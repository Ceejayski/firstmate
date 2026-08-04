---
name: showcase
description: Bring a committed artistic direction to creative and product work - a stated point of view, genuinely distinct alternatives, one flagged surprise, and every decision aimed at a result worth showing off, always derived from the project's own DNA rather than a generic aesthetic. Use when work should be memorable rather than merely correct - a new user-facing surface, page, redesign, brand asset, demo, deck, or presentation - when the user says "surprise me", "make it pop", "add taste", "make it beautiful", "wow me", or "make it worth showing off", or when output is at risk of looking like a template.
user-invocable: true
---

<!-- maintainers: this is a public, installer-facing skill. Keep it standalone, with no private project paths, tool assumptions, or environment branching. -->

# showcase

Make the result worth opening a demo with, by forcing direction decisions that timid execution skips.
Generic output does not come from lack of talent; it comes from never choosing, so every step here produces a checkable artifact - a citation, a thesis, a named star, a flagged surprise, a cut log - and an exhortation without an artifact counts as skipped.
Adjectives ("be bold", "have taste") change nothing; artifacts do.

All artifacts land in one short **direction note** kept wherever the task already keeps its working notes: the PR description, an existing design-notes file, or a comment block at the top of the main changed surface.
Do not invent a new file convention for it; the note is a paragraph, not a document.

## 1. Read the project's DNA before forming any opinion

Taste is contextual: a crude MS-Paint meme product and a sober trading terminal are both excellent on their own terms, and the same generic gloss would ruin both.
Before any design decision, collect the project's own evidence, in this order:

1. Explicit design authority: a design doc, brand guide, token file, theme config, or product-voice doc.
2. Approved references: gold samples, reference images, or "this one is right" artifacts the project keeps.
3. The best existing shipped surface, and the copy voice it uses.
4. Named inspiration or prior art the project's docs point to.

Write a **DNA note**: three to six observed facts, each with a file, token, or asset citation, plus at least one "this project would never" line.
If you cannot cite it, you did not read it - an uncited DNA fact is your own house style leaking in, which is exactly what this step exists to block.
On a greenfield project with no DNA to read, derive a proposed DNA from the audience and subject matter, and label it proposed rather than observed.

## 2. Commit to a thesis before executing

Write one sentence naming the point of view in concrete imagery, plus two or three "this is not" lines naming the tempting nearby defaults being refused.
Falsifiability test: the thesis qualifies only if a reasonable person could put its opposite on a brief.
"A xerox contact sheet stamped by hand" passes; "clean and modern" fails, because nobody briefs for dirty and dated.
Never blend two candidate directions to stay safe: a hedged blend of every option is the precise mechanism by which output becomes generic.

## 3. Generate three genuinely distinct directions

For any surface-scale deliverable, write three directions, each with a thesis, a not-list, its **dominant element** (the one thing a screenshot would be remembered by), and at least one DNA citation.
Then verify they are actually distinct:

- **Axis check**: each pair must sit at opposite ends of at least one named axis - loud/quiet, dense/sparse, handmade/precise, monumental/intimate, still/kinetic, object-led/character-led.
- **Swap test**: mentally exchange two directions' fonts and palettes; if each still reads as itself, something structural separates them, and if they become interchangeable they were one direction in three coats of paint.
- **Dominant elements must differ in kind, not degree** - a bigger version of the same hero is not a second direction.

Pick one, and record two lines: why it beats the others against the DNA and the request, and the single best idea from a losing direction worth stealing.
Steal at most one; stealing more is blending.

## 4. Apply the showcase test to every decision

The test, at every scale: **would I open the demo with this?**
It applies to the hero, and equally to an empty state, an error message, a loading moment, a confirmation, a chart legend, a CLI help text.
Small surfaces are where taste shows most, precisely because nobody expects anything from them.
When the answer is no: name the single weakest thing, fix it now if in scope, and log it in the direction note if not.

**One star per surface**: every screen, section, or output has exactly one deliberate showpiece.
If you cannot name it, the surface is filler; if you count three, pick one and demote the rest.
Name each surface's star in the direction note - an unnamed star is the artifact-skip this skill forbids.

## 5. Run the anti-generic sweep

These defaults read as "nobody decided this" and cost nothing to avoid:

- The centred hero with a gradient blob or glow.
- Three equal feature cards in a row.
- Emoji or stock iconography standing in for a visual identity.
- The same border radius and the same soft drop shadow on every element.
- Gray-on-white "clean" with one brand accent doing all the work.
- One section rhythm repeated down the page: heading, paragraph, grid, repeat.
- Marketing verbs: unlock, empower, seamless, supercharge, elevate.
- The default sans-serif because it was already there.

This is a tripwire list, not a ban list: any item may appear, but only as a cited choice ("the DNA here is deliberately plain, see X"), never as an unexamined default.
The question for each hit is "did I choose this, or did it just happen?" - if it just happened, replace it or consciously re-commit in one line.

## 6. Spend the surprise budget: exactly one

Include exactly one deliberate, unrequested, on-thesis delight per deliverable.
Zero is a failure of nerve; two is scope creep; silent is scope smuggling regardless of size.
The surprise must:

- Serve the committed thesis, not a private whim.
- Be small and separable: an isolated commit or clearly delimited code a reviewer can revert in minutes.
- Never touch scope, pricing, brand assets, data contracts, or public APIs.
- Be flagged in the handoff under a **Surprise** heading, with a one-line removal instruction, so rejecting it is cheap.

A surprise idea that needs any protected decision (section 8) is an option to propose, never to spend.

## 7. Make the subtractive pass

Before calling the work done, run one removal pass: for each element added, ask "if this vanished, would anyone rebuild it?"
Remove at least one thing that fails, or record one line naming the strongest removal candidate and why it stays.
The thesis is usually clearest as the current version minus the second-loudest thing.
Record every cut in a **cut log** (what went, one reason each), so restraint is visible as a decision rather than mistaken for absence of work.

## 8. Precedence: what taste never overrides

- **Owner-only decisions**: pricing, product scope, brand assets and names, real-person likenesses, and legal copy are never invented or "improved" on this skill's initiative; taste operates inside them.
- **Correctness outranks flair**: accessibility (contrast, focus visibility, reduced motion, semantics), security, payment and refund integrity, and the project's documented invariants win every conflict with a striking choice.
  The losing choice is redesigned within the constraint, never waived - and the direction note says so plainly, because confident taste negotiating away an invariant is exactly how this skill goes wrong.
- **Character beats polish**: if a change makes the project more interchangeable with its category, it is a regression even when it is objectively prettier.
  Corporate polish applied to an anti-corporate brand is a failure of this skill, not a success.
- **Scope discipline is unchanged**: the surprise budget licenses one small delight, never an unrequested refactor, and the project's engineering quality bar is untouched.

## 9. Division of labour with execution-polish tooling

If the project uses a dedicated design-execution or polish tool or skill (one that audits spacing, typography, hierarchy, and accessibility - Impeccable is one example), the split is:

- **This skill owns direction and ambition**: what to make, and why it is worth showing off.
- **The polish tool owns execution quality**: whether it is well made.

Run this skill's direction steps before building; run the polish pass after, with the direction note in hand.
A polish finding that would flatten the committed thesis (say, normalizing deliberately crude edges) is answered by citing the thesis; a polish finding about correctness always wins, per section 8.
Neither replaces the other: direction without execution is a sketch, and execution without direction is a template.

## Compact mode for small decisions

For a single component, copy string, empty state, or similar in-scope decision, run the reduced protocol below.
Drop the three directions (section 3), the surprise budget (section 6), and the cut log (section 7).
Keep one DNA citation (section 1), a one-sentence thesis (section 2), the showcase test (section 4), the anti-generic sweep (section 5), and one line in the direction note.
The surprise budget is a per-deliverable obligation and never a per-decision one, so a trivial in-scope edit owes zero surprises.
If a "small" decision turns out to set the direction for a whole surface, stop and run the full protocol.
