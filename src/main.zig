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
        return fromSlice(allocator, data);
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

pub const Position = struct { x: u32, y: u32 };
pub const Cursor = struct {
    pos: Position,

    fn draw(self: Cursor, writer: anytype) !void {
        _ = try writer.print("\x1b[{};{}H", .{ self.pos.y + 1, self.pos.x + 1 });
    }
};

pub const Movement = union(enum) {
    up,
    down,
    left,
    right,
};

pub const Mode = union(enum) { normal, insert, command };

pub const State = struct {
    cursor: Cursor = .{ .pos = .{ .x = 0, .y = 0 } },
    offset: Position = .{ .x = 0, .y = 0 },

    pub fn move(self: *State, movement: Movement) void {
        switch (movement) {
            .up => self.cursor.pos.y -= 1,
            .down => self.cursor.pos.y += 1,
            .left => self.cursor.pos.x -= 1,
            .right => self.cursor.pos.x += 1,
        }
    }
};

pub const InputHandler = struct {
    mode: Mode = .normal,

    pub fn handleInput(self: *InputHandler, c: u8) ?Movement {
        return switch (self.mode) {
            .normal => switch (c) {
                'j' => Movement.down,
                'k' => Movement.up,
                'l' => Movement.right,
                'h' => Movement.left,
                else => return null,
            },
            else => return null,
        };
    }
};

pub fn draw(writer: anytype, buf: *const Buffer, lines: u32) !void {
    _ = try writer.write("\x1b[2J");
    _ = try writer.write("\x1b[1;1H");

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
}

pub fn main() anyerror!void {
    var terminal = try Terminal.init();
    var gpa = std.heap.GeneralPurposeAllocator(.{}){ .backing_allocator = std.heap.c_allocator };
    var allocator = gpa.allocator();
    defer _ = gpa.deinit();

    var buffer = try Buffer.fromFile(allocator, "../zig/src/main.zig");
    defer buffer.deinit();
    try buffer.calculateLines();

    var stdout = std.io.bufferedWriter(std.io.getStdOut().writer());
    var writer = stdout.writer();

    var state = State{};
    var inputHandler = InputHandler{};

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
                if (inputHandler.handleInput(ch)) |movement| {
                    state.move(movement);
                }
            }

            try draw(writer, &buffer, terminal.height);
            try state.cursor.draw(writer);
            try stdout.flush();
        }

        var proc_buf: [16 * 1024]u8 = undefined;
        if (poll_fds[1].revents & (std.os.POLL.IN) != 0) {
            _ = try std.os.read(terminal.fd, &proc_buf);

            try draw(writer, &buffer, terminal.height);
            try state.cursor.draw(writer);
            try stdout.flush();
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

    try std.testing.expectEqualSlices(u32, &.{ 0, 6, 12, 16, 20, 24 }, buf.lines.items);

    var iter = buf.lineIterator();
    try std.testing.expectEqualStrings("hello", iter.next().?);
    try std.testing.expectEqualStrings("world", iter.next().?);
    try std.testing.expectEqualStrings("how", iter.next().?);
    try std.testing.expectEqualStrings("are", iter.next().?);
    try std.testing.expectEqualStrings("you", iter.next().?);
    try std.testing.expectEqualStrings("today", iter.next().?);
    try std.testing.expectEqual(@as(?[]u8, null), iter.next());
}
