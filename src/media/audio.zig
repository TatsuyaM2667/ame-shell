// 音の出力先・入力先の一覧と切り替え(ame-uzume list / use。PipeWire の pipewire-pulse に libpulse で話す)。
//
// 一覧の取得・切り替えは別スレッドで行い(数十 ms かかることがある)、終わったら pipe でメインループへ知らせる。
// 切り替えたときは、再生中・録音中のストリームも新しい機器へ移す。
const std = @import("std");

const App = @import("../core/app.zig").App;
const c = @import("../c.zig");
const sys = @import("../platform/sys.zig");

pub const MAX = 10;

pub const Dev = struct {
    name: [128]u8 = undefined,
    name_len: usize = 0,
    label: [96]u8 = undefined,
    label_len: usize = 0,
    bluetooth: bool = false,

    pub fn nameStr(self: *const Dev) []const u8 {
        return self.name[0..self.name_len];
    }
    pub fn labelStr(self: *const Dev) []const u8 {
        return self.label[0..self.label_len];
    }
};

pub const Kind = enum { sink, source };

const List = struct {
    devs: [MAX]Dev = undefined,
    n: usize = 0,
    default: [128]u8 = undefined,
    default_len: usize = 0,

    pub fn isDefault(self: *const List, i: usize) bool {
        return std.mem.eql(u8, self.devs[i].nameStr(), self.default[0..self.default_len]);
    }
};

pub const Audio = struct {
    app: *App,
    mutex: std.Thread.Mutex = .{},
    /// 描画側が読む(メインスレッドのみ)
    sinks: List = .{},
    sources: List = .{},
    /// スレッドが書く
    new_sinks: List = .{},
    new_sources: List = .{},
    fresh: bool = false,
    /// ame-uzume(と音の口 pipewire-pulse)が無い環境では一覧を出せない
    unavailable: bool = false,
    busy: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    pipe_r: c_int,
    pipe_w: c_int,
    /// 切り替え要求(スレッドへ渡す)
    want_kind: Kind = .sink,
    want_name: [128]u8 = undefined,
    want_len: usize = 0,

    pub fn create(app: *App) !*Audio {
        const self = try app.alloc.create(Audio);
        var fds: [2]c_int = undefined;
        if (c.pipe2(&fds, c.O_CLOEXEC | c.O_NONBLOCK) != 0) return error.Pipe;
        self.* = .{ .app = app, .pipe_r = fds[0], .pipe_w = fds[1] };
        try app.loop.add(fds[0], c.EPOLLIN, self, onReady);
        return self;
    }

    /// 一覧を読み直す(表示する直前に呼ぶ)
    pub fn refresh(self: *Audio) void {
        self.unavailable = !sys.hasCommand("ame-uzume");
        if (self.unavailable) return;
        self.start(false);
    }

    /// 既定の出力先/入力先を切り替える
    pub fn select(self: *Audio, kind: Kind, i: usize) void {
        const l = if (kind == .sink) &self.sinks else &self.sources;
        if (i >= l.n) return;
        const nm = l.devs[i].nameStr();
        // 押した瞬間に表示を切り替える(実際の切り替えは裏で)
        @memcpy(l.default[0..nm.len], nm);
        l.default_len = nm.len;
        self.want_kind = kind;
        @memcpy(self.want_name[0..nm.len], nm);
        self.want_len = nm.len;
        self.start(true);
    }

    fn start(self: *Audio, apply: bool) void {
        if (self.busy.swap(true, .acq_rel)) return;
        const t = std.Thread.spawn(.{}, work, .{ self, apply }) catch {
            self.busy.store(false, .release);
            return;
        };
        t.detach();
    }

    fn work(self: *Audio, apply: bool) void {
        if (apply) {
            var nz: [130]u8 = undefined;
            const name = std.fmt.bufPrintZ(&nz, "{s}", .{self.want_name[0..self.want_len]}) catch "";
            var out: [64]u8 = undefined;
            // 既定にし、流れている音(録っている音)もそこへ移す
            _ = sys.run(&.{ "ame-uzume", "use", if (self.want_kind == .sink) "sink" else "source", name.ptr }, &out);
        }
        var sk: List = .{};
        var sr: List = .{};
        readList("sinks", &sk);
        readList("sources", &sr);
        self.mutex.lock();
        self.new_sinks = sk;
        self.new_sources = sr;
        self.fresh = true;
        self.mutex.unlock();
        self.busy.store(false, .release);
        _ = c.write(self.pipe_w, "a", 1);
    }

    fn onReady(ctx: *anyopaque, fd: c_int, _: u32) void {
        const self: *Audio = @ptrCast(@alignCast(ctx));
        var drain: [16]u8 = undefined;
        while (c.read(fd, &drain, drain.len) > 0) {}
        self.mutex.lock();
        if (self.fresh) {
            self.sinks = self.new_sinks;
            self.sources = self.new_sources;
            self.fresh = false;
        }
        self.mutex.unlock();
        // 出力先が変わると音量も変わる
        self.app.sys.volume = sys.volume();
        self.app.redrawBars();
        if (self.app.activeFrame()) |f| f.schedule();
    }

    pub fn list(self: *Audio, kind: Kind) *const List {
        return if (kind == .sink) &self.sinks else &self.sources;
    }
};

/// `ame-uzume list sinks|sources` の行(名前<TAB>説明<TAB>既定なら *)を読む(モニターは向こうで除いてある)
fn readList(what: [:0]const u8, l: *List) void {
    var buf: [16384]u8 = undefined;
    const s = sys.run(&.{ "ame-uzume", "list", what.ptr }, &buf) orelse return;
    parseList(s, l);
}

fn parseList(s: []const u8, l: *List) void {
    var lines = std.mem.splitScalar(u8, s, '\n');
    while (lines.next()) |line| {
        if (line.len == 0 or l.n >= MAX) continue;
        var f = std.mem.splitScalar(u8, line, '\t');
        const nm = f.next() orelse continue;
        const desc = f.next() orelse "";
        const mark = f.next() orelse "";
        if (nm.len == 0) continue;
        const d = &l.devs[l.n];
        d.* = .{};
        d.name_len = @min(nm.len, d.name.len);
        @memcpy(d.name[0..d.name_len], nm[0..d.name_len]);
        d.bluetooth = std.mem.startsWith(u8, nm, "bluez_");
        setLabel(d, desc);
        l.n += 1;
        if (std.mem.eql(u8, mark, "*")) {
            l.default_len = @min(nm.len, l.default.len);
            @memcpy(l.default[0..l.default_len], nm[0..l.default_len]);
        }
    }
}

test "出力先の一覧の行" {
    var l: List = .{};
    parseList("alsa_output.a\tFamily HD Audio Analog Stereo\t\nbluez_output.b\tAirPods\t*\n", &l);
    try std.testing.expectEqual(@as(usize, 2), l.n);
    try std.testing.expect(l.devs[1].bluetooth);
    try std.testing.expectEqualStrings("bluez_output.b", l.default[0..l.default_len]);
}

/// 分かりにくい ALSA の名前("Family 17h/19h/1ah HD Audio Controller Analog Stereo")を言い換える
fn setLabel(d: *Dev, desc: []const u8) void {
    const nm = d.nameStr();
    const has = struct {
        fn f(h: []const u8, n: []const u8) bool {
            return std.ascii.indexOfIgnoreCase(h, n) != null;
        }
    }.f;
    const pretty: []const u8 = if (d.bluetooth)
        desc
    else if (has(nm, "hdmi") or has(desc, "hdmi") or has(desc, "displayport"))
        "HDMI / DisplayPort"
    else if (std.mem.startsWith(u8, nm, "alsa_output") and has(nm, "analog"))
        "内蔵スピーカー / イヤホン端子"
    else if (std.mem.startsWith(u8, nm, "alsa_input") and has(nm, "analog"))
        "内蔵マイク / マイク端子"
    else if (has(nm, "usb"))
        desc
    else
        desc;
    var n = @min(pretty.len, d.label.len);
    while (n > 0 and n < pretty.len and (pretty[n] & 0xC0) == 0x80) n -= 1;
    @memcpy(d.label[0..n], pretty[0..n]);
    d.label_len = n;
}
