const std = @import("std");

pub fn main() !void {
    var arena_state: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var args = try std.process.argsWithAllocator(arena);
    defer args.deinit();

    _ = args.next();

    const input_file = input_file: {
        const input_file_path = args.next() orelse @panic("Missing argument 1: input file path");
        break :input_file try std.fs.cwd().openFile(input_file_path, .{});
    };
    defer input_file.close();
    var input_buffered_reader = std.io.bufferedReader(input_file.reader());

    const output_file = output_file: {
        const output_file_path = args.next() orelse @panic("Missing argument 2: output file path");
        break :output_file try std.fs.cwd().createFile(output_file_path, .{});
    };
    defer output_file.close();
    var output_buffered_writer = std.io.bufferedWriter(output_file.writer());

    const prefix_strip_str = args.next() orelse @panic("Missing argument 3: prefix string to strip");

    try tweakDecls(arena, prefix_strip_str, input_buffered_reader.reader(), output_buffered_writer.writer());
}

fn tweakDecls(gpa: std.mem.Allocator, prefix_strip: []const u8, reader: anytype, writer: anytype) !void {
    var line: std.ArrayListUnmanaged(u8) = .empty;
    defer line.deinit(gpa);

    var current_name_buf: [128]u8 = undefined;
    var current_name: []const u8 = current_name_buf[0..0];
    var translating_structure: enum { none, extern_struct } = .none;
    var hit_end = false;

    while (!hit_end) {
        reader.streamUntilDelimiter(line.writer(gpa), '\n', null) catch |err| switch (err) {
            error.EndOfStream => hit_end = true,
            else => |e| return e,
        };
        defer line.clearRetainingCapacity();

        switch (translating_structure) {
            .none => {},
            .extern_struct => if (line.items.len > 0 and line.items[0] == '}') {
                try writer.print("}};\npub const {s} = {s};\n", .{ current_name[prefix_strip.len..], current_name });
                translating_structure = .none;
                continue;
            },
        }

        if (std.mem.startsWith(u8, line.items, "pub ") and std.mem.containsAtLeast(u8, line.items, 1, prefix_strip)) {
            if (std.mem.endsWith(u8, line.items, "extern struct {")) {
                const space_idx = std.mem.indexOfScalar(u8, line.items["pub const ".len..], ' ') orelse continue;
                translating_structure = .extern_struct;

                const struct_name = line.items["pub const ".len..][0..space_idx];
                @memcpy(current_name_buf[0..struct_name.len], struct_name);
                current_name = current_name_buf[0..struct_name.len];

                try writer.writeAll(line.items["pub ".len..]);
                try writer.writeByte('\n');

                continue;
            } else if (std.mem.eql(u8, line.items["pub ".len..][0.."extern".len], "extern")) {
                const left_paren_idx = std.mem.indexOfScalar(u8, line.items["pub extern fn ".len..], '(') orelse continue;

                const function_name = line.items["pub extern fn ".len..][0..left_paren_idx];

                try writer.print("{s}\npub const {s} = {s};\n", .{ line.items["pub ".len..], function_name[prefix_strip.len..], function_name });

                continue;
            } else {
                translating_structure = .none;
            }
        }

        try writer.writeAll(line.items);
        try writer.writeByte('\n');
    }
}

test tweakDecls {
    const input =
        \\pub const SDL_Thing = extern struct {
        \\    a: f32 = @import("std").mem.zeroes(f32),
        \\    b: c_int = @import("std").mem.zeroes(c_int),
        \\};
        \\pub extern fn SDL_doStuff(SDL_Thing) void;
    ;
    var input_fbs = std.io.fixedBufferStream(input);

    var output: std.ArrayListUnmanaged(u8) = .empty;
    defer output.deinit(std.testing.allocator);

    try tweakDecls(std.testing.allocator, "SDL_", input_fbs.reader(), output.writer(std.testing.allocator));

    try std.testing.expectEqualStrings(
        \\const SDL_Thing = extern struct {
        \\    a: f32 = @import("std").mem.zeroes(f32),
        \\    b: c_int = @import("std").mem.zeroes(c_int),
        \\};
        \\pub const Thing = SDL_Thing;
        \\extern fn SDL_doStuff(SDL_Thing) void;
        \\pub const doStuff = SDL_doStuff;
        \\
    , output.items);
}
