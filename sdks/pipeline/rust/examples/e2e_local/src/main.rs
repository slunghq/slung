use slung::prelude::*;
use slung_macros::{component, rule, source};

#[derive(serde::Deserialize)]
#[serde(untagged)]
enum IncomingMessage {
    Reading { value: f64 },
    Alert { triggered: bool },
    Notification { msg: String },
}

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
    #[config(value = "local-exec")]
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
    match serde_json::from_slice::<IncomingMessage>(raw)? {
        IncomingMessage::Reading { value } => Ok(Reading { value }),
        _ => Err(std::io::Error::other("payload is not a reading")),
    }
}

fn parse_alert(raw: &[u8]) -> Result<Alert> {
    match serde_json::from_slice::<IncomingMessage>(raw)? {
        IncomingMessage::Alert { triggered } => Ok(Alert { triggered }),
        _ => Err(std::io::Error::other("payload is not an alert")),
    }
}

fn parse_notification(raw: &[u8]) -> Result<Notification> {
    match serde_json::from_slice::<IncomingMessage>(raw)? {
        IncomingMessage::Notification { msg } => Ok(Notification { msg }),
        _ => Err(std::io::Error::other("payload is not a notification")),
    }
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
