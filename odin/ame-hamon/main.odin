// ame-hamon: 今鳴っている音を周波数ごとの棒の高さにして、1 行ずつ流す(cava の代わり)。
// 名前は波紋(はもん)から。雨粒が水面に広げる輪のように、音を広げて見せる。
//
//   ame-hamon [-b 本数]     1 行 = 棒の高さ(0〜1000)を ';' でつないだもの(cava の raw ascii と同じ形)
//
// 音は PulseAudio の録音の口(PipeWire なら pipewire-pulse)の @DEFAULT_MONITOR@ から、libpulse-simple を実行時に読んで取る。
// 計算: 窓をかけて FFT(anim/fft.odin。ame-shell と同じもの)、50Hz〜12kHz を対数で分け、dB にして最近の大きい音で
// 自動でそろえる。上がるときはすぐ、下がるときはなめらかに。1 秒に約 60 行。
// 全部 0 の行は続けて出さない(無音のとき、読む側を起こさない)。
// 終了コード: 0 読む側が閉じた / 1 音を取り込めない
package main

import anim "../../anim"
import "core:dynlib"
import "core:fmt"
import "core:math"
import "core:os"
import "core:strconv"
import "core:strings"

FFT_N :: 1024
RATE :: 44100
CHUNK :: RATE / 60 // 1 回に受け取るサンプル数(約 60 回/秒)
MAX_BARS :: 256

Sample_Spec :: struct {
	format:   i32,
	rate:     u32,
	channels: u8,
}
Buffer_Attr :: struct {
	maxlength, tlength, prebuf, minreq, fragsize: u32,
}

Simple :: struct {
	new:  proc "c" (server: cstring, name: cstring, dir: i32, dev: cstring, stream: cstring, ss: ^Sample_Spec, cmap: rawptr, attr: ^Buffer_Attr, err: ^i32) -> rawptr,
	read: proc "c" (s: rawptr, data: rawptr, bytes: uint, err: ^i32) -> i32,
}

load :: proc() -> (pa: Simple, ok: bool) {
	lib: dynlib.Library
	for n in ([]string{"libpulse-simple.so.0", "libpulse-simple.so"}) {
		if lib, ok = dynlib.load_library(n); ok do break
	}
	if !ok do return
	p1, ok1 := dynlib.symbol_address(lib, "pa_simple_new")
	p2, ok2 := dynlib.symbol_address(lib, "pa_simple_read")
	pa.new = auto_cast p1
	pa.read = auto_cast p2
	return pa, ok1 && ok2
}

/// 窓・回転子・帯域の区切り
Tables :: struct {
	window: [FFT_N]f32,
	tw:     [FFT_N]f32, // cos, sin を N/2 組
	edges:  [MAX_BARS + 1]i32,
}

make_tables :: proc(t: ^Tables, bars: int) {
	nf := f32(FFT_N)
	for i in 0 ..< FFT_N do t.window[i] = 0.5 - 0.5 * math.cos(math.TAU * f32(i) / (nf - 1))
	for k in 0 ..< FFT_N / 2 {
		a := -math.TAU * f32(k) / nf
		t.tw[2 * k] = math.cos(a)
		t.tw[2 * k + 1] = math.sin(a)
	}
	edges(t.edges[:bars + 1], bars)
}

/// 50Hz〜12kHz を対数で等分した FFT のビン番号(低い方は 1 ビン以上の幅を保つ)
edges :: proc(out: []i32, bars: int) {
	prev: i32 = 0
	for b in 0 ..= bars {
		r := f32(b) / f32(bars)
		f := 50 * math.pow(f32(12000) / 50, r)
		bin := i32(f * FFT_N / RATE)
		if b > 0 && bin <= prev do bin = prev + 1
		out[b] = min(bin, FFT_N / 2 - 1)
		prev = out[b]
	}
}

/// 帯域のパワーを 0..1 にそろえ、なめらかにして values に入れる。peak_db は最近の大きい音の目安
shape :: proc(bands: []f32, values: []f32, peak_db: ^f32) {
	loudest: f32 = -120
	db: [MAX_BARS]f32
	n := len(bands)
	for p, i in bands {
		// 高い音ほど小さく出るので少し持ち上げる(ピンクノイズの傾き)
		tilt := 3.0 * f32(i) / f32(n)
		db[i] = 10 * math.log10(p + 1e-12) + tilt * 6
		loudest = max(loudest, db[i])
	}
	// 基準は上がるときは速く、下がるときはゆっくり
	peak_db^ = loudest > peak_db^ ? loudest : peak_db^ - 0.15
	peak_db^ = max(peak_db^, -40)
	RANGE :: 45
	for i in 0 ..< n {
		v := clamp((db[i] - (peak_db^ - RANGE)) / RANGE, 0, 1)
		target := v * v // 小さい音を沈めて、山を目立たせる
		values[i] = target > values[i] ? target : values[i] * 0.82 + target * 0.18
	}
}

/// 「-b 本数」を読む(1〜256。無ければ 48)。誤りなら 0
parse_bars :: proc(args: []string) -> int {
	if len(args) == 0 do return 48
	if len(args) != 2 || args[0] != "-b" do return 0
	n, ok := strconv.parse_int(args[1], 10)
	return ok && n >= 1 && n <= MAX_BARS ? n : 0
}

main :: proc() {
	bars := parse_bars(os.args[1:])
	if bars == 0 {
		fmt.eprintln("使い方: ame-hamon [-b 本数(1〜256)]")
		os.exit(2)
	}
	pa, ok := load()
	if !ok {
		fmt.eprintln("ame-hamon: libpulse-simple が見つかりません")
		os.exit(1)
	}
	ss := Sample_Spec{format = 5, rate = RATE, channels = 1} // PA_SAMPLE_FLOAT32LE・モノラル
	attr := Buffer_Attr{max(u32), max(u32), max(u32), max(u32), CHUNK * 4}
	err: i32
	s := pa.new(nil, "ame-hamon", 2, "@DEFAULT_MONITOR@", "spectrum", &ss, nil, &attr, &err)
	if s == nil {
		fmt.eprintln("ame-hamon: 音を取り込めません(@DEFAULT_MONITOR@)")
		os.exit(1)
	}
	t := new(Tables)
	make_tables(t, bars)
	ring: [FFT_N]f32
	buf: [CHUNK]f32
	work: [2 * FFT_N]f32
	bands: [MAX_BARS]f32
	values: [MAX_BARS]f32
	peak_db: f32 = -30
	was_zero := false
	sb := strings.builder_make()
	for {
		if pa.read(s, &buf, size_of(buf), &err) < 0 {
			fmt.eprintln("ame-hamon: 音の取り込みが止まりました")
			os.exit(1)
		}
		// 古いサンプルを前へ詰めて、新しいものを後ろへ
		copy(ring[:FFT_N - CHUNK], ring[CHUNK:])
		copy(ring[FFT_N - CHUNK:], buf[:])
		anim.spectrum(&ring[0], FFT_N, &t.window[0], &t.tw[0], &work[0], &t.edges[0], i32(bars), &bands[0])
		shape(bands[:bars], values[:bars], &peak_db)
		strings.builder_reset(&sb)
		zero := true
		for i in 0 ..< bars {
			v := int(values[i] * 1000 + 0.5)
			if v > 0 do zero = false
			fmt.sbprintf(&sb, "%d;", v)
		}
		if zero && was_zero do continue
		was_zero = zero
		strings.write_byte(&sb, '\n')
		// 読む側が閉じたら終わる(SIGPIPE か書けないとき)
		if _, werr := os.write(os.stdout, sb.buf[:]); werr != nil do os.exit(0)
	}
}
