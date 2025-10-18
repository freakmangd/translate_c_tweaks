const std = @import("std");
const mem = std.mem;
const ascii = std.ascii;
const clap = @import("clap");

pub fn main() !void {
    var arena_state: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const params = comptime clap.parseParamsComptime(
        \\-h, --help             display this help and exit
        \\-o, --output <str>     output file
        \\-i, --input <str>      input file
        \\-p, --prefix <str>...  prefixes to strip from decls
        \\--auto-init-gen        generate init functions based on fields
        \\--camel-case           change first character of function names to lowercase
        \\
    );

    var diag: clap.Diagnostic = .{};
    var res = clap.parse(clap.Help, &params, clap.parsers.default, .{
        .diagnostic = &diag,
        .allocator = arena,
    }) catch |err| {
        try diag.reportToFile(.stderr(), err);
        return err;
    };
    defer res.deinit();

    const input_file = input_file: {
        const input_file_path = res.args.input orelse @panic("Missing argument 1: input file path");
        break :input_file try std.fs.cwd().openFile(input_file_path, .{});
    };
    defer input_file.close();

    var input_reader_buf: [4096]u8 = undefined;
    var input_reader = input_file.reader(&input_reader_buf);

    const output_file = output_file: {
        const output_file_path = res.args.output orelse @panic("Missing argument 2: output file path");
        break :output_file try std.fs.cwd().createFile(output_file_path, .{});
    };
    defer output_file.close();

    var output_file_buf: [4096]u8 = undefined;
    var output_writer = output_file.writer(&output_file_buf);

    try tweakDecls(arena, &input_reader.interface, &output_writer.interface, .{
        .strip_prefixes = res.args.prefix,
        .auto_init_gen = res.args.@"auto-init-gen" > 0,
        .camel_case_functions = res.args.@"camel-case" > 0,
    });
}

const GatherDeclsOption = enum {
    none,
    returns,
    name_contains,
    returns_and_name_contains,
    returns_or_name_contains,

    pub fn eval(option: GatherDeclsOption, decl: []const u8, type_name: []const u8) bool {
        if (option == .none) return false;

        if (!mem.containsAtLeast(u8, decl, 1, " fn "))
            std.debug.panic("Handed a line that doesnt contain a function declaration: {s}", .{decl});

        const is_return_type = return_type: {
            const end_of_args = mem.lastIndexOfScalar(u8, decl, ')').?;
            const open_brace = mem.lastIndexOfScalar(u8, decl, '{') orelse decl.len;
            break :return_type std.mem.eql(u8, decl[end_of_args + 2 .. open_brace - 1], type_name);
        };

        const name = name: {
            const func_name_start = mem.indexOf(u8, decl, " fn ").? + 4;
            const func_name_end = mem.indexOfScalar(u8, decl[func_name_start..], '(').?;
            break :name decl[func_name_start..][0..func_name_end];
        };

        const contains_name = std.mem.containsAtLeast(u8, name, 1, type_name);

        return switch (option) {
            .none => unreachable,
            .returns => is_return_type,
            .name_contains => contains_name,
            .returns_and_name_contains => is_return_type and contains_name,
            .returns_or_name_contains => is_return_type or contains_name,
        };
    }
};

test GatherDeclsOption {
    const extern_decl = "pub extern fn TypeName_doStuff(arg_1: A) TypeName;";
    const func_decl = "pub fn TypeName_doStuff(arg_1: A) TypeName {";

    try std.testing.expect(GatherDeclsOption.eval(.returns, extern_decl, "TypeName"));
    try std.testing.expect(GatherDeclsOption.eval(.returns, func_decl, "TypeName"));
    try std.testing.expect(!GatherDeclsOption.eval(.returns, func_decl, "Uh"));
}

const StructDef = struct {
    field_names: []const []const u8,
    type_names: []const []const u8,
    decls: std.Io.Writer.Allocating,

    const Map = std.StringArrayHashMapUnmanaged(StructDef);

    pub fn parse(gpa: std.mem.Allocator, struct_defs: *Map, reader: *std.Io.Reader, header: []const u8) !void {
        // pub const TypeName = extern struct {
        const name_end = mem.indexOfScalar(u8, header["pub const ".len..], ' ').?;
        const name = try gpa.dupe(u8, header["pub const ".len..][0..name_end]);

        const entry = try struct_defs.getOrPut(gpa, name);

        var field_names: std.ArrayList([]const u8) = .empty;
        var type_names: std.ArrayList([]const u8) = .empty;

        while (reader.takeDelimiterExclusive('\n')) |line| {
            if (mem.startsWith(u8, line, "};")) break;

            const line_trimmed = mem.trim(u8, line, " ");
            const field_name = mem.sliceTo(line_trimmed, ':');
            var type_name = mem.sliceTo(line_trimmed[field_name.len + 2 ..], '=');
            type_name = type_name[0 .. type_name.len - 1];

            try field_names.append(gpa, try gpa.dupe(u8, field_name));
            try type_names.append(gpa, try gpa.dupe(u8, type_name));
        } else |err| return err;

        entry.value_ptr.* = .{
            .field_names = try field_names.toOwnedSlice(gpa),
            .type_names = try type_names.toOwnedSlice(gpa),
            .decls = .init(gpa),
        };
    }
};

const FuncDef = struct {
    header: [1024]u8,
    header_len: usize,

    pub fn initHeader(fd: *FuncDef, header: []const u8) void {
        @memcpy(fd.header[0..header.len], header);
        fd.header_len = header.len;
    }

    pub fn name(fd: *const FuncDef) []const u8 {
        const left_paren = mem.indexOfScalar(u8, &fd.header, '(').?;
        const name_start = mem.lastIndexOfScalar(u8, fd.header[0..left_paren], ' ').?;
        return fd.header[name_start + 1 .. left_paren];
    }

    pub fn hasBody(fd: FuncDef) bool {
        return mem.endsWith(u8, fd.header[0..fd.header_len], "{");
    }
};

const TweakDeclsOptions = struct {
    auto_init_gen: bool = false,
    gather_decls: GatherDeclsOption = .none,
    strip_prefixes: ?[]const []const u8 = null,
    camel_case_functions: bool = false,
};

pub fn tweakDecls(gpa: std.mem.Allocator, reader: *std.Io.Reader, writer: *std.Io.Writer, options: TweakDeclsOptions) !void {
    var struct_defs: StructDef.Map = .empty;
    defer struct_defs.deinit(gpa);

    var func_def: FuncDef = undefined;

    var taken_names: std.StringArrayHashMapUnmanaged(void) = .empty;
    defer {
        for (taken_names.keys()) |k| gpa.free(k);
        taken_names.deinit(gpa);
    }

    if (options.strip_prefixes) |strip_prefixes| {
        while (reader.takeDelimiterExclusive('\n')) |line| {
            //std.debug.print("line: {s}\n", .{line});

            // i don't think empty lines are ever useful, or even present in translate-c output
            if (line.len == 0) continue;

            if (nameFromDecl(line)) |name| {
                const n = try gpa.dupe(u8, name);
                try taken_names.put(gpa, n, {});
            }

            if (std.mem.startsWith(u8, line, "pub ") and containsAny(line, strip_prefixes)) {
                const line_no_pub = line["pub ".len..];

                if (std.mem.endsWith(u8, line_no_pub, "extern struct {")) {
                    try StructDef.parse(gpa, &struct_defs, reader, line);

                    continue;
                } else if (mem.containsAtLeast(u8, line, 1, "pub fn ") or mem.containsAtLeast(u8, line, 1, "pub extern fn ")) {
                    func_def.initHeader(line_no_pub);
                    const name = func_def.name();
                    const avail = normalizedNameAvailable(name, options, .camel_case, &.{}, taken_names);

                    var sd_iter = struct_defs.iterator();
                    while (sd_iter.next()) |kv| {
                        if (options.gather_decls.eval(line, kv.key_ptr.*)) {
                            try kv.value_ptr.decls.writer.print("    pub const {f} = {s};\n", .{
                                normalizeName(name, options, .camel_case, &.{trimStartMany(kv.key_ptr.*, &.{strip_prefixes})}),
                                name,
                            });
                        }
                    }

                    if (avail) {
                        try writer.writeAll(line_no_pub);
                        try writer.writeByte('\n');
                    } else {
                        try writer.writeAll(line);
                        try writer.writeByte('\n');
                    }

                    if (func_def.hasBody()) {
                        while (true) {
                            const l = try reader.takeDelimiterExclusive('\n');
                            try writer.writeAll(l);
                            try writer.writeByte('\n');
                            if (l.len > 0 and l[0] == '}') break;
                        }
                    }

                    //std.debug.print("trimming {s}\n", .{name});
                    if (avail) {
                        try writer.print("pub const {f} = {s};\n", .{ normalizeName(name, options, .camel_case, &.{}), name });
                    }

                    continue;
                }
            }

            try writer.writeAll(line);
            try writer.writeByte('\n');
        } else |err| switch (err) {
            error.EndOfStream => {},
            else => |e| return e,
        }

        var struct_iter = struct_defs.iterator();
        while (struct_iter.next()) |kv| {
            const name = kv.key_ptr.*;
            const sd = kv.value_ptr;

            try writer.print("const {s} = extern struct {{\n", .{name});

            for (sd.field_names, sd.type_names) |n, t| {
                try writer.print("    {s}: {s} = @import(\"std\").mem.zeroes({s}),\n", .{ n, t, t });
            }

            if (options.auto_init_gen) {
                try writer.writeAll("    pub fn init(");

                for (sd.field_names, sd.type_names, 0..) |n, t, i| {
                    try writer.print("{f}: {s}{s}", .{
                        escapeArgName(n),
                        t,
                        if (i == sd.field_names.len - 1) "" else ", ",
                    });
                }

                try writer.print(
                    \\) {s} {{
                    \\        return .{{
                    \\
                , .{name});

                for (sd.field_names) |n| {
                    try writer.print("            .{s} = {f},\n", .{ n, escapeArgName(n) });
                }

                try writer.writeAll("        };\n    }\n");
            }

            try writer.writeAll(sd.decls.writer.buffered());
            try writer.writeAll("};\n");

            const trimmed_name = trimStartMany(name, &.{ &.{"struct_"}, strip_prefixes });

            try writer.print("pub const {s} = {s};\n", .{ trimmed_name, name });

            gpa.free(name);
            for (sd.field_names) |n| gpa.free(n);
            gpa.free(sd.field_names);
            for (sd.type_names) |t| gpa.free(t);
            gpa.free(sd.type_names);
            sd.decls.deinit();
        }
    }

    try writer.flush();
}

fn nameFromDecl(decl: []const u8) ?[]const u8 {
    if (mem.endsWith(u8, decl, "extern struct {")) {
        const name_start = mem.indexOf(u8, decl, "const ").? + "const ".len;
        const name_end = mem.indexOfScalarPos(u8, decl, name_start, ' ').?;
        return decl[name_start..name_end];
    } else if (mem.startsWith(u8, decl, "pub fn ")) {
        const name_end = mem.indexOfScalar(u8, decl, '(').?;
        return decl["pub fn ".len..name_end];
    } else if (mem.startsWith(u8, decl, "pub extern fn ")) {
        const name_end = mem.indexOfScalar(u8, decl, '(').?;
        return decl["pub extern fn ".len..name_end];
    }
    return null;
}

const NormalizeNameFomatter = struct {
    name: []const u8,
    rules: TweakDeclsOptions,
    extra_strip: []const []const u8,
    style: Style,

    const Style = enum {
        title_case,
        camel_case,
        // snake_case, // we only create function and type aliases, so no need for snake case
    };

    const Alt = std.fmt.Alt(NormalizeNameFomatter, normalizeNameFormat);

    fn normalizeNameFormat(nn: NormalizeNameFomatter, writer: *std.Io.Writer) !void {
        const trimmed_name = trimStartMany(nn.name, &.{ nn.rules.strip_prefixes.?, nn.extra_strip, &.{"_"} });
        //std.debug.print("{s} -> trimmed: {s}\nused:\n", .{ nn.name, trimmed_name });
        //for (nn.rules.strip_prefixes.?) |s| std.debug.print("    {s}\n", .{s});
        //for (nn.extra_strip) |s| std.debug.print("    {s}\n", .{s});

        var underscore_iter = mem.tokenizeScalar(u8, trimmed_name, '_');

        switch (nn.style) {
            .camel_case => {
                if (!nn.rules.camel_case_functions) {
                    try writer.writeAll(trimmed_name);
                    return;
                }

                const first = underscore_iter.next().?;
                try writer.writeByte(ascii.toLower(first[0]));
                try writer.writeAll(first[1..]);

                while (underscore_iter.next()) |part| {
                    try writer.writeByte(ascii.toUpper(part[0]));
                    try writer.writeAll(part[1..]);
                }
            },
            .title_case => {
                const first = underscore_iter.next().?;
                try writer.writeByte(ascii.toUpper(first[0]));
                try writer.writeAll(first[1..]);

                while (underscore_iter.next()) |part| {
                    try writer.writeByte(ascii.toUpper(part[0]));
                    try writer.writeAll(part[1..]);
                }
            },
        }
    }
};

fn normalizeName(
    name: []const u8,
    rules: TweakDeclsOptions,
    style: NormalizeNameFomatter.Style,
    extra_strip: []const []const u8,
) NormalizeNameFomatter.Alt {
    return .{ .data = .{
        .name = name,
        .rules = rules,
        .style = style,
        .extra_strip = extra_strip,
    } };
}

fn normalizedNameAvailable(
    name: []const u8,
    rules: TweakDeclsOptions,
    style: NormalizeNameFomatter.Style,
    extra_strip: []const []const u8,
    taken_names: std.StringArrayHashMapUnmanaged(void),
) bool {
    var nm_name_buf: [256]u8 = undefined;
    var nm_name: std.Io.Writer = .fixed(&nm_name_buf);

    NormalizeNameFomatter.normalizeNameFormat(.{
        .name = name,
        .rules = rules,
        .style = style,
        .extra_strip = extra_strip,
    }, &nm_name) catch return false; // >256 means we out of luck

    return !taken_names.contains(nm_name.buffered());
}

fn escapeArgNameFormat(arg: []const u8, writer: *std.Io.Writer) error{WriteFailed}!void {
    if (mem.eql(u8, arg, "type")) {
        try writer.writeAll("@\"type\"");
    } else {
        try writer.writeAll(arg);
    }
}

fn escapeArgName(arg: []const u8) std.fmt.Alt([]const u8, escapeArgNameFormat) {
    return .{ .data = arg };
}

fn containsPrefixed(str: []const u8, prefix: []const u8, contains: []const u8) bool {
    const idx = std.mem.indexOf(u8, str, prefix) orelse return false;
    return std.mem.startsWith(u8, str[idx..], contains);
}

fn trimStartMany(str: []const u8, prefixes_list: []const []const []const u8) []const u8 {
    var trimmed = str;
    for (prefixes_list) |prefixes| {
        for (prefixes) |p| {
            if (std.mem.startsWith(u8, trimmed, p))
                trimmed = trimmed[p.len..];
        }
    }
    return trimmed;
}

fn containsAny(str: []const u8, needles: []const []const u8) bool {
    return for (needles) |n| {
        if (std.mem.containsAtLeast(u8, str, 1, n)) break true;
    } else false;
}

test tweakDecls {
    const input =
        \\pub extern fn atan2(__y: f64, __x: f64) f64;
        \\pub extern fn atan3(__y: f64, __x: f64) f64;
        \\pub extern fn SDL_Atan2() f64;
        \\pub const SDL_Foo = extern struct {
        \\    type: c_int = @import("std").mem.zeroes(c_int),
        \\};
        \\pub extern fn SDL_Foo_Add_T(a: SDL_Foo, b: SDL_Foo) SDL_Foo;
        \\pub extern fn SDL_FooS_Inv(a: SDL_Foo) SDL_Foo;
        \\pub const struct_SDL_Data = extern struct {
        \\    a: c_int = @import("std").mem.zeroes(c_int),
        \\    b: f32 = @import("std").mem.zeroes(f32),
        \\};
        \\pub const SDL_Data = struct_SDL_Data;
        \\pub extern fn SDL_DoStuff(SDL_Thing) void;
        \\pub fn SDL_Rot_GetAngle(arg_q: b2Rot) callconv(.c) f32 {
        \\    var q = arg_q;
        \\    _ = &q;
        \\    return b2Atan2(q.s, q.c);
        \\}
    ;
    var input_fbs: std.Io.Reader = .fixed(input);

    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();

    try tweakDecls(std.testing.allocator, &input_fbs, &output.writer, .{
        .strip_prefixes = &.{"SDL_"},
        .auto_init_gen = true,
        .camel_case_functions = true,
        .gather_decls = .returns_or_name_contains,
    });

    try std.testing.expectEqualStrings(
        \\pub extern fn atan2(__y: f64, __x: f64) f64;
        \\pub extern fn atan3(__y: f64, __x: f64) f64;
        \\pub extern fn SDL_Atan2() f64;
        \\extern fn SDL_Foo_Add_T(a: SDL_Foo, b: SDL_Foo) SDL_Foo;
        \\pub const fooAddT = SDL_Foo_Add_T;
        \\extern fn SDL_FooS_Inv(a: SDL_Foo) SDL_Foo;
        \\pub const fooSInv = SDL_FooS_Inv;
        \\pub const SDL_Data = struct_SDL_Data;
        \\extern fn SDL_DoStuff(SDL_Thing) void;
        \\pub const doStuff = SDL_DoStuff;
        \\fn SDL_Rot_GetAngle(arg_q: b2Rot) callconv(.c) f32 {
        \\    var q = arg_q;
        \\    _ = &q;
        \\    return b2Atan2(q.s, q.c);
        \\}
        \\pub const rotGetAngle = SDL_Rot_GetAngle;
        \\const SDL_Foo = extern struct {
        \\    type: c_int = @import("std").mem.zeroes(c_int),
        \\    pub fn init(@"type": c_int) SDL_Foo {
        \\        return .{
        \\            .type = @"type",
        \\        };
        \\    }
        \\    pub const addT = SDL_Foo_Add_T;
        \\    pub const sInv = SDL_FooS_Inv;
        \\};
        \\pub const Foo = SDL_Foo;
        \\const struct_SDL_Data = extern struct {
        \\    a: c_int = @import("std").mem.zeroes(c_int),
        \\    b: f32 = @import("std").mem.zeroes(f32),
        \\    pub fn init(a: c_int, b: f32) struct_SDL_Data {
        \\        return .{
        \\            .a = a,
        \\            .b = b,
        \\        };
        \\    }
        \\};
        \\pub const Data = struct_SDL_Data;
        \\
    , output.written());
}
