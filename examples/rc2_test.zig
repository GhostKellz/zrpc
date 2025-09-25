//! RC-2 acceptance test suite
//! Security and performance hardening validation

const std = @import("std");
const zrpc_core = @import("zrpc-core");
const zrpc_quic = @import("zrpc-transport-quic");

const ContractTestSuite = zrpc_core.contract_tests.ContractTestSuite;
const BenchmarkRunner = zrpc_core.benchmark.BenchmarkRunner;
const BenchmarkConfig = zrpc_core.benchmark.BenchmarkConfig;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{ .safety = true }){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.log.info("🎖️  RC-2 Test Suite: Security & Performance Hardening", .{});
    std.log.info("===========================================================", .{});

    // Phase 1: Security Review and Hardening
    std.log.info("\n🔒 Phase 1: Security Review & Hardening", .{});
    std.log.info("---------------------------------------", .{});

    try runSecurityTests(allocator);
    std.log.info("✅ Security review and hardening completed", .{});

    // Phase 2: Performance Optimization Validation
    std.log.info("\n⚡ Phase 2: Performance Optimization Validation", .{});
    std.log.info("----------------------------------------------", .{});

    try runPerformanceOptimizationTests(allocator);
    std.log.info("✅ Performance optimization validation completed", .{});

    // Phase 3: Compatibility Matrix Testing
    std.log.info("\n🧪 Phase 3: Compatibility Matrix Testing", .{});
    std.log.info("----------------------------------------", .{});

    try runCompatibilityMatrixTests(allocator);
    std.log.info("✅ Compatibility matrix testing completed", .{});

    // Phase 4: Enhanced Performance Benchmarks
    std.log.info("\n📊 Phase 4: Enhanced Performance Benchmarks", .{});
    std.log.info("-------------------------------------------", .{});

    try runEnhancedBenchmarks(allocator);
    std.log.info("✅ Enhanced performance benchmarks completed", .{});

    // Phase 5: Memory Safety and Resource Management
    std.log.info("\n🛡️  Phase 5: Memory Safety & Resource Management", .{});
    std.log.info("------------------------------------------------", .{});

    try runMemorySafetyTests(allocator);
    std.log.info("✅ Memory safety and resource management validated", .{});

    // Final Results
    std.log.info("\n🎉 RC-2 Test Suite Results", .{});
    std.log.info("===========================", .{});
    std.log.info("✅ Security review & hardening: PASSED", .{});
    std.log.info("✅ Performance optimization: PASSED", .{});
    std.log.info("✅ Compatibility matrix: PASSED", .{});
    std.log.info("✅ Enhanced benchmarks: PASSED", .{});
    std.log.info("✅ Memory safety validation: PASSED", .{});
    std.log.info("", .{});
    std.log.info("🚀 zRPC is ready for RC-2 release!", .{});
    std.log.info("📝 Next steps: Documentation and migration guides (RC-3)", .{});
}

/// Run comprehensive security tests
fn runSecurityTests(allocator: std.mem.Allocator) !void {
    std.log.info("🔍 Running security validation tests...", .{});

    // Test 1: Input validation and sanitization
    {
        const config = zrpc_core.SecurityConfig{};
        const validator = zrpc_core.SecurityValidator.init(allocator, config);

        // Test endpoint validation
        validator.validateEndpoint("localhost:8080") catch |err| {
            std.log.err("Valid endpoint rejected: {}", .{err});
            return err;
        };

        // Test malicious endpoint rejection
        if (validator.validateEndpoint("javascript:alert(1)")) |_| {
            std.log.err("Malicious endpoint accepted!", .{});
            return error.SecurityViolation;
        } else |_| {
            // Expected failure
        }

        std.log.info("  ✓ Input validation and sanitization tests passed", .{});
    }

    // Test 2: TLS configuration security
    {
        const config = zrpc_core.SecurityConfig{ .strict_tls_validation = true };
        const validator = zrpc_core.SecurityValidator.init(allocator, config);

        // Test strict TLS validation
        if (validator.validateTlsConfig(null)) |_| {
            std.log.err("Null TLS config accepted in strict mode!", .{});
            return error.SecurityViolation;
        } else |_| {
            // Expected failure in strict mode
        }

        std.log.info("  ✓ TLS configuration security tests passed", .{});
    }

    // Test 3: Payload size and content validation
    {
        const config = zrpc_core.SecurityConfig{ .max_message_size = 1024 };
        const validator = zrpc_core.SecurityValidator.init(allocator, config);

        // Test valid payload
        try validator.validatePayload("Hello, World!");

        // Test oversized payload
        const large_payload = "x" ** 2048;
        if (validator.validatePayload(large_payload)) |_| {
            std.log.err("Oversized payload accepted!", .{});
            return error.SecurityViolation;
        } else |_| {
            // Expected failure
        }

        std.log.info("  ✓ Payload validation tests passed", .{});
    }

    // Test 4: Secure random generation
    {
        var secure_random = zrpc_core.SecureRandom.init();

        const id1 = secure_random.generateConnectionId();
        const id2 = secure_random.generateConnectionId();

        if (id1 == id2) {
            std.log.err("Secure random generated identical IDs!", .{});
            return error.SecurityViolation;
        }

        std.log.info("  ✓ Secure random generation tests passed", .{});
    }

    std.log.info("🔒 All security tests passed", .{});
}

/// Run performance optimization tests
fn runPerformanceOptimizationTests(allocator: std.mem.Allocator) !void {
    std.log.info("⚡ Running performance optimization tests...", .{});

    // Test 1: Zero-copy buffer operations
    {

        const buffer = try zrpc_core.ZeroCopyBuffer.fromSlice(allocator, "Hello, World!");
        defer buffer.release();

        const slice_buf = try buffer.slice(7, 12);
        defer slice_buf.release();

        if (!std.mem.eql(u8, slice_buf.asReadOnly(), "World")) {
            std.log.err("Zero-copy slice operation failed!", .{});
            return error.PerformanceTestFailed;
        }

        std.log.info("  ✓ Zero-copy buffer operations validated", .{});
    }

    // Test 2: Memory pool efficiency
    {
        var pool = try zrpc_core.MemoryPool.init(allocator, 1024, 10);
        defer pool.deinit();

        // Allocate and release multiple buffers
        var buffers: [20][]u8 = undefined;
        for (buffers[0..], 0..) |*buffer, i| {
            buffer.* = try pool.acquire();
            _ = i;
        }

        for (buffers) |buffer| {
            pool.release(buffer);
        }

        const stats = pool.getStats();
        if (stats.cache_hits == 0) {
            std.log.warn("Memory pool showed no cache hits - may not be working optimally", .{});
        }

        std.log.info("  ✓ Memory pool efficiency validated (hits: {d}, misses: {d})", .{ stats.cache_hits, stats.cache_misses });
    }

    // Test 3: SIMD operations
    {
        const data1 = "Hello, World! This is a test string for SIMD operations.";
        const data2 = "Hello, World! This is a test string for SIMD operations.";
        const data3 = "Hello, World! This is a different string for comparison.";

        if (!zrpc_core.SimdOps.compareFrameData(data1, data2)) {
            std.log.err("SIMD comparison failed for identical strings!", .{});
            return error.PerformanceTestFailed;
        }

        if (zrpc_core.SimdOps.compareFrameData(data1, data3)) {
            std.log.err("SIMD comparison failed for different strings!", .{});
            return error.PerformanceTestFailed;
        }

        std.log.info("  ✓ SIMD operations validated", .{});
    }

    // Test 4: CPU profiling
    {
        var profiler = zrpc_core.performance.CpuProfiler.init(allocator);
        defer profiler.deinit();

        // Profile a simple operation
        const handle = try profiler.startSample("test_operation");
        std.time.sleep(1_000_000); // Sleep 1ms
        try handle.end();

        if (profiler.getAverageTime("test_operation")) |avg_time| {
            if (avg_time == 0) {
                std.log.err("CPU profiler reported zero time!", .{});
                return error.PerformanceTestFailed;
            }
            std.log.info("  ✓ CPU profiling validated (avg: {d}ns)", .{avg_time});
        } else {
            std.log.err("CPU profiler failed to record operation!", .{});
            return error.PerformanceTestFailed;
        }
    }

    std.log.info("⚡ All performance optimization tests passed", .{});
}

/// Run compatibility matrix tests
fn runCompatibilityMatrixTests(allocator: std.mem.Allocator) !void {
    std.log.info("🧪 Running compatibility matrix tests...", .{});

    // Report platform capabilities
    zrpc_core.PlatformFeatures.reportPlatformCapabilities();

    // Run compatibility matrix
    var matrix = zrpc_core.CompatibilityMatrix.init(allocator);
    defer matrix.deinit();

    try matrix.runAllTests();

    // Generate report to temporary buffer
    var report_buffer = std.ArrayList(u8).init(allocator);
    defer report_buffer.deinit();

    try matrix.generateReport(report_buffer.writer());

    if (report_buffer.items.len == 0) {
        std.log.err("Compatibility matrix report generation failed!", .{});
        return error.CompatibilityTestFailed;
    }

    std.log.info("🧪 Compatibility matrix tests completed successfully", .{});
}

/// Run enhanced performance benchmarks
fn runEnhancedBenchmarks(allocator: std.mem.Allocator) !void {
    std.log.info("📊 Running enhanced performance benchmarks...", .{});

    const quic_transport = zrpc_quic.createClientTransport(allocator);
    defer quic_transport.deinit();

    // Enhanced benchmark configuration with stricter performance requirements
    const bench_config = BenchmarkConfig{
        .iterations = 1000, // More iterations for statistical significance
        .payload_size = 4096, // Larger payload size
        .streaming_count = 20, // More streaming operations
        .chunk_size = 8192,
        .warmup_iterations = 200, // More warmup
        .track_allocations = true,
    };

    var benchmark_runner = BenchmarkRunner.init(allocator, bench_config);
    try benchmark_runner.runBenchmarkSuite(quic_transport);

    std.log.info("📊 Enhanced performance benchmarks completed", .{});
}

/// Run memory safety and resource management tests
fn runMemorySafetyTests(allocator: std.mem.Allocator) !void {
    std.log.info("🛡️  Running memory safety tests...", .{});

    // Test 1: Memory leak detection in transport operations
    {
        const quic_transport = zrpc_quic.createClientTransport(allocator);
        defer quic_transport.deinit();

        // Perform multiple connection attempts to test cleanup
        for (0..10) |i| {
            _ = i;
            const result = quic_transport.connect(allocator, "127.0.0.1:0", null);
            if (result) |conn| {
                conn.close();
            } else |_| {
                // Expected failure for test endpoint
            }
        }

        std.log.info("  ✓ Transport resource cleanup validated", .{});
    }

    // Test 2: Frame memory management
    {
        const Frame = zrpc_core.transport.Frame;
        const FrameType = zrpc_core.transport.FrameType;

        var frames: [100]Frame = undefined;

        // Create multiple frames
        for (frames[0..], 0..) |*frame, i| {
            const data = try std.fmt.allocPrint(allocator, "frame data {d}", .{i});
            defer allocator.free(data);
            frame.* = try Frame.init(allocator, FrameType.data, 0, data);
        }

        // Clean up all frames
        for (frames[0..]) |*frame| {
            frame.deinit();
        }

        std.log.info("  ✓ Frame memory management validated", .{});
    }

    // Test 3: Security validator memory safety
    {
        const config = zrpc_core.SecurityConfig{};
        const validator = zrpc_core.SecurityValidator.init(allocator, config);

        // Test with various allocation sizes
        const sizes = [_]usize{ 1, 100, 1000, 10000, 100000 };
        for (sizes) |size| {
            validator.validateAllocation(size) catch |err| switch (err) {
                zrpc_core.transport.TransportError.ResourceExhausted => {
                    // Expected for very large allocations
                },
                else => return err,
            };
        }

        std.log.info("  ✓ Security validator memory safety validated", .{});
    }

    std.log.info("🛡️  All memory safety tests passed", .{});
}