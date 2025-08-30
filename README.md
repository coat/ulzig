# ulzig

A Zig library and small command line tool for compressing and decompressing
things with the [Uxn LZ Format
(ULZ)](https://wiki.xxiivv.com/site/ulz_format.html). This is a port of a [C
implementation](https://git.sr.ht/~rabbits/uxn-utils/tree/main/item/cli/lz)
that's a part of [uxn-utils](https://git.sr.ht/~rabbits/uxn-utils) by [Hundred
Rabbits](https://100r.co/site/home.html).

## Usage

### Zig

```zig
const ulz = @import("ulz");

const decoded = try ulz.decode(allocator, @embedFile("file.ulz"));
defer allocator.free(decoded);

const encoded = try ulz.encode(allocator, "compress meeeeee");
defer allocator.free(encoded);
```

#### Getting Started

To import ulz in your project, run the following command:

```bash
zig fetch --save git+https://github.com/coat/ulzig
```

Then set add the dependency in your `build.zig`:

```zig
const ulz = b.dependency("ulzig", .{
    .target = target,
    .optimize = optimize,
})

mod.root_module.addImport("ulz", ulz.module("ulzig"));
```

### CLI

Compress the file `foo` into `foo.ulz`:

```bash
ulz foo
```

Decompress `foo.ulz` into `foo`:

```bash
ulz -d foo.ulz
```

## Prior Art

Original
[implementation](https://git.sr.ht/~rabbits/uxn-utils/tree/main/item/cli/lz) in
C that this code was based on.
