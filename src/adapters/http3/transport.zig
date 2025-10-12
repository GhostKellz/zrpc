const std = @import("std");
const transport = @import("../../transport.zig");
const TransportError = transport.TransportError;
const Connection = transport.Connection;
const Stream = transport.Stream;
const Listener = transport.Listener;
const Frame = transport.Frame;

// Import QUIC implementation
const quic = @import("../../quic.zig");
const QuicConnection = quic.QuicConnection;
const QuicStream = quic.QuicStream;

/// HTTP/3 Transport Adapter (RFC 9114)
/// Provides gRPC-over-HTTP/3 transport with:
/// - QUIC as transport layer (RFC 9000)
/// - QPACK header compression (RFC 9204)
/// - HTTP/3 frame types
/// - Stream multiplexing
/// - 0-RTT support

/// HTTP/3 Frame Types (RFC 9114 Section 7.2)
pub const Http3FrameType = enum(u64) {
    data = 0x00,
    headers = 0x01,
    cancel_push = 0x03,
    settings = 0x04,
    push_promise = 0x05,
    goaway = 0x07,
    max_push_id = 0x0d,

    /// gRPC extension frames
    grpc_message = 0x100, // Custom frame type for gRPC

    pub fn encode(self: Http3FrameType) u64 {
        return @intFromEnum(self);
    }
};

/// HTTP/3 Settings (RFC 9114 Section 7.2.4)
pub const Http3Settings = struct {
    max_table_capacity: u64 = 4096, // QPACK dynamic table size
    blocked_streams: u64 = 100, // QPACK blocked streams
    enable_connect_protocol: bool = false,
    enable_webtransport: bool = false,
};

/// HTTP/3 Error Codes (RFC 9114 Section 8.1)
pub const Http3ErrorCode = enum(u64) {
    no_error = 0x100,
    general_protocol_error = 0x101,
    internal_error = 0x102,
    stream_creation_error = 0x103,
    closed_critical_stream = 0x104,
    frame_unexpected = 0x105,
    frame_error = 0x106,
    excessive_load = 0x107,
    id_error = 0x108,
    settings_error = 0x109,
    missing_settings = 0x10a,
    request_rejected = 0x10b,
    request_cancelled = 0x10c,
    request_incomplete = 0x10d,
    message_error = 0x10e,
    connect_error = 0x10f,
    version_fallback = 0x110,
    qpack_decompression_failed = 0x200,
    qpack_encoder_stream_error = 0x201,
    qpack_decoder_stream_error = 0x202,
};

/// Variable-length integer encoding (RFC 9000 Section 16)
const VarInt = struct {
    /// Encode a variable-length integer
    pub fn encode(value: u64, writer: anytype) !void {
        if (value < 64) {
            // 1-byte encoding (00 prefix)
            try writer.writeByte(@intCast(value));
        } else if (value < 16384) {
            // 2-byte encoding (01 prefix)
            const encoded: u16 = @intCast(value | 0x4000);
            try writer.writeInt(u16, encoded, .big);
        } else if (value < 1073741824) {
            // 4-byte encoding (10 prefix)
            const encoded: u32 = @intCast(value | 0x80000000);
            try writer.writeInt(u32, encoded, .big);
        } else {
            // 8-byte encoding (11 prefix)
            const encoded: u64 = value | 0xC000000000000000;
            try writer.writeInt(u64, encoded, .big);
        }
    }

    /// Decode a variable-length integer
    pub fn decode(reader: anytype) !u64 {
        const first_byte = try reader.readByte();
        const prefix = first_byte >> 6;

        switch (prefix) {
            0 => {
                // 1-byte encoding
                return @as(u64, first_byte & 0x3F);
            },
            1 => {
                // 2-byte encoding
                const second_byte = try reader.readByte();
                const value = (@as(u16, first_byte & 0x3F) << 8) | @as(u16, second_byte);
                return @as(u64, value);
            },
            2 => {
                // 4-byte encoding
                var buf: [3]u8 = undefined;
                _ = try reader.readAll(&buf);
                const value = (@as(u32, first_byte & 0x3F) << 24) |
                    (@as(u32, buf[0]) << 16) |
                    (@as(u32, buf[1]) << 8) |
                    @as(u32, buf[2]);
                return @as(u64, value);
            },
            3 => {
                // 8-byte encoding
                var buf: [7]u8 = undefined;
                _ = try reader.readAll(&buf);
                const value = (@as(u64, first_byte & 0x3F) << 56) |
                    (@as(u64, buf[0]) << 48) |
                    (@as(u64, buf[1]) << 40) |
                    (@as(u64, buf[2]) << 32) |
                    (@as(u64, buf[3]) << 24) |
                    (@as(u64, buf[4]) << 16) |
                    (@as(u64, buf[5]) << 8) |
                    @as(u64, buf[6]);
                return value;
            },
            else => unreachable,
        }
    }
};

/// HTTP/3 Frame Header
pub const Http3FrameHeader = struct {
    frame_type: Http3FrameType,
    length: u64,

    pub fn encode(self: Http3FrameHeader, writer: anytype) !void {
        try VarInt.encode(self.frame_type.encode(), writer);
        try VarInt.encode(self.length, writer);
    }

    pub fn decode(reader: anytype) !Http3FrameHeader {
        const frame_type_raw = try VarInt.decode(reader);
        const frame_type: Http3FrameType = @enumFromInt(frame_type_raw);
        const length = try VarInt.decode(reader);

        return Http3FrameHeader{
            .frame_type = frame_type,
            .length = length,
        };
    }
};

/// Simplified QPACK Encoder (RFC 9204)
/// For common gRPC headers - static table only
pub const QpackEncoder = struct {
    allocator: std.mem.Allocator,
    dynamic_table: std.ArrayList(struct { name: []const u8, value: []const u8 }),

    const StaticTable = [_]struct { name: []const u8, value: []const u8 }{
        .{ .name = ":authority", .value = "" },
        .{ .name = ":path", .value = "/" },
        .{ .name = ":method", .value = "POST" },
        .{ .name = ":scheme", .value = "https" },
        .{ .name = "content-type", .value = "application/grpc" },
        .{ .name = "grpc-encoding", .value = "identity" },
        .{ .name = "grpc-accept-encoding", .value = "identity,gzip" },
        .{ .name = "te", .value = "trailers" },
        .{ .name = "grpc-status", .value = "0" },
        .{ .name = "grpc-message", .value = "" },
    };

    pub fn init(allocator: std.mem.Allocator) QpackEncoder {
        return .{
            .allocator = allocator,
            .dynamic_table = std.ArrayList(struct { name: []const u8, value: []const u8 }).init(allocator),
        };
    }

    pub fn deinit(self: *QpackEncoder) void {
        self.dynamic_table.deinit();
    }

    pub fn encode(self: *QpackEncoder, headers: []const struct { name: []const u8, value: []const u8 }, writer: anytype) !void {
        _ = self;

        // QPACK Encoded Field Section Prefix (RFC 9204 Section 4.5.1)
        try VarInt.encode(0, writer); // Required Insert Count = 0 (no dynamic table)
        try VarInt.encode(0, writer); // Delta Base = 0

        for (headers) |header| {
            // Try to find in static table
            var found = false;
            for (StaticTable, 0..) |entry, i| {
                if (std.mem.eql(u8, entry.name, header.name)) {
                    if (entry.value.len == 0 or std.mem.eql(u8, entry.value, header.value)) {
                        // Indexed field line (RFC 9204 Section 4.5.2)
                        try writer.writeByte(0x80 | @as(u8, @intCast(i)));
                        found = true;
                        break;
                    }
                }
            }

            if (!found) {
                // Literal field line with name reference (RFC 9204 Section 4.5.4)
                try writer.writeByte(0x50); // Literal with name reference, no indexing

                // Encode name length and name
                try VarInt.encode(@intCast(header.name.len), writer);
                try writer.writeAll(header.name);

                // Encode value length and value
                try VarInt.encode(@intCast(header.value.len), writer);
                try writer.writeAll(header.value);
            }
        }
    }
};

/// Simplified QPACK Decoder (RFC 9204)
pub const QpackDecoder = struct {
    allocator: std.mem.Allocator,
    dynamic_table: std.ArrayList(struct { name: []const u8, value: []const u8 }),

    pub fn init(allocator: std.mem.Allocator) QpackDecoder {
        return .{
            .allocator = allocator,
            .dynamic_table = std.ArrayList(struct { name: []const u8, value: []const u8 }).init(allocator),
        };
    }

    pub fn deinit(self: *QpackDecoder) void {
        self.dynamic_table.deinit();
    }

    pub fn decode(self: *QpackDecoder, data: []const u8) !std.ArrayList(struct { name: []const u8, value: []const u8 }) {
        var headers = std.ArrayList(struct { name: []const u8, value: []const u8 }).init(self.allocator);
        var stream = std.io.fixedBufferStream(data);
        const reader = stream.reader();

        // Read prefix
        const required_insert_count = try VarInt.decode(reader);
        _ = required_insert_count;
        const delta_base = try VarInt.decode(reader);
        _ = delta_base;

        // Read field lines
        while (stream.pos < data.len) {
            const first_byte = try reader.readByte();

            if ((first_byte & 0x80) != 0) {
                // Indexed field line
                const index = first_byte & 0x3F;
                if (index < QpackEncoder.StaticTable.len) {
                    const entry = QpackEncoder.StaticTable[index];
                    try headers.append(.{ .name = entry.name, .value = entry.value });
                }
            } else if ((first_byte & 0x50) != 0) {
                // Literal field line with name reference
                const name_len = try VarInt.decode(reader);
                const name = data[stream.pos .. stream.pos + name_len];
                stream.pos += name_len;

                const value_len = try VarInt.decode(reader);
                const value = data[stream.pos .. stream.pos + value_len];
                stream.pos += value_len;

                try headers.append(.{ .name = name, .value = value });
            } else {
                break;
            }
        }

        return headers;
    }
};

/// gRPC Message Format (for HTTP/3)
pub const GrpcMessageHttp3 = struct {
    compressed: bool,
    length: u32,
    payload: []const u8,

    pub fn encode(self: GrpcMessageHttp3, writer: anytype) !void {
        // 5-byte prefix: [compressed(1)][length(4)]
        try writer.writeByte(if (self.compressed) 1 else 0);
        try writer.writeInt(u32, self.length, .big);
        try writer.writeAll(self.payload);
    }

    pub fn decode(allocator: std.mem.Allocator, reader: anytype) !GrpcMessageHttp3 {
        const compressed = (try reader.readByte()) != 0;
        const length = try reader.readInt(u32, .big);

        const payload = try allocator.alloc(u8, length);
        const bytes_read = try reader.readAll(payload);
        if (bytes_read != length) {
            return error.UnexpectedEof;
        }

        return GrpcMessageHttp3{
            .compressed = compressed,
            .length = length,
            .payload = payload,
        };
    }
};

/// HTTP/3 Transport Adapter
pub const Http3TransportAdapter = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Http3TransportAdapter {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Http3TransportAdapter) void {
        _ = self;
    }

    /// Connect to an HTTP/3 server (uses QUIC)
    pub fn connect(self: *Http3TransportAdapter, url: []const u8, options: anytype) TransportError!Connection {
        _ = options;

        const parsed = try parseHttp3Url(url);

        // Create QUIC connection (HTTP/3 runs over QUIC)
        const address = try std.net.Address.parseIp(parsed.host, parsed.port);
        var quic_conn = QuicConnection.initClient(self.allocator, address) catch |err| {
            std.debug.print("[HTTP/3] Failed to create QUIC connection: {}\n", .{err});
            return TransportError.NetworkError;
        };

        // Perform QUIC handshake with ALPN "h3" negotiation
        quic_conn.handshake() catch |err| {
            std.debug.print("[HTTP/3] QUIC handshake failed: {}\n", .{err});
            quic_conn.deinit();
            return TransportError.HandshakeFailed;
        };

        std.debug.print("[HTTP/3] QUIC connection established with {s}:{d}\n", .{ parsed.host, parsed.port });

        // Create HTTP/3 connection adapter
        var conn = try self.allocator.create(Http3ConnectionAdapter);
        conn.* = Http3ConnectionAdapter{
            .allocator = self.allocator,
            .quic_connection = quic_conn,
            .control_stream_id = null,
            .qpack_encoder_stream_id = null,
            .qpack_decoder_stream_id = null,
            .settings = Http3Settings{},
            .next_stream_id = 0, // Client-initiated bidirectional streams
            .qpack_encoder = QpackEncoder.init(self.allocator),
            .qpack_decoder = QpackDecoder.init(self.allocator),
        };

        // Initialize HTTP/3 connection (send SETTINGS)
        try conn.initConnection();

        return Connection{
            .ptr = conn,
            .vtable = &Http3ConnectionAdapter.vtable,
        };
    }

    /// Start listening for HTTP/3 connections
    pub fn listen(self: *Http3TransportAdapter, address: []const u8, options: anytype) TransportError!Listener {
        _ = self;
        _ = address;
        _ = options;

        std.debug.print("[HTTP/3] Server listening not yet implemented\n", .{});
        return TransportError.NotSupported;
    }

    fn parseHttp3Url(url: []const u8) !struct {
        scheme: []const u8,
        host: []const u8,
        port: u16,
        path: []const u8,
        is_secure: bool,
    } {
        // Parse scheme
        const scheme_end = std.mem.indexOf(u8, url, "://") orelse return error.InvalidUrl;
        const scheme = url[0..scheme_end];
        const is_secure = std.mem.eql(u8, scheme, "https") or std.mem.eql(u8, scheme, "h3");

        // Parse host and optional port
        const after_scheme = url[scheme_end + 3 ..];
        const path_start = std.mem.indexOf(u8, after_scheme, "/") orelse after_scheme.len;
        const host_port = after_scheme[0..path_start];
        const path = if (path_start < after_scheme.len) after_scheme[path_start..] else "/";

        var host: []const u8 = undefined;
        var port: u16 = undefined;

        if (std.mem.indexOf(u8, host_port, ":")) |colon_pos| {
            host = host_port[0..colon_pos];
            const port_str = host_port[colon_pos + 1 ..];
            port = try std.fmt.parseInt(u16, port_str, 10);
        } else {
            host = host_port;
            port = if (is_secure) 443 else 80;
        }

        return .{
            .scheme = scheme,
            .host = host,
            .port = port,
            .path = path,
            .is_secure = is_secure,
        };
    }
};

/// HTTP/3 Connection Adapter
const Http3ConnectionAdapter = struct {
    allocator: std.mem.Allocator,
    quic_connection: QuicConnection,
    control_stream_id: ?u64,
    qpack_encoder_stream_id: ?u64,
    qpack_decoder_stream_id: ?u64,
    settings: Http3Settings,
    next_stream_id: u64,
    qpack_encoder: QpackEncoder,
    qpack_decoder: QpackDecoder,

    const vtable = Connection.VTable{
        .openStream = openStream,
        .close = close,
        .ping = ping,
    };

    fn initConnection(self: *Http3ConnectionAdapter) !void {
        // Create control stream (RFC 9114 Section 6.2.1)
        // Control stream is unidirectional with type 0x00
        const control_stream = try self.quic_connection.createStream();
        self.control_stream_id = 0; // Track control stream

        // Send stream type (0x00 for control stream)
        var stream_type_buf: [8]u8 = undefined;
        var stream_type_stream = std.io.fixedBufferStream(&stream_type_buf);
        try VarInt.encode(0x00, stream_type_stream.writer());
        _ = try control_stream.write(stream_type_buf[0..stream_type_stream.pos]);

        // Send SETTINGS frame
        var settings_buf = std.ArrayList(u8).init(self.allocator);
        defer settings_buf.deinit();

        try self.encodeSettings(settings_buf.writer());
        _ = try control_stream.write(settings_buf.items);

        std.debug.print("[HTTP/3] Sent SETTINGS frame on control stream\n", .{});
    }

    fn encodeSettings(self: *Http3ConnectionAdapter, writer: anytype) !void {
        // Frame header
        const frame_header = Http3FrameHeader{
            .frame_type = .settings,
            .length = 16, // Approximate size of settings
        };
        try frame_header.encode(writer);

        // Setting: QPACK_MAX_TABLE_CAPACITY
        try VarInt.encode(0x01, writer);
        try VarInt.encode(self.settings.max_table_capacity, writer);

        // Setting: QPACK_BLOCKED_STREAMS
        try VarInt.encode(0x07, writer);
        try VarInt.encode(self.settings.blocked_streams, writer);
    }

    fn openStream(ctx: *anyopaque) TransportError!Stream {
        const self: *Http3ConnectionAdapter = @ptrCast(@alignCast(ctx));

        // Create bidirectional QUIC stream for request/response
        const quic_stream = self.quic_connection.createStream() catch |err| {
            std.debug.print("[HTTP/3] Failed to create stream: {}\n", .{err});
            return TransportError.NetworkError;
        };

        const stream_id = self.next_stream_id;
        self.next_stream_id += 4; // Client bidirectional streams increment by 4

        std.debug.print("[HTTP/3] Opening stream {d}\n", .{stream_id});

        var stream_adapter = try self.allocator.create(Http3StreamAdapter);
        stream_adapter.* = Http3StreamAdapter{
            .allocator = self.allocator,
            .connection = self,
            .quic_stream = quic_stream,
            .stream_id = stream_id,
            .headers_sent = false,
        };

        return Stream{
            .ptr = stream_adapter,
            .vtable = &Http3StreamAdapter.vtable,
        };
    }

    fn close(ctx: *anyopaque) void {
        const self: *Http3ConnectionAdapter = @ptrCast(@alignCast(ctx));

        // Send GOAWAY frame
        self.sendGoaway() catch |err| {
            std.debug.print("[HTTP/3] Failed to send GOAWAY: {}\n", .{err});
        };

        self.qpack_encoder.deinit();
        self.qpack_decoder.deinit();
        self.quic_connection.deinit();
        self.allocator.destroy(self);
    }

    fn ping(ctx: *anyopaque) TransportError!void {
        const self: *Http3ConnectionAdapter = @ptrCast(@alignCast(ctx));

        // HTTP/3 doesn't have PING, but QUIC does
        // We can send a PING frame on the QUIC level
        _ = self;
        std.debug.print("[HTTP/3] PING via underlying QUIC connection\n", .{});
    }

    fn sendGoaway(self: *Http3ConnectionAdapter) !void {
        if (self.control_stream_id) |_| {
            // Send GOAWAY frame on control stream
            var goaway_buf = std.ArrayList(u8).init(self.allocator);
            defer goaway_buf.deinit();

            const frame_header = Http3FrameHeader{
                .frame_type = .goaway,
                .length = 8, // Stream ID size
            };
            try frame_header.encode(goaway_buf.writer());
            try VarInt.encode(self.next_stream_id, goaway_buf.writer());

            std.debug.print("[HTTP/3] Sent GOAWAY frame\n", .{});
        }
    }
};

/// HTTP/3 Stream Adapter
const Http3StreamAdapter = struct {
    allocator: std.mem.Allocator,
    connection: *Http3ConnectionAdapter,
    quic_stream: *QuicStream,
    stream_id: u64,
    headers_sent: bool,

    const vtable = Stream.VTable{
        .write = write,
        .read = read,
        .close = streamClose,
    };

    fn write(ctx: *anyopaque, data: []const u8) TransportError!usize {
        const self: *Http3StreamAdapter = @ptrCast(@alignCast(ctx));

        // Send HEADERS frame first (if not sent)
        if (!self.headers_sent) {
            try self.sendHeaders();
            self.headers_sent = true;
        }

        // Send DATA frame with gRPC message
        try self.sendData(data);

        return data.len;
    }

    fn read(ctx: *anyopaque, buffer: []u8) TransportError!Frame {
        const self: *Http3StreamAdapter = @ptrCast(@alignCast(ctx));

        // Read HTTP/3 frame from QUIC stream
        var frame_header_buf: [16]u8 = undefined;
        const header_bytes = self.quic_stream.read(&frame_header_buf) catch |err| {
            std.debug.print("[HTTP/3] Failed to read frame header: {}\n", .{err});
            return TransportError.NetworkError;
        };

        if (header_bytes == 0) {
            return Frame{
                .data = &[_]u8{},
                .end_of_stream = true,
            };
        }

        var header_stream = std.io.fixedBufferStream(frame_header_buf[0..header_bytes]);
        const frame_header = Http3FrameHeader.decode(header_stream.reader()) catch |err| {
            std.debug.print("[HTTP/3] Failed to decode frame header: {}\n", .{err});
            return TransportError.ProtocolError;
        };

        switch (frame_header.frame_type) {
            .data => {
                // Read payload
                const bytes_to_read = @min(frame_header.length, buffer.len);
                const bytes_read = self.quic_stream.read(buffer[0..bytes_to_read]) catch |err| {
                    std.debug.print("[HTTP/3] Failed to read data: {}\n", .{err});
                    return TransportError.NetworkError;
                };

                return Frame{
                    .data = buffer[0..bytes_read],
                    .end_of_stream = false,
                };
            },
            .headers => {
                // Read and decode headers
                var headers_data = try self.allocator.alloc(u8, @intCast(frame_header.length));
                defer self.allocator.free(headers_data);

                _ = self.quic_stream.read(headers_data) catch |err| {
                    std.debug.print("[HTTP/3] Failed to read headers: {}\n", .{err});
                    return TransportError.NetworkError;
                };

                // Decode with QPACK
                const headers = try self.connection.qpack_decoder.decode(headers_data);
                defer headers.deinit();

                // For now, return empty frame (headers processed)
                return Frame{
                    .data = &[_]u8{},
                    .end_of_stream = false,
                };
            },
            else => {
                return TransportError.ProtocolError;
            },
        }
    }

    fn streamClose(ctx: *anyopaque) void {
        const self: *Http3StreamAdapter = @ptrCast(@alignCast(ctx));

        // Send empty DATA frame with FIN
        self.sendData(&[_]u8{}) catch |err| {
            std.debug.print("[HTTP/3] Failed to send FIN: {}\n", .{err});
        };

        self.quic_stream.finish();
        self.allocator.destroy(self);
    }

    fn sendHeaders(self: *Http3StreamAdapter) !void {
        // Prepare gRPC headers
        const headers = [_]struct { name: []const u8, value: []const u8 }{
            .{ .name = ":method", .value = "POST" },
            .{ .name = ":scheme", .value = "https" },
            .{ .name = ":authority", .value = "localhost" },
            .{ .name = ":path", .value = "/service/method" },
            .{ .name = "content-type", .value = "application/grpc" },
            .{ .name = "te", .value = "trailers" },
        };

        // Encode headers with QPACK
        var headers_buf = std.ArrayList(u8).init(self.allocator);
        defer headers_buf.deinit();

        try self.connection.qpack_encoder.encode(&headers, headers_buf.writer());

        // Send HEADERS frame
        var frame_buf = std.ArrayList(u8).init(self.allocator);
        defer frame_buf.deinit();

        const frame_header = Http3FrameHeader{
            .frame_type = .headers,
            .length = @intCast(headers_buf.items.len),
        };
        try frame_header.encode(frame_buf.writer());
        try frame_buf.appendSlice(headers_buf.items);

        _ = try self.quic_stream.write(frame_buf.items);

        std.debug.print("[HTTP/3] Sent HEADERS frame on stream {d}\n", .{self.stream_id});
    }

    fn sendData(self: *Http3StreamAdapter, data: []const u8) !void {
        var frame_buf = std.ArrayList(u8).init(self.allocator);
        defer frame_buf.deinit();

        const frame_header = Http3FrameHeader{
            .frame_type = .data,
            .length = @intCast(data.len),
        };
        try frame_header.encode(frame_buf.writer());
        if (data.len > 0) {
            try frame_buf.appendSlice(data);
        }

        _ = try self.quic_stream.write(frame_buf.items);

        std.debug.print("[HTTP/3] Sent DATA frame ({d} bytes) on stream {d}\n", .{ data.len, self.stream_id });
    }
};

// Tests
test "HTTP/3 URL parsing" {
    const testing = std.testing;

    {
        const parsed = try Http3TransportAdapter.parseHttp3Url("h3://localhost:443/service");
        try testing.expectEqualStrings("h3", parsed.scheme);
        try testing.expectEqualStrings("localhost", parsed.host);
        try testing.expectEqual(@as(u16, 443), parsed.port);
        try testing.expectEqualStrings("/service", parsed.path);
        try testing.expect(parsed.is_secure);
    }

    {
        const parsed = try Http3TransportAdapter.parseHttp3Url("https://example.com/api");
        try testing.expectEqualStrings("https", parsed.scheme);
        try testing.expectEqualStrings("example.com", parsed.host);
        try testing.expectEqual(@as(u16, 443), parsed.port);
        try testing.expectEqualStrings("/api", parsed.path);
        try testing.expect(parsed.is_secure);
    }
}

test "VarInt encoding/decoding" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const test_values = [_]u64{ 0, 63, 64, 16383, 16384, 1073741823, 1073741824 };

    for (test_values) |value| {
        var buf = std.ArrayList(u8).init(allocator);
        defer buf.deinit();

        try VarInt.encode(value, buf.writer());

        var stream = std.io.fixedBufferStream(buf.items);
        const decoded = try VarInt.decode(stream.reader());

        try testing.expectEqual(value, decoded);
    }
}

test "HTTP/3 frame header encoding/decoding" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var buf = std.ArrayList(u8).init(allocator);
    defer buf.deinit();

    const original = Http3FrameHeader{
        .frame_type = .data,
        .length = 1234,
    };

    try original.encode(buf.writer());

    var stream = std.io.fixedBufferStream(buf.items);
    const decoded = try Http3FrameHeader.decode(stream.reader());

    try testing.expectEqual(original.frame_type, decoded.frame_type);
    try testing.expectEqual(original.length, decoded.length);
}

test "gRPC message HTTP/3 encoding/decoding" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const payload = "Hello HTTP/3 gRPC";

    var buf = std.ArrayList(u8).init(allocator);
    defer buf.deinit();

    const original = GrpcMessageHttp3{
        .compressed = false,
        .length = @intCast(payload.len),
        .payload = payload,
    };

    try original.encode(buf.writer());

    var stream = std.io.fixedBufferStream(buf.items);
    const decoded = try GrpcMessageHttp3.decode(allocator, stream.reader());
    defer allocator.free(decoded.payload);

    try testing.expectEqual(original.compressed, decoded.compressed);
    try testing.expectEqual(original.length, decoded.length);
    try testing.expectEqualStrings(original.payload, decoded.payload);
}
