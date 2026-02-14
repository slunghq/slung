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

fn main() -> Result {
  // Query live data stream
  let handle = query_live("AVG:temp:[sensor=1]")?;
  
  // Query last hour's baseline
  let baseline = query_history("AVG:temp:[sensor=1]:[1h,now]")?;
  
  poll(handle, detect_anomaly, (baseline, 1.5))?;
  
  Ok(())
}

fn detect_anomaly(event: Event, baseline: Event, threshold: f64) -> Result {
  // Compare against baseline in real-time
  if event.value > baseline.value * threshold {
    for producer in events.producers {
      // Write back to producers
      writeback_ws(producer, "OVERHEATING")?;
    }
  }
  
  Ok(())
}
```

## License

Unlike the root project, this SDK is licensed under the MIT License - see the [LICENSE](../LICENSE) file for details.
