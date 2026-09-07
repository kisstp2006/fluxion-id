// SPDX-License-Identifier: CC0-1.0

//! A tour of Fluxion Id. Run it with `zig build example`.
//!
//! It names the same handful of imaginary assets three ways over: by uuid,
//! which the build writes into files; by type id, which the log and the URL
//! show; and by handle, which is how they refer to each other while the
//! program is running.

const std = @import("std");
const Io = std.Io;
const ids = @import("fluxion_id");

/// A mesh, as it exists once it has been loaded.
const Mesh = struct {
    /// What it is called everywhere outside this process.
    id: ids.TypeId,
    name: []const u8,
    triangles: u32,
};

/// One placed copy of a mesh. It refers to the mesh by handle, so the mesh
/// table can grow, shrink and be reordered underneath it.
const Instance = struct {
    mesh: ids.Handle(Mesh),
    label: []const u8,
};

/// The kinds of id this program deals in. Naming them once means a typo is a
/// compile error and a mismatched id is a parse error.
const MeshId = ids.Kind("mesh");
const TextureId = ids.Kind("texture");

/// Minted once with `random`, then written down. Every derived id hangs off
/// it, so a project can change its mind about paths without colliding with
/// anybody else's ids.
const project = ids.Uuid.parseComptime("2f8a1c40-6d3e-4b17-9f22-c1a5e7b90d34");

pub fn main(init: std.process.Init) !void {
    const gpa = init.arena.allocator();

    var stdout_buffer: [4096]u8 = undefined;
    var stdout: Io.File.Writer = .init(.stdout(), init.io, &stdout_buffer);
    const out = &stdout.interface;

    // Ids that leave the process want the generator the operating system
    // seeds, which in Zig 0.16 is reached through `Io`.
    var entropy: std.Random.IoSource = .{ .io = init.io };
    const rng = entropy.interface();
    const now = ids.unixMillis(init.io);

    // --- one thing, named four ways ---------------------------------------
    try out.print(
        \\--- a uuid is a name nobody had to agree on ---
        \\random    {f}  version 4, chance and nothing else
        \\sortable  {f}  version 7, the time and then chance
        \\fromName  {f}  version 5, "models/hull.glb" under the project id
        \\nil       {f}  what an uninitialised id looks like
        \\
    , .{
        ids.random(rng),
        ids.sortable(rng, now),
        ids.Uuid.fromName(project, "models/hull.glb"),
        ids.Uuid.nil,
    });

    // The name-based one is the same every run, on every machine, with
    // nothing written down between them.
    const hull_uuid = ids.Uuid.fromName(project, "models/hull.glb");
    try out.print("\nthe same path again -> {f}  {s}\n", .{
        ids.Uuid.fromName(project, "models/hull.glb"),
        if (hull_uuid.eql(ids.Uuid.fromName(project, "models/hull.glb"))) "same" else "DIFFERENT",
    });
    try out.print("one character of the path changed -> {f}\n", .{
        ids.Uuid.fromName(project, "models/hulls.glb"),
    });

    // --- ids that sort ----------------------------------------------------
    // Six ids inside the same millisecond. A bare `sortable` would let chance
    // order them; a `Clock` counts, so they come out in the order they were
    // asked for.
    try out.writeAll("\n--- six ids in one millisecond ---\n");
    var clock: ids.Uuid.Clock = .init;
    var previous: ?ids.Uuid = null;
    var ascending = true;
    for (0..6) |_| {
        const id = clock.next(rng, now);
        if (previous) |before| ascending = ascending and before.lessThan(id);
        previous = id;
        try out.print("{f}\n", .{id});
    }
    try out.print("ascending: {}\n", .{ascending});
    try out.print("and each one still says when it was made: {d} ms\n", .{
        previous.?.timestamp().?,
    });

    // --- the same id, with its type in front ------------------------------
    try out.writeAll("\n--- a type id says what it points at ---\n");

    var buf: [ids.TypeId.max_string_len]u8 = undefined;
    const hull_id = MeshId.of(hull_uuid);
    try out.print(
        \\uuid      {f}
        \\type id   {s}
        \\prefix    {s}
        \\suffix    {s}  the same 128 bits, in Crockford base32
        \\
    , .{
        hull_id.uuid,
        hull_id.toString(&buf),
        hull_id.prefix(),
        &hull_id.suffix(),
    });

    // Which means an id from the wrong column is caught where it arrives,
    // rather than becoming a lookup that finds nothing.
    const text = hull_id.toString(&buf);
    if (TextureId.parse(text)) |_| {
        try out.writeAll("\nread back as a texture id\n");
    } else |err| {
        try out.print("\nread back as a texture id -> error.{t}\n", .{err});
    }
    try out.print("read back as a mesh id    -> {f}\n", .{try MeshId.parse(text)});

    // --- handles ----------------------------------------------------------
    try out.writeAll("\n--- and a handle, for the run it is loaded in ---\n");

    var meshes: ids.Table(Mesh) = .empty;
    defer meshes.deinit(gpa);
    var instances: ids.Table(Instance) = .empty;
    defer instances.deinit(gpa);

    const hull = try meshes.add(gpa, .{ .id = hull_id, .name = "hull", .triangles = 1200 });
    const wing = try meshes.add(gpa, .{
        .id = MeshId.sortable(rng, now),
        .name = "wing",
        .triangles = 300,
    });
    _ = try instances.add(gpa, .{ .mesh = hull, .label = "hull.left" });
    const right = try instances.add(gpa, .{ .mesh = hull, .label = "hull.right" });
    _ = try instances.add(gpa, .{ .mesh = wing, .label = "wing.left" });

    var it = instances.iterator();
    while (it.next()) |entry| {
        const mesh = meshes.get(entry.value.mesh).?;
        try out.print("{f} {s:<12} -> {f}  {s:<8} {d:>5} triangles\n", .{
            entry.handle,
            entry.value.label,
            entry.value.mesh,
            mesh.name,
            mesh.triangles,
        });
    }

    // The wing is unloaded. Its slot goes back on the free chain, and the
    // instance that pointed at it now resolves to nothing instead of to
    // whatever moves in next.
    try out.writeAll("\nthe wing mesh is unloaded, and a cockpit is loaded into its slot\n");
    _ = meshes.remove(wing);
    const cockpit = try meshes.add(gpa, .{
        .id = MeshId.sortable(rng, now),
        .name = "cockpit",
        .triangles = 800,
    });

    try out.print(
        \\old handle  {f}   resolves to {s}
        \\new handle  {f}   resolves to {s}   same slot, next generation
        \\
    , .{
        wing,
        if (meshes.get(wing)) |m| m.name else "nothing",
        cockpit,
        if (meshes.get(cockpit)) |m| m.name else "nothing",
    });

    it = instances.iterator();
    while (it.next()) |entry| {
        try out.print("{s:<12} -> {s}\n", .{
            entry.value.label,
            if (meshes.get(entry.value.mesh)) |m| m.name else "(unloaded)",
        });
    }

    // A handle is a value, so taking one out of the table is not the same as
    // taking the thing out of the world.
    _ = instances.remove(right);
    try out.print("\n{d} instances left, over {d} mesh slots\n", .{
        instances.count(),
        meshes.slotCount(),
    });

    // --- what each one costs ----------------------------------------------
    try out.print(
        \\
        \\--- three names for one thing ---
        \\Uuid     {d:>2} bytes, {d} characters   the same name next year, anywhere
        \\TypeId   {d:>2} bytes, {d} characters   the same name, and legible
        \\Handle   {d:>2} bytes                  valid in this table, this run
        \\
    , .{
        @sizeOf(ids.Uuid),
        ids.Uuid.string_len,
        @sizeOf(ids.TypeId),
        hull_id.stringLen(),
        @sizeOf(ids.Handle(Mesh)),
    });

    try out.flush();
}
