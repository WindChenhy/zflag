//! Core argument parsing module for zflag.
//!
//! Provides the top-level public API (`parse`, `parseWithOptions`) and all
//! internal functions for traversing the argument struct type at compile time,
//! matching command-line tokens to struct fields, and populating the result.

const std = @import("std");
const types = @import("types.zig");
const value_parser = @import("value_parser.zig");
const help_mod = @import("help.zig");

pub const ParseOptions = types.ParseOptions;
pub const NamedInfo = types.NamedInfo;
pub const ParseError = types.ParseError;

/// Returns `true` if `T` is `[]const u8`.
fn isStringType(comptime T: type) bool {
    const ti = @typeInfo(T);
    return ti == .pointer and ti.pointer.size == .slice and ti.pointer.child == u8;
}

/// Returns `true` if `T` is `[]const []const u8` (a list of strings).
fn isStringListType(comptime T: type) bool {
    const ti = @typeInfo(T);
    if (ti != .pointer or ti.pointer.size != .slice) return false;
    return isStringType(ti.pointer.child);
}

/// Returns `true` if `T` is `[N][]const u8` (a fixed-size string array).
fn isFixedStringArrayType(comptime T: type) bool {
    const ti = @typeInfo(T);
    if (ti != .array) return false;
    return isStringType(ti.child);
}

/// Set one element of a fixed-size string array field.
///
/// `T` must be `[N][]const u8`. The element at `index` is replaced with
/// `value`. Returns `error.InvalidArgumentValue` for non-compatible types.
fn setFixedArrayElement(comptime T: type, ptr: *T, index: usize, value: []const u8) !void {
    switch (comptime @typeInfo(T)) {
        .array => |a| {
            if (a.child == []const u8) {
                const arr = @as(*[a.len]a.child, @ptrCast(ptr));
                arr[index] = value;
            } else {
                return error.InvalidArgumentValue;
            }
        },
        else => return error.InvalidArgumentValue,
    }
}

/// Parse command-line arguments into `T` with default configuration.
///
/// Equivalent to `parseWithOptions(T, .{ .allocator = allocator })`.
pub fn parse(comptime T: type, allocator: std.mem.Allocator) !T {
    return parseWithOptions(T, .{ .allocator = allocator });
}

/// Parse command-line arguments into `T` with the given options.
///
/// This is the main entry point for all parsing. It performs compile-time
/// validation of the struct type, runs the core parser, and optionally
/// handles `--help` / `--version` by printing output and exiting the
/// process when `exit_on_help` is true.
pub fn parseWithOptions(comptime T: type, options: ParseOptions) !T {
    comptime validateType(T);

    const result = parseCore(T, options);

    if (result) |r| {
        return r;
    } else |err| {
        if (options.exit_on_help) {
            switch (err) {
                error.HelpRequested => {
                    const program_name = options.program_name orelse "program";
                    const help_text = help_mod.printHelp(T, options.allocator, program_name, options) catch "";
                    defer if (help_text.len > 0) options.allocator.free(help_text);
                    var buf: [64]u8 = undefined;
                    const stderr = std.debug.lockStderr(&buf);
                    defer std.debug.unlockStderr();
                    stderr.file_writer.interface.print("{s}", .{help_text}) catch {};
                    std.process.exit(0);
                },
                error.VersionRequested => {
                    if (options.version) |v| {
                        var buf: [64]u8 = undefined;
                        const stderr = std.debug.lockStderr(&buf);
                        defer std.debug.unlockStderr();
                        stderr.file_writer.interface.print("{s}\n", .{v}) catch {};
                    }
                    std.process.exit(0);
                },
                else => {},
            }
        }
        return err;
    }
}

/// Core parsing logic: resolve the argument list, initialise defaults, apply
/// environment variable overrides, run the argv parser, and validate required
/// fields.
fn parseCore(comptime T: type, options: ParseOptions) !T {
    const args = if (options.args) |custom_args|
        custom_args
    else blk: {
        if (comptime @hasDecl(std.os, "argv")) {
            break :blk @as([]const []const u8, @ptrCast(std.os.argv[1..]));
        }
        break :blk &[_][]const u8{};
    };

    var result: T = undefined;
    _ = &result;
    initDefaults(T, &result, options.allocator);

    try applyEnvVars(T, &result, options.allocator);

    if (args.len == 0) {
        try validateRequired(T, &result);
        return result;
    }

    var pos_counter: usize = 0;
    try parseArgv(T, &result, args, options, &pos_counter);

    try validateRequired(T, &result);

    return result;
}

/// Validate the argument struct type at compile time.
///
/// Enforces that:
/// - `T` is a struct type
/// - No field is named "help" or "version" (these are reserved)
/// - No short option character is used by more than one field
fn validateType(comptime T: type) void {
    const type_info = @typeInfo(T);
    if (type_info != .@"struct") {
        @compileError("parse only supports struct types, got " ++ @typeName(T));
    }

    for (type_info.@"struct".fields) |field| {
        if (std.mem.eql(u8, field.name, "help")) {
            @compileError("Field name 'help' is reserved");
        }
        if (std.mem.eql(u8, field.name, "version")) {
            @compileError("Field name 'version' is reserved");
        }
    }

    comptime checkShortOptionConflicts(T);
}

/// Detect duplicate short option characters and emit a compile error.
fn checkShortOptionConflicts(comptime T: type) void {
    if (!@hasDecl(T, "info")) return;

    var used_shorts: [256]bool = .{false} ** 256;
    const info_ti = @typeInfo(@field(T, "info"));
    if (info_ti != .@"struct") return;
    for (@typeInfo(T).@"struct".fields) |field| {
        for (info_ti.@"struct".fields) |info_field| {
            if (std.mem.eql(u8, info_field.name, field.name)) {
                if (info_field.default_value_ptr) |ptr| {
                    const field_info = @as(*const types.NamedInfo, @ptrCast(@alignCast(ptr))).*;
                    if (field_info.short) |s| {
                        if (used_shorts[s]) {
                            @compileError("Short option '-" ++ .{s} ++ "' is duplicated");
                        }
                        used_shorts[s] = true;
                    }
                }
                break;
            }
        }
    }
}

/// Initialise all struct fields to their declared default values.
///
/// Fields without an explicit default are set to their zero/empty value:
/// - strings (`[]const u8`) → ""
/// - string lists (`[]const []const u8`) → empty slice
/// - bools → false
/// - ints/floats → 0
/// - structs → .{}
/// - unions → left undefined
fn initDefaults(comptime T: type, result: *T, allocator: std.mem.Allocator) void {
    _ = allocator;
    inline for (@typeInfo(T).@"struct".fields) |field| {
        const field_type = field.type;
        if (field.default_value_ptr) |default_ptr| {
            @field(result, field.name) = @as(*const field_type, @ptrCast(@alignCast(default_ptr))).*;
        } else switch (comptime @typeInfo(field_type)) {
            .pointer => |p| {
                if (p.size == .slice and p.child == u8) {
                    @field(result, field.name) = "";
                } else if (p.size == .slice and p.child == []const u8) {
                    const empty: []const []const u8 = &.{};
                    @field(result, field.name) = empty;
                } else {
                    @field(result, field.name) = undefined;
                }
            },
            .bool => @field(result, field.name) = false,
            .int, .float => @field(result, field.name) = 0,
            .@"struct" => @field(result, field.name) = .{},
            .@"union" => {},
            else => @field(result, field.name) = undefined,
        }
    }
}

/// Apply environment variable overrides for fields that have a `.env` binding
/// in their `NamedInfo`.
///
/// Environment variables only take effect when the field currently holds its
/// default or zero value — they never override an explicit command-line arg.
fn applyEnvVars(comptime T: type, result: *T, allocator: std.mem.Allocator) !void {
    _ = allocator;
    if (!@hasDecl(T, "info")) return;

    const info_ti = comptime @typeInfo(@field(T, "info"));
    if (info_ti != .@"struct") return;

    inline for (@typeInfo(T).@"struct".fields) |field| {
        if (comptime @typeInfo(field.type) == .@"union") continue;
        if (comptime std.mem.eql(u8, field.name, "positional")) continue;
        if (comptime std.mem.eql(u8, field.name, "info")) continue;

        inline for (info_ti.@"struct".fields) |info_field| {
            if (std.mem.eql(u8, info_field.name, field.name)) {
                if (info_field.default_value_ptr) |ptr| {
                    const field_info = @as(*const types.NamedInfo, @ptrCast(@alignCast(ptr))).*;
                    if (field_info.env) |env_name| {
                        const has_default = field.default_value_ptr != null;
                        var should_apply = false;

                        if (has_default) {
                            const default_val = @as(*const field.type, @ptrCast(@alignCast(field.default_value_ptr.?))).*;
                            const current_val = @field(result, field.name);
                            should_apply = valuesEqual(field.type, current_val, default_val);
                        } else {
                            should_apply = isEmptyValue(field.type, @field(result, field.name));
                        }

                        if (should_apply) {
                            if (std.os.getenv(env_name)) |env_val| {
                                const parsed = try parseFieldValue(field.type, env_val);
                                @field(result, field.name) = parsed;
                            }
                        }
                    }
                }
                break;
            }
        }
    }
}

/// Compare two values of the same type for equality.
///
/// Supports strings (slice comparison via `std.mem.eql`), bools, integers,
/// floats, optionals, and enums. Returns `false` for unsupported types.
fn valuesEqual(comptime T: type, a: T, b: T) bool {
    const ti = @typeInfo(T);
    if (isStringType(T)) {
        return std.mem.eql(u8, a, b);
    }
    if (ti == .bool or ti == .int or ti == .float or ti == .optional or ti == .@"enum") {
        return a == b;
    }
    return false;
}

/// Returns `true` if `val` is considered "empty" for the type `T`.
///
/// - `[]const u8`: empty string (len == 0)
/// - `?T`: null
/// - All other types: always `false`
fn isEmptyValue(comptime T: type, val: T) bool {
    if (isStringType(T)) {
        return val.len == 0;
    }
    if (@typeInfo(T) == .optional) {
        return val == null;
    }
    return false;
}

/// Per-instance mutable state for the argv parser.
const ParseState = struct {
    /// Set to true after `--` terminator is encountered.
    after_terminator: bool = false,
    /// Set to true after the first subcommand has been parsed.
    subcommand_parsed: bool = false,
};

/// Tracks how many elements of a fixed-size array have been filled so far.
const FixedArrayTracker = struct {
    field_name: []const u8,
    current_index: usize = 0,
};

/// Walk the argument list and dispatch tokens to the appropriate handler.
fn parseArgv(comptime T: type, result: *T, args: []const []const u8, options: ParseOptions, pos_counter: *usize) !void {
    var state = ParseState{};
    var i: usize = 0;
    var fixed_array_trackers: std.ArrayList(FixedArrayTracker) = .empty;
    defer fixed_array_trackers.deinit(options.allocator);

    while (i < args.len) : (i += 1) {
        const arg = args[i];

        // Handle the `--` terminator.
        if (!state.after_terminator and std.mem.eql(u8, arg, "--")) {
            state.after_terminator = true;
            continue;
        }

        // Everything after `--` is a positional argument.
        if (state.after_terminator) {
            try handlePositional(T, result, arg, pos_counter);
            continue;
        }

        // Handle --help and -h.
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            return error.HelpRequested;
        }

        // Handle --version.
        if (options.version != null and std.mem.eql(u8, arg, "--version")) {
            return error.VersionRequested;
        }

        // Handle long options (--name, --name=value, --no-name).
        if (std.mem.startsWith(u8, arg, "--")) {
            try handleLongOption(T, result, arg[2..], args, &i, options, &fixed_array_trackers);
            continue;
        }

        // Handle short options (-v, -p value, -vaj).
        if (std.mem.startsWith(u8, arg, "-") and arg.len > 1) {
            try handleShortOption(T, result, arg[1..], args, &i, options, &fixed_array_trackers);
            continue;
        }

        // Positional argument or subcommand.
        try handlePositionalOrSubcommand(T, result, arg, &i, args, &state, options, pos_counter, &fixed_array_trackers);
    }
}

/// Handle a `--`-prefixed option.
///
/// Supports:
/// - `--name` (flags and value options)
/// - `--name=value`
/// - `--no-name` (negation prefix for bools, optionals, and string lists)
fn handleLongOption(
    comptime T: type,
    result: *T,
    raw_name: []const u8,
    args: []const []const u8,
    i: *usize,
    options: ParseOptions,
    fixed_array_trackers: *std.ArrayList(FixedArrayTracker),
) !void {
    const name, const explicit_value = splitAssignment(raw_name, options.assignment_separators);

    // Handle --no- prefix.
    if (std.mem.startsWith(u8, name, "no-")) {
        try handleNoPrefixOption(T, result, name[3..], options.allocator);
        return;
    }

    // Match the option name to a struct field.
    var matched = false;
    inline for (@typeInfo(T).@"struct".fields) |field| {
        if (!matched and std.mem.eql(u8, name, field.name)) {
            matched = true;
            try setFieldFromArg(T, result, field, explicit_value, args, i, options.allocator, fixed_array_trackers);
        }
    }

    if (!matched) {
        suggestClosestOption(T, name);
        return error.UnknownOption;
    }
}

/// Handle `--no-<name>` by resetting the field to its negated/empty state.
///
/// - bool: false
/// - optional: null
/// - string list (`[]const []const u8`): empty list (old heap memory freed)
/// - fixed string array: undefined
/// - All other types: error
fn handleNoPrefixOption(comptime T: type, result: *T, name: []const u8, allocator: std.mem.Allocator) !void {
    var matched = false;
    inline for (@typeInfo(T).@"struct".fields) |field| {
        if (!matched and std.mem.eql(u8, name, field.name)) {
            matched = true;
            switch (@typeInfo(field.type)) {
                .bool => @field(result, field.name) = false,
                .optional => @field(result, field.name) = null,
                .pointer => |p| {
                    if (p.size == .slice and p.child == []const u8) {
                        const old = @field(result, field.name);
                        if (@as([]const []const u8, old).len > 0) allocator.free(old);
                        @field(result, field.name) = try allocator.alloc([]const u8, 0);
                    } else return error.InvalidArgumentValue;
                },
                .array => |a| {
                    if (isStringType(a.child)) {
                        @field(result, field.name) = undefined;
                    } else return error.InvalidArgumentValue;
                },
                else => return error.InvalidArgumentValue,
            }
        }
    }
    if (!matched) return error.UnknownOption;
}

/// Handle a `-`-prefixed short option or group of short bool flags.
///
/// If the remaining characters are all bool short options (e.g. `-vaj`),
/// they are expanded and each flag is set. Otherwise the first character
/// is treated as a short option that may consume the rest as an inline
/// value or read the next argument.
fn handleShortOption(
    comptime T: type,
    result: *T,
    raw: []const u8,
    args: []const []const u8,
    i: *usize,
    options: ParseOptions,
    fixed_array_trackers: *std.ArrayList(FixedArrayTracker),
) !void {
    if (raw.len > 1 and isAllBoolFlags(T, raw)) {
        for (raw) |ch| {
            try setBoolFlagByShort(T, result, ch);
        }
        return;
    }

    const ch = raw[0];
    const rest = raw[1..];

    var matched = false;
    inline for (@typeInfo(T).@"struct".fields) |field| {
        if (!matched) {
            const sc = comptime getFieldShortChar(T, field.name);
            if (sc) |s| {
                if (ch == s) {
                    matched = true;
                    if (@typeInfo(field.type) == .bool) {
                        @field(result, field.name) = true;
                    } else {
                        const value = if (rest.len > 0) rest else getNextArg(args, i);
                        if (value) |v| {
                            try setFieldFromArg(T, result, field, v, args, i, options.allocator, fixed_array_trackers);
                            if (rest.len == 0) i.* += 1;
                        } else {
                            return error.MissingRequiredArgument;
                        }
                    }
                }
            }
        }
    }

    if (!matched) {
        const ch_str: []const u8 = &.{raw[0]};
        suggestClosestOption(T, ch_str);
        return error.UnknownOption;
    }
}

/// Returns `true` if every character in `chars` corresponds to a bool-typed
/// field that has a short option alias.
fn isAllBoolFlags(comptime T: type, chars: []const u8) bool {
    for (chars) |ch| {
        var found_bool = false;
        inline for (@typeInfo(T).@"struct".fields) |field| {
            if (@typeInfo(field.type) == .bool) {
                const sc = comptime getFieldShortChar(T, field.name);
                if (sc) |s| {
                    if (ch == s) found_bool = true;
                }
            }
        }
        if (!found_bool) return false;
    }
    return true;
}

/// Set a bool field to `true` given its short option character.
fn setBoolFlagByShort(comptime T: type, result: *T, ch: u8) !void {
    var matched = false;
    inline for (@typeInfo(T).@"struct".fields) |field| {
        if (!matched and @typeInfo(field.type) == .bool) {
            const sc = comptime getFieldShortChar(T, field.name);
            if (sc) |s| {
                if (ch == s) {
                    matched = true;
                    @field(result, field.name) = true;
                }
            }
        }
    }
    if (!matched) {
        const ch_str: []const u8 = &.{ch};
        suggestClosestOption(T, ch_str);
        return error.UnknownOption;
    }
}

/// Look up the short option character for a field from the `pub const info`
/// declaration.
fn getFieldShortChar(comptime T: type, comptime name: []const u8) ?u8 {
    if (!@hasDecl(T, "info")) return null;
    const info_ti = @typeInfo(@field(T, "info"));
    if (info_ti != .@"struct") return null;
    for (info_ti.@"struct".fields) |f| {
        if (std.mem.eql(u8, f.name, name)) {
            if (f.default_value_ptr) |ptr| {
                const entry = @as(*const types.NamedInfo, @ptrCast(@alignCast(ptr))).*;
                return entry.short;
            }
            return null;
        }
    }
    return null;
}

/// Dispatch a non-option argument as either a subcommand or a positional arg.
///
/// If the struct has a union-typed field (subcommand) and no subcommand has
/// been parsed yet, the argument is treated as the subcommand name and the
/// remaining arguments are parsed against the subcommand's struct.
/// Otherwise it falls through to positional argument handling.
fn handlePositionalOrSubcommand(
    comptime T: type,
    result: *T,
    arg: []const u8,
    i: *usize,
    args: []const []const u8,
    state: *ParseState,
    options: ParseOptions,
    pos_counter: *usize,
    fixed_array_trackers: *std.ArrayList(FixedArrayTracker),
) !void {
    comptime var subcommand_field: ?[]const u8 = null;
    comptime {
        for (@typeInfo(T).@"struct".fields) |field| {
            if (@typeInfo(field.type) == .@"union") {
                subcommand_field = field.name;
                break;
            }
        }
    }

    if (comptime subcommand_field) |sc_name| {
        if (!state.subcommand_parsed) {
            state.subcommand_parsed = true;
            const UnionType = @FieldType(T, sc_name);
            var next_i = i.* + 1;
            try parseSubcommand(UnionType, &@field(result, sc_name), arg, args, &next_i, options, fixed_array_trackers);
            i.* = next_i - 1;
            return;
        }
    }

    try handlePositional(T, result, arg, pos_counter);
}

/// Set a positional argument field by index.
///
/// Looks up the `positional` sub-struct and assigns the value to the field
/// at the current position counter.
fn handlePositional(
    comptime T: type,
    result: *T,
    value: []const u8,
    pos_counter: *usize,
) !void {
    if (comptime @hasField(T, "positional")) {
        const PosType = @FieldType(T, "positional");
        var idx: usize = 0;
        inline for (@typeInfo(PosType).@"struct".fields) |field| {
            if (idx == pos_counter.*) {
                @field(&@field(result, "positional"), field.name) = try parseFieldValue(field.type, value);
            }
            idx += 1;
        }
        pos_counter.* += 1;
        return;
    }

    return error.TooManyArguments;
}

/// Parse a subcommand: match the subcommand name against the union field,
/// then parse remaining args against the matched variant's struct type.
fn parseSubcommand(
    comptime UnionType: type,
    result: *UnionType,
    name: []const u8,
    args: []const []const u8,
    idx: *usize,
    options: ParseOptions,
    fixed_array_trackers: *std.ArrayList(FixedArrayTracker),
) !void {
    const union_info = @typeInfo(UnionType).@"union";
    var matched = false;

    inline for (union_info.fields) |field| {
        if (!matched and std.mem.eql(u8, name, field.name)) {
            matched = true;

            var payload: field.type = undefined;
            _ = &payload;
            // Initialise subcommand struct fields from their defaults.
            inline for (@typeInfo(field.type).@"struct".fields) |pf| {
                if (pf.default_value_ptr) |default_ptr| {
                    @field(&payload, pf.name) = @as(*const pf.type, @ptrCast(@alignCast(default_ptr))).*;
                }
            }

            // Consume remaining args as options for the subcommand.
            while (idx.* < args.len) : (idx.* += 1) {
                const arg = args[idx.*];
                if (std.mem.eql(u8, arg, "--")) {
                    idx.* += 1;
                    break;
                }
                if (std.mem.startsWith(u8, arg, "--")) {
                    try handleLongOptionForStruct(field.type, &payload, arg[2..], args, idx, options, fixed_array_trackers);
                } else if (std.mem.startsWith(u8, arg, "-") and arg.len > 1) {
                    try handleShortOptionForStruct(field.type, &payload, arg[1..], args, idx, options.allocator, fixed_array_trackers);
                }
            }

            result.* = @unionInit(UnionType, field.name, payload);
        }
    }

    if (!matched) return error.MissingSubcommand;
}

/// Set a single struct field from a command-line argument value.
///
/// Dispatches based on the field type:
/// - bool: set to true (flag)
/// - `[]const []const u8`: append to string list via `appendToStringList`
/// - `[]const u8`: assign the raw string
/// - `[N][]const u8`: set one element of a fixed-size array
/// - All other types: delegate to `parseFieldValue`
fn setFieldFromArg(
    comptime T: type,
    result: *T,
    comptime field: std.builtin.Type.StructField,
    explicit_value: ?[]const u8,
    args: []const []const u8,
    i: *usize,
    allocator: std.mem.Allocator,
    fixed_array_trackers: *std.ArrayList(FixedArrayTracker),
) !void {
    const field_type = field.type;

    switch (comptime @typeInfo(field_type)) {
        .bool => {
            @field(result, field.name) = true;
        },
        .pointer => |p| {
            if (p.size == .slice and p.child == []const u8) {
                // String list: append value.
                const value = explicit_value orelse (getNextArg(args, i) orelse return error.MissingRequiredArgument);
                if (explicit_value == null) i.* += 1;
                try value_parser.appendToStringList(field_type, &@field(result, field.name), value, allocator);
            } else if (p.size == .slice and p.child == u8) {
                // Plain string: assign directly.
                const value = explicit_value orelse (getNextArg(args, i) orelse return error.MissingRequiredArgument);
                if (explicit_value == null) i.* += 1;
                @field(result, field.name) = value;
            } else {
                return error.InvalidArgumentValue;
            }
        },
        .array => |a| {
            if (a.child == []const u8) {
                // Fixed-size string array: set element by tracking index.
                const value = explicit_value orelse (getNextArg(args, i) orelse return error.MissingRequiredArgument);
                if (explicit_value == null) i.* += 1;

                var tracker_index: usize = 0;
                var found = false;
                for (fixed_array_trackers.items, 0..) |tracker, idx| {
                    if (std.mem.eql(u8, tracker.field_name, field.name)) {
                        tracker_index = idx;
                        found = true;
                        break;
                    }
                }

                if (!found) {
                    try fixed_array_trackers.append(allocator, FixedArrayTracker{ .field_name = field.name, .current_index = 0 });
                    tracker_index = fixed_array_trackers.items.len - 1;
                }

                const tracker = fixed_array_trackers.items[tracker_index];
                const array_len = a.len;
                if (tracker.current_index >= array_len) return error.TooManyArguments;

                try setFixedArrayElement(field_type, &@field(result, field.name), tracker.current_index, value);
                fixed_array_trackers.items[tracker_index].current_index += 1;
            } else {
                // Other array types: parse via parseFieldValue.
                const value = explicit_value orelse (getNextArg(args, i) orelse return error.MissingRequiredArgument);
                if (explicit_value == null) i.* += 1;
                @field(result, field.name) = try parseFieldValue(field_type, value);
            }
        },
        else => {
            // Integers, enums, custom types, etc.: parse via parseFieldValue.
            const value = explicit_value orelse (getNextArg(args, i) orelse return error.MissingRequiredArgument);
            if (explicit_value == null) i.* += 1;
            @field(result, field.name) = try parseFieldValue(field_type, value);
        },
    }
}

/// Parse a string value into the target type `T`.
///
/// Unwraps optionals, rejects string lists and fixed string arrays
/// (which are handled elsewhere), and delegates to `value_parser.parseValue`.
fn parseFieldValue(comptime T: type, str: []const u8) !T {
    const info = @typeInfo(T);
    if (info == .optional) {
        return try parseFieldValue(info.optional.child, str);
    }
    if (isStringListType(T) or isFixedStringArrayType(T)) {
        return error.InvalidArgumentValue;
    }
    return try value_parser.parseValue(T, str);
}

/// Handle a long option (`--name` or `--name=value`) for a subcommand's
/// inner struct type.
///
/// Also supports the `--no-` negation prefix for subcommand fields.
fn handleLongOptionForStruct(
    comptime T: type,
    result: *T,
    raw_name: []const u8,
    args: []const []const u8,
    i: *usize,
    options: ParseOptions,
    fixed_array_trackers: *std.ArrayList(FixedArrayTracker),
) !void {
    const name, const explicit_value = splitAssignment(raw_name, options.assignment_separators);

    // Handle --no- prefix within subcommand scope.
    if (std.mem.startsWith(u8, name, "no-")) {
        var matched = false;
        inline for (@typeInfo(T).@"struct".fields) |field| {
            if (!matched and std.mem.eql(u8, name[3..], field.name)) {
                matched = true;
                switch (@typeInfo(field.type)) {
                    .bool => @field(result, field.name) = false,
                    .optional => @field(result, field.name) = null,
                    .pointer => |p| {
                        if (p.size == .slice and p.child == []const u8) {
                            const old = @field(result, field.name);
                            if (old.len > 0) options.allocator.free(old);
                            @field(result, field.name) = try options.allocator.alloc([]const u8, 0);
                        } else return error.InvalidArgumentValue;
                    },
                    .array => |a| {
                        if (isStringType(a.child)) {
                            @field(result, field.name) = undefined;
                        } else return error.InvalidArgumentValue;
                    },
                    else => return error.InvalidArgumentValue,
                }
            }
        }
        if (!matched) {
            suggestClosestOption(T, name);
            return error.UnknownOption;
        }
        return;
    }

    var matched = false;
    inline for (@typeInfo(T).@"struct".fields) |field| {
        if (!matched and std.mem.eql(u8, name, field.name)) {
            matched = true;
            try setFieldFromArg(T, result, field, explicit_value, args, i, options.allocator, fixed_array_trackers);
        }
    }
    if (!matched) {
        suggestClosestOption(T, name);
        return error.UnknownOption;
    }
}

/// Handle a short option (`-x`, `-xvalue`) for a subcommand's inner struct type.
fn handleShortOptionForStruct(
    comptime T: type,
    result: *T,
    raw: []const u8,
    args: []const []const u8,
    i: *usize,
    allocator: std.mem.Allocator,
    fixed_array_trackers: *std.ArrayList(FixedArrayTracker),
) !void {
    const ch = raw[0];
    const rest = raw[1..];

    var matched = false;
    inline for (@typeInfo(T).@"struct".fields) |field| {
        if (!matched) {
            const sc = comptime getFieldShortChar(T, field.name);
            if (sc) |s| {
                if (ch == s) {
                    matched = true;
                    if (@typeInfo(field.type) == .bool) {
                        @field(result, field.name) = true;
                    } else {
                        const value = if (rest.len > 0) rest else getNextArg(args, i);
                        if (value) |v| {
                            try setFieldFromArg(T, result, field, v, args, i, allocator, fixed_array_trackers);
                            if (rest.len == 0) i.* += 1;
                        } else {
                            return error.MissingRequiredArgument;
                        }
                    }
                }
            }
        }
    }

    if (!matched) {
        const ch_str: []const u8 = &.{raw[0]};
        suggestClosestOption(T, ch_str);
        return error.UnknownOption;
    }
}

/// Validate that all required fields (those without defaults) have been set.
///
/// A field is considered missing if it is still at its zero/empty value and
/// has no default value declared. Positional sub-fields are checked too.
fn validateRequired(comptime T: type, result: *T) !void {
    inline for (@typeInfo(T).@"struct".fields) |field| {
        if (field.default_value_ptr != null) continue;
        if (comptime @typeInfo(field.type) == .optional) continue;
        if (comptime @typeInfo(field.type) == .@"union") continue;
        if (comptime std.mem.eql(u8, field.name, "positional")) continue;

        if (isEmptyValue(field.type, @field(result, field.name))) {
            return error.MissingRequiredArgument;
        }
    }

    if (comptime @hasField(T, "positional")) {
        const PosType = @FieldType(T, "positional");
        inline for (@typeInfo(PosType).@"struct".fields) |field| {
            if (field.default_value_ptr == null and isEmptyValue(field.type, @field(@field(result, "positional"), field.name))) {
                return error.MissingRequiredArgument;
            }
        }
    }
}

/// Suggest a close matching option via stderr when an unknown option is
/// encountered, using Levenshtein distance (max distance = 3).
fn suggestClosestOption(comptime T: type, input: []const u8) void {
    var candidates: std.ArrayList([]const u8) = .empty;
    defer candidates.deinit(std.heap.page_allocator);
    inline for (@typeInfo(T).@"struct".fields) |field| {
        if (comptime @typeInfo(field.type) == .@"union") continue;
        if (comptime std.mem.eql(u8, field.name, "positional")) continue;
        candidates.append(std.heap.page_allocator, field.name) catch return;
    }
    const suggestion = value_parser.findClosestOption(input, candidates.items, 3);
    if (suggestion) |s| {
        var buf: [64]u8 = undefined;
        const stderr = std.debug.lockStderr(&buf);
        defer std.debug.unlockStderr();
        stderr.file_writer.interface.print("    Did you mean --{s}?\n", .{s}) catch {};
    }
}

/// Split `--name=value` into the name and the optional inline value.
///
/// The set of separator characters is configurable via `separators`.
fn splitAssignment(raw: []const u8, separators: []const u8) struct { []const u8, ?[]const u8 } {
    for (separators) |sep_u8| {
        const sep: []const u8 = &.{sep_u8};
        if (std.mem.indexOf(u8, raw, sep)) |pos| {
            return .{ raw[0..pos], raw[pos + 1 ..] };
        }
    }
    return .{ raw, null };
}

/// Get the next argument from the list without advancing the index.
fn getNextArg(args: []const []const u8, i: *usize) ?[]const u8 {
    if (i.* + 1 < args.len) {
        return args[i.* + 1];
    }
    return null;
}

/// Print a formatted message to stderr using Zig 0.16's lockStderr API.
fn printToStdErr(comptime fmt: []const u8, args: anytype) void {
    var buf: [64]u8 = undefined;
    const stderr = std.debug.lockStderr(&buf);
    defer std.debug.unlockStderr();
    stderr.file_writer.interface.print(fmt, args) catch {};
}

// ======================== Tests ========================

test "basic parse with default values" {
    const Args = struct {
        port: u16 = 8080,
        verbose: bool = false,
    };

    const result = try parse(Args, std.testing.allocator);
    try std.testing.expectEqual(@as(u16, 8080), result.port);
    try std.testing.expect(!result.verbose);
}

test "parse long options" {
    const Args = struct {
        port: u16 = 8080,
        name: []const u8 = "",
        verbose: bool = false,
    };

    const test_args = [_][]const u8{ "--port", "9090", "--name", "test", "--verbose" };
    const result = try parseWithOptions(Args, .{ .allocator = std.testing.allocator, .args = &test_args });
    try std.testing.expectEqual(@as(u16, 9090), result.port);
    try std.testing.expectEqualStrings("test", result.name);
    try std.testing.expect(result.verbose);
}

test "parse long option with =" {
    const Args = struct {
        port: u16 = 8080,
    };

    const test_args = [_][]const u8{"--port=9090"};
    const result = try parseWithOptions(Args, .{ .allocator = std.testing.allocator, .args = &test_args });
    try std.testing.expectEqual(@as(u16, 9090), result.port);
}

test "parse --no- prefix for bool" {
    const Args = struct {
        verbose: bool = true,
    };

    const test_args = [_][]const u8{"--no-verbose"};
    const result = try parseWithOptions(Args, .{ .allocator = std.testing.allocator, .args = &test_args });
    try std.testing.expect(!result.verbose);
}

test "parse --no- prefix for optional" {
    const Args = struct {
        config: ?[]const u8 = "default",
    };

    const test_args = [_][]const u8{"--no-config"};
    const result = try parseWithOptions(Args, .{ .allocator = std.testing.allocator, .args = &test_args });
    try std.testing.expect(result.config == null);
}

test "parse short options" {
    const Args = struct {
        verbose: bool = false,
        port: u16 = 8080,

        pub const info = struct {
            verbose: NamedInfo = .{ .short = 'v' },
            port: NamedInfo = .{ .short = 'p' },
        };
    };

    const test_args = [_][]const u8{ "-v", "-p", "3000" };
    const result = try parseWithOptions(Args, .{ .allocator = std.testing.allocator, .args = &test_args });
    try std.testing.expect(result.verbose);
    try std.testing.expectEqual(@as(u16, 3000), result.port);
}

test "parse short option grouping" {
    const Args = struct {
        verbose: bool = false,
        all: bool = false,
        json: bool = false,

        pub const info = struct {
            verbose: NamedInfo = .{ .short = 'v' },
            all: NamedInfo = .{ .short = 'a' },
            json: NamedInfo = .{ .short = 'j' },
        };
    };

    const test_args = [_][]const u8{"-vaj"};
    const result = try parseWithOptions(Args, .{ .allocator = std.testing.allocator, .args = &test_args });
    try std.testing.expect(result.verbose);
    try std.testing.expect(result.all);
    try std.testing.expect(result.json);
}

test "help request returns error" {
    const Args = struct {
        verbose: bool = false,
    };

    const test_args = [_][]const u8{"--help"};
    try std.testing.expectError(error.HelpRequested, parseWithOptions(Args, .{ .allocator = std.testing.allocator, .args = &test_args, .exit_on_help = false }));
}

test "unknown option returns error" {
    const Args = struct {
        verbose: bool = false,
    };

    const test_args = [_][]const u8{"--unknown"};
    try std.testing.expectError(error.UnknownOption, parseWithOptions(Args, .{ .allocator = std.testing.allocator, .args = &test_args }));
}

test "missing required argument returns error" {
    const Args = struct {
        name: []const u8,
    };

    const test_args = [_][]const u8{"--name"};
    try std.testing.expectError(error.MissingRequiredArgument, parseWithOptions(Args, .{ .allocator = std.testing.allocator, .args = &test_args }));
}

test "parse enum option" {
    const LogLevel = enum { debug, info, warn, error_level };

    const Args = struct {
        log_level: LogLevel = .info,
    };

    const test_args = [_][]const u8{"--log_level", "debug"};
    const result = try parseWithOptions(Args, .{ .allocator = std.testing.allocator, .args = &test_args });
    try std.testing.expectEqual(LogLevel.debug, result.log_level);
}

test "-- terminates option parsing" {
    const Args = struct {
        verbose: bool = false,
        positional: struct {
            source: []const u8 = "",
        },
    };

    const test_args = [_][]const u8{ "--verbose", "--", "--not-an-option" };
    const result = try parseWithOptions(Args, .{ .allocator = std.testing.allocator, .args = &test_args });
    try std.testing.expect(result.verbose);
    try std.testing.expectEqualStrings("--not-an-option", result.positional.source);
}

test "parse subcommand" {
    const Args = struct {
        global_verbose: bool = false,

        command: union(enum) {
            commit: struct {
                message: []const u8 = "",
                all: bool = false,
            },
            push: struct {
                force: bool = false,
                remote: []const u8 = "origin",
            },
        },
    };

    const test_args = [_][]const u8{ "--global_verbose", "commit", "--message", "fix bug" };
    const result = try parseWithOptions(Args, .{ .allocator = std.testing.allocator, .args = &test_args });
    try std.testing.expect(result.global_verbose);
    try std.testing.expectEqualStrings("fix bug", result.command.commit.message);
    try std.testing.expect(!result.command.commit.all);
}

test "help output generation" {
    const Args = struct {
        port: u16 = 8080,
        verbose: bool = false,

        pub const info = struct {
            port: NamedInfo = .{
                .short = 'p',
                .description = "service listen port",
                .env = "MYAPP_PORT",
            },
            verbose: NamedInfo = .{
                .short = 'v',
                .description = "enable verbose output",
            },
        };
    };

    const output = try help_mod.printHelp(Args, std.testing.allocator, "myapp", .{ .allocator = std.testing.allocator });
    defer std.testing.allocator.free(output);

    try std.testing.expect(output.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, output, "myapp") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "--port") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "-p") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "--verbose") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "-v") != null);
}

test "parse string list option" {
    const Args = struct {
        include: []const []const u8 = &.{},
    };

    const test_args = [_][]const u8{ "--include", "src/", "--include", "lib/" };
    const result = try parseWithOptions(Args, .{ .allocator = std.testing.allocator, .args = &test_args });
    defer std.testing.allocator.free(result.include);
    try std.testing.expectEqual(@as(usize, 2), result.include.len);
    try std.testing.expectEqualStrings("src/", result.include[0]);
    try std.testing.expectEqualStrings("lib/", result.include[1]);
}

test "parse fixed array option" {
    const Args = struct {
        ip: [2][]const u8 = .{ "", "" },
    };

    const test_args = [_][]const u8{ "--ip", "192.168.1.1", "--ip", "10.0.0.1" };
    const result = try parseWithOptions(Args, .{ .allocator = std.testing.allocator, .args = &test_args });
    try std.testing.expectEqualStrings("192.168.1.1", result.ip[0]);
    try std.testing.expectEqualStrings("10.0.0.1", result.ip[1]);
}

test "parse positional arguments" {
    const Args = struct {
        positional: struct {
            source: []const u8 = "",
            dest: []const u8 = "",
        },
    };

    const test_args = [_][]const u8{ "src.txt", "dest.txt" };
    const result = try parseWithOptions(Args, .{ .allocator = std.testing.allocator, .args = &test_args });
    try std.testing.expectEqualStrings("src.txt", result.positional.source);
    try std.testing.expectEqualStrings("dest.txt", result.positional.dest);
}

test "parse version flag" {
    const Args = struct {
        verbose: bool = false,
    };

    const test_args = [_][]const u8{"--version"};
    try std.testing.expectError(error.VersionRequested, parseWithOptions(Args, .{ .allocator = std.testing.allocator, .args = &test_args, .version = "1.0.0", .exit_on_help = false }));
}

test "custom type with parseFromArg" {
    const IpAddr = struct {
        a: u8, b: u8, c: u8, d: u8,

        pub fn parseFromArg(str: []const u8) !@This() {
            var result: @This() = undefined;
            var iter = std.mem.splitScalar(u8, str, '.');
            var i: usize = 0;
            while (iter.next()) |part| {
                if (i >= 4) return error.InvalidArgumentValue;
                const val = try std.fmt.parseInt(u8, part, 10);
                switch (i) {
                    0 => result.a = val,
                    1 => result.b = val,
                    2 => result.c = val,
                    3 => result.d = val,
                    else => unreachable,
                }
                i += 1;
            }
            if (i != 4) return error.InvalidArgumentValue;
            return result;
        }
    };

    const Args = struct {
        bind: IpAddr = .{ .a = 0, .b = 0, .c = 0, .d = 0 },
    };

    const test_args = [_][]const u8{"--bind", "192.168.1.1"};
    const result = try parseWithOptions(Args, .{ .allocator = std.testing.allocator, .args = &test_args });
    try std.testing.expectEqual(@as(u8, 192), result.bind.a);
    try std.testing.expectEqual(@as(u8, 168), result.bind.b);
    try std.testing.expectEqual(@as(u8, 1), result.bind.c);
    try std.testing.expectEqual(@as(u8, 1), result.bind.d);
}

test "parse help with exit_on_help false returns error" {
    const Args = struct {
        verbose: bool = false,
    };

    const test_args = [_][]const u8{"--help"};
    try std.testing.expectError(error.HelpRequested, parseWithOptions(Args, .{ .allocator = std.testing.allocator, .args = &test_args, .exit_on_help = false }));
}

test "parse --no- prefix for string list" {
    const Args = struct {
        include: []const []const u8 = &.{},
    };

    const test_args = [_][]const u8{ "--include", "src/", "--no-include" };
    const result = try parseWithOptions(Args, .{ .allocator = std.testing.allocator, .args = &test_args });
    defer std.testing.allocator.free(result.include);
    try std.testing.expectEqual(@as(usize, 0), result.include.len);
}

test "parse multiple short options with value" {
    const Args = struct {
        verbose: bool = false,
        port: u16 = 8080,
        name: []const u8 = "",

        pub const info = struct {
            verbose: NamedInfo = .{ .short = 'v' },
            port: NamedInfo = .{ .short = 'p' },
            name: NamedInfo = .{ .short = 'n' },
        };
    };

    const test_args = [_][]const u8{ "-v", "-p", "3000", "-n", "test" };
    const result = try parseWithOptions(Args, .{ .allocator = std.testing.allocator, .args = &test_args });
    try std.testing.expect(result.verbose);
    try std.testing.expectEqual(@as(u16, 3000), result.port);
    try std.testing.expectEqualStrings("test", result.name);
}

test "parse required field" {
    const Args = struct {
        name: []const u8,
    };

    const test_args = [_][]const u8{"--name", "hello"};
    const result = try parseWithOptions(Args, .{ .allocator = std.testing.allocator, .args = &test_args });
    try std.testing.expectEqualStrings("hello", result.name);
}

test "parse required field missing returns error" {
    const Args = struct {
        name: []const u8,
    };

    try std.testing.expectError(error.MissingRequiredArgument, parseWithOptions(Args, .{ .allocator = std.testing.allocator }));
}
