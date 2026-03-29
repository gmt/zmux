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
// Data tables extracted from key-bindings.zig.

const T = @import("types.zig");

pub const DefaultBindingSpec = struct {
    table: []const u8,
    key: T.key_code = T.KEYC_NONE,
    key_name: ?[]const u8 = null,
    note: ?[]const u8 = null,
    repeat: bool = false,
    argv: ?[]const []const u8 = null,
    command: ?[]const u8 = null,
};

const default_list_keys_argv = [_][]const u8{ "list-keys", "-N" };
const default_new_window_argv = [_][]const u8{"new-window"};
const default_display_message_argv = [_][]const u8{"display-message"};
const default_refresh_client_argv = [_][]const u8{"refresh-client"};
const default_client_mode_cancel_argv = [_][]const u8{ "send-keys", "-X", "cancel" };
const default_client_mode_choose_argv = [_][]const u8{ "send-keys", "-X", "choose" };
const default_client_mode_cursor_up_argv = [_][]const u8{ "send-keys", "-X", "cursor-up" };
const default_client_mode_cursor_down_argv = [_][]const u8{ "send-keys", "-X", "cursor-down" };
const default_client_mode_page_up_argv = [_][]const u8{ "send-keys", "-X", "page-up" };
const default_client_mode_page_down_argv = [_][]const u8{ "send-keys", "-X", "page-down" };
const default_client_mode_detach_argv = [_][]const u8{ "send-keys", "-X", "detach" };
const default_client_mode_detach_tagged_argv = [_][]const u8{ "send-keys", "-X", "detach-tagged" };
const default_client_mode_kill_argv = [_][]const u8{ "send-keys", "-X", "kill" };
const default_client_mode_kill_tagged_argv = [_][]const u8{ "send-keys", "-X", "kill-tagged" };
const default_client_mode_suspend_argv = [_][]const u8{ "send-keys", "-X", "suspend" };
const default_client_mode_suspend_tagged_argv = [_][]const u8{ "send-keys", "-X", "suspend-tagged" };
const default_client_mode_tag_argv = [_][]const u8{ "send-keys", "-X", "tag" };
const default_client_mode_tag_all_argv = [_][]const u8{ "send-keys", "-X", "tag-all" };
const default_client_mode_tag_none_argv = [_][]const u8{ "send-keys", "-X", "tag-none" };
const default_buffer_mode_cancel_argv = [_][]const u8{ "send-keys", "-X", "cancel" };
const default_buffer_mode_choose_argv = [_][]const u8{ "send-keys", "-X", "choose" };
const default_buffer_mode_delete_argv = [_][]const u8{ "send-keys", "-X", "delete" };
const default_buffer_mode_delete_tagged_argv = [_][]const u8{ "send-keys", "-X", "delete-tagged" };
const default_buffer_mode_edit_selected_argv = [_][]const u8{ "send-keys", "-X", "edit-selected" };
const default_buffer_mode_filter_argv = [_][]const u8{ "send-keys", "-X", "filter" };
const default_buffer_mode_paste_argv = [_][]const u8{ "send-keys", "-X", "paste" };
const default_buffer_mode_paste_tagged_argv = [_][]const u8{ "send-keys", "-X", "paste-tagged" };
const default_buffer_mode_tag_argv = [_][]const u8{ "send-keys", "-X", "tag" };
const default_buffer_mode_tag_all_argv = [_][]const u8{ "send-keys", "-X", "tag-all" };
const default_buffer_mode_tag_none_argv = [_][]const u8{ "send-keys", "-X", "tag-none" };
const default_buffer_mode_cursor_up_argv = [_][]const u8{ "send-keys", "-X", "cursor-up" };
const default_buffer_mode_cursor_down_argv = [_][]const u8{ "send-keys", "-X", "cursor-down" };
const default_buffer_mode_page_up_argv = [_][]const u8{ "send-keys", "-X", "page-up" };
const default_buffer_mode_page_down_argv = [_][]const u8{ "send-keys", "-X", "page-down" };
const default_tree_mode_cancel_argv = [_][]const u8{ "send-keys", "-X", "cancel" };
const default_tree_mode_choose_argv = [_][]const u8{ "send-keys", "-X", "choose" };
const default_tree_mode_cursor_up_argv = [_][]const u8{ "send-keys", "-X", "cursor-up" };
const default_tree_mode_cursor_down_argv = [_][]const u8{ "send-keys", "-X", "cursor-down" };
const default_tree_mode_page_up_argv = [_][]const u8{ "send-keys", "-X", "page-up" };
const default_tree_mode_page_down_argv = [_][]const u8{ "send-keys", "-X", "page-down" };
const default_tree_mode_expand_argv = [_][]const u8{ "send-keys", "-X", "expand" };
const default_tree_mode_collapse_argv = [_][]const u8{ "send-keys", "-X", "collapse" };
const default_tree_mode_scroll_left_argv = [_][]const u8{ "send-keys", "-X", "scroll-left" };
const default_tree_mode_scroll_right_argv = [_][]const u8{ "send-keys", "-X", "scroll-right" };
const default_tree_mode_tag_argv = [_][]const u8{ "send-keys", "-X", "tag" };
const default_tree_mode_tag_all_argv = [_][]const u8{ "send-keys", "-X", "tag-all" };
const default_tree_mode_tag_none_argv = [_][]const u8{ "send-keys", "-X", "tag-none" };
const default_tree_mode_home_target_argv = [_][]const u8{ "send-keys", "-X", "home-target" };
const default_options_mode_cancel_argv = [_][]const u8{ "send-keys", "-X", "cancel" };
const default_options_mode_choose_argv = [_][]const u8{ "send-keys", "-X", "choose" };
const default_options_mode_cursor_up_argv = [_][]const u8{ "send-keys", "-X", "cursor-up" };
const default_options_mode_cursor_down_argv = [_][]const u8{ "send-keys", "-X", "cursor-down" };
const default_options_mode_page_up_argv = [_][]const u8{ "send-keys", "-X", "page-up" };
const default_options_mode_page_down_argv = [_][]const u8{ "send-keys", "-X", "page-down" };
const default_options_mode_expand_argv = [_][]const u8{ "send-keys", "-X", "expand" };
const default_options_mode_collapse_argv = [_][]const u8{ "send-keys", "-X", "collapse" };
const default_options_mode_reset_current_argv = [_][]const u8{ "send-keys", "-X", "reset-current" };
const default_options_mode_toggle_hide_inherited_argv = [_][]const u8{ "send-keys", "-X", "toggle-hide-inherited" };
const default_options_mode_unset_current_argv = [_][]const u8{ "send-keys", "-X", "unset-current" };
const default_session_menu =
    " 'Next' 'n' {switch-client -n}" ++
    " 'Previous' 'p' {switch-client -p}" ++
    " ''" ++
    " 'Renumber' 'N' {move-window -r}" ++
    " 'Rename' 'n' {command-prompt -I \"#S\" {rename-session -- '%%'}}" ++
    " ''" ++
    " 'New Session' 's' {new-session}" ++
    " 'New Window' 'w' {new-window}";
const default_window_menu =
    " '#{?#{>:#{session_windows},1},,-}Swap Left' 'l' {swap-window -t:-1}" ++
    " '#{?#{>:#{session_windows},1},,-}Swap Right' 'r' {swap-window -t:+1}" ++
    " '#{?pane_marked_set,,-}Swap Marked' 's' {swap-window}" ++
    " ''" ++
    " 'Kill' 'X' {kill-window}" ++
    " 'Respawn' 'R' {respawn-window -k}" ++
    " '#{?pane_marked,Unmark,Mark}' 'm' {select-pane -m}" ++
    " 'Rename' 'n' {command-prompt -FI \"#W\" {rename-window -t '#{window_id}' -- '%%'}}" ++
    " ''" ++
    " 'New After' 'w' {new-window -a}" ++
    " 'New At End' 'W' {new-window}";
const default_pane_menu =
    " '#{?#{m/r:(copy|view)-mode,#{pane_mode}},Go To Top,}' '<' \"send -X history-top\"" ++
    " '#{?#{m/r:(copy|view)-mode,#{pane_mode}},Go To Bottom,}' '>' \"send -X history-bottom\"" ++
    " ''" ++
    " '#{?#{&&:#{buffer_size},#{!:#{pane_in_mode}}},Paste #[underscore]#{=/9/...:buffer_sample},}' 'p' \"paste-buffer\"" ++
    " ''" ++
    " '#{?mouse_word,Search For #[underscore]#{=/9/...:mouse_word},}' 'C-r' \"if -F '#{?#{m/r:(copy|view)-mode,#{pane_mode}},0,1}' 'copy-mode -t ='; send -X -t = search-backward -- '#{q:mouse_word}'\"" ++
    " '#{?mouse_word,Type #[underscore]#{=/9/...:mouse_word},}' 'C-y' \"copy-mode -q; send-keys -l -- '#{q:mouse_word}'\"" ++
    " '#{?mouse_word,Copy #[underscore]#{=/9/...:mouse_word},}' 'c' \"copy-mode -q; set-buffer -- '#{q:mouse_word}'\"" ++
    " '#{?mouse_line,Copy Line,}' 'l' \"copy-mode -q; set-buffer -- '#{q:mouse_line}'\"" ++
    " ''" ++
    " '#{?mouse_hyperlink,Type #[underscore]#{=/9/...:mouse_hyperlink},}' 'C-h' \"copy-mode -q; send-keys -l -- '#{q:mouse_hyperlink}'\"" ++
    " '#{?mouse_hyperlink,Copy #[underscore]#{=/9/...:mouse_hyperlink},}' 'h' \"copy-mode -q; set-buffer -- '#{q:mouse_hyperlink}'\"" ++
    " ''" ++
    " 'Horizontal Split' 'h' \"split-window -h\"" ++
    " 'Vertical Split' 'v' \"split-window -v\"" ++
    " ''" ++
    " '#{?#{>:#{window_panes},1},,-}Swap Up' 'u' \"swap-pane -U\"" ++
    " '#{?#{>:#{window_panes},1},,-}Swap Down' 'd' \"swap-pane -D\"" ++
    " '#{?pane_marked_set,,-}Swap Marked' 's' \"swap-pane\"" ++
    " ''" ++
    " 'Kill' 'X' \"kill-pane\"" ++
    " 'Respawn' 'R' \"respawn-pane -k\"" ++
    " '#{?pane_marked,Unmark,Mark}' 'm' \"select-pane -m\"" ++
    " '#{?#{>:#{window_panes},1},,-}#{?window_zoomed_flag,Unzoom,Zoom}' 'z' \"resize-pane -Z\"";
const default_pane_menu_display =
    "display-menu -t = -xM -yM -T '#[align=centre]#{pane_index} (#{pane_id})'" ++ default_pane_menu;
const default_mouse_down3_pane_argv = [_][]const u8{
    "if",
    "-F",
    "-t",
    "=",
    "#{||:#{mouse_any_flag},#{&&:#{pane_in_mode},#{?#{m/r:(copy|view)-mode,#{pane_mode}},0,1}}}",
    "select-pane -t=; send -M",
    default_pane_menu_display,
};

pub const default_binding_specs = [_]DefaultBindingSpec{
    .{
        .table = "prefix",
        .key_name = "C-b",
        .note = "Send the prefix key",
        .command = "send-prefix",
    },
    .{
        .table = "prefix",
        .key_name = "C-o",
        .note = "Rotate through the panes",
        .command = "rotate-window",
    },
    .{
        .table = "prefix",
        .key_name = "C-z",
        .note = "Suspend the current client",
        .command = "suspend-client",
    },
    .{
        .table = "prefix",
        .key_name = "Space",
        .note = "Select next layout",
        .command = "next-layout",
    },
    .{
        .table = "prefix",
        .key = '!',
        .note = "Break pane to a new window",
        .command = "break-pane",
    },
    .{
        .table = "prefix",
        .key = '"',
        .note = "Split window vertically",
        .command = "split-window",
    },
    .{
        .table = "prefix",
        .key = '#',
        .note = "List all paste buffers",
        .command = "list-buffers",
    },
    .{
        .table = "prefix",
        .key = '$',
        .note = "Rename current session",
        .command = "command-prompt -I'#S' \"rename-session -- '%%'\"",
    },
    .{
        .table = "prefix",
        .key = '%',
        .note = "Split window horizontally",
        .command = "split-window -h",
    },
    .{
        .table = "prefix",
        .key = '&',
        .note = "Kill current window",
        .command = "confirm-before -p'kill-window #W? (y/n)' kill-window",
    },
    .{
        .table = "prefix",
        .key_name = "'",
        .note = "Prompt for window index to select",
        .command = "command-prompt -T window-target -pindex \"select-window -t ':%%'\"",
    },
    .{
        .table = "prefix",
        .key = '(',
        .note = "Switch to previous client",
        .command = "switch-client -p",
    },
    .{
        .table = "prefix",
        .key = ')',
        .note = "Switch to next client",
        .command = "switch-client -n",
    },
    .{
        .table = "prefix",
        .key = ',',
        .note = "Rename current window",
        .command = "command-prompt -I'#W' \"rename-window -- '%%'\"",
    },
    .{
        .table = "prefix",
        .key = '-',
        .note = "Delete the most recent paste buffer",
        .command = "delete-buffer",
    },
    .{
        .table = "prefix",
        .key = '.',
        .note = "Move the current window",
        .command = "command-prompt -T target \"move-window -t '%%'\"",
    },
    .{
        .table = "prefix",
        .key = '/',
        .note = "Describe key binding",
        .command = "command-prompt -kpkey \"list-keys -1N '%%'\"",
    },
    .{
        .table = "prefix",
        .key = ':',
        .note = "Prompt for a command",
        .command = "command-prompt",
    },
    .{
        .table = "prefix",
        .key = ';',
        .note = "Move to the previously active pane",
        .command = "last-pane",
    },
    .{
        .table = "prefix",
        .key = '=',
        .note = "Choose a paste buffer from a list",
        .command = "choose-buffer -Z",
    },
    .{
        .table = "prefix",
        .key = '?',
        .note = "List key bindings",
        .argv = default_list_keys_argv[0..],
    },
    .{
        .table = "prefix",
        .key = 'D',
        .note = "Choose and detach a client from a list",
        .command = "choose-client -Z",
    },
    .{
        .table = "prefix",
        .key = 'E',
        .note = "Spread panes out evenly",
        .command = "select-layout -E",
    },
    .{
        .table = "prefix",
        .key = 'L',
        .note = "Switch to the last client",
        .command = "switch-client -l",
    },
    .{
        .table = "prefix",
        .key = 'M',
        .note = "Clear the marked pane",
        .command = "select-pane -M",
    },
    .{
        .table = "prefix",
        .key = '[',
        .note = "Enter copy mode",
        .command = "copy-mode",
    },
    .{
        .table = "prefix",
        .key = ']',
        .note = "Paste the most recent paste buffer",
        .command = "paste-buffer -p",
    },
    .{
        .table = "prefix",
        .key = 'c',
        .note = "Create a new window",
        .argv = default_new_window_argv[0..],
    },
    .{
        .table = "prefix",
        .key = 'd',
        .note = "Detach the current client",
        .command = "detach-client",
    },
    .{
        .table = "prefix",
        .key = 'f',
        .note = "Search for a pane",
        .command = "command-prompt \"find-window -Z -- '%%'\"",
    },
    .{
        .table = "prefix",
        .key = 'i',
        .note = "Display window information",
        .argv = default_display_message_argv[0..],
    },
    .{
        .table = "prefix",
        .key = 'l',
        .note = "Select the previously current window",
        .command = "last-window",
    },
    .{
        .table = "prefix",
        .key = 'm',
        .note = "Toggle the marked pane",
        .command = "select-pane -m",
    },
    .{
        .table = "prefix",
        .key = 'n',
        .note = "Select the next window",
        .command = "next-window",
    },
    .{
        .table = "prefix",
        .key = 'o',
        .note = "Select the next pane",
        .command = "select-pane -t:.+",
    },
    .{
        .table = "prefix",
        .key = 'C',
        .note = "Customize options",
        .command = "customize-mode -Z",
    },
    .{
        .table = "prefix",
        .key = 'p',
        .note = "Select the previous window",
        .command = "previous-window",
    },
    .{
        .table = "prefix",
        .key = 'q',
        .note = "Display pane numbers",
        .command = "display-panes",
    },
    .{
        .table = "prefix",
        .key = 'r',
        .note = "Redraw the current client",
        .argv = default_refresh_client_argv[0..],
    },
    .{
        .table = "prefix",
        .key = 's',
        .note = "Choose a session from a list",
        .command = "choose-tree -Zs",
    },
    .{
        .table = "prefix",
        .key = 't',
        .note = "Show a clock",
        .command = "clock-mode",
    },
    .{
        .table = "prefix",
        .key = 'w',
        .note = "Choose a window from a list",
        .command = "choose-tree -Zw",
    },
    .{
        .table = "prefix",
        .key = 'x',
        .note = "Kill the active pane",
        .command = "confirm-before -p'kill-pane #P? (y/n)' kill-pane",
    },
    .{
        .table = "prefix",
        .key = 'z',
        .note = "Zoom the active pane",
        .command = "resize-pane -Z",
    },
    .{
        .table = "prefix",
        .key = '{',
        .note = "Swap the active pane with the pane above",
        .command = "swap-pane -U",
    },
    .{
        .table = "prefix",
        .key = '}',
        .note = "Swap the active pane with the pane below",
        .command = "swap-pane -D",
    },
    .{
        .table = "prefix",
        .key = '~',
        .note = "Show messages",
        .command = "show-messages",
    },
    .{
        .table = "prefix",
        .key_name = "PPage",
        .note = "Enter copy mode and scroll up",
        .command = "copy-mode -u",
    },
    .{
        .table = "prefix",
        .key_name = "Up",
        .note = "Select the pane above the active pane",
        .repeat = true,
        .command = "select-pane -U",
    },
    .{
        .table = "prefix",
        .key_name = "Down",
        .note = "Select the pane below the active pane",
        .repeat = true,
        .command = "select-pane -D",
    },
    .{
        .table = "prefix",
        .key_name = "Left",
        .note = "Select the pane to the left of the active pane",
        .repeat = true,
        .command = "select-pane -L",
    },
    .{
        .table = "prefix",
        .key_name = "Right",
        .note = "Select the pane to the right of the active pane",
        .repeat = true,
        .command = "select-pane -R",
    },
    .{
        .table = "prefix",
        .key_name = "M-1",
        .note = "Set the even-horizontal layout",
        .command = "select-layout even-horizontal",
    },
    .{
        .table = "prefix",
        .key_name = "M-2",
        .note = "Set the even-vertical layout",
        .command = "select-layout even-vertical",
    },
    .{
        .table = "prefix",
        .key_name = "M-3",
        .note = "Set the main-horizontal layout",
        .command = "select-layout main-horizontal",
    },
    .{
        .table = "prefix",
        .key_name = "M-4",
        .note = "Set the main-vertical layout",
        .command = "select-layout main-vertical",
    },
    .{
        .table = "prefix",
        .key_name = "M-5",
        .note = "Select the tiled layout",
        .command = "select-layout tiled",
    },
    .{
        .table = "prefix",
        .key_name = "M-6",
        .note = "Set the main-horizontal-mirrored layout",
        .command = "select-layout main-horizontal-mirrored",
    },
    .{
        .table = "prefix",
        .key_name = "M-7",
        .note = "Set the main-vertical-mirrored layout",
        .command = "select-layout main-vertical-mirrored",
    },
    .{
        .table = "prefix",
        .key_name = "M-n",
        .note = "Select the next window with an alert",
        .command = "next-window -a",
    },
    .{
        .table = "prefix",
        .key_name = "M-o",
        .note = "Rotate through the panes in reverse",
        .command = "rotate-window -D",
    },
    .{
        .table = "prefix",
        .key_name = "M-p",
        .note = "Select the previous window with an alert",
        .command = "previous-window -a",
    },
    .{
        .table = "prefix",
        .key_name = "S-Up",
        .note = "Move the visible part of the window up",
        .repeat = true,
        .command = "refresh-client -U 10",
    },
    .{
        .table = "prefix",
        .key_name = "S-Down",
        .note = "Move the visible part of the window down",
        .repeat = true,
        .command = "refresh-client -D 10",
    },
    .{
        .table = "prefix",
        .key_name = "S-Left",
        .note = "Move the visible part of the window left",
        .repeat = true,
        .command = "refresh-client -L 10",
    },
    .{
        .table = "prefix",
        .key_name = "S-Right",
        .note = "Move the visible part of the window right",
        .repeat = true,
        .command = "refresh-client -R 10",
    },
    .{
        .table = "prefix",
        .key_name = "DC",
        .note = "Reset so the visible part of the window follows the cursor",
        .repeat = true,
        .command = "refresh-client -c",
    },
    .{
        .table = "prefix",
        .key_name = "M-Up",
        .note = "Resize the pane up by 5",
        .repeat = true,
        .command = "resize-pane -U 5",
    },
    .{
        .table = "prefix",
        .key_name = "M-Down",
        .note = "Resize the pane down by 5",
        .repeat = true,
        .command = "resize-pane -D 5",
    },
    .{
        .table = "prefix",
        .key_name = "M-Left",
        .note = "Resize the pane left by 5",
        .repeat = true,
        .command = "resize-pane -L 5",
    },
    .{
        .table = "prefix",
        .key_name = "M-Right",
        .note = "Resize the pane right by 5",
        .repeat = true,
        .command = "resize-pane -R 5",
    },
    .{
        .table = "prefix",
        .key_name = "C-Up",
        .note = "Resize the pane up",
        .repeat = true,
        .command = "resize-pane -U",
    },
    .{
        .table = "prefix",
        .key_name = "C-Down",
        .note = "Resize the pane down",
        .repeat = true,
        .command = "resize-pane -D",
    },
    .{
        .table = "prefix",
        .key_name = "C-Left",
        .note = "Resize the pane left",
        .repeat = true,
        .command = "resize-pane -L",
    },
    .{
        .table = "prefix",
        .key_name = "C-Right",
        .note = "Resize the pane right",
        .repeat = true,
        .command = "resize-pane -R",
    },
    .{
        .table = "prefix",
        .key = '<',
        .note = "Display window menu",
        .command = "display-menu -xW -yW -T '#[align=centre]#{window_index}:#{window_name}'" ++ default_window_menu,
    },
    .{
        .table = "prefix",
        .key = '>',
        .note = "Display pane menu",
        .command = "display-menu -xP -yP -T '#[align=centre]#{pane_index} (#{pane_id})'" ++ default_pane_menu,
    },
    .{
        .table = "root",
        .key_name = "MouseDown1Pane",
        .command = "select-pane -t =; send -M",
    },
    .{
        .table = "root",
        .key_name = "C-MouseDown1Pane",
        .command = "swap-pane -s @",
    },
    .{
        .table = "root",
        .key_name = "MouseDrag1Pane",
        .command = "if -F '#{||:#{pane_in_mode},#{mouse_any_flag}}' \"send -M\" \"copy-mode -M\"",
    },
    .{
        .table = "root",
        .key_name = "WheelUpPane",
        .command = "if -F '#{||:#{alternate_on},#{pane_in_mode},#{mouse_any_flag}}' \"send -M\" \"copy-mode -e -t =\"",
    },
    .{
        .table = "root",
        .key_name = "MouseDown2Pane",
        .command = "select-pane -t =; if -F '#{||:#{pane_in_mode},#{mouse_any_flag}}' \"send -M\" \"paste-buffer -p\"",
    },
    .{
        .table = "root",
        .key_name = "DoubleClick1Pane",
        .command = "select-pane -t =; if -F '#{||:#{pane_in_mode},#{mouse_any_flag}}' \"send -M\" \"copy-mode -H -t =; send -X select-word; run -d0.3; send -X copy-pipe-and-cancel\"",
    },
    .{
        .table = "root",
        .key_name = "TripleClick1Pane",
        .command = "select-pane -t =; if -F '#{||:#{pane_in_mode},#{mouse_any_flag}}' \"send -M\" \"copy-mode -H -t =; send -X select-line; run -d0.3; send -X copy-pipe-and-cancel\"",
    },
    .{
        .table = "root",
        .key_name = "MouseDrag1Border",
        .command = "resize-pane -M",
    },
    .{
        .table = "root",
        .key_name = "MouseDown1Status",
        .command = "switch-client -t =",
    },
    .{
        .table = "root",
        .key_name = "C-MouseDown1Status",
        .command = "swap-window -t @",
    },
    .{
        .table = "root",
        .key_name = "WheelDownStatus",
        .command = "select-window -t +",
    },
    .{
        .table = "root",
        .key_name = "WheelUpStatus",
        .command = "select-window -t -",
    },
    .{
        .table = "root",
        .key_name = "MouseDown3StatusLeft",
        .command = "display-menu -t = -xM -yW -T '#[align=centre]#{session_name}'" ++ default_session_menu,
    },
    .{
        .table = "root",
        .key_name = "M-MouseDown3StatusLeft",
        .command = "display-menu -t = -xM -yW -T '#[align=centre]#{session_name}'" ++ default_session_menu,
    },
    .{
        .table = "root",
        .key_name = "MouseDown3Status",
        .command = "display-menu -t = -xW -yW -T '#[align=centre]#{window_index}:#{window_name}'" ++ default_window_menu,
    },
    .{
        .table = "root",
        .key_name = "M-MouseDown3Status",
        .command = "display-menu -t = -xW -yW -T '#[align=centre]#{window_index}:#{window_name}'" ++ default_window_menu,
    },
    .{
        .table = "root",
        .key_name = "MouseDown3Pane",
        .argv = default_mouse_down3_pane_argv[0..],
    },
    .{
        .table = "root",
        .key_name = "M-MouseDown3Pane",
        .command = default_pane_menu_display,
    },
    .{
        .table = "root",
        .key_name = "MouseDown1ScrollbarUp",
        .command = "if -Ft= '#{pane_in_mode}' \"send -Xt= page-up\" \"copy-mode -u -t =\"",
    },
    .{
        .table = "root",
        .key_name = "MouseDown1ScrollbarDown",
        .command = "if -Ft= '#{pane_in_mode}' \"send -Xt= page-down\" \"copy-mode -d -t =\"",
    },
    .{
        .table = "root",
        .key_name = "MouseDrag1ScrollbarSlider",
        .command = "if -Ft= '#{pane_in_mode}' \"send -Xt= scroll-to-mouse\" \"copy-mode -S -t =\"",
    },
    .{
        .table = "copy-mode",
        .key_name = "C-Space",
        .command = "send -X begin-selection",
    },
    .{
        .table = "copy-mode",
        .key_name = "C-a",
        .command = "send -X start-of-line",
    },
    .{
        .table = "copy-mode",
        .key_name = "C-c",
        .command = "send -X cancel",
    },
    .{
        .table = "copy-mode",
        .key_name = "C-e",
        .command = "send -X end-of-line",
    },
    .{
        .table = "copy-mode",
        .key_name = "C-f",
        .command = "send -X cursor-right",
    },
    .{
        .table = "copy-mode",
        .key_name = "C-b",
        .command = "send -X cursor-left",
    },
    .{
        .table = "copy-mode",
        .key_name = "C-g",
        .command = "send -X clear-selection",
    },
    .{
        .table = "copy-mode",
        .key_name = "C-k",
        .command = "send -X copy-pipe-end-of-line-and-cancel",
    },
    .{
        .table = "copy-mode",
        .key_name = "C-l",
        .command = "send -X cursor-centre-vertical",
    },
    .{
        .table = "copy-mode",
        .key_name = "M-l",
        .command = "send -X cursor-centre-horizontal",
    },
    .{
        .table = "copy-mode",
        .key_name = "C-n",
        .command = "send -X cursor-down",
    },
    .{
        .table = "copy-mode",
        .key_name = "C-p",
        .command = "send -X cursor-up",
    },
    .{
        .table = "copy-mode",
        .key_name = "C-r",
        .command = "command-prompt -T search -ip'(search up)' -I'#{pane_search_string}' \"send -X search-backward-incremental -- '%%'\"",
    },
    .{
        .table = "copy-mode",
        .key_name = "C-s",
        .command = "command-prompt -T search -ip'(search down)' -I'#{pane_search_string}' \"send -X search-forward-incremental -- '%%'\"",
    },
    .{
        .table = "copy-mode",
        .key_name = "C-v",
        .command = "send -X page-down",
    },
    .{
        .table = "copy-mode",
        .key_name = "C-w",
        .command = "send -X copy-pipe-and-cancel",
    },
    .{
        .table = "copy-mode",
        .key_name = "Escape",
        .command = "send -X cancel",
    },
    .{
        .table = "copy-mode",
        .key_name = "Space",
        .command = "send -X page-down",
    },
    .{
        .table = "copy-mode",
        .key_name = ",",
        .command = "send -X jump-reverse",
    },
    .{
        .table = "copy-mode",
        .key_name = ";",
        .command = "send -X jump-again",
    },
    .{
        .table = "copy-mode",
        .key_name = "F",
        .command = "command-prompt -1p'(jump backward)' \"send -X jump-backward -- '%%'\"",
    },
    .{
        .table = "copy-mode",
        .key_name = "N",
        .command = "send -X search-reverse",
    },
    .{
        .table = "copy-mode",
        .key_name = "P",
        .command = "send -X toggle-position",
    },
    .{
        .table = "copy-mode",
        .key_name = "R",
        .command = "send -X rectangle-toggle",
    },
    .{
        .table = "copy-mode",
        .key_name = "T",
        .command = "command-prompt -1p'(jump to backward)' \"send -X jump-to-backward -- '%%'\"",
    },
    .{
        .table = "copy-mode",
        .key_name = "X",
        .command = "send -X set-mark",
    },
    .{
        .table = "copy-mode",
        .key_name = "f",
        .command = "command-prompt -1p'(jump forward)' \"send -X jump-forward -- '%%'\"",
    },
    .{
        .table = "copy-mode",
        .key_name = "g",
        .command = "command-prompt -p'(goto line)' \"send -X goto-line -- '%%'\"",
    },
    .{
        .table = "copy-mode",
        .key_name = "n",
        .command = "send -X search-again",
    },
    .{
        .table = "copy-mode",
        .key_name = "q",
        .command = "send -X cancel",
    },
    .{
        .table = "copy-mode",
        .key_name = "r",
        .command = "send -X refresh-from-pane",
    },
    .{
        .table = "copy-mode",
        .key_name = "t",
        .command = "command-prompt -1p'(jump to forward)' \"send -X jump-to-forward -- '%%'\"",
    },
    .{
        .table = "copy-mode",
        .key_name = "Home",
        .command = "send -X start-of-line",
    },
    .{
        .table = "copy-mode",
        .key_name = "End",
        .command = "send -X end-of-line",
    },
    .{
        .table = "copy-mode",
        .key_name = "MouseDown1Pane",
        .command = "select-pane",
    },
    .{
        .table = "copy-mode",
        .key_name = "MouseDrag1Pane",
        .command = "select-pane; send -X begin-selection",
    },
    .{
        .table = "copy-mode",
        .key_name = "MouseDragEnd1Pane",
        .command = "send -X copy-pipe-and-cancel",
    },
    .{
        .table = "copy-mode",
        .key_name = "WheelUpPane",
        .command = "select-pane; send -N5 -X scroll-up",
    },
    .{
        .table = "copy-mode",
        .key_name = "WheelDownPane",
        .command = "select-pane; send -N5 -X scroll-down",
    },
    .{
        .table = "copy-mode",
        .key_name = "DoubleClick1Pane",
        .command = "select-pane; send -X select-word; run -d0.3; send -X copy-pipe-and-cancel",
    },
    .{
        .table = "copy-mode",
        .key_name = "TripleClick1Pane",
        .command = "select-pane; send -X select-line; run -d0.3; send -X copy-pipe-and-cancel",
    },
    .{
        .table = "copy-mode",
        .key_name = "NPage",
        .command = "send -X page-down",
    },
    .{
        .table = "copy-mode",
        .key_name = "PPage",
        .command = "send -X page-up",
    },
    .{
        .table = "copy-mode",
        .key_name = "Up",
        .command = "send -X cursor-up",
    },
    .{
        .table = "copy-mode",
        .key_name = "Down",
        .command = "send -X cursor-down",
    },
    .{
        .table = "copy-mode",
        .key_name = "Left",
        .command = "send -X cursor-left",
    },
    .{
        .table = "copy-mode",
        .key_name = "Right",
        .command = "send -X cursor-right",
    },
    .{
        .table = "copy-mode",
        .key_name = "M-1",
        .command = "command-prompt -Np'(repeat)' -I1 \"send -N '%%'\"",
    },
    .{
        .table = "copy-mode",
        .key_name = "M-2",
        .command = "command-prompt -Np'(repeat)' -I2 \"send -N '%%'\"",
    },
    .{
        .table = "copy-mode",
        .key_name = "M-3",
        .command = "command-prompt -Np'(repeat)' -I3 \"send -N '%%'\"",
    },
    .{
        .table = "copy-mode",
        .key_name = "M-4",
        .command = "command-prompt -Np'(repeat)' -I4 \"send -N '%%'\"",
    },
    .{
        .table = "copy-mode",
        .key_name = "M-5",
        .command = "command-prompt -Np'(repeat)' -I5 \"send -N '%%'\"",
    },
    .{
        .table = "copy-mode",
        .key_name = "M-6",
        .command = "command-prompt -Np'(repeat)' -I6 \"send -N '%%'\"",
    },
    .{
        .table = "copy-mode",
        .key_name = "M-7",
        .command = "command-prompt -Np'(repeat)' -I7 \"send -N '%%'\"",
    },
    .{
        .table = "copy-mode",
        .key_name = "M-8",
        .command = "command-prompt -Np'(repeat)' -I8 \"send -N '%%'\"",
    },
    .{
        .table = "copy-mode",
        .key_name = "M-9",
        .command = "command-prompt -Np'(repeat)' -I9 \"send -N '%%'\"",
    },
    .{
        .table = "copy-mode",
        .key_name = "M-<",
        .command = "send -X history-top",
    },
    .{
        .table = "copy-mode",
        .key_name = "M->",
        .command = "send -X history-bottom",
    },
    .{
        .table = "copy-mode",
        .key_name = "M-R",
        .command = "send -X top-line",
    },
    .{
        .table = "copy-mode",
        .key_name = "M-b",
        .command = "send -X previous-word",
    },
    .{
        .table = "copy-mode",
        .key_name = "C-M-b",
        .command = "send -X previous-matching-bracket",
    },
    .{
        .table = "copy-mode",
        .key_name = "M-f",
        .command = "send -X next-word-end",
    },
    .{
        .table = "copy-mode",
        .key_name = "C-M-f",
        .command = "send -X next-matching-bracket",
    },
    .{
        .table = "copy-mode",
        .key_name = "M-m",
        .command = "send -X back-to-indentation",
    },
    .{
        .table = "copy-mode",
        .key_name = "M-r",
        .command = "send -X middle-line",
    },
    .{
        .table = "copy-mode",
        .key_name = "M-v",
        .command = "send -X page-up",
    },
    .{
        .table = "copy-mode",
        .key_name = "M-w",
        .command = "send -X copy-pipe-and-cancel",
    },
    .{
        .table = "copy-mode",
        .key_name = "M-x",
        .command = "send -X jump-to-mark",
    },
    .{
        .table = "copy-mode",
        .key_name = "M-{",
        .command = "send -X previous-paragraph",
    },
    .{
        .table = "copy-mode",
        .key_name = "M-}",
        .command = "send -X next-paragraph",
    },
    .{
        .table = "copy-mode",
        .key_name = "M-Up",
        .command = "send -X halfpage-up",
    },
    .{
        .table = "copy-mode",
        .key_name = "M-Down",
        .command = "send -X halfpage-down",
    },
    .{
        .table = "copy-mode",
        .key_name = "C-Up",
        .command = "send -X scroll-up",
    },
    .{
        .table = "copy-mode",
        .key_name = "C-Down",
        .command = "send -X scroll-down",
    },
    .{
        .table = "copy-mode-vi",
        .key_name = "#",
        .command = "send -FX search-backward -- '#{copy_cursor_word}'",
    },
    .{
        .table = "copy-mode-vi",
        .key_name = "*",
        .command = "send -FX search-forward -- '#{copy_cursor_word}'",
    },
    .{
        .table = "copy-mode-vi",
        .key_name = "C-c",
        .command = "send -X cancel",
    },
    .{
        .table = "copy-mode-vi",
        .key_name = "C-d",
        .command = "send -X halfpage-down",
    },
    .{
        .table = "copy-mode-vi",
        .key_name = "C-e",
        .command = "send -X scroll-down",
    },
    .{
        .table = "copy-mode-vi",
        .key_name = "C-b",
        .command = "send -X page-up",
    },
    .{
        .table = "copy-mode-vi",
        .key_name = "C-f",
        .command = "send -X page-down",
    },
    .{
        .table = "copy-mode-vi",
        .key_name = "C-h",
        .command = "send -X cursor-left",
    },
    .{
        .table = "copy-mode-vi",
        .key_name = "C-j",
        .command = "send -X copy-pipe-and-cancel",
    },
    .{
        .table = "copy-mode-vi",
        .key_name = "Enter",
        .command = "send -X copy-pipe-and-cancel",
    },
    .{
        .table = "copy-mode-vi",
        .key_name = "C-u",
        .command = "send -X halfpage-up",
    },
    .{
        .table = "copy-mode-vi",
        .key_name = "C-v",
        .command = "send -X rectangle-toggle",
    },
    .{
        .table = "copy-mode-vi",
        .key_name = "C-y",
        .command = "send -X scroll-up",
    },
    .{
        .table = "copy-mode-vi",
        .key_name = "Escape",
        .command = "send -X clear-selection",
    },
    .{
        .table = "copy-mode-vi",
        .key_name = "Space",
        .command = "send -X begin-selection",
    },
    .{
        .table = "copy-mode-vi",
        .key_name = "$",
        .command = "send -X end-of-line",
    },
    .{
        .table = "copy-mode-vi",
        .key_name = ",",
        .command = "send -X jump-reverse",
    },
    .{
        .table = "copy-mode-vi",
        .key_name = "/",
        .command = "command-prompt -T search -p'(search down)' \"send -X search-forward -- '%%'\"",
    },
    .{
        .table = "copy-mode-vi",
        .key_name = "0",
        .command = "send -X start-of-line",
    },
    .{
        .table = "copy-mode-vi",
        .key_name = "1",
        .command = "command-prompt -Np'(repeat)' -I1 \"send -N '%%'\"",
    },
    .{
        .table = "copy-mode-vi",
        .key_name = "2",
        .command = "command-prompt -Np'(repeat)' -I2 \"send -N '%%'\"",
    },
    .{
        .table = "copy-mode-vi",
        .key_name = "3",
        .command = "command-prompt -Np'(repeat)' -I3 \"send -N '%%'\"",
    },
    .{
        .table = "copy-mode-vi",
        .key_name = "4",
        .command = "command-prompt -Np'(repeat)' -I4 \"send -N '%%'\"",
    },
    .{
        .table = "copy-mode-vi",
        .key_name = "5",
        .command = "command-prompt -Np'(repeat)' -I5 \"send -N '%%'\"",
    },
    .{
        .table = "copy-mode-vi",
        .key_name = "6",
        .command = "command-prompt -Np'(repeat)' -I6 \"send -N '%%'\"",
    },
    .{
        .table = "copy-mode-vi",
        .key_name = "7",
        .command = "command-prompt -Np'(repeat)' -I7 \"send -N '%%'\"",
    },
    .{
        .table = "copy-mode-vi",
        .key_name = "8",
        .command = "command-prompt -Np'(repeat)' -I8 \"send -N '%%'\"",
    },
    .{
        .table = "copy-mode-vi",
        .key_name = "9",
        .command = "command-prompt -Np'(repeat)' -I9 \"send -N '%%'\"",
    },
    .{
        .table = "copy-mode-vi",
        .key_name = ":",
        .command = "command-prompt -p'(goto line)' \"send -X goto-line -- '%%'\"",
    },
    .{
        .table = "copy-mode-vi",
        .key_name = ";",
        .command = "send -X jump-again",
    },
    .{
        .table = "copy-mode-vi",
        .key_name = "?",
        .command = "command-prompt -T search -p'(search up)' \"send -X search-backward -- '%%'\"",
    },
    .{
        .table = "copy-mode-vi",
        .key_name = "A",
        .command = "send -X append-selection-and-cancel",
    },
    .{
        .table = "copy-mode-vi",
        .key_name = "B",
        .command = "send -X previous-space",
    },
    .{
        .table = "copy-mode-vi",
        .key_name = "D",
        .command = "send -X copy-pipe-end-of-line-and-cancel",
    },
    .{
        .table = "copy-mode-vi",
        .key_name = "E",
        .command = "send -X next-space-end",
    },
    .{
        .table = "copy-mode-vi",
        .key_name = "F",
        .command = "command-prompt -1p'(jump backward)' \"send -X jump-backward -- '%%'\"",
    },
    .{
        .table = "copy-mode-vi",
        .key_name = "G",
        .command = "send -X history-bottom",
    },
    .{
        .table = "copy-mode-vi",
        .key_name = "H",
        .command = "send -X top-line",
    },
    .{
        .table = "copy-mode-vi",
        .key_name = "J",
        .command = "send -X scroll-down",
    },
    .{
        .table = "copy-mode-vi",
        .key_name = "K",
        .command = "send -X scroll-up",
    },
    .{
        .table = "copy-mode-vi",
        .key_name = "L",
        .command = "send -X bottom-line",
    },
    .{
        .table = "copy-mode-vi",
        .key_name = "M",
        .command = "send -X middle-line",
    },
    .{
        .table = "copy-mode-vi",
        .key_name = "N",
        .command = "send -X search-reverse",
    },
    .{
        .table = "copy-mode-vi",
        .key_name = "P",
        .command = "send -X toggle-position",
    },
    .{
        .table = "copy-mode-vi",
        .key_name = "T",
        .command = "command-prompt -1p'(jump to backward)' \"send -X jump-to-backward -- '%%'\"",
    },
    .{
        .table = "copy-mode-vi",
        .key_name = "V",
        .command = "send -X select-line",
    },
    .{
        .table = "copy-mode-vi",
        .key_name = "W",
        .command = "send -X next-space",
    },
    .{
        .table = "copy-mode-vi",
        .key_name = "X",
        .command = "send -X set-mark",
    },
    .{
        .table = "copy-mode-vi",
        .key_name = "^",
        .command = "send -X back-to-indentation",
    },
    .{
        .table = "copy-mode-vi",
        .key_name = "b",
        .command = "send -X previous-word",
    },
    .{
        .table = "copy-mode-vi",
        .key_name = "e",
        .command = "send -X next-word-end",
    },
    .{
        .table = "copy-mode-vi",
        .key_name = "f",
        .command = "command-prompt -1p'(jump forward)' \"send -X jump-forward -- '%%'\"",
    },
    .{
        .table = "copy-mode-vi",
        .key_name = "g",
        .command = "send -X history-top",
    },
    .{
        .table = "copy-mode-vi",
        .key_name = "h",
        .command = "send -X cursor-left",
    },
    .{
        .table = "copy-mode-vi",
        .key_name = "j",
        .command = "send -X cursor-down",
    },
    .{
        .table = "copy-mode-vi",
        .key_name = "k",
        .command = "send -X cursor-up",
    },
    .{
        .table = "copy-mode-vi",
        .key_name = "z",
        .command = "send -X scroll-middle",
    },
    .{
        .table = "copy-mode-vi",
        .key_name = "l",
        .command = "send -X cursor-right",
    },
    .{
        .table = "copy-mode-vi",
        .key_name = "n",
        .command = "send -X search-again",
    },
    .{
        .table = "copy-mode-vi",
        .key_name = "o",
        .command = "send -X other-end",
    },
    .{
        .table = "copy-mode-vi",
        .key_name = "q",
        .command = "send -X cancel",
    },
    .{
        .table = "copy-mode-vi",
        .key_name = "r",
        .command = "send -X refresh-from-pane",
    },
    .{
        .table = "copy-mode-vi",
        .key_name = "t",
        .command = "command-prompt -1p'(jump to forward)' \"send -X jump-to-forward -- '%%'\"",
    },
    .{
        .table = "copy-mode-vi",
        .key_name = "v",
        .command = "send -X rectangle-toggle",
    },
    .{
        .table = "copy-mode-vi",
        .key_name = "w",
        .command = "send -X next-word",
    },
    .{
        .table = "copy-mode-vi",
        .key_name = "{",
        .command = "send -X previous-paragraph",
    },
    .{
        .table = "copy-mode-vi",
        .key_name = "}",
        .command = "send -X next-paragraph",
    },
    .{
        .table = "copy-mode-vi",
        .key_name = "%",
        .command = "send -X next-matching-bracket",
    },
    .{
        .table = "copy-mode-vi",
        .key_name = "Home",
        .command = "send -X start-of-line",
    },
    .{
        .table = "copy-mode-vi",
        .key_name = "End",
        .command = "send -X end-of-line",
    },
    .{
        .table = "copy-mode-vi",
        .key_name = "MouseDown1Pane",
        .command = "select-pane",
    },
    .{
        .table = "copy-mode-vi",
        .key_name = "MouseDrag1Pane",
        .command = "select-pane; send -X begin-selection",
    },
    .{
        .table = "copy-mode-vi",
        .key_name = "MouseDragEnd1Pane",
        .command = "send -X copy-pipe-and-cancel",
    },
    .{
        .table = "copy-mode-vi",
        .key_name = "WheelUpPane",
        .command = "select-pane; send -N5 -X scroll-up",
    },
    .{
        .table = "copy-mode-vi",
        .key_name = "WheelDownPane",
        .command = "select-pane; send -N5 -X scroll-down",
    },
    .{
        .table = "copy-mode-vi",
        .key_name = "DoubleClick1Pane",
        .command = "select-pane; send -X select-word; run -d0.3; send -X copy-pipe-and-cancel",
    },
    .{
        .table = "copy-mode-vi",
        .key_name = "TripleClick1Pane",
        .command = "select-pane; send -X select-line; run -d0.3; send -X copy-pipe-and-cancel",
    },
    .{
        .table = "copy-mode-vi",
        .key_name = "BSpace",
        .command = "send -X cursor-left",
    },
    .{
        .table = "copy-mode-vi",
        .key_name = "NPage",
        .command = "send -X page-down",
    },
    .{
        .table = "copy-mode-vi",
        .key_name = "PPage",
        .command = "send -X page-up",
    },
    .{
        .table = "copy-mode-vi",
        .key_name = "Up",
        .command = "send -X cursor-up",
    },
    .{
        .table = "copy-mode-vi",
        .key_name = "Down",
        .command = "send -X cursor-down",
    },
    .{
        .table = "copy-mode-vi",
        .key_name = "Left",
        .command = "send -X cursor-left",
    },
    .{
        .table = "copy-mode-vi",
        .key_name = "Right",
        .command = "send -X cursor-right",
    },
    .{
        .table = "copy-mode-vi",
        .key_name = "M-x",
        .command = "send -X jump-to-mark",
    },
    .{
        .table = "copy-mode-vi",
        .key_name = "C-Up",
        .command = "send -X scroll-up",
    },
    .{
        .table = "copy-mode-vi",
        .key_name = "C-Down",
        .command = "send -X scroll-down",
    },
    .{
        .table = "client-mode",
        .key = 'q',
        .note = "Exit client mode",
        .argv = default_client_mode_cancel_argv[0..],
    },
    .{
        .table = "client-mode",
        .key = T.C0_ESC,
        .note = "Exit client mode",
        .argv = default_client_mode_cancel_argv[0..],
    },
    .{
        .table = "client-mode",
        .key = '\r',
        .note = "Choose selected client",
        .argv = default_client_mode_choose_argv[0..],
    },
    .{
        .table = "client-mode",
        .key = T.KEYC_UP,
        .note = "Move up",
        .argv = default_client_mode_cursor_up_argv[0..],
    },
    .{
        .table = "client-mode",
        .key = T.KEYC_DOWN,
        .note = "Move down",
        .argv = default_client_mode_cursor_down_argv[0..],
    },
    .{
        .table = "client-mode",
        .key = T.KEYC_PPAGE,
        .note = "Page up",
        .argv = default_client_mode_page_up_argv[0..],
    },
    .{
        .table = "client-mode",
        .key = T.KEYC_NPAGE,
        .note = "Page down",
        .argv = default_client_mode_page_down_argv[0..],
    },
    .{
        .table = "client-mode",
        .key = 'd',
        .note = "Detach selected client",
        .argv = default_client_mode_detach_argv[0..],
    },
    .{
        .table = "client-mode",
        .key = 'D',
        .note = "Detach tagged clients",
        .argv = default_client_mode_detach_tagged_argv[0..],
    },
    .{
        .table = "client-mode",
        .key = 'x',
        .note = "Kill selected client",
        .argv = default_client_mode_kill_argv[0..],
    },
    .{
        .table = "client-mode",
        .key = 'X',
        .note = "Kill tagged clients",
        .argv = default_client_mode_kill_tagged_argv[0..],
    },
    .{
        .table = "client-mode",
        .key = 'z',
        .note = "Suspend selected client",
        .argv = default_client_mode_suspend_argv[0..],
    },
    .{
        .table = "client-mode",
        .key = 'Z',
        .note = "Suspend tagged clients",
        .argv = default_client_mode_suspend_tagged_argv[0..],
    },
    .{
        .table = "client-mode",
        .key = 't',
        .note = "Tag selected client",
        .argv = default_client_mode_tag_argv[0..],
    },
    .{
        .table = "client-mode",
        .key = 'T',
        .note = "Clear all tags",
        .argv = default_client_mode_tag_none_argv[0..],
    },
    .{
        .table = "client-mode",
        .key = 't' | T.KEYC_CTRL,
        .note = "Tag all clients",
        .argv = default_client_mode_tag_all_argv[0..],
    },
    .{
        .table = "client-mode-vi",
        .key = 'q',
        .note = "Exit client mode",
        .argv = default_client_mode_cancel_argv[0..],
    },
    .{
        .table = "client-mode-vi",
        .key = T.C0_ESC,
        .note = "Exit client mode",
        .argv = default_client_mode_cancel_argv[0..],
    },
    .{
        .table = "client-mode-vi",
        .key = '\r',
        .note = "Choose selected client",
        .argv = default_client_mode_choose_argv[0..],
    },
    .{
        .table = "client-mode-vi",
        .key = 'k',
        .note = "Move up",
        .argv = default_client_mode_cursor_up_argv[0..],
    },
    .{
        .table = "client-mode-vi",
        .key = 'j',
        .note = "Move down",
        .argv = default_client_mode_cursor_down_argv[0..],
    },
    .{
        .table = "client-mode-vi",
        .key = T.KEYC_UP,
        .note = "Move up",
        .argv = default_client_mode_cursor_up_argv[0..],
    },
    .{
        .table = "client-mode-vi",
        .key = T.KEYC_DOWN,
        .note = "Move down",
        .argv = default_client_mode_cursor_down_argv[0..],
    },
    .{
        .table = "client-mode-vi",
        .key = T.KEYC_PPAGE,
        .note = "Page up",
        .argv = default_client_mode_page_up_argv[0..],
    },
    .{
        .table = "client-mode-vi",
        .key = T.KEYC_NPAGE,
        .note = "Page down",
        .argv = default_client_mode_page_down_argv[0..],
    },
    .{
        .table = "client-mode-vi",
        .key = 'd',
        .note = "Detach selected client",
        .argv = default_client_mode_detach_argv[0..],
    },
    .{
        .table = "client-mode-vi",
        .key = 'D',
        .note = "Detach tagged clients",
        .argv = default_client_mode_detach_tagged_argv[0..],
    },
    .{
        .table = "client-mode-vi",
        .key = 'x',
        .note = "Kill selected client",
        .argv = default_client_mode_kill_argv[0..],
    },
    .{
        .table = "client-mode-vi",
        .key = 'X',
        .note = "Kill tagged clients",
        .argv = default_client_mode_kill_tagged_argv[0..],
    },
    .{
        .table = "client-mode-vi",
        .key = 'z',
        .note = "Suspend selected client",
        .argv = default_client_mode_suspend_argv[0..],
    },
    .{
        .table = "client-mode-vi",
        .key = 'Z',
        .note = "Suspend tagged clients",
        .argv = default_client_mode_suspend_tagged_argv[0..],
    },
    .{
        .table = "client-mode-vi",
        .key = 't',
        .note = "Tag selected client",
        .argv = default_client_mode_tag_argv[0..],
    },
    .{
        .table = "client-mode-vi",
        .key = 'T',
        .note = "Clear all tags",
        .argv = default_client_mode_tag_none_argv[0..],
    },
    .{
        .table = "client-mode-vi",
        .key = 't' | T.KEYC_CTRL,
        .note = "Tag all clients",
        .argv = default_client_mode_tag_all_argv[0..],
    },
    .{
        .table = "buffer-mode",
        .key = 'q',
        .note = "Exit buffer mode",
        .argv = default_buffer_mode_cancel_argv[0..],
    },
    .{
        .table = "buffer-mode",
        .key = T.C0_ESC,
        .note = "Exit buffer mode",
        .argv = default_buffer_mode_cancel_argv[0..],
    },
    .{
        .table = "buffer-mode",
        .key = '\r',
        .note = "Paste selected buffer",
        .argv = default_buffer_mode_choose_argv[0..],
    },
    .{
        .table = "buffer-mode",
        .key = 'p',
        .note = "Paste selected buffer",
        .argv = default_buffer_mode_paste_argv[0..],
    },
    .{
        .table = "buffer-mode",
        .key = 'P',
        .note = "Paste tagged buffers",
        .argv = default_buffer_mode_paste_tagged_argv[0..],
    },
    .{
        .table = "buffer-mode",
        .key = 'e',
        .note = "Edit selected buffer",
        .argv = default_buffer_mode_edit_selected_argv[0..],
    },
    .{
        .table = "buffer-mode",
        .key = 'd',
        .note = "Delete selected buffer",
        .argv = default_buffer_mode_delete_argv[0..],
    },
    .{
        .table = "buffer-mode",
        .key = 'D',
        .note = "Delete tagged buffers",
        .argv = default_buffer_mode_delete_tagged_argv[0..],
    },
    .{
        .table = "buffer-mode",
        .key = 'f',
        .note = "Filter buffers",
        .argv = default_buffer_mode_filter_argv[0..],
    },
    .{
        .table = "buffer-mode",
        .key = 't',
        .note = "Tag buffer",
        .argv = default_buffer_mode_tag_argv[0..],
    },
    .{
        .table = "buffer-mode",
        .key = 'T',
        .note = "Clear all tagged buffers",
        .argv = default_buffer_mode_tag_none_argv[0..],
    },
    .{
        .table = "buffer-mode",
        .key = 't' | T.KEYC_CTRL,
        .note = "Tag all buffers",
        .argv = default_buffer_mode_tag_all_argv[0..],
    },
    .{
        .table = "buffer-mode",
        .key = T.KEYC_UP,
        .note = "Move up",
        .argv = default_buffer_mode_cursor_up_argv[0..],
    },
    .{
        .table = "buffer-mode",
        .key = T.KEYC_DOWN,
        .note = "Move down",
        .argv = default_buffer_mode_cursor_down_argv[0..],
    },
    .{
        .table = "buffer-mode",
        .key = T.KEYC_PPAGE,
        .note = "Page up",
        .argv = default_buffer_mode_page_up_argv[0..],
    },
    .{
        .table = "buffer-mode",
        .key = T.KEYC_NPAGE,
        .note = "Page down",
        .argv = default_buffer_mode_page_down_argv[0..],
    },
    .{
        .table = "buffer-mode-vi",
        .key = 'q',
        .note = "Exit buffer mode",
        .argv = default_buffer_mode_cancel_argv[0..],
    },
    .{
        .table = "buffer-mode-vi",
        .key = T.C0_ESC,
        .note = "Exit buffer mode",
        .argv = default_buffer_mode_cancel_argv[0..],
    },
    .{
        .table = "buffer-mode-vi",
        .key = '\r',
        .note = "Paste selected buffer",
        .argv = default_buffer_mode_choose_argv[0..],
    },
    .{
        .table = "buffer-mode-vi",
        .key = 'p',
        .note = "Paste selected buffer",
        .argv = default_buffer_mode_paste_argv[0..],
    },
    .{
        .table = "buffer-mode-vi",
        .key = 'P',
        .note = "Paste tagged buffers",
        .argv = default_buffer_mode_paste_tagged_argv[0..],
    },
    .{
        .table = "buffer-mode-vi",
        .key = 'e',
        .note = "Edit selected buffer",
        .argv = default_buffer_mode_edit_selected_argv[0..],
    },
    .{
        .table = "buffer-mode-vi",
        .key = 'd',
        .note = "Delete selected buffer",
        .argv = default_buffer_mode_delete_argv[0..],
    },
    .{
        .table = "buffer-mode-vi",
        .key = 'D',
        .note = "Delete tagged buffers",
        .argv = default_buffer_mode_delete_tagged_argv[0..],
    },
    .{
        .table = "buffer-mode-vi",
        .key = 'f',
        .note = "Filter buffers",
        .argv = default_buffer_mode_filter_argv[0..],
    },
    .{
        .table = "buffer-mode-vi",
        .key = 't',
        .note = "Tag buffer",
        .argv = default_buffer_mode_tag_argv[0..],
    },
    .{
        .table = "buffer-mode-vi",
        .key = 'T',
        .note = "Clear all tagged buffers",
        .argv = default_buffer_mode_tag_none_argv[0..],
    },
    .{
        .table = "buffer-mode-vi",
        .key = 't' | T.KEYC_CTRL,
        .note = "Tag all buffers",
        .argv = default_buffer_mode_tag_all_argv[0..],
    },
    .{
        .table = "buffer-mode-vi",
        .key = 'k',
        .note = "Move up",
        .argv = default_buffer_mode_cursor_up_argv[0..],
    },
    .{
        .table = "buffer-mode-vi",
        .key = 'j',
        .note = "Move down",
        .argv = default_buffer_mode_cursor_down_argv[0..],
    },
    .{
        .table = "buffer-mode-vi",
        .key = T.KEYC_UP,
        .note = "Move up",
        .argv = default_buffer_mode_cursor_up_argv[0..],
    },
    .{
        .table = "buffer-mode-vi",
        .key = T.KEYC_DOWN,
        .note = "Move down",
        .argv = default_buffer_mode_cursor_down_argv[0..],
    },
    .{
        .table = "buffer-mode-vi",
        .key = T.KEYC_PPAGE,
        .note = "Page up",
        .argv = default_buffer_mode_page_up_argv[0..],
    },
    .{
        .table = "buffer-mode-vi",
        .key = T.KEYC_NPAGE,
        .note = "Page down",
        .argv = default_buffer_mode_page_down_argv[0..],
    },
    .{
        .table = "tree-mode",
        .key = 'q',
        .note = "Exit tree mode",
        .argv = default_tree_mode_cancel_argv[0..],
    },
    .{
        .table = "tree-mode",
        .key = T.C0_ESC,
        .note = "Exit tree mode",
        .argv = default_tree_mode_cancel_argv[0..],
    },
    .{
        .table = "tree-mode",
        .key = '\r',
        .note = "Choose selected item",
        .argv = default_tree_mode_choose_argv[0..],
    },
    .{
        .table = "tree-mode",
        .key = T.KEYC_UP,
        .note = "Move up",
        .argv = default_tree_mode_cursor_up_argv[0..],
    },
    .{
        .table = "tree-mode",
        .key = T.KEYC_DOWN,
        .note = "Move down",
        .argv = default_tree_mode_cursor_down_argv[0..],
    },
    .{
        .table = "tree-mode",
        .key = T.KEYC_PPAGE,
        .note = "Page up",
        .argv = default_tree_mode_page_up_argv[0..],
    },
    .{
        .table = "tree-mode",
        .key = T.KEYC_NPAGE,
        .note = "Page down",
        .argv = default_tree_mode_page_down_argv[0..],
    },
    .{
        .table = "tree-mode",
        .key = T.KEYC_LEFT,
        .note = "Collapse current item",
        .argv = default_tree_mode_collapse_argv[0..],
    },
    .{
        .table = "tree-mode",
        .key = T.KEYC_RIGHT,
        .note = "Expand current item",
        .argv = default_tree_mode_expand_argv[0..],
    },
    .{
        .table = "tree-mode",
        .key = '<',
        .note = "Scroll previews left",
        .argv = default_tree_mode_scroll_left_argv[0..],
    },
    .{
        .table = "tree-mode",
        .key = '>',
        .note = "Scroll previews right",
        .argv = default_tree_mode_scroll_right_argv[0..],
    },
    .{
        .table = "tree-mode",
        .key = 't',
        .note = "Tag selected item",
        .argv = default_tree_mode_tag_argv[0..],
    },
    .{
        .table = "tree-mode",
        .key = 'T',
        .note = "Clear all tree tags",
        .argv = default_tree_mode_tag_none_argv[0..],
    },
    .{
        .table = "tree-mode",
        .key = 't' | T.KEYC_CTRL,
        .note = "Tag all tree items",
        .argv = default_tree_mode_tag_all_argv[0..],
    },
    .{
        .table = "tree-mode",
        .key = 'H',
        .note = "Jump to the target item",
        .argv = default_tree_mode_home_target_argv[0..],
    },
    .{
        .table = "tree-mode-vi",
        .key = 'q',
        .note = "Exit tree mode",
        .argv = default_tree_mode_cancel_argv[0..],
    },
    .{
        .table = "tree-mode-vi",
        .key = T.C0_ESC,
        .note = "Exit tree mode",
        .argv = default_tree_mode_cancel_argv[0..],
    },
    .{
        .table = "tree-mode-vi",
        .key = '\r',
        .note = "Choose selected item",
        .argv = default_tree_mode_choose_argv[0..],
    },
    .{
        .table = "tree-mode-vi",
        .key = 'k',
        .note = "Move up",
        .argv = default_tree_mode_cursor_up_argv[0..],
    },
    .{
        .table = "tree-mode-vi",
        .key = 'j',
        .note = "Move down",
        .argv = default_tree_mode_cursor_down_argv[0..],
    },
    .{
        .table = "tree-mode-vi",
        .key = T.KEYC_UP,
        .note = "Move up",
        .argv = default_tree_mode_cursor_up_argv[0..],
    },
    .{
        .table = "tree-mode-vi",
        .key = T.KEYC_DOWN,
        .note = "Move down",
        .argv = default_tree_mode_cursor_down_argv[0..],
    },
    .{
        .table = "tree-mode-vi",
        .key = T.KEYC_PPAGE,
        .note = "Page up",
        .argv = default_tree_mode_page_up_argv[0..],
    },
    .{
        .table = "tree-mode-vi",
        .key = T.KEYC_NPAGE,
        .note = "Page down",
        .argv = default_tree_mode_page_down_argv[0..],
    },
    .{
        .table = "tree-mode-vi",
        .key = 'h',
        .note = "Collapse current item",
        .argv = default_tree_mode_collapse_argv[0..],
    },
    .{
        .table = "tree-mode-vi",
        .key = 'l',
        .note = "Expand current item",
        .argv = default_tree_mode_expand_argv[0..],
    },
    .{
        .table = "tree-mode-vi",
        .key = T.KEYC_LEFT,
        .note = "Collapse current item",
        .argv = default_tree_mode_collapse_argv[0..],
    },
    .{
        .table = "tree-mode-vi",
        .key = T.KEYC_RIGHT,
        .note = "Expand current item",
        .argv = default_tree_mode_expand_argv[0..],
    },
    .{
        .table = "tree-mode-vi",
        .key = '<',
        .note = "Scroll previews left",
        .argv = default_tree_mode_scroll_left_argv[0..],
    },
    .{
        .table = "tree-mode-vi",
        .key = '>',
        .note = "Scroll previews right",
        .argv = default_tree_mode_scroll_right_argv[0..],
    },
    .{
        .table = "tree-mode-vi",
        .key = 't',
        .note = "Tag selected item",
        .argv = default_tree_mode_tag_argv[0..],
    },
    .{
        .table = "tree-mode-vi",
        .key = 'T',
        .note = "Clear all tree tags",
        .argv = default_tree_mode_tag_none_argv[0..],
    },
    .{
        .table = "tree-mode-vi",
        .key = 't' | T.KEYC_CTRL,
        .note = "Tag all tree items",
        .argv = default_tree_mode_tag_all_argv[0..],
    },
    .{
        .table = "tree-mode-vi",
        .key = 'H',
        .note = "Jump to the target item",
        .argv = default_tree_mode_home_target_argv[0..],
    },
    .{
        .table = "options-mode",
        .key = 'q',
        .note = "Exit options mode",
        .argv = default_options_mode_cancel_argv[0..],
    },
    .{
        .table = "options-mode",
        .key = T.C0_ESC,
        .note = "Exit options mode",
        .argv = default_options_mode_cancel_argv[0..],
    },
    .{
        .table = "options-mode",
        .key = '\r',
        .note = "Inspect selected option",
        .argv = default_options_mode_choose_argv[0..],
    },
    .{
        .table = "options-mode",
        .key = T.KEYC_UP,
        .note = "Move up",
        .argv = default_options_mode_cursor_up_argv[0..],
    },
    .{
        .table = "options-mode",
        .key = T.KEYC_DOWN,
        .note = "Move down",
        .argv = default_options_mode_cursor_down_argv[0..],
    },
    .{
        .table = "options-mode",
        .key = T.KEYC_PPAGE,
        .note = "Page up",
        .argv = default_options_mode_page_up_argv[0..],
    },
    .{
        .table = "options-mode",
        .key = T.KEYC_NPAGE,
        .note = "Page down",
        .argv = default_options_mode_page_down_argv[0..],
    },
    .{
        .table = "options-mode",
        .key = T.KEYC_LEFT,
        .note = "Collapse current section",
        .argv = default_options_mode_collapse_argv[0..],
    },
    .{
        .table = "options-mode",
        .key = T.KEYC_RIGHT,
        .note = "Expand current section",
        .argv = default_options_mode_expand_argv[0..],
    },
    .{
        .table = "options-mode",
        .key = 'd',
        .note = "Reset selected option to default",
        .argv = default_options_mode_reset_current_argv[0..],
    },
    .{
        .table = "options-mode",
        .key = 'u',
        .note = "Unset selected option",
        .argv = default_options_mode_unset_current_argv[0..],
    },
    .{
        .table = "options-mode",
        .key = 'H',
        .note = "Toggle inherited options",
        .argv = default_options_mode_toggle_hide_inherited_argv[0..],
    },
    .{
        .table = "options-mode-vi",
        .key = 'q',
        .note = "Exit options mode",
        .argv = default_options_mode_cancel_argv[0..],
    },
    .{
        .table = "options-mode-vi",
        .key = T.C0_ESC,
        .note = "Exit options mode",
        .argv = default_options_mode_cancel_argv[0..],
    },
    .{
        .table = "options-mode-vi",
        .key = '\r',
        .note = "Inspect selected option",
        .argv = default_options_mode_choose_argv[0..],
    },
    .{
        .table = "options-mode-vi",
        .key = 'k',
        .note = "Move up",
        .argv = default_options_mode_cursor_up_argv[0..],
    },
    .{
        .table = "options-mode-vi",
        .key = 'j',
        .note = "Move down",
        .argv = default_options_mode_cursor_down_argv[0..],
    },
    .{
        .table = "options-mode-vi",
        .key = T.KEYC_UP,
        .note = "Move up",
        .argv = default_options_mode_cursor_up_argv[0..],
    },
    .{
        .table = "options-mode-vi",
        .key = T.KEYC_DOWN,
        .note = "Move down",
        .argv = default_options_mode_cursor_down_argv[0..],
    },
    .{
        .table = "options-mode-vi",
        .key = T.KEYC_PPAGE,
        .note = "Page up",
        .argv = default_options_mode_page_up_argv[0..],
    },
    .{
        .table = "options-mode-vi",
        .key = T.KEYC_NPAGE,
        .note = "Page down",
        .argv = default_options_mode_page_down_argv[0..],
    },
    .{
        .table = "options-mode-vi",
        .key = 'h',
        .note = "Collapse current section",
        .argv = default_options_mode_collapse_argv[0..],
    },
    .{
        .table = "options-mode-vi",
        .key = 'l',
        .note = "Expand current section",
        .argv = default_options_mode_expand_argv[0..],
    },
    .{
        .table = "options-mode-vi",
        .key = T.KEYC_LEFT,
        .note = "Collapse current section",
        .argv = default_options_mode_collapse_argv[0..],
    },
    .{
        .table = "options-mode-vi",
        .key = T.KEYC_RIGHT,
        .note = "Expand current section",
        .argv = default_options_mode_expand_argv[0..],
    },
    .{
        .table = "options-mode-vi",
        .key = 'd',
        .note = "Reset selected option to default",
        .argv = default_options_mode_reset_current_argv[0..],
    },
    .{
        .table = "options-mode-vi",
        .key = 'u',
        .note = "Unset selected option",
        .argv = default_options_mode_unset_current_argv[0..],
    },
    .{
        .table = "options-mode-vi",
        .key = 'H',
        .note = "Toggle inherited options",
        .argv = default_options_mode_toggle_hide_inherited_argv[0..],
    },
};
