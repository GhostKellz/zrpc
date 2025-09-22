const std = @import("std");
const Error = @import("error.zig").Error;
const transport = @import("transport.zig");

pub fn Stream(comptime T: type) type {
    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        connection: *transport.Http2Connection,
        stream_id: transport.StreamId,
        is_closed: bool,
        buffer: std.ArrayList(T),

        pub fn init(allocator: std.mem.Allocator, connection: *transport.Http2Connection, stream_id: transport.StreamId) Self {
            return Self{
                .allocator = allocator,
                .connection = connection,
                .stream_id = stream_id,
                .is_closed = false,
                .buffer = std.ArrayList(T).empty,
            };
        }

        pub fn deinit(self: *Self) void {
            self.buffer.deinit(self.allocator);
        }

        pub fn send(self: *Self, message: T) Error!void {
            if (self.is_closed) {
                return Error.ConnectionClosed;
            }

            // Serialize message
            const codec = @import("codec.zig");
            const data = try codec.ProtobufCodec.encode(self.allocator, message);
            defer self.allocator.free(data);

            // Send as HTTP/2 data frame
            const frame = transport.Frame{
                .stream_id = self.stream_id,
                .frame_type = .data,
                .flags = 0, // Not END_STREAM yet
                .data = data,
            };

            try self.connection.sendFrame(frame);
        }

        pub fn receive(self: *Self) Error!?T {
            if (self.is_closed) {
                return null;
            }

            // Check buffer first
            if (self.buffer.items.len > 0) {
                return self.buffer.orderedRemove(0);
            }

            // Read from connection
            const frame = self.connection.readFrame() catch |err| {
                if (err == Error.NetworkError) {
                    self.is_closed = true;
                    return null;
                }
                return err;
            };

            if (frame.stream_id != self.stream_id) {
                // Frame for different stream, ignore for now
                return null;
            }

            if (frame.frame_type == .data) {
                if ((frame.flags & transport.Frame.Flags.END_STREAM) != 0) {
                    self.is_closed = true;
                }

                if (frame.data.len > 0) {
                    const codec = @import("codec.zig");
                    const message = codec.ProtobufCodec.decode(self.allocator, frame.data, T) catch {
                        return Error.DeserializationError;
                    };
                    return message;
                }
            }

            return null;
        }

        pub fn close(self: *Self) Error!void {
            if (self.is_closed) {
                return;
            }

            // Send empty data frame with END_STREAM flag
            const frame = transport.Frame{
                .stream_id = self.stream_id,
                .frame_type = .data,
                .flags = transport.Frame.Flags.END_STREAM,
                .data = &[_]u8{},
            };

            try self.connection.sendFrame(frame);
            self.is_closed = true;
        }

        pub fn isClosed(self: Self) bool {
            return self.is_closed;
        }
    };
}

pub fn ClientStream(comptime RequestType: type, comptime ResponseType: type) type {
    return struct {
        const Self = @This();

        request_stream: Stream(RequestType),
        response_future: ?ResponseType,
        allocator: std.mem.Allocator,

        pub fn init(allocator: std.mem.Allocator, connection: *transport.Http2Connection, stream_id: transport.StreamId) Self {
            return Self{
                .request_stream = Stream(RequestType).init(allocator, connection, stream_id),
                .response_future = null,
                .allocator = allocator,
            };
        }

        pub fn deinit(self: *Self) void {
            self.request_stream.deinit();
        }

        pub fn send(self: *Self, request: RequestType) Error!void {
            return self.request_stream.send(request);
        }

        pub fn finish(self: *Self) Error!ResponseType {
            try self.request_stream.close();

            // Wait for response (simplified)
            while (!self.request_stream.isClosed()) {
                std.Thread.sleep(1000000); // 1ms
            }

            // Mock response for now
            return @as(Error!ResponseType, Error.NotImplemented);
        }
    };
}

pub fn ServerStream(comptime RequestType: type, comptime ResponseType: type) type {
    return struct {
        const Self = @This();

        response_stream: Stream(ResponseType),
        initial_request: RequestType,
        allocator: std.mem.Allocator,

        pub fn init(allocator: std.mem.Allocator, connection: *transport.Http2Connection, stream_id: transport.StreamId, initial_request: RequestType) Self {
            return Self{
                .response_stream = Stream(ResponseType).init(allocator, connection, stream_id),
                .initial_request = initial_request,
                .allocator = allocator,
            };
        }

        pub fn deinit(self: *Self) void {
            self.response_stream.deinit();
        }

        pub fn send(self: *Self, response: ResponseType) Error!void {
            return self.response_stream.send(response);
        }

        pub fn finish(self: *Self) Error!void {
            return self.response_stream.close();
        }

        pub fn getInitialRequest(self: Self) RequestType {
            return self.initial_request;
        }
    };
}

pub fn BidirectionalStream(comptime RequestType: type, comptime ResponseType: type) type {
    return struct {
        const Self = @This();

        request_stream: Stream(RequestType),
        response_stream: Stream(ResponseType),
        allocator: std.mem.Allocator,

        pub fn init(allocator: std.mem.Allocator, connection: *transport.Http2Connection, stream_id: transport.StreamId) Self {
            return Self{
                .request_stream = Stream(RequestType).init(allocator, connection, stream_id),
                .response_stream = Stream(ResponseType).init(allocator, connection, stream_id),
                .allocator = allocator,
            };
        }

        pub fn deinit(self: *Self) void {
            self.request_stream.deinit();
            self.response_stream.deinit();
        }

        pub fn sendRequest(self: *Self, request: RequestType) Error!void {
            return self.request_stream.send(request);
        }

        pub fn receiveRequest(self: *Self) Error!?RequestType {
            return self.request_stream.receive();
        }

        pub fn sendResponse(self: *Self, response: ResponseType) Error!void {
            return self.response_stream.send(response);
        }

        pub fn receiveResponse(self: *Self) Error!?ResponseType {
            return self.response_stream.receive();
        }

        pub fn closeRequests(self: *Self) Error!void {
            return self.request_stream.close();
        }

        pub fn closeResponses(self: *Self) Error!void {
            return self.response_stream.close();
        }

        pub fn isClosed(self: Self) bool {
            return self.request_stream.isClosed() and self.response_stream.isClosed();
        }
    };
}

test "stream creation" {
    const TestMessage = struct {
        id: u32,
        data: []const u8,
    };

    var mock_connection = transport.Http2Connection.initClient(std.testing.allocator, undefined);
    var stream = Stream(TestMessage).init(std.testing.allocator, &mock_connection, 1);
    defer stream.deinit();

    try std.testing.expectEqual(@as(transport.StreamId, 1), stream.stream_id);
    try std.testing.expectEqual(false, stream.is_closed);
}

test "bidirectional stream" {
    const RequestType = struct {
        query: []const u8,
    };

    const ResponseType = struct {
        result: u32,
    };

    var mock_connection = transport.Http2Connection.initClient(std.testing.allocator, undefined);
    var bidir_stream = BidirectionalStream(RequestType, ResponseType).init(std.testing.allocator, &mock_connection, 1);
    defer bidir_stream.deinit();

    try std.testing.expectEqual(false, bidir_stream.isClosed());
}