//! Engine module — inference loop and runtime context
//!
//! Exports:
//! + context: Runtime state and claim register
//! + loop: Main inference engine

pub const context = @import("./engine/context.zig");
pub const loop = @import("./engine/loop.zig");
pub const server = @import("./engine/connectors/server.zig");
pub const connectors = @import("./engine/connectors.zig");
pub const events = @import("./engine/events.zig");

pub const Context = context.Context;
pub const ClaimRegister = context.ClaimRegister;
pub const InferenceLoop = loop.InferenceLoop;
pub const RuleDispatcher = loop.RuleDispatcher;
pub const Server = server.Server;
pub const SourceConfig = connectors.SourceConfig;
pub const ModuleSession = events.ModuleSession;
pub const ModuleConfig = events.ModuleConfig;
