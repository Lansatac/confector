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
4. **Re-running a task invalidates everything downstream of it**, in every chain that shares its
   inputs. *(Not yet implemented.)*
5. **Required configuration is never defaulted silently.**

---

## The input model

Decided October 2026 (design record: bead `confector-z7z.13`).

- **Inputs are named and typed.** A task declares a map of named inputs, each with a kind and a
  kind-specific spec. Kinds include *repository* (the primary kind), *value*, and *task output*.
- **Upstream task outputs are inputs.** Dependencies between tasks are declared as task-output
  inputs, and graph edges are derived from them. There is no separate dependency list.
- **A repository input names a repository by id plus a ref selector.** Repositories are defined
  globally or per project. Ref selectors are described under "Branches".
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
- **A build chain freezes** its set of tasks and their declared and resolved inputs. It does
  **not** freeze fingerprints, which are computed from the chain plus the current rerun
  generations (see "Re-running a task"), or build configuration, which is read when a task is
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
  chain, at the same fingerprint. *Rerun* says a succeeded result should not be used anymore; see
  below.
- **Cancel means stop**, even when the execution is shared with other chains. Cancelling a task
  also cancels the tasks downstream of it. Before acting, the UI shows everything that will be
  cancelled — including other chains that share the execution — and offers to cancel upstream
  tasks that are still running too.

## Re-running a task

Decided October 2026 (design record: bead `confector-z7z.15`). A rerun means "there was a
problem with that build; don't use it anymore." Where cases are ambiguous, choose what is least
surprising given that meaning.

- **A rerun is an input.** Each task has a *rerun generation*, starting at 0 and keyed by the
  task's fingerprint without it (its *base*). Rerunning increments the generation, recorded durably
  and append-only. The fingerprint hashes the base and the generation, so the rerun task and
  everything downstream of it get new fingerprints through ordinary transitive hashing.
- **Generations are shared, not per chain.** A rerun updates the chain it was requested in — no
  new chain is created — and every other chain that shares that task's inputs. The rerun prompt
  lists the affected chains. Each chain keeps a history of reruns; superseded executions remain
  visible.
- **A rerun must pass.** Downstream tasks wait for the new generation to succeed; a failed rerun
  blocks rather than falling back to the earlier success. (An explicit "accept the previous
  result" override may come later, bead `confector-z7z.22`.)
- **Stale work in flight is cancelled by default.** Downstream tasks already running from the
  superseded result are listed in the rerun prompt and cancelled unless the user chooses
  otherwise.
- **Reuse means the latest success for a fingerprint.** Old and new generations never share a
  fingerprint, so this only matters for races.

## Coordinating builds

Decided October 2026 (design record: bead `confector-z7z.2`).

- **Three components, split along what-versus-how.** An *input resolver* turns a request into a
  chain (resolving inputs, finding or creating the chain). A pure *chain evaluator* takes a chain,
  its requests, the rerun generations, and the executions for its fingerprints, and returns each
  task's state plus the fingerprints that need an execution. An *execution dispatcher* claims each
  needed fingerprint, records the execution, and enqueues it.
- **All state is persisted; nothing lives only in memory.** At most one active execution per
  fingerprint is enforced with compare-and-set in the store, not with locks. *Why:* multiple
  instances and serverless deployment must work, and a restart must lose nothing.
- **Level-triggered, not event-sourced.** Every input — a trigger, a completion, a cancel, a
  rerun, an expired lease — only signals that something changed. The handler re-evaluates the
  affected chains and dispatches whatever is missing. Every step is idempotent, so a crash between
  saving state and enqueuing work is repaired by the next evaluation.
- **The control plane owns fingerprints.** Work orders carry an execution id; a worker's
  completion names that id, and the fingerprint comes from the control plane's own record.
- **Infrastructure failures retry automatically; task failures do not.** A lost worker or expired
  lease counts as an attempt, up to an admin-configured limit tracked on the execution. A task
  that fails is retried only when a user asks.
- **Expired leases are found by a sweep that runs only while work is active.** The sweep is
  registered with the scheduler when executions are active and removed when none are, keeping an
  idle installation free. Scheduler calls may be duplicated or missed, so every dispatch and
  completion re-asserts whether the sweep should exist.
- **Chain state is computed when read.** Add a cached summary only if it proves too slow.

## Branches

Decided October 2026 (design record: bead `confector-z7z.19`).

- **Branches are tracked records**, independent of any one version-control system: repository,
  ref name, kind (branch, tag, or change request), head revision, and whether the branch still
  exists. Git branches, Plastic branches, and Perforce streams all map onto them. Webhooks and
  polling keep them current; a deleted branch is hidden and stops triggering, but its history
  stays.
- **A branch spec chooses which branches are tracked** — include/exclude patterns such as
  `+:*` and `-:experimental/*`. It is set on the repository and can be overridden per project.
- **Builds carry a branch context.** A request records the branch that triggered it, and the
  branch is part of a build chain's identity, so each branch has its own build history. Nothing is
  built twice, because task executions are shared across chains.
- **Repository inputs bind to branches through ref selectors:** a fixed ref (`main`); *follow the
  trigger*, when the trigger came from this input's repository; or *same name with a fallback*,
  for feature branches that span several repositories.
- **Trigger rules filter on event kind** (push, tag, change request) **and branch patterns.**
- **A pull request is a branch of kind *change request*,** so filters and selectors apply to it
  unchanged; code reviews and shelves in other systems map onto the same kind. Each project
  chooses whether to build a change request's head, its merge result, or both, as far as the
  provider supports.
- **A chain carries the trust level of its request.** See "Authentication and trust".
- **Deferred:** cancelling superseded builds when a newer push arrives, and reporting build status
  back to the hosting service.

## Authentication and trust

Decided October 2026 (design record: bead `confector-z7z.10`). The main threat today is
unauthorized access to the server by anyone outside a closed team; untrusted contributors are
handled by trust levels.

- **Every endpoint is authenticated, and the server fails closed.** It refuses to start without
  an authenticator configured; never add an unauthenticated route or a default credential.
- **People sign in through someone else's identity provider.** Authentication is a backend: an
  authenticator turns a request into an identity with roles, or nothing. First an authenticating
  proxy (such as oauth2-proxy) that sets identity headers plus a shared secret; later, signed
  proxy headers and a built-in OpenID Connect login. There are no built-in password accounts —
  only a bootstrap admin token and API tokens. Group-to-role mapping is configuration, not
  per-provider code.
- **Roles are global for now:** admin, member, viewer.
- **Workers hold one token per execution.** It is signed, short-lived, and carried in the work
  order, and it allows only what that execution needs: reporting its own logs and completion,
  uploading its own artifacts, downloading the artifacts its inputs name, and fetching its
  secrets.
- **Webhooks and scheduler callbacks are verified** — by the provider's signature, or by a secret
  the scheduler sends.
- **Secrets come from a secret store backend at run time.** Tasks declare secrets by name; the
  runner fetches the values with its execution token. Values never appear in work orders, queue
  messages, database records, or logs, and they are not inputs (not fingerprinted).
- **Pull requests from forks are untrusted.** Following GitHub's model, untrusted builds wait for
  a member's approval, get no secrets, may reuse trusted cache entries, and store their own
  results in a scope tied to their change request that trusted builds never use. Pull requests
  from branches in the repository itself are trusted.
- **Plugins are never loaded at runtime from a request.** (A previous endpoint that did this was
  removed.)
- **Eventual goal:** configurable worker isolation for untrusted builds (separate worker pools or
  a fresh worker per execution), bead `confector-z7z.27`.

## Backends and extensions

Decided October 2026 (design record: bead `confector-z7z.3`).

- **You pick and choose components when setting up the server.** Every backend is chosen by
  deployment configuration at startup; switching one is a configuration change and a restart,
  never a rebuild. *Why:* the owner prefers separate programs over "bring your own `main.d`" as
  the way to make Confector composable.
- **How a backend is provided depends on the backend:**
  - The state store, queue, scheduler, and authenticator are **compiled in** — they are on the
    hot path or security-critical. One binary contains every first-party implementation
    (including an embedded single-node store, so a home build server needs no database server).
  - The artifact store, log store, secret store, and compute are **extension kinds**. Common
    implementations are built in using the same protocol — local and S3-compatible artifact
    storage; build logs in the state store, S3, or CloudWatch; file secrets; local-process
    compute. Anyone can add others — Azure Blob, Key Vault, a new cloud's machines — in any
    language, without a rebuild.
- **Nothing is loaded into the process at runtime.** No D shared libraries, no plugin registry.
  Construct a typed set of backends at startup and pass it explicitly. *Why:* runtime library
  loading in D is fragile, a global registry hides state from the core, and an endpoint that
  loaded libraries on request was a remote-code-execution hole.
- **Misconfiguration stops startup.** A missing or invalid backend is a startup error, not a
  warning.
- **Artifacts remember which store holds them,** so switching artifact stores keeps old artifacts
  readable while the previous store stays configured; retiring it turns them into cache misses.
- **Compute pools are admin data.** Pools (compute provider, capacity, labels, executor types)
  are edited in the admin UI without a restart.
- **Extensions are a manifest plus a program,** used where the set is open-ended: version control
  providers, build steps, status reporters, and the three extension-kind backends above. The
  manifest declares a JSON Schema for the extension's configuration, so the UI renders its forms
  without running its code. Behavior is JSON in, JSON out, over one of three transports: run a
  local program (stdin/stdout), call a URL, or a built-in implementation of the same protocol.
  Extensions can be written in any language and added without a rebuild.
- **Artifact bytes never pass through an extension.** An artifact-store extension only hands out
  presigned URLs and deletes; runners transfer data directly.
- **Build logs live in the log store, never line by line in the state store.** Runners write
  directly where the store allows it, and the UI reads by cursor. Secrets are masked on the
  runner, before log lines leave it.
- **Installing an extension is running code:** admin-only, pinned by checksum. Running out of
  process isolates crashes, not security.
- **Git is built in;** supporting another git host's webhooks is a data file, not code.
- **Deferred:** a deployment builder for third-party backends (bead `confector-z7z.32`) and
  sandboxed WebAssembly extensions (bead `confector-z7z.33`).

## Build steps

Decided October 2026 (design record: bead `confector-z7z.6`).

- **A step is a program.** The runner validates the step's configuration against its manifest's
  schema, runs the program, and sends a JSON request on stdin.
- **stdout and stderr are the log; structured events go to a file.** Events (progress,
  annotations) are JSON lines appended to the file named by `CONFECTOR_EVENTS`. *Why:* any script
  or existing tool is then a valid step without knowing the protocol.
- **Exit code 0 is success.** A crashing step fails the task; only a lost runner counts as an
  infrastructure failure.
- **Stopping is graceful, then total.** On cancel or timeout the runner asks the step to stop,
  waits a grace period, then kills the whole process tree — build tools spawn helpers that
  outlive their parent.
- **Workspaces start clean.** The runner stages the upstream outputs the task's inputs name,
  runs the steps in order, and collects declared outputs. A task can opt into *named caches* —
  directories that persist on a worker between runs of that task (for example Unity's `Library`).
  Caches are outside the fingerprint.
- **Steps inherit the worker's environment**, plus `CONFECTOR_*` variables and the task's own;
  Confector's credentials are always stripped. Secrets arrive as environment variables or files
  named by the task.
- **Steps are versioned.** A task names a step and a version range; the exact version that ran is
  recorded with the execution. Runners fetch step programs from the artifact store by checksum.
- **Bash, PowerShell, and checkout are built in** and follow the same contract.

## Serverless constraints

The control plane must be able to run as short-lived functions (for example AWS Lambda), which is
how an idle installation costs close to nothing. Code that breaks these rules works on a single
server and fails silently in a function.

- **No background threads or timers in the server.** All work happens in response to a request
  or a scheduler call; a function is frozen between requests. A scheduler backend may run its
  own thread (the local one does), but it only makes HTTP calls like any other scheduler.
- **No long-lived connections.** Live views in the UI poll.
- **Keep startup cheap.** Building the backends from configuration happens on every cold start.
- **Control-plane extensions should not assume a writable disk or installed language runtimes.**
  In a function, prefer the URL transport; local programs must be self-contained.
- **Runners never run as functions.** Builds outlast function time limits; runners live in
  compute pools.

---

## Open questions

These are **undecided**. Do not settle them implicitly by writing code that assumes an answer. If
your task depends on one, stop and ask the project owner. When one is decided, update this file.

- **First-class releases.** Possibly unnecessary given node-level targeting; likely just a label
  on a build chain.
- **Cross-project dependencies.** Deferred, but wanted eventually (bead `confector-z7z.21`).
  Preferred shape: an input kind that pins to another project's chain, not chains that span
  projects.
- **Pipeline definitions as code.** Tasks are currently defined in the web UI and stored in the
  database; whether they should live in the repository is undecided.
- **Build system.** Both `dub.json` and `reggaefile.d` define the build; one will be chosen.

---

## The current state of the code

Be aware of these so you do not spread them:

- **The build coordinator** (`source/confector/server/orchestrator/coordinator.d`) mixes graph
  evaluation with dispatch, splits state between memory and the database, and contains silent
  fallbacks. It is being replaced (see "Coordinating builds"; bead `confector-z7z.23`). Make
  minimal changes there.
- **The data model** (`source/confector/plugin_api/model.d`) has accumulated aliases: several ways
  to specify a repository, artifact identity via `id`/`name`/`path`, multiple fields describing a
  build step. **Do not add another alias.** If a representation is wrong, change it and update its
  callers.
- **There are no external consumers.** Do not add "backward compatibility" shims, re-export
  modules, or deprecated fields. Change the code and its callers together.
- **`PluginRegistry` is a global singleton** used from core logic, and plugins are still loaded as
  shared libraries. Both are being removed (see "Backends and extensions"; bead
  `confector-z7z.31`). Do not add new dependencies on them; pass what you need explicitly.
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
