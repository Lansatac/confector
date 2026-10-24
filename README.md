# Confector

**Confector** is a modular, cloud-native CI/CD engine built for granular task graphs, deterministic caching, and elastic execution.

---

## Why Confector?

Traditional CI/CD systems are built around linear stages and persistent worker infrastructure. As projects grow, this introduces significant friction:

- **Redundant Work**: Entire build pipelines re-run even when inputs and dependencies have not changed.
- **Rigid Linear Pipelines**: Strict stage boundaries make it difficult to express granular dependencies, fan-out/fan-in workflows, or parallel sub-pipelines.
- **Root-Only Triggers**: Workflows typically must evaluate from the very beginning rather than starting at specific steps or subgraphs.
- **Idle Infrastructure Costs**: Maintaining persistent, always-on agent pools is expensive and operationally complex.

**Confector addresses these problems directly:**

- **Work Less**: Tasks are content-addressed and cached by input hash. If inputs and upstream dependencies are unchanged, execution is skipped.
- **Target Anything**: Triggers can target any step in the graph, executing only what is needed to reach the desired state.
- **Scale on Demand**: Execution scales from zero, dispatching tasks ephemerally without requiring long-running dedicated agents.

---

## Core Capabilities

### 1. Directed Acyclic Graph (DAG) Execution
Workflows are defined as directed graphs of distinct tasks with explicit inputs and outputs, enabling optimal parallelism and dependency resolution.

### 2. Content-Addressed Build Caching
Tasks are memoized based on deterministic input fingerprints computed upfront from task definitions and upstream task fingerprints (transitive input hashing) rather than dynamic runtime artifact file hashes. If inputs and upstream dependencies are unchanged, execution is skipped with a `cached` status, reusing valid outputs instantly and reducing build times.

### 3. Arbitrary Node-Level Triggers
Events (commits, webhooks, cron, or manual actions) can trigger any specific node in a graph. Confector validates upstream dependencies and runs only the required subgraph.

### 4. Elastic & Serverless Topologies
Run workloads anywhere—from local development environments and serverless runtimes to ephemeral container clusters—without changing pipeline definitions.

### 5. Pluggable Backends & Build Steps
Execution runtimes, version control providers, and storage backends are decoupled from the core graph engine; backends are chosen by configuration at startup. Tasks compose ordered build steps; checking out a repository input at its pinned revision is built into the runner.

---

## Quickstart

### Prerequisites
- [Docker](https://www.docker.com/) and [Docker Compose](https://docs.docker.com/compose/)
- [VS Code Dev Containers](https://marketplace.visualstudio.com/items?itemName=ms-vscode-remote.remote-containers) (recommended)
- [DMD / LDC](https://dlang.org/download.html), [DUB](https://dub.pm/), [Reggae](https://github.com/atilaneves/reggae), and [Ninja](https://ninja-build.org/) (included in the dev container)

### Local Development

1. **Start dependencies:**
   ```bash
   docker compose up -d
   ```
   - MongoDB: `localhost:27017`
   - Mongo Express UI: `http://localhost:8081`

   The server keeps all state, and its dispatch queue, in MongoDB and will not start without it: set `server.documentStore.connectionString` (or `CONFECTOR_MONGO_URI`) and `server.documentStore.database` in `confector.json` (see `deployments/confector-development/config/confector.json`). Artifacts are kept as files under `server.artifactStore.baseDirectory`, which is required too. A missing setting or an unreachable MongoDB stops startup with an error.

   Executions are retried automatically only after an infrastructure failure (a worker that died or lost its lease). `server.execution.maxAttempts` (or `CONFECTOR_SERVER_EXECUTION_MAX_ATTEMPTS`) sets how many times a worker may start one execution before it fails with "lease lost N times"; it is optional, defaults to 3, and must be at least 1. A task that fails is never retried automatically.

   Settings are read from `confector.json` in the directory named by `CONFECTOR_CONFIG_DIR`. That variable is optional: when it is unset, the server reads its settings from environment variables alone (each setting reads an environment variable, such as `CONFECTOR_MONGO_URI`, and the variable takes precedence over the file). When it is set, the directory must exist and contain a `confector.json` that parses as a JSON object; a missing or unparseable file, or a missing directory, stops startup with an error naming the path.

   The scheduler calls back into the server (cron triggers, VCS polling), and every callback must carry a shared secret in the `X-Confector-Scheduler-Secret` header. Set `server.scheduler.callbackSecret` (or `CONFECTOR_SCHEDULER_CALLBACK_SECRET`); the server checks it and the built-in local scheduler sends it. There is no default: the server will not start without it, and callbacks without the correct secret are refused with 401.

2. **Generate build files & compile:**
   ```bash
   mkdir build && cd build
   reggae -b ninja ..
   ninja
   ```
   This builds the server (`build/out/server/`, with every backend compiled in) and the runner (`build/out/runner/`), and copies the server's `public/` assets next to it.

   **Granular build targets:**
   - `ninja server` — Compile the server and copy its assets
   - `ninja runner` — Compile the runner

   Without reggae, dub builds the same targets from the repository root: `dub build` (both), `dub build :server`, `dub build :runner` (output in `out/`).

3. **Run the server:**
   - **Linux / Dev Container:**
     ```bash
     cd build/out/server && ./confector_server
     ```
   - **Windows:**
     ```powershell
     cd build\out\server; .\confector_server.exe
     ```
   Once running, open [http://localhost:8083](http://localhost:8083) in your browser.

4. **Run tests:**
   ```bash
   dub test :core
   ```

---

## License

Confector is open source software released under [The Unlicense](LICENSE).
