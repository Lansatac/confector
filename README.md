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
Tasks are memoized based on input hashes (dependencies, upstream artifacts, configuration, and custom components). Valid cached outputs are reused instantly, reducing build times.

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

2. **Generate build files & compile:**
   ```bash
   reggae -b ninja .
   ninja
   ```
   This builds the server executable (`bin/confector`), compiles all plugin shared libraries (`bin/plugins/`), and copies required `views/` and `public/` assets into the `bin/` artifact directory.

   **Granular build targets:**
   - `ninja app` — Compile the main server and synchronize assets
   - `ninja plugins` — Compile all dynamic plugins (`bash`, `git`, `powershell`, `local_process`)
   - `ninja plugin-<name>` — Compile a specific plugin (e.g., `ninja plugin-git`)

3. **Run the server:**
   - **Linux / Dev Container:**
     ```bash
     ./bin/confector
     ```
   - **Windows:**
     ```powershell
     .\bin\confector.exe
     ```
   Once running, open [http://localhost:8083](http://localhost:8083) in your browser.

4. **Run tests:**
   ```bash
   dub test confector:core
   ```

---

## License

Confector is open source software released under [The Unlicense](LICENSE).
