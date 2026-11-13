// ame-yatagarasu: URL の中身を取ってくる(curl の代わり。ame-shell の道具が使う curl のオプションをそのまま読む)。
// 名前は遠くへ道案内をし、ものを運ぶ八咫烏(やたがらす)から。
//
//   ame-yatagarasu [オプション] URL       中身を標準出力へ(-o で ファイルへ)
//     -s / -S / -N           (curl と同じ書き方を受け付ける。出力はいつも届いた分からすぐ書く)
//     -f                     HTTP の 400 以上なら中身を書かずに 22 で終わる
//     -L                     転送(3xx)をたどる(10 回まで)
//     -o ファイル             中身をファイルへ
//     -A 名前 / -H "名前: 値" / -X メソッド
//     -d / --data-binary 文字 | @ファイル / --data-urlencode 名前=中身   本文を送る(既定のメソッドは POST。2 つ目からは & でつなぐ)
//     -G                     本文を URL の ? の後ろに付けて GET で送る
//     -w 書式                 最後に書く(%{http_code} を状態コードに置き換える)
//     -K -                    設定を標準入力から(url / header / data-binary / user-agent / request = "値")
//     --max-time 秒 / --connect-timeout 秒 / --max-filesize バイト
//
// HTTP/1.1 は自分で話し、暗号(TLS 1.2 / 1.3)とサーバの証明書の確認は OpenSSL(libssl)に任せる。
// 圧縮は頼まない(Accept-Encoding を送らない)。
// 終了コード(curl と同じ番号): 0 取れた / 2 使い方 / 3 URL が変 / 6 名前を引けない / 7 つながらない /
//   22 -f で HTTP の誤り / 23 書けない / 28 時間切れ / 35 暗号の握手に失敗 / 47 転送が多すぎる / 56 受け取りに失敗 /
//   60 証明書が正しくない / 63 --max-filesize を超えた
const std = @import("std");

// ---------------- OpenSSL(使う関数だけ。ヘッダのマクロに頼らない) ----------------

const SSL = opaque {};
const SSL_CTX = opaque {};
const SSL_METHOD = opaque {};
extern fn TLS_client_method() ?*const SSL_METHOD;
extern fn SSL_CTX_new(m: ?*const SSL_METHOD) ?*SSL_CTX;
extern fn SSL_CTX_set_default_verify_paths(ctx: *SSL_CTX) c_int;
extern fn SSL_CTX_set_verify(ctx: *SSL_CTX, mode: c_int, cb: ?*anyopaque) void;
extern fn SSL_CTX_ctrl(ctx: *SSL_CTX, cmd: c_int, larg: c_long, parg: ?*anyopaque) c_long;
extern fn SSL_new(ctx: *SSL_CTX) ?*SSL;
extern fn SSL_ctrl(s: *SSL, cmd: c_int, larg: c_long, parg: ?*anyopaque) c_long;
extern fn SSL_set1_host(s: *SSL, host: [*:0]const u8) c_int;
extern fn SSL_set_fd(s: *SSL, fd: c_int) c_int;
extern fn SSL_connect(s: *SSL) c_int;
extern fn SSL_read(s: *SSL, buf: [*]u8, n: c_int) c_int;
extern fn SSL_write(s: *SSL, buf: [*]const u8, n: c_int) c_int;
extern fn SSL_get_error(s: *SSL, ret: c_int) c_int;
extern fn SSL_get_verify_result(s: *SSL) c_long;
extern fn SSL_free(s: *SSL) void;
const SSL_VERIFY_PEER = 1;
const SSL_CTRL_SET_TLSEXT_HOSTNAME = 55;
const SSL_CTRL_SET_MIN_PROTO_VERSION = 123;
const TLS1_2_VERSION = 0x0303;
const SSL_ERROR_ZERO_RETURN = 6;
const SSL_ERROR_SYSCALL = 5;

extern "c" fn alarm(secs: c_uint) c_uint;

// ---------------- 終わり方 ----------------

var show_errors = true;

fn die(code: u8, comptime fmt: []const u8, args: anytype) noreturn {
    if (show_errors) std.io.getStdErr().writer().print("ame-yatagarasu: " ++ fmt ++ "\n", args) catch {};
    std.process.exit(code);
}

fn onAlarm(_: c_int) callconv(.C) void {
    const msg = "ame-yatagarasu: 時間切れ\n";
    if (show_errors) _ = std.posix.write(2, msg) catch {};
    std.posix.exit(28);
}

// ---------------- オプション ----------------

const Opts = struct {
    url: []const u8 = "",
    method: ?[]const u8 = null,
    headers: std.ArrayList([]const u8),
    data: ?[]const u8 = null,
    out: ?[]const u8 = null,
    ua: []const u8 = "ame-yatagarasu/1",
    fail: bool = false,
    follow: bool = false,
    write_out: ?[]const u8 = null,
    max_time: u32 = 0,
    connect_timeout: u32 = 0,
    max_filesize: u64 = 0,
    /// -G: 本文を URL の ? の後ろに付けて GET で送る
    get: bool = false,
};

fn usage() noreturn {
    std.io.getStdErr().writeAll("使い方: ame-yatagarasu [-sSfLNG] [-o ファイル] [-A 名前] [-H ヘッダ] [-X メソッド] [-d 本文] [-w 書式] [-K -] [--max-time 秒] [--connect-timeout 秒] [--max-filesize バイト] URL\n") catch {};
    std.process.exit(2);
}

fn num(s: []const u8) u64 {
    // curl は秒に小数も許す(切り上げる)
    const f = std.fmt.parseFloat(f64, s) catch usage();
    if (f < 0) usage();
    return @intFromFloat(@ceil(f));
}

/// 本文: @ファイル ならその中身
fn dataArg(a: std.mem.Allocator, v: []const u8) []const u8 {
    if (v.len > 1 and v[0] == '@') {
        return std.fs.cwd().readFileAlloc(a, v[1..], 1 << 30) catch die(26, "本文のファイルを読めません: {s}", .{v[1..]});
    }
    return v;
}

/// 本文を足す(curl と同じく、2 つ目からは & でつなぐ)
fn addData(a: std.mem.Allocator, o: *Opts, part: []const u8) void {
    o.data = if (o.data) |d| (std.mem.concat(a, u8, &.{ d, "&", part }) catch d) else part;
}

/// --data-urlencode の「名前=中身」: 中身だけを % で逃がす(= が無ければ全部)
fn urlencodeArg(a: std.mem.Allocator, v: []const u8) []const u8 {
    const eqp = std.mem.indexOfScalar(u8, v, '=');
    const name = if (eqp) |p| v[0 .. p + 1] else "";
    const content = if (eqp) |p| v[p + 1 ..] else v;
    var out = std.ArrayList(u8).init(a);
    out.appendSlice(name) catch {};
    for (content) |ch| {
        if (std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '_' or ch == '.' or ch == '~') {
            out.append(ch) catch {};
        } else out.writer().print("%{X:0>2}", .{ch}) catch {};
    }
    return out.items;
}

fn apply(a: std.mem.Allocator, o: *Opts, name: []const u8, v: []const u8) void {
    const eq = std.mem.eql;
    if (eq(u8, name, "url")) {
        o.url = v;
    } else if (eq(u8, name, "header") or eq(u8, name, "H")) {
        o.headers.append(v) catch {};
    } else if (eq(u8, name, "data-binary") or eq(u8, name, "data") or eq(u8, name, "d")) {
        addData(a, o, dataArg(a, v));
    } else if (eq(u8, name, "data-urlencode")) {
        addData(a, o, urlencodeArg(a, v));
    } else if (eq(u8, name, "user-agent") or eq(u8, name, "A")) {
        o.ua = v;
    } else if (eq(u8, name, "request") or eq(u8, name, "X")) {
        o.method = v;
    } else if (eq(u8, name, "output") or eq(u8, name, "o")) {
        o.out = v;
    } else if (eq(u8, name, "write-out") or eq(u8, name, "w")) {
        o.write_out = v;
    } else if (eq(u8, name, "max-time")) {
        o.max_time = @intCast(@min(num(v), std.math.maxInt(u32)));
    } else if (eq(u8, name, "connect-timeout")) {
        o.connect_timeout = @intCast(@min(num(v), std.math.maxInt(u32)));
    } else if (eq(u8, name, "max-filesize")) {
        o.max_filesize = num(v);
    } else usage();
}

/// curl の設定(-K)の 1 行: 名前 = "値"(\" と \\ を戻す)。空行と # は飛ばす
fn configLine(a: std.mem.Allocator, line: []const u8) ?struct { name: []const u8, val: []const u8 } {
    const l = std.mem.trim(u8, line, " \t\r");
    if (l.len == 0 or l[0] == '#') return null;
    const sep = std.mem.indexOfAny(u8, l, "=: \t") orelse return null;
    const name = l[0..sep];
    var rest = std.mem.trimLeft(u8, l[sep..], "=: \t");
    if (rest.len >= 2 and rest[0] == '"') {
        rest = rest[1..];
        var v = std.ArrayList(u8).init(a);
        var i: usize = 0;
        while (i < rest.len and rest[i] != '"') : (i += 1) {
            if (rest[i] == '\\' and i + 1 < rest.len) i += 1;
            v.append(rest[i]) catch {};
        }
        return .{ .name = name, .val = v.items };
    }
    return .{ .name = name, .val = rest };
}

fn parseArgs(a: std.mem.Allocator, args: []const []const u8) Opts {
    var o = Opts{ .headers = std.ArrayList([]const u8).init(a) };
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const s = args[i];
        if (std.mem.startsWith(u8, s, "--")) {
            const name = s[2..];
            if (std.mem.eql(u8, name, "silent") or std.mem.eql(u8, name, "show-error") or std.mem.eql(u8, name, "no-buffer")) continue;
            if (std.mem.eql(u8, name, "fail")) {
                o.fail = true;
                continue;
            }
            if (std.mem.eql(u8, name, "location")) {
                o.follow = true;
                continue;
            }
            if (std.mem.eql(u8, name, "get")) {
                o.get = true;
                continue;
            }
            i += 1;
            if (i >= args.len) usage();
            if (std.mem.eql(u8, name, "config")) {
                readConfig(a, &o, args[i]);
            } else apply(a, &o, name, args[i]);
        } else if (s.len > 1 and s[0] == '-') {
            // -sSfL のようにまとめた書き方。値を取るものは最後に置く
            for (s[1..], 0..) |ch, k| {
                switch (ch) {
                    's' => show_errors = false,
                    'S' => show_errors = true,
                    'N' => {},
                    'G' => o.get = true,
                    'f' => o.fail = true,
                    'L' => o.follow = true,
                    'o', 'A', 'H', 'X', 'd', 'w', 'K' => {
                        if (k != s.len - 2) usage();
                        i += 1;
                        if (i >= args.len) usage();
                        if (ch == 'K') readConfig(a, &o, args[i]) else apply(a, &o, &.{ch}, args[i]);
                    },
                    else => usage(),
                }
            }
        } else o.url = s;
    }
    if (o.url.len == 0) usage();
    return o;
}

fn readConfig(a: std.mem.Allocator, o: *Opts, path: []const u8) void {
    const text = if (std.mem.eql(u8, path, "-"))
        std.io.getStdIn().readToEndAlloc(a, 16 << 20) catch die(26, "設定を読めません", .{})
    else
        std.fs.cwd().readFileAlloc(a, path, 16 << 20) catch die(26, "設定を読めません: {s}", .{path});
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |l| if (configLine(a, l)) |kv| apply(a, o, kv.name, kv.val);
}

// ---------------- URL ----------------

const Url = struct { https: bool, host: []const u8, port: u16, path: []const u8 };

fn parseUrl(u: []const u8) ?Url {
    var rest: []const u8 = undefined;
    var https: bool = undefined;
    if (std.ascii.startsWithIgnoreCase(u, "https://")) {
        https = true;
        rest = u[8..];
    } else if (std.ascii.startsWithIgnoreCase(u, "http://")) {
        https = false;
        rest = u[7..];
    } else return null;
    if (std.mem.indexOfScalar(u8, rest, '#')) |h| rest = rest[0..h];
    const slash = std.mem.indexOfAny(u8, rest, "/?") orelse rest.len;
    var hostport = rest[0..slash];
    if (std.mem.lastIndexOfScalar(u8, hostport, '@')) |at| hostport = hostport[at + 1 ..]; // 利用者名は使わない
    const path = if (slash < rest.len) (if (rest[slash] == '?') rest[slash..] else rest[slash..]) else "/";
    var host = hostport;
    var port: u16 = if (https) 443 else 80;
    if (hostport.len > 0 and hostport[0] == '[') {
        const end = std.mem.indexOfScalar(u8, hostport, ']') orelse return null;
        host = hostport[1..end];
        if (end + 1 < hostport.len and hostport[end + 1] == ':') port = std.fmt.parseInt(u16, hostport[end + 2 ..], 10) catch return null;
    } else if (std.mem.lastIndexOfScalar(u8, hostport, ':')) |cpos| {
        host = hostport[0..cpos];
        port = std.fmt.parseInt(u16, hostport[cpos + 1 ..], 10) catch return null;
    }
    if (host.len == 0) return null;
    return .{ .https = https, .host = host, .port = port, .path = path };
}

/// 転送先(Location)を今の URL を基準に絶対の URL にする
fn resolve(a: std.mem.Allocator, base: Url, loc: []const u8) []const u8 {
    if (std.ascii.startsWithIgnoreCase(loc, "http://") or std.ascii.startsWithIgnoreCase(loc, "https://")) return loc;
    const scheme = if (base.https) "https" else "http";
    if (std.mem.startsWith(u8, loc, "//")) return std.fmt.allocPrint(a, "{s}:{s}", .{ scheme, loc }) catch loc;
    if (std.mem.startsWith(u8, loc, "/")) return std.fmt.allocPrint(a, "{s}://{s}:{d}{s}", .{ scheme, base.host, base.port, loc }) catch loc;
    const q = std.mem.indexOfScalar(u8, base.path, '?') orelse base.path.len;
    const dir = base.path[0 .. (std.mem.lastIndexOfScalar(u8, base.path[0..q], '/') orelse 0) + 1];
    return std.fmt.allocPrint(a, "{s}://{s}:{d}{s}{s}", .{ scheme, base.host, base.port, dir, loc }) catch loc;
}

// ---------------- つなぐ ----------------

const Conn = struct {
    fd: std.posix.socket_t,
    ssl: ?*SSL = null,

    fn write(self: *Conn, data: []const u8) void {
        var off: usize = 0;
        while (off < data.len) {
            if (self.ssl) |s| {
                const n = SSL_write(s, data[off..].ptr, @intCast(@min(data.len - off, 1 << 30)));
                if (n <= 0) die(55, "送れません", .{});
                off += @intCast(n);
            } else {
                off += std.posix.write(self.fd, data[off..]) catch die(55, "送れません", .{});
            }
        }
    }

    /// 0 = 相手が閉じた
    fn read(self: *Conn, buf: []u8) usize {
        if (self.ssl) |s| {
            const n = SSL_read(s, buf.ptr, @intCast(buf.len));
            if (n > 0) return @intCast(n);
            const e = SSL_get_error(s, n);
            // 閉じる合図なしに切るサーバも多い(Connection: close)ので、それも終わりとみなす
            if (e == SSL_ERROR_ZERO_RETURN or e == SSL_ERROR_SYSCALL) return 0;
            die(56, "受け取りに失敗しました", .{});
        }
        return std.posix.read(self.fd, buf) catch die(56, "受け取りに失敗しました", .{});
    }
};

var ssl_ctx: ?*SSL_CTX = null;

fn connect(a: std.mem.Allocator, u: Url, connect_timeout: u32) Conn {
    const list = std.net.getAddressList(a, u.host, u.port) catch die(6, "名前を引けません: {s}", .{u.host});
    if (list.addrs.len == 0) die(6, "名前を引けません: {s}", .{u.host});
    var fd: std.posix.socket_t = -1;
    for (list.addrs) |addr| {
        const s = std.posix.socket(addr.any.family, std.posix.SOCK.STREAM | std.posix.SOCK.CLOEXEC, std.posix.IPPROTO.TCP) catch continue;
        if (connect_timeout > 0) {
            // Linux の connect は SO_SNDTIMEO の時間で諦める
            const tv = std.posix.timeval{ .tv_sec = @intCast(connect_timeout), .tv_usec = 0 };
            std.posix.setsockopt(s, std.posix.SOL.SOCKET, std.posix.SO.SNDTIMEO, std.mem.asBytes(&tv)) catch {};
        }
        std.posix.connect(s, &addr.any, addr.getOsSockLen()) catch {
            std.posix.close(s);
            continue;
        };
        if (connect_timeout > 0) {
            const zero = std.posix.timeval{ .tv_sec = 0, .tv_usec = 0 };
            std.posix.setsockopt(s, std.posix.SOL.SOCKET, std.posix.SO.SNDTIMEO, std.mem.asBytes(&zero)) catch {};
        }
        fd = s;
        break;
    }
    if (fd < 0) die(7, "つながりません: {s}:{d}", .{ u.host, u.port });
    var c = Conn{ .fd = fd };
    if (!u.https) return c;

    if (ssl_ctx == null) {
        const ctx = SSL_CTX_new(TLS_client_method()) orelse die(35, "暗号の準備ができません(libssl)", .{});
        if (SSL_CTX_set_default_verify_paths(ctx) != 1) die(77, "証明書の置き場所を読めません", .{});
        SSL_CTX_set_verify(ctx, SSL_VERIFY_PEER, null);
        _ = SSL_CTX_ctrl(ctx, SSL_CTRL_SET_MIN_PROTO_VERSION, TLS1_2_VERSION, null);
        ssl_ctx = ctx;
    }
    const s = SSL_new(ssl_ctx.?) orelse die(35, "暗号の準備ができません", .{});
    const hz = a.dupeZ(u8, u.host) catch die(35, "メモリが足りません", .{});
    // SNI(どのサイトか)と、証明書の名前の確認
    _ = SSL_ctrl(s, SSL_CTRL_SET_TLSEXT_HOSTNAME, 0, @constCast(@ptrCast(hz.ptr)));
    _ = SSL_set1_host(s, hz.ptr);
    _ = SSL_set_fd(s, fd);
    if (SSL_connect(s) != 1) {
        const v = SSL_get_verify_result(s);
        if (v != 0) die(60, "{s} の証明書を確かめられません(X509 の誤り {d})", .{ u.host, v });
        die(35, "{s} と暗号の握手ができません", .{u.host});
    }
    c.ssl = s;
    return c;
}

// ---------------- 受け取り ----------------

const Reader = struct {
    conn: *Conn,
    buf: [16384]u8 = undefined,
    start: usize = 0,
    end: usize = 0,

    fn fill(self: *Reader) bool {
        if (self.start < self.end) return true;
        self.start = 0;
        self.end = self.conn.read(&self.buf);
        return self.end > 0;
    }

    /// 1 行(\r\n を除く)。行が長すぎる・途中で切れたら null
    fn line(self: *Reader, out: []u8) ?[]const u8 {
        var n: usize = 0;
        while (true) {
            if (!self.fill()) return if (n > 0) out[0..n] else null;
            const ch = self.buf[self.start];
            self.start += 1;
            if (ch == '\n') return std.mem.trimRight(u8, out[0..n], "\r");
            if (n >= out.len) return null;
            out[n] = ch;
            n += 1;
        }
    }

    /// 最大 max バイト。0 = 終わり
    fn some(self: *Reader, max: usize) []const u8 {
        if (!self.fill()) return "";
        const n = @min(max, self.end - self.start);
        defer self.start += n;
        return self.buf[self.start..][0..n];
    }
};

const Sink = struct {
    file: std.fs.File,
    written: u64 = 0,
    max: u64,

    fn put(self: *Sink, data: []const u8) void {
        self.written += data.len;
        if (self.max > 0 and self.written > self.max) die(63, "--max-filesize を超えました", .{});
        self.file.writeAll(data) catch die(23, "書けません", .{});
    }
};

/// 本文を sink へ(chunked / Content-Length / 閉じるまで)
fn body(r: *Reader, sink: *Sink, chunked: bool, length: ?u64) void {
    if (chunked) {
        var lb: [256]u8 = undefined;
        while (true) {
            const l = r.line(&lb) orelse die(56, "chunked の区切りが読めません", .{});
            const hex = std.mem.trim(u8, l[0 .. std.mem.indexOfScalar(u8, l, ';') orelse l.len], " ");
            var left = std.fmt.parseInt(u64, hex, 16) catch die(56, "chunked の長さが読めません", .{});
            if (left == 0) break;
            while (left > 0) {
                const d = r.some(@intCast(@min(left, 1 << 20)));
                if (d.len == 0) die(56, "途中で切れました", .{});
                sink.put(d);
                left -= d.len;
            }
            _ = r.line(&lb); // チャンクの後ろの \r\n
        }
        return;
    }
    if (length) |len| {
        if (sink.max > 0 and len > sink.max) die(63, "--max-filesize を超えました", .{});
        var left = len;
        while (left > 0) {
            const d = r.some(@intCast(@min(left, 1 << 20)));
            if (d.len == 0) die(18, "途中で切れました", .{});
            sink.put(d);
            left -= d.len;
        }
        return;
    }
    while (true) {
        const d = r.some(1 << 20);
        if (d.len == 0) break;
        sink.put(d);
    }
}

/// -w の書式を書く
fn writeOut(fmt: []const u8, code: u16) void {
    const out = std.io.getStdOut().writer();
    var rest = fmt;
    while (std.mem.indexOf(u8, rest, "%{http_code}")) |p| {
        out.writeAll(rest[0..p]) catch {};
        out.print("{d:0>3}", .{code}) catch {};
        rest = rest[p + "%{http_code}".len ..];
    }
    // curl の -w は \n を改行として読む
    var it = std.mem.splitSequence(u8, rest, "\\n");
    var first = true;
    while (it.next()) |part| {
        if (!first) out.writeAll("\n") catch {};
        out.writeAll(part) catch {};
        first = false;
    }
}

pub fn main() u8 {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const a = arena.allocator();
    const argv = std.process.argsAlloc(a) catch return 2;
    const o = parseArgs(a, argv[1..]);
    if (o.max_time > 0) {
        const act = std.posix.Sigaction{ .handler = .{ .handler = onAlarm }, .mask = std.posix.empty_sigset, .flags = 0 };
        std.posix.sigaction(std.posix.SIG.ALRM, &act, null) catch {};
        _ = alarm(o.max_time);
    }
    var url = o.url;
    var send_body = o.data;
    if (o.get) if (o.data) |d| {
        url = std.mem.concat(a, u8, &.{ o.url, if (std.mem.indexOfScalar(u8, o.url, '?') != null) "&" else "?", d }) catch o.url;
        send_body = null;
    };
    var method: []const u8 = o.method orelse if (send_body != null) "POST" else "GET";
    var hops: u32 = 0;
    while (true) {
        const u = parseUrl(url) orelse die(3, "URL が読めません: {s}", .{url});
        var c = connect(a, u, o.connect_timeout);
        // 要求
        var req = std.ArrayList(u8).init(a);
        const w = req.writer();
        w.print("{s} {s} HTTP/1.1\r\nHost: {s}", .{ method, u.path, u.host }) catch {};
        if (u.port != (if (u.https) @as(u16, 443) else 80)) w.print(":{d}", .{u.port}) catch {};
        w.print("\r\nUser-Agent: {s}\r\nAccept: */*\r\nConnection: close\r\n", .{o.ua}) catch {};
        for (o.headers.items) |h| w.print("{s}\r\n", .{h}) catch {};
        if (send_body) |b| {
            var has_type = false;
            for (o.headers.items) |h| has_type = has_type or std.ascii.startsWithIgnoreCase(h, "content-type:");
            if (!has_type) w.writeAll("Content-Type: application/x-www-form-urlencoded\r\n") catch {};
            w.print("Content-Length: {d}\r\n", .{b.len}) catch {};
        }
        w.writeAll("\r\n") catch {};
        c.write(req.items);
        if (send_body) |b| c.write(b);

        var r = Reader{ .conn = &c };
        var lb: [8192]u8 = undefined;
        var code: u16 = 0;
        var chunked = false;
        var length: ?u64 = null;
        var location: ?[]const u8 = null;
        // 1xx(100 Continue など)は飛ばす
        while (true) {
            const status = r.line(&lb) orelse die(52, "返事がありません", .{});
            var parts = std.mem.tokenizeScalar(u8, status, ' ');
            _ = parts.next();
            code = std.fmt.parseInt(u16, parts.next() orelse die(56, "返事の形が違います", .{}), 10) catch die(56, "返事の形が違います", .{});
            chunked = false;
            length = null;
            location = null;
            while (true) {
                const h = r.line(&lb) orelse die(56, "ヘッダが途中で切れました", .{});
                if (h.len == 0) break;
                const colon = std.mem.indexOfScalar(u8, h, ':') orelse continue;
                const name = h[0..colon];
                const val = std.mem.trim(u8, h[colon + 1 ..], " \t");
                if (std.ascii.eqlIgnoreCase(name, "transfer-encoding")) chunked = std.ascii.indexOfIgnoreCase(val, "chunked") != null;
                if (std.ascii.eqlIgnoreCase(name, "content-length")) length = std.fmt.parseInt(u64, val, 10) catch null;
                if (std.ascii.eqlIgnoreCase(name, "location")) location = a.dupe(u8, val) catch null;
            }
            if (code >= 200 or code < 100) break;
        }
        if (o.follow and location != null and (code == 301 or code == 302 or code == 303 or code == 307 or code == 308)) {
            hops += 1;
            if (hops > 10) die(47, "転送が多すぎます", .{});
            url = resolve(a, u, location.?);
            // 303 と、POST 以外を変える 301 / 302 は GET に(curl と同じ)
            if (code == 303 or ((code == 301 or code == 302) and std.mem.eql(u8, method, "POST"))) {
                method = "GET";
                send_body = null;
            }
            std.posix.close(c.fd);
            continue;
        }
        if (o.fail and code >= 400) die(22, "HTTP の誤り {d}", .{code});
        var sink = Sink{
            .file = if (o.out) |p| (std.fs.cwd().createFile(p, .{}) catch die(23, "書けません: {s}", .{p})) else std.io.getStdOut(),
            .max = o.max_filesize,
        };
        body(&r, &sink, chunked, length);
        if (o.out != null) sink.file.close();
        if (o.write_out) |f| writeOut(f, code);
        return 0;
    }
}

test "URL" {
    const u = parseUrl("https://api.example.com/v1/x?q=1#frag").?;
    try std.testing.expect(u.https);
    try std.testing.expectEqualStrings("api.example.com", u.host);
    try std.testing.expectEqual(@as(u16, 443), u.port);
    try std.testing.expectEqualStrings("/v1/x?q=1", u.path);
    const v = parseUrl("http://localhost:8080").?;
    try std.testing.expectEqualStrings("/", v.path);
    try std.testing.expectEqual(@as(u16, 8080), v.port);
    const w6 = parseUrl("http://[::1]:9/a").?;
    try std.testing.expectEqualStrings("::1", w6.host);
    try std.testing.expect(parseUrl("ftp://x") == null);
}

test "転送先" {
    const a = std.testing.allocator;
    var ar = std.heap.ArenaAllocator.init(a);
    defer ar.deinit();
    const base = parseUrl("https://h.example/a/b?x=1").?;
    try std.testing.expectEqualStrings("https://h.example:443/c", resolve(ar.allocator(), base, "/c"));
    try std.testing.expectEqualStrings("https://h.example:443/a/d", resolve(ar.allocator(), base, "d"));
    try std.testing.expectEqualStrings("https://o.example/z", resolve(ar.allocator(), base, "https://o.example/z"));
}

test "設定の行" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const kv = configLine(ar.allocator(), "header = \"x-api-key: a\\\"b\"").?;
    try std.testing.expectEqualStrings("header", kv.name);
    try std.testing.expectEqualStrings("x-api-key: a\"b", kv.val);
    try std.testing.expect(configLine(ar.allocator(), "# c") == null);
}

test "--data-urlencode" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    try std.testing.expectEqualStrings("q=Queen%20Bohemian%20Rhapsody", urlencodeArg(ar.allocator(), "q=Queen Bohemian Rhapsody"));
    try std.testing.expectEqualStrings("s=%E5%A4%9C", urlencodeArg(ar.allocator(), "s=夜"));
}
