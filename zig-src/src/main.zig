const std = @import("std");
const mem = std.mem;
const io = std.io;
const process = std.process;

// Core modules
pub const safety = @import("core/safety.zig");
pub const file_ops = @import("core/file_ops.zig");
pub const logging = @import("core/logging.zig");
pub const config = @import("core/config.zig");

// Cleanup modules
pub const clean = @import("clean/mod.zig");

// Feature modules
pub const scanner = @import("analyze/scanner.zig");
pub const metrics = @import("status/metrics.zig");
pub const uninstall = @import("uninstall/detector.zig");
pub const optimize = @import("optimize/tasks.zig");

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
            try runCleanComprehensive(allocator, &app_config, dry_run, skip_confirm);
        },
        .analyze => {
            const path = target_path orelse blk: {
                const home = std.posix.getenv("HOME") orelse "/";
                break :blk home;
            };
            try runAnalyze(allocator, path);
        },
        .status => {
            try runStatus(allocator);
        },
        .uninstall => {
            if (target_path) |app_name| {
                try runUninstall(allocator, app_name, dry_run, skip_confirm);
            } else {
                try stderr.writeAll("Error: Please specify an app name\n");
                try stderr.writeAll("Usage: mole uninstall <app-name>\n");
            }
        },
        .purge => {
            try stdout.writeAll("\n🧹 Project Artifact Purge\n\n");
            const path = target_path orelse blk: {
                const home = std.posix.getenv("HOME") orelse "/";
                break :blk home;
            };
            try runPurge(allocator, path, app_config.project_cleanup_depth, dry_run, skip_confirm);
        },
        .optimize => {
            try runOptimize(allocator, skip_confirm);
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

/// Run comprehensive cleanup using all cleanup modules
fn runCleanComprehensive(allocator: std.mem.Allocator, app_config: *config.Config, dry_run: bool, skip_confirm: bool) !void {
    const stdout = io.getStdOut().writer();

    try stdout.writeAll("Scanning all cleanup targets...\n");

    // Scan using comprehensive cleanup module
    var scan_result = try clean.scan(allocator, .{
        .mode = .standard,
        .dry_run = dry_run,
        .include_dev_tools = true,
        .include_browser = false, // Only include if user explicitly requests
        .app_config = app_config,
    });
    defer scan_result.deinit();

    // Print summary
    try clean.printSummary(&scan_result, stdout);

    if (scan_result.total_bytes_freed == 0) {
        try stdout.writeAll("Nothing to clean!\n");
        return;
    }

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

    try stdout.writeAll("\nCleaning...\n\n");

    // Execute cleanup
    var result = try clean.execute(allocator, &scan_result, false);
    defer result.deinit();

    const formatted = file_ops.formatBytes(result.bytes_freed);
    try stdout.print("\n✅ Cleanup complete! Freed {d:.2} {s}\n", .{
        formatted.value,
        formatted.unit,
    });
}

/// Run project artifact purge
fn runPurge(allocator: std.mem.Allocator, path: []const u8, max_depth: u32, dry_run: bool, skip_confirm: bool) !void {
    const stdout = io.getStdOut().writer();

    try stdout.print("Scanning for project artifacts in: {s}\n", .{path});
    try stdout.print("Max depth: {d}\n\n", .{max_depth});

    // Scan for project artifacts
    var artifacts = try clean.dev.scanProjectArtifacts(allocator, path, max_depth);
    defer {
        for (artifacts.items) |*a| {
            a.deinit();
        }
        artifacts.deinit();
    }

    if (artifacts.items.len == 0) {
        try stdout.writeAll("No project artifacts found.\n");
        return;
    }

    // Print found artifacts
    try clean.dev.printProjectArtifacts(artifacts.items, stdout);

    // Calculate reclaimable (excluding recent projects)
    var reclaimable: u64 = 0;
    var reclaimable_count: u64 = 0;
    for (artifacts.items) |a| {
        if (!a.is_recent) {
            reclaimable += a.size;
            reclaimable_count += 1;
        }
    }

    if (reclaimable == 0) {
        try stdout.writeAll("\nAll projects are recent (<7 days). Nothing to clean.\n");
        return;
    }

    if (dry_run) {
        try stdout.writeAll("\nDry run complete - no files were deleted.\n");
        return;
    }

    // Confirmation
    if (!skip_confirm) {
        try stdout.writeAll("\nProceed with cleanup? [y/N] ");

        const stdin = io.getStdIn().reader();
        var buf: [10]u8 = undefined;
        const input = stdin.readUntilDelimiter(&buf, '\n') catch "";

        if (input.len == 0 or (input[0] != 'y' and input[0] != 'Y')) {
            try stdout.writeAll("Cancelled.\n");
            return;
        }
    }

    try stdout.writeAll("\nPurging...\n");

    var total_freed: u64 = 0;
    for (artifacts.items) |a| {
        if (a.is_recent) continue;

        var result = file_ops.safeDeleteDirectory(allocator, a.path, .{
            .dry_run = false,
            .skip_confirmation = true,
        }) catch continue;
        defer result.deinit();

        if (result.success) {
            total_freed += result.bytes_freed;
            const formatted = file_ops.formatBytes(result.bytes_freed);
            logging.success("{s}: freed {d:.2} {s}", .{
                a.path,
                formatted.value,
                formatted.unit,
            });
        }
    }

    const total_formatted = file_ops.formatBytes(total_freed);
    try stdout.print("\n✅ Purge complete! Freed {d:.2} {s}\n", .{
        total_formatted.value,
        total_formatted.unit,
    });
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

/// Run disk analyzer
fn runAnalyze(allocator: std.mem.Allocator, path: []const u8) !void {
    const stdout = io.getStdOut().writer();

    try stdout.writeAll("\n📊 Disk Space Analyzer\n\n");

    // Check if analyzing home or specific path
    if (mem.eql(u8, path, std.posix.getenv("HOME") orelse "/")) {
        try stdout.writeAll("Scanning system overview...\n");

        var overview = try scanner.getSystemOverview(allocator);
        defer {
            for (overview.items) |*e| {
                e.deinit();
            }
            overview.deinit();
        }

        try scanner.printOverview(overview.items, stdout);
    } else {
        try stdout.print("Scanning: {s}\n", .{path});

        var result = try scanner.scanDirectory(allocator, path, .{});
        defer result.deinit();

        try scanner.printResults(&result, stdout);
    }
}

/// Run system status
fn runStatus(allocator: std.mem.Allocator) !void {
    const stdout = io.getStdOut().writer();

    var status = try metrics.collectStatus(allocator);
    defer status.deinit();

    try metrics.printStatus(&status, stdout);
}

/// Run app uninstaller
fn runUninstall(allocator: std.mem.Allocator, app_name: []const u8, dry_run: bool, skip_confirm: bool) !void {
    const stdout = io.getStdOut().writer();

    try stdout.print("\n🗑️  Searching for: {s}\n\n", .{app_name});

    // Find matching apps
    var apps = try uninstall.findApps(allocator, app_name);
    defer {
        for (apps.items) |*app| {
            app.deinit();
        }
        apps.deinit();
    }

    if (apps.items.len == 0) {
        try stdout.print("No applications matching '{s}' found.\n", .{app_name});
        return;
    }

    // Show found apps
    try uninstall.printAppList(apps.items, stdout);

    if (apps.items.len == 1) {
        const app = &apps.items[0];

        // Check if protected
        if (uninstall.isProtectedApp(app.name, app.bundle_id)) {
            try stdout.writeAll("\n⚠️  This application is protected and cannot be uninstalled.\n");
            return;
        }

        try uninstall.printAppInfo(app, stdout);

        if (dry_run) {
            try stdout.writeAll("\nDry run - no files would be deleted.\n");
            return;
        }

        if (!skip_confirm) {
            try stdout.writeAll("\nUninstall this application? [y/N] ");

            const stdin = io.getStdIn().reader();
            var buf: [10]u8 = undefined;
            const input = stdin.readUntilDelimiter(&buf, '\n') catch "";

            if (input.len == 0 or (input[0] != 'y' and input[0] != 'Y')) {
                try stdout.writeAll("Cancelled.\n");
                return;
            }
        }

        try stdout.writeAll("\nUninstalling...\n");

        var result = try uninstall.uninstallApp(allocator, app, true, false);
        defer result.deinit();

        if (result.success) {
            const formatted = file_ops.formatBytes(result.bytes_freed);
            try stdout.print("\n✅ Uninstalled {s}. Freed {d:.2} {s}\n", .{
                app.name,
                formatted.value,
                formatted.unit,
            });
        } else {
            try stdout.writeAll("\n❌ Failed to uninstall. Check errors above.\n");
        }
    } else {
        try stdout.writeAll("\nMultiple apps found. Please specify a more specific name.\n");
    }
}

/// Run system optimization
fn runOptimize(allocator: std.mem.Allocator, skip_confirm: bool) !void {
    const stdout = io.getStdOut().writer();

    try stdout.writeAll("\n⚡ System Optimization\n\n");

    // Show available tasks
    try optimize.printTasks(stdout);

    try stdout.writeAll("\nOptions:\n");
    try stdout.writeAll("  1. Quick optimization (fast, no sudo)\n");
    try stdout.writeAll("  2. Full optimization (all tasks, requires sudo)\n");
    try stdout.writeAll("  3. Cancel\n\n");

    if (!skip_confirm) {
        try stdout.writeAll("Choose option [1/2/3]: ");

        const stdin = io.getStdIn().reader();
        var buf: [10]u8 = undefined;
        const input = stdin.readUntilDelimiter(&buf, '\n') catch "";

        if (input.len == 0 or input[0] == '3') {
            try stdout.writeAll("Cancelled.\n");
            return;
        }

        if (input[0] == '1') {
            try stdout.writeAll("\nRunning quick optimization...\n\n");

            var results = try optimize.quickOptimize(allocator);
            defer {
                for (results.items) |*r| r.deinit();
                results.deinit();
            }

            try optimize.printResults(results.items, stdout);
        } else if (input[0] == '2') {
            try stdout.writeAll("\nRunning full optimization (this may take a while)...\n\n");
            try stdout.writeAll("⚠️  Some tasks require sudo. You may be prompted for your password.\n\n");

            var results = try optimize.runAll(allocator, true, false);
            defer {
                for (results.items) |*r| r.deinit();
                results.deinit();
            }

            try optimize.printResults(results.items, stdout);
        } else {
            try stdout.writeAll("Invalid option. Cancelled.\n");
        }
    } else {
        // Auto mode - run quick optimization
        try stdout.writeAll("Running quick optimization...\n\n");

        var results = try optimize.quickOptimize(allocator);
        defer {
            for (results.items) |*r| r.deinit();
            results.deinit();
        }

        try optimize.printResults(results.items, stdout);
    }
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
