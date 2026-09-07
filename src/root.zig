// SPDX-License-Identifier: CC0-1.0

//! Fluxion Id - three ways to name a thing, at three scales.
//!
//! Three pieces:
//!
//!   `Uuid`     128 bits, unique everywhere, minted without asking anyone
//!   `TypeId`   the same 128 bits with the type in front, as one sortable
//!              string a person can read back
//!   `handle`   64 bits, unique inside one table, and free to mint
//!
//! They are the same idea at different prices. A `Uuid` costs sixteen bytes
//! and a random number generator, and in exchange it is still the right name
//! next year, on another machine, in a file nobody has opened yet. A `TypeId`
//! adds a few characters and says what the id is *for*, which is what turns a
//! log line back into something a person can act on. A handle costs eight
//! bytes and a bounds check, and means nothing at all outside the table that
//! issued it - but resolving one is an array index, not a lookup.
//!
//! Most things want more than one. An asset has a `Uuid` in the file it was
//! built from, a `TypeId` in the URL that serves it, and a handle in the
//! array it lives in this run.
//!
//! All three are values, and all three share one shape:
//!
//!   `eql`                  are these the same id
//!   `order` / `lessThan`   sorting, where sorting means something
//!   `format`               print it with `{f}`
//!
//! Nothing here allocates except `handle.Table`, which is the only piece that
//! stores anything. Nothing here is cryptographic: `Uuid.random` is as
//! unguessable as the generator handed to it and no more, and `Uuid.fromName`
//! is deliberately reproducible by anyone who knows the namespace.

const std = @import("std");
const testing = std.testing;

/// A 128-bit identifier. See `Uuid`.
pub const Uuid = @import("Uuid.zig");

/// A `Uuid` with its type written in front. See `TypeId`.
pub const TypeId = @import("TypeId.zig");

pub const handle = @import("handle.zig");

/// A handle to a `T`, in a `Table(T)`. See `handle`.
pub const Handle = handle.Handle;

/// Storage that hands out handles and answers them. See `handle`.
pub const Table = handle.Table;

/// One kind of `TypeId`, with its prefix fixed at compile time. See `TypeId`.
pub const Kind = TypeId.Kind;

/// Shorthand for `Uuid.random`, so call sites read `ids.random(rng)`.
pub fn random(rng: std.Random) Uuid {
    return .random(rng);
}

/// Shorthand for `Uuid.sortable`: a random id with the time in front of it.
pub fn sortable(rng: std.Random, unix_ms: i64) Uuid {
    return .sortable(rng, unix_ms);
}

/// Shorthand for `Uuid.parse`.
pub fn parse(text: []const u8) Uuid.ParseError!Uuid {
    return .parse(text);
}

/// The wall clock in the units `sortable` wants.
///
/// Reading the clock in Zig 0.16 goes through `Io`, and this is the whole of
/// it - written down here so that a caller who just wants an id now does not
/// have to go and find out how:
///
/// ```zig
/// const id = ids.sortable(rng, ids.unixMillis(io));
/// ```
pub fn unixMillis(io: std.Io) i64 {
    return std.Io.Clock.real.now(io).toMilliseconds();
}

test {
    // Pull each module in so `zig build test` runs its tests too.
    _ = Uuid;
    _ = TypeId;
    _ = handle;
    _ = @import("base32.zig");
}

test "the pieces compose" {
    // One asset, named three ways at once: by the id its source file carries,
    // by the text a person sees, and by the slot it lives in this run.
    const Asset = struct {
        id: TypeId,
        name: []const u8,
    };
    const Mesh = TypeId.Kind("mesh");

    var prng: std.Random.DefaultPrng = .init(0xA55E7);
    const rng = prng.random();
    const built_at: i64 = 1_700_000_000_000;

    var assets: Table(Asset) = .empty;
    defer assets.deinit(testing.allocator);

    // The source file's id is derived from its path, so a rebuild that
    // touches nothing else produces the same id again.
    const project = Uuid.parseComptime("2f8a1c40-6d3e-4b17-9f22-c1a5e7b90d34");
    const hull_uuid = Uuid.fromName(project, "models/hull.glb");
    try testing.expect(hull_uuid.eql(Uuid.fromName(project, "models/hull.glb")));

    const hull = try assets.add(testing.allocator, .{
        .id = Mesh.of(hull_uuid),
        .name = "hull",
    });
    const wing = try assets.add(testing.allocator, .{
        .id = Mesh.sortable(rng, built_at),
        .name = "wing",
    });

    // The handle resolves to the asset, and the asset's text form parses back
    // into the same id.
    var buf: [TypeId.max_string_len]u8 = undefined;
    const printed = assets.get(hull).?.id.toString(&buf);
    try testing.expect((try Mesh.parse(printed)).eql(Mesh.of(hull_uuid)));
    try testing.expectError(error.WrongPrefix, TypeId.Kind("texture").parse(printed));

    // The wing goes. Its uuid and text form are as good as they ever were -
    // they name a thing, not a slot - but the handle stops resolving.
    const removed = assets.remove(wing).?;
    try testing.expect(assets.get(wing) == null);
    try testing.expectEqual(@as(?i64, built_at), removed.id.timestamp());
    try testing.expect(assets.get(hull) != null);

    // And the slot comes back with its generation moved on, so the old handle
    // does not quietly find the new occupant.
    const cockpit = try assets.add(testing.allocator, .{
        .id = Mesh.sortable(rng, built_at + 1),
        .name = "cockpit",
    });
    try testing.expectEqual(wing.index, cockpit.index);
    try testing.expect(assets.get(wing) == null);
    try testing.expectEqualStrings("cockpit", assets.get(cockpit).?.name);

    // Time order survives the round trip through text, which is what makes
    // "the newest first" a sort rather than a query.
    try testing.expect(removed.id.lessThan(assets.get(cockpit).?.id));
}

test "shorthands" {
    var prng: std.Random.DefaultPrng = .init(7);
    const rng = prng.random();

    try testing.expectEqual(@as(u4, 4), random(rng).version());
    try testing.expectEqual(@as(u4, 7), sortable(rng, 1_700_000_000_000).version());
    try testing.expectEqual(
        @as(?i64, 1_700_000_000_000),
        sortable(rng, 1_700_000_000_000).timestamp(),
    );

    const text = "f81d4fae-7dec-11d0-a765-00a0c91e6bf6";
    try testing.expect((try parse(text)).eql(try Uuid.parse(text)));
    try testing.expectError(error.InvalidCharacter, parse("nope"));
    try testing.expectError(error.InvalidLength, parse("f81d4fae"));

    try testing.expect(Handle(u32) == handle.Handle(u32));
    try testing.expect(Table(u32) == handle.Table(u32));
    try testing.expect(Kind("user") == TypeId.Kind("user"));
}
