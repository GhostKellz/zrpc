//! Transport-agnostic RPC client
//! Takes a Transport interface and provides RPC calling functionality

const std = @import("std");
const transport_interface = @import("../transport_interface.zig");
const codec = @import("../codec.zig");
const Error = @import("../error.zig").Error;

const Transport = transport_interface.Transport;
const Connection = transport_interface.Connection;
const Stream = transport_interface.Stream;
const Frame = transport_interface.Frame;
const FrameType = transport_interface.FrameType;
const TransportError = transport_interface.TransportError;
const TlsConfig = transport_interface.TlsConfig;
const Listener = transport_interface.Listener;

pub const ClientConfig = struct {
    transport: Transport,
    default_timeout_ms: u32 = 30000,
    max_concurrent_streams: u32 = 100,
};

pub const Client = struct {
    allocator: std.mem.Allocator,
    transport: Transport,
    connection: ?Connection,
    config: ClientConfig,
    next_stream_id: u32,
    active_streams: std.AutoHashMap(u32, *ActiveStream),

    const ActiveStream = struct {
        stream: Stream,
        stream_id: u32,
        method: []const u8,
        timeout_ms: u32,
        response_received: bool,
        allocator: std.mem.Allocator,

        pub fn deinit(self: *ActiveStream) void {
            self.allocator.free(self.method);
        }
    };

    pub fn init(allocator: std.mem.Allocator, config: ClientConfig) Client {
        return Client{
            .allocator = allocator,
            .transport = config.transport,
            .connection = null,
            .config = config,
            .next_stream_id = 1,
            .active_streams = std.AutoHashMap(u32, *ActiveStream).init(allocator),
        };
    }

    pub fn deinit(self: *Client) void {
        self.disconnect();

        // Clean up active streams
        var stream_iter = self.active_streams.iterator();
        while (stream_iter.next()) |entry| {
            entry.value_ptr.*.deinit();
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.active_streams.deinit();
    }

    pub fn connect(self: *Client, endpoint: []const u8, tls_config: ?*const TlsConfig) Error!void {
        self.connection = self.transport.connect(self.allocator, endpoint, tls_config) catch |err| {
            return switch (err) {
                TransportError.Timeout => Error.DeadlineExceeded,
                TransportError.ConnectionReset => Error.NetworkError,
                TransportError.InvalidState => Error.NetworkError,
                else => Error.TransportError,
            };
        };
    }

    pub fn disconnect(self: *Client) void {
        if (self.connection) |conn| {
            conn.close();
            self.connection = null;
        }
    }

    pub fn call(self: *Client, method: []const u8, request_data: []const u8) Error![]u8 {
        return self.callWithTimeout(method, request_data, self.config.default_timeout_ms);
    }

    pub fn callWithTimeout(self: *Client, method: []const u8, request_data: []const u8, timeout_ms: u32) Error![]u8 {
        if (self.connection == null) return Error.InvalidState;

        // Open stream for this RPC
        const stream = self.connection.?.openStream() catch |err| {
            return switch (err) {
                TransportError.ResourceExhausted => Error.ResourceExhausted,
                TransportError.Closed => Error.NetworkError,
                else => Error.TransportError,
            };
        };

        const stream_id = self.next_stream_id;
        self.next_stream_id += 1;

        // Track active stream
        const active_stream = try self.allocator.create(ActiveStream);
        active_stream.* = ActiveStream{
            .stream = stream,
            .stream_id = stream_id,
            .method = try self.allocator.dupe(u8, method),
            .timeout_ms = timeout_ms,
            .response_received = false,
            .allocator = self.allocator,
        };
        try self.active_streams.put(stream_id, active_stream);

        defer {
            _ = self.active_streams.remove(stream_id);
            active_stream.deinit();
            self.allocator.destroy(active_stream);
        }

        // Send headers frame
        try self.sendHeaders(stream, method);

        // Send data frame with request
        try self.sendData(stream, request_data, true); // End stream

        // Read response
        return try self.readResponse(stream, timeout_ms);
    }

    fn sendHeaders(self: *Client, stream: Stream, method: []const u8) Error!void {
        var headers = std.ArrayList(u8){};
        defer headers.deinit(self.allocator);

        // Build gRPC headers
        try headers.appendSlice(self.allocator, ":method");
        try headers.append(self.allocator, 0);
        try headers.appendSlice(self.allocator, "POST");
        try headers.append(self.allocator, 0);
        try headers.appendSlice(self.allocator, ":path");
        try headers.append(self.allocator, 0);
        try headers.append(self.allocator, '/');
        try headers.appendSlice(self.allocator, method);
        try headers.append(self.allocator, 0);
        try headers.appendSlice(self.allocator, "content-type");
        try headers.append(self.allocator, 0);
        try headers.appendSlice(self.allocator, "application/grpc");
        try headers.append(self.allocator, 0);
        try headers.appendSlice(self.allocator, "grpc-encoding");
        try headers.append(self.allocator, 0);
        try headers.appendSlice(self.allocator, "identity");
        try headers.append(self.allocator, 0);

        stream.writeFrame(FrameType.headers, Frame.Flags.END_HEADERS, headers.items) catch |err| {
            return switch (err) {
                TransportError.Timeout => Error.DeadlineExceeded,
                TransportError.Closed => Error.NetworkError,
                else => Error.TransportError,
            };
        };
    }

    fn sendData(self: *Client, stream: Stream, data: []const u8, end_stream: bool) Error!void {
        // gRPC message framing: [compressed flag (1 byte)][length (4 bytes)][data]
        var framed_data = std.ArrayList(u8){};
        defer framed_data.deinit(self.allocator);

        try framed_data.append(self.allocator, 0); // Not compressed
        const length_bytes = std.mem.toBytes(std.mem.nativeToBig(u32, @intCast(data.len)));
        try framed_data.appendSlice(self.allocator, &length_bytes);
        try framed_data.appendSlice(self.allocator, data);

        const flags: u8 = if (end_stream) Frame.Flags.END_STREAM else 0;
        stream.writeFrame(FrameType.data, flags, framed_data.items) catch |err| {
            return switch (err) {
                TransportError.Timeout => Error.DeadlineExceeded,
                TransportError.Closed => Error.NetworkError,
                else => Error.TransportError,
            };
        };
    }

    fn readResponse(self: *Client, stream: Stream, timeout_ms: u32) Error![]u8 {
        _ = timeout_ms; // TODO: Implement timeout handling

        var response_data = std.ArrayList(u8){};
        defer response_data.deinit(self.allocator);

        var headers_received = false;
        var end_stream_received = false;

        while (!end_stream_received) {
            var frame = stream.readFrame(self.allocator) catch |err| {
                return switch (err) {
                    TransportError.Timeout => Error.DeadlineExceeded,
                    TransportError.Closed => Error.NetworkError,
                    TransportError.Canceled => Error.Aborted,
                    else => Error.TransportError,
                };
            };
            defer frame.deinit();

            switch (frame.frame_type) {
                .headers => {
                    headers_received = true;
                    // TODO: Parse response headers for status, metadata
                },
                .data => {
                    // Parse gRPC message framing
                    if (frame.data.len < 5) return Error.InvalidData;

                    const compression_flag = frame.data[0];
                    _ = compression_flag; // Not implemented yet

                    const message_length = std.mem.readInt(u32, frame.data[1..5], .big);
                    if (frame.data.len < 5 + message_length) return Error.InvalidData;

                    const message_data = frame.data[5..5 + message_length];
                    try response_data.appendSlice(self.allocator, message_data);

                    if (frame.flags & Frame.Flags.END_STREAM != 0) {
                        end_stream_received = true;
                    }
                },
                .status => {
                    // TODO: Handle status frames
                    if (frame.flags & Frame.Flags.END_STREAM != 0) {
                        end_stream_received = true;
                    }
                },
                else => {
                    // Ignore other frame types
                },
            }
        }

        if (!headers_received) return Error.InvalidData;

        return try response_data.toOwnedSlice(self.allocator);
    }

    pub fn isConnected(self: *Client) bool {
        if (self.connection) |conn| {
            return conn.isConnected();
        }
        return false;
    }

    pub fn ping(self: *Client) Error!void {
        if (self.connection == null) return Error.InvalidState;

        self.connection.?.ping() catch |err| {
            return switch (err) {
                TransportError.Timeout => Error.DeadlineExceeded,
                TransportError.Closed => Error.NetworkError,
                else => Error.TransportError,
            };
        };
    }
};

test "client basic functionality" {
    // Mock transport for testing
    const MockTransport = struct {
        pub fn connect(self: *@This(), allocator: std.mem.Allocator, endpoint: []const u8, tls_config: ?*const TlsConfig) TransportError!Connection {
            _ = self;
            _ = allocator;
            _ = endpoint;
            _ = tls_config;
            return TransportError.InvalidState;
        }

        pub fn listen(self: *@This(), allocator: std.mem.Allocator, bind_address: []const u8, tls_config: ?*const TlsConfig) TransportError!Listener {
            _ = self;
            _ = allocator;
            _ = bind_address;
            _ = tls_config;
            return TransportError.InvalidState;
        }

        pub fn deinit(self: *@This()) void {
            _ = self;
        }
    };

    var mock_transport = MockTransport{};
    const transport = transport_interface.createTransport(MockTransport, &mock_transport);

    var client = Client.init(std.testing.allocator, .{ .transport = transport });
    defer client.deinit();

    try std.testing.expect(!client.isConnected());
}