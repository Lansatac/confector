---
name: design-session
description: Run a design session with the owner and turn its decisions into beads. Walks concrete scenarios through the design before cutting any work, makes the end-to-end gate test the first bead, cuts detailed beads only for the next slice, and consolidates designs that have been amended. Use when asked to design a feature, milestone or epic, to revisit a design, or to act on an epic checkpoint's design questions.
---

# design-session

You are designing with the owner. The work that follows runs bead by bead through `next-bead`, with
cheap implementers that see one bead at a time. A design problem that slips through here surfaces
late, mid-epic, as code that fights the model. These guidelines exist to find those problems while
they are still cheap to fix. Use judgment where a case doesn't fit.

## Where decisions live

Follow the project's design workflow:

- A decision is recorded in the `design` field of a design bead (`bd update <id> --design-file`),
  which is closed once decided.
- It is summarized in an AGENTS.md section, and the topic leaves "Open questions".
- Implementation work goes in epics under `confector-z7z`.
- AGENTS.md is committed after each decision.

AGENTS.md states project intent only. Propose wording to the owner rather than adding your own
opinions, and keep code status out of it, since that goes stale.

## 1. Understand the problem first

Read AGENTS.md, the relevant design beads, and the code the design will touch. If an epic
checkpoint or reviewer design-pressure notes led here, start from them: they show where the current
model fights the work.

Frame the problem as what the user should be able to do and what must stay true. Get the owner's
agreement on that before discussing mechanisms.

## 2. Walk scenarios before cutting beads

A design described only as mechanisms (documents, indexes, protocols) hides gaps that become
obvious once one concrete user is traced through it. Before cutting any beads, walk three to five
scenarios through the proposed model, step by step, naming each document read and written.

Good scenarios are concrete, with named tasks, repositories and refs ("tasks A and B depend on
repositories RA and RB; C depends on both; I trigger A..."). Between them they should cover:

- the common path, from the user's point of view;
- a later action that depends on an earlier one, such as building on a chain or rerunning;
- a failure: an unreachable repository, a crashed worker, a missing ref;
- two things happening at once, such as concurrent requests or a late completion.

Where a step is awkward, unclear or needs a special case, that is the design talking. Settle it now
with the owner, or record it as an open question, rather than leaving it for an implementer to find.

Record the scenarios in the design bead with their expected outcomes. They become the gate test.

## 3. The gate test is the first bead

Make the first implementation bead of a milestone or large epic an end-to-end test of those
scenarios. Stub what doesn't exist yet, and expect it to fail. Every later bead then moves it toward
green, and integration problems show up while the design is still easy to change, not after every
track has landed.

The test should drive the system the way a user would: through the API, the worker protocol and the
real stores, with a memory and a Mongo configuration where the project has them. Keep its scenarios
in step with the design bead.

## 4. Cut beads only for the next slice

Detailed beads cut far ahead are cut against a design that hasn't met code yet, and the first slice
usually changes it. So:

- Cut detailed beads, with acceptance criteria and dependencies, only for the next slice. That's
  the work that gets the gate test meaningfully further, typically a few days' worth.
- Keep later work as epics that state their intent and the scenarios they serve, without task
  beads.
- When a slice lands, or an epic checkpoint runs, refine the next slice from what was learned.

A good bead names its design bead, says what is out of scope, and has acceptance criteria an
implementer can check without making design choices. If writing the acceptance criteria needs a
decision, the design isn't finished.

## 5. Consolidate amended designs

Amendments stack up: a design bead with two addenda forces every implementer brief to work out the
current design from the history. When a design is amended a second time, or an amendment overturns
part of it, rewrite the design field as one current document. Keep a short "Superseded" note
saying what changed and why, so the reasoning isn't lost. Update the AGENTS.md summary to match.

Point other design beads that cite the old wording at the consolidated one.

## 6. Close the session

Before ending, check with the owner:

- the decisions and the AGENTS.md wording;
- the scenarios and expected outcomes recorded in the design bead;
- the gate test bead, and the beads for the first slice;
- the open questions that remain, listed in AGENTS.md;
- which slice `next-bead` should start on.

Commit AGENTS.md with only its own path. Commit messages say what was decided and why, with no bead
ids, since beads are local and unsynced.
