//! Constant-time observations of already consumed token prefixes. No scan,
//! decoding, repair or source read: classification belongs to the scanner.
const location = @import("parser_support").location;

pub const Kind = enum { word, numeral, quoted, html, concatenation };
pub const Snapshot = struct { span: location.Span, kind: Kind };

pub fn unfinished(scanner: anytype, comptime eof: bool) ?Snapshot {
    const T = @typeInfo(@TypeOf(scanner)).pointer.child;
    const enc = @import("parser_support").encoding.Reader(T.source_encoding);
    var end = scanner.cursor;
    var kind: Kind = undefined;
    if (eof) {
        kind = switch (scanner.terminal) {
            .quote => .quoted,
            .html_unterminated => .html,
            .concat => if (scanner.found == null) .concatenation else return null,
            else => return null,
        };
        // A terminal failure rewinds cursor to anchor; the EOF failures above
        // prove that the complete source was examined before that rewind.
        end = @intCast(enc.units(scanner.source));
    } else {
        if (scanner.terminal != .none) return null;
        kind = if (@hasField(T, "mode")) switch (scanner.mode) {
            .quoted => .quoted,
            .html => .html,
            .ident => .word,
            .numeral => .numeral,
            .trivia => switch (scanner.trivia) {
                .after_plus => .concatenation,
                .after_part => blk: {
                    end = scanner.part_end;
                    break :blk if (scanner.flags.has_html) Kind.html else Kind.quoted;
                },
                .ordinary => return null,
            },
            else => return null,
        } else switch (scanner.state) {
            .quoted, .escape => .quoted,
            .html => .html,
            .bare => .word,
            .leading_dot, .integral, .fraction => .numeral,
            .trivia => switch (scanner.trivia) {
                .after_plus => .concatenation,
                .after_part => blk: {
                    end = scanner.part_end;
                    break :blk if (scanner.flags.has_html) Kind.html else Kind.quoted;
                },
                .ordinary => return null,
            },
            else => return null,
        };
    }
    if (end <= scanner.anchor) return null;
    if (scanner.flags.concatenated) kind = .concatenation;
    return .{ .span = .{ .start = scanner.anchor * enc.width, .len = (end - scanner.anchor) * enc.width }, .kind = kind };
}
