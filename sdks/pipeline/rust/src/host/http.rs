//! HTTP Host ABI — HTTP connector bindings
//!
//! Bindings to Slung built-in HTTP connector:
//! - `slung_http_get`: fetch data from HTTP endpoints
//! - `slung_http_post`: send data to HTTP endpoints

/// HTTP GET request to an external endpoint.
///
/// Fetches data from an HTTP URL and returns the response body.
/// Currently a stub — not yet implemented in the Zig host.
///
/// Returns response data on success, error on failure.
pub fn get(_url: &str) -> std::io::Result<Vec<u8>> {
    // TODO: Implement slung_http_get host function call
    Err(std::io::Error::new(
        std::io::ErrorKind::Other,
        "slung_http_get not yet implemented",
    ))
}

/// HTTP POST request to an external endpoint.
///
/// Sends data to an HTTP URL and returns the response body.
/// Currently a stub — not yet implemented in the Zig host.
///
/// Returns response data on success, error on failure.
pub fn post(_url: &str, _data: &[u8]) -> std::io::Result<Vec<u8>> {
    // TODO: Implement slung_http_post host function call
    Err(std::io::Error::new(
        std::io::ErrorKind::Other,
        "slung_http_post not yet implemented",
    ))
}
