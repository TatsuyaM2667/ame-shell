# OS 対応(Linux と FreeBSD)

<p class="file">対象: src/platform/sys.zig(409 行)/ src/platform/bsd.zig(159 行)/ src/platform/supertap.zig(151 行)/ src/platform/loop.zig / build.zig</p>

ame-shell は、Linux(Chimera = musl / Arch = glibc)と FreeBSD 14・15 の両方で、**同じソースから**ビルドします。OS の違いは `src/platform/` と `build.zig` の中に閉じ込め、それ以外のコードは OS を知りません。

:::easy このページを読む前に
Linux と FreeBSD は、どちらも Unix の仲間ですが、細かいところが違います。電池の残りや CPU の温度の読み方、OS に仕事を頼むときの番号([[syscall]])、キーボードの読み方([[ioctl]])などです。

ame-shell は、この違いを `src/platform/` という場所に閉じ込めています。それ以外の部分は、どちらの OS で動いているかを知りません。
:::

## 方針: カーネルのインターフェースと、小さなコマンドだけ {#policy}

```zig
// src/platform/sys.zig
// OS 依存のデータ取得(sysfs / procfs / 外部コマンド)。
//
// init(dinit/systemd)には依存せず、カーネルのインターフェースと、どの
// ディストリにもある小さなコマンド(wpctl, brightnessctl, nmcli)だけを使う。
// コマンドが無い環境ではその機能だけ「不明」として扱い、シェルは動き続ける。
```

- **init に依存しない**: systemd の D-Bus API(logind 以外)や dinit の機能は使いません。Chimera(dinit)・Arch(systemd)・FreeBSD(rc)で同じように動きます。
- **無ければ「不明」**: 例えば brightnessctl が無い機械では、明るさの項目が出ないだけです。シェルは止まりません。

## 同じ情報を OS ごとに {#sources}

| 情報 | Linux | FreeBSD |
|---|---|---|
| CPU の使用率 | `/proc/stat` の差分 | `sysctlbyname("kern.cp_time")` の差分 |
| メモリ | `/proc/meminfo`(MemAvailable) | `vm.stats.vm.v_page_count` など。「使える」= 空き + inactive + laundry |
| 電池 | `/sys/class/power_supply/*/capacity`・`status`・`online` | `hw.acpi.battery.life`・`state`・`hw.acpi.acline` |
| CPU 温度 | hwmon | `dev.cpu.0.temperature`(0.1 K 単位。coretemp / amdtemp が必要) |
| 機種名 | DMI(`/sys/class/dmi/id`) | `kenv smbios.system.product` |
| 明るさ | brightnessctl | `backlight` コマンド |
| 音量 | wpctl | wpctl(PipeWire があれば)、無ければ `mixer` |
| ネットワーク | nmcli | `ifconfig` |
| 電源操作 | `loginctl reboot / poweroff / suspend` | ConsoleKit2 の D-Bus(`dbus-send --system`) |
| epoll・timerfd・inotify | カーネル | libepoll-shim・libinotify(kqueue の上に同じ API を作るライブラリ) |

```zig
// src/platform/bsd.zig — /proc の代わりに sysctl を直接読む
extern "c" fn sysctlbyname(name: [*:0]const u8, oldp: ?*anyopaque, oldlenp: ?*usize, newp: ?*const anyopaque, newlen: usize) c_int;

/// kern.cp_time: user, nice, sys, intr, idle(全 CPU の合計)
pub fn cpuTimes() ?struct { idle: u64, total: u64 } {
    var t: [5]c_long = undefined;
    var len: usize = @sizeOf(@TypeOf(t));
    if (sysctlbyname("kern.cp_time", &t, &len, null, 0) != 0) return null;
    …
}

/// (使用中, 全体) バイト。使える = 空き + inactive + laundry(Linux の MemAvailable に近い)
pub fn memory() ?struct { used: f64, total: f64 } { … }
```

**sysctl をコマンド(`sysctl -n`)ではなく関数で読む理由**: ダッシュボードを開いている間は 1 秒ごとに読むので、毎回プロセスを起動するのは無駄です。`sysctlbyname(3)` ならシステムコール 1 回で済みます。

**電源操作に root が要らない理由**: Linux では logind(elogind / systemd-logind)が、FreeBSD では ConsoleKit2 が、「ログイン中の本人」に再起動や電源オフを許可します。ame-shell は sudo / doas を使いません。

## epoll と timerfd を FreeBSD で {#shim}

FreeBSD のイベントの仕組みは kqueue で、epoll・timerfd・inotify はありません。ame-shell の [イベントループ](#/tech-loop) は epoll で書いているので、FreeBSD では **libepoll-shim**(kqueue の上に epoll と timerfd を作る)と **libinotify**(同じく inotify)をリンクします。

| 方法 | 判断 |
|---|---|
| **epoll-shim と libinotify** | ✓ ループのコードを変えずに済む。FreeBSD のパッケージにある。Wayland(libwayland)自身も FreeBSD では epoll-shim を使っている |
| kqueue 版のループを別に書く | 2 つのループを保守することになる |
| libuv などの抽象化 | 依存が大きい |

ただし、Zig の標準ライブラリの `std.os.linux.*` は**Linux のシステムコール番号を直接**使うので、FreeBSD では使えません。これを踏んで起動直後に SIGSYS で落ちたのが、[起動とイベントループ](#/tech-loop#sigsys)の件です。今は FreeBSD 向けのバイナリに Linux のシステムコールが 1 つも無いことを、毎回逆アセンブルで確かめています。

## ioctl の番号と型の違い {#ioctl}

```zig
/// EVIOCGBIT(EV_KEY, len) = _IOC(_IOC_READ, 'E', 0x20 + EV_KEY, len)
fn eviocgbitKey(len: u32) u32 {
    // EVIOCGBIT(EV_KEY, len)。ioctl 番号の作り方は OS で違う(Linux の _IOC_READ は 2<<30、FreeBSD の IOC_OUT は 1<<30)
    const dir: u32 = if (@import("builtin").os.tag == .freebsd) 1 << 30 else 2 << 30;
    return dir | ((len & 0x1fff) << 16) | ('E' << 8) | (0x20 + 1);
}
…
// ioctl の request の型は libc で違う(musl は int、FreeBSD は unsigned long)ので、その型へビット列のまま変換する
const Req = @typeInfo(@TypeOf(c.ioctl)).Fn.params[1].type.?;
const req: Req = if (@typeInfo(Req).Int.signedness == .signed) @bitCast(eviocgbitKey(bits.len)) else eviocgbitKey(bits.len);
```

FreeBSD も evdev(`/dev/input/event*`)を持っていますが、**ioctl の番号の作り方**が Linux と違います(「読み出し」の向きを表すビットが、Linux は `2 << 30`、FreeBSD は `1 << 30`)。さらに `ioctl` の第 2 引数の型が、musl では `int`、FreeBSD では `unsigned long` です。Zig の `@typeInfo` で `ioctl` の引数の型をコンパイル時に調べ、**同じビット列のまま**その型に変換しています。

## Super キーだけのタップを見分ける {#supertap}

```zig
// src/platform/supertap.zig
// River 0.3 のキーマップは、修飾キー単体の押下と組み合わせ(Super+1 など)を区別できない
// (-release マッピングは組み合わせの後でも発火する)。そこで evdev(/dev/input/event*)から
// キー入力を「読むだけ」で監視し、
//     Super を押す → 他のキー・マウスボタンを一切押さずに → 600ms 以内に離す
// ときだけ発火させる。デバイスを grab しないので River や他のアプリの入力には影響しない。
// 読むのは押下/解放のキーコードだけで、どこにも保存しない。
```

- **なぜ evdev を直接読むか**: Wayland のクライアントは、フォーカスを持っていないときのキー入力を受け取れません。コンポジタのキーの割り当てでは「Super を離した」ことは分かっても、「その間にほかのキーを押したか」が分かりません。
- **読むだけ・grab しない**: `EVIOCGRAB` を使わないので、River やほかのアプリへの入力はそのままです。
- **キーボードとマウスだけを開く**: `EVIOCGBIT` で「A キーと Super キーを持つ(=キーボード)」か「左ボタンを持つ(=マウス)」デバイスだけを残し、ほかは閉じます。
- **抜き差しに追従**: `/dev/input` を inotify で見て、新しいデバイスができたら 800 ms 後に読み直します(デバイスの権限の設定が少し遅れて付くため)。
- **権限**: `/dev/input/event*` を読むには、Linux では `input` グループ、FreeBSD では devfs の規則が必要です(インストーラが設定)。読めない環境では、この機能だけが無効になり、Super+D は使えます。

## FreeBSD でつまずいた点のまとめ {#freebsd}

| 症状 | 原因 | 対策 |
|---|---|---|
| 起動直後に SIGSYS | `std.os.linux.timerfd_settime`(Linux のシステムコール番号 286) | Linux 以外は libc の `timerfd_settime`。逆アセンブルで検査 |
| ディスクの容量を読めない | musl の `struct statvfs` は translate-c で不透明型になる。さらにメンバーの並びが Linux(bsize, frsize, blocks, bfree, bavail …)と FreeBSD(bavail, bfree, blocks, … frsize …)で違う | 64 bit の整数の並びとして読み、OS ごとに「何番目が何か」を表にする(`frame/data.zig`) |
| Super のタップが効かない | ioctl の番号の作り方・引数の型の違い | 上の `eviocgbitKey` と `@typeInfo` |
| ロックできない | FreeBSD の pam_unix は root でないと照合できない | setuid の swaylock に任せる([ロック](#/tech-notify-lock)) |
| 動画の壁紙が出ない | libmpv が無い・動かない環境 | ffmpeg で再生する経路([動画](#/tech-media#ffmpeg)) |
| タッチパッドが動かない | I2C HID のドライバ(ig4・iichid・hmt)が既定で読み込まれない | インストーラで kld_list に追加(GPIO 割り込みは未対応なので自動でポーリング) |

## 研究者向けの補足 {#research}

:::research 移植性の層と、ABI の差
移植性の問題は、(1) **API の差**(epoll と kqueue、/proc と sysctl)、(2) **ABI の差**(構造体の並び、システムコールの番号、ioctl の符号化、関数の引数の型)、(3) **ポリシーの差**(pam_unix の権限モデル)、に分けられます。(1) は shim のライブラリ(libepoll-shim・libinotify)と `platform/` の関数で吸収し、(2) はコンパイル時の型の反射(`@typeInfo`)と OS ごとの定数の表で吸収し、(3) は機能を別の実装(setuid の swaylock)に委ねて吸収しています。

(2) の誤りは**コンパイルもリンクも通る**ため、最も見つけにくい種類です(SIGSYS の件)。これに対しては、成果物(バイナリ)に対する不変条件の静的な検査(逆アセンブルでの命令の計数)が有効でした。
:::

## 関連する用語 {#terms}

- [[kqueue]]
- [[sysctl]]
- [[ioctl]]
- [[evdev]]
- [[syscall]]
- [[sigsys]]
