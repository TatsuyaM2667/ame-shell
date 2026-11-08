// 画像の縮小(アイコン・アルバムアート)。anim.odin と同じ制約: proc "c"、スライス・アロケータ・libm を使わない。
package anim

// src の [sx0, sx0 + dw·scale) × [sy0, sy0 + dh·scale) を、dst の (ox, oy) から dw × dh 点に縮める。
// 各点は覆う範囲の画素を、はみ出した端は重なった面積の割合で平均する(面積平均)。
// 乗算済みアルファで平均するので、透明な画素の色が縁ににじまない。
// tmp は f32 で sh·dw·4 個。dst の 1 行は ostride 点。
@(export, link_name = "ame_scale_rgba")
scale_rgba :: proc "c" (src: [^]u8, sw: i32, sh: i32, dst: [^]u8, ostride: i32, ox: i32, oy: i32, dw: i32, dh: i32, sx0: f32, sy0: f32, scale: f32, tmp: [^]f32) {
	// 1. 横: 各行を dw 点に(色 × アルファ、アルファ を、覆う幅で平均)。
	// 丸ごと覆う画素は重み 1 なので整数で足し、両端の欠けた画素だけ割合を掛ける
	for y in 0 ..< sh {
		row := y * sw * 4
		for x in 0 ..< dw {
			a := sx0 + f32(x) * scale
			b := a + scale
			if a < 0 {a = 0}
			if b > f32(sw) {b = f32(sw)}
			c0, c1, c2, al, ws: f32
			i0 := i32(a) // 左端の画素
			i1 := i32(b) // 右端の画素(b が整数ならその画素は含まない)
			if i1 >= sw {i1 = sw}
			if i0 == i1 || i0 + 1 > i1 {
				// 1 画素の中に収まる
				if i0 < sw {
					w := b - a
					p := row + i0 * 4
					pa := f32(src[p + 3]) * w
					c0 = f32(src[p + 0]) * pa
					c1 = f32(src[p + 1]) * pa
					c2 = f32(src[p + 2]) * pa
					al = pa
					ws = w
				}
			} else {
				// 左端
				w := f32(i0 + 1) - a
				p := row + i0 * 4
				pa := f32(src[p + 3]) * w
				c0 = f32(src[p + 0]) * pa
				c1 = f32(src[p + 1]) * pa
				c2 = f32(src[p + 2]) * pa
				al = pa
				ws = w
				// 中: 重み 1
				s0, s1, s2, sa: u64
				for i in i0 + 1 ..< i1 {
					q := row + i * 4
					qa := u32(src[q + 3])
					s0 += u64(u32(src[q + 0]) * qa)
					s1 += u64(u32(src[q + 1]) * qa)
					s2 += u64(u32(src[q + 2]) * qa)
					sa += u64(qa)
				}
				c0 += f32(s0)
				c1 += f32(s1)
				c2 += f32(s2)
				al += f32(sa)
				ws += f32(i1 - i0 - 1)
				// 右端
				if i1 < sw {
					w = b - f32(i1)
					if w > 0 {
						p = row + i1 * 4
						pa = f32(src[p + 3]) * w
						c0 += f32(src[p + 0]) * pa
						c1 += f32(src[p + 1]) * pa
						c2 += f32(src[p + 2]) * pa
						al += pa
						ws += w
					}
				}
			}
			if ws <= 0 {ws = 1}
			t := (y * dw + x) * 4
			tmp[t + 0] = c0 / ws
			tmp[t + 1] = c1 / ws
			tmp[t + 2] = c2 / ws
			tmp[t + 3] = al / ws
		}
	}
	// 2. 縦: 同じように縮め、乗算済みを戻す
	for y in 0 ..< dh {
		a := sy0 + f32(y) * scale
		b := a + scale
		if a < 0 {a = 0}
		if b > f32(sh) {b = f32(sh)}
		for x in 0 ..< dw {
			c0, c1, c2, al, ws: f32
			for j := i32(a); j < sh && f32(j) < b; j += 1 {
				w := min(b, f32(j + 1)) - max(a, f32(j))
				if w <= 0 {continue}
				t := (j * dw + x) * 4
				c0 += tmp[t + 0] * w
				c1 += tmp[t + 1] * w
				c2 += tmp[t + 2] * w
				al += tmp[t + 3] * w
				ws += w
			}
			o := ((y + oy) * ostride + (x + ox)) * 4
			if al > 0 {
				dst[o + 0] = u8(min(c0 / al, 255) + 0.5)
				dst[o + 1] = u8(min(c1 / al, 255) + 0.5)
				dst[o + 2] = u8(min(c2 / al, 255) + 0.5)
			}
			if ws <= 0 {ws = 1}
			dst[o + 3] = u8(min(al / ws, 255) + 0.5)
		}
	}
}
