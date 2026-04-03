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

//! popup-menu-test.zig – focused tests for popup.zig and menu.zig helpers.

const std = @import("std");
const T = @import("types.zig");
const env_mod = @import("environ.zig");
const menu = @import("menu.zig");
const popup = @import("popup.zig");

test "popup overlay flags read only popup_data" {
    var cl: T.Client = undefined;
    cl.popup_data = null;
    cl.menu_data = null;

    try std.testing.expect(!popup.overlay_active(&cl));
    try std.testing.expect(!popup.popup_present(&cl));
    try std.testing.expect(popup.popup_data(&cl) == null);
}

test "menu overlay_active reads menu_data independently of popup_data" {
    var cl: T.Client = undefined;
    cl.popup_data = null;
    cl.menu_data = null;

    try std.testing.expect(!menu.overlay_active(&cl));
    try std.testing.expect(menu.overlay_bounds(&cl) == null);
    try std.testing.expect(!menu.overlay_wants_mouse(&cl));
}

test "menu_create allocates titled menu with empty item list" {
    const m = menu.menu_create("Pick one");
    defer m.deinit();

    try std.testing.expectEqualStrings("Pick one", m.title);
    try std.testing.expectEqual(@as(usize, 0), m.items.len);
}

test "popup_modify ignores clients without an active popup" {
    var cl: T.Client = undefined;
    cl.popup_data = null;

    popup.popup_modify(&cl, "x", null, null, null, null);
    try std.testing.expect(cl.popup_data == null);
}

test "menu_add_item adds label and skips duplicate separators" {
    const env = env_mod.environ_create();
    defer env_mod.environ_free(env);

    var cl: T.Client = undefined;
    cl = .{
        .environ = env,
        .tty = .{ .client = undefined, .sx = 120, .sy = 40 },
        .status = .{},
        .flags = T.CLIENT_CONTROL,
        .session = null,
    };
    cl.tty.client = &cl;

    const m = menu.menu_create("M");
    defer m.deinit();

    menu.menu_add_item(m, .{ .name = "Plain" }, null, &cl, null);
    try std.testing.expectEqual(@as(usize, 1), m.items.len);
    try std.testing.expect(!m.items[0].separator);

    menu.menu_add_item(m, .{ .name = "" }, null, &cl, null);
    try std.testing.expectEqual(@as(usize, 2), m.items.len);
    try std.testing.expect(m.items[1].separator);

    menu.menu_add_item(m, .{ .name = "" }, null, &cl, null);
    try std.testing.expectEqual(@as(usize, 2), m.items.len);
}

test "menu_prepare clamps position and menu_prepare fails when terminal too small" {
    const env = env_mod.environ_create();
    defer env_mod.environ_free(env);

    var cl: T.Client = undefined;
    cl = .{
        .environ = env,
        .tty = .{ .client = undefined, .sx = 120, .sy = 40 },
        .status = .{},
        .flags = T.CLIENT_CONTROL,
        .session = null,
        .menu_data = null,
    };
    cl.tty.client = &cl;

    const m = menu.menu_create("Title");
    menu.menu_add_item(m, .{ .name = "One" }, null, &cl, null);
    menu.menu_add_item(m, .{ .name = "Two" }, null, &cl, null);

    const md = menu.menu_prepare(m, 0, 0, null, 200, 200, &cl, 1, null, null, null, null, null, null) orelse return error.TestUnexpectedResult;
    cl.menu_data = @ptrCast(md);
    const w = md.menu.width + 4;
    const h: u32 = @intCast(md.menu.items.len + 2);
    try std.testing.expect(md.px + w <= cl.tty.sx);
    try std.testing.expect(md.py + h <= cl.tty.sy);
    menu.clear_overlay(&cl);

    var tiny: T.Client = undefined;
    tiny = .{
        .environ = env,
        .tty = .{ .client = undefined, .sx = 4, .sy = 4 },
        .status = .{},
        .flags = T.CLIENT_CONTROL,
        .session = null,
    };
    tiny.tty.client = &tiny;

    const m2 = menu.menu_create("X");
    defer m2.deinit();
    menu.menu_add_item(m2, .{ .name = "A" }, null, &tiny, null);
    try std.testing.expect(menu.menu_prepare(m2, 0, 0, null, 0, 0, &tiny, 1, null, null, null, null, null, null) == null);
}

test "menu_resize_cb keeps menu inside tty after resize" {
    const env = env_mod.environ_create();
    defer env_mod.environ_free(env);

    var cl: T.Client = undefined;
    cl = .{
        .environ = env,
        .tty = .{ .client = undefined, .sx = 100, .sy = 30 },
        .status = .{},
        .flags = T.CLIENT_CONTROL,
        .session = null,
        .menu_data = null,
    };
    cl.tty.client = &cl;

    const m = menu.menu_create("R");
    menu.menu_add_item(m, .{ .name = "x" }, null, &cl, null);

    const md = menu.menu_prepare(m, 0, 0, null, 80, 20, &cl, 1, null, null, null, null, null, null) orelse return error.TestUnexpectedResult;
    cl.menu_data = @ptrCast(md);
    cl.tty.sx = 40;
    cl.tty.sy = 15;
    menu.menu_resize_cb(&cl);
    const w = md.menu.width + 4;
    const h: u32 = @intCast(md.menu.items.len + 2);
    try std.testing.expect(md.px + w <= cl.tty.sx);
    try std.testing.expect(md.py + h <= cl.tty.sy);

    menu.clear_overlay(&cl);
    try std.testing.expect(cl.menu_data == null);
}

test "popup_display succeeds then clear_overlay frees popup" {
    const env = env_mod.environ_create();
    defer env_mod.environ_free(env);

    var cl: T.Client = undefined;
    cl = .{
        .environ = env,
        .tty = .{ .client = undefined, .sx = 120, .sy = 40 },
        .status = .{},
        .flags = T.CLIENT_CONTROL,
        .session = null,
        .popup_data = null,
        .references = 1,
    };
    cl.tty.client = &cl;

    try std.testing.expectEqual(@as(i32, 0), popup.popup_display(0, 1, null, 2, 2, 40, 10, "Hi", &cl, null, null, null, "body"));
    try std.testing.expect(popup.overlay_active(&cl));

    popup.clear_overlay(&cl);
    try std.testing.expect(!popup.overlay_active(&cl));
    try std.testing.expect(cl.popup_data == null);
}

test "menu_add_item accepts utf8 label text" {
    const env = env_mod.environ_create();
    defer env_mod.environ_free(env);

    var cl: T.Client = undefined;
    cl = .{
        .environ = env,
        .tty = .{ .client = undefined, .sx = 120, .sy = 40 },
        .status = .{},
        .flags = T.CLIENT_CONTROL,
        .session = null,
    };
    cl.tty.client = &cl;

    const m = menu.menu_create("UTF8");
    defer m.deinit();

    menu.menu_add_item(m, .{ .name = "日本語" }, null, &cl, null);
    try std.testing.expectEqual(@as(usize, 1), m.items.len);
    try std.testing.expectEqualStrings("日本語", m.items[0].display_text.?);
}

test "popup_clear_overlay is safe without popup" {
    const env = env_mod.environ_create();
    defer env_mod.environ_free(env);

    var cl: T.Client = undefined;
    cl = .{
        .environ = env,
        .tty = .{ .client = undefined, .sx = 80, .sy = 24 },
        .status = .{},
        .flags = T.CLIENT_CONTROL,
        .session = null,
        .popup_data = null,
    };
    cl.tty.client = &cl;

    popup.clear_overlay(&cl);
}
