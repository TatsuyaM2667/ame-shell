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
const Surface = surface.Surface;
const bar = @import("bar.zig");

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
};

pub const Lock = struct {
    app: *App,
    session: ?*c.struct_ext_session_lock_v1 = null,
    views: [MAX_OUT]?LockView = [_]?LockView{null} ** MAX_OUT,
    locked: bool = false,
    pam: ?Pam = null,
    service: [:0]const u8 = "ame-shell",
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

    pub fn create(app: *App) !*Lock {
        const self = try app.alloc.create(Lock);
        self.* = .{ .app = app };
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
        if (self.preflight()) |why| {
            std.log.warn("lock: {s}", .{why});
            self.app.osd.info(why);
            self.app.notifs.post("ame-shell", "画面をロックできません", why, 0);
            return "error: lock unavailable (see notification)";
        }
        const sess = c.ext_session_lock_manager_v1_lock(self.app.lock_mgr) orelse return "error: lock request failed";
        self.session = sess;
        _ = c.ext_session_lock_v1_add_listener(sess, &session_listener, self);
        self.locked = true;
        self.unlocking = false;
        self.pw_len = 0;
        self.msg_len = 0;
        self.appear.snap(0);
        self.appear.set(1);
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
        return "ok";
    }

    fn scheduleAll(self: *Lock) void {
        for (self.views) |v| if (v) |vv| vv.surf.schedule();
    }

    pub fn tick(self: *Lock) void {
        if (self.locked) self.scheduleAll();
    }

    fn finish(self: *Lock, unlock: bool) void {
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
        if (self.unlocking and self.unlock_s.x > 0.98) {
            self.unlocking = false;
            self.finish(true);
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
            const ok = self.pamCheck();
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
        var b: u8 = 0;
        const n = c.read(fd, &b, 1);
        self.app.loop.remove(fd);
        _ = c.close(fd);
        self.auth_fd = -1;
        self.busy = false;
        self.pw_len = 0;
        if (n == 1 and b == 1) {
            self.setMsg("ようこそ");
            self.unlocking = true;
            self.unlock_s.set(1);
        } else {
            self.setMsg("パスワードが違います");
            self.shake.kick(420);
        }
        self.scheduleAll();
    }

    // ---- 入力 ----

    fn key(ctx: *anyopaque, _: *Surface, ev: surface.KeyEvent) void {
        const self: *Lock = @ptrCast(@alignCast(ctx));
        if (self.busy or self.unlocking) return;
        switch (ev.sym) {
            c.XKB_KEY_Return, c.XKB_KEY_KP_Enter => self.startAuth(),
            c.XKB_KEY_Escape => {
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

    fn pointer(_: *anyopaque, _: *Surface, _: surface.PointerEvent) void {}

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

        const W: f32 = @floatFromInt(s.width);
        const H: f32 = @floatFromInt(s.height);
        const acc = theme.accent(app);
        const txt = theme.text(app);
        const sub = theme.subtext(app);
        const t = self.appear.x * (1 - self.unlock_s.x);

        // 背景: 壁紙のブラー(ロック画面は不透明でなければならないので下地を必ず塗る)
        cv.rect(0, 0, W, H, 0, Color.hex(0x050a18));
        var gl = theme.glass(app);
        gl.tint.a = 0.25;
        gl.rim.a = 0;
        gl.refraction = 0;
        gl.sparkle = 1.0;
        cv.glass(0, 0, W, H, 0, gl);
        cv.rect(0, 0, W, H, 0, Color.hex(0x000000).alpha(0.25 * (1 - t)));

        cv.save();
        cv.translate(0, (1 - t) * 30 - self.unlock_s.x * 60);
        cv.opacity(t);
        // 時計
        var cb: [16]u8 = undefined;
        const clock = bar.formatClock(&cb, app.cfg.clock_24h, false);
        _ = cv.text(W / 2, H * 0.36, 112, txt, clock, .{ .bold = true, .alignment = .center, .glow = 14, .glow_color = acc.alpha(0.5) });
        var db: [64]u8 = undefined;
        _ = cv.text(W / 2, H * 0.36 + 46, 20, sub, bar.formatDate(&db), .{ .alignment = .center });

        // パスワード欄
        const fw: f32 = 340;
        const fh: f32 = 56;
        const fx = W / 2 - fw / 2 + self.shake.x;
        const fy = H * 0.58;
        // ユーザーの写真(あれば)
        const av = app.avatar.texture();
        if (av != 0) {
            const az: f32 = 64;
            cv.shadow(W / 2 - az / 2, fy - az - 14, az, az, az / 2, 16, theme.shadow());
            cv.image(av, W / 2 - az / 2, fy - az - 18, az, az, az / 2);
            cv.rectBorder(W / 2 - az / 2 - 1, fy - az - 19, az + 2, az + 2, az / 2 + 1, .{ .a = 0 }, acc.alpha(0.8), 2);
        }
        cv.shadow(fx, fy + 8, fw, fh, fh / 2, 22, theme.shadow());
        cv.glass(fx, fy, fw, fh, fh / 2, theme.glassStrong(app));
        if (self.busy) cv.rectBorder(fx, fy, fw, fh, fh / 2, .{ .a = 0 }, acc.alpha(0.8), 1.5);
        var ub: [64]u8 = undefined;
        const user = currentUser(&ub) orelse "";
        if (n == 0 and !self.busy) {
            _ = cv.text(W / 2, fy + fh / 2 + 6, 15, sub.alpha(0.8), if (user.len > 0) user else "パスワード", .{ .alignment = .center });
        }
        // 文字数ぶんの丸がポップする(実際の文字は出さない)
        const spacing: f32 = 18;
        const shown = @min(n + 1, self.dots.len);
        const total = @as(f32, @floatFromInt(n)) * spacing;
        for (0..shown) |i| {
            const d = self.dots[i].x;
            if (d < 0.01) continue;
            const dx = fx + fw / 2 - total / 2 + @as(f32, @floatFromInt(i)) * spacing + spacing / 2;
            const rr = 5 * d;
            cv.rect(dx - rr, fy + fh / 2 - rr, rr * 2, rr * 2, rr, acc.lighten(0.3));
        }
        if (self.msg_len > 0) {
            const err = std.mem.startsWith(u8, self.msg[0..self.msg_len], "パスワードが違います");
            _ = cv.text(W / 2, fy + fh + 34, 14, if (err) theme.danger(app).lighten(0.18) else sub, self.msg[0..self.msg_len], .{ .alignment = .center });
        }
        cv.restore();
        return animating or self.busy;
    }
};

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
