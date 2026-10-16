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

### 5. Modular Plugin & Build Step Architecture
Execution runtimes, version control providers, and storage backends are decoupled from the core graph engine. Tasks can compose arbitrary ordered build steps (e.g. Git clone repository, process runner steps) provided by pluggable systems.

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

   The server keeps all state in MongoDB and will not start without it: set `server.documentStore.connectionString` (or `CONFECTOR_MONGO_URI`) and `server.documentStore.database` in `confector.json` (see `deployments/confector-development/config/confector.json`). A missing setting or an unreachable MongoDB stops startup with an error.

2. **Generate build files & compile:**
   ```bash
   mkdir build && cd build
   reggae -b ninja ..
   ninja
   ```
   This builds the server (`build/out/server/`), the runner (`build/out/runner/`), and every plugin shared library, and copies the server's `public/` assets next to it.

   **Granular build targets:**
   - `ninja server` — Compile the server and copy its assets
   - `ninja runner` — Compile the runner
   - `ninja plugins` — Compile all loadable plugins

   Without reggae, dub builds the same targets from the repository root: `dub build :server`, `dub build :runner`, `dub build :plugins` (output in `out/`).

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
