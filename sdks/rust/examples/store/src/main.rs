use slung::host::store;
use slung::prelude::*;
use slung_macros::{component, rule, source};

#[source(builtin = "http")]
struct StoreEvent {
    #[config(value = "/api/store")]
    endpoint: &'static str,

    #[component(map = parse_store_event)]
    event: Event,
}

#[component]
struct Event {
    key: String,
    value: String,
    delete: bool,
}

fn parse_store_event(raw: &[u8]) -> Result<Event> {
    Ok(serde_json::from_slice(raw)?)
}

#[rule(watch = [StoreEvent::event], priority = 10)]
fn persist_event(ctx: &RuleContext) -> Result<()> {
    let event = ctx.get::<Event>(StoreEvent::event)?;
    let key = event.key.as_bytes();

    if event.delete {
        let deleted = store::delete(key)?;
        eprintln!("STORE DELETE key={} deleted={}", event.key, deleted);
    } else {
        store::set(key, event.value.as_bytes())?;
        let stored = store::get(key)?.ok_or_else(|| {
            std::io::Error::other("store value was missing immediately after set")
        })?;
        if stored != event.value.as_bytes() {
            return Err(std::io::Error::other("store value did not round-trip"));
        }
        eprintln!("STORE SET key={} value={}", event.key, event.value);
    }

    Ok(())
}

fn main() {}
