# Slung Rust SDK

Runtime bindings for [Slung](https://github.com/slunghq/slung) — an ontology-driven compute engine that executes rules based on real-time component updates.

## Overview

Slung rules watch components for changes and fire when facts become dirty. The Rust SDK provides:

- **Descriptor macros** (`#[source]`, `#[component]`, `#[rule]`) — self-describing rule modules
- **RuleContext** — typed access to entity state and host operations
- **Host ABI** — low-level access to active memory, clock, and connectors

## Quickstart

Add to `Cargo.toml`:

```toml
[dependencies]
slung = "0.1"
slung_macros = "0.1"
```

## Example: Sensor Alert Rule

```rust
use slung::prelude::*;

#[source(builtin = "ws")]
struct SensorData {
    #[config]
    path: &'static str,

    temperature: f64,
}

#[component]
struct Alert {
    active: bool,
}

#[rule(watch = [SensorData::temperature], priority = 10)]
fn on_high_temp(ctx: &RuleContext) -> Result<()> {
    let temp = ctx.get::<f64>(SensorData::temperature)?;
    ctx.set(Alert::active, temp > 85.0)?;
    Ok(())
}

// for the compiler to be happy
fn main() {}
```

The host:
1. Parses descriptors from Wasm exports
2. Builds the capability graph (what watches what)
3. Loads component values from the LWW store
4. Fires your rule when `SensorData::temperature` changes
5. Captures writes back to the store and re-triggers dependent rules

## Host ABI

The `host` module provides typed bindings organized by category:

- **generic** — `get()`, `set()`, `now()`, `yield_control()`, `emit()`, `notify()`
- **http** — `get()`, `post()`
- **ws** — `connect()`, `next()`, `send()`
- **tcp_udp** — raw socket escape hatch

Most rules only need `RuleContext::get()` and `RuleContext::set()`.

## How It Works

```text
Wasm module
  ├─ #[source] descriptors → host opens connectors, maps incoming data
  ├─ #[component] descriptors → host tracks typed facts
  └─ #[rule] descriptors → host builds watchlist and capability graph

At runtime:
  component changes → dirty signal → graph lookup → rule fire → write back
```

## License

MIT License — see [LICENSE](../LICENSE).
