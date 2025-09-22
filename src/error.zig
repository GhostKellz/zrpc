const std = @import("std");

pub const Error = error{
    NotImplemented,
    InvalidArgument,
    DeadlineExceeded,
    NotFound,
    AlreadyExists,
    PermissionDenied,
    ResourceExhausted,
    FailedPrecondition,
    Aborted,
    OutOfRange,
    Unimplemented,
    Internal,
    Unavailable,
    DataLoss,
    Unauthenticated,
    TransportError,
    SerializationError,
    DeserializationError,
    ConnectionClosed,
    NetworkError,
    InvalidState,
    InvalidData,
} || std.mem.Allocator.Error;

pub const StatusCode = enum(u32) {
    ok = 0,
    cancelled = 1,
    unknown = 2,
    invalid_argument = 3,
    deadline_exceeded = 4,
    not_found = 5,
    already_exists = 6,
    permission_denied = 7,
    resource_exhausted = 8,
    failed_precondition = 9,
    aborted = 10,
    out_of_range = 11,
    unimplemented = 12,
    internal = 13,
    unavailable = 14,
    data_loss = 15,
    unauthenticated = 16,
};

pub const Status = struct {
    code: StatusCode,
    message: ?[]const u8 = null,
    details: ?[]const u8 = null,

    pub fn ok() Status {
        return Status{ .code = .ok };
    }

    pub fn notFound(message: ?[]const u8) Status {
        return Status{ .code = .not_found, .message = message };
    }

    pub fn invalidArgument(message: ?[]const u8) Status {
        return Status{ .code = .invalid_argument, .message = message };
    }

    pub fn internal(message: ?[]const u8) Status {
        return Status{ .code = .internal, .message = message };
    }

    pub fn isOk(self: Status) bool {
        return self.code == .ok;
    }

    pub fn toError(self: Status) Error {
        return switch (self.code) {
            .ok => unreachable,
            .cancelled => Error.Aborted,
            .unknown => Error.Internal,
            .invalid_argument => Error.InvalidArgument,
            .deadline_exceeded => Error.DeadlineExceeded,
            .not_found => Error.NotFound,
            .already_exists => Error.AlreadyExists,
            .permission_denied => Error.PermissionDenied,
            .resource_exhausted => Error.ResourceExhausted,
            .failed_precondition => Error.FailedPrecondition,
            .aborted => Error.Aborted,
            .out_of_range => Error.OutOfRange,
            .unimplemented => Error.Unimplemented,
            .internal => Error.Internal,
            .unavailable => Error.Unavailable,
            .data_loss => Error.DataLoss,
            .unauthenticated => Error.Unauthenticated,
        };
    }
};

test "status creation and conversion" {
    const ok_status = Status.ok();
    try std.testing.expect(ok_status.isOk());

    const not_found = Status.notFound("Resource not found");
    try std.testing.expectEqual(StatusCode.not_found, not_found.code);
    try std.testing.expectEqualStrings("Resource not found", not_found.message.?);

    const err = not_found.toError();
    try std.testing.expectEqual(Error.NotFound, err);
}