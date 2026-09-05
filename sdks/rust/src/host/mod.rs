//! Host ABI Bindings — Slung runtime interface
//!
//! Modular bindings to Slung host functions organized by category:
//! - `generic`: read/write component values, clock, yield, emit, notify
//! - `http`: HTTP connector
//! - `ws`: WebSocket connector
//! - `tcp_udp`: raw socket escape hatch

pub mod generic;
pub mod http;
pub mod tcp_udp;
pub mod ws;

// Re-export commonly used types and functions from generic
pub use generic::{Timestamp, Value, emit, get, notify, now, set, yield_control};
