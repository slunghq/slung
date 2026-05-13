const std = @import("std");

const zwasm = @import("zwasm");

pub const Context = struct {
    allocator: std.mem.Allocator,
    // TODO: inject broker_manager reference
};

pub fn slung_nats_connect(ctx_ptr: *anyopaque, context: usize) anyerror!void {
    _ = context;
    const vm: *zwasm.Vm = @ptrCast(@alignCast(ctx_ptr));
    _ = vm;
    // TODO: pop url_ptr, url_len from operand stack, connect to NATS, push handle or 0
}

pub fn slung_nats_subscribe(ctx_ptr: *anyopaque, context: usize) anyerror!void {
    _ = context;
    const vm: *zwasm.Vm = @ptrCast(@alignCast(ctx_ptr));
    _ = vm;
    // TODO: pop handle, subject_ptr, subject_len from operand stack, subscribe to NATS subject, push subscription_handle or 0
}

pub fn slung_nats_next(ctx_ptr: *anyopaque, context: usize) anyerror!void {
    _ = context;
    const vm: *zwasm.Vm = @ptrCast(@alignCast(ctx_ptr));
    _ = vm;
    // TODO: pop subscription_handle from operand stack, wait for next NATS message, allocate NatsMessage struct, push ptr
}

pub fn slung_nats_publish(ctx_ptr: *anyopaque, context: usize) anyerror!void {
    _ = context;
    const vm: *zwasm.Vm = @ptrCast(@alignCast(ctx_ptr));
    _ = vm;
    // TODO: pop handle, subject_ptr, subject_len, msg_ptr, msg_len from operand stack, publish to NATS, push 0 on success
}

pub fn slung_kafka_connect(ctx_ptr: *anyopaque, context: usize) anyerror!void {
    _ = context;
    const vm: *zwasm.Vm = @ptrCast(@alignCast(ctx_ptr));
    _ = vm;
    // TODO: pop brokers_ptr, brokers_len from operand stack, connect to Kafka, push handle or 0
}

pub fn slung_kafka_subscribe(ctx_ptr: *anyopaque, context: usize) anyerror!void {
    _ = context;
    const vm: *zwasm.Vm = @ptrCast(@alignCast(ctx_ptr));
    _ = vm;
    // TODO: pop handle, topic_ptr, topic_len from operand stack, subscribe to Kafka topic, push subscription_handle or 0
}

pub fn slung_kafka_next(ctx_ptr: *anyopaque, context: usize) anyerror!void {
    _ = context;
    const vm: *zwasm.Vm = @ptrCast(@alignCast(ctx_ptr));
    _ = vm;
    // TODO: pop subscription_handle from operand stack, wait for next Kafka message, allocate KafkaMessage struct, push ptr
}

pub fn slung_kafka_produce(ctx_ptr: *anyopaque, context: usize) anyerror!void {
    _ = context;
    const vm: *zwasm.Vm = @ptrCast(@alignCast(ctx_ptr));
    _ = vm;
    // TODO: pop handle, topic_ptr, topic_len, msg_ptr, msg_len from operand stack, produce to Kafka, push 0 on success
}

pub fn appendHostFunctions(host_fns: *std.ArrayList(zwasm.HostFnEntry), allocator: std.mem.Allocator, context: usize) !void {
    try host_fns.append(allocator, .{
        .name = "slung_nats_connect",
        .callback = slung_nats_connect,
        .context = context,
    });

    try host_fns.append(allocator, .{
        .name = "slung_nats_subscribe",
        .callback = slung_nats_subscribe,
        .context = context,
    });

    try host_fns.append(allocator, .{
        .name = "slung_nats_next",
        .callback = slung_nats_next,
        .context = context,
    });

    try host_fns.append(allocator, .{
        .name = "slung_nats_publish",
        .callback = slung_nats_publish,
        .context = context,
    });

    try host_fns.append(allocator, .{
        .name = "slung_kafka_connect",
        .callback = slung_kafka_connect,
        .context = context,
    });

    try host_fns.append(allocator, .{
        .name = "slung_kafka_subscribe",
        .callback = slung_kafka_subscribe,
        .context = context,
    });

    try host_fns.append(allocator, .{
        .name = "slung_kafka_next",
        .callback = slung_kafka_next,
        .context = context,
    });

    try host_fns.append(allocator, .{
        .name = "slung_kafka_produce",
        .callback = slung_kafka_produce,
        .context = context,
    });
}
