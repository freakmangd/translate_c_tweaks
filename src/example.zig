const std = @import("std");
const sdl = @import("sdl");

pub fn main() !void {
    std.debug.print("output: {}\n", .{sdl.doStuff()});

    const data: sdl.Data = .init(10, 20);
    std.debug.print("init {}\n", .{data});
}
