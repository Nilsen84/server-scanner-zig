const std = @import("std");
const root = @import("root");

fn formatIp(data: std.net.Ip4Address, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
    _ = fmt;
    _ = options;
    const ip: *const [4]u8 = @ptrCast(&data.sa.addr);
    try std.fmt.format(writer, "{}.{}.{}.{}", .{ ip[0], ip[1], ip[2], ip[3] });
}

fn ipFormatter(addr: std.net.Ip4Address) std.fmt.Formatter(formatIp) {
    return .{ .data = addr };
}

fn readVarInt(reader: anytype) !i32 {
    var res: i32 = 0;

    comptime var position: i32 = 0;
    inline while (position < 32) : (position += 7) {
        const byte = try reader.readByte();
        res |= @as(i32, byte & 0x7F) << position;
        if ((byte & 0x80) == 0) return res;
    }

    return error.VarIntTooBig;
}

fn tryPing(allocator: std.mem.Allocator, stream: std.net.Stream) ![]const u8 {
    try std.posix.setsockopt(stream.handle, std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO, &std.mem.toBytes(root.rw_timeout));
    try std.posix.setsockopt(stream.handle, std.posix.SOL.SOCKET, std.posix.SO.SNDTIMEO, &std.mem.toBytes(root.rw_timeout));

    const data = [_]u8{
        19, // length
        0x00, // packet id: 0
        0xFF, 0xFF, 0xFF, 0xFF, 0x0F, // version: -1
        9, 'l', 'o', 'c', 'a', 'l', 'h', 'o', 's', 't', // address: "localhost"
        0x63, 0xDD, // port: 25565
        0x01, // next state: status
        0x01, 0x00, // status request packet
    };

    try stream.writeAll(&data);

    var reader = stream.reader();
    _ = try readVarInt(reader);
    if (try readVarInt(reader) != 0x00) return error.InvalidPacketId;

    const len: u32 = @bitCast(try readVarInt(reader));
    if (len > std.math.maxInt(u16)) return error.StringTooBig;
    const str = try allocator.alloc(u8, len);
    try reader.readNoEof(str);

    return str;
}

fn save(addr: std.net.Ip4Address, response: *std.json.ObjectMap) !void {
    var buf: ["255.255.255.255.json".len + 1]u8 = undefined;
    const filename = std.fmt.bufPrintZ(&buf, "{}.json", .{ipFormatter(addr)}) catch unreachable;
    const file = try root.output_directory.createFileZ(filename, .{});
    defer file.close();

    var jws = std.json.writeStream(file.writer(), .{ .whitespace = .indent_4 });
    defer jws.deinit();

    try jws.beginObject();
    try jws.objectField("address");
    try jws.write(buf[0 .. filename.len - 5]);

    inline for (.{ "version", "players", "description" }) |key| {
        if (response.fetchSwapRemove(key)) |entry| {
            try jws.objectField(entry.key);
            try jws.write(entry.value);
        }
    }

    var it = response.iterator();
    while (it.next()) |entry| {
        try jws.objectField(entry.key_ptr.*);
        try jws.write(entry.value_ptr.*);
    }

    try jws.endObject();
}

pub fn ping(allocator: std.mem.Allocator, addr: std.net.Ip4Address, sock: std.posix.socket_t) void {
    const stream = std.net.Stream{ .handle = sock };
    defer stream.close();

    const response = tryPing(allocator, stream) catch |err| {
        std.debug.print("failed to ping {}: {s}\n", .{ ipFormatter(addr), @errorName(err) });
        return;
    };
    defer allocator.free(response);

    var json = std.json.parseFromSlice(std.json.Value, allocator, response, .{ .allocate = .alloc_if_needed }) catch |err| {
        std.debug.print("failed to parse response from {}: {s}\n", .{ ipFormatter(addr), @errorName(err) });
        return;
    };
    defer json.deinit();

    const obj = switch (json.value) {
        .object => |*obj| obj,
        else => |val| {
            std.debug.print("json {s} returned from {}: expected object", .{ @tagName(val), ipFormatter(addr) });
            return;
        },
    };

    if (save(addr, obj)) {
        std.debug.print("successfully pinged {}\n", .{ipFormatter(addr)});
    } else |err| {
        std.debug.print("failed to save reponse from {}: {s}\n", .{ ipFormatter(addr), @errorName(err) });
    }
}
