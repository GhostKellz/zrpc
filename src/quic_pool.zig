//! QUIC Connection Pool and Load Balancing
//! Advanced connection multiplexing for high-performance gRPC
const std = @import("std");
const quic = @import("quic.zig");
const Error = @import("error.zig").Error;

// Connection pool statistics
pub const PoolStats = struct {
    total_connections: u32,
    active_connections: u32,
    idle_connections: u32,
    failed_connections: u32,
    total_requests: u64,
    total_bytes_sent: u64,
    total_bytes_received: u64,
    average_rtt_microseconds: u64,

    pub fn init() PoolStats {
        return PoolStats{
            .total_connections = 0,
            .active_connections = 0,
            .idle_connections = 0,
            .failed_connections = 0,
            .total_requests = 0,
            .total_bytes_sent = 0,
            .total_bytes_received = 0,
            .average_rtt_microseconds = 0,
        };
    }
};

// Load balancing strategy
pub const LoadBalancingStrategy = enum {
    round_robin,
    least_connections,
    least_rtt,
    random,
    weighted_round_robin,
};

// Connection pool configuration
pub const PoolConfig = struct {
    max_connections_per_endpoint: u32,
    max_idle_time_seconds: u32,
    connection_timeout_seconds: u32,
    health_check_interval_seconds: u32,
    enable_0rtt: bool,
    enable_connection_migration: bool,
    load_balancing_strategy: LoadBalancingStrategy,

    pub fn default() PoolConfig {
        return PoolConfig{
            .max_connections_per_endpoint = 10,
            .max_idle_time_seconds = 300, // 5 minutes
            .connection_timeout_seconds = 30,
            .health_check_interval_seconds = 60,
            .enable_0rtt = true,
            .enable_connection_migration = true,
            .load_balancing_strategy = .least_rtt,
        };
    }
};

// Connection wrapper with metadata
pub const PooledConnection = struct {
    connection: *quic.QuicConnection,
    endpoint: []const u8,
    created_at: i64,
    last_used: i64,
    request_count: u32,
    is_healthy: bool,
    current_rtt_microseconds: u64,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, connection: *quic.QuicConnection, endpoint: []const u8) !PooledConnection {
        const owned_endpoint = try allocator.dupe(u8, endpoint);
        const now = std.time.timestamp();

        return PooledConnection{
            .connection = connection,
            .endpoint = owned_endpoint,
            .created_at = now,
            .last_used = now,
            .request_count = 0,
            .is_healthy = true,
            .current_rtt_microseconds = 0,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *PooledConnection) void {
        self.connection.deinit();
        self.allocator.destroy(self.connection);
        self.allocator.free(self.endpoint);
    }

    pub fn updateStats(self: *PooledConnection, rtt_microseconds: u64) void {
        self.last_used = std.time.timestamp();
        self.request_count += 1;
        self.current_rtt_microseconds = rtt_microseconds;
    }

    pub fn isIdle(self: *const PooledConnection, max_idle_seconds: u32) bool {
        const now = std.time.timestamp();
        return (now - self.last_used) > max_idle_seconds;
    }

    pub fn age(self: *const PooledConnection) i64 {
        const now = std.time.timestamp();
        return now - self.created_at;
    }
};

// QUIC connection pool with advanced features
pub const QuicConnectionPool = struct {
    allocator: std.mem.Allocator,
    config: PoolConfig,
    connections: std.AutoHashMap(u64, *PooledConnection),
    endpoint_connections: std.StringHashMap(std.ArrayList(*PooledConnection)),
    round_robin_counters: std.StringHashMap(u32),
    stats: PoolStats,
    mutex: std.Thread.Mutex,

    pub fn init(allocator: std.mem.Allocator, config: PoolConfig) QuicConnectionPool {
        return QuicConnectionPool{
            .allocator = allocator,
            .config = config,
            .connections = std.AutoHashMap(u64, *PooledConnection).init(allocator),
            .endpoint_connections = std.StringHashMap(std.ArrayList(*PooledConnection)).init(allocator),
            .round_robin_counters = std.StringHashMap(u32).init(allocator),
            .stats = PoolStats.init(),
            .mutex = std.Thread.Mutex{},
        };
    }

    pub fn deinit(self: *QuicConnectionPool) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Clean up all connections
        var conn_iter = self.connections.iterator();
        while (conn_iter.next()) |entry| {
            entry.value_ptr.*.deinit();
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.connections.deinit();

        // Clean up endpoint connection lists
        var endpoint_iter = self.endpoint_connections.iterator();
        while (endpoint_iter.next()) |entry| {
            entry.value_ptr.deinit(self.allocator);
        }
        self.endpoint_connections.deinit();

        self.round_robin_counters.deinit();
    }

    pub fn getConnection(self: *QuicConnectionPool, endpoint: []const u8) !*PooledConnection {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Get connections for this endpoint
        var endpoint_conns = self.endpoint_connections.get(endpoint);
        if (endpoint_conns == null) {
            // Create new connection list for this endpoint
            const new_list = std.ArrayList(*PooledConnection).init(self.allocator);
            try self.endpoint_connections.put(try self.allocator.dupe(u8, endpoint), new_list);
            endpoint_conns = self.endpoint_connections.getPtr(endpoint);
        }

        const conn_list = &endpoint_conns.?;

        // Remove unhealthy and idle connections
        self.cleanupConnections(conn_list);

        // Find best connection based on strategy
        if (conn_list.items.len > 0) {
            const selected = try self.selectConnection(conn_list.items, endpoint);
            if (selected) |conn| {
                return conn;
            }
        }

        // Create new connection if under limit
        if (conn_list.items.len < self.config.max_connections_per_endpoint) {
            return try self.createNewConnection(endpoint, conn_list);
        }

        // Pool exhausted - return least loaded connection
        return try self.selectConnection(conn_list.items, endpoint) orelse
            return Error.ResourceExhausted;
    }

    fn cleanupConnections(self: *QuicConnectionPool, conn_list: *std.ArrayList(*PooledConnection)) void {
        var i: usize = 0;
        while (i < conn_list.items.len) {
            const conn = conn_list.items[i];
            if (!conn.is_healthy or conn.isIdle(self.config.max_idle_time_seconds)) {
                _ = conn_list.swapRemove(i);

                // Remove from global connections map
                _ = self.connections.remove(@intFromPtr(conn));

                // Update stats
                if (!conn.is_healthy) {
                    self.stats.failed_connections += 1;
                }
                self.stats.active_connections -= 1;

                conn.deinit();
                self.allocator.destroy(conn);
            } else {
                i += 1;
            }
        }
    }

    fn selectConnection(self: *QuicConnectionPool, connections: []*PooledConnection, endpoint: []const u8) !?*PooledConnection {
        if (connections.len == 0) return null;

        switch (self.config.load_balancing_strategy) {
            .round_robin => {
                const counter = self.round_robin_counters.get(endpoint) orelse 0;
                const selected = connections[counter % connections.len];
                try self.round_robin_counters.put(try self.allocator.dupe(u8, endpoint), counter + 1);
                return selected;
            },
            .least_connections => {
                var best_conn = connections[0];
                for (connections[1..]) |conn| {
                    if (conn.request_count < best_conn.request_count) {
                        best_conn = conn;
                    }
                }
                return best_conn;
            },
            .least_rtt => {
                var best_conn = connections[0];
                for (connections[1..]) |conn| {
                    if (conn.current_rtt_microseconds < best_conn.current_rtt_microseconds) {
                        best_conn = conn;
                    }
                }
                return best_conn;
            },
            .random => {
                var rng = std.crypto.random;
                const index = rng.intRangeLessThan(usize, 0, connections.len);
                return connections[index];
            },
            .weighted_round_robin => {
                // Simple weighted by inverse RTT for now
                var total_weight: u64 = 0;
                for (connections) |conn| {
                    const weight = if (conn.current_rtt_microseconds > 0)
                        1000000 / conn.current_rtt_microseconds else 1000;
                    total_weight += weight;
                }

                var rng = std.crypto.random;
                var random_weight = rng.intRangeLessThan(u64, 0, total_weight);

                for (connections) |conn| {
                    const weight = if (conn.current_rtt_microseconds > 0)
                        1000000 / conn.current_rtt_microseconds else 1000;
                    if (random_weight < weight) {
                        return conn;
                    }
                    random_weight -= weight;
                }

                return connections[0];
            },
        }
    }

    fn createNewConnection(self: *QuicConnectionPool, endpoint: []const u8, conn_list: *std.ArrayList(*PooledConnection)) !*PooledConnection {
        // Parse endpoint
        const address = try self.parseEndpoint(endpoint);

        // Create new QUIC connection
        const quic_conn = try self.allocator.create(quic.QuicConnection);
        quic_conn.* = try quic.QuicConnection.initClient(self.allocator, address);

        // Enable advanced features if configured
        if (self.config.enable_connection_migration) {
            // Initialize primary path
            const primary_path = quic.NetworkPath.init(
                try std.net.Address.parseIp4("0.0.0.0", 0),
                address,
                0
            );
            try quic_conn.migration_context.active_paths.append(self.allocator, primary_path);
        }

        // Perform handshake
        try quic_conn.handshake();

        // Create pooled connection wrapper
        const pooled_conn = try self.allocator.create(PooledConnection);
        pooled_conn.* = try PooledConnection.init(self.allocator, quic_conn, endpoint);

        // Add to maps
        try self.connections.put(@intFromPtr(pooled_conn), pooled_conn);
        try conn_list.append(self.allocator, pooled_conn);

        // Update stats
        self.stats.total_connections += 1;
        self.stats.active_connections += 1;

        return pooled_conn;
    }

    fn parseEndpoint(self: *QuicConnectionPool, endpoint: []const u8) !std.net.Address {
        _ = self;

        // Simple parsing for quic://host:port
        if (!std.mem.startsWith(u8, endpoint, "quic://") and !std.mem.startsWith(u8, endpoint, "quics://")) {
            return Error.InvalidArgument;
        }

        const is_secure = std.mem.startsWith(u8, endpoint, "quics://");
        const url_without_scheme = if (is_secure) endpoint[8..] else endpoint[7..];

        const colon_pos = std.mem.indexOf(u8, url_without_scheme, ":");
        const slash_pos = std.mem.indexOf(u8, url_without_scheme, "/");

        const host = if (colon_pos) |pos|
            url_without_scheme[0..pos]
        else if (slash_pos) |pos|
            url_without_scheme[0..pos]
        else
            url_without_scheme;

        const port: u16 = if (colon_pos) |pos| blk: {
            const end_pos = if (slash_pos) |sp| sp else url_without_scheme.len;
            const port_str = url_without_scheme[pos + 1..end_pos];
            break :blk std.fmt.parseInt(u16, port_str, 10) catch if (is_secure) 443 else 80;
        } else if (is_secure) 443 else 80;

        return std.net.Address.resolveIp(host, port) catch Error.NetworkError;
    }

    pub fn getStats(self: *const QuicConnectionPool) PoolStats {
        return self.stats;
    }

    pub fn healthCheck(self: *QuicConnectionPool) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        var endpoint_iter = self.endpoint_connections.iterator();
        while (endpoint_iter.next()) |entry| {
            const conn_list = &entry.value_ptr.*;
            for (conn_list.items) |conn| {
                // Simple health check - ping the connection
                self.pingConnection(conn) catch {
                    conn.is_healthy = false;
                };
            }
        }
    }

    fn pingConnection(self: *QuicConnectionPool, conn: *PooledConnection) !void {
        _ = self;
        _ = conn;
        // TODO: Implement actual PING frame
        // For now, just assume healthy if connection is established
    }
};

// Tests
test "connection pool creation" {
    const config = PoolConfig.default();
    var pool = QuicConnectionPool.init(std.testing.allocator, config);
    defer pool.deinit();

    const stats = pool.getStats();
    try std.testing.expectEqual(@as(u32, 0), stats.total_connections);
    try std.testing.expectEqual(@as(u32, 0), stats.active_connections);
}

test "pooled connection lifecycle" {
    const mock_quic_conn = try std.testing.allocator.create(quic.QuicConnection);
    defer std.testing.allocator.destroy(mock_quic_conn);

    // Initialize with minimal setup for testing
    mock_quic_conn.* = quic.QuicConnection{
        .allocator = std.testing.allocator,
        .state = .initial,
        .local_connection_id = quic.ConnectionId.init("test"),
        .peer_connection_id = quic.ConnectionId.init("peer"),
        .streams = std.AutoHashMap(u64, *quic.QuicStream).init(std.testing.allocator),
        .next_stream_id = 0,
        .socket = std.net.Stream{ .handle = 0 },
        .peer_address = std.net.Address.initIp4([4]u8{ 127, 0, 0, 1 }, 8080),
        .is_server = false,
        .early_data_context = quic.EarlyDataContext.init(),
        .migration_context = quic.MigrationContext.init(std.testing.allocator),
        .transport_params = quic.TransportParameters.default(),
        .zero_rtt_keys = null,
        .session_resumption_ticket = null,
        .current_path_id = 0,
        .path_validation_tokens = std.AutoHashMap(u64, [8]u8).init(std.testing.allocator),
    };

    var pooled = try PooledConnection.init(std.testing.allocator, mock_quic_conn, "quic://test.example.com:443");
    defer {
        // Only free the endpoint, not the connection (since it's on testing allocator)
        std.testing.allocator.free(pooled.endpoint);
        // Clean up mock connection components
        mock_quic_conn.early_data_context.deinit();
        mock_quic_conn.migration_context.deinit();
        mock_quic_conn.path_validation_tokens.deinit();
        mock_quic_conn.streams.deinit();
    }

    try std.testing.expectEqualStrings("quic://test.example.com:443", pooled.endpoint);
    try std.testing.expectEqual(@as(u32, 0), pooled.request_count);
    try std.testing.expect(pooled.is_healthy);

    pooled.updateStats(1500); // 1.5ms RTT
    try std.testing.expectEqual(@as(u32, 1), pooled.request_count);
    try std.testing.expectEqual(@as(u64, 1500), pooled.current_rtt_microseconds);
}