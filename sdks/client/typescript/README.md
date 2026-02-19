# Slung TS Client SDK

Minimal TypeScript client SDK for sending telemetry to Slung over WebSocket.

## Message shape

The server expects binary websocket frames (little-endian):

```text
[timestamp:i64][value:f64][series_len:u16][tag_count:u16][series_utf8][tag_len:u16+tag_utf8]...
```

`timestamp` is expected to be Unix epoch microseconds.

## Install deps

```bash
cd sdks/client
pnpm install
```

## Run simulated sender example

```bash
pnpm run example:simulated
```

Override server URL:

```bash
SLUNG_WS_URL=ws://127.0.0.1:2077 pnpm run example:simulated
```

## Run ingestion benchmark

```bash
pnpm run example:benchmark -- --count 1000000 --batch 2000 --series temp --tags sensor=1,env=bench
```

## Run local TS websocket ingest server benchmark

Start a simple Node/TS websocket server that only parses/counts the same message shape and exits at threshold:

```bash
pnpm run example:ws-server -- --port 2077 --threshold 100000
```

Optional queue mode (simulates channel-style decoupling):

```bash
pnpm run example:ws-server -- --port 2077 --threshold 100000 --queue
```

Then run the existing benchmark client against it:

```bash
pnpm run example:benchmark -- --url ws://127.0.0.1:2077 --count 100000 --batch 2000
```

Duration mode (preferred for stable throughput):

```bash
pnpm run example:benchmark -- --duration 30 --batch 2000 --series temp --tags sensor=1,env=bench --linger-ms 3000
```

Optional flags:

```text
--url ws://127.0.0.1:2077
--count 1000000
--duration 30
--batch 2000
--series temp
--tags sensor=1,env=bench,service=api
--max-buffered 4194304
--linger-ms 3000
--progress-ms 1000
--queue
```

## License

Unlike the root project, this SDK is licensed under the MIT License - see the [LICENSE](../LICENSE) file for details.
