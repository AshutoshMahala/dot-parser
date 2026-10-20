const dot = @import("dot_parser");
const Consumer = struct {
    pub const wants_early_events = 1;
    pub fn onEvent(_: *@This(), _: dot.events.Event) error{}!dot.events.Action {
        return .proceed;
    }
    pub fn onAbort(_: *@This(), _: dot.events.Abort) void {}
};
comptime {
    _ = dot.Events(Consumer);
}
