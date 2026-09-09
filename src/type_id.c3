// SPDX-License-Identifier: CC0-1.0

// A `Uuid` with the type of the thing written in front of it.
//
// A bare UUID in a log line, a URL bar or a bug report says nothing about
// what it points at, and an id pasted from the wrong column looks exactly
// like a right one. A type id says both:
//
//   user_01h455vb4pex5vsknk084sn02q
//   ^^^^ ^
//   |    the same 128 bits, in Crockford base32
//   what they name
//
// The layout is the TypeID specification: a prefix of up to 63 characters
// from `a`-`z` and `_`, an underscore, and 26 base32 digits holding a
// `Uuid`. An empty prefix is allowed, and then the underscore goes too.
//
// Three things fall out of that shape:
//
//   * A wrong id is caught by eye, and by `Kind`, instead of turning into a
//     lookup that quietly finds nothing.
//   * The digits ascend with the alphabet and a version 7 `Uuid` starts with
//     its timestamp, so sorting the text sorts by when the ids were made.
//   * The text survives a URL, a shell, a filename and being read aloud,
//     which base64 and the dashed UUID form do not.
//
// It is a value, prefix and all: 80 bytes with nothing to allocate. The unused
// tail of the prefix is always zeroed, so two ids holding the same text are
// identical byte-for-byte.
//
// The module is `type_id` and not `typeid`, because `typeid` is a C3 type -
// the run-time name of a type - and a module cannot borrow a keyword.
module fluxion::id::type_id;
import fluxion::id::base32, fluxion::id::uuid;
import std::math::random;
import std::io;

struct TypeId (Printable)
{
	// The prefix, padded with zeroes. Read it with `prefix`.
	char[MAX_PREFIX_LEN] prefix_bytes;
	char prefix_len;
	// The 128 bits the id actually names. The specification calls for a
	// version 7 `Uuid` - see `Kind.sortable` - but any id round-trips, because
	// a store full of version 4 ids is not a reason to be unable to print
	// them.
	Uuid uuid;
}

// As long a prefix as the specification allows.
const MAX_PREFIX_LEN = 63;

// How many base32 digits sixteen bytes take.
const SUFFIX_LEN = base32::ENCODED_LEN;

// The longest text form: prefix, underscore, suffix.
const MAX_STRING_LEN = MAX_PREFIX_LEN + 1 + SUFFIX_LEN;

// More than 63 characters.
faultdef PREFIX_TOO_LONG;

// Something other than `a`-`z` and `_`, or an underscore at either end.
// Uppercase and digits are not allowed, so an id has one spelling.
faultdef INVALID_PREFIX;

// The part after the last underscore was not 26 characters from Crockford's
// alphabet.
faultdef INVALID_SUFFIX;

// Twenty-six valid digits that name more than 128 bits, which is any suffix
// starting above `7`.
faultdef SUFFIX_OVERFLOW;

// A well-formed id, of some other kind. See `Kind.parse`.
faultdef WRONG_PREFIX;

// -------------------------------------------------------------------------
// Making one
// -------------------------------------------------------------------------

<*
 Bind `prefix_text` to `uuid`.

     TypeId id = type_id::init("user", uuid::sortable(rng, now))!;

 A free function rather than a method, because there is no `TypeId` yet to
 call one on, and an optional, because the prefix is text and text can be
 wrong.
*>
fn TypeId? init(String prefix_text, Uuid uuid)
{
	check_prefix(prefix_text)!;
	return init_unchecked(prefix_text, uuid);
}

// For a prefix already known to be good, which is every prefix that came
// from `check_prefix` or out of a `TypeId`.
fn TypeId init_unchecked(String prefix_text, Uuid uuid) @private
{
	TypeId self = { .prefix_len = (char)prefix_text.len, .uuid = uuid };
	mem::copy(&self.prefix_bytes, prefix_text.ptr, prefix_text.len);
	return self;
}

// What the specification allows: `a`-`z` and `_`, at most 63 of them, and
// not an underscore at either end. Empty is allowed and means an id with no
// prefix and no underscore.
fn void? check_prefix(String text) @private
{
	if (text.len > MAX_PREFIX_LEN) return PREFIX_TOO_LONG~;
	if (text.len == 0) return;
	if (text[0] == '_' || text[^1] == '_') return INVALID_PREFIX~;
	foreach (c : text)
	{
		if (!((c >= 'a' && c <= 'z') || c == '_')) return INVALID_PREFIX~;
	}
}

<*
 One kind of id, with its prefix fixed at compile time.

     const Kind USER = type_id::@kind("user");
     const Kind ORDER = type_id::@kind("order");

     TypeId alice = USER.sortable(rng, now);
     TypeId cart = ORDER.parse(text)!;   // WRONG_PREFIX if it is a user's

 A misspelled prefix is a compile error rather than a run-time one, and
 `parse` refuses an id of the wrong kind rather than handing back something
 that will fail its lookup later.

 In Zig this was a function returning a type. C3 generics take types and
 numbers as parameters but not strings, so a kind is a value instead: a
 struct holding the prefix, made by a macro that checks the text while the
 program is being compiled and folds to a constant. `USER` and `ORDER` are
 both `Kind`s and both produce a `TypeId`; the check happens where the text
 comes in. `Handle` is the identifier here that the compiler itself tells
 apart.
*>
struct Kind
{
	String prefix;
}

macro Kind @kind(String $prefix) @const
{
	$if $prefix.len > MAX_PREFIX_LEN:
		$error("fluxion-id: type id prefix longer than 63 characters: " +++ $prefix);
	$endif
	$if $prefix.len > 0 &&& ($prefix[0] == '_' ||| $prefix[$prefix.len - 1] == '_'):
		$error("fluxion-id: type id prefix may not start or end with an underscore: " +++ $prefix);
	$endif
	$for var $i = 0; $i < $prefix.len; $i++:
		$if !(($prefix[$i] >= 'a' && $prefix[$i] <= 'z') || $prefix[$i] == '_'):
			$error("fluxion-id: type id prefix may only hold a-z and _: " +++ $prefix);
		$endif
	$endfor
	return (Kind){ .prefix = $prefix };
}

<*
 A fresh time-ordered id, which is what the specification asks for.
*>
fn TypeId Kind.sortable(self, Random rng, long unix_ms)
{
	return init_unchecked(self.prefix, uuid::sortable(rng, unix_ms));
}

<*
 This kind's prefix over a uuid from somewhere else.
*>
fn TypeId Kind.of(self, Uuid uuid)
{
	return init_unchecked(self.prefix, uuid);
}

<*
 Parse, and insist the id is one of these.
*>
fn TypeId? Kind.parse(self, String text)
{
	TypeId id = parse(text)!;
	if (!id.has_prefix(self.prefix)) return WRONG_PREFIX~;
	return id;
}

<*
 Whether an id already in hand is one of these.
*>
fn bool Kind.matches(self, TypeId id)
{
	return id.has_prefix(self.prefix);
}

// -------------------------------------------------------------------------
// Text
// -------------------------------------------------------------------------

<*
 Read the text form.

 The split is at the *last* underscore, because a prefix may contain
 underscores and a suffix may not: `db_user_01h4...` is a `db_user`.
 Everything else is exact - one case, one alphabet, one length - so an id has
 a single spelling and two ids that print the same are the same.
*>
fn TypeId? parse(String text)
{
	String prefix_text = "";
	String suffix_text = text;
	if (try cut = text.rindex_of_char('_'))
	{
		prefix_text = text[:cut];
		suffix_text = text[cut + 1..];
		// A leading underscore is a stray underscore, not an empty prefix.
		if (prefix_text.len == 0) return INVALID_PREFIX~;
	}
	check_prefix(prefix_text)!;

	if (suffix_text.len != SUFFIX_LEN) return INVALID_SUFFIX~;
	// `if (catch err = ...)` is the branch for the empty side of an optional:
	// the fault lands in `err`, and here it is translated into this module's
	// own vocabulary rather than passed up as base32's.
	char[16]? bytes = base32::decode(suffix_text);
	if (catch err = bytes)
	{
		return err == base32::OVERFLOW ? SUFFIX_OVERFLOW~ : INVALID_SUFFIX~;
	}
	// Past the `if (catch)`, which returned, `bytes` is a plain `char[16]`:
	// the compiler has seen that the empty case cannot reach here.
	return init_unchecked(prefix_text, uuid::from_bytes(bytes));
}

<*
 Parse a literal at compile time, so a malformed one is a compile error
 rather than something to handle at run time:

     const TypeId HULL = type_id::@parse("mesh_01h455vb4pex5vsknk084sn02q");

 The same `$`-variable walk as `uuid::@parse`, with the base32 digits
 folded into a 128-bit compile-time integer.
*>
macro TypeId @parse(String $text) @const
{
	var $cut = -1;
	$for var $i = 0; $i < $text.len; $i++:
		$if $text[$i] == '_':
			$cut = $i;
		$endif
	$endfor
	$if $cut == 0:
		$error("fluxion-id: type id starts with a stray underscore: " +++ $text);
	$endif
	// A ternary is checked on both arms at compile time, and a negative slice
	// index is an error even on the arm not taken - hence the `$if`. And a
	// `$if` is a scope, so the variables are declared outside it.
	var $prefix = "";
	var $suffix = $text;
	$if $cut >= 0:
		$prefix = $text[:$cut];
		$suffix = $text[$cut + 1..];
	$endif
	var $kind = @kind($prefix);
	$if $suffix.len != SUFFIX_LEN:
		$error("fluxion-id: type id suffix is not 26 digits: " +++ $text);
	$endif

	var $value = (uint128)0;
	$for var $i = 0; $i < SUFFIX_LEN; $i++:
		var $digit = base32::VALUES[$suffix[$i]];
		$if $digit == 0xFF:
			$error("fluxion-id: type id suffix holds a character outside Crockford's alphabet: " +++ $text);
		$endif
		$if $i == 0 &&& $digit > 7:
			$error("fluxion-id: type id suffix names more than 128 bits: " +++ $text);
		$endif
		$value = ($value << 5) | $digit;
	$endfor

	// A compile-time struct cannot be assigned into field by field, so the
	// two arrays are built first and the struct is written once, whole.
	var $prefix_bytes = (char[MAX_PREFIX_LEN]){};
	$for var $i = 0; $i < $prefix.len; $i++:
		$prefix_bytes[$i] = $prefix[$i];
	$endfor
	var $uuid_bytes = (char[16]){};
	$for var $i = 0; $i < 16; $i++:
		$uuid_bytes[$i] = (char)($value >> (8 * (15 - $i)));
	$endfor
	return (TypeId){
		.prefix_bytes = $prefix_bytes,
		.prefix_len = (char)$prefix.len,
		.uuid = { .bytes = $uuid_bytes },
	};
}

<*
 The prefix, without the underscore. Empty for an id that has none.

 Takes the address because the bytes live inside the value: a slice of a
 copy would point at a temporary. Calling it on a variable is `id.prefix()`
 either way; C3 takes the address for you.
*>
fn String TypeId.prefix(&self)
{
	return (String)self.prefix_bytes[:self.prefix_len];
}

fn bool TypeId.has_prefix(&self, String text)
{
	return self.prefix() == text;
}

<*
 The 26 digits after the underscore, held by value.
*>
fn char[SUFFIX_LEN] TypeId.suffix(self)
{
	return base32::encode(self.uuid.bytes);
}

<*
 How many bytes `to_string` will write.
*>
fn sz TypeId.string_len(self)
{
	return self.prefix_len == 0 ? SUFFIX_LEN : (sz)self.prefix_len + 1 + SUFFIX_LEN;
}

<*
 Write the text form into `buf`, and return the part of it that was used.

 A caller's buffer rather than a returned array, because the length varies
 with the prefix: an array would be mostly padding, and a slice of one
 returned by value would point at a temporary. `%s` covers the common case of
 printing an id without wanting the bytes.
*>
fn String TypeId.to_string(&self, char[MAX_STRING_LEN]* buf)
{
	String prefix_text = self.prefix();
	mem::copy(buf, prefix_text.ptr, prefix_text.len);

	sz used = prefix_text.len;
	if (used != 0)
	{
		(*buf)[used] = '_';
		used++;
	}
	char[SUFFIX_LEN] digits = self.suffix();
	mem::copy(&(*buf)[used], &digits, SUFFIX_LEN);
	return (String)(*buf)[:used + SUFFIX_LEN];
}

<*
 What `%s` prints.
*>
fn sz? TypeId.to_format(&self, Formatter* f) @dynamic
{
	char[MAX_STRING_LEN] buf;
	return f.print(self.to_string(&buf));
}

// -------------------------------------------------------------------------
// Reading one
// -------------------------------------------------------------------------

<*
 When the id was made, for the version 7 uuid the specification asks for.
 `NO_TIMESTAMP` for any other version. See `Uuid.timestamp`.
*>
fn long? TypeId.timestamp(self)
{
	return self.uuid.timestamp();
}

fn bool TypeId.equals(&self, TypeId other)
{
	return self.uuid.equals(other.uuid) && self.has_prefix(other.prefix());
}

<*
 Prefix first, then the uuid - which is exactly the order the text forms sort
 in, because `_` comes before every letter a prefix may hold. So ids group by
 kind, and inside a kind they are in the order they were made.
*>
fn int TypeId.compare_to(&self, TypeId other)
{
	int by_prefix = self.prefix().compare_to(other.prefix());
	return by_prefix != 0 ? by_prefix : self.uuid.compare_to(other.uuid);
}

fn bool TypeId.less(&self, TypeId other)
{
	return self.compare_to(other) < 0;
}

fn uint TypeId.hash(&self)
{
	// The prefix and the bytes through one FNV-1a, so that the same uuid
	// under two prefixes lands on two hashes.
	uint h = 0x811C9DC5;
	foreach (c : self.prefix())
	{
		h ^= c;
		h *= 0x01000193;
	}
	foreach (byte : self.uuid.bytes)
	{
		h ^= byte;
		h *= 0x01000193;
	}
	return h;
}

fn int compare(TypeId a, TypeId b)
{
	return a.compare_to(b);
}

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

import std::collections::map;
import std::sort;

// The example from the TypeID specification.
const String SAMPLE_TEXT = "prefix_01h455vb4pex5vsknk084sn02q";
const String SAMPLE_UUID_TEXT = "01890a5d-ac96-774b-bcce-b302099a8057";
const Uuid SAMPLE_UUID = uuid::@parse("01890a5d-ac96-774b-bcce-b302099a8057");

fn void expect_prints(String expected, TypeId id)
{
	char[MAX_STRING_LEN] buf;
	test::eq(id.to_string(&buf), expected);
	@pool()
	{
		test::eq(string::tformat("%s", id), expected);
	};
	test::eq(id.string_len(), expected.len);
}

fn void test_the_specifications_own_example() @test
{
	TypeId id = parse(SAMPLE_TEXT)!!;
	test::eq(id.prefix(), "prefix");
	char[uuid::STRING_LEN] uuid_text = id.uuid.to_string();
	test::eq((String)uuid_text[..], SAMPLE_UUID_TEXT);
	expect_prints(SAMPLE_TEXT, id);

	// And the other way round.
	TypeId built = init("prefix", SAMPLE_UUID)!!;
	test::@check(built.equals(id));
	expect_prints(SAMPLE_TEXT, built);
}

fn void test_an_id_with_no_prefix_has_no_underscore_either() @test
{
	TypeId id = init("", uuid::NIL)!!;
	expect_prints("00000000000000000000000000", id);
	test::eq(id.prefix(), "");

	TypeId read_back = parse("00000000000000000000000000")!!;
	test::@check(read_back.equals(id));
	test::@check(read_back.uuid.is_nil());
}

fn void test_prefixes_may_contain_underscores_and_the_split_is_at_the_last_one() @test
{
	TypeId id = parse("db_user_01h455vb4pex5vsknk084sn02q")!!;
	test::eq(id.prefix(), "db_user");
	char[uuid::STRING_LEN] uuid_text = id.uuid.to_string();
	test::eq((String)uuid_text[..], SAMPLE_UUID_TEXT);
	expect_prints("db_user_01h455vb4pex5vsknk084sn02q", id);

	char[MAX_PREFIX_LEN] longest;
	longest[..] = 'a';
	String long_prefix = (String)longest[..];
	char[MAX_STRING_LEN] expected;
	mem::copy(&expected, long_prefix.ptr, MAX_PREFIX_LEN);
	mem::copy(&expected[MAX_PREFIX_LEN], "_00000000000000000000000000".ptr, 1 + SUFFIX_LEN);
	expect_prints((String)expected[..], init(long_prefix, uuid::NIL)!!);
}

fn void test_bad_prefixes() @test
{
	char[MAX_PREFIX_LEN + 1] too_long;
	too_long[..] = 'a';
	test::@error(init((String)too_long[..], uuid::NIL), PREFIX_TOO_LONG);
	test::@error(init("_user", uuid::NIL), INVALID_PREFIX);
	test::@error(init("user_", uuid::NIL), INVALID_PREFIX);
	test::@error(init("User", uuid::NIL), INVALID_PREFIX);
	test::@error(init("user2", uuid::NIL), INVALID_PREFIX);
	test::@error(init("user-name", uuid::NIL), INVALID_PREFIX);
	test::@error(init("user name", uuid::NIL), INVALID_PREFIX);

	// The same rules on the way in from text.
	test::@error(parse("_01h455vb4pex5vsknk084sn02q"), INVALID_PREFIX);
	test::@error(parse("User_01h455vb4pex5vsknk084sn02q"), INVALID_PREFIX);
	char[MAX_PREFIX_LEN + 1 + 1 + SUFFIX_LEN] text;
	mem::copy(&text, &too_long, MAX_PREFIX_LEN + 1);
	mem::copy(&text[MAX_PREFIX_LEN + 1], "_01h455vb4pex5vsknk084sn02q".ptr, 1 + SUFFIX_LEN);
	test::@error(parse((String)text[..]), PREFIX_TOO_LONG);
}

fn void test_bad_suffixes() @test
{
	test::@error(parse(""), INVALID_SUFFIX);
	test::@error(parse("user_"), INVALID_SUFFIX);
	test::@error(parse("user_01h455vb4pex5vsknk084sn02"), INVALID_SUFFIX);
	test::@error(parse("user_01h455vb4pex5vsknk084sn02qq"), INVALID_SUFFIX);
	// `i`, `l`, `o` and `u` are not digits, and neither is uppercase.
	test::@error(parse("user_01h455vb4pex5vsknk084sn02i"), INVALID_SUFFIX);
	test::@error(parse("user_01H455VB4PEX5VSKNK084SN02Q"), INVALID_SUFFIX);
	// Twenty-six good digits naming more than 128 bits.
	test::@error(parse("user_8zzzzzzzzzzzzzzzzzzzzzzzzz"), SUFFIX_OVERFLOW);
}

fn void test_round_trip_over_ids_that_are_not_all_zeroes() @test
{
	Sfc64Random prng;
	random::seed(&prng, 0x71D);
	char[MAX_STRING_LEN] buf;

	for (long step = 0; step < 1000; step++)
	{
		TypeId id = init("asset", uuid::sortable(&prng, 1_700_000_000_000 + step))!!;
		String printed = id.to_string(&buf);
		TypeId read_back = parse(printed)!!;
		test::@check(read_back.equals(id));
		test::eq(read_back.timestamp()!!, id.timestamp()!!);
	}
}

fn void test_sorting_the_values_is_sorting_the_text() @test
{
	Sfc64Random prng;
	random::seed(&prng, 0x5027);

	String[] prefixes = { "", "a", "a_b", "ab", "user", "user_role", "z" };
	TypeId[7 * 4] ids;
	sz at = 0;
	foreach (prefix_text : prefixes)
	{
		for (long step = 0; step < 4; step++)
		{
			ids[at] = init(prefix_text, uuid::sortable(&prng, 1_700_000_000_000 + step))!!;
			at++;
		}
	}

	sort::quicksort(ids[..], &compare);

	// Printed in order, the strings are in order too - so a database that
	// sorts these as text agrees with one that sorts them as values.
	char[MAX_STRING_LEN] previous_buf;
	String previous = "";
	foreach (&id : ids)
	{
		char[MAX_STRING_LEN] buf;
		String text = id.to_string(&buf);
		test::@check(text.compare_to(previous) >= 0);
		mem::copy(&previous_buf, text.ptr, text.len);
		previous = (String)previous_buf[:text.len];
	}

	// The empty prefix sorts first, and within one kind the ids are in the
	// order they were made.
	test::eq(ids[0].prefix(), "");
	test::@check(ids[0].less(ids[1]));
}

const Kind USER = @kind("user");
const Kind ORDER = @kind("order");

fn void test_kind_fixes_the_prefix_and_refuses_the_others() @test
{
	Sfc64Random prng;
	random::seed(&prng, 0x11D);

	TypeId alice = USER.sortable(&prng, 1_700_000_000_000);
	test::eq(alice.prefix(), "user");
	test::eq(alice.uuid.version(), (char)7);
	test::@check(USER.matches(alice));
	test::@check(!ORDER.matches(alice));

	char[MAX_STRING_LEN] buf;
	String text = alice.to_string(&buf);
	test::@check(USER.parse(text)!!.equals(alice));
	test::@error(ORDER.parse(text), WRONG_PREFIX);

	// A malformed id is still malformed, whichever kind was expected.
	test::@error(USER.parse("user_nope"), INVALID_SUFFIX);

	// And `of` puts this kind's prefix on an id from somewhere else.
	TypeId imported = ORDER.of(SAMPLE_UUID);
	expect_prints("order_01h455vb4pex5vsknk084sn02q", imported);
}

fn void test_parsed_at_compile_time() @test
{
	const TypeId ID = @parse("prefix_01h455vb4pex5vsknk084sn02q");
	test::eq(ID.prefix(), "prefix");
	test::@check(ID.equals(parse(SAMPLE_TEXT)!!));
	const TypeId BARE = @parse("00000000000000000000000000");
	test::@check(BARE.uuid.is_nil());
	test::eq(BARE.prefix(), "");
}

fn void test_works_as_a_value_and_as_a_map_key() @test
{
	HashMap{TypeId, uint} map;
	map.init(mem);
	defer map.free();

	TypeId id = parse(SAMPLE_TEXT)!!;
	map.set(id, 7);
	test::eq(map.get(parse(SAMPLE_TEXT)!!)!!, 7U);

	// The padding is always zeroed, so equal ids are equal bytes.
	TypeId same = init("prefix", SAMPLE_UUID)!!;
	test::@check(id.equals(same));
	test::eq(id.prefix_bytes, same.prefix_bytes);
	test::eq(id.hash(), same.hash());

	// A different kind of the same uuid is a different id.
	TypeId other = init("prefixx", SAMPLE_UUID)!!;
	test::@check(!other.equals(id));
	test::ne(other.hash(), id.hash());
	test::@check(!map.has_key(other));
}
