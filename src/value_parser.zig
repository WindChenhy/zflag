//! Value parsing utilities for zflag.
//!
//! Provides functions to convert string representations into Zig types
//! and to compute Levenshtein distances for fuzzy option name matching.

const std = @import("std");

/// Parse a string value into the specified type `T`.
///
/// Supported built-in types: bool, integers, floats, enums, strings.
/// Custom struct, union, and enum types can implement `parseFromArg(str: []const u8) !T`
/// to override the default behaviour.
pub fn parseValue(comptime T: type, str: []const u8) !T {
    // Check for a user-defined parseFromArg on struct, union, or enum types.
    const type_info = @typeInfo(T);
    if (type_info == .@"struct" or type_info == .@"union" or type_info == .@"enum") {
        if (@hasDecl(T, "parseFromArg")) {
            return T.parseFromArg(str);
        }
    }

    return switch (type_info) {
        .bool => parseBool(str),
        .int => std.fmt.parseInt(T, str, 10),
        .float => std.fmt.parseFloat(T, str),
        .@"enum" => parseEnum(T, str),
        .pointer => |ptr_info| {
            // `[]const u8` — return the string as-is.
            if (ptr_info.size == .slice and ptr_info.child == u8) {
                return str;
            }
            // `[]const []const u8` — string lists are handled via appendToStringList,
            // not through parseValue; reject here.
            if (ptr_info.size == .slice) {
                const child_type = ptr_info.child;
                const child_info = @typeInfo(child_type);
                if (child_info == .pointer and child_info.pointer.size == .slice and child_info.pointer.child == u8) {
                    return error.InvalidArgumentValue;
                }
            }
            return error.InvalidArgumentValue;
        },
        .array => |array_info| {
            // Fixed-size string arrays (`[N][]const u8`) are handled via setFieldFromArg,
            // not through parseValue; reject here.
            const child_type = array_info.child;
            const child_info = @typeInfo(child_type);
            if (child_info == .pointer and child_info.pointer.size == .slice and child_info.pointer.child == u8) {
                return error.InvalidArgumentValue;
            }
            return error.InvalidArgumentValue;
        },
        else => error.InvalidArgumentValue,
    };
}

/// Append a string value to a string list (`[]const []const u8`).
///
/// Allocates a new array on the heap, copies over existing items, appends the
/// new string, and frees the previous allocation if it was heap-allocated.
pub fn appendToStringList(comptime T: type, list: *[]const []const u8, str: []const u8, allocator: std.mem.Allocator) !void {
    const type_info = @typeInfo(T);
    if (type_info != .pointer or type_info.pointer.size != .slice) return error.InvalidArgumentValue;

    var new_list = try allocator.alloc([]const u8, list.len + 1);
    for (list.*, 0..) |item, i| {
        new_list[i] = item;
    }
    new_list[list.len] = str;
    if (list.len > 0) {
        allocator.free(list.*);
    }
    list.* = new_list;
}

/// Parse a boolean value from a string.
///
/// Accepted truthy values: "true", "1", "yes".
/// Accepted falsy values: "false", "0", "no".
fn parseBool(str: []const u8) !bool {
    if (std.mem.eql(u8, str, "true") or std.mem.eql(u8, str, "1") or std.mem.eql(u8, str, "yes")) {
        return true;
    }
    if (std.mem.eql(u8, str, "false") or std.mem.eql(u8, str, "0") or std.mem.eql(u8, str, "no")) {
        return false;
    }
    return error.InvalidArgumentValue;
}

/// Parse an enum value from a string by matching the string against the
/// enum field names (case-sensitive).
fn parseEnum(comptime T: type, str: []const u8) !T {
    const enum_info = @typeInfo(T).@"enum";
    inline for (enum_info.fields) |field| {
        if (std.mem.eql(u8, str, field.name)) {
            return @enumFromInt(field.value);
        }
    }
    return error.InvalidArgumentValue;
}

/// Compute the Levenshtein edit distance between two strings.
///
/// Uses a space-optimized two-row dynamic programming approach.
/// Strings longer than 256 characters return the sum of their lengths as an
/// upper bound to avoid excessive stack usage.
pub fn levenshteinDistance(a: []const u8, b: []const u8) usize {
    if (a.len == 0) return b.len;
    if (b.len == 0) return a.len;
    if (a.len > 256 or b.len > 256) return a.len + b.len;

    var dp: [514]usize = undefined;
    const m = b.len + 1;

    for (0..m) |i| {
        dp[i] = i;
    }

    for (0..a.len) |i| {
        const curr_row = ((i + 1) % 2) * m;
        const prev_row = (i % 2) * m;
        dp[curr_row] = i + 1;
        for (0..b.len) |j| {
            const cost: usize = if (a[i] == b[j]) 0 else 1;
            dp[curr_row + j + 1] = @min(
                dp[prev_row + j + 1] + 1,
                dp[curr_row + j] + 1,
                dp[prev_row + j] + cost,
            );
        }
    }

    return dp[(a.len % 2) * m + b.len];
}

/// Find the closest matching option from a list of candidates using
/// Levenshtein distance.
///
/// Returns the candidate with the smallest edit distance, provided it is
/// within `max_distance`. Returns `null` if no candidate is close enough.
pub fn findClosestOption(input: []const u8, candidates: []const []const u8, max_distance: usize) ?[]const u8 {
    var best_dist: usize = std.math.maxInt(usize);
    var best_match: ?[]const u8 = null;

    for (candidates) |candidate| {
        const dist = levenshteinDistance(input, candidate);
        if (dist < best_dist and dist <= max_distance) {
            best_dist = dist;
            best_match = candidate;
        }
    }

    return best_match;
}

// ======================== Tests ========================

test "parseBool" {
    try std.testing.expect(try parseValue(bool, "true"));
    try std.testing.expect(try parseValue(bool, "1"));
    try std.testing.expect(try parseValue(bool, "yes"));
    try std.testing.expect(!try parseValue(bool, "false"));
    try std.testing.expect(!try parseValue(bool, "0"));
    try std.testing.expect(!try parseValue(bool, "no"));
}

test "parseInt" {
    try std.testing.expectEqual(@as(u16, 8080), try parseValue(u16, "8080"));
    try std.testing.expectEqual(@as(i32, -42), try parseValue(i32, "-42"));
    try std.testing.expectEqual(@as(u8, 255), try parseValue(u8, "255"));
}

test "parseFloat" {
    try std.testing.expectEqual(@as(f64, 3.14), try parseValue(f64, "3.14"));
    try std.testing.expectEqual(@as(f32, 0.5), try parseValue(f32, "0.5"));
}

test "parseString" {
    const result = try parseValue([]const u8, "hello");
    try std.testing.expectEqualStrings("hello", result);
}

test "parseEnum" {
    const Color = enum { red, green, blue };
    try std.testing.expectEqual(Color.red, try parseValue(Color, "red"));
    try std.testing.expectEqual(Color.green, try parseValue(Color, "green"));
    try std.testing.expectError(error.InvalidArgumentValue, parseValue(Color, "yellow"));
}

test "levenshteinDistance basic" {
    try std.testing.expectEqual(@as(usize, 0), levenshteinDistance("", ""));
    try std.testing.expectEqual(@as(usize, 3), levenshteinDistance("abc", ""));
    try std.testing.expectEqual(@as(usize, 3), levenshteinDistance("", "abc"));
    try std.testing.expectEqual(@as(usize, 1), levenshteinDistance("kitten", "sitten"));
}

test "findClosestOption" {
    const options = [_][]const u8{ "port", "verbose", "name", "help" };
    const result = findClosestOption("prt", &options, 3);
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("port", result.?);
}
