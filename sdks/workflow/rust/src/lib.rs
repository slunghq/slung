#![doc = include_str!("../README.md")]
use serde::{Deserialize, Serialize};

use crate::region::Region;
use std::io::Result;

#[doc(hidden)]
pub mod region;

unsafe extern "C" {
    /// Host live-query registration entrypoint.
    ///
    /// `filter_ptr` is a guest pointer to a `Region` containing UTF-8 filter bytes.
    /// Returns a query handle, or `0` on host-side failure.
    fn u_query_live(filter_ptr: usize) -> u64;
    /// Host historical-query aggregation entrypoint.
    ///
    /// `filter_ptr` is a guest pointer to a `Region` containing UTF-8 filter bytes.
    /// Returns an aggregated `f64`; host also uses `0.0` on failure.
    fn u_query_history(filter_ptr: usize) -> f64;

    /// Host polling entrypoint for a live query handle.
    ///
    /// Returns a guest pointer to a `Region` containing JSON, or `0` if no event is available.
    fn u_poll_handle(handle_ptr: u64) -> usize;
    /// Host query-handle cleanup entrypoint.
    ///
    /// Returns `0` on success and non-zero on failure.
    fn u_free_handle(handle_ptr: u64) -> u32;

    /// Host event-ingest entrypoint.
    ///
    /// All parameters are guest pointers to `Region` values containing UTF-8 text.
    /// Returns `0` on success and non-zero on failure.
    fn u_write_event(timestamp_ptr: usize, value_ptr: usize, tags_ptr: usize) -> u32;

    /// Host websocket writeback entrypoint.
    ///
    /// `producer_ptr` is the destination connection id and `data_ptr` points to a `Region`.
    /// Returns `0` on success and non-zero on failure.
    fn u_writeback_ws(producer_ptr: u64, data_ptr: usize) -> u32;
    /// Host HTTP writeback entrypoint.
    ///
    /// Returns a guest pointer to a response `Region`, or `0` when no response body is available
    /// or the request fails.
    fn u_writeback_http(url_ptr: usize, data_ptr: usize, method_ptr: u32) -> usize;
}

/// Opaque handle returned by live-query registration.
pub type QueryHandle = u64;

/// Event payload returned by host polling.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Event {
    /// Unix timestamp in microseconds.
    pub timestamp: i64,
    /// Numeric value associated with the event.
    pub value: f64,
    /// Event tags from the host payload.
    pub tags: Vec<String>,
    /// Producer ids associated with the event payload.
    pub producers: Vec<u64>,
}

/// Running average state.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Avg {
    /// Running sum.
    pub sum: f64,
    /// Number of samples in the running sum.
    pub count: u64,
}

/// Polled aggregate state variants.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub enum PollState {
    /// Sum aggregate.
    Sum(f64),
    /// Average aggregate.
    Avg(Avg),
    /// Minimum aggregate.
    Min(f64),
    /// Maximum aggregate.
    Max(f64),
}

/// Register a live query and return its host handle.
///
/// `filter` uses the host query syntax. This function returns `Ok(0)` when host registration
/// fails because the host ABI uses `0` as a sentinel value.
pub fn query_live(filter: &str) -> Result<QueryHandle> {
    let filter = Region::build(filter.as_bytes());
    let filter_ptr = &*filter as *const Region;

    let handle = unsafe { u_query_live(filter_ptr as usize) } as QueryHandle;

    Ok(handle)
}

/// Execute a historical aggregation query and return the aggregate value.
///
/// The host ABI returns `0.0` both for valid zero results and some failures.
pub fn query_history(filter: &str) -> Result<f64> {
    let filter = Region::build(filter.as_bytes());
    let filter_ptr = &*filter as *const Region;

    Ok(unsafe { u_query_history(filter_ptr as usize) })
}

/// Poll a live query forever and invoke `callback` for each received event.
///
/// This function does not return under normal operation.
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

/// Poll a live query once and decode aggregate state if available.
pub fn poll_handle_state(handle: QueryHandle) -> Result<Option<PollState>> {
    let data_ptr = unsafe { u_poll_handle(handle) };

    if data_ptr == 0 {
        return Ok(None);
    }

    let data = unsafe { Region::consume(data_ptr as *mut Region) };
    let event = serde_json::from_slice(&data)?;

    Ok(Some(event))
}

/// Free a live query handle on the host.
pub fn free_handle(handle: QueryHandle) -> Result<()> {
    let result = unsafe { u_free_handle(handle) };

    if result == 0 {
        Ok(())
    } else {
        Err(std::io::Error::other("Failed to free handle"))
    }
}

/// Return the current Unix epoch timestamp in microseconds.
pub fn unix_micros() -> i64 {
    let now = std::time::SystemTime::now();
    let duration = now
        .duration_since(std::time::UNIX_EPOCH)
        .expect("system clock is before unix epoch");
    i64::try_from(duration.as_micros()).expect("unix micros does not fit i64")
}

/// Write a new event to the host.
///
/// `tags` is encoded as CSV. `series=<name>` is interpreted specially by the host as the
/// series name; all other tokens are treated as tags.
pub fn write_event(timestamp: i64, value: f64, tags: Vec<String>) -> Result<()> {
    let timestamp = Region::build(timestamp.to_string().as_bytes());
    let timestamp_ptr = &*timestamp as *const Region;
    let value = Region::build(value.to_string().as_bytes());
    let value_ptr = &*value as *const Region;
    let tags = Region::build(tags.join(",").as_bytes());
    let tags_ptr = &*tags as *const Region;

    let result = unsafe {
        u_write_event(
            timestamp_ptr as usize,
            value_ptr as usize,
            tags_ptr as usize,
        )
    };

    if result == 0 {
        Ok(())
    } else {
        Err(std::io::Error::other("Failed to write event"))
    }
}

/// Write back text data to a websocket producer destination.
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

/// HTTP method mapping expected by the host writeback API.
pub enum WritebackMethod {
    /// HTTP GET.
    GET,
    /// HTTP POST.
    POST,
    /// HTTP PUT.
    PUT,
    /// HTTP DELETE.
    DELETE,
}

/// Send an HTTP writeback request through the host.
///
/// Returns `Ok(None)` when no response body is returned or the host fails the request.
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

/// Common imports for workflow handlers.
pub mod prelude {
    pub use crate::Event;
    pub use crate::{
        free_handle, poll_handle, poll_handle_state, query_history, query_live, unix_micros,
        write_event, writeback_ws,
    };
    pub use slung_macros::main;
    pub use std::io::Result;
}
