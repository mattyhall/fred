const std = @import("std");
const ds = @import("ds.zig");

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
    split: ds.Direction,
    insertion: u8,
    copy_whitespace_from_above: void,
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
    goto_line_start_skip_whitespace,
    goto_line_end,
    goto_line_end_plus_one,
};

pub const MovementOpts = struct {
    allow_past_last_column: bool = false,
    repeat: u32 = 1,
};

pub const NormalModeState = enum { none, goto, viewport, viewport_sticky };

pub const Mode = union(enum) {
    normal: NormalModeState,
    insert,
    command,
    search,
    window,
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
                        instructions[3] = .copy_whitespace_from_above;
                        return instructions;
                    },
                    '1', '2', '3', '4', '5', '6', '7', '8', '9', '0' => {
                        inhibit_clear_repeat = true;
                        try self.repeat.append(self.gpa, c);
                        return instructions;
                    },
                    23 => {
                        self.mode = .window;
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
                    'i' => blk: {
                        self.mode = .{ .normal = .none };
                        break :blk Movement.goto_line_start_skip_whitespace;
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
            .window => switch (c) {
                's' => {
                    instructions[0] = .{ .split = .horizontal };
                    self.mode = .{ .normal = .none };
                    return instructions;
                },
                'v' => {
                    instructions[0] = .{ .split = .vertical};
                    self.mode = .{ .normal = .none };
                    return instructions;
                },
                else => {
                    self.mode = .{ .normal = .none };
                    return instructions;
                }
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
