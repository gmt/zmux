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
const opts = @import("options.zig");
const utf8 = @import("utf8.zig");

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
    input: utf8.CellBuffer = .{},
    input_view: []u8,
    last_input: utf8.CellBuffer = .{},
    cursor: usize = 0,
    flags: u32,
    prompt_type: PromptType,
    inputcb: PromptInputCb,
    freecb: ?PromptFreeCb,
    data: ?*anyopaque,
};

var prompt_states: std.AutoHashMap(usize, *PromptState) = undefined;
var prompt_states_init = false;
const prompt_type_count: usize = @intFromEnum(PromptType.window_target) + 1;
var prompt_histories: [prompt_type_count]std.ArrayList([]u8) = undefined;
var prompt_histories_init = false;

fn ensure_init() void {
    if (prompt_states_init) return;
    prompt_states = std.AutoHashMap(usize, *PromptState).init(xm.allocator);
    prompt_states_init = true;
}

fn prompt_type_index(prompt_type: PromptType) usize {
    return switch (prompt_type) {
        .command, .search, .target, .window_target => @intFromEnum(prompt_type),
        .invalid => unreachable,
    };
}

fn ensure_histories_init() void {
    if (prompt_histories_init) return;
    for (&prompt_histories) |*history| history.* = .{};
    prompt_histories_init = true;
}

fn prompt_history(prompt_type: PromptType) *std.ArrayList([]u8) {
    ensure_histories_init();
    return &prompt_histories[prompt_type_index(prompt_type)];
}

fn prompt_history_limit() usize {
    const raw = opts.options_get_number(opts.global_options, "prompt-history-limit");
    return @intCast(@max(raw, 0));
}

fn prompt_history_drop_front(history: *std.ArrayList([]u8), count: usize) void {
    for (0..count) |_| {
        const removed = history.orderedRemove(0);
        xm.allocator.free(removed);
    }
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
    return state.input_view;
}

fn state_copy_input(state: *const PromptState) []u8 {
    return state.input.toOwnedString();
}

fn refresh_input_view(state: *PromptState) void {
    xm.allocator.free(state.input_view);
    state.input_view = state.input.toOwnedString();
}

fn set_prompt_input(state: *PromptState, bytes: []const u8) void {
    state.input.setString(bytes);
    state.cursor = state.input.len();
    refresh_input_view(state);
}

fn set_prompt_last_input(state: *PromptState, bytes: []const u8) void {
    state.last_input.setString(bytes);
}

fn prompt_state_free(state: *PromptState) void {
    if (state.freecb) |freecb| {
        if (state.data != null) freecb(state.data);
    }
    xm.allocator.free(state.prompt_string);
    xm.allocator.free(state.input_view);
    state.input.deinit();
    state.last_input.deinit();
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

fn insert_prompt_bytes(state: *PromptState, bytes: []const u8) void {
    const insert_at = @min(state.cursor, state.input.len());
    state.cursor = insert_at + state.input.insertBytes(insert_at, bytes);
    refresh_input_view(state);
}

fn delete_prompt_before_cursor(state: *PromptState) bool {
    if (!state.input.deleteBefore(&state.cursor)) return false;
    refresh_input_view(state);
    return true;
}

fn append_event(state: *PromptState, event: *const T.key_event) bool {
    const key = event.key & T.KEYC_MASK_KEY;

    if (key <= 0x7f) {
        if (key < 0x20 or key == 0x7f or event.len == 0) return false;
        insert_prompt_bytes(state, event.data[0..event.len]);
        return true;
    }

    if (T.keycIsUnicode(event.key)) {
        if (event.len != 0) {
            insert_prompt_bytes(state, event.data[0..event.len]);
            return true;
        }
        const codepoint = std.math.cast(u21, key) orelse return false;
        const glyph = utf8.Glyph.fromCodepoint(codepoint) orelse return false;
        insert_prompt_bytes(state, glyph.bytes());
        return true;
    }

    return false;
}

fn single_prompt_text(key: T.key_code, buf: *[4]u8) ?[]const u8 {
    if ((key & T.KEYC_MASK_KEY) == T.KEYC_BSPACE) {
        buf[0] = 0x7f;
        return buf[0..1];
    }

    if ((key & T.KEYC_MASK_KEY) > 0x7f) {
        if (!T.keycIsUnicode(key)) return null;
        const len = std.unicode.utf8Encode(@intCast(key & T.KEYC_MASK_KEY), buf) catch return null;
        return buf[0..len];
    }

    buf[0] = @intCast(key & if (key & T.KEYC_CTRL != 0) @as(T.key_code, 0x1f) else T.KEYC_MASK_KEY);
    return buf[0..1];
}

pub fn status_prompt_history_add(line: []const u8, prompt_type: PromptType) void {
    const history = prompt_history(prompt_type);
    const oldsize = history.items.len;
    const is_new = oldsize == 0 or !std.mem.eql(u8, history.items[oldsize - 1], line);
    const limit = prompt_history_limit();

    if (limit > oldsize) {
        if (!is_new) return;
    } else {
        const desired = oldsize + @intFromBool(is_new);
        const freecount = @min(oldsize, desired -| limit);
        if (freecount == 0) return;
        prompt_history_drop_front(history, freecount);
    }

    if (is_new and limit > 0)
        history.append(xm.allocator, xm.xstrdup(line)) catch unreachable;
}

pub fn status_prompt_history_clear(prompt_type: ?PromptType) void {
    ensure_histories_init();
    if (prompt_type) |kind| {
        const history = prompt_history(kind);
        prompt_history_drop_front(history, history.items.len);
        return;
    }

    for (&prompt_histories) |*history|
        prompt_history_drop_front(history, history.items.len);
}

pub fn status_prompt_history_count(prompt_type: PromptType) usize {
    return prompt_history(prompt_type).items.len;
}

pub fn status_prompt_history_item(prompt_type: PromptType, index: usize) ?[]const u8 {
    const history = prompt_history(prompt_type);
    if (index >= history.items.len) return null;
    return history.items[index];
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
        .input_view = xm.xstrdup(""),
        .flags = flags,
        .prompt_type = prompt_type,
        .inputcb = inputcb,
        .freecb = freecb,
        .data = data,
    };
    set_prompt_last_input(state, expanded_input);
    if (flags & PROMPT_INCREMENTAL == 0) {
        set_prompt_input(state, expanded_input);
    }
    xm.allocator.free(expanded_input);

    prompt_states.put(state_key(c), state) catch unreachable;
    c.flags |= T.CLIENT_REDRAWSTATUS;

    if (flags & PROMPT_INCREMENTAL != 0)
        _ = inputcb(c, data, "=", false);
}

pub fn status_prompt_update(c: *T.Client, msg: []const u8, input: ?[]const u8) void {
    const state = find_state(c) orelse return;

    xm.allocator.free(state.prompt_string);
    state.prompt_string = xm.xstrdup(msg);

    set_prompt_last_input(state, input orelse "");
    set_prompt_input(state, input orelse "");
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
            insert_prompt_bytes(state, &digit);
            prompt_changed(c, state, '=');
            return true;
        }
        const text = state_copy_input(state);
        defer xm.allocator.free(text);
        prompt_finish(c, state, text, true);
        return true;
    }

    if (state.flags & PROMPT_SINGLE != 0) {
        var buf: [4]u8 = undefined;
        const text = single_prompt_text(event.key, &buf) orelse return false;
        prompt_finish(c, state, text, true);
        return true;
    }

    if (masked == T.C0_CR or masked == T.C0_LF or masked == T.KEYC_KP_ENTER) {
        const text = state_copy_input(state);
        defer xm.allocator.free(text);
        if (text.len != 0)
            status_prompt_history_add(text, state.prompt_type);
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
        if (delete_prompt_before_cursor(state)) prompt_changed(c, state, '=');
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

test "status-prompt history keeps type-local entries and respects the limit" {
    opts.global_options = opts.options_create(null);
    defer opts.options_free(opts.global_options);
    status_prompt_history_clear(null);

    opts.options_default_all(opts.global_options, T.OPTIONS_TABLE_SERVER);
    opts.options_set_number(opts.global_options, "prompt-history-limit", 2);

    status_prompt_history_add("one", .command);
    status_prompt_history_add("one", .command);
    status_prompt_history_add("search-1", .search);
    status_prompt_history_add("two", .command);
    status_prompt_history_add("three", .command);

    try std.testing.expectEqual(@as(usize, 2), status_prompt_history_count(.command));
    try std.testing.expectEqualStrings("two", status_prompt_history_item(.command, 0).?);
    try std.testing.expectEqualStrings("three", status_prompt_history_item(.command, 1).?);
    try std.testing.expectEqual(@as(usize, 1), status_prompt_history_count(.search));
    try std.testing.expectEqualStrings("search-1", status_prompt_history_item(.search, 0).?);

    status_prompt_history_clear(.command);
    try std.testing.expectEqual(@as(usize, 0), status_prompt_history_count(.command));
    try std.testing.expectEqual(@as(usize, 1), status_prompt_history_count(.search));
    status_prompt_history_clear(null);
}

const PromptCapture = struct {
    last: ?[]u8 = null,
    done: bool = false,
};

fn capture_prompt_input(_: *T.Client, data: ?*anyopaque, text: ?[]const u8, done: bool) i32 {
    const capture: *PromptCapture = @ptrCast(@alignCast(data orelse return 1));
    if (capture.last) |last| xm.allocator.free(last);
    capture.last = if (text) |value| xm.xstrdup(value) else null;
    capture.done = done;
    return 1;
}

fn free_prompt_capture(data: ?*anyopaque) void {
    const capture: *PromptCapture = @ptrCast(@alignCast(data orelse return));
    if (capture.last) |last| xm.allocator.free(last);
    xm.allocator.destroy(capture);
}

test "status-prompt stores multibyte input through the shared cell buffer" {
    opts.global_options = opts.options_create(null);
    defer opts.options_free(opts.global_options);
    opts.options_default_all(opts.global_options, T.OPTIONS_TABLE_SERVER);

    var environ = T.Environ.init(xm.allocator);
    defer environ.deinit();
    var client = T.Client{
        .environ = &environ,
        .tty = undefined,
        .status = .{ .screen = undefined },
    };
    client.tty.client = &client;
    const capture = xm.allocator.create(PromptCapture) catch unreachable;
    capture.* = .{};

    status_prompt_set(
        &client,
        null,
        "Prompt ",
        null,
        capture_prompt_input,
        free_prompt_capture,
        capture,
        0,
        .command,
    );
    defer status_prompt_clear(&client);

    var event: T.key_event = .{
        .key = key_string.key_string_lookup_string("🙂"),
        .len = "🙂".len,
    };
    @memcpy(event.data[0..event.len], "🙂");
    try std.testing.expect(status_prompt_handle_key(&client, &event));
    try std.testing.expectEqualStrings("🙂", status_prompt_input(&client).?);

    event = .{
        .key = T.KEYC_BSPACE,
        .data = std.mem.zeroes([16]u8),
        .len = 1,
    };
    event.data[0] = 0x7f;
    try std.testing.expect(status_prompt_handle_key(&client, &event));
    try std.testing.expectEqualStrings("", status_prompt_input(&client).?);
}

test "status-prompt enter callback sees reconstructed utf8 text" {
    opts.global_options = opts.options_create(null);
    defer opts.options_free(opts.global_options);
    opts.options_default_all(opts.global_options, T.OPTIONS_TABLE_SERVER);

    var environ = T.Environ.init(xm.allocator);
    defer environ.deinit();
    var client = T.Client{
        .environ = &environ,
        .tty = undefined,
        .status = .{ .screen = undefined },
    };
    client.tty.client = &client;
    const capture = xm.allocator.create(PromptCapture) catch unreachable;
    capture.* = .{};

    status_prompt_set(
        &client,
        null,
        "Prompt ",
        "é",
        capture_prompt_input,
        free_prompt_capture,
        capture,
        0,
        .command,
    );
    defer status_prompt_clear(&client);

    var event: T.key_event = .{
        .key = T.C0_CR,
        .data = std.mem.zeroes([16]u8),
        .len = 1,
    };
    event.data[0] = '\r';
    try std.testing.expect(status_prompt_handle_key(&client, &event));
    try std.testing.expect(capture.done);
    try std.testing.expectEqualStrings("é", capture.last.?);
}
