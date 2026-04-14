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

//! Direct tests for [format-resolve.zig](format-resolve.zig) helpers. Per-key
//! resolver behavior is still covered primarily by [format-test.zig](format-test.zig).

const std = @import("std");
const T = @import("types.zig");
const env_mod = @import("environ.zig");
const fmt = @import("format.zig");
const fmt_resolve = @import("format-resolve.zig");
const hyperlinks_mod = @import("hyperlinks.zig");
const grid = @import("grid.zig");
const opts = @import("options.zig");
const screen_mod = @import("screen.zig");
const sess = @import("session.zig");
const utf8 = @import("utf8.zig");
const win = @import("window.zig");
const tty_features = @import("tty-features.zig");
const xm = @import("xmalloc.zig");

const FormatContext = fmt.FormatContext;
const format_require_complete = fmt.format_require_complete;

fn deinit_context_extras(ctx: *FormatContext) void {
    if (ctx.extras) |extras| {
        extras.deinit();
        xm.allocator.destroy(extras);
        ctx.extras = null;
    }
}

test "lookup_option_value reads server-scoped option from global_options" {
    opts.global_options = opts.options_create(null);
    defer opts.options_free(opts.global_options);
    opts.options_default_all(opts.global_options, T.OPTIONS_TABLE_SERVER);

    const ctx = FormatContext{};
    const v = fmt_resolve.lookup_option_value(xm.allocator, "buffer-limit", &ctx).?;
    defer xm.allocator.free(v);
    try std.testing.expectEqualStrings("50", v);
}

test "lookup_option_value reads session option from global_s_options without ctx session" {
    opts.global_s_options = opts.options_create(null);
    defer opts.options_free(opts.global_s_options);
    opts.options_default_all(opts.global_s_options, T.OPTIONS_TABLE_SESSION);

    const ctx = FormatContext{};
    const v = fmt_resolve.lookup_option_value(xm.allocator, "default-shell", &ctx).?;
    defer xm.allocator.free(v);
    try std.testing.expectEqualStrings("/bin/sh", v);
}

test "lookup_option_value returns null for unknown option names" {
    opts.global_options = opts.options_create(null);
    defer opts.options_free(opts.global_options);
    opts.options_default_all(opts.global_options, T.OPTIONS_TABLE_SERVER);

    const ctx = FormatContext{};
    try std.testing.expect(null == fmt_resolve.lookup_option_value(xm.allocator, "not-a-real-zmux-option-xyz", &ctx));
}

test "lookup_option_value reads custom at-prefixed pane options" {
    opts.global_w_options = opts.options_create(null);
    defer opts.options_free(opts.global_w_options);
    opts.options_default_all(opts.global_w_options, T.OPTIONS_TABLE_WINDOW);
    win.window_init_globals(xm.allocator);

    const w = win.window_create(8, 4, T.DEFAULT_XPIXEL, T.DEFAULT_YPIXEL);
    const wp = win.window_add_pane(w, null, 8, 4);
    w.active = wp;
    defer {
        _ = win.all_window_panes.remove(wp.id);
        win.window_pane_destroy(wp);
        opts.options_free(w.options);
        xm.allocator.free(w.name);
        _ = win.windows.remove(w.id);
        xm.allocator.destroy(w);
    }

    opts.options_set_string(wp.options, false, "@fmtresolve_custom", "pane-value");

    const ctx = FormatContext{ .window = w, .pane = wp };
    const v = fmt_resolve.lookup_option_value(xm.allocator, "@fmtresolve_custom", &ctx).?;
    defer xm.allocator.free(v);
    try std.testing.expectEqualStrings("pane-value", v);
}

test "format_grid_hyperlink resolves uri through padding cells to the left" {
    const sc = screen_mod.screen_init(4, 1, 0);
    defer {
        screen_mod.screen_free(sc);
        xm.allocator.destroy(sc);
    }

    const id = hyperlinks_mod.hyperlinks_put(sc.hyperlinks.?, "https://fmt-resolve.test/x", "id1");
    grid.set_padding(sc.grid, 0, 0);
    grid.set_padding(sc.grid, 0, 1);
    var linked = T.grid_default_cell;
    utf8.utf8_set(&linked.data, 'L');
    linked.link = id;
    grid.set_cell(sc.grid, 0, 2, &linked);

    const uri = fmt_resolve.format_grid_hyperlink(sc, 2, 0).?;
    defer xm.allocator.free(uri);
    try std.testing.expectEqualStrings("https://fmt-resolve.test/x", uri);
}

test "format_grid_hyperlink returns null without hyperlinks or zero link" {
    const sc = screen_mod.screen_init(2, 1, 0);
    defer {
        screen_mod.screen_free(sc);
        xm.allocator.destroy(sc);
    }

    grid.set_ascii(sc.grid, 0, 0, 'a');
    try std.testing.expect(null == fmt_resolve.format_grid_hyperlink(sc, 0, 0));
}

test "ctx_session ctx_window ctx_pane follow winlink and client session" {
    sess.session_init_globals(xm.allocator);
    win.window_init_globals(xm.allocator);

    opts.global_options = opts.options_create(null);
    defer opts.options_free(opts.global_options);
    opts.global_s_options = opts.options_create(null);
    defer opts.options_free(opts.global_s_options);
    opts.global_w_options = opts.options_create(null);
    defer opts.options_free(opts.global_w_options);
    opts.options_default_all(opts.global_options, T.OPTIONS_TABLE_SERVER);
    opts.options_default_all(opts.global_s_options, T.OPTIONS_TABLE_SESSION);
    opts.options_default_all(opts.global_w_options, T.OPTIONS_TABLE_WINDOW);

    env_mod.global_environ = env_mod.environ_create();
    defer env_mod.environ_free(env_mod.global_environ);

    const s = sess.session_create(null, "fmt-resolve-ctx", "/", env_mod.environ_create(), opts.options_create(opts.global_s_options), null);
    defer if (sess.session_find("fmt-resolve-ctx") != null) sess.session_destroy(s, false, "test");

    const w = win.window_create(8, 4, T.DEFAULT_XPIXEL, T.DEFAULT_YPIXEL);
    const wp = win.window_add_pane(w, null, 8, 4);
    w.active = wp;
    var cause: ?[]u8 = null;
    const wl = sess.session_attach(s, w, 0, &cause).?;
    s.curw = wl;

    var client = T.Client{
        .environ = env_mod.environ_create(),
        .tty = undefined,
        .status = .{},
        .session = s,
    };
    defer env_mod.environ_free(client.environ);

    try std.testing.expectEqual(s, fmt_resolve.ctx_session(&FormatContext{ .winlink = wl }).?);
    try std.testing.expectEqual(w, fmt_resolve.ctx_window(&FormatContext{ .winlink = wl }).?);
    try std.testing.expectEqual(wp, fmt_resolve.ctx_pane(&FormatContext{ .winlink = wl }).?);

    try std.testing.expectEqual(s, fmt_resolve.ctx_session(&FormatContext{ .client = &client }).?);
    try std.testing.expectEqual(w, fmt_resolve.ctx_window(&FormatContext{ .client = &client }).?);
    try std.testing.expectEqual(wp, fmt_resolve.ctx_pane(&FormatContext{ .client = &client }).?);
}

test "session_is_active matches client session or bare context session" {
    sess.session_init_globals(xm.allocator);

    opts.global_s_options = opts.options_create(null);
    defer opts.options_free(opts.global_s_options);
    opts.options_default_all(opts.global_s_options, T.OPTIONS_TABLE_SESSION);

    env_mod.global_environ = env_mod.environ_create();
    defer env_mod.environ_free(env_mod.global_environ);

    const s_a = sess.session_create(null, "fmt-resolve-act-a", "/", env_mod.environ_create(), opts.options_create(opts.global_s_options), null);
    defer if (sess.session_find("fmt-resolve-act-a") != null) sess.session_destroy(s_a, false, "test");
    const s_b = sess.session_create(null, "fmt-resolve-act-b", "/", env_mod.environ_create(), opts.options_create(opts.global_s_options), null);
    defer if (sess.session_find("fmt-resolve-act-b") != null) sess.session_destroy(s_b, false, "test");

    var client = T.Client{
        .environ = env_mod.environ_create(),
        .tty = undefined,
        .status = .{},
        .session = s_a,
    };
    defer env_mod.environ_free(client.environ);

    try std.testing.expect(fmt_resolve.session_is_active(&FormatContext{ .session = s_a }, s_a));
    try std.testing.expect(!fmt_resolve.session_is_active(&FormatContext{ .session = s_a }, s_b));
    try std.testing.expect(fmt_resolve.session_is_active(&FormatContext{ .client = &client }, s_a));
    try std.testing.expect(!fmt_resolve.session_is_active(&FormatContext{ .client = &client }, s_b));
}

test "child_context_for_pane sets loop_last_flag format_type and pane window" {
    const base = FormatContext{ .message_text = "keep" };
    opts.global_w_options = opts.options_create(null);
    defer opts.options_free(opts.global_w_options);
    opts.options_default_all(opts.global_w_options, T.OPTIONS_TABLE_WINDOW);
    win.window_init_globals(xm.allocator);

    const w = win.window_create(4, 4, T.DEFAULT_XPIXEL, T.DEFAULT_YPIXEL);
    const wp = win.window_add_pane(w, null, 4, 4);
    defer {
        _ = win.all_window_panes.remove(wp.id);
        win.window_pane_destroy(wp);
        opts.options_free(w.options);
        xm.allocator.free(w.name);
        _ = win.windows.remove(w.id);
        xm.allocator.destroy(w);
    }

    const child = fmt_resolve.child_context_for_pane(&base, w, wp, true);
    try std.testing.expectEqual(w, child.window.?);
    try std.testing.expectEqual(wp, child.pane.?);
    try std.testing.expectEqual(true, child.loop_last_flag.?);
    try std.testing.expectEqual(fmt.FormatType.pane, child.format_type);
    try std.testing.expectEqualStrings("keep", child.message_text.?);
}

test "child_context_for_session copies curw window active pane and loop flag" {
    sess.session_init_globals(xm.allocator);
    win.window_init_globals(xm.allocator);

    opts.global_options = opts.options_create(null);
    defer opts.options_free(opts.global_options);
    opts.global_s_options = opts.options_create(null);
    defer opts.options_free(opts.global_s_options);
    opts.global_w_options = opts.options_create(null);
    defer opts.options_free(opts.global_w_options);
    opts.options_default_all(opts.global_options, T.OPTIONS_TABLE_SERVER);
    opts.options_default_all(opts.global_s_options, T.OPTIONS_TABLE_SESSION);
    opts.options_default_all(opts.global_w_options, T.OPTIONS_TABLE_WINDOW);

    env_mod.global_environ = env_mod.environ_create();
    defer env_mod.environ_free(env_mod.global_environ);

    const s = sess.session_create(null, "fmt-resolve-ch-sess", "/", env_mod.environ_create(), opts.options_create(opts.global_s_options), null);
    defer if (sess.session_find("fmt-resolve-ch-sess") != null) sess.session_destroy(s, false, "test");

    const w = win.window_create(8, 4, T.DEFAULT_XPIXEL, T.DEFAULT_YPIXEL);
    const wp = win.window_add_pane(w, null, 8, 4);
    w.active = wp;
    var cause: ?[]u8 = null;
    const wl = sess.session_attach(s, w, 0, &cause).?;
    s.curw = wl;

    const base = FormatContext{};
    const child = fmt_resolve.child_context_for_session(&base, s, false);
    try std.testing.expectEqual(s, child.session.?);
    try std.testing.expectEqual(wl, child.winlink.?);
    try std.testing.expectEqual(w, child.window.?);
    try std.testing.expectEqual(wp, child.pane.?);
    try std.testing.expectEqual(false, child.loop_last_flag.?);
    try std.testing.expectEqual(fmt.FormatType.session, child.format_type);
}

test "child_context_for_client fills session chain when client is attached" {
    sess.session_init_globals(xm.allocator);
    win.window_init_globals(xm.allocator);

    opts.global_s_options = opts.options_create(null);
    defer opts.options_free(opts.global_s_options);
    opts.global_w_options = opts.options_create(null);
    defer opts.options_free(opts.global_w_options);
    opts.options_default_all(opts.global_s_options, T.OPTIONS_TABLE_SESSION);
    opts.options_default_all(opts.global_w_options, T.OPTIONS_TABLE_WINDOW);

    env_mod.global_environ = env_mod.environ_create();
    defer env_mod.environ_free(env_mod.global_environ);

    const s = sess.session_create(null, "fmt-resolve-ch-cl", "/", env_mod.environ_create(), opts.options_create(opts.global_s_options), null);
    defer if (sess.session_find("fmt-resolve-ch-cl") != null) sess.session_destroy(s, false, "test");

    const w = win.window_create(8, 4, T.DEFAULT_XPIXEL, T.DEFAULT_YPIXEL);
    const wp = win.window_add_pane(w, null, 8, 4);
    w.active = wp;
    var cause: ?[]u8 = null;
    const wl = sess.session_attach(s, w, 0, &cause).?;
    s.curw = wl;

    var client = T.Client{
        .environ = env_mod.environ_create(),
        .tty = undefined,
        .status = .{},
        .session = s,
    };
    defer env_mod.environ_free(client.environ);

    const base = FormatContext{};
    const child = fmt_resolve.child_context_for_client(&base, &client, true);
    try std.testing.expectEqual(&client, child.client.?);
    try std.testing.expectEqual(s, child.session.?);
    try std.testing.expectEqual(wl, child.winlink.?);
    try std.testing.expectEqual(w, child.window.?);
    try std.testing.expectEqual(wp, child.pane.?);
    try std.testing.expectEqual(true, child.loop_last_flag.?);
}

test "lookup_option_value resolves custom options through pane window session and global scope chain" {
    sess.session_init_globals(xm.allocator);
    win.window_init_globals(xm.allocator);

    opts.global_options = opts.options_create(null);
    defer opts.options_free(opts.global_options);
    opts.global_s_options = opts.options_create(null);
    defer opts.options_free(opts.global_s_options);
    opts.global_w_options = opts.options_create(null);
    defer opts.options_free(opts.global_w_options);
    opts.options_default_all(opts.global_options, T.OPTIONS_TABLE_SERVER);
    opts.options_default_all(opts.global_s_options, T.OPTIONS_TABLE_SESSION);
    opts.options_default_all(opts.global_w_options, T.OPTIONS_TABLE_WINDOW);

    env_mod.global_environ = env_mod.environ_create();
    defer env_mod.environ_free(env_mod.global_environ);

    const s = sess.session_create(null, "fmt-resolve-scope-chain", "/", env_mod.environ_create(), opts.options_create(opts.global_s_options), null);
    defer if (sess.session_find("fmt-resolve-scope-chain") != null) sess.session_destroy(s, false, "test");

    const w = win.window_create(8, 4, T.DEFAULT_XPIXEL, T.DEFAULT_YPIXEL);
    const wp = win.window_add_pane(w, null, 8, 4);
    w.active = wp;
    var cause: ?[]u8 = null;
    const wl = sess.session_attach(s, w, 0, &cause).?;
    s.curw = wl;

    opts.options_set_string(opts.global_options, false, "@fmtresolve_scope_chain", "global-value");
    opts.options_set_string(opts.global_s_options, false, "@fmtresolve_scope_chain", "global-session-value");
    opts.options_set_string(opts.global_w_options, false, "@fmtresolve_scope_chain", "global-window-value");
    opts.options_set_string(s.options, false, "@fmtresolve_scope_chain", "session-value");
    opts.options_set_string(w.options, false, "@fmtresolve_scope_chain", "window-value");
    opts.options_set_string(wp.options, false, "@fmtresolve_scope_chain", "pane-value");

    const pane_ctx = FormatContext{ .session = s, .winlink = wl, .window = w, .pane = wp };
    const pane_value = fmt_resolve.lookup_option_value(xm.allocator, "@fmtresolve_scope_chain", &pane_ctx).?;
    defer xm.allocator.free(pane_value);
    try std.testing.expectEqualStrings("pane-value", pane_value);

    w.active = null;

    const window_ctx = FormatContext{ .window = w };
    const window_value = fmt_resolve.lookup_option_value(xm.allocator, "@fmtresolve_scope_chain", &window_ctx).?;
    defer xm.allocator.free(window_value);
    try std.testing.expectEqualStrings("window-value", window_value);

    s.curw = null;

    const session_ctx = FormatContext{ .session = s };
    const session_value = fmt_resolve.lookup_option_value(xm.allocator, "@fmtresolve_scope_chain", &session_ctx).?;
    defer xm.allocator.free(session_value);
    try std.testing.expectEqualStrings("session-value", session_value);

    const empty_ctx = FormatContext{};
    const global_value = fmt_resolve.lookup_option_value(xm.allocator, "@fmtresolve_scope_chain", &empty_ctx).?;
    defer xm.allocator.free(global_value);
    try std.testing.expectEqualStrings("global-value", global_value);
}

test "lookup_option_value handles orphan window scope and empty custom scopes" {
    opts.global_options = opts.options_create(null);
    defer opts.options_free(opts.global_options);
    opts.global_s_options = opts.options_create(null);
    defer opts.options_free(opts.global_s_options);
    opts.global_w_options = opts.options_create(null);
    defer opts.options_free(opts.global_w_options);
    opts.options_default_all(opts.global_options, T.OPTIONS_TABLE_SERVER);
    opts.options_default_all(opts.global_s_options, T.OPTIONS_TABLE_SESSION);
    opts.options_default_all(opts.global_w_options, T.OPTIONS_TABLE_WINDOW);
    win.window_init_globals(xm.allocator);

    const w = win.window_create(8, 4, T.DEFAULT_XPIXEL, T.DEFAULT_YPIXEL);
    const wp = win.window_add_pane(w, null, 8, 4);
    w.active = wp;
    defer {
        _ = win.all_window_panes.remove(wp.id);
        win.window_pane_destroy(wp);
        opts.options_free(w.options);
        xm.allocator.free(w.name);
        _ = win.windows.remove(w.id);
        xm.allocator.destroy(w);
    }

    opts.options_set_string(opts.global_w_options, false, "@fmtresolve_orphan_scope", "global-window-value");
    opts.options_set_string(w.options, false, "@fmtresolve_orphan_scope", "window-value");

    const orphan_window_ctx = FormatContext{ .window = w };
    try std.testing.expect(null == fmt_resolve.ctx_session(&orphan_window_ctx));

    const orphan_value = fmt_resolve.lookup_option_value(xm.allocator, "@fmtresolve_orphan_scope", &orphan_window_ctx).?;
    defer xm.allocator.free(orphan_value);
    try std.testing.expectEqualStrings("window-value", orphan_value);

    const empty_ctx = FormatContext{};
    const empty_value = fmt_resolve.lookup_option_value(xm.allocator, "@fmtresolve_orphan_scope", &empty_ctx).?;
    defer xm.allocator.free(empty_value);
    try std.testing.expectEqualStrings("global-window-value", empty_value);

    try std.testing.expect(null == fmt_resolve.lookup_option_value(xm.allocator, "@fmtresolve_missing_scope", &empty_ctx));
}

test "child_context_for_pane preserves inherited metadata and extras" {
    opts.global_w_options = opts.options_create(null);
    defer opts.options_free(opts.global_w_options);
    opts.options_default_all(opts.global_w_options, T.OPTIONS_TABLE_WINDOW);
    win.window_init_globals(xm.allocator);

    const w = win.window_create(4, 4, T.DEFAULT_XPIXEL, T.DEFAULT_YPIXEL);
    const wp = win.window_add_pane(w, null, 4, 4);
    defer {
        _ = win.all_window_panes.remove(wp.id);
        win.window_pane_destroy(wp);
        opts.options_free(w.options);
        xm.allocator.free(w.name);
        _ = win.windows.remove(w.id);
        xm.allocator.destroy(w);
    }

    var base = FormatContext{
        .message_text = "keep",
        .command_name = "display-message",
        .line = 7,
    };
    defer deinit_context_extras(&base);
    fmt.format_add(&base, "fmtresolve_child_note", "inherited-extra");

    const child = fmt_resolve.child_context_for_pane(&base, w, wp, false);
    try std.testing.expectEqualStrings("keep", child.message_text.?);
    try std.testing.expectEqualStrings("display-message", child.command_name.?);
    try std.testing.expectEqual(@as(u32, 7), child.line.?);
    try std.testing.expectEqual(base.extras, child.extras);
    try std.testing.expectEqual(w, child.window.?);
    try std.testing.expectEqual(wp, child.pane.?);
    try std.testing.expectEqual(false, child.loop_last_flag.?);
    try std.testing.expectEqual(fmt.FormatType.pane, child.format_type);

    const inherited = format_require_complete(xm.allocator, "#{message_text}|#{command_name}|#{line}|#{fmtresolve_child_note}", &child).?;
    defer xm.allocator.free(inherited);
    try std.testing.expectEqualStrings("keep|display-message|7|inherited-extra", inherited);
}

test "child_context_for_client without attached session keeps parent scope chain" {
    sess.session_init_globals(xm.allocator);
    win.window_init_globals(xm.allocator);

    opts.global_options = opts.options_create(null);
    defer opts.options_free(opts.global_options);
    opts.global_s_options = opts.options_create(null);
    defer opts.options_free(opts.global_s_options);
    opts.global_w_options = opts.options_create(null);
    defer opts.options_free(opts.global_w_options);
    opts.options_default_all(opts.global_options, T.OPTIONS_TABLE_SERVER);
    opts.options_default_all(opts.global_s_options, T.OPTIONS_TABLE_SESSION);
    opts.options_default_all(opts.global_w_options, T.OPTIONS_TABLE_WINDOW);

    env_mod.global_environ = env_mod.environ_create();
    defer env_mod.environ_free(env_mod.global_environ);

    const s = sess.session_create(null, "fmt-resolve-orphan-client", "/", env_mod.environ_create(), opts.options_create(opts.global_s_options), null);
    defer if (sess.session_find("fmt-resolve-orphan-client") != null) sess.session_destroy(s, false, "test");

    const w = win.window_create(8, 4, T.DEFAULT_XPIXEL, T.DEFAULT_YPIXEL);
    const wp = win.window_add_pane(w, null, 8, 4);
    w.active = wp;
    var cause: ?[]u8 = null;
    const wl = sess.session_attach(s, w, 0, &cause).?;
    s.curw = wl;

    var client = T.Client{
        .environ = env_mod.environ_create(),
        .tty = undefined,
        .status = .{},
        .session = null,
    };
    defer env_mod.environ_free(client.environ);

    var base = FormatContext{
        .session = s,
        .winlink = wl,
        .window = w,
        .pane = wp,
        .message_text = "base-message",
    };
    defer deinit_context_extras(&base);
    fmt.format_add(&base, "fmtresolve_base_extra", "extra-value");

    const child = fmt_resolve.child_context_for_client(&base, &client, true);
    try std.testing.expectEqual(&client, child.client.?);
    try std.testing.expectEqual(s, child.session.?);
    try std.testing.expectEqual(wl, child.winlink.?);
    try std.testing.expectEqual(w, child.window.?);
    try std.testing.expectEqual(wp, child.pane.?);
    try std.testing.expectEqualStrings("base-message", child.message_text.?);
    try std.testing.expectEqual(base.extras, child.extras);
    try std.testing.expectEqual(true, child.loop_last_flag.?);

    const inherited = format_require_complete(xm.allocator, "#{session_name}|#{message_text}|#{fmtresolve_base_extra}", &child).?;
    defer xm.allocator.free(inherited);
    try std.testing.expectEqualStrings("fmt-resolve-orphan-client|base-message|extra-value", inherited);
}

test "child_context_for_winlink sets window pane and loop_last_flag" {
    sess.session_init_globals(xm.allocator);
    win.window_init_globals(xm.allocator);

    opts.global_s_options = opts.options_create(null);
    defer opts.options_free(opts.global_s_options);
    opts.global_w_options = opts.options_create(null);
    defer opts.options_free(opts.global_w_options);
    opts.options_default_all(opts.global_s_options, T.OPTIONS_TABLE_SESSION);
    opts.options_default_all(opts.global_w_options, T.OPTIONS_TABLE_WINDOW);

    env_mod.global_environ = env_mod.environ_create();
    defer env_mod.environ_free(env_mod.global_environ);

    const s = sess.session_create(null, "fmt-resolve-ch-wl", "/", env_mod.environ_create(), opts.options_create(opts.global_s_options), null);
    defer if (sess.session_find("fmt-resolve-ch-wl") != null) sess.session_destroy(s, false, "test");

    const w = win.window_create(8, 4, T.DEFAULT_XPIXEL, T.DEFAULT_YPIXEL);
    const wp = win.window_add_pane(w, null, 8, 4);
    w.active = wp;
    var cause: ?[]u8 = null;
    const wl = sess.session_attach(s, w, 0, &cause).?;

    const base = FormatContext{};
    const child = fmt_resolve.child_context_for_winlink(&base, s, wl, true);
    try std.testing.expectEqual(s, child.session.?);
    try std.testing.expectEqual(wl, child.winlink.?);
    try std.testing.expectEqual(w, child.window.?);
    try std.testing.expectEqual(wp, child.pane.?);
    try std.testing.expectEqual(true, child.loop_last_flag.?);
    try std.testing.expectEqual(fmt.FormatType.window, child.format_type);
}

test "ctx_session returns null for empty FormatContext" {
    try std.testing.expect(null == fmt_resolve.ctx_session(&FormatContext{}));
}

test "sixel_support returns empty without client and reflects term_features" {
    // Without a client context, sixel_support resolves to empty string (tmux behavior).
    {
        const ctx = FormatContext{};
        const result = format_require_complete(xm.allocator, "#{sixel_support}", &ctx).?;
        defer xm.allocator.free(result);
        try std.testing.expectEqualStrings("", result);
    }

    // With a client that lacks TERM_SIXEL, should return "0".
    {
        var client = T.Client{
            .environ = env_mod.environ_create(),
            .tty = undefined,
            .status = .{},
            .term_features = 0,
        };
        defer env_mod.environ_free(client.environ);
        client.tty = .{ .client = &client };

        const ctx = FormatContext{ .client = &client };
        const result = format_require_complete(xm.allocator, "#{sixel_support}", &ctx).?;
        defer xm.allocator.free(result);
        try std.testing.expectEqualStrings("0", result);
    }

    // With a client that has TERM_SIXEL set, should return "1".
    {
        var client = T.Client{
            .environ = env_mod.environ_create(),
            .tty = undefined,
            .status = .{},
            .term_features = tty_features.TERM_SIXEL,
        };
        defer env_mod.environ_free(client.environ);
        client.tty = .{ .client = &client };

        const ctx = FormatContext{ .client = &client };
        const result = format_require_complete(xm.allocator, "#{sixel_support}", &ctx).?;
        defer xm.allocator.free(result);
        try std.testing.expectEqualStrings("1", result);
    }
}

test "client_written returns empty without client and reflects written field" {
    // Without a client context, client_written resolves to empty string (tmux behavior).
    {
        const ctx = FormatContext{};
        const result = format_require_complete(xm.allocator, "#{client_written}", &ctx).?;
        defer xm.allocator.free(result);
        try std.testing.expectEqualStrings("", result);
    }

    // With a client at default (0 written), should return "0".
    {
        var client = T.Client{
            .environ = env_mod.environ_create(),
            .tty = undefined,
            .status = .{},
        };
        defer env_mod.environ_free(client.environ);
        client.tty = .{ .client = &client };

        const ctx = FormatContext{ .client = &client };
        const result = format_require_complete(xm.allocator, "#{client_written}", &ctx).?;
        defer xm.allocator.free(result);
        try std.testing.expectEqualStrings("0", result);
    }

    // With a client that has written bytes, should return the count.
    {
        var client = T.Client{
            .environ = env_mod.environ_create(),
            .tty = undefined,
            .status = .{},
            .written = 42567,
        };
        defer env_mod.environ_free(client.environ);
        client.tty = .{ .client = &client };

        const ctx = FormatContext{ .client = &client };
        const result = format_require_complete(xm.allocator, "#{client_written}", &ctx).?;
        defer xm.allocator.free(result);
        try std.testing.expectEqualStrings("42567", result);
    }
}

test "server_name format resolves to compat_name" {
    const ctx = FormatContext{};
    const result = format_require_complete(xm.allocator, "#{server_name}", &ctx).?;
    defer xm.allocator.free(result);
    const zmux_mod = @import("zmux.zig");
    try std.testing.expectEqualStrings(zmux_mod.compat_name, result);
}

test "server_name format in compat mode resolves to tmux" {
    const zmux_mod = @import("zmux.zig");
    const saved = zmux_mod.compat_name;
    zmux_mod.compat_name = "tmux";
    defer zmux_mod.compat_name = saved;

    const ctx = FormatContext{};
    const result = format_require_complete(xm.allocator, "#{server_name}", &ctx).?;
    defer xm.allocator.free(result);
    try std.testing.expectEqualStrings("tmux", result);
}
