# AGENTS.md — Confector System Architecture & Agent Guidelines

This document outlines the architectural principles, key design decisions, subsystem boundaries, and coding conventions for contributors and AI agents working on **Confector**.

---

## 1. Architectural Principles & Design Decisions

### 1.1 Explicit Directed Acyclic Graph (DAG) Execution
- **Decision**: Workflows are modeled strictly as directed acyclic graphs of discrete tasks rather than linear stages.
- **Rationale**: Linear pipelines artificially constrain execution order and prevent fine-grained dependency modeling. An explicit DAG allows maximal parallelism, fan-out/fan-in patterns, and exact dependency isolation.

### 1.2 Deterministic Content-Addressed Caching
- **Decision**: Task execution is memoized using cryptographic input fingerprints (upstream artifact digests, task configurations, custom components, and script definitions).
- **Rationale**: Eliminates redundant computation. If inputs and upstream artifacts have not changed, execution is skipped with a `cached` status, enabling near-instant validation cycles.

### 1.3 Arbitrary Node-Level Triggers & Subgraph Slicing
- **Decision**: Triggers (git events, webhooks, cron, manual dispatches) can target any arbitrary node in the DAG, not just root nodes.
- **Rationale**: Allows targeted operations (such as running an isolated deployment or a specific test suite) by evaluating only the required subgraph. If upstream cached artifacts exist, ancestors do not re-run.

### 1.4 Stateless Core vs. Persistent Control Plane
- **Decision**: Strict architectural separation between the execution core (`confector:core` / `confector:serverless`) and the persistent management server (`confector:server` / `source/app.d`).
- **Rationale**: The core graph engine, hashing logic, and single-task execution must remain completely stateless, embeddable as a library, and deployable to serverless/FaaS runtimes. The persistent server acts as a consumer of this core library.

### 1.5 Decoupled Queue-Based Worker Delegation
- **Decision**: Compute tasks are dispatched via standard message queues (e.g., MongoDB Queue for local development, cloud message queues) to decoupled workers.
- **Rationale**: Avoids maintaining stateful, proprietary agent daemons. Compute scales elastically from zero using ephemeral runners (serverless functions, Kubernetes Jobs/Pods, or container tasks) or traditional queue-polling workers.

### 1.6 Modular Plugin Architecture
- **Decision**: Execution environments, version control integrations, and runner backends are modeled as decoupled plugins managed by a centralized lifecycle registry.
- **Rationale**: Isolates the core DAG scheduler from external toolchains and cloud providers, allowing new capabilities to be registered dynamically without altering core graph logic.

### 1.7 Data-Oriented System Isolation (ECS-Inspired Model)
- **Decision**: Task nodes are modeled as entity identities with attached, composable data components (inputs, execution specifications, outputs, and triggers), processed by stateless, decoupled systems.
- **Rationale**: Prevents central domain model bloat when introducing exotic input types, heterogeneous storage layers, or custom execution targets. Eliminates rigid inheritance hierarchies in favor of data/logic separation, maximizing composability, modularity, and extensibility across plugins.

---

## 2. Subsystem Boundaries & Responsibilities

- **`source/confector/core/`**: Stateless core library containing domain models and entity definitions (`model.d`), DAG cycle detection & sorting (`dag.d`), fingerprint calculation (`fingerprinter.d`), trigger evaluation (`trigger.d`), plugin lifecycle interfaces (`plugin.d`, `executor.d`, `vcs.d`), and decoupled system contracts (`system.d`). Must have no persistent database or HTTP server dependencies.
- **`source/confector/runner/`**: Execution runners for evaluating task payloads locally via child processes (`process_runner.d`) or serverless invocation handlers (`serverless_runner.d`).
- **`source/confector/queue/`**: Work queue abstractions (`queue.d`) and storage implementations (MongoDB collection queue, cloud queue driver).
- **`source/confector/plugins/`**: Built-in plugin implementations containing component data definitions and stateless processing systems for execution (`process_runner.d`) and VCS providers (`git.d`).
- **`source/controller/` & `source/app.d`**: Persistent Vibe.d web service handling HTTP routing, webhooks, UI rendering, and database persistence.

---

## 3. Developer & Agent Conventions

1. **Stateless Core Invariant**:
   - `confector.core` modules must remain pure and stateless. External state and storage systems must be passed via abstractions.
2. **Plugin Extensibility & Component-System Isolation**:
   - New execution environments, input resolvers, or version control integrations should model data as passive components and logic as stateless systems, registering via `PluginRegistry`.
3. **Explicit Error Diagnostics**:
   - Prefer domain-specific exceptions (e.g., `DAGValidationException`, `FingerprintException`) with descriptive diagnostics (such as exact cycle paths in cyclic graphs).
4. **D Idioms & Safety**:
   - Use standard D type qualifiers (`immutable`, `const`, `pure`, `@safe` / `@trusted` where appropriate).
   - Use `std.digest.sha` for hashing and `vibe.data.json` for serialization.
5. **Unit Testing**:
   - Every core algorithm (DAG resolution, cycle detection, fingerprinting, trigger matching, plugin registration) must be accompanied by comprehensive unit tests (`unittest { ... }`).

---

## 4. Schemas & Specifications Reference

For specific JSON/YAML schemas, payload formats, and data contracts, refer to the documentation in [`docs/`](docs/):
- **[Data Contracts & Schemas](docs/schemas.md)**: Task DAG YAML definitions, fingerprint hash formula, queue task messages, and artifact metadata.
- **[Plugin Architecture Reference](docs/plugins.md)**: Plugin lifecycle, registry mechanics, and extension interfaces (`TaskRunner`, `RepositoryProvider`).
