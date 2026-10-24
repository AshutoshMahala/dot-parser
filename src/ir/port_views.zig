//! On-demand port views: written structure and Graphviz's first-colon reading
//! are separate. No shape lookup, label parsing, allocation or retained index.
const std = @import("std");
const attrs = @import("attributes.zig");
const ports = @import("ports.zig");
const r = @import("resources.zig");
const PortSyntax = @import("../dot/syntax.zig").PortSyntax;
const Range = @import("parser_support").location.Range;

/// `automatic` is the `_` spelling. Recognition is case-sensitive, and does
/// not prove that a name refers to a compass rather than a shape-defined port.
pub const Compass = enum { n, ne, e, se, s, sw, w, nw, c, automatic };

pub fn For(comptime Graph: type) type {
    return struct {
        pub const Port = struct {
            graph: *const Graph,
            resolved: attrs.Resolved,

            pub fn value(self: Port) Graph.ValueView {
                return self.graph.attributeValue(self.resolved);
            }
            /// Only the winning endpoint contribution has syntax. An implicit
            /// empty may cite the key's introduction, but is not that suffix.
            pub fn syntax(self: Port) ?Syntax {
                if (self.resolved.value != .port) return null;
                return .{ .graph = self.graph, .spans = ports.syntax(self.graph, self.resolved.value.port) };
            }
            /// Split logical output at the first colon, without changing syntax
            /// or resolving layout. Linear in one value, allocation-free.
            pub fn graphvizParts(self: Port) GraphvizParts {
                var split: Splitter = .{};
                self.value().writeLogical(&split) catch unreachable;
                return .{ .value = self.value(), .colon = split.colon };
            }
            pub fn graphvizPartsWith(self: Port, options: r.Options) r.Error!GraphvizParts {
                var split: Splitter = .{};
                try self.value().writeLogicalWith(&split, options);
                return .{ .value = self.value(), .colon = split.colon };
            }
        };

        pub const Syntax = struct {
            graph: *const Graph,
            /// Source-byte ranges, in the source encoding, not decoded offsets.
            spans: PortSyntax,

            pub fn span(self: Syntax) Range {
                return ports.span(self.spans);
            }
            pub fn raw(self: Syntax) []const u8 {
                return self.graph.text(self.span());
            }
            /// The first identifier remains ambiguous: `n` may name a port.
            /// `<p>` is the identifier `p`, not a markup subtree.
            pub fn first(self: Syntax) Text {
                return .{ .value = .{ .graph = self.graph, .selected = .{ .written = self.spans.first } } };
            }
            pub fn second(self: Syntax) ?Text {
                const range = self.spans.second orelse return null;
                return .{ .value = .{ .graph = self.graph, .selected = .{ .written = range } } };
            }
            pub fn compass(self: Syntax) CompassStatus {
                return status(self.second());
            }
            pub fn compassWith(self: Syntax, options: r.Options) r.Error!CompassStatus {
                return statusWith(self.second(), self.graph, options);
            }
        };

        pub const GraphvizParts = struct {
            value: Graph.ValueView,
            // Logical output offsets need not fit a source u32: native input
            // can expand to UTF-8. These are never exposed as source locations.
            colon: ?u64,

            /// Text before the first colon, including an empty name. This does
            /// not assert that a shape actually defines that port.
            pub fn name(self: GraphvizParts) Text {
                return .{ .value = self.value, .end = self.colon };
            }
            pub fn compassText(self: GraphvizParts) ?Text {
                const colon = self.colon orelse return null;
                return .{ .value = self.value, .start = colon + 1 };
            }
            pub fn compass(self: GraphvizParts) CompassStatus {
                return status(self.compassText());
            }
            pub fn compassWith(self: GraphvizParts, options: r.Options) r.Error!CompassStatus {
                return statusWith(self.compassText(), self.value.graph, options);
            }
            /// A lone name can be a compass candidate. Graphviz prefers an
            /// existing shape-defined port; this helper does not resolve that.
            pub fn asCompass(self: GraphvizParts) ?Compass {
                return if (self.colon == null) self.name().asCompass() else null;
            }
            pub fn asCompassWith(self: GraphvizParts, options: r.Options) r.Error!?Compass {
                if (self.colon == null) return self.name().asCompassWith(options);
                _ = try r.Work.init(options.limits orelse self.value.graph.limits, options.cancellation);
                return null;
            }
        };

        pub const CompassStatus = union(enum) {
            absent,
            recognized: Compass,
            /// Preserve unsupported/empty suffixes instead of calling them absent.
            unrecognized: Text,
        };

        fn status(text: ?Text) CompassStatus {
            const selected = text orelse return .absent;
            return if (selected.asCompass()) |found| .{ .recognized = found } else .{ .unrecognized = selected };
        }
        fn statusWith(text: ?Text, graph: *const Graph, options: r.Options) r.Error!CompassStatus {
            const selected = text orelse {
                _ = try r.Work.init(options.limits orelse graph.limits, options.cancellation);
                return .absent;
            };
            return if (try selected.asCompassWith(options)) |found| .{ .recognized = found } else .{ .unrecognized = selected };
        }

        /// A borrowed logical text window, not a source span or markup value.
        /// Formatting re-reads the underlying value; there is no decoded cache.
        pub const Text = struct {
            value: Graph.ValueView,
            start: u64 = 0,
            end: ?u64 = null,

            pub fn format(self: Text, writer: *std.Io.Writer) std.Io.Writer.Error!void {
                return self.writeLogical(writer);
            }
            pub fn writeLogical(self: Text, writer: anytype) !void {
                var window: Window(@TypeOf(writer)) = .{ .writer = writer, .start = self.start, .end = self.end };
                try self.value.writeLogical(&window);
            }
            pub fn writeLogicalWith(self: Text, writer: anytype, options: r.Options) !void {
                var window: Window(@TypeOf(writer)) = .{ .writer = writer, .start = self.start, .end = self.end };
                try self.value.writeLogicalWith(&window, options);
            }
            pub fn asCompass(self: Text) ?Compass {
                var candidate: Candidate = .{};
                self.writeLogical(&candidate) catch unreachable;
                return candidate.get();
            }
            pub fn asCompassWith(self: Text, options: r.Options) r.Error!?Compass {
                var candidate: Candidate = .{};
                try self.writeLogicalWith(&candidate, options);
                return candidate.get();
            }
        };
    };
}

const Splitter = struct {
    offset: u64 = 0,
    colon: ?u64 = null,
    pub fn writeAll(self: *Splitter, bytes: []const u8) error{}!void {
        if (self.colon == null) if (std.mem.indexOfScalar(u8, bytes, ':')) |at| {
            self.colon = self.offset + at;
        };
        self.offset += bytes.len;
    }
};

fn Window(comptime Writer: type) type {
    return struct {
        writer: Writer,
        start: u64,
        end: ?u64,
        offset: u64 = 0,
        pub fn writeAll(self: *@This(), bytes: []const u8) !void {
            const begin = self.offset;
            self.offset += bytes.len;
            const lo = @max(begin, self.start);
            const hi = @min(self.offset, self.end orelse self.offset);
            if (lo < hi) try self.writer.writeAll(bytes[@intCast(lo - begin)..@intCast(hi - begin)]);
        }
    };
}

const Candidate = struct {
    bytes: [2]u8 = undefined,
    len: u2 = 0,
    overflow: bool = false,
    pub fn writeAll(self: *Candidate, bytes: []const u8) error{}!void {
        if (self.overflow) return;
        if (bytes.len > self.bytes.len - self.len) {
            self.overflow = true;
            return;
        }
        @memcpy(self.bytes[self.len..][0..bytes.len], bytes);
        self.len += @intCast(bytes.len);
    }
    fn get(self: Candidate) ?Compass {
        if (self.overflow) return null;
        const text = self.bytes[0..self.len];
        inline for (std.meta.tags(Compass)) |tag| {
            const spelling = if (tag == .automatic) "_" else @tagName(tag);
            if (std.mem.eql(u8, text, spelling)) return tag;
        }
        return null;
    }
};
