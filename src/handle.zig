// SPDX-License-Identifier: CC0-1.0

//! Handles: an index and a generation, in eight bytes.
//!
//! A `Uuid` is a name a thing keeps forever, anywhere. A handle is the
//! opposite trade: it means something only inside one `Table`, in one
//! process, for as long as that entry lives - and in exchange it costs eight
//! bytes, no random number generator, and a bounds check to resolve.
//!
//! The obvious version of this is a plain index, and the obvious version is
//! broken. Remove entry 7, add another, and every index 7 still held anywhere
//! now points at the new entry: a dangling reference with no pointer in
//! sight, and no crash to tell you. The generation counter is the fix. Each
//! slot counts how many times it has been used; a handle remembers which time
//! it was made for; `get` compares the two and hands back null when they have
//! parted company.
//!
//! ```zig
//! var meshes: handle.Table(Mesh) = .empty;
//! defer meshes.deinit(gpa);
//!
//! const hull = try meshes.add(gpa, mesh);
//! meshes.get(hull).?.scale = 2;
//!
//! _ = meshes.remove(hull);
//! meshes.get(hull);           // null, even after the slot is handed out again
//! ```
//!
//! `Handle(T)` carries the type of what it points at, so a `Handle(Mesh)` and
//! a `Handle(Texture)` are different Zig types and the compiler refuses to
//! swap them. That costs nothing at runtime: both are a `u64`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;

/// A handle to a `T`, in a `Table(T)`.
///
/// The index says which slot; the generation says which occupant of it.
/// Generation 0 is never handed out, so a zeroed handle - one in a struct
/// that was memset, or built with `std.mem.zeroes` - reads as `none` rather
/// than as a live reference to slot zero.
///
/// It is a `u64` and behaves like one: copy it, compare it with `std.meta.eql`
/// or `eql`, use it as a `std.AutoHashMap` key, put it in a component array.
/// Handles from two different tables of the same type are not
/// interchangeable, and nothing here can tell them apart - keep the table and
/// its handles together.
pub fn Handle(comptime T: type) type {
    return packed struct(u64) {
        index: u32,
        generation: u32,

        const Self = @This();

        /// What this handle points at, so generic code can ask.
        pub const Target = T;

        /// No entry. Also what all-zero bytes mean.
        pub const none: Self = .{ .index = 0, .generation = 0 };

        pub fn isNone(self: Self) bool {
            return self.generation == 0;
        }

        pub fn eql(self: Self, other: Self) bool {
            return self.toInt() == other.toInt();
        }

        /// The eight bytes as one number, for storing in a format that has no
        /// room for a struct.
        pub fn toInt(self: Self) u64 {
            return @bitCast(self);
        }

        pub fn fromInt(value: u64) Self {
            return @bitCast(value);
        }

        /// Print with `{f}`: `#7v2` is the third occupant of slot seven.
        pub fn format(self: Self, w: *std.Io.Writer) std.Io.Writer.Error!void {
            if (self.isNone()) return w.writeAll("#none");
            try w.print("#{d}v{d}", .{ self.index, self.generation });
        }
    };
}

/// Storage that hands out `Handle(T)` and answers them.
///
/// Entries keep their slot for life, so a handle stays valid however much is
/// added or removed around it - unlike an index into an `ArrayList`, which
/// moves the moment something before it is taken out. Removal leaves the slot
/// in place with its generation stepped, and the next `add` takes it back.
///
/// The free slots are chained through each other: a slot that holds nothing
/// has nothing better to do with its bytes than name the next free one. So
/// removal never allocates, and the table is exactly one allocation.
pub fn Table(comptime T: type) type {
    const H = Handle(T);

    return struct {
        const Self = @This();

        /// The handle this table hands out. `Table(Mesh).Handle` is
        /// `handle.Handle(Mesh)`.
        pub const Handle = H;

        slots: std.ArrayList(Slot) = .empty,
        /// The first slot of the free chain, or `end_of_chain`.
        first_free: u32 = end_of_chain,
        /// How many slots hold something. Kept rather than counted, because
        /// counting means walking every slot.
        live: usize = 0,

        /// One less than the number of slots there could ever be, so it can
        /// mean "no next" without costing an optional per slot.
        const end_of_chain = std.math.maxInt(u32);

        const Slot = struct {
            /// How many occupants this slot has had. Starts at 1 and steps on
            /// every removal, skipping 0 so it never collides with `none`.
            generation: u32,
            /// While the slot is free, the next free slot. Ignored while it
            /// holds a value.
            next_free: u32,
            value: ?T,
        };

        pub const empty: Self = .{};

        pub fn deinit(self: *Self, gpa: Allocator) void {
            self.slots.deinit(gpa);
            self.* = undefined;
        }

        // -----------------------------------------------------------------
        // Changing it
        // -----------------------------------------------------------------

        /// Store `value` and return the handle to it. Reuses a free slot when
        /// there is one, which is why the generation matters.
        pub fn add(self: *Self, gpa: Allocator, value: T) Allocator.Error!H {
            if (self.first_free != end_of_chain) {
                const index = self.first_free;
                const slot = &self.slots.items[index];
                self.first_free = slot.next_free;
                slot.value = value;
                self.live += 1;
                return .{ .index = index, .generation = slot.generation };
            }

            // A table cannot hold more slots than an index can name.
            if (self.slots.items.len >= end_of_chain) return error.OutOfMemory;
            const index: u32 = @intCast(self.slots.items.len);
            try self.slots.append(gpa, .{
                .generation = 1,
                .next_free = end_of_chain,
                .value = value,
            });
            self.live += 1;
            return .{ .index = index, .generation = 1 };
        }

        /// Take the entry out and hand it back, or null if the handle was
        /// already stale. The slot goes on the free chain with its generation
        /// stepped, so every handle to what used to be there stops resolving
        /// at the same moment.
        ///
        /// A slot that has been through 2^32 occupants starts its generations
        /// again, and a handle kept across all of that could match a stranger.
        /// Four billion removals of one slot is a long way past the point
        /// where a handle should have been dropped, but it is not never.
        pub fn remove(self: *Self, h: H) ?T {
            if (self.get(h) == null) return null;

            const slot = &self.slots.items[h.index];
            const taken = slot.value.?;
            slot.value = null;
            slot.generation +%= 1;
            if (slot.generation == 0) slot.generation = 1;
            slot.next_free = self.first_free;
            self.first_free = h.index;
            self.live -= 1;
            return taken;
        }

        /// Empty the table, keeping the slots.
        ///
        /// The slots stay because the generations live in them: throwing them
        /// away would let the next `add` hand out a handle that an old one
        /// compares equal to.
        pub fn clearRetainingCapacity(self: *Self) void {
            self.first_free = end_of_chain;
            // Backwards, so the chain comes out in ascending order and slots
            // are reused in the order they were first made.
            var index = self.slots.items.len;
            while (index > 0) {
                index -= 1;
                const slot = &self.slots.items[index];
                if (slot.value != null) {
                    slot.value = null;
                    slot.generation +%= 1;
                    if (slot.generation == 0) slot.generation = 1;
                }
                slot.next_free = self.first_free;
                self.first_free = @intCast(index);
            }
            self.live = 0;
        }

        // -----------------------------------------------------------------
        // Reading it
        // -----------------------------------------------------------------

        /// What `h` points at, or null if it points at nothing any more.
        ///
        /// The pointer is into the table's storage, so it survives until the
        /// next `add` grows it. Hold the handle, not the pointer.
        pub fn get(self: *Self, h: H) ?*T {
            const slot = self.liveSlot(h) orelse return null;
            return &slot.value.?;
        }

        pub fn getConst(self: *const Self, h: H) ?*const T {
            if (h.generation == 0 or h.index >= self.slots.items.len) return null;
            const slot = &self.slots.items[h.index];
            if (slot.generation != h.generation) return null;
            if (slot.value == null) return null;
            return &slot.value.?;
        }

        pub fn contains(self: *const Self, h: H) bool {
            return self.getConst(h) != null;
        }

        /// How many entries the table holds.
        pub fn count(self: *const Self) usize {
            return self.live;
        }

        /// How many slots exist, live and free together. The high-water mark
        /// of `count`, near enough.
        pub fn slotCount(self: *const Self) usize {
            return self.slots.items.len;
        }

        fn liveSlot(self: *Self, h: H) ?*Slot {
            if (h.generation == 0 or h.index >= self.slots.items.len) return null;
            const slot = &self.slots.items[h.index];
            if (slot.generation != h.generation) return null;
            if (slot.value == null) return null;
            return slot;
        }

        /// Walks the live entries in slot order, handing back each handle
        /// alongside its value. Adding or removing during the walk invalidates
        /// it, as with any container.
        pub fn iterator(self: *Self) Iterator {
            return .{ .table = self };
        }

        pub const Iterator = struct {
            table: *Self,
            index: u32 = 0,

            pub const Entry = struct {
                handle: H,
                value: *T,
            };

            pub fn next(self: *Iterator) ?Entry {
                while (self.index < self.table.slots.items.len) {
                    const index = self.index;
                    self.index += 1;
                    const slot = &self.table.slots.items[index];
                    if (slot.value != null) return .{
                        .handle = .{ .index = index, .generation = slot.generation },
                        .value = &slot.value.?,
                    };
                }
                return null;
            }
        };
    };
}

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

const Mesh = struct {
    name: []const u8,
    triangles: u32 = 0,
};

const Texture = struct { name: []const u8 };

test "a handle is eight bytes, and zero means none" {
    try testing.expectEqual(@as(usize, 8), @sizeOf(Handle(Mesh)));
    try testing.expectEqual(@as(u64, 0), Handle(Mesh).none.toInt());
    try testing.expect(Handle(Mesh).none.isNone());
    try testing.expect(Handle(Mesh).fromInt(0).isNone());
    try testing.expect(std.mem.zeroes(Handle(Mesh)).isNone());

    const h: Handle(Mesh) = .{ .index = 7, .generation = 2 };
    try testing.expect(!h.isNone());
    try testing.expect(h.eql(.fromInt(h.toInt())));
    try testing.expectFmt("#7v2", "{f}", .{h});
    try testing.expectFmt("#none", "{f}", .{Handle(Mesh).none});

    // A struct holding one is a value, so a struct full of them is too.
    try testing.expect(std.meta.eql(h, Handle(Mesh){ .index = 7, .generation = 2 }));
}

test "handles to different types are different types" {
    try testing.expect(Handle(Mesh) != Handle(Texture));
    try testing.expect(Table(Mesh).Handle == Handle(Mesh));
    try testing.expect(Handle(Mesh).Target == Mesh);

    // They are the same eight bytes; it is the compiler that keeps them
    // apart, which is the whole point.
    try testing.expectEqual(@sizeOf(Handle(Mesh)), @sizeOf(Handle(Texture)));
}

test "add, get, remove" {
    var meshes: Table(Mesh) = .empty;
    defer meshes.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 0), meshes.count());

    const hull = try meshes.add(testing.allocator, .{ .name = "hull", .triangles = 1200 });
    const wing = try meshes.add(testing.allocator, .{ .name = "wing", .triangles = 300 });
    try testing.expectEqual(@as(usize, 2), meshes.count());

    try testing.expectEqualStrings("hull", meshes.get(hull).?.name);
    try testing.expectEqualStrings("wing", meshes.get(wing).?.name);
    try testing.expect(meshes.contains(hull));

    // The pointer is into the table, so writing through it sticks.
    meshes.get(hull).?.triangles = 1201;
    try testing.expectEqual(@as(u32, 1201), meshes.getConst(hull).?.triangles);

    const taken = meshes.remove(hull).?;
    try testing.expectEqualStrings("hull", taken.name);
    try testing.expectEqual(@as(usize, 1), meshes.count());
    try testing.expect(meshes.get(hull) == null);
    try testing.expect(!meshes.contains(hull));
    // Removing it again says so rather than pretending.
    try testing.expect(meshes.remove(hull) == null);

    // The other handle did not move.
    try testing.expectEqualStrings("wing", meshes.get(wing).?.name);
}

test "a reused slot does not answer the old handle" {
    var meshes: Table(Mesh) = .empty;
    defer meshes.deinit(testing.allocator);

    const first = try meshes.add(testing.allocator, .{ .name = "first" });
    try testing.expectEqual(@as(u32, 0), first.index);
    try testing.expectEqual(@as(u32, 1), first.generation);

    _ = meshes.remove(first);
    const second = try meshes.add(testing.allocator, .{ .name = "second" });

    // Same slot, next generation - which is exactly the case a bare index
    // would get wrong.
    try testing.expectEqual(first.index, second.index);
    try testing.expectEqual(@as(u32, 2), second.generation);
    try testing.expect(!first.eql(second));
    try testing.expect(meshes.get(first) == null);
    try testing.expectEqualStrings("second", meshes.get(second).?.name);

    // And one slot was enough for both.
    try testing.expectEqual(@as(usize, 1), meshes.slotCount());
}

test "handles survive everything moving around them" {
    var meshes: Table(Mesh) = .empty;
    defer meshes.deinit(testing.allocator);

    var handles: [100]Table(Mesh).Handle = undefined;
    for (&handles, 0..) |*h, i| {
        h.* = try meshes.add(testing.allocator, .{ .name = "mesh", .triangles = @intCast(i) });
    }

    // Take out every other one, then put back twice as many, which reuses the
    // freed slots and grows past them.
    var i: usize = 0;
    while (i < handles.len) : (i += 2) {
        try testing.expectEqual(@as(u32, @intCast(i)), meshes.remove(handles[i]).?.triangles);
    }
    for (0..100) |j| {
        _ = try meshes.add(testing.allocator, .{ .name = "later", .triangles = @intCast(j) });
    }

    // Every handle that was not removed still finds what it was given.
    i = 1;
    while (i < handles.len) : (i += 2) {
        try testing.expectEqual(@as(u32, @intCast(i)), meshes.get(handles[i]).?.triangles);
    }
    // And every handle that was removed still finds nothing.
    i = 0;
    while (i < handles.len) : (i += 2) {
        try testing.expect(meshes.get(handles[i]) == null);
    }
    try testing.expectEqual(@as(usize, 150), meshes.count());
}

test "free slots are reused before the table grows" {
    var meshes: Table(Mesh) = .empty;
    defer meshes.deinit(testing.allocator);

    const a = try meshes.add(testing.allocator, .{ .name = "a" });
    const b = try meshes.add(testing.allocator, .{ .name = "b" });
    const c = try meshes.add(testing.allocator, .{ .name = "c" });
    try testing.expectEqual(@as(usize, 3), meshes.slotCount());

    _ = meshes.remove(a);
    _ = meshes.remove(c);
    try testing.expectEqual(@as(usize, 3), meshes.slotCount());

    // The chain is last freed first, so slot 2 comes back before slot 0.
    try testing.expectEqual(@as(u32, 2), (try meshes.add(testing.allocator, .{ .name = "d" })).index);
    try testing.expectEqual(@as(u32, 0), (try meshes.add(testing.allocator, .{ .name = "e" })).index);
    try testing.expectEqual(@as(usize, 3), meshes.slotCount());

    // Only now is there nothing to reuse.
    try testing.expectEqual(@as(u32, 3), (try meshes.add(testing.allocator, .{ .name = "f" })).index);
    try testing.expect(meshes.contains(b));
}

test "clearing keeps the generations" {
    var meshes: Table(Mesh) = .empty;
    defer meshes.deinit(testing.allocator);

    const a = try meshes.add(testing.allocator, .{ .name = "a" });
    _ = try meshes.add(testing.allocator, .{ .name = "b" });

    meshes.clearRetainingCapacity();
    try testing.expectEqual(@as(usize, 0), meshes.count());
    try testing.expectEqual(@as(usize, 2), meshes.slotCount());
    try testing.expect(meshes.get(a) == null);

    // The slots come back in order, but with their generations moved on, so
    // no handle from before the clear resolves.
    const fresh = try meshes.add(testing.allocator, .{ .name = "fresh" });
    try testing.expectEqual(a.index, fresh.index);
    try testing.expect(!a.eql(fresh));
    try testing.expectEqualStrings("fresh", meshes.get(fresh).?.name);
}

test "iterating hands back handles that work" {
    var meshes: Table(Mesh) = .empty;
    defer meshes.deinit(testing.allocator);

    const a = try meshes.add(testing.allocator, .{ .name = "a" });
    const b = try meshes.add(testing.allocator, .{ .name = "b" });
    const c = try meshes.add(testing.allocator, .{ .name = "c" });
    _ = meshes.remove(b);

    var seen: usize = 0;
    var it = meshes.iterator();
    while (it.next()) |entry| {
        seen += 1;
        // The handle the iterator gives back is the one that was handed out.
        try testing.expect(entry.handle.eql(if (seen == 1) a else c));
        try testing.expectEqual(entry.value, meshes.get(entry.handle).?);
        entry.value.triangles = 9;
    }
    try testing.expectEqual(@as(usize, 2), seen);
    try testing.expectEqual(@as(u32, 9), meshes.get(a).?.triangles);
    try testing.expectEqual(@as(u32, 9), meshes.get(c).?.triangles);
}

test "handles that were never handed out" {
    var meshes: Table(Mesh) = .empty;
    defer meshes.deinit(testing.allocator);

    const real = try meshes.add(testing.allocator, .{ .name = "real" });

    try testing.expect(meshes.get(.none) == null);
    try testing.expect(meshes.get(.{ .index = 99, .generation = 1 }) == null);
    try testing.expect(meshes.get(.{ .index = real.index, .generation = 99 }) == null);
    try testing.expect(meshes.remove(.none) == null);
    try testing.expect(meshes.contains(real));
}

test "generations wrap past zero rather than onto it" {
    var meshes: Table(Mesh) = .empty;
    defer meshes.deinit(testing.allocator);

    var h = try meshes.add(testing.allocator, .{ .name = "a" });
    // Start one removal short of the wrap.
    meshes.slots.items[0].generation = std.math.maxInt(u32);
    h.generation = std.math.maxInt(u32);

    _ = meshes.remove(h);
    const after = try meshes.add(testing.allocator, .{ .name = "b" });
    try testing.expectEqual(@as(u32, 1), after.generation);
    try testing.expect(!after.isNone());
    try testing.expectEqualStrings("b", meshes.get(after).?.name);
}

test "a table of handles into another table" {
    // The shape this is for: entries that refer to each other by handle
    // rather than by pointer, so either table can grow without anything
    // going stale.
    const Instance = struct { mesh: Handle(Mesh), scale: f32 };

    var meshes: Table(Mesh) = .empty;
    defer meshes.deinit(testing.allocator);
    var instances: Table(Instance) = .empty;
    defer instances.deinit(testing.allocator);

    const hull = try meshes.add(testing.allocator, .{ .name = "hull" });
    const one = try instances.add(testing.allocator, .{ .mesh = hull, .scale = 1 });
    const two = try instances.add(testing.allocator, .{ .mesh = hull, .scale = 2 });

    try testing.expectEqualStrings("hull", meshes.get(instances.get(one).?.mesh).?.name);

    // The mesh goes. Both instances still exist, and both now know that what
    // they pointed at does not.
    _ = meshes.remove(hull);
    try testing.expect(meshes.get(instances.get(one).?.mesh) == null);
    try testing.expect(meshes.get(instances.get(two).?.mesh) == null);
    try testing.expectEqual(@as(usize, 2), instances.count());
}
