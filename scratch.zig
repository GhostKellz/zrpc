const std = @import("std");

test "arraylist init" {
    const Buf = std.ArrayList(u8);
    @compileLog(@hasDecl(Buf, "init"));
}
