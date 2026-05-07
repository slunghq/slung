# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

+ Connector abstraction (`Arc<Mutex<DirtyQueue>>`, `Arc<Mutex<LwwRegistry>>`) for thread-safe shared state
+ WebSocket connector skeleton with TODO tasks for Milestone B
+ NATS and TCP connectors with TODO tasks for Milestone B
+ `ModuleSession` for managing module lifecycle (init, deinit, run)
+ `ModuleConfig` for configuring sources and runtime parameters
+ Event loop supervisor pattern with source polling and inference dispatch
+ `slung_get`, `slung_set`, `slung_now`, `slung_yield` host ABI functions fully implemented
+ Rust SDK with `#[source]`, `#[component]`, `#[rule]` macros
+ Multi-cycle cascade proof with convergence guarantee (e2e test)
+ Capability graph builder with forward/reverse indices
<!-- -->
+ HLC (Hybrid Logical Clock) with causal tags for CRDT ordering
+ LWW (Last-Write-Wins) registry with Bloom filter short-circuit
+ Dirty queue with MPMC support and optional blocking pop
+ Generic smart pointer (`Arc`) with atomic reference counting
+ Mutex with RAII Guard pattern
+ Columnar cache table for fast column-oriented reads

### Removed

+ MPSC ring buffer pipeline - superseded by dirty-driven agenda and capability graph dispatch
+ TSDB as primary data model - time-series storage replaced by LWW CRDT registry with columnar cache per node
+ Stream processing execution model - replaced by forward-chaining reactive rule engine
+ `slung_emit` host ABI function - redundant with `slung_set`

### Changed

+ Wasm compute layer reoriented from stream transform functions to self-contained rule modules with declared watch lists
+ Columnar storage retained but recast as a local read cache rather than the primary persistence layer


[Unreleased]: https://github.com/slunghq/slung/compare/HEAD
