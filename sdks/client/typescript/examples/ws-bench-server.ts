import { WebSocketServer } from "ws";
import { decodeEventBinary } from "../src/wire.ts";

type Args = {
  port: number;
  threshold: number;
  queueMode: boolean;
  progressMs: number;
};

function parseArgs(argv: string[]): Args {
  const out: Args = {
    port: Number(process.env.SLUNG_WS_PORT ?? 2077),
    threshold: 100_000,
    queueMode: false,
    progressMs: 1000,
  };

  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if ((arg === "--help") || (arg === "-h")) {
      console.log("Usage: pnpm run example:ws-server -- [--port 2077] [--threshold 100000] [--queue] [--progress-ms 1000]");
      process.exit(0);
    } else if (arg === "--port" && argv[i + 1]) {
      out.port = Number(argv[++i]);
    } else if (arg === "--threshold" && argv[i + 1]) {
      out.threshold = Number(argv[++i]);
    } else if (arg === "--queue") {
      out.queueMode = true;
    } else if (arg === "--progress-ms" && argv[i + 1]) {
      out.progressMs = Number(argv[++i]);
    }
  }

  if (!Number.isFinite(out.port) || out.port <= 0) throw new Error("Invalid --port");
  if (!Number.isFinite(out.threshold) || out.threshold <= 0) throw new Error("Invalid --threshold");
  if (!Number.isFinite(out.progressMs) || out.progressMs <= 0) throw new Error("Invalid --progress-ms");
  return out;
}

async function main(): Promise<void> {
  const args = parseArgs(process.argv.slice(2));
  const wss = new WebSocketServer({ port: args.port });

  let received = 0;
  let bytes = 0;
  let startedAtNs = 0n;
  let finished = false;

  const queue: Buffer[] = [];
  let pumping = false;

  const ingest = (buf: Buffer): void => {
    if (finished) return;
    if (startedAtNs === 0n) startedAtNs = process.hrtime.bigint();
    bytes += buf.length;

    if (!decodeEventBinary(buf)) return;

    received += 1;
    if (received >= args.threshold) {
      finished = true;
      const elapsedSec = Number(process.hrtime.bigint() - startedAtNs) / 1e9;
      const rate = received / elapsedSec;
      const mbps = (bytes / (1024 * 1024)) / elapsedSec;
      console.log(`received=${received}`);
      console.log(`elapsed_sec=${elapsedSec.toFixed(3)}`);
      console.log(`throughput_msg_per_sec=${rate.toFixed(2)}`);
      console.log(`throughput_mb_per_sec=${mbps.toFixed(2)}`);
      wss.close(() => process.exit(0));
    }
  };

  const pumpQueue = (): void => {
    if (pumping || !args.queueMode || finished) return;
    pumping = true;
    setImmediate(() => {
      while (queue.length > 0 && !finished) {
        const next = queue.shift();
        if (!next) break;
        ingest(next);
      }
      pumping = false;
      if (queue.length > 0 && !finished) pumpQueue();
    });
  };

  const progressTimer = setInterval(() => {
    if (startedAtNs === 0n) return;
    const elapsedSec = Number(process.hrtime.bigint() - startedAtNs) / 1e9;
    const rate = elapsedSec > 0 ? received / elapsedSec : 0;
    const mbps = elapsedSec > 0 ? (bytes / (1024 * 1024)) / elapsedSec : 0;
    console.log(`progress received=${received} rate=${rate.toFixed(2)}/s mbps=${mbps.toFixed(2)} queue=${queue.length}`);
  }, args.progressMs);

  wss.on("connection", (socket) => {
    socket.on("message", (data) => {
      const buf = Buffer.isBuffer(data) ? data : Buffer.from(data as ArrayBuffer);
      if (args.queueMode) {
        queue.push(buf);
        pumpQueue();
      } else {
        ingest(buf);
      }
    });
  });

  wss.on("close", () => clearInterval(progressTimer));
  console.log(`ws bench server listening on ws://127.0.0.1:${args.port}`);
  console.log(`threshold=${args.threshold} queue_mode=${args.queueMode}`);
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
