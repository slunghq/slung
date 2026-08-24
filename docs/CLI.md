# Slung CLI

Slung CLI is a command-line interface that lets you manage, debug, and deploy Slung modules.

The CLI command tree is:

```text
slung
├── init
├── build
├── check
├── run
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
└── storage
    ├── status
    ├── verify
    └── replay
```

## Global Flags

Global flags can be used with every command.

- `--help, -h` - help for Slung.
- `--version, -v` - show the Slung version.
- `--config, -c <file>` - runtime configuration file. Values from this file populate command fields when the command is run.

## Core Commands

- `slung init` - scaffold a new project in your preferred language.
- `slung build` - compile module source to Wasm.
- `slung check` - check the module against the host interface.
- `slung run` - run a module in development mode.

### `slung init [options]`

- `--language, -l <language>` - language for the new project.
- `--path, -p <directory>` - directory for the new project.

### `slung build [options]`

- `--module, -m <path>` - module source or project path.
- `--target, -t <target>` - Wasm target.
- `--release` - build an optimized release module.

### `slung check [options]`

- `--module, -m <path>` - module source or Wasm path.
- `--target, -t <target>` - Wasm target.

### `slung run [options]`

```bash
slung run \
  --module <path.wasm> \
  --namespace <name> \
  --node-id <id> \
  --ws-port <port> \
  --http-port <port>
```

- `--module, -m <path.wasm>` - module to run. Required.
- `--namespace, -N <name>` - isolation namespace. Defaults to `default`.
- `--node-id, -n <id>` - node identity. Defaults to `node-1`.
- `--ws-port, -w <port>` - WebSocket gateway port. Defaults to `2073`.
- `--http-port, -H <port>` - HTTP webhook port. Defaults to `2074`.

The module declares its sources, components, mappers, and rules through Wasm exports. The runtime discovers those exports when the module loads.

## Instances

`slung instance` manages Slung module instances.

- `slung instance list` - list running module instances.
- `slung instance start` - start a module instance.
- `slung instance stop` - stop a module instance.
- `slung instance restart` - restart a module instance.
- `slung instance status` - show the status of a module instance.

## Static Analysis

`slung graph` inspects the static capability graph of a module as JSON.

- `slung graph show` - show the full static capability graph.
- `slung graph trace` - track the static capability graph of a specific component.
- `slung graph cycles` - detect and report cyclic dependencies in the static capability graph.
- `slung graph diff` - compare the capability graph of two module versions.

## Debugging

`slung trace` debugs the causal chain of an event.

- `slung trace show` - show the causal chain of an event.
- `slung trace replay` - replay a trace using a given seed.

## Sources

`slung source` inspects and sends events to configured sources.

- `slung source list` - show configured sources and their mapping function.
- `slung source send` - fire a synthetic event to a given source.

`slung source send` accepts:

- `--source <source>` - source to send the event to.
- `--payload <file>` - payload file to send.

## Storage

`slung storage` inspects and manages durable Slung storage.

- `slung storage status` - show storage status.
- `slung storage verify` - verify the storage database and WAL.
- `slung storage replay` - replay durable storage records.

Storage includes the SQLite database, WAL, fact state, module-owned data, mutation history, and pending inference work.

## Runtime endpoints

The runtime currently exposes two inbound endpoints:

- WebSocket gateway: `ws://<host>:2073/<namespace>/<source>`
- HTTP webhook: `POST http://<host>:2074/<namespace>/<source>`

These endpoints feed raw payloads into source mappers. A transport response currently means that the payload was received by the in-memory ingress buffer; it does not yet mean that the payload was durably stored or that the cascade completed.
