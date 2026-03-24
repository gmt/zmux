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
// Ported from tmux/tmux.h (type definitions only)
// Original copyright:
//   Copyright (c) 2007 Nicholas Marriott <nicholas.marriott@gmail.com>
//   ISC licence – same terms as above.

//! types.zig – central type definitions for zmux, mirroring tmux.h.
//!
//! All core struct and enum types live here to avoid circular module imports.
//! Implementation files (session.zig, window.zig, etc.) @import("types.zig")
//! and provide the functions that operate on these types.

const std = @import("std");
const c = @import("c.zig");
pub const protocol = @import("zmux-protocol.zig");

// ── Build constants ────────────────────────────────────────────────────────
const build_options = @import("build_options");

pub const ZMUX_VERSION: []const u8 = build_options.version;
pub const ZMUX_CONF: []const u8 = build_options.zmux_conf;
pub const ZMUX_SOCK: []const u8 = build_options.zmux_sock;
pub const ZMUX_TERM: []const u8 = build_options.zmux_term;
pub const ZMUX_LOCK_CMD: []const u8 = build_options.zmux_lock_cmd;

pub const PANE_MINIMUM: u32 = 1;
pub const WINDOW_MINIMUM: u32 = PANE_MINIMUM;
pub const WINDOW_MAXIMUM: u32 = 10000;
pub const NAME_INTERVAL: u64 = 500_000; // microseconds
pub const DEFAULT_XPIXEL: u32 = 16;
pub const DEFAULT_YPIXEL: u32 = 32;
pub const UTF8_SIZE: usize = 32;
pub const TTY_NAME_MAX: usize = 64;
pub const STATUS_LINES_LIMIT: u32 = 5;

// ── Key codes ─────────────────────────────────────────────────────────────

pub const key_code = u64;

pub const KEYC_NONE: key_code = 0x000ff000000000;
pub const KEYC_UNKNOWN: key_code = 0x000fe000000000;
pub const KEYC_BASE: key_code = 0x0000000010e000;
pub const KEYC_USER: key_code = 0x0000000010f000;
pub const KEYC_NUSER: u32 = 1000;

pub const KEYC_META: key_code = 0x00100000000000;
pub const KEYC_CTRL: key_code = 0x00200000000000;
pub const KEYC_SHIFT: key_code = 0x00400000000000;

pub const KEYC_MASK_MODIFIERS: key_code = 0x00f00000000000;
pub const KEYC_MASK_FLAGS: key_code = 0xff000000000000;
pub const KEYC_MASK_KEY: key_code = 0x000fffffffffff;

pub const MODEKEY_EMACS: u32 = 0;
pub const MODEKEY_VI: u32 = 1;

// ── UTF-8 ─────────────────────────────────────────────────────────────────

pub const utf8_char = u32;

pub const Utf8Data = extern struct {
    data: [UTF8_SIZE]u8,
    have: u8,
    size: u8,
    width: u8, // 0xff if invalid
};

pub const Utf8State = enum(u32) {
    more,
    done,
    @"error",
};

// ── Colour / attributes ───────────────────────────────────────────────────

pub const COLOUR_FLAG_256: u32 = 0x01000000;
pub const COLOUR_FLAG_RGB: u32 = 0x02000000;

pub const ColourPalette = struct {
    fg: i32 = 8,
    bg: i32 = 8,
    palette: ?[]i32 = null,
    default_palette: ?[]i32 = null,
};

pub const GRID_ATTR_BRIGHT: u16 = 0x0001;
pub const GRID_ATTR_DIM: u16 = 0x0002;
pub const GRID_ATTR_UNDERSCORE: u16 = 0x0004;
pub const GRID_ATTR_BLINK: u16 = 0x0008;
pub const GRID_ATTR_REVERSE: u16 = 0x0010;
pub const GRID_ATTR_HIDDEN: u16 = 0x0020;
pub const GRID_ATTR_ITALICS: u16 = 0x0040;
pub const GRID_ATTR_CHARSET: u16 = 0x0080;
pub const GRID_ATTR_STRIKETHROUGH: u16 = 0x0100;
pub const GRID_ATTR_NOATTR: u16 = 0x4000;

pub const GRID_FLAG_FG256: u8 = 0x01;
pub const GRID_FLAG_BG256: u8 = 0x02;
pub const GRID_FLAG_PADDING: u8 = 0x04;
pub const GRID_FLAG_EXTENDED: u8 = 0x08;
pub const GRID_FLAG_SELECTED: u8 = 0x10;
pub const GRID_FLAG_NOPALETTE: u8 = 0x20;
pub const GRID_FLAG_CLEARED: u8 = 0x40;
pub const GRID_FLAG_TAB: u8 = 0x80;

// ── Grid cell ─────────────────────────────────────────────────────────────

pub const GridCell = extern struct {
    data: Utf8Data,
    attr: u16,
    flags: u8,
    fg: i32,
    bg: i32,
    us: i32, // underline colour
    link: u32,
};

pub const GridExtdEntry = extern struct {
    data: utf8_char,
    attr: u16,
    flags: u8,
    fg: i32,
    bg: i32,
    us: i32,
    link: u32,
};

/// Compact inline cell entry – fits common ASCII case in 5 bytes.
pub const GridCellEntryData = packed struct {
    attr: u8,
    fg: u8,
    bg: u8,
    data: u8,
};
pub const GridCellEntry = extern struct {
    offset_or_data: extern union {
        offset: u32,
        data: GridCellEntryData,
    },
    flags: u8,
};

pub const GridLine = struct {
    celldata: []GridCellEntry = &.{},
    cellused: u32 = 0,
    extddata: []GridExtdEntry = &.{},
    flags: i32 = 0,
    time: i64 = 0,
};

pub const Grid = struct {
    flags: i32 = 0,
    sx: u32,
    sy: u32,
    hscrolled: u32 = 0,
    hsize: u32 = 0,
    hlimit: u32 = 2000,
    linedata: []GridLine,
};

pub const GridReader = struct {
    gd: *Grid,
    cx: u32 = 0,
    cy: u32 = 0,
};

// ── Style ─────────────────────────────────────────────────────────────────

pub const StyleAlign = enum {
    default,
    left,
    centre,
    right,
    absolute_centre,
};

pub const StyleList = enum {
    off,
    on,
    focus,
    left_marker,
    right_marker,
};

pub const StyleRangeType = enum {
    none,
    left,
    right,
    pane,
    window,
    session,
    user,
};

pub const Style = struct {
    gc: GridCell = std.mem.zeroes(GridCell),
    ignore: bool = false,
    fill: i32 = 8,
    @"align": StyleAlign = .default,
    list: StyleList = .off,
    range_type: StyleRangeType = .none,
    range_argument: u32 = 0,
    range_string: [16]u8 = std.mem.zeroes([16]u8),
    width: i32 = -1,
    width_percentage: i32 = 0,
    pad: i32 = -1,
};

// ── Screen ────────────────────────────────────────────────────────────────

pub const ScreenCursorStyle = enum {
    default,
    block,
    underline,
    bar,
};

pub const Screen = struct {
    title: ?[]u8 = null,
    path: ?[]u8 = null,
    grid: *Grid,
    cx: u32 = 0,
    cy: u32 = 0,
    cstyle: ScreenCursorStyle = .default,
    default_cstyle: ScreenCursorStyle = .default,
    ccolour: i32 = -1,
    default_ccolour: i32 = -1,
    rupper: u32 = 0,
    rlower: u32 = 0,
    mode: i32 = 0,
    default_mode: i32 = 0,
    saved_cx: u32 = 0,
    saved_cy: u32 = 0,
    saved_grid: ?*Grid = null,
    saved_cell: GridCell = std.mem.zeroes(GridCell),
    saved_flags: i32 = 0,
    tabs: ?[]u8 = null,
};

// ── Terminal ──────────────────────────────────────────────────────────────

pub const TTY_NOCURSOR: u32 = 0x0001;
pub const TTY_FREEZE: u32 = 0x0002;
pub const TTY_STARTED: u32 = 0x0010;
pub const TTY_OPENED: u32 = 0x0020;
pub const TTY_BLOCK: u32 = 0x0080;

pub const Tty = struct {
    client: *Client,
    sx: u32 = 80,
    sy: u32 = 24,
    xpixel: u32 = DEFAULT_XPIXEL,
    ypixel: u32 = DEFAULT_YPIXEL,
    cx: u32 = 0,
    cy: u32 = 0,
    cstyle: ScreenCursorStyle = .default,
    ccolour: i32 = -1,
    mode: i32 = 0,
    fg: i32 = 8,
    bg: i32 = 8,
    flags: i32 = 0,
    ttyname: ?[]u8 = null,
    term_name: ?[]u8 = null,
};

// ── Layout ────────────────────────────────────────────────────────────────

pub const LayoutType = enum {
    leftright,
    topbottom,
    windowpane,
};

pub const LayoutCell = struct {
    @"type": LayoutType = .windowpane,
    parent: ?*LayoutCell = null,
    sx: u32 = 0,
    sy: u32 = 0,
    xoff: u32 = 0,
    yoff: u32 = 0,
    wp: ?*WindowPane = null,
    cells: std.ArrayList(*LayoutCell) = .{},
};

// ── WindowPane ────────────────────────────────────────────────────────────

pub const PANE_REDRAW: u32 = 0x0001;
pub const PANE_FOCUSED: u32 = 0x0004;
pub const PANE_EXITED: u32 = 0x0100;
pub const PANE_EMPTY: u32 = 0x0800;

pub const WindowPane = struct {
    id: u32,
    active_point: u32 = 0,

    window: *Window,
    options: *Options,

    layout_cell: ?*LayoutCell = null,
    saved_layout_cell: ?*LayoutCell = null,

    sx: u32,
    sy: u32,
    xoff: u32 = 0,
    yoff: u32 = 0,

    flags: u32 = 0,

    // PTY
    argv: ?[][]u8 = null,
    shell: ?[]u8 = null,
    cwd: ?[]u8 = null,
    pid: std.posix.pid_t = -1,
    tty_name: [TTY_NAME_MAX]u8 = std.mem.zeroes([TTY_NAME_MAX]u8),
    status: i32 = 0,
    fd: i32 = -1,

    // Screen
    screen: *Screen,
    base: Screen,

    // Colour palette
    palette: ColourPalette = .{},

    // Pipe (pipe-pane)
    pipe_fd: i32 = -1,
    pipe_pid: std.posix.pid_t = -1,
};

// ── Window ────────────────────────────────────────────────────────────────

pub const WINDOW_BELL: u32 = 0x01;
pub const WINDOW_ACTIVITY: u32 = 0x02;
pub const WINDOW_SILENCE: u32 = 0x04;
pub const WINDOW_ZOOMED: u32 = 0x08;
pub const WINDOW_RESIZE: u32 = 0x20;

pub const Window = struct {
    id: u32,
    latest: ?*anyopaque = null,

    name: []u8,

    active: ?*WindowPane = null,
    panes: std.ArrayList(*WindowPane) = .{},
    last_panes: std.ArrayList(*WindowPane) = .{},

    lastlayout: i32 = -1,
    layout_root: ?*LayoutCell = null,
    saved_layout_root: ?*LayoutCell = null,
    old_layout: ?[]u8 = null,

    sx: u32,
    sy: u32,
    manual_sx: u32 = 0,
    manual_sy: u32 = 0,
    xpixel: u32 = DEFAULT_XPIXEL,
    ypixel: u32 = DEFAULT_YPIXEL,

    new_sx: u32 = 0,
    new_sy: u32 = 0,

    flags: u32 = 0,
    options: *Options,
    references: u32 = 0,
    winlinks: std.ArrayList(*Winlink) = .{},
};

// ── Winlink ───────────────────────────────────────────────────────────────

pub const WINLINK_BELL: u32 = 0x01;
pub const WINLINK_ACTIVITY: u32 = 0x02;
pub const WINLINK_SILENCE: u32 = 0x04;
pub const WINLINK_VISITED: u32 = 0x08;

pub const Winlink = struct {
    idx: i32,
    session: *Session,
    window: *Window,
    flags: u32 = 0,
};

// ── Session ───────────────────────────────────────────────────────────────

pub const SESSION_ALERTED: u32 = 0x01;

pub const SessionGroup = struct {
    name: []const u8,
    sessions: std.ArrayList(*Session) = .{},
};

pub const Session = struct {
    id: u32,
    name: []u8,
    cwd: []const u8,

    curw: ?*Winlink = null,
    lastw: std.ArrayList(*Winlink) = .{},
    windows: std.AutoHashMap(i32, Winlink) = undefined, // keyed by idx

    statusat: i32 = 0,
    statuslines: u32 = 1,

    options: *Options,
    flags: u32 = 0,
    attached: u32 = 0,

    tio: ?*std.posix.termios = null,
    environ: *Environ,
    references: i32 = 1,
};

// ── Options ───────────────────────────────────────────────────────────────

pub const OptionsType = enum {
    string,
    number,
    @"bool",
    choice,
    colour,
    style,
    flag,
    array,
    command,
};

pub const OptionsScope = packed struct {
    server: bool = false,
    session: bool = false,
    window: bool = false,
    pane: bool = false,
};

pub const OPTIONS_TABLE_SERVER: OptionsScope = .{ .server = true };
pub const OPTIONS_TABLE_SESSION: OptionsScope = .{ .session = true };
pub const OPTIONS_TABLE_WINDOW: OptionsScope = .{ .window = true };
pub const OPTIONS_TABLE_PANE: OptionsScope = .{ .pane = true };

pub const OptionsTableEntry = struct {
    name: []const u8,
    @"type": OptionsType,
    scope: OptionsScope,
    default_num: i64 = 0,
    default_str: ?[]const u8 = null,
    choices: ?[]const []const u8 = null,
    minimum: ?i64 = null,
    maximum: ?i64 = null,
    unit: ?[]const u8 = null,
    text: ?[]const u8 = null,
    separator: ?[]const u8 = null,
};

pub const OptionsValue = union(OptionsType) {
    string: []u8,
    number: i64,
    @"bool": bool,
    choice: u32,
    colour: i32,
    style: Style,
    flag: bool,
    array: std.ArrayList([]u8),
    command: ?*anyopaque, // cmd_list pointer, opaque for now
};

pub const Options = struct {
    parent: ?*Options,
    entries: std.StringHashMap(OptionsValue),

    pub fn init(alloc: std.mem.Allocator, parent: ?*Options) Options {
        return .{ .parent = parent, .entries = std.StringHashMap(OptionsValue).init(alloc) };
    }
    pub fn deinit(self: *Options) void {
        self.entries.deinit();
    }
};

// ── Environ ───────────────────────────────────────────────────────────────

pub const ENVIRON_HIDDEN: u32 = 0x01;

pub const EnvironEntry = struct {
    name: []u8,
    value: ?[]u8,
    flags: u32 = 0,
};

pub const Environ = struct {
    entries: std.StringHashMap(EnvironEntry),

    pub fn init(alloc: std.mem.Allocator) Environ {
        return .{ .entries = std.StringHashMap(EnvironEntry).init(alloc) };
    }
    pub fn deinit(self: *Environ) void {
        self.entries.deinit();
    }
};

// ── Client ────────────────────────────────────────────────────────────────

pub const CLIENT_TERMINAL: u64 = 0x000001;
pub const CLIENT_LOGIN: u64 = 0x000002;
pub const CLIENT_EXIT: u64 = 0x000004;
pub const CLIENT_REDRAWWINDOW: u64 = 0x000008;
pub const CLIENT_REDRAWSTATUS: u64 = 0x000010;
pub const CLIENT_REDRAWSTATUSALWAYS: u64 = 0x000020;
pub const CLIENT_REDRAWBORDERS: u64 = 0x000040;
pub const CLIENT_REDRAWPANES: u64 = 0x000080;
pub const CLIENT_REDRAWOVERLAY: u64 = 0x000100;
pub const CLIENT_REDRAWSCROLLBARS: u64 = 0x000200;
pub const CLIENT_REDRAW: u64 = CLIENT_REDRAWWINDOW | CLIENT_REDRAWSTATUS | CLIENT_REDRAWSTATUSALWAYS | CLIENT_REDRAWBORDERS | CLIENT_REDRAWPANES | CLIENT_REDRAWOVERLAY | CLIENT_REDRAWSCROLLBARS;
pub const CLIENT_CONTROL: u64 = 0x000400;
pub const CLIENT_CONTROLCONTROL: u64 = 0x000800;
pub const CLIENT_FOCUSED: u64 = 0x001000;
pub const CLIENT_UTF8: u64 = 0x002000;
pub const CLIENT_IDENTIFIED: u64 = 0x004000;
pub const CLIENT_ATTACHED: u64 = 0x008000;
pub const CLIENT_STARTSERVER: u64 = 0x010000;
pub const CLIENT_NOSTARTSERVER: u64 = 0x020000;
pub const CLIENT_READONLY: u64 = 0x040000;
pub const CLIENT_IGNORESIZE: u64 = 0x080000;
pub const CLIENT_NOFORK: u64 = 0x100000;
pub const CLIENT_DEFAULTSOCKET: u64 = 0x200000;

pub const ClientExitReason = enum {
    none,
    detached,
    detached_hup,
    lost_tty,
    terminated,
    lost_server,
    exited,
    server_exited,
    message_provided,
};

pub const StatusLine = struct {
    screen: Screen,
    active: ?*Screen = null,
    references: u32 = 0,
    style: GridCell = std.mem.zeroes(GridCell),
};

pub const Client = struct {
    name: ?[]const u8 = null,
    peer: ?*ZmuxPeer = null,

    pid: std.posix.pid_t = 0,
    fd: i32 = -1,
    out_fd: i32 = -1,
    retval: i32 = 0,

    environ: *Environ,
    title: ?[]u8 = null,
    path: ?[]u8 = null,
    cwd: ?[]const u8 = null,

    term_name: ?[]u8 = null,
    term_features: i32 = 0,
    term_type: ?[]u8 = null,
    term_caps: ?[][]u8 = null,
    ttyname: ?[]u8 = null,

    tty: Tty,
    status: StatusLine,

    flags: u64 = 0,
    session: ?*Session = null,
    last_session: ?*Session = null,

    exit_reason: ClientExitReason = .none,
    exit_message: ?[]u8 = null,
    exit_session: ?[]u8 = null,

    message_string: ?[]u8 = null,
};

// ── IPC proc layer ────────────────────────────────────────────────────────

pub const PEER_BAD: u32 = 0x1;

pub const ZmuxPeer = struct {
    parent: *ZmuxProc,
    ibuf: c.imsg.imsgbuf,
    event: ?*c.libevent.event = null,
    uid: std.posix.uid_t = 0,
    flags: u32 = 0,
    dispatchcb: *const fn (?*c.imsg.imsg, ?*anyopaque) callconv(.c) void,
    arg: ?*anyopaque = null,
};

pub const ZmuxProc = struct {
    name: []const u8,
    exit: bool = false,
    signalcb: ?*const fn (i32) callconv(.c) void = null,
    peers: std.ArrayList(*ZmuxPeer) = .{},
    sig_events: std.ArrayList(*c.libevent.event) = .{},
};

// ── Command framework ─────────────────────────────────────────────────────

pub const CmdRetval = enum(i32) {
    @"error" = -1,
    normal = 0,
    wait = 1,
    stop = 2,
};

pub const CMD_STARTSERVER: u32 = 0x01;
pub const CMD_READONLY: u32 = 0x02;
pub const CMD_AFTERHOOK: u32 = 0x04;
pub const CMD_CLIENT_CFLAG: u32 = 0x08;
pub const CMD_CLIENT_TFLAG: u32 = 0x10;
pub const CMD_CLIENT_CANFAIL: u32 = 0x20;

pub const CmdFindType = enum {
    pane,
    window,
    session,
};

pub const CMD_FIND_PREFER_UNATTACHED: u32 = 0x01;
pub const CMD_FIND_QUIET: u32 = 0x02;
pub const CMD_FIND_WINDOW_INDEX: u32 = 0x04;
pub const CMD_FIND_DEFAULT_MARKED: u32 = 0x08;
pub const CMD_FIND_EXACT_SESSION: u32 = 0x10;
pub const CMD_FIND_EXACT_WINDOW: u32 = 0x20;
pub const CMD_FIND_CANFAIL: u32 = 0x40;

pub const CmdFindState = struct {
    flags: u32 = 0,
    current: ?*CmdFindState = null,
    s: ?*Session = null,
    wl: ?*Winlink = null,
    w: ?*Window = null,
    wp: ?*WindowPane = null,
    idx: i32 = 0,
};

pub const CmdParseStatus = enum {
    @"error",
    success,
};

pub const CmdParseResult = struct {
    status: CmdParseStatus,
    cmdlist: ?*anyopaque = null,
    @"error": ?[]u8 = null,
};

pub const CmdParseInput = struct {
    flags: u32 = 0,
    file: ?[]const u8 = null,
    line: u32 = 0,
    item: ?*CmdqItem = null,
    c: ?*Client = null,
    fs: CmdFindState = .{},
};

pub const CMDQ_STATE_REPEAT: u32 = 0x1;
pub const CMDQ_STATE_CONTROL: u32 = 0x2;
pub const CMDQ_STATE_NOHOOKS: u32 = 0x4;

// Opaque forward references – filled in by cmd.zig and cmd-queue.zig
pub const CmdList = opaque {};
pub const CmdqItem = opaque {};
pub const Cmd = opaque {};
pub const CmdqList = opaque {};

pub const ArgsType = enum {
    none,
    string,
    commands,
};

pub const ArgsValue = struct {
    @"type": ArgsType = .none,
    data: union {
        string: []u8,
        cmdlist: *CmdList,
        none: void,
    } = .{ .none = {} },
    cached: ?[]u8 = null,
};

pub const Args = struct {
    flags: std.AutoHashMap(u8, []ArgsValue),
    values: std.ArrayList(ArgsValue),
};

// ── Spawn context ─────────────────────────────────────────────────────────

pub const SPAWN_KILL: u32 = 0x01;
pub const SPAWN_DETACHED: u32 = 0x02;
pub const SPAWN_RESPAWN: u32 = 0x04;
pub const SPAWN_CANFAIL: u32 = 0x08;
pub const SPAWN_EMPTY: u32 = 0x10;
pub const SPAWN_NONOTIFY: u32 = 0x20;
pub const SPAWN_BEFORE: u32 = 0x40;
pub const SPAWN_FULLSIZE: u32 = 0x80;
pub const SPAWN_NEWWINDOW: u32 = 0x100;
pub const SPAWN_ZOOM: u32 = 0x200;

pub const SpawnContext = struct {
    item: ?*CmdqItem = null,
    s: ?*Session = null,
    wl: ?*Winlink = null,
    wp0: ?*WindowPane = null,
    lc: ?*LayoutCell = null,
    name: ?[]const u8 = null,
    argv: ?[][]u8 = null,
    environ: ?*Environ = null,
    idx: i32 = -1,
    cwd: ?[]const u8 = null,
    flags: u32 = 0,
};

// ── Message log ───────────────────────────────────────────────────────────

pub const MessageEntry = struct {
    msg: []u8,
    msg_num: u32,
    msg_time: i64, // unix timestamp
};

// ── Alert and window-size constants ───────────────────────────────────────

pub const ALERT_NONE: u32 = 0;
pub const ALERT_ANY: u32 = 1;
pub const ALERT_CURRENT: u32 = 2;
pub const ALERT_OTHER: u32 = 3;

pub const WINDOW_SIZE_LARGEST: u32 = 0;
pub const WINDOW_SIZE_SMALLEST: u32 = 1;
pub const WINDOW_SIZE_MANUAL: u32 = 2;
pub const WINDOW_SIZE_LATEST: u32 = 3;

pub const PANE_STATUS_OFF: u32 = 0;
pub const PANE_STATUS_TOP: u32 = 1;
pub const PANE_STATUS_BOTTOM: u32 = 2;

// ── Screen write context (forward-compat stub) ────────────────────────────

pub const ScreenWriteCtx = struct {
    wp: ?*WindowPane = null,
    s: *Screen,
    flags: u32 = 0,
};
