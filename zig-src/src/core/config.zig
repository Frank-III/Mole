const std = @import("std");
const fs = std.fs;
const mem = std.mem;
const json = std.json;
const Allocator = mem.Allocator;
const safety = @import("safety.zig");

/// Application configuration
pub const Config = struct {
    /// User-defined whitelist (paths to never delete)
    whitelist: std.ArrayList([]const u8),

    /// User-defined blacklist (additional paths to clean)
    blacklist: std.ArrayList([]const u8),

    /// Whether to enable verbose logging
    verbose: bool = false,

    /// Whether to run in dry-run mode by default
    dry_run: bool = false,

    /// Minimum age in days for orphan detection
    orphan_min_age_days: u64 = 60,

    /// Maximum depth for project cleanup
    project_cleanup_depth: u32 = 5,

    /// Protected browser domains (web editors, etc.)
    protected_domains: std.ArrayList([]const u8),

    allocator: Allocator,

    /// Default protected domains for web-based editors
    pub const DEFAULT_PROTECTED_DOMAINS = [_][]const u8{
        "capcut.com",
        "photopea.com",
        "pixlr.com",
        "figma.com",
        "canva.com",
    };

    pub fn init(allocator: Allocator) Config {
        var whitelist = std.ArrayList([]const u8).init(allocator);
        var blacklist = std.ArrayList([]const u8).init(allocator);
        var protected_domains = std.ArrayList([]const u8).init(allocator);

        // Add default protected domains
        for (DEFAULT_PROTECTED_DOMAINS) |domain| {
            protected_domains.append(allocator.dupe(u8, domain) catch continue) catch continue;
        }

        return .{
            .whitelist = whitelist,
            .blacklist = blacklist,
            .protected_domains = protected_domains,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Config) void {
        for (self.whitelist.items) |item| {
            self.allocator.free(item);
        }
        self.whitelist.deinit();

        for (self.blacklist.items) |item| {
            self.allocator.free(item);
        }
        self.blacklist.deinit();

        for (self.protected_domains.items) |item| {
            self.allocator.free(item);
        }
        self.protected_domains.deinit();
    }

    /// Add a path to the whitelist
    pub fn addToWhitelist(self: *Config, path: []const u8) !void {
        // Validate the path is absolute
        if (path.len == 0 or path[0] != '/') {
            return error.InvalidPath;
        }

        // Don't add duplicates
        for (self.whitelist.items) |existing| {
            if (mem.eql(u8, existing, path)) {
                return;
            }
        }

        try self.whitelist.append(try self.allocator.dupe(u8, path));
    }

    /// Remove a path from the whitelist
    pub fn removeFromWhitelist(self: *Config, path: []const u8) void {
        var i: usize = 0;
        while (i < self.whitelist.items.len) {
            if (mem.eql(u8, self.whitelist.items[i], path)) {
                self.allocator.free(self.whitelist.orderedRemove(i));
            } else {
                i += 1;
            }
        }
    }

    /// Check if a path is whitelisted
    pub fn isWhitelisted(self: *const Config, path: []const u8) bool {
        for (self.whitelist.items) |whitelisted| {
            if (mem.eql(u8, whitelisted, path)) {
                return true;
            }
            // Also check if path is under a whitelisted directory
            if (mem.startsWith(u8, path, whitelisted) and
                path.len > whitelisted.len and
                path[whitelisted.len] == '/')
            {
                return true;
            }
        }
        return false;
    }

    /// Check if a domain is protected
    pub fn isDomainProtected(self: *const Config, domain: []const u8) bool {
        for (self.protected_domains.items) |protected| {
            if (mem.eql(u8, protected, domain)) {
                return true;
            }
            // Also check subdomain matching
            if (mem.endsWith(u8, domain, protected)) {
                return true;
            }
        }
        return false;
    }
};

/// Path to the configuration file
pub fn getConfigPath(allocator: Allocator) ![]u8 {
    const home = std.posix.getenv("HOME") orelse return error.NoHomeDir;
    return try std.fmt.allocPrint(allocator, "{s}/.config/mole/config.json", .{home});
}

/// Path to the configuration directory
pub fn getConfigDir(allocator: Allocator) ![]u8 {
    const home = std.posix.getenv("HOME") orelse return error.NoHomeDir;
    return try std.fmt.allocPrint(allocator, "{s}/.config/mole", .{home});
}

/// Load configuration from file
pub fn loadConfig(allocator: Allocator) !Config {
    var config = Config.init(allocator);
    errdefer config.deinit();

    const config_path = try getConfigPath(allocator);
    defer allocator.free(config_path);

    const file = fs.cwd().openFile(config_path, .{}) catch |err| {
        // If config doesn't exist, return defaults
        if (err == error.FileNotFound) {
            return config;
        }
        return err;
    };
    defer file.close();

    const content = try file.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(content);

    // Parse JSON
    var parsed = try json.parseFromSlice(json.Value, allocator, content, .{});
    defer parsed.deinit();

    const root = parsed.value;

    if (root != .object) {
        return config;
    }

    // Parse whitelist
    if (root.object.get("whitelist")) |whitelist_val| {
        if (whitelist_val == .array) {
            for (whitelist_val.array.items) |item| {
                if (item == .string) {
                    try config.addToWhitelist(item.string);
                }
            }
        }
    }

    // Parse blacklist
    if (root.object.get("blacklist")) |blacklist_val| {
        if (blacklist_val == .array) {
            for (blacklist_val.array.items) |item| {
                if (item == .string) {
                    if (item.string.len > 0 and item.string[0] == '/') {
                        try config.blacklist.append(try allocator.dupe(u8, item.string));
                    }
                }
            }
        }
    }

    // Parse options
    if (root.object.get("verbose")) |v| {
        if (v == .bool) config.verbose = v.bool;
    }

    if (root.object.get("dry_run")) |v| {
        if (v == .bool) config.dry_run = v.bool;
    }

    if (root.object.get("orphan_min_age_days")) |v| {
        if (v == .integer) config.orphan_min_age_days = @intCast(@max(0, v.integer));
    }

    if (root.object.get("project_cleanup_depth")) |v| {
        if (v == .integer) config.project_cleanup_depth = @intCast(@max(1, v.integer));
    }

    // Parse protected domains
    if (root.object.get("protected_domains")) |domains_val| {
        if (domains_val == .array) {
            for (domains_val.array.items) |item| {
                if (item == .string) {
                    try config.protected_domains.append(try allocator.dupe(u8, item.string));
                }
            }
        }
    }

    return config;
}

/// Save configuration to file
pub fn saveConfig(allocator: Allocator, config: *const Config) !void {
    const config_dir = try getConfigDir(allocator);
    defer allocator.free(config_dir);

    // Ensure config directory exists
    fs.cwd().makePath(config_dir) catch |err| {
        if (err != error.PathAlreadyExists) {
            return err;
        }
    };

    const config_path = try getConfigPath(allocator);
    defer allocator.free(config_path);

    var file = try fs.cwd().createFile(config_path, .{});
    defer file.close();

    var writer = file.writer();

    // Write JSON manually for readability
    try writer.writeAll("{\n");

    // Whitelist
    try writer.writeAll("  \"whitelist\": [\n");
    for (config.whitelist.items, 0..) |item, i| {
        try writer.print("    \"{s}\"", .{item});
        if (i < config.whitelist.items.len - 1) {
            try writer.writeAll(",");
        }
        try writer.writeAll("\n");
    }
    try writer.writeAll("  ],\n");

    // Blacklist
    try writer.writeAll("  \"blacklist\": [\n");
    for (config.blacklist.items, 0..) |item, i| {
        try writer.print("    \"{s}\"", .{item});
        if (i < config.blacklist.items.len - 1) {
            try writer.writeAll(",");
        }
        try writer.writeAll("\n");
    }
    try writer.writeAll("  ],\n");

    // Protected domains
    try writer.writeAll("  \"protected_domains\": [\n");
    for (config.protected_domains.items, 0..) |item, i| {
        try writer.print("    \"{s}\"", .{item});
        if (i < config.protected_domains.items.len - 1) {
            try writer.writeAll(",");
        }
        try writer.writeAll("\n");
    }
    try writer.writeAll("  ],\n");

    // Options
    try writer.print("  \"verbose\": {s},\n", .{if (config.verbose) "true" else "false"});
    try writer.print("  \"dry_run\": {s},\n", .{if (config.dry_run) "true" else "false"});
    try writer.print("  \"orphan_min_age_days\": {d},\n", .{config.orphan_min_age_days});
    try writer.print("  \"project_cleanup_depth\": {d}\n", .{config.project_cleanup_depth});

    try writer.writeAll("}\n");
}

// ============================================================================
// Unit Tests
// ============================================================================

test "config initialization" {
    const allocator = std.testing.allocator;
    var config = Config.init(allocator);
    defer config.deinit();

    try std.testing.expectEqual(@as(u64, 60), config.orphan_min_age_days);
    try std.testing.expect(!config.verbose);
    try std.testing.expect(!config.dry_run);
}

test "whitelist operations" {
    const allocator = std.testing.allocator;
    var config = Config.init(allocator);
    defer config.deinit();

    try config.addToWhitelist("/Users/test/important");

    try std.testing.expect(config.isWhitelisted("/Users/test/important"));
    try std.testing.expect(config.isWhitelisted("/Users/test/important/subdir"));
    try std.testing.expect(!config.isWhitelisted("/Users/test/other"));

    config.removeFromWhitelist("/Users/test/important");
    try std.testing.expect(!config.isWhitelisted("/Users/test/important"));
}

test "domain protection" {
    const allocator = std.testing.allocator;
    var config = Config.init(allocator);
    defer config.deinit();

    try std.testing.expect(config.isDomainProtected("photopea.com"));
    try std.testing.expect(config.isDomainProtected("app.photopea.com"));
    try std.testing.expect(!config.isDomainProtected("example.com"));
}
