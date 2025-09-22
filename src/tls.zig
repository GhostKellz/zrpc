const std = @import("std");
const Error = @import("error.zig").Error;

pub const TlsVersion = enum {
    tls_1_2,
    tls_1_3,
};

pub const TlsConfig = struct {
    version: TlsVersion,
    ca_cert_path: ?[]const u8,
    cert_path: ?[]const u8,
    key_path: ?[]const u8,
    verify_peer: bool,
    alpn_protocols: []const []const u8,

    pub fn default() TlsConfig {
        return TlsConfig{
            .version = .tls_1_3,
            .ca_cert_path = null,
            .cert_path = null,
            .key_path = null,
            .verify_peer = true,
            .alpn_protocols = &[_][]const u8{"h2"}, // HTTP/2
        };
    }

    pub fn clientDefault() TlsConfig {
        var config = TlsConfig.default();
        config.verify_peer = true;
        return config;
    }

    pub fn serverDefault(cert_path: []const u8, key_path: []const u8) TlsConfig {
        var config = TlsConfig.default();
        config.cert_path = cert_path;
        config.key_path = key_path;
        config.verify_peer = false; // Server doesn't verify client by default
        return config;
    }
};

pub const TlsConnection = struct {
    allocator: std.mem.Allocator,
    underlying_stream: std.net.Stream,
    config: TlsConfig,
    is_client: bool,
    is_handshake_complete: bool,

    pub fn initClient(allocator: std.mem.Allocator, stream: std.net.Stream, config: TlsConfig) TlsConnection {
        return TlsConnection{
            .allocator = allocator,
            .underlying_stream = stream,
            .config = config,
            .is_client = true,
            .is_handshake_complete = false,
        };
    }

    pub fn initServer(allocator: std.mem.Allocator, stream: std.net.Stream, config: TlsConfig) TlsConnection {
        return TlsConnection{
            .allocator = allocator,
            .underlying_stream = stream,
            .config = config,
            .is_client = false,
            .is_handshake_complete = false,
        };
    }

    pub fn handshake(self: *TlsConnection) Error!void {
        if (self.is_handshake_complete) {
            return;
        }

        // Mock TLS handshake implementation
        // In a real implementation, this would:
        // 1. Send ClientHello/ServerHello
        // 2. Exchange certificates
        // 3. Perform key exchange
        // 4. Verify certificates if verify_peer is true
        // 5. Establish encrypted connection

        if (self.config.version != .tls_1_3) {
            return Error.Internal; // Only TLS 1.3 supported
        }

        // Simulate handshake delay
        std.Thread.sleep(1000000); // 1ms

        self.is_handshake_complete = true;
    }

    pub fn read(self: *TlsConnection, buffer: []u8) Error!usize {
        if (!self.is_handshake_complete) {
            return Error.Internal;
        }

        // In a real implementation, this would decrypt the data
        return self.underlying_stream.read(buffer) catch Error.NetworkError;
    }

    pub fn write(self: *TlsConnection, data: []const u8) Error!usize {
        if (!self.is_handshake_complete) {
            return Error.Internal;
        }

        // In a real implementation, this would encrypt the data
        return self.underlying_stream.write(data) catch Error.NetworkError;
    }

    pub fn close(self: *TlsConnection) void {
        // Send close_notify alert
        self.underlying_stream.close();
    }

    pub fn getAlpnProtocol(self: TlsConnection) ?[]const u8 {
        if (!self.is_handshake_complete) {
            return null;
        }

        // Return the negotiated ALPN protocol
        if (self.config.alpn_protocols.len > 0) {
            return self.config.alpn_protocols[0];
        }
        return null;
    }

    pub fn getPeerCertificate(self: TlsConnection) ?[]const u8 {
        if (!self.is_handshake_complete) {
            return null;
        }

        // In a real implementation, this would return the peer's certificate
        return null;
    }
};

pub const TlsTransport = struct {
    allocator: std.mem.Allocator,
    config: TlsConfig,

    pub fn init(allocator: std.mem.Allocator, config: TlsConfig) TlsTransport {
        return TlsTransport{
            .allocator = allocator,
            .config = config,
        };
    }

    pub fn connect(self: *TlsTransport, host: []const u8, port: u16) Error!TlsConnection {
        // Connect to the host
        const address = std.net.Address.resolveIp(host, port) catch return Error.NetworkError;
        const stream = std.net.tcpConnectToAddress(address) catch return Error.NetworkError;

        var tls_conn = TlsConnection.initClient(self.allocator, stream, self.config);
        try tls_conn.handshake();

        // Verify ALPN protocol negotiation for gRPC
        const alpn_protocol = tls_conn.getAlpnProtocol();
        if (alpn_protocol == null or !std.mem.eql(u8, alpn_protocol.?, "h2")) {
            tls_conn.close();
            return Error.TransportError;
        }

        return tls_conn;
    }

    pub fn accept(self: *TlsTransport, stream: std.net.Stream) Error!TlsConnection {
        var tls_conn = TlsConnection.initServer(self.allocator, stream, self.config);
        try tls_conn.handshake();

        // Verify ALPN protocol negotiation for gRPC
        const alpn_protocol = tls_conn.getAlpnProtocol();
        if (alpn_protocol == null or !std.mem.eql(u8, alpn_protocol.?, "h2")) {
            tls_conn.close();
            return Error.TransportError;
        }

        return tls_conn;
    }
};

test "tls config creation" {
    const default_config = TlsConfig.default();
    try std.testing.expectEqual(TlsVersion.tls_1_3, default_config.version);
    try std.testing.expectEqual(true, default_config.verify_peer);
    try std.testing.expectEqualStrings("h2", default_config.alpn_protocols[0]);

    const client_config = TlsConfig.clientDefault();
    try std.testing.expectEqual(true, client_config.verify_peer);

    const server_config = TlsConfig.serverDefault("/path/to/cert.pem", "/path/to/key.pem");
    try std.testing.expectEqual(false, server_config.verify_peer);
    try std.testing.expectEqualStrings("/path/to/cert.pem", server_config.cert_path.?);
    try std.testing.expectEqualStrings("/path/to/key.pem", server_config.key_path.?);
}

test "tls connection handshake" {
    // Mock TCP stream
    const mock_stream = std.net.Stream{ .handle = 0 };
    const config = TlsConfig.clientDefault();

    var tls_conn = TlsConnection.initClient(std.testing.allocator, mock_stream, config);

    try std.testing.expectEqual(false, tls_conn.is_handshake_complete);

    try tls_conn.handshake();

    try std.testing.expectEqual(true, tls_conn.is_handshake_complete);
    try std.testing.expectEqualStrings("h2", tls_conn.getAlpnProtocol().?);
}