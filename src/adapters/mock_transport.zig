//! Mock transport for testing and demonstration
//! This shows how to implement the transport interface

const std = @import("std");
const zrpc_core = @import("zrpc-core");

const Transport = zrpc_core.transport.Transport;
const Connection = zrpc_core.transport.Connection;
const Stream = zrpc_core.transport.Stream;
const Frame = zrpc_core.transport.Frame;
const FrameType = zrpc_core.transport.FrameType;
const TransportError = zrpc_core.transport.TransportError;
const TlsConfig = zrpc_core.transport.TlsConfig;
const Listener = zrpc_core.transport.Listener;

pub const MockTransportAdapter = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) MockTransportAdapter {
        return MockTransportAdapter{
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *MockTransportAdapter) void {
        _ = self;
    }

    pub fn connect(self: *MockTransportAdapter, allocator: std.mem.Allocator, endpoint: []const u8, tls_config: ?*const TlsConfig) TransportError!Connection {
        _ = self;
        _ = tls_config;

        std.debug.print("Mock: Connecting to {s}\n", .{endpoint});

        const conn = try allocator.create(MockConnectionAdapter);
        conn.* = MockConnectionAdapter{
            .allocator = allocator,
            .endpoint = try allocator.dupe(u8, endpoint),
        };

        return Connection{
            .ptr = conn,
            .vtable = &MockConnectionAdapter.vtable,
        };
    }

    pub fn listen(self: *MockTransportAdapter, allocator: std.mem.Allocator, bind_address: []const u8, tls_config: ?*const TlsConfig) TransportError!Listener {
        _ = self;
        _ = tls_config;

        std.debug.print("Mock: Listening on {s}\n", .{bind_address});

        const listener = try allocator.create(MockListenerAdapter);
        listener.* = MockListenerAdapter{
            .allocator = allocator,
            .bind_address = try allocator.dupe(u8, bind_address),
        };

        return Listener{
            .ptr = listener,
            .vtable = &MockListenerAdapter.vtable,
        };
    }
};

const MockConnectionAdapter = struct {
    allocator: std.mem.Allocator,
    endpoint: []const u8,
    stream_counter: u32 = 0,

    fn openStream(ptr: *anyopaque) TransportError!Stream {
        const self: *MockConnectionAdapter = @ptrCast(@alignCast(ptr));

        const stream = try self.allocator.create(MockStreamAdapter);
        stream.* = MockStreamAdapter.init(self.allocator, self.stream_counter);
        self.stream_counter += 1;

        std.debug.print("Mock: Opened stream {}\n", .{stream.stream_id});

        return Stream{
            .ptr = stream,
            .vtable = &MockStreamAdapter.vtable,
        };
    }

    fn close(ptr: *anyopaque) void {
        const self: *MockConnectionAdapter = @ptrCast(@alignCast(ptr));
        std.debug.print("Mock: Closing connection to {s}\n", .{self.endpoint});
        self.allocator.free(self.endpoint);
        self.allocator.destroy(self);
    }

    fn ping(ptr: *anyopaque) TransportError!void {
        _ = ptr;
        std.debug.print("Mock: Ping successful\n", .{});
    }

    fn isConnected(ptr: *anyopaque) bool {
        _ = ptr;
        return true; // Mock is always "connected"
    }

    const vtable = Connection.VTable{
        .openStream = openStream,
        .close = close,
        .ping = ping,
        .isConnected = isConnected,
    };
};

const MockListenerAdapter = struct {
    allocator: std.mem.Allocator,
    bind_address: []const u8,

    fn accept(ptr: *anyopaque) TransportError!Connection {
        const self: *MockListenerAdapter = @ptrCast(@alignCast(ptr));

        std.debug.print("Mock: Accepting connection\n", .{});

        const conn = try self.allocator.create(MockConnectionAdapter);
        conn.* = MockConnectionAdapter{
            .allocator = self.allocator,
            .endpoint = try self.allocator.dupe(u8, "mock-client"),
        };

        return Connection{
            .ptr = conn,
            .vtable = &MockConnectionAdapter.vtable,
        };
    }

    fn close(ptr: *anyopaque) void {
        const self: *MockListenerAdapter = @ptrCast(@alignCast(ptr));
        std.debug.print("Mock: Closing listener on {s}\n", .{self.bind_address});
        self.allocator.free(self.bind_address);
        self.allocator.destroy(self);
    }

    const vtable = Listener.VTable{
        .accept = accept,
        .close = close,
    };
};

const MockStreamAdapter = struct {
    allocator: std.mem.Allocator,
    stream_id: u32,
    data_buffer: std.ArrayList(u8),
    frames_to_read: std.ArrayList(Frame),

    fn writeFrame(ptr: *anyopaque, frame_type: FrameType, flags: u8, data: []const u8) TransportError!void {
        const self: *MockStreamAdapter = @ptrCast(@alignCast(ptr));

        std.debug.print("Mock: Writing frame type {} with {} bytes\n", .{ @intFromEnum(frame_type), data.len });

        // For mock, just echo the frame back for reading
        const frame = Frame.init(self.allocator, frame_type, flags, data) catch return TransportError.ResourceExhausted;
        self.frames_to_read.append(self.allocator, frame) catch return TransportError.ResourceExhausted;
    }

    fn readFrame(ptr: *anyopaque, allocator: std.mem.Allocator) TransportError!Frame {
        const self: *MockStreamAdapter = @ptrCast(@alignCast(ptr));

        if (self.frames_to_read.items.len == 0) {
            // Create a mock response frame
            const response_data = "Mock response from server";
            return Frame.init(allocator, FrameType.data, Frame.Flags.END_STREAM, response_data) catch TransportError.ResourceExhausted;
        }

        const frame = self.frames_to_read.orderedRemove(0);
        std.debug.print("Mock: Read frame type {} with {} bytes\n", .{ @intFromEnum(frame.frame_type), frame.data.len });

        // Transfer ownership to the provided allocator
        const new_frame = Frame.init(allocator, frame.frame_type, frame.flags, frame.data) catch TransportError.ResourceExhausted;
        // Clean up the original frame
        var mutable_frame = frame;
        mutable_frame.deinit();

        return new_frame;
    }

    fn cancel(ptr: *anyopaque) void {
        const self: *MockStreamAdapter = @ptrCast(@alignCast(ptr));
        std.debug.print("Mock: Canceling stream {}\n", .{self.stream_id});
    }

    fn close(ptr: *anyopaque) void {
        const self: *MockStreamAdapter = @ptrCast(@alignCast(ptr));
        std.debug.print("Mock: Closing stream {}\n", .{self.stream_id});

        // Clean up frames
        for (self.frames_to_read.items) |*frame| {
            frame.deinit();
        }
        self.frames_to_read.deinit(self.allocator);
        self.data_buffer.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    const vtable = Stream.VTable{
        .writeFrame = writeFrame,
        .readFrame = readFrame,
        .cancel = cancel,
        .close = close,
    };

    fn init(allocator: std.mem.Allocator, stream_id: u32) MockStreamAdapter {
        return MockStreamAdapter{
            .allocator = allocator,
            .stream_id = stream_id,
            .data_buffer = std.ArrayList(u8){},
            .frames_to_read = std.ArrayList(Frame){},
        };
    }
};

/// Convenience function to create a mock transport
pub fn createTransport(allocator: std.mem.Allocator) Transport {
    const adapter = allocator.create(MockTransportAdapter) catch @panic("OOM");
    adapter.* = MockTransportAdapter.init(allocator);
    return zrpc_core.transport.createTransport(MockTransportAdapter, adapter);
}

test "mock transport basic functionality" {
    const allocator = std.testing.allocator;

    var adapter = MockTransportAdapter.init(allocator);
    defer adapter.deinit();

    // Test that we can create connections
    const transport = createTransport(allocator);
    const conn = try transport.connect(allocator, "localhost:8080", null);
    defer conn.close();

    try std.testing.expect(conn.isConnected());
}