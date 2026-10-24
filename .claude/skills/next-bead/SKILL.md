---
name: next-bead
description: Pick the next ready bead (optionally filtered by a label such as m1, or given as ids), bundling small related beads, then have a cheap sub-agent implement it and a more capable one review it, fix findings, verify, commit and close. Use when asked to work the next bead, the next batch, or to "implement and review" beads.
---

# next-bead

Arguments (optional): a label (`m1`), bead ids, or a theme. With none, use the project's current
milestone label. You are the orchestrator: you select, brief, verify, commit and close. Sub-agents
implement and review. Keep your own context small: ask agents for concise reports.

## 1. Select

- `bd ready --label <label>`, then `bd show` the likely candidates. Skip epics and design beads.
- Prefer, in order: P0/P1; unblocks the most other beads; dependency order; cheap to verify.
- A bead that needs an owner design decision (the notes or description say so, or the right answer
  is genuinely ambiguous) is not implemented: surface the question to the user with your
  recommendation and pick another bead.

### Bundling

Bundle beads into one implementer run when they are **small** and **related** (same files, component
or design context, or one fixes the other's bug), at most three per bundle. Run them one at a time in
a single agent, verifying each before the next. Do not bundle large beads, unrelated areas, or
risky storage, security or concurrency work, which gets its own bundle and review. The point is to
pay for context loading once.

Triage first: some beads are already fixed or moot. The agent must check that the problem still
exists in current code before changing anything, and say so in the bead notes if not.

## 2. Choose the models

Default to the cheapest agent that can do the job; the reviewer is always at least one step stronger.

| Work | Implementer | Reviewer |
|---|---|---|
| Well specified, self-contained, tests are the spec, few files (bug fixes, small features, plumbing, config, docs) | `implementer` (haiku) | sonnet |
| Multi-file but well specified: wiring, audits, interface changes with clear acceptance | `implementer-medium` (sonnet) | opus if it touches correctness-critical code, else sonnet |
| Concurrency, CAS or crash-recovery protocols, security design, cross-cutting refactors, anything needing design judgment | `implementer-medium` first; `implementer-strong` (opus) only on escalation | opus |

**Every first implementation attempt starts with at most `implementer-medium`.** Never start a bead
with `implementer-strong`, however hard it looks: use `implementer-medium` and the strongest
reviewer, and escalate to `implementer-strong` only under "Escalating" below. The one exception is
an explicit instruction from the user to use the strong implementer.

Pass `model` on the Agent call to override an agent's default. When a cheap implementer's first
attempt shows it is out of its depth (it guesses at design, or the reviewer finds structural
problems), switch to `implementer-strong` for the rework instead of looping.

## 3. Brief the implementer

Use `subagent_type: implementer` or `implementer-medium` for the first attempt (`implementer-strong`
only for an escalation). The prompt must contain: bead ids; the
files or area; "read AGENTS.md first"; `bd show <id>` and, for design context, the `design` field of
the relevant closed design beads (`bd show <id> --json`); the acceptance criteria; what is out of
scope; the verification commands; and the standing rules: no git write commands, do not close or
create beads, no bead ids or bead details in code, comments, test names, error messages or commit
messages (beads are local only), record notes with `bd comments add <id> "..."`, report concisely
(files, design choices, deferred items, exact test results, anything unverified).

### Bead writes by agents

`bd` is built for concurrent use and works from a worktree (it finds the main checkout's database), so
agents may read beads anywhere. Agents (implementers and reviewers) record notes only with
`bd comments add`: each comment is a new record, so concurrent agents cannot overwrite each other.
Fields that are replaced whole (`--notes`, `--description`, `--design`, `--acceptance`), status
changes, `bd close` and `bd create` are the orchestrator's: a read-modify-write of those fields from
two writers loses an update. When a comment holds lasting context, fold it into the notes or design
field yourself.

Run agents in the main tree one at a time. For parallel agents use one git worktree each and only
parallelize beads that share no files (dub builds collide in one tree). Create them yourself in the
worktree folder the user has named, or ask where if they have not (`git worktree add -b wt-<name>
<folder>/<name> HEAD`; keep the path short on Windows), tell the agent to work only inside that
folder, and remove the worktree and branch after applying the result (`git worktree remove --force`,
`git branch -D`). The harness's `isolation: "worktree"` does not let you choose the folder. Apply a worktree result to the main tree by `git add -N .` in the worktree, `git diff
--binary` into the scratchpad directory, and `git apply --3way` in the main tree (expect conflicts in
files another bead also touched, such as the README; resolve them by keeping both sides). Then run the
tests and build in the main tree before committing.

## 4. Review

Always review, with a stronger model than the implementer, via `subagent_type: reviewer`. The
reviewer defaults to sonnet, which is right for haiku `implementer` work; pass `model: opus` for the
opus rows of the table. Give it the
bead id, the design context, and where the changes are (working tree or worktree path). It is
read-only and reports ranked findings with file:line, a failure scenario and a severity. Ask it
specifically to check: acceptance criteria; whether tests fail without the change; fail-fast and
AGENTS.md conventions; leftover or dead code; behavior changes the implementer did not flag;
stale docs and references; line endings.

## 5. Fix, verify, commit

- Send the findings to the same implementer with `SendMessage` (resuming is far cheaper than a new
  agent). Ask for fixes for blockers and should-fix items; defer the rest by filing follow-up beads.
  One fix round is normal. See "Escalating" below for when to hand off instead of looping.
- Do not trust reports. Run the tests yourself for every affected package (names are in each
  `dub.json`: `dub test :core`, `:server`, `:plugin-api`, `:runner-core`, plugin packages) and
  `dub build`; `dub test :server` overwrites the server exe, so build again afterward. Check
  `git status` for stray files and `git diff --stat` against `--ignore-cr-at-eol` for line-ending
  churn (each file keeps its own LF or CRLF).
- Commit only the files for this work (`git add <paths>`; never `-A`): leave the user's unrelated
  uncommitted changes alone. If `.git/index.lock` exists, confirm no git process is running before
  removing it. Message: what and why, which models implemented and reviewed when that
  is useful, plus the attribution line the system provides. No bead ids or bead details in the
  message (beads are local only).
- `bd close <ids> --reason "..."`. Create follow-up beads for deferred findings and real bugs found
  on the way (with a label and parent), and add notes where a later bead must know something.

## Escalating

A cheap model that is struggling costs more than a capable one that is not. Hand the work to the
next model up (haiku, then sonnet, then opus) instead of continuing when any of these holds:

- The reviewer still reports blockers, or the same should-fix finding, after **one** fix round.
- The implementer's first report shows it guessed at a design question, left tests failing, weakened
  or deleted existing tests to get green, or changed behavior beyond the bead.
- The reviewer finds structural problems (wrong layering, a broken protocol or consistency rule), not
  just local defects.
- The implementer ran out of its own context or budget, or reports it could not finish.

Do not run a second fix round with the same model. Do not restart from scratch: start the stronger
agent on the current working tree (or worktree) with the bead, the reviewer's findings, and the
implementer's report, and tell it to keep what is sound and rework what is not. Resuming the weaker
agent with `SendMessage` is only for local, clearly described fixes. If the strongest model also
needs a second round, stop and report to the user what is unresolved. Mention escalations in the
final report: they are the evidence for tuning the model table.

## 6. Report

Concisely: the commits, beads closed, findings that mattered, deferred follow-ups (with ids), anything
unverified, and the token usage per agent from the completion notifications. If the user is
experimenting with model choices, say how the cheap implementer and the reviewer performed.

## Environment notes

Windows with Git Bash; there is no `/tmp`, use the session scratchpad. dub is the source of truth for
builds (`reggae -b ninja ..` then `ninja server` from `build/` is an optional faster dev build).
