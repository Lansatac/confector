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

   The server keeps all state in MongoDB and will not start without it: set `server.documentStore.connectionString` (or `CONFECTOR_MONGO_URI`) and `server.documentStore.database` in `confector.json` (see `deployments/confector-development/config/confector.json`). Artifacts are kept as files under `server.artifactStore.baseDirectory`, which is required too. A missing setting or an unreachable MongoDB stops startup with an error.

   A worker holds an execution under a lease that its heartbeat extends. Requeueing an execution whose worker was lost, and failing it once its leases have expired `server.execution.maxAttempts` (or `CONFECTOR_SERVER_EXECUTION_MAX_ATTEMPTS`) times, is done by the coordination sweep, which the server registers with its scheduler at startup to run every minute. The setting is optional, defaults to 3, and must be at least 1; it is validated at startup. A task that fails is never retried automatically.

   Settings are read from `confector.json` in the directory named by `CONFECTOR_CONFIG_DIR`. That variable is optional: when it is unset, the server reads its settings from environment variables alone (each setting reads an environment variable, such as `CONFECTOR_MONGO_URI`, and the variable takes precedence over the file). When it is set, the directory must exist and contain a `confector.json` that parses as a JSON object; a missing or unparseable file, or a missing directory, stops startup with an error naming the path.

   The scheduler calls back into the server (cron triggers, VCS polling), and every callback must carry a shared secret in the `X-Confector-Scheduler-Secret` header. Set `server.scheduler.callbackSecret` (or `CONFECTOR_SCHEDULER_CALLBACK_SECRET`); the server checks it and the built-in local scheduler sends it. There is no default: the server will not start without it, and callbacks without the correct secret are refused with 401.

   Workers authenticate with a signed, short-lived token per execution, carried in the work order and sent in the `X-Confector-Worker-Token` header on every call that execution makes (heartbeat and release, logs, completion, and artifact upload and download). The server signs and checks the tokens with a signing key. Unless one is configured, the server generates a random 32-byte key the first time it starts and stores it in the document store, so every instance and restart uses the same key; the first start logs a warning when it does this. Backups and exports of the document store therefore hold the key. Setting `server.workerTokens.signingKey` (or `CONFECTOR_WORKER_TOKEN_SIGNING_KEY`) overrides the stored key; a configured key must be at least 32 bytes, for example the output of `openssl rand -hex 32`. Worker requests without a valid token for that execution are refused with 401 (missing, altered or expired token) or 403 (a token for another execution or artifact). A request from an attempt that no longer holds its execution (the lease ran out and it was started again, or it was released) is refused with 409, so a stale report or upload is never recorded. The runner needs no token setting: it takes each token from its work order.

   Runners receive work through `/queue/receive` with a worker pool credential, sent in the `X-Confector-Worker-Pool-Credential` header. Set `server.workerPool.credential` (or `CONFECTOR_WORKER_POOL_CREDENTIAL`); there is no default, and the server does not generate one, because every runner must be given it. It must be at least 32 bytes, for example the output of `openssl rand -hex 32`. The server refuses to start without it, and `/queue/receive` refuses a missing or wrong credential with 401 before it does anything else. Every runner reads the same value from its `CONFECTOR_WORKER_POOL_CREDENTIAL` environment variable, and `confector-runner worker` refuses to start without it. The credential is sent only on `/queue/receive`; the routes an execution uses take its worker token instead. Neither the server nor the runner logs the credential or returns it in a response.

   Users reach the server only through an authenticating proxy, such as oauth2-proxy behind nginx, which signs them in and sets their identity. The server trusts that proxy with a shared secret: set `server.auth.trustedProxy.secret` (or `CONFECTOR_AUTH_PROXY_SECRET`) to at least 32 bytes, for example the output of `openssl rand -hex 32`. The proxy sends it in the `X-Confector-Proxy-Secret` header on every request (`server.auth.trustedProxy.secretHeader` changes the name). The user comes from `X-Forwarded-User`, the email from `X-Forwarded-Email`, and comma-separated group names from `X-Forwarded-Groups` (under `server.auth.trustedProxy.headers`). The server reads these headers only from a request carrying the secret, compared in constant time. A request with a missing or wrong secret is refused with 401, its identity headers are ignored, and the refusal is logged as a warning. A request that sends the secret or any of the three identity headers more than once is refused with 401 as well, and the warning names the header but never its value. The secret header must differ from the identity headers (compared case-insensitively), or the server does not start. The server refuses to start without the secret. A request for a path no route matches is answered 401 when it has no identity and 404 when it does.

   Roles are global, and each implies the ones below it: `viewer` reads everything; `member` also edits projects and tasks and starts builds; `admin` also manages repositories. Map emails and group names to roles with the lists `server.auth.trustedProxy.roles.admins`, `members` and `viewers`. Emails match case-insensitively; group names match exactly. An identity that matches several roles gets the highest; one that matches none has no role and is refused with 403 on every route. The server must only be reachable through the proxy. The proxy sets the secret itself and must not pass on a secret or identity headers that a client sent, because the server trusts any request that carries the secret. In development the nginx proxy at `localhost:8080` injects a fixed identity into every request: user `dev`, email `dev@confector.localhost`, which the development configuration maps to admin. Dev runs as that admin through the proxy, so a browser or `curl` against `http://localhost:8080` needs no headers:

   ```bash
   curl http://localhost:8080/api/v1/projects
   ```

   The proxy overwrites any identity or secret headers a client sends. The development configuration and the proxy each hold the dev secret, so change both together.

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
