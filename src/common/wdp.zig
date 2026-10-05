//! WDP 0.1.0-draft Level 2 metadata and identity construction. Registries and
//! payloads are processor-owned; parsers never need a runtime catalog service.
const std = @import("std");
const Severity = @import("reporting.zig").Severity;
const base62_alphabet = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz";

/// A sequence number and meaning are one definition, never independent fields.
pub const SequenceDefinition = struct { number: u16, alias: []const u8 };
pub const Sequence = struct {
    pub const missing: SequenceDefinition = .{ .number = 1, .alias = "MISSING" };
    pub const mismatch: SequenceDefinition = .{ .number = 2, .alias = "MISMATCH" };
    pub const invalid: SequenceDefinition = .{ .number = 3, .alias = "INVALID" };
    pub const duplicate: SequenceDefinition = .{ .number = 6, .alias = "DUPLICATE" };
    pub const unsupported: SequenceDefinition = .{ .number = 9, .alias = "UNSUPPORTED" };
    pub const exhausted: SequenceDefinition = .{ .number = 26, .alias = "EXHAUSTED" };
};

/// Typed, static metadata. Processors own their component/primary enums and
/// wording; each enum provides name() for its WDP display spelling.
pub fn Catalog(comptime Component: type, comptime Primary: type) type {
    return struct {
        pub const Definition = struct {
            severity: Severity,
            component: Component,
            primary: Primary,
            /// Number and conventional/project-specific alias are paired.
            sequence: SequenceDefinition,
            /// Static fallback wording, not retained in diagnostic values.
            summary: []const u8,
            hint: []const u8,

            pub fn info(self: @This()) Info {
                return .{
                    .severity = self.severity,
                    .component = self.component,
                    .primary = self.primary,
                    .sequence = self.sequence.number,
                    .alias = self.sequence.alias,
                    .summary = self.summary,
                    .hint = self.hint,
                };
            }
        };
        pub const Info = struct {
            severity: Severity,
            component: Component,
            primary: Primary,
            /// WDP sequence, 1–999.
            sequence: u16,
            alias: []const u8,
            /// Renderers may refine these static fallbacks with typed details.
            summary: []const u8,
            hint: []const u8,
        };
    };
}

/// Compile-time identity construction from a processor's Code.info(). No
/// runtime formatting/hashing or universal registry is needed by a parser.
pub fn Registry(comptime Code: type, comptime namespace: []const u8) type {
    return struct {
        /// Severity-only consumers do not reference runtime message metadata.
        pub fn severity(code: Code) Severity {
            return switch (code) {
                inline else => |value| comptime value.info().severity,
            };
        }
        pub fn structured(code: Code) []const u8 {
            return switch (code) {
                inline else => |value| comptime text(value),
            };
        }
        fn text(comptime code: Code) []const u8 {
            const info = code.info();
            return std.fmt.comptimePrint("{c}.{s}.{s}.{d:0>3}", .{
                info.severity.letter(), info.component.name(), info.primary.name(), info.sequence,
            });
        }
        pub fn compactId(code: Code) [5]u8 {
            @setEvalBranchQuota(10000);
            return switch (code) {
                inline else => |value| comptime computeCompactId(text(value)),
            };
        }
        /// Namespace hash, '-', then code hash. No runtime hashing.
        pub fn qualifiedCompactId(code: Code) [11]u8 {
            @setEvalBranchQuota(10000);
            return switch (code) {
                inline else => |value| comptime computeNamespaceHash(namespace) ++ "-".* ++ compactId(value),
            };
        }

        /// Call at comptime in each registry: drift and collisions are build
        /// errors, including for consumers that do not run the library tests.
        pub fn validate() void {
            @setEvalBranchQuota(200000);
            if (namespace.len == 0 or namespace.len > 16 or !std.ascii.isLower(namespace[0]))
                @compileError("invalid diagnostic namespace");
            for (namespace) |byte| {
                if (!std.ascii.isLower(byte) and !std.ascii.isDigit(byte) and byte != '_')
                    @compileError("invalid diagnostic namespace");
            }
            const codes = std.enums.values(Code);
            var identities: [codes.len][]const u8 = undefined;
            var hashes: [codes.len][5]u8 = undefined;
            for (codes, 0..) |a, i| {
                const info = a.info();
                identities[i] = text(a);
                if (info.sequence == 0 or info.sequence > 999 or info.alias.len == 0 or
                    info.summary.len == 0 or info.hint.len == 0 or identities[i].len > 64)
                    @compileError("invalid diagnostic registry metadata");
                hashes[i] = computeCompactId(identities[i]);
                if (!validName(info.component.name()) or !validName(info.primary.name()) or
                    std.mem.eql(u8, info.component.name(), info.primary.name()))
                    @compileError("invalid diagnostic component or primary");
                if (!std.ascii.isUpper(info.alias[0])) @compileError("invalid diagnostic sequence alias");
                for (info.alias) |byte| {
                    if (!std.ascii.isUpper(byte) and !std.ascii.isDigit(byte) and byte != '_')
                        @compileError("invalid diagnostic sequence alias");
                }
                for (0..i) |j| {
                    if (std.mem.eql(u8, identities[i], identities[j])) @compileError("duplicate diagnostic identity");
                    if (std.mem.eql(u8, &hashes[i], &hashes[j])) @compileError("diagnostic compact-ID collision");
                }
            }
        }
    };
}

fn validName(name: []const u8) bool {
    if (name.len == 0 or name.len > 16 or !std.ascii.isUpper(name[0])) return false;
    for (name[1..]) |byte| if (!std.ascii.isAlphanumeric(byte)) return false;
    return true;
}

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
