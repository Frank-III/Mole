const std = @import("std");
const fs = std.fs;
const mem = std.mem;
const Allocator = mem.Allocator;
const Child = std.process.Child;

const file_ops = @import("../core/file_ops.zig");
const logging = @import("../core/logging.zig");
const safety = @import("../core/safety.zig");

const log = logging.scoped("optimize");

/// Optimization task category
pub const TaskCategory = enum {
    maintenance,
    network,
    spotlight,
    launch_services,
    memory,
    disk,

    pub fn displayName(self: TaskCategory) []const u8 {
        return switch (self) {
            .maintenance => "System Maintenance",
            .network => "Network",
            .spotlight => "Spotlight",
            .launch_services => "Launch Services",
            .memory => "Memory",
            .disk => "Disk",
        };
    }
};

/// Optimization task
pub const Task = struct {
    name: []const u8,
    description: []const u8,
    category: TaskCategory,
    command: []const []const u8,
    requires_sudo: bool = false,
    /// Estimated time in seconds
    estimated_time: u32 = 5,
};

/// Available optimization tasks
pub const TASKS = [_]Task{
    // Maintenance scripts
    .{
        .name = "Daily Maintenance",
        .description = "Run daily system maintenance scripts",
        .category = .maintenance,
        .command = &.{ "periodic", "daily" },
        .requires_sudo = true,
        .estimated_time = 30,
    },
    .{
        .name = "Weekly Maintenance",
        .description = "Run weekly system maintenance scripts",
        .category = .maintenance,
        .command = &.{ "periodic", "weekly" },
        .requires_sudo = true,
        .estimated_time = 60,
    },
    .{
        .name = "Monthly Maintenance",
        .description = "Run monthly system maintenance scripts",
        .category = .maintenance,
        .command = &.{ "periodic", "monthly" },
        .requires_sudo = true,
        .estimated_time = 120,
    },

    // Network
    .{
        .name = "Flush DNS Cache",
        .description = "Clear the DNS resolver cache",
        .category = .network,
        .command = &.{ "dscacheutil", "-flushcache" },
        .requires_sudo = false,
        .estimated_time = 2,
    },
    .{
        .name = "Restart mDNSResponder",
        .description = "Restart the DNS responder service",
        .category = .network,
        .command = &.{ "killall", "-HUP", "mDNSResponder" },
        .requires_sudo = true,
        .estimated_time = 3,
    },

    // Spotlight
    .{
        .name = "Rebuild Spotlight Index",
        .description = "Rebuild the Spotlight search index for root volume",
        .category = .spotlight,
        .command = &.{ "mdutil", "-E", "/" },
        .requires_sudo = true,
        .estimated_time = 300,
    },

    // Launch Services
    .{
        .name = "Rebuild Launch Services",
        .description = "Rebuild the Launch Services database",
        .category = .launch_services,
        .command = &.{
            "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister",
            "-kill", "-r", "-domain", "local", "-domain", "system", "-domain", "user",
        },
        .requires_sudo = false,
        .estimated_time = 30,
    },

    // Memory
    .{
        .name = "Purge Memory",
        .description = "Free up inactive memory",
        .category = .memory,
        .command = &.{"purge"},
        .requires_sudo = true,
        .estimated_time = 10,
    },

    // Disk
    .{
        .name = "Verify Disk",
        .description = "Verify the startup disk",
        .category = .disk,
        .command = &.{ "diskutil", "verifyVolume", "/" },
        .requires_sudo = false,
        .estimated_time = 120,
    },
};

/// Result of running a task
pub const TaskResult = struct {
    task: Task,
    success: bool,
    output: ?[]const u8,
    error_msg: ?[]const u8,
    duration_ms: u64,
    allocator: Allocator,

    pub fn deinit(self: *TaskResult) void {
        if (self.output) |o| self.allocator.free(o);
        if (self.error_msg) |e| self.allocator.free(e);
    }
};

/// Run a single optimization task
pub fn runTask(allocator: Allocator, task: Task, use_sudo: bool) !TaskResult {
    const start = std.time.milliTimestamp();

    var result = TaskResult{
        .task = task,
        .success = false,
        .output = null,
        .error_msg = null,
        .duration_ms = 0,
        .allocator = allocator,
    };

    // Build command with sudo if needed
    var argv = std.ArrayList([]const u8).init(allocator);
    defer argv.deinit();

    if (task.requires_sudo and use_sudo) {
        try argv.append("sudo");
    }

    for (task.command) |arg| {
        try argv.append(arg);
    }

    // Spawn process
    var child = Child.init(argv.items, allocator);
    child.stderr_behavior = .Pipe;
    child.stdout_behavior = .Pipe;

    child.spawn() catch |err| {
        result.error_msg = try std.fmt.allocPrint(allocator, "Failed to spawn: {s}", .{@errorName(err)});
        return result;
    };

    // Wait for completion
    const term = child.wait() catch |err| {
        result.error_msg = try std.fmt.allocPrint(allocator, "Failed to wait: {s}", .{@errorName(err)});
        return result;
    };

    const end = std.time.milliTimestamp();
    result.duration_ms = @intCast(@max(0, end - start));

    // Check exit status
    result.success = term.Exited == 0;

    if (!result.success) {
        // Read stderr
        if (child.stderr) |stderr| {
            var buf: [4096]u8 = undefined;
            const len = stderr.read(&buf) catch 0;
            if (len > 0) {
                result.error_msg = try allocator.dupe(u8, buf[0..len]);
            }
        }
    }

    return result;
}

/// Run all tasks in a category
pub fn runCategory(allocator: Allocator, category: TaskCategory, use_sudo: bool) !std.ArrayList(TaskResult) {
    var results = std.ArrayList(TaskResult).init(allocator);
    errdefer {
        for (results.items) |*r| r.deinit();
        results.deinit();
    }

    for (TASKS) |task| {
        if (task.category == category) {
            log.info("Running: {s}", .{task.name});
            const result = try runTask(allocator, task, use_sudo);
            try results.append(result);
        }
    }

    return results;
}

/// Run all optimization tasks
pub fn runAll(allocator: Allocator, use_sudo: bool, skip_slow: bool) !std.ArrayList(TaskResult) {
    var results = std.ArrayList(TaskResult).init(allocator);
    errdefer {
        for (results.items) |*r| r.deinit();
        results.deinit();
    }

    for (TASKS) |task| {
        // Skip slow tasks if requested
        if (skip_slow and task.estimated_time > 60) {
            continue;
        }

        // Skip sudo tasks if not using sudo
        if (task.requires_sudo and !use_sudo) {
            continue;
        }

        log.info("Running: {s}", .{task.name});
        const result = try runTask(allocator, task, use_sudo);
        try results.append(result);
    }

    return results;
}

/// Print available tasks
pub fn printTasks(writer: anytype) !void {
    try writer.writeAll("\n══════════════════════════════════════════════════════\n");
    try writer.writeAll("           AVAILABLE OPTIMIZATION TASKS\n");
    try writer.writeAll("══════════════════════════════════════════════════════\n\n");

    var current_category: ?TaskCategory = null;

    for (TASKS) |task| {
        if (current_category == null or current_category.? != task.category) {
            current_category = task.category;
            try writer.print("\n{s}:\n", .{task.category.displayName()});
        }

        const sudo_indicator = if (task.requires_sudo) " 🔐" else "";
        const time_str = if (task.estimated_time >= 60)
            try std.fmt.allocPrint(std.heap.page_allocator, "~{d}m", .{task.estimated_time / 60})
        else
            try std.fmt.allocPrint(std.heap.page_allocator, "~{d}s", .{task.estimated_time});

        try writer.print("  • {s}{s} ({s})\n", .{ task.name, sudo_indicator, time_str });
        try writer.print("    {s}\n", .{task.description});
    }

    try writer.writeAll("\n🔐 = Requires sudo\n");
}

/// Print task results
pub fn printResults(results: []const TaskResult, writer: anytype) !void {
    try writer.writeAll("\n══════════════════════════════════════════════════════\n");
    try writer.writeAll("              OPTIMIZATION RESULTS\n");
    try writer.writeAll("══════════════════════════════════════════════════════\n\n");

    var success_count: u32 = 0;
    var fail_count: u32 = 0;
    var total_time: u64 = 0;

    for (results) |r| {
        const status = if (r.success) "✅" else "❌";
        try writer.print("{s} {s} ({d}ms)\n", .{ status, r.task.name, r.duration_ms });

        if (!r.success) {
            if (r.error_msg) |err| {
                try writer.print("   Error: {s}\n", .{err});
            }
            fail_count += 1;
        } else {
            success_count += 1;
        }

        total_time += r.duration_ms;
    }

    try writer.writeAll("\n─────────────────────────────────────────────────────\n");
    try writer.print("Completed: {d} succeeded, {d} failed\n", .{ success_count, fail_count });
    try writer.print("Total time: {d}ms\n", .{total_time});
}

/// Quick optimization (fast tasks only, no sudo)
pub fn quickOptimize(allocator: Allocator) !std.ArrayList(TaskResult) {
    var results = std.ArrayList(TaskResult).init(allocator);
    errdefer {
        for (results.items) |*r| r.deinit();
        results.deinit();
    }

    // Only run fast, non-sudo tasks
    const quick_tasks = [_][]const u8{
        "Flush DNS Cache",
        "Rebuild Launch Services",
    };

    for (TASKS) |task| {
        for (quick_tasks) |quick_name| {
            if (mem.eql(u8, task.name, quick_name)) {
                log.info("Running: {s}", .{task.name});
                const result = try runTask(allocator, task, false);
                try results.append(result);
                break;
            }
        }
    }

    return results;
}

// ============================================================================
// Finder & Dock Refresh
// ============================================================================

/// Restart Finder
pub fn restartFinder(allocator: Allocator) !TaskResult {
    return runTask(allocator, .{
        .name = "Restart Finder",
        .description = "Restart the Finder application",
        .category = .maintenance,
        .command = &.{ "killall", "Finder" },
        .requires_sudo = false,
        .estimated_time = 2,
    }, false);
}

/// Restart Dock
pub fn restartDock(allocator: Allocator) !TaskResult {
    return runTask(allocator, .{
        .name = "Restart Dock",
        .description = "Restart the Dock application",
        .category = .maintenance,
        .command = &.{ "killall", "Dock" },
        .requires_sudo = false,
        .estimated_time = 2,
    }, false);
}

/// Clear font caches
pub fn clearFontCaches(allocator: Allocator) !TaskResult {
    return runTask(allocator, .{
        .name = "Clear Font Caches",
        .description = "Clear system font caches",
        .category = .maintenance,
        .command = &.{ "atsutil", "databases", "-remove" },
        .requires_sudo = true,
        .estimated_time = 5,
    }, true);
}

// ============================================================================
// Tests
// ============================================================================

test "task categories" {
    try std.testing.expectEqualStrings("System Maintenance", TaskCategory.maintenance.displayName());
    try std.testing.expectEqualStrings("Network", TaskCategory.network.displayName());
}

test "tasks exist" {
    try std.testing.expect(TASKS.len > 0);

    // Verify all tasks have required fields
    for (TASKS) |task| {
        try std.testing.expect(task.name.len > 0);
        try std.testing.expect(task.command.len > 0);
    }
}
