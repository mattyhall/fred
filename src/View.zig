const std = @import("std");
const Buffer = @import("Buffer.zig");
const State = @import("State.zig");
const Style = @import("Style.zig");
const Terminal = @import("Terminal.zig");
const input = @import("input.zig");

const Self = @This();

gpa: std.mem.Allocator,

size: Terminal.Size,

current_buffer: usize,
buffers: std.ArrayListUnmanaged(State),

input_handler: input.InputHandler,

event_fd: std.os.fd_t,

pub fn init(allocator: std.mem.Allocator) Self {
    return Self{
        .gpa = allocator,
        .current_buffer = 0,
        .buffers = std.ArrayListUnmanaged(State){},
        .input_handler = input.InputHandler.init(allocator),
        .size = .{ .width = 80, .height = 80 },
        .event_fd = std.os.eventfd(0, 0) catch unreachable,
    };
}

pub fn current(self: *const Self) *State {
    return &self.buffers.items[self.current_buffer];
}

fn bufferChanged(self: *Self, buffer: *const Buffer) void {
    if (self.current().buffer == buffer) {
        _ = std.os.write(self.event_fd, &[_]u8{ 0, 0, 0, 0, 0, 0, 0, 1 }) catch unreachable;
    }
}

pub fn addBuffer(self: *Self, buffer: *Buffer) !void {
    try buffer.register(bufferChanged, self);
    try self.buffers.append(self.gpa, State.init(self.gpa, &self.size, &self.input_handler, buffer));
    try self.buffers.items[self.buffers.items.len - 1].buffer.calculateLines();
}

pub fn handleInstructions(self: *Self, instructions: []const input.Instruction) !void {
    self.current().buffer.lock.lock();
    defer self.current().buffer.lock.unlock();

    try self.current().handleInput(instructions);
}

pub fn draw(self: *const Self, writer: anytype) !void {
    self.current().buffer.lock.lock();
    defer self.current().buffer.lock.unlock();

    std.log.debug("size: {any}", .{self.size});

    // Clear
    _ = try writer.write("\x1b[2J");

    try self.current().draw(writer);

    // Goto bottom
    _ = try writer.print("\x1b[{};{}H", .{ self.size.height, 1 });

    // Command
    if (self.input_handler.mode == .command) {
        try writer.print(":{s}", .{self.input_handler.cmd.items});
    } else if (self.input_handler.mode == .search) {
        const colour = if (self.current().valid_regex) Style.green else Style.red;
        try (Style{ .foreground = Style.grey, .background = colour }).print(writer, "search:", .{});
        try writer.print(" {s}", .{self.input_handler.cmd.items});
    } else {
        try self.drawStatusLine(writer);

        const line_len = std.math.log10(self.current().buffer.lines.items.len) + 1;
        _ = try writer.print("\x1b[{};{}H", .{
            self.current().cursor.pos.y + 1,
            self.current().cursor.pos.x + line_len + 2 + 1,
        });
    }

    if (self.input_handler.mode == .normal) {
        // Block cursor
        _ = try writer.write("\x1b[2 q");
    } else {
        // Bar cursor
        _ = try writer.write("\x1b[6 q");
    }
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
        self.size.height,
        self.size.width - len - 1,
    });

    try (Style{ .foreground = Style.green }).print(writer, "{s}{s} ", .{ path, modified });
    try (Style{ .foreground = Style.blue }).print(writer, "{s} ", .{pos_s});
    try (Style{ .foreground = Style.blue }).print(writer, "{s}", .{pc_s});
}

pub fn deinit(self: *Self) void {
    for (self.buffers.items) |*b| {
        b.buffer.unregister(self);
        b.deinit();
    }

    self.buffers.deinit(self.gpa);
}
