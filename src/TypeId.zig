// SPDX-License-Identifier: CC0-1.0

//! A `Uuid` with the type of the thing written in front of it.
//!
//! A bare UUID in a log line, a URL bar or a bug report says nothing about
//! what it points at, and an id pasted from the wrong column looks exactly
//! like a right one. A type id says both:
//!
//!   user_01h455vb4pex5vsknk084sn02q
//!   ^^^^ ^
//!   |    the same 128 bits, in Crockford base32
//!   what they name
//!
//! The layout is the TypeID specification: a prefix of up to 63 characters
//! from `a`-`z` and `_`, an underscore, and 26 base32 digits holding a
//! `Uuid`. An empty prefix is allowed, and then the underscore goes too.
//!
//! Three things fall out of that shape:
//!
//!   * A wrong id is caught by eye, and by `Kind`, instead of turning into a
//!     lookup that quietly finds nothing.
//!   * The digits ascend with the alphabet and a version 7 `Uuid` starts with
//!     its timestamp, so sorting the text sorts by when the ids were made.
//!   * The text survives a URL, a shell, a filename and being read aloud,
//!     which base64 and the dashed UUID form do not.
//!
//! It is a value, prefix and all: 80 bytes with nothing to allocate and
//! nothing to free. The unused tail of the prefix is always zeroed, so two
//! ids holding the same text are identical byte-for-byte and a `TypeId` works
//! directly as a `std.AutoHashMap` key.

const std = @import("std");
const testing = std.testing;

const base32 = @import("base32.zig");
const Uuid = @import("Uuid.zig");

const TypeId = @This();

/// The prefix, padded with zeroes. Read it with `prefix`.
prefix_bytes: [max_prefix_len]u8,
prefix_len: u8,

/// The 128 bits the id actually names. The specification calls for a version
/// 7 `Uuid` - see `Kind.sortable` - but any id round-trips, because a store
/// full of version 4 ids is not a reason to be unable to print them.
uuid: Uuid,

/// As long a prefix as the specification allows.
pub const max_prefix_len: usize = 63;

/// How many base32 digits sixteen bytes take.
pub const suffix_len: usize = base32.encoded_len;

/// The longest text form: prefix, underscore, suffix.
pub const max_string_len: usize = max_prefix_len + 1 + suffix_len;

pub const PrefixError = error{
    /// More than 63 characters.
    PrefixTooLong,
    /// Something other than `a`-`z` and `_`, or an underscore at either end.
    /// Uppercase and digits are not allowed, so an id has one spelling.
    InvalidPrefix,
};

pub const ParseError = PrefixError || error{
    /// The part after the last underscore was not 26 characters from
    /// Crockford's alphabet.
    InvalidSuffix,
    /// Twenty-six valid digits that name more than 128 bits, which is any
    /// suffix starting above `7`.
    SuffixOverflow,
};

// -------------------------------------------------------------------------
// Making one
// -------------------------------------------------------------------------

/// Bind `prefix_text` to `uuid`.
///
/// The uuid is usually made on the spot, which decl literals keep short:
///
/// ```zig
/// const id = try TypeId.init("user", .sortable(rng, now));
/// ```
pub fn init(prefix_text: []const u8, uuid: Uuid) PrefixError!TypeId {
    try checkPrefix(prefix_text);
    return initUnchecked(prefix_text, uuid);
}

/// For a prefix already known to be good, which is every prefix that came
/// from `checkPrefix` or out of a `TypeId`.
fn initUnchecked(prefix_text: []const u8, uuid: Uuid) TypeId {
    var self: TypeId = .{
        .prefix_bytes = @splat(0),
        .prefix_len = @intCast(prefix_text.len),
        .uuid = uuid,
    };
    @memcpy(self.prefix_bytes[0..prefix_text.len], prefix_text);
    return self;
}

/// What the specification allows: `a`-`z` and `_`, at most 63 of them, and
/// not an underscore at either end. Empty is allowed and means an id with no
/// prefix and no underscore.
fn checkPrefix(text: []const u8) PrefixError!void {
    if (text.len > max_prefix_len) return error.PrefixTooLong;
    if (text.len == 0) return;
    if (text[0] == '_' or text[text.len - 1] == '_') return error.InvalidPrefix;
    for (text) |c| switch (c) {
        'a'...'z', '_' => {},
        else => return error.InvalidPrefix,
    };
}

/// One kind of id, with its prefix fixed at compile time.
///
/// ```zig
/// const User = TypeId.Kind("user");
/// const Order = TypeId.Kind("order");
///
/// const alice = User.sortable(rng, now);
/// const cart = try Order.parse(text);   // error.WrongPrefix if it is a user
/// ```
///
/// A misspelled prefix is a compile error rather than a runtime one, and
/// `parse` refuses an id of the wrong kind rather than handing back something
/// that will fail its lookup later.
///
/// What this does not do is make `User` and `Order` different Zig types: both
/// produce a `TypeId`, and the check happens where the text comes in.
/// `handle.Handle` is the identifier here that the compiler tells apart.
pub fn Kind(comptime prefix_text: []const u8) type {
    comptime {
        checkPrefix(prefix_text) catch
            @compileError("fluxion-id: not a type id prefix: " ++ prefix_text);
    }
    const Error = ParseError || error{
        /// A well-formed id, of some other kind.
        WrongPrefix,
    };

    return struct {
        pub const prefix = prefix_text;
        pub const ParseError = Error;

        /// A fresh time-ordered id, which is what the specification asks for.
        pub fn sortable(rng: std.Random, unix_ms: i64) TypeId {
            return initUnchecked(prefix_text, Uuid.sortable(rng, unix_ms));
        }

        /// This kind's prefix over a uuid from somewhere else.
        pub fn of(uuid: Uuid) TypeId {
            return initUnchecked(prefix_text, uuid);
        }

        /// Parse, and insist the id is one of these.
        pub fn parse(text: []const u8) Error!TypeId {
            const id = try TypeId.parse(text);
            if (!id.hasPrefix(prefix_text)) return error.WrongPrefix;
            return id;
        }

        /// Whether an id already in hand is one of these.
        pub fn matches(id: TypeId) bool {
            return id.hasPrefix(prefix_text);
        }
    };
}

// -------------------------------------------------------------------------
// Text
// -------------------------------------------------------------------------

/// Read the text form.
///
/// The split is at the *last* underscore, because a prefix may contain
/// underscores and a suffix may not: `db_user_01h4...` is a `db_user`.
/// Everything else is exact - one case, one alphabet, one length - so an id
/// has a single spelling and two ids that print the same are the same.
pub fn parse(text: []const u8) ParseError!TypeId {
    const cut = std.mem.lastIndexOfScalar(u8, text, '_');
    const prefix_text = if (cut) |i| text[0..i] else "";
    const suffix_text = if (cut) |i| text[i + 1 ..] else text;

    // A leading underscore is a stray underscore, not an empty prefix.
    if (cut != null and prefix_text.len == 0) return error.InvalidPrefix;
    try checkPrefix(prefix_text);

    if (suffix_text.len != suffix_len) return error.InvalidSuffix;
    const bytes = base32.decode(suffix_text[0..suffix_len]) catch |err| switch (err) {
        error.InvalidCharacter => return error.InvalidSuffix,
        error.Overflow => return error.SuffixOverflow,
    };
    return initUnchecked(prefix_text, .fromBytes(bytes));
}

/// Parse at compile time, so a malformed literal is a compile error rather
/// than something to handle at runtime.
pub fn parseComptime(comptime text: []const u8) TypeId {
    const parsed = comptime blk: {
        break :blk parse(text) catch
            @compileError("fluxion-id: not a type id: " ++ text);
    };
    return parsed;
}

/// The prefix, without the underscore. Empty for an id that has none.
///
/// Takes a pointer because the bytes live inside the value: a slice of a
/// temporary would dangle.
pub fn prefix(self: *const TypeId) []const u8 {
    return self.prefix_bytes[0..self.prefix_len];
}

pub fn hasPrefix(self: *const TypeId, text: []const u8) bool {
    return std.mem.eql(u8, self.prefix(), text);
}

/// The 26 digits after the underscore, held by value.
pub fn suffix(self: TypeId) [suffix_len]u8 {
    return base32.encode(self.uuid.bytes);
}

/// How many bytes `toString` will write.
pub fn stringLen(self: TypeId) usize {
    return if (self.prefix_len == 0) suffix_len else self.prefix_len + 1 + suffix_len;
}

/// Write the text form into `buf`, and return the part of it that was used.
///
/// A caller's buffer rather than a returned array, because the length varies
/// with the prefix: an array would be mostly padding, and a slice of one
/// returned by value would point at a temporary. `{f}` covers the common case
/// of printing an id without wanting the bytes.
pub fn toString(self: *const TypeId, buf: *[max_string_len]u8) []u8 {
    const prefix_text = self.prefix();
    @memcpy(buf[0..prefix_text.len], prefix_text);

    var used = prefix_text.len;
    if (used != 0) {
        buf[used] = '_';
        used += 1;
    }
    @memcpy(buf[used..][0..suffix_len], &self.suffix());
    return buf[0 .. used + suffix_len];
}

/// Print with `{f}`.
pub fn format(self: TypeId, w: *std.Io.Writer) std.Io.Writer.Error!void {
    if (self.prefix_len != 0) {
        try w.writeAll(self.prefix());
        try w.writeByte('_');
    }
    try w.writeAll(&self.suffix());
}

// -------------------------------------------------------------------------
// Reading one
// -------------------------------------------------------------------------

/// When the id was made, for the version 7 uuid the specification asks for.
/// Null for any other version. See `Uuid.timestamp`.
pub fn timestamp(self: TypeId) ?i64 {
    return self.uuid.timestamp();
}

pub fn eql(self: TypeId, other: TypeId) bool {
    return self.uuid.eql(other.uuid) and self.hasPrefix(other.prefix());
}

/// Prefix first, then the uuid - which is exactly the order the text forms
/// sort in, because `_` comes before every letter a prefix may hold. So ids
/// group by kind, and inside a kind they are in the order they were made.
pub fn order(self: TypeId, other: TypeId) std.math.Order {
    return switch (std.mem.order(u8, self.prefix(), other.prefix())) {
        .eq => self.uuid.order(other.uuid),
        else => |result| result,
    };
}

pub fn lessThan(self: TypeId, other: TypeId) bool {
    return self.order(other) == .lt;
}

pub fn hash(self: *const TypeId) u64 {
    var hasher: std.hash.Wyhash = .init(0);
    hasher.update(self.prefix());
    hasher.update(&self.uuid.bytes);
    return hasher.final();
}

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

/// The example from the TypeID specification.
const sample_text = "prefix_01h455vb4pex5vsknk084sn02q";
const sample_uuid = "01890a5d-ac96-774b-bcce-b302099a8057";

fn expectPrints(expected: []const u8, id: TypeId) !void {
    var buf: [max_string_len]u8 = undefined;
    try testing.expectEqualStrings(expected, id.toString(&buf));
    try testing.expectFmt(expected, "{f}", .{id});
    try testing.expectEqual(expected.len, id.stringLen());
}

test "the specification's own example" {
    const id = try parse(sample_text);
    try testing.expectEqualStrings("prefix", id.prefix());
    try testing.expectEqualStrings(sample_uuid, &id.uuid.toString());
    try expectPrints(sample_text, id);

    // And the other way round.
    const built = try init("prefix", .parseComptime(sample_uuid));
    try testing.expect(built.eql(id));
    try expectPrints(sample_text, built);
}

test "an id with no prefix has no underscore either" {
    const id = try init("", .nil);
    try expectPrints("00000000000000000000000000", id);
    try testing.expectEqualStrings("", id.prefix());

    const read_back = try parse("00000000000000000000000000");
    try testing.expect(read_back.eql(id));
    try testing.expect(read_back.uuid.isNil());
}

test "prefixes may contain underscores, and the split is at the last one" {
    const id = try parse("db_user_01h455vb4pex5vsknk084sn02q");
    try testing.expectEqualStrings("db_user", id.prefix());
    try testing.expectEqualStrings(sample_uuid, &id.uuid.toString());
    try expectPrints("db_user_01h455vb4pex5vsknk084sn02q", id);

    const long = "a" ** max_prefix_len;
    try expectPrints(long ++ "_00000000000000000000000000", try init(long, .nil));
}

test "bad prefixes" {
    try testing.expectError(error.PrefixTooLong, init("a" ** (max_prefix_len + 1), .nil));
    try testing.expectError(error.InvalidPrefix, init("_user", .nil));
    try testing.expectError(error.InvalidPrefix, init("user_", .nil));
    try testing.expectError(error.InvalidPrefix, init("User", .nil));
    try testing.expectError(error.InvalidPrefix, init("user2", .nil));
    try testing.expectError(error.InvalidPrefix, init("user-name", .nil));
    try testing.expectError(error.InvalidPrefix, init("user name", .nil));

    // The same rules on the way in from text.
    try testing.expectError(error.InvalidPrefix, parse("_01h455vb4pex5vsknk084sn02q"));
    try testing.expectError(error.InvalidPrefix, parse("User_01h455vb4pex5vsknk084sn02q"));
    try testing.expectError(
        error.PrefixTooLong,
        parse("a" ** (max_prefix_len + 1) ++ "_01h455vb4pex5vsknk084sn02q"),
    );
}

test "bad suffixes" {
    try testing.expectError(error.InvalidSuffix, parse(""));
    try testing.expectError(error.InvalidSuffix, parse("user_"));
    try testing.expectError(error.InvalidSuffix, parse("user_01h455vb4pex5vsknk084sn02"));
    try testing.expectError(error.InvalidSuffix, parse("user_01h455vb4pex5vsknk084sn02qq"));
    // `i`, `l`, `o` and `u` are not digits, and neither is uppercase.
    try testing.expectError(error.InvalidSuffix, parse("user_01h455vb4pex5vsknk084sn02i"));
    try testing.expectError(error.InvalidSuffix, parse("user_01H455VB4PEX5VSKNK084SN02Q"));
    // Twenty-six good digits naming more than 128 bits.
    try testing.expectError(error.SuffixOverflow, parse("user_8zzzzzzzzzzzzzzzzzzzzzzzzz"));
}

test "round trip, over ids that are not all zeroes" {
    var prng: std.Random.DefaultPrng = .init(0x71D);
    const rng = prng.random();
    var buf: [max_string_len]u8 = undefined;

    for (0..1000) |step| {
        const id = try init("asset", .sortable(rng, 1_700_000_000_000 + @as(i64, @intCast(step))));
        const printed = id.toString(&buf);
        const read_back = try parse(printed);
        try testing.expect(read_back.eql(id));
        try testing.expect(std.meta.eql(read_back, id));
        try testing.expectEqual(id.timestamp(), read_back.timestamp());
    }
}

test "sorting the values is sorting the text" {
    var prng: std.Random.DefaultPrng = .init(0x5027);
    const rng = prng.random();

    const prefixes = [_][]const u8{ "", "a", "a_b", "ab", "user", "user_role", "z" };
    var ids: [prefixes.len * 4]TypeId = undefined;
    var at: usize = 0;
    for (prefixes) |prefix_text| {
        for (0..4) |step| {
            ids[at] = try init(prefix_text, .sortable(rng, 1_700_000_000_000 + @as(i64, @intCast(step))));
            at += 1;
        }
    }

    std.mem.sort(TypeId, &ids, {}, struct {
        fn lt(_: void, x: TypeId, y: TypeId) bool {
            return x.lessThan(y);
        }
    }.lt);

    // Printed in order, the strings are in order too - so a database that
    // sorts these as text agrees with one that sorts them as values.
    var previous: [max_string_len]u8 = undefined;
    var previous_len: usize = 0;
    for (ids) |id| {
        var buf: [max_string_len]u8 = undefined;
        const text = id.toString(&buf);
        try testing.expect(!std.mem.lessThan(u8, text, previous[0..previous_len]));
        @memcpy(previous[0..text.len], text);
        previous_len = text.len;
    }

    // The empty prefix sorts first, and within one kind the ids are in the
    // order they were made.
    try testing.expectEqualStrings("", ids[0].prefix());
    try testing.expect(ids[0].lessThan(ids[1]));
}

test "Kind fixes the prefix and refuses the others" {
    const User = Kind("user");
    const Order = Kind("order");

    var prng: std.Random.DefaultPrng = .init(0x11D);
    const rng = prng.random();

    const alice = User.sortable(rng, 1_700_000_000_000);
    try testing.expectEqualStrings("user", alice.prefix());
    try testing.expectEqual(@as(u4, 7), alice.uuid.version());
    try testing.expect(User.matches(alice));
    try testing.expect(!Order.matches(alice));

    var buf: [max_string_len]u8 = undefined;
    const text = alice.toString(&buf);
    try testing.expect((try User.parse(text)).eql(alice));
    try testing.expectError(error.WrongPrefix, Order.parse(text));

    // A malformed id is still malformed, whichever kind was expected.
    try testing.expectError(error.InvalidSuffix, User.parse("user_nope"));

    // And `of` puts this kind's prefix on an id from somewhere else.
    const imported = Order.of(.parseComptime(sample_uuid));
    try expectPrints("order_01h455vb4pex5vsknk084sn02q", imported);
}

test "parsed at compile time" {
    const id = parseComptime(sample_text);
    try testing.expectEqualStrings("prefix", id.prefix());
    try testing.expect(id.eql(try parse(sample_text)));
}

test "works as a value and as a map key" {
    var map: std.AutoHashMapUnmanaged(TypeId, u32) = .empty;
    defer map.deinit(testing.allocator);

    const id = try parse(sample_text);
    try map.put(testing.allocator, id, 7);
    try testing.expectEqual(@as(?u32, 7), map.get(try parse(sample_text)));

    // The padding is always zeroed, so equal ids are equal bytes - which is
    // what lets `AutoHashMap` hash the struct without help.
    try testing.expect(std.meta.eql(id, try init("prefix", .parseComptime(sample_uuid))));
    try testing.expectEqual(id.hash(), (try parse(sample_text)).hash());

    // A different kind of the same uuid is a different id.
    const other = try init("prefixx", .parseComptime(sample_uuid));
    try testing.expect(!other.eql(id));
    try testing.expect(other.hash() != id.hash());
    try testing.expect(map.get(other) == null);
}
