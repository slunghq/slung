#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../../../../.." && pwd)
EXAMPLE_DIR="$ROOT/sdks/pipeline/rust/examples/http"
MODULE="$EXAMPLE_DIR/target/wasm32-wasip1/release/http.wasm"

server_pid=""
slung_pid=""
cleanup() {
    if [ -n "$slung_pid" ]; then kill "$slung_pid" 2>/dev/null || true; fi
    if [ -n "$server_pid" ]; then kill "$server_pid" 2>/dev/null || true; fi
}
trap cleanup EXIT INT TERM

echo "Building HTTP pipeline example..."
(
    cd "$EXAMPLE_DIR"
    cargo build --target wasm32-wasip1 --release
)

echo "Starting HTTP test server..."
(
    cd "$EXAMPLE_DIR"
    cargo run --bin test_server
) >"$EXAMPLE_DIR/test-server.log" 2>&1 &
server_pid=$!

for _ in $(seq 1 50); do
    if curl -fsS http://127.0.0.1:2080/health >/dev/null 2>&1; then
        break
    fi
    sleep 0.1
done

echo "Starting Slung..."
(
    cd "$ROOT"
    zig build run -- dev \
        --module "$MODULE" \
        --namespace http_test \
        --node-id node-1 \
        --ws-port 2073 \
        --http-port 2074
) >"$EXAMPLE_DIR/slung.log" 2>&1 &
slung_pid=$!

for _ in $(seq 1 50); do
    if curl -fsS http://127.0.0.1:2074/http_test/api/trigger >/dev/null 2>&1; then
        break
    fi
    sleep 0.1
done

echo "Triggering outbound HTTP requests..."
curl -fsS -X POST http://127.0.0.1:2074/http_test/api/trigger \
    -H 'Content-Type: application/json' \
    -d '{"request_id":"http-example"}'
echo

echo "Verifying received requests..."
for _ in $(seq 1 50); do
    if curl -fsS http://127.0.0.1:2080/verify >/dev/null 2>&1; then
        curl -fsS http://127.0.0.1:2080/verify
        echo
        exit 0
    fi
    sleep 0.1
done

curl -fsS http://127.0.0.1:2080/verify
echo
