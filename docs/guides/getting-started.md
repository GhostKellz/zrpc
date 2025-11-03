# Getting Started with zRPC (Alpha)

This guide walks through building a small unary RPC service using the transport-agnostic core together with the QUIC adapter. The example targets Zig 0.16.0-dev and the current alpha API surface.

## Prerequisites
- Zig 0.16.0-dev or newer
- A checkout of this repository (the QUIC adapter depends on in-tree sources)
- Familiarity with Zig's build system and basic async error handling

## 1. Add zRPC to your project

### Option A — Local checkout (recommended during alpha)
Clone the repository adjacent to your application and point `build.zig.zon` at it:

```zig
.dependencies = .{
    .zrpc = .{
        .path = "../zrpc", // adjust as needed
    },
};
```

### Option B — Tarball snapshot
If you prefer a pinned snapshot, fetch and record the hash (replace `HASH` with the value produced by `zig fetch`):

```zig
.dependencies = .{
    .zrpc = .{
        .url = "https://github.com/ghostkellz/zrpc/archive/refs/heads/main.tar.gz",
        .hash = "HASH",
    },
};
```

## 2. Wire modules inside `build.zig`

Import the transport-agnostic core and opt-in transport adapters explicitly. Only the QUIC adapter is ready today.

```zig
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zrpc_dep = b.dependency("zrpc", .{
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "hello-zrpc",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const zrpc_core = zrpc_dep.module("zrpc-core");
    const zrpc_quic = zrpc_dep.module("zrpc-transport-quic");

    exe.root_module.addImport("zrpc-core", zrpc_core);
    exe.root_module.addImport("zrpc-transport-quic", zrpc_quic);

    b.installArtifact(exe);
}
```

## 3. Write a minimal server
Create `src/server.zig`:

```zig
const std = @import("std");
const zrpc = @import("zrpc-core");
const quic_adapter = @import("zrpc-transport-quic");

fn sayHello(_: *zrpc.RequestContext, response: *zrpc.ResponseContext) !void {
    response.data = "Hello from zRPC over QUIC!";
}

pub fn run(allocator: std.mem.Allocator) !void {
    var transport = quic_adapter.createTransport(allocator);

    var server = zrpc.Server.init(allocator, .{
        .transport = transport,
    });
    defer server.deinit();

    try server.registerHandler("Greeter/SayHello", sayHello);

    try server.bind("127.0.0.1:8443", null);
    std.log.info("listening on 127.0.0.1:8443", .{});
    try server.serve();
}
```

Key points:
- `registerHandler` expects the `Service/Method` identifier used by clients.
- TLS configuration is still under construction; pass `null` for local testing.
- `serve` blocks the current thread. Async/zsync integration will mature in future releases.

## 4. Write a matching client
Create `src/client.zig`:

```zig
const std = @import("std");
const zrpc = @import("zrpc-core");
const quic_adapter = @import("zrpc-transport-quic");

pub fn callSayHello(allocator: std.mem.Allocator) !void {
    var transport = quic_adapter.createTransport(allocator);

    var client = zrpc.Client.init(allocator, .{
        .transport = transport,
    });
    defer client.deinit();

    try client.connect("127.0.0.1:8443", null);

    const response = try client.call("Greeter/SayHello", "World");
    defer allocator.free(response);

    std.debug.print("Server replied: {s}\n", .{response});
}
```

## 5. Glue both sides together in `src/main.zig`

```zig
const std = @import("std");
const server = @import("server.zig");
const client = @import("client.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var server_thread = try std.Thread.spawn(.{}, runServer, .{allocator});
    defer server_thread.join();

    std.time.sleep(200 * std.time.ns_per_ms);
    try client.callSayHello(allocator);
}

fn runServer(allocator: std.mem.Allocator) void {
    server.run(allocator) catch |err| {
        std.log.err("server error: {}", .{err});
    };
}
```

Running server and client in the same process keeps things compact. In a real deployment you would run them as separate executables or services.

## 6. Build and run

```bash
zig build
zig build run
```

Sample output:

```
info: listening on 127.0.0.1:8443
Server replied: Hello from zRPC over QUIC!
```

## 7. Where to go next
- Deserialize requests and build responses using the protobuf or JSON codecs under `zrpc-core.codec`.
- Explore streaming APIs—scaffolding exists, but help finishing them is appreciated.
- Replace the sleep-based synchronization with proper readiness signaling once async support lands.
- Track transport/observability milestones in `docs/next-gen-roadmap.md`.

> 💬 Have improvements? Open an issue or PR—the project is evolving quickly during the alpha phase.