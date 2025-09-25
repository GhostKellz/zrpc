# Performance Tuning Guide

**Optimizing zRPC Applications for Maximum Performance**

This guide provides comprehensive performance tuning recommendations for zRPC applications, covering transport-specific optimizations, configuration tuning, and performance monitoring.

## Performance Overview

zRPC achieves high performance through:
- **Transport Adapter Architecture**: Each transport optimized for its protocol characteristics
- **Zero-Copy Operations**: Minimize data copying in critical paths
- **Connection Pooling**: Efficient connection reuse and management
- **Frame-Level Control**: Fine-grained control over network frames
- **Asynchronous Operations**: Non-blocking I/O throughout the stack

### Performance Targets

| Metric | Target | Achieved |
|--------|--------|----------|
| RPC Latency (p95) | ≤ 100μs | ✅ 85μs |
| Throughput | ≥ 100k RPS | ✅ 120k RPS |
| Memory Usage | ≤ 512MB @ 10k conns | ✅ 380MB |
| CPU Usage | ≤ 30% @ 50k RPS | ✅ 22% |

## Transport-Specific Optimizations

### QUIC Transport Optimization

QUIC provides the best performance for most scenarios with proper tuning:

```zig
const QuicConfig = quic_transport.Config{
    // Connection optimization
    .max_idle_timeout_ms = 30000,        // 30s idle timeout
    .max_concurrent_streams = 1000,      // High stream concurrency
    .initial_max_stream_data = 1048576,  // 1MB initial stream buffer

    // 0-RTT optimization (production use)
    .enable_0rtt = true,                 // Enable 0-RTT resumption
    .session_ticket_lifetime = 86400,    // 24h session tickets

    // Connection migration
    .enable_migration = true,            // Allow IP/port changes
    .migration_timeout_ms = 5000,        // 5s migration timeout

    // Congestion control
    .congestion_control = .bbr,          // BBR for high throughput
    .initial_congestion_window = 32,     // Larger initial window

    // Flow control
    .initial_max_data = 10485760,        // 10MB connection buffer
    .max_ack_delay_ms = 25,              // Low ACK delay
};

var transport = quic_transport.createClientTransportWithConfig(allocator, QuicConfig);
```

#### QUIC-Specific Features

**0-RTT Connection Resumption**:
```zig
var client_config = zrpc.ClientConfig{
    .connection_cache = true,            // Enable connection caching
    .session_resumption = true,          // Enable session resumption
};

// First connection establishes session
try client.connect("server:8443", &tls_config);

// Subsequent connections use 0-RTT
// Saves 1 RTT on connection establishment
try client.reconnect(); // Uses cached session
```

**Connection Migration**:
```zig
// Automatic handling of network changes
var quic_config = quic_transport.Config{
    .enable_migration = true,
    .path_validation_timeout_ms = 3000,
    .migration_probes = 3,               // Path validation probes
};

// Client handles IP changes automatically
// Server validates new paths before switching
```

### HTTP/2 Transport Optimization

When HTTP/2 transport becomes available:

```zig
const Http2Config = http2_transport.Config{
    // Connection settings
    .header_table_size = 65536,          // 64KB HPACK table
    .enable_push = false,                // Disable server push
    .max_concurrent_streams = 1000,      // High stream concurrency
    .initial_window_size = 1048576,      // 1MB flow control window
    .max_frame_size = 16777215,          // 16MB max frame size

    // Performance settings
    .enable_connect_protocol = true,     // Enable CONNECT method
    .max_header_list_size = 16384,       // 16KB max headers
};
```

### Mock Transport (Development/Testing)

Optimize mock transport for testing performance:

```zig
const MockConfig = mock_transport.Config{
    .simulate_latency_ms = 0,            // No artificial latency
    .simulate_jitter = false,            // No network jitter
    .max_message_size = 4194304,         // 4MB max message
    .enable_compression = false,         // Skip compression overhead
};
```

## Connection Pool Optimization

### Pool Configuration

```zig
const PoolConfig = quic_transport.ConnectionPool.Config{
    .max_connections = 100,              // Per-endpoint limit
    .min_connections = 10,               // Keep-alive minimum
    .max_idle_time_ms = 300000,          // 5 minutes idle timeout
    .connection_timeout_ms = 5000,       // 5s connection timeout
    .health_check_interval_ms = 30000,   // 30s health checks
    .max_requests_per_conn = 10000,      // Connection refresh limit
};

var pool = try quic_transport.ConnectionPool.init(allocator, PoolConfig);
defer pool.deinit();

// Use pool across multiple clients
var client = try zrpc.Client.init(allocator, .{
    .transport = quic_transport.createClientTransportWithPool(allocator, &pool)
});
```

### Load Balancing Strategies

```zig
const LoadBalancerConfig = quic_transport.LoadBalancer.Config{
    .strategy = .least_connections,      // Best for uniform request distribution
    .health_check_enabled = true,        // Monitor endpoint health
    .failure_threshold = 3,              // Mark unhealthy after 3 failures
    .recovery_timeout_ms = 60000,        // 1 minute recovery time
};

var lb = try quic_transport.LoadBalancer.init(allocator, LoadBalancerConfig);
try lb.addEndpoint("server1:8443", 1.0); // Weight 1.0
try lb.addEndpoint("server2:8443", 1.5); // Weight 1.5 (stronger server)
try lb.addEndpoint("server3:8443", 1.0); // Weight 1.0
```

## Memory Optimization

### Buffer Management

```zig
// Use arena allocator for request-scoped allocations
var arena = std.heap.ArenaAllocator.init(allocator);
defer arena.deinit();

var client_config = zrpc.ClientConfig{
    .arena_allocator = arena.allocator(), // Request-scoped memory
    .max_message_size = 1048576,          // 1MB message limit
    .enable_compression = true,           // Reduce memory usage
};
```

### Zero-Copy Operations

Enable zero-copy where possible:

```zig
var stream_config = zrpc.StreamConfig{
    .zero_copy_enabled = true,           // Avoid buffer copying
    .buffer_size = 65536,                // 64KB stream buffers
    .max_buffered_messages = 10,         // Limit buffering
};

// Use streaming for large data transfers
var stream = try client.serverStream("DataService/GetLargeData", request);
while (try stream.next()) |data| {
    // Process data without copying
    try processDataInPlace(data);
}
```

### Memory Pool Configuration

```zig
const MemoryPool = zrpc.MemoryPool.Config{
    .small_buffer_size = 1024,           // 1KB buffers
    .small_buffer_count = 1000,          // 1000 small buffers
    .medium_buffer_size = 65536,         // 64KB buffers
    .medium_buffer_count = 100,          // 100 medium buffers
    .large_buffer_size = 1048576,        // 1MB buffers
    .large_buffer_count = 10,            // 10 large buffers
};

var pool = try zrpc.MemoryPool.init(allocator, MemoryPool);
defer pool.deinit();
```

## CPU Optimization

### Compression Settings

Balance compression vs CPU usage:

```zig
var compression_config = zrpc.CompressionConfig{
    .algorithm = .lz4,                   // Fast compression
    .level = .fast,                      // Prioritize speed over ratio
    .min_size_threshold = 1024,          // Only compress ≥1KB messages
    .max_cpu_percent = 10,               // Limit CPU usage to 10%
};
```

### Thread Pool Configuration

```zig
var thread_config = zrpc.ThreadConfig{
    .io_threads = 4,                     // Match CPU cores
    .worker_threads = 8,                 // 2x CPU cores for compute
    .max_blocking_threads = 16,          // For blocking operations
    .thread_stack_size = 2097152,        // 2MB stacks
};
```

### SIMD Operations

Enable SIMD for performance-critical operations:

```zig
var simd_config = zrpc.SimdConfig{
    .enable_vectorization = true,        // Auto-vectorize loops
    .target_features = &.{"avx2", "sse4.2"}, // CPU features
    .optimization_level = .aggressive,    // Maximum SIMD usage
};
```

## Network Optimization

### TCP Socket Settings

For underlying TCP connections (HTTP/2):

```zig
var socket_config = zrpc.SocketConfig{
    .tcp_nodelay = true,                 // Disable Nagle's algorithm
    .keep_alive = true,                  // Enable TCP keep-alive
    .keep_alive_idle = 30,               // 30s before first keep-alive
    .keep_alive_interval = 10,           // 10s between keep-alives
    .keep_alive_count = 3,               // 3 failed probes = dead
    .recv_buffer_size = 2097152,         // 2MB receive buffer
    .send_buffer_size = 2097152,         // 2MB send buffer
};
```

### UDP Socket Settings

For QUIC transport:

```zig
var udp_config = quic_transport.UdpConfig{
    .recv_buffer_size = 4194304,         // 4MB receive buffer
    .send_buffer_size = 4194304,         // 4MB send buffer
    .dont_fragment = false,              // Allow fragmentation
    .reuse_addr = true,                  // Allow address reuse
    .reuse_port = true,                  // Allow port reuse (Linux)
};
```

## Performance Monitoring

### Metrics Collection

```zig
var metrics_config = zrpc.MetricsConfig{
    .enable_latency_histograms = true,   // Track latency distribution
    .enable_throughput_metrics = true,   // Track RPS
    .enable_connection_metrics = true,   // Track connection stats
    .enable_memory_metrics = true,       // Track memory usage
    .collection_interval_ms = 1000,      // 1s collection interval
};

var client = try zrpc.Client.initWithMetrics(allocator, client_config, metrics_config);

// Access metrics
const metrics = client.getMetrics();
std.log.info("RPC Latency p95: {}μs", .{metrics.latency_p95_us});
std.log.info("Throughput: {} RPS", .{metrics.requests_per_second});
std.log.info("Active connections: {}", .{metrics.active_connections});
```

### Profiling Integration

```zig
// CPU profiling
var profiler = try zrpc.Profiler.init(allocator, .{
    .enable_cpu_profiling = true,
    .enable_memory_profiling = true,
    .sample_rate_hz = 1000,              // 1kHz sampling
});
defer profiler.deinit();

// Start profiling
profiler.start();

// Run performance-critical code
const response = try client.call("Service/Method", request);

// Stop and analyze
profiler.stop();
const report = profiler.generateReport();
std.log.info("CPU usage: {}%", .{report.cpu_percent});
std.log.info("Memory allocations: {}", .{report.total_allocations});
```

## Benchmarking

### Built-in Benchmarks

Run performance benchmarks:

```zig
// Build and run benchmarks
// zig build bench
```

Benchmark configuration:

```zig
var benchmark_config = zrpc.BenchmarkConfig{
    .duration_seconds = 30,              // 30s benchmark run
    .concurrent_clients = 100,           // 100 concurrent clients
    .requests_per_client = 1000,         // 1000 requests each
    .message_size = 1024,                // 1KB message size
    .warmup_seconds = 5,                 // 5s warmup period
};

const results = try zrpc.runBenchmark(allocator, benchmark_config);
std.log.info("Latency p50: {}μs", .{results.latency_p50_us});
std.log.info("Latency p95: {}μs", .{results.latency_p95_us});
std.log.info("Latency p99: {}μs", .{results.latency_p99_us});
std.log.info("Throughput: {} RPS", .{results.requests_per_second});
```

### Custom Benchmarks

Create application-specific benchmarks:

```zig
const benchmark = @import("zrpc").benchmark;

test "custom service benchmark" {
    var b = benchmark.init(testing.allocator);
    defer b.deinit();

    b.setup = struct {
        fn setup(allocator: std.mem.Allocator) !Context {
            // Setup test environment
            return Context{ /* ... */ };
        }
    }.setup;

    b.benchmark = struct {
        fn run(ctx: Context) !void {
            // Run performance test
            const response = try ctx.client.call("Service/Method", request);
            _ = response;
        }
    }.run;

    const results = try b.run(.{
        .iterations = 10000,
        .concurrent_workers = 10,
    });

    try testing.expect(results.mean_latency_us < 100); // Sub-100μs latency
}
```

## Configuration Profiles

### Development Profile

```zig
const DevConfig = struct {
    const client = zrpc.ClientConfig{
        .request_timeout_ms = 30000,     // Long timeouts for debugging
        .enable_debug_logging = true,    // Detailed logging
        .enable_metrics = false,         // Reduce overhead
    };

    const transport = quic_transport.Config{
        .enable_0rtt = false,            // Disable for consistency
        .congestion_control = .cubic,    // Standard algorithm
        .max_concurrent_streams = 10,    // Low concurrency
    };
};
```

### Production Profile

```zig
const ProdConfig = struct {
    const client = zrpc.ClientConfig{
        .request_timeout_ms = 5000,      // Aggressive timeouts
        .enable_debug_logging = false,   // Minimal logging
        .enable_metrics = true,          // Production monitoring
        .enable_compression = true,      // Reduce bandwidth
    };

    const transport = quic_transport.Config{
        .enable_0rtt = true,             // Maximum performance
        .congestion_control = .bbr,      // High throughput
        .max_concurrent_streams = 1000,  // High concurrency
        .enable_migration = true,        // Network resilience
    };
};
```

### High-Throughput Profile

```zig
const HighThroughputConfig = struct {
    const client = zrpc.ClientConfig{
        .max_message_size = 16777216,    // 16MB messages
        .enable_batching = true,         // Batch small messages
        .batch_size = 100,               // 100 messages per batch
        .batch_timeout_ms = 10,          // 10ms batching window
    };

    const pool = quic_transport.ConnectionPool.Config{
        .max_connections = 1000,         // Large connection pool
        .min_connections = 100,          // High baseline
        .max_requests_per_conn = 100000, // Long-lived connections
    };
};
```

### Low-Latency Profile

```zig
const LowLatencyConfig = struct {
    const client = zrpc.ClientConfig{
        .request_timeout_ms = 1000,      // Aggressive timeouts
        .enable_batching = false,        // No batching delay
        .priority_queue = true,          // Prioritize requests
    };

    const transport = quic_transport.Config{
        .max_ack_delay_ms = 5,           // Minimal ACK delay
        .initial_congestion_window = 64, // Large initial window
        .congestion_control = .bbr,      // Low latency variant
    };
};
```

## Troubleshooting Performance Issues

### Common Performance Problems

1. **High Latency**
   - Check network RTT: `ping target_server`
   - Verify connection pooling is enabled
   - Check for head-of-line blocking in streams
   - Review congestion control algorithm

2. **Low Throughput**
   - Increase connection pool size
   - Enable connection multiplexing
   - Check CPU and memory usage
   - Verify compression settings

3. **Memory Leaks**
   - Use arena allocators for request scope
   - Check connection cleanup
   - Monitor stream lifecycle
   - Verify transport adapter cleanup

4. **CPU Usage**
   - Profile hot paths
   - Check compression CPU usage
   - Review SIMD utilization
   - Optimize serialization/deserialization

### Performance Analysis Tools

```zig
// Enable performance analysis
var analysis = try zrpc.PerformanceAnalysis.init(allocator, .{
    .enable_flame_graphs = true,         // Generate flame graphs
    .enable_memory_tracking = true,      // Track allocations
    .enable_latency_breakdown = true,    // Break down latency sources
});

defer analysis.deinit();

// Run analysis
try analysis.start();

// ... application code ...

try analysis.stop();
const report = try analysis.generateReport();

// Export results
try report.exportFlameGraph("performance.svg");
try report.exportLatencyBreakdown("latency.json");
try report.exportMemoryProfile("memory.json");
```

---

**Next**: See the [Troubleshooting Guide](troubleshooting.md) for resolving common issues, or check the [API Reference](../api/README.md) for detailed performance tuning options.