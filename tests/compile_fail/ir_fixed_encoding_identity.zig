const dot = @import("dot_parser");
const Utf8 = dot.ir.Lowering(.{});
const Native = dot.ir.Lowering(.{ .source_encodings = &.{ .utf8, .utf16 } });
export fn rejected() void {
    _ = Native.FixedLoweringScratch(Utf8.FixedGraphStorage(.{}), .{});
}
