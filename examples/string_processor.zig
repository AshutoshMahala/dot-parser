const std = @import("std");
const strings = @import("string_processor");
const City = strings.Profile(.{ .policy = .{ .validation = .{
    .one_of = .{ .values = &.{ "SF", "Seattle" }, .severity = .err },
} } });

pub fn main(init: std.process.Init) !void {
    const source = "Seattle";
    var bag = City.GrowableDiagnosticBag.init(init.gpa, .{});
    defer bag.deinit();
    const result = try City.parseAndValidate(.{ .bytes = source, .origin = 0 }, bag.sink(), .{});
    if (!result.valid()) return error.InvalidCity;

    // Same validator contract, custom settings, and generic failure reporting.
    const Nonempty = strings.validators.Predicate(void, {}, struct {
        fn check(value: anytype, _: void) bool {
            return value.bytes.len != 0;
        }
    }.check);
    const Description = strings.Profile(.{ .custom = Nonempty, .policy = .{ .validation = .{ .custom = .err } } });
    const checked = try Description.parseAndValidate(.{ .bytes = "borrowed contents", .origin = 0 }, Description.Sink.discard, .{});
    if (!checked.valid()) return error.InvalidDescription;
}
