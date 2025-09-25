//! zrpc-core: Transport-agnostic RPC framework
//! This module exports the core RPC functionality without transport dependencies

const std = @import("std");

// Core exports
pub const Client = @import("core/client.zig").Client;
pub const Server = @import("core/server.zig").Server;
pub const ClientConfig = @import("core/client.zig").ClientConfig;
pub const ServerConfig = @import("core/server.zig").ServerConfig;
pub const RequestContext = @import("core/server.zig").RequestContext;
pub const ResponseContext = @import("core/server.zig").ResponseContext;

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