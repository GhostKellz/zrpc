//! QUIC transport implementation for zrpc
//! Custom QUIC/HTTP3 implementation optimized for gRPC
const std = @import("std");
const Error = @import("error.zig").Error;
const tls = @import("tls.zig");

// QUIC protocol constants
pub const QUIC_VERSION_1: u32 = 0x00000001;
pub const INITIAL_MAX_DATA: u64 = 1024 * 1024; // 1MB
pub const INITIAL_MAX_STREAM_DATA: u64 = 256 * 1024; // 256KB
pub const INITIAL_MAX_STREAMS: u64 = 100;

// Packet types according to RFC 9000
pub const PacketType = enum(u8) {
    initial = 0x0,
    zero_rtt = 0x1,
    handshake = 0x2,
    retry = 0x3,
    one_rtt = 0x4,
};

// QUIC frame types
pub const FrameType = enum(u8) {
    padding = 0x00,
    ping = 0x01,
    ack = 0x02,
    reset_stream = 0x04,
    stop_sending = 0x05,
    crypto = 0x06,
    new_token = 0x07,
    stream = 0x08, // Stream frames 0x08-0x0f
    max_data = 0x10,
    max_stream_data = 0x11,
    max_streams = 0x12,
    data_blocked = 0x14,
    stream_data_blocked = 0x15,
    streams_blocked = 0x16,
    new_connection_id = 0x18,
    retire_connection_id = 0x19,
    path_challenge = 0x1a,
    path_response = 0x1b,
    connection_close = 0x1c,
    handshake_done = 0x1e,
};

// Stream states
pub const StreamState = enum {
    idle,
    open,
    half_closed_local,
    half_closed_remote,
    closed,
    reset_sent,
    reset_received,
};

// Connection states
pub const ConnectionState = enum {
    initial,
    handshake,
    established,
    closing,
    draining,
    closed,
    // 0-RTT states
    zero_rtt_attempt,
    zero_rtt_established,
};

pub const ConnectionId = struct {
    data: [20]u8,
    len: u8,

    pub fn init(data: []const u8) ConnectionId {
        var cid = ConnectionId{
            .data = [_]u8{0} ** 20,
            .len = @intCast(@min(data.len, 20)),
        };
        @memcpy(cid.data[0..cid.len], data[0..cid.len]);
        return cid;
    }

    pub fn random(allocator: std.mem.Allocator) !ConnectionId {
        _ = allocator;
        var data: [8]u8 = undefined;
        std.crypto.random.bytes(&data);
        return ConnectionId.init(&data);
    }

    pub fn asSlice(self: *const ConnectionId) []const u8 {
        return self.data[0..self.len];
    }
};

// Session ticket for 0-RTT resumption
pub const SessionTicket = struct {
    ticket_data: []u8,
    early_data_limit: u32,
    creation_time: i64,
    max_early_data_size: u32,
    alpn_protocol: []const u8,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, ticket_data: []const u8, early_data_limit: u32) !SessionTicket {
        const owned_ticket = try allocator.dupe(u8, ticket_data);
        const owned_alpn = try allocator.dupe(u8, "h3"); // HTTP/3 for gRPC

        const ts = std.posix.clock_gettime(std.posix.CLOCK.REALTIME) catch unreachable;
        const creation_time: i64 = @intCast(ts.sec);
        return SessionTicket{
            .ticket_data = owned_ticket,
            .early_data_limit = early_data_limit,
            .creation_time = creation_time,
            .max_early_data_size = early_data_limit,
            .alpn_protocol = owned_alpn,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *SessionTicket) void {
        self.allocator.free(self.ticket_data);
        self.allocator.free(self.alpn_protocol);
    }

    pub fn isValid(self: *const SessionTicket) bool {
        const ts = std.posix.clock_gettime(std.posix.CLOCK.REALTIME) catch unreachable;
        const current_time: i64 = @intCast(ts.sec);
        const max_age = 7 * 24 * 60 * 60; // 7 days in seconds
        return (current_time - self.creation_time) < max_age;
    }
};

// Transport parameters for 0-RTT
pub const TransportParameters = struct {
    max_data: u64,
    max_stream_data_bidi_local: u64,
    max_stream_data_bidi_remote: u64,
    max_stream_data_uni: u64,
    max_streams_bidi: u64,
    max_streams_uni: u64,
    idle_timeout: u64,
    max_udp_payload_size: u64,

    pub fn default() TransportParameters {
        return TransportParameters{
            .max_data = INITIAL_MAX_DATA,
            .max_stream_data_bidi_local = INITIAL_MAX_STREAM_DATA,
            .max_stream_data_bidi_remote = INITIAL_MAX_STREAM_DATA,
            .max_stream_data_uni = INITIAL_MAX_STREAM_DATA,
            .max_streams_bidi = INITIAL_MAX_STREAMS,
            .max_streams_uni = INITIAL_MAX_STREAMS,
            .idle_timeout = 30000, // 30 seconds
            .max_udp_payload_size = 1200,
        };
    }
};

// 0-RTT early data context
pub const EarlyDataContext = struct {
    session_ticket: ?SessionTicket,
    transport_params: TransportParameters,
    early_data_sent: u32,
    early_data_accepted: bool,

    pub fn init() EarlyDataContext {
        return EarlyDataContext{
            .session_ticket = null,
            .transport_params = TransportParameters.default(),
            .early_data_sent = 0,
            .early_data_accepted = false,
        };
    }

    pub fn deinit(self: *EarlyDataContext) void {
        if (self.session_ticket) |*ticket| {
            ticket.deinit();
        }
    }

    pub fn canSendEarlyData(self: *const EarlyDataContext, data_size: u32) bool {
        if (self.session_ticket == null) return false;
        const ticket = self.session_ticket.?;
        return ticket.isValid() and
               (self.early_data_sent + data_size) <= ticket.early_data_limit;
    }
};

// Connection migration context
pub const MigrationContext = struct {
    active_paths: std.ArrayList(NetworkPath),
    primary_path: ?*NetworkPath,
    probing_paths: std.AutoHashMap(u64, *NetworkPath),
    path_validation_in_progress: bool,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) MigrationContext {
        return MigrationContext{
            .active_paths = std.ArrayList(NetworkPath){},
            .primary_path = null,
            .probing_paths = std.AutoHashMap(u64, *NetworkPath).init(allocator),
            .path_validation_in_progress = false,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *MigrationContext) void {
        for (self.active_paths.items) |*path| {
            path.deinit();
        }
        self.active_paths.deinit(self.allocator);

        var path_iter = self.probing_paths.iterator();
        while (path_iter.next()) |entry| {
            entry.value_ptr.*.deinit();
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.probing_paths.deinit();
    }
};

// Network path for connection migration
pub const NetworkPath = struct {
    local_address: std.Io.net.IpAddress,
    peer_address: std.Io.net.IpAddress,
    path_id: u64,
    rtt: u64, // Round-trip time in microseconds
    mtu: u32, // Maximum transmission unit
    validated: bool,
    last_validation: i64,
    challenge_data: ?[8]u8,

    pub fn init(local: std.Io.net.IpAddress, peer: std.Io.net.IpAddress, path_id: u64) NetworkPath {
        return NetworkPath{
            .local_address = local,
            .peer_address = peer,
            .path_id = path_id,
            .rtt = 0,
            .mtu = 1200, // Conservative default
            .validated = false,
            .last_validation = 0,
            .challenge_data = null,
        };
    }

    pub fn deinit(self: *NetworkPath) void {
        _ = self; // Nothing to deallocate for now
    }

    pub fn needsValidation(self: *const NetworkPath) bool {
        const ts = std.posix.clock_gettime(std.posix.CLOCK.REALTIME) catch unreachable;
        const current_time: i64 = @intCast(ts.sec);
        const validation_timeout = 60; // 1 minute
        return !self.validated or
               (current_time - self.last_validation) > validation_timeout;
    }

    pub fn startValidation(self: *NetworkPath) void {
        var rng = std.crypto.random;
        var challenge: [8]u8 = undefined;
        rng.bytes(&challenge);
        self.challenge_data = challenge;
        const ts = std.posix.clock_gettime(std.posix.CLOCK.REALTIME) catch unreachable;
        self.last_validation = @intCast(ts.sec);
    }
};

pub const QuicPacket = struct {
    header: PacketHeader,
    payload: []const u8,
    allocator: std.mem.Allocator,

    pub const PacketHeader = struct {
        packet_type: PacketType,
        version: u32,
        dest_connection_id: ConnectionId,
        source_connection_id: ConnectionId,
        packet_number: u64,
        payload_length: u32,
    };

    pub fn init(allocator: std.mem.Allocator, header: PacketHeader, payload: []const u8) !QuicPacket {
        const owned_payload = try allocator.dupe(u8, payload);
        return QuicPacket{
            .header = header,
            .payload = owned_payload,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *QuicPacket) void {
        self.allocator.free(self.payload);
    }

    pub fn encode(self: *const QuicPacket, allocator: std.mem.Allocator) ![]u8 {
        var buffer = std.ArrayList(u8){};
        defer buffer.deinit(allocator);

        // Form byte (packet type + version flag)
        const form_byte: u8 = 0x80 | (@intFromEnum(self.header.packet_type) << 4);
        try buffer.append(allocator,form_byte);

        // Version (for long header packets)
        if (self.header.packet_type != .one_rtt) {
            const version_bytes = std.mem.toBytes(std.mem.nativeToBig(u32, self.header.version));
            try buffer.appendSlice(allocator,&version_bytes);
        }

        // Destination Connection ID
        try buffer.append(allocator,self.header.dest_connection_id.len);
        try buffer.appendSlice(allocator,self.header.dest_connection_id.asSlice());

        // Source Connection ID
        try buffer.append(allocator,self.header.source_connection_id.len);
        try buffer.appendSlice(allocator,self.header.source_connection_id.asSlice());

        // Packet number (simplified encoding)
        const pn_bytes = std.mem.toBytes(std.mem.nativeToBig(u64, self.header.packet_number));
        try buffer.appendSlice(allocator,&pn_bytes);

        // Payload
        try buffer.appendSlice(allocator,self.payload);

        return try buffer.toOwnedSlice(allocator);
    }
};

pub const QuicFrame = struct {
    frame_type: FrameType,
    data: []const u8,
    allocator: std.mem.Allocator,

    // Stream frame specific fields
    stream_id: ?u64 = null,
    offset: ?u64 = null,
    fin: bool = false,

    pub fn initStream(allocator: std.mem.Allocator, stream_id: u64, offset: u64, data: []const u8, fin: bool) !QuicFrame {
        const owned_data = try allocator.dupe(u8, data);
        return QuicFrame{
            .frame_type = .stream,
            .data = owned_data,
            .allocator = allocator,
            .stream_id = stream_id,
            .offset = offset,
            .fin = fin,
        };
    }

    pub fn initCrypto(allocator: std.mem.Allocator, offset: u64, data: []const u8) !QuicFrame {
        const owned_data = try allocator.dupe(u8, data);
        return QuicFrame{
            .frame_type = .crypto,
            .data = owned_data,
            .allocator = allocator,
            .offset = offset,
        };
    }

    pub fn initPathChallenge(allocator: std.mem.Allocator, challenge_data: [8]u8) !QuicFrame {
        const owned_data = try allocator.dupe(u8, &challenge_data);
        return QuicFrame{
            .frame_type = .path_challenge,
            .data = owned_data,
            .allocator = allocator,
        };
    }

    pub fn initPathResponse(allocator: std.mem.Allocator, response_data: [8]u8) !QuicFrame {
        const owned_data = try allocator.dupe(u8, &response_data);
        return QuicFrame{
            .frame_type = .path_response,
            .data = owned_data,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *QuicFrame) void {
        self.allocator.free(self.data);
    }

    pub fn encode(self: *const QuicFrame, allocator: std.mem.Allocator) ![]u8 {
        var buffer = std.ArrayList(u8){};
        defer buffer.deinit(allocator);

        // Frame type
        try buffer.append(allocator,@intFromEnum(self.frame_type));

        switch (self.frame_type) {
            .stream => {
                // Stream ID (variable-length integer)
                try encodeVarInt(allocator, &buffer, self.stream_id.?);
                // Offset (variable-length integer)
                try encodeVarInt(allocator, &buffer, self.offset.?);
                // Length (variable-length integer)
                try encodeVarInt(allocator, &buffer, self.data.len);
                // Data
                try buffer.appendSlice(allocator,self.data);
            },
            .crypto => {
                // Offset (variable-length integer)
                try encodeVarInt(allocator, &buffer, self.offset.?);
                // Length (variable-length integer)
                try encodeVarInt(allocator, &buffer, self.data.len);
                // Data
                try buffer.appendSlice(allocator,self.data);
            },
            .ping => {
                // Ping frame has no additional data
            },
            .padding => {
                // Padding frame data
                try buffer.appendSlice(allocator,self.data);
            },
            .path_challenge => {
                // PATH_CHALLENGE: 8 bytes of challenge data
                try buffer.appendSlice(allocator,self.data);
            },
            .path_response => {
                // PATH_RESPONSE: 8 bytes of response data
                try buffer.appendSlice(allocator,self.data);
            },
            else => {
                // Other frame types - just append data for now
                try buffer.appendSlice(allocator,self.data);
            },
        }

        return try buffer.toOwnedSlice(allocator);
    }
};

// Variable-length integer encoding (RFC 9000 Section 16)
fn encodeVarInt(allocator: std.mem.Allocator, buffer: *std.ArrayList(u8), value: u64) !void {
    if (value < 64) {
        try buffer.append(allocator,@intCast(value));
    } else if (value < 16384) {
        const bytes = std.mem.toBytes(std.mem.nativeToBig(u16, @intCast(value)));
        try buffer.append(allocator,bytes[0] | 0x40);
        try buffer.append(allocator,bytes[1]);
    } else if (value < 1073741824) {
        const bytes = std.mem.toBytes(std.mem.nativeToBig(u32, @intCast(value)));
        try buffer.append(allocator,bytes[0] | 0x80);
        try buffer.appendSlice(allocator,bytes[1..]);
    } else {
        const bytes = std.mem.toBytes(std.mem.nativeToBig(u64, value));
        try buffer.append(allocator,bytes[0] | 0xc0);
        try buffer.appendSlice(allocator,bytes[1..]);
    }
}

fn decodeVarInt(data: []const u8, pos: *usize) !u64 {
    if (pos.* >= data.len) return Error.InvalidData;

    const first_byte = data[pos.*];
    pos.* += 1;

    const length = @as(u8, 1) << (first_byte >> 6);
    const value_mask: u8 = 0x3f;

    if (pos.* + length - 1 > data.len) return Error.InvalidData;

    var value: u64 = first_byte & value_mask;
    for (1..length) |i| {
        value = (value << 8) | data[pos.* + i - 1];
    }
    pos.* += length - 1;

    return value;
}

pub const QuicStream = struct {
    id: u64,
    state: StreamState,
    send_offset: u64,
    recv_offset: u64,
    send_buffer: std.ArrayList(u8),
    recv_buffer: std.ArrayList(u8),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, stream_id: u64) QuicStream {
        return QuicStream{
            .id = stream_id,
            .state = .idle,
            .send_offset = 0,
            .recv_offset = 0,
            .send_buffer = std.ArrayList(u8){},
            .recv_buffer = std.ArrayList(u8){},
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *QuicStream) void {
        self.send_buffer.deinit(self.allocator);
        self.recv_buffer.deinit(self.allocator);
    }

    pub fn write(self: *QuicStream, data: []const u8) !void {
        try self.send_buffer.appendSlice(self.allocator, data);
        self.state = .open;
    }

    pub fn read(self: *QuicStream, buffer: []u8) !usize {
        const available = std.math.min(buffer.len, self.recv_buffer.items.len);
        if (available == 0) return 0;

        @memcpy(buffer[0..available], self.recv_buffer.items[0..available]);

        // Remove read data from buffer
        const remaining = self.recv_buffer.items.len - available;
        if (remaining > 0) {
            std.mem.copyForwards(u8, self.recv_buffer.items[0..remaining], self.recv_buffer.items[available..]);
        }
        self.recv_buffer.shrinkAndFree(remaining);

        return available;
    }

    pub fn finish(self: *QuicStream) void {
        switch (self.state) {
            .open => self.state = .half_closed_local,
            .half_closed_remote => self.state = .closed,
            else => {},
        }
    }

    pub fn isWritable(self: *const QuicStream) bool {
        return self.state == .idle or self.state == .open or self.state == .half_closed_remote;
    }

    pub fn isReadable(self: *const QuicStream) bool {
        return self.state == .open or self.state == .half_closed_local;
    }
};

// Advanced connection management with 0-RTT and migration
pub const QuicConnection = struct {
    allocator: std.mem.Allocator,
    state: ConnectionState,
    local_connection_id: ConnectionId,
    peer_connection_id: ConnectionId,
    streams: std.AutoHashMap(u64, *QuicStream),
    next_stream_id: u64,
    socket: std.Io.net.Stream,
    peer_address: std.Io.net.IpAddress,
    is_server: bool,

    // Advanced features
    early_data_context: EarlyDataContext,
    migration_context: MigrationContext,
    transport_params: TransportParameters,

    // 0-RTT state
    zero_rtt_keys: ?[]u8,
    session_resumption_ticket: ?[]u8,

    // Connection migration
    current_path_id: u64,
    path_validation_tokens: std.AutoHashMap(u64, [8]u8),

    pub fn initClient(allocator: std.mem.Allocator, peer_address: std.Io.net.IpAddress) !QuicConnection {
        var io_threaded = std.Io.Threaded.init_single_threaded;
        const io = io_threaded.io();
        const socket = try peer_address.connect(io, .{});

        return QuicConnection{
            .allocator = allocator,
            .state = .initial,
            .local_connection_id = try ConnectionId.random(allocator),
            .peer_connection_id = try ConnectionId.random(allocator),
            .streams = std.AutoHashMap(u64, *QuicStream).init(allocator),
            .next_stream_id = 0, // Client-initiated streams start at 0
            .socket = socket,
            .peer_address = peer_address,
            .is_server = false,

            // Initialize advanced features
            .early_data_context = EarlyDataContext.init(),
            .migration_context = MigrationContext.init(allocator),
            .transport_params = TransportParameters.default(),
            .zero_rtt_keys = null,
            .session_resumption_ticket = null,
            .current_path_id = 0,
            .path_validation_tokens = std.AutoHashMap(u64, [8]u8).init(allocator),
        };
    }

    pub fn initServer(allocator: std.mem.Allocator, socket: std.Io.net.Stream, peer_address: std.Io.net.IpAddress) !QuicConnection {
        return QuicConnection{
            .allocator = allocator,
            .state = .initial,
            .local_connection_id = try ConnectionId.random(allocator),
            .peer_connection_id = try ConnectionId.random(allocator),
            .streams = std.AutoHashMap(u64, *QuicStream).init(allocator),
            .next_stream_id = 1, // Server-initiated streams start at 1
            .socket = socket,
            .peer_address = peer_address,
            .is_server = true,

            // Initialize advanced features
            .early_data_context = EarlyDataContext.init(),
            .migration_context = MigrationContext.init(allocator),
            .transport_params = TransportParameters.default(),
            .zero_rtt_keys = null,
            .session_resumption_ticket = null,
            .current_path_id = 0,
            .path_validation_tokens = std.AutoHashMap(u64, [8]u8).init(allocator),
        };
    }

    pub fn deinit(self: *QuicConnection) void {
        // Clean up streams
        var stream_iter = self.streams.iterator();
        while (stream_iter.next()) |entry| {
            entry.value_ptr.*.deinit();
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.streams.deinit();

        // Clean up advanced features
        self.early_data_context.deinit();
        self.migration_context.deinit();
        self.path_validation_tokens.deinit();

        if (self.zero_rtt_keys) |keys| {
            self.allocator.free(keys);
        }
        if (self.session_resumption_ticket) |ticket| {
            self.allocator.free(ticket);
        }

        self.socket.close();
    }

    pub fn createStream(self: *QuicConnection) !*QuicStream {
        const stream_id = self.next_stream_id;
        self.next_stream_id += 4; // Client uses 0,4,8... Server uses 1,5,9...

        const stream = try self.allocator.create(QuicStream);
        stream.* = QuicStream.init(self.allocator, stream_id);

        try self.streams.put(stream_id, stream);
        return stream;
    }

    pub fn getStream(self: *QuicConnection, stream_id: u64) ?*QuicStream {
        return self.streams.get(stream_id);
    }

    pub fn sendPacket(self: *QuicConnection, packet: *const QuicPacket) !void {
        const encoded = try packet.encode(self.allocator);
        defer self.allocator.free(encoded);

        _ = try self.socket.write(encoded);
    }

    pub fn receivePacket(self: *QuicConnection) !QuicPacket {
        var buffer: [2048]u8 = undefined;
        const bytes_read = try self.socket.read(&buffer);

        // Simplified packet parsing - in real implementation would need proper parsing
        if (bytes_read < 16) return Error.InvalidData;

        const header = QuicPacket.PacketHeader{
            .packet_type = .one_rtt, // Simplified
            .version = QUIC_VERSION_1,
            .dest_connection_id = self.local_connection_id,
            .source_connection_id = self.peer_connection_id,
            .packet_number = 1, // Would need proper packet number tracking
            .payload_length = @intCast(bytes_read - 16),
        };

        return try QuicPacket.init(self.allocator, header, buffer[16..bytes_read]);
    }

    pub fn handshake(self: *QuicConnection) !void {
        if (self.state != .initial) return Error.InvalidState;

        if (!self.is_server) {
            // Client sends Initial packet
            const crypto_data = "CLIENT_HELLO"; // Simplified TLS handshake
            var crypto_frame = try QuicFrame.initCrypto(self.allocator, 0, crypto_data);
            defer crypto_frame.deinit();

            const frame_data = try crypto_frame.encode(self.allocator);
            defer self.allocator.free(frame_data);

            const header = QuicPacket.PacketHeader{
                .packet_type = .initial,
                .version = QUIC_VERSION_1,
                .dest_connection_id = self.peer_connection_id,
                .source_connection_id = self.local_connection_id,
                .packet_number = 0,
                .payload_length = @intCast(frame_data.len),
            };

            var packet = try QuicPacket.init(self.allocator, header, frame_data);
            defer packet.deinit();

            try self.sendPacket(&packet);
        }

        self.state = .handshake;

        // Simplified handshake completion
        self.state = .established;
    }

    // 0-RTT connection resumption methods
    pub fn enable0Rtt(self: *QuicConnection, session_ticket: SessionTicket) !void {
        if (self.is_server) return Error.InvalidState;

        self.early_data_context.session_ticket = session_ticket;
        self.state = .zero_rtt_attempt;
    }

    pub fn send0RttData(self: *QuicConnection, data: []const u8) !bool {
        if (self.state != .zero_rtt_attempt) return false;
        if (!self.early_data_context.canSendEarlyData(@intCast(data.len))) return false;

        // Create 0-RTT data frame
        const stream = try self.createStream();
        try stream.write(data);

        self.early_data_context.early_data_sent += @intCast(data.len);
        return true;
    }

    pub fn confirm0RttAccepted(self: *QuicConnection) void {
        if (self.state == .zero_rtt_attempt) {
            self.early_data_context.early_data_accepted = true;
            self.state = .zero_rtt_established;
        }
    }

    // Connection migration methods
    pub fn startPathMigration(self: *QuicConnection, new_address: std.Io.net.IpAddress) !void {
        const path_id = self.current_path_id + 1;
        const local_addr = std.Io.net.IpAddress{ .ip4 = std.Io.net.Ip4Address.unspecified(0) };
        const new_path = NetworkPath.init(
            local_addr, // Local will be assigned by OS
            new_address,
            path_id
        );

        try self.migration_context.active_paths.append(self.allocator, new_path);
        try self.validatePath(path_id);
    }

    pub fn validatePath(self: *QuicConnection, path_id: u64) !void {
        // Find the path in active paths
        for (self.migration_context.active_paths.items) |*path| {
            if (path.path_id == path_id) {
                if (path.needsValidation()) {
                    path.startValidation();

                    // Send PATH_CHALLENGE frame
                    if (path.challenge_data) |challenge| {
                        try self.sendPathChallenge(challenge);
                        try self.path_validation_tokens.put(path_id, challenge);
                    }
                }
                break;
            }
        }
    }

    pub fn sendPathChallenge(self: *QuicConnection, challenge_data: [8]u8) !void {
        var challenge_frame = try QuicFrame.initPathChallenge(self.allocator, challenge_data);
        defer challenge_frame.deinit();

        const frame_data = try challenge_frame.encode(self.allocator);
        defer self.allocator.free(frame_data);

        const header = QuicPacket.PacketHeader{
            .packet_type = .one_rtt,
            .version = QUIC_VERSION_1,
            .dest_connection_id = self.peer_connection_id,
            .source_connection_id = self.local_connection_id,
            .packet_number = 1,
            .payload_length = @intCast(frame_data.len),
        };

        var packet = try QuicPacket.init(self.allocator, header, frame_data);
        defer packet.deinit();

        try self.sendPacket(&packet);
    }

    pub fn handlePathResponse(self: *QuicConnection, response_data: [8]u8) !void {
        // Validate the response matches our challenge
        const path_iter = self.migration_context.active_paths.items;
        for (path_iter) |*path| {
            if (path.challenge_data) |challenge| {
                if (std.mem.eql(u8, &challenge, &response_data)) {
                    path.validated = true;
                    const ts = std.posix.clock_gettime(std.posix.CLOCK.REALTIME) catch unreachable;
                    path.last_validation = @intCast(ts.sec);

                    // If this was the primary path, migration is complete
                    if (self.migration_context.primary_path == path) {
                        self.current_path_id = path.path_id;
                    }
                    break;
                }
            }
        }
    }

    pub fn switchToPrimaryPath(self: *QuicConnection, path_id: u64) !void {
        for (self.migration_context.active_paths.items) |*path| {
            if (path.path_id == path_id and path.validated) {
                self.migration_context.primary_path = path;
                self.current_path_id = path_id;

                // Update peer address for future packets
                self.peer_address = path.peer_address;
                break;
            }
        }
    }

    // Connection multiplexing support
    pub fn isMultiplexingCapable(self: *const QuicConnection) bool {
        return self.state == .established or self.state == .zero_rtt_established;
    }

    pub fn getActivePathCount(self: *const QuicConnection) usize {
        return self.migration_context.active_paths.items.len;
    }

    pub fn getBestPath(self: *const QuicConnection) ?*const NetworkPath {
        var best_path: ?*const NetworkPath = null;
        var best_rtt: u64 = std.math.maxInt(u64);

        for (self.migration_context.active_paths.items) |*path| {
            if (path.validated and path.rtt < best_rtt) {
                best_path = path;
                best_rtt = path.rtt;
            }
        }

        return best_path;
    }
};

// Tests
test "connection id creation" {
    const data = "test_conn_id";
    const cid = ConnectionId.init(data);
    try std.testing.expectEqual(@as(u8, data.len), cid.len);
    try std.testing.expectEqualStrings(data, cid.asSlice());
}

test "variable length integer encoding" {
    var buffer = std.ArrayList(u8){};
    defer buffer.deinit(std.testing.allocator);

    try encodeVarInt(std.testing.allocator, &buffer, 42);
    try std.testing.expectEqual(@as(usize, 1), buffer.items.len);
    try std.testing.expectEqual(@as(u8, 42), buffer.items[0]);
}

test "quic stream operations" {
    var stream = QuicStream.init(std.testing.allocator, 0);
    defer stream.deinit();

    try stream.write("hello world");
    try std.testing.expectEqual(StreamState.open, stream.state);

    stream.finish();
    try std.testing.expectEqual(StreamState.half_closed_local, stream.state);
}

test "quic frame encoding" {
    const data = "test frame data";
    var frame = try QuicFrame.initStream(std.testing.allocator, 4, 0, data, false);
    defer frame.deinit();

    const encoded = try frame.encode(std.testing.allocator);
    defer std.testing.allocator.free(encoded);

    try std.testing.expect(encoded.len > data.len); // Should include headers
}

test "0-RTT session ticket" {
    const ticket_data = "session_ticket_12345";
    var ticket = try SessionTicket.init(std.testing.allocator, ticket_data, 1024);
    defer ticket.deinit();

    try std.testing.expect(ticket.isValid());
    try std.testing.expectEqual(@as(u32, 1024), ticket.early_data_limit);
    try std.testing.expectEqualStrings("h3", ticket.alpn_protocol);
}

test "early data context" {
    var context = EarlyDataContext.init();
    defer context.deinit();

    // No session ticket - should not allow early data
    try std.testing.expect(!context.canSendEarlyData(100));

    // Add session ticket
    const ticket_data = "test_ticket";
    context.session_ticket = try SessionTicket.init(std.testing.allocator, ticket_data, 2048);

    // Should allow early data within limit
    try std.testing.expect(context.canSendEarlyData(1000));
    try std.testing.expect(!context.canSendEarlyData(3000));
}

test "path challenge and response frames" {
    const challenge_data = [8]u8{ 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08 };

    var challenge_frame = try QuicFrame.initPathChallenge(std.testing.allocator, challenge_data);
    defer challenge_frame.deinit();

    try std.testing.expectEqual(FrameType.path_challenge, challenge_frame.frame_type);
    try std.testing.expectEqualSlices(u8, &challenge_data, challenge_frame.data);

    var response_frame = try QuicFrame.initPathResponse(std.testing.allocator, challenge_data);
    defer response_frame.deinit();

    try std.testing.expectEqual(FrameType.path_response, response_frame.frame_type);
    try std.testing.expectEqualSlices(u8, &challenge_data, response_frame.data);
}

test "connection migration" {
    const local_addr = std.Io.net.IpAddress{ .ip4 = .{ .bytes = [4]u8{ 127, 0, 0, 1 }, .port = 8080 } };
    const peer_addr = std.Io.net.IpAddress{ .ip4 = .{ .bytes = [4]u8{ 127, 0, 0, 1 }, .port = 8081 } };

    var path = NetworkPath.init(local_addr, peer_addr, 1);
    defer path.deinit();

    try std.testing.expect(path.needsValidation());
    try std.testing.expect(!path.validated);

    path.startValidation();
    try std.testing.expect(path.challenge_data != null);
}