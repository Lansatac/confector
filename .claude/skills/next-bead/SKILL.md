---
name: next-bead
description: Pick the next ready bead (optionally filtered by a label such as m1, or given as ids), bundling small related beads, then have a cheap sub-agent implement it and a more capable one review it, fix findings, verify, commit and close. Use when asked to work the next bead, the next batch, or to "implement and review" beads.
---

# next-bead

Arguments (optional): a label (`m1`), bead ids, or a theme. With none, use the project's current
milestone label. You are the orchestrator: you select, brief, check, commit and close. Sub-agents
implement and review. Keep your own context small by asking agents for concise reports.

These are guidelines, not a checklist. Each one says why it exists, so use judgment where a case
doesn't fit. The one firm rule is the model choice in section 2.

## 1. Select

Look at `bd ready --label <label>` and `bd show` the likely candidates, skipping epics and design
beads. Good picks are high priority, unblock other beads, come next in dependency order and are
cheap to verify.

A bead that needs an owner design decision is a question, not a task. Ask the user, with your
recommendation, and pick another bead meanwhile. That applies when the bead says so, or when the
right answer is genuinely ambiguous.

### Bundling

Loading context is the expensive part of an agent run, so bundle small, related beads into one run.
Related means the same files, component or design context, or one fixing the other's bug. Two or
three is usually the limit. Keep large beads, unrelated areas, and risky storage, security or
concurrency work in their own runs, so each gets a focused review.

Some beads are already fixed or moot. Ask the implementer to check that the problem still exists
before changing anything.

## 2. Choose the models

**Start every bead with `implementer` (haiku), paired with a stronger reviewer.** This is the one
firm rule. Agents tend to underestimate haiku and reach for opus or sonnet "to be safe". In the
owner's experience, haiku with a capable reviewer and a fix round has not failed on this project,
and it costs far less. A bead looking hard is not a reason to start higher.

- `implementer-medium` (sonnet) is for work that still needs design judgment the bead and its
  design fields don't settle, such as cross-cutting refactors. Start there only in that case.
- `implementer-strong` (opus) is only for escalation (see "Escalating"), or when the user asks for
  it explicitly.

Pick the reviewer for the risk:

- **Sonnet** suits most haiku work.
- **Opus** suits concurrency, compare-and-set, crash recovery, security, and anything
  correctness-critical or cross-cutting.

Haiku's misses tend to be project conventions rather than design. Remind it to reuse existing
facilities (crypto, RNG, store patterns, test helpers), and that bead ids don't belong in code.

## 3. Brief the implementer

Give the agent what it needs to work without rediscovering it:

- the bead ids and the files or area;
- "read AGENTS.md first", and `bd show <id>`;
- the `design` field of relevant closed design beads (`bd show <id> --json`);
- the acceptance criteria and what's out of scope;
- the packages to test.

Include the standing rules:

- No git write commands; you commit.
- Don't close or create beads.
- No bead ids or bead details in code, comments, test names, error messages or commit messages.
  Beads are local and unsynced, so ids point at nothing for anyone else.
- Record notes with `bd comments add`.
- Report concisely: files, design choices, deferred items, exact test results and anything
  unverified.

### Tests

The implementer owns the test run. It runs the affected packages and `dub build`, and reports
exact results, including anything that failed, hung or was skipped. Test suites are slow, and
running them again when nothing has changed tells you nothing new. So the reviewer and you
normally take that report as the result and spend your effort elsewhere. Run tests yourself when
you have a reason to, for example:

- the tree changed after the report;
- the report looks incomplete;
- a test is the quickest way to settle a question.

### Bead writes

Comments are separate records, so concurrent agents can't overwrite each other's. Fields that are
replaced whole (notes, description, design, acceptance), status changes, closing and creating are
yours: two writers doing a read-modify-write lose an update. Fold lasting context from comments
into the notes or design field yourself.

### Parallel work

dub builds collide in one tree, so run agents in the main tree one at a time. To parallelize, give
each agent its own git worktree, and only pair beads that share no files.

1. Create the worktree in a folder the user has named, or ask where. Use
   `git worktree add -b wt-<name> <folder>/<name> HEAD`, and keep the path short on Windows. The
   harness's `isolation: "worktree"` doesn't let you choose the folder.
2. Tell the agent to work only inside that folder.
3. To apply the result, run `git add -N .` in the worktree, write `git diff --binary` to the
   scratchpad, and `git apply --3way` it in the main tree. Resolve conflicts in shared files such
   as the README by keeping both sides.
4. Run the tests there, since the tree changed after the implementer's run.
5. Remove the worktree and its branch afterward.

## 4. Review

Always have the work reviewed by a stronger model than the one that wrote it, using
`subagent_type: reviewer`. It defaults to sonnet; pass `model: opus` when section 2 calls for it.

Give it:

- the bead id and the design context;
- where the changes are;
- the implementer's test results.

Points worth asking about:

- acceptance;
- whether the tests would fail without the change;
- fail-fast and AGENTS.md conventions;
- leftover or dead code;
- unflagged behavior changes;
- stale docs;
- line endings.

## 5. Fix and commit

- **Fix round.** Send the findings to the same implementer with `SendMessage`. Resuming is far
  cheaper than a new agent. Ask for fixes to the blockers and should-fix items, and file follow-up
  beads for the rest. One fix round is normal.
- **Final checks.** Check `git status` for stray files. Compare `git diff --stat` with and without
  `--ignore-cr-at-eol` to catch line-ending churn, since each file keeps its own LF or CRLF.
- **Commit.** Add only this work's paths, never `-A`, so the user's unrelated changes stay out.
  The message says what and why, which models implemented and reviewed it, and the attribution
  line the system provides. No bead ids.
- **Close.** Run `bd close` with a reason. File follow-ups for deferred findings and bugs found on
  the way, with a label and parent.

## Escalating

A cheap model that is struggling costs more than a capable one that isn't. Hand the work one step
up (haiku, then sonnet, then opus) rather than looping, when for example:

- blockers remain after a fix round;
- the implementer guessed at a design question, or got tests green by weakening them;
- the reviewer finds structural problems rather than local defects;
- the implementer couldn't finish.

Start the stronger agent on the current tree with the bead, the findings and the previous report,
and tell it to keep what is sound. If opus also struggles, stop and tell the user what is
unresolved. Mention escalations in your report: they are the evidence for tuning the model choice.

## 6. Report

Report concisely:

- the commits and the beads closed;
- the findings that mattered;
- the follow-ups filed, with their ids;
- anything unverified;
- the token usage per agent.

If the user is experimenting with model choices, say how the implementer and reviewer did.

## Environment notes

Windows with Git Bash: there's no `/tmp`, so use the session scratchpad. dub is the source of truth
for builds. `reggae -b ninja ..` followed by `ninja server` from `build/` is an optional faster dev
build.
