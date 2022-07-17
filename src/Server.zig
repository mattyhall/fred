const std = @import("std");
const ds = @import("ds.zig");
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
view_count: std.atomic.Atomic(u16),

pub fn init(gpa: std.mem.Allocator) Self {
    var server = std.net.StreamServer.init(.{});
    return Self{
        .gpa = gpa,
        .server = server,
        .buffers = std.SinglyLinkedList(Buffer){},
        .views = std.SinglyLinkedList(View){},
        .view_count = std.atomic.Atomic(u16).init(0),
    };
}

fn findOrCreateBuffer(self: *Self, path: []const u8) !*Buffer {
    var node = self.buffers.first;
    while (node) |n| {
        if (n.data.path) |node_path| {
            if (std.mem.eql(u8, node_path, path)) {
                return &n.data;
            }
        }
        node = n.next;
    }

    var new_node = try self.gpa.create(@TypeOf(self.buffers).Node);
    new_node.data = try Buffer.fromFile(self.gpa, path);
    self.buffers.prepend(new_node);
    return &new_node.data;
}

pub fn handle(self: *Self, view: *View, conn: std.net.StreamServer.Connection) !void {
    std.log.debug("got connection", .{});

    var br = std.io.bufferedReader(conn.stream.reader());
    var reader = br.reader();

    const op = try reader.readIntBig(u8);
    if (op != @enumToInt(msg.Op.hello)) {
        conn.stream.close();
        return error.invalid_op;
    }

    view.size.width = try reader.readIntBig(u16);
    view.size.height = try reader.readIntBig(u16);

    const path_len = try reader.readIntBig(u16);
    var path = try self.gpa.alloc(u8, path_len);
    defer self.gpa.free(path);

    var n_read = try reader.read(path);
    if (n_read != path.len) {
        conn.stream.close();
        return error.path_too_short;
    }

    std.log.debug("read hello {}x{}", .{ view.size.width, view.size.height });

    var buf = try self.findOrCreateBuffer(path);
    try view.addBuffer(buf);

    var bw = std.io.bufferedWriter(conn.stream.writer());
    var writer = bw.writer();

    try self.print(writer, view);
    try bw.flush();

    while (true) {
        var poll_fds = [_]std.os.pollfd{
            .{ .fd = view.event_fd, .events = std.os.POLL.IN, .revents = undefined },
            .{ .fd = conn.stream.handle, .events = std.os.POLL.IN, .revents = undefined },
        };
        const events = try std.os.poll(&poll_fds, std.math.maxInt(i32));
        std.debug.assert(events != 0);
        if (events == 0) continue;

        var proc_buf: [8]u8 = undefined;
        if (poll_fds[0].revents & std.os.POLL.IN != 0) {
            std.log.debug("print", .{});
            _ = try std.os.read(view.event_fd, &proc_buf);
            try self.print(writer, view);
            try bw.flush();
        }

        if (poll_fds[1].revents & std.os.POLL.IN != 0) {
            std.log.debug("read", .{});
            if ((try self.read(reader, writer, view)) == .quit) {
                conn.stream.close();
                return;
            }
            try bw.flush();
        }
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

fn read(self: *Self, reader: anytype, writer: anytype, view: *View) !enum { quit, cont } {
    const op = @intToEnum(msg.Op, try reader.readIntBig(u8));
    std.log.debug("handling {}", .{op});
    switch (op) {
        .input => {
            const len = try reader.readIntBig(u8);
            var inp = try self.gpa.alloc(u8, len);
            defer self.gpa.free(inp);

            const n_read = try reader.read(inp);
            if (n_read != inp.len) return error.eof;

            for (inp) |ch| {
                var instructions = (try view.input_handler.handleInput(ch)) orelse continue;
                switch (instructions[0]) {
                    .command => |al| {
                        if (std.mem.eql(u8, "q", al.items)) {
                            const count = self.view_count.fetchSub(1, .AcqRel);
                            std.log.debug("got :q, {} views left including one that sent :q", .{count});
                            if (count == 1) std.os.exit(0);

                            return .quit;
                        }

                        if (std.mem.eql(u8, "w", al.items)) try view.current().buffer.save();

                        if (std.mem.eql(u8, "b", al.items))
                            view.current_buffer = (view.current_buffer + 1) % view.buffers.items.len;

                        if (std.mem.startsWith(u8, al.items, "e") and al.items.len > 2) {
                            const p = al.items[2..];
                            const buf = try self.findOrCreateBuffer(p);
                            try view.addBuffer(buf);
                        }

                        al.deinit();
                    },
                    .split => |dir| {
                        try writer.writeIntBig(u8, @enumToInt(msg.Op.split));
                        try writer.writeIntBig(u8, @enumToInt(dir));
                        const path = view.current().buffer.path orelse unreachable;
                        try writer.writeIntBig(u16, @intCast(u16, path.len));
                        try writer.writeAll(path);
                    },
                    else => try view.handleInstructions(&instructions),
                }
            }

            try self.print(writer, view);
        },
        .resize => {
            view.size.width = try reader.readIntBig(u16);
            view.size.height = try reader.readIntBig(u16);
        },
        .hello, .print, .split => {},
    }

    return .cont;
}

fn connectionThreadMain(server: *Self, conn: std.net.StreamServer.Connection) void {
    var node = server.gpa.create(@TypeOf(server.views).Node) catch |err| {
        std.log.warn("got error whilst creating node {}", .{err});
        return;
    };
    defer server.gpa.destroy(node);

    node.data = View.init(server.gpa);
    server.views.prepend(node);

    defer server.views.remove(node);

    var view = &node.data;

    server.handle(view, conn) catch |err| {
        std.log.warn("got error whilst handling conn: {}", .{err});
    };
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

        _ = self.view_count.fetchAdd(1, .Monotonic);

        var thread = try std.Thread.spawn(.{}, connectionThreadMain, .{ self, conn });
        thread.detach();
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
