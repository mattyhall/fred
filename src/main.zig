const std = @import("std");
const Terminal = @import("Terminal.zig");
const Style = @import("Style.zig");

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
    const scopePrefix = "(" ++ @tagName(scope) ++ ")";
    const prefix = "[" ++ level.asText() ++ "]";
    log_file.writer().print(prefix ++ " " ++ scopePrefix ++ " " ++ format ++ "\n", args) catch unreachable;
}

pub const Span = struct {
    start: u32,
    end: u32,

    pub fn width(self: Span) u32 {
        return self.end - self.start;
    }
};

fn startOfWord(previous: u8, current: u8) bool {
    const c_alpha = std.ascii.isAlNum(current);
    const p_alpha = std.ascii.isAlNum(previous);
    const p_space = std.ascii.isSpace(previous);
    return (c_alpha and (p_space or !p_alpha)) or (!c_alpha and (p_space or p_alpha));
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

    pub fn lineAt(self: *const Self, line: u32) []const u8 {
        const span = self.lineSpan(line);
        return self.data.items[span.start..span.end];
    }

    pub fn lineSpan(self: *const Self, line: u32) Span {
        const line_start = self.lines.items[line];
        const line_end = if (line < self.lines.items.len - 1)
            self.lines.items[line + 1] - 1 // -1 to omit the newline
        else
            @intCast(u32, self.data.items.len);

        return .{ .start = line_start, .end = line_end };
    }

    pub fn deinit(self: *Self) void {
        self.data.deinit(self.gpa);
        self.lines.deinit(self.gpa);
    }
};

pub const Position = struct { x: u32, y: u32 };
pub const Cursor = struct {
    pos: Position,
};

pub const Movement = union(enum) {
    up,
    down,
    left,
    right,
    word_left,
    word_right,
    viewport_up,
    viewport_down,
    viewport_line_top,
    viewport_line_bottom,
    goto_file_top,
    goto_file_end,
    goto_line_start,
    goto_line_end,
};

pub const State = struct {
    cursor: Cursor = .{ .pos = .{ .x = 0, .y = 0 } },
    offset: Position = .{ .x = 0, .y = 0 },
    size: *const Terminal.Size,
    buffer: Buffer,

    pub fn init(terminal: *const Terminal, buffer: Buffer) State {
        return .{ .size = &terminal.size, .buffer = buffer };
    }

    pub fn bufferCursorPos(self: *const State) Position {
        return .{ .x = self.cursor.pos.x + self.offset.x, .y = self.cursor.pos.y + self.offset.y };
    }

    pub fn move(self: *State, movement: Movement) void {
        const pos = self.bufferCursorPos();
        switch (movement) {
            .up => {
                if (self.cursor.pos.y == 0)
                    self.offset.y = std.math.max(1, self.offset.y) - 1
                else
                    self.cursor.pos.y -= 1;
                self.cursor.pos.x = std.math.max(1, std.math.min(
                    self.cursor.pos.x + 1,
                    self.buffer.lineSpan(self.bufferCursorPos().y).width(),
                )) - 1;
            },
            .down => {
                if (self.cursor.pos.y >= self.size.height - 1) {
                    if (pos.y < self.buffer.lines.items.len - 1)
                        self.offset.y += 1;
                } else if (pos.y < self.buffer.lines.items.len - 1) {
                    self.cursor.pos.y += 1;
                }
                self.cursor.pos.x = std.math.max(1, std.math.min(
                    self.cursor.pos.x + 1,
                    self.buffer.lineSpan(self.bufferCursorPos().y).width(),
                )) - 1;
            },
            .left => self.cursor.pos.x = std.math.max(1, self.cursor.pos.x) - 1,
            .right => self.cursor.pos.x = std.math.min(
                self.cursor.pos.x + 1,
                std.math.max(1, self.buffer.lineSpan(pos.y).width()) - 1,
            ),
            .word_right => {
                var line = self.buffer.lineAt(pos.y);
                const want_non_alpha = std.ascii.isAlNum(line[pos.x]);
                var new_pos = pos;
                var skipping_whitespace = false;
                while (true) {
                    if (new_pos.x >= line.len - 1) {
                        if (new_pos.y >= self.buffer.lines.items.len - 1) break;

                        self.move(.down);
                        self.move(.goto_line_start);
                        break;
                    }

                    self.move(.right);
                    new_pos = self.bufferCursorPos();
                    const char = line[new_pos.x];

                    if (std.ascii.isSpace(char)) {
                        skipping_whitespace = true;
                        continue;
                    }

                    if (skipping_whitespace and !std.ascii.isSpace(char))
                        break;

                    if ((want_non_alpha and !std.ascii.isAlNum(char)) or
                        (!want_non_alpha and std.ascii.isAlNum(char)))
                        break;
                }
            },
            .word_left => {
                var line = self.buffer.lineAt(pos.y);
                const line_start = pos.x == 0;
                if (line_start) {
                    if (pos.y == 0) return;

                    self.move(.up);
                    self.move(.goto_line_end);
                }

                var new_pos = self.bufferCursorPos();
                line = self.buffer.lineAt(new_pos.y);
                var word_start = startOfWord(line[new_pos.x - 1], line[new_pos.x]);
                if (word_start) {
                    // Find first character of the previous word
                    while (true) {
                        self.move(.left);

                        new_pos = self.bufferCursorPos();
                        if (new_pos.x == 0) return;
                        if (!std.ascii.isSpace(line[new_pos.x])) break;
                    }
                }

                new_pos = self.bufferCursorPos();
                const starting_char = line[new_pos.x];
                word_start = startOfWord(line[new_pos.x - 1], starting_char);
                if (word_start) return;

                // Find start of word
                while (true) {
                    new_pos = self.bufferCursorPos();
                    if (new_pos.x == 0) return;

                    const char = line[new_pos.x];
                    if (std.ascii.isAlNum(starting_char) and !std.ascii.isAlNum(char))
                        break;
                    if (!std.ascii.isAlNum(starting_char) and (std.ascii.isAlNum(char) or std.ascii.isSpace(char)))
                        break;

                    self.move(.left);
                }

                self.move(.right);
            },
            .goto_file_top => {
                self.cursor.pos = .{ .x = 0, .y = 0 };
                self.offset = .{ .x = 0, .y = 0 };
            },
            .goto_file_end => {
                self.cursor.pos = .{ .x = 0, .y = std.math.min(self.buffer.lines.items.len - 1, self.size.height - 1) };
                if (self.buffer.lines.items.len > self.size.height)
                    self.offset = .{ .x = 0, .y = @intCast(u32, self.buffer.lines.items.len) - self.size.height };
            },
            .goto_line_start => self.cursor.pos.x = 0,
            .goto_line_end => self.cursor.pos.x = self.buffer.lineSpan(pos.y).width() - 1,
            .viewport_up => {
                if (self.offset.y == 0) return;
                self.offset.y -= 1;
                if (self.cursor.pos.y < self.size.height - 1) self.cursor.pos.y += 1;
            },
            .viewport_down => {
                if (self.offset.y >= self.buffer.lines.items.len - 1) return;

                self.offset.y += 1;
                if (self.cursor.pos.y > 0) self.cursor.pos.y -= 1;
            },
            .viewport_line_top => {
                self.offset.y += self.cursor.pos.y;
                self.cursor.pos.y = 0;
            },
            .viewport_line_bottom => {
                if (pos.y < self.size.height) {
                    self.cursor.pos.y = self.offset.y;
                    self.offset.y = 0;
                    return;
                }

                self.offset.y -= self.size.height - self.cursor.pos.y - 1;
                self.cursor.pos.y = self.size.height - 1;
            },
        }
    }

    pub fn draw(self: *const State, writer: anytype) !void {
        _ = try writer.write("\x1b[2J");
        _ = try writer.write("\x1b[1;1H");

        const line_len = std.math.log10(self.buffer.lines.items.len) + 1;

        // Line numbers and editor
        {
            const line_style = Style{ .foreground = Style.grey };
            var iter = self.buffer.lineIterator();
            var i: u32 = 0;
            var skipped: u32 = 0;
            while (iter.next()) |line| {
                if (skipped < self.offset.y) {
                    skipped += 1;
                    continue;
                }
                if (i >= self.size.height) break;

                if (i == self.cursor.pos.y) {
                    try writer.print(" {:[1]}", .{ i + skipped + 1, line_len });
                    try line_style.print(writer, "│", .{});
                } else try line_style.print(writer, " {:[1]}│", .{ i + skipped + 1, line_len });

                _ = try writer.write(line);
                _ = try writer.write("\x1b[1E");
                i += 1;
            }
        }

        // Cursor
        _ = try writer.print("\x1b[{};{}H", .{
            self.cursor.pos.y + 1,
            self.cursor.pos.x + line_len + 2 + 1,
        }); // Position
        _ = try writer.write("\x1b[2 q"); // Block cursor
    }

    pub fn deinit(self: *State) void {
        self.buffer.deinit();
    }
};

pub const NormalModeState = enum { none, goto, viewport, viewport_sticky };

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
                    'w' => Movement.word_right,
                    'b' => Movement.word_left,
                    'g' => {
                        self.mode = .{ .normal = .goto };
                        return null;
                    },
                    'v' => {
                        self.mode = .{ .normal = .viewport };
                        return null;
                    },
                    'V' => {
                        self.mode = .{ .normal = .viewport_sticky };
                        return null;
                    },
                    else => return null,
                },
                .goto => switch (c) {
                    'e' => blk: {
                        self.mode = .{ .normal = .none };
                        break :blk Movement.goto_file_end;
                    },
                    'g' => blk: {
                        self.mode = .{ .normal = .none };
                        break :blk Movement.goto_file_top;
                    },
                    'h' => blk: {
                        self.mode = .{ .normal = .none };
                        break :blk Movement.goto_line_start;
                    },
                    'l' => blk: {
                        self.mode = .{ .normal = .none };
                        break :blk Movement.goto_line_end;
                    },
                    else => {
                        self.mode = .{ .normal = .none };
                        return null;
                    },
                },
                .viewport, .viewport_sticky => {
                    const movement = switch (c) {
                        'j' => Movement.viewport_down,
                        'k' => Movement.viewport_up,
                        't' => Movement.viewport_line_top,
                        'b' => Movement.viewport_line_bottom,
                        else => {
                            self.mode = .{ .normal = .none };
                            return null;
                        },
                    };
                    if (state == .viewport) {
                        self.mode = .{ .normal = .none };
                    }
                    return movement;
                },
            },
            else => return null,
        };
    }
};

pub fn main() anyerror!void {
    try setupLogging();

    var stdout = std.io.bufferedWriter(std.io.getStdOut().writer());
    var writer = stdout.writer();

    if (std.os.argv.len != 2) {
        _ = try writer.write("please pass an argument");
        try stdout.flush();
        std.os.exit(1);
    }

    const path = std.mem.span(std.os.argv[1]);

    var terminal = try Terminal.init();
    var gpa = std.heap.GeneralPurposeAllocator(.{}){ .backing_allocator = std.heap.c_allocator };
    var allocator = gpa.allocator();
    defer _ = gpa.deinit();

    var state = State.init(terminal, try Buffer.fromFile(allocator, path));
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

test "state word movement" {
    var gpa = std.testing.allocator;
    const lit =
        \\here are words ("quote")
        \\test@test
    ;
    var data = try gpa.alloc(u8, lit.len);
    std.mem.copy(u8, data, lit);

    const terminal = Terminal{ .size = .{ .width = 50, .height = 6 } };
    var state = State.init(&terminal, Buffer.fromSlice(gpa, data));
    defer state.deinit();
    try state.buffer.calculateLines();

    const positions = [_]Position{
        .{ .x = 5, .y = 0 },
        .{ .x = 9, .y = 0 },
        .{ .x = 15, .y = 0 },
        .{ .x = 17, .y = 0 },
        .{ .x = 22, .y = 0 },
        .{ .x = 0, .y = 1 },
        .{ .x = 4, .y = 1 },
        .{ .x = 5, .y = 1 },
    };

    var i: isize = 0;
    while (i < positions.len) : (i += 1) {
        state.move(.word_right);
        try std.testing.expectEqual(positions[@intCast(usize, i)], state.cursor.pos);
    }
    i -= 2;
    while (i >= 0) : (i -= 1) {
        state.move(.word_left);
        try std.testing.expectEqual(positions[@intCast(usize, i)], state.cursor.pos);
    }
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

    state.move(.goto_file_end);
    // Top '6', cursor on '10'
    try std.testing.expectEqual(Position{ .x = 0, .y = 4 }, state.cursor.pos);
    try std.testing.expectEqual(Position{ .x = 0, .y = 5 }, state.offset);

    state.move(.goto_file_top);
    try std.testing.expectEqual(Position{ .x = 0, .y = 0 }, state.cursor.pos);
    try std.testing.expectEqual(Position{ .x = 0, .y = 0 }, state.offset);

    terminal.size.height = 15;
    state.move(.goto_file_end);
    // Top '1', cursor on '10'
    try std.testing.expectEqual(Position{ .x = 0, .y = 9 }, state.cursor.pos);
    try std.testing.expectEqual(Position{ .x = 0, .y = 0 }, state.offset);
}

test "state goto start/end of line" {
    var gpa = std.testing.allocator;
    const lit =
        \\hello
        \\world
        \\helloworldhowareyoutoday
    ;
    var data = try gpa.alloc(u8, lit.len);
    std.mem.copy(u8, data, lit);

    var terminal = Terminal{ .size = .{ .width = 100, .height = 2 } };
    var state = State.init(&terminal, Buffer.fromSlice(gpa, data));
    defer state.deinit();
    try state.buffer.calculateLines();

    state.move(.goto_line_end);
    try std.testing.expectEqual(Position{ .x = 4, .y = 0 }, state.cursor.pos);
    try std.testing.expectEqual(Position{ .x = 0, .y = 0 }, state.offset);

    state.move(.down);
    state.move(.goto_line_start);
    try std.testing.expectEqual(Position{ .x = 0, .y = 1 }, state.cursor.pos);
    try std.testing.expectEqual(Position{ .x = 0, .y = 0 }, state.offset);

    state.move(.goto_line_end);
    try std.testing.expectEqual(Position{ .x = 4, .y = 1 }, state.cursor.pos);
    try std.testing.expectEqual(Position{ .x = 0, .y = 0 }, state.offset);

    state.move(.down);
    state.move(.goto_line_end);
    try std.testing.expectEqual(Position{ .x = 23, .y = 1 }, state.cursor.pos);
    try std.testing.expectEqual(Position{ .x = 0, .y = 1 }, state.offset);
}

test "state clamp line end" {
    var gpa = std.testing.allocator;
    const lit =
        \\helloworldhowareyoutoday
        \\world
        \\hi
    ;
    var data = try gpa.alloc(u8, lit.len);
    std.mem.copy(u8, data, lit);

    var terminal = Terminal{ .size = .{ .width = 100, .height = 3 } };
    var state = State.init(&terminal, Buffer.fromSlice(gpa, data));
    defer state.deinit();
    try state.buffer.calculateLines();

    state.move(.goto_line_end);
    try std.testing.expectEqual(Position{ .x = 23, .y = 0 }, state.cursor.pos);
    try std.testing.expectEqual(Position{ .x = 0, .y = 0 }, state.offset);

    state.move(.right);
    try std.testing.expectEqual(Position{ .x = 23, .y = 0 }, state.cursor.pos);
    try std.testing.expectEqual(Position{ .x = 0, .y = 0 }, state.offset);

    state.move(.down);
    try std.testing.expectEqual(Position{ .x = 4, .y = 1 }, state.cursor.pos);
    try std.testing.expectEqual(Position{ .x = 0, .y = 0 }, state.offset);

    state.move(.down);
    try std.testing.expectEqual(Position{ .x = 1, .y = 2 }, state.cursor.pos);
    try std.testing.expectEqual(Position{ .x = 0, .y = 0 }, state.offset);
}

test "state viewport up/down" {
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

    var terminal = Terminal{ .size = .{ .width = 100, .height = 5 } };
    var state = State.init(&terminal, Buffer.fromSlice(gpa, data));
    defer state.deinit();
    try state.buffer.calculateLines();

    state.move(.viewport_up);
    try std.testing.expectEqual(Position{ .x = 0, .y = 0 }, state.cursor.pos);
    try std.testing.expectEqual(Position{ .x = 0, .y = 0 }, state.offset);

    state.move(.down);
    state.move(.down);
    // Top '1', cursor '3'
    try std.testing.expectEqual(Position{ .x = 0, .y = 2 }, state.cursor.pos);
    try std.testing.expectEqual(Position{ .x = 0, .y = 0 }, state.offset);

    state.move(.viewport_down);
    state.move(.viewport_down);
    // Top '3', cursor '3'
    try std.testing.expectEqual(Position{ .x = 0, .y = 0 }, state.cursor.pos);
    try std.testing.expectEqual(Position{ .x = 0, .y = 2 }, state.offset);

    state.move(.viewport_down);
    state.move(.viewport_down);
    state.move(.viewport_down);
    state.move(.viewport_down);
    // Top '7', cursor '7'
    try std.testing.expectEqual(Position{ .x = 0, .y = 0 }, state.cursor.pos);
    try std.testing.expectEqual(Position{ .x = 0, .y = 6 }, state.offset);

    state.move(.viewport_up);
    state.move(.viewport_up);
    // Top '5', cursor '7'
    try std.testing.expectEqual(Position{ .x = 0, .y = 2 }, state.cursor.pos);
    try std.testing.expectEqual(Position{ .x = 0, .y = 4 }, state.offset);
}

test "state viewport line to top/bottom" {
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

    var terminal = Terminal{ .size = .{ .width = 100, .height = 5 } };
    var state = State.init(&terminal, Buffer.fromSlice(gpa, data));
    defer state.deinit();
    try state.buffer.calculateLines();

    state.move(.viewport_line_top);
    try std.testing.expectEqual(Position{ .x = 0, .y = 0 }, state.cursor.pos);
    try std.testing.expectEqual(Position{ .x = 0, .y = 0 }, state.offset);

    state.move(.down);
    state.move(.down);
    // Top '1', cursor '3'
    try std.testing.expectEqual(Position{ .x = 0, .y = 2 }, state.cursor.pos);
    try std.testing.expectEqual(Position{ .x = 0, .y = 0 }, state.offset);

    state.move(.viewport_line_top);
    // Top '3', cursor '3'
    try std.testing.expectEqual(Position{ .x = 0, .y = 0 }, state.cursor.pos);
    try std.testing.expectEqual(Position{ .x = 0, .y = 2 }, state.offset);

    state.move(.viewport_line_bottom);
    // Top '1', cursor '3'
    try std.testing.expectEqual(Position{ .x = 0, .y = 2 }, state.cursor.pos);
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

    state.move(.goto_file_end);
    // Top '6', cursor on '10'
    try std.testing.expectEqual(Position{ .x = 0, .y = 4 }, state.cursor.pos);
    try std.testing.expectEqual(Position{ .x = 0, .y = 5 }, state.offset);

    terminal.size.height = 15;
    state.move(.down);
    // Top '6', cursor on '10'
    try std.testing.expectEqual(Position{ .x = 0, .y = 4 }, state.cursor.pos);
    try std.testing.expectEqual(Position{ .x = 0, .y = 5 }, state.offset);
}
