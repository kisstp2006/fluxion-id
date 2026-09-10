# Fluxion Id

Three ways to name a thing, at three scales. For Zig 0.16.

| Module | What it is |
| --- | --- |
| `Uuid` | A 128-bit identifier in the layout RFC 9562 fixes: version 4 from chance, version 7 from the clock and then chance, version 5 from a namespace and a name. Parses the spellings the world writes, prints one. |
| `TypeId` | The same 128 bits with the type in front, as one lowercase string that sorts by when the id was made — `user_01h455vb4pex5vsknk084sn02q`. Follows the TypeID specification. |
| `handle` | Generational handles into a slot table. Eight bytes, an array index to resolve, and a stale one answers null instead of answering the wrong entry. |

They are the same idea at different prices:

| | `Uuid` | `TypeId` | `Handle(T)` |
| --- | --- | --- | --- |
| Size | 16 bytes | 80 bytes | 8 bytes |
| Written down | 36 characters | up to 90 | not meant to be |
| Unique across | everything | everything | one table |
| Valid for | ever | ever | as long as the entry |
| Costs to mint | a random number generator | a random number generator | nothing |
| Costs to resolve | a lookup | a lookup | a bounds check |

Most things want more than one. An asset has a `Uuid` in the file it was built
from, a `TypeId` in the URL that serves it, and a handle in the array it lives
in this run.

All three are values with `eql` and `{f}`. `Uuid` and `TypeId` add `order`,
`lessThan`, `hash` and a text form; `Handle` does not, because the order of two
handles is the order of two slots, which is not a fact about anything.

Nothing here allocates except `handle.Table`, which is the only piece that
stores anything. Nothing here is cryptographic: `Uuid.random` is exactly as
unguessable as the generator handed to it, and `Uuid.fromName` is deliberately
reproducible by anyone who knows the namespace.

## Install

```bash
zig fetch --save git+https://github.com/kisstp2006/fluxion-id
```

Or, for a checkout next to your project, add to `build.zig.zon`:

```zig
.dependencies = .{
    .fluxion_id = .{ .path = "../fluxion-id" },
},
```

Either way, wire it up in `build.zig`:

```zig
const fluxion = b.dependency("fluxion_id", .{
    .target = target,
    .optimize = optimize,
});
exe_mod.addImport("fluxion_id", fluxion.module("fluxion_id"));
```

```zig
const ids = @import("fluxion_id");
```

## Tour

### Uuid

Four ways to make one. The choice is about what you want the id correlated
with:

```zig
ids.random(rng);                                // version 4: chance, and nothing else
ids.sortable(rng, now);                         // version 7: the time, and then chance
ids.Uuid.fromName(project, "models/hull.glb");  // version 5: this namespace, this name
ids.Uuid.fromBytes(sixteen_bytes);              // whatever they meant already
```

The generator is a parameter. For ids that leave the process, pass the one the
operating system seeds, which in Zig 0.16 is reached through `Io`; for a build
that has to produce the same ids twice, pass a seeded `DefaultPrng` instead:

```zig
var entropy: std.Random.IoSource = .{ .io = io };
const rng = entropy.interface();
```

The clock is a parameter too, for the same reason and one more: an id can be
dated to when the event happened rather than to when the id was made.
`ids.unixMillis(io)` is the whole of reading it.

**Version 7, and why it is usually the right one.** The first six bytes are the
millisecond, big-endian, so the ids ascend as they are made — as bytes, as
numbers, and as text. A B-tree keyed on these appends to one page instead of
dirtying a random page per insert. What version 4 buys instead is that an id
says nothing about when it was made, which sometimes matters more.

Two ids made in the same millisecond sort in whatever order chance put them.
A `Clock` uses the twelve bits version 7 reserves as a counter, so they do not:

```zig
var clock: ids.Uuid.Clock = .init;
const a = clock.next(rng, now);
const b = clock.next(rng, now);   // same millisecond, still after `a`
```

It also holds the line when the clock does not — an NTP step, a laptop waking
up, a virtual machine resuming. The ids keep ascending across all of it.

**Text.** Forgiving on the way in, exact on the way out. Dashes anywhere or
nowhere, braces, `urn:uuid:`, either case:

```zig
const id = try ids.parse("f81d4fae-7dec-11d0-a765-00a0c91e6bf6");
try ids.parse("{F81D4FAE7DEC11D0A76500A0C91E6BF6}");   // the same id
try ids.parse("urn:uuid:f81d4fae-7dec-11d0-a765-00a0c91e6bf6");

id.toString();   // [36]u8, held by value - nothing to free
id.toUrn();      // [45]u8, with the scheme in front
```

A literal can be parsed at compile time, so a typo is a compile error rather
than an error to handle:

```zig
const project = ids.Uuid.parseComptime("2f8a1c40-6d3e-4b17-9f22-c1a5e7b90d34");
```

**Names.** `fromName` is the one an asset pipeline wants: a path in, an id out,
the same one next build and on every machine, with nothing written down in
between.

```zig
const hull = ids.Uuid.fromName(project, "models/hull.glb");
// == ids.Uuid.fromName(project, "models/hull.glb"), always
```

Mint the namespace once with `random` and keep it as a constant.
`Uuid.namespaces` holds the four the RFC defines, for the cases where the thing
being named really is a DNS name, a URL, an OID or an X.500 name.

**Reading one back.**

```zig
id.version();     // 4, 5 or 7 for the ones minted here
id.variant();     // .rfc9562, or what an id from elsewhere turns out to be
id.timestamp();   // ?i64 - the milliseconds, for version 7
```

### TypeId

A bare UUID in a log line, a URL bar or a bug report says nothing about what it
points at, and an id pasted from the wrong column looks exactly like a right
one. A type id says both:

```
user_01h455vb4pex5vsknk084sn02q
^^^^ ^
|    the same 128 bits, in Crockford base32
what they name
```

Name the kinds once, and a misspelled prefix becomes a compile error:

```zig
const User = ids.Kind("user");
const Order = ids.Kind("order");

const alice = User.sortable(rng, now);
const cart = try Order.parse(text);   // error.WrongPrefix if it is a user's
```

That check happens where text comes in, not in the type system: `User` and
`Order` both produce a `TypeId`. `handle.Handle` is the identifier here that
the compiler itself tells apart.

**Why base32 rather than the base64 an id would otherwise be squeezed into.**
Crockford's alphabet drops `i`, `l`, `o` and `u` — the first three because they
are hard to tell from `1` and `0`, the last so that no run of digits spells a
word anyone will object to. What is left survives a URL, a shell, a filename,
and being read down a phone line.

**Why the ordering is worth having.** The digits ascend with the alphabet, and
a version 7 uuid begins with its timestamp, so sorting the text sorts by kind
and then by when each id was made. A database that sorts these as strings
agrees with one that sorts them as values:

```zig
a.lessThan(b);   // == std.mem.lessThan(u8, a.toString(&x), b.toString(&y))
```

**Text.** One spelling, and nothing else accepted: lowercase, 26 digits, the
prefix split off at the *last* underscore so that `db_user_01h4…` is a
`db_user`.

```zig
var buf: [ids.TypeId.max_string_len]u8 = undefined;
const text = id.toString(&buf);        // a slice of `buf`
try out.print("{f}", .{id});           // or straight to a writer
```

`toString` takes a buffer because the length varies with the prefix: an array
returned by value would be mostly padding, and a slice of one would point at a
temporary.

The uuid underneath is a public field, because the two forms are for different
places — the `TypeId` is what a person sees, `id.uuid` is what goes in the
column:

```zig
const id = try ids.TypeId.init("user", .sortable(rng, now));
id.uuid;          // the 128 bits
id.prefix();      // "user"
id.timestamp();   // when it was made
```

### handle

The obvious way to refer to an entry in an array is its index, and the obvious
way is broken. Remove entry 7, add another, and every index 7 still held
anywhere now points at the new entry — a dangling reference with no pointer in
sight, and no crash to tell you.

A handle is an index with a generation beside it. The slot counts how many
occupants it has had, the handle remembers which one it was made for, and `get`
compares them:

```zig
var meshes: ids.Table(Mesh) = .empty;
defer meshes.deinit(gpa);

const hull = try meshes.add(gpa, mesh);
meshes.get(hull).?.triangles = 1200;

_ = meshes.remove(hull);
meshes.get(hull);           // null, even after the slot is handed out again
```

Entries keep their slot for life, so a handle stays valid however much is added
or removed around it. The free slots are chained through each other — a slot
holding nothing has nothing better to do with its bytes than name the next free
one — so removal never allocates and the table is exactly one allocation.

`Handle(T)` carries the type of what it points at, so a `Handle(Mesh)` and a
`Handle(Texture)` are different Zig types and the compiler refuses to swap
them. That costs nothing at runtime: both are a `u64`. Generation 0 is never
handed out, which makes an all-zero handle mean `none` rather than slot zero.

```zig
const Instance = struct {
    mesh: ids.Handle(Mesh),   // eight bytes, and not a Handle(Texture)
    transform: [16]f32,
};
```

Walking it hands back each handle alongside its value, so an iteration can
store what it found:

```zig
var it = meshes.iterator();
while (it.next()) |entry| {
    entry.value.triangles += 1;
    remember(entry.handle);
}
```

The honest limit: a slot that has been through 2^32 occupants starts its
generations again, and a handle kept across all of that could match a stranger.
Four billion removals of one slot is a long way past the point where a handle
should have been dropped, but it is not never.

## Everything together

```zig
// The source file's id comes from its path, so a rebuild that touches
// nothing else produces the same id again.
const hull_uuid = ids.Uuid.fromName(project, "models/hull.glb");

// What a person sees, and what the URL carries.
const Mesh = ids.Kind("mesh");
const hull_id = Mesh.of(hull_uuid);

// And what the rest of the program refers to it by, this run.
const hull = try meshes.add(gpa, .{ .id = hull_id, .name = "hull" });
_ = try instances.add(gpa, .{ .mesh = hull, .label = "hull.left" });

// The mesh is unloaded. Its uuid and its text form are as good as they ever
// were - they name a thing, not a slot - but the handle stops resolving,
// and it does not start resolving again when the slot is reused.
_ = meshes.remove(hull);
meshes.get(hull);   // null
```

`zig build example` runs exactly this, on a handful of imaginary meshes, and
prints every id as it goes.

## Build

```bash
zig build test        # run the test suite
zig build example     # build and run the demo tour
zig build docs        # generate API docs into zig-out/docs
```

The ids are checked against the published vectors: RFC 9562's own name-based
example, and the TypeID specification's `prefix_01h455vb4pex5vsknk084sn02q`.
The rest is checked by round trip — every text form parses back into the id it
came from — and by the cases that make a generational handle worth having: a
removed entry, a reused slot, and a handle held across both.

## Requirements

Zig 0.16.0.

## License

`SPDX-License-Identifier: CC0-1.0`

[CC0 1.0 Universal](LICENSE) — public domain dedication. Do whatever you like
with this, no attribution required.
