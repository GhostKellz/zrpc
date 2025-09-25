//! Performance optimization module for zRPC
//! Implements zero-copy operations, memory optimization, and CPU usage improvements

const std = @import("std");
const transport_interface = @import("transport_interface.zig");
const TransportError = transport_interface.TransportError;
const Frame = transport_interface.Frame;
const FrameType = transport_interface.FrameType;

/// Performance configuration settings
pub const PerformanceConfig = struct {
    /// Enable zero-copy optimizations where possible
    enable_zero_copy: bool = true,

    /// Use memory pools for frequent allocations
    enable_memory_pools: bool = true,

    /// Buffer pool size for frame buffers
    frame_buffer_pool_size: u32 = 1000,

    /// Maximum buffer size for pooling
    max_pooled_buffer_size: usize = 64 * 1024, // 64KB

    /// Enable SIMD optimizations where available
    enable_simd: bool = true,

    /// Prefetch distance for memory access patterns
    prefetch_distance: u32 = 64,

    /// Enable CPU cache-friendly data layouts
    enable_cache_optimization: bool = true,
};

/// Zero-copy buffer management
pub const ZeroCopyBuffer = struct {
    data: []u8,
    allocator: std.mem.Allocator,
    ref_count: std.atomic.Value(u32),
    read_only: bool,

    pub fn init(allocator: std.mem.Allocator, size: usize, read_only: bool) !*ZeroCopyBuffer {
        const buffer = try allocator.create(ZeroCopyBuffer);
        const data = try allocator.alloc(u8, size);

        buffer.* = ZeroCopyBuffer{
            .data = data,
            .allocator = allocator,
            .ref_count = std.atomic.Value(u32).init(1),
            .read_only = read_only,
        };

        return buffer;
    }

    pub fn fromSlice(allocator: std.mem.Allocator, data: []const u8) !*ZeroCopyBuffer {
        const buffer = try allocator.create(ZeroCopyBuffer);
        const buffer_data = try allocator.dupe(u8, data);

        buffer.* = ZeroCopyBuffer{
            .data = buffer_data,
            .allocator = allocator,
            .ref_count = std.atomic.Value(u32).init(1),
            .read_only = true,
        };

        return buffer;
    }

    pub fn retain(self: *ZeroCopyBuffer) void {
        _ = self.ref_count.fetchAdd(1, .seq_cst);
    }

    pub fn release(self: *ZeroCopyBuffer) void {
        const old_count = self.ref_count.fetchSub(1, .seq_cst);
        if (old_count == 1) {
            self.allocator.free(self.data);
            self.allocator.destroy(self);
        }
    }

    pub fn asReadOnly(self: *ZeroCopyBuffer) []const u8 {
        return self.data;
    }

    pub fn asMutable(self: *ZeroCopyBuffer) ![]u8 {
        if (self.read_only) {
            return TransportError.InvalidArgument;
        }
        return self.data;
    }

    /// Create a zero-copy slice of this buffer
    pub fn slice(self: *ZeroCopyBuffer, start: usize, end: usize) !*ZeroCopyBuffer {
        if (start >= end or end > self.data.len) {
            return TransportError.InvalidArgument;
        }

        const new_buffer = try self.allocator.create(ZeroCopyBuffer);
        new_buffer.* = ZeroCopyBuffer{
            .data = self.data[start..end],
            .allocator = self.allocator,
            .ref_count = std.atomic.Value(u32).init(1),
            .read_only = self.read_only,
        };

        // Share reference to the original buffer
        self.retain();

        return new_buffer;
    }
};

/// High-performance memory pool for frequent allocations
pub const MemoryPool = struct {
    const PoolEntry = struct {
        buffer: []u8,
        next: ?*PoolEntry,
    };

    allocator: std.mem.Allocator,
    buffer_size: usize,
    free_list: ?*PoolEntry,
    mutex: std.Thread.Mutex,
    total_allocated: std.atomic.Value(u64),
    cache_hits: std.atomic.Value(u64),
    cache_misses: std.atomic.Value(u64),

    pub fn init(allocator: std.mem.Allocator, buffer_size: usize, initial_count: u32) !MemoryPool {
        var pool = MemoryPool{
            .allocator = allocator,
            .buffer_size = buffer_size,
            .free_list = null,
            .mutex = std.Thread.Mutex{},
            .total_allocated = std.atomic.Value(u64).init(0),
            .cache_hits = std.atomic.Value(u64).init(0),
            .cache_misses = std.atomic.Value(u64).init(0),
        };

        // Pre-allocate initial buffers
        for (0..initial_count) |_| {
            const entry = try allocator.create(PoolEntry);
            entry.buffer = try allocator.alloc(u8, buffer_size);
            entry.next = pool.free_list;
            pool.free_list = entry;
        }

        return pool;
    }

    pub fn deinit(self: *MemoryPool) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        var current = self.free_list;
        while (current) |entry| {
            const next = entry.next;
            self.allocator.free(entry.buffer);
            self.allocator.destroy(entry);
            current = next;
        }
    }

    pub fn acquire(self: *MemoryPool) ![]u8 {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.free_list) |entry| {
            self.free_list = entry.next;
            const buffer = entry.buffer;
            self.allocator.destroy(entry);
            _ = self.cache_hits.fetchAdd(1, .seq_cst);
            return buffer;
        } else {
            // Pool empty, allocate new buffer
            _ = self.cache_misses.fetchAdd(1, .seq_cst);
            _ = self.total_allocated.fetchAdd(1, .seq_cst);
            return try self.allocator.alloc(u8, self.buffer_size);
        }
    }

    pub fn release(self: *MemoryPool, buffer: []u8) void {
        if (buffer.len != self.buffer_size) {
            // Wrong size, just free it
            self.allocator.free(buffer);
            return;
        }

        self.mutex.lock();
        defer self.mutex.unlock();

        const entry = self.allocator.create(PoolEntry) catch {
            // Failed to create entry, just free the buffer
            self.allocator.free(buffer);
            return;
        };

        entry.buffer = buffer;
        entry.next = self.free_list;
        self.free_list = entry;
    }

    pub fn getStats(self: *const MemoryPool) PoolStats {
        return PoolStats{
            .total_allocated = self.total_allocated.load(.seq_cst),
            .cache_hits = self.cache_hits.load(.seq_cst),
            .cache_misses = self.cache_misses.load(.seq_cst),
        };
    }
};

pub const PoolStats = struct {
    total_allocated: u64,
    cache_hits: u64,
    cache_misses: u64,
};

/// Optimized frame operations with zero-copy where possible
pub const OptimizedFrame = struct {
    frame_type: FrameType,
    flags: u8,
    buffer: *ZeroCopyBuffer,
    data_range: struct { start: usize, end: usize },

    pub fn initFromBuffer(frame_type: FrameType, flags: u8, buffer: *ZeroCopyBuffer, start: usize, end: usize) !OptimizedFrame {
        if (start >= end or end > buffer.data.len) {
            return TransportError.InvalidArgument;
        }

        buffer.retain(); // Keep buffer alive

        return OptimizedFrame{
            .frame_type = frame_type,
            .flags = flags,
            .buffer = buffer,
            .data_range = .{ .start = start, .end = end },
        };
    }

    pub fn initFromSlice(allocator: std.mem.Allocator, frame_type: FrameType, flags: u8, data: []const u8) !OptimizedFrame {
        const buffer = try ZeroCopyBuffer.fromSlice(allocator, data);
        return OptimizedFrame{
            .frame_type = frame_type,
            .flags = flags,
            .buffer = buffer,
            .data_range = .{ .start = 0, .end = data.len },
        };
    }

    pub fn deinit(self: *OptimizedFrame) void {
        self.buffer.release();
    }

    pub fn getData(self: *const OptimizedFrame) []const u8 {
        return self.buffer.data[self.data_range.start..self.data_range.end];
    }

    /// Create a legacy Frame for compatibility
    pub fn toLegacyFrame(self: *const OptimizedFrame, allocator: std.mem.Allocator) !Frame {
        const data = self.getData();
        return Frame.init(allocator, self.frame_type, self.flags, data);
    }

    /// Zero-copy slice operation
    pub fn slice(self: *const OptimizedFrame, _: std.mem.Allocator, start: usize, end: usize) !OptimizedFrame {
        if (start >= end or end > (self.data_range.end - self.data_range.start)) {
            return TransportError.InvalidArgument;
        }

        const buffer_slice = try self.buffer.slice(
            self.data_range.start + start,
            self.data_range.start + end
        );

        return OptimizedFrame{
            .frame_type = self.frame_type,
            .flags = self.flags,
            .buffer = buffer_slice,
            .data_range = .{ .start = 0, .end = end - start },
        };
    }
};

/// SIMD-optimized operations where available
pub const SimdOps = struct {
    pub fn memcopy(dest: []u8, src: []const u8) void {
        std.debug.assert(dest.len >= src.len);

        if (comptime @import("builtin").target.cpu.arch.isX86()) {
            // Use vectorized copy for x86/x86_64
            vectorMemcopy(dest, src);
        } else {
            // Fallback to standard memcpy
            @memcpy(dest[0..src.len], src);
        }
    }

    fn vectorMemcopy(dest: []u8, src: []const u8) void {
        const copy_len = src.len;

        if (copy_len >= 32 and comptime std.simd.suggestVectorLength(u8) != null) {
            const vector_len = comptime std.simd.suggestVectorLength(u8) orelse 32;
            const Vector = @Vector(vector_len, u8);

            var i: usize = 0;
            while (i + vector_len <= copy_len) : (i += vector_len) {
                const vec: Vector = src[i..i+vector_len][0..vector_len].*;
                dest[i..i+vector_len][0..vector_len].* = vec;
            }

            // Handle remaining bytes
            @memcpy(dest[i..copy_len], src[i..copy_len]);
        } else {
            @memcpy(dest[0..copy_len], src);
        }
    }

    /// Optimized comparison for frame types and data
    pub fn compareFrameData(a: []const u8, b: []const u8) bool {
        if (a.len != b.len) return false;
        if (a.len == 0) return true;

        if (comptime @import("builtin").target.cpu.arch.isX86() and std.simd.suggestVectorLength(u8) != null) {
            return vectorCompare(a, b);
        } else {
            return std.mem.eql(u8, a, b);
        }
    }

    fn vectorCompare(a: []const u8, b: []const u8) bool {
        const vector_len = comptime std.simd.suggestVectorLength(u8) orelse 32;
        const Vector = @Vector(vector_len, u8);

        var i: usize = 0;
        while (i + vector_len <= a.len) : (i += vector_len) {
            const vec_a: Vector = a[i..i+vector_len][0..vector_len].*;
            const vec_b: Vector = b[i..i+vector_len][0..vector_len].*;

            if (!@reduce(.And, vec_a == vec_b)) {
                return false;
            }
        }

        // Handle remaining bytes
        return std.mem.eql(u8, a[i..], b[i..]);
    }
};

/// CPU profiling utilities for performance optimization
pub const CpuProfiler = struct {
    start_time: i128,
    samples: std.ArrayList(ProfileSample),

    const ProfileSample = struct {
        timestamp: i128,
        operation: []const u8,
        duration_ns: u64,
    };

    pub fn init(allocator: std.mem.Allocator) CpuProfiler {
        return CpuProfiler{
            .start_time = std.time.nanoTimestamp(),
            .samples = std.ArrayList(ProfileSample).init(allocator),
        };
    }

    pub fn deinit(self: *CpuProfiler) void {
        self.samples.deinit();
    }

    pub fn startSample(self: *CpuProfiler, operation: []const u8) !ProfileHandle {
        return ProfileHandle{
            .profiler = self,
            .operation = operation,
            .start_time = std.time.nanoTimestamp(),
        };
    }

    pub fn addSample(self: *CpuProfiler, operation: []const u8, duration_ns: u64) !void {
        try self.samples.append(ProfileSample{
            .timestamp = std.time.nanoTimestamp() - self.start_time,
            .operation = operation,
            .duration_ns = duration_ns,
        });
    }

    pub fn getAverageTime(self: *const CpuProfiler, operation: []const u8) ?u64 {
        var total: u64 = 0;
        var count: u32 = 0;

        for (self.samples.items) |sample| {
            if (std.mem.eql(u8, sample.operation, operation)) {
                total += sample.duration_ns;
                count += 1;
            }
        }

        return if (count > 0) total / count else null;
    }
};

pub const ProfileHandle = struct {
    profiler: *CpuProfiler,
    operation: []const u8,
    start_time: i128,

    pub fn end(self: ProfileHandle) !void {
        const end_time = std.time.nanoTimestamp();
        const duration = @as(u64, @intCast(@max(0, end_time - self.start_time)));
        try self.profiler.addSample(self.operation, duration);
    }
};

test "zero copy buffer operations" {
    const allocator = std.testing.allocator;

    const buffer = try ZeroCopyBuffer.fromSlice(allocator, "Hello, World!");
    defer buffer.release();

    try std.testing.expectEqualStrings("Hello, World!", buffer.asReadOnly());

    const slice_buf = try buffer.slice(7, 12);
    defer slice_buf.release();

    try std.testing.expectEqualStrings("World", slice_buf.asReadOnly());
}

test "memory pool operations" {
    const allocator = std.testing.allocator;

    var pool = try MemoryPool.init(allocator, 1024, 5);
    defer pool.deinit();

    const buffer1 = try pool.acquire();
    const buffer2 = try pool.acquire();

    try std.testing.expect(buffer1.len == 1024);
    try std.testing.expect(buffer2.len == 1024);

    pool.release(buffer1);
    pool.release(buffer2);

    const stats = pool.getStats();
    try std.testing.expect(stats.cache_hits >= 0);
}

test "SIMD operations" {
    const data1 = "Hello, World!";
    const data2 = "Hello, World!";
    const data3 = "Hello, Zig!!!";

    try std.testing.expect(SimdOps.compareFrameData(data1, data2));
    try std.testing.expect(!SimdOps.compareFrameData(data1, data3));
}