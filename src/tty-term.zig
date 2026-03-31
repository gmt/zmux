// Copyright (c) 2026 Greg Turner <gmt@be-evil.net>
//
// Permission to use, copy, modify, and distribute this software for any
// purpose with or without fee is hereby granted, provided that the above
// copyright notice and this permission notice appear in all copies.
//
// THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
// WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
// MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
// ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
// WHATSOEVER RESULTING FROM LOSS OF MIND, USE, DATA OR PROFITS, WHETHER
// IN AN ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING
// OUT OF OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
//
// Written for zmux by Greg Turner. This file is new zmux runtime work that
// gives the reduced tty/runtime path one real terminfo-backed capability layer.
// Ported from tmux/tty-term.c (terminal capability lookup layer).

//! tty-term.zig -- complete terminfo capability layer ported from tmux's tty-term.c.
//!
//! Provides the TTYC enum of all terminal capability codes, a typed capability
//! code table, and lookup functions used by tty.zig and the TTY output layer.

const std = @import("std");
const T = @import("types.zig");
const xm = @import("xmalloc.zig");
const c = @import("c.zig");
const log = @import("log.zig");

// ── Capability types ──────────────────────────────────────────────────────

pub const CapabilityType = enum {
    none,
    string,
    number,
    flag,
};

pub const CapabilityValue = union(CapabilityType) {
    none: void,
    string: []u8,
    number: i32,
    flag: bool,
};

// ── TTYC capability codes ─────────────────────────────────────────────────
//
// Mirrors tmux's enum tty_code_code from tmux.h, listing every terminal
// capability that tty.c, tty-keys.c, screen-redraw.c, etc. may query.

pub const TTYC = enum(usize) {
    ACSC,
    AM,
    AX,
    BCE,
    BEL,
    BIDI,
    BLINK,
    BOLD,
    CIVIS,
    CLEAR,
    CLMG,
    CMG,
    CNORM,
    COLORS,
    CR,
    CS,
    CSR,
    CUB,
    CUB1,
    CUD,
    CUD1,
    CUF,
    CUF1,
    CUP,
    CUU,
    CUU1,
    CVVIS,
    DCH,
    DCH1,
    DIM,
    DL,
    DL1,
    DSBP,
    DSEKS,
    DSFCS,
    DSMG,
    E3,
    ECH,
    ED,
    EL,
    EL1,
    ENACS,
    ENBP,
    ENEKS,
    ENFCS,
    ENMG,
    FSL,
    HLS,
    HOME,
    HPA,
    ICH,
    ICH1,
    IL,
    IL1,
    INDN,
    INVIS,
    KCBT,
    KCUB1,
    KCUD1,
    KCUF1,
    KCUU1,
    KDC2,
    KDC3,
    KDC4,
    KDC5,
    KDC6,
    KDC7,
    KDCH1,
    KDN2,
    KDN3,
    KDN4,
    KDN5,
    KDN6,
    KDN7,
    KEND,
    KEND2,
    KEND3,
    KEND4,
    KEND5,
    KEND6,
    KEND7,
    KF1,
    KF2,
    KF3,
    KF4,
    KF5,
    KF6,
    KF7,
    KF8,
    KF9,
    KF10,
    KF11,
    KF12,
    KF13,
    KF14,
    KF15,
    KF16,
    KF17,
    KF18,
    KF19,
    KF20,
    KF21,
    KF22,
    KF23,
    KF24,
    KF25,
    KF26,
    KF27,
    KF28,
    KF29,
    KF30,
    KF31,
    KF32,
    KF33,
    KF34,
    KF35,
    KF36,
    KF37,
    KF38,
    KF39,
    KF40,
    KF41,
    KF42,
    KF43,
    KF44,
    KF45,
    KF46,
    KF47,
    KF48,
    KF49,
    KF50,
    KF51,
    KF52,
    KF53,
    KF54,
    KF55,
    KF56,
    KF57,
    KF58,
    KF59,
    KF60,
    KF61,
    KF62,
    KF63,
    KHOM2,
    KHOM3,
    KHOM4,
    KHOM5,
    KHOM6,
    KHOM7,
    KHOME,
    KIC2,
    KIC3,
    KIC4,
    KIC5,
    KIC6,
    KIC7,
    KICH1,
    KIND,
    KLFT2,
    KLFT3,
    KLFT4,
    KLFT5,
    KLFT6,
    KLFT7,
    KMOUS,
    KNP,
    KNXT2,
    KNXT3,
    KNXT4,
    KNXT5,
    KNXT6,
    KNXT7,
    KPP,
    KPRV2,
    KPRV3,
    KPRV4,
    KPRV5,
    KPRV6,
    KPRV7,
    KRI,
    KRIT2,
    KRIT3,
    KRIT4,
    KRIT5,
    KRIT6,
    KRIT7,
    KUP2,
    KUP3,
    KUP4,
    KUP5,
    KUP6,
    KUP7,
    MS,
    NOBR,
    OL,
    OP,
    RECT,
    REV,
    RGB,
    RI,
    RIN,
    RMACS,
    RMCUP,
    RMKX,
    SE,
    SETAB,
    SETAF,
    SETAL,
    SETRGBB,
    SETRGBF,
    SETULC,
    SETULC1,
    SGR0,
    SITM,
    SMACS,
    SMCUP,
    SMKX,
    SMOL,
    SMSO,
    SMUL,
    SMULX,
    SMXX,
    SXL,
    SS,
    SWD,
    SYNC,
    TC,
    TSL,
    U8,
    VPA,
    XT,

    pub fn count() usize {
        return @typeInfo(TTYC).@"enum".fields.len;
    }
};

// ── Capability code table ─────────────────────────────────────────────────
//
// Maps each TTYC enum value to its terminfo name and expected type.
// Order matches the enum definition (array-indexed).

const CodeEntry = struct {
    cap_type: CapabilityType,
    name: []const u8,
};

const code_table = [_]CodeEntry{
    .{ .cap_type = .string, .name = "acsc" }, // ACSC
    .{ .cap_type = .flag, .name = "am" }, // AM
    .{ .cap_type = .flag, .name = "AX" }, // AX
    .{ .cap_type = .flag, .name = "bce" }, // BCE
    .{ .cap_type = .string, .name = "bel" }, // BEL
    .{ .cap_type = .string, .name = "Bidi" }, // BIDI
    .{ .cap_type = .string, .name = "blink" }, // BLINK
    .{ .cap_type = .string, .name = "bold" }, // BOLD
    .{ .cap_type = .string, .name = "civis" }, // CIVIS
    .{ .cap_type = .string, .name = "clear" }, // CLEAR
    .{ .cap_type = .string, .name = "Clmg" }, // CLMG
    .{ .cap_type = .string, .name = "Cmg" }, // CMG
    .{ .cap_type = .string, .name = "cnorm" }, // CNORM
    .{ .cap_type = .number, .name = "colors" }, // COLORS
    .{ .cap_type = .string, .name = "Cr" }, // CR
    .{ .cap_type = .string, .name = "Cs" }, // CS
    .{ .cap_type = .string, .name = "csr" }, // CSR
    .{ .cap_type = .string, .name = "cub" }, // CUB
    .{ .cap_type = .string, .name = "cub1" }, // CUB1
    .{ .cap_type = .string, .name = "cud" }, // CUD
    .{ .cap_type = .string, .name = "cud1" }, // CUD1
    .{ .cap_type = .string, .name = "cuf" }, // CUF
    .{ .cap_type = .string, .name = "cuf1" }, // CUF1
    .{ .cap_type = .string, .name = "cup" }, // CUP
    .{ .cap_type = .string, .name = "cuu" }, // CUU
    .{ .cap_type = .string, .name = "cuu1" }, // CUU1
    .{ .cap_type = .string, .name = "cvvis" }, // CVVIS
    .{ .cap_type = .string, .name = "dch" }, // DCH
    .{ .cap_type = .string, .name = "dch1" }, // DCH1
    .{ .cap_type = .string, .name = "dim" }, // DIM
    .{ .cap_type = .string, .name = "dl" }, // DL
    .{ .cap_type = .string, .name = "dl1" }, // DL1
    .{ .cap_type = .string, .name = "Dsbp" }, // DSBP
    .{ .cap_type = .string, .name = "Dseks" }, // DSEKS
    .{ .cap_type = .string, .name = "Dsfcs" }, // DSFCS
    .{ .cap_type = .string, .name = "Dsmg" }, // DSMG
    .{ .cap_type = .string, .name = "E3" }, // E3
    .{ .cap_type = .string, .name = "ech" }, // ECH
    .{ .cap_type = .string, .name = "ed" }, // ED
    .{ .cap_type = .string, .name = "el" }, // EL
    .{ .cap_type = .string, .name = "el1" }, // EL1
    .{ .cap_type = .string, .name = "enacs" }, // ENACS
    .{ .cap_type = .string, .name = "Enbp" }, // ENBP
    .{ .cap_type = .string, .name = "Eneks" }, // ENEKS
    .{ .cap_type = .string, .name = "Enfcs" }, // ENFCS
    .{ .cap_type = .string, .name = "Enmg" }, // ENMG
    .{ .cap_type = .string, .name = "fsl" }, // FSL
    .{ .cap_type = .string, .name = "Hls" }, // HLS
    .{ .cap_type = .string, .name = "home" }, // HOME
    .{ .cap_type = .string, .name = "hpa" }, // HPA
    .{ .cap_type = .string, .name = "ich" }, // ICH
    .{ .cap_type = .string, .name = "ich1" }, // ICH1
    .{ .cap_type = .string, .name = "il" }, // IL
    .{ .cap_type = .string, .name = "il1" }, // IL1
    .{ .cap_type = .string, .name = "indn" }, // INDN
    .{ .cap_type = .string, .name = "invis" }, // INVIS
    .{ .cap_type = .string, .name = "kcbt" }, // KCBT
    .{ .cap_type = .string, .name = "kcub1" }, // KCUB1
    .{ .cap_type = .string, .name = "kcud1" }, // KCUD1
    .{ .cap_type = .string, .name = "kcuf1" }, // KCUF1
    .{ .cap_type = .string, .name = "kcuu1" }, // KCUU1
    .{ .cap_type = .string, .name = "kDC" }, // KDC2
    .{ .cap_type = .string, .name = "kDC3" }, // KDC3
    .{ .cap_type = .string, .name = "kDC4" }, // KDC4
    .{ .cap_type = .string, .name = "kDC5" }, // KDC5
    .{ .cap_type = .string, .name = "kDC6" }, // KDC6
    .{ .cap_type = .string, .name = "kDC7" }, // KDC7
    .{ .cap_type = .string, .name = "kdch1" }, // KDCH1
    .{ .cap_type = .string, .name = "kDN" }, // KDN2
    .{ .cap_type = .string, .name = "kDN3" }, // KDN3
    .{ .cap_type = .string, .name = "kDN4" }, // KDN4
    .{ .cap_type = .string, .name = "kDN5" }, // KDN5
    .{ .cap_type = .string, .name = "kDN6" }, // KDN6
    .{ .cap_type = .string, .name = "kDN7" }, // KDN7
    .{ .cap_type = .string, .name = "kend" }, // KEND
    .{ .cap_type = .string, .name = "kEND" }, // KEND2
    .{ .cap_type = .string, .name = "kEND3" }, // KEND3
    .{ .cap_type = .string, .name = "kEND4" }, // KEND4
    .{ .cap_type = .string, .name = "kEND5" }, // KEND5
    .{ .cap_type = .string, .name = "kEND6" }, // KEND6
    .{ .cap_type = .string, .name = "kEND7" }, // KEND7
    .{ .cap_type = .string, .name = "kf1" }, // KF1
    .{ .cap_type = .string, .name = "kf2" }, // KF2
    .{ .cap_type = .string, .name = "kf3" }, // KF3
    .{ .cap_type = .string, .name = "kf4" }, // KF4
    .{ .cap_type = .string, .name = "kf5" }, // KF5
    .{ .cap_type = .string, .name = "kf6" }, // KF6
    .{ .cap_type = .string, .name = "kf7" }, // KF7
    .{ .cap_type = .string, .name = "kf8" }, // KF8
    .{ .cap_type = .string, .name = "kf9" }, // KF9
    .{ .cap_type = .string, .name = "kf10" }, // KF10
    .{ .cap_type = .string, .name = "kf11" }, // KF11
    .{ .cap_type = .string, .name = "kf12" }, // KF12
    .{ .cap_type = .string, .name = "kf13" }, // KF13
    .{ .cap_type = .string, .name = "kf14" }, // KF14
    .{ .cap_type = .string, .name = "kf15" }, // KF15
    .{ .cap_type = .string, .name = "kf16" }, // KF16
    .{ .cap_type = .string, .name = "kf17" }, // KF17
    .{ .cap_type = .string, .name = "kf18" }, // KF18
    .{ .cap_type = .string, .name = "kf19" }, // KF19
    .{ .cap_type = .string, .name = "kf20" }, // KF20
    .{ .cap_type = .string, .name = "kf21" }, // KF21
    .{ .cap_type = .string, .name = "kf22" }, // KF22
    .{ .cap_type = .string, .name = "kf23" }, // KF23
    .{ .cap_type = .string, .name = "kf24" }, // KF24
    .{ .cap_type = .string, .name = "kf25" }, // KF25
    .{ .cap_type = .string, .name = "kf26" }, // KF26
    .{ .cap_type = .string, .name = "kf27" }, // KF27
    .{ .cap_type = .string, .name = "kf28" }, // KF28
    .{ .cap_type = .string, .name = "kf29" }, // KF29
    .{ .cap_type = .string, .name = "kf30" }, // KF30
    .{ .cap_type = .string, .name = "kf31" }, // KF31
    .{ .cap_type = .string, .name = "kf32" }, // KF32
    .{ .cap_type = .string, .name = "kf33" }, // KF33
    .{ .cap_type = .string, .name = "kf34" }, // KF34
    .{ .cap_type = .string, .name = "kf35" }, // KF35
    .{ .cap_type = .string, .name = "kf36" }, // KF36
    .{ .cap_type = .string, .name = "kf37" }, // KF37
    .{ .cap_type = .string, .name = "kf38" }, // KF38
    .{ .cap_type = .string, .name = "kf39" }, // KF39
    .{ .cap_type = .string, .name = "kf40" }, // KF40
    .{ .cap_type = .string, .name = "kf41" }, // KF41
    .{ .cap_type = .string, .name = "kf42" }, // KF42
    .{ .cap_type = .string, .name = "kf43" }, // KF43
    .{ .cap_type = .string, .name = "kf44" }, // KF44
    .{ .cap_type = .string, .name = "kf45" }, // KF45
    .{ .cap_type = .string, .name = "kf46" }, // KF46
    .{ .cap_type = .string, .name = "kf47" }, // KF47
    .{ .cap_type = .string, .name = "kf48" }, // KF48
    .{ .cap_type = .string, .name = "kf49" }, // KF49
    .{ .cap_type = .string, .name = "kf50" }, // KF50
    .{ .cap_type = .string, .name = "kf51" }, // KF51
    .{ .cap_type = .string, .name = "kf52" }, // KF52
    .{ .cap_type = .string, .name = "kf53" }, // KF53
    .{ .cap_type = .string, .name = "kf54" }, // KF54
    .{ .cap_type = .string, .name = "kf55" }, // KF55
    .{ .cap_type = .string, .name = "kf56" }, // KF56
    .{ .cap_type = .string, .name = "kf57" }, // KF57
    .{ .cap_type = .string, .name = "kf58" }, // KF58
    .{ .cap_type = .string, .name = "kf59" }, // KF59
    .{ .cap_type = .string, .name = "kf60" }, // KF60
    .{ .cap_type = .string, .name = "kf61" }, // KF61
    .{ .cap_type = .string, .name = "kf62" }, // KF62
    .{ .cap_type = .string, .name = "kf63" }, // KF63
    .{ .cap_type = .string, .name = "kHOM" }, // KHOM2
    .{ .cap_type = .string, .name = "kHOM3" }, // KHOM3
    .{ .cap_type = .string, .name = "kHOM4" }, // KHOM4
    .{ .cap_type = .string, .name = "kHOM5" }, // KHOM5
    .{ .cap_type = .string, .name = "kHOM6" }, // KHOM6
    .{ .cap_type = .string, .name = "kHOM7" }, // KHOM7
    .{ .cap_type = .string, .name = "khome" }, // KHOME
    .{ .cap_type = .string, .name = "kIC" }, // KIC2
    .{ .cap_type = .string, .name = "kIC3" }, // KIC3
    .{ .cap_type = .string, .name = "kIC4" }, // KIC4
    .{ .cap_type = .string, .name = "kIC5" }, // KIC5
    .{ .cap_type = .string, .name = "kIC6" }, // KIC6
    .{ .cap_type = .string, .name = "kIC7" }, // KIC7
    .{ .cap_type = .string, .name = "kich1" }, // KICH1
    .{ .cap_type = .string, .name = "kind" }, // KIND
    .{ .cap_type = .string, .name = "kLFT" }, // KLFT2
    .{ .cap_type = .string, .name = "kLFT3" }, // KLFT3
    .{ .cap_type = .string, .name = "kLFT4" }, // KLFT4
    .{ .cap_type = .string, .name = "kLFT5" }, // KLFT5
    .{ .cap_type = .string, .name = "kLFT6" }, // KLFT6
    .{ .cap_type = .string, .name = "kLFT7" }, // KLFT7
    .{ .cap_type = .string, .name = "kmous" }, // KMOUS
    .{ .cap_type = .string, .name = "knp" }, // KNP
    .{ .cap_type = .string, .name = "kNXT" }, // KNXT2
    .{ .cap_type = .string, .name = "kNXT3" }, // KNXT3
    .{ .cap_type = .string, .name = "kNXT4" }, // KNXT4
    .{ .cap_type = .string, .name = "kNXT5" }, // KNXT5
    .{ .cap_type = .string, .name = "kNXT6" }, // KNXT6
    .{ .cap_type = .string, .name = "kNXT7" }, // KNXT7
    .{ .cap_type = .string, .name = "kpp" }, // KPP
    .{ .cap_type = .string, .name = "kPRV" }, // KPRV2
    .{ .cap_type = .string, .name = "kPRV3" }, // KPRV3
    .{ .cap_type = .string, .name = "kPRV4" }, // KPRV4
    .{ .cap_type = .string, .name = "kPRV5" }, // KPRV5
    .{ .cap_type = .string, .name = "kPRV6" }, // KPRV6
    .{ .cap_type = .string, .name = "kPRV7" }, // KPRV7
    .{ .cap_type = .string, .name = "kri" }, // KRI
    .{ .cap_type = .string, .name = "kRIT" }, // KRIT2
    .{ .cap_type = .string, .name = "kRIT3" }, // KRIT3
    .{ .cap_type = .string, .name = "kRIT4" }, // KRIT4
    .{ .cap_type = .string, .name = "kRIT5" }, // KRIT5
    .{ .cap_type = .string, .name = "kRIT6" }, // KRIT6
    .{ .cap_type = .string, .name = "kRIT7" }, // KRIT7
    .{ .cap_type = .string, .name = "kUP" }, // KUP2
    .{ .cap_type = .string, .name = "kUP3" }, // KUP3
    .{ .cap_type = .string, .name = "kUP4" }, // KUP4
    .{ .cap_type = .string, .name = "kUP5" }, // KUP5
    .{ .cap_type = .string, .name = "kUP6" }, // KUP6
    .{ .cap_type = .string, .name = "kUP7" }, // KUP7
    .{ .cap_type = .string, .name = "Ms" }, // MS
    .{ .cap_type = .string, .name = "Nobr" }, // NOBR
    .{ .cap_type = .string, .name = "ol" }, // OL
    .{ .cap_type = .string, .name = "op" }, // OP
    .{ .cap_type = .string, .name = "Rect" }, // RECT
    .{ .cap_type = .string, .name = "rev" }, // REV
    .{ .cap_type = .flag, .name = "RGB" }, // RGB
    .{ .cap_type = .string, .name = "ri" }, // RI
    .{ .cap_type = .string, .name = "rin" }, // RIN
    .{ .cap_type = .string, .name = "rmacs" }, // RMACS
    .{ .cap_type = .string, .name = "rmcup" }, // RMCUP
    .{ .cap_type = .string, .name = "rmkx" }, // RMKX
    .{ .cap_type = .string, .name = "Se" }, // SE
    .{ .cap_type = .string, .name = "setab" }, // SETAB
    .{ .cap_type = .string, .name = "setaf" }, // SETAF
    .{ .cap_type = .string, .name = "setal" }, // SETAL
    .{ .cap_type = .string, .name = "setrgbb" }, // SETRGBB
    .{ .cap_type = .string, .name = "setrgbf" }, // SETRGBF
    .{ .cap_type = .string, .name = "Setulc" }, // SETULC
    .{ .cap_type = .string, .name = "Setulc1" }, // SETULC1
    .{ .cap_type = .string, .name = "sgr0" }, // SGR0
    .{ .cap_type = .string, .name = "sitm" }, // SITM
    .{ .cap_type = .string, .name = "smacs" }, // SMACS
    .{ .cap_type = .string, .name = "smcup" }, // SMCUP
    .{ .cap_type = .string, .name = "smkx" }, // SMKX
    .{ .cap_type = .string, .name = "Smol" }, // SMOL
    .{ .cap_type = .string, .name = "smso" }, // SMSO
    .{ .cap_type = .string, .name = "smul" }, // SMUL
    .{ .cap_type = .string, .name = "Smulx" }, // SMULX
    .{ .cap_type = .string, .name = "smxx" }, // SMXX
    .{ .cap_type = .flag, .name = "Sxl" }, // SXL
    .{ .cap_type = .string, .name = "Ss" }, // SS
    .{ .cap_type = .string, .name = "Swd" }, // SWD
    .{ .cap_type = .string, .name = "Sync" }, // SYNC
    .{ .cap_type = .flag, .name = "Tc" }, // TC
    .{ .cap_type = .string, .name = "tsl" }, // TSL
    .{ .cap_type = .number, .name = "U8" }, // U8
    .{ .cap_type = .string, .name = "vpa" }, // VPA
    .{ .cap_type = .flag, .name = "XT" }, // XT
};

// Compile-time validation: code_table length must match TTYC field count.
comptime {
    std.debug.assert(code_table.len == @typeInfo(TTYC).@"enum".fields.len);
}

// ── TtyTerm: per-terminal capability state ────────────────────────────────

pub const TtyTerm = struct {
    codes: []CapabilityValue,
    /// Bitset of terminal feature indices merged into this term (mirrors tmux tty_term.features).
    applied_features: i32 = 0,
    /// TERM_* flags from tty-features.c (256/RGB/DECSLRM/DECFRA/sixel).
    term_flags: i32 = 0,

    pub fn init() TtyTerm {
        const codes = xm.allocator.alloc(CapabilityValue, TTYC.count()) catch unreachable;
        for (codes) |*code| code.* = .none;
        return .{ .codes = codes };
    }

    pub fn deinit(self: *TtyTerm) void {
        for (self.codes) |*val| {
            if (val.* == .string) xm.allocator.free(val.string);
        }
        xm.allocator.free(self.codes);
    }

    /// Load capabilities from recorded name=value cap entries.
    pub fn loadCaps(self: *TtyTerm, caps: [][]u8) void {
        // Clear existing.
        for (self.codes) |*val| {
            if (val.* == .string) xm.allocator.free(val.string);
            val.* = .none;
        }

        for (caps) |cap| {
            const sep = std.mem.indexOfScalar(u8, cap, '=') orelse continue;
            const name = cap[0..sep];
            const value = cap[sep + 1 ..];

            for (code_table, 0..) |entry, idx| {
                if (!std.mem.eql(u8, entry.name, name)) continue;

                switch (entry.cap_type) {
                    .string => {
                        self.codes[idx] = .{ .string = xm.xstrdup(value) };
                    },
                    .number => {
                        const n = std.fmt.parseInt(i32, value, 10) catch continue;
                        self.codes[idx] = .{ .number = n };
                    },
                    .flag => {
                        self.codes[idx] = .{ .flag = std.mem.eql(u8, value, "1") };
                    },
                    .none => {},
                }
                break;
            }
        }
    }

    /// Apply a colon-separated capability override string (tmux tty_term_apply).
    pub fn tty_term_apply(self: *TtyTerm, capabilities: []const u8, quiet: bool) void {
        var offset: usize = 0;
        var chunk_buf: [8192]u8 = undefined;
        while (tty_term_override_next(capabilities, &offset, &chunk_buf)) |chunk| {
            apply_capability_chunk(self, chunk, quiet);
        }
    }

    /// Returns true if the capability is present (not .none).
    pub fn has(self: *const TtyTerm, code: TTYC) bool {
        return self.codes[@intFromEnum(code)] != .none;
    }

    /// Returns the string value for a string capability, or "" if absent.
    pub fn string(self: *const TtyTerm, code: TTYC) []const u8 {
        if (!self.has(code)) return "";
        const val = self.codes[@intFromEnum(code)];
        if (val != .string) return "";
        return val.string;
    }

    /// Returns the numeric value for a number capability, or 0 if absent.
    pub fn number(self: *const TtyTerm, code: TTYC) i32 {
        if (!self.has(code)) return 0;
        const val = self.codes[@intFromEnum(code)];
        if (val != .number) return 0;
        return val.number;
    }

    /// Returns the boolean value for a flag capability, or false if absent.
    pub fn flag(self: *const TtyTerm, code: TTYC) bool {
        if (!self.has(code)) return false;
        const val = self.codes[@intFromEnum(code)];
        if (val != .flag) return false;
        return val.flag;
    }

    /// Look up a capability by string name; returns its enum tag or null.
    pub fn codeByName(name: []const u8) ?TTYC {
        for (code_table, 0..) |entry, idx| {
            if (std.mem.eql(u8, entry.name, name))
                return @as(TTYC, @enumFromInt(idx));
        }
        return null;
    }

    /// Return the code table entry for a given TTYC code.
    pub fn codeEntry(code: TTYC) *const CodeEntry {
        return &code_table[@intFromEnum(code)];
    }

    /// Describe a single capability for logging/display (mirrors tmux tty_term_describe).
    pub fn describe(self: *const TtyTerm, code: TTYC) []u8 {
        const idx = @intFromEnum(code);
        const entry = &code_table[idx];
        const val = self.codes[idx];
        return switch (val) {
            .none => std.fmt.allocPrint(xm.allocator, "{d: >4}: {s}: [missing]", .{ idx, entry.name }) catch unreachable,
            .string => |s| blk: {
                const escaped = escapeCapabilityValue(xm.allocator, s);
                defer xm.allocator.free(escaped);
                break :blk std.fmt.allocPrint(xm.allocator, "{d: >4}: {s}: (string) {s}", .{ idx, entry.name, escaped }) catch unreachable;
            },
            .number => |n| std.fmt.allocPrint(xm.allocator, "{d: >4}: {s}: (number) {d}", .{ idx, entry.name, n }) catch unreachable,
            .flag => |f| std.fmt.allocPrint(xm.allocator, "{d: >4}: {s}: (flag) {s}", .{ idx, entry.name, if (f) "true" else "false" }) catch unreachable,
        };
    }

    /// Get string capability expanded with one integer parameter (tparm).
    pub fn string_i(self: *const TtyTerm, code: TTYC, a: c_int) []const u8 {
        const base = self.string(code);
        if (base.len == 0) return "";
        const base_z = xm.xm_dupeZ(base);
        defer xm.allocator.free(base_z);
        const result = c.ncurses.tparm(base_z.ptr, @as(c_long, a), @as(c_long, 0), @as(c_long, 0), @as(c_long, 0), @as(c_long, 0), @as(c_long, 0), @as(c_long, 0), @as(c_long, 0), @as(c_long, 0));
        if (result == null) {
            log.log_debug("could not expand {s}", .{code_table[@intFromEnum(code)].name});
            return "";
        }
        return std.mem.span(result.?);
    }

    /// Get string capability expanded with two integer parameters (tparm).
    pub fn string_ii(self: *const TtyTerm, code: TTYC, a: c_int, b: c_int) []const u8 {
        const base = self.string(code);
        if (base.len == 0) return "";
        const base_z = xm.xm_dupeZ(base);
        defer xm.allocator.free(base_z);
        const result = c.ncurses.tparm(base_z.ptr, @as(c_long, a), @as(c_long, b), @as(c_long, 0), @as(c_long, 0), @as(c_long, 0), @as(c_long, 0), @as(c_long, 0), @as(c_long, 0), @as(c_long, 0));
        if (result == null) {
            log.log_debug("could not expand {s}", .{code_table[@intFromEnum(code)].name});
            return "";
        }
        return std.mem.span(result.?);
    }

    /// Get string capability expanded with three integer parameters (tparm).
    pub fn string_iii(self: *const TtyTerm, code: TTYC, a: c_int, b: c_int, cc: c_int) []const u8 {
        const base = self.string(code);
        if (base.len == 0) return "";
        const base_z = xm.xm_dupeZ(base);
        defer xm.allocator.free(base_z);
        const result = c.ncurses.tparm(base_z.ptr, @as(c_long, a), @as(c_long, b), @as(c_long, cc), @as(c_long, 0), @as(c_long, 0), @as(c_long, 0), @as(c_long, 0), @as(c_long, 0), @as(c_long, 0));
        if (result == null) {
            log.log_debug("could not expand {s}", .{code_table[@intFromEnum(code)].name});
            return "";
        }
        return std.mem.span(result.?);
    }

    /// Get string capability expanded with one string parameter (tparm).
    pub fn string_s(self: *const TtyTerm, code: TTYC, a: [*:0]const u8) []const u8 {
        const base = self.string(code);
        if (base.len == 0) return "";
        const base_z = xm.xm_dupeZ(base);
        defer xm.allocator.free(base_z);
        const result = c.ncurses.tparm(base_z.ptr, @as(c_long, @intCast(@intFromPtr(a))), @as(c_long, 0), @as(c_long, 0), @as(c_long, 0), @as(c_long, 0), @as(c_long, 0), @as(c_long, 0), @as(c_long, 0), @as(c_long, 0));
        if (result == null) {
            log.log_debug("could not expand {s}", .{code_table[@intFromEnum(code)].name});
            return "";
        }
        return std.mem.span(result.?);
    }

    /// Get string capability expanded with two string parameters (tparm).
    pub fn string_ss(self: *const TtyTerm, code: TTYC, a: [*:0]const u8, b: [*:0]const u8) []const u8 {
        const base = self.string(code);
        if (base.len == 0) return "";
        const base_z = xm.xm_dupeZ(base);
        defer xm.allocator.free(base_z);
        const result = c.ncurses.tparm(base_z.ptr, @as(c_long, @intCast(@intFromPtr(a))), @as(c_long, @intCast(@intFromPtr(b))), @as(c_long, 0), @as(c_long, 0), @as(c_long, 0), @as(c_long, 0), @as(c_long, 0), @as(c_long, 0), @as(c_long, 0));
        if (result == null) {
            log.log_debug("could not expand {s}", .{code_table[@intFromEnum(code)].name});
            return "";
        }
        return std.mem.span(result.?);
    }
};

// ── Standalone API (mirrors tmux C function names) ────────────────────────

const opts = @import("options.zig");
const tty_features = @import("tty-features.zig");
const env_mod = @import("environ.zig");

/// Return the total number of terminal capability codes (mirrors tmux tty_term_ncodes).
pub fn tty_term_ncodes() usize {
    return TTYC.count();
}

/// Strip terminfo padding sequences ($<...>) from a string (mirrors tmux tty_term_strip).
pub fn tty_term_strip(s: []const u8) []u8 {
    if (std.mem.indexOfScalar(u8, s, '$') == null)
        return xm.xstrdup(s);

    var buf: [8192]u8 = undefined;
    var len: usize = 0;
    var ptr: usize = 0;
    while (ptr < s.len) {
        if (s[ptr] == '$' and ptr + 1 < s.len and s[ptr + 1] == '<') {
            while (ptr < s.len and s[ptr] != '>') ptr += 1;
            if (ptr < s.len and s[ptr] == '>') ptr += 1;
            if (ptr >= s.len) break;
        }
        if (len >= buf.len - 1) break;
        buf[len] = s[ptr];
        len += 1;
        ptr += 1;
    }
    return xm.xstrdup(buf[0..len]);
}

/// Create a TtyTerm from a set of capability strings (reduced port of tmux tty_term_create).
/// Populates capability codes, applies terminal features and overrides, and
/// validates that required capabilities (clear, cup) are present.
pub fn tty_term_create(
    name: []const u8,
    caps: [][]u8,
    feat: *i32,
    cause: *?[]u8,
) ?*TtyTerm {
    log.log_debug("adding term {s}", .{name});

    const term = xm.allocator.create(TtyTerm) catch unreachable;
    term.* = TtyTerm.init();

    for (caps) |cap| {
        const sep = std.mem.indexOfScalar(u8, cap, '=') orelse continue;
        const cap_name = cap[0..sep];
        const value = cap[sep + 1 ..];

        for (code_table, 0..) |entry, idx| {
            if (!nameMatch(entry.name, cap_name)) continue;

            switch (entry.cap_type) {
                .none => {},
                .string => {
                    const stripped = tty_term_strip(value);
                    if (term.codes[idx] == .string) xm.allocator.free(term.codes[idx].string);
                    term.codes[idx] = .{ .string = stripped };
                },
                .number => {
                    const n = std.fmt.parseInt(i32, value, 10) catch {
                        log.log_debug("{s}: invalid number", .{entry.name});
                        continue;
                    };
                    term.codes[idx] = .{ .number = n };
                },
                .flag => {
                    term.codes[idx] = .{ .flag = value.len > 0 and value[0] == '1' };
                },
            }
            break;
        }
    }

    // Apply terminal features from the terminal-features option.
    if (opts.options_get_only(opts.global_options, "terminal-features")) |o| {
        if (opts.options_array_first(o)) |first_item| {
            var item: ?*const T.OptionsArrayItem = first_item;
            while (item) |a| {
                const s = opts.options_array_item_value(a);
                var offset: usize = 0;
                var chunk_buf: [8192]u8 = undefined;
                if (tty_term_override_next(s, &offset, &chunk_buf)) |first| {
                    if (fnmatchSlice(first, name))
                        tty_features.tty_add_features(feat, s[offset..], ":");
                }
                item = opts.options_array_next(o, a);
            }
        }
    }

    // Apply overrides.
    tty_term_apply_overrides(term, name);

    // Validate required capabilities.
    if (!term.has(.CLEAR)) {
        cause.* = xm.xstrdup("terminal does not support clear");
        tty_term_free(term);
        return null;
    }
    if (!term.has(.CUP)) {
        cause.* = xm.xstrdup("terminal does not support cup");
        tty_term_free(term);
        return null;
    }

    // VT100-like detection.
    const clear_str = term.string(.CLEAR);
    if (term.flag(.XT) or (clear_str.len >= 2 and clear_str[0] == '\x1b' and clear_str[1] == '[')) {
        term.term_flags |= TERM_VT100LIKE;
        tty_features.tty_add_features(feat, "bpaste,focus,title", ",");
    }

    // Add RGB feature if terminal advertises truecolor.
    if ((term.flag(.TC) or term.has(.RGB)) and (!term.has(.SETRGBF) or !term.has(.SETRGBB)))
        tty_features.tty_add_features(feat, "RGB", ",");

    // Apply the features and overrides again.
    if (tty_features.tty_apply_features(term, feat.*) != 0)
        tty_term_apply_overrides(term, name);

    // Log capabilities.
    for (0..TTYC.count()) |i| {
        const desc = term.describe(@enumFromInt(i));
        defer xm.allocator.free(desc);
        log.log_debug("{s}{s}", .{ name, desc });
    }

    return term;
}

/// Free a TtyTerm and all its resources (mirrors tmux tty_term_free).
pub fn tty_term_free(term: *TtyTerm) void {
    log.log_debug("removing term", .{});
    term.deinit();
    xm.allocator.destroy(term);
}

/// Apply terminal-overrides option entries to a TtyTerm (mirrors tmux tty_term_apply_overrides).
pub fn tty_term_apply_overrides(term: *TtyTerm, name: []const u8) void {
    if (opts.options_get_only(opts.global_options, "terminal-overrides")) |o| {
        if (opts.options_array_first(o)) |first_item| {
            var item: ?*const T.OptionsArrayItem = first_item;
            while (item) |a| {
                const s = opts.options_array_item_value(a);
                var offset: usize = 0;
                var chunk_buf: [8192]u8 = undefined;
                if (tty_term_override_next(s, &offset, &chunk_buf)) |first| {
                    if (fnmatchSlice(first, name))
                        term.tty_term_apply(s[offset..], false);
                }
                item = opts.options_array_next(o, a);
            }
        }
    }

    // Update RGB flag.
    if (term.has(.SETRGBF) and term.has(.SETRGBB))
        term.term_flags |= tty_features.TERM_RGBCOLOURS
    else
        term.term_flags &= ~tty_features.TERM_RGBCOLOURS;
    log.log_debug("RGBCOLOURS flag is {d}", .{@as(i32, if (term.term_flags & tty_features.TERM_RGBCOLOURS != 0) 1 else 0)});

    // Update DECSLRM flag.
    if (term.has(.CMG) and term.has(.CLMG))
        term.term_flags |= tty_features.TERM_DECSLRM
    else
        term.term_flags &= ~tty_features.TERM_DECSLRM;
    log.log_debug("DECSLRM flag is {d}", .{@as(i32, if (term.term_flags & tty_features.TERM_DECSLRM != 0) 1 else 0)});

    // Update DECFRA flag.
    if (term.has(.RECT))
        term.term_flags |= tty_features.TERM_DECFRA
    else
        term.term_flags &= ~tty_features.TERM_DECFRA;
    log.log_debug("DECFRA flag is {d}", .{@as(i32, if (term.term_flags & tty_features.TERM_DECFRA != 0) 1 else 0)});

    // Update NOAM flag.
    if (!term.flag(.AM))
        term.term_flags |= TERM_NOAM
    else
        term.term_flags &= ~TERM_NOAM;
    log.log_debug("NOAM flag is {d}", .{@as(i32, if (term.term_flags & TERM_NOAM != 0) 1 else 0)});
}

/// Standalone tty_term_has (delegates to TtyTerm method).
pub fn tty_term_has(term: *const TtyTerm, code: TTYC) bool {
    return term.has(code);
}

/// Standalone tty_term_string (delegates to TtyTerm method).
pub fn tty_term_string(term: *const TtyTerm, code: TTYC) []const u8 {
    return term.string(code);
}

/// Standalone tty_term_string_i (delegates to TtyTerm method).
pub fn tty_term_string_i(term: *const TtyTerm, code: TTYC, a: c_int) []const u8 {
    return term.string_i(code, a);
}

/// Standalone tty_term_string_ii (delegates to TtyTerm method).
pub fn tty_term_string_ii(term: *const TtyTerm, code: TTYC, a: c_int, b: c_int) []const u8 {
    return term.string_ii(code, a, b);
}

/// Standalone tty_term_string_iii (delegates to TtyTerm method).
pub fn tty_term_string_iii(term: *const TtyTerm, code: TTYC, a: c_int, b: c_int, cc: c_int) []const u8 {
    return term.string_iii(code, a, b, cc);
}

/// Standalone tty_term_string_s (delegates to TtyTerm method).
pub fn tty_term_string_s(term: *const TtyTerm, code: TTYC, a: [*:0]const u8) []const u8 {
    return term.string_s(code, a);
}

/// Standalone tty_term_string_ss (delegates to TtyTerm method).
pub fn tty_term_string_ss(term: *const TtyTerm, code: TTYC, a: [*:0]const u8, b: [*:0]const u8) []const u8 {
    return term.string_ss(code, a, b);
}

/// Standalone tty_term_number (delegates to TtyTerm method).
pub fn tty_term_number(term: *const TtyTerm, code: TTYC) i32 {
    return term.number(code);
}

/// Standalone tty_term_flag (delegates to TtyTerm method).
pub fn tty_term_flag(term: *const TtyTerm, code: TTYC) bool {
    return term.flag(code);
}

/// Standalone tty_term_describe (delegates to TtyTerm method).
pub fn tty_term_describe(term: *const TtyTerm, code: TTYC) []u8 {
    return term.describe(code);
}

/// Standalone tty_term_read_list (delegates to readTermCaps).
pub fn tty_term_read_list(term_name: []const u8, fd: i32) ![][]u8 {
    return readTermCaps(term_name, fd);
}

/// Standalone tty_term_free_list (delegates to freeTermCaps).
pub fn tty_term_free_list(caps: [][]u8) void {
    freeTermCaps(caps);
}

// Term flags not in tty-features.zig (local to tty-term).
const TERM_VT100LIKE: i32 = 0x20;
const TERM_NOAM: i32 = 0x80;

/// Shell-glob match on Zig slices using C fnmatch.
fn fnmatchSlice(pattern: []const u8, text: []const u8) bool {
    const pattern_z = xm.xm_dupeZ(pattern);
    defer xm.allocator.free(pattern_z);
    const text_z = xm.xm_dupeZ(text);
    defer xm.allocator.free(text_z);
    return c.posix_sys.fnmatch(pattern_z.ptr, text_z.ptr, 0) == 0;
}

/// Case-sensitive name match for capability lookup.
fn nameMatch(entry_name: []const u8, cap_name: []const u8) bool {
    return std.mem.eql(u8, entry_name, cap_name);
}

// ── Full terminfo read (ncurses-backed) ───────────────────────────────────

/// Read all capabilities from terminfo for the given terminal name.
pub fn readTermCaps(term_name: []const u8, fd: i32) ![][]u8 {
    const term_z = xm.xm_dupeZ(term_name);
    defer xm.allocator.free(term_z);

    var err: c_int = 0;
    if (c.ncurses.setupterm(term_z.ptr, fd, &err) != c.ncurses.OK)
        return xm.allocator.alloc([]u8, 0);
    defer {
        if (@hasDecl(c.ncurses, "del_curterm") and @hasDecl(c.ncurses, "cur_term")) {
            if (c.ncurses.cur_term != null)
                _ = c.ncurses.del_curterm(c.ncurses.cur_term);
        }
    }

    var caps: std.ArrayList([]u8) = .{};
    errdefer {
        for (caps.items) |cap| xm.allocator.free(cap);
        caps.deinit(xm.allocator);
    }

    for (code_table) |entry| {
        const value = switch (entry.cap_type) {
            .string => readStringCapability(entry.name),
            .number => readNumberCapability(entry.name),
            .flag => readFlagCapability(entry.name),
            .none => null,
        } orelse continue;

        const cap_entry = try std.fmt.allocPrint(xm.allocator, "{s}={s}", .{ entry.name, value });
        try caps.append(xm.allocator, cap_entry);
        if (entry.cap_type != .string)
            xm.allocator.free(value);
    }

    return caps.toOwnedSlice(xm.allocator);
}

pub fn freeTermCaps(caps: [][]u8) void {
    for (caps) |cap| xm.allocator.free(cap);
    xm.allocator.free(caps);
}

// ── Tty-based string/number/flag lookups (backward-compatible API) ────────
//
// These functions operate on the Tty.client's recorded term_caps and
// feature-fallback strings. They are the primary interface used by tty.zig.

pub fn hasCapability(tty: *const T.Tty, name: []const u8) bool {
    return capabilityValue(tty.client, name) != null or tty_features.hasCapability(tty.client, name);
}

pub fn stringCapability(tty: *const T.Tty, name: []const u8) ?[]const u8 {
    return capabilityValue(tty.client, name) orelse tty_features.stringCapability(tty.client, name);
}

pub fn numberCapability(tty: *const T.Tty, name: []const u8) ?i32 {
    const value = capabilityValue(tty.client, name) orelse tty_features.stringCapability(tty.client, name) orelse return null;
    return std.fmt.parseInt(i32, value, 10) catch null;
}

pub fn acsCapability(tty: *const T.Tty, ch: u8) ?[]const u8 {
    const mapping = stringCapability(tty, "acsc") orelse return null;

    var idx: usize = 0;
    while (idx + 1 < mapping.len) : (idx += 2) {
        if (mapping[idx] != ch) continue;
        return mapping[idx + 1 .. idx + 2];
    }
    return null;
}

/// Return true when the tty's terminal looks VT100-like.
/// Mirrors the detection criterion in tty_term_create: either the `xt`
/// (xterm) capability flag is set, or the `clear` capability string starts
/// with ESC [ (CSI), which is the classic VT100 indicator.
pub fn isVt100Like(tty: *const T.Tty) bool {
    // xt (xterm-compatible) flag: implies VT100-compatible escape sequences.
    const xt = capabilityValue(tty.client, "xt");
    if (xt != null) return true;
    // Inspect the `clear` capability: VT100 clear begins with ESC [.
    const clear = stringCapability(tty, "clear") orelse return false;
    return clear.len >= 2 and clear[0] == '\x1b' and clear[1] == '[';
}

// ── Capability description (for show-messages) ────────────────────────────

pub fn describeRecordedCapability(alloc: std.mem.Allocator, ordinal: usize, cap: []const u8) []u8 {
    const sep = std.mem.indexOfScalar(u8, cap, '=') orelse {
        return std.fmt.allocPrint(alloc, "{d: >4}: {s}: [invalid]", .{ ordinal, cap }) catch unreachable;
    };
    const name = cap[0..sep];
    const value = cap[sep + 1 ..];
    const kind = capabilityKind(name) orelse .string;
    return switch (kind) {
        .number => std.fmt.allocPrint(alloc, "{d: >4}: {s}: (number) {s}", .{ ordinal, name, value }) catch unreachable,
        .flag => std.fmt.allocPrint(alloc, "{d: >4}: {s}: (flag) {s}", .{ ordinal, name, value }) catch unreachable,
        .string => blk: {
            const escaped = escapeCapabilityValue(alloc, value);
            defer alloc.free(escaped);
            break :blk std.fmt.allocPrint(alloc, "{d: >4}: {s}: (string) {s}", .{ ordinal, name, escaped }) catch unreachable;
        },
        .none => std.fmt.allocPrint(alloc, "{d: >4}: {s}: {s}", .{ ordinal, name, value }) catch unreachable,
    };
}

// ── Capability name to TTYC enum lookup ───────────────────────────────────

pub fn lookupCode(name: []const u8) ?TTYC {
    return TtyTerm.codeByName(name);
}

// ── Internal helpers ──────────────────────────────────────────────────────

fn capabilityNameForTable(raw: []const u8) []const u8 {
    if (std.mem.startsWith(u8, raw, "*:")) return raw[2..];
    return raw;
}

/// Next colon-separated field; `::` is a literal colon (tmux tty_term_override_next).
fn tty_term_override_next(s: []const u8, offset: *usize, out: *[8192]u8) ?[]const u8 {
    var at = offset.*;
    if (at >= s.len) return null;
    var n: usize = 0;
    while (at < s.len) {
        if (s[at] == ':') {
            if (at + 1 < s.len and s[at + 1] == ':') {
                if (n >= out.len - 1) return null;
                out[n] = ':';
                n += 1;
                at += 2;
            } else break;
        } else {
            if (n >= out.len - 1) return null;
            out[n] = s[at];
            n += 1;
            at += 1;
        }
    }
    if (at < s.len and s[at] == ':') at += 1;
    offset.* = at;
    return out[0..n];
}

fn apply_capability_chunk(term: *TtyTerm, chunk: []const u8, quiet: bool) void {
    if (chunk.len == 0) return;

    var remove = false;
    var name_part: []const u8 = chunk;
    var value_slice: []const u8 = "";

    if (std.mem.indexOfScalar(u8, chunk, '=')) |eq| {
        name_part = chunk[0..eq];
        value_slice = chunk[eq + 1 ..];
    } else if (chunk.len >= 1 and chunk[chunk.len - 1] == '@') {
        name_part = chunk[0 .. chunk.len - 1];
        remove = true;
    }

    const lookup_name = capabilityNameForTable(name_part);
    const code = TtyTerm.codeByName(lookup_name) orelse return;
    const entry = TtyTerm.codeEntry(code);
    const idx = @intFromEnum(code);

    if (!quiet) {
        if (remove) {
            log.log_debug("override: {s}@", .{lookup_name});
        } else if (value_slice.len == 0 and entry.cap_type == .flag) {
            log.log_debug("override: {s}", .{lookup_name});
        } else {
            log.log_debug("override: {s}={s}", .{ lookup_name, value_slice });
        }
    }

    if (remove) {
        if (term.codes[idx] == .string) xm.allocator.free(term.codes[idx].string);
        term.codes[idx] = .none;
        return;
    }

    switch (entry.cap_type) {
        .none => {},
        .string => {
            const owned = xm.xstrdup(value_slice);
            if (term.codes[idx] == .string) xm.allocator.free(term.codes[idx].string);
            term.codes[idx] = .{ .string = owned };
        },
        .number => {
            const n = std.fmt.parseInt(i32, value_slice, 10) catch return;
            if (term.codes[idx] == .string) xm.allocator.free(term.codes[idx].string);
            term.codes[idx] = .{ .number = n };
        },
        .flag => {
            if (term.codes[idx] == .string) xm.allocator.free(term.codes[idx].string);
            term.codes[idx] = .{ .flag = true };
        },
    }
}

fn capabilityValue(cl: *const T.Client, name: []const u8) ?[]const u8 {
    const caps = cl.term_caps orelse return null;
    for (caps) |cap| {
        if (!std.mem.startsWith(u8, cap, name)) continue;
        if (cap.len <= name.len or cap[name.len] != '=') continue;
        return cap[name.len + 1 ..];
    }
    return null;
}

fn capabilityKind(name: []const u8) ?CapabilityType {
    for (code_table) |entry| {
        if (std.mem.eql(u8, entry.name, name)) return entry.cap_type;
    }
    return null;
}

fn escapeCapabilityValue(alloc: std.mem.Allocator, value: []const u8) []u8 {
    var out: std.ArrayList(u8) = .{};
    errdefer out.deinit(alloc);

    for (value) |ch| {
        switch (ch) {
            '\n' => out.appendSlice(alloc, "\\n") catch unreachable,
            '\r' => out.appendSlice(alloc, "\\r") catch unreachable,
            '\t' => out.appendSlice(alloc, "\\t") catch unreachable,
            '\\' => out.appendSlice(alloc, "\\\\") catch unreachable,
            '"' => out.appendSlice(alloc, "\\\"") catch unreachable,
            else => {
                if (ch >= 0x20 and ch <= 0x7e)
                    out.append(alloc, ch) catch unreachable
                else
                    out.writer(alloc).print("\\x{X:0>2}", .{ch}) catch unreachable;
            },
        }
    }

    return out.toOwnedSlice(alloc) catch unreachable;
}

fn readStringCapability(name: []const u8) ?[]const u8 {
    const name_z = xm.xm_dupeZ(name);
    defer xm.allocator.free(name_z);

    const raw = c.ncurses.tigetstr(name_z.ptr);
    if (raw == null) return null;
    if (@intFromPtr(raw.?) == std.math.maxInt(usize)) return null;
    return xm.xstrdup(std.mem.span(raw.?));
}

fn readNumberCapability(name: []const u8) ?[]u8 {
    const name_z = xm.xm_dupeZ(name);
    defer xm.allocator.free(name_z);

    const value = c.ncurses.tigetnum(name_z.ptr);
    if (value == -1 or value == -2) return null;
    return xm.xasprintf("{d}", .{value});
}

fn readFlagCapability(name: []const u8) ?[]u8 {
    const name_z = xm.xm_dupeZ(name);
    defer xm.allocator.free(name_z);

    const value = c.ncurses.tigetflag(name_z.ptr);
    if (value != 1) return null;
    return xm.xstrdup("1");
}

// ── Tests ─────────────────────────────────────────────────────────────────

test "tty_term TTYC enum and code table are in sync" {
    try std.testing.expectEqual(@as(usize, code_table.len), TTYC.count());
    // Spot-check a few entries.
    try std.testing.expectEqualStrings("acsc", code_table[@intFromEnum(TTYC.ACSC)].name);
    try std.testing.expectEqual(.string, code_table[@intFromEnum(TTYC.ACSC)].cap_type);
    try std.testing.expectEqualStrings("am", code_table[@intFromEnum(TTYC.AM)].name);
    try std.testing.expectEqual(.flag, code_table[@intFromEnum(TTYC.AM)].cap_type);
    try std.testing.expectEqualStrings("colors", code_table[@intFromEnum(TTYC.COLORS)].name);
    try std.testing.expectEqual(.number, code_table[@intFromEnum(TTYC.COLORS)].cap_type);
    try std.testing.expectEqualStrings("XT", code_table[@intFromEnum(TTYC.XT)].name);
    try std.testing.expectEqual(.flag, code_table[@intFromEnum(TTYC.XT)].cap_type);
}

test "tty_term parses numeric, string, and ACS capabilities from reduced terminfo state" {
    var caps = [_][]u8{
        @constCast("U8=0"),
        @constCast("acsc=qx"),
        @constCast("tsl=\x1b]0;"),
        @constCast("fsl=\x07"),
    };
    var client = T.Client{
        .environ = undefined,
        .tty = undefined,
        .status = .{},
        .term_caps = caps[0..],
    };
    client.tty = .{ .client = &client };

    try std.testing.expectEqual(@as(i32, 0), numberCapability(&client.tty, "U8").?);
    try std.testing.expectEqualStrings("\x1b]0;", stringCapability(&client.tty, "tsl").?);
    try std.testing.expectEqualStrings("x", acsCapability(&client.tty, 'q').?);
    try std.testing.expect(hasCapability(&client.tty, "fsl"));
    try std.testing.expect(!hasCapability(&client.tty, "kmous"));
}

test "tty_term describes recorded reduced capabilities" {
    const number_line = describeRecordedCapability(std.testing.allocator, 0, "U8=1");
    defer std.testing.allocator.free(number_line);
    try std.testing.expectEqualStrings("   0: U8: (number) 1", number_line);

    const flag_line = describeRecordedCapability(std.testing.allocator, 1, "AX=1");
    defer std.testing.allocator.free(flag_line);
    try std.testing.expectEqualStrings("   1: AX: (flag) 1", flag_line);

    const string_line = describeRecordedCapability(std.testing.allocator, 4, "kmous=\x1b[M");
    defer std.testing.allocator.free(string_line);
    try std.testing.expectEqualStrings("   4: kmous: (string) \\x1B[M", string_line);
}

test "tty_term falls back to feature-provided capability strings" {
    var client = T.Client{
        .environ = undefined,
        .tty = undefined,
        .status = .{},
        .term_features = tty_features.featureBit(.title) | tty_features.featureBit(.clipboard),
    };
    client.tty = .{ .client = &client };

    try std.testing.expect(hasCapability(&client.tty, "Ms"));
    try std.testing.expectEqualStrings("\x1b]0;", stringCapability(&client.tty, "tsl").?);
    try std.testing.expectEqualStrings("\x1b]52;%p1%s;%p2%s\x07", stringCapability(&client.tty, "Ms").?);
}

test "tty_term TtyTerm loads caps and provides typed lookups" {
    var term = TtyTerm.init();
    defer term.deinit();

    var caps = [_][]u8{
        @constCast("U8=1"),
        @constCast("colors=256"),
        @constCast("AX=1"),
        @constCast("clear=\x1b[H\x1b[J"),
        @constCast("cup=\x1b[%i%p1%d;%p2%dH"),
        @constCast("tsl=\x1b]0;"),
        @constCast("fsl=\x07"),
        @constCast("XT=1"),
    };
    term.loadCaps(caps[0..]);

    // Number capability
    try std.testing.expect(term.has(.U8));
    try std.testing.expectEqual(@as(i32, 1), term.number(.U8));
    try std.testing.expect(term.has(.COLORS));
    try std.testing.expectEqual(@as(i32, 256), term.number(.COLORS));

    // String capability
    try std.testing.expect(term.has(.CLEAR));
    try std.testing.expectEqualStrings("\x1b[H\x1b[J", term.string(.CLEAR));
    try std.testing.expect(term.has(.TSL));
    try std.testing.expectEqualStrings("\x1b]0;", term.string(.TSL));

    // Flag capability
    try std.testing.expect(term.has(.AX));
    try std.testing.expect(term.flag(.AX));
    try std.testing.expect(term.has(.XT));
    try std.testing.expect(term.flag(.XT));

    // Missing capability
    try std.testing.expect(!term.has(.BIDI));
    try std.testing.expectEqualStrings("", term.string(.BIDI));
    try std.testing.expectEqual(@as(i32, 0), term.number(@as(TTYC, @enumFromInt(@intFromEnum(TTYC.COLORS) + 1))));
}

test "tty_term TtyTerm codeByName resolves names to TTYC enum" {
    try std.testing.expectEqual(TTYC.ACSC, TtyTerm.codeByName("acsc"));
    try std.testing.expectEqual(TTYC.KMOUS, TtyTerm.codeByName("kmous"));
    try std.testing.expectEqual(TTYC.COLORS, TtyTerm.codeByName("colors"));
    try std.testing.expectEqual(TTYC.XT, TtyTerm.codeByName("XT"));
    try std.testing.expectEqual(TTYC.SETRGBF, TtyTerm.codeByName("setrgbf"));
    try std.testing.expect(TtyTerm.codeByName("nonexistent") == null);
}

test "tty_term lookupCode public wrapper works" {
    try std.testing.expectEqual(TTYC.CUP, lookupCode("cup"));
    try std.testing.expectEqual(TTYC.SMULX, lookupCode("Smulx"));
    try std.testing.expect(lookupCode("zzz") == null);
}

test "tty_term capabilityKind resolves via full code table" {
    try std.testing.expectEqual(CapabilityType.string, capabilityKind("acsc"));
    try std.testing.expectEqual(CapabilityType.number, capabilityKind("colors"));
    try std.testing.expectEqual(CapabilityType.flag, capabilityKind("XT"));
    try std.testing.expectEqual(CapabilityType.string, capabilityKind("cup"));
    try std.testing.expectEqual(CapabilityType.string, capabilityKind("setab"));
    try std.testing.expectEqual(CapabilityType.flag, capabilityKind("RGB"));
    try std.testing.expectEqual(CapabilityType.flag, capabilityKind("Tc"));
    try std.testing.expect(capabilityKind("nonexistent") == null);
}

test "tty_term TtyTerm loadCaps replaces previous values" {
    var term = TtyTerm.init();
    defer term.deinit();

    var caps1 = [_][]u8{@constCast("colors=16")};
    term.loadCaps(caps1[0..]);
    try std.testing.expectEqual(@as(i32, 16), term.number(.COLORS));

    var caps2 = [_][]u8{@constCast("colors=256")};
    term.loadCaps(caps2[0..]);
    try std.testing.expectEqual(@as(i32, 256), term.number(.COLORS));
}
