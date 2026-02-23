import { SlungClient } from "../src/index.ts";

async function main(): Promise<void> {
  const client = new SlungClient(
    process.env.SLUNG_WS_URL ?? "ws://127.0.0.1:2077",
  );
  await client.connect();

  console.log("connected to slung websocket");
  console.log("sending simulated events every 10ms");

  const stop = client.startSimulatedStream({
    intervalMs: 10,
    initialValue: 90,
    jitter: 1.2,
    series: "temp",
    tags: ["sensor=1", "env=dev", "service=api"],
  });

  const shutdown = () => {
    stop();
    client.close(1000, "shutdown");
    process.exit(0);
  };

  process.on("SIGINT", shutdown);
  process.on("SIGTERM", shutdown);
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
