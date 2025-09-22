//! zrpc - Advanced RPC framework for Zig
//! A neutral, low-level core library for gRPC-like transports, serialization, and service definitions.
const std = @import("std");

pub const service = @import("service.zig");
pub const codec = @import("codec.zig");
pub const transport = @import("transport.zig");
pub const streaming = @import("streaming.zig");
pub const tls = @import("tls.zig");
pub const protobuf = @import("protobuf.zig");
pub const quic = @import("quic.zig");
pub const quic_pool = @import("quic_pool.zig");
pub const auth = @import("auth.zig");
pub const proto_parser = @import("proto_parser.zig");
pub const codegen = @import("codegen.zig");
pub const Error = @import("error.zig").Error;

pub const Client = service.Client;
pub const Server = service.Server;
pub const MethodDef = service.MethodDef;
pub const TlsConfig = tls.TlsConfig;
pub const TlsConnection = tls.TlsConnection;

// Transport types
pub const Http2Transport = transport.Http2Transport;
pub const QuicTransport = transport.QuicTransport;
pub const MockTransport = transport.MockTransport;

// QUIC specific exports
pub const QuicConnection = quic.QuicConnection;
pub const QuicStream = quic.QuicStream;
pub const QuicPacket = quic.QuicPacket;
pub const QuicFrame = quic.QuicFrame;
pub const SessionTicket = quic.SessionTicket;
pub const NetworkPath = quic.NetworkPath;

// QUIC connection pooling
pub const QuicConnectionPool = quic_pool.QuicConnectionPool;
pub const PooledConnection = quic_pool.PooledConnection;
pub const PoolConfig = quic_pool.PoolConfig;
pub const LoadBalancingStrategy = quic_pool.LoadBalancingStrategy;

// Authentication
pub const JwtToken = auth.JwtToken;
pub const OAuth2Token = auth.OAuth2Token;
pub const AuthMiddleware = auth.AuthMiddleware;

// Protocol Buffer parsing and code generation
pub const ProtoFile = proto_parser.ProtoFile;
pub const MessageDef = proto_parser.MessageDef;
pub const ProtoServiceDef = proto_parser.ServiceDef;
pub const parseProtoFile = proto_parser.parseProtoFile;
pub const parseProtoFromFile = proto_parser.parseProtoFromFile;
pub const generateZigCode = codegen.generateZigCode;
pub const generateFromProtoFile = codegen.generateFromProtoFile;
pub const CodegenOptions = codegen.CodegenOptions;

test {
    std.testing.refAllDecls(@This());
}
