const std = @import("std");
const fs = std.fs;
const mem = std.mem;
const Allocator = mem.Allocator;

/// Safety errors that can occur during path validation
pub const SafetyError = error{
    /// Path is in the Iron Dome blocklist (critical system path)
    IronDomeViolation,
    /// Path contains directory traversal attempts (../)
    DirectoryTraversal,
    /// Path is empty or null
    EmptyPath,
    /// Path contains control characters
    ControlCharacters,
    /// Path is not absolute (must start with /)
    NotAbsolutePath,
    /// Path is a symlink pointing outside allowed scope
    DangerousSymlink,
    /// Path resolution failed
    PathResolutionFailed,
    /// Attempted operation on root directory
    RootDirectoryOperation,
    /// Path is too long
    PathTooLong,
};

/// Maximum allowed path length
pub const MAX_PATH_LEN: usize = 4096;

/// Iron Dome: Critical system paths that must NEVER be modified
/// These paths are protected at all costs - the system will refuse any operation on them
pub const IRON_DOME_PATHS = [_][]const u8{
    // Root and core system directories
    "/",
    "/System",
    "/bin",
    "/sbin",
    "/usr",
    "/etc",
    "/var",
    "/private/etc",
    "/private/var",
    "/cores",

    // System integrity paths
    "/System/Library",
    "/System/Applications",
    "/System/Volumes",
    "/Library/Extensions",
    "/Library/Frameworks",

    // Boot and recovery
    "/System/Volumes/Data",
    "/System/Volumes/Preboot",
    "/System/Volumes/Recovery",
    "/System/Volumes/VM",

    // Critical user data that should never be bulk-deleted
    "/Users/Shared",
};

/// Paths that require extra confirmation before modification
pub const SENSITIVE_PATHS = [_][]const u8{
    "/Library",
    "/Applications",
    "/Users",
    "/opt",
    "/usr/local",
    "/private",
};

/// Protected application data (AI tools, security software, etc.)
pub const PROTECTED_APP_PATTERNS = [_][]const u8{
    "Claude",
    "Cursor",
    "ChatGPT",
    "Ollama",
    "LM Studio",
    "Tailscale",
    "1Password",
    "Keychain",
    "ssh",
    "gnupg",
    "gpg",
};

/// Vendor prefixes that indicate shared resources (don't delete orphaned data)
pub const VENDOR_PREFIXES = [_][]const u8{
    "com.adobe.",
    "com.microsoft.",
    "com.google.",
    "com.apple.",
    "org.mozilla.",
};

/// Check if a path matches any Iron Dome protected path
pub fn isIronDomePath(path: []const u8) bool {
    // Exact match check
    for (IRON_DOME_PATHS) |protected| {
        if (mem.eql(u8, path, protected)) {
            return true;
        }
    }

    // Prefix match for system directories
    const system_prefixes = [_][]const u8{
        "/System/",
        "/bin/",
        "/sbin/",
        "/usr/bin/",
        "/usr/sbin/",
        "/usr/lib/",
        "/Library/Extensions/",
        "/Library/Frameworks/",
    };

    for (system_prefixes) |prefix| {
        if (mem.startsWith(u8, path, prefix)) {
            return true;
        }
    }

    return false;
}

/// Check if path is in sensitive area requiring confirmation
pub fn isSensitivePath(path: []const u8) bool {
    for (SENSITIVE_PATHS) |sensitive| {
        if (mem.eql(u8, path, sensitive) or mem.startsWith(u8, path, sensitive ++ "/")) {
            return true;
        }
    }
    return false;
}

/// Check if path appears to be protected application data
pub fn isProtectedAppData(path: []const u8) bool {
    for (PROTECTED_APP_PATTERNS) |pattern| {
        if (mem.indexOf(u8, path, pattern) != null) {
            return true;
        }
    }
    return false;
}

/// Check if a bundle ID belongs to a major vendor (shared resources)
pub fn isVendorBundleId(bundle_id: []const u8) bool {
    for (VENDOR_PREFIXES) |prefix| {
        if (mem.startsWith(u8, bundle_id, prefix)) {
            return true;
        }
    }
    return false;
}

/// Validate a path for safety before any file operation
/// Returns the validated path or an error
pub fn validatePath(path: []const u8) SafetyError!void {
    // Check for empty path
    if (path.len == 0) {
        return SafetyError.EmptyPath;
    }

    // Check path length
    if (path.len > MAX_PATH_LEN) {
        return SafetyError.PathTooLong;
    }

    // Must be absolute path
    if (path[0] != '/') {
        return SafetyError.NotAbsolutePath;
    }

    // Check for root directory operation
    if (mem.eql(u8, path, "/")) {
        return SafetyError.RootDirectoryOperation;
    }

    // Check for control characters
    for (path) |c| {
        if (c < 32 and c != '\t') {
            return SafetyError.ControlCharacters;
        }
    }

    // Check for directory traversal attempts
    if (containsTraversal(path)) {
        return SafetyError.DirectoryTraversal;
    }

    // Check Iron Dome
    if (isIronDomePath(path)) {
        return SafetyError.IronDomeViolation;
    }
}

/// Check if path contains directory traversal sequences
fn containsTraversal(path: []const u8) bool {
    // Check for ../ or /.. or standalone ..
    var i: usize = 0;
    while (i < path.len) {
        if (i + 1 < path.len and path[i] == '.' and path[i + 1] == '.') {
            // Check if it's a real traversal (not part of filename like "foo..bar")
            const before_ok = i == 0 or path[i - 1] == '/';
            const after_ok = i + 2 >= path.len or path[i + 2] == '/';
            if (before_ok and after_ok) {
                return true;
            }
        }
        i += 1;
    }
    return false;
}

/// Normalize a path by resolving . and .. components
/// Returns error if the result would escape the starting directory
pub fn normalizePath(allocator: Allocator, path: []const u8) ![]u8 {
    if (path.len == 0) {
        return SafetyError.EmptyPath;
    }

    var components = std.ArrayList([]const u8).init(allocator);
    defer components.deinit();

    var iter = mem.splitScalar(u8, path, '/');
    while (iter.next()) |component| {
        if (component.len == 0 or mem.eql(u8, component, ".")) {
            continue;
        } else if (mem.eql(u8, component, "..")) {
            if (components.items.len > 0) {
                _ = components.pop();
            }
            // Silently ignore attempts to go above root
        } else {
            try components.append(component);
        }
    }

    // Reconstruct path
    var result = std.ArrayList(u8).init(allocator);
    errdefer result.deinit();

    for (components.items) |component| {
        try result.append('/');
        try result.appendSlice(component);
    }

    if (result.items.len == 0) {
        try result.append('/');
    }

    return result.toOwnedSlice();
}

/// Safe path joining that prevents traversal attacks
pub fn safeJoinPath(allocator: Allocator, base: []const u8, child: []const u8) ![]u8 {
    // Validate base path
    try validatePath(base);

    // Child must not be absolute or contain traversal
    if (child.len > 0 and child[0] == '/') {
        return SafetyError.NotAbsolutePath;
    }

    if (containsTraversal(child)) {
        return SafetyError.DirectoryTraversal;
    }

    // Join paths
    var result = std.ArrayList(u8).init(allocator);
    errdefer result.deinit();

    try result.appendSlice(base);
    if (base.len > 0 and base[base.len - 1] != '/') {
        try result.append('/');
    }
    try result.appendSlice(child);

    const joined = try result.toOwnedSlice();

    // Validate the result
    validatePath(joined) catch |err| {
        allocator.free(joined);
        return err;
    };

    return joined;
}

/// Check if a path is a symlink and validate its target
pub fn validateSymlink(path: []const u8) SafetyError!void {
    // First validate the path itself
    try validatePath(path);

    // Try to read the symlink target
    var buf: [MAX_PATH_LEN]u8 = undefined;
    const target = std.posix.readlink(path, &buf) catch {
        // Not a symlink or can't read - that's fine
        return;
    };

    // Validate the target doesn't point to protected areas
    if (isIronDomePath(target)) {
        return SafetyError.DangerousSymlink;
    }
}

/// Result of path safety analysis
pub const PathSafetyLevel = enum {
    /// Safe to operate on without restrictions
    safe,
    /// Requires user confirmation
    needs_confirmation,
    /// Operation should be denied
    denied,
};

/// Analyze a path and determine its safety level
pub fn analyzePathSafety(path: []const u8) PathSafetyLevel {
    // Validate first
    validatePath(path) catch {
        return .denied;
    };

    // Check for protected app data
    if (isProtectedAppData(path)) {
        return .needs_confirmation;
    }

    // Check for sensitive paths
    if (isSensitivePath(path)) {
        return .needs_confirmation;
    }

    return .safe;
}

// ============================================================================
// Unit Tests
// ============================================================================

test "Iron Dome blocks root" {
    try std.testing.expectError(SafetyError.RootDirectoryOperation, validatePath("/"));
}

test "Iron Dome blocks system paths" {
    try std.testing.expectError(SafetyError.IronDomeViolation, validatePath("/System"));
    try std.testing.expectError(SafetyError.IronDomeViolation, validatePath("/System/Library/Fonts"));
    try std.testing.expectError(SafetyError.IronDomeViolation, validatePath("/bin/bash"));
    try std.testing.expectError(SafetyError.IronDomeViolation, validatePath("/usr/bin/env"));
}

test "Iron Dome allows user paths" {
    try validatePath("/Users/testuser/Documents");
    try validatePath("/Users/testuser/Library/Caches");
    try validatePath("/tmp/test");
}

test "blocks directory traversal" {
    try std.testing.expectError(SafetyError.DirectoryTraversal, validatePath("/Users/test/../../../etc/passwd"));
    try std.testing.expectError(SafetyError.DirectoryTraversal, validatePath("/tmp/.."));
    try std.testing.expectError(SafetyError.DirectoryTraversal, validatePath("/tmp/../.."));
}

test "blocks relative paths" {
    try std.testing.expectError(SafetyError.NotAbsolutePath, validatePath("relative/path"));
    try std.testing.expectError(SafetyError.NotAbsolutePath, validatePath("./current"));
    try std.testing.expectError(SafetyError.NotAbsolutePath, validatePath("../parent"));
}

test "blocks empty paths" {
    try std.testing.expectError(SafetyError.EmptyPath, validatePath(""));
}

test "blocks control characters" {
    try std.testing.expectError(SafetyError.ControlCharacters, validatePath("/tmp/file\x00name"));
    try std.testing.expectError(SafetyError.ControlCharacters, validatePath("/tmp/file\nname"));
}

test "path normalization" {
    const allocator = std.testing.allocator;

    const result1 = try normalizePath(allocator, "/Users/test/./Documents/../Downloads");
    defer allocator.free(result1);
    try std.testing.expectEqualStrings("/Users/test/Downloads", result1);

    const result2 = try normalizePath(allocator, "/tmp/./././file");
    defer allocator.free(result2);
    try std.testing.expectEqualStrings("/tmp/file", result2);
}

test "safe path joining" {
    const allocator = std.testing.allocator;

    const result = try safeJoinPath(allocator, "/Users/test", "Documents/file.txt");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("/Users/test/Documents/file.txt", result);

    // Should reject traversal in child
    try std.testing.expectError(SafetyError.DirectoryTraversal, safeJoinPath(allocator, "/Users/test", "../etc/passwd"));

    // Should reject absolute child
    try std.testing.expectError(SafetyError.NotAbsolutePath, safeJoinPath(allocator, "/Users/test", "/etc/passwd"));
}

test "protected app detection" {
    try std.testing.expect(isProtectedAppData("/Users/test/Library/Application Support/Claude"));
    try std.testing.expect(isProtectedAppData("/Users/test/.ssh/id_rsa"));
    try std.testing.expect(!isProtectedAppData("/Users/test/Library/Caches/com.spotify.client"));
}

test "vendor bundle ID detection" {
    try std.testing.expect(isVendorBundleId("com.adobe.Photoshop"));
    try std.testing.expect(isVendorBundleId("com.microsoft.Word"));
    try std.testing.expect(isVendorBundleId("com.apple.Safari"));
    try std.testing.expect(!isVendorBundleId("com.spotify.client"));
}
