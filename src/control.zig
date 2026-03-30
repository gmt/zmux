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
// Ported from tmux/control.c.
// Original copyright:
//   Copyright (c) 2012 Nicholas Marriott <nicholas.marriott@gmail.com>
//   Copyright (c) 2012 George Nachman <tmux@georgester.com>
//   ISC licence – same terms as above.

//! control.zig – control-mode client lifecycle, output queuing, and pane
//! offset bookkeeping ported from tmux's control.c.
//!
//! Block-based output queuing: each client has an "all_blocks" queue and
//! each control pane has its own block queue.  %output blocks are added to
//! both queues; notification lines are added only to all_blocks.
//!
//! When data can be written, pane blocks are drained first; when a block is
//! fully written it is removed from both queues, and any queued notification
//! lines that are now at the head of all_blocks are flushed.
//!
//! I/O callbacks that depend on libevent bufferevents are provided as stubs
//! since zmux uses peer-based IPC rather than raw bufferevents.

const std = @import("std");
const T = @import("types.zig");
const file_mod = @import("file.zig");
const log = @import("log.zig");
const session_mod = @import("session.zig");
const window_mod = @import("window.zig");
const xm = @import("xmalloc.zig");

const CONTROL_BUFFER_LOW: usize = 512;
const CONTROL_BUFFER_HIGH: usize = 8192;
const CONTROL_WRITE_MINIMUM: usize = 32;
const CONTROL_MAXIMUM_AGE: i64 = 300_000;

const CONTROL_IGNORE_FLAGS: u64 = T.CLIENT_CONTROL_NOOUTPUT | T.CLIENT_UNATTACHEDFLAGS;

// ---------------------------------------------------------------------------
// Block helpers
// ---------------------------------------------------------------------------

fn control_alloc_block() *T.ControlBlock {
    const cb = xm.allocator.create(T.ControlBlock) catch unreachable;
    cb.* = .{};
    return cb;
}

fn control_free_block(cl: *T.Client, cb: *T.ControlBlock) void {
    if (cb.line) |line| xm.allocator.free(line);
    remove_block_from_all(cl, cb);
    xm.allocator.destroy(cb);
}

fn remove_block_from_all(cl: *T.Client, cb: *T.ControlBlock) void {
    for (cl.control_all_blocks.items, 0..) |item, i| {
        if (item == cb) {
            _ = cl.control_all_blocks.orderedRemove(i);
            return;
        }
    }
}

fn remove_block_from_pane(cp: *T.ControlPane, cb: *T.ControlBlock) void {
    for (cp.blocks.items, 0..) |item, i| {
        if (item == cb) {
            _ = cp.blocks.orderedRemove(i);
            return;
        }
    }
}

fn now_millis() i64 {
    return std.time.milliTimestamp();
}

// ---------------------------------------------------------------------------
// Pane lookup / management
// ---------------------------------------------------------------------------

fn control_get_pane(cl: *T.Client, wp: *T.WindowPane) ?*T.ControlPane {
    for (cl.control_panes.items) |*pane| {
        if (pane.pane == wp.id) return pane;
    }
    return null;
}

fn control_get_pane_by_id(cl: *T.Client, pane_id: u32) ?*T.ControlPane {
    for (cl.control_panes.items) |*pane| {
        if (pane.pane == pane_id) return pane;
    }
    return null;
}

fn control_add_pane(cl: *T.Client, wp: *T.WindowPane) *T.ControlPane {
    if (control_get_pane(cl, wp)) |pane| return pane;

    cl.control_panes.append(xm.allocator, .{
        .pane = wp.id,
        .offset = wp.offset,
        .queued = wp.offset,
    }) catch unreachable;
    return &cl.control_panes.items[cl.control_panes.items.len - 1];
}

fn sync_pane_offsets(cp: *T.ControlPane, wp: *T.WindowPane) void {
    cp.offset = wp.offset;
    cp.queued = wp.offset;
}

/// Validate that the pane is part of the client's session.
pub fn control_window_pane(cl: *T.Client, pane_id: u32) ?*T.WindowPane {
    const s = cl.session orelse return null;
    const wp = window_mod.window_pane_find_by_id(pane_id) orelse return null;
    if (session_mod.winlink_find_by_window(&s.windows, wp.window) == null)
        return null;
    return wp;
}

// ---------------------------------------------------------------------------
// Writing helpers
// ---------------------------------------------------------------------------

fn write_to_peer(cl: *T.Client, data: []const u8) void {
    const peer = cl.peer orelse return;
    _ = file_mod.sendPeerStream(peer, 1, data);
}

fn write_control_line(cl: *T.Client, comptime fmt: []const u8, args: anytype) void {
    const line = std.fmt.allocPrint(xm.allocator, fmt ++ "\n", args) catch unreachable;
    defer xm.allocator.free(line);
    write_to_peer(cl, line);
}

/// Write a notification line to the control client.  If no %output blocks
/// are pending the line is written directly; otherwise it is queued as a
/// block (size == 0, line != null) behind the pending output so ordering
/// is preserved.
pub fn control_write(cl: *T.Client, comptime fmt: []const u8, args: anytype) void {
    if (cl.control_all_blocks.items.len == 0) {
        log.log_debug("control_write: {s}: writing line directly", .{cl.name orelse "<anon>"});
        write_control_line(cl, fmt, args);
        return;
    }

    const cb = control_alloc_block();
    cb.line = std.fmt.allocPrint(xm.allocator, fmt, args) catch unreachable;
    cb.t = now_millis();
    cl.control_all_blocks.append(xm.allocator, cb) catch unreachable;

    log.log_debug("control_write: {s}: storing line", .{cl.name orelse "<anon>"});
}

/// Flush queued notification blocks (size == 0) from the head of
/// all_blocks.  Stops at the first %output block (size != 0).
pub fn control_flush_all_blocks(cl: *T.Client) void {
    while (cl.control_all_blocks.items.len > 0) {
        const cb = cl.control_all_blocks.items[0];
        if (cb.size != 0)
            break;

        if (cb.line) |line| {
            log.log_debug("control_flush_all_blocks: {s}: flushing line", .{cl.name orelse "<anon>"});
            const with_nl = std.fmt.allocPrint(xm.allocator, "{s}\n", .{line}) catch unreachable;
            defer xm.allocator.free(with_nl);
            write_to_peer(cl, with_nl);
        }

        _ = cl.control_all_blocks.orderedRemove(0);
        if (cb.line) |line| xm.allocator.free(line);
        xm.allocator.destroy(cb);
    }
}

/// Write encoded output data for a pane to the client.
pub fn control_write_data(cl: *T.Client, data: []const u8) void {
    log.log_debug("control_write_data: {s}: writing {d} bytes", .{ cl.name orelse "<anon>", data.len });
    write_to_peer(cl, data);
}

// ---------------------------------------------------------------------------
// Pane output blocks
// ---------------------------------------------------------------------------

/// Discard all queued output for a single pane.
fn control_discard_pane(cl: *T.Client, cp: *T.ControlPane) void {
    while (cp.blocks.items.len > 0) {
        const cb = cp.blocks.items[0];
        _ = cp.blocks.orderedRemove(0);
        control_free_block(cl, cb);
    }
}

/// Check age of the oldest block for this pane.  Returns true if the pane
/// was paused or the client was flagged for exit due to staleness.
fn control_check_age(cl: *T.Client, wp: *T.WindowPane, cp: *T.ControlPane) bool {
    if (cp.blocks.items.len == 0) return false;
    const cb = cp.blocks.items[0];
    const t = now_millis();
    if (cb.t >= t) return false;

    const age = t - cb.t;
    log.log_debug("control_check_age: {s}: %{d} is {d}ms behind", .{ cl.name orelse "<anon>", wp.id, age });

    if ((cl.flags & T.CLIENT_CONTROL_PAUSEAFTER) != 0) {
        if (age < cl.pause_age) return false;
        cp.flags |= T.CONTROL_PANE_PAUSED;
        control_discard_pane(cl, cp);
        control_write(cl, "%pause %{d}", .{wp.id});
    } else {
        if (age < CONTROL_MAXIMUM_AGE) return false;
        cl.exit_message = xm.xstrdup("too far behind");
        cl.flags |= T.CLIENT_EXIT;
        control_discard(cl);
    }
    return true;
}

/// Queue new output from a pane.
pub fn control_write_output(cl: *T.Client, wp: *T.WindowPane) void {
    const s = cl.session orelse return;
    if (session_mod.winlink_find_by_window(&s.windows, wp.window) == null) return;

    if ((cl.flags & CONTROL_IGNORE_FLAGS) != 0) {
        if (control_get_pane(cl, wp)) |cp| {
            log.log_debug("control_write_output: {s}: ignoring pane %{d}", .{ cl.name orelse "<anon>", wp.id });
            window_mod.window_pane_update_used_data(wp, &cp.offset, std.math.maxInt(usize));
            window_mod.window_pane_update_used_data(wp, &cp.queued, std.math.maxInt(usize));
        }
        return;
    }

    const cp = control_add_pane(cl, wp);
    if ((cp.flags & (T.CONTROL_PANE_OFF | T.CONTROL_PANE_PAUSED)) != 0) {
        log.log_debug("control_write_output: {s}: ignoring pane %{d}", .{ cl.name orelse "<anon>", wp.id });
        window_mod.window_pane_update_used_data(wp, &cp.offset, std.math.maxInt(usize));
        window_mod.window_pane_update_used_data(wp, &cp.queued, std.math.maxInt(usize));
        return;
    }

    if (control_check_age(cl, wp, cp)) return;

    var new_size: usize = 0;
    _ = window_mod.window_pane_get_new_data(wp, &cp.queued, &new_size);
    if (new_size == 0) return;
    window_mod.window_pane_update_used_data(wp, &cp.queued, new_size);

    const cb = control_alloc_block();
    cb.size = new_size;
    cb.t = now_millis();
    cb.pane_id = wp.id;
    cl.control_all_blocks.append(xm.allocator, cb) catch unreachable;
    cp.blocks.append(xm.allocator, cb) catch unreachable;

    log.log_debug("control_write_output: {s}: new block of {d} for %{d}", .{ cl.name orelse "<anon>", cb.size, wp.id });

    if (!cp.pending_flag) {
        log.log_debug("control_write_output: {s}: %{d} now pending", .{ cl.name orelse "<anon>", wp.id });
        cp.pending_flag = true;
        cl.control_pending_count += 1;
    }
}

/// Encode and write pending output for a pane, up to `limit` bytes.
/// Returns true if the pane still has pending blocks.
pub fn control_write_pending(cl: *T.Client, cp: *T.ControlPane, limit: usize) bool {
    const wp = control_window_pane(cl, cp.pane) orelse {
        while (cp.blocks.items.len > 0) {
            const cb = cp.blocks.items[0];
            _ = cp.blocks.orderedRemove(0);
            control_free_block(cl, cb);
        }
        control_flush_all_blocks(cl);
        return false;
    };

    if (wp.fd == -1) {
        while (cp.blocks.items.len > 0) {
            const cb = cp.blocks.items[0];
            _ = cp.blocks.orderedRemove(0);
            control_free_block(cl, cb);
        }
        control_flush_all_blocks(cl);
        return false;
    }

    var used: usize = 0;

    while (used < limit and cp.blocks.items.len > 0) {
        if (control_check_age(cl, wp, cp))
            break;

        const cb = cp.blocks.items[0];
        const t = now_millis();
        const age: i64 = if (cb.t < t) t - cb.t else 0;

        log.log_debug("control_write_pending: {s}: block {d} (age {d}) for %{d} (used {d}/{d})", .{
            cl.name orelse "<anon>", cb.size, age, cp.pane, used, limit,
        });

        var size = cb.size;
        if (size > limit - used)
            size = limit - used;
        used += size;

        const encoded = control_encode_output(cl, cp, wp, size, age);
        if (encoded.len > 0) {
            control_write_data(cl, encoded);
            xm.allocator.free(encoded);
        }

        cb.size -= size;
        if (cb.size == 0) {
            _ = cp.blocks.orderedRemove(0);
            control_free_block(cl, cb);

            if (cl.control_all_blocks.items.len > 0 and
                cl.control_all_blocks.items[0].size == 0)
            {
                control_flush_all_blocks(cl);
            }
        }
    }

    return cp.blocks.items.len > 0;
}

/// Encode pane output data into a %output or %extended-output line.
fn control_encode_output(cl: *T.Client, cp: *T.ControlPane, wp: *T.WindowPane, size: usize, age: i64) []u8 {
    var new_size: usize = 0;
    const new_data = window_mod.window_pane_get_new_data(wp, &cp.offset, &new_size);
    if (new_size < size) {
        log.log_debug("control_encode_output: not enough data: {d} < {d}", .{ new_size, size });
        window_mod.window_pane_update_used_data(wp, &cp.offset, new_size);
        return xm.allocator.alloc(u8, 0) catch unreachable;
    }

    var buf = std.ArrayList(u8).init(xm.allocator);
    if ((cl.flags & T.CLIENT_CONTROL_PAUSEAFTER) != 0) {
        const header = std.fmt.allocPrint(xm.allocator, "%extended-output %{d} {d} : ", .{ wp.id, age }) catch unreachable;
        buf.appendSlice(header) catch unreachable;
        xm.allocator.free(header);
    } else {
        const header = std.fmt.allocPrint(xm.allocator, "%output %{d} ", .{wp.id}) catch unreachable;
        buf.appendSlice(header) catch unreachable;
        xm.allocator.free(header);
    }

    var i: usize = 0;
    while (i < size) : (i += 1) {
        const byte = if (i < new_data.len) new_data[i] else 0;
        if (byte < ' ' or byte == '\\') {
            const esc = std.fmt.allocPrint(xm.allocator, "\\{o:0>3}", .{byte}) catch unreachable;
            buf.appendSlice(esc) catch unreachable;
            xm.allocator.free(esc);
        } else {
            buf.append(byte) catch unreachable;
        }
    }

    buf.append('\n') catch unreachable;
    window_mod.window_pane_update_used_data(wp, &cp.offset, size);
    return buf.toOwnedSlice() catch unreachable;
}

// ---------------------------------------------------------------------------
// Control client write callback (stub + logic)
// ---------------------------------------------------------------------------

/// Drive pending output to the client.  In tmux this is called from the
/// bufferevent write callback; here it is available for explicit flushing.
pub fn control_write_callback(cl: *T.Client) void {
    control_flush_all_blocks(cl);

    var written: usize = 0;
    while (written < CONTROL_BUFFER_HIGH) {
        if (cl.control_pending_count == 0) break;

        const space = CONTROL_BUFFER_HIGH - written;
        var limit = space / @as(usize, @intCast(cl.control_pending_count)) / 3;
        if (limit < CONTROL_WRITE_MINIMUM)
            limit = CONTROL_WRITE_MINIMUM;

        var i: usize = 0;
        while (i < cl.control_panes.items.len) {
            const cp = &cl.control_panes.items[i];
            if (!cp.pending_flag) {
                i += 1;
                continue;
            }
            if (control_write_pending(cl, cp, limit)) {
                i += 1;
                continue;
            }
            cp.pending_flag = false;
            cl.control_pending_count -= 1;
            i += 1;
        }

        written += space;
    }
}

// ---------------------------------------------------------------------------
// Discard / reset
// ---------------------------------------------------------------------------

/// Discard all pending output for the control client.
pub fn control_discard(cl: *T.Client) void {
    for (cl.control_panes.items) |*cp|
        control_discard_pane(cl, cp);
}

/// Reset all pane offsets, clearing pane tracking.
pub fn control_reset_offsets(cl: *T.Client) void {
    for (cl.control_panes.items) |*cp| {
        cp.blocks.deinit(xm.allocator);
    }
    cl.control_panes.clearAndFree(xm.allocator);
    cl.control_pending_count = 0;
}

// ---------------------------------------------------------------------------
// Pane offset query
// ---------------------------------------------------------------------------

/// Return the write offset for a control client pane.  Sets `off` to
/// indicate whether output is currently suppressed.  Returns null when
/// no offset is available (suppressed or unknown pane).
pub fn control_pane_offset(cl: *T.Client, wp: *T.WindowPane, off: *bool) ?*T.WindowPaneOffset {
    if ((cl.flags & T.CLIENT_CONTROL_NOOUTPUT) != 0) {
        off.* = false;
        return null;
    }

    const cp = control_get_pane(cl, wp) orelse {
        off.* = false;
        return null;
    };

    if ((cp.flags & T.CONTROL_PANE_PAUSED) != 0) {
        off.* = false;
        return null;
    }
    if ((cp.flags & T.CONTROL_PANE_OFF) != 0) {
        off.* = true;
        return null;
    }

    off.* = false;
    return &cp.offset;
}

// ---------------------------------------------------------------------------
// Lifecycle
// ---------------------------------------------------------------------------

/// Initialize control mode for a client.  In tmux this sets up
/// bufferevents; here we initialize the Zig-side state.
pub fn control_start(cl: *T.Client) void {
    cl.control_panes = .{};
    cl.control_all_blocks = .{};
    cl.control_pending_count = 0;
    cl.control_ready_flag = false;

    if ((cl.flags & T.CLIENT_CONTROLCONTROL) != 0) {
        write_to_peer(cl, "\x1bP1000p");
    }

    log.log_debug("control_start: {s}: control mode initialized", .{cl.name orelse "<anon>"});
}

/// Mark a control client as ready to receive input.
pub fn control_ready(cl: *T.Client) void {
    cl.control_ready_flag = true;
    log.log_debug("control_ready: {s}: control client ready", .{cl.name orelse "<anon>"});
}

/// Stop control mode and free all associated state.
pub fn control_stop(cl: *T.Client) void {
    log.log_debug("control_stop: {s}: tearing down control mode", .{cl.name orelse "<anon>"});

    while (cl.control_all_blocks.items.len > 0) {
        const cb = cl.control_all_blocks.items[0];
        _ = cl.control_all_blocks.orderedRemove(0);
        if (cb.line) |line| xm.allocator.free(line);
        xm.allocator.destroy(cb);
    }
    cl.control_all_blocks.deinit(xm.allocator);

    control_reset_offsets(cl);

    cl.control_ready_flag = false;
}

/// Returns true when the control client has no outstanding data to write.
pub fn control_all_done(cl: *T.Client) bool {
    return cl.control_all_blocks.items.len == 0;
}

// ---------------------------------------------------------------------------
// Pane on/off/pause/continue
// ---------------------------------------------------------------------------

pub fn control_set_pane_on(cl: *T.Client, wp: *T.WindowPane) void {
    const cp = control_get_pane(cl, wp) orelse return;
    if ((cp.flags & T.CONTROL_PANE_OFF) == 0) return;

    cp.flags &= ~@as(u8, T.CONTROL_PANE_OFF);
    sync_pane_offsets(cp, wp);
}

pub fn control_set_pane_off(cl: *T.Client, wp: *T.WindowPane) void {
    const cp = control_add_pane(cl, wp);
    cp.flags |= T.CONTROL_PANE_OFF;
}

pub fn control_continue_pane(cl: *T.Client, wp: *T.WindowPane) void {
    const cp = control_get_pane(cl, wp) orelse return;
    if ((cp.flags & T.CONTROL_PANE_PAUSED) == 0) return;

    cp.flags &= ~@as(u8, T.CONTROL_PANE_PAUSED);
    sync_pane_offsets(cp, wp);
    control_write(cl, "%continue %{d}", .{wp.id});
}

pub fn control_pause_pane(cl: *T.Client, wp: *T.WindowPane) void {
    const cp = control_add_pane(cl, wp);
    if ((cp.flags & T.CONTROL_PANE_PAUSED) != 0) return;

    cp.flags |= T.CONTROL_PANE_PAUSED;
    control_discard_pane(cl, cp);
    control_write(cl, "%pause %{d}", .{wp.id});
}

// ---------------------------------------------------------------------------
// Deinit
// ---------------------------------------------------------------------------

pub fn control_panes_deinit(cl: *T.Client) void {
    for (cl.control_panes.items) |*cp| {
        cp.blocks.deinit(xm.allocator);
    }
    cl.control_panes.deinit(xm.allocator);
}

// ---------------------------------------------------------------------------
// I/O callbacks (stubs – zmux uses peer-based IPC, not bufferevents)
// ---------------------------------------------------------------------------

/// Stub: libevent read callback.  In tmux this reads lines from the
/// bufferevent input and dispatches them as commands.  zmux handles
/// command dispatch through the peer/proc layer instead.
pub fn control_read_callback(cl: *T.Client) void {
    _ = cl;
}

/// Stub: libevent error callback.  In tmux this flags the client for exit
/// when the bufferevent encounters an error.  zmux detects peer errors
/// through the proc dispatch layer.
pub fn control_error_callback(cl: *T.Client) void {
    cl.flags |= T.CLIENT_EXIT;
}
