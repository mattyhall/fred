const std = @import("std");
const Terminal = @import("Terminal.zig");
const Buffer = @import("Buffer.zig");
const input = @import("input.zig");
const State = @import("State.zig");

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
            const inp = terminal.getInput();
            for (inp) |ch| {
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

test "catch all" {
    std.testing.refAllDecls(@This());
}
