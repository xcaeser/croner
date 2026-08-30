//! Five-field cron expression parsing, evaluation, and scheduling.
//!
//! `Expression` is allocation-free. `Scheduler` stores in-memory jobs and uses
//! a caller-provided `std.Io` for sleeping, concurrency, and child processes.

const std = @import("std");

pub const ParseError = error{
    InvalidFieldCount,
    InvalidSyntax,
    ValueOutOfRange,
    InvalidRange,
    InvalidStep,
};

pub const DateTimeError = error{InvalidDateTime};

pub const Month = std.time.epoch.Month;

/// A timezone-neutral Gregorian calendar minute.
pub const DateTime = struct {
    year: u16,
    month: Month,
    day: u8,
    hour: u8,
    minute: u8,

    pub fn init(year: u16, month: Month, day: u8, hour: u8, minute: u8) DateTimeError!DateTime {
        const date_time: DateTime = .{
            .year = year,
            .month = month,
            .day = day,
            .hour = hour,
            .minute = minute,
        };
        try date_time.validate();
        return date_time;
    }

    fn validate(self: DateTime) DateTimeError!void {
        if (self.year == 0 or
            self.day == 0 or self.day > std.time.epoch.getDaysInMonth(self.year, self.month) or
            self.hour > 23 or self.minute > 59)
        {
            return error.InvalidDateTime;
        }
    }
};

/// A parsed five-field cron expression.
pub const Expression = struct {
    minutes: u64,
    hours: u32,
    days_of_month: u32,
    months: u16,
    days_of_week: u8,
    day_of_month_star: bool,
    day_of_week_star: bool,

    /// Parses `minute hour day-of-month month day-of-week`.
    pub fn parse(source: []const u8) ParseError!Expression {
        var fields: [5][]const u8 = undefined;
        var tokens = std.mem.tokenizeAny(u8, source, " \t");
        for (&fields) |*field| field.* = tokens.next() orelse return error.InvalidFieldCount;
        if (tokens.next() != null) return error.InvalidFieldCount;

        const minutes = try parseField(fields[0], 0, 59);
        const hours = try parseField(fields[1], 0, 23);
        const days_of_month = try parseField(fields[2], 1, 31);
        const months = try parseField(fields[3], 1, 12);
        const days_of_week = try parseField(fields[4], 0, 6);

        return .{
            .minutes = @intCast(minutes.mask),
            .hours = @intCast(hours.mask),
            .days_of_month = @intCast(days_of_month.mask),
            .months = @intCast(months.mask),
            .days_of_week = @intCast(days_of_week.mask),
            .day_of_month_star = days_of_month.star,
            .day_of_week_star = days_of_week.star,
        };
    }

    /// Returns whether `date_time` matches this expression.
    pub fn matches(self: Expression, date_time: DateTime) DateTimeError!bool {
        try date_time.validate();
        return self.matchesUnchecked(date_time);
    }

    fn matchesUnchecked(self: Expression, date_time: DateTime) bool {
        return has(self.minutes, date_time.minute, 0) and
            has(self.hours, date_time.hour, 0) and
            has(self.months, date_time.month.numeric(), 1) and
            self.dayMatches(date_time);
    }

    /// Returns the first matching calendar minute strictly after `after`.
    /// `null` means no matching minute exists in a Gregorian 400-year cycle or
    /// before the maximum representable year.
    pub fn next(self: Expression, after: DateTime) DateTimeError!?DateTime {
        try after.validate();
        var date_time = nextMinute(after) orelse return null;

        var days_checked: u32 = 0;
        while (days_checked < days_per_gregorian_cycle) : (days_checked += 1) {
            const first_day = days_checked == 0;
            if (has(self.months, date_time.month.numeric(), 1) and self.dayMatches(date_time)) {
                var hour: u8 = if (first_day) date_time.hour else 0;
                while (hour < 24) : (hour += 1) {
                    if (!has(self.hours, hour, 0)) continue;

                    var minute: u8 = if (first_day and hour == date_time.hour) date_time.minute else 0;
                    while (minute < 60) : (minute += 1) {
                        if (has(self.minutes, minute, 0)) {
                            return .{
                                .year = date_time.year,
                                .month = date_time.month,
                                .day = date_time.day,
                                .hour = hour,
                                .minute = minute,
                            };
                        }
                    }
                }
            }

            date_time = nextDay(date_time) orelse return null;
        }
        return null;
    }

    fn dayMatches(self: Expression, date_time: DateTime) bool {
        const day_of_month = has(self.days_of_month, date_time.day, 1);
        const day_of_week = has(self.days_of_week, weekday(date_time), 0);
        return if (self.day_of_month_star or self.day_of_week_star)
            day_of_month and day_of_week
        else
            day_of_month or day_of_week;
    }
};

pub const JobId = enum(u64) { _ };

pub const OverlapPolicy = enum {
    skip,
    concurrent,
};

pub const TimeZoneError = error{
    InvalidOffset,
    InvalidTzif,
    InvalidTzifFooter,
    MissingFutureRule,
    DateOutOfRange,
};

/// A validated UTC, fixed-offset, or caller-owned TZif timezone.
pub const TimeZone = struct {
    value: union(enum) {
        fixed: i32,
        tzif: struct {
            tz: *const std.Tz,
            footer: ?PosixTimeZone,
        },
    },

    pub const utc: TimeZone = .{ .value = .{ .fixed = 0 } };

    /// Creates a fixed timezone offset east of UTC, in seconds, within the
    /// interoperable TZif range -89,999 through 93,599.
    pub fn fixedOffset(seconds: i32) TimeZoneError!TimeZone {
        if (seconds < min_utc_offset or seconds > max_utc_offset) return error.InvalidOffset;
        return .{ .value = .{ .fixed = seconds } };
    }

    /// Creates a timezone borrowing `tz`, which must outlive every use.
    pub fn fromTz(tz: *const std.Tz) TimeZoneError!TimeZone {
        if (tz.timetypes.len == 0) return error.InvalidTzif;
        for (tz.timetypes) |time_type| {
            if (time_type.offset == std.math.minInt(i32)) return error.InvalidTzif;
        }
        const type_start = @intFromPtr(tz.timetypes.ptr);
        const type_size = @sizeOf(std.tz.Timetype);
        const type_end = type_start + type_size * tz.timetypes.len;
        for (tz.transitions) |transition| {
            const address = @intFromPtr(transition.timetype);
            if (address < type_start or address >= type_end or (address - type_start) % type_size != 0)
                return error.InvalidTzif;
        }
        if (tz.transitions.len > 1) {
            for (tz.transitions[1..], tz.transitions[0 .. tz.transitions.len - 1]) |current, previous| {
                if (current.ts <= previous.ts) return error.InvalidTzif;
            }
        }
        for (tz.leapseconds, 0..) |leap, index| {
            if (leap.occurrence < 0) return error.InvalidTzif;
            if (index == 0) {
                if (leap.correction != -1 and leap.correction != 1) return error.InvalidTzif;
                continue;
            }
            const previous = tz.leapseconds[index - 1];
            if (@as(i64, previous.occurrence) + 2_419_199 > leap.occurrence) return error.InvalidTzif;
            const correction_delta = @as(i32, leap.correction) - previous.correction;
            if (correction_delta != -1 and correction_delta != 1) return error.InvalidTzif;
        }

        var footer: ?PosixTimeZone = null;
        if (tz.footer) |source| {
            if (source.len > 0) footer = try PosixTimeZone.parse(source);
        }
        if (tz.transitions.len > 0 and footer == null) return error.MissingFutureRule;
        if (tz.transitions.len > 0) {
            const last = tz.transitions[tz.transitions.len - 1];
            const unix_seconds = try unixTimeFromLeap(tz, last.ts);
            if (try footer.?.offsetAt(unix_seconds) != last.timetype.offset)
                return error.InvalidTzifFooter;
        }

        return .{ .value = .{ .tzif = .{ .tz = tz, .footer = footer } } };
    }

    fn toLocal(self: TimeZone, unix_seconds: i64) TimeZoneError!DateTime {
        return civilFromUnix(unix_seconds, try self.offsetAt(unix_seconds));
    }

    fn offsetAt(self: TimeZone, unix_seconds: i64) TimeZoneError!i32 {
        return switch (self.value) {
            .fixed => |offset| offset,
            .tzif => |zone| tzif: {
                const transitions = zone.tz.transitions;
                if (transitions.len == 0) {
                    break :tzif if (zone.footer) |footer|
                        try footer.offsetAt(unix_seconds)
                    else
                        zone.tz.timetypes[0].offset;
                }
                const transition_time = try unixLeapTime(zone.tz, unix_seconds);
                if (transition_time < transitions[0].ts) break :tzif zone.tz.timetypes[0].offset;
                if (transition_time >= transitions[transitions.len - 1].ts)
                    break :tzif try zone.footer.?.offsetAt(unix_seconds);

                var low: usize = 0;
                var high: usize = transitions.len;
                while (low < high) {
                    const middle = low + (high - low) / 2;
                    if (transitions[middle].ts <= transition_time)
                        low = middle + 1
                    else
                        high = middle;
                }
                break :tzif transitions[low - 1].timetype.offset;
            },
        };
    }
};

pub const Invocation = struct {
    job_id: JobId,
    scheduled_unix_minute: i64,
    local_time: DateTime,
};

pub const Callback = struct {
    context: ?*anyopaque = null,
    run: *const fn (?*anyopaque, std.Io, Invocation) anyerror!void,
};

pub const Command = struct {
    argv: []const []const u8,
    cwd: std.process.Child.Cwd = .inherit,
    environ_map: ?*const std.process.Environ.Map = null,
};

pub const Task = union(enum) {
    callback: Callback,
    command: Command,
};

pub const JobOptions = struct {
    time_zone: TimeZone = .utc,
    overlap: OverlapPolicy = .skip,
};

pub const Outcome = union(enum) {
    callback_success,
    callback_error: anyerror,
    command_terminated: std.process.Child.Term,
    command_error: anyerror,
    skipped_overlap,
};

/// Receives results from scheduler and job tasks and therefore must be
/// thread-safe.
pub const Observer = struct {
    context: ?*anyopaque = null,
    notify: *const fn (?*anyopaque, Invocation, Outcome) void,
};

pub const AddError = std.mem.Allocator.Error || error{
    Running,
    InvalidCommand,
    JobIdExhausted,
};

pub const RunError = std.Io.Cancelable || std.Io.ConcurrentError || TimeZoneError || error{
    AlreadyRunning,
};

/// An in-memory, single-owner scheduler configured before `run` starts.
/// `run` must return before another method is called or the scheduler is
/// deinitialized.
pub const Scheduler = struct {
    allocator: std.mem.Allocator,
    jobs: std.ArrayList(Job),
    next_id: u64,
    running: bool,

    pub fn init(allocator: std.mem.Allocator) Scheduler {
        return .{
            .allocator = allocator,
            .jobs = .empty,
            .next_id = 0,
            .running = false,
        };
    }

    pub fn deinit(self: *Scheduler) void {
        std.debug.assert(!self.running);
        self.jobs.deinit(self.allocator);
        self.* = undefined;
    }

    /// Stores a job specification by value. Any pointed-to data remains owned
    /// by the caller and must outlive `run`.
    pub fn add(
        self: *Scheduler,
        expression: Expression,
        task: Task,
        options: JobOptions,
    ) AddError!JobId {
        if (self.running) return error.Running;
        if (task == .command) {
            const command = task.command;
            if (command.argv.len == 0 or command.argv[0].len == 0)
                return error.InvalidCommand;
            for (command.argv) |arg| {
                if (std.mem.indexOfScalar(u8, arg, 0) != null) return error.InvalidCommand;
            }
            switch (command.cwd) {
                .path => |path| if (path.len == 0 or std.mem.indexOfScalar(u8, path, 0) != null)
                    return error.InvalidCommand,
                .inherit, .dir => {},
            }
            if (command.environ_map) |environ_map| {
                for (environ_map.values()) |value| {
                    if (std.mem.indexOfScalar(u8, value, 0) != null) return error.InvalidCommand;
                }
            }
        }
        if (self.next_id == std.math.maxInt(u64)) return error.JobIdExhausted;

        const id: JobId = @fromBackingInt(self.next_id);
        try self.jobs.append(self.allocator, .{
            .id = id,
            .expression = expression,
            .task = task,
            .options = options,
            .active = .init(false),
        });
        self.next_id += 1;
        return id;
    }

    pub fn remove(self: *Scheduler, id: JobId) error{Running}!bool {
        if (self.running) return error.Running;
        for (self.jobs.items, 0..) |job, index| {
            if (job.id == id) {
                _ = self.jobs.swapRemove(index);
                return true;
            }
        }
        return false;
    }

    /// Runs until canceled. The caller-provided `io` must support concurrency.
    pub fn run(self: *Scheduler, io: std.Io, observer: ?Observer) RunError!void {
        if (self.running) return error.AlreadyRunning;
        self.running = true;
        defer self.running = false;

        var jobs: std.Io.Group = .init;
        defer jobs.cancel(io);

        const minute_ns: i96 = std.time.ns_per_min;
        while (true) {
            const now = std.Io.Clock.real.now(io);
            const deadline_ns = (@divFloor(now.nanoseconds, minute_ns) + 1) * minute_ns;
            const deadline: std.Io.Clock.Timestamp = .{
                .raw = .{ .nanoseconds = deadline_ns },
                .clock = .real,
            };
            try deadline.wait(io);

            const current = std.Io.Clock.real.now(io);
            const unix_minute = std.math.cast(i64, @divFloor(current.nanoseconds, minute_ns)) orelse
                return error.DateOutOfRange;
            try self.dispatchMinute(io, &jobs, unix_minute, observer);
        }
    }

    fn dispatchMinute(
        self: *Scheduler,
        io: std.Io,
        group: *std.Io.Group,
        unix_minute: i64,
        observer: ?Observer,
    ) RunError!void {
        const unix_seconds = std.math.mul(i64, unix_minute, 60) catch return error.DateOutOfRange;
        for (self.jobs.items) |*job| {
            const local_time = try job.options.time_zone.toLocal(unix_seconds);
            if (!job.expression.matchesUnchecked(local_time)) continue;

            const invocation: Invocation = .{
                .job_id = job.id,
                .scheduled_unix_minute = unix_minute,
                .local_time = local_time,
            };
            const tracks_overlap = job.options.overlap == .skip;
            if (tracks_overlap and job.active.swap(true, .acq_rel)) {
                report(observer, invocation, .skipped_overlap);
                continue;
            }

            group.concurrent(io, executeJob, .{ job, io, invocation, observer }) catch |err| {
                if (tracks_overlap) job.active.store(false, .release);
                return err;
            };
        }
    }
};

const Job = struct {
    id: JobId,
    expression: Expression,
    task: Task,
    options: JobOptions,
    active: std.atomic.Value(bool),
};

fn executeJob(
    job: *Job,
    io: std.Io,
    invocation: Invocation,
    observer: ?Observer,
) std.Io.Cancelable!void {
    defer if (job.options.overlap == .skip) job.active.store(false, .release);

    switch (job.task) {
        .callback => |callback| {
            callback.run(callback.context, io, invocation) catch |err| {
                if (err == error.Canceled) return error.Canceled;
                report(observer, invocation, .{ .callback_error = err });
                return;
            };
            report(observer, invocation, .callback_success);
        },
        .command => |command| {
            const previous_cancel_protection = io.swapCancelProtection(.blocked);
            const child_result = std.process.spawn(io, .{
                .argv = command.argv,
                .cwd = command.cwd,
                .environ_map = command.environ_map,
                .stdin = .ignore,
                .stdout = .inherit,
                .stderr = .inherit,
            });
            _ = io.swapCancelProtection(previous_cancel_protection);

            var child = child_result catch |err| {
                if (err == error.Canceled) return error.Canceled;
                report(observer, invocation, .{ .command_error = err });
                return;
            };
            var kill_child = child;
            defer kill_child.kill(io);

            try io.checkCancel();

            const term = child.wait(io) catch |err| {
                if (err == error.Canceled) return error.Canceled;
                report(observer, invocation, .{ .command_error = err });
                return;
            };
            kill_child.id = null;
            report(observer, invocation, .{ .command_terminated = term });
        },
    }
}

fn report(observer: ?Observer, invocation: Invocation, outcome: Outcome) void {
    const sink = observer orelse return;
    sink.notify(sink.context, invocation, outcome);
}

const seconds_per_day = 86_400;
const min_utc_offset = -89_999;
const max_utc_offset = 93_599;

fn unixLeapTime(tz: *const std.Tz, unix_seconds: i64) TimeZoneError!i64 {
    var correction: i64 = 0;
    for (tz.leapseconds) |leap| {
        // `correction` is the value in force before this leap record.
        const event_unix = std.math.sub(i64, leap.occurrence, correction) catch
            return error.DateOutOfRange;
        if (unix_seconds < event_unix) break;
        correction = leap.correction;
    }
    return std.math.add(i64, unix_seconds, correction) catch error.DateOutOfRange;
}

fn unixTimeFromLeap(tz: *const std.Tz, leap_seconds: i64) TimeZoneError!i64 {
    var correction: i64 = 0;
    for (tz.leapseconds) |leap| {
        if (leap_seconds < leap.occurrence) break;
        const next_correction: i64 = leap.correction;
        if (next_correction > correction and
            leap_seconds < @as(i64, leap.occurrence) + next_correction - correction)
            return error.InvalidTzif;
        correction = next_correction;
    }
    return std.math.sub(i64, leap_seconds, correction) catch error.DateOutOfRange;
}

const PosixTimeZone = struct {
    standard_offset: i32,
    daylight_offset: ?i32 = null,
    start: TransitionRule = undefined,
    end: TransitionRule = undefined,

    fn parse(source: []const u8) TimeZoneError!PosixTimeZone {
        for (source) |byte| if (!std.ascii.isPrint(byte)) return error.InvalidTzifFooter;
        var parser: FooterParser = .{ .source = source };
        try parser.skipName();

        var result: PosixTimeZone = .{ .standard_offset = try parser.parseOffset() };
        if (parser.done()) return result;

        try parser.skipName();
        result.daylight_offset = if (parser.peek() != ',')
            try parser.parseOffset()
        else
            result.standard_offset + 3_600;
        try parser.expect(',');
        result.start = try parser.parseRule();
        try parser.expect(',');
        result.end = try parser.parseRule();
        if (!parser.done()) return error.InvalidTzifFooter;
        return result;
    }

    fn offsetAt(self: PosixTimeZone, unix_seconds: i64) TimeZoneError!i32 {
        const daylight_offset = self.daylight_offset orelse return self.standard_offset;
        const year = (try civilFromUnix(unix_seconds, self.standard_offset)).year;
        const RuleTransition = struct {
            at: i64,
            before: i32,
            after: i32,
        };
        var latest: ?RuleTransition = null;
        var earliest: ?RuleTransition = null;

        const year_value: u32 = year;
        // Both rules for Y-1 may spill into Y, so retain Y-2 as prior state.
        var rule_year: u32 = if (year_value > 2) year_value - 2 else 1;
        const last_year: u32 = if (year_value < std.math.maxInt(u16)) year_value + 1 else year_value;
        while (rule_year <= last_year) : (rule_year += 1) {
            const candidate_year: u16 = @intCast(rule_year);
            const transitions = [_]RuleTransition{
                .{
                    .at = self.start.unix(candidate_year, self.standard_offset, self.standard_offset),
                    .before = self.standard_offset,
                    .after = daylight_offset,
                },
                .{
                    .at = self.end.unix(candidate_year, self.standard_offset, daylight_offset),
                    .before = daylight_offset,
                    .after = self.standard_offset,
                },
            };
            for (transitions) |transition| {
                if (transition.at <= unix_seconds) {
                    if (latest == null or transition.at >= latest.?.at) latest = transition;
                } else if (earliest == null or transition.at < earliest.?.at) {
                    earliest = transition;
                }
            }
        }
        return if (latest) |transition| transition.after else earliest.?.before;
    }
};

const TransitionRule = struct {
    day: union(enum) {
        julian_no_leap: u16,
        day_of_year: u16,
        month_week_day: struct {
            month: u8,
            week: u8,
            weekday: u8,
        },
    },
    seconds: i32 = 2 * 60 * 60,
    basis: enum { wall, standard, utc } = .wall,

    fn unix(self: TransitionRule, year: u16, standard_offset: i32, before_offset: i32) i64 {
        const day_index: i64 = switch (self.day) {
            .julian_no_leap => |day| blk: {
                var index: i64 = day - 1;
                if (std.time.epoch.isLeapYear(year) and day >= 60) index += 1;
                break :blk index;
            },
            .day_of_year => |day| day,
            .month_week_day => |rule| blk: {
                const month: Month = @fromBackingInt(@as(u4, @intCast(rule.month)));
                const first_weekday = weekday(.{
                    .year = year,
                    .month = month,
                    .day = 1,
                    .hour = 0,
                    .minute = 0,
                });
                var day: u8 = 1 + (rule.weekday + 7 - first_weekday) % 7 + 7 * (rule.week - 1);
                const days_in_month = std.time.epoch.getDaysInMonth(year, month);
                if (day > days_in_month) day -= 7;

                var index: i64 = day - 1;
                var number: u8 = 1;
                while (number < rule.month) : (number += 1) {
                    const prior: Month = @fromBackingInt(@as(u4, @intCast(number)));
                    index += std.time.epoch.getDaysInMonth(year, prior);
                }
                break :blk index;
            },
        };
        const local = daysFromCivil(year, .jan, 1) * seconds_per_day +
            day_index * seconds_per_day + self.seconds;
        return local - switch (self.basis) {
            .wall => before_offset,
            .standard => standard_offset,
            .utc => 0,
        };
    }
};

const FooterParser = struct {
    source: []const u8,
    index: usize = 0,

    fn done(self: FooterParser) bool {
        return self.index == self.source.len;
    }

    fn peek(self: FooterParser) u8 {
        return if (self.done()) 0 else self.source[self.index];
    }

    fn expect(self: *FooterParser, expected: u8) TimeZoneError!void {
        if (self.peek() != expected) return error.InvalidTzifFooter;
        self.index += 1;
    }

    fn skipName(self: *FooterParser) TimeZoneError!void {
        const start = self.index;
        if (self.peek() == '<') {
            self.index += 1;
            const name_start = self.index;
            while (!self.done() and self.peek() != '>') : (self.index += 1) {}
            if (self.done() or self.index - name_start < 3) return error.InvalidTzifFooter;
            self.index += 1;
            return;
        }
        while (!self.done() and std.ascii.isAlphabetic(self.peek())) : (self.index += 1) {}
        if (self.index - start < 3) return error.InvalidTzifFooter;
    }

    fn parseOffset(self: *FooterParser) TimeZoneError!i32 {
        var sign: i32 = 1;
        if (self.peek() == '+' or self.peek() == '-') {
            if (self.peek() == '-') sign = -1;
            self.index += 1;
        }
        return -sign * try self.parseTime(24);
    }

    fn parseRule(self: *FooterParser) TimeZoneError!TransitionRule {
        var rule: TransitionRule = undefined;
        if (self.peek() == 'J') {
            self.index += 1;
            const day = try self.parseNumber(365);
            if (day == 0) return error.InvalidTzifFooter;
            rule = .{ .day = .{ .julian_no_leap = day } };
        } else if (self.peek() == 'M') {
            self.index += 1;
            const month = try self.parseNumber(12);
            try self.expect('.');
            const week = try self.parseNumber(5);
            try self.expect('.');
            const day = try self.parseNumber(6);
            if (month == 0 or week == 0) return error.InvalidTzifFooter;
            rule = .{ .day = .{ .month_week_day = .{
                .month = @intCast(month),
                .week = @intCast(week),
                .weekday = @intCast(day),
            } } };
        } else {
            rule = .{ .day = .{ .day_of_year = try self.parseNumber(365) } };
        }

        if (self.peek() == '/') {
            self.index += 1;
            var sign: i32 = 1;
            if (self.peek() == '+' or self.peek() == '-') {
                if (self.peek() == '-') sign = -1;
                self.index += 1;
            }
            rule.seconds = sign * try self.parseTime(167);
            switch (self.peek()) {
                's' => {
                    rule.basis = .standard;
                    self.index += 1;
                },
                'u', 'g', 'z' => {
                    rule.basis = .utc;
                    self.index += 1;
                },
                'w' => self.index += 1,
                else => {},
            }
        }
        return rule;
    }

    fn parseTime(self: *FooterParser, maximum_hour: u16) TimeZoneError!i32 {
        const hour = try self.parseNumber(maximum_hour);
        var minute: u16 = 0;
        var second: u16 = 0;
        if (self.peek() == ':') {
            self.index += 1;
            minute = try self.parseNumber(59);
            if (self.peek() == ':') {
                self.index += 1;
                second = try self.parseNumber(59);
            }
        }
        return @as(i32, hour) * 3_600 + @as(i32, minute) * 60 + second;
    }

    fn parseNumber(self: *FooterParser, maximum: u16) TimeZoneError!u16 {
        const start = self.index;
        while (!self.done() and std.ascii.isDigit(self.peek())) : (self.index += 1) {}
        if (self.index == start) return error.InvalidTzifFooter;
        const result = std.fmt.parseUnsigned(u16, self.source[start..self.index], 10) catch
            return error.InvalidTzifFooter;
        if (result > maximum) return error.InvalidTzifFooter;
        return result;
    }
};

fn civilFromUnix(unix_seconds: i64, offset: i32) TimeZoneError!DateTime {
    const local = std.math.add(i64, unix_seconds, offset) catch return error.DateOutOfRange;
    const days = @divFloor(local, seconds_per_day);
    const second_of_day: u32 = @intCast(local - days * seconds_per_day);

    const adjusted = std.math.add(i64, days, 719_468) catch return error.DateOutOfRange;
    const era = @divFloor(adjusted, 146_097);
    const day_of_era = adjusted - era * 146_097;
    const year_of_era = @divFloor(
        day_of_era - @divFloor(day_of_era, 1_460) + @divFloor(day_of_era, 36_524) - @divFloor(day_of_era, 146_096),
        365,
    );
    var year = year_of_era + era * 400;
    const day_of_year = day_of_era - (365 * year_of_era + @divFloor(year_of_era, 4) - @divFloor(year_of_era, 100));
    const month_prime = @divFloor(5 * day_of_year + 2, 153);
    const day = day_of_year - @divFloor(153 * month_prime + 2, 5) + 1;
    const month = month_prime + if (month_prime < 10) @as(i64, 3) else -9;
    year += if (month <= 2) 1 else 0;
    if (year < 1 or year > std.math.maxInt(u16)) return error.DateOutOfRange;

    return .{
        .year = @intCast(year),
        .month = @fromBackingInt(@as(u4, @intCast(month))),
        .day = @intCast(day),
        .hour = @intCast(second_of_day / 3_600),
        .minute = @intCast(second_of_day % 3_600 / 60),
    };
}

fn daysFromCivil(year_value: u16, month_value: Month, day_value: u8) i64 {
    var year: i64 = year_value;
    const month: i64 = month_value.numeric();
    year -= if (month <= 2) 1 else 0;
    const era = @divFloor(year, 400);
    const year_of_era = year - era * 400;
    const month_prime = month + if (month > 2) @as(i64, -3) else 9;
    const day_of_year = @divFloor(153 * month_prime + 2, 5) + day_value - 1;
    const day_of_era = year_of_era * 365 + @divFloor(year_of_era, 4) -
        @divFloor(year_of_era, 100) + day_of_year;
    return era * 146_097 + day_of_era - 719_468;
}

const ParsedField = struct {
    mask: u64,
    star: bool,
};

fn parseField(source: []const u8, minimum: u8, maximum: u8) ParseError!ParsedField {
    if (source.len == 0) return error.InvalidSyntax;

    if (source[0] == '*') {
        if (source.len == 1) return .{ .mask = fullMask(minimum, maximum), .star = true };
        if (source.len < 3 or source[1] != '/' or std.mem.indexOfScalar(u8, source[2..], '/') != null)
            return error.InvalidSyntax;

        const step = try parseStep(source[2..]);
        return .{ .mask = steppedMask(minimum, maximum, step), .star = true };
    }

    var mask: u64 = 0;
    var parts = std.mem.splitScalar(u8, source, ',');
    while (parts.next()) |part| {
        if (part.len == 0) return error.InvalidSyntax;

        const slash = std.mem.indexOfScalar(u8, part, '/');
        const base = if (slash) |index| part[0..index] else part;
        const step = if (slash) |index| blk: {
            if (std.mem.indexOfScalar(u8, part[index + 1 ..], '/') != null) return error.InvalidSyntax;
            break :blk try parseStep(part[index + 1 ..]);
        } else 1;

        if (std.mem.indexOfScalar(u8, base, '-')) |dash| {
            if (std.mem.indexOfScalar(u8, base[dash + 1 ..], '-') != null) return error.InvalidSyntax;
            const start = try parseValue(base[0..dash], minimum, maximum);
            const end = try parseValue(base[dash + 1 ..], minimum, maximum);
            if (start > end) return error.InvalidRange;
            mask |= steppedMask(start, end, step) << @intCast(start - minimum);
        } else {
            if (slash != null) return error.InvalidSyntax;
            const value = try parseValue(base, minimum, maximum);
            mask |= @as(u64, 1) << @intCast(value - minimum);
        }
    }

    return .{ .mask = mask, .star = false };
}

fn parseValue(source: []const u8, minimum: u8, maximum: u8) ParseError!u8 {
    for (source) |byte| if (!std.ascii.isDigit(byte)) return error.InvalidSyntax;
    const value = std.fmt.parseUnsigned(u16, source, 10) catch |err| switch (err) {
        error.InvalidCharacter => return error.InvalidSyntax,
        error.Overflow => return error.ValueOutOfRange,
    };
    if (value < minimum or value > maximum) return error.ValueOutOfRange;
    return @intCast(value);
}

fn parseStep(source: []const u8) ParseError!u16 {
    for (source) |byte| if (!std.ascii.isDigit(byte)) return error.InvalidSyntax;
    const step = std.fmt.parseUnsigned(u16, source, 10) catch |err| switch (err) {
        error.InvalidCharacter => return error.InvalidSyntax,
        error.Overflow => return error.InvalidStep,
    };
    if (step == 0) return error.InvalidStep;
    return step;
}

fn fullMask(minimum: u8, maximum: u8) u64 {
    const width: u8 = maximum - minimum + 1;
    return (@as(u64, 1) << @intCast(width)) - 1;
}

fn steppedMask(minimum: u8, maximum: u8, step: u16) u64 {
    var mask: u64 = 0;
    var value: u16 = minimum;
    while (value <= maximum) {
        mask |= @as(u64, 1) << @intCast(value - minimum);
        if (maximum - value < step) break;
        value += step;
    }
    return mask;
}

fn has(mask: anytype, value: anytype, minimum: u8) bool {
    return mask & (@as(@TypeOf(mask), 1) << @intCast(value - minimum)) != 0;
}

fn weekday(date_time: DateTime) u8 {
    const offsets = [_]u8{ 0, 3, 2, 5, 0, 3, 5, 1, 4, 6, 2, 4 };
    const month: u8 = date_time.month.numeric();
    var year: u32 = date_time.year;
    if (month < 3) year -= 1;
    return @intCast((year + year / 4 - year / 100 + year / 400 + offsets[month - 1] + date_time.day) % 7);
}

fn nextMinute(date_time: DateTime) ?DateTime {
    var next = date_time;
    if (next.minute < 59) {
        next.minute += 1;
        return next;
    }
    next.minute = 0;
    if (next.hour < 23) {
        next.hour += 1;
        return next;
    }
    return nextDay(next);
}

fn nextDay(date_time: DateTime) ?DateTime {
    var next = date_time;
    next.hour = 0;
    next.minute = 0;

    if (next.day < std.time.epoch.getDaysInMonth(next.year, next.month)) {
        next.day += 1;
        return next;
    }
    next.day = 1;

    if (next.month != .dec) {
        next.month = @as(Month, @fromBackingInt(@as(u4, @intCast(next.month.numeric() + 1))));
        return next;
    }
    if (next.year == std.math.maxInt(u16)) return null;
    next.year += 1;
    next.month = .jan;
    return next;
}

const days_per_gregorian_cycle = 146_097;

const TestOutcomes = struct {
    callback_success: std.atomic.Value(u32) = .init(0),
    callback_error: std.atomic.Value(u32) = .init(0),
    skipped_overlap: std.atomic.Value(u32) = .init(0),
    command_exit: std.atomic.Value(i32) = .init(-1),

    fn notify(context: ?*anyopaque, invocation: Invocation, outcome: Outcome) void {
        _ = invocation;
        const self: *TestOutcomes = @ptrCast(@alignCast(context.?));
        switch (outcome) {
            .callback_success => _ = self.callback_success.fetchAdd(1, .monotonic),
            .callback_error => _ = self.callback_error.fetchAdd(1, .monotonic),
            .skipped_overlap => _ = self.skipped_overlap.fetchAdd(1, .monotonic),
            .command_terminated => |term| switch (term) {
                .exited => |code| self.command_exit.store(code, .monotonic),
                else => self.command_exit.store(-2, .monotonic),
            },
            .command_error => self.command_exit.store(-3, .monotonic),
        }
    }

    fn observer(self: *TestOutcomes) Observer {
        return .{ .context = self, .notify = notify };
    }
};

fn successfulTestCallback(_: ?*anyopaque, _: std.Io, _: Invocation) anyerror!void {}

fn failingTestCallback(_: ?*anyopaque, _: std.Io, _: Invocation) anyerror!void {
    return error.ExpectedCallbackFailure;
}

fn blockingTestCallback(_: ?*anyopaque, io: std.Io, _: Invocation) anyerror!void {
    try std.Io.sleep(io, .fromSeconds(60), .awake);
}

fn unixSeconds(year: u16, month: Month, day: u8, hour: u8, minute: u8) i64 {
    return daysFromCivil(year, month, day) * seconds_per_day +
        @as(i64, hour) * 3_600 + @as(i64, minute) * 60;
}

fn fuzzParsers(_: void, smith: *std.testing.Smith) !void {
    var buffer: [256]u8 = undefined;
    const source = buffer[0..smith.slice(&buffer)];
    if (Expression.parse(source)) |_| {} else |_| {}
    if (PosixTimeZone.parse(source)) |_| {} else |_| {}
}

test "cron parsers tolerate arbitrary input" {
    try std.testing.fuzz({}, fuzzParsers, .{ .corpus = &.{
        "* * * * *",
        "CET-1CEST,M3.5.0,M10.5.0/3",
    } });
}

test "parse five-field numeric syntax" {
    const expression = try Expression.parse("*/15 8-12/2 * 1,3 1-5");
    try std.testing.expect(try expression.matches(try DateTime.init(2026, .mar, 2, 10, 30)));
    try std.testing.expect(!try expression.matches(try DateTime.init(2026, .mar, 2, 11, 30)));
    try std.testing.expect(!try expression.matches(try DateTime.init(2026, .mar, 2, 10, 31)));

    try std.testing.expectError(error.InvalidFieldCount, Expression.parse("* * * *"));
    try std.testing.expectError(error.InvalidSyntax, Expression.parse("1/2 * * * *"));
    try std.testing.expectError(error.InvalidSyntax, Expression.parse("1_0 * * * *"));
    try std.testing.expectError(error.ValueOutOfRange, Expression.parse("60 * * * *"));
    try std.testing.expectError(error.InvalidRange, Expression.parse("5-1 * * * *"));
    try std.testing.expectError(error.InvalidStep, Expression.parse("*/0 * * * *"));
}

test "day fields use cron wildcard and OR semantics" {
    const either_day = try Expression.parse("30 4 1,15 * 5");
    try std.testing.expect(try either_day.matches(try DateTime.init(2026, .jan, 1, 4, 30)));
    try std.testing.expect(try either_day.matches(try DateTime.init(2026, .jan, 2, 4, 30)));
    try std.testing.expect(!try either_day.matches(try DateTime.init(2026, .jan, 3, 4, 30)));

    const stepped_star = try Expression.parse("0 0 */2 * 1");
    try std.testing.expect(try stepped_star.matches(try DateTime.init(2026, .jan, 5, 0, 0)));
    try std.testing.expect(!try stepped_star.matches(try DateTime.init(2026, .jan, 12, 0, 0)));
    try std.testing.expect(!try stepped_star.matches(try DateTime.init(2026, .jan, 13, 0, 0)));
}

test "next is exclusive and crosses calendar boundaries" {
    const weekdays = try Expression.parse("*/15 9-17 * * 1-5");
    try std.testing.expectEqual(
        try DateTime.init(2026, .aug, 31, 9, 15),
        (try weekdays.next(try DateTime.init(2026, .aug, 31, 9, 0))).?,
    );
    try std.testing.expectEqual(
        try DateTime.init(2026, .sep, 7, 9, 0),
        (try weekdays.next(try DateTime.init(2026, .sep, 4, 17, 59))).?,
    );

    const leap_day = try Expression.parse("0 0 29 2 *");
    try std.testing.expectEqual(
        try DateTime.init(2024, .feb, 29, 0, 0),
        (try leap_day.next(try DateTime.init(2023, .mar, 1, 0, 0))).?,
    );
}

test "invalid dates and impossible schedules are reported" {
    const daily = try Expression.parse("0 0 * * *");
    const invalid: DateTime = .{ .year = 2026, .month = .feb, .day = 30, .hour = 0, .minute = 0 };
    try std.testing.expectError(error.InvalidDateTime, daily.matches(invalid));
    try std.testing.expectError(error.InvalidDateTime, daily.next(invalid));

    const impossible = try Expression.parse("0 0 31 2 *");
    try std.testing.expectEqual(null, try impossible.next(try DateTime.init(2026, .jan, 1, 0, 0)));
    try std.testing.expectEqual(null, try daily.next(try DateTime.init(std.math.maxInt(u16), .dec, 31, 23, 59)));
}

test "UTC, fixed offsets, and recorded TZif transitions convert calendar minutes" {
    try std.testing.expectEqual(
        try DateTime.init(1970, .jan, 1, 0, 0),
        try TimeZone.utc.toLocal(0),
    );
    try std.testing.expectEqual(
        try DateTime.init(1969, .dec, 31, 23, 59),
        try TimeZone.utc.toLocal(-60),
    );
    const fixed = try TimeZone.fixedOffset(90 * 60);
    try std.testing.expectEqual(
        try DateTime.init(1970, .jan, 1, 1, 30),
        try fixed.toLocal(0),
    );
    _ = try TimeZone.fixedOffset(min_utc_offset);
    _ = try TimeZone.fixedOffset(max_utc_offset);
    try std.testing.expectError(error.InvalidOffset, TimeZone.fixedOffset(min_utc_offset - 1));
    try std.testing.expectError(error.InvalidOffset, TimeZone.fixedOffset(max_utc_offset + 1));

    var timetypes = [_]std.tz.Timetype{
        .{ .offset = 0, .flags = 0, .name_data = .{ 'U', 'T', 'C', 0, 0, 0 } },
        .{ .offset = 3_600, .flags = 1, .name_data = .{ 'D', 'S', 'T', 0, 0, 0 } },
        .{ .offset = 7_200, .flags = 0, .name_data = .{ 'F', 'U', 'T', 0, 0, 0 } },
    };
    var transitions = [_]std.tz.Transition{
        .{ .ts = 3_600, .timetype = &timetypes[1] },
        .{ .ts = 7_200, .timetype = &timetypes[2] },
    };
    const tz: std.Tz = .{
        .allocator = std.testing.allocator,
        .transitions = &transitions,
        .timetypes = &timetypes,
        .leapseconds = &.{},
        .footer = "FUT-2",
    };
    const recorded = try TimeZone.fromTz(&tz);
    try std.testing.expectEqual(3_600, try recorded.offsetAt(3_600));
    try std.testing.expectEqual(3_600, try recorded.offsetAt(7_199));
    try std.testing.expectEqual(7_200, try recorded.offsetAt(7_200));

    const inconsistent_footer: std.Tz = .{
        .allocator = std.testing.allocator,
        .transitions = &transitions,
        .timetypes = &timetypes,
        .leapseconds = &.{},
        .footer = "UTC0",
    };
    try std.testing.expectError(error.InvalidTzifFooter, TimeZone.fromTz(&inconsistent_footer));

    var pre_transition_types = [_]std.tz.Timetype{
        .{ .offset = 3_600, .flags = 1, .name_data = .{ 'D', 'S', 'T', 0, 0, 0 } },
        .{ .offset = 0, .flags = 0, .name_data = .{ 'U', 'T', 'C', 0, 0, 0 } },
    };
    var first_transition = [_]std.tz.Transition{
        .{ .ts = 3_600, .timetype = &pre_transition_types[1] },
    };
    const pre_transition_tz: std.Tz = .{
        .allocator = std.testing.allocator,
        .transitions = &first_transition,
        .timetypes = &pre_transition_types,
        .leapseconds = &.{},
        .footer = "UTC0",
    };
    const pre_transition = try TimeZone.fromTz(&pre_transition_tz);
    try std.testing.expectEqual(3_600, try pre_transition.offsetAt(3_599));
    try std.testing.expectEqual(0, try pre_transition.offsetAt(3_600));

    var leap_transitions = [_]std.tz.Transition{
        .{ .ts = 78_796_801, .timetype = &timetypes[1] },
        .{ .ts = 78_796_900, .timetype = &timetypes[0] },
    };
    const leap_seconds = [_]std.tz.Leapsecond{
        .{ .occurrence = 78_796_800, .correction = 1 },
    };
    const leap_tz: std.Tz = .{
        .allocator = std.testing.allocator,
        .transitions = &leap_transitions,
        .timetypes = &timetypes,
        .leapseconds = &leap_seconds,
        .footer = "UTC0",
    };
    const leap_aware = try TimeZone.fromTz(&leap_tz);
    try std.testing.expectEqual(78_796_799, try unixLeapTime(&leap_tz, 78_796_799));
    try std.testing.expectEqual(78_796_801, try unixLeapTime(&leap_tz, 78_796_800));
    try std.testing.expectEqual(0, try leap_aware.offsetAt(78_796_799));
    try std.testing.expectEqual(3_600, try leap_aware.offsetAt(78_796_800));

    const truncated: std.Tz = .{
        .allocator = std.testing.allocator,
        .transitions = &transitions,
        .timetypes = &timetypes,
        .leapseconds = &.{},
        .footer = null,
    };
    try std.testing.expectError(error.MissingFutureRule, TimeZone.fromTz(&truncated));

    var unsorted_transitions = [_]std.tz.Transition{
        .{ .ts = 7_200, .timetype = &timetypes[0] },
        .{ .ts = 3_600, .timetype = &timetypes[1] },
    };
    const unsorted: std.Tz = .{
        .allocator = std.testing.allocator,
        .transitions = &unsorted_transitions,
        .timetypes = &timetypes,
        .leapseconds = &.{},
        .footer = "UTC0",
    };
    try std.testing.expectError(error.InvalidTzif, TimeZone.fromTz(&unsorted));

    const invalid_leaps = [_]std.tz.Leapsecond{
        .{ .occurrence = 78_796_800, .correction = 1 },
        .{ .occurrence = 78_796_799, .correction = 2 },
    };
    const invalid_leap_tz: std.Tz = .{
        .allocator = std.testing.allocator,
        .transitions = &.{},
        .timetypes = &timetypes,
        .leapseconds = &invalid_leaps,
        .footer = "UTC0",
    };
    try std.testing.expectError(error.InvalidTzif, TimeZone.fromTz(&invalid_leap_tz));
}

test "TZif POSIX rules skip spring gaps and repeat fall wall minutes" {
    try std.testing.expectError(
        error.InvalidTzifFooter,
        PosixTimeZone.parse("STD999999999999999999999999999999999999999"),
    );
    try std.testing.expectError(error.InvalidTzifFooter, PosixTimeZone.parse("<AB\x00C>0"));
    try std.testing.expectError(error.InvalidTzifFooter, PosixTimeZone.parse("<ABC\xff>0"));

    var timetypes = [_]std.tz.Timetype{
        .{ .offset = 3_600, .flags = 0, .name_data = .{ 'C', 'E', 'T', 0, 0, 0 } },
    };
    const tz: std.Tz = .{
        .allocator = std.testing.allocator,
        .transitions = &.{},
        .timetypes = &timetypes,
        .leapseconds = &.{},
        .footer = "CET-1CEST,M3.5.0,M10.5.0/3",
    };
    const paris = try TimeZone.fromTz(&tz);

    try std.testing.expectEqual(
        try DateTime.init(2026, .mar, 29, 1, 59),
        try paris.toLocal(unixSeconds(2026, .mar, 29, 0, 59)),
    );
    try std.testing.expectEqual(
        try DateTime.init(2026, .mar, 29, 3, 0),
        try paris.toLocal(unixSeconds(2026, .mar, 29, 1, 0)),
    );
    const first = try paris.toLocal(unixSeconds(2026, .oct, 25, 0, 30));
    const repeated = try paris.toLocal(unixSeconds(2026, .oct, 25, 1, 30));
    try std.testing.expectEqual(try DateTime.init(2026, .oct, 25, 2, 30), first);
    try std.testing.expectEqual(first, repeated);

    const cross_year_tz: std.Tz = .{
        .allocator = std.testing.allocator,
        .transitions = &.{},
        .timetypes = &timetypes,
        .leapseconds = &.{},
        .footer = "STD0DST,J1/-2,J100/0",
    };
    const cross_year = try TimeZone.fromTz(&cross_year_tz);
    try std.testing.expectEqual(
        0,
        try cross_year.offsetAt(unixSeconds(2025, .dec, 31, 21, 59)),
    );
    try std.testing.expectEqual(
        3_600,
        try cross_year.offsetAt(unixSeconds(2025, .dec, 31, 22, 0)),
    );
}

test "scheduler lifecycle and single-minute callback dispatch" {
    var scheduler = Scheduler.init(std.testing.allocator);
    defer scheduler.deinit();

    const every_minute = try Expression.parse("* * * * *");
    try std.testing.expectError(
        error.InvalidCommand,
        scheduler.add(every_minute, .{ .command = .{ .argv = &.{} } }, .{}),
    );
    try std.testing.expectError(
        error.InvalidCommand,
        scheduler.add(every_minute, .{ .command = .{ .argv = &.{ "echo", "bad\x00argument" } } }, .{}),
    );
    try std.testing.expectError(
        error.InvalidCommand,
        scheduler.add(every_minute, .{ .command = .{ .argv = &.{"echo"}, .cwd = .{ .path = "" } } }, .{}),
    );
    try std.testing.expectError(
        error.InvalidCommand,
        scheduler.add(every_minute, .{ .command = .{ .argv = &.{"echo"}, .cwd = .{ .path = "bad\x00path" } } }, .{}),
    );
    var invalid_environ = std.process.Environ.Map.init(std.testing.allocator);
    defer invalid_environ.deinit();
    try invalid_environ.put("KEY", "bad\x00value");
    try std.testing.expectError(
        error.InvalidCommand,
        scheduler.add(every_minute, .{ .command = .{ .argv = &.{"echo"}, .environ_map = &invalid_environ } }, .{}),
    );
    const success_id = try scheduler.add(
        every_minute,
        .{ .callback = .{ .run = successfulTestCallback } },
        .{},
    );
    const failure_id = try scheduler.add(
        every_minute,
        .{ .callback = .{ .run = failingTestCallback } },
        .{},
    );
    try std.testing.expect(@backingInt(failure_id) > @backingInt(success_id));

    scheduler.running = true;
    try std.testing.expectError(error.Running, scheduler.remove(success_id));
    try std.testing.expectError(
        error.Running,
        scheduler.add(every_minute, .{ .callback = .{ .run = successfulTestCallback } }, .{}),
    );
    scheduler.running = false;

    var outcomes: TestOutcomes = .{};
    var group: std.Io.Group = .init;
    defer group.cancel(std.testing.io);
    try scheduler.dispatchMinute(std.testing.io, &group, 0, outcomes.observer());
    try group.await(std.testing.io);
    try std.testing.expectEqual(1, outcomes.callback_success.load(.monotonic));
    try std.testing.expectEqual(1, outcomes.callback_error.load(.monotonic));

    try std.testing.expect(try scheduler.remove(success_id));
    try std.testing.expect(!(try scheduler.remove(success_id)));
}

test "scheduler applies overlap policies and cancellation cleanup" {
    const every_minute = try Expression.parse("* * * * *");

    var skipped = Scheduler.init(std.testing.allocator);
    defer skipped.deinit();
    _ = try skipped.add(
        every_minute,
        .{ .callback = .{ .run = successfulTestCallback } },
        .{ .overlap = .skip },
    );
    var skipped_outcomes: TestOutcomes = .{};
    var skipped_group: std.Io.Group = .init;
    defer skipped_group.cancel(std.testing.io);
    try skipped.dispatchMinute(std.testing.io, &skipped_group, 0, skipped_outcomes.observer());
    try skipped.dispatchMinute(std.testing.io, &skipped_group, 1, skipped_outcomes.observer());
    try skipped_group.await(std.testing.io);
    try std.testing.expectEqual(1, skipped_outcomes.callback_success.load(.monotonic));
    try std.testing.expectEqual(1, skipped_outcomes.skipped_overlap.load(.monotonic));

    var concurrent = Scheduler.init(std.testing.allocator);
    defer concurrent.deinit();
    _ = try concurrent.add(
        every_minute,
        .{ .callback = .{ .run = successfulTestCallback } },
        .{ .overlap = .concurrent },
    );
    var concurrent_outcomes: TestOutcomes = .{};
    var concurrent_group: std.Io.Group = .init;
    defer concurrent_group.cancel(std.testing.io);
    try concurrent.dispatchMinute(std.testing.io, &concurrent_group, 0, concurrent_outcomes.observer());
    try concurrent.dispatchMinute(std.testing.io, &concurrent_group, 1, concurrent_outcomes.observer());
    try concurrent_group.await(std.testing.io);
    try std.testing.expectEqual(2, concurrent_outcomes.callback_success.load(.monotonic));

    var canceled = Scheduler.init(std.testing.allocator);
    defer canceled.deinit();
    _ = try canceled.add(
        every_minute,
        .{ .callback = .{ .run = blockingTestCallback } },
        .{},
    );
    var canceled_group: std.Io.Group = .init;
    try canceled.dispatchMinute(std.testing.io, &canceled_group, 0, null);
    try std.testing.expect(canceled.jobs.items[0].active.load(.acquire));
    canceled_group.cancel(std.testing.io);
    try std.testing.expect(!canceled.jobs.items[0].active.load(.acquire));

    var run_future = try std.Io.concurrent(
        std.testing.io,
        Scheduler.run,
        .{ &canceled, std.testing.io, null },
    );
    try std.testing.expectError(error.Canceled, run_future.cancel(std.testing.io));
    try std.testing.expect(!canceled.running);
}

test "scheduler reports child process termination" {
    if (!std.process.can_spawn or @import("builtin").os.tag == .windows) return error.SkipZigTest;

    var scheduler = Scheduler.init(std.testing.allocator);
    defer scheduler.deinit();
    _ = try scheduler.add(
        try Expression.parse("* * * * *"),
        .{ .command = .{ .argv = &.{ "/bin/sh", "-c", "exit 7" } } },
        .{},
    );

    var outcomes: TestOutcomes = .{};
    var group: std.Io.Group = .init;
    defer group.cancel(std.testing.io);
    try scheduler.dispatchMinute(std.testing.io, &group, 0, outcomes.observer());
    try group.await(std.testing.io);
    try std.testing.expectEqual(7, outcomes.command_exit.load(.monotonic));
}

test "scheduler cancellation cleans up a running child command" {
    if (!std.process.can_spawn or @import("builtin").os.tag == .windows) return error.SkipZigTest;

    var scheduler = Scheduler.init(std.testing.allocator);
    defer scheduler.deinit();

    var marker_bytes: [12]u8 = undefined;
    std.testing.io.random(&marker_bytes);
    var marker_path_buf: [128]u8 = undefined;
    const marker_path = try std.fmt.bufPrint(
        &marker_path_buf,
        "/tmp/libcron-cancel-{x}.ready",
        .{marker_bytes},
    );
    std.Io.Dir.deleteFileAbsolute(std.testing.io, marker_path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
    defer std.Io.Dir.deleteFileAbsolute(std.testing.io, marker_path) catch {};
    var shell_command_buf: [256]u8 = undefined;
    const shell_command = try std.fmt.bufPrint(
        &shell_command_buf,
        "printf ready > {s}; exec /bin/sleep 60",
        .{marker_path},
    );
    const argv = [_][]const u8{ "/bin/sh", "-c", shell_command };
    _ = try scheduler.add(
        try Expression.parse("* * * * *"),
        .{ .command = .{ .argv = &argv } },
        .{},
    );

    var outcomes: TestOutcomes = .{};
    var group: std.Io.Group = .init;
    defer group.cancel(std.testing.io);
    try scheduler.dispatchMinute(std.testing.io, &group, 0, outcomes.observer());
    try std.testing.expect(scheduler.jobs.items[0].active.load(.acquire));

    var child_started = false;
    for (0..100) |_| {
        if (std.Io.Dir.accessAbsolute(std.testing.io, marker_path, .{})) |_| {
            child_started = true;
            break;
        } else |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        }
        try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
    }
    try std.testing.expect(child_started);

    group.cancel(std.testing.io);
    try std.testing.expect(!scheduler.jobs.items[0].active.load(.acquire));
    try std.testing.expectEqual(-1, outcomes.command_exit.load(.monotonic));
}
