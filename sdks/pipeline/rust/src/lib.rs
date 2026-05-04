#![doc = include_str!("../README.md")]
use serde::{Deserialize, Serialize};
use std::marker::PhantomData;

use std::io::Result;

/// Host ABI bindings — organized by function category
pub mod host;

/// Typed component selector used by descriptor-based rules.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ComponentKey<T> {
    /// Source name registered in the descriptor graph.
    pub source: &'static str,
    /// Component field name within the source descriptor.
    pub field: &'static str,
    /// Runtime component id used by the lower-level host ABI.
    pub component_id: u32,
    _marker: PhantomData<fn() -> T>,
}

impl<T> ComponentKey<T> {
    /// Create a typed component selector.
    pub const fn new(source: &'static str, field: &'static str, component_id: u32) -> Self {
        Self {
            source,
            field,
            component_id,
            _marker: PhantomData,
        }
    }
}

/// Rule execution context for typed descriptor-based handlers.
#[derive(Debug, Clone, Copy, Default)]
pub struct RuleContext {
    entity_id: u32,
}

impl RuleContext {
    /// Build a rule context for a specific entity id.
    pub const fn new(entity_id: u32) -> Self {
        Self { entity_id }
    }

    /// Return the current entity id.
    pub const fn entity_id(&self) -> u32 {
        self.entity_id
    }

    /// Read and deserialize the current value of a typed component.
    pub fn get<T>(&self, component: ComponentKey<T>) -> Result<T>
    where
        T: for<'de> Deserialize<'de>,
    {
        match host::generic::get(self.entity_id, component.component_id)? {
            Some(value) => Ok(value),
            None => Err(std::io::Error::new(
                std::io::ErrorKind::NotFound,
                format!(
                    "component {}::{} has no value for entity {}",
                    component.source, component.field, self.entity_id
                ),
            )),
        }
    }

    /// Serialize and store a typed component value.
    pub fn set<T>(&self, component: ComponentKey<T>, value: T) -> Result<()>
    where
        T: Serialize,
    {
        host::generic::set(self.entity_id, component.component_id, value)
    }

    /// Return the current host time as unix milliseconds.
    pub fn now(&self) -> u64 {
        host::generic::now().ok().map(|t| t.wall_ms()).unwrap_or(0)
    }

    /// Yield execution back to the host scheduler.
    pub fn yield_now(&self) {
        let _ = host::generic::yield_control();
    }
}

/// Common imports for workflow handlers.
pub mod prelude {
    pub use crate::{ComponentKey, RuleContext};
    // Generic ABI exports (most commonly used)
    pub use crate::host::generic::{Timestamp, Value, emit, get, notify, now, set, yield_control};
    // Connectors
    pub use crate::host::{http, tcp_udp, ws};
    pub use slung_macros::*;
    pub use std::io::Result;
}
