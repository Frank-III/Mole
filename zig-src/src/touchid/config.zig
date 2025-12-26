const std = @import("std");
const fs = std.fs;
const mem = std.mem;
const Allocator = mem.Allocator;
const Child = std.process.Child;

const logging = @import("../core/logging.zig");

const log = logging.scoped("touchid");

/// PAM configuration file path
const PAM_SUDO_PATH = "/etc/pam.d/sudo";
const PAM_SUDO_LOCAL_PATH = "/etc/pam.d/sudo_local";

/// The line to add for Touch ID
const TOUCHID_LINE = "auth       sufficient     pam_tid.so";

/// Touch ID status
pub const TouchIdStatus = enum {
    enabled,
    disabled,
    not_supported,
    unknown,

    pub fn displayName(self: TouchIdStatus) []const u8 {
        return switch (self) {
            .enabled => "Enabled",
            .disabled => "Disabled",
            .not_supported => "Not Supported",
            .unknown => "Unknown",
        };
    }
};

/// Check if Touch ID hardware is available
pub fn isHardwareAvailable() bool {
    // Check for Touch ID by looking for biometric support
    // On Apple Silicon Macs and Intel Macs with Touch Bar
    var child = Child.init(&.{ "bioutil", "-r" }, std.heap.page_allocator);
    child.stderr_behavior = .Ignore;
    child.stdout_behavior = .Ignore;

    child.spawn() catch return false;
    const term = child.wait() catch return false;

    return term.Exited == 0;
}

/// Check current Touch ID sudo status
pub fn getStatus(allocator: Allocator) !TouchIdStatus {
    // First check hardware
    if (!isHardwareAvailable()) {
        return .not_supported;
    }

    // Check sudo_local first (preferred on newer macOS)
    if (checkPamFile(allocator, PAM_SUDO_LOCAL_PATH)) |has_tid| {
        return if (has_tid) .enabled else .disabled;
    } else |_| {}

    // Fall back to sudo
    if (checkPamFile(allocator, PAM_SUDO_PATH)) |has_tid| {
        return if (has_tid) .enabled else .disabled;
    } else |_| {}

    return .unknown;
}

/// Check if a PAM file has Touch ID enabled
fn checkPamFile(allocator: Allocator, path: []const u8) !bool {
    const file = try fs.cwd().openFile(path, .{});
    defer file.close();

    const content = try file.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(content);

    return mem.indexOf(u8, content, "pam_tid.so") != null;
}

/// Enable Touch ID for sudo
pub fn enable(allocator: Allocator) !EnableResult {
    var result = EnableResult{
        .success = false,
        .message = null,
        .allocator = allocator,
    };

    // Check hardware first
    if (!isHardwareAvailable()) {
        result.message = try allocator.dupe(u8, "Touch ID hardware not available");
        return result;
    }

    // Check if already enabled
    const status = try getStatus(allocator);
    if (status == .enabled) {
        result.success = true;
        result.message = try allocator.dupe(u8, "Touch ID for sudo is already enabled");
        return result;
    }

    // Try sudo_local first (recommended approach, survives macOS updates)
    const use_local = fs.cwd().access(PAM_SUDO_LOCAL_PATH, .{}) catch false;

    if (use_local) {
        result = try enableInFile(allocator, PAM_SUDO_LOCAL_PATH);
    } else {
        // Create sudo_local or modify sudo
        result = try enableInFile(allocator, PAM_SUDO_PATH);
    }

    return result;
}

/// Result of enable/disable operation
pub const EnableResult = struct {
    success: bool,
    message: ?[]const u8,
    allocator: Allocator,

    pub fn deinit(self: *EnableResult) void {
        if (self.message) |m| self.allocator.free(m);
    }
};

/// Enable Touch ID in a specific PAM file
fn enableInFile(allocator: Allocator, path: []const u8) !EnableResult {
    var result = EnableResult{
        .success = false,
        .message = null,
        .allocator = allocator,
    };

    // Read current content
    const file = fs.cwd().openFile(path, .{}) catch |err| {
        result.message = try std.fmt.allocPrint(allocator, "Cannot open {s}: {s}", .{ path, @errorName(err) });
        return result;
    };

    const content = file.readToEndAlloc(allocator, 1024 * 1024) catch |err| {
        file.close();
        result.message = try std.fmt.allocPrint(allocator, "Cannot read {s}: {s}", .{ path, @errorName(err) });
        return result;
    };
    defer allocator.free(content);
    file.close();

    // Check if already has pam_tid.so
    if (mem.indexOf(u8, content, "pam_tid.so") != null) {
        result.success = true;
        result.message = try allocator.dupe(u8, "Touch ID already configured");
        return result;
    }

    // Build new content with Touch ID line at the top (after comments)
    var new_content = std.ArrayList(u8).init(allocator);
    defer new_content.deinit();

    var lines = mem.splitScalar(u8, content, '\n');
    var inserted = false;

    while (lines.next()) |line| {
        // Write the line
        try new_content.appendSlice(line);
        try new_content.append('\n');

        // Insert after the first "auth" line or comment block
        if (!inserted and line.len > 0 and line[0] != '#') {
            if (mem.startsWith(u8, mem.trim(u8, line, " \t"), "auth")) {
                // Insert our line before the next auth line
            } else {
                // Insert at the start of non-comment content
                try new_content.appendSlice(TOUCHID_LINE);
                try new_content.append('\n');
                inserted = true;
            }
        }
    }

    // If we haven't inserted yet, add at the beginning after shebang/comments
    if (!inserted) {
        var final_content = std.ArrayList(u8).init(allocator);
        errdefer final_content.deinit();

        try final_content.appendSlice("# sudo_local: local config for sudo, survives system updates\n");
        try final_content.appendSlice(TOUCHID_LINE);
        try final_content.append('\n');
        try final_content.appendSlice(new_content.items);

        // Write using sudo tee
        const write_result = try writeWithSudo(allocator, path, final_content.items);
        return write_result;
    }

    // Write using sudo tee
    return try writeWithSudo(allocator, path, new_content.items);
}

/// Write content to a file using sudo tee
fn writeWithSudo(allocator: Allocator, path: []const u8, content: []const u8) !EnableResult {
    var result = EnableResult{
        .success = false,
        .message = null,
        .allocator = allocator,
    };

    // Use sudo tee to write
    var child = Child.init(&.{ "sudo", "tee", path }, allocator);
    child.stdin_behavior = .Pipe;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Pipe;

    child.spawn() catch |err| {
        result.message = try std.fmt.allocPrint(allocator, "Failed to spawn sudo: {s}", .{@errorName(err)});
        return result;
    };

    // Write content to stdin
    if (child.stdin) |stdin| {
        stdin.writeAll(content) catch {};
        stdin.close();
    }

    const term = child.wait() catch |err| {
        result.message = try std.fmt.allocPrint(allocator, "Failed to wait: {s}", .{@errorName(err)});
        return result;
    };

    if (term.Exited == 0) {
        result.success = true;
        result.message = try allocator.dupe(u8, "Touch ID for sudo enabled successfully");
    } else {
        // Read stderr
        if (child.stderr) |stderr| {
            var buf: [1024]u8 = undefined;
            const len = stderr.read(&buf) catch 0;
            if (len > 0) {
                result.message = try allocator.dupe(u8, buf[0..len]);
            } else {
                result.message = try allocator.dupe(u8, "Failed to enable Touch ID (permission denied?)");
            }
        }
    }

    return result;
}

/// Disable Touch ID for sudo
pub fn disable(allocator: Allocator) !EnableResult {
    var result = EnableResult{
        .success = false,
        .message = null,
        .allocator = allocator,
    };

    const status = try getStatus(allocator);
    if (status != .enabled) {
        result.success = true;
        result.message = try allocator.dupe(u8, "Touch ID for sudo is not enabled");
        return result;
    }

    // Read and modify the file
    const paths = [_][]const u8{ PAM_SUDO_LOCAL_PATH, PAM_SUDO_PATH };

    for (paths) |path| {
        const file = fs.cwd().openFile(path, .{}) catch continue;

        const content = file.readToEndAlloc(allocator, 1024 * 1024) catch {
            file.close();
            continue;
        };
        defer allocator.free(content);
        file.close();

        if (mem.indexOf(u8, content, "pam_tid.so") == null) {
            continue;
        }

        // Remove the Touch ID line
        var new_content = std.ArrayList(u8).init(allocator);
        defer new_content.deinit();

        var lines = mem.splitScalar(u8, content, '\n');
        while (lines.next()) |line| {
            if (mem.indexOf(u8, line, "pam_tid.so") != null) {
                continue; // Skip this line
            }
            try new_content.appendSlice(line);
            try new_content.append('\n');
        }

        return try writeWithSudo(allocator, path, new_content.items);
    }

    result.message = try allocator.dupe(u8, "Could not find Touch ID configuration to remove");
    return result;
}

/// Print Touch ID status
pub fn printStatus(status: TouchIdStatus, writer: anytype) !void {
    try writer.writeAll("\n══════════════════════════════════════════════════════\n");
    try writer.writeAll("              TOUCH ID FOR SUDO\n");
    try writer.writeAll("══════════════════════════════════════════════════════\n\n");

    const emoji = switch (status) {
        .enabled => "✅",
        .disabled => "❌",
        .not_supported => "⚠️",
        .unknown => "❓",
    };

    try writer.print("Status: {s} {s}\n\n", .{ emoji, status.displayName() });

    switch (status) {
        .enabled => {
            try writer.writeAll("Touch ID is configured for sudo authentication.\n");
            try writer.writeAll("You can use your fingerprint instead of password.\n");
        },
        .disabled => {
            try writer.writeAll("Touch ID is available but not configured for sudo.\n");
            try writer.writeAll("Run 'mole touchid enable' to set it up.\n");
        },
        .not_supported => {
            try writer.writeAll("Touch ID hardware not detected on this Mac.\n");
        },
        .unknown => {
            try writer.writeAll("Could not determine Touch ID status.\n");
        },
    }

    try writer.writeAll("\n");
}

// ============================================================================
// Tests
// ============================================================================

test "status display names" {
    try std.testing.expectEqualStrings("Enabled", TouchIdStatus.enabled.displayName());
    try std.testing.expectEqualStrings("Disabled", TouchIdStatus.disabled.displayName());
}
