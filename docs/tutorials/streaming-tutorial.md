# Streaming RPC Tutorial

**Master streaming RPCs for real-time communication**

This tutorial covers all streaming patterns in zRPC: client streaming, server streaming, and bidirectional streaming.

## Streaming Overview

zRPC supports four RPC patterns:
- **Unary**: Single request → Single response
- **Client Streaming**: Multiple requests → Single response
- **Server Streaming**: Single request → Multiple responses
- **Bidirectional Streaming**: Multiple requests ↔ Multiple responses

## Real-World Example: Chat Application

Let's build a complete chat application demonstrating all streaming patterns.

### Step 1: Define Message Types

Create `src/chat.zig`:

```zig
const std = @import("std");

// Basic message structure
pub const Message = struct {
    id: u64,
    user: []const u8,
    content: []const u8,
    timestamp: i64,
    room: []const u8,

    pub fn now(id: u64, user: []const u8, content: []const u8, room: []const u8) Message {
        return Message{
            .id = id,
            .user = user,
            .content = content,
            .timestamp = std.time.milliTimestamp(),
            .room = room,
        };
    }
};

// Client streaming: Send multiple messages, get summary
pub const MessageBatch = struct {
    messages: []const Message,
};

pub const BatchSummary = struct {
    total_messages: u32,
    total_characters: u32,
    users: []const []const u8,
    timestamp: i64,
};

// Server streaming: Subscribe to room messages
pub const SubscribeRequest = struct {
    room: []const u8,
    user: []const u8,
    since_timestamp: ?i64 = null,
};

// Bidirectional streaming: Real-time chat
pub const ChatJoinRequest = struct {
    user: []const u8,
    room: []const u8,
};

pub const ChatResponse = struct {
    type: ResponseType,
    message: ?Message = null,
    user_joined: ?[]const u8 = null,
    user_left: ?[]const u8 = null,
    error_message: ?[]const u8 = null,

    pub const ResponseType = enum {
        message,
        user_joined,
        user_left,
        error,
        ack,
    };

    pub fn messageResponse(message: Message) ChatResponse {
        return ChatResponse{
            .type = .message,
            .message = message,
        };
    }

    pub fn userJoinedResponse(user: []const u8) ChatResponse {
        return ChatResponse{
            .type = .user_joined,
            .user_joined = user,
        };
    }

    pub fn ackResponse() ChatResponse {
        return ChatResponse{
            .type = .ack,
        };
    }
};

// User management
pub const User = struct {
    name: []const u8,
    joined_at: i64,
    message_count: u32 = 0,
};

// Room state
pub const Room = struct {
    name: []const u8,
    users: std.StringHashMap(User),
    messages: std.ArrayList(Message),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, name: []const u8) Room {
        return Room{
            .name = name,
            .users = std.StringHashMap(User).init(allocator),
            .messages = std.ArrayList(Message).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Room) void {
        self.users.deinit();
        self.messages.deinit();
    }

    pub fn addUser(self: *Room, user: User) !void {
        try self.users.put(user.name, user);
    }

    pub fn removeUser(self: *Room, username: []const u8) void {
        _ = self.users.remove(username);
    }

    pub fn addMessage(self: *Room, message: Message) !void {
        try self.messages.append(message);

        // Update user message count
        if (self.users.getPtr(message.user)) |user| {
            user.message_count += 1;
        }
    }

    pub fn getRecentMessages(self: *const Room, since_timestamp: ?i64) []const Message {
        if (since_timestamp) |since| {
            var result = std.ArrayList(Message).init(self.allocator);
            for (self.messages.items) |message| {
                if (message.timestamp > since) {
                    result.append(message) catch break;
                }
            }
            return result.toOwnedSlice() catch &[_]Message{};
        }
        return self.messages.items;
    }
};
```

### Step 2: Implement the Chat Server

Create `src/chat_server.zig`:

```zig
const std = @import("std");
const zrpc = @import("zrpc-core");
const quic_transport = @import("zrpc-transport-quic");
const chat = @import("chat.zig");

const ChatService = struct {
    allocator: std.mem.Allocator,
    rooms: std.StringHashMap(chat.Room),
    next_message_id: std.atomic.Value(u64),
    active_streams: std.ArrayList(*ActiveStream),
    mutex: std.Thread.Mutex,

    const Self = @This();

    const ActiveStream = struct {
        room: []const u8,
        user: []const u8,
        stream: *zrpc.BidirectionalStream(chat.Message, chat.ChatResponse),
    };

    pub fn init(allocator: std.mem.Allocator) !*Self {
        const service = try allocator.create(Self);
        service.* = Self{
            .allocator = allocator,
            .rooms = std.StringHashMap(chat.Room).init(allocator),
            .next_message_id = std.atomic.Value(u64).init(1),
            .active_streams = std.ArrayList(*ActiveStream).init(allocator),
            .mutex = std.Thread.Mutex{},
        };
        return service;
    }

    pub fn deinit(self: *Self) void {
        var room_iterator = self.rooms.iterator();
        while (room_iterator.next()) |entry| {
            entry.value_ptr.deinit();
        }
        self.rooms.deinit();
        self.active_streams.deinit();
        self.allocator.destroy(self);
    }

    // Unary RPC: Send a single message
    pub fn sendMessage(self: *Self, request: chat.Message, context: *const zrpc.RequestContext) !chat.ChatResponse {
        _ = context;

        self.mutex.lock();
        defer self.mutex.unlock();

        // Get or create room
        const room = self.getOrCreateRoom(request.room);

        // Create message with new ID
        var message = request;
        message.id = self.next_message_id.fetchAdd(1, .monotonic);
        message.timestamp = std.time.milliTimestamp();

        // Add to room
        try room.addMessage(message);

        std.log.info("📨 Message from {} in {}: {s}", .{ message.user, message.room, message.content });

        // Broadcast to active streams in this room
        try self.broadcastToRoom(message.room, chat.ChatResponse.messageResponse(message));

        return chat.ChatResponse.ackResponse();
    }

    // Client streaming: Receive multiple messages, return summary
    pub fn sendMessageBatch(self: *Self, stream: *zrpc.ClientStream(chat.Message, chat.BatchSummary)) !void {
        var messages = std.ArrayList(chat.Message).init(self.allocator);
        defer messages.deinit();

        var users = std.StringHashMap(void).init(self.allocator);
        defer users.deinit();

        var total_characters: u32 = 0;

        // Receive all messages from client
        while (true) {
            const message = stream.receive() catch |err| switch (err) {
                error.StreamClosed => break,
                else => return err,
            };

            if (message) |msg| {
                try messages.append(msg);
                total_characters += @intCast(msg.content.len);
                try users.put(msg.user, {});

                // Process message
                try self.sendMessage(msg, &zrpc.RequestContext{});
            } else {
                break; // End of stream
            }
        }

        // Create summary
        var user_list = std.ArrayList([]const u8).init(self.allocator);
        defer user_list.deinit();

        var user_iterator = users.iterator();
        while (user_iterator.next()) |entry| {
            try user_list.append(entry.key_ptr.*);
        }

        const summary = chat.BatchSummary{
            .total_messages = @intCast(messages.items.len),
            .total_characters = total_characters,
            .users = try user_list.toOwnedSlice(),
            .timestamp = std.time.milliTimestamp(),
        };

        // Send summary back
        try stream.respond(summary);

        std.log.info("📊 Processed batch: {} messages, {} chars, {} users",
            .{ summary.total_messages, summary.total_characters, summary.users.len });
    }

    // Server streaming: Subscribe to room messages
    pub fn subscribeToRoom(self: *Self, request: chat.SubscribeRequest,
                          stream: *zrpc.ServerStream(chat.SubscribeRequest, chat.ChatResponse)) !void {

        std.log.info("📺 {} subscribing to room: {s}", .{ request.user, request.room });

        self.mutex.lock();
        const room = self.getOrCreateRoom(request.room);

        // Send recent messages if requested
        if (request.since_timestamp) |since| {
            const recent_messages = room.getRecentMessages(since);
            for (recent_messages) |message| {
                try stream.send(chat.ChatResponse.messageResponse(message));
            }
        }
        self.mutex.unlock();

        // Add user to room
        const user = chat.User{
            .name = request.user,
            .joined_at = std.time.milliTimestamp(),
        };

        self.mutex.lock();
        try room.addUser(user);
        self.mutex.unlock();

        // Notify about user joining
        try self.broadcastToRoom(request.room, chat.ChatResponse.userJoinedResponse(request.user));

        // Keep stream alive (in real implementation, you'd handle this differently)
        var count: u32 = 0;
        while (count < 100) { // Demo limitation
            std.time.sleep(1000 * std.time.ns_per_ms); // 1 second
            count += 1;

            // In real implementation, this would be event-driven
            // For demo, we'll just send periodic updates
        }
    }

    // Bidirectional streaming: Real-time chat
    pub fn joinChat(self: *Self, stream: *zrpc.BidirectionalStream(chat.Message, chat.ChatResponse)) !void {
        // Wait for initial join request
        const join_message = try stream.receive() orelse return error.NoJoinMessage;

        std.log.info("🔗 {} joining chat in room: {s}", .{ join_message.user, join_message.room });

        // Register active stream
        const active_stream = try self.allocator.create(ActiveStream);
        active_stream.* = ActiveStream{
            .room = join_message.room,
            .user = join_message.user,
            .stream = stream,
        };

        self.mutex.lock();
        try self.active_streams.append(active_stream);

        // Add user to room
        const room = self.getOrCreateRoom(join_message.room);
        const user = chat.User{
            .name = join_message.user,
            .joined_at = std.time.milliTimestamp(),
        };
        try room.addUser(user);
        self.mutex.unlock();

        // Send acknowledgment
        try stream.send(chat.ChatResponse.ackResponse());

        // Notify others about user joining
        try self.broadcastToRoom(join_message.room, chat.ChatResponse.userJoinedResponse(join_message.user));

        // Handle incoming messages
        while (true) {
            const message = stream.receive() catch |err| switch (err) {
                error.StreamClosed, error.ConnectionReset => break,
                else => return err,
            };

            if (message) |msg| {
                // Process incoming message
                const response = try self.sendMessage(msg, &zrpc.RequestContext{});
                try stream.send(response);
            } else {
                break; // Client closed stream
            }
        }

        // Cleanup: remove from active streams and room
        self.mutex.lock();
        defer self.mutex.unlock();

        // Remove from active streams
        for (self.active_streams.items, 0..) |active, i| {
            if (active == active_stream) {
                _ = self.active_streams.swapRemove(i);
                break;
            }
        }

        // Remove from room
        if (self.rooms.getPtr(join_message.room)) |room| {
            room.removeUser(join_message.user);
        }

        // Notify about user leaving
        try self.broadcastToRoom(join_message.room, chat.ChatResponse{
            .type = .user_left,
            .user_left = join_message.user,
        });

        self.allocator.destroy(active_stream);
        std.log.info("👋 {} left chat room: {s}", .{ join_message.user, join_message.room });
    }

    // Helper methods
    fn getOrCreateRoom(self: *Self, room_name: []const u8) *chat.Room {
        if (self.rooms.getPtr(room_name)) |room| {
            return room;
        }

        // Create new room
        const room = chat.Room.init(self.allocator, room_name);
        self.rooms.put(room_name, room) catch unreachable;
        return self.rooms.getPtr(room_name).?;
    }

    fn broadcastToRoom(self: *Self, room_name: []const u8, response: chat.ChatResponse) !void {
        for (self.active_streams.items) |active_stream| {
            if (std.mem.eql(u8, active_stream.room, room_name)) {
                active_stream.stream.send(response) catch |err| {
                    std.log.warn("Failed to send to {}: {}", .{ active_stream.user, err });
                };
            }
        }
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.log.info("💬 Starting Chat Server...");

    // Create transport and server
    var transport = quic_transport.createServerTransport(allocator);
    defer transport.deinit();

    var server_config = zrpc.ServerConfig.default(transport);
    server_config.enable_debug_logging = true;
    server_config.max_connections = 1000;
    server_config.request_timeout_ms = 60000; // 1 minute for streaming

    var server = try zrpc.Server.init(allocator, server_config);
    defer server.deinit();

    // Create chat service
    var chat_service = try ChatService.init(allocator);
    defer chat_service.deinit();

    // TLS configuration
    var tls_config = zrpc.TlsConfig.development();
    try server.bind("0.0.0.0:8443", &tls_config);

    // Register handlers
    try server.registerHandler("Chat/SendMessage", chat.Message, chat.ChatResponse,
        zrpc.MethodHandler(chat.Message, chat.ChatResponse){
            .handler_fn = @ptrCast(&chat_service.sendMessage)
        });

    std.log.info("✅ Chat service registered on 0.0.0.0:8443");
    std.log.info("🚀 Ready for streaming connections!");

    try server.serve();
}
```

### Step 3: Client Streaming Example

Create `src/batch_client.zig`:

```zig
const std = @import("std");
const zrpc = @import("zrpc-core");
const quic_transport = @import("zrpc-transport-quic");
const chat = @import("chat.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.log.info("📤 Client Streaming: Batch Message Sender");

    // Create client
    var transport = quic_transport.createClientTransport(allocator);
    defer transport.deinit();

    var client_config = zrpc.ClientConfig.default(transport);
    client_config.request_timeout_ms = 30000; // 30 seconds for streaming

    var client = try zrpc.Client.init(allocator, client_config);
    defer client.deinit();

    var tls_config = zrpc.TlsConfig.development();
    try client.connect("localhost:8443", &tls_config);
    std.log.info("✅ Connected to chat server");

    // Create client stream
    var stream = try client.clientStream(chat.Message, chat.BatchSummary, "Chat/SendMessageBatch");
    defer stream.close();

    // Send multiple messages
    const messages = [_]chat.Message{
        chat.Message.now(0, "alice", "Hello everyone!", "general"),
        chat.Message.now(0, "alice", "How's everyone doing?", "general"),
        chat.Message.now(0, "bob", "Hi Alice! Good to see you", "general"),
        chat.Message.now(0, "alice", "Thanks Bob! Great to be here", "general"),
        chat.Message.now(0, "charlie", "Room is getting lively!", "general"),
    };

    std.log.info("📨 Sending {} messages...", .{messages.len});

    for (messages) |message| {
        try stream.send(message);
        std.log.info("  → {}: {s}", .{ message.user, message.content });
        std.time.sleep(500 * std.time.ns_per_ms); // Small delay for demo
    }

    // Close send side and receive summary
    const summary = try stream.closeAndReceive();

    std.log.info("📊 Batch Summary:");
    std.log.info("  Total messages: {}", .{summary.total_messages});
    std.log.info("  Total characters: {}", .{summary.total_characters});
    std.log.info("  Users involved: {}", .{summary.users.len});
    for (summary.users) |user| {
        std.log.info("    - {s}", .{user});
    }

    std.log.info("🎉 Client streaming completed!");
}
```

### Step 4: Server Streaming Example

Create `src/subscriber_client.zig`:

```zig
const std = @import("std");
const zrpc = @import("zrpc-core");
const quic_transport = @import("zrpc-transport-quic");
const chat = @import("chat.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.log.info("📥 Server Streaming: Room Subscriber");

    // Create client
    var transport = quic_transport.createClientTransport(allocator);
    defer transport.deinit();

    var client_config = zrpc.ClientConfig.default(transport);
    client_config.request_timeout_ms = 60000; // 1 minute for streaming

    var client = try zrpc.Client.init(allocator, client_config);
    defer client.deinit();

    var tls_config = zrpc.TlsConfig.development();
    try client.connect("localhost:8443", &tls_config);
    std.log.info("✅ Connected to chat server");

    // Subscribe to room
    const subscribe_request = chat.SubscribeRequest{
        .room = "general",
        .user = "subscriber",
        .since_timestamp = null, // Get all messages
    };

    std.log.info("📺 Subscribing to room: {s}", .{subscribe_request.room});

    var stream = try client.serverStream(chat.SubscribeRequest, chat.ChatResponse,
        "Chat/SubscribeToRoom", subscribe_request);
    defer stream.close();

    // Listen for messages
    var message_count: u32 = 0;
    while (try stream.next()) |response| {
        message_count += 1;

        switch (response.type) {
            .message => {
                if (response.message) |message| {
                    std.log.info("📨 [{s}] {}: {s}",
                        .{ message.room, message.user, message.content });
                }
            },
            .user_joined => {
                if (response.user_joined) |user| {
                    std.log.info("👋 {} joined the room", .{user});
                }
            },
            .user_left => {
                if (response.user_left) |user| {
                    std.log.info("🚪 {} left the room", .{user});
                }
            },
            .error => {
                if (response.error_message) |error_msg| {
                    std.log.err("❌ Error: {s}", .{error_msg});
                }
            },
            .ack => {
                std.log.info("✅ Acknowledgment received");
            },
        }

        // Demo limitation: stop after 50 messages
        if (message_count >= 50) {
            std.log.info("Demo limit reached, stopping...");
            break;
        }
    }

    std.log.info("📊 Received {} messages", .{message_count});
    std.log.info("🎉 Server streaming completed!");
}
```

### Step 5: Bidirectional Streaming Example

Create `src/chat_client.zig`:

```zig
const std = @import("std");
const zrpc = @import("zrpc-core");
const quic_transport = @import("zrpc-transport-quic");
const chat = @import("chat.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.log.info("💬 Bidirectional Streaming: Interactive Chat Client");

    // Create client
    var transport = quic_transport.createClientTransport(allocator);
    defer transport.deinit();

    var client_config = zrpc.ClientConfig.default(transport);
    client_config.request_timeout_ms = 300000; // 5 minutes for interactive chat

    var client = try zrpc.Client.init(allocator, client_config);
    defer client.deinit();

    var tls_config = zrpc.TlsConfig.development();
    try client.connect("localhost:8443", &tls_config);
    std.log.info("✅ Connected to chat server");

    // Get user info
    const stdin = std.io.getStdIn().reader();
    var input_buffer: [256]u8 = undefined;

    std.log.info("Enter your username:");
    const username = (try stdin.readUntilDelimiterOrEof(input_buffer[0..], '\n')) orelse return;
    const username_trimmed = std.mem.trim(u8, username, " \n\r");

    std.log.info("Enter room name:");
    const room = (try stdin.readUntilDelimiterOrEof(input_buffer[0..], '\n')) orelse return;
    const room_trimmed = std.mem.trim(u8, room, " \n\r");

    // Create bidirectional stream
    var stream = try client.bidirectionalStream(chat.Message, chat.ChatResponse, "Chat/JoinChat");
    defer stream.close();

    // Send join message
    const join_message = chat.Message.now(0, username_trimmed, "", room_trimmed);
    try stream.send(join_message);

    std.log.info("🔗 Joining chat room: {s} as {s}", .{ room_trimmed, username_trimmed });
    std.log.info("Type messages and press Enter. Type 'quit' to exit.");
    std.log.info("----------------------------------------");

    // Start background thread to handle incoming messages
    const ReceiveThread = struct {
        stream_ptr: *zrpc.BidirectionalStream(chat.Message, chat.ChatResponse),
        should_stop: *std.atomic.Value(bool),

        fn run(self: @This()) void {
            while (!self.should_stop.load(.monotonic)) {
                const response = self.stream_ptr.receive() catch |err| switch (err) {
                    error.StreamClosed, error.ConnectionReset => break,
                    else => {
                        std.log.err("Receive error: {}", .{err});
                        break;
                    },
                };

                if (response) |resp| {
                    switch (resp.type) {
                        .message => {
                            if (resp.message) |message| {
                                std.log.info("📨 {}: {s}", .{ message.user, message.content });
                            }
                        },
                        .user_joined => {
                            if (resp.user_joined) |user| {
                                std.log.info("👋 {} joined the chat", .{user});
                            }
                        },
                        .user_left => {
                            if (resp.user_left) |user| {
                                std.log.info("🚪 {} left the chat", .{user});
                            }
                        },
                        .ack => {
                            // Silent acknowledgment
                        },
                        .error => {
                            if (resp.error_message) |error_msg| {
                                std.log.err("❌ Error: {s}", .{error_msg});
                            }
                        },
                    }
                } else {
                    break; // Stream ended
                }
            }
        }
    };

    var should_stop = std.atomic.Value(bool).init(false);
    const receive_context = ReceiveThread{
        .stream_ptr = &stream,
        .should_stop = &should_stop,
    };

    const receive_thread = try std.Thread.spawn(.{}, ReceiveThread.run, .{receive_context});

    // Main input loop
    while (true) {
        const input = (try stdin.readUntilDelimiterOrEof(input_buffer[0..], '\n')) orelse break;
        const message_content = std.mem.trim(u8, input, " \n\r");

        if (std.mem.eql(u8, message_content, "quit")) {
            std.log.info("👋 Goodbye!");
            break;
        }

        if (message_content.len == 0) continue;

        // Send message
        const message = chat.Message.now(0, username_trimmed, message_content, room_trimmed);
        try stream.send(message);
    }

    // Cleanup
    should_stop.store(true, .monotonic);
    try stream.closeSend();
    receive_thread.join();

    std.log.info("🎉 Chat session ended!");
}
```

### Step 6: Update build.zig

Add the new executables to your `build.zig`:

```zig
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Mock modules (adjust paths as needed)
    const zrpc_core = b.addModule("zrpc-core", .{
        .root_source_file = b.path("../../src/core.zig"),
        .target = target,
    });

    const quic_transport = b.addModule("zrpc-transport-quic", .{
        .root_source_file = b.path("../../src/adapters/quic.zig"),
        .target = target,
        .imports = &.{
            .{ .name = "zrpc-core", .module = zrpc_core },
        },
    });

    // Chat server
    const chat_server = b.addExecutable(.{
        .name = "chat-server",
        .root_source_file = b.path("src/chat_server.zig"),
        .target = target,
        .optimize = optimize,
    });
    chat_server.root_module.addImport("zrpc-core", zrpc_core);
    chat_server.root_module.addImport("zrpc-transport-quic", quic_transport);

    // Client streaming example
    const batch_client = b.addExecutable(.{
        .name = "batch-client",
        .root_source_file = b.path("src/batch_client.zig"),
        .target = target,
        .optimize = optimize,
    });
    batch_client.root_module.addImport("zrpc-core", zrpc_core);
    batch_client.root_module.addImport("zrpc-transport-quic", quic_transport);

    // Server streaming example
    const subscriber_client = b.addExecutable(.{
        .name = "subscriber-client",
        .root_source_file = b.path("src/subscriber_client.zig"),
        .target = target,
        .optimize = optimize,
    });
    subscriber_client.root_module.addImport("zrpc-core", zrpc_core);
    subscriber_client.root_module.addImport("zrpc-transport-quic", quic_transport);

    // Bidirectional streaming example
    const chat_client = b.addExecutable(.{
        .name = "chat-client",
        .root_source_file = b.path("src/chat_client.zig"),
        .target = target,
        .optimize = optimize,
    });
    chat_client.root_module.addImport("zrpc-core", zrpc_core);
    chat_client.root_module.addImport("zrpc-transport-quic", quic_transport);

    // Install artifacts
    b.installArtifact(chat_server);
    b.installArtifact(batch_client);
    b.installArtifact(subscriber_client);
    b.installArtifact(chat_client);

    // Run steps
    const run_server = b.step("chat-server", "Run the chat server");
    run_server.dependOn(&b.addRunArtifact(chat_server).step);

    const run_batch = b.step("batch-client", "Run batch message client");
    run_batch.dependOn(&b.addRunArtifact(batch_client).step);

    const run_subscriber = b.step("subscriber", "Run room subscriber client");
    run_subscriber.dependOn(&b.addRunArtifact(subscriber_client).step);

    const run_chat = b.step("chat-client", "Run interactive chat client");
    run_chat.dependOn(&b.addRunArtifact(chat_client).step);
}
```

## Running the Chat Application

### Terminal 1: Start the Server
```bash
zig build chat-server
```

### Terminal 2: Client Streaming Demo
```bash
zig build batch-client
```

### Terminal 3: Server Streaming Demo
```bash
zig build subscriber
```

### Terminal 4: Interactive Chat
```bash
zig build chat-client
```

## Advanced Streaming Patterns

### Stream Flow Control

```zig
// Control message flow in bidirectional streams
var stream = try client.bidirectionalStream(RequestType, ResponseType, "Service/Method");

// Send with flow control
const window_size = 10;
var pending_messages: u32 = 0;

while (pending_messages < window_size) {
    try stream.send(message);
    pending_messages += 1;
}

// Wait for acknowledgments to continue
while (pending_messages > 0) {
    const response = try stream.receive();
    if (response.type == .ack) {
        pending_messages -= 1;
    }
}
```

### Stream Error Handling

```zig
// Robust error handling in streams
while (true) {
    const message = stream.receive() catch |err| switch (err) {
        error.StreamClosed => {
            std.log.info("Stream closed gracefully");
            break;
        },
        error.ConnectionReset => {
            std.log.warn("Connection lost, attempting reconnect...");
            try reconnectAndResumeStream();
            continue;
        },
        error.Timeout => {
            std.log.warn("Message timeout, continuing...");
            continue;
        },
        else => {
            std.log.err("Unrecoverable stream error: {}", .{err});
            return err;
        },
    };

    // Process message...
}
```

### Stream Multiplexing

```zig
// Handle multiple streams concurrently
const StreamHandler = struct {
    fn handleUserStream(user: []const u8, stream: *BidirectionalStream) !void {
        // Handle stream for specific user
    }
};

// Create multiple streams
var streams = std.ArrayList(*BidirectionalStream).init(allocator);
defer streams.deinit();

for (users) |user| {
    const stream = try client.bidirectionalStream(Message, Response, "Chat/JoinChat");
    try streams.append(stream);

    // Handle each stream in a separate thread
    const thread = try std.Thread.spawn(.{}, StreamHandler.handleUserStream, .{ user, stream });
    thread.detach();
}
```

## Performance Considerations

### Stream Buffer Management

```zig
// Optimize stream performance
var stream_config = zrpc.StreamConfig{
    .buffer_size = 64 * 1024,        // 64KB buffer
    .max_buffered_messages = 100,    // Buffer up to 100 messages
    .enable_compression = true,       // Compress large messages
    .compression_threshold = 1024,    // Compress messages > 1KB
};

var client_config = zrpc.ClientConfig{
    .transport = transport,
    .stream_config = stream_config,
};
```

### Memory Management

```zig
// Use arena allocator for request-scoped data
var arena = std.heap.ArenaAllocator.init(allocator);
defer arena.deinit();

const stream_allocator = arena.allocator();

// All stream-related allocations will be freed together
const message = try deserializeMessage(stream_allocator, data);
```

## Testing Streaming RPCs

### Mock Streaming

```zig
test "bidirectional streaming" {
    const mock_transport = @import("zrpc-transport-mock");

    var transport = mock_transport.createClientTransport(testing.allocator);
    defer transport.deinit();

    var client = try zrpc.Client.init(testing.allocator, .{ .transport = transport });
    defer client.deinit();

    // Configure mock responses
    mock_transport.expectBidirectionalStream("Chat/JoinChat", &.{
        .{ .send = message1, .receive = response1 },
        .{ .send = message2, .receive = response2 },
    });

    var stream = try client.bidirectionalStream(Message, Response, "Chat/JoinChat");
    defer stream.close();

    try stream.send(message1);
    const resp1 = try stream.receive();
    try testing.expectEqual(response1, resp1);
}
```

---

**Next**: Continue with the [Authentication Tutorial](auth-tutorial.md) to add security to your streaming applications, or check the [Performance Guide](../guides/performance-tuning.md) for optimization techniques.