# Migration Guide: From Monolithic to Modular zRPC

This guide helps you migrate from the previous monolithic zRPC (alpha versions) to the new transport-agnostic architecture (beta and beyond).

## Why Migrate?

The new modular architecture provides:

- **🏗️ Cleaner Dependencies**: Core compiles without transport dependencies
- **🔌 Pluggable Transports**: Easy to swap QUIC, HTTP/2, or custom transports
- **⚡ Better Performance**: Optimized for specific transport features
- **🧪 Easier Testing**: Mock transports for unit tests
- **📦 Smaller Builds**: Only include the transports you need

## Breaking Changes Summary

| **Aspect** | **Old (Alpha)** | **New (Beta)** |
|------------|-----------------|----------------|
| **Import** | `@import("zrpc")` | `@import("zrpc-core")` + `@import("zrpc-transport-quic")` |
| **Client Creation** | `zrpc.Client.init(allocator, endpoint)` | `zrpc_core.Client.init(allocator, .{.transport = transport})` |
| **Server Creation** | `zrpc.Server.init(allocator, config)` | `zrpc_core.Server.init(allocator, .{.transport = transport})` |
| **Connection** | Implicit via URL scheme | Explicit: `client.connect(endpoint, tls_config)` |
| **Transport Selection** | URL-based (`quic://`, `http://`) | Explicit transport adapter injection |
| **Dependencies** | Single package | Core + transport adapter packages |

## Step-by-Step Migration

### 1. Update Dependencies

**Old `build.zig.zon`:**
```zig
.dependencies = .{
    .zrpc = .{
        .url = "https://github.com/ghostkellz/zrpc/archive/refs/heads/main.tar.gz",
        .hash = "...",
    },
},
```

**New `build.zig.zon`:**
```zig
.dependencies = .{
    .@"zrpc-core" = .{
        .url = "https://github.com/ghostkellz/zrpc/releases/download/v0.4.0-beta.1/zrpc-core.tar.gz",
        .hash = "...",
    },
    .@"zrpc-transport-quic" = .{
        .url = "https://github.com/ghostkellz/zrpc/releases/download/v0.1.0-beta.1/zrpc-transport-quic.tar.gz",
        .hash = "...",
    },
},
```

**Old `build.zig`:**
```zig
const zrpc = b.dependency("zrpc", .{}).module("zrpc");
exe.root_module.addImport("zrpc", zrpc);
```

**New `build.zig`:**
```zig
const zrpc_core = b.dependency("zrpc-core", .{}).module("zrpc-core");
const zrpc_quic = b.dependency("zrpc-transport-quic", .{}).module("zrpc-transport-quic");

exe.root_module.addImport("zrpc-core", zrpc_core);
exe.root_module.addImport("zrpc-transport-quic", zrpc_quic);
```

### 2. Update Imports

**Old imports:**
```zig
const std = @import("std");
const zrpc = @import("zrpc");
```

**New imports:**
```zig
const std = @import("std");
const zrpc_core = @import("zrpc-core");
const zrpc_quic = @import("zrpc-transport-quic");
```

### 3. Migrate Client Code

**Old client pattern:**
```zig
// Old: URL-based transport selection
var client = try zrpc.Client.init(allocator, "quic://localhost:8080");
const response = try client.call("Service/Method", request_data);
```

**New client pattern:**
```zig
// New: Explicit transport injection
const transport = zrpc_quic.createClientTransport(allocator);
var client = zrpc_core.Client.init(allocator, .{ .transport = transport });
defer client.deinit();

try client.connect("localhost:8080", null);
const response = try client.call("Service/Method", request_data);
defer allocator.free(response);
```

### 4. Migrate Server Code

**Old server pattern:**
```zig
// Old: Built-in transport selection
var server = try zrpc.Server.init(allocator, .{
    .transport = .quic,
    .port = 8080,
});
try server.registerService(MyService{});
try server.start();
```

**New server pattern:**
```zig
// New: Explicit transport injection
const transport = zrpc_quic.createServerTransport(allocator);
var server = zrpc_core.Server.init(allocator, .{ .transport = transport });
defer server.deinit();

// Handler function instead of service struct
fn myHandler(request: *zrpc_core.RequestContext, response: *zrpc_core.ResponseContext) !void {
    // Process request.data, set response.data
}

try server.registerHandler("MyService/MyMethod", myHandler);
try server.bind("127.0.0.1:8080", null);
try server.serve();
```

### 5. Update Service Handlers

**Old service pattern:**
```zig
const MyService = struct {
    pub fn myMethod(self: *MyService, req: *const Request) !Response {
        return Response{ .data = "response" };
    }
};

try server.registerService(MyService{});
```

**New handler pattern:**
```zig
fn myHandler(request: *zrpc_core.RequestContext, response: *zrpc_core.ResponseContext) !void {
    // Parse request (you'll typically use protobuf here)
    const req_data = request.data;

    // Process business logic
    const result = processRequest(req_data);

    // Set response (you'll typically serialize protobuf here)
    response.data = try response.allocator.dupe(u8, result);
    response.status_code = 0; // gRPC OK
}

try server.registerHandler("MyService/MyMethod", myHandler);
```

### 6. Handle TLS Configuration

**Old TLS pattern:**
```zig
var client = try zrpc.Client.init(allocator, "quics://secure-server:8443");
```

**New TLS pattern:**
```zig
const tls_config = zrpc_core.TlsConfig{
    .cert_file = "client.crt",
    .key_file = "client.key",
    .ca_file = "ca.crt",
    .server_name = "secure-server",
};

const transport = zrpc_quic.createClientTransport(allocator);
var client = zrpc_core.Client.init(allocator, .{ .transport = transport });
try client.connect("secure-server:8443", &tls_config);
```

## Migration Examples

### Example 1: Simple Echo Service

**Before (Alpha):**
```zig
const std = @import("std");
const zrpc = @import("zrpc");

const EchoService = struct {
    pub fn echo(self: *EchoService, req: *const EchoRequest) !EchoResponse {
        return EchoResponse{ .message = req.message };
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    var server = try zrpc.Server.init(allocator, .{ .transport = .quic });
    try server.registerService(EchoService{});
    try server.listen("localhost:8080");
    try server.start();
}
```

**After (Beta):**
```zig
const std = @import("std");
const zrpc_core = @import("zrpc-core");
const zrpc_quic = @import("zrpc-transport-quic");

fn echoHandler(request: *zrpc_core.RequestContext, response: *zrpc_core.ResponseContext) !void {
    // Echo the request data back
    response.data = request.data;
    response.status_code = 0;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    const transport = zrpc_quic.createServerTransport(allocator);
    var server = zrpc_core.Server.init(allocator, .{ .transport = transport });
    defer server.deinit();

    try server.registerHandler("EchoService/Echo", echoHandler);
    try server.bind("localhost:8080", null);
    try server.serve();
}
```

### Example 2: Client with Multiple Calls

**Before (Alpha):**
```zig
var client = try zrpc.Client.init(allocator, "quic://localhost:8080");

const echo_resp = try client.call("EchoService/Echo", echo_req);
const greet_resp = try client.call("GreeterService/Greet", greet_req);
```

**After (Beta):**
```zig
const transport = zrpc_quic.createClientTransport(allocator);
var client = zrpc_core.Client.init(allocator, .{ .transport = transport });
defer client.deinit();

try client.connect("localhost:8080", null);

const echo_resp = try client.call("EchoService/Echo", echo_req);
defer allocator.free(echo_resp);

const greet_resp = try client.call("GreeterService/Greet", greet_req);
defer allocator.free(greet_resp);
```

## Advanced Migration Scenarios

### Custom Transport Adapters

If you used custom transport implementations:

**Old approach:**
```zig
const MyTransport = struct {
    // Custom transport implementation
};

var server = try zrpc.Server.init(allocator, .{ .transport = MyTransport{} });
```

**New approach:**
```zig
// Implement the transport SPI
pub const MyTransportAdapter = struct {
    pub fn connect(/*...*/) TransportError!Connection { /*...*/ }
    pub fn listen(/*...*/) TransportError!Listener { /*...*/ }
};

pub fn createTransport(allocator: std.mem.Allocator) Transport {
    const adapter = allocator.create(MyTransportAdapter) catch @panic("OOM");
    adapter.* = MyTransportAdapter.init(allocator);
    return zrpc_core.transport.createTransport(MyTransportAdapter, adapter);
}

const transport = createTransport(allocator);
var server = zrpc_core.Server.init(allocator, .{ .transport = transport });
```

### Protocol Buffer Integration

Protocol buffer handling remains similar but uses the new context pattern:

**Old protobuf handler:**
```zig
pub fn processOrder(self: *OrderService, req: *const OrderRequest) !OrderResponse {
    const order = try self.processOrderLogic(req);
    return OrderResponse{ .order_id = order.id, .status = order.status };
}
```

**New protobuf handler:**
```zig
fn processOrderHandler(request: *zrpc_core.RequestContext, response: *zrpc_core.ResponseContext) !void {
    // Deserialize protobuf request
    const req = try OrderRequest.decode(request.data, request.allocator);

    // Process business logic
    const order = try processOrderLogic(req);

    // Serialize protobuf response
    const resp = OrderResponse{ .order_id = order.id, .status = order.status };
    response.data = try resp.encode(response.allocator);
    response.status_code = 0;
}
```

## Testing Migration

### Unit Tests

**Old test pattern:**
```zig
test "service logic" {
    const service = MyService{};
    const result = try service.myMethod(&request);
    try std.testing.expect(result.success);
}
```

**New test pattern:**
```zig
test "handler logic" {
    var request_ctx = zrpc_core.RequestContext.init(std.testing.allocator, "TestService/Test", request_data);
    defer request_ctx.deinit();

    var response_ctx = zrpc_core.ResponseContext.init(std.testing.allocator, &[_]u8{});
    defer response_ctx.deinit();

    try myHandler(&request_ctx, &response_ctx);
    try std.testing.expect(response_ctx.status_code == 0);
}
```

### Integration Tests with Mock Transport

The new architecture makes integration testing easier:

```zig
test "integration with mock transport" {
    const mock_transport = zrpc_core.transport.createMockTransport(std.testing.allocator);

    var client = zrpc_core.Client.init(std.testing.allocator, .{ .transport = mock_transport });
    defer client.deinit();

    // Test client without real network
    const response = try client.call("TestService/Test", "test data");
    defer std.testing.allocator.free(response);
}
```

## Compatibility Notes

### Backwards Compatibility

- **No API compatibility** between alpha and beta versions
- **Protocol compatibility** with gRPC clients/servers maintained
- **Migration required** for existing alpha codebases

### Feature Parity

All features from the alpha version are available in beta:
- ✅ Unary RPCs
- ✅ Streaming RPCs (client, server, bidirectional)
- ✅ QUIC transport with 0-RTT
- ✅ Connection migration
- ✅ Load balancing
- ✅ Protocol buffer support
- ✅ TLS 1.3
- ✅ Authentication headers

### Performance

Beta should have equivalent or better performance:
- ✅ Same QUIC optimizations
- ✅ Reduced memory allocations
- ✅ Faster compile times (modular builds)
- ✅ Better cache locality

## Troubleshooting Migration

### Common Issues

**"Module not found" errors:**
- Update `build.zig.zon` dependencies
- Run `zig fetch` to update hashes
- Check module names in `build.zig`

**"Unknown field" errors:**
- Update API calls to new patterns
- Check function signatures in docs
- Use handler functions instead of service structs

**Transport connection failures:**
- Verify explicit `client.connect()` calls
- Check TLS configuration format
- Ensure server `bind()` before `serve()`

**Memory leaks in tests:**
- Add `defer allocator.free(response)` for all responses
- Use `defer client.deinit()` and `defer server.deinit()`
- Check that handlers properly manage allocations

### Getting Help

1. **Documentation**: Check [Architecture Guide](architecture.md) and [Quickstart](quickstart.md)
2. **Examples**: See `examples/` directory for working code
3. **Issues**: Report migration problems on [GitHub Issues](https://github.com/ghostkellz/zrpc/issues)
4. **Community**: Ask questions on [Zig Community](https://ziglang.org/community)

## Migration Checklist

- [ ] Update `build.zig.zon` with new dependencies
- [ ] Update `build.zig` module imports
- [ ] Change source imports to modular pattern
- [ ] Replace URL-based client creation with explicit transport
- [ ] Convert service structs to handler functions
- [ ] Update server creation and binding pattern
- [ ] Add explicit connection calls for clients
- [ ] Update TLS configuration format
- [ ] Add proper memory cleanup (defer statements)
- [ ] Run tests to verify functionality
- [ ] Update any custom transport implementations
- [ ] Review performance with new architecture

🎉 **Migration Complete!** You're now using the clean, modular zRPC architecture that will scale with your application needs.