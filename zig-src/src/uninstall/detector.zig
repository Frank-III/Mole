const std = @import("std");
const fs = std.fs;
const mem = std.mem;
const Allocator = mem.Allocator;

const safety = @import("../core/safety.zig");
const file_ops = @import("../core/file_ops.zig");
const logging = @import("../core/logging.zig");
const config = @import("../core/config.zig");

const log = logging.scoped("uninstall");

/// Application information
pub const AppInfo = struct {
    name: []const u8,
    bundle_id: ?[]const u8,
    path: []const u8,
    size: u64,
    version: ?[]const u8,
    /// Related files (preferences, caches, etc.)
    related_files: std.ArrayList(RelatedFile),
    /// Total size including related files
    total_size: u64,
    allocator: Allocator,

    pub fn deinit(self: *AppInfo) void {
        self.allocator.free(self.name);
        if (self.bundle_id) |id| self.allocator.free(id);
        self.allocator.free(self.path);
        if (self.version) |v| self.allocator.free(v);
        for (self.related_files.items) |*f| {
            f.deinit();
        }
        self.related_files.deinit();
    }
};

/// Related file types
pub const RelatedFileType = enum {
    preferences,
    cache,
    application_support,
    logs,
    containers,
    launch_agent,
    launch_daemon,
    saved_state,
    receipts,
    other,

    pub fn displayName(self: RelatedFileType) []const u8 {
        return switch (self) {
            .preferences => "Preferences",
            .cache => "Cache",
            .application_support => "Application Support",
            .logs => "Logs",
            .containers => "Containers",
            .launch_agent => "Launch Agent",
            .launch_daemon => "Launch Daemon",
            .saved_state => "Saved State",
            .receipts => "Receipts",
            .other => "Other",
        };
    }
};

/// Related file info
pub const RelatedFile = struct {
    path: []const u8,
    file_type: RelatedFileType,
    size: u64,
    is_orphan: bool,
    allocator: Allocator,

    pub fn deinit(self: *RelatedFile) void {
        self.allocator.free(self.path);
    }
};

/// Search locations for applications
const APP_LOCATIONS = [_][]const u8{
    "/Applications",
    "/System/Applications",
    "{home}/Applications",
};

/// Search patterns for related files
const RELATED_PATTERNS = [_]struct {
    path_template: []const u8,
    file_type: RelatedFileType,
}{
    // Preferences
    .{ .path_template = "{home}/Library/Preferences/{bundle_id}.plist", .file_type = .preferences },
    .{ .path_template = "{home}/Library/Preferences/{name}.plist", .file_type = .preferences },

    // Caches
    .{ .path_template = "{home}/Library/Caches/{bundle_id}", .file_type = .cache },
    .{ .path_template = "{home}/Library/Caches/{name}", .file_type = .cache },

    // Application Support
    .{ .path_template = "{home}/Library/Application Support/{name}", .file_type = .application_support },
    .{ .path_template = "{home}/Library/Application Support/{bundle_id}", .file_type = .application_support },

    // Logs
    .{ .path_template = "{home}/Library/Logs/{name}", .file_type = .logs },
    .{ .path_template = "{home}/Library/Logs/{bundle_id}", .file_type = .logs },

    // Containers (sandboxed apps)
    .{ .path_template = "{home}/Library/Containers/{bundle_id}", .file_type = .containers },

    // Launch Agents
    .{ .path_template = "{home}/Library/LaunchAgents/{bundle_id}.plist", .file_type = .launch_agent },
    .{ .path_template = "{home}/Library/LaunchAgents/{name}.plist", .file_type = .launch_agent },

    // Saved State
    .{ .path_template = "{home}/Library/Saved Application State/{bundle_id}.savedState", .file_type = .saved_state },

    // Receipts
    .{ .path_template = "/var/db/receipts/{bundle_id}.*", .file_type = .receipts },
};

/// Protected apps that should not be uninstalled
const PROTECTED_APPS = [_][]const u8{
    "Finder",
    "System Preferences",
    "System Settings",
    "App Store",
    "Safari",
    "Terminal",
    "Activity Monitor",
    "Disk Utility",
    "Migration Assistant",
    "Installer",
    "System Information",
};

/// Protected bundle prefixes (AI tools, security software)
const PROTECTED_PREFIXES = [_][]const u8{
    "com.apple.",
    "com.anthropic.",
};

/// Check if an app is protected
pub fn isProtectedApp(name: []const u8, bundle_id: ?[]const u8) bool {
    // Check name
    for (PROTECTED_APPS) |protected| {
        if (mem.eql(u8, name, protected)) {
            return true;
        }
    }

    // Check bundle ID prefix
    if (bundle_id) |id| {
        for (PROTECTED_PREFIXES) |prefix| {
            if (mem.startsWith(u8, id, prefix)) {
                return true;
            }
        }
    }

    // Check safety module
    if (safety.isProtectedAppData(name)) {
        return true;
    }

    return false;
}

/// Find installed applications
pub fn findApps(allocator: Allocator, search_term: ?[]const u8) !std.ArrayList(AppInfo) {
    var apps = std.ArrayList(AppInfo).init(allocator);
    errdefer {
        for (apps.items) |*app| {
            app.deinit();
        }
        apps.deinit();
    }

    const home = std.posix.getenv("HOME") orelse return apps;

    for (APP_LOCATIONS) |location_template| {
        const location = if (mem.indexOf(u8, location_template, "{home}") != null)
            try std.fmt.allocPrint(allocator, "{s}/Applications", .{home})
        else
            try allocator.dupe(u8, location_template);
        defer allocator.free(location);

        if (!file_ops.pathExists(location)) continue;

        var dir = fs.cwd().openDir(location, .{ .iterate = true }) catch continue;
        defer dir.close();

        var iter = dir.iterate();
        while (try iter.next()) |entry| {
            // Check if it's an .app bundle
            if (!mem.endsWith(u8, entry.name, ".app")) continue;

            // Extract app name (remove .app)
            const app_name = entry.name[0 .. entry.name.len - 4];

            // Filter by search term if provided
            if (search_term) |term| {
                if (!containsIgnoreCase(app_name, term)) continue;
            }

            const app_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ location, entry.name });
            errdefer allocator.free(app_path);

            // Get bundle ID from Info.plist
            var bundle_id: ?[]u8 = null;
            var version: ?[]u8 = null;
            // In real implementation, would parse Info.plist

            // Calculate app size
            const app_size = file_ops.calculateDirectorySize(allocator, app_path) catch 0;

            var app_info = AppInfo{
                .name = try allocator.dupe(u8, app_name),
                .bundle_id = bundle_id,
                .path = app_path,
                .size = app_size,
                .version = version,
                .related_files = std.ArrayList(RelatedFile).init(allocator),
                .total_size = app_size,
                .allocator = allocator,
            };

            // Find related files
            try findRelatedFiles(allocator, &app_info, home);

            try apps.append(app_info);
        }
    }

    return apps;
}

/// Find files related to an application
fn findRelatedFiles(allocator: Allocator, app: *AppInfo, home: []const u8) !void {
    for (RELATED_PATTERNS) |pattern| {
        // Expand path template
        var path = try expandTemplate(allocator, pattern.path_template, app.name, app.bundle_id, home);
        defer allocator.free(path);

        // Skip glob patterns for now
        if (mem.indexOf(u8, path, "*") != null) continue;

        if (file_ops.pathExists(path)) {
            const size = if (file_ops.isDirectory(path))
                file_ops.calculateDirectorySize(allocator, path) catch 0
            else blk: {
                const stat = fs.cwd().statFile(path) catch break :blk @as(u64, 0);
                break :blk stat.size;
            };

            try app.related_files.append(.{
                .path = try allocator.dupe(u8, path),
                .file_type = pattern.file_type,
                .size = size,
                .is_orphan = false,
                .allocator = allocator,
            });

            app.total_size += size;
        }
    }
}

/// Expand a path template
fn expandTemplate(
    allocator: Allocator,
    template: []const u8,
    name: []const u8,
    bundle_id: ?[]const u8,
    home: []const u8,
) ![]u8 {
    var result = std.ArrayList(u8).init(allocator);
    errdefer result.deinit();

    var i: usize = 0;
    while (i < template.len) {
        if (i + 6 <= template.len and mem.eql(u8, template[i .. i + 6], "{home}")) {
            try result.appendSlice(home);
            i += 6;
        } else if (i + 6 <= template.len and mem.eql(u8, template[i .. i + 6], "{name}")) {
            try result.appendSlice(name);
            i += 6;
        } else if (i + 11 <= template.len and mem.eql(u8, template[i .. i + 11], "{bundle_id}")) {
            if (bundle_id) |id| {
                try result.appendSlice(id);
            } else {
                try result.appendSlice(name);
            }
            i += 11;
        } else {
            try result.append(template[i]);
            i += 1;
        }
    }

    return result.toOwnedSlice();
}

/// Case-insensitive contains check
fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len > haystack.len) return false;

    outer: for (0..haystack.len - needle.len + 1) |i| {
        for (needle, 0..) |c, j| {
            const h = haystack[i + j];
            if (std.ascii.toLower(h) != std.ascii.toLower(c)) {
                continue :outer;
            }
        }
        return true;
    }
    return false;
}

/// Find orphaned application data (data without corresponding app)
pub fn findOrphans(allocator: Allocator, min_age_days: u64) !std.ArrayList(RelatedFile) {
    var orphans = std.ArrayList(RelatedFile).init(allocator);
    errdefer {
        for (orphans.items) |*o| {
            o.deinit();
        }
        orphans.deinit();
    }

    const home = std.posix.getenv("HOME") orelse return orphans;

    // Scan Application Support for orphans
    const app_support = try std.fmt.allocPrint(allocator, "{s}/Library/Application Support", .{home});
    defer allocator.free(app_support);

    try scanForOrphans(allocator, app_support, .application_support, min_age_days, &orphans);

    // Scan Caches
    const caches = try std.fmt.allocPrint(allocator, "{s}/Library/Caches", .{home});
    defer allocator.free(caches);

    try scanForOrphans(allocator, caches, .cache, min_age_days, &orphans);

    // Scan Preferences
    const prefs = try std.fmt.allocPrint(allocator, "{s}/Library/Preferences", .{home});
    defer allocator.free(prefs);

    try scanForOrphans(allocator, prefs, .preferences, min_age_days, &orphans);

    return orphans;
}

fn scanForOrphans(
    allocator: Allocator,
    path: []const u8,
    file_type: RelatedFileType,
    min_age_days: u64,
    orphans: *std.ArrayList(RelatedFile),
) !void {
    var dir = fs.cwd().openDir(path, .{ .iterate = true }) catch return;
    defer dir.close();

    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        // Skip system prefixes
        if (mem.startsWith(u8, entry.name, "com.apple.")) continue;
        if (mem.startsWith(u8, entry.name, ".")) continue;

        const full_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ path, entry.name });
        errdefer allocator.free(full_path);

        // Check if corresponding app exists
        const app_exists = checkAppExists(allocator, entry.name) catch false;

        if (!app_exists) {
            // Check age
            const is_old = file_ops.isOlderThanDays(full_path, min_age_days) catch false;
            if (!is_old) {
                allocator.free(full_path);
                continue;
            }

            // Check vendor whitelist
            if (safety.isVendorBundleId(entry.name)) {
                allocator.free(full_path);
                continue;
            }

            const size = if (entry.kind == .directory)
                file_ops.calculateDirectorySize(allocator, full_path) catch 0
            else blk: {
                const stat = dir.statFile(entry.name) catch break :blk @as(u64, 0);
                break :blk stat.size;
            };

            try orphans.append(.{
                .path = full_path,
                .file_type = file_type,
                .size = size,
                .is_orphan = true,
                .allocator = allocator,
            });
        } else {
            allocator.free(full_path);
        }
    }
}

fn checkAppExists(allocator: Allocator, name: []const u8) !bool {
    const home = std.posix.getenv("HOME") orelse return false;

    // Check common locations
    const locations = [_][]const u8{
        "/Applications",
    };

    for (locations) |base| {
        // Try exact match
        const app_path = try std.fmt.allocPrint(allocator, "{s}/{s}.app", .{ base, name });
        defer allocator.free(app_path);

        if (file_ops.pathExists(app_path)) return true;
    }

    // Also check user Applications
    const user_apps = try std.fmt.allocPrint(allocator, "{s}/Applications/{s}.app", .{ home, name });
    defer allocator.free(user_apps);

    return file_ops.pathExists(user_apps);
}

/// Uninstall an application
pub fn uninstallApp(
    allocator: Allocator,
    app: *const AppInfo,
    include_related: bool,
    dry_run: bool,
) !file_ops.FileOpResult {
    var result = file_ops.FileOpResult.init(allocator);
    errdefer result.deinit();

    // Check if protected
    if (isProtectedApp(app.name, app.bundle_id)) {
        try result.addError(allocator, app.path, "Application is protected and cannot be uninstalled");
        return result;
    }

    log.info("Uninstalling: {s}", .{app.name});

    // Delete main app bundle
    var app_result = try file_ops.safeDeleteDirectory(allocator, app.path, .{
        .dry_run = dry_run,
        .skip_confirmation = true,
    });
    defer app_result.deinit();

    result.bytes_freed += app_result.bytes_freed;
    result.files_affected += app_result.files_affected;

    if (!app_result.success) {
        for (app_result.errors.items) |err| {
            try result.addError(allocator, err.path, err.message);
        }
    }

    // Delete related files if requested
    if (include_related) {
        for (app.related_files.items) |related| {
            log.info("  Removing: {s}", .{related.file_type.displayName()});

            if (file_ops.isDirectory(related.path)) {
                var related_result = try file_ops.safeDeleteDirectory(allocator, related.path, .{
                    .dry_run = dry_run,
                    .skip_confirmation = true,
                });
                defer related_result.deinit();

                result.bytes_freed += related_result.bytes_freed;
                result.files_affected += related_result.files_affected;
            } else {
                var related_result = try file_ops.safeDeleteFile(allocator, related.path, .{
                    .dry_run = dry_run,
                });
                defer related_result.deinit();

                result.bytes_freed += related_result.bytes_freed;
                result.files_affected += related_result.files_affected;
            }
        }
    }

    return result;
}

/// Print app info
pub fn printAppInfo(app: *const AppInfo, writer: anytype) !void {
    const size_fmt = file_ops.formatBytes(app.size);
    const total_fmt = file_ops.formatBytes(app.total_size);

    try writer.print("\n📦 {s}\n", .{app.name});
    try writer.writeAll("─────────────────────────────────────────────────────\n");
    try writer.print("Path:        {s}\n", .{app.path});
    if (app.bundle_id) |id| {
        try writer.print("Bundle ID:   {s}\n", .{id});
    }
    if (app.version) |v| {
        try writer.print("Version:     {s}\n", .{v});
    }
    try writer.print("App Size:    {d:.2} {s}\n", .{ size_fmt.value, size_fmt.unit });

    if (app.related_files.items.len > 0) {
        try writer.writeAll("\nRelated Files:\n");
        for (app.related_files.items) |related| {
            const rel_size = file_ops.formatBytes(related.size);
            try writer.print("  {s:<20} {d:.2} {s}\n", .{
                related.file_type.displayName(),
                rel_size.value,
                rel_size.unit,
            });
            try writer.print("    └─ {s}\n", .{related.path});
        }
    }

    try writer.print("\nTotal Size:  {d:.2} {s}\n", .{ total_fmt.value, total_fmt.unit });
}

/// Print list of apps
pub fn printAppList(apps: []const AppInfo, writer: anytype) !void {
    try writer.writeAll("\n══════════════════════════════════════════════════════\n");
    try writer.writeAll("              INSTALLED APPLICATIONS\n");
    try writer.writeAll("══════════════════════════════════════════════════════\n\n");

    for (apps, 0..) |app, i| {
        const size_fmt = file_ops.formatBytes(app.total_size);
        const protected = if (isProtectedApp(app.name, app.bundle_id)) " 🔒" else "";
        try writer.print("{d:>3}. {s:<30} {d:>8.2} {s}{s}\n", .{
            i + 1,
            truncate(app.name, 30),
            size_fmt.value,
            size_fmt.unit,
            protected,
        });
    }
}

fn truncate(s: []const u8, max: usize) []const u8 {
    if (s.len <= max) return s;
    return s[0..max];
}

// ============================================================================
// Tests
// ============================================================================

test "protected app detection" {
    try std.testing.expect(isProtectedApp("Finder", null));
    try std.testing.expect(isProtectedApp("Safari", null));
    try std.testing.expect(!isProtectedApp("Slack", null));
}

test "case insensitive contains" {
    try std.testing.expect(containsIgnoreCase("Slack", "slack"));
    try std.testing.expect(containsIgnoreCase("SLACK", "slack"));
    try std.testing.expect(containsIgnoreCase("MySlackApp", "slack"));
    try std.testing.expect(!containsIgnoreCase("Teams", "slack"));
}

test "expand template" {
    const allocator = std.testing.allocator;
    const result = try expandTemplate(
        allocator,
        "{home}/Library/{name}",
        "TestApp",
        null,
        "/Users/test",
    );
    defer allocator.free(result);
    try std.testing.expectEqualStrings("/Users/test/Library/TestApp", result);
}
