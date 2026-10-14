# AGENTS.md — Confector

This file is written for AI agents working on Confector. It explains what the project is for, why
it is designed the way it is, and how to make changes that fit. Read all of it before making
changes; the reasons matter as much as the rules, because you will meet situations the rules
do not cover.

**Important:** much of the existing code was written by earlier agents and does **not** yet follow
the principles below. When existing code and this document disagree, this document wins. Do not
copy a pattern just because it already exists in the codebase. See "The current state of the code".

---

## What Confector is

Confector is an open-source CI/CD system built around two ideas:

1. **Cost proportional to work.** A CI/CD control plane — deciding what to build, tracking builds,
   serving the UI — sits idle most of the time. It should cost close to nothing while it does. The
   dominant cost of running Confector should be build agents doing real work, not command and
   control. Serverless deployment is the main way to achieve this, but it is a means, not a goal
   in itself.
2. **Never build the same thing twice.** Builds behave like pure functions. Each task declares its
   inputs explicitly; if a task's inputs have not changed, it is not rebuilt and its earlier outputs
   are reused.

### Motivating example

A game project has *internal* builds (development tools enabled) and *external* builds (for end
users). Day to day, only internal builds are needed. At release time, the team wants an external
build of the **same commit** they have been testing — not merely the same branch.

Conventional CI systems force a bad choice: build every variant up front (wasting time on builds
nobody uses) or require a complete set of artifacts before a release can be cut. Confector should
let the external build be produced on demand, from exactly the inputs the tested build used,
rebuilding only what differs. The main mechanism for this is a clear task graph that can be
targeted, and stopped, at any node.

When you are unsure whether a change serves the project, check it against this example.

---

## Goals

- **Explicit inputs.** The task graph has a general notion of *inputs*. Source repositories at a
  specific revision are the primary and most important kind of input, but not the only one.
  *Why:* the whole caching model depends on inputs being declared. An input the system does not
  know about is an input that can silently produce a stale cache hit.
- **Good-faith caching, with an override.** Reusing a result is a best-effort judgment based on
  declared inputs, not a proof. Builds can succeed or fail for reasons the system cannot see, so
  users must be able to re-run a task, and re-running a task invalidates every task downstream of
  it. *Why:* pragmatism. A cache that cannot be overridden turns every undetected input into a
  support problem.
- **Cheap to run.** An idle installation should cost close to nothing.
- **Bring your own backend.** Confector can be deployed on AWS, Google Cloud, or other
  infrastructure without this repository hosting an implementation for every provider. *Why:*
  cheap hosting depends on using whatever services a team already has, and the core project cannot
  maintain adapters for all of them.
- **Open source.**

## Non-goals

Do not add features or abstractions in service of these:

- A hosted SaaS product.
- Compatibility with Jenkins plugins or pipeline syntax.
- Guaranteed hermetic or bit-for-bit reproducible builds. Caching is good faith, not proof.
- Dependence on any particular database, queue, or cloud provider.

---

## Design principles

Each principle comes with the reason behind it. Use the reason to decide cases the principle does
not spell out.

### Separate *what to build* from *how to build it*

Evaluating the graph — which tasks need to run, given their inputs and what is already cached — is
a different concern from executing tasks. Keep them in separate components with a data boundary
between them: evaluation produces data describing the work; execution consumes it.

*Why:* conflating these two was the most damaging mistake in the project's history. It took a long
time to separate graph evaluation from execution, and the build coordinator is still tangled as a
result. If a change makes an executor decide what to build, or makes graph evaluation run or wait
on work, stop and reconsider.

### Separate data from behavior

Prefer plain data structures processed by separate, focused components over objects that bundle
state and behavior. Divide the design along systemic lines (in the spirit of ECS), not along class
hierarchies.

*Why:* the project owner is skeptical of object-oriented design. Plain data is easy to serialize,
hash, store, and send across process boundaries — all of which Confector does constantly — and
behavior kept separate from data is easier to test and replace.

### Name things by role

- Components that *act* are named for what they do: `GraphEvaluator`, `TaskDispatcher`.
- Plain data types are nouns: `BuildPlan`, `TaskResult`.

Avoid vague names like `Manager`, `Handler`, or `Helper`, and avoid naming a component for what it
*is* rather than what it does. *Why:* a name that states the job makes it obvious when a component
starts doing a second job. (Many existing names predate this rule; rename when you redesign a
component, not in unrelated changes.)

### Functional core, imperative shell

Keep decision logic pure: given data in, return data out, with no I/O, persistence, clocks, or
global state. Push side effects — databases, queues, network, file system, processes — to a thin
outer layer that calls the pure core.

*Why:* this is how Confector stays testable and how it reaches serverless deployment. Logic that
receives its state explicitly can run in a long-lived server or in a short-lived function
unchanged. This replaces an earlier, stricter "stateless core" rule that the code never actually
followed.

### Fail loudly

Prefer obvious failures to silent degradation, within reason.

- If required configuration, a plugin context, or a dependency is missing or invalid, throw an
  exception with a clear message immediately. Do not log a warning and continue.
- Do not invent defaults for required settings (for example, a default database connection
  string). A wrong default that "works" hides the real problem.
- Do not write empty `catch` blocks. Do not substitute sentinel values (such as `"unknown"`) for
  data that failed to compute.
- Prefer domain-specific exceptions with diagnostics that point at the cause (for example, the
  exact cycle path in a cyclic graph).
- An intentional optional feature with a sensible default is fine, but document the default where
  it is defined.

*Why:* earlier agents repeatedly added "reasonable" fallbacks that hid serious errors — missing
plugin context, wrong database connection strings, absent artifact directories. Each one cost far
more time to find than a crash would have.

### YAGNI, except at boundaries

Do not build speculative features. But design the interfaces *between* subsystems deliberately —
"interface" in the conceptual sense of a contract, not inheritance.

*Why:* internals are cheap to change; boundaries are not. A little care at a boundary (what data
crosses it, who owns it, what can fail) saves a great deal of rework later.

---

## Invariants

Every change must preserve these. Some are not yet true of the current code; do not make them
less true.

1. **A task's fingerprint is a deterministic function of its identity (project and task) and its
   resolved declared inputs** — nothing else. Upstream task outputs are inputs, so upstream fingerprints feed in
   transitively. Changing any declared input changes the fingerprint. A repository input
   contributes its *pinned revision* (for git, the commit SHA), not its URL or branch. Build
   configuration (steps, parameters, environment) is not part of the fingerprint; see "The input
   model". *(Currently violated: repository revisions do not reach the fingerprint, and build
   configuration does.)*
2. **Graph evaluation does not execute work, and execution does not decide what to build.**
3. **Decision logic is pure; state is passed in explicitly.** No hidden global or mutable singleton
   state in decision logic.
4. **Re-running a task invalidates everything downstream of it.** *(Not yet implemented.)*
5. **Required configuration is never defaulted silently.**

---

## The input model

Decided October 2026 (design record: bead `confector-z7z.13`).

- **Inputs are named and typed.** A task declares a map of named inputs, each with a kind and a
  kind-specific spec. Kinds include *repository* (the primary kind), *value*, and *task output*.
- **Upstream task outputs are inputs.** Dependencies between tasks are declared as task-output
  inputs, and graph edges are derived from them. There is no separate dependency list.
- **A repository input names a repository by id plus a ref selector.** Repositories are defined
  globally or per project. What ref selectors exist, and how a triggering branch binds to them, is
  part of the open "Branches" question.
- **Declared, then resolved, then hashed.** Resolution is its own step: it turns every declared
  input in the whole DAG into a pinned value (branch to commit, and so on) once, when a build
  chain is created, so every task in the chain sees the same revisions. Pinned values can come
  from querying the repository, from the trigger payload, or from an existing chain. Fingerprints
  are computed only from resolved values.
- **Each provider defines its own pinned value.** The core treats it as opaque. For git it is the
  commit SHA alone — not the URL, branch, or checkout path.
- **Build configuration is not an input.** Steps, parameters, and environment describe *how* to
  build, not *what*; put configuration that should drive caching in the repository, where the
  revision covers it. To apply a configuration change to unchanged inputs, re-run the task. Each
  execution result records a hash of the task definition it ran with, so the UI can show that a
  result predates a configuration change. *Why:* a configuration change only fails to take
  effect when the inputs are unchanged, and in that case the user wants explicit control rather
  than automatic invalidation.
- **The task's identity is part of its fingerprint.** Two tasks with identical inputs (an
  internal and an external build of the same commit) must not share cached results.
- **Checkout is explicit.** Inputs are not materialized automatically. A checkout step takes an
  input *by name* — never a URL — and checks out exactly its pinned revision. Steps that fetch
  things outside the input mechanism are allowed but are outside the caching guarantee.

## The caching contract

Decided October 2026 (design record: bead `confector-z7z.1`).

- **A cache hit means** an earlier execution of the same task — same project, same task, same
  resolved declared inputs — *succeeded*, and its declared artifacts still exist.
- **A cache hit does not promise** the same build configuration, worker toolchain or environment,
  network-fetched content, or secrets, nor byte-identical output. Re-running a task is the
  override.
- **Projects never share cache entries.** Task identity in the fingerprint includes the project.
- **The control plane computes cache keys.** Never trust a fingerprint reported by a worker.
- **Results are append-only, looked up by fingerprint.** Never overwrite an earlier result.
- **Only successes are reused.** Failures are recorded but are never cache hits; a re-run can cure
  a failure caused by something outside the inputs, such as a build machine dying.
- **Missing artifacts make a miss, not an error.** If retention removed a result's artifacts, the
  task runs again. (A task that ran but did not produce an artifact a downstream input needs is
  different: that fails loudly.)
- **Each result records the full task definition it ran with**, so it can be inspected and the UI
  can show when a result predates a configuration change.
- **A build chain freezes** its set of tasks, their declared and resolved inputs, and their
  fingerprints. It does **not** freeze build configuration, which is read when a task is
  dispatched. A task deleted from the project after the chain was created fails loudly if asked to
  build; a task added later is not part of the chain.

## What a build is

Decided October 2026 (design record: bead `confector-z7z.14`). A "build" used to conflate three
things; they are now distinct:

- **Build request** — who asked for what: target tasks, intent (build, retry, rerun), trigger and
  its payload, optional pins. Immutable.
- **Build chain** — a snapshot of the whole project DAG: every task's declared inputs, resolved
  inputs, and fingerprint. Immutable once created. This is what the UI calls a *build*; it has a
  canonical per-project number (#123) and, separately, user-editable labels.
- **Task execution** — one run of one task at one fingerprint ("task run" in the UI).
  Append-only and shared across chains; a cache hit is a chain using an execution another chain
  produced.

How they fit together:

- **A request joins or creates a chain.** Resolve the whole DAG and fingerprint it. If the project
  already has a chain with the same snapshot, the request joins it; otherwise a new chain is
  created. The request runs its targets and their upstream tasks, never downstream ones.
- **Any task in a chain can be built later** against the chain's pinned inputs, without
  re-resolving. This is how an external build is made from exactly what was tested.
- **Chain state is derived, never stored**, from the chain's requests and the executions for its
  fingerprints.
- **A configuration change does not trigger a rebuild** of a chain whose task already succeeded;
  re-run the task to apply it.
- **Retry and rerun are different.** *Retry* runs a failed or cancelled task again in the same
  chain. *Rerun* forces a succeeded task to run again; it creates a new chain from that task
  forward, whose parent is the original.
- **Cancel means stop**, even when the execution is shared with other chains. Cancelling a task
  also cancels the tasks downstream of it. Before acting, the UI shows everything that will be
  cancelled — including other chains that share the execution — and offers to cancel upstream
  tasks that are still running too.

---

## Open questions

These are **undecided**. Do not settle them implicitly by writing code that assumes an answer. If
your task depends on one, stop and ask the project owner. When one is decided, update this file.

- **Branches.** Branches should be a first-class concept: branch filters on triggers, which
  branches are visible, how a triggering branch binds to repository inputs, and pull request
  builds. Not yet designed (bead `confector-z7z.19`).
- **Re-run semantics.** Leading idea: a re-run is itself an input (a "triggering intent") to the
  re-run task, so its fingerprint and every downstream fingerprint change through normal
  transitive hashing. Undecided: which result later builds with the same inputs should reuse.
  (Retry vs. rerun and cancellation are decided; see "What a build is".)
- **First-class releases.** Possibly unnecessary given node-level targeting; likely just a label
  on a build chain.
- **Cross-project dependencies.** Deferred, but wanted eventually (bead `confector-z7z.21`).
  Preferred shape: an input kind that pins to another project's chain, not chains that span
  projects.
- **Plugin architecture.** Likely direction: formally separate *structural backends* (state store,
  queue, artifact storage, scheduler, compute — exactly one each, chosen at deployment) from
  *extensions* (build step types, version-control integrations — zero or more). Build steps,
  including repository checkout, would become separate executables invoked by the runner.
  Not yet designed in detail.
- **Coordinator redesign.** The build coordinator mixes in-memory and persisted state; the likely
  direction is an event-driven state machine over persisted state.
- **Authentication and trust.** There is currently no authentication. Undecided: worker and user
  auth, secret delivery, and keeping untrusted builds from writing to a shared cache.
- **Pipeline definitions as code.** Tasks are currently defined in the web UI and stored in the
  database; whether they should live in the repository is undecided.
- **Build system.** Both `dub.json` and `reggaefile.d` define the build; one will be chosen.

---

## The current state of the code

Be aware of these so you do not spread them:

- **The build coordinator** (`source/confector/server/orchestrator/coordinator.d`) mixes graph
  evaluation with dispatch, splits state between memory and the database, and contains silent
  fallbacks. It is slated for redesign. Make minimal changes there.
- **The data model** (`source/confector/plugin_api/model.d`) has accumulated aliases: several ways
  to specify a repository, artifact identity via `id`/`name`/`path`, multiple fields describing a
  build step. **Do not add another alias.** If a representation is wrong, change it and update its
  callers.
- **There are no external consumers.** Do not add "backward compatibility" shims, re-export
  modules, or deprecated fields. Change the code and its callers together.
- **`PluginRegistry` is a global singleton** used from core logic. Do not add new dependencies on it;
  pass what you need explicitly.
- **In-memory test fakes do not always behave like the real backends.** Make fakes match the real
  behavior, not the other way around.

### Orientation

- `source/confector/core/` — graph construction and evaluation, fingerprinting, trigger matching,
  plugin registry.
- `source/confector/plugin_api/` — data types and interfaces shared with plugins.
- `source/confector/runner_core/` — executes a single task on a worker.
- `source/confector/runner/` — the runner command-line program.
- `source/confector/server/` — web server, API, dashboard, and build coordinator.
- `source/confector/config/` — configuration types.
- `plugins/` — plugins by category (step definitions and executors, workers, artifact storage,
  state storage, queue, scheduler).
- `views/`, `public/` — web UI templates and static assets.

Explore the code for anything more specific; file-level details change too often to list here.

---

## How to work in this repository

- **Ask when the intent is unclear.** If a request could be read more than one way, or touches an
  open question, ask instead of guessing. An agent's guess written into code or documentation
  tends to be mistaken later for a decision.
- **Do not write your own opinions into this file or other design documentation.** Propose changes
  to the project owner instead. This file should state the project's intent, not an agent's.
- **Change the existing thing, do not add a parallel one.** Adding a new field, function, or module
  alongside an old one that does nearly the same thing is how the data model got its aliases.
- **Test the pure core.** Graph evaluation, fingerprinting, trigger matching, and similar decision
  logic need unit tests. Because the logic is pure, tests should not need databases or servers.
- **D conventions.** Use `immutable`, `const`, `pure`, and `@safe` / `@trusted` where they apply.
  Use `std.digest.sha` for hashing and `vibe.data.json` for serialization.

## Build and test

Subpackage names are prefixed with `confector-`. From the repository root:

- Run core unit tests: `dub test :confector-core`
- Other subpackages follow the same pattern, for example `:confector-server` or
  `:confector-runner-core`; check each subpackage's `dub.json` for its exact name.

A `reggaefile.d` also exists; see "Build system" under open questions.
