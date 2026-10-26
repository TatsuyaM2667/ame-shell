// テキスト: fontconfig でフォント選択 → HarfBuzz で整形 → FreeType で SDF ラスタライズ
// → 1枚のグリフアトラス(GL_R8)に詰める。
//
// SDF にする理由: 1つのアトラスから任意サイズで滑らかに描け、拡大縮小アニメーションや
// 発光(グロー)をシェーダの閾値操作だけで作れるため。全サーフェスで共有する。
//
// 日本語: 主フォント(既定 Noto Sans CJK JP)→ アイコン用 Nerd Font → それでも無い文字は
// fontconfig にその文字を含むフォントを問い合わせ、動的にフォールバックチェーンへ追加する。
const std = @import("std");
const c = @import("c.zig");

pub const BASE_PX: f32 = 40; // SDF を生成する基準サイズ(大きいほど高品質だが生成が遅くアトラスを食う)
const SPREAD: c_int = 6; // SDF の広がり(px)。グローの最大幅にもなる
// アトラスは 2048²(GPU 側に確保され、CPU の常駐メモリはほぼ増えない)。
// 途中で拡張するとキャッシュ全消去 → 全グリフ再生成のスパイクになるため、最初から最大で確保する。
const ATLAS_MIN: c_int = 2048;
const ATLAS_MAX: c_int = 2048;

pub const Glyph = struct {
    // アトラス上の UV
    u0: f32,
    v0: f32,
    u1: f32,
    v1: f32,
    // 基準サイズでのビットマップ寸法とベアリング(ベースライン原点から)
    w: f32,
    h: f32,
    left: f32,
    top: f32,
};

pub var raster_ns: u64 = 0;
pub var raster_n: u64 = 0;

pub const Placed = struct {
    glyph: Glyph,
    cluster: u32, // 元の文字列のバイト位置(折り返し位置の計算に使う)
    x: f32, // 基準サイズでのペン位置
    y: f32,
};

const Face = struct {
    ft: c.FT_Face,
    hb: *c.hb_font_t,
    path_hash: u64,
};

pub const Fonts = struct {
    alloc: std.mem.Allocator,
    ft: c.FT_Library,
    faces: std.ArrayList(Face),
    /// 字体ごとのチェーン: [regular の顔番号..], [bold の顔番号..]
    chains: [2]std.ArrayList(u16),
    cache: std.AutoHashMap(u64, ?Glyph),
    /// 「この文字はどの顔で描くか」のキャッシュ(フォールバック探索を毎回しない)
    cp_face: std.AutoHashMap(u64, u16),
    atlas_tex: c.GLuint = 0,
    pen_x: c_int = 1,
    pen_y: c_int = 1,
    row_h: c_int = 0,
    atlas_size: c_int = ATLAS_MIN,
    /// アトラスを作り直した(このフレームの描画は古い UV を含む)→ 全サーフェスを描き直す合図
    needs_redraw: bool = false,
    hb_buf: *c.hb_buffer_t,
    scratch: std.ArrayList(Placed),

    pub fn init(alloc: std.mem.Allocator, ui_family: []const u8, icon_family: []const u8) !*Fonts {
        const self = try alloc.create(Fonts);
        var lib: c.FT_Library = null;
        if (c.FT_Init_FreeType(&lib) != 0) return error.FreeType;
        // SDF の広がりを設定("sdf" はアウトライン用、"bsdf" はビットマップ用ラスタライザ)
        var spread: c_int = SPREAD;
        _ = c.FT_Property_Set(lib, "sdf", "spread", &spread);
        _ = c.FT_Property_Set(lib, "bsdf", "spread", &spread);
        _ = c.FcInit();
        self.* = .{
            .alloc = alloc,
            .ft = lib,
            .faces = std.ArrayList(Face).init(alloc),
            .chains = .{ std.ArrayList(u16).init(alloc), std.ArrayList(u16).init(alloc) },
            .cache = std.AutoHashMap(u64, ?Glyph).init(alloc),
            .cp_face = std.AutoHashMap(u64, u16).init(alloc),
            .hb_buf = c.hb_buffer_create().?,
            .scratch = std.ArrayList(Placed).init(alloc),
        };
        for ([_]u1{ 0, 1 }) |bold| {
            var name_buf: [256]u8 = undefined;
            const weight = if (bold == 1) ":weight=bold" else "";
            const ui = std.fmt.bufPrintZ(&name_buf, "{s}{s}", .{ ui_family, weight }) catch "sans-serif";
            if (self.loadPattern(ui)) |i| try self.chains[bold].append(i);
            const ic = std.fmt.bufPrintZ(&name_buf, "{s}", .{icon_family}) catch "monospace";
            if (self.loadPattern(ic)) |i| try self.chains[bold].append(i);
            // 最後の砦: 日本語の sans-serif
            if (self.loadPattern("sans-serif:lang=ja")) |i| try self.chains[bold].append(i);
        }
        if (self.chains[0].items.len == 0) return error.NoFonts;
        return self;
    }

    /// fontconfig のパターン文字列から最適なフォントを探し、顔を読み込んで番号を返す。
    fn loadPattern(self: *Fonts, pattern: [:0]const u8) ?u16 {
        const pat = c.FcNameParse(pattern.ptr) orelse return null;
        defer c.FcPatternDestroy(pat);
        return self.loadMatch(pat);
    }

    fn loadMatch(self: *Fonts, pat: *c.FcPattern) ?u16 {
        _ = c.FcConfigSubstitute(null, pat, c.FcMatchPattern);
        c.FcDefaultSubstitute(pat);
        var res: c.FcResult = undefined;
        const m = c.FcFontMatch(null, pat, &res) orelse return null;
        defer c.FcPatternDestroy(m);
        var file: [*c]c.FcChar8 = null;
        var index: c_int = 0;
        if (c.FcPatternGetString(m, c.FC_FILE, 0, &file) != c.FcResultMatch) return null;
        _ = c.FcPatternGetInteger(m, c.FC_INDEX, 0, &index);
        const path = std.mem.sliceTo(file, 0);
        const h = std.hash.Wyhash.hash(@intCast(index), path);
        for (self.faces.items, 0..) |f, i| if (f.path_hash == h) return @intCast(i);
        var face: c.FT_Face = null;
        if (c.FT_New_Face(self.ft, file, index, &face) != 0) return null;
        _ = c.FT_Set_Pixel_Sizes(face, 0, @intFromFloat(BASE_PX));
        const hb = c.hb_ft_font_create_referenced(face) orelse return null;
        self.faces.append(.{ .ft = face, .hb = hb, .path_hash = h }) catch return null;
        return @intCast(self.faces.items.len - 1);
    }

    /// codepoint を描ける顔をチェーンから探す。無ければ fontconfig に聞いて追加。
    pub fn faceFor(self: *Fonts, chain: u1, cp: u32) u16 {
        const key = (@as(u64, chain) << 32) | cp;
        if (self.cp_face.get(key)) |f| return f;
        var found: ?u16 = null;
        for (self.chains[chain].items) |fi| {
            if (c.FT_Get_Char_Index(self.faces.items[fi].ft, cp) != 0) {
                found = fi;
                break;
            }
        }
        if (found == null and cp > 0x20) {
            // その文字を含むフォントを探す(絵文字や記号など)
            if (c.FcPatternCreate()) |pat| {
                defer c.FcPatternDestroy(pat);
                const cs = c.FcCharSetCreate();
                defer c.FcCharSetDestroy(cs);
                _ = c.FcCharSetAddChar(cs, cp);
                _ = c.FcPatternAddCharSet(pat, c.FC_CHARSET, cs);
                _ = c.FcPatternAddBool(pat, c.FC_SCALABLE, c.FcTrue);
                if (self.loadMatch(pat)) |fi| {
                    if (c.FT_Get_Char_Index(self.faces.items[fi].ft, cp) != 0) {
                        found = fi;
                        var present = false;
                        for (self.chains[chain].items) |x| present = present or x == fi;
                        if (!present) self.chains[chain].append(fi) catch {};
                    }
                }
            }
        }
        const f = found orelse self.chains[chain].items[0];
        self.cp_face.put(key, f) catch {};
        return f;
    }

    /// 文字列を整形し、基準サイズでの配置済みグリフ列(self.scratch)と全幅を返す。
    /// 戻り値のスライスは次の shape 呼び出しまで有効。
    pub fn shape(self: *Fonts, str: []const u8, bold: bool) struct { glyphs: []Placed, width: f32 } {
        self.scratch.clearRetainingCapacity();
        if (str.len == 0) return .{ .glyphs = self.scratch.items, .width = 0 };
        const chain: u1 = @intFromBool(bold and self.chains[1].items.len > 0);
        var pen: f32 = 0;
        // 同じ顔で描ける区間(ラン)ごとに HarfBuzz に渡す。
        var i: usize = 0;
        while (i < str.len) {
            const run_start = i;
            var run_face: ?u16 = null;
            while (i < str.len) {
                const n = std.unicode.utf8ByteSequenceLength(str[i]) catch 1;
                const end = @min(i + n, str.len);
                const cp = std.unicode.utf8Decode(str[i..end]) catch 0xfffd;
                const f = self.faceFor(chain, cp);
                if (run_face == null) run_face = f else if (run_face.? != f) break;
                i = end;
            }
            const face = self.faces.items[run_face.?];
            c.hb_buffer_clear_contents(self.hb_buf);
            c.hb_buffer_add_utf8(self.hb_buf, str.ptr, @intCast(str.len), @intCast(run_start), @intCast(i - run_start));
            c.hb_buffer_guess_segment_properties(self.hb_buf);
            c.hb_shape(face.hb, self.hb_buf, null, 0);
            var count: c_uint = 0;
            const infos = c.hb_buffer_get_glyph_infos(self.hb_buf, &count);
            const poss = c.hb_buffer_get_glyph_positions(self.hb_buf, &count);
            for (0..count) |gi| {
                const gid = infos[gi].codepoint;
                const p = poss[gi];
                if (self.glyph(run_face.?, gid)) |g| {
                    self.scratch.append(.{
                        .glyph = g,
                        .cluster = infos[gi].cluster,
                        .x = pen + @as(f32, @floatFromInt(p.x_offset)) / 64.0,
                        .y = -@as(f32, @floatFromInt(p.y_offset)) / 64.0,
                    }) catch {};
                }
                pen += @as(f32, @floatFromInt(p.x_advance)) / 64.0;
            }
        }
        return .{ .glyphs = self.scratch.items, .width = pen };
    }

    pub fn measure(self: *Fonts, str: []const u8, bold: bool, size: f32) f32 {
        return self.shape(str, bold).width * size / BASE_PX;
    }

    /// グリフを SDF でラスタライズしてアトラスに置く(キャッシュ済みならそれを返す)。
    pub fn glyph(self: *Fonts, face_idx: u16, gid: u32) ?Glyph {
        const key = (@as(u64, face_idx) << 32) | gid;
        if (self.cache.get(key)) |g| return g;
        const g = self.rasterize(face_idx, gid);
        self.cache.put(key, g) catch {};
        return g;
    }

    fn rasterize(self: *Fonts, face_idx: u16, gid: u32) ?Glyph {
        const t0 = std.time.nanoTimestamp();
        defer {
            raster_ns += @intCast(std.time.nanoTimestamp() - t0);
            raster_n += 1;
        }
        const face = self.faces.items[face_idx].ft;
        if (c.FT_Load_Glyph(face, gid, c.FT_LOAD_DEFAULT | c.FT_LOAD_NO_HINTING) != 0) return null;
        const slot = face.*.glyph;
        // アウトラインから直接 SDF を作る("sdf" ラスタライザ)と CJK で 1 字 6ms 以上かかるため、
        // まず通常のアンチエイリアス描画をしてから、そのビットマップを SDF に変換する("bsdf")。
        // 計測で約 1/10 の時間になり、品質差は UI の文字サイズでは見分けられない。
        if (c.FT_Render_Glyph(slot, c.FT_RENDER_MODE_NORMAL) != 0) return null;
        _ = c.FT_Render_Glyph(slot, c.FT_RENDER_MODE_SDF); // 失敗時(カラー絵文字等)は通常のビットマップのまま
        const bm = slot.*.bitmap;
        const w: c_int = @intCast(bm.width);
        const h: c_int = @intCast(bm.rows);
        if (w == 0 or h == 0) return null; // 空白
        const ATLAS = self.atlas_size;
        if (self.pen_x + w + 1 >= ATLAS) {
            self.pen_x = 1;
            self.pen_y += self.row_h + 1;
            self.row_h = 0;
        }
        if (self.pen_y + h + 1 >= ATLAS) {
            // 満杯: 広げられるなら広げ、最大なら全消去。どちらもキャッシュを捨てて描き直してもらう。
            if (self.atlas_size < ATLAS_MAX) {
                self.atlas_size = ATLAS_MAX;
                std.log.info("glyph atlas を {d}px に拡張", .{ATLAS_MAX});
            } else std.log.warn("glyph atlas full, resetting", .{});
            self.cache.clearRetainingCapacity();
            self.allocAtlas();
            self.pen_x = 1;
            self.pen_y = 1;
            self.row_h = 0;
            self.needs_redraw = true;
        }
        c.glBindTexture(c.GL_TEXTURE_2D, self.atlas_tex);
        c.glPixelStorei(c.GL_UNPACK_ALIGNMENT, 1);
        c.glPixelStorei(c.GL_UNPACK_ROW_LENGTH, @divTrunc(bm.pitch, 1));
        c.glTexSubImage2D(c.GL_TEXTURE_2D, 0, self.pen_x, self.pen_y, w, h, c.GL_RED, c.GL_UNSIGNED_BYTE, bm.buffer);
        c.glPixelStorei(c.GL_UNPACK_ROW_LENGTH, 0);
        const fa: f32 = @floatFromInt(self.atlas_size);
        const g = Glyph{
            .u0 = @as(f32, @floatFromInt(self.pen_x)) / fa,
            .v0 = @as(f32, @floatFromInt(self.pen_y)) / fa,
            .u1 = @as(f32, @floatFromInt(self.pen_x + w)) / fa,
            .v1 = @as(f32, @floatFromInt(self.pen_y + h)) / fa,
            .w = @floatFromInt(w),
            .h = @floatFromInt(h),
            .left = @floatFromInt(slot.*.bitmap_left),
            .top = @floatFromInt(slot.*.bitmap_top),
        };
        self.pen_x += w + 1;
        self.row_h = @max(self.row_h, h);
        return g;
    }

    /// GL コンテキスト作成後に呼ぶ。
    pub fn initGl(self: *Fonts) void {
        c.glGenTextures(1, &self.atlas_tex);
        self.allocAtlas();
    }

    /// 現在の atlas_size でテクスチャを確保し、GPU 上で 0 クリアする
    /// (CPU で 0 埋めバッファを作って転送すると、その分ドライバ側にもコピーが残るため)
    fn allocAtlas(self: *Fonts) void {
        const n = self.atlas_size;
        c.glBindTexture(c.GL_TEXTURE_2D, self.atlas_tex);
        c.glTexImage2D(c.GL_TEXTURE_2D, 0, c.GL_R8, n, n, 0, c.GL_RED, c.GL_UNSIGNED_BYTE, null);
        c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MIN_FILTER, c.GL_LINEAR);
        c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MAG_FILTER, c.GL_LINEAR);
        c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_WRAP_S, c.GL_CLAMP_TO_EDGE);
        c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_WRAP_T, c.GL_CLAMP_TO_EDGE);
        var prev_fbo: c.GLint = 0;
        c.glGetIntegerv(c.GL_FRAMEBUFFER_BINDING, &prev_fbo);
        var fbo: c.GLuint = 0;
        c.glGenFramebuffers(1, &fbo);
        c.glBindFramebuffer(c.GL_FRAMEBUFFER, fbo);
        c.glFramebufferTexture2D(c.GL_FRAMEBUFFER, c.GL_COLOR_ATTACHMENT0, c.GL_TEXTURE_2D, self.atlas_tex, 0);
        c.glViewport(0, 0, n, n);
        c.glClearColor(0, 0, 0, 0);
        c.glClear(c.GL_COLOR_BUFFER_BIT);
        c.glBindFramebuffer(c.GL_FRAMEBUFFER, @intCast(prev_fbo));
        c.glDeleteFramebuffers(1, &fbo);
    }
};

/// アイドル時の先読み: よく使う文字のグリフを少しずつ前もって SDF 化しておく。
/// (初めてランチャーを開いた瞬間に 100 字以上の生成が重なって 1 フレームが長引くのを防ぐ)
pub const Warmer = struct {
    queue: std.ArrayList(u8),
    pos: usize = 0,

    pub fn init(alloc: std.mem.Allocator) Warmer {
        return .{ .queue = std.ArrayList(u8).init(alloc) };
    }

    pub fn add(self: *Warmer, s: []const u8) void {
        self.queue.appendSlice(s) catch {};
        self.queue.append(' ') catch {};
    }

    pub fn pending(self: *const Warmer) bool {
        return self.pos < self.queue.items.len;
    }

    /// 最大 budget_us マイクロ秒だけ作業する。両方の太さ(regular/bold)を温める。
    pub fn step(self: *Warmer, fonts: *Fonts, budget_us: i128) void {
        const t0 = std.time.nanoTimestamp();
        const q = self.queue.items;
        while (self.pos < q.len) {
            const n = std.unicode.utf8ByteSequenceLength(q[self.pos]) catch 1;
            const end = @min(self.pos + n, q.len);
            const cp = std.unicode.utf8Decode(q[self.pos..end]) catch 0x20;
            self.pos = end;
            if (cp <= 0x20) continue;
            for ([_]u1{ 0, 1 }) |chain| {
                if (fonts.chains[chain].items.len == 0) continue;
                const fi = fonts.faceFor(chain, cp);
                const gid = c.FT_Get_Char_Index(fonts.faces.items[fi].ft, cp);
                if (gid != 0) _ = fonts.glyph(fi, gid);
            }
            if (std.time.nanoTimestamp() - t0 > budget_us * 1000) break;
        }
        if (self.pos >= q.len) {
            self.queue.clearAndFree();
            self.pos = 0;
        }
    }
};

/// 先読みの既定セット: ASCII・かな・UI で使う漢字
pub const common_chars =
    " !\"#$%&'()*+,-./0123456789:;<=>?@ABCDEFGHIJKLMNOPQRSTUVWXYZ[\\]^_`abcdefghijklmnopqrstuvwxyz{|}~…" ++
    "ぁあぃいぅうぇえぉおかがきぎくぐけげこごさざしじすずせぜそぞただちぢっつづてでとどなにぬねのはばぱひびぴふぶぷへべぺほぼぽまみむめもゃやゅゆょよらりるれろゎわをんー" ++
    "ァアィイゥウェエォオカガキギクグケゲコゴサザシジスズセゼソゾタダチヂッツヅテデトドナニヌネノハバパヒビピフブプヘベペホボポマミムメモャヤュユョヨラリルレロワヲンヴ" ++
    "年月日時分秒曜火水木金土雨通知消去再生中停止音量明温度検索実行設定画面表示新今前次全見無効有充電" ++
    "（）「」、。・！？％：°‹›" ++
    // UI で使う Nerd Font アイコン
    "\u{F0079}\u{F007A}\u{F007B}\u{F007C}\u{F007D}\u{F007E}\u{F007F}\u{F0080}\u{F0081}\u{F0082}\u{F0084}\u{F008E}\u{F009B}\u{F00AF}" ++
    "\u{F00E0}\u{F018D}\u{F0200}\u{F0349}\u{F03E4}\u{F040A}\u{F04AD}\u{F04AE}\u{F057E}\u{F057F}\u{F0580}\u{F0581}\u{F05A9}\u{F075A}" ++
    "\u{F075F}\u{F0928}\u{F092D}";
