const std = @import("std");
const Server = @import("Server.zig");
const Client = @import("Client.zig");
const Terminal = @import("Terminal.zig");

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

pub fn panic(m: []const u8, error_return_trace: ?*std.builtin.StackTrace) noreturn {
    Terminal.cleanupTerminal();
    const first_trace_addr = @returnAddress();
    std.log.err("panic: {s}", .{m});
    std.debug.panicImpl(error_return_trace, first_trace_addr, m);
}

fn setupLogging(server: bool) !void {
    const name = if (server) "fred_server.log" else "fred.log";
    log_file = try std.fs.cwd().createFile(name, .{});
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
    var stdout = std.io.bufferedWriter(std.io.getStdOut().writer());
    var writer = stdout.writer();

    var gpa = std.heap.GeneralPurposeAllocator(.{}){ .backing_allocator = std.heap.c_allocator };
    defer _ = gpa.deinit();

    if (std.os.argv.len == 3) {
        if (!std.mem.eql(u8, "-s", std.mem.span(std.os.argv[1]))) {
            _ = try writer.write("only recognised argument is -s");
            try stdout.flush();
            std.os.exit(1);
        }

        try setupLogging(false);

        var client = Client.init(gpa.allocator());
        defer client.deinit();

        client.run(std.mem.span(std.os.argv[1]), std.mem.span(std.os.argv[2])) catch |err| {
            std.log.err("got error: {}", .{err});
            return err;
        };

        return;
    }

    if (std.os.argv.len != 2) {
        _ = try writer.write("please pass an argument");
        try stdout.flush();
        std.os.exit(1);
    }

    const id = newIdentifier();
    if ((try std.os.fork()) == 0) {
        try setupLogging(true);

        var server = Server.init(gpa.allocator());
        defer server.deinit();

        server.listen(&id) catch |err| {
            std.log.err("got error: {}", .{err});
            return err;
        };

        return;
    }

    try setupLogging(false);

    var client = Client.init(gpa.allocator());
    defer client.deinit();

    client.run(&id, std.mem.span(std.os.argv[1])) catch |err| {
        std.log.err("got error: {}", .{err});
        return err;
    };
}

test "catch all" {
    std.testing.refAllDecls(@This());
}
