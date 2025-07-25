const std = @import("std.zig");
const builtin = @import("builtin");
const debug = std.debug;
const assert = debug.assert;
const math = std.math;
const mem = @This();
const testing = std.testing;
const Endian = std.builtin.Endian;
const native_endian = builtin.cpu.arch.endian();

/// The standard library currently thoroughly depends on byte size
/// being 8 bits.  (see the use of u8 throughout allocation code as
/// the "byte" type.)  Code which depends on this can reference this
/// declaration.  If we ever try to port the standard library to a
/// non-8-bit-byte platform, this will allow us to search for things
/// which need to be updated.
pub const byte_size_in_bits = 8;

pub const Allocator = @import("mem/Allocator.zig");

/// Stored as a power-of-two.
pub const Alignment = enum(math.Log2Int(usize)) {
    @"1" = 0,
    @"2" = 1,
    @"4" = 2,
    @"8" = 3,
    @"16" = 4,
    @"32" = 5,
    @"64" = 6,
    _,

    pub fn toByteUnits(a: Alignment) usize {
        return @as(usize, 1) << @intFromEnum(a);
    }

    pub fn fromByteUnits(n: usize) Alignment {
        assert(std.math.isPowerOfTwo(n));
        return @enumFromInt(@ctz(n));
    }

    pub inline fn of(comptime T: type) Alignment {
        return comptime fromByteUnits(@alignOf(T));
    }

    pub fn order(lhs: Alignment, rhs: Alignment) std.math.Order {
        return std.math.order(@intFromEnum(lhs), @intFromEnum(rhs));
    }

    pub fn compare(lhs: Alignment, op: std.math.CompareOperator, rhs: Alignment) bool {
        return std.math.compare(@intFromEnum(lhs), op, @intFromEnum(rhs));
    }

    pub fn max(lhs: Alignment, rhs: Alignment) Alignment {
        return @enumFromInt(@max(@intFromEnum(lhs), @intFromEnum(rhs)));
    }

    pub fn min(lhs: Alignment, rhs: Alignment) Alignment {
        return @enumFromInt(@min(@intFromEnum(lhs), @intFromEnum(rhs)));
    }

    /// Return next address with this alignment.
    pub fn forward(a: Alignment, address: usize) usize {
        const x = (@as(usize, 1) << @intFromEnum(a)) - 1;
        return (address + x) & ~x;
    }

    /// Return previous address with this alignment.
    pub fn backward(a: Alignment, address: usize) usize {
        const x = (@as(usize, 1) << @intFromEnum(a)) - 1;
        return address & ~x;
    }

    /// Return whether address is aligned to this amount.
    pub fn check(a: Alignment, address: usize) bool {
        return @ctz(address) >= @intFromEnum(a);
    }
};

/// Detects and asserts if the std.mem.Allocator interface is violated by the caller
/// or the allocator.
pub fn ValidationAllocator(comptime T: type) type {
    return struct {
        const Self = @This();

        underlying_allocator: T,

        pub fn init(underlying_allocator: T) @This() {
            return .{
                .underlying_allocator = underlying_allocator,
            };
        }

        pub fn allocator(self: *Self) Allocator {
            return .{
                .ptr = self,
                .vtable = &.{
                    .alloc = alloc,
                    .resize = resize,
                    .remap = remap,
                    .free = free,
                },
            };
        }

        fn getUnderlyingAllocatorPtr(self: *Self) Allocator {
            if (T == Allocator) return self.underlying_allocator;
            return self.underlying_allocator.allocator();
        }

        pub fn alloc(
            ctx: *anyopaque,
            n: usize,
            alignment: mem.Alignment,
            ret_addr: usize,
        ) ?[*]u8 {
            assert(n > 0);
            const self: *Self = @ptrCast(@alignCast(ctx));
            const underlying = self.getUnderlyingAllocatorPtr();
            const result = underlying.rawAlloc(n, alignment, ret_addr) orelse
                return null;
            assert(alignment.check(@intFromPtr(result)));
            return result;
        }

        pub fn resize(
            ctx: *anyopaque,
            buf: []u8,
            alignment: Alignment,
            new_len: usize,
            ret_addr: usize,
        ) bool {
            const self: *Self = @ptrCast(@alignCast(ctx));
            assert(buf.len > 0);
            const underlying = self.getUnderlyingAllocatorPtr();
            return underlying.rawResize(buf, alignment, new_len, ret_addr);
        }

        pub fn remap(
            ctx: *anyopaque,
            buf: []u8,
            alignment: Alignment,
            new_len: usize,
            ret_addr: usize,
        ) ?[*]u8 {
            const self: *Self = @ptrCast(@alignCast(ctx));
            assert(buf.len > 0);
            const underlying = self.getUnderlyingAllocatorPtr();
            return underlying.rawRemap(buf, alignment, new_len, ret_addr);
        }

        pub fn free(
            ctx: *anyopaque,
            buf: []u8,
            alignment: Alignment,
            ret_addr: usize,
        ) void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            assert(buf.len > 0);
            const underlying = self.getUnderlyingAllocatorPtr();
            underlying.rawFree(buf, alignment, ret_addr);
        }

        pub fn reset(self: *Self) void {
            self.underlying_allocator.reset();
        }
    };
}

pub fn validationWrap(allocator: anytype) ValidationAllocator(@TypeOf(allocator)) {
    return ValidationAllocator(@TypeOf(allocator)).init(allocator);
}

test "Allocator basics" {
    try testing.expectError(error.OutOfMemory, testing.failing_allocator.alloc(u8, 1));
    try testing.expectError(error.OutOfMemory, testing.failing_allocator.allocSentinel(u8, 1, 0));
}

test "Allocator.resize" {
    const primitiveIntTypes = .{
        i8,
        u8,
        i16,
        u16,
        i32,
        u32,
        i64,
        u64,
        i128,
        u128,
        isize,
        usize,
    };
    inline for (primitiveIntTypes) |T| {
        var values = try testing.allocator.alloc(T, 100);
        defer testing.allocator.free(values);

        for (values, 0..) |*v, i| v.* = @as(T, @intCast(i));
        if (!testing.allocator.resize(values, values.len + 10)) return error.OutOfMemory;
        values = values.ptr[0 .. values.len + 10];
        try testing.expect(values.len == 110);
    }

    const primitiveFloatTypes = .{
        f16,
        f32,
        f64,
        f128,
    };
    inline for (primitiveFloatTypes) |T| {
        var values = try testing.allocator.alloc(T, 100);
        defer testing.allocator.free(values);

        for (values, 0..) |*v, i| v.* = @as(T, @floatFromInt(i));
        if (!testing.allocator.resize(values, values.len + 10)) return error.OutOfMemory;
        values = values.ptr[0 .. values.len + 10];
        try testing.expect(values.len == 110);
    }
}

test "Allocator alloc and remap with zero-bit type" {
    var values = try testing.allocator.alloc(void, 10);
    defer testing.allocator.free(values);

    try testing.expectEqual(10, values.len);
    const remaped = testing.allocator.remap(values, 200);
    try testing.expect(remaped != null);

    values = remaped.?;
    try testing.expectEqual(200, values.len);
}

/// Copy all of source into dest at position 0.
/// dest.len must be >= source.len.
/// If the slices overlap, dest.ptr must be <= src.ptr.
/// This function is deprecated; use @memmove instead.
pub fn copyForwards(comptime T: type, dest: []T, source: []const T) void {
    for (dest[0..source.len], source) |*d, s| d.* = s;
}

/// Copy all of source into dest at position 0.
/// dest.len must be >= source.len.
/// If the slices overlap, dest.ptr must be >= src.ptr.
/// This function is deprecated; use @memmove instead.
pub fn copyBackwards(comptime T: type, dest: []T, source: []const T) void {
    // TODO instead of manually doing this check for the whole array
    // and turning off runtime safety, the compiler should detect loops like
    // this and automatically omit safety checks for loops
    @setRuntimeSafety(false);
    assert(dest.len >= source.len);
    var i = source.len;
    while (i > 0) {
        i -= 1;
        dest[i] = source[i];
    }
}

/// Generally, Zig users are encouraged to explicitly initialize all fields of a struct explicitly rather than using this function.
/// However, it is recognized that there are sometimes use cases for initializing all fields to a "zero" value. For example, when
/// interfacing with a C API where this practice is more common and relied upon. If you are performing code review and see this
/// function used, examine closely - it may be a code smell.
/// Zero initializes the type.
/// This can be used to zero-initialize any type for which it makes sense. Structs will be initialized recursively.
pub fn zeroes(comptime T: type) T {
    switch (@typeInfo(T)) {
        .comptime_int, .int, .comptime_float, .float => {
            return @as(T, 0);
        },
        .@"enum" => {
            return @as(T, @enumFromInt(0));
        },
        .void => {
            return {};
        },
        .bool => {
            return false;
        },
        .optional, .null => {
            return null;
        },
        .@"struct" => |struct_info| {
            if (@sizeOf(T) == 0) return undefined;
            if (struct_info.layout == .@"extern") {
                var item: T = undefined;
                @memset(asBytes(&item), 0);
                return item;
            } else {
                var structure: T = undefined;
                inline for (struct_info.fields) |field| {
                    if (!field.is_comptime) {
                        @field(structure, field.name) = zeroes(field.type);
                    }
                }
                return structure;
            }
        },
        .pointer => |ptr_info| {
            switch (ptr_info.size) {
                .slice => {
                    if (ptr_info.sentinel()) |sentinel| {
                        if (ptr_info.child == u8 and sentinel == 0) {
                            return ""; // A special case for the most common use-case: null-terminated strings.
                        }
                        @compileError("Can't set a sentinel slice to zero. This would require allocating memory.");
                    } else {
                        return &[_]ptr_info.child{};
                    }
                },
                .c => {
                    return null;
                },
                .one, .many => {
                    if (ptr_info.is_allowzero) return @ptrFromInt(0);
                    @compileError("Only nullable and allowzero pointers can be set to zero.");
                },
            }
        },
        .array => |info| {
            return @splat(zeroes(info.child));
        },
        .vector => |info| {
            return @splat(zeroes(info.child));
        },
        .@"union" => |info| {
            if (info.layout == .@"extern") {
                var item: T = undefined;
                @memset(asBytes(&item), 0);
                return item;
            }
            @compileError("Can't set a " ++ @typeName(T) ++ " to zero.");
        },
        .enum_literal,
        .error_union,
        .error_set,
        .@"fn",
        .type,
        .noreturn,
        .undefined,
        .@"opaque",
        .frame,
        .@"anyframe",
        => {
            @compileError("Can't set a " ++ @typeName(T) ++ " to zero.");
        },
    }
}

test zeroes {
    const C_struct = extern struct {
        x: u32,
        y: u32 align(128),
    };

    var a = zeroes(C_struct);

    // Extern structs should have padding zeroed out.
    try testing.expectEqualSlices(u8, &[_]u8{0} ** @sizeOf(@TypeOf(a)), asBytes(&a));

    a.y += 10;

    try testing.expect(a.x == 0);
    try testing.expect(a.y == 10);

    const ZigStruct = struct {
        comptime comptime_field: u8 = 5,

        integral_types: struct {
            integer_0: i0,
            integer_8: i8,
            integer_16: i16,
            integer_32: i32,
            integer_64: i64,
            integer_128: i128,
            unsigned_0: u0,
            unsigned_8: u8,
            unsigned_16: u16,
            unsigned_32: u32,
            unsigned_64: u64,
            unsigned_128: u128,

            float_32: f32,
            float_64: f64,
        },

        pointers: struct {
            optional: ?*u8,
            c_pointer: [*c]u8,
            slice: []u8,
            nullTerminatedString: [:0]const u8,
        },

        array: [2]u32,
        vector_u32: @Vector(2, u32),
        vector_f32: @Vector(2, f32),
        vector_bool: @Vector(2, bool),
        optional_int: ?u8,
        empty: void,
        sentinel: [3:0]u8,
    };

    const b = zeroes(ZigStruct);
    try testing.expectEqual(@as(u8, 5), b.comptime_field);
    try testing.expectEqual(@as(i8, 0), b.integral_types.integer_0);
    try testing.expectEqual(@as(i8, 0), b.integral_types.integer_8);
    try testing.expectEqual(@as(i16, 0), b.integral_types.integer_16);
    try testing.expectEqual(@as(i32, 0), b.integral_types.integer_32);
    try testing.expectEqual(@as(i64, 0), b.integral_types.integer_64);
    try testing.expectEqual(@as(i128, 0), b.integral_types.integer_128);
    try testing.expectEqual(@as(u8, 0), b.integral_types.unsigned_0);
    try testing.expectEqual(@as(u8, 0), b.integral_types.unsigned_8);
    try testing.expectEqual(@as(u16, 0), b.integral_types.unsigned_16);
    try testing.expectEqual(@as(u32, 0), b.integral_types.unsigned_32);
    try testing.expectEqual(@as(u64, 0), b.integral_types.unsigned_64);
    try testing.expectEqual(@as(u128, 0), b.integral_types.unsigned_128);
    try testing.expectEqual(@as(f32, 0), b.integral_types.float_32);
    try testing.expectEqual(@as(f64, 0), b.integral_types.float_64);
    try testing.expectEqual(@as(?*u8, null), b.pointers.optional);
    try testing.expectEqual(@as([*c]u8, null), b.pointers.c_pointer);
    try testing.expectEqual(@as([]u8, &[_]u8{}), b.pointers.slice);
    try testing.expectEqual(@as([:0]const u8, ""), b.pointers.nullTerminatedString);
    for (b.array) |e| {
        try testing.expectEqual(@as(u32, 0), e);
    }
    try testing.expectEqual(@as(@TypeOf(b.vector_u32), @splat(0)), b.vector_u32);
    try testing.expectEqual(@as(@TypeOf(b.vector_f32), @splat(0.0)), b.vector_f32);
    if (!(builtin.zig_backend == .stage2_llvm and builtin.cpu.arch == .hexagon)) {
        try testing.expectEqual(@as(@TypeOf(b.vector_bool), @splat(false)), b.vector_bool);
    }
    try testing.expectEqual(@as(?u8, null), b.optional_int);
    for (b.sentinel) |e| {
        try testing.expectEqual(@as(u8, 0), e);
    }

    const C_union = extern union {
        a: u8,
        b: u32,
    };

    const c = zeroes(C_union);
    try testing.expectEqual(@as(u8, 0), c.a);
    try testing.expectEqual(@as(u32, 0), c.b);

    const comptime_union = comptime zeroes(C_union);
    try testing.expectEqual(@as(u8, 0), comptime_union.a);
    try testing.expectEqual(@as(u32, 0), comptime_union.b);

    // Ensure zero sized struct with fields is initialized correctly.
    _ = zeroes(struct { handle: void });
}

/// Initializes all fields of the struct with their default value, or zero values if no default value is present.
/// If the field is present in the provided initial values, it will have that value instead.
/// Structs are initialized recursively.
pub fn zeroInit(comptime T: type, init: anytype) T {
    const Init = @TypeOf(init);

    switch (@typeInfo(T)) {
        .@"struct" => |struct_info| {
            switch (@typeInfo(Init)) {
                .@"struct" => |init_info| {
                    if (init_info.is_tuple) {
                        if (init_info.fields.len > struct_info.fields.len) {
                            @compileError("Tuple initializer has more elements than there are fields in `" ++ @typeName(T) ++ "`");
                        }
                    } else {
                        inline for (init_info.fields) |field| {
                            if (!@hasField(T, field.name)) {
                                @compileError("Encountered an initializer for `" ++ field.name ++ "`, but it is not a field of " ++ @typeName(T));
                            }
                        }
                    }

                    var value: T = if (struct_info.layout == .@"extern") zeroes(T) else undefined;

                    inline for (struct_info.fields, 0..) |field, i| {
                        if (field.is_comptime) {
                            continue;
                        }

                        if (init_info.is_tuple and init_info.fields.len > i) {
                            @field(value, field.name) = @field(init, init_info.fields[i].name);
                        } else if (@hasField(@TypeOf(init), field.name)) {
                            switch (@typeInfo(field.type)) {
                                .@"struct" => {
                                    @field(value, field.name) = zeroInit(field.type, @field(init, field.name));
                                },
                                else => {
                                    @field(value, field.name) = @field(init, field.name);
                                },
                            }
                        } else if (field.defaultValue()) |val| {
                            @field(value, field.name) = val;
                        } else {
                            switch (@typeInfo(field.type)) {
                                .@"struct" => {
                                    @field(value, field.name) = std.mem.zeroInit(field.type, .{});
                                },
                                else => {
                                    @field(value, field.name) = std.mem.zeroes(@TypeOf(@field(value, field.name)));
                                },
                            }
                        }
                    }

                    return value;
                },
                else => {
                    @compileError("The initializer must be a struct");
                },
            }
        },
        else => {
            @compileError("Can't default init a " ++ @typeName(T));
        },
    }
}

test zeroInit {
    const I = struct {
        d: f64,
    };

    const S = struct {
        a: u32,
        b: ?bool,
        c: I,
        e: [3]u8,
        f: i64 = -1,
    };

    const s = zeroInit(S, .{
        .a = 42,
    });

    try testing.expectEqual(S{
        .a = 42,
        .b = null,
        .c = .{
            .d = 0,
        },
        .e = [3]u8{ 0, 0, 0 },
        .f = -1,
    }, s);

    const Color = struct {
        r: u8,
        g: u8,
        b: u8,
        a: u8,
    };

    const c = zeroInit(Color, .{ 255, 255 });
    try testing.expectEqual(Color{
        .r = 255,
        .g = 255,
        .b = 0,
        .a = 0,
    }, c);

    const Foo = struct {
        foo: u8 = 69,
        bar: u8,
    };

    const f = zeroInit(Foo, .{});
    try testing.expectEqual(Foo{
        .foo = 69,
        .bar = 0,
    }, f);

    const Bar = struct {
        foo: u32 = 666,
        bar: u32 = 420,
    };

    const b = zeroInit(Bar, .{69});
    try testing.expectEqual(Bar{
        .foo = 69,
        .bar = 420,
    }, b);

    const Baz = struct {
        foo: [:0]const u8 = "bar",
    };

    const baz1 = zeroInit(Baz, .{});
    try testing.expectEqual(Baz{}, baz1);

    const baz2 = zeroInit(Baz, .{ .foo = "zab" });
    try testing.expectEqualSlices(u8, "zab", baz2.foo);

    const NestedBaz = struct {
        bbb: Baz,
    };
    const nested_baz = zeroInit(NestedBaz, .{});
    try testing.expectEqual(NestedBaz{
        .bbb = Baz{},
    }, nested_baz);
}

pub fn sort(
    comptime T: type,
    items: []T,
    context: anytype,
    comptime lessThanFn: fn (@TypeOf(context), lhs: T, rhs: T) bool,
) void {
    std.sort.block(T, items, context, lessThanFn);
}

pub fn sortUnstable(
    comptime T: type,
    items: []T,
    context: anytype,
    comptime lessThanFn: fn (@TypeOf(context), lhs: T, rhs: T) bool,
) void {
    std.sort.pdq(T, items, context, lessThanFn);
}

/// TODO: currently this just calls `insertionSortContext`. The block sort implementation
/// in this file needs to be adapted to use the sort context.
pub fn sortContext(a: usize, b: usize, context: anytype) void {
    std.sort.insertionContext(a, b, context);
}

pub fn sortUnstableContext(a: usize, b: usize, context: anytype) void {
    std.sort.pdqContext(a, b, context);
}

/// Compares two slices of numbers lexicographically. O(n).
pub fn order(comptime T: type, lhs: []const T, rhs: []const T) math.Order {
    const n = @min(lhs.len, rhs.len);
    for (lhs[0..n], rhs[0..n]) |lhs_elem, rhs_elem| {
        switch (math.order(lhs_elem, rhs_elem)) {
            .eq => continue,
            .lt => return .lt,
            .gt => return .gt,
        }
    }
    return math.order(lhs.len, rhs.len);
}

/// Compares two many-item pointers with NUL-termination lexicographically.
pub fn orderZ(comptime T: type, lhs: [*:0]const T, rhs: [*:0]const T) math.Order {
    var i: usize = 0;
    while (lhs[i] == rhs[i] and lhs[i] != 0) : (i += 1) {}
    return math.order(lhs[i], rhs[i]);
}

test order {
    try testing.expect(order(u8, "abcd", "bee") == .lt);
    try testing.expect(order(u8, "abc", "abc") == .eq);
    try testing.expect(order(u8, "abc", "abc0") == .lt);
    try testing.expect(order(u8, "", "") == .eq);
    try testing.expect(order(u8, "", "a") == .lt);
}

test orderZ {
    try testing.expect(orderZ(u8, "abcd", "bee") == .lt);
    try testing.expect(orderZ(u8, "abc", "abc") == .eq);
    try testing.expect(orderZ(u8, "abc", "abc0") == .lt);
    try testing.expect(orderZ(u8, "", "") == .eq);
    try testing.expect(orderZ(u8, "", "a") == .lt);
}

/// Returns true if lhs < rhs, false otherwise
pub fn lessThan(comptime T: type, lhs: []const T, rhs: []const T) bool {
    return order(T, lhs, rhs) == .lt;
}

test lessThan {
    try testing.expect(lessThan(u8, "abcd", "bee"));
    try testing.expect(!lessThan(u8, "abc", "abc"));
    try testing.expect(lessThan(u8, "abc", "abc0"));
    try testing.expect(!lessThan(u8, "", ""));
    try testing.expect(lessThan(u8, "", "a"));
}

const eqlBytes_allowed = switch (builtin.zig_backend) {
    // These backends don't support vectors yet.
    .stage2_aarch64,
    .stage2_powerpc,
    .stage2_riscv64,
    => false,
    // The SPIR-V backend does not support the optimized path yet.
    .stage2_spirv => false,
    // The naive memory comparison implementation is more useful for fuzzers to
    // find interesting inputs.
    else => !builtin.fuzz,
};

/// Returns true if and only if the slices have the same length and all elements
/// compare true using equality operator.
pub fn eql(comptime T: type, a: []const T, b: []const T) bool {
    if (!@inComptime() and @sizeOf(T) != 0 and std.meta.hasUniqueRepresentation(T) and
        eqlBytes_allowed)
    {
        return eqlBytes(sliceAsBytes(a), sliceAsBytes(b));
    }

    if (a.len != b.len) return false;
    if (a.len == 0 or a.ptr == b.ptr) return true;

    for (a, b) |a_elem, b_elem| {
        if (a_elem != b_elem) return false;
    }
    return true;
}

test eql {
    try testing.expect(eql(u8, "abcd", "abcd"));
    try testing.expect(!eql(u8, "abcdef", "abZdef"));
    try testing.expect(!eql(u8, "abcdefg", "abcdef"));

    comptime {
        try testing.expect(eql(type, &.{ bool, f32 }, &.{ bool, f32 }));
        try testing.expect(!eql(type, &.{ bool, f32 }, &.{ f32, bool }));
        try testing.expect(!eql(type, &.{ bool, f32 }, &.{bool}));

        try testing.expect(eql(comptime_int, &.{ 1, 2, 3 }, &.{ 1, 2, 3 }));
        try testing.expect(!eql(comptime_int, &.{ 1, 2, 3 }, &.{ 3, 2, 1 }));
        try testing.expect(!eql(comptime_int, &.{1}, &.{ 1, 2 }));
    }

    try testing.expect(eql(void, &.{ {}, {} }, &.{ {}, {} }));
    try testing.expect(!eql(void, &.{{}}, &.{ {}, {} }));
}

/// std.mem.eql heavily optimized for slices of bytes.
fn eqlBytes(a: []const u8, b: []const u8) bool {
    comptime assert(eqlBytes_allowed);

    if (a.len != b.len) return false;
    if (a.len == 0 or a.ptr == b.ptr) return true;

    if (a.len <= 16) {
        if (a.len < 4) {
            const x = (a[0] ^ b[0]) | (a[a.len - 1] ^ b[a.len - 1]) | (a[a.len / 2] ^ b[a.len / 2]);
            return x == 0;
        }
        var x: u32 = 0;
        for ([_]usize{ 0, a.len - 4, (a.len / 8) * 4, a.len - 4 - ((a.len / 8) * 4) }) |n| {
            x |= @as(u32, @bitCast(a[n..][0..4].*)) ^ @as(u32, @bitCast(b[n..][0..4].*));
        }
        return x == 0;
    }

    // Figure out the fastest way to scan through the input in chunks.
    // Uses vectors when supported and falls back to usize/words when not.
    const Scan = if (std.simd.suggestVectorLength(u8)) |vec_size|
        struct {
            pub const size = vec_size;
            pub const Chunk = @Vector(size, u8);
            pub inline fn isNotEqual(chunk_a: Chunk, chunk_b: Chunk) bool {
                return @reduce(.Or, chunk_a != chunk_b);
            }
        }
    else
        struct {
            pub const size = @sizeOf(usize);
            pub const Chunk = usize;
            pub inline fn isNotEqual(chunk_a: Chunk, chunk_b: Chunk) bool {
                return chunk_a != chunk_b;
            }
        };

    inline for (1..6) |s| {
        const n = 16 << s;
        if (n <= Scan.size and a.len <= n) {
            const V = @Vector(n / 2, u8);
            var x = @as(V, a[0 .. n / 2].*) ^ @as(V, b[0 .. n / 2].*);
            x |= @as(V, a[a.len - n / 2 ..][0 .. n / 2].*) ^ @as(V, b[a.len - n / 2 ..][0 .. n / 2].*);
            const zero: V = @splat(0);
            return !@reduce(.Or, x != zero);
        }
    }
    // Compare inputs in chunks at a time (excluding the last chunk).
    for (0..(a.len - 1) / Scan.size) |i| {
        const a_chunk: Scan.Chunk = @bitCast(a[i * Scan.size ..][0..Scan.size].*);
        const b_chunk: Scan.Chunk = @bitCast(b[i * Scan.size ..][0..Scan.size].*);
        if (Scan.isNotEqual(a_chunk, b_chunk)) return false;
    }

    // Compare the last chunk using an overlapping read (similar to the previous size strategies).
    const last_a_chunk: Scan.Chunk = @bitCast(a[a.len - Scan.size ..][0..Scan.size].*);
    const last_b_chunk: Scan.Chunk = @bitCast(b[a.len - Scan.size ..][0..Scan.size].*);
    return !Scan.isNotEqual(last_a_chunk, last_b_chunk);
}

/// Compares two slices and returns the index of the first inequality.
/// Returns null if the slices are equal.
pub fn indexOfDiff(comptime T: type, a: []const T, b: []const T) ?usize {
    const shortest = @min(a.len, b.len);
    if (a.ptr == b.ptr)
        return if (a.len == b.len) null else shortest;
    var index: usize = 0;
    while (index < shortest) : (index += 1) if (a[index] != b[index]) return index;
    return if (a.len == b.len) null else shortest;
}

test indexOfDiff {
    try testing.expectEqual(indexOfDiff(u8, "one", "one"), null);
    try testing.expectEqual(indexOfDiff(u8, "one two", "one"), 3);
    try testing.expectEqual(indexOfDiff(u8, "one", "one two"), 3);
    try testing.expectEqual(indexOfDiff(u8, "one twx", "one two"), 6);
    try testing.expectEqual(indexOfDiff(u8, "xne", "one"), 0);
}

/// Takes a sentinel-terminated pointer and returns a slice preserving pointer attributes.
/// `[*c]` pointers are assumed to be 0-terminated and assumed to not be allowzero.
fn Span(comptime T: type) type {
    switch (@typeInfo(T)) {
        .optional => |optional_info| {
            return ?Span(optional_info.child);
        },
        .pointer => |ptr_info| {
            var new_ptr_info = ptr_info;
            switch (ptr_info.size) {
                .c => {
                    new_ptr_info.sentinel_ptr = &@as(ptr_info.child, 0);
                    new_ptr_info.is_allowzero = false;
                },
                .many => if (ptr_info.sentinel() == null) @compileError("invalid type given to std.mem.span: " ++ @typeName(T)),
                .one, .slice => @compileError("invalid type given to std.mem.span: " ++ @typeName(T)),
            }
            new_ptr_info.size = .slice;
            return @Type(.{ .pointer = new_ptr_info });
        },
        else => {},
    }
    @compileError("invalid type given to std.mem.span: " ++ @typeName(T));
}

test Span {
    try testing.expect(Span([*:1]u16) == [:1]u16);
    try testing.expect(Span(?[*:1]u16) == ?[:1]u16);
    try testing.expect(Span([*:1]const u8) == [:1]const u8);
    try testing.expect(Span(?[*:1]const u8) == ?[:1]const u8);
    try testing.expect(Span([*c]u16) == [:0]u16);
    try testing.expect(Span(?[*c]u16) == ?[:0]u16);
    try testing.expect(Span([*c]const u8) == [:0]const u8);
    try testing.expect(Span(?[*c]const u8) == ?[:0]const u8);
}

/// Takes a sentinel-terminated pointer and returns a slice, iterating over the
/// memory to find the sentinel and determine the length.
/// Pointer attributes such as const are preserved.
/// `[*c]` pointers are assumed to be non-null and 0-terminated.
pub fn span(ptr: anytype) Span(@TypeOf(ptr)) {
    if (@typeInfo(@TypeOf(ptr)) == .optional) {
        if (ptr) |non_null| {
            return span(non_null);
        } else {
            return null;
        }
    }
    const Result = Span(@TypeOf(ptr));
    const l = len(ptr);
    const ptr_info = @typeInfo(Result).pointer;
    if (ptr_info.sentinel()) |s| {
        return ptr[0..l :s];
    } else {
        return ptr[0..l];
    }
}

test span {
    var array: [5]u16 = [_]u16{ 1, 2, 3, 4, 5 };
    const ptr = @as([*:3]u16, array[0..2 :3]);
    try testing.expect(eql(u16, span(ptr), &[_]u16{ 1, 2 }));
    try testing.expectEqual(@as(?[:0]u16, null), span(@as(?[*:0]u16, null)));
}

/// Helper for the return type of sliceTo()
fn SliceTo(comptime T: type, comptime end: std.meta.Elem(T)) type {
    switch (@typeInfo(T)) {
        .optional => |optional_info| {
            return ?SliceTo(optional_info.child, end);
        },
        .pointer => |ptr_info| {
            var new_ptr_info = ptr_info;
            new_ptr_info.size = .slice;
            switch (ptr_info.size) {
                .one => switch (@typeInfo(ptr_info.child)) {
                    .array => |array_info| {
                        new_ptr_info.child = array_info.child;
                        // The return type must only be sentinel terminated if we are guaranteed
                        // to find the value searched for, which is only the case if it matches
                        // the sentinel of the type passed.
                        if (array_info.sentinel()) |s| {
                            if (end == s) {
                                new_ptr_info.sentinel_ptr = &end;
                            } else {
                                new_ptr_info.sentinel_ptr = null;
                            }
                        }
                    },
                    else => {},
                },
                .many, .slice => {
                    // The return type must only be sentinel terminated if we are guaranteed
                    // to find the value searched for, which is only the case if it matches
                    // the sentinel of the type passed.
                    if (ptr_info.sentinel()) |s| {
                        if (end == s) {
                            new_ptr_info.sentinel_ptr = &end;
                        } else {
                            new_ptr_info.sentinel_ptr = null;
                        }
                    }
                },
                .c => {
                    new_ptr_info.sentinel_ptr = &end;
                    // C pointers are always allowzero, but we don't want the return type to be.
                    assert(new_ptr_info.is_allowzero);
                    new_ptr_info.is_allowzero = false;
                },
            }
            return @Type(.{ .pointer = new_ptr_info });
        },
        else => {},
    }
    @compileError("invalid type given to std.mem.sliceTo: " ++ @typeName(T));
}

/// Takes a pointer to an array, a sentinel-terminated pointer, or a slice and iterates searching for
/// the first occurrence of `end`, returning the scanned slice.
/// If `end` is not found, the full length of the array/slice/sentinel terminated pointer is returned.
/// If the pointer type is sentinel terminated and `end` matches that terminator, the
/// resulting slice is also sentinel terminated.
/// Pointer properties such as mutability and alignment are preserved.
/// C pointers are assumed to be non-null.
pub fn sliceTo(ptr: anytype, comptime end: std.meta.Elem(@TypeOf(ptr))) SliceTo(@TypeOf(ptr), end) {
    if (@typeInfo(@TypeOf(ptr)) == .optional) {
        const non_null = ptr orelse return null;
        return sliceTo(non_null, end);
    }
    const Result = SliceTo(@TypeOf(ptr), end);
    const length = lenSliceTo(ptr, end);
    const ptr_info = @typeInfo(Result).pointer;
    if (ptr_info.sentinel()) |s| {
        return ptr[0..length :s];
    } else {
        return ptr[0..length];
    }
}

test sliceTo {
    try testing.expectEqualSlices(u8, "aoeu", sliceTo("aoeu", 0));

    {
        var array: [5]u16 = [_]u16{ 1, 2, 3, 4, 5 };
        try testing.expectEqualSlices(u16, &array, sliceTo(&array, 0));
        try testing.expectEqualSlices(u16, array[0..3], sliceTo(array[0..3], 0));
        try testing.expectEqualSlices(u16, array[0..2], sliceTo(&array, 3));
        try testing.expectEqualSlices(u16, array[0..2], sliceTo(array[0..3], 3));

        const sentinel_ptr = @as([*:5]u16, @ptrCast(&array));
        try testing.expectEqualSlices(u16, array[0..2], sliceTo(sentinel_ptr, 3));
        try testing.expectEqualSlices(u16, array[0..4], sliceTo(sentinel_ptr, 99));

        const optional_sentinel_ptr = @as(?[*:5]u16, @ptrCast(&array));
        try testing.expectEqualSlices(u16, array[0..2], sliceTo(optional_sentinel_ptr, 3).?);
        try testing.expectEqualSlices(u16, array[0..4], sliceTo(optional_sentinel_ptr, 99).?);

        const c_ptr = @as([*c]u16, &array);
        try testing.expectEqualSlices(u16, array[0..2], sliceTo(c_ptr, 3));

        const slice: []u16 = &array;
        try testing.expectEqualSlices(u16, array[0..2], sliceTo(slice, 3));
        try testing.expectEqualSlices(u16, &array, sliceTo(slice, 99));

        const sentinel_slice: [:5]u16 = array[0..4 :5];
        try testing.expectEqualSlices(u16, array[0..2], sliceTo(sentinel_slice, 3));
        try testing.expectEqualSlices(u16, array[0..4], sliceTo(sentinel_slice, 99));
    }
    {
        var sentinel_array: [5:0]u16 = [_:0]u16{ 1, 2, 3, 4, 5 };
        try testing.expectEqualSlices(u16, sentinel_array[0..2], sliceTo(&sentinel_array, 3));
        try testing.expectEqualSlices(u16, &sentinel_array, sliceTo(&sentinel_array, 0));
        try testing.expectEqualSlices(u16, &sentinel_array, sliceTo(&sentinel_array, 99));
    }

    try testing.expectEqual(@as(?[]u8, null), sliceTo(@as(?[]u8, null), 0));
}

/// Private helper for sliceTo(). If you want the length, use sliceTo(foo, x).len
fn lenSliceTo(ptr: anytype, comptime end: std.meta.Elem(@TypeOf(ptr))) usize {
    switch (@typeInfo(@TypeOf(ptr))) {
        .pointer => |ptr_info| switch (ptr_info.size) {
            .one => switch (@typeInfo(ptr_info.child)) {
                .array => |array_info| {
                    if (array_info.sentinel()) |s| {
                        if (s == end) {
                            return indexOfSentinel(array_info.child, end, ptr);
                        }
                    }
                    return indexOfScalar(array_info.child, ptr, end) orelse array_info.len;
                },
                else => {},
            },
            .many => if (ptr_info.sentinel()) |s| {
                if (s == end) {
                    return indexOfSentinel(ptr_info.child, end, ptr);
                }
                // We're looking for something other than the sentinel,
                // but iterating past the sentinel would be a bug so we need
                // to check for both.
                var i: usize = 0;
                while (ptr[i] != end and ptr[i] != s) i += 1;
                return i;
            },
            .c => {
                assert(ptr != null);
                return indexOfSentinel(ptr_info.child, end, ptr);
            },
            .slice => {
                if (ptr_info.sentinel()) |s| {
                    if (s == end) {
                        return indexOfSentinel(ptr_info.child, s, ptr);
                    }
                }
                return indexOfScalar(ptr_info.child, ptr, end) orelse ptr.len;
            },
        },
        else => {},
    }
    @compileError("invalid type given to std.mem.sliceTo: " ++ @typeName(@TypeOf(ptr)));
}

test lenSliceTo {
    try testing.expect(lenSliceTo("aoeu", 0) == 4);

    {
        var array: [5]u16 = [_]u16{ 1, 2, 3, 4, 5 };
        try testing.expectEqual(@as(usize, 5), lenSliceTo(&array, 0));
        try testing.expectEqual(@as(usize, 3), lenSliceTo(array[0..3], 0));
        try testing.expectEqual(@as(usize, 2), lenSliceTo(&array, 3));
        try testing.expectEqual(@as(usize, 2), lenSliceTo(array[0..3], 3));

        const sentinel_ptr = @as([*:5]u16, @ptrCast(&array));
        try testing.expectEqual(@as(usize, 2), lenSliceTo(sentinel_ptr, 3));
        try testing.expectEqual(@as(usize, 4), lenSliceTo(sentinel_ptr, 99));

        const c_ptr = @as([*c]u16, &array);
        try testing.expectEqual(@as(usize, 2), lenSliceTo(c_ptr, 3));

        const slice: []u16 = &array;
        try testing.expectEqual(@as(usize, 2), lenSliceTo(slice, 3));
        try testing.expectEqual(@as(usize, 5), lenSliceTo(slice, 99));

        const sentinel_slice: [:5]u16 = array[0..4 :5];
        try testing.expectEqual(@as(usize, 2), lenSliceTo(sentinel_slice, 3));
        try testing.expectEqual(@as(usize, 4), lenSliceTo(sentinel_slice, 99));
    }
    {
        var sentinel_array: [5:0]u16 = [_:0]u16{ 1, 2, 3, 4, 5 };
        try testing.expectEqual(@as(usize, 2), lenSliceTo(&sentinel_array, 3));
        try testing.expectEqual(@as(usize, 5), lenSliceTo(&sentinel_array, 0));
        try testing.expectEqual(@as(usize, 5), lenSliceTo(&sentinel_array, 99));
    }
}

/// Takes a sentinel-terminated pointer and iterates over the memory to find the
/// sentinel and determine the length.
/// `[*c]` pointers are assumed to be non-null and 0-terminated.
pub fn len(value: anytype) usize {
    switch (@typeInfo(@TypeOf(value))) {
        .pointer => |info| switch (info.size) {
            .many => {
                const sentinel = info.sentinel() orelse
                    @compileError("invalid type given to std.mem.len: " ++ @typeName(@TypeOf(value)));
                return indexOfSentinel(info.child, sentinel, value);
            },
            .c => {
                assert(value != null);
                return indexOfSentinel(info.child, 0, value);
            },
            else => @compileError("invalid type given to std.mem.len: " ++ @typeName(@TypeOf(value))),
        },
        else => @compileError("invalid type given to std.mem.len: " ++ @typeName(@TypeOf(value))),
    }
}

test len {
    var array: [5]u16 = [_]u16{ 1, 2, 0, 4, 5 };
    const ptr = @as([*:4]u16, array[0..3 :4]);
    try testing.expect(len(ptr) == 3);
    const c_ptr = @as([*c]u16, ptr);
    try testing.expect(len(c_ptr) == 2);
}

const backend_supports_vectors = switch (builtin.zig_backend) {
    .stage2_llvm, .stage2_c => true,
    else => false,
};

pub fn indexOfSentinel(comptime T: type, comptime sentinel: T, p: [*:sentinel]const T) usize {
    var i: usize = 0;

    if (backend_supports_vectors and
        !std.debug.inValgrind() and // https://github.com/ziglang/zig/issues/17717
        !@inComptime() and
        (@typeInfo(T) == .int or @typeInfo(T) == .float) and std.math.isPowerOfTwo(@bitSizeOf(T)))
    {
        switch (@import("builtin").cpu.arch) {
            // The below branch assumes that reading past the end of the buffer is valid, as long
            // as we don't read into a new page. This should be the case for most architectures
            // which use paged memory, however should be confirmed before adding a new arch below.
            .aarch64, .x86, .x86_64 => if (std.simd.suggestVectorLength(T)) |block_len| {
                const page_size = std.heap.page_size_min;
                const block_size = @sizeOf(T) * block_len;
                const Block = @Vector(block_len, T);
                const mask: Block = @splat(sentinel);

                comptime assert(std.heap.page_size_min % @sizeOf(Block) == 0);
                assert(page_size % @sizeOf(Block) == 0);

                // First block may be unaligned
                const start_addr = @intFromPtr(&p[i]);
                const offset_in_page = start_addr & (page_size - 1);
                if (offset_in_page <= page_size - @sizeOf(Block)) {
                    // Will not read past the end of a page, full block.
                    const block: Block = p[i..][0..block_len].*;
                    const matches = block == mask;
                    if (@reduce(.Or, matches)) {
                        return i + std.simd.firstTrue(matches).?;
                    }

                    i += @divExact(std.mem.alignForward(usize, start_addr, block_size) - start_addr, @sizeOf(T));
                } else {
                    @branchHint(.unlikely);
                    // Would read over a page boundary. Per-byte at a time until aligned or found.
                    // 0.39% chance this branch is taken for 4K pages at 16b block length.
                    //
                    // An alternate strategy is to do read a full block (the last in the page) and
                    // mask the entries before the pointer.
                    while ((@intFromPtr(&p[i]) & (block_size - 1)) != 0) : (i += 1) {
                        if (p[i] == sentinel) return i;
                    }
                }

                assert(std.mem.isAligned(@intFromPtr(&p[i]), block_size));
                while (true) {
                    const block: *const Block = @ptrCast(@alignCast(p[i..][0..block_len]));
                    const matches = block.* == mask;
                    if (@reduce(.Or, matches)) {
                        return i + std.simd.firstTrue(matches).?;
                    }
                    i += block_len;
                }
            },
            else => {},
        }
    }

    while (p[i] != sentinel) {
        i += 1;
    }
    return i;
}

test "indexOfSentinel vector paths" {
    const Types = [_]type{ u8, u16, u32, u64 };
    const allocator = std.testing.allocator;
    const page_size = std.heap.page_size_min;

    inline for (Types) |T| {
        const block_len = std.simd.suggestVectorLength(T) orelse continue;

        // Allocate three pages so we guarantee a page-crossing address with a full page after
        const memory = try allocator.alloc(T, 3 * page_size / @sizeOf(T));
        defer allocator.free(memory);
        @memset(memory, 0xaa);

        // Find starting page-alignment = 0
        var start: usize = 0;
        const start_addr = @intFromPtr(&memory);
        start += (std.mem.alignForward(usize, start_addr, page_size) - start_addr) / @sizeOf(T);
        try testing.expect(start < page_size / @sizeOf(T));

        // Validate all sub-block alignments
        const search_len = page_size / @sizeOf(T);
        memory[start + search_len] = 0;
        for (0..block_len) |offset| {
            try testing.expectEqual(search_len - offset, indexOfSentinel(T, 0, @ptrCast(&memory[start + offset])));
        }
        memory[start + search_len] = 0xaa;

        // Validate page boundary crossing
        const start_page_boundary = start + (page_size / @sizeOf(T));
        memory[start_page_boundary + block_len] = 0;
        for (0..block_len) |offset| {
            try testing.expectEqual(2 * block_len - offset, indexOfSentinel(T, 0, @ptrCast(&memory[start_page_boundary - block_len + offset])));
        }
    }
}

/// Returns true if all elements in a slice are equal to the scalar value provided
pub fn allEqual(comptime T: type, slice: []const T, scalar: T) bool {
    for (slice) |item| {
        if (item != scalar) return false;
    }
    return true;
}

/// Remove a set of values from the beginning of a slice.
pub fn trimStart(comptime T: type, slice: []const T, values_to_strip: []const T) []const T {
    var begin: usize = 0;
    while (begin < slice.len and indexOfScalar(T, values_to_strip, slice[begin]) != null) : (begin += 1) {}
    return slice[begin..];
}

test trimStart {
    try testing.expectEqualSlices(u8, "foo\n ", trimStart(u8, " foo\n ", " \n"));
}

/// Deprecated: use `trimStart` instead.
pub const trimLeft = trimStart;

/// Remove a set of values from the end of a slice.
pub fn trimEnd(comptime T: type, slice: []const T, values_to_strip: []const T) []const T {
    var end: usize = slice.len;
    while (end > 0 and indexOfScalar(T, values_to_strip, slice[end - 1]) != null) : (end -= 1) {}
    return slice[0..end];
}

test trimEnd {
    try testing.expectEqualSlices(u8, " foo", trimEnd(u8, " foo\n ", " \n"));
}

/// Deprecated: use `trimEnd` instead.
pub const trimRight = trimEnd;

/// Remove a set of values from the beginning and end of a slice.
pub fn trim(comptime T: type, slice: []const T, values_to_strip: []const T) []const T {
    var begin: usize = 0;
    var end: usize = slice.len;
    while (begin < end and indexOfScalar(T, values_to_strip, slice[begin]) != null) : (begin += 1) {}
    while (end > begin and indexOfScalar(T, values_to_strip, slice[end - 1]) != null) : (end -= 1) {}
    return slice[begin..end];
}

test trim {
    try testing.expectEqualSlices(u8, "foo", trim(u8, " foo\n ", " \n"));
    try testing.expectEqualSlices(u8, "foo", trim(u8, "foo", " \n"));
}

/// Linear search for the index of a scalar value inside a slice.
pub fn indexOfScalar(comptime T: type, slice: []const T, value: T) ?usize {
    return indexOfScalarPos(T, slice, 0, value);
}

/// Linear search for the last index of a scalar value inside a slice.
pub fn lastIndexOfScalar(comptime T: type, slice: []const T, value: T) ?usize {
    var i: usize = slice.len;
    while (i != 0) {
        i -= 1;
        if (slice[i] == value) return i;
    }
    return null;
}

pub fn indexOfScalarPos(comptime T: type, slice: []const T, start_index: usize, value: T) ?usize {
    if (start_index >= slice.len) return null;

    var i: usize = start_index;
    if (backend_supports_vectors and
        !std.debug.inValgrind() and // https://github.com/ziglang/zig/issues/17717
        !@inComptime() and
        (@typeInfo(T) == .int or @typeInfo(T) == .float) and std.math.isPowerOfTwo(@bitSizeOf(T)))
    {
        if (std.simd.suggestVectorLength(T)) |block_len| {
            // For Intel Nehalem (2009) and AMD Bulldozer (2012) or later, unaligned loads on aligned data result
            // in the same execution as aligned loads. We ignore older arch's here and don't bother pre-aligning.
            //
            // Use `std.simd.suggestVectorLength(T)` to get the same alignment as used in this function
            // however this usually isn't necessary unless your arch has a performance penalty due to this.
            //
            // This may differ for other arch's. Arm for example costs a cycle when loading across a cache
            // line so explicit alignment prologues may be worth exploration.

            // Unrolling here is ~10% improvement. We can then do one bounds check every 2 blocks
            // instead of one which adds up.
            const Block = @Vector(block_len, T);
            if (i + 2 * block_len < slice.len) {
                const mask: Block = @splat(value);
                while (true) {
                    inline for (0..2) |_| {
                        const block: Block = slice[i..][0..block_len].*;
                        const matches = block == mask;
                        if (@reduce(.Or, matches)) {
                            return i + std.simd.firstTrue(matches).?;
                        }
                        i += block_len;
                    }
                    if (i + 2 * block_len >= slice.len) break;
                }
            }

            // {block_len, block_len / 2} check
            inline for (0..2) |j| {
                const block_x_len = block_len / (1 << j);
                comptime if (block_x_len < 4) break;

                const BlockX = @Vector(block_x_len, T);
                if (i + block_x_len < slice.len) {
                    const mask: BlockX = @splat(value);
                    const block: BlockX = slice[i..][0..block_x_len].*;
                    const matches = block == mask;
                    if (@reduce(.Or, matches)) {
                        return i + std.simd.firstTrue(matches).?;
                    }
                    i += block_x_len;
                }
            }
        }
    }

    for (slice[i..], i..) |c, j| {
        if (c == value) return j;
    }
    return null;
}

test indexOfScalarPos {
    const Types = [_]type{ u8, u16, u32, u64 };

    inline for (Types) |T| {
        var memory: [64 / @sizeOf(T)]T = undefined;
        @memset(&memory, 0xaa);
        memory[memory.len - 1] = 0;

        for (0..memory.len) |i| {
            try testing.expectEqual(memory.len - i - 1, indexOfScalarPos(T, memory[i..], 0, 0).?);
        }
    }
}

pub fn indexOfAny(comptime T: type, slice: []const T, values: []const T) ?usize {
    return indexOfAnyPos(T, slice, 0, values);
}

pub fn lastIndexOfAny(comptime T: type, slice: []const T, values: []const T) ?usize {
    var i: usize = slice.len;
    while (i != 0) {
        i -= 1;
        for (values) |value| {
            if (slice[i] == value) return i;
        }
    }
    return null;
}

pub fn indexOfAnyPos(comptime T: type, slice: []const T, start_index: usize, values: []const T) ?usize {
    if (start_index >= slice.len) return null;
    for (slice[start_index..], start_index..) |c, i| {
        for (values) |value| {
            if (c == value) return i;
        }
    }
    return null;
}

/// Find the first item in `slice` which is not contained in `values`.
///
/// Comparable to `strspn` in the C standard library.
pub fn indexOfNone(comptime T: type, slice: []const T, values: []const T) ?usize {
    return indexOfNonePos(T, slice, 0, values);
}

/// Find the last item in `slice` which is not contained in `values`.
///
/// Like `strspn` in the C standard library, but searches from the end.
pub fn lastIndexOfNone(comptime T: type, slice: []const T, values: []const T) ?usize {
    var i: usize = slice.len;
    outer: while (i != 0) {
        i -= 1;
        for (values) |value| {
            if (slice[i] == value) continue :outer;
        }
        return i;
    }
    return null;
}

/// Find the first item in `slice[start_index..]` which is not contained in `values`.
/// The returned index will be relative to the start of `slice`, and never less than `start_index`.
///
/// Comparable to `strspn` in the C standard library.
pub fn indexOfNonePos(comptime T: type, slice: []const T, start_index: usize, values: []const T) ?usize {
    if (start_index >= slice.len) return null;
    outer: for (slice[start_index..], start_index..) |c, i| {
        for (values) |value| {
            if (c == value) continue :outer;
        }
        return i;
    }
    return null;
}

test indexOfNone {
    try testing.expect(indexOfNone(u8, "abc123", "123").? == 0);
    try testing.expect(lastIndexOfNone(u8, "abc123", "123").? == 2);
    try testing.expect(indexOfNone(u8, "123abc", "123").? == 3);
    try testing.expect(lastIndexOfNone(u8, "123abc", "123").? == 5);
    try testing.expect(indexOfNone(u8, "123123", "123") == null);
    try testing.expect(indexOfNone(u8, "333333", "123") == null);

    try testing.expect(indexOfNonePos(u8, "abc123", 3, "321") == null);
}

pub fn indexOf(comptime T: type, haystack: []const T, needle: []const T) ?usize {
    return indexOfPos(T, haystack, 0, needle);
}

/// Find the index in a slice of a sub-slice, searching from the end backwards.
/// To start looking at a different index, slice the haystack first.
/// Consider using `lastIndexOf` instead of this, which will automatically use a
/// more sophisticated algorithm on larger inputs.
pub fn lastIndexOfLinear(comptime T: type, haystack: []const T, needle: []const T) ?usize {
    if (needle.len > haystack.len) return null;
    var i: usize = haystack.len - needle.len;
    while (true) : (i -= 1) {
        if (mem.eql(T, haystack[i..][0..needle.len], needle)) return i;
        if (i == 0) return null;
    }
}

/// Consider using `indexOfPos` instead of this, which will automatically use a
/// more sophisticated algorithm on larger inputs.
pub fn indexOfPosLinear(comptime T: type, haystack: []const T, start_index: usize, needle: []const T) ?usize {
    if (needle.len > haystack.len) return null;
    var i: usize = start_index;
    const end = haystack.len - needle.len;
    while (i <= end) : (i += 1) {
        if (eql(T, haystack[i..][0..needle.len], needle)) return i;
    }
    return null;
}

test indexOfPosLinear {
    try testing.expectEqual(0, indexOfPosLinear(u8, "", 0, ""));
    try testing.expectEqual(0, indexOfPosLinear(u8, "123", 0, ""));

    try testing.expectEqual(null, indexOfPosLinear(u8, "", 0, "1"));
    try testing.expectEqual(0, indexOfPosLinear(u8, "1", 0, "1"));
    try testing.expectEqual(null, indexOfPosLinear(u8, "2", 0, "1"));
    try testing.expectEqual(1, indexOfPosLinear(u8, "21", 0, "1"));
    try testing.expectEqual(null, indexOfPosLinear(u8, "222", 0, "1"));

    try testing.expectEqual(null, indexOfPosLinear(u8, "", 0, "12"));
    try testing.expectEqual(null, indexOfPosLinear(u8, "1", 0, "12"));
    try testing.expectEqual(null, indexOfPosLinear(u8, "2", 0, "12"));
    try testing.expectEqual(0, indexOfPosLinear(u8, "12", 0, "12"));
    try testing.expectEqual(null, indexOfPosLinear(u8, "21", 0, "12"));
    try testing.expectEqual(1, indexOfPosLinear(u8, "212", 0, "12"));
    try testing.expectEqual(0, indexOfPosLinear(u8, "122", 0, "12"));
    try testing.expectEqual(1, indexOfPosLinear(u8, "212112", 0, "12"));
}

fn boyerMooreHorspoolPreprocessReverse(pattern: []const u8, table: *[256]usize) void {
    for (table) |*c| {
        c.* = pattern.len;
    }

    var i: usize = pattern.len - 1;
    // The first item is intentionally ignored and the skip size will be pattern.len.
    // This is the standard way Boyer-Moore-Horspool is implemented.
    while (i > 0) : (i -= 1) {
        table[pattern[i]] = i;
    }
}

fn boyerMooreHorspoolPreprocess(pattern: []const u8, table: *[256]usize) void {
    for (table) |*c| {
        c.* = pattern.len;
    }

    var i: usize = 0;
    // The last item is intentionally ignored and the skip size will be pattern.len.
    // This is the standard way Boyer-Moore-Horspool is implemented.
    while (i < pattern.len - 1) : (i += 1) {
        table[pattern[i]] = pattern.len - 1 - i;
    }
}

/// Find the index in a slice of a sub-slice, searching from the end backwards.
/// To start looking at a different index, slice the haystack first.
/// Uses the Reverse Boyer-Moore-Horspool algorithm on large inputs;
/// `lastIndexOfLinear` on small inputs.
pub fn lastIndexOf(comptime T: type, haystack: []const T, needle: []const T) ?usize {
    if (needle.len > haystack.len) return null;
    if (needle.len == 0) return haystack.len;

    if (!std.meta.hasUniqueRepresentation(T) or haystack.len < 52 or needle.len <= 4)
        return lastIndexOfLinear(T, haystack, needle);

    const haystack_bytes = sliceAsBytes(haystack);
    const needle_bytes = sliceAsBytes(needle);

    var skip_table: [256]usize = undefined;
    boyerMooreHorspoolPreprocessReverse(needle_bytes, skip_table[0..]);

    var i: usize = haystack_bytes.len - needle_bytes.len;
    while (true) {
        if (i % @sizeOf(T) == 0 and mem.eql(u8, haystack_bytes[i .. i + needle_bytes.len], needle_bytes)) {
            return @divExact(i, @sizeOf(T));
        }
        const skip = skip_table[haystack_bytes[i]];
        if (skip > i) break;
        i -= skip;
    }

    return null;
}

/// Uses Boyer-Moore-Horspool algorithm on large inputs; `indexOfPosLinear` on small inputs.
pub fn indexOfPos(comptime T: type, haystack: []const T, start_index: usize, needle: []const T) ?usize {
    if (needle.len > haystack.len) return null;
    if (needle.len < 2) {
        if (needle.len == 0) return start_index;
        // indexOfScalarPos is significantly faster than indexOfPosLinear
        return indexOfScalarPos(T, haystack, start_index, needle[0]);
    }

    if (!std.meta.hasUniqueRepresentation(T) or haystack.len < 52 or needle.len <= 4)
        return indexOfPosLinear(T, haystack, start_index, needle);

    const haystack_bytes = sliceAsBytes(haystack);
    const needle_bytes = sliceAsBytes(needle);

    var skip_table: [256]usize = undefined;
    boyerMooreHorspoolPreprocess(needle_bytes, skip_table[0..]);

    var i: usize = start_index * @sizeOf(T);
    while (i <= haystack_bytes.len - needle_bytes.len) {
        if (i % @sizeOf(T) == 0 and mem.eql(u8, haystack_bytes[i .. i + needle_bytes.len], needle_bytes)) {
            return @divExact(i, @sizeOf(T));
        }
        i += skip_table[haystack_bytes[i + needle_bytes.len - 1]];
    }

    return null;
}

test indexOf {
    try testing.expect(indexOf(u8, "one two three four five six seven eight nine ten eleven", "three four").? == 8);
    try testing.expect(lastIndexOf(u8, "one two three four five six seven eight nine ten eleven", "three four").? == 8);
    try testing.expect(indexOf(u8, "one two three four five six seven eight nine ten eleven", "two two") == null);
    try testing.expect(lastIndexOf(u8, "one two three four five six seven eight nine ten eleven", "two two") == null);

    try testing.expect(indexOf(u8, "one two three four five six seven eight nine ten", "").? == 0);
    try testing.expect(lastIndexOf(u8, "one two three four five six seven eight nine ten", "").? == 48);

    try testing.expect(indexOf(u8, "one two three four", "four").? == 14);
    try testing.expect(lastIndexOf(u8, "one two three two four", "two").? == 14);
    try testing.expect(indexOf(u8, "one two three four", "gour") == null);
    try testing.expect(lastIndexOf(u8, "one two three four", "gour") == null);
    try testing.expect(indexOf(u8, "foo", "foo").? == 0);
    try testing.expect(lastIndexOf(u8, "foo", "foo").? == 0);
    try testing.expect(indexOf(u8, "foo", "fool") == null);
    try testing.expect(lastIndexOf(u8, "foo", "lfoo") == null);
    try testing.expect(lastIndexOf(u8, "foo", "fool") == null);

    try testing.expect(indexOf(u8, "foo foo", "foo").? == 0);
    try testing.expect(lastIndexOf(u8, "foo foo", "foo").? == 4);
    try testing.expect(lastIndexOfAny(u8, "boo, cat", "abo").? == 6);
    try testing.expect(lastIndexOfScalar(u8, "boo", 'o').? == 2);
}

test "indexOf multibyte" {
    {
        // make haystack and needle long enough to trigger Boyer-Moore-Horspool algorithm
        const haystack = [1]u16{0} ** 100 ++ [_]u16{ 0xbbaa, 0xccbb, 0xddcc, 0xeedd, 0xffee, 0x00ff };
        const needle = [_]u16{ 0xbbaa, 0xccbb, 0xddcc, 0xeedd, 0xffee };
        try testing.expectEqual(indexOfPos(u16, &haystack, 0, &needle), 100);

        // check for misaligned false positives (little and big endian)
        const needleLE = [_]u16{ 0xbbbb, 0xcccc, 0xdddd, 0xeeee, 0xffff };
        try testing.expectEqual(indexOfPos(u16, &haystack, 0, &needleLE), null);
        const needleBE = [_]u16{ 0xaacc, 0xbbdd, 0xccee, 0xddff, 0xee00 };
        try testing.expectEqual(indexOfPos(u16, &haystack, 0, &needleBE), null);
    }

    {
        // make haystack and needle long enough to trigger Boyer-Moore-Horspool algorithm
        const haystack = [_]u16{ 0xbbaa, 0xccbb, 0xddcc, 0xeedd, 0xffee, 0x00ff } ++ [1]u16{0} ** 100;
        const needle = [_]u16{ 0xbbaa, 0xccbb, 0xddcc, 0xeedd, 0xffee };
        try testing.expectEqual(lastIndexOf(u16, &haystack, &needle), 0);

        // check for misaligned false positives (little and big endian)
        const needleLE = [_]u16{ 0xbbbb, 0xcccc, 0xdddd, 0xeeee, 0xffff };
        try testing.expectEqual(lastIndexOf(u16, &haystack, &needleLE), null);
        const needleBE = [_]u16{ 0xaacc, 0xbbdd, 0xccee, 0xddff, 0xee00 };
        try testing.expectEqual(lastIndexOf(u16, &haystack, &needleBE), null);
    }
}

test "indexOfPos empty needle" {
    try testing.expectEqual(indexOfPos(u8, "abracadabra", 5, ""), 5);
}

/// Returns the number of needles inside the haystack
/// needle.len must be > 0
/// does not count overlapping needles
pub fn count(comptime T: type, haystack: []const T, needle: []const T) usize {
    assert(needle.len > 0);
    var i: usize = 0;
    var found: usize = 0;

    while (indexOfPos(T, haystack, i, needle)) |idx| {
        i = idx + needle.len;
        found += 1;
    }

    return found;
}

test count {
    try testing.expect(count(u8, "", "h") == 0);
    try testing.expect(count(u8, "h", "h") == 1);
    try testing.expect(count(u8, "hh", "h") == 2);
    try testing.expect(count(u8, "world!", "hello") == 0);
    try testing.expect(count(u8, "hello world!", "hello") == 1);
    try testing.expect(count(u8, "   abcabc   abc", "abc") == 3);
    try testing.expect(count(u8, "udexdcbvbruhasdrw", "bruh") == 1);
    try testing.expect(count(u8, "foo bar", "o bar") == 1);
    try testing.expect(count(u8, "foofoofoo", "foo") == 3);
    try testing.expect(count(u8, "fffffff", "ff") == 3);
    try testing.expect(count(u8, "owowowu", "owowu") == 1);
}

/// Returns true if the haystack contains expected_count or more needles
/// needle.len must be > 0
/// does not count overlapping needles
//
/// See also: `containsAtLeastScalar`
pub fn containsAtLeast(comptime T: type, haystack: []const T, expected_count: usize, needle: []const T) bool {
    assert(needle.len > 0);
    if (expected_count == 0) return true;

    var i: usize = 0;
    var found: usize = 0;

    while (indexOfPos(T, haystack, i, needle)) |idx| {
        i = idx + needle.len;
        found += 1;
        if (found == expected_count) return true;
    }
    return false;
}

test containsAtLeast {
    try testing.expect(containsAtLeast(u8, "aa", 0, "a"));
    try testing.expect(containsAtLeast(u8, "aa", 1, "a"));
    try testing.expect(containsAtLeast(u8, "aa", 2, "a"));
    try testing.expect(!containsAtLeast(u8, "aa", 3, "a"));

    try testing.expect(containsAtLeast(u8, "radaradar", 1, "radar"));
    try testing.expect(!containsAtLeast(u8, "radaradar", 2, "radar"));

    try testing.expect(containsAtLeast(u8, "radarradaradarradar", 3, "radar"));
    try testing.expect(!containsAtLeast(u8, "radarradaradarradar", 4, "radar"));

    try testing.expect(containsAtLeast(u8, "   radar      radar   ", 2, "radar"));
    try testing.expect(!containsAtLeast(u8, "   radar      radar   ", 3, "radar"));
}

/// Returns true if the haystack contains expected_count or more needles
//
/// See also: `containsAtLeast`
pub fn containsAtLeastScalar(comptime T: type, haystack: []const T, expected_count: usize, needle: T) bool {
    if (expected_count == 0) return true;

    var found: usize = 0;

    for (haystack) |item| {
        if (item == needle) {
            found += 1;
            if (found == expected_count) return true;
        }
    }

    return false;
}

test containsAtLeastScalar {
    try testing.expect(containsAtLeastScalar(u8, "aa", 0, 'a'));
    try testing.expect(containsAtLeastScalar(u8, "aa", 1, 'a'));
    try testing.expect(containsAtLeastScalar(u8, "aa", 2, 'a'));
    try testing.expect(!containsAtLeastScalar(u8, "aa", 3, 'a'));

    try testing.expect(containsAtLeastScalar(u8, "adadda", 3, 'd'));
    try testing.expect(!containsAtLeastScalar(u8, "adadda", 4, 'd'));
}

/// Reads an integer from memory with size equal to bytes.len.
/// T specifies the return type, which must be large enough to store
/// the result.
pub fn readVarInt(comptime ReturnType: type, bytes: []const u8, endian: Endian) ReturnType {
    assert(@typeInfo(ReturnType).int.bits >= bytes.len * 8);
    const bits = @typeInfo(ReturnType).int.bits;
    const signedness = @typeInfo(ReturnType).int.signedness;
    const WorkType = std.meta.Int(signedness, @max(16, bits));
    var result: WorkType = 0;
    switch (endian) {
        .big => {
            for (bytes) |b| {
                result = (result << 8) | b;
            }
        },
        .little => {
            const ShiftType = math.Log2Int(WorkType);
            for (bytes, 0..) |b, index| {
                result = result | (@as(WorkType, b) << @as(ShiftType, @intCast(index * 8)));
            }
        },
    }
    return @truncate(result);
}

test readVarInt {
    try testing.expect(readVarInt(u0, &[_]u8{}, .big) == 0x0);
    try testing.expect(readVarInt(u0, &[_]u8{}, .little) == 0x0);
    try testing.expect(readVarInt(u8, &[_]u8{0x12}, .big) == 0x12);
    try testing.expect(readVarInt(u8, &[_]u8{0xde}, .little) == 0xde);
    try testing.expect(readVarInt(u16, &[_]u8{ 0x12, 0x34 }, .big) == 0x1234);
    try testing.expect(readVarInt(u16, &[_]u8{ 0x12, 0x34 }, .little) == 0x3412);

    try testing.expect(readVarInt(i8, &[_]u8{0xff}, .big) == -1);
    try testing.expect(readVarInt(i8, &[_]u8{0xfe}, .little) == -2);
    try testing.expect(readVarInt(i16, &[_]u8{ 0xff, 0xfd }, .big) == -3);
    try testing.expect(readVarInt(i16, &[_]u8{ 0xfc, 0xff }, .little) == -4);

    // Return type can be oversized (bytes.len * 8 < @typeInfo(ReturnType).int.bits)
    try testing.expect(readVarInt(u9, &[_]u8{0x12}, .little) == 0x12);
    try testing.expect(readVarInt(u9, &[_]u8{0xde}, .big) == 0xde);
    try testing.expect(readVarInt(u80, &[_]u8{ 0x12, 0x34, 0x56, 0x78, 0x9a, 0xbc, 0xde, 0xf0, 0x24 }, .big) == 0x123456789abcdef024);
    try testing.expect(readVarInt(u80, &[_]u8{ 0xec, 0x10, 0x32, 0x54, 0x76, 0x98, 0xba, 0xdc, 0xfe }, .little) == 0xfedcba9876543210ec);

    try testing.expect(readVarInt(i9, &[_]u8{0xff}, .big) == 0xff);
    try testing.expect(readVarInt(i9, &[_]u8{0xfe}, .little) == 0xfe);
}

/// Loads an integer from packed memory with provided bit_count, bit_offset, and signedness.
/// Asserts that T is large enough to store the read value.
pub fn readVarPackedInt(
    comptime T: type,
    bytes: []const u8,
    bit_offset: usize,
    bit_count: usize,
    endian: std.builtin.Endian,
    signedness: std.builtin.Signedness,
) T {
    const uN = std.meta.Int(.unsigned, @bitSizeOf(T));
    const iN = std.meta.Int(.signed, @bitSizeOf(T));
    const Log2N = std.math.Log2Int(T);

    const read_size = (bit_count + (bit_offset % 8) + 7) / 8;
    const bit_shift = @as(u3, @intCast(bit_offset % 8));
    const pad = @as(Log2N, @intCast(@bitSizeOf(T) - bit_count));

    const lowest_byte = switch (endian) {
        .big => bytes.len - (bit_offset / 8) - read_size,
        .little => bit_offset / 8,
    };
    const read_bytes = bytes[lowest_byte..][0..read_size];

    if (@bitSizeOf(T) <= 8) {
        // These are the same shifts/masks we perform below, but adds `@truncate`/`@intCast`
        // where needed since int is smaller than a byte.
        const value = if (read_size == 1) b: {
            break :b @as(uN, @truncate(read_bytes[0] >> bit_shift));
        } else b: {
            const i: u1 = @intFromBool(endian == .big);
            const head = @as(uN, @truncate(read_bytes[i] >> bit_shift));
            const tail_shift = @as(Log2N, @intCast(@as(u4, 8) - bit_shift));
            const tail = @as(uN, @truncate(read_bytes[1 - i]));
            break :b (tail << tail_shift) | head;
        };
        switch (signedness) {
            .signed => return @as(T, @intCast((@as(iN, @bitCast(value)) << pad) >> pad)),
            .unsigned => return @as(T, @intCast((@as(uN, @bitCast(value)) << pad) >> pad)),
        }
    }

    // Copy the value out (respecting endianness), accounting for bit_shift
    var int: uN = 0;
    switch (endian) {
        .big => {
            for (read_bytes[0 .. read_size - 1]) |elem| {
                int = elem | (int << 8);
            }
            int = (read_bytes[read_size - 1] >> bit_shift) | (int << (@as(u4, 8) - bit_shift));
        },
        .little => {
            int = read_bytes[0] >> bit_shift;
            for (read_bytes[1..], 0..) |elem, i| {
                int |= (@as(uN, elem) << @as(Log2N, @intCast((8 * (i + 1) - bit_shift))));
            }
        },
    }
    switch (signedness) {
        .signed => return @as(T, @intCast((@as(iN, @bitCast(int)) << pad) >> pad)),
        .unsigned => return @as(T, @intCast((@as(uN, @bitCast(int)) << pad) >> pad)),
    }
}

test readVarPackedInt {
    const T = packed struct(u16) { a: u3, b: u7, c: u6 };
    var st = T{ .a = 1, .b = 2, .c = 4 };
    const b_field = readVarPackedInt(u64, std.mem.asBytes(&st), @bitOffsetOf(T, "b"), 7, builtin.cpu.arch.endian(), .unsigned);
    try std.testing.expectEqual(st.b, b_field);
}

/// Reads an integer from memory with bit count specified by T.
/// The bit count of T must be evenly divisible by 8.
/// This function cannot fail and cannot cause undefined behavior.
pub inline fn readInt(comptime T: type, buffer: *const [@divExact(@typeInfo(T).int.bits, 8)]u8, endian: Endian) T {
    const value: T = @bitCast(buffer.*);
    return if (endian == native_endian) value else @byteSwap(value);
}

test readInt {
    try testing.expect(readInt(u0, &[_]u8{}, .big) == 0x0);
    try testing.expect(readInt(u0, &[_]u8{}, .little) == 0x0);

    try testing.expect(readInt(u8, &[_]u8{0x32}, .big) == 0x32);
    try testing.expect(readInt(u8, &[_]u8{0x12}, .little) == 0x12);

    try testing.expect(readInt(u16, &[_]u8{ 0x12, 0x34 }, .big) == 0x1234);
    try testing.expect(readInt(u16, &[_]u8{ 0x12, 0x34 }, .little) == 0x3412);

    try testing.expect(readInt(u72, &[_]u8{ 0x12, 0x34, 0x56, 0x78, 0x9a, 0xbc, 0xde, 0xf0, 0x24 }, .big) == 0x123456789abcdef024);
    try testing.expect(readInt(u72, &[_]u8{ 0xec, 0x10, 0x32, 0x54, 0x76, 0x98, 0xba, 0xdc, 0xfe }, .little) == 0xfedcba9876543210ec);

    try testing.expect(readInt(i8, &[_]u8{0xff}, .big) == -1);
    try testing.expect(readInt(i8, &[_]u8{0xfe}, .little) == -2);

    try testing.expect(readInt(i16, &[_]u8{ 0xff, 0xfd }, .big) == -3);
    try testing.expect(readInt(i16, &[_]u8{ 0xfc, 0xff }, .little) == -4);

    try moreReadIntTests();
    try comptime moreReadIntTests();
}

fn readPackedIntLittle(comptime T: type, bytes: []const u8, bit_offset: usize) T {
    const uN = std.meta.Int(.unsigned, @bitSizeOf(T));
    const Log2N = std.math.Log2Int(T);

    const bit_count = @as(usize, @bitSizeOf(T));
    const bit_shift = @as(u3, @intCast(bit_offset % 8));

    const load_size = (bit_count + 7) / 8;
    const load_tail_bits = @as(u3, @intCast((load_size * 8) - bit_count));
    const LoadInt = std.meta.Int(.unsigned, load_size * 8);

    if (bit_count == 0)
        return 0;

    // Read by loading a LoadInt, and then follow it up with a 1-byte read
    // of the tail if bit_offset pushed us over a byte boundary.
    const read_bytes = bytes[bit_offset / 8 ..];
    const val = @as(uN, @truncate(readInt(LoadInt, read_bytes[0..load_size], .little) >> bit_shift));
    if (bit_shift > load_tail_bits) {
        const tail_bits = @as(Log2N, @intCast(bit_shift - load_tail_bits));
        const tail_byte = read_bytes[load_size];
        const tail_truncated = if (bit_count < 8) @as(uN, @truncate(tail_byte)) else @as(uN, tail_byte);
        return @as(T, @bitCast(val | (tail_truncated << (@as(Log2N, @truncate(bit_count)) -% tail_bits))));
    } else return @as(T, @bitCast(val));
}

fn readPackedIntBig(comptime T: type, bytes: []const u8, bit_offset: usize) T {
    const uN = std.meta.Int(.unsigned, @bitSizeOf(T));
    const Log2N = std.math.Log2Int(T);

    const bit_count = @as(usize, @bitSizeOf(T));
    const bit_shift = @as(u3, @intCast(bit_offset % 8));
    const byte_count = (@as(usize, bit_shift) + bit_count + 7) / 8;

    const load_size = (bit_count + 7) / 8;
    const load_tail_bits = @as(u3, @intCast((load_size * 8) - bit_count));
    const LoadInt = std.meta.Int(.unsigned, load_size * 8);

    if (bit_count == 0)
        return 0;

    // Read by loading a LoadInt, and then follow it up with a 1-byte read
    // of the tail if bit_offset pushed us over a byte boundary.
    const end = bytes.len - (bit_offset / 8);
    const read_bytes = bytes[(end - byte_count)..end];
    const val = @as(uN, @truncate(readInt(LoadInt, bytes[(end - load_size)..end][0..load_size], .big) >> bit_shift));
    if (bit_shift > load_tail_bits) {
        const tail_bits = @as(Log2N, @intCast(bit_shift - load_tail_bits));
        const tail_byte = if (bit_count < 8) @as(uN, @truncate(read_bytes[0])) else @as(uN, read_bytes[0]);
        return @as(T, @bitCast(val | (tail_byte << (@as(Log2N, @truncate(bit_count)) -% tail_bits))));
    } else return @as(T, @bitCast(val));
}

pub const readPackedIntNative = switch (native_endian) {
    .little => readPackedIntLittle,
    .big => readPackedIntBig,
};

pub const readPackedIntForeign = switch (native_endian) {
    .little => readPackedIntBig,
    .big => readPackedIntLittle,
};

/// Loads an integer from packed memory.
/// Asserts that buffer contains at least bit_offset + @bitSizeOf(T) bits.
pub fn readPackedInt(comptime T: type, bytes: []const u8, bit_offset: usize, endian: Endian) T {
    switch (endian) {
        .little => return readPackedIntLittle(T, bytes, bit_offset),
        .big => return readPackedIntBig(T, bytes, bit_offset),
    }
}

test readPackedInt {
    const T = packed struct(u16) { a: u3, b: u7, c: u6 };
    var st = T{ .a = 1, .b = 2, .c = 4 };
    const b_field = readPackedInt(u7, std.mem.asBytes(&st), @bitOffsetOf(T, "b"), builtin.cpu.arch.endian());
    try std.testing.expectEqual(st.b, b_field);
}

test "comptime read/write int" {
    comptime {
        var bytes: [2]u8 = undefined;
        writeInt(u16, &bytes, 0x1234, .little);
        const result = readInt(u16, &bytes, .big);
        try testing.expect(result == 0x3412);
    }
    comptime {
        var bytes: [2]u8 = undefined;
        writeInt(u16, &bytes, 0x1234, .big);
        const result = readInt(u16, &bytes, .little);
        try testing.expect(result == 0x3412);
    }
}

/// Writes an integer to memory, storing it in twos-complement.
/// This function always succeeds, has defined behavior for all inputs, but
/// the integer bit width must be divisible by 8.
pub inline fn writeInt(comptime T: type, buffer: *[@divExact(@typeInfo(T).int.bits, 8)]u8, value: T, endian: Endian) void {
    buffer.* = @bitCast(if (endian == native_endian) value else @byteSwap(value));
}

test writeInt {
    var buf0: [0]u8 = undefined;
    var buf1: [1]u8 = undefined;
    var buf2: [2]u8 = undefined;
    var buf9: [9]u8 = undefined;

    writeInt(u0, &buf0, 0x0, .big);
    try testing.expect(eql(u8, buf0[0..], &[_]u8{}));
    writeInt(u0, &buf0, 0x0, .little);
    try testing.expect(eql(u8, buf0[0..], &[_]u8{}));

    writeInt(u8, &buf1, 0x12, .big);
    try testing.expect(eql(u8, buf1[0..], &[_]u8{0x12}));
    writeInt(u8, &buf1, 0x34, .little);
    try testing.expect(eql(u8, buf1[0..], &[_]u8{0x34}));

    writeInt(u16, &buf2, 0x1234, .big);
    try testing.expect(eql(u8, buf2[0..], &[_]u8{ 0x12, 0x34 }));
    writeInt(u16, &buf2, 0x5678, .little);
    try testing.expect(eql(u8, buf2[0..], &[_]u8{ 0x78, 0x56 }));

    writeInt(u72, &buf9, 0x123456789abcdef024, .big);
    try testing.expect(eql(u8, buf9[0..], &[_]u8{ 0x12, 0x34, 0x56, 0x78, 0x9a, 0xbc, 0xde, 0xf0, 0x24 }));
    writeInt(u72, &buf9, 0xfedcba9876543210ec, .little);
    try testing.expect(eql(u8, buf9[0..], &[_]u8{ 0xec, 0x10, 0x32, 0x54, 0x76, 0x98, 0xba, 0xdc, 0xfe }));

    writeInt(i8, &buf1, -1, .big);
    try testing.expect(eql(u8, buf1[0..], &[_]u8{0xff}));
    writeInt(i8, &buf1, -2, .little);
    try testing.expect(eql(u8, buf1[0..], &[_]u8{0xfe}));

    writeInt(i16, &buf2, -3, .big);
    try testing.expect(eql(u8, buf2[0..], &[_]u8{ 0xff, 0xfd }));
    writeInt(i16, &buf2, -4, .little);
    try testing.expect(eql(u8, buf2[0..], &[_]u8{ 0xfc, 0xff }));
}

fn writePackedIntLittle(comptime T: type, bytes: []u8, bit_offset: usize, value: T) void {
    const uN = std.meta.Int(.unsigned, @bitSizeOf(T));
    const Log2N = std.math.Log2Int(T);

    const bit_count = @as(usize, @bitSizeOf(T));
    const bit_shift = @as(u3, @intCast(bit_offset % 8));

    const store_size = (@bitSizeOf(T) + 7) / 8;
    const store_tail_bits = @as(u3, @intCast((store_size * 8) - bit_count));
    const StoreInt = std.meta.Int(.unsigned, store_size * 8);

    if (bit_count == 0)
        return;

    // Write by storing a StoreInt, and then follow it up with a 1-byte tail
    // if bit_offset pushed us over a byte boundary.
    const write_bytes = bytes[bit_offset / 8 ..];
    const head = write_bytes[0] & ((@as(u8, 1) << bit_shift) - 1);

    var write_value = (@as(StoreInt, @as(uN, @bitCast(value))) << bit_shift) | @as(StoreInt, @intCast(head));
    if (bit_shift > store_tail_bits) {
        const tail_len = @as(Log2N, @intCast(bit_shift - store_tail_bits));
        write_bytes[store_size] &= ~((@as(u8, 1) << @as(u3, @intCast(tail_len))) - 1);
        write_bytes[store_size] |= @as(u8, @intCast((@as(uN, @bitCast(value)) >> (@as(Log2N, @truncate(bit_count)) -% tail_len))));
    } else if (bit_shift < store_tail_bits) {
        const tail_len = store_tail_bits - bit_shift;
        const tail = write_bytes[store_size - 1] & (@as(u8, 0xfe) << (7 - tail_len));
        write_value |= @as(StoreInt, tail) << (8 * (store_size - 1));
    }

    writeInt(StoreInt, write_bytes[0..store_size], write_value, .little);
}

fn writePackedIntBig(comptime T: type, bytes: []u8, bit_offset: usize, value: T) void {
    const uN = std.meta.Int(.unsigned, @bitSizeOf(T));
    const Log2N = std.math.Log2Int(T);

    const bit_count = @as(usize, @bitSizeOf(T));
    const bit_shift = @as(u3, @intCast(bit_offset % 8));
    const byte_count = (bit_shift + bit_count + 7) / 8;

    const store_size = (@bitSizeOf(T) + 7) / 8;
    const store_tail_bits = @as(u3, @intCast((store_size * 8) - bit_count));
    const StoreInt = std.meta.Int(.unsigned, store_size * 8);

    if (bit_count == 0)
        return;

    // Write by storing a StoreInt, and then follow it up with a 1-byte tail
    // if bit_offset pushed us over a byte boundary.
    const end = bytes.len - (bit_offset / 8);
    const write_bytes = bytes[(end - byte_count)..end];
    const head = write_bytes[byte_count - 1] & ((@as(u8, 1) << bit_shift) - 1);

    var write_value = (@as(StoreInt, @as(uN, @bitCast(value))) << bit_shift) | @as(StoreInt, @intCast(head));
    if (bit_shift > store_tail_bits) {
        const tail_len = @as(Log2N, @intCast(bit_shift - store_tail_bits));
        write_bytes[0] &= ~((@as(u8, 1) << @as(u3, @intCast(tail_len))) - 1);
        write_bytes[0] |= @as(u8, @intCast((@as(uN, @bitCast(value)) >> (@as(Log2N, @truncate(bit_count)) -% tail_len))));
    } else if (bit_shift < store_tail_bits) {
        const tail_len = store_tail_bits - bit_shift;
        const tail = write_bytes[0] & (@as(u8, 0xfe) << (7 - tail_len));
        write_value |= @as(StoreInt, tail) << (8 * (store_size - 1));
    }

    writeInt(StoreInt, write_bytes[(byte_count - store_size)..][0..store_size], write_value, .big);
}

pub const writePackedIntNative = switch (native_endian) {
    .little => writePackedIntLittle,
    .big => writePackedIntBig,
};

pub const writePackedIntForeign = switch (native_endian) {
    .little => writePackedIntBig,
    .big => writePackedIntLittle,
};

/// Stores an integer to packed memory.
/// Asserts that buffer contains at least bit_offset + @bitSizeOf(T) bits.
pub fn writePackedInt(comptime T: type, bytes: []u8, bit_offset: usize, value: T, endian: Endian) void {
    switch (endian) {
        .little => writePackedIntLittle(T, bytes, bit_offset, value),
        .big => writePackedIntBig(T, bytes, bit_offset, value),
    }
}

test writePackedInt {
    const T = packed struct(u16) { a: u3, b: u7, c: u6 };
    var st = T{ .a = 1, .b = 2, .c = 4 };
    writePackedInt(u7, std.mem.asBytes(&st), @bitOffsetOf(T, "b"), 0x7f, builtin.cpu.arch.endian());
    try std.testing.expectEqual(T{ .a = 1, .b = 0x7f, .c = 4 }, st);
}

/// Stores an integer to packed memory with provided bit_offset, bit_count, and signedness.
/// If negative, the written value is sign-extended.
pub fn writeVarPackedInt(bytes: []u8, bit_offset: usize, bit_count: usize, value: anytype, endian: std.builtin.Endian) void {
    const T = @TypeOf(value);
    const uN = std.meta.Int(.unsigned, @bitSizeOf(T));

    const bit_shift = @as(u3, @intCast(bit_offset % 8));
    const write_size = (bit_count + bit_shift + 7) / 8;
    const lowest_byte = switch (endian) {
        .big => bytes.len - (bit_offset / 8) - write_size,
        .little => bit_offset / 8,
    };
    const write_bytes = bytes[lowest_byte..][0..write_size];

    if (write_size == 0) {
        return;
    } else if (write_size == 1) {
        // Single byte writes are handled specially, since we need to mask bits
        // on both ends of the byte.
        const mask = (@as(u8, 0xff) >> @as(u3, @intCast(8 - bit_count)));
        const new_bits = @as(u8, @intCast(@as(uN, @bitCast(value)) & mask)) << bit_shift;
        write_bytes[0] = (write_bytes[0] & ~(mask << bit_shift)) | new_bits;
        return;
    }

    var remaining: T = value;

    // Iterate bytes forward for Little-endian, backward for Big-endian
    const delta: i2 = if (endian == .big) -1 else 1;
    const start = if (endian == .big) @as(isize, @intCast(write_bytes.len - 1)) else 0;

    var i: isize = start; // isize for signed index arithmetic

    // Write first byte, using a mask to protects bits preceding bit_offset
    const head_mask = @as(u8, 0xff) >> bit_shift;
    write_bytes[@intCast(i)] &= ~(head_mask << bit_shift);
    write_bytes[@intCast(i)] |= @as(u8, @intCast(@as(uN, @bitCast(remaining)) & head_mask)) << bit_shift;
    remaining = math.shr(T, remaining, @as(u4, 8) - bit_shift);
    i += delta;

    // Write bytes[1..bytes.len - 1]
    if (@bitSizeOf(T) > 8) {
        const loop_end = start + delta * (@as(isize, @intCast(write_size)) - 1);
        while (i != loop_end) : (i += delta) {
            write_bytes[@as(usize, @intCast(i))] = @as(u8, @truncate(@as(uN, @bitCast(remaining))));
            remaining >>= 8;
        }
    }

    // Write last byte, using a mask to protect bits following bit_offset + bit_count
    const following_bits = -%@as(u3, @truncate(bit_shift + bit_count));
    const tail_mask = (@as(u8, 0xff) << following_bits) >> following_bits;
    write_bytes[@as(usize, @intCast(i))] &= ~tail_mask;
    write_bytes[@as(usize, @intCast(i))] |= @as(u8, @intCast(@as(uN, @bitCast(remaining)) & tail_mask));
}

test writeVarPackedInt {
    const T = packed struct(u16) { a: u3, b: u7, c: u6 };
    var st = T{ .a = 1, .b = 2, .c = 4 };
    const value: u64 = 0x7f;
    writeVarPackedInt(std.mem.asBytes(&st), @bitOffsetOf(T, "b"), 7, value, builtin.cpu.arch.endian());
    try testing.expectEqual(T{ .a = 1, .b = value, .c = 4 }, st);
}

/// Swap the byte order of all the members of the fields of a struct
/// (Changing their endianness)
pub fn byteSwapAllFields(comptime S: type, ptr: *S) void {
    switch (@typeInfo(S)) {
        .@"struct" => {
            inline for (std.meta.fields(S)) |f| {
                switch (@typeInfo(f.type)) {
                    .@"struct" => |struct_info| if (struct_info.backing_integer) |Int| {
                        @field(ptr, f.name) = @bitCast(@byteSwap(@as(Int, @bitCast(@field(ptr, f.name)))));
                    } else {
                        byteSwapAllFields(f.type, &@field(ptr, f.name));
                    },
                    .@"union", .array => byteSwapAllFields(f.type, &@field(ptr, f.name)),
                    .@"enum" => {
                        @field(ptr, f.name) = @enumFromInt(@byteSwap(@intFromEnum(@field(ptr, f.name))));
                    },
                    .bool => {},
                    .float => |float_info| {
                        @field(ptr, f.name) = @bitCast(@byteSwap(@as(std.meta.Int(.unsigned, float_info.bits), @bitCast(@field(ptr, f.name)))));
                    },
                    else => {
                        @field(ptr, f.name) = @byteSwap(@field(ptr, f.name));
                    },
                }
            }
        },
        .@"union" => |union_info| {
            if (union_info.tag_type != null) {
                @compileError("byteSwapAllFields expects an untagged union");
            }

            const first_size = @bitSizeOf(union_info.fields[0].type);
            inline for (union_info.fields) |field| {
                if (@bitSizeOf(field.type) != first_size) {
                    @compileError("Unable to byte-swap unions with varying field sizes");
                }
            }

            const BackingInt = std.meta.Int(.unsigned, @bitSizeOf(S));
            ptr.* = @bitCast(@byteSwap(@as(BackingInt, @bitCast(ptr.*))));
        },
        .array => |info| {
            byteSwapAllElements(info.child, ptr);
        },
        else => {
            ptr.* = @byteSwap(ptr.*);
        },
    }
}

test byteSwapAllFields {
    const T = extern struct {
        f0: u8,
        f1: u16,
        f2: u32,
        f3: [1]u8,
        f4: bool,
        f5: f32,
        f6: extern union { f0: u16, f1: u16 },
    };
    const K = extern struct {
        f0: u8,
        f1: T,
        f2: u16,
        f3: [1]u8,
        f4: bool,
        f5: f32,
    };
    var s = T{
        .f0 = 0x12,
        .f1 = 0x1234,
        .f2 = 0x12345678,
        .f3 = .{0x12},
        .f4 = true,
        .f5 = @as(f32, @bitCast(@as(u32, 0x4640e400))),
        .f6 = .{ .f0 = 0x1234 },
    };
    var k = K{
        .f0 = 0x12,
        .f1 = s,
        .f2 = 0x1234,
        .f3 = .{0x12},
        .f4 = false,
        .f5 = @as(f32, @bitCast(@as(u32, 0x45d42800))),
    };
    byteSwapAllFields(T, &s);
    byteSwapAllFields(K, &k);
    try std.testing.expectEqual(T{
        .f0 = 0x12,
        .f1 = 0x3412,
        .f2 = 0x78563412,
        .f3 = .{0x12},
        .f4 = true,
        .f5 = @as(f32, @bitCast(@as(u32, 0x00e44046))),
        .f6 = .{ .f0 = 0x3412 },
    }, s);
    try std.testing.expectEqual(K{
        .f0 = 0x12,
        .f1 = s,
        .f2 = 0x3412,
        .f3 = .{0x12},
        .f4 = false,
        .f5 = @as(f32, @bitCast(@as(u32, 0x0028d445))),
    }, k);
}

pub fn byteSwapAllElements(comptime Elem: type, slice: []Elem) void {
    for (slice) |*elem| {
        switch (@typeInfo(@TypeOf(elem.*))) {
            .@"struct", .@"union", .array => byteSwapAllFields(@TypeOf(elem.*), elem),
            .@"enum" => {
                elem.* = @enumFromInt(@byteSwap(@intFromEnum(elem.*)));
            },
            .bool => {},
            .float => |float_info| {
                elem.* = @bitCast(@byteSwap(@as(std.meta.Int(.unsigned, float_info.bits), @bitCast(elem.*))));
            },
            else => {
                elem.* = @byteSwap(elem.*);
            },
        }
    }
}

/// Returns an iterator that iterates over the slices of `buffer` that are not
/// any of the items in `delimiters`.
///
/// `tokenizeAny(u8, "   abc|def ||  ghi  ", " |")` will return slices
/// for "abc", "def", "ghi", null, in that order.
///
/// If `buffer` is empty, the iterator will return null.
/// If none of `delimiters` exist in buffer,
/// the iterator will return `buffer`, null, in that order.
///
/// See also: `tokenizeSequence`, `tokenizeScalar`,
///           `splitSequence`,`splitAny`, `splitScalar`,
///           `splitBackwardsSequence`, `splitBackwardsAny`, and `splitBackwardsScalar`
pub fn tokenizeAny(comptime T: type, buffer: []const T, delimiters: []const T) TokenIterator(T, .any) {
    return .{
        .index = 0,
        .buffer = buffer,
        .delimiter = delimiters,
    };
}

/// Returns an iterator that iterates over the slices of `buffer` that are not
/// the sequence in `delimiter`.
///
/// `tokenizeSequence(u8, "<>abc><def<><>ghi", "<>")` will return slices
/// for "abc><def", "ghi", null, in that order.
///
/// If `buffer` is empty, the iterator will return null.
/// If `delimiter` does not exist in buffer,
/// the iterator will return `buffer`, null, in that order.
/// The delimiter length must not be zero.
///
/// See also: `tokenizeAny`, `tokenizeScalar`,
///           `splitSequence`,`splitAny`, and `splitScalar`
///           `splitBackwardsSequence`, `splitBackwardsAny`, and `splitBackwardsScalar`
pub fn tokenizeSequence(comptime T: type, buffer: []const T, delimiter: []const T) TokenIterator(T, .sequence) {
    assert(delimiter.len != 0);
    return .{
        .index = 0,
        .buffer = buffer,
        .delimiter = delimiter,
    };
}

/// Returns an iterator that iterates over the slices of `buffer` that are not
/// `delimiter`.
///
/// `tokenizeScalar(u8, "   abc def     ghi  ", ' ')` will return slices
/// for "abc", "def", "ghi", null, in that order.
///
/// If `buffer` is empty, the iterator will return null.
/// If `delimiter` does not exist in buffer,
/// the iterator will return `buffer`, null, in that order.
///
/// See also: `tokenizeAny`, `tokenizeSequence`,
///           `splitSequence`,`splitAny`, and `splitScalar`
///           `splitBackwardsSequence`, `splitBackwardsAny`, and `splitBackwardsScalar`
pub fn tokenizeScalar(comptime T: type, buffer: []const T, delimiter: T) TokenIterator(T, .scalar) {
    return .{
        .index = 0,
        .buffer = buffer,
        .delimiter = delimiter,
    };
}

test tokenizeScalar {
    var it = tokenizeScalar(u8, "   abc def   ghi  ", ' ');
    try testing.expect(eql(u8, it.next().?, "abc"));
    try testing.expect(eql(u8, it.peek().?, "def"));
    try testing.expect(eql(u8, it.next().?, "def"));
    try testing.expect(eql(u8, it.next().?, "ghi"));
    try testing.expect(it.next() == null);

    it = tokenizeScalar(u8, "..\\bob", '\\');
    try testing.expect(eql(u8, it.next().?, ".."));
    try testing.expect(eql(u8, "..", "..\\bob"[0..it.index]));
    try testing.expect(eql(u8, it.next().?, "bob"));
    try testing.expect(it.next() == null);

    it = tokenizeScalar(u8, "//a/b", '/');
    try testing.expect(eql(u8, it.next().?, "a"));
    try testing.expect(eql(u8, it.next().?, "b"));
    try testing.expect(eql(u8, "//a/b", "//a/b"[0..it.index]));
    try testing.expect(it.next() == null);

    it = tokenizeScalar(u8, "|", '|');
    try testing.expect(it.next() == null);
    try testing.expect(it.peek() == null);

    it = tokenizeScalar(u8, "", '|');
    try testing.expect(it.next() == null);
    try testing.expect(it.peek() == null);

    it = tokenizeScalar(u8, "hello", ' ');
    try testing.expect(eql(u8, it.next().?, "hello"));
    try testing.expect(it.next() == null);

    var it16 = tokenizeScalar(
        u16,
        std.unicode.utf8ToUtf16LeStringLiteral("hello"),
        ' ',
    );
    try testing.expect(eql(u16, it16.next().?, std.unicode.utf8ToUtf16LeStringLiteral("hello")));
    try testing.expect(it16.next() == null);
}

test tokenizeAny {
    var it = tokenizeAny(u8, "a|b,c/d e", " /,|");
    try testing.expect(eql(u8, it.next().?, "a"));
    try testing.expect(eql(u8, it.peek().?, "b"));
    try testing.expect(eql(u8, it.next().?, "b"));
    try testing.expect(eql(u8, it.next().?, "c"));
    try testing.expect(eql(u8, it.next().?, "d"));
    try testing.expect(eql(u8, it.next().?, "e"));
    try testing.expect(it.next() == null);
    try testing.expect(it.peek() == null);

    it = tokenizeAny(u8, "hello", "");
    try testing.expect(eql(u8, it.next().?, "hello"));
    try testing.expect(it.next() == null);

    var it16 = tokenizeAny(
        u16,
        std.unicode.utf8ToUtf16LeStringLiteral("a|b,c/d e"),
        std.unicode.utf8ToUtf16LeStringLiteral(" /,|"),
    );
    try testing.expect(eql(u16, it16.next().?, std.unicode.utf8ToUtf16LeStringLiteral("a")));
    try testing.expect(eql(u16, it16.next().?, std.unicode.utf8ToUtf16LeStringLiteral("b")));
    try testing.expect(eql(u16, it16.next().?, std.unicode.utf8ToUtf16LeStringLiteral("c")));
    try testing.expect(eql(u16, it16.next().?, std.unicode.utf8ToUtf16LeStringLiteral("d")));
    try testing.expect(eql(u16, it16.next().?, std.unicode.utf8ToUtf16LeStringLiteral("e")));
    try testing.expect(it16.next() == null);
}

test tokenizeSequence {
    var it = tokenizeSequence(u8, "a<>b<><>c><>d><", "<>");
    try testing.expectEqualStrings("a", it.next().?);
    try testing.expectEqualStrings("b", it.peek().?);
    try testing.expectEqualStrings("b", it.next().?);
    try testing.expectEqualStrings("c>", it.next().?);
    try testing.expectEqualStrings("d><", it.next().?);
    try testing.expect(it.next() == null);
    try testing.expect(it.peek() == null);

    var it16 = tokenizeSequence(
        u16,
        std.unicode.utf8ToUtf16LeStringLiteral("a<>b<><>c><>d><"),
        std.unicode.utf8ToUtf16LeStringLiteral("<>"),
    );
    try testing.expect(eql(u16, it16.next().?, std.unicode.utf8ToUtf16LeStringLiteral("a")));
    try testing.expect(eql(u16, it16.next().?, std.unicode.utf8ToUtf16LeStringLiteral("b")));
    try testing.expect(eql(u16, it16.next().?, std.unicode.utf8ToUtf16LeStringLiteral("c>")));
    try testing.expect(eql(u16, it16.next().?, std.unicode.utf8ToUtf16LeStringLiteral("d><")));
    try testing.expect(it16.next() == null);
}

test "tokenize (reset)" {
    {
        var it = tokenizeAny(u8, "   abc def   ghi  ", " ");
        try testing.expect(eql(u8, it.next().?, "abc"));
        try testing.expect(eql(u8, it.next().?, "def"));
        try testing.expect(eql(u8, it.next().?, "ghi"));

        it.reset();

        try testing.expect(eql(u8, it.next().?, "abc"));
        try testing.expect(eql(u8, it.next().?, "def"));
        try testing.expect(eql(u8, it.next().?, "ghi"));
        try testing.expect(it.next() == null);
    }
    {
        var it = tokenizeSequence(u8, "<><>abc<>def<><>ghi<>", "<>");
        try testing.expect(eql(u8, it.next().?, "abc"));
        try testing.expect(eql(u8, it.next().?, "def"));
        try testing.expect(eql(u8, it.next().?, "ghi"));

        it.reset();

        try testing.expect(eql(u8, it.next().?, "abc"));
        try testing.expect(eql(u8, it.next().?, "def"));
        try testing.expect(eql(u8, it.next().?, "ghi"));
        try testing.expect(it.next() == null);
    }
    {
        var it = tokenizeScalar(u8, "   abc def   ghi  ", ' ');
        try testing.expect(eql(u8, it.next().?, "abc"));
        try testing.expect(eql(u8, it.next().?, "def"));
        try testing.expect(eql(u8, it.next().?, "ghi"));

        it.reset();

        try testing.expect(eql(u8, it.next().?, "abc"));
        try testing.expect(eql(u8, it.next().?, "def"));
        try testing.expect(eql(u8, it.next().?, "ghi"));
        try testing.expect(it.next() == null);
    }
}

/// Returns an iterator that iterates over the slices of `buffer` that
/// are separated by the byte sequence in `delimiter`.
///
/// `splitSequence(u8, "abc||def||||ghi", "||")` will return slices
/// for "abc", "def", "", "ghi", null, in that order.
///
/// If `delimiter` does not exist in buffer,
/// the iterator will return `buffer`, null, in that order.
/// The delimiter length must not be zero.
///
/// See also: `splitAny`, `splitScalar`, `splitBackwardsSequence`,
///           `splitBackwardsAny`,`splitBackwardsScalar`,
///           `tokenizeAny`, `tokenizeSequence`, and `tokenizeScalar`.
pub fn splitSequence(comptime T: type, buffer: []const T, delimiter: []const T) SplitIterator(T, .sequence) {
    assert(delimiter.len != 0);
    return .{
        .index = 0,
        .buffer = buffer,
        .delimiter = delimiter,
    };
}

/// Returns an iterator that iterates over the slices of `buffer` that
/// are separated by any item in `delimiters`.
///
/// `splitAny(u8, "abc,def||ghi", "|,")` will return slices
/// for "abc", "def", "", "ghi", null, in that order.
///
/// If none of `delimiters` exist in buffer,
/// the iterator will return `buffer`, null, in that order.
///
/// See also: `splitSequence`, `splitScalar`, `splitBackwardsSequence`,
///           `splitBackwardsAny`,`splitBackwardsScalar`,
///           `tokenizeAny`, `tokenizeSequence`, and `tokenizeScalar`.
pub fn splitAny(comptime T: type, buffer: []const T, delimiters: []const T) SplitIterator(T, .any) {
    return .{
        .index = 0,
        .buffer = buffer,
        .delimiter = delimiters,
    };
}

/// Returns an iterator that iterates over the slices of `buffer` that
/// are separated by `delimiter`.
///
/// `splitScalar(u8, "abc|def||ghi", '|')` will return slices
/// for "abc", "def", "", "ghi", null, in that order.
///
/// If `delimiter` does not exist in buffer,
/// the iterator will return `buffer`, null, in that order.
///
/// See also: `splitSequence`, `splitAny`, `splitBackwardsSequence`,
///           `splitBackwardsAny`,`splitBackwardsScalar`,
///           `tokenizeAny`, `tokenizeSequence`, and `tokenizeScalar`.
pub fn splitScalar(comptime T: type, buffer: []const T, delimiter: T) SplitIterator(T, .scalar) {
    return .{
        .index = 0,
        .buffer = buffer,
        .delimiter = delimiter,
    };
}

test splitScalar {
    var it = splitScalar(u8, "abc|def||ghi", '|');
    try testing.expectEqualSlices(u8, it.rest(), "abc|def||ghi");
    try testing.expectEqualSlices(u8, it.first(), "abc");

    try testing.expectEqualSlices(u8, it.rest(), "def||ghi");
    try testing.expectEqualSlices(u8, it.peek().?, "def");
    try testing.expectEqualSlices(u8, it.next().?, "def");

    try testing.expectEqualSlices(u8, it.rest(), "|ghi");
    try testing.expectEqualSlices(u8, it.next().?, "");

    try testing.expectEqualSlices(u8, it.rest(), "ghi");
    try testing.expectEqualSlices(u8, it.peek().?, "ghi");
    try testing.expectEqualSlices(u8, it.next().?, "ghi");

    try testing.expectEqualSlices(u8, it.rest(), "");
    try testing.expect(it.peek() == null);
    try testing.expect(it.next() == null);

    it = splitScalar(u8, "", '|');
    try testing.expectEqualSlices(u8, it.first(), "");
    try testing.expect(it.next() == null);

    it = splitScalar(u8, "|", '|');
    try testing.expectEqualSlices(u8, it.first(), "");
    try testing.expectEqualSlices(u8, it.next().?, "");
    try testing.expect(it.peek() == null);
    try testing.expect(it.next() == null);

    it = splitScalar(u8, "hello", ' ');
    try testing.expectEqualSlices(u8, it.first(), "hello");
    try testing.expect(it.next() == null);

    var it16 = splitScalar(
        u16,
        std.unicode.utf8ToUtf16LeStringLiteral("hello"),
        ' ',
    );
    try testing.expectEqualSlices(u16, it16.first(), std.unicode.utf8ToUtf16LeStringLiteral("hello"));
    try testing.expect(it16.next() == null);
}

test splitSequence {
    var it = splitSequence(u8, "a, b ,, c, d, e", ", ");
    try testing.expectEqualSlices(u8, it.first(), "a");
    try testing.expectEqualSlices(u8, it.rest(), "b ,, c, d, e");
    try testing.expectEqualSlices(u8, it.next().?, "b ,");
    try testing.expectEqualSlices(u8, it.next().?, "c");
    try testing.expectEqualSlices(u8, it.next().?, "d");
    try testing.expectEqualSlices(u8, it.next().?, "e");
    try testing.expect(it.next() == null);

    var it16 = splitSequence(
        u16,
        std.unicode.utf8ToUtf16LeStringLiteral("a, b ,, c, d, e"),
        std.unicode.utf8ToUtf16LeStringLiteral(", "),
    );
    try testing.expectEqualSlices(u16, it16.first(), std.unicode.utf8ToUtf16LeStringLiteral("a"));
    try testing.expectEqualSlices(u16, it16.next().?, std.unicode.utf8ToUtf16LeStringLiteral("b ,"));
    try testing.expectEqualSlices(u16, it16.next().?, std.unicode.utf8ToUtf16LeStringLiteral("c"));
    try testing.expectEqualSlices(u16, it16.next().?, std.unicode.utf8ToUtf16LeStringLiteral("d"));
    try testing.expectEqualSlices(u16, it16.next().?, std.unicode.utf8ToUtf16LeStringLiteral("e"));
    try testing.expect(it16.next() == null);
}

test splitAny {
    var it = splitAny(u8, "a,b, c d e", ", ");
    try testing.expectEqualSlices(u8, it.first(), "a");
    try testing.expectEqualSlices(u8, it.rest(), "b, c d e");
    try testing.expectEqualSlices(u8, it.next().?, "b");
    try testing.expectEqualSlices(u8, it.next().?, "");
    try testing.expectEqualSlices(u8, it.next().?, "c");
    try testing.expectEqualSlices(u8, it.next().?, "d");
    try testing.expectEqualSlices(u8, it.next().?, "e");
    try testing.expect(it.next() == null);

    it = splitAny(u8, "hello", "");
    try testing.expect(eql(u8, it.next().?, "hello"));
    try testing.expect(it.next() == null);

    var it16 = splitAny(
        u16,
        std.unicode.utf8ToUtf16LeStringLiteral("a,b, c d e"),
        std.unicode.utf8ToUtf16LeStringLiteral(", "),
    );
    try testing.expectEqualSlices(u16, it16.first(), std.unicode.utf8ToUtf16LeStringLiteral("a"));
    try testing.expectEqualSlices(u16, it16.next().?, std.unicode.utf8ToUtf16LeStringLiteral("b"));
    try testing.expectEqualSlices(u16, it16.next().?, std.unicode.utf8ToUtf16LeStringLiteral(""));
    try testing.expectEqualSlices(u16, it16.next().?, std.unicode.utf8ToUtf16LeStringLiteral("c"));
    try testing.expectEqualSlices(u16, it16.next().?, std.unicode.utf8ToUtf16LeStringLiteral("d"));
    try testing.expectEqualSlices(u16, it16.next().?, std.unicode.utf8ToUtf16LeStringLiteral("e"));
    try testing.expect(it16.next() == null);
}

test "split (reset)" {
    {
        var it = splitSequence(u8, "abc def ghi", " ");
        try testing.expect(eql(u8, it.first(), "abc"));
        try testing.expect(eql(u8, it.next().?, "def"));
        try testing.expect(eql(u8, it.next().?, "ghi"));

        it.reset();

        try testing.expect(eql(u8, it.first(), "abc"));
        try testing.expect(eql(u8, it.next().?, "def"));
        try testing.expect(eql(u8, it.next().?, "ghi"));
        try testing.expect(it.next() == null);
    }
    {
        var it = splitAny(u8, "abc def,ghi", " ,");
        try testing.expect(eql(u8, it.first(), "abc"));
        try testing.expect(eql(u8, it.next().?, "def"));
        try testing.expect(eql(u8, it.next().?, "ghi"));

        it.reset();

        try testing.expect(eql(u8, it.first(), "abc"));
        try testing.expect(eql(u8, it.next().?, "def"));
        try testing.expect(eql(u8, it.next().?, "ghi"));
        try testing.expect(it.next() == null);
    }
    {
        var it = splitScalar(u8, "abc def ghi", ' ');
        try testing.expect(eql(u8, it.first(), "abc"));
        try testing.expect(eql(u8, it.next().?, "def"));
        try testing.expect(eql(u8, it.next().?, "ghi"));

        it.reset();

        try testing.expect(eql(u8, it.first(), "abc"));
        try testing.expect(eql(u8, it.next().?, "def"));
        try testing.expect(eql(u8, it.next().?, "ghi"));
        try testing.expect(it.next() == null);
    }
}

/// Returns an iterator that iterates backwards over the slices of `buffer` that
/// are separated by the sequence in `delimiter`.
///
/// `splitBackwardsSequence(u8, "abc||def||||ghi", "||")` will return slices
/// for "ghi", "", "def", "abc", null, in that order.
///
/// If `delimiter` does not exist in buffer,
/// the iterator will return `buffer`, null, in that order.
/// The delimiter length must not be zero.
///
/// See also: `splitBackwardsAny`, `splitBackwardsScalar`,
///           `splitSequence`, `splitAny`,`splitScalar`,
///           `tokenizeAny`, `tokenizeSequence`, and `tokenizeScalar`.
pub fn splitBackwardsSequence(comptime T: type, buffer: []const T, delimiter: []const T) SplitBackwardsIterator(T, .sequence) {
    assert(delimiter.len != 0);
    return .{
        .index = buffer.len,
        .buffer = buffer,
        .delimiter = delimiter,
    };
}

/// Returns an iterator that iterates backwards over the slices of `buffer` that
/// are separated by any item in `delimiters`.
///
/// `splitBackwardsAny(u8, "abc,def||ghi", "|,")` will return slices
/// for "ghi", "", "def", "abc", null, in that order.
///
/// If none of `delimiters` exist in buffer,
/// the iterator will return `buffer`, null, in that order.
///
/// See also: `splitBackwardsSequence`, `splitBackwardsScalar`,
///           `splitSequence`, `splitAny`,`splitScalar`,
///           `tokenizeAny`, `tokenizeSequence`, and `tokenizeScalar`.
pub fn splitBackwardsAny(comptime T: type, buffer: []const T, delimiters: []const T) SplitBackwardsIterator(T, .any) {
    return .{
        .index = buffer.len,
        .buffer = buffer,
        .delimiter = delimiters,
    };
}

/// Returns an iterator that iterates backwards over the slices of `buffer` that
/// are separated by `delimiter`.
///
/// `splitBackwardsScalar(u8, "abc|def||ghi", '|')` will return slices
/// for "ghi", "", "def", "abc", null, in that order.
///
/// If `delimiter` does not exist in buffer,
/// the iterator will return `buffer`, null, in that order.
///
/// See also: `splitBackwardsSequence`, `splitBackwardsAny`,
///           `splitSequence`, `splitAny`,`splitScalar`,
///           `tokenizeAny`, `tokenizeSequence`, and `tokenizeScalar`.
pub fn splitBackwardsScalar(comptime T: type, buffer: []const T, delimiter: T) SplitBackwardsIterator(T, .scalar) {
    return .{
        .index = buffer.len,
        .buffer = buffer,
        .delimiter = delimiter,
    };
}

test splitBackwardsScalar {
    var it = splitBackwardsScalar(u8, "abc|def||ghi", '|');
    try testing.expectEqualSlices(u8, it.rest(), "abc|def||ghi");
    try testing.expectEqualSlices(u8, it.first(), "ghi");

    try testing.expectEqualSlices(u8, it.rest(), "abc|def|");
    try testing.expectEqualSlices(u8, it.next().?, "");

    try testing.expectEqualSlices(u8, it.rest(), "abc|def");
    try testing.expectEqualSlices(u8, it.next().?, "def");

    try testing.expectEqualSlices(u8, it.rest(), "abc");
    try testing.expectEqualSlices(u8, it.next().?, "abc");

    try testing.expectEqualSlices(u8, it.rest(), "");
    try testing.expect(it.next() == null);

    it = splitBackwardsScalar(u8, "", '|');
    try testing.expectEqualSlices(u8, it.first(), "");
    try testing.expect(it.next() == null);

    it = splitBackwardsScalar(u8, "|", '|');
    try testing.expectEqualSlices(u8, it.first(), "");
    try testing.expectEqualSlices(u8, it.next().?, "");
    try testing.expect(it.next() == null);

    it = splitBackwardsScalar(u8, "hello", ' ');
    try testing.expectEqualSlices(u8, it.first(), "hello");
    try testing.expect(it.next() == null);

    var it16 = splitBackwardsScalar(
        u16,
        std.unicode.utf8ToUtf16LeStringLiteral("hello"),
        ' ',
    );
    try testing.expectEqualSlices(u16, it16.first(), std.unicode.utf8ToUtf16LeStringLiteral("hello"));
    try testing.expect(it16.next() == null);
}

test splitBackwardsSequence {
    var it = splitBackwardsSequence(u8, "a, b ,, c, d, e", ", ");
    try testing.expectEqualSlices(u8, it.rest(), "a, b ,, c, d, e");
    try testing.expectEqualSlices(u8, it.first(), "e");

    try testing.expectEqualSlices(u8, it.rest(), "a, b ,, c, d");
    try testing.expectEqualSlices(u8, it.next().?, "d");

    try testing.expectEqualSlices(u8, it.rest(), "a, b ,, c");
    try testing.expectEqualSlices(u8, it.next().?, "c");

    try testing.expectEqualSlices(u8, it.rest(), "a, b ,");
    try testing.expectEqualSlices(u8, it.next().?, "b ,");

    try testing.expectEqualSlices(u8, it.rest(), "a");
    try testing.expectEqualSlices(u8, it.next().?, "a");

    try testing.expectEqualSlices(u8, it.rest(), "");
    try testing.expect(it.next() == null);

    var it16 = splitBackwardsSequence(
        u16,
        std.unicode.utf8ToUtf16LeStringLiteral("a, b ,, c, d, e"),
        std.unicode.utf8ToUtf16LeStringLiteral(", "),
    );
    try testing.expectEqualSlices(u16, it16.first(), std.unicode.utf8ToUtf16LeStringLiteral("e"));
    try testing.expectEqualSlices(u16, it16.next().?, std.unicode.utf8ToUtf16LeStringLiteral("d"));
    try testing.expectEqualSlices(u16, it16.next().?, std.unicode.utf8ToUtf16LeStringLiteral("c"));
    try testing.expectEqualSlices(u16, it16.next().?, std.unicode.utf8ToUtf16LeStringLiteral("b ,"));
    try testing.expectEqualSlices(u16, it16.next().?, std.unicode.utf8ToUtf16LeStringLiteral("a"));
    try testing.expect(it16.next() == null);
}

test splitBackwardsAny {
    var it = splitBackwardsAny(u8, "a,b, c d e", ", ");
    try testing.expectEqualSlices(u8, it.rest(), "a,b, c d e");
    try testing.expectEqualSlices(u8, it.first(), "e");

    try testing.expectEqualSlices(u8, it.rest(), "a,b, c d");
    try testing.expectEqualSlices(u8, it.next().?, "d");

    try testing.expectEqualSlices(u8, it.rest(), "a,b, c");
    try testing.expectEqualSlices(u8, it.next().?, "c");

    try testing.expectEqualSlices(u8, it.rest(), "a,b,");
    try testing.expectEqualSlices(u8, it.next().?, "");

    try testing.expectEqualSlices(u8, it.rest(), "a,b");
    try testing.expectEqualSlices(u8, it.next().?, "b");

    try testing.expectEqualSlices(u8, it.rest(), "a");
    try testing.expectEqualSlices(u8, it.next().?, "a");

    try testing.expectEqualSlices(u8, it.rest(), "");
    try testing.expect(it.next() == null);

    var it16 = splitBackwardsAny(
        u16,
        std.unicode.utf8ToUtf16LeStringLiteral("a,b, c d e"),
        std.unicode.utf8ToUtf16LeStringLiteral(", "),
    );
    try testing.expectEqualSlices(u16, it16.first(), std.unicode.utf8ToUtf16LeStringLiteral("e"));
    try testing.expectEqualSlices(u16, it16.next().?, std.unicode.utf8ToUtf16LeStringLiteral("d"));
    try testing.expectEqualSlices(u16, it16.next().?, std.unicode.utf8ToUtf16LeStringLiteral("c"));
    try testing.expectEqualSlices(u16, it16.next().?, std.unicode.utf8ToUtf16LeStringLiteral(""));
    try testing.expectEqualSlices(u16, it16.next().?, std.unicode.utf8ToUtf16LeStringLiteral("b"));
    try testing.expectEqualSlices(u16, it16.next().?, std.unicode.utf8ToUtf16LeStringLiteral("a"));
    try testing.expect(it16.next() == null);
}

test "splitBackwards (reset)" {
    {
        var it = splitBackwardsSequence(u8, "abc def ghi", " ");
        try testing.expect(eql(u8, it.first(), "ghi"));
        try testing.expect(eql(u8, it.next().?, "def"));
        try testing.expect(eql(u8, it.next().?, "abc"));

        it.reset();

        try testing.expect(eql(u8, it.first(), "ghi"));
        try testing.expect(eql(u8, it.next().?, "def"));
        try testing.expect(eql(u8, it.next().?, "abc"));
        try testing.expect(it.next() == null);
    }
    {
        var it = splitBackwardsAny(u8, "abc def,ghi", " ,");
        try testing.expect(eql(u8, it.first(), "ghi"));
        try testing.expect(eql(u8, it.next().?, "def"));
        try testing.expect(eql(u8, it.next().?, "abc"));

        it.reset();

        try testing.expect(eql(u8, it.first(), "ghi"));
        try testing.expect(eql(u8, it.next().?, "def"));
        try testing.expect(eql(u8, it.next().?, "abc"));
        try testing.expect(it.next() == null);
    }
    {
        var it = splitBackwardsScalar(u8, "abc def ghi", ' ');
        try testing.expect(eql(u8, it.first(), "ghi"));
        try testing.expect(eql(u8, it.next().?, "def"));
        try testing.expect(eql(u8, it.next().?, "abc"));

        it.reset();

        try testing.expect(eql(u8, it.first(), "ghi"));
        try testing.expect(eql(u8, it.next().?, "def"));
        try testing.expect(eql(u8, it.next().?, "abc"));
        try testing.expect(it.next() == null);
    }
}

/// Returns an iterator with a sliding window of slices for `buffer`.
/// The sliding window has length `size` and on every iteration moves
/// forward by `advance`.
///
/// Extract data for moving average with:
/// `window(u8, "abcdefg", 3, 1)` will return slices
/// "abc", "bcd", "cde", "def", "efg", null, in that order.
///
/// Chunk or split every N items with:
/// `window(u8, "abcdefg", 3, 3)` will return slices
/// "abc", "def", "g", null, in that order.
///
/// Pick every even index with:
/// `window(u8, "abcdefg", 1, 2)` will return slices
/// "a", "c", "e", "g" null, in that order.
///
/// The `size` and `advance` must be not be zero.
pub fn window(comptime T: type, buffer: []const T, size: usize, advance: usize) WindowIterator(T) {
    assert(size != 0);
    assert(advance != 0);
    return .{
        .index = 0,
        .buffer = buffer,
        .size = size,
        .advance = advance,
    };
}

test window {
    {
        // moving average size 3
        var it = window(u8, "abcdefg", 3, 1);
        try testing.expectEqualSlices(u8, it.next().?, "abc");
        try testing.expectEqualSlices(u8, it.next().?, "bcd");
        try testing.expectEqualSlices(u8, it.next().?, "cde");
        try testing.expectEqualSlices(u8, it.next().?, "def");
        try testing.expectEqualSlices(u8, it.next().?, "efg");
        try testing.expectEqual(it.next(), null);

        // multibyte
        var it16 = window(u16, std.unicode.utf8ToUtf16LeStringLiteral("abcdefg"), 3, 1);
        try testing.expectEqualSlices(u16, it16.next().?, std.unicode.utf8ToUtf16LeStringLiteral("abc"));
        try testing.expectEqualSlices(u16, it16.next().?, std.unicode.utf8ToUtf16LeStringLiteral("bcd"));
        try testing.expectEqualSlices(u16, it16.next().?, std.unicode.utf8ToUtf16LeStringLiteral("cde"));
        try testing.expectEqualSlices(u16, it16.next().?, std.unicode.utf8ToUtf16LeStringLiteral("def"));
        try testing.expectEqualSlices(u16, it16.next().?, std.unicode.utf8ToUtf16LeStringLiteral("efg"));
        try testing.expectEqual(it16.next(), null);
    }

    {
        // chunk/split every 3
        var it = window(u8, "abcdefg", 3, 3);
        try testing.expectEqualSlices(u8, it.next().?, "abc");
        try testing.expectEqualSlices(u8, it.next().?, "def");
        try testing.expectEqualSlices(u8, it.next().?, "g");
        try testing.expectEqual(it.next(), null);
    }

    {
        // pick even
        var it = window(u8, "abcdefg", 1, 2);
        try testing.expectEqualSlices(u8, it.next().?, "a");
        try testing.expectEqualSlices(u8, it.next().?, "c");
        try testing.expectEqualSlices(u8, it.next().?, "e");
        try testing.expectEqualSlices(u8, it.next().?, "g");
        try testing.expectEqual(it.next(), null);
    }

    {
        // empty
        var it = window(u8, "", 1, 1);
        try testing.expectEqualSlices(u8, it.next().?, "");
        try testing.expectEqual(it.next(), null);

        it = window(u8, "", 10, 1);
        try testing.expectEqualSlices(u8, it.next().?, "");
        try testing.expectEqual(it.next(), null);

        it = window(u8, "", 1, 10);
        try testing.expectEqualSlices(u8, it.next().?, "");
        try testing.expectEqual(it.next(), null);

        it = window(u8, "", 10, 10);
        try testing.expectEqualSlices(u8, it.next().?, "");
        try testing.expectEqual(it.next(), null);
    }

    {
        // first
        var it = window(u8, "abcdefg", 3, 3);
        try testing.expectEqualSlices(u8, it.first(), "abc");
        it.reset();
        try testing.expectEqualSlices(u8, it.next().?, "abc");
    }

    {
        // reset
        var it = window(u8, "abcdefg", 3, 3);
        try testing.expectEqualSlices(u8, it.next().?, "abc");
        try testing.expectEqualSlices(u8, it.next().?, "def");
        try testing.expectEqualSlices(u8, it.next().?, "g");
        try testing.expectEqual(it.next(), null);

        it.reset();
        try testing.expectEqualSlices(u8, it.next().?, "abc");
        try testing.expectEqualSlices(u8, it.next().?, "def");
        try testing.expectEqualSlices(u8, it.next().?, "g");
        try testing.expectEqual(it.next(), null);
    }
}

pub fn WindowIterator(comptime T: type) type {
    return struct {
        buffer: []const T,
        index: ?usize,
        size: usize,
        advance: usize,

        const Self = @This();

        /// Returns a slice of the first window.
        /// Call this only to get the first window and then use `next` to get
        /// all subsequent windows.
        /// Asserts that iteration has not begun.
        pub fn first(self: *Self) []const T {
            assert(self.index.? == 0);
            return self.next().?;
        }

        /// Returns a slice of the next window, or null if window is at end.
        pub fn next(self: *Self) ?[]const T {
            const start = self.index orelse return null;
            const next_index = start + self.advance;
            const end = if (start + self.size < self.buffer.len and next_index < self.buffer.len) blk: {
                self.index = next_index;
                break :blk start + self.size;
            } else blk: {
                self.index = null;
                break :blk self.buffer.len;
            };

            return self.buffer[start..end];
        }

        /// Resets the iterator to the initial window.
        pub fn reset(self: *Self) void {
            self.index = 0;
        }
    };
}

pub fn startsWith(comptime T: type, haystack: []const T, needle: []const T) bool {
    return if (needle.len > haystack.len) false else eql(T, haystack[0..needle.len], needle);
}

test startsWith {
    try testing.expect(startsWith(u8, "Bob", "Bo"));
    try testing.expect(!startsWith(u8, "Needle in haystack", "haystack"));
}

pub fn endsWith(comptime T: type, haystack: []const T, needle: []const T) bool {
    return if (needle.len > haystack.len) false else eql(T, haystack[haystack.len - needle.len ..], needle);
}

test endsWith {
    try testing.expect(endsWith(u8, "Needle in haystack", "haystack"));
    try testing.expect(!endsWith(u8, "Bob", "Bo"));
}

pub const DelimiterType = enum { sequence, any, scalar };

pub fn TokenIterator(comptime T: type, comptime delimiter_type: DelimiterType) type {
    return struct {
        buffer: []const T,
        delimiter: switch (delimiter_type) {
            .sequence, .any => []const T,
            .scalar => T,
        },
        index: usize,

        const Self = @This();

        /// Returns a slice of the current token, or null if tokenization is
        /// complete, and advances to the next token.
        pub fn next(self: *Self) ?[]const T {
            const result = self.peek() orelse return null;
            self.index += result.len;
            return result;
        }

        /// Returns a slice of the current token, or null if tokenization is
        /// complete. Does not advance to the next token.
        pub fn peek(self: *Self) ?[]const T {
            // move to beginning of token
            while (self.index < self.buffer.len and self.isDelimiter(self.index)) : (self.index += switch (delimiter_type) {
                .sequence => self.delimiter.len,
                .any, .scalar => 1,
            }) {}
            const start = self.index;
            if (start == self.buffer.len) {
                return null;
            }

            // move to end of token
            var end = start;
            while (end < self.buffer.len and !self.isDelimiter(end)) : (end += 1) {}

            return self.buffer[start..end];
        }

        /// Returns a slice of the remaining bytes. Does not affect iterator state.
        pub fn rest(self: Self) []const T {
            // move to beginning of token
            var index: usize = self.index;
            while (index < self.buffer.len and self.isDelimiter(index)) : (index += switch (delimiter_type) {
                .sequence => self.delimiter.len,
                .any, .scalar => 1,
            }) {}
            return self.buffer[index..];
        }

        /// Resets the iterator to the initial token.
        pub fn reset(self: *Self) void {
            self.index = 0;
        }

        fn isDelimiter(self: Self, index: usize) bool {
            switch (delimiter_type) {
                .sequence => return startsWith(T, self.buffer[index..], self.delimiter),
                .any => {
                    const item = self.buffer[index];
                    for (self.delimiter) |delimiter_item| {
                        if (item == delimiter_item) {
                            return true;
                        }
                    }
                    return false;
                },
                .scalar => return self.buffer[index] == self.delimiter,
            }
        }
    };
}

pub fn SplitIterator(comptime T: type, comptime delimiter_type: DelimiterType) type {
    return struct {
        buffer: []const T,
        index: ?usize,
        delimiter: switch (delimiter_type) {
            .sequence, .any => []const T,
            .scalar => T,
        },

        const Self = @This();

        /// Returns a slice of the first field.
        /// Call this only to get the first field and then use `next` to get all subsequent fields.
        /// Asserts that iteration has not begun.
        pub fn first(self: *Self) []const T {
            assert(self.index.? == 0);
            return self.next().?;
        }

        /// Returns a slice of the next field, or null if splitting is complete.
        pub fn next(self: *Self) ?[]const T {
            const start = self.index orelse return null;
            const end = if (switch (delimiter_type) {
                .sequence => indexOfPos(T, self.buffer, start, self.delimiter),
                .any => indexOfAnyPos(T, self.buffer, start, self.delimiter),
                .scalar => indexOfScalarPos(T, self.buffer, start, self.delimiter),
            }) |delim_start| blk: {
                self.index = delim_start + switch (delimiter_type) {
                    .sequence => self.delimiter.len,
                    .any, .scalar => 1,
                };
                break :blk delim_start;
            } else blk: {
                self.index = null;
                break :blk self.buffer.len;
            };
            return self.buffer[start..end];
        }

        /// Returns a slice of the next field, or null if splitting is complete.
        /// This method does not alter self.index.
        pub fn peek(self: *Self) ?[]const T {
            const start = self.index orelse return null;
            const end = if (switch (delimiter_type) {
                .sequence => indexOfPos(T, self.buffer, start, self.delimiter),
                .any => indexOfAnyPos(T, self.buffer, start, self.delimiter),
                .scalar => indexOfScalarPos(T, self.buffer, start, self.delimiter),
            }) |delim_start| delim_start else self.buffer.len;
            return self.buffer[start..end];
        }

        /// Returns a slice of the remaining bytes. Does not affect iterator state.
        pub fn rest(self: Self) []const T {
            const end = self.buffer.len;
            const start = self.index orelse end;
            return self.buffer[start..end];
        }

        /// Resets the iterator to the initial slice.
        pub fn reset(self: *Self) void {
            self.index = 0;
        }
    };
}

pub fn SplitBackwardsIterator(comptime T: type, comptime delimiter_type: DelimiterType) type {
    return struct {
        buffer: []const T,
        index: ?usize,
        delimiter: switch (delimiter_type) {
            .sequence, .any => []const T,
            .scalar => T,
        },

        const Self = @This();

        /// Returns a slice of the first field.
        /// Call this only to get the first field and then use `next` to get all subsequent fields.
        /// Asserts that iteration has not begun.
        pub fn first(self: *Self) []const T {
            assert(self.index.? == self.buffer.len);
            return self.next().?;
        }

        /// Returns a slice of the next field, or null if splitting is complete.
        pub fn next(self: *Self) ?[]const T {
            const end = self.index orelse return null;
            const start = if (switch (delimiter_type) {
                .sequence => lastIndexOf(T, self.buffer[0..end], self.delimiter),
                .any => lastIndexOfAny(T, self.buffer[0..end], self.delimiter),
                .scalar => lastIndexOfScalar(T, self.buffer[0..end], self.delimiter),
            }) |delim_start| blk: {
                self.index = delim_start;
                break :blk delim_start + switch (delimiter_type) {
                    .sequence => self.delimiter.len,
                    .any, .scalar => 1,
                };
            } else blk: {
                self.index = null;
                break :blk 0;
            };
            return self.buffer[start..end];
        }

        /// Returns a slice of the remaining bytes. Does not affect iterator state.
        pub fn rest(self: Self) []const T {
            const end = self.index orelse 0;
            return self.buffer[0..end];
        }

        /// Resets the iterator to the initial slice.
        pub fn reset(self: *Self) void {
            self.index = self.buffer.len;
        }
    };
}

/// Naively combines a series of slices with a separator.
/// Allocates memory for the result, which must be freed by the caller.
pub fn join(allocator: Allocator, separator: []const u8, slices: []const []const u8) Allocator.Error![]u8 {
    return joinMaybeZ(allocator, separator, slices, false);
}

/// Naively combines a series of slices with a separator and null terminator.
/// Allocates memory for the result, which must be freed by the caller.
pub fn joinZ(allocator: Allocator, separator: []const u8, slices: []const []const u8) Allocator.Error![:0]u8 {
    const out = try joinMaybeZ(allocator, separator, slices, true);
    return out[0 .. out.len - 1 :0];
}

fn joinMaybeZ(allocator: Allocator, separator: []const u8, slices: []const []const u8, zero: bool) Allocator.Error![]u8 {
    if (slices.len == 0) return if (zero) try allocator.dupe(u8, &[1]u8{0}) else &[0]u8{};

    const total_len = blk: {
        var sum: usize = separator.len * (slices.len - 1);
        for (slices) |slice| sum += slice.len;
        if (zero) sum += 1;
        break :blk sum;
    };

    const buf = try allocator.alloc(u8, total_len);
    errdefer allocator.free(buf);

    @memcpy(buf[0..slices[0].len], slices[0]);
    var buf_index: usize = slices[0].len;
    for (slices[1..]) |slice| {
        @memcpy(buf[buf_index .. buf_index + separator.len], separator);
        buf_index += separator.len;
        @memcpy(buf[buf_index .. buf_index + slice.len], slice);
        buf_index += slice.len;
    }

    if (zero) buf[buf.len - 1] = 0;

    // No need for shrink since buf is exactly the correct size.
    return buf;
}

test join {
    {
        const str = try join(testing.allocator, ",", &[_][]const u8{});
        defer testing.allocator.free(str);
        try testing.expect(eql(u8, str, ""));
    }
    {
        const str = try join(testing.allocator, ",", &[_][]const u8{ "a", "b", "c" });
        defer testing.allocator.free(str);
        try testing.expect(eql(u8, str, "a,b,c"));
    }
    {
        const str = try join(testing.allocator, ",", &[_][]const u8{"a"});
        defer testing.allocator.free(str);
        try testing.expect(eql(u8, str, "a"));
    }
    {
        const str = try join(testing.allocator, ",", &[_][]const u8{ "a", "", "b", "", "c" });
        defer testing.allocator.free(str);
        try testing.expect(eql(u8, str, "a,,b,,c"));
    }
}

test joinZ {
    {
        const str = try joinZ(testing.allocator, ",", &[_][]const u8{});
        defer testing.allocator.free(str);
        try testing.expect(eql(u8, str, ""));
        try testing.expectEqual(str[str.len], 0);
    }
    {
        const str = try joinZ(testing.allocator, ",", &[_][]const u8{ "a", "b", "c" });
        defer testing.allocator.free(str);
        try testing.expect(eql(u8, str, "a,b,c"));
        try testing.expectEqual(str[str.len], 0);
    }
    {
        const str = try joinZ(testing.allocator, ",", &[_][]const u8{"a"});
        defer testing.allocator.free(str);
        try testing.expect(eql(u8, str, "a"));
        try testing.expectEqual(str[str.len], 0);
    }
    {
        const str = try joinZ(testing.allocator, ",", &[_][]const u8{ "a", "", "b", "", "c" });
        defer testing.allocator.free(str);
        try testing.expect(eql(u8, str, "a,,b,,c"));
        try testing.expectEqual(str[str.len], 0);
    }
}

/// Copies each T from slices into a new slice that exactly holds all the elements.
pub fn concat(allocator: Allocator, comptime T: type, slices: []const []const T) Allocator.Error![]T {
    return concatMaybeSentinel(allocator, T, slices, null);
}

/// Copies each T from slices into a new slice that exactly holds all the elements.
pub fn concatWithSentinel(allocator: Allocator, comptime T: type, slices: []const []const T, comptime s: T) Allocator.Error![:s]T {
    const ret = try concatMaybeSentinel(allocator, T, slices, s);
    return ret[0 .. ret.len - 1 :s];
}

/// Copies each T from slices into a new slice that exactly holds all the elements as well as the sentinel.
pub fn concatMaybeSentinel(allocator: Allocator, comptime T: type, slices: []const []const T, comptime s: ?T) Allocator.Error![]T {
    if (slices.len == 0) return if (s) |sentinel| try allocator.dupe(T, &[1]T{sentinel}) else &[0]T{};

    const total_len = blk: {
        var sum: usize = 0;
        for (slices) |slice| {
            sum += slice.len;
        }

        if (s) |_| {
            sum += 1;
        }

        break :blk sum;
    };

    const buf = try allocator.alloc(T, total_len);
    errdefer allocator.free(buf);

    var buf_index: usize = 0;
    for (slices) |slice| {
        @memcpy(buf[buf_index .. buf_index + slice.len], slice);
        buf_index += slice.len;
    }

    if (s) |sentinel| {
        buf[buf.len - 1] = sentinel;
    }

    // No need for shrink since buf is exactly the correct size.
    return buf;
}

test concat {
    {
        const str = try concat(testing.allocator, u8, &[_][]const u8{ "abc", "def", "ghi" });
        defer testing.allocator.free(str);
        try testing.expect(eql(u8, str, "abcdefghi"));
    }
    {
        const str = try concat(testing.allocator, u32, &[_][]const u32{
            &[_]u32{ 0, 1 },
            &[_]u32{ 2, 3, 4 },
            &[_]u32{},
            &[_]u32{5},
        });
        defer testing.allocator.free(str);
        try testing.expect(eql(u32, str, &[_]u32{ 0, 1, 2, 3, 4, 5 }));
    }
    {
        const str = try concatWithSentinel(testing.allocator, u8, &[_][]const u8{ "abc", "def", "ghi" }, 0);
        defer testing.allocator.free(str);
        try testing.expectEqualSentinel(u8, 0, str, "abcdefghi");
    }
    {
        const slice = try concatWithSentinel(testing.allocator, u8, &[_][]const u8{}, 0);
        defer testing.allocator.free(slice);
        try testing.expectEqualSentinel(u8, 0, slice, &[_:0]u8{});
    }
    {
        const slice = try concatWithSentinel(testing.allocator, u32, &[_][]const u32{
            &[_]u32{ 0, 1 },
            &[_]u32{ 2, 3, 4 },
            &[_]u32{},
            &[_]u32{5},
        }, 2);
        defer testing.allocator.free(slice);
        try testing.expectEqualSentinel(u32, 2, slice, &[_:2]u32{ 0, 1, 2, 3, 4, 5 });
    }
}

fn moreReadIntTests() !void {
    {
        const bytes = [_]u8{
            0x12,
            0x34,
            0x56,
            0x78,
        };
        try testing.expect(readInt(u32, &bytes, .big) == 0x12345678);
        try testing.expect(readInt(u32, &bytes, .big) == 0x12345678);
        try testing.expect(readInt(i32, &bytes, .big) == 0x12345678);
        try testing.expect(readInt(u32, &bytes, .little) == 0x78563412);
        try testing.expect(readInt(u32, &bytes, .little) == 0x78563412);
        try testing.expect(readInt(i32, &bytes, .little) == 0x78563412);
    }
    {
        const buf = [_]u8{
            0x00,
            0x00,
            0x12,
            0x34,
        };
        const answer = readInt(u32, &buf, .big);
        try testing.expect(answer == 0x00001234);
    }
    {
        const buf = [_]u8{
            0x12,
            0x34,
            0x00,
            0x00,
        };
        const answer = readInt(u32, &buf, .little);
        try testing.expect(answer == 0x00003412);
    }
    {
        const bytes = [_]u8{
            0xff,
            0xfe,
        };
        try testing.expect(readInt(u16, &bytes, .big) == 0xfffe);
        try testing.expect(readInt(i16, &bytes, .big) == -0x0002);
        try testing.expect(readInt(u16, &bytes, .little) == 0xfeff);
        try testing.expect(readInt(i16, &bytes, .little) == -0x0101);
    }
}

/// Returns the smallest number in a slice. O(n).
/// `slice` must not be empty.
pub fn min(comptime T: type, slice: []const T) T {
    assert(slice.len > 0);
    var best = slice[0];
    for (slice[1..]) |item| {
        best = @min(best, item);
    }
    return best;
}

test min {
    try testing.expectEqual(min(u8, "abcdefg"), 'a');
    try testing.expectEqual(min(u8, "bcdefga"), 'a');
    try testing.expectEqual(min(u8, "a"), 'a');
}

/// Returns the largest number in a slice. O(n).
/// `slice` must not be empty.
pub fn max(comptime T: type, slice: []const T) T {
    assert(slice.len > 0);
    var best = slice[0];
    for (slice[1..]) |item| {
        best = @max(best, item);
    }
    return best;
}

test max {
    try testing.expectEqual(max(u8, "abcdefg"), 'g');
    try testing.expectEqual(max(u8, "gabcdef"), 'g');
    try testing.expectEqual(max(u8, "g"), 'g');
}

/// Finds the smallest and largest number in a slice. O(n).
/// Returns an anonymous struct with the fields `min` and `max`.
/// `slice` must not be empty.
pub fn minMax(comptime T: type, slice: []const T) struct { T, T } {
    assert(slice.len > 0);
    var running_minimum = slice[0];
    var running_maximum = slice[0];
    for (slice[1..]) |item| {
        running_minimum = @min(running_minimum, item);
        running_maximum = @max(running_maximum, item);
    }
    return .{ running_minimum, running_maximum };
}

test minMax {
    {
        const actual_min, const actual_max = minMax(u8, "abcdefg");
        try testing.expectEqual(@as(u8, 'a'), actual_min);
        try testing.expectEqual(@as(u8, 'g'), actual_max);
    }
    {
        const actual_min, const actual_max = minMax(u8, "bcdefga");
        try testing.expectEqual(@as(u8, 'a'), actual_min);
        try testing.expectEqual(@as(u8, 'g'), actual_max);
    }
    {
        const actual_min, const actual_max = minMax(u8, "a");
        try testing.expectEqual(@as(u8, 'a'), actual_min);
        try testing.expectEqual(@as(u8, 'a'), actual_max);
    }
}

/// Returns the index of the smallest number in a slice. O(n).
/// `slice` must not be empty.
pub fn indexOfMin(comptime T: type, slice: []const T) usize {
    assert(slice.len > 0);
    var best = slice[0];
    var index: usize = 0;
    for (slice[1..], 0..) |item, i| {
        if (item < best) {
            best = item;
            index = i + 1;
        }
    }
    return index;
}

test indexOfMin {
    try testing.expectEqual(indexOfMin(u8, "abcdefg"), 0);
    try testing.expectEqual(indexOfMin(u8, "bcdefga"), 6);
    try testing.expectEqual(indexOfMin(u8, "a"), 0);
}

/// Returns the index of the largest number in a slice. O(n).
/// `slice` must not be empty.
pub fn indexOfMax(comptime T: type, slice: []const T) usize {
    assert(slice.len > 0);
    var best = slice[0];
    var index: usize = 0;
    for (slice[1..], 0..) |item, i| {
        if (item > best) {
            best = item;
            index = i + 1;
        }
    }
    return index;
}

test indexOfMax {
    try testing.expectEqual(indexOfMax(u8, "abcdefg"), 6);
    try testing.expectEqual(indexOfMax(u8, "gabcdef"), 0);
    try testing.expectEqual(indexOfMax(u8, "a"), 0);
}

/// Finds the indices of the smallest and largest number in a slice. O(n).
/// Returns the indices of the smallest and largest numbers in that order.
/// `slice` must not be empty.
pub fn indexOfMinMax(comptime T: type, slice: []const T) struct { usize, usize } {
    assert(slice.len > 0);
    var minVal = slice[0];
    var maxVal = slice[0];
    var minIdx: usize = 0;
    var maxIdx: usize = 0;
    for (slice[1..], 0..) |item, i| {
        if (item < minVal) {
            minVal = item;
            minIdx = i + 1;
        }
        if (item > maxVal) {
            maxVal = item;
            maxIdx = i + 1;
        }
    }
    return .{ minIdx, maxIdx };
}

test indexOfMinMax {
    try testing.expectEqual(.{ 0, 6 }, indexOfMinMax(u8, "abcdefg"));
    try testing.expectEqual(.{ 1, 0 }, indexOfMinMax(u8, "gabcdef"));
    try testing.expectEqual(.{ 0, 0 }, indexOfMinMax(u8, "a"));
}

pub fn swap(comptime T: type, a: *T, b: *T) void {
    const tmp = a.*;
    a.* = b.*;
    b.* = tmp;
}

inline fn reverseVector(comptime N: usize, comptime T: type, a: []T) [N]T {
    var res: [N]T = undefined;
    inline for (0..N) |i| {
        res[i] = a[N - i - 1];
    }
    return res;
}

/// In-place order reversal of a slice
pub fn reverse(comptime T: type, items: []T) void {
    var i: usize = 0;
    const end = items.len / 2;
    if (backend_supports_vectors and
        !@inComptime() and
        @bitSizeOf(T) > 0 and
        std.math.isPowerOfTwo(@bitSizeOf(T)))
    {
        if (std.simd.suggestVectorLength(T)) |simd_size| {
            if (simd_size <= end) {
                const simd_end = end - (simd_size - 1);
                while (i < simd_end) : (i += simd_size) {
                    const left_slice = items[i .. i + simd_size];
                    const right_slice = items[items.len - i - simd_size .. items.len - i];

                    const left_shuffled: [simd_size]T = reverseVector(simd_size, T, left_slice);
                    const right_shuffled: [simd_size]T = reverseVector(simd_size, T, right_slice);

                    @memcpy(right_slice, &left_shuffled);
                    @memcpy(left_slice, &right_shuffled);
                }
            }
        }
    }

    while (i < end) : (i += 1) {
        swap(T, &items[i], &items[items.len - i - 1]);
    }
}

test reverse {
    {
        var arr = [_]i32{ 5, 3, 1, 2, 4 };
        reverse(i32, arr[0..]);
        try testing.expectEqualSlices(i32, &arr, &.{ 4, 2, 1, 3, 5 });
    }
    {
        var arr = [_]u0{};
        reverse(u0, arr[0..]);
        try testing.expectEqualSlices(u0, &arr, &.{});
    }
    {
        var arr = [_]i64{ 19, 17, 15, 13, 11, 9, 7, 5, 3, 1, 2, 4, 6, 8, 10, 12, 14, 16, 18 };
        reverse(i64, arr[0..]);
        try testing.expectEqualSlices(i64, &arr, &.{ 18, 16, 14, 12, 10, 8, 6, 4, 2, 1, 3, 5, 7, 9, 11, 13, 15, 17, 19 });
    }
    {
        var arr = [_][]const u8{ "a", "b", "c", "d" };
        reverse([]const u8, arr[0..]);
        try testing.expectEqualSlices([]const u8, &arr, &.{ "d", "c", "b", "a" });
    }
    {
        const MyType = union(enum) {
            a: [3]u8,
            b: u24,
            c,
        };
        var arr = [_]MyType{ .{ .a = .{ 0, 0, 0 } }, .{ .b = 0 }, .c };
        reverse(MyType, arr[0..]);
        try testing.expectEqualSlices(MyType, &arr, &([_]MyType{ .c, .{ .b = 0 }, .{ .a = .{ 0, 0, 0 } } }));
    }
}
fn ReverseIterator(comptime T: type) type {
    const Pointer = blk: {
        switch (@typeInfo(T)) {
            .pointer => |ptr_info| switch (ptr_info.size) {
                .one => switch (@typeInfo(ptr_info.child)) {
                    .array => |array_info| {
                        var new_ptr_info = ptr_info;
                        new_ptr_info.size = .many;
                        new_ptr_info.child = array_info.child;
                        new_ptr_info.sentinel_ptr = array_info.sentinel_ptr;
                        break :blk @Type(.{ .pointer = new_ptr_info });
                    },
                    else => {},
                },
                .slice => {
                    var new_ptr_info = ptr_info;
                    new_ptr_info.size = .many;
                    break :blk @Type(.{ .pointer = new_ptr_info });
                },
                else => {},
            },
            else => {},
        }
        @compileError("expected slice or pointer to array, found '" ++ @typeName(T) ++ "'");
    };
    const Element = std.meta.Elem(Pointer);
    const ElementPointer = @Type(.{ .pointer = ptr: {
        var ptr = @typeInfo(Pointer).pointer;
        ptr.size = .one;
        ptr.child = Element;
        ptr.sentinel_ptr = null;
        break :ptr ptr;
    } });
    return struct {
        ptr: Pointer,
        index: usize,
        pub fn next(self: *@This()) ?Element {
            if (self.index == 0) return null;
            self.index -= 1;
            return self.ptr[self.index];
        }
        pub fn nextPtr(self: *@This()) ?ElementPointer {
            if (self.index == 0) return null;
            self.index -= 1;
            return &self.ptr[self.index];
        }
    };
}

/// Iterates over a slice in reverse.
pub fn reverseIterator(slice: anytype) ReverseIterator(@TypeOf(slice)) {
    return .{ .ptr = slice.ptr, .index = slice.len };
}

test reverseIterator {
    {
        var it = reverseIterator("abc");
        try testing.expectEqual(@as(?u8, 'c'), it.next());
        try testing.expectEqual(@as(?u8, 'b'), it.next());
        try testing.expectEqual(@as(?u8, 'a'), it.next());
        try testing.expectEqual(@as(?u8, null), it.next());
    }
    {
        var array = [2]i32{ 3, 7 };
        const slice: []const i32 = &array;
        var it = reverseIterator(slice);
        try testing.expectEqual(@as(?i32, 7), it.next());
        try testing.expectEqual(@as(?i32, 3), it.next());
        try testing.expectEqual(@as(?i32, null), it.next());

        it = reverseIterator(slice);
        try testing.expect(*const i32 == @TypeOf(it.nextPtr().?));
        try testing.expectEqual(@as(?i32, 7), it.nextPtr().?.*);
        try testing.expectEqual(@as(?i32, 3), it.nextPtr().?.*);
        try testing.expectEqual(@as(?*const i32, null), it.nextPtr());

        const mut_slice: []i32 = &array;
        var mut_it = reverseIterator(mut_slice);
        mut_it.nextPtr().?.* += 1;
        mut_it.nextPtr().?.* += 2;
        try testing.expectEqual([2]i32{ 5, 8 }, array);
    }
    {
        var array = [2]i32{ 3, 7 };
        const ptr_to_array: *const [2]i32 = &array;
        var it = reverseIterator(ptr_to_array);
        try testing.expectEqual(@as(?i32, 7), it.next());
        try testing.expectEqual(@as(?i32, 3), it.next());
        try testing.expectEqual(@as(?i32, null), it.next());

        it = reverseIterator(ptr_to_array);
        try testing.expect(*const i32 == @TypeOf(it.nextPtr().?));
        try testing.expectEqual(@as(?i32, 7), it.nextPtr().?.*);
        try testing.expectEqual(@as(?i32, 3), it.nextPtr().?.*);
        try testing.expectEqual(@as(?*const i32, null), it.nextPtr());

        const mut_ptr_to_array: *[2]i32 = &array;
        var mut_it = reverseIterator(mut_ptr_to_array);
        mut_it.nextPtr().?.* += 1;
        mut_it.nextPtr().?.* += 2;
        try testing.expectEqual([2]i32{ 5, 8 }, array);
    }
}

/// In-place rotation of the values in an array ([0 1 2 3] becomes [1 2 3 0] if we rotate by 1)
/// Assumes 0 <= amount <= items.len
pub fn rotate(comptime T: type, items: []T, amount: usize) void {
    reverse(T, items[0..amount]);
    reverse(T, items[amount..]);
    reverse(T, items);
}

test rotate {
    var arr = [_]i32{ 5, 3, 1, 2, 4 };
    rotate(i32, arr[0..], 2);

    try testing.expect(eql(i32, &arr, &[_]i32{ 1, 2, 4, 5, 3 }));
}

/// Replace needle with replacement as many times as possible, writing to an output buffer which is assumed to be of
/// appropriate size. Use replacementSize to calculate an appropriate buffer size.
/// The needle must not be empty.
/// Returns the number of replacements made.
pub fn replace(comptime T: type, input: []const T, needle: []const T, replacement: []const T, output: []T) usize {
    // Empty needle will loop until output buffer overflows.
    assert(needle.len > 0);

    var i: usize = 0;
    var slide: usize = 0;
    var replacements: usize = 0;
    while (slide < input.len) {
        if (mem.startsWith(T, input[slide..], needle)) {
            @memcpy(output[i..][0..replacement.len], replacement);
            i += replacement.len;
            slide += needle.len;
            replacements += 1;
        } else {
            output[i] = input[slide];
            i += 1;
            slide += 1;
        }
    }

    return replacements;
}

test replace {
    var output: [29]u8 = undefined;
    var replacements = replace(u8, "All your base are belong to us", "base", "Zig", output[0..]);
    var expected: []const u8 = "All your Zig are belong to us";
    try testing.expect(replacements == 1);
    try testing.expectEqualStrings(expected, output[0..expected.len]);

    replacements = replace(u8, "Favor reading code over writing code.", "code", "", output[0..]);
    expected = "Favor reading  over writing .";
    try testing.expect(replacements == 2);
    try testing.expectEqualStrings(expected, output[0..expected.len]);

    // Empty needle is not allowed but input may be empty.
    replacements = replace(u8, "", "x", "y", output[0..0]);
    expected = "";
    try testing.expect(replacements == 0);
    try testing.expectEqualStrings(expected, output[0..expected.len]);

    // Adjacent replacements.

    replacements = replace(u8, "\\n\\n", "\\n", "\n", output[0..]);
    expected = "\n\n";
    try testing.expect(replacements == 2);
    try testing.expectEqualStrings(expected, output[0..expected.len]);

    replacements = replace(u8, "abbba", "b", "cd", output[0..]);
    expected = "acdcdcda";
    try testing.expect(replacements == 3);
    try testing.expectEqualStrings(expected, output[0..expected.len]);
}

/// Replace all occurrences of `match` with `replacement`.
pub fn replaceScalar(comptime T: type, slice: []T, match: T, replacement: T) void {
    for (slice) |*e| {
        if (e.* == match)
            e.* = replacement;
    }
}

/// Collapse consecutive duplicate elements into one entry.
pub fn collapseRepeatsLen(comptime T: type, slice: []T, elem: T) usize {
    if (slice.len == 0) return 0;
    var write_idx: usize = 1;
    var read_idx: usize = 1;
    while (read_idx < slice.len) : (read_idx += 1) {
        if (slice[read_idx - 1] != elem or slice[read_idx] != elem) {
            slice[write_idx] = slice[read_idx];
            write_idx += 1;
        }
    }
    return write_idx;
}

/// Collapse consecutive duplicate elements into one entry.
pub fn collapseRepeats(comptime T: type, slice: []T, elem: T) []T {
    return slice[0..collapseRepeatsLen(T, slice, elem)];
}

fn testCollapseRepeats(str: []const u8, elem: u8, expected: []const u8) !void {
    const mutable = try std.testing.allocator.dupe(u8, str);
    defer std.testing.allocator.free(mutable);
    try testing.expect(std.mem.eql(u8, collapseRepeats(u8, mutable, elem), expected));
}
test collapseRepeats {
    try testCollapseRepeats("", '/', "");
    try testCollapseRepeats("a", '/', "a");
    try testCollapseRepeats("/", '/', "/");
    try testCollapseRepeats("//", '/', "/");
    try testCollapseRepeats("/a", '/', "/a");
    try testCollapseRepeats("//a", '/', "/a");
    try testCollapseRepeats("a/", '/', "a/");
    try testCollapseRepeats("a//", '/', "a/");
    try testCollapseRepeats("a/a", '/', "a/a");
    try testCollapseRepeats("a//a", '/', "a/a");
    try testCollapseRepeats("//a///a////", '/', "/a/a/");
}

/// Calculate the size needed in an output buffer to perform a replacement.
/// The needle must not be empty.
pub fn replacementSize(comptime T: type, input: []const T, needle: []const T, replacement: []const T) usize {
    // Empty needle will loop forever.
    assert(needle.len > 0);

    var i: usize = 0;
    var size: usize = input.len;
    while (i < input.len) {
        if (mem.startsWith(T, input[i..], needle)) {
            size = size - needle.len + replacement.len;
            i += needle.len;
        } else {
            i += 1;
        }
    }

    return size;
}

test replacementSize {
    try testing.expect(replacementSize(u8, "All your base are belong to us", "base", "Zig") == 29);
    try testing.expect(replacementSize(u8, "Favor reading code over writing code.", "code", "") == 29);
    try testing.expect(replacementSize(u8, "Only one obvious way to do things.", "things.", "things in Zig.") == 41);

    // Empty needle is not allowed but input may be empty.
    try testing.expect(replacementSize(u8, "", "x", "y") == 0);

    // Adjacent replacements.
    try testing.expect(replacementSize(u8, "\\n\\n", "\\n", "\n") == 2);
    try testing.expect(replacementSize(u8, "abbba", "b", "cd") == 8);
}

/// Perform a replacement on an allocated buffer of pre-determined size. Caller must free returned memory.
pub fn replaceOwned(comptime T: type, allocator: Allocator, input: []const T, needle: []const T, replacement: []const T) Allocator.Error![]T {
    const output = try allocator.alloc(T, replacementSize(T, input, needle, replacement));
    _ = replace(T, input, needle, replacement, output);
    return output;
}

test replaceOwned {
    const gpa = std.testing.allocator;

    const base_replace = replaceOwned(u8, gpa, "All your base are belong to us", "base", "Zig") catch @panic("out of memory");
    defer gpa.free(base_replace);
    try testing.expect(eql(u8, base_replace, "All your Zig are belong to us"));

    const zen_replace = replaceOwned(u8, gpa, "Favor reading code over writing code.", " code", "") catch @panic("out of memory");
    defer gpa.free(zen_replace);
    try testing.expect(eql(u8, zen_replace, "Favor reading over writing."));
}

/// Converts a little-endian integer to host endianness.
pub fn littleToNative(comptime T: type, x: T) T {
    return switch (native_endian) {
        .little => x,
        .big => @byteSwap(x),
    };
}

/// Converts a big-endian integer to host endianness.
pub fn bigToNative(comptime T: type, x: T) T {
    return switch (native_endian) {
        .little => @byteSwap(x),
        .big => x,
    };
}

/// Converts an integer from specified endianness to host endianness.
pub fn toNative(comptime T: type, x: T, endianness_of_x: Endian) T {
    return switch (endianness_of_x) {
        .little => littleToNative(T, x),
        .big => bigToNative(T, x),
    };
}

/// Converts an integer which has host endianness to the desired endianness.
pub fn nativeTo(comptime T: type, x: T, desired_endianness: Endian) T {
    return switch (desired_endianness) {
        .little => nativeToLittle(T, x),
        .big => nativeToBig(T, x),
    };
}

/// Converts an integer which has host endianness to little endian.
pub fn nativeToLittle(comptime T: type, x: T) T {
    return switch (native_endian) {
        .little => x,
        .big => @byteSwap(x),
    };
}

/// Converts an integer which has host endianness to big endian.
pub fn nativeToBig(comptime T: type, x: T) T {
    return switch (native_endian) {
        .little => @byteSwap(x),
        .big => x,
    };
}

/// Returns the number of elements that, if added to the given pointer, align it
/// to a multiple of the given quantity, or `null` if one of the following
/// conditions is met:
/// - The aligned pointer would not fit the address space,
/// - The delta required to align the pointer is not a multiple of the pointee's
///   type.
pub fn alignPointerOffset(ptr: anytype, align_to: usize) ?usize {
    assert(isValidAlign(align_to));

    const T = @TypeOf(ptr);
    const info = @typeInfo(T);
    if (info != .pointer or info.pointer.size != .many)
        @compileError("expected many item pointer, got " ++ @typeName(T));

    // Do nothing if the pointer is already well-aligned.
    if (align_to <= info.pointer.alignment)
        return 0;

    // Calculate the aligned base address with an eye out for overflow.
    const addr = @intFromPtr(ptr);
    var ov = @addWithOverflow(addr, align_to - 1);
    if (ov[1] != 0) return null;
    ov[0] &= ~@as(usize, align_to - 1);

    // The delta is expressed in terms of bytes, turn it into a number of child
    // type elements.
    const delta = ov[0] - addr;
    const pointee_size = @sizeOf(info.pointer.child);
    if (delta % pointee_size != 0) return null;
    return delta / pointee_size;
}

/// Aligns a given pointer value to a specified alignment factor.
/// Returns an aligned pointer or null if one of the following conditions is
/// met:
/// - The aligned pointer would not fit the address space,
/// - The delta required to align the pointer is not a multiple of the pointee's
///   type.
pub fn alignPointer(ptr: anytype, align_to: usize) ?@TypeOf(ptr) {
    const adjust_off = alignPointerOffset(ptr, align_to) orelse return null;
    // Avoid the use of ptrFromInt to avoid losing the pointer provenance info.
    return @alignCast(ptr + adjust_off);
}

test alignPointer {
    const S = struct {
        fn checkAlign(comptime T: type, base: usize, align_to: usize, expected: usize) !void {
            const ptr: T = @ptrFromInt(base);
            const aligned = alignPointer(ptr, align_to);
            try testing.expectEqual(expected, @intFromPtr(aligned));
        }
    };

    try S.checkAlign([*]u8, 0x123, 0x200, 0x200);
    try S.checkAlign([*]align(4) u8, 0x10, 2, 0x10);
    try S.checkAlign([*]u32, 0x10, 2, 0x10);
    try S.checkAlign([*]u32, 0x4, 16, 0x10);
    // Misaligned.
    try S.checkAlign([*]align(1) u32, 0x3, 2, 0);
    // Overflow.
    try S.checkAlign([*]u32, math.maxInt(usize) - 3, 8, 0);
}

fn CopyPtrAttrs(
    comptime source: type,
    comptime size: std.builtin.Type.Pointer.Size,
    comptime child: type,
) type {
    const info = @typeInfo(source).pointer;
    return @Type(.{
        .pointer = .{
            .size = size,
            .is_const = info.is_const,
            .is_volatile = info.is_volatile,
            .is_allowzero = info.is_allowzero,
            .alignment = info.alignment,
            .address_space = info.address_space,
            .child = child,
            .sentinel_ptr = null,
        },
    });
}

fn AsBytesReturnType(comptime P: type) type {
    const pointer = @typeInfo(P).pointer;
    assert(pointer.size == .one);
    const size = @sizeOf(pointer.child);
    return CopyPtrAttrs(P, .one, [size]u8);
}

/// Given a pointer to a single item, returns a slice of the underlying bytes, preserving pointer attributes.
pub fn asBytes(ptr: anytype) AsBytesReturnType(@TypeOf(ptr)) {
    return @ptrCast(@alignCast(ptr));
}

test asBytes {
    const deadbeef = @as(u32, 0xDEADBEEF);
    const deadbeef_bytes = switch (native_endian) {
        .big => "\xDE\xAD\xBE\xEF",
        .little => "\xEF\xBE\xAD\xDE",
    };

    try testing.expect(eql(u8, asBytes(&deadbeef), deadbeef_bytes));

    var codeface = @as(u32, 0xC0DEFACE);
    for (asBytes(&codeface)) |*b|
        b.* = 0;
    try testing.expect(codeface == 0);

    const S = packed struct {
        a: u8,
        b: u8,
        c: u8,
        d: u8,
    };

    const inst = S{
        .a = 0xBE,
        .b = 0xEF,
        .c = 0xDE,
        .d = 0xA1,
    };
    switch (native_endian) {
        .little => {
            try testing.expect(eql(u8, asBytes(&inst), "\xBE\xEF\xDE\xA1"));
        },
        .big => {
            try testing.expect(eql(u8, asBytes(&inst), "\xA1\xDE\xEF\xBE"));
        },
    }

    const ZST = struct {};
    const zero = ZST{};
    try testing.expect(eql(u8, asBytes(&zero), ""));
}

test "asBytes preserves pointer attributes" {
    const inArr: u32 align(16) = 0xDEADBEEF;
    const inPtr = @as(*align(16) const volatile u32, @ptrCast(&inArr));
    const outSlice = asBytes(inPtr);

    const in = @typeInfo(@TypeOf(inPtr)).pointer;
    const out = @typeInfo(@TypeOf(outSlice)).pointer;

    try testing.expectEqual(in.is_const, out.is_const);
    try testing.expectEqual(in.is_volatile, out.is_volatile);
    try testing.expectEqual(in.is_allowzero, out.is_allowzero);
    try testing.expectEqual(in.alignment, out.alignment);
}

/// Given any value, returns a copy of its bytes in an array.
pub fn toBytes(value: anytype) [@sizeOf(@TypeOf(value))]u8 {
    return asBytes(&value).*;
}

test toBytes {
    var my_bytes = toBytes(@as(u32, 0x12345678));
    switch (native_endian) {
        .big => try testing.expect(eql(u8, &my_bytes, "\x12\x34\x56\x78")),
        .little => try testing.expect(eql(u8, &my_bytes, "\x78\x56\x34\x12")),
    }

    my_bytes[0] = '\x99';
    switch (native_endian) {
        .big => try testing.expect(eql(u8, &my_bytes, "\x99\x34\x56\x78")),
        .little => try testing.expect(eql(u8, &my_bytes, "\x99\x56\x34\x12")),
    }
}

fn BytesAsValueReturnType(comptime T: type, comptime B: type) type {
    return CopyPtrAttrs(B, .one, T);
}

/// Given a pointer to an array of bytes, returns a pointer to a value of the specified type
/// backed by those bytes, preserving pointer attributes.
pub fn bytesAsValue(comptime T: type, bytes: anytype) BytesAsValueReturnType(T, @TypeOf(bytes)) {
    return @ptrCast(bytes);
}

test bytesAsValue {
    const deadbeef = @as(u32, 0xDEADBEEF);
    const deadbeef_bytes = switch (native_endian) {
        .big => "\xDE\xAD\xBE\xEF",
        .little => "\xEF\xBE\xAD\xDE",
    };

    try testing.expect(deadbeef == bytesAsValue(u32, deadbeef_bytes).*);

    var codeface_bytes: [4]u8 = switch (native_endian) {
        .big => "\xC0\xDE\xFA\xCE",
        .little => "\xCE\xFA\xDE\xC0",
    }.*;
    const codeface = bytesAsValue(u32, &codeface_bytes);
    try testing.expect(codeface.* == 0xC0DEFACE);
    codeface.* = 0;
    for (codeface_bytes) |b|
        try testing.expect(b == 0);

    const S = packed struct {
        a: u8,
        b: u8,
        c: u8,
        d: u8,
    };

    const inst = S{
        .a = 0xBE,
        .b = 0xEF,
        .c = 0xDE,
        .d = 0xA1,
    };
    const inst_bytes = switch (native_endian) {
        .little => "\xBE\xEF\xDE\xA1",
        .big => "\xA1\xDE\xEF\xBE",
    };
    const inst2 = bytesAsValue(S, inst_bytes);
    try testing.expect(std.meta.eql(inst, inst2.*));
}

test "bytesAsValue preserves pointer attributes" {
    const inArr align(16) = [4]u8{ 0xDE, 0xAD, 0xBE, 0xEF };
    const inSlice = @as(*align(16) const volatile [4]u8, @ptrCast(&inArr))[0..];
    const outPtr = bytesAsValue(u32, inSlice);

    const in = @typeInfo(@TypeOf(inSlice)).pointer;
    const out = @typeInfo(@TypeOf(outPtr)).pointer;

    try testing.expectEqual(in.is_const, out.is_const);
    try testing.expectEqual(in.is_volatile, out.is_volatile);
    try testing.expectEqual(in.is_allowzero, out.is_allowzero);
    try testing.expectEqual(in.alignment, out.alignment);
}

/// Given a pointer to an array of bytes, returns a value of the specified type backed by a
/// copy of those bytes.
pub fn bytesToValue(comptime T: type, bytes: anytype) T {
    return bytesAsValue(T, bytes).*;
}
test bytesToValue {
    const deadbeef_bytes = switch (native_endian) {
        .big => "\xDE\xAD\xBE\xEF",
        .little => "\xEF\xBE\xAD\xDE",
    };

    const deadbeef = bytesToValue(u32, deadbeef_bytes);
    try testing.expect(deadbeef == @as(u32, 0xDEADBEEF));
}

fn BytesAsSliceReturnType(comptime T: type, comptime bytesType: type) type {
    return CopyPtrAttrs(bytesType, .slice, T);
}

/// Given a slice of bytes, returns a slice of the specified type
/// backed by those bytes, preserving pointer attributes.
/// If `T` is zero-bytes sized, the returned slice has a len of zero.
pub fn bytesAsSlice(comptime T: type, bytes: anytype) BytesAsSliceReturnType(T, @TypeOf(bytes)) {
    // let's not give an undefined pointer to @ptrCast
    // it may be equal to zero and fail a null check
    if (bytes.len == 0 or @sizeOf(T) == 0) {
        return &[0]T{};
    }

    const cast_target = CopyPtrAttrs(@TypeOf(bytes), .many, T);

    return @as(cast_target, @ptrCast(bytes))[0..@divExact(bytes.len, @sizeOf(T))];
}

test bytesAsSlice {
    {
        const bytes = [_]u8{ 0xDE, 0xAD, 0xBE, 0xEF };
        const slice = bytesAsSlice(u16, bytes[0..]);
        try testing.expect(slice.len == 2);
        try testing.expect(bigToNative(u16, slice[0]) == 0xDEAD);
        try testing.expect(bigToNative(u16, slice[1]) == 0xBEEF);
    }
    {
        const bytes = [_]u8{ 0xDE, 0xAD, 0xBE, 0xEF };
        var runtime_zero: usize = 0;
        _ = &runtime_zero;
        const slice = bytesAsSlice(u16, bytes[runtime_zero..]);
        try testing.expect(slice.len == 2);
        try testing.expect(bigToNative(u16, slice[0]) == 0xDEAD);
        try testing.expect(bigToNative(u16, slice[1]) == 0xBEEF);
    }
}

test "bytesAsSlice keeps pointer alignment" {
    {
        var bytes = [_]u8{ 0x01, 0x02, 0x03, 0x04 };
        const numbers = bytesAsSlice(u32, bytes[0..]);
        try comptime testing.expect(@TypeOf(numbers) == []align(@alignOf(@TypeOf(bytes))) u32);
    }
    {
        var bytes = [_]u8{ 0x01, 0x02, 0x03, 0x04 };
        var runtime_zero: usize = 0;
        _ = &runtime_zero;
        const numbers = bytesAsSlice(u32, bytes[runtime_zero..]);
        try comptime testing.expect(@TypeOf(numbers) == []align(@alignOf(@TypeOf(bytes))) u32);
    }
}

test "bytesAsSlice on a packed struct" {
    const F = packed struct {
        a: u8,
    };

    const b: [1]u8 = .{9};
    const f = bytesAsSlice(F, &b);
    try testing.expect(f[0].a == 9);
}

test "bytesAsSlice with specified alignment" {
    var bytes align(4) = [_]u8{
        0x33,
        0x33,
        0x33,
        0x33,
    };
    const slice: []u32 = std.mem.bytesAsSlice(u32, bytes[0..]);
    try testing.expect(slice[0] == 0x33333333);
}

test "bytesAsSlice preserves pointer attributes" {
    const inArr align(16) = [4]u8{ 0xDE, 0xAD, 0xBE, 0xEF };
    const inSlice = @as(*align(16) const volatile [4]u8, @ptrCast(&inArr))[0..];
    const outSlice = bytesAsSlice(u16, inSlice);

    const in = @typeInfo(@TypeOf(inSlice)).pointer;
    const out = @typeInfo(@TypeOf(outSlice)).pointer;

    try testing.expectEqual(in.is_const, out.is_const);
    try testing.expectEqual(in.is_volatile, out.is_volatile);
    try testing.expectEqual(in.is_allowzero, out.is_allowzero);
    try testing.expectEqual(in.alignment, out.alignment);
}

test "bytesAsSlice with zero-bit element type" {
    {
        const bytes = [_]u8{};
        const slice = bytesAsSlice(void, &bytes);
        try testing.expectEqual(0, slice.len);
    }
    {
        const bytes = [_]u8{ 0x01, 0x02, 0x03, 0x04 };
        const slice = bytesAsSlice(u0, &bytes);
        try testing.expectEqual(0, slice.len);
    }
}

fn SliceAsBytesReturnType(comptime Slice: type) type {
    return CopyPtrAttrs(Slice, .slice, u8);
}

/// Given a slice, returns a slice of the underlying bytes, preserving pointer attributes.
pub fn sliceAsBytes(slice: anytype) SliceAsBytesReturnType(@TypeOf(slice)) {
    const Slice = @TypeOf(slice);

    // a slice of zero-bit values always occupies zero bytes
    if (@sizeOf(std.meta.Elem(Slice)) == 0) return &[0]u8{};

    // let's not give an undefined pointer to @ptrCast
    // it may be equal to zero and fail a null check
    if (slice.len == 0 and std.meta.sentinel(Slice) == null) return &[0]u8{};

    const cast_target = CopyPtrAttrs(Slice, .many, u8);

    return @as(cast_target, @ptrCast(slice))[0 .. slice.len * @sizeOf(std.meta.Elem(Slice))];
}

test sliceAsBytes {
    const bytes = [_]u16{ 0xDEAD, 0xBEEF };
    const slice = sliceAsBytes(bytes[0..]);
    try testing.expect(slice.len == 4);
    try testing.expect(eql(u8, slice, switch (native_endian) {
        .big => "\xDE\xAD\xBE\xEF",
        .little => "\xAD\xDE\xEF\xBE",
    }));
}

test "sliceAsBytes with sentinel slice" {
    const empty_string: [:0]const u8 = "";
    const bytes = sliceAsBytes(empty_string);
    try testing.expect(bytes.len == 0);
}

test "sliceAsBytes with zero-bit element type" {
    const lots_of_nothing = [1]void{{}} ** 10_000;
    const bytes = sliceAsBytes(&lots_of_nothing);
    try testing.expect(bytes.len == 0);
}

test "sliceAsBytes packed struct at runtime and comptime" {
    const Foo = packed struct {
        a: u4,
        b: u4,
    };
    const S = struct {
        fn doTheTest() !void {
            var foo: Foo = undefined;
            var slice = sliceAsBytes(@as(*[1]Foo, &foo)[0..1]);
            slice[0] = 0x13;
            try testing.expect(foo.a == 0x3);
            try testing.expect(foo.b == 0x1);
        }
    };
    try S.doTheTest();
    try comptime S.doTheTest();
}

test "sliceAsBytes and bytesAsSlice back" {
    try testing.expect(@sizeOf(i32) == 4);

    var big_thing_array = [_]i32{ 1, 2, 3, 4 };
    const big_thing_slice: []i32 = big_thing_array[0..];

    const bytes = sliceAsBytes(big_thing_slice);
    try testing.expect(bytes.len == 4 * 4);

    bytes[4] = 0;
    bytes[5] = 0;
    bytes[6] = 0;
    bytes[7] = 0;
    try testing.expect(big_thing_slice[1] == 0);

    const big_thing_again = bytesAsSlice(i32, bytes);
    try testing.expect(big_thing_again[2] == 3);

    big_thing_again[2] = -1;
    try testing.expect(bytes[8] == math.maxInt(u8));
    try testing.expect(bytes[9] == math.maxInt(u8));
    try testing.expect(bytes[10] == math.maxInt(u8));
    try testing.expect(bytes[11] == math.maxInt(u8));
}

test "sliceAsBytes preserves pointer attributes" {
    const inArr align(16) = [2]u16{ 0xDEAD, 0xBEEF };
    const inSlice = @as(*align(16) const volatile [2]u16, @ptrCast(&inArr))[0..];
    const outSlice = sliceAsBytes(inSlice);

    const in = @typeInfo(@TypeOf(inSlice)).pointer;
    const out = @typeInfo(@TypeOf(outSlice)).pointer;

    try testing.expectEqual(in.is_const, out.is_const);
    try testing.expectEqual(in.is_volatile, out.is_volatile);
    try testing.expectEqual(in.is_allowzero, out.is_allowzero);
    try testing.expectEqual(in.alignment, out.alignment);
}

/// Round an address down to the next (or current) aligned address.
/// Unlike `alignForward`, `alignment` can be any positive number, not just a power of 2.
pub fn alignForwardAnyAlign(comptime T: type, addr: T, alignment: T) T {
    if (isValidAlignGeneric(T, alignment))
        return alignForward(T, addr, alignment);
    assert(alignment != 0);
    return alignBackwardAnyAlign(T, addr + (alignment - 1), alignment);
}

/// Round an address up to the next (or current) aligned address.
/// The alignment must be a power of 2 and greater than 0.
/// Asserts that rounding up the address does not cause integer overflow.
pub fn alignForward(comptime T: type, addr: T, alignment: T) T {
    assert(isValidAlignGeneric(T, alignment));
    return alignBackward(T, addr + (alignment - 1), alignment);
}

pub fn alignForwardLog2(addr: usize, log2_alignment: u8) usize {
    const alignment = @as(usize, 1) << @as(math.Log2Int(usize), @intCast(log2_alignment));
    return alignForward(usize, addr, alignment);
}

/// Force an evaluation of the expression; this tries to prevent
/// the compiler from optimizing the computation away even if the
/// result eventually gets discarded.
// TODO: use @declareSideEffect() when it is available - https://github.com/ziglang/zig/issues/6168
pub fn doNotOptimizeAway(val: anytype) void {
    if (@inComptime()) return;

    const max_gp_register_bits = @bitSizeOf(c_long);
    const t = @typeInfo(@TypeOf(val));
    switch (t) {
        .void, .null, .comptime_int, .comptime_float => return,
        .@"enum" => doNotOptimizeAway(@intFromEnum(val)),
        .bool => doNotOptimizeAway(@intFromBool(val)),
        .int => {
            const bits = t.int.bits;
            if (bits <= max_gp_register_bits and builtin.zig_backend != .stage2_c) {
                const val2 = @as(
                    std.meta.Int(t.int.signedness, @max(8, std.math.ceilPowerOfTwoAssert(u16, bits))),
                    val,
                );
                asm volatile (""
                    :
                    : [_] "r" (val2),
                );
            } else doNotOptimizeAway(&val);
        },
        .float => {
            if ((t.float.bits == 32 or t.float.bits == 64) and builtin.zig_backend != .stage2_c) {
                asm volatile (""
                    :
                    : [_] "rm" (val),
                );
            } else doNotOptimizeAway(&val);
        },
        .pointer => {
            if (builtin.zig_backend == .stage2_c) {
                doNotOptimizeAwayC(val);
            } else {
                asm volatile (""
                    :
                    : [_] "m" (val),
                    : .{ .memory = true });
            }
        },
        .array => {
            if (t.array.len * @sizeOf(t.array.child) <= 64) {
                for (val) |v| doNotOptimizeAway(v);
            } else doNotOptimizeAway(&val);
        },
        else => doNotOptimizeAway(&val),
    }
}

/// .stage2_c doesn't support asm blocks yet, so use volatile stores instead
var deopt_target: if (builtin.zig_backend == .stage2_c) u8 else void = undefined;
fn doNotOptimizeAwayC(ptr: anytype) void {
    const dest = @as(*volatile u8, @ptrCast(&deopt_target));
    for (asBytes(ptr)) |b| {
        dest.* = b;
    }
    dest.* = 0;
}

test doNotOptimizeAway {
    comptime doNotOptimizeAway("test");

    doNotOptimizeAway(null);
    doNotOptimizeAway(true);
    doNotOptimizeAway(0);
    doNotOptimizeAway(0.0);
    doNotOptimizeAway(@as(u1, 0));
    doNotOptimizeAway(@as(u3, 0));
    doNotOptimizeAway(@as(u8, 0));
    doNotOptimizeAway(@as(u16, 0));
    doNotOptimizeAway(@as(u32, 0));
    doNotOptimizeAway(@as(u64, 0));
    doNotOptimizeAway(@as(u128, 0));
    doNotOptimizeAway(@as(u13, 0));
    doNotOptimizeAway(@as(u37, 0));
    doNotOptimizeAway(@as(u96, 0));
    doNotOptimizeAway(@as(u200, 0));
    doNotOptimizeAway(@as(f32, 0.0));
    doNotOptimizeAway(@as(f64, 0.0));
    doNotOptimizeAway([_]u8{0} ** 4);
    doNotOptimizeAway([_]u8{0} ** 100);
    doNotOptimizeAway(@as(std.builtin.Endian, .little));
}

test alignForward {
    try testing.expect(alignForward(usize, 1, 1) == 1);
    try testing.expect(alignForward(usize, 2, 1) == 2);
    try testing.expect(alignForward(usize, 1, 2) == 2);
    try testing.expect(alignForward(usize, 2, 2) == 2);
    try testing.expect(alignForward(usize, 3, 2) == 4);
    try testing.expect(alignForward(usize, 4, 2) == 4);
    try testing.expect(alignForward(usize, 7, 8) == 8);
    try testing.expect(alignForward(usize, 8, 8) == 8);
    try testing.expect(alignForward(usize, 9, 8) == 16);
    try testing.expect(alignForward(usize, 15, 8) == 16);
    try testing.expect(alignForward(usize, 16, 8) == 16);
    try testing.expect(alignForward(usize, 17, 8) == 24);
}

/// Round an address down to the previous (or current) aligned address.
/// Unlike `alignBackward`, `alignment` can be any positive number, not just a power of 2.
pub fn alignBackwardAnyAlign(comptime T: type, addr: T, alignment: T) T {
    if (isValidAlignGeneric(T, alignment))
        return alignBackward(T, addr, alignment);
    assert(alignment != 0);
    return addr - @mod(addr, alignment);
}

/// Round an address down to the previous (or current) aligned address.
/// The alignment must be a power of 2 and greater than 0.
pub fn alignBackward(comptime T: type, addr: T, alignment: T) T {
    assert(isValidAlignGeneric(T, alignment));
    // 000010000 // example alignment
    // 000001111 // subtract 1
    // 111110000 // binary not
    return addr & ~(alignment - 1);
}

/// Returns whether `alignment` is a valid alignment, meaning it is
/// a positive power of 2.
pub fn isValidAlign(alignment: usize) bool {
    return isValidAlignGeneric(usize, alignment);
}

/// Returns whether `alignment` is a valid alignment, meaning it is
/// a positive power of 2.
pub fn isValidAlignGeneric(comptime T: type, alignment: T) bool {
    return alignment > 0 and std.math.isPowerOfTwo(alignment);
}

pub fn isAlignedAnyAlign(i: usize, alignment: usize) bool {
    if (isValidAlign(alignment))
        return isAligned(i, alignment);
    assert(alignment != 0);
    return 0 == @mod(i, alignment);
}

pub fn isAlignedLog2(addr: usize, log2_alignment: u8) bool {
    return @ctz(addr) >= log2_alignment;
}

/// Given an address and an alignment, return true if the address is a multiple of the alignment
/// The alignment must be a power of 2 and greater than 0.
pub fn isAligned(addr: usize, alignment: usize) bool {
    return isAlignedGeneric(u64, addr, alignment);
}

pub fn isAlignedGeneric(comptime T: type, addr: T, alignment: T) bool {
    return alignBackward(T, addr, alignment) == addr;
}

test isAligned {
    try testing.expect(isAligned(0, 4));
    try testing.expect(isAligned(1, 1));
    try testing.expect(isAligned(2, 1));
    try testing.expect(isAligned(2, 2));
    try testing.expect(!isAligned(2, 4));
    try testing.expect(isAligned(3, 1));
    try testing.expect(!isAligned(3, 2));
    try testing.expect(!isAligned(3, 4));
    try testing.expect(isAligned(4, 4));
    try testing.expect(isAligned(4, 2));
    try testing.expect(isAligned(4, 1));
    try testing.expect(!isAligned(4, 8));
    try testing.expect(!isAligned(4, 16));
}

test "freeing empty string with null-terminated sentinel" {
    const empty_string = try testing.allocator.dupeZ(u8, "");
    testing.allocator.free(empty_string);
}

/// Returns a slice with the given new alignment,
/// all other pointer attributes copied from `AttributeSource`.
fn AlignedSlice(comptime AttributeSource: type, comptime new_alignment: usize) type {
    const info = @typeInfo(AttributeSource).pointer;
    return @Type(.{
        .pointer = .{
            .size = .slice,
            .is_const = info.is_const,
            .is_volatile = info.is_volatile,
            .is_allowzero = info.is_allowzero,
            .alignment = new_alignment,
            .address_space = info.address_space,
            .child = info.child,
            .sentinel_ptr = null,
        },
    });
}

/// Returns the largest slice in the given bytes that conforms to the new alignment,
/// or `null` if the given bytes contain no conforming address.
pub fn alignInBytes(bytes: []u8, comptime new_alignment: usize) ?[]align(new_alignment) u8 {
    const begin_address = @intFromPtr(bytes.ptr);
    const end_address = begin_address + bytes.len;

    const begin_address_aligned = mem.alignForward(usize, begin_address, new_alignment);
    const new_length = std.math.sub(usize, end_address, begin_address_aligned) catch |e| switch (e) {
        error.Overflow => return null,
    };
    const alignment_offset = begin_address_aligned - begin_address;
    return @alignCast(bytes[alignment_offset .. alignment_offset + new_length]);
}

/// Returns the largest sub-slice within the given slice that conforms to the new alignment,
/// or `null` if the given slice contains no conforming address.
pub fn alignInSlice(slice: anytype, comptime new_alignment: usize) ?AlignedSlice(@TypeOf(slice), new_alignment) {
    const bytes = sliceAsBytes(slice);
    const aligned_bytes = alignInBytes(bytes, new_alignment) orelse return null;

    const Element = @TypeOf(slice[0]);
    const slice_length_bytes = aligned_bytes.len - (aligned_bytes.len % @sizeOf(Element));
    const aligned_slice = bytesAsSlice(Element, aligned_bytes[0..slice_length_bytes]);
    return @alignCast(aligned_slice);
}

test "read/write(Var)PackedInt" {
    switch (builtin.cpu.arch) {
        // This test generates too much code to execute on WASI.
        // LLVM backend fails with "too many locals: locals exceed maximum"
        .wasm32, .wasm64 => return error.SkipZigTest,
        else => {},
    }

    const foreign_endian: Endian = if (native_endian == .big) .little else .big;
    const expect = std.testing.expect;
    var prng = std.Random.DefaultPrng.init(1234);
    const random = prng.random();

    @setEvalBranchQuota(10_000);
    inline for ([_]type{ u8, u16, u32, u128 }) |BackingType| {
        for ([_]BackingType{
            @as(BackingType, 0), // all zeros
            -%@as(BackingType, 1), // all ones
            random.int(BackingType), // random
            random.int(BackingType), // random
            random.int(BackingType), // random
        }) |init_value| {
            const uTs = [_]type{ u1, u3, u7, u8, u9, u10, u15, u16, u86 };
            const iTs = [_]type{ i1, i3, i7, i8, i9, i10, i15, i16, i86 };
            inline for (uTs ++ iTs) |PackedType| {
                if (@bitSizeOf(PackedType) > @bitSizeOf(BackingType))
                    continue;

                const iPackedType = std.meta.Int(.signed, @bitSizeOf(PackedType));
                const uPackedType = std.meta.Int(.unsigned, @bitSizeOf(PackedType));
                const Log2T = std.math.Log2Int(BackingType);

                const offset_at_end = @bitSizeOf(BackingType) - @bitSizeOf(PackedType);
                for ([_]usize{ 0, 1, 7, 8, 9, 10, 15, 16, 86, offset_at_end }) |offset| {
                    if (offset > offset_at_end or offset == @bitSizeOf(BackingType))
                        continue;

                    for ([_]PackedType{
                        ~@as(PackedType, 0), // all ones: -1 iN / maxInt uN
                        @as(PackedType, 0), // all zeros: 0 iN / 0 uN
                        @as(PackedType, @bitCast(@as(iPackedType, math.maxInt(iPackedType)))), // maxInt iN
                        @as(PackedType, @bitCast(@as(iPackedType, math.minInt(iPackedType)))), // maxInt iN
                        random.int(PackedType), // random
                        random.int(PackedType), // random
                    }) |write_value| {
                        { // Fixed-size Read/Write (Native-endian)

                            // Initialize Value
                            var value: BackingType = init_value;

                            // Read
                            const read_value1 = readPackedInt(PackedType, asBytes(&value), offset, native_endian);
                            try expect(read_value1 == @as(PackedType, @bitCast(@as(uPackedType, @truncate(value >> @as(Log2T, @intCast(offset)))))));

                            // Write
                            writePackedInt(PackedType, asBytes(&value), offset, write_value, native_endian);
                            try expect(write_value == @as(PackedType, @bitCast(@as(uPackedType, @truncate(value >> @as(Log2T, @intCast(offset)))))));

                            // Read again
                            const read_value2 = readPackedInt(PackedType, asBytes(&value), offset, native_endian);
                            try expect(read_value2 == write_value);

                            // Verify bits outside of the target integer are unmodified
                            const diff_bits = init_value ^ value;
                            if (offset != offset_at_end)
                                try expect(diff_bits >> @as(Log2T, @intCast(offset + @bitSizeOf(PackedType))) == 0);
                            if (offset != 0)
                                try expect(diff_bits << @as(Log2T, @intCast(@bitSizeOf(BackingType) - offset)) == 0);
                        }

                        { // Fixed-size Read/Write (Foreign-endian)

                            // Initialize Value
                            var value: BackingType = @byteSwap(init_value);

                            // Read
                            const read_value1 = readPackedInt(PackedType, asBytes(&value), offset, foreign_endian);
                            try expect(read_value1 == @as(PackedType, @bitCast(@as(uPackedType, @truncate(@byteSwap(value) >> @as(Log2T, @intCast(offset)))))));

                            // Write
                            writePackedInt(PackedType, asBytes(&value), offset, write_value, foreign_endian);
                            try expect(write_value == @as(PackedType, @bitCast(@as(uPackedType, @truncate(@byteSwap(value) >> @as(Log2T, @intCast(offset)))))));

                            // Read again
                            const read_value2 = readPackedInt(PackedType, asBytes(&value), offset, foreign_endian);
                            try expect(read_value2 == write_value);

                            // Verify bits outside of the target integer are unmodified
                            const diff_bits = init_value ^ @byteSwap(value);
                            if (offset != offset_at_end)
                                try expect(diff_bits >> @as(Log2T, @intCast(offset + @bitSizeOf(PackedType))) == 0);
                            if (offset != 0)
                                try expect(diff_bits << @as(Log2T, @intCast(@bitSizeOf(BackingType) - offset)) == 0);
                        }

                        const signedness = @typeInfo(PackedType).int.signedness;
                        const NextPowerOfTwoInt = std.meta.Int(signedness, try comptime std.math.ceilPowerOfTwo(u16, @bitSizeOf(PackedType)));
                        const ui64 = std.meta.Int(signedness, 64);
                        inline for ([_]type{ PackedType, NextPowerOfTwoInt, ui64 }) |U| {
                            { // Variable-size Read/Write (Native-endian)

                                if (@bitSizeOf(U) < @bitSizeOf(PackedType))
                                    continue;

                                // Initialize Value
                                var value: BackingType = init_value;

                                // Read
                                const read_value1 = readVarPackedInt(U, asBytes(&value), offset, @bitSizeOf(PackedType), native_endian, signedness);
                                try expect(read_value1 == @as(PackedType, @bitCast(@as(uPackedType, @truncate(value >> @as(Log2T, @intCast(offset)))))));

                                // Write
                                writeVarPackedInt(asBytes(&value), offset, @bitSizeOf(PackedType), @as(U, write_value), native_endian);
                                try expect(write_value == @as(PackedType, @bitCast(@as(uPackedType, @truncate(value >> @as(Log2T, @intCast(offset)))))));

                                // Read again
                                const read_value2 = readVarPackedInt(U, asBytes(&value), offset, @bitSizeOf(PackedType), native_endian, signedness);
                                try expect(read_value2 == write_value);

                                // Verify bits outside of the target integer are unmodified
                                const diff_bits = init_value ^ value;
                                if (offset != offset_at_end)
                                    try expect(diff_bits >> @as(Log2T, @intCast(offset + @bitSizeOf(PackedType))) == 0);
                                if (offset != 0)
                                    try expect(diff_bits << @as(Log2T, @intCast(@bitSizeOf(BackingType) - offset)) == 0);
                            }

                            { // Variable-size Read/Write (Foreign-endian)

                                if (@bitSizeOf(U) < @bitSizeOf(PackedType))
                                    continue;

                                // Initialize Value
                                var value: BackingType = @byteSwap(init_value);

                                // Read
                                const read_value1 = readVarPackedInt(U, asBytes(&value), offset, @bitSizeOf(PackedType), foreign_endian, signedness);
                                try expect(read_value1 == @as(PackedType, @bitCast(@as(uPackedType, @truncate(@byteSwap(value) >> @as(Log2T, @intCast(offset)))))));

                                // Write
                                writeVarPackedInt(asBytes(&value), offset, @bitSizeOf(PackedType), @as(U, write_value), foreign_endian);
                                try expect(write_value == @as(PackedType, @bitCast(@as(uPackedType, @truncate(@byteSwap(value) >> @as(Log2T, @intCast(offset)))))));

                                // Read again
                                const read_value2 = readVarPackedInt(U, asBytes(&value), offset, @bitSizeOf(PackedType), foreign_endian, signedness);
                                try expect(read_value2 == write_value);

                                // Verify bits outside of the target integer are unmodified
                                const diff_bits = init_value ^ @byteSwap(value);
                                if (offset != offset_at_end)
                                    try expect(diff_bits >> @as(Log2T, @intCast(offset + @bitSizeOf(PackedType))) == 0);
                                if (offset != 0)
                                    try expect(diff_bits << @as(Log2T, @intCast(@bitSizeOf(BackingType) - offset)) == 0);
                            }
                        }
                    }
                }
            }
        }
    }
}
