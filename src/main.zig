const std = @import("std");
const lcg = @import("lcg.zig");
const pinger = @import("pinger.zig");
const IoUring = std.os.linux.IoUring;

const Connection = struct {
    socket: std.posix.socket_t,
    addr: std.net.Ip4Address,
};

pub const connect_timeout = std.os.linux.kernel_timespec{
    .tv_sec = 0,
    .tv_nsec = std.time.ns_per_ms * 500,
};

pub const rw_timeout = std.posix.timeval{
    .tv_sec = 0,
    .tv_usec = std.time.us_per_ms * 500,
};

pub const max_connections = 1600;

pub var output_directory: std.fs.Dir = undefined;

pub fn main() !void {
    output_directory = try std.fs.cwd().makeOpenPath("output", .{});
    const allocator = std.heap.c_allocator;

    var pool = try std.heap.MemoryPoolExtra(Connection, .{ .growable = false }).initPreheated(allocator, max_connections);
    var ring = try IoUring.init(std.math.ceilPowerOfTwoAssert(u16, max_connections * 2), 0);
    var ips = lcg.FullCycleLCG(u32).init(std.crypto.random);
    var cqes: [64]std.os.linux.io_uring_cqe = undefined;

    while (true) {
        while (pool.create() catch null) |conn| {
            const ip: [4]u8 = @bitCast(std.mem.nativeToBig(u32, ips.next()));

            conn.* = Connection{
                .socket = try std.posix.socket(std.posix.AF.INET, std.posix.SOCK.STREAM, 0),
                .addr = std.net.Ip4Address.init(ip, 25565),
            };

            var sqe = try ring.connect(@intFromPtr(conn), conn.socket, @ptrCast(&conn.addr.sa), conn.addr.getOsSockLen());
            sqe.flags |= std.os.linux.IOSQE_IO_LINK;
            _ = try ring.link_timeout(0, &connect_timeout, 0);
        }

        _ = try ring.submit_and_wait(0);

        const num_copied = try ring.copy_cqes(&cqes, 1);
        for (cqes[0..num_copied]) |cqe| {
            const conn = @as(?*align(8) Connection, @ptrFromInt(cqe.user_data)) orelse continue;
            defer pool.destroy(conn);
            switch (cqe.err()) {
                .SUCCESS => (try std.Thread.spawn(.{}, pinger.ping, .{ allocator, conn.addr, conn.socket })).detach(),
                else => std.posix.close(conn.socket),
            }
        }
    }
}
