const std = @import("std");
const builtin = @import("builtin");
const native_endian = builtin.cpu.arch.endian();
const ofmt_c = builtin.object_format == .c;

/// For now, we prefer weak linkage because some of the routines we implement here may also be
/// provided by system/dynamic libc. Eventually we should be more disciplined about this on a
/// per-symbol, per-target basis: https://github.com/ziglang/zig/issues/11883
pub const linkage: std.builtin.GlobalLinkage = if (builtin.is_test)
    .internal
else if (ofmt_c)
    .strong
else
    .weak;

/// Determines the symbol's visibility to other objects.
/// For WebAssembly this allows the symbol to be resolved to other modules, but will not
/// export it to the host runtime.
pub const visibility: std.builtin.SymbolVisibility = if (linkage == .internal or builtin.link_mode == .dynamic)
    .default
else
    .hidden;

pub const PreferredLoadStoreElement = element: {
    if (std.simd.suggestVectorLength(u8)) |vec_size| {
        const Vec = @Vector(vec_size, u8);

        if (@sizeOf(Vec) == vec_size and std.math.isPowerOfTwo(vec_size)) {
            break :element Vec;
        }
    }
    break :element usize;
};

pub const want_aeabi = switch (builtin.abi) {
    .eabi,
    .eabihf,
    .musleabi,
    .musleabihf,
    .gnueabi,
    .gnueabihf,
    .android,
    .androideabi,
    => switch (builtin.cpu.arch) {
        .arm, .armeb, .thumb, .thumbeb => true,
        else => false,
    },
    else => false,
};

/// These functions are provided by libc when targeting MSVC, but not MinGW.
// Temporarily used for thumb-uefi until https://github.com/ziglang/zig/issues/21630 is addressed.
pub const want_windows_arm_abi = builtin.cpu.arch.isArm() and (builtin.os.tag == .windows or builtin.os.tag == .uefi) and (builtin.abi.isGnu() or !builtin.link_libc);

pub const want_windows_msvc_or_itanium_abi = switch (builtin.abi) {
    .none, .msvc, .itanium => builtin.os.tag == .windows,
    else => false,
};

pub const want_ppc_abi = builtin.cpu.arch.isPowerPC();

pub const want_float_exceptions = !builtin.cpu.arch.isWasm();

// Libcalls that involve u128 on Windows x86-64 are expected by LLVM to use the
// calling convention of @Vector(2, u64), rather than what's standard.
pub const want_windows_v2u64_abi = builtin.os.tag == .windows and builtin.cpu.arch == .x86_64 and !ofmt_c;

/// This governs whether to use these symbol names for f16/f32 conversions
/// rather than the standard names:
/// * __gnu_f2h_ieee
/// * __gnu_h2f_ieee
/// Known correct configurations:
///   x86_64-freestanding-none => true
///   x86_64-linux-none => true
///   x86_64-linux-gnu => true
///   x86_64-linux-musl => true
///   x86_64-linux-eabi => true
///   arm-linux-musleabihf => true
///   arm-linux-gnueabihf => true
///   arm-linux-eabihf => false
///   wasm32-wasi-musl => false
///   wasm32-freestanding-none => false
///   x86_64-windows-gnu => true
///   x86_64-windows-msvc => true
///   any-macos-any => false
pub const gnu_f16_abi = switch (builtin.cpu.arch) {
    .wasm32,
    .wasm64,
    .riscv64,
    .riscv32,
    => false,

    .x86, .x86_64 => true,

    .arm, .armeb, .thumb, .thumbeb => switch (builtin.abi) {
        .eabi, .eabihf => false,
        else => true,
    },

    else => !builtin.os.tag.isDarwin(),
};

pub const want_sparc_abi = builtin.cpu.arch.isSPARC();

pub const test_safety = switch (builtin.zig_backend) {
    .stage2_aarch64 => false,
    else => builtin.is_test,
};

// Avoid dragging in the runtime safety mechanisms into this .o file, unless
// we're trying to test compiler-rt.
pub const panic = if (test_safety) std.debug.FullPanic(std.debug.defaultPanic) else std.debug.no_panic;

/// This seems to mostly correspond to `clang::TargetInfo::HasFloat16`.
pub fn F16T(comptime OtherType: type) type {
    return switch (builtin.cpu.arch) {
        .amdgcn,
        .arm,
        .armeb,
        .thumb,
        .thumbeb,
        .aarch64,
        .aarch64_be,
        .nvptx,
        .nvptx64,
        .riscv32,
        .riscv64,
        .spirv32,
        .spirv64,
        => f16,
        .hexagon => if (builtin.target.cpu.has(.hexagon, .v68)) f16 else u16,
        .x86, .x86_64 => if (builtin.target.os.tag.isDarwin()) switch (OtherType) {
            // Starting with LLVM 16, Darwin uses different abi for f16
            // depending on the type of the other return/argument..???
            f32, f64 => u16,
            f80, f128 => f16,
            else => unreachable,
        } else f16,
        else => u16,
    };
}

pub fn wideMultiply(comptime Z: type, a: Z, b: Z, hi: *Z, lo: *Z) void {
    switch (Z) {
        u16 => {
            // 16x16 --> 32 bit multiply
            const product = @as(u32, a) * @as(u32, b);
            hi.* = @intCast(product >> 16);
            lo.* = @truncate(product);
        },
        u32 => {
            // 32x32 --> 64 bit multiply
            const product = @as(u64, a) * @as(u64, b);
            hi.* = @truncate(product >> 32);
            lo.* = @truncate(product);
        },
        u64 => {
            const S = struct {
                fn loWord(x: u64) u64 {
                    return @as(u32, @truncate(x));
                }
                fn hiWord(x: u64) u64 {
                    return @as(u32, @truncate(x >> 32));
                }
            };
            // 64x64 -> 128 wide multiply for platforms that don't have such an operation;
            // many 64-bit platforms have this operation, but they tend to have hardware
            // floating-point, so we don't bother with a special case for them here.
            // Each of the component 32x32 -> 64 products
            const plolo: u64 = S.loWord(a) * S.loWord(b);
            const plohi: u64 = S.loWord(a) * S.hiWord(b);
            const philo: u64 = S.hiWord(a) * S.loWord(b);
            const phihi: u64 = S.hiWord(a) * S.hiWord(b);
            // Sum terms that contribute to lo in a way that allows us to get the carry
            const r0: u64 = S.loWord(plolo);
            const r1: u64 = S.hiWord(plolo) +% S.loWord(plohi) +% S.loWord(philo);
            lo.* = r0 +% (r1 << 32);
            // Sum terms contributing to hi with the carry from lo
            hi.* = S.hiWord(plohi) +% S.hiWord(philo) +% S.hiWord(r1) +% phihi;
        },
        u128 => {
            const Word_LoMask: u64 = 0x00000000ffffffff;
            const Word_HiMask: u64 = 0xffffffff00000000;
            const Word_FullMask: u64 = 0xffffffffffffffff;
            const S = struct {
                fn Word_1(x: u128) u64 {
                    return @as(u32, @truncate(x >> 96));
                }
                fn Word_2(x: u128) u64 {
                    return @as(u32, @truncate(x >> 64));
                }
                fn Word_3(x: u128) u64 {
                    return @as(u32, @truncate(x >> 32));
                }
                fn Word_4(x: u128) u64 {
                    return @as(u32, @truncate(x));
                }
            };
            // 128x128 -> 256 wide multiply for platforms that don't have such an operation;
            // many 64-bit platforms have this operation, but they tend to have hardware
            // floating-point, so we don't bother with a special case for them here.

            const product11: u64 = S.Word_1(a) * S.Word_1(b);
            const product12: u64 = S.Word_1(a) * S.Word_2(b);
            const product13: u64 = S.Word_1(a) * S.Word_3(b);
            const product14: u64 = S.Word_1(a) * S.Word_4(b);
            const product21: u64 = S.Word_2(a) * S.Word_1(b);
            const product22: u64 = S.Word_2(a) * S.Word_2(b);
            const product23: u64 = S.Word_2(a) * S.Word_3(b);
            const product24: u64 = S.Word_2(a) * S.Word_4(b);
            const product31: u64 = S.Word_3(a) * S.Word_1(b);
            const product32: u64 = S.Word_3(a) * S.Word_2(b);
            const product33: u64 = S.Word_3(a) * S.Word_3(b);
            const product34: u64 = S.Word_3(a) * S.Word_4(b);
            const product41: u64 = S.Word_4(a) * S.Word_1(b);
            const product42: u64 = S.Word_4(a) * S.Word_2(b);
            const product43: u64 = S.Word_4(a) * S.Word_3(b);
            const product44: u64 = S.Word_4(a) * S.Word_4(b);

            const sum0: u128 = @as(u128, product44);
            const sum1: u128 = @as(u128, product34) +%
                @as(u128, product43);
            const sum2: u128 = @as(u128, product24) +%
                @as(u128, product33) +%
                @as(u128, product42);
            const sum3: u128 = @as(u128, product14) +%
                @as(u128, product23) +%
                @as(u128, product32) +%
                @as(u128, product41);
            const sum4: u128 = @as(u128, product13) +%
                @as(u128, product22) +%
                @as(u128, product31);
            const sum5: u128 = @as(u128, product12) +%
                @as(u128, product21);
            const sum6: u128 = @as(u128, product11);

            const r0: u128 = (sum0 & Word_FullMask) +%
                ((sum1 & Word_LoMask) << 32);
            const r1: u128 = (sum0 >> 64) +%
                ((sum1 >> 32) & Word_FullMask) +%
                (sum2 & Word_FullMask) +%
                ((sum3 << 32) & Word_HiMask);

            lo.* = r0 +% (r1 << 64);
            hi.* = (r1 >> 64) +%
                (sum1 >> 96) +%
                (sum2 >> 64) +%
                (sum3 >> 32) +%
                sum4 +%
                (sum5 << 32) +%
                (sum6 << 64);
        },
        else => @compileError("unsupported"),
    }
}

pub fn normalize(comptime T: type, significand: *std.meta.Int(.unsigned, @typeInfo(T).float.bits)) i32 {
    const Z = std.meta.Int(.unsigned, @typeInfo(T).float.bits);
    const integerBit = @as(Z, 1) << std.math.floatFractionalBits(T);

    const shift = @clz(significand.*) - @clz(integerBit);
    significand.* <<= @as(std.math.Log2Int(Z), @intCast(shift));
    return @as(i32, 1) - shift;
}

pub inline fn fneg(a: anytype) @TypeOf(a) {
    const F = @TypeOf(a);
    const bits = @typeInfo(F).float.bits;
    const U = @Type(.{ .int = .{
        .signedness = .unsigned,
        .bits = bits,
    } });
    const sign_bit_mask = @as(U, 1) << (bits - 1);
    const negated = @as(U, @bitCast(a)) ^ sign_bit_mask;
    return @bitCast(negated);
}

/// Allows to access underlying bits as two equally sized lower and higher
/// signed or unsigned integers.
pub fn HalveInt(comptime T: type, comptime signed_half: bool) type {
    return extern union {
        pub const bits = @divExact(@typeInfo(T).int.bits, 2);
        pub const HalfTU = std.meta.Int(.unsigned, bits);
        pub const HalfTS = std.meta.Int(.signed, bits);
        pub const HalfT = if (signed_half) HalfTS else HalfTU;

        all: T,
        s: if (native_endian == .little)
            extern struct { low: HalfT, high: HalfT }
        else
            extern struct { high: HalfT, low: HalfT },
    };
}
