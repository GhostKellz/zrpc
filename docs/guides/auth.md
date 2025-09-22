# Authentication Guide

zRPC provides comprehensive authentication support through JWT tokens and OAuth2 integration. This guide covers secure authentication patterns for RPC services.

## Overview

zRPC supports multiple authentication mechanisms:

- **JWT (JSON Web Tokens)** - Stateless token-based authentication
- **OAuth2** - Industry standard authorization framework
- **Custom Middleware** - Extensible authentication pipeline
- **TLS Client Certificates** - Mutual TLS authentication

## JWT Authentication

### JWT Structure

A JWT consists of three parts: Header, Payload, and Signature.

```zig
const jwt_header = zrpc.auth.JwtHeader{
    .alg = "HS256", // HMAC SHA-256
    .typ = "JWT",
    .kid = "key-id-1", // Optional key ID
};

const jwt_payload = zrpc.auth.JwtPayload{
    .iss = "https://auth.example.com", // Issuer
    .sub = "user123", // Subject
    .aud = "api.example.com", // Audience
    .exp = std.time.timestamp() + 3600, // Expires in 1 hour
    .iat = std.time.timestamp(), // Issued at
    .jti = "token-id-123", // JWT ID
};
```

### Creating JWT Tokens

```zig
const std = @import("std");
const zrpc = @import("zrpc");

pub fn createJwtToken(allocator: std.mem.Allocator, user_id: []const u8, secret: []const u8) ![]u8 {
    // Create header
    const header = zrpc.auth.JwtHeader{
        .alg = "HS256",
        .typ = "JWT",
    };

    // Create payload
    const now = std.time.timestamp();
    const payload = zrpc.auth.JwtPayload{
        .iss = "zrpc-service",
        .sub = user_id,
        .aud = "zrpc-api",
        .exp = now + 3600, // 1 hour
        .iat = now,
        .nbf = now, // Not valid before now
    };

    // Create and sign token
    var token = try zrpc.auth.JwtToken.init(allocator, header, payload);
    defer token.deinit();

    return try token.sign(secret);
}
```

### Validating JWT Tokens

```zig
pub fn validateJwtToken(allocator: std.mem.Allocator, token_string: []const u8, secret: []const u8) !zrpc.auth.JwtPayload {
    // Parse token
    var token = try zrpc.auth.JwtToken.parse(allocator, token_string);
    defer token.deinit();

    // Verify signature
    const is_valid = try token.verify(secret);
    if (!is_valid) {
        return zrpc.Error.Unauthorized;
    }

    // Check expiration
    const now = std.time.timestamp();
    if (token.payload.exp <= now) {
        return zrpc.Error.TokenExpired;
    }

    // Check not-before time
    if (token.payload.nbf > now) {
        return zrpc.Error.TokenNotYetValid;
    }

    return token.payload;
}
```

### JWT Middleware

Create authentication middleware for your server:

```zig
const JwtAuthMiddleware = struct {
    secret: []const u8,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, secret: []const u8) JwtAuthMiddleware {
        return JwtAuthMiddleware{
            .secret = secret,
            .allocator = allocator,
        };
    }

    pub fn authenticate(self: *JwtAuthMiddleware, context: *zrpc.CallContext) !void {
        // Extract authorization header
        const auth_header = context.metadata.get("authorization") orelse {
            return zrpc.Error.Unauthorized;
        };

        // Check Bearer token format
        if (!std.mem.startsWith(u8, auth_header, "Bearer ")) {
            return zrpc.Error.InvalidToken;
        }

        const token = auth_header[7..]; // Skip "Bearer "

        // Validate token
        const payload = validateJwtToken(self.allocator, token, self.secret) catch {
            return zrpc.Error.Unauthorized;
        };

        // Add user info to context
        try context.addMetadata("user_id", payload.sub);
        try context.addMetadata("token_issued_at", try std.fmt.allocPrint(self.allocator, "{}", .{payload.iat}));
    }
};
```

## OAuth2 Integration

### OAuth2 Token Types

```zig
pub const OAuth2Token = struct {
    access_token: []const u8,
    token_type: []const u8,
    expires_in: i64,
    refresh_token: ?[]const u8,
    scope: ?[]const u8,

    pub fn isExpired(self: OAuth2Token) bool {
        // Implementation depends on how you track token creation time
        return false; // Placeholder
    }

    pub fn needsRefresh(self: OAuth2Token) bool {
        // Refresh if token expires in less than 5 minutes
        return self.expires_in < 300;
    }
};
```

### Authorization Code Flow

```zig
const OAuth2Client = struct {
    client_id: []const u8,
    client_secret: []const u8,
    redirect_uri: []const u8,
    auth_url: []const u8,
    token_url: []const u8,
    allocator: std.mem.Allocator,

    pub fn getAuthorizationUrl(self: OAuth2Client, state: []const u8, scopes: []const []const u8) ![]u8 {
        const scope_string = try std.mem.join(self.allocator, " ", scopes);
        defer self.allocator.free(scope_string);

        return try std.fmt.allocPrint(self.allocator,
            "{s}?response_type=code&client_id={s}&redirect_uri={s}&scope={s}&state={s}",
            .{ self.auth_url, self.client_id, self.redirect_uri, scope_string, state }
        );
    }

    pub fn exchangeCodeForToken(self: OAuth2Client, code: []const u8) !OAuth2Token {
        // HTTP POST to token endpoint
        const form_data = try std.fmt.allocPrint(self.allocator,
            "grant_type=authorization_code&client_id={s}&client_secret={s}&code={s}&redirect_uri={s}",
            .{ self.client_id, self.client_secret, code, self.redirect_uri }
        );
        defer self.allocator.free(form_data);

        // Make HTTP request and parse response
        // This is a simplified example - use actual HTTP client
        return OAuth2Token{
            .access_token = "example_access_token",
            .token_type = "Bearer",
            .expires_in = 3600,
            .refresh_token = "example_refresh_token",
            .scope = "read write",
        };
    }

    pub fn refreshToken(self: OAuth2Client, refresh_token: []const u8) !OAuth2Token {
        const form_data = try std.fmt.allocPrint(self.allocator,
            "grant_type=refresh_token&client_id={s}&client_secret={s}&refresh_token={s}",
            .{ self.client_id, self.client_secret, refresh_token }
        );
        defer self.allocator.free(form_data);

        // Make HTTP request and parse response
        return OAuth2Token{
            .access_token = "new_access_token",
            .token_type = "Bearer",
            .expires_in = 3600,
            .refresh_token = refresh_token, // May be same or new
            .scope = "read write",
        };
    }
};
```

### Client Credentials Flow

For service-to-service authentication:

```zig
pub fn getServiceToken(client: OAuth2Client, scopes: []const []const u8) !OAuth2Token {
    const scope_string = try std.mem.join(client.allocator, " ", scopes);
    defer client.allocator.free(scope_string);

    const form_data = try std.fmt.allocPrint(client.allocator,
        "grant_type=client_credentials&client_id={s}&client_secret={s}&scope={s}",
        .{ client.client_id, client.client_secret, scope_string }
    );
    defer client.allocator.free(form_data);

    // Make HTTP request to token endpoint
    return OAuth2Token{
        .access_token = "service_access_token",
        .token_type = "Bearer",
        .expires_in = 7200, // 2 hours
        .refresh_token = null, // Not applicable for client credentials
        .scope = scope_string,
    };
}
```

## Authentication Middleware

### Custom Authentication Middleware

```zig
pub const AuthMiddleware = struct {
    jwt_secret: []const u8,
    oauth2_introspection_url: ?[]const u8,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, jwt_secret: []const u8) AuthMiddleware {
        return AuthMiddleware{
            .jwt_secret = jwt_secret,
            .oauth2_introspection_url = null,
            .allocator = allocator,
        };
    }

    pub fn withOAuth2Introspection(self: *AuthMiddleware, url: []const u8) void {
        self.oauth2_introspection_url = url;
    }

    pub fn authenticate(self: *AuthMiddleware, context: *zrpc.CallContext) !void {
        const auth_header = context.metadata.get("authorization") orelse {
            return zrpc.Error.Unauthorized;
        };

        if (std.mem.startsWith(u8, auth_header, "Bearer ")) {
            const token = auth_header[7..];

            // Try JWT first
            if (self.validateJWT(token)) |payload| {
                try self.addUserContext(context, payload);
                return;
            }

            // Try OAuth2 introspection if configured
            if (self.oauth2_introspection_url) |url| {
                if (try self.introspectOAuth2Token(token, url)) |token_info| {
                    try self.addOAuth2Context(context, token_info);
                    return;
                }
            }
        }

        return zrpc.Error.Unauthorized;
    }

    fn validateJWT(self: *AuthMiddleware, token: []const u8) ?zrpc.auth.JwtPayload {
        return validateJwtToken(self.allocator, token, self.jwt_secret) catch null;
    }

    fn introspectOAuth2Token(self: *AuthMiddleware, token: []const u8, introspection_url: []const u8) !?OAuth2TokenInfo {
        // Make HTTP POST to introspection endpoint
        _ = token;
        _ = introspection_url;
        return null; // Placeholder
    }

    fn addUserContext(self: *AuthMiddleware, context: *zrpc.CallContext, payload: zrpc.auth.JwtPayload) !void {
        _ = self;
        try context.addMetadata("auth_type", "jwt");
        try context.addMetadata("user_id", payload.sub);
        try context.addMetadata("issuer", payload.iss);
    }

    fn addOAuth2Context(self: *AuthMiddleware, context: *zrpc.CallContext, token_info: OAuth2TokenInfo) !void {
        _ = self;
        _ = token_info;
        try context.addMetadata("auth_type", "oauth2");
        // Add OAuth2-specific context
    }
};
```

### Server Integration

```zig
pub fn createAuthenticatedServer(allocator: std.mem.Allocator, jwt_secret: []const u8) !zrpc.Server {
    var server = zrpc.Server.init(allocator);

    // Create authentication middleware
    var auth_middleware = AuthMiddleware.init(allocator, jwt_secret);

    // Wrap handlers with authentication
    const authenticated_handler = struct {
        middleware: *AuthMiddleware,
        original_handler: zrpc.MethodHandler,

        fn handle(self: @This(), ctx: *zrpc.CallContext, request: []const u8) zrpc.Error![]u8 {
            // Authenticate first
            try self.middleware.authenticate(ctx);

            // Call original handler if authentication succeeds
            return switch (self.original_handler.call_type) {
                .unary => if (self.original_handler.unary_handler) |h| h(ctx, request) else zrpc.Error.NotImplemented,
                else => zrpc.Error.NotImplemented,
            };
        }
    };

    return server;
}
```

## Client Authentication

### Automatic Token Management

```zig
const AuthenticatedClient = struct {
    client: zrpc.Client,
    token_provider: TokenProvider,
    allocator: std.mem.Allocator,

    const TokenProvider = union(enum) {
        static: []const u8,
        jwt: struct {
            secret: []const u8,
            user_id: []const u8,
        },
        oauth2: OAuth2Client,
    };

    pub fn init(allocator: std.mem.Allocator, endpoint: []const u8, provider: TokenProvider) AuthenticatedClient {
        return AuthenticatedClient{
            .client = zrpc.Client.init(allocator, endpoint),
            .token_provider = provider,
            .allocator = allocator,
        };
    }

    pub fn call(
        self: *AuthenticatedClient,
        comptime service_method: []const u8,
        request: anytype,
        response_type: type,
        context: ?*zrpc.CallContext,
    ) !response_type {
        var call_context = context orelse &zrpc.CallContext.init(self.allocator);
        defer if (context == null) call_context.deinit();

        // Get and add authentication token
        const token = try self.getToken();
        defer self.allocator.free(token);

        try call_context.addMetadata("authorization", token);

        return try self.client.call(service_method, request, response_type, call_context);
    }

    fn getToken(self: *AuthenticatedClient) ![]u8 {
        return switch (self.token_provider) {
            .static => |token| try self.allocator.dupe(u8, token),
            .jwt => |jwt_config| {
                const token = try createJwtToken(self.allocator, jwt_config.user_id, jwt_config.secret);
                return try std.fmt.allocPrint(self.allocator, "Bearer {s}", .{token});
            },
            .oauth2 => |oauth2_client| {
                const oauth_token = try oauth2_client.getServiceToken(&[_][]const u8{"read"});
                return try std.fmt.allocPrint(self.allocator, "Bearer {s}", .{oauth_token.access_token});
            },
        };
    }
};
```

## Security Best Practices

### Token Security

1. **Use Strong Secrets**: JWT secrets should be at least 256 bits
2. **Short Expiration**: Keep token lifetimes short (1-24 hours)
3. **Secure Storage**: Store refresh tokens securely
4. **Rotate Secrets**: Regularly rotate signing keys

```zig
// Generate strong JWT secret
fn generateJwtSecret(allocator: std.mem.Allocator) ![]u8 {
    var secret = try allocator.alloc(u8, 32); // 256 bits
    std.crypto.random.bytes(secret);
    return secret;
}

// Key rotation example
const KeyRotation = struct {
    current_key: []const u8,
    previous_key: ?[]const u8,
    next_rotation: i64,

    pub fn getValidationKeys(self: KeyRotation) [][]const u8 {
        if (self.previous_key) |prev| {
            return &[_][]const u8{ self.current_key, prev };
        } else {
            return &[_][]const u8{self.current_key};
        }
    }

    pub fn shouldRotate(self: KeyRotation) bool {
        return std.time.timestamp() >= self.next_rotation;
    }
};
```

### Transport Security

Always use TLS for authentication:

```zig
const tls_config = zrpc.TlsConfig{
    .cert_file = "server.crt",
    .key_file = "server.key",
    .ca_file = "ca.crt",
    .verify_client = true, // For mutual TLS
    .min_version = .tls_1_3,
};

var secure_server = try zrpc.Server.initWithTls(allocator, tls_config);
```

### Rate Limiting

Implement rate limiting for authentication endpoints:

```zig
const RateLimiter = struct {
    requests: std.HashMap([]const u8, RequestInfo, std.hash_map.StringContext, std.hash_map.default_max_load_percentage),
    allocator: std.mem.Allocator,

    const RequestInfo = struct {
        count: u32,
        window_start: i64,
    };

    pub fn checkLimit(self: *RateLimiter, client_ip: []const u8, limit: u32, window_ms: i64) bool {
        const now = std.time.timestamp();

        if (self.requests.get(client_ip)) |info| {
            if (now - info.window_start < window_ms) {
                return info.count < limit;
            }
        }

        // Reset or create new window
        self.requests.put(client_ip, RequestInfo{
            .count = 1,
            .window_start = now,
        }) catch return false;

        return true;
    }
};
```

## Testing Authentication

### Mock Authentication

```zig
const MockAuthProvider = struct {
    valid_tokens: std.StringHashMap([]const u8),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) MockAuthProvider {
        return MockAuthProvider{
            .valid_tokens = std.StringHashMap([]const u8).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn addValidToken(self: *MockAuthProvider, token: []const u8, user_id: []const u8) !void {
        try self.valid_tokens.put(token, user_id);
    }

    pub fn validateToken(self: *MockAuthProvider, token: []const u8) ?[]const u8 {
        return self.valid_tokens.get(token);
    }
};

// Test with mock authentication
test "authenticated RPC call" {
    var mock_auth = MockAuthProvider.init(std.testing.allocator);
    defer mock_auth.deinit();

    try mock_auth.addValidToken("test-token", "test-user");

    var context = zrpc.CallContext.init(std.testing.allocator);
    defer context.deinit();

    try context.addMetadata("authorization", "Bearer test-token");

    // Test your authenticated handler
}
```

## Common Patterns

### Automatic Token Refresh

```zig
const TokenManager = struct {
    oauth2_client: OAuth2Client,
    current_token: ?OAuth2Token,
    mutex: std.Thread.Mutex,
    allocator: std.mem.Allocator,

    pub fn getValidToken(self: *TokenManager) ![]u8 {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.current_token) |token| {
            if (!token.needsRefresh()) {
                return try self.allocator.dupe(u8, token.access_token);
            }

            // Refresh token
            if (token.refresh_token) |refresh| {
                self.current_token = try self.oauth2_client.refreshToken(refresh);
                return try self.allocator.dupe(u8, self.current_token.?.access_token);
            }
        }

        // Get new token
        self.current_token = try self.oauth2_client.getServiceToken(&[_][]const u8{"api"});
        return try self.allocator.dupe(u8, self.current_token.?.access_token);
    }
};
```

### Session Management

```zig
const SessionManager = struct {
    sessions: std.HashMap([]const u8, Session, std.hash_map.StringContext, std.hash_map.default_max_load_percentage),
    allocator: std.mem.Allocator,

    const Session = struct {
        user_id: []const u8,
        created_at: i64,
        expires_at: i64,
        permissions: std.ArrayList([]const u8),
    };

    pub fn createSession(self: *SessionManager, user_id: []const u8, duration_ms: i64) ![]u8 {
        const session_id = try generateSessionId(self.allocator);
        const now = std.time.timestamp();

        const session = Session{
            .user_id = try self.allocator.dupe(u8, user_id),
            .created_at = now,
            .expires_at = now + duration_ms,
            .permissions = std.ArrayList([]const u8).init(self.allocator),
        };

        try self.sessions.put(session_id, session);
        return session_id;
    }

    pub fn validateSession(self: *SessionManager, session_id: []const u8) ?Session {
        const session = self.sessions.get(session_id) orelse return null;

        if (std.time.timestamp() > session.expires_at) {
            _ = self.sessions.remove(session_id);
            return null;
        }

        return session;
    }
};
```

This comprehensive authentication guide covers JWT, OAuth2, middleware patterns, and security best practices for zRPC applications.