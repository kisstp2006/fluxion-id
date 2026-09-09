# Fluxion Id

Three ways to name a thing, at three scales. For C3 0.8.

| Module | What it is |
| --- | --- |
| `uuid` | A 128-bit identifier in the layout RFC 9562 fixes: version 4 from chance, version 7 from the clock and then chance, version 5 from a namespace and a name. Parses the spellings the world writes, prints one. |
| `type_id` | The same 128 bits with the type in front, as one lowercase string that sorts by when the id was made - `user_01h455vb4pex5vsknk084sn02q`. Follows the TypeID specification. |
| `handle` | Generational handles into a slot table. Eight bytes, an array index to resolve, and a stale one answers null instead of answering the wrong entry. |

They are the same idea at different prices:

| | `Uuid` | `TypeId` | `Handle{Type}` |
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

All three are values with `equals` and `%s`. `Uuid` and `TypeId` add
`compare_to`, `less`, `hash` and a text form; `Handle` does not order, because
the order of two handles is the order of two slots, which is not a fact about
anything.

Nothing here allocates except `Table`, which is the only piece that stores
anything. Nothing here is cryptographic: `uuid::random` is exactly as
unguessable as the generator handed to it, and `uuid::from_name` is
deliberately reproducible by anyone who knows the namespace.

## Install

The library is the `fluxion_id.c3l` directory in this repository. For a
checkout next to your project, add to `project.json`:

```json
"dependency-search-paths": ["../fluxion-id"],
"dependencies": ["fluxion_id"]
```

Then, in the code:

```c3
import fluxion::id;
```

## Tour

### uuid

Four ways to make one. The choice is about what you want the id correlated
with:

```c3
id::random(&rng);                                // version 4: chance, and nothing else
id::sortable(&rng, now);                         // version 7: the time, and then chance
uuid::from_name(PROJECT, "models/hull.glb");     // version 5: this namespace, this name
uuid::from_bytes(sixteen_bytes);                 // whatever they meant already
```

The generator is a parameter: any of the standard library's `Random`
implementations, passed by address. For ids that leave the process, seed it
from the operating system; for a build that has to produce the same ids twice,
seed it from a number instead:

```c3
Sfc64Random rng;
random::seed_entropy(&rng);     // or random::seed(&rng, 42)
```

The clock is a parameter too, for the same reason and one more: an id can be
dated to when the event happened rather than to when the id was made.
`id::unix_millis()` is the whole of reading it.

**Version 7, and why it is usually the right one.** The first six bytes are the
millisecond, big-endian, so the ids ascend as they are made - as bytes, as
numbers, and as text. A B-tree keyed on these appends to one page instead of
dirtying a random page per insert. What version 4 buys instead is that an id
says nothing about when it was made, which sometimes matters more.

Two ids made in the same millisecond sort in whatever order chance put them.
A `Clock` uses the twelve bits version 7 reserves as a counter, so they do not:

```c3
Clock clock;
clock.init();
Uuid a = clock.next(&rng, now);
Uuid b = clock.next(&rng, now);   // same millisecond, still after `a`
```

It also holds the line when the clock does not - an NTP step, a laptop waking
up, a virtual machine resuming. The ids keep ascending across all of it.

**Text.** Forgiving on the way in, exact on the way out. Dashes anywhere or
nowhere, braces, `urn:uuid:`, either case:

```c3
Uuid id = id::parse("f81d4fae-7dec-11d0-a765-00a0c91e6bf6")!;
id::parse("{F81D4FAE7DEC11D0A76500A0C91E6BF6}")!;   // the same id
id::parse("urn:uuid:f81d4fae-7dec-11d0-a765-00a0c91e6bf6")!;

id.to_string();   // char[36], held by value - nothing to free
id.to_urn();      // char[45], with the scheme in front
```

A literal can be parsed at compile time, so a typo is a compile error rather
than an error to handle, and the result can be a constant:

```c3
const Uuid PROJECT = uuid::@parse("2f8a1c40-6d3e-4b17-9f22-c1a5e7b90d34");
```

**Names.** `from_name` is the one an asset pipeline wants: a path in, an id out,
the same one next build and on every machine, with nothing written down in
between.

```c3
Uuid hull = uuid::from_name(PROJECT, "models/hull.glb");
// == uuid::from_name(PROJECT, "models/hull.glb"), always
```

Mint the namespace once with `random` and keep it as a constant.
`uuid::NAMESPACE_DNS` and its three siblings are the ones the RFC defines, for
the cases where the thing being named really is a DNS name, a URL, an OID or an
X.500 name.

**Reading one back.**

```c3
id.version();     // 4, 5 or 7 for the ones minted here
id.variant();     // RFC9562, or what an id from elsewhere turns out to be
id.timestamp();   // long? - the milliseconds, for version 7
```

### type_id

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

```c3
const Kind USER = type_id::@kind("user");
const Kind ORDER = type_id::@kind("order");

TypeId alice = USER.sortable(&rng, now);
TypeId cart = ORDER.parse(text)!;   // WRONG_PREFIX if it is a user's
```

That check happens where text comes in, not in the type system: `USER` and
`ORDER` both produce a `TypeId`. `Handle` is the identifier here that the
compiler itself tells apart.

**Why base32 rather than the base64 an id would otherwise be squeezed into.**
Crockford's alphabet drops `i`, `l`, `o` and `u` - the first three because they
are hard to tell from `1` and `0`, the last so that no run of digits spells a
word anyone will object to. What is left survives a URL, a shell, a filename,
and being read down a phone line.

**Why the ordering is worth having.** The digits ascend with the alphabet, and
a version 7 uuid begins with its timestamp, so sorting the text sorts by kind
and then by when each id was made. A database that sorts these as strings
agrees with one that sorts them as values:

```c3
a.less(b);   // == a.to_string(&x).compare_to(b.to_string(&y)) < 0
```

**Text.** One spelling, and nothing else accepted: lowercase, 26 digits, the
prefix split off at the *last* underscore so that `db_user_01h4...` is a
`db_user`.

```c3
char[type_id::MAX_STRING_LEN] buf;
String text = id.to_string(&buf);      // a slice of `buf`
io::printfn("%s", id);                 // or straight to a writer
```

`to_string` takes a buffer because the length varies with the prefix: an array
returned by value would be mostly padding, and a slice of one would point at a
temporary.

The uuid underneath is a public field, because the two forms are for different
places - the `TypeId` is what a person sees, `id.uuid` is what goes in the
column:

```c3
TypeId id = type_id::init("user", uuid::sortable(&rng, now))!;
id.uuid;          // the 128 bits
id.prefix();      // "user"
id.timestamp();   // when it was made
```

### handle

The obvious way to refer to an entry in an array is its index, and the obvious
way is broken. Remove entry 7, add another, and every index 7 still held
anywhere now points at the new entry - a dangling reference with no pointer in
sight, and no crash to tell you.

A handle is an index with a generation beside it. The slot counts how many
occupants it has had, the handle remembers which one it was made for, and `get`
compares them:

```c3
Table{Mesh} meshes;
meshes.init(mem);
defer meshes.free();

Handle{Mesh} hull = meshes.add(mesh);
meshes.get(hull).triangles = 1200;

meshes.remove(hull)!;
meshes.get(hull);           // null, even after the slot is handed out again
```

Entries keep their slot for life, so a handle stays valid however much is added
or removed around it. The free slots are chained through each other - a slot
holding nothing has nothing better to do with its bytes than name the next free
one - so removal never allocates and the table is exactly one allocation.

`Handle{Type}` carries the type of what it points at, so a `Handle{Mesh}` and a
`Handle{Texture}` are different C3 types and the compiler refuses to swap them.
That costs nothing at runtime: both are two `uint`s. Generation 0 is never
handed out, which makes an all-zero handle mean none rather than slot zero.

```c3
struct Instance
{
    Handle{Mesh} mesh;   // eight bytes, and not a Handle{Texture}
    float[16] transform;
}
```

Walking it hands back each handle alongside its value, so an iteration can
store what it found:

```c3
Iterator{Mesh} it = meshes.iterator();
while (try entry = it.next())
{
    entry.value.triangles += 1;
    remember(entry.handle);
}
```

The honest limit: a slot that has been through 2^32 occupants starts its
generations again, and a handle kept across all of that could match a stranger.
Four billion removals of one slot is a long way past the point where a handle
should have been dropped, but it is not never.

## Everything together

```c3
// The source file's id comes from its path, so a rebuild that touches
// nothing else produces the same id again.
Uuid hull_uuid = uuid::from_name(PROJECT, "models/hull.glb");

// What a person sees, and what the URL carries.
const Kind MESH = type_id::@kind("mesh");
TypeId hull_id = MESH.of(hull_uuid);

// And what the rest of the program refers to it by, this run.
Handle{Mesh} hull = meshes.add({ .id = hull_id, .name = "hull" });
instances.add({ .mesh = hull, .label = "hull.left" });

// The mesh is unloaded. Its uuid and its text form are as good as they ever
// were - they name a thing, not a slot - but the handle stops resolving,
// and it does not start resolving again when the slot is reused.
meshes.remove(hull)!;
meshes.get(hull);   // null
```

`c3c run demo` runs exactly this, on a handful of imaginary meshes, and prints
every id as it goes.

## Build

```bash
c3c test          # run the test suite
c3c run demo      # build and run the demo tour
```

The ids are checked against the published vectors: RFC 9562's own name-based
example, and the TypeID specification's `prefix_01h455vb4pex5vsknk084sn02q`.
The rest is checked by round trip - every text form parses back into the id it
came from - and by the cases that make a generational handle worth having: a
removed entry, a reused slot, and a handle held across both.

## Layout

```
fluxion_id.c3l/manifest.json   what a consumer's build reads
src/                           the library, one module per file
examples/demo.c3               the tour
project.json5                  this repository's own build: tests and the demo
```

## Requirements

C3 0.8.3.

## License

`SPDX-License-Identifier: CC0-1.0`

[CC0 1.0 Universal](LICENSE) - public domain dedication. Do whatever you like
with this, no attribution required.
