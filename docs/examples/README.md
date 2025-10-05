# zRPC Examples

**Complete example applications demonstrating zRPC features**

This directory contains comprehensive examples showing different aspects of zRPC usage, from basic client-server patterns to advanced streaming and performance optimization.

## Getting Started Examples

### [Hello World](hello-world/)
The simplest possible zRPC application.

**What it demonstrates:**
- Basic client-server setup
- Unary RPC calls
- Transport adapter configuration
- TLS setup

**Files:**
- `server.zig` - Simple greeting server
- `client.zig` - Client making greeting requests
- `build.zig` - Build configuration

**Run:**
```bash
cd docs/examples/hello-world
zig build server  # Terminal 1
zig build client  # Terminal 2
```

### [Calculator Service](calculator/)
A complete calculator service with error handling.

**What it demonstrates:**
- Multiple RPC methods
- Error handling and validation
- Request/response patterns
- Service registration

**Features:**
- Add, subtract, multiply, divide operations
- Division by zero error handling
- Input validation
- Structured responses

**Run:**
```bash
cd docs/examples/calculator
zig build server
zig build client
```

## Streaming Examples

### [Chat Application](streaming-chat/)
Real-time chat with all streaming patterns.

**What it demonstrates:**
- Client streaming (batch messages)
- Server streaming (room subscription)
- Bidirectional streaming (interactive chat)
- Stream lifecycle management

**Components:**
- Chat server with room management
- Batch message client (client streaming)
- Room subscriber (server streaming)
- Interactive chat client (bidirectional)

**Run:**
```bash
cd docs/examples/streaming-chat
zig build chat-server    # Terminal 1
zig build batch-client   # Terminal 2
zig build subscriber     # Terminal 3
zig build chat-client    # Terminal 4
```

### [File Transfer](file-transfer/)
High-performance file transfer with streaming.

**What it demonstrates:**
- Large data streaming
- Progress reporting
- Flow control
- Error recovery
- Performance optimization

**Features:**
- Chunked file upload/download
- Transfer progress tracking
- Resume interrupted transfers
- Bandwidth throttling

## Authentication Examples

### [JWT Authentication](jwt-auth/)
Complete JWT-based authentication system.

**What it demonstrates:**
- JWT token generation and validation
- Authentication middleware
- Protected RPC methods
- Token refresh patterns

**Components:**
- Auth server with user management
- Protected service requiring authentication
- Client with token handling

**Run:**
```bash
cd docs/examples/jwt-auth
zig build auth-server
zig build protected-server
zig build client
```

### [OAuth2 Integration](oauth2-integration/)
OAuth2 authentication with external providers.

**What it demonstrates:**
- OAuth2 authorization code flow
- Token exchange and refresh
- External provider integration
- Secure token storage

## Transport Examples

### [QUIC Features](quic-features/)
Demonstrates advanced QUIC transport capabilities.

**What it demonstrates:**
- 0-RTT connection resumption
- Connection migration
- Multiple stream types
- QUIC-specific optimizations

**Components:**
- Server with QUIC optimization
- Client demonstrating 0-RTT
- Connection migration testing
- Performance comparison

**Run:**
```bash
cd docs/examples/quic-features
zig build server
zig build client-0rtt
zig build client-migration
```

### [Transport Comparison](transport-comparison/)
Benchmarking different transport adapters.

**What it demonstrates:**
- Performance comparison (QUIC vs HTTP/2)
- Transport-specific optimizations
- Benchmarking methodology
- Connection pooling effects

## Performance Examples

### [High Throughput Service](high-throughput/)
Optimized for maximum requests per second.

**What it demonstrates:**
- Connection pooling strategies
- Request batching
- Memory optimization
- CPU optimization techniques

**Features:**
- 100k+ RPS capability
- Memory pooling
- Zero-copy operations
- SIMD optimizations

**Run:**
```bash
cd docs/examples/high-throughput
zig build server
zig build load-generator
zig build benchmark
```

### [Low Latency Trading](low-latency/)
Ultra-low latency trading system simulation.

**What it demonstrates:**
- Sub-millisecond latency optimization
- Real-time market data streaming
- Order processing pipeline
- Latency measurement

**Components:**
- Market data server (server streaming)
- Order processing service (unary)
- Trading client with latency tracking

## Production Examples

### [Microservices Architecture](microservices/)
Complete microservices setup with service discovery.

**What it demonstrates:**
- Service-to-service communication
- Load balancing
- Health checks
- Circuit breakers
- Distributed tracing

**Services:**
- User service
- Order service
- Payment service
- API Gateway
- Service registry

**Run:**
```bash
cd docs/examples/microservices
zig build services    # Starts all services
zig build gateway     # API Gateway
zig build client      # Test client
```

### [Production Deployment](production/)
Production-ready setup with monitoring.

**What it demonstrates:**
- TLS certificate management
- Logging and metrics
- Graceful shutdown
- Configuration management
- Health monitoring

**Features:**
- Real TLS certificates
- Prometheus metrics export
- Structured logging
- Docker deployment
- Kubernetes manifests

## Testing Examples

### [Contract Testing](contract-testing/)
Comprehensive testing strategies.

**What it demonstrates:**
- Transport adapter contract tests
- Service interface testing
- Mock transport usage
- Integration testing patterns

**Test Types:**
- Unit tests with mocks
- Integration tests
- Contract tests
- Load tests
- Chaos tests

**Run:**
```bash
cd docs/examples/contract-testing
zig build test-unit
zig build test-integration
zig build test-contract
```

### [RC-4: Stress Testing](../../examples/rc4_test.zig) 🆕
**Release Candidate validation: Stress testing and edge case handling**

**What it demonstrates:**
- High connection count testing (10k+ concurrent)
- Long-running connection stability
- Network failure resilience
- Resource exhaustion recovery
- Malformed packet handling
- Network partition scenarios
- Rapid connect/disconnect cycles
- Memory pressure scenarios

**Run:**
```bash
zig build rc4
```

### [RC-5: Final Validation](../../examples/rc5_test.zig) 🆕
**Release Candidate validation: End-to-end integration and performance**

**What it demonstrates:**
- End-to-end integration tests
- Performance benchmarking (p95 ≤ 100μs)
- Resource usage profiling
- Backward compatibility verification

**Run:**
```bash
zig build rc5
zig build preview  # Run both RC-4 and RC-5
```

### [Mock Transport](mock-transport/)
Testing with mock transport adapter.

**What it demonstrates:**
- Deterministic testing
- Error simulation
- Network condition simulation
- Test data management

## Advanced Examples

### [Custom Transport](custom-transport/)
Implementing a custom transport adapter.

**What it demonstrates:**
- Transport adapter interface
- Custom protocol implementation
- Contract test compliance
- Performance optimization

**Components:**
- Custom transport implementation
- Contract test suite
- Performance benchmarks
- Documentation

### [Protocol Buffers](protobuf-integration/)
Using Protocol Buffers with zRPC.

**What it demonstrates:**
- .proto file parsing
- Code generation
- Serialization/deserialization
- Schema evolution

**Features:**
- Complex message types
- Nested structures
- Repeated fields
- Optional/required fields

**Run:**
```bash
cd docs/examples/protobuf-integration
zig build codegen    # Generate Zig code from .proto
zig build server
zig build client
```

## Example Structure

Each example follows a consistent structure:

```
example-name/
├── src/
│   ├── server.zig       # Server implementation
│   ├── client.zig       # Client implementation
│   ├── types.zig        # Shared types
│   └── ...
├── build.zig            # Build configuration
├── README.md            # Example-specific documentation
├── .proto files        # Protocol definitions (if applicable)
└── certs/              # TLS certificates (development only)
```

## Running Examples

### Prerequisites

1. **Zig 0.16.0-dev** or compatible
2. **OpenSSL** (for TLS certificate generation)

### Quick Setup

```bash
# Clone the repository
git clone https://github.com/ghostkellz/zrpc.git
cd zrpc/docs/examples

# Generate development certificates (one-time setup)
./generate-certs.sh

# Choose an example
cd hello-world

# Build and run
zig build server  # Terminal 1
zig build client  # Terminal 2
```

### Development Certificates

Most examples use development TLS certificates for simplicity. **Never use these in production!**

To generate fresh development certificates:

```bash
cd docs/examples
chmod +x generate-certs.sh
./generate-certs.sh
```

This creates:
- `certs/server.crt` - Development server certificate
- `certs/server.key` - Development server private key
- `certs/ca.crt` - Development Certificate Authority

## Example Categories

| Category | Examples | Complexity |
|----------|----------|------------|
| **Basics** | hello-world, calculator | Beginner |
| **Streaming** | chat, file-transfer | Intermediate |
| **Auth** | jwt-auth, oauth2 | Intermediate |
| **Transport** | quic-features, comparison | Advanced |
| **Performance** | high-throughput, low-latency | Advanced |
| **Production** | microservices, deployment | Expert |
| **Testing** | contract-testing, mocks | Intermediate |
| **Advanced** | custom-transport, protobuf | Expert |

## Performance Baseline

Run performance benchmarks to establish baseline metrics:

```bash
cd docs/examples/high-throughput
zig build benchmark

# Expected results (on modern hardware):
# Latency p95: < 100μs
# Throughput: > 100k RPS
# Memory usage: < 512MB @ 10k connections
```

## Contributing Examples

To add a new example:

1. **Create directory**: `docs/examples/your-example/`
2. **Follow structure**: Use the standard example structure
3. **Add documentation**: Comprehensive README.md
4. **Test thoroughly**: Ensure it works on different platforms
5. **Update index**: Add to this README.md

Example guidelines:
- **Clear purpose**: Each example should demonstrate specific features
- **Self-contained**: Include all necessary code and configuration
- **Well-documented**: Explain what it demonstrates and how to run it
- **Production-ready patterns**: Show best practices, not just basic functionality

## Troubleshooting

### Common Issues

1. **Port already in use**
   ```bash
   # Check what's using the port
   lsof -i :8443
   # Kill the process or use a different port
   ```

2. **TLS certificate errors**
   ```bash
   # Regenerate development certificates
   cd docs/examples
   ./generate-certs.sh
   ```

3. **Build errors**
   ```bash
   # Clean and rebuild
   zig build clean
   zig build
   ```

4. **Connection timeouts**
   - Check firewall settings
   - Verify server is running
   - Try different network interface

### Getting Help

- **Documentation**: Check the [API Reference](../api/README.md)
- **Troubleshooting**: See [Troubleshooting Guide](../guides/troubleshooting.md)
- **Performance**: Check [Performance Tuning](../guides/performance-tuning.md)
- **Issues**: Report problems on [GitHub Issues](https://github.com/ghostkellz/zrpc/issues)

---

**Start exploring**: Try the [Hello World](hello-world/) example first, then move to more advanced examples based on your needs!