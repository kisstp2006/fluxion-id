// SPDX-License-Identifier: CC0-1.0

// A 128-bit name for a thing, in the layout RFC 9562 fixes.
//
// Sixteen bytes is enough that two machines that have never spoken can each
// mint one and be confident they did not collide. That is the whole trick: no
// server hands these out, no table is locked, and a name minted offline is as
// good as one from a datacentre. The cost is thirty-six characters of text no
// reader will ever recognise.
//
// Four ways to make one, and the choice is about what the id should be
// correlated with:
//
//   `random`      version 4: nothing but chance. The default.
//   `sortable`    version 7: a timestamp, then chance. Ids made near each
//                 other in time sort near each other, which is what a database
//                 index wants.
//   `from_name`   version 5: the same id every time for the same namespace and
//                 text, so a path becomes an id with nothing written down.
//   `from_bytes`  sixteen bytes that already mean something elsewhere.
//
// The bytes are stored in the order they are written, so a `Uuid` memcpy'd
// into a file reads back on any machine, and byte order is also numeric order
// - and, for `sortable`, the order the ids were made in. It is a value: copy
// it, compare it with `==` on the bytes or `equals`, use it as a `HashMap` key.
module fluxion::id::uuid;
import std::hash::sha1;
import std::math::random;
import std::io;

// `(Printable)` declares that the struct implements the interface `%s`
// formatting looks for. The one method it needs, `to_format`, is further
// down, and `io::printfn("%s", id)` prints the canonical form from then on.
struct Uuid (Printable)
{
	// Big-endian, as RFC 9562 lays them out: the text form reads straight off.
	char[16] bytes;
}

// All zeroes. What an uninitialised id looks like, and therefore what to
// check for.
const Uuid NIL = {};

// All ones. Sorts after everything, which makes it the upper bound of a
// range query.
const Uuid MAX = { .bytes = { [0..15] = 0xFF } };

// The length of the canonical text form, `8-4-4-4-12`.
const STRING_LEN = 36;

// The scheme RFC 9562 registers for the URN form.
const String URN_PREFIX = "urn:uuid:";

// The length of `urn:uuid:` and the canonical form together.
const URN_LEN = URN_PREFIX.len + STRING_LEN;

// A character that is neither a hex digit nor punctuation in a place
// punctuation may go.
faultdef INVALID_CHARACTER;

// The text did not hold exactly 32 hex digits.
faultdef INVALID_LENGTH;

// Asked for the timestamp of an id that has none. See `timestamp`.
faultdef NO_TIMESTAMP;

// Which family of identifier the bytes belong to, read off the two bits RFC
// 9562 reserves for the question. Everything here mints `RFC9562`; the rest
// exist because ids from elsewhere still have to be recognised.
enum Variant
{
	// Apollo NCS, from before the RFC.
	NCS,
	// The one the RFC defines, and the only one `version` means anything for.
	RFC9562,
	// Microsoft's GUIDs, which store the first three fields little-endian.
	MICROSOFT,
	// Held back for whatever comes next.
	RESERVED,
}

// Letter case, for the text forms.
enum Case
{
	LOWER,
	UPPER,
}

// -------------------------------------------------------------------------
// Making one
// -------------------------------------------------------------------------

<*
 Take sixteen bytes as they are, with no version or variant bits set. For an
 id that came from somewhere else and means something already.
*>
fn Uuid from_bytes(char[16] bytes)
{
	return { .bytes = bytes };
}

<*
 The bits of a `uint128`, most significant first.
*>
fn Uuid from_int(uint128 value)
{
	Uuid self;
	bitorder::store_be(&self.bytes, value);
	return self;
}

fn uint128 Uuid.to_int(self)
{
	return bitorder::load_be((uint128*)&self.bytes);
}

<*
 A fresh random id, version 4: 122 bits of chance and six of bookkeeping.

 The generator is yours to choose. `Random` is an interface, so any of the
 standard library's generators fits, passed by address:

     Sfc64Random prng;
     random::seed_entropy(&prng);
     Uuid id = uuid::random(&prng);

 Seed from entropy for ids that leave the process. A generator seeded from a
 fixed number is the right choice instead when a build has to produce the
 same ids twice - and the wrong one when anybody stands to gain by guessing
 the next id.
*>
fn Uuid random(Random rng)
{
	Uuid self;
	rng.next_bytes(&self.bytes);
	self.stamp(4);
	return self;
}

<*
 A random id with the time in front of it, version 7.

 The first six bytes are milliseconds since the Unix epoch, big-endian, so
 ids ascend as they are made - as bytes, as numbers, and as text. A B-tree
 keyed on these appends to one page instead of dirtying a random page per
 insert, which is the reason to prefer version 7 over version 4 for anything
 that ends up in a database.

 The clock is a parameter rather than something read here, because a caller
 that wants reproducible ids, or ids dated to when an event actually
 happened, has to be able to say so. `id::unix_millis()` reads the wall
 clock in these units.

 Before 1970 there is nothing to write and after the year 10889 there is no
 room, so both ends of the range saturate rather than wrap into a timestamp
 that would read as plausible.

 Two ids made in the same millisecond sort in whatever order chance put
 them. Use `Clock` when that is not good enough.
*>
fn Uuid sortable(Random rng, long unix_ms)
{
	return sortable_counted(rng, unix_ms, rng.next_short() & 0xFFF);
}

<*
 A source of `sortable` ids that never repeats and never goes backwards,
 even within one millisecond or across a clock that steps.

 Version 7 leaves twelve bits between the timestamp and the random tail. RFC
 9562 calls using them this way the "fixed bit-length dedicated counter"
 method, and it is what turns ids that merely sort by millisecond into ids
 that sort by the order they were handed out:

     Clock clock;
     clock.init();
     Uuid a = clock.next(rng, now);
     Uuid b = clock.next(rng, now);   // same millisecond, still after `a`

 One `Clock` per thread, or one behind a mutex. Two of them running against
 the same wall clock each ascend on their own and interleave arbitrarily
 with each other.
*>
struct Clock
{
	// The last millisecond handed out, which is not always the last
	// millisecond seen.
	long last_ms;
	// Twelve bits in use, held in the next size up.
	ushort counter;
}

<*
 A clock that has handed out nothing yet, so the first `next` takes whatever
 time it is given.
*>
fn void Clock.init(&self)
{
	*self = { .last_ms = long::min };
}

fn Uuid Clock.next(&self, Random rng, long unix_ms)
{
	if (unix_ms > self.last_ms)
	{
		self.last_ms = unix_ms;
		// Seeded in the low half, so there is room to count up inside this
		// millisecond, and seeded randomly rather than from zero so that the
		// ids are not a sequence anyone can continue.
		self.counter = rng.next_short() & 0x7FF;
	}
	else
	{
		// Either a second id in the same millisecond or a clock that went
		// backwards - an NTP step, a laptop waking up, a virtual machine
		// resuming. Both get the same answer: keep the millisecond already
		// used and step the counter, so the ids still ascend.
		if (self.counter == 0xFFF)
		{
			// Four thousand ids in one millisecond. Borrow from the next
			// millisecond rather than repeat this one; the clock catches up.
			self.counter = 0;
			if (self.last_ms < long::max) self.last_ms++;
		}
		else
		{
			self.counter++;
		}
	}
	return sortable_counted(rng, self.last_ms, self.counter);
}

// Version 7, with the twelve counter bits chosen by the caller.
fn Uuid sortable_counted(Random rng, long unix_ms, ushort counter) @private
{
	const ulong CEILING = 0xFFFF_FFFF_FFFF; // 48 bits
	ulong ms = unix_ms <= 0 ? 0 : min((ulong)unix_ms, CEILING);

	Uuid self;
	// Six bytes of timestamp, big-endian, by hand: there is no 48-bit
	// integer to hand `store_be`.
	for (int i = 0; i < 6; i++)
	{
		self.bytes[i] = (char)(ms >> (8 * (5 - i)));
	}
	// The counter's twelve bits straddle byte 6, whose top nibble `stamp`
	// takes back for the version.
	self.bytes[6] = (char)(counter >> 8);
	self.bytes[7] = (char)counter;
	rng.next_bytes(self.bytes[8..]);
	self.stamp(7);
	return self;
}

<*
 The same id every time for the same `namespace` and `name`, version 5.

 This is the one an asset pipeline wants: hand it a path and it hands back an
 id that will still be the same next build, on another machine, without
 anything having been written down.

     // Mint one of these once, with `random`, and keep it as a constant.
     const Uuid ASSETS = uuid::@parse("2f8a1c40-6d3e-4b17-9f22-c1a5e7b90d34");
     Uuid cursor = uuid::from_name(ASSETS, "textures/ui/cursor.png");

 The digest is SHA-1, truncated, as the RFC specifies. That is not a
 security property and was never meant to be one: anyone who knows the
 namespace can compute the id for any name, which is the point.
*>
fn Uuid from_name(Uuid namespace, String name)
{
	Sha1 sha;
	sha.init();
	sha.update(&namespace.bytes);
	sha.update(name);
	char[20] digest = sha.final();

	Uuid self;
	mem::copy(&self.bytes, &digest, 16);
	self.stamp(5);
	return self;
}

// Overwrite the version and variant bits, which RFC 9562 reserves.
fn void Uuid.stamp(&self, char version_number)
{
	self.bytes[6] = (self.bytes[6] & 0x0F) | (version_number << 4);
	self.bytes[8] = (self.bytes[8] & 0x3F) | 0x80;
}

// -------------------------------------------------------------------------
// Compile-time parsing
// -------------------------------------------------------------------------

<*
 Parse a literal at compile time, so a malformed one is a compile error
 rather than something to handle at run time, and the result can initialise
 a `const`:

     const Uuid PROJECT = uuid::@parse("2f8a1c40-6d3e-4b17-9f22-c1a5e7b90d34");

 This is the same trick as the CRC table in fluxion-hash, applied to text:
 every variable is a `$`-variable, so the compiler runs the loop itself and
 what is left is sixteen bytes. `$error` inside such a macro is a compile
 error at the call site, with the message given here. The run-time `parse`
 below accepts more spellings; a literal in source has no reason to be
 spelled any way but the canonical one.
*>
macro Uuid @parse(String $text) @const
{
	var $bytes = (char[16]){};
	var $digits = 0;
	$for var $i = 0; $i < $text.len; $i++:
		$if $text[$i] != '-':
			$if $digits >= 32:
				$error("fluxion-id: not a uuid, more than 32 digits: " +++ $text);
			$endif
			var $v = @hex_value_const($text[$i]);
			$if $digits % 2 == 0:
				$bytes[$digits / 2] = $v << 4;
			$else
				$bytes[$digits / 2] |= $v;
			$endif
			$digits++;
		$endif
	$endfor
	$if $digits != 32:
		$error("fluxion-id: not a uuid, wants 32 hex digits: " +++ $text);
	$endif
	return (Uuid){ .bytes = $bytes };
}

macro char @hex_value_const($c) @const @private
{
	$switch:
		$case $c >= '0' && $c <= '9':
			return $c - '0';
		$case $c >= 'a' && $c <= 'f':
			return $c - 'a' + 10;
		$case $c >= 'A' && $c <= 'F':
			return $c - 'A' + 10;
		$default:
			$error("fluxion-id: not a hex digit in a uuid literal");
	$endswitch
}

// The namespaces RFC 9562 defines, for `from_name`. A project that is not
// naming DNS names or URLs should mint its own with `random` and keep it as
// a constant.
const Uuid NAMESPACE_DNS = @parse("6ba7b810-9dad-11d1-80b4-00c04fd430c8");
const Uuid NAMESPACE_URL = @parse("6ba7b811-9dad-11d1-80b4-00c04fd430c8");
const Uuid NAMESPACE_OID = @parse("6ba7b812-9dad-11d1-80b4-00c04fd430c8");
const Uuid NAMESPACE_X500 = @parse("6ba7b814-9dad-11d1-80b4-00c04fd430c8");

// -------------------------------------------------------------------------
// Text
// -------------------------------------------------------------------------

const String HEX_DIGITS = "0123456789abcdef0123456789ABCDEF";

fn char hex_digit(char nibble, Case letter_case) @private
{
	sz offset = letter_case == UPPER ? 16 : 0;
	return HEX_DIGITS[offset + nibble];
}

// The value of one hex digit, or 0xFF for anything that is not one.
fn char hex_value(char c) @private
{
	switch
	{
		case c >= '0' && c <= '9': return c - '0';
		case c >= 'a' && c <= 'f': return c - 'a' + 10;
		case c >= 'A' && c <= 'F': return c - 'A' + 10;
		default: return 0xFF;
	}
}

<*
 Read the canonical `8-4-4-4-12` form.

 Dashes may be anywhere or nowhere, surrounding braces are allowed, a leading
 `urn:uuid:` is allowed, and either case reads: all of
 `f81d4fae-7dec-11d0-a765-00a0c91e6bf6`, `F81D4FAE7DEC11D0A76500A0C91E6BF6`,
 `{f81d4fae-...}` and `urn:uuid:f81d4fae-...` are the same id. What is not
 allowed is anything that is not a hex digit, a dash or a brace - a space is
 a mistake, not a separator.

 Forgiving on the way in and exact on the way out: `to_string` always gives
 the one spelling back, so an id compares equal to itself however it was
 written down.

 The return type `Uuid?` is C3's optional: a `Uuid`, or a fault saying why
 there is none. `return INVALID_LENGTH~;` is how a function hands back the
 fault, and the caller unwraps with `!` to pass it up, `!!` to insist, or
 `if (try id = parse(text))` to branch.
*>
fn Uuid? parse(String text)
{
	String body = text;
	if (body.len >= URN_PREFIX.len && body[:URN_PREFIX.len].compare_to_ignore_case(URN_PREFIX) == 0)
	{
		body = body[URN_PREFIX.len..];
	}
	if (body.len >= 2 && body[0] == '{' && body[^1] == '}')
	{
		body = body[1..^2];
	}

	Uuid self;
	sz digits = 0;
	char high = 0;
	foreach (c : body)
	{
		if (c == '-') continue;
		char value = hex_value(c);
		if (value == 0xFF) return INVALID_CHARACTER~;
		// Checked before the write rather than after it, so that the write
		// can never reach past the sixteenth byte.
		if (digits >= 32) return INVALID_LENGTH~;
		if (digits % 2 == 0)
		{
			high = value;
		}
		else
		{
			self.bytes[digits / 2] = (high << 4) | value;
		}
		digits++;
	}
	if (digits != 32) return INVALID_LENGTH~;
	return self;
}

<*
 The canonical form, held by value: nothing to allocate and nothing to free.
 Slice it - `(String)text[..]` - where a `String` is wanted.
*>
fn char[STRING_LEN] Uuid.to_string(self)
{
	return self.to_string_case(LOWER);
}

fn char[STRING_LEN] Uuid.to_string_case(self, Case letter_case)
{
	char[STRING_LEN] out;
	sz digit = 0;
	for (sz i = 0; i < STRING_LEN; i++)
	{
		// Where the dashes go in the canonical form.
		if (i == 8 || i == 13 || i == 18 || i == 23)
		{
			out[i] = '-';
			continue;
		}
		char byte = self.bytes[digit / 2];
		char nibble = digit % 2 == 0 ? byte >> 4 : byte & 0x0F;
		out[i] = hex_digit(nibble, letter_case);
		digit++;
	}
	return out;
}

<*
 The URN form, for the places that want a URI rather than a bare id.
*>
fn char[URN_LEN] Uuid.to_urn(self)
{
	char[URN_LEN] out;
	char[STRING_LEN] text = self.to_string();
	mem::copy(&out, URN_PREFIX.ptr, URN_PREFIX.len);
	mem::copy(&out[URN_PREFIX.len], &text, STRING_LEN);
	return out;
}

<*
 What `%s` prints: the canonical lowercase form. This is the `Printable`
 method; the `@dynamic` marks it as reachable through the interface, and the
 return is how many characters went out, or the writer's fault.
*>
fn sz? Uuid.to_format(&self, Formatter* f) @dynamic
{
	char[STRING_LEN] text = self.to_string();
	return f.print((String)text[..]);
}

// -------------------------------------------------------------------------
// Reading one
// -------------------------------------------------------------------------

<*
 The version digit, for an id whose `variant` is `RFC9562`: 4 for `random`,
 5 for `from_name`, 7 for `sortable`. Meaningless for one made with
 `from_bytes`.
*>
fn char Uuid.version(self)
{
	return self.bytes[6] >> 4;
}

<*
 Which family the id belongs to. Everything minted here is `RFC9562`.
*>
fn Variant Uuid.variant(self)
{
	char byte = self.bytes[8];
	if ((byte & 0x80) == 0x00) return NCS;
	if ((byte & 0xC0) == 0x80) return RFC9562;
	if ((byte & 0xE0) == 0xC0) return MICROSOFT;
	return RESERVED;
}

<*
 When a `sortable` id was made, in milliseconds since the Unix epoch, or
 `NO_TIMESTAMP` for any other version.

 Only version 7 carries a timestamp this can read. Version 1 has one too, but
 counts hundreds of nanoseconds from 1582 with its fields split across the
 id, and nothing here mints one.
*>
fn long? Uuid.timestamp(self)
{
	if (self.version() != 7) return NO_TIMESTAMP~;
	long ms = 0;
	foreach (byte : self.bytes[:6]) ms = (ms << 8) | byte;
	return ms;
}

fn bool Uuid.is_nil(self)
{
	return self.equals(NIL);
}

fn bool Uuid.is_max(self)
{
	return self.equals(MAX);
}

<*
 The methods `equals`, `compare_to` and `hash` are the three the standard
 library looks for: `equals` is what `test::eq` and `HashMap` use to compare,
 `compare_to` is what `sort::quicksort` can be handed, and `hash` is what
 lets a `Uuid` be a `HashMap` key.
*>
fn bool Uuid.equals(self, Uuid other)
{
	return self.bytes == other.bytes;
}

<*
 Byte order, which for these bytes is also numeric order - and, for
 `sortable` ids, the order they were made in. Negative, zero or positive, as
 `compare_to` is everywhere in C3.
*>
fn int Uuid.compare_to(self, Uuid other)
{
	foreach (i, byte : self.bytes)
	{
		if (byte != other.bytes[i]) return byte < other.bytes[i] ? -1 : 1;
	}
	return 0;
}

fn bool Uuid.less(self, Uuid other)
{
	return self.compare_to(other) < 0;
}

<*
 A 32-bit hash of the bytes, which is the width `HashMap` asks a key for.
 FNV-1a, because sixteen bytes is too short for anything cleverer to matter.
*>
fn uint Uuid.hash(self)
{
	uint h = 0x811C9DC5;
	foreach (byte : self.bytes)
	{
		h ^= byte;
		h *= 0x01000193;
	}
	return h;
}

// The comparison in the shape `sort::quicksort` wants: a function, not a
// method, over two values.
fn int compare(Uuid a, Uuid b)
{
	return a.compare_to(b);
}

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

import std::collections::map;
import std::sort;

const String SAMPLE_TEXT = "f81d4fae-7dec-11d0-a765-00a0c91e6bf6";
const char[16] SAMPLE_BYTES = {
	0xF8, 0x1D, 0x4F, 0xAE, 0x7D, 0xEC, 0x11, 0xD0,
	0xA7, 0x65, 0x00, 0xA0, 0xC9, 0x1E, 0x6B, 0xF6,
};

macro @expect_text(#actual, String expected)
{
	var got = #actual;
	test::eq((String)got[..], expected);
}

fn void test_parse_and_print_the_canonical_form() @test
{
	Uuid id = parse(SAMPLE_TEXT)!!;
	test::eq(id.bytes, SAMPLE_BYTES);
	@expect_text(id.to_string(), SAMPLE_TEXT);
	@expect_text(id.to_urn(), "urn:uuid:f81d4fae-7dec-11d0-a765-00a0c91e6bf6");
	// `%s` goes through `to_format`. `tformat` writes into the temporary
	// allocator, which `@pool` opens and closes around the block.
	@pool()
	{
		test::eq(string::tformat("%s", id), SAMPLE_TEXT);
	};
}

fn void test_parse_is_forgiving_about_punctuation_and_case() @test
{
	Uuid id = parse(SAMPLE_TEXT)!!;
	String[] spellings = {
		SAMPLE_TEXT,
		"F81D4FAE-7DEC-11D0-A765-00A0C91E6BF6",
		"f81d4fae7dec11d0a76500a0c91e6bf6",
		"{f81d4fae-7dec-11d0-a765-00a0c91e6bf6}",
		"{F81D4FAE7DEC11D0A76500A0C91E6BF6}",
		"f8-1d-4f-ae-7d-ec-11-d0-a7-65-00-a0-c9-1e-6b-f6",
		"urn:uuid:f81d4fae-7dec-11d0-a765-00a0c91e6bf6",
		"URN:UUID:F81D4FAE-7DEC-11D0-A765-00A0C91E6BF6",
	};
	foreach (text : spellings)
	{
		test::@check(id.equals(parse(text)!!), "spelling %s", text);
	}
	// But printing always gives the one spelling back.
	@expect_text(parse(spellings[1])!!.to_string(), SAMPLE_TEXT);
	@expect_text(id.to_string_case(UPPER), "F81D4FAE-7DEC-11D0-A765-00A0C91E6BF6");
}

fn void test_malformed_text() @test
{
	test::@error(parse(""), INVALID_LENGTH);
	test::@error(parse("f81d4fae"), INVALID_LENGTH);
	test::@error(parse("f81d4fae-7dec-11d0-a765-00a0c91e6bf600"), INVALID_LENGTH);
	test::@error(parse("f81d4fae-7dec-11d0-a765-00a0c91e6bf"), INVALID_LENGTH);
	test::@error(parse("g81d4fae-7dec-11d0-a765-00a0c91e6bf6"), INVALID_CHARACTER);
	test::@error(parse("f81d4fae 7dec 11d0 a765 00a0c91e6bf6"), INVALID_CHARACTER);
	test::@error(parse("urn:uuid:f81d4fae-7dec-11d0-a765-00a0c91e6bf6!"), INVALID_CHARACTER);
	// A great many digits, caught before anything is written past the end.
	char[64] many;
	many[..] = 'f';
	test::@error(parse((String)many[..]), INVALID_LENGTH);
}

fn void test_nil_and_max() @test
{
	test::@check(NIL.is_nil());
	test::@check(MAX.is_max());
	test::@check(!NIL.is_max());
	@expect_text(NIL.to_string(), "00000000-0000-0000-0000-000000000000");
	@expect_text(MAX.to_string(), "ffffffff-ffff-ffff-ffff-ffffffffffff");
	test::@check(parse("00000000-0000-0000-0000-000000000000")!!.is_nil());
	test::@check(!parse(SAMPLE_TEXT)!!.is_nil());
}

fn void test_round_trip_through_bytes_and_integers() @test
{
	Uuid id = parse(SAMPLE_TEXT)!!;
	test::@check(id.equals(from_bytes(id.bytes)));
	test::@check(id.equals(from_int(id.to_int())));
	test::eq(id.to_int(), (uint128)0xF81D4FAE7DEC11D0A76500A0C91E6BF6);

	// The stored order is the printed order, so a memcpy to disk reads back.
	test::eq(id.bytes[0], (char)0xF8);
}

fn void test_random_ids_are_version_4_and_distinct() @test
{
	Sfc64Random prng;
	random::seed(&prng, 0x5EED);

	HashMap{Uuid, bool} seen;
	seen.init(mem);
	defer seen.free();

	for (int i = 0; i < 1000; i++)
	{
		Uuid id = random(&prng);
		test::eq(id.version(), (char)4);
		test::eq(id.variant(), Variant.RFC9562);
		test::@error(id.timestamp(), NO_TIMESTAMP);
		test::@check(!id.is_nil());
		seen.set(id, true);
	}
	test::eq(seen.len(), 1000);
}

fn void test_sortable_ids_carry_the_time_and_sort_by_it() @test
{
	Sfc64Random prng;
	random::seed(&prng, 0x7777);

	const long START = 1_700_000_000_000;
	Uuid previous = sortable(&prng, START);
	test::eq(previous.version(), (char)7);
	test::eq(previous.variant(), Variant.RFC9562);
	test::eq(previous.timestamp()!!, START);

	// A millisecond later is a larger id, whatever chance did with the tail.
	for (long step = 1; step < 500; step++)
	{
		long at = START + step;
		Uuid id = sortable(&prng, at);
		test::eq(id.timestamp()!!, at);
		test::@check(previous.less(id));
		previous = id;
	}
}

fn void test_sortable_saturates_rather_than_wrapping() @test
{
	Sfc64Random prng;
	random::seed(&prng, 1);

	// Before the epoch there is nothing to write.
	test::eq(sortable(&prng, -1).timestamp()!!, 0L);
	test::eq(sortable(&prng, long::min).timestamp()!!, 0L);

	// Past the top of the field, the largest millisecond it can hold - not a
	// small one that would read as the 1970s.
	const long CEILING = 0xFFFF_FFFF_FFFF;
	test::eq(sortable(&prng, CEILING + 1).timestamp()!!, CEILING);
	test::eq(sortable(&prng, long::max).timestamp()!!, CEILING);
}

fn void test_clock_ascends_within_a_millisecond_and_across_a_clock_that_steps_back() @test
{
	Sfc64Random prng;
	random::seed(&prng, 0xC10C);

	Clock clock;
	clock.init();
	const long AT = 1_700_000_000_000;

	// A thousand ids in one millisecond, each after the last.
	Uuid previous = clock.next(&prng, AT);
	for (int i = 0; i < 1000; i++)
	{
		Uuid id = clock.next(&prng, AT);
		test::@check(previous.less(id));
		test::eq(id.version(), (char)7);
		previous = id;
	}

	// The clock steps backwards by a second. The ids do not.
	for (int i = 0; i < 100; i++)
	{
		Uuid id = clock.next(&prng, AT - 1000);
		test::@check(previous.less(id));
		previous = id;
	}

	// And time moving on again is picked straight up.
	Uuid later = clock.next(&prng, AT + 5);
	test::@check(previous.less(later));
	test::eq(later.timestamp()!!, AT + 5);
}

fn void test_clock_keeps_ascending_when_the_counter_runs_out() @test
{
	Sfc64Random prng;
	random::seed(&prng, 2);

	// Start with the counter as high as it goes, so the next id has to borrow
	// a millisecond from the future.
	Clock clock = { .last_ms = 1_000, .counter = 0xFFF };
	Uuid first = clock.next(&prng, 1_000);
	test::eq(first.timestamp()!!, 1_001L);

	Uuid previous = first;
	for (int i = 0; i < 10_000; i++)
	{
		Uuid id = clock.next(&prng, 1_000);
		test::@check(previous.less(id));
		previous = id;
	}
}

fn void test_from_name_gives_the_same_id_every_time() @test
{
	// A namespace of this project's own, not one of the RFC's.
	const Uuid ASSETS = @parse("2f8a1c40-6d3e-4b17-9f22-c1a5e7b90d34");
	Uuid cursor = from_name(ASSETS, "textures/ui/cursor.png");

	test::@check(cursor.equals(from_name(ASSETS, "textures/ui/cursor.png")));
	test::eq(cursor.version(), (char)5);
	test::eq(cursor.variant(), Variant.RFC9562);

	// A different name, or the same name in a different namespace, is a
	// different id.
	test::@check(!cursor.equals(from_name(ASSETS, "textures/ui/cursor2.png")));
	test::@check(!cursor.equals(from_name(NAMESPACE_DNS, "textures/ui/cursor.png")));
}

fn void test_from_name_matches_the_rfcs_own_example() @test
{
	// RFC 9562 appendix: the DNS namespace over "www.example.com".
	Uuid id = from_name(NAMESPACE_DNS, "www.example.com");
	@expect_text(id.to_string(), "2ed6657d-e927-568b-95e1-2665a8aea6a2");
}

fn void test_namespaces_are_parsed_at_compile_time() @test
{
	@expect_text(NAMESPACE_DNS.to_string(), "6ba7b810-9dad-11d1-80b4-00c04fd430c8");
	const Uuid MINE = @parse(SAMPLE_TEXT);
	test::@check(MINE.equals(parse(SAMPLE_TEXT)!!));
}

fn void test_variants_other_than_the_rfcs_are_recognised_not_minted() @test
{
	test::eq(@parse("00000000-0000-0000-0000-000000000000").variant(), Variant.NCS);
	test::eq(@parse("00000000-0000-0000-8000-000000000000").variant(), Variant.RFC9562);
	test::eq(@parse("00000000-0000-0000-c000-000000000000").variant(), Variant.MICROSOFT);
	test::eq(@parse("00000000-0000-0000-e000-000000000000").variant(), Variant.RESERVED);
	test::eq(MAX.variant(), Variant.RESERVED);
}

fn void test_ordering_and_hashing() @test
{
	Uuid a = parse("00000000-0000-0000-0000-000000000001")!!;
	Uuid b = parse("00000000-0000-0000-0000-000000000002")!!;

	test::@check(a.less(b));
	test::@check(!b.less(a));
	test::eq(a.compare_to(b), -1);
	test::eq(a.compare_to(a), 0);
	test::eq(a.hash(), parse("00000000-0000-0000-0000-000000000001")!!.hash());

	// Byte order is numeric order, so sorting ids sorts their values.
	Uuid[4] ids = { b, NIL, a, MAX };
	sort::quicksort(ids[..], &compare);
	test::@check(ids[0].is_nil());
	test::@check(ids[1].equals(a));
	test::@check(ids[2].equals(b));
	test::@check(ids[3].is_max());
}

fn void test_works_as_a_value_and_as_a_map_key() @test
{
	HashMap{Uuid, uint} map;
	map.init(mem);
	defer map.free();

	Uuid id = parse(SAMPLE_TEXT)!!;
	map.set(id, 7);
	// The same id arrived at a different way must hit the same slot.
	test::eq(map.get(parse("F81D4FAE7DEC11D0A76500A0C91E6BF6")!!)!!, 7U);
	test::@check(id.equals(from_bytes(SAMPLE_BYTES)));

	// It copies like an integer, so a copy is independent.
	Uuid copy = id;
	copy.bytes[0] = 0;
	test::eq(id.bytes[0], (char)0xF8);
}
