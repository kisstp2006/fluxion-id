// SPDX-License-Identifier: CC0-1.0

// A tour of Fluxion Id. Run it with `c3c run demo`.
//
// It names the same handful of imaginary assets three ways over: by uuid,
// which the build writes into files; by type id, which the log and the URL
// show; and by handle, which is how they refer to each other while the
// program is running.
module demo;
import std::io;
import std::math::random;
import fluxion::id;

// A mesh, as it exists once it has been loaded.
struct Mesh
{
	// What it is called everywhere outside this process.
	TypeId id;
	String name;
	uint triangles;
}

// One placed copy of a mesh. It refers to the mesh by handle, so the mesh
// table can grow, shrink and be reordered underneath it.
struct Instance
{
	Handle{Mesh} mesh;
	String label;
}

// The kinds of id this program deals in. Naming them once means a typo is a
// compile error and a mismatched id is a parse error.
const Kind MESH_ID = type_id::@kind("mesh");
const Kind TEXTURE_ID = type_id::@kind("texture");

// Minted once with `random`, then written down. Every derived id hangs off
// it, so a project can change its mind about paths without colliding with
// anybody else's ids.
const Uuid PROJECT = uuid::@parse("2f8a1c40-6d3e-4b17-9f22-c1a5e7b90d34");

fn void main()
{
	// Ids that leave the process want a generator seeded from the operating
	// system's entropy, which `seed_entropy` does.
	Sfc64Random prng;
	random::seed_entropy(&prng);
	long now = id::unix_millis();

	// --- one thing, named four ways ---------------------------------------
	io::printn("--- a uuid is a name nobody had to agree on ---");
	io::printfn("random    %s  version 4, chance and nothing else", id::random(&prng));
	io::printfn("sortable  %s  version 7, the time and then chance", id::sortable(&prng, now));
	io::printfn("fromName  %s  version 5, \"models/hull.glb\" under the project id",
		uuid::from_name(PROJECT, "models/hull.glb"));
	io::printfn("nil       %s  what an uninitialised id looks like", uuid::NIL);

	// The name-based one is the same every run, on every machine, with
	// nothing written down between them.
	Uuid hull_uuid = uuid::from_name(PROJECT, "models/hull.glb");
	io::printfn("\nthe same path again -> %s  %s", uuid::from_name(PROJECT, "models/hull.glb"),
		hull_uuid.equals(uuid::from_name(PROJECT, "models/hull.glb")) ? "same" : "DIFFERENT");
	io::printfn("one character of the path changed -> %s", uuid::from_name(PROJECT, "models/hulls.glb"));

	// --- ids that sort ----------------------------------------------------
	// Six ids inside the same millisecond. A bare `sortable` would let chance
	// order them; a `Clock` counts, so they come out in the order they were
	// asked for.
	io::printn("\n--- six ids in one millisecond ---");
	Clock clock;
	clock.init();
	Uuid previous;
	bool ascending = true;
	for (int i = 0; i < 6; i++)
	{
		Uuid id = clock.next(&prng, now);
		if (i > 0) ascending = ascending && previous.less(id);
		previous = id;
		io::printfn("%s", id);
	}
	io::printfn("ascending: %s", ascending);
	io::printfn("and each one still says when it was made: %d ms", previous.timestamp()!!);

	// --- the same id, with its type in front ------------------------------
	io::printn("\n--- a type id says what it points at ---");

	char[type_id::MAX_STRING_LEN] buf;
	TypeId hull_id = MESH_ID.of(hull_uuid);
	char[type_id::SUFFIX_LEN] suffix = hull_id.suffix();
	io::printfn("uuid      %s", hull_id.uuid);
	io::printfn("type id   %s", hull_id.to_string(&buf));
	io::printfn("prefix    %s", hull_id.prefix());
	io::printfn("suffix    %s  the same 128 bits, in Crockford base32", (String)suffix[..]);

	// Which means an id from the wrong column is caught where it arrives,
	// rather than becoming a lookup that finds nothing.
	String text = hull_id.to_string(&buf);
	if (catch err = TEXTURE_ID.parse(text))
	{
		io::printfn("\nread back as a texture id -> %s", err);
	}
	else
	{
		io::printn("\nread back as a texture id");
	}
	io::printfn("read back as a mesh id    -> %s", MESH_ID.parse(text)!!);

	// --- handles ----------------------------------------------------------
	io::printn("\n--- and a handle, for the run it is loaded in ---");

	Table{Mesh} meshes;
	meshes.init(mem);
	defer meshes.free();
	Table{Instance} instances;
	instances.init(mem);
	defer instances.free();

	Handle{Mesh} hull = meshes.add({ .id = hull_id, .name = "hull", .triangles = 1200 });
	Handle{Mesh} wing = meshes.add({ .id = MESH_ID.sortable(&prng, now), .name = "wing", .triangles = 300 });
	instances.add({ .mesh = hull, .label = "hull.left" });
	Handle{Instance} right = instances.add({ .mesh = hull, .label = "hull.right" });
	instances.add({ .mesh = wing, .label = "wing.left" });

	Iterator{Instance} it = instances.iterator();
	while (try entry = it.next())
	{
		Mesh* mesh = meshes.get(entry.value.mesh);
		io::printfn("%s %-12s -> %s  %-8s %5d triangles",
			entry.handle, entry.value.label, entry.value.mesh, mesh.name, mesh.triangles);
	}

	// The wing is unloaded. Its slot goes back on the free chain, and the
	// instance that pointed at it now resolves to nothing instead of to
	// whatever moves in next.
	io::printn("\nthe wing mesh is unloaded, and a cockpit is loaded into its slot");
	meshes.remove(wing);
	Handle{Mesh} cockpit = meshes.add({ .id = MESH_ID.sortable(&prng, now), .name = "cockpit", .triangles = 800 });

	io::printfn("old handle  %s   resolves to %s", wing, name_of(meshes.get(wing), "nothing"));
	io::printfn("new handle  %s   resolves to %s   same slot, next generation", cockpit, name_of(meshes.get(cockpit), "nothing"));

	it = instances.iterator();
	while (try entry = it.next())
	{
		io::printfn("%-12s -> %s", entry.value.label, name_of(meshes.get(entry.value.mesh), "(unloaded)"));
	}

	// A handle is a value, so taking one out of the table is not the same as
	// taking the thing out of the world.
	instances.remove(right);
	io::printfn("\n%d instances left, over %d mesh slots", instances.count(), meshes.slot_count());

	// --- what each one costs ----------------------------------------------
	io::printn("\n--- three names for one thing ---");
	io::printfn("Uuid     %2d bytes, %d characters   the same name next year, anywhere", Uuid::size, uuid::STRING_LEN);
	io::printfn("TypeId   %2d bytes, %d characters   the same name, and legible", TypeId::size, hull_id.string_len());
	io::printfn("Handle   %2d bytes                  valid in this table, this run", Handle{Mesh}::size);
}

// A null pointer has no name; say so instead of dereferencing it.
fn String name_of(Mesh* mesh, String otherwise)
{
	return mesh == null ? otherwise : mesh.name;
}
