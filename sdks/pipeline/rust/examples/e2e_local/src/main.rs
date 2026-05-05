use slung::prelude::*;

// Component types
#[component]
struct Reading {
    value: f64,
}

#[component]
struct Alert {
    triggered: bool,
}

#[component]
struct Notification {
    msg: String,
}

// Source with mappers
#[source(builtin = "ws")]
struct LocalExec {
    #[config]
    path: &'static str,

    #[component(map = parse_reading)]
    reading: Reading,

    #[component(map = parse_alert)]
    alert: Alert,

    #[component(map = parse_notification)]
    notification: Notification,
}

// Mappers — translate raw source bytes into typed component values
fn parse_reading(raw: &[u8]) -> Result<Reading> {
    let json: serde_json::Value = serde_json::from_slice(raw)?;
    let value = if json.is_number() {
        json.as_f64().unwrap_or(0.0)
    } else {
        json["value"].as_f64().unwrap_or(0.0)
    };
    Ok(Reading { value })
}

fn parse_alert(raw: &[u8]) -> Result<Alert> {
    let json: serde_json::Value = serde_json::from_slice(raw)?;
    let triggered = if json.is_boolean() {
        json.as_bool().unwrap_or(false)
    } else {
        json["triggered"].as_bool().unwrap_or(false)
    };
    Ok(Alert { triggered })
}

fn parse_notification(raw: &[u8]) -> Result<Notification> {
    let json: serde_json::Value = serde_json::from_slice(raw)?;
    let msg = if json.is_string() {
        json.as_str().unwrap_or("").to_string()
    } else {
        json["msg"].as_str().unwrap_or("").to_string()
    };
    Ok(Notification { msg })
}

// Rules reference components through the source struct's typed fields
#[rule(
    watch = [LocalExec::reading],
    priority = 10,
)]
fn on_reading(ctx: &RuleContext) -> Result<()> {
    let reading = ctx.get::<Reading>(LocalExec::reading)?;
    ctx.set(
        LocalExec::alert,
        Alert {
            triggered: reading.value > 10.0,
        },
    )?;
    Ok(())
}

#[rule(
    watch = [LocalExec::alert],
    priority = 5,
)]
fn on_alert(ctx: &RuleContext) -> Result<()> {
    let alert = ctx.get::<Alert>(LocalExec::alert)?;
    let msg = if alert.triggered {
        "ALERT: reading exceeded threshold".to_string()
    } else {
        "OK: reading normal".to_string()
    };
    ctx.set(LocalExec::notification, Notification { msg })?;
    Ok(())
}

fn main() {}
