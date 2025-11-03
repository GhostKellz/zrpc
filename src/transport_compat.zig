// Backward compatibility wrapper for old transport.zig API
// This allows adapters to access Message, Frame, StreamId etc.
pub const transport = @import("transport.zig");
pub usingnamespace transport;
