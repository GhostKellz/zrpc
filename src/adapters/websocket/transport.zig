//! WebSocket transport adapter for zrpc
//! Implements RFC 6455 - The WebSocket Protocol
//!
//! This adapter enables zRPC to work over WebSocket connections,
//! essential for:
//! - Rune MCP servers (Model Context Protocol)
//! - Browser clients (web-based AI tools)
//! - Firewall-friendly deployments
//! - Real-time dashboards

const std = @import("std");
const zrpc_core = @import("zrpc-core");
const transport_interface = zrpc_core.transport;
const Error = zrpc_core.Error;
// Metrics and tracing will be integrated later
// const metrics = @import("../metrics.zig");
// const tracing = @import("../tracing.zig");

const Transport = transport_interface.Transport;
const Connection = transport_interface.Connection;
const Stream = transport_interface.Stream;
const Frame = transport_interface.Frame;
const FrameType = transport_interface.FrameType;
const TransportError = transport_interface.TransportError;
const TlsConfig = transport_interface.TlsConfig;
const Listener = transport_interface.Listener;

// Stub types until metrics/tracing are integrated
const MetricsRegistry = opaque {};
const Tracer = opaque {};
const Span = opaque {};
const SpanContext = opaque {};

// WebSocket protocol constants (RFC 6455)
const WS_MAGIC_STRING = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";
const WS_VERSION = "13";

/// WebSocket frame opcodes
const Opcode = enum(u8) {
    continuation = 0x0,
    text = 0x1,
    binary = 0x2,
    close = 0x8,
    ping = 0x9,
    pong = 0xA,
    _,
};

/// WebSocket frame flags
const FrameFlags = packed struct {
    opcode: u4,
    rsv3: bool = false,
    rsv2: bool = false,
    rsv1: bool = false,
    fin: bool = false,
};

/// WebSocket frame header
const WsFrameHeader = struct {
    fin: bool,
    rsv1: bool = false,
    rsv2: bool = false,
    rsv3: bool = false,
    opcode: Opcode,
    masked: bool,
    payload_len: u64,
    mask_key: ?[4]u8 = null,
};

pub const WebSocketTransportAdapter = struct {
    allocator: std.mem.Allocator,
    metrics_registry: ?*MetricsRegistry,
    tracer: ?*Tracer,

    pub fn init(allocator: std.mem.Allocator) WebSocketTransportAdapter {
        return WebSocketTransportAdapter{
            .allocator = allocator,
            .metrics_registry = null,
            .tracer = null,
        };
    }

    pub fn initWithMetrics(allocator: std.mem.Allocator, metrics_registry: *MetricsRegistry) WebSocketTransportAdapter {
        return WebSocketTransportAdapter{
            .allocator = allocator,
            .metrics_registry = metrics_registry,
            .tracer = null,
        };
    }

    pub fn initWithObservability(
        allocator: std.mem.Allocator,
        metrics_registry: ?*MetricsRegistry,
        tracer: ?*Tracer,
    ) WebSocketTransportAdapter {
        return WebSocketTransportAdapter{
            .allocator = allocator,
            .metrics_registry = metrics_registry,
            .tracer = tracer,
        };
    }

    pub fn deinit(self: *WebSocketTransportAdapter) void {
        _ = self;
    }

    pub fn connect(
        self: *WebSocketTransportAdapter,
        allocator: std.mem.Allocator,
        endpoint: []const u8,
        tls_config: ?*const TlsConfig,
    ) TransportError!Connection {
        // Parse WebSocket URL (ws:// or wss://)
        const parsed = self.parseWebSocketUrl(endpoint) catch return TransportError.InvalidArgument;

        std.log.info("WebSocket: Connecting to {s}://{s}:{d}{s}", .{
            parsed.scheme,
            parsed.host,
            parsed.port,
            parsed.path,
        });

        // Establish TCP connection
        const address = std.net.Address.resolveIp(parsed.host, parsed.port) catch
            return TransportError.InvalidArgument;

        const tcp_conn = std.net.tcpConnectToAddress(address) catch |err| {
            std.log.err("WebSocket: TCP connection failed: {}", .{err});
            return TransportError.ConnectionReset;
        };

        // Create adapter connection
        const adapter_conn = try allocator.create(WebSocketConnectionAdapter);
        adapter_conn.* = WebSocketConnectionAdapter{
            .socket = tcp_conn,
            .allocator = allocator,
            .streams = std.AutoHashMap(u64, *WebSocketStreamAdapter).init(allocator),
            .next_stream_id = 0,
            .is_client = true,
            .is_upgraded = false,
            .endpoint = try allocator.dupe(u8, endpoint),
            .use_tls = parsed.is_secure,
            .metrics_registry = self.metrics_registry,
            .tracer = self.tracer,
            .connection_span = null,
        };

        // Record connection metrics
        if (self.metrics_registry) |registry| {
            registry.recordTransportConnect();
        }

        // Start connection span (disabled until tracing integration)
        // if (self.tracer) |t| {
        //     const span = try t.startSpan("websocket.connect", .client);
        //     try span.setAttribute("transport.protocol", .{ .string = "websocket" });
        //     try span.setAttribute("net.peer.name", .{ .string = parsed.host });
        //     try span.setAttribute("net.peer.port", .{ .int = parsed.port });
        //     adapter_conn.connection_span = span;
        // }
        _ = self.tracer;
        adapter_conn.connection_span = null;

        // Perform WebSocket handshake
        adapter_conn.performHandshake(parsed.host, parsed.path) catch |err| {
            std.log.err("WebSocket: Handshake failed: {}", .{err});
            adapter_conn.socket.close();
            allocator.destroy(adapter_conn);
            return TransportError.Protocol;
        };

        std.log.info("WebSocket: Connection established and upgraded");

        // TODO: Handle TLS if wss://
        if (tls_config) |_| {
            if (parsed.is_secure) {
                std.log.warn("WebSocket: TLS (wss://) not yet implemented, using ws://");
            }
        }

        return Connection{
            .ptr = adapter_conn,
            .vtable = &WebSocketConnectionAdapter.vtable,
        };
    }

    pub fn listen(
        self: *WebSocketTransportAdapter,
        allocator: std.mem.Allocator,
        bind_address: []const u8,
        tls_config: ?*const TlsConfig,
    ) TransportError!Listener {
        _ = tls_config;

        // Parse bind address
        const parsed = self.parseEndpoint(bind_address) catch return TransportError.InvalidArgument;
        const address = std.net.Address.initIp4([4]u8{ 127, 0, 0, 1 }, parsed.port);

        // Create listener
        const adapter_listener = try allocator.create(WebSocketListenerAdapter);
        adapter_listener.* = WebSocketListenerAdapter{
            .bind_address = address,
            .allocator = allocator,
            .is_listening = false,
        };

        return Listener{
            .ptr = adapter_listener,
            .vtable = &WebSocketListenerAdapter.vtable,
        };
    }

    fn parseWebSocketUrl(self: *WebSocketTransportAdapter, url: []const u8) !struct {
        scheme: []const u8,
        host: []const u8,
        port: u16,
        path: []const u8,
        is_secure: bool,
    } {
        _ = self;

        // Parse ws://host:port/path or wss://host:port/path
        var is_secure = false;
        var remaining = url;

        if (std.mem.startsWith(u8, url, "wss://")) {
            is_secure = true;
            remaining = url[6..];
        } else if (std.mem.startsWith(u8, url, "ws://")) {
            remaining = url[5..];
        } else {
            return error.InvalidUrl;
        }

        // Find path separator
        const path_start = std.mem.indexOfScalar(u8, remaining, '/') orelse remaining.len;
        const host_port = remaining[0..path_start];
        const path = if (path_start < remaining.len) remaining[path_start..] else "/";

        // Parse host:port
        const colon_pos = std.mem.lastIndexOfScalar(u8, host_port, ':');
        const host = if (colon_pos) |pos| host_port[0..pos] else host_port;
        const default_port: u16 = if (is_secure) 443 else 80;
        const port = if (colon_pos) |pos|
            std.fmt.parseInt(u16, host_port[pos + 1 ..], 10) catch default_port
        else
            default_port;

        return .{
            .scheme = if (is_secure) "wss" else "ws",
            .host = host,
            .port = port,
            .path = path,
            .is_secure = is_secure,
        };
    }

    fn parseEndpoint(self: *WebSocketTransportAdapter, endpoint: []const u8) !struct { host: []const u8, port: u16 } {
        _ = self;

        const colon_pos = std.mem.lastIndexOfScalar(u8, endpoint, ':') orelse return error.InvalidEndpoint;
        const host = endpoint[0..colon_pos];
        const port_str = endpoint[colon_pos + 1 ..];
        const port = std.fmt.parseInt(u16, port_str, 10) catch return error.InvalidEndpoint;

        return .{ .host = host, .port = port };
    }
};

const WebSocketConnectionAdapter = struct {
    socket: std.net.Stream,
    allocator: std.mem.Allocator,
    streams: std.AutoHashMap(u64, *WebSocketStreamAdapter),
    next_stream_id: u64,
    is_client: bool,
    is_upgraded: bool,
    endpoint: []const u8,
    use_tls: bool,
    metrics_registry: ?*MetricsRegistry,
    tracer: ?*Tracer,
    connection_span: ?*Span,

    fn performHandshake(self: *WebSocketConnectionAdapter, host: []const u8, path: []const u8) !void {
        if (!self.is_client) return error.ServerHandshakeNotImplemented;

        // Generate random WebSocket key (16 bytes base64 encoded)
        var key_bytes: [16]u8 = undefined;
        std.crypto.random.bytes(&key_bytes);

        var key_base64: [24]u8 = undefined;
        const key_encoded = std.base64.standard.Encoder.encode(&key_base64, &key_bytes);

        // Build HTTP upgrade request
        var request: std.ArrayList(u8) = .empty;
        defer request.deinit(self.allocator);

        try request.writer().print(
            "GET {s} HTTP/1.1\r\n" ++
                "Host: {s}\r\n" ++
                "Upgrade: websocket\r\n" ++
                "Connection: Upgrade\r\n" ++
                "Sec-WebSocket-Key: {s}\r\n" ++
                "Sec-WebSocket-Version: {s}\r\n" ++
                "\r\n",
            .{ path, host, key_encoded, WS_VERSION },
        );

        // Send handshake
        _ = try self.socket.write(request.items);

        // Read and validate response
        var response_buf: [4096]u8 = undefined;
        const bytes_read = try self.socket.read(&response_buf);
        const response = response_buf[0..bytes_read];

        // Validate HTTP 101 Switching Protocols
        if (!std.mem.startsWith(u8, response, "HTTP/1.1 101")) {
            std.log.err("WebSocket: Invalid handshake response: {s}", .{response[0..@min(100, response.len)]});
            return error.HandshakeFailed;
        }

        // Validate Sec-WebSocket-Accept header
        // Expected = base64(SHA1(key + magic_string))
        var hasher = std.crypto.hash.Sha1.init(.{});
        hasher.update(key_encoded);
        hasher.update(WS_MAGIC_STRING);
        var accept_hash: [20]u8 = undefined;
        hasher.final(&accept_hash);

        var expected_accept: [28]u8 = undefined;
        const expected = std.base64.standard.Encoder.encode(&expected_accept, &accept_hash);

        // Check if response contains our expected accept value
        var found_accept = false;
        var line_iter = std.mem.split(u8, response, "\r\n");
        while (line_iter.next()) |line| {
            if (std.mem.startsWith(u8, line, "Sec-WebSocket-Accept:")) {
                const value = std.mem.trim(u8, line[21..], " ");
                if (std.mem.eql(u8, value, expected)) {
                    found_accept = true;
                    break;
                }
            }
        }

        if (!found_accept) {
            std.log.err("WebSocket: Invalid Sec-WebSocket-Accept header", .{});
            return error.HandshakeFailed;
        }

        self.is_upgraded = true;
        std.log.info("WebSocket: Handshake successful", .{});

        // Add handshake event to span (disabled until tracing integration)
        // if (self.connection_span) |span| {
        //     span.addEvent("handshake.completed", &[_]tracing.Attribute{}) catch {};
        // }
        _ = self.connection_span;
    }

    fn openStream(ptr: *anyopaque) TransportError!Stream {
        const self: *WebSocketConnectionAdapter = @ptrCast(@alignCast(ptr));

        if (!self.is_upgraded) {
            return TransportError.Protocol;
        }

        std.log.debug("WebSocket: Creating new stream {d}", .{self.next_stream_id});

        // Create stream adapter
        const adapter_stream = try self.allocator.create(WebSocketStreamAdapter);
        adapter_stream.* = WebSocketStreamAdapter{
            .connection = self,
            .allocator = self.allocator,
            .stream_id = self.next_stream_id,
            .frame_buffer = .empty,
            .stream_span = null,
        };

        // Track the stream
        try self.streams.put(self.next_stream_id, adapter_stream);
        self.next_stream_id += 1;

        // Record stream metrics
        if (self.metrics_registry) |registry| {
            registry.recordStreamOpen();
        }

        // Create child span for stream (disabled until tracing integration)
        // if (self.connection_span) |parent_span| {
        //     if (self.tracer) |t| {
        //         const span = try t.startChildSpan("websocket.stream", .client, parent_span.context);
        //         try span.setAttribute("stream.id", .{ .int = @intCast(adapter_stream.stream_id) });
        //         adapter_stream.stream_span = span;
        //     }
        // }
        adapter_stream.stream_span = null;

        std.log.debug("WebSocket: Stream {d} created successfully", .{adapter_stream.stream_id});

        return Stream{
            .ptr = adapter_stream,
            .vtable = &WebSocketStreamAdapter.vtable,
        };
    }

    fn close(ptr: *anyopaque) void {
        const self: *WebSocketConnectionAdapter = @ptrCast(@alignCast(ptr));

        // Send WebSocket close frame
        const close_frame = [_]u8{ 0x88, 0x00 }; // FIN + Close opcode, no payload
        _ = self.socket.write(&close_frame) catch {};

        // Record disconnection metrics
        if (self.metrics_registry) |registry| {
            registry.recordTransportDisconnect();
        }

        // End connection span
        if (self.connection_span) |span| {
            span.setStatus(.ok, null) catch {};
            if (self.tracer) |t| {
                t.endSpan(span) catch {};
            }
        }

        // Clean up all streams
        var stream_iter = self.streams.iterator();
        while (stream_iter.next()) |entry| {
            // Record stream close for each active stream
            if (self.metrics_registry) |registry| {
                registry.recordStreamClose();
            }
            entry.value_ptr.*.frame_buffer.deinit(self.allocator);
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.streams.deinit();

        self.allocator.free(self.endpoint);
        self.socket.close();
        self.allocator.destroy(self);
    }

    fn ping(ptr: *anyopaque) TransportError!void {
        const self: *WebSocketConnectionAdapter = @ptrCast(@alignCast(ptr));

        if (!self.is_upgraded) {
            return TransportError.Protocol;
        }

        // Send WebSocket ping frame
        const ping_frame = [_]u8{ 0x89, 0x00 }; // FIN + Ping opcode, no payload
        _ = self.socket.write(&ping_frame) catch return TransportError.Protocol;

        return;
    }

    fn isConnected(ptr: *anyopaque) bool {
        const self: *WebSocketConnectionAdapter = @ptrCast(@alignCast(ptr));
        return self.is_upgraded;
    }

    pub const vtable = Connection.VTable{
        .openStream = openStream,
        .close = close,
        .ping = ping,
        .isConnected = isConnected,
    };
};

const WebSocketListenerAdapter = struct {
    bind_address: std.net.Address,
    allocator: std.mem.Allocator,
    is_listening: bool,
    socket: ?std.net.Stream = null,

    fn accept(ptr: *anyopaque) TransportError!Connection {
        const self: *WebSocketListenerAdapter = @ptrCast(@alignCast(ptr));
        _ = self;
        // TODO: Implement WebSocket server accept
        return TransportError.Protocol;
    }

    fn close(ptr: *anyopaque) void {
        const self: *WebSocketListenerAdapter = @ptrCast(@alignCast(ptr));
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

const WebSocketStreamAdapter = struct {
    connection: *WebSocketConnectionAdapter,
    allocator: std.mem.Allocator,
    stream_id: u64,
    frame_buffer: std.ArrayList(u8),
    stream_span: ?*Span,

    fn writeFrame(ptr: *anyopaque, _: FrameType, flags: u8, data: []const u8) TransportError!void {
        const self: *WebSocketStreamAdapter = @ptrCast(@alignCast(ptr));

        // Map RPC frame to WebSocket frame
        // Use binary WebSocket frames for RPC data
        try self.sendWebSocketFrame(.binary, data, flags & Frame.Flags.END_STREAM != 0);
    }

    fn sendWebSocketFrame(self: *WebSocketStreamAdapter, opcode: Opcode, payload: []const u8, fin: bool) !void {
        var frame: std.ArrayList(u8) = .empty;
        defer frame.deinit(self.allocator);

        // Byte 0: FIN + RSV + Opcode
        var byte0: u8 = @intFromEnum(opcode);
        if (fin) byte0 |= 0x80; // Set FIN bit

        try frame.append(self.allocator, byte0);

        // Byte 1: MASK + Payload length
        var byte1: u8 = 0;
        if (self.connection.is_client) byte1 |= 0x80; // Client must mask

        if (payload.len < 126) {
            byte1 |= @intCast(payload.len);
            try frame.append(self.allocator, byte1);
        } else if (payload.len < 65536) {
            byte1 |= 126;
            try frame.append(self.allocator, byte1);
            try frame.append(@intCast((payload.len >> 8) & 0xFF));
            try frame.append(@intCast(payload.len & 0xFF));
        } else {
            byte1 |= 127;
            try frame.append(self.allocator, byte1);
            // 64-bit length
            var i: u3 = 0;
            while (i < 8) : (i += 1) {
                try frame.append(@intCast((payload.len >> @intCast(56 - i * 8)) & 0xFF));
            }
        }

        // Masking key (if client)
        var mask_key: [4]u8 = undefined;
        if (self.connection.is_client) {
            std.crypto.random.bytes(&mask_key);
            try frame.appendSlice(&mask_key);
        }

        // Payload (masked if client)
        if (self.connection.is_client) {
            for (payload, 0..) |byte, i| {
                try frame.append(byte ^ mask_key[i % 4]);
            }
        } else {
            try frame.appendSlice(payload);
        }

        // Send frame
        const bytes_written = try self.connection.socket.write(frame.items);

        // Record bytes sent
        if (self.connection.metrics_registry) |registry| {
            registry.recordBytesTransferred(bytes_written, 0);
        }
    }

    fn readFrame(ptr: *anyopaque, allocator: std.mem.Allocator) TransportError!Frame {
        const self: *WebSocketStreamAdapter = @ptrCast(@alignCast(ptr));

        // Read WebSocket frame header (minimum 2 bytes)
        var header_buf: [14]u8 = undefined; // Max header size
        const bytes_read = self.connection.socket.read(header_buf[0..2]) catch
            return TransportError.Protocol;

        if (bytes_read < 2) return TransportError.Protocol;

        const byte0 = header_buf[0];
        const byte1 = header_buf[1];

        const fin = (byte0 & 0x80) != 0;
        const opcode: Opcode = @enumFromInt(byte0 & 0x0F);
        const masked = (byte1 & 0x80) != 0;
        var payload_len: u64 = byte1 & 0x7F;

        var header_offset: usize = 2;

        // Extended payload length
        if (payload_len == 126) {
            _ = try self.connection.socket.read(header_buf[2..4]);
            payload_len = (@as(u64, header_buf[2]) << 8) | header_buf[3];
            header_offset = 4;
        } else if (payload_len == 127) {
            _ = try self.connection.socket.read(header_buf[2..10]);
            payload_len = 0;
            var i: u3 = 0;
            while (i < 8) : (i += 1) {
                payload_len = (payload_len << 8) | header_buf[2 + i];
            }
            header_offset = 10;
        }

        // Masking key
        var mask_key: [4]u8 = undefined;
        if (masked) {
            _ = try self.connection.socket.read(header_buf[header_offset .. header_offset + 4]);
            @memcpy(&mask_key, header_buf[header_offset .. header_offset + 4]);
        }

        // Read payload
        const frame_data = try allocator.alloc(u8, @intCast(payload_len));
        errdefer allocator.free(frame_data);

        if (payload_len > 0) {
            _ = try self.connection.socket.read(frame_data);

            // Unmask if needed
            if (masked) {
                for (frame_data, 0..) |*byte, i| {
                    byte.* ^= mask_key[i % 4];
                }
            }
        }

        // Handle control frames
        switch (opcode) {
            .ping => {
                // Respond with pong
                try self.sendWebSocketFrame(.pong, frame_data, true);
                allocator.free(frame_data);
                // Recursively read next frame
                return self.readFrame(ptr, allocator);
            },
            .pong => {
                // Ignore pong frames
                allocator.free(frame_data);
                return self.readFrame(ptr, allocator);
            },
            .close => {
                // Connection closing
                allocator.free(frame_data);
                return TransportError.Closed;
            },
            else => {},
        }

        // Map to RPC frame
        const rpc_flags: u8 = if (fin) Frame.Flags.END_STREAM else 0;

        // Record bytes received (header + payload)
        if (self.connection.metrics_registry) |registry| {
            const total_bytes_received = header_offset + (if (masked) 4 else 0) + @as(usize, @intCast(payload_len));
            registry.recordBytesTransferred(0, total_bytes_received);
        }

        return Frame{
            .frame_type = .data, // WebSocket binary/text maps to data
            .flags = rpc_flags,
            .data = frame_data,
            .allocator = allocator,
        };
    }

    fn cancel(ptr: *anyopaque) void {
        const self: *WebSocketStreamAdapter = @ptrCast(@alignCast(ptr));
        // Send close frame for this stream
        self.sendWebSocketFrame(.close, &[_]u8{}, true) catch {};
    }

    fn close(ptr: *anyopaque) void {
        const self: *WebSocketStreamAdapter = @ptrCast(@alignCast(ptr));

        // Record stream close
        if (self.connection.metrics_registry) |registry| {
            registry.recordStreamClose();
        }

        // End stream span
        if (self.stream_span) |span| {
            span.setStatus(.ok, null) catch {};
            if (self.connection.tracer) |t| {
                t.endSpan(span) catch {};
            }
        }

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

/// Convenience function to create a WebSocket transport
pub fn createTransport(allocator: std.mem.Allocator) Transport {
    const adapter = allocator.create(WebSocketTransportAdapter) catch @panic("OOM");
    adapter.* = WebSocketTransportAdapter.init(allocator);
    return transport_interface.createTransport(WebSocketTransportAdapter, adapter);
}

test "WebSocket URL parsing" {
    const allocator = std.testing.allocator;
    var adapter = WebSocketTransportAdapter.init(allocator);
    defer adapter.deinit();

    // Test ws://
    const parsed1 = try adapter.parseWebSocketUrl("ws://localhost:8080/api/v1");
    try std.testing.expectEqualStrings("ws", parsed1.scheme);
    try std.testing.expectEqualStrings("localhost", parsed1.host);
    try std.testing.expectEqual(@as(u16, 8080), parsed1.port);
    try std.testing.expectEqualStrings("/api/v1", parsed1.path);
    try std.testing.expectEqual(false, parsed1.is_secure);

    // Test wss://
    const parsed2 = try adapter.parseWebSocketUrl("wss://example.com:443/stream");
    try std.testing.expectEqualStrings("wss", parsed2.scheme);
    try std.testing.expectEqualStrings("example.com", parsed2.host);
    try std.testing.expectEqual(@as(u16, 443), parsed2.port);
    try std.testing.expectEqualStrings("/stream", parsed2.path);
    try std.testing.expectEqual(true, parsed2.is_secure);

    // Test default ports
    const parsed3 = try adapter.parseWebSocketUrl("ws://localhost/");
    try std.testing.expectEqual(@as(u16, 80), parsed3.port);

    const parsed4 = try adapter.parseWebSocketUrl("wss://secure.io/");
    try std.testing.expectEqual(@as(u16, 443), parsed4.port);
}
