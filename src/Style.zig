foreground: Colour = .{ .r = 255, .g = 255, .b = 255 },
background: Colour = .{ .r = 0, .g = 0, .b = 0 },
bold: u1 = 0,
faint: u1 = 0,
italic: u1 = 0,

const Self = @This();

pub const grey = Colour{ .r = 68, .g = 71, .b = 90 };

pub const Colour = struct {
    r: u8,
    g: u8,
    b: u8,

    pub fn eql(a: Colour, b: Colour) bool {
        return a.r == b.r and a.g == b.g and a.b == b.b;
    }
};

fn colour(writer: anytype, c: Colour) !void {
    try writer.print("2;{};{};{}m", .{ c.r, c.g, c.b });
}

pub fn print(self: Self, writer: anytype, comptime format: []const u8, args: anytype) !void {
    if (!self.foreground.eql(Colour{ .r = 255, .g = 255, .b = 255 })) {
        _ = try writer.write("\x1b[38;");
        try colour(writer, self.foreground);
    }
    if (!self.background.eql(Colour{ .r = 0, .g = 0, .b = 0 })) {
        _ = try writer.write("\x1b[38;");
        try colour(writer, self.background);
    }

    if (self.bold == 1)
        _ = try writer.write("\x1b[1m");
    if (self.faint == 1)
        _ = try writer.write("\x1b[2m");
    if (self.italic == 1)
        _ = try writer.write("\x1b[3m");

    try writer.print(format, args);

    _ = try writer.write("\x1b[0m");
}
