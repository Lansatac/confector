---
name: design-session
description: Run a design session with the owner and turn its decisions into beads. Walks concrete scenarios through the design before cutting any work, makes the end-to-end gate test the first bead, cuts detailed beads only for the next vertical slice, and consolidates designs that have been amended. Use when asked to design a feature, milestone or epic, to revisit a design, or to act on an epic checkpoint's design questions.
---

# design-session

You are designing with the owner. The work that follows runs bead by bead through `next-bead`, with
cheap implementers that see one bead at a time. A design problem that slips through here surfaces
late, mid-epic, as code that fights the model. These guidelines exist to find those problems while
they are still cheap to fix. Use judgment where a case doesn't fit.

## Where decisions live

This skill is shared between projects; the project's AGENTS.md (in particular any "Agent workflow"
section) and `bd memories` say where its design docs live and where implementation epics go. The
defaults:

- A decision is recorded in the `design` field of a design bead (`bd update <id> --design-file`),
  which is closed once decided.
- It is summarized in the project's design docs (AGENTS.md, or the docs it points to).
- Questions left open are listed where the project keeps open questions, and a bead for one is
  titled "Decide: ...", so `next-bead` treats it as a question for the owner rather than a task.
- Implementation work goes in an epic for the feature, with the design bead linked.
- The docs are committed after each decision.

Design docs state intent, constraints and invariants. Propose wording to the owner rather than
adding your own opinions, and keep implementation status out of them, since that goes stale.

## 1. Understand the problem first

Read AGENTS.md, the design docs and design beads for the area, and the code the design will touch.
If an epic checkpoint or reviewer design-pressure notes led here, start from them: they show where
the current model fights the work.

Frame the problem as what the user should be able to do and what must stay true. Get the owner's
agreement on that before discussing mechanisms.

## 2. Walk scenarios before cutting beads

A design described only as mechanisms (records, indexes, messages, protocols) hides gaps that become
obvious once one concrete user is traced through it. Before cutting any beads, walk three to five
scenarios through the proposed model, step by step, naming which component acts, each piece of state
read and written, and each message sent.

Good scenarios are concrete, with named actors and objects ("Alice and Bob share a document; Alice
goes offline and edits it; Bob deletes a section she edited; Alice reconnects..."). Between them
they should cover:

- the common path, from the user's point of view;
- a later action that depends on an earlier one, such as repeating, undoing or building on it;
- a failure: a dependency that is unreachable, a process that crashes, data that is missing or from
  an older version;
- two things happening at once: two actors changing the same thing, or a late or duplicated
  message.

Where a step is awkward, unclear or needs a special case, that is the design talking. Settle it now
with the owner, or record it as an open question, rather than leaving it for an implementer to find.

Record the scenarios in the design bead with their expected outcomes. They become the gate test.

## 3. The gate test is the first bead

Make the first implementation bead of a milestone or large epic an end-to-end test of those
scenarios. Stub what doesn't exist yet, and expect it to fail. Every later bead moves it toward
green, so integration problems show up while the design is still easy to change, not after every
track has landed.

Drive the system the way a user would, entering each scenario where the user's action enters the
code today (an API, a command, an input handler), with real stores or faithful fakes. A gate that
calls only the new core passes while users still run the old path, so it can't tell you the work is
done. If expressing a scenario needs heavy mocking, the design probably mixes logic into the shell;
settle that now.

Steps automated tests can't reach (UI, input, multiple real clients, external services) go in a
manual test script in the design bead, with the expected outcome of each step. Keep both in step
with the design.

## 4. Cut beads only for the next slice

Detailed beads cut far ahead are cut against a design that hasn't met code yet, and the first slice
usually changes it. So:

- Cut detailed beads, with acceptance criteria and dependencies, only for the next slice: the work
  that gets the gate test meaningfully further, typically a few days' worth.
- Keep later work as epics that state their intent and the scenarios they serve, without task
  beads.
- When a slice lands, or an epic checkpoint runs, refine the next slice from what was learned.

Slice vertically. A slice takes one user action (or a few closely related ones) all the way through
the system, from where it enters to where its effect is stored and shown, and deletes the old path
that action used. Avoid slicing by layer (core, then plumbing, then wiring): a layered epic builds
the new path in full beside the old one, nothing changes for users until the last slice, and every
slice in between leaves "kept until the wiring bead" notes that pile onto that last bead. If one
action can't switch over without the others, put them in the same slice.

Note the epic's starting bead count in its notes so growth is visible, and name a follow-up epic
for findings the gate doesn't need, so they don't land in this one. `next-bead` uses both.

A good bead names its design bead and the docs to read, says what is out of scope, and has
acceptance criteria an implementer can check without making design choices. If writing the
acceptance criteria needs a decision, the design isn't finished.

## 5. Consolidate amended designs

Amendments stack up: a design bead with two addenda forces every implementer brief to work out the
current design from the history. When a design is amended a second time, or an amendment overturns
part of it, rewrite the design field as one current document, with a short "Superseded" note saying
what changed and why. Update the design docs to match, and point other design beads that cite the
old wording at the consolidated one.

## 6. Close the session

Before ending, check with the owner:

- the decisions and the doc wording;
- the scenarios and expected outcomes recorded in the design bead;
- the gate test bead, its manual test script, and the beads for the first slice;
- the open questions that remain;
- which slice `next-bead` should start on.

Commit the docs with only their own paths. Commit messages say what was decided and why, with no
bead ids, since beads are local and unsynced.
