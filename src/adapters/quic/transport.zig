//! QUIC transport adapter for zrpc
//! Implements the transport interface using the existing QUIC implementation

const std = @import("std");
const zrpc_core = @import("zrpc-core");
const transport_interface = zrpc_core.transport;
const Error = zrpc_core.Error;

// Import the existing QUIC implementation
const quic = @import("../../quic.zig");
const QuicConnection = quic.QuicConnection;
const QuicStream = quic.QuicStream;

const Transport = transport_interface.Transport;
const Connection = transport_interface.Connection;
const Stream = transport_interface.Stream;
const Frame = transport_interface.Frame;
const FrameType = transport_interface.FrameType;
const TransportError = transport_interface.TransportError;
const TlsConfig = transport_interface.TlsConfig;
const Listener = transport_interface.Listener;

pub const QuicTransportAdapter = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) QuicTransportAdapter {
        return QuicTransportAdapter{
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *QuicTransportAdapter) void {
        _ = self;
    }

    pub fn connect(self: *QuicTransportAdapter, allocator: std.mem.Allocator, endpoint: []const u8, tls_config: ?*const TlsConfig) TransportError!Connection {
        _ = tls_config; // TODO: Map TLS config to QUIC config in real implementation

        // Parse endpoint
        const parsed = self.parseEndpoint(endpoint) catch return TransportError.InvalidArgument;
        const address = std.net.Address.resolveIp(parsed.host, parsed.port) catch return TransportError.InvalidArgument;

        std.log.info("QUIC: Connecting to {s}:{d}", .{ parsed.host, parsed.port });

        // Create QUIC connection using existing implementation
        var quic_conn = QuicConnection.initClient(allocator, address) catch |err| {
            std.log.err("QUIC: Failed to create connection: {}", .{err});
            return switch (err) {
                error.ConnectionRefused => TransportError.ConnectionReset,
                error.OutOfMemory => TransportError.OutOfMemory,
                else => TransportError.Protocol,
            };
        };

        // Perform QUIC handshake
        quic_conn.handshake() catch |err| {
            std.log.err("QUIC: Handshake failed: {}", .{err});
            quic_conn.deinit();
            return TransportError.Protocol;
        };

        std.log.info("QUIC: Connection established");

        // Create adapter connection
        const adapter_conn = try allocator.create(QuicConnectionAdapter);
        adapter_conn.* = QuicConnectionAdapter{
            .quic_connection = quic_conn,
            .allocator = allocator,
            .streams = std.AutoHashMap(u64, *QuicStreamAdapter).init(allocator),
            .next_stream_id = 0,
        };

        return Connection{
            .ptr = adapter_conn,
            .vtable = &QuicConnectionAdapter.vtable,
        };
    }

    pub fn listen(self: *QuicTransportAdapter, allocator: std.mem.Allocator, bind_address: []const u8, tls_config: ?*const TlsConfig) TransportError!Listener {
        _ = tls_config; // TODO: Implement TLS config handling

        // Parse bind address
        const parsed = self.parseEndpoint(bind_address) catch return TransportError.InvalidArgument;
        const address = std.net.Address.initIp4([4]u8{ 127, 0, 0, 1 }, parsed.port);

        // Create QUIC listener adapter
        const adapter_listener = try allocator.create(QuicListenerAdapter);
        adapter_listener.* = QuicListenerAdapter{
            .bind_address = address,
            .allocator = allocator,
            .is_listening = false,
        };

        return Listener{
            .ptr = adapter_listener,
            .vtable = &QuicListenerAdapter.vtable,
        };
    }

    fn parseEndpoint(self: *QuicTransportAdapter, endpoint: []const u8) !struct { host: []const u8, port: u16 } {
        _ = self;

        const colon_pos = std.mem.lastIndexOfScalar(u8, endpoint, ':') orelse return error.InvalidEndpoint;
        const host = endpoint[0..colon_pos];
        const port_str = endpoint[colon_pos + 1..];
        const port = std.fmt.parseInt(u16, port_str, 10) catch return error.InvalidEndpoint;

        return .{ .host = host, .port = port };
    }
};

const QuicConnectionAdapter = struct {
    quic_connection: QuicConnection,
    allocator: std.mem.Allocator,
    streams: std.AutoHashMap(u64, *QuicStreamAdapter),
    next_stream_id: u64,

    fn openStream(ptr: *anyopaque) TransportError!Stream {
        const self: *QuicConnectionAdapter = @ptrCast(@alignCast(ptr));

        std.log.debug("QUIC: Creating new stream {d}", .{self.next_stream_id});

        // Create QUIC stream using existing implementation
        const quic_stream = self.quic_connection.createStream() catch |err| {
            std.log.err("QUIC: Failed to create stream: {}", .{err});
            return switch (err) {
                error.OutOfMemory => TransportError.OutOfMemory,
                else => TransportError.Protocol,
            };
        };

        // Create stream adapter
        const adapter_stream = try self.allocator.create(QuicStreamAdapter);
        adapter_stream.* = QuicStreamAdapter{
            .quic_stream = quic_stream,
            .allocator = self.allocator,
            .stream_id = self.next_stream_id,
            .frame_buffer = std.ArrayList(u8){},
        };

        // Track the stream
        try self.streams.put(self.next_stream_id, adapter_stream);
        self.next_stream_id += 1;

        std.log.debug("QUIC: Stream {d} created successfully", .{adapter_stream.stream_id});

        return Stream{
            .ptr = adapter_stream,
            .vtable = &QuicStreamAdapter.vtable,
        };
    }

    fn close(ptr: *anyopaque) void {
        const self: *QuicConnectionAdapter = @ptrCast(@alignCast(ptr));

        // Clean up all streams
        var stream_iter = self.streams.iterator();
        while (stream_iter.next()) |entry| {
            entry.value_ptr.*.frame_buffer.deinit();
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.streams.deinit();

        self.quic_connection.deinit();
        self.allocator.destroy(self);
    }

    fn ping(ptr: *anyopaque) TransportError!void {
        const self: *QuicConnectionAdapter = @ptrCast(@alignCast(ptr));
        _ = self; // TODO: Implement QUIC ping
        return TransportError.Protocol;
    }

    fn isConnected(ptr: *anyopaque) bool {
        const self: *QuicConnectionAdapter = @ptrCast(@alignCast(ptr));
        return self.quic_connection.isMultiplexingCapable();
    }

    pub const vtable = Connection.VTable{
        .openStream = openStream,
        .close = close,
        .ping = ping,
        .isConnected = isConnected,
    };
};

const QuicListenerAdapter = struct {
    bind_address: std.net.Address,
    allocator: std.mem.Allocator,
    is_listening: bool,
    socket: ?std.net.Stream = null,

    fn accept(ptr: *anyopaque) TransportError!Connection {
        const self: *QuicListenerAdapter = @ptrCast(@alignCast(ptr));
        _ = self; // TODO: Implement QUIC server accept
        return TransportError.Protocol;
    }

    fn close(ptr: *anyopaque) void {
        const self: *QuicListenerAdapter = @ptrCast(@alignCast(ptr));
        if (self.socket) |socket| {
            socket.close();
        }
        self.is_listening = false;
        self.allocator.destroy(self);
    }

    pub const vtable = Listener.VTable{
        .accept = accept,
        .close = close,
    };
};

const QuicStreamAdapter = struct {
    quic_stream: *quic.QuicStream,
    allocator: std.mem.Allocator,
    stream_id: u64,
    frame_buffer: std.ArrayList(u8),

    fn writeFrame(ptr: *anyopaque, frame_type: FrameType, flags: u8, data: []const u8) TransportError!void {
        const self: *QuicStreamAdapter = @ptrCast(@alignCast(ptr));

        // Map RPC frame to QUIC stream data
        var frame_data = std.ArrayList(u8){};
        defer frame_data.deinit();

        // Simple framing: [frame_type(1)][flags(1)][length(4)][data]
        try frame_data.append(@intFromEnum(frame_type));
        try frame_data.append(flags);

        const length_bytes = std.mem.toBytes(std.mem.nativeToBig(u32, @intCast(data.len)));
        try frame_data.appendSlice(&length_bytes);
        try frame_data.appendSlice(data);

        self.quic_stream.write(frame_data.items) catch |err| {
            return switch (err) {
                error.OutOfMemory => TransportError.ResourceExhausted,
                else => TransportError.Protocol,
            };
        };

        // Handle end stream
        if (flags & Frame.Flags.END_STREAM != 0) {
            self.quic_stream.finish();
        }
    }

    fn readFrame(ptr: *anyopaque, allocator: std.mem.Allocator) TransportError!Frame {
        const self: *QuicStreamAdapter = @ptrCast(@alignCast(ptr));

        // Read frame header (6 bytes: frame_type + flags + length)
        var header_buf: [6]u8 = undefined;
        const header_read = self.quic_stream.read(&header_buf) catch |err| {
            return switch (err) {
                else => TransportError.Protocol,
            };
        };

        if (header_read < 6) return TransportError.Protocol;

        const frame_type: FrameType = @enumFromInt(header_buf[0]);
        const flags = header_buf[1];
        const data_length = std.mem.readInt(u32, header_buf[2..6], .big);

        // Read frame data
        const frame_data = try allocator.alloc(u8, data_length);
        const data_read = self.quic_stream.read(frame_data) catch |err| {
            allocator.free(frame_data);
            return switch (err) {
                else => TransportError.Protocol,
            };
        };

        if (data_read < data_length) {
            allocator.free(frame_data);
            return TransportError.Protocol;
        }

        return Frame{
            .frame_type = frame_type,
            .flags = flags,
            .data = frame_data,
            .allocator = allocator,
        };
    }

    fn cancel(ptr: *anyopaque) void {
        const self: *QuicStreamAdapter = @ptrCast(@alignCast(ptr));
        // QUIC cancel maps to stream reset
        self.quic_stream.finish(); // Close the stream
    }

    fn close(ptr: *anyopaque) void {
        const self: *QuicStreamAdapter = @ptrCast(@alignCast(ptr));
        self.quic_stream.finish();
        self.frame_buffer.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    pub const vtable = Stream.VTable{
        .writeFrame = writeFrame,
        .readFrame = readFrame,
        .cancel = cancel,
        .close = close,
    };
};

/// Convenience function to create a QUIC transport
pub fn createTransport(allocator: std.mem.Allocator) Transport {
    const adapter = allocator.create(QuicTransportAdapter) catch @panic("OOM");
    adapter.* = QuicTransportAdapter.init(allocator);
    return transport_interface.createTransport(QuicTransportAdapter, adapter);
}

test "QUIC transport adapter creation" {
    const allocator = std.testing.allocator;

    var adapter = QuicTransportAdapter.init(allocator);
    defer adapter.deinit();

    // Test endpoint parsing
    const parsed = try adapter.parseEndpoint("localhost:8080");
    try std.testing.expectEqualStrings("localhost", parsed.host);
    try std.testing.expectEqual(@as(u16, 8080), parsed.port);
}