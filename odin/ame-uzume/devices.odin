// ame-uzume の出力先・入力先(pactl list / set-default-* / move-* の代わり)。
//
//   ame-uzume list sinks|sources        1 行に 1 つ「名前<TAB>説明<TAB>既定なら *」(モニターは除く)
//   ame-uzume use sink|source 名前       既定にし、流れている音(録っている音)もそこへ移す
package main

import "core:dynlib"
import "core:fmt"
import "core:strings"

// pa_sink_info / pa_source_info の前の方(name・index・description は同じ並び)
Dev_Info :: struct {
	name:        cstring,
	index:       u32,
	description: cstring,
}
// pa_server_info の前の方(既定の出力・入力の名前まで)
Server_Info :: struct {
	user_name, host_name, server_version, server_name: cstring,
	spec:                                              Sample_Spec,
	default_sink_name:                                 cstring,
	default_source_name:                               cstring,
}
// pa_sink_input_info / pa_source_output_info は先頭が index
Stream_Info :: struct {
	index: u32,
}

Dev_Cb :: proc "c" (ctx: rawptr, info: ^Dev_Info, eol: i32, ud: rawptr)
Server_Cb :: proc "c" (ctx: rawptr, info: ^Server_Info, ud: rawptr)
Stream_Cb :: proc "c" (ctx: rawptr, info: ^Stream_Info, eol: i32, ud: rawptr)

Pad :: struct {
	get_sink_list:      proc "c" (ctx: rawptr, cb: Dev_Cb, ud: rawptr) -> rawptr,
	get_source_list:    proc "c" (ctx: rawptr, cb: Dev_Cb, ud: rawptr) -> rawptr,
	get_server_info:    proc "c" (ctx: rawptr, cb: Server_Cb, ud: rawptr) -> rawptr,
	set_default_sink:   proc "c" (ctx: rawptr, name: cstring, cb: Ok_Cb, ud: rawptr) -> rawptr,
	set_default_source: proc "c" (ctx: rawptr, name: cstring, cb: Ok_Cb, ud: rawptr) -> rawptr,
	get_sink_inputs:    proc "c" (ctx: rawptr, cb: Stream_Cb, ud: rawptr) -> rawptr,
	get_source_outputs: proc "c" (ctx: rawptr, cb: Stream_Cb, ud: rawptr) -> rawptr,
	move_sink_input:    proc "c" (ctx: rawptr, idx: u32, name: cstring, cb: Ok_Cb, ud: rawptr) -> rawptr,
	move_source_output: proc "c" (ctx: rawptr, idx: u32, name: cstring, cb: Ok_Cb, ud: rawptr) -> rawptr,
}
pad: Pad

load_devices :: proc() -> bool {
	lib, ok := dynlib.load_library("libpulse.so.0")
	if !ok do lib, ok = dynlib.load_library("libpulse.so")
	if !ok do return false
	sym :: proc(lib: dynlib.Library, name: string, dst: ^$T) -> bool {
		p, found := dynlib.symbol_address(lib, name)
		if found do dst^ = cast(T)p
		return found
	}
	return(
		sym(lib, "pa_context_get_sink_info_list", &pad.get_sink_list) &&
		sym(lib, "pa_context_get_source_info_list", &pad.get_source_list) &&
		sym(lib, "pa_context_get_server_info", &pad.get_server_info) &&
		sym(lib, "pa_context_set_default_sink", &pad.set_default_sink) &&
		sym(lib, "pa_context_set_default_source", &pad.set_default_source) &&
		sym(lib, "pa_context_get_sink_input_info_list", &pad.get_sink_inputs) &&
		sym(lib, "pa_context_get_source_output_info_list", &pad.get_source_outputs) &&
		sym(lib, "pa_context_move_sink_input_by_name", &pad.move_sink_input) &&
		sym(lib, "pa_context_move_source_output_by_name", &pad.move_source_output) \
	)
}

MAX_DEVS :: 32
Dev :: struct {
	name: [256]u8,
	name_len: int,
	desc: [256]u8,
	desc_len: int,
}
Devs :: struct {
	d: [MAX_DEVS]Dev,
	n: int,
}

copy_c :: proc "contextless" (dst: []u8, s: cstring) -> int {
	if s == nil do return 0
	p := ([^]u8)(s)
	n := 0
	for n < len(dst) && p[n] != 0 {
		// タブと改行は区切りに使うので空白に
		dst[n] = p[n] == '\t' || p[n] == '\n' ? ' ' : p[n]
		n += 1
	}
	return n
}

on_dev :: proc "c" (_: rawptr, info: ^Dev_Info, eol: i32, ud: rawptr) {
	if eol != 0 || info == nil do return
	l := cast(^Devs)ud
	if l.n >= MAX_DEVS do return
	d := &l.d[l.n]
	d.name_len = copy_c(d.name[:], info.name)
	d.desc_len = copy_c(d.desc[:], info.description)
	l.n += 1
}

Defaults :: struct {
	sink:      [256]u8,
	sink_len:  int,
	src:       [256]u8,
	src_len:   int,
}

on_server :: proc "c" (_: rawptr, info: ^Server_Info, ud: rawptr) {
	if info == nil do return
	d := cast(^Defaults)ud
	d.sink_len = copy_c(d.sink[:], info.default_sink_name)
	d.src_len = copy_c(d.src[:], info.default_source_name)
}

Streams :: struct {
	idx: [64]u32,
	n:   int,
}

on_stream :: proc "c" (_: rawptr, info: ^Stream_Info, eol: i32, ud: rawptr) {
	if eol != 0 || info == nil do return
	s := cast(^Streams)ud
	if s.n < len(s.idx) {
		s.idx[s.n] = info.index
		s.n += 1
	}
}

/// 一覧の 1 行(モニターは除く)。既定なら 3 つ目に *
format_dev :: proc(d: ^Dev, default_name: string) -> (line: string, keep: bool) {
	name := string(d.name[:d.name_len])
	if strings.has_suffix(name, ".monitor") do return "", false
	mark := name == default_name ? "*" : ""
	return fmt.tprintf("%s\t%s\t%s", name, string(d.desc[:d.desc_len]), mark), true
}

devices_list :: proc(sources: bool) -> bool {
	l: Devs
	if !wait(sources ? pad.get_source_list(ctx, on_dev, &l) : pad.get_sink_list(ctx, on_dev, &l)) do return false
	defs: Defaults
	wait(pad.get_server_info(ctx, on_server, &defs))
	def := sources ? string(defs.src[:defs.src_len]) : string(defs.sink[:defs.sink_len])
	for i in 0 ..< l.n {
		if line, keep := format_dev(&l.d[i], def); keep do fmt.println(line)
	}
	return true
}

devices_use :: proc(sources: bool, name: string) -> bool {
	cname := strings.clone_to_cstring(name, context.temp_allocator)
	done := false
	if !wait(sources ? pad.set_default_source(ctx, cname, ok_flag, &done) : pad.set_default_sink(ctx, cname, ok_flag, &done)) || !done do return false
	// 流れている音(録っている音)もそこへ移す。移せないもの(固定のもの)は飛ばす
	s: Streams
	wait(sources ? pad.get_source_outputs(ctx, on_stream, &s) : pad.get_sink_inputs(ctx, on_stream, &s))
	for i in 0 ..< s.n {
		moved := false
		wait(sources ? pad.move_source_output(ctx, s.idx[i], cname, ok_flag, &moved) : pad.move_sink_input(ctx, s.idx[i], cname, ok_flag, &moved))
	}
	return true
}

// ---------------- 音のカード(Bluetooth のイヤホンを高音質 A2DP にするときに使う) ----------------
//   ame-uzume list cards              1 行に 1 つ、カードの名前
//   ame-uzume profile カード プロファイル  カードのプロファイルを変える(例: bluez_card.XX a2dp-sink)

// pa_card_info の前の方(index・name)
Card_Info :: struct {
	index: u32,
	name:  cstring,
}
Card_Cb :: proc "c" (ctx: rawptr, info: ^Card_Info, eol: i32, ud: rawptr)

Pac :: struct {
	get_card_list:    proc "c" (ctx: rawptr, cb: Card_Cb, ud: rawptr) -> rawptr,
	set_card_profile: proc "c" (ctx: rawptr, card: cstring, profile: cstring, cb: Ok_Cb, ud: rawptr) -> rawptr,
}
pac: Pac

load_cards :: proc() -> bool {
	lib, ok := dynlib.load_library("libpulse.so.0")
	if !ok do lib, ok = dynlib.load_library("libpulse.so")
	if !ok do return false
	p1, ok1 := dynlib.symbol_address(lib, "pa_context_get_card_info_list")
	p2, ok2 := dynlib.symbol_address(lib, "pa_context_set_card_profile_by_name")
	pac.get_card_list = auto_cast p1
	pac.set_card_profile = auto_cast p2
	return ok1 && ok2
}

on_card :: proc "c" (_: rawptr, info: ^Card_Info, eol: i32, ud: rawptr) {
	if eol != 0 || info == nil do return
	l := cast(^Devs)ud
	if l.n >= MAX_DEVS do return
	l.d[l.n].name_len = copy_c(l.d[l.n].name[:], info.name)
	l.n += 1
}

cards_list :: proc() -> bool {
	l: Devs
	if !wait(pac.get_card_list(ctx, on_card, &l)) do return false
	for i in 0 ..< l.n do fmt.println(string(l.d[i].name[:l.d[i].name_len]))
	return true
}

card_profile :: proc(card, profile: string) -> bool {
	done := false
	c1 := strings.clone_to_cstring(card, context.temp_allocator)
	c2 := strings.clone_to_cstring(profile, context.temp_allocator)
	return wait(pac.set_card_profile(ctx, c1, c2, ok_flag, &done)) && done
}
