//! Shared byte-boundary primitives for already validated identifier expressions.
//! No validation, decoding, allocation or extra pass over a complete operand.
//! Offset arguments may be u32 source cursors or native decoder slice indices.

pub fn skipGlue(raw: []const u8, offset: anytype) void {
    while (offset.* < raw.len) switch (raw[offset.*]) {
        '"', '<' => return,
        '#' => skipLine(raw, offset),
        '/' => {
            if (raw[offset.* + 1] == '/') {
                skipLine(raw, offset);
            } else {
                offset.* += 2;
                while (!(raw[offset.*] == '*' and raw[offset.* + 1] == '/')) offset.* += 1;
                offset.* += 2;
            }
        },
        else => offset.* += 1, // validated whitespace or '+'
    };
}

fn skipLine(raw: []const u8, offset: anytype) void {
    while (offset.* < raw.len and raw[offset.*] != '\n' and raw[offset.*] != '\r') offset.* += 1;
}

/// `start` points at the outer '<'; return just past its matching '>'.
pub fn htmlEnd(raw: []const u8, start: anytype) @TypeOf(start) {
    var offset = start + 1;
    var depth: u32 = 1;
    while (depth != 0) : (offset += 1) switch (raw[offset]) {
        '<' => depth += 1,
        '>' => depth -= 1,
        else => {},
    };
    return offset;
}

/// Stop at the next quote or backslash; neither is consumed.
pub fn quotedRunEnd(raw: []const u8, start: anytype) @TypeOf(start) {
    var offset = start;
    while (offset < raw.len and raw[offset] != '"' and raw[offset] != '\\') offset += 1;
    return offset;
}

/// `start` points at a backslash; quoted continuations include the optional LF.
pub fn escapeEnd(raw: []const u8, start: anytype) @TypeOf(start) {
    var offset = start + 2;
    if (raw[start + 1] == '\r' and offset < raw.len and raw[offset] == '\n') offset += 1;
    return offset;
}
