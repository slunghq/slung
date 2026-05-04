use slung::prelude::*;
use slung_macros::{component, rule, source};

// source declares the entity and its components together
// each component field carries its mapper function
#[source(builtin = "ws")]
struct SensorData {
    #[config]
    path: &'static str,

    #[component(map = parse_temperature)]
    temperature: Temperature,

    #[component(map = parse_humidity)]
    humidity: Humidity,

    #[component]
    status: SensorStatus,
}

// component declares the type — serialization glue only
// no entity binding here, that happens via the source field
#[component]
struct Temperature {
    value: f32,
    unit: String,
    ts: u64,
}

#[component]
struct Humidity {
    value: f32,
    unit: String,
    ts: u64,
}

#[component]
enum SensorStatus {
    Ok {
        temp: f32,
        humidity: f32,
        since: u64,
    },
    Alert {
        reason: String,
        since: u64,
    },
}

// mappers — translate raw source bytes into typed component values
fn parse_temperature(raw: &[u8]) -> Result<Temperature> {
    let json: serde_json::Value = serde_json::from_slice(raw)?;
    Ok(Temperature {
        value: json["temperature"].as_f64().unwrap_or(0.0) as f32,
        unit: json["unit"].as_str().unwrap_or("C").to_string(),
        ts: json["ts"].as_u64().unwrap_or(0),
    })
}

fn parse_humidity(raw: &[u8]) -> Result<Humidity> {
    let json: serde_json::Value = serde_json::from_slice(raw)?;
    Ok(Humidity {
        value: json["humidity"].as_f64().unwrap_or(0.0) as f32,
        unit: "%".to_string(),
        ts: json["ts"].as_u64().unwrap_or(0),
    })
}

// rule references components through the source struct's typed fields
// ctx carries entity scope — no raw IDs
#[rule(
    watch = [SensorData::temperature],
    priority = 10,
)]
fn on_temperature_update(ctx: &RuleContext) -> Result<()> {
    let temp = ctx.get::<Temperature>(SensorData::temperature)?;
    eprintln!("temperature update: {:.1}°{}", temp.value, temp.unit);
    Ok(())
}

#[rule(
    watch = [SensorData::temperature, SensorData::humidity],
    priority = 5,
)]
fn on_sensor_update(ctx: &RuleContext) -> Result<()> {
    let temp = ctx.get::<Temperature>(SensorData::temperature)?;
    let humidity = ctx.get::<Humidity>(SensorData::humidity)?;

    let status = if temp.value > 40.0 {
        SensorStatus::Alert {
            reason: format!("temperature critical: {:.1}°{}", temp.value, temp.unit),
            since: ctx.now(),
        }
    } else {
        SensorStatus::Ok {
            temp: temp.value,
            humidity: humidity.value,
            since: ctx.now(),
        }
    };

    // set writes a typed derived component back into active memory
    // no raw IDs, no JSON — the host handles serialization
    ctx.set(SensorData::status, status)?;

    ctx.yield_now();
    Ok(())
}

fn main() {}
