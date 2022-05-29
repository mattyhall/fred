const std = @import("std");
const c = @cImport({
    @cInclude("termios.h");
    @cInclude("stdlib.h");
    @cInclude("sys/ioctl.h");
    @cInclude("signal.h");
});

pub const Size = struct { width: u32, height: u32 };

const MAX_EVENTS_PER_FRAME = 32;

const Self = @This();

const stdin = std.io.getStdIn().reader();

var instance: ?Self = null;

size: Size,
original_terminal_settings: c.struct_termios = undefined,
events: [MAX_EVENTS_PER_FRAME]u8 = undefined,
fd: std.os.fd_t = undefined,

fn cleanupTerminal() callconv(.C) void {
    _ = std.io.getStdOut().writer().write("\x1b[0;0H\x1b[2J") catch {
        @panic("could not reset display");
    };

    _ = c.tcsetattr(std.os.STDIN_FILENO, c.TCSANOW, &instance.?.original_terminal_settings);
}

fn handleResize(_: c_int) callconv(.C) void {
    var sz: c.winsize = undefined;
    if (c.ioctl(std.os.STDIN_FILENO, c.TIOCGWINSZ, &sz) != 0)
        std.os.exit(1);

    instance.?.size.width = sz.ws_col;
    instance.?.size.height = sz.ws_row;

    // An eventfd takes a 64bit integer.
    // FIXME(mjh): don't assume endianess
    _ = std.os.write(instance.?.fd, &[_]u8{ 0, 0, 0, 0, 0, 0, 0, 1 }) catch unreachable;
}

pub fn init() error{ TermiosFailure, WinSzFailure, EventFdFailure }!*Self {
    std.debug.assert(instance == null);
    instance = Self{ .fd = undefined, .size = .{ .width = 0, .height = 0 } };

    // FIXME(mjh): find a mac alternative
    instance.?.fd = std.os.eventfd(0, 0) catch return error.EventFdFailure;

    if (c.tcgetattr(std.os.STDIN_FILENO, &instance.?.original_terminal_settings) < 0)
        return error.TermiosFailure;

    var raw = instance.?.original_terminal_settings;
    raw.c_iflag &= ~@intCast(c_uint, c.BRKINT | c.ICRNL | c.INPCK | c.ISTRIP | c.IXON);
    raw.c_lflag &= ~@intCast(c_uint, c.ECHO | c.ICANON | c.IEXTEN | c.ISIG);
    raw.c_cc[c.VMIN] = 1;

    if (c.tcsetattr(std.os.STDIN_FILENO, c.TCSANOW, &raw) < 0)
        return error.TermiosFailure;

    _ = c.atexit(cleanupTerminal);

    _ = c.signal(c.SIGWINCH, handleResize);
    handleResize(c.SIGWINCH);

    return &(instance.?);
}

pub fn getInput(self: *Self) []const u8 {
    const read = stdin.read(&self.events) catch unreachable;
    return self.events[0..read];
}
