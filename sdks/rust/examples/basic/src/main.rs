use slung::prelude::*;
use std::io::Result;

fn main() -> Result<()> {
    // Query live data stream
    let handle = query_live("AVG:temp:[sensor=1]")?;

    // Query last hour's baseline
    let baseline = query_history("AVG:temp:[sensor=1]:[1h,now]")?.expect("Failed to query history");

    poll_handle(handle, detect_anomaly, (baseline, 1.5))?;

    Ok(())
}

fn detect_anomaly(event: Event, args: (Event, f64)) -> Result<()> {
    let (baseline, threshold) = args;

    // Compare against baseline in real-time
    if event.value > baseline.value * threshold {
        for producer in event.producers {
            // Write back to producers
            writeback_ws(&producer, "OVERHEATING")?;
        }
    }

    Ok(())
}
