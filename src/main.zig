const std = @import("std");
const Terminal = @import("Terminal.zig");
const Style = @import("Style.zig");
const re = @import("re");

var log_file: std.fs.File = undefined;

pub fn panic(msg: []const u8, error_return_trace: ?*std.builtin.StackTrace) noreturn {
    Terminal.cleanupTerminal();
    const first_trace_addr = @returnAddress();
    std.debug.panicImpl(error_return_trace, first_trace_addr, msg);
}

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

    pub fn contains(self: Span, v: u32) bool {
        return v >= self.start and v < self.end;
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
    path: ?[]const u8 = null,

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

    fn openFile(path: []const u8) !std.fs.File {
        const f = if (path[0] == '/')
            try (try std.fs.openDirAbsolute(
                std.fs.path.dirname(path) orelse return error.file_not_found,
                .{},
            )).openFile(std.fs.path.basename(path), .{ .mode = .read_write })
        else
            try std.fs.cwd().openFile(path, .{ .mode = .read_write });
        return f;
    }

    pub fn fromFile(allocator: std.mem.Allocator, path: []const u8) !Self {
        var f = try openFile(path);
        defer f.close();

        var data = try f.readToEndAlloc(allocator, 2 * 1024 * 1024);
        var self = fromSlice(allocator, data);
        self.path = path;
        return self;
    }

    pub fn fromSlice(allocator: std.mem.Allocator, data: []u8) Self {
        return Self{
            .gpa = allocator,
            .data = std.ArrayListUnmanaged(u8){ .items = data, .capacity = data.len },
            .lines = std.ArrayListUnmanaged(u32){},
        };
    }

    pub fn save(self: *const Self) !void {
        const p = self.path orelse return error.no_path;
        var f = try openFile(p);
        defer f.close();
        try f.writeAll(self.data.items);
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

pub const Instruction = union(enum) {
    noop: void,
    movement: struct { movement: Movement, opts: MovementOpts = .{} },
    command: std.ArrayList(u8),
    search: union(enum) {
        complete: std.ArrayList(u8),
        quit: void,
        char: void,
        next: void,
    },
    insertion: u8,
};

pub const Movement = union(enum) {
    up,
    down,
    left,
    right,
    word_left,
    word_right,
    page_up,
    page_down,
    viewport_up,
    viewport_down,
    viewport_centre,
    viewport_line_top,
    viewport_line_bottom,
    goto_line,
    goto_file_top,
    goto_file_end,
    goto_line_start,
    goto_line_end,
    goto_line_end_plus_one,
};

pub const MovementOpts = struct {
    allow_past_last_column: bool = false,
    repeat: u32 = 1,
};

pub const State = struct {
    cursor: Cursor = .{ .pos = .{ .x = 0, .y = 0 } },
    offset: Position = .{ .x = 0, .y = 0 },

    gpa: std.mem.Allocator,

    terminal_size: *const Terminal.Size,
    buffer: Buffer,
    input_handler: InputHandler,

    current_search: ?std.ArrayList(u8) = null,
    search_highlights: std.ArrayListUnmanaged(Span),
    matches: ?re.Matches = null,
    valid_regex: bool = true,

    have_command_line: bool = true,

    pub fn init(gpa: std.mem.Allocator, terminal: *const Terminal, buffer: Buffer) State {
        return .{
            .gpa = gpa,
            .terminal_size = &terminal.size,
            .buffer = buffer,
            .input_handler = InputHandler.init(gpa),
            .search_highlights = .{},
        };
    }

    /// Returns the size allocated to the buffer
    pub fn size(self: *const State) Terminal.Size {
        var sz = self.terminal_size.*;
        if (self.have_command_line)
            sz.height -= 1;
        return sz;
    }

    fn bufferCursorPos(self: *const State) Position {
        return .{ .x = self.cursor.pos.x + self.offset.x, .y = self.cursor.pos.y + self.offset.y };
    }

    fn bufferIndex(self: *const State) usize {
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

    fn putCursorAtIndex(self: *State, index: usize) void {
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
        } else {
            @panic("not sure how to handle this yet");
        }
    }

    fn moveToNextMatch(self: *State, col: u32, row: u32, skip_current: bool) void {
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

    fn refindMatches(self: *State) !void {
        if (self.current_search) |s|
            _ = try self.findMatches(s.items);
    }

    fn findMatches(self: *State, s: []const u8) !bool {
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

    fn handleInput(self: *State, ch: u8) !void {
        const input = (try self.input_handler.handleInput(ch)) orelse return;
        for (input) |i| {
            switch (i) {
                .movement => |m| self.move(m.movement, m.opts),
                .command => |al| {
                    if (std.mem.eql(u8, "q", al.items)) std.os.exit(0);
                    if (std.mem.eql(u8, "w", al.items)) try self.buffer.save();
                    al.deinit();
                },
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
                            _ = self.buffer.data.orderedRemove(index - 1);
                            try self.buffer.calculateLines();
                            try self.refindMatches();
                            self.putCursorAtIndex(index - 1);
                        },
                        13 => { // RET
                            try self.buffer.data.insert(self.buffer.gpa, index, '\n');
                            try self.buffer.calculateLines();
                            try self.refindMatches();
                            self.move(.down, .{});
                            self.move(.goto_line_start, .{});
                        },
                        else => {
                            try self.buffer.data.insert(self.buffer.gpa, index, c);
                            try self.buffer.calculateLines();
                            try self.refindMatches();
                            self.move(.right, .{ .allow_past_last_column = true });
                        },
                    }
                },
                .noop => {},
            }
        }
    }

    fn move(self: *State, movement: Movement, opts: MovementOpts) void {
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

        // Command
        if (self.input_handler.mode == .command) {
            try writer.print(":{s}", .{self.input_handler.cmd.items});
        } else if (self.input_handler.mode == .search) {
            const colour = if (self.valid_regex) Style.green else Style.red;
            try (Style{ .foreground = Style.grey, .background = colour }).print(writer, "search:", .{});
            try writer.print(" {s}", .{self.input_handler.cmd.items});
        } else {
            // Cursor position
            _ = try writer.print("\x1b[{};{}H", .{
                self.cursor.pos.y + 1,
                self.cursor.pos.x + line_len + 2 + 1,
            });
        }

        if (self.input_handler.mode == .insert) {
            // Bar cursor
            _ = try writer.write("\x1b[6 q");
        } else {
            // Block cursor
            _ = try writer.write("\x1b[2 q");
        }
    }

    pub fn deinit(self: *State) void {
        self.buffer.deinit();
        self.input_handler.deinit();
        if (self.current_search) |s| s.deinit();
        if (self.matches) |m| m.deinit();
        self.search_highlights.deinit(self.gpa);
    }
};

pub const NormalModeState = enum { none, goto, viewport, viewport_sticky };

pub const Mode = union(enum) {
    normal: NormalModeState,
    insert,
    command,
    search,
};

pub const InputHandler = struct {
    gpa: std.mem.Allocator,
    mode: Mode = .{ .normal = .none },
    cmd: std.ArrayListUnmanaged(u8),
    repeat: std.ArrayListUnmanaged(u8),

    pub fn init(allocator: std.mem.Allocator) InputHandler {
        return .{ .gpa = allocator, .cmd = std.ArrayListUnmanaged(u8){}, .repeat = std.ArrayListUnmanaged(u8){} };
    }

    pub fn deinit(self: *InputHandler) void {
        self.cmd.deinit(self.gpa);
    }

    pub fn handleInput(self: *InputHandler, c: u8) !?[16]Instruction {
        var instructions: [16]Instruction = .{
            .noop, .noop, .noop, .noop,
            .noop, .noop, .noop, .noop,
            .noop, .noop, .noop, .noop,
            .noop, .noop, .noop, .noop,
        };
        var inhibit_clear_repeat = false;
        defer b: {
            if (inhibit_clear_repeat) break :b;
            self.repeat.clearRetainingCapacity();
        }
        const movement = switch (self.mode) {
            .normal => |state| switch (state) {
                .none => switch (c) {
                    'j' => Movement.down,
                    'k' => Movement.up,
                    'l' => Movement.right,
                    'h' => Movement.left,
                    'w' => Movement.word_right,
                    'b' => Movement.word_left,
                    2 => Movement.page_up,
                    6 => Movement.page_down,
                    'g' => b: {
                        if (self.repeat.items.len != 0) break :b Movement.goto_line;

                        self.mode = .{ .normal = .goto };
                        return instructions;
                    },
                    'v' => {
                        self.mode = .{ .normal = .viewport };
                        return instructions;
                    },
                    'V' => {
                        self.mode = .{ .normal = .viewport_sticky };
                        return instructions;
                    },
                    ':' => {
                        self.mode = .command;
                        return instructions;
                    },
                    '/' => {
                        self.mode = .search;
                        return instructions;
                    },
                    'n' => {
                        instructions[0] = Instruction{ .search = .next };
                        return instructions;
                    },
                    'i' => {
                        self.mode = .insert;
                        return instructions;
                    },
                    'a', 'A' => {
                        self.mode = .insert;
                        instructions[0] = .{ .movement = .{
                            .movement = switch (c) {
                                'a' => Movement.right,
                                'A' => Movement.goto_line_end_plus_one,
                                else => unreachable,
                            },
                            .opts = .{ .allow_past_last_column = true },
                        } };
                        return instructions;
                    },
                    'o' => {
                        self.mode = .insert;

                        instructions[0] = Instruction{
                            .movement = .{
                                .movement = Movement.goto_line_end_plus_one,
                                .opts = .{ .allow_past_last_column = true },
                            },
                        };
                        instructions[1] = Instruction{ .insertion = 13 };
                        return instructions;
                    },
                    'O' => {
                        self.mode = .insert;
                        instructions[0] = .{
                            .movement = .{
                                .movement = Movement.goto_line_start,
                                .opts = .{ .allow_past_last_column = true },
                            },
                        };
                        instructions[1] = .{ .insertion = 13 };
                        instructions[2] = .{ .movement = .{ .movement = Movement.up } };
                        instructions[3] = .{ .movement = .{ .movement = Movement.goto_line_start } };
                        return instructions;
                    },
                    '1', '2', '3', '4', '5', '6', '7', '8', '9', '0' => {
                        inhibit_clear_repeat = true;
                        try self.repeat.append(self.gpa, c);
                        return instructions;
                    },
                    else => return instructions,
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
                        return instructions;
                    },
                },
                .viewport, .viewport_sticky => b: {
                    const movement = switch (c) {
                        'j' => Movement.viewport_down,
                        'k' => Movement.viewport_up,
                        't' => Movement.viewport_line_top,
                        'c' => Movement.viewport_centre,
                        'b' => Movement.viewport_line_bottom,
                        else => {
                            self.mode = .{ .normal = .none };
                            return instructions;
                        },
                    };
                    if (state == .viewport) {
                        self.mode = .{ .normal = .none };
                    }
                    break :b movement;
                },
            },
            .command => switch (c) {
                13 => {
                    // RET
                    const al = self.cmd.toManaged(self.gpa);
                    self.cmd = .{};
                    self.mode = .{ .normal = .none };
                    instructions[0] = .{ .command = al };
                    return instructions;
                },
                27 => {
                    // ESC
                    self.mode = .{ .normal = .none };
                    self.cmd.clearRetainingCapacity();
                    return instructions;
                },
                else => {
                    if (c < 32 or c > 126) return instructions;
                    try self.cmd.append(self.gpa, c);
                    return instructions;
                },
            },
            .search => switch (c) {
                13 => {
                    // RET
                    const al = self.cmd.toManaged(self.gpa);
                    self.cmd = .{};
                    self.mode = .{ .normal = .none };
                    instructions[0] = .{ .search = .{ .complete = al } };
                    return instructions;
                },
                27 => {
                    // ESC
                    self.mode = .{ .normal = .none };
                    self.cmd.clearRetainingCapacity();
                    instructions[0] = .{ .search = .quit };
                    return instructions;
                },
                127 => {
                    _ = self.cmd.popOrNull();
                    instructions[0] = .{ .search = .char };
                    return instructions;
                },
                else => {
                    if (c < 32 or c > 126) return instructions;
                    try self.cmd.append(self.gpa, c);
                    instructions[0] = .{ .search = .char };
                    return instructions;
                },
            },
            .insert => switch (c) {
                27 => {
                    // ESC
                    self.mode = .{ .normal = .none };
                    // Not sure why we need to do this - possible miscomp?
                    instructions[0] = .noop;
                    return instructions;
                },
                else => {
                    instructions[0] = .{ .insertion = c };
                    return instructions;
                },
            },
        };

        instructions[0] = Instruction{
            .movement = .{
                .movement = movement,
                .opts = .{
                    .repeat = if (self.repeat.items.len == 0) 1 else try std.fmt.parseInt(u32, self.repeat.items, 10),
                },
            },
        };
        return instructions;
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

    var state = State.init(allocator, terminal, try Buffer.fromFile(allocator, path));
    defer state.deinit();
    try state.buffer.calculateLines();

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
                try state.handleInput(ch);
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
    var state = State.init(gpa, &terminal, Buffer.fromSlice(gpa, data));
    defer state.deinit();
    state.have_command_line = false;
    try state.buffer.calculateLines();

    state.move(.left, .{});
    try std.testing.expectEqual(Position{ .x = 0, .y = 0 }, state.cursor.pos);

    state.move(.up, .{});
    try std.testing.expectEqual(Position{ .x = 0, .y = 0 }, state.cursor.pos);

    state.move(.right, .{});
    try std.testing.expectEqual(Position{ .x = 1, .y = 0 }, state.cursor.pos);

    state.move(.down, .{});
    try std.testing.expectEqual(Position{ .x = 1, .y = 1 }, state.cursor.pos);

    state.move(.down, .{});
    state.move(.down, .{});
    state.move(.down, .{});
    state.move(.right, .{});
    state.move(.right, .{});
    state.move(.right, .{});
    try std.testing.expectEqual(Position{ .x = 4, .y = 4 }, state.cursor.pos);

    state.move(.up, .{});
    state.move(.up, .{});
    state.move(.up, .{});
    state.move(.left, .{});
    state.move(.left, .{});
    state.move(.left, .{});
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
    var state = State.init(gpa, &terminal, Buffer.fromSlice(gpa, data));
    defer state.deinit();
    state.have_command_line = false;
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
    var state = State.init(gpa, &terminal, Buffer.fromSlice(gpa, data));
    defer state.deinit();
    state.have_command_line = false;
    try state.buffer.calculateLines();

    state.move(.word_right, .{});
    try std.testing.expectEqual(Position{ .x = 0, .y = 1 }, state.cursor.pos);

    state.move(.word_right, .{});
    try std.testing.expectEqual(Position{ .x = 0, .y = 2 }, state.cursor.pos);

    state.move(.word_left, .{});
    try std.testing.expectEqual(Position{ .x = 0, .y = 1 }, state.cursor.pos);

    state.move(.word_left, .{});
    try std.testing.expectEqual(Position{ .x = 0, .y = 0 }, state.cursor.pos);
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
    var state = State.init(gpa, &terminal, Buffer.fromSlice(gpa, data));
    defer state.deinit();
    state.have_command_line = false;
    try state.buffer.calculateLines();

    state.move(.down, .{});
    state.move(.down, .{});
    // Top 'q', cursor on 'd'
    try std.testing.expectEqual(Position{ .x = 0, .y = 2 }, state.cursor.pos);
    try std.testing.expectEqual(Position{ .x = 0, .y = 0 }, state.offset);

    state.move(.down, .{});
    // Top 'u', cursor on 'l'
    try std.testing.expectEqual(Position{ .x = 0, .y = 2 }, state.cursor.pos);
    try std.testing.expectEqual(Position{ .x = 0, .y = 1 }, state.offset);

    state.move(.down, .{});
    state.move(.down, .{});
    // Top 'l', cursor on '5'
    try std.testing.expectEqual(Position{ .x = 0, .y = 2 }, state.cursor.pos);
    try std.testing.expectEqual(Position{ .x = 0, .y = 3 }, state.offset);

    state.move(.down, .{});
    // Top still 'l', cursor on '5'
    try std.testing.expectEqual(Position{ .x = 0, .y = 2 }, state.cursor.pos);
    try std.testing.expectEqual(Position{ .x = 0, .y = 3 }, state.offset);

    state.move(.up, .{});
    state.move(.up, .{});
    // Top still 'l', cursor on 'l'
    try std.testing.expectEqual(Position{ .x = 0, .y = 0 }, state.cursor.pos);
    try std.testing.expectEqual(Position{ .x = 0, .y = 3 }, state.offset);

    state.move(.up, .{});
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
    var state = State.init(gpa, &terminal, Buffer.fromSlice(gpa, data));
    defer state.deinit();
    state.have_command_line = false;
    try state.buffer.calculateLines();

    state.move(.goto_file_end, .{});
    // Top '6', cursor on '10'
    try std.testing.expectEqual(Position{ .x = 0, .y = 4 }, state.cursor.pos);
    try std.testing.expectEqual(Position{ .x = 0, .y = 5 }, state.offset);

    state.move(.goto_file_top, .{});
    try std.testing.expectEqual(Position{ .x = 0, .y = 0 }, state.cursor.pos);
    try std.testing.expectEqual(Position{ .x = 0, .y = 0 }, state.offset);

    terminal.size.height = 15;
    state.move(.goto_file_end, .{});
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
    var state = State.init(gpa, &terminal, Buffer.fromSlice(gpa, data));
    defer state.deinit();
    state.have_command_line = false;
    try state.buffer.calculateLines();

    state.move(.goto_line_end, .{});
    try std.testing.expectEqual(Position{ .x = 4, .y = 0 }, state.cursor.pos);
    try std.testing.expectEqual(Position{ .x = 0, .y = 0 }, state.offset);

    state.move(.down, .{});
    state.move(.goto_line_start, .{});
    try std.testing.expectEqual(Position{ .x = 0, .y = 1 }, state.cursor.pos);
    try std.testing.expectEqual(Position{ .x = 0, .y = 0 }, state.offset);

    state.move(.goto_line_end, .{});
    try std.testing.expectEqual(Position{ .x = 4, .y = 1 }, state.cursor.pos);
    try std.testing.expectEqual(Position{ .x = 0, .y = 0 }, state.offset);

    state.move(.down, .{});
    state.move(.goto_line_end, .{});
    try std.testing.expectEqual(Position{ .x = 23, .y = 1 }, state.cursor.pos);
    try std.testing.expectEqual(Position{ .x = 0, .y = 1 }, state.offset);
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
    var state = State.init(gpa, &terminal, Buffer.fromSlice(gpa, data));
    defer state.deinit();
    state.have_command_line = false;
    try state.buffer.calculateLines();

    state.move(.goto_line, .{ .repeat = 5 });
    try std.testing.expectEqual(Position{ .x = 0, .y = 4 }, state.cursor.pos);
    try std.testing.expectEqual(Position{ .x = 0, .y = 0 }, state.offset);
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
    var state = State.init(gpa, &terminal, Buffer.fromSlice(gpa, data));
    defer state.deinit();
    state.have_command_line = false;
    try state.buffer.calculateLines();

    state.move(.goto_line_end, .{});
    try std.testing.expectEqual(Position{ .x = 23, .y = 0 }, state.cursor.pos);
    try std.testing.expectEqual(Position{ .x = 0, .y = 0 }, state.offset);

    state.move(.right, .{});
    try std.testing.expectEqual(Position{ .x = 23, .y = 0 }, state.cursor.pos);
    try std.testing.expectEqual(Position{ .x = 0, .y = 0 }, state.offset);

    state.move(.down, .{});
    try std.testing.expectEqual(Position{ .x = 4, .y = 1 }, state.cursor.pos);
    try std.testing.expectEqual(Position{ .x = 0, .y = 0 }, state.offset);

    state.move(.down, .{});
    try std.testing.expectEqual(Position{ .x = 1, .y = 2 }, state.cursor.pos);
    try std.testing.expectEqual(Position{ .x = 0, .y = 0 }, state.offset);
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
    var state = State.init(gpa, &terminal, Buffer.fromSlice(gpa, data));
    defer state.deinit();
    state.have_command_line = false;
    try state.buffer.calculateLines();

    state.move(.down, .{});
    state.move(.page_up, .{});
    // Top '1', cursor on '2'
    try std.testing.expectEqual(Position{ .x = 0, .y = 1 }, state.cursor.pos);
    try std.testing.expectEqual(Position{ .x = 0, .y = 0 }, state.offset);

    state.move(.page_down, .{});
    // Top '5', cursor on '5'
    try std.testing.expectEqual(Position{ .x = 0, .y = 0 }, state.cursor.pos);
    try std.testing.expectEqual(Position{ .x = 0, .y = 4 }, state.offset);

    state.move(.page_down, .{});
    // Top '9', cursor on '9'
    try std.testing.expectEqual(Position{ .x = 0, .y = 0 }, state.cursor.pos);
    try std.testing.expectEqual(Position{ .x = 0, .y = 8 }, state.offset);

    state.move(.page_up, .{});
    // Top '5', cursor on '10'
    try std.testing.expectEqual(Position{ .x = 0, .y = 4 }, state.cursor.pos);
    try std.testing.expectEqual(Position{ .x = 0, .y = 4 }, state.offset);
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
    var state = State.init(gpa, &terminal, Buffer.fromSlice(gpa, data));
    defer state.deinit();
    state.have_command_line = false;
    try state.buffer.calculateLines();

    state.move(.viewport_up, .{});
    try std.testing.expectEqual(Position{ .x = 0, .y = 0 }, state.cursor.pos);
    try std.testing.expectEqual(Position{ .x = 0, .y = 0 }, state.offset);

    state.move(.down, .{});
    state.move(.down, .{});
    // Top '1', cursor '3'
    try std.testing.expectEqual(Position{ .x = 0, .y = 2 }, state.cursor.pos);
    try std.testing.expectEqual(Position{ .x = 0, .y = 0 }, state.offset);

    state.move(.viewport_down, .{});
    state.move(.viewport_down, .{});
    // Top '3', cursor '3'
    try std.testing.expectEqual(Position{ .x = 0, .y = 0 }, state.cursor.pos);
    try std.testing.expectEqual(Position{ .x = 0, .y = 2 }, state.offset);

    state.move(.viewport_down, .{});
    state.move(.viewport_down, .{});
    state.move(.viewport_down, .{});
    state.move(.viewport_down, .{});
    // Top '7', cursor '7'
    try std.testing.expectEqual(Position{ .x = 0, .y = 0 }, state.cursor.pos);
    try std.testing.expectEqual(Position{ .x = 0, .y = 6 }, state.offset);

    state.move(.viewport_up, .{});
    state.move(.viewport_up, .{});
    // Top '5', cursor '7'
    try std.testing.expectEqual(Position{ .x = 0, .y = 2 }, state.cursor.pos);
    try std.testing.expectEqual(Position{ .x = 0, .y = 4 }, state.offset);
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
    var state = State.init(gpa, &terminal, Buffer.fromSlice(gpa, data));
    defer state.deinit();
    state.have_command_line = false;
    try state.buffer.calculateLines();

    state.move(.viewport_line_top, .{});
    try std.testing.expectEqual(Position{ .x = 0, .y = 0 }, state.cursor.pos);
    try std.testing.expectEqual(Position{ .x = 0, .y = 0 }, state.offset);

    state.move(.down, .{});
    state.move(.down, .{});
    // Top '1', cursor '3'
    try std.testing.expectEqual(Position{ .x = 0, .y = 2 }, state.cursor.pos);
    try std.testing.expectEqual(Position{ .x = 0, .y = 0 }, state.offset);

    state.move(.viewport_line_top, .{});
    // Top '3', cursor '3'
    try std.testing.expectEqual(Position{ .x = 0, .y = 0 }, state.cursor.pos);
    try std.testing.expectEqual(Position{ .x = 0, .y = 2 }, state.offset);

    state.move(.viewport_line_bottom, .{});
    // Top '1', cursor '3'
    try std.testing.expectEqual(Position{ .x = 0, .y = 2 }, state.cursor.pos);
    try std.testing.expectEqual(Position{ .x = 0, .y = 0 }, state.offset);

    state.move(.viewport_centre, .{});
    // Top '1', cursor '3'
    try std.testing.expectEqual(Position{ .x = 0, .y = 2 }, state.cursor.pos);
    try std.testing.expectEqual(Position{ .x = 0, .y = 0 }, state.offset);

    state.move(.down, .{});
    state.move(.down, .{});
    // Top '1', cursor '5'
    state.move(.viewport_centre, .{});
    // Top '3', cursor '5'
    try std.testing.expectEqual(Position{ .x = 0, .y = 2 }, state.cursor.pos);
    try std.testing.expectEqual(Position{ .x = 0, .y = 2 }, state.offset);
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
    var state = State.init(gpa, &terminal, Buffer.fromSlice(gpa, data));
    defer state.deinit();
    state.have_command_line = false;
    try state.buffer.calculateLines();

    state.move(.goto_file_end, .{});
    // Top '6', cursor on '10'
    try std.testing.expectEqual(Position{ .x = 0, .y = 4 }, state.cursor.pos);
    try std.testing.expectEqual(Position{ .x = 0, .y = 5 }, state.offset);

    terminal.size.height = 15;
    state.move(.down, .{});
    // Top '6', cursor on '10'
    try std.testing.expectEqual(Position{ .x = 0, .y = 4 }, state.cursor.pos);
    try std.testing.expectEqual(Position{ .x = 0, .y = 5 }, state.offset);
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
    var state = State.init(gpa, &terminal, Buffer.fromSlice(gpa, data));
    defer state.deinit();
    state.have_command_line = false;
    try state.buffer.calculateLines();

    for ("/re\r") |c| {
        try state.handleInput(c);
    }
    try std.testing.expectEqual(Position{ .x = 6, .y = 0 }, state.cursor.pos);

    try state.handleInput('n');
    try std.testing.expectEqual(Position{ .x = 20, .y = 0 }, state.cursor.pos);

    try state.handleInput('n');
    try std.testing.expectEqual(Position{ .x = 36, .y = 4 }, state.cursor.pos);

    try state.handleInput('n');
    try std.testing.expectEqual(Position{ .x = 78, .y = 4 }, state.cursor.pos);
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
    var state = State.init(gpa, &terminal, Buffer.fromSlice(gpa, data));
    defer state.deinit();
    state.have_command_line = false;
    try state.buffer.calculateLines();

    for ("Ao") |c| {
        try state.handleInput(c);
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
    var state = State.init(gpa, &terminal, Buffer.fromSlice(gpa, data));
    defer state.deinit();
    state.have_command_line = false;
    try state.buffer.calculateLines();

    state.move(.goto_file_end, .{});
    state.move(.up, .{});
    state.move(.goto_line_start, .{});
    try std.testing.expectEqual(Position{ .x = 0, .y = 0 }, state.cursor.pos);
    try std.testing.expectEqual(Position{ .x = 0, .y = 3 }, state.offset);

    for ([_]u8{ 'i', 127 }) |c| {
        try state.handleInput(c);
    }

    try std.testing.expectEqual(Position{ .x = 3, .y = 0 }, state.cursor.pos);
    try std.testing.expectEqual(Position{ .x = 0, .y = 2 }, state.offset);
}
