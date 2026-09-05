# Store example

This example demonstrates module-owned persistent storage through the `slung_store_*` ABI.

The rule accepts an event containing a key, value, and delete flag:

+ `delete = false` calls `store::set`, then reads the value back with `store::get`.
+ `delete = true` calls `store::delete`.

Storage is scoped by the runtime namespace and module name. Values are opaque bytes and are persisted by the host's SQLite module store; fact and pending-work durability remains in the separate WAL.

## Build

From this directory:

```bash
rustup target add wasm32-wasip1
cargo build --target wasm32-wasip1 --release
```

The module is written to:

```text
target/wasm32-wasip1/release/store.wasm
```
