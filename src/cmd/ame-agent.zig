// ame-agent: コーディング CLI の出力を、共通の出来事(1 行 1 つの JSON)に直すフィルタ。
//
//   claude -p … --output-format stream-json | ame-agent [-f 形式] [-C 作業フォルダ]
//   ame-agent sessions [フォルダ]          Claude Code のそのフォルダの会話(新しい順){"id","title","mtime"}
//   ame-agent history フォルダ 会話の id   その会話の記録を、同じ出来事にして出す
//
// 形式: claude(既定。Qwen Code・Cursor Agent・Amp も)/ antigravity(agy)/ gemini / codex / opencode / kimi / raw
// 出来事(読み方は lib/agentfmt.zig。ame-shell の AI チャットのパネルも同じものを使う):
//   {"type":"session","id"}            会話の id(次は --resume などに渡せる)
//   {"type":"delta","text"}            少しずつ届く返事の続き / {"type":"text","text"} まとまった返事
//   {"type":"user","text"}             人の発言(history のときだけ)
//   {"type":"tool","title"}            ツールの実行 / {"type":"result","text","error"} その結果
//   {"type":"error","message"} / {"type":"split"}(返事の区切り)/ {"type":"done","cost"}
//   {"type":"raw","text"}              JSON でない行(色の指定は取り除く)
// -C を付けると、ツールの見出しのパスからそのフォルダを省く。
const std = @import("std");
const af = @import("ame_lib").agentfmt;

var out: std.io.BufferedWriter(4096, std.fs.File.Writer) = undefined;

fn write(v: anytype) void {
    const w = out.writer();
    std.json.stringify(v, .{}, w) catch return;
    w.writeByte('\n') catch return;
}

fn emit(_: *anyopaque, e: af.Event) void {
    switch (e) {
        .session => |s| write(.{ .type = "session", .id = s }),
        .tool => |s| write(.{ .type = "tool", .title = s }),
        .result => |r| write(.{ .type = "result", .text = r.text, .@"error" = r.err }),
        .@"error" => |s| write(.{ .type = "error", .message = s }),
        .split => write(.{ .type = "split" }),
        .done => |d| write(.{ .type = "done", .cost = d.cost }),
        inline .delta, .text, .user, .raw => |s, tag| write(.{ .type = @tagName(tag), .text = s }),
    }
}

fn usage() noreturn {
    std.io.getStdErr().writeAll(
        \\使い方: CLI の出力 | ame-agent [-f claude|antigravity|gemini|codex|opencode|kimi|raw] [-C フォルダ]
        \\        ame-agent sessions [フォルダ]
        \\        ame-agent history フォルダ 会話の id
        \\
    ) catch {};
    std.process.exit(2);
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const a = gpa.allocator();
    const args = try std.process.argsAlloc(a);
    out = std.io.bufferedWriter(std.io.getStdOut().writer());
    defer out.flush() catch {};
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const here = std.process.getCwd(&cwd_buf) catch ".";
    var dummy: u8 = 0;

    if (args.len >= 2 and std.mem.eql(u8, args[1], "sessions")) {
        if (args.len > 3) usage();
        var arena = std.heap.ArenaAllocator.init(a);
        var list = std.ArrayList(af.SessionInfo).init(a);
        af.listSessions(arena.allocator(), if (args.len == 3) args[2] else here, &list);
        for (list.items) |s| write(.{ .id = s.id, .title = s.title, .mtime = @divTrunc(s.mtime, std.time.ns_per_s) });
        return;
    }
    if (args.len >= 2 and std.mem.eql(u8, args[1], "history")) {
        if (args.len != 4) usage();
        var p = af.Parser{ .fmt = .claude, .live = false, .cwd = args[2], .ctx = &dummy, .emit = emit, .alloc = a };
        if (!af.loadHistory(a, args[2], args[3], &p)) {
            out.flush() catch {};
            std.io.getStdErr().writer().print("ame-agent: 会話の記録が見つかりません: {s}\n", .{args[3]}) catch {};
            std.process.exit(1);
        }
        return;
    }

    var p = af.Parser{ .fmt = .claude, .ctx = &dummy, .emit = emit, .alloc = a };
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const x = args[i];
        if (i + 1 >= args.len) usage();
        if (std.mem.eql(u8, x, "-f")) {
            i += 1;
            p.fmt = af.Fmt.parse(args[i]) orelse usage();
        } else if (std.mem.eql(u8, x, "-C")) {
            i += 1;
            p.cwd = args[i];
        } else usage();
    }
    // 1 行ずつ読み、行ごとに出す(パイプの先がすぐ表示できるように)
    var line = std.ArrayList(u8).init(a);
    const r = std.io.getStdIn().reader();
    while (true) {
        line.clearRetainingCapacity();
        r.streamUntilDelimiter(line.writer(), '\n', 64 << 20) catch |e| switch (e) {
            error.EndOfStream => {
                if (line.items.len > 0) p.line(line.items);
                break;
            },
            error.StreamTooLong => {
                r.skipUntilDelimiterOrEof('\n') catch break;
                continue;
            },
            else => return e,
        };
        p.line(line.items);
        try out.flush();
    }
}
