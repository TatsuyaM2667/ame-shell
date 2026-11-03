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
        // sun_path(Linux 108 / FreeBSD 104 バイト)に入らない長さの XDG_RUNTIME_DIR では作れない(落ちずに ame-ctl を無効にする)
        const addr = @import("ipc_path.zig").unixAddr(p) orelse return error.PathTooLong;
        // socket / bind / listen は std.posix で(glibc の transparent union の sockaddr を避ける。ipc_path.zig)
        const fd = std.posix.socket(std.posix.AF.UNIX, std.posix.SOCK.STREAM | std.posix.SOCK.CLOEXEC | std.posix.SOCK.NONBLOCK, 0) catch return error.Socket;
        errdefer std.posix.close(fd);
        std.posix.bind(fd, @ptrCast(&addr), @sizeOf(std.posix.sockaddr.un)) catch return error.Bind;
        _ = c.chmod(p.ptr, 0o600);
        std.posix.listen(fd, 8) catch return error.Listen;
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
            const cl = std.posix.accept(fd, null, null, std.posix.SOCK.CLOEXEC) catch break;
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
    \\  dashboard toggle|open|close|dashboard|media|performance|workspaces
    \\  volume up|down|mute|<0-100>
    \\  brightness up|down
    \\  osd volume|brightness
    \\  wallpaper aurora|rain|<画像・GIF・動画のパス>
    \\  accent <#rrggbb>|reset
    \\  notify <text>          (テスト用の通知)
    \\  notifications toggle|clear
    \\  session | sidebar | utilities   (caelestia: 各ドロワーの開閉)
    \\  close-all
    \\  network | bluetooth     (Wi-Fi / Bluetooth の設定パネル)
    \\  wallpaper-picker        (全画面の壁紙ピッカー)
    \\  workspace <1-9>        (ワークスペース切替)
    \\  window close|fullscreen|float|focus-next|focus-prev|swap-next|swap-prev
    \\  screenshot region|full|clip   (範囲 / 全体を ~/Pictures/Screenshots に保存してコピー / 全体をコピーだけ)
    \\  avatar pick           (ユーザーの写真をファイル選択の画面から選ぶ)
    \\  media play-pause|next|previous   (再生中の曲の操作)
    \\  net wifi|saved|radio|ssid|bt|bt-devices   (Wi-Fi・Bluetooth の状態。NetworkManager / BlueZ に D-Bus で聞く)
    \\  hand on|off|toggle|status   (ハンド操作: カメラで手の動きを見てカーソル・窓を操作する)
    \\  face enroll|clear|status     (顔認証: 顔を登録・消す。登録するとロック画面で顔を見てロックを外す)
    \\  lock
    \\  reload                 (設定の再読込)
    \\  widgets reload
    \\  stats                  (性能統計)
    \\  restart | quit
;

/// ame-shell 内部(WM のキーバインド等)から ame-ctl のコマンドを実行する
pub fn runCommand(app: *App, line: []const u8) void {
    var buf: [512]u8 = undefined;
    _ = handle(app, line, &buf);
}

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
        // caelestia: dashboard dashboard|media|performance|workspaces で、そのタブを開く
        const tabs = [_][]const u8{ "dashboard", "media", "performance", "workspaces" };
        if (app.activeFrame()) |f| for (tabs, 0..) |t, i| if (eq(u8, arg, t)) {
            f.openDashTab(i);
            return "ok";
        };
        if (eq(u8, arg, "open")) app.dashboard.open() else if (eq(u8, arg, "close")) app.dashboard.close() else app.dashboard.toggle();
    } else if (eq(u8, cmd, "session") or eq(u8, cmd, "sidebar") or eq(u8, cmd, "utilities")) {
        const f = app.activeFrame() orelse return "error: caelestia レイアウト(shell { layout caelestia })でのみ使えます";
        if (eq(u8, cmd, "session")) f.toggleSession() else if (eq(u8, cmd, "sidebar")) f.toggleSidebar() else f.toggleUtilities();
    } else if (eq(u8, cmd, "debug-media")) {
        // 試験用(AME_DEBUG が設定されているときだけ): 「アーティスト|曲名|長さ秒|位置秒」で再生中のふりをする
        if (std.posix.getenv("AME_DEBUG") == null) return "error: AME_DEBUG が必要です";
        app.media.debugFake(rest);
    } else if (eq(u8, cmd, "debug-hand")) {
        // 試験用(AME_DEBUG のときだけ): カメラ無しで手の形と位置を与える(<none|point|pinch|open|fist> <x 0〜1> <y 0〜1>)
        if (std.posix.getenv("AME_DEBUG") == null) return "error: AME_DEBUG が必要です";
        @import("hand/hand.zig").debugInject(app, rest);
    } else if (eq(u8, cmd, "debug-wobble")) {
        // 試験用(AME_DEBUG のときだけ): 浮いた窓のたわみを、カーソル無しで動かす(start / move dx dy / release)
        if (std.posix.getenv("AME_DEBUG") == null) return "error: AME_DEBUG が必要です";
        if (app.wm) |w| w.debugWobble(rest);
    } else if (eq(u8, cmd, "debug-spectrum")) {
        // 試験用(AME_DEBUG のときだけ): 音を鳴らさずに、ビジュアライザーへ低音の強いスペクトルを入れる
        if (std.posix.getenv("AME_DEBUG") == null) return "error: AME_DEBUG が必要です";
        const seed: f32 = @floatFromInt(std.fmt.parseInt(u32, if (arg.len > 0) arg else "1", 10) catch 1);
        var vals: [@import("frame/data.zig").BARS]f32 = undefined;
        for (&vals, 0..) |*v, i| {
            const x: f32 = @floatFromInt(i);
            v.* = std.math.clamp(0.95 * @exp(-x / 9.0) + 0.25 * @abs(@sin(x * 0.7 + seed)) + 0.15 * @abs(@sin(x * 2.3 + seed * 1.7)), 0, 1);
        }
        app.lock.spectrum.values = vals;
        app.lock.spectrum.fake = true;
        if (app.activeFrame()) |f| {
            f.spectrum.values = vals;
            f.spectrum.fake = true;
        }
        app.lock.scheduleAll();
    } else if (eq(u8, cmd, "debug-battery")) {
        // 試験用(AME_DEBUG のときだけ): 「残り% [ac]」の電池の状態にして、少なくなったときの通知を確かめる
        if (std.posix.getenv("AME_DEBUG") == null) return "error: AME_DEBUG が必要です";
        app.debug_battery = true;
        app.sys.battery.present = true;
        app.sys.battery.percent = std.fmt.parseInt(u8, arg, 10) catch return "error: 残り% を数で";
        app.sys.battery.on_ac = std.mem.indexOf(u8, rest, "ac") != null;
        app.sys.battery.charging = app.sys.battery.on_ac;
        app.syswatch.checkBattery();
        app.redrawBars();
    } else if (eq(u8, cmd, "debug-usb")) {
        // 試験用(AME_DEBUG のときだけ): 「add|remove <sysfs の DEVPATH>」の uevent を受け取ったことにする
        if (std.posix.getenv("AME_DEBUG") == null) return "error: AME_DEBUG が必要です";
        const dp = std.mem.trim(u8, rest[@min(rest.len, arg.len)..], " ");
        var mb: [512]u8 = undefined;
        const msg = std.fmt.bufPrint(&mb, "{s}@{s}\x00ACTION={s}\x00DEVPATH={s}\x00SUBSYSTEM=usb\x00DEVTYPE=usb_device\x00", .{ arg, dp, arg, dp }) catch return "error";
        app.syswatch.usbUeventPub(msg);
    } else if (eq(u8, cmd, "debug-error")) {
        // 試験用(AME_DEBUG のときだけ): 失敗時の赤い光
        if (std.posix.getenv("AME_DEBUG") == null) return "error: AME_DEBUG が必要です";
        theme.flashError(app);
    } else if (eq(u8, cmd, "wallpaper-picker")) {
        app.wallpick.toggle();
    } else if (eq(u8, cmd, "network") or eq(u8, cmd, "bluetooth")) {
        const f = app.activeFrame() orelse return "error: caelestia レイアウトでのみ使えます";
        f.toggleNet(if (eq(u8, cmd, "network")) 0 else 1);
    } else if (eq(u8, cmd, "workspace") or eq(u8, cmd, "window")) {
        // workspace <1-9>(River 0.3/0.5 両方)/ window close|fullscreen|float|focus-next|focus-prev|swap-next|swap-prev
        if (eq(u8, cmd, "workspace")) {
            const n = std.fmt.parseInt(u5, arg, 10) catch return "error: workspace 1-9";
            if (n < 1 or n > 9) return "error: workspace 1-9";
            app.focusTags(@as(u32, 1) << (n - 1)); // River 0.5 は内蔵 WM、0.3 は river-control へ
        } else {
            const w = app.wm orelse return "error: window は River 0.5 セッション(内蔵ウィンドウマネージャ)でのみ使えます";
            const WmAction = @import("wm/wm.zig").Action;
            const a: WmAction = if (eq(u8, arg, "close")) .close else if (eq(u8, arg, "fullscreen")) .fullscreen else if (eq(u8, arg, "float")) .float else if (eq(u8, arg, "focus-next")) .focus_next else if (eq(u8, arg, "focus-prev")) .focus_prev else if (eq(u8, arg, "swap-next")) .swap_next else if (eq(u8, arg, "swap-prev")) .swap_prev else return "error: window close|fullscreen|float|focus-next|focus-prev|swap-next|swap-prev";
            w.push(a);
        }
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
    } else if (eq(u8, cmd, "avatar")) {
        if (!eq(u8, arg, "pick")) return "error: avatar pick";
        app.wallpick.openAvatarFile();
    } else if (eq(u8, cmd, "media")) {
        // 再生中の曲の操作(MPRIS を D-Bus で。playerctl は使わない)
        if (eq(u8, arg, "play-pause") or eq(u8, arg, "toggle")) app.media.toggle() else if (eq(u8, arg, "next")) app.media.next() else if (eq(u8, arg, "previous") or eq(u8, arg, "prev")) app.media.prev() else return "error: media play-pause|next|previous";
    } else if (eq(u8, cmd, "net") and eq(u8, arg, "ssid")) {
        // つながっている Wi-Fi の名前(バーに出すもの)
        return @import("platform/netdbus.zig").activeSsid(out) orelse "(つながっていません)";
    } else if (eq(u8, cmd, "net")) {
        // Wi-Fi・Bluetooth の状態(NetworkManager / BlueZ に D-Bus で直接聞く。読み取りだけ)
        const argv: []const []const u8 = if (eq(u8, arg, "wifi"))
            &.{ "nmcli", "-t", "-f", "IN-USE,SSID,SIGNAL,SECURITY", "dev", "wifi", "list" }
        else if (eq(u8, arg, "saved"))
            &.{ "nmcli", "-t", "-f", "NAME,TYPE", "connection", "show" }
        else if (eq(u8, arg, "radio"))
            &.{ "nmcli", "radio", "wifi" }
        else if (eq(u8, arg, "bt"))
            &.{ "bluetoothctl", "show" }
        else if (eq(u8, arg, "bt-devices"))
            &.{ "bluetoothctl", "devices" }
        else
            return "error: net wifi|saved|radio|ssid|bt|bt-devices";
        return @import("platform/netdbus.zig").run(argv, out) orelse "error";
    } else if (eq(u8, cmd, "screenshot")) {
        const k = @import("shot.zig").Kind.parse(if (arg.len > 0) arg else "region") orelse return "error: screenshot region|full|clip";
        @import("shot.zig").take(app, k, 0);
    } else if (eq(u8, cmd, "hand")) {
        // ハンド操作(カメラで手の動きを見て、カーソルと窓を操作する)
        const hand = @import("hand/hand.zig");
        if (eq(u8, arg, "on")) hand.enable(app) else if (eq(u8, arg, "off")) hand.disable() else if (eq(u8, arg, "toggle") or arg.len == 0) hand.toggle(app) else if (!eq(u8, arg, "status")) return "error: hand on|off|toggle|status";
        return if (hand.enabled()) "on" else "off";
    } else if (eq(u8, cmd, "face")) {
        // 顔認証(ロック画面で顔を見てロックを外す)の登録・削除・状態
        const fa = @import("face/unlock.zig");
        if (eq(u8, arg, "enroll")) return fa.enroll(app);
        if (eq(u8, arg, "clear")) return fa.clear();
        if (eq(u8, arg, "status") or arg.len == 0) return fa.status(out);
        return "error: face enroll|clear|status";
    } else if (eq(u8, cmd, "lock")) {
        return app.lock.lock();
    } else if (eq(u8, cmd, "reload")) {
        app.loadConfig(false);
    } else if (eq(u8, cmd, "widgets")) {
        app.dashboard.reloadWidgets();
    } else if (eq(u8, cmd, "stats")) {
        return stats(app, out);
    } else if (eq(u8, cmd, "restart")) {
        if (app.wm) |w| w.saveState(); // River 0.5: 窓のワークスペースを再起動後に戻す
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
