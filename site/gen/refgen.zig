// refgen: ame-shell のソース(Zig・Odin)から関数リファレンスのページを作る(zig build site の途中で実行)。
//
//   refgen <出力.zig> <表示名> <ファイル> [<表示名> <ファイル> ...]
//
// 各ファイルの冒頭のコメントを「ファイルの説明」、関数・型・定数の直前の // / /// コメントを「説明」として集め、
// シグネチャ・定義の行番号・GitHub へのリンクと一緒に Markdown にする。手で書かないので、ソースと必ず一致する。
// 出力は Zig のソース(pub const pages = .{ .{ slug, title, src }, ... })で、site.wasm に埋め込まれる。
const std = @import("std");

const REPO = "https://github.com/TatsuyaM2667/ame-shell/blob/master/";

const Kind = enum { func, type_, constant };

const Entry = struct {
    kind: Kind,
    name: []const u8,
    container: []const u8, // 型の中の関数なら型の名前
    sig: []const u8,
    doc: []const u8,
    line: usize,
};

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const args = try std.process.argsAlloc(a);
    if (args.len < 2) return error.Usage;

    var pages = std.ArrayList(u8).init(a);
    const pw = pages.writer();
    try pw.writeAll("// zig build site が生成(site/gen/refgen.zig)。編集しない。\n");
    try pw.writeAll("pub const Ref = struct { slug: []const u8, title: []const u8, src: []const u8 };\n");
    try pw.writeAll("pub const pages = [_]Ref{\n");

    // 索引のページ(最後に書くので、先に各ファイルの統計を集める)
    var index = std.ArrayList(u8).init(a);
    const iw = index.writer();
    var total_fn: usize = 0;
    var total_lines: usize = 0;
    var file_rows = std.ArrayList(u8).init(a);
    const rw = file_rows.writer();

    var i: usize = 2;
    while (i + 1 < args.len) : (i += 2) {
        const name = args[i];
        const path = args[i + 1];
        const src = try std.fs.cwd().readFileAlloc(a, path, 4 << 20);
        const odin = std.mem.endsWith(u8, name, ".odin");
        var r = try parseFile(a, src, odin);
        total_fn += r.n_fn;
        total_lines += r.lines;

        var md = std.ArrayList(u8).init(a);
        const w = md.writer();
        try w.print("# {s}\n\n", .{name});
        try w.print("<p class=\"file\">{d} 行 · 関数 {d} 個 · 型 {d} 個 · <a href=\"{s}{s}\" target=\"_blank\" rel=\"noopener\">GitHub で開く</a></p>\n\n", .{ r.lines, r.n_fn, r.n_type, REPO, name });
        if (r.header.len > 0) {
            try w.writeAll("## ファイルの説明 {#about}\n\n```text\n");
            try w.writeAll(r.header);
            try w.writeAll("\n```\n\n");
        }
        // 型ごとにまとめる(先頭はファイル直下)
        var groups = std.ArrayList([]const u8).init(a);
        try groups.append("");
        for (r.entries.items) |e| {
            if (e.kind == .type_) try groups.append(e.name);
        }
        for (groups.items) |g| {
            var any = false;
            for (r.entries.items) |e| {
                if (!std.mem.eql(u8, e.container, g)) continue;
                if (g.len == 0 and e.kind == .type_) continue;
                any = true;
                break;
            }
            // 型そのものの説明
            var tentry: ?Entry = null;
            for (r.entries.items) |e| if (e.kind == .type_ and std.mem.eql(u8, e.name, g)) {
                tentry = e;
            };
            if (!any and tentry == null) continue;
            if (g.len == 0) {
                try w.writeAll("## ファイル直下 {#top}\n\n");
            } else {
                try w.print("## 型 {s} {{#t-{s}}}\n\n", .{ g, g });
                if (tentry) |t| try writeEntryBody(w, t, name, odin);
            }
            for (r.entries.items) |e| {
                if (!std.mem.eql(u8, e.container, g)) continue;
                if (e.kind == .type_) continue;
                const label = switch (e.kind) {
                    .func => "関数",
                    .constant => "定数",
                    .type_ => "型",
                };
                if (g.len > 0) {
                    try w.print("### {s}.{s} <small>{s}</small> {{#{s}-{s}}}\n\n", .{ g, e.name, label, g, e.name });
                } else {
                    try w.print("### {s} <small>{s}</small> {{#{s}}}\n\n", .{ e.name, label, e.name });
                }
                try writeEntryBody(w, e, name, odin);
            }
        }
        const slug = try std.fmt.allocPrint(a, "ref/{s}", .{name});
        try pw.print("    .{{ .slug = \"{s}\", .title = \"{s}\", .src = \"{}\" }},\n", .{ slug, name, std.zig.fmtEscapes(md.items) });
        try rw.print("| [{s}](#/{s}) | {d} | {d} | {d} | {s} |\n", .{ name, slug, r.lines, r.n_fn, r.n_type, firstLine(r.header) });
        r.entries.deinit();
    }

    try iw.writeAll("# 関数リファレンス\n\n");
    try iw.print("<p class=\"file\">{d} ファイル · {d} 行 · 関数 {d} 個(ソースから自動生成)</p>\n\n", .{ (args.len - 2) / 2, total_lines, total_fn });
    try iw.writeAll(
        \\ame-shell のすべてのファイルについて、**関数・型・定数を 1 つずつ**、シグネチャ(引数と戻り値の型)・説明コメント・定義の行番号・GitHub へのリンクと一緒に並べています。
        \\
        \\このリファレンスは `zig build site` のときに `site/gen/refgen.zig` がソースを読んで作ります。**手で書いていないので、ソースと必ず一致します**。説明は、ソースの中のコメント(`//` と `///`)そのものです。
        \\
        \\> 読み方: まず[技術解説](#/tech)で全体の仕組みをつかみ、気になった関数をここで引くのがおすすめです。用語は [Wiki](#/wiki) にあります。
        \\
        \\## ファイルの一覧 {#files}
        \\
        \\| ファイル | 行 | 関数 | 型 | 冒頭の説明 |
        \\|---|---|---|---|---|
        \\
    );
    try iw.writeAll(file_rows.items);
    try pw.print("    .{{ .slug = \"ref\", .title = \"関数リファレンス\", .src = \"{}\" }},\n", .{std.zig.fmtEscapes(index.items)});
    try pw.writeAll("};\n");

    const out = try std.fs.cwd().createFile(args[1], .{});
    defer out.close();
    try out.writeAll(pages.items);
}

fn firstLine(s: []const u8) []const u8 {
    const l = if (std.mem.indexOfScalar(u8, s, '\n')) |k| s[0..k] else s;
    // 表を壊さないよう | を除き、長すぎるものは切る
    var end = @min(l.len, 120);
    while (end > 0 and end < l.len and (l[end] & 0xC0) == 0x80) end -= 1;
    const cut = l[0..end];
    if (std.mem.indexOfScalar(u8, cut, '|') != null) return "";
    return cut;
}

fn writeEntryBody(w: anytype, e: Entry, file: []const u8, odin: bool) !void {
    try w.print("```{s}\n{s}\n```\n\n", .{ if (odin) "odin" else "zig", e.sig });
    if (e.doc.len > 0) {
        try w.writeAll("```text\n");
        try w.writeAll(e.doc);
        try w.writeAll("\n```\n\n");
    } else {
        try w.writeAll("(説明コメントなし。名前とシグネチャ、[技術解説](#/tech)を参照)\n\n");
    }
    try w.print("定義: [{s}:{d}]({s}{s}#L{d})\n\n", .{ file, e.line, REPO, file, e.line });
}

const Parsed = struct {
    header: []const u8,
    entries: std.ArrayList(Entry),
    lines: usize,
    n_fn: usize,
    n_type: usize,
};

fn trimComment(l: []const u8) ?[]const u8 {
    const t = std.mem.trimLeft(u8, l, " \t");
    if (std.mem.startsWith(u8, t, "///")) return std.mem.trim(u8, t[3..], " ");
    if (std.mem.startsWith(u8, t, "//")) return std.mem.trim(u8, t[2..], " ");
    return null;
}

fn indentOf(l: []const u8) usize {
    var n: usize = 0;
    while (n < l.len and (l[n] == ' ' or l[n] == '\t')) n += 1;
    return n;
}

fn isIdent(ch: u8) bool {
    return std.ascii.isAlphanumeric(ch) or ch == '_';
}

fn parseFile(a: std.mem.Allocator, src: []const u8, odin: bool) !Parsed {
    var lines = std.ArrayList([]const u8).init(a);
    var it = std.mem.splitScalar(u8, src, '\n');
    while (it.next()) |l| try lines.append(std.mem.trimRight(u8, l, "\r"));
    const L = lines.items;

    // ファイル冒頭のコメント
    var header = std.ArrayList(u8).init(a);
    var k: usize = 0;
    while (k < L.len) : (k += 1) {
        const t = std.mem.trimLeft(u8, L[k], " ");
        if (std.mem.startsWith(u8, t, "package ")) continue; // Odin
        const cm = trimComment(L[k]) orelse break;
        if (header.items.len > 0) try header.append('\n');
        try header.appendSlice(cm);
    }

    var entries = std.ArrayList(Entry).init(a);
    var n_fn: usize = 0;
    var n_type: usize = 0;
    // 型の入れ子(名前と字下げ)
    var stack = std.ArrayList(struct { name: []const u8, indent: usize }).init(a);

    for (L, 0..) |line, idx| {
        const ind = indentOf(line);
        const t = line[ind..];
        // 型の終わり
        if (stack.items.len > 0 and std.mem.startsWith(u8, t, "}") and ind == stack.items[stack.items.len - 1].indent) {
            _ = stack.pop();
            continue;
        }
        if (t.len == 0 or std.mem.startsWith(u8, t, "//")) continue;

        var kind: ?Kind = null;
        var name: []const u8 = "";
        if (odin) {
            // name :: proc ... / name :: struct / NAME :: f32(…)
            if (ind == 0) if (std.mem.indexOf(u8, t, " :: ")) |p| {
                name = t[0..p];
                const rest = t[p + 4 ..];
                var ok = name.len > 0;
                for (name) |ch| ok = ok and isIdent(ch);
                if (ok) {
                    if (std.mem.startsWith(u8, rest, "proc")) kind = .func else if (std.mem.startsWith(u8, rest, "struct")) kind = .type_ else kind = .constant;
                }
            };
        } else {
            // fn
            var s = t;
            inline for (.{ "pub ", "export ", "inline ", "extern \"c\" ", "extern " }) |pre| {
                if (std.mem.startsWith(u8, s, pre)) s = s[pre.len..];
            }
            inline for (.{ "pub ", "export ", "inline " }) |pre| {
                if (std.mem.startsWith(u8, s, pre)) s = s[pre.len..];
            }
            if (std.mem.startsWith(u8, s, "fn ")) {
                const after = s[3..];
                var e: usize = 0;
                while (e < after.len and isIdent(after[e])) e += 1;
                if (e > 0) {
                    kind = .func;
                    name = after[0..e];
                }
            } else if (std.mem.startsWith(u8, s, "const ") or std.mem.startsWith(u8, s, "var ")) {
                const after = if (s[0] == 'c') s[6..] else s[4..];
                var e: usize = 0;
                while (e < after.len and isIdent(after[e])) e += 1;
                if (e > 0) {
                    name = after[0..e];
                    const rest = std.mem.trimLeft(u8, after[e..], " ");
                    if (std.mem.startsWith(u8, rest, "= ")) {
                        const v = rest[2..];
                        const is_type = std.mem.indexOf(u8, v, "struct") != null or std.mem.startsWith(u8, v, "enum") or std.mem.startsWith(u8, v, "union");
                        if (is_type and std.mem.endsWith(u8, std.mem.trimRight(u8, v, " "), "{")) {
                            kind = .type_;
                        } else if (ind <= 4 and !std.mem.startsWith(u8, v, "@import")) {
                            // 説明コメントのある定数だけ載せる
                            if (idx > 0 and trimComment(L[idx - 1]) != null) kind = .constant;
                        }
                    }
                }
            }
        }
        const kd = kind orelse continue;
        // ファイル直下(字下げ 0)か、開いている型の直下(その型の字下げ + 4)だけを載せる。
        // 関数の中で作った一時的な型や関数(並べ替えの比較関数など)は載せない
        if (!odin) {
            const expected: usize = if (stack.items.len > 0) stack.items[stack.items.len - 1].indent + 4 else 0;
            if (ind != expected) continue;
        }

        // 直前のコメント(Odin の @(…) 属性は飛ばす)
        var doc_lines = std.ArrayList([]const u8).init(a);
        var j = idx;
        while (j > 0) {
            j -= 1;
            const pt = std.mem.trimLeft(u8, L[j], " \t");
            if (std.mem.startsWith(u8, pt, "@(")) continue;
            const cm = trimComment(L[j]) orelse break;
            try doc_lines.insert(0, cm);
        }
        // ファイル冒頭のコメントは関数の説明にしない
        if (j == 0 and doc_lines.items.len > 0 and header.items.len > 0 and idx < 40 and trimComment(L[0]) != null) {
            var all_header = true;
            for (0..idx) |q| {
                const qt = std.mem.trimLeft(u8, L[q], " ");
                if (trimComment(L[q]) == null and !std.mem.startsWith(u8, qt, "package ") and qt.len > 0) all_header = false;
            }
            if (all_header) doc_lines.clearRetainingCapacity();
        }
        var doc = std.ArrayList(u8).init(a);
        for (doc_lines.items, 0..) |dl, q| {
            if (q > 0) try doc.append('\n');
            try doc.appendSlice(dl);
        }

        // シグネチャ: 「{」か「;」までの最大 6 行
        var sig = std.ArrayList(u8).init(a);
        var m = idx;
        while (m < L.len and m < idx + 6) : (m += 1) {
            const sl = std.mem.trim(u8, L[m], " \t");
            if (m > idx) try sig.append(' ');
            if (std.mem.lastIndexOf(u8, sl, " {")) |b| if (b + 2 == sl.len or std.mem.endsWith(u8, sl, "{")) {
                try sig.appendSlice(sl[0..b]);
                break;
            };
            if (std.mem.endsWith(u8, sl, "{")) {
                try sig.appendSlice(sl[0 .. sl.len - 1]);
                break;
            }
            try sig.appendSlice(sl);
            if (std.mem.endsWith(u8, sl, ";") or std.mem.endsWith(u8, sl, ",") and kd == .constant) break;
        }

        const container = if (stack.items.len > 0) stack.items[stack.items.len - 1].name else "";
        // 型の中の定数・入れ子の型は、最上位の型だけを載せる(読みやすさのため)
        if (kd == .type_ and stack.items.len > 0) {
            try stack.append(.{ .name = name, .indent = ind });
            continue;
        }
        if (kd == .constant and stack.items.len > 0) continue;
        if (kd == .func and stack.items.len > 1) continue;
        try entries.append(.{ .kind = kd, .name = name, .container = container, .sig = sig.items, .doc = doc.items, .line = idx + 1 });
        switch (kd) {
            .func => n_fn += 1,
            .type_ => n_type += 1,
            .constant => {},
        }
        if (kd == .type_ and !odin) try stack.append(.{ .name = name, .indent = ind });
    }
    return .{ .header = header.items, .entries = entries, .lines = L.len, .n_fn = n_fn, .n_type = n_type };
}
