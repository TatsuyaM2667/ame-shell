// ログイン画面(greeter)。SDDM の代わりに、greetd から ame-shell をこのモードで起動する
// (session/ame-greeter: _greetd ユーザーで River 0.5 + ame-shell。AME_GREETER=1)。
//
// 見た目と操作はロック画面と同じ(lock.zig / lockui.zig)。違うのは:
//   - 認証は PAM ではなく greetd に頼む(GREETD_SOCK の UNIX ソケット、長さ 4 バイト + JSON)。
//     成功したら start_session でセッション(既定は「Ame Shell」)を始めてもらい、ame-shell は終わる
//   - ユーザーを選べる(/etc/passwd の UID 1000 以上でログインできる人)。最後にログインした人が最初
//   - 背景・写真はユーザーごとの置き場(/var/lib/ame-shell/greeter/<ユーザー>。sddmshare.zig が書く)から:
//     wallmode がオーロラ・雨ならそれを描き、画像・動画なら wallpaper.bmp(その人の壁紙)を表示する
//   - セッションの切り替え・再起動・電源オフのボタン
// 試験用: AME_GREETER_FAKE=1 なら greetd を使わず、パスワード "ame" で成功したことにする(何も起動しない)。
const std = @import("std");
const builtin = @import("builtin");
const c = @import("c.zig");
const App = @import("app.zig").App;

pub const MAX_USERS = 16;
pub const MAX_SESSIONS = 12;

pub const Name = struct {
    buf: [64]u8 = undefined,
    len: usize = 0,
    pub fn get(self: *const Name) []const u8 {
        return self.buf[0..self.len];
    }
    fn set(self: *Name, s: []const u8) void {
        self.len = @min(s.len, self.buf.len);
        @memcpy(self.buf[0..self.len], s[0..self.len]);
    }
};

pub const Session = struct {
    name: Name = .{},
    exec: [256]u8 = undefined,
    exec_len: usize = 0,
    file: Name = .{},
};

pub const State = struct {
    users: [MAX_USERS]Name = undefined,
    n_users: usize = 0,
    user: usize = 0,
    sessions: [MAX_SESSIONS]Session = undefined,
    n_sessions: usize = 0,
    session: usize = 0,
};

pub var st: State = .{};

pub fn enabled() bool {
    const v = std.posix.getenv("AME_GREETER") orelse return false;
    return std.mem.eql(u8, v, "1");
}

fn fake() bool {
    const v = std.posix.getenv("AME_GREETER_FAKE") orelse return false;
    return std.mem.eql(u8, v, "1");
}

pub fn shareRoot() []const u8 {
    if (std.posix.getenv("AME_GREETER_SHARE")) |d| return d; // 試験用
    return if (builtin.os.tag == .freebsd) "/var/db/ame-shell/greeter" else "/var/lib/ame-shell/greeter";
}

pub fn userName() []const u8 {
    if (st.n_users == 0) return "";
    return st.users[st.user].get();
}

pub fn sessionName() []const u8 {
    if (st.n_sessions == 0) return "";
    return st.sessions[st.session].name.get();
}

/// ユーザーとセッションの一覧を読む(起動時に 1 回)
pub fn load() void {
    loadUsers();
    loadSessions();
    // 最後にログインした人
    var lb: [128]u8 = undefined;
    if (lastUserPath(&lb)) |p| {
        var buf: [64]u8 = undefined;
        if (std.fs.cwd().readFile(p, &buf)) |s| {
            const name = std.mem.trim(u8, s, " \t\r\n");
            for (st.users[0..st.n_users], 0..) |u, i| if (std.mem.eql(u8, u.get(), name)) {
                st.user = i;
            };
        } else |_| {}
    }
    std.log.info("greeter: ユーザー {d} 人・セッション {d} 個(既定: {s} / {s})", .{ st.n_users, st.n_sessions, userName(), sessionName() });
}

fn loadUsers() void {
    st.n_users = 0;
    const data = std.fs.cwd().readFileAlloc(std.heap.c_allocator, "/etc/passwd", 1 << 20) catch return;
    defer std.heap.c_allocator.free(data);
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |l| {
        var f: [7][]const u8 = undefined;
        var it = std.mem.splitScalar(u8, l, ':');
        var n: usize = 0;
        while (it.next()) |x| {
            if (n >= f.len) break;
            f[n] = x;
            n += 1;
        }
        if (n < 7) continue;
        const uid = std.fmt.parseInt(u32, f[2], 10) catch continue;
        if (uid < 1000 or uid >= 60000) continue;
        const sh = f[6];
        if (std.mem.endsWith(u8, sh, "nologin") or std.mem.endsWith(u8, sh, "/false") or sh.len == 0) continue;
        if (st.n_users >= MAX_USERS) break;
        st.users[st.n_users] = .{};
        st.users[st.n_users].set(f[0]);
        st.n_users += 1;
    }
}

fn loadSessions() void {
    st.n_sessions = 0;
    for ([_][]const u8{ "/usr/local/share/wayland-sessions", "/usr/share/wayland-sessions" }) |d| {
        var dir = std.fs.cwd().openDir(d, .{ .iterate = true }) catch continue;
        defer dir.close();
        var it = dir.iterate();
        while (it.next() catch null) |ent| {
            if (!std.mem.endsWith(u8, ent.name, ".desktop")) continue;
            if (st.n_sessions >= MAX_SESSIONS) return;
            // 同じ名前のファイルは最初のものだけ
            var dup = false;
            for (st.sessions[0..st.n_sessions]) |s| dup = dup or std.mem.eql(u8, s.file.get(), ent.name);
            if (dup) continue;
            var buf: [4096]u8 = undefined;
            const text = dir.readFile(ent.name, &buf) catch continue;
            var s = Session{};
            s.file.set(ent.name);
            var hidden = false;
            var lines = std.mem.splitScalar(u8, text, '\n');
            var in_main = false;
            while (lines.next()) |raw| {
                const l = std.mem.trim(u8, raw, " \t\r");
                if (l.len > 0 and l[0] == '[') {
                    in_main = std.mem.eql(u8, l, "[Desktop Entry]");
                    continue;
                }
                if (!in_main) continue;
                const eq = std.mem.indexOfScalar(u8, l, '=') orelse continue;
                const k = l[0..eq];
                const v = l[eq + 1 ..];
                if (std.mem.eql(u8, k, "Name")) s.name.set(v) else if (std.mem.eql(u8, k, "Exec")) {
                    s.exec_len = @min(v.len, s.exec.len);
                    @memcpy(s.exec[0..s.exec_len], v[0..s.exec_len]);
                } else if ((std.mem.eql(u8, k, "NoDisplay") or std.mem.eql(u8, k, "Hidden")) and std.mem.eql(u8, v, "true")) hidden = true;
            }
            if (hidden or s.exec_len == 0 or s.name.len == 0) continue;
            st.sessions[st.n_sessions] = s;
            // 既定は ame-shell(River 0.5 の「Ame Shell」→ 通常の「Ame Shell」の順)
            if (std.mem.eql(u8, ent.name, "ame-shell-river5.desktop")) st.session = st.n_sessions;
            if (std.mem.eql(u8, ent.name, "ame-shell.desktop") and !std.mem.eql(u8, st.sessions[st.session].file.get(), "ame-shell-river5.desktop")) st.session = st.n_sessions;
            st.n_sessions += 1;
        }
    }
}

fn lastUserPath(buf: []u8) ?[]const u8 {
    const home = std.posix.getenv("HOME") orelse return null;
    return std.fmt.bufPrint(buf, "{s}/ame-last-user", .{home}) catch null;
}

pub fn saveLastUser() void {
    var lb: [128]u8 = undefined;
    const p = lastUserPath(&lb) orelse return;
    const f = std.fs.cwd().createFile(p, .{}) catch return;
    defer f.close();
    f.writer().print("{s}\n", .{userName()}) catch {};
}

/// 選んだユーザーの見た目(写真・壁紙)にする
pub fn applyUser(app: *App) void {
    const u = userName();
    if (u.len == 0) return;
    var pb: [256]u8 = undefined;
    // 写真
    const av = std.fmt.bufPrintZ(&pb, "{s}/{s}/avatar.bmp", .{ shareRoot(), u }) catch return;
    const avatar = @import("avatar.zig");
    avatar.setOverride(if (c.access(av.ptr, c.R_OK) == 0) av else null);
    app.avatar.reload();
    // 壁紙: wallmode(aurora / rain / image / video)
    var mb: [64]u8 = undefined;
    var wb: [320]u8 = undefined;
    const mode_path = std.fmt.bufPrint(&wb, "{s}/{s}/wallmode", .{ shareRoot(), u }) catch return;
    const mode = std.mem.trim(u8, std.fs.cwd().readFile(mode_path, &mb) catch "aurora", " \t\r\n");
    var cmd_buf: [400]u8 = undefined;
    const cmd = if (std.mem.eql(u8, mode, "rain"))
        "wallpaper rain"
    else if (std.mem.eql(u8, mode, "image") or std.mem.eql(u8, mode, "video")) blk: {
        var ib: [320]u8 = undefined;
        const img = std.fmt.bufPrintZ(&ib, "{s}/{s}/wallpaper.bmp", .{ shareRoot(), u }) catch break :blk "wallpaper aurora";
        if (c.access(img.ptr, c.R_OK) != 0) break :blk "wallpaper aurora";
        break :blk std.fmt.bufPrint(&cmd_buf, "wallpaper {s}", .{img}) catch "wallpaper aurora";
    } else "wallpaper aurora";
    @import("ipc.zig").runCommand(app, cmd);
}

pub fn cycleUser(app: *App, d: i32) void {
    if (st.n_users < 2) return;
    const n: i32 = @intCast(st.n_users);
    st.user = @intCast(@mod(@as(i32, @intCast(st.user)) + d, n));
    applyUser(app);
}

pub fn cycleSession(d: i32) void {
    if (st.n_sessions < 2) return;
    const n: i32 = @intCast(st.n_sessions);
    st.session = @intCast(@mod(@as(i32, @intCast(st.session)) + d, n));
}

pub fn power(reboot: bool) void {
    @import("platform/sys.zig").spawnDetached(if (builtin.os.tag == .freebsd)
        (if (reboot) "shutdown -r now" else "shutdown -p now")
    else if (reboot) "loginctl reboot" else "loginctl poweroff");
}

// ---------------------------------------------------------------------------
// greetd との受け答え(認証の子プロセスの中で呼ぶ。ブロックしてよい)
// ---------------------------------------------------------------------------

/// 顔認証の PAM モジュール(ame-face の pam_face.zig)が最初に出す問い。"face" と答えたときだけカメラで確かめ、
/// ほかの答え(パスワードでのログイン)では何もしない。結果は "ame-face:<理由>" の案内で届く
const FACE_PROMPT = "ame-face";

fn connectGreetd(msg: []u8, msg_len: *usize) ?std.posix.fd_t {
    const sock_path = std.posix.getenv("GREETD_SOCK") orelse {
        setMsg(msg, msg_len, "greetd に接続できません(GREETD_SOCK がありません)");
        return null;
    };
    const fd = std.posix.socket(std.posix.AF.UNIX, std.posix.SOCK.STREAM | std.posix.SOCK.CLOEXEC, 0) catch return null;
    var addr = std.posix.sockaddr.un{ .family = std.posix.AF.UNIX, .path = undefined };
    @memset(&addr.path, 0);
    if (sock_path.len >= addr.path.len) {
        std.posix.close(fd);
        return null;
    }
    @memcpy(addr.path[0..sock_path.len], sock_path);
    std.posix.connect(fd, @ptrCast(&addr), @sizeOf(std.posix.sockaddr.un)) catch {
        std.posix.close(fd);
        setMsg(msg, msg_len, "greetd に接続できません");
        return null;
    };
    return fd;
}

fn createSession(fd: std.posix.fd_t, resp: []u8) ?[]const u8 {
    var req: [256]u8 = undefined;
    var w = std.io.fixedBufferStream(&req);
    w.writer().writeAll("{\"type\":\"create_session\",\"username\":") catch return null;
    jsonStr(w.writer(), userName()) catch return null;
    w.writer().writeAll("}") catch return null;
    return roundTrip(fd, req[0..w.pos], resp);
}

/// 問い(auth_message)の文
fn authText(r: []const u8) []const u8 {
    const key = "\"auth_message\":\"";
    const i = std.mem.indexOf(u8, r, key) orelse return "";
    const rest = r[i + key.len ..];
    const e = std.mem.indexOfScalar(u8, rest, '"') orelse return "";
    return rest[0..e];
}

/// 結果: 1 = 成功(セッションを始めた)、0 = パスワードが違う、2 = その他の失敗(msg に理由)
pub fn authenticate(pw: []const u8, msg: []u8, msg_len: *usize) u8 {
    msg_len.* = 0;
    if (fake()) return if (std.mem.eql(u8, pw, "ame")) 1 else 0;
    const fd = connectGreetd(msg, msg_len) orelse return 2;
    defer std.posix.close(fd);

    var req: [1024]u8 = undefined;
    var resp: [4096]u8 = undefined;
    var w = std.io.fixedBufferStream(&req);
    var r = createSession(fd, &resp) orelse return 2;

    var rounds: usize = 0;
    while (rounds < 8) : (rounds += 1) {
        if (has(r, "\"type\":\"success\"")) break;
        if (has(r, "\"type\":\"error\"")) {
            _ = roundTrip(fd, "{\"type\":\"cancel_session\"}", &resp);
            if (has(r, "auth_error")) return 0;
            setMsg(msg, msg_len, description(r) orelse "ログインできませんでした");
            return 2;
        }
        if (!has(r, "\"type\":\"auth_message\"")) return 2;
        // パスワードなど(secret / visible)には答え、案内(info / error)には空で答える。
        // 顔認証の問いには空で答える(パスワードでログインするので、カメラは使わない)
        w.reset();
        if (std.mem.eql(u8, authText(r), FACE_PROMPT)) {
            w.writer().writeAll("{\"type\":\"post_auth_message_response\",\"response\":\"\"}") catch return 2;
        } else if (has(r, "\"auth_message_type\":\"secret\"") or has(r, "\"auth_message_type\":\"visible\"")) {
            w.writer().writeAll("{\"type\":\"post_auth_message_response\",\"response\":") catch return 2;
            jsonStr(w.writer(), pw) catch return 2;
            w.writer().writeAll("}") catch return 2;
        } else {
            w.writer().writeAll("{\"type\":\"post_auth_message_response\",\"response\":null}") catch return 2;
        }
        r = roundTrip(fd, req[0..w.pos], &resp) orelse return 2;
        @memset(&req, 0); // パスワードを残さない
    }
    if (!has(r, "\"type\":\"success\"")) return 2;
    return startSession(fd, msg, msg_len);
}

/// 顔でログインする。結果: 1 = 成功(セッションを始めた)、0 = 一致しない(msg に理由)、
/// 2 = その他の失敗、3 = この人は顔を登録していない・使えない(何も出さない)、4 = 顔認証の仕組みが入っていない
pub fn authenticateFace(msg: []u8, msg_len: *usize) u8 {
    msg_len.* = 0;
    if (fake()) return 4;
    const fd = connectGreetd(msg, msg_len) orelse return 2;
    defer std.posix.close(fd);
    var resp: [4096]u8 = undefined;
    var r = createSession(fd, &resp) orelse return 2;
    var asked = false;
    var reason: []const u8 = "";
    var reason_buf: [48]u8 = undefined;
    var rounds: usize = 0;
    while (rounds < 8) : (rounds += 1) {
        if (has(r, "\"type\":\"success\"")) return startSession(fd, msg, msg_len);
        if (has(r, "\"type\":\"error\"")) {
            _ = roundTrip(fd, "{\"type\":\"cancel_session\"}", &resp);
            setMsg(msg, msg_len, description(r) orelse "ログインできませんでした");
            return 2;
        }
        if (!has(r, "\"type\":\"auth_message\"")) return 2;
        const text = authText(r);
        var answer: []const u8 = "{\"type\":\"post_auth_message_response\",\"response\":null}";
        if (std.mem.eql(u8, text, FACE_PROMPT)) {
            asked = true;
            answer = "{\"type\":\"post_auth_message_response\",\"response\":\"face\"}";
        } else if (std.mem.startsWith(u8, text, FACE_PROMPT ++ ":")) {
            const s = text[FACE_PROMPT.len + 1 ..];
            const n = @min(s.len, reason_buf.len);
            @memcpy(reason_buf[0..n], s[0..n]);
            reason = reason_buf[0..n];
        } else if (has(r, "\"auth_message_type\":\"secret\"") or has(r, "\"auth_message_type\":\"visible\"")) {
            // 顔では通らず、パスワードを聞かれた: やめる(パスワードは入力欄から改めて)
            _ = roundTrip(fd, "{\"type\":\"cancel_session\"}", &resp);
            if (!asked) return 4;
            if (std.mem.eql(u8, reason, "not-enrolled")) return 3;
            setMsg(msg, msg_len, faceReason(reason));
            return if (std.mem.eql(u8, reason, "no-match")) 0 else 2;
        }
        r = roundTrip(fd, answer, &resp) orelse return 2;
    }
    _ = roundTrip(fd, "{\"type\":\"cancel_session\"}", &resp);
    return 2;
}

fn faceReason(r: []const u8) []const u8 {
    const eq = std.mem.eql;
    if (eq(u8, r, "no-match")) return "顔が一致しませんでした(パスワードを入力してください)";
    if (eq(u8, r, "no-face")) return "顔が見つかりませんでした(パスワードを入力するか、もう一度クリック)";
    if (eq(u8, r, "too-dark")) return "顔が暗すぎます(赤外線の照明が点かないか、顔が遠いようです)";
    if (eq(u8, r, "no-camera")) return "赤外線カメラを開けませんでした";
    if (eq(u8, r, "ir-required")) return "赤外線カメラで登録した顔だけを使います(登録し直してください)";
    if (eq(u8, r, "no-model")) return "顔の認識のモデルがありません(一度ログインして顔を登録し直してください)";
    return "顔認証を使えませんでした";
}

/// セッションを始めてもらう(Exec= を空白で区切った引数)
fn startSession(fd: std.posix.fd_t, msg: []u8, msg_len: *usize) u8 {
    var req: [1024]u8 = undefined;
    var resp: [4096]u8 = undefined;
    var w = std.io.fixedBufferStream(&req);
    w.writer().writeAll("{\"type\":\"start_session\",\"cmd\":[") catch return 2;
    const s = st.sessions[st.session];
    var it = std.mem.tokenizeAny(u8, s.exec[0..s.exec_len], " \t");
    var first = true;
    while (it.next()) |arg| {
        if (std.mem.startsWith(u8, arg, "%")) continue; // %U などのフィールドコード
        if (!first) w.writer().writeByte(',') catch return 2;
        jsonStr(w.writer(), arg) catch return 2;
        first = false;
    }
    w.writer().writeAll("],\"env\":[\"XDG_SESSION_TYPE=wayland\"]}") catch return 2;
    const r = roundTrip(fd, req[0..w.pos], &resp) orelse return 2;
    if (!has(r, "\"type\":\"success\"")) {
        setMsg(msg, msg_len, description(r) orelse "セッションを始められませんでした");
        _ = roundTrip(fd, "{\"type\":\"cancel_session\"}", &resp);
        return 2;
    }
    return 1;
}

fn has(s: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, s, needle) != null;
}

fn setMsg(msg: []u8, len: *usize, s: []const u8) void {
    len.* = @min(s.len, msg.len);
    @memcpy(msg[0..len.*], s[0..len.*]);
}

/// エラーの "description":"…" を取り出す
fn description(r: []const u8) ?[]const u8 {
    const key = "\"description\":\"";
    const i = std.mem.indexOf(u8, r, key) orelse return null;
    const rest = r[i + key.len ..];
    const e = std.mem.indexOfScalar(u8, rest, '"') orelse return null;
    return rest[0..e];
}

/// 長さ(4 バイト、ホストのバイト順)+ JSON を送り、同じ形の返事を受け取る
fn roundTrip(fd: std.posix.fd_t, payload: []const u8, out: []u8) ?[]const u8 {
    var len: u32 = @intCast(payload.len);
    writeAll(fd, std.mem.asBytes(&len)) catch return null;
    writeAll(fd, payload) catch return null;
    var lb: [4]u8 = undefined;
    readAll(fd, &lb) catch return null;
    const n = std.mem.bytesToValue(u32, &lb);
    if (n > out.len) return null;
    readAll(fd, out[0..n]) catch return null;
    return out[0..n];
}

fn writeAll(fd: std.posix.fd_t, b: []const u8) !void {
    var off: usize = 0;
    while (off < b.len) off += try std.posix.write(fd, b[off..]);
}

fn readAll(fd: std.posix.fd_t, b: []u8) !void {
    var off: usize = 0;
    while (off < b.len) {
        const n = try std.posix.read(fd, b[off..]);
        if (n == 0) return error.EndOfStream;
        off += n;
    }
}

fn jsonStr(w: anytype, s: []const u8) !void {
    try w.writeByte('"');
    for (s) |ch| switch (ch) {
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        '\n' => try w.writeAll("\\n"),
        '\r' => try w.writeAll("\\r"),
        '\t' => try w.writeAll("\\t"),
        0...8, 11, 12, 14...0x1f => try w.print("\\u{x:0>4}", .{ch}),
        else => try w.writeByte(ch),
    };
    try w.writeByte('"');
}

test "jsonStr はパスワードの記号を正しく書く" {
    var b: [64]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&b);
    try jsonStr(fbs.writer(), "a\"b\\c\n\x01");
    try std.testing.expectEqualStrings("\"a\\\"b\\\\c\\n\\u0001\"", fbs.getWritten());
}
