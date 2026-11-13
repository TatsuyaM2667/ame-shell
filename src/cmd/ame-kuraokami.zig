// ame-kuraokami: 今の天気を wttr.in から取ってくる。
// 名前は雨を司る龍神、闇龗神(くらおかみ)から。
//
//   ame-kuraokami [-l 言葉] [場所]          「12°C 晴れ(Sapporo, Japan)」の 1 行
//   ame-kuraokami --json [-l 言葉] [場所]   {"temp","condition","symbol","icon","place"} の 1 行
//
// 場所を省くと IP アドレスから推定。言葉は既定 ja(wttr.in の lang)。icon は Nerd Font の天気のアイコン(夜は月)。
// 終了コード: 0 取れた / 1 場所が分からない・返事の形が違う / 2 つながらない(ame-yatagarasu が要る)
const std = @import("std");
const weather = @import("ame_lib").weather;

fn usage() noreturn {
    std.io.getStdErr().writeAll("使い方: ame-kuraokami [--json] [-l 言葉] [場所]\n") catch {};
    std.process.exit(2);
}

// struct tm(glibc・musl・FreeBSD で同じ並び)
const Tm = extern struct { sec: c_int, min: c_int, hour: c_int, mday: c_int, mon: c_int, year: c_int, wday: c_int, yday: c_int, isdst: c_int, gmtoff: c_long, zone: ?[*:0]const u8 };
extern "c" fn localtime_r(t: *const i64, out: *Tm) ?*Tm;

/// ローカル時刻で夜か(タイムゾーンの扱いは libc に任せる)
fn isNight() bool {
    const t: i64 = std.time.timestamp();
    var tm: Tm = undefined;
    if (localtime_r(&t, &tm) == null) return false;
    return tm.hour < 6 or tm.hour >= 18;
}

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const a = arena.allocator();
    const args = try std.process.argsAlloc(a);
    var json = false;
    var lang: []const u8 = "ja";
    var place: []const u8 = "";
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const x = args[i];
        if (std.mem.eql(u8, x, "--json")) {
            json = true;
        } else if (std.mem.eql(u8, x, "-l")) {
            i += 1;
            if (i >= args.len) usage();
            lang = args[i];
        } else if (x.len > 0 and x[0] == '-') {
            usage();
        } else place = x;
    }
    var ub: [256]u8 = undefined;
    const u = weather.url(place, lang, &ub) orelse usage();
    const r = std.process.Child.run(.{ .allocator = a, .argv = &.{ "ame-yatagarasu", "-s", "--max-time", "8", u }, .max_output_bytes = 4096 }) catch {
        std.io.getStdErr().writeAll("ame-kuraokami: ame-yatagarasu を起動できません\n") catch {};
        std.process.exit(2);
    };
    if (r.term != .Exited or r.term.Exited != 0) {
        std.io.getStdErr().writeAll("ame-kuraokami: wttr.in につながりません\n") catch {};
        std.process.exit(2);
    }
    const rep = weather.parse(r.stdout) orelse {
        std.io.getStdErr().writer().print("ame-kuraokami: 天気が分かりません: {s}\n", .{std.mem.trim(u8, r.stdout, " \n")}) catch {};
        std.process.exit(1);
    };
    const w = std.io.getStdOut().writer();
    if (json) {
        try std.json.stringify(.{ .temp = rep.temp, .condition = rep.condition, .symbol = rep.symbol, .icon = weather.icon(rep.symbol, isNight()), .place = rep.place }, .{}, w);
        try w.writeByte('\n');
    } else if (rep.place.len > 0) {
        try w.print("{s} {s}({s})\n", .{ rep.temp, rep.condition, rep.place });
    } else try w.print("{s} {s}\n", .{ rep.temp, rep.condition });
}
