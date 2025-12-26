const std = @import("std");
const fs = std.fs;
const io = std.io;

/// Log levels
pub const Level = enum(u8) {
    debug = 0,
    info = 1,
    warn = 2,
    @"error" = 3,
    fatal = 4,

    pub fn toString(self: Level) []const u8 {
        return switch (self) {
            .debug => "DEBUG",
            .info => "INFO",
            .warn => "WARN",
            .@"error" => "ERROR",
            .fatal => "FATAL",
        };
    }

    pub fn color(self: Level) []const u8 {
        return switch (self) {
            .debug => "\x1b[36m", // Cyan
            .info => "\x1b[32m", // Green
            .warn => "\x1b[33m", // Yellow
            .@"error" => "\x1b[31m", // Red
            .fatal => "\x1b[35m", // Magenta
        };
    }
};

const RESET = "\x1b[0m";
const BOLD = "\x1b[1m";
const DIM = "\x1b[2m";

/// Global logger configuration
pub const Config = struct {
    /// Minimum log level to output
    min_level: Level = .info,
    /// Whether to use colors
    use_colors: bool = true,
    /// Whether to show timestamps
    show_timestamps: bool = true,
    /// Output file (null = stderr)
    output_file: ?fs.File = null,
    /// Whether to output to file as well as stderr
    dual_output: bool = false,
};

var global_config: Config = .{};

/// Set global logger configuration
pub fn setConfig(config: Config) void {
    global_config = config;
}

/// Get the writer for log output
fn getWriter() fs.File.Writer {
    return if (global_config.output_file) |file|
        file.writer()
    else
        io.getStdErr().writer();
}

/// Format and write a log message
pub fn log(level: Level, comptime format: []const u8, args: anytype) void {
    if (@intFromEnum(level) < @intFromEnum(global_config.min_level)) {
        return;
    }

    const writer = getWriter();

    // Timestamp
    if (global_config.show_timestamps) {
        const timestamp = std.time.timestamp();
        const seconds = @mod(timestamp, 86400);
        const hours = @divTrunc(seconds, 3600);
        const minutes = @divTrunc(@mod(seconds, 3600), 60);
        const secs = @mod(seconds, 60);

        if (global_config.use_colors) {
            writer.print("{s}[{d:0>2}:{d:0>2}:{d:0>2}]{s} ", .{
                DIM,
                hours,
                minutes,
                secs,
                RESET,
            }) catch return;
        } else {
            writer.print("[{d:0>2}:{d:0>2}:{d:0>2}] ", .{
                hours,
                minutes,
                secs,
            }) catch return;
        }
    }

    // Level
    if (global_config.use_colors) {
        writer.print("{s}{s}{s:<5}{s} ", .{
            level.color(),
            BOLD,
            level.toString(),
            RESET,
        }) catch return;
    } else {
        writer.print("{s:<5} ", .{level.toString()}) catch return;
    }

    // Message
    writer.print(format ++ "\n", args) catch return;

    // Also write to file if dual output
    if (global_config.dual_output) {
        if (global_config.output_file) |_| {
            const stderr = io.getStdErr().writer();
            if (global_config.show_timestamps) {
                const timestamp = std.time.timestamp();
                const seconds = @mod(timestamp, 86400);
                const hours = @divTrunc(seconds, 3600);
                const minutes = @divTrunc(@mod(seconds, 3600), 60);
                const secs = @mod(seconds, 60);
                stderr.print("{s}[{d:0>2}:{d:0>2}:{d:0>2}]{s} ", .{
                    DIM,
                    hours,
                    minutes,
                    secs,
                    RESET,
                }) catch return;
            }
            stderr.print("{s}{s}{s:<5}{s} ", .{
                level.color(),
                BOLD,
                level.toString(),
                RESET,
            }) catch return;
            stderr.print(format ++ "\n", args) catch return;
        }
    }
}

/// Convenience functions for each log level
pub fn debug(comptime format: []const u8, args: anytype) void {
    log(.debug, format, args);
}

pub fn info(comptime format: []const u8, args: anytype) void {
    log(.info, format, args);
}

pub fn warn(comptime format: []const u8, args: anytype) void {
    log(.warn, format, args);
}

pub fn err(comptime format: []const u8, args: anytype) void {
    log(.@"error", format, args);
}

pub fn fatal(comptime format: []const u8, args: anytype) void {
    log(.fatal, format, args);
}

/// Scoped logger with a prefix
pub fn scoped(comptime scope: []const u8) type {
    return struct {
        pub fn debug(comptime format: []const u8, args: anytype) void {
            log(.debug, "[" ++ scope ++ "] " ++ format, args);
        }

        pub fn info(comptime format: []const u8, args: anytype) void {
            log(.info, "[" ++ scope ++ "] " ++ format, args);
        }

        pub fn warn(comptime format: []const u8, args: anytype) void {
            log(.warn, "[" ++ scope ++ "] " ++ format, args);
        }

        pub fn err(comptime format: []const u8, args: anytype) void {
            log(.@"error", "[" ++ scope ++ "] " ++ format, args);
        }

        pub fn fatal(comptime format: []const u8, args: anytype) void {
            log(.fatal, "[" ++ scope ++ "] " ++ format, args);
        }
    };
}

/// Print a progress bar
pub fn progress(current: u64, total: u64, width: u32) void {
    if (total == 0) return;

    const writer = getWriter();
    const percentage = @as(f64, @floatFromInt(current)) / @as(f64, @floatFromInt(total));
    const filled = @as(u32, @intFromFloat(@as(f64, @floatFromInt(width)) * percentage));
    const empty = width - filled;

    writer.print("\r", .{}) catch return;

    if (global_config.use_colors) {
        writer.print("{s}", .{"\x1b[32m"}) catch return;
    }

    // Draw filled portion
    var i: u32 = 0;
    while (i < filled) : (i += 1) {
        writer.print("█", .{}) catch return;
    }

    if (global_config.use_colors) {
        writer.print("{s}", .{"\x1b[90m"}) catch return;
    }

    // Draw empty portion
    i = 0;
    while (i < empty) : (i += 1) {
        writer.print("░", .{}) catch return;
    }

    if (global_config.use_colors) {
        writer.print("{s}", .{RESET}) catch return;
    }

    writer.print(" {d:.1}%", .{percentage * 100}) catch return;
}

/// Clear the current line
pub fn clearLine() void {
    const writer = getWriter();
    writer.print("\r\x1b[K", .{}) catch return;
}

/// Print a success message with checkmark
pub fn success(comptime format: []const u8, args: anytype) void {
    const writer = getWriter();
    if (global_config.use_colors) {
        writer.print("\x1b[32m✓\x1b[0m ", .{}) catch return;
    } else {
        writer.print("[OK] ", .{}) catch return;
    }
    writer.print(format ++ "\n", args) catch return;
}

/// Print a failure message with X
pub fn failure(comptime format: []const u8, args: anytype) void {
    const writer = getWriter();
    if (global_config.use_colors) {
        writer.print("\x1b[31m✗\x1b[0m ", .{}) catch return;
    } else {
        writer.print("[FAIL] ", .{}) catch return;
    }
    writer.print(format ++ "\n", args) catch return;
}

/// Print a spinner frame (call repeatedly)
pub fn spinner(frame: u8) void {
    const frames = [_][]const u8{ "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" };
    const writer = getWriter();
    writer.print("\r{s} ", .{frames[frame % frames.len]}) catch return;
}

// ============================================================================
// Unit Tests
// ============================================================================

test "log level ordering" {
    try std.testing.expect(@intFromEnum(Level.debug) < @intFromEnum(Level.info));
    try std.testing.expect(@intFromEnum(Level.info) < @intFromEnum(Level.warn));
    try std.testing.expect(@intFromEnum(Level.warn) < @intFromEnum(Level.@"error"));
    try std.testing.expect(@intFromEnum(Level.@"error") < @intFromEnum(Level.fatal));
}

test "level to string" {
    try std.testing.expectEqualStrings("DEBUG", Level.debug.toString());
    try std.testing.expectEqualStrings("ERROR", Level.@"error".toString());
}
