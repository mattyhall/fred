const std = @import("std");
const Fred = @import("Fred.zig");
const Terminal = @import("Terminal.zig");
const Buffer = @import("Buffer.zig");
const State = @import("State.zig");
const msg = @import("msg.zig");

const Self = @This();

gpa: std.mem.Allocator,
server: std.net.StreamServer,
size: Terminal.Size,

pub fn init(gpa: std.mem.Allocator) Self {
    var server = std.net.StreamServer.init(.{});
    return Self{ .gpa = gpa, .server = server, .size = .{ .width = 80, .height = 80} };
}

pub fn handle(self: *Self, fred: *Fred, conn: std.net.StreamServer.Connection) !void {
    var buf: [1024 * 16]u8 = undefined;
    var read = try conn.stream.read(&buf);
    var pkt = buf[0..read];

    var fbs = std.io.fixedBufferStream(pkt);
    var reader = fbs.reader();

    const op = try reader.readIntBig(u8);
    if (op != @enumToInt(msg.Op.hello)) {
        conn.stream.close();
        return error.invalid_op;
    }

    self.size.width = try reader.readIntBig(u16);
    self.size.height = try reader.readIntBig(u16);

    const path_len = try reader.readIntBig(u16);
    var path = try self.gpa.alloc(u8, path_len);
    defer self.gpa.free(path);

    read = try reader.read(path);
    if (read != path.len) {
        conn.stream.close();
        return error.path_too_short;
    }

    try fred.addBuffer(State.init(self.gpa, &self.size, &fred.input_handler, try Buffer.fromFile(self.gpa, path)));

    var al = std.ArrayList(u8).init(self.gpa);
    try fred.draw(al.writer());

    var bw = std.io.bufferedWriter(conn.stream.writer());
    var writer = bw.writer();
    try writer.writeIntBig(u8, @enumToInt(msg.Op.print));
    try writer.writeIntBig(u32, @intCast(u32, al.items.len));
    try writer.writeAll(al.items);
    try bw.flush();

    while (true) {
        read = try conn.stream.read(&buf);
    }
}

pub fn listen(self: *Self, session: []const u8) !void {
    std.os.mkdir("/tmp/fred/", 0o777) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    var path = try std.fs.path.join(self.gpa, &.{ "/tmp/fred/", session });
    defer self.gpa.free(path);

    std.os.unlink(path) catch {};

    try self.server.listen(try std.net.Address.initUnix(path));

    var fred = Fred.init(self.gpa, &self.size);
    defer fred.deinit();

    while (true) {
        var conn = try self.server.accept();
        try self.handle(&fred, conn);
    }
}

pub fn deinit(self: *Self) void {
    self.server.deinit();
}
