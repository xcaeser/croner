//! Croner command line daemon.
//!
//! The command line layer deliberately keeps its state on disk only for the
//! daemon endpoint and log.  Job definitions and pause state live in memory.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const builtin = @import("builtin");

const libcron = @import("libcron");
const zli = @import("zli");

const schema_url = "https://xcaeser.github.io/croner/croner.schema.json";
const max_config_bytes = 1024 * 1024;
const max_message_bytes = 1024 * 1024;
const unix_socket_path_max = if (builtin.os.tag == .macos) 104 else Io.net.UnixAddress.max_len;
const control_io_timeout: Io.Clock.Duration = .{ .clock = .awake, .raw = .fromSeconds(5) };

var signal_write_fd = std.atomic.Value(std.posix.fd_t).init(-1);

fn signalHandler(_: std.posix.SIG) callconv(.c) void {
    const fd = signal_write_fd.load(.monotonic);
    if (fd >= 0) {
        var byte = [_]u8{1};
        _ = std.posix.system.write(fd, &byte, 1);
    }
}

fn installSignalHandlers() void {
    const action: std.posix.Sigaction = .{
        .handler = .{ .handler = signalHandler },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(.INT, &action, null);
    std.posix.sigaction(.TERM, &action, null);
}

const EnvJson = std.json.ArrayHashMap([]const u8);

const CommandJson = struct {
    argv: []const []const u8,
    cwd: ?[]const u8 = null,
    env: ?EnvJson = null,
};

const ActionJson = struct {
    command: CommandJson,
};

const JobJson = struct {
    id: []const u8,
    schedule: []const u8,
    action: ActionJson,
    overlap: libcron.OverlapPolicy = .skip,
};

const ConfigJson = struct {
    @"$schema": ?[]const u8 = null,
    jobs: []const JobJson,
};

const EnvPair = struct { key: []const u8, value: []const u8 };

const JobSpec = struct {
    arena: ?std.heap.ArenaAllocator,
    id: []const u8,
    schedule: []const u8,
    expression: libcron.Expression,
    argv: []const []const u8,
    cwd: []const u8,
    env: []const EnvPair,
    overlap: libcron.OverlapPolicy,

    fn init(gpa: Allocator, job: JobJson, config_dir: []const u8) !JobSpec {
        var arena = std.heap.ArenaAllocator.init(gpa);
        errdefer arena.deinit();
        const a = arena.allocator();
        if (job.id.len == 0 or std.mem.indexOfScalar(u8, job.id, 0) != null) return error.InvalidJobId;
        const schedule = try a.dupe(u8, job.schedule);
        const expression = libcron.Expression.parse(schedule) catch return error.InvalidSchedule;
        const command = job.action.command;
        if (command.argv.len == 0) return error.InvalidCommand;
        const argv = try a.alloc([]const u8, command.argv.len);
        for (command.argv, 0..) |arg, i| {
            if (arg.len == 0 or std.mem.indexOfScalar(u8, arg, 0) != null) return error.InvalidCommand;
            argv[i] = try a.dupe(u8, arg);
        }

        const cwd_source = command.cwd orelse config_dir;
        if (cwd_source.len == 0 or std.mem.indexOfScalar(u8, cwd_source, 0) != null) return error.InvalidCwd;
        const cwd = if (std.fs.path.isAbsolute(cwd_source))
            try a.dupe(u8, cwd_source)
        else
            try std.fs.path.resolve(a, &.{ config_dir, cwd_source });

        const env_len = if (command.env) |env| env.map.count() else 0;
        const env = try a.alloc(EnvPair, env_len);
        if (command.env) |json_env| {
            var it = json_env.map.iterator();
            var i: usize = 0;
            while (it.next()) |entry| {
                if (!validEnvName(entry.key_ptr.*) or std.mem.indexOfScalar(u8, entry.value_ptr.*, 0) != null)
                    return error.InvalidEnvironment;
                env[i] = .{
                    .key = try a.dupe(u8, entry.key_ptr.*),
                    .value = try a.dupe(u8, entry.value_ptr.*),
                };
                i += 1;
            }
        }
        std.sort.insertion(EnvPair, env, {}, struct {
            fn lessThan(_: void, lhs: EnvPair, rhs: EnvPair) bool {
                return std.mem.order(u8, lhs.key, rhs.key) == .lt;
            }
        }.lessThan);
        const id = try a.dupe(u8, job.id);

        return .{
            .arena = arena,
            .id = id,
            .schedule = schedule,
            .expression = expression,
            .argv = argv,
            .cwd = cwd,
            .env = env,
            .overlap = job.overlap,
        };
    }

    fn deinit(self: *JobSpec) void {
        if (self.arena) |*arena| arena.deinit();
        self.* = undefined;
    }

    fn eql(lhs: *const JobSpec, rhs: *const JobSpec) bool {
        if (!std.mem.eql(u8, lhs.schedule, rhs.schedule) or
            !std.mem.eql(u8, lhs.cwd, rhs.cwd) or lhs.overlap != rhs.overlap or
            lhs.argv.len != rhs.argv.len or lhs.env.len != rhs.env.len) return false;
        for (lhs.argv, rhs.argv) |a, b| if (!std.mem.eql(u8, a, b)) return false;
        for (lhs.env, rhs.env) |a, b| {
            if (!std.mem.eql(u8, a.key, b.key) or !std.mem.eql(u8, a.value, b.value)) return false;
        }
        return true;
    }

    fn move(self: *JobSpec) JobSpec {
        const result = self.*;
        self.arena = null;
        return result;
    }
};

fn validEnvName(name: []const u8) bool {
    if (name.len == 0 or !(std.ascii.isAlphabetic(name[0]) or name[0] == '_')) return false;
    for (name[1..]) |c| if (!(std.ascii.isAlphanumeric(c) or c == '_')) return false;
    return true;
}

const LoadedSpecs = struct {
    allocator: Allocator,
    items: std.ArrayList(JobSpec),

    fn deinit(self: *LoadedSpecs) void {
        for (self.items.items) |*item| item.deinit();
        self.items.deinit(self.allocator);
    }
};

fn parseConfig(allocator: Allocator, bytes: []const u8, config_dir: []const u8) !LoadedSpecs {
    if (bytes.len > max_config_bytes) return error.ConfigTooLarge;
    var parsed = std.json.parseFromSlice(ConfigJson, allocator, bytes, .{
        .allocate = .alloc_always,
        .duplicate_field_behavior = .@"error",
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidConfig,
    };
    defer parsed.deinit();
    if (parsed.value.@"$schema") |source| {
        if (!std.mem.eql(u8, source, schema_url)) return error.InvalidSchema;
    }

    var result: LoadedSpecs = .{ .allocator = allocator, .items = .empty };
    errdefer result.deinit();
    try result.items.ensureTotalCapacity(allocator, parsed.value.jobs.len);
    var ids = std.StringHashMap(void).init(allocator);
    defer ids.deinit();
    try ids.ensureTotalCapacity(@intCast(parsed.value.jobs.len));
    for (parsed.value.jobs) |job| {
        if ((ids.getOrPutAssumeCapacity(job.id)).found_existing) return error.DuplicateJobId;
        var spec = try JobSpec.init(allocator, job, config_dir);
        errdefer spec.deinit();
        result.items.appendAssumeCapacity(spec.move());
    }
    return result;
}

fn loadConfig(allocator: Allocator, io: Io, path: []const u8) !LoadedSpecs {
    const bytes = try Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(max_config_bytes));
    defer allocator.free(bytes);
    const config_dir = std.fs.path.dirname(path) orelse ".";
    return parseConfig(allocator, bytes, config_dir);
}

fn resolveFromCwd(allocator: Allocator, io: Io, path: []const u8) ![]u8 {
    if (std.fs.path.isAbsolute(path)) return std.fs.path.resolve(allocator, &.{path});
    const cwd = try std.process.currentPathAlloc(io, allocator);
    defer allocator.free(cwd);
    return std.fs.path.resolve(allocator, &.{ cwd, path });
}

const StatePaths = struct {
    allocator: Allocator,
    root: []const u8,
    socket: []const u8,
    lock: []const u8,
    log: []const u8,

    fn init(allocator: Allocator, io: Io, config_path: []const u8) !StatePaths {
        const abs = try resolveFromCwd(allocator, io, config_path);
        defer allocator.free(abs);
        const dir = std.fs.path.dirname(abs) orelse return error.InvalidConfigPath;
        const key = std.hash.Wyhash.hash(0, abs);
        const key_text = try std.fmt.allocPrint(allocator, "{x}", .{key});
        defer allocator.free(key_text);
        const root = try std.fs.path.join(allocator, &.{ dir, ".croner", key_text });
        errdefer allocator.free(root);
        const socket = try std.fs.path.join(allocator, &.{ root, "s" });
        errdefer allocator.free(socket);
        if (socket.len > unix_socket_path_max) return error.NameTooLong;
        const lock = try std.fs.path.join(allocator, &.{ root, "daemon.lock" });
        errdefer allocator.free(lock);
        const log = try std.fs.path.join(allocator, &.{ root, "croner.log" });
        return .{ .allocator = allocator, .root = root, .socket = socket, .lock = lock, .log = log };
    }

    fn deinit(self: *StatePaths) void {
        self.allocator.free(self.root);
        self.allocator.free(self.socket);
        self.allocator.free(self.lock);
        self.allocator.free(self.log);
        self.* = undefined;
    }

    fn ensure(self: *const StatePaths, io: Io) !void {
        const cwd = Io.Dir.cwd();
        _ = try cwd.createDirPathStatus(io, self.root, .fromMode(0o700));
        const parent_path = std.fs.path.dirname(self.root) orelse return error.InvalidStatePath;
        var parent = try Io.Dir.openDirAbsolute(io, parent_path, .{});
        defer parent.close(io);
        try parent.setPermissions(io, .fromMode(0o700));
        var dir = try Io.Dir.openDirAbsolute(io, self.root, .{});
        defer dir.close(io);
        try dir.setPermissions(io, .fromMode(0o700));
        const ignore_path = try std.fs.path.join(self.allocator, &.{ std.fs.path.dirname(self.root) orelse ".", ".gitignore" });
        defer self.allocator.free(ignore_path);
        cwd.writeFile(io, .{
            .sub_path = ignore_path,
            .data = "*\n",
            .flags = .{ .exclusive = true, .permissions = .fromMode(0o600) },
        }) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
    }
};

const Request = union(enum) {
    ping,
    list,
    start: []const u8,
    stop: []const u8,
    reload,
    shutdown,
};

const JobStatus = struct { id: []const u8, schedule: []const u8, status: Status };
const Status = enum(u8) { active, paused, offline };
const Response = union(enum) {
    pid: u64,
    ok: []const u8,
    jobs: []const JobStatus,
    @"error": []const u8,
};

const App = struct {
    allocator: Allocator,
    io: Io,
};

fn appFor(ctx: zli.CommandContext) *App {
    return ctx.getContextData(App);
}

fn printResponse(ctx: zli.CommandContext, parsed: *const std.json.Parsed(Response)) !void {
    switch (parsed.value) {
        .pid => return error.InvalidResponse,
        .ok => |message| try ctx.writer.print("{s}\n", .{message}),
        .@"error" => |message| {
            try ctx.writer.print("error: {s}\n", .{message});
            return error.DaemonError;
        },
        .jobs => |jobs| {
            try ctx.writer.print("ID\tSTATUS\tSCHEDULE\n", .{});
            for (jobs) |job| try ctx.writer.print("{s}\t{t}\t{s}\n", .{ job.id, job.status, job.schedule });
        },
    }
}

fn commandSetup(ctx: zli.CommandContext) !void {
    const app = appFor(ctx);
    const config_path = ctx.flag("config", []const u8);
    const existing = Io.Dir.cwd().openFile(app.io, config_path, .{}) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    if (existing) |file| {
        file.close(app.io);
        return error.ConfigAlreadyExists;
    }

    const id = try prompt(ctx, "Job id: ");
    const schedule = try prompt(ctx, "Schedule: ");
    const argv_text = try prompt(ctx, "Command argv (JSON array): ");
    defer app.allocator.free(id);
    defer app.allocator.free(schedule);
    defer app.allocator.free(argv_text);
    var argv_parsed = std.json.parseFromSlice([]const []const u8, app.allocator, argv_text, .{
        .allocate = .alloc_always,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidCommand,
    };
    defer argv_parsed.deinit();
    const command = CommandJson{ .argv = argv_parsed.value };
    const job = JobJson{ .id = id, .schedule = schedule, .action = .{ .command = command } };
    const config = ConfigJson{ .@"$schema" = schema_url, .jobs = &.{job} };
    const config_dir = std.fs.path.dirname(config_path) orelse ".";
    var checked = try JobSpec.init(app.allocator, job, config_dir);
    checked.deinit();
    const bytes = try jsonWrite(ConfigJson, config, app.allocator);
    defer app.allocator.free(bytes);
    try Io.Dir.cwd().writeFile(app.io, .{
        .sub_path = config_path,
        .data = bytes,
        .flags = .{ .exclusive = true, .permissions = .fromMode(0o600) },
    });
    try ctx.writer.print("created {s}\n", .{config_path});
}

fn prompt(ctx: zli.CommandContext, text: []const u8) ![]const u8 {
    try ctx.writer.print("{s}", .{text});
    try ctx.writer.flush();
    const line = ctx.reader.takeDelimiterInclusive('\n') catch return error.InvalidInput;
    var end = line.len;
    while (end > 0 and (line[end - 1] == '\n' or line[end - 1] == '\r')) end -= 1;
    return ctx.allocator.dupe(u8, line[0..end]);
}

fn commandStart(ctx: zli.CommandContext) !void {
    const app = appFor(ctx);
    const config_path = ctx.flag("config", []const u8);
    if (ctx.getArg("id")) |id| {
        var state = try StatePaths.init(app.allocator, app.io, config_path);
        defer state.deinit();
        var response = try request(app.allocator, app.io, &state, .{ .start = id });
        defer response.deinit();
        return printResponse(ctx, &response);
    }
    try startBackground(app, config_path, ctx.writer);
}

fn commandStop(ctx: zli.CommandContext) !void {
    const app = appFor(ctx);
    const config_path = ctx.flag("config", []const u8);
    var state = try StatePaths.init(app.allocator, app.io, config_path);
    defer state.deinit();
    const message: Request = if (ctx.getArg("id")) |id| .{ .stop = id } else .shutdown;
    var response = try request(app.allocator, app.io, &state, message);
    defer response.deinit();
    try printResponse(ctx, &response);
}

fn commandReload(ctx: zli.CommandContext) !void {
    const app = appFor(ctx);
    var state = try StatePaths.init(app.allocator, app.io, ctx.flag("config", []const u8));
    defer state.deinit();
    var response = try request(app.allocator, app.io, &state, .reload);
    defer response.deinit();
    try printResponse(ctx, &response);
}

fn commandList(ctx: zli.CommandContext) !void {
    const app = appFor(ctx);
    const config_path = ctx.flag("config", []const u8);
    var state = try StatePaths.init(app.allocator, app.io, config_path);
    defer state.deinit();
    var response = request(app.allocator, app.io, &state, .list) catch |err| switch (err) {
        error.ConnectionRefused, error.FileNotFound => return printOffline(ctx, app, config_path),
        else => return err,
    };
    defer response.deinit();
    try printResponse(ctx, &response);
}

fn printOffline(ctx: zli.CommandContext, app: *App, config_path: []const u8) !void {
    const absolute = try resolveFromCwd(app.allocator, app.io, config_path);
    defer app.allocator.free(absolute);
    var specs = try loadConfig(app.allocator, app.io, absolute);
    defer specs.deinit();
    try ctx.writer.print("ID\tSTATUS\tSCHEDULE\n", .{});
    for (specs.items.items) |spec| try ctx.writer.print("{s}\t{t}\t{s}\n", .{ spec.id, Status.offline, spec.schedule });
}

fn commandLogs(ctx: zli.CommandContext) !void {
    const app = appFor(ctx);
    var state = try StatePaths.init(app.allocator, app.io, ctx.flag("config", []const u8));
    defer state.deinit();
    const line_count = ctx.flag("lines", i32);
    if (line_count < 0) return error.InvalidLines;
    const lines: usize = @intCast(line_count);
    var offset = try printLog(app, ctx.writer, state.log, lines);
    if (ctx.flag("follow", bool)) {
        while (true) {
            try Io.sleep(app.io, .fromMilliseconds(250), .awake);
            offset = try appendLog(app.io, ctx.writer, state.log, offset);
        }
    }
}

fn startBackground(app: *App, config_path: []const u8, writer: *Io.Writer) !void {
    const absolute = try resolveFromCwd(app.allocator, app.io, config_path);
    defer app.allocator.free(absolute);
    const dir = std.fs.path.dirname(absolute) orelse ".";
    var specs = try loadConfig(app.allocator, app.io, absolute);
    specs.deinit();
    var state = try StatePaths.init(app.allocator, app.io, absolute);
    defer state.deinit();
    try state.ensure(app.io);
    if (try daemonSocketAvailable(app.io, &state)) return error.AlreadyRunning;

    var log = Io.Dir.cwd().createFile(app.io, state.log, .{
        .read = true,
        .truncate = false,
        .permissions = .fromMode(0o600),
    }) catch |err| switch (err) {
        error.FileNotFound => blk: {
            const parent = std.fs.path.dirname(state.log) orelse return err;
            _ = try Io.Dir.cwd().createDirPathStatus(app.io, parent, .fromMode(0o700));
            break :blk try Io.Dir.cwd().createFile(app.io, state.log, .{
                .read = true,
                .truncate = false,
                .permissions = .fromMode(0o600),
            });
        },
        else => return err,
    };
    defer log.close(app.io);
    try log.setPermissions(app.io, .fromMode(0o600));
    const log_size = (try log.stat(app.io)).size;
    var log_buffer: [1]u8 = undefined;
    var log_writer = Io.File.Writer.initStreaming(log, app.io, &log_buffer);
    try log_writer.seekTo(log_size);
    const executable = try std.process.executablePathAlloc(app.io, app.allocator);
    defer app.allocator.free(executable);
    const argv = [_][]const u8{ executable, "_serve", absolute };
    var child = try std.process.spawn(app.io, .{
        .argv = &argv,
        .cwd = .{ .path = dir },
        .stdin = .ignore,
        .stdout = .{ .file = log },
        .stderr = .{ .file = log },
    });
    var started = false;
    var child_owned = true;
    errdefer if (!started and child_owned) child.kill(app.io);
    // The CLI is POSIX-only and this child owns no pipe handles. Waiting on a
    // copy keeps the original PID available for cleanup after cancellation.
    var wait_child = child;
    const StartEvent = union(enum) {
        ready: anyerror!void,
        child: anyerror!std.process.Child.Term,
        timeout: anyerror!void,
    };
    var events: [3]StartEvent = undefined;
    var select: Io.Select(StartEvent) = .init(app.io, &events);
    try select.concurrent(.ready, waitForDaemon, .{
        app.allocator,
        app.io,
        &state,
        @as(u64, @intCast(child.id.?)),
    });
    defer {
        if (started) {
            select.cancelDiscard();
        } else {
            while (select.cancel()) |event| switch (event) {
                .child => |result| if (result) |_| {
                    child_owned = false;
                } else |_| {},
                else => {},
            };
        }
    }
    try select.concurrent(.child, std.process.Child.wait, .{ &wait_child, app.io });
    try select.concurrent(.timeout, Io.sleep, .{ app.io, control_io_timeout.raw, control_io_timeout.clock });
    switch (try select.await()) {
        .ready => |result| {
            try result;
            started = true;
        },
        .child => |result| {
            _ = try result;
            child_owned = false;
            return error.DaemonStartFailed;
        },
        .timeout => |result| {
            try result;
            return error.DaemonStartFailed;
        },
    }
    try writer.print("started\nlog: {s}\n", .{state.log});
}

fn printLog(app: *App, writer: *Io.Writer, path: []const u8, lines: usize) !u64 {
    const file = Io.Dir.cwd().openFile(app.io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return 0,
        else => return err,
    };
    defer file.close(app.io);
    const size = (try file.stat(app.io)).size;
    const start = try tailOffset(file, app.io, size, lines);
    return writeLogRange(file, app.io, writer, start, size);
}

fn tailOffset(file: Io.File, io: Io, size: u64, lines: usize) !u64 {
    if (lines == 0 or size == 0) return size;
    var buffer: [8192]u8 = undefined;
    var remaining = lines;
    var end = size;
    while (end > 0) {
        const chunk_len: usize = @intCast(@min(end, @as(u64, buffer.len)));
        const start = end - chunk_len;
        const count = try file.readPositionalAll(io, buffer[0..chunk_len], start);
        if (count == 0) return 0;
        var index = count;
        while (index > 0) {
            index -= 1;
            const position = start + index;
            if (position == size - 1 and buffer[index] == '\n') continue;
            if (buffer[index] != '\n') continue;
            remaining -= 1;
            if (remaining == 0) return position + 1;
        }
        end = start;
    }
    return 0;
}

fn writeLogRange(file: Io.File, io: Io, writer: *Io.Writer, start: u64, end: u64) !u64 {
    var buffer: [8192]u8 = undefined;
    var offset = start;
    while (offset < end) {
        const count = try file.readPositionalAll(io, buffer[0..@intCast(@min(end - offset, buffer.len))], offset);
        if (count == 0) break;
        try writer.writeAll(buffer[0..count]);
        offset += count;
    }
    try writer.flush();
    return offset;
}

fn appendLog(io: Io, writer: *Io.Writer, path: []const u8, previous_offset: u64) !u64 {
    const file = Io.Dir.cwd().openFile(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return previous_offset,
        else => return err,
    };
    defer file.close(io);
    const size = (try file.stat(io)).size;
    const offset = if (size < previous_offset) 0 else previous_offset;
    return writeLogRange(file, io, writer, offset, size);
}

fn addCommand(root: *zli.Command, init: zli.InitOptions, name: []const u8, description: []const u8, execute: anytype) !*zli.Command {
    const command = try zli.Command.init(init, .{ .name = name, .description = description }, execute);
    try root.addCommand(command);
    return command;
}

fn buildCli(init: zli.InitOptions) !*zli.Command {
    const root = try zli.Command.init(init, .{
        .name = "croner",
        .description = "Cron jobs for Zig projects",
        .version = .{ .major = 0, .minor = 1, .patch = 0 },
    }, commandHelp);
    errdefer root.deinit();
    try root.addFlag(.{
        .name = "config",
        .description = "Configuration file",
        .type = .String,
        .default_value = .{ .String = "./croner.json" },
        .persistent = true,
    });

    _ = try addCommand(root, init, "setup", "Create a croner.json file", commandSetup);
    const start = try addCommand(root, init, "start", "Start the daemon or resume a job", commandStart);
    try start.addPositionalArg(.{ .name = "id", .description = "Job id", .required = false });
    const stop = try addCommand(root, init, "stop", "Stop the daemon or pause a job", commandStop);
    try stop.addPositionalArg(.{ .name = "id", .description = "Job id", .required = false });
    _ = try addCommand(root, init, "list", "List configured jobs", commandList);
    _ = try addCommand(root, init, "reload", "Reload the configuration", commandReload);
    _ = try addCommand(root, init, "version", "Print the version", commandVersion);
    const logs = try addCommand(root, init, "logs", "Show daemon logs", commandLogs);
    try logs.addFlag(.{ .name = "lines", .description = "Number of lines", .type = .Int, .default_value = .{ .Int = 100 } });
    try logs.addFlag(.{ .name = "follow", .description = "Follow appended logs", .type = .Bool, .default_value = .{ .Bool = false } });
    return root;
}

fn normalizedArgVector(allocator: Allocator, args: []const [:0]const u8) ![][*:0]const u8 {
    const vector = try allocator.alloc([*:0]const u8, args.len);
    for (args, vector) |arg, *item| item.* = arg.ptr;

    // zli discovers a subcommand only before the first flag.
    if (args.len >= 4 and std.mem.eql(u8, args[1], "--config") and args[3].len > 0 and args[3][0] != '-') {
        vector[1] = args[3].ptr;
        vector[2] = args[1].ptr;
        vector[3] = args[2].ptr;
    } else if (args.len >= 3 and std.mem.startsWith(u8, args[1], "--config=") and args[2].len > 0 and args[2][0] != '-') {
        vector[1] = args[2].ptr;
        vector[2] = args[1].ptr;
    }
    return vector;
}

fn commandHelp(ctx: zli.CommandContext) !void {
    try ctx.command.printHelp();
}

fn commandVersion(ctx: zli.CommandContext) !void {
    try ctx.root.printVersion();
}

fn serve(init: std.process.Init, config_path: []const u8) !void {
    if (std.posix.errno(std.posix.system.setsid()) != .SUCCESS) return error.DetachFailed;
    const fds = try Io.Threaded.pipe2(.{ .CLOEXEC = true });
    const signal_reader = Io.File{ .handle = fds[0], .flags = .{ .nonblocking = false } };
    const signal_writer = Io.File{ .handle = fds[1], .flags = .{ .nonblocking = false } };
    defer signal_reader.close(init.io);
    defer signal_writer.close(init.io);
    signal_write_fd.store(fds[1], .release);
    defer signal_write_fd.store(-1, .release);
    installSignalHandlers();
    var state = try StatePaths.init(init.gpa, init.io, config_path);
    defer state.deinit();
    try state.ensure(init.io);
    const state_lock = acquireStateLock(init.io, &state) catch |err| switch (err) {
        error.WouldBlock => return error.AlreadyRunning,
        else => return err,
    };
    defer state_lock.close(init.io);
    var daemon = try Daemon.init(init.gpa, init.io, init.environ_map, config_path);
    defer daemon.deinit();
    var server = try listenState(init.io, &state);
    defer {
        server.deinit(init.io);
        Io.Dir.deleteFileAbsolute(init.io, state.socket) catch {};
    }
    std.debug.print("[croner] daemon started\n", .{});
    const Event = union(enum) {
        server: anyerror!void,
        signal: anyerror!void,
    };
    var events: [2]Event = undefined;
    var select: Io.Select(Event) = .init(init.io, &events);
    try select.concurrent(.server, runServer, .{ &daemon, &server });
    defer select.cancelDiscard();
    try select.concurrent(.signal, waitForSignal, .{ signal_reader, init.io });
    const event = try select.await();
    switch (event) {
        .server => |result| result catch |err| if (err != error.Canceled) return err,
        .signal => {},
    }
    std.debug.print("[croner] daemon stopped\n", .{});
}

pub fn main(init: std.process.Init) !void {
    if (builtin.os.tag != .macos and builtin.os.tag != .linux) return error.UnsupportedOperatingSystem;
    const allocator = init.gpa;
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = Io.File.stdout().writer(init.io, &stdout_buffer);
    defer stdout_writer.interface.flush() catch {};
    var stdin_buffer: [4096]u8 = undefined;
    var stdin_reader = Io.File.stdin().reader(init.io, &stdin_buffer);

    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len > 1 and std.mem.eql(u8, args[1], "_serve")) {
        if (args.len != 3) return error.InvalidArguments;
        return serve(init, args[2]);
    }
    var cli = try buildCli(.{
        .io = init.io,
        .writer = &stdout_writer.interface,
        .reader = &stdin_reader.interface,
        .allocator = allocator,
    });
    defer cli.deinit();
    const arg_vector = try normalizedArgVector(init.arena.allocator(), args);
    var iterator = (std.process.Args{ .vector = arg_vector }).iterate();
    var app: App = .{ .allocator = allocator, .io = init.io };
    cli.execute(&iterator, .{ .data = &app }) catch |err| {
        if (err != error.DaemonError)
            stdout_writer.interface.print("error: {s}\n", .{@errorName(err)}) catch {};
        stdout_writer.interface.flush() catch {};
        std.process.exit(1);
    };
}

test "config parsing applies defaults and rejects invalid jobs" {
    const valid = "{\"$schema\":\"https://xcaeser.github.io/croner/croner.schema.json\",\"jobs\":[{\"id\":\"sync\",\"schedule\":\"*/5 * * * *\",\"action\":{\"command\":{\"argv\":[\"echo\",\"ok\"],\"env\":{\"MODE\":\"test\"}}}}]}";
    var parsed = try parseConfig(std.testing.allocator, valid, "/tmp");
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 1), parsed.items.items.len);
    try std.testing.expectEqual(libcron.OverlapPolicy.skip, parsed.items.items[0].overlap);
    try std.testing.expectEqualStrings("/tmp", parsed.items.items[0].cwd);
    try std.testing.expectEqualStrings("test", parsed.items.items[0].env[0].value);

    const duplicate = "{\"jobs\":[{\"id\":\"x\",\"schedule\":\"* * * * *\",\"action\":{\"command\":{\"argv\":[\"x\"]}}},{\"id\":\"x\",\"schedule\":\"* * * * *\",\"action\":{\"command\":{\"argv\":[\"y\"]}}}]}";
    try std.testing.expectError(error.DuplicateJobId, parseConfig(std.testing.allocator, duplicate, "/tmp"));

    const bad_env = "{\"jobs\":[{\"id\":\"x\",\"schedule\":\"* * * * *\",\"action\":{\"command\":{\"argv\":[\"x\"],\"env\":{\"BAD-NAME\":\"x\"}}}}]}";
    try std.testing.expectError(error.InvalidEnvironment, parseConfig(std.testing.allocator, bad_env, "/tmp"));

    const explicit = "{\"jobs\":[{\"id\":\"x\",\"schedule\":\"* * * * *\",\"action\":{\"command\":{\"argv\":[\"x\"],\"cwd\":\"work\"}},\"overlap\":\"concurrent\"}]}";
    var explicit_parsed = try parseConfig(std.testing.allocator, explicit, "/tmp");
    defer explicit_parsed.deinit();
    try std.testing.expectEqual(libcron.OverlapPolicy.concurrent, explicit_parsed.items.items[0].overlap);
    try std.testing.expectEqualStrings("/tmp/work", explicit_parsed.items.items[0].cwd);
}

test "config parser rejects unknown fields and invalid schedules" {
    const unknown = "{\"jobs\":[],\"extra\":true}";
    try std.testing.expectError(error.InvalidConfig, parseConfig(std.testing.allocator, unknown, "/tmp"));
    const invalid_schedule = "{\"jobs\":[{\"id\":\"x\",\"schedule\":\"not cron\",\"action\":{\"command\":{\"argv\":[\"x\"]}}}]}";
    try std.testing.expectError(error.InvalidSchedule, parseConfig(std.testing.allocator, invalid_schedule, "/tmp"));
    const invalid_schema = "{\"$schema\":\"https://example.com/schema.json\",\"jobs\":[]}";
    try std.testing.expectError(error.InvalidSchema, parseConfig(std.testing.allocator, invalid_schema, "/tmp"));
    const empty_argv = "{\"jobs\":[{\"id\":\"x\",\"schedule\":\"* * * * *\",\"action\":{\"command\":{\"argv\":[]}}}]}";
    try std.testing.expectError(error.InvalidCommand, parseConfig(std.testing.allocator, empty_argv, "/tmp"));
    const empty_cwd = "{\"jobs\":[{\"id\":\"x\",\"schedule\":\"* * * * *\",\"action\":{\"command\":{\"argv\":[\"x\"],\"cwd\":\"\"}}}]}";
    try std.testing.expectError(error.InvalidCwd, parseConfig(std.testing.allocator, empty_cwd, "/tmp"));

    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    const one_job = "{\"jobs\":[{\"id\":\"x\",\"schedule\":\"* * * * *\",\"action\":{\"command\":{\"argv\":[\"x\"]}}}]}";
    try std.testing.expectError(error.OutOfMemory, parseConfig(failing.allocator(), one_job, "/tmp"));
}

test "job spec owns allocations made while it is initialized" {
    var long_id: [8192]u8 = @splat('x');
    var spec = try JobSpec.init(std.testing.allocator, .{
        .id = &long_id,
        .schedule = "* * * * *",
        .action = .{ .command = .{ .argv = &.{"true"} } },
    }, "/tmp");
    defer spec.deinit();
    try std.testing.expectEqualStrings(&long_id, spec.id);
}

test "config flag may precede the subcommand" {
    const separate = [_][:0]const u8{ "croner", "--config", "project.json", "list" };
    const separate_vector = try normalizedArgVector(std.testing.allocator, &separate);
    defer std.testing.allocator.free(separate_vector);
    const expected_separate = [_][]const u8{ "croner", "list", "--config", "project.json" };
    for (expected_separate, separate_vector) |expected, actual|
        try std.testing.expectEqualStrings(expected, std.mem.span(actual));

    const joined = [_][:0]const u8{ "croner", "--config=project.json", "start", "sync" };
    const joined_vector = try normalizedArgVector(std.testing.allocator, &joined);
    defer std.testing.allocator.free(joined_vector);
    const expected_joined = [_][]const u8{ "croner", "start", "--config=project.json", "sync" };
    for (expected_joined, joined_vector) |expected, actual|
        try std.testing.expectEqualStrings(expected, std.mem.span(actual));
}

test "relative config path produces absolute state paths" {
    var state = try StatePaths.init(std.testing.allocator, std.testing.io, "./croner.json");
    defer state.deinit();
    try std.testing.expect(std.fs.path.isAbsolute(state.root));
    try std.testing.expect(std.fs.path.isAbsolute(state.socket));
    try std.testing.expect(state.socket.len <= unix_socket_path_max);
}

test "protocol messages round trip and log tail selects requested lines" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "log", .data = "a\nb\nc\n" });
    const file = try tmp.dir.openFile(std.testing.io, "log", .{});
    defer file.close(std.testing.io);
    try std.testing.expectEqual(@as(u64, 2), try tailOffset(file, std.testing.io, 6, 2));

    const cwd = try std.process.currentPathAlloc(std.testing.io, std.testing.allocator);
    defer std.testing.allocator.free(cwd);
    const socket_path = try std.fs.path.resolve(std.testing.allocator, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path, "protocol.sock" });
    defer std.testing.allocator.free(socket_path);
    const address = try Io.net.UnixAddress.init(socket_path);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "protocol.sock", .data = "stale" });
    const lock_path = try std.fs.path.resolve(std.testing.allocator, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path, "protocol.lock" });
    defer std.testing.allocator.free(lock_path);
    const state: StatePaths = .{
        .allocator = std.testing.allocator,
        .root = "",
        .socket = socket_path,
        .lock = lock_path,
        .log = "",
    };
    const state_lock = try acquireStateLock(std.testing.io, &state);
    defer state_lock.close(std.testing.io);
    try std.testing.expectError(error.WouldBlock, acquireStateLock(std.testing.io, &state));
    try std.testing.expect(!(try daemonSocketAvailable(std.testing.io, &state)));
    var server = try listenState(std.testing.io, &state);
    defer {
        server.deinit(std.testing.io);
        Io.Dir.deleteFileAbsolute(std.testing.io, socket_path) catch {};
    }
    var client = try address.connect(std.testing.io);
    defer client.close(std.testing.io);
    var peer = try server.accept(std.testing.io);
    defer peer.close(std.testing.io);
    try std.testing.expectError(
        error.Timeout,
        readMessageTimeout(&peer, std.testing.io, std.testing.allocator, .{
            .deadline = .{ .clock = .awake, .raw = .zero },
        }),
    );

    try sendMessage(&client, std.testing.io, Request, .{ .start = "sync" }, std.testing.allocator);
    const request_bytes = try readMessage(&peer, std.testing.io, std.testing.allocator);
    defer std.testing.allocator.free(request_bytes);
    var request_parsed = try std.json.parseFromSlice(Request, std.testing.allocator, request_bytes, .{});
    defer request_parsed.deinit();
    try std.testing.expectEqualStrings("sync", request_parsed.value.start);

    try sendMessage(&peer, std.testing.io, Response, .{ .ok = "started" }, std.testing.allocator);
    const response_bytes = try readMessage(&client, std.testing.io, std.testing.allocator);
    defer std.testing.allocator.free(response_bytes);
    var response_parsed = try std.json.parseFromSlice(Response, std.testing.allocator, response_bytes, .{});
    defer response_parsed.deinit();
    try std.testing.expectEqualStrings("started", response_parsed.value.ok);

    const payload = try std.testing.allocator.alloc(u8, max_message_bytes);
    defer std.testing.allocator.free(payload);
    @memset(payload, 'x');
    const WriteExactMessage = struct {
        fn run(stream: *Io.net.Stream, io: Io, bytes: []const u8) !void {
            var buffer: [4096]u8 = undefined;
            var writer = stream.writer(io, &buffer);
            try writer.interface.writeAll(bytes);
            try writer.interface.writeByte('\n');
            try writer.interface.flush();
        }
    };
    var write_future = try Io.concurrent(std.testing.io, WriteExactMessage.run, .{ &client, std.testing.io, payload });
    errdefer _ = write_future.cancel(std.testing.io) catch {};
    const exact = try readMessage(&peer, std.testing.io, std.testing.allocator);
    defer std.testing.allocator.free(exact);
    try write_future.await(std.testing.io);
    try std.testing.expectEqualSlices(u8, payload, exact);

    const wire_oversized = try std.testing.allocator.alloc(u8, max_message_bytes + 1);
    defer std.testing.allocator.free(wire_oversized);
    @memset(wire_oversized, 'x');
    var oversized_future = try Io.concurrent(std.testing.io, WriteExactMessage.run, .{
        &client,
        std.testing.io,
        wire_oversized,
    });
    errdefer _ = oversized_future.cancel(std.testing.io) catch {};
    try std.testing.expectError(
        error.MessageTooLarge,
        readMessage(&peer, std.testing.io, std.testing.allocator),
    );
    try oversized_future.await(std.testing.io);

    const oversized = try std.testing.allocator.alloc(u8, max_message_bytes);
    defer std.testing.allocator.free(oversized);
    @memset(oversized, 'x');
    try std.testing.expectError(
        error.MessageTooLarge,
        sendMessage(&client, std.testing.io, Response, .{ .ok = oversized }, std.testing.allocator),
    );
    try std.testing.expectError(error.AlreadyRunning, listenState(std.testing.io, &state));
    server.deinit(std.testing.io);
    server = try listenState(std.testing.io, &state);
}

test "daemon pause and reload reconcile by stable job id" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const initial = "{\"jobs\":[{\"id\":\"keep\",\"schedule\":\"* * * * *\",\"action\":{\"command\":{\"argv\":[\"/usr/bin/true\"]}}},{\"id\":\"change\",\"schedule\":\"* * * * *\",\"action\":{\"command\":{\"argv\":[\"/usr/bin/true\"]}}},{\"id\":\"remove\",\"schedule\":\"* * * * *\",\"action\":{\"command\":{\"argv\":[\"/usr/bin/true\"]}}}]}";
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "croner.json", .data = initial });
    const path = try tmp.dir.realPathFileAlloc(std.testing.io, "croner.json", std.testing.allocator);
    defer std.testing.allocator.free(path);
    var environ: std.process.Environ.Map = .init(std.testing.allocator);
    defer environ.deinit();
    var daemon = try Daemon.init(std.testing.allocator, std.testing.io, &environ, path);
    defer daemon.deinit();

    const keep = daemon.find("keep").?;
    const change = daemon.find("change").?;
    try std.testing.expect(keep.owned_environ == null);
    try daemon.setRunning("keep", false);
    try std.testing.expect(keep.future == null);
    try daemon.setRunning("keep", true);
    try std.testing.expect(keep.future != null);
    try daemon.setRunning("keep", false);

    const invalid = "{\"jobs\":[{\"id\":\"keep\",\"schedule\":\"* * * * *\",\"action\":{\"command\":{\"argv\":[\"/usr/bin/true\"]}}},{\"id\":\"keep\",\"schedule\":\"* * * * *\",\"action\":{\"command\":{\"argv\":[\"/usr/bin/true\"]}}}]}";
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "croner.json", .data = invalid });
    try std.testing.expectError(error.DuplicateJobId, daemon.reload());
    try std.testing.expect(daemon.find("keep").? == keep);
    try std.testing.expect(daemon.find("change").? == change);
    try std.testing.expect(keep.future == null);

    const updated = "{\"jobs\":[{\"id\":\"keep\",\"schedule\":\"* * * * *\",\"action\":{\"command\":{\"argv\":[\"/usr/bin/true\"]}}},{\"id\":\"change\",\"schedule\":\"*/2 * * * *\",\"action\":{\"command\":{\"argv\":[\"/usr/bin/true\"]}}},{\"id\":\"new\",\"schedule\":\"* * * * *\",\"action\":{\"command\":{\"argv\":[\"/usr/bin/true\"],\"env\":{\"CRONER_TEST\":\"1\"}}}}]}";
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "croner.json", .data = updated });
    try daemon.reload();
    try std.testing.expect(daemon.find("keep").? == keep);
    try std.testing.expect(keep.future == null);
    try std.testing.expect(daemon.find("change").? != change);
    try std.testing.expect(daemon.find("change").?.future != null);
    try std.testing.expect(daemon.find("remove") == null);
    const new_job = daemon.find("new").?;
    try std.testing.expect(new_job.future != null);
    try std.testing.expectEqualStrings("1", new_job.owned_environ.?.get("CRONER_TEST").?);

    const failed = new_job;
    failed.stop();
    failed.scheduler.running = true;
    try failed.start();
    try std.testing.expectError(error.AlreadyRunning, failed.future.?.await(std.testing.io));
    try std.testing.expectEqual(Status.offline, failed.state.load(.acquire));
    const statuses = try daemon.status(std.testing.allocator);
    defer std.testing.allocator.free(statuses);
    try std.testing.expectEqualStrings("new", statuses[2].id);
    try std.testing.expectEqual(Status.offline, statuses[2].status);

    failed.scheduler.running = false;
    try failed.start();
    try std.testing.expectEqual(Status.active, failed.state.load(.acquire));
    daemon.stopAll();
    for (daemon.jobs.items) |job| {
        try std.testing.expect(job.future == null);
        try std.testing.expectEqual(Status.paused, job.state.load(.acquire));
    }
}

fn jsonWrite(comptime T: type, value: T, allocator: Allocator) ![]u8 {
    var writer = Io.Writer.Allocating.init(allocator);
    errdefer writer.deinit();
    try std.json.Stringify.value(value, .{ .emit_null_optional_fields = false }, &writer.writer);
    try writer.writer.writeByte('\n');
    return writer.toOwnedSlice();
}

fn readMessage(stream: *Io.net.Stream, io: Io, allocator: Allocator) ![]u8 {
    return readMessageTimeout(stream, io, allocator, .none);
}

fn readMessageTimeout(stream: *Io.net.Stream, io: Io, allocator: Allocator, timeout: Io.Timeout) ![]u8 {
    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(allocator);
    var chunk: [4096]u8 = undefined;
    while (true) {
        const read_len = @min(chunk.len, max_message_bytes - result.items.len + 1);
        var data = [_][]u8{chunk[0..read_len]};
        const count = try (try io.operateTimeout(.{ .net_read = .{
            .socket_handle = stream.socket.handle,
            .data = &data,
        } }, timeout)).net_read;
        if (count == 0) return error.EndOfStream;
        const bytes = chunk[0..count];
        if (std.mem.indexOfScalar(u8, bytes, '\n')) |index| {
            if (result.items.len + index > max_message_bytes) return error.MessageTooLarge;
            try result.appendSlice(allocator, bytes[0..index]);
            return result.toOwnedSlice(allocator);
        }
        if (result.items.len + bytes.len > max_message_bytes) return error.MessageTooLarge;
        try result.appendSlice(allocator, bytes);
    }
}

fn sendMessage(stream: *Io.net.Stream, io: Io, comptime T: type, value: T, allocator: Allocator) !void {
    const bytes = try jsonWrite(T, value, allocator);
    defer allocator.free(bytes);
    if (bytes.len > max_message_bytes + 1) return error.MessageTooLarge;
    const timeout: Io.Timeout = .{ .deadline = .fromNow(io, control_io_timeout) };
    var offset: usize = 0;
    while (offset < bytes.len) {
        const data = [_][]const u8{bytes[offset..]};
        const count = try (try io.operateTimeout(.{ .net_write = .{
            .socket_handle = stream.socket.handle,
            .data = &data,
        } }, timeout)).net_write;
        if (count == 0) return error.EndOfStream;
        offset += count;
    }
}

fn connectState(io: Io, state: *const StatePaths) !Io.net.Stream {
    const stat = Io.Dir.cwd().statFile(io, state.socket, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return error.FileNotFound,
        else => return err,
    };
    if (stat.kind != .unix_domain_socket) return error.FileNotFound;
    const address = try Io.net.UnixAddress.init(state.socket);
    return address.connect(io);
}

fn request(allocator: Allocator, io: Io, state: *const StatePaths, message: Request) !std.json.Parsed(Response) {
    var stream = try connectState(io, state);
    defer stream.close(io);
    try sendMessage(&stream, io, Request, message, allocator);
    const line = try readMessageTimeout(
        &stream,
        io,
        allocator,
        .{ .deadline = .fromNow(io, control_io_timeout) },
    );
    defer allocator.free(line);
    return std.json.parseFromSlice(Response, allocator, line, .{
        .allocate = .alloc_always,
        .duplicate_field_behavior = .@"error",
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidResponse,
    };
}

fn daemonSocketAvailable(io: Io, state: *const StatePaths) !bool {
    var stream = connectState(io, state) catch |err| switch (err) {
        error.ConnectionRefused, error.FileNotFound => return false,
        else => return err,
    };
    stream.close(io);
    return true;
}

fn waitForDaemon(allocator: Allocator, io: Io, state: *const StatePaths, child_pid: u64) !void {
    while (true) {
        var response = request(allocator, io, state, .ping) catch |err| {
            if (err == error.OutOfMemory or err == error.Canceled) return err;
            try Io.sleep(io, .fromMilliseconds(25), .awake);
            continue;
        };
        const daemon_pid = switch (response.value) {
            .pid => |pid| pid,
            else => {
                response.deinit();
                return error.InvalidResponse;
            },
        };
        response.deinit();
        if (daemon_pid != child_pid) return error.AlreadyRunning;
        return;
    }
}

fn acquireStateLock(io: Io, state: *const StatePaths) !Io.File {
    return Io.Dir.createFileAbsolute(io, state.lock, .{
        .truncate = false,
        .lock = .exclusive,
        .lock_nonblocking = true,
        .permissions = .fromMode(0o600),
    });
}

fn listenState(io: Io, state: *const StatePaths) !Io.net.Server {
    const address = try Io.net.UnixAddress.init(state.socket);
    return address.listen(io, .{}) catch |err| switch (err) {
        error.AddressInUse => {
            if (try daemonSocketAvailable(io, state)) return error.AlreadyRunning;
            Io.Dir.deleteFileAbsolute(io, state.socket) catch |delete_err| switch (delete_err) {
                error.FileNotFound => {},
                else => return delete_err,
            };
            return address.listen(io, .{});
        },
        else => return err,
    };
}

fn handleRequest(daemon: *Daemon, stream: *Io.net.Stream, request_bytes: []const u8, shutdown: *bool) !void {
    var parsed = std.json.parseFromSlice(Request, daemon.allocator, request_bytes, .{
        .allocate = .alloc_always,
        .duplicate_field_behavior = .@"error",
    }) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        try sendMessage(stream, daemon.io, Response, .{ .@"error" = "invalid request" }, daemon.allocator);
        return;
    };
    defer parsed.deinit();
    switch (parsed.value) {
        .ping => try sendMessage(
            stream,
            daemon.io,
            Response,
            .{ .pid = @intCast(std.posix.system.getpid()) },
            daemon.allocator,
        ),
        .list => {
            const statuses = try daemon.status(daemon.allocator);
            defer daemon.allocator.free(statuses);
            try sendMessage(stream, daemon.io, Response, .{ .jobs = statuses }, daemon.allocator);
        },
        .start => |id| {
            daemon.setRunning(id, true) catch |err| {
                const message = @errorName(err);
                try sendMessage(stream, daemon.io, Response, .{ .@"error" = message }, daemon.allocator);
                return;
            };
            try sendMessage(stream, daemon.io, Response, .{ .ok = "started" }, daemon.allocator);
        },
        .stop => |id| {
            daemon.setRunning(id, false) catch |err| {
                const message = @errorName(err);
                try sendMessage(stream, daemon.io, Response, .{ .@"error" = message }, daemon.allocator);
                return;
            };
            try sendMessage(stream, daemon.io, Response, .{ .ok = "stopped" }, daemon.allocator);
        },
        .reload => {
            daemon.reload() catch |err| {
                const message = @errorName(err);
                try sendMessage(stream, daemon.io, Response, .{ .@"error" = message }, daemon.allocator);
                return;
            };
            try sendMessage(stream, daemon.io, Response, .{ .ok = "reloaded" }, daemon.allocator);
        },
        .shutdown => {
            daemon.stopAll();
            shutdown.* = true;
            try sendMessage(stream, daemon.io, Response, .{ .ok = "stopped" }, daemon.allocator);
        },
    }
}

fn runServer(daemon: *Daemon, server: *Io.net.Server) !void {
    var shutdown = false;
    while (!shutdown) {
        var stream = server.accept(daemon.io) catch |err| switch (err) {
            error.Canceled => break,
            else => return err,
        };
        defer stream.close(daemon.io);
        const bytes = readMessageTimeout(
            &stream,
            daemon.io,
            daemon.allocator,
            .{ .deadline = .fromNow(daemon.io, control_io_timeout) },
        ) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            continue;
        };
        defer daemon.allocator.free(bytes);
        handleRequest(daemon, &stream, bytes, &shutdown) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
        };
    }
}

fn waitForSignal(file: Io.File, io: Io) anyerror!void {
    var byte: [1]u8 = undefined;
    const data = [_][]u8{byte[0..]};
    _ = try file.readStreaming(io, &data);
}

const RuntimeJob = struct {
    allocator: Allocator,
    io: Io,
    spec: JobSpec,
    owned_environ: ?std.process.Environ.Map,
    scheduler: libcron.Scheduler,
    future: ?Io.Future(libcron.RunError!void) = null,
    state: std.atomic.Value(Status),

    fn create(allocator: Allocator, io: Io, parent_env: *const std.process.Environ.Map, spec: JobSpec) !*RuntimeJob {
        var owned_spec = spec;
        errdefer owned_spec.deinit();
        const job = try allocator.create(RuntimeJob);
        errdefer allocator.destroy(job);
        job.* = undefined;
        job.allocator = allocator;
        job.io = io;
        job.spec = owned_spec;
        owned_spec.arena = null;
        errdefer job.spec.deinit();
        job.owned_environ = null;
        errdefer if (job.owned_environ) |*environ| environ.deinit();
        const environ_map = if (spec.env.len == 0)
            parent_env
        else blk: {
            job.owned_environ = try parent_env.clone(allocator);
            for (spec.env) |entry| try job.owned_environ.?.put(entry.key, entry.value);
            break :blk &job.owned_environ.?;
        };
        job.scheduler = libcron.Scheduler.init(allocator);
        errdefer job.scheduler.deinit();
        _ = try job.scheduler.add(spec.expression, .{ .command = .{
            .argv = spec.argv,
            .cwd = .{ .path = spec.cwd },
            .environ_map = environ_map,
        } }, .{ .time_zone = .utc, .overlap = spec.overlap });
        job.future = null;
        job.state = .init(.paused);
        return job;
    }

    fn start(self: *RuntimeJob) !void {
        switch (self.state.load(.acquire)) {
            .active => return,
            .offline => if (self.future) |*future| {
                _ = future.await(self.io) catch {};
                self.future = null;
            },
            .paused => {},
        }
        self.state.store(.active, .release);
        self.future = Io.concurrent(self.io, run, .{self}) catch |err| {
            self.state.store(.offline, .release);
            return err;
        };
    }

    fn stop(self: *RuntimeJob) void {
        if (self.future) |*future| {
            _ = future.cancel(self.io) catch {};
            self.future = null;
        }
        self.state.store(.paused, .release);
    }

    fn run(self: *RuntimeJob) libcron.RunError!void {
        self.scheduler.run(self.io, .{ .context = self, .notify = observerNotify }) catch |err| {
            if (err != error.Canceled) self.state.store(.offline, .release);
            return err;
        };
        self.state.store(.offline, .release);
    }

    fn deinit(self: *RuntimeJob) void {
        self.stop();
        self.scheduler.deinit();
        if (self.owned_environ) |*environ| environ.deinit();
        self.spec.deinit();
        self.allocator.destroy(self);
    }
};

fn observerNotify(context: ?*anyopaque, invocation: libcron.Invocation, outcome: libcron.Outcome) void {
    const job: *RuntimeJob = @ptrCast(@alignCast(context.?));
    std.debug.print("[{s}] {s} at {d}\n", .{ job.spec.id, @tagName(outcome), invocation.scheduled_unix_minute });
}

const Daemon = struct {
    allocator: Allocator,
    io: Io,
    parent_env: *const std.process.Environ.Map,
    config_path: []const u8,
    jobs: std.ArrayList(*RuntimeJob),

    fn init(allocator: Allocator, io: Io, parent_env: *const std.process.Environ.Map, config_path: []const u8) !Daemon {
        const config_absolute = try resolveFromCwd(allocator, io, config_path);
        var result: Daemon = .{
            .allocator = allocator,
            .io = io,
            .parent_env = parent_env,
            .config_path = config_absolute,
            .jobs = .empty,
        };
        errdefer result.deinit();
        var specs = try loadConfig(allocator, io, result.config_path);
        defer specs.deinit();
        try result.jobs.ensureTotalCapacity(allocator, specs.items.items.len);
        for (specs.items.items) |*spec| {
            const runtime = try RuntimeJob.create(allocator, io, parent_env, spec.move());
            runtime.start() catch |err| {
                runtime.deinit();
                return err;
            };
            result.jobs.appendAssumeCapacity(runtime);
        }
        return result;
    }

    fn deinit(self: *Daemon) void {
        for (self.jobs.items) |job| job.deinit();
        self.jobs.deinit(self.allocator);
        self.allocator.free(self.config_path);
        self.* = undefined;
    }

    fn find(self: *Daemon, id: []const u8) ?*RuntimeJob {
        for (self.jobs.items) |job| if (std.mem.eql(u8, job.spec.id, id)) return job;
        return null;
    }

    fn setRunning(self: *Daemon, id: []const u8, running: bool) !void {
        const job = self.find(id) orelse return error.UnknownJob;
        if (running) try job.start() else job.stop();
    }

    fn stopAll(self: *Daemon) void {
        for (self.jobs.items) |job| job.stop();
    }

    fn reload(self: *Daemon) !void {
        var specs = try loadConfig(self.allocator, self.io, self.config_path);
        errdefer specs.deinit();
        const Existing = struct {
            job: *RuntimeJob,
            retained: bool = false,
            was_active: bool = false,
        };
        var existing_by_id = std.StringHashMap(Existing).init(self.allocator);
        defer existing_by_id.deinit();
        try existing_by_id.ensureTotalCapacity(@intCast(self.jobs.items.len));
        for (self.jobs.items) |job| existing_by_id.putAssumeCapacity(job.spec.id, .{ .job = job });
        var next: std.ArrayList(*RuntimeJob) = .empty;
        var created: std.ArrayList(*RuntimeJob) = .empty;
        errdefer {
            for (created.items) |job| job.deinit();
            created.deinit(self.allocator);
            next.deinit(self.allocator);
        }
        try next.ensureTotalCapacity(self.allocator, specs.items.items.len);
        try created.ensureTotalCapacity(self.allocator, specs.items.items.len);
        for (specs.items.items) |*candidate| {
            if (existing_by_id.getPtr(candidate.id)) |existing| {
                if (existing.job.spec.eql(candidate)) {
                    existing.retained = true;
                    next.appendAssumeCapacity(existing.job);
                    continue;
                }
            }
            const runtime = try RuntimeJob.create(self.allocator, self.io, self.parent_env, candidate.move());
            created.appendAssumeCapacity(runtime);
            next.appendAssumeCapacity(runtime);
        }
        var existing_iterator = existing_by_id.valueIterator();
        while (existing_iterator.next()) |existing| {
            existing.was_active = !existing.retained and existing.job.state.load(.acquire) == .active;
            if (existing.was_active) existing.job.stop();
        }
        for (created.items) |job| job.start() catch |err| {
            for (created.items) |created_job| created_job.stop();
            var restore_iterator = existing_by_id.valueIterator();
            while (restore_iterator.next()) |existing| {
                if (existing.was_active) existing.job.start() catch |restart_err|
                    std.debug.print("[{s}] failed to restore scheduler: {s}\n", .{ existing.job.spec.id, @errorName(restart_err) });
            }
            return err;
        };
        var cleanup_iterator = existing_by_id.valueIterator();
        while (cleanup_iterator.next()) |existing| {
            if (!existing.retained) existing.job.deinit();
        }
        self.jobs.deinit(self.allocator);
        self.jobs = next;
        created.deinit(self.allocator);
        specs.deinit();
    }

    fn status(self: *const Daemon, allocator: Allocator) ![]JobStatus {
        const result = try allocator.alloc(JobStatus, self.jobs.items.len);
        for (self.jobs.items, 0..) |job, i| result[i] = .{
            .id = job.spec.id,
            .schedule = job.spec.schedule,
            .status = job.state.load(.acquire),
        };
        return result;
    }
};
