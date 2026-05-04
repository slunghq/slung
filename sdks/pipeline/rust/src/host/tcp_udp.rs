//! TCP/UDP Host ABI — Raw socket escape hatch
//!
//! Bindings to Slung raw socket primitives:
//! - `slung_tcp_connect`: establish TCP connections
//! - `slung_tcp_read`: receive data from TCP socket
//! - `slung_tcp_write`: send data over TCP socket
//! - `slung_tcp_close`: close TCP connection
//! - `slung_udp_bind`: bind to UDP port
//! - `slung_udp_recv`: receive UDP datagrams
//! - `slung_udp_send`: send UDP datagrams

/// Establish a TCP connection to a remote endpoint.
///
/// Connects to a host:port and returns a connection handle.
/// Currently a stub — not yet implemented in the Zig host.
///
/// Returns a connection handle on success, error on failure.
pub fn tcp_connect(_host: &str, _port: u16) -> std::io::Result<u64> {
    // TODO: Implement slung_tcp_connect host function call
    Err(std::io::Error::new(
        std::io::ErrorKind::Other,
        "slung_tcp_connect not yet implemented",
    ))
}

/// Read data from a TCP connection.
///
/// Receives up to `len` bytes from a connected socket.
/// Currently a stub — not yet implemented in the Zig host.
///
/// Returns received data on success, error on failure.
pub fn tcp_read(_handle: u64, _len: usize) -> std::io::Result<Vec<u8>> {
    // TODO: Implement slung_tcp_read host function call
    Err(std::io::Error::new(
        std::io::ErrorKind::Other,
        "slung_tcp_read not yet implemented",
    ))
}

/// Write data to a TCP connection.
///
/// Sends data to a connected socket.
/// Currently a stub — not yet implemented in the Zig host.
///
/// Returns `Ok(())` on success, `Err` on failure.
pub fn tcp_write(_handle: u64, _data: &[u8]) -> std::io::Result<()> {
    // TODO: Implement slung_tcp_write host function call
    Err(std::io::Error::new(
        std::io::ErrorKind::Other,
        "slung_tcp_write not yet implemented",
    ))
}

/// Close a TCP connection.
///
/// Closes a connected socket and frees its resources.
/// Currently a stub — not yet implemented in the Zig host.
///
/// Returns `Ok(())` on success, `Err` on failure.
pub fn tcp_close(_handle: u64) -> std::io::Result<()> {
    // TODO: Implement slung_tcp_close host function call
    Err(std::io::Error::new(
        std::io::ErrorKind::Other,
        "slung_tcp_close not yet implemented",
    ))
}

/// Bind to a UDP port and return a socket handle.
///
/// Binds to a local address and port for receiving UDP datagrams.
/// Currently a stub — not yet implemented in the Zig host.
///
/// Returns a socket handle on success, error on failure.
pub fn udp_bind(_addr: &str, _port: u16) -> std::io::Result<u64> {
    // TODO: Implement slung_udp_bind host function call
    Err(std::io::Error::new(
        std::io::ErrorKind::Other,
        "slung_udp_bind not yet implemented",
    ))
}

/// Receive a UDP datagram.
///
/// Receives a datagram from a bound UDP socket.
/// Currently a stub — not yet implemented in the Zig host.
///
/// Returns (data, source_address) on success, error on failure.
pub fn udp_recv(_handle: u64) -> std::io::Result<(Vec<u8>, String)> {
    // TODO: Implement slung_udp_recv host function call
    Err(std::io::Error::new(
        std::io::ErrorKind::Other,
        "slung_udp_recv not yet implemented",
    ))
}

/// Send a UDP datagram to a remote endpoint.
///
/// Sends data to a remote address via UDP socket.
/// Currently a stub — not yet implemented in the Zig host.
///
/// Returns `Ok(())` on success, `Err` on failure.
pub fn udp_send(_handle: u64, _addr: &str, _port: u16, _data: &[u8]) -> std::io::Result<()> {
    // TODO: Implement slung_udp_send host function call
    Err(std::io::Error::new(
        std::io::ErrorKind::Other,
        "slung_udp_send not yet implemented",
    ))
}
