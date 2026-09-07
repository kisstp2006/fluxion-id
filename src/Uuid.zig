// SPDX-License-Identifier: CC0-1.0

//! A 128-bit name for a thing, in the layout RFC 9562 fixes.
//!
//! Sixteen bytes is enough that two machines that have never spoken can each
//! mint one and be confident they did not collide. That is the whole trick:
//! no server hands these out, no table has to be locked, and a name minted
//! offline on a laptop is as good as one minted in a datacentre. What it
//! costs is sixteen bytes, and thirty-six characters of text that no reader
//! will ever recognise.
//!
//! Four ways to make one, and the choice is about what the id should be
//! correlated with:
//!
//!   `random`    version 4: nothing but chance. The default.
//!   `sortable`  version 7: a timestamp, then chance. Ids made near each
//!               other in time sort near each other, which is what a database
//!               index wants.
//!   `fromName`  version 5: the same id every time for the same namespace and
//!               text, so a path becomes an id with nothing written down.
//!   `fromBytes` sixteen bytes that already mean something elsewhere.
//!
//! The bytes are stored in the order they are written, so a `Uuid` can be
//! memcpy'd into a file and read back on any machine, and byte order is also
//! numeric order and - for `sortable` - the order the ids were made in. It is
//! a value: copy it, compare it with `std.meta.eql`, use it as a
//! `std.AutoHashMap` key.

const std = @import("std");
const testing = std.testing;

const Uuid = @This();

/// Big-endian, as RFC 9562 lays them out: the text form reads straight off.
bytes: [16]u8,

/// All zeroes. What an uninitialised id looks like, and therefore what to
/// check for.
pub const nil: Uuid = .{ .bytes = @splat(0) };

/// All ones. Sorts after everything, which makes it the upper bound of a
/// range query.
pub const max: Uuid = .{ .bytes = @splat(0xFF) };

/// The length of the canonical text form, `8-4-4-4-12`.
pub const string_len: usize = 36;

/// The scheme RFC 9562 registers for the URN form.
pub const urn_prefix = "urn:uuid:";

/// The length of `urn:uuid:` and the canonical form together.
pub const urn_len: usize = urn_prefix.len + string_len;

/// Where the dashes go in the canonical form.
const dash_positions = [_]usize{ 8, 13, 18, 23 };

pub const ParseError = error{
    /// A character that is neither a hex digit nor punctuation in a place
    /// punctuation may go.
    InvalidCharacter,
    /// The text did not hold exactly 32 hex digits.
    InvalidLength,
};

/// Which family of identifier the bytes belong to, read off the two bits RFC
/// 9562 reserves for the question. Everything here mints `rfc9562`; the rest
/// exist because ids from elsewhere still have to be recognised.
pub const Variant = enum {
    /// Apollo NCS, from before the RFC.
    ncs,
    /// The one the RFC defines, and the only one `version` means anything for.
    rfc9562,
    /// Microsoft's GUIDs, which store the first three fields little-endian.
    microsoft,
    /// Held back for whatever comes next.
    reserved,
};

/// Letter case, for the text forms.
pub const Case = enum { lower, upper };

// -------------------------------------------------------------------------
// Making one
// -------------------------------------------------------------------------

/// Take sixteen bytes as they are, with no version or variant bits set. For
/// an id that came from somewhere else and means something already.
pub fn fromBytes(bytes: [16]u8) Uuid {
    return .{ .bytes = bytes };
}

/// The bits of a `u128`, most significant first.
pub fn fromInt(value: u128) Uuid {
    var self: Uuid = undefined;
    std.mem.writeInt(u128, &self.bytes, value, .big);
    return self;
}

pub fn toInt(self: Uuid) u128 {
    return std.mem.readInt(u128, &self.bytes, .big);
}

/// A fresh random id, version 4: 122 bits of chance and six of bookkeeping.
///
/// The generator is yours to choose. For ids that leave the process, pass one
/// the operating system seeds, which in Zig 0.16 means going through `Io`:
///
/// ```zig
/// var source: std.Random.IoSource = .{ .io = io };
/// const id = Uuid.random(source.interface());
/// ```
///
/// A seeded `std.Random.DefaultPrng` is the right choice instead when a build
/// has to produce the same ids twice - and the wrong one when anybody stands
/// to gain by guessing the next id.
pub fn random(rng: std.Random) Uuid {
    var self: Uuid = undefined;
    rng.bytes(&self.bytes);
    self.stamp(4);
    return self;
}

/// A random id with the time in front of it, version 7.
///
/// The first six bytes are milliseconds since the Unix epoch, big-endian, so
/// ids ascend as they are made - as bytes, as numbers, and as text. A B-tree
/// keyed on these appends to one page instead of dirtying a random page per
/// insert, which is the reason to prefer version 7 over version 4 for
/// anything that ends up in a database.
///
/// The clock is a parameter rather than something read here, because reading
/// it needs an `Io`, and because a caller that wants reproducible ids, or ids
/// dated to when an event actually happened, has to be able to say so:
///
/// ```zig
/// const now = std.Io.Clock.real.now(io).toMilliseconds();
/// const id = Uuid.sortable(rng, now);
/// ```
///
/// Before 1970 there is nothing to write and after the year 10889 there is no
/// room, so both ends of the range saturate rather than wrap into a timestamp
/// that would read as plausible.
///
/// Two ids made in the same millisecond sort in whatever order chance put
/// them. Use `Clock` when that is not good enough.
pub fn sortable(rng: std.Random, unix_ms: i64) Uuid {
    return sortableCounted(rng, unix_ms, rng.int(u12));
}

/// A source of `sortable` ids that never repeats and never goes backwards,
/// even within one millisecond or across a clock that steps.
///
/// Version 7 leaves twelve bits between the timestamp and the random tail.
/// RFC 9562 calls using them this way the "fixed bit-length dedicated
/// counter" method, and it is what turns ids that merely sort by millisecond
/// into ids that sort by the order they were handed out:
///
/// ```zig
/// var clock: Uuid.Clock = .init;
/// const a = clock.next(rng, now);
/// const b = clock.next(rng, now);   // same millisecond, still after `a`
/// ```
///
/// One `Clock` per thread, or one behind a mutex. Two of them running against
/// the same wall clock each ascend on their own and interleave arbitrarily
/// with each other.
pub const Clock = struct {
    /// The last millisecond handed out, which is not always the last
    /// millisecond seen.
    last_ms: i64,
    counter: u12,

    pub const init: Clock = .{ .last_ms = std.math.minInt(i64), .counter = 0 };

    pub fn next(self: *Clock, rng: std.Random, unix_ms: i64) Uuid {
        if (unix_ms > self.last_ms) {
            self.last_ms = unix_ms;
            // Seeded in the low half, so there is room to count up inside
            // this millisecond, and seeded randomly rather than from zero so
            // that the ids are not a sequence anyone can continue.
            self.counter = rng.int(u11);
        } else {
            // Either a second id in the same millisecond or a clock that went
            // backwards - an NTP step, a laptop waking up, a virtual machine
            // resuming. Both get the same answer: keep the millisecond
            // already used and step the counter, so the ids still ascend.
            const stepped = @addWithOverflow(self.counter, 1);
            self.counter = stepped[0];
            // Four thousand ids in one millisecond. Borrow from the next
            // millisecond rather than repeat this one; the clock catches up.
            if (stepped[1] == 1) self.last_ms +|= 1;
        }
        return sortableCounted(rng, self.last_ms, self.counter);
    }
};

/// Version 7, with the twelve counter bits chosen by the caller.
fn sortableCounted(rng: std.Random, unix_ms: i64, counter: u12) Uuid {
    const ms: u48 = if (unix_ms <= 0)
        0
    else
        @intCast(@min(unix_ms, std.math.maxInt(u48)));

    var self: Uuid = undefined;
    std.mem.writeInt(u48, self.bytes[0..6], ms, .big);
    // The counter's twelve bits straddle byte 6, whose top nibble `stamp`
    // takes back for the version.
    self.bytes[6] = @intCast(counter >> 8);
    self.bytes[7] = @truncate(counter);
    rng.bytes(self.bytes[8..]);
    self.stamp(7);
    return self;
}

/// The same id every time for the same `namespace` and `name`, version 5.
///
/// This is the one an asset pipeline wants: hand it a path and it hands back
/// an id that will still be the same next build, on another machine, without
/// anything having been written down.
///
/// ```zig
/// // Mint one of these once, with `random`, and keep it as a constant.
/// const assets = Uuid.parseComptime("2f8a1c40-6d3e-4b17-9f22-c1a5e7b90d34");
/// const cursor = Uuid.fromName(assets, "textures/ui/cursor.png");
/// ```
///
/// The digest is SHA-1, truncated, as the RFC specifies. That is not a
/// security property and was never meant to be one: anyone who knows the
/// namespace can compute the id for any name, which is the point.
pub fn fromName(namespace: Uuid, name: []const u8) Uuid {
    var sha1: std.crypto.hash.Sha1 = .init(.{});
    sha1.update(&namespace.bytes);
    sha1.update(name);

    var digest: [std.crypto.hash.Sha1.digest_length]u8 = undefined;
    sha1.final(&digest);

    var self: Uuid = undefined;
    @memcpy(&self.bytes, digest[0..16]);
    self.stamp(5);
    return self;
}

/// Overwrite the version and variant bits, which RFC 9562 reserves.
fn stamp(self: *Uuid, comptime version_number: u4) void {
    self.bytes[6] = (self.bytes[6] & 0x0F) | (@as(u8, version_number) << 4);
    self.bytes[8] = (self.bytes[8] & 0x3F) | 0x80;
}

/// The namespaces RFC 9562 defines, for `fromName`. A project that is not
/// naming DNS names or URLs should mint its own with `random` and keep it as
/// a constant.
pub const namespaces = struct {
    pub const dns = parseComptime("6ba7b810-9dad-11d1-80b4-00c04fd430c8");
    pub const url = parseComptime("6ba7b811-9dad-11d1-80b4-00c04fd430c8");
    pub const oid = parseComptime("6ba7b812-9dad-11d1-80b4-00c04fd430c8");
    pub const x500 = parseComptime("6ba7b814-9dad-11d1-80b4-00c04fd430c8");
};

/// Parse at compile time, so a malformed literal is a compile error rather
/// than something to handle at runtime.
pub fn parseComptime(comptime text: []const u8) Uuid {
    const parsed = comptime blk: {
        break :blk parse(text) catch
            @compileError("fluxion-id: not a uuid: " ++ text);
    };
    return parsed;
}

// -------------------------------------------------------------------------
// Text
// -------------------------------------------------------------------------

const hex_digits = "0123456789abcdef0123456789ABCDEF";

fn hexDigit(nibble: u4, case: Case) u8 {
    const offset: usize = switch (case) {
        .lower => 0,
        .upper => 16,
    };
    return hex_digits[offset + nibble];
}

/// The value of one hex digit, or null for anything that is not one.
fn hexValue(c: u8) ?u4 {
    return switch (c) {
        '0'...'9' => @intCast(c - '0'),
        'a'...'f' => @intCast(c - 'a' + 10),
        'A'...'F' => @intCast(c - 'A' + 10),
        else => null,
    };
}

/// Read the canonical `8-4-4-4-12` form.
///
/// Dashes may be anywhere or nowhere, surrounding braces are allowed, a
/// leading `urn:uuid:` is allowed, and either case reads: all of
/// `f81d4fae-7dec-11d0-a765-00a0c91e6bf6`,
/// `F81D4FAE7DEC11D0A76500A0C91E6BF6`, `{f81d4fae-...}` and
/// `urn:uuid:f81d4fae-...` are the same id. What is not allowed is anything
/// that is not a hex digit, a dash or a brace - a space is a mistake, not a
/// separator.
///
/// Forgiving on the way in and exact on the way out: `toString` always gives
/// the one spelling back, so an id compares equal to itself however it was
/// written down.
pub fn parse(text: []const u8) ParseError!Uuid {
    var body = text;
    if (body.len >= urn_prefix.len and
        std.ascii.eqlIgnoreCase(body[0..urn_prefix.len], urn_prefix))
    {
        body = body[urn_prefix.len..];
    }
    if (body.len >= 2 and body[0] == '{' and body[body.len - 1] == '}') {
        body = body[1 .. body.len - 1];
    }

    var self: Uuid = undefined;
    var digits: usize = 0;
    var high: u4 = 0;
    for (body) |c| {
        if (c == '-') continue;
        const value = hexValue(c) orelse return error.InvalidCharacter;
        if (digits % 2 == 0) {
            high = value;
        } else {
            self.bytes[digits / 2] = (@as(u8, high) << 4) | value;
        }
        digits += 1;
        // Checked inside the loop rather than after it, so that the write
        // above can never reach past the sixteenth byte.
        if (digits > 32) return error.InvalidLength;
    }
    if (digits != 32) return error.InvalidLength;
    return self;
}

/// The canonical form, held by value: nothing to allocate and nothing to free.
pub fn toString(self: Uuid) [string_len]u8 {
    return self.toStringCase(.lower);
}

pub fn toStringCase(self: Uuid, case: Case) [string_len]u8 {
    var out: [string_len]u8 = undefined;
    var digit: usize = 0;
    var i: usize = 0;
    while (i < string_len) : (i += 1) {
        if (std.mem.indexOfScalar(usize, &dash_positions, i) != null) {
            out[i] = '-';
            continue;
        }
        const byte = self.bytes[digit / 2];
        const nibble: u4 = @intCast(if (digit % 2 == 0) byte >> 4 else byte & 0x0F);
        out[i] = hexDigit(nibble, case);
        digit += 1;
    }
    return out;
}

/// The URN form, for the places that want a URI rather than a bare id.
pub fn toUrn(self: Uuid) [urn_len]u8 {
    var out: [urn_len]u8 = undefined;
    @memcpy(out[0..urn_prefix.len], urn_prefix);
    @memcpy(out[urn_prefix.len..], &self.toString());
    return out;
}

/// Print with `{f}`, in the canonical lowercase form.
pub fn format(self: Uuid, w: *std.Io.Writer) std.Io.Writer.Error!void {
    try w.writeAll(&self.toString());
}

// -------------------------------------------------------------------------
// Reading one
// -------------------------------------------------------------------------

/// The version digit, for an id whose `variant` is `rfc9562`: 4 for `random`,
/// 5 for `fromName`, 7 for `sortable`. Meaningless for one made with
/// `fromBytes`.
pub fn version(self: Uuid) u4 {
    return @intCast(self.bytes[6] >> 4);
}

/// Which family the id belongs to. Everything minted here is `rfc9562`.
pub fn variant(self: Uuid) Variant {
    const byte = self.bytes[8];
    if (byte & 0x80 == 0x00) return .ncs;
    if (byte & 0xC0 == 0x80) return .rfc9562;
    if (byte & 0xE0 == 0xC0) return .microsoft;
    return .reserved;
}

/// When a `sortable` id was made, in milliseconds since the Unix epoch, or
/// null for any other version.
///
/// Only version 7 carries a timestamp this can read. Version 1 has one too,
/// but counts hundreds of nanoseconds from 1582 with its fields split across
/// the id, and nothing here mints one.
pub fn timestamp(self: Uuid) ?i64 {
    if (self.version() != 7) return null;
    return std.mem.readInt(u48, self.bytes[0..6], .big);
}

pub fn isNil(self: Uuid) bool {
    return self.eql(nil);
}

pub fn isMax(self: Uuid) bool {
    return self.eql(max);
}

pub fn eql(self: Uuid, other: Uuid) bool {
    return std.mem.eql(u8, &self.bytes, &other.bytes);
}

/// Byte order, which for these bytes is also numeric order - and, for
/// `sortable` ids, the order they were made in.
pub fn order(self: Uuid, other: Uuid) std.math.Order {
    return std.mem.order(u8, &self.bytes, &other.bytes);
}

pub fn lessThan(self: Uuid, other: Uuid) bool {
    return self.order(other) == .lt;
}

pub fn hash(self: Uuid) u64 {
    return std.hash.Wyhash.hash(0, &self.bytes);
}

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

const sample_text = "f81d4fae-7dec-11d0-a765-00a0c91e6bf6";
const sample_bytes = [16]u8{
    0xF8, 0x1D, 0x4F, 0xAE, 0x7D, 0xEC, 0x11, 0xD0,
    0xA7, 0x65, 0x00, 0xA0, 0xC9, 0x1E, 0x6B, 0xF6,
};

test "parse and print the canonical form" {
    const id = try parse(sample_text);
    try testing.expectEqualSlices(u8, &sample_bytes, &id.bytes);
    try testing.expectEqualStrings(sample_text, &id.toString());
    try testing.expectFmt(sample_text, "{f}", .{id});
    try testing.expectEqualStrings(urn_prefix ++ sample_text, &id.toUrn());
}

test "parse is forgiving about punctuation and case" {
    const id = try parse(sample_text);
    const spellings = [_][]const u8{
        sample_text,
        "F81D4FAE-7DEC-11D0-A765-00A0C91E6BF6",
        "f81d4fae7dec11d0a76500a0c91e6bf6",
        "{f81d4fae-7dec-11d0-a765-00a0c91e6bf6}",
        "{F81D4FAE7DEC11D0A76500A0C91E6BF6}",
        "f8-1d-4f-ae-7d-ec-11-d0-a7-65-00-a0-c9-1e-6b-f6",
        "urn:uuid:f81d4fae-7dec-11d0-a765-00a0c91e6bf6",
        "URN:UUID:F81D4FAE-7DEC-11D0-A765-00A0C91E6BF6",
    };
    for (spellings) |text| {
        try testing.expect(id.eql(try parse(text)));
    }
    // But printing always gives the one spelling back.
    try testing.expectEqualStrings(sample_text, &(try parse(spellings[1])).toString());
    try testing.expectEqualStrings(
        "F81D4FAE-7DEC-11D0-A765-00A0C91E6BF6",
        &id.toStringCase(.upper),
    );
}

test "malformed text" {
    try testing.expectError(error.InvalidLength, parse(""));
    try testing.expectError(error.InvalidLength, parse("f81d4fae"));
    try testing.expectError(error.InvalidLength, parse(sample_text ++ "00"));
    try testing.expectError(error.InvalidLength, parse("f81d4fae-7dec-11d0-a765-00a0c91e6bf"));
    try testing.expectError(error.InvalidCharacter, parse("g81d4fae-7dec-11d0-a765-00a0c91e6bf6"));
    try testing.expectError(error.InvalidCharacter, parse("f81d4fae 7dec 11d0 a765 00a0c91e6bf6"));
    try testing.expectError(error.InvalidCharacter, parse(urn_prefix ++ sample_text ++ "!"));
    // A great many digits, caught before anything is written past the end.
    try testing.expectError(error.InvalidLength, parse("f" ** 64));
}

test "nil and max" {
    try testing.expect(nil.isNil());
    try testing.expect(max.isMax());
    try testing.expect(!nil.isMax());
    try testing.expectEqualStrings("00000000-0000-0000-0000-000000000000", &nil.toString());
    try testing.expectEqualStrings("ffffffff-ffff-ffff-ffff-ffffffffffff", &max.toString());
    try testing.expect((try parse("00000000-0000-0000-0000-000000000000")).isNil());
    try testing.expect(!(try parse(sample_text)).isNil());
}

test "round trip through bytes and integers" {
    const id = try parse(sample_text);
    try testing.expect(id.eql(fromBytes(id.bytes)));
    try testing.expect(id.eql(fromInt(id.toInt())));
    try testing.expectEqual(@as(u128, 0xF81D4FAE7DEC11D0A76500A0C91E6BF6), id.toInt());

    // The stored order is the printed order, so a memcpy to disk reads back.
    try testing.expectEqual(@as(u8, 0xF8), id.bytes[0]);
}

test "random ids are version 4 and distinct" {
    var prng: std.Random.DefaultPrng = .init(0x5EED);
    const rng = prng.random();

    var seen: std.AutoHashMapUnmanaged(Uuid, void) = .empty;
    defer seen.deinit(testing.allocator);

    for (0..1000) |_| {
        const id = random(rng);
        try testing.expectEqual(@as(u4, 4), id.version());
        try testing.expectEqual(Variant.rfc9562, id.variant());
        try testing.expect(id.timestamp() == null);
        try testing.expect(!id.isNil());
        try seen.put(testing.allocator, id, {});
    }
    try testing.expectEqual(@as(usize, 1000), seen.count());
}

test "sortable ids carry the time and sort by it" {
    var prng: std.Random.DefaultPrng = .init(0x7777);
    const rng = prng.random();

    const start: i64 = 1_700_000_000_000;
    var previous = sortable(rng, start);
    try testing.expectEqual(@as(u4, 7), previous.version());
    try testing.expectEqual(Variant.rfc9562, previous.variant());
    try testing.expectEqual(@as(?i64, start), previous.timestamp());

    // A millisecond later is a larger id, whatever chance did with the tail.
    for (1..500) |step| {
        const at = start + @as(i64, @intCast(step));
        const id = sortable(rng, at);
        try testing.expectEqual(@as(?i64, at), id.timestamp());
        try testing.expect(previous.lessThan(id));
        previous = id;
    }
}

test "sortable saturates rather than wrapping" {
    var prng: std.Random.DefaultPrng = .init(1);
    const rng = prng.random();

    // Before the epoch there is nothing to write.
    try testing.expectEqual(@as(?i64, 0), sortable(rng, -1).timestamp());
    try testing.expectEqual(@as(?i64, 0), sortable(rng, std.math.minInt(i64)).timestamp());

    // Past the top of the field, the largest millisecond it can hold - not a
    // small one that would read as the 1970s.
    const ceiling: i64 = std.math.maxInt(u48);
    try testing.expectEqual(@as(?i64, ceiling), sortable(rng, ceiling + 1).timestamp());
    try testing.expectEqual(@as(?i64, ceiling), sortable(rng, std.math.maxInt(i64)).timestamp());
}

test "Clock ascends within a millisecond, and across a clock that steps back" {
    var prng: std.Random.DefaultPrng = .init(0xC10C);
    const rng = prng.random();

    var clock: Clock = .init;
    const at: i64 = 1_700_000_000_000;

    // A thousand ids in one millisecond, each after the last.
    var previous = clock.next(rng, at);
    for (0..1000) |_| {
        const id = clock.next(rng, at);
        try testing.expect(previous.lessThan(id));
        try testing.expectEqual(@as(u4, 7), id.version());
        previous = id;
    }

    // The clock steps backwards by a second. The ids do not.
    for (0..100) |_| {
        const id = clock.next(rng, at - 1000);
        try testing.expect(previous.lessThan(id));
        previous = id;
    }

    // And time moving on again is picked straight up.
    const later = clock.next(rng, at + 5);
    try testing.expect(previous.lessThan(later));
    try testing.expectEqual(@as(?i64, at + 5), later.timestamp());
}

test "Clock keeps ascending when the counter runs out" {
    var prng: std.Random.DefaultPrng = .init(2);
    const rng = prng.random();

    // Start with the counter as high as it goes, so the next id has to borrow
    // a millisecond from the future.
    var clock: Clock = .{ .last_ms = 1_000, .counter = std.math.maxInt(u12) };
    const first = clock.next(rng, 1_000);
    try testing.expectEqual(@as(?i64, 1_001), first.timestamp());

    var previous = first;
    for (0..10_000) |_| {
        const id = clock.next(rng, 1_000);
        try testing.expect(previous.lessThan(id));
        previous = id;
    }
}

test "fromName gives the same id every time" {
    // A namespace of this project's own, not one of the RFC's.
    const assets = parseComptime("2f8a1c40-6d3e-4b17-9f22-c1a5e7b90d34");
    const cursor = fromName(assets, "textures/ui/cursor.png");

    try testing.expect(cursor.eql(fromName(assets, "textures/ui/cursor.png")));
    try testing.expectEqual(@as(u4, 5), cursor.version());
    try testing.expectEqual(Variant.rfc9562, cursor.variant());

    // A different name, or the same name in a different namespace, is a
    // different id.
    try testing.expect(!cursor.eql(fromName(assets, "textures/ui/cursor2.png")));
    try testing.expect(!cursor.eql(fromName(namespaces.dns, "textures/ui/cursor.png")));
}

test "fromName matches the RFC's own example" {
    // RFC 9562 appendix: the DNS namespace over "www.example.com".
    const id = fromName(namespaces.dns, "www.example.com");
    try testing.expectEqualStrings("2ed6657d-e927-568b-95e1-2665a8aea6a2", &id.toString());
}

test "namespaces are parsed at compile time" {
    try testing.expectEqualStrings(
        "6ba7b810-9dad-11d1-80b4-00c04fd430c8",
        &namespaces.dns.toString(),
    );
    const mine = parseComptime(sample_text);
    try testing.expect(mine.eql(try parse(sample_text)));
}

test "variants other than the RFC's are recognised, not minted" {
    const at = struct {
        fn variantOf(comptime text: []const u8) Variant {
            return parseComptime(text).variant();
        }
    };
    try testing.expectEqual(Variant.ncs, at.variantOf("00000000-0000-0000-0000-000000000000"));
    try testing.expectEqual(Variant.rfc9562, at.variantOf("00000000-0000-0000-8000-000000000000"));
    try testing.expectEqual(Variant.microsoft, at.variantOf("00000000-0000-0000-c000-000000000000"));
    try testing.expectEqual(Variant.reserved, at.variantOf("00000000-0000-0000-e000-000000000000"));
    try testing.expectEqual(Variant.reserved, max.variant());
}

test "ordering and hashing" {
    const a = try parse("00000000-0000-0000-0000-000000000001");
    const b = try parse("00000000-0000-0000-0000-000000000002");

    try testing.expect(a.lessThan(b));
    try testing.expect(!b.lessThan(a));
    try testing.expectEqual(std.math.Order.lt, a.order(b));
    try testing.expectEqual(std.math.Order.eq, a.order(a));
    try testing.expectEqual(a.hash(), (try parse("00000000-0000-0000-0000-000000000001")).hash());

    // Byte order is numeric order, so sorting ids sorts their values.
    var ids = [_]Uuid{ b, nil, a, max };
    std.mem.sort(Uuid, &ids, {}, struct {
        fn lt(_: void, x: Uuid, y: Uuid) bool {
            return x.lessThan(y);
        }
    }.lt);
    try testing.expect(ids[0].isNil());
    try testing.expect(ids[1].eql(a));
    try testing.expect(ids[2].eql(b));
    try testing.expect(ids[3].isMax());
}

test "works as a value and as a map key" {
    var map: std.AutoHashMapUnmanaged(Uuid, u32) = .empty;
    defer map.deinit(testing.allocator);

    const id = try parse(sample_text);
    try map.put(testing.allocator, id, 7);
    // The same id arrived at a different way must hit the same slot.
    try testing.expectEqual(@as(?u32, 7), map.get(try parse("F81D4FAE7DEC11D0A76500A0C91E6BF6")));
    try testing.expect(std.meta.eql(id, fromBytes(sample_bytes)));

    // It copies like an integer, so a copy is independent.
    var copy = id;
    copy.bytes[0] = 0;
    try testing.expectEqual(@as(u8, 0xF8), id.bytes[0]);
}
