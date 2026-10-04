//! Bring your own label processor. This one wraps the built-in markup parser
//! and counts the labels it checks; put your own checks in `parseAndValidate`.
const std = @import("std");
const dot = @import("dot_parser");
const markup = @import("markup_parser");

const CountingLabels = struct {
    const Base = markup.Profile(.{ .policy = markup.presets.untrusted });
    pub const Policies = Base.Policies;
    pub const Options = Base.Options;
    pub const Diagnostic = markup.Diagnostic;
    pub const DiagnosticSink = markup.DiagnosticSink;
    pub const InputError = markup.Fragment.Error;
    /// Supplied by the caller as `.markup_resources`.
    pub const ParseResources = struct { checked: ?*u32 = null };
    /// Optional: lets `Parser.console` render this processor's diagnostics.
    pub const console = markup.console;

    pub const Prepared = struct {
        inner: Base.Prepared,
        pub fn initWorkspace(self: @This(), allocator: std.mem.Allocator, resources: ParseResources) Workspace {
            return .{ .inner = self.inner.initWorkspace(allocator, .{}), .checked = resources.checked };
        }
    };

    pub const Workspace = struct {
        inner: Base.Workspace,
        checked: ?*u32,
        pub fn parseAndValidate(self: *@This(), input: markup.Fragment, sink: DiagnosticSink) InputError!markup.FixedFragmentResult {
            if (self.checked) |count| count.* += 1;
            return self.inner.parseAndValidate(input, sink);
        }
        pub fn deinit(self: *@This()) void {
            self.inner.deinit();
        }
    };

    pub fn prepare(options: Options) Prepared {
        return .{ .inner = Base.prepare(options) };
    }
};

const Parser = dot.Profile(.{
    .policy = .{ .limits = .{ .max_nesting = 64, .max_statements = 1000, .max_attributes = 1000 } },
    .processors = .{ .markup = CountingLabels },
});

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const source = "digraph { a [label=<<b>ok</b>>]; b [label=<<i>bad</b>>]; a -> b; }";

    var bag = Parser.GrowableDiagnosticBag.init(allocator, .{});
    defer bag.deinit();
    var checked: u32 = 0;
    var result = try Parser.parseAndValidate(allocator, source, bag.sink(), .{
        .markup_resources = .{ .checked = &checked },
    });
    defer result.deinit(allocator);

    var buffer: [4096]u8 = undefined;
    var output = std.Io.File.Writer.init(.stdout(), init.io, &buffer);
    const writer = &output.interface;
    try writer.print("labels checked: {d}, valid: {d}, whole file valid: {any}\n", .{
        checked, result.markup.valid, result.documentValid(),
    });
    const locations = try allocator.alloc(dot.location.Location, try Parser.console.locationCapacity(bag.items()));
    defer allocator.free(locations);
    try Parser.console.renderBoxedList(bag.items(), 0, .{ .source = source, .source_name = "example.dot" }, locations, writer);
    try writer.flush();
}
