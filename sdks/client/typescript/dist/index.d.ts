export type SlungEvent = {
    value: number;
    timestamp: number;
    series: string;
    tags: string[];
};
export type SimulatedStreamOptions = {
    intervalMs?: number;
    initialValue?: number;
    jitter?: number;
    series?: string;
    tags?: string[];
};
export declare class SlungClient {
    private readonly url;
    private ws;
    constructor(url?: string);
    connect(): Promise<void>;
    sendEvent(event: SlungEvent): void;
    startSimulatedStream(options?: SimulatedStreamOptions): () => void;
    close(code?: number, reason?: string): void;
}
export { createEventBinaryEncoder, decodeEventBinary, encodeEventBinary } from "./wire.js";
