/// "Wake up" an event loop from any thread using an async completion.
pub const Async = @This();

const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const os = std.os;
const xev = @import("main.zig");

/// eventfd file descriptor
fd: os.fd_t,

/// Create a new async. An async can be assigned to exactly one loop
/// to be woken up.
pub fn init() !Async {
    return .{
        .fd = try std.os.eventfd(0, 0),
    };
}

pub fn deinit(self: *Async) void {
    std.os.close(self.fd);
}

/// Wait for a message on this async. Note that async messages may be
/// coalesced (or they may not be) so you should not expect a 1:1 mapping
/// between send and wait.
///
/// Just like the rest of libxev, the wait must be re-queued if you want
/// to continue to be notified of async events.
///
/// You should NOT register an async with multiple loops (the same loop
/// is fine -- but unnecessary). The behavior when waiting on multiple
/// loops is undefined.
pub fn wait(
    self: Async,
    loop: *xev.Loop,
    c: *xev.Completion,
    userdata: ?*anyopaque,
    comptime cb: *const fn (ud: ?*anyopaque, c: *xev.Completion, r: xev.Result) void,
) void {
    c.* = .{
        .op = .{
            .read = .{
                .fd = self.fd,
                .buffer = .{ .array = undefined },
            },
        },
        .userdata = userdata,
        .callback = cb,
    };

    loop.add(c);
}

/// Notify a loop to wake up synchronously. This should never block forever
/// (it will always EVENTUALLY succeed regardless of if the loop is currently
/// ticking or not).
///
/// Internal details subject to change but if you're relying on these
/// details then you may want to consider using a lower level interface
/// using the loop directly:
///
///   - linux+io_uring: eventfd is used. If the eventfd write would block
///     (EAGAIN) then we assume success because the eventfd is full.
///
pub fn notify(self: Async) !void {
    // We want to just write "1" in the correct byte order as our host.
    const val = @bitCast([8]u8, @as(u64, 1));
    _ = os.write(self.fd, &val) catch |err| switch (err) {
        error.WouldBlock => return,
        else => return err,
    };
}

test "async" {
    const testing = std.testing;
    _ = testing;

    var loop = try xev.Loop.init(16);
    defer loop.deinit();

    var notifier = try init();
    defer notifier.deinit();

    // Wait
    var wake: bool = false;
    var c_wait: xev.Completion = undefined;
    notifier.wait(&loop, &c_wait, &wake, (struct {
        fn callback(ud: ?*anyopaque, c: *xev.Completion, r: xev.Result) void {
            _ = c;
            _ = r.read catch unreachable;
            const ptr = @ptrCast(*bool, @alignCast(@alignOf(bool), ud.?));
            ptr.* = true;
        }
    }).callback);

    // Send a notification
    try notifier.notify();

    // Wait for wake
    while (!wake) try loop.tick();
}

test "async: notify first" {
    const testing = std.testing;
    _ = testing;

    var loop = try xev.Loop.init(16);
    defer loop.deinit();

    var notifier = try init();
    defer notifier.deinit();

    // Send a notification
    try notifier.notify();

    // Wait
    var wake: bool = false;
    var c_wait: xev.Completion = undefined;
    notifier.wait(&loop, &c_wait, &wake, (struct {
        fn callback(ud: ?*anyopaque, c: *xev.Completion, r: xev.Result) void {
            _ = c;
            _ = r.read catch unreachable;
            const ptr = @ptrCast(*bool, @alignCast(@alignOf(bool), ud.?));
            ptr.* = true;
        }
    }).callback);

    // Wait for wake
    while (!wake) try loop.tick();
}