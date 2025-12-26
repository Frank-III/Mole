const std = @import("std");
const fs = std.fs;
const mem = std.mem;
const Allocator = mem.Allocator;

const safety = @import("../core/safety.zig");
const file_ops = @import("../core/file_ops.zig");
const logging = @import("../core/logging.zig");
const config = @import("../core/config.zig");

const log = logging.scoped("caches");

/// Cache category for reporting
pub const CacheCategory = enum {
    user_caches,
    app_caches,
    system_caches,
    spotlight,
    quicklook,
    saved_state,

    pub fn displayName(self: CacheCategory) []const u8 {
        return switch (self) {
            .user_caches => "User Caches",
            .app_caches => "Application Caches",
            .system_caches => "System Caches",
            .spotlight => "Spotlight Index",
            .quicklook => "QuickLook Thumbnails",
            .saved_state => "Saved Application State",
        };
    }

    pub fn description(self: CacheCategory) []const u8 {
        return switch (self) {
            .user_caches => "General application cache files",
            .app_caches => "App-specific cached data",
            .system_caches => "System-level caches",
            .spotlight => "Spotlight search index cache",
            .quicklook => "File preview thumbnails",
            .saved_state => "Application window states",
        };
    }
};

/// Individual cache target
pub const CacheTarget = struct {
    name: []const u8,
    path_template: []const u8,
    category: CacheCategory,
    requires_sudo: bool = false,
    min_age_days: u64 = 0,
    /// Patterns to exclude from cleanup
    exclude_patterns: []const []const u8 = &.{},
};

/// Default cache cleanup targets
pub const DEFAULT_TARGETS = [_]CacheTarget{
    // User caches
    .{
        .name = "User Library Caches",
        .path_template = "{s}/Library/Caches",
        .category = .user_caches,
        .exclude_patterns = &.{
            "CloudKit",
            "com.apple.Safari",
            "com.apple.iCloud",
        },
    },
    .{
        .name = "QuickLook Thumbnails",
        .path_template = "{s}/Library/Caches/com.apple.QuickLook.thumbnailcache",
        .category = .quicklook,
    },
    .{
        .name = "Safari Cache",
        .path_template = "{s}/Library/Caches/com.apple.Safari",
        .category = .app_caches,
        .min_age_days = 7,
    },

    // Saved application state
    .{
        .name = "Saved Application State",
        .path_template = "{s}/Library/Saved Application State",
        .category = .saved_state,
        .min_age_days = 30,
    },

    // Temporary files
    .{
        .name = "User Temp Files",
        .path_template = "{s}/.Trash",
        .category = .user_caches,
    },

    // System caches (may need sudo)
    .{
        .name = "System Caches",
        .path_template = "/Library/Caches",
        .category = .system_caches,
        .requires_sudo = true,
        .exclude_patterns = &.{
            "com.apple.installer",
            "com.apple.softwareupdate",
        },
    },
};

/// Result of scanning a cache target
pub const ScanResult = struct {
    target: CacheTarget,
    path: []const u8,
    size: u64,
    file_count: u64,
    can_clean: bool,
    skip_reason: ?[]const u8,
    allocator: Allocator,

    pub fn deinit(self: *ScanResult) void {
        self.allocator.free(self.path);
        if (self.skip_reason) |reason| {
            self.allocator.free(reason);
        }
    }
};

/// Cache cleaner configuration
pub const CleanerConfig = struct {
    dry_run: bool = false,
    skip_confirmation: bool = false,
    include_system: bool = false,
    min_size_bytes: u64 = 0,
    app_config: ?*const config.Config = null,
};

/// Scan all cache targets and return results
pub fn scanCaches(allocator: Allocator, cfg: CleanerConfig) !std.ArrayList(ScanResult) {
    var results = std.ArrayList(ScanResult).init(allocator);
    errdefer {
        for (results.items) |*item| {
            item.deinit();
        }
        results.deinit();
    }

    const home = std.posix.getenv("HOME") orelse return error.NoHomeDir;

    for (DEFAULT_TARGETS) |target| {
        // Skip system caches if not requested
        if (target.requires_sudo and !cfg.include_system) {
            continue;
        }

        // Expand path template
        const path = if (mem.indexOf(u8, target.path_template, "{s}") != null)
            try std.fmt.allocPrint(allocator, target.path_template, .{home})
        else
            try allocator.dupe(u8, target.path_template);

        var result = ScanResult{
            .target = target,
            .path = path,
            .size = 0,
            .file_count = 0,
            .can_clean = true,
            .skip_reason = null,
            .allocator = allocator,
        };

        // Check if whitelisted
        if (cfg.app_config) |app_cfg| {
            if (app_cfg.isWhitelisted(path)) {
                result.can_clean = false;
                result.skip_reason = try allocator.dupe(u8, "whitelisted");
                try results.append(result);
                continue;
            }
        }

        // Validate path
        safety.validatePath(path) catch {
            result.can_clean = false;
            result.skip_reason = try allocator.dupe(u8, "protected by Iron Dome");
            try results.append(result);
            continue;
        };

        // Check if exists
        if (!file_ops.pathExists(path)) {
            result.can_clean = false;
            result.skip_reason = try allocator.dupe(u8, "not found");
            try results.append(result);
            continue;
        }

        // Calculate size
        result.size = file_ops.calculateDirectorySize(allocator, path) catch 0;

        if (result.size < cfg.min_size_bytes) {
            result.can_clean = false;
            result.skip_reason = try allocator.dupe(u8, "below size threshold");
            try results.append(result);
            continue;
        }

        // Check minimum age if specified
        if (target.min_age_days > 0) {
            const is_old = file_ops.isOlderThanDays(path, target.min_age_days) catch false;
            if (!is_old) {
                result.can_clean = false;
                result.skip_reason = try std.fmt.allocPrint(
                    allocator,
                    "less than {d} days old",
                    .{target.min_age_days},
                );
                try results.append(result);
                continue;
            }
        }

        try results.append(result);
    }

    return results;
}

/// Clean specific cache targets
pub fn cleanCaches(
    allocator: Allocator,
    targets: []const ScanResult,
    cfg: CleanerConfig,
) !file_ops.FileOpResult {
    var result = file_ops.FileOpResult.init(allocator);
    errdefer result.deinit();

    for (targets) |target| {
        if (!target.can_clean) {
            continue;
        }

        log.info("Cleaning: {s}", .{target.target.name});

        // Handle exclusions
        if (target.target.exclude_patterns.len > 0) {
            // Clean selectively, excluding patterns
            const sub_result = try cleanDirectoryWithExclusions(
                allocator,
                target.path,
                target.target.exclude_patterns,
                cfg.dry_run,
            );
            result.bytes_freed += sub_result.bytes_freed;
            result.files_affected += sub_result.files_affected;
        } else {
            // Clean everything
            var sub_result = try file_ops.safeDeleteDirectory(allocator, target.path, .{
                .dry_run = cfg.dry_run,
                .skip_confirmation = cfg.skip_confirmation,
            });
            defer sub_result.deinit();

            result.bytes_freed += sub_result.bytes_freed;
            result.files_affected += sub_result.files_affected;

            if (!sub_result.success) {
                for (sub_result.errors.items) |err| {
                    try result.addError(allocator, err.path, err.message);
                }
            }
        }
    }

    return result;
}

/// Clean a directory while excluding certain patterns
fn cleanDirectoryWithExclusions(
    allocator: Allocator,
    path: []const u8,
    exclusions: []const []const u8,
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
        // Check if excluded
        var excluded = false;
        for (exclusions) |pattern| {
            if (mem.indexOf(u8, entry.name, pattern) != null) {
                excluded = true;
                break;
            }
        }

        if (excluded) {
            log.debug("Skipping excluded: {s}", .{entry.name});
            continue;
        }

        const full_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ path, entry.name });
        defer allocator.free(full_path);

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

/// Get total reclaimable space from scan results
pub fn getTotalReclaimable(results: []const ScanResult) struct { size: u64, count: u64 } {
    var total_size: u64 = 0;
    var count: u64 = 0;

    for (results) |r| {
        if (r.can_clean and r.size > 0) {
            total_size += r.size;
            count += 1;
        }
    }

    return .{ .size = total_size, .count = count };
}

/// Print scan results to writer
pub fn printScanResults(results: []const ScanResult, writer: anytype) !void {
    var current_category: ?CacheCategory = null;

    for (results) |r| {
        // Print category header if changed
        if (current_category == null or current_category.? != r.target.category) {
            current_category = r.target.category;
            try writer.print("\n{s}:\n", .{r.target.category.displayName()});
        }

        const formatted = file_ops.formatBytes(r.size);

        if (r.can_clean) {
            try writer.print("  ✅ {s}: {d:.2} {s}\n", .{
                r.target.name,
                formatted.value,
                formatted.unit,
            });
        } else {
            try writer.print("  ⏭️  {s}: {s}\n", .{
                r.target.name,
                r.skip_reason orelse "skipped",
            });
        }
    }
}

// ============================================================================
// Application-specific cache cleanup
// ============================================================================

/// Known application cache patterns
pub const AppCachePattern = struct {
    app_name: []const u8,
    bundle_id: []const u8,
    cache_paths: []const []const u8,
    safe_to_delete: bool = true,
};

/// Common application cache patterns
pub const APP_CACHE_PATTERNS = [_]AppCachePattern{
    .{
        .app_name = "Spotify",
        .bundle_id = "com.spotify.client",
        .cache_paths = &.{
            "Library/Caches/com.spotify.client",
            "Library/Application Support/Spotify/PersistentCache",
        },
    },
    .{
        .app_name = "Slack",
        .bundle_id = "com.tinyspeck.slackmacgap",
        .cache_paths = &.{
            "Library/Caches/com.tinyspeck.slackmacgap",
            "Library/Application Support/Slack/Cache",
            "Library/Application Support/Slack/Code Cache",
        },
    },
    .{
        .app_name = "Discord",
        .bundle_id = "com.hnc.Discord",
        .cache_paths = &.{
            "Library/Caches/com.hnc.Discord",
            "Library/Application Support/discord/Cache",
            "Library/Application Support/discord/Code Cache",
        },
    },
    .{
        .app_name = "VSCode",
        .bundle_id = "com.microsoft.VSCode",
        .cache_paths = &.{
            "Library/Caches/com.microsoft.VSCode",
            "Library/Application Support/Code/Cache",
            "Library/Application Support/Code/CachedData",
            "Library/Application Support/Code/CachedExtensions",
        },
    },
    .{
        .app_name = "Zoom",
        .bundle_id = "us.zoom.xos",
        .cache_paths = &.{
            "Library/Caches/us.zoom.xos",
            "Library/Application Support/zoom.us/data",
        },
    },
    .{
        .app_name = "Teams",
        .bundle_id = "com.microsoft.teams",
        .cache_paths = &.{
            "Library/Caches/com.microsoft.teams",
            "Library/Application Support/Microsoft/Teams/Cache",
        },
    },
    .{
        .app_name = "Dropbox",
        .bundle_id = "com.getdropbox.dropbox",
        .cache_paths = &.{
            "Library/Caches/com.getdropbox.dropbox",
            "Library/Caches/com.plausiblelabs.crashreporter.data/com.getdropbox.dropbox",
        },
    },
};

/// Scan for application-specific caches
pub fn scanAppCaches(allocator: Allocator) !std.ArrayList(ScanResult) {
    var results = std.ArrayList(ScanResult).init(allocator);
    errdefer {
        for (results.items) |*item| {
            item.deinit();
        }
        results.deinit();
    }

    const home = std.posix.getenv("HOME") orelse return error.NoHomeDir;

    for (APP_CACHE_PATTERNS) |pattern| {
        var total_size: u64 = 0;
        var found = false;

        for (pattern.cache_paths) |cache_path| {
            const full_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ home, cache_path });
            defer allocator.free(full_path);

            if (file_ops.pathExists(full_path)) {
                found = true;
                total_size += file_ops.calculateDirectorySize(allocator, full_path) catch 0;
            }
        }

        if (found and total_size > 0) {
            // Use first cache path as representative
            const path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ home, pattern.cache_paths[0] });

            try results.append(.{
                .target = .{
                    .name = pattern.app_name,
                    .path_template = pattern.cache_paths[0],
                    .category = .app_caches,
                },
                .path = path,
                .size = total_size,
                .file_count = 0,
                .can_clean = pattern.safe_to_delete,
                .skip_reason = null,
                .allocator = allocator,
            });
        }
    }

    return results;
}

// ============================================================================
// Tests
// ============================================================================

test "cache category display names" {
    try std.testing.expectEqualStrings("User Caches", CacheCategory.user_caches.displayName());
    try std.testing.expectEqualStrings("Application Caches", CacheCategory.app_caches.displayName());
}

test "total reclaimable calculation" {
    const results = [_]ScanResult{
        .{
            .target = DEFAULT_TARGETS[0],
            .path = "/test",
            .size = 1000,
            .file_count = 10,
            .can_clean = true,
            .skip_reason = null,
            .allocator = std.testing.allocator,
        },
        .{
            .target = DEFAULT_TARGETS[0],
            .path = "/test2",
            .size = 500,
            .file_count = 5,
            .can_clean = false,
            .skip_reason = null,
            .allocator = std.testing.allocator,
        },
    };

    const totals = getTotalReclaimable(&results);
    try std.testing.expectEqual(@as(u64, 1000), totals.size);
    try std.testing.expectEqual(@as(u64, 1), totals.count);
}
