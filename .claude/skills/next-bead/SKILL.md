---
name: next-bead
description: Pick the next ready bead (optionally filtered by an epic, a label, or given as ids), bundling small related beads, then have a cheap sub-agent implement it and a more capable one review it, fix findings, verify, commit and close. Use when asked to work the next bead, the next batch, or to "implement and review" beads.
---

# next-bead

Arguments (optional): an epic id, a label, bead ids, or a theme. With none, take the
highest-priority ready work. You are the orchestrator: you select, brief, check, commit and close.
Sub-agents implement and review. Keep your own context small by asking agents for concise reports.

These are guidelines, not a checklist. Each says why it exists, so use judgment where a case doesn't
fit. The one firm rule is the model choice in section 2.

Work through the queue without asking for approval at each step: handle review findings, commits
and closing yourself, and move on. Stop only for decisions that are genuinely the owner's.

Epics grow when every finding becomes a new bead, and they split into old and new paths when work
is built beside the behavior it replaces. Two habits counter both: **pull concerns forward** (fix or
decide them while the code is open, rather than filing them), and **replace rather than add** (a
change that introduces a new path also moves the callers and deletes the old one).

## Project specifics

This skill is shared between projects. Before starting, read the project's AGENTS.md (in
particular any "Agent workflow" section) and `bd memories` for:

- the build and test commands, and what "affected" means for tests;
- version-control rules: how to commit, what agents may and may not run, how to see a diff of
  pending work;
- whether implementers can run in parallel, and how;
- the high-risk areas that call for the stronger reviewer and a run of their own;
- environment quirks (shell, temp directories, tools that must not be run).

It also expects the agent definitions `implementer` (haiku), `implementer-medium` (sonnet),
`implementer-strong` (opus) and `reviewer` (read-only), which carry the project's standing rules
for sub-agents. If the project lacks one of these, ask the user rather than guessing.

## 1. Select

Look at `bd ready` (with `--parent <epic>` or `--label <label>` when given) and `bd show` the likely
candidates, skipping epics and design beads. Good picks are high priority, come next in dependency
order, and get a user-facing path working end to end, or closer to it.

Prefer the bead that switches a real caller over to new code over one that builds more machinery for
later callers. Pure logic is cheap to unit-test and wiring isn't, so a queue picked by ease of
verification builds the new path in full while users still run the old one, and the switch-over
bead gathers every deferred cleanup. Ease of verification only breaks ties.

A bead that needs an owner decision is a question, not a task: ask the user, with your
recommendation, and pick another bead meanwhile. That applies when the bead says so (titles
starting "Decide:", or a topic the project lists as an open question), or when the right answer is
genuinely ambiguous. Product questions, such as what a user sees or how a feature behaves, are
always the owner's.

### Bundling

Loading context is the expensive part of an agent run, so bundle small, related beads (same files,
component or design context, or one fixing the other's bug) into one run. Two or three is usually
the limit. Keep large beads, unrelated areas, and the project's high-risk areas in their own runs,
so each gets a focused review.

Some beads are already fixed or moot; the implementer checks that the problem still exists first.

## 2. Choose the models

**Start every bead with `implementer` (haiku), paired with a stronger reviewer.** This is the one
firm rule. Agents tend to underestimate haiku and reach for opus or sonnet "to be safe". Haiku with
a capable reviewer and a fix round costs far less, and the review catches what it misses. A bead
looking hard is not a reason to start higher.

- `implementer-medium` (sonnet) is for work that needs design judgment the bead and its design
  fields don't settle, such as cross-cutting refactors. Start there only in that case.
- `implementer-strong` (opus) is only for escalation, or when the user asks for it.

Pick the reviewer for the risk: **sonnet** for most haiku work; **opus** for the project's high-risk
areas and anything correctness-critical or cross-cutting.

## 3. Brief the implementer

The agent definitions carry the standing rules (version control, no bead ids in code, notes via
`bd comments add`, the report format). The brief adds what it needs to work without rediscovering
it:

- the bead ids and the files or area;
- the `design` field of relevant closed design beads (`bd show <id> --json`), and any project docs
  for the area;
- the acceptance criteria and what's out of scope;
- which tests to run;
- existing facilities to reuse (helpers, patterns, test fakes): haiku's misses tend to be project
  conventions rather than design.

Remind it to replace rather than add. If moving the callers would reach well outside the bead, it
stops and reports instead of keeping both paths "until" a later bead. That is a slicing problem for
you (see "Emergent work"), not a reason to leave two paths.

### Tests

The implementer builds and runs the affected tests, and reports exact results, including anything
that failed, hung or was skipped. Running them again when nothing has changed tells you nothing new,
so the reviewer and you take that report as the result. Run tests yourself when the tree changed
after the report, the report looks incomplete, or a test is the quickest way to settle a question.

Some behavior can't be reached by automated tests (UI, input, multiple real clients, external
services). Have the implementer write down manual steps that would verify it, and pass those to the
owner rather than claiming the behavior is verified.

### Bead writes

Comments are separate records, so concurrent agents can't overwrite each other's. Fields replaced
whole (notes, description, design, acceptance), status changes, closing and creating are yours: two
writers doing a read-modify-write lose an update. Fold lasting context from comments into the notes
or design field yourself.

### Parallel work

Implementers sharing one working copy collide in builds and edits, so by default run them one at a
time; a read-only reviewer for the previous bead can overlap with them. Parallelize only when the
project gives each agent an isolated working copy (such as a git worktree), and only pair beads that
share no files. Then tell each agent to work only inside its copy, merge each result back into the
main copy, run the tests there (the tree changed after the implementer's run), and remove the copy.

## 4. Review

Always have the work reviewed by a stronger model than the one that wrote it, using
`subagent_type: reviewer` (sonnet by default; pass `model: opus` when section 2 calls for it). Give
it the bead id, the design context, the files changed and how to see their diff, and the
implementer's test results. The reviewer's definition covers what to check; add anything specific to
this bead.

Implementers and reviewers look at one bead, so they make awkward code correct rather than asking
whether it should exist. The reviewer also reports **design pressure**: correct code suggesting the
design is fighting the work, such as repair or resync paths, consistency checks between copies of
the same data, special cases, one component compensating for another, or a bead that grew well
beyond its description. Each flag gets a decision before the next bead starts, because every bead
built on an awkward shape makes it more expensive to change. A comment on the epic is not a
decision; triage it under "Emergent work".

## Emergent work

Reviews, implementers and your own reading keep turning up concerns: bugs on the way, cleanups,
design pressure, gaps in the design. Filing each as a new bead is the easy default, and it is how
epics balloon while their real problems wait. Triage every finding as it arrives, taking the first
answer that fits:

1. **Fix it in this bead** when it's in code this bead touches or must touch. Size alone isn't a
   reason to defer: the context is loaded now and won't be again.
2. **Ask the owner now** when it's a design problem in what this bead builds or builds on. Pause
   anything that would build on it until it's decided, then amend the design and the open beads.
3. **Fold it into an open bead** of the epic when the epic's gate can't pass without it. Amend that
   bead's description and acceptance rather than leaving a comment the next implementer has to dig
   out.
4. **Send it to the epic's follow-up backlog** otherwise: a separate epic, created the first time
   it's needed and linked in the epic's notes, so this epic doesn't grow work it doesn't need.

A new bead joins the epic only when the gate can't pass without it and no open bead can absorb it.
Say in your report whenever the epic gains a bead.

Two signs the slicing is wrong rather than the finding: a bead that can't replace its old path
without reaching into another bead's work, and an open bead collecting "when you do this, also..."
notes. Re-slice (merge the beads, or move the switch-over earlier) instead.

## 5. Fix and commit

- **Fix round.** Send the findings to the same implementer with `SendMessage`; resuming is far
  cheaper than a new agent. Ask for the blockers, the should-fix items and whatever "Emergent work"
  put in this bead. One fix round is normal.
- **Final checks.** Check the working copy for stray files and for this work's files the VCS isn't
  tracking yet. Compare the diff's changed-line counts with and without trailing CRs to catch
  line-ending churn, since each file keeps its own LF or CRLF.
- **Commit** only this work's paths, named explicitly, so the owner's unrelated changes stay out;
  confirm afterwards that only what was pending before you started remains. The message says what
  and why, which models implemented and reviewed it, and the attribution line the system provides.
  No bead ids: beads are local and unsynced.
- **Close** with `bd close` and a reason, which may cite the commit.

## Escalating

A cheap model that is struggling costs more than a capable one that isn't. Hand the work one step
up (haiku, sonnet, opus) rather than looping, when blockers remain after a fix round, the
implementer guessed at a design question or got tests green by weakening them, the reviewer finds
structural problems rather than local defects, or the implementer couldn't finish.

Start the stronger agent on the current tree with the bead, the findings and the previous report,
and tell it to keep what is sound. If opus also struggles, stop and tell the user what is
unresolved. Mention escalations in your report: they are the evidence for tuning the model choice.

## Epic checkpoint

Run a checkpoint when the last implementation bead of an epic closes. Also run one mid-epic when the
epic has grown by about a third over its starting bead count (record that count in the epic's notes
the first time you work it), or when two design-pressure questions have gone to the owner. Growth is
the cheapest signal that the design is fighting the work, and a mid-epic checkpoint can still change
the remaining beads.

Have an opus reviewer read the code as it now stands (not the diff) against AGENTS.md, the epic's
design and the design pressure raised on it, and answer:

1. What is more complex than its purpose needs?
2. Where do the code and the design disagree?
3. What will the next epic find awkward?

Bring its answers to the user as candidate design questions, with your recommendation, not as
implementation beads: design changes are the user's call. A checkpoint that finds nothing is a good
result; say so briefly and move on.

## 6. Report

Concisely:

- the commits and the beads closed;
- the findings that mattered, and where each went (fixed here, asked, folded into a bead, or the
  follow-up backlog), with ids;
- beads the epic gained, and its count against its starting size;
- any design pressure, and what was decided;
- anything unverified, with the manual steps that would verify it;
- the token usage per agent, and how the implementer and reviewer did if the user is tuning model
  choices.
