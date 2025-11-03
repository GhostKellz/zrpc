// Compatibility layer for old transport API
pub const transport = @import("../../transport.zig");
pub const Message = transport.Message;
pub const Frame = transport.Frame;
pub const StreamId = transport.StreamId;
