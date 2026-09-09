// SPDX-License-Identifier: CC0-1.0

// Crockford base32 over exactly sixteen bytes, which is what a `TypeId`
// suffix is made of.
//
// Base32 rather than the base64 an id would otherwise be written in, because
// the result has to survive being read aloud, typed in from a screenshot, and
// pasted into a URL, a shell and a filename. Crockford's alphabet drops `i`,
// `l`, `o` and `u`: the first three because they are hard to tell from `1` and
// `0`, the last so that no arrangement of digits spells a word anyone will
// object to.
//
// Sixteen bytes is 128 bits, and 26 base32 digits hold 130, so the top two
// bits of the first digit are always zero and the first character is always
// `0` to `7`. Text that starts higher than `7` names a number too large to be
// sixteen bytes, and is rejected rather than truncated.
//
// The digits ascend with the alphabet, so sorting the text sorts the bytes.
// That is the property `TypeId` leans on: because a UUIDv7 begins with its
// timestamp, sorting the strings sorts by the moment each id was made.
module fluxion::id::base32;

// Crockford's digits, in order. Note the gaps where `i`, `l`, `o` and `u`
// would be.
const String ALPHABET = "0123456789abcdefghjkmnpqrstvwxyz";

// How many digits sixteen bytes take.
const ENCODED_LEN = 26;

// A character outside the alphabet. Uppercase counts: the encoded form is
// lowercase, and accepting anything else would mean two spellings of one id.
faultdef INVALID_CHARACTER;

// A first digit above `7`, so the text names more than 128 bits.
faultdef OVERFLOW;

// The digit values, indexed by byte. 0xFF for anything that is not a digit,
// which is most of the table. Built at compile time the same way `crc` in
// fluxion-hash builds its table: only `$`-variables, so the macro folds to a
// constant and the table is data, not code.
macro char[256] @values() @const @private
{
	var $t = (char[256]){};
	$for var $i = 0; $i < 256; $i++:
		$t[$i] = 0xFF;
	$endfor
	$for var $i = 0; $i < 32; $i++:
		$t[ALPHABET[$i]] = $i;
	$endfor
	return $t;
}

const char[256] VALUES = @values();

<*
 Sixteen bytes, most significant first, as 26 digits.
*>
fn char[ENCODED_LEN] encode(char[16] bytes)
{
	// C3 has a 128-bit integer, which makes this a shift loop rather than a
	// bit-buffer. `load_be` reads the sixteen bytes as one big-endian number.
	uint128 value = bitorder::load_be((uint128*)&bytes);
	char[ENCODED_LEN] out;
	// Filled from the back, because the last digit is the low five bits.
	for (sz i = ENCODED_LEN; i > 0; i--)
	{
		out[i - 1] = ALPHABET[(sz)(value & 31)];
		value >>= 5;
	}
	return out;
}

<*
 The other way. The contract pins the length to 26, so a wrong length is
 caught at the call site in safe builds rather than read past here.

 @require text.len == ENCODED_LEN : "a base32 suffix is exactly 26 digits"
*>
fn char[16]? decode(char[] text)
{
	char first = VALUES[text[0]];
	if (first == 0xFF) return INVALID_CHARACTER~;
	if (first > 7) return OVERFLOW~;

	// With the first digit below 8, the running value stays under 2^128 all
	// the way: 3 bits, then 5 more per digit, is 3 + 5 * 25 = 128 exactly.
	uint128 value = first;
	foreach (c : text[1..])
	{
		char digit = VALUES[c];
		if (digit == 0xFF) return INVALID_CHARACTER~;
		value = (value << 5) | digit;
	}

	char[16] bytes;
	bitorder::store_be(&bytes, value);
	return bytes;
}

<*
 Whether `text` would decode. Cheaper to ask than to decode and throw the
 bytes away.

 @require text.len == ENCODED_LEN : "a base32 suffix is exactly 26 digits"
*>
fn bool is_valid(char[] text)
{
	// `@ok` is the C3 spelling of "did this succeed": it evaluates the
	// optional and answers true or false without unwrapping it.
	return @ok(decode(text));
}

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

import std::math::random;

// A `char[N]` is not a `String`, and `test::eq` will not compare the two.
// Slicing turns an array into a `char[]`, which a `String` is, so this is
// how the tests below say "the text should read...".
macro @expect_text(#actual, String expected)
{
	var got = #actual;
	test::eq((String)got[..], expected);
}

fn void test_round_trip() @test
{
	Sfc64Random prng;
	random::seed(&prng, 0xB32);

	for (int round = 0; round < 1000; round++)
	{
		char[16] bytes;
		prng.next_bytes(&bytes);
		char[ENCODED_LEN] text = encode(bytes);
		test::eq(decode(&text)!!, bytes);
	}
}

fn void test_the_ends_of_the_range() @test
{
	char[16] zero;
	char[16] ones;
	ones[..] = 0xFF;

	@expect_text(encode(zero), "00000000000000000000000000");
	@expect_text(encode(ones), "7zzzzzzzzzzzzzzzzzzzzzzzzz");
	test::eq(decode("00000000000000000000000000")!!, zero);
	test::eq(decode("7zzzzzzzzzzzzzzzzzzzzzzzzz")!!, ones);

	// One past the top: 26 digits that name 2^128 or more.
	test::@error(decode("8zzzzzzzzzzzzzzzzzzzzzzzzz"), OVERFLOW);
	test::@error(decode("80000000000000000000000000"), OVERFLOW);
	test::@error(decode("zzzzzzzzzzzzzzzzzzzzzzzzzz"), OVERFLOW);
}

fn void test_the_alphabet_is_exactly_crockfords_and_only_in_lowercase() @test
{
	test::eq(ALPHABET.len, 32);
	foreach (c : "ilou")
	{
		test::@check(!@ok(ALPHABET.index_of_char(c)));
	}

	// Uppercase is not a second spelling of the same id.
	test::@error(decode("0000000000000000000000000Z"), INVALID_CHARACTER);
	test::@error(decode("0000000000000000000000000i"), INVALID_CHARACTER);
	test::@error(decode("0000000000000000000000000 "), INVALID_CHARACTER);
	test::@error(decode("-0000000000000000000000000"), INVALID_CHARACTER);
}

fn void test_text_order_is_byte_order() @test
{
	Sfc64Random prng;
	random::seed(&prng, 0x0D3E);

	for (int round = 0; round < 1000; round++)
	{
		char[16] a;
		char[16] b;
		prng.next_bytes(&a);
		prng.next_bytes(&b);

		char[ENCODED_LEN] ta = encode(a);
		char[ENCODED_LEN] tb = encode(b);
		test::eq(((String)ta[..]).compare_to((String)tb[..]), ((String)a[..]).compare_to((String)b[..]));
	}

	// Which is what makes a timestamped id sort by time once it is text.
	char[16] early;
	char[16] late;
	// A 48-bit millisecond in the first six bytes, big-endian: the shift
	// leaves the two low bytes of the `ulong` zero, and they land in bytes 6
	// and 7 where they change nothing.
	bitorder::store_be(&early[0], (ulong)1_700_000_000_000 << 16);
	bitorder::store_be(&late[0], (ulong)1_700_000_000_001 << 16);
	char[ENCODED_LEN] te = encode(early);
	char[ENCODED_LEN] tl = encode(late);
	test::@check(((String)te[..]).compare_to((String)tl[..]) < 0);
}

fn void test_every_digit_decodes_to_its_position() @test
{
	foreach (i, c : ALPHABET)
	{
		char[ENCODED_LEN] text;
		text[..] = '0';
		text[ENCODED_LEN - 1] = c;
		char[16] bytes = decode(&text)!!;
		test::eq(bitorder::load_be((uint128*)&bytes), (uint128)i);
	}
	test::@check(is_valid("00000000000000000000000000"));
	test::@check(!is_valid("i0000000000000000000000000"));
}
