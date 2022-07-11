const std = @import("std");
const ds = @import("ds.zig");

gpa: std.mem.Allocator,
data: std.ArrayListUnmanaged(u8),
lines: std.ArrayListUnmanaged(u32),
path: ?[]const u8 = null,
dirty: bool = false,

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

pub fn save(self: *Self) !void {
    const p = self.path orelse return error.no_path;
    var f = try openFile(p);
    defer f.close();
    try f.writeAll(self.data.items);
    self.dirty = false;
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

pub fn lineSpan(self: *const Self, line: u32) ds.Span {
    const line_start = self.lines.items[line];
    const line_end = if (line < self.lines.items.len - 1)
        self.lines.items[line + 1] - 1 // -1 to omit the newline
    else
        @intCast(u32, self.data.items.len);

    return .{ .start = line_start, .end = line_end };
}

fn change(self: *Self) !void {
    self.dirty = true;
    try self.calculateLines();
}

pub fn orderedRemove(self: *Self, index: usize) !void {
    _ = self.data.orderedRemove(index);
    try self.change();
}

pub fn insert(self: *Self, index: usize, ch: u8) !void {
    try self.data.insert(self.gpa, index, ch);
    try self.change();
}

pub fn insertSlice(self: *Self, index: usize, s: []const u8) !void {
    try self.data.insertSlice(self.gpa, index, s);
    try self.change();
}

pub fn deinit(self: *Self) void {
    self.data.deinit(self.gpa);
    self.lines.deinit(self.gpa);
}

test "buffer line iterator" {
    var gpa = std.testing.allocator;
    const lit = "hello\nworld\nhow\nare\nyou\ntoday\n";
    var data = try gpa.alloc(u8, lit.len);
    std.mem.copy(u8, data, lit);

    var buf = Self.fromSlice(gpa, data);
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
