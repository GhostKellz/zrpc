//! Transport types compatibility layer
//! Exports Message, Frame, StreamId for transport adapters

const transport = @import("transport.zig");

pub const Message = transport.Message;
pub const Frame = transport.Frame;
pub const StreamId = transport.StreamId;
pub const Metadata = transport.Metadata;
pub const Context = transport.Context;
