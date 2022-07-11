const std = @import("std");
const Terminal = @import("Terminal.zig");
const Buffer = @import("Buffer.zig");
const Style = @import("Style.zig");
const input = @import("input.zig");
const ds = @import("ds.zig");
const re = @import("re");

const Self = @This();

cursor: ds.Cursor = .{ .pos = .{ .x = 0, .y = 0 } },
offset: ds.Position = .{ .x = 0, .y = 0 },

gpa: std.mem.Allocator,

terminal_size: *const Terminal.Size,
buffer: Buffer,
input_handler: *input.InputHandler,

current_search: ?std.ArrayList(u8) = null,
search_highlights: std.ArrayListUnmanaged(ds.Span),
matches: ?re.Matches = null,
valid_regex: bool = true,

have_command_line: bool = true,

fn startOfWord(previous: u8, current: u8) bool {
    const c_alpha = std.ascii.isAlNum(current);
    const p_alpha = std.ascii.isAlNum(previous);
    const p_space = std.ascii.isSpace(previous);
    return (c_alpha and (p_space or !p_alpha)) or (!c_alpha and (p_space or p_alpha));
}

pub fn init(gpa: std.mem.Allocator, terminal: *const Terminal, input_handler: *input.InputHandler, buffer: Buffer) Self {
    return .{
        .gpa = gpa,
        .terminal_size = &terminal.size,
        .buffer = buffer,
        .input_handler = input_handler,
        .search_highlights = .{},
    };
}

/// Returns the size allocated to the buffer
pub fn size(self: *const Self) Terminal.Size {
    var sz = self.terminal_size.*;
    if (self.have_command_line)
        sz.height -= 1;
    return sz;
}

pub fn bufferCursorPos(self: *const Self) ds.Position {
    return .{ .x = self.cursor.pos.x + self.offset.x, .y = self.cursor.pos.y + self.offset.y };
}

fn bufferIndex(self: *const Self) usize {
    const pos = self.bufferCursorPos();
    var index: usize = pos.x;
    var iter = self.buffer.lineIterator();
    var i: usize = 0;
    while (iter.next()) |line| {
        if (i >= pos.y) break;
        i += 1;
        index += line.len + 1;
    }
    return index;
}

fn putCursorAtIndex(self: *Self, index: usize) void {
    var i: usize = 0;
    var x: u32 = 0;
    var y: u32 = 0;
    while (i < index) : (i += 1) {
        if (self.buffer.data.items[i] == '\n') {
            x = 0;
            y += 1;
            continue;
        }

        x += 1;
    }

    const pos = self.bufferCursorPos();
    self.cursor.pos.x = x;
    if (y < pos.y) {
        const diff = pos.y - y;
        if (diff > self.cursor.pos.y) {
            const remaining_diff = diff - self.cursor.pos.y;
            self.cursor.pos.y = 0;
            self.offset.y -= remaining_diff;
        } else {
            self.cursor.pos.y -= diff;
        }
    } else if (y > pos.y) {
        const diff = y - pos.y;
        if (diff > self.terminal_size.height) {
            self.cursor.pos.y = 0;
            self.offset.y = diff;
        } else {
            self.cursor.pos.y += diff;
        }
    }
}

fn moveToNextMatch(self: *Self, col: u32, row: u32, skip_current: bool) void {
    const matches = self.matches orelse return;
    if (matches.matches.len == 0) return;

    // Find buffer position of (col, row)
    var iter = self.buffer.lineIterator();
    var buf_pos: u32 = 0;
    var line: u32 = 0;
    while (iter.next()) |l| {
        if (line >= row) break;
        buf_pos += @intCast(u32, l.len) + 1;
        line += 1;
    }
    buf_pos += col;

    // Find pos of next match
    var pos: ?u32 = null;
    for (matches.matches) |m| {
        if ((skip_current and m.start > buf_pos) or (!skip_current and m.start >= buf_pos)) {
            pos = @intCast(u32, m.start);
            break;
        }
    }

    // If there's no match after this one goes back to the start of the buffer
    if (pos == null) {
        self.moveToNextMatch(0, 0, false);
        return;
    }

    if (pos.? == buf_pos) return;

    // If next match is on the same line as (col, row)
    if (pos.? < buf_pos + (self.buffer.lineAt(line).len + 1) - col) {
        self.cursor.pos.x += pos.? - buf_pos;
        return;
    }

    buf_pos += (@intCast(u32, self.buffer.lineAt(line).len) + 1) - col;
    line += 1;

    while (iter.next()) |l| {
        if (buf_pos <= pos.? and buf_pos + @intCast(u32, l.len) + 1 > pos.?) {
            if (line < self.size().height) {
                self.cursor.pos = .{ .x = pos.? - buf_pos, .y = line };
                self.offset = .{ .x = 0, .y = 0 };
                return;
            }

            self.cursor.pos = .{ .x = pos.? - buf_pos, .y = self.size().height / 2 };
            self.offset = .{ .x = 0, .y = line - self.size().height / 2 };
            return;
        }

        buf_pos += @intCast(u32, l.len) + 1;
        line += 1;
    }
}

fn refindMatches(self: *Self) !void {
    if (self.current_search) |s|
        _ = try self.findMatches(s.items);
}

fn findMatches(self: *Self, s: []const u8) !bool {
    self.search_highlights.clearRetainingCapacity();
    if (self.matches) |m| m.deinit();
    var regex = re.Regex.init(s) catch {
        self.matches = null;
        self.valid_regex = false;
        return false;
    };
    defer regex.deinit();
    self.valid_regex = true;
    self.matches = regex.search(self.buffer.data.items);
    for (self.matches.?.matches) |match| {
        try self.search_highlights.append(self.gpa, .{
            .start = @intCast(u32, match.start),
            .end = @intCast(u32, match.end),
        });
    }
    return true;
}

pub fn handleInput(self: *Self, instructions: []const input.Instruction) !void {
    for (instructions) |i| {
        switch (i) {
            .movement => |m| self.move(m.movement, m.opts),
            .search => |s| switch (s) {
                .quit => self.search_highlights.clearRetainingCapacity(),
                .complete => |al| {
                    if (self.current_search) |q| q.deinit();
                    self.current_search = al;
                },
                .char => {
                    if (!try self.findMatches(self.input_handler.cmd.items)) continue;
                    const pos = self.bufferCursorPos();
                    self.moveToNextMatch(pos.x, pos.y, false);
                },
                .next => {
                    const pos = self.bufferCursorPos();
                    self.moveToNextMatch(pos.x, pos.y, true);
                },
            },
            .insertion => |c| {
                const index = self.bufferIndex();
                switch (c) {
                    127 => { // BACKSPACE
                        if (index == 0) return;
                        try self.buffer.orderedRemove(index - 1);
                        try self.refindMatches();
                        self.putCursorAtIndex(index - 1);
                    },
                    13 => { // RET
                        try self.buffer.insert(index, '\n');
                        self.move(.down, .{});
                        self.move(.goto_line_start, .{});
                        try self.copyWhitespaceFromAbove();
                        try self.refindMatches();
                    },
                    else => {
                        try self.buffer.insert(index, c);
                        try self.refindMatches();
                        self.move(.right, .{ .allow_past_last_column = true });
                    },
                }
            },
            .copy_whitespace_from_above => try self.copyWhitespaceFromAbove(),
            .noop, .command => {},
        }
    }
}

fn copyWhitespaceFromAbove(self: *Self) !void {
    const pos = self.bufferCursorPos();
    if (pos.y == 0) return;
    const line_above = self.buffer.lineAt(pos.y - 1);
    var index: ?u32 = null;
    for (line_above) |c, n| {
        if (!std.ascii.isSpace(c)) break;
        index = @intCast(u32, n);
    }
    if (index) |idx| {
        const buffer_index = self.bufferIndex();
        try self.buffer.insertSlice(buffer_index, line_above[0 .. idx + 1]);
        try self.refindMatches();
        self.move(.goto_line_end_plus_one, .{});
    }
}

fn move(self: *Self, movement: input.Movement, opts: input.MovementOpts) void {
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
            if (self.cursor.pos.y >= self.size().height - 1) {
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
        .right => {
            const minus: u32 = if (opts.allow_past_last_column) 0 else 1;
            self.cursor.pos.x = std.math.min(
                self.cursor.pos.x + 1,
                std.math.max(1, self.buffer.lineSpan(pos.y).width()) - minus,
            );
        },
        .word_right => {
            var line = self.buffer.lineAt(pos.y);
            if (pos.x >= line.len) {
                self.move(.down, .{});
                self.move(.goto_line_start, .{});
                return;
            }
            const want_non_alpha = std.ascii.isAlNum(line[pos.x]);
            var new_pos = pos;
            var skipping_whitespace = false;
            while (true) {
                if (new_pos.x >= line.len - 1) {
                    if (new_pos.y >= self.buffer.lines.items.len - 1) break;

                    self.move(.down, .{});
                    self.move(.goto_line_start, .{});
                    break;
                }

                self.move(.right, .{});
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
            if (pos.x >= line.len) {
                self.move(.up, .{});
                self.move(.goto_line_end, .{});
            }
            const line_start = pos.x == 0;
            if (line_start) {
                if (pos.y == 0) return;

                self.move(.up, .{});
                self.move(.goto_line_end, .{});
            }

            var new_pos = self.bufferCursorPos();
            line = self.buffer.lineAt(new_pos.y);
            if (new_pos.x == 0) return;
            var word_start = startOfWord(line[new_pos.x - 1], line[new_pos.x]);
            if (word_start) {
                // Find first character of the previous word
                while (true) {
                    self.move(.left, .{});

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

                self.move(.left, .{});
            }

            self.move(.right, .{});
        },
        .goto_file_top => {
            self.cursor.pos = .{ .x = 0, .y = 0 };
            self.offset = .{ .x = 0, .y = 0 };
        },
        .goto_file_end => {
            self.cursor.pos = .{ .x = 0, .y = std.math.min(self.buffer.lines.items.len - 1, self.size().height - 1) };
            if (self.buffer.lines.items.len > self.size().height)
                self.offset = .{ .x = 0, .y = @intCast(u32, self.buffer.lines.items.len) - self.size().height };
        },
        .goto_line => {
            if (opts.repeat == 0 or opts.repeat > self.buffer.lines.items.len) return;
            const line = opts.repeat - 1;
            if (line < self.size().height) {
                self.cursor.pos = .{ .x = 0, .y = line };
                self.offset = .{ .x = 0, .y = 0 };
                return;
            }

            self.cursor.pos = .{ .x = 0, .y = self.size().height / 2 };
            self.offset = .{ .x = 0, .y = line - self.size().height / 2 };
        },
        .goto_line_start => self.cursor.pos.x = 0,
        .goto_line_start_skip_whitespace => {
            const line = self.buffer.lineAt(pos.y);
            var x: u32 = 0;
            for (line) |ch| {
                if (!std.ascii.isSpace(ch)) break;
                x += 1;
            }
            self.cursor.pos.x = x;
        },
        .goto_line_end => self.cursor.pos.x = std.math.max(1, self.buffer.lineSpan(pos.y).width()) - 1,
        .goto_line_end_plus_one => {
            self.move(.goto_line_end, .{});
            if (self.buffer.lineSpan(self.bufferCursorPos().y).width() > 0)
                self.move(.right, .{ .allow_past_last_column = true });
        },
        .page_up => {
            self.offset.y = std.math.max(self.offset.y, self.size().height - 1) - (self.size().height - 1);
            if (pos.y >= self.size().height)
                self.cursor.pos.y = self.size().height - 1;
        },
        .page_down => {
            self.offset.y = std.math.min(self.offset.y + self.size().height, @intCast(u32, self.buffer.lines.items.len - 1)) - 1;
            self.cursor.pos.y = 0;
        },
        .viewport_up => {
            if (self.offset.y == 0) return;
            self.offset.y -= 1;
            if (self.cursor.pos.y < self.size().height - 1) self.cursor.pos.y += 1;
        },
        .viewport_down => {
            if (self.offset.y >= self.buffer.lines.items.len - 1) return;

            self.offset.y += 1;
            if (self.cursor.pos.y > 0) self.cursor.pos.y -= 1;
        },
        .viewport_centre => {
            const centre = self.size().height / 2;
            if (self.cursor.pos.y == centre) return;

            if (self.cursor.pos.y > centre) {
                const diff = self.cursor.pos.y - centre;
                self.offset.y += diff;
                self.cursor.pos.y -= diff;
                return;
            }

            var diff = centre - self.cursor.pos.y;
            if (diff > self.offset.y)
                diff = self.offset.y;
            self.offset.y -= diff;
            self.cursor.pos.y += diff;
        },
        .viewport_line_top => {
            self.offset.y += self.cursor.pos.y;
            self.cursor.pos.y = 0;
        },
        .viewport_line_bottom => {
            if (pos.y < self.size().height) {
                const line = self.cursor.pos.y + self.offset.y;
                self.cursor.pos.y = line;
                self.offset.y = 0;
                return;
            }

            self.offset.y -= self.size().height - self.cursor.pos.y - 1;
            self.cursor.pos.y = self.size().height - 1;
        },
    }
}

pub fn draw(self: *const Self, writer: anytype) !void {
    const line_len = std.math.log10(self.buffer.lines.items.len) + 1;

    _ = try writer.write("\x1b[1;1H");

    // Line numbers and editor
    {
        const line_style = Style{ .foreground = Style.grey };
        var iter = self.buffer.lineIterator();
        var i: u32 = 0;
        var skipped: u32 = 0;
        var buf_index: u32 = 0;
        while (iter.next()) |line| {
            if (skipped < self.offset.y) {
                skipped += 1;
                buf_index += @intCast(u32, line.len) + 1;
                continue;
            }
            if (i >= self.size().height) break;

            if (i == self.cursor.pos.y) {
                try writer.print(" {:[1]}", .{ i + skipped + 1, line_len });
                try line_style.print(writer, "│", .{});
            } else try line_style.print(writer, " {:[1]}│", .{ i + skipped + 1, line_len });

            for (line) |c| {
                const highlight = b: {
                    for (self.search_highlights.items) |hl| {
                        if (hl.contains(buf_index)) break :b true;
                    }
                    break :b false;
                };

                if (highlight) {
                    try (Style{ .foreground = Style.grey, .background = Style.pink }).print(writer, "{c}", .{c});
                } else {
                    _ = try writer.write(&.{c});
                }

                buf_index += 1;
            }
            buf_index += 1;
            _ = try writer.write("\x1b[1E");
            i += 1;
        }
    }

    // Cursor position
    _ = try writer.print("\x1b[{};{}H", .{
        self.cursor.pos.y + 1,
        self.cursor.pos.x + line_len + 2 + 1,
    });
}

pub fn deinit(self: *Self) void {
    self.buffer.deinit();
    if (self.current_search) |s| s.deinit();
    if (self.matches) |m| m.deinit();
    self.search_highlights.deinit(self.gpa);
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
    var handler = input.InputHandler.init(gpa);
    defer handler.deinit();
    var state = Self.init(gpa, &terminal, &handler, Buffer.fromSlice(gpa, data));
    defer state.deinit();
    state.have_command_line = false;
    try state.buffer.calculateLines();

    const positions = [_]ds.Position{
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
        state.move(.word_right, .{});
        try std.testing.expectEqual(positions[@intCast(usize, i)], state.cursor.pos);
    }
    i -= 2;
    while (i >= 0) : (i -= 1) {
        state.move(.word_left, .{});
        try std.testing.expectEqual(positions[@intCast(usize, i)], state.cursor.pos);
    }
}

test "state word movement blank line" {
    var gpa = std.testing.allocator;
    const lit =
        \\word
        \\
        \\word
    ;
    var data = try gpa.alloc(u8, lit.len);
    std.mem.copy(u8, data, lit);

    const terminal = Terminal{ .size = .{ .width = 50, .height = 6 } };
    var handler = input.InputHandler.init(gpa);
    defer handler.deinit();
    var state = Self.init(gpa, &terminal, &handler, Buffer.fromSlice(gpa, data));
    defer state.deinit();
    state.have_command_line = false;
    try state.buffer.calculateLines();

    state.move(.word_right, .{});
    try std.testing.expectEqual(ds.Position{ .x = 0, .y = 1 }, state.cursor.pos);

    state.move(.word_right, .{});
    try std.testing.expectEqual(ds.Position{ .x = 0, .y = 2 }, state.cursor.pos);

    state.move(.word_left, .{});
    try std.testing.expectEqual(ds.Position{ .x = 0, .y = 1 }, state.cursor.pos);

    state.move(.word_left, .{});
    try std.testing.expectEqual(ds.Position{ .x = 0, .y = 0 }, state.cursor.pos);
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
    var handler = input.InputHandler.init(gpa);
    defer handler.deinit();
    var state = Self.init(gpa, &terminal, &handler, Buffer.fromSlice(gpa, data));
    defer state.deinit();
    state.have_command_line = false;
    try state.buffer.calculateLines();

    state.move(.down, .{});
    state.move(.down, .{});
    // Top 'q', cursor on 'd'
    try std.testing.expectEqual(ds.Position{ .x = 0, .y = 2 }, state.cursor.pos);
    try std.testing.expectEqual(ds.Position{ .x = 0, .y = 0 }, state.offset);

    state.move(.down, .{});
    // Top 'u', cursor on 'l'
    try std.testing.expectEqual(ds.Position{ .x = 0, .y = 2 }, state.cursor.pos);
    try std.testing.expectEqual(ds.Position{ .x = 0, .y = 1 }, state.offset);

    state.move(.down, .{});
    state.move(.down, .{});
    // Top 'l', cursor on '5'
    try std.testing.expectEqual(ds.Position{ .x = 0, .y = 2 }, state.cursor.pos);
    try std.testing.expectEqual(ds.Position{ .x = 0, .y = 3 }, state.offset);

    state.move(.down, .{});
    // Top still 'l', cursor on '5'
    try std.testing.expectEqual(ds.Position{ .x = 0, .y = 2 }, state.cursor.pos);
    try std.testing.expectEqual(ds.Position{ .x = 0, .y = 3 }, state.offset);

    state.move(.up, .{});
    state.move(.up, .{});
    // Top still 'l', cursor on 'l'
    try std.testing.expectEqual(ds.Position{ .x = 0, .y = 0 }, state.cursor.pos);
    try std.testing.expectEqual(ds.Position{ .x = 0, .y = 3 }, state.offset);

    state.move(.up, .{});
    // Top 'd', cursor on 'd'
    try std.testing.expectEqual(ds.Position{ .x = 0, .y = 0 }, state.cursor.pos);
    try std.testing.expectEqual(ds.Position{ .x = 0, .y = 2 }, state.offset);
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
    var handler = input.InputHandler.init(gpa);
    defer handler.deinit();
    var state = Self.init(gpa, &terminal, &handler, Buffer.fromSlice(gpa, data));
    defer state.deinit();
    state.have_command_line = false;
    try state.buffer.calculateLines();

    state.move(.goto_file_end, .{});
    // Top '6', cursor on '10'
    try std.testing.expectEqual(ds.Position{ .x = 0, .y = 4 }, state.cursor.pos);
    try std.testing.expectEqual(ds.Position{ .x = 0, .y = 5 }, state.offset);

    state.move(.goto_file_top, .{});
    try std.testing.expectEqual(ds.Position{ .x = 0, .y = 0 }, state.cursor.pos);
    try std.testing.expectEqual(ds.Position{ .x = 0, .y = 0 }, state.offset);

    terminal.size.height = 15;
    state.move(.goto_file_end, .{});
    // Top '1', cursor on '10'
    try std.testing.expectEqual(ds.Position{ .x = 0, .y = 9 }, state.cursor.pos);
    try std.testing.expectEqual(ds.Position{ .x = 0, .y = 0 }, state.offset);
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
    var handler = input.InputHandler.init(gpa);
    defer handler.deinit();
    var state = Self.init(gpa, &terminal, &handler, Buffer.fromSlice(gpa, data));
    defer state.deinit();
    state.have_command_line = false;
    try state.buffer.calculateLines();

    state.move(.goto_line_end, .{});
    try std.testing.expectEqual(ds.Position{ .x = 4, .y = 0 }, state.cursor.pos);
    try std.testing.expectEqual(ds.Position{ .x = 0, .y = 0 }, state.offset);

    state.move(.down, .{});
    state.move(.goto_line_start, .{});
    try std.testing.expectEqual(ds.Position{ .x = 0, .y = 1 }, state.cursor.pos);
    try std.testing.expectEqual(ds.Position{ .x = 0, .y = 0 }, state.offset);

    state.move(.goto_line_end, .{});
    try std.testing.expectEqual(ds.Position{ .x = 4, .y = 1 }, state.cursor.pos);
    try std.testing.expectEqual(ds.Position{ .x = 0, .y = 0 }, state.offset);

    state.move(.down, .{});
    state.move(.goto_line_end, .{});
    try std.testing.expectEqual(ds.Position{ .x = 23, .y = 1 }, state.cursor.pos);
    try std.testing.expectEqual(ds.Position{ .x = 0, .y = 1 }, state.offset);
}

test "state goto start of line skip whitespace" {
    var gpa = std.testing.allocator;
    const lit =
        \\helloworldhowareyoutoday
        \\    helloworldhowareyoutoday
    ;
    var data = try gpa.alloc(u8, lit.len);
    std.mem.copy(u8, data, lit);

    var terminal = Terminal{ .size = .{ .width = 100, .height = 2 } };
    var handler = input.InputHandler.init(gpa);
    defer handler.deinit();
    var state = Self.init(gpa, &terminal, &handler, Buffer.fromSlice(gpa, data));
    defer state.deinit();
    state.have_command_line = false;
    try state.buffer.calculateLines();

    state.move(.goto_line_end, .{});
    try std.testing.expectEqual(ds.Position{ .x = 23, .y = 0 }, state.cursor.pos);
    try std.testing.expectEqual(ds.Position{ .x = 0, .y = 0 }, state.offset);

    state.move(.down, .{});
    try std.testing.expectEqual(ds.Position{ .x = 23, .y = 1 }, state.cursor.pos);
    try std.testing.expectEqual(ds.Position{ .x = 0, .y = 0 }, state.offset);

    state.move(.goto_line_start_skip_whitespace, .{});
    try std.testing.expectEqual(ds.Position{ .x = 4, .y = 1 }, state.cursor.pos);
    try std.testing.expectEqual(ds.Position{ .x = 0, .y = 0 }, state.offset);
}

test "state goto line" {
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
    var handler = input.InputHandler.init(gpa);
    defer handler.deinit();
    var state = Self.init(gpa, &terminal, &handler, Buffer.fromSlice(gpa, data));
    defer state.deinit();
    state.have_command_line = false;
    try state.buffer.calculateLines();

    state.move(.goto_line, .{ .repeat = 5 });
    try std.testing.expectEqual(ds.Position{ .x = 0, .y = 4 }, state.cursor.pos);
    try std.testing.expectEqual(ds.Position{ .x = 0, .y = 0 }, state.offset);
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
    var handler = input.InputHandler.init(gpa);
    defer handler.deinit();
    var state = Self.init(gpa, &terminal, &handler, Buffer.fromSlice(gpa, data));
    defer state.deinit();
    state.have_command_line = false;
    try state.buffer.calculateLines();

    state.move(.goto_line_end, .{});
    try std.testing.expectEqual(ds.Position{ .x = 23, .y = 0 }, state.cursor.pos);
    try std.testing.expectEqual(ds.Position{ .x = 0, .y = 0 }, state.offset);

    state.move(.right, .{});
    try std.testing.expectEqual(ds.Position{ .x = 23, .y = 0 }, state.cursor.pos);
    try std.testing.expectEqual(ds.Position{ .x = 0, .y = 0 }, state.offset);

    state.move(.down, .{});
    try std.testing.expectEqual(ds.Position{ .x = 4, .y = 1 }, state.cursor.pos);
    try std.testing.expectEqual(ds.Position{ .x = 0, .y = 0 }, state.offset);

    state.move(.down, .{});
    try std.testing.expectEqual(ds.Position{ .x = 1, .y = 2 }, state.cursor.pos);
    try std.testing.expectEqual(ds.Position{ .x = 0, .y = 0 }, state.offset);
}

test "state page up/down" {
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
    var handler = input.InputHandler.init(gpa);
    defer handler.deinit();
    var state = Self.init(gpa, &terminal, &handler, Buffer.fromSlice(gpa, data));
    defer state.deinit();
    state.have_command_line = false;
    try state.buffer.calculateLines();

    state.move(.down, .{});
    state.move(.page_up, .{});
    // Top '1', cursor on '2'
    try std.testing.expectEqual(ds.Position{ .x = 0, .y = 1 }, state.cursor.pos);
    try std.testing.expectEqual(ds.Position{ .x = 0, .y = 0 }, state.offset);

    state.move(.page_down, .{});
    // Top '5', cursor on '5'
    try std.testing.expectEqual(ds.Position{ .x = 0, .y = 0 }, state.cursor.pos);
    try std.testing.expectEqual(ds.Position{ .x = 0, .y = 4 }, state.offset);

    state.move(.page_down, .{});
    // Top '9', cursor on '9'
    try std.testing.expectEqual(ds.Position{ .x = 0, .y = 0 }, state.cursor.pos);
    try std.testing.expectEqual(ds.Position{ .x = 0, .y = 8 }, state.offset);

    state.move(.page_up, .{});
    // Top '5', cursor on '10'
    try std.testing.expectEqual(ds.Position{ .x = 0, .y = 4 }, state.cursor.pos);
    try std.testing.expectEqual(ds.Position{ .x = 0, .y = 4 }, state.offset);
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
    var handler = input.InputHandler.init(gpa);
    defer handler.deinit();
    var state = Self.init(gpa, &terminal, &handler, Buffer.fromSlice(gpa, data));
    defer state.deinit();
    state.have_command_line = false;
    try state.buffer.calculateLines();

    state.move(.viewport_up, .{});
    try std.testing.expectEqual(ds.Position{ .x = 0, .y = 0 }, state.cursor.pos);
    try std.testing.expectEqual(ds.Position{ .x = 0, .y = 0 }, state.offset);

    state.move(.down, .{});
    state.move(.down, .{});
    // Top '1', cursor '3'
    try std.testing.expectEqual(ds.Position{ .x = 0, .y = 2 }, state.cursor.pos);
    try std.testing.expectEqual(ds.Position{ .x = 0, .y = 0 }, state.offset);

    state.move(.viewport_down, .{});
    state.move(.viewport_down, .{});
    // Top '3', cursor '3'
    try std.testing.expectEqual(ds.Position{ .x = 0, .y = 0 }, state.cursor.pos);
    try std.testing.expectEqual(ds.Position{ .x = 0, .y = 2 }, state.offset);

    state.move(.viewport_down, .{});
    state.move(.viewport_down, .{});
    state.move(.viewport_down, .{});
    state.move(.viewport_down, .{});
    // Top '7', cursor '7'
    try std.testing.expectEqual(ds.Position{ .x = 0, .y = 0 }, state.cursor.pos);
    try std.testing.expectEqual(ds.Position{ .x = 0, .y = 6 }, state.offset);

    state.move(.viewport_up, .{});
    state.move(.viewport_up, .{});
    // Top '5', cursor '7'
    try std.testing.expectEqual(ds.Position{ .x = 0, .y = 2 }, state.cursor.pos);
    try std.testing.expectEqual(ds.Position{ .x = 0, .y = 4 }, state.offset);
}

test "state viewport line to top/bottom/centre" {
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
    var handler = input.InputHandler.init(gpa);
    defer handler.deinit();
    var state = Self.init(gpa, &terminal, &handler, Buffer.fromSlice(gpa, data));
    defer state.deinit();
    state.have_command_line = false;
    try state.buffer.calculateLines();

    state.move(.viewport_line_top, .{});
    try std.testing.expectEqual(ds.Position{ .x = 0, .y = 0 }, state.cursor.pos);
    try std.testing.expectEqual(ds.Position{ .x = 0, .y = 0 }, state.offset);

    state.move(.down, .{});
    state.move(.down, .{});
    // Top '1', cursor '3'
    try std.testing.expectEqual(ds.Position{ .x = 0, .y = 2 }, state.cursor.pos);
    try std.testing.expectEqual(ds.Position{ .x = 0, .y = 0 }, state.offset);

    state.move(.viewport_line_top, .{});
    // Top '3', cursor '3'
    try std.testing.expectEqual(ds.Position{ .x = 0, .y = 0 }, state.cursor.pos);
    try std.testing.expectEqual(ds.Position{ .x = 0, .y = 2 }, state.offset);

    state.move(.viewport_line_bottom, .{});
    // Top '1', cursor '3'
    try std.testing.expectEqual(ds.Position{ .x = 0, .y = 2 }, state.cursor.pos);
    try std.testing.expectEqual(ds.Position{ .x = 0, .y = 0 }, state.offset);

    state.move(.viewport_centre, .{});
    // Top '1', cursor '3'
    try std.testing.expectEqual(ds.Position{ .x = 0, .y = 2 }, state.cursor.pos);
    try std.testing.expectEqual(ds.Position{ .x = 0, .y = 0 }, state.offset);

    state.move(.down, .{});
    state.move(.down, .{});
    // Top '1', cursor '5'
    state.move(.viewport_centre, .{});
    // Top '3', cursor '5'
    try std.testing.expectEqual(ds.Position{ .x = 0, .y = 2 }, state.cursor.pos);
    try std.testing.expectEqual(ds.Position{ .x = 0, .y = 2 }, state.offset);
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
    var handler = input.InputHandler.init(gpa);
    defer handler.deinit();
    var state = Self.init(gpa, &terminal, &handler, Buffer.fromSlice(gpa, data));
    defer state.deinit();
    state.have_command_line = false;
    try state.buffer.calculateLines();

    state.move(.goto_file_end, .{});
    // Top '6', cursor on '10'
    try std.testing.expectEqual(ds.Position{ .x = 0, .y = 4 }, state.cursor.pos);
    try std.testing.expectEqual(ds.Position{ .x = 0, .y = 5 }, state.offset);

    terminal.size.height = 15;
    state.move(.down, .{});
    // Top '6', cursor on '10'
    try std.testing.expectEqual(ds.Position{ .x = 0, .y = 4 }, state.cursor.pos);
    try std.testing.expectEqual(ds.Position{ .x = 0, .y = 5 }, state.offset);
}

test "search multiple one line" {
    var gpa = std.testing.allocator;
    const lit =
        \\const re = @import("re");
        \\
        \\var log_file: std.fs.File = undefined;
        \\
        \\pub fn panic(msg: []const u8, error_return_trace: ?*std.builtin.StackTrace) noreturn {
    ;
    var data = try gpa.alloc(u8, lit.len);
    std.mem.copy(u8, data, lit);

    var terminal = Terminal{ .size = .{ .width = 10, .height = 5 } };
    var handler = input.InputHandler.init(gpa);
    defer handler.deinit();
    var state = Self.init(gpa, &terminal, &handler, Buffer.fromSlice(gpa, data));
    defer state.deinit();
    state.have_command_line = false;
    try state.buffer.calculateLines();

    for ("/re\r") |c| {
        try state.handleInput(&((try handler.handleInput(c)) orelse unreachable));
    }
    try std.testing.expectEqual(ds.Position{ .x = 6, .y = 0 }, state.cursor.pos);

    try state.handleInput(&((try handler.handleInput('n')) orelse unreachable));
    try std.testing.expectEqual(ds.Position{ .x = 20, .y = 0 }, state.cursor.pos);

    try state.handleInput(&((try handler.handleInput('n')) orelse unreachable));
    try std.testing.expectEqual(ds.Position{ .x = 36, .y = 4 }, state.cursor.pos);

    try state.handleInput(&((try handler.handleInput('n')) orelse unreachable));
    try std.testing.expectEqual(ds.Position{ .x = 78, .y = 4 }, state.cursor.pos);
}

test "end of blank line then letter" {
    var gpa = std.testing.allocator;
    const lit =
        \\
        \\hello
    ;
    var data = try gpa.alloc(u8, lit.len);
    std.mem.copy(u8, data, lit);

    var terminal = Terminal{ .size = .{ .width = 10, .height = 5 } };
    var handler = input.InputHandler.init(gpa);
    defer handler.deinit();
    var state = Self.init(gpa, &terminal, &handler, Buffer.fromSlice(gpa, data));
    defer state.deinit();
    state.have_command_line = false;
    try state.buffer.calculateLines();

    for ("Ao") |c| {
        try state.handleInput(&((try handler.handleInput(c)) orelse unreachable));
    }
    try std.testing.expectEqualStrings("o\nhello", state.buffer.data.items);
}

test "backspace at top of viewport" {
    var gpa = std.testing.allocator;
    const lit =
        \\zero
        \\one
        \\two
        \\three
        \\four
    ;
    var data = try gpa.alloc(u8, lit.len);
    std.mem.copy(u8, data, lit);

    var terminal = Terminal{ .size = .{ .width = 10, .height = 2 } };
    var handler = input.InputHandler.init(gpa);
    defer handler.deinit();
    var state = Self.init(gpa, &terminal, &handler, Buffer.fromSlice(gpa, data));
    defer state.deinit();
    state.have_command_line = false;
    try state.buffer.calculateLines();

    state.move(.goto_file_end, .{});
    state.move(.up, .{});
    state.move(.goto_line_start, .{});
    try std.testing.expectEqual(ds.Position{ .x = 0, .y = 0 }, state.cursor.pos);
    try std.testing.expectEqual(ds.Position{ .x = 0, .y = 3 }, state.offset);

    for ([_]u8{ 'i', 127 }) |c| {
        try state.handleInput(&((try handler.handleInput(c)) orelse unreachable));
    }

    try std.testing.expectEqual(ds.Position{ .x = 3, .y = 0 }, state.cursor.pos);
    try std.testing.expectEqual(ds.Position{ .x = 0, .y = 2 }, state.offset);
}

test "autoindent" {
    var gpa = std.testing.allocator;
    const lit =
        \\  hello
        \\  world
    ;
    var data = try gpa.alloc(u8, lit.len);
    std.mem.copy(u8, data, lit);

    var terminal = Terminal{ .size = .{ .width = 10, .height = 5 } };
    var handler = input.InputHandler.init(gpa);
    defer handler.deinit();
    var state = Self.init(gpa, &terminal, &handler, Buffer.fromSlice(gpa, data));
    defer state.deinit();
    state.have_command_line = false;
    try state.buffer.calculateLines();

    state.move(.down, .{});

    for ("O1") |c| {
        try state.handleInput(&((try handler.handleInput(c)) orelse unreachable));
    }
    try std.testing.expectEqualStrings("  hello\n  1\n  world", state.buffer.data.items);

    try state.handleInput(&((try handler.handleInput('\x1b')) orelse unreachable));
    for ("o2") |c| {
        try state.handleInput(&((try handler.handleInput(c)) orelse unreachable));
    }
    try std.testing.expectEqualStrings("  hello\n  1\n  2\n  world", state.buffer.data.items);

    for ("\r3") |c| {
        try state.handleInput(&((try handler.handleInput(c)) orelse unreachable));
    }
    try std.testing.expectEqualStrings("  hello\n  1\n  2\n  3\n  world", state.buffer.data.items);
}
