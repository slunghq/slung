# Slung v0.2.0-alpha.1

Slung v0.2.0-alpha.1 adds the first configurable deployment/runtime surface and node-local durability layer beyond the original `v0.1.0-alpha.1` runtime.

See the full [changelog](https://github.com/slunghq/slung/blob/main/docs/CHANGELOG.md).

## Highlights

+ Hierarchical CLI with `dev`, `run`, `deploy`, `instance`, `source`, `storage`, `graph`, and `trace` commands.
+ Deployment server and runtime supervisor for loading and managing module sessions.
+ TOML configuration for module paths, namespaces, node identity, ports, storage, and durability.
+ Append-only WAL with eventual and strict durability modes, batching, checksums, recovery, and backpressure handling.
+ SQLite-backed storage for module-owned `slung_store_*` data.
+ HTTP webhook ingress and expanded outbound HTTP support.
+ Outbound HTTP request headers, response headers, response bodies, and direct HTTP status codes.
+ Rust pipeline modules targeting `wasm32-wasip1`.
+ Runtime, storage, and WAL benchmarks.
+ Improved logging, deployment diagnostics, CLI errors, and test tooling.

## Install

Download the archive matching your operating system and architecture from the [GitHub Releases page](https://github.com/slunghq/slung/releases), extract `slung`, and make it executable:

```sh
chmod +x ./slung
```

## Configure durability

The default is eventual durability:

```toml
[storage]
path = "data/slung.db"
durability = "eventual"
```

Use strict durability when a source operation must wait for its WAL checkpoint to be written and synced:

```toml
[storage]
durability = "strict"
```

For local or operational overrides:

```sh
./slung dev --module module.wasm --durability strict
./slung run --config slung.toml --durability eventual
```

Eventual mode offers lower latency and higher throughput but can lose checkpoints still queued when the process or machine fails. Strict mode provides a stronger local recovery boundary at higher storage cost. Neither mode makes external HTTP effects exactly-once; use destination idempotency keys where replay matters.

## Status

Slung remains alpha software. The current release is single-node. Review the documentation for connector limitations, transport acknowledgment semantics, authentication status, and external-effect recovery before using it in production.
