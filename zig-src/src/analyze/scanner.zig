const std = @import("std");
const fs = std.fs;
const mem = std.mem;
const Thread = std.Thread;
const Allocator = mem.Allocator;

const safety = @import("../core/safety.zig");
const file_ops = @import("../core/file_ops.zig");
const logging = @import("../core/logging.zig");

// Re-export pool for parallel scanning
pub const pool = @import("pool.zig");

const log = logging.scoped("analyze");

/// Entry in the directory scan
pub const DirEntry = struct {
    name: []const u8,
    path: []const u8,
    size: u64,
    is_dir: bool,
    child_count: u64,
    allocator: Allocator,

    pub fn deinit(self: *DirEntry) void {
        self.allocator.free(self.name);
        self.allocator.free(self.path);
    }

    /// Compare by size (descending)
    pub fn compareBySize(_: void, a: DirEntry, b: DirEntry) bool {
        return a.size > b.size;
    }
};

/// Scan result for a directory
pub const ScanResult = struct {
    path: []const u8,
    total_size: u64,
    file_count: u64,
    dir_count: u64,
    entries: std.ArrayList(DirEntry),
    large_files: std.ArrayList(DirEntry),
    scan_time_ms: u64,
    allocator: Allocator,

    pub fn init(allocator: Allocator, path: []const u8) !ScanResult {
        return .{
            .path = try allocator.dupe(u8, path),
            .total_size = 0,
            .file_count = 0,
            .dir_count = 0,
            .entries = std.ArrayList(DirEntry).init(allocator),
            .large_files = std.ArrayList(DirEntry).init(allocator),
            .scan_time_ms = 0,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *ScanResult) void {
        self.allocator.free(self.path);
        for (self.entries.items) |*entry| {
            entry.deinit();
        }
        self.entries.deinit();
        for (self.large_files.items) |*entry| {
            entry.deinit();
        }
        self.large_files.deinit();
    }

    /// Sort entries by size (largest first)
    pub fn sortBySize(self: *ScanResult) void {
        std.mem.sort(DirEntry, self.entries.items, {}, DirEntry.compareBySize);
        std.mem.sort(DirEntry, self.large_files.items, {}, DirEntry.compareBySize);
    }
};

/// Scanner configuration
pub const ScanConfig = struct {
    /// Maximum depth to scan (-1 for unlimited)
    max_depth: i32 = -1,
    /// Minimum file size to track as "large" (default 100MB)
    large_file_threshold: u64 = 100 * 1024 * 1024,
    /// Maximum entries to return per directory
    max_entries: usize = 50,
    /// Whether to follow symlinks
    follow_symlinks: bool = false,
    /// Show hidden files
    show_hidden: bool = true,
};

/// Scan a directory and return size information
pub fn scanDirectory(allocator: Allocator, path: []const u8, cfg: ScanConfig) !ScanResult {
    const start_time = std.time.milliTimestamp();

    // Validate path
    try safety.validatePath(path);

    var result = try ScanResult.init(allocator, path);
    errdefer result.deinit();

    // Open directory
    var dir = fs.cwd().openDir(path, .{ .iterate = true }) catch |err| {
        log.err("Failed to open directory: {s}", .{@errorName(err)});
        return result;
    };
    defer dir.close();

    // Scan entries
    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        // Skip hidden files if requested
        if (!cfg.show_hidden and entry.name[0] == '.') {
            continue;
        }

        const full_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ path, entry.name });
        errdefer allocator.free(full_path);

        const name = try allocator.dupe(u8, entry.name);
        errdefer allocator.free(name);

        var dir_entry = DirEntry{
            .name = name,
            .path = full_path,
            .size = 0,
            .is_dir = entry.kind == .directory,
            .child_count = 0,
            .allocator = allocator,
        };

        if (entry.kind == .directory) {
            result.dir_count += 1;
            // Calculate directory size recursively
            var dir_size: u64 = 0;
            var file_count: u64 = 0;
            calculateDirSize(allocator, full_path, cfg.max_depth, &dir_size, &file_count, cfg) catch {};
            dir_entry.size = dir_size;
            dir_entry.child_count = file_count;
        } else {
            result.file_count += 1;
            // Get file size
            const stat = dir.statFile(entry.name) catch continue;
            dir_entry.size = stat.size;

            // Track large files
            if (stat.size >= cfg.large_file_threshold) {
                const large_entry = DirEntry{
                    .name = try allocator.dupe(u8, entry.name),
                    .path = try allocator.dupe(u8, full_path),
                    .size = stat.size,
                    .is_dir = false,
                    .child_count = 0,
                    .allocator = allocator,
                };
                try result.large_files.append(large_entry);
            }
        }

        result.total_size += dir_entry.size;
        try result.entries.append(dir_entry);
    }

    // Sort by size
    result.sortBySize();

    // Trim to max entries
    while (result.entries.items.len > cfg.max_entries) {
        var entry = result.entries.pop();
        entry.deinit();
    }

    const end_time = std.time.milliTimestamp();
    result.scan_time_ms = @intCast(@max(0, end_time - start_time));

    return result;
}

/// Recursively calculate directory size
fn calculateDirSize(
    allocator: Allocator,
    path: []const u8,
    depth: i32,
    total_size: *u64,
    file_count: *u64,
    cfg: ScanConfig,
) !void {
    if (depth == 0) return;

    // Validate path
    safety.validatePath(path) catch return;

    var dir = fs.cwd().openDir(path, .{ .iterate = true }) catch return;
    defer dir.close();

    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        // Skip hidden if requested
        if (!cfg.show_hidden and entry.name[0] == '.') {
            continue;
        }

        if (entry.kind == .directory) {
            if (!cfg.follow_symlinks and entry.kind == .sym_link) {
                continue;
            }

            const sub_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ path, entry.name });
            defer allocator.free(sub_path);

            const new_depth = if (depth < 0) depth else depth - 1;
            try calculateDirSize(allocator, sub_path, new_depth, total_size, file_count, cfg);
        } else {
            file_count.* += 1;
            const stat = dir.statFile(entry.name) catch continue;
            total_size.* += stat.size;
        }
    }
}

/// Scan for large files recursively
pub fn findLargeFiles(
    allocator: Allocator,
    path: []const u8,
    threshold: u64,
    max_results: usize,
) !std.ArrayList(DirEntry) {
    var results = std.ArrayList(DirEntry).init(allocator);
    errdefer {
        for (results.items) |*item| {
            item.deinit();
        }
        results.deinit();
    }

    try findLargeFilesRecursive(allocator, path, threshold, &results, 10);

    // Sort by size
    std.mem.sort(DirEntry, results.items, {}, DirEntry.compareBySize);

    // Trim to max results
    while (results.items.len > max_results) {
        var entry = results.pop();
        entry.deinit();
    }

    return results;
}

fn findLargeFilesRecursive(
    allocator: Allocator,
    path: []const u8,
    threshold: u64,
    results: *std.ArrayList(DirEntry),
    depth: i32,
) !void {
    if (depth == 0) return;

    safety.validatePath(path) catch return;

    var dir = fs.cwd().openDir(path, .{ .iterate = true }) catch return;
    defer dir.close();

    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        const full_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ path, entry.name });

        if (entry.kind == .directory) {
            defer allocator.free(full_path);
            try findLargeFilesRecursive(allocator, full_path, threshold, results, depth - 1);
        } else {
            const stat = dir.statFile(entry.name) catch {
                allocator.free(full_path);
                continue;
            };

            if (stat.size >= threshold) {
                try results.append(.{
                    .name = try allocator.dupe(u8, entry.name),
                    .path = full_path,
                    .size = stat.size,
                    .is_dir = false,
                    .child_count = 0,
                    .allocator = allocator,
                });
            } else {
                allocator.free(full_path);
            }
        }
    }
}

/// Print scan results
pub fn printResults(result: *const ScanResult, writer: anytype) !void {
    const total_fmt = file_ops.formatBytes(result.total_size);

    try writer.writeAll("\n══════════════════════════════════════════════════════\n");
    try writer.print("  📁 {s}\n", .{result.path});
    try writer.writeAll("══════════════════════════════════════════════════════\n\n");

    try writer.print("Total Size: {d:.2} {s}\n", .{ total_fmt.value, total_fmt.unit });
    try writer.print("Files: {d}  |  Directories: {d}\n", .{ result.file_count, result.dir_count });
    try writer.print("Scan Time: {d}ms\n\n", .{result.scan_time_ms});

    // Top entries by size
    try writer.writeAll("Top Items by Size:\n");
    try writer.writeAll("─────────────────────────────────────────────────────\n");

    for (result.entries.items, 0..) |entry, i| {
        if (i >= 20) break;

        const size_fmt = file_ops.formatBytes(entry.size);
        const icon = if (entry.is_dir) "📁" else "📄";
        const percentage = if (result.total_size > 0)
            @as(f64, @floatFromInt(entry.size)) / @as(f64, @floatFromInt(result.total_size)) * 100
        else
            0;

        // Size bar
        const bar_width: usize = 20;
        const filled = @as(usize, @intFromFloat(percentage / 100 * @as(f64, @floatFromInt(bar_width))));

        try writer.print("{s} {s:<30} ", .{ icon, truncateName(entry.name, 30) });
        try writer.print("{d:>8.2} {s:<2} ", .{ size_fmt.value, size_fmt.unit });

        // Draw bar
        try writer.writeAll("[");
        var j: usize = 0;
        while (j < bar_width) : (j += 1) {
            if (j < filled) {
                try writer.writeAll("█");
            } else {
                try writer.writeAll("░");
            }
        }
        try writer.print("] {d:>5.1}%\n", .{percentage});
    }

    // Large files section
    if (result.large_files.items.len > 0) {
        try writer.writeAll("\n🔍 Large Files (>100MB):\n");
        try writer.writeAll("─────────────────────────────────────────────────────\n");

        for (result.large_files.items, 0..) |entry, i| {
            if (i >= 10) break;
            const size_fmt = file_ops.formatBytes(entry.size);
            try writer.print("  📄 {s}: {d:.2} {s}\n", .{
                truncateName(entry.path, 50),
                size_fmt.value,
                size_fmt.unit,
            });
        }
    }

    try writer.writeAll("\n");
}

/// Truncate a name to fit display width
fn truncateName(name: []const u8, max_len: usize) []const u8 {
    if (name.len <= max_len) return name;
    return name[0..max_len];
}

/// Get overview of key system directories
pub fn getSystemOverview(allocator: Allocator) !std.ArrayList(DirEntry) {
    var entries = std.ArrayList(DirEntry).init(allocator);
    errdefer {
        for (entries.items) |*e| {
            e.deinit();
        }
        entries.deinit();
    }

    const home = std.posix.getenv("HOME") orelse return entries;

    const overview_paths = [_]struct { name: []const u8, path: []const u8 }{
        .{ .name = "Home", .path = "" },
        .{ .name = "Documents", .path = "/Documents" },
        .{ .name = "Downloads", .path = "/Downloads" },
        .{ .name = "Desktop", .path = "/Desktop" },
        .{ .name = "Pictures", .path = "/Pictures" },
        .{ .name = "Music", .path = "/Music" },
        .{ .name = "Movies", .path = "/Movies" },
        .{ .name = "Library", .path = "/Library" },
        .{ .name = "Applications", .path = "/Applications" },
    };

    for (overview_paths) |item| {
        const full_path = if (item.path.len == 0)
            try allocator.dupe(u8, home)
        else
            try std.fmt.allocPrint(allocator, "{s}{s}", .{ home, item.path });

        if (!file_ops.pathExists(full_path)) {
            allocator.free(full_path);
            continue;
        }

        var size: u64 = 0;
        var file_count: u64 = 0;
        calculateDirSize(allocator, full_path, 5, &size, &file_count, .{}) catch {};

        try entries.append(.{
            .name = try allocator.dupe(u8, item.name),
            .path = full_path,
            .size = size,
            .is_dir = true,
            .child_count = file_count,
            .allocator = allocator,
        });
    }

    // Sort by size
    std.mem.sort(DirEntry, entries.items, {}, DirEntry.compareBySize);

    return entries;
}

/// Print system overview
pub fn printOverview(entries: []const DirEntry, writer: anytype) !void {
    try writer.writeAll("\n══════════════════════════════════════════════════════\n");
    try writer.writeAll("              DISK SPACE OVERVIEW\n");
    try writer.writeAll("══════════════════════════════════════════════════════\n\n");

    var total: u64 = 0;
    for (entries) |e| {
        total += e.size;
    }

    for (entries) |entry| {
        const size_fmt = file_ops.formatBytes(entry.size);
        const percentage = if (total > 0)
            @as(f64, @floatFromInt(entry.size)) / @as(f64, @floatFromInt(total)) * 100
        else
            0;

        try writer.print("📁 {s:<15} {d:>8.2} {s:<2} ", .{
            entry.name,
            size_fmt.value,
            size_fmt.unit,
        });

        // Draw bar
        const bar_width: usize = 25;
        const filled = @as(usize, @intFromFloat(percentage / 100 * @as(f64, @floatFromInt(bar_width))));

        try writer.writeAll("[");
        var j: usize = 0;
        while (j < bar_width) : (j += 1) {
            if (j < filled) {
                try writer.writeAll("█");
            } else {
                try writer.writeAll("░");
            }
        }
        try writer.print("] {d:>5.1}%\n", .{percentage});
    }

    const total_fmt = file_ops.formatBytes(total);
    try writer.print("\nTotal Scanned: {d:.2} {s}\n", .{ total_fmt.value, total_fmt.unit });
}

// ============================================================================
// Parallel Scanning Support
// ============================================================================

/// Parallel scan result with timing information
pub const ParallelScanSummary = struct {
    total_size: u64,
    file_count: u64,
    dir_count: u64,
    scan_time_ms: u64,
    worker_count: u32,
    entries: std.ArrayList(DirEntry),
    allocator: Allocator,

    pub fn deinit(self: *ParallelScanSummary) void {
        for (self.entries.items) |*e| {
            e.deinit();
        }
        self.entries.deinit();
    }
};

/// Scan a directory using parallel workers for improved performance
pub fn scanDirectoryParallel(allocator: Allocator, path: []const u8, cfg: ScanConfig) !ParallelScanSummary {
    const start_time = std.time.milliTimestamp();

    // Validate path
    try safety.validatePath(path);

    const worker_count = pool.getOptimalWorkerCount();

    var scanner_pool = try pool.ScannerPool.init(allocator, worker_count);
    defer scanner_pool.deinit();

    try scanner_pool.scan(path, cfg.max_depth, cfg.show_hidden);

    const results = scanner_pool.getResults();
    const end_time = std.time.milliTimestamp();

    // Convert pool results to DirEntry format for display
    var entries = std.ArrayList(DirEntry).init(allocator);
    errdefer {
        for (entries.items) |*e| {
            e.deinit();
        }
        entries.deinit();
    }

    // Group and aggregate by top-level directories
    var dir_sizes = std.StringHashMap(u64).init(allocator);
    defer dir_sizes.deinit();

    for (results.entries) |scan_result| {
        // Extract the first component after the root path
        const relative = if (mem.startsWith(u8, scan_result.path, path))
            scan_result.path[path.len..]
        else
            scan_result.path;

        // Skip leading slash
        const trimmed = if (relative.len > 0 and relative[0] == '/')
            relative[1..]
        else
            relative;

        // Get first directory component
        const first_slash = mem.indexOf(u8, trimmed, "/");
        const top_dir = if (first_slash) |idx|
            trimmed[0..idx]
        else
            trimmed;

        if (top_dir.len == 0) continue;

        // Aggregate sizes
        const existing = dir_sizes.get(top_dir) orelse 0;
        try dir_sizes.put(top_dir, existing + scan_result.size);
    }

    // Convert to DirEntry list
    var iter = dir_sizes.iterator();
    while (iter.next()) |entry| {
        const full_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ path, entry.key_ptr.* });

        try entries.append(.{
            .name = try allocator.dupe(u8, entry.key_ptr.*),
            .path = full_path,
            .size = entry.value_ptr.*,
            .is_dir = true,
            .child_count = 0,
            .allocator = allocator,
        });
    }

    // Sort by size
    std.mem.sort(DirEntry, entries.items, {}, DirEntry.compareBySize);

    // Trim to max entries
    while (entries.items.len > cfg.max_entries) {
        var e = entries.pop();
        e.deinit();
    }

    return .{
        .total_size = results.total_size,
        .file_count = results.total_files,
        .dir_count = results.total_dirs,
        .scan_time_ms = @intCast(@max(0, end_time - start_time)),
        .worker_count = worker_count,
        .entries = entries,
        .allocator = allocator,
    };
}

/// Get system overview using parallel scanning
pub fn getSystemOverviewParallel(allocator: Allocator) !ParallelScanSummary {
    const start_time = std.time.milliTimestamp();
    const home = std.posix.getenv("HOME") orelse "/";

    var entries = std.ArrayList(DirEntry).init(allocator);
    errdefer {
        for (entries.items) |*e| {
            e.deinit();
        }
        entries.deinit();
    }

    var total_size: u64 = 0;
    var total_files: u64 = 0;
    var total_dirs: u64 = 0;

    const worker_count = pool.getOptimalWorkerCount();

    const overview_paths = [_]struct { name: []const u8, path: []const u8 }{
        .{ .name = "Documents", .path = "/Documents" },
        .{ .name = "Downloads", .path = "/Downloads" },
        .{ .name = "Desktop", .path = "/Desktop" },
        .{ .name = "Pictures", .path = "/Pictures" },
        .{ .name = "Music", .path = "/Music" },
        .{ .name = "Movies", .path = "/Movies" },
        .{ .name = "Library", .path = "/Library" },
    };

    // Scan each directory in parallel using the pool
    for (overview_paths) |item| {
        const full_path = try std.fmt.allocPrint(allocator, "{s}{s}", .{ home, item.path });
        errdefer allocator.free(full_path);

        if (!file_ops.pathExists(full_path)) {
            allocator.free(full_path);
            continue;
        }

        // Use parallel scan for each directory
        const scan_result = pool.parallelScan(allocator, full_path, 10) catch |err| {
            log.debug("Failed to scan {s}: {s}", .{ full_path, @errorName(err) });
            allocator.free(full_path);
            continue;
        };

        try entries.append(.{
            .name = try allocator.dupe(u8, item.name),
            .path = full_path,
            .size = scan_result.total_size,
            .is_dir = true,
            .child_count = scan_result.file_count,
            .allocator = allocator,
        });

        total_size += scan_result.total_size;
        total_files += scan_result.file_count;
        total_dirs += scan_result.dir_count;
    }

    // Sort by size
    std.mem.sort(DirEntry, entries.items, {}, DirEntry.compareBySize);

    const end_time = std.time.milliTimestamp();

    return .{
        .total_size = total_size,
        .file_count = total_files,
        .dir_count = total_dirs,
        .scan_time_ms = @intCast(@max(0, end_time - start_time)),
        .worker_count = worker_count,
        .entries = entries,
        .allocator = allocator,
    };
}

/// Print parallel scan results
pub fn printParallelResults(result: *const ParallelScanSummary, writer: anytype) !void {
    const total_fmt = file_ops.formatBytes(result.total_size);

    try writer.writeAll("\n══════════════════════════════════════════════════════\n");
    try writer.writeAll("              DISK SPACE OVERVIEW (Parallel)\n");
    try writer.writeAll("══════════════════════════════════════════════════════\n\n");

    try writer.print("Total Size: {d:.2} {s}\n", .{ total_fmt.value, total_fmt.unit });
    try writer.print("Files: {d}  |  Directories: {d}\n", .{ result.file_count, result.dir_count });
    try writer.print("Scan Time: {d}ms  |  Workers: {d}\n\n", .{ result.scan_time_ms, result.worker_count });

    try writer.writeAll("Directory Sizes:\n");
    try writer.writeAll("─────────────────────────────────────────────────────\n");

    for (result.entries.items) |entry| {
        const size_fmt = file_ops.formatBytes(entry.size);
        const percentage = if (result.total_size > 0)
            @as(f64, @floatFromInt(entry.size)) / @as(f64, @floatFromInt(result.total_size)) * 100
        else
            0;

        try writer.print("📁 {s:<15} {d:>8.2} {s:<2} ", .{
            entry.name,
            size_fmt.value,
            size_fmt.unit,
        });

        // Draw bar
        const bar_width: usize = 25;
        const filled = @as(usize, @intFromFloat(percentage / 100 * @as(f64, @floatFromInt(bar_width))));

        try writer.writeAll("[");
        var j: usize = 0;
        while (j < bar_width) : (j += 1) {
            if (j < filled) {
                try writer.writeAll("█");
            } else {
                try writer.writeAll("░");
            }
        }
        try writer.print("] {d:>5.1}%\n", .{percentage});
    }

    try writer.writeAll("\n");
}

// ============================================================================
// Tests
// ============================================================================

test "scan config defaults" {
    const cfg = ScanConfig{};
    try std.testing.expectEqual(@as(i32, -1), cfg.max_depth);
    try std.testing.expectEqual(@as(u64, 100 * 1024 * 1024), cfg.large_file_threshold);
}

test "truncate name" {
    try std.testing.expectEqualStrings("hello", truncateName("hello", 10));
    try std.testing.expectEqualStrings("hello", truncateName("hello world", 5));
}
