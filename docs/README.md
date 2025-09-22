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

zRPC is a modern, high-performance RPC framework designed specifically for Zig. It provides:

- **🚀 Full RPC Support** - Unary, client-streaming, server-streaming, and bidirectional streaming
- **🔒 Security First** - TLS 1.3, JWT authentication, OAuth2 token handling
- **⚡ High Performance** - HTTP/2, HTTP/3, and QUIC transport with 0-RTT connection resumption
- **🛠️ Developer Experience** - Complete .proto file parsing and Zig code generation
- **🔄 Load Balancing** - Multiple strategies (round-robin, least connections, weighted)
- **📊 Monitoring** - Comprehensive benchmarking and performance metrics
- **🌐 Protocol Buffer** - Full protobuf v3 support with JSON codec for debugging

## Architecture Overview

```
zrpc/
├── Core Framework
│   ├── HTTP/2 & QUIC transports
│   ├── Streaming RPC support (unary, client, server, bidirectional)
│   ├── Protobuf & JSON codecs
│   └── Service definitions & method handling
├── Advanced Features
│   ├── JWT/OAuth2 authentication with middleware
│   ├── 0-RTT connection resumption
│   ├── Connection migration & path validation
│   └── Connection pooling with load balancing
├── Developer Tools
│   ├── .proto file parser (complete AST)
│   ├── Zig code generator (messages, services, clients)
│   └── Benchmarking framework vs gRPC C++
└── Production Ready
    ├── TLS 1.3 security
    ├── Performance monitoring & metrics
    ├── Error handling & timeout management
    └── Thread-safe connection management
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

### Microservices
```zig
// service.zig
var server = zrpc.Server.init(allocator);
try server.registerHandler("UserService", "GetUser", user_handler);
try server.registerHandler("OrderService", "CreateOrder", order_handler);
try server.serve("0.0.0.0:8080");
```

### API Gateway
```zig
// gateway.zig
var client_pool = zrpc.transport.ConnectionPool.init(allocator, pool_config);
var load_balancer = zrpc.transport.LoadBalancer.init(allocator, lb_config);

// Route requests to backend services
const response = try route_request(request, &client_pool, &load_balancer);
```

### Real-time Communication
```zig
// streaming.zig
var stream = try client.bidirectionalStream("Chat/Messages", Message, Message, &context);
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
| 0.1.x        | 0.16.0-dev  | Current |

## License

zRPC is licensed under the MIT License. See [LICENSE](../LICENSE) for details.

---

**Ready to get started?** Follow the [Getting Started Guide](guides/getting-started.md) to build your first zRPC application!