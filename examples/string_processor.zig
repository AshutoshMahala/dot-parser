const std = @import("std");
const strings = @import("string_processor");
const markup = @import("markup_parser");
const dot = @import("dot_parser");
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

    // Built-ins and consumer validators share the resumable contract.
    const Match = struct {
        pub const Settings = []const u8;
        pub const defaults: Settings = "Seattle";
        pub const uses_comparison = true;
        pub fn State(comptime Context: type) type {
            return struct { comparison: Context.ComparisonState = .{} };
        }
        pub fn step(state: anytype, value: anytype, expected: Settings, context: anytype) strings.Step {
            return context.equalsStep(&state.comparison, value, expected);
        }
    };
    const Bounded = strings.Profile(.{ .custom = Match, .policy = .{
        .execution = .{ .metering = true },
        .validation = .{ .custom = .err },
    } });
    var session = try Bounded.Session.init(.{ .bytes = source, .origin = 0 }, Bounded.Sink.discard, .{});
    defer session.deinit();
    while (session.advance(4).outcome == null) {
        // The caller can run other work here before resuming this value.
    }
    if (!session.result().?.valid()) return error.InvalidCity;

    // Explicit host-reader binding: this does not enable automatic attributes.
    // Both spellings below are checked as the logical string "Seattle".
    const Label = City.WithReader(markup.LogicalReader(.utf8));
    const label = try markup.LogicalReader(.utf8).init(.{ .bytes = "Sea&#116;tle", .origin = 100 }, .{});
    if (!(try Label.parseAndValidate(label, bag.sink(), .{})).valid()) return error.InvalidCity;
    const DotName = City.WithReader(dot.identifier.LogicalReader(.utf8));
    const name = try dot.identifier.LogicalReader(.utf8).init(.{ .bytes = "\"Sea\" + \"ttle\"", .origin = 200 });
    if (!(try DotName.parseAndValidate(name, bag.sink(), .{})).valid()) return error.InvalidCity;

    // Automatic attribute routing, one operation and one shared bag.
    const Labels = markup.Profile(.{
        .processors = .{ .string = City },
        .policy = .{ .mode = .structural, .attributes = .{
            .title = .{ .string = .process },
        } },
    });
    const Parser = dot.Profile(.{
        .processors = .{ .string = City, .markup = Labels },
        .policy = .{ .attributes = .{ .label = .{ .string = .process } } },
    });
    var combined_bag = Parser.GrowableDiagnosticBag.init(init.gpa, .{});
    defer combined_bag.deinit();
    var combined = try Parser.parseAndValidate(init.gpa, "graph { a[label=\"Sea\"+\"ttle\"]; b[label=<<x title='S&#70;'/>>] }", combined_bag.sink(), .{});
    defer combined.deinit(init.gpa);
    if (!combined.documentValid()) return error.InvalidCity;
}
