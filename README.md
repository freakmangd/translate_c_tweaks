## Install
Run `zig fetch --save git+https://github.com/freakmangd/translate_c_tweaks` in your project directory

In your `build.zig`:
```zig
const tc = b.addTranslateC(.{
    .root_source_file = b.path("src/my_header.h"),
    .target = target,
    .optimize = optimize,
});

const tc_tweaked = @import("translate_c_tweaks").tweakTranslateC(b, .{
    .translate_c_step = tc,
    .prefix_trim_string = "SDL_",
    .target = target,
    .optimize = optimize,
});

project_module.addImport("my_lib", tc_tweaked);
```

If you saved the library under a different name in your zon's dependencies, you can either specify that name:
```zig
const tc_tweaked = @import("what_you_named_it").tweakTranslateC(b, .{
    .translate_c_step = tc,
    .prefix_trim_string = "SDL_",
    .target = target,
    .optimize = optimize,
    // here
    .dependency_name = "what_you_named_it",
});
```
Or provide the artifact yourself:
```zig
const tc_tweaked = @import("what_you_named_it").tweakTranslateC(b, .{
    .translate_c_step = tc,
    .prefix_trim_string = "SDL_",
    .target = target,
    .optimize = optimize,
    // here
    .tweaks_artifact = b.dependency("what_you_named_it", .{...}).artifact("tc_tweaks"),
});
```

## Usage
The name you used in `addImport` can be imported from any file inside `project_module`, any functions or structs that start with the prefix you gave will now be accessible without that prefix.

Only using `addTranslateC`:
```zig
@import("my_lib").SDL_doStuff();
```
Adding the tweaks step:
```zig
@import("my_lib").doStuff();
```

ZLS seems to play nice as well, at least on my machine
