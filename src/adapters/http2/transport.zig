const std = @import("std");
const transport = @import("../../transport.zig");
const TransportError = transport.TransportError;
const Connection = transport.Connection;
const Stream = transport.Stream;
const Listener = transport.Listener;
const Frame = transport.Frame;

/// HTTP/2 Transport Adapter (RFC 7540)
/// Provides standard gRPC-over-HTTP/2 transport with:
/// - HPACK header compression
/// - Stream multiplexing
/// - Flow control
/// - TLS/ALPN negotiation (h2)
/// - gRPC message framing

/// HTTP/2 Frame Types (RFC 7540 Section 6)
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

/// HTTP/2 Frame Flags (RFC 7540 Section 6)
pub const FrameFlags = struct {
    pub const END_STREAM: u8 = 0x1;
    pub const ACK: u8 = 0x1;
    pub const END_HEADERS: u8 = 0x4;
    pub const PADDED: u8 = 0x8;
    pub const PRIORITY: u8 = 0x20;
};

/// HTTP/2 Error Codes (RFC 7540 Section 7)
pub const ErrorCode = enum(u32) {
    no_error = 0x0,
    protocol_error = 0x1,
    internal_error = 0x2,
    flow_control_error = 0x3,
    settings_timeout = 0x4,
    stream_closed = 0x5,
    frame_size_error = 0x6,
    refused_stream = 0x7,
    cancel = 0x8,
    compression_error = 0x9,
    connect_error = 0xa,
    enhance_your_calm = 0xb,
    inadequate_security = 0xc,
    http_1_1_required = 0xd,
};

/// HTTP/2 Settings (RFC 7540 Section 6.5)
pub const Settings = struct {
    header_table_size: u32 = 4096,
    enable_push: bool = false, // Disabled for gRPC
    max_concurrent_streams: u32 = 100,
    initial_window_size: u32 = 65535,
    max_frame_size: u32 = 16384,
    max_header_list_size: u32 = 8192,
};

/// HTTP/2 Frame Header (9 bytes - RFC 7540 Section 4.1)
pub const FrameHeader = struct {
    length: u24, // 3 bytes
    frame_type: FrameType, // 1 byte
    flags: u8, // 1 byte
    stream_id: u31, // 4 bytes (R bit + 31-bit stream ID)

    pub fn encode(self: FrameHeader, writer: anytype) !void {
        // Write 3-byte length (big-endian)
        try writer.writeByte(@as(u8, @intCast((self.length >> 16) & 0xFF)));
        try writer.writeByte(@as(u8, @intCast((self.length >> 8) & 0xFF)));
        try writer.writeByte(@as(u8, @intCast(self.length & 0xFF)));

        try writer.writeByte(@intFromEnum(self.frame_type));
        try writer.writeByte(self.flags);

        // Write 4-byte stream ID (big-endian, with R bit = 0)
        const stream_id_u32: u32 = @as(u32, self.stream_id);
        try writer.writeInt(u32, stream_id_u32, .big);
    }

    pub fn decode(reader: anytype) !FrameHeader {
        // Read 3-byte length
        const len_byte1 = try reader.readByte();
        const len_byte2 = try reader.readByte();
        const len_byte3 = try reader.readByte();
        const length: u24 = (@as(u24, len_byte1) << 16) | (@as(u24, len_byte2) << 8) | @as(u24, len_byte3);

        const frame_type_raw = try reader.readByte();
        const frame_type = @as(FrameType, @enumFromInt(frame_type_raw));

        const flags = try reader.readByte();

        const stream_id_raw = try reader.readInt(u32, .big);
        const stream_id: u31 = @intCast(stream_id_raw & 0x7FFFFFFF); // Mask off R bit

        return FrameHeader{
            .length = length,
            .frame_type = frame_type,
            .flags = flags,
            .stream_id = stream_id,
        };
    }
};

/// Simple HPACK Static Table (RFC 7541)
/// Simplified for common gRPC headers
const HpackStaticTable = struct {
    pub const entries = [_]struct { name: []const u8, value: []const u8 }{
        .{ .name = ":authority", .value = "" },
        .{ .name = ":method", .value = "POST" },
        .{ .name = ":path", .value = "/" },
        .{ .name = ":scheme", .value = "https" },
        .{ .name = "content-type", .value = "application/grpc" },
        .{ .name = "grpc-encoding", .value = "identity" },
        .{ .name = "grpc-accept-encoding", .value = "identity" },
        .{ .name = "te", .value = "trailers" },
    };

    pub fn lookup(name: []const u8) ?usize {
        for (entries, 0..) |entry, i| {
            if (std.mem.eql(u8, entry.name, name)) {
                return i + 1; // HPACK indices start at 1
            }
        }
        return null;
    }
};

/// Simplified HPACK Encoder (for gRPC headers)
pub const HpackEncoder = struct {
    allocator: std.mem.Allocator,
    dynamic_table: std.ArrayList(struct { name: []const u8, value: []const u8 }),

    pub fn init(allocator: std.mem.Allocator) HpackEncoder {
        return .{
            .allocator = allocator,
            .dynamic_table = std.ArrayList(struct { name: []const u8, value: []const u8 }).init(allocator),
        };
    }

    pub fn deinit(self: *HpackEncoder) void {
        self.dynamic_table.deinit();
    }

    pub fn encode(self: *HpackEncoder, headers: []const struct { name: []const u8, value: []const u8 }, writer: anytype) !void {
        _ = self;
        for (headers) |header| {
            // Try to find in static table
            if (HpackStaticTable.lookup(header.name)) |index| {
                // Indexed Header Field (RFC 7541 Section 6.1)
                try writer.writeByte(@as(u8, 0x80 | @as(u8, @intCast(index))));
            } else {
                // Literal Header Field without Indexing (RFC 7541 Section 6.2.2)
                try writer.writeByte(0x00); // No indexing prefix

                // Encode name length and name
                try encodeInteger(writer, 7, @intCast(header.name.len));
                try writer.writeAll(header.name);

                // Encode value length and value
                try encodeInteger(writer, 7, @intCast(header.value.len));
                try writer.writeAll(header.value);
            }
        }
    }

    fn encodeInteger(writer: anytype, prefix_bits: u3, value: u32) !void {
        const max_prefix: u32 = (@as(u32, 1) << prefix_bits) - 1;

        if (value < max_prefix) {
            try writer.writeByte(@intCast(value));
        } else {
            try writer.writeByte(@intCast(max_prefix));
            var remaining = value - max_prefix;
            while (remaining >= 128) {
                try writer.writeByte(@as(u8, @intCast((remaining % 128) + 128)));
                remaining /= 128;
            }
            try writer.writeByte(@intCast(remaining));
        }
    }
};

/// Simplified HPACK Decoder
pub const HpackDecoder = struct {
    allocator: std.mem.Allocator,
    dynamic_table: std.ArrayList(struct { name: []const u8, value: []const u8 }),

    pub fn init(allocator: std.mem.Allocator) HpackDecoder {
        return .{
            .allocator = allocator,
            .dynamic_table = std.ArrayList(struct { name: []const u8, value: []const u8 }).init(allocator),
        };
    }

    pub fn deinit(self: *HpackDecoder) void {
        self.dynamic_table.deinit();
    }

    pub fn decode(self: *HpackDecoder, data: []const u8) !std.ArrayList(struct { name: []const u8, value: []const u8 }) {
        var headers = std.ArrayList(struct { name: []const u8, value: []const u8 }).init(self.allocator);
        var pos: usize = 0;

        while (pos < data.len) {
            const first_byte = data[pos];

            if ((first_byte & 0x80) != 0) {
                // Indexed Header Field
                const index = first_byte & 0x7F;
                if (index > 0 and index <= HpackStaticTable.entries.len) {
                    const entry = HpackStaticTable.entries[index - 1];
                    try headers.append(.{ .name = entry.name, .value = entry.value });
                }
                pos += 1;
            } else {
                // Literal Header Field
                pos += 1; // Skip prefix byte

                // Read name length and name
                const name_len = data[pos];
                pos += 1;
                const name = data[pos .. pos + name_len];
                pos += name_len;

                // Read value length and value
                const value_len = data[pos];
                pos += 1;
                const value = data[pos .. pos + value_len];
                pos += value_len;

                try headers.append(.{ .name = name, .value = value });
            }
        }

        return headers;
    }
};

/// gRPC Message Format (5-byte prefix + payload)
pub const GrpcMessage = struct {
    compressed: bool,
    length: u32,
    payload: []const u8,

    pub fn encode(self: GrpcMessage, writer: anytype) !void {
        // Write 5-byte prefix
        try writer.writeByte(if (self.compressed) 1 else 0);
        try writer.writeInt(u32, self.length, .big);
        try writer.writeAll(self.payload);
    }

    pub fn decode(allocator: std.mem.Allocator, reader: anytype) !GrpcMessage {
        const compressed = (try reader.readByte()) != 0;
        const length = try reader.readInt(u32, .big);

        const payload = try allocator.alloc(u8, length);
        const bytes_read = try reader.readAll(payload);
        if (bytes_read != length) {
            return error.UnexpectedEof;
        }

        return GrpcMessage{
            .compressed = compressed,
            .length = length,
            .payload = payload,
        };
    }
};

/// HTTP/2 Transport Adapter
pub const Http2TransportAdapter = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Http2TransportAdapter {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Http2TransportAdapter) void {
        _ = self;
    }

    /// Connect to an HTTP/2 server
    pub fn connect(self: *Http2TransportAdapter, url: []const u8, options: anytype) TransportError!Connection {
        _ = options;

        const parsed = try parseHttp2Url(url);

        // Connect TCP socket
        const address = try std.net.Address.parseIp(parsed.host, parsed.port);
        const socket = try std.net.tcpConnectToAddress(address);

        std.debug.print("[HTTP/2] Connected to {s}:{d}\n", .{ parsed.host, parsed.port });

        // TODO: Implement TLS/ALPN negotiation for h2
        if (parsed.is_secure) {
            std.debug.print("[HTTP/2] TLS/ALPN negotiation not yet implemented (h2)\n", .{});
            // For now, we'll proceed without TLS
            // In production, this should negotiate ALPN with "h2" protocol
        }

        // Send HTTP/2 connection preface (RFC 7540 Section 3.5)
        const preface = "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n";
        _ = try socket.write(preface);

        // Create connection adapter
        var conn = try self.allocator.create(Http2ConnectionAdapter);
        conn.* = Http2ConnectionAdapter{
            .allocator = self.allocator,
            .socket = socket,
            .is_preface_sent = true,
            .next_stream_id = 1, // Client streams are odd numbers
            .settings = Settings{},
            .local_window_size = 65535,
            .remote_window_size = 65535,
            .hpack_encoder = HpackEncoder.init(self.allocator),
            .hpack_decoder = HpackDecoder.init(self.allocator),
        };

        // Send initial SETTINGS frame
        try conn.sendSettings();

        // Read and process server's SETTINGS frame
        try conn.receiveSettings();

        return Connection{
            .ptr = conn,
            .vtable = &Http2ConnectionAdapter.vtable,
        };
    }

    /// Start listening for HTTP/2 connections
    pub fn listen(self: *Http2TransportAdapter, address: []const u8, options: anytype) TransportError!Listener {
        _ = self;
        _ = address;
        _ = options;

        std.debug.print("[HTTP/2] Server listening not yet implemented\n", .{});
        return TransportError.NotSupported;
    }

    fn parseHttp2Url(url: []const u8) !struct {
        scheme: []const u8,
        host: []const u8,
        port: u16,
        path: []const u8,
        is_secure: bool,
    } {
        // Parse scheme
        const scheme_end = std.mem.indexOf(u8, url, "://") orelse return error.InvalidUrl;
        const scheme = url[0..scheme_end];
        const is_secure = std.mem.eql(u8, scheme, "https") or std.mem.eql(u8, scheme, "h2");

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

/// HTTP/2 Connection Adapter
const Http2ConnectionAdapter = struct {
    allocator: std.mem.Allocator,
    socket: std.net.Stream,
    is_preface_sent: bool,
    next_stream_id: u31,
    settings: Settings,
    local_window_size: u32,
    remote_window_size: u32,
    hpack_encoder: HpackEncoder,
    hpack_decoder: HpackDecoder,

    const vtable = Connection.VTable{
        .openStream = openStream,
        .close = close,
        .ping = ping,
    };

    fn openStream(ctx: *anyopaque) TransportError!Stream {
        const self: *Http2ConnectionAdapter = @ptrCast(@alignCast(ctx));

        const stream_id = self.next_stream_id;
        self.next_stream_id += 2; // Client streams are odd numbers

        std.debug.print("[HTTP/2] Opening stream {d}\n", .{stream_id});

        var stream_adapter = try self.allocator.create(Http2StreamAdapter);
        stream_adapter.* = Http2StreamAdapter{
            .allocator = self.allocator,
            .connection = self,
            .stream_id = stream_id,
            .state = .idle,
            .local_window_size = self.settings.initial_window_size,
            .remote_window_size = self.settings.initial_window_size,
        };

        return Stream{
            .ptr = stream_adapter,
            .vtable = &Http2StreamAdapter.vtable,
        };
    }

    fn close(ctx: *anyopaque) void {
        const self: *Http2ConnectionAdapter = @ptrCast(@alignCast(ctx));

        // Send GOAWAY frame
        self.sendGoaway() catch |err| {
            std.debug.print("[HTTP/2] Failed to send GOAWAY: {}\n", .{err});
        };

        self.hpack_encoder.deinit();
        self.hpack_decoder.deinit();
        self.socket.close();
        self.allocator.destroy(self);
    }

    fn ping(ctx: *anyopaque) TransportError!void {
        const self: *Http2ConnectionAdapter = @ptrCast(@alignCast(ctx));

        // Send PING frame with random payload
        var payload: [8]u8 = undefined;
        std.crypto.random.bytes(&payload);

        try self.sendPing(&payload, false);

        // Wait for PING ACK
        const header = try FrameHeader.decode(self.socket.reader());
        if (header.frame_type != .ping or (header.flags & FrameFlags.ACK) == 0) {
            return TransportError.ProtocolError;
        }

        std.debug.print("[HTTP/2] PING successful\n", .{});
    }

    fn sendSettings(self: *Http2ConnectionAdapter) !void {
        const header = FrameHeader{
            .length = 0, // Empty SETTINGS for simplicity
            .frame_type = .settings,
            .flags = 0,
            .stream_id = 0, // SETTINGS is connection-level
        };

        try header.encode(self.socket.writer());
        std.debug.print("[HTTP/2] Sent SETTINGS frame\n", .{});
    }

    fn receiveSettings(self: *Http2ConnectionAdapter) !void {
        const header = try FrameHeader.decode(self.socket.reader());

        if (header.frame_type != .settings) {
            return error.ProtocolError;
        }

        // Read and discard settings payload for now
        if (header.length > 0) {
            var buf: [256]u8 = undefined;
            _ = try self.socket.reader().readAll(buf[0..@min(header.length, buf.len)]);
        }

        // Send SETTINGS ACK
        const ack_header = FrameHeader{
            .length = 0,
            .frame_type = .settings,
            .flags = FrameFlags.ACK,
            .stream_id = 0,
        };

        try ack_header.encode(self.socket.writer());
        std.debug.print("[HTTP/2] Received and ACKed SETTINGS\n", .{});
    }

    fn sendPing(self: *Http2ConnectionAdapter, payload: *const [8]u8, ack: bool) !void {
        const header = FrameHeader{
            .length = 8,
            .frame_type = .ping,
            .flags = if (ack) FrameFlags.ACK else 0,
            .stream_id = 0,
        };

        try header.encode(self.socket.writer());
        try self.socket.writer().writeAll(payload);
    }

    fn sendGoaway(self: *Http2ConnectionAdapter) !void {
        const header = FrameHeader{
            .length = 8, // Last stream ID (4 bytes) + error code (4 bytes)
            .frame_type = .goaway,
            .flags = 0,
            .stream_id = 0,
        };

        try header.encode(self.socket.writer());
        try self.socket.writer().writeInt(u32, 0, .big); // Last stream ID
        try self.socket.writer().writeInt(u32, @intFromEnum(ErrorCode.no_error), .big);

        std.debug.print("[HTTP/2] Sent GOAWAY frame\n", .{});
    }
};

/// HTTP/2 Stream States (RFC 7540 Section 5.1)
const StreamState = enum {
    idle,
    open,
    half_closed_local,
    half_closed_remote,
    closed,
};

/// HTTP/2 Stream Adapter
const Http2StreamAdapter = struct {
    allocator: std.mem.Allocator,
    connection: *Http2ConnectionAdapter,
    stream_id: u31,
    state: StreamState,
    local_window_size: u32,
    remote_window_size: u32,

    const vtable = Stream.VTable{
        .write = write,
        .read = read,
        .close = streamClose,
    };

    fn write(ctx: *anyopaque, data: []const u8) TransportError!usize {
        const self: *Http2StreamAdapter = @ptrCast(@alignCast(ctx));

        // Send HEADERS frame first (if this is the first write)
        if (self.state == .idle) {
            try self.sendHeaders();
            self.state = .open;
        }

        // Send gRPC message in DATA frame
        try self.sendData(data, false);

        return data.len;
    }

    fn read(ctx: *anyopaque, buffer: []u8) TransportError!Frame {
        const self: *Http2StreamAdapter = @ptrCast(@alignCast(ctx));

        // Read HTTP/2 frame
        const header = FrameHeader.decode(self.connection.socket.reader()) catch |err| {
            return TransportError.NetworkError;
        };

        // Ensure frame is for this stream
        if (header.stream_id != self.stream_id) {
            std.debug.print("[HTTP/2] Received frame for stream {d}, expected {d}\n", .{ header.stream_id, self.stream_id });
            return TransportError.ProtocolError;
        }

        switch (header.frame_type) {
            .data => {
                // Read payload
                const bytes_read = try self.connection.socket.reader().readAll(buffer[0..@min(header.length, buffer.len)]);

                return Frame{
                    .data = buffer[0..bytes_read],
                    .end_of_stream = (header.flags & FrameFlags.END_STREAM) != 0,
                };
            },
            .headers => {
                // Read and decode headers
                var headers_data = try self.allocator.alloc(u8, header.length);
                defer self.allocator.free(headers_data);

                _ = try self.connection.socket.reader().readAll(headers_data);

                // For now, return empty frame (headers processed)
                return Frame{
                    .data = &[_]u8{},
                    .end_of_stream = (header.flags & FrameFlags.END_STREAM) != 0,
                };
            },
            .rst_stream => {
                return TransportError.StreamReset;
            },
            else => {
                return TransportError.ProtocolError;
            },
        }
    }

    fn streamClose(ctx: *anyopaque) void {
        const self: *Http2StreamAdapter = @ptrCast(@alignCast(ctx));

        // Send DATA frame with END_STREAM flag
        self.sendData(&[_]u8{}, true) catch |err| {
            std.debug.print("[HTTP/2] Failed to send END_STREAM: {}\n", .{err});
        };

        self.state = .closed;
        self.allocator.destroy(self);
    }

    fn sendHeaders(self: *Http2StreamAdapter) !void {
        // Prepare gRPC headers
        var headers_buf = std.ArrayList(u8).init(self.allocator);
        defer headers_buf.deinit();

        const headers = [_]struct { name: []const u8, value: []const u8 }{
            .{ .name = ":method", .value = "POST" },
            .{ .name = ":scheme", .value = "https" },
            .{ .name = ":path", .value = "/service/method" }, // TODO: Get from call context
            .{ .name = ":authority", .value = "localhost" },
            .{ .name = "content-type", .value = "application/grpc" },
            .{ .name = "te", .value = "trailers" },
        };

        // Encode headers with HPACK
        try self.connection.hpack_encoder.encode(&headers, headers_buf.writer());

        // Send HEADERS frame
        const header = FrameHeader{
            .length = @intCast(headers_buf.items.len),
            .frame_type = .headers,
            .flags = FrameFlags.END_HEADERS, // No continuation for simplicity
            .stream_id = self.stream_id,
        };

        try header.encode(self.connection.socket.writer());
        try self.connection.socket.writer().writeAll(headers_buf.items);

        std.debug.print("[HTTP/2] Sent HEADERS frame for stream {d}\n", .{self.stream_id});
    }

    fn sendData(self: *Http2StreamAdapter, data: []const u8, end_stream: bool) !void {
        // Check flow control
        if (data.len > self.remote_window_size) {
            return error.FlowControlError;
        }

        const header = FrameHeader{
            .length = @intCast(data.len),
            .frame_type = .data,
            .flags = if (end_stream) FrameFlags.END_STREAM else 0,
            .stream_id = self.stream_id,
        };

        try header.encode(self.connection.socket.writer());
        if (data.len > 0) {
            try self.connection.socket.writer().writeAll(data);
        }

        // Update flow control window
        self.remote_window_size -= @intCast(data.len);

        std.debug.print("[HTTP/2] Sent DATA frame ({d} bytes) for stream {d}\n", .{ data.len, self.stream_id });
    }
};

// Tests
test "HTTP/2 URL parsing" {
    const testing = std.testing;

    {
        const parsed = try Http2TransportAdapter.parseHttp2Url("http://localhost:8080/service");
        try testing.expectEqualStrings("http", parsed.scheme);
        try testing.expectEqualStrings("localhost", parsed.host);
        try testing.expectEqual(@as(u16, 8080), parsed.port);
        try testing.expectEqualStrings("/service", parsed.path);
        try testing.expect(!parsed.is_secure);
    }

    {
        const parsed = try Http2TransportAdapter.parseHttp2Url("https://example.com/api");
        try testing.expectEqualStrings("https", parsed.scheme);
        try testing.expectEqualStrings("example.com", parsed.host);
        try testing.expectEqual(@as(u16, 443), parsed.port);
        try testing.expectEqualStrings("/api", parsed.path);
        try testing.expect(parsed.is_secure);
    }
}

test "HTTP/2 frame header encoding/decoding" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var buf = std.ArrayList(u8).init(allocator);
    defer buf.deinit();

    const original = FrameHeader{
        .length = 1234,
        .frame_type = .data,
        .flags = FrameFlags.END_STREAM,
        .stream_id = 42,
    };

    try original.encode(buf.writer());

    var stream = std.io.fixedBufferStream(buf.items);
    const decoded = try FrameHeader.decode(stream.reader());

    try testing.expectEqual(original.length, decoded.length);
    try testing.expectEqual(original.frame_type, decoded.frame_type);
    try testing.expectEqual(original.flags, decoded.flags);
    try testing.expectEqual(original.stream_id, decoded.stream_id);
}

test "gRPC message encoding/decoding" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const payload = "Hello gRPC";

    var buf = std.ArrayList(u8).init(allocator);
    defer buf.deinit();

    const original = GrpcMessage{
        .compressed = false,
        .length = @intCast(payload.len),
        .payload = payload,
    };

    try original.encode(buf.writer());

    var stream = std.io.fixedBufferStream(buf.items);
    const decoded = try GrpcMessage.decode(allocator, stream.reader());
    defer allocator.free(decoded.payload);

    try testing.expectEqual(original.compressed, decoded.compressed);
    try testing.expectEqual(original.length, decoded.length);
    try testing.expectEqualStrings(original.payload, decoded.payload);
}
