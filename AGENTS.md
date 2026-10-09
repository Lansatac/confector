# AGENTS.md — Confector System Architecture & Agent Guidelines

This document outlines the architectural principles, key design decisions, subsystem boundaries, and coding conventions for contributors and AI agents working on **Confector**.

---

## What is Confector?

Confector is a modular, cloud-native CI/CD engine written in D (Dlang) that executes workflows as directed acyclic graphs (DAGs). It provides deterministic content-addressed caching, arbitrary node-level triggers, and elastic, plugin-driven execution. The system is designed around a strict separation between a **stateless execution core** (embeddable as a library, deployable to serverless/FaaS) and a **persistent management server** (Vibe.d HTTP service with MongoDB).

Key design pillars:
- **DAG-based execution** — Workflows are explicit DAGs, not linear pipelines, enabling maximal parallelism and fine-grained dependency modeling.
- **Content-addressed caching** — Task fingerprints are computed from task definitions and transitive upstream hashes, enabling cache hits across any compute backend.
- **Serverless-first design** — The entire system is designed so that a version of the server can be deployed in a serverless/FaaS context. The execution core is stateless and embeddable as a library. Even the orchestrator logic should eventually be splittable into stateless functions triggered by queue events. Always keep serverless deployability in mind when making architectural decisions.
- **Plugin-driven extensibility** — Build steps, VCS integrations, compute backends, and artifact storage are all decoupled plugins loaded dynamically.
- **Queue-based workers** — Tasks are dispatched via message queues to decoupled workers that may be local processes, serverless functions, or Kubernetes jobs.

---

## Where to Look

### Core Library — `source/confector/core/`
Stateless DAG engine, fingerprinting, trigger matching, and plugin lifecycle. Key files:
- `dag.d` — DAG construction, cycle detection, topological sort, subgraph slicing
- `fingerprinter.d` — Deterministic SHA-256 fingerprint computation
- `trigger.d` — Trigger rule evaluation against events
- `plugin.d` / `plugin_loader.d` — Plugin registry and dynamic library loading
- `model.d` — Domain models for tasks, builds, projects, and persistence
- `storage.d` — `BuildStateRepository` interface and local artifact storage

### Plugin API — `source/confector/plugin_api/`
Public interfaces and data models that plugins implement. Key files:
- `plugin.d` — `Plugin` base interface, categories (definition, step_executor, worker, artifact)
- `system.d` — ECS-inspired system contracts (`BuildStepSystem`, `InputResolverSystem`, etc.)
- `executor.d` — Compute provider and worker pool abstractions
- `model.d` — Core domain structs (`TaskNode`, `BuildStep`, `TaskQueueMessage`, etc.)

### Execution Engine — `source/confector/runner_core/`
**Stateless** single-task execution orchestration (input resolution → build steps → artifact publishing). This is the core component deployable to serverless/FaaS.
- `engine.d` — `TaskEngine`: stateless orchestrator for the full execution pipeline with cache support
- `artifacts.d` — Artifact staging and checksum verification
- `worker.d` — HTTP-based remote worker daemon

### Server (Control Plane) — `source/confector/server/`
Persistent Vibe.d web service with MongoDB persistence. **Goal:** a version of this should be deployable in a serverless context — see serverless design pillar above.
- `app.d` — Application bootstrap (MongoDB, plugins, routing). Currently stateful; serverless target requires splitting orchestration into event-driven functions.
- `config.d` — Server configuration structs
- `controller/` — HTTP endpoints: `api_controller.d` (REST API), `dashboard_controller.d` (web UI), `admin_controller.d` (plugin management), `executor_controller.d`, `repositorycontroller.d`
- `orchestrator/coordinator.d` — `BuildCoordinator`: central build orchestration, trigger handling, subgraph computation, in-flight deduplication. **Currently stateful** (in-memory registries, MongoDB persistence); for serverless deployment, this logic needs to be decomposed into stateless functions.
- `orchestrator/capacity_broker.d` — Queue backlog monitoring and compute provisioning
- `orchestrator/serverless_handler.d` — **Stateless** serverless/FaaS execution handler; entry point for serverless task execution via JSON-RPC
- `storage/mongo_repository.d` — MongoDB implementation of `BuildStateRepository`

### Work Queue — `source/confector/queue/`
Queue abstractions and implementations.
- `queue.d` — `WorkQueue` interface and in-memory implementation
- `mongo_queue.d` — MongoDB-backed persistent queue with visibility timeouts

### Configuration — `source/confector/config/`
Type-safe hierarchical configuration with environment variable override support.
- `package.d` — Struct-based config definitions with UDA annotations

### Standalone Runner — `source/confector/runner_app/`
CLI tool for single-task execution or HTTP worker daemon mode.
- `main.d` — Entry point with `run` and `worker` subcommands

### Plugins — `plugins/`
Dynamic libraries compiled to `out/plugins/`. Four categories:
- **`definition/`** (server-side) — Step UI forms and validation (e.g., `git/`, `bash/`, `powershell/`)
- **`step_executor/`** (runner-side) — Build step execution and input resolution (e.g., `git/`, `bash/`, `powershell/`)
- **`worker/`** (server-side) — Compute provisioning (e.g., `local_process/`)
- **`artifact/`** (runner-side) — Artifact storage backends (e.g., `local/`)

### Other Key Directories
- **`views/`** — 26 Diet-NG templates for the web UI (dashboard, projects, tasks, builds, etc.)
- **`out/`** — Self-contained runtime artifact directory (executable, plugins, views, public assets)
- **`deployments/`** — Deployment configs (Docker Compose, dev container)
- **`dub.json`** — DUB package manifest defining sub-packages
- **`reggaefile.d`** — Reggae build script coordinating compilation and asset sync

---

## Architectural Principles & Design Decisions

### 1.1 Explicit Directed Acyclic Graph (DAG) Execution
- **Decision**: Workflows are modeled strictly as directed acyclic graphs of discrete tasks rather than linear stages.
- **Rationale**: Linear pipelines artificially constrain execution order and prevent fine-grained dependency modeling. An explicit DAG allows maximal parallelism, fan-out/fan-in patterns, and exact dependency isolation.

### 1.2 Deterministic Content-Addressed Caching
- **Decision**: Task execution is memoized using cryptographic input fingerprints computed deterministically upfront from task definitions and upstream task fingerprints (transitive input hashing) rather than dynamic runtime artifact file hashes.
- **Rationale**: Eliminates redundant computation and decouples work definition from execution. Upfront transitive hashing ensures fingerprints are deterministic, statically resolvable during DAG scheduling before compute allocation, and invariant across all compute backends.

### 1.3 Arbitrary Node-Level Triggers & Subgraph Slicing
- **Decision**: Triggers (git events, webhooks, cron, manual dispatches) can target any arbitrary node in the DAG, not just root nodes.
- **Rationale**: Allows targeted operations (such as running an isolated deployment or a specific test suite) by evaluating only the required subgraph. If upstream cached artifacts exist, ancestors do not re-run.

### 1.4 Serverless-First Design
- **Decision**: The entire system is designed so that a version of the server can be deployed in a serverless/FaaS context. The execution core (`confector:core` / `confector:runner_core`) is stateless and embeddable as a library. The serverless handler (`serverless_handler.d`) provides a JSON-RPC entry point for stateless task execution.
- **Rationale**: Serverless deployment enables elastic scaling from zero, pay-per-use cost models, and no persistent infrastructure overhead. The current persistent server (`confector:server`) is the reference implementation, but the goal is to decompose its orchestration logic (trigger matching, subgraph slicing, task coordination) into stateless, event-driven functions.
- **Current status**: `TaskEngine` and `serverless_handler.d` are already stateless. `BuildCoordinator`, `CapacityBroker`, and `app.d` bootstrap are still stateful and represent the primary target for future serverless decomposition.
- **Guideline for agents**: When making changes to the server module, always consider whether the change could prevent or complicate a future serverless deployment. Prefer passing state via abstractions (interfaces, parameters) over embedding it in class members or global state.

### 1.5 Decoupled Queue-Based Worker Delegation
- **Decision**: Compute tasks are dispatched via standard message queues (e.g., MongoDB Queue for local development, cloud message queues) to decoupled workers.
- **Rationale**: Avoids maintaining stateful, proprietary agent daemons. Compute scales elastically from zero using ephemeral runners (serverless functions, Kubernetes Jobs/Pods, or container tasks) or traditional queue-polling workers.

### 1.6 Modular Plugin Architecture
- **Decision**: Execution environments, version control integrations, and runner backends are modeled as decoupled plugins managed by a centralized lifecycle registry.
- **Rationale**: Isolates the core DAG scheduler from external toolchains and cloud providers, allowing new capabilities to be registered dynamically without altering core graph logic.

### 1.7 Data-Oriented System Isolation (ECS-Inspired Model)
- **Decision**: Task nodes are modeled as entity identities with attached, composable data components (inputs, execution specifications, outputs, and triggers), processed by stateless, decoupled systems.
- **Rationale**: Prevents central domain model bloat when introducing exotic input types, heterogeneous storage layers, or custom execution targets. Eliminates rigid inheritance hierarchies in favor of data/logic separation, maximizing composability, modularity, and extensibility across plugins.

### 1.8 Plugin-Defined Ordered Build Steps
- **Decision**: Task execution consists of an arbitrary ordered list of plugin-defined build steps (such as the Git plugin's `clone_repository` step or the process runner's `process` step).
- **Rationale**: Replaces rigid, monolithic script execution with composable, sequentially executed step systems. Each plugin exposes step handlers dynamically via `BuildStepSystem`, maximizing reusability and fine-grained error isolation.

---

## Developer & Agent Conventions

1. **Stateless Core Invariant**:
   - `confector.core` and `confector.runner_core` modules must remain pure and stateless. External state and storage systems must be passed via abstractions (interfaces, parameters). Never introduce persistent state, global singletons with mutable state, or implicit I/O dependencies in these modules.
2. **Serverless Deployability Check**:
   - Before making architectural changes to the server module, ask: "Could this logic run as a stateless function?" If the answer should be yes, ensure state is passed explicitly rather than stored. The `BuildCoordinator` and `CapacityBroker` are known targets for future serverless decomposition.
3. **Plugin Extensibility & Component-System Isolation**:
   - New execution environments, input resolvers, or version control integrations should model data as passive components and logic as stateless systems, registering via `PluginRegistry`.
4. **Explicit Error Diagnostics**:
   - Prefer domain-specific exceptions (e.g., `DAGValidationException`, `FingerprintException`) with descriptive diagnostics (such as exact cycle paths in cyclic graphs).
5. **No Silent Fallbacks — Fail Fast and Loudly**:
   - Never add silent fallbacks or "reasonable" default behavior when configuration is missing, invalid, or ambiguous. Historically, agents have introduced fallbacks that hid serious errors (e.g., missing plugin context, wrong database connection strings, absent artifact directories).
   - If a required configuration value, plugin context, or dependency is missing, throw an explicit exception with a clear error message immediately. Do not log a warning and continue.
   - If a fallback is intentionally designed and obvious (e.g., a well-documented optional feature with a clear default), document it explicitly in the code and configuration schema. Otherwise, fail fast.
   - Plugins must enforce non-null `PluginContext` in `initialize()` and throw if the host fails to provide configuration. Do not accept null contexts and degrade silently.
6. **D Idioms & Safety**:
   - Use standard D type qualifiers (`immutable`, `const`, `pure`, `@safe` / `@trusted` where appropriate).
   - Use `std.digest.sha` for hashing and `vibe.data.json` for serialization.
7. **Build & Execution Workflow**:
   - Build all targets (app, plugins, assets): `dub build`
   - Build specific components: `dub build :server`, `dub build :plugins`, etc
   - Run the server: `dub run :server`
8. **Unit Testing**:
   - Every core algorithm (DAG resolution, cycle detection, fingerprinting, trigger matching, plugin registration) must be accompanied by comprehensive unit tests (`dub test confector:core`).

---

## Schemas & Specifications Reference

For specific JSON/YAML schemas, payload formats, and data contracts, refer to the documentation in [`docs/`](docs/):
- **[Data Contracts & Schemas](docs/schemas.md)**: Task DAG YAML definitions, fingerprint hash formula, queue task messages, and artifact metadata.
- **[Plugin Architecture Reference](docs/plugins.md)**: Plugin lifecycle, registry mechanics, and extension interfaces (`BuildStepSystem`, `RepositoryProvider`).
