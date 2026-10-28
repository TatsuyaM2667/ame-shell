// ame-shell ドキュメントサイトの描画エンジン(Zig → wasm32-freestanding)。
//
// 各ページの本文(content/*.md、Markdown の小さな部分集合 + 独自のブロック)をビルド時に埋め込み、
// ブラウザ上でこの WebAssembly が HTML に変換する。JavaScript は wasm を読み込んで結果を DOM に
// 入れるだけ(static/app.js)。デモ(スプリング・あいまい検索・主色抽出)は ame-shell 本体と同じ
// Odin のコア(anim/anim.odin)を wasm にしたものを app.js から呼ぶ。
//
// 書式:
//   # 見出し / ## 見出し {#id} / ### 見出し     段落は空行で区切る
//   - 箇条書き / 1. 番号付き / > 補足(>! で注意) / ``` コード ``` / | 表 |(2 行目は |---|)
//   ::video 名前 | 説明     media/名前.mp4(ポスターは media/名前.jpg)
//   ::img ファイル | 説明     media/ファイル
//   ::demo spring|fuzzy|color
//   ::stats  の次の行から空行まで「値 | 説明」     ::cards  の次の行から空行まで「アイコン | 題 | 本文」
//   < で始まる行は HTML をそのまま
//   行内: **太字** `コード` [文字](URL)   表のセルの先頭の ✓ ✗ △ は色付き

const std = @import("std");

const Page = struct { slug: []const u8, title: []const u8, src: []const u8 };

const pages = [_]Page{
    .{ .slug = "", .title = "ホーム", .src = @embedFile("content/home.md") },
    .{ .slug = "animation", .title = "アニメーション", .src = @embedFile("content/animation.md") },
    .{ .slug = "shell", .title = "シェルの機能", .src = @embedFile("content/shell.md") },
    .{ .slug = "rendering", .title = "描画とガラス", .src = @embedFile("content/rendering.md") },
    .{ .slug = "performance", .title = "性能", .src = @embedFile("content/performance.md") },
    .{ .slug = "compare", .title = "ほかの WM と比較", .src = @embedFile("content/compare.md") },
    .{ .slug = "install", .title = "インストール", .src = @embedFile("content/install.md") },
    .{ .slug = "reference", .title = "リファレンス", .src = @embedFile("content/reference.md") },
    .{ .slug = "architecture", .title = "設計", .src = @embedFile("content/architecture.md") },
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
    const s = in_buf[0..@min(len, in_buf.len)];
    for (pages, 0..) |p, i| if (std.mem.eql(u8, p.slug, s)) return @intCast(i);
    return -1;
}

/// ページの題(out に書く)。戻り値は長さ
export fn page_title(i: u32) u32 {
    reset();
    if (i < pages.len) raw(pages[i].title);
    return @intCast(out_len);
}

/// ナビゲーション(今のページに印)
export fn render_nav(cur: u32) u32 {
    reset();
    for (pages, 0..) |p, i| {
        raw("<a href=\"#/");
        raw(p.slug);
        raw("\"");
        if (i == cur) raw(" class=\"on\" aria-current=\"page\"");
        raw(">");
        esc(p.title);
        raw("</a>");
    }
    return @intCast(out_len);
}

/// ページ本文の HTML。戻り値は長さ
export fn render_page(i: u32) u32 {
    reset();
    if (i >= pages.len) {
        raw("<h1>ページが見つかりません</h1><p><a href=\"#/\">ホームへ</a></p>");
        return @intCast(out_len);
    }
    renderDoc(pages[i].src);
    // 前後のページへのリンク
    raw("<nav class=\"pager\">");
    if (i > 0) {
        raw("<a class=\"prev\" href=\"#/");
        raw(pages[i - 1].slug);
        raw("\"><small>前へ</small>");
        esc(pages[i - 1].title);
        raw("</a>");
    }
    if (i + 1 < pages.len) {
        raw("<a class=\"next\" href=\"#/");
        raw(pages[i + 1].slug);
        raw("\"><small>次へ</small>");
        esc(pages[i + 1].title);
        raw("</a>");
    }
    raw("</nav>");
    if (overflow) raw("<p>(ページが大きすぎます)</p>");
    return @intCast(out_len);
}

/// ページ内の目次(## の見出し)
export fn render_toc(i: u32) u32 {
    reset();
    if (i >= pages.len) return 0;
    var it = std.mem.splitScalar(u8, pages[i].src, '\n');
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
    return @intCast(out_len);
}

// ---------------------------------------------------------------------------

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
    const t = std.mem.trimRight(u8, s, " ");
    if (std.mem.endsWith(u8, t, "}")) {
        if (std.mem.lastIndexOf(u8, t, " {#")) |k| {
            return .{ .text = t[0..k], .id = t[k + 3 .. t.len - 1] };
        }
    }
    const id = std.fmt.bufPrint(&id_buf, "sec-{d}", .{n}) catch "sec";
    return .{ .text = t, .id = id };
}

/// 行内の書式: **太字** `コード` [文字](URL)
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

fn renderDoc(src: []const u8) void {
    var lines = std.mem.splitScalar(u8, src, '\n');
    var block: Block = .none;
    var h2n: u32 = 0;
    var table_row: u32 = 0;
    var mode: enum { normal, stats, cards } = .normal;

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

        // ---- 空行: ブロックを閉じる ----
        if (line.len == 0) {
            close(&block);
            switch (mode) {
                .stats, .cards => raw("</div>"),
                .normal => {},
            }
            mode = .normal;
            continue;
        }

        // ---- ::stats / ::cards の中身 ----
        if (mode == .stats) {
            var it = splitBar(line);
            const v = trim(it.next() orelse "");
            const l = trim(it.next() orelse "");
            raw("<div class=\"stat\"><b>");
            inlineText(v);
            raw("</b><span>");
            inlineText(l);
            raw("</span></div>");
            continue;
        }
        if (mode == .cards) {
            var it = splitBar(line);
            const ic = trim(it.next() orelse "");
            const t = trim(it.next() orelse "");
            const b = trim(it.rest());
            raw("<div class=\"card\"><i>");
            esc(ic);
            raw("</i><h4>");
            inlineText(t);
            raw("</h4><p>");
            inlineText(b);
            raw("</p></div>");
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
            const arg = head.next() orelse "";
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
                raw(">");
                inlineText(body);
                raw("</");
                raw(tag);
                raw(">");
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
        // 箇条書きの続きの行(字下げ)
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
    switch (mode) {
        .stats, .cards => raw("</div>"),
        .normal => {},
    }
}

fn caption(cap: []const u8) void {
    if (cap.len > 0) {
        raw("<figcaption>");
        inlineText(cap);
        raw("</figcaption>");
    }
    raw("</figure>");
}

fn close(b: *Block) void {
    switch (b.*) {
        .none => {},
        .para => raw("</p>"),
        .ul => raw("</ul>"),
        .ol => raw("</ol>"),
        .quote => raw("</p></aside>"),
        .table => raw("</table></div>"),
    }
    b.* = .none;
}

