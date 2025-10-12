# zRPC Metrics Integration

**Prometheus metrics collection and monitoring for zRPC**

## Overview

zRPC provides built-in Prometheus metrics collection for monitoring RPC performance, transport health, and system resources. The metrics system is:

- **Thread-safe**: Uses atomic operations for concurrent updates
- **Low-overhead**: Minimal performance impact (< 1μs per metric)
- **Transport-agnostic**: Works with all transport adapters
- **Prometheus-compatible**: Standard text format for scraping

## Quick Start

### 1. Initialize Metrics Registry

```zig
const std = @import("std");
const metrics = @import("metrics.zig");

var registry = try metrics.MetricsRegistry.init(allocator);
defer registry.deinit();
```

### 2. Start Metrics Server

```zig
const metrics_server = @import("metrics_server.zig");

var server = try metrics_server.MetricsServer.init(allocator, &registry, 9090);
defer server.deinit();

try server.start();
// Metrics available at http://localhost:9090/metrics
```

### 3. Integrate with Transport

```zig
// Create transport with metrics
var transport = websocket.WebSocketTransportAdapter.initWithMetrics(allocator, &registry);

// Metrics are automatically recorded for:
// - Connection lifecycle
// - Stream operations
// - Bytes transferred
```

## Available Metrics

### RPC Metrics

| Metric | Type | Description |
|--------|------|-------------|
| `zrpc_requests_total` | Counter | Total RPC requests |
| `zrpc_requests_success_total` | Counter | Successful requests |
| `zrpc_requests_failed_total` | Counter | Failed requests |
| `zrpc_duration_microseconds` | Histogram | Request latency (μs) |

### Transport Metrics

| Metric | Type | Description |
|--------|------|-------------|
| `zrpc_transport_connections_active` | Gauge | Active connections |
| `zrpc_transport_connections_total` | Counter | Total connections |
| `zrpc_transport_bytes_sent_total` | Counter | Bytes sent |
| `zrpc_transport_bytes_received_total` | Counter | Bytes received |

### Stream Metrics

| Metric | Type | Description |
|--------|------|-------------|
| `zrpc_streams_active` | Gauge | Active streams |
| `zrpc_streams_total` | Counter | Total streams created |

### Compression Metrics

| Metric | Type | Description |
|--------|------|-------------|
| `zrpc_compression_bytes_before_total` | Counter | Bytes before compression |
| `zrpc_compression_bytes_after_total` | Counter | Bytes after compression |

## Recording Metrics

### Manual Recording

```zig
// RPC lifecycle
registry.recordRpcStart();
const start = std.time.nanoTimestamp();

// ... perform RPC ...

const duration_us = @divTrunc(std.time.nanoTimestamp() - start, 1000);
registry.recordRpcSuccess(duration_us);
// Or: registry.recordRpcFailure(duration_us);
```

### Automatic Recording (Transport Integration)

Metrics are automatically recorded when you use a metrics-enabled transport:

```zig
// Create transport with metrics
var transport = websocket.WebSocketTransportAdapter.initWithMetrics(
    allocator,
    &registry
);

// All operations automatically tracked:
var conn = try transport.connect(allocator, "ws://localhost:8080", null);
// ✓ recordTransportConnect() called

var stream = try conn.openStream();
// ✓ recordStreamOpen() called

try stream.writeFrame(.data, 0, payload);
// ✓ recordBytesTransferred(sent, 0) called

const frame = try stream.readFrame(allocator);
// ✓ recordBytesTransferred(0, received) called

stream.close();
// ✓ recordStreamClose() called

conn.close();
// ✓ recordTransportDisconnect() called
```

## Prometheus Integration

### Scraping Configuration

Add to `prometheus.yml`:

```yaml
scrape_configs:
  - job_name: 'zrpc'
    static_configs:
      - targets: ['localhost:9090']
    scrape_interval: 15s
```

### Example Queries

#### Request Rate
```promql
rate(zrpc_requests_total[5m])
```

#### Error Rate
```promql
rate(zrpc_requests_failed_total[5m]) / rate(zrpc_requests_total[5m])
```

#### P95 Latency
```promql
histogram_quantile(0.95, rate(zrpc_duration_microseconds_bucket[5m]))
```

#### Active Connections
```promql
zrpc_transport_connections_active
```

#### Throughput (MB/s)
```promql
rate(zrpc_transport_bytes_sent_total[1m]) / 1024 / 1024
```

#### Compression Ratio
```promql
zrpc_compression_bytes_after_total / zrpc_compression_bytes_before_total
```

## Metrics Server Endpoints

The built-in HTTP server provides:

- **`/metrics`**: Prometheus text format metrics
- **`/health`**: Health check (`{"status":"ok"}`)
- **`/`**: Simple HTML index with links

### Example: Fetch Metrics

```bash
curl http://localhost:9090/metrics
```

Output:
```
# HELP zrpc_requests_total Total number of RPC requests
# TYPE zrpc_requests_total counter
zrpc_requests_total 1234

# HELP zrpc_duration_microseconds RPC request duration in microseconds
# TYPE zrpc_duration_microseconds histogram
zrpc_duration_microseconds_bucket{le="10"} 45
zrpc_duration_microseconds_bucket{le="50"} 234
zrpc_duration_microseconds_bucket{le="100"} 567
...
```

## Statistics Summary

Get a quick summary without Prometheus:

```zig
const stats = registry.getStats();
stats.print();
```

Output:
```
zRPC Metrics:
  Requests: 1234 total (1200 success, 34 failed)
  Error rate: 2.75%
  Avg latency: 87.45 μs
  Connections: 5 active (120 total)
  Streams: 12 active (450 total)
  Traffic: 52428800 sent, 31457280 received
  Compression: 0.350:1 ratio
```

## Performance Considerations

### Overhead

- **Counter increment**: ~5ns (atomic add)
- **Histogram observation**: ~50ns (bucket lookup + atomic adds)
- **Total per-request overhead**: < 1μs

### Optimization Tips

1. **Batch updates**: Record metrics at logical boundaries (e.g., RPC completion) rather than intermediate steps
2. **Sample high-frequency events**: For very high-throughput systems, consider sampling (e.g., record every 10th request)
3. **Disable in production**: Set `metrics_registry = null` to completely disable metrics

## Transport Integration Pattern

To add metrics to a custom transport adapter:

```zig
pub const MyTransportAdapter = struct {
    allocator: std.mem.Allocator,
    metrics_registry: ?*MetricsRegistry,

    pub fn initWithMetrics(
        allocator: std.mem.Allocator,
        metrics_registry: *MetricsRegistry
    ) MyTransportAdapter {
        return .{
            .allocator = allocator,
            .metrics_registry = metrics_registry,
        };
    }

    pub fn connect(...) !Connection {
        // ... create connection ...

        // Record connection
        if (self.metrics_registry) |registry| {
            registry.recordTransportConnect();
        }

        return connection;
    }
};
```

### Integration Checklist

- [ ] Add `metrics_registry: ?*MetricsRegistry` field
- [ ] Add `initWithMetrics()` constructor
- [ ] Call `recordTransportConnect()` on connect
- [ ] Call `recordTransportDisconnect()` on disconnect
- [ ] Call `recordStreamOpen()` on stream creation
- [ ] Call `recordStreamClose()` on stream close
- [ ] Call `recordBytesTransferred()` on I/O operations

## Example: Complete Integration

See `examples/metrics_example.zig` for a complete working example:

```bash
cd /data/projects/zrpc
zig build metrics-example
```

This example demonstrates:
- Metrics registry initialization
- HTTP server startup
- Simulated RPC activity
- Real-time metrics updates
- Prometheus scraping

## Grafana Dashboard

Create visualizations with these panels:

1. **Request Rate**: `rate(zrpc_requests_total[5m])`
2. **Error Rate**: `rate(zrpc_requests_failed_total[5m]) / rate(zrpc_requests_total[5m])`
3. **Latency Heatmap**: `zrpc_duration_microseconds_bucket`
4. **Active Connections**: `zrpc_transport_connections_active`
5. **Throughput**: `rate(zrpc_transport_bytes_sent_total[1m])`
6. **Compression Efficiency**: `1 - (zrpc_compression_bytes_after_total / zrpc_compression_bytes_before_total)`

## Troubleshooting

### Metrics Not Updating

**Problem**: Metrics remain at 0 after RPC calls.

**Solution**: Ensure transport was initialized with `initWithMetrics()`:
```zig
// ❌ Wrong: No metrics
var transport = MyTransport.init(allocator);

// ✅ Correct: Metrics enabled
var transport = MyTransport.initWithMetrics(allocator, &registry);
```

### Server Not Starting

**Problem**: `error.AddressInUse` when starting metrics server.

**Solution**: Port 9090 already in use. Choose different port:
```zig
var server = try MetricsServer.init(allocator, &registry, 9091);
```

### High Memory Usage

**Problem**: Metrics registry consuming excessive memory.

**Solution**: Histogram buckets are allocated. With default 11 buckets, memory usage is minimal (~1KB). If concerned, reduce buckets or disable histograms.

## Production Deployment

### Security Considerations

1. **Bind to localhost**: Default `127.0.0.1` prevents external access
2. **Firewall rules**: Restrict `/metrics` endpoint access
3. **TLS**: For production, add TLS support to metrics server
4. **Authentication**: Add token-based auth for sensitive metrics

### Monitoring Setup

1. **Prometheus**: Scrape `/metrics` endpoint
2. **Alerting**: Set up alerts for error rate, latency spikes
3. **Grafana**: Create dashboards for visualization
4. **Retention**: Configure Prometheus retention policy

### Example Production Config

```zig
// Bind to internal network interface only
const address = std.net.Address.initIp4([_]u8{ 10, 0, 1, 5 }, 9090);
var server = try MetricsServer.init(allocator, &registry, 9090);
server.bind_address = address;
```

## Next Steps

- See `/docs/guides/observability.md` for OpenTelemetry tracing
- See `/docs/guides/logging.md` for structured logging
- See `/examples/production/` for production deployment examples

---

**Complete Phase 2 Progress**:
- ✅ Priority 1: zlog integration
- ✅ Priority 2: Prometheus metrics (this guide)
- ⏳ Priority 3: OpenTelemetry tracing (coming next)
