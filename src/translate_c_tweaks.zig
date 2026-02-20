const std = @import("std");
const mem = std.mem;
const ascii = std.ascii;
const clap = @import("clap");

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();

    const params = comptime clap.parseParamsComptime(
        \\-h, --help             display this help and exit
        \\-o, --output <str>     output file
        \\-i, --input <str>      input file
        \\-p, --prefix <str>...  prefixes to strip from decls
        \\--auto-init-gen        generate init functions based on fields
        \\--camel-case           change first character of function names to lowercase
        \\--alias <str>...       add an alias for type T, format "Original,Alias"
        \\--extras               open stdin for extra redefinitions
        \\
    );

    var diag: clap.Diagnostic = .{};
    var res = clap.parse(clap.Help, &params, clap.parsers.default, init.minimal.args, .{
        .diagnostic = &diag,
        .allocator = arena,
    }) catch |err| {
        try diag.reportToFile(init.io, .stderr(), err);
        return err;
    };
    defer res.deinit();

    const input_file = input_file: {
        const input_file_path = res.args.input orelse @panic("Missing argument 1: input file path");
        break :input_file try std.Io.Dir.cwd().openFile(init.io, input_file_path, .{});
    };
    defer input_file.close(init.io);

    var input_reader_buf: [4096]u8 = undefined;
    var input_reader = input_file.reader(init.io, &input_reader_buf);

    const output_file = output_file: {
        const output_file_path = res.args.output orelse @panic("Missing argument 2: output file path");
        break :output_file try std.Io.Dir.cwd().createFile(init.io, output_file_path, .{});
    };
    defer output_file.close(init.io);

    var output_file_buf: [4096]u8 = undefined;
    var output_writer = output_file.writer(init.io, &output_file_buf);

    //std.debug.print("about to read extra!\n", .{});

    const type_aliases: [][2][]const u8 = try arena.alloc([2][]const u8, res.args.alias.len);
    for (type_aliases, res.args.alias) |*ta, alias| {
        var split = std.mem.splitScalar(u8, alias, ',');
        ta[0] = split.next().?;
        ta[1] = split.next().?;
    }

    var type_extra_decls: std.ArrayList([2][]const u8) = .empty;
    defer type_extra_decls.deinit(arena);

    var type_redefs: std.ArrayList([2][]const u8) = .empty;
    defer type_redefs.deinit(arena);

    if (res.args.extras > 0) {
        var stdin_buf: [2048]u8 = undefined;
        var stdin = std.Io.File.stdin().reader(init.io, &stdin_buf);

        type_extra_decls = try readExtra(arena, &stdin.interface);
        type_redefs = try readExtra(arena, &stdin.interface);
    }

    //std.debug.print("about to tweak!\n", .{});

    try tweakDecls(arena, &input_reader.interface, &output_writer.interface, .{
        .strip_prefixes = res.args.prefix,
        .auto_init_gen = res.args.@"auto-init-gen" > 0,
        .camel_case_functions = res.args.@"camel-case" > 0,
        .gather_decls = .returns_or_name_contains,
        .type_aliases = type_aliases,
        .type_extra_decls = type_extra_decls.items,
        .redefine_types = type_redefs.items,
    });
}

fn readExtra(gpa: std.mem.Allocator, stdin: *std.Io.Reader) !std.ArrayList([2][]const u8) {
    var current_type: ?struct {
        name: []const u8,
        lines: usize,
    } = null;
    var lines_counted: usize = 0;

    var assoc_list: std.ArrayList([2][]const u8) = .empty;
    errdefer assoc_list.deinit(gpa);

    var decls_content: std.Io.Writer.Allocating = .init(gpa);
    defer decls_content.deinit();

    while (try stdin.takeDelimiter('\n')) |line| {
        if (mem.eql(u8, line, "---")) break;

        const current = current_type orelse {
            var space_iter = mem.splitScalar(u8, line, ' ');

            const name = space_iter.next().?;
            const lines = space_iter.next().?;

            current_type = .{
                .name = try gpa.dupe(u8, name),
                .lines = std.fmt.parseInt(usize, lines, 10) catch @panic(""),
            };
            continue;
        };

        try decls_content.writer.writeAll(line);
        try decls_content.writer.writeByte('\n');

        lines_counted += 1;
        if (lines_counted >= current.lines) {
            try assoc_list.append(gpa, .{
                current.name,
                try decls_content.toOwnedSlice(),
            });

            lines_counted = 0;
            decls_content.clearRetainingCapacity();
            current_type = null;
        }
    }

    return assoc_list;
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
    was_filled: bool = false,

    const Map = std.StringArrayHashMapUnmanaged(StructDef);

    pub fn parse(gpa: std.mem.Allocator, struct_defs: *Map, reader: *std.Io.Reader, header: []const u8) ![]const u8 {
        // pub const TypeName = extern struct {
        const name_end = mem.indexOfScalar(u8, header["pub const ".len..], ' ').?;
        const name = try gpa.dupe(u8, header["pub const ".len..][0..name_end]);

        const entry = try struct_defs.getOrPut(gpa, name);

        if (entry.found_existing) {
            gpa.free(name);
        }

        var field_names: std.ArrayList([]const u8) = .empty;
        var type_names: std.ArrayList([]const u8) = .empty;

        while (try reader.takeDelimiter('\n')) |line| {
            if (mem.startsWith(u8, mem.trimStart(u8, line, " "), "pub const ")) continue;
            if (mem.startsWith(u8, line, "};")) break;

            //std.debug.print("LINE: {s}\n", .{line});

            const line_trimmed = mem.trim(u8, line, " ");
            const field_name = mem.sliceTo(line_trimmed, ':');
            var type_name = mem.sliceTo(line_trimmed[field_name.len + 2 ..], '=');
            type_name = type_name[0 .. type_name.len - 1];

            try field_names.append(gpa, try gpa.dupe(u8, field_name));
            try type_names.append(gpa, try gpa.dupe(u8, type_name));
        }

        entry.value_ptr.* = .{
            .field_names = try field_names.toOwnedSlice(gpa),
            .type_names = try type_names.toOwnedSlice(gpa),
            .decls = if (entry.found_existing) entry.value_ptr.decls else .init(gpa),
            .was_filled = true,
        };

        return entry.key_ptr.*;
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
    strip_prefixes: []const []const u8 = &.{},
    auto_init_gen: bool = false,
    camel_case_functions: bool = false,
    gather_decls: GatherDeclsOption = .none,
    type_aliases: []const [2][]const u8 = &.{},
    type_extra_decls: []const [2][]const u8 = &.{},
    redefine_types: []const [2][]const u8 = &.{},
};

pub fn tweakDecls(gpa: std.mem.Allocator, reader: *std.Io.Reader, writer: *std.Io.Writer, options: TweakDeclsOptions) !void {
    var struct_defs: StructDef.Map = .empty;
    defer struct_defs.deinit(gpa);

    for (options.type_aliases) |ta| {
        try struct_defs.put(gpa, try gpa.dupe(u8, ta[0]), .{
            .decls = .init(gpa),
            .field_names = &.{},
            .type_names = &.{},
        });
    }

    var func_def: FuncDef = undefined;

    var namespaced_decls: std.Io.Writer.Allocating = .init(gpa);
    defer namespaced_decls.deinit();

    var taken_names: std.StringArrayHashMapUnmanaged(void) = .empty;
    defer {
        for (taken_names.keys()) |k| gpa.free(k);
        taken_names.deinit(gpa);
    }

    // access outer scope
    try writer.writeAll("const @\"-\" = @This();\n");

    line_loop: while (try reader.takeDelimiter('\n')) |line| {
        //std.debug.print("line: {s}\n", .{line});

        name_check: {
            const name = nameFromDecl(line) orelse break :name_check;
            if (normalizedNameAvailable(name, options, .camel_case, &.{}, taken_names)) {
                const n = try gpa.dupe(u8, name);
                try taken_names.put(gpa, n, {});
            }
        }

        if (std.mem.startsWith(u8, line, "pub ")) {
            const line_no_pub = line["pub ".len..];

            if (std.mem.endsWith(u8, line_no_pub, "extern struct {")) {
                const name = try StructDef.parse(gpa, &struct_defs, reader, line);
                const trimmed_name = trimStartMany(name, &.{ &.{"struct_"}, options.strip_prefixes });
                const avail = normalizedNameAvailable(name, options, .camel_case, &.{}, taken_names);

                if (avail) {
                    try namespaced_decls.writer.print("    pub const {s} = {s};\n", .{ trimmed_name, name });
                } else {
                    try namespaced_decls.writer.print("    pub const {s} = @\"-\".{s};\n", .{ name, name });
                }

                continue;
            } else if (mem.containsAtLeast(u8, line, 1, "pub fn ") or mem.containsAtLeast(u8, line, 1, "pub extern fn ")) {
                func_def.initHeader(line_no_pub);
                const name = func_def.name();
                const avail = normalizedNameAvailable(name, options, .camel_case, &.{}, taken_names);

                try checkDeclForStructDefs(options, struct_defs, line);
                //var sd_iter = struct_defs.iterator();
                //while (sd_iter.next()) |kv| {
                //    if (options.gather_decls.eval(line, kv.key_ptr.*)) {
                //        try kv.value_ptr.decls.writer.print("    pub const {f} = {s};\n", .{
                //            normalizeName(name, options, .camel_case, &.{trimStartMany(kv.key_ptr.*, &.{options.strip_prefixes})}),
                //            name,
                //        });
                //    }
                //}

                try writer.writeAll(line);
                try writer.writeByte('\n');

                if (func_def.hasBody()) {
                    while (true) {
                        const l = (try reader.takeDelimiter('\n')) orelse return error.EndOfStream;
                        try writer.writeAll(l);
                        try writer.writeByte('\n');
                        if (l.len > 0 and l[0] == '}') break;
                    }
                }

                //std.debug.print("trimming {s}\n", .{name});
                if (avail) {
                    try namespaced_decls.writer.print("    pub const {f} = {s};\n", .{ normalizeName(name, options, .camel_case, &.{}), name });
                } else {
                    try namespaced_decls.writer.print("    pub const {s} = @\"-\".{s};\n", .{ name, name });
                }

                continue;
            }
        }

        if (mem.startsWith(u8, line, "pub const ")) redef: {
            const name = nameFromDecl(line) orelse break :redef;
            for (options.redefine_types) |redef| {
                if (mem.eql(u8, name, redef[0])) {
                    try writer.writeAll(redef[1]);
                    try writer.writeByte('\n');
                    continue :line_loop;
                }
            }
        }

        try writer.writeAll(line);
        try writer.writeByte('\n');
    }

    var struct_iter = struct_defs.iterator();
    while (struct_iter.next()) |kv| {
        if (!kv.value_ptr.was_filled) {
            std.debug.panic("Type alias {s} was never found :(", .{kv.key_ptr.*});
        }

        const name = kv.key_ptr.*;
        const sd = kv.value_ptr;

        try writer.print("pub const {s} = extern struct {{\n", .{name});

        for (sd.field_names, sd.type_names) |n, t| {
            try writer.print("    {s}: {s} = @import(\"std\").mem.zeroes({s}),\n", .{ n, t, t });
        }

        if (options.auto_init_gen) {
            try writer.writeAll("    pub fn init(");

            for (sd.field_names, sd.type_names, 0..) |n, t, i| {
                try writer.print("arg_{s}: {s}{s}", .{
                    n,
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
                try writer.print("            .{s} = arg_{s},\n", .{ n, n });
            }

            try writer.writeAll("        };\n    }\n");
        }

        for (options.type_extra_decls) |extra_decls| {
            if (mem.eql(u8, name, extra_decls[0])) {
                try writer.writeAll(extra_decls[1]);
                try writer.writeByte('\n');
            }
            break;
        }

        try writer.writeAll(sd.decls.writer.buffered());
        try writer.writeAll("};\n");

        gpa.free(name);
        for (sd.field_names) |n| gpa.free(n);
        gpa.free(sd.field_names);
        for (sd.type_names) |t| gpa.free(t);
        gpa.free(sd.type_names);
        sd.decls.deinit();
    }

    try writer.print(
        \\pub const ziggy = struct {{
        \\    pub const ex = @"-";
        \\{s}}};
        \\
    , .{namespaced_decls.written()});

    try writer.flush();
}

fn checkDeclForStructDefs(options: TweakDeclsOptions, struct_defs: StructDef.Map, decl: []const u8) !void {
    const name = nameFromDecl(decl).?;

    //std.debug.print("\nchecking decl {s} <- {s}\n", .{ name, decl });

    //for (options.type_aliases) |ta| {
    //    //std.debug.print("checking against {s}!\n", .{ta[0]});
    //    if (options.gather_decls.eval(decl, ta[1])) {
    //        //std.debug.print("it fits! putting in {s} as {f}\n", .{ ta[1], normalizeName(name, options, .camel_case, &.{trimStartMany(ta[0], &.{options.strip_prefixes})}) });
    //        try struct_defs.getPtr(ta[0]).?.decls.writer.print("    pub const {f} = {s};\n", .{
    //            normalizeName(name, options, .camel_case, &.{trimStartMany(ta[1], &.{options.strip_prefixes})}),
    //            name,
    //        });
    //    }
    //}

    //std.debug.print("done checking aliases\n", .{});

    var sd_iter = struct_defs.iterator();
    outer: while (sd_iter.next()) |kv| {
        for (options.type_aliases) |ta| {
            //std.debug.print("checking against {s}!\n", .{ta[1]});
            if (mem.eql(u8, ta[0], kv.key_ptr.*)) {
                if (options.gather_decls.eval(decl, ta[1])) {
                    //std.debug.print("it fits! putting in {s} as {f}\n", .{ kv.key_ptr.*, normalizeName(name, options, .camel_case, &.{trimStartMany(ta[1], &.{options.strip_prefixes})}) });
                    try kv.value_ptr.decls.writer.print("    pub const {f} = {s};\n", .{
                        normalizeName(name, options, .camel_case, &.{trimStartMany(ta[1], &.{options.strip_prefixes})}),
                        name,
                    });
                    continue :outer;
                }
            }
        }

        //std.debug.print("checking against {s}!\n", .{kv.key_ptr.*});
        if (options.gather_decls.eval(decl, kv.key_ptr.*)) {
            //std.debug.print("it fits! putting in {s} as {f}\n", .{ kv.key_ptr.*, normalizeName(name, options, .camel_case, &.{trimStartMany(kv.key_ptr.*, &.{options.strip_prefixes})}) });
            try kv.value_ptr.decls.writer.print("    pub const {f} = {s};\n", .{
                normalizeName(name, options, .camel_case, &.{trimStartMany(kv.key_ptr.*, &.{options.strip_prefixes})}),
                name,
            });
            continue;
        }
    }
}

fn nameFromDecl(decl: []const u8) ?[]const u8 {
    if (mem.startsWith(u8, decl, "pub const ")) {
        const name_end = mem.indexOf(u8, decl, " =").?;
        return decl["pub const ".len..name_end];
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
        const trimmed_name = trimStartMany(nn.name, &.{ nn.rules.strip_prefixes, nn.extra_strip, &.{"_"} });
        //std.debug.print("{s} -> trimmed: {s}\nused:\n", .{ nn.name, trimmed_name });
        //for (nn.rules.strip_prefixes) |s| std.debug.print("    {s}\n", .{s});
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
            },
            .title_case => {
                const first = underscore_iter.next().?;
                try writer.writeByte(ascii.toUpper(first[0]));
                try writer.writeAll(first[1..]);
            },
        }

        while (underscore_iter.next()) |part| {
            try writer.writeByte(ascii.toUpper(part[0]));
            try writer.writeAll(part[1..]);
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
    // private name
    if (name[0] == '_') return false;

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
        \\pub const struct_b2WorldId = extern struct {
        \\    index1: u16 = @import("std").mem.zeroes(u16),
        \\    generation: u16 = @import("std").mem.zeroes(u16),
        \\};
        \\pub const b2WorldId = struct_b2WorldId;
        \\pub extern fn b2World_Step(worldId: b2WorldId, timeStep: f32, subStepCount: c_int) void;
        \\pub const struct_b2Vec2 = extern struct {
        \\    x: f32 = @import("std").mem.zeroes(f32),
        \\    y: f32 = @import("std").mem.zeroes(f32),
        \\};
        \\pub const b2_staticBody: c_int = 0;
        \\pub const b2_kinematicBody: c_int = 1;
        \\pub const b2_dynamicBody: c_int = 2;
        \\pub const b2_bodyTypeCount: c_int = 3;
        \\pub const enum_b2BodyType = c_uint;
        \\pub const b2BodyType = enum_b2BodyType;
    ;
    var input_fbs: std.Io.Reader = .fixed(input);

    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();

    try tweakDecls(std.testing.allocator, &input_fbs, &output.writer, .{
        .strip_prefixes = &.{ "SDL_", "b2" },
        .auto_init_gen = true,
        .camel_case_functions = true,
        .gather_decls = .returns_or_name_contains,
        .type_aliases = &.{
            .{ "SDL_Foo", "FooS" },
            .{ "struct_b2WorldId", "World" },
        },
        .type_extra_decls = &.{
            .{
                "struct_b2Vec2",
                \\    pub fn splat(v: f32) struct_b2Vec2 {
                \\        return .{ .x = v, .y = v };
                \\    }
            },
        },
        .redefine_types = &.{
            .{
                "b2BodyType",
                \\pub const b2BodyType = enum(enum_b2BodyType) {
                \\    static_body = b2_staticBody,
                \\    kinematic_body = b2_kinematicBody,
                \\    dynamic_body = b2_dynamicBody,
                \\    body_type_count = b2_bodyTypeCount,
                \\};
            },
        },
    });

    try std.testing.expectEqualStrings(
        \\const @"-" = @This();
        \\pub extern fn atan2(__y: f64, __x: f64) f64;
        \\pub extern fn atan3(__y: f64, __x: f64) f64;
        \\pub extern fn SDL_Atan2() f64;
        \\pub extern fn SDL_Foo_Add_T(a: SDL_Foo, b: SDL_Foo) SDL_Foo;
        \\pub extern fn SDL_FooS_Inv(a: SDL_Foo) SDL_Foo;
        \\pub const SDL_Data = struct_SDL_Data;
        \\pub extern fn SDL_DoStuff(SDL_Thing) void;
        \\pub fn SDL_Rot_GetAngle(arg_q: b2Rot) callconv(.c) f32 {
        \\    var q = arg_q;
        \\    _ = &q;
        \\    return b2Atan2(q.s, q.c);
        \\}
        \\pub const b2WorldId = struct_b2WorldId;
        \\pub extern fn b2World_Step(worldId: b2WorldId, timeStep: f32, subStepCount: c_int) void;
        \\pub const b2_staticBody: c_int = 0;
        \\pub const b2_kinematicBody: c_int = 1;
        \\pub const b2_dynamicBody: c_int = 2;
        \\pub const b2_bodyTypeCount: c_int = 3;
        \\pub const enum_b2BodyType = c_uint;
        \\pub const b2BodyType = enum(enum_b2BodyType) {
        \\    static_body = b2_staticBody,
        \\    kinematic_body = b2_kinematicBody,
        \\    dynamic_body = b2_dynamicBody,
        \\    body_type_count = b2_bodyTypeCount,
        \\};
        \\pub const SDL_Foo = extern struct {
        \\    type: c_int = @import("std").mem.zeroes(c_int),
        \\    pub fn init(arg_type: c_int) SDL_Foo {
        \\        return .{
        \\            .type = arg_type,
        \\        };
        \\    }
        \\    pub const addT = SDL_Foo_Add_T;
        \\    pub const inv = SDL_FooS_Inv;
        \\};
        \\pub const struct_b2WorldId = extern struct {
        \\    index1: u16 = @import("std").mem.zeroes(u16),
        \\    generation: u16 = @import("std").mem.zeroes(u16),
        \\    pub fn init(arg_index1: u16, arg_generation: u16) struct_b2WorldId {
        \\        return .{
        \\            .index1 = arg_index1,
        \\            .generation = arg_generation,
        \\        };
        \\    }
        \\    pub const step = b2World_Step;
        \\};
        \\pub const struct_SDL_Data = extern struct {
        \\    a: c_int = @import("std").mem.zeroes(c_int),
        \\    b: f32 = @import("std").mem.zeroes(f32),
        \\    pub fn init(arg_a: c_int, arg_b: f32) struct_SDL_Data {
        \\        return .{
        \\            .a = arg_a,
        \\            .b = arg_b,
        \\        };
        \\    }
        \\};
        \\pub const struct_b2Vec2 = extern struct {
        \\    x: f32 = @import("std").mem.zeroes(f32),
        \\    y: f32 = @import("std").mem.zeroes(f32),
        \\    pub fn init(arg_x: f32, arg_y: f32) struct_b2Vec2 {
        \\        return .{
        \\            .x = arg_x,
        \\            .y = arg_y,
        \\        };
        \\    }
        \\    pub fn splat(v: f32) struct_b2Vec2 {
        \\        return .{ .x = v, .y = v };
        \\    }
        \\};
        \\pub const ziggy = struct {
        \\    pub const ex = @"-";
        \\    pub const atan2 = @"-".atan2;
        \\    pub const atan3 = @"-".atan3;
        \\    pub const SDL_Atan2 = @"-".SDL_Atan2;
        \\    pub const Foo = SDL_Foo;
        \\    pub const fooAddT = SDL_Foo_Add_T;
        \\    pub const fooSInv = SDL_FooS_Inv;
        \\    pub const Data = struct_SDL_Data;
        \\    pub const doStuff = SDL_DoStuff;
        \\    pub const rotGetAngle = SDL_Rot_GetAngle;
        \\    pub const WorldId = struct_b2WorldId;
        \\    pub const worldStep = b2World_Step;
        \\    pub const Vec2 = struct_b2Vec2;
        \\};
        \\
    , output.written());
}
