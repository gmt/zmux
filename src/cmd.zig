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
const c_zig = @import("c.zig");
const T = @import("types.zig");
const xm = @import("xmalloc.zig");
const log = @import("log.zig");
const args_mod = @import("arguments.zig");
const cmdq_mod = @import("cmd-queue.zig");
const format_mod = @import("format.zig");
const env_mod = @import("environ.zig");

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
const cmd_lock_server = @import("cmd-lock-server.zig");
const cmd_server_access = @import("cmd-server-access.zig");
const cmd_switch_client = @import("cmd-switch-client.zig");
const cmd_refresh_client = @import("cmd-refresh-client.zig");
const cmd_list_sessions = @import("cmd-list-sessions.zig");
const cmd_list_windows = @import("cmd-list-windows.zig");
const cmd_list_panes = @import("cmd-list-panes.zig");
const cmd_list_clients = @import("cmd-list-clients.zig");
const cmd_list_buffers = @import("cmd-list-buffers.zig");
const cmd_choose_tree = @import("cmd-choose-tree.zig");
const cmd_copy_mode = @import("cmd-copy-mode.zig");
const cmd_display_message = @import("cmd-display-message.zig");
const cmd_display_menu = @import("cmd-display-menu.zig");
const cmd_command_prompt = @import("cmd-command-prompt.zig");
const cmd_confirm_before = @import("cmd-confirm-before.zig");
const cmd_show_messages = @import("cmd-show-messages.zig");
const cmd_show_prompt_history = @import("cmd-show-prompt-history.zig");
const cmd_if_shell = @import("cmd-if-shell.zig");
const cmd_run_shell = @import("cmd-run-shell.zig");
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
const cmd_select_layout = @import("cmd-select-layout.zig");
const cmd_split_window = @import("cmd-split-window.zig");
const cmd_join_pane = @import("cmd-join-pane.zig");
const cmd_resize_pane = @import("cmd-resize-pane.zig");
const cmd_resize_window = @import("cmd-resize-window.zig");
const cmd_swap_pane = @import("cmd-swap-pane.zig");
const cmd_swap_window = @import("cmd-swap-window.zig");
const cmd_display_panes = @import("cmd-display-panes.zig");
const cmd_capture_pane = @import("cmd-capture-pane.zig");
const cmd_find_window = @import("cmd-find-window.zig");
const cmd_set_buffer = @import("cmd-set-buffer.zig");
const cmd_save_buffer = @import("cmd-save-buffer.zig");
const cmd_load_buffer = @import("cmd-load-buffer.zig");
const cmd_paste_buffer = @import("cmd-paste-buffer.zig");
const cmd_send_keys = @import("cmd-send-keys.zig");
const cmd_pipe_pane = @import("cmd-pipe-pane.zig");
const cmd_respawn_pane = @import("cmd-respawn-pane.zig");
const cmd_respawn_window = @import("cmd-respawn-window.zig");
const cmd_rotate_window = @import("cmd-rotate-window.zig");
const cmd_wait_for = @import("cmd-wait-for.zig");

const cmd_table: []const *const CmdEntry = &.{
    &cmd_new_session.entry,
    &cmd_new_session.entry_has,
    &cmd_new_session.entry_start,
    &cmd_attach_session.entry,
    &cmd_attach_session.entry_detach,
    &cmd_attach_session.entry_suspend,
    &cmd_kill_session.entry,
    &cmd_kill_server.entry,
    &cmd_lock_server.entry,
    &cmd_lock_server.entry_session,
    &cmd_lock_server.entry_client,
    &cmd_server_access.entry,
    &cmd_switch_client.entry,
    &cmd_refresh_client.entry,
    &cmd_list_sessions.entry,
    &cmd_list_windows.entry,
    &cmd_list_panes.entry,
    &cmd_list_clients.entry,
    &cmd_list_buffers.entry,
    &cmd_choose_tree.entry,
    &cmd_choose_tree.entry_client,
    &cmd_choose_tree.entry_buffer,
    &cmd_choose_tree.entry_customize_mode,
    &cmd_copy_mode.entry_clock,
    &cmd_copy_mode.entry,
    &cmd_display_message.entry,
    &cmd_display_menu.entry,
    &cmd_display_menu.entry_popup,
    &cmd_command_prompt.entry,
    &cmd_confirm_before.entry,
    &cmd_show_messages.entry,
    &cmd_show_prompt_history.entry,
    &cmd_show_prompt_history.entry_clear,
    &cmd_if_shell.entry,
    &cmd_run_shell.entry,
    &cmd_start_server.entry,
    &cmd_select_window.entry,
    &cmd_select_window.entry_next,
    &cmd_select_window.entry_previous,
    &cmd_select_window.entry_last,
    &cmd_new_window.entry,
    &cmd_bind_key.entry,
    &cmd_unbind_key.entry,
    &cmd_list_keys.entry,
    &cmd_list_commands.entry,
    &cmd_source_file.entry,
    &cmd_set_environment.entry,
    &cmd_show_environment.entry,
    &cmd_set_option.entry,
    &cmd_set_option.entry_hook,
    &cmd_set_option.entry_window,
    &cmd_show_options.entry,
    &cmd_show_options.entry_window,
    &cmd_show_options.entry_hooks,
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
    &cmd_select_layout.entry,
    &cmd_select_layout.entry_next,
    &cmd_select_layout.entry_previous,
    &cmd_split_window.entry,
    &cmd_join_pane.entry_join,
    &cmd_join_pane.entry_move,
    &cmd_resize_pane.entry,
    &cmd_resize_window.entry,
    &cmd_swap_pane.entry,
    &cmd_swap_window.entry,
    &cmd_display_panes.entry,
    &cmd_capture_pane.entry,
    &cmd_capture_pane.entry_clear,
    &cmd_find_window.entry,
    &cmd_set_buffer.entry,
    &cmd_set_buffer.entry_delete,
    &cmd_save_buffer.entry,
    &cmd_save_buffer.entry_show,
    &cmd_load_buffer.entry,
    &cmd_paste_buffer.entry,
    &cmd_send_keys.entry,
    &cmd_send_keys.entry_prefix,
    &cmd_pipe_pane.entry,
    &cmd_respawn_pane.entry,
    &cmd_respawn_window.entry,
    &cmd_rotate_window.entry,
    &cmd_wait_for.entry,
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

pub const PreprocessError = error{
    UnterminatedConditional,
    UnexpectedElse,
    UnexpectedElif,
    UnexpectedEndif,
};

// ── Conditional / directive preprocessor ─────────────────────────────────

/// Scope entry for nested %if blocks, matching tmux's cmd_parse_scope.
const ConditionalScope = struct {
    flag: bool, // whether the current branch is active
    any_taken: bool, // whether any branch in this if/elif chain was taken
};

/// Preprocess directives in input text:
///   - %if / %elif / %else / %endif  (conditional inclusion)
///   - %hidden VAR=VALUE             (hidden environment variable)
///   - ~ home expansion               (in unquoted token-start positions)
///
/// Returns a new string with only the active lines, suitable for the
/// existing split_commands/split_command_words pipeline.
fn preprocess_directives(
    alloc: std.mem.Allocator,
    input: []const u8,
    pi: *T.CmdParseInput,
) (ParseError || PreprocessError || error{OutOfMemory})![]u8 {
    var result: std.ArrayList(u8) = .{};
    errdefer result.deinit(alloc);

    // Stack of conditional scopes (outermost at index 0).
    var scope_stack: std.ArrayList(ConditionalScope) = .{};
    defer scope_stack.deinit(alloc);

    // Split into lines for directive processing.
    var lines = std.mem.splitScalar(u8, input, '\n');
    var first_line = true;
    while (lines.next()) |raw_line| {
        const line = std.mem.trimRight(u8, raw_line, "\r");
        const trimmed = std.mem.trimLeft(u8, line, " \t");

        // Check for %directives.
        if (std.mem.startsWith(u8, trimmed, "%if ") or
            std.mem.startsWith(u8, trimmed, "%if\t"))
        {
            const cond_text = std.mem.trim(u8, trimmed[3..], " \t");
            const expanded = expand_condition(alloc, cond_text, pi);
            defer alloc.free(expanded);
            const flag = format_mod.format_truthy(expanded);
            const parent_active = is_active(&scope_stack);
            scope_stack.append(alloc, .{
                .flag = parent_active and flag,
                .any_taken = flag,
            }) catch return error.OutOfMemory;
            continue;
        }

        if (std.mem.eql(u8, trimmed, "%else")) {
            if (scope_stack.items.len == 0) return PreprocessError.UnexpectedElse;
            const scope = &scope_stack.items[scope_stack.items.len - 1];
            const parent_active = is_parent_active(&scope_stack);
            scope.flag = parent_active and !scope.any_taken;
            scope.any_taken = true; // %else always counts as taken for the chain
            continue;
        }

        if (std.mem.startsWith(u8, trimmed, "%elif ") or
            std.mem.startsWith(u8, trimmed, "%elif\t"))
        {
            if (scope_stack.items.len == 0) return PreprocessError.UnexpectedElif;
            const scope = &scope_stack.items[scope_stack.items.len - 1];
            if (scope.any_taken) {
                // A previous branch was already taken; skip this one.
                scope.flag = false;
            } else {
                const cond_text = std.mem.trim(u8, trimmed[5..], " \t");
                const expanded = expand_condition(alloc, cond_text, pi);
                defer alloc.free(expanded);
                const flag = format_mod.format_truthy(expanded);
                const parent_active = is_parent_active(&scope_stack);
                scope.flag = parent_active and flag;
                scope.any_taken = flag;
            }
            continue;
        }

        if (std.mem.eql(u8, trimmed, "%endif")) {
            if (scope_stack.items.len == 0) return PreprocessError.UnexpectedEndif;
            _ = scope_stack.pop();
            continue;
        }

        // %hidden: set a hidden environment variable if active.
        if (std.mem.startsWith(u8, trimmed, "%hidden ") or
            std.mem.startsWith(u8, trimmed, "%hidden\t"))
        {
            if (is_active(&scope_stack)) {
                const assign = std.mem.trim(u8, trimmed[7..], " \t");
                if (pi.flags & T.CMD_PARSE_PARSEONLY == 0) {
                    env_mod.environ_put(env_mod.global_environ, assign, T.ENVIRON_HIDDEN);
                }
            }
            continue;
        }

        // Not a directive: include line only if active.
        if (is_active(&scope_stack)) {
            if (!first_line)
                result.append(alloc, '\n') catch return error.OutOfMemory;
            const processed = try process_line_tokens(alloc, line);
            defer alloc.free(processed);
            result.appendSlice(alloc, processed) catch return error.OutOfMemory;
            first_line = false;
        }
    }

    if (scope_stack.items.len != 0) {
        return PreprocessError.UnterminatedConditional;
    }

    return result.toOwnedSlice(alloc) catch return error.OutOfMemory;
}

/// Check if the current scope stack means we are in an active branch.
fn is_active(stack: *const std.ArrayList(ConditionalScope)) bool {
    if (stack.items.len == 0) return true;
    return stack.items[stack.items.len - 1].flag;
}

/// Check if the parent scope (everything except the top) is active.
fn is_parent_active(stack: *const std.ArrayList(ConditionalScope)) bool {
    if (stack.items.len <= 1) return true;
    return stack.items[stack.items.len - 2].flag;
}

/// Expand a condition expression using the format system.
/// In tmux, conditions after %if/%elif are format-expanded, then evaluated
/// for truthiness. We expand using the pi context.
fn expand_condition(
    alloc: std.mem.Allocator,
    cond_text: []const u8,
    pi: *T.CmdParseInput,
) []u8 {
    const ctx = format_mod.FormatContext{
        .item = if (pi.item) |item| @ptrCast(item) else null,
        .client = pi.c,
        .session = if (pi.fs.s) |s| s else null,
        .winlink = if (pi.fs.wl) |wl| wl else null,
        .pane = if (pi.fs.wp) |wp| wp else null,
    };
    const expanded = format_mod.format_expand(alloc, cond_text, &ctx);
    return expanded.text;
}

/// Process a single line for ~ home-directory expansion.
/// Tilde is expanded at the start of an unquoted token when followed by
/// a path separator, whitespace, quote, or end of token — matching tmux's
/// yylex_token_tilde behavior.
fn process_line_tokens(
    alloc: std.mem.Allocator,
    line: []const u8,
) error{OutOfMemory}![]u8 {
    var result: std.ArrayList(u8) = .{};
    errdefer result.deinit(alloc);

    const State = enum { none, single, double };
    var state: State = .none;
    var token_start = true; // true when next char would start a new token
    var i: usize = 0;

    while (i < line.len) {
        const ch = line[i];

        switch (state) {
            .none => {
                if (ch == '~' and token_start) {
                    // Expand tilde: collect username part (until / or whitespace/end)
                    i += 1;
                    var name_end = i;
                    while (name_end < line.len) {
                        const nc = line[name_end];
                        if (nc == '/' or nc == ' ' or nc == '\t' or
                            nc == '\n' or nc == '"' or nc == '\'')
                            break;
                        name_end += 1;
                    }
                    const username = line[i..name_end];
                    const home = resolve_home(username);
                    if (home) |h| {
                        result.appendSlice(alloc, h) catch return error.OutOfMemory;
                    } else {
                        // If home resolution fails, output ~ literally
                        result.append(alloc, '~') catch return error.OutOfMemory;
                        result.appendSlice(alloc, username) catch return error.OutOfMemory;
                    }
                    i = name_end;
                    token_start = false;
                    continue;
                }

                if (ch == '\'') {
                    state = .single;
                    token_start = false;
                } else if (ch == '"') {
                    state = .double;
                    token_start = false;
                } else if (ch == ' ' or ch == '\t') {
                    token_start = true;
                } else if (ch == ';') {
                    token_start = true;
                } else {
                    token_start = false;
                }
                result.append(alloc, ch) catch return error.OutOfMemory;
            },
            .single => {
                if (ch == '\'') state = .none;
                result.append(alloc, ch) catch return error.OutOfMemory;
            },
            .double => {
                if (ch == '"') state = .none;
                result.append(alloc, ch) catch return error.OutOfMemory;
            },
        }
        i += 1;
    }

    return result.toOwnedSlice(alloc) catch return error.OutOfMemory;
}

/// Resolve ~ or ~username to a home directory path.
/// Matches tmux's yylex_token_tilde: bare ~ uses $HOME, ~user uses getpwnam.
fn resolve_home(username: []const u8) ?[]const u8 {
    if (username.len == 0) {
        // Bare ~: use HOME from global environ, fall back to process env.
        if (env_mod.environ_find(env_mod.global_environ, "HOME")) |entry| {
            if (entry.value) |v| {
                if (v.len > 0) return v;
            }
        }
        // Fall back to the process environment.
        const home_z = std.posix.getenv("HOME");
        if (home_z) |h| return h;
        return null;
    } else {
        // ~username: use getpwnam.
        const name_z = xm.allocator.dupeZ(u8, username) catch return null;
        defer xm.allocator.free(name_z);
        const pw = c_zig.posix_sys.getpwnam(name_z.ptr);
        if (pw) |p| {
            if (p.*.pw_dir != null) return std.mem.sliceTo(p.*.pw_dir, 0);
        }
        return null;
    }
}

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
/// Handles %if/%elif/%else/%endif conditionals, %hidden assignments,
/// and ~ home directory expansion.
pub fn cmd_parse_from_string(
    input: []const u8,
    pi: *T.CmdParseInput,
) T.CmdParseResult {
    const preprocessed = preprocess_directives(xm.allocator, input, pi) catch |err| {
        const msg = switch (err) {
            ParseError.UnterminatedQuote => xm.xstrdup("unterminated quote"),
            PreprocessError.UnterminatedConditional => xm.xstrdup("unterminated %if block"),
            PreprocessError.UnexpectedElse => xm.xstrdup("unexpected %else without %if"),
            PreprocessError.UnexpectedElif => xm.xstrdup("unexpected %elif without %if"),
            PreprocessError.UnexpectedEndif => xm.xstrdup("unexpected %endif without %if"),
            else => xm.xstrdup("parse error"),
        };
        return .{
            .status = .@"error",
            .@"error" = msg,
        };
    };
    defer xm.allocator.free(preprocessed);

    var list = xm.allocator.create(CmdList) catch unreachable;
    list.* = .{};

    var commands = split_commands(xm.allocator, preprocessed) catch |err| {
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
    defer free_split_command_words(&commands);

    for (commands.items) |part| {
        // Tokenise into argv, preserving quoted segments.
        var argv = split_command_words(xm.allocator, part) catch |err| {
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

        if (argv.items.len == 0) continue;

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

fn split_commands(
    alloc: std.mem.Allocator,
    input: []const u8,
) ParseError!std.ArrayList([]u8) {
    var commands: std.ArrayList([]u8) = .{};
    errdefer free_split_command_words(&commands);

    var current: std.ArrayList(u8) = .{};
    defer current.deinit(alloc);

    const QuoteState = enum { none, single, double };
    var state: QuoteState = .none;
    var escaped = false;

    for (input) |ch| {
        if (escaped) {
            current.append(alloc, ch) catch unreachable;
            escaped = false;
            continue;
        }

        switch (state) {
            .none => switch (ch) {
                ';', '\n' => {
                    const trimmed = std.mem.trim(u8, current.items, " \t\r\n");
                    if (trimmed.len != 0)
                        commands.append(alloc, alloc.dupe(u8, trimmed) catch unreachable) catch unreachable;
                    current.clearRetainingCapacity();
                },
                '\'' => {
                    state = .single;
                    current.append(alloc, ch) catch unreachable;
                },
                '"' => {
                    state = .double;
                    current.append(alloc, ch) catch unreachable;
                },
                '\\' => {
                    escaped = true;
                    current.append(alloc, ch) catch unreachable;
                },
                else => current.append(alloc, ch) catch unreachable,
            },
            .single => {
                current.append(alloc, ch) catch unreachable;
                if (ch == '\'') state = .none;
            },
            .double => {
                current.append(alloc, ch) catch unreachable;
                if (ch == '"') {
                    state = .none;
                } else if (ch == '\\') {
                    escaped = true;
                }
            },
        }
    }

    if (escaped or state != .none) {
        return ParseError.UnterminatedQuote;
    }

    const trimmed = std.mem.trim(u8, current.items, " \t\r\n");
    if (trimmed.len != 0)
        commands.append(alloc, alloc.dupe(u8, trimmed) catch unreachable) catch unreachable;
    return commands;
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

pub fn cmd_list_all_have(list_ptr: *T.CmdList, flag: u32) bool {
    const list: *CmdList = @ptrCast(@alignCast(list_ptr));
    var cmd = list.head;
    while (cmd) |c| : (cmd = c.next) {
        if (c.entry.flags & flag == 0) return false;
    }
    return true;
}

// ── Execution ─────────────────────────────────────────────────────────────

pub fn cmd_execute(cmd: *Cmd, item: *cmdq_mod.CmdqItem) T.CmdRetval {
    const saved_cmd = item.cmd;
    const saved_target_client = item.target_client;
    item.cmd = cmd;
    item.target_client = cmdq_mod.cmdq_resolve_target_client(item, cmd);
    defer {
        item.target_client = saved_target_client;
        item.cmd = saved_cmd;
    }

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
        cmd_parse_from_argv_with_cause(&.{"definitely-not-real"}, null, &cause),
    );
    try std.testing.expectEqualStrings("unknown command: definitely-not-real", cause.?);
}

// ── Preprocessor / directive tests ───────────────────────────────────────

fn setup_test_environ() void {
    env_mod.global_environ = env_mod.environ_create();
}

fn teardown_test_environ() void {
    env_mod.environ_free(env_mod.global_environ);
}

test "preprocess: simple %if true includes body" {
    setup_test_environ();
    defer teardown_test_environ();

    const input =
        \\%if 1
        \\set-option status on
        \\%endif
    ;
    var pi = T.CmdParseInput{};
    const result = try preprocess_directives(std.testing.allocator, input, &pi);
    defer std.testing.allocator.free(result);

    try std.testing.expectEqualStrings("set-option status on", result);
}

test "preprocess: simple %if false excludes body" {
    setup_test_environ();
    defer teardown_test_environ();

    const input =
        \\%if 0
        \\set-option status on
        \\%endif
    ;
    var pi = T.CmdParseInput{};
    const result = try preprocess_directives(std.testing.allocator, input, &pi);
    defer std.testing.allocator.free(result);

    try std.testing.expectEqualStrings("", result);
}

test "preprocess: %if/%else selects correct branch" {
    setup_test_environ();
    defer teardown_test_environ();

    const input =
        \\%if 0
        \\set-option status off
        \\%else
        \\set-option status on
        \\%endif
    ;
    var pi = T.CmdParseInput{};
    const result = try preprocess_directives(std.testing.allocator, input, &pi);
    defer std.testing.allocator.free(result);

    try std.testing.expectEqualStrings("set-option status on", result);
}

test "preprocess: %elif chain selects first true branch" {
    setup_test_environ();
    defer teardown_test_environ();

    const input =
        \\%if 0
        \\cmd-a
        \\%elif 0
        \\cmd-b
        \\%elif 1
        \\cmd-c
        \\%elif 1
        \\cmd-d
        \\%else
        \\cmd-e
        \\%endif
    ;
    var pi = T.CmdParseInput{};
    const result = try preprocess_directives(std.testing.allocator, input, &pi);
    defer std.testing.allocator.free(result);

    try std.testing.expectEqualStrings("cmd-c", result);
}

test "preprocess: nested %if blocks" {
    setup_test_environ();
    defer teardown_test_environ();

    const input =
        \\%if 1
        \\%if 0
        \\inner-false
        \\%else
        \\inner-true
        \\%endif
        \\outer-true
        \\%endif
    ;
    var pi = T.CmdParseInput{};
    const result = try preprocess_directives(std.testing.allocator, input, &pi);
    defer std.testing.allocator.free(result);

    try std.testing.expectEqualStrings("inner-true\nouter-true", result);
}

test "preprocess: outer false suppresses nested blocks" {
    setup_test_environ();
    defer teardown_test_environ();

    const input =
        \\%if 0
        \\%if 1
        \\should-not-appear
        \\%endif
        \\also-not-appear
        \\%endif
    ;
    var pi = T.CmdParseInput{};
    const result = try preprocess_directives(std.testing.allocator, input, &pi);
    defer std.testing.allocator.free(result);

    try std.testing.expectEqualStrings("", result);
}

test "preprocess: unterminated %if returns error" {
    setup_test_environ();
    defer teardown_test_environ();

    const input =
        \\%if 1
        \\set-option status on
    ;
    var pi = T.CmdParseInput{};
    try std.testing.expectError(
        PreprocessError.UnterminatedConditional,
        preprocess_directives(std.testing.allocator, input, &pi),
    );
}

test "preprocess: unexpected %else returns error" {
    setup_test_environ();
    defer teardown_test_environ();

    var pi = T.CmdParseInput{};
    try std.testing.expectError(
        PreprocessError.UnexpectedElse,
        preprocess_directives(std.testing.allocator, "%else", &pi),
    );
}

test "preprocess: unexpected %endif returns error" {
    setup_test_environ();
    defer teardown_test_environ();

    var pi = T.CmdParseInput{};
    try std.testing.expectError(
        PreprocessError.UnexpectedEndif,
        preprocess_directives(std.testing.allocator, "%endif", &pi),
    );
}

test "preprocess: %hidden sets hidden environment variable" {
    setup_test_environ();
    defer teardown_test_environ();

    const input = "%hidden MY_VAR=hello";
    var pi = T.CmdParseInput{};
    const result = try preprocess_directives(std.testing.allocator, input, &pi);
    defer std.testing.allocator.free(result);

    // The %hidden line should be consumed (not in output).
    try std.testing.expectEqualStrings("", result);

    // The variable should be set in global environ.
    const entry = env_mod.environ_find(env_mod.global_environ, "MY_VAR");
    try std.testing.expect(entry != null);
    try std.testing.expectEqualStrings("hello", entry.?.value.?);
    try std.testing.expect(entry.?.flags & T.ENVIRON_HIDDEN != 0);
}

test "preprocess: %hidden in false branch is not set" {
    setup_test_environ();
    defer teardown_test_environ();

    const input =
        \\%if 0
        \\%hidden SKIP_VAR=nope
        \\%endif
    ;
    var pi = T.CmdParseInput{};
    const result = try preprocess_directives(std.testing.allocator, input, &pi);
    defer std.testing.allocator.free(result);

    try std.testing.expect(env_mod.environ_find(env_mod.global_environ, "SKIP_VAR") == null);
}

test "preprocess: %hidden with PARSEONLY does not set variable" {
    setup_test_environ();
    defer teardown_test_environ();

    const input = "%hidden PARSE_VAR=nope";
    var pi = T.CmdParseInput{ .flags = T.CMD_PARSE_PARSEONLY };
    const result = try preprocess_directives(std.testing.allocator, input, &pi);
    defer std.testing.allocator.free(result);

    try std.testing.expect(env_mod.environ_find(env_mod.global_environ, "PARSE_VAR") == null);
}

test "preprocess: tilde expansion at token start" {
    setup_test_environ();
    defer teardown_test_environ();

    // Set HOME in the global environ for controlled test.
    env_mod.environ_set(env_mod.global_environ, "HOME", 0, "/test/home");

    const input = "source-file ~/conf";
    var pi = T.CmdParseInput{};
    const result = try preprocess_directives(std.testing.allocator, input, &pi);
    defer std.testing.allocator.free(result);

    try std.testing.expectEqualStrings("source-file /test/home/conf", result);
}

test "preprocess: tilde not expanded mid-token" {
    setup_test_environ();
    defer teardown_test_environ();

    env_mod.environ_set(env_mod.global_environ, "HOME", 0, "/test/home");

    const input = "echo foo~bar";
    var pi = T.CmdParseInput{};
    const result = try preprocess_directives(std.testing.allocator, input, &pi);
    defer std.testing.allocator.free(result);

    try std.testing.expectEqualStrings("echo foo~bar", result);
}

test "preprocess: tilde not expanded inside single quotes" {
    setup_test_environ();
    defer teardown_test_environ();

    env_mod.environ_set(env_mod.global_environ, "HOME", 0, "/test/home");

    const input = "echo '~/conf'";
    var pi = T.CmdParseInput{};
    const result = try preprocess_directives(std.testing.allocator, input, &pi);
    defer std.testing.allocator.free(result);

    try std.testing.expectEqualStrings("echo '~/conf'", result);
}

test "cmd_parse_from_string: basic semicolon separation still works" {
    setup_test_environ();
    defer teardown_test_environ();

    var pi = T.CmdParseInput{};
    const result = cmd_parse_from_string("set-option status on", &pi);
    try std.testing.expect(result.status == .success);
    if (result.cmdlist) |cl_ptr| {
        const list: *CmdList = @ptrCast(@alignCast(cl_ptr));
        try std.testing.expect(list.head != null);
        try std.testing.expectEqualStrings("set-option", list.head.?.entry.name);
        cmd_list_free(list);
    }
}

test "cmd_parse_from_string: %if true includes command" {
    setup_test_environ();
    defer teardown_test_environ();

    const input =
        \\%if 1
        \\set-option status on
        \\%endif
    ;
    var pi = T.CmdParseInput{};
    const result = cmd_parse_from_string(input, &pi);
    try std.testing.expect(result.status == .success);
    if (result.cmdlist) |cl_ptr| {
        const list: *CmdList = @ptrCast(@alignCast(cl_ptr));
        try std.testing.expect(list.head != null);
        try std.testing.expectEqualStrings("set-option", list.head.?.entry.name);
        cmd_list_free(list);
    }
}

test "cmd_parse_from_string: %if false produces empty list" {
    setup_test_environ();
    defer teardown_test_environ();

    const input =
        \\%if 0
        \\set-option status on
        \\%endif
    ;
    var pi = T.CmdParseInput{};
    const result = cmd_parse_from_string(input, &pi);
    try std.testing.expect(result.status == .success);
    if (result.cmdlist) |cl_ptr| {
        const list: *CmdList = @ptrCast(@alignCast(cl_ptr));
        try std.testing.expect(list.head == null);
        cmd_list_free(list);
    }
}

test "cmd_parse_from_string: unterminated %if returns error" {
    setup_test_environ();
    defer teardown_test_environ();

    const input =
        \\%if 1
        \\set-option status on
    ;
    var pi = T.CmdParseInput{};
    const result = cmd_parse_from_string(input, &pi);
    try std.testing.expect(result.status == .@"error");
    try std.testing.expect(result.@"error" != null);
    if (result.@"error") |err| xm.allocator.free(err);
}
