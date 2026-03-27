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
// Ported in part from tmux/status.c.
// Original copyright:
//   Copyright (c) 2008 Nicholas Marriott <nicholas.marriott@gmail.com>
//   ISC licence – same terms as above.

const std = @import("std");
const T = @import("types.zig");
const xm = @import("xmalloc.zig");
const cmd_display = @import("cmd-display-message.zig");
const key_string = @import("key-string.zig");

pub const PromptType = enum(u8) {
    command = 0,
    search = 1,
    target = 2,
    window_target = 3,
    invalid = 0xff,
};

pub const PROMPT_SINGLE: u32 = 0x1;
pub const PROMPT_NUMERIC: u32 = 0x2;
pub const PROMPT_INCREMENTAL: u32 = 0x4;
pub const PROMPT_NOFORMAT: u32 = 0x8;
pub const PROMPT_KEY: u32 = 0x10;
pub const PROMPT_ACCEPT: u32 = 0x20;
pub const PROMPT_QUOTENEXT: u32 = 0x40;
pub const PROMPT_BSPACE_EXIT: u32 = 0x80;

pub const PromptInputCb = *const fn (*T.Client, ?*anyopaque, ?[]const u8, bool) i32;
pub const PromptFreeCb = *const fn (?*anyopaque) void;

const PromptState = struct {
    prompt_string: []u8,
    input: std.ArrayList(u8) = .{},
    last_input: []u8,
    flags: u32,
    prompt_type: PromptType,
    inputcb: PromptInputCb,
    freecb: ?PromptFreeCb,
    data: ?*anyopaque,
};

var prompt_states: std.AutoHashMap(usize, *PromptState) = undefined;
var prompt_states_init = false;

fn ensure_init() void {
    if (prompt_states_init) return;
    prompt_states = std.AutoHashMap(usize, *PromptState).init(xm.allocator);
    prompt_states_init = true;
}

fn state_key(c: *T.Client) usize {
    return @intFromPtr(c);
}

fn find_state(c: *T.Client) ?*PromptState {
    if (!prompt_states_init) return null;
    return prompt_states.get(state_key(c));
}

fn expand_input(fs: ?*const T.CmdFindState, input: []const u8, flags: u32) []u8 {
    if (input.len == 0 or flags & PROMPT_NOFORMAT != 0) return xm.xstrdup(input);
    if (fs) |target| return cmd_display.expand_format(xm.allocator, input, target);
    return xm.xstrdup(input);
}

fn state_current_input(state: *const PromptState) []const u8 {
    return state.input.items;
}

fn state_copy_input(state: *const PromptState) []u8 {
    return xm.xstrdup(state_current_input(state));
}

fn prompt_state_free(state: *PromptState) void {
    if (state.freecb) |freecb| {
        if (state.data != null) freecb(state.data);
    }
    xm.allocator.free(state.prompt_string);
    xm.allocator.free(state.last_input);
    state.input.deinit(xm.allocator);
    xm.allocator.destroy(state);
}

fn prompt_finish(c: *T.Client, state: *PromptState, text: ?[]const u8, done: bool) void {
    const rc = state.inputcb(c, state.data, text, done);
    if (rc == 0) status_prompt_clear(c);
}

fn prompt_changed(c: *T.Client, state: *PromptState, prefix: u8) void {
    c.flags |= T.CLIENT_REDRAWSTATUS;
    if (state.flags & PROMPT_INCREMENTAL == 0) return;

    const text = state_copy_input(state);
    defer xm.allocator.free(text);

    var payload: std.ArrayList(u8) = .{};
    defer payload.deinit(xm.allocator);
    payload.append(xm.allocator, prefix) catch unreachable;
    payload.appendSlice(xm.allocator, text) catch unreachable;

    const owned = payload.toOwnedSlice(xm.allocator) catch unreachable;
    defer xm.allocator.free(owned);
    _ = state.inputcb(c, state.data, owned, false);
}

fn append_prompt_bytes(state: *PromptState, bytes: []const u8) void {
    state.input.appendSlice(xm.allocator, bytes) catch unreachable;
}

fn pop_last_codepoint(state: *PromptState) bool {
    if (state.input.items.len == 0) return false;

    var idx = state.input.items.len - 1;
    while (idx > 0 and (state.input.items[idx] & 0xc0) == 0x80) : (idx -= 1) {}
    state.input.shrinkRetainingCapacity(idx);
    return true;
}

fn append_event(state: *PromptState, event: *const T.key_event) bool {
    const key = event.key & T.KEYC_MASK_KEY;

    if (key <= 0x7f) {
        if (key < 0x20 or key == 0x7f or event.len == 0) return false;
        append_prompt_bytes(state, event.data[0..event.len]);
        return true;
    }

    if (T.keycIsUnicode(event.key)) {
        if (event.len != 0) {
            append_prompt_bytes(state, event.data[0..event.len]);
            return true;
        }

        var buf: [4]u8 = undefined;
        const len = std.unicode.utf8Encode(@intCast(key), &buf) catch return false;
        append_prompt_bytes(state, buf[0..len]);
        return true;
    }

    return false;
}

pub fn status_prompt_type(name: []const u8) PromptType {
    if (std.mem.eql(u8, name, "command")) return .command;
    if (std.mem.eql(u8, name, "search")) return .search;
    if (std.mem.eql(u8, name, "target")) return .target;
    if (std.mem.eql(u8, name, "window-target")) return .window_target;
    return .invalid;
}

pub fn status_prompt_type_string(prompt_type: PromptType) []const u8 {
    return switch (prompt_type) {
        .command => "command",
        .search => "search",
        .target => "target",
        .window_target => "window-target",
        .invalid => "invalid",
    };
}

pub fn status_prompt_active(c: *T.Client) bool {
    return find_state(c) != null;
}

pub fn status_prompt_message(c: *T.Client) ?[]const u8 {
    const state = find_state(c) orelse return null;
    return state.prompt_string;
}

pub fn status_prompt_input(c: *T.Client) ?[]const u8 {
    const state = find_state(c) orelse return null;
    return state_current_input(state);
}

pub fn status_prompt_set(
    c: *T.Client,
    fs: ?*const T.CmdFindState,
    msg: []const u8,
    input: ?[]const u8,
    inputcb: PromptInputCb,
    freecb: ?PromptFreeCb,
    data: ?*anyopaque,
    flags: u32,
    prompt_type: PromptType,
) void {
    const expanded_input = expand_input(fs, input orelse "", flags);
    errdefer xm.allocator.free(expanded_input);

    status_prompt_clear(c);
    ensure_init();

    const state = xm.allocator.create(PromptState) catch unreachable;
    state.* = .{
        .prompt_string = xm.xstrdup(msg),
        .last_input = expanded_input,
        .flags = flags,
        .prompt_type = prompt_type,
        .inputcb = inputcb,
        .freecb = freecb,
        .data = data,
    };
    if (flags & PROMPT_INCREMENTAL == 0)
        state.input.appendSlice(xm.allocator, expanded_input) catch unreachable;

    prompt_states.put(state_key(c), state) catch unreachable;
    c.flags |= T.CLIENT_REDRAWSTATUS;

    if (flags & PROMPT_INCREMENTAL != 0)
        _ = inputcb(c, data, "=", false);
}

pub fn status_prompt_update(c: *T.Client, msg: []const u8, input: ?[]const u8) void {
    const state = find_state(c) orelse return;

    xm.allocator.free(state.prompt_string);
    state.prompt_string = xm.xstrdup(msg);

    xm.allocator.free(state.last_input);
    state.last_input = xm.xstrdup(input orelse "");

    state.input.clearRetainingCapacity();
    state.input.appendSlice(xm.allocator, input orelse "") catch unreachable;
    c.flags |= T.CLIENT_REDRAWSTATUS;
}

pub fn status_prompt_clear(c: *T.Client) void {
    if (!prompt_states_init) return;
    const removed = prompt_states.fetchRemove(state_key(c)) orelse return;
    prompt_state_free(removed.value);
    c.flags |= T.CLIENT_REDRAWSTATUS;
}

pub fn status_prompt_handle_key(c: *T.Client, event: *const T.key_event) bool {
    const state = find_state(c) orelse return false;
    const masked = event.key & T.KEYC_MASK_KEY;

    if (state.flags & PROMPT_KEY != 0) {
        prompt_finish(c, state, key_string.key_string_lookup_key(event.key, 0), true);
        return true;
    }

    if (state.flags & PROMPT_NUMERIC != 0) {
        if (masked >= '0' and masked <= '9') {
            const digit = [_]u8{@intCast(masked)};
            append_prompt_bytes(state, &digit);
            prompt_changed(c, state, '=');
            return true;
        }
        const text = state_copy_input(state);
        defer xm.allocator.free(text);
        prompt_finish(c, state, text, true);
        return true;
    }

    if (masked == T.C0_CR or masked == T.C0_LF or masked == T.KEYC_KP_ENTER) {
        const text = state_copy_input(state);
        defer xm.allocator.free(text);
        prompt_finish(c, state, text, true);
        return true;
    }

    if (masked == T.C0_ESC or event.key == ('c' | T.KEYC_CTRL) or event.key == ('g' | T.KEYC_CTRL)) {
        prompt_finish(c, state, null, true);
        return true;
    }

    if (masked == T.KEYC_BSPACE or masked == T.C0_BS or event.key == ('h' | T.KEYC_CTRL)) {
        if (state_current_input(state).len == 0 and state.flags & PROMPT_BSPACE_EXIT != 0) {
            prompt_finish(c, state, null, true);
            return true;
        }
        if (pop_last_codepoint(state)) prompt_changed(c, state, '=');
        return true;
    }

    if (!append_event(state, event)) return false;

    if (state.flags & PROMPT_SINGLE != 0) {
        const text = state_copy_input(state);
        defer xm.allocator.free(text);
        prompt_finish(c, state, text, true);
        return true;
    }

    prompt_changed(c, state, '=');
    return true;
}
