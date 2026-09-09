#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../../../.." && pwd)
EXAMPLE_DIR="$ROOT/sdks/go/examples/http"
FIXTURE_DIR="$ROOT/sdks/rust/examples/http"
MODULE="$EXAMPLE_DIR/target/http.wasm"

server_pid=""
slung_pid=""
cleanup() {
    if [ -n "$slung_pid" ]; then kill "$slung_pid" 2>/dev/null || true; fi
    if [ -n "$server_pid" ]; then kill "$server_pid" 2>/dev/null || true; fi
    # Clean stale processes from this example only; do not kill other Slung runs.
    pkill -TERM -f '[s]lung.*go_http_test' 2>/dev/null || true
    pkill -TERM -f '/examples/http/target/debug/test_server' 2>/dev/null || true
    pkill -TERM -f '[c]argo run --bin test_server.*examples/http' 2>/dev/null || true
}
trap cleanup EXIT INT TERM

echo "Building Go HTTP example..."
(
    cd "$EXAMPLE_DIR"
    mkdir -p target
    compiler="${GO_COMPILER:-tinygo}"
    if [ "$compiler" = "tinygo" ]; then
        tinygo build -target wasip1 -opt=z -o "$MODULE" .
    else
        echo "unsupported Go compiler: $compiler (use GO_COMPILER=tinygo)" >&2
        exit 1
    fi
)

echo "Starting HTTP test server..."
(
    cd "$FIXTURE_DIR"
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
        --namespace go_http_test \
        --node-id node-1 \
        --ws-port 2079 \
        --http-port 2081
) >"$EXAMPLE_DIR/slung.log" 2>&1 &
slung_pid=$!

ready=0
for _ in $(seq 1 300); do
    if grep -q 'Registered route: POST /go_http_test/api/trigger' "$EXAMPLE_DIR/slung.log" \
        && curl -sS -o /dev/null http://127.0.0.1:2081/go_http_test/api/trigger 2>/dev/null; then
        ready=1
        break
    fi
    sleep 0.1
done
if [ "$ready" -ne 1 ]; then
    cat "$EXAMPLE_DIR/slung.log"
    exit 1
fi

echo "Triggering Go HTTP rule..."
curl -fsS -X POST http://127.0.0.1:2081/go_http_test/api/trigger \
    -H 'Content-Type: application/json' \
    -d '{"request_id":"http-example"}'
echo

echo "Verifying outbound requests..."
for _ in $(seq 1 50); do
    if curl -fsS http://127.0.0.1:2080/verify >/dev/null 2>&1; then
        curl -fsS http://127.0.0.1:2080/verify
        echo
        exit 0
    fi
    sleep 0.1
done

cat "$EXAMPLE_DIR/slung.log"
cat "$EXAMPLE_DIR/test-server.log"
exit 1
