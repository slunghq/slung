# Slung Rust SDK

An abstraction library for interacting with the [*Slung runtime*](https://github.com/slunghq/slung).

## Quickstart

Add to your rust project's `Cargo.toml`:

```toml
[dependencies]
slung = "0.1.0"
```

And then at the top of your module:

```rust
use slung::prelude::*;
```

## Example
Here's a basic anomaly detection example:

```rust
use slung::prelude::*;

#[main]
fn main() -> Result<()> {
    // Subscribe to live stream updates.
    let handle = query_live("AVG:temp:[sensor=1]")?;
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
```

## Query Syntax

`OP:SERIES:[TAGS]:[RANGE]`

+ RANGE is optional
+ OP: AVG, MIN, MAX, SUM, COUNT
+ TAGS: AND, OR, NOT
+ RANGE: `[start_time,end_time]`. Timestamps in microseconds. Also supports sec, min, hour, day, week (short & plural forms apply).

## License

Unlike the root project, this SDK is licensed under the MIT License - see the [LICENSE](../LICENSE) file for details.
