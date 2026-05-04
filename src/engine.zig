//! Engine module — inference loop and runtime context
//!
//! Exports:
//! + context: Runtime state and claim register
//! + loop: Main inference engine

pub const context = @import("./engine/context.zig");
pub const loop = @import("./engine/loop.zig");

pub const Context = context.Context;
pub const ClaimRegister = context.ClaimRegister;
pub const InferenceLoop = loop.InferenceLoop;
pub const RuleDispatcher = loop.RuleDispatcher;
