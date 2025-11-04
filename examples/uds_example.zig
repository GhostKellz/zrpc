const std = @import("std");
const zrpc = @import("zrpc-core");
const uds = @import("zrpc-transport-uds");

/// Example: Unix Domain Socket transport for high-performance local IPC
/// Use cases:
/// - Local service communication (e.g., zeke daemon ↔ zeke CLI)
/// - Plugin systems (e.g., gshell plugins)
/// - MCP server communication (e.g., glyph tools)
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.log.info("=== zRPC Unix Domain Socket Example ===", .{});

    // Configuration
    const socket_path = "/tmp/zrpc-example.sock";

    // Start server in separate thread
    const server_thread = try std.Thread.spawn(.{}, runServer, .{ allocator, socket_path });
    defer server_thread.join();

    // Give server time to start
    std.posix.nanosleep(0, 100 * 1000 * 1000); // 100ms

    // Run client
    try runClient(allocator, socket_path);

    std.log.info("=== Example Complete ===", .{});
}

fn runServer(allocator: std.mem.Allocator, socket_path: []const u8) !void {
    std.log.info("Starting UDS server on {s}", .{socket_path});

    var server = try uds.UdsServer.init(allocator, socket_path);
    defer server.deinit();

    std.log.info("Server listening, waiting for connections...", .{});

    // Accept one connection for this example
    var conn = try server.accept();
    defer conn.close();

    std.log.info("Client connected!", .{});

    // Read HTTP/2 preface
    var preface_buf: [24]u8 = undefined;
    const preface_len = try std.posix.read(conn.socket, &preface_buf);
    _ = preface_len;

    // Read settings frame
    const settings_frame = try conn.readFrame();
    defer allocator.free(settings_frame.data);
    std.log.info("Received SETTINGS frame", .{});

    // Send settings ACK
    const settings_ack = uds.Frame{
        .stream_id = 0,
        .frame_type = .settings,
        .flags = 0x01, // ACK
        .data = &.{},
    };
    try conn.sendFrame(settings_ack);

    // Read headers frame
    const headers_frame = try conn.readFrame();
    defer allocator.free(headers_frame.data);
    std.log.info("Received HEADERS frame on stream {d}", .{headers_frame.stream_id});

    // Read data frame
    const data_frame = try conn.readFrame();
    defer allocator.free(data_frame.data);
    std.log.info("Received DATA: {s}", .{data_frame.data});

    // Send response headers
    var response_headers: std.ArrayList(u8) = .empty;
    defer response_headers.deinit(allocator);

    try response_headers.appendSlice(allocator, ":status");
    try response_headers.append(allocator, 0);
    try response_headers.appendSlice(allocator, "200");
    try response_headers.append(allocator, 0);

    try response_headers.appendSlice(allocator, "content-type");
    try response_headers.append(allocator, 0);
    try response_headers.appendSlice(allocator, "application/grpc");
    try response_headers.append(allocator, 0);

    const resp_headers_frame = uds.Frame{
        .stream_id = headers_frame.stream_id,
        .frame_type = .headers,
        .flags = 0x04, // END_HEADERS
        .data = response_headers.items,
    };
    try conn.sendFrame(resp_headers_frame);

    // Send response data
    const response_data = "Hello from UDS server!";
    const resp_data_frame = uds.Frame{
        .stream_id = headers_frame.stream_id,
        .frame_type = .data,
        .flags = 0x01, // END_STREAM
        .data = response_data,
    };
    try conn.sendFrame(resp_data_frame);

    std.log.info("Response sent, closing connection", .{});
}

fn runClient(allocator: std.mem.Allocator, socket_path: []const u8) !void {
    std.log.info("Connecting to UDS server...", .{});

    var transport_impl = uds.UdsTransport.init(allocator);

    // Use Message type exported from UDS module
    var message = uds.Message.init(allocator, "Hello from UDS client!");
    defer message.deinit();

    try message.addHeader("grpc-method", "ExampleService/SayHello");

    const endpoint = try std.fmt.allocPrint(allocator, "unix://{s}", .{socket_path});
    defer allocator.free(endpoint);

    const response = try transport_impl.send(endpoint, message);
    defer allocator.free(response.body);

    std.log.info("Client received response: {s}", .{response.body});
}

test "UDS transport integration" {
    const allocator = std.testing.allocator;

    const socket_path = "/tmp/zrpc-test-integration.sock";

    // Clean up any existing socket
    std.fs.deleteFileAbsolute(socket_path) catch {};

    var server = try uds.UdsServer.init(allocator, socket_path);
    defer server.deinit();

    // Test that socket file was created
    const stat = try std.fs.cwd().statFile(socket_path);
    try std.testing.expect(stat.kind == .unix_domain_socket);
}
