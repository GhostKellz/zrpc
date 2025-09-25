# Transport API Reference

**Complete API documentation for zRPC transport layer interfaces**

The transport layer provides the foundation for all network communication in zRPC through a standardized Service Provider Interface (SPI).

## Core Transport Interface

### Transport

The main transport interface that all transport adapters must implement.

```zig
pub const Transport = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    const VTable = struct {
        connect: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, endpoint: []const u8, tls_config: ?*const TlsConfig) TransportError!Connection,
        deinit: *const fn (ptr: *anyopaque) void,
    };

    /// Establish a connection to the specified endpoint
    pub fn connect(self: Transport, allocator: std.mem.Allocator, endpoint: []const u8, tls_config: ?*const TlsConfig) TransportError!Connection {
        return self.vtable.connect(self.ptr, allocator, endpoint, tls_config);
    }

    /// Clean up transport resources
    pub fn deinit(self: Transport) void {
        self.vtable.deinit(self.ptr);
    }
};
```

**Parameters:**
- `endpoint`: Network endpoint in format "host:port" (e.g., "localhost:8443")
- `tls_config`: Optional TLS configuration for secure connections
- `allocator`: Memory allocator for connection resources

**Returns:**
- `Connection`: Active connection instance
- `TransportError`: On connection failure

**Example:**
```zig
const transport = quic_transport.createClientTransport(allocator);
const conn = try transport.connect(allocator, "server.example.com:8443", &tls_config);
defer conn.close();
```

### Connection

Represents an active network connection with stream management capabilities.

```zig
pub const Connection = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    const VTable = struct {
        openStream: *const fn (ptr: *anyopaque) TransportError!Stream,
        close: *const fn (ptr: *anyopaque) void,
        ping: *const fn (ptr: *anyopaque) TransportError!void,
        isConnected: *const fn (ptr: *anyopaque) bool,
    };

    /// Open a new stream on this connection
    pub fn openStream(self: Connection) TransportError!Stream {
        return self.vtable.openStream(self.ptr);
    }

    /// Close the connection and all associated streams
    pub fn close(self: Connection) void {
        self.vtable.close(self.ptr);
    }

    /// Send a keep-alive ping
    pub fn ping(self: Connection) TransportError!void {
        return self.vtable.ping(self.ptr);
    }

    /// Check if connection is still active
    pub fn isConnected(self: Connection) bool {
        return self.vtable.isConnected(self.ptr);
    }
};
```

**Methods:**

#### `openStream() TransportError!Stream`
Creates a new stream for RPC communication.

**Returns:**
- `Stream`: New stream instance
- `TransportError.ResourceExhausted`: If connection stream limit reached

**Example:**
```zig
const stream = try connection.openStream();
defer stream.close();
```

#### `ping() TransportError!void`
Sends a keep-alive ping to maintain connection.

**Returns:**
- `void`: On successful ping
- `TransportError.ConnectionTimeout`: If ping times out
- `TransportError.NotConnected`: If connection is closed

#### `isConnected() bool`
Checks connection status without side effects.

**Returns:**
- `true`: Connection is active
- `false`: Connection is closed or failed

### Stream

Individual communication channel for RPC messages.

```zig
pub const Stream = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    const VTable = struct {
        writeFrame: *const fn (ptr: *anyopaque, frame_type: FrameType, flags: u8, data: []const u8) TransportError!void,
        readFrame: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator) TransportError!Frame,
        close: *const fn (ptr: *anyopaque) void,
        cancel: *const fn (ptr: *anyopaque) void,
    };

    /// Write a frame to the stream
    pub fn writeFrame(self: Stream, frame_type: FrameType, flags: u8, data: []const u8) TransportError!void {
        return self.vtable.writeFrame(self.ptr, frame_type, flags, data);
    }

    /// Read the next frame from the stream
    pub fn readFrame(self: Stream, allocator: std.mem.Allocator) TransportError!Frame {
        return self.vtable.readFrame(self.ptr, allocator);
    }

    /// Close the stream normally
    pub fn close(self: Stream) void {
        self.vtable.close(self.ptr);
    }

    /// Cancel the stream immediately
    pub fn cancel(self: Stream) void {
        self.vtable.cancel(self.ptr);
    }
};
```

**Methods:**

#### `writeFrame(frame_type: FrameType, flags: u8, data: []const u8) TransportError!void`
Writes a frame to the stream.

**Parameters:**
- `frame_type`: Type of frame (data, headers, etc.)
- `flags`: Frame-specific flags
- `data`: Frame payload data

**Returns:**
- `void`: On successful write
- `TransportError.ResourceExhausted`: If write buffer full
- `TransportError.InvalidArgument`: If frame invalid

**Example:**
```zig
try stream.writeFrame(.data, 0, message_bytes);
try stream.writeFrame(.headers, 0x01, header_bytes); // End of headers flag
```

#### `readFrame(allocator: std.mem.Allocator) TransportError!Frame`
Reads the next frame from the stream.

**Parameters:**
- `allocator`: Memory allocator for frame data

**Returns:**
- `Frame`: The received frame
- `TransportError.ConnectionReset`: If stream reset
- `TransportError.Timeout`: If read times out

**Example:**
```zig
const frame = try stream.readFrame(allocator);
defer allocator.free(frame.payload);

switch (frame.frame_type) {
    .data => try processData(frame.payload),
    .headers => try processHeaders(frame.payload),
    .rst_stream => return error.StreamReset,
    else => {},
}
```

## Frame Protocol

### FrameType

Defines the types of frames used in the transport protocol.

```zig
pub const FrameType = enum(u8) {
    data = 0x00,        /// Payload data
    headers = 0x01,     /// Request/response headers
    priority = 0x02,    /// Stream priority
    rst_stream = 0x03,  /// Stream reset
    settings = 0x04,    /// Connection settings
    ping = 0x06,        /// Keep-alive ping
    goaway = 0x07,      /// Connection termination

    /// Convert frame type to string for debugging
    pub fn toString(self: FrameType) []const u8 {
        return switch (self) {
            .data => "DATA",
            .headers => "HEADERS",
            .priority => "PRIORITY",
            .rst_stream => "RST_STREAM",
            .settings => "SETTINGS",
            .ping => "PING",
            .goaway => "GOAWAY",
        };
    }
};
```

### Frame

Container for transport protocol frames.

```zig
pub const Frame = struct {
    frame_type: FrameType,
    flags: u8,
    stream_id: u32,
    payload: []u8,

    /// Create a new frame
    pub fn init(frame_type: FrameType, flags: u8, stream_id: u32, payload: []u8) Frame {
        return Frame{
            .frame_type = frame_type,
            .flags = flags,
            .stream_id = stream_id,
            .payload = payload,
        };
    }

    /// Check if a specific flag is set
    pub fn hasFlag(self: Frame, flag: u8) bool {
        return (self.flags & flag) != 0;
    }

    /// Get frame size including headers
    pub fn totalSize(self: Frame) usize {
        return 9 + self.payload.len; // 9 bytes header + payload
    }
};
```

**Common Frame Flags:**
- `0x01`: End of stream
- `0x02`: End of headers
- `0x04`: Padded
- `0x08`: Priority

**Example:**
```zig
// Create a data frame with end-of-stream flag
const frame = Frame.init(.data, 0x01, stream_id, message_data);

// Check for end-of-stream
if (frame.hasFlag(0x01)) {
    std.log.info("Received end-of-stream");
}
```

## TLS Configuration

### TlsConfig

Configuration for TLS/SSL secure connections.

```zig
pub const TlsConfig = struct {
    /// Certificate file path (PEM format)
    cert_path: ?[]const u8 = null,

    /// Private key file path (PEM format)
    key_path: ?[]const u8 = null,

    /// Certificate Authority file path for validation
    ca_cert_path: ?[]const u8 = null,

    /// Verify server certificate hostname
    verify_hostname: bool = true,

    /// Allow self-signed certificates (development only)
    allow_self_signed: bool = false,

    /// Expected server hostname (overrides endpoint hostname)
    expected_hostname: ?[]const u8 = null,

    /// Minimum TLS protocol version
    min_protocol_version: TlsVersion = .tls1_3,

    /// Verify certificate chain
    verify_chain: bool = true,

    /// Client certificate for mutual TLS
    client_cert_path: ?[]const u8 = null,
    client_key_path: ?[]const u8 = null,

    /// Validate TLS configuration
    pub fn validate(self: *const TlsConfig) TlsError!void {
        if (self.cert_path != null and self.key_path == null) {
            return TlsError.MissingPrivateKey;
        }
        if (self.key_path != null and self.cert_path == null) {
            return TlsError.MissingCertificate;
        }
        // Additional validation...
    }

    /// Create a development configuration (insecure)
    pub fn development() TlsConfig {
        return TlsConfig{
            .verify_hostname = false,
            .allow_self_signed = true,
            .verify_chain = false,
        };
    }

    /// Create a production configuration (secure)
    pub fn production(cert_path: []const u8, key_path: []const u8) TlsConfig {
        return TlsConfig{
            .cert_path = cert_path,
            .key_path = key_path,
            .verify_hostname = true,
            .allow_self_signed = false,
            .verify_chain = true,
            .min_protocol_version = .tls1_3,
        };
    }
};
```

### TlsVersion

Supported TLS protocol versions.

```zig
pub const TlsVersion = enum {
    tls1_2,
    tls1_3,

    pub fn toString(self: TlsVersion) []const u8 {
        return switch (self) {
            .tls1_2 => "TLS 1.2",
            .tls1_3 => "TLS 1.3",
        };
    }
};
```

**Example TLS Configuration:**
```zig
// Production server configuration
const server_tls = TlsConfig.production("server.crt", "server.key");

// Client with custom CA
const client_tls = TlsConfig{
    .ca_cert_path = "custom-ca.pem",
    .verify_hostname = true,
    .expected_hostname = "api.example.com",
};

// Development (insecure)
const dev_tls = TlsConfig.development();
```

## Error Handling

### TransportError

Unified error taxonomy for all transport operations.

```zig
pub const TransportError = error{
    // Network-level errors
    ConnectionFailed,      /// Cannot establish connection
    ConnectionReset,       /// Connection reset by peer
    ConnectionTimeout,     /// Connection attempt timed out
    NotConnected,         /// Operation on closed connection

    // Protocol-level errors
    InvalidFrame,         /// Malformed frame received
    InvalidHeader,        /// Invalid frame header
    Protocol,            /// Generic protocol violation

    // Resource errors
    ResourceExhausted,   /// Too many connections/streams
    InvalidArgument,     /// Invalid function parameter

    // System errors
    NetworkError,        /// Underlying network error
    OutOfMemory,        /// Memory allocation failed

    // TLS errors
    TlsHandshakeFailed, /// TLS handshake error
    CertificateError,   /// Certificate validation error
};
```

### Error Handling Patterns

```zig
// Basic error handling
const connection = transport.connect(allocator, endpoint, &tls_config) catch |err| switch (err) {
    error.ConnectionTimeout => {
        std.log.warn("Connection timed out, retrying...");
        // Implement retry logic
        return err;
    },
    error.CertificateError => {
        std.log.err("TLS certificate validation failed");
        return err;
    },
    else => return err,
};

// Stream operation with error recovery
const frame = stream.readFrame(allocator) catch |err| switch (err) {
    error.ConnectionReset => {
        std.log.info("Stream reset, handling gracefully");
        try handleStreamReset();
        return;
    },
    error.ResourceExhausted => {
        std.log.warn("Resource exhausted, waiting for availability");
        try waitForResources();
        // Retry operation
        return stream.readFrame(allocator);
    },
    else => return err,
};
```

## Contract Testing

### Running Transport Compliance Tests

```zig
const contract_tests = @import("zrpc-core").contract_tests;

test "QUIC transport compliance" {
    var transport = quic_transport.createClientTransport(testing.allocator);
    defer transport.deinit();

    try contract_tests.runClientTransportTests(testing.allocator, transport);
}

test "custom transport compliance" {
    var custom_transport = CustomTransport.init(testing.allocator);
    defer custom_transport.deinit();

    const transport = Transport{
        .ptr = &custom_transport,
        .vtable = &CustomTransport.vtable,
    };

    try contract_tests.runTransportTests(testing.allocator, transport);
}
```

### Contract Test Suite

The contract tests verify:

1. **Connection Lifecycle**
   - Successful connection establishment
   - Proper connection closure
   - Connection status reporting
   - Keep-alive functionality

2. **Stream Operations**
   - Stream creation and management
   - Frame read/write operations
   - Stream cancellation
   - Resource cleanup

3. **Error Handling**
   - Proper error propagation
   - Error recovery mechanisms
   - Resource cleanup on errors

4. **Resource Management**
   - Memory leak prevention
   - Connection limit enforcement
   - Stream limit enforcement
   - Proper cleanup on shutdown

## Performance Considerations

### Zero-Copy Operations

Transport adapters should minimize data copying:

```zig
// Efficient frame writing (zero-copy when possible)
pub fn writeFrame(ptr: *anyopaque, frame_type: FrameType, flags: u8, data: []const u8) TransportError!void {
    const self: *CustomTransport = @ptrCast(@alignCast(ptr));

    // Direct buffer writing without intermediate copies
    const header = [9]u8{
        @intFromEnum(frame_type),
        flags,
        // ... frame header fields
    };

    try self.socket.writev(&.{ header[0..], data });
}
```

### Connection Pooling

Transport adapters can provide connection pooling:

```zig
pub const ConnectionPool = struct {
    pub const Config = struct {
        max_connections: usize = 100,
        min_connections: usize = 10,
        idle_timeout_ms: u64 = 300000, // 5 minutes
        health_check_interval_ms: u64 = 30000, // 30 seconds
    };

    pub fn init(allocator: std.mem.Allocator, config: Config) !*ConnectionPool {
        // Initialize connection pool
    }

    pub fn getConnection(self: *ConnectionPool, endpoint: []const u8) !Connection {
        // Return existing or create new connection
    }

    pub fn returnConnection(self: *ConnectionPool, connection: Connection) void {
        // Return connection to pool
    }
};
```

---

**Next**: See the [Core API](core.md) for RPC-level interfaces, or check the [Examples](../examples/README.md) for complete usage patterns.