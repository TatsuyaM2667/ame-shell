// ame-ctl からの操作を受ける Unix ソケット。
// パス: $XDG_RUNTIME_DIR/ame-shell-$WAYLAND_DISPLAY.sock(ネストしたテスト用インスタンスと衝突しないよう
// Wayland ディスプレイ名を含める)。1行1コマンド、応答も1行(複数行の場合あり)で返して切断する。
const std = @import("std");
const c = @import("c.zig");
const App = @import("app.zig").App;
const sys = @import("platform/sys.zig");
const theme = @import("theme.zig");
const cfgmod = @import("config.zig");

pub const socketPath = @import("ipc_path.zig").socketPath;

pub const Server = struct {
    app: *App,
    fd: c_int = -1,
    path: [256]u8 = undefined,

    pub fn init(app: *App) !Server {
        var s = Server{ .app = app };
        const p = socketPath(&s.path) orelse return error.NoRuntimeDir;
        _ = c.unlink(p.ptr); // 前回の残骸
        const fd = c.socket(c.AF_UNIX, c.SOCK_STREAM | c.SOCK_CLOEXEC | c.SOCK_NONBLOCK, 0);
        if (fd < 0) return error.Socket;
        var addr = std.mem.zeroes(c.struct_sockaddr_un);
        addr.sun_family = c.AF_UNIX;
        @memcpy(addr.sun_path[0..p.len], p);
        if (c.bind(fd, @ptrCast(&addr), @sizeOf(c.struct_sockaddr_un)) != 0) return error.Bind;
        _ = c.chmod(p.ptr, 0o600);
        if (c.listen(fd, 8) != 0) return error.Listen;
        s.fd = fd;
        return s;
    }

    /// App のアドレスが確定してから呼ぶ(init は値で返すため)。
    pub fn register(self: *Server) void {
        self.app.loop.add(self.fd, c.EPOLLIN, self, onAccept) catch {};
    }

    fn onAccept(ctx: *anyopaque, fd: c_int, _: u32) void {
        const self: *Server = @ptrCast(@alignCast(ctx));
        while (true) {
            const cl = c.accept4(fd, null, null, c.SOCK_CLOEXEC);
            if (cl < 0) break;
            defer _ = c.close(cl);
            // コマンドは短いので同期で1回読む(クライアントは書いてすぐ待つ)
            var buf: [512]u8 = undefined;
            var tv = c.struct_timeval{ .tv_sec = 1, .tv_usec = 0 };
            _ = c.setsockopt(cl, c.SOL_SOCKET, c.SO_RCVTIMEO, &tv, @sizeOf(c.struct_timeval));
            const n = c.read(cl, &buf, buf.len);
            if (n <= 0) continue;
            var out: [4096]u8 = undefined;
            const reply = handle(self.app, std.mem.trim(u8, buf[0..@intCast(n)], " \n\r\t"), &out);
            _ = c.write(cl, reply.ptr, reply.len);
            _ = c.write(cl, "\n", 1);
        }
    }

    pub fn deinit(self: *Server) void {
        if (self.fd >= 0) {
            _ = c.close(self.fd);
            _ = c.unlink(@ptrCast(&self.path));
        }
    }
};

const help =
    \\commands:
    \\  launcher toggle|open|close
    \\  dashboard toggle|open|close
    \\  volume up|down|mute|<0-100>
    \\  brightness up|down
    \\  osd volume|brightness
    \\  wallpaper aurora|rain|<image path>
    \\  accent <#rrggbb>|reset
    \\  notify <text>          (テスト用の通知)
    \\  notifications toggle|clear
    \\  session | sidebar | utilities   (caelestia: 各ドロワーの開閉)
    \\  close-all
    \\  wallpaper-picker        (全画面の壁紙ピッカー)
    \\  lock
    \\  reload                 (設定の再読込)
    \\  widgets reload
    \\  stats                  (性能統計)
    \\  restart | quit
;

fn handle(app: *App, line: []const u8, out: []u8) []const u8 {
    var it = std.mem.tokenizeScalar(u8, line, ' ');
    const cmd = it.next() orelse return help;
    const arg = it.next() orelse "";
    const rest = std.mem.trim(u8, line[@min(line.len, cmd.len + 1)..], " ");
    const eq = std.mem.eql;

    if (eq(u8, cmd, "launcher")) {
        if (eq(u8, arg, "open")) {
            app.launcher.open();
            const q = std.mem.trim(u8, rest[@min(rest.len, arg.len)..], " ");
            if (q.len > 0) app.launcher.setQuery(q);
        } else if (eq(u8, arg, "close")) app.launcher.close() else app.launcher.toggle();
    } else if (eq(u8, cmd, "dashboard")) {
        if (eq(u8, arg, "open")) app.dashboard.open() else if (eq(u8, arg, "close")) app.dashboard.close() else app.dashboard.toggle();
    } else if (eq(u8, cmd, "session") or eq(u8, cmd, "sidebar") or eq(u8, cmd, "utilities")) {
        const f = app.activeFrame() orelse return "error: caelestia レイアウト(shell { layout caelestia })でのみ使えます";
        if (eq(u8, cmd, "session")) f.toggleSession() else if (eq(u8, cmd, "sidebar")) f.toggleSidebar() else f.toggleUtilities();
    } else if (eq(u8, cmd, "debug-media")) {
        // 試験用(AME_DEBUG が設定されているときだけ): 「アーティスト|曲名|長さ秒|位置秒」で再生中のふりをする
        if (std.posix.getenv("AME_DEBUG") == null) return "error: AME_DEBUG が必要です";
        app.media.debugFake(rest);
    } else if (eq(u8, cmd, "wallpaper-picker")) {
        app.wallpick.toggle();
    } else if (eq(u8, cmd, "close-all")) {
        if (app.activeFrame()) |f| f.closeAll();
        app.launcher.close();
        app.dashboard.close();
    } else if (eq(u8, cmd, "volume")) {
        if (eq(u8, arg, "up")) sys.setVolumeDelta(5) else if (eq(u8, arg, "down")) sys.setVolumeDelta(-5) else if (eq(u8, arg, "mute")) sys.toggleMute() else {
            const v = std.fmt.parseFloat(f32, arg) catch return "error: volume up|down|mute|0-100";
            sys.setVolume(v / 100);
        }
        app.sys.volume = sys.volume();
        app.osd.show(.volume);
        app.redrawBars();
    } else if (eq(u8, cmd, "brightness")) {
        sys.setBrightnessDelta(if (eq(u8, arg, "down")) -5 else 5);
        app.sys.brightness = sys.brightness();
        app.osd.show(.brightness);
    } else if (eq(u8, cmd, "osd")) {
        if (eq(u8, arg, "brightness")) {
            app.sys.brightness = sys.brightness();
            app.osd.show(.brightness);
        } else {
            app.sys.volume = sys.volume();
            app.osd.show(.volume);
        }
    } else if (eq(u8, cmd, "wallpaper")) {
        const mode: cfgmod.WallMode = if (eq(u8, arg, "aurora")) .aurora else if (eq(u8, arg, "rain")) .rain else .image;
        if (arg.len == 0) return "error: wallpaper aurora|rain|<path>";
        for (app.outputs.items) |o| if (o.wall) |w| w.switchTo(mode, rest);
    } else if (eq(u8, cmd, "accent")) {
        if (eq(u8, arg, "reset")) theme.setAccent(app, null) else {
            var s = arg;
            if (s.len > 0 and s[0] == '#') s = s[1..];
            const v = std.fmt.parseInt(u32, s, 16) catch return "error: accent #rrggbb";
            theme.setAccent(app, @import("anim.zig").Color.hex(v));
        }
        app.redrawBars();
        app.dashboard.dataChanged();
    } else if (eq(u8, cmd, "notify")) {
        app.notifs.post("ame-ctl", if (rest.len > 0) rest else "テスト通知", "これは ame-ctl からのテスト通知です。日本語も表示できます 🌧", 0);
    } else if (eq(u8, cmd, "notifications")) {
        if (eq(u8, arg, "clear")) app.notifs.clearAll() else app.notifs.toggleCenter();
    } else if (eq(u8, cmd, "lock")) {
        return app.lock.lock();
    } else if (eq(u8, cmd, "reload")) {
        app.loadConfig(false);
    } else if (eq(u8, cmd, "widgets")) {
        app.dashboard.reloadWidgets();
    } else if (eq(u8, cmd, "stats")) {
        return stats(app, out);
    } else if (eq(u8, cmd, "restart")) {
        app.restart_requested = true;
        app.running = false;
    } else if (eq(u8, cmd, "quit")) {
        app.running = false;
    } else if (eq(u8, cmd, "help")) {
        return help;
    } else {
        return "error: unknown command (try: ame-ctl help)";
    }
    return "ok";
}

fn stats(app: *App, out: []u8) []const u8 {
    var ru: c.struct_rusage = undefined;
    _ = c.getrusage(c.RUSAGE_SELF, &ru);
    const cpu_s = @as(f64, @floatFromInt(ru.ru_utime.tv_sec + ru.ru_stime.tv_sec)) +
        @as(f64, @floatFromInt(ru.ru_utime.tv_usec + ru.ru_stime.tv_usec)) / 1e6;
    var rss_kb: u64 = 0;
    var buf: [2048]u8 = undefined;
    if (sys.readFile("/proc/self/status", &buf)) |s| {
        var lines = std.mem.splitScalar(u8, s, '\n');
        while (lines.next()) |l| {
            if (std.mem.startsWith(u8, l, "VmRSS:")) {
                var t = std.mem.tokenizeAny(u8, l[6..], " \tk");
                rss_kb = std.fmt.parseInt(u64, t.next() orelse "0", 10) catch 0;
            }
        }
    }
    const fs = &app.frame_stats;
    const avg = if (fs.frames > 0) fs.sum_dt / @as(f64, @floatFromInt(fs.frames)) else 0;
    var refresh: f32 = 60;
    if (app.activeOutput()) |o| refresh = @as(f32, @floatFromInt(o.refresh_mhz)) / 1000;
    return std.fmt.bufPrint(out, "uptime_s={d:.1} cpu_time_s={d:.3} rss_mb={d:.1} frames={d} avg_frame_ms={d:.2} max_frame_ms={d:.2} render_avg_us={d} render_max_us={d} refresh_hz={d:.1} startup_ms={d} glyphs={d} glyph_raster_avg_us={d}", .{
        app.timeSec(),
        cpu_s,
        @as(f64, @floatFromInt(rss_kb)) / 1024.0,
        fs.frames,
        avg * 1000,
        fs.max_dt * 1000,
        if (fs.renders > 0) fs.render_us_sum / fs.renders else 0,
        fs.render_us_max,
        refresh,
        app.startup_ms,
        @import("text.zig").raster_n,
        if (@import("text.zig").raster_n > 0) @import("text.zig").raster_ns / @import("text.zig").raster_n / 1000 else 0,
    }) catch "error";
}
