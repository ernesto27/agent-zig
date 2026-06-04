const std = @import("std");

const log = std.log.scoped(.sandbox);

pub const Result = struct {
    content: []const u8,
    is_error: bool = false,
};

/// A Docker container bound to a per-run git worktree (a new branch under
/// ~/.config/agent-zig/worktrees) bind-mounted at /workspace.
///
/// The agent loop stays on the host; only tool *actions* are shipped in here via
/// `docker exec`. Only the throwaway worktree is bind-mounted, so the main repo
/// checkout is never exposed. The container is created with `--rm`, so stopping it
/// auto-removes it; the worktree (and its branch) is kept for review/merge.
pub const Sandbox = struct {
    active: bool = false,
    /// Container name; also the `docker exec` target. Owned by `alloc`.
    name: []const u8 = "",
    /// Absolute host repo root, used to remap absolute paths to /workspace.
    /// Owned by `alloc`.
    host_root: []const u8 = "",
    /// Absolute path of the per-run worktree (under ~/.agents). Owned by `alloc`.
    worktree_path: []const u8 = "",
    /// Branch name checked out in the worktree. Owned by `alloc`.
    branch: []const u8 = "",
    workdir: []const u8 = "/workspace",

    const Self = @This();

    /// Launch a detached, auto-removing container off `image` and copy the
    /// contents of `repo_path` into /workspace (no bind mount → host untouched).
    /// Sets `active = true` on success; on error nothing is left running.
    pub fn start(self: *Self, alloc: std.mem.Allocator, image: []const u8, repo_path: []const u8) !void {
        const home = std.posix.getenv("HOME") orelse return error.NoHomeEnv;
        const repo = std.fs.path.basename(repo_path);
        const ts = std.time.timestamp();

        // 1) create the worktree on a NEW branch off HEAD, under
        //    ~/.config/agent-zig/worktrees/<repo> (alongside the app's config).
        //    Flat branch name (no slash) so it can't collide with an existing
        //    branch like "sandbox" via a git ref directory/file conflict.
        const parent = try std.fmt.allocPrint(alloc, "{s}/.config/agent-zig/worktrees/{s}", .{ home, repo });
        defer alloc.free(parent);
        std.fs.cwd().makePath(parent) catch |err| {
            log.err("makePath {s} failed: {}", .{ parent, err });
            return error.WorktreeSetupFailed;
        };

        const wt = try std.fmt.allocPrint(alloc, "{s}/sandbox-{d}", .{ parent, ts });
        errdefer alloc.free(wt);
        const branch = try std.fmt.allocPrint(alloc, "sandbox-{d}", .{ts});
        errdefer alloc.free(branch);

        try checked(alloc, &.{ "git", "-C", repo_path, "worktree", "add", wt, "-b", branch }, error.WorktreeAddFailed);
        errdefer runQuiet(alloc, &.{ "git", "-C", repo_path, "worktree", "remove", "--force", wt });

        // 2) launch a detached, auto-removing container with the worktree
        //    bind-mounted at /workspace ('tail -f /dev/null' keeps it alive).
        //    Only the throwaway worktree is exposed — the main repo is not.
        // pid + timestamp → unique per run, so a stale container left by a crash
        // (still running, since --rm only fires on stop) never collides on name.
        const name = try std.fmt.allocPrint(alloc, "agent-zig-sbx-{d}-{d}", .{ std.os.linux.getpid(), ts });
        errdefer alloc.free(name);

        const mount = try std.fmt.allocPrint(alloc, "{s}:{s}", .{ wt, self.workdir });
        defer alloc.free(mount);
        try checked(alloc, &.{ "docker", "run", "--rm", "-d", "--name", name, "-v", mount, "-w", self.workdir, image, "tail", "-f", "/dev/null" }, error.DockerRunFailed);
        errdefer runQuiet(alloc, &.{ "docker", "rm", "-f", name });

        const root = try alloc.dupe(u8, repo_path);
        errdefer alloc.free(root);

        self.name = name;
        self.host_root = root;
        self.worktree_path = wt;
        self.branch = branch;
        self.active = true;
        log.info("sandbox up: {s} ({s}) wt={s} branch={s}", .{ name, image, wt, branch });
    }

    /// Stop the container (the worktree/branch is kept under ~/.agents). The
    /// container runs as root, so first hand the worktree files back to the host
    /// user. With `--rm`, `docker stop` also removes the container. Best-effort.
    pub fn stop(self: *Self, alloc: std.mem.Allocator) void {
        if (!self.active) return;
        if (std.fmt.allocPrint(alloc, "{d}:{d}", .{ std.os.linux.getuid(), std.os.linux.getgid() })) |owner| {
            runQuiet(alloc, &.{ "docker", "exec", self.name, "chown", "-R", owner, self.workdir });
            alloc.free(owner);
        } else |_| {}
        runQuiet(alloc, &.{ "docker", "stop", self.name });
        alloc.free(self.name);
        alloc.free(self.host_root);
        alloc.free(self.worktree_path);
        alloc.free(self.branch);
        self.* = .{};
    }

    /// Map a tool-supplied path to one relative to /workspace: strip the host
    /// repo root (the tool schemas tell the model to use absolute paths) plus any
    /// leading "./" or "/". Returns a sub-slice of `path` (no allocation).
    pub fn rel(self: *const Self, path: []const u8) []const u8 {
        var p = path;
        if (self.host_root.len > 0 and std.mem.startsWith(u8, p, self.host_root)) {
            p = p[self.host_root.len..];
        }
        if (std.mem.startsWith(u8, p, "./")) p = p[2..];
        while (p.len > 0 and p[0] == '/') p = p[1..];
        return if (p.len == 0) "." else p;
    }

    /// Run a shell command string inside the container (the `bash` tool).
    pub fn execShell(self: *const Self, alloc: std.mem.Allocator, command: []const u8) Result {
        return self.runArgv(alloc, &.{ "/bin/sh", "-c", command });
    }

    /// Run an explicit argv inside the container (no shell ⇒ no quoting traps).
    /// Mirrors tools.runBash output handling, with a `docker exec` prefix.
    pub fn runArgv(self: *const Self, alloc: std.mem.Allocator, argv: []const []const u8) Result {
        var full = std.ArrayList([]const u8){};
        defer full.deinit(alloc);
        full.appendSlice(alloc, &.{ "docker", "exec", "-w", self.workdir, self.name }) catch return oom();
        full.appendSlice(alloc, argv) catch return oom();

        const r = std.process.Child.run(.{
            .allocator = alloc,
            .argv = full.items,
            .max_output_bytes = 256 * 1024,
        }) catch |err| {
            const msg = std.fmt.allocPrint(alloc, "docker exec failed: {s}", .{@errorName(err)}) catch
                return .{ .content = "docker exec failed", .is_error = true };
            return .{ .content = msg, .is_error = true };
        };
        defer alloc.free(r.stdout);
        defer alloc.free(r.stderr);

        const code: u8 = switch (r.term) {
            .Exited => |c| c,
            else => 1,
        };
        const out = if (r.stderr.len == 0)
            alloc.dupe(u8, r.stdout) catch return oom()
        else
            std.mem.concat(alloc, u8, &.{ r.stdout, "\n[stderr]\n", r.stderr }) catch return oom();
        return .{ .content = out, .is_error = code != 0 };
    }

    /// Write `content` to `rel_path` (relative to /workspace) by piping it to the
    /// container's stdin — keeps arbitrary file bytes out of argv.
    pub fn writeFile(self: *const Self, alloc: std.mem.Allocator, rel_path: []const u8, content: []const u8) Result {
        // $1 = rel_path, passed as an argv arg so it needs no shell escaping.
        const script = "mkdir -p \"$(dirname \"$1\")\" && cat > \"$1\"";
        var child = std.process.Child.init(&.{
            "docker", "exec", "-i", "-w", self.workdir, self.name,
            "/bin/sh", "-c",     script,        "sh",     rel_path,
        }, alloc);
        child.stdin_behavior = .Pipe;
        child.stdout_behavior = .Ignore;
        child.stderr_behavior = .Ignore;

        child.spawn() catch |err| {
            const msg = std.fmt.allocPrint(alloc, "docker exec (write) spawn failed: {s}", .{@errorName(err)}) catch
                return .{ .content = "docker exec write failed", .is_error = true };
            return .{ .content = msg, .is_error = true };
        };

        if (child.stdin) |stdin| {
            stdin.writeAll(content) catch {};
            stdin.close();
            child.stdin = null;
        }

        const term = child.wait() catch |err| {
            const msg = std.fmt.allocPrint(alloc, "docker exec (write) failed: {s}", .{@errorName(err)}) catch
                return .{ .content = "docker exec write failed", .is_error = true };
            return .{ .content = msg, .is_error = true };
        };
        const code: u8 = switch (term) {
            .Exited => |c| c,
            else => 1,
        };
        if (code != 0) {
            const msg = std.fmt.allocPrint(alloc, "write failed in container (exit {d})", .{code}) catch
                return .{ .content = "write failed in container", .is_error = true };
            return .{ .content = msg, .is_error = true };
        }
        const ok = std.fmt.allocPrint(alloc, "Successfully wrote {d} bytes to {s}", .{ content.len, rel_path }) catch
            return .{ .content = "File written" };
        return .{ .content = ok };
    }
};

fn oom() Result {
    return .{ .content = "Out of memory", .is_error = true };
}

/// Run a docker command and return `e` if it exits non-zero.
fn checked(alloc: std.mem.Allocator, argv: []const []const u8, e: anyerror) !void {
    const r = try std.process.Child.run(.{ .allocator = alloc, .argv = argv, .max_output_bytes = 64 * 1024 });
    defer alloc.free(r.stdout);
    defer alloc.free(r.stderr);
    const code: u8 = switch (r.term) {
        .Exited => |c| c,
        else => 1,
    };
    if (code != 0) {
        log.err("{s} failed (exit {d}): {s}", .{ argv[0], code, r.stderr });
        return e;
    }
}

/// Best-effort docker command; ignores output and failures.
fn runQuiet(alloc: std.mem.Allocator, argv: []const []const u8) void {
    const r = std.process.Child.run(.{ .allocator = alloc, .argv = argv, .max_output_bytes = 16 * 1024 }) catch return;
    alloc.free(r.stdout);
    alloc.free(r.stderr);
}
