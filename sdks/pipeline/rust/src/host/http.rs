//! HTTP host bindings.

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Response {
    pub status: u16,
    pub headers: Vec<(String, String)>,
    pub body: Vec<u8>,
}

unsafe extern "C" {
    fn slung_http_get(
        url_ptr: usize,
        url_len: usize,
        request_headers_ptr: usize,
        request_headers_len: usize,
        response_ptr: *mut usize,
        response_len: *mut usize,
        response_headers_ptr: *mut usize,
        response_headers_len: *mut usize,
    ) -> usize;

    fn slung_http_post(
        url_ptr: usize,
        url_len: usize,
        request_headers_ptr: usize,
        request_headers_len: usize,
        body_ptr: usize,
        body_len: usize,
        response_ptr: *mut usize,
        response_len: *mut usize,
        response_headers_ptr: *mut usize,
        response_headers_len: *mut usize,
    ) -> usize;

    fn slung_http_put(
        url_ptr: usize,
        url_len: usize,
        request_headers_ptr: usize,
        request_headers_len: usize,
        body_ptr: usize,
        body_len: usize,
        response_ptr: *mut usize,
        response_len: *mut usize,
        response_headers_ptr: *mut usize,
        response_headers_len: *mut usize,
    ) -> usize;

    fn slung_http_delete(
        url_ptr: usize,
        url_len: usize,
        request_headers_ptr: usize,
        request_headers_len: usize,
        response_ptr: *mut usize,
        response_len: *mut usize,
        response_headers_ptr: *mut usize,
        response_headers_len: *mut usize,
    ) -> usize;
}

pub fn get(url: &str, headers: &[(&str, &str)]) -> std::io::Result<Response> {
    let mut response = ResponseBuffers::default();
    let request_headers = encode_headers(headers)?;
    let status = unsafe {
        slung_http_get(
            url.as_ptr() as usize,
            url.len(),
            request_headers.as_ptr() as usize,
            request_headers.len(),
            &mut response.body_ptr,
            &mut response.body_len,
            &mut response.headers_ptr,
            &mut response.headers_len,
        )
    };
    response.into_result(status)
}

pub fn post(url: &str, body: &[u8], headers: &[(&str, &str)]) -> std::io::Result<Response> {
    request_with_body(slung_http_post, url, body, headers)
}

pub fn put(url: &str, body: &[u8], headers: &[(&str, &str)]) -> std::io::Result<Response> {
    request_with_body(slung_http_put, url, body, headers)
}

pub fn delete(url: &str, headers: &[(&str, &str)]) -> std::io::Result<Response> {
    let mut response = ResponseBuffers::default();
    let request_headers = encode_headers(headers)?;
    let status = unsafe {
        slung_http_delete(
            url.as_ptr() as usize,
            url.len(),
            request_headers.as_ptr() as usize,
            request_headers.len(),
            &mut response.body_ptr,
            &mut response.body_len,
            &mut response.headers_ptr,
            &mut response.headers_len,
        )
    };
    response.into_result(status)
}

type BodyRequest = unsafe extern "C" fn(
    usize,
    usize,
    usize,
    usize,
    usize,
    usize,
    *mut usize,
    *mut usize,
    *mut usize,
    *mut usize,
) -> usize;

fn request_with_body(
    request: BodyRequest,
    url: &str,
    body: &[u8],
    headers: &[(&str, &str)],
) -> std::io::Result<Response> {
    let mut response = ResponseBuffers::default();
    let request_headers = encode_headers(headers)?;
    let status = unsafe {
        request(
            url.as_ptr() as usize,
            url.len(),
            request_headers.as_ptr() as usize,
            request_headers.len(),
            body.as_ptr() as usize,
            body.len(),
            &mut response.body_ptr,
            &mut response.body_len,
            &mut response.headers_ptr,
            &mut response.headers_len,
        )
    };
    response.into_result(status)
}

#[derive(Default)]
struct ResponseBuffers {
    body_ptr: usize,
    body_len: usize,
    headers_ptr: usize,
    headers_len: usize,
}

impl ResponseBuffers {
    fn into_result(self, status: usize) -> std::io::Result<Response> {
        if status == 0 {
            return Err(std::io::Error::other(
                "HTTP request failed before receiving a response",
            ));
        }

        let body = copy_and_free(self.body_ptr, self.body_len)?;
        let headers = decode_headers(self.headers_ptr, self.headers_len)?;
        Ok(Response {
            status: status as u16,
            headers,
            body,
        })
    }
}

fn encode_headers(headers: &[(&str, &str)]) -> std::io::Result<Vec<u8>> {
    let mut encoded = Vec::new();
    for (name, value) in headers {
        let name_len = u32::try_from(name.len())
            .map_err(|_| std::io::Error::other("HTTP header name is too long"))?;
        let value_len = u32::try_from(value.len())
            .map_err(|_| std::io::Error::other("HTTP header value is too long"))?;
        encoded.extend_from_slice(&name_len.to_le_bytes());
        encoded.extend_from_slice(&value_len.to_le_bytes());
        encoded.extend_from_slice(name.as_bytes());
        encoded.extend_from_slice(value.as_bytes());
    }
    Ok(encoded)
}

fn decode_headers(ptr: usize, len: usize) -> std::io::Result<Vec<(String, String)>> {
    if ptr == 0 || len == 0 {
        return Ok(Vec::new());
    }

    let bytes = unsafe { std::slice::from_raw_parts(ptr as *const u8, len) };
    let result = decode_header_bytes(bytes);
    unsafe { crate::slung_dealloc(ptr as *mut u8, len) };
    result
}

fn decode_header_bytes(bytes: &[u8]) -> std::io::Result<Vec<(String, String)>> {
    let mut cursor = 0;
    let mut headers = Vec::new();
    while cursor < bytes.len() {
        if bytes.len() - cursor < 8 {
            return Err(std::io::Error::other("invalid HTTP response headers"));
        }
        let name_len = u32::from_le_bytes(bytes[cursor..cursor + 4].try_into().unwrap()) as usize;
        let value_len =
            u32::from_le_bytes(bytes[cursor + 4..cursor + 8].try_into().unwrap()) as usize;
        cursor += 8;
        let name_end = cursor
            .checked_add(name_len)
            .ok_or_else(|| std::io::Error::other("invalid HTTP response headers"))?;
        let value_end = name_end
            .checked_add(value_len)
            .ok_or_else(|| std::io::Error::other("invalid HTTP response headers"))?;
        if value_end > bytes.len() {
            return Err(std::io::Error::other("invalid HTTP response headers"));
        }
        let name = String::from_utf8(bytes[cursor..name_end].to_vec())
            .map_err(|_| std::io::Error::other("HTTP response header name is not UTF-8"))?;
        let value = String::from_utf8(bytes[name_end..value_end].to_vec())
            .map_err(|_| std::io::Error::other("HTTP response header value is not UTF-8"))?;
        headers.push((name, value));
        cursor = value_end;
    }
    Ok(headers)
}

fn copy_and_free(ptr: usize, len: usize) -> std::io::Result<Vec<u8>> {
    if ptr == 0 || len == 0 {
        return Ok(Vec::new());
    }
    let response = unsafe { std::slice::from_raw_parts(ptr as *const u8, len).to_vec() };
    unsafe { crate::slung_dealloc(ptr as *mut u8, len) };
    Ok(response)
}
