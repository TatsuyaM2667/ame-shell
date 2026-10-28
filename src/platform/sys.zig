// OS 依存のデータ取得(sysfs / procfs / 外部コマンド)。
//
// init(dinit/systemd)には依存せず、カーネルのインターフェースと、どの
// ディストリにもある小さなコマンド(wpctl, brightnessctl, nmcli)だけを使う。
// コマンドが無い環境ではその機能だけ「不明」として扱い、シェルは動き続ける。
const std = @import("std");
const c = @import("../c.zig");
const builtin = @import("builtin");
/// FreeBSD では /proc・/sys の代わりに sysctl や FreeBSD のコマンドを使う(bsd.zig)
const is_bsd = builtin.os.tag == .freebsd;
const bsd = @import("bsd.zig");

/// 電源操作。Linux は loginctl(elogind / systemd-logind)、FreeBSD は ConsoleKit2 を D-Bus で
/// (どちらも一般ユーザーのまま実行できる)。suspend は画面のロックが先に出るよう 1 秒待つ
pub const PowerAction = enum { suspend_, reboot, poweroff };
pub fn power(a: PowerAction) void {
    if (is_bsd) {
        const method = switch (a) {
            .suspend_ => "Suspend",
            .reboot => "Reboot",
            .poweroff => "PowerOff",
        };
        var buf: [256]u8 = undefined;
        const cmd = std.fmt.bufPrintZ(&buf, "{s}dbus-send --system --print-reply --dest=org.freedesktop.ConsoleKit /org/freedesktop/ConsoleKit/Manager org.freedesktop.ConsoleKit.Manager.{s} boolean:true", .{ if (a == .suspend_) "sleep 1; " else "", method }) catch return;
        spawnDetached(cmd.ptr);
        return;
    }
    spawnDetached(switch (a) {
        .suspend_ => "sleep 1; loginctl suspend",
        .reboot => "loginctl reboot",
        .poweroff => "loginctl poweroff",
    });
}

/// PATH にそのコマンドがあるか(nmcli・bluetoothctl の無い環境で、パネルに理由を出すため)
pub fn hasCommand(name: []const u8) bool {
    const path = std.posix.getenv("PATH") orelse "/usr/local/bin:/usr/bin:/bin";
    var it = std.mem.splitScalar(u8, path, ':');
    while (it.next()) |dir| {
        if (dir.len == 0) continue;
        var buf: [512]u8 = undefined;
        const p = std.fmt.bufPrintZ(&buf, "{s}/{s}", .{ dir, name }) catch continue;
        if (c.access(p.ptr, c.X_OK) == 0) return true;
    }
    return false;
}

/// 小さなファイルを読み、前後の空白を取った内容を buf に返す。
pub fn readFile(path: [*:0]const u8, buf: []u8) ?[]const u8 {
    const fd = c.open(path, c.O_RDONLY | c.O_CLOEXEC);
    if (fd < 0) return null;
    defer _ = c.close(fd);
    const n = c.read(fd, buf.ptr, buf.len);
    if (n <= 0) return null;
    return std.mem.trim(u8, buf[0..@intCast(n)], " \n\t");
}

fn readInt(path: [*:0]const u8) ?i64 {
    var buf: [64]u8 = undefined;
    const s = readFile(path, &buf) orelse return null;
    return std.fmt.parseInt(i64, s, 10) catch null;
}

// ---------------- 電源 ----------------

/// dir(末尾に / 付き)の中の数値のファイル
fn readAttr(dir: []const u8, file: []const u8) ?i64 {
    var p: [320]u8 = undefined;
    return readInt(std.fmt.bufPrintZ(&p, "{s}{s}", .{ dir, file }) catch return null);
}

pub const Battery = struct {
    present: bool = false,
    percent: u8 = 0,
    /// 充電している(電源につながっていても、満充電・充電の上限・保護モードで止まっているときは false)
    charging: bool = false,
    on_ac: bool = true,
    /// 満充電(status = Full)
    full: bool = false,
    /// 放電中は残りの時間、充電中は満充電までの時間(分)。分からなければ null
    minutes: ?u32 = null,

    /// 電源につながっているが充電していない(満充電・充電の上限・保護モード)
    pub fn held(self: Battery) bool {
        return self.present and self.on_ac and !self.charging;
    }
};

pub fn battery() Battery {
    if (is_bsd) {
        const x = bsd.battery();
        return .{ .present = x.present, .percent = x.percent, .charging = x.charging, .on_ac = x.on_ac, .full = x.on_ac and !x.charging and x.percent >= 100, .minutes = if (x.on_ac) null else x.minutes };
    }
    var b = Battery{};
    const dir = c.opendir("/sys/class/power_supply") orelse return b;
    defer _ = c.closedir(dir);
    var ac_seen = false;
    var ac_online = false;
    while (c.readdir(dir)) |ent| {
        const name = std.mem.sliceTo(@as([*:0]const u8, @ptrCast(&ent.*.d_name)), 0);
        if (name[0] == '.') continue;
        var p: [256]u8 = undefined;
        var t: [32]u8 = undefined;
        const type_path = std.fmt.bufPrintZ(&p, "/sys/class/power_supply/{s}/type", .{name}) catch continue;
        const ty = readFile(type_path, &t) orelse continue;
        if (std.mem.eql(u8, ty, "Battery") and !b.present) {
            const cap = std.fmt.bufPrintZ(&p, "/sys/class/power_supply/{s}/capacity", .{name}) catch continue;
            b.percent = @intCast(std.math.clamp(readInt(cap) orelse 0, 0, 100));
            var sbuf: [32]u8 = undefined;
            const st_path = std.fmt.bufPrintZ(&p, "/sys/class/power_supply/{s}/status", .{name}) catch continue;
            const st = readFile(st_path, &sbuf) orelse "";
            b.charging = std.mem.eql(u8, st, "Charging");
            b.full = std.mem.eql(u8, st, "Full");
            b.present = true;
            // 残り時間: energy(µWh / µW)か charge(µAh / µA)のどちらかがある
            const bat_dir = std.fmt.bufPrint(&p, "/sys/class/power_supply/{s}/", .{name}) catch continue;
            const now = readAttr(bat_dir, "energy_now") orelse readAttr(bat_dir, "charge_now");
            const full = readAttr(bat_dir, "energy_full") orelse readAttr(bat_dir, "charge_full");
            const rate = readAttr(bat_dir, "power_now") orelse readAttr(bat_dir, "current_now");
            if (now != null and rate != null and @abs(rate.?) > 0) {
                const r: f64 = @floatFromInt(@abs(rate.?));
                const left: f64 = if (b.charging) @floatFromInt(@max((full orelse now.?) - now.?, 0)) else if (std.mem.eql(u8, st, "Discharging")) @floatFromInt(now.?) else -1;
                const m = left / r * 60;
                if (left >= 0 and m >= 1 and m < 48 * 60) b.minutes = @intFromFloat(m);
            }
        } else if (std.mem.eql(u8, ty, "Mains")) {
            ac_seen = true;
            const on = std.fmt.bufPrintZ(&p, "/sys/class/power_supply/{s}/online", .{name}) catch continue;
            if ((readInt(on) orelse 0) == 1) ac_online = true;
        }
    }
    b.on_ac = if (ac_seen) ac_online else !b.present;
    return b;
}

// ---------------- 明るさ ----------------

pub fn brightness() ?f32 {
    if (is_bsd) return bsd.backlight(run);
    const dir = c.opendir("/sys/class/backlight") orelse return null;
    defer _ = c.closedir(dir);
    while (c.readdir(dir)) |ent| {
        const name = std.mem.sliceTo(@as([*:0]const u8, @ptrCast(&ent.*.d_name)), 0);
        if (name[0] == '.') continue;
        var p: [256]u8 = undefined;
        const cur = readInt(std.fmt.bufPrintZ(&p, "/sys/class/backlight/{s}/brightness", .{name}) catch continue) orelse continue;
        const max = readInt(std.fmt.bufPrintZ(&p, "/sys/class/backlight/{s}/max_brightness", .{name}) catch continue) orelse continue;
        if (max <= 0) continue;
        return @as(f32, @floatFromInt(cur)) / @as(f32, @floatFromInt(max));
    }
    return null;
}

/// sysfs への書き込みは通常 root/video グループが必要なので brightnessctl に任せる。
pub fn setBrightnessDelta(percent: i32) void {
    var arg: [16]u8 = undefined;
    const a = if (percent >= 0)
        std.fmt.bufPrintZ(&arg, "{d}%+", .{percent}) catch return
    else
        std.fmt.bufPrintZ(&arg, "{d}%-", .{-percent}) catch return;
    var out: [64]u8 = undefined;
    if (is_bsd) {
        var nb: [8]u8 = undefined;
        const n = std.fmt.bufPrintZ(&nb, "{d}", .{@abs(percent)}) catch return;
        _ = run(&.{ "backlight", if (percent >= 0) "incr" else "decr", n.ptr }, &out);
        return;
    }
    _ = run(&.{ "brightnessctl", "-q", "set", a.ptr }, &out);
}

// ---------------- 音量(PipeWire: wpctl) ----------------

pub const Volume = struct { known: bool = false, level: f32 = 0, muted: bool = false };

pub fn volume() Volume {
    var out: [128]u8 = undefined;
    const s = run(&.{ "wpctl", "get-volume", "@DEFAULT_AUDIO_SINK@" }, &out) orelse {
        // FreeBSD で PipeWire が無いときは mixer(8)
        if (is_bsd) if (bsd.mixerVolume(run)) |m| return .{ .known = true, .level = m.level, .muted = m.muted };
        return .{};
    };
    // 形式: "Volume: 0.45" または "Volume: 0.45 [MUTED]"
    var it = std.mem.tokenizeAny(u8, s, " \n");
    _ = it.next() orelse return .{};
    const num = it.next() orelse return .{};
    const v = std.fmt.parseFloat(f32, num) catch return .{};
    return .{ .known = true, .level = v, .muted = std.mem.indexOf(u8, s, "MUTED") != null };
}

pub fn setVolumeDelta(percent: i32) void {
    var arg: [16]u8 = undefined;
    const a = if (percent >= 0)
        std.fmt.bufPrintZ(&arg, "{d}%+", .{percent}) catch return
    else
        std.fmt.bufPrintZ(&arg, "{d}%-", .{-percent}) catch return;
    var out: [8]u8 = undefined;
    // -l 1.0 で 100% を超えないようにする(耳とスピーカーの保護)。
    if (run(&.{ "wpctl", "set-volume", "-l", "1.0", "@DEFAULT_AUDIO_SINK@", a.ptr }, &out) == null and is_bsd) {
        var mb: [32]u8 = undefined;
        const m = std.fmt.bufPrintZ(&mb, "vol.volume={s}{d:.2}", .{ if (percent >= 0) "+" else "-", @as(f32, @floatFromInt(@abs(percent))) / 100 }) catch return;
        _ = run(&.{ "mixer", m.ptr }, &out);
    }
}

pub fn setVolume(level: f32) void {
    var arg: [16]u8 = undefined;
    const a = std.fmt.bufPrintZ(&arg, "{d:.2}", .{std.math.clamp(level, 0, 1)}) catch return;
    var out: [8]u8 = undefined;
    if (run(&.{ "wpctl", "set-volume", "@DEFAULT_AUDIO_SINK@", a.ptr }, &out) == null and is_bsd) {
        var mb: [32]u8 = undefined;
        const m = std.fmt.bufPrintZ(&mb, "vol.volume={d:.2}", .{std.math.clamp(level, 0, 1)}) catch return;
        _ = run(&.{ "mixer", m.ptr }, &out);
    }
}

pub fn toggleMute() void {
    var out: [8]u8 = undefined;
    if (run(&.{ "wpctl", "set-mute", "@DEFAULT_AUDIO_SINK@", "toggle" }, &out) == null and is_bsd) {
        _ = run(&.{ "mixer", "vol.mute=^" }, &out);
    }
}

// ---------------- ネットワーク ----------------

pub const NetKind = enum { none, wired, wifi };
pub const Net = struct { kind: NetKind = .none, name_buf: [64]u8 = undefined, name_len: usize = 0 };

pub fn network() Net {
    var n = Net{};
    if (is_bsd) {
        const x = bsd.network(run);
        if (x.connected) {
            n.kind = if (x.wifi) .wifi else .wired;
            n.name_len = x.name_len;
            @memcpy(n.name_buf[0..x.name_len], x.name_buf[0..x.name_len]);
        }
        return n;
    }
    const dir = c.opendir("/sys/class/net") orelse return n;
    defer _ = c.closedir(dir);
    while (c.readdir(dir)) |ent| {
        const name = std.mem.sliceTo(@as([*:0]const u8, @ptrCast(&ent.*.d_name)), 0);
        if (name[0] == '.' or std.mem.eql(u8, name, "lo")) continue;
        var p: [256]u8 = undefined;
        var b: [32]u8 = undefined;
        const op = readFile(std.fmt.bufPrintZ(&p, "/sys/class/net/{s}/operstate", .{name}) catch continue, &b) orelse continue;
        if (!std.mem.eql(u8, op, "up")) continue;
        const wl = std.fmt.bufPrintZ(&p, "/sys/class/net/{s}/wireless", .{name}) catch continue;
        const is_wifi = c.access(wl, c.F_OK) == 0;
        // 仮想 IF(docker/veth/br)は「接続」とは見なさない。
        if (!is_wifi and (std.mem.startsWith(u8, name, "veth") or std.mem.startsWith(u8, name, "docker") or std.mem.startsWith(u8, name, "br-") or std.mem.startsWith(u8, name, "virbr"))) continue;
        if (is_wifi or n.kind == .none) {
            n.kind = if (is_wifi) .wifi else .wired;
            n.name_len = @min(name.len, n.name_buf.len);
            @memcpy(n.name_buf[0..n.name_len], name[0..n.name_len]);
        }
        if (is_wifi) break;
    }
    // Wi-Fi なら SSID を表示したい。nmcli があれば聞く(無ければ IF 名のまま)。
    if (n.kind == .wifi) {
        var out: [256]u8 = undefined;
        if (run(&.{ "nmcli", "-t", "-f", "ACTIVE,SSID", "dev", "wifi", "list", "--rescan", "no" }, &out)) |s| {
            var lines = std.mem.splitScalar(u8, s, '\n');
            while (lines.next()) |l| {
                if (std.mem.startsWith(u8, l, "yes:")) {
                    const ssid = l[4..];
                    n.name_len = @min(ssid.len, n.name_buf.len);
                    @memcpy(n.name_buf[0..n.name_len], ssid[0..n.name_len]);
                    break;
                }
            }
        }
    }
    return n;
}

// ---------------- CPU / メモリ(ダッシュボード用) ----------------

pub const CpuSample = struct { idle: u64 = 0, total: u64 = 0 };

pub fn cpuSample() CpuSample {
    if (is_bsd) {
        const t = bsd.cpuTimes() orelse return .{};
        return .{ .idle = t.idle, .total = t.total };
    }
    var buf: [512]u8 = undefined;
    const s = readFile("/proc/stat", &buf) orelse return .{};
    var it = std.mem.tokenizeAny(u8, s, " \n");
    _ = it.next(); // "cpu"
    var total: u64 = 0;
    var idle: u64 = 0;
    var i: usize = 0;
    while (it.next()) |tok| : (i += 1) {
        if (i >= 8) break;
        const v = std.fmt.parseInt(u64, tok, 10) catch break;
        total += v;
        if (i == 3 or i == 4) idle += v; // idle + iowait
    }
    return .{ .idle = idle, .total = total };
}

pub fn memUsage() f32 {
    if (is_bsd) {
        const m = bsd.memory() orelse return 0;
        return if (m.total > 0) @floatCast(m.used / m.total) else 0;
    }
    var buf: [2048]u8 = undefined;
    const s = readFile("/proc/meminfo", &buf) orelse return 0;
    var total: f32 = 0;
    var avail: f32 = 0;
    var lines = std.mem.splitScalar(u8, s, '\n');
    while (lines.next()) |l| {
        var it = std.mem.tokenizeAny(u8, l, ": ");
        const k = it.next() orelse continue;
        const v = std.fmt.parseFloat(f32, it.next() orelse continue) catch continue;
        if (std.mem.eql(u8, k, "MemTotal")) total = v;
        if (std.mem.eql(u8, k, "MemAvailable")) avail = v;
    }
    if (total <= 0) return 0;
    return 1 - avail / total;
}

pub fn cpuTemp() ?f32 {
    if (is_bsd) return bsd.cpuTemp();
    // thermal_zone の中から x86_pkg_temp / k10temp 相当を優先、無ければ最初のもの。
    var best: ?f32 = null;
    var i: usize = 0;
    while (i < 16) : (i += 1) {
        var p: [96]u8 = undefined;
        const t = readInt(std.fmt.bufPrintZ(&p, "/sys/class/thermal/thermal_zone{d}/temp", .{i}) catch break) orelse continue;
        const v = @as(f32, @floatFromInt(t)) / 1000.0;
        if (v <= 0 or v > 150) continue;
        if (best == null or v > best.?) best = v;
    }
    return best;
}

// ---------------- 子プロセス ----------------

/// argv を実行し、標準出力を buf に取り込んで返す(同期・短時間コマンド専用)。
/// コマンドが見つからない/失敗したら null。シェルを経由しないので引数注入の心配がない。
pub fn run(argv: []const ?[*:0]const u8, buf: []u8) ?[]const u8 {
    var fds: [2]c_int = undefined;
    if (c.pipe2(&fds, c.O_CLOEXEC) != 0) return null;
    var args: [16:null]?[*:0]const u8 = .{null} ** 16;
    for (argv, 0..) |a, i| args[i] = a;
    const pid = c.fork();
    if (pid < 0) {
        _ = c.close(fds[0]);
        _ = c.close(fds[1]);
        return null;
    }
    if (pid == 0) {
        _ = c.dup2(fds[1], 1);
        const devnull = c.open("/dev/null", c.O_WRONLY);
        if (devnull >= 0) _ = c.dup2(devnull, 2);
        _ = c.execvp(args[0].?, @ptrCast(&args));
        c._exit(127);
    }
    _ = c.close(fds[1]);
    var total: usize = 0;
    while (total < buf.len) {
        const n = c.read(fds[0], buf.ptr + total, buf.len - total);
        if (n <= 0) break;
        total += @intCast(n);
    }
    _ = c.close(fds[0]);
    var status: c_int = 0;
    _ = c.waitpid(pid, &status, 0);
    if (!(c.WIFEXITED(status) and c.WEXITSTATUS(status) == 0)) return null;
    return std.mem.trim(u8, buf[0..total], " \n");
}

/// ランチャー等から GUI アプリを起動する。二重 fork + setsid でシェルから切り離し、
/// シェルが再起動してもアプリが道連れにならないようにする。
pub fn spawnDetached(cmdline: [*:0]const u8) void {
    const pid = c.fork();
    if (pid < 0) return;
    if (pid == 0) {
        _ = c.setsid();
        const pid2 = c.fork();
        if (pid2 != 0) c._exit(0);
        var sigset: c.sigset_t = undefined;
        _ = c.sigemptyset(&sigset);
        _ = c.sigprocmask(c.SIG_SETMASK, &sigset, null);
        const argv = [_:null]?[*:0]const u8{ "/bin/sh", "-c", cmdline, null };
        _ = c.execv("/bin/sh", @ptrCast(&argv));
        c._exit(127);
    }
    var status: c_int = 0;
    _ = c.waitpid(pid, &status, 0);
}

/// 長時間動く子プロセスを起動し、その標準出力を読む fd を返す(イベント監視用。
/// 例: `pactl subscribe` の出力を epoll で待てば、音量変更をポーリングなしで検知できる)。
pub fn spawnReader(argv: []const ?[*:0]const u8, out_pid: *c_int) ?c_int {
    var fds: [2]c_int = undefined;
    if (c.pipe2(&fds, c.O_CLOEXEC) != 0) return null;
    var args: [16:null]?[*:0]const u8 = .{null} ** 16;
    for (argv, 0..) |a, i| args[i] = a;
    const pid = c.fork();
    if (pid < 0) return null;
    if (pid == 0) {
        _ = c.dup2(fds[1], 1);
        const devnull = c.open("/dev/null", c.O_WRONLY);
        if (devnull >= 0) _ = c.dup2(devnull, 2);
        _ = c.execvp(args[0].?, @ptrCast(&args));
        c._exit(127);
    }
    _ = c.close(fds[1]);
    _ = c.fcntl(fds[0], c.F_SETFL, c.O_NONBLOCK);
    out_pid.* = pid;
    return fds[0];
}

/// spawnReader と同じだが、標準エラーも同じ pipe に流す(nmcli 等のエラーメッセージを表示するため)
pub fn spawnReaderAll(argv: []const ?[*:0]const u8, out_pid: *c_int) ?c_int {
    var fds: [2]c_int = undefined;
    if (c.pipe2(&fds, c.O_CLOEXEC) != 0) return null;
    var args: [24:null]?[*:0]const u8 = .{null} ** 24;
    for (argv, 0..) |a, i| args[i] = a;
    const pid = c.fork();
    if (pid < 0) return null;
    if (pid == 0) {
        _ = c.dup2(fds[1], 1);
        _ = c.dup2(fds[1], 2);
        // 対話的な確認を求めるコマンドが止まらないように標準入力は空に
        const devnull = c.open("/dev/null", c.O_RDONLY);
        if (devnull >= 0) _ = c.dup2(devnull, 0);
        _ = c.execvp(args[0].?, @ptrCast(&args));
        c._exit(127);
    }
    _ = c.close(fds[1]);
    _ = c.fcntl(fds[0], c.F_SETFL, c.O_NONBLOCK);
    out_pid.* = pid;
    return fds[0];
}
