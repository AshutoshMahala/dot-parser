//! WDP 0.1.0-draft Level 2 identity hashing. Registries and payloads are
//! processor-owned. Existing DOT official-vector tests cover these algorithms.
const std = @import("std");
const base62_alphabet = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz";

fn base62Encode(hash: u64) [5]u8 {
    var value = hash & 0xFF_FFFF_FFFF;
    var out: [5]u8 = undefined;
    var i: usize = 5;
    while (i > 0) {
        i -= 1;
        out[i] = base62_alphabet[@intCast(value % 62)];
        value /= 62;
    }
    return out;
}

/// WDP part 5 compact ID: uppercase the display-form code (at most 64 bytes).
/// Registries compute this at comptime.
pub fn computeCompactId(code_text: []const u8) [5]u8 {
    // "wdp-v1", zero-padded to 8 bytes, little-endian (WDP part 5 §4.5).
    const wdp_seed: u64 = 0x000031762D706477;
    var upper_buf: [64]u8 = undefined;
    std.debug.assert(code_text.len <= upper_buf.len);
    for (code_text, 0..) |byte, i| upper_buf[i] = std.ascii.toUpper(byte);
    return base62Encode(std.hash.XxHash3.hash(wdp_seed, upper_buf[0..code_text.len]));
}

/// WDP part 7: hash namespaces as-is, without code-style uppercasing.
pub fn computeNamespaceHash(namespace_text: []const u8) [5]u8 {
    // "wdpns-v1", little-endian; distinct from the part 5 code seed.
    const wdpns_seed: u64 = 0x31762D736E706477;
    return base62Encode(std.hash.XxHash3.hash(wdpns_seed, namespace_text));
}
