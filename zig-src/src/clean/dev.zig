const std = @import("std");
const fs = std.fs;
const mem = std.mem;
const Allocator = mem.Allocator;

const safety = @import("../core/safety.zig");
const file_ops = @import("../core/file_ops.zig");
const logging = @import("../core/logging.zig");
const config = @import("../core/config.zig");

const log = logging.scoped("dev");

/// Developer tool category
pub const DevToolCategory = enum {
    xcode,
    node,
    rust,
    go,
    python,
    ruby,
    java,
    homebrew,
    docker,
    cocoapods,
    gradle,

    pub fn displayName(self: DevToolCategory) []const u8 {
        return switch (self) {
            .xcode => "Xcode",
            .node => "Node.js/npm",
            .rust => "Rust/Cargo",
            .go => "Go",
            .python => "Python/pip",
            .ruby => "Ruby/Gems",
            .java => "Java/Maven",
            .homebrew => "Homebrew",
            .docker => "Docker",
            .cocoapods => "CocoaPods",
            .gradle => "Gradle",
        };
    }

    pub fn description(self: DevToolCategory) []const u8 {
        return switch (self) {
            .xcode => "Xcode build artifacts, simulators, and derived data",
            .node => "npm/yarn/pnpm caches and global packages",
            .rust => "Cargo registry cache and build artifacts",
            .go => "Go module cache and build cache",
            .python => "pip cache and virtual environments",
            .ruby => "Ruby gems cache",
            .java => "Maven/Gradle caches",
            .homebrew => "Homebrew download cache",
            .docker => "Docker images and build cache",
            .cocoapods => "CocoaPods cache",
            .gradle => "Gradle build cache",
        };
    }
};

/// Developer tool cache location
pub const DevToolPath = struct {
    category: DevToolCategory,
    name: []const u8,
    /// Path template (use {home} for home dir)
    path_template: []const u8,
    /// Whether this is considered safe to delete
    safe_to_delete: bool = true,
    /// Estimated recovery difficulty (1-5)
    recovery_difficulty: u8 = 1,
    /// Minimum age in days before cleanup (0 = always)
    min_age_days: u64 = 0,
};

/// All known developer tool paths
pub const DEV_TOOL_PATHS = [_]DevToolPath{
    // Xcode
    .{
        .category = .xcode,
        .name = "DerivedData",
        .path_template = "{home}/Library/Developer/Xcode/DerivedData",
        .recovery_difficulty = 1,
    },
    .{
        .category = .xcode,
        .name = "iOS Device Support",
        .path_template = "{home}/Library/Developer/Xcode/iOS DeviceSupport",
        .recovery_difficulty = 2,
        .min_age_days = 90,
    },
    .{
        .category = .xcode,
        .name = "watchOS Device Support",
        .path_template = "{home}/Library/Developer/Xcode/watchOS DeviceSupport",
        .recovery_difficulty = 2,
        .min_age_days = 90,
    },
    .{
        .category = .xcode,
        .name = "Archives",
        .path_template = "{home}/Library/Developer/Xcode/Archives",
        .safe_to_delete = false,
        .recovery_difficulty = 5,
    },
    .{
        .category = .xcode,
        .name = "Simulator Caches",
        .path_template = "{home}/Library/Developer/CoreSimulator/Caches",
        .recovery_difficulty = 1,
    },
    .{
        .category = .xcode,
        .name = "Simulator Devices",
        .path_template = "{home}/Library/Developer/CoreSimulator/Devices",
        .safe_to_delete = false,
        .recovery_difficulty = 3,
    },

    // Node.js / npm / yarn / pnpm
    .{
        .category = .node,
        .name = "npm cache",
        .path_template = "{home}/.npm/_cacache",
        .recovery_difficulty = 1,
    },
    .{
        .category = .node,
        .name = "npm logs",
        .path_template = "{home}/.npm/_logs",
        .recovery_difficulty = 1,
    },
    .{
        .category = .node,
        .name = "Yarn cache",
        .path_template = "{home}/.yarn/cache",
        .recovery_difficulty = 1,
    },
    .{
        .category = .node,
        .name = "Yarn unplugged",
        .path_template = "{home}/.yarn/unplugged",
        .recovery_difficulty = 2,
    },
    .{
        .category = .node,
        .name = "pnpm cache",
        .path_template = "{home}/.pnpm-store",
        .recovery_difficulty = 1,
    },
    .{
        .category = .node,
        .name = "Cypress cache",
        .path_template = "{home}/.cache/Cypress",
        .recovery_difficulty = 2,
    },

    // Rust / Cargo
    .{
        .category = .rust,
        .name = "Cargo registry cache",
        .path_template = "{home}/.cargo/registry/cache",
        .recovery_difficulty = 1,
    },
    .{
        .category = .rust,
        .name = "Cargo registry index",
        .path_template = "{home}/.cargo/registry/index",
        .recovery_difficulty = 1,
    },
    .{
        .category = .rust,
        .name = "Cargo git checkouts",
        .path_template = "{home}/.cargo/git/checkouts",
        .recovery_difficulty = 1,
    },
    .{
        .category = .rust,
        .name = "Cargo git db",
        .path_template = "{home}/.cargo/git/db",
        .recovery_difficulty = 2,
    },

    // Go
    .{
        .category = .go,
        .name = "Go build cache",
        .path_template = "{home}/.cache/go-build",
        .recovery_difficulty = 1,
    },
    .{
        .category = .go,
        .name = "Go module cache",
        .path_template = "{home}/go/pkg/mod/cache",
        .recovery_difficulty = 1,
    },

    // Python
    .{
        .category = .python,
        .name = "pip cache",
        .path_template = "{home}/.cache/pip",
        .recovery_difficulty = 1,
    },
    .{
        .category = .python,
        .name = "pip http cache",
        .path_template = "{home}/Library/Caches/pip",
        .recovery_difficulty = 1,
    },
    .{
        .category = .python,
        .name = "Poetry cache",
        .path_template = "{home}/.cache/pypoetry",
        .recovery_difficulty = 1,
    },
    .{
        .category = .python,
        .name = "Pipenv cache",
        .path_template = "{home}/.cache/pipenv",
        .recovery_difficulty = 1,
    },

    // Ruby
    .{
        .category = .ruby,
        .name = "Gem cache",
        .path_template = "{home}/.gem/ruby",
        .recovery_difficulty = 2,
        .min_age_days = 30,
    },
    .{
        .category = .ruby,
        .name = "Bundler cache",
        .path_template = "{home}/.bundle/cache",
        .recovery_difficulty = 1,
    },

    // Java / Maven / Gradle
    .{
        .category = .java,
        .name = "Maven cache",
        .path_template = "{home}/.m2/repository",
        .recovery_difficulty = 2,
    },
    .{
        .category = .gradle,
        .name = "Gradle cache",
        .path_template = "{home}/.gradle/caches",
        .recovery_difficulty = 2,
    },
    .{
        .category = .gradle,
        .name = "Gradle wrapper",
        .path_template = "{home}/.gradle/wrapper",
        .recovery_difficulty = 1,
    },

    // Homebrew
    .{
        .category = .homebrew,
        .name = "Homebrew cache",
        .path_template = "{home}/Library/Caches/Homebrew",
        .recovery_difficulty = 1,
    },
    .{
        .category = .homebrew,
        .name = "Homebrew logs",
        .path_template = "{home}/Library/Logs/Homebrew",
        .recovery_difficulty = 1,
    },

    // Docker
    .{
        .category = .docker,
        .name = "Docker desktop data",
        .path_template = "{home}/Library/Containers/com.docker.docker/Data",
        .safe_to_delete = false,
        .recovery_difficulty = 4,
    },

    // CocoaPods
    .{
        .category = .cocoapods,
        .name = "CocoaPods cache",
        .path_template = "{home}/Library/Caches/CocoaPods",
        .recovery_difficulty = 1,
    },
    .{
        .category = .cocoapods,
        .name = "CocoaPods repos",
        .path_template = "{home}/.cocoapods/repos",
        .recovery_difficulty = 2,
    },
};

/// Result of scanning a dev tool path
pub const DevToolScanResult = struct {
    path_info: DevToolPath,
    full_path: []const u8,
    size: u64,
    file_count: u64,
    can_clean: bool,
    skip_reason: ?[]const u8,
    allocator: Allocator,

    pub fn deinit(self: *DevToolScanResult) void {
        self.allocator.free(self.full_path);
        if (self.skip_reason) |reason| {
            self.allocator.free(reason);
        }
    }
};

/// Dev cleaner configuration
pub const DevCleanerConfig = struct {
    /// Categories to include (null = all safe ones)
    categories: ?[]const DevToolCategory = null,
    /// Include unsafe paths
    include_unsafe: bool = false,
    /// Dry run mode
    dry_run: bool = false,
    /// Minimum size to consider (bytes)
    min_size: u64 = 0,
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

/// Scan all developer tool paths
pub fn scanDevTools(allocator: Allocator, cfg: DevCleanerConfig) !std.ArrayList(DevToolScanResult) {
    var results = std.ArrayList(DevToolScanResult).init(allocator);
    errdefer {
        for (results.items) |*item| {
            item.deinit();
        }
        results.deinit();
    }

    const home = std.posix.getenv("HOME") orelse return error.NoHomeDir;

    for (DEV_TOOL_PATHS) |path_info| {
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

        // Check safe to delete
        if (!path_info.safe_to_delete and !cfg.include_unsafe) {
            continue;
        }

        const full_path = try expandPath(allocator, path_info.path_template, home);

        var result = DevToolScanResult{
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

        // Check if exists
        if (!file_ops.pathExists(full_path)) {
            result.can_clean = false;
            result.skip_reason = try allocator.dupe(u8, "not found");
            try results.append(result);
            continue;
        }

        // Calculate size
        result.size = file_ops.calculateDirectorySize(allocator, full_path) catch 0;

        if (result.size < cfg.min_size) {
            result.can_clean = false;
            result.skip_reason = try allocator.dupe(u8, "below size threshold");
            try results.append(result);
            continue;
        }

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

/// Clean developer tool caches
pub fn cleanDevTools(
    allocator: Allocator,
    results: []const DevToolScanResult,
    dry_run: bool,
) !file_ops.FileOpResult {
    var result = file_ops.FileOpResult.init(allocator);
    errdefer result.deinit();

    for (results) |scan_result| {
        if (!scan_result.can_clean or scan_result.size == 0) {
            continue;
        }

        log.info("Cleaning: {s} ({s})", .{
            scan_result.path_info.name,
            scan_result.path_info.category.displayName(),
        });

        var sub_result = try file_ops.safeDeleteDirectory(allocator, scan_result.full_path, .{
            .dry_run = dry_run,
            .skip_confirmation = true,
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

    return result;
}

/// Get summary by category
pub fn getSummaryByCategory(results: []const DevToolScanResult) std.AutoHashMap(DevToolCategory, u64) {
    var summary = std.AutoHashMap(DevToolCategory, u64).init(std.heap.page_allocator);

    for (results) |r| {
        if (!r.can_clean) continue;

        const existing = summary.get(r.path_info.category) orelse 0;
        summary.put(r.path_info.category, existing + r.size) catch continue;
    }

    return summary;
}

/// Print scan results grouped by category
pub fn printDevToolResults(results: []const DevToolScanResult, writer: anytype) !void {
    var current_category: ?DevToolCategory = null;

    for (results) |r| {
        if (current_category == null or current_category.? != r.path_info.category) {
            current_category = r.path_info.category;
            try writer.print("\n{s}:\n", .{r.path_info.category.displayName()});
        }

        const formatted = file_ops.formatBytes(r.size);

        if (r.can_clean and r.size > 0) {
            const difficulty = switch (r.path_info.recovery_difficulty) {
                1 => "easy",
                2 => "medium",
                3 => "slow",
                4 => "hard",
                else => "risky",
            };
            try writer.print("  ✅ {s}: {d:.2} {s} (recovery: {s})\n", .{
                r.path_info.name,
                formatted.value,
                formatted.unit,
                difficulty,
            });
        } else {
            try writer.print("  ⏭️  {s}: {s}\n", .{
                r.path_info.name,
                r.skip_reason orelse "skipped",
            });
        }
    }
}

/// Calculate total reclaimable space
pub fn getTotalReclaimable(results: []const DevToolScanResult) struct { size: u64, count: u64 } {
    var total: u64 = 0;
    var count: u64 = 0;

    for (results) |r| {
        if (r.can_clean and r.size > 0) {
            total += r.size;
            count += 1;
        }
    }

    return .{ .size = total, .count = count };
}

// ============================================================================
// Project Artifact Cleanup (node_modules, target, build, etc.)
// ============================================================================

/// Project artifact type
pub const ProjectArtifact = enum {
    node_modules,
    target, // Rust
    build,
    dist,
    out,
    venv,
    pycache,
    next,
    nuxt,
    cache,
    coverage,

    pub fn displayName(self: ProjectArtifact) []const u8 {
        return switch (self) {
            .node_modules => "node_modules",
            .target => "target (Rust)",
            .build => "build",
            .dist => "dist",
            .out => "out",
            .venv => "venv (Python)",
            .pycache => "__pycache__",
            .next => ".next (Next.js)",
            .nuxt => ".nuxt (Nuxt.js)",
            .cache => ".cache",
            .coverage => "coverage",
        };
    }

    pub fn dirName(self: ProjectArtifact) []const u8 {
        return switch (self) {
            .node_modules => "node_modules",
            .target => "target",
            .build => "build",
            .dist => "dist",
            .out => "out",
            .venv => "venv",
            .pycache => "__pycache__",
            .next => ".next",
            .nuxt => ".nuxt",
            .cache => ".cache",
            .coverage => "coverage",
        };
    }
};

/// Found project artifact
pub const FoundArtifact = struct {
    artifact_type: ProjectArtifact,
    path: []const u8,
    size: u64,
    /// Days since last modification
    age_days: u64,
    /// Whether this is a recent project (< 7 days)
    is_recent: bool,
    allocator: Allocator,

    pub fn deinit(self: *FoundArtifact) void {
        self.allocator.free(self.path);
    }
};

/// Scan for project artifacts recursively
pub fn scanProjectArtifacts(
    allocator: Allocator,
    root_path: []const u8,
    max_depth: u32,
) !std.ArrayList(FoundArtifact) {
    var artifacts = std.ArrayList(FoundArtifact).init(allocator);
    errdefer {
        for (artifacts.items) |*a| {
            a.deinit();
        }
        artifacts.deinit();
    }

    try scanProjectArtifactsRecursive(allocator, root_path, 0, max_depth, &artifacts);

    return artifacts;
}

fn scanProjectArtifactsRecursive(
    allocator: Allocator,
    path: []const u8,
    depth: u32,
    max_depth: u32,
    artifacts: *std.ArrayList(FoundArtifact),
) !void {
    if (depth >= max_depth) return;

    // Validate path
    safety.validatePath(path) catch return;

    var dir = fs.cwd().openDir(path, .{ .iterate = true }) catch return;
    defer dir.close();

    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        if (entry.kind != .directory) continue;

        // Skip hidden directories except specific ones
        if (entry.name[0] == '.' and
            !mem.eql(u8, entry.name, ".next") and
            !mem.eql(u8, entry.name, ".nuxt") and
            !mem.eql(u8, entry.name, ".cache"))
        {
            continue;
        }

        const full_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ path, entry.name });

        // Check if this is an artifact directory
        var is_artifact = false;
        var artifact_type: ProjectArtifact = undefined;

        inline for (std.meta.fields(ProjectArtifact)) |field| {
            const at = @field(ProjectArtifact, field.name);
            if (mem.eql(u8, entry.name, at.dirName())) {
                is_artifact = true;
                artifact_type = at;
                break;
            }
        }

        if (is_artifact) {
            const size = file_ops.calculateDirectorySize(allocator, full_path) catch 0;
            const is_old = file_ops.isOlderThanDays(full_path, 7) catch true;

            try artifacts.append(.{
                .artifact_type = artifact_type,
                .path = full_path,
                .size = size,
                .age_days = if (is_old) 7 else 0,
                .is_recent = !is_old,
                .allocator = allocator,
            });
        } else {
            defer allocator.free(full_path);
            // Recurse into this directory
            try scanProjectArtifactsRecursive(allocator, full_path, depth + 1, max_depth, artifacts);
        }
    }
}

/// Print found artifacts
pub fn printProjectArtifacts(artifacts: []const FoundArtifact, writer: anytype) !void {
    var total_size: u64 = 0;
    var recent_count: u64 = 0;

    for (artifacts) |a| {
        const formatted = file_ops.formatBytes(a.size);
        const status = if (a.is_recent) "⚠️  (recent)" else "✅";

        try writer.print("{s} {s}: {d:.2} {s}\n", .{
            status,
            a.path,
            formatted.value,
            formatted.unit,
        });

        if (!a.is_recent) {
            total_size += a.size;
        } else {
            recent_count += 1;
        }
    }

    const formatted_total = file_ops.formatBytes(total_size);
    try writer.print("\nTotal reclaimable: {d:.2} {s}\n", .{
        formatted_total.value,
        formatted_total.unit,
    });

    if (recent_count > 0) {
        try writer.print("({d} recent projects excluded)\n", .{recent_count});
    }
}

// ============================================================================
// Tests
// ============================================================================

test "dev tool category names" {
    try std.testing.expectEqualStrings("Xcode", DevToolCategory.xcode.displayName());
    try std.testing.expectEqualStrings("Node.js/npm", DevToolCategory.node.displayName());
}

test "expand path template" {
    const allocator = std.testing.allocator;

    const result = try expandPath(allocator, "{home}/Library/Caches", "/Users/test");
    defer allocator.free(result);

    try std.testing.expectEqualStrings("/Users/test/Library/Caches", result);
}

test "project artifact names" {
    try std.testing.expectEqualStrings("node_modules", ProjectArtifact.node_modules.dirName());
    try std.testing.expectEqualStrings("target", ProjectArtifact.target.dirName());
}
