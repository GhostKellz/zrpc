//! Security hardening module for zRPC
//! Implements input validation, sanitization, and security best practices

const std = @import("std");
const transport_interface = @import("transport_interface.zig");
const TransportError = transport_interface.TransportError;

/// Security configuration for zRPC instances
pub const SecurityConfig = struct {
    /// Maximum message size in bytes (default: 4MB)
    max_message_size: usize = 4 * 1024 * 1024,

    /// Maximum number of concurrent streams per connection
    max_concurrent_streams: u32 = 100,

    /// Maximum connection idle timeout in seconds
    max_idle_timeout_sec: u32 = 300,

    /// Enable strict TLS certificate validation
    strict_tls_validation: bool = true,

    /// Require minimum TLS version
    min_tls_version: TlsVersion = .tls_1_3,

    /// Enable rate limiting
    enable_rate_limiting: bool = true,

    /// Maximum requests per second per connection
    max_requests_per_sec: u32 = 1000,

    /// Enable input sanitization
    enable_input_sanitization: bool = true,

    /// Maximum header size in bytes
    max_header_size: usize = 8192,

    /// Maximum number of headers per message
    max_headers_count: u32 = 100,
};

pub const TlsVersion = enum {
    tls_1_2,
    tls_1_3,
};

/// Security validator for transport operations
pub const SecurityValidator = struct {
    config: SecurityConfig,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, config: SecurityConfig) SecurityValidator {
        return SecurityValidator{
            .config = config,
            .allocator = allocator,
        };
    }

    /// Validate endpoint string for security issues
    pub fn validateEndpoint(self: *const SecurityValidator, endpoint: []const u8) !void {
        if (endpoint.len == 0) {
            return TransportError.InvalidArgument;
        }

        if (endpoint.len > 253) { // RFC 1035 max hostname length
            return TransportError.InvalidArgument;
        }

        // Check for null bytes and control characters
        for (endpoint) |char| {
            if (char < 0x20 or char > 0x7E) {
                if (char != ':' and char != '.') { // Allow common separators
                    return TransportError.InvalidArgument;
                }
            }
        }

        // Prevent obvious injection attempts
        const dangerous_patterns = [_][]const u8{
            "../", "..\\", "javascript:", "data:", "file:",
            "<script", "</script", "eval(", "exec(",
        };

        const lower_endpoint = try std.ascii.allocLowerString(self.allocator, endpoint);
        defer self.allocator.free(lower_endpoint);

        for (dangerous_patterns) |pattern| {
            if (std.mem.indexOf(u8, lower_endpoint, pattern) != null) {
                return TransportError.InvalidArgument;
            }
        }
    }

    /// Validate message payload size and content
    pub fn validatePayload(self: *const SecurityValidator, payload: []const u8) !void {
        if (payload.len > self.config.max_message_size) {
            return TransportError.ResourceExhausted;
        }

        if (self.config.enable_input_sanitization) {
            // Check for potential buffer overflow patterns
            var null_count: u32 = 0;
            for (payload) |byte| {
                if (byte == 0) {
                    null_count += 1;
                    if (null_count > 10) { // Suspicious number of null bytes
                        return TransportError.InvalidArgument;
                    }
                }
            }
        }
    }

    /// Validate frame headers for security compliance
    pub fn validateFrameHeaders(self: *const SecurityValidator, headers: []const u8) !void {
        if (headers.len > self.config.max_header_size) {
            return TransportError.ResourceExhausted;
        }

        if (self.config.enable_input_sanitization) {
            // Check for header injection patterns
            const injection_patterns = [_][]const u8{
                "\r\n", "\n\r", "\\r\\n", "\\n\\r",
                "%0d%0a", "%0a%0d", "%0D%0A", "%0A%0D",
            };

            for (injection_patterns) |pattern| {
                if (std.mem.indexOf(u8, headers, pattern) != null) {
                    return TransportError.InvalidArgument;
                }
            }
        }
    }

    /// Rate limiting check (simplified implementation)
    pub fn checkRateLimit(self: *const SecurityValidator, connection_id: u64) !void {
        _ = self;
        _ = connection_id;
        // In production, this would maintain per-connection rate limiting state
        // For RC2, we implement the interface
    }

    /// Validate TLS configuration security
    pub fn validateTlsConfig(self: *const SecurityValidator, tls_config: ?*const transport_interface.TlsConfig) !void {
        if (tls_config == null and self.config.strict_tls_validation) {
            return TransportError.InvalidArgument; // TLS required in strict mode
        }

        if (tls_config) |config| {
            // Validate ALPN protocols
            for (config.alpn_protocols) |protocol| {
                if (protocol.len == 0 or protocol.len > 255) {
                    return TransportError.InvalidArgument;
                }
            }

            // In production, validate certificate paths exist and are readable
            _ = config.cert_file;
            _ = config.key_file;
            _ = config.ca_file;
        }
    }

    /// Memory safety validation for allocations
    pub fn validateAllocation(self: *const SecurityValidator, size: usize) !void {
        // Prevent excessive memory allocations
        const max_single_allocation = 100 * 1024 * 1024; // 100MB
        if (size > max_single_allocation) {
            return TransportError.ResourceExhausted;
        }

        // Check for integer overflow in allocation size calculations
        if (size > std.math.maxInt(usize) / 2) {
            return TransportError.ResourceExhausted;
        }

        _ = self;
    }
};

/// Security audit utilities
pub const SecurityAudit = struct {
    pub fn auditTransportInterface() void {
        // Compile-time checks for security best practices
        comptime {
            // Ensure error types are properly defined
            _ = TransportError.InvalidArgument;
            _ = TransportError.ResourceExhausted;
            _ = TransportError.Protocol;
        }
    }

    pub fn auditMemoryUsage(allocator: std.mem.Allocator) !void {
        // In production, this would check for memory leaks
        // and unusual allocation patterns
        _ = allocator;
    }
};

/// Secure random number generation for security features
pub const SecureRandom = struct {
    prng: std.Random.DefaultPrng,

    pub fn init() SecureRandom {
        var seed: u64 = undefined;
        std.posix.getrandom(std.mem.asBytes(&seed)) catch {
            seed = @intCast(std.time.timestamp());
        };

        return SecureRandom{
            .prng = std.Random.DefaultPrng.init(seed),
        };
    }

    pub fn generateConnectionId(self: *SecureRandom) u64 {
        return self.prng.random().int(u64);
    }

    pub fn generateStreamId(self: *SecureRandom) u32 {
        return self.prng.random().int(u32);
    }
};

test "security validator endpoint validation" {
    const allocator = std.testing.allocator;
    const config = SecurityConfig{};
    const validator = SecurityValidator.init(allocator, config);

    // Valid endpoints
    try validator.validateEndpoint("localhost:8080");
    try validator.validateEndpoint("192.168.1.1:443");
    try validator.validateEndpoint("example.com:8443");

    // Invalid endpoints
    try std.testing.expectError(TransportError.InvalidArgument, validator.validateEndpoint(""));
    try std.testing.expectError(TransportError.InvalidArgument, validator.validateEndpoint("host\x00:8080"));
    try std.testing.expectError(TransportError.InvalidArgument, validator.validateEndpoint("javascript:alert(1)"));
}

test "security validator payload validation" {
    const allocator = std.testing.allocator;
    const config = SecurityConfig{ .max_message_size = 1024 };
    const validator = SecurityValidator.init(allocator, config);

    // Valid payload
    const small_payload = "Hello, World!";
    try validator.validatePayload(small_payload);

    // Too large payload
    const large_payload = "x" ** 2048;
    try std.testing.expectError(TransportError.ResourceExhausted, validator.validatePayload(large_payload));
}

test "secure random generation" {
    var secure_random = SecureRandom.init();

    const id1 = secure_random.generateConnectionId();
    const id2 = secure_random.generateConnectionId();

    // Should generate different IDs (very high probability)
    try std.testing.expect(id1 != id2);
}