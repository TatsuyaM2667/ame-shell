// ame-shell アニメーション/計算コア(Odin)。
//
// なぜ Odin か: 数値処理を書きやすく、C ABI でそのまま Zig 本体にリンクでき、
// 同じソースを freestanding_wasm32 にもビルドできる(WASMウィジェットと共有するため)。
//
// 制約: ランタイム(アロケータ/コンテキスト)に依存しないよう、全エクスポートは
// `proc "c"` で、スライス・動的配列・libm 関数を使わない。四則演算だけで書くことで
// ネイティブ(musl/glibc)と wasm32 の両方でシンボル未解決なくリンクできる。
package anim

// Zig 側の `extern struct Spring` とレイアウトを一致させること。
Spring :: struct {
	x:        f32, // 現在値
	v:        f32, // 速度(単位/秒)
	target:   f32, // 目標値
	response: f32, // 応答時間(秒)。小さいほど速い。≒ 1周期の長さ
	damping:  f32, // 減衰比 ζ。1 = 臨界減衰(行き過ぎない)、<1 = 弾む
}

// 積分の最大刻み。semi-implicit Euler は h·ω が小さければ安定する。
// response=0.08s (ω≈78) でも h=1ms なら h·ω≈0.08 で十分安定。
MAX_STEP :: f32(0.001)
// 静止判定の閾値。UI はピクセル単位なので 0.01px/0.01px/s で十分見えない。
EPS_X :: f32(0.005)
EPS_V :: f32(0.01)

// 1つのスプリングを dt 秒進める。まだ動いていれば true。
//
// 目標(target)が途中で変わっても x と v をそのまま引き継ぐため、
// 速度が連続したまま新しい目標へ曲がっていく(「速度連続」の要件)。
@(export, link_name = "ame_spring_step")
spring_step :: proc "c" (s: ^Spring, dt: f32) -> b32 {
	if s.response <= 0 {
		s.x = s.target
		s.v = 0
		return false
	}
	// k = ω², c = 2ζω(質量1)。ω = 2π / response。
	omega := f32(6.2831853) / s.response
	k := omega * omega
	c := 2 * s.damping * omega

	// フレーム落ちで dt が巨大になっても破綻しないよう上限を設ける。
	remaining := dt
	if remaining > 0.1 {remaining = 0.1}
	for remaining > 0 {
		h := remaining
		if h > MAX_STEP {h = MAX_STEP}
		a := -k * (s.x - s.target) - c * s.v
		s.v += a * h
		s.x += s.v * h
		remaining -= h
	}

	dx := s.x - s.target
	if dx < 0 {dx = -dx}
	av := s.v
	if av < 0 {av = -av}
	if dx < EPS_X && av < EPS_V {
		s.x = s.target
		s.v = 0
		return false
	}
	return true
}

// 配列をまとめて進め、動いている個数を返す。フレームごとに呼ぶ。
@(export, link_name = "ame_springs_step")
springs_step :: proc "c" (arr: [^]Spring, count: i32, dt: f32) -> i32 {
	active: i32 = 0
	for i in 0 ..< count {
		if spring_step(&arr[i], dt) {active += 1}
	}
	return active
}

// ---------------------------------------------------------------------------
// ファジーマッチ(ランチャー用)
//
// fzf 系の考え方を簡略化: パターンの各文字が順に(飛び飛びでも)現れれば一致。
// スコアは「連続一致」「単語の先頭」「文字列の先頭」を加点し、間の飛びを減点。
// UTF-8 はバイト単位で比較する(マルチバイト文字は完全一致でのみ当たる)ので、
// 日本語名も部分一致で検索できる。ASCII のみ大文字小文字を無視。
// 不一致は -1。
// ---------------------------------------------------------------------------

lower :: #force_inline proc "c" (b: u8) -> u8 {
	if b >= 'A' && b <= 'Z' {return b + 32}
	return b
}

is_sep :: #force_inline proc "c" (b: u8) -> bool {
	return b == ' ' || b == '-' || b == '_' || b == '.' || b == '/'
}

@(export, link_name = "ame_fuzzy_score")
fuzzy_score :: proc "c" (pat: [^]u8, pat_len: i32, text: [^]u8, text_len: i32) -> i32 {
	if pat_len == 0 {return 0}
	score: i32 = 0
	pi: i32 = 0
	last_match: i32 = -2
	first_match: i32 = -1
	for ti in 0 ..< text_len {
		if pi >= pat_len {break}
		tc := lower(text[ti])
		if tc != lower(pat[pi]) {continue}
		bonus: i32 = 10
		if ti == 0 {
			bonus += 30
		} else if is_sep(text[ti - 1]) {
			bonus += 20
		} else if text[ti] >= 'A' &&
		   text[ti] <= 'Z' &&
		   text[ti - 1] >= 'a' &&
		   text[ti - 1] <= 'z' {
			bonus += 15 // camelCase の境界
		}
		if last_match == ti - 1 {
			bonus += 18 // 連続一致を強く優遇
		} else if last_match >= 0 {
			gap := ti - last_match - 1
			if gap > 8 {gap = 8}
			bonus -= gap
		}
		if first_match < 0 {first_match = ti}
		score += bonus
		last_match = ti
		pi += 1
	}
	if pi < pat_len {return -1}
	// 早く始まり、短い名前ほど少し上に。
	fm := first_match
	if fm > 20 {fm = 20}
	score -= fm
	tl := text_len
	if tl > 60 {tl = 60}
	score -= tl / 6
	return score
}

// ---------------------------------------------------------------------------
// 主色抽出(アルバムアート → テーマ色)
//
// RGBA8 画素を 4bit/チャネルの 4096 ビンヒストグラムに入れ、
// 「出現数 × 彩度」が最大のビンの平均色を返す。灰色・黒・白を避けて
// 印象的な色を選ぶため彩度で重み付けする。作業領域は呼び出し側が用意
// (4096 * 4 個の u32)し、Odin 側でメモリ確保しない。
// 戻り値: 0xRRGGBB
// ---------------------------------------------------------------------------

@(export, link_name = "ame_dominant_color")
dominant_color :: proc "c" (rgba: [^]u8, pixel_count: i32, stride_px: i32, work: [^]u32) -> u32 {
	for i in 0 ..< 4096 * 4 {work[i] = 0}
	step := stride_px
	if step < 1 {step = 1}
	for i: i32 = 0; i < pixel_count; i += step {
		r := u32(rgba[i * 4 + 0])
		g := u32(rgba[i * 4 + 1])
		b := u32(rgba[i * 4 + 2])
		a := u32(rgba[i * 4 + 3])
		if a < 128 {continue}
		bin := ((r >> 4) << 8) | ((g >> 4) << 4) | (b >> 4)
		work[bin * 4 + 0] += 1
		work[bin * 4 + 1] += r
		work[bin * 4 + 2] += g
		work[bin * 4 + 3] += b
	}
	best: u32 = 0
	best_w: f32 = -1
	for bin in 0 ..< u32(4096) {
		n := work[bin * 4]
		if n == 0 {continue}
		r := f32(work[bin * 4 + 1]) / f32(n)
		g := f32(work[bin * 4 + 2]) / f32(n)
		b := f32(work[bin * 4 + 3]) / f32(n)
		mx := max(r, max(g, b))
		mn := min(r, min(g, b))
		sat: f32 = 0
		if mx > 0 {sat = (mx - mn) / mx}
		// 暗すぎ/明るすぎは配色に向かないので減点。
		lum_pen: f32 = 1
		if mx < 40 {lum_pen = 0.2}
		if mn > 230 {lum_pen = 0.3}
		w := f32(n) * (0.15 + sat * sat) * lum_pen
		if w > best_w {
			best_w = w
			best = (u32(r) << 16) | (u32(g) << 8) | u32(b)
		}
	}
	if best_w < 0 {return 0x6aa8ff} 	// 画像が空なら既定の青
	return best
}
