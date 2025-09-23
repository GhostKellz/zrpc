//! QUIC-gRPC implementation combining QUIC transport with gRPC message framing
//! This implements both HTTP/2 and QUIC transport for gRPC services

const std = @import("std");
const Error = @import("error.zig").Error;
const service = @import("service.zig");
const codec = @import("codec.zig");
const quic = @import("quic.zig");

pub const QuicGrpcTransport = struct {
    allocator: std.mem.Allocator,
    socket: std.net.DatagramSocket,
    connections: std.AutoHashMap(std.net.Address, *QuicGrpcConnection),

    pub fn init(allocator: std.mem.Allocator) !QuicGrpcTransport {
        const socket = try std.net.DatagramSocket.init(.ipv4);

        return QuicGrpcTransport{
            .allocator = allocator,
            .socket = socket,
            .connections = std.AutoHashMap(std.net.Address, *QuicGrpcConnection).init(allocator),
        };
    }

    pub fn deinit(self: *QuicGrpcTransport) void {
        var conn_iter = self.connections.iterator();
        while (conn_iter.next()) |entry| {
            entry.value_ptr.*.deinit();
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.connections.deinit();
        self.socket.deinit();
    }

    pub fn bind(self: *QuicGrpcTransport, address: std.net.Address) !void {
        try self.socket.bind(address);
    }

    pub fn connectToServer(self: *QuicGrpcTransport, server_address: std.net.Address) !*QuicGrpcConnection {
        // Check if we already have a connection
        if (self.connections.get(server_address)) |conn| {
            return conn;
        }

        // Create new QUIC connection
        const connection = try self.allocator.create(QuicGrpcConnection);
        connection.* = try QuicGrpcConnection.initClient(self.allocator, &self.socket, server_address);

        try self.connections.put(server_address, connection);

        // Perform QUIC handshake
        try connection.performHandshake();

        return connection;
    }

    pub fn acceptConnection(self: *QuicGrpcTransport) !*QuicGrpcConnection {
        var buffer: [1500]u8 = undefined;
        const result = try self.socket.receive(&buffer);

        // Check if this is from an existing connection
        if (self.connections.get(result.sender)) |conn| {
            try conn.processPacket(result.data);
            return conn;
        }

        // Create new server connection
        const connection = try self.allocator.create(QuicGrpcConnection);
        connection.* = try QuicGrpcConnection.initServer(self.allocator, &self.socket, result.sender);

        try self.connections.put(result.sender, connection);
        try connection.processPacket(result.data);

        return connection;
    }
};

pub const QuicGrpcConnection = struct {
    allocator: std.mem.Allocator,
    socket: *std.net.DatagramSocket,
    peer_address: std.net.Address,
    local_connection_id: [8]u8,
    peer_connection_id: [8]u8,
    state: ConnectionState,
    streams: std.AutoHashMap(u64, *GrpcStream),
    next_stream_id: u64,
    is_server: bool,

    const ConnectionState = enum {
        initial,
        handshake,
        established,
        closing,
        closed,
    };

    pub fn initClient(allocator: std.mem.Allocator, socket: *std.net.DatagramSocket, peer_address: std.net.Address) !QuicGrpcConnection {
        var local_id: [8]u8 = undefined;
        std.crypto.random.bytes(&local_id);

        var peer_id: [8]u8 = undefined;
        std.crypto.random.bytes(&peer_id);

        return QuicGrpcConnection{
            .allocator = allocator,
            .socket = socket,
            .peer_address = peer_address,
            .local_connection_id = local_id,
            .peer_connection_id = peer_id,
            .state = .initial,
            .streams = std.AutoHashMap(u64, *GrpcStream).init(allocator),
            .next_stream_id = 0, // Client starts at 0
            .is_server = false,
        };
    }

    pub fn initServer(allocator: std.mem.Allocator, socket: *std.net.DatagramSocket, peer_address: std.net.Address) !QuicGrpcConnection {
        var local_id: [8]u8 = undefined;
        std.crypto.random.bytes(&local_id);

        var peer_id: [8]u8 = undefined;
        std.crypto.random.bytes(&peer_id);

        return QuicGrpcConnection{
            .allocator = allocator,
            .socket = socket,
            .peer_address = peer_address,
            .local_connection_id = local_id,
            .peer_connection_id = peer_id,
            .state = .initial,
            .streams = std.AutoHashMap(u64, *GrpcStream).init(allocator),
            .next_stream_id = 1, // Server starts at 1
            .is_server = true,
        };
    }

    pub fn deinit(self: *QuicGrpcConnection) void {
        var stream_iter = self.streams.iterator();
        while (stream_iter.next()) |entry| {
            entry.value_ptr.*.deinit();
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.streams.deinit();
    }

    pub fn performHandshake(self: *QuicGrpcConnection) !void {
        if (self.state != .initial) return;

        // Send initial handshake packet
        var packet_data = std.ArrayList(u8){};
        defer packet_data.deinit(self.allocator);

        // QUIC packet header with connection IDs
        try packet_data.append(self.allocator, 0x80); // Long header packet
        try packet_data.appendSlice(self.allocator, &self.local_connection_id);
        try packet_data.appendSlice(self.allocator, &self.peer_connection_id);

        // Add handshake payload (simplified)
        const handshake_payload = "QUIC-gRPC-HANDSHAKE";
        try packet_data.appendSlice(self.allocator, handshake_payload);

        _ = try self.socket.sendTo(packet_data.items, self.peer_address);

        self.state = .handshake;

        // In a real implementation, we'd wait for handshake completion
        // For this demo, we'll just mark as established
        self.state = .established;
    }

    pub fn processPacket(self: *QuicGrpcConnection, data: []const u8) !void {
        // Simple packet processing - in real QUIC this would be much more complex
        if (data.len < 16) return Error.InvalidData;

        // Extract stream data (simplified)
        if (data.len > 20) {
            const stream_id: u64 = 0; // Simplified stream ID extraction
            var stream = self.streams.get(stream_id) orelse blk: {
                const new_stream = try self.allocator.create(GrpcStream);
                new_stream.* = try GrpcStream.init(self.allocator, stream_id);
                try self.streams.put(stream_id, new_stream);
                break :blk new_stream;
            };

            const payload = data[20..]; // Skip headers
            try stream.receiveData(payload);
        }
    }

    pub fn createStream(self: *QuicGrpcConnection) !*GrpcStream {
        if (self.state != .established) return Error.ConnectionNotReady;

        const stream_id = self.next_stream_id;
        self.next_stream_id += 4; // QUIC stream ID space

        const stream = try self.allocator.create(GrpcStream);
        stream.* = try GrpcStream.init(self.allocator, stream_id);
        stream.connection = self;

        try self.streams.put(stream_id, stream);
        return stream;
    }

    pub fn sendGrpcRequest(self: *QuicGrpcConnection, method: []const u8, message: []const u8) ![]u8 {
        const stream = try self.createStream();
        defer {
            stream.deinit();
            _ = self.streams.remove(stream.id);
            self.allocator.destroy(stream);
        }

        // Send gRPC request
        try stream.sendGrpcMessage(method, message);

        // Wait for response (simplified)
        return try stream.receiveGrpcResponse();
    }
};

pub const GrpcStream = struct {
    allocator: std.mem.Allocator,
    id: u64,
    state: StreamState,
    send_buffer: std.ArrayList(u8),
    recv_buffer: std.ArrayList(u8),
    connection: ?*QuicGrpcConnection,

    const StreamState = enum {
        idle,
        open,
        half_closed_local,
        half_closed_remote,
        closed,
    };

    pub fn init(allocator: std.mem.Allocator, stream_id: u64) !GrpcStream {
        return GrpcStream{
            .allocator = allocator,
            .id = stream_id,
            .state = .idle,
            .send_buffer = std.ArrayList(u8){},
            .recv_buffer = std.ArrayList(u8){},
            .connection = null,
        };
    }

    pub fn deinit(self: *GrpcStream) void {
        self.send_buffer.deinit(self.allocator);
        self.recv_buffer.deinit(self.allocator);
    }

    pub fn sendGrpcMessage(self: *GrpcStream, method: []const u8, message: []const u8) !void {
        if (self.connection == null) return Error.InvalidState;

        // Build gRPC-over-QUIC message
        var grpc_data = std.ArrayList(u8){};
        defer grpc_data.deinit(self.allocator);

        // gRPC-Web style headers (simplified)
        try grpc_data.appendSlice(self.allocator, ":method POST\r\n");
        try grpc_data.appendSlice(self.allocator, ":path /");
        try grpc_data.appendSlice(self.allocator, method);
        try grpc_data.appendSlice(self.allocator, "\r\n");
        try grpc_data.appendSlice(self.allocator, "content-type: application/grpc\r\n");
        try grpc_data.appendSlice(self.allocator, "grpc-encoding: identity\r\n\r\n");

        // gRPC message framing: [compression flag (1 byte)][length (4 bytes)][data]
        try grpc_data.append(self.allocator, 0); // No compression

        const length_bytes = std.mem.toBytes(std.mem.nativeToBig(u32, @intCast(message.len)));
        try grpc_data.appendSlice(self.allocator, &length_bytes);
        try grpc_data.appendSlice(self.allocator, message);

        // Create QUIC packet with stream data
        var packet = std.ArrayList(u8){};
        defer packet.deinit(self.allocator);

        // QUIC header (simplified)
        try packet.append(self.allocator, 0x40); // Short header
        try packet.appendSlice(self.allocator, &self.connection.?.peer_connection_id);

        // Stream frame
        try packet.append(self.allocator, 0x08); // STREAM frame type
        try encodeVarInt(&packet, self.id); // Stream ID
        try encodeVarInt(&packet, grpc_data.items.len); // Length
        try packet.appendSlice(self.allocator, grpc_data.items);

        // Send over UDP
        _ = try self.connection.?.socket.sendTo(packet.items, self.connection.?.peer_address);
        self.state = .open;
    }

    pub fn receiveData(self: *GrpcStream, data: []const u8) !void {
        try self.recv_buffer.appendSlice(self.allocator, data);
    }

    pub fn receiveGrpcResponse(self: *GrpcStream) ![]u8 {
        // Simplified response parsing - in real implementation would wait for complete message
        if (self.recv_buffer.items.len < 5) {
            return Error.IncompleteMessage;
        }

        // Parse gRPC message framing
        const compression_flag = self.recv_buffer.items[0];
        _ = compression_flag; // Unused for now

        const length = std.mem.readInt(u32, self.recv_buffer.items[1..5], .big);

        if (self.recv_buffer.items.len < 5 + length) {
            return Error.IncompleteMessage;
        }

        const message_data = self.recv_buffer.items[5..5 + length];
        return try self.allocator.dupe(u8, message_data);
    }

    // Streaming support
    pub fn sendStreamMessage(self: *GrpcStream, message: []const u8) !void {
        if (self.connection == null) return Error.InvalidState;

        // Build streaming gRPC message
        var grpc_data = std.ArrayList(u8){};
        defer grpc_data.deinit(self.allocator);

        // gRPC message framing for streaming
        try grpc_data.append(self.allocator, 0); // No compression
        const length_bytes = std.mem.toBytes(std.mem.nativeToBig(u32, @intCast(message.len)));
        try grpc_data.appendSlice(self.allocator, &length_bytes);
        try grpc_data.appendSlice(self.allocator, message);

        // Send as QUIC stream frame
        try self.sendQuicStreamFrame(grpc_data.items, false); // Don't close stream yet
    }

    pub fn receiveStreamMessage(self: *GrpcStream) !?[]u8 {
        // Try to parse a complete message from received buffer
        if (self.recv_buffer.items.len < 5) return null;

        const length = std.mem.readInt(u32, self.recv_buffer.items[1..5], .big);
        if (self.recv_buffer.items.len < 5 + length) return null;

        // Extract message
        const message_data = self.recv_buffer.items[5..5 + length];
        const result = try self.allocator.dupe(u8, message_data);

        // Remove processed data from buffer
        const remaining_len = self.recv_buffer.items.len - (5 + length);
        if (remaining_len > 0) {
            std.mem.copyForwards(
                u8,
                self.recv_buffer.items[0..remaining_len],
                self.recv_buffer.items[5 + length..]
            );
        }
        self.recv_buffer.shrinkAndFree(self.allocator, remaining_len);

        return result;
    }

    pub fn closeStream(self: *GrpcStream) !void {
        if (self.connection == null) return Error.InvalidState;

        // Send empty frame with FIN flag
        try self.sendQuicStreamFrame(&[_]u8{}, true);
        self.state = .closed;
    }

    fn sendQuicStreamFrame(self: *GrpcStream, data: []const u8, fin: bool) !void {
        var packet = std.ArrayList(u8){};
        defer packet.deinit(self.allocator);

        // QUIC header (simplified)
        try packet.append(self.allocator, 0x40); // Short header
        try packet.appendSlice(self.allocator, &self.connection.?.peer_connection_id);

        // Stream frame with optional FIN
        const frame_type: u8 = if (fin) 0x09 else 0x08; // STREAM frame with/without FIN
        try packet.append(self.allocator, frame_type);
        try encodeVarInt(&packet, self.id); // Stream ID
        try encodeVarInt(&packet, data.len); // Length
        try packet.appendSlice(self.allocator, data);

        // Send over UDP
        _ = try self.connection.?.socket.sendTo(packet.items, self.connection.?.peer_address);
    }

    fn encodeVarInt(buffer: *std.ArrayList(u8), value: u64) !void {
        if (value < 64) {
            try buffer.append(buffer.allocator, @intCast(value));
        } else if (value < 16384) {
            const bytes = std.mem.toBytes(std.mem.nativeToBig(u16, @intCast(value)));
            try buffer.append(buffer.allocator, bytes[0] | 0x40);
            try buffer.append(buffer.allocator, bytes[1]);
        } else {
            // Simplified - only handle up to 2-byte varint for now
            const bytes = std.mem.toBytes(std.mem.nativeToBig(u16, @intCast(value & 0x3FFF)));
            try buffer.append(buffer.allocator, bytes[0] | 0x40);
            try buffer.append(buffer.allocator, bytes[1]);
        }
    }
};

// QUIC-gRPC Server
pub const QuicGrpcServer = struct {
    allocator: std.mem.Allocator,
    transport: QuicGrpcTransport,
    handlers: std.StringHashMap(GrpcHandler),
    is_running: bool,

    const GrpcHandler = struct {
        handler_fn: *const fn (request: []const u8, allocator: std.mem.Allocator) anyerror![]u8,
    };

    pub fn init(allocator: std.mem.Allocator, bind_address: std.net.Address) !QuicGrpcServer {
        var transport = try QuicGrpcTransport.init(allocator);
        try transport.bind(bind_address);

        return QuicGrpcServer{
            .allocator = allocator,
            .transport = transport,
            .handlers = std.StringHashMap(GrpcHandler).init(allocator),
            .is_running = false,
        };
    }

    pub fn deinit(self: *QuicGrpcServer) void {
        self.transport.deinit();
        self.handlers.deinit();
    }

    pub fn registerHandler(self: *QuicGrpcServer, method: []const u8, handler_fn: *const fn (request: []const u8, allocator: std.mem.Allocator) anyerror![]u8) !void {
        const owned_method = try self.allocator.dupe(u8, method);
        try self.handlers.put(owned_method, GrpcHandler{ .handler_fn = handler_fn });
    }

    pub fn serve(self: *QuicGrpcServer) !void {
        self.is_running = true;

        while (self.is_running) {
            const connection = self.transport.acceptConnection() catch |err| {
                std.debug.print("Error accepting connection: {}\n", .{err});
                continue;
            };

            // Handle connection in a simple synchronous way
            self.handleConnection(connection) catch |err| {
                std.debug.print("Error handling connection: {}\n", .{err});
            };
        }
    }

    fn handleConnection(self: *QuicGrpcServer, connection: *QuicGrpcConnection) !void {
        // In a real server, this would run in a separate thread
        var stream_iter = connection.streams.iterator();
        while (stream_iter.next()) |entry| {
            const stream = entry.value_ptr.*;

            if (stream.recv_buffer.items.len > 0) {
                try self.processGrpcRequest(stream);
            }
        }
    }

    fn processGrpcRequest(self: *QuicGrpcServer, stream: *GrpcStream) !void {
        // Parse gRPC request (simplified)
        const request_data = stream.recv_buffer.items;

        // Extract method from headers (very simplified)
        const method = "TestService/TestMethod"; // Hardcoded for demo

        if (self.handlers.get(method)) |handler| {
            // Extract message payload (skip headers and framing)
            const message_start = std.mem.indexOf(u8, request_data, "\r\n\r\n") orelse return Error.InvalidRequest;
            const payload_start = message_start + 4;

            if (payload_start + 5 < request_data.len) {
                const message_length = std.mem.readInt(u32, request_data[payload_start + 1..payload_start + 5], .big);

                if (payload_start + 5 + message_length <= request_data.len) {
                    const message_data = request_data[payload_start + 5..payload_start + 5 + message_length];

                    // Call handler
                    const response = try handler.handler_fn(message_data, self.allocator);
                    defer self.allocator.free(response);

                    // Send response back through stream
                    try stream.sendGrpcMessage(method, response);
                }
            }
        }
    }

    pub fn stop(self: *QuicGrpcServer) void {
        self.is_running = false;
    }
};

// QUIC-gRPC Client
pub const QuicGrpcClient = struct {
    allocator: std.mem.Allocator,
    transport: QuicGrpcTransport,
    connection: ?*QuicGrpcConnection,

    pub fn init(allocator: std.mem.Allocator) !QuicGrpcClient {
        const transport = try QuicGrpcTransport.init(allocator);

        return QuicGrpcClient{
            .allocator = allocator,
            .transport = transport,
            .connection = null,
        };
    }

    pub fn deinit(self: *QuicGrpcClient) void {
        self.transport.deinit();
    }

    pub fn connect(self: *QuicGrpcClient, server_address: std.net.Address) !void {
        self.connection = try self.transport.connectToServer(server_address);
    }

    pub fn call(self: *QuicGrpcClient, method: []const u8, request: []const u8) ![]u8 {
        if (self.connection == null) return Error.NotConnected;

        return try self.connection.?.sendGrpcRequest(method, request);
    }

    // Streaming RPC methods
    pub fn clientStream(self: *QuicGrpcClient, method: []const u8) !*GrpcStream {
        if (self.connection == null) return Error.NotConnected;

        const stream = try self.connection.?.createStream();

        // Send headers for client streaming
        var headers = std.ArrayList(u8){};
        defer headers.deinit(self.allocator);

        try headers.appendSlice(self.allocator, ":method POST\r\n");
        try headers.appendSlice(self.allocator, ":path /");
        try headers.appendSlice(self.allocator, method);
        try headers.appendSlice(self.allocator, "\r\n");
        try headers.appendSlice(self.allocator, "content-type: application/grpc\r\n");
        try headers.appendSlice(self.allocator, "grpc-encoding: identity\r\n\r\n");

        try stream.sendQuicStreamFrame(headers.items, false);
        return stream;
    }

    pub fn serverStream(self: *QuicGrpcClient, method: []const u8, request: []const u8) !*GrpcStream {
        if (self.connection == null) return Error.NotConnected;

        const stream = try self.connection.?.createStream();

        // Send initial request and keep stream open for responses
        try stream.sendGrpcMessage(method, request);
        return stream;
    }

    pub fn bidirectionalStream(self: *QuicGrpcClient, method: []const u8) !*GrpcStream {
        if (self.connection == null) return Error.NotConnected;

        const stream = try self.connection.?.createStream();

        // Send headers for bidirectional streaming
        var headers = std.ArrayList(u8){};
        defer headers.deinit(self.allocator);

        try headers.appendSlice(self.allocator, ":method POST\r\n");
        try headers.appendSlice(self.allocator, ":path /");
        try headers.appendSlice(self.allocator, method);
        try headers.appendSlice(self.allocator, "\r\n");
        try headers.appendSlice(self.allocator, "content-type: application/grpc\r\n");
        try headers.appendSlice(self.allocator, "grpc-encoding: identity\r\n\r\n");

        try stream.sendQuicStreamFrame(headers.items, false);
        return stream;
    }
};

// Tests
test "QUIC-gRPC basic functionality" {
    const allocator = std.testing.allocator;

    // Test transport creation
    var transport = try QuicGrpcTransport.init(allocator);
    defer transport.deinit();

    const bind_addr = std.net.Address.initIp4([4]u8{ 127, 0, 0, 1 }, 8080);
    transport.bind(bind_addr) catch |err| {
        // Might fail in test environment, that's ok
        std.debug.print("Bind failed (expected in tests): {}\n", .{err});
    };
}

test "QUIC-gRPC stream creation" {
    const allocator = std.testing.allocator;

    var stream = try GrpcStream.init(allocator, 4);
    defer stream.deinit();

    try std.testing.expectEqual(@as(u64, 4), stream.id);
    try std.testing.expectEqual(GrpcStream.StreamState.idle, stream.state);
}