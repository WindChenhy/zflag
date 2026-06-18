//! Core type definitions for zflag.
//!
//! This module defines the metadata structures and configuration options
//! used throughout the argument parsing pipeline.

const std = @import("std");

/// All possible errors that can occur during argument parsing.
pub const ParseError = error{
    /// An undefined option was encountered on the command line.
    UnknownOption,
    /// A required argument was not provided.
    MissingRequiredArgument,
    /// An argument value could not be converted to the expected type.
    InvalidArgumentValue,
    /// More values were provided than a fixed-size array can hold.
    TooManyArguments,
    /// The provided subcommand name did not match any defined subcommand.
    MissingSubcommand,
    /// The user requested help via --help or -h.
    HelpRequested,
    /// The user requested version info via --version.
    VersionRequested,
    /// Memory allocation failed.
    OutOfMemory,
    /// A string could not be parsed as an enum variant.
    InvalidEnumValue,
    /// A string could not be parsed as an integer.
    InvalidIntegerValue,
    /// A string could not be parsed as a float.
    InvalidFloatValue,
    /// A string could not be parsed as a boolean.
    InvalidBoolValue,
};

/// Metadata for a single named option field.
///
/// Declared inside a `pub const info` struct nested within the argument struct.
/// Each field in the info struct corresponds by name to a field in the outer
/// argument struct and carries optional metadata such as short aliases,
/// descriptions, and environment variable bindings.
pub const NamedInfo = struct {
    /// Single-character short option name, e.g. 'p' for `-p`.
    short: ?u8 = null,
    /// Human-readable description shown in the `--help` output.
    description: []const u8 = "",
    /// Environment variable name to read the default value from.
    env: ?[]const u8 = null,
    /// Whether to hide this option from the help output.
    hidden: bool = false,
    /// Custom placeholder string in the help output, e.g. "<PORT>".
    placeholder: ?[]const u8 = null,
};

/// Configuration options for the argument parser.
///
/// Passed to `parseWithOptions` to customize parsing behaviour.
pub const ParseOptions = struct {
    /// Memory allocator used for dynamic allocations such as repeated string
    /// list entries and fixed-size array trackers.
    allocator: std.mem.Allocator,
    /// Characters that can separate an option name from its value when using
    /// the `--name=value` syntax. Default is "=".
    assignment_separators: []const u8 = "=",
    /// Override the program name displayed in help output. When null, the
    /// parser falls back to the first element of argv (if available) or
    /// "program".
    program_name: ?[]const u8 = null,
    /// Version string. When set, `--version` is enabled and prints this value.
    version: ?[]const u8 = null,
    /// Whether the parser should exit the process on `--help` or `--version`.
    /// When true (default), `std.process.exit(0)` is called after printing
    /// help or version. When false, `error.HelpRequested` or
    /// `error.VersionRequested` is returned instead.
    exit_on_help: bool = true,
    /// Whether to show environment variable hints in the `--help` output.
    show_env_in_help: bool = true,
    /// Custom argument list for testing. When null, the parser reads from
    /// `std.os.argv`.
    args: ?[]const []const u8 = null,
};
