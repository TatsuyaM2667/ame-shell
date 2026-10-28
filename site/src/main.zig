// ame-shell ドキュメントサイトの描画エンジン(Zig → wasm32-freestanding)。
//
// 5 つの区分(ドキュメント・技術解説・関数リファレンス・Wiki・ブログ)の本文をビルド時に埋め込み、
// ブラウザ上でこの WebAssembly が HTML にする。JavaScript は wasm を読み込んで結果を DOM に入れるだけ
// (static/app.js)。関数リファレンスは site/gen/refgen.zig がソースから生成したもの(refpages)。
//
// 書式(Markdown の部分集合 + 独自のブロック):
//   # 見出し / ## 見出し {#id} / ### 見出し {#id}     段落は空行で区切る
//   - 箇条書き / 1. 番号付き / > 補足(>! で注意) / ``` コード ``` / | 表 |(2 行目は |---|)
//   ::video 名前 | 説明   ::img ファイル | 説明   ::demo spring|fuzzy|color
//   ::stats(値 | 説明)/ ::cards(アイコン | 題 | 本文)/ ::infobox 題(項目 | 値)… 空行まで
//   :::easy 題 … ::: / :::deep 題 … ::: / :::research 題 … :::   (囲み)
//   < で始まる行は HTML をそのまま
//   行内: **太字** `コード` [文字](URL) [[wiki の項目]] [[項目|表示する文字]]

const std = @import("std");
const refpages = @import("refpages");

const Sec = enum(u32) { doc, tech, ref, wiki, blog };

const Page = struct {
    slug: []const u8,
    title: []const u8,
    src: []const u8,
    sec: Sec = .doc,
    /// Wiki: カテゴリ / ブログ: 日付
    meta: []const u8 = "",
};

fn d(slug: []const u8, title: []const u8, src: []const u8) Page {
    return .{ .slug = slug, .title = title, .src = src, .sec = .doc };
}
fn t(slug: []const u8, title: []const u8, src: []const u8) Page {
    return .{ .slug = slug, .title = title, .src = src, .sec = .tech };
}

const static_pages = [_]Page{
    // ---- ドキュメント ----
    d("", "ホーム", @embedFile("content/home.md")),
    d("animation", "アニメーション", @embedFile("content/animation.md")),
    d("shell", "シェルの機能", @embedFile("content/shell.md")),
    d("performance", "性能", @embedFile("content/performance.md")),
    d("compare", "ほかの WM と比較", @embedFile("content/compare.md")),
    d("install", "インストール", @embedFile("content/install.md")),
    d("reference", "設定とコマンド", @embedFile("content/reference.md")),
    // ---- 技術解説 ----
    t("tech", "全体像", @embedFile("content/tech/index.md")),
    t("tech-lang", "言語とツールチェイン", @embedFile("content/tech/lang.md")),
    t("tech-build", "ビルド(build.zig)", @embedFile("content/tech/build.md")),
    t("tech-loop", "起動とイベントループ", @embedFile("content/tech/loop.md")),
    t("tech-wayland", "Wayland とサーフェス", @embedFile("content/tech/wayland.md")),
    t("tech-gpu", "GPU レンダラ", @embedFile("content/tech/gpu.md")),
    t("tech-glass", "ガラス・壁紙・配色", @embedFile("content/tech/glass.md")),
    t("tech-text", "文字の描画", @embedFile("content/tech/text.md")),
    t("tech-anim", "ばねとアニメーションの中核", @embedFile("content/tech/anim.md")),
    t("tech-wm", "ウィンドウマネージャ", @embedFile("content/tech/wm.md")),
    t("tech-frame", "枠とドロワー", @embedFile("content/tech/frame.md")),
    t("tech-launcher", "ランチャーとアイコン", @embedFile("content/tech/launcher.md")),
    t("tech-media", "メディア・歌詞・音・動画", @embedFile("content/tech/media.md")),
    t("tech-notify-lock", "通知とロック画面", @embedFile("content/tech/notify-lock.md")),
    t("tech-wasm", "WebAssembly ウィジェット", @embedFile("content/tech/wasm.md")),
    t("tech-platform", "OS 対応(Linux と FreeBSD)", @embedFile("content/tech/platform.md")),
    t("tech-config", "設定と ame-ctl", @embedFile("content/tech/config.md")),
    t("tech-session", "セッションとインストーラ", @embedFile("content/tech/session.md")),
    t("tech-site", "このサイトの作り", @embedFile("content/tech/site.md")),
} ++ convList(.wiki, @import("content/wiki/list.zig").items) ++ convList(.blog, @import("content/blog/list.zig").items);

/// 一覧ファイル(.{ スラッグ, 題, カテゴリか日付, 本文 } のタプル)を Page の配列にする
fn convList(comptime sec: Sec, comptime items: anytype) [items.len]Page {
    var out: [items.len]Page = undefined;
    inline for (items, 0..) |it, i| out[i] = .{ .slug = it[0], .title = it[1], .meta = it[2], .src = it[3], .sec = sec };
    return out;
}

const pages = blk: {
    var arr: [static_pages.len + refpages.pages.len]Page = undefined;
    for (static_pages, 0..) |p, i| arr[i] = p;
    for (refpages.pages, 0..) |r, i| arr[static_pages.len + i] = .{ .slug = r.slug, .title = r.title, .src = r.src, .sec = .ref };
    break :blk arr;
};

// ---- JS とのやりとり用のバッファ ----
var in_buf: [256]u8 = undefined;
var out_buf: [1 << 20]u8 = undefined;
var out_len: usize = 0;
var overflow = false;

export fn in_ptr() [*]u8 {
    return &in_buf;
}
export fn out_ptr() [*]const u8 {
    return &out_buf;
}
export fn page_count() u32 {
    return pages.len;
}

/// in_buf[0..len] のスラッグのページ番号(無ければ -1)
export fn find_page(len: u32) i32 {
    return if (findSlug(in_buf[0..@min(len, in_buf.len)])) |i| @intCast(i) else -1;
}

fn findSlug(s: []const u8) ?usize {
    for (pages, 0..) |p, i| if (std.mem.eql(u8, p.slug, s)) return i;
    return null;
}

/// 区分(0 ドキュメント / 1 技術解説 / 2 関数リファレンス / 3 Wiki / 4 ブログ)
export fn page_section(i: u32) u32 {
    return if (i < pages.len) @intFromEnum(pages[i].sec) else 0;
}

export fn page_title(i: u32) u32 {
    reset();
    if (i < pages.len) raw(pages[i].title);
    return @intCast(out_len);
}

/// 上のナビゲーション(区分だけ)
export fn render_nav(cur: u32) u32 {
    reset();
    const sec: Sec = if (cur < pages.len) pages[cur].sec else .doc;
    const items = [_]struct { s: Sec, href: []const u8, label: []const u8 }{
        .{ .s = .doc, .href = "#/", .label = "docs" },
        .{ .s = .tech, .href = "#/tech", .label = "技術解説" },
        .{ .s = .ref, .href = "#/ref", .label = "関数リファレンス" },
        .{ .s = .wiki, .href = "#/wiki", .label = "Wiki" },
        .{ .s = .blog, .href = "#/blog", .label = "ブログ" },
    };
    for (items) |it| {
        raw("<a href=\"");
        raw(it.href);
        raw("\"");
        if (it.s == sec) raw(" class=\"on\"");
        raw(">");
        raw(it.label);
        raw("</a>");
    }
    return @intCast(out_len);
}

/// ページ本文の HTML
export fn render_page(i: u32) u32 {
    reset();
    if (i >= pages.len) {
        raw("<h1>404: ページが見つかりません</h1><p><a href=\"#/\">ホームへ</a> · <a href=\"#/wiki\">Wiki</a></p>");
        return @intCast(out_len);
    }
    const p = pages[i];
    switch (p.sec) {
        .doc, .tech, .ref => {
            const name = switch (p.sec) {
                .ref => "AME-SHELL(3)",
                .tech => "AME-SHELL(7)",
                else => "AME-SHELL(1)",
            };
            raw("<div class=\"manhead\"><span>");
            raw(name);
            raw("</span><span>");
            raw(switch (p.sec) {
                .ref => "ame-shell 関数リファレンス",
                .tech => "ame-shell 技術解説",
                else => "ame-shell マニュアル",
            });
            raw("</span><span>");
            raw(name);
            raw("</span></div>");
        },
        else => {},
    }
    cur_sec = p.sec;
    renderDoc(p.src, p);
    switch (p.sec) {
        .wiki => {
            if (std.mem.eql(u8, p.slug, "wiki")) wikiIndex() else {
                raw("<div class=\"catlinks\">カテゴリ: <a href=\"#/wiki#");
                catId(p.meta);
                raw("\">");
                esc(p.meta);
                raw("</a></div>");
            }
        },
        .blog => if (std.mem.eql(u8, p.slug, "blog")) blogIndex(),
        else => {},
    }
    pager(i);
    if (overflow) raw("<p>(ページが大きすぎます)</p>");
    return @intCast(out_len);
}

/// 横の欄: 区分ごとの一覧と、このページの目次
export fn render_toc(i: u32) u32 {
    reset();
    if (i >= pages.len) return 0;
    const p = pages[i];
    switch (p.sec) {
        .wiki => {
            raw("<div class=\"wlogo\"><a href=\"#/wiki\"><b>ame-shell</b><span>Wiki</span></a><small>ame-shell の用語集</small></div>");
            raw("<div class=\"chap\"><p>案内</p><a href=\"#/wiki\">メインページ</a><a href=\"#/wiki#index\">すべての項目</a><a href=\"#/tech\">技術解説</a><a href=\"#/ref\">関数リファレンス</a></div>");
            raw("<div class=\"chap\"><p>カテゴリ</p>");
            var seen: [32][]const u8 = undefined;
            var ns: usize = 0;
            for (pages) |q| {
                if (q.sec != .wiki or q.meta.len == 0) continue;
                var dup = false;
                for (seen[0..ns]) |x| dup = dup or std.mem.eql(u8, x, q.meta);
                if (dup or ns >= seen.len) continue;
                seen[ns] = q.meta;
                ns += 1;
                raw("<a href=\"#/wiki#");
                catId(q.meta);
                raw("\">");
                esc(q.meta);
                raw("</a>");
            }
            raw("</div>");
            return @intCast(out_len);
        },
        .blog => {
            raw("<div class=\"chap\"><p>記事</p>");
            var k: usize = pages.len;
            while (k > 0) {
                k -= 1;
                const q = pages[k];
                if (q.sec != .blog or q.meta.len == 0) continue;
                raw("<a href=\"#/");
                raw(q.slug);
                raw("\"");
                if (k == i) raw(" class=\"cur\"");
                raw("><small>");
                raw(q.meta);
                raw("</small> ");
                esc(q.title);
                raw("</a>");
            }
            raw("</div>");
            return @intCast(out_len);
        },
        else => {},
    }
    // ドキュメント・技術解説・リファレンス: 同じ区分のページ一覧
    raw("<div class=\"chap\"><p>");
    raw(switch (p.sec) {
        .tech => "技術解説",
        .ref => "ファイル",
        else => "ドキュメント",
    });
    raw("</p>");
    var k: usize = 0;
    for (pages, 0..) |q, j| {
        if (q.sec != p.sec) continue;
        raw("<a href=\"#/");
        raw(q.slug);
        raw("\"");
        if (j == i) raw(" class=\"cur\"");
        raw(">");
        if (p.sec == .tech and k > 0) {
            var nb: [8]u8 = undefined;
            raw(std.fmt.bufPrint(&nb, "{d}. ", .{k}) catch "");
        }
        if (p.sec == .ref and q.slug.len > 4) esc(q.slug[4..]) else esc(q.title);
        raw("</a>");
        k += 1;
    }
    raw("</div>");
    raw("<div class=\"here\">");
    tocLinks(p.src);
    raw("</div>");
    return @intCast(out_len);
}

fn tocLinks(src: []const u8) void {
    var it = std.mem.splitScalar(u8, src, '\n');
    var n: u32 = 0;
    var in_code = false;
    while (it.next()) |line| {
        if (std.mem.startsWith(u8, line, "```")) in_code = !in_code;
        if (in_code or !std.mem.startsWith(u8, line, "## ")) continue;
        n += 1;
        const h = splitId(line[3..], n);
        raw("<a href=\"#");
        esc(h.id);
        raw("\">");
        inlineText(h.text);
        raw("</a>");
    }
}

fn pager(i: usize) void {
    const sec = pages[i].sec;
    var prev: ?usize = null;
    var next: ?usize = null;
    var k = i;
    while (k > 0) {
        k -= 1;
        if (pages[k].sec == sec) {
            prev = k;
            break;
        }
    }
    k = i + 1;
    while (k < pages.len) : (k += 1) if (pages[k].sec == sec) {
        next = k;
        break;
    };
    if (prev == null and next == null) return;
    raw("<nav class=\"pager\">");
    if (prev) |q| {
        raw("<a class=\"prev\" href=\"#/");
        raw(pages[q].slug);
        raw("\"><small>← 前</small>");
        esc(pages[q].title);
        raw("</a>");
    }
    if (next) |q| {
        raw("<a class=\"next\" href=\"#/");
        raw(pages[q].slug);
        raw("\"><small>次 →</small>");
        esc(pages[q].title);
        raw("</a>");
    }
    raw("</nav>");
}

/// Wiki のメインページの末尾: カテゴリごとの全項目
fn wikiIndex() void {
    raw("<h2 id=\"index\">すべての項目</h2>");
    var seen: [32][]const u8 = undefined;
    var ns: usize = 0;
    for (pages) |q| {
        if (q.sec != .wiki or q.meta.len == 0) continue;
        var dup = false;
        for (seen[0..ns]) |x| dup = dup or std.mem.eql(u8, x, q.meta);
        if (dup or ns >= seen.len) continue;
        seen[ns] = q.meta;
        ns += 1;
        raw("<h3 id=\"");
        catId(q.meta);
        raw("\">");
        esc(q.meta);
        raw("</h3><ul class=\"cols\">");
        for (pages) |r| {
            if (r.sec != .wiki or !std.mem.eql(u8, r.meta, q.meta)) continue;
            raw("<li><a class=\"wl\" href=\"#/");
            raw(r.slug);
            raw("\">");
            esc(r.title);
            raw("</a></li>");
        }
        raw("</ul>");
    }
}

/// カテゴリ名 → id(バイト列を 16 進にする。日本語でも一意)
fn catId(s: []const u8) void {
    raw("cat-");
    var buf: [2]u8 = undefined;
    for (s[0..@min(s.len, 24)]) |ch| {
        _ = std.fmt.bufPrint(&buf, "{x:0>2}", .{ch}) catch return;
        raw(&buf);
    }
}

/// ブログの一覧(新しい順)
fn blogIndex() void {
    raw("<ul class=\"posts\">");
    var k: usize = pages.len;
    while (k > 0) {
        k -= 1;
        const q = pages[k];
        if (q.sec != .blog or q.meta.len == 0) continue;
        raw("<li><time>");
        raw(q.meta);
        raw("</time><a href=\"#/");
        raw(q.slug);
        raw("\">");
        esc(q.title);
        raw("</a></li>");
    }
    raw("</ul>");
}

// ---------------------------------------------------------------------------

var cur_sec: Sec = .doc;

fn reset() void {
    out_len = 0;
    overflow = false;
}

fn raw(s: []const u8) void {
    if (out_len + s.len > out_buf.len) {
        overflow = true;
        return;
    }
    @memcpy(out_buf[out_len..][0..s.len], s);
    out_len += s.len;
}

fn esc(s: []const u8) void {
    var start: usize = 0;
    for (s, 0..) |ch, k| {
        const rep: ?[]const u8 = switch (ch) {
            '&' => "&amp;",
            '<' => "&lt;",
            '>' => "&gt;",
            '"' => "&quot;",
            else => null,
        };
        if (rep) |r| {
            raw(s[start..k]);
            raw(r);
            start = k + 1;
        }
    }
    raw(s[start..]);
}

const Heading = struct { text: []const u8, id: []const u8 };

var id_buf: [16]u8 = undefined;

/// 「見出し {#id}」→ 本文と id(無ければ sec-番号)
fn splitId(s: []const u8, n: u32) Heading {
    const tt = std.mem.trimRight(u8, s, " ");
    if (std.mem.endsWith(u8, tt, "}")) {
        if (std.mem.lastIndexOf(u8, tt, " {#")) |k| {
            return .{ .text = tt[0..k], .id = tt[k + 3 .. tt.len - 1] };
        }
    }
    const id = std.fmt.bufPrint(&id_buf, "sec-{d}", .{n}) catch "sec";
    return .{ .text = tt, .id = id };
}

/// 行内の書式: **太字** `コード` [文字](URL) [[wiki の項目]] [[項目|文字]]
fn inlineText(s: []const u8) void {
    var k: usize = 0;
    var plain: usize = 0;
    while (k < s.len) {
        if (s[k] == '`') {
            if (std.mem.indexOfScalarPos(u8, s, k + 1, '`')) |e| {
                esc(s[plain..k]);
                raw("<code>");
                esc(s[k + 1 .. e]);
                raw("</code>");
                k = e + 1;
                plain = k;
                continue;
            }
        } else if (s[k] == '*' and k + 1 < s.len and s[k + 1] == '*') {
            if (std.mem.indexOfPos(u8, s, k + 2, "**")) |e| {
                esc(s[plain..k]);
                raw("<strong>");
                inlineText(s[k + 2 .. e]);
                raw("</strong>");
                k = e + 2;
                plain = k;
                continue;
            }
        } else if (s[k] == '[' and k + 1 < s.len and s[k + 1] == '[') {
            if (std.mem.indexOfPos(u8, s, k + 2, "]]")) |e| {
                esc(s[plain..k]);
                wikiLink(s[k + 2 .. e]);
                k = e + 2;
                plain = k;
                continue;
            }
        } else if (s[k] == '[') {
            if (std.mem.indexOfPos(u8, s, k + 1, "](")) |m| {
                if (std.mem.indexOfScalarPos(u8, s, m + 2, ')')) |e| {
                    const url = s[m + 2 .. e];
                    esc(s[plain..k]);
                    raw("<a href=\"");
                    esc(url);
                    raw("\"");
                    if (std.mem.startsWith(u8, url, "http")) raw(" target=\"_blank\" rel=\"noopener\"");
                    raw(">");
                    inlineText(s[k + 1 .. m]);
                    raw("</a>");
                    k = e + 1;
                    plain = k;
                    continue;
                }
            }
        }
        k += 1;
    }
    esc(s[plain..]);
}

/// [[slug]] / [[slug|文字]]: Wiki の項目へのリンク。項目が無ければ赤いリンク(Wikipedia と同じ)
fn wikiLink(inner: []const u8) void {
    var slug = inner;
    var label: []const u8 = "";
    if (std.mem.indexOfScalar(u8, inner, '|')) |bar| {
        slug = inner[0..bar];
        label = inner[bar + 1 ..];
    }
    var sb: [96]u8 = undefined;
    const full = std.fmt.bufPrint(&sb, "wiki/{s}", .{slug}) catch slug;
    const found = findSlug(full);
    raw("<a class=\"wl");
    if (found == null) raw(" new");
    raw("\" href=\"#/");
    esc(full);
    raw("\"");
    if (found) |fi| {
        raw(" title=\"");
        esc(pages[fi].title);
        raw("\"");
    }
    raw(">");
    if (label.len > 0) inlineText(label) else if (found) |fi| esc(pages[fi].title) else esc(slug);
    raw("</a>");
}

/// 表のセル: 先頭の ✓ ✗ △ に色を付ける
fn cell(s: []const u8) void {
    const marks = [_]struct { m: []const u8, cls: []const u8 }{
        .{ .m = "✓", .cls = "yes" },
        .{ .m = "✗", .cls = "no" },
        .{ .m = "△", .cls = "part" },
    };
    for (marks) |mk| if (std.mem.startsWith(u8, s, mk.m)) {
        raw("<span class=\"");
        raw(mk.cls);
        raw("\">");
        raw(mk.m);
        raw("</span>");
        inlineText(s[mk.m.len..]);
        return;
    };
    inlineText(s);
}

fn splitBar(line: []const u8) std.mem.SplitIterator(u8, .scalar) {
    return std.mem.splitScalar(u8, line, '|');
}

fn trim(s: []const u8) []const u8 {
    return std.mem.trim(u8, s, " \t");
}

const Block = enum { none, para, ul, ol, quote, table };
const Mode = enum { normal, stats, cards, infobox };

fn renderDoc(src: []const u8, page: Page) void {
    var lines = std.mem.splitScalar(u8, src, '\n');
    var block: Block = .none;
    var h2n: u32 = 0;
    var table_row: u32 = 0;
    var mode: Mode = .normal;
    var toc_done = false;
    // Wiki: 見出しが 3 つ以上あれば、最初の ## の前に目次の箱(Wikipedia と同じ)
    var n_h2: u32 = 0;
    {
        var it = std.mem.splitScalar(u8, src, '\n');
        var in_code = false;
        while (it.next()) |l| {
            if (std.mem.startsWith(u8, l, "```")) in_code = !in_code;
            if (!in_code and std.mem.startsWith(u8, l, "## ")) n_h2 += 1;
        }
    }
    const wiki_toc = page.sec == .wiki and n_h2 >= 3;

    while (lines.next()) |line_raw| {
        const line = std.mem.trimRight(u8, line_raw, " \r");

        // ---- コード ----
        if (std.mem.startsWith(u8, line, "```")) {
            close(&block);
            const lang = trim(line[3..]);
            raw("<pre class=\"code\"");
            if (lang.len > 0) {
                raw(" data-lang=\"");
                esc(lang);
                raw("\"");
            }
            raw("><code>");
            var first = true;
            while (lines.next()) |cl| {
                if (std.mem.startsWith(u8, cl, "```")) break;
                if (!first) raw("\n");
                first = false;
                esc(std.mem.trimRight(u8, cl, "\r"));
            }
            raw("</code></pre>");
            continue;
        }

        // ---- 空行 ----
        if (line.len == 0) {
            close(&block);
            endMode(&mode);
            continue;
        }

        // ---- ::stats / ::cards / ::infobox の中身 ----
        if (mode != .normal) {
            var it = splitBar(line);
            switch (mode) {
                .stats => {
                    const v = trim(it.next() orelse "");
                    const l = trim(it.next() orelse "");
                    raw("<div class=\"stat\"><b>");
                    inlineText(v);
                    raw("</b><span>");
                    inlineText(l);
                    raw("</span></div>");
                },
                .cards => {
                    const ic = trim(it.next() orelse "");
                    const tt = trim(it.next() orelse "");
                    const bd = trim(it.rest());
                    raw("<div class=\"card\"><i>");
                    esc(ic);
                    raw("</i><h4>");
                    inlineText(tt);
                    raw("</h4><p>");
                    inlineText(bd);
                    raw("</p></div>");
                },
                .infobox => {
                    const k = trim(it.next() orelse "");
                    const v = trim(it.rest());
                    raw("<tr><th>");
                    inlineText(k);
                    raw("</th><td>");
                    inlineText(v);
                    raw("</td></tr>");
                },
                .normal => {},
            }
            continue;
        }

        // ---- 囲み(:::easy 題 … :::)----
        if (std.mem.startsWith(u8, line, ":::")) {
            close(&block);
            const rest = trim(line[3..]);
            if (rest.len == 0) {
                raw("</div>");
            } else {
                var sp = std.mem.splitScalar(u8, rest, ' ');
                const kind = sp.next() orelse "";
                const title = trim(sp.rest());
                raw("<div class=\"box ");
                esc(kind);
                raw("\"><p class=\"box-h\">");
                raw(if (std.mem.eql(u8, kind, "easy")) "はじめての人へ" else if (std.mem.eql(u8, kind, "research")) "研究者向け" else if (std.mem.eql(u8, kind, "math")) "数式" else "くわしく");
                if (title.len > 0) {
                    raw(" — ");
                    inlineText(title);
                }
                raw("</p>");
            }
            continue;
        }

        // ---- 生の HTML ----
        if (line[0] == '<') {
            close(&block);
            raw(line);
            raw("\n");
            continue;
        }

        // ---- 独自ブロック ----
        if (std.mem.startsWith(u8, line, "::")) {
            close(&block);
            var it = splitBar(line[2..]);
            var head = std.mem.tokenizeScalar(u8, trim(it.next() orelse ""), ' ');
            const kind = head.next() orelse "";
            const arg = trim(head.rest());
            const cap = trim(it.rest());
            if (std.mem.eql(u8, kind, "video")) {
                raw("<figure class=\"media\"><video src=\"media/");
                esc(arg);
                raw(".mp4\" poster=\"media/");
                esc(arg);
                raw(".jpg\" muted loop playsinline preload=\"none\" data-autoplay></video>");
                caption(cap);
            } else if (std.mem.eql(u8, kind, "img")) {
                raw("<figure class=\"media\"><img loading=\"lazy\" src=\"media/");
                esc(arg);
                raw("\" alt=\"");
                esc(cap);
                raw("\">");
                caption(cap);
            } else if (std.mem.eql(u8, kind, "demo")) {
                raw("<div class=\"demo\" data-demo=\"");
                esc(arg);
                raw("\"></div>");
            } else if (std.mem.eql(u8, kind, "stats")) {
                raw("<div class=\"stats\">");
                mode = .stats;
            } else if (std.mem.eql(u8, kind, "cards")) {
                raw("<div class=\"cards\">");
                mode = .cards;
            } else if (std.mem.eql(u8, kind, "infobox")) {
                raw("<table class=\"infobox\"><caption>");
                inlineText(if (arg.len > 0) arg else page.title);
                raw("</caption>");
                mode = .infobox;
            }
            continue;
        }

        // ---- 見出し ----
        if (line[0] == '#') {
            close(&block);
            var lvl: usize = 0;
            while (lvl < line.len and line[lvl] == '#') lvl += 1;
            const body = trim(line[lvl..]);
            if (lvl == 2) {
                if (wiki_toc and !toc_done) {
                    toc_done = true;
                    raw("<div class=\"wtoc\"><p>目次</p>");
                    var it = std.mem.splitScalar(u8, src, '\n');
                    var n: u32 = 0;
                    var in_code = false;
                    raw("<ol>");
                    while (it.next()) |l| {
                        if (std.mem.startsWith(u8, l, "```")) in_code = !in_code;
                        if (in_code or !std.mem.startsWith(u8, l, "## ")) continue;
                        n += 1;
                        const h = splitId(l[3..], n);
                        raw("<li><a href=\"#");
                        esc(h.id);
                        raw("\">");
                        inlineText(h.text);
                        raw("</a></li>");
                    }
                    raw("</ol></div>");
                }
                h2n += 1;
                const h = splitId(body, h2n);
                raw("<h2 id=\"");
                esc(h.id);
                raw("\"><a class=\"anchor\" href=\"#");
                esc(h.id);
                raw("\">#</a>");
                inlineText(h.text);
                raw("</h2>");
            } else {
                const tag = if (lvl <= 1) "h1" else "h3";
                raw("<");
                raw(tag);
                var text = body;
                if (std.mem.endsWith(u8, body, "}")) if (std.mem.lastIndexOf(u8, body, " {#")) |k| {
                    raw(" id=\"");
                    esc(body[k + 3 .. body.len - 1]);
                    raw("\"");
                    text = body[0..k];
                };
                raw(">");
                inlineText(text);
                raw("</");
                raw(tag);
                raw(">");
                if (lvl <= 1) {
                    if (page.sec == .wiki and !std.mem.eql(u8, page.slug, "wiki")) raw("<p class=\"wsub\">出典: ame-shell Wiki — ame-shell の用語集</p>");
                    if (page.sec == .blog and page.meta.len > 0) {
                        raw("<p class=\"post-meta\"><time>");
                        raw(page.meta);
                        raw("</time> · ame-shell 開発ブログ</p>");
                    }
                }
            }
            continue;
        }

        // ---- 表 ----
        if (line[0] == '|') {
            if (block != .table) {
                close(&block);
                raw("<div class=\"table\"><table>");
                block = .table;
                table_row = 0;
            }
            const inner = trim(line)[1..];
            const row = if (std.mem.endsWith(u8, inner, "|")) inner[0 .. inner.len - 1] else inner;
            if (std.mem.indexOf(u8, row, "---") != null and std.mem.indexOfAny(u8, row, "abcdefghijklmnopqrstuvwxyz") == null) continue;
            const tag = if (table_row == 0) "th" else "td";
            raw("<tr>");
            var cells = splitBar(row);
            while (cells.next()) |cc| {
                raw("<");
                raw(tag);
                raw(">");
                cell(trim(cc));
                raw("</");
                raw(tag);
                raw(">");
            }
            raw("</tr>");
            table_row += 1;
            continue;
        }

        // ---- 箇条書き ----
        if (std.mem.startsWith(u8, line, "- ")) {
            if (block != .ul) {
                close(&block);
                raw("<ul>");
                block = .ul;
            }
            raw("<li>");
            inlineText(line[2..]);
            raw("</li>");
            continue;
        }
        if (line.len > 3 and std.ascii.isDigit(line[0]) and std.mem.indexOf(u8, line[0..@min(4, line.len)], ". ") != null) {
            if (block != .ol) {
                close(&block);
                raw("<ol>");
                block = .ol;
            }
            const k = std.mem.indexOf(u8, line, ". ").?;
            raw("<li>");
            inlineText(line[k + 2 ..]);
            raw("</li>");
            continue;
        }
        if ((block == .ul or block == .ol) and std.mem.startsWith(u8, line, "  ")) {
            out_len -|= "</li>".len;
            raw("<br>");
            inlineText(trim(line));
            raw("</li>");
            continue;
        }

        // ---- 補足 ----
        if (line[0] == '>') {
            const warn = line.len > 1 and line[1] == '!';
            const body = trim(line[if (warn) 2 else 1..]);
            if (block != .quote) {
                close(&block);
                raw(if (warn) "<aside class=\"note warn\"><p>" else "<aside class=\"note\"><p>");
                block = .quote;
            } else raw("<br>");
            inlineText(body);
            continue;
        }

        // ---- 段落 ----
        if (block != .para) {
            close(&block);
            raw("<p>");
            block = .para;
        } else raw(" ");
        inlineText(line);
    }
    close(&block);
    endMode(&mode);
}

fn endMode(m: *Mode) void {
    switch (m.*) {
        .stats, .cards => raw("</div>"),
        .infobox => raw("</table>"),
        .normal => {},
    }
    m.* = .normal;
}

fn caption(cap: []const u8) void {
    if (cap.len > 0) {
        raw("<figcaption>");
        inlineText(cap);
        raw("</figcaption>");
    }
    raw("</figure>");
}

fn close(bl: *Block) void {
    switch (bl.*) {
        .none => {},
        .para => raw("</p>"),
        .ul => raw("</ul>"),
        .ol => raw("</ol>"),
        .quote => raw("</p></aside>"),
        .table => raw("</table></div>"),
    }
    bl.* = .none;
}
