const support = @import("parser_support");
const diagnostic = @import("diagnostic.zig");
const common = support.console;
pub fn For(comptime Custom: type) type {
    const D = diagnostic.For(Custom).Diagnostic;
    return common.Renderer(struct {
        pub const Item = D;
        pub const registry = diagnostic;
        pub const Role = enum { related };
        pub const Annotations = common.Annotations(Role, 1);
        pub fn headline(d: D, _: *common.Positions, writer: anytype) !void {
            if (@hasDecl(Custom, "message")) {
                if (d.detail) |info| return Custom.message(info, writer);
            }
            try writer.writeAll(d.code.info().summary);
        }
        pub fn hasDetails(_: D) bool {
            return false;
        }
        pub fn detail(_: D, _: *common.Positions, _: anytype) !void {}
        pub fn hasNote(d: D) bool {
            return d.related != null;
        }
        pub fn note(d: D, positions: *common.Positions, writer: anytype) !void {
            try writer.writeAll("related value at ");
            try positions.writeColonForm(d.related.?.start, writer);
        }
        pub fn hint(d: D, _: *common.Positions, writer: anytype) !void {
            if (@hasDecl(Custom, "hint")) {
                if (d.detail) |info| return Custom.hint(info, writer);
            }
            try writer.writeAll(d.code.info().hint);
        }
        pub fn fix(d: D) ?diagnostic.Fix {
            return d.fix;
        }
        pub fn annotations(d: D) Annotations {
            var list: Annotations = .{};
            if (d.related) |span| list.add(.{ .span = span, .primary = false, .role = .related });
            return list;
        }
        pub fn primaryLabel(d: D, p: *common.Positions, writer: anytype) !void {
            try headline(d, p, writer);
        }
        pub fn secondaryLabel(_: D, _: Role, writer: anytype) !void {
            try writer.writeAll("related value");
        }
    });
}
