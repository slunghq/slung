//! Engine module — inference loop and runtime context
//!
//! Exports:
//! + context: Runtime state and claim register
//! + loop: Main inference engine

pub const connectors = @import("./engine/connectors.zig");
pub const SourceConfig = connectors.SourceConfig;
pub const ws = @import("./engine/connectors/ws.zig");
pub const http = @import("./engine/connectors/http.zig");
pub const context = @import("./engine/context.zig");
pub const Context = context.Context;
pub const ClaimRegister = context.ClaimRegister;
pub const events = @import("./engine/events.zig");
pub const ModuleSession = events.ModuleSession;
pub const ModuleConfig = events.ModuleConfig;
pub const loop = @import("./engine/loop.zig");
pub const InferenceLoop = loop.InferenceLoop;
pub const RuleDispatcher = loop.RuleDispatcher;
