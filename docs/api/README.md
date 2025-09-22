# zRPC API Reference

This directory contains comprehensive API documentation for all zRPC modules.

## Modules

- [**Service**](service.md) - Core RPC service definitions, client and server
- [**Transport**](transport.md) - HTTP/2, QUIC, and message handling
- [**Authentication**](auth.md) - JWT and OAuth2 authentication
- [**Streaming**](streaming.md) - Client, server, and bidirectional streaming
- [**Codec**](codec.md) - JSON and Protocol Buffer serialization
- [**TLS**](tls.md) - TLS 1.3 configuration and connection management
- [**QUIC**](quic.md) - QUIC protocol implementation
- [**QUIC Pool**](quic_pool.md) - Connection pooling and load balancing
- [**Protocol Parser**](proto_parser.md) - .proto file parsing
- [**Code Generation**](codegen.md) - Zig code generation from .proto files
- [**Errors**](errors.md) - Error types and handling

## Quick Navigation

### Core APIs
- [`Client`](service.md#client) - RPC client for making calls
- [`Server`](service.md#server) - RPC server for handling requests
- [`CallContext`](service.md#callcontext) - Request context and metadata

### Transport
- [`Http2Transport`](transport.md#http2transport) - HTTP/2 transport layer
- [`QuicTransport`](transport.md#quictransport) - QUIC transport layer
- [`Message`](transport.md#message) - Message structure with headers

### Streaming
- [`ClientStream`](streaming.md#clientstream) - Client-side streaming
- [`ServerStream`](streaming.md#serverstream) - Server-side streaming
- [`BidirectionalStream`](streaming.md#bidirectionalstream) - Bidirectional streaming

### Security
- [`JwtToken`](auth.md#jwttoken) - JWT token handling
- [`OAuth2Token`](auth.md#oauth2token) - OAuth2 token management
- [`TlsConfig`](tls.md#tlsconfig) - TLS configuration

## Usage Patterns

### Basic RPC Call
```zig
var client = try zrpc.Client.init(allocator, "localhost:8080");
const response = try client.call("Service/Method", request, ResponseType, null);
```

### Server Setup
```zig
var server = zrpc.Server.init(allocator);
try server.registerHandler("Service", "Method", handler);
try server.serve("0.0.0.0:8080");
```

### Streaming
```zig
var stream = try client.clientStream("Service/StreamMethod", RequestType, ResponseType, null);
try stream.send(request);
const response = try stream.receive();
```

## Error Handling

All APIs return errors from the [`Error`](errors.md) enum. Common patterns:

```zig
const response = client.call(...) catch |err| switch (err) {
    Error.ConnectionTimeout => // Handle timeout
    Error.Unauthorized => // Handle auth failure
    Error.NotFound => // Handle missing service/method
    else => return err,
};
```