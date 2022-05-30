const std = @import("std");
const Terminal = @import("Terminal.zig");

var log_file: std.fs.File = undefined;

fn setupLogging() !void {
    log_file = try std.fs.cwd().createFile("fred.log", .{});
}

pub fn log(
    comptime level: std.log.Level,
    comptime scope: @TypeOf(.EnumLiteral),
    comptime format: []const u8,
    args: anytype,
) void {
    const scopePrefix = "(" ++  @tagName(scope) ++ ")";
    const prefix = "[" ++ level.asText() ++ "]";
    log_file.writer().print(prefix ++ " " ++ scopePrefix ++ " " ++ format ++ "\n", args) catch unreachable;
}

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
                self.data[self.lines[self.i] .. self.data.len - 1]
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

    pub fn draw(self: *const Self, writer: anytype, lines: u32, offset: Position) !void {
        _ = try writer.write("\x1b[2J");
        _ = try writer.write("\x1b[1;1H");

        {
            var iter = self.lineIterator();
            var i: u32 = 0;
            var skipped: u32 = 0;
            while (iter.next()) |line| {
                if (skipped < offset.y) {
                    skipped += 1;
                    continue;
                }
                if (i >= lines) break;

                _ = try writer.write(line);
                _ = try writer.write("\x1b[1E");
                i += 1;
            }
        }
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
    end,
    top,
};

pub const State = struct {
    cursor: Cursor = .{ .pos = .{ .x = 0, .y = 0 } },
    offset: Position = .{ .x = 0, .y = 0 },
    size: *const Terminal.Size,
    buffer: Buffer,

    pub fn init(terminal: *const Terminal, buffer: Buffer) State {
        return .{ .size = &terminal.size, .buffer = buffer };
    }

    pub fn move(self: *State, movement: Movement) void {
        switch (movement) {
            .up => {
                if (self.cursor.pos.y == 0)
                    self.offset.y = std.math.max(1, self.offset.y) - 1
                else
                    self.cursor.pos.y -= 1;
            },
            .down => {
                if (self.cursor.pos.y >= self.size.height - 1) {
                    if (self.cursor.pos.y + self.offset.y < self.buffer.lines.items.len - 1)
                        self.offset.y += 1;
                } else if (self.cursor.pos.y + self.offset.y < self.buffer.lines.items.len - 1) {
                    self.cursor.pos.y += 1;
                }
            },
            .left => self.cursor.pos.x = std.math.max(1, self.cursor.pos.x) - 1,
            .right => self.cursor.pos.x += 1,
            .top => {
                self.cursor.pos = .{ .x = 0, .y = 0 };
                self.offset = .{ .x = 0, .y = 0 };
            },
            .end => {
                self.cursor.pos = .{ .x = 0, .y = std.math.min(self.buffer.lines.items.len - 1, self.size.height - 1) };
                if (self.buffer.lines.items.len > self.size.height)
                    self.offset = .{ .x = 0, .y = @intCast(u32, self.buffer.lines.items.len) - self.size.height };
            },
        }
    }

    pub fn draw(self: *const State, writer: anytype) !void {
        try self.buffer.draw(writer, self.size.height, self.offset);
        try self.cursor.draw(writer);
    }

    pub fn deinit(self: *State) void {
        self.buffer.deinit();
    }
};

pub const NormalModeState = enum { none, goto };

pub const Mode = union(enum) {
    normal: NormalModeState,
    insert,
    command,
};

pub const InputHandler = struct {
    mode: Mode = .{ .normal = .none },

    pub fn handleInput(self: *InputHandler, c: u8) ?Movement {
        return switch (self.mode) {
            .normal => |state| switch (state) {
                .none => switch (c) {
                    'j' => Movement.down,
                    'k' => Movement.up,
                    'l' => Movement.right,
                    'h' => Movement.left,
                    'g' => {
                        self.mode = .{ .normal = .goto };
                        return null;
                    },
                    else => return null,
                },
                .goto => switch (c) {
                    'e' => blk: {
                        self.mode = .{ .normal = .none };
                        break :blk Movement.end;
                    },
                    'g' => blk: {
                        self.mode = .{ .normal = .none };
                        break :blk Movement.top;
                    },
                    else => {
                        self.mode = .{ .normal = .none };
                        return null;
                    },
                },
            },
            else => return null,
        };
    }
};

pub fn main() anyerror!void {
    try setupLogging();

    var terminal = try Terminal.init();
    var gpa = std.heap.GeneralPurposeAllocator(.{}){ .backing_allocator = std.heap.c_allocator };
    var allocator = gpa.allocator();
    defer _ = gpa.deinit();

    var stdout = std.io.bufferedWriter(std.io.getStdOut().writer());
    var writer = stdout.writer();

    var state = State.init(terminal, try Buffer.fromFile(allocator, "../zig/src/main.zig"));
    defer state.deinit();
    try state.buffer.calculateLines();

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

            try state.draw(writer);
            try stdout.flush();
        }

        var proc_buf: [16 * 1024]u8 = undefined;
        if (poll_fds[1].revents & (std.os.POLL.IN) != 0) {
            _ = try std.os.read(terminal.fd, &proc_buf);

            try state.draw(writer);
            try stdout.flush();
        }
    }
}

test "buffer line iterator" {
    var gpa = std.testing.allocator;
    const lit = "hello\nworld\nhow\nare\nyou\ntoday\n";
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

test "state basic cursor movement" {
    var gpa = std.testing.allocator;
    const lit =
        \\qwerty
        \\uiopas
        \\dfghjk
        \\lzxcvb
        \\nm1234
        \\567890
    ;
    var data = try gpa.alloc(u8, lit.len);
    std.mem.copy(u8, data, lit);

    const terminal = Terminal{ .size = .{ .width = 6, .height = 6 } };
    var state = State.init(&terminal, Buffer.fromSlice(gpa, data));
    defer state.deinit();
    try state.buffer.calculateLines();

    state.move(.left);
    try std.testing.expectEqual(Position{ .x = 0, .y = 0 }, state.cursor.pos);

    state.move(.up);
    try std.testing.expectEqual(Position{ .x = 0, .y = 0 }, state.cursor.pos);

    state.move(.right);
    try std.testing.expectEqual(Position{ .x = 1, .y = 0 }, state.cursor.pos);

    state.move(.down);
    try std.testing.expectEqual(Position{ .x = 1, .y = 1 }, state.cursor.pos);

    state.move(.down);
    state.move(.down);
    state.move(.down);
    state.move(.right);
    state.move(.right);
    state.move(.right);
    try std.testing.expectEqual(Position{ .x = 4, .y = 4 }, state.cursor.pos);

    state.move(.up);
    state.move(.up);
    state.move(.up);
    state.move(.left);
    state.move(.left);
    state.move(.left);
    try std.testing.expectEqual(Position{ .x = 1, .y = 1 }, state.cursor.pos);
}

test "state viewport" {
    var gpa = std.testing.allocator;
    const lit =
        \\qwerty
        \\uiopas
        \\dfghjk
        \\lzxcvb
        \\nm1234
        \\567890
    ;
    var data = try gpa.alloc(u8, lit.len);
    std.mem.copy(u8, data, lit);

    const terminal = Terminal{ .size = .{ .width = 6, .height = 3 } };
    var state = State.init(&terminal, Buffer.fromSlice(gpa, data));
    defer state.deinit();
    try state.buffer.calculateLines();

    state.move(.down);
    state.move(.down);
    // Top 'q', cursor on 'd'
    try std.testing.expectEqual(Position{ .x = 0, .y = 2 }, state.cursor.pos);
    try std.testing.expectEqual(Position{ .x = 0, .y = 0 }, state.offset);

    state.move(.down);
    // Top 'u', cursor on 'l'
    try std.testing.expectEqual(Position{ .x = 0, .y = 2 }, state.cursor.pos);
    try std.testing.expectEqual(Position{ .x = 0, .y = 1 }, state.offset);

    state.move(.down);
    state.move(.down);
    // Top 'l', cursor on '5'
    try std.testing.expectEqual(Position{ .x = 0, .y = 2 }, state.cursor.pos);
    try std.testing.expectEqual(Position{ .x = 0, .y = 3 }, state.offset);

    state.move(.down);
    // Top still 'l', cursor on '5'
    try std.testing.expectEqual(Position{ .x = 0, .y = 2 }, state.cursor.pos);
    try std.testing.expectEqual(Position{ .x = 0, .y = 3 }, state.offset);

    state.move(.up);
    state.move(.up);
    // Top still 'l', cursor on 'l'
    try std.testing.expectEqual(Position{ .x = 0, .y = 0 }, state.cursor.pos);
    try std.testing.expectEqual(Position{ .x = 0, .y = 3 }, state.offset);

    state.move(.up);
    // Top 'd', cursor on 'd'
    try std.testing.expectEqual(Position{ .x = 0, .y = 0 }, state.cursor.pos);
    try std.testing.expectEqual(Position{ .x = 0, .y = 2 }, state.offset);
}

test "state goto top/bottom" {
    var gpa = std.testing.allocator;
    const lit =
    \\1
    \\2
    \\3
    \\4
    \\5
    \\6
    \\7
    \\8
    \\9
    \\10
    ;
    var data = try gpa.alloc(u8, lit.len);
    std.mem.copy(u8, data, lit);

    var terminal = Terminal{ .size = .{ .width = 10, .height = 5 } };
    var state = State.init(&terminal, Buffer.fromSlice(gpa, data));
    defer state.deinit();
    try state.buffer.calculateLines();

    state.move(.end);
    // Top '6', cursor on '10'
    try std.testing.expectEqual(Position{ .x = 0, .y = 4 }, state.cursor.pos);
    try std.testing.expectEqual(Position{ .x = 0, .y = 5 }, state.offset);

    state.move(.top);
    try std.testing.expectEqual(Position{ .x = 0, .y = 0 }, state.cursor.pos);
    try std.testing.expectEqual(Position{ .x = 0, .y = 0 }, state.offset);

    terminal.size.height = 15;
    state.move(.end);
    // Top '1', cursor on '10'
    try std.testing.expectEqual(Position{ .x = 0, .y = 9 }, state.cursor.pos);
    try std.testing.expectEqual(Position{ .x = 0, .y = 0 }, state.offset);
}

test "state can't scroll past last line" {
    // Can happen if you are on the last line and make the window bigger - there will be blank space at the bottom
    var gpa = std.testing.allocator;
    const lit =
    \\1
    \\2
    \\3
    \\4
    \\5
    \\6
    \\7
    \\8
    \\9
    \\10
    ;
    var data = try gpa.alloc(u8, lit.len);
    std.mem.copy(u8, data, lit);

    var terminal = Terminal{ .size = .{ .width = 10, .height = 5 } };
    var state = State.init(&terminal, Buffer.fromSlice(gpa, data));
    defer state.deinit();
    try state.buffer.calculateLines();

    state.move(.end);
    // Top '6', cursor on '10'
    try std.testing.expectEqual(Position{ .x = 0, .y = 4 }, state.cursor.pos);
    try std.testing.expectEqual(Position{ .x = 0, .y = 5 }, state.offset);

    terminal.size.height = 15;
    state.move(.down);
    // Top '6', cursor on '10'
    try std.testing.expectEqual(Position{ .x = 0, .y = 4 }, state.cursor.pos);
    try std.testing.expectEqual(Position{ .x = 0, .y = 5 }, state.offset);
}
