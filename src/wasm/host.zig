//! Host runtime support — exposes Slung's host ABI through zwasm 2.

const zwasm = @import("zwasm");

const generic = @import("host_abi/generic.zig");

/// Register all Slung imports in the v2 linker. The context pointer is kept by
/// the linker and surfaced to callbacks through `Caller.data`.
pub fn defineHostFunctions(linker: *zwasm.Linker, context: *anyopaque) !void {
    try generic.defineHostFunctions(linker, context);

    // These APIs are intentionally no-op stubs until their connector managers
    // are wired to the v2 Caller API. Keeping their signatures explicit means
    // connector-enabled guest modules still link with the same ABI.
    const noop = struct {
        fn one(_: *zwasm.Caller, _: u32) i32 {
            return -1;
        }
        fn two(_: *zwasm.Caller, _: u32, _: u32) i32 {
            return -1;
        }
        fn three(_: *zwasm.Caller, _: u32, _: u32, _: u32) i32 {
            return -1;
        }
        fn four(_: *zwasm.Caller, _: u32, _: u32, _: u32, _: u32) i32 {
            return -1;
        }
        fn six(_: *zwasm.Caller, _: u32, _: u32, _: u32, _: u32, _: u32, _: u32) i32 {
            return -1;
        }
    };

    inline for (.{
        "slung_tcp_connect",    "slung_udp_bind",      "slung_nats_connect",
        "slung_nats_subscribe", "slung_kafka_connect", "slung_kafka_subscribe",
        "slung_ws_connect",
    }) |name| try linker.defineFuncCtx("env", name, context, fn (*zwasm.Caller, u32) i32, noop.one);
    inline for (.{
        "slung_tcp_close", "slung_udp_recv", "slung_nats_next", "slung_kafka_next",
        "slung_ws_next",   "slung_ws_close",
    }) |name| try linker.defineFuncCtx("env", name, context, fn (*zwasm.Caller, u32, u32) i32, noop.two);
    inline for (.{
        "slung_tcp_read",      "slung_tcp_write", "slung_udp_send", "slung_nats_publish",
        "slung_kafka_produce", "slung_ws_send",
    }) |name| try linker.defineFuncCtx("env", name, context, fn (*zwasm.Caller, u32, u32, u32) i32, noop.three);
    inline for (.{ "slung_http_get", "slung_http_delete" }) |name| try linker.defineFuncCtx("env", name, context, fn (*zwasm.Caller, u32, u32, u32, u32) i32, noop.four);
    inline for (.{ "slung_http_post", "slung_http_put" }) |name| try linker.defineFuncCtx("env", name, context, fn (*zwasm.Caller, u32, u32, u32, u32, u32, u32) i32, noop.six);
}
