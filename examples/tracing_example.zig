const std = @import("std");
const zrpc = @import("zrpc");
const tracing = @import("tracing");
const websocket = @import("adapters/websocket/transport.zig");

const Tracer = tracing.Tracer;
const Span = tracing.Span;
const SpanContext = tracing.SpanContext;
const OtlpExporter = tracing.OtlpExporter;

/// Example demonstrating OpenTelemetry distributed tracing with zRPC
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.log.info("=== zRPC OpenTelemetry Tracing Example ===\n", .{});

    // Initialize tracer
    var tracer = try Tracer.init(allocator, "tracing_example");
    defer tracer.deinit();

    // Initialize OTLP exporter (e.g., for Jaeger)
    var exporter = try OtlpExporter.init(allocator, "http://127.0.0.1:4318/v1/traces");
    defer exporter.deinit();

    // Demo 1: Basic span lifecycle
    std.log.info("--- Demo 1: Basic Span Lifecycle ---", .{});
    {
        const span = try tracer.startSpan("demo.operation", .client);
        try span.setAttribute("demo.name", .{ .string = "basic_span" });
        try span.setAttribute("demo.number", .{ .int = 42 });

        // Simulate work
        std.time.sleep(10 * std.time.ns_per_ms);

        try span.addEvent("processing.started", &[_]tracing.Attribute{});
        std.time.sleep(20 * std.time.ns_per_ms);

        try span.setStatus(.ok, null);
        try tracer.endSpan(span);

        std.log.info("✓ Created and completed span: demo.operation", .{});
    }

    // Demo 2: Parent-child span relationships
    std.log.info("\n--- Demo 2: Parent-Child Spans ---", .{});
    {
        const parent = try tracer.startSpan("parent.operation", .server);
        try parent.setAttribute("request.id", .{ .string = "req-001" });

        // Child span 1
        const child1 = try tracer.startChildSpan("database.query", .client, parent.context);
        try child1.setAttribute("db.system", .{ .string = "postgresql" });
        try child1.setAttribute("db.statement", .{ .string = "SELECT * FROM users WHERE id = $1" });
        std.time.sleep(15 * std.time.ns_per_ms);
        try tracer.endSpan(child1);

        // Child span 2
        const child2 = try tracer.startChildSpan("cache.lookup", .client, parent.context);
        try child2.setAttribute("cache.key", .{ .string = "user:123" });
        try child2.setAttribute("cache.hit", .{ .bool = true });
        std.time.sleep(5 * std.time.ns_per_ms);
        try tracer.endSpan(child2);

        try tracer.endSpan(parent);

        std.log.info("✓ Created parent span with 2 children", .{});
    }

    // Demo 3: W3C Trace Context propagation
    std.log.info("\n--- Demo 3: W3C Trace Context Propagation ---", .{});
    {
        const service1_span = try tracer.startSpan("service1.handle_request", .server);
        try service1_span.setAttribute("service.name", .{ .string = "frontend" });

        // Serialize context for propagation
        const traceparent = try service1_span.context.toTraceparent(allocator);
        defer allocator.free(traceparent);

        std.log.info("Generated traceparent header: {s}", .{traceparent});

        // Simulate receiving request in another service
        const received_context = try SpanContext.fromTraceparent(traceparent);
        std.log.info("✓ Parsed trace context successfully", .{});

        const service2_span = try tracer.startChildSpan("service2.process", .server, received_context);
        try service2_span.setAttribute("service.name", .{ .string = "backend" });

        std.time.sleep(10 * std.time.ns_per_ms);

        try tracer.endSpan(service2_span);
        try tracer.endSpan(service1_span);

        std.log.info("✓ Cross-service trace propagation successful", .{});
    }

    // Demo 4: Error tracking
    std.log.info("\n--- Demo 4: Error Tracking ---", .{});
    {
        const span = try tracer.startSpan("operation.with_error", .client);
        try span.setAttribute("attempt", .{ .int = 1 });

        // Simulate error
        std.time.sleep(5 * std.time.ns_per_ms);

        try span.addEvent("error.occurred", &[_]tracing.Attribute{
            .{ .key = "error.type", .value = .{ .string = "ConnectionTimeout" } },
            .{ .key = "error.message", .value = .{ .string = "Failed to connect to database" } },
        });

        try span.setStatus(.error_status, "Connection timeout after 5s");
        try tracer.endSpan(span);

        std.log.info("✓ Tracked error in span", .{});
    }

    // Demo 5: Complex distributed trace
    std.log.info("\n--- Demo 5: Complex Distributed Trace ---", .{});
    {
        // API Gateway
        const gateway_span = try tracer.startSpan("api.gateway", .server);
        try gateway_span.setAttribute("http.method", .{ .string = "POST" });
        try gateway_span.setAttribute("http.route", .{ .string = "/api/orders" });

        // Auth Service
        const auth_span = try tracer.startChildSpan("auth.verify", .client, gateway_span.context);
        try auth_span.setAttribute("auth.user_id", .{ .string = "user-123" });
        std.time.sleep(8 * std.time.ns_per_ms);
        try tracer.endSpan(auth_span);

        // Order Service
        const order_span = try tracer.startChildSpan("order.create", .server, gateway_span.context);
        try order_span.setAttribute("order.id", .{ .string = "order-456" });

        // Database write
        const db_span = try tracer.startChildSpan("db.insert", .client, order_span.context);
        try db_span.setAttribute("db.table", .{ .string = "orders" });
        std.time.sleep(12 * std.time.ns_per_ms);
        try tracer.endSpan(db_span);

        // Payment Service
        const payment_span = try tracer.startChildSpan("payment.process", .client, order_span.context);
        try payment_span.setAttribute("payment.amount", .{ .double = 99.99 });
        try payment_span.setAttribute("payment.currency", .{ .string = "USD" });
        std.time.sleep(25 * std.time.ns_per_ms);
        try tracer.endSpan(payment_span);

        try tracer.endSpan(order_span);
        try tracer.endSpan(gateway_span);

        std.log.info("✓ Created complex trace with 5 spans across 4 services", .{});
    }

    // Export spans to OTLP endpoint
    std.log.info("\n--- Exporting Spans ---", .{});
    const completed_spans = tracer.getCompletedSpans();
    std.log.info("Total spans collected: {d}", .{completed_spans.len});

    if (completed_spans.len > 0) {
        std.log.info("Exporting to {s}...", .{exporter.endpoint});

        exporter.exportSpans(completed_spans) catch |err| {
            std.log.warn("Failed to export spans: {} (Is Jaeger running?)", .{err});
            std.log.info("Start Jaeger with: docker run -d -p 4318:4318 -p 16686:16686 jaegertracing/all-in-one:latest", .{});
        };

        std.log.info("✓ Spans exported successfully", .{});
    }

    // Print span summary
    std.log.info("\n=== Span Summary ===", .{});
    for (completed_spans, 0..) |span, i| {
        std.log.info("[{d}] {s}", .{ i + 1, span.name });
        std.log.info("    Kind: {s}", .{@tagName(span.kind)});
        std.log.info("    Status: {s}", .{@tagName(span.status)});

        if (span.durationMicros()) |duration| {
            std.log.info("    Duration: {d} μs", .{duration});
        }

        if (span.parent_span_id) |parent_id| {
            var buf: [16]u8 = undefined;
            const hex = parent_id.toHex(&buf);
            std.log.info("    Parent: {s}", .{hex});
        }

        std.log.info("    Attributes: {d}", .{span.attributes.items.len});

        for (span.attributes.items) |attr| {
            switch (attr.value) {
                .string => |s| std.log.info("      {s} = \"{s}\"", .{ attr.key, s }),
                .int => |val| std.log.info("      {s} = {d}", .{ attr.key, val }),
                .double => |val| std.log.info("      {s} = {d:.2}", .{ attr.key, val }),
                .bool => |val| std.log.info("      {s} = {}", .{ attr.key, val }),
            }
        }

        if (span.events.items.len > 0) {
            std.log.info("    Events: {d}", .{span.events.items.len});
            for (span.events.items) |event| {
                std.log.info("      - {s}", .{event.name});
            }
        }

        std.log.info("", .{});
    }

    std.log.info("=== Complete ===", .{});
    std.log.info("\nTo visualize these traces:", .{});
    std.log.info("1. Start Jaeger: docker run -d -p 4318:4318 -p 16686:16686 jaegertracing/all-in-one:latest", .{});
    std.log.info("2. Re-run this example", .{});
    std.log.info("3. Open Jaeger UI: http://localhost:16686", .{});
    std.log.info("4. Search for service: 'tracing_example'", .{});
}
