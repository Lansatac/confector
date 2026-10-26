# AGENTS.md — Confector

This file is written for AI agents working on Confector. It explains what the project is for, why
it is designed the way it is, and how to make changes that fit. Read the design principles, the invariants and
the sections your change touches; the reasons matter as much as the rules, because you will meet
situations the rules do not cover.

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
- **Bring your own backend.** Confector can be deployed on AWS, Google Cloud, or other
  infrastructure without this repository hosting an implementation for every provider. *Why:*
  cheap hosting depends on using whatever services a team already has, and the core project cannot
  maintain adapters for all of them.

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

*Why:* conflating these two was the most damaging mistake in the project's history. If a change
makes an executor decide what to build, or makes graph evaluation run or wait on work, stop and
reconsider.

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
unchanged.

### Fail loudly

Prefer obvious failures to silent degradation, within reason.

- If required configuration, a backend setting, or a dependency is missing or invalid, throw an
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

### Prefer message passing to locks

Coordinate concurrent work by passing messages, not by sharing mutable state behind mutexes.
State that must be shared across processes lives in the state store and is changed with
single-document compare-and-set. State that must be shared inside a process is owned by a single
task (an actor) that other code sends messages to. Do not add mutexes; if one seems necessary,
raise it as a design question first.

*Why:* the owner prefers an actor model. It also matches the coordination design: correctness
comes from compare-and-set and level-triggered re-evaluation, which hold across several server
instances, whereas an in-process lock excludes nothing between instances.

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
   model".
2. **Re-running a task invalidates everything downstream of it.**

---

## The input model

- **Inputs are named and typed.** A task declares a map of named inputs, each with a kind and a
  kind-specific spec. Kinds include *repository* (the primary kind), *value*, and *task output*.
- **Upstream task outputs are inputs.** Dependencies between tasks are declared as task-output
  inputs, and graph edges are derived from them. There is no separate dependency list.
- **A repository input names a repository by id.** Repositories are defined globally or per
  project. An input may carry a *branch filter* (which refs the task may be built from) and a
  *default ref spec*, but it does not choose the ref: the trigger or request does (see
  "Branches"), and the default applies only when they say nothing.
- **Declared, then resolved, then hashed.** Resolution is its own step: it turns repository
  inputs into pinned values (ref to revision), each distinct repository and ref once. A request
  records a pin for every repository and ref it binds, taken from the pins supplied with it (the
  trigger payload or a user), else from its chain, else by querying the repository. Fingerprints
  are computed only from resolved values.
- **Each provider defines its own pinned value.** The core treats it as opaque. For git it is the
  commit SHA alone — not the URL, branch, or checkout path.
- **Build configuration is not an input.** Steps, parameters, and environment describe *how* to
  build, not *what*; put configuration that should drive caching in the repository, where the
  revision covers it. To apply a configuration change to unchanged inputs, re-run the task.
  *Why:* a configuration change only fails to take effect when the inputs are unchanged, and in
  that case the user wants explicit control rather than automatic invalidation.
- **The task's identity, project and task, is part of its fingerprint.** Two tasks with
  identical inputs (an internal and an external build of the same commit), or the same task in
  two projects, never share cached results.
- **Checkout is explicit.** Inputs are not materialized automatically. A checkout step takes an
  input *by name* — never a URL — and checks out exactly its pinned revision. Steps that fetch
  things outside the input mechanism are allowed but are outside the caching guarantee.

## The caching contract

- **A cache hit means** an earlier execution of the same task — same project, same task, same
  resolved declared inputs — *succeeded*, and its declared artifacts still exist.
- **A cache hit does not promise** the same build configuration, worker toolchain or environment,
  network-fetched content, or secrets, nor byte-identical output. Re-running a task is the
  override.
- **Results are append-only, looked up by fingerprint.** Never overwrite an earlier result.
- **Only successes are reused.** Failures are recorded but are never cache hits; a re-run can cure
  a failure caused by something outside the inputs, such as a build machine dying.
- **Missing artifacts make a miss, not an error.** If retention removed a result's artifacts, the
  task runs again. (A task that ran but did not produce an artifact a downstream input needs is
  different: that fails loudly.)

## What a build is

A "build" used to conflate three things; they are now distinct:

- **Build request** — who asked for what: target tasks, intent (build, retry, rerun), trigger and
  its payload, the ref each repository input is bound to, the pin of every repository and ref
  those bindings use, and the project definition it runs with. Immutable, and evaluable from
  itself.
- **Build chain** — one build: the requests made for it and an index of their pins (for every
  repository and ref, its revision). A chain never holds two revisions of one ref, so a task
  added later builds from the same revision as the tasks before it. It holds no tasks or edges.
  Pins only grow and never change once set. A *headline ref* groups chains into a history. This
  is what the UI calls a *build*; it has a canonical per-project number (#123) and, separately,
  user-editable labels.
- **Task execution** — one run of one task at one fingerprint ("task run" in the UI).
  Append-only and shared across chains; a cache hit is a chain using an execution another chain
  produced.

How they fit together:

- **A request joins or creates a chain.** Read the current definition and resolve the inputs it
  needs. If the project already has a chain whose pins agree with every value the request resolved
  (same ref and same revision), the request joins it, adding any pins the chain lacks;
  otherwise a new chain is created. The request runs its targets and their upstream tasks, never
  downstream ones.
- **A new chain is a snapshot.** Creating a chain binds every repository input of the current
  definition, not only those the request's tasks use, by the creating request's refs and the
  inputs' defaults, and pins each of those refs. A build's number means the code as of when it
  was made. If any of those refs cannot be bound or resolved, the request fails and no chain is
  created.
- **A chain remembers how its inputs were bound.** It records the ref each repository input was
  first bound to, by the snapshot or by a later request. On an existing chain, an input the
  request names no ref for binds to the chain's ref, and only an input the chain has never bound
  falls back to the input's default.
- **Any task in today's definition can be built later for a chain**, against the chain's pins.
  This is how an external build is made from exactly the source that was tested, including with
  a task added after the chain was created. A ref the chain lacks (an input added to the
  definition later, or bound to another ref) is resolved when first needed and then kept. A
  task no longer in the definition is simply not offered; its history stays.
- **Binding an input to another ref adds a pin.** A later request on a chain may bind an input
  the chain has already built to a different ref; the chain then holds a pin for each ref.
- **The request is the unit of evaluation.** Each request is evaluated on its own: its graph is
  its targets and their upstream tasks in its own definition, fingerprinted against its own
  pins and the current rerun generations. Requests on one chain are never merged; two requests
  that need the same fingerprint share its execution.
- **Request state is derived from authoritative inputs**: the request, the ledgers and
  executions for its fingerprints, and the rerun generations. A small mutable *request state* document per request holds whether it is still
  open, its cached task states and its outcome; it can always be rebuilt from those inputs.
- **What a chain shows is derived for display**: the union of its requests' states (with no
  request open, today's definition over its pins). It is never an input to a decision. An old
  chain's view can change when the definition changes; what actually ran stays in the execution
  records.
- **Retry and rerun are different.** *Retry* runs a failed or cancelled task again in the same
  chain, at the same fingerprint. *Rerun* says a succeeded result should not be used anymore; see
  below.
- **Cancel means stop**, even when the execution is shared with other chains. Cancelling a task
  also cancels the tasks downstream of it. Before acting, the UI shows everything that will be
  cancelled, including other chains that share the execution.

## Re-running a task

A rerun means "there was a problem with that build; don't use it anymore." Where cases are ambiguous, choose what is least
surprising given that meaning.

- **A rerun is an input.** Each task has a *rerun generation*, starting at 0 and keyed by the
  task's fingerprint without it (its *base*). Rerunning increments the generation, recorded durably
  and append-only. The fingerprint hashes the base and the generation, so the rerun task and
  everything downstream of it get new fingerprints through ordinary transitive hashing.
- **Generations are shared, not per chain.** A rerun updates the chain it was requested in — no
  new chain is created. How far it reaches into other chains that share the task's inputs is an
  open question (see "How far a rerun reaches"); the rerun prompt lists the affected chains.
  Each chain keeps a history of reruns; superseded executions remain visible.
- **A rerun must pass.** Downstream tasks wait for the new generation to succeed; a failed rerun
  blocks rather than falling back to the earlier success.
- **Stale work in flight is cancelled by default.** Downstream tasks already running from the
  superseded result are listed in the rerun prompt and cancelled unless the user chooses
  otherwise.

## Coordinating builds

*Principle:* the fewest moving parts that keep the caching contract. Correctness rests on the
store guarantees in "Backend interfaces"; liveness rests on a periodic sweep, not on
subscriptions.

- **Split along what-versus-how.** An *input resolver* turns a request into a chain (resolving
  inputs, finding or creating the chain). A pure *request evaluator* takes one request (with its
  pins), its definition, the rerun generations and the ledgers of its fingerprints, and
  returns each task's state plus the fingerprints that need an execution. Each needed
  fingerprint is claimed by creating its active execution in the ledger; a worker that asks for
  work is handed one (see "Workers and capacity").
- **All state is persisted; nothing lives only in memory.** Each fingerprint has a *ledger*
  document, read by id, holding its active execution (at most one), its latest success, and its
  latest stopped execution with a sequence number. At most one active execution per fingerprint
  is enforced with compare-and-set on the ledger, not with locks. *Why:* multiple instances and
  serverless deployment must work, and a restart must lose nothing.
- **The active execution lives in the ledger.** Claiming it, starting it, extending its lease and
  expiring it are each one compare-and-set on one document. When it ends, an immutable execution
  record is written and then folded into the ledger; whoever next reads the ledger completes a
  fold left half-done. *Why:* every extra document an execution's state is split across adds a
  crash window and a repair path.
- **Level-triggered, not event-sourced.** A trigger, a completion or an expired lease only means
  "something changed"; the handler re-evaluates the open requests it may affect and claims
  whatever is missing. Every step is idempotent, so a crash between two writes is repaired by the
  next evaluation.
- **When an execution ends, the open requests of its project are re-evaluated.** Completion,
  failure, lost lease and cancel all finish the execution, fold the result into the ledger, and
  then re-evaluate that project's open requests. If that step is lost, the sweep does it.
- **Ordering uses sequence numbers, not clocks.** Whether a failure settles an earlier request is
  decided by the ledger's sequence numbers, never by comparing timestamps written by different
  instances.
- **The control plane owns fingerprints.** Work orders carry an execution id; a worker's
  completion names that id, and the fingerprint comes from the control plane, never the worker.
- **The active execution owns its lease.** A running execution records when its lease expires and
  which attempt holds it; the worker's heartbeat extends the lease. Heartbeats and completions
  from a superseded attempt are rejected.
- **Infrastructure failures retry automatically; task failures do not.** An expired lease counts
  as an attempt, up to an admin-configured limit tracked on the execution. A task that fails is
  retried only when a user asks.
- **A task that cannot be dispatched fails its request** with the error recorded, rather than
  being retried on every sweep. The user fixes the cause and retries.
- **The sweep runs on a fixed schedule.** One scheduler entry, always registered: each run expires
  lost leases and re-evaluates every open request. An
  idle run is one cheap query. Scheduler calls may be duplicated or missed; the sweep is
  idempotent.

## Workers and capacity

- **Workers pull.** A worker asks the control plane for work; the control plane chooses a queued
  execution at that moment and claims it for the worker by compare-and-set. There is no queue
  service between them. *Why:* choosing at the last moment keeps the build queue reorderable and
  lets the control plane match a task to the best worker, and a serverless control plane cannot
  push to workers anyway.
- **Capacity is separate from assignment.** Whatever makes workers exist — an admin, a compute
  provider, an external autoscaler — never assigns work. Getting capacity wrong costs money or
  latency, never correctness: an extra worker finds nothing to do, and work waits for a missing
  one.
- **Any compute can host a runner, including functions.**
- **Deferred:** compute providers and how they scale, how workers authenticate per pool, admin
  control of workers (disable, drain, terminate), and lower-latency delivery for stateful
  servers.

## Branches

- **Branches are tracked records**, independent of any one version-control system: repository,
  ref name, kind (branch, tag, or change request), head revision, and whether the branch still
  exists. Git branches, Plastic branches, and Perforce streams all map onto them. Webhooks and
  polling keep them current; a deleted branch is hidden and stops triggering, but its history
  stays.
- **A branch spec chooses which branches are tracked** — include/exclude patterns such as
  `+:*` and `-:experimental/*`. It is set on the repository and can be overridden per project.
- **The trigger or request chooses the ref of every repository.** A trigger targets a task and
  gives a *ref spec* for each repository in that task's closure (optionally per input, so one
  closure can use a repository at two refs).
- **A ref spec is an event spec, *same name*, or a fixed ref.** An *event* spec is a branch
  pattern such as "any branch of repository A1"; pushes to that repository fire the trigger.
  *Same name* follows the event's branch. A fixed ref names one ref, such as B1's `main`. A
  non-fixed spec can name a fallback ref, or say to skip the build, for when the name does not
  exist. (The notation is an implementation choice; examples here are illustrative.)
- **One event makes one request.** Other repositories are paired with the event's branch by
  name, never as a cross product.
- **Manual and cron requests have no event,** so their specs are concrete. A manual request may
  name a ref per repository, with the defaults shown as hints.
- **Inputs supply defaults, not choices.** What a trigger or request does not specify, and the
  chain has not already bound, comes from the input's own default ref spec (a fixed ref or *same name*, never an event spec, because a
  default cannot fire a trigger); with neither, loading the definition fails.
- **Builds carry a headline ref.** A chain records one ref (the event's, or the manual request's
  choice for the primary repository) that groups its history; a project with no repositories has
  one history. A request joins a chain by pin agreement, not by headline, so triggers on
  different tasks for one push share a chain. Nothing is built twice, because task executions are
  shared across chains.
- **Visibility filters narrow what can be built:** the repository's branch spec, the project's
  override of it, and each input's filter all apply. An event on a hidden ref does not fire a
  trigger; a fixed ref that a filter hides fails loudly when the definition loads.
- **Trigger rules filter on event kind** (push, tag, change request) **and branch patterns.**
- **A pull request is a branch of kind *change request*,** so filters and specs apply to it
  unchanged (other repositories pair with its source branch name, and pull requests from forks
  never pair); code reviews and shelves in other systems map onto the same kind. Each project
  chooses whether to build a change request's head, its merge result, or both, as far as the
  provider supports.
- **A chain carries the trust level of its request.** See "Authentication and trust".
- **Deferred:** cancelling superseded builds when a newer push arrives, and reporting build status
  back to the hosting service.

## Cross-project dependencies

Implementation deferred.

- **Projects organize; they do not change how the graph works.** A task may take another
  project's task output as an input, and it behaves like any upstream task: fingerprints and
  reruns flow through it, and a missing result is built.
- **A chain is a snapshot of inputs, across projects.** Creating or joining a chain also joins or
  creates a chain of each project it depends on, recursively — one per upstream project and
  selector. The upstream chain belongs to its own project, which numbers it, and shows in that
  project's history as a build used by the depender. Upstream inputs are resolved in the same pass,
  so inputs both projects use agree.
- **Selection chooses the upstream chain.** By default, the upstream project's inputs use their
  own default ref specs (a trigger may override them with project-qualified entries). A
  dependency or a request can instead choose another branch, an existing chain by number or
  label, or the latest chain where the task succeeded. Choosing revisions or "that
  build" fills pins before evaluation; nothing after evaluation changes.
- **A request targets tasks in its own project.** To build several projects together, make a task
  that depends on all of them.
- **Cycles between projects fail loudly** when definitions are loaded.
- **Deferred:** which projects may see and depend on each other (per-project permissions), and
  views deeper than a chain's tasks grouped by project with links between linked chains.

## Authentication and trust

The main threat today is unauthorized access to the server by anyone outside a closed team;
untrusted contributors are handled by trust levels.

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
  secrets. The signing key is generated once per installation and kept in the document store
  unless one is configured; a random per-installation key is not a guessable default.
- **Webhooks and scheduler callbacks are verified** — by the provider's signature, or by a secret
  the scheduler sends.
- **Secrets come from a secret store backend at run time.** Tasks declare secrets by name; the
  runner fetches the values with its execution token. Values never appear in work orders,
  database records, or logs, and they are not inputs (not fingerprinted).
- **Pull requests from forks are untrusted.** Following GitHub's model, untrusted builds wait for
  a member's approval, get no secrets, may reuse trusted cache entries, and store their own
  results in a scope tied to their change request that trusted builds never use. Pull requests
  from branches in the repository itself are trusted.
- **Eventual goal:** configurable worker isolation for untrusted builds (separate worker pools or
  a fresh worker per execution).

## Backends and extensions

- **You pick and choose components when setting up the server.** Every backend is chosen by
  deployment configuration at startup; switching one is a configuration change and a restart,
  never a rebuild. *Why:* the owner prefers separate programs over "bring your own `main.d`" as
  the way to make Confector composable.
- **How a backend is provided depends on the backend:**
  - The state store, scheduler, and authenticator are **compiled in** — they are on the
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
- **Deferred:** a deployment builder for third-party backends and sandboxed WebAssembly
  extensions.

## Retention

- **Retention is by reachability, not age.** Executions are shared across chains, so an old
  execution may be what today's build reuses. Policy decides which *chains* are retained;
  everything a retained chain uses is kept; anything else is deleted after it has been
  unreferenced for a grace period.
- **Always retained:** chains with work in progress (queued, running, or awaiting dispatch or
  approval — tasks nobody requested do not count, since most chains never run every task), the
  latest chain of each active branch, and pinned chains. Any signed-in user can pin a chain.
- **Bytes go; records stay.** Artifacts and logs are deleted; chain and execution records are kept
  forever by default (expiry is configurable) and show "artifacts expired". Building a task in an
  old chain then rebuilds its upstream tasks from the same pinned inputs — the same inputs, not
  necessarily the same bytes. Pin or release a chain to keep exact binaries.
- **Retention runs as a daily, resumable, idempotent sweep** triggered by the scheduler, deleting
  through the artifact and log stores. Never rely on storage lifecycle rules: they cannot know
  what is pinned or still referenced.

## Pipeline definitions

- **A project's definition is one document** — tasks, inputs, steps, triggers, outputs — with one
  schema, whether it is a YAML file or edited in the UI.
- **Each project chooses where it lives:** a separate configuration repository (the default), the
  code repository, or Confector itself. A separate repository is the default because editing the
  pipeline then never invalidates builds, access can be limited to the people who own CI, and one
  configuration can serve many code repositories. When the definition is read from a repository, the branch is a project-level default (a project
  setting, since a definition cannot say where to find itself): the code event's branch name,
  falling back to the main branch.
- **Some things are never in a definition:** repository records and credentials, secrets, compute
  pools, permissions, admin settings. Definitions refer to them by name.
- **A request reads the definition once, when it is made,** wherever the definition is stored,
  and every task it runs uses it — structure and build configuration alike. A running build
  finishes with the configuration it started with; to apply a change to it, cancel and request
  again, reusing every result already finished.
- **A later request uses the definition current when it is made** — another target, a retry, a
  rerun — against the chain's same pins. So fixing a configuration and retrying works the same
  whether you edit in the UI or commit, and an external build of an old, tested commit uses
  today's release configuration.
- **Each execution records the full definition it ran with** and the revision it came from, so
  it can be inspected and the UI can show when a result predates a configuration change. A
  request stores its definition as an immutable document keyed by a hash of its content, and
  records where it came from.
- **An execution runs with the definition of the request that claimed it.** A request that
  finds its fingerprint already running waits for that execution, whatever definition it runs
  with: build configuration is not part of the fingerprint (see "The caching contract").
- **An invalid definition fails loudly,** with file and line.

## Backend interfaces

- **The state store is a small document store; domain logic lives in the core.** Backends offer
  get, create, compare-and-set replace and remove, and index queries the core declares up front.
  Chains, executions, branches and everything else are core code written once on top. Keep the
  interface small so a new backend (DynamoDB, Postgres, SQLite) stays small.
- **Correctness depends only on reads by id and compare-and-set on a single document.** Index
  queries are for finding work (open requests, history pages) and may lag behind writes; if one
  lags, work is found a little later, never decided wrongly. There are no multi-document
  transactions; the next evaluation (or the sweep) repairs anything left half-done.
- **Documents stay under 256 KB.** Larger data belongs in the artifact or log store.
- **Workers never hold database credentials.** They receive work only through the control plane.
- **Every backend, including in-memory test fakes, must pass the conformance suite** for its
  interface.

## Build steps

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

## Version control providers

- **A provider does four things.** On the control plane: list a repository's refs, resolve a ref
  selector to a pinned value, and parse webhooks. On the runner: check out a pinned value.
  Verifying a webhook's signature is part of parsing it and cannot be skipped.
- **Pinned values are opaque to the core** and hashed in canonical JSON (RFC 8785), so providers
  cannot disagree on formatting.
- **Webhooks first, polling as a fallback.** Polling is configured per repository, because it
  costs money even when nothing changes.
- **Git checkout fetches the exact commit.** If that commit no longer exists (for example after a
  force-push), fail loudly; a rerun cannot help, because the chain pins that commit.
- **Checkout credentials stay inside checkout.** They are never written to the workspace or
  passed to other steps. This is why untrusted builds may use them: it is the one exception to
  "untrusted builds get no secrets".

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

---

## Open questions

These are **undecided**. Do not settle them implicitly by writing code that assumes an answer. If
your task depends on one, stop and ask the project owner. When one is decided, update this file.

- **Releases and deployments.** Deferred, but do not close the door.
  Deploying is an ordinary task in the graph, so builds stay environment-free and a separate
  task configures and ships them. The direction: a *release* is a record cut from a chain that
  freezes the executions of chosen tasks and pins their artifacts, so later reruns never change
  it; tasks can declare which environment they deploy to, giving a view of what was most recently
  deployed where. Deploy tasks will need a flag to never reuse cached results.
- **How far a rerun reaches.** Rerun generations are keyed by fingerprint, so a rerun affects
  every chain that shares the task's inputs; for a widely shared task that rebuilds the history
  of every branch. Whether
  a rerun reaches only the requested chain, the chains confirmed in the prompt and open chains, or
  all of them is undecided.
- **Extensible input kinds.** Any external source (a package feed, an asset server, a network
  folder) should be able to be an input, pinned like a repository. Whether and how
  extensions add input kinds is undecided; until then the kinds are repository, value and task
  output.
- **Terminated workers.** Whether an admin terminating a worker counts as an infrastructure
  failure (retried automatically) or a task failure (retried only by a user) is undecided.

---

## Orientation

Libraries live in `libs/`, the server and runner programs in `apps/`, and compiled-in backends in
`backends/<kind>/<name>/`. Each dub package is a directory with its own `dub.json` and a
`source/` folder holding the full module path (for example `libs/core/source/confector/core/`).
Explore the code for anything more specific; details change too often to list here.

---

## How to work in this repository

- **Ask when the intent is unclear.** If a request could be read more than one way, or touches an
  open question, ask instead of guessing. An agent's guess written into code or documentation
  tends to be mistaken later for a decision.
- **Do not write your own opinions into this file or other design documentation.** Propose changes
  to the project owner instead. This file should state the project's intent, not an agent's.
- **Change the existing thing, do not add a parallel one.** Adding a new field, function, or module
  alongside an old one that does nearly the same thing is how the data model got its aliases.
  The data model (`libs/api/source/confector/api/model.d`) has one canonical form for each
  concept; do not add another alias. If a representation is wrong, change it and its callers.
- **There are no external consumers.** Do not add backward-compatibility shims, re-export
  modules, deprecated fields, or migrations of stored data. Change the code and its callers
  together.
- **Make test fakes match the real backends**, not the other way around.
- **Code does not reference beads.** Beads are not synced, so a bead id in code, comments or this
  file means nothing to other readers. Keep comments minimal and useful: what the code does and
  why, not its history.
- **Do not record the state of the implementation here.** It goes stale; read the code.
- **Test the pure core.** Graph evaluation, fingerprinting, and similar decision
  logic need unit tests. Because the logic is pure, tests should not need databases or servers.
- **D conventions.** Use `immutable`, `const`, `pure`, and `@safe` / `@trusted` where they apply.
  Prefer `std.digest.sha` for hashing and `vibe.data.json` for serialization.

## Build and test

Every package is a subpackage of the root `confector` package, and packages depend on each other
as `"confector:<name>": {"path": "<relative path to the repository root>"}`. The root
`dub.selections.json` is marked `inheritable`, so building any package — from the root or from its
own directory — uses the same dependency versions; do not commit `dub.selections.json` files
anywhere else. From the repository root:

- Run core unit tests: `dub test :core`
- Other subpackages follow the same pattern, for example `:server` or `:runner-core`; check each
  subpackage's `dub.json` for its exact name.
- Build everything: `dub build` (or `dub build :server`, `dub build :runner`).

**dub is the source of truth for the build.** Change `dub.json` files to change what is built;
never make `reggaefile.d` the only place something is defined.

**reggae is an optional, faster development build** over the same dub project. From the
repository root:

```
cd build && reggae -b ninja .. && ninja
```

Targets: `server`, `runner` (plain `ninja` builds both).

Outputs land in `build/out/server/` and `build/out/runner/`. Release builds should use LDC.

**The server's `.dt` templates are compiled into the binary,** so it needs no `views` directory at
runtime; do not "fix" a missing one next to the executable.
