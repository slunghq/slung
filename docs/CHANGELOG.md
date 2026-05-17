# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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

## [Unreleased]


[0.1.0-alpha.1]: https://github.com/slunghq/slung/releases/tag/v0.1.0-alpha.1
[Unreleased]: https://github.com/slunghq/slung/compare/v0.1.0-alpha.1...HEAD
