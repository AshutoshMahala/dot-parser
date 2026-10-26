//! Bounded ASCII runs. Each byte is exactly one scalar/credit; non-ASCII,
//! short tails and mismatches fall back without consuming any work.
pub const width = @import("parser_support").logical.ascii_width;

pub inline fn ascii(bytes: []const u8, at: u32) bool {
    if (at >= bytes.len or bytes.len - at < width) return false;
    const block: @Vector(width, u8) = bytes[at..][0..width].*;
    return @reduce(.Or, block) & 0x80 == 0;
}

pub inline fn equalAscii(a: []const u8, ai: u32, b: []const u8, bi: u32) bool {
    if (ai >= a.len or a.len - ai < width or bi >= b.len or b.len - bi < width) return false;
    const left: @Vector(width, u8) = a[ai..][0..width].*;
    const right: @Vector(width, u8) = b[bi..][0..width].*;
    return @reduce(.Or, left | right) & 0x80 == 0 and @reduce(.And, left == right);
}

pub fn equalAsciiIgnoreCase(a: []const u8, ai: u32, b: []const u8, bi: u32) bool {
    if (ai >= a.len or a.len - ai < width or bi >= b.len or b.len - bi < width) return false;
    const left: @Vector(width, u8) = a[ai..][0..width].*;
    const right: @Vector(width, u8) = b[bi..][0..width].*;
    if (@reduce(.Or, left | right) & 0x80 != 0) return false;
    const upper_a: @Vector(width, u8) = @splat('A');
    const upper_z: @Vector(width, u8) = @splat('Z');
    const bit: @Vector(width, u8) = @splat('a' - 'A');
    // Only letters fold: unconditional OR would also equate punctuation.
    const l = @select(u8, (left >= upper_a) & (left <= upper_z), left | bit, left);
    const r = @select(u8, (right >= upper_a) & (right <= upper_z), right | bit, right);
    return @reduce(.And, l == r);
}
