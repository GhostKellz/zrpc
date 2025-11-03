//! Token-based authentication for zrpc
//! JWT and OAuth2 support for gRPC services
const std = @import("std");
const Error = @import("error.zig").Error;

fn jsonAppendComma(buffer: *std.ArrayList(u8), allocator: std.mem.Allocator, first: *bool) !void {
    if (first.*) {
        first.* = false;
    } else {
        try buffer.append(allocator, ',');
    }
}

fn jsonAppendEscaped(buffer: *std.ArrayList(u8), allocator: std.mem.Allocator, value: []const u8) !void {
    for (value) |c| {
        switch (c) {
            '"' => try buffer.appendSlice(allocator, "\\\""),
            '\\' => try buffer.appendSlice(allocator, "\\\\"),
            '\n' => try buffer.appendSlice(allocator, "\\n"),
            '\r' => try buffer.appendSlice(allocator, "\\r"),
            '\t' => try buffer.appendSlice(allocator, "\\t"),
            else => try buffer.append(allocator, c),
        }
    }
}

fn jsonAppendStringLiteral(buffer: *std.ArrayList(u8), allocator: std.mem.Allocator, value: []const u8) !void {
    try buffer.append(allocator, '"');
    try jsonAppendEscaped(buffer, allocator, value);
    try buffer.append(allocator, '"');
}

fn jsonAppendStringField(buffer: *std.ArrayList(u8), allocator: std.mem.Allocator, key: []const u8, value: []const u8, first: *bool) !void {
    try jsonAppendComma(buffer, allocator, first);
    try jsonAppendStringLiteral(buffer, allocator, key);
    try buffer.append(allocator, ':');
    try jsonAppendStringLiteral(buffer, allocator, value);
}

fn jsonAppendIntField(buffer: *std.ArrayList(u8), allocator: std.mem.Allocator, key: []const u8, value: i64, first: *bool) !void {
    try jsonAppendComma(buffer, allocator, first);
    try jsonAppendStringLiteral(buffer, allocator, key);
    try buffer.append(allocator, ':');

    var temp: [32]u8 = undefined;
    const written = try std.fmt.bufPrint(temp[0..], "{d}", .{value});
    try buffer.appendSlice(allocator, written);
}

fn jsonAppendStringArrayField(buffer: *std.ArrayList(u8), allocator: std.mem.Allocator, key: []const u8, values: []const []const u8, first: *bool) !void {
    try jsonAppendComma(buffer, allocator, first);
    try jsonAppendStringLiteral(buffer, allocator, key);
    try buffer.append(allocator, ':');
    try buffer.append(allocator, '[');

    var first_value = true;
    for (values) |val| {
        if (!first_value) {
            try buffer.append(allocator, ',');
        } else {
            first_value = false;
        }
        try jsonAppendStringLiteral(buffer, allocator, val);
    }

    try buffer.append(allocator, ']');
}

// JWT Header structure
pub const JwtHeader = struct {
    alg: []const u8, // Algorithm (HS256, RS256, etc.)
    typ: []const u8, // Type (JWT)
    kid: ?[]const u8 = null, // Key ID

    pub fn clone(self: *const JwtHeader, allocator: std.mem.Allocator) !JwtHeader {
        const alg_copy = try allocator.dupe(u8, self.alg);
        errdefer allocator.free(alg_copy);

        const typ_copy = try allocator.dupe(u8, self.typ);
        errdefer allocator.free(typ_copy);

        var kid_copy: ?[]const u8 = null;
        if (self.kid) |kid_value| {
            const cloned = try allocator.dupe(u8, kid_value);
            kid_copy = cloned;
        }

        return JwtHeader{
            .alg = alg_copy,
            .typ = typ_copy,
            .kid = kid_copy,
        };
    }

    pub fn encode(self: *const JwtHeader, allocator: std.mem.Allocator) ![]u8 {
        var json_str: std.ArrayList(u8) = .{};
        defer json_str.deinit(allocator);

        try json_str.append(allocator, '{');
        var first = true;
        try jsonAppendStringField(&json_str, allocator, "alg", self.alg, &first);
        try jsonAppendStringField(&json_str, allocator, "typ", self.typ, &first);
        if (self.kid) |kid| {
            try jsonAppendStringField(&json_str, allocator, "kid", kid, &first);
        }
        try json_str.append(allocator, '}');

        return try base64UrlEncode(allocator, json_str.items);
    }

    pub fn decode(allocator: std.mem.Allocator, encoded: []const u8) !JwtHeader {
        const decoded = try base64UrlDecode(allocator, encoded);
        defer allocator.free(decoded);

        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, decoded, .{});
        defer parsed.deinit();

        const obj = parsed.value.object;
        const alg = try allocator.dupe(u8, obj.get("alg").?.string);
        const typ = try allocator.dupe(u8, obj.get("typ").?.string);

        var kid: ?[]const u8 = null;
        if (obj.get("kid")) |kid_val| {
            kid = try allocator.dupe(u8, kid_val.string);
        }

        return JwtHeader{
            .alg = alg,
            .typ = typ,
            .kid = kid,
        };
    }

    pub fn deinit(self: *JwtHeader, allocator: std.mem.Allocator) void {
        allocator.free(self.alg);
        allocator.free(self.typ);
        if (self.kid) |kid| {
            allocator.free(kid);
        }
    }
};

// JWT Claims structure
pub const JwtClaims = struct {
    iss: ?[]const u8 = null, // Issuer
    sub: ?[]const u8 = null, // Subject
    aud: ?[]const u8 = null, // Audience
    exp: ?i64 = null, // Expiration time
    nbf: ?i64 = null, // Not before
    iat: ?i64 = null, // Issued at
    jti: ?[]const u8 = null, // JWT ID

    // Custom claims
    scope: ?[]const u8 = null,
    permissions: ?[]const []const u8 = null,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) JwtClaims {
        return JwtClaims{
            .allocator = allocator,
        };
    }

    pub fn clone(self: *const JwtClaims) !JwtClaims {
        var cloned = JwtClaims.init(self.allocator);

        if (self.iss) |iss| {
            cloned.iss = try cloned.allocator.dupe(u8, iss);
        }
        if (self.sub) |sub| {
            cloned.sub = try cloned.allocator.dupe(u8, sub);
        }
        if (self.aud) |aud| {
            cloned.aud = try cloned.allocator.dupe(u8, aud);
        }
        if (self.jti) |jti| {
            cloned.jti = try cloned.allocator.dupe(u8, jti);
        }
        if (self.scope) |scope| {
            cloned.scope = try cloned.allocator.dupe(u8, scope);
        }

        if (self.permissions) |perms| {
            var perms_copy = try cloned.allocator.alloc([]const u8, perms.len);
            var assigned: usize = 0;
            errdefer {
                while (assigned > 0) {
                    assigned -= 1;
                    cloned.allocator.free(perms_copy[assigned]);
                }
                cloned.allocator.free(perms_copy);
            }

            var idx: usize = 0;
            while (idx < perms.len) : (idx += 1) {
                perms_copy[idx] = try cloned.allocator.dupe(u8, perms[idx]);
                assigned = idx + 1;
            }
            cloned.permissions = perms_copy;
        }

        cloned.exp = self.exp;
        cloned.nbf = self.nbf;
        cloned.iat = self.iat;

        return cloned;
    }

    pub fn deinit(self: *JwtClaims) void {
        if (self.iss) |iss| self.allocator.free(iss);
        if (self.sub) |sub| self.allocator.free(sub);
        if (self.aud) |aud| self.allocator.free(aud);
        if (self.jti) |jti| self.allocator.free(jti);
        if (self.scope) |scope| self.allocator.free(scope);

        if (self.permissions) |perms| {
            for (perms) |perm| {
                self.allocator.free(perm);
            }
            self.allocator.free(perms);
        }
    }

    pub fn setIssuer(self: *JwtClaims, issuer: []const u8) !void {
        if (self.iss) |old| self.allocator.free(old);
        self.iss = try self.allocator.dupe(u8, issuer);
    }

    pub fn setSubject(self: *JwtClaims, subject: []const u8) !void {
        if (self.sub) |old| self.allocator.free(old);
        self.sub = try self.allocator.dupe(u8, subject);
    }

    pub fn setAudience(self: *JwtClaims, audience: []const u8) !void {
        if (self.aud) |old| self.allocator.free(old);
        self.aud = try self.allocator.dupe(u8, audience);
    }

    pub fn setScope(self: *JwtClaims, scope: []const u8) !void {
        if (self.scope) |old| self.allocator.free(old);
        self.scope = try self.allocator.dupe(u8, scope);
    }

    pub fn setExpiration(self: *JwtClaims, seconds_from_now: i64) void {
        self.exp = std.time.timestamp() + seconds_from_now;
    }

    pub fn setIssuedNow(self: *JwtClaims) void {
        self.iat = std.time.timestamp();
    }

    pub fn isExpired(self: *const JwtClaims) bool {
        if (self.exp) |exp| {
            return std.time.timestamp() > exp;
        }
        return false;
    }

    pub fn isValidNow(self: *const JwtClaims) bool {
        const now = std.time.timestamp();

        if (self.exp) |exp| {
            if (now > exp) return false;
        }

        if (self.nbf) |nbf| {
            if (now < nbf) return false;
        }

        return true;
    }

    pub fn encode(self: *const JwtClaims, allocator: std.mem.Allocator) ![]u8 {
        var json_str: std.ArrayList(u8) = .{};
        defer json_str.deinit(allocator);

        try json_str.append(allocator, '{');
        var first = true;

        if (self.iss) |iss| try jsonAppendStringField(&json_str, allocator, "iss", iss, &first);
        if (self.sub) |sub| try jsonAppendStringField(&json_str, allocator, "sub", sub, &first);
        if (self.aud) |aud| try jsonAppendStringField(&json_str, allocator, "aud", aud, &first);
        if (self.exp) |exp| try jsonAppendIntField(&json_str, allocator, "exp", exp, &first);
        if (self.nbf) |nbf| try jsonAppendIntField(&json_str, allocator, "nbf", nbf, &first);
        if (self.iat) |iat| try jsonAppendIntField(&json_str, allocator, "iat", iat, &first);
        if (self.jti) |jti| try jsonAppendStringField(&json_str, allocator, "jti", jti, &first);
        if (self.scope) |scope| try jsonAppendStringField(&json_str, allocator, "scope", scope, &first);
        if (self.permissions) |perms| try jsonAppendStringArrayField(&json_str, allocator, "permissions", perms, &first);

        try json_str.append(allocator, '}');

        return try base64UrlEncode(allocator, json_str.items);
    }
};

// JWT Token
pub const JwtToken = struct {
    header: JwtHeader,
    claims: JwtClaims,
    signature: []u8,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, header: JwtHeader, claims: JwtClaims) !JwtToken {
        var header_clone = try header.clone(allocator);
        errdefer header_clone.deinit(allocator);

        var claims_clone = try claims.clone();
        errdefer claims_clone.deinit();

        return JwtToken{
            .header = header_clone,
            .claims = claims_clone,
            .signature = &[_]u8{},
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *JwtToken) void {
        self.header.deinit(self.allocator);
        self.claims.deinit();
        self.allocator.free(self.signature);
    }

    pub fn sign(self: *JwtToken, secret: []const u8) !void {
        const header_encoded = try self.header.encode(self.allocator);
        defer self.allocator.free(header_encoded);

        const claims_encoded = try self.claims.encode(self.allocator);
        defer self.allocator.free(claims_encoded);

        // Create signing input: header.claims
        const signing_input = try std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ header_encoded, claims_encoded });
        defer self.allocator.free(signing_input);

        // Sign using HMAC-SHA256 (simplified for HS256)
        if (std.mem.eql(u8, self.header.alg, "HS256")) {
            var hmac = std.crypto.auth.hmac.sha2.HmacSha256.init(secret);
            hmac.update(signing_input);
            var signature: [32]u8 = undefined;
            hmac.final(&signature);

            if (self.signature.len > 0) {
                self.allocator.free(self.signature);
            }
            self.signature = try base64UrlEncode(self.allocator, &signature);
        } else {
            return Error.NotImplemented; // Only HS256 for now
        }
    }

    pub fn verify(self: *const JwtToken, secret: []const u8) !bool {
        const header_encoded = try self.header.encode(self.allocator);
        defer self.allocator.free(header_encoded);

        const claims_encoded = try self.claims.encode(self.allocator);
        defer self.allocator.free(claims_encoded);

        const signing_input = try std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ header_encoded, claims_encoded });
        defer self.allocator.free(signing_input);

        if (std.mem.eql(u8, self.header.alg, "HS256")) {
            var hmac = std.crypto.auth.hmac.sha2.HmacSha256.init(secret);
            hmac.update(signing_input);
            var expected_signature: [32]u8 = undefined;
            hmac.final(&expected_signature);

            const expected_encoded = try base64UrlEncode(self.allocator, &expected_signature);
            defer self.allocator.free(expected_encoded);

            return std.mem.eql(u8, self.signature, expected_encoded);
        }

        return Error.NotImplemented;
    }

    pub fn encode(self: *const JwtToken) ![]u8 {
        const header_encoded = try self.header.encode(self.allocator);
        defer self.allocator.free(header_encoded);

        const claims_encoded = try self.claims.encode(self.allocator);
        defer self.allocator.free(claims_encoded);

        return try std.fmt.allocPrint(self.allocator, "{s}.{s}.{s}", .{ header_encoded, claims_encoded, self.signature });
    }

    pub fn decode(allocator: std.mem.Allocator, token_str: []const u8) !JwtToken {
        var parts = std.mem.splitSequence(u8, token_str, ".");

        const header_part = parts.next() orelse return Error.InvalidArgument;
        const claims_part = parts.next() orelse return Error.InvalidArgument;
        const signature_part = parts.next() orelse return Error.InvalidArgument;

        const header = try JwtHeader.decode(allocator, header_part);

        // Decode claims
        const claims_decoded = try base64UrlDecode(allocator, claims_part);
        defer allocator.free(claims_decoded);

        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, claims_decoded, .{});
        defer parsed.deinit();

        var claims = JwtClaims.init(allocator);

        const obj = parsed.value.object;
        if (obj.get("iss")) |iss| {
            try claims.setIssuer(iss.string);
        }
        if (obj.get("sub")) |sub| {
            try claims.setSubject(sub.string);
        }
        if (obj.get("aud")) |aud| {
            try claims.setAudience(aud.string);
        }
        if (obj.get("exp")) |exp| {
            claims.exp = exp.integer;
        }
        if (obj.get("iat")) |iat| {
            claims.iat = iat.integer;
        }
        if (obj.get("scope")) |scope| {
            try claims.setScope(scope.string);
        }

        const signature = try allocator.dupe(u8, signature_part);

        return JwtToken{
            .header = header,
            .claims = claims,
            .signature = signature,
            .allocator = allocator,
        };
    }
};

// OAuth2 Token Response
pub const OAuth2TokenResponse = struct {
    access_token: []const u8,
    token_type: []const u8,
    expires_in: ?i64 = null,
    refresh_token: ?[]const u8 = null,
    scope: ?[]const u8 = null,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *OAuth2TokenResponse) void {
        self.allocator.free(self.access_token);
        self.allocator.free(self.token_type);
        if (self.refresh_token) |token| self.allocator.free(token);
        if (self.scope) |scope| self.allocator.free(scope);
    }

    pub fn fromJson(allocator: std.mem.Allocator, json_str: []const u8) !OAuth2TokenResponse {
        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_str, .{});
        defer parsed.deinit();

        const obj = parsed.value.object;

        const access_token = try allocator.dupe(u8, obj.get("access_token").?.string);
        const token_type = try allocator.dupe(u8, obj.get("token_type").?.string);

        var refresh_token: ?[]const u8 = null;
        if (obj.get("refresh_token")) |rt| {
            refresh_token = try allocator.dupe(u8, rt.string);
        }

        var scope: ?[]const u8 = null;
        if (obj.get("scope")) |sc| {
            scope = try allocator.dupe(u8, sc.string);
        }

        var expires_in: ?i64 = null;
        if (obj.get("expires_in")) |exp| {
            expires_in = exp.integer;
        }

        return OAuth2TokenResponse{
            .access_token = access_token,
            .token_type = token_type,
            .expires_in = expires_in,
            .refresh_token = refresh_token,
            .scope = scope,
            .allocator = allocator,
        };
    }
};

// Authentication middleware
pub const AuthMiddleware = struct {
    secret: []const u8,
    issuer: []const u8,
    audience: []const u8,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, secret: []const u8, issuer: []const u8, audience: []const u8) !AuthMiddleware {
        return AuthMiddleware{
            .secret = try allocator.dupe(u8, secret),
            .issuer = try allocator.dupe(u8, issuer),
            .audience = try allocator.dupe(u8, audience),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *AuthMiddleware) void {
        self.allocator.free(self.secret);
        self.allocator.free(self.issuer);
        self.allocator.free(self.audience);
    }

    pub fn validateToken(self: *const AuthMiddleware, token_str: []const u8) !JwtClaims {
        var token = try JwtToken.decode(self.allocator, token_str);
        defer token.deinit();

        // Verify signature
        if (!try token.verify(self.secret)) {
            return Error.Unauthenticated;
        }

        // Check expiration
        if (!token.claims.isValidNow()) {
            return Error.Unauthenticated;
        }

        // Validate issuer
        if (token.claims.iss) |iss| {
            if (!std.mem.eql(u8, iss, self.issuer)) {
                return Error.Unauthenticated;
            }
        }

        // Validate audience
        if (token.claims.aud) |aud| {
            if (!std.mem.eql(u8, aud, self.audience)) {
                return Error.Unauthenticated;
            }
        }

        // Return validated claims (caller must deinit)
        return try token.claims.clone();
    }

    pub fn createToken(self: *const AuthMiddleware, subject: []const u8, scope: ?[]const u8, expires_in: i64) ![]u8 {
        const header = JwtHeader{
            .alg = "HS256",
            .typ = "JWT",
            .kid = null,
        };

        var claims = JwtClaims.init(self.allocator);
        defer claims.deinit();
        try claims.setIssuer(self.issuer);
        try claims.setSubject(subject);
        try claims.setAudience(self.audience);
        if (scope) |s| try claims.setScope(s);
        claims.setIssuedNow();
        claims.setExpiration(expires_in);

        var token = try JwtToken.init(self.allocator, header, claims);
        defer token.deinit();

        try token.sign(self.secret);
        return try token.encode();
    }
};

// Base64 URL encoding/decoding (simplified)
fn base64UrlEncode(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
    const encoder = std.base64.url_safe_no_pad.Encoder;
    const encoded_len = encoder.calcSize(data.len);
    const encoded = try allocator.alloc(u8, encoded_len);
    _ = encoder.encode(encoded, data);
    return encoded;
}

fn base64UrlDecode(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
    const decoder = std.base64.url_safe_no_pad.Decoder;
    const decoded_len = try decoder.calcSizeForSlice(data);
    const decoded = try allocator.alloc(u8, decoded_len);
    try decoder.decode(decoded, data);
    return decoded;
}

// Tests
test "JWT header encoding/decoding" {
    const header = JwtHeader{
        .alg = "HS256",
        .typ = "JWT",
        .kid = null,
    };

    const encoded = try header.encode(std.testing.allocator);
    defer std.testing.allocator.free(encoded);

    var decoded = try JwtHeader.decode(std.testing.allocator, encoded);
    defer decoded.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("HS256", decoded.alg);
    try std.testing.expectEqualStrings("JWT", decoded.typ);
    try std.testing.expect(decoded.kid == null);
}

test "JWT claims validation" {
    var claims = JwtClaims.init(std.testing.allocator);
    defer claims.deinit();

    try claims.setSubject("user123");
    try claims.setScope("read:data");
    claims.setExpiration(3600); // 1 hour from now
    claims.setIssuedNow();

    try std.testing.expect(claims.isValidNow());
    try std.testing.expect(!claims.isExpired());

    if (claims.sub) |sub| {
        try std.testing.expectEqualStrings("user123", sub);
    }
}

test "JWT token signing and verification" {
    const secret = "my-secret-key";

    const header = JwtHeader{
        .alg = "HS256",
        .typ = "JWT",
        .kid = null,
    };

    var claims = JwtClaims.init(std.testing.allocator);
    defer claims.deinit();

    try claims.setSubject("test-user");
    claims.setExpiration(3600);

    var token = try JwtToken.init(std.testing.allocator, header, claims);
    defer token.deinit();

    try token.sign(secret);
    try std.testing.expect(try token.verify(secret));

    // Test with wrong secret
    try std.testing.expect(!try token.verify("wrong-secret"));
}

test "auth middleware" {
    var middleware = try AuthMiddleware.init(std.testing.allocator, "secret-key", "test-issuer", "test-audience");
    defer middleware.deinit();

    const token_str = try middleware.createToken("user123", "read:data", 3600);
    defer std.testing.allocator.free(token_str);

    var validated_claims = try middleware.validateToken(token_str);
    defer validated_claims.deinit();

    if (validated_claims.sub) |sub| {
        try std.testing.expectEqualStrings("user123", sub);
    }
    if (validated_claims.scope) |scope| {
        try std.testing.expectEqualStrings("read:data", scope);
    }
}
