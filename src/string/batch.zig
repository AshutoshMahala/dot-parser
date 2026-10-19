//! Bounded ASCII runs. Each byte is exactly one scalar/credit; non-ASCII,
//! short tails and mismatches fall back without consuming any work.
pub const width = 16;

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
