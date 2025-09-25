# Transport Adapter Development Guide

**Complete guide to implementing custom transport adapters for zRPC**

This guide teaches you how to create custom transport adapters that integrate seamlessly with zRPC's transport-agnostic architecture.

## Overview

Transport adapters allow zRPC to support different network protocols while maintaining a consistent API. The adapter pattern provides:

- **Protocol Independence**: Core RPC logic remains unchanged
- **Performance Optimization**: Each adapter optimized for its protocol
- **Testing Support**: Mock transports for development/testing
- **Extensibility**: Easy to add new protocols

## Transport Adapter Interface

All transport adapters must implement the standardized Service Provider Interface (SPI):

### Core Interface Structure

```zig
pub const Transport = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    const VTable = struct {
        connect: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, endpoint: []const u8, tls_config: ?*const TlsConfig) TransportError!Connection,
        deinit: *const fn (ptr: *anyopaque) void,
    };
};

pub const Connection = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    const VTable = struct {
        openStream: *const fn (ptr: *anyopaque) TransportError!Stream,
        close: *const fn (ptr: *anyopaque) void,
        ping: *const fn (ptr: *anyopaque) TransportError!void,
        isConnected: *const fn (ptr: *anyopaque) bool,
    };
};

pub const Stream = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    const VTable = struct {
        writeFrame: *const fn (ptr: *anyopaque, frame_type: FrameType, flags: u8, data: []const u8) TransportError!void,
        readFrame: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator) TransportError!Frame,
        close: *const fn (ptr: *anyopaque) void,
        cancel: *const fn (ptr: *anyopaque) void,
    };
};
```

## Step-by-Step Implementation

### Step 1: Design Your Transport

First, define your transport's characteristics:

```zig
// Example: WebSocket transport adapter
const WebSocketTransportAdapter = struct {
    allocator: std.mem.Allocator,
    config: Config,
    active_connections: std.ArrayList(*WebSocketConnection),
    mutex: std.Thread.Mutex,

    const Config = struct {
        max_connections: usize = 100,
        connection_timeout_ms: u64 = 30000,
        enable_compression: bool = true,
        websocket_version: u8 = 13,
        user_agent: []const u8 = "zrpc-websocket/1.0",
    };

    const Self = @This();

    // ... implementation details
};
```

### Step 2: Implement Transport Methods

```zig
pub const WebSocketTransportAdapter = struct {
    // ... fields from above

    pub fn init(allocator: std.mem.Allocator, config: Config) !*Self {
        const adapter = try allocator.create(Self);
        adapter.* = Self{
            .allocator = allocator,
            .config = config,
            .active_connections = std.ArrayList(*WebSocketConnection).init(allocator),
            .mutex = std.Thread.Mutex{},
        };
        return adapter;
    }

    pub fn deinit(self: *Self) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Close all active connections
        for (self.active_connections.items) |conn| {
            conn.close();
            self.allocator.destroy(conn);
        }
        self.active_connections.deinit();
        self.allocator.destroy(self);
    }

    // Transport vtable implementation
    pub const transport_vtable = Transport.VTable{
        .connect = connect,
        .deinit = deinitTransport,
    };

    fn connect(ptr: *anyopaque, allocator: std.mem.Allocator, endpoint: []const u8, tls_config: ?*const TlsConfig) TransportError!Connection {
        const self: *Self = @ptrCast(@alignCast(ptr));

        // Parse endpoint (e.g., "ws://localhost:8080/rpc" or "wss://...")
        const parsed_endpoint = try parseWebSocketEndpoint(endpoint);

        // Create WebSocket connection
        const ws_conn = try WebSocketConnection.init(
            allocator,
            parsed_endpoint,
            tls_config,
            self.config
        );

        // Establish connection
        try ws_conn.connect();

        // Add to active connections
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.active_connections.append(ws_conn);

        // Return Connection interface
        return Connection{
            .ptr = ws_conn,
            .vtable = &WebSocketConnection.connection_vtable,
        };
    }

    fn deinitTransport(ptr: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.deinit();
    }
};
```

### Step 3: Implement Connection Methods

```zig
const WebSocketConnection = struct {
    allocator: std.mem.Allocator,
    socket: std.net.Stream,
    endpoint: ParsedEndpoint,
    tls_config: ?*const TlsConfig,
    config: WebSocketTransportAdapter.Config,
    connected: std.atomic.Value(bool),
    streams: std.ArrayList(*WebSocketStream),
    next_stream_id: std.atomic.Value(u32),
    mutex: std.Thread.Mutex,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, endpoint: ParsedEndpoint,
               tls_config: ?*const TlsConfig, config: WebSocketTransportAdapter.Config) !*Self {
        const conn = try allocator.create(Self);
        conn.* = Self{
            .allocator = allocator,
            .socket = undefined, // Will be set during connect()
            .endpoint = endpoint,
            .tls_config = tls_config,
            .config = config,
            .connected = std.atomic.Value(bool).init(false),
            .streams = std.ArrayList(*WebSocketStream).init(allocator),
            .next_stream_id = std.atomic.Value(u32).init(1),
            .mutex = std.Thread.Mutex{},
        };
        return conn;
    }

    pub fn deinit(self: *Self) void {
        self.close();

        self.mutex.lock();
        defer self.mutex.unlock();

        // Close all streams
        for (self.streams.items) |stream| {
            stream.close();
            self.allocator.destroy(stream);
        }
        self.streams.deinit();
        self.allocator.destroy(self);
    }

    pub fn connect(self: *Self) !void {
        // Connect to WebSocket server
        const address = try std.net.Address.parseIp(self.endpoint.host, self.endpoint.port);
        self.socket = try std.net.tcpConnectToAddress(address);

        // Perform WebSocket handshake
        try self.performHandshake();

        self.connected.store(true, .release);
    }

    // Connection vtable implementation
    pub const connection_vtable = Connection.VTable{
        .openStream = openStream,
        .close = closeConnection,
        .ping = ping,
        .isConnected = isConnected,
    };

    fn openStream(ptr: *anyopaque) TransportError!Stream {
        const self: *Self = @ptrCast(@alignCast(ptr));

        if (!self.connected.load(.acquire)) {
            return TransportError.NotConnected;
        }

        // Create new stream
        const stream_id = self.next_stream_id.fetchAdd(1, .monotonic);
        const stream = try WebSocketStream.init(self.allocator, self, stream_id);

        // Add to active streams
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.streams.append(stream);

        return Stream{
            .ptr = stream,
            .vtable = &WebSocketStream.stream_vtable,
        };
    }

    fn closeConnection(ptr: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.close();
    }

    fn ping(ptr: *anyopaque) TransportError!void {
        const self: *Self = @ptrCast(@alignCast(ptr));

        if (!self.connected.load(.acquire)) {
            return TransportError.NotConnected;
        }

        // Send WebSocket ping frame
        const ping_frame = WebSocketFrame{
            .opcode = .ping,
            .payload = &[_]u8{},
        };

        try self.sendFrame(ping_frame);

        // Wait for pong (simplified - in real implementation, use async)
        const response = try self.receiveFrame();
        if (response.opcode != .pong) {
            return TransportError.Protocol;
        }
    }

    fn isConnected(ptr: *anyopaque) bool {
        const self: *Self = @ptrCast(@alignCast(ptr));
        return self.connected.load(.acquire);
    }

    // WebSocket-specific methods
    pub fn close(self: *Self) void {
        if (self.connected.swap(false, .acq_rel)) {
            // Send close frame
            const close_frame = WebSocketFrame{
                .opcode = .close,
                .payload = &[_]u8{},
            };
            self.sendFrame(close_frame) catch {};

            self.socket.close();
        }
    }

    fn performHandshake(self: *Self) !void {
        // Implement WebSocket handshake protocol
        // This is simplified - real implementation needs full WebSocket handshake

        const key = try generateWebSocketKey(self.allocator);
        defer self.allocator.free(key);

        const handshake_request = try std.fmt.allocPrint(self.allocator,
            "GET {} HTTP/1.1\r\n" ++
            "Host: {}:{}\r\n" ++
            "Upgrade: websocket\r\n" ++
            "Connection: Upgrade\r\n" ++
            "Sec-WebSocket-Key: {s}\r\n" ++
            "Sec-WebSocket-Version: {}\r\n" ++
            "Sec-WebSocket-Protocol: zrpc\r\n" ++
            "\r\n",
            .{ self.endpoint.path, self.endpoint.host, self.endpoint.port, key, self.config.websocket_version }
        );
        defer self.allocator.free(handshake_request);

        _ = try self.socket.writeAll(handshake_request);

        // Read and validate response (simplified)
        var response_buffer: [4096]u8 = undefined;
        const response_len = try self.socket.readAll(response_buffer[0..]);
        const response = response_buffer[0..response_len];

        if (!std.mem.containsAtLeast(u8, response, 1, "HTTP/1.1 101")) {
            return TransportError.Protocol;
        }
    }

    fn sendFrame(self: *Self, frame: WebSocketFrame) !void {
        // Implement WebSocket frame sending
        var frame_buffer = std.ArrayList(u8).init(self.allocator);
        defer frame_buffer.deinit();

        // WebSocket frame format: [FIN|RSV|OPCODE][MASK|LEN][EXTENDED LEN][MASK KEY][PAYLOAD]
        const fin_and_opcode: u8 = 0x80 | @intFromEnum(frame.opcode); // FIN=1
        try frame_buffer.append(fin_and_opcode);

        // Payload length encoding
        if (frame.payload.len < 126) {
            try frame_buffer.append(@intCast(frame.payload.len | 0x80)); // MASK=1 for client
        } else if (frame.payload.len < 65536) {
            try frame_buffer.append(126 | 0x80); // MASK=1
            try frame_buffer.append(@intCast((frame.payload.len >> 8) & 0xFF));
            try frame_buffer.append(@intCast(frame.payload.len & 0xFF));
        } else {
            try frame_buffer.append(127 | 0x80); // MASK=1
            // 64-bit length (simplified for this example)
            for (0..8) |i| {
                try frame_buffer.append(@intCast((frame.payload.len >> @intCast(8 * (7 - i))) & 0xFF));
            }
        }

        // Masking key (required for client-to-server)
        const mask_key = [_]u8{ 0x12, 0x34, 0x56, 0x78 }; // In real implementation, use random
        try frame_buffer.appendSlice(&mask_key);

        // Masked payload
        for (frame.payload, 0..) |byte, i| {
            try frame_buffer.append(byte ^ mask_key[i % 4]);
        }

        _ = try self.socket.writeAll(frame_buffer.items);
    }

    fn receiveFrame(self: *Self) !WebSocketFrame {
        // Implement WebSocket frame receiving (simplified)
        var header: [2]u8 = undefined;
        _ = try self.socket.readAll(&header);

        const opcode: WebSocketOpcode = @enumFromInt(header[0] & 0x0F);
        const masked = (header[1] & 0x80) != 0;
        var payload_len: u64 = header[1] & 0x7F;

        // Extended payload length
        if (payload_len == 126) {
            var len_bytes: [2]u8 = undefined;
            _ = try self.socket.readAll(&len_bytes);
            payload_len = (@as(u64, len_bytes[0]) << 8) | len_bytes[1];
        } else if (payload_len == 127) {
            var len_bytes: [8]u8 = undefined;
            _ = try self.socket.readAll(&len_bytes);
            payload_len = std.mem.readInt(u64, &len_bytes, .big);
        }

        // Masking key
        var mask_key: [4]u8 = undefined;
        if (masked) {
            _ = try self.socket.readAll(&mask_key);
        }

        // Payload
        const payload = try self.allocator.alloc(u8, @intCast(payload_len));
        _ = try self.socket.readAll(payload);

        // Unmask payload
        if (masked) {
            for (payload, 0..) |*byte, i| {
                byte.* ^= mask_key[i % 4];
            }
        }

        return WebSocketFrame{
            .opcode = opcode,
            .payload = payload,
        };
    }
};
```

### Step 4: Implement Stream Methods

```zig
const WebSocketStream = struct {
    allocator: std.mem.Allocator,
    connection: *WebSocketConnection,
    stream_id: u32,
    closed: std.atomic.Value(bool),

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, connection: *WebSocketConnection, stream_id: u32) !*Self {
        const stream = try allocator.create(Self);
        stream.* = Self{
            .allocator = allocator,
            .connection = connection,
            .stream_id = stream_id,
            .closed = std.atomic.Value(bool).init(false),
        };
        return stream;
    }

    // Stream vtable implementation
    pub const stream_vtable = Stream.VTable{
        .writeFrame = writeFrame,
        .readFrame = readFrame,
        .close = closeStream,
        .cancel = cancelStream,
    };

    fn writeFrame(ptr: *anyopaque, frame_type: FrameType, flags: u8, data: []const u8) TransportError!void {
        const self: *Self = @ptrCast(@alignCast(ptr));

        if (self.closed.load(.acquire)) {
            return TransportError.InvalidArgument;
        }

        // Create RPC frame header
        const rpc_frame = try self.encodeRpcFrame(frame_type, flags, self.stream_id, data);
        defer self.allocator.free(rpc_frame);

        // Send as WebSocket binary message
        const ws_frame = WebSocketFrame{
            .opcode = .binary,
            .payload = rpc_frame,
        };

        try self.connection.sendFrame(ws_frame);
    }

    fn readFrame(ptr: *anyopaque, allocator: std.mem.Allocator) TransportError!Frame {
        const self: *Self = @ptrCast(@alignCast(ptr));

        if (self.closed.load(.acquire)) {
            return TransportError.InvalidArgument;
        }

        // Receive WebSocket frame
        const ws_frame = try self.connection.receiveFrame();
        defer allocator.free(ws_frame.payload);

        if (ws_frame.opcode != .binary) {
            return TransportError.InvalidFrame;
        }

        // Decode RPC frame from WebSocket payload
        return try self.decodeRpcFrame(allocator, ws_frame.payload);
    }

    fn closeStream(ptr: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.close();
    }

    fn cancelStream(ptr: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.cancel();
    }

    pub fn close(self: *Self) void {
        if (!self.closed.swap(true, .acq_rel)) {
            // Send RST_STREAM frame
            self.writeFrame(.rst_stream, 0, &[_]u8{}) catch {};

            // Remove from connection's stream list
            self.connection.mutex.lock();
            defer self.connection.mutex.unlock();

            for (self.connection.streams.items, 0..) |stream, i| {
                if (stream == self) {
                    _ = self.connection.streams.swapRemove(i);
                    break;
                }
            }
        }
    }

    pub fn cancel(self: *Self) void {
        self.close(); // For this simple example, cancel is the same as close
    }

    // Helper methods for RPC frame encoding/decoding
    fn encodeRpcFrame(self: *Self, frame_type: FrameType, flags: u8, stream_id: u32, data: []const u8) ![]u8 {
        // RPC frame format: [LENGTH:24][TYPE:8][FLAGS:8][STREAM_ID:32][PAYLOAD]
        const frame_size = 9 + data.len;
        const frame = try self.allocator.alloc(u8, frame_size);

        // Frame length (excluding header)
        const payload_len = @as(u32, @intCast(data.len));
        frame[0] = @intCast((payload_len >> 16) & 0xFF);
        frame[1] = @intCast((payload_len >> 8) & 0xFF);
        frame[2] = @intCast(payload_len & 0xFF);

        // Frame type and flags
        frame[3] = @intFromEnum(frame_type);
        frame[4] = flags;

        // Stream ID
        std.mem.writeInt(u32, frame[5..9], stream_id, .big);

        // Payload
        @memcpy(frame[9..], data);

        return frame;
    }

    fn decodeRpcFrame(self: *Self, allocator: std.mem.Allocator, data: []const u8) !Frame {
        _ = self;

        if (data.len < 9) {
            return TransportError.InvalidFrame;
        }

        // Parse frame header
        const payload_len = (@as(u32, data[0]) << 16) | (@as(u32, data[1]) << 8) | data[2];
        const frame_type: FrameType = @enumFromInt(data[3]);
        const flags = data[4];
        const stream_id = std.mem.readInt(u32, data[5..9], .big);

        if (data.len != 9 + payload_len) {
            return TransportError.InvalidFrame;
        }

        // Copy payload
        const payload = try allocator.alloc(u8, payload_len);
        @memcpy(payload, data[9..]);

        return Frame{
            .frame_type = frame_type,
            .flags = flags,
            .stream_id = stream_id,
            .payload = payload,
        };
    }
};
```

### Step 5: Supporting Types and Utilities

```zig
// WebSocket-specific types
const WebSocketFrame = struct {
    opcode: WebSocketOpcode,
    payload: []const u8,
};

const WebSocketOpcode = enum(u4) {
    continuation = 0x0,
    text = 0x1,
    binary = 0x2,
    close = 0x8,
    ping = 0x9,
    pong = 0xA,
};

const ParsedEndpoint = struct {
    scheme: []const u8, // "ws" or "wss"
    host: []const u8,
    port: u16,
    path: []const u8,
};

// Utility functions
fn parseWebSocketEndpoint(endpoint: []const u8) !ParsedEndpoint {
    // Parse "ws://host:port/path" or "wss://host:port/path"
    // This is simplified - real implementation needs robust URL parsing

    if (std.mem.startsWith(u8, endpoint, "ws://")) {
        const remainder = endpoint[5..];
        const scheme = "ws";
        return parseHostPortPath(remainder, scheme, 80);
    } else if (std.mem.startsWith(u8, endpoint, "wss://")) {
        const remainder = endpoint[6..];
        const scheme = "wss";
        return parseHostPortPath(remainder, scheme, 443);
    } else {
        return TransportError.InvalidArgument;
    }
}

fn parseHostPortPath(remainder: []const u8, scheme: []const u8, default_port: u16) !ParsedEndpoint {
    // Find path separator
    const path_start = std.mem.indexOf(u8, remainder, "/") orelse remainder.len;
    const host_port = remainder[0..path_start];
    const path = if (path_start < remainder.len) remainder[path_start..] else "/";

    // Split host and port
    if (std.mem.lastIndexOf(u8, host_port, ":")) |colon_pos| {
        const host = host_port[0..colon_pos];
        const port_str = host_port[colon_pos + 1..];
        const port = std.fmt.parseInt(u16, port_str, 10) catch default_port;

        return ParsedEndpoint{
            .scheme = scheme,
            .host = host,
            .port = port,
            .path = path,
        };
    } else {
        return ParsedEndpoint{
            .scheme = scheme,
            .host = host_port,
            .port = default_port,
            .path = path,
        };
    }
}

fn generateWebSocketKey(allocator: std.mem.Allocator) ![]u8 {
    // Generate random 16-byte key and base64 encode it
    var random_bytes: [16]u8 = undefined;
    std.crypto.random.bytes(&random_bytes);

    // Base64 encode (simplified - real implementation should use proper base64)
    const key = try allocator.alloc(u8, 24); // Base64 of 16 bytes = 24 chars
    _ = std.base64.standard.Encoder.encode(key, &random_bytes);

    return key;
}
```

### Step 6: Create Public Factory Functions

```zig
// Public API for creating transport instances
pub fn createClientTransport(allocator: std.mem.Allocator) Transport {
    const config = WebSocketTransportAdapter.Config{}; // Default config
    return createClientTransportWithConfig(allocator, config);
}

pub fn createClientTransportWithConfig(allocator: std.mem.Allocator, config: WebSocketTransportAdapter.Config) Transport {
    const adapter = WebSocketTransportAdapter.init(allocator, config) catch @panic("Failed to create WebSocket transport");

    return Transport{
        .ptr = adapter,
        .vtable = &WebSocketTransportAdapter.transport_vtable,
    };
}

pub fn createServerTransport(allocator: std.mem.Allocator) Transport {
    // For server, you'd implement WebSocketServerAdapter
    // This is left as an exercise - server WebSocket is more complex
    @panic("Server WebSocket transport not implemented in this example");
}
```

## Contract Testing

Every transport adapter must pass the contract tests:

```zig
const std = @import("std");
const testing = std.testing;
const zrpc = @import("zrpc-core");
const websocket_transport = @import("websocket_transport.zig");

test "WebSocket transport contract compliance" {
    const allocator = testing.allocator;

    // Create transport
    var transport = websocket_transport.createClientTransport(allocator);
    defer transport.deinit();

    // Run contract tests
    try zrpc.contract_tests.runClientTransportTests(allocator, transport);
}

test "WebSocket connection lifecycle" {
    const allocator = testing.allocator;

    var transport = websocket_transport.createClientTransport(allocator);
    defer transport.deinit();

    // Mock WebSocket server for testing
    const mock_server = try MockWebSocketServer.start(allocator, "127.0.0.1:0");
    defer mock_server.stop();

    const endpoint = try std.fmt.allocPrint(allocator, "ws://127.0.0.1:{}/test", .{mock_server.port});
    defer allocator.free(endpoint);

    // Test connection
    const connection = try transport.connect(allocator, endpoint, null);
    try testing.expect(connection.isConnected());

    // Test ping
    try connection.ping();

    // Test stream creation
    const stream = try connection.openStream();
    defer stream.close();

    // Test frame operations
    const test_data = "Hello, WebSocket!";
    try stream.writeFrame(.data, 0, test_data);

    const frame = try stream.readFrame(allocator);
    defer allocator.free(frame.payload);

    try testing.expectEqual(FrameType.data, frame.frame_type);
    try testing.expectEqualStrings(test_data, frame.payload);

    // Cleanup
    connection.close();
    try testing.expect(!connection.isConnected());
}
```

## Performance Considerations

### Memory Management

```zig
// Use memory pools for frequent allocations
const FramePool = struct {
    allocator: std.mem.Allocator,
    pool: std.ArrayList([]u8),
    mutex: std.Thread.Mutex,

    pub fn getFrame(self: *FramePool, size: usize) ![]u8 {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Try to reuse existing frame
        for (self.pool.items, 0..) |frame, i| {
            if (frame.len >= size) {
                _ = self.pool.swapRemove(i);
                return frame[0..size];
            }
        }

        // Allocate new frame
        return try self.allocator.alloc(u8, size);
    }

    pub fn returnFrame(self: *FramePool, frame: []u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        self.pool.append(frame) catch {
            // Pool full, just free the frame
            self.allocator.free(frame);
        };
    }
};
```

### Zero-Copy Optimization

```zig
// Implement zero-copy reads when possible
fn writeFrameZeroCopy(self: *WebSocketStream, frame_type: FrameType, flags: u8, data: []const u8) TransportError!void {
    // Instead of copying data, write header and data separately
    const header = try self.encodeFrameHeader(frame_type, flags, self.stream_id, data.len);
    defer self.allocator.free(header);

    // Write header
    try self.connection.socket.writeAll(header);

    // Write data directly (zero-copy)
    try self.connection.socket.writeAll(data);
}
```

### Asynchronous Operations

```zig
// Implement async I/O for better performance
fn readFrameAsync(self: *WebSocketStream, allocator: std.mem.Allocator) TransportError!Frame {
    // Use async I/O operations
    const header_future = async self.connection.socket.read(header_buffer);
    const header = try await header_future;

    // Parse header and read payload asynchronously
    const payload_len = parsePayloadLength(header);
    const payload_future = async self.readPayload(allocator, payload_len);
    const payload = try await payload_future;

    return Frame{
        .frame_type = parseFrameType(header),
        .flags = parseFlags(header),
        .stream_id = parseStreamId(header),
        .payload = payload,
    };
}
```

## Testing Strategies

### Mock Server for Testing

```zig
const MockWebSocketServer = struct {
    allocator: std.mem.Allocator,
    server: std.net.Server,
    port: u16,
    running: std.atomic.Value(bool),
    thread: ?std.Thread,

    pub fn start(allocator: std.mem.Allocator, bind_address: []const u8) !*MockWebSocketServer {
        const address = try std.net.Address.parseIp(bind_address, 0);
        var server = try address.listen(.{});
        const port = server.listen_address.getPort();

        const mock_server = try allocator.create(MockWebSocketServer);
        mock_server.* = MockWebSocketServer{
            .allocator = allocator,
            .server = server,
            .port = port,
            .running = std.atomic.Value(bool).init(true),
            .thread = null,
        };

        mock_server.thread = try std.Thread.spawn(.{}, runServer, .{mock_server});

        return mock_server;
    }

    pub fn stop(self: *MockWebSocketServer) void {
        self.running.store(false, .release);
        if (self.thread) |thread| {
            thread.join();
        }
        self.server.deinit();
        self.allocator.destroy(self);
    }

    fn runServer(self: *MockWebSocketServer) void {
        while (self.running.load(.acquire)) {
            const connection = self.server.accept() catch continue;

            // Handle WebSocket connection in separate thread
            const handle_thread = std.Thread.spawn(.{}, handleConnection, .{ self, connection }) catch continue;
            handle_thread.detach();
        }
    }

    fn handleConnection(self: *MockWebSocketServer, connection: std.net.Server.Connection) void {
        _ = self;
        defer connection.stream.close();

        // Implement mock WebSocket server behavior
        // Accept handshake, echo messages, etc.
    }
};
```

### Error Injection Testing

```zig
test "WebSocket error handling" {
    const allocator = testing.allocator;

    var transport = websocket_transport.createClientTransport(allocator);
    defer transport.deinit();

    // Test invalid endpoint
    try testing.expectError(TransportError.InvalidArgument,
        transport.connect(allocator, "invalid://endpoint", null));

    // Test connection timeout
    try testing.expectError(TransportError.ConnectionTimeout,
        transport.connect(allocator, "ws://non-existent-host:9999/", null));

    // Test protocol errors
    // ... more error tests
}
```

## Documentation

Document your transport adapter thoroughly:

```zig
//! WebSocket Transport Adapter for zRPC
//!
//! This adapter provides WebSocket transport support for zRPC, allowing
//! RPC communication over WebSocket connections.
//!
//! ## Features
//! - WebSocket protocol support (RFC 6455)
//! - Both WS and WSS (TLS) connections
//! - Frame-based RPC communication
//! - Connection pooling and management
//! - Automatic reconnection support
//!
//! ## Configuration
//! ```zig
//! var config = WebSocketTransportAdapter.Config{
//!     .max_connections = 100,
//!     .connection_timeout_ms = 30000,
//!     .enable_compression = true,
//! };
//!
//! var transport = websocket_transport.createClientTransportWithConfig(allocator, config);
//! ```
//!
//! ## Performance
//! - Optimized for low latency
//! - Zero-copy operations where possible
//! - Memory pooling for frame buffers
//! - Asynchronous I/O support
//!
//! ## Thread Safety
//! All public APIs are thread-safe. Internal state is protected by mutexes
//! where necessary.
```

## Integration Example

Here's how your custom transport integrates with zRPC:

```zig
const std = @import("std");
const zrpc = @import("zrpc-core");
const websocket_transport = @import("websocket_transport.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Create WebSocket transport
    var ws_config = websocket_transport.WebSocketTransportAdapter.Config{
        .enable_compression = true,
        .connection_timeout_ms = 10000,
    };

    var transport = websocket_transport.createClientTransportWithConfig(allocator, ws_config);
    defer transport.deinit();

    // Create zRPC client with WebSocket transport
    var client_config = zrpc.ClientConfig.default(transport);
    var client = try zrpc.Client.init(allocator, client_config);
    defer client.deinit();

    // Connect via WebSocket
    try client.connect("ws://localhost:8080/rpc", null);

    // Make RPC calls - the rest is identical to other transports!
    const response = try client.call(RequestType, ResponseType, "Service/Method", request);
    std.log.info("Response: {}", .{response});
}
```

## Best Practices

1. **Follow the Interface**: Implement all required methods exactly as specified
2. **Error Handling**: Map transport-specific errors to `TransportError` enum
3. **Resource Management**: Always clean up resources in `deinit` methods
4. **Thread Safety**: Protect shared state with appropriate synchronization
5. **Performance**: Optimize for your protocol's characteristics
6. **Testing**: Implement comprehensive tests including contract tests
7. **Documentation**: Document configuration options and usage patterns

## Common Pitfalls

1. **Memory Leaks**: Always pair allocations with deallocations
2. **Blocking Operations**: Avoid blocking the caller thread
3. **Error Propagation**: Don't swallow errors - propagate them appropriately
4. **State Management**: Handle connection/stream state transitions correctly
5. **Frame Boundaries**: Ensure proper frame parsing and generation

---

**Congratulations!** You now have the knowledge to implement custom transport adapters for zRPC. Your adapter will integrate seamlessly with the existing ecosystem while providing optimizations specific to your protocol.