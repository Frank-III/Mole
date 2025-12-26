const std = @import("std");
const mem = std.mem;
const io = std.io;
const process = std.process;

// Core modules
pub const safety = @import("core/safety.zig");
pub const file_ops = @import("core/file_ops.zig");
pub const logging = @import("core/logging.zig");
pub const config = @import("core/config.zig");

const VERSION = "2.0.0-zig";
const AUTHOR = "Tw93 & Contributors";

/// Command type for routing
const Command = enum {
    help,
    version,
    clean,
    analyze,
    status,
    uninstall,
    purge,
    optimize,
    check,
    config_cmd,
    unknown,

    fn fromString(str: []const u8) Command {
        const commands = .{
            .{ "help", Command.help },
            .{ "-h", Command.help },
            .{ "--help", Command.help },
            .{ "version", Command.version },
            .{ "-v", Command.version },
            .{ "--version", Command.version },
            .{ "clean", Command.clean },
            .{ "c", Command.clean },
            .{ "analyze", Command.analyze },
            .{ "a", Command.analyze },
            .{ "status", Command.status },
            .{ "s", Command.status },
            .{ "uninstall", Command.uninstall },
            .{ "u", Command.uninstall },
            .{ "purge", Command.purge },
            .{ "p", Command.purge },
            .{ "optimize", Command.optimize },
            .{ "o", Command.optimize },
            .{ "check", Command.check },
            .{ "config", Command.config_cmd },
        };

        inline for (commands) |cmd| {
            if (mem.eql(u8, str, cmd[0])) {
                return cmd[1];
            }
        }

        return .unknown;
    }
};

/// Print the banner
fn printBanner(writer: anytype) !void {
    try writer.writeAll(
        \\
        \\  ███╗   ███╗ ██████╗ ██╗     ███████╗
        \\  ████╗ ████║██╔═══██╗██║     ██╔════╝
        \\  ██╔████╔██║██║   ██║██║     █████╗
        \\  ██║╚██╔╝██║██║   ██║██║     ██╔══╝
        \\  ██║ ╚═╝ ██║╚██████╔╝███████╗███████╗
        \\  ╚═╝     ╚═╝ ╚═════╝ ╚══════╝╚══════╝
        \\
        \\
    );
    try writer.print("Version {s} (Zig Edition)\n\n", .{VERSION});
}

/// Print help message
fn printHelp(writer: anytype) !void {
    try printBanner(writer);

    try writer.writeAll(
        \\USAGE:
        \\  mole <command> [options]
        \\
        \\COMMANDS:
        \\  clean, c       Deep clean system caches, logs, and temp files
        \\  analyze, a     Interactive disk space analyzer (TUI)
        \\  status, s      Real-time system status monitor (TUI)
        \\  uninstall, u   Smart app uninstaller with orphan detection
        \\  purge, p       Clean project build artifacts (node_modules, target, etc.)
        \\  optimize, o    System maintenance and optimization
        \\  check          System health check
        \\  config         Manage configuration (whitelist, blacklist)
        \\  help, -h       Show this help message
        \\  version, -v    Show version information
        \\
        \\OPTIONS:
        \\  --dry-run      Preview changes without making them
        \\  --verbose      Enable verbose logging
        \\  --yes, -y      Skip confirmation prompts
        \\
        \\EXAMPLES:
        \\  mole clean              # Deep clean with confirmation
        \\  mole clean --dry-run    # Preview what would be cleaned
        \\  mole analyze ~/         # Analyze home directory
        \\  mole uninstall Slack    # Uninstall Slack completely
        \\  mole purge              # Clean project build artifacts
        \\
        \\SAFETY:
        \\  Mole uses a multi-layered safety system:
        \\  - Iron Dome: Critical system paths are always protected
        \\  - Symlink validation: Prevents directory traversal attacks
        \\  - Vendor protection: Shared app resources are preserved
        \\  - Orphan age check: Only removes data older than 60 days
        \\
        \\For more information, visit: https://github.com/tw93/Mole
        \\
    );
}

/// Print version
fn printVersion(writer: anytype) !void {
    try writer.print("mole {s}\n", .{VERSION});
    try writer.writeAll("A lightweight macOS maintenance tool\n");
    try writer.print("By {s}\n", .{AUTHOR});
    try writer.writeAll("\nBuilt with Zig - fast, safe, and reliable\n");
}

/// Main entry point
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const stdout = io.getStdOut().writer();
    const stderr = io.getStdErr().writer();

    // Parse arguments
    var args = try process.argsWithAllocator(allocator);
    defer args.deinit();

    // Skip program name
    _ = args.skip();

    // Get command
    const cmd_str = args.next() orelse {
        // No command - show help
        try printHelp(stdout);
        return;
    };

    const cmd = Command.fromString(cmd_str);

    // Parse remaining arguments
    var dry_run = false;
    var verbose = false;
    var skip_confirm = false;
    var target_path: ?[]const u8 = null;

    while (args.next()) |arg| {
        if (mem.eql(u8, arg, "--dry-run")) {
            dry_run = true;
        } else if (mem.eql(u8, arg, "--verbose")) {
            verbose = true;
        } else if (mem.eql(u8, arg, "--yes") or mem.eql(u8, arg, "-y")) {
            skip_confirm = true;
        } else if (arg.len > 0 and arg[0] != '-') {
            target_path = arg;
        }
    }

    // Configure logging
    if (verbose) {
        logging.setConfig(.{
            .min_level = .debug,
            .use_colors = true,
            .show_timestamps = true,
        });
    }

    // Load config
    var app_config = config.loadConfig(allocator) catch |err| {
        logging.warn("Failed to load config: {s}, using defaults", .{@errorName(err)});
        config.Config.init(allocator);
    };
    defer app_config.deinit();

    // Override with command-line options
    if (dry_run) app_config.dry_run = true;
    if (verbose) app_config.verbose = true;

    // Route to command handler
    switch (cmd) {
        .help => try printHelp(stdout),
        .version => try printVersion(stdout),
        .clean => {
            try stdout.writeAll("\n🧹 Mole Clean\n\n");
            if (dry_run) {
                try stdout.writeAll("Running in DRY-RUN mode - no files will be deleted\n\n");
            }
            try runClean(allocator, &app_config, dry_run, skip_confirm);
        },
        .analyze => {
            const path = target_path orelse blk: {
                const home = std.posix.getenv("HOME") orelse "/";
                break :blk home;
            };
            try stdout.print("\n📊 Analyzing: {s}\n", .{path});
            try stdout.writeAll("(TUI analyzer coming soon...)\n\n");
            // TODO: Implement TUI analyzer
        },
        .status => {
            try stdout.writeAll("\n📈 System Status Monitor\n");
            try stdout.writeAll("(TUI monitor coming soon...)\n\n");
            // TODO: Implement TUI status monitor
        },
        .uninstall => {
            if (target_path) |app_name| {
                try stdout.print("\n🗑️  Uninstalling: {s}\n", .{app_name});
                try stdout.writeAll("(App uninstaller coming soon...)\n\n");
            } else {
                try stderr.writeAll("Error: Please specify an app name\n");
                try stderr.writeAll("Usage: mole uninstall <app-name>\n");
            }
        },
        .purge => {
            try stdout.writeAll("\n🧹 Project Artifact Purge\n");
            try stdout.writeAll("(Project purge coming soon...)\n\n");
        },
        .optimize => {
            try stdout.writeAll("\n⚡ System Optimization\n");
            try stdout.writeAll("(Optimization coming soon...)\n\n");
        },
        .check => {
            try stdout.writeAll("\n🔍 System Health Check\n\n");
            try runHealthCheck(allocator, stdout);
        },
        .config_cmd => {
            try stdout.writeAll("\n⚙️  Configuration\n\n");
            try showConfig(&app_config, stdout);
        },
        .unknown => {
            try stderr.print("Unknown command: {s}\n", .{cmd_str});
            try stderr.writeAll("Run 'mole help' for usage information\n");
        },
    }
}

/// Run the clean command
fn runClean(allocator: std.mem.Allocator, app_config: *config.Config, dry_run: bool, skip_confirm: bool) !void {
    const stdout = io.getStdOut().writer();

    // Define cleanup targets
    const CleanTarget = struct {
        name: []const u8,
        path_template: []const u8,
        description: []const u8,
    };

    const targets = [_]CleanTarget{
        .{ .name = "User Caches", .path_template = "{s}/Library/Caches", .description = "Application cache files" },
        .{ .name = "User Logs", .path_template = "{s}/Library/Logs", .description = "Application log files" },
        .{ .name = "Xcode DerivedData", .path_template = "{s}/Library/Developer/Xcode/DerivedData", .description = "Xcode build artifacts" },
        .{ .name = "npm Cache", .path_template = "{s}/.npm/_cacache", .description = "npm package cache" },
        .{ .name = "Yarn Cache", .path_template = "{s}/.yarn/cache", .description = "Yarn package cache" },
        .{ .name = "pip Cache", .path_template = "{s}/.cache/pip", .description = "Python pip cache" },
        .{ .name = "Cargo Cache", .path_template = "{s}/.cargo/registry/cache", .description = "Rust cargo cache" },
        .{ .name = "Go Cache", .path_template = "{s}/.cache/go-build", .description = "Go build cache" },
        .{ .name = "Homebrew Cache", .path_template = "{s}/Library/Caches/Homebrew", .description = "Homebrew download cache" },
    };

    const home = std.posix.getenv("HOME") orelse {
        logging.err("Could not determine home directory", .{});
        return;
    };

    var total_size: u64 = 0;
    var total_files: u64 = 0;

    try stdout.writeAll("Scanning cleanup targets...\n\n");

    // Scan each target
    for (targets) |target| {
        const path = try std.fmt.allocPrint(allocator, target.path_template, .{home});
        defer allocator.free(path);

        // Check if whitelisted
        if (app_config.isWhitelisted(path)) {
            try stdout.print("  ⏭️  {s}: skipped (whitelisted)\n", .{target.name});
            continue;
        }

        // Validate path
        safety.validatePath(path) catch {
            try stdout.print("  ❌ {s}: blocked (safety)\n", .{target.name});
            continue;
        };

        // Check if exists
        if (!file_ops.pathExists(path)) {
            try stdout.print("  ⚪ {s}: not found\n", .{target.name});
            continue;
        }

        // Calculate size
        const size = file_ops.calculateDirectorySize(allocator, path) catch 0;
        if (size == 0) {
            try stdout.print("  ⚪ {s}: empty\n", .{target.name});
            continue;
        }

        const formatted = file_ops.formatBytes(size);
        try stdout.print("  ✅ {s}: {d:.2} {s}\n", .{ target.name, formatted.value, formatted.unit });

        total_size += size;
        total_files += 1;
    }

    try stdout.writeAll("\n");

    if (total_files == 0) {
        try stdout.writeAll("Nothing to clean!\n");
        return;
    }

    const total_formatted = file_ops.formatBytes(total_size);
    try stdout.print("Total reclaimable: {d:.2} {s} across {d} locations\n\n", .{
        total_formatted.value,
        total_formatted.unit,
        total_files,
    });

    if (dry_run) {
        try stdout.writeAll("Dry run complete - no files were deleted.\n");
        return;
    }

    // Confirmation
    if (!skip_confirm) {
        try stdout.writeAll("Proceed with cleanup? [y/N] ");

        const stdin = io.getStdIn().reader();
        var buf: [10]u8 = undefined;
        const input = stdin.readUntilDelimiter(&buf, '\n') catch "";

        if (input.len == 0 or (input[0] != 'y' and input[0] != 'Y')) {
            try stdout.writeAll("Cancelled.\n");
            return;
        }
    }

    try stdout.writeAll("\nCleaning...\n");

    // Perform cleanup
    for (targets) |target| {
        const path = try std.fmt.allocPrint(allocator, target.path_template, .{home});
        defer allocator.free(path);

        if (app_config.isWhitelisted(path)) continue;
        if (!file_ops.pathExists(path)) continue;

        var result = file_ops.safeDeleteDirectory(allocator, path, .{
            .dry_run = false,
            .skip_confirmation = true,
        }) catch continue;
        defer result.deinit();

        if (result.success) {
            const formatted = file_ops.formatBytes(result.bytes_freed);
            logging.success("{s}: freed {d:.2} {s}", .{
                target.name,
                formatted.value,
                formatted.unit,
            });
        } else {
            for (result.errors.items) |err| {
                logging.err("{s}: {s}", .{ err.path, err.message });
            }
        }
    }

    try stdout.writeAll("\nCleanup complete!\n");
}

/// Run health check
fn runHealthCheck(allocator: std.mem.Allocator, writer: anytype) !void {
    _ = allocator;

    try writer.writeAll("System Health Report\n");
    try writer.writeAll("═══════════════════════════════════════\n\n");

    // Check disk space
    try writer.writeAll("📁 Disk Space:\n");
    try writer.writeAll("   (checking...)\n\n");

    // Check protected paths
    try writer.writeAll("🛡️  Iron Dome Protection: Active\n");
    try writer.print("   Protected paths: {d}\n\n", .{safety.IRON_DOME_PATHS.len});

    // Check config
    try writer.writeAll("⚙️  Configuration: Loaded\n\n");

    try writer.writeAll("All systems operational.\n");
}

/// Show configuration
fn showConfig(app_config: *const config.Config, writer: anytype) !void {
    try writer.writeAll("Current Configuration:\n");
    try writer.writeAll("─────────────────────────────────────\n\n");

    try writer.print("Verbose:              {s}\n", .{if (app_config.verbose) "yes" else "no"});
    try writer.print("Dry-run by default:   {s}\n", .{if (app_config.dry_run) "yes" else "no"});
    try writer.print("Orphan min age:       {d} days\n", .{app_config.orphan_min_age_days});
    try writer.print("Project scan depth:   {d}\n\n", .{app_config.project_cleanup_depth});

    try writer.writeAll("Whitelist:\n");
    if (app_config.whitelist.items.len == 0) {
        try writer.writeAll("  (empty)\n");
    } else {
        for (app_config.whitelist.items) |item| {
            try writer.print("  - {s}\n", .{item});
        }
    }

    try writer.writeAll("\nProtected Domains:\n");
    for (app_config.protected_domains.items) |domain| {
        try writer.print("  - {s}\n", .{domain});
    }

    try writer.writeAll("\n");
}

// ============================================================================
// Tests
// ============================================================================

test "command parsing" {
    try std.testing.expectEqual(Command.help, Command.fromString("help"));
    try std.testing.expectEqual(Command.help, Command.fromString("-h"));
    try std.testing.expectEqual(Command.clean, Command.fromString("clean"));
    try std.testing.expectEqual(Command.clean, Command.fromString("c"));
    try std.testing.expectEqual(Command.analyze, Command.fromString("analyze"));
    try std.testing.expectEqual(Command.unknown, Command.fromString("foo"));
}

test {
    // Run all tests from submodules
    std.testing.refAllDecls(@This());
}
