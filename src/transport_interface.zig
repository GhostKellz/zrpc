//! Transport adapter interface - strict SPI for pluggable transports
//! This defines the minimal contract between zrpc-core and transport adapters

const std = @import("std");

/// Standard error set that all transports must map to
pub const TransportError = error{
    Timeout,
    Canceled,
    Closed,
    ConnectionReset,
    Temporary,
    ResourceExhausted,
    Protocol,
    InvalidArgument,
    NotConnected,
    InvalidState,
    OutOfMemory,
};

/// TLS configuration passed through to transport adapters
pub const TlsConfig = struct {
    cert_file: ?[]const u8 = null,
    key_file: ?[]const u8 = null,
    ca_file: ?[]const u8 = null,
    server_name: ?[]const u8 = null,
    alpn_protocols: []const []const u8 = &.{"h2", "h3"},
    verify_peer: bool = true,
};

/// Frame types for RPC communication
pub const FrameType = enum(u8) {
    data = 0x0,
    headers = 0x1,
    status = 0x2,
    cancel = 0x3,
    keepalive = 0x4,
    metadata = 0x5,
};

/// Frame for RPC communication - minimal envelope
pub const Frame = struct {
    frame_type: FrameType,
    flags: u8,
    data: []u8,
    allocator: std.mem.Allocator,

    pub const Flags = struct {
        pub const END_STREAM: u8 = 0x1;
        pub const END_HEADERS: u8 = 0x4;
    };

    pub fn init(allocator: std.mem.Allocator, frame_type: FrameType, flags: u8, data: []const u8) !Frame {
        const owned_data = try allocator.dupe(u8, data);
        return Frame{
            .frame_type = frame_type,
            .flags = flags,
            .data = owned_data,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Frame) void {
        self.allocator.free(self.data);
    }
};

/// Stream interface - represents a single RPC stream
pub const Stream = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        writeFrame: *const fn (ptr: *anyopaque, frame_type: FrameType, flags: u8, data: []const u8) TransportError!void,
        readFrame: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator) TransportError!Frame,
        cancel: *const fn (ptr: *anyopaque) void,
        close: *const fn (ptr: *anyopaque) void,
    };

    pub fn writeFrame(self: Stream, frame_type: FrameType, flags: u8, data: []const u8) TransportError!void {
        return self.vtable.writeFrame(self.ptr, frame_type, flags, data);
    }

    pub fn readFrame(self: Stream, allocator: std.mem.Allocator) TransportError!Frame {
        return self.vtable.readFrame(self.ptr, allocator);
    }

    pub fn cancel(self: Stream) void {
        self.vtable.cancel(self.ptr);
    }

    pub fn close(self: Stream) void {
        self.vtable.close(self.ptr);
    }
};

/// Connection interface - manages multiple streams
pub const Connection = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        openStream: *const fn (ptr: *anyopaque) TransportError!Stream,
        close: *const fn (ptr: *anyopaque) void,
        ping: *const fn (ptr: *anyopaque) TransportError!void,
        isConnected: *const fn (ptr: *anyopaque) bool,
    };

    pub fn openStream(self: Connection) TransportError!Stream {
        return self.vtable.openStream(self.ptr);
    }

    pub fn close(self: Connection) void {
        self.vtable.close(self.ptr);
    }

    pub fn ping(self: Connection) TransportError!void {
        return self.vtable.ping(self.ptr);
    }

    pub fn isConnected(self: Connection) bool {
        return self.vtable.isConnected(self.ptr);
    }
};

/// Transport adapter interface - creates connections
pub const Transport = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        connect: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, endpoint: []const u8, tls_config: ?*const TlsConfig) TransportError!Connection,
        listen: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, bind_address: []const u8, tls_config: ?*const TlsConfig) TransportError!Listener,
        deinit: *const fn (ptr: *anyopaque) void,
    };

    pub fn connect(self: Transport, allocator: std.mem.Allocator, endpoint: []const u8, tls_config: ?*const TlsConfig) TransportError!Connection {
        return self.vtable.connect(self.ptr, allocator, endpoint, tls_config);
    }

    pub fn listen(self: Transport, allocator: std.mem.Allocator, bind_address: []const u8, tls_config: ?*const TlsConfig) TransportError!Listener {
        return self.vtable.listen(self.ptr, allocator, bind_address, tls_config);
    }

    pub fn deinit(self: Transport) void {
        self.vtable.deinit(self.ptr);
    }
};

/// Listener interface - accepts incoming connections
pub const Listener = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        accept: *const fn (ptr: *anyopaque) TransportError!Connection,
        close: *const fn (ptr: *anyopaque) void,
    };

    pub fn accept(self: Listener) TransportError!Connection {
        return self.vtable.accept(self.ptr);
    }

    pub fn close(self: Listener) void {
        self.vtable.close(self.ptr);
    }
};

/// Helper to create transport implementations
pub fn createTransport(comptime T: type, impl: *T) Transport {
    const Impl = struct {
        pub fn connect(ptr: *anyopaque, allocator: std.mem.Allocator, endpoint: []const u8, tls_config: ?*const TlsConfig) TransportError!Connection {
            const self: *T = @ptrCast(@alignCast(ptr));
            return self.connect(allocator, endpoint, tls_config);
        }

        pub fn listen(ptr: *anyopaque, allocator: std.mem.Allocator, bind_address: []const u8, tls_config: ?*const TlsConfig) TransportError!Listener {
            const self: *T = @ptrCast(@alignCast(ptr));
            return self.listen(allocator, bind_address, tls_config);
        }

        pub fn deinit(ptr: *anyopaque) void {
            const self: *T = @ptrCast(@alignCast(ptr));
            self.deinit();
        }

        const vtable = Transport.VTable{
            .connect = connect,
            .listen = listen,
            .deinit = deinit,
        };
    };

    return Transport{
        .ptr = impl,
        .vtable = &Impl.vtable,
    };
}

test "transport interface basic usage" {
    // Mock implementation for testing
    const MockTransport = struct {
        allocator: std.mem.Allocator,

        pub fn connect(self: *@This(), allocator: std.mem.Allocator, endpoint: []const u8, tls_config: ?*const TlsConfig) TransportError!Connection {
            _ = self;
            _ = allocator;
            _ = endpoint;
            _ = tls_config;
            return TransportError.NotConnected; // Mock implementation
        }

        pub fn listen(self: *@This(), allocator: std.mem.Allocator, bind_address: []const u8, tls_config: ?*const TlsConfig) TransportError!Listener {
            _ = self;
            _ = allocator;
            _ = bind_address;
            _ = tls_config;
            return TransportError.NotConnected; // Mock implementation
        }

        pub fn deinit(self: *@This()) void {
            _ = self;
        }
    };

    var mock_impl = MockTransport{ .allocator = std.testing.allocator };
    const transport = createTransport(MockTransport, &mock_impl);

    const result = transport.connect(std.testing.allocator, "localhost:8080", null);
    try std.testing.expectError(TransportError.NotConnected, result);
}