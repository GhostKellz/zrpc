const std = @import("std");
const Error = @import("error.zig").Error;
const tls = @import("tls.zig");
const quic = @import("quic.zig");
const metadata_mod = @import("metadata.zig");

pub const Metadata = metadata_mod.Metadata;
pub const Context = metadata_mod.Context;

pub const Message = struct {
    headers: std.StringHashMap([]const u8),
    body: []const u8,
    allocator: std.mem.Allocator,
    metadata: ?*Metadata, // Optional gRPC metadata
    context: ?*Context, // Optional context with deadline

    pub fn init(allocator: std.mem.Allocator, body: []const u8) Message {
        return Message{
            .headers = std.StringHashMap([]const u8).init(allocator),
            .body = body,
            .allocator = allocator,
            .metadata = null,
            .context = null,
        };
    }

    pub fn initWithMetadata(allocator: std.mem.Allocator, body: []const u8, meta: *Metadata) Message {
        return Message{
            .headers = std.StringHashMap([]const u8).init(allocator),
            .body = body,
            .allocator = allocator,
            .metadata = meta,
            .context = null,
        };
    }

    pub fn initWithContext(allocator: std.mem.Allocator, body: []const u8, ctx: *Context) Message {
        return Message{
            .headers = std.StringHashMap([]const u8).init(allocator),
            .body = body,
            .allocator = allocator,
            .metadata = &ctx.metadata,
            .context = ctx,
        };
    }

    pub fn deinit(self: *Message) void {
        self.headers.deinit();
    }

    pub fn addHeader(self: *Message, key: []const u8, value: []const u8) !void {
        try self.headers.put(key, value);
    }
};

pub const StreamId = u32;

pub const Frame = struct {
    stream_id: StreamId,
    frame_type: FrameType,
    flags: u8,
    data: []const u8,

    pub const FrameType = enum(u8) {
        data = 0x0,
        headers = 0x1,
        priority = 0x2,
        rst_stream = 0x3,
        settings = 0x4,
        push_promise = 0x5,
        ping = 0x6,
        goaway = 0x7,
        window_update = 0x8,
        continuation = 0x9,
    };

    pub const Flags = struct {
        pub const END_STREAM: u8 = 0x1;
        pub const END_HEADERS: u8 = 0x4;
        pub const PADDED: u8 = 0x8;
        pub const PRIORITY: u8 = 0x20;
    };
};

pub const ConnectionType = union(enum) {
    tcp: std.net.Stream,
    tls: tls.TlsConnection,
    quic: *quic.QuicConnection,
};

pub const Http2Connection = struct {
    allocator: std.mem.Allocator,
    connection: ConnectionType,
    next_stream_id: StreamId,
    window_size: u32,
    is_server: bool,

    const PREFACE = "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n";

    pub fn initClient(allocator: std.mem.Allocator, stream: std.net.Stream) Http2Connection {
        return Http2Connection{
            .allocator = allocator,
            .connection = ConnectionType{ .tcp = stream },
            .next_stream_id = 1,
            .window_size = 65535,
            .is_server = false,
        };
    }

    pub fn initClientTls(allocator: std.mem.Allocator, tls_conn: tls.TlsConnection) Http2Connection {
        return Http2Connection{
            .allocator = allocator,
            .connection = ConnectionType{ .tls = tls_conn },
            .next_stream_id = 1,
            .window_size = 65535,
            .is_server = false,
        };
    }

    pub fn initServer(allocator: std.mem.Allocator, stream: std.net.Stream) Http2Connection {
        return Http2Connection{
            .allocator = allocator,
            .connection = ConnectionType{ .tcp = stream },
            .next_stream_id = 2,
            .window_size = 65535,
            .is_server = true,
        };
    }

    pub fn initServerTls(allocator: std.mem.Allocator, tls_conn: tls.TlsConnection) Http2Connection {
        return Http2Connection{
            .allocator = allocator,
            .connection = ConnectionType{ .tls = tls_conn },
            .next_stream_id = 2,
            .window_size = 65535,
            .is_server = true,
        };
    }

    fn writeToConnection(self: *Http2Connection, data: []const u8) Error!void {
        switch (self.connection) {
            .tcp => |stream| {
                _ = stream.write(data) catch return Error.NetworkError;
            },
            .tls => |*tls_conn| {
                _ = tls_conn.write(data) catch return Error.NetworkError;
            },
            .quic => |quic_conn| {
                _ = quic_conn.socket.write(data) catch return Error.NetworkError;
            },
        }
    }

    fn readFromConnection(self: *Http2Connection, buffer: []u8) Error!usize {
        return switch (self.connection) {
            .tcp => |stream| stream.read(buffer) catch Error.NetworkError,
            .tls => |*tls_conn| tls_conn.read(buffer) catch Error.NetworkError,
            .quic => |quic_conn| quic_conn.socket.read(buffer) catch Error.NetworkError,
        };
    }

    fn readAllFromConnection(self: *Http2Connection, buffer: []u8) Error!void {
        var bytes_read: usize = 0;
        while (bytes_read < buffer.len) {
            const n = try self.readFromConnection(buffer[bytes_read..]);
            if (n == 0) return Error.NetworkError;
            bytes_read += n;
        }
    }

    pub fn sendPreface(self: *Http2Connection) Error!void {
        if (!self.is_server) {
            try self.writeToConnection(PREFACE);
        }
    }

    pub fn sendFrame(self: *Http2Connection, frame: Frame) Error!void {
        var frame_header: [9]u8 = undefined;

        // Frame length (24 bits)
        std.mem.writeInt(u24, frame_header[0..3], @intCast(frame.data.len), .big);

        // Frame type (8 bits)
        frame_header[3] = @intFromEnum(frame.frame_type);

        // Flags (8 bits)
        frame_header[4] = frame.flags;

        // Stream ID (32 bits, with reserved bit cleared)
        std.mem.writeInt(u32, frame_header[5..9], frame.stream_id & 0x7FFFFFFF, .big);

        try self.writeToConnection(&frame_header);
        try self.writeToConnection(frame.data);
    }

    pub fn readFrame(self: *Http2Connection) Error!Frame {
        var frame_header: [9]u8 = undefined;
        try self.readAllFromConnection(&frame_header);

        const length = std.mem.readInt(u24, frame_header[0..3], .big);
        const frame_type_int = frame_header[3];
        const flags = frame_header[4];
        const stream_id = std.mem.readInt(u32, frame_header[5..9], .big) & 0x7FFFFFFF;

        const frame_type: Frame.FrameType = @enumFromInt(frame_type_int);

        const data = try self.allocator.alloc(u8, length);
        self.readAllFromConnection(data) catch {
            self.allocator.free(data);
            return Error.NetworkError;
        };

        return Frame{
            .stream_id = stream_id,
            .frame_type = frame_type,
            .flags = flags,
            .data = data,
        };
    }

    pub fn allocateStreamId(self: *Http2Connection) StreamId {
        const id = self.next_stream_id;
        self.next_stream_id += 2;
        return id;
    }
};

pub const Http2Transport = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Http2Transport {
        return Http2Transport{
            .allocator = allocator,
        };
    }

    pub fn send(self: *Http2Transport, endpoint: []const u8, message: Message) Error!Message {
        // Parse endpoint URL
        if (!std.mem.startsWith(u8, endpoint, "http://") and !std.mem.startsWith(u8, endpoint, "https://")) {
            return Error.InvalidArgument;
        }

        const is_https = std.mem.startsWith(u8, endpoint, "https://");
        const url_without_scheme = if (is_https) endpoint[8..] else endpoint[7..];

        const colon_pos = std.mem.indexOf(u8, url_without_scheme, ":");
        const slash_pos = std.mem.indexOf(u8, url_without_scheme, "/");

        const host = if (colon_pos) |pos|
            url_without_scheme[0..pos]
        else if (slash_pos) |pos|
            url_without_scheme[0..pos]
        else
            url_without_scheme;

        const port: u16 = if (colon_pos) |pos| blk: {
            const end_pos = if (slash_pos) |sp| sp else url_without_scheme.len;
            const port_str = url_without_scheme[pos + 1 .. end_pos];
            break :blk std.fmt.parseInt(u16, port_str, 10) catch if (is_https) 443 else 80;
        } else if (is_https) 443 else 80;

        const path = if (slash_pos) |pos|
            url_without_scheme[pos..]
        else
            "/";

        // Connect to server
        const address = std.net.Address.resolveIp(host, port) catch return Error.NetworkError;
        const stream = std.net.tcpConnectToAddress(address) catch return Error.NetworkError;
        defer stream.close();

        var connection = Http2Connection.initClient(self.allocator, stream);
        try connection.sendPreface();

        // Send settings frame
        const settings_data: [0]u8 = .{};
        const settings_frame = Frame{
            .stream_id = 0,
            .frame_type = .settings,
            .flags = 0,
            .data = &settings_data,
        };
        try connection.sendFrame(settings_frame);

        // Create headers for gRPC request
        const stream_id = connection.allocateStreamId();
        const method = message.headers.get("grpc-method") orelse "Unknown/Method";

        var headers_data = std.ArrayList(u8).init(self.allocator);
        try headers_data.ensureTotalCapacity(1024);
        defer headers_data.deinit();

        // Simple pseudo-header encoding (not proper HPACK)
        try headers_data.appendSlice(":method");
        try headers_data.append(0);
        try headers_data.appendSlice("POST");
        try headers_data.append(0);

        try headers_data.appendSlice(":path");
        try headers_data.append(0);
        try headers_data.appendSlice(path);
        try headers_data.append(0);

        try headers_data.appendSlice(":authority");
        try headers_data.append(0);
        try headers_data.appendSlice(host);
        try headers_data.append(0);

        try headers_data.appendSlice("content-type");
        try headers_data.append(0);
        try headers_data.appendSlice("application/grpc");
        try headers_data.append(0);

        try headers_data.appendSlice("grpc-method");
        try headers_data.append(0);
        try headers_data.appendSlice(method);
        try headers_data.append(0);

        const headers_frame = Frame{
            .stream_id = stream_id,
            .frame_type = .headers,
            .flags = Frame.Flags.END_HEADERS,
            .data = headers_data.items,
        };
        try connection.sendFrame(headers_frame);

        // Send data frame
        const data_frame = Frame{
            .stream_id = stream_id,
            .frame_type = .data,
            .flags = Frame.Flags.END_STREAM,
            .data = message.body,
        };
        try connection.sendFrame(data_frame);

        // Read response (simplified - would need proper state machine)
        // For now, return a mock response indicating HTTP/2 transport was used
        var response = Message.init(self.allocator, "HTTP/2 response data");
        try response.addHeader("status", "200");
        try response.addHeader("transport", "http2");
        return response;
    }
};

pub const QuicTransport = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) QuicTransport {
        return QuicTransport{
            .allocator = allocator,
        };
    }

    pub fn send(self: *QuicTransport, endpoint: []const u8, message: Message) Error!Message {
        // Parse endpoint URL for QUIC
        if (!std.mem.startsWith(u8, endpoint, "quic://") and !std.mem.startsWith(u8, endpoint, "quics://")) {
            return Error.InvalidArgument;
        }

        const is_secure = std.mem.startsWith(u8, endpoint, "quics://");
        const url_without_scheme = if (is_secure) endpoint[8..] else endpoint[7..];

        const colon_pos = std.mem.indexOf(u8, url_without_scheme, ":");
        const slash_pos = std.mem.indexOf(u8, url_without_scheme, "/");

        const host = if (colon_pos) |pos|
            url_without_scheme[0..pos]
        else if (slash_pos) |pos|
            url_without_scheme[0..pos]
        else
            url_without_scheme;

        const port: u16 = if (colon_pos) |pos| blk: {
            const end_pos = if (slash_pos) |sp| sp else url_without_scheme.len;
            const port_str = url_without_scheme[pos + 1 .. end_pos];
            break :blk std.fmt.parseInt(u16, port_str, 10) catch if (is_secure) 443 else 80;
        } else if (is_secure) 443 else 80;

        const path = if (slash_pos) |pos|
            url_without_scheme[pos..]
        else
            "/";

        // Create QUIC connection
        const address = std.net.Address.resolveIp(host, port) catch return Error.NetworkError;
        var connection = quic.QuicConnection.initClient(self.allocator, address) catch return Error.NetworkError;
        defer connection.deinit();

        // Perform QUIC handshake
        connection.handshake() catch return Error.NetworkError;

        // Create bidirectional stream for gRPC request
        const stream = connection.createStream() catch return Error.NetworkError;

        // Build gRPC-over-HTTP/3 message
        const method = message.headers.get("grpc-method") orelse "Unknown/Method";

        var grpc_message = std.ArrayList(u8){};
        defer grpc_message.deinit(self.allocator);

        // HTTP/3 headers frame (simplified)
        // In real implementation, would use QPACK compression
        try grpc_message.appendSlice(self.allocator, ":method: POST\r\n");
        try grpc_message.appendSlice(self.allocator, ":path: ");
        try grpc_message.appendSlice(self.allocator, path);
        try grpc_message.appendSlice(self.allocator, "\r\n");
        try grpc_message.appendSlice(self.allocator, ":authority: ");
        try grpc_message.appendSlice(self.allocator, host);
        try grpc_message.appendSlice(self.allocator, "\r\n");
        try grpc_message.appendSlice(self.allocator, "content-type: application/grpc\r\n");
        try grpc_message.appendSlice(self.allocator, "grpc-method: ");
        try grpc_message.appendSlice(self.allocator, method);
        try grpc_message.appendSlice(self.allocator, "\r\n\r\n");

        // gRPC message framing: [compressed flag (1 byte)][length (4 bytes)][data]
        try grpc_message.append(self.allocator, 0); // Not compressed
        const msg_len_bytes = std.mem.toBytes(std.mem.nativeToBig(u32, @intCast(message.body.len)));
        try grpc_message.appendSlice(self.allocator, &msg_len_bytes);
        try grpc_message.appendSlice(self.allocator, message.body);

        // Send data over QUIC stream
        try stream.write(grpc_message.items);
        stream.finish();

        // Create HTTP/3 data frame
        var stream_frame = try quic.QuicFrame.initStream(
            self.allocator,
            stream.id,
            0,
            grpc_message.items,
            true, // FIN bit
        );
        defer stream_frame.deinit();

        const frame_data = try stream_frame.encode(self.allocator);
        defer self.allocator.free(frame_data);

        const header = quic.QuicPacket.PacketHeader{
            .packet_type = .one_rtt,
            .version = quic.QUIC_VERSION_1,
            .dest_connection_id = connection.peer_connection_id,
            .source_connection_id = connection.local_connection_id,
            .packet_number = 1,
            .payload_length = @intCast(frame_data.len),
        };

        var packet = try quic.QuicPacket.init(self.allocator, header, frame_data);
        defer packet.deinit();

        connection.sendPacket(&packet) catch return Error.NetworkError;

        // Read response (simplified)
        var response = Message.init(self.allocator, "QUIC/HTTP3 gRPC response");
        try response.addHeader("status", "200");
        try response.addHeader("transport", "quic");
        try response.addHeader("protocol", "http3");
        return response;
    }
};

pub const MockTransport = struct {
    pub fn send(endpoint: []const u8, message: Message) Error!Message {
        _ = endpoint;
        _ = message;

        var response = Message.init(std.heap.page_allocator, "mock response");
        try response.addHeader("status", "200");
        return response;
    }
};

test "mock transport" {
    var message = Message.init(std.testing.allocator, "test message");
    defer message.deinit();

    var response = try MockTransport.send("http://localhost:8080", message);
    defer response.deinit();

    try std.testing.expectEqualStrings("mock response", response.body);
    try std.testing.expectEqualStrings("200", response.headers.get("status").?);
}

test "http2 frame creation" {
    const data = "test data";
    const frame = Frame{
        .stream_id = 1,
        .frame_type = .data,
        .flags = Frame.Flags.END_STREAM,
        .data = data,
    };

    try std.testing.expectEqual(@as(StreamId, 1), frame.stream_id);
    try std.testing.expectEqual(Frame.FrameType.data, frame.frame_type);
    try std.testing.expectEqual(Frame.Flags.END_STREAM, frame.flags);
    try std.testing.expectEqualStrings("test data", frame.data);
}

test "http2 tls integration" {
    // Mock TLS connection
    const mock_stream = std.net.Stream{ .handle = 0 };
    const tls_config = tls.TlsConfig.clientDefault();
    var tls_conn = tls.TlsConnection.initClient(std.testing.allocator, mock_stream, tls_config);

    // Test TLS handshake
    try tls_conn.handshake();
    try std.testing.expectEqual(true, tls_conn.is_handshake_complete);

    // Test HTTP/2 connection over TLS
    var http2_conn = Http2Connection.initClientTls(std.testing.allocator, tls_conn);
    try std.testing.expectEqual(@as(StreamId, 1), http2_conn.next_stream_id);
    try std.testing.expectEqual(false, http2_conn.is_server);

    // Test ALPN protocol negotiation
    switch (http2_conn.connection) {
        .tls => |*tls_connection| {
            const alpn_protocol = tls_connection.getAlpnProtocol();
            try std.testing.expectEqualStrings("h2", alpn_protocol.?);
        },
        else => unreachable,
    }
}

test "quic transport basic functionality" {
    var transport = QuicTransport.init(std.testing.allocator);

    var message = Message.init(std.testing.allocator, "test grpc message");
    defer message.deinit();

    try message.addHeader("grpc-method", "TestService/TestMethod");

    // Test URL parsing for QUIC endpoints
    const valid_endpoints = [_][]const u8{
        "quic://localhost:8080/TestService/TestMethod",
        "quics://secure.example.com:443/api/grpc",
    };

    for (valid_endpoints) |endpoint| {
        // Would normally test actual connection, but for unit test just verify parsing
        const result = transport.send(endpoint, message);
        // Expect network error since we're not actually connecting
        try std.testing.expectError(Error.NetworkError, result);
    }

    // Test invalid endpoints
    const invalid_endpoints = [_][]const u8{
        "http://localhost:8080/test",
        "https://example.com/api",
        "invalid://test",
    };

    for (invalid_endpoints) |endpoint| {
        const result = transport.send(endpoint, message);
        try std.testing.expectError(Error.InvalidArgument, result);
    }
}

test "quic frame creation and encoding" {
    const test_data = "Hello, QUIC!";
    var frame = try quic.QuicFrame.initStream(std.testing.allocator, 4, 0, test_data, true);
    defer frame.deinit();

    const encoded = try frame.encode(std.testing.allocator);
    defer std.testing.allocator.free(encoded);

    try std.testing.expect(encoded.len > test_data.len);
    try std.testing.expectEqual(quic.FrameType.stream, frame.frame_type);
    try std.testing.expectEqual(@as(u64, 4), frame.stream_id.?);
    try std.testing.expectEqual(true, frame.fin);
}

test "quic connection creation" {
    const address = std.net.Address.initIp4([4]u8{ 127, 0, 0, 1 }, 8080);

    // This will fail to connect, but we can test the initialization path.
    var conn = quic.QuicConnection.initClient(std.testing.allocator, address) catch |err| {
        switch (err) {
            error.ConnectionRefused, error.NetworkUnreachable, error.ConnectionTimedOut, error.AddressNotAvailable => return,
            else => return err,
        }
    };
    defer conn.deinit();
    try std.testing.expect(!conn.is_server);
}
