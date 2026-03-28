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
// Ported from tmux/options-table.c
// Original copyright:
//   Copyright (c) 2011 Nicholas Marriott <nicholas.marriott@gmail.com>
//   ISC licence – same terms as above.

//! options-table.zig – static table of all tmux/zmux options with defaults.
//!
//! This mirrors options-table.c.  Scopes:
//!   OPTIONS_TABLE_SERVER  → installed into global_options
//!   OPTIONS_TABLE_SESSION → installed into global_s_options
//!   OPTIONS_TABLE_WINDOW  → installed into global_w_options
//!   OPTIONS_TABLE_PANE    → installed into pane's options

const T = @import("types.zig");
const S = T.OPTIONS_TABLE_SERVER;
const Ss = T.OPTIONS_TABLE_SESSION;
const W = T.OPTIONS_TABLE_WINDOW;
const P = T.OPTIONS_TABLE_PANE;
const SW = T.OptionsScope{ .server = true, .window = true };
const SP = T.OptionsScope{ .server = true, .pane = true };
const WP = T.OptionsScope{ .window = true, .pane = true };
const empty_array = [_][]const u8{};

const OT = T.OptionsType;
const update_environment_default = [_][]const u8{
    "DISPLAY",
    "KRB5CCNAME",
    "MSYSTEM",
    "SSH_ASKPASS",
    "SSH_AUTH_SOCK",
    "SSH_AGENT_PID",
    "SSH_CONNECTION",
    "WINDOWID",
    "XAUTHORITY",
};

const status_format_default_0 =
    "#[align=left range=left #{E:status-left-style}]" ++
    "#[push-default]" ++
    "#{T;=/#{status-left-length}:status-left}" ++
    "#[pop-default]" ++
    "#[norange default]" ++
    "#[list=on align=#{status-justify}]" ++
    "#[list=left-marker]<#[list=right-marker]>#[list=on]" ++
    "#{W:" ++
    "#[range=window|#{window_index} " ++
    "#{E:window-status-style}" ++
    "#{?#{&&:#{window_last_flag},#{!=:#{E:window-status-last-style},default}},#{E:window-status-last-style},}" ++
    "#{?#{&&:#{window_bell_flag},#{!=:#{E:window-status-bell-style},default}},#{E:window-status-bell-style},#{?#{&&:#{||:#{window_activity_flag},#{window_silence_flag}},#{!=:#{E:window-status-activity-style},default}},#{E:window-status-activity-style},}}" ++
    "]" ++
    "#[push-default]" ++
    "#{T:window-status-format}" ++
    "#[pop-default]" ++
    "#[norange default]" ++
    "#{?loop_last_flag,,#{E:window-status-separator}}" ++
    "," ++
    "#[range=window|#{window_index} list=focus " ++
    "#{?#{!=:#{E:window-status-current-style},default},#{E:window-status-current-style},#{E:window-status-style}}" ++
    "#{?#{&&:#{window_last_flag},#{!=:#{E:window-status-last-style},default}},#{E:window-status-last-style},}" ++
    "#{?#{&&:#{window_bell_flag},#{!=:#{E:window-status-bell-style},default}},#{E:window-status-bell-style},#{?#{&&:#{||:#{window_activity_flag},#{window_silence_flag}},#{!=:#{E:window-status-activity-style},default}},#{E:window-status-activity-style},}}" ++
    "]" ++
    "#[push-default]" ++
    "#{T:window-status-current-format}" ++
    "#[pop-default]" ++
    "#[norange list=on default]" ++
    "#{?loop_last_flag,,#{E:window-status-separator}}" ++
    "}" ++
    "#[nolist align=right range=right #{E:status-right-style}]" ++
    "#[push-default]" ++
    "#{T;=/#{status-right-length}:status-right}" ++
    "#[pop-default]" ++
    "#[norange default]";

const status_format_default = [_][]const u8{
    status_format_default_0,
};

pub const options_table: []const T.OptionsTableEntry = &[_]T.OptionsTableEntry{
    // ── Server options ────────────────────────────────────────────────────
    .{ .name = "backspace", .type = .string, .scope = S, .default_str = "\x7f" },
    .{ .name = "buffer-limit", .type = .number, .scope = S, .default_num = 50, .minimum = 1 },
    .{ .name = "command-alias", .type = .array, .scope = S },
    .{ .name = "codepoint-widths", .type = .array, .scope = S },
    .{ .name = "copy-command", .type = .string, .scope = S, .default_str = "" },
    .{ .name = "default-terminal", .type = .string, .scope = S, .default_str = "tmux-256color" },
    .{ .name = "editor", .type = .string, .scope = S, .default_str = "/usr/bin/vi" },
    .{ .name = "escape-time", .type = .number, .scope = S, .default_num = 500, .minimum = 0 },
    .{ .name = "exit-empty", .type = .flag, .scope = S, .default_num = 1 },
    .{ .name = "exit-unattached", .type = .flag, .scope = S, .default_num = 0 },
    .{ .name = "extended-keys", .type = .choice, .scope = S, .default_num = 0, .choices = &.{ "off", "on", "always" } },
    .{ .name = "extended-keys-format", .type = .choice, .scope = S, .default_num = 1, .choices = &.{ "csi-u", "xterm" } },
    .{ .name = "focus-events", .type = .flag, .scope = S, .default_num = 0 },
    .{ .name = "history-file", .type = .string, .scope = S, .default_str = "" },
    .{ .name = "message-limit", .type = .number, .scope = S, .default_num = 1000, .minimum = 0 },
    .{ .name = "prompt-history-limit", .type = .number, .scope = S, .default_num = 100, .minimum = 0 },
    .{ .name = "set-clipboard", .type = .choice, .scope = S, .default_num = 1, .choices = &.{ "off", "on", "external" } },
    .{ .name = "terminal-features", .type = .array, .scope = S },
    .{ .name = "terminal-overrides", .type = .array, .scope = S },
    .{ .name = "update-environment", .type = .array, .scope = S },
    .{ .name = "user-keys", .type = .array, .scope = S },
    .{ .name = "variation-selector-always-wide", .type = .flag, .scope = S, .default_num = 1 },
    .{ .name = "visual-activity", .type = .choice, .scope = S, .default_num = 0, .choices = &.{ "off", "on", "both" } },
    .{ .name = "visual-bell", .type = .choice, .scope = S, .default_num = 0, .choices = &.{ "off", "on", "both" } },
    .{ .name = "visual-silence", .type = .choice, .scope = S, .default_num = 0, .choices = &.{ "off", "on", "both" } },

    // ── Session options ───────────────────────────────────────────────────
    .{ .name = "activity-action", .type = .choice, .scope = Ss, .default_num = 1, .choices = &.{ "none", "any", "current", "other" } },
    .{ .name = "assume-paste-time", .type = .number, .scope = Ss, .default_num = 1, .minimum = 0 },
    .{ .name = "base-index", .type = .number, .scope = Ss, .default_num = 0, .minimum = 0 },
    .{ .name = "bell-action", .type = .choice, .scope = Ss, .default_num = 1, .choices = &.{ "none", "any", "current", "other" } },
    .{ .name = "default-command", .type = .string, .scope = Ss, .default_str = "" },
    .{ .name = "default-shell", .type = .string, .scope = Ss, .default_str = "/bin/sh" },
    .{ .name = "default-size", .type = .string, .scope = Ss, .default_str = "80x24" },
    .{ .name = "destroy-unattached", .type = .choice, .scope = Ss, .default_num = 0, .choices = &.{ "off", "on", "keep-last", "keep-group" } },
    .{ .name = "detach-on-destroy", .type = .choice, .scope = Ss, .default_num = 1, .choices = &.{ "off", "on", "no-detached", "previous", "next" } },
    .{ .name = "display-panes-active-colour", .type = .colour, .scope = Ss, .default_num = 1 },
    .{ .name = "display-panes-colour", .type = .colour, .scope = Ss, .default_num = 4 },
    .{ .name = "display-panes-time", .type = .number, .scope = Ss, .default_num = 1000, .minimum = 1 },
    .{ .name = "display-time", .type = .number, .scope = Ss, .default_num = 750, .minimum = 0 },
    .{ .name = "focus-follows-mouse", .type = .flag, .scope = Ss, .default_num = 0 },
    .{ .name = "history-limit", .type = .number, .scope = Ss, .default_num = 2000, .minimum = 0 },
    .{ .name = "key-table", .type = .string, .scope = Ss, .default_str = "root" },
    .{ .name = "lock-after-time", .type = .number, .scope = Ss, .default_num = 0, .minimum = 0 },
    .{ .name = "lock-command", .type = .string, .scope = Ss, .default_str = "lock -np" },
    .{ .name = "message-command-style", .type = .style, .scope = Ss, .default_str = "bg=black,fg=yellow" },
    .{ .name = "message-format", .type = .string, .scope = Ss, .default_str = "#[#{?#{command_prompt},#{E:message-command-style},#{E:message-style}}]#{message}" },
    .{ .name = "message-line", .type = .choice, .scope = Ss, .default_num = 0, .choices = &.{ "0", "1", "2", "3", "4" } },
    .{ .name = "message-style", .type = .style, .scope = Ss, .default_str = "bg=yellow,fg=black,fill=yellow" },
    .{ .name = "mouse", .type = .flag, .scope = Ss, .default_num = 0 },
    .{ .name = "prefix", .type = .string, .scope = Ss, .default_str = "C-b" },
    .{ .name = "prefix2", .type = .string, .scope = Ss, .default_str = "" },
    .{ .name = "renumber-windows", .type = .flag, .scope = Ss, .default_num = 0 },
    .{ .name = "repeat-time", .type = .number, .scope = Ss, .default_num = 500, .minimum = 0 },
    .{ .name = "set-titles", .type = .flag, .scope = Ss, .default_num = 0 },
    .{ .name = "set-titles-string", .type = .string, .scope = Ss, .default_str = "#S:#I:#W - \"#T\" #{session_alerts}" },
    .{ .name = "silence-action", .type = .choice, .scope = Ss, .default_num = 1, .choices = &.{ "none", "any", "current", "other" } },
    .{ .name = "status", .type = .choice, .scope = Ss, .default_num = 1, .choices = &.{ "off", "on", "2", "3", "4", "5" } },
    .{ .name = "status-bg", .type = .colour, .scope = Ss, .default_num = 8 },
    .{ .name = "status-fg", .type = .colour, .scope = Ss, .default_num = 8 },
    .{
        .name = "status-format",
        .type = .array,
        .scope = Ss,
        .default_arr = status_format_default[0..],
    },
    .{ .name = "status-interval", .type = .number, .scope = Ss, .default_num = 15, .minimum = 0 },
    .{ .name = "status-justify", .type = .choice, .scope = Ss, .default_num = 0, .choices = &.{ "left", "centre", "right", "absolute-centre" } },
    .{ .name = "status-keys", .type = .choice, .scope = Ss, .default_num = 0, .choices = &.{ "emacs", "vi" } },
    .{ .name = "status-left", .type = .string, .scope = Ss, .default_str = "[#{session_name}] " },
    .{ .name = "status-left-length", .type = .number, .scope = Ss, .default_num = 10, .minimum = 0 },
    .{ .name = "status-left-style", .type = .style, .scope = Ss, .default_str = "default" },
    .{ .name = "status-position", .type = .choice, .scope = Ss, .default_num = 1, .choices = &.{ "top", "bottom" } },
    .{ .name = "status-right", .type = .string, .scope = Ss, .default_str = "#{?window_bigger,[#{window_offset_x}#,#{window_offset_y}] ,}\"#{=21:pane_title}\" %H:%M %d-%b-%y" },
    .{ .name = "status-right-length", .type = .number, .scope = Ss, .default_num = 40, .minimum = 0 },
    .{ .name = "status-right-style", .type = .style, .scope = Ss, .default_str = "default" },
    .{ .name = "status-style", .type = .style, .scope = Ss, .default_str = "bg=green,fg=black" },
    .{ .name = "prompt-cursor-colour", .type = .colour, .scope = Ss, .default_num = -1 },
    .{ .name = "prompt-cursor-style", .type = .choice, .scope = Ss, .default_num = 0, .choices = &.{ "default", "blinking-block", "block", "blinking-underline", "underline", "blinking-bar", "bar" } },
    .{ .name = "prompt-command-cursor-style", .type = .choice, .scope = Ss, .default_num = 0, .choices = &.{ "default", "blinking-block", "block", "blinking-underline", "underline", "blinking-bar", "bar" } },
    .{
        .name = "update-environment",
        .type = .array,
        .scope = Ss,
        .default_arr = update_environment_default[0..],
    },
    .{ .name = "visual-activity", .type = .choice, .scope = Ss, .default_num = 0, .choices = &.{ "off", "on", "both" } },
    .{ .name = "visual-bell", .type = .choice, .scope = Ss, .default_num = 0, .choices = &.{ "off", "on", "both" } },
    .{ .name = "visual-silence", .type = .choice, .scope = Ss, .default_num = 0, .choices = &.{ "off", "on", "both" } },
    .{ .name = "word-separators", .type = .string, .scope = Ss, .default_str = "!\"#$%&'()*+,-./:;<=>?@[\\]^`{|}~" },

    // ── Hook options ──────────────────────────────────────────────────────
    .{ .name = "after-bind-key", .type = .array, .scope = Ss, .is_hook = true, .default_arr = empty_array[0..] },
    .{ .name = "after-capture-pane", .type = .array, .scope = Ss, .is_hook = true, .default_arr = empty_array[0..] },
    .{ .name = "after-copy-mode", .type = .array, .scope = Ss, .is_hook = true, .default_arr = empty_array[0..] },
    .{ .name = "after-display-message", .type = .array, .scope = Ss, .is_hook = true, .default_arr = empty_array[0..] },
    .{ .name = "after-display-panes", .type = .array, .scope = Ss, .is_hook = true, .default_arr = empty_array[0..] },
    .{ .name = "after-kill-pane", .type = .array, .scope = Ss, .is_hook = true, .default_arr = empty_array[0..] },
    .{ .name = "after-list-buffers", .type = .array, .scope = Ss, .is_hook = true, .default_arr = empty_array[0..] },
    .{ .name = "after-list-clients", .type = .array, .scope = Ss, .is_hook = true, .default_arr = empty_array[0..] },
    .{ .name = "after-list-keys", .type = .array, .scope = Ss, .is_hook = true, .default_arr = empty_array[0..] },
    .{ .name = "after-list-panes", .type = .array, .scope = Ss, .is_hook = true, .default_arr = empty_array[0..] },
    .{ .name = "after-list-sessions", .type = .array, .scope = Ss, .is_hook = true, .default_arr = empty_array[0..] },
    .{ .name = "after-list-windows", .type = .array, .scope = Ss, .is_hook = true, .default_arr = empty_array[0..] },
    .{ .name = "after-load-buffer", .type = .array, .scope = Ss, .is_hook = true, .default_arr = empty_array[0..] },
    .{ .name = "after-lock-server", .type = .array, .scope = Ss, .is_hook = true, .default_arr = empty_array[0..] },
    .{ .name = "after-new-session", .type = .array, .scope = Ss, .is_hook = true, .default_arr = empty_array[0..] },
    .{ .name = "after-new-window", .type = .array, .scope = Ss, .is_hook = true, .default_arr = empty_array[0..] },
    .{ .name = "after-paste-buffer", .type = .array, .scope = Ss, .is_hook = true, .default_arr = empty_array[0..] },
    .{ .name = "after-pipe-pane", .type = .array, .scope = Ss, .is_hook = true, .default_arr = empty_array[0..] },
    .{ .name = "after-queue", .type = .array, .scope = Ss, .is_hook = true, .default_arr = empty_array[0..] },
    .{ .name = "after-refresh-client", .type = .array, .scope = Ss, .is_hook = true, .default_arr = empty_array[0..] },
    .{ .name = "after-rename-session", .type = .array, .scope = Ss, .is_hook = true, .default_arr = empty_array[0..] },
    .{ .name = "after-rename-window", .type = .array, .scope = Ss, .is_hook = true, .default_arr = empty_array[0..] },
    .{ .name = "after-resize-pane", .type = .array, .scope = Ss, .is_hook = true, .default_arr = empty_array[0..] },
    .{ .name = "after-resize-window", .type = .array, .scope = Ss, .is_hook = true, .default_arr = empty_array[0..] },
    .{ .name = "after-save-buffer", .type = .array, .scope = Ss, .is_hook = true, .default_arr = empty_array[0..] },
    .{ .name = "after-select-layout", .type = .array, .scope = Ss, .is_hook = true, .default_arr = empty_array[0..] },
    .{ .name = "after-select-pane", .type = .array, .scope = Ss, .is_hook = true, .default_arr = empty_array[0..] },
    .{ .name = "after-select-window", .type = .array, .scope = Ss, .is_hook = true, .default_arr = empty_array[0..] },
    .{ .name = "after-send-keys", .type = .array, .scope = Ss, .is_hook = true, .default_arr = empty_array[0..] },
    .{ .name = "after-set-buffer", .type = .array, .scope = Ss, .is_hook = true, .default_arr = empty_array[0..] },
    .{ .name = "after-set-environment", .type = .array, .scope = Ss, .is_hook = true, .default_arr = empty_array[0..] },
    .{ .name = "after-set-hook", .type = .array, .scope = Ss, .is_hook = true, .default_arr = empty_array[0..] },
    .{ .name = "after-set-option", .type = .array, .scope = Ss, .is_hook = true, .default_arr = empty_array[0..] },
    .{ .name = "after-show-environment", .type = .array, .scope = Ss, .is_hook = true, .default_arr = empty_array[0..] },
    .{ .name = "after-show-messages", .type = .array, .scope = Ss, .is_hook = true, .default_arr = empty_array[0..] },
    .{ .name = "after-show-options", .type = .array, .scope = Ss, .is_hook = true, .default_arr = empty_array[0..] },
    .{ .name = "after-split-window", .type = .array, .scope = Ss, .is_hook = true, .default_arr = empty_array[0..] },
    .{ .name = "after-unbind-key", .type = .array, .scope = Ss, .is_hook = true, .default_arr = empty_array[0..] },
    .{ .name = "alert-activity", .type = .array, .scope = Ss, .is_hook = true, .default_arr = empty_array[0..] },
    .{ .name = "alert-bell", .type = .array, .scope = Ss, .is_hook = true, .default_arr = empty_array[0..] },
    .{ .name = "alert-silence", .type = .array, .scope = Ss, .is_hook = true, .default_arr = empty_array[0..] },
    .{ .name = "client-active", .type = .array, .scope = Ss, .is_hook = true, .default_arr = empty_array[0..] },
    .{ .name = "client-attached", .type = .array, .scope = Ss, .is_hook = true, .default_arr = empty_array[0..] },
    .{ .name = "client-dark-theme", .type = .array, .scope = Ss, .is_hook = true, .default_arr = empty_array[0..] },
    .{ .name = "client-detached", .type = .array, .scope = Ss, .is_hook = true, .default_arr = empty_array[0..] },
    .{ .name = "client-focus-in", .type = .array, .scope = Ss, .is_hook = true, .default_arr = empty_array[0..] },
    .{ .name = "client-focus-out", .type = .array, .scope = Ss, .is_hook = true, .default_arr = empty_array[0..] },
    .{ .name = "client-light-theme", .type = .array, .scope = Ss, .is_hook = true, .default_arr = empty_array[0..] },
    .{ .name = "client-resized", .type = .array, .scope = Ss, .is_hook = true, .default_arr = empty_array[0..] },
    .{ .name = "client-session-changed", .type = .array, .scope = Ss, .is_hook = true, .default_arr = empty_array[0..] },
    .{ .name = "command-error", .type = .array, .scope = Ss, .is_hook = true, .default_arr = empty_array[0..] },
    .{ .name = "pane-died", .type = .array, .scope = WP, .is_hook = true, .default_arr = empty_array[0..] },
    .{ .name = "pane-exited", .type = .array, .scope = WP, .is_hook = true, .default_arr = empty_array[0..] },
    .{ .name = "pane-focus-in", .type = .array, .scope = WP, .is_hook = true, .default_arr = empty_array[0..] },
    .{ .name = "pane-focus-out", .type = .array, .scope = WP, .is_hook = true, .default_arr = empty_array[0..] },
    .{ .name = "pane-mode-changed", .type = .array, .scope = WP, .is_hook = true, .default_arr = empty_array[0..] },
    .{ .name = "pane-set-clipboard", .type = .array, .scope = WP, .is_hook = true, .default_arr = empty_array[0..] },
    .{ .name = "pane-title-changed", .type = .array, .scope = WP, .is_hook = true, .default_arr = empty_array[0..] },
    .{ .name = "session-closed", .type = .array, .scope = Ss, .is_hook = true, .default_arr = empty_array[0..] },
    .{ .name = "session-created", .type = .array, .scope = Ss, .is_hook = true, .default_arr = empty_array[0..] },
    .{ .name = "session-renamed", .type = .array, .scope = Ss, .is_hook = true, .default_arr = empty_array[0..] },
    .{ .name = "session-window-changed", .type = .array, .scope = Ss, .is_hook = true, .default_arr = empty_array[0..] },
    .{ .name = "window-layout-changed", .type = .array, .scope = W, .is_hook = true, .default_arr = empty_array[0..] },
    .{ .name = "window-linked", .type = .array, .scope = Ss, .is_hook = true, .default_arr = empty_array[0..] },
    .{ .name = "window-pane-changed", .type = .array, .scope = W, .is_hook = true, .default_arr = empty_array[0..] },
    .{ .name = "window-renamed", .type = .array, .scope = W, .is_hook = true, .default_arr = empty_array[0..] },
    .{ .name = "window-resized", .type = .array, .scope = W, .is_hook = true, .default_arr = empty_array[0..] },
    .{ .name = "window-unlinked", .type = .array, .scope = Ss, .is_hook = true, .default_arr = empty_array[0..] },

    // ── Window options ────────────────────────────────────────────────────
    .{ .name = "aggressive-resize", .type = .flag, .scope = W, .default_num = 0 },
    .{ .name = "allow-passthrough", .type = .choice, .scope = WP, .default_num = 0, .choices = &.{ "off", "on", "all" } },
    .{ .name = "allow-rename", .type = .flag, .scope = WP, .default_num = 1 },
    .{ .name = "alternate-screen", .type = .flag, .scope = WP, .default_num = 1 },
    .{ .name = "automatic-rename", .type = .flag, .scope = W, .default_num = 1 },
    .{ .name = "automatic-rename-format", .type = .string, .scope = W, .default_str = "#{?pane_in_mode,[zmux],#{pane_current_command}}#{?pane_dead,dead,}" },
    .{ .name = "clock-mode-colour", .type = .colour, .scope = W, .default_num = 4 },
    .{ .name = "clock-mode-style", .type = .choice, .scope = W, .default_num = 1, .choices = &.{ "12", "24" } },
    .{ .name = "copy-mode-match-style", .type = .style, .scope = W, .default_str = "bg=cyan,fg=black" },
    .{ .name = "copy-mode-current-match-style", .type = .style, .scope = W, .default_str = "bg=magenta,fg=black" },
    .{ .name = "copy-mode-mark-style", .type = .style, .scope = W, .default_str = "bg=red,fg=black" },
    .{ .name = "fill-character", .type = .string, .scope = W, .default_str = "" },
    .{ .name = "main-pane-height", .type = .string, .scope = W, .default_str = "24" },
    .{ .name = "main-pane-width", .type = .string, .scope = W, .default_str = "80" },
    .{ .name = "menu-style", .type = .style, .scope = W, .default_str = "default" },
    .{ .name = "menu-selected-style", .type = .style, .scope = W, .default_str = "bg=yellow,fg=black" },
    .{ .name = "menu-border-style", .type = .style, .scope = W, .default_str = "default" },
    .{ .name = "menu-border-lines", .type = .choice, .scope = W, .default_num = 0, .choices = &.{ "single", "rounded", "double", "heavy", "simple", "padded", "none" } },
    .{ .name = "mode-keys", .type = .choice, .scope = W, .default_num = 0, .choices = &.{ "emacs", "vi" } },
    .{ .name = "mode-style", .type = .style, .scope = W, .default_str = "bg=yellow,fg=black" },
    .{ .name = "monitor-activity", .type = .flag, .scope = W, .default_num = 0 },
    .{ .name = "monitor-bell", .type = .flag, .scope = W, .default_num = 1 },
    .{ .name = "monitor-silence", .type = .number, .scope = W, .default_num = 0, .minimum = 0 },
    .{ .name = "other-pane-height", .type = .string, .scope = W, .default_str = "0" },
    .{ .name = "other-pane-width", .type = .string, .scope = W, .default_str = "0" },
    .{ .name = "tiled-layout-max-columns", .type = .number, .scope = W, .default_num = 0, .minimum = 0 },
    .{ .name = "pane-active-border-style", .type = .style, .scope = WP, .default_str = "#{?pane_in_mode,fg=yellow,#{?synchronize-panes,fg=red,fg=green}}" },
    .{ .name = "pane-base-index", .type = .number, .scope = W, .default_num = 0, .minimum = 0 },
    .{ .name = "pane-border-format", .type = .string, .scope = WP, .default_str = "#{?pane_active,#[reverse],}#{pane_index}#[default] \"#{pane_title}\"" },
    .{ .name = "pane-border-indicators", .type = .choice, .scope = WP, .default_num = 2, .choices = &.{ "off", "colour", "arrows", "both" } },
    .{ .name = "pane-border-lines", .type = .choice, .scope = WP, .default_num = 0, .choices = &.{ "single", "double", "heavy", "simple", "number", "spaces" } },
    .{ .name = "pane-border-status", .type = .choice, .scope = WP, .default_num = 0, .choices = &.{ "off", "top", "bottom" } },
    .{ .name = "pane-border-style", .type = .style, .scope = WP, .default_str = "default" },
    .{ .name = "pane-colours", .type = .array, .scope = WP },
    .{ .name = "pane-scrollbars", .type = .choice, .scope = WP, .default_num = 0, .choices = &.{ "off", "modal", "always" } },
    .{ .name = "pane-scrollbars-style", .type = .style, .scope = WP, .default_str = "default" },
    .{ .name = "pane-scrollbars-position", .type = .choice, .scope = WP, .default_num = T.PANE_SCROLLBARS_RIGHT, .choices = &.{ "right", "left" } },
    .{ .name = "popup-style", .type = .style, .scope = W, .default_str = "default" },
    .{ .name = "popup-border-style", .type = .style, .scope = W, .default_str = "default" },
    .{ .name = "popup-border-lines", .type = .choice, .scope = W, .default_num = 1, .choices = &.{ "single", "rounded", "double", "heavy", "simple", "padded", "none" } },
    .{ .name = "remain-on-exit", .type = .choice, .scope = WP, .default_num = 0, .choices = &.{ "off", "on", "failed" } },
    .{ .name = "remain-on-exit-format", .type = .string, .scope = WP, .default_str = "Pane is dead (#{pane_dead_status})" },
    .{ .name = "scroll-on-clear", .type = .flag, .scope = WP, .default_num = 1 },
    .{ .name = "scroll-speed", .type = .number, .scope = W, .default_num = 3 },
    .{ .name = "synchronize-panes", .type = .flag, .scope = WP, .default_num = 0 },
    .{ .name = "window-active-style", .type = .style, .scope = WP, .default_str = "default" },
    .{ .name = "window-size", .type = .choice, .scope = W, .default_num = T.WINDOW_SIZE_LATEST, .choices = &.{ "largest", "smallest", "manual", "latest" } },
    .{ .name = "window-status-activity-style", .type = .style, .scope = W, .default_str = "reverse" },
    .{ .name = "window-status-bell-style", .type = .style, .scope = W, .default_str = "reverse" },
    .{ .name = "window-status-current-format", .type = .string, .scope = W, .default_str = "#I:#W#{?window_flags,#{window_flags}, }" },
    .{ .name = "window-status-current-style", .type = .style, .scope = W, .default_str = "default" },
    .{ .name = "window-status-format", .type = .string, .scope = W, .default_str = "#I:#W#{?window_flags,#{window_flags}, }" },
    .{ .name = "window-status-last-style", .type = .style, .scope = W, .default_str = "default" },
    .{ .name = "window-status-separator", .type = .string, .scope = W, .default_str = " " },
    .{ .name = "window-status-style", .type = .style, .scope = W, .default_str = "default" },
    .{ .name = "window-style", .type = .style, .scope = WP, .default_str = "default" },
    .{ .name = "wrap-search", .type = .flag, .scope = W, .default_num = 1 },
};
