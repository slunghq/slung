//! Generic Host ABI — Runtime memory and state access
//!
//! Bindings to Slung core host functions for rule execution:
//! - `slung_set`: write component values to the LWW store
//! - `slung_get`: read component values from the store
//! - `slung_now`: get current HLC timestamp
//! - `slung_yield`: cooperative pause point
//! - `slung_emit`: signal component updates to watchers
//! - `slung_notify`: send notifications to external systems

use serde::{Deserialize, Serialize};

unsafe extern "C" {
    /// Write a component value to the LWW store.
    ///
    /// Stack: [entity_id: i32, component_id: i32, value_ptr: i32, value_len: i32] -> [status: i32]
    ///
    /// `value_ptr` and `value_len` point to JSON-serialized value in guest memory.
    ///
    /// Returns:
    /// - 0: Success
    /// - 1: Invalid parameters (null ptr or zero len)
    /// - 2: Memory read error
    /// - 3: JSON parse error
    /// - 4: Key too long
    /// - 5: LWW store error
    fn slung_set(
        entity_id: usize,
        component_id: usize,
        value_ptr: usize,
        value_len: usize,
    ) -> usize;

    /// Read a component value from the LWW store.
    ///
    /// Stack: [entity_id: i32, component_id: i32] -> [ptr: i32, len: i32]
    ///
    /// Returns (ptr, len) of JSON-serialized value allocated in guest memory.
    /// Returns (0, 0) if not found or error occurs.
    fn slung_get(entity_id: usize, component_id: usize, ptr: *mut usize, len: *mut usize) -> usize;

    /// Get current HLC timestamp.
    ///
    /// Stack: [wall_hi_ptr: i32, wall_lo_ptr: i32, logical_ptr: i32] -> [status: i32]
    ///
    /// Writes HLC timestamp components to guest memory addresses via pointers.
    /// Returns 0 on success, non-zero error code on failure.
    fn slung_now(wall_hi_ptr: *mut u32, wall_lo_ptr: *mut u32, logical_ptr: *mut u32) -> usize;

    /// Cooperative pause point for rule execution.
    ///
    /// Stack: [] -> [status: i32]
    ///
    /// Returns 0 on success, non-zero error code on failure.
    fn slung_yield() -> usize;
}

/// Component value — mirrors the Zig types.Value type
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(untagged)]
pub enum Value {
    /// Boolean value
    Bool(bool),
    /// Signed 64-bit integer
    Int(i64),
    /// 64-bit floating point
    Float(f64),
    /// UTF-8 byte string
    Bytes(String),
}

/// Set a component value in the LWW store.
///
/// Automatically serializes the value to JSON and writes it to the store.
/// Returns `Ok(())` on success, `Err` with status code on failure.
pub fn set<T: Serialize>(entity_id: u32, component_id: u32, value: T) -> std::io::Result<()> {
    let json_bytes = serde_json::to_vec(&value)?;

    // Pass the JSON byte buffer directly to the host.
    let value_ptr = json_bytes.as_ptr() as usize;
    let value_len = json_bytes.len() as usize;

    let status = unsafe {
        slung_set(
            entity_id as usize,
            component_id as usize,
            value_ptr,
            value_len,
        )
    };

    if status == 0 {
        Ok(())
    } else {
        Err(std::io::Error::other(format!(
            "slung_set failed with status: {}",
            status
        )))
    }
}

/// Get a component value from the LWW store.
///
/// Deserializes the stored JSON value into the requested type.
/// Returns `Ok(None)` if value not found, `Ok(Some(value))` on success, `Err` on failure.
pub fn get<T: for<'de> Deserialize<'de>>(
    entity_id: u32,
    component_id: u32,
) -> std::io::Result<Option<T>> {
    let mut ptr: usize = 0;
    let mut len: usize = 0;
    let status = unsafe {
        slung_get(
            entity_id as usize,
            component_id as usize,
            &mut ptr,
            &mut len,
        )
    };

    if ptr == 0 || len == 0 || status != 0 {
        return Ok(None);
    }

    // Read from guest memory, then release the host-allocated buffer.
    let result = match unsafe {
        serde_json::from_slice(std::slice::from_raw_parts(ptr as *const u8, len))
    } {
        Ok(value) => Ok(Some(value)),
        Err(e) => Err(std::io::Error::other(format!("JSON parse error: {}", e))),
    };
    unsafe {
        crate::slung_dealloc(ptr as *mut u8, len);
    }
    result
}

/// HLC timestamp — encodes wall clock, logical counter, and node id
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub struct Timestamp {
    /// Wall-clock time in milliseconds since Unix epoch (high 32 bits)
    pub wall_ms_hi: u32,
    /// Wall-clock time in milliseconds since Unix epoch (low 32 bits)
    pub wall_ms_lo: u32,
    /// Logical counter for same-millisecond ordering
    pub logical: u32,
}

impl Timestamp {
    /// Get wall-clock time as full u64 (ms since Unix epoch)
    pub fn wall_ms(&self) -> u64 {
        ((self.wall_ms_hi as u64) << 32) | (self.wall_ms_lo as u64)
    }
}

/// Get current HLC timestamp.
///
/// Returns timestamp encoding wall-clock time, logical counter, and node id.
pub fn now() -> std::io::Result<Timestamp> {
    let mut wall_ms_hi: u32 = 0;
    let mut wall_ms_lo: u32 = 0;
    let mut logical: u32 = 0;

    let status = unsafe { slung_now(&mut wall_ms_hi, &mut wall_ms_lo, &mut logical) };

    if status == 0 {
        Ok(Timestamp {
            wall_ms_hi,
            wall_ms_lo,
            logical,
        })
    } else {
        Err(std::io::Error::other(format!(
            "slung_now failed with status: {}",
            status
        )))
    }
}

/// Cooperative pause point for rule execution.
///
/// Can be used to signal the scheduler to yield control.
pub fn yield_control() -> std::io::Result<()> {
    let status = unsafe { slung_yield() };

    if status == 0 {
        Ok(())
    } else {
        Err(std::io::Error::other("slung_yield failed"))
    }
}

/// Emit a component update notification.
///
/// Signals that a component has been updated, triggering watchers.
/// Currently a stub — not yet implemented in the Zig host.
///
/// Returns `Ok(())` on success, `Err` on failure.
pub fn emit(_entity_id: u32, _component_id: u32) -> std::io::Result<()> {
    // TODO: Implement slung_emit host function call
    Err(std::io::Error::new(
        std::io::ErrorKind::Other,
        "slung_emit not yet implemented",
    ))
}

/// Send a notification to an external system.
///
/// Notifies listeners or external systems about a state change.
/// Currently a stub — not yet implemented in the Zig host.
///
/// Returns `Ok(())` on success, `Err` on failure.
pub fn notify(_topic: &str, _message: &str) -> std::io::Result<()> {
    // TODO: Implement slung_notify host function call
    Err(std::io::Error::new(
        std::io::ErrorKind::Other,
        "slung_notify not yet implemented",
    ))
}
