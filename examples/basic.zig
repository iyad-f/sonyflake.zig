// SPDX-FileCopyrightText: 2026 Iyad
//
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");
const time = std.time;
const sonyflake = @import("sonyflake");

fn check_machine_id(machine_id: u30) bool {
    // for our imaginary application machine Ids greater than 200 are not allowed.
    return machine_id <= 200;
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    // 9 July 2026 at 19:21:30 (UTC), this is the current timestamp when i am writing this.
    const start_timestamp = std.Io.Timestamp.fromNanoseconds(1_783_624_890 * time.ns_per_s);
    const time_unit = std.Io.Duration.fromMilliseconds(1);

    // We are initializing Sonyflake with the default settings of a snowflake.
    var sf = try sonyflake.Sonyflake.init(
        io,
        .{
            .bits_sequence = 12,
            .bits_machine_id = 10,
            .time_unit = time_unit,
            .start_timestamp = start_timestamp,
            .machine_id = 63, // Try setting a value above 200 and see magic!
            .check_machine_id = check_machine_id,
        },
    );

    for (0..10) |i| {
        const id = try sf.next_id();
        std.debug.print("Id {d}: {d}\n", .{ i, id });
    }
}
