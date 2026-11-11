// refcheck: 学習ページが指すコードの場所が、本当にあるかを確かめる。
//
//   zig run learn/tools/refcheck.zig            (ame-shell のフォルダで)
//   zig run learn/tools/refcheck.zig -- <フォルダ>   (別のフォルダの .md を調べる)
//
// 調べるもの(site/src/content/learn/*.md):
//   ::code パス:行 名前 | 説明     → ファイルがあり、その行に「名前」が書いてあるか
//   `パス` / `パス:行`(行内のコード) → ファイルがあり、行がファイルの長さ以内か
//     (パスは src/・anim/・widgets/・learn/・docs/・session/・scripts/ で始まるものだけ)
// 1 つでも合わなければ、場所と理由を出して 1 で終わる。
const std = @import("std");

const prefixes = [_][]const u8{ "src/", "anim/", "widgets/", "learn/", "docs/", "session/", "scripts/" };

var bad: usize = 0;
var checked: usize = 0;

fn report(md: []const u8, ln: usize, comptime fmt: []const u8, args: anytype) void {
    std.debug.print("✗ {s}:{d}: " ++ fmt ++ "\n", .{ md, ln } ++ args);
    bad += 1;
}

/// ファイルの n 行目(1 から)。無ければ null。lines には行の数を返す
fn lineOf(a: std.mem.Allocator, path: []const u8, n: usize, lines: *usize) !?[]const u8 {
    const data = std.fs.cwd().readFileAlloc(a, path, 8 << 20) catch return error.NoFile;
    var it = std.mem.splitScalar(u8, data, '\n');
    var i: usize = 0;
    var found: ?[]const u8 = null;
    while (it.next()) |l| {
        i += 1;
        if (i == n) found = l;
    }
    lines.* = i;
    return found;
}

fn checkLoc(a: std.mem.Allocator, md: []const u8, ln: usize, loc: []const u8, name: []const u8) !void {
    checked += 1;
    const colon = std.mem.lastIndexOfScalar(u8, loc, ':');
    const path = if (colon) |c| loc[0..c] else loc;
    const n: usize = if (colon) |c| std.fmt.parseInt(usize, loc[c + 1 ..], 10) catch return report(md, ln, "行番号が数でない: {s}", .{loc}) else 0;
    var lines: usize = 0;
    const l = lineOf(a, path, n, &lines) catch return report(md, ln, "ファイルが無い: {s}", .{path});
    if (n == 0) return;
    const text = l orelse return report(md, ln, "{s} は {d} 行しかない({d} 行目を指している)", .{ path, lines, n });
    if (name.len > 0 and std.mem.indexOf(u8, text, name) == null)
        report(md, ln, "{s}:{d} に「{s}」が無い(その行: {s})", .{ path, n, name, std.mem.trim(u8, text, " \t") });
}

fn isPath(s: []const u8) bool {
    if (std.mem.indexOfAny(u8, s, " *|") != null) return false;
    for (prefixes) |p| if (std.mem.startsWith(u8, s, p)) return true;
    return false;
}

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // 引数でフォルダを変えられる(検査そのものの試験用)
    const args = try std.process.argsAlloc(a);
    const dir_path = if (args.len > 1) args[1] else "site/src/content/learn";
    var dir = try std.fs.cwd().openDir(dir_path, .{ .iterate = true });
    defer dir.close();
    var it = dir.iterate();
    while (try it.next()) |e| {
        if (e.kind != .file or !std.mem.endsWith(u8, e.name, ".md")) continue;
        const md = try std.fmt.allocPrint(a, "{s}/{s}", .{ dir_path, e.name });
        const src = try std.fs.cwd().readFileAlloc(a, md, 4 << 20);
        var lines = std.mem.splitScalar(u8, src, '\n');
        var ln: usize = 0;
        var in_code = false;
        while (lines.next()) |line| {
            ln += 1;
            if (std.mem.startsWith(u8, line, "```")) {
                in_code = !in_code;
                continue;
            }
            if (in_code) continue;
            if (std.mem.startsWith(u8, line, "::code ")) {
                const head = std.mem.trim(u8, line[7 .. std.mem.indexOfScalar(u8, line, '|') orelse line.len], " ");
                var hs = std.mem.tokenizeScalar(u8, head, ' ');
                const loc = hs.next() orelse continue;
                try checkLoc(a, md, ln, loc, std.mem.trim(u8, hs.rest(), " "));
                continue;
            }
            // 行内の `パス` / `パス:行`
            var k: usize = 0;
            while (std.mem.indexOfScalarPos(u8, line, k, '`')) |s| {
                const e2 = std.mem.indexOfScalarPos(u8, line, s + 1, '`') orelse break;
                const inner = line[s + 1 .. e2];
                if (isPath(inner)) try checkLoc(a, md, ln, inner, "");
                k = e2 + 1;
            }
        }
    }
    if (bad > 0) {
        std.debug.print("\n{d} 個の参照のうち {d} 個が合いません\n", .{ checked, bad });
        std.process.exit(1);
    }
    std.debug.print("✓ {d} 個のコードの参照は、すべて実在します\n", .{checked});
}
