const std = @import("std");
const State = @import("State.zig");
const Style = @import("Style.zig");
const Terminal = @import("Terminal.zig");
const input = @import("input.zig");

const Self = @This();

gpa: std.mem.Allocator,

terminal_size: *const Terminal.Size,

current_buffer: u32,
buffers: std.ArrayListUnmanaged(State),

input_handler: input.InputHandler,

pub fn init(allocator: std.mem.Allocator, terminal: *const Terminal) Self {
    return Self{
        .gpa = allocator,
        .current_buffer = 0,
        .buffers = std.ArrayListUnmanaged(State){},
        .input_handler = input.InputHandler.init(allocator),
        .terminal_size = &terminal.size,
    };
}

fn current(self: *const Self) *State {
    return &self.buffers.items[self.current_buffer];
}

pub fn addBuffer(self: *Self, state: State) !void {
    try self.buffers.append(self.gpa, state);
    try self.buffers.items[self.buffers.items.len - 1].buffer.calculateLines();
}

pub fn handleInput(self: *Self, ch: u8) !void {
    const instructions = (try self.input_handler.handleInput(ch)) orelse return;
    switch (instructions[0]) {
        .command => |al| {
            if (std.mem.eql(u8, "q", al.items)) std.os.exit(0);
            if (std.mem.eql(u8, "w", al.items)) try self.current().buffer.save();
            al.deinit();
            return;
        },
        else => {},
    }

    try self.current().handleInput(&instructions);
}

pub fn draw(self: *const Self, writer: anytype) !void {
    // Clear and go to bottom
    _ = try writer.write("\x1b[2J");
    _ = try writer.print("\x1b[{};{}H", .{ self.terminal_size.height, 1 });

    // Command
    if (self.input_handler.mode == .command) {
        try writer.print(":{s}", .{self.input_handler.cmd.items});
    } else if (self.input_handler.mode == .search) {
        const colour = if (self.current().valid_regex) Style.green else Style.red;
        try (Style{ .foreground = Style.grey, .background = colour }).print(writer, "search:", .{});
        try writer.print(" {s}", .{self.input_handler.cmd.items});
    } else {
        try self.drawStatusLine(writer);
    }

    if (self.input_handler.mode == .insert) {
        // Bar cursor
        _ = try writer.write("\x1b[6 q");
    } else {
        // Block cursor
        _ = try writer.write("\x1b[2 q");
    }

    try self.current().draw(writer);
}

fn drawStatusLine(self: *const Self, writer: anytype) !void {
    var buf: [1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);

    const b = self.current();

    const pos = b.bufferCursorPos();
    const pos_s = try std.fmt.allocPrint(fba.allocator(), "{}:{}", .{ pos.y + 1, pos.x + 1 });

    const pc = (pos.y * 100) / b.buffer.lines.items.len;
    const pc_s = try std.fmt.allocPrint(fba.allocator(), "{}%", .{pc});

    const path = b.buffer.path orelse @as([]const u8, std.mem.sliceTo("scratch", 0));

    const modified = if (b.buffer.dirty) "[+]" else "";

    const len = path.len + modified.len + 1 + pos_s.len + 1 + pc_s.len;

    _ = try writer.print("\x1b[{};{}H", .{
        self.terminal_size.height,
        self.terminal_size.width - len - 1,
    });

    try (Style{ .foreground = Style.green }).print(writer, "{s}{s} ", .{ path, modified });
    try (Style{ .foreground = Style.blue }).print(writer, "{s} ", .{pos_s});
    try (Style{ .foreground = Style.blue }).print(writer, "{s}", .{pc_s});
}

pub fn deinit(self: *Self) void {
    for (self.buffers.items) |*b| {
        b.deinit();
    }
    self.buffers.deinit(self.gpa);
}
