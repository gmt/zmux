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

//! session-test.zig – session lifecycle and side-effect tests.

const std = @import("std");
const T = @import("types.zig");
const xm = @import("xmalloc.zig");
const opts = @import("options.zig");
const sess = @import("session.zig");
const win = @import("window.zig");
const env_mod = @import("environ.zig");
const cmdq = @import("cmd-queue.zig");

// ── Test helpers ─────────────────────────────────────────────────────────

fn init_test_globals() void {
    cmdq.cmdq_reset_for_tests();
    sess.session_init_globals(xm.allocator);
    win.window_init_globals(xm.allocator);

    opts.global_options = opts.options_create(null);
    opts.options_default_all(opts.global_options, T.OPTIONS_TABLE_SERVER);
    opts.global_s_options = opts.options_create(null);
    opts.options_default_all(opts.global_s_options, T.OPTIONS_TABLE_SESSION);
    opts.global_w_options = opts.options_create(null);
    opts.options_default_all(opts.global_w_options, T.OPTIONS_TABLE_WINDOW);

    env_mod.global_environ = env_mod.environ_create();
}

fn deinit_test_globals() void {
    env_mod.environ_free(env_mod.global_environ);
    opts.options_free(opts.global_options);
    opts.options_free(opts.global_s_options);
    opts.options_free(opts.global_w_options);
    cmdq.cmdq_reset_for_tests();
}

// ── Tests ────────────────────────────────────────────────────────────────

test "session_create assigns monotonic IDs and auto-generates prefixed names" {
    init_test_globals();
    defer deinit_test_globals();

    // Explicit name
    const sa = sess.session_create(
        null,
        "explicit-name",
        "/tmp",
        env_mod.environ_create(),
        opts.options_create(opts.global_s_options),
        null,
    );
    defer if (sess.session_find("explicit-name") != null)
        sess.session_destroy(sa, false, "test");

    try std.testing.expectEqualStrings("explicit-name", sa.name);
    try std.testing.expect(sess.session_find("explicit-name") == sa);
    try std.testing.expect(sess.session_find_by_id(sa.id) == sa);

    const id_str = xm.xasprintf("${d}", .{sa.id});
    defer xm.allocator.free(id_str);
    try std.testing.expect(sess.session_find_by_id_str(id_str) == sa);

    // Prefix-generated name
    const sb = sess.session_create(
        "pfx",
        null,
        "/tmp",
        env_mod.environ_create(),
        opts.options_create(opts.global_s_options),
        null,
    );
    defer if (sess.session_find_by_id(sb.id) != null)
        sess.session_destroy(sb, false, "test");

    try std.testing.expect(sb.id > sa.id);
    try std.testing.expect(std.mem.startsWith(u8, sb.name, "pfx-"));

    // No prefix, no name — bare numeric
    const sc = sess.session_create(
        null,
        null,
        "/tmp",
        env_mod.environ_create(),
        opts.options_create(opts.global_s_options),
        null,
    );
    defer if (sess.session_find_by_id(sc.id) != null)
        sess.session_destroy(sc, false, "test");

    try std.testing.expect(sc.id > sb.id);
    // Name should parse as the numeric id
    const parsed = std.fmt.parseUnsigned(u32, sc.name, 10) catch unreachable;
    try std.testing.expectEqual(sc.id, parsed);
}

test "session_destroy detaches windows and cleans up global state" {
    init_test_globals();
    defer deinit_test_globals();

    const s = sess.session_create(
        null,
        "destroy-test",
        "/tmp",
        env_mod.environ_create(),
        opts.options_create(opts.global_s_options),
        null,
    );

    // Attach two windows with panes
    const w1 = win.window_create(80, 24, T.DEFAULT_XPIXEL, T.DEFAULT_YPIXEL);
    const w2 = win.window_create(80, 24, T.DEFAULT_XPIXEL, T.DEFAULT_YPIXEL);
    _ = win.window_add_pane(w1, null, 80, 24);
    _ = win.window_add_pane(w2, null, 80, 24);

    const w1_id = w1.id;
    const w2_id = w2.id;

    var cause: ?[]u8 = null;
    _ = sess.session_attach(s, w1, 0, &cause);
    _ = sess.session_attach(s, w2, 1, &cause);

    // Drain notify queue so window-linked refs are released
    while (cmdq.cmdq_next(null) != 0) {}

    try std.testing.expectEqual(@as(u32, 2), s.windows.count());

    // Destroy — windows should be fully cleaned up once notify refs drain
    sess.session_destroy(s, false, "test");
    while (cmdq.cmdq_next(null) != 0) {}

    try std.testing.expect(sess.session_find("destroy-test") == null);
    try std.testing.expect(win.windows.get(w1_id) == null);
    try std.testing.expect(win.windows.get(w2_id) == null);
}

test "session_destroy with shared window only decrements refcount" {
    init_test_globals();
    defer deinit_test_globals();

    const s1 = sess.session_create(
        null,
        "shared-src",
        "/tmp",
        env_mod.environ_create(),
        opts.options_create(opts.global_s_options),
        null,
    );
    const s2 = sess.session_create(
        null,
        "shared-dst",
        "/tmp",
        env_mod.environ_create(),
        opts.options_create(opts.global_s_options),
        null,
    );
    defer if (sess.session_find("shared-dst") != null)
        sess.session_destroy(s2, false, "test");

    const w = win.window_create(80, 24, T.DEFAULT_XPIXEL, T.DEFAULT_YPIXEL);
    _ = win.window_add_pane(w, null, 80, 24);
    const w_id = w.id;

    var cause: ?[]u8 = null;
    _ = sess.session_attach(s1, w, 0, &cause);
    _ = sess.session_attach(s2, w, 0, &cause);

    // Drain notify queue so window-linked refs are released
    while (cmdq.cmdq_next(null) != 0) {}

    // Window referenced by two sessions
    try std.testing.expectEqual(@as(u32, 2), w.references);

    // Destroy s1 — drain notify so window-unlinked ref is freed too
    sess.session_destroy(s1, false, "test");
    while (cmdq.cmdq_next(null) != 0) {}

    try std.testing.expect(sess.session_find("shared-src") == null);
    try std.testing.expect(win.windows.get(w_id) != null);
    try std.testing.expectEqual(@as(u32, 1), w.references);
}

test "session options inherit from global session defaults" {
    init_test_globals();
    defer deinit_test_globals();

    const session_opts = opts.options_create(opts.global_s_options);
    const s = sess.session_create(
        null,
        "opt-inherit",
        "/tmp",
        env_mod.environ_create(),
        session_opts,
        null,
    );
    defer if (sess.session_find("opt-inherit") != null)
        sess.session_destroy(s, false, "test");

    // Session options should chain to global_s_options
    try std.testing.expectEqual(opts.global_s_options, s.options.parent.?);

    // Reading a default value (e.g. base-index) should fall through to the parent
    const base_idx = opts.options_get_number(s.options, "base-index");
    const global_base = opts.options_get_number(opts.global_s_options, "base-index");
    try std.testing.expectEqual(global_base, base_idx);

    // Override locally — should diverge from parent
    opts.options_set_number(s.options, "base-index", 42);
    try std.testing.expectEqual(@as(i64, 42), opts.options_get_number(s.options, "base-index"));
    try std.testing.expectEqual(global_base, opts.options_get_number(opts.global_s_options, "base-index"));
}

test "session_group is cleaned up when last member is destroyed" {
    init_test_globals();
    defer deinit_test_globals();

    const s1 = sess.session_create(
        null,
        "grp-first",
        "/tmp",
        env_mod.environ_create(),
        opts.options_create(opts.global_s_options),
        null,
    );
    const s2 = sess.session_create(
        null,
        "grp-second",
        "/tmp",
        env_mod.environ_create(),
        opts.options_create(opts.global_s_options),
        null,
    );

    const sg = sess.session_group_new("cleanup-group");
    sess.session_group_add(sg, s1);
    sess.session_group_add(sg, s2);

    try std.testing.expect(sess.session_group_find("cleanup-group") != null);
    try std.testing.expectEqual(@as(u32, 2), sess.session_group_count(sg));
    try std.testing.expect(sess.session_group_contains(s1) != null);

    // Destroy first — group survives with one member
    sess.session_destroy(s1, false, "test");
    const sg_after = sess.session_group_find("cleanup-group");
    try std.testing.expect(sg_after != null);
    try std.testing.expectEqual(@as(u32, 1), sess.session_group_count(sg_after.?));

    // Destroy second — group should be fully removed
    sess.session_destroy(s2, false, "test");
    try std.testing.expect(sess.session_group_find("cleanup-group") == null);
}

test "session_destroy on empty session (no windows) does not crash" {
    init_test_globals();
    defer deinit_test_globals();

    const s = sess.session_create(
        null,
        "empty-destroy",
        "/tmp",
        env_mod.environ_create(),
        opts.options_create(opts.global_s_options),
        null,
    );

    try std.testing.expectEqual(@as(u32, 0), s.windows.count());

    // Destroy with notification — should not panic
    sess.session_destroy(s, true, "test");
    try std.testing.expect(sess.session_find("empty-destroy") == null);
}
