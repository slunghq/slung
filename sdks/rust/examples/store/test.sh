#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../../../.." && pwd)
EXAMPLE_DIR="$ROOT/sdks/rust/examples/store"
MODULE="$EXAMPLE_DIR/target/wasm32-wasip1/release/store.wasm"

slung_pid=""
cleanup() {
    if [ -n "$slung_pid" ]; then kill "$slung_pid" 2>/dev/null || true; fi
    pkill -TERM -f '[s]lung.*dev' 2>/dev/null || true
}
trap cleanup EXIT INT TERM

echo "Building store example..."
(
    cd "$EXAMPLE_DIR"
    cargo build --target wasm32-wasip1 --release
)

echo "Starting Slung..."
(
    cd "$ROOT"
    zig build run -- dev \
        --module "$MODULE" \
        --namespace store_test \
        --node-id node-1 \
        --ws-port 2075 \
        --http-port 2076
) >"$EXAMPLE_DIR/slung.log" 2>&1 &
slung_pid=$!

for _ in $(seq 1 50); do
    if curl -sS -o /dev/null -X POST \
        http://127.0.0.1:2076/store_test/api/store \
        -H 'Content-Type: application/json' \
        -d '{"key":"readiness","value":"ok","delete":false}' 2>/dev/null; then
        break
    fi
    sleep 0.1
done

echo "Testing store::set and store::get..."
curl -fsS -X POST http://127.0.0.1:2076/store_test/api/store \
    -H 'Content-Type: application/json' \
    -d '{"key":"example-key","value":"example-value","delete":false}' >/dev/null

echo "Testing store::delete..."
curl -fsS -X POST http://127.0.0.1:2076/store_test/api/store \
    -H 'Content-Type: application/json' \
    -d '{"key":"example-key","value":"","delete":true}' >/dev/null

for _ in $(seq 1 50); do
    if grep -q 'STORE SET key=example-key value=example-value' "$EXAMPLE_DIR/slung.log" \
        && grep -q 'STORE DELETE key=example-key deleted=true' "$EXAMPLE_DIR/slung.log"; then
        echo "Store example passed."
        exit 0
    fi
    sleep 0.1
done

cat "$EXAMPLE_DIR/slung.log"
exit 1
