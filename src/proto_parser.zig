//! Protocol Buffer (.proto) file parser
//! Parses .proto files and extracts service definitions for code generation

const std = @import("std");
const Error = @import("error.zig").Error;

// Proto file AST nodes
pub const ProtoFile = struct {
    syntax: []const u8,
    package: ?[]const u8,
    imports: std.ArrayList([]const u8),
    options: std.StringHashMap([]const u8),
    messages: std.ArrayList(MessageDef),
    enums: std.ArrayList(EnumDef),
    services: std.ArrayList(ServiceDef),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) ProtoFile {
        return ProtoFile{
            .syntax = "proto3",
            .package = null,
            .imports = std.ArrayList([]const u8){},
            .options = std.StringHashMap([]const u8).init(allocator),
            .messages = std.ArrayList(MessageDef){},
            .enums = std.ArrayList(EnumDef){},
            .services = std.ArrayList(ServiceDef){},
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *ProtoFile) void {
        if (self.package) |pkg| {
            self.allocator.free(pkg);
        }

        for (self.imports.items) |import| {
            self.allocator.free(import);
        }
        self.imports.deinit(self.allocator);

        var opts_iter = self.options.iterator();
        while (opts_iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.options.deinit();

        for (self.messages.items) |*msg| {
            msg.deinit();
        }
        self.messages.deinit(self.allocator);

        for (self.enums.items) |*enum_def| {
            enum_def.deinit();
        }
        self.enums.deinit(self.allocator);

        for (self.services.items) |*service| {
            service.deinit();
        }
        self.services.deinit(self.allocator);
    }
};

pub const FieldType = enum {
    double,
    float,
    int32,
    int64,
    uint32,
    uint64,
    sint32,
    sint64,
    fixed32,
    fixed64,
    sfixed32,
    sfixed64,
    bool,
    string,
    bytes,
    message,
    enum_type,

    pub fn fromString(type_str: []const u8) ?FieldType {
        const type_map = std.StaticStringMap(FieldType).initComptime(.{
            .{ "double", .double },
            .{ "float", .float },
            .{ "int32", .int32 },
            .{ "int64", .int64 },
            .{ "uint32", .uint32 },
            .{ "uint64", .uint64 },
            .{ "sint32", .sint32 },
            .{ "sint64", .sint64 },
            .{ "fixed32", .fixed32 },
            .{ "fixed64", .fixed64 },
            .{ "sfixed32", .sfixed32 },
            .{ "sfixed64", .sfixed64 },
            .{ "bool", .bool },
            .{ "string", .string },
            .{ "bytes", .bytes },
        });

        return type_map.get(type_str);
    }
};

pub const FieldLabel = enum {
    optional,
    required,
    repeated,
};

pub const FieldDef = struct {
    label: ?FieldLabel,
    field_type: FieldType,
    type_name: ?[]const u8, // For message/enum types
    name: []const u8,
    number: u32,
    options: std.StringHashMap([]const u8),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, name: []const u8, field_type: FieldType, number: u32) !FieldDef {
        return FieldDef{
            .label = null,
            .field_type = field_type,
            .type_name = null,
            .name = try allocator.dupe(u8, name),
            .number = number,
            .options = std.StringHashMap([]const u8).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *FieldDef) void {
        self.allocator.free(self.name);
        if (self.type_name) |type_name| {
            self.allocator.free(type_name);
        }

        var opts_iter = self.options.iterator();
        while (opts_iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.options.deinit();
    }
};

pub const MessageDef = struct {
    name: []const u8,
    fields: std.ArrayList(FieldDef),
    nested_messages: std.ArrayList(MessageDef),
    nested_enums: std.ArrayList(EnumDef),
    options: std.StringHashMap([]const u8),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, name: []const u8) !MessageDef {
        return MessageDef{
            .name = try allocator.dupe(u8, name),
            .fields = std.ArrayList(FieldDef){},
            .nested_messages = std.ArrayList(MessageDef){},
            .nested_enums = std.ArrayList(EnumDef){},
            .options = std.StringHashMap([]const u8).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *MessageDef) void {
        self.allocator.free(self.name);

        for (self.fields.items) |*field| {
            field.deinit();
        }
        self.fields.deinit(self.allocator);

        for (self.nested_messages.items) |*msg| {
            msg.deinit();
        }
        self.nested_messages.deinit(self.allocator);

        for (self.nested_enums.items) |*enum_def| {
            enum_def.deinit();
        }
        self.nested_enums.deinit(self.allocator);

        var opts_iter = self.options.iterator();
        while (opts_iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.options.deinit();
    }
};

pub const EnumValueDef = struct {
    name: []const u8,
    number: i32,
    options: std.StringHashMap([]const u8),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, name: []const u8, number: i32) !EnumValueDef {
        return EnumValueDef{
            .name = try allocator.dupe(u8, name),
            .number = number,
            .options = std.StringHashMap([]const u8).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *EnumValueDef) void {
        self.allocator.free(self.name);

        var opts_iter = self.options.iterator();
        while (opts_iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.options.deinit();
    }
};

pub const EnumDef = struct {
    name: []const u8,
    values: std.ArrayList(EnumValueDef),
    options: std.StringHashMap([]const u8),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, name: []const u8) !EnumDef {
        return EnumDef{
            .name = try allocator.dupe(u8, name),
            .values = std.ArrayList(EnumValueDef){},
            .options = std.StringHashMap([]const u8).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *EnumDef) void {
        self.allocator.free(self.name);

        for (self.values.items) |*value| {
            value.deinit();
        }
        self.values.deinit(self.allocator);

        var opts_iter = self.options.iterator();
        while (opts_iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.options.deinit();
    }
};

pub const MethodDef = struct {
    name: []const u8,
    input_type: []const u8,
    output_type: []const u8,
    client_streaming: bool,
    server_streaming: bool,
    options: std.StringHashMap([]const u8),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, name: []const u8, input_type: []const u8, output_type: []const u8) !MethodDef {
        return MethodDef{
            .name = try allocator.dupe(u8, name),
            .input_type = try allocator.dupe(u8, input_type),
            .output_type = try allocator.dupe(u8, output_type),
            .client_streaming = false,
            .server_streaming = false,
            .options = std.StringHashMap([]const u8).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *MethodDef) void {
        self.allocator.free(self.name);
        self.allocator.free(self.input_type);
        self.allocator.free(self.output_type);

        var opts_iter = self.options.iterator();
        while (opts_iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.options.deinit();
    }
};

pub const ServiceDef = struct {
    name: []const u8,
    methods: std.ArrayList(MethodDef),
    options: std.StringHashMap([]const u8),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, name: []const u8) !ServiceDef {
        return ServiceDef{
            .name = try allocator.dupe(u8, name),
            .methods = std.ArrayList(MethodDef){},
            .options = std.StringHashMap([]const u8).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *ServiceDef) void {
        self.allocator.free(self.name);

        for (self.methods.items) |*method| {
            method.deinit();
        }
        self.methods.deinit(self.allocator);

        var opts_iter = self.options.iterator();
        while (opts_iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.options.deinit();
    }
};

// Tokenizer for proto files
pub const TokenType = enum {
    identifier,
    string_literal,
    number,
    keyword,
    symbol,
    comment,
    eof,
};

pub const Token = struct {
    type: TokenType,
    value: []const u8,
    line: u32,
    column: u32,
};

pub const Lexer = struct {
    input: []const u8,
    position: usize,
    line: u32,
    column: u32,

    const keywords = std.StaticStringMap(void).initComptime(.{
        .{"syntax"},     .{"package"},    .{"import"},     .{"option"},
        .{"message"},    .{"enum"},       .{"service"},    .{"rpc"},
        .{"returns"},    .{"stream"},     .{"optional"},   .{"required"},
        .{"repeated"},   .{"reserved"},   .{"extend"},     .{"extensions"},
        .{"oneof"},      .{"map"},        .{"public"},     .{"weak"},
        .{"true"},       .{"false"},
    });

    pub fn init(input: []const u8) Lexer {
        return Lexer{
            .input = input,
            .position = 0,
            .line = 1,
            .column = 1,
        };
    }

    pub fn nextToken(self: *Lexer) Token {
        self.skipWhitespace();

        if (self.position >= self.input.len) {
            return Token{ .type = .eof, .value = "", .line = self.line, .column = self.column };
        }

        const start_line = self.line;
        const start_column = self.column;
        const start_pos = self.position;

        const ch = self.input[self.position];

        switch (ch) {
            '/' => {
                if (self.position + 1 < self.input.len and self.input[self.position + 1] == '/') {
                    return self.readLineComment();
                } else if (self.position + 1 < self.input.len and self.input[self.position + 1] == '*') {
                    return self.readBlockComment();
                } else {
                    self.advance();
                    return Token{ .type = .symbol, .value = self.input[start_pos..self.position], .line = start_line, .column = start_column };
                }
            },
            '"' => return self.readString(),
            '\'' => return self.readString(),
            '0'...'9' => return self.readNumber(),
            'a'...'z', 'A'...'Z', '_' => return self.readIdentifier(),
            else => {
                self.advance();
                return Token{ .type = .symbol, .value = self.input[start_pos..self.position], .line = start_line, .column = start_column };
            },
        }
    }

    fn advance(self: *Lexer) void {
        if (self.position < self.input.len) {
            if (self.input[self.position] == '\n') {
                self.line += 1;
                self.column = 1;
            } else {
                self.column += 1;
            }
            self.position += 1;
        }
    }

    fn skipWhitespace(self: *Lexer) void {
        while (self.position < self.input.len) {
            const ch = self.input[self.position];
            if (ch == ' ' or ch == '\t' or ch == '\r' or ch == '\n') {
                self.advance();
            } else {
                break;
            }
        }
    }

    fn readLineComment(self: *Lexer) Token {
        const start_line = self.line;
        const start_column = self.column;
        const start_pos = self.position;

        while (self.position < self.input.len and self.input[self.position] != '\n') {
            self.advance();
        }

        return Token{ .type = .comment, .value = self.input[start_pos..self.position], .line = start_line, .column = start_column };
    }

    fn readBlockComment(self: *Lexer) Token {
        const start_line = self.line;
        const start_column = self.column;
        const start_pos = self.position;

        self.advance(); // skip '/'
        self.advance(); // skip '*'

        while (self.position + 1 < self.input.len) {
            if (self.input[self.position] == '*' and self.input[self.position + 1] == '/') {
                self.advance(); // skip '*'
                self.advance(); // skip '/'
                break;
            }
            self.advance();
        }

        return Token{ .type = .comment, .value = self.input[start_pos..self.position], .line = start_line, .column = start_column };
    }

    fn readString(self: *Lexer) Token {
        const start_line = self.line;
        const start_column = self.column;
        const start_pos = self.position;
        const quote_char = self.input[self.position];

        self.advance(); // skip opening quote

        while (self.position < self.input.len) {
            const ch = self.input[self.position];
            if (ch == quote_char) {
                self.advance(); // skip closing quote
                break;
            } else if (ch == '\\') {
                self.advance(); // skip backslash
                if (self.position < self.input.len) {
                    self.advance(); // skip escaped character
                }
            } else {
                self.advance();
            }
        }

        return Token{ .type = .string_literal, .value = self.input[start_pos..self.position], .line = start_line, .column = start_column };
    }

    fn readNumber(self: *Lexer) Token {
        const start_line = self.line;
        const start_column = self.column;
        const start_pos = self.position;

        while (self.position < self.input.len) {
            const ch = self.input[self.position];
            if (ch >= '0' and ch <= '9' or ch == '.' or ch == 'e' or ch == 'E' or ch == '+' or ch == '-') {
                self.advance();
            } else {
                break;
            }
        }

        return Token{ .type = .number, .value = self.input[start_pos..self.position], .line = start_line, .column = start_column };
    }

    fn readIdentifier(self: *Lexer) Token {
        const start_line = self.line;
        const start_column = self.column;
        const start_pos = self.position;

        while (self.position < self.input.len) {
            const ch = self.input[self.position];
            if ((ch >= 'a' and ch <= 'z') or (ch >= 'A' and ch <= 'Z') or
                (ch >= '0' and ch <= '9') or ch == '_') {
                self.advance();
            } else {
                break;
            }
        }

        const value = self.input[start_pos..self.position];
        const token_type: TokenType = if (keywords.has(value)) .keyword else .identifier;

        return Token{ .type = token_type, .value = value, .line = start_line, .column = start_column };
    }
};

// Parser for proto files
pub const Parser = struct {
    lexer: Lexer,
    current_token: Token,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, input: []const u8) Parser {
        var lexer = Lexer.init(input);
        const current_token = lexer.nextToken();

        return Parser{
            .lexer = lexer,
            .current_token = current_token,
            .allocator = allocator,
        };
    }

    pub fn parseFile(self: *Parser) !ProtoFile {
        var proto_file = ProtoFile.init(self.allocator);

        while (self.current_token.type != .eof) {
            if (self.current_token.type == .comment) {
                self.nextToken();
                continue;
            }

            if (self.current_token.type == .keyword) {
                if (std.mem.eql(u8, self.current_token.value, "syntax")) {
                    try self.parseSyntax(&proto_file);
                } else if (std.mem.eql(u8, self.current_token.value, "package")) {
                    try self.parsePackage(&proto_file);
                } else if (std.mem.eql(u8, self.current_token.value, "import")) {
                    try self.parseImport(&proto_file);
                } else if (std.mem.eql(u8, self.current_token.value, "option")) {
                    try self.parseOption(&proto_file.options);
                } else if (std.mem.eql(u8, self.current_token.value, "message")) {
                    const message = try self.parseMessage();
                    try proto_file.messages.append(self.allocator, message);
                } else if (std.mem.eql(u8, self.current_token.value, "enum")) {
                    const enum_def = try self.parseEnum();
                    try proto_file.enums.append(self.allocator, enum_def);
                } else if (std.mem.eql(u8, self.current_token.value, "service")) {
                    const service = try self.parseService();
                    try proto_file.services.append(self.allocator, service);
                } else {
                    return Error.InvalidArgument; // Unknown keyword
                }
            } else {
                return Error.InvalidArgument; // Unexpected token
            }
        }

        return proto_file;
    }

    fn nextToken(self: *Parser) void {
        self.current_token = self.lexer.nextToken();
    }

    fn expect(self: *Parser, expected: []const u8) !void {
        if (!std.mem.eql(u8, self.current_token.value, expected)) {
            return Error.InvalidArgument;
        }
        self.nextToken();
    }

    fn parseSyntax(self: *Parser, proto_file: *ProtoFile) !void {
        try self.expect("syntax");
        try self.expect("=");

        if (self.current_token.type != .string_literal) {
            return Error.InvalidArgument;
        }

        // Remove quotes from string literal
        const syntax_value = self.current_token.value;
        const syntax = syntax_value[1..syntax_value.len-1];
        proto_file.syntax = try self.allocator.dupe(u8, syntax);

        self.nextToken();
        try self.expect(";");
    }

    fn parsePackage(self: *Parser, proto_file: *ProtoFile) !void {
        try self.expect("package");

        if (self.current_token.type != .identifier) {
            return Error.InvalidArgument;
        }

        proto_file.package = try self.allocator.dupe(u8, self.current_token.value);
        self.nextToken();
        try self.expect(";");
    }

    fn parseImport(self: *Parser, proto_file: *ProtoFile) !void {
        try self.expect("import");

        // Handle optional "public" or "weak"
        if (self.current_token.type == .keyword and
            (std.mem.eql(u8, self.current_token.value, "public") or
             std.mem.eql(u8, self.current_token.value, "weak"))) {
            self.nextToken();
        }

        if (self.current_token.type != .string_literal) {
            return Error.InvalidArgument;
        }

        // Remove quotes from string literal
        const import_value = self.current_token.value;
        const import_path = import_value[1..import_value.len-1];
        const owned_import = try self.allocator.dupe(u8, import_path);
        try proto_file.imports.append(self.allocator, owned_import);

        self.nextToken();
        try self.expect(";");
    }

    fn parseOption(self: *Parser, options: *std.StringHashMap([]const u8)) !void {
        try self.expect("option");

        if (self.current_token.type != .identifier) {
            return Error.InvalidArgument;
        }

        const option_name = try self.allocator.dupe(u8, self.current_token.value);
        self.nextToken();

        try self.expect("=");

        var option_value: []const u8 = undefined;
        if (self.current_token.type == .string_literal) {
            // Remove quotes from string literal
            const str_value = self.current_token.value;
            option_value = try self.allocator.dupe(u8, str_value[1..str_value.len-1]);
        } else if (self.current_token.type == .number or self.current_token.type == .identifier) {
            option_value = try self.allocator.dupe(u8, self.current_token.value);
        } else {
            return Error.InvalidArgument;
        }

        self.nextToken();
        try self.expect(";");

        try options.put(option_name, option_value);
    }

    fn parseMessage(self: *Parser) !MessageDef {
        try self.expect("message");

        if (self.current_token.type != .identifier) {
            return Error.InvalidArgument;
        }

        var message = try MessageDef.init(self.allocator, self.current_token.value);
        self.nextToken();

        try self.expect("{");

        while (!std.mem.eql(u8, self.current_token.value, "}")) {
            if (self.current_token.type == .comment) {
                self.nextToken();
                continue;
            }

            if (self.current_token.type == .keyword) {
                if (std.mem.eql(u8, self.current_token.value, "message")) {
                    const nested = try self.parseMessage();
                    try message.nested_messages.append(self.allocator, nested);
                } else if (std.mem.eql(u8, self.current_token.value, "enum")) {
                    const nested_enum = try self.parseEnum();
                    try message.nested_enums.append(self.allocator, nested_enum);
                } else if (std.mem.eql(u8, self.current_token.value, "option")) {
                    try self.parseOption(&message.options);
                } else {
                    // Parse field
                    const field = try self.parseField();
                    try message.fields.append(self.allocator, field);
                }
            } else {
                // Parse field
                const field = try self.parseField();
                try message.fields.append(self.allocator, field);
            }
        }

        try self.expect("}");
        return message;
    }

    fn parseField(self: *Parser) !FieldDef {
        var label: ?FieldLabel = null;

        // Check for field labels
        if (self.current_token.type == .keyword) {
            if (std.mem.eql(u8, self.current_token.value, "optional")) {
                label = .optional;
                self.nextToken();
            } else if (std.mem.eql(u8, self.current_token.value, "required")) {
                label = .required;
                self.nextToken();
            } else if (std.mem.eql(u8, self.current_token.value, "repeated")) {
                label = .repeated;
                self.nextToken();
            }
        }

        // Parse field type
        if (self.current_token.type != .identifier) {
            return Error.InvalidArgument;
        }

        const type_str = self.current_token.value;
        var field_type: FieldType = undefined;
        var type_name: ?[]const u8 = null;

        if (FieldType.fromString(type_str)) |ft| {
            field_type = ft;
        } else {
            // Custom message or enum type
            field_type = .message; // Default to message type
            type_name = try self.allocator.dupe(u8, type_str);
        }

        self.nextToken();

        // Parse field name
        if (self.current_token.type != .identifier) {
            return Error.InvalidArgument;
        }

        const field_name = self.current_token.value;
        self.nextToken();

        // Parse field number
        try self.expect("=");

        if (self.current_token.type != .number) {
            return Error.InvalidArgument;
        }

        const field_number = try std.fmt.parseInt(u32, self.current_token.value, 10);
        self.nextToken();

        // Parse optional field options
        const field_options = std.StringHashMap([]const u8).init(self.allocator);
        if (std.mem.eql(u8, self.current_token.value, "[")) {
            self.nextToken();
            // TODO: Parse field options
            try self.expect("]");
        }

        try self.expect(";");

        var field = try FieldDef.init(self.allocator, field_name, field_type, field_number);
        field.label = label;
        field.type_name = type_name;
        field.options = field_options;

        return field;
    }

    fn parseEnum(self: *Parser) !EnumDef {
        try self.expect("enum");

        if (self.current_token.type != .identifier) {
            return Error.InvalidArgument;
        }

        var enum_def = try EnumDef.init(self.allocator, self.current_token.value);
        self.nextToken();

        try self.expect("{");

        while (!std.mem.eql(u8, self.current_token.value, "}")) {
            if (self.current_token.type == .comment) {
                self.nextToken();
                continue;
            }

            if (self.current_token.type == .keyword and std.mem.eql(u8, self.current_token.value, "option")) {
                try self.parseOption(&enum_def.options);
            } else {
                // Parse enum value
                if (self.current_token.type != .identifier) {
                    return Error.InvalidArgument;
                }

                const value_name = self.current_token.value;
                self.nextToken();

                try self.expect("=");

                if (self.current_token.type != .number) {
                    return Error.InvalidArgument;
                }

                const value_number = try std.fmt.parseInt(i32, self.current_token.value, 10);
                self.nextToken();

                // Skip optional options for now
                if (std.mem.eql(u8, self.current_token.value, "[")) {
                    self.nextToken();
                    // TODO: Parse enum value options
                    try self.expect("]");
                }

                try self.expect(";");

                const enum_value = try EnumValueDef.init(self.allocator, value_name, value_number);
                try enum_def.values.append(self.allocator, enum_value);
            }
        }

        try self.expect("}");
        return enum_def;
    }

    fn parseService(self: *Parser) !ServiceDef {
        try self.expect("service");

        if (self.current_token.type != .identifier) {
            return Error.InvalidArgument;
        }

        var service = try ServiceDef.init(self.allocator, self.current_token.value);
        self.nextToken();

        try self.expect("{");

        while (!std.mem.eql(u8, self.current_token.value, "}")) {
            if (self.current_token.type == .comment) {
                self.nextToken();
                continue;
            }

            if (self.current_token.type == .keyword) {
                if (std.mem.eql(u8, self.current_token.value, "option")) {
                    try self.parseOption(&service.options);
                } else if (std.mem.eql(u8, self.current_token.value, "rpc")) {
                    const method = try self.parseMethod();
                    try service.methods.append(self.allocator, method);
                } else {
                    return Error.InvalidArgument;
                }
            } else {
                return Error.InvalidArgument;
            }
        }

        try self.expect("}");
        return service;
    }

    fn parseMethod(self: *Parser) !MethodDef {
        try self.expect("rpc");

        if (self.current_token.type != .identifier) {
            return Error.InvalidArgument;
        }

        const method_name = self.current_token.value;
        self.nextToken();

        try self.expect("(");

        // Check for client streaming
        var client_streaming = false;
        if (self.current_token.type == .keyword and std.mem.eql(u8, self.current_token.value, "stream")) {
            client_streaming = true;
            self.nextToken();
        }

        if (self.current_token.type != .identifier) {
            return Error.InvalidArgument;
        }

        const input_type = self.current_token.value;
        self.nextToken();

        try self.expect(")");
        try self.expect("returns");
        try self.expect("(");

        // Check for server streaming
        var server_streaming = false;
        if (self.current_token.type == .keyword and std.mem.eql(u8, self.current_token.value, "stream")) {
            server_streaming = true;
            self.nextToken();
        }

        if (self.current_token.type != .identifier) {
            return Error.InvalidArgument;
        }

        const output_type = self.current_token.value;
        self.nextToken();

        try self.expect(")");

        // Parse method body (options)
        var method_options = std.StringHashMap([]const u8).init(self.allocator);
        if (std.mem.eql(u8, self.current_token.value, "{")) {
            self.nextToken();

            while (!std.mem.eql(u8, self.current_token.value, "}")) {
                if (self.current_token.type == .comment) {
                    self.nextToken();
                    continue;
                }

                if (self.current_token.type == .keyword and std.mem.eql(u8, self.current_token.value, "option")) {
                    try self.parseOption(&method_options);
                } else {
                    return Error.InvalidArgument;
                }
            }

            try self.expect("}");
        } else {
            try self.expect(";");
        }

        var method = try MethodDef.init(self.allocator, method_name, input_type, output_type);
        method.client_streaming = client_streaming;
        method.server_streaming = server_streaming;
        method.options = method_options;

        return method;
    }
};

// Public API
pub fn parseProtoFile(allocator: std.mem.Allocator, content: []const u8) !ProtoFile {
    var parser = Parser.init(allocator, content);
    return try parser.parseFile();
}

pub fn parseProtoFromFile(allocator: std.mem.Allocator, file_path: []const u8) !ProtoFile {
    const file = try std.fs.cwd().openFile(file_path, .{});
    defer file.close();

    const file_size = try file.getEndPos();
    const content = try allocator.alloc(u8, file_size);
    defer allocator.free(content);

    _ = try file.readAll(content);

    return parseProtoFile(allocator, content);
}

// Tests
test "parse simple proto file" {
    const proto_content =
        \\syntax = "proto3";
        \\package example;
        \\
        \\message HelloRequest {
        \\  string name = 1;
        \\}
        \\
        \\message HelloResponse {
        \\  string message = 1;
        \\}
        \\
        \\service Greeter {
        \\  rpc SayHello(HelloRequest) returns (HelloResponse);
        \\}
    ;

    var proto_file = try parseProtoFile(std.testing.allocator, proto_content);
    defer proto_file.deinit();

    try std.testing.expectEqualStrings("proto3", proto_file.syntax);
    try std.testing.expectEqualStrings("example", proto_file.package.?);
    try std.testing.expectEqual(@as(usize, 2), proto_file.messages.items.len);
    try std.testing.expectEqual(@as(usize, 1), proto_file.services.items.len);

    const service = &proto_file.services.items[0];
    try std.testing.expectEqualStrings("Greeter", service.name);
    try std.testing.expectEqual(@as(usize, 1), service.methods.items.len);

    const method = &service.methods.items[0];
    try std.testing.expectEqualStrings("SayHello", method.name);
    try std.testing.expectEqualStrings("HelloRequest", method.input_type);
    try std.testing.expectEqualStrings("HelloResponse", method.output_type);
    try std.testing.expect(!method.client_streaming);
    try std.testing.expect(!method.server_streaming);
}

test "parse streaming methods" {
    const proto_content =
        \\syntax = "proto3";
        \\
        \\service StreamService {
        \\  rpc ClientStream(stream Request) returns (Response);
        \\  rpc ServerStream(Request) returns (stream Response);
        \\  rpc BidirectionalStream(stream Request) returns (stream Response);
        \\}
    ;

    var proto_file = try parseProtoFile(std.testing.allocator, proto_content);
    defer proto_file.deinit();

    const service = &proto_file.services.items[0];
    try std.testing.expectEqual(@as(usize, 3), service.methods.items.len);

    // Client streaming
    const client_stream = &service.methods.items[0];
    try std.testing.expect(client_stream.client_streaming);
    try std.testing.expect(!client_stream.server_streaming);

    // Server streaming
    const server_stream = &service.methods.items[1];
    try std.testing.expect(!server_stream.client_streaming);
    try std.testing.expect(server_stream.server_streaming);

    // Bidirectional streaming
    const bidi_stream = &service.methods.items[2];
    try std.testing.expect(bidi_stream.client_streaming);
    try std.testing.expect(bidi_stream.server_streaming);
}