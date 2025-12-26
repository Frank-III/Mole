//! Mole Cleanup Modules
//!
//! This module provides comprehensive system cleanup functionality
//! with safety-first architecture.

pub const caches = @import("caches.zig");
pub const browser = @import("browser.zig");
pub const dev = @import("dev.zig");
pub const system = @import("system.zig");

const std = @import("std");
const Allocator = std.mem.Allocator;
const file_ops = @import("../core/file_ops.zig");
const config = @import("../core/config.zig");
const logging = @import("../core/logging.zig");

const log = logging.scoped("clean");

/// Cleanup mode
pub const CleanMode = enum {
    /// Quick clean - just caches
    quick,
    /// Standard clean - caches + dev tools
    standard,
    /// Deep clean - everything including browser data
    deep,
    /// Custom - user-selected categories
    custom,
};

/// Cleanup configuration
pub const CleanConfig = struct {
    mode: CleanMode = .standard,
    dry_run: bool = false,
    skip_confirmation: bool = false,
    include_browser: bool = false,
    include_dev_tools: bool = true,
    include_system: bool = false,
    include_trash: bool = false,
    app_config: ?*const config.Config = null,
};

/// Aggregated cleanup result
pub const CleanResult = struct {
    cache_result: ?caches.ScanResult = null,
    browser_results: ?std.ArrayList(browser.BrowserScanResult) = null,
    dev_results: ?std.ArrayList(dev.DevToolScanResult) = null,
    system_results: ?std.ArrayList(system.SystemScanResult) = null,
    total_bytes_freed: u64 = 0,
    total_files_affected: u64 = 0,
    allocator: Allocator,

    pub fn deinit(self: *CleanResult) void {
        if (self.browser_results) |*results| {
            for (results.items) |*item| {
                item.deinit();
            }
            results.deinit();
        }
        if (self.dev_results) |*results| {
            for (results.items) |*item| {
                item.deinit();
            }
            results.deinit();
        }
        if (self.system_results) |*results| {
            for (results.items) |*item| {
                item.deinit();
            }
            results.deinit();
        }
    }
};

/// Run a full cleanup scan
pub fn scan(allocator: Allocator, cfg: CleanConfig) !CleanResult {
    var result = CleanResult{ .allocator = allocator };

    log.info("Starting cleanup scan (mode: {s})", .{@tagName(cfg.mode)});

    // Scan caches
    var cache_results = try caches.scanCaches(allocator, .{
        .dry_run = cfg.dry_run,
        .app_config = cfg.app_config,
    });
    defer {
        for (cache_results.items) |*item| {
            item.deinit();
        }
        cache_results.deinit();
    }

    const cache_totals = caches.getTotalReclaimable(cache_results.items);
    result.total_bytes_freed += cache_totals.size;

    // Scan browser data if requested
    if (cfg.include_browser or cfg.mode == .deep) {
        result.browser_results = try browser.scanBrowserData(allocator, .{
            .app_config = cfg.app_config,
        });

        if (result.browser_results) |results| {
            const summary = browser.getSummaryByBrowser(results.items);
            result.total_bytes_freed += summary.total;
        }
    }

    // Scan dev tools if requested
    if (cfg.include_dev_tools or cfg.mode == .standard or cfg.mode == .deep) {
        result.dev_results = try dev.scanDevTools(allocator, .{
            .app_config = cfg.app_config,
        });

        if (result.dev_results) |results| {
            const totals = dev.getTotalReclaimable(results.items);
            result.total_bytes_freed += totals.size;
        }
    }

    // Scan system paths if requested
    if (cfg.include_system or cfg.mode == .deep) {
        result.system_results = try system.scanSystem(allocator, .{
            .include_trash = cfg.include_trash,
            .app_config = cfg.app_config,
        });

        if (result.system_results) |results| {
            const totals = system.getTotalReclaimable(results.items);
            result.total_bytes_freed += totals.size;
        }
    }

    return result;
}

/// Print scan summary
pub fn printSummary(result: *const CleanResult, writer: anytype) !void {
    try writer.writeAll("\n══════════════════════════════════════════════════════\n");
    try writer.writeAll("                    CLEANUP SUMMARY\n");
    try writer.writeAll("══════════════════════════════════════════════════════\n");

    // Browser data
    if (result.browser_results) |results| {
        const summary = browser.getSummaryByBrowser(results.items);
        if (summary.total > 0) {
            try writer.writeAll("\n🌐 Browser Data:\n");
            if (summary.chrome > 0) try printLine(writer, "Chrome", summary.chrome);
            if (summary.firefox > 0) try printLine(writer, "Firefox", summary.firefox);
            if (summary.safari > 0) try printLine(writer, "Safari", summary.safari);
            if (summary.edge > 0) try printLine(writer, "Edge", summary.edge);
            if (summary.brave > 0) try printLine(writer, "Brave", summary.brave);
            if (summary.arc > 0) try printLine(writer, "Arc", summary.arc);
        }
    }

    // Dev tools
    if (result.dev_results) |results| {
        const totals = dev.getTotalReclaimable(results.items);
        if (totals.size > 0) {
            try writer.writeAll("\n🛠️  Developer Tools:\n");
            for (results.items) |r| {
                if (r.can_clean and r.size > 0) {
                    try printLine(writer, r.path_info.name, r.size);
                }
            }
        }
    }

    // System
    if (result.system_results) |results| {
        const totals = system.getTotalReclaimable(results.items);
        if (totals.size > 0) {
            try writer.writeAll("\n🖥️  System:\n");
            for (results.items) |r| {
                if (r.can_clean and r.size > 0) {
                    try printLine(writer, r.path_info.name, r.size);
                }
            }
        }
    }

    try writer.writeAll("\n──────────────────────────────────────────────────────\n");
    const formatted = file_ops.formatBytes(result.total_bytes_freed);
    try writer.print("  TOTAL RECLAIMABLE: {d:.2} {s}\n", .{ formatted.value, formatted.unit });
    try writer.writeAll("══════════════════════════════════════════════════════\n\n");
}

fn printLine(writer: anytype, name: []const u8, size: u64) !void {
    const formatted = file_ops.formatBytes(size);
    try writer.print("  • {s}: {d:.2} {s}\n", .{ name, formatted.value, formatted.unit });
}

/// Execute cleanup based on scan results
pub fn execute(
    allocator: Allocator,
    result: *const CleanResult,
    dry_run: bool,
) !file_ops.FileOpResult {
    var op_result = file_ops.FileOpResult.init(allocator);
    errdefer op_result.deinit();

    log.info("Executing cleanup{s}", .{if (dry_run) " (dry run)" else ""});

    // Clean browser data
    if (result.browser_results) |results| {
        const sub_result = try browser.cleanBrowserData(allocator, results.items, dry_run);
        op_result.bytes_freed += sub_result.bytes_freed;
        op_result.files_affected += sub_result.files_affected;
    }

    // Clean dev tools
    if (result.dev_results) |results| {
        var sub_result = try dev.cleanDevTools(allocator, results.items, dry_run);
        defer sub_result.deinit();
        op_result.bytes_freed += sub_result.bytes_freed;
        op_result.files_affected += sub_result.files_affected;
    }

    // Clean system
    if (result.system_results) |results| {
        var sub_result = try system.cleanSystem(allocator, results.items, dry_run);
        defer sub_result.deinit();
        op_result.bytes_freed += sub_result.bytes_freed;
        op_result.files_affected += sub_result.files_affected;
    }

    return op_result;
}

// ============================================================================
// Tests
// ============================================================================

test "clean mode enum" {
    try std.testing.expectEqualStrings("quick", @tagName(CleanMode.quick));
    try std.testing.expectEqualStrings("deep", @tagName(CleanMode.deep));
}

test {
    // Import all submodule tests
    _ = caches;
    _ = browser;
    _ = dev;
    _ = system;
}
