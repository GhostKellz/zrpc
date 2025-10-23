//! Async streaming support for zrpc using zsync channels
//! Provides channel-based streaming for client, server, and bidirectional streaming

const std = @import("std");
const zsync = @import("zsync");

/// Client streaming call - send multiple requests, receive single response
pub fn ClientStreamingCall(comptime Request: type, comptime Response: type) type {
    return struct {
        channel: zsync.Channel(Request),
        response_handle: zsync.TaskHandle,
        allocator: std.mem.Allocator,

        const Self = @This();

        pub fn init(allocator: std.mem.Allocator, handler_fn: *const fn (zsync.Channel(Request)) anyerror!Response) !Self {
            var channel = try zsync.boundedChannel(Request, allocator, 100);

            // Spawn task to process stream and produce response
            const ProcessorTask = struct {
                fn process(io: zsync.Io) !Response {
                    _ = io;
                    return try handler_fn(channel);
                }
            };

            const handle = try zsync.spawnTask(ProcessorTask.process, .{});

            return Self{
                .channel = channel,
                .response_handle = handle,
                .allocator = allocator,
            };
        }

        pub fn send(self: *Self, request: Request) !void {
            try self.channel.send(request);
        }

        pub fn finish(self: *Self) !Response {
            self.channel.close();
            return try self.response_handle.await();
        }

        pub fn deinit(self: *Self) void {
            self.channel.deinit();
            self.response_handle.deinit();
        }
    };
}

/// Server streaming call - send single request, receive multiple responses
pub fn ServerStreamingCall(comptime Request: type, comptime Response: type) type {
    return struct {
        channel: zsync.Channel(Response),
        producer_handle: zsync.TaskHandle,
        allocator: std.mem.Allocator,

        const Self = @This();

        pub fn init(allocator: std.mem.Allocator, request: Request, handler_fn: *const fn (Request, zsync.Channel(Response)) anyerror!void) !Self {
            var channel = try zsync.boundedChannel(Response, allocator, 100);

            // Spawn task to produce responses
            const ProducerTask = struct {
                fn produce(io: zsync.Io) !void {
                    _ = io;
                    try handler_fn(request, channel);
                    channel.close();
                }
            };

            const handle = try zsync.spawnTask(ProducerTask.produce, .{});

            return Self{
                .channel = channel,
                .producer_handle = handle,
                .allocator = allocator,
            };
        }

        pub fn recv(self: *Self) !?Response {
            return self.channel.tryRecv();
        }

        pub fn deinit(self: *Self) void {
            try self.producer_handle.await();
            self.producer_handle.deinit();
            self.channel.deinit();
        }
    };
}

/// Bidirectional streaming call - send and receive multiple messages
pub fn BidirectionalStreamingCall(comptime Request: type, comptime Response: type) type {
    return struct {
        request_channel: zsync.Channel(Request),
        response_channel: zsync.Channel(Response),
        processor_handle: zsync.TaskHandle,
        allocator: std.mem.Allocator,

        const Self = @This();

        pub fn init(allocator: std.mem.Allocator, handler_fn: *const fn (zsync.Channel(Request), zsync.Channel(Response)) anyerror!void) !Self {
            var request_channel = try zsync.boundedChannel(Request, allocator, 100);
            var response_channel = try zsync.boundedChannel(Response, allocator, 100);

            // Spawn task to process bidirectional stream
            const ProcessorTask = struct {
                fn process(io: zsync.Io) !void {
                    _ = io;
                    try handler_fn(request_channel, response_channel);
                    response_channel.close();
                }
            };

            const handle = try zsync.spawnTask(ProcessorTask.process, .{});

            return Self{
                .request_channel = request_channel,
                .response_channel = response_channel,
                .processor_handle = handle,
                .allocator = allocator,
            };
        }

        pub fn send(self: *Self, request: Request) !void {
            try self.request_channel.send(request);
        }

        pub fn recv(self: *Self) !?Response {
            return self.response_channel.tryRecv();
        }

        pub fn closeSend(self: *Self) void {
            self.request_channel.close();
        }

        pub fn deinit(self: *Self) void {
            try self.processor_handle.await();
            self.processor_handle.deinit();
            self.request_channel.deinit();
            self.response_channel.deinit();
        }
    };
}

// Example usage tests
test "client streaming" {
    const Request = struct {
        value: i32,
    };

    const Response = struct {
        sum: i32,
    };

    const handler = struct {
        fn handle(channel: zsync.Channel(Request)) !Response {
            var sum: i32 = 0;
            while (channel.recv()) |req| {
                sum += req.value;
            }
            return Response{ .sum = sum };
        }
    }.handle;

    var call = try ClientStreamingCall(Request, Response).init(std.testing.allocator, handler);
    defer call.deinit();

    try call.send(.{ .value = 10 });
    try call.send(.{ .value = 20 });
    try call.send(.{ .value = 30 });

    const response = try call.finish();
    try std.testing.expectEqual(@as(i32, 60), response.sum);
}

test "server streaming" {
    const Request = struct {
        count: usize,
    };

    const Response = struct {
        value: usize,
    };

    const handler = struct {
        fn handle(request: Request, channel: zsync.Channel(Response)) !void {
            for (0..request.count) |i| {
                try channel.send(.{ .value = i });
            }
        }
    }.handle;

    var call = try ServerStreamingCall(Request, Response).init(
        std.testing.allocator,
        .{ .count = 5 },
        handler,
    );
    defer call.deinit();

    var received: usize = 0;
    while (try call.recv()) |response| {
        try std.testing.expectEqual(received, response.value);
        received += 1;
    }

    try std.testing.expectEqual(@as(usize, 5), received);
}

test "bidirectional streaming" {
    const Request = struct {
        value: i32,
    };

    const Response = struct {
        doubled: i32,
    };

    const handler = struct {
        fn handle(req_channel: zsync.Channel(Request), resp_channel: zsync.Channel(Response)) !void {
            while (req_channel.recv()) |req| {
                try resp_channel.send(.{ .doubled = req.value * 2 });
            }
        }
    }.handle;

    var call = try BidirectionalStreamingCall(Request, Response).init(std.testing.allocator, handler);
    defer call.deinit();

    try call.send(.{ .value = 5 });
    try call.send(.{ .value = 10 });
    call.closeSend();

    const resp1 = (try call.recv()).?;
    try std.testing.expectEqual(@as(i32, 10), resp1.doubled);

    const resp2 = (try call.recv()).?;
    try std.testing.expectEqual(@as(i32, 20), resp2.doubled);
}
