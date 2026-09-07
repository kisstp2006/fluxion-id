// SPDX-License-Identifier: CC0-1.0

//! Crockford base32 over exactly sixteen bytes, which is what a `TypeId`
//! suffix is made of.
//!
//! Base32 rather than the base64 an id would otherwise be written in, because
//! the result has to survive being read aloud, typed in from a screenshot, and
//! pasted into a URL, a shell and a filename. Crockford's alphabet drops `i`,
//! `l`, `o` and `u`: the first three because they are hard to tell from `1` and
//! `0`, the last so that no arrangement of digits spells a word anyone will
//! object to.
//!
//! Sixteen bytes is 128 bits, and 26 base32 digits hold 130, so the top two
//! bits of the first digit are always zero and the first character is always
//! `0` to `7`. Text that starts higher than `7` names a number too large to be
//! sixteen bytes, and is rejected rather than truncated.
//!
//! The digits ascend with the alphabet, so sorting the text sorts the bytes.
//! That is the property `TypeId` leans on: because a UUIDv7 begins with its
//! timestamp, sorting the strings sorts by the moment each id was made.

const std = @import("std");
const testing = std.testing;

/// Crockford's digits, in order. Note the gaps where `i`, `l`, `o` and `u`
/// would be.
pub const alphabet = "0123456789abcdefghjkmnpqrstvwxyz";

/// How many digits sixteen bytes take.
pub const encoded_len: usize = 26;

pub const DecodeError = error{
    /// A character outside the alphabet. Uppercase counts: the encoded form is
    /// lowercase, and accepting anything else would mean two spellings of one
    /// id.
    InvalidCharacter,
    /// A first digit above `7`, so the text names more than 128 bits.
    Overflow,
};

/// The digit values, indexed by byte. 0xFF for anything that is not a digit,
/// which is most of the table.
const values = blk: {
    var table: [256]u8 = @splat(0xFF);
    for (alphabet, 0..) |c, i| table[c] = i;
    break :blk table;
};

/// Sixteen bytes, most significant first, as 26 digits.
pub fn encode(bytes: [16]u8) [encoded_len]u8 {
    var value = std.mem.readInt(u128, &bytes, .big);
    var out: [encoded_len]u8 = undefined;
    var i = encoded_len;
    // Filled from the back, because the last digit is the low five bits.
    while (i > 0) {
        i -= 1;
        out[i] = alphabet[@as(u5, @truncate(value))];
        value >>= 5;
    }
    return out;
}

/// The other way. Takes a pointer to exactly 26 characters, so the length is
/// the caller's problem and cannot be wrong here.
pub fn decode(text: *const [encoded_len]u8) DecodeError![16]u8 {
    const first = values[text[0]];
    if (first == 0xFF) return error.InvalidCharacter;
    if (first > 7) return error.Overflow;

    // With the first digit below 8, the running value stays under 2^128 all
    // the way: 3 bits, then 5 more per digit, is 3 + 5 * 25 = 128 exactly.
    var value: u128 = first;
    for (text[1..]) |c| {
        const digit = values[c];
        if (digit == 0xFF) return error.InvalidCharacter;
        value = (value << 5) | digit;
    }

    var bytes: [16]u8 = undefined;
    std.mem.writeInt(u128, &bytes, value, .big);
    return bytes;
}

/// Whether `text` would decode. Cheaper to ask than to decode and throw the
/// bytes away.
pub fn isValid(text: *const [encoded_len]u8) bool {
    _ = decode(text) catch return false;
    return true;
}

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

test "round trip" {
    var prng: std.Random.DefaultPrng = .init(0xB32);
    const rng = prng.random();

    for (0..1000) |_| {
        var bytes: [16]u8 = undefined;
        rng.bytes(&bytes);
        const text = encode(bytes);
        try testing.expectEqualSlices(u8, &bytes, &(try decode(&text)));
    }
}

test "the ends of the range" {
    const zero: [16]u8 = @splat(0);
    const ones: [16]u8 = @splat(0xFF);

    try testing.expectEqualStrings("00000000000000000000000000", &encode(zero));
    try testing.expectEqualStrings("7zzzzzzzzzzzzzzzzzzzzzzzzz", &encode(ones));
    try testing.expectEqualSlices(u8, &zero, &(try decode("00000000000000000000000000")));
    try testing.expectEqualSlices(u8, &ones, &(try decode("7zzzzzzzzzzzzzzzzzzzzzzzzz")));

    // One past the top: 26 digits that name 2^128 or more.
    try testing.expectError(error.Overflow, decode("8zzzzzzzzzzzzzzzzzzzzzzzzz"));
    try testing.expectError(error.Overflow, decode("80000000000000000000000000"));
    try testing.expectError(error.Overflow, decode("zzzzzzzzzzzzzzzzzzzzzzzzzz"));
}

test "the alphabet is exactly Crockford's, and only in lowercase" {
    try testing.expectEqual(@as(usize, 32), alphabet.len);
    for ("ilou") |c| {
        try testing.expect(std.mem.indexOfScalar(u8, alphabet, c) == null);
    }

    // Uppercase is not a second spelling of the same id.
    try testing.expectError(error.InvalidCharacter, decode("0000000000000000000000000Z"));
    try testing.expectError(error.InvalidCharacter, decode("0000000000000000000000000i"));
    try testing.expectError(error.InvalidCharacter, decode("0000000000000000000000000 "));
    try testing.expectError(error.InvalidCharacter, decode("-0000000000000000000000000"));
}

test "text order is byte order" {
    var prng: std.Random.DefaultPrng = .init(0x0D3E);
    const rng = prng.random();

    for (0..1000) |_| {
        var a: [16]u8 = undefined;
        var b: [16]u8 = undefined;
        rng.bytes(&a);
        rng.bytes(&b);

        const text_order = std.mem.order(u8, &encode(a), &encode(b));
        try testing.expectEqual(std.mem.order(u8, &a, &b), text_order);
    }

    // Which is what makes a timestamped id sort by time once it is text.
    var early: [16]u8 = @splat(0);
    var late: [16]u8 = @splat(0);
    std.mem.writeInt(u48, early[0..6], 1_700_000_000_000, .big);
    std.mem.writeInt(u48, late[0..6], 1_700_000_000_001, .big);
    try testing.expect(std.mem.lessThan(u8, &encode(early), &encode(late)));
}

test "every digit decodes to its position" {
    for (alphabet, 0..) |c, i| {
        var text: [encoded_len]u8 = @splat('0');
        text[encoded_len - 1] = c;
        const bytes = try decode(&text);
        try testing.expectEqual(@as(u128, i), std.mem.readInt(u128, &bytes, .big));
    }
    try testing.expect(isValid("00000000000000000000000000"));
    try testing.expect(!isValid("i0000000000000000000000000"));
}
