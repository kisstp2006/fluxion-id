// SPDX-License-Identifier: CC0-1.0

// Handles: an index and a generation, in eight bytes.
//
// A `Uuid` is a name a thing keeps forever, anywhere. A handle is the
// opposite trade: it means something only inside one `Table`, in one
// process, for as long as that entry lives - and in exchange it costs eight
// bytes, no random number generator, and a bounds check to resolve.
//
// The obvious version is a plain index, and it is broken: remove entry 7, add
// another, and every index 7 still held now points at the new entry - a
// dangling reference with no pointer in sight and no crash to tell you. The
// generation counter is the fix. Each slot counts how often it has been used,
// a handle remembers which use it was made for, and `get` returns null when
// the two have parted company.
//
//     Table{Mesh} meshes;
//     meshes.init(mem);
//     defer meshes.free();
//
//     Handle{Mesh} hull = meshes.add(mesh);
//     meshes.get(hull).scale = 2;
//
//     meshes.remove(hull)!;
//     meshes.get(hull);           // null, even after the slot is handed out again
//
// `Handle{Mesh}` and `Handle{Texture}` are different C3 types and the
// compiler refuses to swap them. That costs nothing at run time: both are
// two `uint`s. The whole module is generic over the entry type, so the
// handle, the table, its slots and its iterator are stamped out together
// for each `Type` and agree with each other by construction.
module fluxion::id::handle <Type>;
import std::collections::list;
import std::io;

<*
 A handle to a `Type`, in a `Table{Type}`.

 The index says which slot; the generation says which occupant of it.
 Generation 0 is never handed out, so a zeroed handle - one in a struct that
 was declared and never assigned, which C3 zero-fills - reads as none rather
 than as a live reference to slot zero.

 It is two `uint`s and behaves like one number: copy it, compare it with
 `equals`, use it as a `HashMap` key, put it in a component array. Handles
 from two different tables of the same type are not interchangeable, and
 nothing here can tell them apart - keep the table and its handles together.
*>
struct Handle (Printable)
{
	uint index;
	uint generation;
}

<*
 Whether this is the no-entry handle, which all-zero bytes also are.
*>
fn bool Handle.is_none(self)
{
	return self.generation == 0;
}

fn bool Handle.equals(self, Handle other)
{
	return self.index == other.index && self.generation == other.generation;
}

fn uint Handle.hash(self)
{
	return self.to_int().hash();
}

<*
 The eight bytes as one number, for storing in a format that has no room
 for a struct. The reverse is `bitcast(value, Handle{Mesh})`: C3 will
 reinterpret any value as any type of the same size, and this is exactly the
 case that is for.
*>
fn ulong Handle.to_int(self)
{
	return bitcast(self, ulong);
}

<*
 What `%s` prints: `#7v2` is the third occupant of slot seven.
*>
fn sz? Handle.to_format(&self, Formatter* f) @dynamic
{
	if (self.is_none()) return f.print("#none");
	return f.printf("#%dv%d", self.index, self.generation);
}

<*
 Storage that hands out `Handle{Type}` and answers them.

 Entries keep their slot for life, so a handle stays valid however much is
 added or removed around it - unlike an index into a `List`, which moves the
 moment something before it is taken out. Removal leaves the slot in place
 with its generation stepped, and the next `add` takes it back.

 The free slots are chained through each other: a slot that holds nothing
 has nothing better to do with its bytes than name the next free one. So
 removal never allocates, and the table is exactly one allocation.
*>
struct Table
{
	List{Slot} slots;
	// The first slot of the free chain, or `END_OF_CHAIN`.
	uint first_free;
	// How many slots hold something. Kept rather than counted, because
	// counting means walking every slot.
	sz live;
}

// One less than the number of slots there could ever be, so it can mean "no
// next" without costing an optional per slot.
const uint END_OF_CHAIN = uint::max;

struct Slot
{
	// How many occupants this slot has had. Starts at 1 and steps on every
	// removal, skipping 0 so it never collides with the none handle.
	uint generation;
	// While the slot is free, the next free slot. Ignored while it holds a
	// value.
	uint next_free;
	// Whether `value` means anything. C3 has no optional field, so the flag
	// is spelled out.
	bool occupied;
	Type value;
}

// The handle named nothing this table ever handed out. See `remove`.
faultdef STALE_HANDLE;

<*
 An empty table that will allocate from `allocator` when it grows. Nothing
 is allocated until the first `add`.
*>
fn void Table.init(&self, Allocator allocator)
{
	self.slots.init(allocator);
	self.first_free = END_OF_CHAIN;
	self.live = 0;
}

fn void Table.free(&self)
{
	self.slots.free();
	*self = {};
}

// -------------------------------------------------------------------------
// Changing it
// -------------------------------------------------------------------------

<*
 Store `value` and return the handle to it. Reuses a free slot when there is
 one, which is why the generation matters.

 @require self.slots.len() < END_OF_CHAIN : "a table cannot hold more slots than an index can name"
*>
fn Handle Table.add(&self, Type value)
{
	if (self.first_free != END_OF_CHAIN)
	{
		uint index = self.first_free;
		Slot* slot = &self.slots[index];
		self.first_free = slot.next_free;
		slot.value = value;
		slot.occupied = true;
		self.live++;
		return { .index = index, .generation = slot.generation };
	}

	uint index = (uint)self.slots.len();
	self.slots.push({ .generation = 1, .next_free = END_OF_CHAIN, .occupied = true, .value = value });
	self.live++;
	return { .index = index, .generation = 1 };
}

<*
 Take the entry out and hand it back, or `STALE_HANDLE` if the handle was
 already stale. The slot goes on the free chain with its generation stepped,
 so every handle to what used to be there stops resolving at the same
 moment.

 A slot that has been through 2^32 occupants starts its generations again,
 and a handle kept across all of that could match a stranger. Four billion
 removals of one slot is a long way past the point where a handle should
 have been dropped, but it is not never.
*>
fn Type? Table.remove(&self, Handle h) @maydiscard
{
	Slot* slot = self.live_slot(h);
	if (slot == null) return STALE_HANDLE~;

	Type taken = slot.value;
	slot.occupied = false;
	slot.generation++;
	if (slot.generation == 0) slot.generation = 1;
	slot.next_free = self.first_free;
	self.first_free = h.index;
	self.live--;
	return taken;
}

<*
 Empty the table, keeping the slots.

 The slots stay because the generations live in them: throwing them away
 would let the next `add` hand out a handle that an old one compares equal
 to.
*>
fn void Table.clear_retaining_capacity(&self)
{
	self.first_free = END_OF_CHAIN;
	// Backwards, so the chain comes out in ascending order and slots are
	// reused in the order they were first made.
	for (sz index = self.slots.len(); index > 0; index--)
	{
		Slot* slot = &self.slots[index - 1];
		if (slot.occupied)
		{
			slot.occupied = false;
			slot.generation++;
			if (slot.generation == 0) slot.generation = 1;
		}
		slot.next_free = self.first_free;
		self.first_free = (uint)(index - 1);
	}
	self.live = 0;
}

// -------------------------------------------------------------------------
// Reading it
// -------------------------------------------------------------------------

<*
 What `h` points at, or null if it points at nothing any more.

 The pointer is into the table's storage, so it survives until the next
 `add` grows it. Hold the handle, not the pointer.
*>
fn Type* Table.get(&self, Handle h)
{
	Slot* slot = self.live_slot(h);
	return slot == null ? null : &slot.value;
}

fn bool Table.contains(&self, Handle h)
{
	return self.live_slot(h) != null;
}

<*
 How many entries the table holds.
*>
fn sz Table.count(&self)
{
	return self.live;
}

<*
 How many slots exist, live and free together. The high-water mark of
 `count`, near enough.
*>
fn sz Table.slot_count(&self)
{
	return self.slots.len();
}

fn Slot* Table.live_slot(&self, Handle h)
{
	if (h.generation == 0 || h.index >= self.slots.len()) return null;
	Slot* slot = &self.slots[h.index];
	if (slot.generation != h.generation) return null;
	if (!slot.occupied) return null;
	return slot;
}

<*
 Walks the live entries in slot order, handing back each handle alongside
 its value. Adding or removing during the walk invalidates it, as with any
 container.

     Iterator{Mesh} it = meshes.iterator();
     while (try entry = it.next())
     {
         entry.value.triangles += 1;
         remember(entry.handle);
     }
*>
fn Iterator Table.iterator(&self)
{
	return { .table = self };
}

struct Iterator
{
	Table* table;
	uint index;
}

struct Entry
{
	Handle handle;
	Type* value;
}

<*
 The next live entry, or an empty optional at the end. `while (try entry =
 it.next())` is the loop: `try` unwraps while there is something, and the
 fault it hands back to stop is nothing more than a signal.
*>
fn Entry? Iterator.next(&self)
{
	while (self.index < self.table.slots.len())
	{
		uint index = self.index;
		self.index++;
		Slot* slot = &self.table.slots[index];
		if (slot.occupied)
		{
			return { .handle = { .index = index, .generation = slot.generation }, .value = &slot.value };
		}
	}
	return NO_MORE_ENTRIES~;
}

faultdef NO_MORE_ENTRIES;

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------
//
// A generic module cannot hold tests - there is no `Type` to run them for -
// so they live in a plain module beside it, over two concrete entry types.

module fluxion::id::handle_test @test;
import fluxion::id::handle;
import std::collections::map;

struct Mesh
{
	String name;
	uint triangles;
}

struct Texture
{
	String name;
}

alias MeshHandle = Handle{Mesh};

// Entries that refer to each other by handle rather than by pointer, so
// either table can grow without anything going stale.
struct Instance
{
	Handle{Mesh} mesh;
	float scale;
}

fn void test_a_handle_is_eight_bytes_and_zero_means_none() @test
{
	test::eq(Handle{Mesh}::size, 8);
	Handle{Mesh} none;
	test::eq(none.to_int(), 0UL);
	test::@check(none.is_none());
	test::@check(bitcast(0UL, Handle{Mesh}).is_none());

	Handle{Mesh} h = { .index = 7, .generation = 2 };
	test::@check(!h.is_none());
	test::@check(h.equals(bitcast(h.to_int(), Handle{Mesh})));
	@pool()
	{
		test::eq(string::tformat("%s", h), "#7v2");
		test::eq(string::tformat("%s", none), "#none");
	};

	// A handle is a value, so a struct full of them is too, and it hashes. A
	// generic inside a generic wants a name first; that is a parser rule.
	HashMap{MeshHandle, uint} map;
	map.init(mem);
	defer map.free();
	map.set(h, 1);
	test::@check(map.has_key((Handle{Mesh}){ .index = 7, .generation = 2 }));
}

fn void test_handles_to_different_types_are_different_types() @test
{
	test::@check(Handle{Mesh}::typeid != Handle{Texture}::typeid);
	// They are the same eight bytes; it is the compiler that keeps them
	// apart, which is the whole point. `$defined` asks whether an expression
	// would compile, and assigning one to the other would not.
	test::eq(Handle{Mesh}::size, Handle{Texture}::size);
	Handle{Mesh} m;
	Handle{Texture} t;
	test::@check(!$defined(m = t));
}

fn void test_add_get_remove() @test
{
	Table{Mesh} meshes;
	meshes.init(mem);
	defer meshes.free();

	test::eq(meshes.count(), 0);

	Handle{Mesh} hull = meshes.add({ .name = "hull", .triangles = 1200 });
	Handle{Mesh} wing = meshes.add({ .name = "wing", .triangles = 300 });
	test::eq(meshes.count(), 2);

	test::eq(meshes.get(hull).name, "hull");
	test::eq(meshes.get(wing).name, "wing");
	test::@check(meshes.contains(hull));

	// The pointer is into the table, so writing through it sticks.
	meshes.get(hull).triangles = 1201;
	test::eq(meshes.get(hull).triangles, 1201U);

	Mesh taken = meshes.remove(hull)!!;
	test::eq(taken.name, "hull");
	test::eq(meshes.count(), 1);
	test::@check(meshes.get(hull) == null);
	test::@check(!meshes.contains(hull));
	// Removing it again says so rather than pretending.
	test::@error(meshes.remove(hull), handle::STALE_HANDLE);

	// The other handle did not move.
	test::eq(meshes.get(wing).name, "wing");
}

fn void test_a_reused_slot_does_not_answer_the_old_handle() @test
{
	Table{Mesh} meshes;
	meshes.init(mem);
	defer meshes.free();

	Handle{Mesh} first = meshes.add({ .name = "first" });
	test::eq(first.index, 0U);
	test::eq(first.generation, 1U);

	meshes.remove(first);
	Handle{Mesh} second = meshes.add({ .name = "second" });

	// Same slot, next generation - which is exactly the case a bare index
	// would get wrong.
	test::eq(second.index, first.index);
	test::eq(second.generation, 2U);
	test::@check(!first.equals(second));
	test::@check(meshes.get(first) == null);
	test::eq(meshes.get(second).name, "second");

	// And one slot was enough for both.
	test::eq(meshes.slot_count(), 1);
}

fn void test_handles_survive_everything_moving_around_them() @test
{
	Table{Mesh} meshes;
	meshes.init(mem);
	defer meshes.free();

	Handle{Mesh}[100] handles;
	foreach (i, &h : handles)
	{
		*h = meshes.add({ .name = "mesh", .triangles = (uint)i });
	}

	// Take out every other one, then put back twice as many, which reuses the
	// freed slots and grows past them.
	for (sz i = 0; i < handles.len; i += 2)
	{
		test::eq(meshes.remove(handles[i])!!.triangles, (uint)i);
	}
	for (uint j = 0; j < 100; j++)
	{
		meshes.add({ .name = "later", .triangles = j });
	}

	// Every handle that was not removed still finds what it was given.
	for (sz i = 1; i < handles.len; i += 2)
	{
		test::eq(meshes.get(handles[i]).triangles, (uint)i);
	}
	// And every handle that was removed still finds nothing.
	for (sz i = 0; i < handles.len; i += 2)
	{
		test::@check(meshes.get(handles[i]) == null);
	}
	test::eq(meshes.count(), 150);
}

fn void test_free_slots_are_reused_before_the_table_grows() @test
{
	Table{Mesh} meshes;
	meshes.init(mem);
	defer meshes.free();

	Handle{Mesh} a = meshes.add({ .name = "a" });
	Handle{Mesh} b = meshes.add({ .name = "b" });
	Handle{Mesh} c = meshes.add({ .name = "c" });
	test::eq(meshes.slot_count(), 3);

	meshes.remove(a);
	meshes.remove(c);
	test::eq(meshes.slot_count(), 3);

	// The chain is last freed first, so slot 2 comes back before slot 0.
	test::eq(meshes.add({ .name = "d" }).index, 2U);
	test::eq(meshes.add({ .name = "e" }).index, 0U);
	test::eq(meshes.slot_count(), 3);

	// Only now is there nothing to reuse.
	test::eq(meshes.add({ .name = "f" }).index, 3U);
	test::@check(meshes.contains(b));
}

fn void test_clearing_keeps_the_generations() @test
{
	Table{Mesh} meshes;
	meshes.init(mem);
	defer meshes.free();

	Handle{Mesh} a = meshes.add({ .name = "a" });
	meshes.add({ .name = "b" });

	meshes.clear_retaining_capacity();
	test::eq(meshes.count(), 0);
	test::eq(meshes.slot_count(), 2);
	test::@check(meshes.get(a) == null);

	// The slots come back in order, but with their generations moved on, so
	// no handle from before the clear resolves.
	Handle{Mesh} fresh = meshes.add({ .name = "fresh" });
	test::eq(fresh.index, a.index);
	test::@check(!a.equals(fresh));
	test::eq(meshes.get(fresh).name, "fresh");
}

fn void test_iterating_hands_back_handles_that_work() @test
{
	Table{Mesh} meshes;
	meshes.init(mem);
	defer meshes.free();

	Handle{Mesh} a = meshes.add({ .name = "a" });
	Handle{Mesh} b = meshes.add({ .name = "b" });
	Handle{Mesh} c = meshes.add({ .name = "c" });
	meshes.remove(b);

	sz seen = 0;
	Iterator{Mesh} it = meshes.iterator();
	while (try entry = it.next())
	{
		seen++;
		// The handle the iterator gives back is the one that was handed out.
		test::@check(entry.handle.equals(seen == 1 ? a : c));
		test::@check(entry.value == meshes.get(entry.handle));
		entry.value.triangles = 9;
	}
	test::eq(seen, 2);
	test::eq(meshes.get(a).triangles, 9U);
	test::eq(meshes.get(c).triangles, 9U);
}

fn void test_handles_that_were_never_handed_out() @test
{
	Table{Mesh} meshes;
	meshes.init(mem);
	defer meshes.free();

	Handle{Mesh} real = meshes.add({ .name = "real" });
	Handle{Mesh} none;

	test::@check(meshes.get(none) == null);
	test::@check(meshes.get({ .index = 99, .generation = 1 }) == null);
	test::@check(meshes.get({ .index = real.index, .generation = 99 }) == null);
	test::@error(meshes.remove(none), handle::STALE_HANDLE);
	test::@check(meshes.contains(real));
}

fn void test_generations_wrap_past_zero_rather_than_onto_it() @test
{
	Table{Mesh} meshes;
	meshes.init(mem);
	defer meshes.free();

	Handle{Mesh} h = meshes.add({ .name = "a" });
	// Start one removal short of the wrap.
	meshes.slots[0].generation = uint::max;
	h.generation = uint::max;

	meshes.remove(h);
	Handle{Mesh} after = meshes.add({ .name = "b" });
	test::eq(after.generation, 1U);
	test::@check(!after.is_none());
	test::eq(meshes.get(after).name, "b");
}

fn void test_a_table_of_handles_into_another_table() @test
{
	Table{Mesh} meshes;
	meshes.init(mem);
	defer meshes.free();
	Table{Instance} instances;
	instances.init(mem);
	defer instances.free();

	Handle{Mesh} hull = meshes.add({ .name = "hull" });
	Handle{Instance} one = instances.add({ .mesh = hull, .scale = 1 });
	Handle{Instance} two = instances.add({ .mesh = hull, .scale = 2 });

	test::eq(meshes.get(instances.get(one).mesh).name, "hull");

	// The mesh goes. Both instances still exist, and both now know that what
	// they pointed at does not.
	meshes.remove(hull);
	test::@check(meshes.get(instances.get(one).mesh) == null);
	test::@check(meshes.get(instances.get(two).mesh) == null);
	test::eq(instances.count(), 2);
}
