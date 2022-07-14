const std = @import("std");
const Fred = @import("Fred.zig");
const Terminal = @import("Terminal.zig");
const Buffer = @import("Buffer.zig");
const input = @import("input.zig");
const State = @import("State.zig");

const IDENTIFIER_LEN = 16;

pub fn newIdentifier() [IDENTIFIER_LEN]u8 {
    var id: [IDENTIFIER_LEN]u8 = undefined;
    const chars = "abcdefghijklmnopqrstuvwxyz1234567890";
    var rng = std.rand.DefaultPrng.init(@bitCast(u64, std.time.milliTimestamp()));
    {
        var i: usize = 0;
        while (i < IDENTIFIER_LEN) : (i += 1) {
            const r = rng.random().uintLessThan(usize, chars.len);
            id[i] = chars[r];
        }
    }

    return id;
}

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

pub const Op = enum(u8) { hello, print };

fn handleConn(allocator: std.mem.Allocator, fred: *Fred, conn: std.net.StreamServer.Connection) !void {
    var buf: [1024 * 16]u8 = undefined;
    var read = try conn.stream.read(&buf);
    var pkt = buf[0..read];

    var fbs = std.io.fixedBufferStream(pkt);
    var reader = fbs.reader();

    const op = try reader.readIntBig(u8);
    if (op != @enumToInt(Op.hello)) {
        conn.stream.close();
        return error.invalid_op;
    }

    _ = try reader.readIntBig(u8); // width
    _ = try reader.readIntBig(u8); // height

    const path_len = try reader.readIntBig(u16);
    var path = try allocator.alloc(u8, path_len);
    defer allocator.free(path);

    read = try reader.read(path);
    if (read != path.len) {
        conn.stream.close();
        return error.path_too_short;
    }

    const terminal_size = Terminal.Size{ .width = 80, .height = 80 };

    try fred.addBuffer(State.init(allocator, &terminal_size, &fred.input_handler, try Buffer.fromFile(allocator, path)));

    var al = std.ArrayList(u8).init(allocator);
    try fred.draw(al.writer());

    var bw = std.io.bufferedWriter(conn.stream.writer());
    var writer = bw.writer();
    try writer.writeIntBig(u8, @enumToInt(Op.print));
    try writer.writeIntBig(u32, @intCast(u32, al.items.len));
    try writer.writeAll(al.items);
    try bw.flush();

    while (true) {
        read = try conn.stream.read(&buf);
    }
}

fn runServer(session: []const u8) !void {
    var server = std.net.StreamServer.init(.{});
    defer server.deinit();

    var gpa = std.heap.GeneralPurposeAllocator(.{}){ .backing_allocator = std.heap.c_allocator };
    var allocator = gpa.allocator();

    std.os.mkdir("/tmp/fred/", 0o777) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    var path = try std.fs.path.join(allocator, &.{ "/tmp/fred/", session });
    defer allocator.free(path);

    std.os.unlink(path) catch {};

    try server.listen(try std.net.Address.initUnix(path));

    var size = Terminal.Size{ .width = 80, .height = 80 };
    var fred = Fred.init(allocator, &size);
    defer fred.deinit();

    while (true) {
        var conn = try server.accept();
        try handleConn(allocator, &fred, conn);
    }
}

fn runClient(session: []const u8) !void {
    const path = std.mem.span(std.os.argv[1]);

    var gpa = std.heap.GeneralPurposeAllocator(.{}){ .backing_allocator = std.heap.c_allocator };
    var allocator = gpa.allocator();

    var uds_path = try std.fs.path.join(allocator, &.{"/tmp/fred", session});
    defer allocator.free(uds_path);

    var stream: std.net.Stream = undefined;
    while (true) {
        stream = std.net.connectUnixSocket(uds_path) catch {
            std.time.sleep(std.time.ns_per_ms * 10);
            continue;
        };
        break;
    }

    {
        var al = std.ArrayList(u8).init(allocator);
        defer al.deinit();

        var writer = al.writer();
        try writer.writeIntBig(u8, @enumToInt(Op.hello));
        try writer.writeIntBig(u8, 80); // width
        try writer.writeIntBig(u8, 80); // height
        try writer.writeIntBig(u16, @intCast(u16, path.len));
        try writer.writeAll(path);

        try stream.writer().writeAll(al.items);
    }

    var stdout = std.io.bufferedWriter(std.io.getStdOut().writer());
    var stdout_writer = stdout.writer();

    var terminal = try Terminal.init();

    {
        var buf: [16 * 1024]u8 = undefined;
        var read = try stream.read(&buf);
        var pkt = buf[0..read];
        var fbs = std.io.fixedBufferStream(pkt);
        var reader = fbs.reader();
        if ((try reader.readIntBig(u8)) != @enumToInt(Op.print)) {
            stream.close();
            return error.expected_print;
        }

        const size = try reader.readIntBig(u32);
        const pos = try fbs.getPos();
        var res = pkt[pos .. pos + size];
        try stdout_writer.writeAll(res);
        try stdout.flush();
    }

    while (true) {
        const inp = terminal.getInput();
        if (inp[0] == 'q') {
            return;
        }
    }

    //    var terminal = try Terminal.init();
    //    var gpa = std.heap.GeneralPurposeAllocator(.{}){ .backing_allocator = std.heap.c_allocator };
    //    var allocator = gpa.allocator();
    //    defer _ = gpa.deinit();
    //
    //    var fred = Fred.init(allocator, terminal);
    //    defer fred.deinit();
    //
    //    try fred.addBuffer(State.init(allocator, &terminal.size, &fred.input_handler, try Buffer.fromFile(allocator, path)));
    //
    //    while (true) {
    //        var poll_fds = [_]std.os.pollfd{
    //            .{ .fd = std.os.STDIN_FILENO, .events = std.os.POLL.IN, .revents = undefined },
    //            .{ .fd = terminal.fd, .events = std.os.POLL.IN, .revents = undefined },
    //        };
    //        const events = try std.os.poll(&poll_fds, std.math.maxInt(i32));
    //        std.debug.assert(events != 0);
    //        if (events == 0) continue;
    //
    //        if (poll_fds[0].revents & std.os.POLL.IN != 0) {
    //            const inp = terminal.getInput();
    //            for (inp) |ch| {
    //                try fred.handleInput(ch);
    //            }
    //
    //            try fred.draw(writer);
    //            try stdout.flush();
    //        }
    //
    //        var proc_buf: [16 * 1024]u8 = undefined;
    //        if (poll_fds[1].revents & (std.os.POLL.IN) != 0) {
    //            _ = try std.os.read(terminal.fd, &proc_buf);
    //
    //            try fred.draw(writer);
    //            try stdout.flush();
    //        }
    //    }
}

pub fn main() anyerror!void {
    try setupLogging();

    var stdout = std.io.bufferedWriter(std.io.getStdOut().writer());
    var writer = stdout.writer();

    if (std.os.argv.len == 3) {
        if (!std.mem.eql(u8, "-s", std.mem.span(std.os.argv[1]))) {
            _ = try writer.write("only recognised argument is -s");
            try stdout.flush();
            std.os.exit(1);
        }

        try runClient(std.mem.span(std.os.argv[2]));
        return;
    }

    if (std.os.argv.len != 2) {
        _ = try writer.write("please pass an argument");
        try stdout.flush();
        std.os.exit(1);
    }

    const id = newIdentifier();
    if ((try std.os.fork()) == 0) {
        try runServer(&id);
        return;
    }

    try runClient(&id);
}

test "catch all" {
    std.testing.refAllDecls(@This());
}
