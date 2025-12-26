const std = @import("std");
const fs = std.fs;
const mem = std.mem;
const posix = std.posix;
const Allocator = mem.Allocator;
const safety = @import("safety.zig");

/// File operation errors
pub const FileOpError = error{
    /// Safety validation failed
    SafetyViolation,
    /// File or directory not found
    NotFound,
    /// Permission denied
    PermissionDenied,
    /// Operation would affect too many files
    TooManyFiles,
    /// Disk is full
    DiskFull,
    /// File is in use
    FileInUse,
    /// Not a directory
    NotDirectory,
    /// Not a file
    NotFile,
    /// Directory not empty
    DirectoryNotEmpty,
    /// Unknown error
    Unknown,
} || safety.SafetyError || Allocator.Error;

/// Maximum files to delete in a single operation (safety limit)
pub const MAX_DELETE_BATCH: usize = 10000;

/// Minimum age in days for orphan detection
pub const ORPHAN_MIN_AGE_DAYS: u64 = 60;

/// Result of a file operation
pub const FileOpResult = struct {
    success: bool,
    bytes_freed: u64,
    files_affected: u64,
    errors: std.ArrayList(OperationError),

    pub fn init(allocator: Allocator) FileOpResult {
        return .{
            .success = true,
            .bytes_freed = 0,
            .files_affected = 0,
            .errors = std.ArrayList(OperationError).init(allocator),
        };
    }

    pub fn deinit(self: *FileOpResult) void {
        for (self.errors.items) |*err| {
            err.deinit();
        }
        self.errors.deinit();
    }

    pub fn addError(self: *FileOpResult, allocator: Allocator, path: []const u8, message: []const u8) !void {
        self.success = false;
        try self.errors.append(.{
            .path = try allocator.dupe(u8, path),
            .message = try allocator.dupe(u8, message),
            .allocator = allocator,
        });
    }
};

pub const OperationError = struct {
    path: []const u8,
    message: []const u8,
    allocator: Allocator,

    pub fn deinit(self: *OperationError) void {
        self.allocator.free(self.path);
        self.allocator.free(self.message);
    }
};

/// Options for delete operations
pub const DeleteOptions = struct {
    /// Perform dry run (don't actually delete)
    dry_run: bool = false,
    /// Follow symlinks (dangerous, default false)
    follow_symlinks: bool = false,
    /// Force delete even if files are read-only
    force: bool = false,
    /// Maximum depth for recursive operations (-1 for unlimited)
    max_depth: i32 = -1,
    /// Skip confirmation for sensitive paths
    skip_confirmation: bool = false,
    /// Callback for progress updates
    progress_callback: ?*const fn (path: []const u8, bytes: u64) void = null,
};

/// File metadata with safety information
pub const SafeFileInfo = struct {
    path: []const u8,
    size: u64,
    is_dir: bool,
    is_symlink: bool,
    modified_time: i128,
    accessed_time: i128,
    safety_level: safety.PathSafetyLevel,
    allocator: Allocator,

    pub fn deinit(self: *SafeFileInfo) void {
        self.allocator.free(self.path);
    }
};

/// Get file info with safety analysis
pub fn getFileInfo(allocator: Allocator, path: []const u8) !SafeFileInfo {
    // Validate path first
    try safety.validatePath(path);

    const stat = fs.cwd().statFile(path) catch |err| {
        return switch (err) {
            error.FileNotFound => FileOpError.NotFound,
            error.AccessDenied => FileOpError.PermissionDenied,
            else => FileOpError.Unknown,
        };
    };

    return SafeFileInfo{
        .path = try allocator.dupe(u8, path),
        .size = stat.size,
        .is_dir = stat.kind == .directory,
        .is_symlink = stat.kind == .sym_link,
        .modified_time = stat.mtime,
        .accessed_time = stat.atime,
        .safety_level = safety.analyzePathSafety(path),
        .allocator = allocator,
    };
}

/// Safely delete a file
pub fn safeDeleteFile(allocator: Allocator, path: []const u8, options: DeleteOptions) !FileOpResult {
    var result = FileOpResult.init(allocator);
    errdefer result.deinit();

    // Validate path
    safety.validatePath(path) catch |err| {
        try result.addError(allocator, path, @errorName(err));
        return result;
    };

    // Check safety level
    const safety_level = safety.analyzePathSafety(path);
    if (safety_level == .denied) {
        try result.addError(allocator, path, "Path is protected by Iron Dome");
        return result;
    }

    if (safety_level == .needs_confirmation and !options.skip_confirmation) {
        try result.addError(allocator, path, "Path requires confirmation");
        return result;
    }

    // Get file size before deletion
    const stat = fs.cwd().statFile(path) catch |err| {
        try result.addError(allocator, path, @errorName(err));
        return result;
    };

    if (stat.kind == .directory) {
        try result.addError(allocator, path, "Use safeDeleteDirectory for directories");
        return result;
    }

    // Dry run - just report what would happen
    if (options.dry_run) {
        result.bytes_freed = stat.size;
        result.files_affected = 1;
        return result;
    }

    // Perform deletion
    fs.cwd().deleteFile(path) catch |err| {
        try result.addError(allocator, path, @errorName(err));
        return result;
    };

    result.bytes_freed = stat.size;
    result.files_affected = 1;

    if (options.progress_callback) |callback| {
        callback(path, stat.size);
    }

    return result;
}

/// Safely delete a directory and its contents
pub fn safeDeleteDirectory(allocator: Allocator, path: []const u8, options: DeleteOptions) !FileOpResult {
    var result = FileOpResult.init(allocator);
    errdefer result.deinit();

    // Validate path
    safety.validatePath(path) catch |err| {
        try result.addError(allocator, path, @errorName(err));
        return result;
    };

    // Check safety level
    const safety_level = safety.analyzePathSafety(path);
    if (safety_level == .denied) {
        try result.addError(allocator, path, "Path is protected by Iron Dome");
        return result;
    }

    if (safety_level == .needs_confirmation and !options.skip_confirmation) {
        try result.addError(allocator, path, "Path requires confirmation");
        return result;
    }

    // Validate symlink if not following
    if (!options.follow_symlinks) {
        safety.validateSymlink(path) catch |err| {
            try result.addError(allocator, path, @errorName(err));
            return result;
        };
    }

    // Calculate size and count files
    var total_size: u64 = 0;
    var file_count: u64 = 0;

    try walkDirectory(allocator, path, options.max_depth, &total_size, &file_count);

    // Safety check: don't delete too many files at once
    if (file_count > MAX_DELETE_BATCH) {
        try result.addError(allocator, path, "Too many files - split into smaller operations");
        return result;
    }

    // Dry run - just report what would happen
    if (options.dry_run) {
        result.bytes_freed = total_size;
        result.files_affected = file_count;
        return result;
    }

    // Perform deletion
    fs.cwd().deleteTree(path) catch |err| {
        try result.addError(allocator, path, @errorName(err));
        return result;
    };

    result.bytes_freed = total_size;
    result.files_affected = file_count;

    if (options.progress_callback) |callback| {
        callback(path, total_size);
    }

    return result;
}

/// Walk a directory and calculate total size and file count
fn walkDirectory(allocator: Allocator, path: []const u8, max_depth: i32, total_size: *u64, file_count: *u64) !void {
    if (max_depth == 0) return;

    var dir = fs.cwd().openDir(path, .{ .iterate = true }) catch return;
    defer dir.close();

    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        file_count.* += 1;

        const full_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ path, entry.name });
        defer allocator.free(full_path);

        if (entry.kind == .directory) {
            const new_depth = if (max_depth < 0) max_depth else max_depth - 1;
            try walkDirectory(allocator, full_path, new_depth, total_size, file_count);
        } else {
            const stat = dir.statFile(entry.name) catch continue;
            total_size.* += stat.size;
        }
    }
}

/// Calculate the size of a directory
pub fn calculateDirectorySize(allocator: Allocator, path: []const u8) !u64 {
    try safety.validatePath(path);

    var total_size: u64 = 0;
    var file_count: u64 = 0;
    try walkDirectory(allocator, path, -1, &total_size, &file_count);
    return total_size;
}

/// Check if a path exists
pub fn pathExists(path: []const u8) bool {
    safety.validatePath(path) catch return false;
    fs.cwd().access(path, .{}) catch return false;
    return true;
}

/// Check if a path is a directory
pub fn isDirectory(path: []const u8) bool {
    safety.validatePath(path) catch return false;
    const stat = fs.cwd().statFile(path) catch return false;
    return stat.kind == .directory;
}

/// Check if a file is older than specified days
pub fn isOlderThanDays(path: []const u8, days: u64) !bool {
    try safety.validatePath(path);

    const stat = fs.cwd().statFile(path) catch |err| {
        return switch (err) {
            error.FileNotFound => FileOpError.NotFound,
            error.AccessDenied => FileOpError.PermissionDenied,
            else => FileOpError.Unknown,
        };
    };

    const now = std.time.nanoTimestamp();
    const age_ns = now - stat.mtime;
    const age_days = @divFloor(@as(u64, @intCast(@max(age_ns, 0))), std.time.ns_per_day);

    return age_days >= days;
}

/// Batch delete files with safety checks
pub fn batchDelete(allocator: Allocator, paths: []const []const u8, options: DeleteOptions) !FileOpResult {
    var result = FileOpResult.init(allocator);
    errdefer result.deinit();

    // Safety check: batch size limit
    if (paths.len > MAX_DELETE_BATCH) {
        try result.addError(allocator, "(batch)", "Too many files in batch");
        return result;
    }

    for (paths) |path| {
        const is_dir = isDirectory(path);

        const sub_result = if (is_dir)
            try safeDeleteDirectory(allocator, path, options)
        else
            try safeDeleteFile(allocator, path, options);

        result.bytes_freed += sub_result.bytes_freed;
        result.files_affected += sub_result.files_affected;

        if (!sub_result.success) {
            result.success = false;
            for (sub_result.errors.items) |err| {
                try result.addError(allocator, err.path, err.message);
            }
        }
    }

    return result;
}

/// Create a temporary directory safely
pub fn createTempDir(allocator: Allocator, prefix: []const u8) ![]u8 {
    const tmp_base = "/tmp";
    try safety.validatePath(tmp_base);

    const timestamp = std.time.milliTimestamp();
    const random = std.crypto.random.int(u32);

    const dir_name = try std.fmt.allocPrint(allocator, "{s}/{s}-{d}-{d}", .{
        tmp_base,
        prefix,
        timestamp,
        random,
    });
    errdefer allocator.free(dir_name);

    try safety.validatePath(dir_name);

    fs.cwd().makeDir(dir_name) catch |err| {
        return switch (err) {
            error.AccessDenied => FileOpError.PermissionDenied,
            error.DiskQuota => FileOpError.DiskFull,
            else => FileOpError.Unknown,
        };
    };

    return dir_name;
}

/// Format bytes into human-readable string
pub fn formatBytes(bytes: u64) struct { value: f64, unit: []const u8 } {
    const units = [_][]const u8{ "B", "KB", "MB", "GB", "TB" };
    var value: f64 = @floatFromInt(bytes);
    var unit_idx: usize = 0;

    while (value >= 1024 and unit_idx < units.len - 1) {
        value /= 1024;
        unit_idx += 1;
    }

    return .{ .value = value, .unit = units[unit_idx] };
}

// ============================================================================
// Unit Tests
// ============================================================================

test "format bytes" {
    const result1 = formatBytes(1024);
    try std.testing.expectEqual(@as(f64, 1.0), result1.value);
    try std.testing.expectEqualStrings("KB", result1.unit);

    const result2 = formatBytes(1024 * 1024 * 5);
    try std.testing.expectEqual(@as(f64, 5.0), result2.value);
    try std.testing.expectEqualStrings("MB", result2.unit);

    const result3 = formatBytes(500);
    try std.testing.expectEqual(@as(f64, 500.0), result3.value);
    try std.testing.expectEqualStrings("B", result3.unit);
}

test "file info safety level" {
    // This would need actual file system access to test properly
    // In practice, use a test fixture directory
}

test "delete options defaults" {
    const options = DeleteOptions{};
    try std.testing.expect(!options.dry_run);
    try std.testing.expect(!options.follow_symlinks);
    try std.testing.expect(!options.force);
    try std.testing.expectEqual(@as(i32, -1), options.max_depth);
}
