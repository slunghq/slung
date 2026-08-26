# Slung CLI

The Slung CLI manages local development runtimes, deployment hosts, modules,
and the runtime state attached to them.

This documents the current development branch. Some commands exist in the
command tree but are not implemented yet.

## Command tree

```text
slung
├── init
├── build
├── check
├── dev
├── run
├── deploy
├── instance
│   ├── list
│   ├── start
│   ├── stop
│   ├── restart
│   └── status
├── graph
│   ├── show
│   ├── trace
│   ├── cycles
│   └── diff
├── trace
│   ├── show
│   └── replay
├── source
│   ├── list
│   └── send
├── storage
│   ├── status
│   ├── verify
│   └── replay
└── auth
    ├── login
    ├── logout
    ├── list
    └── status
```

## Global flags

Global flags can be used with every command and can appear before or after the
command.

- `--config, -c <file>` - path to the configuration file.
- `--target, -t <target>` - Slung deployment or local target.
- `--help, -h` - show help.
- `--version, -v` - show the Slung version.

The default config path is:

```text
./slung.toml
```

The path is resolved from the current working directory. An absolute path can
also be supplied.

## Configuration

`--config` always has the same spelling. The command determines which values
it uses from the file.

The current configuration model separates module settings from deployment
settings:

```toml
version = 1

[run]
module = "build/app.wasm"
namespace = "production"

[deployment]
node_id = "node-1"
discovery_port = 2072
ws_port = 2073
http_port = 2074

[storage]
path = ".slung"
durability = "strict"

[observability]
enabled = true
service_name = "slung"
otlp_endpoint = "http://127.0.0.1:4318"
```

`[run]` is module-level configuration. `[deployment]` is deployment-level
configuration and owns the node ID and listener ports.

Explicit command flags override values from the config file. Values not
provided by either source use command defaults.

## Core commands

- `slung init` - scaffold a new project in your preferred language.
- `slung build` - compile module source to Wasm.
- `slung check` - check the module against the host interface.
- `slung dev` - run a module in development mode.
- `slung run` - run a deployment host without loading a module.
- `slung deploy` - deploy a module to an existing Slung deployment.

### `slung init [options]`

- `--language, -l <language>` - language for the new project.
- `--path, -p <directory>` - directory for the new project.

The command is present in the CLI but is not implemented yet.

### `slung build [options]`

- `--module, -m <path>` - module source or project path.
- `--target, -t <target>` - Wasm target.
- `--release` - build an optimized release module.

The command is present in the CLI but is not implemented yet.

### `slung check [options]`

- `--module, -m <path>` - module source or Wasm path.
- `--target, -t <target>` - Wasm target.

The command is present in the CLI but is not implemented yet.

## Development runtime

### `slung dev [options]`

`dev` loads a module directly from the local filesystem and starts a
module session.

```sh
slung dev \
  --module src/testdata/webhook.wasm \
  --namespace test_ns \
  --node-id node-1 \
  --ws-port 2073 \
  --http-port 2074
```

Flags:

- `--module, -m <path.wasm>` - module to run. It can also come from
  `[run].module` in the config file.
- `--namespace, -N <name>` - isolation namespace. Defaults to `default`.
- `--node-id, -n <id>` - node identity. Defaults to `node-1`.
- `--ws-port, -w <port>` - WebSocket gateway port. Defaults to `2073`.
- `--http-port, -H <port>` - HTTP webhook port. Defaults to `2074`.

When the module loads, Slung discovers its source, component, mapper, and rule
exports. The module’s capability graph is built and its connectors are
registered against the runtime gateways.

`dev` logs the loaded module:

```text
Starting... Module loaded:
  namespace: test_ns
  node id:   node-1
  module:    src/testdata/webhook.wasm
```

## Deployment host

### `slung run [options]`

`run` starts a deployment host. It does not load a module and does not create a
`ModuleSession`.

```sh
slung run \
  --node-id node-1 \
  --discovery-port 2072 \
  --ws-port 2073 \
  --http-port 2074
```

Flags:

- `--node-id, -n <id>` - node identity. Defaults to `node-1`.
- `--discovery-port, -d <port>` - deployment/discovery listener. Defaults to
  `2072`.
- `--ws-port, -w <port>` - WebSocket gateway port. Defaults to `2073`.
- `--http-port, -H <port>` - HTTP webhook port. Defaults to `2074`.

The deployment host starts all three listeners:

```text
2072  deployment/discovery
2073  WebSocket gateway
2074  HTTP webhook
```

Its startup log only identifies the deployment host and node. Module loading
and the `Module loaded` message belong to `dev` or deployment activation.

## Deploying a module

### `slung deploy [options]`

`deploy` sends a Wasm module and its config file to an existing deployment
host.

```sh
slung deploy \
  --target local \
  --module src/testdata/webhook.wasm \
  --namespace test_ns \
  --config slung.toml
```

Flags:

- `--module, -m <path.wasm>` - module to deploy. If omitted, the CLI uses
  `[run].module` from the config file.
- `--namespace, -N <name>` - namespace for the module. If omitted, the CLI
  uses `[run].namespace` and then `default`.

`--target` is global. The current `local` target resolves to:

```text
http://127.0.0.1:2072/deploy
```

HTTP and HTTPS targets have `/deploy` appended automatically. A host and port
without a scheme are treated as HTTP targets.

The deployment request contains:

```text
namespace
module name
raw config file bytes
Wasm bytes
```

The deployment host stores the deployment in memory, activates the module, and
registers its discovered source routes against the existing HTTP and
WebSocket gateways.

The CLI parses the response and reports either:

```text
First deployment: webhook.wasm
```

or:

```text
Redeployment: webhook.wasm
```

### Redeployment

A namespace can be redeployed. A redeployment:

1. Replaces the stored module and config for that namespace.
2. Stops the previous session’s connectors.
3. Removes the previous module’s source routes.
4. Replaces the active module session and capability graph.
5. Starts the replacement session.

The deployment record also stores a 32-byte BLAKE3 digest of the Wasm bytes.
The digest is currently internal and is not printed by the CLI.

Deployment state is currently process-memory only. Restarting the deployment
host loses stored modules, configs, and active sessions.

## Instances

`slung instance` is the intended interface for managing multiple module
instances:

- `slung instance list` - list running module instances.
- `slung instance start` - start a module instance.
- `slung instance stop` - stop a module instance.
- `slung instance restart` - restart a module instance.
- `slung instance status` - show the status of a module instance.

The command definitions and flags exist, but the handlers are not implemented
yet.

## Static analysis

`slung graph` inspects a module’s static capability graph as JSON:

- `slung graph show` - show the full static capability graph.
- `slung graph trace` - track the static capability graph of a specific
  component.
- `slung graph cycles` - detect and report cyclic dependencies in the static
  capability graph.
- `slung graph diff` - compare the capability graph of two module versions.

Available flags include:

- `--module, -m <path.wasm>` - module to inspect.
- `--component, -C <component>` - component to trace.
- `--left, -l <path.wasm>` - first module version for `graph diff`.
- `--right, -r <path.wasm>` - second module version for `graph diff`.
- `--format, -f <format>` - output format.

The command definitions exist, but graph handlers are not implemented yet.

## Debugging

`slung trace` is the causal-chain debugging command:

- `slung trace show` - show the causal chain of an event.
- `slung trace replay` - replay a trace using a given seed.

Flags:

- `--fact, -f <fact>` - fact whose causal chain should be shown.
- `--seed, -s <seed>` - seed to replay.

The command definitions exist, but trace handlers are not implemented yet.

## Sources

`slung source` inspects and sends events to configured sources:

- `slung source list` - show configured sources and their mapping function.
- `slung source send` - fire a synthetic event to a given source.

`slung source send` accepts:

- `--source, -s <source>` - source to send the event to.
- `--payload, -p <file>` - payload file to send.

The command definitions exist, but source handlers are not implemented yet.

## Storage

`slung storage` inspects and manages durable Slung storage:

- `slung storage status` - show storage status.
- `slung storage verify` - verify the storage database and WAL.
- `slung storage replay` - replay durable storage records.

Storage currently includes SQLite-backed fact state, mutation history, pending
inference work, and module-owned key/value data. Storage handlers are not
implemented in the CLI yet.

## Authentication

`slung auth` is reserved for global authentication data used when accessing
remote deployments:

- `slung auth login` - save authentication data for a remote deployment.
- `slung auth logout` - remove authentication data for a remote deployment.
- `slung auth list` - list saved authentication profiles.
- `slung auth status` - show authentication status for a remote deployment.

Authentication persistence and remote authentication are not implemented yet.

## Runtime endpoints

A deployment host currently exposes:

- Deployment/discovery: `POST http://<host>:2072/deploy`
- WebSocket gateway: `ws://<host>:2073/<namespace>/<source>`
- HTTP webhook: `POST http://<host>:2074/<namespace>/<source>`

The deployment endpoint accepts an in-memory deployment envelope. The HTTP
and WebSocket gateways are shared by the active module sessions on that
deployment host.

HTTP webhook responses currently acknowledge that the payload was received by
the ingress buffer. They do not mean that a mapper accepted the payload, that
the fact was durably stored, or that the inference cascade completed.

## CLI errors and exit codes

The CLI prints diagnostics instead of exposing Zig error traces:

```text
Error: Missing value for --module
```

Current exit codes:

- `0` - success or help/version output.
- `1` - runtime or internal failure.
- `2` - invalid command-line input.
- `3` - command exists but is not implemented yet.
