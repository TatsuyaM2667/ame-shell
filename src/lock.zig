// ロック画面: ext-session-lock-v1 + PAM。
//
// 閉じ込め防止のため、ロックする「前」に認証が成立し得る構成かを確認する:
//   1. コンポジタが ext_session_lock_manager_v1 を持つ
//   2. libpam.so を dlopen でき、必要な関数がある
//   3. PAM サービス "ame-shell"(無ければ同じ目的の "swaylock")の設定ファイルが存在する
//   4. pam_unix の補助プログラム unix_chkpwd が setuid で存在する(一般ユーザーが照合できる)
// どれかが欠けていればロックせず、OSD と通知で理由を出す。
//
// 認証は fork した子プロセスで行う(PAM の失敗時ディレイでも UI が固まらず、PAM モジュールの
// クラッシュがシェルを巻き込まない)。結果は pipe で 1 バイト返ってくるのを epoll で待つ。
const std = @import("std");
const c = @import("c.zig");
const anim = @import("anim.zig");
const Spring = anim.Spring;
const Color = anim.Color;
const gfx = @import("gfx.zig");
const theme = @import("theme.zig");
const appmod = @import("app.zig");
const App = appmod.App;
const Output = appmod.Output;
const surface = @import("surface.zig");
const ripple = @import("ripple.zig");
const Surface = surface.Surface;
const bar = @import("bar.zig");
const lockui = @import("lockui.zig");
const framedata = @import("frame/data.zig");

// ---- PAM(ヘッダが無くても動くよう ABI を自前で定義し、dlopen で解決する) ----
const PAM_SUCCESS = 0;
const PAM_PROMPT_ECHO_OFF = 1;
const PAM_PROMPT_ECHO_ON = 2;
const PAM_CONV_ERR = 19;
const PamMessage = extern struct { msg_style: c_int, msg: ?[*:0]const u8 };
const PamResponse = extern struct { resp: ?[*:0]u8, resp_retcode: c_int };
const ConvFn = *const fn (c_int, [*c][*c]const PamMessage, [*c][*c]PamResponse, ?*anyopaque) callconv(.C) c_int;
const PamConv = extern struct { conv: ConvFn, appdata_ptr: ?*anyopaque };
const PamStart = *const fn ([*:0]const u8, [*:0]const u8, *const PamConv, *?*anyopaque) callconv(.C) c_int;
const PamAuth = *const fn (?*anyopaque, c_int) callconv(.C) c_int;
const PamEnd = *const fn (?*anyopaque, c_int) callconv(.C) c_int;

const Pam = struct { start: PamStart, auth: PamAuth, acct: PamAuth, end: PamEnd };

const MAX_OUT = 8;

const LockView = struct {
    lock: *Lock,
    out: *Output,
    surf: *Surface,
    /// 水の波紋で解除するときの、このビューの写し(ripple.zig)
    snap: c.GLuint = 0,
};

pub const Lock = struct {
    app: *App,
    session: ?*c.struct_ext_session_lock_v1 = null,
    views: [MAX_OUT]?LockView = [_]?LockView{null} ** MAX_OUT,
    locked: bool = false,
    /// このロックで、ログイン画面(SDDM)用の背景をもう書き出したか(sddmshare.zig)
    sddm_saved: bool = false,
    /// 解除を水の波紋で見せる(Win+L のロック。ログイン画面は別の演出): 写しを取る → オーバーレイ → ロックを外す
    ripple_req: bool = false,
    ripple_started: bool = false,
    /// ログイン画面(greeter.zig)として動いている: 認証は greetd、成功したら ame-shell を終える
    greeter: bool = false,
    pam: ?Pam = null,
    service: [:0]const u8 = "ame-shell",
    /// FreeBSD: パスワード照合の補助(root の setuid の ame-auth)
    auth_helper: ?[:0]const u8 = null,
    pw: [256]u8 = undefined,
    pw_len: usize = 0,
    // 認証の子プロセス
    auth_fd: c_int = -1,
    busy: bool = false,
    msg: [128]u8 = undefined,
    msg_len: usize = 0,
    // アニメーション
    appear: Spring = Spring.init(0, 0.6, 0.85),
    shake: Spring = Spring.init(0, 0.35, 0.25), // 失敗時に横に震える(減衰の弱いバネ)
    dots: [32]Spring = [_]Spring{Spring.init(0, 0.25, 0.55)} ** 32,
    unlock_s: Spring = Spring.init(0, 0.45, 1.0),
    unlocking: bool = false,
    // ---- iOS 風の見た目(lockui.zig)----
    /// 0 = 眺める画面(時計・曲・通知)/ 1 = パスワードの入力画面
    auth: Spring = Spring.init(0, 0.42, 0.9),
    auth_mode: bool = false,
    last_input_ms: u64 = 0,
    time_s: f32 = 0,
    vinyl: f32 = 0,
    media_s: Spring = Spring.init(0, 0.5, 0.85),
    play_s: Spring = Spring.init(0, 0.3, 0.8),
    expand: Spring = Spring.init(0, 0.4, 0.85),
    ring: Spring = Spring.init(0, 0.4, 0.85),
    notif_expanded: bool = false,
    /// これより新しい ID の通知をロック画面に出す(ロックしてから来たもの)
    first_notif_id: u32 = 0,
    cards: [6]lockui.Card = [_]lockui.Card{.{}} ** 6,
    /// 歌詞: 出ている割合と、流れる位置(行の番号)
    lyr_s: Spring = Spring.init(0, 0.45, 0.9),
    lyr_pos: Spring = Spring.init(0, 0.38, 0.82),
    /// ロック画面の歌詞(ダッシュボードと同じ見せ方): 今の行のポップと、歌い終えた行の押し上げ
    lk_pop: Spring = Spring.init(1, 0.38, 0.55),
    lk_scroll: Spring = Spring.init(0, 0.45, 0.9),
    lyr_idx: i32 = -1,
    hits: lockui.Hits = .{},
    spectrum: framedata.Spectrum,

    pub fn create(app: *App) !*Lock {
        const self = try app.alloc.create(Lock);
        self.* = .{ .app = app, .spectrum = .{ .app = app } };
        self.spectrum.ctx = self;
        self.spectrum.on_frame = struct {
            fn f(ctx: *anyopaque) void {
                const l: *Lock = @ptrCast(@alignCast(ctx));
                l.scheduleAll();
            }
        }.f;
        return self;
    }

    fn setMsg(self: *Lock, m: []const u8) void {
        self.msg_len = @min(m.len, self.msg.len);
        @memcpy(self.msg[0..self.msg_len], m[0..self.msg_len]);
    }

    fn exists(path: [:0]const u8) bool {
        return c.access(path.ptr, c.R_OK) == 0;
    }

    /// ロックしてよい構成かを確認し、問題があれば理由を返す
    fn preflight(self: *Lock) ?[]const u8 {
        if (!self.app.cfg.lock_enabled) return "ロックは設定で無効になっています";
        if (self.app.lock_mgr == null) return "コンポジタが ext-session-lock-v1 に未対応のためロックできません";
        // FreeBSD: pam_unix は root でないと照合できないので、setuid の ame-auth に照合してもらう
        if (@import("builtin").os.tag == .freebsd) {
            self.auth_helper = findAuthHelper() orelse return "ame-auth(照合の補助)が入っていません(sh install.sh で入れ直してください)";
            if (!exists("/usr/local/etc/pam.d/ame-shell") and !exists("/etc/pam.d/ame-shell"))
                return "PAM サービス ame-shell が未インストールです(sh install.sh で入れ直してください)";
            return null;
        }
        if (self.pam == null) {
            const h = c.dlopen("libpam.so.0", c.RTLD_NOW) orelse c.dlopen("libpam.so", c.RTLD_NOW) orelse return "libpam が見つからないためロックできません";
            const s = c.dlsym(h, "pam_start") orelse return "libpam が不完全です";
            const a = c.dlsym(h, "pam_authenticate") orelse return "libpam が不完全です";
            const ac = c.dlsym(h, "pam_acct_mgmt") orelse return "libpam が不完全です";
            const e = c.dlsym(h, "pam_end") orelse return "libpam が不完全です";
            self.pam = .{ .start = @ptrCast(s), .auth = @ptrCast(a), .acct = @ptrCast(ac), .end = @ptrCast(e) };
        }
        // サービス設定: /etc/pam.d が優先、無ければ /usr/lib/pam.d(Chimera はこちら)
        if (exists("/etc/pam.d/ame-shell") or exists("/usr/lib/pam.d/ame-shell")) {
            self.service = "ame-shell";
        } else if (exists("/etc/pam.d/swaylock") or exists("/usr/lib/pam.d/swaylock")) {
            std.log.info("lock: PAM サービス ame-shell が未インストールのため swaylock の設定を使います", .{});
            self.service = "swaylock";
        } else return "PAM サービス ame-shell が未インストールです(install-session.sh を実行してください)";
        // pam_unix はパスワード照合に setuid の unix_chkpwd を使う
        var found = false;
        for ([_][:0]const u8{ "/usr/bin/unix_chkpwd", "/usr/sbin/unix_chkpwd", "/sbin/unix_chkpwd" }) |p| {
            const st = std.posix.fstatat(std.posix.AT.FDCWD, p, 0) catch continue;
            if (st.mode & std.posix.S.ISUID != 0) found = true;
        }
        if (!found) return "unix_chkpwd(setuid)が無いため、一般ユーザーでは認証できません";
        return null;
    }

    pub fn lock(self: *Lock) []const u8 {
        if (self.locked) return "ok (already locked)";
        // FreeBSD の pam_unix は root でないとパスワードを照合できない(Linux の unix_chkpwd に当たる補助が無い)。
        // FreeBSD の swaylock パッケージは setuid で入るので、ロックはそれに任せる
        // ame-auth(root の setuid の照合の補助)が入っていれば、Linux と同じ ame-shell のロック画面を使う
        if (@import("builtin").os.tag == .freebsd and findAuthHelper() == null) {
            if (!@import("platform/sys.zig").hasCommand("swaylock")) {
                const why = "FreeBSD ではロックに swaylock が必要です(pkg install swaylock)";
                self.app.osd.info(why);
                return "error: swaylock not found";
            }
            @import("platform/sys.zig").spawnDetached("swaylock -f -c 0b1020");
            return "ok (swaylock)";
        }
        if (self.preflight()) |why| {
            std.log.warn("lock: {s}", .{why});
            self.app.osd.info(why);
            self.app.notifs.post("ame-shell", "画面をロックできません", why, 0);
            return "error: lock unavailable (see notification)";
        }
        if (!self.startSession()) return "error: lock request failed";
        return "ok";
    }

    /// ログイン画面として始める(greetd から AME_GREETER=1 で起動されたとき。App.init から)
    pub fn greet(self: *Lock) void {
        self.greeter = true;
        // ログインの成功で穴が広がる演出は、ゆっくり見せる
        self.unlock_s.response = 0.9;
        if (self.app.lock_mgr == null or !self.startSession()) {
            std.log.err("greeter: コンポジタが ext-session-lock-v1 に未対応のため、ログイン画面を出せません", .{});
            self.app.running = false;
        }
    }

    fn startSession(self: *Lock) bool {
        const sess = c.ext_session_lock_manager_v1_lock(self.app.lock_mgr) orelse return false;
        self.session = sess;
        _ = c.ext_session_lock_v1_add_listener(sess, &session_listener, self);
        self.locked = true;
        self.sddm_saved = false;
        self.unlocking = false;
        self.pw_len = 0;
        self.msg_len = 0;
        self.appear.snap(0);
        self.appear.set(1);
        self.auth.snap(0);
        self.auth_mode = false;
        self.notif_expanded = false;
        self.expand.snap(0);
        self.media_s.snap(0);
        self.play_s.snap(if (self.app.media.status == .playing) 1 else 0);
        self.first_notif_id = self.app.notifs.next_id;
        for (&self.cards) |*cd| cd.* = .{};
        self.updateSpectrum();
        self.unlock_s.snap(0);
        for (self.app.outputs.items, 0..) |o, i| {
            if (i >= MAX_OUT) break;
            const s = Surface.createLock(self.app, .{ .ctx = self, .draw = draw, .key = key, .pointer = pointer }, sess, o.wl) catch continue;
            s.output = o;
            self.views[i] = .{ .lock = self, .out = o, .surf = s };
        }
        // ランチャー等は閉じておく(ロック解除後に開いたままにならないように)
        self.app.launcher.close();
        self.app.dashboard.close();
        return true;
    }

    pub fn scheduleAll(self: *Lock) void {
        for (self.views) |v| if (v) |vv| vv.surf.schedule();
    }

    pub fn tick(self: *Lock) void {
        if (!self.locked) return;
        // 入力画面のまま 12 秒触らなければ、眺める画面にもどる
        if (self.auth_mode and self.pw_len == 0 and !self.busy and @import("platform/loop.zig").nowMs() -| self.last_input_ms > 12_000) self.setAuth(false);
        self.updateSpectrum();
        self.scheduleAll();
    }

    fn finish(self: *Lock, unlock: bool) void {
        self.spectrum.stop();
        for (&self.views) |*v| {
            if (v.*) |vv| vv.surf.destroy();
            v.* = null;
        }
        if (self.session) |s| {
            if (unlock) c.ext_session_lock_v1_unlock_and_destroy(s) else c.ext_session_lock_v1_destroy(s);
        }
        self.session = null;
        self.locked = false;
        @memset(&self.pw, 0); // パスワードはメモリに残さない
        self.pw_len = 0;
        _ = c.wl_display_flush(self.app.display);
    }

    pub fn reap(self: *Lock) void {
        if (self.unlocking and self.ripple_req) {
            if (!self.ripple_started) {
                // すべての出力の写しがそろったら、同じ絵を映すオーバーレイを出す
                var snaps: [MAX_OUT]ripple.Snap = undefined;
                var n: usize = 0;
                for (self.views) |v| if (v) |vv| {
                    if (vv.snap == 0) return;
                    const sc: c_int = @max(vv.surf.scale, 1);
                    snaps[n] = .{ .out = vv.out, .tex = vv.snap, .w = @as(c_int, @intCast(vv.surf.width)) * sc, .h = @as(c_int, @intCast(vv.surf.height)) * sc };
                    n += 1;
                };
                self.ripple_started = true;
                for (&self.views) |*v| if (v.*) |*vv| {
                    vv.snap = 0; // テクスチャは ripple.zig が持つ
                };
                if (!ripple.start(self.app, snaps[0..n])) {
                    // オーバーレイを出せない: いつもの消え方で外す
                    for (snaps[0..n]) |sn| {
                        var t = sn.tex;
                        c.glDeleteTextures(1, &t);
                    }
                    self.ripple_req = false;
                    self.unlock_s.set(1);
                    self.scheduleAll();
                }
                return;
            }
            // オーバーレイが描けた(見た目はロック画面と同じ)ので、ロックを外して波紋を始める
            if (!ripple.ready()) return;
            self.ripple_req = false;
            self.ripple_started = false;
            self.unlocking = false;
            self.finish(true);
            ripple.begin();
            return;
        }
        if (self.unlocking and self.unlock_s.x > 0.98) {
            self.unlocking = false;
            self.finish(true);
            // ログイン画面: セッションは greetd が始める。ame-shell(と River)は終わる
            if (self.greeter) self.app.running = false;
        }
    }

    // ---- 認証(子プロセス) ----

    fn startAuth(self: *Lock) void {
        if (self.busy or self.pw_len == 0) return;
        var fds: [2]c_int = undefined;
        if (c.pipe2(&fds, c.O_CLOEXEC) != 0) return;
        const pid = c.fork();
        if (pid < 0) {
            _ = c.close(fds[0]);
            _ = c.close(fds[1]);
            return;
        }
        if (pid == 0) {
            _ = c.close(fds[0]);
            if (self.greeter) {
                // greetd に認証とセッションの開始を頼む。結果 1 バイト + 失敗の理由
                var m: [160]u8 = undefined;
                var ml: usize = 0;
                const r = @import("greeter.zig").authenticate(self.pw[0..self.pw_len], &m, &ml);
                @memset(&self.pw, 0);
                var out: [161]u8 = undefined;
                out[0] = r;
                @memcpy(out[1 .. 1 + ml], m[0..ml]);
                _ = c.write(fds[1], &out, 1 + ml);
                c._exit(0);
            }
            // 試験用: 入れ子の試験セッション(AME_SESSION_NESTED=1)で AME_LOCK_FAKE=1 のときだけ、パスワード "ame" で解除できる
            const fake = std.posix.getenv("AME_LOCK_FAKE") != null and
                std.mem.eql(u8, std.posix.getenv("AME_SESSION_NESTED") orelse "", "1");
            const ok = if (fake) std.mem.eql(u8, self.pw[0..self.pw_len], "ame") else if (self.auth_helper) |hp| self.helperCheck(hp) else self.pamCheck();
            const b: u8 = if (ok) 1 else 0;
            _ = c.write(fds[1], &b, 1);
            c._exit(0);
        }
        _ = c.close(fds[1]);
        // 親は自分のコピーを消す(子は自分のメモリで使い終わる)
        @memset(&self.pw, 0);
        self.auth_fd = fds[0];
        self.busy = true;
        self.setMsg("確認しています…");
        self.app.loop.add(fds[0], c.EPOLLIN | c.EPOLLHUP, self, onAuthDone) catch {};
        self.scheduleAll();
    }

    /// FreeBSD: setuid の ame-auth にパスワードを標準入力で渡して照合してもらう(認証の子プロセスの中で呼ぶ)
    fn helperCheck(self: *Lock, helper: [:0]const u8) bool {
        // ame-shell は SIGCHLD を無視している。待てるように既定に戻す(この子プロセスの中だけ)
        @import("platform/sys.zig").childDefaults();
        var p: [2]c_int = undefined;
        if (c.pipe(&p) != 0) return false;
        const pid = c.fork();
        if (pid < 0) return false;
        if (pid == 0) {
            _ = c.dup2(p[0], 0);
            _ = c.close(p[0]);
            _ = c.close(p[1]);
            const argv = [_:null]?[*:0]const u8{ helper.ptr, null };
            const envp = [_:null]?[*:0]const u8{null};
            _ = c.execve(helper.ptr, @ptrCast(&argv), @ptrCast(&envp));
            c._exit(2);
        }
        _ = c.close(p[0]);
        _ = c.write(p[1], &self.pw, self.pw_len);
        _ = c.close(p[1]);
        @memset(&self.pw, 0);
        var status: c_int = 0;
        if (c.waitpid(pid, &status, 0) != pid) return false;
        return c.WIFEXITED(status) and c.WEXITSTATUS(status) == 0;
    }

    fn pamCheck(self: *Lock) bool {
        const pam = self.pam orelse return false;
        var user_buf: [64]u8 = undefined;
        const user = currentUser(&user_buf) orelse return false;
        const conv = PamConv{ .conv = pamConv, .appdata_ptr = self };
        var h: ?*anyopaque = null;
        if (pam.start(self.service.ptr, user.ptr, &conv, &h) != PAM_SUCCESS) return false;
        var r = pam.auth(h, 0);
        if (r == PAM_SUCCESS) r = pam.acct(h, 0);
        _ = pam.end(h, r);
        return r == PAM_SUCCESS;
    }

    fn onAuthDone(ctx: *anyopaque, fd: c_int, _: u32) void {
        const self: *Lock = @ptrCast(@alignCast(ctx));
        var buf: [161]u8 = undefined;
        const n = c.read(fd, &buf, buf.len);
        const b: u8 = if (n >= 1) buf[0] else 0;
        self.app.loop.remove(fd);
        _ = c.close(fd);
        self.auth_fd = -1;
        self.busy = false;
        self.pw_len = 0;
        if (n >= 1 and b == 1) {
            if (self.greeter) @import("greeter.zig").saveLastUser();
            self.setMsg("ようこそ");
            self.unlocking = true;
            if (self.greeter) {
                self.unlock_s.set(1);
            } else {
                self.ripple_req = true;
                self.ripple_started = false;
            }
        } else if (n > 1 and b == 2) {
            // greetd の失敗(パスワード以外)
            self.setMsg(buf[1..@intCast(n)]);
            self.shake.kick(420);
        } else {
            self.setMsg("パスワードが違います");
            self.shake.kick(420);
        self.last_input_ms = @import("platform/loop.zig").nowMs();
        }
        self.scheduleAll();
    }

    // ---- 入力 ----

    fn key(ctx: *anyopaque, _: *Surface, ev: surface.KeyEvent) void {
        const self: *Lock = @ptrCast(@alignCast(ctx));
        if (self.busy or self.unlocking) return;
        self.last_input_ms = @import("platform/loop.zig").nowMs();
        // 眺める画面: どのキーでも入力画面へ(文字ならそのまま 1 文字目として入れる)
        if (!self.auth_mode) {
            if (ev.sym == c.XKB_KEY_Escape) return;
            self.setAuth(true);
        }
        switch (ev.sym) {
            c.XKB_KEY_Return, c.XKB_KEY_KP_Enter => self.startAuth(),
            c.XKB_KEY_Escape => {
                // 空なら眺める画面へもどる
                if (self.pw_len == 0) self.setAuth(false);
                @memset(&self.pw, 0);
                self.pw_len = 0;
                for (&self.dots) |*d| d.set(0);
            },
            c.XKB_KEY_BackSpace => {
                if (self.pw_len > 0) {
                    var i = self.pw_len - 1;
                    while (i > 0 and (self.pw[i] & 0xC0) == 0x80) i -= 1;
                    self.pw_len = i;
                }
            },
            else => {
                if (ev.utf8.len > 0 and ev.utf8[0] >= 0x20 and self.pw_len + ev.utf8.len < self.pw.len - 1) {
                    @memcpy(self.pw[self.pw_len .. self.pw_len + ev.utf8.len], ev.utf8);
                    self.pw_len += ev.utf8.len;
                    self.msg_len = 0;
                }
            },
        }
        self.scheduleAll();
    }

    fn pointer(ctx: *anyopaque, _: *Surface, ev: surface.PointerEvent) void {
        const self: *Lock = @ptrCast(@alignCast(ctx));
        if (ev.kind != .press or self.busy or self.unlocking) return;
        self.last_input_ms = @import("platform/loop.zig").nowMs();
        // ログイン画面のボタン(どちらの画面でも)
        if (self.greeter) {
            const g = @import("greeter.zig");
            switch (self.hits.which(ev.x, ev.y)) {
                .uprev, .unext => |h| {
                    g.cycleUser(self.app, if (h == .uprev) -1 else 1);
                    self.msg_len = 0;
                    self.scheduleAll();
                    return;
                },
                .session => {
                    g.cycleSession(1);
                    self.scheduleAll();
                    return;
                },
                .reboot => return g.power(true),
                .poweroff => return g.power(false),
                else => {},
            }
        }
        if (!self.auth_mode) {
            switch (self.hits.which(ev.x, ev.y)) {
                .prev => self.app.media.prev(),
                .play => self.app.media.toggle(),
                .next => self.app.media.next(),
                .stack => self.notif_expanded = !self.notif_expanded,
                .uprev, .unext, .session, .reboot, .poweroff => {},
                .none => self.setAuth(true),
            }
        } else if (ev.button == 0x111 and self.pw_len == 0) self.setAuth(false); // 右クリックでもどる
        self.scheduleAll();
    }

    fn setAuth(self: *Lock, on: bool) void {
        self.auth_mode = on;
        self.auth.set(if (on) 1 else 0);
        if (on) self.last_input_ms = @import("platform/loop.zig").nowMs();
        self.updateSpectrum();
        self.scheduleAll();
    }

    /// 眺める画面で曲が流れている間だけ、音を拾ってスペクトラムを計算する
    fn updateSpectrum(self: *Lock) void {
        const want = self.locked and !self.auth_mode and !self.unlocking and self.app.media.status == .playing;
        if (want and !self.spectrum.running()) self.spectrum.start();
        if (!want and self.spectrum.running()) self.spectrum.stop();
    }

    /// 通知が来た(notify.zig から)。ロック画面のカードを出す
    pub fn notified(self: *Lock, id: u32) void {
        if (!self.locked) return;
        // 一番古いカードの枠を使い回す
        var slot: usize = 0;
        for (self.cards, 0..) |cd, i| if (cd.id < self.cards[slot].id) {
            slot = i;
        };
        self.cards[slot] = .{ .id = id };
        self.cards[slot].s.snap(0);
        self.cards[slot].s.set(1);
        self.scheduleAll();
    }

    /// その通知のカードが出てくる途中か(0 → 1)。見つからなければ出きっている
    pub fn cardSpring(self: *const Lock, id: u32) f32 {
        for (self.cards) |cd| if (cd.id == id) return cd.s.x;
        return 1;
    }

    /// 入力画面に出す名前(ログイン画面では選んでいるユーザー)
    pub fn userName(self: *const Lock, buf: []u8) []const u8 {
        if (self.greeter) return @import("greeter.zig").userName();
        return currentUserName(buf);
    }

    pub fn isError(self: *const Lock) bool {
        return std.mem.startsWith(u8, self.msg[0..self.msg_len], "パスワードが違います");
    }

    // ---- 描画 ----

    fn countChars(s: []const u8) usize {
        var n: usize = 0;
        for (s) |ch| {
            if ((ch & 0xC0) != 0x80) n += 1;
        }
        return n;
    }

    fn draw(ctx: *anyopaque, s: *Surface, cv: *gfx.Canvas, dt: f32) bool {
        const self: *Lock = @ptrCast(@alignCast(ctx));
        const app = self.app;
        // 複数出力で同じスプリングを何度も進めないよう、最初のビューだけが時間を進める
        const primary = if (self.views[0]) |v| v.surf == s else true;
        var animating = false;
        const n = @min(countChars(self.pw[0..self.pw_len]), self.dots.len);
        for (&self.dots, 0..) |*d, i| d.set(if (i < n) 1 else 0);
        if (primary) {
            var springs = [_]*Spring{ &self.appear, &self.shake, &self.unlock_s };
            if (anim.stepAll(&springs, dt)) animating = true;
            for (&self.dots) |*d| if (d.step(dt)) {
                animating = true;
            };
        } else {
            animating = self.appear.moving() or self.shake.moving() or self.unlock_s.moving();
            for (self.dots) |d| animating = animating or d.moving();
        }
        if (self.unlocking and self.unlock_s.x > 0.98) app.reap_pending = true;

        const out: ?*Output = for (self.views) |v| {
            if (v) |vv| if (vv.surf == s) break vv.out;
        } else null;
        // 壁紙のシーンをロック画面から進める(オーロラが動き続ける。wallpaper.zig)
        if (out) |o| if (o.wall) |w| {
            w.advanceForLock(dt);
            // 壁紙の描画で変わった描き先の大きさを、このサーフェスに戻す
            c.glBindFramebuffer(c.GL_FRAMEBUFFER, 0);
            c.glViewport(0, 0, @intFromFloat(@as(f32, @floatFromInt(s.width)) * cv.scale), @intFromFloat(@as(f32, @floatFromInt(s.height)) * cv.scale));
        };
        const out_bd: ?*gfx.Backdrop = if (out) |o| &o.backdrop else null;
        if (lockui.draw(self, s, out_bd, cv, primary, dt)) animating = true;
        // 水の波紋で解除: 描き終えた絵を写し取る(次のループで ripple.zig がオーバーレイに映す)
        if (self.ripple_req and !self.ripple_started) for (&self.views) |*v| if (v.*) |*vv| if (vv.surf == s and vv.snap == 0) {
            cv.flush();
            const sc: c_int = @max(s.scale, 1);
            vv.snap = ripple.capture(@as(c_int, @intCast(s.width)) * sc, @as(c_int, @intCast(s.height)) * sc);
            app.reap_pending = true;
        };
        return animating or self.busy;
    }
};

/// FreeBSD: root が持ち主で setuid の ame-auth を探す(install-session.sh が libexec に入れる)
fn findAuthHelper() ?[:0]const u8 {
    for ([_][:0]const u8{ "/usr/local/libexec/ame-shell/ame-auth", "/usr/libexec/ame-shell/ame-auth" }) |p| {
        const st = std.posix.fstatat(std.posix.AT.FDCWD, p, 0) catch continue;
        if (st.mode & std.posix.S.ISUID != 0 and st.uid == 0) return p;
    }
    return null;
}

/// 今のユーザー名(無ければ空)
pub fn currentUserName(buf: []u8) []const u8 {
    return currentUser(buf) orelse "";
}

fn currentUser(buf: []u8) ?[:0]const u8 {
    const u = std.posix.getenv("USER") orelse std.posix.getenv("LOGNAME") orelse return null;
    return std.fmt.bufPrintZ(buf, "{s}", .{u}) catch null;
}

/// PAM の会話関数: パスワード入力を求められたら(子プロセス内の)バッファを渡す
fn pamConv(num: c_int, msgs: [*c][*c]const PamMessage, resp: [*c][*c]PamResponse, data: ?*anyopaque) callconv(.C) c_int {
    const self: *Lock = @ptrCast(@alignCast(data orelse return PAM_CONV_ERR));
    if (num <= 0) return PAM_CONV_ERR;
    const n: usize = @intCast(num);
    const arr: [*]PamResponse = @ptrCast(@alignCast(c.calloc(n, @sizeOf(PamResponse)) orelse return PAM_CONV_ERR));
    for (0..n) |i| {
        const m = msgs[i];
        if (m.*.msg_style == PAM_PROMPT_ECHO_OFF or m.*.msg_style == PAM_PROMPT_ECHO_ON) {
            self.pw[self.pw_len] = 0;
            arr[i].resp = @ptrCast(c.strdup(@ptrCast(&self.pw)));
        }
    }
    resp.* = @ptrCast(arr);
    return PAM_SUCCESS;
}

fn onLocked(_: ?*anyopaque, _: ?*c.struct_ext_session_lock_v1) callconv(.C) void {
    std.log.info("lock: ロックしました", .{});
}
fn onFinished(data: ?*anyopaque, _: ?*c.struct_ext_session_lock_v1) callconv(.C) void {
    // コンポジタがロックを拒否した/他のロッカーが動いている
    const self: *Lock = @ptrCast(@alignCast(data.?));
    std.log.warn("lock: コンポジタがロックを終了しました", .{});
    self.finish(false);
}
const session_listener = c.struct_ext_session_lock_v1_listener{ .locked = onLocked, .finished = onFinished };
