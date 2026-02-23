import WebSocket from "ws";
import { createEventBinaryEncoder } from "../src/wire.ts";

type Args = {
  url: string;
  count: number;
  durationSec: number;
  series: string;
  tags: string[];
  batch: number;
  maxBufferedBytes: number;
  lingerMs: number;
  progressMs: number;
};

function parseArgs(argv: string[]): Args {
  const out: Args = {
    url: process.env.SLUNG_WS_URL ?? "ws://127.0.0.1:2077",
    count: 100_000,
    durationSec: 0,
    series: "temp",
    tags: ["sensor=1", "env=bench"],
    batch: 1000,
    maxBufferedBytes: 4 * 1024 * 1024,
    lingerMs: 2000,
    progressMs: 1000,
  };

  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === "--url" && argv[i + 1]) out.url = argv[++i];
    else if (arg === "--count" && argv[i + 1]) out.count = Number(argv[++i]);
    else if (arg === "--duration" && argv[i + 1]) out.durationSec = Number(argv[++i]);
    else if (arg === "--series" && argv[i + 1]) out.series = argv[++i];
    else if (arg === "--tags" && argv[i + 1]) {
      out.tags = argv[++i]
        .split(",")
        .map((x) => x.trim())
        .filter(Boolean);
    } else if (arg === "--batch" && argv[i + 1]) out.batch = Number(argv[++i]);
    else if (arg === "--max-buffered" && argv[i + 1]) {
      out.maxBufferedBytes = Number(argv[++i]);
    } else if (arg === "--linger-ms" && argv[i + 1]) {
      out.lingerMs = Number(argv[++i]);
    } else if (arg === "--progress-ms" && argv[i + 1]) {
      out.progressMs = Number(argv[++i]);
    }
  }

  if (!Number.isFinite(out.count) || out.count <= 0) throw new Error("Invalid --count");
  if (!Number.isFinite(out.durationSec) || out.durationSec < 0) throw new Error("Invalid --duration");
  if (!Number.isFinite(out.batch) || out.batch <= 0) throw new Error("Invalid --batch");
  if (!Number.isFinite(out.maxBufferedBytes) || out.maxBufferedBytes <= 0) {
    throw new Error("Invalid --max-buffered");
  }
  if (!Number.isFinite(out.lingerMs) || out.lingerMs < 0) throw new Error("Invalid --linger-ms");
  if (!Number.isFinite(out.progressMs) || out.progressMs <= 0) throw new Error("Invalid --progress-ms");

  if (out.durationSec > 0) {
    out.count = Number.MAX_SAFE_INTEGER;
  }
  return out;
}

function waitForOpen(ws: WebSocket): Promise<void> {
  return new Promise((resolve, reject) => {
    ws.once("open", () => resolve());
    ws.once("error", (err) => reject(err));
  });
}

function waitForDrain(ws: WebSocket, maxBufferedBytes: number): Promise<void> | null {
  if (ws.bufferedAmount <= maxBufferedBytes) return null;
  return new Promise((resolve) => {
    const poll = () => {
      if (ws.readyState !== WebSocket.OPEN) return resolve();
      if (ws.bufferedAmount <= maxBufferedBytes) return resolve();
      setTimeout(poll, 1);
    };
    poll();
  });
}

async function main(): Promise<void> {
  const args = parseArgs(process.argv.slice(2));
  const ws = new WebSocket(args.url);
  await waitForOpen(ws);

  let sent = 0;
  let value = 100;
  let peakBuffered = 0;
  const encode = createEventBinaryEncoder(args.series, args.tags);
  const started = process.hrtime.bigint();
  const runUntilNs =
    args.durationSec > 0
      ? Number(started) + Math.floor(args.durationSec * 1e9)
      : Number.MAX_SAFE_INTEGER;

  const progress = setInterval(() => {
    const elapsedSec = Number(process.hrtime.bigint() - started) / 1e9;
    const rate = elapsedSec > 0 ? sent / elapsedSec : 0;
    peakBuffered = Math.max(peakBuffered, ws.bufferedAmount);
    console.log(
      `progress sent=${sent} buffered=${ws.bufferedAmount} peak_buffered=${peakBuffered} rate=${rate.toFixed(2)}/s`,
    );
  }, args.progressMs);

  while (sent < args.count && Number(process.hrtime.bigint()) < runUntilNs) {
    const limit = Math.min(args.count, sent + args.batch);
    while (sent < limit) {
      if (Number(process.hrtime.bigint()) >= runUntilNs) break;
      value += (Math.random() - 0.5) * 0.4;
      ws.send(encode(Date.now(), Number(value.toFixed(4))));
      sent += 1;
    }

    const drain = waitForDrain(ws, args.maxBufferedBytes);
    if (drain) await drain;
  }

  while (ws.bufferedAmount > 0 && ws.readyState === WebSocket.OPEN) {
    await new Promise((r) => setTimeout(r, 1));
  }

  if (args.lingerMs > 0) {
    await new Promise((r) => setTimeout(r, args.lingerMs));
  }

  clearInterval(progress);

  const elapsedNs = Number(process.hrtime.bigint() - started);
  const elapsedSec = elapsedNs / 1e9;
  const rate = sent / elapsedSec;

  console.log(`sent=${sent}`);
  console.log(`elapsed_sec=${elapsedSec.toFixed(3)}`);
  console.log(`throughput_msg_per_sec=${rate.toFixed(2)}`);
  console.log(`peak_buffered_bytes=${peakBuffered}`);
  console.log(`linger_ms=${args.lingerMs}`);

  ws.close(1000, "benchmark done");
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
