# Error Handling Reference

zRPC provides a comprehensive error system designed for robust RPC communication. This reference covers all error types, handling patterns, and best practices.

## Error Types

All zRPC operations return errors from the `Error` enum defined in `src/error.zig`:

```zig
pub const Error = error{
    // Connection Errors
    ConnectionTimeout,
    ConnectionRefused,
    ConnectionLost,
    NetworkError,

    // Authentication Errors
    Unauthorized,
    Forbidden,
    InvalidToken,
    TokenExpired,
    TokenNotYetValid,

    // Protocol Errors
    InvalidRequest,
    InvalidResponse,
    ProtocolError,
    UnsupportedVersion,

    // Serialization Errors
    SerializationError,
    DeserializationError,
    InvalidFormat,

    // Service Errors
    NotFound,
    MethodNotFound,
    ServiceUnavailable,

    // Streaming Errors
    StreamClosed,
    StreamError,
    FlowControlError,

    // Transport Errors
    TlsHandshakeFailure,
    Http2ProtocolError,
    Http2FlowControlError,
    Http2CompressionError,
    QuicConnectionError,
    QuicTransportError,
    QuicApplicationError,

    // Resource Errors
    OutOfMemory,
    ResourceExhausted,
    RateLimitExceeded,

    // General Errors
    Internal,
    NotImplemented,
    Timeout,
    Cancelled,
};
```

## Error Categories

### Connection Errors

Errors related to network connectivity:

| Error | Description | Recovery Strategy |
|-------|-------------|-------------------|
| `ConnectionTimeout` | Connection attempt timed out | Retry with exponential backoff |
| `ConnectionRefused` | Server refused connection | Check server status, try alternative endpoint |
| `ConnectionLost` | Connection dropped unexpectedly | Reconnect and retry operation |
| `NetworkError` | General network failure | Check network connectivity |

**Example Handling:**
```zig
const response = client.call(...) catch |err| switch (err) {
    Error.ConnectionTimeout => {
        std.time.sleep(1000_000_000); // 1 second
        return try client.call(...); // Retry
    },
    Error.ConnectionRefused => {
        return try fallback_client.call(...); // Try backup server
    },
    Error.ConnectionLost => {
        try client.reconnect();
        return try client.call(...);
    },
    else => return err,
};
```

### Authentication Errors

Security and authentication failures:

| Error | Description | Recovery Strategy |
|-------|-------------|-------------------|
| `Unauthorized` | Invalid or missing credentials | Refresh authentication |
| `Forbidden` | Valid credentials, insufficient permissions | Request elevated access |
| `InvalidToken` | Malformed authentication token | Re-authenticate |
| `TokenExpired` | Authentication token has expired | Refresh token |
| `TokenNotYetValid` | Token not yet valid (nbf claim) | Wait or check system clock |

**Example Handling:**
```zig
const TokenManager = struct {
    oauth2_client: OAuth2Client,
    current_token: ?[]const u8,

    fn callWithAuth(self: *TokenManager, client: *zrpc.Client, method: []const u8, request: anytype, response_type: type) !response_type {
        var context = zrpc.CallContext.init(client.allocator);
        defer context.deinit();

        // Add current token
        if (self.current_token) |token| {
            try context.addMetadata("authorization", token);
        }

        return client.call(method, request, response_type, &context) catch |err| switch (err) {
            Error.Unauthorized, Error.TokenExpired => {
                // Refresh token and retry
                self.current_token = try self.refreshToken();
                try context.metadata.put("authorization", self.current_token.?);
                return try client.call(method, request, response_type, &context);
            },
            else => return err,
        };
    }
};
```

### Protocol Errors

RPC protocol and format errors:

| Error | Description | Common Causes |
|-------|-------------|---------------|
| `InvalidRequest` | Malformed request | Invalid message format, missing required fields |
| `InvalidResponse` | Malformed response | Server error, protocol mismatch |
| `ProtocolError` | General protocol violation | Version mismatch, invalid frame sequence |
| `UnsupportedVersion` | Unsupported protocol version | Client/server version mismatch |

### Transport-Specific Errors

#### HTTP/2 Errors

| Error | Description | Recovery |
|-------|-------------|----------|
| `Http2ProtocolError` | HTTP/2 frame or state error | Reset connection |
| `Http2FlowControlError` | Flow control window exceeded | Wait for window update |
| `Http2CompressionError` | HPACK compression failed | Reset connection |

#### QUIC Errors

| Error | Description | Recovery |
|-------|-------------|----------|
| `QuicConnectionError` | QUIC connection terminated | Reconnect with new connection |
| `QuicTransportError` | Transport parameter error | Check configuration |
| `QuicApplicationError` | Application protocol error | Check application logic |

## Error Handling Patterns

### Basic Error Handling

```zig
const response = client.call("Service/Method", request, ResponseType, null) catch |err| {
    std.log.err("RPC call failed: {}", .{err});
    return default_response;
};
```

### Comprehensive Error Handling

```zig
fn handleRpcCall(client: *zrpc.Client, request: RequestType) !ResponseType {
    return client.call("Service/Method", request, ResponseType, null) catch |err| switch (err) {
        // Retryable errors
        Error.ConnectionTimeout,
        Error.ConnectionLost,
        Error.NetworkError,
        Error.ServiceUnavailable => {
            std.log.warn("Retryable error: {}, retrying...", .{err});
            return try retryWithBackoff(client, request);
        },

        // Authentication errors
        Error.Unauthorized,
        Error.TokenExpired => {
            std.log.info("Auth error: {}, refreshing credentials...", .{err});
            try refreshCredentials();
            return try client.call("Service/Method", request, ResponseType, null);
        },

        // Client errors (don't retry)
        Error.InvalidRequest,
        Error.NotFound,
        Error.Forbidden => {
            std.log.err("Client error: {}", .{err});
            return err;
        },

        // Server errors (may retry with different server)
        Error.Internal,
        Error.ResourceExhausted => {
            std.log.warn("Server error: {}, trying fallback...", .{err});
            return try fallback_client.call("Service/Method", request, ResponseType, null);
        },

        // Unhandled errors
        else => {
            std.log.err("Unexpected error: {}", .{err});
            return err;
        },
    };
}
```

### Retry Logic with Exponential Backoff

```zig
const RetryConfig = struct {
    max_attempts: u32 = 3,
    initial_delay_ms: u64 = 100,
    max_delay_ms: u64 = 5000,
    backoff_multiplier: f64 = 2.0,
    jitter: bool = true,
};

fn retryWithBackoff(
    client: *zrpc.Client,
    request: anytype,
    config: RetryConfig,
) !ResponseType {
    var attempt: u32 = 0;
    var delay_ms = config.initial_delay_ms;

    while (attempt < config.max_attempts) {
        const result = client.call("Service/Method", request, ResponseType, null);

        if (result) |response| {
            return response;
        } else |err| switch (err) {
            // Only retry on specific errors
            Error.ConnectionTimeout,
            Error.ConnectionLost,
            Error.ServiceUnavailable,
            Error.NetworkError => {
                attempt += 1;
                if (attempt >= config.max_attempts) return err;

                // Apply jitter to prevent thundering herd
                const actual_delay = if (config.jitter)
                    delay_ms + (std.crypto.random.int(u64) % (delay_ms / 2))
                else
                    delay_ms;

                std.log.info("Retry attempt {} after {}ms", .{ attempt, actual_delay });
                std.time.sleep(actual_delay * 1_000_000); // Convert to nanoseconds

                // Exponential backoff
                delay_ms = @min(
                    @as(u64, @intFromFloat(@as(f64, @floatFromInt(delay_ms)) * config.backoff_multiplier)),
                    config.max_delay_ms
                );
            },
            else => return err, // Don't retry on other errors
        }
    }

    return Error.Timeout; // All retries exhausted
}
```

### Circuit Breaker Pattern

```zig
const CircuitBreakerState = enum {
    closed,    // Normal operation
    open,      // Failing, reject requests
    half_open, // Testing if service recovered
};

const CircuitBreaker = struct {
    state: CircuitBreakerState = .closed,
    failure_count: u32 = 0,
    success_count: u32 = 0,
    last_failure_time: i64 = 0,

    // Configuration
    failure_threshold: u32 = 5,
    recovery_timeout_ms: i64 = 60000, // 1 minute
    success_threshold: u32 = 3, // For half-open state

    fn call(self: *CircuitBreaker, client: *zrpc.Client, request: anytype) !ResponseType {
        switch (self.state) {
            .open => {
                const now = std.time.timestamp();
                if (now - self.last_failure_time > self.recovery_timeout_ms) {
                    self.state = .half_open;
                    self.success_count = 0;
                } else {
                    return Error.ServiceUnavailable; // Circuit is open
                }
            },
            .closed, .half_open => {},
        }

        const result = client.call("Service/Method", request, ResponseType, null);

        if (result) |response| {
            self.onSuccess();
            return response;
        } else |err| {
            self.onFailure();
            return err;
        }
    }

    fn onSuccess(self: *CircuitBreaker) void {
        switch (self.state) {
            .closed => {
                self.failure_count = 0;
            },
            .half_open => {
                self.success_count += 1;
                if (self.success_count >= self.success_threshold) {
                    self.state = .closed;
                    self.failure_count = 0;
                }
            },
            .open => {}, // Shouldn't happen
        }
    }

    fn onFailure(self: *CircuitBreaker) void {
        self.failure_count += 1;
        self.last_failure_time = std.time.timestamp();

        if (self.failure_count >= self.failure_threshold) {
            self.state = .open;
        }
    }
};
```

## Error Context and Metadata

### Adding Error Context

```zig
const RpcError = struct {
    err: Error,
    context: []const u8,
    metadata: std.StringHashMap([]const u8),
    stack_trace: ?std.builtin.StackTrace,

    fn wrap(err: Error, context: []const u8, allocator: std.mem.Allocator) RpcError {
        return RpcError{
            .err = err,
            .context = context,
            .metadata = std.StringHashMap([]const u8).init(allocator),
            .stack_trace = std.builtin.current_stack_trace(),
        };
    }

    fn addMetadata(self: *RpcError, key: []const u8, value: []const u8) !void {
        try self.metadata.put(key, value);
    }
};

// Usage
const response = client.call(...) catch |err| {
    var rpc_err = RpcError.wrap(err, "Failed to call UserService/GetUser", allocator);
    try rpc_err.addMetadata("user_id", "12345");
    try rpc_err.addMetadata("request_id", request_id);

    std.log.err("RPC Error: {} - {s}", .{ rpc_err.err, rpc_err.context });
    return rpc_err.err;
};
```

### Error Logging and Monitoring

```zig
const ErrorLogger = struct {
    allocator: std.mem.Allocator,
    metrics: std.HashMap(Error, u64, std.hash_map.AutoContext(Error), std.hash_map.default_max_load_percentage),

    fn logError(self: *ErrorLogger, err: Error, context: []const u8, metadata: ?std.StringHashMap([]const u8)) void {
        // Update metrics
        const count = self.metrics.get(err) orelse 0;
        self.metrics.put(err, count + 1) catch {};

        // Log with structured format
        var log_entry = std.ArrayList(u8).init(self.allocator);
        defer log_entry.deinit();

        std.fmt.format(log_entry.writer(),
            "{{\"level\":\"error\",\"error\":\"{}\",\"context\":\"{s}\",\"timestamp\":{}",
            .{ err, context, std.time.timestamp() }
        ) catch {};

        if (metadata) |md| {
            _ = log_entry.appendSlice(",\"metadata\":{") catch {};

            var iter = md.iterator();
            var first = true;
            while (iter.next()) |entry| {
                if (!first) _ = log_entry.append(',') catch {};
                first = false;

                std.fmt.format(log_entry.writer(), "\"{s}\":\"{s}\"", .{ entry.key_ptr.*, entry.value_ptr.* }) catch {};
            }

            _ = log_entry.append('}') catch {};
        }

        _ = log_entry.append('}') catch {};

        std.log.err("{s}", .{log_entry.items});
    }

    fn getErrorMetrics(self: *ErrorLogger) std.HashMap(Error, u64, std.hash_map.AutoContext(Error), std.hash_map.default_max_load_percentage) {
        return self.metrics;
    }
};
```

## Best Practices

### 1. Error Classification

Always classify errors into categories:
- **Transient**: Network issues, timeouts (retry)
- **Authentication**: Auth failures (refresh credentials)
- **Client**: Invalid requests (don't retry)
- **Server**: Internal errors (may retry with different server)

### 2. Meaningful Error Messages

```zig
// Good
return Error.InvalidRequest; // With context: "Missing required field 'email' in UserCreateRequest"

// Better
const ValidationError = struct {
    field: []const u8,
    message: []const u8,

    fn missing(field: []const u8) ValidationError {
        return ValidationError{
            .field = field,
            .message = "Field is required but not provided",
        };
    }
};
```

### 3. Error Recovery

```zig
const ResilientClient = struct {
    primary_client: zrpc.Client,
    fallback_client: ?zrpc.Client,
    circuit_breaker: CircuitBreaker,
    retry_config: RetryConfig,

    fn call(self: *ResilientClient, method: []const u8, request: anytype, response_type: type) !response_type {
        // Try primary with circuit breaker
        if (self.circuit_breaker.call(&self.primary_client, request)) |response| {
            return response;
        } else |err| {
            // Try fallback if available
            if (self.fallback_client) |*fallback| {
                std.log.warn("Primary failed with {}, trying fallback", .{err});
                return try fallback.call(method, request, response_type, null);
            }
            return err;
        }
    }
};
```

### 4. Error Testing

```zig
test "error handling" {
    const allocator = std.testing.allocator;

    // Test timeout error
    var mock_client = MockClient.init(allocator);
    mock_client.setError(Error.ConnectionTimeout);

    const result = mock_client.call("Service/Method", request, ResponseType, null);
    try std.testing.expectError(Error.ConnectionTimeout, result);

    // Test recovery
    mock_client.clearError();
    const response = try mock_client.call("Service/Method", request, ResponseType, null);
    try std.testing.expect(response.success);
}
```

### 5. Documentation

Document error conditions in your API:

```zig
/// Retrieves user information by ID
///
/// Errors:
/// - Error.NotFound: User with specified ID does not exist
/// - Error.Unauthorized: Invalid or missing authentication
/// - Error.Forbidden: User does not have permission to view this user
/// - Error.ConnectionTimeout: Server did not respond within timeout
/// - Error.ServiceUnavailable: User service is temporarily unavailable
pub fn getUser(client: *zrpc.Client, user_id: u32) !User {
    // Implementation
}
```

This comprehensive error handling reference provides the foundation for building robust zRPC applications with proper error management and recovery strategies.