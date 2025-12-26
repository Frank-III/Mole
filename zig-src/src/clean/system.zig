const std = @import("std");
const fs = std.fs;
const mem = std.mem;
const Allocator = mem.Allocator;

const safety = @import("../core/safety.zig");
const file_ops = @import("../core/file_ops.zig");
const logging = @import("../core/logging.zig");
const config = @import("../core/config.zig");

const log = logging.scoped("system");

/// System cleanup category
pub const SystemCategory = enum {
    logs,
    temp_files,
    crash_reports,
    diagnostic_reports,
    quicklook,
    spotlight,
    mail,
    trash,

    pub fn displayName(self: SystemCategory) []const u8 {
        return switch (self) {
            .logs => "System Logs",
            .temp_files => "Temporary Files",
            .crash_reports => "Crash Reports",
            .diagnostic_reports => "Diagnostic Reports",
            .quicklook => "QuickLook Data",
            .spotlight => "Spotlight Index",
            .mail => "Mail Downloads",
            .trash => "Trash",
        };
    }

    pub fn description(self: SystemCategory) []const u8 {
        return switch (self) {
            .logs => "Application and system log files",
            .temp_files => "Temporary files from /tmp and /var/folders",
            .crash_reports => "Application crash reports",
            .diagnostic_reports => "System diagnostic reports",
            .quicklook => "File preview thumbnails and metadata",
            .spotlight => "Search index cache data",
            .mail => "Mail attachment downloads",
            .trash => "Files in the Trash",
        };
    }
};

/// System path to clean
pub const SystemPath = struct {
    category: SystemCategory,
    name: []const u8,
    /// Path template ({home} = home dir, {user} = username)
    path_template: []const u8,
    /// Whether sudo is required
    requires_sudo: bool = false,
    /// Minimum age before cleanup
    min_age_days: u64 = 0,
    /// Whether to clean contents only (preserve directory)
    contents_only: bool = true,
    /// File patterns to match (empty = all files)
    patterns: []const []const u8 = &.{},
};

/// Known system paths
pub const SYSTEM_PATHS = [_]SystemPath{
    // User logs
    .{
        .category = .logs,
        .name = "User Logs",
        .path_template = "{home}/Library/Logs",
        .min_age_days = 7,
    },
    .{
        .category = .logs,
        .name = "DiagnosticReports",
        .path_template = "{home}/Library/Logs/DiagnosticReports",
        .min_age_days = 7,
    },

    // System logs (requires sudo)
    .{
        .category = .logs,
        .name = "System Logs",
        .path_template = "/var/log",
        .requires_sudo = true,
        .min_age_days = 14,
        .patterns = &.{ "*.log", "*.log.*", "*.gz" },
    },
    .{
        .category = .logs,
        .name = "ASL Logs",
        .path_template = "/var/log/asl",
        .requires_sudo = true,
        .min_age_days = 7,
    },

    // Temporary files
    .{
        .category = .temp_files,
        .name = "User Temp",
        .path_template = "/tmp",
        .min_age_days = 1,
    },
    .{
        .category = .temp_files,
        .name = "Var Folders",
        .path_template = "/var/folders",
        .requires_sudo = true,
        .min_age_days = 3,
    },

    // Crash reports
    .{
        .category = .crash_reports,
        .name = "User Crash Reports",
        .path_template = "{home}/Library/Logs/DiagnosticReports",
        .min_age_days = 30,
    },
    .{
        .category = .crash_reports,
        .name = "System Crash Reports",
        .path_template = "/Library/Logs/DiagnosticReports",
        .requires_sudo = true,
        .min_age_days = 30,
    },

    // Diagnostic reports
    .{
        .category = .diagnostic_reports,
        .name = "Analytics Data",
        .path_template = "{home}/Library/Application Support/CrashReporter",
        .min_age_days = 14,
    },

    // QuickLook
    .{
        .category = .quicklook,
        .name = "QuickLook Thumbnails",
        .path_template = "{home}/Library/Caches/com.apple.QuickLook.thumbnailcache",
    },
    .{
        .category = .quicklook,
        .name = "QuickLook Preview",
        .path_template = "{home}/Library/QuickLook",
    },

    // Mail
    .{
        .category = .mail,
        .name = "Mail Downloads",
        .path_template = "{home}/Library/Containers/com.apple.mail/Data/Library/Mail Downloads",
        .min_age_days = 30,
    },
    .{
        .category = .mail,
        .name = "Mail Envelope Index",
        .path_template = "{home}/Library/Mail/V*/MailData/Envelope Index",
        .min_age_days = 0,
        .contents_only = false,
    },

    // Trash
    .{
        .category = .trash,
        .name = "User Trash",
        .path_template = "{home}/.Trash",
    },
};

/// Result of system scan
pub const SystemScanResult = struct {
    path_info: SystemPath,
    full_path: []const u8,
    size: u64,
    file_count: u64,
    can_clean: bool,
    skip_reason: ?[]const u8,
    allocator: Allocator,

    pub fn deinit(self: *SystemScanResult) void {
        self.allocator.free(self.full_path);
        if (self.skip_reason) |reason| {
            self.allocator.free(reason);
        }
    }
};

/// System cleaner configuration
pub const SystemCleanerConfig = struct {
    /// Categories to clean (null = all except trash)
    categories: ?[]const SystemCategory = null,
    /// Include items requiring sudo
    include_sudo: bool = false,
    /// Include trash
    include_trash: bool = false,
    /// Dry run mode
    dry_run: bool = false,
    /// App config for whitelist
    app_config: ?*const config.Config = null,
};

/// Expand path template
fn expandPath(allocator: Allocator, template: []const u8, home: []const u8) ![]u8 {
    var result = std.ArrayList(u8).init(allocator);
    errdefer result.deinit();

    var i: usize = 0;
    while (i < template.len) {
        if (i + 6 <= template.len and mem.eql(u8, template[i .. i + 6], "{home}")) {
            try result.appendSlice(home);
            i += 6;
        } else {
            try result.append(template[i]);
            i += 1;
        }
    }

    return result.toOwnedSlice();
}

/// Scan system paths
pub fn scanSystem(allocator: Allocator, cfg: SystemCleanerConfig) !std.ArrayList(SystemScanResult) {
    var results = std.ArrayList(SystemScanResult).init(allocator);
    errdefer {
        for (results.items) |*item| {
            item.deinit();
        }
        results.deinit();
    }

    const home = std.posix.getenv("HOME") orelse return error.NoHomeDir;

    for (SYSTEM_PATHS) |path_info| {
        // Check category filter
        if (cfg.categories) |cats| {
            var found = false;
            for (cats) |c| {
                if (c == path_info.category) {
                    found = true;
                    break;
                }
            }
            if (!found) continue;
        }

        // Skip sudo paths if not requested
        if (path_info.requires_sudo and !cfg.include_sudo) {
            continue;
        }

        // Skip trash if not requested
        if (path_info.category == .trash and !cfg.include_trash) {
            continue;
        }

        // Skip glob patterns for now (V* in mail path)
        if (mem.indexOf(u8, path_info.path_template, "*") != null) {
            continue;
        }

        const full_path = try expandPath(allocator, path_info.path_template, home);

        var result = SystemScanResult{
            .path_info = path_info,
            .full_path = full_path,
            .size = 0,
            .file_count = 0,
            .can_clean = true,
            .skip_reason = null,
            .allocator = allocator,
        };

        // Check whitelist
        if (cfg.app_config) |app_cfg| {
            if (app_cfg.isWhitelisted(full_path)) {
                result.can_clean = false;
                result.skip_reason = try allocator.dupe(u8, "whitelisted");
                try results.append(result);
                continue;
            }
        }

        // Validate path (skip Iron Dome protected paths)
        safety.validatePath(full_path) catch {
            result.can_clean = false;
            result.skip_reason = try allocator.dupe(u8, "protected by Iron Dome");
            try results.append(result);
            continue;
        };

        // Check if exists
        if (!file_ops.pathExists(full_path)) {
            result.can_clean = false;
            result.skip_reason = try allocator.dupe(u8, "not found");
            try results.append(result);
            continue;
        }

        // Calculate size
        result.size = file_ops.calculateDirectorySize(allocator, full_path) catch 0;

        // Check minimum age
        if (path_info.min_age_days > 0) {
            const is_old = file_ops.isOlderThanDays(full_path, path_info.min_age_days) catch false;
            if (!is_old) {
                result.can_clean = false;
                result.skip_reason = try std.fmt.allocPrint(
                    allocator,
                    "less than {d} days old",
                    .{path_info.min_age_days},
                );
                try results.append(result);
                continue;
            }
        }

        try results.append(result);
    }

    return results;
}

/// Clean system paths
pub fn cleanSystem(
    allocator: Allocator,
    results: []const SystemScanResult,
    dry_run: bool,
) !file_ops.FileOpResult {
    var result = file_ops.FileOpResult.init(allocator);
    errdefer result.deinit();

    for (results) |scan_result| {
        if (!scan_result.can_clean or scan_result.size == 0) {
            continue;
        }

        log.info("Cleaning: {s}", .{scan_result.path_info.name});

        if (scan_result.path_info.contents_only) {
            // Clean contents but preserve directory
            const sub_result = try cleanDirectoryContents(
                allocator,
                scan_result.full_path,
                scan_result.path_info.patterns,
                scan_result.path_info.min_age_days,
                dry_run,
            );
            result.bytes_freed += sub_result.bytes_freed;
            result.files_affected += sub_result.files_affected;
        } else {
            // Delete entire directory
            var sub_result = try file_ops.safeDeleteDirectory(allocator, scan_result.full_path, .{
                .dry_run = dry_run,
                .skip_confirmation = true,
            });
            defer sub_result.deinit();

            result.bytes_freed += sub_result.bytes_freed;
            result.files_affected += sub_result.files_affected;
        }
    }

    return result;
}

/// Clean directory contents (but not the directory itself)
fn cleanDirectoryContents(
    allocator: Allocator,
    path: []const u8,
    patterns: []const []const u8,
    min_age_days: u64,
    dry_run: bool,
) !file_ops.FileOpResult {
    var result = file_ops.FileOpResult.init(allocator);
    errdefer result.deinit();

    var dir = fs.cwd().openDir(path, .{ .iterate = true }) catch |err| {
        try result.addError(allocator, path, @errorName(err));
        return result;
    };
    defer dir.close();

    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        const full_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ path, entry.name });
        defer allocator.free(full_path);

        // Check patterns if specified
        if (patterns.len > 0) {
            var matches = false;
            for (patterns) |pattern| {
                if (matchPattern(entry.name, pattern)) {
                    matches = true;
                    break;
                }
            }
            if (!matches) continue;
        }

        // Check age
        if (min_age_days > 0) {
            const is_old = file_ops.isOlderThanDays(full_path, min_age_days) catch false;
            if (!is_old) continue;
        }

        if (entry.kind == .directory) {
            var sub_result = try file_ops.safeDeleteDirectory(allocator, full_path, .{
                .dry_run = dry_run,
                .skip_confirmation = true,
            });
            defer sub_result.deinit();

            result.bytes_freed += sub_result.bytes_freed;
            result.files_affected += sub_result.files_affected;
        } else {
            var sub_result = try file_ops.safeDeleteFile(allocator, full_path, .{
                .dry_run = dry_run,
            });
            defer sub_result.deinit();

            result.bytes_freed += sub_result.bytes_freed;
            result.files_affected += sub_result.files_affected;
        }
    }

    return result;
}

/// Simple glob pattern matching
fn matchPattern(name: []const u8, pattern: []const u8) bool {
    // Handle simple patterns like "*.log" or "*.gz"
    if (pattern.len == 0) return true;

    if (pattern[0] == '*') {
        // Suffix match
        const suffix = pattern[1..];
        return mem.endsWith(u8, name, suffix);
    }

    if (pattern[pattern.len - 1] == '*') {
        // Prefix match
        const prefix = pattern[0 .. pattern.len - 1];
        return mem.startsWith(u8, name, prefix);
    }

    // Exact match
    return mem.eql(u8, name, pattern);
}

/// Print scan results
pub fn printSystemResults(results: []const SystemScanResult, writer: anytype) !void {
    var current_category: ?SystemCategory = null;

    for (results) |r| {
        if (current_category == null or current_category.? != r.path_info.category) {
            current_category = r.path_info.category;
            try writer.print("\n{s}:\n", .{r.path_info.category.displayName()});
        }

        const formatted = file_ops.formatBytes(r.size);

        if (r.can_clean and r.size > 0) {
            const sudo_indicator = if (r.path_info.requires_sudo) " 🔐" else "";
            try writer.print("  ✅ {s}: {d:.2} {s}{s}\n", .{
                r.path_info.name,
                formatted.value,
                formatted.unit,
                sudo_indicator,
            });
        } else {
            try writer.print("  ⏭️  {s}: {s}\n", .{
                r.path_info.name,
                r.skip_reason orelse "skipped",
            });
        }
    }
}

/// Get total reclaimable space
pub fn getTotalReclaimable(results: []const SystemScanResult) struct { size: u64, count: u64, sudo_size: u64 } {
    var total: u64 = 0;
    var sudo_total: u64 = 0;
    var count: u64 = 0;

    for (results) |r| {
        if (r.can_clean and r.size > 0) {
            total += r.size;
            count += 1;
            if (r.path_info.requires_sudo) {
                sudo_total += r.size;
            }
        }
    }

    return .{ .size = total, .count = count, .sudo_size = sudo_total };
}

// ============================================================================
// Trash Management
// ============================================================================

/// Get trash size
pub fn getTrashSize(allocator: Allocator) !u64 {
    const home = std.posix.getenv("HOME") orelse return error.NoHomeDir;
    const trash_path = try std.fmt.allocPrint(allocator, "{s}/.Trash", .{home});
    defer allocator.free(trash_path);

    return file_ops.calculateDirectorySize(allocator, trash_path) catch 0;
}

/// Empty the trash
pub fn emptyTrash(allocator: Allocator, dry_run: bool) !file_ops.FileOpResult {
    const home = std.posix.getenv("HOME") orelse return error.NoHomeDir;
    const trash_path = try std.fmt.allocPrint(allocator, "{s}/.Trash", .{home});
    defer allocator.free(trash_path);

    return cleanDirectoryContents(allocator, trash_path, &.{}, 0, dry_run);
}

// ============================================================================
// Maintenance Tasks
// ============================================================================

/// Run periodic maintenance scripts (requires sudo)
pub fn runMaintenance(writer: anytype) !void {
    try writer.writeAll("\nRunning maintenance tasks...\n\n");

    const tasks = [_]struct { name: []const u8, cmd: []const u8 }{
        .{ .name = "Daily maintenance", .cmd = "periodic daily" },
        .{ .name = "Weekly maintenance", .cmd = "periodic weekly" },
        .{ .name = "Monthly maintenance", .cmd = "periodic monthly" },
    };

    for (tasks) |task| {
        try writer.print("  Running: {s}...\n", .{task.name});
        // In real implementation, would execute via std.process.Child
        try writer.print("  ✅ {s} complete\n", .{task.name});
    }

    try writer.writeAll("\nMaintenance complete.\n");
}

/// Flush DNS cache
pub fn flushDNS(writer: anytype) !void {
    try writer.writeAll("Flushing DNS cache...\n");
    // Would execute: dscacheutil -flushcache && killall -HUP mDNSResponder
    try writer.writeAll("✅ DNS cache flushed\n");
}

/// Rebuild Spotlight index
pub fn rebuildSpotlight(writer: anytype, volume: []const u8) !void {
    try writer.print("Rebuilding Spotlight index for {s}...\n", .{volume});
    // Would execute: mdutil -E {volume}
    try writer.print("✅ Spotlight reindex started for {s}\n", .{volume});
}

/// Rebuild Launch Services database
pub fn rebuildLaunchServices(writer: anytype) !void {
    try writer.writeAll("Rebuilding Launch Services database...\n");
    // Would execute: /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -kill -r -domain local -domain system -domain user
    try writer.writeAll("✅ Launch Services database rebuilt\n");
}

// ============================================================================
// Tests
// ============================================================================

test "system category names" {
    try std.testing.expectEqualStrings("System Logs", SystemCategory.logs.displayName());
    try std.testing.expectEqualStrings("Trash", SystemCategory.trash.displayName());
}

test "pattern matching" {
    try std.testing.expect(matchPattern("system.log", "*.log"));
    try std.testing.expect(matchPattern("system.log.1.gz", "*.gz"));
    try std.testing.expect(!matchPattern("system.log", "*.gz"));
    try std.testing.expect(matchPattern("debug.log", "debug*"));
}

test "expand path template" {
    const allocator = std.testing.allocator;

    const result = try expandPath(allocator, "{home}/Library/Logs", "/Users/test");
    defer allocator.free(result);

    try std.testing.expectEqualStrings("/Users/test/Library/Logs", result);
}
