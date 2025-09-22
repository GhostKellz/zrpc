<div align="center">
  <img src="assets/icons/zrpc.png" alt="zRPC Logo" width="200"/>

  # zRPC

  [![Made with Zig](https://img.shields.io/badge/Made%20with-Zig-yellow.svg)](https://ziglang.org/)
  [![Zig 0.16.0-dev](https://img.shields.io/badge/Zig-0.16.0--dev-orange.svg)](https://ziglang.org/download/)
  [![QUIC](https://img.shields.io/badge/QUIC-RFC%209000-blue.svg)](https://tools.ietf.org/html/rfc9000)
  [![HTTP](https://img.shields.io/badge/HTTP-1.1%20%7C%202%20%7C%203-green.svg)](https://tools.ietf.org/html/rfc7540)
  [![TLS](https://img.shields.io/badge/TLS-1.3-red.svg)](https://tools.ietf.org/html/rfc8446)
  [![OAuth2](https://img.shields.io/badge/OAuth2-supported-purple.svg)](https://tools.ietf.org/html/rfc6749)
  [![JWT](https://img.shields.io/badge/JWT-HS256-lightblue.svg)](https://tools.ietf.org/html/rfc7519)
</div>

**Advanced RPC framework for Zig.** A neutral, low-level core library for gRPC-like transports, serialization, and service definitions.

## ✨ Features

- **🚀 Full RPC Support**: Unary, client-streaming, server-streaming, and bidirectional streaming
- **🔒 Security First**: TLS 1.3, JWT authentication, OAuth2 token handling
- **⚡ High Performance**: HTTP/2, HTTP/3, and QUIC transport with 0-RTT connection resumption
- **🛠️ Developer Experience**: Complete .proto file parsing and Zig code generation
- **🔄 Load Balancing**: Multiple strategies (round-robin, least connections, weighted)
- **📊 Monitoring**: Comprehensive benchmarking and performance metrics
- **🌐 Protocol Buffer**: Full protobuf v3 support with JSON codec for debugging

## 🏗️ Architecture

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

## 🚀 Quick Start

### Installation

Add zRPC as a dependency using `zig fetch`:

```bash
zig fetch --save https://github.com/ghostkellz/zrpc
```

Or manually add to your `build.zig.zon`:

```zig
.dependencies = .{
    .zrpc = .{
        .url = "https://github.com/ghostkellz/zrpc/archive/refs/heads/main.tar.gz",
        .hash = "...", // Will be filled by `zig fetch`
    },
},
```

### Basic Usage

```zig
const std = @import("std");
const zrpc = @import("zrpc");

// Define your service
const MyService = struct {
    pub fn sayHello(self: *MyService, req: *const HelloRequest) !HelloResponse {
        return HelloResponse{ .message = "Hello, " ++ req.name };
    }
};

// Start server
var server = try zrpc.Server.init(allocator, .{ .port = 8080 });
try server.registerService(MyService{});
try server.start();

// Create client
var client = try zrpc.Client.init(allocator, "localhost:8080");
const response = try client.call("MyService/sayHello", HelloRequest{ .name = "World" });
```

## 🔧 Building

```bash
# Build the library
zig build

# Run tests
zig build test

# Run benchmarks
zig build run -- benchmark

# Generate code from .proto files
zig build run -- codegen input.proto output.zig
```

## 📈 Performance

zRPC is designed for high performance with:

- **Zero-copy serialization** where possible
- **Connection pooling** with automatic cleanup
- **QUIC 0-RTT** for minimal latency
- **Efficient load balancing** algorithms
- **Comprehensive benchmarking** vs gRPC C++

## 🔐 Security

- **TLS 1.3** encryption with certificate validation
- **JWT tokens** with HMAC-SHA256 signing
- **OAuth2** token handling and validation
- **Authentication middleware** for request validation

## 🤝 Contributing

Contributions are welcome! Please see our [Contributing Guide](CONTRIBUTING.md) for details.

## 📄 License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## 🙏 Acknowledgments

- Built with the amazing [Zig](https://ziglang.org/) programming language
- Inspired by [gRPC](https://grpc.io/) but designed for Zig-native development
- QUIC implementation based on [RFC 9000](https://tools.ietf.org/html/rfc9000)
