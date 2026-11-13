// 音のスペクトラム(メディアの波形)。cava の代わり。小さな道具 ame-spectrum(odin/ame-spectrum)が使う。
// anim.odin と同じ制約: proc "c"、スライス・アロケータ・libm を使わない(四則演算だけ)。
// sin / cos の表・窓関数・帯域の区切りは呼ぶ側(ame-spectrum)が一度だけ作って渡す。
package anim

// 基数 2 の FFT(その場で計算)。re / im は長さ n(2 のべき)。
// tw は「回転子」の表: tw[2k] = cos(-2πk/n), tw[2k+1] = sin(-2πk/n)(k < n/2)
fft_inplace :: proc "c" (re: [^]f32, im: [^]f32, n: i32, tw: [^]f32) {
	// ビット反転の並べ替え
	j: i32 = 0
	for i: i32 = 1; i < n; i += 1 {
		bit := n >> 1
		for j & bit != 0 {
			j ~= bit
			bit >>= 1
		}
		j ~= bit
		if i < j {
			tr := re[i]; re[i] = re[j]; re[j] = tr
			ti := im[i]; im[i] = im[j]; im[j] = ti
		}
	}
	// バタフライ
	size: i32 = 2
	for size <= n {
		half := size >> 1
		step := n / size
		for start: i32 = 0; start < n; start += size {
			for k: i32 = 0; k < half; k += 1 {
				c := tw[2 * k * step]
				s := tw[2 * k * step + 1]
				a := start + k
				b := a + half
				xr := re[b] * c - im[b] * s
				xi := re[b] * s + im[b] * c
				re[b] = re[a] - xr
				im[b] = im[a] - xi
				re[a] += xr
				im[a] += xi
			}
		}
		size <<= 1
	}
}

// samples(n 個)に窓をかけて FFT し、帯域ごとのパワー(振幅の 2 乗の平均)を bands に書く。
// edges は帯域の区切り(FFT のビン番号、nbands + 1 個)。work は 2n 個の作業領域。
@(export, link_name = "ame_spectrum")
spectrum :: proc "c" (samples: [^]f32, n: i32, window: [^]f32, tw: [^]f32, work: [^]f32, edges: [^]i32, nbands: i32, bands: [^]f32) {
	re := work
	im := work[n:]
	for i: i32 = 0; i < n; i += 1 {
		re[i] = samples[i] * window[i]
		im[i] = 0
	}
	fft_inplace(re, im, n, tw)
	for b: i32 = 0; b < nbands; b += 1 {
		lo := edges[b]
		hi := edges[b + 1]
		if hi <= lo do hi = lo + 1
		sum: f32 = 0
		for k := lo; k < hi; k += 1 {
			sum += re[k] * re[k] + im[k] * im[k]
		}
		bands[b] = sum / f32(hi - lo)
	}
}
