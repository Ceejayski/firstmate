# Verification: the showcase skill changes what an agent produces

This record verifies that [`skills/showcase/SKILL.md`](../../skills/showcase/SKILL.md) is operational rather than exhortative: the same task, run without and then with the skill's protocol, produced materially different output, and every skill step left the checkable artifact it demands.

- Date: 2026-08-03.
- Skill version: the copy committed alongside this record.
- Task used: design the "wallet connected, zero server generations" empty state for a live project's archive page (the `/gens` route of a registered meme-generator site project).
- Method: author the baseline first, honestly, as the fast-and-safe version an agent produces with the project's palette but no direction protocol; then run the skill's steps 1-7 literally and record each artifact below; render both as standalone mocks and inspect them in a real browser.

## Exact commands

```sh
chrome-devtools-axi open "file://$PWD/docs/verification/showcase-skill/baseline.html"
chrome-devtools-axi screenshot --output /tmp/baseline.png
chrome-devtools-axi open "file://$PWD/docs/verification/showcase-skill/directed.html"
chrome-devtools-axi screenshot --output /tmp/directed.png
```

Both committed mocks render as intended in Chrome, last confirmed on 2026-08-04.

The baseline's accessibility snapshot exposes a status card with heading, caption, and one link.
The directed mock's snapshot exposes the main landmark, the "OWNER ARCHIVE" eyebrow text, the heading, the caption paragraph, the link, and the aside text, with no list node among them.
That absence is a property of the snapshot view rather than of the markup: the command flattens structural containers, and a default-styled `<ul aria-label="...">` injected into the same page prints as bare text nodes too, so this output is not evidence about what a screen reader announces.
What is committed is a labelled list - `<ul class="frames" aria-label="Empty archive wall, eight waiting frames">` with eight `<li>` children and no `aria-hidden` - which Chrome exposes as a named list.
The name lives there because the eight frames carry no text of their own, and the decorative stamp sits in a wrapping `<div class="frames-wall">` rather than inside the `<ul>`, so the list has only `<li>` children.

Both mocks label the primary button in ink rather than white, because white on `#e8352a` is 4.22:1, under the 4.5:1 the skill's own precedence rail demands, while ink on the same red is 4.69:1.
Chrome confirms the rendered values: the CTA computes to `rgb(10, 10, 10)` on `rgb(232, 53, 42)`.

## Before and after

- Before: [`showcase-skill/baseline.html`](showcase-skill/baseline.html) - a centred card raised by a soft drop shadow, circled emoji icon, "No generations yet", apologetic caption, one rounded button.
  It uses the project's exact palette tokens and is competently built, which is the point: palette adherence alone did not prevent the canonical empty-state template.
  Four items on the skill's anti-generic tripwire list appear unexamined (centred card, icon-as-identity, uniform radius, soft shadow), and the project's own token file literally carries a "NO soft glow" comment the baseline violates.
- After: [`showcase-skill/directed.html`](showcase-skill/directed.html) - the picked direction below: a vacant gallery wall of eight taped, tilted, dashed frames under a rotated red "NO CURSES YET" stamp, marker-face heading "The wall is up.", hard offset shadows, and a flagged one-item surprise.
  Emptiness is rendered as reserved space rather than absence, and the ghost wall prefigures the exact grid the page grows into.

The delta is structural, not cosmetic: different layout, different information design, different copy voice, different emotional read - produced by the protocol, since the same author wrote both files in the same hour.

## The skill-run artifacts

**DNA note (step 1), all facts cited from the project's own sources:**

1. Hand-drawn faces sitewide: marker display plus handwriting body, template sans retired (design-token doc, typography block; token CSS `--font-hand` comment).
2. Hard offset "sticker" shadows only, explicitly "NO soft glow/halo on brand art" (token CSS `--shadow` comment).
3. Wobble border radii as a signature, for example `14px 5px 16px 6px / 6px 15px 5px 17px` (design-token doc, rounded block).
4. Red stamp, taped paper, and dashed-border vocabulary throughout the approved hero reference (project gold sample: rotated "CURSED" stamp, dashed contract panel, speech bubble).
5. Copy voice is in-world and unapologetic: "curse", "rot", "cooking", never SaaS-neutral (shipped archive page copy).
6. This project would never: soft gradients, glassmorphism, polite gray minimalism, or apology copy.

**Thesis (step 2), committed before any markup was written and carried in the directed mock's header comment:**

Thesis: an empty gallery wall with paper squares already taped up - emptiness rendered as reserved space, not absence.
This is not: a sad-face apology; not a dashboard placeholder card; not a mascot cartoon doing the work the user's gens should do.
Falsifiability check: the opposite ("a quiet apology that gets out of the way until there is something to show") is a brief a reasonable person could write, so the thesis is a real commitment rather than a compliment.

**Directions considered (step 3), with the distinctness checks applied:**

- A - "the first page of a fresh sketchbook": quiet and intimate; dominant element is one large empty hand-inked frame with a pencil scrawl inside; cites the paper tokens.
- B - "wall of fame, currently vacant": loud and monumental; dominant element is the vacant stamped wall of waiting frames; cites the gold sample's stamp and tape vocabulary.
- C - "the spider is waiting": kinetic and character-led; dominant element is the mascot dangling into the empty space with a speech-bubble dare; cites the hero mascot reference.

Axis check: A/B sit on quiet/monumental, B/C on object-led/character-led, A/C on still/kinetic.
Swap test: A is defined by a single frame object, B by repeated ghost slots, C by an actor - each survives a font-and-palette swap as itself.
Pick: B, because it does double duty the others cannot: it previews the archive's future form (the shipped page's own contact-sheet framing) while making emptiness read as potential, and it gives the CTA a diegetic job ("make the first one" fills a visible slot).
Stolen from a loser: A's handwritten scrawl tone for the caption; C's mascot was deliberately not stolen, one theft is the limit.

**Showcase test (step 4):** the baseline fails "would I open the demo with this?" - it is the empty state every product has.
The directed version's named star is the stamped vacant wall; the heading and CTA were kept quieter so the wall stays the only star.

**Anti-generic sweep (step 5), run over the DIRECTED mock, one verdict per tripwire item:**

1. Centred hero with a gradient blob or glow - absent; there is no gradient anywhere and every shadow is a hard offset, per the token file's "NO soft glow" comment.
2. Three equal feature cards in a row - absent; the eight equal frames are the direction's dominant element (a wall of waiting slots), not a card row standing in for content.
3. Emoji or stock iconography as identity - absent; the baseline's circled framed-picture emoji was cut and nothing replaced it.
4. Same border radius and same soft shadow everywhere - present as a cited choice: the wobble radius `14px 5px 16px 6px / 6px 15px 5px 17px` repeats on the frames and the CTA because it is the documented signature token, and the shadows are hard offsets rather than the soft drop the item warns about.
5. Gray-on-white "clean" with one accent doing all the work - absent; the palette is ink and paper, and the red does structural work as stamp, border, and shadow ink rather than as a lone highlight.
6. One section rhythm repeated - absent; the surface runs eyebrow, marker heading, one caption, the grid, then an actions row, and never repeats a block.
7. Marketing verbs - absent; the copy is "The wall is up.", "Eight frames, zero curses", "until it rots", "Make the first one", none of them from the unlock/empower/seamless family.
8. Default sans-serif because it was already there - absent; the marker and hand faces come from the typography DNA, and the fallback stacks exist only because a standalone mock cannot load the site's self-hosted woff2.

Sweep result: one hit, re-committed in one line rather than replaced, which is the outcome the step allows.

**Surprise budget (step 6):** exactly one - slot 1 carries a taped paper note reading "reserved for your first curse" that straightens on hover.
It is flagged in the mock's header comment with a one-line removal instruction (delete the `.reserved-note` block and its element), touches no scope or contract, and respects reduced-motion.

**Cut log (step 7):** cut a planned third row of ghost frames (two rows already read as a wall); cut a "how it works" caption that duplicated the make-page's job; cut the mascot from direction B (it belongs to direction C and would have been blending).

## Honest limitations

- Three directions from one model are narrower than three directions from three people.
  The axis and swap tests catch collapse into one idea, but they cannot manufacture range the author does not have.
- The skill makes commitment cheap, which also makes a wrong commitment more decisive.
  Direction B leans on the red-stamp motif from one gold sample; if the project ever retires that motif, this process would have confidently shipped an outdated read.
  The only guard is that every DNA fact is cited, so a reviewer can see exactly which source a direction stands on and challenge it.
- It did not help where a design-first process already ran: the shipped archive page carries its own thesis header from a prior wireframe-driven redesign, and the full protocol there would mostly re-derive existing decisions.
  Compact mode is the right dose on such surfaces, and an agent may misjudge which mode a task deserves.
- The anti-generic tripwire list is web-UI-weighted; for copy, decks, or CLI output the agent must generalize it, which is exactly the kind of judgment the list was written to avoid relying on.
- The skill cannot tell whether the surprise lands as delight or as noise; that remains a human read on the flagged, cheap-to-reject artifact.
- Cost is real: the full protocol adds a DNA read, three written directions, and a note to every surface-scale task.
  That is the price of the deliverable being worth showing off, but it is the wrong price for a checkbox fix.

## How a task invokes it

The skill is public and standalone: install it into a project like any installer-facing skill, or point an agent at `skills/showcase/SKILL.md` directly.
For fleet work, the task instructions author adds one line to design-flavored task instructions, for example: "Before any design or creative decision, read and follow skills/showcase/SKILL.md and keep its direction note in the PR description."
No scaffold automation was added, deliberately: the brief scaffolder's repo argument is a caller-supplied string with no reliable signal that a task is design-flavored (the same reason the coding-guidelines skill is added to briefs by hand), so a keyword heuristic would misfire in both directions.
If design-heavy briefs become frequent, a `--design` scaffold flag that injects the load line is the smallest honest wiring; propose it then, not now.
