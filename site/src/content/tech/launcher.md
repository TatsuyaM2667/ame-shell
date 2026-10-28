# ランチャーとアイコン

<p class="file">対象: src/launcher.zig(1219 行)/ src/icons.zig(212 行)/ src/wallpick.zig(383 行)/ src/platform/sys.zig の spawnDetached</p>

## アプリを探す: .desktop を読む {#desktop}

`$XDG_DATA_HOME` と `$XDG_DATA_DIRS` の各 `applications/` を、サブディレクトリまでたどって `.desktop` を読みます。Flatpak のアプリ(`~/.local/share/flatpak/exports/share` と `/var/lib/flatpak/exports/share`)も、`XDG_DATA_DIRS` に入っていない環境のために追加で探します。`[Desktop Entry]` の節だけを見て、`NoDisplay` / `Hidden` / `Type` が Application 以外のものは除きます。

読むキー: `Name`・`Name[ja]`・`GenericName`(`[ja]` 優先)・`Comment`(`[ja]` 優先)・`Keywords`・`Exec`・`Icon`・`Terminal`。

### 並べ方: 5 つの欄のいちばん良い点 {#rank}

```zig
const fields = [_]struct { s: []const u8, bonus: i32 }{
    .{ .s = e.name, .bonus = 30 },                                   // 表示名
    .{ .s = e.name_ja, .bonus = 30 },                                // 日本語の表示名
    .{ .s = e.generic, .bonus = 0 },                                 // 「ウェブブラウザ」など
    .{ .s = e.keywords, .bonus = -5 },                               // 検索用のキーワード
    .{ .s = std.fs.path.basename(firstWord(e.exec)), .bonus = 5 },   // 実行するコマンド名
};
for (fields) |f| {
    if (f.s.len == 0) continue;
    const sc = anim.fuzzy(q, f.s);
    if (sc >= 0) best = @max(best, sc + f.bonus);
}
…
// お気に入りは常に上、その次によく(最近)使うもの
if (e.fav) |rank| best += 100000 - @as(i32, @intCast(@min(rank, 1000))) * 10;
best += frecency(&e);
```

- 名前・日本語名・一般名・キーワード・コマンド名のそれぞれに [Odin のあいまい検索](#/tech-anim) を掛け、**いちばん良い点**を採ります。日本語の環境で「ブラウザ」と打っても、英語名の Firefox が見つかります。
- 欄ごとに加点を変えています。表示名の一致(+30)はキーワードの一致(−5)より信頼できるからです。
- **お気に入り**は 100000 点を足して必ず上に。お気に入りの中は並べた順(rank)。

### よく使う順(frecency) {#frecency}

```zig
fn frecency(e: *const Entry) i32 {
    if (e.uses == 0) return 0;
    const age = std.time.timestamp() - e.last_used;
    const day: i64 = 86400;
    const w: f32 = if (e.last_used == 0) 0.5 else if (age < day) 1.0 else if (age < 7 * day) 0.75 else if (age < 30 * day) 0.5 else 0.25;
    return @intFromFloat(@min(@as(f32, @floatFromInt(e.uses)), 200) * w * 6);
}
```

「使った回数(最大 200)× 最近さの重み × 6」。今日使ったものは 1.0、今週は 0.75、今月は 0.5、それより前は 0.25。Firefox の「frecency」と同じ考え方で、**よく使うものと最近使ったものの両方**を上に出します。回数の上限 200 は、昔たくさん使ったアプリが永遠に上に居座らないためです。

**検索語が空のとき**はこの順だけで並ぶので、Super を押して離した瞬間に、いつものアプリが一番上にあります。

## アプリの起動: 二重 fork + setsid {#spawn}

```zig
/// ランチャー等から GUI アプリを起動する。二重 fork + setsid でシェルから切り離し、
/// シェルが再起動してもアプリが道連れにならないようにする。
pub fn spawnDetached(cmdline: [*:0]const u8) void {
    const pid = c.fork();
    if (pid < 0) return;
    if (pid == 0) {
        _ = c.setsid();                 // 新しいセッション(端末やシェルのプロセスグループから外れる)
        const pid2 = c.fork();
        if (pid2 != 0) c._exit(0);      // 中間のプロセスはすぐ終わる → 孫は init の子になる
        var sigset: c.sigset_t = undefined;
        _ = c.sigemptyset(&sigset);
        _ = c.sigprocmask(c.SIG_SETMASK, &sigset, null);   // シグナルのマスクを引き継がない
        const argv = [_:null]?[*:0]const u8{ "/bin/sh", "-c", cmdline, null };
        _ = c.execv("/bin/sh", @ptrCast(&argv));
        c._exit(127);
    }
    var status: c_int = 0;
    _ = c.waitpid(pid, &status, 0);     // 中間のプロセスだけを待つ(すぐ終わる)
}
```

| 手順 | 理由 |
|---|---|
| `setsid` | ame-shell のプロセスグループから外す。ame-shell を再起動(`exec`)したり、落ちたりしても、起動したアプリは道連れにならない |
| 二重 fork | 孫プロセスの親は init(PID 1)になる。ame-shell がアプリの終了を待つ必要がなく、ゾンビも残らない |
| シグナルのマスクを空に | ame-shell がブロックしているシグナルを、アプリが引き継がないように |
| `/bin/sh -c` | `.desktop` の Exec は引数の引用などシェルの書式を含むことがあるため。ユーザーが入力したものではなく、インストールされたファイルの中身 |

## アイコン: 全テーマの索引を 1 回だけ作る {#icons}

```zig
// src/icons.zig
// 検索: 入っている全アイコンテーマ(ユーザー設定のテーマ → hicolor → breeze-dark → breeze →
// Adwaita → oxygen …)を一度だけ走査して「名前 → 一番良いファイル」の索引を作る。
// テーマの中ではカテゴリ(apps / devices / preferences …)を問わず、SVG(拡大しても綺麗)を
// 最優先、PNG は 64〜256px に近いものを選ぶ。索引作りは数十〜数百 ms かかるので、
// 必ずワーカースレッドから呼ぶこと(launcher.zig の IconWorker)。
//
// 読み込み: PNG/JPEG は stb_image、SVG は nanosvg でラスタライズし、指定の大きさに縮小する。
// "-symbolic" アイコン(単色の線画、暗い色で描かれている)は暗い UI で見えないので明るい色に塗り直す。
```

**なぜ freedesktop のアイコンテーマの仕様どおりに探さないか**: 仕様では「テーマ → 継承元 → 大きさの近いディレクトリ」と順に探しますが、アプリが自分のアイコンを入れているテーマはまちまちで(hicolor だけ、breeze だけ…)、仕様どおりだと見つからないアイコンが多く出ました。全テーマを 1 回走査して「名前 → いちばん良いファイル」の表にすると、どこに入っていても見つかり、探すのも表を引くだけになります。

**`-symbolic` アイコンを塗り直す**: GNOME 系の単色アイコンは暗い色で描かれていて、暗いガラスの上では見えません。明るい色に塗り直しています。

## 重い仕事はワーカースレッドで {#worker}

```zig
fn run(self: *IconWorker, jobs: []IconJob, gen: u32) void {
    for (jobs) |j| {
        … アイコンを探してデコード・縮小(動画の壁紙は ffmpeg で 1 コマ取り出して) …
        self.mutex.lock();
        self.results.append(.{ .idx = j.idx, .gen = gen, .thumb = j.thumb, .photo = j.photo, .px = px }) …
        self.mutex.unlock();
        // まとめて通知されても良い(読む側は全部取り出す)。満杯の EAGAIN は無視。
        _ = c.write(self.pipe_w, "i", 1);
    }
}
```

- **計測が理由**: `/usr/share/pixmaps/zellij.png`(巨大な PNG)のデコードだけで **92 ms**かかり、描画のスレッドでやると、その間ランチャーが止まりました。
- ワーカーは「(世代・行番号・画素)」を結果の配列に足し、pipe に 1 バイト書くだけです。**ランチャーのデータには一切触れません**。メインスレッドが epoll で pipe を受け取り、結果を取り出してテクスチャにします(GL は描画スレッドからしか触れないため)。
- **世代(`gen`)**: アプリの一覧を読み直した後に、前の一覧の結果が遅れて届くことがあります。世代が違う結果は捨てるので、別のアプリに違うアイコンが付くことはありません。
- pipe が満杯でも書き込みの失敗は無視します。読む側は、起きたら**溜まっている結果を全部**取り出すので、通知の 1 バイトが何個でも同じです。

**結果**: アイコンの読み込みが、描画のスレッドから完全に消えました。

## 壁紙ピッカー {#wallpick}

```zig
// src/wallpick.zig
// 全画面のオーバーレイに、斜め(平行四辺形)のカードを横一列に並べる。選択中のカードだけが
// スプリングで大きく広がり、ほかは細い短冊になって暗くなる。カードの中の画像は横位置に応じて
// 少しずれる(パララックス)。開くときはカードが下から時間差で飛び上がり、閉じるときは沈む。
// 決定すると、そのカードの位置を起点に壁紙が切り替わる(wallpaper.zig の円/斜めワイプ/短冊)。
```

- カードの形は、画像を歪めずに平行四辺形でくり抜くシェーダ([GPU の種類 9](#/tech-gpu))。
- 選んだカードの**画面上の位置**を、壁紙の切り替えのシェーダの起点(`u_origin`)として渡します。カードから新しい壁紙が広がるように見えます([切り替え](#/tech-glass))。
- 動画の壁紙のサムネイルは、ffmpeg で 1 秒目のコマを `~/.cache/ame-shell/thumbs` に PNG で保存します。ファイル名は「パスと更新時刻のハッシュ」なので、動画を差し替えたら作り直します。
