# Troubleshooting Guide

**Common Issues and Solutions for zRPC Applications**

This guide helps diagnose and resolve common issues when developing and deploying zRPC applications.

## Quick Diagnostic Tools

### Health Check Commands

```bash
# Build and run diagnostics
zig build test                  # Run all tests
zig build beta                  # Run integration tests
zig build bench                 # Run performance tests

# Check specific components
zig build alpha1               # Test basic functionality
zig build rc1                  # Test API compliance
```

### Debug Logging

Enable detailed logging for troubleshooting:

```zig
var client_config = zrpc.ClientConfig{
    .enable_debug_logging = true,
    .log_level = .debug,
    .log_transport_frames = true,    // Log frame-level details
    .log_connection_events = true,   // Log connection lifecycle
};

std.log.debug("Client connecting to {s}", .{endpoint});
```

## Connection Issues

### Problem: Connection Failed

**Symptoms:**
- `error.ConnectionFailed` when calling `client.connect()`
- Timeout errors during connection establishment
- "No route to host" errors

**Diagnosis:**

```zig
// Test basic connectivity
const result = client.ping() catch |err| switch (err) {
    error.ConnectionFailed => {
        std.log.err("Cannot reach server at {s}", .{endpoint});
        // Check network connectivity
        return err;
    },
    error.ConnectionTimeout => {
        std.log.err("Connection timeout to {s}", .{endpoint});
        // Check firewall, increase timeout
        return err;
    },
    else => return err,
};
```

**Solutions:**

1. **Network Connectivity**
   ```bash
   # Test basic connectivity
   ping server_hostname
   telnet server_hostname 8443
   ```

2. **Firewall Configuration**
   ```bash
   # Check if port is open
   nmap -p 8443 server_hostname

   # For QUIC (UDP)
   nc -u server_hostname 8443
   ```

3. **Configuration Check**
   ```zig
   var transport = quic_transport.createClientTransport(allocator);

   // Verify endpoint format
   try client.connect("server.example.com:8443", &tls_config);
   // NOT: quic://server.example.com:8443 (old v1.x format)
   ```

### Problem: Connection Drops

**Symptoms:**
- `error.ConnectionReset` during RPC calls
- Intermittent connection failures
- "Connection lost" errors

**Diagnosis:**

```zig
// Enable connection monitoring
var transport_config = quic_transport.Config{
    .enable_keep_alive = true,
    .keep_alive_interval_ms = 30000,     // 30s ping interval
    .connection_timeout_ms = 60000,      // 60s timeout
};

// Check connection health
if (!client.isConnected()) {
    std.log.warn("Connection lost, attempting reconnect...");
    try client.reconnect();
}
```

**Solutions:**

1. **Enable Keep-Alive**
   ```zig
   var config = quic_transport.Config{
       .enable_keep_alive = true,
       .keep_alive_interval_ms = 30000,
       .max_idle_timeout_ms = 300000,   // 5 minutes
   };
   ```

2. **Connection Pooling**
   ```zig
   var pool_config = quic_transport.ConnectionPool.Config{
       .max_connections = 10,
       .health_check_interval_ms = 30000,
       .auto_reconnect = true,
   };
   ```

3. **Retry Logic**
   ```zig
   const max_retries = 3;
   var attempt: u32 = 0;

   while (attempt < max_retries) {
       const response = client.call("Service/Method", request) catch |err| switch (err) {
           error.ConnectionReset, error.NotConnected => {
               attempt += 1;
               if (attempt < max_retries) {
                   std.log.warn("Retry {} of {}", .{attempt, max_retries});
                   std.time.sleep(1000 * std.time.ns_per_ms); // 1s backoff
                   try client.reconnect();
                   continue;
               }
               return err;
           },
           else => return err,
       };
       break;
   }
   ```

## TLS/Security Issues

### Problem: TLS Handshake Failure

**Symptoms:**
- `error.TlsHandshakeFailed` during connection
- Certificate validation errors
- Protocol version mismatch

**Diagnosis:**

```zig
var tls_config = zrpc.TlsConfig{
    .cert_path = "cert.pem",
    .key_path = "key.pem",
    .ca_cert_path = "ca.pem",           // For client cert validation
    .verify_hostname = true,            // Check hostname matches cert
    .min_protocol_version = .tls1_3,    // Enforce TLS 1.3
};

// Test TLS configuration
const tls_test = zrpc.TlsConfig.validate(&tls_config) catch |err| switch (err) {
    error.InvalidCertificate => {
        std.log.err("Certificate file invalid or corrupted");
        return err;
    },
    error.CertificateExpired => {
        std.log.err("Certificate has expired");
        return err;
    },
    error.InvalidPrivateKey => {
        std.log.err("Private key file invalid or corrupted");
        return err;
    },
    else => return err,
};
```

**Solutions:**

1. **Certificate Validation**
   ```bash
   # Check certificate validity
   openssl x509 -in cert.pem -text -noout

   # Check certificate expiration
   openssl x509 -in cert.pem -checkend 86400

   # Verify certificate chain
   openssl verify -CAfile ca.pem cert.pem
   ```

2. **Hostname Verification**
   ```zig
   var tls_config = zrpc.TlsConfig{
       .verify_hostname = false,  // Disable for testing only
       // OR provide correct hostname
       .expected_hostname = "server.example.com",
   };
   ```

3. **Self-Signed Certificates**
   ```zig
   var tls_config = zrpc.TlsConfig{
       .allow_self_signed = true,     // Development only
       .verify_chain = false,         // Skip chain validation
   };
   ```

### Problem: Authentication Failures

**Symptoms:**
- `error.Unauthorized` on RPC calls
- JWT token validation failures
- OAuth2 token expired errors

**Diagnosis:**

```zig
var auth_config = zrpc.AuthConfig{
    .type = .jwt,
    .token = jwt_token,
    .validate_expiry = true,
};

// Test token validity
const token_info = zrpc.auth.validateJwt(jwt_token) catch |err| switch (err) {
    error.TokenExpired => {
        std.log.err("JWT token has expired");
        // Refresh token
        return err;
    },
    error.InvalidSignature => {
        std.log.err("JWT signature validation failed");
        // Check signing key
        return err;
    },
    error.InvalidClaims => {
        std.log.err("JWT claims validation failed");
        // Check token contents
        return err;
    },
    else => return err,
};
```

**Solutions:**

1. **JWT Token Issues**
   ```zig
   // Refresh expired tokens
   if (token_expired) {
       const new_token = try auth_client.refreshToken(refresh_token);
       auth_config.token = new_token;
   }

   // Verify token format
   const decoded = try zrpc.auth.decodeJwt(jwt_token);
   std.log.debug("Token expires: {}", .{decoded.exp});
   ```

2. **OAuth2 Configuration**
   ```zig
   var oauth_config = zrpc.OAuth2Config{
       .client_id = "your_client_id",
       .client_secret = "your_client_secret",
       .token_endpoint = "https://auth.example.com/token",
       .auto_refresh = true,            // Automatic token refresh
   };
   ```

## Performance Issues

### Problem: High Latency

**Symptoms:**
- RPC calls taking longer than expected
- Timeouts on fast operations
- Variable response times

**Diagnosis:**

```zig
// Enable latency tracking
var metrics_config = zrpc.MetricsConfig{
    .enable_latency_histograms = true,
    .enable_request_tracing = true,
};

const start_time = std.time.nanoTimestamp();
const response = try client.call("Service/Method", request);
const end_time = std.time.nanoTimestamp();
const latency_us = @intCast(u64, (end_time - start_time) / 1000);

if (latency_us > 1000) { // > 1ms
    std.log.warn("High latency detected: {}μs", .{latency_us});
}
```

**Solutions:**

1. **Connection Pooling**
   ```zig
   var pool_config = quic_transport.ConnectionPool.Config{
       .max_connections = 50,           // Increase pool size
       .min_connections = 10,           // Keep warm connections
       .connection_reuse = true,        // Reuse connections
   };
   ```

2. **QUIC Optimizations**
   ```zig
   var quic_config = quic_transport.Config{
       .enable_0rtt = true,             // 0-RTT connection resumption
       .congestion_control = .bbr,      // Better congestion control
       .initial_congestion_window = 32, // Larger initial window
   };
   ```

3. **Request Batching**
   ```zig
   var client_config = zrpc.ClientConfig{
       .enable_batching = true,         // Batch small requests
       .batch_size = 10,                // 10 requests per batch
       .batch_timeout_ms = 5,           // 5ms batching window
   };
   ```

### Problem: Low Throughput

**Symptoms:**
- Cannot achieve expected requests per second
- CPU or memory bottlenecks
- Connection saturation

**Diagnosis:**

```zig
// Monitor resource usage
const metrics = client.getMetrics();
std.log.info("RPS: {}, CPU: {}%, Memory: {}MB", .{
    metrics.requests_per_second,
    metrics.cpu_percent,
    metrics.memory_usage_mb
});

// Check connection utilization
std.log.info("Active connections: {}/{}", .{
    metrics.active_connections,
    metrics.max_connections
});
```

**Solutions:**

1. **Increase Concurrency**
   ```zig
   var transport_config = quic_transport.Config{
       .max_concurrent_streams = 1000,  // More parallel streams
   };

   var pool_config = quic_transport.ConnectionPool.Config{
       .max_connections = 100,          // More connections
   };
   ```

2. **Optimize Serialization**
   ```zig
   var codec_config = zrpc.CodecConfig{
       .enable_compression = true,      // Reduce bandwidth
       .compression_algorithm = .lz4,   // Fast compression
       .zero_copy_enabled = true,       // Avoid buffer copying
   };
   ```

3. **Load Balancing**
   ```zig
   var lb_config = quic_transport.LoadBalancer.Config{
       .strategy = .least_connections,  // Distribute load evenly
       .health_check_enabled = true,    // Remove unhealthy endpoints
   };
   ```

### Problem: Memory Leaks

**Symptoms:**
- Memory usage grows over time
- Out of memory errors
- Performance degradation

**Diagnosis:**

```zig
// Enable memory tracking
var memory_tracker = try zrpc.MemoryTracker.init(allocator);
defer memory_tracker.deinit();

// Track allocations
const before_memory = memory_tracker.getCurrentUsage();
const response = try client.call("Service/Method", request);
const after_memory = memory_tracker.getCurrentUsage();

if (after_memory > before_memory + 1024 * 1024) { // +1MB
    std.log.warn("Potential memory leak detected");
    memory_tracker.printAllocations();
}
```

**Solutions:**

1. **Proper Resource Cleanup**
   ```zig
   var client = try zrpc.Client.init(allocator, config);
   defer client.deinit(); // Always call deinit

   var transport = quic_transport.createClientTransport(allocator);
   defer transport.deinit(); // Transport cleanup
   ```

2. **Arena Allocators**
   ```zig
   var arena = std.heap.ArenaAllocator.init(allocator);
   defer arena.deinit(); // Free all at once

   var client_config = zrpc.ClientConfig{
       .arena_allocator = arena.allocator(),
   };
   ```

3. **Connection Lifecycle**
   ```zig
   // Properly close streams
   var stream = try client.serverStream("Service/Method", request);
   defer stream.close();

   while (try stream.next()) |message| {
       // Process message
   }
   ```

## Transport-Specific Issues

### QUIC Transport Issues

**Problem: UDP Port Blocked**

```bash
# Test UDP connectivity
nc -u server_hostname 8443
```

**Solution:**
```zig
// Try different port
try client.connect("server:8444", &tls_config);

// Or use HTTP/2 fallback
var http2_transport = http2_transport.createClientTransport(allocator);
var fallback_client = try zrpc.Client.init(allocator, .{
    .transport = http2_transport
});
```

**Problem: Connection Migration Failures**

**Diagnosis:**
```zig
var quic_config = quic_transport.Config{
    .enable_migration = true,
    .migration_timeout_ms = 5000,
    .debug_migration = true,            // Enable migration logging
};
```

**Solution:**
```zig
// Disable migration if problematic
var quic_config = quic_transport.Config{
    .enable_migration = false,          // Disable for stability
};

// Or increase timeouts
var quic_config = quic_transport.Config{
    .migration_timeout_ms = 30000,      // 30s timeout
    .path_validation_timeout_ms = 10000, // 10s validation
};
```

### Mock Transport Issues (Testing)

**Problem: Test Timeouts**

```zig
// Configure mock transport for testing
var mock_config = mock_transport.Config{
    .simulate_latency_ms = 0,           // No artificial delay
    .simulate_failures = false,         // Disable failure simulation
    .max_message_size = 1048576,        // 1MB limit
};
```

**Problem: Unrealistic Test Behavior**

```zig
// Make mock transport more realistic
var mock_config = mock_transport.Config{
    .simulate_latency_ms = 10,          // 10ms latency
    .simulate_jitter = true,            // Add network jitter
    .failure_rate = 0.01,               // 1% failure rate
};
```

## Build and Compilation Issues

### Problem: Module Import Errors

**Symptoms:**
- `error: unable to find module 'zrpc'`
- Build dependency resolution failures

**Solution:**

1. **Check build.zig Configuration**
   ```zig
   // Correct import structure
   const zrpc_core = b.dependency("zrpc-core", .{});
   exe.root_module.addImport("zrpc-core", zrpc_core.module("zrpc-core"));

   const quic_transport = b.dependency("zrpc-transport-quic", .{});
   exe.root_module.addImport("zrpc-transport-quic", quic_transport.module("zrpc-transport-quic"));
   ```

2. **Update Source Imports**
   ```zig
   // Old (v1.x)
   const zrpc = @import("zrpc");

   // New (v2.x)
   const zrpc = @import("zrpc-core");
   const quic_transport = @import("zrpc-transport-quic");
   ```

### Problem: API Compatibility Issues

**Symptoms:**
- Compilation errors with std library changes
- `std.Target.current` vs `builtin.target` conflicts

**Solution:**

Check Zig version compatibility:
```bash
zig version  # Should be 0.16.0-dev or compatible

# Update to compatible version if needed
```

Update API calls:
```zig
// Old API
const target = std.Target.current;

// New API
const target = builtin.target;
```

## Debugging Strategies

### Enable Comprehensive Logging

```zig
var debug_config = zrpc.DebugConfig{
    .enable_all_logging = true,
    .log_level = .debug,
    .log_transport_frames = true,
    .log_connection_events = true,
    .log_stream_lifecycle = true,
    .log_memory_allocations = true,
};
```

### Use Contract Tests

```zig
// Verify transport adapter compliance
const contract_tests = @import("zrpc-core").contract_tests;

test "transport compliance" {
    var transport = your_transport.createClientTransport(testing.allocator);
    defer transport.deinit();

    try contract_tests.runClientTransportTests(testing.allocator, transport);
}
```

### Performance Profiling

```zig
// Enable performance profiling
var profiler = try zrpc.Profiler.init(allocator, .{
    .enable_cpu_profiling = true,
    .enable_memory_profiling = true,
    .sample_rate_hz = 1000,
});
defer profiler.deinit();

profiler.start();
// ... run code ...
profiler.stop();

const report = profiler.generateReport();
try report.exportFlameGraph("profile.svg");
```

## Getting Additional Help

### Diagnostic Commands

```bash
# Run full test suite
zig build test

# Test specific components
zig build alpha1    # Basic functionality
zig build beta      # Integration tests
zig build rc1       # API compliance
zig build bench     # Performance tests

# Generate diagnostic report
zig build --summary all
```

### Community Resources

1. **Documentation**: Check [API Reference](../api/README.md)
2. **Examples**: See `/examples/` directory
3. **GitHub Issues**: Report bugs and get help
4. **Performance Guide**: See [Performance Tuning](performance-tuning.md)

### Debug Information Collection

When reporting issues, include:

1. **Environment Information**
   ```bash
   zig version
   uname -a
   ```

2. **Configuration Details**
   ```zig
   // Include your client/server configuration
   std.log.debug("Config: {}", .{config});
   ```

3. **Error Logs**
   - Enable debug logging
   - Include full stack traces
   - Capture transport-level errors

4. **Performance Metrics**
   ```zig
   const metrics = client.getMetrics();
   std.log.info("Metrics: {}", .{metrics});
   ```

---

**Next**: Check the [API Reference](../api/README.md) for detailed API documentation or see the [Migration Guide](migration-guide.md) if upgrading from v1.x.