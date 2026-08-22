//! HTTP Host ABI — HTTP connector bindings

unsafe extern "C" {
    fn slung_http_get(
        url_ptr: usize,
        url_len: usize,
        response_ptr: *mut usize,
        response_len: *mut usize,
    ) -> usize;

    fn slung_http_post(
        url_ptr: usize,
        url_len: usize,
        data_ptr: usize,
        data_len: usize,
        response_ptr: *mut usize,
        response_len: *mut usize,
    ) -> usize;

}

pub fn get(url: &str) -> std::io::Result<Vec<u8>> {
    let mut response_ptr = 0;
    let mut response_len = 0;
    let status = unsafe {
        slung_http_get(
            url.as_ptr() as usize,
            url.len(),
            &mut response_ptr,
            &mut response_len,
        )
    };
    if status != 0 {
        return Err(std::io::Error::other(format!(
            "slung_http_get failed with status: {}",
            status
        )));
    }
    copy_and_free_response(response_ptr, response_len)
}

pub fn post(url: &str, data: &[u8]) -> std::io::Result<Vec<u8>> {
    let mut response_ptr = 0;
    let mut response_len = 0;
    let status = unsafe {
        slung_http_post(
            url.as_ptr() as usize,
            url.len(),
            data.as_ptr() as usize,
            data.len(),
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
    copy_and_free_response(response_ptr, response_len)
}

fn copy_and_free_response(ptr: usize, len: usize) -> std::io::Result<Vec<u8>> {
    if ptr == 0 || len == 0 {
        return Ok(Vec::new());
    }

    let response = unsafe { std::slice::from_raw_parts(ptr as *const u8, len).to_vec() };
    unsafe {
        crate::slung_dealloc(ptr as *mut u8, len);
    }
    Ok(response)
}
