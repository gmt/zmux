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
const cmd_mod = @import("cmd.zig");
const key_string = @import("key-string.zig");
const opts = @import("options.zig");
const server = @import("server.zig");
const status_mod = @import("status.zig");
const status_runtime = @import("status-runtime.zig");
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
pub const PromptCompleteCb = *const fn (*T.Client, ?*anyopaque, []const u8, usize) ?[]u8;
pub const PromptFreeCb = *const fn (?*anyopaque) void;

pub const PromptRenderState = struct {
    input_visible: []u8,
    cursor_column: u32,
    command_prompt: bool,
};

const PromptMode = enum {
    entry,
    command,
};

const PromptState = struct {
    prompt_string: []u8,
    input: utf8.CellBuffer = .{},
    input_view: []u8,
    last_input: utf8.CellBuffer = .{},
    saved_input: utf8.CellBuffer = .{},
    cursor: usize = 0,
    history_index: usize = 0,
    mode: PromptMode = .entry,
    quote_next: bool = false,
    flags: u32,
    prompt_type: PromptType,
    inputcb: PromptInputCb,
    completecb: ?PromptCompleteCb,
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

fn set_prompt_saved_input(state: *PromptState, bytes: []const u8) void {
    state.saved_input.setString(bytes);
}

fn prompt_state_free(state: *PromptState) void {
    if (state.freecb) |freecb| {
        if (state.data != null) freecb(state.data);
    }
    xm.allocator.free(state.prompt_string);
    xm.allocator.free(state.input_view);
    state.input.deinit();
    state.last_input.deinit();
    state.saved_input.deinit();
    xm.allocator.destroy(state);
}

fn prompt_finish(c: *T.Client, state: *PromptState, text: ?[]const u8, done: bool) void {
    const rc = state.inputcb(c, state.data, text, done);
    if (rc == 0) status_prompt_clear(c);
}

fn request_status_redraw(c: *T.Client) void {
    server.server_status_client(c);
}

fn prompt_changed(c: *T.Client, state: *PromptState, prefix: u8) void {
    request_status_redraw(c);
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

fn delete_prompt_at_cursor(state: *PromptState) bool {
    if (!state.input.deleteAt(state.cursor)) return false;
    refresh_input_view(state);
    return true;
}

fn delete_prompt_range(state: *PromptState, start: usize, end: usize) bool {
    const remove_at = @min(start, state.input.len());
    const removed = state.input.deleteRange(remove_at, end);
    if (removed == 0) return false;
    state.cursor = remove_at;
    refresh_input_view(state);
    return true;
}

fn replace_prompt_range(state: *PromptState, start: usize, end: usize, bytes: []const u8) bool {
    const replace_at = @min(start, state.input.len());
    const inserted = state.input.replaceRange(replace_at, end, bytes);
    refresh_input_view(state);
    state.cursor = replace_at + inserted;
    return inserted != 0 or end > replace_at;
}

fn prompt_separators(c: *T.Client) []const u8 {
    const session = c.session orelse return "";
    return opts.options_get_string(session.options, "word-separators");
}

fn prompt_uses_vi_keys(c: *T.Client) bool {
    const session = c.session orelse return false;
    return opts.options_get_number(session.options, "status-keys") == T.MODEKEY_VI;
}

fn enter_command_mode(c: *T.Client, state: *PromptState) void {
    if (state.mode == .command) return;
    state.mode = .command;
    if (state.cursor != 0) state.cursor -= 1;
    state.quote_next = false;
    request_status_redraw(c);
}

fn enter_entry_mode(c: *T.Client, state: *PromptState) void {
    if (state.mode == .entry) return;
    state.mode = .entry;
    if (state.input.len() != 0 and state.cursor < state.input.len()) state.cursor += 1;
    state.quote_next = false;
    request_status_redraw(c);
}

fn enter_entry_mode_in_place(c: *T.Client, state: *PromptState) void {
    if (state.mode == .entry) return;
    state.mode = .entry;
    state.quote_next = false;
    request_status_redraw(c);
}

fn insert_prompt_data(state: *PromptState, data: *const T.Utf8Data) void {
    const insert_at = @min(state.cursor, state.input.len());
    state.input.insertData(insert_at, data);
    state.cursor = insert_at + 1;
    refresh_input_view(state);
}

fn prompt_forward_word(state: *PromptState, separators: []const u8) bool {
    const next = state.input.nextWordCursor(state.cursor, separators);
    if (state.cursor == next) return false;
    state.cursor = next;
    return true;
}

fn prompt_end_word(state: *PromptState, separators: []const u8) bool {
    const next = state.input.nextWordEndCursor(state.cursor, separators);
    if (state.cursor == next) return false;
    state.cursor = next;
    return true;
}

fn prompt_backward_word(state: *PromptState, separators: []const u8) bool {
    const next = state.input.previousWordCursor(state.cursor, separators);
    if (state.cursor == next) return false;
    state.cursor = next;
    return true;
}

fn save_prompt_range(state: *PromptState, start: usize, end: usize) void {
    const bytes = state.input.rangeToOwnedString(start, end);
    defer xm.allocator.free(bytes);
    set_prompt_saved_input(state, bytes);
}

fn delete_prompt_word_before_cursor(state: *PromptState, separators: []const u8) bool {
    const range = state.input.previousWordRange(state.cursor, separators);
    if (range.start == range.end) return false;

    save_prompt_range(state, range.start, range.end);
    return delete_prompt_range(state, range.start, range.end);
}

fn yank_saved_prompt(state: *PromptState) bool {
    if (state.saved_input.len() == 0) return false;
    const text = state.saved_input.toOwnedString();
    defer xm.allocator.free(text);
    insert_prompt_bytes(state, text);
    return true;
}

fn transpose_prompt_cells(state: *PromptState) bool {
    const size = state.input.len();
    var idx = @min(state.cursor, size);
    if (idx < size) idx += 1;
    if (idx < 2) return false;

    const left = idx - 2;
    const right = idx - 1;
    const tmp = state.input.cells.items[left];
    state.input.cells.items[left] = state.input.cells.items[right];
    state.input.cells.items[right] = tmp;
    state.cursor = idx;
    refresh_input_view(state);
    return true;
}

fn history_up(state: *PromptState) bool {
    const history = prompt_history(state.prompt_type);
    if (history.items.len == 0 or state.history_index == history.items.len) return false;
    state.history_index += 1;
    set_prompt_input(state, history.items[history.items.len - state.history_index]);
    return true;
}

fn history_down(state: *PromptState) bool {
    const history = prompt_history(state.prompt_type);
    if (history.items.len == 0 or state.history_index == 0) return false;
    state.history_index -= 1;
    if (state.history_index == 0)
        set_prompt_input(state, "")
    else
        set_prompt_input(state, history.items[history.items.len - state.history_index]);
    return true;
}

fn replace_prompt_complete(c: *T.Client, state: *PromptState, replacement: ?[]const u8) bool {
    const completecb = state.completecb orelse return false;
    const bounds = state.input.boundedRangeAtCursor(state.cursor, utf8.CELL_BUFFER_WHITESPACE);

    const word = state.input.rangeToOwnedString(bounds.start, bounds.end);
    defer xm.allocator.free(word);

    const owned_completion = if (replacement == null) completecb(c, state.data, word, bounds.start) else null;
    defer if (owned_completion) |value| xm.allocator.free(value);
    const completed = replacement orelse owned_completion orelse return false;
    if (std.mem.eql(u8, completed, word)) return false;
    return replace_prompt_range(state, bounds.start, bounds.end, completed);
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

fn render_prompt_cell(out: *std.ArrayList(u8), cell: *const T.Utf8Data) void {
    if (cell.size == 1 and (cell.data[0] <= 0x1f or cell.data[0] == 0x7f)) {
        out.append(xm.allocator, '^') catch unreachable;
        out.append(xm.allocator, if (cell.data[0] == 0x7f) '?' else cell.data[0] | 0x40) catch unreachable;
        return;
    }
    out.appendSlice(xm.allocator, cell.data[0..cell.size]) catch unreachable;
}

fn rendered_cell_width(cell: *const T.Utf8Data) u32 {
    if (cell.size == 1 and (cell.data[0] <= 0x1f or cell.data[0] == 0x7f)) return 2;
    return cell.width;
}

fn rendered_cursor_width(state: *const PromptState) u32 {
    var width: u32 = 0;
    const limit = @min(state.cursor, state.input.len());
    for (state.input.cells.items[0..limit]) |cell| width += rendered_cell_width(&cell);
    if (state.quote_next) width += 1;
    return width;
}

fn append_visible_render_items(
    state: *const PromptState,
    offset: u32,
    width: u32,
    out: *std.ArrayList(u8),
) void {
    if (width == 0) return;

    const limit = offset + width;
    var position: u32 = 0;
    var quote_written = false;

    for (state.input.cells.items, 0..) |cell, idx| {
        if (state.quote_next and !quote_written and idx == state.cursor) {
            if (position >= offset and position < limit)
                out.append(xm.allocator, '^') catch unreachable;
            position += 1;
            quote_written = true;
        }

        const cell_width = rendered_cell_width(&cell);
        const next = position + cell_width;

        if (cell_width == 0) {
            if (position >= offset and position < limit)
                render_prompt_cell(out, &cell);
            continue;
        }
        if (next <= offset) {
            position = next;
            continue;
        }
        if (position >= limit or next > limit) break;

        render_prompt_cell(out, &cell);
        position = next;
    }

    if (state.quote_next and !quote_written and state.cursor == state.input.len()) {
        if (position >= offset and position < limit)
            out.append(xm.allocator, '^') catch unreachable;
    }
}

fn append_quoted_key(state: *PromptState, event: *const T.key_event) bool {
    var data = std.mem.zeroes(T.Utf8Data);
    const masked = event.key & T.KEYC_MASK_KEY;

    if (masked == T.KEYC_BSPACE) {
        utf8.utf8_set(&data, 0x7f);
        data.width = 2;
        insert_prompt_data(state, &data);
        return true;
    }

    if (masked > 0x7f) {
        if (T.keycIsUnicode(event.key)) {
            const codepoint = std.math.cast(u21, masked) orelse return false;
            const glyph = utf8.Glyph.fromCodepoint(codepoint) orelse return false;
            insert_prompt_data(state, glyph.payload());
            return true;
        }
        return false;
    }

    const value: u8 = @intCast(if (event.key & T.KEYC_CTRL != 0) masked & 0x1f else masked);
    utf8.utf8_set(&data, value);
    if (value <= 0x1f or value == 0x7f) data.width = 2;
    insert_prompt_data(state, &data);
    return true;
}

fn command_mode_cursor_right(state: *PromptState) bool {
    const size = state.input.len();
    if (size == 0 or state.cursor + 1 >= size) return false;
    state.cursor += 1;
    return true;
}

fn command_mode_delete_current(state: *PromptState) bool {
    const size = state.input.len();
    if (size == 0 or state.cursor >= size) return false;
    const deleted = delete_prompt_at_cursor(state);
    if (deleted and state.input.len() != 0 and state.cursor == state.input.len())
        state.cursor -= 1;
    return deleted;
}

fn command_mode_delete_to_end(state: *PromptState) bool {
    const size = state.input.len();
    if (size == 0 or state.cursor >= size) return false;
    const deleted = delete_prompt_range(state, state.cursor, size);
    if (deleted and state.input.len() != 0 and state.cursor == state.input.len())
        state.cursor -= 1;
    return deleted;
}

fn handle_command_mode_key(c: *T.Client, state: *PromptState, event: *const T.key_event) bool {
    const masked = event.key & T.KEYC_MASK_KEY;
    const size = state.input.len();

    switch (event.key) {
        T.KEYC_BSPACE => {
            if (state.cursor > 0) state.cursor -= 1;
            request_status_redraw(c);
            return true;
        },
        'A' => {
            state.cursor = size;
            enter_entry_mode_in_place(c, state);
            request_status_redraw(c);
            return true;
        },
        'I' => {
            state.cursor = 0;
            enter_entry_mode_in_place(c, state);
            request_status_redraw(c);
            return true;
        },
        'C' => {
            _ = command_mode_delete_to_end(state);
            enter_entry_mode_in_place(c, state);
            prompt_changed(c, state, '=');
            return true;
        },
        's' => {
            _ = command_mode_delete_current(state);
            enter_entry_mode_in_place(c, state);
            prompt_changed(c, state, '=');
            return true;
        },
        'a' => {
            if (command_mode_cursor_right(state)) {}
            enter_entry_mode_in_place(c, state);
            if (size != 0 and state.cursor < state.input.len()) state.cursor += 1;
            request_status_redraw(c);
            return true;
        },
        'S' => {
            _ = delete_prompt_range(state, 0, state.input.len());
            enter_entry_mode_in_place(c, state);
            prompt_changed(c, state, '=');
            return true;
        },
        'i' => {
            enter_entry_mode_in_place(c, state);
            request_status_redraw(c);
            return true;
        },
        T.C0_ESC => return true,
        '$' => {
            state.cursor = size;
            request_status_redraw(c);
            return true;
        },
        '0', '^' => {
            state.cursor = 0;
            request_status_redraw(c);
            return true;
        },
        'D' => {
            if (command_mode_delete_to_end(state))
                prompt_changed(c, state, '=')
            else
                request_status_redraw(c);
            return true;
        },
        'X' => {
            if (state.cursor > 0) {
                state.cursor -= 1;
                if (delete_prompt_at_cursor(state))
                    prompt_changed(c, state, '=')
                else
                    request_status_redraw(c);
            } else {
                request_status_redraw(c);
            }
            return true;
        },
        'b' => {
            _ = prompt_backward_word(state, prompt_separators(c));
            request_status_redraw(c);
            return true;
        },
        'B' => {
            _ = prompt_backward_word(state, "");
            request_status_redraw(c);
            return true;
        },
        'd' => {
            if (delete_prompt_range(state, 0, state.input.len()))
                prompt_changed(c, state, '=')
            else
                request_status_redraw(c);
            return true;
        },
        'e' => {
            _ = prompt_end_word(state, prompt_separators(c));
            request_status_redraw(c);
            return true;
        },
        'E' => {
            _ = prompt_end_word(state, "");
            request_status_redraw(c);
            return true;
        },
        'w' => {
            _ = prompt_forward_word(state, prompt_separators(c));
            if (state.cursor == state.input.len() and state.cursor != 0) state.cursor -= 1;
            request_status_redraw(c);
            return true;
        },
        'W' => {
            _ = prompt_forward_word(state, "");
            if (state.cursor == state.input.len() and state.cursor != 0) state.cursor -= 1;
            request_status_redraw(c);
            return true;
        },
        'p' => {
            if (yank_saved_prompt(state))
                prompt_changed(c, state, '=')
            else
                request_status_redraw(c);
            return true;
        },
        'q' => {
            prompt_finish(c, state, null, true);
            return true;
        },
        T.KEYC_DC, 'x' => {
            if (command_mode_delete_current(state))
                prompt_changed(c, state, '=')
            else
                request_status_redraw(c);
            return true;
        },
        T.KEYC_DOWN, 'j' => {
            if (history_down(state))
                prompt_changed(c, state, '=')
            else
                request_status_redraw(c);
            if (state.input.len() != 0 and state.cursor == state.input.len()) state.cursor -= 1;
            return true;
        },
        T.KEYC_LEFT, 'h' => {
            if (state.cursor > 0) state.cursor -= 1;
            request_status_redraw(c);
            return true;
        },
        T.KEYC_RIGHT, 'l' => {
            _ = command_mode_cursor_right(state);
            request_status_redraw(c);
            return true;
        },
        T.KEYC_UP, 'k' => {
            if (history_up(state))
                prompt_changed(c, state, '=')
            else
                request_status_redraw(c);
            if (state.input.len() != 0 and state.cursor == state.input.len()) state.cursor -= 1;
            return true;
        },
        'h' | T.KEYC_CTRL, 'c' | T.KEYC_CTRL => {
            prompt_finish(c, state, null, true);
            return true;
        },
        else => {},
    }

    if (masked == T.C0_CR or masked == T.C0_LF or masked == T.KEYC_KP_ENTER) {
        const text = state_copy_input(state);
        defer xm.allocator.free(text);
        if (text.len != 0)
            status_prompt_history_add(text, state.prompt_type);
        prompt_finish(c, state, text, true);
        return true;
    }

    return true;
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

test "status_prompt_type maps names and status_prompt_type_string round-trips" {
    const pairs = [_]struct { name: []const u8, want: PromptType }{
        .{ .name = "command", .want = .command },
        .{ .name = "search", .want = .search },
        .{ .name = "target", .want = .target },
        .{ .name = "window-target", .want = .window_target },
        .{ .name = "bogus", .want = .invalid },
    };
    for (pairs) |p| {
        const got = status_prompt_type(p.name);
        try std.testing.expectEqual(p.want, got);
        if (got != .invalid) {
            try std.testing.expectEqualStrings(p.name, status_prompt_type_string(got));
        }
    }
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

pub fn status_prompt_command_mode(c: *T.Client) bool {
    const state = find_state(c) orelse return false;
    return state.mode == .command;
}

pub fn status_prompt_render_state(c: *T.Client, available_width: u32) ?PromptRenderState {
    const state = find_state(c) orelse return null;
    const cursor_width = rendered_cursor_width(state);

    var offset: u32 = 0;
    if (available_width != 0 and cursor_width >= available_width)
        offset = (cursor_width - available_width) + 1;

    var out: std.ArrayList(u8) = .{};
    append_visible_render_items(state, offset, available_width, &out);
    return .{
        .input_visible = out.toOwnedSlice(xm.allocator) catch unreachable,
        .cursor_column = cursor_width - offset,
        .command_prompt = state.mode == .command,
    };
}

pub fn status_prompt_set(
    c: *T.Client,
    fs: ?*const T.CmdFindState,
    msg: []const u8,
    input: ?[]const u8,
    inputcb: PromptInputCb,
    completecb: ?PromptCompleteCb,
    freecb: ?PromptFreeCb,
    data: ?*anyopaque,
    flags: u32,
    prompt_type: PromptType,
) void {
    const expanded_input = expand_input(fs, input orelse "", flags);
    errdefer xm.allocator.free(expanded_input);

    status_runtime.status_message_clear(c);
    status_prompt_clear(c);
    ensure_init();

    const state = xm.allocator.create(PromptState) catch unreachable;
    state.* = .{
        .prompt_string = xm.xstrdup(msg),
        .input_view = xm.xstrdup(""),
        .flags = flags,
        .prompt_type = prompt_type,
        .inputcb = inputcb,
        .completecb = completecb,
        .freecb = freecb,
        .data = data,
    };
    set_prompt_last_input(state, expanded_input);
    if (flags & PROMPT_INCREMENTAL == 0) {
        set_prompt_input(state, expanded_input);
    }
    xm.allocator.free(expanded_input);

    prompt_states.put(state_key(c), state) catch unreachable;
    status_runtime.status_prompt_enter(c, flags & PROMPT_INCREMENTAL == 0);

    if (flags & PROMPT_INCREMENTAL != 0)
        _ = inputcb(c, data, "=", false);
}

pub fn status_prompt_update(c: *T.Client, msg: []const u8, input: ?[]const u8) void {
    const state = find_state(c) orelse return;

    xm.allocator.free(state.prompt_string);
    state.prompt_string = xm.xstrdup(msg);

    set_prompt_last_input(state, input orelse "");
    set_prompt_input(state, input orelse "");
    state.history_index = 0;
    state.quote_next = false;
    request_status_redraw(c);
}

pub fn status_prompt_clear(c: *T.Client) void {
    if (!prompt_states_init) return;
    const removed = prompt_states.fetchRemove(state_key(c)) orelse return;
    prompt_state_free(removed.value);
    status_runtime.status_prompt_leave(c);
}

/// Handle a raw key code in the prompt (tmux `status_prompt_key`).
/// zmux routes keys through `key_event`; this wrapper exists for C-name parity.
pub fn status_prompt_key(c: *T.Client, key: T.key_code) i32 {
    var event = T.key_event{ .key = key };
    return @intFromBool(status_prompt_handle_key(c, &event));
}

/// Map a terminal column click to a cursor character index.
/// `click_col` is relative to the start of the input area; `offset` is the
/// horizontal scroll amount from `status_prompt_render_state`.
fn mouse_set_cursor(st: *PromptState, click_col: u32, offset: u32) void {
    var col: u32 = 0;
    const target_col = click_col + offset;
    for (st.input.cells.items, 0..) |cell, idx| {
        const w = rendered_cell_width(&cell);
        if (col + w > target_col) {
            st.cursor = idx;
            return;
        }
        col += w;
    }
    st.cursor = st.input.len();
}

pub fn status_prompt_handle_key(c: *T.Client, event: *const T.key_event) bool {
    const state = find_state(c) orelse return false;
    const masked = event.key & T.KEYC_MASK_KEY;

    // Mouse events must be handled before PROMPT_KEY / PROMPT_NUMERIC so
    // they don't accidentally finish the prompt with a key-name string.
    if (T.keycIsMouse(event.key)) {
        const m = &event.m;
        if (T.mouseButtons(m.b) == T.MOUSE_BUTTON_1 and
            !T.mouseRelease(m.b) and !T.mouseDrag(m.b) and !T.mouseWheel(m.b))
        {
            if (status_mod.status_prompt_input_geometry(c)) |geom| {
                if (status_mod.status_prompt_row(c)) |row| {
                    const prompt_row = row + geom.line;
                    if (m.y == prompt_row and m.x >= geom.input_x and
                        m.x < geom.input_x + geom.input_width)
                    {
                        const click_col = m.x - geom.input_x;
                        const cursor_width = rendered_cursor_width(state);
                        const offset: u32 = if (geom.input_width != 0 and cursor_width >= geom.input_width)
                            (cursor_width - geom.input_width) + 1
                        else
                            0;
                        mouse_set_cursor(state, click_col, offset);
                        request_status_redraw(c);
                    }
                }
            }
        }
        return true;
    }

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

    if (state.quote_next) {
        state.quote_next = false;
        if (append_quoted_key(state, event))
            prompt_changed(c, state, '=')
        else
            request_status_redraw(c);
        return true;
    }

    if (state.flags & PROMPT_SINGLE != 0) {
        var buf: [4]u8 = undefined;
        const text = single_prompt_text(event.key, &buf) orelse return true;
        prompt_finish(c, state, text, true);
        return true;
    }

    if (prompt_uses_vi_keys(c)) {
        if (state.mode == .entry and masked == T.C0_ESC) {
            enter_command_mode(c, state);
            return true;
        }
        if (state.mode == .command)
            return handle_command_mode_key(c, state, event);
    } else if (state.mode == .command) {
        state.mode = .entry;
    }

    switch (event.key) {
        T.KEYC_LEFT, 'b' | T.KEYC_CTRL => {
            if (state.cursor > 0) {
                state.cursor -= 1;
                request_status_redraw(c);
            }
            return true;
        },
        T.KEYC_RIGHT, 'f' | T.KEYC_CTRL => {
            if (state.cursor < state.input.len()) {
                state.cursor += 1;
                request_status_redraw(c);
            }
            return true;
        },
        T.KEYC_HOME, 'a' | T.KEYC_CTRL => {
            if (state.cursor != 0) {
                state.cursor = 0;
                request_status_redraw(c);
            }
            return true;
        },
        T.KEYC_END, 'e' | T.KEYC_CTRL => {
            const size = state.input.len();
            if (state.cursor != size) {
                state.cursor = size;
                request_status_redraw(c);
            }
            return true;
        },
        T.C0_HT => {
            if (replace_prompt_complete(c, state, null))
                prompt_changed(c, state, '=')
            else
                request_status_redraw(c);
            return true;
        },
        T.KEYC_DC, 'd' | T.KEYC_CTRL => {
            if (delete_prompt_at_cursor(state))
                prompt_changed(c, state, '=')
            else
                request_status_redraw(c);
            return true;
        },
        T.KEYC_UP, 'p' | T.KEYC_CTRL => {
            if (history_up(state))
                prompt_changed(c, state, '=')
            else
                request_status_redraw(c);
            return true;
        },
        T.KEYC_DOWN, 'n' | T.KEYC_CTRL => {
            if (history_down(state))
                prompt_changed(c, state, '=')
            else
                request_status_redraw(c);
            return true;
        },
        'u' | T.KEYC_CTRL => {
            if (delete_prompt_range(state, 0, state.cursor))
                prompt_changed(c, state, '=')
            else
                request_status_redraw(c);
            return true;
        },
        'k' | T.KEYC_CTRL => {
            if (delete_prompt_range(state, state.cursor, state.input.len()))
                prompt_changed(c, state, '=')
            else
                request_status_redraw(c);
            return true;
        },
        'r' | T.KEYC_CTRL => {
            if (state.flags & PROMPT_INCREMENTAL != 0) {
                if (state.input.len() == 0) {
                    const text = state.last_input.toOwnedString();
                    defer xm.allocator.free(text);
                    set_prompt_input(state, text);
                    prompt_changed(c, state, '=');
                } else {
                    prompt_changed(c, state, '-');
                }
                return true;
            }
        },
        's' | T.KEYC_CTRL => {
            if (state.flags & PROMPT_INCREMENTAL != 0) {
                if (state.input.len() == 0) {
                    const text = state.last_input.toOwnedString();
                    defer xm.allocator.free(text);
                    set_prompt_input(state, text);
                    prompt_changed(c, state, '=');
                } else {
                    prompt_changed(c, state, '+');
                }
                return true;
            }
        },
        'v' | T.KEYC_CTRL => {
            state.quote_next = true;
            request_status_redraw(c);
            return true;
        },
        'w' | T.KEYC_CTRL => {
            if (delete_prompt_word_before_cursor(state, prompt_separators(c)))
                prompt_changed(c, state, '=')
            else
                request_status_redraw(c);
            return true;
        },
        'y' | T.KEYC_CTRL => {
            if (yank_saved_prompt(state))
                prompt_changed(c, state, '=')
            else
                request_status_redraw(c);
            return true;
        },
        't' | T.KEYC_CTRL => {
            if (transpose_prompt_cells(state))
                prompt_changed(c, state, '=')
            else
                request_status_redraw(c);
            return true;
        },
        T.KEYC_LEFT | T.KEYC_CTRL, 'b' | T.KEYC_META => {
            _ = prompt_backward_word(state, prompt_separators(c));
            request_status_redraw(c);
            return true;
        },
        T.KEYC_RIGHT | T.KEYC_CTRL, 'f' | T.KEYC_META => {
            _ = prompt_forward_word(state, prompt_separators(c));
            request_status_redraw(c);
            return true;
        },
        else => {},
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
        if (delete_prompt_before_cursor(state))
            prompt_changed(c, state, '=')
        else
            request_status_redraw(c);
        return true;
    }

    if (!append_event(state, event)) return true;

    if (state.flags & PROMPT_SINGLE != 0) {
        const text = state_copy_input(state);
        defer xm.allocator.free(text);
        prompt_finish(c, state, text, true);
        return true;
    }

    prompt_changed(c, state, '=');
    return true;
}

// ── Prompt history file I/O ─────────────────────────────────────────────

fn historyFilePath() ?[]u8 {
    const history_file = opts.options_get_string(opts.global_options, "history-file");
    if (history_file.len == 0) return null;
    if (history_file[0] == '/') return xm.xstrdup(history_file);

    if (history_file.len < 2 or history_file[0] != '~' or history_file[1] != '/') return null;
    const home = std.posix.getenv("HOME") orelse return null;
    return std.fmt.allocPrint(xm.allocator, "{s}{s}", .{ home, history_file[1..] }) catch null;
}

pub fn status_prompt_load_history() void {
    const path = historyFilePath() orelse return;
    defer xm.allocator.free(path);

    const file = std.fs.cwd().openFile(path, .{}) catch return;
    defer file.close();

    const stat = file.stat() catch return;
    if (stat.size == 0 or stat.size > 1024 * 1024) return;

    const buf = xm.allocator.alloc(u8, stat.size) catch return;
    defer xm.allocator.free(buf);

    const bytes_read = file.readAll(buf) catch return;
    if (bytes_read == 0) return;
    const data = buf[0..bytes_read];

    ensure_histories_init();
    var start: usize = 0;
    while (start < data.len) {
        const eol = std.mem.indexOfScalarPos(u8, data, start, '\n') orelse data.len;
        const line = std.mem.trimRight(u8, data[start..eol], "\r");
        start = if (eol < data.len) eol + 1 else data.len;
        if (line.len == 0) continue;

        addTypedHistoryFromLine(line);
    }
}

fn addTypedHistoryFromLine(line: []const u8) void {
    const colon_pos = std.mem.indexOfScalar(u8, line, ':');
    if (colon_pos == null or colon_pos.? == 0) {
        status_prompt_history_add(line, .command);
        return;
    }
    const type_str = line[0..colon_pos.?];
    const rest = line[colon_pos.? + 1 ..];
    const prompt_type = status_prompt_type(type_str);
    if (prompt_type == .invalid) {
        status_prompt_history_add(line, .command);
    } else {
        status_prompt_history_add(rest, prompt_type);
    }
}

pub fn status_prompt_save_history() void {
    const path = historyFilePath() orelse return;
    defer xm.allocator.free(path);

    if (!prompt_histories_init) return;

    const file = std.fs.cwd().createFile(path, .{ .truncate = true }) catch return;
    defer file.close();

    for (0..prompt_type_count) |type_idx| {
        const prompt_type: PromptType = @enumFromInt(@as(u8, @intCast(type_idx)));
        const type_str = status_prompt_type_string(prompt_type);
        const history = &prompt_histories[type_idx];
        for (history.items) |item| {
            var buf: [4096]u8 = undefined;
            const line = std.fmt.bufPrint(&buf, "{s}:{s}\n", .{ type_str, item }) catch continue;
            file.writeAll(line) catch {};
        }
    }
}

// ── Ported tmux functions ───────────────────────────────────────────────

const options_table = @import("options-table.zig");
const session_mod = @import("session.zig");
const paste = @import("paste.zig");
const menu_mod = @import("menu.zig");
const resize_mod = @import("resize.zig");
const format_draw = @import("format-draw.zig");

/// Accept prompt immediately (port of tmux status_prompt_accept).
/// Used as a cmdq callback when PROMPT_ACCEPT is set.
pub fn status_prompt_accept(c: *T.Client) void {
    const state = find_state(c) orelse return;
    _ = state.inputcb(c, state.data, "y", true);
    status_prompt_clear(c);
}

/// Paste into prompt from the paste buffer or saved yank
/// (port of tmux status_prompt_paste).
pub fn status_prompt_paste(c: *T.Client) bool {
    const state = find_state(c) orelse return false;

    if (state.saved_input.len() != 0)
        return yank_saved_prompt(state);

    const pb = paste.paste_get_top(null) orelse return false;
    var bufsize: usize = 0;
    const bufdata = paste.paste_buffer_data(pb, &bufsize);
    if (bufsize == 0) return false;

    var sanitized: std.ArrayList(u8) = .{};
    defer sanitized.deinit(xm.allocator);

    var i: usize = 0;
    while (i < bufsize) {
        const ch = bufdata[i];
        if (ch <= 31 or ch >= 127) break;
        sanitized.append(xm.allocator, ch) catch unreachable;
        i += 1;
    }

    if (sanitized.items.len == 0) return false;
    insert_prompt_bytes(state, sanitized.items);
    return true;
}

/// Redraw a single prompt character with control-char rendering
/// (port of tmux status_prompt_redraw_character).
/// Returns true if drawing should continue.
pub fn status_prompt_redraw_character(
    out: *std.ArrayList(u8),
    offset: u32,
    pwidth: u32,
    width: *u32,
    ud: *const T.Utf8Data,
) bool {
    if (width.* < offset) {
        width.* += ud.width;
        return true;
    }
    if (width.* >= offset + pwidth)
        return false;
    width.* += ud.width;
    if (width.* > offset + pwidth)
        return false;

    render_prompt_cell(out, ud);
    return true;
}

/// Redraw quote indicator '^' if necessary
/// (port of tmux status_prompt_redraw_quote).
/// Returns true if drawing should continue.
pub fn status_prompt_redraw_quote(
    c: *T.Client,
    pcursor: u32,
    out: *std.ArrayList(u8),
    offset: u32,
    pwidth: u32,
    width: *u32,
) bool {
    const state = find_state(c) orelse return true;
    if (!state.quote_next) return true;
    const cursor_col = rendered_cursor_width(state);
    if (cursor_col != pcursor + 1) return true;
    var ud = std.mem.zeroes(T.Utf8Data);
    utf8.utf8_set(&ud, '^');
    return status_prompt_redraw_character(out, offset, pwidth, width, &ud);
}

/// Check if a utf8 character is in a separator list
/// (port of tmux status_prompt_in_list).
pub fn status_prompt_in_list(ws: []const u8, ud: *const T.Utf8Data) bool {
    if (ud.size != 1 or ud.width != 1) return false;
    return std.mem.indexOfScalar(u8, ws, ud.data[0]) != null;
}

/// Check if a utf8 character is a space
/// (port of tmux status_prompt_space).
pub fn status_prompt_space(ud: *const T.Utf8Data) bool {
    if (ud.size != 1 or ud.width != 1) return false;
    return ud.data[0] == ' ';
}

/// Translate vi key to emacs equivalent
/// (port of tmux status_prompt_translate_key).
/// Returns 0 to drop, 1 to process as emacs key, 2 to append.
pub fn status_prompt_translate_key(c: *T.Client, key: T.key_code, new_key: *T.key_code) i32 {
    const state = find_state(c) orelse return 0;
    if (state.mode == .entry) {
        switch (key) {
            'a' | T.KEYC_CTRL,
            'c' | T.KEYC_CTRL,
            'e' | T.KEYC_CTRL,
            'g' | T.KEYC_CTRL,
            'h' | T.KEYC_CTRL,
            T.C0_HT,
            'k' | T.KEYC_CTRL,
            'n' | T.KEYC_CTRL,
            'p' | T.KEYC_CTRL,
            't' | T.KEYC_CTRL,
            'u' | T.KEYC_CTRL,
            'v' | T.KEYC_CTRL,
            'w' | T.KEYC_CTRL,
            'y' | T.KEYC_CTRL,
            T.C0_CR,
            T.C0_LF,
            T.KEYC_LEFT | T.KEYC_CTRL,
            T.KEYC_RIGHT | T.KEYC_CTRL,
            T.KEYC_BSPACE,
            T.KEYC_DC,
            T.KEYC_DOWN,
            T.KEYC_END,
            T.KEYC_HOME,
            T.KEYC_LEFT,
            T.KEYC_RIGHT,
            T.KEYC_UP,
            => {
                new_key.* = key;
                return 1;
            },
            T.C0_ESC => {
                enter_command_mode(c, state);
                return 0;
            },
            else => {},
        }
        new_key.* = key;
        return 2;
    }
    new_key.* = key;
    return 0;
}

/// Forward word motion (port of tmux status_prompt_forward_word).
pub fn status_prompt_forward_word(c: *T.Client) void {
    const state = find_state(c) orelse return;
    _ = prompt_forward_word(state, prompt_separators(c));
}

/// Backward word motion (port of tmux status_prompt_backward_word).
pub fn status_prompt_backward_word(c: *T.Client) void {
    const state = find_state(c) orelse return;
    _ = prompt_backward_word(state, prompt_separators(c));
}

/// End-of-word motion (port of tmux status_prompt_end_word).
pub fn status_prompt_end_word(c: *T.Client) void {
    const state = find_state(c) orelse return;
    _ = prompt_end_word(state, prompt_separators(c));
}

/// History up (port of tmux status_prompt_up_history).
pub fn status_prompt_up_history(c: *T.Client) ?[]const u8 {
    const state = find_state(c) orelse return null;
    if (!history_up(state)) return null;
    return state_current_input(state);
}

/// History down (port of tmux status_prompt_down_history).
pub fn status_prompt_down_history(c: *T.Client) ?[]const u8 {
    const state = find_state(c) orelse return null;
    if (!history_down(state)) return null;
    return state_current_input(state);
}

/// Add a line to history (port of tmux status_prompt_add_history).
pub fn status_prompt_add_history(line: []const u8, prompt_type: PromptType) void {
    status_prompt_history_add(line, prompt_type);
}

/// Add a typed history line from a file (port of tmux status_prompt_add_typed_history).
pub fn status_prompt_add_typed_history(line: []const u8) void {
    addTypedHistoryFromLine(line);
}

/// Find the history file path (port of tmux status_prompt_find_history_file).
pub fn status_prompt_find_history_file() ?[]u8 {
    return historyFilePath();
}

/// Data for the completion menu callback.
const StatusPromptMenu = struct {
    c: *T.Client,
    start: u32,
    size: u32,
    list: [][]u8,
    flag: u8,
};

/// Menu callback for prompt completion
/// (port of tmux status_prompt_menu_callback).
fn status_prompt_menu_callback(spm: *StatusPromptMenu, idx: u32) void {
    const c = spm.c;
    const state = find_state(c) orelse return;
    if (idx >= spm.size) return;
    const actual_idx = spm.start + idx;
    if (actual_idx >= spm.list.len) return;

    var s: []u8 = undefined;
    if (spm.flag == 0) {
        s = xm.xstrdup(spm.list[actual_idx]);
    } else {
        s = std.fmt.allocPrint(xm.allocator, "-{c}{s}", .{ spm.flag, spm.list[actual_idx] }) catch unreachable;
    }
    defer xm.allocator.free(s);

    if (state.prompt_type == .window_target) {
        set_prompt_input(state, s);
        request_status_redraw(c);
    } else if (replace_prompt_complete(c, state, s)) {
        request_status_redraw(c);
    }
}

/// Free a StatusPromptMenu's list entries.
fn status_prompt_menu_free(spm: *StatusPromptMenu) void {
    for (spm.list) |item| xm.allocator.free(item);
    xm.allocator.free(spm.list);
    xm.allocator.destroy(spm);
}

/// Sort completion list (port of tmux status_prompt_complete_sort).
pub fn status_prompt_complete_sort(list: *std.ArrayList([]const u8)) void {
    if (list.items.len < 2) return;
    std.mem.sort([]const u8, list.items, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lessThan);
}

/// Build completion list including commands, aliases, options, and layouts
/// (port of tmux status_prompt_complete_list).
pub fn status_prompt_complete_list(word: []const u8, at_start: bool) std.ArrayList([]const u8) {
    var list = std.ArrayList([]const u8).init(xm.allocator);
    const slen = word.len;

    for (cmd_mod.cmd_entries()) |entry| {
        if (entry.name.len >= slen and std.mem.eql(u8, entry.name[0..slen], word))
            status_prompt_add_list(&list, entry.name);
        if (entry.alias) |alias| {
            if (alias.len >= slen and std.mem.eql(u8, alias[0..slen], word))
                status_prompt_add_list(&list, alias);
        }
    }

    if (opts.options_get_only(opts.global_options, "command-alias")) |v| {
        var a = opts.options_array_first(v);
        while (a) |item| {
            const value = opts.options_array_item_value(item);
            if (std.mem.indexOfScalar(u8, value, '=')) |eq_pos| {
                const alias_name = value[0..eq_pos];
                if (alias_name.len >= slen and std.mem.eql(u8, alias_name[0..slen], word))
                    status_prompt_add_list(&list, alias_name);
            }
            a = opts.options_array_next(v, item);
        }
    }

    if (at_start) return list;

    for (options_table.options_table) |*oe| {
        if (oe.name.len >= slen and std.mem.eql(u8, oe.name[0..slen], word))
            status_prompt_add_list(&list, oe.name);
    }

    const layouts = [_][]const u8{
        "even-horizontal",       "even-vertical",
        "main-horizontal",       "main-horizontal-mirrored",
        "main-vertical",         "main-vertical-mirrored",
        "tiled",
    };
    for (&layouts) |layout| {
        if (layout.len >= slen and std.mem.eql(u8, layout[0..slen], word))
            status_prompt_add_list(&list, layout);
    }

    return list;
}

/// Complete a session name (port of tmux status_prompt_complete_session).
pub fn status_prompt_complete_session(
    list: *std.ArrayList([]const u8),
    s: []const u8,
    flag: u8,
) ?[]u8 {
    if (!@hasDecl(session_mod, "sessions")) return null;

    var it = session_mod.sessions.valueIterator();
    while (it.next()) |sess_ptr| {
        const sess = sess_ptr.*;
        if (s.len == 0 or
            (sess.name.len >= s.len and std.mem.eql(u8, sess.name[0..s.len], s)))
        {
            const with_colon = std.fmt.allocPrint(xm.allocator, "{s}:", .{sess.name}) catch unreachable;
            defer xm.allocator.free(with_colon);
            status_prompt_add_list(list, with_colon);
        } else if (s.len > 0 and s[0] == '$') {
            const id_str = std.fmt.allocPrint(xm.allocator, "{d}", .{sess.id}) catch unreachable;
            defer xm.allocator.free(id_str);
            const rest = s[1..];
            if (rest.len == 0 or
                (id_str.len >= rest.len and std.mem.eql(u8, id_str[0..rest.len], rest)))
            {
                const with_dollar = std.fmt.allocPrint(xm.allocator, "${s}:", .{id_str}) catch unreachable;
                defer xm.allocator.free(with_dollar);
                status_prompt_add_list(list, with_dollar);
            }
        }
    }

    const out = status_prompt_complete_prefix(list.items) orelse return null;
    if (flag != 0) {
        const tmp = std.fmt.allocPrint(xm.allocator, "-{c}{s}", .{ flag, out }) catch unreachable;
        xm.allocator.free(out);
        return tmp;
    }
    return out;
}

/// Complete window targets from a session
/// (port of tmux status_prompt_complete_window_menu).
/// Returns the sole match if unique, otherwise null (menu display deferred).
pub fn status_prompt_complete_window_menu(
    c: *T.Client,
    s: *T.Session,
    word: []const u8,
    flag: u8,
) ?[]u8 {
    const state = find_state(c) orelse return null;
    var items = std.ArrayList([]u8).init(xm.allocator);
    defer {
        for (items.items) |item| xm.allocator.free(item);
        items.deinit(xm.allocator);
    }

    var wl_it = s.windows.valueIterator();
    while (wl_it.next()) |wl_ptr| {
        const wl = wl_ptr.*;
        if (word.len != 0) {
            const idx_str = std.fmt.allocPrint(xm.allocator, "{d}", .{wl.idx}) catch unreachable;
            defer xm.allocator.free(idx_str);
            if (idx_str.len < word.len or !std.mem.eql(u8, idx_str[0..word.len], word)) continue;
        }

        if (state.prompt_type == .window_target) {
            items.append(
                xm.allocator,
                std.fmt.allocPrint(xm.allocator, "{d}", .{wl.idx}) catch unreachable,
            ) catch unreachable;
        } else {
            items.append(
                xm.allocator,
                std.fmt.allocPrint(xm.allocator, "{s}:{d}", .{ s.name, wl.idx }) catch unreachable,
            ) catch unreachable;
        }
        if (items.items.len >= 10) break;
    }

    if (items.items.len == 0) return null;
    if (items.items.len == 1) {
        if (flag != 0) {
            const tmp = std.fmt.allocPrint(xm.allocator, "-{c}{s}", .{ flag, items.items[0] }) catch unreachable;
            return tmp;
        }
        return xm.xstrdup(items.items[0]);
    }

    const const_items = @as([][]const u8, items.items);
    return status_prompt_complete_prefix(const_items);
}

/// Show the completion list as a popup menu
/// (port of tmux status_prompt_complete_list_menu).
/// Returns true if a menu was shown (currently a no-op placeholder since
/// the zmux menu infrastructure does not yet support arbitrary callbacks).
pub fn status_prompt_complete_list_menu(
    c: *T.Client,
    list: *std.ArrayList([]const u8),
    _offset: u32,
    _flag: u8,
) bool {
    _ = _offset;
    _ = _flag;
    if (list.items.len <= 1) return false;

    const lines = resize_mod.status_line_size(c);
    if (c.tty.sy <= lines + 2) return false;

    return false;
}

/// Replace completion at cursor (port of tmux status_prompt_replace_complete).
pub fn status_prompt_replace_complete_public(c: *T.Client, s: ?[]const u8) bool {
    const state = find_state(c) orelse return false;
    return replace_prompt_complete(c, state, s);
}

/// Full word completion dispatcher
/// (port of tmux status_prompt_complete).
/// Handles command, option, session, and window-target completion.
pub fn status_prompt_complete_full(c: *T.Client, word: []const u8, offset: u32) ?[]u8 {
    const state = find_state(c) orelse return status_prompt_complete(word, offset == 0);

    if (word.len == 0 and
        state.prompt_type != .target and
        state.prompt_type != .window_target)
        return null;

    if (state.prompt_type != .target and
        state.prompt_type != .window_target and
        !std.mem.startsWith(u8, word, "-t") and
        !std.mem.startsWith(u8, word, "-s"))
    {
        var list = status_prompt_complete_list(word, offset == 0);
        defer {
            list.deinit(xm.allocator);
        }

        if (list.items.len == 0) return null;
        if (list.items.len == 1)
            return std.fmt.allocPrint(xm.allocator, "{s} ", .{list.items[0]}) catch unreachable;

        status_prompt_complete_sort(&list);
        const prefix = status_prompt_complete_prefix(list.items);
        if (prefix) |p| {
            if (std.mem.eql(u8, word, p)) {
                xm.allocator.free(p);
                _ = status_prompt_complete_list_menu(c, &list, offset, 0);
                return null;
            }
        }
        return prefix;
    }

    var s: []const u8 = undefined;
    var flag: u8 = 0;
    if (state.prompt_type == .target or state.prompt_type == .window_target) {
        s = word;
        flag = 0;
    } else {
        if (word.len < 2) return null;
        s = word[2..];
        flag = word[1];
    }

    if (state.prompt_type == .window_target) {
        const sess = c.session orelse return null;
        const out = status_prompt_complete_window_menu(c, sess, s, 0);
        return out;
    }

    const colon_pos = std.mem.indexOfScalar(u8, s, ':');
    if (colon_pos == null) {
        var list = std.ArrayList([]const u8).init(xm.allocator);
        defer list.deinit(xm.allocator);
        return status_prompt_complete_session(&list, s, flag);
    }

    const colon = colon_pos.?;
    if (std.mem.indexOfScalar(u8, s[colon + 1 ..], '.') == null) {
        const sess = blk: {
            if (colon == 0) {
                break :blk c.session;
            } else {
                const sess_name = s[0..colon];
                break :blk session_mod.session_find(sess_name);
            }
        } orelse return null;
        return status_prompt_complete_window_menu(c, sess, s[colon + 1 ..], flag);
    }

    return null;
}

// ── Prompt completion ───────────────────────────────────────────────────

pub fn status_prompt_complete(word: []const u8, at_start: bool) ?[]u8 {
    if (word.len == 0 and !at_start) return null;

    var list: std.ArrayList([]const u8) = .{};
    defer {
        list.deinit(xm.allocator);
    }
    const slen = word.len;

    // Match against command names and aliases
    for (cmd_mod.cmd_entries()) |entry| {
        if (entry.name.len >= slen and std.mem.eql(u8, entry.name[0..slen], word)) {
            status_prompt_add_list(&list, entry.name);
        }
        if (entry.alias) |alias| {
            if (alias.len >= slen and std.mem.eql(u8, alias[0..slen], word)) {
                status_prompt_add_list(&list, alias);
            }
        }
    }

    if (at_start) return completeFromList(list.items);

    // Match against layout names
    const layouts = [_][]const u8{
        "even-horizontal",       "even-vertical",
        "main-horizontal",       "main-horizontal-mirrored",
        "main-vertical",         "main-vertical-mirrored",
        "tiled",
    };
    for (&layouts) |layout| {
        if (layout.len >= slen and std.mem.eql(u8, layout[0..slen], word)) {
            status_prompt_add_list(&list, layout);
        }
    }

    return completeFromList(list.items);
}

/// Add a unique string to a completion list (tmux `status_prompt_add_list`).
pub fn status_prompt_add_list(list: *std.ArrayList([]const u8), s: []const u8) void {
    for (list.items) |item| {
        if (std.mem.eql(u8, item, s)) return;
    }
    list.append(xm.allocator, s) catch unreachable;
}

fn completeFromList(items: [][]const u8) ?[]u8 {
    if (items.len == 0) return null;
    if (items.len == 1) {
        return std.fmt.allocPrint(xm.allocator, "{s} ", .{items[0]}) catch unreachable;
    }
    return status_prompt_complete_prefix(items);
}

/// Longest common prefix of completion candidates (tmux `status_prompt_complete_prefix`).
pub fn status_prompt_complete_prefix(items: [][]const u8) ?[]u8 {
    if (items.len == 0) return null;
    var shortest: usize = items[0].len;
    for (items[1..]) |item| shortest = @min(shortest, item.len);

    var common_len: usize = shortest;
    outer: while (common_len > 0) : (common_len -= 1) {
        const ch = items[0][common_len - 1];
        for (items[1..]) |item| {
            if (item[common_len - 1] != ch) continue :outer;
        }
        break;
    }
    if (common_len == 0) return null;
    return xm.xstrdup(items[0][0..common_len]);
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

fn send_prompt_key(client: *T.Client, key: T.key_code, bytes: []const u8) bool {
    var event = T.key_event{ .key = key, .len = bytes.len };
    if (bytes.len != 0) @memcpy(event.data[0..bytes.len], bytes);
    return status_prompt_handle_key(client, &event);
}

fn test_complete(_: *T.Client, _: ?*anyopaque, word: []const u8, offset: usize) ?[]u8 {
    if (offset == 0 and std.mem.eql(u8, word, "ren"))
        return xm.xstrdup("rename-window ");
    return null;
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
        .status = .{},
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
        null,
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
        .status = .{},
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
        null,
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

test "status-prompt supports cursor edits, history traversal, completion, and render windows" {
    opts.global_options = opts.options_create(null);
    defer opts.options_free(opts.global_options);
    opts.options_default_all(opts.global_options, T.OPTIONS_TABLE_SERVER);

    var environ = T.Environ.init(xm.allocator);
    defer environ.deinit();
    var client = T.Client{
        .environ = &environ,
        .tty = undefined,
        .status = .{},
    };
    client.tty.client = &client;

    const capture = xm.allocator.create(PromptCapture) catch unreachable;
    capture.* = .{};

    status_prompt_history_clear(null);
    defer status_prompt_history_clear(null);
    status_prompt_history_add("one", .command);
    status_prompt_history_add("two", .command);

    status_prompt_set(
        &client,
        null,
        "Prompt ",
        "abc",
        capture_prompt_input,
        test_complete,
        free_prompt_capture,
        capture,
        0,
        .command,
    );
    defer status_prompt_clear(&client);

    try std.testing.expect(send_prompt_key(&client, T.KEYC_LEFT, ""));
    try std.testing.expect(send_prompt_key(&client, 'X', "X"));
    try std.testing.expectEqualStrings("abXc", status_prompt_input(&client).?);

    try std.testing.expect(send_prompt_key(&client, T.KEYC_DC, ""));
    try std.testing.expectEqualStrings("abX", status_prompt_input(&client).?);

    try std.testing.expect(send_prompt_key(&client, T.KEYC_HOME, ""));
    try std.testing.expect(send_prompt_key(&client, '>', ">"));
    try std.testing.expectEqualStrings(">abX", status_prompt_input(&client).?);

    try std.testing.expect(send_prompt_key(&client, T.KEYC_END, ""));
    try std.testing.expect(send_prompt_key(&client, T.C0_HT, "\t"));
    try std.testing.expectEqualStrings(">abX", status_prompt_input(&client).?);

    try std.testing.expect(send_prompt_key(&client, T.KEYC_UP, ""));
    try std.testing.expectEqualStrings("two", status_prompt_input(&client).?);
    try std.testing.expect(send_prompt_key(&client, T.KEYC_UP, ""));
    try std.testing.expectEqualStrings("one", status_prompt_input(&client).?);
    try std.testing.expect(send_prompt_key(&client, T.KEYC_DOWN, ""));
    try std.testing.expectEqualStrings("two", status_prompt_input(&client).?);
    try std.testing.expect(send_prompt_key(&client, T.KEYC_DOWN, ""));
    try std.testing.expectEqualStrings("", status_prompt_input(&client).?);

    status_prompt_update(&client, "Prompt ", "ren");
    try std.testing.expect(send_prompt_key(&client, T.C0_HT, "\t"));
    try std.testing.expectEqualStrings("rename-window ", status_prompt_input(&client).?);

    status_prompt_update(&client, "Prompt ", "abcdef");
    try std.testing.expect(send_prompt_key(&client, T.KEYC_LEFT, ""));
    try std.testing.expect(send_prompt_key(&client, T.KEYC_LEFT, ""));
    const render_state = status_prompt_render_state(&client, 3).?;
    defer xm.allocator.free(render_state.input_visible);
    try std.testing.expectEqualStrings("cde", render_state.input_visible);
    try std.testing.expectEqual(@as(u32, 2), render_state.cursor_column);
}

test "status-prompt cursor edits stay on the shared status-only redraw path" {
    opts.global_options = opts.options_create(null);
    defer opts.options_free(opts.global_options);
    opts.options_default_all(opts.global_options, T.OPTIONS_TABLE_SERVER);

    var environ = T.Environ.init(xm.allocator);
    defer environ.deinit();
    var client = T.Client{
        .environ = &environ,
        .tty = undefined,
        .status = .{},
    };
    client.tty.client = &client;

    const capture = xm.allocator.create(PromptCapture) catch unreachable;
    capture.* = .{};

    status_prompt_set(
        &client,
        null,
        "Prompt ",
        "abc",
        capture_prompt_input,
        null,
        free_prompt_capture,
        capture,
        0,
        .command,
    );
    defer status_prompt_clear(&client);

    client.flags = 0;
    try std.testing.expect(send_prompt_key(&client, T.KEYC_LEFT, ""));
    try std.testing.expect(client.flags & T.CLIENT_REDRAWSTATUS != 0);
    try std.testing.expect(client.flags & T.CLIENT_REDRAWWINDOW == 0);
    try std.testing.expect(client.flags & T.CLIENT_REDRAWBORDERS == 0);
}

test "status-prompt word motion and delete-word use the shared cell reader" {
    opts.global_options = opts.options_create(null);
    defer opts.options_free(opts.global_options);
    opts.options_default_all(opts.global_options, T.OPTIONS_TABLE_SERVER);

    var environ = T.Environ.init(xm.allocator);
    defer environ.deinit();
    var client = T.Client{
        .environ = &environ,
        .tty = undefined,
        .status = .{},
    };
    client.tty.client = &client;

    const capture = xm.allocator.create(PromptCapture) catch unreachable;
    capture.* = .{};

    status_prompt_set(
        &client,
        null,
        "Prompt ",
        "é 🙂 two",
        capture_prompt_input,
        null,
        free_prompt_capture,
        capture,
        0,
        .search,
    );
    defer status_prompt_clear(&client);

    try std.testing.expect(send_prompt_key(&client, 'b' | T.KEYC_META, ""));
    try std.testing.expect(send_prompt_key(&client, 'b' | T.KEYC_META, ""));
    try std.testing.expect(send_prompt_key(&client, 'f' | T.KEYC_META, ""));
    try std.testing.expect(send_prompt_key(&client, 'w' | T.KEYC_CTRL, ""));
    try std.testing.expectEqualStrings("é  two", status_prompt_input(&client).?);
}

test "status-prompt vi command mode and quote-next render through the shared cell buffer" {
    const env_mod = @import("environ.zig");
    const sess_mod = @import("session.zig");

    opts.global_options = opts.options_create(null);
    defer opts.options_free(opts.global_options);
    opts.options_default_all(opts.global_options, T.OPTIONS_TABLE_SERVER);
    opts.global_s_options = opts.options_create(null);
    defer opts.options_free(opts.global_s_options);
    opts.options_default_all(opts.global_s_options, T.OPTIONS_TABLE_SESSION);

    sess_mod.session_init_globals(xm.allocator);
    env_mod.global_environ = env_mod.environ_create();
    defer env_mod.environ_free(env_mod.global_environ);

    const session = sess_mod.session_create(
        null,
        "prompt-vi",
        "/",
        env_mod.environ_create(),
        opts.options_create(opts.global_s_options),
        null,
    );
    defer if (sess_mod.session_find(session.name)) |_| sess_mod.session_destroy(session, false, "test");
    opts.options_set_number(session.options, "status-keys", T.MODEKEY_VI);

    var environ = T.Environ.init(xm.allocator);
    defer environ.deinit();
    var client = T.Client{
        .environ = &environ,
        .tty = undefined,
        .status = .{},
        .session = session,
    };
    client.tty.client = &client;

    const capture = xm.allocator.create(PromptCapture) catch unreachable;
    capture.* = .{};

    status_prompt_set(
        &client,
        null,
        "Prompt ",
        "abc",
        capture_prompt_input,
        null,
        free_prompt_capture,
        capture,
        0,
        .command,
    );
    defer status_prompt_clear(&client);

    try std.testing.expect(send_prompt_key(&client, T.C0_ESC, "\x1b"));
    try std.testing.expect(status_prompt_command_mode(&client));
    {
        const render_state = status_prompt_render_state(&client, 10).?;
        defer xm.allocator.free(render_state.input_visible);
        try std.testing.expect(render_state.command_prompt);
        try std.testing.expectEqualStrings("abc", render_state.input_visible);
        try std.testing.expectEqual(@as(u32, 2), render_state.cursor_column);
    }

    try std.testing.expect(send_prompt_key(&client, 'x', "x"));
    try std.testing.expectEqualStrings("ab", status_prompt_input(&client).?);
    try std.testing.expect(status_prompt_command_mode(&client));

    try std.testing.expect(send_prompt_key(&client, 'i', "i"));
    try std.testing.expect(!status_prompt_command_mode(&client));
    try std.testing.expect(send_prompt_key(&client, 'v' | T.KEYC_CTRL, ""));
    try std.testing.expect(send_prompt_key(&client, 'a' | T.KEYC_CTRL, ""));
    try std.testing.expectEqualSlices(u8, &.{ 'a', 0x01, 'b' }, status_prompt_input(&client).?);

    {
        const render_state = status_prompt_render_state(&client, 10).?;
        defer xm.allocator.free(render_state.input_visible);
        try std.testing.expectEqualStrings("a^Ab", render_state.input_visible);
        try std.testing.expectEqual(@as(u32, 3), render_state.cursor_column);
    }
}
