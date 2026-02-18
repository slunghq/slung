use slung::prelude::*;

#[main]
fn main() -> Result<()> {
    // Subscribe to live stream updates.
    let handle = query_live("SUM:temp:[sensor=1]")?;
    poll_handle(handle, on_event, 100.0)?;

    Ok(())
}

fn on_event(event: Event, alert_threshold: f64) -> Result<()> {
    if event.value > alert_threshold {
        println!("event timestamp={} value={}", event.timestamp, event.value);
        for producer in event.producers {
            writeback_ws(producer, "ALERT: threshold exceeded")?;
        }
    }

    Ok(())
}
