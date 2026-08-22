//! Engine module — inference loop and runtime context
//!
//! Exports:
//! + context: Runtime state and claim register
//! + loop: Main inference engine

const build_options = @import("build_options");

pub const connectors = if (build_options.enable_connectors) @import("./engine/connectors.zig") else null;
pub const SourceConfig = if (build_options.enable_connectors) connectors.?.SourceConfig else void;
pub const ws = if (build_options.enable_connectors) @import("./engine/connectors/ws.zig") else null;
pub const http = if (build_options.enable_connectors) @import("./engine/connectors/http.zig") else null;
pub const context = @import("./engine/context.zig");
pub const Context = context.Context;
pub const ClaimRegister = context.ClaimRegister;
pub const events = if (build_options.enable_connectors) @import("./engine/events.zig") else struct {};
pub const ModuleSession = if (build_options.enable_connectors) @import("./engine/events.zig").ModuleSession else void;
pub const ModuleConfig = if (build_options.enable_connectors) @import("./engine/events.zig").ModuleConfig else void;
pub const loop = @import("./engine/loop.zig");
pub const InferenceLoop = loop.InferenceLoop;
pub const RuleDispatcher = loop.RuleDispatcher;
