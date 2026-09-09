// SPDX-License-Identifier: CC0-1.0

// Fluxion Id - three ways to name a thing, at three scales.
//
// Three pieces, each its own module under `fluxion::id`:
//
//   `uuid`      128 bits, unique everywhere, minted without asking anyone
//   `type_id`   the same 128 bits with the type in front, as one sortable
//               string a person can read back
//   `handle`    64 bits, unique inside one table, and free to mint
//
// The same idea at different prices. A `Uuid` costs sixteen bytes and a random
// number generator, and is still the right name next year on another machine.
// A `TypeId` adds a few characters and says what the id is *for*, which turns
// a log line into something a person can act on. A handle costs eight bytes
// and means nothing outside the table that issued it - but resolving one is an
// array index, not a lookup.
//
// Most things want more than one. An asset has a `Uuid` in the file it was
// built from, a `TypeId` in the URL that serves it, and a handle in the
// array it lives in this run.
//
// All three are values, and all three share one shape:
//
//   `equals`                  are these the same id
//   `compare_to` / `less`     sorting, where sorting means something
//   `%s`                      print it
//
// Nothing here allocates except `Table`, which is the only piece that stores
// anything. Nothing here is cryptographic: `uuid::random` is as unguessable
// as the generator handed to it and no more, and `uuid::from_name` is
// deliberately reproducible by anyone who knows the namespace.
//
// This module holds the shorthands. Importing `fluxion::id` imports the three
// sub-modules with it.
module fluxion::id;
import fluxion::id::uuid, fluxion::id::type_id, fluxion::id::handle;
import std::math::random;
import std::time;

<*
 Shorthand for `uuid::random`, so call sites read `id::random(rng)`.
*>
fn Uuid random(Random rng)
{
	return uuid::random(rng);
}

<*
 Shorthand for `uuid::sortable`: a random id with the time in front of it.
*>
fn Uuid sortable(Random rng, long unix_ms)
{
	return uuid::sortable(rng, unix_ms);
}

<*
 Shorthand for `uuid::parse`.
*>
fn Uuid? parse(String text)
{
	return uuid::parse(text);
}

<*
 The wall clock in the units `sortable` wants.

 The standard library's `time::now()` counts microseconds since the Unix
 epoch; this is the division, written down here so that a caller who just
 wants an id now does not have to go and find out:

     Uuid id = id::sortable(rng, id::unix_millis());
*>
fn long unix_millis()
{
	return (long)time::now() / 1000;
}

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

struct Asset
{
	TypeId id;
	String name;
}

const Kind MESH = type_id::@kind("mesh");
const Kind TEXTURE = type_id::@kind("texture");

fn void test_the_pieces_compose() @test
{
	// One asset, named three ways at once: by the id its source file carries,
	// by the text a person sees, and by the slot it lives in this run.
	Sfc64Random prng;
	random::seed(&prng, 0xA55E7);
	const long BUILT_AT = 1_700_000_000_000;

	Table{Asset} assets;
	assets.init(mem);
	defer assets.free();

	// The source file's id is derived from its path, so a rebuild that
	// touches nothing else produces the same id again.
	const Uuid PROJECT = uuid::@parse("2f8a1c40-6d3e-4b17-9f22-c1a5e7b90d34");
	Uuid hull_uuid = uuid::from_name(PROJECT, "models/hull.glb");
	test::@check(hull_uuid.equals(uuid::from_name(PROJECT, "models/hull.glb")));

	Handle{Asset} hull = assets.add({ .id = MESH.of(hull_uuid), .name = "hull" });
	Handle{Asset} wing = assets.add({ .id = MESH.sortable(&prng, BUILT_AT), .name = "wing" });

	// The handle resolves to the asset, and the asset's text form parses back
	// into the same id.
	char[type_id::MAX_STRING_LEN] buf;
	String printed = assets.get(hull).id.to_string(&buf);
	test::@check(MESH.parse(printed)!!.equals(MESH.of(hull_uuid)));
	test::@error(TEXTURE.parse(printed), type_id::WRONG_PREFIX);

	// The wing goes. Its uuid and text form are as good as they ever were -
	// they name a thing, not a slot - but the handle stops resolving.
	Asset removed = assets.remove(wing)!!;
	test::@check(assets.get(wing) == null);
	test::eq(removed.id.timestamp()!!, BUILT_AT);
	test::@check(assets.get(hull) != null);

	// And the slot comes back with its generation moved on, so the old handle
	// does not quietly find the new occupant.
	Handle{Asset} cockpit = assets.add({ .id = MESH.sortable(&prng, BUILT_AT + 1), .name = "cockpit" });
	test::eq(cockpit.index, wing.index);
	test::@check(assets.get(wing) == null);
	test::eq(assets.get(cockpit).name, "cockpit");

	// Time order survives the round trip through text, which is what makes
	// "the newest first" a sort rather than a query.
	test::@check(removed.id.less(assets.get(cockpit).id));
}

fn void test_shorthands() @test
{
	Sfc64Random prng;
	random::seed(&prng, 7);

	test::eq(random(&prng).version(), (char)4);
	test::eq(sortable(&prng, 1_700_000_000_000).version(), (char)7);
	test::eq(sortable(&prng, 1_700_000_000_000).timestamp()!!, 1_700_000_000_000L);

	String text = "f81d4fae-7dec-11d0-a765-00a0c91e6bf6";
	test::@check(parse(text)!!.equals(uuid::parse(text)!!));
	test::@error(parse("nope"), uuid::INVALID_CHARACTER);
	test::@error(parse("f81d4fae"), uuid::INVALID_LENGTH);

	// The clock reads as a plausible number of milliseconds: after 2024.
	test::@check(unix_millis() > 1_700_000_000_000);
}
