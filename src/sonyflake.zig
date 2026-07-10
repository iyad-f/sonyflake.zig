// SPDX-FileCopyrightText: 2026 Iyad
//
// SPDX-License-Identifier: Apache-2.0

//! A distributed unique Id generator inspired by Twitter's Snowflake.
//!
//! By default, a Sonyflake Id is composed of:
//! - 39 bits for timestamp in units of 10 milliseconds
//! - 8 bits for a sequence number
//! - 16 bits for a machine Id

const std = @import("std");
const Io = std.Io;
const time = std.time;
const testing = std.testing;

/// Configuration for Sonyflake.
pub const Settings = struct {
    /// Number of bits allocated for the sequence number. Must be 1 to 30 (inclusive).
    bits_sequence: u5 = 8,

    /// Number of bits allocated for the machine Id. Must be 1 to 30 (inclusive).
    bits_machine_id: u5 = 16,

    /// Smallest unit by which the timestamp advances. Must be at least one millisecond.
    time_unit: Io.Duration = .fromMilliseconds(10),

    /// The epoch from which elapsed time is measured. Must not be in the future.
    start_timestamp: Io.Timestamp,

    /// Machine Id embedded in every generated Id. Must fit in `bits_machine_id` bits.
    machine_id: u30,

    /// Optional predicate to validate `machine_id`. If it returns false, `init`
    /// fails with `error.CheckMachineIdFailed`.
    check_machine_id: ?*const fn (u30) bool = null,
};

/// Errors returned by Sonyflake.
pub const Error = error{
    /// `bits_sequence` is not between 1 and 30 (inclusive).
    InvalidSequenceBits,

    /// A sequence does not fit in `bits_sequence` bits.
    InvalidSequence,

    /// `bits_machine_id` is not between 1 and 30 (inclusive).
    InvalidMachineIdBits,

    /// A machine Id does not fit in `bits_machine_id` bits.
    InvalidMachineId,

    /// `time_unit` is shorter than one millisecond.
    InvalidTimeUnit,

    /// The timestamp bit length (`63 - bits_sequence - bits_machine_id`) is less than 32.
    InvalidTimestampBits,

    /// `start_timestamp` is ahead of the time being measured.
    StartTimestampAhead,

    /// The elapsed time has exhausted the bits allocated to it.
    OverTimeLimit,

    /// The `check_machine_id` predicate rejected the machine Id.
    CheckMachineIdFailed,
};

/// The component parts of a decomposed Sonyflake Id.
pub const DecomposedId = struct {
    /// The number of `time_unit`s elapsed since `start_timestamp`.
    timestamp: u63,
    /// The sequence number.
    sequence: u30,
    /// The machine Id.
    machine_id: u30,
};

/// A distributed unique Id generator.
pub const Sonyflake = struct {
    _io: Io,
    _mutex: Io.Mutex,
    _bits_time: u6,
    _bits_sequence: u5,
    _bits_machine_id: u5,
    _time_unit: i64,
    _start_timestamp: i64,
    _elapsed_time_units: i64,
    _sequence: u30,
    _machine_id: u30,

    const Self = @This();

    /// Creates a `Sonyflake` from `settings`. See `Error` for validation failures.
    pub fn init(io: Io, settings: Settings) Error!Self {
        if (settings.bits_machine_id == 0 or settings.bits_machine_id > 30) {
            return error.InvalidMachineIdBits;
        }

        if (settings.bits_sequence == 0 or settings.bits_sequence > 30) {
            return error.InvalidSequenceBits;
        }

        if (settings.time_unit.toNanoseconds() < time.ns_per_ms) {
            return error.InvalidTimeUnit;
        }

        if (settings.start_timestamp.toNanoseconds() > now(io).toNanoseconds()) {
            return error.StartTimestampAhead;
        }

        const bits_time = @as(u6, 63) - settings.bits_machine_id - settings.bits_sequence;
        if (bits_time < 32) {
            return error.InvalidTimestampBits;
        }

        const machine_id = settings.machine_id;
        if (machine_id >= (@as(u31, 1) << settings.bits_machine_id)) {
            return error.InvalidMachineId;
        }

        if (settings.check_machine_id) |check_machine_id| {
            if (!check_machine_id(machine_id)) {
                return error.CheckMachineIdFailed;
            }
        }

        const sequence: u30 = @intCast((@as(u31, 1) << settings.bits_sequence) - 1);

        var sf = Sonyflake{
            ._io = io,
            ._mutex = .init,
            ._bits_time = bits_time,
            ._bits_sequence = settings.bits_sequence,
            ._bits_machine_id = settings.bits_machine_id,
            ._time_unit = @intCast(settings.time_unit.toNanoseconds()),
            ._start_timestamp = undefined,
            ._elapsed_time_units = 0,
            ._sequence = sequence,
            ._machine_id = machine_id,
        };

        sf._start_timestamp = sf.toInternalTimestamp(settings.start_timestamp);

        return sf;
    }

    /// Returns the next unique Id, blocking until the next time unit if the
    /// sequence is exhausted within the current one.
    pub fn next_id(self: *Self) (Error || Io.Cancelable)!u64 {
        const mask_sequence: u30 = @intCast((@as(u31, 1) << self._bits_sequence) - 1);

        try self._mutex.lock(self._io);
        defer self._mutex.unlock(self._io);

        const current = self.currentElapsedTimeUnits();
        if (self._elapsed_time_units < current) {
            self._elapsed_time_units = current;
            self._sequence = 0;
        } else {
            self._sequence = (self._sequence +% 1) & mask_sequence;
            if (self._sequence == 0) {
                self._elapsed_time_units += 1;
                const overtime = self._elapsed_time_units - current;
                try self.sleep(overtime);
            }
        }

        return try self.toId();
    }

    /// Returns the timestamp at which `id` was generated.
    pub fn toTimestamp(self: *const Self, id: u64) Io.Timestamp {
        const ns = (self._start_timestamp + @as(i64, self.timestampPart(id))) * self._time_unit;
        return Io.Timestamp.fromNanoseconds(ns);
    }

    /// Builds an Id from an explicit `timestamp`, `sequence`, and `machine_id`
    /// instead of the current clock. See `Error` for validation failures.
    pub fn compose(self: *const Self, timestamp: Io.Timestamp, sequence: u30, machine_id: u30) Error!u64 {
        const elapsed_time_units = self.toInternalTimestamp(timestamp) - self._start_timestamp;
        if (elapsed_time_units < 0) {
            return error.StartTimestampAhead;
        }
        if (elapsed_time_units >= @as(i64, 1) << self._bits_time) {
            return error.OverTimeLimit;
        }

        if (sequence >= @as(u31, 1) << self._bits_sequence) {
            return error.InvalidSequence;
        }

        if (machine_id >= @as(u31, 1) << self._bits_machine_id) {
            return error.InvalidMachineId;
        }

        return @as(u64, @intCast(elapsed_time_units)) << (self._bits_sequence + self._bits_machine_id) |
            @as(u64, sequence) << self._bits_machine_id | machine_id;
    }

    /// Splits `id` into its `timestamp`, `sequence`, and `machine_id` parts.
    pub fn decompose(self: *const Self, id: u64) DecomposedId {
        return .{
            .timestamp = self.timestampPart(id),
            .sequence = self.sequencePart(id),
            .machine_id = self.machineIdPart(id),
        };
    }

    fn toInternalTimestamp(self: *const Self, timestamp: Io.Timestamp) i64 {
        const ns: i64 = @intCast(timestamp.toNanoseconds());
        return @divTrunc(ns, self._time_unit);
    }

    fn currentElapsedTimeUnits(self: *const Self) i64 {
        return self.toInternalTimestamp(now(self._io)) - self._start_timestamp;
    }

    fn sleep(self: *const Self, overtime: i64) Io.Cancelable!void {
        const now_ns: i64 = @intCast(now(self._io).toNanoseconds());
        const sleep_ns = overtime * self._time_unit - @rem(now_ns, self._time_unit);
        try self._io.sleep(.fromNanoseconds(sleep_ns), .real);
    }

    fn toId(self: *const Self) Error!u64 {
        if (self._elapsed_time_units >= (@as(i64, 1) << self._bits_time)) {
            return error.OverTimeLimit;
        }

        return @as(u64, @intCast(self._elapsed_time_units)) << (self._bits_sequence + self._bits_machine_id) |
            @as(u64, self._sequence) << self._bits_machine_id | self._machine_id;
    }

    fn timestampPart(self: *const Self, id: u64) u63 {
        return @intCast(id >> (self._bits_sequence + self._bits_machine_id));
    }

    fn sequencePart(self: *const Self, id: u64) u30 {
        const mask_sequence = ((@as(u31, 1) << self._bits_sequence) - 1) << self._bits_machine_id;
        return @intCast((id & mask_sequence) >> self._bits_machine_id);
    }

    fn machineIdPart(self: *const Self, id: u64) u30 {
        const mask_machine_id = (@as(u31, 1) << self._bits_machine_id) - 1;
        return @intCast(id & mask_machine_id);
    }
};

fn now(io: Io) Io.Timestamp {
    return Io.Clock.real.now(io);
}

test "invalid bits time" {
    const io = testing.io;

    const result = Sonyflake.init(
        io,
        .{
            .bits_sequence = 16,
            .bits_machine_id = 16,
            .machine_id = 0,
            .start_timestamp = now(io),
        },
    );
    try testing.expectEqual(error.InvalidTimestampBits, result);
}

test "invalid bits sequence" {
    const io = testing.io;

    const result = Sonyflake.init(
        io,
        .{
            .bits_sequence = 31,
            .machine_id = 0,
            .start_timestamp = now(io),
        },
    );
    try testing.expectEqual(error.InvalidSequenceBits, result);
}

test "invalid bits machine id" {
    const io = testing.io;

    const result = Sonyflake.init(
        io,
        .{
            .bits_machine_id = 31,
            .machine_id = 0,
            .start_timestamp = now(io),
        },
    );
    try testing.expectEqual(error.InvalidMachineIdBits, result);
}

test "invalid time unit" {
    const io = testing.io;

    const result = Sonyflake.init(
        io,
        .{
            .time_unit = .fromNanoseconds(1),
            .machine_id = 0,
            .start_timestamp = now(io),
        },
    );
    try testing.expectEqual(error.InvalidTimeUnit, result);
}

test "start timestamp ahead" {
    const io = testing.io;

    const result = Sonyflake.init(
        io,
        .{
            .machine_id = 0,
            .start_timestamp = now(io).addDuration(.fromMilliseconds(100)),
        },
    );

    try testing.expectEqual(error.StartTimestampAhead, result);
}

test "too large machine id" {
    const io = testing.io;

    const result = Sonyflake.init(
        io,
        .{
            .machine_id = (1 << 16),
            .start_timestamp = now(io),
        },
    );
    try testing.expectEqual(error.InvalidMachineId, result);
}

fn check_machine_id_always_fail(machine_id: u30) bool {
    _ = machine_id;
    return false;
}

test "check machine id failed" {
    const io = testing.io;

    const result = Sonyflake.init(
        io,
        .{
            .check_machine_id = check_machine_id_always_fail,
            .machine_id = 0,
            .start_timestamp = now(io),
        },
    );
    try testing.expectEqual(error.CheckMachineIdFailed, result);
}

fn expectParts(parts: DecomposedId, expected_timestamp: i64, sequence: u30, machine_id: u30) !void {
    try testing.expectEqual(expected_timestamp, @as(i64, parts.timestamp));
    try testing.expectEqual(sequence, parts.sequence);
    try testing.expectEqual(machine_id, parts.machine_id);
}

test "compose and decompose zero values" {
    const io = testing.io;

    const now_ts = now(io);
    const sf = try Sonyflake.init(io, .{
        .time_unit = .fromMilliseconds(1),
        .machine_id = 0,
        .start_timestamp = now_ts,
    });

    const id = try sf.compose(now_ts, 0, 0);
    const expected_timestamp = sf.toInternalTimestamp(now_ts) - sf._start_timestamp;
    try expectParts(sf.decompose(id), expected_timestamp, 0, 0);
}

test "compose and decompose max sequence" {
    const io = testing.io;

    const now_ts = now(io);
    const sf = try Sonyflake.init(io, .{
        .time_unit = .fromMilliseconds(1),
        .machine_id = 0,
        .start_timestamp = now_ts,
    });

    const max_sequence: u30 = @intCast((@as(u31, 1) << sf._bits_sequence) - 1);
    const id = try sf.compose(now_ts, max_sequence, 0);
    const expected_timestamp = sf.toInternalTimestamp(now_ts) - sf._start_timestamp;
    try expectParts(sf.decompose(id), expected_timestamp, max_sequence, 0);
}

test "compose and decompose max machine id" {
    const io = testing.io;

    const now_ts = now(io);
    const sf = try Sonyflake.init(io, .{
        .time_unit = .fromMilliseconds(1),
        .machine_id = 0,
        .start_timestamp = now_ts,
    });

    const max_machine_id: u30 = @intCast((@as(u31, 1) << sf._bits_machine_id) - 1);
    const id = try sf.compose(now_ts, 0, max_machine_id);
    const expected_timestamp = sf.toInternalTimestamp(now_ts) - sf._start_timestamp;
    try expectParts(sf.decompose(id), expected_timestamp, 0, max_machine_id);
}

test "compose and decompose future time" {
    const io = testing.io;

    const now_ts = now(io);
    const future_time = now_ts.addDuration(.fromNanoseconds(time.ns_per_hour));
    const sf = try Sonyflake.init(io, .{
        .time_unit = .fromMilliseconds(1),
        .machine_id = 0,
        .start_timestamp = now_ts,
    });

    const id = try sf.compose(future_time, 0, 0);
    const expected_timestamp = sf.toInternalTimestamp(future_time) - sf._start_timestamp;
    try expectParts(sf.decompose(id), expected_timestamp, 0, 0);
}

test "compose start timestamp ahead" {
    const io = testing.io;

    const now_ts = now(io);
    const sf = try Sonyflake.init(io, .{
        .machine_id = 0,
        .start_timestamp = now_ts,
    });

    const result = sf.compose(now_ts.subDuration(.fromSeconds(1)), 0, 0);
    try testing.expectEqual(error.StartTimestampAhead, result);
}

test "compose over time limit" {
    const io = testing.io;

    const now_ts = now(io);
    const sf = try Sonyflake.init(io, .{
        .time_unit = .fromMilliseconds(1),
        .machine_id = 0,
        .start_timestamp = now_ts,
    });

    const future_time = now_ts.addDuration(.fromNanoseconds(365 * 175 * time.ns_per_day));
    const result = sf.compose(future_time, 0, 0);
    try testing.expectEqual(error.OverTimeLimit, result);
}

test "compose invalid sequence" {
    const io = testing.io;

    const now_ts = now(io);
    const sf = try Sonyflake.init(io, .{
        .machine_id = 0,
        .start_timestamp = now_ts,
    });

    const invalid_sequence: u30 = @intCast(@as(u31, 1) << sf._bits_sequence);
    const result = sf.compose(now_ts, invalid_sequence, 0);
    try testing.expectEqual(error.InvalidSequence, result);
}

test "compose invalid machine id" {
    const io = testing.io;

    const now_ts = now(io);
    const sf = try Sonyflake.init(io, .{
        .machine_id = 0,
        .start_timestamp = now_ts,
    });

    const invalid_machine_id: u30 = @intCast(@as(u31, 1) << sf._bits_machine_id);
    const result = sf.compose(now_ts, 0, invalid_machine_id);
    try testing.expectEqual(error.InvalidMachineId, result);
}

fn generateIds(s: *Sonyflake, out: []u64) (Error || Io.Cancelable)!void {
    for (out) |*id| id.* = try s.next_id();
}

test "next id" {
    const io = testing.io;

    const machine_id = 0;
    var sf = try Sonyflake.init(
        io,
        .{
            .time_unit = .fromMilliseconds(1),
            .machine_id = machine_id,
            .start_timestamp = now(io),
        },
    );

    var previous_id = try sf.next_id();
    var previous_timestamp = sf.timestampPart(previous_id);
    var previous_sequence = sf.sequencePart(previous_id);

    for (0..1000) |_| {
        const current_id = try sf.next_id();
        try testing.expect(current_id > previous_id);
        try testing.expectEqual(machine_id, sf.machineIdPart(current_id));

        const current_timestamp = sf.timestampPart(current_id);
        const current_sequence = sf.sequencePart(current_id);

        if (current_timestamp == previous_timestamp) {
            try testing.expect(current_sequence > previous_sequence);
        } else {
            try testing.expect(current_timestamp > previous_timestamp);
            try testing.expect(current_sequence == 0);
        }

        previous_id = current_id;
        previous_timestamp = current_timestamp;
        previous_sequence = current_sequence;
    }
}

test "next id over time limit" {
    const io = testing.io;

    var sf = try Sonyflake.init(
        io,
        .{
            .machine_id = 0,
            .start_timestamp = now(io),
        },
    );

    const ticks_per_year = @divTrunc(@as(i64, 365 * time.ns_per_day), sf._time_unit);
    sf._start_timestamp -= 175 * ticks_per_year;

    const result = sf.next_id();
    try testing.expectEqual(error.OverTimeLimit, result);
}

test "next id concurrent" {
    const io = testing.io;
    const allocator = testing.allocator;

    const start_timestamp = now(io);
    var sf1 = try Sonyflake.init(
        io,
        .{
            .machine_id = 1,
            .start_timestamp = start_timestamp,
        },
    );
    var sf2 = try Sonyflake.init(
        io,
        .{
            .machine_id = 2,
            .start_timestamp = start_timestamp,
        },
    );

    const task_count = try std.Thread.getCpuCount();
    const ids_per_task = 1000;
    const total_ids = task_count * ids_per_task;

    const ids_buffer = try allocator.alloc(u64, total_ids);
    defer allocator.free(ids_buffer);

    const futures = try allocator.alloc(
        Io.Future((Error || Io.Cancelable)!void),
        task_count,
    );
    defer allocator.free(futures);

    for (0..task_count) |i| {
        const slice = ids_buffer[i * ids_per_task .. (i + 1) * ids_per_task];
        const sf_instance = if (i % 2 == 0) &sf1 else &sf2;
        futures[i] = try io.concurrent(generateIds, .{ sf_instance, slice });
    }

    var first_error: ?(Error || Io.Cancelable) = null;
    for (futures) |*future| {
        future.await(io) catch |err| {
            first_error = first_error orelse err;
        };
    }
    if (first_error) |err| return err;

    var seen_ids = std.AutoHashMap(u64, void).init(allocator);
    defer seen_ids.deinit();

    for (0..task_count) |i| {
        const slice = ids_buffer[i * ids_per_task .. (i + 1) * ids_per_task];
        const sf_instance = if (i % 2 == 0) &sf1 else &sf2;
        const machine_id: u30 = if (i % 2 == 0) 1 else 2;

        var previous_id: u64 = 0;
        for (slice) |id| {
            try testing.expectEqual(machine_id, sf_instance.machineIdPart(id));
            try testing.expect(id > previous_id);
            previous_id = id;

            const result = try seen_ids.getOrPut(id);
            if (result.found_existing) {
                std.debug.print("Duplicate ID found: {d}\n", .{id});
                try testing.expect(false);
            }
        }
    }
}
