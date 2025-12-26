const std = @import("std");
const fs = std.fs;
const mem = std.mem;
const Allocator = mem.Allocator;

const safety = @import("../core/safety.zig");
const file_ops = @import("../core/file_ops.zig");
const logging = @import("../core/logging.zig");
const config = @import("../core/config.zig");

const log = logging.scoped("browser");

/// Supported browsers
pub const Browser = enum {
    chrome,
    firefox,
    safari,
    edge,
    brave,
    arc,
    opera,

    pub fn displayName(self: Browser) []const u8 {
        return switch (self) {
            .chrome => "Google Chrome",
            .firefox => "Mozilla Firefox",
            .safari => "Safari",
            .edge => "Microsoft Edge",
            .brave => "Brave",
            .arc => "Arc",
            .opera => "Opera",
        };
    }

    pub fn bundleId(self: Browser) []const u8 {
        return switch (self) {
            .chrome => "com.google.Chrome",
            .firefox => "org.mozilla.firefox",
            .safari => "com.apple.Safari",
            .edge => "com.microsoft.edgemac",
            .brave => "com.brave.Browser",
            .arc => "company.thebrowser.Browser",
            .opera => "com.operasoftware.Opera",
        };
    }
};

/// Type of browser data
pub const BrowserDataType = enum {
    cache,
    cookies,
    history,
    local_storage,
    session_storage,
    service_workers,
    indexed_db,

    pub fn displayName(self: BrowserDataType) []const u8 {
        return switch (self) {
            .cache => "Cache",
            .cookies => "Cookies",
            .history => "History",
            .local_storage => "Local Storage",
            .session_storage => "Session Storage",
            .service_workers => "Service Workers",
            .indexed_db => "IndexedDB",
        };
    }

    /// Whether this type is safe to delete by default
    pub fn isSafeToDelete(self: BrowserDataType) bool {
        return switch (self) {
            .cache => true,
            .service_workers => true,
            .session_storage => true,
            // These require explicit user consent
            .cookies => false,
            .history => false,
            .local_storage => false,
            .indexed_db => false,
        };
    }
};

/// Browser data location
pub const BrowserDataPath = struct {
    browser: Browser,
    data_type: BrowserDataType,
    /// Path relative to home directory
    relative_path: []const u8,
    /// Some paths are inside profile directories
    is_profile_relative: bool = false,
};

/// Chrome/Chromium-based browser data locations
const CHROMIUM_PATHS = [_]BrowserDataPath{
    .{ .browser = .chrome, .data_type = .cache, .relative_path = "Library/Caches/Google/Chrome" },
    .{ .browser = .chrome, .data_type = .cache, .relative_path = "Library/Application Support/Google/Chrome/Default/Cache", .is_profile_relative = true },
    .{ .browser = .chrome, .data_type = .cache, .relative_path = "Library/Application Support/Google/Chrome/Default/Code Cache", .is_profile_relative = true },
    .{ .browser = .chrome, .data_type = .service_workers, .relative_path = "Library/Application Support/Google/Chrome/Default/Service Worker", .is_profile_relative = true },
    .{ .browser = .chrome, .data_type = .local_storage, .relative_path = "Library/Application Support/Google/Chrome/Default/Local Storage", .is_profile_relative = true },
    .{ .browser = .chrome, .data_type = .indexed_db, .relative_path = "Library/Application Support/Google/Chrome/Default/IndexedDB", .is_profile_relative = true },

    .{ .browser = .edge, .data_type = .cache, .relative_path = "Library/Caches/Microsoft Edge" },
    .{ .browser = .edge, .data_type = .cache, .relative_path = "Library/Application Support/Microsoft Edge/Default/Cache", .is_profile_relative = true },

    .{ .browser = .brave, .data_type = .cache, .relative_path = "Library/Caches/BraveSoftware/Brave-Browser" },
    .{ .browser = .brave, .data_type = .cache, .relative_path = "Library/Application Support/BraveSoftware/Brave-Browser/Default/Cache", .is_profile_relative = true },

    .{ .browser = .arc, .data_type = .cache, .relative_path = "Library/Caches/company.thebrowser.Browser" },
    .{ .browser = .opera, .data_type = .cache, .relative_path = "Library/Caches/com.operasoftware.Opera" },
};

/// Firefox data locations
const FIREFOX_PATHS = [_]BrowserDataPath{
    .{ .browser = .firefox, .data_type = .cache, .relative_path = "Library/Caches/Firefox" },
    // Firefox uses profile directories like xxxxx.default-release
    .{ .browser = .firefox, .data_type = .cache, .relative_path = "Library/Application Support/Firefox/Profiles", .is_profile_relative = true },
};

/// Safari data locations
const SAFARI_PATHS = [_]BrowserDataPath{
    .{ .browser = .safari, .data_type = .cache, .relative_path = "Library/Caches/com.apple.Safari" },
    .{ .browser = .safari, .data_type = .cache, .relative_path = "Library/Caches/com.apple.Safari.SafeBrowsing" },
    .{ .browser = .safari, .data_type = .local_storage, .relative_path = "Library/Safari/LocalStorage" },
};

/// Result of scanning browser data
pub const BrowserScanResult = struct {
    browser: Browser,
    data_type: BrowserDataType,
    path: []const u8,
    size: u64,
    can_clean: bool,
    /// Domains that would be affected (for local storage, etc.)
    affected_domains: std.ArrayList([]const u8),
    /// Domains that are protected and will be preserved
    protected_domains: std.ArrayList([]const u8),
    allocator: Allocator,

    pub fn deinit(self: *BrowserScanResult) void {
        self.allocator.free(self.path);
        for (self.affected_domains.items) |domain| {
            self.allocator.free(domain);
        }
        self.affected_domains.deinit();
        for (self.protected_domains.items) |domain| {
            self.allocator.free(domain);
        }
        self.protected_domains.deinit();
    }
};

/// Browser cleaner configuration
pub const BrowserCleanerConfig = struct {
    /// Browsers to clean (null = all)
    browsers: ?[]const Browser = null,
    /// Data types to clean
    data_types: []const BrowserDataType = &.{.cache},
    /// Whether to include unsafe data types (cookies, history)
    include_unsafe: bool = false,
    /// Dry run mode
    dry_run: bool = false,
    /// Protected domains (won't delete their data)
    protected_domains: []const []const u8 = &.{},
    /// App config for additional protected domains
    app_config: ?*const config.Config = null,
};

/// Scan browser data
pub fn scanBrowserData(allocator: Allocator, cfg: BrowserCleanerConfig) !std.ArrayList(BrowserScanResult) {
    var results = std.ArrayList(BrowserScanResult).init(allocator);
    errdefer {
        for (results.items) |*item| {
            item.deinit();
        }
        results.deinit();
    }

    const home = std.posix.getenv("HOME") orelse return error.NoHomeDir;

    // Combine all paths
    const all_paths = CHROMIUM_PATHS ++ FIREFOX_PATHS ++ SAFARI_PATHS;

    for (all_paths) |browser_path| {
        // Check if this browser is in our filter
        if (cfg.browsers) |browsers| {
            var found = false;
            for (browsers) |b| {
                if (b == browser_path.browser) {
                    found = true;
                    break;
                }
            }
            if (!found) continue;
        }

        // Check if this data type is in our filter
        var type_found = false;
        for (cfg.data_types) |dt| {
            if (dt == browser_path.data_type) {
                type_found = true;
                break;
            }
        }
        if (!type_found) continue;

        // Check if unsafe and we're not including unsafe
        if (!browser_path.data_type.isSafeToDelete() and !cfg.include_unsafe) {
            continue;
        }

        const full_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ home, browser_path.relative_path });

        var result = BrowserScanResult{
            .browser = browser_path.browser,
            .data_type = browser_path.data_type,
            .path = full_path,
            .size = 0,
            .can_clean = true,
            .affected_domains = std.ArrayList([]const u8).init(allocator),
            .protected_domains = std.ArrayList([]const u8).init(allocator),
            .allocator = allocator,
        };

        // Check if path exists
        if (!file_ops.pathExists(full_path)) {
            result.can_clean = false;
            try results.append(result);
            continue;
        }

        // Calculate size
        result.size = file_ops.calculateDirectorySize(allocator, full_path) catch 0;

        // For local storage and indexed DB, scan for domains
        if (browser_path.data_type == .local_storage or browser_path.data_type == .indexed_db) {
            try scanForDomains(allocator, full_path, &result.affected_domains);

            // Check for protected domains
            for (result.affected_domains.items) |domain| {
                if (isDomainProtected(domain, cfg)) {
                    try result.protected_domains.append(try allocator.dupe(u8, domain));
                }
            }
        }

        try results.append(result);
    }

    return results;
}

/// Scan a directory for domain-based storage
fn scanForDomains(allocator: Allocator, path: []const u8, domains: *std.ArrayList([]const u8)) !void {
    var dir = fs.cwd().openDir(path, .{ .iterate = true }) catch return;
    defer dir.close();

    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        // Domain-based storage often uses formats like:
        // http_example.com_0.localstorage
        // https_example.com_0
        const name = entry.name;

        // Extract domain from various formats
        if (mem.startsWith(u8, name, "http_") or mem.startsWith(u8, name, "https_")) {
            const start = if (mem.startsWith(u8, name, "https_")) @as(usize, 6) else @as(usize, 5);
            const end = mem.indexOf(u8, name[start..], "_") orelse continue;
            const domain = name[start .. start + end];

            // Check if already in list
            var found = false;
            for (domains.items) |existing| {
                if (mem.eql(u8, existing, domain)) {
                    found = true;
                    break;
                }
            }

            if (!found) {
                try domains.append(try allocator.dupe(u8, domain));
            }
        }
    }
}

/// Check if a domain is protected
fn isDomainProtected(domain: []const u8, cfg: BrowserCleanerConfig) bool {
    // Check explicit protected domains
    for (cfg.protected_domains) |protected| {
        if (mem.eql(u8, domain, protected) or mem.endsWith(u8, domain, protected)) {
            return true;
        }
    }

    // Check app config protected domains
    if (cfg.app_config) |app_cfg| {
        if (app_cfg.isDomainProtected(domain)) {
            return true;
        }
    }

    // Default protected domains for web-based editors
    const default_protected = [_][]const u8{
        "capcut.com",
        "photopea.com",
        "pixlr.com",
        "figma.com",
        "canva.com",
        "notion.so",
        "coda.io",
        "airtable.com",
    };

    for (default_protected) |protected| {
        if (mem.eql(u8, domain, protected) or mem.endsWith(u8, domain, protected)) {
            return true;
        }
    }

    return false;
}

/// Clean browser data
pub fn cleanBrowserData(
    allocator: Allocator,
    results: []const BrowserScanResult,
    dry_run: bool,
) !file_ops.FileOpResult {
    var result = file_ops.FileOpResult.init(allocator);
    errdefer result.deinit();

    for (results) |scan_result| {
        if (!scan_result.can_clean or scan_result.size == 0) {
            continue;
        }

        log.info("Cleaning {s} {s}", .{
            scan_result.browser.displayName(),
            scan_result.data_type.displayName(),
        });

        // If there are protected domains, we need to clean selectively
        if (scan_result.protected_domains.items.len > 0) {
            log.info("  Preserving {d} protected domain(s)", .{scan_result.protected_domains.items.len});

            const sub_result = try cleanWithDomainProtection(
                allocator,
                scan_result.path,
                scan_result.protected_domains.items,
                dry_run,
            );
            result.bytes_freed += sub_result.bytes_freed;
            result.files_affected += sub_result.files_affected;
        } else {
            var sub_result = try file_ops.safeDeleteDirectory(allocator, scan_result.path, .{
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

/// Clean a directory while preserving protected domains
fn cleanWithDomainProtection(
    allocator: Allocator,
    path: []const u8,
    protected: []const []const u8,
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
        // Check if this entry belongs to a protected domain
        var is_protected = false;
        for (protected) |domain| {
            if (mem.indexOf(u8, entry.name, domain) != null) {
                is_protected = true;
                break;
            }
        }

        if (is_protected) {
            log.debug("  Preserving: {s}", .{entry.name});
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

/// Get summary of browser data by browser
pub fn getSummaryByBrowser(results: []const BrowserScanResult) struct {
    chrome: u64,
    firefox: u64,
    safari: u64,
    edge: u64,
    brave: u64,
    arc: u64,
    opera: u64,
    total: u64,
} {
    var summary = .{
        .chrome = @as(u64, 0),
        .firefox = @as(u64, 0),
        .safari = @as(u64, 0),
        .edge = @as(u64, 0),
        .brave = @as(u64, 0),
        .arc = @as(u64, 0),
        .opera = @as(u64, 0),
        .total = @as(u64, 0),
    };

    for (results) |r| {
        if (!r.can_clean) continue;

        switch (r.browser) {
            .chrome => summary.chrome += r.size,
            .firefox => summary.firefox += r.size,
            .safari => summary.safari += r.size,
            .edge => summary.edge += r.size,
            .brave => summary.brave += r.size,
            .arc => summary.arc += r.size,
            .opera => summary.opera += r.size,
        }
        summary.total += r.size;
    }

    return summary;
}

/// Print browser scan results
pub fn printBrowserResults(results: []const BrowserScanResult, writer: anytype) !void {
    var current_browser: ?Browser = null;

    for (results) |r| {
        if (current_browser == null or current_browser.? != r.browser) {
            current_browser = r.browser;
            try writer.print("\n{s}:\n", .{r.browser.displayName()});
        }

        const formatted = file_ops.formatBytes(r.size);

        if (r.can_clean and r.size > 0) {
            try writer.print("  ✅ {s}: {d:.2} {s}\n", .{
                r.data_type.displayName(),
                formatted.value,
                formatted.unit,
            });

            if (r.protected_domains.items.len > 0) {
                try writer.print("     ⚠️  {d} protected domain(s) will be preserved\n", .{
                    r.protected_domains.items.len,
                });
            }
        } else if (r.size == 0) {
            try writer.print("  ⚪ {s}: empty\n", .{r.data_type.displayName()});
        } else {
            try writer.print("  ⏭️  {s}: not found\n", .{r.data_type.displayName()});
        }
    }
}

// ============================================================================
// Tests
// ============================================================================

test "browser display names" {
    try std.testing.expectEqualStrings("Google Chrome", Browser.chrome.displayName());
    try std.testing.expectEqualStrings("Mozilla Firefox", Browser.firefox.displayName());
}

test "data type safety" {
    try std.testing.expect(BrowserDataType.cache.isSafeToDelete());
    try std.testing.expect(!BrowserDataType.cookies.isSafeToDelete());
    try std.testing.expect(!BrowserDataType.history.isSafeToDelete());
}

test "domain protection" {
    const cfg = BrowserCleanerConfig{
        .protected_domains = &.{"example.com"},
    };

    try std.testing.expect(isDomainProtected("example.com", cfg));
    try std.testing.expect(isDomainProtected("photopea.com", cfg)); // default protected
    try std.testing.expect(!isDomainProtected("random-site.com", cfg));
}
