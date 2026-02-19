import WebSocket from "ws";
import { encodeEventBinary, nowUnixMicros } from "./wire.js";
export class SlungClient {
    url;
    ws = null;
    constructor(url = "ws://127.0.0.1:2077") {
        this.url = url;
    }
    async connect() {
        if (this.ws && this.ws.readyState === WebSocket.OPEN)
            return;
        await new Promise((resolve, reject) => {
            const ws = new WebSocket(this.url);
            ws.once("open", () => {
                this.ws = ws;
                resolve();
            });
            ws.once("error", (err) => {
                reject(err);
            });
        });
    }
    sendEvent(event) {
        if (!this.ws || this.ws.readyState !== WebSocket.OPEN) {
            throw new Error("WebSocket is not connected. Call connect() first.");
        }
        this.ws.send(encodeEventBinary(event));
    }
    startSimulatedStream(options = {}) {
        const intervalMs = options.intervalMs ?? 500;
        const jitter = options.jitter ?? 0.5;
        const series = options.series ?? "temp";
        const tags = options.tags ?? ["sensor=1", "env=dev"];
        let value = options.initialValue ?? 20;
        const timer = setInterval(() => {
            value += (Math.random() - 0.5) * jitter;
            this.sendEvent({
                value: Number(value.toFixed(3)),
                timestamp: nowUnixMicros(),
                series,
                tags,
            });
        }, intervalMs);
        return () => clearInterval(timer);
    }
    close(code, reason) {
        if (!this.ws)
            return;
        this.ws.close(code, reason);
        this.ws = null;
    }
}
export { createEventBinaryEncoder, decodeEventBinary, encodeEventBinary, nowUnixMicros, } from "./wire.js";
