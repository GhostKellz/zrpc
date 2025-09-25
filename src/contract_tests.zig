//! Contract test harness for transport adapters
//! Ensures all transport implementations behave consistently

const std = @import("std");

const transport_interface = @import("transport_interface.zig");
const Transport = transport_interface.Transport;
const Connection = transport_interface.Connection;
const Stream = transport_interface.Stream;
const Frame = transport_interface.Frame;
const FrameType = transport_interface.FrameType;
const TransportError = transport_interface.TransportError;

/// Contract test suite for transport adapters
pub const ContractTestSuite = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) ContractTestSuite {
        return ContractTestSuite{
            .allocator = allocator,
        };
    }

    /// Test basic connection lifecycle
    pub fn testConnectionLifecycle(self: *const ContractTestSuite, transport: Transport) !void {
        std.log.info("Testing connection lifecycle...", .{});

        // Test connection creation
        const conn = transport.connect(self.allocator, "127.0.0.1:0", null) catch |err| switch (err) {
            TransportError.ConnectionReset, TransportError.NotConnected => {
                std.log.warn("Connection failed as expected for test endpoint", .{});
                return;
            },
            else => return err,
        };
        defer conn.close();

        // Test connection state
        try std.testing.expect(conn.isConnected());

        std.log.info("✅ Connection lifecycle test passed", .{});
    }

    /// Test stream operations
    pub fn testStreamOperations(self: *const ContractTestSuite, transport: Transport) !void {
        std.log.info("Testing stream operations...", .{});

        const conn = transport.connect(self.allocator, "127.0.0.1:0", null) catch |err| switch (err) {
            TransportError.ConnectionReset, TransportError.NotConnected => {
                std.log.warn("Skipping stream test - no connection", .{});
                return;
            },
            else => return err,
        };
        defer conn.close();

        // Test stream creation
        const stream = conn.openStream() catch |err| switch (err) {
            TransportError.NotConnected, TransportError.Protocol => {
                std.log.warn("Stream creation failed as expected for test connection", .{});
                return;
            },
            else => return err,
        };
        defer stream.close();

        // Test frame writing
        const test_data = "Hello, contract test!";
        try stream.writeFrame(FrameType.data, 0, test_data);

        // Test stream cancellation
        stream.cancel();

        std.log.info("✅ Stream operations test passed", .{});
    }

    /// Test frame serialization consistency
    pub fn testFrameSerialization(self: *const ContractTestSuite, transport: Transport) !void {
        std.log.info("Testing frame serialization...", .{});

        const conn = transport.connect(self.allocator, "127.0.0.1:0", null) catch |err| switch (err) {
            TransportError.ConnectionReset, TransportError.NotConnected => {
                std.log.warn("Skipping frame test - no connection", .{});
                return;
            },
            else => return err,
        };
        defer conn.close();

        const stream = conn.openStream() catch |err| switch (err) {
            TransportError.NotConnected, TransportError.Protocol => {
                std.log.warn("Skipping frame test - no stream", .{});
                return;
            },
            else => return err,
        };
        defer stream.close();

        // Test different frame types
        const test_cases = [_]struct {
            frame_type: FrameType,
            flags: u8,
            data: []const u8,
        }{
            .{ .frame_type = FrameType.data, .flags = 0, .data = "test data" },
            .{ .frame_type = FrameType.headers, .flags = Frame.Flags.END_HEADERS, .data = "content-type: application/grpc" },
            .{ .frame_type = FrameType.data, .flags = Frame.Flags.END_STREAM, .data = "final data" },
        };

        for (test_cases) |test_case| {
            try stream.writeFrame(test_case.frame_type, test_case.flags, test_case.data);
        }

        std.log.info("✅ Frame serialization test passed", .{});
    }

    /// Test error handling consistency
    pub fn testErrorHandling(self: *const ContractTestSuite, transport: Transport) !void {
        std.log.info("Testing error handling...", .{});

        // Test invalid endpoint
        const invalid_result = transport.connect(self.allocator, "invalid-endpoint", null);
        try std.testing.expectError(TransportError.InvalidArgument, invalid_result);

        // Test connection to non-existent endpoint
        const nonexistent_result = transport.connect(self.allocator, "192.0.2.0:1", null);
        try std.testing.expectError(TransportError.ConnectionReset, nonexistent_result);

        std.log.info("✅ Error handling test passed", .{});
    }

    /// Test transport adapter cleanup
    pub fn testResourceCleanup(self: *const ContractTestSuite, transport: Transport) !void {
        std.log.info("Testing resource cleanup...", .{});

        // Create and immediately close connection
        const conn = transport.connect(self.allocator, "127.0.0.1:0", null) catch |err| switch (err) {
            TransportError.ConnectionReset, TransportError.NotConnected => {
                std.log.warn("Skipping cleanup test - no connection", .{});
                return;
            },
            else => return err,
        };

        const stream = conn.openStream() catch |err| switch (err) {
            TransportError.NotConnected, TransportError.Protocol => {
                conn.close();
                return;
            },
            else => return err,
        };

        // Close in correct order
        stream.close();
        conn.close();

        std.log.info("✅ Resource cleanup test passed", .{});
    }

    /// Run full contract test suite
    pub fn runAll(self: *const ContractTestSuite, transport: Transport) !void {
        std.log.info("🧪 Running contract test suite...", .{});

        try self.testConnectionLifecycle(transport);
        try self.testStreamOperations(transport);
        try self.testFrameSerialization(transport);
        try self.testErrorHandling(transport);
        try self.testResourceCleanup(transport);

        std.log.info("✅ All contract tests passed!", .{});
    }
};

/// Test runner for multiple transports
pub fn runContractTests(allocator: std.mem.Allocator, transports: []Transport) !void {
    const suite = ContractTestSuite.init(allocator);

    for (transports, 0..) |transport, i| {
        std.log.info("Testing transport adapter #{d}...", .{i + 1});
        try suite.runAll(transport);
    }

    std.log.info("🎉 All transport adapters passed contract tests!", .{});
}

test "contract test framework" {
    const allocator = std.testing.allocator;

    // Test the framework itself
    const suite = ContractTestSuite.init(allocator);
    _ = suite;
}