//! HTTP Host ABI — HTTP connector bindings
//!
//! Bindings to Slung built-in HTTP connector:
//! - `slung_http_get`: fetch data from HTTP endpoints
//! - `slung_http_post`: send data to HTTP endpoints

unsafe extern "C" {
    /// Perform an HTTP GET request to an external endpoint.
    ///
    /// Stack: [url_ptr: i32, url_len: i32] -> [response_ptr: i32, response_len: i32, status: i32]
    ///
    /// `url_ptr` and `url_len` point to the URL string in guest memory.
    /// Returns (response_ptr, response_len) of response data allocated in guest memory, or (0, 0) on error.
    /// The status code indicates success (0) or failure (non-zero).
    fn slung_http_get(
        url_ptr: usize,
        url_len: usize,
        response_ptr: *mut usize,
        response_len: *mut usize,
    ) -> usize;

    /// Perform an HTTP POST request to an external endpoint.
    ///
    /// Stack: [url_ptr: i32, url_len: i32, data_ptr: i32, data_len: i32] -> [response_ptr: i32, response_len: i32, status: i32]
    ///
    /// `url_ptr` and `url_len` point to the URL string in guest memory.
    /// `data_ptr` and `data_len` point to the request body in guest memory.
    /// Returns (response_ptr, response_len) of response data allocated in guest memory, or (0, 0) on error.
    /// The status code indicates success (0) or failure (non-zero).
    fn slung_http_post(
        url_ptr: usize,
        url_len: usize,
        data_ptr: usize,
        data_len: usize,
        response_ptr: *mut usize,
        response_len: *mut usize,
    ) -> usize;
}

/// HTTP GET request to an external endpoint.
///
/// Fetches data from an HTTP URL and returns the response body.
///
/// Returns response data on success, error on failure.
pub fn get(url: &str) -> std::io::Result<Vec<u8>> {
    let url_ptr = url.as_ptr() as usize;
    let url_len = url.len() as usize;

    let mut response_ptr: usize = 0;
    let mut response_len: usize = 0;

    let status = unsafe { slung_http_get(url_ptr, url_len, &mut response_ptr, &mut response_len) };

    if status != 0 {
        return Err(std::io::Error::other(format!(
            "slung_http_get failed with status: {}",
            status
        )));
    }

    if response_ptr == 0 || response_len == 0 {
        return Ok(Vec::new());
    }

    // Read response from guest memory and create a Vec copy
    let response_bytes =
        unsafe { std::slice::from_raw_parts(response_ptr as *const u8, response_len) };
    Ok(response_bytes.to_vec())
}

/// HTTP POST request to an external endpoint.
///
/// Sends data to an HTTP URL and returns the response body.
///
/// Returns response data on success, error on failure.
pub fn post(url: &str, data: &[u8]) -> std::io::Result<Vec<u8>> {
    let url_ptr = url.as_ptr() as usize;
    let url_len = url.len() as usize;
    let data_ptr = data.as_ptr() as usize;
    let data_len = data.len() as usize;

    let mut response_ptr: usize = 0;
    let mut response_len: usize = 0;

    let status = unsafe {
        slung_http_post(
            url_ptr,
            url_len,
            data_ptr,
            data_len,
            &mut response_ptr,
            &mut response_len,
        )
    };

    if status != 0 {
        return Err(std::io::Error::other(format!(
            "slung_http_post failed with status: {}",
            status
        )));
    }

    if response_ptr == 0 || response_len == 0 {
        return Ok(Vec::new());
    }

    // Read response from guest memory and create a Vec copy
    let response_bytes =
        unsafe { std::slice::from_raw_parts(response_ptr as *const u8, response_len) };
    Ok(response_bytes.to_vec())
}
