# メディア・歌詞・音・動画

<p class="file">対象: src/media.zig(331 行)/ src/lyrics.zig(319 行)/ src/audio.zig(223 行)/ src/video.zig(501 行)</p>

:::easy このページを読む前に
音楽を再生していると、ダッシュボードに曲名やアルバムアートや歌詞が出ます。これは、プレーヤーが「今この曲を、ここまで再生している」と知らせる約束事([[mpris]])を ame-shell が聞いているからです。

歌詞は、時刻付きの歌詞([[lrc]])をインターネットから取ってきて、再生位置に合わせて今の行を出します。動画の壁紙は、動画を GPU で直接描く仕組み([[libmpv]]、[[va-api]])で再生しています。
:::

## 再生中の曲: `playerctl --follow` を常駐させる {#mpris}

```zig
// src/media.zig
// メディア(MPRIS): `playerctl --follow` を常駐させ、出力行が来たときだけ状態を更新する
// (ポーリングしない)。アルバムアートは file:// ならそのまま、http(s) なら curl で
// キャッシュへ取得(完了を pipe の EOF で知る)。読み込んだ画像から Odin で主色を抽出し、
// テーマのアクセント色をその色へ滑らかに遷移させる。
const fd = sys.spawnReader(&.{ "playerctl", "--follow", "metadata", "--format", fmt }, &self.pid) orelse { … };
```

書式(`fmt`)は、タブ区切りで 8 項目です。

```
{{status}}\t{{playerName}}\t{{artist}}\t{{title}}\t{{mpris:artUrl}}\t{{mpris:length}}\t{{position}}\t{{xesam:album}}
```

```zig
fn parseLine(self: *Media, line: []const u8) void {
    var f = std.mem.splitScalar(u8, line, '\t');
    const status = f.next() orelse "";
    …
    const album = f.next() orelse "";
    …
    self.length_s = (std.fmt.parseFloat(f32, len_us) catch 0) / 1e6;
    // ライブ配信などは長さが無意味な値(数日以上)になるので「不明」扱いにする
    if (self.length_s > 86400) self.length_s = 0;
    self.pos_s = (std.fmt.parseFloat(f32, pos_us) catch 0) / 1e6;
    self.pos_at_ms = loop.nowMs();
    …
}
```

| 判断 | 理由 |
|---|---|
| **D-Bus を直接話さず playerctl を使う** | MPRIS は、プレーヤーの出現・消滅の追跡、複数のプレーヤーからどれを表示するかの選択、プロパティの変化の購読と、やることが多い。playerctl はそれを全部こなし、変化したときに 1 行出すだけ。ame-shell は行を待つだけで済む |
| **`--follow` で常駐** | 「1 秒ごとに playerctl を起動して聞く」と、何も再生していなくても毎秒プロセスが起動する。`--follow` なら変化があったときだけ行が来る |
| **タブ区切り** | 曲名やアーティスト名にはスペースや記号が入るが、タブはまず入らない |
| **長さが 1 日を超えたら「不明」** | ライブ配信では、プレーヤーが巨大な長さを返すことがある。そのまま進行バーにすると、バーが全く進まない |

### 再生位置は「最後に聞いた位置 + 経過時間」 {#position}

```zig
pub fn position(self: *Media) f32 {
    if (self.status != .playing) return self.pos_s;
    const p = self.pos_s + @as(f32, @floatFromInt(loop.nowMs() - self.pos_at_ms)) / 1000.0;
    return if (self.length_s > 0) @min(p, self.length_s) else p;
}

/// playerctl --follow は再生位置の変化(シーク)を通知しないので、歌詞を表示している間だけ
/// 3 秒おきに実際の位置を聞き直してずれを補正する。
pub fn resync(self: *Media) void { … }
```

再生位置を毎フレーム聞くのではなく、**最後に聞いた位置と、その時刻からの経過時間**で計算します。歌詞の同期と進行バーは毎フレームこの値を読みます。

ただし `playerctl --follow` は**シーク(再生位置のジャンプ)を通知しません**。そこで、**歌詞を表示している間だけ** 3 秒おきに実際の位置を聞き直します。歌詞を見ていないときは聞きません。

### アルバムアート {#art}

- `file://` ならそのまま読む。`http(s)://` なら curl でキャッシュに保存し、終わったら pipe の EOF で知る(`--max-filesize 8000000` で巨大な画像を拒否)。
- 読んだ画像から、配色と同じ方法でアクセントの色を作り、**再生中はアクセントをその色に**します([配色](#/tech-glass))。

## 同期歌詞: LRCLIB {#lyrics}

```zig
// src/lyrics.zig
//   1. キャッシュ(~/.cache/ame-shell/lyrics/<曲のハッシュ>)があればそれを使う
//   2. 無ければ curl で /api/get(アーティスト名 + 曲名 + 長さ)→ 見つからなければ /api/search
//      を非同期に叩き、完了を pipe の EOF で知る(シェルを通さず引数で渡すので曲名に何が入っていても安全)
//   3. JSON(std.json)から syncedLyrics(無ければ plainLyrics)を取り出して LRC を解析
// 曲が変わるたびに 1 回だけ問い合わせ、見つからなかったことも「無し」としてキャッシュする。
fd = sys.spawnReader(&.{ "curl", "-s", "--max-time", "8", "-A", "ame-shell (https://github.com)", "-G", "https://lrclib.net/api/get",
                         "--data-urlencode", an.ptr, "--data-urlencode", tn.ptr, "--data-urlencode", dn.ptr }, &self.pid);
```

| 判断 | 理由 |
|---|---|
| [LRCLIB](https://lrclib.net/) | 無料・登録不要。再生位置に同期した LRC がある |
| `/api/get` → `/api/search` | まず「アーティスト + 曲名 + 長さ」で正確に探し、無ければあいまいに検索する |
| **曲名を検索の前に整える** | 動画サイトの曲名にありがちな `【MV】`、`(Official Video)`、`[Lyrics]` などの飾りを末尾から取り除く(`cleanTitle`) |
| `--data-urlencode` で引数として渡す | 曲名に `&` や `'` が入っていても、URL やシェルとして解釈されない |
| **「無かった」こともキャッシュ** | 歌詞の無い曲を再生するたびに問い合わせない |
| curl は子プロセス | HTTP・TLS のライブラリをリンクしない。8 秒のタイムアウト。待つのは pipe だけ |

### LRC の解析 {#lrc}

```zig
while (line.len > 0 and line[0] == '[') {
    const close = std.mem.indexOfScalar(u8, line, ']') orelse break;
    const tag = line[1..close];
    line = line[close + 1 ..];
    const colon = std.mem.indexOfScalar(u8, tag, ':') orelse continue;
    const mm = std.fmt.parseFloat(f32, tag[0..colon]) catch continue; // [ar:..] 等のタグは数値にならない
    const ss = std.fmt.parseFloat(f32, tag[colon + 1 ..]) catch continue;
    …
}
```

- 1 行に**複数の時刻**(`[00:12.00][01:30.00]サビ`)があっても、それぞれの時刻に同じ行を登録します(繰り返しのサビの書き方)。
- `[ar:…]` のような情報のタグは、数値にならないので自然に読み飛ばします。
- 時刻の無い行しか無ければ「同期なしの歌詞」として、曲の進み具合に合わせてゆっくり送ります。

### 今の行を探す {#current}

```zig
pub fn current(self: *const Lyrics, pos: f32) struct { idx: ?usize, frac: f32 } {
    …
    for (ls, 0..) |l, i| {
        if (l.t <= pos) idx = i else break;
    }
    const next_t = if (i + 1 < ls.len) ls[i + 1].t else ls[i].t + 5;
    const span = @max(next_t - ls[i].t, 0.1);
    return .{ .idx = i, .frac = std.math.clamp((pos - ls[i].t) / span, 0, 1) };
}
```

今の行と、その行の中でどこまで進んだか(`frac`、0〜1)を返します。表示側は、行が変わったときにポップのばねを 0 から始め([アニメーション](#/animation))、`frac` で文字の色をアクセントへ近づけます。

### プレーヤーから歌詞を渡す仕組み {#sidecar}

```zig
pub fn trySidecar(self: *Lyrics, player: []const u8) void {
    …
    for (player) |ch| if (!(std.ascii.isAlphanumeric(ch) or ch == '_' or ch == '-' or ch == '.')) return;
    const p = std.fmt.bufPrint(&pb, "{s}/lyrics/{s}.lrc", .{ rd, player }) catch return;   // $XDG_RUNTIME_DIR/lyrics/<プレーヤー名>.lrc
    const st = std.fs.cwd().statFile(p) catch return;
    if (st.mtime == self.sidecar_mtime) return;            // 変わっていなければ読まない
    … [ti:] と [ar:] を読む …
    if (!eqi(ti, title)) return;                           // 今の曲のものか
    if (ar.len > 0 and artist.len > 0 and !eqi(ar, artist)) return;
    // 一致: LRCLIB の問い合わせをやめて、こちらを使う
    self.cancel();
    …
}
```

自前の歌詞を持っているプレーヤー(作者の [music-tui-bsd](https://github.com/TatsuyaM2667/music-tui-bsd) など)は、`$XDG_RUNTIME_DIR/lyrics/<MPRIS のプレーヤー名>.lrc` に書けば、それが LRCLIB より優先されます。

- **プレーヤー名の文字を確かめてから**パスに使います(`../` などでほかの場所を読ませない)。
- `[ti:]`(と `[ar:]`)が今の曲と一致するときだけ使うので、前の曲のファイルが残っていても間違えません。
- 更新時刻が変わったときだけ読み直します。
- `$XDG_RUNTIME_DIR` はログイン中だけ存在し、本人だけが書けるディレクトリです。ほかのユーザーが偽の歌詞を置くことはできません。

## 音の出力先: pactl のテキストを読む {#audio}

```zig
// src/audio.zig
// pactl の JSON 出力は日本語の機器名(AirPods の名前など)で壊れるので、テキスト形式を読む。
// 一覧の取得・切り替えは別スレッドで行い(pactl は数十 ms かかる)、終わったら pipe でメインループへ知らせる。
// 切り替えたときは、再生中・録音中のストリームも新しい機器へ移す。
```

- **JSON ではなくテキスト**: `pactl -f json` は、機器名に日本語が入ると壊れた JSON を出しました(作者の AirPods の名前で発生)。そこで人間向けのテキスト出力を読んでいます。
- **別スレッド**: pactl は 1 回に数十 ms かかるので、描画のスレッドでは呼びません。
- **ストリームも移す**: 既定の出力を変えるだけでは、すでに鳴っている音(再生中の曲)は元の機器のまま鳴り続けます。再生中のストリームも新しい機器へ移します。
- 音量の変化は `pactl subscribe` を常駐させて知ります(PipeWire のネイティブ API を使わないのは、開発用のパッケージへの依存を避けるため)。値の変更と読み取りは `wpctl` で行い、`-l 1.0` で 100% を超えないようにしています(耳とスピーカーの保護)。

## 動画の壁紙: libmpv の描画 API {#video}

```zig
// src/video.zig
// 動画・GIF のライブ壁紙(libmpv の描画 API を dlopen で使う)。
// libmpv(C ライブラリ)は実行時に読み込むので、ビルドにヘッダや開発パッケージは要らない。
const h = std.c.dlopen("libmpv.so.2", std.c.RTLD.LAZY) orelse std.c.dlopen("libmpv.so", std.c.RTLD.LAZY) orelse { … };
```

```zig
/// 壁紙向け: 音なし・無限ループ・ハードウェア復号・字幕や OSD なし
const opts = [_][2][*:0]const u8{
    .{ "vo", "libmpv" },
    .{ "hwdec", "auto-safe" },
    .{ "loop-file", "inf" },
    .{ "audio", "no" },
    …
    .{ "video-sync", "display-desync" },
    .{ "config", "no" },
};
```

| 判断 | 理由 |
|---|---|
| **libmpv の描画 API**(`vo=libmpv`) | mpv が復号したコマを、ame-shell の OpenGL のコンテキストの FBO に**直接**描かせる。CPU にコピーしない |
| **dlopen** | libmpv が無い環境でも ame-shell は起動できる(動画の壁紙だけが使えない)。ビルドに mpv の開発パッケージが要らない |
| `hwdec=auto-safe` | VA-API などのハードウェア復号を、安全と分かっているものだけ使う |
| `config=no` | ユーザーの mpv の設定(字幕や音声の設定)の影響を受けない |
| `wl_display` を渡さない | 渡すと VA-API が別の場所で Wayland の往復をして、ame-shell のイベントループの読み込みの準備と噛み合って固まった。復号は DRM のレンダーノード経由で行う |
| mpv のスレッドからは pipe に 1 バイト書くだけ | mpv のコールバックは mpv のスレッドで呼ばれる。GL を触れるのはメインスレッドだけなので、そこで「起きて」と知らせるだけにする |

### libmpv が使えないとき: ffmpeg {#ffmpeg}

```zig
// まず VA-API(GPU で復号・縮小。4K でも CPU は軽い)、使えなければ CPU で復号する。
// どちらも画面を覆うように拡大して切り抜く(壁紙のシェーダの cover と同じ見た目)。動画のパスは $1 で渡す
\\common="-nostdin -loglevel error -stream_loop -1 -re"
\\ffmpeg $common -hwaccel vaapi -hwaccel_output_format vaapi -i "$1" -an -sn \
\\  -vf "scale_vaapi=w={d}:h={d}:force_original_aspect_ratio=increase,hwdownload,format=nv12,crop={d}:{d},fps=30,format=rgba" \
\\  -f rawvideo - ||
\\exec ffmpeg $common -i "$1" -an -sn \
\\  -vf "scale={d}:{d}:force_original_aspect_ratio=increase,crop={d}:{d},fps=30" -pix_fmt rgba -f rawvideo -
```

FreeBSD など、libmpv が無い・再生できない・5 秒たっても最初のコマが出ない環境では、ffmpeg のプロセスで復号します。

- **VA-API で復号と縮小まで GPU で**行い、小さくなった画像だけを CPU に下ろします。失敗したら(VA-API のドライバが無いなど)、`||` で CPU の復号に切り替えます。
- 結果は横 1280 までの RGBA。パイプからコマの大きさ分を読み、たまったら 2 枚のバッファを入れ替えてテクスチャに送ります。
- 動画のパスは `$1`(位置引数)として渡します。ファイル名に空白や記号があっても、シェルの文字列に埋め込まないので安全です。
- 止めるときはプロセスグループごと SIGKILL して `waitpid` で回収します(sh と ffmpeg の両方を確実に止める)。

**実測**(4K の動画、Radeon 680M): VA-API の経路で CPU 約 **39%**、CPU 復号では約 **135%**。libmpv の経路はさらに軽く、約 5%(720p の動画)です。

>! **見つけて直した不具合**: 再生に失敗した ffmpeg のパイプを epoll に残したままにすると、パイプは「EOF で読める」状態のまま残り、epoll が起き続けて CPU が空回りしました。失敗したプレーヤーはその場で epoll から外して片付けるようにしています。

## 研究者向けの補足 {#research}

:::research 時計の同期と、外部プロセスとの境界
再生位置の推定は、「最後に観測した位置 p₀ と時刻 t₀」からの外挿 `p(t) = p₀ + (t − t₀)·r`(r = 再生速度 = 1)で、観測の間隔の間のプレーヤーとの時計のずれ(ドリフト)と、通知されないシーク(不連続)を、3 秒ごとの再観測で補正する**区分的な線形の推定**です。歌詞の同期の誤差は、外挿の誤差と、playerctl の出力の遅延の和で抑えられます。

外部のプログラム(playerctl・curl・pactl・ffmpeg)を子プロセスとして使い、結果をパイプの EOF で受ける設計は、ライブラリをリンクする場合に比べて**故障の隔離**(子が落ちても親は落ちない)と**依存の最小化**(HTTP・TLS・D-Bus・コーデックのライブラリをリンクしない)を得る代わりに、プロセスの生成のコスト(数 ms)を払います。どれも人間の操作の頻度(秒単位)でしか起きないので、このコストは無視できます。
:::

## 関連する用語 {#terms}

- [[mpris]]
- [[lrc]]
- [[pipewire]]
- [[libmpv]]
- [[va-api]]
- [[a2dp-hfp]]
