// 鍵束(ame-keyring)の中身: アプリがしまった秘密(API キー・パスワード)の一覧・属性での検索・ファイルの形・暗号化。
// D-Bus(Secret Service)の口は src/cmd/ame-keyring.zig。ここは OS にも D-Bus にも依存しない。
//
// ファイル: "AMEKR1" + 24 バイトの nonce + XChaCha20-Poly1305 で暗号化した JSON(+ 16 バイトの認証タグ)。
// JSON: {"next_id":N,"items":[{"id","label","attrs":[[鍵,値],…],"secret"(base64),"content_type","created","modified"}]}
const std = @import("std");

const MAGIC = "AMEKR1";
const Aead = std.crypto.aead.chacha_poly.XChaCha20Poly1305;
pub const KEY_LEN = Aead.key_length;

pub const Attr = struct { key: []const u8, value: []const u8 };

pub const Item = struct {
    id: u32,
    label: []const u8,
    attrs: []Attr,
    secret: []u8,
    content_type: []const u8,
    created: u64,
    modified: u64,
};

pub const Store = struct {
    a: std.mem.Allocator,
    items: std.ArrayListUnmanaged(Item) = .{},
    next_id: u32 = 1,

    pub fn init(a: std.mem.Allocator) Store {
        return .{ .a = a };
    }

    pub fn deinit(self: *Store) void {
        for (self.items.items) |*it| self.freeItem(it);
        self.items.deinit(self.a);
    }

    fn freeItem(self: *Store, it: *Item) void {
        std.crypto.utils.secureZero(u8, it.secret);
        self.a.free(it.secret);
        self.a.free(it.label);
        self.a.free(it.content_type);
        for (it.attrs) |at| {
            self.a.free(at.key);
            self.a.free(at.value);
        }
        self.a.free(it.attrs);
    }

    fn dupAttrs(self: *Store, attrs: []const Attr) ![]Attr {
        const out = try self.a.alloc(Attr, attrs.len);
        for (attrs, 0..) |at, i| out[i] = .{ .key = try self.a.dupe(u8, at.key), .value = try self.a.dupe(u8, at.value) };
        return out;
    }

    pub fn get(self: *Store, id: u32) ?*Item {
        for (self.items.items) |*it| if (it.id == id) return it;
        return null;
    }

    /// filter の属性を全部持っている(空の filter は全部に合う)
    pub fn matches(it: *const Item, filter: []const Attr) bool {
        outer: for (filter) |f| {
            for (it.attrs) |at| if (std.mem.eql(u8, at.key, f.key)) {
                if (std.mem.eql(u8, at.value, f.value)) continue :outer;
                return false;
            };
            return false;
        }
        return true;
    }

    /// 属性がちょうど同じ(順序は問わない)
    fn sameAttrs(x: []const Attr, y: []const Attr) bool {
        if (x.len != y.len) return false;
        const tmp = Item{ .id = 0, .label = "", .attrs = @constCast(x), .secret = &.{}, .content_type = "", .created = 0, .modified = 0 };
        return matches(&tmp, y);
    }

    /// 合うものの id(新しい順ではなく、しまった順)
    pub fn search(self: *Store, filter: []const Attr, out: *std.ArrayList(u32)) !void {
        for (self.items.items) |*it| if (matches(it, filter)) try out.append(it.id);
    }

    /// しまう。replace なら属性がちょうど同じものを置き換える。返り値は id
    pub fn create(self: *Store, label: []const u8, attrs: []const Attr, secret: []const u8, content_type: []const u8, replace: bool, now: u64) !u32 {
        if (replace) for (self.items.items) |*it| if (sameAttrs(it.attrs, attrs)) {
            try self.setSecret(it, secret, content_type, now);
            const l = try self.a.dupe(u8, label);
            self.a.free(it.label);
            it.label = l;
            return it.id;
        };
        const it = Item{
            .id = self.next_id,
            .label = try self.a.dupe(u8, label),
            .attrs = try self.dupAttrs(attrs),
            .secret = try self.a.dupe(u8, secret),
            .content_type = try self.a.dupe(u8, content_type),
            .created = now,
            .modified = now,
        };
        try self.items.append(self.a, it);
        self.next_id += 1;
        return it.id;
    }

    pub fn setSecret(self: *Store, it: *Item, secret: []const u8, content_type: []const u8, now: u64) !void {
        const s = try self.a.dupe(u8, secret);
        const ct = try self.a.dupe(u8, content_type);
        std.crypto.utils.secureZero(u8, it.secret);
        self.a.free(it.secret);
        self.a.free(it.content_type);
        it.secret = s;
        it.content_type = ct;
        it.modified = now;
    }

    pub fn setLabel(self: *Store, it: *Item, label: []const u8, now: u64) !void {
        const l = try self.a.dupe(u8, label);
        self.a.free(it.label);
        it.label = l;
        it.modified = now;
    }

    pub fn setAttrs(self: *Store, it: *Item, attrs: []const Attr, now: u64) !void {
        const n = try self.dupAttrs(attrs);
        for (it.attrs) |at| {
            self.a.free(at.key);
            self.a.free(at.value);
        }
        self.a.free(it.attrs);
        it.attrs = n;
        it.modified = now;
    }

    pub fn delete(self: *Store, id: u32) bool {
        for (self.items.items, 0..) |*it, i| if (it.id == id) {
            self.freeItem(it);
            _ = self.items.orderedRemove(i);
            return true;
        };
        return false;
    }

    // ---- ファイルの形 ----

    const WireItem = struct { id: u32, label: []const u8, attrs: []const [2][]const u8, secret: []const u8, content_type: []const u8 = "text/plain", created: u64 = 0, modified: u64 = 0 };
    const Wire = struct { next_id: u32 = 1, items: []const WireItem = &.{} };

    /// JSON にする(秘密は base64)。返り値は a で確保。使い終わったら secureZero してから free
    pub fn toJson(self: *Store, a: std.mem.Allocator) ![]u8 {
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const t = arena.allocator();
        const list = try t.alloc(WireItem, self.items.items.len);
        const enc = std.base64.standard.Encoder;
        for (self.items.items, 0..) |it, i| {
            const at = try t.alloc([2][]const u8, it.attrs.len);
            for (it.attrs, 0..) |x, j| at[j] = .{ x.key, x.value };
            const b = try t.alloc(u8, enc.calcSize(it.secret.len));
            list[i] = .{ .id = it.id, .label = it.label, .attrs = at, .secret = enc.encode(b, it.secret), .content_type = it.content_type, .created = it.created, .modified = it.modified };
        }
        const s = try std.json.stringifyAlloc(a, Wire{ .next_id = self.next_id, .items = list }, .{});
        // 中間の base64 の秘密を消してから返す
        for (list) |w| std.crypto.utils.secureZero(u8, @constCast(w.secret));
        return s;
    }

    pub fn fromJson(a: std.mem.Allocator, json: []const u8) !Store {
        const p = try std.json.parseFromSlice(Wire, a, json, .{ .ignore_unknown_fields = true });
        defer p.deinit();
        var s = Store.init(a);
        errdefer s.deinit();
        const dec = std.base64.standard.Decoder;
        for (p.value.items) |w| {
            const secret = try a.alloc(u8, try dec.calcSizeForSlice(w.secret));
            errdefer a.free(secret);
            try dec.decode(secret, w.secret);
            const attrs = try a.alloc(Attr, w.attrs.len);
            for (w.attrs, 0..) |x, i| attrs[i] = .{ .key = try a.dupe(u8, x[0]), .value = try a.dupe(u8, x[1]) };
            try s.items.append(a, .{ .id = w.id, .label = try a.dupe(u8, w.label), .attrs = attrs, .secret = secret, .content_type = try a.dupe(u8, w.content_type), .created = w.created, .modified = w.modified });
        }
        s.next_id = p.value.next_id;
        for (s.items.items) |it| s.next_id = @max(s.next_id, it.id + 1);
        return s;
    }
};

/// 暗号化してファイルの中身にする("AMEKR1" + nonce + 暗号文 + タグ)
pub fn seal(a: std.mem.Allocator, key: [KEY_LEN]u8, plain: []const u8) ![]u8 {
    const out = try a.alloc(u8, MAGIC.len + Aead.nonce_length + plain.len + Aead.tag_length);
    @memcpy(out[0..MAGIC.len], MAGIC);
    const nonce = out[MAGIC.len..][0..Aead.nonce_length];
    std.crypto.random.bytes(nonce);
    const ct = out[MAGIC.len + Aead.nonce_length ..][0..plain.len];
    const tag = out[out.len - Aead.tag_length ..][0..Aead.tag_length];
    Aead.encrypt(ct, tag, plain, MAGIC, nonce.*, key);
    return out;
}

/// ファイルの中身を復号する。形が違う・鍵が違う・書き換えられていれば error
pub fn open(a: std.mem.Allocator, key: [KEY_LEN]u8, data: []const u8) ![]u8 {
    if (data.len < MAGIC.len + Aead.nonce_length + Aead.tag_length or !std.mem.eql(u8, data[0..MAGIC.len], MAGIC)) return error.BadFormat;
    const nonce = data[MAGIC.len..][0..Aead.nonce_length];
    const ct = data[MAGIC.len + Aead.nonce_length .. data.len - Aead.tag_length];
    const tag = data[data.len - Aead.tag_length ..][0..Aead.tag_length];
    const out = try a.alloc(u8, ct.len);
    errdefer a.free(out);
    try Aead.decrypt(out, ct, tag.*, MAGIC, nonce.*, key);
    return out;
}

test "store create, search, replace, round trip" {
    const a = std.testing.allocator;
    var s = Store.init(a);
    defer s.deinit();
    const id1 = try s.create("Zed", &.{ .{ .key = "url", .value = "https://api.anthropic.com" }, .{ .key = "username", .value = "x" } }, "sk-1", "text/plain", true, 10);
    const id2 = try s.create("Other", &.{.{ .key = "url", .value = "https://example.com" }}, "pw", "text/plain", true, 11);
    // 同じ属性(順序違い)で replace → 同じ id で中身が変わる
    const id1b = try s.create("Zed2", &.{ .{ .key = "username", .value = "x" }, .{ .key = "url", .value = "https://api.anthropic.com" } }, "sk-2", "text/plain", true, 12);
    try std.testing.expectEqual(id1, id1b);
    try std.testing.expectEqualStrings("sk-2", s.get(id1).?.secret);
    var ids = std.ArrayList(u32).init(a);
    defer ids.deinit();
    try s.search(&.{.{ .key = "url", .value = "https://example.com" }}, &ids);
    try std.testing.expectEqualSlices(u32, &.{id2}, ids.items);
    ids.clearRetainingCapacity();
    try s.search(&.{}, &ids);
    try std.testing.expectEqual(@as(usize, 2), ids.items.len);

    // JSON と暗号化を通して戻す
    const json = try s.toJson(a);
    defer a.free(json);
    var key: [KEY_LEN]u8 = undefined;
    std.crypto.random.bytes(&key);
    const sealed = try seal(a, key, json);
    defer a.free(sealed);
    try std.testing.expect(std.mem.indexOf(u8, sealed, "sk-2") == null); // 平文で残っていない
    const plain = try open(a, key, sealed);
    defer a.free(plain);
    var s2 = try Store.fromJson(a, plain);
    defer s2.deinit();
    try std.testing.expectEqualStrings("sk-2", s2.get(id1).?.secret);
    try std.testing.expectEqualStrings("Zed2", s2.get(id1).?.label);
    try std.testing.expectEqual(@as(u32, 3), s2.next_id);
    try std.testing.expect(s2.delete(id2));
    try std.testing.expect(s2.get(id2) == null);

    // 鍵違い・書き換えは開けない
    var bad = key;
    bad[0] ^= 1;
    try std.testing.expectError(error.AuthenticationFailed, open(a, bad, sealed));
    sealed[sealed.len - 1] ^= 1;
    try std.testing.expectError(error.AuthenticationFailed, open(a, key, sealed));
}
