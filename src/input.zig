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
// Ported in part from tmux/input.c.
// Original copyright:
//   Copyright (c) 2009 Nicholas Marriott <nicholas.marriott@gmail.com>
//   ISC licence – same terms as above.

//! input.zig – reduced terminal-input parser feeding screen-write.

const std = @import("std");
const T = @import("types.zig");
const xm = @import("xmalloc.zig");
const opts = @import("options.zig");
const screen_mod = @import("screen.zig");
const grid_mod = @import("grid.zig");
const screen_write = @import("screen-write.zig");
const alerts = @import("alerts.zig");
const hyperlinks_mod = @import("hyperlinks.zig");
const colour_mod = @import("colour.zig");
const window_mod = @import("window.zig");
const log = @import("log.zig");
const paste_mod = @import("paste.zig");
const proc_mod = @import("proc.zig");
const c_bridge = @import("c.zig");
/// OSC terminator type — mirrors tmux's input_end_type.
const OscEndType = enum { st, bel };

/// Global input buffer size limit, settable via input_set_buffer_size.
var input_buffer_size: usize = 1048576;

// ── Reply infrastructure ─────────────────────────────────────────────────

/// Low-level reply writer: writes a raw string back to the pane's PTY fd.
/// Mirrors tmux input_send_reply (writes to bufferevent; zmux writes to fd).
pub fn input_send_reply(wp: *T.WindowPane, reply: []const u8) void {
    if (wp.fd < 0) return;
    log.log_debug("input_send_reply: {s}", .{reply});
    var rest = reply;
    while (rest.len > 0) {
        const written = std.posix.write(@intCast(wp.fd), rest) catch return;
        if (written == 0) return;
        rest = rest[written..];
    }
}

/// Terminal reply: format and send a reply string to the pane's PTY.
/// Mirrors tmux input_reply. The `add` parameter is accepted for API
/// compatibility (tmux uses it for request queuing) but currently ignored
/// since zmux does not yet have the request queue infrastructure.
pub fn input_reply(wp: *T.WindowPane, _: bool, comptime fmt: []const u8, args: anytype) void {
    var buf: [512]u8 = undefined;
    const reply = std.fmt.bufPrint(&buf, fmt, args) catch return;
    input_send_reply(wp, reply);
}

/// Reply to a colour query (OSC 4/10/11/12).
/// Mirrors tmux input_osc_colour_reply.
pub fn input_osc_colour_reply(
    wp: *T.WindowPane,
    add: bool,
    n: u32,
    idx: i32,
    c_in: i32,
    end_type: OscEndType,
) void {
    var c = c_in;
    if (c != -1) c = colour_mod.colour_force_rgb(c);
    if (c == -1) return;
    var r: u8 = undefined;
    var g: u8 = undefined;
    var b: u8 = undefined;
    colour_mod.colour_split_rgb(c, &r, &g, &b);

    const end: []const u8 = if (end_type == .bel) "\x07" else "\x1b\\";

    if (n == 4) {
        input_reply(wp, add, "\x1b]{d};{d};rgb:{x:0>2}{x:0>2}/{x:0>2}{x:0>2}/{x:0>2}{x:0>2}{s}", .{
            n, idx, r, r, g, g, b, b, end,
        });
    } else {
        input_reply(wp, add, "\x1b]{d};rgb:{x:0>2}{x:0>2}/{x:0>2}{x:0>2}/{x:0>2}{x:0>2}{s}", .{
            n, r, r, g, g, b, b, end,
        });
    }
}

/// Report the current theme (dark/light) to the pane.
/// Mirrors tmux input_report_current_theme.
pub fn input_report_current_theme(wp: *T.WindowPane) void {
    const theme = window_mod.window_pane_get_theme(wp);
    wp.flags &= ~@as(u32, T.PANE_THEMECHANGED);

    switch (theme) {
        .dark => {
            log.log_debug("input_report_current_theme: %%{d} dark theme", .{wp.id});
            input_reply(wp, false, "\x1b[?997;1n", .{});
        },
        .light => {
            log.log_debug("input_report_current_theme: %%{d} light theme", .{wp.id});
            input_reply(wp, false, "\x1b[?997;2n", .{});
        },
        .unknown => {
            log.log_debug("input_report_current_theme: %%{d} unknown theme", .{wp.id});
        },
    }
}

/// Send a clipboard reply (OSC 52) back to the pane.
/// Mirrors tmux input_reply_clipboard.
pub fn input_reply_clipboard(wp: *T.WindowPane, buf: ?[]const u8, end: []const u8, clip: u8) void {
    if (wp.fd < 0) return;

    // Compute base64 payload size (if any).
    const encoded_len: usize = if (buf) |data| (if (data.len > 0) std.base64.standard.Encoder.calcSize(data.len) else 0) else 0;
    // Header "\x1b]52;" (5) + optional clip (1) + ";" (1) + encoded + end
    const clip_len: usize = if (clip != 0) 1 else 0;
    const total = 5 + clip_len + 1 + encoded_len + end.len;
    const out = xm.allocator.alloc(u8, total) catch return;
    defer xm.allocator.free(out);

    var pos: usize = 0;
    @memcpy(out[pos..][0..5], "\x1b]52;");
    pos += 5;
    if (clip != 0) {
        out[pos] = clip;
        pos += 1;
    }
    out[pos] = ';';
    pos += 1;

    if (buf) |data| {
        if (data.len > 0) {
            _ = std.base64.standard.Encoder.encode(out[pos..][0..encoded_len], data);
            pos += encoded_len;
        }
    }
    @memcpy(out[pos..][0..end.len], end);
    pos += end.len;

    input_send_reply(wp, out[0..pos]);
}

/// Start a 5-second timer that resets the input parser to ground state.
/// Prevents a stuck parser when a DCS/OSC/APC sequence is never completed.
pub fn input_start_ground_timer(wp: *T.WindowPane) void {
    const base = proc_mod.libevent orelse return;
    if (wp.ground_timer == null) {
        wp.ground_timer = c_bridge.libevent.event_new(
            base, -1, 0, input_ground_timer_cb, wp,
        );
    }
    const ev = wp.ground_timer orelse return;
    _ = c_bridge.libevent.event_del(ev);
    var tv = std.posix.timeval{ .sec = 5, .usec = 0 };
    _ = c_bridge.libevent.event_add(ev, @ptrCast(&tv));
}

export fn input_ground_timer_cb(_: c_int, _: c_short, arg: ?*anyopaque) void {
    const wp: *T.WindowPane = @ptrCast(@alignCast(arg orelse return));
    log.log_debug("input_ground_timer_cb: %%{d} ground timer expired", .{wp.id});
    input_reset(wp, 0);
}

// ── Input request queue ──────────────────────────────────────────────────

/// Start a 100ms timer that flushes stale requests.
pub fn input_start_request_timer(wp: *T.WindowPane) void {
    const base = proc_mod.libevent orelse return;
    if (wp.input_request_timer == null) {
        wp.input_request_timer = c_bridge.libevent.event_new(
            base, -1, 0, input_request_timer_cb, wp,
        );
    }
    const ev = wp.input_request_timer orelse return;
    _ = c_bridge.libevent.event_del(ev);
    var tv = std.posix.timeval{ .sec = 0, .usec = 100000 };
    _ = c_bridge.libevent.event_add(ev, @ptrCast(&tv));
}

export fn input_request_timer_cb(_: c_int, _: c_short, arg: ?*anyopaque) void {
    const wp: *T.WindowPane = @ptrCast(@alignCast(arg orelse return));
    log.log_debug("input_request_timer_cb: %%{d} flushing {d} stale requests", .{ wp.id, wp.input_request_list.items.len });
    while (wp.input_request_list.items.len > 0) {
        const ir = wp.input_request_list.items[0];
        if (ir.type == .queue) {
            if (ir.data) |d| {
                const bytes: [*]const u8 = @ptrCast(@alignCast(d));
                // Queued reply data length is stored as the idx field.
                input_send_reply(wp, bytes[0..@as(usize, @intCast(ir.idx))]);
            }
        }
        input_free_request_at(wp, 0);
    }
}

fn input_free_request_at(wp: *T.WindowPane, idx: usize) void {
    const ir = wp.input_request_list.items[idx];
    if (ir.c) |cl| {
        for (cl.input_requests.items, 0..) |cir, ci| {
            if (cir == ir) {
                _ = cl.input_requests.orderedRemove(ci);
                break;
            }
        }
    }
    wp.input_request_count -|= 1;
    xm.allocator.destroy(ir);
    _ = wp.input_request_list.orderedRemove(idx);
}

/// Add a request to the pane's queue and send the query to the best client.
pub fn input_add_request(wp: *T.WindowPane, req_type: T.InputRequestType, idx: i32, end: T.InputEndType) i32 {
    const client_registry = @import("client-registry.zig");
    const sess = @import("session.zig");
    const tty_mod = @import("tty.zig");

    var best: ?*T.Client = null;
    for (client_registry.clients.items) |cl| {
        if (cl.flags & (T.CLIENT_DEAD | T.CLIENT_SUSPENDED) != 0) continue;
        const s = cl.session orelse continue;
        if (!sess.session_has_window(s, wp.window)) continue;
        if ((cl.tty.flags & @as(i32, @intCast(T.TTY_STARTED))) == 0) continue;
        if (best == null)
            best = cl
        else if (cl.activity_time > best.?.activity_time)
            best = cl;
    }
    const cl = best orelse return -1;

    const ir = xm.allocator.create(T.InputRequest) catch return -1;
    ir.* = .{
        .wp = wp,
        .c = cl,
        .type = req_type,
        .idx = idx,
        .end = end,
        .t = @intCast(@max(std.time.milliTimestamp(), 0)),
    };
    wp.input_request_list.append(xm.allocator, ir) catch {
        xm.allocator.destroy(ir);
        return -1;
    };
    cl.input_requests.append(xm.allocator, ir) catch {};
    wp.input_request_count += 1;

    if (wp.input_request_count == 1)
        input_start_request_timer(wp);

    switch (req_type) {
        .palette => {
            var buf: [32]u8 = undefined;
            const query = std.fmt.bufPrint(&buf, "\x1b]4;{d};?\x1b\\", .{idx}) catch return -1;
            tty_mod.tty_puts_str(&cl.tty, query);
        },
        .clipboard => {
            tty_mod.tty_putcode_ss(&cl.tty, "Ms", "", "?");
        },
        .queue => {},
    }
    return 0;
}

/// Handle a reply to a request forwarded from tty-keys.
pub fn input_request_reply(cl: *T.Client, req_type_raw: u32, data: ?*anyopaque) void {
    const rtype = std.meta.intToEnum(T.InputRequestType, req_type_raw) catch return;
    _ = data;

    // Find first matching request on this client.
    var found: ?*T.InputRequest = null;
    for (cl.input_requests.items) |ir| {
        if (ir.type == rtype) {
            found = ir;
            break;
        }
    }
    const match = found orelse return;
    const wp = match.wp orelse return;

    // Process all requests on the pane's queue up to and including the match.
    while (wp.input_request_list.items.len > 0) {
        const ir = wp.input_request_list.items[0];
        const is_match = (ir == match);
        if (ir.type == .queue) {
            if (ir.data) |d| {
                const bytes: [*]const u8 = @ptrCast(@alignCast(d));
                input_send_reply(wp, bytes[0..@as(usize, @intCast(ir.idx))]);
            }
        }
        input_free_request_at(wp, 0);
        if (is_match) break;
    }
}

/// Cancel all pending requests for a client (called on disconnect).
pub fn input_cancel_requests(cl: *T.Client) void {
    while (cl.input_requests.items.len > 0) {
        const ir = cl.input_requests.items[0];
        if (ir.wp) |wp| {
            for (wp.input_request_list.items, 0..) |pir, pi| {
                if (pir == ir) {
                    wp.input_request_count -|= 1;
                    _ = wp.input_request_list.orderedRemove(pi);
                    break;
                }
            }
        }
        xm.allocator.destroy(ir);
        _ = cl.input_requests.orderedRemove(0);
    }
}

/// Set the global input buffer size limit.
pub fn input_set_buffer_size(buffer_size: usize) void {
    log.log_debug("input_set_buffer_size: {d} -> {d}", .{ input_buffer_size, buffer_size });
    input_buffer_size = buffer_size;
}

pub fn input_parse_screen(wp: *T.WindowPane, bytes: []const u8) void {
    if (bytes.len == 0) return;
    wp.flags |= T.PANE_CHANGED;
    if (wp.modes.items.len != 0)
        wp.flags |= T.PANE_UNSEENCHANGES;
    wp.input_pending.appendSlice(@import("xmalloc.zig").allocator, bytes) catch unreachable;

    var ctx = T.ScreenWriteCtx{ .wp = wp, .s = screen_mod.screen_current(wp) };
    var i: usize = 0;
    while (i < wp.input_pending.items.len) {
        if (wp.input_pending.items[i] != 0x1b) {
            const start = i;
            var end = i;
            while (end < wp.input_pending.items.len and wp.input_pending.items[end] != 0x1b) : (end += 1) {}

            const keep_incomplete_tail = end == wp.input_pending.items.len;
            const consumed = handle_plain_bytes(&ctx, wp.input_pending.items[start..end], keep_incomplete_tail);
            i += consumed;
            if (consumed < end - start) break;
            continue;
        }

        if (i + 1 >= wp.input_pending.items.len) break;
        const next = wp.input_pending.items[i + 1];
        if (next == '[') {
            const consumed = parse_csi(&ctx, wp.input_pending.items[i..]) orelse break;
            i += consumed;
            continue;
        }
        if (next == ']') {
            const consumed = parse_osc(wp, wp.input_pending.items[i..]) orelse break;
            i += consumed;
            continue;
        }
        if (next == '=') {
            ctx.s.mode |= T.MODE_KKEYPAD;
            i += 2;
            continue;
        }
        if (next == '>') {
            ctx.s.mode &= ~T.MODE_KKEYPAD;
            i += 2;
            continue;
        }
        if (next == 'H') {
            if (ctx.s.cx < ctx.s.grid.sx)
                screen_mod.screen_set_tab(ctx.s, ctx.s.cx);
            i += 2;
            continue;
        }
        if (next == '7') {
            screen_write.save_cursor(&ctx);
            i += 2;
            continue;
        }
        if (next == '8') {
            screen_write.restore_cursor(&ctx);
            i += 2;
            continue;
        }
        if (next == 'D') {
            // IND – index (linefeed)
            screen_write.newline(&ctx);
            i += 2;
            continue;
        }
        if (next == 'M') {
            // RI – reverse index
            const gd = ctx.s.grid;
            if (ctx.s.cy == ctx.s.rupper)
                grid_mod.scroll_down(gd, ctx.s.rupper, @min(ctx.s.rlower, gd.sy -| 1))
            else if (ctx.s.cy > 0)
                ctx.s.cy -= 1;
            i += 2;
            continue;
        }
        if (next == 'E') {
            // NEL – next line
            screen_write.carriage_return(&ctx);
            screen_write.newline(&ctx);
            i += 2;
            continue;
        }
        if (next == 'c') {
            // RIS – full reset
            input_reset_cell(ctx.s);
            screen_write.erase_screen(&ctx);
            i += 2;
            continue;
        }
        if (next == 'P') {
            // DCS – device control string with full parameter/intermediate parsing
            const dcs = parse_dcs_structured(wp.input_pending.items[i..]) orelse break;
            apply_dcs(wp, &ctx, dcs);
            i += dcs.consumed;
            continue;
        }
        if (next == '_') {
            // APC – application program command
            // tmux uses APC to set window title (like a secondary OSC 0/2).
            // Consume until ST, and apply title if allow-set-title is enabled.
            const consumed = parse_apc(wp, wp.input_pending.items[i..]) orelse break;
            i += consumed;
            continue;
        }
        if (next == 'k') {
            // ESC k ... ESC \\ – window rename (reduced: consume until ST)
            const consumed = parse_rename(wp, wp.input_pending.items[i..]) orelse break;
            i += consumed;
            continue;
        }
        if (next == 'X') {
            // SOS – consume until ST
            const consumed = parse_string_to_st(wp.input_pending.items[i..]) orelse break;
            i += consumed;
            continue;
        }
        if (next == '(' or next == ')') {
            // ESC ( C / ESC ) C — SCS (select character set)
            if (i + 2 >= wp.input_pending.items.len) break;
            const charset = wp.input_pending.items[i + 2];
            if (next == '(') {
                ctx.s.g0set = if (charset == '0') 1 else 0;
            } else {
                ctx.s.g1set = if (charset == '0') 1 else 0;
            }
            i += 3;
            continue;
        }
        if (next == '#') {
            // ESC # 8 — DECALN (screen alignment test)
            if (i + 2 >= wp.input_pending.items.len) break;
            if (wp.input_pending.items[i + 2] == '8') {
                screen_write.alignmenttest(&ctx);
            }
            i += 3;
            continue;
        }

        // Reduced default: swallow other ESC sequences for now.
        i += 2;
    }

    if (i > 0) {
        const remaining = wp.input_pending.items.len - i;
        std.mem.copyForwards(u8, wp.input_pending.items[0..remaining], wp.input_pending.items[i..]);
        wp.input_pending.shrinkRetainingCapacity(remaining);
    }
}

fn handle_plain_bytes(ctx: *T.ScreenWriteCtx, bytes: []const u8, keep_incomplete_tail: bool) usize {
    var i: usize = 0;
    var chunk_start: usize = 0;

    while (i < bytes.len) {
        const ch = bytes[i];
        switch (ch) {
            0x07, '\r', '\n', 0x08, '\t', 0x0B, 0x0C, 0x0E, 0x0F => {
                if (i > chunk_start) {
                    _ = screen_write.putBytes(ctx, bytes[chunk_start..i], false);
                }
                handle_plain_control(ctx, ch);
                i += 1;
                chunk_start = i;
            },
            else => i += 1,
        }
    }

    if (chunk_start < bytes.len) {
        return chunk_start + screen_write.putBytes(ctx, bytes[chunk_start..], keep_incomplete_tail);
    }
    return i;
}

fn handle_plain_control(ctx: *T.ScreenWriteCtx, ch: u8) void {
    switch (ch) {
        0x07 => if (ctx.wp) |wp| alerts.alerts_queue(wp.window, T.WINDOW_BELL),
        '\r' => screen_write.carriage_return(ctx),
        '\n', 0x0B, 0x0C => {
            // LF, VT, FF: if MODE_CRLF is set, do carriage return first
            if (ctx.s.mode & T.MODE_CRLF != 0)
                screen_write.carriage_return(ctx);
            screen_write.newline(ctx);
        },
        0x08 => screen_write.backspace(ctx),
        '\t' => screen_write.tab(ctx),
        0x0E => {
            // SO – shift out (select G1 character set, no-op for now)
        },
        0x0F => {
            // SI – shift in (select G0 character set, no-op for now)
        },
        else => unreachable,
    }
}

fn parse_csi(ctx: *T.ScreenWriteCtx, bytes: []const u8) ?usize {
    var idx: usize = 2; // ESC [
    while (idx < bytes.len) : (idx += 1) {
        const ch = bytes[idx];
        if (ch >= '@' and ch <= '~') {
            apply_csi(ctx, bytes[2..idx], ch);
            return idx + 1;
        }
    }
    return null;
}

fn parse_osc(wp: *T.WindowPane, bytes: []const u8) ?usize {
    var idx: usize = 2; // ESC ]
    while (idx < bytes.len) : (idx += 1) {
        if (bytes[idx] == 0x07) {
            apply_osc(wp, bytes[2..idx], .bel);
            return idx + 1;
        }
        if (idx + 1 < bytes.len and bytes[idx] == 0x1b and bytes[idx + 1] == '\\') {
            apply_osc(wp, bytes[2..idx], .st);
            return idx + 2;
        }
    }
    return null;
}

fn apply_osc(wp: *T.WindowPane, payload: []const u8, end_type: OscEndType) void {
    // Parse the numeric OSC kind from the payload (everything before the first ';').
    // Some OSC codes (110/111/112) have no value part.
    const semi = std.mem.indexOfScalar(u8, payload, ';');
    const kind_slice = if (semi) |s| payload[0..s] else payload;
    const kind = std.fmt.parseInt(u32, kind_slice, 10) catch return;
    const value: []const u8 = if (semi) |s| payload[s + 1 ..] else "";
    const current = screen_mod.screen_current(wp);

    switch (kind) {
        0, 1, 2 => {
            // OSC 0/1/2 – set window title
            if (current.title) |old| xm.allocator.free(old);
            current.title = if (value.len != 0) xm.xstrdup(value) else null;
        },
        4 => {
            // OSC 4 ; index ; color — set/query palette colour
            apply_osc_4(wp, value, end_type);
        },
        7 => {
            // OSC 7 ; path — set working directory
            screen_mod.screen_set_path(current, value);
        },
        8 => {
            // OSC 8 ; params ; uri — hyperlink open/close
            apply_osc_8(current, value);
        },
        10 => {
            // OSC 10 ; color — set/query foreground colour
            apply_osc_10(wp, value, end_type);
        },
        11 => {
            // OSC 11 ; color — set/query background colour
            apply_osc_11(wp, value, end_type);
        },
        12 => {
            // OSC 12 ; color — set/query cursor colour
            apply_osc_12(wp, value, end_type);
        },
        52 => {
            // OSC 52 ; clipboard — clipboard access
            apply_osc_52(wp, value, end_type);
        },
        104 => {
            // OSC 104 ; index — reset palette colour (stub)
        },
        110 => {
            // OSC 110 — reset foreground colour
            wp.palette.fg = 8;
        },
        111 => {
            // OSC 111 — reset background colour
            wp.palette.bg = 8;
        },
        112 => {
            // OSC 112 — reset cursor colour (stub)
        },
        133 => {
            // OSC 133 ; marker — semantic prompt markers A/B/C/D (stub)
        },
        else => {
            // Unknown OSC sequence — ignore
        },
    }
}

/// OSC 8 ; params ; uri — open or close a hyperlink.
/// Params may contain key=value pairs separated by ':'.
/// An empty URI closes the current hyperlink (sets link to 0).
/// A non-empty URI stores the hyperlink via the screen's hyperlink table.
fn apply_osc_8(s: *T.Screen, value: []const u8) void {
    // Split into params and URI at the first ';'
    const semi_idx = std.mem.indexOfScalar(u8, value, ';') orelse {
        // No URI separator — invalid, swallow
        return;
    };
    const params = value[0..semi_idx];
    const uri = value[semi_idx + 1 ..];

    // Close hyperlink when URI is empty
    if (uri.len == 0) {
        s.cell_attr &= ~T.GRID_ATTR_HIDDEN; // no special attr needed; link 0 = no link
        s.saved_cell.link = 0;
        return;
    }

    // Parse "id=<value>" from params if present
    var id: ?[]const u8 = null;
    if (params.len > 0) {
        var pos: usize = 0;
        while (pos < params.len) {
            // Find next ':' or end
            const next_colon = std.mem.indexOfScalarPos(u8, params, pos, ':') orelse params.len;
            const segment = params[pos..next_colon];
            if (segment.len > 3 and std.mem.startsWith(u8, segment, "id=")) {
                id = segment[3..];
            }
            pos = next_colon + 1;
        }
    }

    // Store the hyperlink if the screen has a hyperlink table
    if (s.hyperlinks) |hl| {
        const link_id = hyperlinks_mod.hyperlinks_put(hl, uri, id);
        // Attach to the current cell state so future writes carry the link
        s.saved_cell.link = link_id;
    }
    // If no hyperlink table exists, just swallow (reduced)
}

/// Handle OSC 4 — palette colour set/query.
/// If the value is "idx;?" we reply with the palette colour.
/// Otherwise consume silently (set is a stub for now).
fn apply_osc_4(wp: *T.WindowPane, value: []const u8, end_type: OscEndType) void {
    // Parse "idx;?" or "idx;colour" pairs
    var rest: []const u8 = value;
    while (rest.len > 0) {
        const semi1 = std.mem.indexOfScalar(u8, rest, ';') orelse return;
        const idx_str = rest[0..semi1];
        const idx = std.fmt.parseInt(i32, idx_str, 10) catch return;
        if (idx < 0 or idx >= 256) return;
        rest = rest[semi1 + 1 ..];
        const semi2 = std.mem.indexOfScalar(u8, rest, ';') orelse rest.len;
        const colour_str = rest[0..semi2];
        if (std.mem.eql(u8, colour_str, "?")) {
            // Query: reply with palette colour
            const c = colour_mod.colour_palette_get(&wp.palette, idx | @as(i32, @bitCast(T.COLOUR_FLAG_256)));
            if (c != -1) {
                input_osc_colour_reply(wp, true, 4, idx, c, end_type);
            }
        }
        // Set is a stub — would need colour_parseX11 + colour_palette_set
        if (semi2 >= rest.len) break;
        rest = rest[semi2 + 1 ..];
    }
}

/// Handle OSC 10 — foreground colour set/query.
fn apply_osc_10(wp: *T.WindowPane, value: []const u8, end_type: OscEndType) void {
    if (std.mem.eql(u8, value, "?")) {
        // Query foreground colour
        const c = window_mod.window_pane_get_fg(wp);
        input_osc_colour_reply(wp, true, 10, 0, c, end_type);
        return;
    }
    // Set foreground colour — stub (would need colour_parseX11)
}

/// Handle OSC 11 — background colour set/query.
fn apply_osc_11(wp: *T.WindowPane, value: []const u8, end_type: OscEndType) void {
    if (std.mem.eql(u8, value, "?")) {
        // Query background colour
        const c = window_mod.window_pane_get_bg(wp);
        input_osc_colour_reply(wp, true, 11, 0, c, end_type);
        return;
    }
    // Set background colour — stub (would need colour_parseX11)
}

/// Handle OSC 12 — cursor colour set/query.
fn apply_osc_12(wp: *T.WindowPane, value: []const u8, end_type: OscEndType) void {
    if (std.mem.eql(u8, value, "?")) {
        // Query cursor colour
        const current = screen_mod.screen_current(wp);
        var c = current.ccolour;
        if (c == -1) c = current.default_ccolour;
        input_osc_colour_reply(wp, true, 12, 0, c, end_type);
        return;
    }
    // Set cursor colour — stub (would need colour_parseX11)
}

/// Handle OSC 52 — clipboard access.
/// "c;?" queries, "c;base64data" sets.
fn apply_osc_52(wp: *T.WindowPane, value: []const u8, end_type: OscEndType) void {
    const semi = std.mem.indexOfScalar(u8, value, ';') orelse return;
    const clip_str = value[0..semi];
    const data_str = value[semi + 1 ..];

    // Determine which clipboard target
    const clip: u8 = if (clip_str.len > 0) clip_str[0] else 0;

    if (std.mem.eql(u8, data_str, "?")) {
        // Query clipboard — reply with current paste buffer
        const state = opts.options_get_number(opts.global_options, "get-clipboard");
        if (state == 0) return;
        if (state == 1) {
            const pb = paste_mod.paste_get_top(null) orelse return;
            var len: usize = 0;
            const buf = paste_mod.paste_buffer_data(pb, &len);
            const end: []const u8 = if (end_type == .bel) "\x07" else "\x1b\\";
            input_reply_clipboard(wp, buf[0..len], end, clip);
        }
        // state >= 2 would need input_add_request (client request infrastructure)
        return;
    }

    // Set clipboard — decode base64 and store
    const set_state = opts.options_get_number(opts.global_options, "set-clipboard");
    if (set_state != 2) return;
    if (data_str.len == 0) return;

    const decoded_len = std.base64.standard.Decoder.calcSizeForSlice(data_str) catch return;
    const decoded = xm.allocator.alloc(u8, decoded_len) catch return;
    std.base64.standard.Decoder.decode(decoded, data_str) catch {
        xm.allocator.free(decoded);
        return;
    };
    paste_mod.paste_add(null, decoded);
}

/// Parsed DCS structure: parameters, intermediate bytes, and data payload.
const DcsParsed = struct {
    /// Total bytes consumed from input (including ESC P and ST).
    consumed: usize,
    /// Raw parameter string (digits and ';' between ESC P and the data).
    params: []const u8,
    /// Intermediate bytes (0x20-0x2F range) collected before data.
    interm: []const u8,
    /// Data payload after params/intermediates, up to ST.
    data: []const u8,
};

/// Parse a DCS sequence and extract the structured components.
fn parse_dcs_structured(bytes: []const u8) ?DcsParsed {
    if (bytes.len < 2) return null;
    std.debug.assert(bytes[0] == 0x1b and bytes[1] == 'P');

    var idx: usize = 2;

    // Phase 1: Collect parameter bytes.
    const param_start = idx;
    var ignore = false;
    while (idx < bytes.len) {
        const ch = bytes[idx];
        if ((ch >= '0' and ch <= '9') or ch == ';') {
            idx += 1;
        } else if (ch == ':' or (ch >= '<' and ch <= '?')) {
            ignore = true;
            idx += 1;
            break;
        } else {
            break;
        }
    }
    const params = if (!ignore) bytes[param_start..idx] else "";

    // Phase 2: Collect intermediate bytes.
    const interm_start = idx;
    while (idx < bytes.len and bytes[idx] >= 0x20 and bytes[idx] <= 0x2F) {
        idx += 1;
    }
    const interm = if (!ignore) bytes[interm_start..idx] else "";

    // Phase 3: Ignore mode — skip to ST.
    if (ignore) {
        while (idx < bytes.len) {
            if (bytes[idx] == 0x1b and idx + 1 < bytes.len and bytes[idx + 1] == '\\') return DcsParsed{ .consumed = idx + 2, .params = "", .interm = "", .data = "" };
            if (bytes[idx] == 0x07) return DcsParsed{ .consumed = idx + 1, .params = "", .interm = "", .data = "" };
            idx += 1;
        }
        return null;
    }

    // Phase 4: Collect data payload.
    const data_start = idx;
    while (idx < bytes.len) {
        if (bytes[idx] == 0x1b) {
            if (idx + 1 >= bytes.len) return null;
            if (bytes[idx + 1] == '\\') {
                return DcsParsed{
                    .consumed = idx + 2,
                    .params = params,
                    .interm = interm,
                    .data = bytes[data_start..idx],
                };
            }
            idx += 2;
            continue;
        }
        if (bytes[idx] == 0x07) {
            return DcsParsed{
                .consumed = idx + 1,
                .params = params,
                .interm = interm,
                .data = bytes[data_start..idx],
            };
        }
        idx += 1;
    }
    return null;
}

/// Dispatch a fully-parsed DCS sequence, applying side-effects.
/// Mirrors tmux's input_dcs_dispatch and input_handle_decrqss.
fn apply_dcs(wp: *T.WindowPane, ctx: *T.ScreenWriteCtx, dcs: DcsParsed) void {
    const data = dcs.data;

    // DECRQSS: DCS $ q <request> ST  (intermediate '$', data starts with 'q')
    if (dcs.interm.len == 1 and dcs.interm[0] == '$' and data.len >= 1 and data[0] == 'q') {
        apply_decrqss(wp, ctx, data);
        return;
    }

    // Sixel: DCS Ps ; Ps q <data> ST  (no intermediate, data starts with 'q')
    if (dcs.interm.len == 0 and data.len >= 1 and data[0] == 'q') {
        const w = wp.window;
        const sixel_mod = @import("image-sixel.zig");
        // Second DCS parameter (P2) controls transparent background.
        // Parse from the raw param string "Ps;P2" — default to 0.
        const p2: u32 = blk: {
            const semi = std.mem.indexOfScalar(u8, dcs.params, ';') orelse break :blk 0;
            if (semi + 1 >= dcs.params.len) break :blk 0;
            break :blk std.fmt.parseInt(u32, dcs.params[semi + 1 ..], 10) catch 0;
        };
        const si = sixel_mod.sixel_parse(data, p2, w.xpixel, w.ypixel) orelse return;
        const sw = @import("screen-write.zig");
        sw.screen_write_sixelimage(ctx, si, T.grid_default_cell.bg);
        return;
    }

    // Passthrough: DCS tmux; <raw> ST
    // Stub: would need allow-passthrough option check + rawstring output.
    if (data.len >= 5 and std.mem.startsWith(u8, data, "tmux;")) {
        return;
    }

    // All other DCS sequences: silently consumed.
}

/// Handle DECRQSS (DCS $ q <request> ST).
/// Currently handles cursor style query (SP q).
fn apply_decrqss(wp: *T.WindowPane, ctx: *T.ScreenWriteCtx, data: []const u8) void {
    // data[0] == 'q', rest is the request selector
    if (data.len < 3 or data[1] != ' ' or data[2] != 'q') {
        // Unrecognized DECRQSS: send DCS 0 $ r ST
        input_reply(wp, true, "\x1bP0$r\x1b\\", .{});
        return;
    }

    // Cursor style query: DCS $ q SP q ST
    // Reply: DCS 1 $ r Ps SP q ST
    const s = ctx.s;
    const ps: u32 = blk: {
        if (s.cstyle == .block or s.cstyle == .underline or s.cstyle == .bar) {
            const blinking = (s.mode & T.MODE_CURSOR_BLINKING) != 0;
            break :blk switch (s.cstyle) {
                .block => if (blinking) @as(u32, 1) else 2,
                .underline => if (blinking) @as(u32, 3) else 4,
                .bar => if (blinking) @as(u32, 5) else 6,
                else => 0,
            };
        }
        // Fall back to configured cursor-style option
        const opt_ps = opts.options_get_number(wp.options, "cursor-style");
        if (opt_ps < 0 or opt_ps > 6) break :blk @as(u32, 0);
        break :blk @intCast(opt_ps);
    };

    input_reply(wp, true, "\x1bP1$r q{d} q\x1b\\", .{ps});
}

fn parse_string_to_st(bytes: []const u8) ?usize {
    // Consume until ESC \ or BEL, starting after ESC <introducer>
    var idx: usize = 2; // skip ESC and the introducer character
    while (idx < bytes.len) {
        if (bytes[idx] == 0x1b and idx + 1 < bytes.len and bytes[idx + 1] == '\\') return idx + 2;
        if (bytes[idx] == 0x07) return idx + 1;
        idx += 1;
    }
    return null;
}

fn parse_rename(_: *T.WindowPane, bytes: []const u8) ?usize {
    // ESC k name ESC \\ – window rename
    var idx: usize = 2; // skip ESC k
    while (idx < bytes.len) {
        if (bytes[idx] == 0x1b and idx + 1 < bytes.len and bytes[idx + 1] == '\\') {
            // const name = bytes[2..idx];
            // reduced: would need allow-rename option check
            return idx + 2;
        }
        if (bytes[idx] == 0x07) {
            return idx + 1;
        }
        idx += 1;
    }
    return null;
}

/// Parse APC sequence: ESC _ payload ST (ESC \ or BEL).
/// If allow-set-title is enabled, sets the window title to the APC payload.
/// Returns total bytes consumed, or null if incomplete.
fn parse_apc(wp: *T.WindowPane, bytes: []const u8) ?usize {
    var idx: usize = 2; // skip ESC _
    while (idx < bytes.len) {
        if (bytes[idx] == 0x1b and idx + 1 < bytes.len and bytes[idx + 1] == '\\') {
            const payload = bytes[2..idx];
            apply_apc(wp, payload);
            return idx + 2;
        }
        if (bytes[idx] == 0x07) {
            const payload = bytes[2..idx];
            apply_apc(wp, payload);
            return idx + 1;
        }
        idx += 1;
    }
    return null;
}

/// Apply APC payload. tmux uses APC to set the window title when
/// allow-set-title is enabled (mirroring its input_exit_apc handler).
fn apply_apc(wp: *T.WindowPane, payload: []const u8) void {
    if (opts.options_get_number(wp.options, "allow-set-title") == 0) return;
    const s = screen_mod.screen_current(wp);
    _ = screen_mod.screen_set_title(s, payload);
}

fn apply_csi(ctx: *T.ScreenWriteCtx, raw_params: []const u8, final: u8) void {
    var private = false;
    var modify_other_keys = false;
    var has_intermediate_space = false;
    var params_raw = raw_params;
    if (params_raw.len != 0 and params_raw[0] == '?') {
        private = true;
        params_raw = params_raw[1..];
    } else if (params_raw.len != 0 and params_raw[0] == '>') {
        modify_other_keys = true;
        params_raw = params_raw[1..];
    }

    // Check for intermediate bytes between numeric parameters and final byte.
    // Space (0x20) is used by DECSCUSR (CSI Ps SP q).
    // Dollar (0x24) is used by DECRQM (CSI ? Ps $ p).
    var has_intermediate_dollar = false;
    if (std.mem.indexOfScalar(u8, params_raw, ' ') != null) {
        has_intermediate_space = true;
    }
    if (std.mem.indexOfScalar(u8, params_raw, '$') != null) {
        has_intermediate_dollar = true;
    }

    var params_buf: [24]u32 = [_]u32{0} ** 24;
    const parsed = parse_csi_params(params_raw, &params_buf);
    const params = params_buf[0..parsed.count];

    if (modify_other_keys and final == 'm') {
        apply_modify_other_keys(ctx, params);
        return;
    }
    if (modify_other_keys and final == 'c') {
        // CSI > c — DA2 secondary device attributes
        if (first_param(params, 0) == 0) {
            if (ctx.wp) |wp| input_reply(wp, true, "\x1b[>84;0;0c", .{});
        }
        return;
    }
    if (modify_other_keys and final == 'n') {
        // CSI > Ps n — MODOFF (extended key mode clear)
        apply_modify_other_keys_off(ctx, params);
        return;
    }
    if (modify_other_keys and final == 'q') {
        // CSI > q — XDA (report terminal name and version)
        if (first_param(params, 0) == 0) {
            if (ctx.wp) |wp| {
                const zmux_mod = @import("zmux.zig");
                const ver = zmux_mod.getversion();
                input_reply(wp, true, "\x1bP>|zmux {s}\x1b\\", .{ver});
            }
        }
        return;
    }
    if (private and (final == 'h' or final == 'l')) {
        apply_private_modes(ctx, params, final == 'h');
        return;
    }
    if (private and final == 'n') {
        // CSI ? Ps n — DSR_PRIVATE (device status report, private mode).
        if (first_param(params, 0) == 996) {
            if (ctx.wp) |wp| input_report_current_theme(wp);
        }
        return;
    }
    if (private and has_intermediate_dollar and final == 'p') {
        // CSI ? Ps $ p — DECRQM (request mode, private)
        apply_decrqm(ctx, params);
        return;
    }
    if (private and final == 'S') {
        // CSI ? Ps S — graphics mode SM (Sixel support query)
        apply_sm_graphics(ctx, params);
        return;
    }
    if (has_intermediate_space and final == 'q') {
        // CSI Ps SP q — DECSCUSR set cursor style
        apply_decscusr(ctx, params);
        return;
    }

    switch (final) {
        'A' => screen_write.cursor_up(ctx, first_param(params, 1)),
        'B' => screen_write.cursor_down(ctx, first_param(params, 1)),
        'C' => screen_write.cursor_right(ctx, first_param(params, 1)),
        'D' => screen_write.cursor_left(ctx, first_param(params, 1)),
        'E' => {
            screen_write.cursor_down(ctx, first_param(params, 1));
            screen_write.carriage_return(ctx);
        },
        'F' => {
            screen_write.cursor_up(ctx, first_param(params, 1));
            screen_write.carriage_return(ctx);
        },
        'G', '`' => screen_write.cursor_to(ctx, ctx.s.cy, first_param(params, 1) -| 1),
        'H', 'f' => {
            const row = first_param(params, 1) -| 1;
            const col = second_param(params, 1) -| 1;
            screen_write.cursor_to(ctx, row, col);
        },
        'J' => switch (first_param(params, 0)) {
            0 => screen_write.erase_to_screen_end(ctx),
            1 => screen_write.erase_to_screen_beginning(ctx),
            2 => screen_write.erase_screen(ctx),
            3 => {
                if (second_param(params, 0) == 0)
                    screen_write.clearhistory(ctx);
            },
            else => {},
        },
        'K' => switch (first_param(params, 0)) {
            0 => screen_write.erase_to_eol(ctx),
            1 => screen_write.erase_to_bol(ctx),
            2 => screen_write.erase_line(ctx),
            else => {},
        },
        'L' => screen_write.insert_lines(ctx, first_param(params, 1)),
        'M' => screen_write.delete_lines(ctx, first_param(params, 1)),
        '@' => screen_write.insert_characters(ctx, first_param(params, 1)),
        'P' => screen_write.delete_characters(ctx, first_param(params, 1)),
        'X' => screen_write.erase_characters(ctx, first_param(params, 1)),
        'g' => switch (first_param(params, 0)) {
            0 => if (ctx.s.cx < ctx.s.grid.sx) screen_mod.screen_clear_tab(ctx.s, ctx.s.cx),
            3 => screen_mod.screen_clear_all_tabs(ctx.s),
            else => {},
        },
        'd' => screen_write.cursor_to(ctx, first_param(params, 1) -| 1, ctx.s.cx),
        'S' => {
            // SU – scroll up
            const gd = ctx.s.grid;
            const top = ctx.s.rupper;
            const bottom = @min(ctx.s.rlower, gd.sy -| 1);
            var n = first_param(params, 1);
            while (n > 0) : (n -= 1) {
                grid_mod.scroll_up(gd, top, bottom);
            }
        },
        'T' => {
            // SD – scroll down
            const gd = ctx.s.grid;
            const top = ctx.s.rupper;
            const bottom = @min(ctx.s.rlower, gd.sy -| 1);
            var n = first_param(params, 1);
            while (n > 0) : (n -= 1) {
                grid_mod.scroll_down(gd, top, bottom);
            }
        },
        'Z' => {
            // CBT – cursor backward tabulation
            var cx = ctx.s.cx;
            if (cx > ctx.s.grid.sx) cx = ctx.s.grid.sx;
            var n = first_param(params, 1);
            while (cx > 0 and n > 0) : (n -= 1) {
                while (cx > 0) : (cx -= 1) {
                    if (screen_mod.screen_has_tab(ctx.s, cx - 1)) break;
                }
            }
            ctx.s.cx = cx;
        },
        'b' => {
            // REP – repeat previous printable character
            apply_rep(ctx, first_param(params, 1));
        },
        'c' => {
            // DA1 – device attributes
            if (first_param(params, 0) == 0) {
                if (ctx.wp) |wp| input_reply(wp, true, "\x1b[?1;2c", .{});
            }
        },
        'n' => {
            // DSR – device status report
            if (ctx.wp) |wp| {
                switch (first_param(params, 0)) {
                    5 => input_reply(wp, true, "\x1b[0n", .{}),
                    6 => input_reply(wp, true, "\x1b[{d};{d}R", .{ ctx.s.cy + 1, ctx.s.cx + 1 }),
                    else => {},
                }
            }
        },
        'r' => {
            const top = first_param(params, 1) -| 1;
            const bottom = second_param(params, ctx.s.grid.sy) -| 1;
            screen_write.set_scroll_region(ctx, top, bottom);
        },
        's' => screen_write.save_cursor(ctx),
        'u' => screen_write.restore_cursor(ctx),
        't' => apply_winops(ctx, params),
        'm' => apply_sgr_raw(ctx, params_raw),
        'h' => apply_sm(ctx, params, false),
        'l' => apply_rm(ctx, params, false),
        else => {},
    }
}

/// CSI Ps b — REP: repeat previous printable character Ps times.
fn apply_rep(ctx: *T.ScreenWriteCtx, n: u32) void {
    const s = ctx.s;
    if (!s.input_last_valid) return;
    if (s.last_glyph.size == 0) return;

    const max = if (s.cx < s.grid.sx) s.grid.sx - s.cx else 0;
    var count = @min(n, max);
    if (count == 0) return;

    // Build a cell from the last glyph with current attributes.
    var gc = T.GridCell.fromPayload(&s.last_glyph);
    while (count > 0) : (count -= 1) {
        screen_write.putCell(ctx, &gc);
    }
}

fn apply_sgr(ctx: *T.ScreenWriteCtx, params: []const u32) void {
    const s = ctx.s;
    if (params.len == 0) {
        s.cell_fg = 8;
        s.cell_bg = 8;
        s.cell_us = 8;
        s.cell_attr = 0;
        return;
    }
    var i: usize = 0;
    while (i < params.len) : (i += 1) {
        const n = params[i];
        switch (n) {
            0 => {
                s.cell_fg = 8;
                s.cell_bg = 8;
                s.cell_us = 8;
                s.cell_attr = 0;
            },
            1 => s.cell_attr |= T.GRID_ATTR_BRIGHT,
            2 => s.cell_attr |= T.GRID_ATTR_DIM,
            3 => s.cell_attr |= T.GRID_ATTR_ITALICS,
            4 => {
                s.cell_attr &= ~T.GRID_ATTR_ALL_UNDERSCORE;
                s.cell_attr |= T.GRID_ATTR_UNDERSCORE;
            },
            5, 6 => s.cell_attr |= T.GRID_ATTR_BLINK,
            7 => s.cell_attr |= T.GRID_ATTR_REVERSE,
            8 => s.cell_attr |= T.GRID_ATTR_HIDDEN,
            9 => s.cell_attr |= T.GRID_ATTR_STRIKETHROUGH,
            21 => {
                s.cell_attr &= ~T.GRID_ATTR_ALL_UNDERSCORE;
                s.cell_attr |= T.GRID_ATTR_UNDERSCORE_2;
            },
            22 => s.cell_attr &= ~(T.GRID_ATTR_BRIGHT | T.GRID_ATTR_DIM),
            23 => s.cell_attr &= ~T.GRID_ATTR_ITALICS,
            24 => s.cell_attr &= ~T.GRID_ATTR_ALL_UNDERSCORE,
            25 => s.cell_attr &= ~T.GRID_ATTR_BLINK,
            27 => s.cell_attr &= ~T.GRID_ATTR_REVERSE,
            28 => s.cell_attr &= ~T.GRID_ATTR_HIDDEN,
            29 => s.cell_attr &= ~T.GRID_ATTR_STRIKETHROUGH,
            30...37 => s.cell_fg = n - 30,
            39 => s.cell_fg = 8,
            40...47 => s.cell_bg = n - 40,
            49 => s.cell_bg = 8,
            53 => s.cell_attr |= T.GRID_ATTR_OVERLINE,
            55 => s.cell_attr &= ~T.GRID_ATTR_OVERLINE,
            59 => s.cell_us = 8,
            90...97 => s.cell_fg = n,
            100...107 => s.cell_bg = n - 10,
            38, 48, 58 => {
                if (i + 1 < params.len) {
                    i += 1;
                    if (params[i] == 5 and i + 1 < params.len) {
                        i += 1;
                        sgr_set_colour_256(s, n, params[i]);
                    } else if (params[i] == 2 and i + 3 < params.len) {
                        const r = params[i + 1];
                        const g = params[i + 2];
                        const b = params[i + 3];
                        sgr_set_colour_rgb(s, n, r, g, b);
                        i += 3;
                    }
                }
            },
            else => {},
        }
    }
}

/// SGR entry point that works on the raw CSI parameter bytes.
/// Handles both semicolon-separated and colon-separated (ISO 8613-6) forms.
///
/// Plain semicolon-separated parameters (e.g. "38;2;255;128;0") must be
/// collected into a single array so that multi-param sequences like
/// 38;2;R;G;B are consumed correctly.  Colon-separated segments (e.g.
/// "38:2::255:128:0") are self-contained and handled independently.
fn apply_sgr_raw(ctx: *T.ScreenWriteCtx, raw: []const u8) void {
    if (raw.len == 0) {
        apply_sgr(ctx, &[_]u32{});
        return;
    }

    var buf: [24]u32 = [_]u32{0} ** 24;
    var count: usize = 0;

    var start: usize = 0;
    while (start <= raw.len) {
        const end = std.mem.indexOfScalarPos(u8, raw, start, ';') orelse raw.len;
        const seg = raw[start..end];

        if (std.mem.indexOfScalar(u8, seg, ':') != null) {
            // Flush accumulated plain params before the colon segment.
            if (count > 0) {
                apply_sgr(ctx, buf[0..count]);
                count = 0;
            }
            apply_sgr_colon(ctx, seg);
        } else {
            // Parse numeric value and accumulate into the shared buffer.
            const val = std.fmt.parseInt(u32, seg, 10) catch 0;
            if (count < buf.len) {
                buf[count] = val;
                count += 1;
            }
        }

        if (end >= raw.len) break;
        start = end + 1;
    }

    if (count > 0) {
        apply_sgr(ctx, buf[0..count]);
    }
}

/// Handle a single colon-separated SGR segment (ISO 8613-6).
/// e.g. "4:3" for curly underline, "38:2::255:128:0" for RGB fg,
/// "58:5:196" for underline colour 256.
fn apply_sgr_colon(ctx: *T.ScreenWriteCtx, seg: []const u8) void {
    const s = ctx.s;
    var p: [8]i32 = [_]i32{-1} ** 8;
    var n: usize = 0;

    var pos: usize = 0;
    while (pos <= seg.len and n < 8) {
        const next = std.mem.indexOfScalarPos(u8, seg, pos, ':') orelse seg.len;
        const part = seg[pos..next];
        if (part.len > 0) {
            p[n] = @as(i32, @intCast(std.fmt.parseInt(u32, part, 10) catch {
                return;
            }));
        }
        n += 1;
        if (next >= seg.len) break;
        pos = next + 1;
    }

    if (n == 0) return;

    // 4:N — underline style variants
    if (p[0] == 4) {
        if (n != 2) return;
        switch (p[1]) {
            0 => s.cell_attr &= ~T.GRID_ATTR_ALL_UNDERSCORE,
            1 => {
                s.cell_attr &= ~T.GRID_ATTR_ALL_UNDERSCORE;
                s.cell_attr |= T.GRID_ATTR_UNDERSCORE;
            },
            2 => {
                s.cell_attr &= ~T.GRID_ATTR_ALL_UNDERSCORE;
                s.cell_attr |= T.GRID_ATTR_UNDERSCORE_2;
            },
            3 => {
                s.cell_attr &= ~T.GRID_ATTR_ALL_UNDERSCORE;
                s.cell_attr |= T.GRID_ATTR_UNDERSCORE_3;
            },
            4 => {
                s.cell_attr &= ~T.GRID_ATTR_ALL_UNDERSCORE;
                s.cell_attr |= T.GRID_ATTR_UNDERSCORE_4;
            },
            5 => {
                s.cell_attr &= ~T.GRID_ATTR_ALL_UNDERSCORE;
                s.cell_attr |= T.GRID_ATTR_UNDERSCORE_5;
            },
            else => {},
        }
        return;
    }

    // 38:..., 48:..., 58:... — colour with colon sub-params
    if (n < 2 or (p[0] != 38 and p[0] != 48 and p[0] != 58)) return;
    const fgbg: u32 = @intCast(p[0]);
    switch (p[1]) {
        2 => {
            if (n < 3) return;
            // Two forms: 38:2:R:G:B (n==5) or 38:2:colourspace:R:G:B (n>=6)
            var ci: usize = undefined;
            if (n == 5)
                ci = 2
            else
                ci = 3;
            if (n < ci + 3) return;
            const r = p[ci];
            const g = p[ci + 1];
            const b = p[ci + 2];
            if (r < 0 or r > 255 or g < 0 or g > 255 or b < 0 or b > 255) return;
            sgr_set_colour_rgb(s, fgbg, @intCast(r), @intCast(g), @intCast(b));
        },
        5 => {
            if (n < 3) return;
            const c = p[2];
            if (c < 0 or c > 255) return;
            sgr_set_colour_256(s, fgbg, @intCast(c));
        },
        else => {},
    }
}

fn sgr_set_colour_256(s: *T.Screen, fgbg: u32, c: u32) void {
    const val = c | T.COLOUR_FLAG_256;
    if (fgbg == 38)
        s.cell_fg = val
    else if (fgbg == 48)
        s.cell_bg = val
    else if (fgbg == 58)
        s.cell_us = val;
}

fn sgr_set_colour_rgb(s: *T.Screen, fgbg: u32, r: u32, g: u32, b: u32) void {
    const val = T.COLOUR_FLAG_RGB | (r << 16) | (g << 8) | b;
    if (fgbg == 38)
        s.cell_fg = val
    else if (fgbg == 48)
        s.cell_bg = val
    else if (fgbg == 58)
        s.cell_us = val;
}

/// Reset cell state to default (mirrors tmux's input_reset_cell).
fn input_reset_cell(s: *T.Screen) void {
    s.cell_fg = 8;
    s.cell_bg = 8;
    s.cell_us = 8;
    s.cell_attr = 0;
    s.g0set = 0;
    s.g1set = 0;
}

fn apply_sm(ctx: *T.ScreenWriteCtx, params: []const u32, private: bool) void {
    if (private) {
        apply_private_modes(ctx, params, true);
        return;
    }
    for (params) |mode| {
        switch (mode) {
            4 => ctx.s.mode |= T.MODE_INSERT,
            34 => ctx.s.mode &= ~T.MODE_CURSOR_VERY_VISIBLE,
            else => {},
        }
    }
}

fn apply_rm(ctx: *T.ScreenWriteCtx, params: []const u32, private: bool) void {
    if (private) {
        apply_private_modes(ctx, params, false);
        return;
    }
    for (params) |mode| {
        switch (mode) {
            4 => ctx.s.mode &= ~T.MODE_INSERT,
            34 => ctx.s.mode |= T.MODE_CURSOR_VERY_VISIBLE,
            else => {},
        }
    }
}

fn apply_decscusr(ctx: *T.ScreenWriteCtx, params: []const u32) void {
    // CSI Ps SP q — DECSCUSR set cursor style.
    // 0 or 1 = blinking block, 2 = steady block,
    // 3 = blinking underline, 4 = steady underline,
    // 5 = blinking bar, 6 = steady bar.
    const style = first_param(params, 0);
    const s = ctx.s;
    switch (style) {
        0 => {
            s.cstyle = .default;
            s.mode &= ~T.MODE_CURSOR_BLINKING_SET;
        },
        1 => {
            s.cstyle = .block;
            s.mode |= T.MODE_CURSOR_BLINKING;
            s.mode |= T.MODE_CURSOR_BLINKING_SET;
        },
        2 => {
            s.cstyle = .block;
            s.mode &= ~T.MODE_CURSOR_BLINKING;
            s.mode |= T.MODE_CURSOR_BLINKING_SET;
        },
        3 => {
            s.cstyle = .underline;
            s.mode |= T.MODE_CURSOR_BLINKING;
            s.mode |= T.MODE_CURSOR_BLINKING_SET;
        },
        4 => {
            s.cstyle = .underline;
            s.mode &= ~T.MODE_CURSOR_BLINKING;
            s.mode |= T.MODE_CURSOR_BLINKING_SET;
        },
        5 => {
            s.cstyle = .bar;
            s.mode |= T.MODE_CURSOR_BLINKING;
            s.mode |= T.MODE_CURSOR_BLINKING_SET;
        },
        6 => {
            s.cstyle = .bar;
            s.mode &= ~T.MODE_CURSOR_BLINKING;
            s.mode |= T.MODE_CURSOR_BLINKING_SET;
        },
        else => {},
    }
}

/// Handle CSI ? Ps S — graphics mode SM (Sixel support query).
/// zmux does not support Sixel, so always replies with "not recognized" (3).
fn apply_sm_graphics(ctx: *T.ScreenWriteCtx, params: []const u32) void {
    const wp = ctx.wp orelse return;
    if (params.len == 0) return;
    const n = params[0];
    const o: u32 = if (params.len >= 3) params[2] else 0;
    // Reply: not supported (action 3 = not recognized)
    input_reply(wp, true, "\x1b[?{d};3;{d}S", .{ n, o });
}

fn apply_winops(ctx: *T.ScreenWriteCtx, params: []const u32) void {
    const wp = ctx.wp;
    const x = ctx.s.grid.sx;
    const y = ctx.s.grid.sy;
    var m: usize = 0;
    while (m < params.len) {
        const n = params[m];
        switch (n) {
            1, 2, 5, 6, 7, 11, 13, 17, 20, 21, 24 => {},
            14 => {
                // Report text area size in pixels
                if (wp) |p| {
                    const w = p.window;
                    input_reply(p, true, "\x1b[4;{d};{d}t", .{
                        y * w.ypixel, x * w.xpixel,
                    });
                }
            },
            15 => {
                // Report screen size in pixels
                if (wp) |p| {
                    const w = p.window;
                    input_reply(p, true, "\x1b[5;{d};{d}t", .{
                        y * w.ypixel, x * w.xpixel,
                    });
                }
            },
            16 => {
                // Report cell size in pixels
                if (wp) |p| {
                    const w = p.window;
                    input_reply(p, true, "\x1b[6;{d};{d}t", .{ w.ypixel, w.xpixel });
                }
            },
            18 => {
                // Report text area size in characters
                if (wp) |p|
                    input_reply(p, true, "\x1b[8;{d};{d}t", .{ y, x });
            },
            19 => {
                // Report screen size in characters
                if (wp) |p|
                    input_reply(p, true, "\x1b[9;{d};{d}t", .{ y, x });
            },
            3, 4, 8 => {
                m += 1;
                if (m >= params.len) return;
                m += 1;
                if (m >= params.len) return;
            },
            9, 10 => {
                m += 1;
                if (m >= params.len) return;
            },
            22 => {
                m += 1;
                if (m >= params.len) return;
                if (params[m] == 0 or params[m] == 2)
                    screen_mod.screen_push_title(ctx.s);
            },
            23 => {
                m += 1;
                if (m >= params.len) return;
                if (params[m] == 0 or params[m] == 2)
                    screen_mod.screen_pop_title(ctx.s);
            },
            else => {},
        }
        m += 1;
    }
}

/// Handle CSI ? Ps $ p — DECRQM (request mode, private).
/// Replies with the current state of various private modes.
fn apply_decrqm(ctx: *T.ScreenWriteCtx, params: []const u32) void {
    const wp = ctx.wp orelse return;
    const s = ctx.s;
    const mode = first_param(params, 0);
    // n: 1 = set, 2 = reset
    const n: u32 = switch (mode) {
        12 => blk: {
            // Cursor blink: check runtime style or option
            if (s.cstyle != .default or (s.mode & T.MODE_CURSOR_BLINKING_SET != 0)) {
                break :blk if (s.mode & T.MODE_CURSOR_BLINKING != 0) 1 else 2;
            }
            const oo = wp.options;
            const p = opts.options_get_number(oo, "cursor-style");
            // blink for 1,3,5; steady for 0,2,4,6
            break :blk if (p == 1 or p == 3 or p == 5) 1 else 2;
        },
        1004 => if (s.mode & T.MODE_FOCUSON != 0) @as(u32, 1) else 2,
        1006 => if (s.mode & T.MODE_MOUSE_SGR != 0) @as(u32, 1) else 2,
        2004 => if (s.mode & T.MODE_BRACKETPASTE != 0) @as(u32, 1) else 2,
        2026 => if (s.mode & T.MODE_SYNC != 0) @as(u32, 1) else 2,
        2031 => 2, // theme updates: always report "not recognized"
        else => return,
    };
    input_reply(wp, true, "\x1b[?{d};{d}$y", .{ mode, n });
}

fn apply_modify_other_keys(ctx: *T.ScreenWriteCtx, params: []const u32) void {
    if (first_param(params, 0) != 4) return;

    const configured = opts.options_get_number(opts.global_options, "extended-keys");
    if (params.len >= 2 and params[1] != 0) {
        if (configured == 0) return;
        ctx.s.mode &= ~T.EXTENDED_KEY_MODES;
        if (params[1] == 2)
            ctx.s.mode |= T.MODE_KEYS_EXTENDED_2
        else if (params[1] == 1 or configured == 2)
            ctx.s.mode |= T.MODE_KEYS_EXTENDED;
        return;
    }

    ctx.s.mode &= ~T.EXTENDED_KEY_MODES;
    if (configured == 2) ctx.s.mode |= T.MODE_KEYS_EXTENDED;
}

/// Handle CSI > Ps n — MODOFF (extended key mode clear).
/// Mirrors tmux's INPUT_CSI_MODOFF handler.
fn apply_modify_other_keys_off(ctx: *T.ScreenWriteCtx, params: []const u32) void {
    if (first_param(params, 0) != 4) return;

    ctx.s.mode &= ~T.EXTENDED_KEY_MODES;
    const configured = opts.options_get_number(opts.global_options, "extended-keys");
    if (configured == 2) ctx.s.mode |= T.MODE_KEYS_EXTENDED;
}

fn apply_private_modes(ctx: *T.ScreenWriteCtx, params: []const u32, set: bool) void {
    const wp = ctx.wp orelse return;
    const current = screen_mod.screen_current(wp);
    for (params) |mode| {
        switch (mode) {
            1 => {
                if (set)
                    current.mode |= T.MODE_KCURSOR
                else
                    current.mode &= ~T.MODE_KCURSOR;
            },
            3 => {
                // DECCOLM — select 132/80 column mode (reduced: clear screen + home cursor)
                if (set) {
                    screen_write.cursor_to(ctx, 0, 0);
                    screen_write.erase_screen(ctx);
                } else {
                    screen_write.cursor_to(ctx, 0, 0);
                    screen_write.erase_screen(ctx);
                }
            },
            6 => {
                // DECOM — origin mode
                if (set)
                    current.mode |= T.MODE_ORIGIN
                else {
                    current.mode &= ~T.MODE_ORIGIN;
                    screen_write.cursor_to(ctx, 0, 0);
                }
            },
            7 => {
                // DECAWM — auto-wrap mode
                if (set)
                    current.mode |= T.MODE_WRAP
                else
                    current.mode &= ~T.MODE_WRAP;
            },
            12 => {
                // Cursor blinking
                if (set) {
                    current.mode |= T.MODE_CURSOR_BLINKING;
                    current.mode |= T.MODE_CURSOR_BLINKING_SET;
                } else {
                    current.mode &= ~T.MODE_CURSOR_BLINKING;
                    current.mode |= T.MODE_CURSOR_BLINKING_SET;
                }
            },
            25 => {
                current.cursor_visible = set;
                if (set)
                    current.mode |= T.MODE_CURSOR
                else
                    current.mode &= ~T.MODE_CURSOR;
            },
            1000, 1001 => {
                if (set) {
                    current.mode &= ~T.ALL_MOUSE_MODES;
                    current.mode |= T.MODE_MOUSE_STANDARD;
                } else current.mode &= ~T.ALL_MOUSE_MODES;
            },
            1002 => {
                if (set) {
                    current.mode &= ~T.ALL_MOUSE_MODES;
                    current.mode |= T.MODE_MOUSE_BUTTON;
                } else current.mode &= ~T.ALL_MOUSE_MODES;
            },
            1003 => {
                if (set) {
                    current.mode &= ~T.ALL_MOUSE_MODES;
                    current.mode |= T.MODE_MOUSE_ALL;
                } else current.mode &= ~T.ALL_MOUSE_MODES;
            },
            1004 => {
                // Focus reporting
                if (set)
                    current.mode |= T.MODE_FOCUSON
                else
                    current.mode &= ~T.MODE_FOCUSON;
            },
            1005 => {
                if (set)
                    current.mode |= T.MODE_MOUSE_UTF8
                else
                    current.mode &= ~T.MODE_MOUSE_UTF8;
            },
            1006 => {
                if (set)
                    current.mode |= T.MODE_MOUSE_SGR
                else
                    current.mode &= ~T.MODE_MOUSE_SGR;
            },
            47, 1047 => {
                if (set)
                    screen_mod.screen_enter_alternate(wp, false)
                else
                    screen_mod.screen_leave_alternate(wp, false);
            },
            1049 => {
                if (set)
                    screen_mod.screen_enter_alternate(wp, true)
                else
                    screen_mod.screen_leave_alternate(wp, true);
            },
            2004 => {
                current.bracketed_paste = set;
                if (set)
                    current.mode |= T.MODE_BRACKETPASTE
                else
                    current.mode &= ~T.MODE_BRACKETPASTE;
            },
            2026 => {
                // Synchronized output
                if (set) {
                    screen_write.screen_write_start_sync(wp);
                } else {
                    screen_write.screen_write_stop_sync(wp);
                    wp.flags |= T.PANE_REDRAW;
                }
            },
            2031 => {
                // Theme update notifications
                if (set) {
                    current.mode |= T.MODE_THEME_UPDATES;
                    wp.flags &= ~T.PANE_THEMECHANGED;
                } else {
                    current.mode &= ~T.MODE_THEME_UPDATES;
                    wp.flags &= ~T.PANE_THEMECHANGED;
                }
            },
            else => {},
        }
        ctx.s = screen_mod.screen_current(wp);
    }
}

const ParsedParams = struct {
    count: usize,
};

fn parse_csi_params(raw: []const u8, out: *[24]u32) ParsedParams {
    var count: usize = 0;
    var current: u32 = 0;
    var have_current = false;
    for (raw) |ch| {
        if (ch >= '0' and ch <= '9') {
            current = current * 10 + (ch - '0');
            have_current = true;
            continue;
        }
        if (ch == ';') {
            if (count < out.len) {
                out[count] = if (have_current) current else 0;
                count += 1;
            }
            current = 0;
            have_current = false;
            continue;
        }
    }
    if (have_current or count == 0) {
        if (count < out.len) {
            out[count] = if (have_current) current else 0;
            count += 1;
        }
    }
    return .{ .count = count };
}

fn first_param(params: []const u32, fallback: u32) u32 {
    if (params.len == 0 or params[0] == 0) return fallback;
    return params[0];
}

fn second_param(params: []const u32, fallback: u32) u32 {
    if (params.len < 2 or params[1] == 0) return fallback;
    return params[1];
}

test "input parses printable text and simple cursor movement" {
    const win = @import("window.zig");
    const grid = @import("grid.zig");

    opts.global_w_options = opts.options_create(null);
    defer opts.options_free(opts.global_w_options);
    opts.options_default_all(opts.global_w_options, T.OPTIONS_TABLE_WINDOW);
    win.window_init_globals(@import("xmalloc.zig").allocator);

    const w = win.window_create(8, 3, T.DEFAULT_XPIXEL, T.DEFAULT_YPIXEL);
    defer {
        while (w.panes.items.len > 0) {
            const pane = w.panes.items[w.panes.items.len - 1];
            win.window_remove_pane(w, pane);
        }
        w.panes.deinit(@import("xmalloc.zig").allocator);
        w.last_panes.deinit(@import("xmalloc.zig").allocator);
        opts.options_free(w.options);
        @import("xmalloc.zig").allocator.free(w.name);
        _ = win.windows.remove(w.id);
        @import("xmalloc.zig").allocator.destroy(w);
    }

    const wp = win.window_add_pane(w, null, 8, 3);
    input_parse_screen(wp, "ab\x1b[2;3HZ");
    try std.testing.expectEqual(@as(u8, 'a'), grid.ascii_at(wp.base.grid, 0, 0));
    try std.testing.expectEqual(@as(u8, 'b'), grid.ascii_at(wp.base.grid, 0, 1));
    try std.testing.expectEqual(@as(u8, 'Z'), grid.ascii_at(wp.base.grid, 1, 2));
}

test "input supports cursor save restore and private alternate screen" {
    const win = @import("window.zig");
    const grid = @import("grid.zig");

    opts.global_w_options = opts.options_create(null);
    defer opts.options_free(opts.global_w_options);
    opts.options_default_all(opts.global_w_options, T.OPTIONS_TABLE_WINDOW);
    win.window_init_globals(@import("xmalloc.zig").allocator);

    const w = win.window_create(8, 3, T.DEFAULT_XPIXEL, T.DEFAULT_YPIXEL);
    defer {
        while (w.panes.items.len > 0) {
            const pane = w.panes.items[w.panes.items.len - 1];
            win.window_remove_pane(w, pane);
        }
        w.panes.deinit(@import("xmalloc.zig").allocator);
        w.last_panes.deinit(@import("xmalloc.zig").allocator);
        opts.options_free(w.options);
        @import("xmalloc.zig").allocator.free(w.name);
        _ = win.windows.remove(w.id);
        @import("xmalloc.zig").allocator.destroy(w);
    }

    const wp = win.window_add_pane(w, null, 8, 3);
    input_parse_screen(wp, "abc\x1b[s\x1b[2;2HZ\x1b[uQ");
    try std.testing.expectEqual(@as(u8, 'Q'), grid.ascii_at(wp.base.grid, 0, 3));

    input_parse_screen(wp, "\x1b[?1049hALT");
    try std.testing.expect(screen_mod.screen_alternate_active(wp));
    try std.testing.expectEqual(@as(u8, 'A'), grid.ascii_at(wp.screen.grid, 0, 0));
    try std.testing.expectEqual(@as(u8, 'a'), grid.ascii_at(wp.base.grid, 0, 0));

    input_parse_screen(wp, "\x1b[?1049l");
    try std.testing.expect(!screen_mod.screen_alternate_active(wp));
    try std.testing.expectEqual(@as(u8, 'a'), grid.ascii_at(wp.base.grid, 0, 0));
}

test "input keeps incomplete CSI pending across calls" {
    const win = @import("window.zig");
    const grid = @import("grid.zig");

    opts.global_w_options = opts.options_create(null);
    defer opts.options_free(opts.global_w_options);
    opts.options_default_all(opts.global_w_options, T.OPTIONS_TABLE_WINDOW);
    win.window_init_globals(@import("xmalloc.zig").allocator);

    const w = win.window_create(4, 2, T.DEFAULT_XPIXEL, T.DEFAULT_YPIXEL);
    defer {
        while (w.panes.items.len > 0) {
            const pane = w.panes.items[w.panes.items.len - 1];
            win.window_remove_pane(w, pane);
        }
        w.panes.deinit(@import("xmalloc.zig").allocator);
        w.last_panes.deinit(@import("xmalloc.zig").allocator);
        opts.options_free(w.options);
        @import("xmalloc.zig").allocator.free(w.name);
        _ = win.windows.remove(w.id);
        @import("xmalloc.zig").allocator.destroy(w);
    }

    const wp = win.window_add_pane(w, null, 4, 2);
    input_parse_screen(wp, "\x1b[2");
    try std.testing.expectEqual(@as(usize, 3), wp.input_pending.items.len);
    input_parse_screen(wp, ";2HZ");
    try std.testing.expectEqual(@as(usize, 0), wp.input_pending.items.len);
    try std.testing.expectEqual(@as(u8, 'Z'), grid.ascii_at(wp.base.grid, 1, 1));
}

test "input keeps incomplete UTF-8 pending across calls" {
    const win = @import("window.zig");
    const grid = @import("grid.zig");

    opts.global_w_options = opts.options_create(null);
    defer opts.options_free(opts.global_w_options);
    opts.options_default_all(opts.global_w_options, T.OPTIONS_TABLE_WINDOW);
    win.window_init_globals(@import("xmalloc.zig").allocator);

    const w = win.window_create(6, 2, T.DEFAULT_XPIXEL, T.DEFAULT_YPIXEL);
    defer {
        while (w.panes.items.len > 0) {
            const pane = w.panes.items[w.panes.items.len - 1];
            win.window_remove_pane(w, pane);
        }
        w.panes.deinit(@import("xmalloc.zig").allocator);
        w.last_panes.deinit(@import("xmalloc.zig").allocator);
        opts.options_free(w.options);
        @import("xmalloc.zig").allocator.free(w.name);
        _ = win.windows.remove(w.id);
        @import("xmalloc.zig").allocator.destroy(w);
    }

    const wp = win.window_add_pane(w, null, 6, 2);
    input_parse_screen(wp, "\xf0\x9f");
    try std.testing.expectEqual(@as(usize, 2), wp.input_pending.items.len);

    input_parse_screen(wp, "\x99\x82A");
    try std.testing.expectEqual(@as(usize, 0), wp.input_pending.items.len);

    var cell: T.GridCell = undefined;
    grid.get_cell(wp.base.grid, 0, 0, &cell);
    try std.testing.expectEqual(@as(u8, 2), cell.data.width);
    grid.get_cell(wp.base.grid, 0, 1, &cell);
    try std.testing.expect(cell.isPadding());
    try std.testing.expectEqual(@as(u8, 'A'), grid.ascii_at(wp.base.grid, 0, 2));
}

test "input parses OSC pane title updates" {
    const win = @import("window.zig");

    opts.global_w_options = opts.options_create(null);
    defer opts.options_free(opts.global_w_options);
    opts.options_default_all(opts.global_w_options, T.OPTIONS_TABLE_WINDOW);
    win.window_init_globals(@import("xmalloc.zig").allocator);

    const w = win.window_create(4, 2, T.DEFAULT_XPIXEL, T.DEFAULT_YPIXEL);
    defer {
        while (w.panes.items.len > 0) {
            const pane = w.panes.items[w.panes.items.len - 1];
            win.window_remove_pane(w, pane);
        }
        w.panes.deinit(@import("xmalloc.zig").allocator);
        w.last_panes.deinit(@import("xmalloc.zig").allocator);
        opts.options_free(w.options);
        @import("xmalloc.zig").allocator.free(w.name);
        _ = win.windows.remove(w.id);
        @import("xmalloc.zig").allocator.destroy(w);
    }

    const wp = win.window_add_pane(w, null, 4, 2);
    input_parse_screen(wp, "\x1b]2;logs\x07");
    try std.testing.expectEqualStrings("logs", screen_mod.screen_current(wp).title.?);
}

test "input tracks pane path tabs and unseen changes" {
    const grid = @import("grid.zig");
    const win = @import("window.zig");

    opts.global_w_options = opts.options_create(null);
    defer opts.options_free(opts.global_w_options);
    opts.options_default_all(opts.global_w_options, T.OPTIONS_TABLE_WINDOW);
    win.window_init_globals(@import("xmalloc.zig").allocator);

    const w = win.window_create(12, 3, T.DEFAULT_XPIXEL, T.DEFAULT_YPIXEL);
    defer {
        while (w.panes.items.len > 0) {
            const pane = w.panes.items[w.panes.items.len - 1];
            win.window_remove_pane(w, pane);
        }
        w.panes.deinit(@import("xmalloc.zig").allocator);
        w.last_panes.deinit(@import("xmalloc.zig").allocator);
        opts.options_free(w.options);
        @import("xmalloc.zig").allocator.free(w.name);
        _ = win.windows.remove(w.id);
        @import("xmalloc.zig").allocator.destroy(w);
    }

    const wp = win.window_add_pane(w, null, 12, 3);
    const mode = T.WindowMode{ .name = "input-runtime-test" };
    const wme = win.window_pane_push_mode(wp, &mode, null, null);

    input_parse_screen(wp, "\x1b]7;/tmp/demo\x07\x1b[4G\x1bH\rA\tB");
    try std.testing.expectEqualStrings("/tmp/demo", screen_mod.screen_current(wp).path.?);
    try std.testing.expect(screen_mod.screen_has_tab(screen_mod.screen_current(wp), 3));
    try std.testing.expect((wp.flags & T.PANE_UNSEENCHANGES) != 0);
    try std.testing.expectEqual(@as(u8, 'A'), grid.ascii_at(wp.base.grid, 0, 0));
    try std.testing.expectEqual(@as(u8, 'B'), grid.ascii_at(wp.base.grid, 0, 3));

    input_parse_screen(wp, "\x1b[4G\x1b[g");
    try std.testing.expect(!screen_mod.screen_has_tab(screen_mod.screen_current(wp), 3));

    input_parse_screen(wp, "\x1b[3g");
    try std.testing.expect(!screen_mod.screen_has_tab(screen_mod.screen_current(wp), 8));

    try std.testing.expect(win.window_pane_pop_mode(wp, wme));
    try std.testing.expect((wp.flags & T.PANE_UNSEENCHANGES) == 0);
}

test "input tracks keypad cursor mouse and extended-key modes" {
    const win = @import("window.zig");

    opts.global_options = opts.options_create(null);
    defer opts.options_free(opts.global_options);
    opts.global_w_options = opts.options_create(null);
    defer opts.options_free(opts.global_w_options);
    opts.options_default_all(opts.global_options, T.OPTIONS_TABLE_SERVER);
    opts.options_default_all(opts.global_w_options, T.OPTIONS_TABLE_WINDOW);
    opts.options_set_number(opts.global_options, "extended-keys", 1);
    win.window_init_globals(@import("xmalloc.zig").allocator);

    const w = win.window_create(8, 3, T.DEFAULT_XPIXEL, T.DEFAULT_YPIXEL);
    defer {
        while (w.panes.items.len > 0) {
            const pane = w.panes.items[w.panes.items.len - 1];
            win.window_remove_pane(w, pane);
        }
        w.panes.deinit(@import("xmalloc.zig").allocator);
        w.last_panes.deinit(@import("xmalloc.zig").allocator);
        opts.options_free(w.options);
        @import("xmalloc.zig").allocator.free(w.name);
        _ = win.windows.remove(w.id);
        @import("xmalloc.zig").allocator.destroy(w);
    }

    const wp = win.window_add_pane(w, null, 8, 3);
    input_parse_screen(wp, "\x1b=\x1b[?1h\x1b[?1002h\x1b[?1006h\x1b[?2004h\x1b[>4;2m");

    const mode = screen_mod.screen_current(wp).mode;
    try std.testing.expect(mode & T.MODE_KKEYPAD != 0);
    try std.testing.expect(mode & T.MODE_KCURSOR != 0);
    try std.testing.expect(mode & T.MODE_MOUSE_BUTTON != 0);
    try std.testing.expect(mode & T.MODE_MOUSE_SGR != 0);
    try std.testing.expect(mode & T.MODE_BRACKETPASTE != 0);
    try std.testing.expect(mode & T.MODE_KEYS_EXTENDED_2 != 0);

    input_parse_screen(wp, "\x1b>\x1b[?1l\x1b[?1002l\x1b[?1006l\x1b[?2004l\x1b[>4m");
    const cleared = screen_mod.screen_current(wp).mode;
    try std.testing.expect(cleared & T.MODE_KKEYPAD == 0);
    try std.testing.expect(cleared & T.MODE_KCURSOR == 0);
    try std.testing.expect(cleared & T.MODE_MOUSE_BUTTON == 0);
    try std.testing.expect(cleared & T.MODE_MOUSE_SGR == 0);
    try std.testing.expect(cleared & T.MODE_BRACKETPASTE == 0);
    try std.testing.expect(cleared & T.EXTENDED_KEY_MODES == 0);
}

test "input handles VT, FF, SO, SI and MODE_CRLF" {
    const win = @import("window.zig");
    const grid = @import("grid.zig");

    opts.global_w_options = opts.options_create(null);
    defer opts.options_free(opts.global_w_options);
    opts.options_default_all(opts.global_w_options, T.OPTIONS_TABLE_WINDOW);
    win.window_init_globals(@import("xmalloc.zig").allocator);

    const w = win.window_create(8, 3, T.DEFAULT_XPIXEL, T.DEFAULT_YPIXEL);
    defer {
        while (w.panes.items.len > 0) {
            const pane = w.panes.items[w.panes.items.len - 1];
            win.window_remove_pane(w, pane);
        }
        w.panes.deinit(@import("xmalloc.zig").allocator);
        w.last_panes.deinit(@import("xmalloc.zig").allocator);
        opts.options_free(w.options);
        @import("xmalloc.zig").allocator.free(w.name);
        _ = win.windows.remove(w.id);
        @import("xmalloc.zig").allocator.destroy(w);
    }

    const wp = win.window_add_pane(w, null, 8, 3);

    // Write text, then VT should move down without carriage return
    input_parse_screen(wp, "AB\x0BCD");
    try std.testing.expectEqual(@as(u8, 'A'), grid.ascii_at(wp.base.grid, 0, 0));
    try std.testing.expectEqual(@as(u8, 'B'), grid.ascii_at(wp.base.grid, 0, 1));
    // VT without MODE_CRLF: cursor stays at column 2, moves to row 1
    try std.testing.expectEqual(@as(u8, 'C'), grid.ascii_at(wp.base.grid, 1, 2));
    try std.testing.expectEqual(@as(u8, 'D'), grid.ascii_at(wp.base.grid, 1, 3));

    // FF should also behave like LF (move down, stay in column)
    input_parse_screen(wp, "\x0CEF");
    try std.testing.expectEqual(@as(u8, 'E'), grid.ascii_at(wp.base.grid, 2, 4));
    try std.testing.expectEqual(@as(u8, 'F'), grid.ascii_at(wp.base.grid, 2, 5));

    // SO and SI should be silently consumed without corrupting output.
    input_parse_screen(wp, "\x0E\x0FGH");
    try std.testing.expectEqual(@as(u8, 'G'), grid.ascii_at(wp.base.grid, 2, 6));
    try std.testing.expectEqual(@as(u8, 'H'), grid.ascii_at(wp.base.grid, 2, 7));

    // MODE_CRLF: LF should do carriage return before newline
    screen_mod.screen_current(wp).mode |= T.MODE_CRLF;
    input_parse_screen(wp, "\nKL");
    try std.testing.expectEqual(@as(u8, ' '), grid.ascii_at(wp.base.grid, 0, 0)); // scrolled
    try std.testing.expectEqual(@as(u8, 'K'), grid.ascii_at(wp.base.grid, 2, 0));
    try std.testing.expectEqual(@as(u8, 'L'), grid.ascii_at(wp.base.grid, 2, 1));
}

test "input handles ACS charset selection ESC ( 0 / ESC ( B / ESC ) 0 / ESC ) B" {
    const win = @import("window.zig");

    opts.global_w_options = opts.options_create(null);
    defer opts.options_free(opts.global_w_options);
    opts.options_default_all(opts.global_w_options, T.OPTIONS_TABLE_WINDOW);
    win.window_init_globals(@import("xmalloc.zig").allocator);

    const w = win.window_create(8, 3, T.DEFAULT_XPIXEL, T.DEFAULT_YPIXEL);
    defer {
        while (w.panes.items.len > 0) {
            const pane = w.panes.items[w.panes.items.len - 1];
            win.window_remove_pane(w, pane);
        }
        w.panes.deinit(@import("xmalloc.zig").allocator);
        w.last_panes.deinit(@import("xmalloc.zig").allocator);
        opts.options_free(w.options);
        @import("xmalloc.zig").allocator.free(w.name);
        _ = win.windows.remove(w.id);
        @import("xmalloc.zig").allocator.destroy(w);
    }

    const wp = win.window_add_pane(w, null, 8, 3);
    const s = screen_mod.screen_current(wp);

    // Default: both G0 and G1 are ASCII (0)
    try std.testing.expectEqual(@as(u8, 0), s.g0set);
    try std.testing.expectEqual(@as(u8, 0), s.g1set);

    // ESC ( 0 — select DEC line drawing for G0
    input_parse_screen(wp, "\x1b(0");
    try std.testing.expectEqual(@as(u8, 1), s.g0set);
    try std.testing.expectEqual(@as(u8, 0), s.g1set);

    // ESC ( B — select ASCII for G0
    input_parse_screen(wp, "\x1b(B");
    try std.testing.expectEqual(@as(u8, 0), s.g0set);
    try std.testing.expectEqual(@as(u8, 0), s.g1set);

    // ESC ) 0 — select DEC line drawing for G1
    input_parse_screen(wp, "\x1b)0");
    try std.testing.expectEqual(@as(u8, 0), s.g0set);
    try std.testing.expectEqual(@as(u8, 1), s.g1set);

    // ESC ) B — select ASCII for G1
    input_parse_screen(wp, "\x1b)B");
    try std.testing.expectEqual(@as(u8, 0), s.g0set);
    try std.testing.expectEqual(@as(u8, 0), s.g1set);

    // Verify no pending bytes remain
    try std.testing.expectEqual(@as(usize, 0), wp.input_pending.items.len);
}

test "input DECSCUSR sets cursor style and blinking mode" {
    const win = @import("window.zig");

    opts.global_w_options = opts.options_create(null);
    defer opts.options_free(opts.global_w_options);
    opts.options_default_all(opts.global_w_options, T.OPTIONS_TABLE_WINDOW);
    win.window_init_globals(@import("xmalloc.zig").allocator);

    const w = win.window_create(8, 3, T.DEFAULT_XPIXEL, T.DEFAULT_YPIXEL);
    defer {
        while (w.panes.items.len > 0) {
            const pane = w.panes.items[w.panes.items.len - 1];
            win.window_remove_pane(w, pane);
        }
        w.panes.deinit(@import("xmalloc.zig").allocator);
        w.last_panes.deinit(@import("xmalloc.zig").allocator);
        opts.options_free(w.options);
        @import("xmalloc.zig").allocator.free(w.name);
        _ = win.windows.remove(w.id);
        @import("xmalloc.zig").allocator.destroy(w);
    }

    const wp = win.window_add_pane(w, null, 8, 3);
    const s = screen_mod.screen_current(wp);

    // CSI 1 SP q — blinking block
    input_parse_screen(wp, "\x1b[1 q");
    try std.testing.expect(s.cstyle == .block);
    try std.testing.expect(s.mode & T.MODE_CURSOR_BLINKING != 0);

    // CSI 2 SP q — steady block
    input_parse_screen(wp, "\x1b[2 q");
    try std.testing.expect(s.cstyle == .block);
    try std.testing.expect(s.mode & T.MODE_CURSOR_BLINKING == 0);

    // CSI 3 SP q — blinking underline
    input_parse_screen(wp, "\x1b[3 q");
    try std.testing.expect(s.cstyle == .underline);
    try std.testing.expect(s.mode & T.MODE_CURSOR_BLINKING != 0);

    // CSI 4 SP q — steady underline
    input_parse_screen(wp, "\x1b[4 q");
    try std.testing.expect(s.cstyle == .underline);
    try std.testing.expect(s.mode & T.MODE_CURSOR_BLINKING == 0);

    // CSI 5 SP q — blinking bar
    input_parse_screen(wp, "\x1b[5 q");
    try std.testing.expect(s.cstyle == .bar);
    try std.testing.expect(s.mode & T.MODE_CURSOR_BLINKING != 0);

    // CSI 6 SP q — steady bar
    input_parse_screen(wp, "\x1b[6 q");
    try std.testing.expect(s.cstyle == .bar);
    try std.testing.expect(s.mode & T.MODE_CURSOR_BLINKING == 0);

    // CSI 0 SP q — reset to default
    input_parse_screen(wp, "\x1b[0 q");
    try std.testing.expect(s.cstyle == .default);
    try std.testing.expect(s.mode & T.MODE_CURSOR_BLINKING_SET == 0);
}

test "input handles ESC # 8 DECALN alignment test" {
    const win = @import("window.zig");
    const grid = @import("grid.zig");

    opts.global_w_options = opts.options_create(null);
    defer opts.options_free(opts.global_w_options);
    opts.options_default_all(opts.global_w_options, T.OPTIONS_TABLE_WINDOW);
    win.window_init_globals(@import("xmalloc.zig").allocator);

    const w = win.window_create(4, 2, T.DEFAULT_XPIXEL, T.DEFAULT_YPIXEL);
    defer {
        while (w.panes.items.len > 0) {
            const pane = w.panes.items[w.panes.items.len - 1];
            win.window_remove_pane(w, pane);
        }
        w.panes.deinit(@import("xmalloc.zig").allocator);
        w.last_panes.deinit(@import("xmalloc.zig").allocator);
        opts.options_free(w.options);
        @import("xmalloc.zig").allocator.free(w.name);
        _ = win.windows.remove(w.id);
        @import("xmalloc.zig").allocator.destroy(w);
    }

    const wp = win.window_add_pane(w, null, 4, 2);

    // Write some initial content, then run DECALN
    input_parse_screen(wp, "ABCD");
    try std.testing.expectEqual(@as(u8, 'A'), grid.ascii_at(wp.base.grid, 0, 0));
    try std.testing.expectEqual(@as(u8, 'D'), grid.ascii_at(wp.base.grid, 0, 3));

    // ESC # 8 fills screen with 'E'
    input_parse_screen(wp, "\x1b#8");
    try std.testing.expectEqual(@as(u8, 'E'), grid.ascii_at(wp.base.grid, 0, 0));
    try std.testing.expectEqual(@as(u8, 'E'), grid.ascii_at(wp.base.grid, 0, 3));
    try std.testing.expectEqual(@as(u8, 'E'), grid.ascii_at(wp.base.grid, 1, 0));
    try std.testing.expectEqual(@as(u8, 'E'), grid.ascii_at(wp.base.grid, 1, 3));

    // Cursor should be reset to 0,0
    const s = screen_mod.screen_current(wp);
    try std.testing.expectEqual(@as(u32, 0), s.cx);
    try std.testing.expectEqual(@as(u32, 0), s.cy);
}

test "input keeps incomplete ESC ( sequence pending" {
    const win = @import("window.zig");

    opts.global_w_options = opts.options_create(null);
    defer opts.options_free(opts.global_w_options);
    opts.options_default_all(opts.global_w_options, T.OPTIONS_TABLE_WINDOW);
    win.window_init_globals(@import("xmalloc.zig").allocator);

    const w = win.window_create(4, 2, T.DEFAULT_XPIXEL, T.DEFAULT_YPIXEL);
    defer {
        while (w.panes.items.len > 0) {
            const pane = w.panes.items[w.panes.items.len - 1];
            win.window_remove_pane(w, pane);
        }
        w.panes.deinit(@import("xmalloc.zig").allocator);
        w.last_panes.deinit(@import("xmalloc.zig").allocator);
        opts.options_free(w.options);
        @import("xmalloc.zig").allocator.free(w.name);
        _ = win.windows.remove(w.id);
        @import("xmalloc.zig").allocator.destroy(w);
    }

    const wp = win.window_add_pane(w, null, 4, 2);

    // Send ESC ( without the third byte — should stay pending
    input_parse_screen(wp, "\x1b(");
    try std.testing.expectEqual(@as(usize, 2), wp.input_pending.items.len);

    // Complete the sequence
    input_parse_screen(wp, "0");
    try std.testing.expectEqual(@as(usize, 0), wp.input_pending.items.len);
    const s2 = screen_mod.screen_current(wp);
    try std.testing.expectEqual(@as(u8, 1), s2.g0set);

    // Same for ESC # without third byte
    input_parse_screen(wp, "\x1b#");
    try std.testing.expectEqual(@as(usize, 2), wp.input_pending.items.len);
    input_parse_screen(wp, "8");
    try std.testing.expectEqual(@as(usize, 0), wp.input_pending.items.len);
}

test "input swallows OSC 4 palette set without crashing" {
    const win = @import("window.zig");
    const grid = @import("grid.zig");

    opts.global_w_options = opts.options_create(null);
    defer opts.options_free(opts.global_w_options);
    opts.options_default_all(opts.global_w_options, T.OPTIONS_TABLE_WINDOW);
    win.window_init_globals(@import("xmalloc.zig").allocator);

    const w = win.window_create(8, 3, T.DEFAULT_XPIXEL, T.DEFAULT_YPIXEL);
    defer {
        while (w.panes.items.len > 0) {
            const pane = w.panes.items[w.panes.items.len - 1];
            win.window_remove_pane(w, pane);
        }
        w.panes.deinit(@import("xmalloc.zig").allocator);
        w.last_panes.deinit(@import("xmalloc.zig").allocator);
        opts.options_free(w.options);
        @import("xmalloc.zig").allocator.free(w.name);
        _ = win.windows.remove(w.id);
        @import("xmalloc.zig").allocator.destroy(w);
    }

    const wp = win.window_add_pane(w, null, 8, 3);
    // OSC 4 ; 1 ; #rrggbb — should be swallowed without crashing
    input_parse_screen(wp, "\x1b]4;1;#ff0000\x07");
    // Verify normal operation continues after
    input_parse_screen(wp, "OK");
    try std.testing.expectEqual(@as(u8, 'O'), grid.ascii_at(wp.base.grid, 0, 0));
    try std.testing.expectEqual(@as(u8, 'K'), grid.ascii_at(wp.base.grid, 0, 1));
}

test "input handles OSC 8 hyperlink open and close" {
    const win = @import("window.zig");
    const hl_mod = @import("hyperlinks.zig");

    opts.global_w_options = opts.options_create(null);
    defer opts.options_free(opts.global_w_options);
    opts.options_default_all(opts.global_w_options, T.OPTIONS_TABLE_WINDOW);
    win.window_init_globals(@import("xmalloc.zig").allocator);

    const w = win.window_create(8, 3, T.DEFAULT_XPIXEL, T.DEFAULT_YPIXEL);
    defer {
        while (w.panes.items.len > 0) {
            const pane = w.panes.items[w.panes.items.len - 1];
            win.window_remove_pane(w, pane);
        }
        w.panes.deinit(@import("xmalloc.zig").allocator);
        w.last_panes.deinit(@import("xmalloc.zig").allocator);
        opts.options_free(w.options);
        @import("xmalloc.zig").allocator.free(w.name);
        _ = win.windows.remove(w.id);
        @import("xmalloc.zig").allocator.destroy(w);
    }

    const wp = win.window_add_pane(w, null, 8, 3);
    const s = screen_mod.screen_current(wp);

    // Set up hyperlink table on the screen
    s.hyperlinks = hl_mod.hyperlinks_init();
    defer {
        if (s.hyperlinks) |hl| hl_mod.hyperlinks_free(hl);
    }

    // Open a hyperlink with id and URI
    input_parse_screen(wp, "\x1b]8;id=mylink;https://example.com\x07");
    // The saved_cell.link should be set to a non-zero value
    try std.testing.expect(s.saved_cell.link != 0);

    // Close the hyperlink (empty URI)
    input_parse_screen(wp, "\x1b]8;;\x07");
    try std.testing.expectEqual(@as(u32, 0), s.saved_cell.link);
}

test "input swallows OSC 10/11/12 colour sequences" {
    const win = @import("window.zig");
    const grid = @import("grid.zig");

    opts.global_w_options = opts.options_create(null);
    defer opts.options_free(opts.global_w_options);
    opts.options_default_all(opts.global_w_options, T.OPTIONS_TABLE_WINDOW);
    win.window_init_globals(@import("xmalloc.zig").allocator);

    const w = win.window_create(8, 3, T.DEFAULT_XPIXEL, T.DEFAULT_YPIXEL);
    defer {
        while (w.panes.items.len > 0) {
            const pane = w.panes.items[w.panes.items.len - 1];
            win.window_remove_pane(w, pane);
        }
        w.panes.deinit(@import("xmalloc.zig").allocator);
        w.last_panes.deinit(@import("xmalloc.zig").allocator);
        opts.options_free(w.options);
        @import("xmalloc.zig").allocator.free(w.name);
        _ = win.windows.remove(w.id);
        @import("xmalloc.zig").allocator.destroy(w);
    }

    const wp = win.window_add_pane(w, null, 8, 3);
    // OSC 10 — set foreground colour (swallow)
    input_parse_screen(wp, "\x1b]10;#aabbcc\x07");
    // OSC 11 — set background colour (swallow)
    input_parse_screen(wp, "\x1b]11;#112233\x07");
    // OSC 12 — set cursor colour (swallow)
    input_parse_screen(wp, "\x1b]12;#ddeeff\x07");
    // Verify normal operation continues
    input_parse_screen(wp, "XY");
    try std.testing.expectEqual(@as(u8, 'X'), grid.ascii_at(wp.base.grid, 0, 0));
    try std.testing.expectEqual(@as(u8, 'Y'), grid.ascii_at(wp.base.grid, 0, 1));
}

test "input swallows OSC 52 clipboard and OSC 104 palette reset" {
    const win = @import("window.zig");
    const grid = @import("grid.zig");

    opts.global_w_options = opts.options_create(null);
    defer opts.options_free(opts.global_w_options);
    opts.options_default_all(opts.global_w_options, T.OPTIONS_TABLE_WINDOW);
    win.window_init_globals(@import("xmalloc.zig").allocator);

    const w = win.window_create(8, 3, T.DEFAULT_XPIXEL, T.DEFAULT_YPIXEL);
    defer {
        while (w.panes.items.len > 0) {
            const pane = w.panes.items[w.panes.items.len - 1];
            win.window_remove_pane(w, pane);
        }
        w.panes.deinit(@import("xmalloc.zig").allocator);
        w.last_panes.deinit(@import("xmalloc.zig").allocator);
        opts.options_free(w.options);
        @import("xmalloc.zig").allocator.free(w.name);
        _ = win.windows.remove(w.id);
        @import("xmalloc.zig").allocator.destroy(w);
    }

    const wp = win.window_add_pane(w, null, 8, 3);
    // OSC 52 — clipboard (swallow)
    input_parse_screen(wp, "\x1b]52;c;SGVsbG8=\x07");
    // OSC 104 — palette reset (swallow)
    input_parse_screen(wp, "\x1b]104;1\x07");
    // Verify normal operation continues
    input_parse_screen(wp, "AB");
    try std.testing.expectEqual(@as(u8, 'A'), grid.ascii_at(wp.base.grid, 0, 0));
    try std.testing.expectEqual(@as(u8, 'B'), grid.ascii_at(wp.base.grid, 0, 1));
}

test "input swallows OSC 110/111/112 colour resets" {
    const win = @import("window.zig");
    const grid = @import("grid.zig");

    opts.global_w_options = opts.options_create(null);
    defer opts.options_free(opts.global_w_options);
    opts.options_default_all(opts.global_w_options, T.OPTIONS_TABLE_WINDOW);
    win.window_init_globals(@import("xmalloc.zig").allocator);

    const w = win.window_create(8, 3, T.DEFAULT_XPIXEL, T.DEFAULT_YPIXEL);
    defer {
        while (w.panes.items.len > 0) {
            const pane = w.panes.items[w.panes.items.len - 1];
            win.window_remove_pane(w, pane);
        }
        w.panes.deinit(@import("xmalloc.zig").allocator);
        w.last_panes.deinit(@import("xmalloc.zig").allocator);
        opts.options_free(w.options);
        @import("xmalloc.zig").allocator.free(w.name);
        _ = win.windows.remove(w.id);
        @import("xmalloc.zig").allocator.destroy(w);
    }

    const wp = win.window_add_pane(w, null, 8, 3);
    // OSC 110 — reset foreground (swallow)
    input_parse_screen(wp, "\x1b]110\x07");
    // OSC 111 — reset background (swallow)
    input_parse_screen(wp, "\x1b]111\x07");
    // OSC 112 — reset cursor colour (swallow)
    input_parse_screen(wp, "\x1b]112\x07");
    // Verify normal operation continues
    input_parse_screen(wp, "CD");
    try std.testing.expectEqual(@as(u8, 'C'), grid.ascii_at(wp.base.grid, 0, 0));
    try std.testing.expectEqual(@as(u8, 'D'), grid.ascii_at(wp.base.grid, 0, 1));
}

test "input swallows OSC 133 semantic prompt markers" {
    const win = @import("window.zig");
    const grid = @import("grid.zig");

    opts.global_w_options = opts.options_create(null);
    defer opts.options_free(opts.global_w_options);
    opts.options_default_all(opts.global_w_options, T.OPTIONS_TABLE_WINDOW);
    win.window_init_globals(@import("xmalloc.zig").allocator);

    const w = win.window_create(8, 3, T.DEFAULT_XPIXEL, T.DEFAULT_YPIXEL);
    defer {
        while (w.panes.items.len > 0) {
            const pane = w.panes.items[w.panes.items.len - 1];
            win.window_remove_pane(w, pane);
        }
        w.panes.deinit(@import("xmalloc.zig").allocator);
        w.last_panes.deinit(@import("xmalloc.zig").allocator);
        opts.options_free(w.options);
        @import("xmalloc.zig").allocator.free(w.name);
        _ = win.windows.remove(w.id);
        @import("xmalloc.zig").allocator.destroy(w);
    }

    const wp = win.window_add_pane(w, null, 8, 3);
    // OSC 133 ; A — prompt start marker
    input_parse_screen(wp, "\x1b]133;A\x07");
    // OSC 133 ; B — command start marker
    input_parse_screen(wp, "\x1b]133;B\x07");
    // OSC 133 ; C — command output start marker
    input_parse_screen(wp, "\x1b]133;C\x07");
    // OSC 133 ; D — command output end marker
    input_parse_screen(wp, "\x1b]133;D\x07");
    // Verify normal operation continues
    input_parse_screen(wp, "EF");
    try std.testing.expectEqual(@as(u8, 'E'), grid.ascii_at(wp.base.grid, 0, 0));
    try std.testing.expectEqual(@as(u8, 'F'), grid.ascii_at(wp.base.grid, 0, 1));
}

test "input CSI t winops and CSI > c DA2 are consumed without error" {
    const win = @import("window.zig");
    const grid = @import("grid.zig");

    opts.global_w_options = opts.options_create(null);
    defer opts.options_free(opts.global_w_options);
    opts.options_default_all(opts.global_w_options, T.OPTIONS_TABLE_WINDOW);
    win.window_init_globals(@import("xmalloc.zig").allocator);

    const w = win.window_create(8, 3, T.DEFAULT_XPIXEL, T.DEFAULT_YPIXEL);
    defer {
        while (w.panes.items.len > 0) {
            const pane = w.panes.items[w.panes.items.len - 1];
            win.window_remove_pane(w, pane);
        }
        w.panes.deinit(@import("xmalloc.zig").allocator);
        w.last_panes.deinit(@import("xmalloc.zig").allocator);
        opts.options_free(w.options);
        @import("xmalloc.zig").allocator.free(w.name);
        _ = win.windows.remove(w.id);
        @import("xmalloc.zig").allocator.destroy(w);
    }

    const wp = win.window_add_pane(w, null, 8, 3);

    // Write text, then send CSI t sequences — they should be consumed cleanly
    input_parse_screen(wp, "AB\x1b[14tCD");
    try std.testing.expectEqual(@as(u8, 'A'), grid.ascii_at(wp.base.grid, 0, 0));
    try std.testing.expectEqual(@as(u8, 'B'), grid.ascii_at(wp.base.grid, 0, 1));
    try std.testing.expectEqual(@as(u8, 'C'), grid.ascii_at(wp.base.grid, 0, 2));
    try std.testing.expectEqual(@as(u8, 'D'), grid.ascii_at(wp.base.grid, 0, 3));
    try std.testing.expectEqual(@as(usize, 0), wp.input_pending.items.len);

    // CSI 18 t — report text area size in chars
    input_parse_screen(wp, "\x1b[18t");
    try std.testing.expectEqual(@as(usize, 0), wp.input_pending.items.len);

    // CSI 21 t — report window title
    input_parse_screen(wp, "\x1b[21t");
    try std.testing.expectEqual(@as(usize, 0), wp.input_pending.items.len);

    // CSI > c — DA2 secondary device attributes
    input_parse_screen(wp, "\x1b[>c");
    try std.testing.expectEqual(@as(usize, 0), wp.input_pending.items.len);
}

test "input DCS is consumed cleanly and does not corrupt output" {
    const win = @import("window.zig");
    const grid = @import("grid.zig");

    opts.global_w_options = opts.options_create(null);
    defer opts.options_free(opts.global_w_options);
    opts.options_default_all(opts.global_w_options, T.OPTIONS_TABLE_WINDOW);
    win.window_init_globals(@import("xmalloc.zig").allocator);

    const w = win.window_create(8, 3, T.DEFAULT_XPIXEL, T.DEFAULT_YPIXEL);
    defer {
        while (w.panes.items.len > 0) {
            const pane = w.panes.items[w.panes.items.len - 1];
            win.window_remove_pane(w, pane);
        }
        w.panes.deinit(@import("xmalloc.zig").allocator);
        w.last_panes.deinit(@import("xmalloc.zig").allocator);
        opts.options_free(w.options);
        @import("xmalloc.zig").allocator.free(w.name);
        _ = win.windows.remove(w.id);
        @import("xmalloc.zig").allocator.destroy(w);
    }

    const wp = win.window_add_pane(w, null, 8, 3);

    // Basic DCS: ESC P data ESC \
    input_parse_screen(wp, "AB\x1bPsome-dcs-data\x1b\\CD");
    try std.testing.expectEqual(@as(u8, 'A'), grid.ascii_at(wp.base.grid, 0, 0));
    try std.testing.expectEqual(@as(u8, 'B'), grid.ascii_at(wp.base.grid, 0, 1));
    try std.testing.expectEqual(@as(u8, 'C'), grid.ascii_at(wp.base.grid, 0, 2));
    try std.testing.expectEqual(@as(u8, 'D'), grid.ascii_at(wp.base.grid, 0, 3));
    try std.testing.expectEqual(@as(usize, 0), wp.input_pending.items.len);
}

test "input DCS with parameters is consumed cleanly" {
    const win = @import("window.zig");
    const grid = @import("grid.zig");

    opts.global_w_options = opts.options_create(null);
    defer opts.options_free(opts.global_w_options);
    opts.options_default_all(opts.global_w_options, T.OPTIONS_TABLE_WINDOW);
    win.window_init_globals(@import("xmalloc.zig").allocator);

    const w = win.window_create(8, 3, T.DEFAULT_XPIXEL, T.DEFAULT_YPIXEL);
    defer {
        while (w.panes.items.len > 0) {
            const pane = w.panes.items[w.panes.items.len - 1];
            win.window_remove_pane(w, pane);
        }
        w.panes.deinit(@import("xmalloc.zig").allocator);
        w.last_panes.deinit(@import("xmalloc.zig").allocator);
        opts.options_free(w.options);
        @import("xmalloc.zig").allocator.free(w.name);
        _ = win.windows.remove(w.id);
        @import("xmalloc.zig").allocator.destroy(w);
    }

    const wp = win.window_add_pane(w, null, 8, 3);

    // DCS with numeric parameters: ESC P 1;2 data ESC \
    input_parse_screen(wp, "\x1bP1;2somedata\x1b\\XY");
    try std.testing.expectEqual(@as(u8, 'X'), grid.ascii_at(wp.base.grid, 0, 0));
    try std.testing.expectEqual(@as(u8, 'Y'), grid.ascii_at(wp.base.grid, 0, 1));
    try std.testing.expectEqual(@as(usize, 0), wp.input_pending.items.len);
}

test "input DCS with intermediate byte is consumed cleanly" {
    const win = @import("window.zig");
    const grid = @import("grid.zig");

    opts.global_w_options = opts.options_create(null);
    defer opts.options_free(opts.global_w_options);
    opts.options_default_all(opts.global_w_options, T.OPTIONS_TABLE_WINDOW);
    win.window_init_globals(@import("xmalloc.zig").allocator);

    const w = win.window_create(8, 3, T.DEFAULT_XPIXEL, T.DEFAULT_YPIXEL);
    defer {
        while (w.panes.items.len > 0) {
            const pane = w.panes.items[w.panes.items.len - 1];
            win.window_remove_pane(w, pane);
        }
        w.panes.deinit(@import("xmalloc.zig").allocator);
        w.last_panes.deinit(@import("xmalloc.zig").allocator);
        opts.options_free(w.options);
        @import("xmalloc.zig").allocator.free(w.name);
        _ = win.windows.remove(w.id);
        @import("xmalloc.zig").allocator.destroy(w);
    }

    const wp = win.window_add_pane(w, null, 8, 3);

    // DCS with '$' intermediate (DECRQSS): ESC P $ q Pt ST
    input_parse_screen(wp, "AB\x1bP$q q\x1b\\CD");
    try std.testing.expectEqual(@as(u8, 'A'), grid.ascii_at(wp.base.grid, 0, 0));
    try std.testing.expectEqual(@as(u8, 'B'), grid.ascii_at(wp.base.grid, 0, 1));
    try std.testing.expectEqual(@as(u8, 'C'), grid.ascii_at(wp.base.grid, 0, 2));
    try std.testing.expectEqual(@as(u8, 'D'), grid.ascii_at(wp.base.grid, 0, 3));
    try std.testing.expectEqual(@as(usize, 0), wp.input_pending.items.len);
}

test "input DCS with colon is ignored and consumed cleanly" {
    const win = @import("window.zig");
    const grid = @import("grid.zig");

    opts.global_w_options = opts.options_create(null);
    defer opts.options_free(opts.global_w_options);
    opts.options_default_all(opts.global_w_options, T.OPTIONS_TABLE_WINDOW);
    win.window_init_globals(@import("xmalloc.zig").allocator);

    const w = win.window_create(8, 3, T.DEFAULT_XPIXEL, T.DEFAULT_YPIXEL);
    defer {
        while (w.panes.items.len > 0) {
            const pane = w.panes.items[w.panes.items.len - 1];
            win.window_remove_pane(w, pane);
        }
        w.panes.deinit(@import("xmalloc.zig").allocator);
        w.last_panes.deinit(@import("xmalloc.zig").allocator);
        opts.options_free(w.options);
        @import("xmalloc.zig").allocator.free(w.name);
        _ = win.windows.remove(w.id);
        @import("xmalloc.zig").allocator.destroy(w);
    }

    const wp = win.window_add_pane(w, null, 8, 3);

    // DCS with colon in params should be ignored (tmux: dcs_ignore state)
    input_parse_screen(wp, "\x1bP1:2ignored\x1b\\OK");
    try std.testing.expectEqual(@as(u8, 'O'), grid.ascii_at(wp.base.grid, 0, 0));
    try std.testing.expectEqual(@as(u8, 'K'), grid.ascii_at(wp.base.grid, 0, 1));
    try std.testing.expectEqual(@as(usize, 0), wp.input_pending.items.len);
}

test "input DCS with BEL terminator is consumed cleanly" {
    const win = @import("window.zig");
    const grid = @import("grid.zig");

    opts.global_w_options = opts.options_create(null);
    defer opts.options_free(opts.global_w_options);
    opts.options_default_all(opts.global_w_options, T.OPTIONS_TABLE_WINDOW);
    win.window_init_globals(@import("xmalloc.zig").allocator);

    const w = win.window_create(8, 3, T.DEFAULT_XPIXEL, T.DEFAULT_YPIXEL);
    defer {
        while (w.panes.items.len > 0) {
            const pane = w.panes.items[w.panes.items.len - 1];
            win.window_remove_pane(w, pane);
        }
        w.panes.deinit(@import("xmalloc.zig").allocator);
        w.last_panes.deinit(@import("xmalloc.zig").allocator);
        opts.options_free(w.options);
        @import("xmalloc.zig").allocator.free(w.name);
        _ = win.windows.remove(w.id);
        @import("xmalloc.zig").allocator.destroy(w);
    }

    const wp = win.window_add_pane(w, null, 8, 3);

    // DCS terminated by BEL
    input_parse_screen(wp, "\x1bPdata\x07AB");
    try std.testing.expectEqual(@as(u8, 'A'), grid.ascii_at(wp.base.grid, 0, 0));
    try std.testing.expectEqual(@as(u8, 'B'), grid.ascii_at(wp.base.grid, 0, 1));
    try std.testing.expectEqual(@as(usize, 0), wp.input_pending.items.len);
}

test "input DCS keeps incomplete sequence pending across calls" {
    const win = @import("window.zig");
    const grid = @import("grid.zig");

    opts.global_w_options = opts.options_create(null);
    defer opts.options_free(opts.global_w_options);
    opts.options_default_all(opts.global_w_options, T.OPTIONS_TABLE_WINDOW);
    win.window_init_globals(@import("xmalloc.zig").allocator);

    const w = win.window_create(8, 3, T.DEFAULT_XPIXEL, T.DEFAULT_YPIXEL);
    defer {
        while (w.panes.items.len > 0) {
            const pane = w.panes.items[w.panes.items.len - 1];
            win.window_remove_pane(w, pane);
        }
        w.panes.deinit(@import("xmalloc.zig").allocator);
        w.last_panes.deinit(@import("xmalloc.zig").allocator);
        opts.options_free(w.options);
        @import("xmalloc.zig").allocator.free(w.name);
        _ = win.windows.remove(w.id);
        @import("xmalloc.zig").allocator.destroy(w);
    }

    const wp = win.window_add_pane(w, null, 8, 3);

    // Send incomplete DCS
    input_parse_screen(wp, "\x1bP1;2partial");
    try std.testing.expect(wp.input_pending.items.len > 0);

    // Complete it
    input_parse_screen(wp, "data\x1b\\OK");
    try std.testing.expectEqual(@as(u8, 'O'), grid.ascii_at(wp.base.grid, 0, 0));
    try std.testing.expectEqual(@as(u8, 'K'), grid.ascii_at(wp.base.grid, 0, 1));
    try std.testing.expectEqual(@as(usize, 0), wp.input_pending.items.len);
}

test "input DCS with embedded ESC in data is consumed correctly" {
    const win = @import("window.zig");
    const grid = @import("grid.zig");

    opts.global_w_options = opts.options_create(null);
    defer opts.options_free(opts.global_w_options);
    opts.options_default_all(opts.global_w_options, T.OPTIONS_TABLE_WINDOW);
    win.window_init_globals(@import("xmalloc.zig").allocator);

    const w = win.window_create(8, 3, T.DEFAULT_XPIXEL, T.DEFAULT_YPIXEL);
    defer {
        while (w.panes.items.len > 0) {
            const pane = w.panes.items[w.panes.items.len - 1];
            win.window_remove_pane(w, pane);
        }
        w.panes.deinit(@import("xmalloc.zig").allocator);
        w.last_panes.deinit(@import("xmalloc.zig").allocator);
        opts.options_free(w.options);
        @import("xmalloc.zig").allocator.free(w.name);
        _ = win.windows.remove(w.id);
        @import("xmalloc.zig").allocator.destroy(w);
    }

    const wp = win.window_add_pane(w, null, 8, 3);

    // DCS data containing an ESC that is NOT followed by '\' — should be
    // treated as part of the payload (tmux's dcs_handler allows ESC inside).
    input_parse_screen(wp, "\x1bPdata\x1bXmore\x1b\\AB");
    try std.testing.expectEqual(@as(u8, 'A'), grid.ascii_at(wp.base.grid, 0, 0));
    try std.testing.expectEqual(@as(u8, 'B'), grid.ascii_at(wp.base.grid, 0, 1));
    try std.testing.expectEqual(@as(usize, 0), wp.input_pending.items.len);
}

test "input APC is consumed cleanly" {
    const win = @import("window.zig");
    const grid = @import("grid.zig");

    opts.global_w_options = opts.options_create(null);
    defer opts.options_free(opts.global_w_options);
    opts.options_default_all(opts.global_w_options, T.OPTIONS_TABLE_WINDOW);
    win.window_init_globals(@import("xmalloc.zig").allocator);

    const w = win.window_create(8, 3, T.DEFAULT_XPIXEL, T.DEFAULT_YPIXEL);
    defer {
        while (w.panes.items.len > 0) {
            const pane = w.panes.items[w.panes.items.len - 1];
            win.window_remove_pane(w, pane);
        }
        w.panes.deinit(@import("xmalloc.zig").allocator);
        w.last_panes.deinit(@import("xmalloc.zig").allocator);
        opts.options_free(w.options);
        @import("xmalloc.zig").allocator.free(w.name);
        _ = win.windows.remove(w.id);
        @import("xmalloc.zig").allocator.destroy(w);
    }

    const wp = win.window_add_pane(w, null, 8, 3);

    // Basic APC: ESC _ data ESC \
    input_parse_screen(wp, "AB\x1b_some-apc-data\x1b\\CD");
    try std.testing.expectEqual(@as(u8, 'A'), grid.ascii_at(wp.base.grid, 0, 0));
    try std.testing.expectEqual(@as(u8, 'B'), grid.ascii_at(wp.base.grid, 0, 1));
    try std.testing.expectEqual(@as(u8, 'C'), grid.ascii_at(wp.base.grid, 0, 2));
    try std.testing.expectEqual(@as(u8, 'D'), grid.ascii_at(wp.base.grid, 0, 3));
    try std.testing.expectEqual(@as(usize, 0), wp.input_pending.items.len);
}

test "input APC keeps incomplete sequence pending across calls" {
    const win = @import("window.zig");
    const grid = @import("grid.zig");

    opts.global_w_options = opts.options_create(null);
    defer opts.options_free(opts.global_w_options);
    opts.options_default_all(opts.global_w_options, T.OPTIONS_TABLE_WINDOW);
    win.window_init_globals(@import("xmalloc.zig").allocator);

    const w = win.window_create(8, 3, T.DEFAULT_XPIXEL, T.DEFAULT_YPIXEL);
    defer {
        while (w.panes.items.len > 0) {
            const pane = w.panes.items[w.panes.items.len - 1];
            win.window_remove_pane(w, pane);
        }
        w.panes.deinit(@import("xmalloc.zig").allocator);
        w.last_panes.deinit(@import("xmalloc.zig").allocator);
        opts.options_free(w.options);
        @import("xmalloc.zig").allocator.free(w.name);
        _ = win.windows.remove(w.id);
        @import("xmalloc.zig").allocator.destroy(w);
    }

    const wp = win.window_add_pane(w, null, 8, 3);

    // Send incomplete APC
    input_parse_screen(wp, "\x1b_partial");
    try std.testing.expect(wp.input_pending.items.len > 0);

    // Complete it
    input_parse_screen(wp, "apc\x1b\\OK");
    try std.testing.expectEqual(@as(u8, 'O'), grid.ascii_at(wp.base.grid, 0, 0));
    try std.testing.expectEqual(@as(u8, 'K'), grid.ascii_at(wp.base.grid, 0, 1));
    try std.testing.expectEqual(@as(usize, 0), wp.input_pending.items.len);
}

test "input APC with BEL terminator is consumed cleanly" {
    const win = @import("window.zig");
    const grid = @import("grid.zig");

    opts.global_w_options = opts.options_create(null);
    defer opts.options_free(opts.global_w_options);
    opts.options_default_all(opts.global_w_options, T.OPTIONS_TABLE_WINDOW);
    win.window_init_globals(@import("xmalloc.zig").allocator);

    const w = win.window_create(8, 3, T.DEFAULT_XPIXEL, T.DEFAULT_YPIXEL);
    defer {
        while (w.panes.items.len > 0) {
            const pane = w.panes.items[w.panes.items.len - 1];
            win.window_remove_pane(w, pane);
        }
        w.panes.deinit(@import("xmalloc.zig").allocator);
        w.last_panes.deinit(@import("xmalloc.zig").allocator);
        opts.options_free(w.options);
        @import("xmalloc.zig").allocator.free(w.name);
        _ = win.windows.remove(w.id);
        @import("xmalloc.zig").allocator.destroy(w);
    }

    const wp = win.window_add_pane(w, null, 8, 3);

    // APC terminated by BEL
    input_parse_screen(wp, "\x1b_apc-data\x07AB");
    try std.testing.expectEqual(@as(u8, 'A'), grid.ascii_at(wp.base.grid, 0, 0));
    try std.testing.expectEqual(@as(u8, 'B'), grid.ascii_at(wp.base.grid, 0, 1));
    try std.testing.expectEqual(@as(usize, 0), wp.input_pending.items.len);
}

test "input DCS parsed structure has correct params interm and data" {
    const testing = std.testing;

    // Simple DCS: ESC P data ST
    const seq1 = "\x1bPhello\x1b\\";
    const dcs1 = (parse_dcs_structured(seq1)).?;
    try testing.expectEqual(@as(usize, 9), dcs1.consumed);
    try testing.expectEqualStrings("", dcs1.params);
    try testing.expectEqualStrings("", dcs1.interm);
    try testing.expectEqualStrings("hello", dcs1.data);

    // DCS with params: ESC P 1;2 data ST
    const seq2 = "\x1bP1;2data\x1b\\";
    const dcs2 = (parse_dcs_structured(seq2)).?;
    try testing.expectEqualStrings("1;2", dcs2.params);
    try testing.expectEqualStrings("", dcs2.interm);
    try testing.expectEqualStrings("data", dcs2.data);

    // DCS with intermediate: ESC P $ q Pt ST
    const seq3 = "\x1bP$q q\x1b\\";
    const dcs3 = (parse_dcs_structured(seq3)).?;
    try testing.expectEqualStrings("", dcs3.params);
    try testing.expectEqualStrings("$", dcs3.interm);
    try testing.expectEqualStrings("q q", dcs3.data);

    // DCS with params and intermediate
    const seq4 = "\x1bP1;$x\x1b\\";
    const dcs4 = (parse_dcs_structured(seq4)).?;
    try testing.expectEqualStrings("1;", dcs4.params);
    try testing.expectEqualStrings("$", dcs4.interm);
    try testing.expectEqualStrings("x", dcs4.data);

    // DCS with colon (should be ignored)
    const seq5 = "\x1bP1:2bad\x1b\\";
    const dcs5 = (parse_dcs_structured(seq5)).?;
    try testing.expectEqualStrings("", dcs5.params);
    try testing.expectEqualStrings("", dcs5.interm);
    try testing.expectEqualStrings("", dcs5.data);
    try testing.expectEqual(@as(usize, seq5.len), dcs5.consumed);

    // DCS with embedded ESC (not ST)
    const seq6 = "\x1bPdata\x1bXmore\x1b\\";
    const dcs6 = (parse_dcs_structured(seq6)).?;
    try testing.expectEqualStrings("data\x1bXmore", dcs6.data);

    // Incomplete sequence
    try testing.expect(parse_dcs_structured("\x1bPpartial") == null);
    try testing.expect(parse_dcs_structured("\x1bPdata\x1b") == null);
}

test "input SOS is consumed cleanly" {
    const win = @import("window.zig");
    const grid = @import("grid.zig");

    opts.global_w_options = opts.options_create(null);
    defer opts.options_free(opts.global_w_options);
    opts.options_default_all(opts.global_w_options, T.OPTIONS_TABLE_WINDOW);
    win.window_init_globals(@import("xmalloc.zig").allocator);

    const w = win.window_create(8, 3, T.DEFAULT_XPIXEL, T.DEFAULT_YPIXEL);
    defer {
        while (w.panes.items.len > 0) {
            const pane = w.panes.items[w.panes.items.len - 1];
            win.window_remove_pane(w, pane);
        }
        w.panes.deinit(@import("xmalloc.zig").allocator);
        w.last_panes.deinit(@import("xmalloc.zig").allocator);
        opts.options_free(w.options);
        @import("xmalloc.zig").allocator.free(w.name);
        _ = win.windows.remove(w.id);
        @import("xmalloc.zig").allocator.destroy(w);
    }

    const wp = win.window_add_pane(w, null, 8, 3);

    // SOS: ESC X data ESC \
    input_parse_screen(wp, "AB\x1bXsome-sos-data\x1b\\CD");
    try std.testing.expectEqual(@as(u8, 'A'), grid.ascii_at(wp.base.grid, 0, 0));
    try std.testing.expectEqual(@as(u8, 'B'), grid.ascii_at(wp.base.grid, 0, 1));
    try std.testing.expectEqual(@as(u8, 'C'), grid.ascii_at(wp.base.grid, 0, 2));
    try std.testing.expectEqual(@as(u8, 'D'), grid.ascii_at(wp.base.grid, 0, 3));
    try std.testing.expectEqual(@as(usize, 0), wp.input_pending.items.len);
}

// ── tmux C-name API ──
//
// zmux does NOT use tmux's state-machine `input_ctx` architecture.  Instead,
// `input_parse_screen` drives an inline byte-by-byte parser that operates
// directly on `WindowPane` / `ScreenWriteCtx`.  The functions below provide
// tmux-compatible entry points so that callers written against the C API can
// link and build.  Where possible they delegate to the real zmux
// implementations above; where the required infrastructure (libevent timers,
// bufferevent write-back, tty query path) does not yet exist, the body
// contains a comment explaining what is needed.
//
const input_win = @import("window.zig");

// ── Core parsing entry points ──

/// Parse raw bytes for a pane (tmux: `input_parse_buffer`).
/// Delegates directly to `input_parse_screen`.
pub fn input_parse_buffer(wp: *T.WindowPane, buf: []const u8) void {
    input_parse_screen(wp, buf);
}

/// Low-level parse entry point (tmux: `input_parse`).
/// In tmux this takes an `input_ctx` pointer and drives the state machine.
/// zmux delegates to `input_parse_screen` when a pane is available.
/// This overload exists for callers that only have an opaque context.
pub fn input_parse(_: ?*anyopaque, _: [*]const u8, _: usize) void {
    // zmux cannot recover the WindowPane from an opaque pointer.
    // Callers should use input_parse_buffer or input_parse_screen instead.
}

/// Read new data from a pane's pty buffer and parse it (tmux: `input_parse_pane`).
pub fn input_parse_pane(wp: *T.WindowPane) void {
    var wpo: T.WindowPaneOffset = .{};
    var size: usize = undefined;
    const data = input_win.window_pane_get_new_data(wp, &wpo, &size);
    input_parse_buffer(wp, data);
    input_win.window_pane_update_used_data(wp, &wpo, size);
}

// ── Lifecycle (tmux: `input_init` / `input_free` / `input_reset`) ──
//
// tmux allocates a heap `input_ctx` with DCS/APC accumulation buffers,
// a ground timer (libevent), a request queue, and saved cell state.
// zmux keeps all equivalent state on `Screen` (cell_fg/bg/us/attr,
// g0set/g1set, saved_* variants) and `WindowPane.input_pending`.
// No separate heap object is needed, so `input_init` resets cell state
// and `input_free` drains the pending buffer.

/// Initialise input parsing state for a pane (tmux: `input_init`).
/// Resets the cell attributes on the pane's base screen to defaults.
pub fn input_init(wp: ?*T.WindowPane, _: ?*anyopaque) void {
    if (wp) |w| {
        input_reset_cell(&w.base);
        w.input_pending.clearRetainingCapacity();
    }
}

/// Tear down input parsing state (tmux: `input_free`).
/// Drains any pending bytes on the pane.  zmux has no heap-allocated
/// `input_ctx`, so there is no structure to free.
pub fn input_free(wp: ?*T.WindowPane) void {
    if (wp) |w| {
        w.input_pending.clearRetainingCapacity();
        // tmux also calls screen_write_stop_sync here; mirror that.
        screen_write.screen_write_stop_sync(w);
    }
}

/// Reset input state and optionally clear the screen (tmux: `input_reset`).
/// Resets cell attributes to default.  If `clear` is non-zero and the pane
/// has no active modes, the base screen is erased.
pub fn input_reset(wp: ?*T.WindowPane, clear: i32) void {
    if (wp) |w| {
        input_reset_cell(&w.base);
        w.input_pending.clearRetainingCapacity();

        if (clear != 0) {
            var ctx = T.ScreenWriteCtx{ .wp = w, .s = &w.base };
            screen_write.reset(&ctx);
        }
    }
}

// ── State save / restore (DECSC / DECRC) ──
//
// tmux saves the full `input_cell` (cell attributes + g0/g1 sets), cursor
// position, and origin mode into `old_cell` / `old_cx` / `old_cy` /
// `old_mode` on the `input_ctx`.  zmux stores the same information on the
// `Screen` struct (saved_cell_fg/bg/us/attr, saved_g0set/g1set, saved_cx,
// saved_cy, saved_mode) and the save/restore is done through
// `screen_write.save_cursor` / `screen_write.restore_cursor`.

/// Save cursor position and cell attributes (tmux: DECSC / `input_save_state`).
pub fn input_save_state(wp: ?*T.WindowPane) void {
    if (wp) |w| {
        var ctx = T.ScreenWriteCtx{ .wp = w, .s = screen_mod.screen_current(w) };
        screen_write.save_cursor(&ctx);
    }
}

/// Restore cursor position and cell attributes (tmux: DECRC / `input_restore_state`).
pub fn input_restore_state(wp: ?*T.WindowPane) void {
    if (wp) |w| {
        var ctx = T.ScreenWriteCtx{ .wp = w, .s = screen_mod.screen_current(w) };
        screen_write.restore_cursor(&ctx);
    }
}
