// AI の API とのやりとりの部品(画面にも OS の作りにも依存しない)。
// ame-ai(src/cmd/ame-ai.zig)が使い、ame-shell の AI チャットも会社の一覧・API キーの保存に使う。
//
// 会話の形式は 2 種類だけ:
//   openai    … OpenAI 互換の /chat/completions(OpenAI・Gemini・Mistral・DeepSeek・OpenRouter・Kimi・OpenCode Zen・
//                xAI・Groq・Qwen・GLM・Perplexity・Together・Cerebras・Ollama・その他の互換サーバ)
//   anthropic … Anthropic の /messages
//
// 会話は、会社に関係なく同じ形(Turn の並び。JSON では下の parseConversation の形)で受け渡す。
// API キー: ~/.config/ame-shell/ai-keys(「<会社の id> <キー>」の行、0600)、無ければ環境変数(OPENAI_API_KEY など)。
const std = @import("std");

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

/// tool = コーディング CLI のツールの実行(1 行目が見出し、残りが出力)
pub fn providerIndex(id: []const u8) ?usize {
    for (providers, 0..) |p, i| if (std.mem.eql(u8, p.id, id)) return i;
    return null;
}

// ---------------------------------------------------------------------------
// 置き場・API キー
// ---------------------------------------------------------------------------

pub fn configDir(buf: []u8) ?[]const u8 {
    if (std.posix.getenv("XDG_CONFIG_HOME")) |x| if (x.len > 0) return std.fmt.bufPrint(buf, "{s}/ame-shell", .{x}) catch null;
    const h = std.posix.getenv("HOME") orelse return null;
    return std.fmt.bufPrint(buf, "{s}/.config/ame-shell", .{h}) catch null;
}

pub fn stateDir(buf: []u8) ?[]const u8 {
    if (std.posix.getenv("XDG_STATE_HOME")) |x| if (x.len > 0) return std.fmt.bufPrint(buf, "{s}/ame-shell", .{x}) catch null;
    const h = std.posix.getenv("HOME") orelse return null;
    return std.fmt.bufPrint(buf, "{s}/.local/state/ame-shell", .{h}) catch null;
}

pub fn readSmall(path: []const u8, buf: []u8) ?[]const u8 {
    const f = std.fs.cwd().openFile(path, .{}) catch return null;
    defer f.close();
    const n = f.readAll(buf) catch return null;
    return buf[0..n];
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
pub fn saveKey(alloc: std.mem.Allocator, i: usize, k: []const u8) bool {
    if (k.len > 0 and !validKey(k)) return false;
    var pb: [512]u8 = undefined;
    const path = keysPath(&pb) orelse return false;
    var db: [400]u8 = undefined;
    std.fs.cwd().makePath(configDir(&db) orelse return false) catch {};
    var fb: [8192]u8 = undefined;
    const old = readSmall(path, &fb) orelse "";
    var out = std.ArrayList(u8).init(alloc);
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
    if (k.len > 0) out.writer().print("{s} {s}\n", .{ providers[i].id, k }) catch return false;
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

// ---------------------------------------------------------------------------
// 会話(会社に関係ない形)
// ---------------------------------------------------------------------------

pub const Call = struct { id: []const u8, name: []const u8, args: []const u8 };

/// 送る画像(base64 にしたもの)
pub const Image = struct { mime: []const u8, b64: []const u8 };

/// 会話の 1 つ。user / assistant(calls = そのあとに呼んだツール)/ tool(id の呼び出しの結果)
pub const Turn = struct {
    role: enum { user, assistant, tool },
    content: []const u8 = "",
    calls: []const Call = &.{},
    id: []const u8 = "",
    err: bool = false,
    /// user に付けた画像のファイル(会話の JSON の "images")。読んで images にするのは ame-ai
    image_paths: []const []const u8 = &.{},
    images: []const Image = &.{},
};

/// 画像の種類(先頭のバイトで見分ける)。送れない形なら null
pub fn mimeOf(b: []const u8) ?[]const u8 {
    if (std.mem.startsWith(u8, b, "\x89PNG\r\n\x1a\n")) return "image/png";
    if (std.mem.startsWith(u8, b, "\xff\xd8\xff")) return "image/jpeg";
    if (std.mem.startsWith(u8, b, "GIF87a") or std.mem.startsWith(u8, b, "GIF89a")) return "image/gif";
    if (b.len >= 12 and std.mem.eql(u8, b[0..4], "RIFF") and std.mem.eql(u8, b[8..12], "WEBP")) return "image/webp";
    return null;
}

/// モデルに渡すツール(name は <サーバ>__<ツール>。schema は JSON の文字列)
pub const ToolDef = struct { name: []const u8, description: []const u8, schema: []const u8 };

/// JSON の会話を読む:
///   [{"role":"user","content":"…"},
///    {"role":"assistant","content":"…","tool_calls":[{"id":"…","name":"…","arguments":"{…}"}]},
///    {"role":"tool","id":"…","content":"…","error":false}]
pub fn parseConversation(a: std.mem.Allocator, json: []const u8) ![]Turn {
    const v = try std.json.parseFromSliceLeaky(std.json.Value, a, json, .{});
    if (v != .array) return error.NotAnArray;
    var out = std.ArrayList(Turn).init(a);
    for (v.array.items) |e| {
        const role = getStr(e, "role") orelse continue;
        const content = getStr(e, "content") orelse "";
        if (std.mem.eql(u8, role, "user")) {
            var paths = std.ArrayList([]const u8).init(a);
            if (e.object.get("images")) |im| if (im == .array) for (im.array.items) |p| {
                if (p == .string) try paths.append(p.string);
            };
            try out.append(.{ .role = .user, .content = content, .image_paths = paths.items });
        } else if (std.mem.eql(u8, role, "assistant")) {
            var calls = std.ArrayList(Call).init(a);
            if (e.object.get("tool_calls")) |tc| if (tc == .array) for (tc.array.items) |c| {
                try calls.append(.{ .id = getStr(c, "id") orelse "", .name = getStr(c, "name") orelse "", .args = getStr(c, "arguments") orelse "{}" });
            };
            try out.append(.{ .role = .assistant, .content = content, .calls = calls.items });
        } else if (std.mem.eql(u8, role, "tool")) {
            const err = if (e.object.get("error")) |x| x == .bool and x.bool else false;
            try out.append(.{ .role = .tool, .content = content, .id = getStr(e, "id") orelse "", .err = err });
        }
    }
    return out.items;
}

/// JSON のオブジェクトの文字列を値にする(壊れていれば空のオブジェクト)
fn parseObj(a: std.mem.Allocator, s: []const u8) std.json.Value {
    const v = std.json.parseFromSliceLeaky(std.json.Value, a, if (s.len > 0) s else "{}", .{}) catch return .{ .object = std.json.ObjectMap.init(a) };
    if (v != .object) return .{ .object = std.json.ObjectMap.init(a) };
    return v;
}

fn findResult(turns: []const Turn, id: []const u8) ?Turn {
    for (turns) |t| if (t.role == .tool and std.mem.eql(u8, t.id, id)) return t;
    return null;
}

/// 画像つきの頼みごと: Anthropic は [{image(base64)}…, {text}]、OpenAI 互換は [{text}, {image_url(data URI)}…]
fn writeUserParts(ws: anytype, proto: Proto, t: Turn, a: std.mem.Allocator) !void {
    try ws.beginArray();
    if (proto == .anthropic) {
        for (t.images) |im| {
            try ws.beginObject();
            try ws.objectField("type");
            try ws.write("image");
            try ws.objectField("source");
            try ws.beginObject();
            try ws.objectField("type");
            try ws.write("base64");
            try ws.objectField("media_type");
            try ws.write(im.mime);
            try ws.objectField("data");
            try ws.write(im.b64);
            try ws.endObject();
            try ws.endObject();
        }
    }
    if (t.content.len > 0) {
        try ws.beginObject();
        try ws.objectField("type");
        try ws.write("text");
        try ws.objectField("text");
        try ws.write(t.content);
        try ws.endObject();
    }
    if (proto == .openai) {
        for (t.images) |im| {
            try ws.beginObject();
            try ws.objectField("type");
            try ws.write("image_url");
            try ws.objectField("image_url");
            try ws.beginObject();
            try ws.objectField("url");
            try ws.write(try std.fmt.allocPrint(a, "data:{s};base64,{s}", .{ im.mime, im.b64 }));
            try ws.endObject();
            try ws.endObject();
        }
    }
    try ws.endArray();
}

/// 送る本文(JSON)を作る。結果の届いていないツールの呼び出しは送らない
pub fn buildBody(out: *std.ArrayList(u8), proto: Proto, mdl: []const u8, system: []const u8, turns: []const Turn, tools: []const ToolDef) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer arena.deinit();
    const a = arena.allocator();
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
    for (turns) |t| {
        switch (t.role) {
            .tool => {}, // 呼び出しのあとにまとめて書く
            .user => {
                if (t.content.len == 0 and t.images.len == 0) continue;
                try ws.beginObject();
                try ws.objectField("role");
                try ws.write("user");
                try ws.objectField("content");
                if (t.images.len == 0) {
                    try ws.write(t.content);
                } else try writeUserParts(&ws, proto, t, a);
                try ws.endObject();
            },
            .assistant => {
                var calls = std.ArrayList(Call).init(a);
                for (t.calls) |c| if (findResult(turns, c.id) != null) try calls.append(c);
                if (t.content.len == 0 and calls.items.len == 0) continue;
                try ws.beginObject();
                try ws.objectField("role");
                try ws.write("assistant");
                try ws.objectField("content");
                if (proto == .anthropic) {
                    try ws.beginArray();
                    if (t.content.len > 0) {
                        try ws.beginObject();
                        try ws.objectField("type");
                        try ws.write("text");
                        try ws.objectField("text");
                        try ws.write(t.content);
                        try ws.endObject();
                    }
                    for (calls.items) |c| {
                        try ws.beginObject();
                        try ws.objectField("type");
                        try ws.write("tool_use");
                        try ws.objectField("id");
                        try ws.write(c.id);
                        try ws.objectField("name");
                        try ws.write(c.name);
                        try ws.objectField("input");
                        try ws.write(parseObj(a, c.args));
                        try ws.endObject();
                    }
                    try ws.endArray();
                } else {
                    if (t.content.len > 0) try ws.write(t.content) else try ws.write(null);
                    if (calls.items.len > 0) {
                        try ws.objectField("tool_calls");
                        try ws.beginArray();
                        for (calls.items) |c| {
                            try ws.beginObject();
                            try ws.objectField("id");
                            try ws.write(c.id);
                            try ws.objectField("type");
                            try ws.write("function");
                            try ws.objectField("function");
                            try ws.beginObject();
                            try ws.objectField("name");
                            try ws.write(c.name);
                            try ws.objectField("arguments");
                            try ws.write(if (c.args.len > 0) c.args else "{}");
                            try ws.endObject();
                            try ws.endObject();
                        }
                        try ws.endArray();
                    }
                }
                try ws.endObject();
                if (calls.items.len == 0) continue;
                // ツールの結果(Anthropic は 1 つの user にまとめる)
                if (proto == .anthropic) {
                    try ws.beginObject();
                    try ws.objectField("role");
                    try ws.write("user");
                    try ws.objectField("content");
                    try ws.beginArray();
                    for (calls.items) |c| {
                        const r = findResult(turns, c.id).?;
                        try ws.beginObject();
                        try ws.objectField("type");
                        try ws.write("tool_result");
                        try ws.objectField("tool_use_id");
                        try ws.write(c.id);
                        try ws.objectField("content");
                        try ws.write(if (r.content.len > 0) r.content else "(空)");
                        if (r.err) {
                            try ws.objectField("is_error");
                            try ws.write(true);
                        }
                        try ws.endObject();
                    }
                    try ws.endArray();
                    try ws.endObject();
                } else for (calls.items) |c| {
                    const r = findResult(turns, c.id).?;
                    try ws.beginObject();
                    try ws.objectField("role");
                    try ws.write("tool");
                    try ws.objectField("tool_call_id");
                    try ws.write(c.id);
                    try ws.objectField("content");
                    try ws.write(if (r.content.len > 0) r.content else "(空)");
                    try ws.endObject();
                }
            },
        }
    }
    try ws.endArray();
    if (tools.len > 0) {
        try ws.objectField("tools");
        try ws.beginArray();
        for (tools) |t| {
            try ws.beginObject();
            if (proto == .anthropic) {
                try ws.objectField("name");
                try ws.write(t.name);
                try ws.objectField("description");
                try ws.write(t.description);
                try ws.objectField("input_schema");
                try ws.write(parseObj(a, t.schema));
            } else {
                try ws.objectField("type");
                try ws.write("function");
                try ws.objectField("function");
                try ws.beginObject();
                try ws.objectField("name");
                try ws.write(t.name);
                try ws.objectField("description");
                try ws.write(t.description);
                try ws.objectField("parameters");
                try ws.write(parseObj(a, t.schema));
                try ws.endObject();
            }
            try ws.endObject();
        }
        try ws.endArray();
    }
    try ws.endObject();
}

// ---------------------------------------------------------------------------
// curl の設定(API キーはコマンドラインに出さず、curl の標準入力 -K - で渡す)
// ---------------------------------------------------------------------------

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
pub fn buildCurlConfig(out: *std.ArrayList(u8), i: usize, url: []const u8, k: ?[]const u8, body_file: ?[]const u8) !void {
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

// ---------------------------------------------------------------------------
// 返事の読み取り(Server-Sent Events の data: 1 つずつ)
// ---------------------------------------------------------------------------

pub fn getStr(v: std.json.Value, name: []const u8) ?[]const u8 {
    if (v != .object) return null;
    const x = v.object.get(name) orelse return null;
    return if (x == .string) x.string else null;
}

/// 1 つの data: から取り出したもの(文字は v の中を指す)
pub const Delta = struct {
    text: []const u8 = "",
    think: []const u8 = "",
    err: []const u8 = "",
};

/// 1 つの data: の JSON(解析済み)から、増えた文章・考え中の文章・エラーを取り出す
pub fn parseDelta(v: std.json.Value, proto: Proto) Delta {
    var d = Delta{};
    if (v != .object) return d;
    if (errorMessage(v)) |e| {
        d.err = e;
        return d;
    }
    switch (proto) {
        .anthropic => {
            const ty = getStr(v, "type") orelse return d;
            if (!std.mem.eql(u8, ty, "content_block_delta")) return d;
            const delta = v.object.get("delta") orelse return d;
            if (getStr(delta, "text")) |t| d.text = t;
            if (getStr(delta, "thinking")) |t| d.think = t;
        },
        .openai => {
            const ch = v.object.get("choices") orelse return d;
            if (ch != .array or ch.array.items.len == 0) return d;
            const c0 = ch.array.items[0];
            if (c0 != .object) return d;
            const delta = c0.object.get("delta") orelse c0.object.get("message") orelse return d;
            if (getStr(delta, "content")) |t| d.text = t;
            if (getStr(delta, "reasoning_content") orelse getStr(delta, "reasoning")) |t| d.think = t;
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

/// 返事が来なかったときの、人に読める理由(HTTP の状態と、届いた本文から)
pub fn describeFailure(a: std.mem.Allocator, http: u32, raw_in: []const u8) []const u8 {
    const raw = std.mem.trim(u8, raw_in, " \r\n");
    var msg: []const u8 = raw;
    if (std.mem.indexOfAny(u8, raw, "{[")) |j| {
        if (std.json.parseFromSliceLeaky(std.json.Value, a, raw[j..], .{})) |v| {
            if (errorMessage(v)) |m| msg = m;
        } else |_| {}
    }
    if (msg.len > 400) msg = msg[0..400];
    const what: []const u8 = switch (http) {
        0 => "つながりませんでした",
        401, 403 => "API キーが使えません",
        402 => "残高・クレジットが足りません",
        404 => "モデルか接続先が見つかりません",
        429 => "使いすぎの制限にかかりました(少し待ってから)",
        500...599 => "相手のサーバで問題が起きています",
        200 => "返事が空でした",
        else => "失敗しました",
    };
    if (msg.len == 0) return std.fmt.allocPrint(a, "{s}(HTTP {d})", .{ what, http }) catch what;
    return std.fmt.allocPrint(a, "{s}(HTTP {d}): {s}", .{ what, http, msg }) catch what;
}

/// 返事の途中で少しずつ届くツールの呼び出しを組み立てる
/// (OpenAI: delta.tool_calls の index ごと / Anthropic: content_block_start の tool_use と input_json_delta)
pub const CallBuilder = struct {
    const Part = struct { index: u32, id: std.ArrayList(u8), name: std.ArrayList(u8), args: std.ArrayList(u8) };
    a: std.mem.Allocator,
    parts: std.ArrayList(Part),

    pub fn init(a: std.mem.Allocator) CallBuilder {
        return .{ .a = a, .parts = std.ArrayList(Part).init(a) };
    }

    fn at(self: *CallBuilder, idx: u32) ?*Part {
        for (self.parts.items) |*p| if (p.index == idx) return p;
        self.parts.append(.{ .index = idx, .id = std.ArrayList(u8).init(self.a), .name = std.ArrayList(u8).init(self.a), .args = std.ArrayList(u8).init(self.a) }) catch return null;
        return &self.parts.items[self.parts.items.len - 1];
    }

    pub fn feed(self: *CallBuilder, v: std.json.Value, proto: Proto) void {
        if (v != .object) return;
        switch (proto) {
            .anthropic => {
                const ty = getStr(v, "type") orelse return;
                const idx: u32 = if (v.object.get("index")) |x| (if (x == .integer) @intCast(@max(0, x.integer)) else 0) else 0;
                if (std.mem.eql(u8, ty, "content_block_start")) {
                    const cb = v.object.get("content_block") orelse return;
                    if (!std.mem.eql(u8, getStr(cb, "type") orelse "", "tool_use")) return;
                    const p = self.at(idx) orelse return;
                    p.id.appendSlice(getStr(cb, "id") orelse "") catch {};
                    p.name.appendSlice(getStr(cb, "name") orelse "") catch {};
                } else if (std.mem.eql(u8, ty, "content_block_delta")) {
                    const d = v.object.get("delta") orelse return;
                    const pj = getStr(d, "partial_json") orelse return;
                    for (self.parts.items) |*p| if (p.index == idx) p.args.appendSlice(pj) catch {};
                }
            },
            .openai => {
                const ch = v.object.get("choices") orelse return;
                if (ch != .array or ch.array.items.len == 0 or ch.array.items[0] != .object) return;
                const delta = ch.array.items[0].object.get("delta") orelse ch.array.items[0].object.get("message") orelse return;
                if (delta != .object) return;
                const tc = delta.object.get("tool_calls") orelse return;
                if (tc != .array) return;
                for (tc.array.items, 0..) |t, k| {
                    if (t != .object) continue;
                    const idx: u32 = if (t.object.get("index")) |x| (if (x == .integer) @intCast(@max(0, x.integer)) else @intCast(k)) else @intCast(k);
                    const p = self.at(idx) orelse continue;
                    if (getStr(t, "id")) |id| if (p.id.items.len == 0) p.id.appendSlice(id) catch {};
                    if (t.object.get("function")) |f| {
                        if (getStr(f, "name")) |n| p.name.appendSlice(n) catch {};
                        if (getStr(f, "arguments")) |ar| p.args.appendSlice(ar) catch {};
                    }
                }
            },
        }
    }

    /// 組み上がった呼び出し(id が無ければ round と順番から作る)
    pub fn calls(self: *CallBuilder, round: u32) []Call {
        var out = std.ArrayList(Call).init(self.a);
        for (self.parts.items, 0..) |p, k| {
            if (p.name.items.len == 0) continue;
            const id = if (p.id.items.len > 0) p.id.items else std.fmt.allocPrint(self.a, "call_{d}_{d}", .{ round, k }) catch "call";
            out.append(.{ .id = id, .name = p.name.items, .args = if (p.args.items.len > 0) p.args.items else "{}" }) catch {};
        }
        return out.items;
    }
};

// ---------------------------------------------------------------------------
// モデルの一覧(GET /models)
// ---------------------------------------------------------------------------

const MAX_MODELS = 600;

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

fn parseV(a: std.mem.Allocator, s: []const u8) std.json.Value {
    return std.json.parseFromSliceLeaky(std.json.Value, a, s, .{}) catch .null;
}

test "deltas and errors" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("こん", parseDelta(parseV(a, "{\"choices\":[{\"delta\":{\"content\":\"こん\"}}]}"), .openai).text);
    try std.testing.expectEqualStrings("考", parseDelta(parseV(a, "{\"choices\":[{\"delta\":{\"content\":null,\"reasoning_content\":\"考\"}}]}"), .openai).think);
    try std.testing.expectEqualStrings("Hi", parseDelta(parseV(a, "{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"Hi\"}}"), .anthropic).text);
    try std.testing.expectEqualStrings("Overloaded", parseDelta(parseV(a, "{\"type\":\"error\",\"error\":{\"type\":\"overloaded_error\",\"message\":\"Overloaded\"}}"), .anthropic).err);
    try std.testing.expectEqualStrings("API key not valid", errorMessage(parseV(a, "[{\"error\":{\"code\":400,\"message\":\"API key not valid\"}}]")).?);
    try std.testing.expectEqualStrings("API キーが使えません(HTTP 401): bad key", describeFailure(a, 401, "{\"error\":{\"message\":\"bad key\"}}"));
}

test "body and curl config" {
    var body = std.ArrayList(u8).init(std.testing.allocator);
    defer body.deinit();
    try buildBody(&body, .anthropic, "claude", "be brief", &.{.{ .role = .user, .content = "say \"hi\"\n" }}, &.{});
    try std.testing.expectEqualStrings("{\"model\":\"claude\",\"stream\":true,\"max_tokens\":8192,\"system\":\"be brief\",\"messages\":[{\"role\":\"user\",\"content\":\"say \\\"hi\\\"\\n\"}]}", body.items);
    var cfg = std.ArrayList(u8).init(std.testing.allocator);
    defer cfg.deinit();
    try buildCurlConfig(&cfg, 0, "https://x/v1/chat/completions", "sk-abc", "/run/b.json");
    try std.testing.expect(std.mem.indexOf(u8, cfg.items, "header = \"Authorization: Bearer sk-abc\"\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, cfg.items, "data-binary = \"@/run/b.json\"\n") != null);
    try std.testing.expect(!validKey("sk-\"bad\""));
    try std.testing.expect(validKey("sk-or-v1-0123456789abcdef"));
}

test "conversation with tool calls" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const turns = try parseConversation(a,
        \\[{"role":"user","content":"天気は?"},
        \\ {"role":"assistant","content":"","tool_calls":[{"id":"c1","name":"w__get","arguments":"{\"city\":\"東京\"}"},{"id":"c2","name":"w__x","arguments":"{}"}]},
        \\ {"role":"tool","id":"c1","content":"晴れ"}]
    );
    try std.testing.expectEqual(@as(usize, 3), turns.len);
    const tools = [_]ToolDef{.{ .name = "w__get", .description = "d", .schema = "{\"type\":\"object\"}" }};
    var body = std.ArrayList(u8).init(std.testing.allocator);
    defer body.deinit();
    try buildBody(&body, .openai, "m", "", turns, &tools);
    // 結果の無い c2 は送らない
    try std.testing.expect(std.mem.indexOf(u8, body.items, "c2") == null);
    try std.testing.expect(std.mem.indexOf(u8, body.items, "\"tool_calls\":[{\"id\":\"c1\",\"type\":\"function\",\"function\":{\"name\":\"w__get\",\"arguments\":\"{\\\"city\\\":\\\"東京\\\"}\"}}]") != null);
    try std.testing.expect(std.mem.indexOf(u8, body.items, "{\"role\":\"tool\",\"tool_call_id\":\"c1\",\"content\":\"晴れ\"}") != null);
    body.clearRetainingCapacity();
    try buildBody(&body, .anthropic, "m", "", turns, &tools);
    try std.testing.expect(std.mem.indexOf(u8, body.items, "{\"type\":\"tool_use\",\"id\":\"c1\",\"name\":\"w__get\",\"input\":{\"city\":\"東京\"}}") != null);
    try std.testing.expect(std.mem.indexOf(u8, body.items, "\"input_schema\":{\"type\":\"object\"}") != null);
}

test "call builder and models" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var cb = CallBuilder.init(a);
    cb.feed(parseV(a, "{\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"call_1\",\"function\":{\"name\":\"w__get\",\"arguments\":\"\"}}]}}]}"), .openai);
    cb.feed(parseV(a, "{\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"function\":{\"arguments\":\"{\\\"c\\\":1}\"}}]}}]}"), .openai);
    const calls = cb.calls(1);
    try std.testing.expectEqual(@as(usize, 1), calls.len);
    try std.testing.expectEqualStrings("{\"c\":1}", calls[0].args);
    var list = std.ArrayList([]const u8).init(a);
    try std.testing.expectEqual(@as(usize, 2), try parseModels(a, "{\"data\":[{\"id\":\"b\"},{\"id\":\"models/a\"}]}", &list));
    try std.testing.expectEqualStrings("a", list.items[0]);
}

test "user turn with images" {
    var body = std.ArrayList(u8).init(std.testing.allocator);
    defer body.deinit();
    const turns = [_]Turn{.{ .role = .user, .content = "これは何?", .images = &.{.{ .mime = "image/png", .b64 = "QUJD" }} }};
    try buildBody(&body, .anthropic, "m", "", &turns, &.{});
    try std.testing.expect(std.mem.indexOf(u8, body.items, "\"content\":[{\"type\":\"image\",\"source\":{\"type\":\"base64\",\"media_type\":\"image/png\",\"data\":\"QUJD\"}},{\"type\":\"text\",\"text\":\"これは何?\"}]") != null);
    body.clearRetainingCapacity();
    try buildBody(&body, .openai, "m", "", &turns, &.{});
    try std.testing.expect(std.mem.indexOf(u8, body.items, "\"content\":[{\"type\":\"text\",\"text\":\"これは何?\"},{\"type\":\"image_url\",\"image_url\":{\"url\":\"data:image/png;base64,QUJD\"}}]") != null);
    // 画像だけ(文が空)でも送る
    body.clearRetainingCapacity();
    try buildBody(&body, .openai, "m", "", &.{.{ .role = .user, .images = &.{.{ .mime = "image/jpeg", .b64 = "QQ==" }} }}, &.{});
    try std.testing.expect(std.mem.indexOf(u8, body.items, "data:image/jpeg;base64,QQ==") != null);
    // 会話の JSON の images
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const t = try parseConversation(arena.allocator(), "[{\"role\":\"user\",\"content\":\"x\",\"images\":[\"/a.png\",\"/b.jpg\"]}]");
    try std.testing.expectEqual(@as(usize, 2), t[0].image_paths.len);
    try std.testing.expectEqualStrings("/b.jpg", t[0].image_paths[1]);
    try std.testing.expectEqualStrings("image/png", mimeOf("\x89PNG\r\n\x1a\n....").?);
    try std.testing.expectEqualStrings("image/webp", mimeOf("RIFF\x00\x00\x00\x00WEBPVP8 ").?);
    try std.testing.expect(mimeOf("hello") == null);
}
