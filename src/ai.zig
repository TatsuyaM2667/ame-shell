// AI チャット: いろいろな会社の API と会話する(画面は frame/aipanel.zig の右から生えるパネル)。
//
// 会話の形式は 2 種類だけ:
//   openai    … OpenAI 互換の /chat/completions(OpenAI・Gemini・Mistral・DeepSeek・OpenRouter・Kimi・OpenCode Zen・
//                xAI・Groq・Qwen・GLM・Perplexity・Together・Cerebras・Ollama・その他の互換サーバ)
//   anthropic … Anthropic の /messages
// どちらも stream: true で受け取り(Server-Sent Events)、届いた分から表示する。
//
// 通信は curl を非同期に動かし、出力を pipe で読む(歌詞と同じ)。API キーはコマンドライン(誰でも読める
// /proc/<pid>/cmdline)に出さず、curl の設定(-K -)として標準入力から渡す。送る本文は $XDG_RUNTIME_DIR の
// 自分だけ読めるファイルに書き、終わったら消す。
//
// API キー: ~/.config/ame-shell/ai-keys(「<会社の id> <キー>」の行、0600。パネルから貼り付けて保存できる)、
//           無ければ環境変数(OPENAI_API_KEY など)。
// 選んだ会社・モデル: $XDG_STATE_HOME/ame-shell/ai。会話: $XDG_STATE_HOME/ame-shell/ai-chat(再起動しても残る)。
const std = @import("std");
const c = @import("c.zig");
const App = @import("app.zig").App;
const sys = @import("platform/sys.zig");

pub const Proto = enum { openai, anthropic };

pub const Provider = struct {
    id: []const u8,
    name: []const u8,
    base: []const u8,
    proto: Proto = .openai,
    env: []const []const u8 = &.{},
    /// 最初に使うモデル(パネルの「モデル」で一覧から選び直せる)
    model: []const u8,
    /// API キーが要るか(Ollama などこの PC のサーバは要らない)
    need_key: bool = true,
    /// キーを作る場所(パネルに出す)
    hint: []const u8 = "",
};

pub const CUSTOM = "custom";

pub const providers = [_]Provider{
    .{ .id = "openai", .name = "OpenAI", .base = "https://api.openai.com/v1", .env = &.{"OPENAI_API_KEY"}, .model = "gpt-5-mini", .hint = "platform.openai.com/api-keys" },
    .{ .id = "anthropic", .name = "Anthropic (Claude)", .base = "https://api.anthropic.com/v1", .proto = .anthropic, .env = &.{"ANTHROPIC_API_KEY"}, .model = "claude-sonnet-5-5", .hint = "console.anthropic.com/settings/keys" },
    .{ .id = "gemini", .name = "Google Gemini", .base = "https://generativelanguage.googleapis.com/v1beta/openai", .env = &.{ "GEMINI_API_KEY", "GOOGLE_API_KEY" }, .model = "gemini-2.5-flash", .hint = "aistudio.google.com/apikey" },
    .{ .id = "mistral", .name = "Mistral", .base = "https://api.mistral.ai/v1", .env = &.{"MISTRAL_API_KEY"}, .model = "mistral-medium-latest", .hint = "console.mistral.ai/api-keys" },
    .{ .id = "deepseek", .name = "DeepSeek", .base = "https://api.deepseek.com/v1", .env = &.{"DEEPSEEK_API_KEY"}, .model = "deepseek-chat", .hint = "platform.deepseek.com/api_keys" },
    .{ .id = "opencode", .name = "OpenCode Zen", .base = "https://opencode.ai/zen/v1", .env = &.{"OPENCODE_API_KEY"}, .model = "kimi-k2", .hint = "opencode.ai/auth" },
    .{ .id = "openrouter", .name = "OpenRouter", .base = "https://openrouter.ai/api/v1", .env = &.{"OPENROUTER_API_KEY"}, .model = "openrouter/auto", .hint = "openrouter.ai/keys" },
    .{ .id = "kimi", .name = "Kimi (Moonshot)", .base = "https://api.moonshot.ai/v1", .env = &.{ "MOONSHOT_API_KEY", "KIMI_API_KEY" }, .model = "kimi-k2-turbo-preview", .hint = "platform.moonshot.ai/console/api-keys" },
    .{ .id = "xai", .name = "xAI (Grok)", .base = "https://api.x.ai/v1", .env = &.{"XAI_API_KEY"}, .model = "grok-4", .hint = "console.x.ai" },
    .{ .id = "groq", .name = "Groq", .base = "https://api.groq.com/openai/v1", .env = &.{"GROQ_API_KEY"}, .model = "llama-3.3-70b-versatile", .hint = "console.groq.com/keys" },
    .{ .id = "qwen", .name = "Qwen (Alibaba Cloud)", .base = "https://dashscope-intl.aliyuncs.com/compatible-mode/v1", .env = &.{"DASHSCOPE_API_KEY"}, .model = "qwen-plus", .hint = "bailian.console.alibabacloud.com" },
    .{ .id = "zai", .name = "Z.ai (GLM)", .base = "https://api.z.ai/api/paas/v4", .env = &.{ "ZAI_API_KEY", "ZHIPU_API_KEY" }, .model = "glm-4.6", .hint = "z.ai/manage-apikey" },
    .{ .id = "perplexity", .name = "Perplexity", .base = "https://api.perplexity.ai", .env = &.{"PERPLEXITY_API_KEY"}, .model = "sonar", .hint = "perplexity.ai/account/api" },
    .{ .id = "together", .name = "Together AI", .base = "https://api.together.xyz/v1", .env = &.{"TOGETHER_API_KEY"}, .model = "meta-llama/Llama-3.3-70B-Instruct-Turbo", .hint = "api.together.ai/settings/api-keys" },
    .{ .id = "cerebras", .name = "Cerebras", .base = "https://api.cerebras.ai/v1", .env = &.{"CEREBRAS_API_KEY"}, .model = "llama-3.3-70b", .hint = "cloud.cerebras.ai" },
    .{ .id = "ollama", .name = "Ollama(この PC)", .base = "http://127.0.0.1:11434/v1", .model = "llama3.2", .need_key = false },
    // 設定の ai { custom-url "…" } の OpenAI 互換サーバ(LM Studio・vLLM・社内のゲートウェイなど)。キーは任意
    .{ .id = CUSTOM, .name = "カスタム(OpenAI 互換)", .base = "", .model = "", .need_key = false },
};

pub const Role = enum { user, assistant };

pub const Line = struct {
    a: u32,
    b: u32,
    kind: Kind = .plain,
    pub const Kind = enum { plain, code, head, bullet, bullet_cont, quote };
};

pub const Msg = struct {
    role: Role,
    text: std.ArrayList(u8),
    /// 考えている途中の文章(DeepSeek R1・OpenRouter の reasoning、Claude の thinking)
    think: std.ArrayList(u8),
    err: bool = false,
    /// 表示のレイアウト(aipanel が作る。文字が増えたら最後の段落から作り直す)
    lines: std.ArrayList(Line),
    lay_w: f32 = 0,
    lay_len: usize = 0,
    lay_para: usize = 0,
    lay_code: bool = false,
    lay_max: f32 = 0,
    lay_lines_before: usize = 0,
    lay_max_before: f32 = 0,

    fn create(alloc: std.mem.Allocator, role: Role) !*Msg {
        const m = try alloc.create(Msg);
        m.* = .{ .role = role, .text = std.ArrayList(u8).init(alloc), .think = std.ArrayList(u8).init(alloc), .lines = std.ArrayList(Line).init(alloc) };
        return m;
    }
    fn destroy(self: *Msg, alloc: std.mem.Allocator) void {
        self.text.deinit();
        self.think.deinit();
        self.lines.deinit();
        alloc.destroy(self);
    }
};

const MAX_MODELS = 600;

const State = struct {
    app: ?*App = null,
    alloc: std.mem.Allocator = std.heap.c_allocator,
    loaded: bool = false,
    msgs: std.ArrayList(*Msg) = undefined,
    prov: usize = 6, // OpenRouter
    models: [providers.len][128]u8 = undefined,
    model_len: [providers.len]usize = [_]usize{0} ** providers.len,

    // ---- 会話の送受信 ----
    fd: c_int = -1,
    pid: c_int = 0,
    line: std.ArrayList(u8) = undefined,
    raw: std.ArrayList(u8) = undefined,
    http: u32 = 0,
    body_path: [256]u8 = undefined,
    body_len: usize = 0,
    got: bool = false,
    stream_err: bool = false,

    // ---- モデルの一覧 ----
    mfd: c_int = -1,
    mpid: c_int = 0,
    mbuf: std.ArrayList(u8) = undefined,
    model_arena: std.heap.ArenaAllocator = undefined,
    model_list: std.ArrayList([]const u8) = undefined,
    model_prov: usize = std.math.maxInt(usize),
    model_err: [160]u8 = undefined,
    model_err_len: usize = 0,
};

var st: State = .{};

pub fn ensure(app: *App) void {
    st.app = app;
    if (st.loaded) return;
    st.loaded = true;
    st.alloc = app.alloc;
    st.msgs = std.ArrayList(*Msg).init(st.alloc);
    st.line = std.ArrayList(u8).init(st.alloc);
    st.raw = std.ArrayList(u8).init(st.alloc);
    st.mbuf = std.ArrayList(u8).init(st.alloc);
    st.model_arena = std.heap.ArenaAllocator.init(st.alloc);
    st.model_list = std.ArrayList([]const u8).init(st.alloc);
    loadState();
    if (app.cfg.ai_provider.len > 0) if (providerIndex(app.cfg.ai_provider.get())) |i| {
        // 設定ファイルの指定は「初めて使うとき」の既定。パネルで選び直したものが優先
        if (!stateFileExists()) st.prov = i;
    };
    loadChat();
}

pub fn messages() []*Msg {
    return st.msgs.items;
}

pub fn providerIndex(id: []const u8) ?usize {
    for (providers, 0..) |p, i| if (std.mem.eql(u8, p.id, id)) return i;
    return null;
}

pub fn current() usize {
    return st.prov;
}

pub fn baseUrl(i: usize) []const u8 {
    if (std.mem.eql(u8, providers[i].id, CUSTOM)) if (st.app) |a| return a.cfg.ai_custom_url.get();
    return providers[i].base;
}

pub fn model(i: usize) []const u8 {
    if (st.model_len[i] > 0) return st.models[i][0..st.model_len[i]];
    if (std.mem.eql(u8, providers[i].id, CUSTOM)) if (st.app) |a| return a.cfg.ai_custom_model.get();
    return providers[i].model;
}

pub fn setProvider(i: usize) void {
    if (i >= providers.len or i == st.prov) return;
    st.prov = i;
    saveState();
}

pub fn setModel(i: usize, name: []const u8) void {
    const n = @min(name.len, st.models[i].len);
    @memcpy(st.models[i][0..n], name[0..n]);
    st.model_len[i] = n;
    saveState();
}

pub fn busy() bool {
    return st.fd >= 0;
}

pub fn modelsBusy() bool {
    return st.mfd >= 0;
}

/// 取ってきたモデルの一覧(その会社の分だけ)
pub fn modelList(i: usize) []const []const u8 {
    return if (st.model_prov == i) st.model_list.items else &.{};
}

pub fn modelError() []const u8 {
    return st.model_err[0..st.model_err_len];
}

fn redraw() void {
    if (st.app) |a| for (a.outputs.items) |o| if (o.frame) |f| f.schedule();
}

// ---------------------------------------------------------------------------
// API キー
// ---------------------------------------------------------------------------

fn configDir(buf: []u8) ?[]const u8 {
    if (std.posix.getenv("XDG_CONFIG_HOME")) |x| if (x.len > 0) return std.fmt.bufPrint(buf, "{s}/ame-shell", .{x}) catch null;
    const h = std.posix.getenv("HOME") orelse return null;
    return std.fmt.bufPrint(buf, "{s}/.config/ame-shell", .{h}) catch null;
}

fn stateDir(buf: []u8) ?[]const u8 {
    if (std.posix.getenv("XDG_STATE_HOME")) |x| if (x.len > 0) return std.fmt.bufPrint(buf, "{s}/ame-shell", .{x}) catch null;
    const h = std.posix.getenv("HOME") orelse return null;
    return std.fmt.bufPrint(buf, "{s}/.local/state/ame-shell", .{h}) catch null;
}

fn keysPath(buf: []u8) ?[]const u8 {
    var d: [400]u8 = undefined;
    const dir = configDir(&d) orelse return null;
    return std.fmt.bufPrint(buf, "{s}/ai-keys", .{dir}) catch null;
}

/// その会社の API キー(ai-keys ファイル → 環境変数)。out に写して返す
pub fn key(i: usize, out: []u8) ?[]const u8 {
    var pb: [512]u8 = undefined;
    if (keysPath(&pb)) |path| {
        var fb: [8192]u8 = undefined;
        if (readSmall(path, &fb)) |txt| {
            var it = std.mem.splitScalar(u8, txt, '\n');
            while (it.next()) |raw_line| {
                const l = std.mem.trim(u8, raw_line, " \t\r");
                if (l.len == 0 or l[0] == '#') continue;
                const sp = std.mem.indexOfAny(u8, l, " \t") orelse continue;
                if (!std.mem.eql(u8, l[0..sp], providers[i].id)) continue;
                const k = std.mem.trim(u8, l[sp + 1 ..], " \t");
                if (k.len == 0 or k.len > out.len) continue;
                @memcpy(out[0..k.len], k);
                return out[0..k.len];
            }
        }
    }
    for (providers[i].env) |e| if (std.posix.getenv(e)) |v| if (v.len > 0 and v.len <= out.len) {
        @memcpy(out[0..v.len], v);
        return out[0..v.len];
    };
    return null;
}

pub fn hasKey(i: usize) bool {
    var b: [512]u8 = undefined;
    return key(i, &b) != null;
}

/// 使えるキーの形か(curl の設定に安全に書ける文字だけ)
pub fn validKey(k: []const u8) bool {
    if (k.len < 8 or k.len > 400) return false;
    for (k) |ch| if (ch <= 0x20 or ch >= 0x7f or ch == '"' or ch == '\\') return false;
    return true;
}

/// キーを保存する(ai-keys の同じ会社の行を置き換える。ファイルは 0600)。空なら消す
pub fn saveKey(i: usize, k: []const u8) bool {
    if (k.len > 0 and !validKey(k)) return false;
    var pb: [512]u8 = undefined;
    const path = keysPath(&pb) orelse return false;
    var db: [400]u8 = undefined;
    std.fs.cwd().makePath(configDir(&db) orelse return false) catch {};
    var fb: [8192]u8 = undefined;
    const old = readSmall(path, &fb) orelse "";
    var out = std.ArrayList(u8).init(st.alloc);
    defer out.deinit();
    if (old.len == 0) out.appendSlice("# ame-shell の AI チャットの API キー(<会社> <キー>)。このファイルは自分だけが読めます\n") catch return false;
    var it = std.mem.splitScalar(u8, old, '\n');
    while (it.next()) |l| {
        if (l.len == 0) continue;
        const t = std.mem.trim(u8, l, " \t\r");
        const sp = std.mem.indexOfAny(u8, t, " \t");
        if (sp != null and std.mem.eql(u8, t[0..sp.?], providers[i].id)) continue;
        out.appendSlice(l) catch return false;
        out.append('\n') catch return false;
    }
    if (k.len > 0) {
        out.writer().print("{s} {s}\n", .{ providers[i].id, k }) catch return false;
    }
    var tb: [520]u8 = undefined;
    const tmp = std.fmt.bufPrint(&tb, "{s}.new", .{path}) catch return false;
    {
        const f = std.fs.cwd().createFile(tmp, .{ .mode = 0o600, .truncate = true }) catch return false;
        defer f.close();
        f.writeAll(out.items) catch return false;
    }
    std.fs.cwd().rename(tmp, path) catch return false;
    // 前からあったファイルでも、自分だけ読めるように
    if (std.fs.cwd().openFile(path, .{})) |f| {
        f.chmod(0o600) catch {};
        f.close();
    } else |_| {}
    return true;
}

fn readSmall(path: []const u8, buf: []u8) ?[]const u8 {
    const f = std.fs.cwd().openFile(path, .{}) catch return null;
    defer f.close();
    const n = f.readAll(buf) catch return null;
    return buf[0..n];
}

// ---------------------------------------------------------------------------
// 選んだ会社・モデル / 会話の保存
// ---------------------------------------------------------------------------

fn statePath(buf: []u8, name: []const u8) ?[]const u8 {
    var d: [400]u8 = undefined;
    const dir = stateDir(&d) orelse return null;
    return std.fmt.bufPrint(buf, "{s}/{s}", .{ dir, name }) catch null;
}

fn stateFileExists() bool {
    var pb: [512]u8 = undefined;
    const p = statePath(&pb, "ai") orelse return false;
    std.fs.cwd().access(p, .{}) catch return false;
    return true;
}

fn loadState() void {
    var pb: [512]u8 = undefined;
    const p = statePath(&pb, "ai") orelse return;
    var fb: [16384]u8 = undefined;
    const txt = readSmall(p, &fb) orelse return;
    var it = std.mem.splitScalar(u8, txt, '\n');
    while (it.next()) |l| {
        var f = std.mem.tokenizeScalar(u8, l, ' ');
        const k = f.next() orelse continue;
        if (std.mem.eql(u8, k, "provider")) {
            if (providerIndex(f.next() orelse continue)) |i| st.prov = i;
        } else if (std.mem.eql(u8, k, "model")) {
            const i = providerIndex(f.next() orelse continue) orelse continue;
            const m = f.rest();
            if (m.len == 0) continue;
            const n = @min(m.len, st.models[i].len);
            @memcpy(st.models[i][0..n], m[0..n]);
            st.model_len[i] = n;
        }
    }
}

fn saveState() void {
    var out = std.ArrayList(u8).init(st.alloc);
    defer out.deinit();
    const w = out.writer();
    w.print("provider {s}\n", .{providers[st.prov].id}) catch return;
    for (providers, 0..) |p, i| if (st.model_len[i] > 0) w.print("model {s} {s}\n", .{ p.id, st.models[i][0..st.model_len[i]] }) catch return;
    writeState("ai", out.items);
}

fn writeState(name: []const u8, bytes: []const u8) void {
    var d: [400]u8 = undefined;
    const dir = stateDir(&d) orelse return;
    std.fs.cwd().makePath(dir) catch {};
    var pb: [512]u8 = undefined;
    const p = statePath(&pb, name) orelse return;
    var tb: [520]u8 = undefined;
    const tmp = std.fmt.bufPrint(&tb, "{s}.new", .{p}) catch return;
    const f = std.fs.cwd().createFile(tmp, .{ .mode = 0o600, .truncate = true }) catch return;
    f.writeAll(bytes) catch {
        f.close();
        return;
    };
    f.close();
    std.fs.cwd().rename(tmp, p) catch {};
}

/// 会話の保存形式: 「U <バイト数>\n<本文>\n」/「A …」(本文に何が入っていても読み戻せる)
fn saveChat() void {
    var out = std.ArrayList(u8).init(st.alloc);
    defer out.deinit();
    for (st.msgs.items) |m| {
        if (m.err or m.text.items.len == 0) continue;
        out.writer().print("{c} {d}\n", .{ @as(u8, if (m.role == .user) 'U' else 'A'), m.text.items.len }) catch return;
        out.appendSlice(m.text.items) catch return;
        out.append('\n') catch return;
    }
    writeState("ai-chat", out.items);
}

fn loadChat() void {
    var pb: [512]u8 = undefined;
    const p = statePath(&pb, "ai-chat") orelse return;
    const f = std.fs.cwd().openFile(p, .{}) catch return;
    defer f.close();
    const txt = f.readToEndAlloc(st.alloc, 8 << 20) catch return;
    defer st.alloc.free(txt);
    parseChat(st.alloc, &st.msgs, txt) catch {};
}

fn parseChat(alloc: std.mem.Allocator, list: *std.ArrayList(*Msg), txt: []const u8) !void {
    var i: usize = 0;
    while (i < txt.len) {
        const nl = std.mem.indexOfScalarPos(u8, txt, i, '\n') orelse return;
        const head = txt[i..nl];
        if (head.len < 3 or head[1] != ' ') return;
        const role: Role = if (head[0] == 'U') .user else if (head[0] == 'A') .assistant else return;
        const n = std.fmt.parseInt(usize, head[2..], 10) catch return;
        if (nl + 1 + n > txt.len) return;
        const m = try Msg.create(alloc, role);
        try m.text.appendSlice(txt[nl + 1 .. nl + 1 + n]);
        try list.append(m);
        i = nl + 1 + n + 1;
    }
}

pub fn clear() void {
    stop();
    for (st.msgs.items) |m| m.destroy(st.alloc);
    st.msgs.clearRetainingCapacity();
    saveChat();
    redraw();
}

// ---------------------------------------------------------------------------
// 送る
// ---------------------------------------------------------------------------

/// 送る本文(JSON)を作る
fn buildBody(out: *std.ArrayList(u8), proto: Proto, mdl: []const u8, system: []const u8, msgs: []const *Msg) !void {
    var ws = std.json.writeStream(out.writer(), .{});
    try ws.beginObject();
    try ws.objectField("model");
    try ws.write(mdl);
    try ws.objectField("stream");
    try ws.write(true);
    if (proto == .anthropic) {
        try ws.objectField("max_tokens");
        try ws.write(8192);
        if (system.len > 0) {
            try ws.objectField("system");
            try ws.write(system);
        }
    }
    try ws.objectField("messages");
    try ws.beginArray();
    if (proto == .openai and system.len > 0) {
        try ws.beginObject();
        try ws.objectField("role");
        try ws.write("system");
        try ws.objectField("content");
        try ws.write(system);
        try ws.endObject();
    }
    for (msgs) |m| {
        // 失敗した返事・空の返事(今から書く分)は送らない
        if (m.err or m.text.items.len == 0) continue;
        try ws.beginObject();
        try ws.objectField("role");
        try ws.write(if (m.role == .user) "user" else "assistant");
        try ws.objectField("content");
        try ws.write(m.text.items);
        try ws.endObject();
    }
    try ws.endArray();
    try ws.endObject();
}

/// curl の設定ファイルの 1 行(値は "" で囲み、\ と " を逃がす)
fn cfgLine(w: anytype, name: []const u8, val: []const u8) !void {
    try w.print("{s} = \"", .{name});
    for (val) |ch| {
        switch (ch) {
            '"', '\\' => try w.print("\\{c}", .{ch}),
            '\n', '\r' => {},
            else => try w.writeByte(ch),
        }
    }
    try w.writeAll("\"\n");
}

/// curl の設定(URL・ヘッダ・本文のファイル)を作る
fn buildCurlConfig(out: *std.ArrayList(u8), i: usize, url: []const u8, k: ?[]const u8, body_file: ?[]const u8) !void {
    const w = out.writer();
    try cfgLine(w, "url", url);
    var hb: [600]u8 = undefined;
    if (k) |kk| {
        if (providers[i].proto == .anthropic) {
            try cfgLine(w, "header", try std.fmt.bufPrint(&hb, "x-api-key: {s}", .{kk}));
        } else try cfgLine(w, "header", try std.fmt.bufPrint(&hb, "Authorization: Bearer {s}", .{kk}));
    }
    if (providers[i].proto == .anthropic) try cfgLine(w, "header", "anthropic-version: 2023-06-01");
    if (std.mem.eql(u8, providers[i].id, "openrouter")) {
        try cfgLine(w, "header", "HTTP-Referer: https://github.com/TatsuyaM2667/ame-shell");
        try cfgLine(w, "header", "X-Title: ame-shell");
    }
    if (body_file) |bf| {
        try cfgLine(w, "header", "Content-Type: application/json");
        var db: [300]u8 = undefined;
        try cfgLine(w, "data-binary", try std.fmt.bufPrint(&db, "@{s}", .{bf}));
    }
}

const HTTP_MARK = "__AME_HTTP__";

/// 送る。失敗の理由は返事の欄に出す
pub fn send(text: []const u8) void {
    const t = std.mem.trim(u8, text, " \t\r\n");
    if (t.len == 0 or busy()) return;
    const app = st.app orelse return;
    const um = Msg.create(st.alloc, .user) catch return;
    um.text.appendSlice(t) catch {};
    st.msgs.append(um) catch return;
    const am = Msg.create(st.alloc, .assistant) catch return;
    st.msgs.append(am) catch return;
    saveChat();
    redraw();

    const i = st.prov;
    const p = &providers[i];
    const base = baseUrl(i);
    if (base.len == 0) return fail(am, "カスタムの接続先が未設定です(設定の ai { custom-url \"http://…/v1\" })");
    const mdl = model(i);
    if (mdl.len == 0) return fail(am, "モデルが未設定です(上の名前を押してモデルを選んでください)");
    var kb: [512]u8 = undefined;
    const k = key(i, &kb);
    if (p.need_key and k == null) return fail(am, "API キーが未設定です。上の会社の名前を押して、キーを貼り付けてください");

    var body = std.ArrayList(u8).init(st.alloc);
    defer body.deinit();
    buildBody(&body, p.proto, mdl, app.cfg.ai_system.get(), st.msgs.items) catch return fail(am, "本文を作れませんでした");
    const rd = std.posix.getenv("XDG_RUNTIME_DIR") orelse "/tmp";
    const bp = std.fmt.bufPrint(&st.body_path, "{s}/ame-ai-{d}.json", .{ rd, c.getpid() }) catch return fail(am, "一時ファイルを作れませんでした");
    st.body_len = bp.len;
    {
        const f = std.fs.cwd().createFile(bp, .{ .mode = 0o600, .truncate = true }) catch return fail(am, "一時ファイルを作れませんでした");
        defer f.close();
        f.writeAll(body.items) catch return fail(am, "一時ファイルに書けませんでした");
    }
    var ub: [600]u8 = undefined;
    const url = std.fmt.bufPrint(&ub, "{s}{s}", .{ base, if (p.proto == .anthropic) "/messages" else "/chat/completions" }) catch return fail(am, "URL が長すぎます");
    var cfg = std.ArrayList(u8).init(st.alloc);
    defer cfg.deinit();
    buildCurlConfig(&cfg, i, url, k, bp) catch return fail(am, "設定を作れませんでした");
    @memset(&kb, 0);

    st.line.clearRetainingCapacity();
    st.raw.clearRetainingCapacity();
    st.http = 0;
    st.got = false;
    st.stream_err = false;
    const argv = [_]?[*:0]const u8{ "curl", "-sS", "-N", "--connect-timeout", "15", "--max-time", "900", "-w", "\n" ++ HTTP_MARK ++ "%{http_code}\n", "-K", "-" };
    st.fd = sys.spawnPiped(&argv, cfg.items, &st.pid) orelse {
        removeBody();
        return fail(am, "curl を起動できませんでした(curl を入れてください)");
    };
    @memset(cfg.items, 0);
    app.loop.add(st.fd, c.EPOLLIN | c.EPOLLHUP, &st, onRead) catch {};
}

fn fail(m: *Msg, why: []const u8) void {
    m.text.clearRetainingCapacity();
    m.text.appendSlice(why) catch {};
    m.err = true;
    redraw();
}

fn removeBody() void {
    if (st.body_len == 0) return;
    std.fs.cwd().deleteFile(st.body_path[0..st.body_len]) catch {};
    st.body_len = 0;
}

/// 返事を止める(届いた分は残す)
pub fn stop() void {
    if (st.fd < 0) return;
    _ = c.kill(st.pid, c.SIGTERM);
    finishStream(true);
}

fn onRead(_: *anyopaque, fd: c_int, _: u32) void {
    var tmp: [16384]u8 = undefined;
    while (true) {
        const n = c.read(fd, &tmp, tmp.len);
        if (n > 0) {
            feed(tmp[0..@intCast(n)]);
            continue;
        }
        if (n < 0 and std.posix.errno(n) == .AGAIN) {
            redraw();
            return;
        }
        break; // EOF
    }
    if (st.line.items.len > 0) {
        const l = st.alloc.dupe(u8, st.line.items) catch "";
        defer if (l.len > 0) st.alloc.free(l);
        st.line.clearRetainingCapacity();
        handleLine(l);
    }
    finishStream(false);
}

fn feed(bytes: []const u8) void {
    var rest = bytes;
    while (std.mem.indexOfScalar(u8, rest, '\n')) |nl| {
        if (st.line.items.len > 0) {
            st.line.appendSlice(rest[0..nl]) catch {};
            const l = st.alloc.dupe(u8, st.line.items) catch return;
            defer st.alloc.free(l);
            st.line.clearRetainingCapacity();
            handleLine(l);
        } else handleLine(rest[0..nl]);
        rest = rest[nl + 1 ..];
    }
    st.line.appendSlice(rest) catch {};
}

fn lastAssistant() ?*Msg {
    if (st.msgs.items.len == 0) return null;
    const m = st.msgs.items[st.msgs.items.len - 1];
    return if (m.role == .assistant) m else null;
}

fn handleLine(raw_line: []const u8) void {
    const l = std.mem.trimRight(u8, raw_line, "\r");
    if (std.mem.startsWith(u8, l, HTTP_MARK)) {
        st.http = std.fmt.parseInt(u32, l[HTTP_MARK.len..], 10) catch 0;
        return;
    }
    if (std.mem.startsWith(u8, l, "data:")) {
        const payload = std.mem.trim(u8, l[5..], " ");
        if (std.mem.eql(u8, payload, "[DONE]")) return;
        const m = lastAssistant() orelse return;
        const d = parseDelta(st.alloc, payload, providers[st.prov].proto);
        defer d.deinit(st.alloc);
        if (d.text.len > 0) {
            m.text.appendSlice(d.text) catch {};
            st.got = true;
        }
        if (d.think.len > 0) m.think.appendSlice(d.think) catch {};
        if (d.err.len > 0) {
            st.stream_err = true;
            if (st.raw.items.len < 4096) st.raw.appendSlice(d.err) catch {};
        }
        return;
    }
    if (l.len == 0 or std.mem.startsWith(u8, l, "event:") or l[0] == ':') return;
    // SSE ではない行: エラーの本文(JSON)や curl のメッセージ
    if (st.raw.items.len < 65536) {
        st.raw.appendSlice(l) catch {};
        st.raw.append('\n') catch {};
    }
}

pub const Delta = struct {
    text: []const u8 = "",
    think: []const u8 = "",
    err: []const u8 = "",
    fn deinit(self: Delta, alloc: std.mem.Allocator) void {
        if (self.text.len > 0) alloc.free(self.text);
        if (self.think.len > 0) alloc.free(self.think);
        if (self.err.len > 0) alloc.free(self.err);
    }
};

fn getStr(v: std.json.Value, name: []const u8) ?[]const u8 {
    if (v != .object) return null;
    const x = v.object.get(name) orelse return null;
    return if (x == .string) x.string else null;
}

/// 1 つの data: の JSON から、増えた文章・考え中の文章・エラーを取り出す
pub fn parseDelta(alloc: std.mem.Allocator, payload: []const u8, proto: Proto) Delta {
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, payload, .{}) catch return .{};
    defer parsed.deinit();
    const v = parsed.value;
    var d = Delta{};
    if (v != .object) return d;
    if (errorMessage(v)) |e| {
        d.err = alloc.dupe(u8, e) catch "";
        return d;
    }
    switch (proto) {
        .anthropic => {
            const ty = getStr(v, "type") orelse return d;
            if (!std.mem.eql(u8, ty, "content_block_delta")) return d;
            const delta = v.object.get("delta") orelse return d;
            if (getStr(delta, "text")) |t| d.text = alloc.dupe(u8, t) catch "";
            if (getStr(delta, "thinking")) |t| d.think = alloc.dupe(u8, t) catch "";
        },
        .openai => {
            const ch = v.object.get("choices") orelse return d;
            if (ch != .array or ch.array.items.len == 0) return d;
            const c0 = ch.array.items[0];
            if (c0 != .object) return d;
            const delta = c0.object.get("delta") orelse c0.object.get("message") orelse return d;
            if (getStr(delta, "content")) |t| d.text = alloc.dupe(u8, t) catch "";
            if (getStr(delta, "reasoning_content") orelse getStr(delta, "reasoning")) |t| d.think = alloc.dupe(u8, t) catch "";
        },
    }
    return d;
}

/// エラーの JSON から人に読めるメッセージを取り出す({"error":{"message"}} / {"error":"…"} / [{"error":…}] / {"message"})
pub fn errorMessage(v: std.json.Value) ?[]const u8 {
    switch (v) {
        .array => |a| return if (a.items.len > 0) errorMessage(a.items[0]) else null,
        .object => |o| {
            if (o.get("error")) |e| {
                switch (e) {
                    .string => |s| return s,
                    .object => {
                        if (getStr(e, "message")) |m| return m;
                        if (getStr(e, "type")) |t| return t;
                        return "エラー";
                    },
                    else => {},
                }
            }
            if (getStr(v, "type")) |t| if (std.mem.eql(u8, t, "error")) return getStr(v, "message") orelse "エラー";
            return null;
        },
        else => return null,
    }
}

fn finishStream(stopped: bool) void {
    if (st.fd >= 0) {
        if (st.app) |a| a.loop.remove(st.fd);
        _ = c.close(st.fd);
        st.fd = -1;
    }
    removeBody();
    if (lastAssistant()) |m| {
        if (!st.got and !stopped) {
            var eb: [600]u8 = undefined;
            fail(m, describeFailure(&eb));
        } else if (st.stream_err) {
            // 途中までは届いたが、最後にエラー
            m.text.appendSlice("\n\n(エラー: ") catch {};
            m.text.appendSlice(std.mem.trim(u8, st.raw.items, " \n")) catch {};
            m.text.appendSlice(")") catch {};
        } else if (stopped and m.text.items.len == 0) {
            fail(m, "止めました");
        }
    }
    saveChat();
    redraw();
}

fn describeFailure(buf: []u8) []const u8 {
    const raw = std.mem.trim(u8, st.raw.items, " \r\n");
    var msg: []const u8 = raw;
    var parsed: ?std.json.Parsed(std.json.Value) = null;
    defer if (parsed) |p| p.deinit();
    if (std.mem.indexOfAny(u8, raw, "{[")) |j| {
        parsed = std.json.parseFromSlice(std.json.Value, st.alloc, raw[j..], .{}) catch null;
        if (parsed) |p| if (errorMessage(p.value)) |m| {
            msg = m;
        };
    }
    if (msg.len > 400) msg = msg[0..400];
    const what: []const u8 = switch (st.http) {
        0 => "つながりませんでした",
        401, 403 => "API キーが使えません",
        402 => "残高・クレジットが足りません",
        404 => "モデルか接続先が見つかりません",
        429 => "使いすぎの制限にかかりました(少し待ってから)",
        500...599 => "相手のサーバで問題が起きています",
        200 => "返事が空でした",
        else => "失敗しました",
    };
    if (msg.len == 0) return std.fmt.bufPrint(buf, "{s}(HTTP {d})", .{ what, st.http }) catch what;
    return std.fmt.bufPrint(buf, "{s}(HTTP {d}): {s}", .{ what, st.http, msg }) catch what;
}

// ---------------------------------------------------------------------------
// モデルの一覧(GET /models)
// ---------------------------------------------------------------------------

pub fn fetchModels(i: usize) void {
    const app = st.app orelse return;
    if (st.mfd >= 0) return;
    st.model_err_len = 0;
    const base = baseUrl(i);
    if (base.len == 0) return setModelErr("カスタムの接続先が未設定です");
    var kb: [512]u8 = undefined;
    const k = key(i, &kb);
    if (providers[i].need_key and k == null) return setModelErr("API キーを入れると一覧を取ってきます");
    var ub: [600]u8 = undefined;
    const url = std.fmt.bufPrint(&ub, "{s}/models", .{base}) catch return;
    var cfg = std.ArrayList(u8).init(st.alloc);
    defer cfg.deinit();
    buildCurlConfig(&cfg, i, url, k, null) catch return;
    @memset(&kb, 0);
    st.mbuf.clearRetainingCapacity();
    const argv = [_]?[*:0]const u8{ "curl", "-sS", "--connect-timeout", "10", "--max-time", "30", "-w", "\n" ++ HTTP_MARK ++ "%{http_code}\n", "-K", "-" };
    st.mfd = sys.spawnPiped(&argv, cfg.items, &st.mpid) orelse return setModelErr("curl を起動できませんでした");
    @memset(cfg.items, 0);
    st.model_prov = i;
    _ = st.model_arena.reset(.retain_capacity);
    st.model_list.clearRetainingCapacity();
    app.loop.add(st.mfd, c.EPOLLIN | c.EPOLLHUP, &st, onModels) catch {};
}

fn setModelErr(s: []const u8) void {
    const n = @min(s.len, st.model_err.len);
    @memcpy(st.model_err[0..n], s[0..n]);
    st.model_err_len = n;
    redraw();
}

fn onModels(_: *anyopaque, fd: c_int, _: u32) void {
    var tmp: [16384]u8 = undefined;
    while (true) {
        const n = c.read(fd, &tmp, tmp.len);
        if (n > 0) {
            if (st.mbuf.items.len < 16 << 20) st.mbuf.appendSlice(tmp[0..@intCast(n)]) catch {};
            continue;
        }
        if (n < 0 and std.posix.errno(n) == .AGAIN) return;
        break;
    }
    if (st.app) |a| a.loop.remove(fd);
    _ = c.close(fd);
    st.mfd = -1;
    const all = st.mbuf.items;
    var http: u32 = 0;
    var body = all;
    if (std.mem.lastIndexOf(u8, all, HTTP_MARK)) |j| {
        http = std.fmt.parseInt(u32, std.mem.trim(u8, all[j + HTTP_MARK.len ..], " \r\n"), 10) catch 0;
        body = all[0..j];
    }
    const n = parseModels(st.model_arena.allocator(), body, &st.model_list) catch 0;
    if (n == 0) {
        var eb: [160]u8 = undefined;
        setModelErr(std.fmt.bufPrint(&eb, "一覧を取れませんでした(HTTP {d})。モデル名を入力して Enter でも使えます", .{http}) catch "一覧を取れませんでした");
    }
    redraw();
}

/// {"data":[{"id":"…"},…]}(OpenAI 互換・Anthropic)/ {"models":[{"name":"models/…"}]} から id を取り出し、名前順に並べる
pub fn parseModels(alloc: std.mem.Allocator, body: []const u8, out: *std.ArrayList([]const u8)) !usize {
    const j = std.mem.indexOfAny(u8, body, "{[") orelse return 0;
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, body[j..], .{}) catch return 0;
    defer parsed.deinit();
    const v = parsed.value;
    const arr = blk: {
        if (v == .array) break :blk v.array.items;
        if (v != .object) return 0;
        const d = v.object.get("data") orelse v.object.get("models") orelse return 0;
        if (d != .array) return 0;
        break :blk d.array.items;
    };
    for (arr) |e| {
        if (out.items.len >= MAX_MODELS) break;
        var id = getStr(e, "id") orelse getStr(e, "name") orelse continue;
        if (std.mem.startsWith(u8, id, "models/")) id = id["models/".len..];
        try out.append(try alloc.dupe(u8, id));
    }
    std.mem.sort([]const u8, out.items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lt);
    return out.items.len;
}

// ---------------------------------------------------------------------------
// クリップボード(clipboard.zig。ext-data-control を直接使う)
// ---------------------------------------------------------------------------

pub fn copy(text: []const u8) void {
    const app = st.app orelse return;
    _ = @import("clipboard.zig").copy(app, text);
}

/// 貼り付け: 読み終わったら cb に渡す
pub fn paste(cb: *const fn ([]const u8) void) void {
    const app = st.app orelse return;
    _ = @import("clipboard.zig").paste(app, cb);
}

// ---------------------------------------------------------------------------

test "openai delta" {
    const a = std.testing.allocator;
    const d = parseDelta(a, "{\"choices\":[{\"delta\":{\"content\":\"こん\"}}]}", .openai);
    defer d.deinit(a);
    try std.testing.expectEqualStrings("こん", d.text);
    const r = parseDelta(a, "{\"choices\":[{\"delta\":{\"content\":null,\"reasoning_content\":\"考\"}}]}", .openai);
    defer r.deinit(a);
    try std.testing.expectEqualStrings("", r.text);
    try std.testing.expectEqualStrings("考", r.think);
}

test "anthropic delta and errors" {
    const a = std.testing.allocator;
    const d = parseDelta(a, "{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"Hi\"}}", .anthropic);
    defer d.deinit(a);
    try std.testing.expectEqualStrings("Hi", d.text);
    const e = parseDelta(a, "{\"type\":\"error\",\"error\":{\"type\":\"overloaded_error\",\"message\":\"Overloaded\"}}", .anthropic);
    defer e.deinit(a);
    try std.testing.expectEqualStrings("Overloaded", e.err);
    const p = try std.json.parseFromSlice(std.json.Value, a, "[{\"error\":{\"code\":400,\"message\":\"API key not valid\"}}]", .{});
    defer p.deinit();
    try std.testing.expectEqualStrings("API key not valid", errorMessage(p.value).?);
}

test "body and curl config" {
    const a = std.testing.allocator;
    var m1 = try Msg.create(a, .user);
    defer m1.destroy(a);
    try m1.text.appendSlice("say \"hi\"\n");
    var m2 = try Msg.create(a, .assistant);
    defer m2.destroy(a);
    var body = std.ArrayList(u8).init(a);
    defer body.deinit();
    try buildBody(&body, .anthropic, "claude", "be brief", &.{ m1, m2 });
    try std.testing.expectEqualStrings("{\"model\":\"claude\",\"stream\":true,\"max_tokens\":8192,\"system\":\"be brief\",\"messages\":[{\"role\":\"user\",\"content\":\"say \\\"hi\\\"\\n\"}]}", body.items);
    var cfg = std.ArrayList(u8).init(a);
    defer cfg.deinit();
    try buildCurlConfig(&cfg, 0, "https://x/v1/chat/completions", "sk-abc", "/run/b.json");
    try std.testing.expect(std.mem.indexOf(u8, cfg.items, "header = \"Authorization: Bearer sk-abc\"\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, cfg.items, "data-binary = \"@/run/b.json\"\n") != null);
    try std.testing.expect(!validKey("sk-\"bad\""));
    try std.testing.expect(validKey("sk-or-v1-0123456789abcdef"));
}

test "models list" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var list = std.ArrayList([]const u8).init(a);
    defer list.deinit();
    const n = try parseModels(arena.allocator(), "{\"object\":\"list\",\"data\":[{\"id\":\"b-model\"},{\"id\":\"models/a-model\"}]}", &list);
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectEqualStrings("a-model", list.items[0]);
}

test "chat round trip" {
    const a = std.testing.allocator;
    var list = std.ArrayList(*Msg).init(a);
    defer {
        for (list.items) |m| m.destroy(a);
        list.deinit();
    }
    try parseChat(a, &list, "U 5\nhello\nA 7\nline1\nx\n");
    try std.testing.expectEqual(@as(usize, 2), list.items.len);
    try std.testing.expectEqualStrings("line1\nx", list.items[1].text.items);
}
