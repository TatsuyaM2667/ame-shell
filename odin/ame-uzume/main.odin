// ame-uzume: 音量を読む / 変える / 見張る(wpctl・pactl の代わり)。
// 名前は天岩戸の前で舞い、音を鳴らした芸能の神、天宇受売命(あめのうずめ)から。
//
//   ame-uzume                  今の音量を 1 行(「45」、消音なら「45 muted」)
//   ame-uzume set 40 | +5 | -5 音量を変える(0〜100。100 は超えない: 耳とスピーカーを守る)
//   ame-uzume mute [on|off]    消音を切り替える(on / off で決め打ち)
//   ame-uzume restore          最後に set / mute した音量に戻す(ログインのとき)
//   ame-uzume watch            今の音量を 1 行、その後は変わるたびに 1 行(終わらない)
//
// 相手は既定の出力(@DEFAULT_SINK@)。PulseAudio の口(PipeWire なら pipewire-pulse)に libpulse で話す。
// libpulse は実行時に読む(ヘッダも -dev パッケージも要らない。無ければ 1 で終わる)。
// set / mute した値は $XDG_STATE_HOME/ame-shell/volume に「45 0」の形で覚える。
// 終了コード: 0 できた / 1 音の口につながらない・変えられない / 2 使い方の誤り
package main

import "core:dynlib"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"

NORM :: 0x10000 // PA_VOLUME_NORM(100%)
CHANNELS_MAX :: 32
SINK :: cstring("@DEFAULT_SINK@")

// libpulse の構造体(必要な前の方だけ。ABI は 0.9 から変わっていない)
Sample_Spec :: struct {
	format:   i32,
	rate:     u32,
	channels: u8,
}
Channel_Map :: struct {
	channels: u8,
	pos:      [CHANNELS_MAX]i32,
}
CVolume :: struct {
	channels: u8,
	values:   [CHANNELS_MAX]u32,
}
Sink_Info :: struct {
	name:         cstring,
	index:        u32,
	description:  cstring,
	spec:         Sample_Spec,
	cmap:         Channel_Map,
	owner_module: u32,
	volume:       CVolume,
	mute:         i32,
}

Sink_Cb :: proc "c" (ctx: rawptr, info: ^Sink_Info, eol: i32, ud: rawptr)
Ok_Cb :: proc "c" (ctx: rawptr, ok: i32, ud: rawptr)
Event_Cb :: proc "c" (ctx: rawptr, ev: u32, idx: u32, ud: rawptr)

Pa :: struct {
	mainloop_new:           proc "c" () -> rawptr,
	mainloop_get_api:       proc "c" (ml: rawptr) -> rawptr,
	mainloop_iterate:       proc "c" (ml: rawptr, block: i32, ret: ^i32) -> i32,
	context_new:            proc "c" (api: rawptr, name: cstring) -> rawptr,
	context_connect:        proc "c" (ctx: rawptr, server: cstring, flags: i32, api: rawptr) -> i32,
	context_get_state:      proc "c" (ctx: rawptr) -> i32,
	get_sink_info_by_name:  proc "c" (ctx: rawptr, name: cstring, cb: Sink_Cb, ud: rawptr) -> rawptr,
	set_sink_volume_by_name: proc "c" (ctx: rawptr, name: cstring, v: ^CVolume, cb: Ok_Cb, ud: rawptr) -> rawptr,
	set_sink_mute_by_name:  proc "c" (ctx: rawptr, name: cstring, mute: i32, cb: Ok_Cb, ud: rawptr) -> rawptr,
	set_subscribe_callback: proc "c" (ctx: rawptr, cb: Event_Cb, ud: rawptr),
	subscribe:              proc "c" (ctx: rawptr, mask: u32, cb: Ok_Cb, ud: rawptr) -> rawptr,
	operation_get_state:    proc "c" (op: rawptr) -> i32,
	operation_unref:        proc "c" (op: rawptr),
}
pa: Pa
ml, ctx: rawptr

load :: proc() -> bool {
	lib: dynlib.Library
	ok: bool
	for n in ([]string{"libpulse.so.0", "libpulse.so"}) {
		if lib, ok = dynlib.load_library(n); ok do break
	}
	if !ok do return false
	sym :: proc(lib: dynlib.Library, name: string, dst: ^$T) -> bool {
		p, found := dynlib.symbol_address(lib, name)
		if found do dst^ = cast(T)p
		return found
	}
	return(
		sym(lib, "pa_mainloop_new", &pa.mainloop_new) &&
		sym(lib, "pa_mainloop_get_api", &pa.mainloop_get_api) &&
		sym(lib, "pa_mainloop_iterate", &pa.mainloop_iterate) &&
		sym(lib, "pa_context_new", &pa.context_new) &&
		sym(lib, "pa_context_connect", &pa.context_connect) &&
		sym(lib, "pa_context_get_state", &pa.context_get_state) &&
		sym(lib, "pa_context_get_sink_info_by_name", &pa.get_sink_info_by_name) &&
		sym(lib, "pa_context_set_sink_volume_by_name", &pa.set_sink_volume_by_name) &&
		sym(lib, "pa_context_set_sink_mute_by_name", &pa.set_sink_mute_by_name) &&
		sym(lib, "pa_context_set_subscribe_callback", &pa.set_subscribe_callback) &&
		sym(lib, "pa_context_subscribe", &pa.subscribe) &&
		sym(lib, "pa_operation_get_state", &pa.operation_get_state) &&
		sym(lib, "pa_operation_unref", &pa.operation_unref) \
	)
}

/// 音の口につなぐ(PA_CONTEXT_READY = 4、FAILED = 5、TERMINATED = 6)
connect :: proc() -> bool {
	if !load() do return false
	ml = pa.mainloop_new()
	ctx = pa.context_new(pa.mainloop_get_api(ml), "ame-uzume")
	if ctx == nil || pa.context_connect(ctx, nil, 0, nil) < 0 do return false
	for {
		switch pa.context_get_state(ctx) {
		case 4:
			return true
		case 5, 6:
			return false
		}
		if pa.mainloop_iterate(ml, 1, nil) < 0 do return false
	}
}

/// 操作が終わるまで回す(PA_OPERATION_RUNNING = 0)
wait :: proc(op: rawptr) -> bool {
	if op == nil do return false
	for pa.operation_get_state(op) == 0 {
		if pa.mainloop_iterate(ml, 1, nil) < 0 do break
	}
	pa.operation_unref(op)
	return true
}

Level :: struct {
	known:    bool,
	pct:      int, // 0〜100 より上もありうる(ほかのアプリが上げたとき)
	muted:    bool,
	channels: u8,
}

on_sink :: proc "c" (_: rawptr, info: ^Sink_Info, eol: i32, ud: rawptr) {
	if eol != 0 || info == nil do return
	l := cast(^Level)ud
	n := int(info.volume.channels)
	if n == 0 do return
	// 一番大きいチャンネル(pactl・wpctl の見せ方と同じ)
	m: u32 = 0
	for i in 0 ..< n do m = max(m, info.volume.values[i])
	l^ = {true, int((u64(m) * 100 + NORM / 2) / NORM), info.mute != 0, info.volume.channels}
}

read :: proc() -> Level {
	l: Level
	wait(pa.get_sink_info_by_name(ctx, SINK, on_sink, &l))
	return l
}

ok_flag :: proc "c" (_: rawptr, ok: i32, ud: rawptr) {(cast(^bool)ud)^ = ok != 0}

set_pct :: proc(cur: Level, pct: int) -> bool {
	v: CVolume
	v.channels = cur.channels
	for i in 0 ..< int(cur.channels) do v.values[i] = u32((pct * NORM + 50) / 100)
	done := false
	return wait(pa.set_sink_volume_by_name(ctx, SINK, &v, ok_flag, &done)) && done
}

set_mute :: proc(m: bool) -> bool {
	done := false
	return wait(pa.set_sink_mute_by_name(ctx, SINK, i32(m), ok_flag, &done)) && done
}

/// 「40」「+5」「-5」(後ろの % は読み飛ばす)を、新しい音量(0〜100)にする。読めなければ -1
target :: proc(arg: string, cur: int) -> int {
	s := strings.trim_suffix(arg, "%")
	sign := 0
	if len(s) > 0 && (s[0] == '+' || s[0] == '-') {
		sign = s[0] == '+' ? 1 : -1
		s = s[1:]
	}
	n, ok := strconv.parse_int(s, 10)
	if !ok || n < 0 || n > 100 do return -1
	want := sign == 0 ? n : cur + sign * n
	return clamp(want, 0, 100)
}

state_path :: proc() -> string {
	if d := os.get_env("XDG_STATE_HOME", context.temp_allocator); d != "" do return strings.concatenate({d, "/ame-shell/volume"}, context.temp_allocator)
	home := os.get_env("HOME", context.temp_allocator)
	return strings.concatenate({home, "/.local/state/ame-shell/volume"}, context.temp_allocator)
}

save :: proc(l: Level) {
	p := state_path()
	dir := p[:strings.last_index_byte(p, '/')]
	// ~/.local/state/ame-shell が無ければ作る(親は 1 段だけ)
	os.make_directory(dir[:strings.last_index_byte(dir, '/')])
	os.make_directory(dir)
	_ = os.write_entire_file(p, transmute([]u8)fmt.tprintf("%d %d\n", l.pct, l.muted ? 1 : 0))
}

print_level :: proc(l: Level) {
	fmt.printf("%d%s\n", l.pct, l.muted ? " muted" : "")
}

usage :: proc() -> ! {
	fmt.eprintln("使い方: ame-uzume [set <0-100 | +N | -N> | mute [on|off] | restore | watch]")
	os.exit(2)
}

watched: Level
changed: bool

on_event :: proc "c" (_: rawptr, ev: u32, _: u32, _: rawptr) {
	// 種類(下位 4 ビット): 0 = シンク、7 = サーバ(既定の出力が変わった)
	f := ev & 0xF
	if f == 0 || f == 7 do changed = true
}

main :: proc() {
	args := os.args[1:]
	cmd := len(args) > 0 ? args[0] : "get"
	switch cmd {
	case "get", "set", "mute", "restore", "watch":
	case:
		usage()
	}
	if (cmd == "get" || cmd == "restore" || cmd == "watch") && len(args) > 1 do usage()
	if cmd == "set" && len(args) != 2 do usage()
	if cmd == "mute" && len(args) > 2 do usage()
	if !connect() {
		fmt.eprintln("ame-uzume: 音の口(PulseAudio / pipewire-pulse)につながりません")
		os.exit(1)
	}
	cur := read()
	if !cur.known {
		fmt.eprintln("ame-uzume: 既定の出力が見つかりません")
		os.exit(1)
	}
	switch cmd {
	case "get":
		print_level(cur)
	case "set":
		p := target(args[1], cur.pct)
		if p < 0 do usage()
		if p != cur.pct && !set_pct(cur, p) do os.exit(1)
		save({true, p, cur.muted, cur.channels})
	case "mute":
		m := !cur.muted
		if len(args) == 2 {
			switch args[1] {
			case "on":
				m = true
			case "off":
				m = false
			case "toggle":
			case:
				usage()
			}
		}
		if m != cur.muted && !set_mute(m) do os.exit(1)
		save({true, cur.pct, m, cur.channels})
	case "restore":
		data, rerr := os.read_entire_file(state_path(), context.temp_allocator)
		if rerr != nil do return // 覚えていなければ何もしない
		f := strings.fields(strings.trim_space(string(data)), context.temp_allocator)
		if len(f) != 2 do return
		p, ok1 := strconv.parse_int(f[0], 10)
		if !ok1 || p < 0 || p > 100 do return
		if p != cur.pct && !set_pct(cur, p) do os.exit(1)
		if (f[1] == "1") != cur.muted && !set_mute(f[1] == "1") do os.exit(1)
	case "watch":
		print_level(cur)
		watched = cur
		pa.set_subscribe_callback(ctx, on_event, nil)
		// 購読: シンク(0x1)とサーバ(0x80)
		wait(pa.subscribe(ctx, 0x1 | 0x80, nil, nil))
		for {
			if pa.mainloop_iterate(ml, 1, nil) < 0 do os.exit(1) // 音の口が落ちた
			if !changed do continue
			changed = false
			l := read()
			if l.known && (l.pct != watched.pct || l.muted != watched.muted) {
				watched = l
				print_level(l)
			}
		}
	}
}
