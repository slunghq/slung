//! WebSocket Host ABI — WebSocket connector bindings
//!
//! Bindings to Slung built-in WebSocket connector:
//! - `slung_ws_connect`: establish WebSocket connections
//! - `slung_ws_next`: receive messages from WebSocket
//! - `slung_ws_send`: send messages over WebSocket

/// Connect to a WebSocket endpoint.
///
/// Establishes a WebSocket connection to a URL and returns a connection handle.
/// Currently a stub — not yet implemented in the Zig host.
///
/// Returns a connection handle on success, error on failure.
pub fn connect(_url: &str) -> std::io::Result<u64> {
    // TODO: Implement slung_ws_connect host function call
    Err(std::io::Error::new(
        std::io::ErrorKind::Other,
        "slung_ws_connect not yet implemented",
    ))
}

/// Receive the next message from a WebSocket connection.
///
/// Blocks until a message is available or the connection is closed.
/// Currently a stub — not yet implemented in the Zig host.
///
/// Returns message data on success, error on failure.
pub fn next(_handle: u64) -> std::io::Result<Vec<u8>> {
    // TODO: Implement slung_ws_next host function call
    Err(std::io::Error::new(
        std::io::ErrorKind::Other,
        "slung_ws_next not yet implemented",
    ))
}

/// Send a message over a WebSocket connection.
///
/// Sends data to a connected WebSocket endpoint.
/// Currently a stub — not yet implemented in the Zig host.
///
/// Returns `Ok(())` on success, `Err` on failure.
pub fn send(_handle: u64, _data: &[u8]) -> std::io::Result<()> {
    // TODO: Implement slung_ws_send host function call
    Err(std::io::Error::new(
        std::io::ErrorKind::Other,
        "slung_ws_send not yet implemented",
    ))
}
