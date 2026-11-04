// ハンドのポーズの割り当て: 手のポーズ(伸びている指の組み合わせ)、または両手のポーズの組み合わせを、
// アプリの起動や操作に割り当てる。設定画面(posegui.zig)で編集し、$XDG_CONFIG_HOME/ame-shell/hand-poses に保存する。
//
// ポーズは「伸びている指」の 5 ビット(0 = 親指・1 = 人差し指・2 = 中指・3 = 薬指・4 = 小指)。
// 片手のポーズは、もう一方の手が映っていないときだけ。両手のポーズは、左右どちらの手がどちらでもよい。
// ポーズを 0.7 秒ほど止めると動く(hand.zig)。割り当てた片手のポーズは、元からある動き(パー = メニュー、
// 握りこぶし = 閉じる、本数 = ワークスペース)より先に使う。指さし(人差し指だけ)はカーソルなので割り当てられない。
//
// ファイルの 1 行: <手 1> <手 2 か .> <種類> <引数>
//   手は指の文字の並び(t 親指 / i 人差し指 / m 中指 / r 薬指 / p 小指)、握りこぶしは 0
//   自分のポーズ(custom.zig で登録した形)は c:名前
//   例: ip . app firefox.desktop      … 人差し指と小指(キツネ)で Firefox
//       tp tp action screenshot        … 両手で電話の形でスクリーンショット
//       0 0 command ame-ctl lock       … 両手の握りこぶしでコマンド
const std = @import("std");
const App = @import("../app.zig").App;
const custom = @import("custom.zig");

pub const NONE: u8 = 0xff;
pub const MAX = 32;

pub const THUMB: u8 = 1;
pub const INDEX: u8 = 2;
pub const MIDDLE: u8 = 4;
pub const RING: u8 = 8;
pub const PINKY: u8 = 16;
/// カーソル(指さし)。割り当てられない
pub const POINT: u8 = INDEX;

/// 設定画面に並べるポーズ(名前つき)
pub const Named = struct { mask: u8, name: []const u8 };
pub const presets = [_]Named{
    .{ .mask = 0, .name = "握りこぶし" },
    .{ .mask = THUMB | INDEX | MIDDLE | RING | PINKY, .name = "パー" },
    .{ .mask = THUMB, .name = "いいね" },
    .{ .mask = INDEX | MIDDLE, .name = "ピース" },
    .{ .mask = INDEX | MIDDLE | RING, .name = "3 本" },
    .{ .mask = INDEX | MIDDLE | RING | PINKY, .name = "4 本" },
    .{ .mask = INDEX | PINKY, .name = "キツネ" },
    .{ .mask = THUMB | INDEX | PINKY, .name = "アイラブユー" },
    .{ .mask = THUMB | PINKY, .name = "電話" },
    .{ .mask = THUMB | INDEX, .name = "L の字" },
    .{ .mask = PINKY, .name = "小指" },
    .{ .mask = THUMB | INDEX | MIDDLE, .name = "親指と 2 本" },
};

/// 自分のポーズ(custom.zig)か
pub fn isCustom(id: u8) bool {
    return id != NONE and id >= custom.BASE and id < custom.BASE + custom.MAX;
}

pub fn poseName(mask: u8) []const u8 {
    if (isCustom(mask)) {
        const ps = custom.poses();
        const i = mask - custom.BASE;
        return if (i < ps.len) ps[i].nameStr() else "(消したポーズ)";
    }
    for (presets) |p| if (p.mask == mask) return p.name;
    if (mask == POINT) return "指さし";
    return "そのほか";
}

/// 元からある動き(割り当てなければこれが動く)
pub fn builtinOf(mask: u8) ?[]const u8 {
    return switch (mask) {
        0 => "窓を閉じる",
        THUMB | INDEX | MIDDLE | RING | PINKY => "手のメニュー",
        THUMB => "ワークスペース 1",
        INDEX | MIDDLE => "ワークスペース 2・上下に動かすとスクロール",
        INDEX | MIDDLE | RING => "ワークスペース 3",
        INDEX | MIDDLE | RING | PINKY => "ワークスペース 4",
        else => null,
    };
}

pub const Kind = enum(u8) { action, app, command };

/// 割り当てられる操作
pub const Op = enum(u8) {
    launcher,
    dashboard,
    menu,
    screenshot,
    close,
    fullscreen,
    float,
    lock,
    play_pause,
    next,
    prev,
    vol_up,
    vol_down,
    mute,
    ws1,
    ws2,
    ws3,
    ws4,
    ws5,
    ws6,
    ws7,
    ws8,
    ws9,

    pub fn label(o: Op) []const u8 {
        return switch (o) {
            .launcher => "ランチャー",
            .dashboard => "ダッシュボード",
            .menu => "手のメニュー",
            .screenshot => "スクリーンショット",
            .close => "窓を閉じる",
            .fullscreen => "全画面",
            .float => "窓を浮かせる",
            .lock => "画面をロック",
            .play_pause => "再生 / 一時停止",
            .next => "次の曲",
            .prev => "前の曲",
            .vol_up => "音量を上げる",
            .vol_down => "音量を下げる",
            .mute => "消音",
            .ws1 => "ワークスペース 1",
            .ws2 => "ワークスペース 2",
            .ws3 => "ワークスペース 3",
            .ws4 => "ワークスペース 4",
            .ws5 => "ワークスペース 5",
            .ws6 => "ワークスペース 6",
            .ws7 => "ワークスペース 7",
            .ws8 => "ワークスペース 8",
            .ws9 => "ワークスペース 9",
        };
    }
};

pub const Binding = struct {
    a: u8,
    /// もう一方の手(NONE = 片手のポーズ)
    b: u8 = NONE,
    kind: Kind = .action,
    op: Op = .launcher,
    /// app: .desktop の名前 / command: コマンド
    arg: [200]u8 = undefined,
    arg_len: usize = 0,

    pub fn argStr(self: *const Binding) []const u8 {
        return self.arg[0..self.arg_len];
    }

    pub fn setArg(self: *Binding, s: []const u8) void {
        self.arg_len = @min(s.len, self.arg.len);
        @memcpy(self.arg[0..self.arg_len], s[0..self.arg_len]);
    }

    /// 同じポーズか(両手は左右を問わない)
    pub fn samePose(self: *const Binding, a: u8, b: u8) bool {
        return (self.a == a and self.b == b) or (self.b != NONE and self.a == b and self.b == a);
    }
};

pub var list: [MAX]Binding = undefined;
pub var n: usize = 0;
var loaded = false;

pub fn bindings() []Binding {
    ensureLoaded();
    return list[0..n];
}

/// 今の手のポーズに割り当てがあれば返す(b = もう一方の手、無ければ NONE)
pub fn find(a: u8, b: u8) ?*const Binding {
    ensureLoaded();
    for (list[0..n]) |*x| if (x.samePose(a, b)) return x;
    return null;
}

/// アプリの起動の割り当てだけ(ハンド操作が「アプリ起動だけ」のとき)
pub fn findApp(a: u8, b: u8) ?*const Binding {
    const x = find(a, b) orelse return null;
    return if (x.kind == .app) x else null;
}

pub fn add(bn: Binding) bool {
    ensureLoaded();
    if (bn.a == POINT and bn.b == NONE) return false;
    // 同じポーズは置き換える
    for (list[0..n]) |*x| if (x.samePose(bn.a, bn.b)) {
        x.* = bn;
        save();
        return true;
    };
    if (n >= MAX) return false;
    list[n] = bn;
    n += 1;
    save();
    return true;
}

pub fn remove(i: usize) void {
    if (i >= n) return;
    std.mem.copyForwards(Binding, list[i .. n - 1], list[i + 1 .. n]);
    n -= 1;
    save();
}

// ---- 文字 ⇔ ポーズ ----

const letters = "timrp";

pub fn maskToStr(mask: u8, buf: []u8) []const u8 {
    // 自分のポーズは "c:名前"
    if (isCustom(mask)) return std.fmt.bufPrint(buf, "c:{s}", .{poseName(mask)}) catch "?";
    if (mask == NONE) return ".";
    if (mask == 0) return "0";
    var k: usize = 0;
    for (letters, 0..) |ch, i| if (mask & (@as(u8, 1) << @intCast(i)) != 0) {
        buf[k] = ch;
        k += 1;
    };
    return buf[0..k];
}

pub fn strToMask(s: []const u8) ?u8 {
    if (std.mem.startsWith(u8, s, "c:")) {
        const i = custom.find(s[2..]) orelse return null;
        return custom.BASE + @as(u8, @intCast(i));
    }
    if (std.mem.eql(u8, s, ".")) return NONE;
    if (std.mem.eql(u8, s, "0")) return 0;
    var m: u8 = 0;
    for (s) |ch| {
        const i = std.mem.indexOfScalar(u8, letters, ch) orelse return null;
        m |= @as(u8, 1) << @intCast(i);
    }
    return if (m == 0) null else m;
}

/// 1 行を読む(空行・# の行は null)
pub fn parseLine(line: []const u8) ?Binding {
    const t = std.mem.trim(u8, line, " \t\r");
    if (t.len == 0 or t[0] == '#') return null;
    var it = std.mem.tokenizeAny(u8, t, " \t");
    const a = strToMask(it.next() orelse return null) orelse return null;
    const b = strToMask(it.next() orelse return null) orelse return null;
    if (a == NONE) return null;
    const kind_s = it.next() orelse return null;
    const rest = std.mem.trim(u8, it.rest(), " \t");
    var bn = Binding{ .a = a, .b = b };
    if (std.mem.eql(u8, kind_s, "action")) {
        bn.kind = .action;
        bn.op = std.meta.stringToEnum(Op, rest) orelse return null;
    } else if (std.mem.eql(u8, kind_s, "app")) {
        if (rest.len == 0) return null;
        bn.kind = .app;
        bn.setArg(rest);
    } else if (std.mem.eql(u8, kind_s, "command")) {
        if (rest.len == 0) return null;
        bn.kind = .command;
        bn.setArg(rest);
    } else return null;
    return bn;
}

pub fn formatLine(bn: *const Binding, w: anytype) !void {
    var b1: [64]u8 = undefined;
    var b2: [64]u8 = undefined;
    try w.print("{s} {s} ", .{ maskToStr(bn.a, &b1), maskToStr(bn.b, &b2) });
    switch (bn.kind) {
        .action => try w.print("action {s}\n", .{@tagName(bn.op)}),
        .app => try w.print("app {s}\n", .{bn.argStr()}),
        .command => try w.print("command {s}\n", .{bn.argStr()}),
    }
}

// ---- ファイル ----

fn path(buf: []u8) ?[]const u8 {
    if (std.posix.getenv("XDG_CONFIG_HOME")) |d| if (d.len > 0) return std.fmt.bufPrint(buf, "{s}/ame-shell/hand-poses", .{d}) catch null;
    const home = std.posix.getenv("HOME") orelse return null;
    return std.fmt.bufPrint(buf, "{s}/.config/ame-shell/hand-poses", .{home}) catch null;
}

fn ensureLoaded() void {
    if (loaded) return;
    loaded = true;
    reload();
}

pub fn reload() void {
    n = 0;
    var pb: [512]u8 = undefined;
    const p = path(&pb) orelse return;
    var buf: [16 << 10]u8 = undefined;
    const data = std.fs.cwd().readFile(p, &buf) catch return;
    var it = std.mem.splitScalar(u8, data, '\n');
    while (it.next()) |line| {
        if (n >= MAX) break;
        if (parseLine(line)) |bn| {
            list[n] = bn;
            n += 1;
        }
    }
}

fn save() void {
    var pb: [512]u8 = undefined;
    const p = path(&pb) orelse return;
    if (std.fs.path.dirname(p)) |d| std.fs.cwd().makePath(d) catch {};
    var buf: [16 << 10]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const w = fbs.writer();
    w.writeAll("# ハンドのポーズの割り当て(ame-shell の設定画面が書きます。手で直してもよい)\n# <手 1> <手 2 か .> action|app|command <引数>   指: t 親指 i 人差し指 m 中指 r 薬指 p 小指、0 = 握りこぶし\n") catch return;
    for (list[0..n]) |*bn| formatLine(bn, w) catch return;
    std.fs.cwd().writeFile(.{ .sub_path = p, .data = fbs.getWritten() }) catch {};
}

// ---- 動かす ----

pub fn run(app: *App, bn: *const Binding) void {
    switch (bn.kind) {
        .app => _ = app.launcher.launchById(bn.argStr()),
        .command => {
            var b: [256]u8 = undefined;
            const z = std.fmt.bufPrintZ(&b, "{s}", .{bn.argStr()}) catch return;
            app.spawn(z);
        },
        .action => {
            const ipc = @import("../ipc.zig");
            const hand = @import("hand.zig");
            switch (bn.op) {
                .launcher => app.launcher.toggle(),
                .dashboard => ipc.runCommand(app, "dashboard toggle"),
                .menu => hand.openMenuPublic(app),
                .screenshot => ipc.runCommand(app, "screenshot full"),
                .close => ipc.runCommand(app, "window close"),
                .fullscreen => ipc.runCommand(app, "window fullscreen"),
                .float => ipc.runCommand(app, "window float"),
                .lock => _ = app.lock.lock(),
                .play_pause => app.media.toggle(),
                .next => app.media.next(),
                .prev => app.media.prev(),
                .vol_up => ipc.runCommand(app, "volume up"),
                .vol_down => ipc.runCommand(app, "volume down"),
                .mute => ipc.runCommand(app, "volume mute"),
                .ws1, .ws2, .ws3, .ws4, .ws5, .ws6, .ws7, .ws8, .ws9 => {
                    const k: u5 = @intCast(@intFromEnum(bn.op) - @intFromEnum(Op.ws1));
                    app.focusTags(@as(u32, 1) << k);
                },
            }
        },
    }
}

/// 割り当ての説明(設定画面・バナー用)
pub fn describe(app: *App, bn: *const Binding, buf: []u8) []const u8 {
    return switch (bn.kind) {
        .action => bn.op.label(),
        .app => blk: {
            for (app.launcher.appEntries()) |*e| if (std.mem.eql(u8, e.id, bn.argStr())) break :blk (std.fmt.bufPrint(buf, "{s} を起動", .{e.display()}) catch e.display());
            break :blk std.fmt.bufPrint(buf, "{s} を起動", .{bn.argStr()}) catch bn.argStr();
        },
        .command => std.fmt.bufPrint(buf, "コマンド: {s}", .{bn.argStr()}) catch bn.argStr(),
    };
}

test "ポーズの文字と行の読み書き" {
    var b: [8]u8 = undefined;
    try std.testing.expectEqualStrings("ip", maskToStr(INDEX | PINKY, &b));
    try std.testing.expectEqual(@as(u8, THUMB | PINKY), strToMask("tp").?);
    try std.testing.expectEqual(@as(u8, 0), strToMask("0").?);
    try std.testing.expectEqual(NONE, strToMask(".").?);
    try std.testing.expect(strToMask("x") == null);

    const x = parseLine("ip . app firefox.desktop").?;
    try std.testing.expectEqual(@as(u8, INDEX | PINKY), x.a);
    try std.testing.expectEqual(NONE, x.b);
    try std.testing.expectEqual(Kind.app, x.kind);
    try std.testing.expectEqualStrings("firefox.desktop", x.argStr());
    const y = parseLine("tp 0 action screenshot").?;
    try std.testing.expectEqual(Op.screenshot, y.op);
    // 両手は左右を問わない
    try std.testing.expect(y.samePose(0, THUMB | PINKY));
    try std.testing.expect(!y.samePose(THUMB | PINKY, NONE));
    try std.testing.expect(parseLine("# コメント") == null);
    try std.testing.expect(parseLine("ip . action nope") == null);

    var out: [128]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&out);
    try formatLine(&y, fbs.writer());
    try std.testing.expectEqualStrings("tp 0 action screenshot\n", fbs.getWritten());
}
