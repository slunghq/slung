//! Module-owned persistent key/value storage bindings.

unsafe extern "C" {
    fn slung_store_get(
        key_ptr: usize,
        key_len: usize,
        value_ptr: *mut usize,
        value_len: *mut usize,
    ) -> usize;
    fn slung_store_set(key_ptr: usize, key_len: usize, value_ptr: usize, value_len: usize)
    -> usize;
    fn slung_store_delete(key_ptr: usize, key_len: usize) -> usize;
}

/// Read an opaque module-owned value.
///
/// `Ok(None)` means the key does not exist. Values are copied out of guest
/// memory and released through the module allocator.
pub fn get(key: &[u8]) -> std::io::Result<Option<Vec<u8>>> {
    let mut value_ptr = 0usize;
    let mut value_len = 0usize;
    let status = unsafe {
        slung_store_get(
            key.as_ptr() as usize,
            key.len(),
            &mut value_ptr,
            &mut value_len,
        )
    };
    match status {
        0 => copy_and_free(value_ptr, value_len).map(Some),
        1 => Ok(None),
        code => Err(std::io::Error::other(format!(
            "slung_store_get failed with status: {code}"
        ))),
    }
}

/// Store an opaque module-owned value.
pub fn set(key: &[u8], value: &[u8]) -> std::io::Result<()> {
    let status = unsafe {
        slung_store_set(
            key.as_ptr() as usize,
            key.len(),
            value.as_ptr() as usize,
            value.len(),
        )
    };
    if status == 0 {
        Ok(())
    } else {
        Err(std::io::Error::other(format!(
            "slung_store_set failed with status: {status}"
        )))
    }
}

/// Delete a module-owned value. Returns whether the key existed.
pub fn delete(key: &[u8]) -> std::io::Result<bool> {
    let status = unsafe { slung_store_delete(key.as_ptr() as usize, key.len()) };
    match status {
        0 => Ok(true),
        1 => Ok(false),
        code => Err(std::io::Error::other(format!(
            "slung_store_delete failed with status: {code}"
        ))),
    }
}

fn copy_and_free(ptr: usize, len: usize) -> std::io::Result<Vec<u8>> {
    if ptr == 0 || len == 0 {
        return Ok(Vec::new());
    }
    let bytes = unsafe { std::slice::from_raw_parts(ptr as *const u8, len).to_vec() };
    unsafe { crate::slung_dealloc(ptr as *mut u8, len) };
    Ok(bytes)
}
