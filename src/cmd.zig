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
// Ported from tmux/cmd.c
// Original copyright:
//   Copyright (c) 2007 Nicholas Marriott <nicholas.marriott@gmail.com>
//   ISC licence – same terms as above.

//! cmd.zig – command table, parsing, and dispatch.

const std = @import("std");
const T = @import("types.zig");
const xm = @import("xmalloc.zig");
const log = @import("log.zig");
const args_mod = @import("arguments.zig");
const cmdq_mod = @import("cmd-queue.zig");

// ── Concrete types for CmdList / Cmd ──────────────────────────────────────

pub const CmdEntry = struct {
    name: []const u8,
    alias: ?[]const u8 = null,
    usage: []const u8 = "",
    template: []const u8 = "",
    lower: i32 = 0,
    upper: i32 = -1,
    flags: u32 = 0,
    exec: *const fn (*Cmd, *cmdq_mod.CmdqItem) T.CmdRetval,
};

pub const Cmd = struct {
    entry: *const CmdEntry,
    args: args_mod.Arguments,
    next: ?*Cmd = null,
};

pub const CmdList = struct {
    references: u32 = 1,
    group: u32 = 0,
    head: ?*Cmd = null,
    tail: ?*Cmd = null,

    pub fn append(self: *CmdList, cmd: *Cmd) void {
        if (self.tail) |tail| {
            tail.next = cmd;
            self.tail = cmd;
        } else {
            self.head = cmd;
            self.tail = cmd;
        }
    }
};

// ── Command table ─────────────────────────────────────────────────────────

const cmd_new_session = @import("cmd-new-session.zig");
const cmd_attach_session = @import("cmd-attach-session.zig");
const cmd_kill_session = @import("cmd-kill-session.zig");
const cmd_kill_server = @import("cmd-kill-server.zig");
const cmd_switch_client = @import("cmd-switch-client.zig");
const cmd_refresh_client = @import("cmd-refresh-client.zig");
const cmd_list_sessions = @import("cmd-list-sessions.zig");
const cmd_list_windows = @import("cmd-list-windows.zig");
const cmd_list_panes = @import("cmd-list-panes.zig");
const cmd_list_clients = @import("cmd-list-clients.zig");
const cmd_display_message = @import("cmd-display-message.zig");
const cmd_start_server = @import("cmd-start-server.zig");
const cmd_select_window = @import("cmd-select-window.zig");
const cmd_new_window = @import("cmd-new-window.zig");
const cmd_bind_key = @import("cmd-bind-key.zig");
const cmd_unbind_key = @import("cmd-unbind-key.zig");
const cmd_list_keys = @import("cmd-list-keys.zig");
const cmd_list_commands = @import("cmd-list-commands.zig");
const cmd_source_file = @import("cmd-source-file.zig");
const cmd_set_environment = @import("cmd-set-environment.zig");
const cmd_show_environment = @import("cmd-show-environment.zig");
const cmd_set_option = @import("cmd-set-option.zig");
const cmd_show_options = @import("cmd-show-options.zig");
const cmd_rename_window = @import("cmd-rename-window.zig");
const cmd_rename_session = @import("cmd-rename-session.zig");
const cmd_kill_window = @import("cmd-kill-window.zig");
const cmd_kill_pane = @import("cmd-kill-pane.zig");
const cmd_unlink_window = @import("cmd-unlink-window.zig");
const cmd_move_window = @import("cmd-move-window.zig");
const cmd_break_pane = @import("cmd-break-pane.zig");
const cmd_select_pane = @import("cmd-select-pane.zig");
const cmd_split_window = @import("cmd-split-window.zig");
const cmd_join_pane = @import("cmd-join-pane.zig");
const cmd_resize_pane = @import("cmd-resize-pane.zig");
const cmd_swap_pane = @import("cmd-swap-pane.zig");
const cmd_display_panes = @import("cmd-display-panes.zig");
const cmd_capture_pane = @import("cmd-capture-pane.zig");

const cmd_table: []const *const CmdEntry = &.{
    &cmd_new_session.entry,
    &cmd_new_session.entry_has,
    &cmd_new_session.entry_start,
    &cmd_attach_session.entry,
    &cmd_attach_session.entry_detach,
    &cmd_kill_session.entry,
    &cmd_kill_server.entry,
    &cmd_switch_client.entry,
    &cmd_refresh_client.entry,
    &cmd_list_sessions.entry,
    &cmd_list_windows.entry,
    &cmd_list_panes.entry,
    &cmd_list_clients.entry,
    &cmd_display_message.entry,
    &cmd_start_server.entry,
    &cmd_select_window.entry,
    &cmd_new_window.entry,
    &cmd_bind_key.entry,
    &cmd_unbind_key.entry,
    &cmd_list_keys.entry,
    &cmd_list_commands.entry,
    &cmd_source_file.entry,
    &cmd_set_environment.entry,
    &cmd_show_environment.entry,
    &cmd_set_option.entry,
    &cmd_set_option.entry_window,
    &cmd_show_options.entry,
    &cmd_show_options.entry_window,
    &cmd_rename_window.entry,
    &cmd_rename_session.entry,
    &cmd_kill_window.entry,
    &cmd_kill_pane.entry,
    &cmd_unlink_window.entry,
    &cmd_move_window.entry_link,
    &cmd_move_window.entry_move,
    &cmd_break_pane.entry,
    &cmd_select_pane.entry,
    &cmd_select_pane.entry_last,
    &cmd_split_window.entry,
    &cmd_join_pane.entry_join,
    &cmd_join_pane.entry_move,
    &cmd_resize_pane.entry,
    &cmd_swap_pane.entry,
    &cmd_display_panes.entry,
    &cmd_capture_pane.entry,
    &cmd_capture_pane.entry_clear,
};

// ── Lookup ────────────────────────────────────────────────────────────────

pub fn cmd_find_entry(name: []const u8) ?*const CmdEntry {
    for (cmd_table) |entry| {
        if (std.mem.eql(u8, entry.name, name)) return entry;
        if (entry.alias) |alias| {
            if (std.mem.eql(u8, alias, name)) return entry;
        }
    }
    return null;
}

pub fn cmd_entries() []const *const CmdEntry {
    return cmd_table;
}

// ── Parsing ───────────────────────────────────────────────────────────────

pub const ParseError = error{
    UnknownCommand,
    ParseFailed,
    UnterminatedQuote,
};

/// Parse a single command from an argv slice.
pub fn cmd_parse_one(
    argv: []const []const u8,
    cl: ?*T.Client,
    cause: *?[]u8,
) !*Cmd {
    _ = cl;
    if (argv.len == 0) {
        cause.* = xm.xstrdup("empty command");
        return ParseError.UnknownCommand;
    }
    const entry = cmd_find_entry(argv[0]) orelse {
        cause.* = xm.xasprintf("unknown command: {s}", .{argv[0]});
        return ParseError.UnknownCommand;
    };

    var cause2: ?[]u8 = null;
    const parsed_args = args_mod.args_parse(
        xm.allocator,
        argv[1..],
        entry.template,
        entry.lower,
        entry.upper,
        &cause2,
    ) catch {
        cause.* = cause2;
        return ParseError.ParseFailed;
    };

    const cmd = xm.allocator.create(Cmd) catch unreachable;
    cmd.* = .{ .entry = entry, .args = parsed_args };
    return cmd;
}

/// Parse a full semicolon/newline-separated command string into a CmdList.
pub fn cmd_parse_from_argv_with_cause(
    argv: []const []const u8,
    cl: ?*T.Client,
    cause: *?[]u8,
) !*CmdList {
    const list = xm.allocator.create(CmdList) catch unreachable;
    list.* = .{};

    const cmd = try cmd_parse_one(argv, cl, cause);
    list.append(cmd);
    return list;
}

pub fn cmd_parse_from_argv(
    argv: []const []const u8,
    cl: ?*T.Client,
) !*CmdList {
    var cause: ?[]u8 = null;
    return cmd_parse_from_argv_with_cause(argv, cl, &cause);
}

/// Parse commands from a string (semicolon-separated).
pub fn cmd_parse_from_string(
    input: []const u8,
    pi: *T.CmdParseInput,
) T.CmdParseResult {
    _ = pi;
    // Split on semicolons
    var list = xm.allocator.create(CmdList) catch unreachable;
    list.* = .{};

    var it = std.mem.tokenizeScalar(u8, input, ';');
    while (it.next()) |part| {
        const trimmed = std.mem.trim(u8, part, " \t\n");
        if (trimmed.len == 0) continue;
        // Tokenise into argv, preserving quoted segments.
        var argv = split_command_words(xm.allocator, trimmed) catch |err| {
            const msg = switch (err) {
                ParseError.UnterminatedQuote => xm.xstrdup("unterminated quote"),
                else => xm.xstrdup("parse error"),
            };
            cmd_list_free(list);
            return .{
                .status = .@"error",
                .@"error" = msg,
            };
        };
        defer free_split_command_words(&argv);

        var cause: ?[]u8 = null;
        const argv_const = xm.allocator.alloc([]const u8, argv.items.len) catch unreachable;
        defer xm.allocator.free(argv_const);
        for (argv.items, 0..) |word, idx| argv_const[idx] = word;

        const cmd = cmd_parse_one(argv_const, null, &cause) catch {
            const err = cause orelse xm.xstrdup("parse error");
            cmd_list_free(list);
            return .{
                .status = .@"error",
                .@"error" = err,
            };
        };
        list.append(cmd);
    }

    return .{ .status = .success, .cmdlist = @ptrCast(list) };
}

pub fn split_command_words(
    alloc: std.mem.Allocator,
    input: []const u8,
) ParseError!std.ArrayList([]u8) {
    var words: std.ArrayList([]u8) = .{};
    errdefer free_split_command_words(&words);

    var current: std.ArrayList(u8) = .{};
    defer current.deinit(alloc);

    const QuoteState = enum { none, single, double };
    var state: QuoteState = .none;
    var escaped = false;
    var token_open = false;

    for (input) |ch| {
        if (escaped) {
            current.append(alloc, ch) catch unreachable;
            escaped = false;
            token_open = true;
            continue;
        }

        switch (state) {
            .none => switch (ch) {
                ' ', '\t', '\r', '\n' => {
                    if (token_open) {
                        words.append(alloc, current.toOwnedSlice(alloc) catch unreachable) catch unreachable;
                        token_open = false;
                    }
                },
                '\'' => {
                    state = .single;
                    token_open = true;
                },
                '"' => {
                    state = .double;
                    token_open = true;
                },
                '\\' => {
                    escaped = true;
                    token_open = true;
                },
                else => {
                    current.append(alloc, ch) catch unreachable;
                    token_open = true;
                },
            },
            .single => {
                if (ch == '\'') {
                    state = .none;
                } else {
                    current.append(alloc, ch) catch unreachable;
                }
            },
            .double => {
                if (ch == '"') {
                    state = .none;
                } else if (ch == '\\') {
                    escaped = true;
                } else {
                    current.append(alloc, ch) catch unreachable;
                }
            },
        }
    }

    if (escaped or state != .none) {
        return ParseError.UnterminatedQuote;
    }
    if (token_open) {
        words.append(alloc, current.toOwnedSlice(alloc) catch unreachable) catch unreachable;
    }
    return words;
}

pub fn free_split_command_words(words: *std.ArrayList([]u8)) void {
    for (words.items) |word| xm.allocator.free(word);
    words.deinit(xm.allocator);
}

pub fn cmd_free(cmd: *Cmd) void {
    cmd.args.deinit();
    xm.allocator.destroy(cmd);
}

pub fn cmd_list_ref(list_ptr: *T.CmdList) *T.CmdList {
    const list: *CmdList = @ptrCast(@alignCast(list_ptr));
    list.references += 1;
    return list_ptr;
}

pub fn cmd_list_unref(list_ptr: *T.CmdList) void {
    const list: *CmdList = @ptrCast(@alignCast(list_ptr));
    if (list.references == 0) return;
    list.references -= 1;
    if (list.references == 0) cmd_list_free(list);
}

pub fn cmd_list_free(list: *CmdList) void {
    var cmd = list.head;
    while (cmd) |c| {
        cmd = c.next;
        cmd_free(c);
    }
    xm.allocator.destroy(list);
}

pub fn cmd_list_any_have(list: *CmdList, flag: u32) bool {
    var cmd = list.head;
    while (cmd) |c| : (cmd = c.next) {
        if (c.entry.flags & flag != 0) return true;
    }
    return false;
}

// ── Execution ─────────────────────────────────────────────────────────────

pub fn cmd_execute(cmd: *Cmd, item: *cmdq_mod.CmdqItem) T.CmdRetval {
    log.log_debug("execute {s}", .{cmd.entry.name});
    return cmd.entry.exec(cmd, item);
}

pub fn cmd_get_args(cmd: *Cmd) *args_mod.Arguments {
    return &cmd.args;
}

pub fn cmd_get_entry(cmd: *Cmd) *const CmdEntry {
    return cmd.entry;
}

test "cmd_entries exposes stable registered table order" {
    const entries = cmd_entries();
    try std.testing.expect(entries.len >= 1);
    try std.testing.expectEqualStrings("new-session", entries[0].name);
    try std.testing.expect(cmd_find_entry("list-commands") != null);
    try std.testing.expect(cmd_find_entry("show-window-options") != null);
}

test "cmd_parse_from_argv_with_cause preserves parse cause" {
    var cause: ?[]u8 = null;
    defer if (cause) |msg| xm.allocator.free(msg);

    try std.testing.expectError(
        ParseError.UnknownCommand,
        cmd_parse_from_argv_with_cause(&.{ "definitely-not-real" }, null, &cause),
    );
    try std.testing.expectEqualStrings("unknown command: definitely-not-real", cause.?);
}
