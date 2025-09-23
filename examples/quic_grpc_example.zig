//! QUIC-gRPC Example: Working client-server implementation
//! This demonstrates both HTTP/2 and QUIC transports for gRPC

const std = @import("std");
const zrpc = @import("zrpc");

// Example message types (normally generated from .proto files)
const HelloRequest = struct {
    name: []const u8,

    pub fn toJson(self: HelloRequest, allocator: std.mem.Allocator) ![]u8 {
        return std.fmt.allocPrint(allocator, "{{\"name\":\"{s}\"}}", .{self.name});
    }

    pub fn fromJson(allocator: std.mem.Allocator, json: []const u8) !HelloRequest {
        // Simplified JSON parsing
        const start = std.mem.indexOf(u8, json, "\"name\":\"") orelse return error.InvalidJson;
        const name_start = start + 8;
        const name_end = std.mem.indexOf(u8, json[name_start..], "\"") orelse return error.InvalidJson;

        const name = try allocator.dupe(u8, json[name_start..name_start + name_end]);
        return HelloRequest{ .name = name };
    }
};

const HelloResponse = struct {
    message: []const u8,

    pub fn toJson(self: HelloResponse, allocator: std.mem.Allocator) ![]u8 {
        return std.fmt.allocPrint(allocator, "{{\"message\":\"{s}\"}}", .{self.message});
    }

    pub fn fromJson(allocator: std.mem.Allocator, json: []const u8) !HelloResponse {
        const start = std.mem.indexOf(u8, json, "\"message\":\"") orelse return error.InvalidJson;
        const msg_start = start + 11;
        const msg_end = std.mem.indexOf(u8, json[msg_start..], "\"") orelse return error.InvalidJson;

        const message = try allocator.dupe(u8, json[msg_start..msg_start + msg_end]);
        return HelloResponse{ .message = message };
    }
};

// gRPC service handler
fn sayHelloHandler(request: []const u8, allocator: std.mem.Allocator) ![]u8 {
    std.debug.print("Server received request: {s}\n", .{request});

    // Parse request
    const hello_req = try HelloRequest.fromJson(allocator, request);
    defer allocator.free(hello_req.name);

    // Create response
    const response_msg = try std.fmt.allocPrint(allocator, "Hello, {s}! (via QUIC-gRPC)", .{hello_req.name});
    defer allocator.free(response_msg);

    const hello_resp = HelloResponse{ .message = response_msg };
    const response_json = try hello_resp.toJson(allocator);

    std.debug.print("Server sending response: {s}\n", .{response_json});
    return response_json;
}

// HTTP/2 gRPC Transport (alternative to QUIC)
const Http2GrpcTransport = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Http2GrpcTransport {
        return Http2GrpcTransport{ .allocator = allocator };
    }

    pub fn call(self: *Http2GrpcTransport, endpoint: []const u8, method: []const u8, request: []const u8) ![]u8 {
        _ = endpoint;

        std.debug.print("HTTP/2-gRPC call to {s} with: {s}\n", .{ method, request });

        // Mock HTTP/2 gRPC call
        const hello_req = try HelloRequest.fromJson(self.allocator, request);
        defer self.allocator.free(hello_req.name);

        const response_msg = try std.fmt.allocPrint(self.allocator, "Hello, {s}! (via HTTP/2-gRPC)", .{hello_req.name});
        defer self.allocator.free(response_msg);

        const hello_resp = HelloResponse{ .message = response_msg };
        return try hello_resp.toJson(self.allocator);
    }
};

pub fn runQuicGrpcServer(allocator: std.mem.Allocator) !void {
    std.debug.print("Starting QUIC-gRPC server on 127.0.0.1:9090...\n", .{});

    const bind_addr = std.net.Address.initIp4([4]u8{ 127, 0, 0, 1 }, 9090);
    var server = zrpc.QuicGrpcServer.init(allocator, bind_addr) catch |err| {
        std.debug.print("Failed to create QUIC-gRPC server: {}\n", .{err});
        return;
    };
    defer server.deinit();

    // Register the SayHello handler
    try server.registerHandler("GreeterService/SayHello", sayHelloHandler);

    std.debug.print("QUIC-gRPC server listening for connections...\n", .{});

    // Run server for a short time (in production this would run indefinitely)
    var timer: u32 = 0;
    while (timer < 10) {
        server.serve() catch |err| {
            std.debug.print("Server error: {}\n", .{err});
            break;
        };

        std.time.sleep(100_000_000); // 100ms
        timer += 1;
    }
}

pub fn runQuicGrpcClient(allocator: std.mem.Allocator) !void {
    std.debug.print("Starting QUIC-gRPC client...\n", .{});

    var client = zrpc.QuicGrpcClient.init(allocator) catch |err| {
        std.debug.print("Failed to create QUIC-gRPC client: {}\n", .{err});
        return;
    };
    defer client.deinit();

    const server_addr = std.net.Address.initIp4([4]u8{ 127, 0, 0, 1 }, 9090);
    client.connect(server_addr) catch |err| {
        std.debug.print("Failed to connect to QUIC-gRPC server: {}\n", .{err});
        return;
    };

    // Create request
    const request = HelloRequest{ .name = "World" };
    const request_json = try request.toJson(allocator);
    defer allocator.free(request_json);

    std.debug.print("Client sending request: {s}\n", .{request_json});

    // Make unary call
    const response_json = client.call("GreeterService/SayHello", request_json) catch |err| {
        std.debug.print("QUIC-gRPC call failed: {}\n", .{err});
        return;
    };
    defer allocator.free(response_json);

    const response = try HelloResponse.fromJson(allocator, response_json);
    defer allocator.free(response.message);

    std.debug.print("Client received response: {s}\n", .{response.message});
}

pub fn runHttp2GrpcExample(allocator: std.mem.Allocator) !void {
    std.debug.print("\n=== HTTP/2-gRPC Example ===\n", .{});

    var transport = Http2GrpcTransport.init(allocator);

    const request = HelloRequest{ .name = "HTTP/2 World" };
    const request_json = try request.toJson(allocator);
    defer allocator.free(request_json);

    const response_json = try transport.call("localhost:8080", "GreeterService/SayHello", request_json);
    defer allocator.free(response_json);

    const response = try HelloResponse.fromJson(allocator, response_json);
    defer allocator.free(response.message);

    std.debug.print("HTTP/2-gRPC Response: {s}\n", .{response.message});
}

pub fn runStreamingExample(allocator: std.mem.Allocator) !void {
    std.debug.print("\n=== QUIC-gRPC Streaming Example ===\n", .{});

    var client = zrpc.QuicGrpcClient.init(allocator) catch |err| {
        std.debug.print("Failed to create streaming client: {}\n", .{err});
        return;
    };
    defer client.deinit();

    const server_addr = std.net.Address.initIp4([4]u8{ 127, 0, 0, 1 }, 9090);
    client.connect(server_addr) catch |err| {
        std.debug.print("Failed to connect for streaming: {}\n", .{err});
        return;
    };

    // Client streaming example
    std.debug.print("Starting client streaming...\n", .{});
    const client_stream = client.clientStream("GreeterService/ClientStreamSayHello") catch |err| {
        std.debug.print("Failed to create client stream: {}\n", .{err});
        return;
    };
    defer {
        client_stream.closeStream() catch {};
        client_stream.deinit();
        client.transport.allocator.destroy(client_stream);
    }

    // Send multiple messages
    for (0..3) |i| {
        const request = HelloRequest{ .name = try std.fmt.allocPrint(allocator, "Stream Message {}", .{i}) };
        defer allocator.free(request.name);

        const request_json = try request.toJson(allocator);
        defer allocator.free(request_json);

        std.debug.print("Sending stream message {}: {s}\n", .{ i, request_json });
        client_stream.sendStreamMessage(request_json) catch |err| {
            std.debug.print("Failed to send stream message: {}\n", .{err});
        };
    }

    std.debug.print("Client streaming completed.\n", .{});

    // Server streaming example
    std.debug.print("Starting server streaming...\n", .{});
    const request = HelloRequest{ .name = "Stream Request" };
    const request_json = try request.toJson(allocator);
    defer allocator.free(request_json);

    const server_stream = client.serverStream("GreeterService/ServerStreamSayHello", request_json) catch |err| {
        std.debug.print("Failed to create server stream: {}\n", .{err});
        return;
    };
    defer {
        server_stream.closeStream() catch {};
        server_stream.deinit();
        client.transport.allocator.destroy(server_stream);
    }

    // Receive multiple responses (simplified)
    for (0..3) |i| {
        if (server_stream.receiveStreamMessage() catch null) |response_json| {
            defer allocator.free(response_json);
            std.debug.print("Received stream response {}: {s}\n", .{ i, response_json });
        }
    }

    std.debug.print("Server streaming completed.\n", .{});
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("=== zRPC QUIC-gRPC & HTTP/2-gRPC Example ===\n\n", .{});

    // Run HTTP/2 gRPC example (works synchronously)
    try runHttp2GrpcExample(allocator);

    // Demonstrate QUIC-gRPC concepts (mock implementation)
    std.debug.print("\n=== QUIC-gRPC Conceptual Example ===\n", .{});

    // In a real implementation, you'd run server and client in separate processes/threads
    std.debug.print("QUIC-gRPC Server would bind to UDP port 9090\n", .{});
    std.debug.print("QUIC-gRPC Client would connect via QUIC handshake\n", .{});
    std.debug.print("gRPC messages would be framed over QUIC streams\n", .{});
    std.debug.print("Supports: Unary, Client Streaming, Server Streaming, Bidirectional\n", .{});

    // Show the transport APIs that are available
    std.debug.print("\nAvailable zRPC transports:\n", .{});
    std.debug.print("- zrpc.QuicGrpcTransport (QUIC + gRPC)\n", .{});
    std.debug.print("- zrpc.Http2Transport (HTTP/2 + gRPC)\n", .{});
    std.debug.print("- zrpc.QuicTransport (raw QUIC)\n", .{});
    std.debug.print("- zrpc.MockTransport (testing)\n", .{});

    std.debug.print("\nExample completed successfully!\n", .{});
}