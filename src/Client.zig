const std = @import("std");
const Terminal = @import("Terminal.zig");
const input = @import("input.zig");
const msg = @import("msg.zig");

const Self = @This();

gpa: std.mem.Allocator,

pub fn init(gpa: std.mem.Allocator) Self {
    return Self{ .gpa = gpa };
}

pub fn run(self: *Self, session: []const u8, path: []const u8) !void {
    var uds_path = try std.fs.path.join(self.gpa, &.{ "/tmp/fred", session });
    defer self.gpa.free(uds_path);

    var stream: std.net.Stream = undefined;
    while (true) {
        stream = std.net.connectUnixSocket(uds_path) catch {
            std.time.sleep(std.time.ns_per_ms * 10);
            continue;
        };
        break;
    }

    {
        var al = std.ArrayList(u8).init(self.gpa);
        defer al.deinit();

        var writer = al.writer();
        try writer.writeIntBig(u8, @enumToInt(msg.Op.hello));
        try writer.writeIntBig(u8, 80); // width
        try writer.writeIntBig(u8, 80); // height
        try writer.writeIntBig(u16, @intCast(u16, path.len));
        try writer.writeAll(path);

        try stream.writer().writeAll(al.items);
    }

    var stdout = std.io.bufferedWriter(std.io.getStdOut().writer());
    var stdout_writer = stdout.writer();

    var terminal = try Terminal.init();

    {
        var br = std.io.bufferedReader(stream.reader());
        var reader = br.reader();
        if ((try reader.readIntBig(u8)) != @enumToInt(msg.Op.print)) {
            stream.close();
            return error.expected_print;
        }

        const size = try reader.readIntBig(u32);
        {
            var i: u16 = 0;
            while (i < size) : (i += 1) {
                try stdout_writer.writeByte(try reader.readByte());
            }
        }
        try stdout.flush();
    }

    while (true) {
        const inp = terminal.getInput();
        if (inp[0] == 'q') {
            return;
        }
    }

    //    var terminal = try Terminal.init();
    //    var gpa = std.heap.GeneralPurposeAllocator(.{}){ .backing_allocator = std.heap.c_allocator };
    //    var allocator = gpa.allocator();
    //    defer _ = gpa.deinit();
    //
    //    var fred = Fred.init(allocator, terminal);
    //    defer fred.deinit();
    //
    //    try fred.addBuffer(State.init(allocator, &terminal.size, &fred.input_handler, try Buffer.fromFile(allocator, path)));
    //
    //    while (true) {
    //        var poll_fds = [_]std.os.pollfd{
    //            .{ .fd = std.os.STDIN_FILENO, .events = std.os.POLL.IN, .revents = undefined },
    //            .{ .fd = terminal.fd, .events = std.os.POLL.IN, .revents = undefined },
    //        };
    //        const events = try std.os.poll(&poll_fds, std.math.maxInt(i32));
    //        std.debug.assert(events != 0);
    //        if (events == 0) continue;
    //
    //        if (poll_fds[0].revents & std.os.POLL.IN != 0) {
    //            const inp = terminal.getInput();
    //            for (inp) |ch| {
    //                try fred.handleInput(ch);
    //            }
    //
    //            try fred.draw(writer);
    //            try stdout.flush();
    //        }
    //
    //        var proc_buf: [16 * 1024]u8 = undefined;
    //        if (poll_fds[1].revents & (std.os.POLL.IN) != 0) {
    //            _ = try std.os.read(terminal.fd, &proc_buf);
    //
    //            try fred.draw(writer);
    //            try stdout.flush();
    //        }
    //    }
}

pub fn deinit(_: *Self) void {}