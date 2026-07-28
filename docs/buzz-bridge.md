# Buzz fleet bridge

The Buzz fleet bridge is an opt-in, one-way-by-default status link from a firstmate home to a channel in a [Buzz](https://github.com/block/buzz) community, plus a pull-based intake for research requests posted in that channel.
It exists for captains who run a dual-home setup: firstmate remains the supervisor of record (worktrees, validation pipeline, merge authority, dispatch rules), while Buzz is a second cockpit for chat-scale work and fleet visibility.
The bridge is inert until configured, exactly like X mode: a home without a configured channel gets zero behavior change, no bootstrap artifacts, and no watcher work.

## Architecture

- `bin/fm-buzz-lib.sh` resolves config and composes the public-safe fleet snapshot; it is sourced by the two clients and owns the secrets discipline (the key rides the buzz CLI subprocess environment only and is never printed or placed on a command line).
- `bin/fm-buzz-status.sh` posts the snapshot, or a custom line via `--text <file>` / stdin, to the configured channel with `buzz messages send`; `--dry-run` prints the exact message with no network.
- `bin/fm-buzz-enqueue.sh` is the research intake: one short `buzz messages get` poll of the same channel that surfaces new `fm research:` / `fm: scout web` requests as `buzz-research <event_id> <question>` lines and tracks a `state/buzz-bridge.cursor` high-water mark so each request surfaces exactly once.
- `docs/configuration.md` ("Buzz fleet bridge") owns the config schema and resolution order; this file owns the operating guide.
- Behavior is pinned by `tests/fm-buzz-bridge.test.sh` with a fake `buzz` CLI.

Nothing in the bridge writes into Buzz-managed state, spawns Buzz agents, or replaces firstmate supervision; it only sends and reads channel messages as its own configured identity.

## Opt-in

1. Create or pick a fleet channel in the Buzz workspace (desktop UI, or `buzz channels create`) and note its UUID from `buzz channels list`.
2. Provide a Nostr private key the captain controls for the bridge identity, ideally a dedicated "Firstmate" member rather than any nest agent's key.
3. Put the settings in the home's gitignored `config/buzz-bridge.env` (or `.env`) per the schema in `docs/configuration.md`.
4. Smoke it: `bin/fm-buzz-status.sh --dry-run` first, then a real `bin/fm-buzz-status.sh` and confirm the message appears in the channel.

With the channel unset both clients are hard no-ops; with the channel set but the key missing they print one stderr guidance line and still exit 0, so a half-configured bridge can never fail the fleet.

## When firstmate posts (no-spam rules)

The bridge is event-driven by firstmate, not a high-frequency mirror; there is deliberately no bridge watcher shim, because the watcher check surface is byte-validated and the value here does not justify widening it.
Post on captain-relevant events only, the same set section 9 of `AGENTS.md` already escalates:

- A ship task's PR is ready or merged, a scout's findings are in, or a task failed - post the one-line outcome (with the full PR URL) via `--text`.
- On heartbeat review, post a fresh snapshot only when the fleet actually changed since the last post.
- Never post routine progress, empty polls, retries, or internal mechanics, and never relay worker output verbatim - the channel is captain-facing, so the section 9 translation rules apply.

## Research requests (Grok stays firstmate-side)

Buzz's managed-agent catalog has no Grok runtime, and by captain policy web/X-central research stays on firstmate crews (Grok when quota allows, else the configured Claude research profile in `config/crew-dispatch.json`).
The bridge encodes that as a message convention instead of a Buzz-side runtime:

1. The captain (or a nest agent) posts `fm research: <question>` or `fm: scout web <question>` in the fleet channel.
2. Firstmate runs `bin/fm-buzz-enqueue.sh` when the bridge is configured - on heartbeat review, or on demand - and treats each surfaced `buzz-research` line as ordinary scout intake: queue it, dispatch per the configured dispatch rules, and acknowledge in the channel via `fm-buzz-status.sh --text`.
3. When the scout report lands, firstmate posts the findings summary back the same way.

`--peek` previews pending requests without consuming them; the cursor only advances on a normal poll, so a crashed intake retries the same requests next time.

## Health checks

- `bin/fm-buzz-status.sh --dry-run` - composes the snapshot locally; proves config parsing and backlog reading with no network.
- `buzz channels list` with the bridge identity's key in the environment - proves relay reachability and identity auth.
- `cat state/buzz-bridge.cursor` - the last message timestamp the research intake has consumed.

## Secrets

`BUZZ_PRIVATE_KEY` (and any relay credentials) live only in the gitignored `config/buzz-bridge.env` or `.env`, are passed to the buzz CLI via the subprocess environment, and must never appear in tracked files, reports, commits, status lines, or channel messages.
