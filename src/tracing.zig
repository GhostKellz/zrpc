const std = @import("std");

/// OpenTelemetry Distributed Tracing for zRPC
/// Implements W3C Trace Context standard for span propagation

/// 128-bit trace ID (globally unique across all traces)
pub const TraceId = struct {
    high: u64,
    low: u64,

    pub fn generate() TraceId {
        return .{
            .high = std.crypto.random.int(u64),
            .low = std.crypto.random.int(u64),
        };
    }

    pub fn fromHex(hex: []const u8) !TraceId {
        if (hex.len != 32) return error.InvalidTraceId;

        const high = try std.fmt.parseInt(u64, hex[0..16], 16);
        const low = try std.fmt.parseInt(u64, hex[16..32], 16);

        return .{ .high = high, .low = low };
    }

    pub fn toHex(self: TraceId, buf: *[32]u8) []const u8 {
        return std.fmt.bufPrint(buf, "{x:0>16}{x:0>16}", .{ self.high, self.low }) catch unreachable;
    }

    pub fn isValid(self: TraceId) bool {
        return self.high != 0 or self.low != 0;
    }
};

/// 64-bit span ID (unique within a trace)
pub const SpanId = struct {
    value: u64,

    pub fn generate() SpanId {
        return .{ .value = std.crypto.random.int(u64) };
    }

    pub fn fromHex(hex: []const u8) !SpanId {
        if (hex.len != 16) return error.InvalidSpanId;
        const value = try std.fmt.parseInt(u64, hex, 16);
        return .{ .value = value };
    }

    pub fn toHex(self: SpanId, buf: *[16]u8) []const u8 {
        return std.fmt.bufPrint(buf, "{x:0>16}", .{self.value}) catch unreachable;
    }

    pub fn isValid(self: SpanId) bool {
        return self.value != 0;
    }
};

/// Span context for propagation (W3C Trace Context)
pub const SpanContext = struct {
    trace_id: TraceId,
    span_id: SpanId,
    trace_flags: u8, // bit 0: sampled flag
    trace_state: ?[]const u8 = null,

    pub fn generate(allocator: std.mem.Allocator) !SpanContext {
        _ = allocator;
        return .{
            .trace_id = TraceId.generate(),
            .span_id = SpanId.generate(),
            .trace_flags = 0x01, // sampled
            .trace_state = null,
        };
    }

    pub fn isSampled(self: SpanContext) bool {
        return (self.trace_flags & 0x01) != 0;
    }

    pub fn isValid(self: SpanContext) bool {
        return self.trace_id.isValid() and self.span_id.isValid();
    }

    /// Format as W3C traceparent header
    /// Format: 00-<trace-id>-<span-id>-<trace-flags>
    pub fn toTraceparent(self: SpanContext, allocator: std.mem.Allocator) ![]u8 {
        var trace_id_buf: [32]u8 = undefined;
        var span_id_buf: [16]u8 = undefined;

        const trace_id_hex = self.trace_id.toHex(&trace_id_buf);
        const span_id_hex = self.span_id.toHex(&span_id_buf);

        return std.fmt.allocPrint(
            allocator,
            "00-{s}-{s}-{x:0>2}",
            .{ trace_id_hex, span_id_hex, self.trace_flags },
        );
    }

    /// Parse W3C traceparent header
    pub fn fromTraceparent(traceparent: []const u8) !SpanContext {
        // Format: 00-<trace-id>-<span-id>-<trace-flags>
        var parts = std.mem.splitSequence(u8, traceparent, "-");

        const version = parts.next() orelse return error.InvalidTraceparent;
        if (!std.mem.eql(u8, version, "00")) return error.UnsupportedVersion;

        const trace_id_hex = parts.next() orelse return error.InvalidTraceparent;
        const span_id_hex = parts.next() orelse return error.InvalidTraceparent;
        const flags_hex = parts.next() orelse return error.InvalidTraceparent;

        const trace_id = try TraceId.fromHex(trace_id_hex);
        const span_id = try SpanId.fromHex(span_id_hex);
        const trace_flags = try std.fmt.parseInt(u8, flags_hex, 16);

        return .{
            .trace_id = trace_id,
            .span_id = span_id,
            .trace_flags = trace_flags,
            .trace_state = null,
        };
    }
};

/// Span kind (client, server, internal, etc.)
pub const SpanKind = enum(u8) {
    internal = 0,
    server = 1,
    client = 2,
    producer = 3,
    consumer = 4,
};

/// Span status
pub const SpanStatus = enum(u8) {
    unset = 0,
    ok = 1,
    error_status = 2,
};

/// Span attribute value types
pub const AttributeValue = union(enum) {
    string: []const u8,
    int: i64,
    double: f64,
    bool: bool,
};

/// Span attribute (key-value pair)
pub const Attribute = struct {
    key: []const u8,
    value: AttributeValue,
};

/// Span event (timed annotation)
pub const SpanEvent = struct {
    name: []const u8,
    timestamp: i64,
    attributes: []Attribute,
};

/// Span represents a single operation in a trace
pub const Span = struct {
    context: SpanContext,
    parent_span_id: ?SpanId,
    name: []const u8,
    kind: SpanKind,
    start_time: i64,
    end_time: ?i64,
    status: SpanStatus,
    status_message: ?[]const u8,
    attributes: std.ArrayList(Attribute),
    events: std.ArrayList(SpanEvent),
    allocator: std.mem.Allocator,

    pub fn init(
        allocator: std.mem.Allocator,
        context: SpanContext,
        name: []const u8,
        kind: SpanKind,
        parent_span_id: ?SpanId,
    ) !Span {
        return .{
            .context = context,
            .parent_span_id = parent_span_id,
            .name = try allocator.dupe(u8, name),
            .kind = kind,
            .start_time = @intCast(std.time.nanoTimestamp()),
            .end_time = null,
            .status = .unset,
            .status_message = null,
            .attributes = .empty,
            .events = .empty,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Span) void {
        self.allocator.free(self.name);

        for (self.attributes.items) |attr| {
            self.allocator.free(attr.key);
            switch (attr.value) {
                .string => |s| self.allocator.free(s),
                else => {},
            }
        }
        self.attributes.deinit(self.allocator);

        for (self.events.items) |event| {
            self.allocator.free(event.name);
            for (event.attributes) |attr| {
                self.allocator.free(attr.key);
                switch (attr.value) {
                    .string => |s| self.allocator.free(s),
                    else => {},
                }
            }
            self.allocator.free(event.attributes);
        }
        self.events.deinit(self.allocator);

        if (self.status_message) |msg| {
            self.allocator.free(msg);
        }
    }

    /// Set span attribute
    pub fn setAttribute(self: *Span, key: []const u8, value: AttributeValue) !void {
        const key_copy = try self.allocator.dupe(u8, key);
        const value_copy = switch (value) {
            .string => |s| AttributeValue{ .string = try self.allocator.dupe(u8, s) },
            .int => |i| AttributeValue{ .int = i },
            .double => |d| AttributeValue{ .double = d },
            .bool => |b| AttributeValue{ .bool = b },
        };

        try self.attributes.append(self.allocator, .{
            .key = key_copy,
            .value = value_copy,
        });
    }

    /// Add span event
    pub fn addEvent(self: *Span, name: []const u8, attributes: []const Attribute) !void {
        const name_copy = try self.allocator.dupe(u8, name);

        // Copy attributes
        const attrs_copy = try self.allocator.alloc(Attribute, attributes.len);
        for (attributes, 0..) |attr, attr_idx| {
            const key_copy = try self.allocator.dupe(u8, attr.key);
            const value_copy = switch (attr.value) {
                .string => |s| AttributeValue{ .string = try self.allocator.dupe(u8, s) },
                .int => |int_val| AttributeValue{ .int = int_val },
                .double => |d| AttributeValue{ .double = d },
                .bool => |b| AttributeValue{ .bool = b },
            };
            attrs_copy[attr_idx] = .{ .key = key_copy, .value = value_copy };
        }

        try self.events.append(self.allocator, .{
            .name = name_copy,
            .timestamp = @intCast(std.time.nanoTimestamp()),
            .attributes = attrs_copy,
        });
    }

    /// Set span status
    pub fn setStatus(self: *Span, status: SpanStatus, message: ?[]const u8) !void {
        self.status = status;
        if (message) |msg| {
            self.status_message = try self.allocator.dupe(u8, msg);
        }
    }

    /// End span
    pub fn end(self: *Span) void {
        if (self.end_time == null) {
            self.end_time = @intCast(std.time.nanoTimestamp());
        }
    }

    /// Get span duration in microseconds
    pub fn durationMicros(self: *Span) ?i64 {
        const end_timestamp = self.end_time orelse return null;
        return @divTrunc(end_timestamp - self.start_time, 1000);
    }
};

/// Tracer creates and manages spans
pub const Tracer = struct {
    allocator: std.mem.Allocator,
    service_name: []const u8,
    active_spans: std.ArrayList(*Span),
    completed_spans: std.ArrayList(Span),
    mutex: std.Thread.Mutex,

    pub fn init(allocator: std.mem.Allocator, service_name: []const u8) !Tracer {
        return .{
            .allocator = allocator,
            .service_name = try allocator.dupe(u8, service_name),
            .active_spans = .empty,
            .completed_spans = .empty,
            .mutex = .{},
        };
    }

    pub fn deinit(self: *Tracer) void {
        self.allocator.free(self.service_name);

        for (self.active_spans.items) |span| {
            span.deinit();
            self.allocator.destroy(span);
        }
        self.active_spans.deinit(self.allocator);

        for (self.completed_spans.items) |*span| {
            span.deinit();
        }
        self.completed_spans.deinit(self.allocator);
    }

    /// Start a new root span
    pub fn startSpan(self: *Tracer, name: []const u8, kind: SpanKind) !*Span {
        const context = try SpanContext.generate(self.allocator);
        return self.startSpanWithContext(name, kind, context, null);
    }

    /// Start a child span with parent context
    pub fn startChildSpan(
        self: *Tracer,
        name: []const u8,
        kind: SpanKind,
        parent_context: SpanContext,
    ) !*Span {
        // Create new span ID but keep same trace ID
        const context = SpanContext{
            .trace_id = parent_context.trace_id,
            .span_id = SpanId.generate(),
            .trace_flags = parent_context.trace_flags,
            .trace_state = parent_context.trace_state,
        };

        return self.startSpanWithContext(name, kind, context, parent_context.span_id);
    }

    fn startSpanWithContext(
        self: *Tracer,
        name: []const u8,
        kind: SpanKind,
        context: SpanContext,
        parent_span_id: ?SpanId,
    ) !*Span {
        const span = try self.allocator.create(Span);
        span.* = try Span.init(self.allocator, context, name, kind, parent_span_id);

        // Add service name attribute
        try span.setAttribute("service.name", .{ .string = self.service_name });

        self.mutex.lock();
        defer self.mutex.unlock();

        try self.active_spans.append(self.allocator, span);

        return span;
    }

    /// End and record span
    pub fn endSpan(self: *Tracer, span: *Span) !void {
        span.end();

        self.mutex.lock();
        defer self.mutex.unlock();

        // Remove from active spans
        for (self.active_spans.items, 0..) |s, i| {
            if (s == span) {
                _ = self.active_spans.swapRemove(i);
                break;
            }
        }

        // Move to completed spans
        try self.completed_spans.append(self.allocator, span.*);
        self.allocator.destroy(span);
    }

    /// Get all completed spans (for export)
    pub fn getCompletedSpans(self: *Tracer) []Span {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.completed_spans.items;
    }

    /// Clear completed spans after export
    pub fn clearCompletedSpans(self: *Tracer) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        for (self.completed_spans.items) |*span| {
            span.deinit();
        }
        self.completed_spans.clearRetainingCapacity();
    }
};

/// OTLP Span Exporter (OpenTelemetry Protocol)
pub const OtlpExporter = struct {
    allocator: std.mem.Allocator,
    endpoint: []const u8, // e.g., "http://localhost:4318/v1/traces"

    pub fn init(allocator: std.mem.Allocator, endpoint: []const u8) !OtlpExporter {
        return .{
            .allocator = allocator,
            .endpoint = try allocator.dupe(u8, endpoint),
        };
    }

    pub fn deinit(self: *OtlpExporter) void {
        self.allocator.free(self.endpoint);
    }

    /// Export spans to OTLP endpoint
    pub fn exportSpans(self: *OtlpExporter, spans: []Span) !void {
        if (spans.len == 0) return;

        // Build JSON payload
        var json: std.ArrayList(u8) = .init(self.allocator);
        defer json.deinit();

        try self.buildOtlpJson(&json, spans);

        // Send HTTP POST request
        try self.sendHttp(json.items);
    }

    fn buildOtlpJson(self: *OtlpExporter, writer: *std.ArrayList(u8), spans: []Span) !void {
        _ = self;
        const w = writer.writer();

        try w.writeAll("{\"resourceSpans\":[{\"scopeSpans\":[{\"spans\":[");

        for (spans, 0..) |span, i| {
            if (i > 0) try w.writeAll(",");

            var trace_id_buf: [32]u8 = undefined;
            var span_id_buf: [16]u8 = undefined;
            const trace_id_hex = span.context.trace_id.toHex(&trace_id_buf);
            const span_id_hex = span.context.span_id.toHex(&span_id_buf);

            try w.print(
                \\{{"traceId":"{s}","spanId":"{s}","name":"{s}","kind":{d},"startTimeUnixNano":{d}
            , .{
                trace_id_hex,
                span_id_hex,
                span.name,
                @intFromEnum(span.kind),
                span.start_time,
            });

            if (span.end_time) |end| {
                try w.print(",\"endTimeUnixNano\":{d}", .{end});
            }

            if (span.parent_span_id) |parent| {
                var parent_buf: [16]u8 = undefined;
                const parent_hex = parent.toHex(&parent_buf);
                try w.print(",\"parentSpanId\":\"{}\"", .{std.zig.fmtEscapes(parent_hex)});
            }

            // Attributes
            if (span.attributes.items.len > 0) {
                try w.writeAll(",\"attributes\":[");
                for (span.attributes.items, 0..) |attr, j| {
                    if (j > 0) try w.writeAll(",");
                    try w.print("{{\"key\":\"{}\",\"value\":{{", .{std.zig.fmtEscapes(attr.key)});
                    switch (attr.value) {
                        .string => |s| try w.print("\"stringValue\":\"{}\"", .{std.zig.fmtEscapes(s)}),
                        .int => |val| try w.print("\"intValue\":{d}", .{val}),
                        .double => |val| try w.print("\"doubleValue\":{d}", .{val}),
                        .bool => |val| try w.print("\"boolValue\":{}", .{val}),
                    }
                    try w.writeAll("}}");
                }
                try w.writeAll("]");
            }

            // Status
            try w.print(",\"status\":{{\"code\":{d}", .{@intFromEnum(span.status)});
            if (span.status_message) |msg| {
                try w.print(",\"message\":\"{}\"", .{std.zig.fmtEscapes(msg)});
            }
            try w.writeAll("}");

            try w.writeAll("}");
        }

        try w.writeAll("]}]}]}");
    }

    fn sendHttp(self: *OtlpExporter, body: []const u8) !void {
        // Parse endpoint URL
        const url = try std.Uri.parse(self.endpoint);
        const host = url.host orelse return error.InvalidEndpoint;
        const port = url.port orelse 4318;

        // Connect to endpoint
        const address = try std.net.Address.parseIp(host.percent_encoded, port);
        const conn = try std.net.tcpConnectToAddress(address);
        defer conn.close();

        // Build HTTP request
        var request: std.ArrayList(u8) = .init(self.allocator);
        defer request.deinit();

        try request.writer().print(
            "POST {s} HTTP/1.1\r\n" ++
                "Host: {s}:{d}\r\n" ++
                "Content-Type: application/json\r\n" ++
                "Content-Length: {d}\r\n" ++
                "\r\n",
            .{ url.path.percent_encoded, host.percent_encoded, port, body.len },
        );
        try request.appendSlice(body);

        // Send request
        _ = try conn.write(request.items);

        // Read response (basic check)
        var response: [1024]u8 = undefined;
        _ = try conn.read(&response);
        // TODO: Parse response and check for errors
    }
};

// Tests
test "TraceId generation and parsing" {
    const testing = std.testing;

    const trace_id = TraceId.generate();
    try testing.expect(trace_id.isValid());

    var buf: [32]u8 = undefined;
    const hex = trace_id.toHex(&buf);
    try testing.expectEqual(@as(usize, 32), hex.len);

    const parsed = try TraceId.fromHex(hex);
    try testing.expectEqual(trace_id.high, parsed.high);
    try testing.expectEqual(trace_id.low, parsed.low);
}

test "SpanId generation and parsing" {
    const testing = std.testing;

    const span_id = SpanId.generate();
    try testing.expect(span_id.isValid());

    var buf: [16]u8 = undefined;
    const hex = span_id.toHex(&buf);
    try testing.expectEqual(@as(usize, 16), hex.len);

    const parsed = try SpanId.fromHex(hex);
    try testing.expectEqual(span_id.value, parsed.value);
}

test "W3C traceparent format" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const context = SpanContext{
        .trace_id = TraceId{ .high = 0x0123456789abcdef, .low = 0xfedcba9876543210 },
        .span_id = SpanId{ .value = 0x1122334455667788 },
        .trace_flags = 0x01,
    };

    const traceparent = try context.toTraceparent(allocator);
    defer allocator.free(traceparent);

    try testing.expect(std.mem.startsWith(u8, traceparent, "00-"));

    const parsed = try SpanContext.fromTraceparent(traceparent);
    try testing.expectEqual(context.trace_id.high, parsed.trace_id.high);
    try testing.expectEqual(context.trace_id.low, parsed.trace_id.low);
    try testing.expectEqual(context.span_id.value, parsed.span_id.value);
    try testing.expectEqual(context.trace_flags, parsed.trace_flags);
}

test "Span lifecycle" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const context = try SpanContext.generate(allocator);
    var span = try Span.init(allocator, context, "test_span", .client, null);
    defer span.deinit();

    try span.setAttribute("http.method", .{ .string = "GET" });
    try span.setAttribute("http.status_code", .{ .int = 200 });

    try span.addEvent("request_started", &[_]Attribute{});
    try span.setStatus(.ok, null);

    span.end();

    try testing.expect(span.end_time != null);
    try testing.expect(span.durationMicros() != null);
}

test "Tracer with parent-child spans" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var tracer = try Tracer.init(allocator, "test_service");
    defer tracer.deinit();

    // Create parent span
    const parent = try tracer.startSpan("parent_operation", .server);
    try parent.setAttribute("request.id", .{ .string = "req-123" });

    // Create child span
    const child = try tracer.startChildSpan("child_operation", .client, parent.context);
    try child.setAttribute("db.query", .{ .string = "SELECT * FROM users" });

    try tracer.endSpan(child);
    try tracer.endSpan(parent);

    const completed = tracer.getCompletedSpans();
    try testing.expectEqual(@as(usize, 2), completed.len);
}
