const dot = @import("dot_parser");
comptime {
    const options: dot.GrowableDiagnosticBag.Options = .{ .max_entries = .{ .limited = 65_536 } };
    _ = options;
}
