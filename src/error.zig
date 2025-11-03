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

    // Constructor helpers for all status codes
    pub fn ok() Status {
        return Status{ .code = .ok };
    }

    pub fn cancelled(message: ?[]const u8) Status {
        return Status{ .code = .cancelled, .message = message };
    }

    pub fn unknown(message: ?[]const u8) Status {
        return Status{ .code = .unknown, .message = message };
    }

    pub fn invalidArgument(message: ?[]const u8) Status {
        return Status{ .code = .invalid_argument, .message = message };
    }

    pub fn deadlineExceeded(message: ?[]const u8) Status {
        return Status{ .code = .deadline_exceeded, .message = message };
    }

    pub fn notFound(message: ?[]const u8) Status {
        return Status{ .code = .not_found, .message = message };
    }

    pub fn alreadyExists(message: ?[]const u8) Status {
        return Status{ .code = .already_exists, .message = message };
    }

    pub fn permissionDenied(message: ?[]const u8) Status {
        return Status{ .code = .permission_denied, .message = message };
    }

    pub fn resourceExhausted(message: ?[]const u8) Status {
        return Status{ .code = .resource_exhausted, .message = message };
    }

    pub fn failedPrecondition(message: ?[]const u8) Status {
        return Status{ .code = .failed_precondition, .message = message };
    }

    pub fn aborted(message: ?[]const u8) Status {
        return Status{ .code = .aborted, .message = message };
    }

    pub fn outOfRange(message: ?[]const u8) Status {
        return Status{ .code = .out_of_range, .message = message };
    }

    pub fn unimplemented(message: ?[]const u8) Status {
        return Status{ .code = .unimplemented, .message = message };
    }

    pub fn internal(message: ?[]const u8) Status {
        return Status{ .code = .internal, .message = message };
    }

    pub fn unavailable(message: ?[]const u8) Status {
        return Status{ .code = .unavailable, .message = message };
    }

    pub fn dataLoss(message: ?[]const u8) Status {
        return Status{ .code = .data_loss, .message = message };
    }

    pub fn unauthenticated(message: ?[]const u8) Status {
        return Status{ .code = .unauthenticated, .message = message };
    }

    pub fn isOk(self: Status) bool {
        return self.code == .ok;
    }

    /// Convert gRPC status code to zRPC error
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

    /// Convert zRPC error to gRPC status code
    pub fn fromError(err: Error) StatusCode {
        return switch (err) {
            Error.InvalidArgument => .invalid_argument,
            Error.DeadlineExceeded => .deadline_exceeded,
            Error.NotFound => .not_found,
            Error.AlreadyExists => .already_exists,
            Error.PermissionDenied => .permission_denied,
            Error.ResourceExhausted => .resource_exhausted,
            Error.FailedPrecondition => .failed_precondition,
            Error.Aborted => .aborted,
            Error.OutOfRange => .out_of_range,
            Error.Unimplemented => .unimplemented,
            Error.Internal => .internal,
            Error.Unavailable => .unavailable,
            Error.DataLoss => .data_loss,
            Error.Unauthenticated => .unauthenticated,
            Error.NotImplemented => .unimplemented,
            Error.TransportError => .unavailable,
            Error.NetworkError => .unavailable,
            Error.ConnectionClosed => .unavailable,
            Error.SerializationError => .internal,
            Error.DeserializationError => .internal,
            Error.InvalidState => .internal,
            Error.InvalidData => .invalid_argument,
            Error.OutOfMemory => .resource_exhausted,
        };
    }

    /// Get human-readable description of status code
    pub fn description(self: Status) []const u8 {
        return switch (self.code) {
            .ok => "Request completed successfully",
            .cancelled => "Operation cancelled by caller",
            .unknown => "Unknown error occurred",
            .invalid_argument => "Client specified invalid argument",
            .deadline_exceeded => "Deadline expired before operation completed",
            .not_found => "Requested resource not found",
            .already_exists => "Resource already exists",
            .permission_denied => "Caller lacks permission for operation",
            .resource_exhausted => "Resource quota exceeded or out of space",
            .failed_precondition => "System not in required state for operation",
            .aborted => "Operation aborted due to concurrent modification",
            .out_of_range => "Operation attempted past valid range",
            .unimplemented => "Operation not implemented or supported",
            .internal => "Internal server error",
            .unavailable => "Service unavailable, try again later",
            .data_loss => "Unrecoverable data loss or corruption",
            .unauthenticated => "Authentication required but missing or invalid",
        };
    }

    /// Parse gRPC status code from integer
    pub fn fromInt(code: u32) ?StatusCode {
        return std.meta.intToEnum(StatusCode, code) catch null;
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