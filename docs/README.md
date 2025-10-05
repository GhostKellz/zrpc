# zRPC Documentation

Welcome to the zRPC documentation! This comprehensive guide covers everything you need to know about using zRPC, the advanced RPC framework for Zig.

## Quick Navigation

### 🚀 Getting Started
- [**Getting Started Guide**](guides/getting-started.md) - Your first zRPC application
- [**Installation**](guides/getting-started.md#installation) - Set up zRPC in your project
- [**Quick Start**](guides/getting-started.md#your-first-rpc-service) - Build your first service

### 📚 Guides
- [**Transport Layer**](guides/transport.md) - HTTP/2, QUIC, and transport configuration
- [**Authentication**](guides/auth.md) - JWT, OAuth2, and security patterns
- [**Protocol Buffers**](guides/protobuf.md) - .proto file parsing and code generation

### 📖 API Reference
- [**API Overview**](api/README.md) - Complete API documentation
- [**Service API**](api/service.md) - Client, Server, and RPC methods
- [**Core Types**](api/README.md#core-apis) - Essential types and interfaces

## What is zRPC?

**Version: 2.0.0-rc.5** | **Status: Release Preview** 🎬

zRPC is a modern, high-performance RPC framework designed specifically for Zig with a **transport-agnostic modular architecture**. It provides:

- **🏗️ Modular Architecture** - Clean separation between RPC core and transport adapters
- **🔌 Pluggable Transports** - QUIC, HTTP/2, or custom transport implementations
- **🚀 Full RPC Support** - Unary, client-streaming, server-streaming, and bidirectional streaming
- **🔒 Security First** - TLS 1.3, JWT authentication, OAuth2 token handling
- **⚡ High Performance** - p95 latency ≤ 100μs, 10k+ concurrent connections
- **🛠️ Developer Experience** - Complete .proto file parsing and Zig code generation
- **📦 Minimal Dependencies** - Core has zero transport dependencies
- **🌐 Protocol Buffer** - Full protobuf v3 support with JSON codec for debugging

## Architecture Overview

```
zrpc-ecosystem/
├── zrpc-core/                    # Transport-agnostic RPC framework
│   ├── codecs/ (protobuf, JSON)
│   ├── interceptors/
│   ├── service/ (method dispatch)
│   └── interfaces/ (transport SPI)
│
├── zrpc-transport-quic/          # QUIC transport adapter (optional)
│   ├── 0-RTT connection resumption
│   ├── connection migration
│   └── HTTP/3 + gRPC integration
│
├── zrpc-transport-http2/         # HTTP/2 transport adapter (planned)
│   ├── TLS 1.3 support
│   └── connection multiplexing
│
└── zrpc-tools/                   # Code generation and tooling
    ├── proto parser
    ├── Zig code generator
    └── benchmarking framework
```

## Key Features

### Transport Layer
- **HTTP/2** - Standard gRPC-compatible transport with multiplexing
- **QUIC** - Modern UDP-based transport with 0-RTT and connection migration
- **TLS 1.3** - End-to-end encryption with certificate validation
- **Connection Pooling** - Efficient connection reuse and load balancing

### Authentication & Security
- **JWT Tokens** - Stateless authentication with HMAC-SHA256 signing
- **OAuth2** - Industry standard authorization with token refresh
- **Mutual TLS** - Certificate-based authentication
- **Custom Middleware** - Extensible authentication pipeline

### Protocol Buffers
- **Complete Parser** - Full .proto file parsing with AST generation
- **Code Generation** - Generate Zig structs, enums, and service definitions
- **Binary Serialization** - Efficient protobuf serialization/deserialization
- **gRPC Compatibility** - Full compatibility with standard gRPC services

### Streaming
- **Unary RPCs** - Single request, single response
- **Client Streaming** - Multiple requests, single response
- **Server Streaming** - Single request, multiple responses
- **Bidirectional Streaming** - Multiple requests, multiple responses

## Documentation Structure

### Guides
Step-by-step tutorials and conceptual explanations:

- **[Getting Started](guides/getting-started.md)** - Build your first zRPC application
- **[Transport Layer](guides/transport.md)** - Configure HTTP/2 and QUIC transports
- **[Authentication](guides/auth.md)** - Implement JWT and OAuth2 security
- **[Protocol Buffers](guides/protobuf.md)** - Use .proto files and code generation

### API Reference
Detailed API documentation for all modules:

- **[Service API](api/service.md)** - Core RPC functionality
- **[Transport API](api/README.md#transport)** - Network layer abstractions
- **[Authentication API](api/README.md#security)** - Security and auth types
- **[Streaming API](api/README.md#streaming)** - Streaming RPC interfaces

### Reference
Additional reference materials:

- **[Error Types](reference/errors.md)** - Complete error handling guide
- **[Configuration](reference/config.md)** - Configuration options
- **[Performance](reference/performance.md)** - Optimization techniques

## Common Use Cases

### Microservices with QUIC Transport
```zig
const zrpc = @import("zrpc-core");
const zrq  = @import("zrpc-transport-quic");
const zq   = @import("zquic");

// Server
var listener = try zq.listen(.{
    .alpn = "zr/1",
    .addr = "0.0.0.0:8443",
    .tls = tlsCfg()
});
var server = try zrpc.Server.init(allocator, .{
    .transport = zrq.server(listener)
});
try server.registerService(UserService{});
try server.start();
```

### API Gateway
```zig
// Client with explicit transport injection
var conn = try zquic.connect(.{
    .endpoint = "backend:8443",
    .tls = cfg
});
var client = try zrpc.Client.init(allocator, .{
    .transport = zrq.client(conn)
});

// Route requests to backend services
const response = try client.call("OrderService/Create", request);
```

### Real-time Communication
```zig
// Bidirectional streaming
var stream = try client.openBidiStream("Chat/Messages");
try stream.send(message);
const incoming = try stream.receive();
```

## Getting Help

### Documentation
- Browse the [API Reference](api/README.md) for detailed interface documentation
- Follow the [Getting Started Guide](guides/getting-started.md) for your first application
- Check the [Authentication Guide](guides/auth.md) for security implementation

### Community
- Report issues on [GitHub Issues](https://github.com/ghostkellz/zrpc/issues)
- Join discussions on [GitHub Discussions](https://github.com/ghostkellz/zrpc/discussions)
- Follow the project on [GitHub](https://github.com/ghostkellz/zrpc)

### Examples
Check the `examples/` directory in the repository for complete working examples:
- Basic client/server
- Streaming RPCs
- Authentication patterns
- Performance optimization

## Contributing

We welcome contributions! Please see our [Contributing Guide](../CONTRIBUTING.md) for details on:
- Code style and conventions
- Testing requirements
- Documentation standards
- Pull request process

## Version Compatibility

| zRPC Version | Zig Version | Status |
|--------------|-------------|---------|
| 2.0.0-rc.5   | 0.16.0-dev.164+ | Release Preview 🎬 |
| 1.0.x        | 0.16.0-dev  | Legacy (Monolithic) |

## License

zRPC is licensed under the MIT License. See [LICENSE](../LICENSE) for details.

---

**Ready to get started?** Follow the [Getting Started Guide](guides/getting-started.md) to build your first zRPC application!