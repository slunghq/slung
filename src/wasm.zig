//! Wasm module — runtime execution, module loading, and host ABI.
//!
//! Exposes the module loader/graph builder, host ABI functions, and execution runtime.

pub const module = @import("wasm/module.zig");
pub const GraphBuilder = module.GraphBuilder;
pub const SourceRegistry = module.SourceRegistry;
pub const ComponentRegistry = module.ComponentRegistry;
pub const RuleRegistry = module.RuleRegistry;

pub const graph = @import("wasm/index.zig");
pub const ForwardKey = graph.ForwardKey;
pub const Forward = graph.Forward;
pub const ForwardIndex = graph.ForwardIndex;
pub const Reverse = graph.Reverse;
pub const ReverseIndex = graph.ReverseIndex;

pub const host = @import("wasm/host.zig");
pub const wire = @import("wasm/wire.zig");
