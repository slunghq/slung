export type WireEvent = {
    timestamp: number;
    value: number;
    series: string;
    tags: string[];
};
export declare function createEventBinaryEncoder(series: string, tags: string[]): (timestamp: number, value: number) => Buffer;
export declare function encodeEventBinary(event: WireEvent): Buffer;
export declare function decodeEventBinary(buf: Buffer): WireEvent | null;
