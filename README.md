# zflag

> A Lightweight Command-Line Argument Parser for Zig — Declarative, Zero-Cost Abstraction

[![Zig Version](https://img.shields.io/badge/Zig-0.16.0-orange)](https://ziglang.org/)
[![License](https://img.shields.io/badge/License-MIT-blue)](LICENSE)

zflag is a lightweight command-line argument parsing library designed for Zig. Define your arguments as a simple `struct`, and zflag automatically binds command-line arguments to Zig variables — powered by comptime for compile-time type inference and validation.

## ✨ Features

- **Declarative Definition** — Define a `struct` to declare all arguments; field names become option names
- **Automatic Type Binding** — Supports bool, integers, floats, strings, enums, optionals, and more
- **Short & Long Options** — Use `-p 8080` or `--port 8080`
- **Short Flag Grouping** — `-vaj` expands to `-v -a -j`
- **`--no-` Prefix** — `--no-verbose` sets bool flags to false
- **`--name=value` Syntax** — Equals-sign delimiters supported
- **`--` Terminator** — All arguments after `--` are treated as positional
- **Positional Arguments** — Declared via nested struct
- **Subcommands** — `union(enum)` for git-like multi-command structures
- **Metadata** — `pub const info` for short names, descriptions, env vars, and more
- **Auto Help Generation** — Formatted `--help` output generated from struct definition
- **Custom Type Extension** — Implement `parseFromArg` to support any type
- **Zero Dependencies** — Only depends on the Zig standard library
- **Compile-Time Validation** — Name conflicts and duplicate short options caught at compile time

## 📦 Installation

Add the dependency in `build.zig.zon`:

```zig
.dependencies = .{
    .zflag = .{
        .url = "https://github.com/yourname/zflag/archive/refs/tags/v0.1.0.tar.gz",
        .hash = "...",
    },
},
```

Then add the module in `build.zig`:

```zig
const zflag = b.dependency("zflag", .{});
exe.root_module.addImport("zflag", zflag.module("zflag"));
```

## 🚀 Quick Start

### Basic Usage

```zig
const std = @import("std");
const zflag = @import("zflag");

const Args = struct {
    port: u16 = 8080,            // Optional with default
    name: []const u8 = "",        // Optional, empty string = not provided
    verbose: bool = false,        // Boolean flag
};

pub fn main() !void {
    const args = try zflag.parse(Args);

    std.debug.print("port: {d}\n", .{args.port});
    std.debug.print("name: {s}\n", .{args.name});
    std.debug.print("verbose: {}\n", .{args.verbose});
}
```

Run it:

```bash
$ myapp --port 9090 --name myserver --verbose
port: 9090
name: myserver
verbose: true

$ myapp --help
Usage: myapp [OPTIONS]

Options:
      --port <port>     [默认: 8080]
      --name <name>
      --verbose
  -h, --help            显示此帮助信息
```

### Short Options

```zig
const Args = struct {
    verbose: bool = false,
    port: u16 = 8080,
    output: []const u8 = "",

    pub const info = struct {
        verbose: zflag.NamedInfo = .{ .short = 'v', .description = "Enable verbose output" },
        port: zflag.NamedInfo = .{ .short = 'p', .description = "Listen port" },
        output: zflag.NamedInfo = .{ .short = 'o', .description = "Output file" },
    };
};
```

```bash
$ myapp -v -p 3000 -o result.txt
$ myapp -vp 3000 -o result.txt      # Short flag grouping
$ myapp --port=3000                  # Equals-sign syntax
```

### Environment Variable Binding

```zig
const Args = struct {
    port: u16 = 8080,
    log_level: []const u8 = "info",

    pub const info = struct {
        port: zflag.NamedInfo = .{
            .short = 'p',
            .description = "Server port",
            .env = "MYAPP_PORT",          // Priority: CLI > env var > default
        },
        log_level: zflag.NamedInfo = .{
            .short = 'l',
            .description = "Log level",
            .env = "MYAPP_LOG_LEVEL",
        },
    };
};
```

```bash
$ MYAPP_PORT=9090 myapp               # Read from environment
$ myapp --port 3000                    # CLI overrides env var
```

### Positional Arguments

```zig
const Args = struct {
    verbose: bool = false,
    positional: struct {
        source: []const u8,      // Required
        dest: []const u8,        // Required
    },
};
```

```bash
$ myapp -v src/main.zig build/
# args.verbose = true
# args.positional.source = "src/main.zig"
# args.positional.dest = "build/"
```

### Subcommands

```zig
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
```

```bash
$ mygit --global_verbose commit --message "fix bug" --all
# args.global_verbose = true
# args.command = .{ .commit = .{ .message = "fix bug", .all = true } }

$ mygit push --force --remote upstream
# args.command = .{ .push = .{ .force = true, .remote = "upstream" } }
```

### Custom Types

Implement `parseFromArg` on your type for automatic parsing:

```zig
const IpAddr = struct {
    a: u8, b: u8, c: u8, d: u8,

    pub fn parseFromArg(str: []const u8) !IpAddr {
        var result: IpAddr = undefined;
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
```

```bash
$ myapp --bind 192.168.1.100
```

### `--no-` Prefix

```zig
const Args = struct {
    cache: bool = true,
    config: ?[]const u8 = "default.toml",  // Optional type
};
```

```bash
$ myapp --no-cache       # cache = false
$ myapp --no-config      # config = null
```

### `--` Terminator

```bash
$ myapp --verbose -- --not-a-flag
# args.verbose = true
# Positional args include "--not-a-flag" (not parsed as an option)
```

### Custom Parse Configuration

```zig
const args = try zflag.parseWithOptions(Args, .{
    .version = "1.0.0",                // Enable --version
    .show_env_in_help = true,          // Show env vars in help text
    .args = &.{ "--port", "3000" },    // Custom arg list (for testing)
});
```

## 📖 API Reference

### Core Functions

```zig
/// Basic parsing with default configuration
pub fn parse(comptime T: type) !T;

/// Parsing with custom configuration
pub fn parseWithOptions(comptime T: type, options: ParseOptions) !T;
```

### Supported Types

| Type | Behavior |
|------|----------|
| `bool` | Flag: `--flag` sets true, `--no-flag` sets false |
| `u8..u64`, `i8..i64` | Integer with automatic range validation |
| `f32`, `f64` | Floating point |
| `[]const u8` | String |
| `?T` | Optional: `--no-name` sets to null |
| `enum` | Enum: matched by member name |
| `[N]T` | Fixed-size array: requires exactly N values |
| Custom type | Implement `parseFromArg(str) !T` |

### NamedInfo

Declare metadata for fields in `pub const info`:

```zig
pub const info = struct {
    field_name: zflag.NamedInfo = .{
        .short = 'x',              // Short option character
        .description = "Help text", // Description for --help
        .env = "ENV_VAR_NAME",     // Environment variable binding
        .hidden = false,           // Hide from help output
        .placeholder = "<VALUE>",  // Placeholder in help text
    },
};
```

### ParseOptions

```zig
pub const ParseOptions = struct {
    assignment_separators: []const u8 = "=",
    program_name: ?[]const u8 = null,
    version: ?[]const u8 = null,
    exit_on_help: bool = true,
    show_env_in_help: bool = true,
    args: ?[]const []const u8 = null,  // Custom arg list (for testing)
};
```

## 🏗️ Project Structure

```
src/
├── main.zig          # Core parsing logic (parse, parseWithOptions)
├── types.zig         # Type definitions (ParseOptions, NamedInfo, ParseError)
├── value_parser.zig  # Value parsers (type conversion, Levenshtein distance)
└── help.zig          # Auto-generated help output
```

## 🧪 Running Tests

```bash
zig build test
```

## 📄 License

MIT License
