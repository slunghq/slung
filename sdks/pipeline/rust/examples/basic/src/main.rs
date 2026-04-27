#![allow(unsafe_code)]
#![allow(unsafe_attr_outside_unsafe)]

use slung_macros::{component, rule, source};

/// Sensor data source - represents incoming sensor readings
#[source]
struct SensorData {
    temperature: f32,
    humidity: f32,
}

/// Temperature component descriptor
#[component]
struct Temperature {
    value: f32,
    unit: String,
    timestamp: u64,
}

/// Humidity component descriptor
#[component]
struct Humidity {
    value: f32,
    unit: String,
    timestamp: u64,
}

/// Rule that fires when temperature reading arrives
#[rule(watch = ["SensorData::temperature"], priority = 10)]
fn on_temperature_update() {
    // When a new temperature reading arrives from SensorData,
    // this rule is triggered by the host via the capability graph
    eprintln!("Temperature update received");
}

/// Rule that fires when either temperature or humidity changes
#[rule(watch = ["SensorData::temperature", "SensorData::humidity"], priority = 5)]
fn on_sensor_update() {
    // This rule triggers whenever either sensor component becomes dirty.
    // The host consults the capability graph to determine which rules to fire.
    eprintln!("Sensor update received");
}

fn main() {}
