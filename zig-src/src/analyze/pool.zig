const std = @import("std");
const Thread = std.Thread;
const Mutex = Thread.Mutex;
const Allocator = std.mem.Allocator;
const fs = std.fs;

const safety = @import("../core/safety.zig");
const logging = @import("../core/logging.zig");

const log = logging.scoped("pool");

/// Work item for the pool
pub const WorkItem = struct {
    path: []const u8,
    depth: i32,
};

/// Result from scanning a path
pub const ScanResult = struct {
    path: []const u8,
    size: u64,
    file_count: u64,
    dir_count: u64,
    allocator: Allocator,

    pub fn deinit(self: *ScanResult) void {
        self.allocator.free(self.path);
    }
};

/// Thread-safe work queue
pub const WorkQueue = struct {
    items: std.ArrayList(WorkItem),
    mutex: Mutex,
    done: bool,
    allocator: Allocator,

    pub fn init(allocator: Allocator) WorkQueue {
        return .{
            .items = std.ArrayList(WorkItem).init(allocator),
            .mutex = .{},
            .done = false,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *WorkQueue) void {
        for (self.items.items) |item| {
            self.allocator.free(item.path);
        }
        self.items.deinit();
    }

    pub fn push(self: *WorkQueue, item: WorkItem) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.items.append(item);
    }

    pub fn pop(self: *WorkQueue) ?WorkItem {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.items.items.len == 0) {
            return null;
        }
        return self.items.pop();
    }

    pub fn isEmpty(self: *WorkQueue) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.items.items.len == 0;
    }

    pub fn markDone(self: *WorkQueue) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.done = true;
    }

    pub fn isDone(self: *WorkQueue) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.done and self.items.items.len == 0;
    }
};

/// Aggregated results with thread-safe access
pub const ResultCollector = struct {
    results: std.ArrayList(ScanResult),
    total_size: std.atomic.Value(u64),
    total_files: std.atomic.Value(u64),
    total_dirs: std.atomic.Value(u64),
    mutex: Mutex,
    allocator: Allocator,

    pub fn init(allocator: Allocator) ResultCollector {
        return .{
            .results = std.ArrayList(ScanResult).init(allocator),
            .total_size = std.atomic.Value(u64).init(0),
            .total_files = std.atomic.Value(u64).init(0),
            .total_dirs = std.atomic.Value(u64).init(0),
            .mutex = .{},
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *ResultCollector) void {
        for (self.results.items) |*r| {
            r.deinit();
        }
        self.results.deinit();
    }

    pub fn addResult(self: *ResultCollector, result: ScanResult) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.results.append(result);
    }

    pub fn addSize(self: *ResultCollector, size: u64) void {
        _ = self.total_size.fetchAdd(size, .monotonic);
    }

    pub fn addFiles(self: *ResultCollector, count: u64) void {
        _ = self.total_files.fetchAdd(count, .monotonic);
    }

    pub fn addDirs(self: *ResultCollector, count: u64) void {
        _ = self.total_dirs.fetchAdd(count, .monotonic);
    }

    pub fn getTotalSize(self: *ResultCollector) u64 {
        return self.total_size.load(.monotonic);
    }

    pub fn getTotalFiles(self: *ResultCollector) u64 {
        return self.total_files.load(.monotonic);
    }

    pub fn getTotalDirs(self: *ResultCollector) u64 {
        return self.total_dirs.load(.monotonic);
    }
};

/// Worker context
const WorkerContext = struct {
    queue: *WorkQueue,
    collector: *ResultCollector,
    allocator: Allocator,
    max_depth: i32,
    show_hidden: bool,
    active_workers: *std.atomic.Value(u32),
};

/// Scanner worker pool
pub const ScannerPool = struct {
    workers: []Thread,
    queue: WorkQueue,
    collector: ResultCollector,
    allocator: Allocator,
    active_workers: std.atomic.Value(u32),

    /// Create a new scanner pool
    pub fn init(allocator: Allocator, worker_count: u32) !ScannerPool {
        const count = @max(2, @min(worker_count, 32));

        return .{
            .workers = try allocator.alloc(Thread, count),
            .queue = WorkQueue.init(allocator),
            .collector = ResultCollector.init(allocator),
            .allocator = allocator,
            .active_workers = std.atomic.Value(u32).init(0),
        };
    }

    pub fn deinit(self: *ScannerPool) void {
        self.queue.deinit();
        self.collector.deinit();
        self.allocator.free(self.workers);
    }

    /// Scan a directory using the worker pool
    pub fn scan(self: *ScannerPool, path: []const u8, max_depth: i32, show_hidden: bool) !void {
        // Validate root path
        try safety.validatePath(path);

        // Add initial work item
        try self.queue.push(.{
            .path = try self.allocator.dupe(u8, path),
            .depth = max_depth,
        });

        // Create worker context
        var ctx = WorkerContext{
            .queue = &self.queue,
            .collector = &self.collector,
            .allocator = self.allocator,
            .max_depth = max_depth,
            .show_hidden = show_hidden,
            .active_workers = &self.active_workers,
        };

        // Spawn workers
        for (self.workers, 0..) |*worker, i| {
            _ = i;
            worker.* = try Thread.spawn(.{}, workerFn, .{&ctx});
        }

        // Wait for all workers to complete
        for (self.workers) |worker| {
            worker.join();
        }
    }

    /// Get results after scanning
    pub fn getResults(self: *ScannerPool) struct {
        total_size: u64,
        total_files: u64,
        total_dirs: u64,
        entries: []ScanResult,
    } {
        return .{
            .total_size = self.collector.getTotalSize(),
            .total_files = self.collector.getTotalFiles(),
            .total_dirs = self.collector.getTotalDirs(),
            .entries = self.collector.results.items,
        };
    }
};

/// Worker function
fn workerFn(ctx: *WorkerContext) void {
    _ = ctx.active_workers.fetchAdd(1, .monotonic);
    defer _ = ctx.active_workers.fetchSub(1, .monotonic);

    while (true) {
        // Try to get work
        const item = ctx.queue.pop() orelse {
            // No work available
            // Check if other workers are still active and queue might get more items
            if (ctx.active_workers.load(.monotonic) <= 1 and ctx.queue.isEmpty()) {
                // We're the last worker and queue is empty, mark done
                ctx.queue.markDone();
                break;
            }

            // Wait a bit and try again
            std.time.sleep(1_000_000); // 1ms
            if (ctx.queue.isDone()) break;
            continue;
        };
        defer ctx.allocator.free(item.path);

        // Process this directory
        processDirectory(ctx, item.path, item.depth) catch |err| {
            log.debug("Error processing {s}: {s}", .{ item.path, @errorName(err) });
        };
    }
}

/// Process a single directory
fn processDirectory(ctx: *WorkerContext, path: []const u8, depth: i32) !void {
    // Validate path
    safety.validatePath(path) catch return;

    var dir = fs.cwd().openDir(path, .{ .iterate = true }) catch return;
    defer dir.close();

    var local_size: u64 = 0;
    var local_files: u64 = 0;
    var local_dirs: u64 = 0;

    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        // Skip hidden files if requested
        if (!ctx.show_hidden and entry.name[0] == '.') {
            continue;
        }

        if (entry.kind == .directory) {
            local_dirs += 1;

            // Add subdirectory to queue if within depth limit
            if (depth != 0) {
                const sub_path = try std.fmt.allocPrint(ctx.allocator, "{s}/{s}", .{ path, entry.name });
                const new_depth = if (depth < 0) depth else depth - 1;

                ctx.queue.push(.{
                    .path = sub_path,
                    .depth = new_depth,
                }) catch {
                    ctx.allocator.free(sub_path);
                };
            }
        } else {
            local_files += 1;

            // Get file size
            const stat = dir.statFile(entry.name) catch continue;
            local_size += stat.size;
        }
    }

    // Update global counters
    ctx.collector.addSize(local_size);
    ctx.collector.addFiles(local_files);
    ctx.collector.addDirs(local_dirs);

    // Add result for this directory
    try ctx.collector.addResult(.{
        .path = try ctx.allocator.dupe(u8, path),
        .size = local_size,
        .file_count = local_files,
        .dir_count = local_dirs,
        .allocator = ctx.allocator,
    });
}

/// Get optimal worker count based on CPU cores
pub fn getOptimalWorkerCount() u32 {
    // I/O bound work benefits from more workers than cores
    const cpu_count = Thread.getCpuCount() catch 4;
    return @intCast(@min(32, cpu_count * 2));
}

// ============================================================================
// Convenience function for parallel scanning
// ============================================================================

/// Parallel scan result
pub const ParallelScanResult = struct {
    total_size: u64,
    file_count: u64,
    dir_count: u64,
    scan_time_ms: u64,
    worker_count: u32,
};

/// Scan a directory in parallel and return aggregate stats
pub fn parallelScan(
    allocator: Allocator,
    path: []const u8,
    max_depth: i32,
) !ParallelScanResult {
    const start = std.time.milliTimestamp();
    const worker_count = getOptimalWorkerCount();

    var pool = try ScannerPool.init(allocator, worker_count);
    defer pool.deinit();

    try pool.scan(path, max_depth, true);

    const results = pool.getResults();
    const end = std.time.milliTimestamp();

    return .{
        .total_size = results.total_size,
        .file_count = results.total_files,
        .dir_count = results.total_dirs,
        .scan_time_ms = @intCast(@max(0, end - start)),
        .worker_count = worker_count,
    };
}

// ============================================================================
// Tests
// ============================================================================

test "work queue basic operations" {
    const allocator = std.testing.allocator;

    var queue = WorkQueue.init(allocator);
    defer queue.deinit();

    try queue.push(.{ .path = try allocator.dupe(u8, "/test"), .depth = 1 });

    const item = queue.pop();
    try std.testing.expect(item != null);
    allocator.free(item.?.path);

    try std.testing.expect(queue.isEmpty());
}

test "optimal worker count" {
    const count = getOptimalWorkerCount();
    try std.testing.expect(count >= 2);
    try std.testing.expect(count <= 32);
}
