#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../../../.." && pwd)
EXAMPLE_DIR="$ROOT/sdks/rust/examples/webhook"
MODULE="$EXAMPLE_DIR/target/wasm32-wasip1/release/webhook.wasm"

slung_pid=""
cleanup() {
    if [ -n "$slung_pid" ]; then kill "$slung_pid" 2>/dev/null || true; fi
    pkill -TERM -f '[s]lung.*dev' 2>/dev/null || true
}
trap cleanup EXIT INT TERM

echo "Building webhook example..."
(
    cd "$EXAMPLE_DIR"
    cargo build --target wasm32-wasip1 --release
)

echo "Starting Slung..."
(
    cd "$ROOT"
    zig build run -- dev \
        --module "$MODULE" \
        --namespace webhook_test \
        --node-id node-1 \
        --ws-port 2077 \
        --http-port 2078
) >"$EXAMPLE_DIR/slung.log" 2>&1 &
slung_pid=$!

ENDPOINT="http://127.0.0.1:2078/webhook_test/api/inventory"
for _ in $(seq 1 50); do
    if curl -sS -o /dev/null -X POST "$ENDPOINT" \
        -H 'Content-Type: application/json' \
        -d '{"sku":"READINESS","quantity":150}' 2>/dev/null; then
        break
    fi
    sleep 0.1
done

echo "Sending inventory and order events..."
curl -fsS -X POST "$ENDPOINT" \
    -H 'Content-Type: application/json' \
    -d '{"sku":"GADGET-002","quantity":30}' >/dev/null
curl -fsS -X POST "$ENDPOINT" \
    -H 'Content-Type: application/json' \
    -d '{"sku":"CRITICAL-003","quantity":10}' >/dev/null
curl -fsS -X POST "$ENDPOINT" \
    -H 'Content-Type: application/json' \
    -d '{"order_id":"ORD-2024-001","sku":"GADGET-002","quantity":5}' >/dev/null

for _ in $(seq 1 50); do
    if grep -q 'LOW STOCK ALERT: GADGET-002 now at 30 units' "$EXAMPLE_DIR/slung.log" \
        && grep -q 'EMERGENCY: CRITICAL-003 is critically low at 10 units' "$EXAMPLE_DIR/slung.log" \
        && grep -q 'Order ORD-2024-001: 5 units of GADGET-002 reserved' "$EXAMPLE_DIR/slung.log"; then
        echo "Webhook example passed."
        exit 0
    fi
    sleep 0.1
done

cat "$EXAMPLE_DIR/slung.log"
exit 1
