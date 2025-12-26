const std = @import("std");
const fs = std.fs;
const mem = std.mem;
const Allocator = mem.Allocator;
const process = std.process;

const file_ops = @import("../core/file_ops.zig");
const logging = @import("../core/logging.zig");

const log = logging.scoped("status");

/// CPU information
pub const CpuInfo = struct {
    model: []const u8,
    cores: u32,
    threads: u32,
    /// CPU usage percentage (0-100)
    usage: f64,
    /// Load averages (1, 5, 15 min)
    load_avg: [3]f64,
    allocator: Allocator,

    pub fn deinit(self: *CpuInfo) void {
        self.allocator.free(self.model);
    }
};

/// Memory information
pub const MemoryInfo = struct {
    /// Total physical memory in bytes
    total: u64,
    /// Used memory in bytes
    used: u64,
    /// Free memory in bytes
    free: u64,
    /// Swap total in bytes
    swap_total: u64,
    /// Swap used in bytes
    swap_used: u64,

    pub fn usagePercent(self: *const MemoryInfo) f64 {
        if (self.total == 0) return 0;
        return @as(f64, @floatFromInt(self.used)) / @as(f64, @floatFromInt(self.total)) * 100;
    }
};

/// Disk information
pub const DiskInfo = struct {
    mount_point: []const u8,
    total: u64,
    used: u64,
    free: u64,
    allocator: Allocator,

    pub fn usagePercent(self: *const DiskInfo) f64 {
        if (self.total == 0) return 0;
        return @as(f64, @floatFromInt(self.used)) / @as(f64, @floatFromInt(self.total)) * 100;
    }

    pub fn deinit(self: *DiskInfo) void {
        self.allocator.free(self.mount_point);
    }
};

/// Battery information
pub const BatteryInfo = struct {
    /// Battery level (0-100)
    level: u8,
    /// Whether charging
    is_charging: bool,
    /// Whether on AC power
    on_ac_power: bool,
    /// Cycle count
    cycle_count: u32,
    /// Health percentage
    health: u8,
};

/// Network information
pub const NetworkInfo = struct {
    interface: []const u8,
    ip_address: []const u8,
    bytes_sent: u64,
    bytes_recv: u64,
    allocator: Allocator,

    pub fn deinit(self: *NetworkInfo) void {
        self.allocator.free(self.interface);
        self.allocator.free(self.ip_address);
    }
};

/// Complete system status
pub const SystemStatus = struct {
    hostname: []const u8,
    os_version: []const u8,
    uptime_seconds: u64,
    cpu: ?CpuInfo,
    memory: MemoryInfo,
    disks: std.ArrayList(DiskInfo),
    battery: ?BatteryInfo,
    health_score: u8,
    allocator: Allocator,

    pub fn deinit(self: *SystemStatus) void {
        self.allocator.free(self.hostname);
        self.allocator.free(self.os_version);
        if (self.cpu) |*cpu| {
            cpu.deinit();
        }
        for (self.disks.items) |*disk| {
            disk.deinit();
        }
        self.disks.deinit();
    }
};

/// Collect all system metrics
pub fn collectStatus(allocator: Allocator) !SystemStatus {
    var status = SystemStatus{
        .hostname = try getHostname(allocator),
        .os_version = try getOsVersion(allocator),
        .uptime_seconds = getUptime(),
        .cpu = try getCpuInfo(allocator),
        .memory = getMemoryInfo(),
        .disks = try getDiskInfo(allocator),
        .battery = getBatteryInfo(),
        .health_score = 0,
        .allocator = allocator,
    };

    // Calculate health score
    status.health_score = calculateHealthScore(&status);

    return status;
}

/// Get hostname
fn getHostname(allocator: Allocator) ![]u8 {
    var buf: [256]u8 = undefined;

    // Try to read /etc/hostname or use uname
    const hostname_file = fs.cwd().openFile("/etc/hostname", .{}) catch {
        // Fallback
        return try allocator.dupe(u8, "localhost");
    };
    defer hostname_file.close();

    const len = hostname_file.read(&buf) catch {
        return try allocator.dupe(u8, "localhost");
    };

    // Trim newline
    var hostname = buf[0..len];
    if (hostname.len > 0 and hostname[hostname.len - 1] == '\n') {
        hostname = hostname[0 .. hostname.len - 1];
    }

    return try allocator.dupe(u8, hostname);
}

/// Get OS version
fn getOsVersion(allocator: Allocator) ![]u8 {
    // On Linux, read /etc/os-release
    const os_release = fs.cwd().openFile("/etc/os-release", .{}) catch {
        return try allocator.dupe(u8, "Unknown");
    };
    defer os_release.close();

    var buf: [4096]u8 = undefined;
    const len = os_release.read(&buf) catch {
        return try allocator.dupe(u8, "Unknown");
    };

    const content = buf[0..len];

    // Parse PRETTY_NAME
    var iter = mem.splitScalar(u8, content, '\n');
    while (iter.next()) |line| {
        if (mem.startsWith(u8, line, "PRETTY_NAME=")) {
            var value = line[12..];
            // Remove quotes
            if (value.len >= 2 and value[0] == '"') {
                value = value[1 .. value.len - 1];
            }
            return try allocator.dupe(u8, value);
        }
    }

    return try allocator.dupe(u8, "Linux");
}

/// Get system uptime in seconds
fn getUptime() u64 {
    // Read /proc/uptime
    const uptime_file = fs.cwd().openFile("/proc/uptime", .{}) catch {
        return 0;
    };
    defer uptime_file.close();

    var buf: [64]u8 = undefined;
    const len = uptime_file.read(&buf) catch return 0;

    const content = buf[0..len];
    const space_idx = mem.indexOf(u8, content, " ") orelse return 0;

    const uptime_str = content[0..space_idx];
    const uptime_float = std.fmt.parseFloat(f64, uptime_str) catch return 0;

    return @intFromFloat(uptime_float);
}

/// Get CPU information
fn getCpuInfo(allocator: Allocator) !?CpuInfo {
    // Read /proc/cpuinfo
    const cpuinfo_file = fs.cwd().openFile("/proc/cpuinfo", .{}) catch {
        return null;
    };
    defer cpuinfo_file.close();

    var buf: [16384]u8 = undefined;
    const len = cpuinfo_file.read(&buf) catch return null;
    const content = buf[0..len];

    var model: []const u8 = "Unknown";
    var cores: u32 = 0;

    var iter = mem.splitScalar(u8, content, '\n');
    while (iter.next()) |line| {
        if (mem.startsWith(u8, line, "model name")) {
            if (mem.indexOf(u8, line, ":")) |colon_idx| {
                model = mem.trim(u8, line[colon_idx + 1 ..], " \t");
            }
        } else if (mem.startsWith(u8, line, "processor")) {
            cores += 1;
        }
    }

    // Get load average
    var load_avg = [3]f64{ 0, 0, 0 };
    const loadavg_file = fs.cwd().openFile("/proc/loadavg", .{}) catch null;
    if (loadavg_file) |file| {
        defer file.close();
        var load_buf: [64]u8 = undefined;
        const load_len = file.read(&load_buf) catch 0;
        if (load_len > 0) {
            var load_iter = mem.splitScalar(u8, load_buf[0..load_len], ' ');
            var i: usize = 0;
            while (load_iter.next()) |val| {
                if (i >= 3) break;
                load_avg[i] = std.fmt.parseFloat(f64, val) catch 0;
                i += 1;
            }
        }
    }

    // Estimate CPU usage from load average
    const usage = if (cores > 0)
        @min(100.0, load_avg[0] / @as(f64, @floatFromInt(cores)) * 100)
    else
        0;

    return CpuInfo{
        .model = try allocator.dupe(u8, model),
        .cores = cores,
        .threads = cores, // Simplified
        .usage = usage,
        .load_avg = load_avg,
        .allocator = allocator,
    };
}

/// Get memory information
fn getMemoryInfo() MemoryInfo {
    var info = MemoryInfo{
        .total = 0,
        .used = 0,
        .free = 0,
        .swap_total = 0,
        .swap_used = 0,
    };

    // Read /proc/meminfo
    const meminfo_file = fs.cwd().openFile("/proc/meminfo", .{}) catch {
        return info;
    };
    defer meminfo_file.close();

    var buf: [4096]u8 = undefined;
    const len = meminfo_file.read(&buf) catch return info;
    const content = buf[0..len];

    var mem_total: u64 = 0;
    var mem_free: u64 = 0;
    var mem_available: u64 = 0;
    var swap_total: u64 = 0;
    var swap_free: u64 = 0;

    var iter = mem.splitScalar(u8, content, '\n');
    while (iter.next()) |line| {
        if (parseMemLine(line, "MemTotal:")) |val| {
            mem_total = val * 1024;
        } else if (parseMemLine(line, "MemFree:")) |val| {
            mem_free = val * 1024;
        } else if (parseMemLine(line, "MemAvailable:")) |val| {
            mem_available = val * 1024;
        } else if (parseMemLine(line, "SwapTotal:")) |val| {
            swap_total = val * 1024;
        } else if (parseMemLine(line, "SwapFree:")) |val| {
            swap_free = val * 1024;
        }
    }

    info.total = mem_total;
    info.free = if (mem_available > 0) mem_available else mem_free;
    info.used = if (mem_total > info.free) mem_total - info.free else 0;
    info.swap_total = swap_total;
    info.swap_used = if (swap_total > swap_free) swap_total - swap_free else 0;

    return info;
}

fn parseMemLine(line: []const u8, prefix: []const u8) ?u64 {
    if (!mem.startsWith(u8, line, prefix)) return null;

    const value_start = prefix.len;
    const trimmed = mem.trim(u8, line[value_start..], " \t");

    // Remove "kB" suffix if present
    const num_end = mem.indexOf(u8, trimmed, " ") orelse trimmed.len;
    const num_str = trimmed[0..num_end];

    return std.fmt.parseInt(u64, num_str, 10) catch null;
}

/// Get disk information
fn getDiskInfo(allocator: Allocator) !std.ArrayList(DiskInfo) {
    var disks = std.ArrayList(DiskInfo).init(allocator);
    errdefer {
        for (disks.items) |*disk| {
            disk.deinit();
        }
        disks.deinit();
    }

    // Read /proc/mounts
    const mounts_file = fs.cwd().openFile("/proc/mounts", .{}) catch {
        return disks;
    };
    defer mounts_file.close();

    var buf: [8192]u8 = undefined;
    const len = mounts_file.read(&buf) catch return disks;
    const content = buf[0..len];

    var iter = mem.splitScalar(u8, content, '\n');
    while (iter.next()) |line| {
        var fields = mem.splitScalar(u8, line, ' ');
        const device = fields.next() orelse continue;
        const mount_point = fields.next() orelse continue;

        // Skip non-physical filesystems
        if (!mem.startsWith(u8, device, "/dev/")) continue;
        if (mem.startsWith(u8, mount_point, "/snap")) continue;
        if (mem.startsWith(u8, mount_point, "/boot")) continue;

        // Get disk stats using statvfs equivalent
        // For now, we'll just add known mount points
        if (mem.eql(u8, mount_point, "/") or
            mem.startsWith(u8, mount_point, "/home") or
            mem.startsWith(u8, mount_point, "/Users"))
        {
            try disks.append(.{
                .mount_point = try allocator.dupe(u8, mount_point),
                .total = 0, // Would need statvfs
                .used = 0,
                .free = 0,
                .allocator = allocator,
            });
        }
    }

    return disks;
}

/// Get battery information (if available)
fn getBatteryInfo() ?BatteryInfo {
    // Check /sys/class/power_supply/BAT0
    const capacity_file = fs.cwd().openFile("/sys/class/power_supply/BAT0/capacity", .{}) catch {
        return null;
    };
    defer capacity_file.close();

    var buf: [16]u8 = undefined;
    const len = capacity_file.read(&buf) catch return null;

    const capacity_str = mem.trim(u8, buf[0..len], " \n\t");
    const capacity = std.fmt.parseInt(u8, capacity_str, 10) catch return null;

    // Check charging status
    var is_charging = false;
    const status_file = fs.cwd().openFile("/sys/class/power_supply/BAT0/status", .{}) catch null;
    if (status_file) |file| {
        defer file.close();
        var status_buf: [32]u8 = undefined;
        const status_len = file.read(&status_buf) catch 0;
        if (status_len > 0) {
            const status = mem.trim(u8, status_buf[0..status_len], " \n\t");
            is_charging = mem.eql(u8, status, "Charging");
        }
    }

    return BatteryInfo{
        .level = capacity,
        .is_charging = is_charging,
        .on_ac_power = is_charging,
        .cycle_count = 0, // Would need to read cycle_count file
        .health = 100,
    };
}

/// Calculate overall system health score (0-100)
fn calculateHealthScore(status: *const SystemStatus) u8 {
    var score: u32 = 100;

    // CPU usage penalty
    if (status.cpu) |cpu| {
        if (cpu.usage > 90) score -= 20 else if (cpu.usage > 70) score -= 10;
    }

    // Memory usage penalty
    const mem_usage = status.memory.usagePercent();
    if (mem_usage > 90) score -= 25 else if (mem_usage > 80) score -= 15 else if (mem_usage > 70) score -= 5;

    // Disk usage penalty
    for (status.disks.items) |disk| {
        const disk_usage = disk.usagePercent();
        if (disk_usage > 95) score -= 20 else if (disk_usage > 90) score -= 10 else if (disk_usage > 80) score -= 5;
    }

    // Battery health
    if (status.battery) |battery| {
        if (battery.level < 10 and !battery.is_charging) score -= 15;
    }

    return @intCast(@max(0, @min(100, score)));
}

/// Format uptime as human readable
pub fn formatUptime(seconds: u64) struct { days: u64, hours: u64, mins: u64 } {
    const days = seconds / 86400;
    const hours = (seconds % 86400) / 3600;
    const mins = (seconds % 3600) / 60;
    return .{ .days = days, .hours = hours, .mins = mins };
}

/// Print system status
pub fn printStatus(status: *const SystemStatus, writer: anytype) !void {
    try writer.writeAll("\n══════════════════════════════════════════════════════\n");
    try writer.writeAll("               SYSTEM STATUS\n");
    try writer.writeAll("══════════════════════════════════════════════════════\n\n");

    // Basic info
    try writer.print("Hostname:    {s}\n", .{status.hostname});
    try writer.print("OS:          {s}\n", .{status.os_version});

    const uptime = formatUptime(status.uptime_seconds);
    try writer.print("Uptime:      {d}d {d}h {d}m\n", .{ uptime.days, uptime.hours, uptime.mins });
    try writer.writeAll("\n");

    // CPU
    if (status.cpu) |cpu| {
        try writer.writeAll("CPU:\n");
        try writer.print("  Model:     {s}\n", .{truncate(cpu.model, 40)});
        try writer.print("  Cores:     {d}\n", .{cpu.cores});
        try writer.print("  Load Avg:  {d:.2}, {d:.2}, {d:.2}\n", .{
            cpu.load_avg[0],
            cpu.load_avg[1],
            cpu.load_avg[2],
        });
        try writer.print("  Usage:     ", .{});
        try printBar(writer, cpu.usage, 30);
        try writer.print(" {d:.1}%\n\n", .{cpu.usage});
    }

    // Memory
    try writer.writeAll("Memory:\n");
    const mem_used_fmt = file_ops.formatBytes(status.memory.used);
    const mem_total_fmt = file_ops.formatBytes(status.memory.total);
    try writer.print("  Used:      {d:.2} {s} / {d:.2} {s}\n", .{
        mem_used_fmt.value,
        mem_used_fmt.unit,
        mem_total_fmt.value,
        mem_total_fmt.unit,
    });
    try writer.print("  Usage:     ", .{});
    try printBar(writer, status.memory.usagePercent(), 30);
    try writer.print(" {d:.1}%\n", .{status.memory.usagePercent()});

    if (status.memory.swap_total > 0) {
        const swap_used_fmt = file_ops.formatBytes(status.memory.swap_used);
        const swap_total_fmt = file_ops.formatBytes(status.memory.swap_total);
        try writer.print("  Swap:      {d:.2} {s} / {d:.2} {s}\n", .{
            swap_used_fmt.value,
            swap_used_fmt.unit,
            swap_total_fmt.value,
            swap_total_fmt.unit,
        });
    }
    try writer.writeAll("\n");

    // Disks
    if (status.disks.items.len > 0) {
        try writer.writeAll("Disks:\n");
        for (status.disks.items) |disk| {
            try writer.print("  {s}:\n", .{disk.mount_point});
            const disk_used_fmt = file_ops.formatBytes(disk.used);
            const disk_total_fmt = file_ops.formatBytes(disk.total);
            try writer.print("    {d:.2} {s} / {d:.2} {s} ", .{
                disk_used_fmt.value,
                disk_used_fmt.unit,
                disk_total_fmt.value,
                disk_total_fmt.unit,
            });
            try printBar(writer, disk.usagePercent(), 20);
            try writer.print(" {d:.1}%\n", .{disk.usagePercent()});
        }
        try writer.writeAll("\n");
    }

    // Battery
    if (status.battery) |battery| {
        try writer.writeAll("Battery:\n");
        const charge_status = if (battery.is_charging) "Charging" else "Discharging";
        try writer.print("  Level:     {d}% ({s})\n", .{ battery.level, charge_status });
        try writer.print("  Status:    ", .{});
        try printBar(writer, @floatFromInt(battery.level), 30);
        try writer.writeAll("\n\n");
    }

    // Health Score
    try writer.writeAll("─────────────────────────────────────────────────────\n");
    const health_emoji = if (status.health_score >= 80) "✅" else if (status.health_score >= 60) "⚠️ " else "❌";
    try writer.print("Health Score: {s} {d}/100\n", .{ health_emoji, status.health_score });
    try writer.writeAll("══════════════════════════════════════════════════════\n\n");
}

fn printBar(writer: anytype, percent: f64, width: usize) !void {
    const filled = @as(usize, @intFromFloat(@min(100.0, @max(0.0, percent)) / 100.0 * @as(f64, @floatFromInt(width))));
    try writer.writeAll("[");
    var i: usize = 0;
    while (i < width) : (i += 1) {
        if (i < filled) {
            // Color based on usage
            if (percent > 90) {
                try writer.writeAll("█"); // Would be red in real terminal
            } else if (percent > 70) {
                try writer.writeAll("█"); // Would be yellow
            } else {
                try writer.writeAll("█"); // Would be green
            }
        } else {
            try writer.writeAll("░");
        }
    }
    try writer.writeAll("]");
}

fn truncate(s: []const u8, max: usize) []const u8 {
    if (s.len <= max) return s;
    return s[0..max];
}

// ============================================================================
// Tests
// ============================================================================

test "format uptime" {
    const result = formatUptime(90061); // 1 day, 1 hour, 1 minute, 1 second
    try std.testing.expectEqual(@as(u64, 1), result.days);
    try std.testing.expectEqual(@as(u64, 1), result.hours);
    try std.testing.expectEqual(@as(u64, 1), result.mins);
}

test "memory usage percent" {
    const info = MemoryInfo{
        .total = 1000,
        .used = 250,
        .free = 750,
        .swap_total = 0,
        .swap_used = 0,
    };
    try std.testing.expectEqual(@as(f64, 25.0), info.usagePercent());
}
