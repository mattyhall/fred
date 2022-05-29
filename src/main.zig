const std = @import("std");
const Terminal = @import("Terminal.zig");

pub const Buffer = struct {
    gpa: std.mem.Allocator,
    data: std.ArrayListUnmanaged(u8),
    lines: std.ArrayListUnmanaged(u32),

    const Self = @This();

    pub const LineIterator = struct {
        lines: []u32,
        data: []u8,
        i: u32,

        pub fn next(self: *LineIterator) ?[]u8 {
            if (self.i >= self.lines.len) return null;
            const slice = if (self.i == self.lines.len - 1)
                self.data[self.lines[self.i]..]
            else
                self.data[self.lines[self.i] .. self.lines[self.i + 1] - 1];
            self.i += 1;
            return slice;
        }
    };

    pub fn fromFile(allocator: std.mem.Allocator, path: []const u8) !Self {
        var f = try std.fs.cwd().openFile(path, .{});
        defer f.close();

        var data = try f.readToEndAlloc(allocator, 2 * 1024 * 1024);
        return Self{
            .gpa = allocator,
            .data = std.ArrayListUnmanaged(u8){ .items = data, .capacity = data.len },
            .lines = std.ArrayListUnmanaged(u32){},
        };
    }

    pub fn fromSlice(allocator: std.mem.Allocator, data: []u8) Self {
        return Self{
            .gpa = allocator,
            .data = std.ArrayListUnmanaged(u8){ .items = data, .capacity = data.len },
            .lines = std.ArrayListUnmanaged(u32){},
        };
    }

    pub fn calculateLines(self: *Self) !void {
        self.lines.clearRetainingCapacity();
        if (self.data.items.len > 0) try self.lines.append(self.gpa, 0);
        for (self.data.items) |ch, i| {
            if (ch == '\n' and i < self.data.items.len - 1) {
                try self.lines.append(self.gpa, @intCast(u32, i + 1));
            }
        }
    }

    pub fn lineIterator(self: *const Self) LineIterator {
        return .{ .lines = self.lines.items, .data = self.data.items, .i = 0 };
    }

    pub fn deinit(self: *Self) void {
        self.data.deinit(self.gpa);
        self.lines.deinit(self.gpa);
    }
};

pub fn draw(buf: *const Buffer, lines: u32) !void {
    _ = buf;
    var stdout = std.io.bufferedWriter(std.io.getStdOut().writer());
    var writer = stdout.writer();

    _ = try writer.write("\x1b[1;1H");
    _ = try writer.write("\x1b[0J");

    {
        var iter = buf.lineIterator();
        var i: u32 = 0;
        while (iter.next()) |line| {
            if (i >= lines) break;
            _ = try writer.write(line);
            _ = try writer.write("\x1b[1E");
            i += 1;
        }
    }

    try stdout.flush();
}

pub fn main() anyerror!void {
    var terminal = try Terminal.init();
    var gpa = std.heap.GeneralPurposeAllocator(.{}){ .backing_allocator = std.heap.c_allocator };
    var allocator = gpa.allocator();
    defer _ = gpa.deinit();

    var buffer = try Buffer.fromFile(allocator, "../zig/src/main.zig");
    defer buffer.deinit();
    try buffer.calculateLines();

    try draw(&buffer, terminal.height);

    while (true) {
        var poll_fds = [_]std.os.pollfd{
            .{ .fd = std.os.STDIN_FILENO, .events = std.os.POLL.IN, .revents = undefined },
            .{ .fd = terminal.fd, .events = std.os.POLL.IN, .revents = undefined },
        };
        const events = try std.os.poll(&poll_fds, std.math.maxInt(i32));
        std.debug.assert(events != 0);
        if (events == 0) continue;

        if (poll_fds[0].revents & std.os.POLL.IN != 0) {
            const input = terminal.getInput();
            for (input) |ch| {
                if (ch == 'q') std.os.exit(0);
            }
        }

        var proc_buf: [16 * 1024]u8 = undefined;
        if (poll_fds[1].revents & (std.os.POLL.IN) != 0) {
            _ = try std.os.read(terminal.fd, &proc_buf);
            try draw(&buffer, terminal.height);
        }
    }
}

test "buffer line iterator" {
    var gpa = std.testing.allocator;
    const lit = "hello\nworld\nhow\nare\nyou\ntoday";
    var data = try gpa.alloc(u8, lit.len);
    std.mem.copy(u8, data, lit);

    var buf = Buffer.fromSlice(gpa, data);
    defer buf.deinit();
    try buf.calculateLines();

    try std.testing.expectEqualSlices(u32, &.{0, 6, 12, 16, 20, 24}, buf.lines.items);

    var iter = buf.lineIterator();
    try std.testing.expectEqualStrings("hello", iter.next().?);
    try std.testing.expectEqualStrings("world", iter.next().?);
    try std.testing.expectEqualStrings("how", iter.next().?);
    try std.testing.expectEqualStrings("are", iter.next().?);
    try std.testing.expectEqualStrings("you", iter.next().?);
    try std.testing.expectEqualStrings("today", iter.next().?);
    try std.testing.expectEqual(@as(?[]u8, null), iter.next());
}
