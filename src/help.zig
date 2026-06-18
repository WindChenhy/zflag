//! Help text generation for zflag.
//!
//! Produces a formatted `--help` string by introspecting the argument struct
//! type at compile time, including option descriptions, defaults,
//! environment variable hints, positional arguments, and subcommands.

const std = @import("std");
const types = @import("types.zig");

/// Generate a help text string for the argument struct `T`.
///
/// The output includes a "Usage:" line, a list of all options with their
/// short aliases, descriptions, default values, and environment variable
/// bindings, followed by positional argument and subcommand sections where
/// applicable.
///
/// `allocator` is used for the returned string. The caller owns the memory.
/// `program_name` is displayed in the usage line.
/// `options` controls whether to show env bindings and version info.
pub fn printHelp(comptime T: type, allocator: std.mem.Allocator, program_name: []const u8, options: types.ParseOptions) ![]const u8 {
    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(allocator);

    // Writer adapter that appends formatted output into the ArrayList.
    const ListWriter = struct {
        list: *std.ArrayList(u8),
        allocator: std.mem.Allocator,

        pub fn print(self: @This(), comptime fmt: []const u8, args: anytype) !void {
            var buf: [512]u8 = undefined;
            const slice = try std.fmt.bufPrint(&buf, fmt, args);
            try self.list.appendSlice(self.allocator, slice);
        }

        pub fn writeAll(self: @This(), bytes: []const u8) !void {
            try self.list.appendSlice(self.allocator, bytes);
        }
    };

    var lw = ListWriter{ .list = &list, .allocator = allocator };

    // Usage line.
    try lw.print("Usage: {s} [OPTIONS]", .{program_name});

    // Append positional argument placeholders, if any.
    if (comptime @hasField(T, "positional")) {
        inline for (@typeInfo(@FieldType(T, "positional")).@"struct".fields) |field| {
            try lw.print(" <{s}>", .{field.name});
        }
    }

    // Append subcommand placeholder if the struct has a union-typed field.
    inline for (@typeInfo(T).@"struct".fields) |field| {
        if (@typeInfo(field.type) == .@"union") {
            try lw.print(" <COMMAND>", .{});
            break;
        }
    }

    try lw.print("\n\nOptions:\n", .{});

    // Render each option field.
    inline for (@typeInfo(T).@"struct".fields) |field| {
        if (comptime std.mem.eql(u8, field.name, "positional")) continue;
        if (comptime std.mem.eql(u8, field.name, "info")) continue;
        if (comptime @typeInfo(field.type) == .@"union") continue;

        const info_entry = comptime getInfoEntry(T, field.name);
        if (info_entry) |info| {
            if (info.hidden) continue;
            // Show short alias if available.
            if (info.short) |s| {
                try lw.print("  -{c}, --{s}", .{ s, field.name });
            } else {
                try lw.print("      --{s}", .{field.name});
            }
        } else {
            try lw.print("      --{s}", .{field.name});
        }

        // Placeholder for non-boolean options.
        if (@typeInfo(field.type) != .bool) {
            const info_entry2 = comptime getInfoEntry(T, field.name);
            const placeholder = if (info_entry2) |info|
                info.placeholder orelse field.name
            else
                field.name;
            try lw.print(" <{s}>", .{placeholder});
        }

        // Description.
        const info_entry3 = comptime getInfoEntry(T, field.name);
        if (info_entry3) |info| {
            if (info.description.len > 0) {
                try lw.print("  {s}", .{info.description});
            }
        }

        // Default value.
        if (field.default_value_ptr) |default_ptr| {
            const default_val = @as(*const field.type, @ptrCast(@alignCast(default_ptr))).*;
            try lw.print(" [default: {any}]", .{default_val});
        }

        // Environment variable binding.
        if (options.show_env_in_help) {
            const info_entry4 = comptime getInfoEntry(T, field.name);
            if (info_entry4) |info| {
                if (info.env) |e| {
                    try lw.print(" [env: {s}]", .{e});
                }
            }
        }

        try lw.print("\n", .{});
    }

    // Built-in help option.
    try lw.print("  -h, --help              Show this help message\n", .{});

    // Version option (only shown when version is set).
    if (options.version != null) {
        try lw.print("      --version           Show version information\n", .{});
    }

    // Positional argument details.
    if (comptime @hasField(T, "positional")) {
        try lw.print("\nArguments:\n", .{});
        inline for (@typeInfo(@FieldType(T, "positional")).@"struct".fields) |field| {
            if (field.default_value_ptr) |_| {
                try lw.print("  <{s: <20}>optional\n", .{field.name});
            } else {
                try lw.print("  <{s: <20}>required\n", .{field.name});
            }
        }
    }

    // Subcommand list.
    inline for (@typeInfo(T).@"struct".fields) |field| {
        if (@typeInfo(field.type) == .@"union") {
            try lw.print("\nCommands:\n", .{});
            inline for (@typeInfo(field.type).@"union".fields) |sub_field| {
                try lw.print("  {s}\n", .{sub_field.name});
            }
            break;
        }
    }

    return list.toOwnedSlice(allocator);
}

/// Look up the `NamedInfo` entry for a field in the argument struct's
/// `pub const info` declaration.
///
/// Returns `null` if no info declaration exists or if the field is not found.
fn getInfoEntry(comptime T: type, comptime field_name: []const u8) ?types.NamedInfo {
    if (!@hasDecl(T, "info")) return null;
    const info_ti = @typeInfo(@field(T, "info"));
    if (info_ti != .@"struct") return null;
    for (info_ti.@"struct".fields) |f| {
        if (std.mem.eql(u8, f.name, field_name)) {
            if (f.default_value_ptr) |ptr| {
                return @as(*const types.NamedInfo, @ptrCast(@alignCast(ptr))).*;
            }
            return null;
        }
    }
    return null;
}
