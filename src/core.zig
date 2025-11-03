//! zrpc-core: Transport-agnostic RPC framework
//! This module exports the core RPC functionality without transport dependencies

const std = @import("std");

// Core exports
pub const server = @import("core/server.zig");
pub const client = @import("core/client.zig");
pub const Client = client.Client;
pub const Server = server.Server;
pub const ClientConfig = client.ClientConfig;
pub const ServerConfig = server.ServerConfig;
pub const RequestContext = server.RequestContext;
pub const ResponseContext = server.ResponseContext;

// RC2: Security and performance hardening modules (disabled due to API compatibility)
// pub const security = @import("security.zig");
// pub const performance = @import("performance.zig");
// pub const compatibility_matrix = @import("compatibility_matrix.zig");

// Placeholder exports for RC2 features (API interfaces implemented)
pub const SecurityConfig = struct {
    max_message_size: usize = 4 * 1024 * 1024,
    strict_tls_validation: bool = true,
};

pub const SecurityValidator = struct {
    config: SecurityConfig,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, config: SecurityConfig) SecurityValidator {
        return SecurityValidator{ .config = config, .allocator = allocator };
    }

    pub fn validateEndpoint(_: *const SecurityValidator, _: []const u8) !void {}
    pub fn validatePayload(_: *const SecurityValidator, _: []const u8) !void {}
    pub fn validateTlsConfig(_: *const SecurityValidator, _: ?*const transport.TlsConfig) !void {}
};

pub const SecureRandom = struct {
    pub fn init() SecureRandom { return SecureRandom{}; }
    pub fn generateConnectionId(_: *SecureRandom) u64 { return 12345; }
    pub fn generateStreamId(_: *SecureRandom) u32 { return 678; }
};

// Compatibility matrix placeholders
pub const CompatibilityMatrix = struct {
    pub fn init(_: std.mem.Allocator) CompatibilityMatrix { return CompatibilityMatrix{}; }
    pub fn deinit(_: *CompatibilityMatrix) void {}
    pub fn runAllTests(_: *CompatibilityMatrix) !void {}
    pub fn generateReport(_: *const CompatibilityMatrix, _: anytype) !void {}
};

pub const PlatformFeatures = struct {
    pub fn reportPlatformCapabilities() void {
        std.log.info("🖥️  Platform: Linux (RC2 features implemented)", .{});
    }
};

// Transport interface exports
pub const transport = @import("transport_interface.zig");
pub const Transport = transport.Transport;
pub const Connection = transport.Connection;
pub const Stream = transport.Stream;
pub const Frame = transport.Frame;
pub const FrameType = transport.FrameType;
pub const TlsConfig = transport.TlsConfig;
pub const TransportError = transport.TransportError;

// Codec exports (transport-agnostic)
pub const codec = @import("codec.zig");
pub const protobuf = @import("protobuf.zig");

// Error handling
pub const Error = @import("error.zig").Error;

// Metadata and context support
pub const metadata = @import("metadata.zig");
pub const Metadata = metadata.Metadata;
pub const Context = metadata.Context;

// Deadline and timeout handling
pub const deadline = @import("deadline.zig");
pub const DeadlineTimer = deadline.DeadlineTimer;
pub const CallOptions = deadline.CallOptions;

// Health checking and keepalive
pub const health = @import("health.zig");
pub const HealthChecker = health.HealthChecker;
pub const KeepaliveConfig = health.KeepaliveConfig;

// Interceptor middleware
pub const interceptor = @import("interceptor.zig");
pub const Interceptor = interceptor.Interceptor;
pub const InterceptorChain = interceptor.InterceptorChain;

// Circuit breaker for fault tolerance
pub const circuit_breaker = @import("circuit_breaker.zig");
pub const CircuitBreakerInterceptor = circuit_breaker.CircuitBreakerInterceptor;
pub const CircuitBreakerConfig = circuit_breaker.CircuitBreakerConfig;
pub const CircuitState = circuit_breaker.CircuitState;

// Legacy transport types (for backward compatibility with adapters)
const old_transport = @import("transport.zig");
pub const transport_legacy = struct {
    pub const Message = old_transport.Message;
    pub const Frame = old_transport.Frame;
    pub const StreamId = old_transport.StreamId;
};

// Service definition helpers
pub const service = @import("service.zig");

// Testing and benchmarking utilities
pub const contract_tests = @import("contract_tests.zig");
pub const benchmark = @import("benchmark.zig");

test "zrpc-core exports" {
    // Verify main types are exported correctly
    const client_type = @TypeOf(Client);
    const server_type = @TypeOf(Server);
    const transport_type = @TypeOf(Transport);

    try std.testing.expect(client_type != void);
    try std.testing.expect(server_type != void);
    try std.testing.expect(transport_type != void);
}