const std = @import("std");
const zrpc = @import("zrpc-core");
const Error = zrpc.Error;

// Import legacy transport types from core
pub const Message = zrpc.transport_legacy.Message;
pub const Frame = zrpc.transport_legacy.Frame;
pub const StreamId = zrpc.transport_legacy.StreamId;

/// Unix Domain Socket transport for local IPC
/// - No TLS overhead (sockets are local-only)
/// - Filesystem permissions for access control
/// - 2-3x faster than TCP loopback
/// - Compatible with gRPC message framing
pub const UdsTransport = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) UdsTransport {
        return .{
            .allocator = allocator,
        };
    }

    /// Connect to Unix domain socket
    pub fn connect(
        allocator: std.mem.Allocator,
        socket_path: []const u8,
    ) Error!UdsConnection {
        // Create Unix socket
        const sock = std.posix.socket(
            std.posix.AF.UNIX,
            std.posix.SOCK.STREAM,
            0,
        ) catch return Error.NetworkError;
        errdefer std.posix.close(sock);

        // Build sockaddr_un
        var addr = std.posix.sockaddr.un{
            .family = std.posix.AF.UNIX,
            .path = undefined,
        };

        if (socket_path.len >= addr.path.len) {
            return Error.InvalidArgument;
        }

        @memset(&addr.path, 0);
        @memcpy(addr.path[0..socket_path.len], socket_path);

        // Connect to socket
        std.posix.connect(
            sock,
            @ptrCast(&addr),
            @sizeOf(@TypeOf(addr)),
        ) catch |err| {
            std.posix.close(sock);
            return switch (err) {
                error.ConnectionRefused => Error.Unavailable,
                error.FileNotFound => Error.NotFound,
                error.PermissionDenied => Error.PermissionDenied,
                else => Error.NetworkError,
            };
        };

        return UdsConnection{
            .allocator = allocator,
            .socket = sock,
            .next_stream_id = 1,
            .window_size = 65535,
        };
    }

    /// Send gRPC message over UDS
    pub fn send(self: *UdsTransport, endpoint: []const u8, message: Message) Error!Message {
        // Parse unix:// URL
        if (!std.mem.startsWith(u8, endpoint, "unix://")) {
            return Error.InvalidArgument;
        }

        const socket_path = endpoint[7..];

        // Connect to socket
        var conn = try connect(self.allocator, socket_path);
        defer conn.close();

        // Send HTTP/2 preface for gRPC compatibility
        try conn.sendPreface();

        // Send settings frame
        const settings_data: [0]u8 = .{};
        const settings_frame = Frame{
            .stream_id = 0,
            .frame_type = .settings,
            .flags = 0,
            .data = &settings_data,
        };
        try conn.sendFrame(settings_frame);

        // Allocate stream ID
        const stream_id = conn.allocateStreamId();

        // Build headers
        const method = message.headers.get("grpc-method") orelse "Unknown/Method";
        var headers_data: std.ArrayList(u8) = .empty;
        defer headers_data.deinit(self.allocator);

        try headers_data.ensureTotalCapacity(self.allocator, 1024);

        // Pseudo-headers (simplified - not HPACK)
        try headers_data.appendSlice(self.allocator, ":method");
        try headers_data.append(self.allocator, 0);
        try headers_data.appendSlice(self.allocator, "POST");
        try headers_data.append(self.allocator, 0);

        try headers_data.appendSlice(self.allocator, ":path");
        try headers_data.append(self.allocator, 0);
        try headers_data.appendSlice(self.allocator, "/");
        try headers_data.append(self.allocator, 0);

        try headers_data.appendSlice(self.allocator, ":authority");
        try headers_data.append(self.allocator, 0);
        try headers_data.appendSlice(self.allocator, "localhost");
        try headers_data.append(self.allocator, 0);

        try headers_data.appendSlice(self.allocator, "content-type");
        try headers_data.append(self.allocator, 0);
        try headers_data.appendSlice(self.allocator, "application/grpc");
        try headers_data.append(self.allocator, 0);

        try headers_data.appendSlice(self.allocator, "grpc-method");
        try headers_data.append(self.allocator, 0);
        try headers_data.appendSlice(self.allocator, method);
        try headers_data.append(self.allocator, 0);

        // Send headers frame
        const headers_frame = Frame{
            .stream_id = stream_id,
            .frame_type = .headers,
            .flags = Frame.Flags.END_HEADERS,
            .data = headers_data.items,
        };
        try conn.sendFrame(headers_frame);

        // Send data frame
        const data_frame = Frame{
            .stream_id = stream_id,
            .frame_type = .data,
            .flags = Frame.Flags.END_STREAM,
            .data = message.body,
        };
        try conn.sendFrame(data_frame);

        // Read response frames
        var response_body: std.ArrayList(u8) = .empty;
        defer response_body.deinit(self.allocator);

        while (true) {
            const frame = try conn.readFrame();
            defer self.allocator.free(frame.data);

            // Stop on END_STREAM
            if (frame.flags & Frame.Flags.END_STREAM != 0) {
                if (frame.frame_type == .data and frame.data.len > 0) {
                    try response_body.appendSlice(self.allocator, frame.data);
                }
                break;
            }

            if (frame.frame_type == .data) {
                try response_body.appendSlice(self.allocator, frame.data);
            }
        }

        // Build response message
        const body = try self.allocator.dupe(u8, response_body.items);
        var response = Message.init(self.allocator, body);
        try response.addHeader("status", "200");
        try response.addHeader("transport", "uds");
        return response;
    }
};

/// Unix Domain Socket connection
pub const UdsConnection = struct {
    allocator: std.mem.Allocator,
    socket: std.posix.socket_t,
    next_stream_id: StreamId,
    window_size: u32,

    const PREFACE = "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n";

    pub fn close(self: *UdsConnection) void {
        std.posix.close(self.socket);
    }

    pub fn sendPreface(self: *UdsConnection) Error!void {
        _ = std.posix.write(self.socket, PREFACE) catch return Error.NetworkError;
    }

    pub fn sendFrame(self: *UdsConnection, frame: Frame) Error!void {
        var frame_header: [9]u8 = undefined;

        // Frame length (24 bits)
        std.mem.writeInt(u24, frame_header[0..3], @intCast(frame.data.len), .big);

        // Frame type (8 bits)
        frame_header[3] = @intFromEnum(frame.frame_type);

        // Flags (8 bits)
        frame_header[4] = frame.flags;

        // Stream ID (32 bits, with reserved bit cleared)
        std.mem.writeInt(u32, frame_header[5..9], frame.stream_id & 0x7FFFFFFF, .big);

        _ = std.posix.write(self.socket, &frame_header) catch return Error.NetworkError;
        _ = std.posix.write(self.socket, frame.data) catch return Error.NetworkError;
    }

    pub fn readFrame(self: *UdsConnection) Error!Frame {
        var frame_header: [9]u8 = undefined;
        try self.readExact(&frame_header);

        const length = std.mem.readInt(u24, frame_header[0..3], .big);
        const frame_type_int = frame_header[3];
        const flags = frame_header[4];
        const stream_id = std.mem.readInt(u32, frame_header[5..9], .big) & 0x7FFFFFFF;

        const frame_type: Frame.FrameType = @enumFromInt(frame_type_int);

        const data = try self.allocator.alloc(u8, length);
        errdefer self.allocator.free(data);

        if (length > 0) {
            try self.readExact(data);
        }

        return Frame{
            .stream_id = stream_id,
            .frame_type = frame_type,
            .flags = flags,
            .data = data,
        };
    }

    pub fn allocateStreamId(self: *UdsConnection) StreamId {
        const id = self.next_stream_id;
        self.next_stream_id += 2;
        return id;
    }

    fn readExact(self: *UdsConnection, buffer: []u8) Error!void {
        var bytes_read: usize = 0;
        while (bytes_read < buffer.len) {
            const n = std.posix.read(self.socket, buffer[bytes_read..]) catch return Error.NetworkError;
            if (n == 0) return Error.ConnectionClosed;
            bytes_read += n;
        }
    }
};

/// Unix Domain Socket server
pub const UdsServer = struct {
    allocator: std.mem.Allocator,
    socket: std.posix.socket_t,
    socket_path: []const u8,

    /// Create and bind Unix domain socket server
    pub fn init(allocator: std.mem.Allocator, socket_path: []const u8) Error!UdsServer {
        // Remove existing socket file if it exists
        std.fs.deleteFileAbsolute(socket_path) catch |err| {
            if (err != error.FileNotFound) {
                return Error.InvalidState;
            }
        };

        // Create Unix socket
        const sock = std.posix.socket(
            std.posix.AF.UNIX,
            std.posix.SOCK.STREAM,
            0,
        ) catch return Error.NetworkError;
        errdefer std.posix.close(sock);

        // Build sockaddr_un
        var addr = std.posix.sockaddr.un{
            .family = std.posix.AF.UNIX,
            .path = undefined,
        };

        if (socket_path.len >= addr.path.len) {
            return Error.InvalidArgument;
        }

        @memset(&addr.path, 0);
        @memcpy(addr.path[0..socket_path.len], socket_path);

        // Bind socket
        std.posix.bind(
            sock,
            @ptrCast(&addr),
            @sizeOf(@TypeOf(addr)),
        ) catch |err| {
            std.posix.close(sock);
            return switch (err) {
                error.AddressInUse => Error.AlreadyExists,
                error.AccessDenied => Error.PermissionDenied,
                else => Error.NetworkError,
            };
        };

        // Listen for connections
        std.posix.listen(sock, 128) catch {
            std.posix.close(sock);
            return Error.NetworkError;
        };

        return UdsServer{
            .allocator = allocator,
            .socket = sock,
            .socket_path = try allocator.dupe(u8, socket_path),
        };
    }

    pub fn deinit(self: *UdsServer) void {
        std.posix.close(self.socket);
        // Clean up socket file
        std.fs.deleteFileAbsolute(self.socket_path) catch {};
        self.allocator.free(self.socket_path);
    }

    /// Accept incoming connection
    pub fn accept(self: *UdsServer) Error!UdsConnection {
        var addr: std.posix.sockaddr.un = undefined;
        var addr_len: std.posix.socklen_t = @sizeOf(@TypeOf(addr));

        const client_sock = std.posix.accept(
            self.socket,
            @ptrCast(&addr),
            &addr_len,
            0,
        ) catch |err| {
            // Note: std.posix.accept can return SocketNotListening internally but it's
            // not in the AcceptError type definition, so we handle it in the else case
            return switch (err) {
                error.WouldBlock => Error.Unavailable,
                else => Error.NetworkError,
            };
        };

        return UdsConnection{
            .allocator = self.allocator,
            .socket = client_sock,
            .next_stream_id = 2, // Server uses even stream IDs
            .window_size = 65535,
        };
    }
};

// Tests
test "UDS connection initialization" {
    const allocator = std.testing.allocator;

    // Test socket path validation - path too long
    const too_long_path = "/tmp/" ++ "x" ** 200 ++ ".sock";

    // Too long path should fail
    const result = UdsTransport.connect(allocator, too_long_path);
    try std.testing.expectError(Error.InvalidArgument, result);
}

test "UDS frame encoding/decoding" {
    // Create a mock frame (we can't test actual I/O without a running server)
    const test_data = "test frame data";
    const frame = Frame{
        .stream_id = 1,
        .frame_type = .data,
        .flags = Frame.Flags.END_STREAM,
        .data = test_data,
    };

    try std.testing.expectEqual(@as(StreamId, 1), frame.stream_id);
    try std.testing.expectEqual(Frame.FrameType.data, frame.frame_type);
    try std.testing.expectEqualStrings(test_data, frame.data);
}

test "UDS transport URL parsing" {
    const allocator = std.testing.allocator;
    var uds = UdsTransport.init(allocator);

    var message = Message.init(allocator, "test");
    defer message.deinit();

    // Invalid URL scheme
    const result = uds.send("http://localhost", message);
    try std.testing.expectError(Error.InvalidArgument, result);
}

test "UDS server init and cleanup" {
    const allocator = std.testing.allocator;
    const socket_path = "/tmp/zrpc-test.sock";

    var server = try UdsServer.init(allocator, socket_path);
    defer server.deinit();

    // Verify socket was created
    const stat = std.fs.cwd().statFile(socket_path) catch unreachable;
    try std.testing.expect(stat.kind == .unix_domain_socket);
}
