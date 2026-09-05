# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.2.0-alpha.1] - 2026-05-18

### Added

+ Hierarchical CLI with `dev`, `run`, `deploy`, `instance`, `source`, `storage`, `graph`, and `trace` command groups.
+ Deployment server and runtime supervisor for loading and managing module sessions.
+ TOML configuration for modules, namespaces, node identity, ports, storage, durability, and observability settings.
+ SQLite-backed module storage for `slung_store_*` data, with vendored SQLite sources.
+ Append-only WAL for node-local fact and pending-work durability, including eventual and strict modes, batching, recovery, checksums, and backpressure handling.
+ HTTP source connector for webhook ingestion alongside the WebSocket gateway.
+ Outbound HTTP host ABI with request headers, response headers, response bodies, and direct HTTP status codes.
+ Rust HTTP client bindings and a Rust end-to-end outbound HTTP example with a local test server.
+ Rust pipeline support for `wasm32-wasip1` modules and embedded source configuration.
+ Deployment, storage, runtime execution, and WAL benchmarks.
+ Scoped, timestamped, colored runtime logging and a custom test runner.

### Changed

+ Runtime configuration can be supplied through `slung.toml` or overridden for development and runtime commands with `--durability eventual|strict`.
+ Module lifecycle and source ingestion are managed through `ModuleSession` and the runtime supervisor.
+ Outbound HTTP failures are distinguished from HTTP error responses; HTTP statuses are returned directly to modules.

### Fixed

+ Improved CLI error messages and exit codes.
+ Improved deployment session loading and deployment logging.
+ Corrected webhook endpoint examples and storage path documentation.

## [0.1.0-alpha.1] - 2026-05-17

### Added

+ CLI runtime entrypoint for module-backed execution: `slung run --module ... --namespace ... --node-id ... --ws-port ...`
+ Runtime context and connector plumbing built on shared `Arc<Mutex<...>>` state
+ WebSocket server-mode ingress for module source routes
+ Connector skeletons for Redis, NATS, TCP/UDP, and WebSocket client mode
+ `ModuleSession` for managing module lifecycle (init, deinit, run)
+ `ModuleConfig` for configuring sources and runtime parameters
+ Source polling and inference dispatch runtime loop
+ Generic host ABI functions: `slung_get`, `slung_set`, `slung_now`, `slung_yield`
+ Rust SDK macros for `#[source]`, `#[component]`, and `#[rule]`
+ End-to-end multi-cycle cascade test coverage
+ Wasm descriptor sweep and capability graph builder with forward/reverse indices
+ HLC (Hybrid Logical Clock) with causal tags for CRDT ordering
+ LWW (Last-Write-Wins) registry with Bloom filter short-circuit
+ Dirty queue with MPMC support and optional blocking pop
+ Generic smart pointer (`Arc`) with atomic reference counting
+ Mutex with RAII Guard pattern
+ Columnar cache table implementation

### Removed

+ MPSC ring buffer pipeline - superseded by dirty-driven agenda and capability graph dispatch
+ TSDB as primary data model - time-series storage replaced by LWW CRDT registry with columnar cache per node
+ Stream processing execution model - replaced by forward-chaining reactive rule engine
+ `slung_emit` host ABI function - redundant with `slung_set`

### Changed

+ Wasm execution model reoriented from stream transforms to self-describing rule modules with declared watch lists
+ Columnar storage retained as a local read cache rather than the primary persistence layer

[Unreleased]: https://github.com/slunghq/slung/compare/v0.2.0-alpha.1...HEAD
[0.2.0-alpha.1]: https://github.com/slunghq/slung/releases/tag/v0.2.0-alpha.1
[0.1.0-alpha.1]: https://github.com/slunghq/slung/releases/tag/v0.1.0-alpha.1
