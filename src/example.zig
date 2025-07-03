const std = @import("std");
const sdl = @import("sdl");

pub fn main() !void {
    std.debug.print("output: {}\n", .{sdl.doStuff()});
}
