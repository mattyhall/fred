const std = @import("std");
const ds = @import("ds.zig");
const Terminal = @import("Terminal.zig");
const input = @import("input.zig");
const msg = @import("msg.zig");

const Self = @This();

gpa: std.mem.Allocator,
stream: std.net.Stream = undefined,
terminal: *Terminal = undefined,
session: []const u8 = undefined,

pub fn init(gpa: std.mem.Allocator) Self {
    return Self{ .gpa = gpa };
}

pub fn run(self: *Self, session: []const u8, path: []const u8) !void {
    self.session = session;

    var uds_path = try std.fs.path.join(self.gpa, &.{ "/tmp/fred", session });
    defer self.gpa.free(uds_path);

    var stdout = std.io.bufferedWriter(std.io.getStdOut().writer());
    var stdout_writer = stdout.writer();

    while (true) {
        self.stream = std.net.connectUnixSocket(uds_path) catch {
            std.time.sleep(std.time.ns_per_ms * 10);
            continue;
        };
        break;
    }

    self.terminal = try Terminal.init();

    std.log.debug("sending hello", .{});
    {
        var al = std.ArrayList(u8).init(self.gpa);
        defer al.deinit();

        var writer = al.writer();
        try writer.writeIntBig(u8, @enumToInt(msg.Op.hello));
        try writer.writeIntBig(u16, @intCast(u16, self.terminal.size.width));
        try writer.writeIntBig(u16, @intCast(u16, self.terminal.size.height));
        try writer.writeIntBig(u16, @intCast(u16, path.len));
        try writer.writeAll(path);

        try self.stream.writer().writeAll(al.items);
    }

    var br = std.io.bufferedReader(self.stream.reader());
    var reader = br.reader();

    {
        if ((try reader.readIntBig(u8)) != @enumToInt(msg.Op.print)) {
            self.stream.close();
            return error.expected_print;
        }

        try self.readPrint(reader, stdout_writer);
        try stdout.flush();
    }

    while (true) {
        var poll_fds = [_]std.os.pollfd{
            .{ .fd = std.os.STDIN_FILENO, .events = std.os.POLL.IN, .revents = undefined },
            .{ .fd = self.terminal.fd, .events = std.os.POLL.IN, .revents = undefined },
            .{ .fd = self.stream.handle, .events = std.os.POLL.IN, .revents = undefined },
        };
        const events = try std.os.poll(&poll_fds, std.math.maxInt(i32));
        std.debug.assert(events != 0);
        if (events == 0) continue;

        std.log.debug("polled", .{});

        if (poll_fds[0].revents & std.os.POLL.IN != 0) {
            const inp = self.terminal.getInput();
            std.log.debug("terminal input {s}", .{inp});

            try self.sendInput(inp);
        }

        var proc_buf: [16 * 1024]u8 = undefined;
        if (poll_fds[1].revents & std.os.POLL.IN != 0) {
            std.log.debug("resize", .{});
            _ = try std.os.read(self.terminal.fd, &proc_buf);
            try self.sendResize();
        }

        if ((poll_fds[2].revents & std.os.POLL.IN != 0) or br.fifo.readableLength() > 0) {
            std.log.debug("stream readable", .{});
            self.read(reader, stdout_writer) catch |err| {
                switch (err) {
                    error.EndOfStream => return,
                    else => return err,
                }
            };
            try stdout.flush();
        }
    }
}

fn readPrint(self: *Self, reader: anytype, stdout_writer: anytype) !void {
    _ = self;

    const size = try reader.readIntBig(u32);
    std.log.debug("print buf is {}", .{size});
    {
        var i: u16 = 0;
        while (i < size) : (i += 1) {
            try stdout_writer.writeByte(try reader.readByte());
        }
    }
}

fn read(self: *Self, reader: anytype, writer: anytype) !void {
    const op = @intToEnum(msg.Op, try reader.readIntBig(u8));
    switch (op) {
        .print => try self.readPrint(reader, writer),
        .split => try self.readSplit(reader),
        .hello, .resize, .input => {},
    }
}

fn readSplit(self: *Self, reader: anytype) !void {
    const dir = @intToEnum(ds.Direction, try reader.readIntBig(u8));

    var path = try self.gpa.alloc(u8, try reader.readIntBig(u16));
    defer self.gpa.free(path);

    const n_read = try reader.read(path);
    if (n_read != path.len) return error.EndOfStream;

    const argv = b: {
        var args = &[_][]const u8{
            "tmux",
            "split-window",
            "-h",
            "fred",
            "-s",
            self.session,
            path,
        };
        if (dir == .vertical) break :b args;

        // Remove the "-h"
        var i: usize = 2;
        while (i < args.len - 1) : (i += 1) {
            args[i] = args[i+1];
        }
        break :b args[0..args.len-1];
    };

    var proc = std.ChildProcess.init(argv, self.gpa);
    try proc.spawn();
}

fn sendResize(self: *Self) !void {
    var buffered = std.io.bufferedWriter(self.stream.writer());
    var writer = buffered.writer();

    try writer.writeIntBig(u8, @enumToInt(msg.Op.resize));
    try writer.writeIntBig(u16, @intCast(u16, self.terminal.size.width));
    try writer.writeIntBig(u16, @intCast(u16, self.terminal.size.height));

    try buffered.flush();
}

fn sendInput(self: *Self, inp: []const u8) !void {
    var buffered = std.io.bufferedWriter(self.stream.writer());
    var writer = buffered.writer();

    try writer.writeIntBig(u8, @enumToInt(msg.Op.input));
    try writer.writeIntBig(u8, @intCast(u8, inp.len));
    try writer.writeAll(inp);

    try buffered.flush();
}

pub fn deinit(_: *Self) void {}
