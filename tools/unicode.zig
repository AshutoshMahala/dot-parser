//! Offline Unicode-generation helpers. Not imported by the library.
const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Input = struct { header: []const u8, sha256: []const u8 };
pub const case_folding: Input = .{
    .header = "# CaseFolding-17.0.0.txt",
    .sha256 = "ff8d8fefbf123574205085d6714c36149eb946d717a0c585c27f0f4ef58c4183",
};
pub const east_asian_width: Input = .{
    .header = "# EastAsianWidth-17.0.0.txt",
    .sha256 = "ea7ce50f3444a050333448dffef1cadd9325af55cbb764b4a2280faf52170a33",
};
pub const general_category: Input = .{
    .header = "# DerivedGeneralCategory-17.0.0.txt",
    .sha256 = "d62e5bab70ca74f099343f71224fa051cb1fdd61a1ab45c0488c44cfc0b6102e",
};
pub const license: Input = .{
    .header = "UNICODE LICENSE V3",
    .sha256 = "e7a93b009565cfce55919a381437ac4db883e9da2126fa28b91d12732bc53d96",
};

pub fn verifyInput(bytes: []const u8, expected: Input) !void {
    if (!std.mem.startsWith(u8, bytes, expected.header)) return error.UnexpectedUnicodeVersion;
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    if (!std.mem.eql(u8, &std.fmt.bytesToHex(digest, .lower), expected.sha256))
        return error.UnicodeChecksumMismatch;
}

pub fn readPinned(gpa: Allocator, io: std.Io, path: []const u8, expected: Input) ![]const u8 {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(8 * 1024 * 1024));
    errdefer gpa.free(bytes);
    verifyInput(bytes, expected) catch |err| {
        std.debug.print("{s}: {s}; expected pinned Unicode 17.0.0 input\n", .{ path, @errorName(err) });
        return err;
    };
    return bytes;
}

pub fn trim(bytes: []const u8) []const u8 {
    return std.mem.trim(u8, bytes, " \t\r\n");
}

pub fn codePoint(bytes: []const u8) !u21 {
    const cp = std.fmt.parseInt(u21, trim(bytes), 16) catch return error.InvalidUnicodeData;
    if (cp > 0x10ffff) return error.InvalidUnicodeData;
    return cp;
}

/// No --write option: generation writes stdout; --check only compares a file.
pub fn checkPath(args: []const []const u8, input_count: usize) !?[]const u8 {
    if (args.len == input_count + 1) return null;
    if (args.len == input_count + 3 and std.mem.eql(u8, args[input_count + 1], "--check"))
        return args[input_count + 2];
    return error.InvalidArguments;
}

pub fn format(gpa: Allocator, bytes: []const u8) ![]u8 {
    const source = try gpa.dupeZ(u8, bytes);
    defer gpa.free(source);
    var ast = try std.zig.Ast.parse(gpa, source, .zig);
    defer ast.deinit(gpa);
    if (ast.errors.len != 0) return error.InvalidGeneratedZig;
    return ast.renderAlloc(gpa);
}

pub fn output(gpa: Allocator, io: std.Io, bytes: []const u8, check: ?[]const u8) !void {
    const formatted = try format(gpa, bytes);
    defer gpa.free(formatted);
    if (check) |path| {
        const existing = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(8 * 1024 * 1024));
        defer gpa.free(existing);
        if (!std.mem.eql(u8, existing, formatted)) {
            std.debug.print("{s}: generated Unicode source is out of date\n", .{path});
            return error.GeneratedSourceMismatch;
        }
        return;
    }
    var buffer: [8192]u8 = undefined;
    var writer = std.Io.File.stdout().writer(io, &buffer);
    try writer.interface.writeAll(formatted);
    try writer.interface.flush();
}

test "input pins reject a wrong version and modified bytes" {
    const expected: Input = .{
        .header = "abc",
        .sha256 = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
    };
    try verifyInput("abc", expected);
    try std.testing.expectError(error.UnexpectedUnicodeVersion, verifyInput("xyz", expected));
    try std.testing.expectError(error.UnicodeChecksumMismatch, verifyInput("abcd", expected));
}

test "arguments and generated Zig are checked" {
    try std.testing.expectEqual(null, try checkPath(&.{ "generator", "input" }, 1));
    try std.testing.expectEqualStrings("output", (try checkPath(&.{ "generator", "input", "--check", "output" }, 1)).?);
    try std.testing.expectError(error.InvalidArguments, checkPath(&.{"generator"}, 1));
    try std.testing.expectError(error.InvalidArguments, checkPath(&.{ "generator", "input", "--write", "output" }, 1));
    try std.testing.expectError(error.InvalidGeneratedZig, format(std.testing.allocator, "const = ;"));
    try std.testing.expectError(error.InvalidUnicodeData, codePoint("110000"));
    try std.testing.expectError(error.InvalidUnicodeData, codePoint("no"));
}
