// プロセス全体の malloc 一式を差し替える(実行ファイルが定義した malloc は Mesa / LLVM / mpv / FreeType も使う)。
//
// なぜ: Chimera の libc(musl + mimalloc)は解放したメモリを OS に返さない(試すと 590MB 確保→全解放でも
// Pss_Anon は 590MB のまま、LazyFree も 0)。シェーダのコンパイルや画像・動画の復号のような一時的な山が
// 全部常駐し続け、私有メモリが 150〜280MB になっていた。libc は mi_collect も malloc_trim も出していない。
//
// やり方: 大きいブロック(LARGE 以上)は mmap で直に取り、free で munmap して即座に返す(glibc の
// mmap しきい値と同じ考え方)。小さいものは libc の malloc に任せる(山が小さく、速さが要るので)。
// どちらも利用者ポインタの直前 16 バイトに見出し {tag, base} を置き、free / realloc で見分ける。
// musl は malloc を差し替えると自分の posix_memalign / aligned_alloc を断るので、それらもここで実装する。
const std = @import("std");
const linux = std.os.linux;

const Fn = struct {
    extern "c" fn dlsym(handle: ?*anyopaque, name: [*:0]const u8) ?*anyopaque;
    extern "c" fn pthread_atfork(prepare: ?*const fn () callconv(.C) void, parent: ?*const fn () callconv(.C) void, child: ?*const fn () callconv(.C) void) c_int;
};
const RTLD_NEXT: ?*anyopaque = @ptrFromInt(@as(usize, @bitCast(@as(isize, -1))));

const SMALL: usize = 0x5A11_A3E5_0C0D_E001; // 上位 16 ビットを LARGE_TAG と違えること
const LARGE_TAG: usize = 0xA3E5 << 48; // 下位 48 ビットに mmap したページ数
const TAG_MASK: usize = 0xFFFF << 48;
const PAGE = 4096;
const HDR = 16;
// 大きいブロックの中身はキャッシュ行(64 バイト)にそろえる。16 バイトずれだと動画フレームの写しや
// テクスチャ転送が遅い道に落ち、CPU が 1.6 倍になった
const LOFF = 64;

// 16KB 以上を mmap へ(動画壁紙で測って: 64KB→148MB, 32KB→135MB, 16KB→115MB, 8KB→107MB。CPU は同じ。
// 8KB はわずかに減るが、マッピングの数(vm.max_map_count)と mmap の回数が増えるので 16KB)
const large_min: usize = 16 << 10;

const Head = extern struct { tag: usize, base: usize };

var r_malloc: ?*const fn (usize) callconv(.C) ?[*]u8 = null;
var r_free: ?*const fn (?*anyopaque) callconv(.C) void = null;
var r_usable: ?*const fn (?*anyopaque) callconv(.C) usize = null;
var resolving = false;

// dlsym が中で malloc を呼んだとき用の手元の領域(解放はしない)
var boot: [64 << 10]u8 align(16) = undefined;
var boot_used = std.atomic.Value(usize).init(0);

fn resolve() bool {
    if (@atomicLoad(?*const fn (usize) callconv(.C) ?[*]u8, &r_malloc, .acquire) != null) return true;
    if (resolving) return false;
    resolving = true;
    defer resolving = false;
    r_free = @ptrCast(Fn.dlsym(RTLD_NEXT, "free"));
    r_usable = @ptrCast(Fn.dlsym(RTLD_NEXT, "malloc_usable_size"));
    @atomicStore(?*const fn (usize) callconv(.C) ?[*]u8, &r_malloc, @ptrCast(Fn.dlsym(RTLD_NEXT, "malloc")), .release);
    if (r_malloc == null) return false;
    // fork の瞬間に別のスレッドが cache_lock を持っていると、子(ロック画面の PAM など exec せずに働く子)の
    // malloc が永久に待つ。fork の間はこちらで持っておき、親子どちらでも離す
    _ = Fn.pthread_atfork(forkPrepare, forkRelease, forkChild);
    return true;
}

fn head(p: *anyopaque) *Head {
    return @ptrFromInt(@intFromPtr(p) - HDR);
}

fn inBoot(p: usize) bool {
    return p >= @intFromPtr(&boot) and p < @intFromPtr(&boot) + boot.len;
}

// 解放した大きいマッピングを少しだけ取っておく(動画のフレームのように同じ大きさを毎フレーム取り直すものが
// mmap / munmap / ページフォールトを繰り返さないように)。8 個・16MB まで、3 秒使われなければ返す。
const CACHE_N = 8;
const CACHE_MAX = 16 << 20;
const CACHE_AGE = 3;
const Cached = struct { base: usize = 0, total: usize = 0, t: i64 = 0 };
var cache: [CACHE_N]Cached = [_]Cached{.{}} ** CACHE_N;
var cache_bytes: usize = 0;
var cache_lock: std.Thread.Mutex = .{};
threadlocal var reused = false;

fn now() i64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(linux.CLOCK.MONOTONIC_COARSE, &ts);
    return ts.tv_sec;
}

fn forkPrepare() callconv(.C) void {
    cache_lock.lock();
}
/// 子は 1 スレッドだけなので作り直す(Debug の Mutex は別のスレッドからの unlock を許さない)
fn forkChild() callconv(.C) void {
    cache_lock = .{};
}
fn forkRelease() callconv(.C) void {
    cache_lock.unlock();
}

/// 古いものを返す(cache_lock を持って呼ぶ)
fn expire(t: i64) void {
    for (&cache) |*e| if (e.base != 0 and t - e.t >= CACHE_AGE) {
        _ = linux.munmap(@ptrFromInt(e.base), e.total);
        cache_bytes -= e.total;
        e.* = .{};
    };
}

fn takeCached(total: usize) ?Cached {
    cache_lock.lock();
    defer cache_lock.unlock();
    expire(now());
    for (&cache) |*e| if (e.base != 0 and e.total >= total and e.total - total <= total / 4) {
        const r = e.*;
        cache_bytes -= e.total;
        e.* = .{};
        return r;
    };
    return null;
}

/// 取っておけたら true(呼び手は munmap しない)
fn putCached(base: usize, total: usize) bool {
    if (total > CACHE_MAX / 2) return false;
    cache_lock.lock();
    defer cache_lock.unlock();
    const t = now();
    expire(t);
    // 入らなければ一番古いものから返して場所を空ける
    while (cache_bytes + total > CACHE_MAX or for (cache) |e| {
        if (e.base == 0) break false;
    } else true) {
        var old: ?*Cached = null;
        for (&cache) |*e| if (e.base != 0 and (old == null or e.t < old.?.t)) {
            old = e;
        };
        const o = old orelse return false;
        _ = linux.munmap(@ptrFromInt(o.base), o.total);
        cache_bytes -= o.total;
        o.* = .{};
    }
    for (&cache) |*e| if (e.base == 0) {
        e.* = .{ .base = base, .total = total, .t = t };
        cache_bytes += total;
        return true;
    };
    return false;
}

fn mapLarge(len: usize, al: usize) ?[*]u8 {
    const extra = if (al > LOFF) al else 0;
    var total = std.mem.alignForward(usize, len + LOFF + extra, PAGE);
    var r: usize = 0;
    if (takeCached(total)) |e| {
        r = e.base;
        total = e.total;
        reused = true;
    } else {
        r = linux.mmap(null, total, linux.PROT.READ | linux.PROT.WRITE, .{ .TYPE = .PRIVATE, .ANONYMOUS = true }, -1, 0);
        if (linux.E.init(r) != .SUCCESS) return null;
        reused = false;
    }
    const p = std.mem.alignForward(usize, r + LOFF, @max(al, LOFF));
    head(@ptrFromInt(p)).* = .{ .tag = LARGE_TAG | (total / PAGE), .base = r };
    return @ptrFromInt(p);
}

fn alloc(len: usize, al: usize) ?[*]u8 {
    if (!resolve()) {
        const need = std.mem.alignForward(usize, len + HDR, 16) + @max(al, 16);
        const off = boot_used.fetchAdd(need, .monotonic);
        if (off + need > boot.len) return null;
        const p = std.mem.alignForward(usize, @intFromPtr(&boot) + off + HDR, @max(al, 16));
        head(@ptrFromInt(p)).* = .{ .tag = SMALL, .base = 0 };
        return @ptrFromInt(p);
    }
    if (len >= large_min) return mapLarge(len, al);
    const extra = if (al > 16) al else 0;
    const raw = r_malloc.?(len + HDR + extra) orelse return null;
    const p = std.mem.alignForward(usize, @intFromPtr(raw) + HDR, @max(al, 16));
    head(@ptrFromInt(p)).* = .{ .tag = SMALL, .base = @intFromPtr(raw) };
    return @ptrFromInt(p);
}

fn usable(p: *anyopaque) usize {
    const h = head(p);
    if (h.tag == SMALL) {
        if (h.base == 0) return 0;
        return r_usable.?(@ptrFromInt(h.base)) - (@intFromPtr(p) - h.base);
    }
    return h.base + (h.tag & ~TAG_MASK) * PAGE - @intFromPtr(p);
}

fn release(p: *anyopaque) void {
    if (inBoot(@intFromPtr(p))) return;
    const h = head(p);
    if (h.tag == SMALL) return r_free.?(@ptrFromInt(h.base));
    if (h.tag & TAG_MASK == LARGE_TAG) {
        const total = (h.tag & ~TAG_MASK) * PAGE;
        if (!putCached(h.base, total)) _ = linux.munmap(@ptrFromInt(h.base), total);
        return;
    }
    // 見出しが無い = 差し替える前に libc が確保したもの
    _ = resolve();
    r_free.?(p);
}

export fn malloc(len: usize) ?*anyopaque {
    return alloc(len, 16);
}

export fn calloc(n: usize, sz: usize) ?*anyopaque {
    const len = std.math.mul(usize, n, sz) catch return null;
    const p = alloc(len, 16) orelse return null;
    // 新しく mmap したページは最初から 0(触らずに済むので常駐もしない)
    if (head(p).tag == SMALL or reused) @memset(p[0..len], 0);
    return p;
}

export fn free(p: ?*anyopaque) void {
    release(p orelse return);
}

export fn realloc(old: ?*anyopaque, len: usize) ?*anyopaque {
    const o = old orelse return alloc(len, 16);
    if (len == 0) {
        release(o);
        return null;
    }
    const h = head(o);
    const have = if (inBoot(@intFromPtr(o))) 0 else if (h.tag == SMALL or h.tag & TAG_MASK == LARGE_TAG) usable(o) else return null;
    if (len <= have and (h.tag == SMALL or len >= large_min)) return o;
    // 大きいまま伸び縮みするなら mremap(中身の写しが要らない)。整列つきで取ったもの(base が先頭でない)は除く
    if (h.tag & TAG_MASK == LARGE_TAG and len >= large_min and @intFromPtr(o) - h.base == LOFF) {
        const old_total = (h.tag & ~TAG_MASK) * PAGE;
        const total = std.mem.alignForward(usize, len + LOFF, PAGE);
        const r = linux.syscall4(.mremap, h.base, old_total, total, 1); // 1 = MREMAP_MAYMOVE(Zig 0.13 に包みが無い)
        if (linux.E.init(r) != .SUCCESS) return null;
        const p: *anyopaque = @ptrFromInt(r + LOFF);
        head(p).* = .{ .tag = LARGE_TAG | (total / PAGE), .base = r };
        return p;
    }
    const n = alloc(len, 16) orelse return null;
    const keep = @min(have, len);
    @memcpy(n[0..keep], @as([*]const u8, @ptrCast(o))[0..keep]);
    release(o);
    return n;
}

export fn reallocarray(old: ?*anyopaque, n: usize, sz: usize) ?*anyopaque {
    return realloc(old, std.math.mul(usize, n, sz) catch return null);
}

fn validAlign(al: usize) bool {
    return al != 0 and al & (al - 1) == 0;
}

export fn posix_memalign(out: *?*anyopaque, al: usize, len: usize) c_int {
    if (!validAlign(al) or al % @sizeOf(usize) != 0) return @intFromEnum(linux.E.INVAL);
    out.* = alloc(len, al) orelse return @intFromEnum(linux.E.NOMEM);
    return 0;
}

export fn aligned_alloc(al: usize, len: usize) ?*anyopaque {
    if (!validAlign(al)) return null;
    return alloc(len, al);
}

export fn memalign(al: usize, len: usize) ?*anyopaque {
    if (!validAlign(al)) return null;
    return alloc(len, al);
}

export fn valloc(len: usize) ?*anyopaque {
    return alloc(len, PAGE);
}

export fn malloc_usable_size(p: ?*anyopaque) usize {
    const q = p orelse return 0;
    if (inBoot(@intFromPtr(q))) return 0;
    return usable(q);
}

test "大小・整列・realloc が見出しを保つ" {
    // このテストは差し替えとは別に関数を直接呼ぶ(テストの実行ファイルでは export が libc と衝突しない)
    const s: [*]u8 = @ptrCast(malloc(100).?);
    @memset(s[0..100], 7);
    try std.testing.expect(malloc_usable_size(s) >= 100);
    const big: [*]u8 = @ptrCast(realloc(s, 200 << 10).?);
    try std.testing.expectEqual(@as(u8, 7), big[99]);
    try std.testing.expect(head(big).tag & TAG_MASK == LARGE_TAG);
    const bigger: [*]u8 = @ptrCast(realloc(big, 1 << 20).?);
    try std.testing.expectEqual(@as(u8, 7), bigger[0]);
    const back: [*]u8 = @ptrCast(realloc(bigger, 50).?);
    try std.testing.expectEqual(@as(u8, 7), back[49]);
    try std.testing.expect(head(back).tag == SMALL);
    free(back);
    var p: ?*anyopaque = null;
    try std.testing.expectEqual(@as(c_int, 0), posix_memalign(&p, 8192, 300 << 10));
    try std.testing.expect(@intFromPtr(p.?) % 8192 == 0);
    @memset(@as([*]u8, @ptrCast(p.?))[0 .. 300 << 10], 1);
    free(p);
    const z: [*]u8 = @ptrCast(calloc(10, 1000).?);
    for (z[0..10000]) |b| try std.testing.expectEqual(@as(u8, 0), b);
    free(z);
    // 取っておいたマッピングを再利用しても calloc は 0 で返す
    const dirty: [*]u8 = @ptrCast(malloc(200 << 10).?);
    @memset(dirty[0 .. 200 << 10], 0xff);
    free(dirty);
    const clean: [*]u8 = @ptrCast(calloc(200 << 10, 1).?);
    try std.testing.expect(clean == dirty);
    for (clean[0 .. 200 << 10]) |b| try std.testing.expectEqual(@as(u8, 0), b);
    free(clean);
    const a64 = aligned_alloc(64, 40).?;
    try std.testing.expect(@intFromPtr(a64) % 64 == 0);
    free(a64);
}
