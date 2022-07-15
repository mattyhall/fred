const std = @import("std");
const View = @import("View.zig");
const Terminal = @import("Terminal.zig");
const Buffer = @import("Buffer.zig");
const State = @import("State.zig");
const msg = @import("msg.zig");

const Self = @This();

gpa: std.mem.Allocator,
server: std.net.StreamServer,
buffers: std.SinglyLinkedList(Buffer),
views: std.SinglyLinkedList(View),

pub fn init(gpa: std.mem.Allocator) Self {
    var server = std.net.StreamServer.init(.{});
    return Self{
        .gpa = gpa,
        .server = server,
        .buffers = std.SinglyLinkedList(Buffer){},
        .views = std.SinglyLinkedList(View){},
    };
}

pub fn handle(self: *Self, conn: std.net.StreamServer.Connection) !void {
    std.log.debug("got connection", .{});

    var br = std.io.bufferedReader(conn.stream.reader());
    var reader = br.reader();

    const op = try reader.readIntBig(u8);
    if (op != @enumToInt(msg.Op.hello)) {
        conn.stream.close();
        return error.invalid_op;
    }

    const width = try reader.readIntBig(u16);
    const height = try reader.readIntBig(u16);

    const path_len = try reader.readIntBig(u16);
    var path = try self.gpa.alloc(u8, path_len);
    defer self.gpa.free(path);

    var n_read = try reader.read(path);
    if (n_read != path.len) {
        conn.stream.close();
        return error.path_too_short;
    }

    std.log.debug("read hello {}x{}", .{ width, height });

    var buf = b: {
        var node = self.buffers.first;
        while (node) |n| {
            if (n.data.path) |node_path| {
                if (std.mem.eql(u8, node_path, path)) {
                    break :b &n.data;
                }
            }
            node = n.next;
        }

        var new_node = try self.gpa.create(@TypeOf(self.buffers).Node);
        new_node.data = try Buffer.fromFile(self.gpa, path);
        self.buffers.prepend(new_node);
        break :b &new_node.data;
    };

    var node = try self.gpa.create(@TypeOf(self.views).Node);
    defer self.gpa.destroy(node);

    node.data = View.init(self.gpa, width, height);
    self.views.prepend(node);
    defer self.views.remove(node);

    var view = &node.data;
    try view.addBuffer(buf);

    var bw = std.io.bufferedWriter(conn.stream.writer());
    var writer = bw.writer();

    try self.print(writer, view);
    try bw.flush();

    while (true) {
        try self.read(reader, writer, view);
        try bw.flush();
    }
}

fn print(self: *Self, writer: anytype, view: *View) !void {
    var al = std.ArrayList(u8).init(self.gpa);
    defer al.deinit();

    try view.draw(al.writer());

    try writer.writeIntBig(u8, @enumToInt(msg.Op.print));
    try writer.writeIntBig(u32, @intCast(u32, al.items.len));
    try writer.writeAll(al.items);
}

fn read(self: *Self, reader: anytype, writer: anytype, view: *View) !void {
    const op = @intToEnum(msg.Op, try reader.readIntBig(u8));
    std.log.debug("handling {}", .{op});
    switch (op) {
        .input => {
            const len = try reader.readIntBig(u8);
            var buf = try self.gpa.alloc(u8, len);
            defer self.gpa.free(buf);

            const n_read = try reader.read(buf);
            if (n_read != buf.len) return error.eof;

            for (buf) |ch| {
                try view.handleInput(ch);
            }

            try self.print(writer, view);
        },
        .resize => {
            view.size.width = try reader.readIntBig(u16);
            view.size.height = try reader.readIntBig(u16);
        },
        .hello, .print => {},
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

    while (true) {
        var conn = try self.server.accept();
        self.handle(conn) catch |err| {
            std.log.warn("got error whilst handling conn: {}", .{err});
        };
    }
}

fn deinitList(self: *Self, comptime T: type, list: *std.SinglyLinkedList(T)) void {
    var node = list.popFirst();
    while (node) |n| {
        n.data.deinit();
        self.gpa.destroy(n);
        node = list.popFirst();
    }
}

pub fn deinit(self: *Self) void {
    self.server.deinit();
    self.deinitList(View, &self.views);
    self.deinitList(Buffer, &self.buffers);
}
