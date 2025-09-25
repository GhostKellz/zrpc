//! zrpc-transport-quic: QUIC transport adapter for zrpc
//! This module provides QUIC transport implementation using the existing QUIC stack
//! For ALPHA-1, we use a mock transport to demonstrate the architecture

const std = @import("std");
const zrpc_core = @import("zrpc-core");
const mock_transport = @import("mock_transport.zig");

// Re-export core types for convenience
pub const Client = zrpc_core.Client;
pub const Server = zrpc_core.Server;
pub const Transport = zrpc_core.Transport;
pub const TlsConfig = zrpc_core.TlsConfig;
pub const Error = zrpc_core.Error;

// Mock transport for ALPHA-1 demonstration
pub const MockTransportAdapter = mock_transport.MockTransportAdapter;

/// Create a QUIC transport for client use (using mock for ALPHA-1)
pub fn createClientTransport(allocator: std.mem.Allocator) Transport {
    return mock_transport.createTransport(allocator);
}

/// Create a QUIC transport for server use (using mock for ALPHA-1)
pub fn createServerTransport(allocator: std.mem.Allocator) Transport {
    return mock_transport.createTransport(allocator);
}

/// Convenience function to create a QUIC-enabled client
pub fn createClient(allocator: std.mem.Allocator, config: ?zrpc_core.ClientConfig) !Client {
    const transport = createClientTransport(allocator);

    const client_config = config orelse zrpc_core.ClientConfig{
        .transport = transport,
    };

    return Client.init(allocator, client_config);
}

/// Convenience function to create a QUIC-enabled server
pub fn createServer(allocator: std.mem.Allocator, config: ?zrpc_core.ServerConfig) !Server {
    const transport = createServerTransport(allocator);

    const server_config = config orelse zrpc_core.ServerConfig{
        .transport = transport,
    };

    return Server.init(allocator, server_config);
}

/// Helper for explicit transport injection (recommended pattern)
/// For ALPHA-1, this uses mock transport
pub fn client(allocator: std.mem.Allocator, mock_endpoint: []const u8) !Client {
    _ = mock_endpoint; // TODO: Use endpoint in ALPHA-2 with real QUIC
    const transport = createClientTransport(allocator);
    return Client.init(allocator, .{ .transport = transport });
}

/// Helper for explicit transport injection (recommended pattern)
/// For ALPHA-1, this uses mock transport
pub fn server(allocator: std.mem.Allocator, mock_address: []const u8) !Server {
    _ = mock_address; // TODO: Use address in ALPHA-2 with real QUIC
    const transport = createServerTransport(allocator);
    return Server.init(allocator, .{ .transport = transport });
}

test "QUIC adapter basic functionality" {
    const allocator = std.testing.allocator;

    // Test transport creation
    const transport = createClientTransport(allocator);
    _ = transport;

    // Test client creation
    const test_client = try createClient(allocator, null);
    defer test_client.deinit();

    try std.testing.expect(!test_client.isConnected());
}