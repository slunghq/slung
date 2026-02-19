#![doc = include_str!("../README.md")]
use serde::{Deserialize, Serialize};

use crate::region::Region;
use std::io::Result;

#[doc(hidden)]
pub mod region;

unsafe extern "C" {
    fn u_query_live(filter_ptr: usize) -> u64;
    fn u_query_history(filter_ptr: usize) -> f64;

    fn u_poll_handle(handle_ptr: u64) -> usize;
    fn u_free_handle(handle_ptr: u64) -> u32;

    fn u_write_event(timestamp_ptr: usize, value_ptr: usize, tags_ptr: usize) -> u32;

    fn u_writeback_ws(producer_ptr: u64, data_ptr: usize) -> u32;
    fn u_writeback_http(url_ptr: usize, data_ptr: usize, method_ptr: u32) -> usize;
}

pub type QueryHandle = u64;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Event {
    /// Unix timestamp in microseconds.
    pub timestamp: i64,
    pub value: f64,
    pub tags: Vec<String>,
    pub producers: Vec<u64>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Avg {
    pub sum: f64,
    pub count: u64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub enum PollState {
    Sum(f64),
    Avg(Avg),
    Min(f64),
    Max(f64),
}

// --- Query Handling ---
pub fn query_live(filter: &str) -> Result<QueryHandle> {
    let filter = Region::build(filter.as_bytes());
    let filter_ptr = &*filter as *const Region;

    let handle = unsafe { u_query_live(filter_ptr as usize) } as QueryHandle;

    Ok(handle)
}

pub fn query_history(filter: &str) -> Result<f64> {
    let filter = Region::build(filter.as_bytes());
    let filter_ptr = &*filter as *const Region;

    Ok(unsafe { u_query_history(filter_ptr as usize) })
}

pub fn poll_handle<F, A>(handle: QueryHandle, callback: F, args: A) -> Result<()>
where
    F: Fn(Event, A) -> Result<()>,
    A: Clone,
{
    loop {
        let data_ptr = unsafe { u_poll_handle(handle) };

        if data_ptr == 0 {
            continue;
        }

        let data = unsafe { Region::consume(data_ptr as *mut Region) };
        let event = serde_json::from_slice(&data)?;

        callback(event, args.clone())?;
    }
}

pub fn poll_handle_state(handle: QueryHandle) -> Result<Option<PollState>> {
    let data_ptr = unsafe { u_poll_handle(handle) };

    if data_ptr == 0 {
        return Ok(None);
    }

    let data = unsafe { Region::consume(data_ptr as *mut Region) };
    let event = serde_json::from_slice(&data)?;

    Ok(Some(event))
}

pub fn free_handle(handle: QueryHandle) -> Result<()> {
    let result = unsafe { u_free_handle(handle) };

    if result == 0 {
        Ok(())
    } else {
        // TODO: custom error type
        Err(std::io::Error::other("Failed to free handle"))
    }
}

// --- Writing events ---
/// Return current Unix epoch timestamp in microseconds.
pub fn unix_micros() -> i64 {
    let now = std::time::SystemTime::now();
    let duration = now
        .duration_since(std::time::UNIX_EPOCH)
        .expect("system clock is before unix epoch");
    i64::try_from(duration.as_micros()).expect("unix micros does not fit i64")
}

pub fn write_event(timestamp: i64, value: f64, tags: Vec<String>) -> Result<()> {
    let timestamp = Region::build(timestamp.to_string().as_bytes());
    let timestamp_ptr = &*timestamp as *const Region;
    let value = Region::build(value.to_string().as_bytes());
    let value_ptr = &*value as *const Region;
    let tags = Region::build(tags.join(",").as_bytes());
    let tags_ptr = &*tags as *const Region;

    let result = unsafe { u_write_event(timestamp_ptr as usize, value_ptr as usize, tags_ptr as usize) };

    if result == 0 {
        Ok(())
    } else {
        Err(std::io::Error::other("Failed to write event"))
    }
}

// --- Write backs ---
pub fn writeback_ws(destination: u64, data: &str) -> Result<()> {
    let data = Region::build(data.as_bytes());
    let data_ptr = &*data as *const Region;

    let result = unsafe { u_writeback_ws(destination, data_ptr as usize) };

    if result == 0 {
        Ok(())
    } else {
        Err(std::io::Error::other("Failed to writeback to websocket"))
    }
}

pub enum WritebackMethod {
    GET,
    POST,
    PUT,
    DELETE,
}

pub fn writeback_http(
    destination: &str,
    data: &str,
    method: WritebackMethod,
) -> Result<Option<Vec<u8>>> {
    let destination = Region::build(destination.as_bytes());
    let destination_ptr = &*destination as *const Region;
    let data = Region::build(data.as_bytes());
    let data_ptr = &*data as *const Region;
    let method = match method {
        WritebackMethod::GET => 0,
        WritebackMethod::POST => 1,
        WritebackMethod::PUT => 2,
        WritebackMethod::DELETE => 3,
    };

    let result =
        unsafe { u_writeback_http(destination_ptr as usize, data_ptr as usize, method as u32) };

    if result == 0 {
        Ok(None)
    } else {
        Ok(Some(unsafe { Region::consume(result as *mut Region) }))
    }
}

pub mod prelude {
    pub use crate::Event;
    pub use crate::{
        free_handle, poll_handle, poll_handle_state, query_history, query_live, unix_micros,
        write_event, writeback_ws,
    };
    pub use slung_macros::main;
    pub use std::io::Result;
}
