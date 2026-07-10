<!--
SPDX-FileCopyrightText: 2026 Iyad

SPDX-License-Identifier: Apache-2.0
-->

# Sonyflake

Sonyflake is a distributed unique Id generator inspired by [Twitter's Snowflake](https://blog.twitter.com/2010/announcing-snowflake).

This project is a Zig implementation inspired by the original [sony/sonyflake](https://github.com/sony/sonyflake).

Sonyflake focuses on lifetime and performance on many host/core environment. So it has a different bit assignment from Snowflake. By default, a Sonyflake Id is composed of:

- 39 bits for timestamp in units of 10 milliseconds
- 8 bits for a sequence number
- 16 bits for a machine Id

As a result, Sonyflake has the following advantages and disadvantages:

- The lifetime (174 years) is longer than that of snowflake (69 years)
- It can work in more distributed machines (2^16) than Snowflake (2^10)
- It can generate 2^8 Ids per 10 milliseconds at most in a single instance (fewer than Snowflake)

However, if you want more generation rate in a single host, you can easily run multiple Sonyflake instances concurrently using an Io backend which supports concurrency. In addition, you can adjust the lifetime and generation rate of Sonyflake by customizing the bit assignment and the time unit.

## Installation

```sh
zig fetch --save https://github.com/iyad-f/sonyflake.zig
```

## Usage

```zig
const std = @import("std");
const process = std.process;
const time = std.time;
const debug = std.debug;
const Io = std.Io;

const sonyflake = @import("sonyflake");

pub fn main(init: process.Init) !void {
    const io = init.io;

    var sf = try sonyflake.Sonyflake.init(
        io,
        .{
            .machine_id = 63,
            .start_timestamp = Io.Timestamp.fromNanoseconds(1_783_624_890 * time.ns_per_s),
        },
    );

    const id = try sf.next_id();
    debug.print("{d}\n", .{id});
}
```

`Sonyflake.init` creates a new instance from an `Io` implementation and a `Settings` struct:

```zig
pub fn init(io: Io, settings: Settings) Error!Sonyflake
```

The `io` is stored and used for the instance's lifetime by the methods that need it, this has to be the case instead of each of those methods accepting `io` as a separate argument, because the implementation relies on a mutex, clock reads and sleep, and each of these has to keep using the same `Io` implementation the whole time, otherwise you can end up with unexpected results. For the clock this is because different `Io` implementations can define it differently, so timestamps read through one implementation won't necessarily line up with timestamps read through another. The mutex is similar, the blocking and waking of whatever is waiting on it is handled by the `Io` implementation it was used with, so a different implementation just won't coordinate with it and the synchronization that keeps concurrent `next_id` calls safe would break. An easier analogy to understand this would be allocating with one allocator but freeing with another, it just doesn't work.

You can configure Sonyflake with the `Settings` struct:

```zig
pub const Settings = struct {
    bits_sequence: u5 = 8,
    bits_machine_id: u5 = 16,
    time_unit: Io.Duration = .fromMilliseconds(10),
    start_timestamp: Io.Timestamp,
    machine_id: u30,
    check_machine_id: ?*const fn (u30) bool = null,
};
```

- `bits_sequence` is the bit length of the sequence number. It defaults to 8 and must be between 1 and 30.
- `bits_machine_id` is the bit length of the machine Id. It defaults to 16 and must be between 1 and 30.
- `time_unit` is the time unit of Sonyflake. It defaults to 10 msec and must be at least 1 msec.
- `start_timestamp` is the epoch from which the Sonyflake time is measured as elapsed time. It is required and must be before the current time.
- `machine_id` is the machine id embedded in every generated id. It is required and must fit in `bits_machine_id` bits.
- `check_machine_id` validates the machine id. If it returns false, `init` fails with `error.CheckMachineIdFailed`. If it is `null` (the default), no validation is done.

The bit length of the timestamp is calculated by `63 - bits_sequence - bits_machine_id`. If it is less than 32, `init` returns `error.InvalidTimestampBits`.

To get a new unique id, call `next_id`:

```zig
pub fn next_id(self: *Self) (Error || Io.Cancelable)!u64
```

If the sequence is exhausted within the current time unit, `next_id` blocks until the next one. It can keep generating ids for about 174 years from `start_timestamp` by default, but once the Sonyflake time exceeds the limit, `next_id` returns `error.OverTimeLimit`.

## Development

Requires [Zig](https://ziglang.org) 0.16.0.

- Run the tests: `zig build test`
- Compile the examples: `zig build examples` (run one with `zig build example-<name>`, e.g. `zig build example-basic`)
- Install the git hooks: `pre-commit install`

## License

Licensed under the [Apache License, Version 2.0](LICENSE).
