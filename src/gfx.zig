// EGL + GLES3 による 2D 専用レンダラ。
//
// 設計:
//  * EGLContext は1つだけ作り、全サーフェス(バー、壁紙、ランチャー…)で共有する。
//    グリフアトラス・壁紙のブラー済みテクスチャをそのまま全パネルで使えるため。
//  * UI は「インスタンス化した四角形」1種類だけを描く。形状(角丸矩形・影・ガラス・
//    SDF文字・円弧・画像)はフラグメントシェーダ内の SDF で決めるので、1フレームの
//    描画がほぼ1回のドローコールで済む。
//  * ガラス: シェル自身が壁紙を描くので、壁紙を縮小 → dual Kawase ブラーした
//    テクスチャを持っておき、パネルは「自分の真後ろの位置」をサンプルする。縁では
//    SDF の法線方向に UV をずらして屈折風に歪ませ、縁のハイライト・ノイズ・スパークルを足す。
const std = @import("std");
const c = @import("c.zig");
const textmod = @import("text.zig");
const Color = @import("anim.zig").Color;

// ---------------------------------------------------------------------------
// シェーダ
// ---------------------------------------------------------------------------

const ui_vs =
    \\#version 300 es
    \\layout(location=0) in vec2 a_corner;
    \\layout(location=1) in vec4 a_rect;
    \\layout(location=2) in vec4 a_c0;
    \\layout(location=3) in vec4 a_c1;
    \\layout(location=4) in vec4 a_c2;
    \\layout(location=5) in vec4 a_p0;
    \\layout(location=6) in vec4 a_p1;
    \\layout(location=7) in vec4 a_clip;
    \\uniform vec2 u_size;
    \\out vec2 v_p; out vec2 v_frag; out vec2 v_uv; out vec2 v_l01;
    \\flat out vec2 v_half; flat out vec4 v_c0; flat out vec4 v_c1; flat out vec4 v_c2;
    \\flat out vec4 v_p0; flat out vec4 v_p1; flat out vec4 v_clip;
    \\void main(){
    \\  float kind = a_p0.y;
    \\  // 影・発光は矩形の外側まで描くので四角形を広げる。文字は SDF の余白内で完結。
    \\  float pad = kind == 1.0 ? a_p0.w * 1.6 + 2.0 : ((kind == 3.0 || kind == 7.0) ? 0.0 : 1.5);
    \\  vec2 half_ = a_rect.zw * 0.5;
    \\  vec2 center = a_rect.xy + half_;
    \\  vec2 lp = (a_corner * 2.0 - 1.0) * (half_ + pad);
    \\  vec2 pos = center + lp;
    \\  v_p = lp; v_frag = pos; v_half = half_;
    \\  v_l01 = lp / max(half_, vec2(0.001)) * 0.5 + 0.5;
    \\  // 7 = 縦書き(時計回りに 90° 回したグリフ): 画面の下方向がグリフの右方向になる
    \\  v_uv = kind == 3.0 ? mix(a_p1.xy, a_p1.zw, a_corner) : (kind == 7.0 ? mix(a_p1.xy, a_p1.zw, vec2(a_corner.y, 1.0 - a_corner.x)) : v_l01);
    \\  v_c0 = a_c0; v_c1 = a_c1; v_c2 = a_c2; v_p0 = a_p0; v_p1 = a_p1; v_clip = a_clip;
    \\  gl_Position = vec4(pos.x / u_size.x * 2.0 - 1.0, 1.0 - pos.y / u_size.y * 2.0, 0.0, 1.0);
    \\}
;

const ui_fs =
    \\#version 300 es
    \\precision highp float;
    \\in vec2 v_p; in vec2 v_frag; in vec2 v_uv; in vec2 v_l01;
    \\flat in vec2 v_half; flat in vec4 v_c0; flat in vec4 v_c1; flat in vec4 v_c2;
    \\flat in vec4 v_p0; flat in vec4 v_p1; flat in vec4 v_clip;
    \\uniform sampler2D u_atlas;
    \\uniform sampler2D u_blur;
    \\uniform sampler2D u_img;
    \\uniform vec2 u_origin;   // このサーフェスの出力上の位置(論理px)
    \\uniform vec2 u_output;   // 出力の論理サイズ
    \\uniform float u_scale;   // バッファスケール
    \\uniform float u_time;
    \\out vec4 o;
    \\float sdBox(vec2 p, vec2 b, float r){ r = min(r, min(b.x, b.y)); vec2 q = abs(p) - b + r; return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r; }
    \\float hash(vec2 p){ p = fract(p * vec2(123.34, 456.21)); p += dot(p, p + 45.32); return fract(p.x * p.y); }
    \\vec4 pm(vec4 c){ return vec4(c.rgb * c.a, c.a); }
    \\void main(){
    \\  if (v_clip.z > 0.0) {
    \\    vec2 q = v_frag - v_clip.xy;
    \\    if (q.x < 0.0 || q.y < 0.0 || q.x > v_clip.z || q.y > v_clip.w) discard;
    \\  }
    \\  float kind = v_p0.y;
    \\  float r = v_p0.x;
    \\  float px = 1.0 / u_scale;
    \\  if (kind == 0.0) {            // 角丸矩形(縦グラデーション + 縁取り)
    \\    float d = sdBox(v_p, v_half, r);
    \\    float a = clamp(0.5 - d / px, 0.0, 1.0);
    \\    vec4 fill = mix(v_c0, v_c1, clamp(v_l01.y, 0.0, 1.0));
    \\    float bw = v_p0.z;
    \\    if (bw > 0.0) {
    \\      float inner = clamp(0.5 - (d + bw) / px, 0.0, 1.0);
    \\      fill = mix(v_c2, fill, inner);
    \\    }
    \\    o = pm(fill) * a;
    \\  } else if (kind == 1.0) {     // ソフトシャドウ(ガウスの近似)
    \\    float s = max(v_p0.w, 0.5);
    \\    float d = sdBox(v_p, v_half, r);
    \\    float a = 1.0 - smoothstep(-s, s * 1.6, d);
    \\    o = pm(v_c0) * a * a;
    \\  } else if (kind == 2.0) {     // ガラス
    \\    float d = sdBox(v_p, v_half, r);
    \\    float mask = clamp(0.5 - d / px, 0.0, 1.0);
    \\    if (mask <= 0.0) discard;
    \\    vec2 e = vec2(0.75, 0.0);
    \\    vec2 n = normalize(vec2(sdBox(v_p + e.xy, v_half, r) - sdBox(v_p - e.xy, v_half, r),
    \\                            sdBox(v_p + e.yx, v_half, r) - sdBox(v_p - e.yx, v_half, r)) + 1e-5);
    \\    float rim = min(16.0, min(v_half.x, v_half.y));
    \\    float edge = 1.0 - smoothstep(0.0, rim, -d);           // 縁で1、中心で0
    \\    float refr = v_p1.x;                                    // 屈折の強さ(px)
    \\    vec2 off = -n * edge * edge * refr;
    \\    vec2 sp = u_origin + v_frag + off;
    \\    // 壁紙 FBO は GL 流儀で下が v=0、UI 座標は上が y=0 なので反転する。
    \\    vec2 uv = vec2(sp.x / u_output.x, 1.0 - sp.y / u_output.y);
    \\    // 縁でわずかに色収差を付けてガラスの厚みを出す
    \\    vec2 ca = vec2(n.x, -n.y) * edge * 1.5 / u_output;
    \\    vec3 bg = vec3(texture(u_blur, uv + ca).r, texture(u_blur, uv).g, texture(u_blur, uv - ca).b);
    \\    vec3 col = mix(bg, v_c0.rgb, v_c0.a);                   // 色付け
    \\    col += v_c1.rgb * v_c1.a * (1.0 - v_l01.y);              // 上からの柔らかい光
    \\    col += v_c2.rgb * edge * edge * 0.10;                    // 内側の発光
    \\    // 細い縁のハイライト。左上からの光源を想定し、向きで明るさを変える。
    \\    float line = clamp(1.0 - abs(d + 0.75) / (1.1 * px + 0.35), 0.0, 1.0);
    \\    float facing = 0.35 + 0.65 * max(0.0, dot(n, normalize(vec2(-0.55, -0.85))));
    \\    col = mix(col, v_c2.rgb, line * facing * v_c2.a);
    \\    // 微細なノイズ(バンディング防止と素材感)
    \\    col += (hash(gl_FragCoord.xy) - 0.5) * 0.03;
    \\    // スパークル: 28px 格子ごとに1点、ごく一部だけが瞬く
    \\    if (v_p1.z > 0.0) {
    \\      vec2 cell = floor((v_frag + u_origin) / 28.0);
    \\      float h = hash(cell);
    \\      if (h > 0.86) {
    \\        vec2 star = (cell + vec2(hash(cell + 7.1), hash(cell + 3.7))) * 28.0 - u_origin;
    \\        float dist = length(v_frag - star);
    \\        float tw = 0.5 + 0.5 * sin(u_time * (1.5 + h * 2.0) + h * 40.0);
    \\        col += vec3(0.8, 0.9, 1.0) * pow(max(0.0, 1.0 - dist / 1.6), 2.0) * tw * v_p1.z;
    \\      }
    \\    }
    \\    o = vec4(col, 1.0) * mask * v_p1.y;
    \\  } else if (kind == 3.0 || kind == 7.0) {     // SDF 文字(7 は縦)
    \\    float v = texture(u_atlas, v_uv).r;
    \\    float k = v_p0.z;           // 基準px → 画面px の倍率
    \\    float dist = (v - 0.5) * 2.0 * 6.0 * k + 0.15;  // 画面px単位の符号付き距離(内側が正)
    \\    float a = clamp(dist + 0.5, 0.0, 1.0);
    \\    vec4 col = pm(v_c0) * a;
    \\    if (v_p0.w > 0.0) {         // 発光
    \\      float g = clamp(1.0 + dist / v_p0.w, 0.0, 1.0);
    \\      col += pm(v_c2) * g * g * (1.0 - a);
    \\    }
    \\    o = col;
    \\  } else if (kind == 4.0) {     // 円弧プログレス(上から時計回り)
    \\    float R = v_half.x - v_p1.y * 0.5;
    \\    float ring = abs(length(v_p) - R) - v_p1.y * 0.5;
    \\    float a = clamp(0.5 - ring / px, 0.0, 1.0);
    \\    float ang = atan(v_p.x, -v_p.y) / 6.2831853;
    \\    ang = ang < 0.0 ? ang + 1.0 : ang;
    \\    float on = smoothstep(v_p1.x + 0.002, v_p1.x - 0.002, ang);
    \\    o = mix(pm(v_c1), pm(v_c0), on) * a;
    \\  } else if (kind == 9.0) {     // 斜めのカード(平行四辺形でくり抜いた画像。画像自体は歪めない)
    \\    float sk = v_c1.r;                                  // 傾き(x += sk * y)
    \\    vec2 q = vec2(v_p.x - sk * v_p.y, v_p.y);
    \\    vec2 hb = vec2(v_half.x - abs(sk) * v_half.y, v_half.y);
    \\    float d = sdBox(q, hb, r);
    \\    float a = clamp(0.5 - d / px, 0.0, 1.0);
    \\    if (a <= 0.0) discard;
    \\    vec4 t = texture(u_img, mix(v_p1.xy, v_p1.zw, v_l01));
    \\    vec3 col = t.rgb * v_c0.rgb;                        // c0.rgb で明るさ(非選択は暗く)
    \\    float bw = v_p0.z;
    \\    if (bw > 0.0) col = mix(col, v_c2.rgb, (1.0 - clamp(0.5 - (d + bw) / px, 0.0, 1.0)) * v_c2.a);
    \\    o = vec4(col, 1.0) * a * v_c0.a;
    \\  } else if (kind == 8.0) {     // 線分(両端が丸い)。p1 = 端点 a, b(矩形中心からの相対座標)
    \\    vec2 pa = v_p - v_p1.xy, ba = v_p1.zw - v_p1.xy;
    \\    float hh = clamp(dot(pa, ba) / max(dot(ba, ba), 1e-4), 0.0, 1.0);
    \\    float d = length(pa - ba * hh) - v_p0.z * 0.5;
    \\    o = pm(v_c0) * clamp(0.5 - d / px, 0.0, 1.0);
    \\  } else {                      // 画像(角丸マスク)
    \\    float d = sdBox(v_p, v_half, r);
    \\    float a = clamp(0.5 - d / px, 0.0, 1.0);
    \\    vec2 uv = mix(v_p1.xy, v_p1.zw, v_l01);
    \\    vec4 t = texture(u_img, uv);
    \\    o = vec4(t.rgb, 1.0) * t.a * a * v_c0.a;
    \\  }
    \\}
;

const fs_vs =
    \\#version 300 es
    \\out vec2 v_uv;
    \\void main(){
    \\  vec2 p = vec2((gl_VertexID << 1) & 2, gl_VertexID & 2);
    \\  v_uv = p;
    \\  gl_Position = vec4(p * 2.0 - 1.0, 0.0, 1.0);
    \\}
;

/// ライブ壁紙: mode 0=オーロラ, 1=雨(ボケ+雨筋), 2=画像。画像は波紋状のトランジション。
const wall_fs =
    \\#version 300 es
    \\precision highp float;
    \\in vec2 v_uv;
    \\uniform vec2 u_res;
    \\uniform float u_time;
    \\uniform int u_mode;
    \\uniform int u_prev_mode;
    \\uniform float u_mix;          // 0→1 で前の壁紙から現在の壁紙へ
    \\uniform sampler2D u_img;      // 現在の画像
    \\uniform sampler2D u_prev;     // 前の画像
    \\uniform vec2 u_img_size; uniform vec2 u_prev_size;
    \\uniform vec3 u_ca; uniform vec3 u_cb; uniform vec3 u_cc;
    \\uniform int u_trans;          // 0=波紋 1=円 2=斜めワイプ 3=短冊
    \\uniform vec2 u_origin;        // 円の中心(uv、下が 0)
    \\out vec4 o;
    \\float h21(vec2 p){ p = fract(p * vec2(233.34, 851.73)); p += dot(p, p + 23.45); return fract(p.x * p.y); }
    \\float noise(vec2 p){ vec2 i = floor(p), f = fract(p); f = f*f*(3.0-2.0*f);
    \\  return mix(mix(h21(i), h21(i+vec2(1,0)), f.x), mix(h21(i+vec2(0,1)), h21(i+vec2(1,1)), f.x), f.y); }
    \\float fbm(vec2 p){ float v = 0.0, a = 0.5; for (int i = 0; i < 5; i++){ v += a * noise(p); p = p * 2.03 + 17.1; a *= 0.5; } return v; }
    \\vec3 cover(sampler2D s, vec2 sz, vec2 uv){
    \\  float ra = u_res.x / u_res.y, ia = sz.x / max(sz.y, 1.0);
    \\  vec2 k = ra > ia ? vec2(1.0, ia / ra) : vec2(ra / ia, 1.0);
    \\  return texture(s, (uv - 0.5) * k + 0.5).rgb;
    \\}
    \\vec3 aurora(vec2 uv, float t){
    \\  vec3 col = mix(vec3(0.006, 0.012, 0.040), vec3(0.025, 0.05, 0.13), uv.y);
    \\  float ar = u_res.x / u_res.y;
    \\  vec2 p = vec2(uv.x * ar, uv.y);
    \\  // 星(先に描き、オーロラの光が上に重なる)。セル内のランダムな1点を丸く光らせる。
    \\  vec2 g = uv * u_res / 5.0;
    \\  vec2 id = floor(g);
    \\  float s = h21(id);
    \\  if (s > 0.975) {
    \\    vec2 sp = vec2(h21(id + 3.1), h21(id + 5.7));
    \\    float d = length(fract(g) - sp) * 5.0;
    \\    float tw = 0.6 + 0.4 * sin(t * (1.0 + s) * 1.7 + s * 90.0);
    \\    col += vec3(0.75, 0.85, 1.0) * smoothstep(1.3, 0.0, d) * tw * smoothstep(0.3, 0.9, uv.y) * (s - 0.975) * 30.0;
    \\  }
    \\  // カーテン状のオーロラ: 下端はくっきり、上へ長く消えていく。縦の光条は高周波の fbm。
    \\  for (int i = 0; i < 3; i++){
    \\    float fi = float(i);
    \\    float x = p.x * 0.8 + fi * 1.7;
    \\    float yc = 0.50 + 0.08 * fi + 0.22 * (fbm(vec2(x * 0.55 + t * 0.012 * (1.0 + fi), fi * 5.0)) - 0.5);
    \\    float d = uv.y - yc;
    \\    float curtain = d > 0.0 ? exp(-d * (4.0 + fi * 2.0)) : exp(-d * d * 700.0);
    \\    float rays = fbm(vec2(x * 11.0 + t * 0.04 * (1.0 + fi * 0.5), fi * 7.0 + uv.y * 0.5));
    \\    rays = pow(rays, 1.6) * 1.9;
    \\    vec3 c0 = i == 0 ? u_ca : (i == 1 ? u_cb : u_cc);
    \\    vec3 c1 = i == 0 ? u_cb : u_cc;
    \\    col += mix(c0, c1, clamp(d * 3.5, 0.0, 1.0)) * curtain * rays * (0.55 - 0.13 * fi);
    \\  }
    \\  // 地平線のかすかな照り返し
    \\  col += u_ca * 0.05 * exp(-uv.y * 7.0);
    \\  return col;
    \\}
    \\vec3 rain(vec2 uv, float t){
    \\  // 夜の街のボケ
    \\  vec3 col = mix(vec3(0.015, 0.03, 0.07), vec3(0.04, 0.08, 0.17), uv.y);
    \\  vec2 px = uv * u_res;
    \\  for (int l = 0; l < 3; l++){
    \\    float sz = 70.0 + 50.0 * float(l);
    \\    vec2 g = px / sz + vec2(float(l) * 7.3, t * 0.01 * float(l + 1));
    \\    vec2 id = floor(g); vec2 f = fract(g) - 0.5;
    \\    float h = h21(id + float(l) * 13.0);
    \\    vec2 o2 = vec2(h21(id + 1.7), h21(id + 9.2)) - 0.5;
    \\    // 円がセルの境界をはみ出すと四角く欠けるので、中心のずれ+半径 < 0.5 に収める
    \\    float d = length(f - o2 * 0.3);
    \\    float b = smoothstep(0.30, 0.23, d) * step(0.55, h) * (0.10 + 0.08 * sin(t * 0.7 + h * 30.0));
    \\    vec3 c = mix(u_ca, u_cb, h21(id + 4.4));
    \\    c = mix(c, u_cc, step(0.85, h));
    \\    col += c * b * (1.0 - 0.25 * float(l));
    \\  }
    \\  // 雨筋
    \\  for (int l = 0; l < 3; l++){
    \\    float fl = float(l);
    \\    float cols = 160.0 + fl * 90.0;
    \\    float x = uv.x * cols;
    \\    float id = floor(x);
    \\    float h = h21(vec2(id, fl));
    \\    float sp = 0.6 + h * 0.8 + fl * 0.3;
    \\    float y = fract(uv.y * (1.2 + fl * 0.4) + t * sp + h * 10.0);
    \\    float streak = smoothstep(0.0, 0.08, y) * smoothstep(0.16, 0.08, y);
    \\    float thin = smoothstep(0.5, 0.0, abs(fract(x) - 0.5) * (2.0 + fl));
    \\    col += vec3(0.55, 0.7, 1.0) * streak * thin * step(0.72, h) * (0.10 - fl * 0.02);
    \\  }
    \\  // 下の水たまりの波紋
    \\  float ripple = 0.0;
    \\  if (uv.y < 0.22){
    \\    vec2 g = vec2(uv.x * u_res.x / u_res.y * 5.0, uv.y * 16.0);
    \\    vec2 id = floor(g); vec2 f = fract(g) - 0.5;
    \\    float h = h21(id);
    \\    float ph = fract(t * 0.5 + h);
    \\    float r = length(f * vec2(1.0, 2.5));
    \\    ripple = smoothstep(0.04, 0.0, abs(r - ph * 0.5)) * (1.0 - ph) * step(0.6, h);
    \\    col += vec3(0.5, 0.7, 1.0) * ripple * 0.12 * (1.0 - uv.y / 0.22);
    \\  }
    \\  return col;
    \\}
    \\vec3 scene(int mode, vec2 uv, sampler2D s, vec2 sz){
    \\  if (mode == 0) return aurora(uv, u_time);
    \\  if (mode == 1) return rain(uv, u_time);
    \\  return cover(s, sz, vec2(uv.x, 1.0 - uv.y));
    \\}
    \\// 新しい壁紙: 少し拡大した状態から元の大きさへ落ち着く(着地感)
    \\vec3 sceneB(vec2 uv, float zoom, vec2 o){ return scene(u_mode, (uv - o) / zoom + o, u_img, u_img_size); }
    \\float ease(float t){ return t * t * (3.0 - 2.0 * t); }
    \\void main(){
    \\  vec2 uv = v_uv;
    \\  vec3 col;
    \\  float m = clamp(u_mix, 0.0, 1.0);
    \\  if (u_mix < 1.0) {
    \\    float ar = u_res.x / u_res.y;
    \\    float zoom = 1.0 + 0.10 * (1.0 - m) * (1.0 - m);
    \\    if (u_trans == 1) {
    \\      // 円: 選んだカードの位置から広がる。境界は光るリングで、その内側を少し屈折させる
    \\      vec2 o = u_origin;
    \\      vec2 d = (uv - o) * vec2(ar, 1.0);
    \\      float r = length(d);
    \\      float maxr = length(vec2(max(o.x, 1.0 - o.x) * ar, max(o.y, 1.0 - o.y)));
    \\      float front = ease(m) * (maxr + 0.08);
    \\      float band = exp(-pow((r - front) * 18.0, 2.0));
    \\      vec2 duv = uv - normalize(d + 1e-5) / vec2(ar, 1.0) * band * 0.03;
    \\      vec3 a = scene(u_prev_mode, duv, u_prev, u_prev_size) * (1.0 - 0.35 * m);
    \\      vec3 b = sceneB(duv, zoom, o);
    \\      col = mix(a, b, smoothstep(front + 0.006, front - 0.006, r)) + band * mix(vec3(0.6, 0.8, 1.0), u_ca, 0.4) * 0.55;
    \\    } else if (u_trans == 2) {
    \\      // 斜めのワイプ(ピッカーのカードと同じ傾き)。境目を光の筋が横切る
    \\      float sk = 0.35;
    \\      float x = uv.x * ar + (uv.y - 0.5) * sk;
    \\      float front = mix(-0.5 * sk - 0.12, ar + 0.5 * sk + 0.12, ease(m));
    \\      float streak = exp(-pow((x - front) * 22.0, 2.0));
    \\      vec2 duv = uv + vec2(streak * 0.02, 0.0);
    \\      vec3 a = scene(u_prev_mode, duv, u_prev, u_prev_size) * (1.0 - 0.3 * m);
    \\      vec3 b = sceneB(duv, zoom, vec2(0.0, 0.5));
    \\      col = mix(a, b, smoothstep(front + 0.03, front - 0.03, x)) + streak * vec3(0.7, 0.85, 1.0) * 0.6;
    \\    } else if (u_trans == 3) {
    \\      // 短冊: 斜めの帯ごとに時間差で、帯の中を左から右へ塗り替える
    \\      float sk = 0.35;
    \\      float n = 9.0;
    \\      float x = (uv.x * ar + (uv.y - 0.5) * sk + 0.5 * sk) / (ar + sk);
    \\      float id = floor(x * n);
    \\      float lt = ease(clamp((m - id / n * 0.55) / 0.45, 0.0, 1.0));
    \\      float fx = fract(x * n);
    \\      float show = smoothstep(lt + 0.03, lt - 0.03, fx);
    \\      float glow = exp(-pow((fx - lt) * 26.0, 2.0)) * (1.0 - lt) * step(0.001, lt);
    \\      vec3 a = scene(u_prev_mode, uv, u_prev, u_prev_size) * (1.0 - 0.3 * m);
    \\      vec3 b = sceneB(uv, zoom, vec2(0.5));
    \\      col = mix(a, b, show) + glow * vec3(0.7, 0.85, 1.0) * 0.5;
    \\    } else {
    \\      // 波紋: 中心から広がる。境界の帯だけ UV を歪ませて水面のように見せる
    \\      vec2 cuv = (uv - 0.5) * vec2(ar, 1.0);
    \\      float r = length(cuv);
    \\      float front = u_mix * 1.25;
    \\      float band = exp(-pow((r - front) * 14.0, 2.0));
    \\      vec2 duv = uv + normalize(cuv + 1e-5) * band * 0.025 / vec2(ar, 1.0);
    \\      vec3 a = scene(u_prev_mode, duv, u_prev, u_prev_size);
    \\      vec3 b = scene(u_mode, duv, u_img, u_img_size);
    \\      col = mix(b, a, smoothstep(front - 0.02, front + 0.02, r)) + band * vec3(0.25, 0.4, 0.6) * 0.25;
    \\    }
    \\  } else {
    \\    col = scene(u_mode, uv, u_img, u_img_size);
    \\  }
    \\  // 周辺減光 + ディザ
    \\  vec2 q = uv - 0.5;
    \\  col *= 1.0 - dot(q, q) * 0.45;
    \\  col += (h21(gl_FragCoord.xy + u_time) - 0.5) / 255.0;
    \\  o = vec4(col, 1.0);
    \\}
;

/// caelestia 風の「枠」: 画面の縁 + 縁から生える引き出し(ドロワー)を 1 つの SDF で描く。
/// 枠 = 「窓の穴(角丸矩形)」の外側。各ドロワーは縁に貼り付いた角丸矩形で、smooth-min で
/// 枠と融合させるので、付け根に凹の丸み(フィレット)ができ、伸びると「ニョキッ」と生えて見える。
const frame_fs =
    \\#version 300 es
    \\precision highp float;
    \\in vec2 v_uv;
    \\uniform vec2 u_size; uniform float u_scale; uniform vec2 u_output; uniform vec2 u_origin;
    \\uniform sampler2D u_blur; uniform float u_time;
    \\uniform vec4 u_hole; uniform float u_hole_r;
    \\uniform vec4 u_box[14]; uniform vec2 u_boxp[14]; uniform int u_n;
    \\uniform vec4 u_tint; uniform vec4 u_rim; uniform vec4 u_sheen; uniform float u_shadow; uniform float u_sparkle;
    \\out vec4 o;
    \\float sdBox(vec2 p, vec2 b, float r){ r = min(r, min(b.x, b.y)); vec2 q = abs(p) - b + r; return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r; }
    \\float smin(float a, float b, float k){ if (k <= 0.01) return min(a, b); float h = max(k - abs(a - b), 0.0) / k; return min(a, b) - h * h * k * 0.25; }
    \\float hash(vec2 p){ p = fract(p * vec2(123.34, 456.21)); p += dot(p, p + 45.32); return fract(p.x * p.y); }
    \\// 各ドロワーは「枠とだけ」なめらかに融合させ、ドロワー同士は普通の和集合にする
    \\//(連鎖的に smin すると、近くのドロワー同士が細い橋でつながってしまうため)
    \\float scene(vec2 p){
    \\  float fr = -sdBox(p - (u_hole.xy + u_hole.zw * 0.5), u_hole.zw * 0.5, u_hole_r);
    \\  float m = fr;
    \\  for (int i = 0; i < 14; i++) {
    \\    if (i >= u_n) break;
    \\    vec4 b = u_box[i];
    \\    m = min(m, smin(fr, sdBox(p - (b.xy + b.zw * 0.5), b.zw * 0.5, u_boxp[i].x), u_boxp[i].y));
    \\  }
    \\  return m;
    \\}
    \\void main(){
    \\  vec2 p = vec2(v_uv.x, 1.0 - v_uv.y) * u_size;
    \\  float m = scene(p);
    \\  float px = 1.0 / u_scale;
    \\  if (m > 36.0) discard;                       // 枠から遠い(窓の領域): 何も描かない
    \\  float a = clamp(0.5 - m / px, 0.0, 1.0);
    \\  float sh = u_shadow * exp(-max(m, 0.0) / 8.0) * (1.0 - a);   // 窓側に落ちる柔らかい影
    \\  if (a <= 0.0) { o = vec4(0.0, 0.005, 0.02, 1.0) * sh; return; }
    \\  vec2 e = vec2(0.75, 0.0);
    \\  vec2 n = normalize(vec2(scene(p + e.xy) - scene(p - e.xy), scene(p + e.yx) - scene(p - e.yx)) + 1e-5);
    \\  float edge = 1.0 - smoothstep(0.0, 14.0, -m);
    \\  vec2 sp = u_origin + p - n * edge * edge * 8.0;
    \\  vec2 uv = vec2(sp.x / u_output.x, 1.0 - sp.y / u_output.y);
    \\  vec3 bg = texture(u_blur, uv).rgb;
    \\  vec3 col = mix(bg, u_tint.rgb, u_tint.a);
    \\  col += u_sheen.rgb * u_sheen.a * edge * edge;
    \\  float line = clamp(1.0 - abs(m + 0.75) / (1.1 * px + 0.35), 0.0, 1.0);
    \\  float facing = 0.4 + 0.6 * max(0.0, dot(n, normalize(vec2(-0.5, -0.85))));
    \\  col = mix(col, u_rim.rgb, line * facing * u_rim.a);
    \\  col += (hash(gl_FragCoord.xy) - 0.5) * 0.025;
    \\  if (u_sparkle > 0.0) {
    \\    vec2 cell = floor((p + u_origin) / 30.0);
    \\    float h = hash(cell);
    \\    if (h > 0.9) {
    \\      vec2 star = (cell + vec2(hash(cell + 7.1), hash(cell + 3.7))) * 30.0 - u_origin;
    \\      float tw = 0.5 + 0.5 * sin(u_time * (1.5 + h * 2.0) + h * 40.0);
    \\      col += vec3(0.8, 0.9, 1.0) * pow(max(0.0, 1.0 - length(p - star) / 1.5), 2.0) * tw * u_sparkle;
    \\    }
    \\  }
    \\  o = vec4(col, 1.0) * a + vec4(0.0, 0.005, 0.02, 1.0) * sh;
    \\}
;

const down_fs =
    \\#version 300 es
    \\precision mediump float;
    \\in vec2 v_uv; uniform sampler2D u_tex; uniform vec2 u_half; out vec4 o;
    \\void main(){
    \\  vec4 s = texture(u_tex, v_uv) * 4.0;
    \\  s += texture(u_tex, v_uv - u_half);
    \\  s += texture(u_tex, v_uv + u_half);
    \\  s += texture(u_tex, v_uv + vec2(u_half.x, -u_half.y));
    \\  s += texture(u_tex, v_uv - vec2(u_half.x, -u_half.y));
    \\  o = s / 8.0;
    \\}
;

const up_fs =
    \\#version 300 es
    \\precision mediump float;
    \\in vec2 v_uv; uniform sampler2D u_tex; uniform vec2 u_half; out vec4 o;
    \\void main(){
    \\  vec2 h = u_half;
    \\  vec4 s = texture(u_tex, v_uv + vec2(-h.x * 2.0, 0.0));
    \\  s += texture(u_tex, v_uv + vec2(-h.x, h.y)) * 2.0;
    \\  s += texture(u_tex, v_uv + vec2(0.0, h.y * 2.0));
    \\  s += texture(u_tex, v_uv + vec2(h.x, h.y)) * 2.0;
    \\  s += texture(u_tex, v_uv + vec2(h.x * 2.0, 0.0));
    \\  s += texture(u_tex, v_uv + vec2(h.x, -h.y)) * 2.0;
    \\  s += texture(u_tex, v_uv + vec2(0.0, -h.y * 2.0));
    \\  s += texture(u_tex, v_uv + vec2(-h.x, -h.y)) * 2.0;
    \\  o = s / 12.0;
    \\}
;

const blit_fs =
    \\#version 300 es
    \\precision mediump float;
    \\in vec2 v_uv; uniform sampler2D u_tex; out vec4 o;
    \\void main(){ o = vec4(texture(u_tex, v_uv).rgb, 1.0); }
;

// ---------------------------------------------------------------------------
// GPU コンテキスト
// ---------------------------------------------------------------------------

pub const Gpu = struct {
    dpy: c.EGLDisplay,
    cfg: c.EGLConfig,
    ctx: c.EGLContext,
    ui: c.GLuint = 0,
    wall: c.GLuint = 0,
    down: c.GLuint = 0,
    up: c.GLuint = 0,
    blit: c.GLuint = 0,
    frame: c.GLuint = 0,
    vao: c.GLuint = 0,
    quad_vbo: c.GLuint = 0,
    inst_vbo: c.GLuint = 0,
    empty_vao: c.GLuint = 0,
    white_tex: c.GLuint = 0,
    black_tex: c.GLuint = 0,
    u: struct {
        size: c.GLint = -1,
        origin: c.GLint = -1,
        output: c.GLint = -1,
        scale: c.GLint = -1,
        time: c.GLint = -1,
    } = .{},

    pub fn init(wl_display: *c.struct_wl_display) !Gpu {
        // KHR_platform_wayland があれば明示的に Wayland プラットフォームを使う。
        var dpy: c.EGLDisplay = c.EGL_NO_DISPLAY;
        const get_platform: c.PFNEGLGETPLATFORMDISPLAYEXTPROC = @ptrCast(c.eglGetProcAddress("eglGetPlatformDisplayEXT"));
        if (get_platform) |f| dpy = f(c.EGL_PLATFORM_WAYLAND_KHR, wl_display, null);
        if (dpy == c.EGL_NO_DISPLAY) dpy = c.eglGetDisplay(@ptrCast(wl_display));
        if (dpy == c.EGL_NO_DISPLAY) return error.EglDisplay;
        var major: c.EGLint = 0;
        var minor: c.EGLint = 0;
        if (c.eglInitialize(dpy, &major, &minor) == 0) return error.EglInit;
        if (c.eglBindAPI(c.EGL_OPENGL_ES_API) == 0) return error.EglBind;

        const attrs = [_]c.EGLint{
            c.EGL_SURFACE_TYPE,    c.EGL_WINDOW_BIT,
            c.EGL_RENDERABLE_TYPE, c.EGL_OPENGL_ES3_BIT,
            c.EGL_RED_SIZE,        8,
            c.EGL_GREEN_SIZE,      8,
            c.EGL_BLUE_SIZE,       8,
            c.EGL_ALPHA_SIZE,      8,
            c.EGL_NONE,
        };
        var cfg: c.EGLConfig = null;
        var n: c.EGLint = 0;
        if (c.eglChooseConfig(dpy, &attrs, &cfg, 1, &n) == 0 or n == 0) return error.EglConfig;
        const ctx_attrs = [_]c.EGLint{ c.EGL_CONTEXT_MAJOR_VERSION, 3, c.EGL_NONE };
        const ctx = c.eglCreateContext(dpy, cfg, c.EGL_NO_CONTEXT, &ctx_attrs);
        if (ctx == c.EGL_NO_CONTEXT) return error.EglContext;
        // サーフェスが無い状態でもテクスチャ等を作れるよう surfaceless で current にする(Mesa は対応)。
        if (c.eglMakeCurrent(dpy, c.EGL_NO_SURFACE, c.EGL_NO_SURFACE, ctx) == 0) return error.EglSurfaceless;

        var g = Gpu{ .dpy = dpy, .cfg = cfg, .ctx = ctx };
        g.ui = try program(ui_vs, ui_fs);
        g.wall = try program(fs_vs, wall_fs);
        g.down = try program(fs_vs, down_fs);
        g.up = try program(fs_vs, up_fs);
        g.blit = try program(fs_vs, blit_fs);
        g.frame = try program(fs_vs, frame_fs);
        g.u.size = c.glGetUniformLocation(g.ui, "u_size");
        g.u.origin = c.glGetUniformLocation(g.ui, "u_origin");
        g.u.output = c.glGetUniformLocation(g.ui, "u_output");
        g.u.scale = c.glGetUniformLocation(g.ui, "u_scale");
        g.u.time = c.glGetUniformLocation(g.ui, "u_time");
        c.glUseProgram(g.ui);
        c.glUniform1i(c.glGetUniformLocation(g.ui, "u_atlas"), 0);
        c.glUniform1i(c.glGetUniformLocation(g.ui, "u_blur"), 1);
        c.glUniform1i(c.glGetUniformLocation(g.ui, "u_img"), 2);
        c.glUseProgram(g.wall);
        c.glUniform1i(c.glGetUniformLocation(g.wall, "u_img"), 3);
        c.glUniform1i(c.glGetUniformLocation(g.wall, "u_prev"), 4);

        // 単位四角形(TRIANGLE_STRIP)とインスタンスバッファ
        c.glGenVertexArrays(1, &g.vao);
        c.glBindVertexArray(g.vao);
        const quad = [_]f32{ 0, 0, 1, 0, 0, 1, 1, 1 };
        c.glGenBuffers(1, &g.quad_vbo);
        c.glBindBuffer(c.GL_ARRAY_BUFFER, g.quad_vbo);
        c.glBufferData(c.GL_ARRAY_BUFFER, @sizeOf(@TypeOf(quad)), &quad, c.GL_STATIC_DRAW);
        c.glEnableVertexAttribArray(0);
        c.glVertexAttribPointer(0, 2, c.GL_FLOAT, c.GL_FALSE, 8, null);
        c.glGenBuffers(1, &g.inst_vbo);
        c.glBindBuffer(c.GL_ARRAY_BUFFER, g.inst_vbo);
        var loc: c.GLuint = 1;
        while (loc <= 7) : (loc += 1) {
            c.glEnableVertexAttribArray(loc);
            c.glVertexAttribPointer(loc, 4, c.GL_FLOAT, c.GL_FALSE, INST_FLOATS * 4, @ptrFromInt((loc - 1) * 16));
            c.glVertexAttribDivisor(loc, 1);
        }
        c.glBindVertexArray(0);
        c.glGenVertexArrays(1, &g.empty_vao);

        g.white_tex = solidTex(0xffffffff);
        g.black_tex = solidTex(0xff100804);
        return g;
    }

    pub fn makeCurrent(self: *Gpu, surf: c.EGLSurface) void {
        _ = c.eglMakeCurrent(self.dpy, surf, surf, self.ctx);
    }
};

fn solidTex(rgba: u32) c.GLuint {
    var t: c.GLuint = 0;
    c.glGenTextures(1, &t);
    c.glBindTexture(c.GL_TEXTURE_2D, t);
    c.glTexImage2D(c.GL_TEXTURE_2D, 0, c.GL_RGBA, 1, 1, 0, c.GL_RGBA, c.GL_UNSIGNED_BYTE, &rgba);
    c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MIN_FILTER, c.GL_LINEAR);
    return t;
}

fn shader(kind: c.GLenum, src: []const u8) !c.GLuint {
    const s = c.glCreateShader(kind);
    const ptr: [*c]const u8 = src.ptr;
    const len: c.GLint = @intCast(src.len);
    c.glShaderSource(s, 1, &ptr, &len);
    c.glCompileShader(s);
    var ok: c.GLint = 0;
    c.glGetShaderiv(s, c.GL_COMPILE_STATUS, &ok);
    if (ok == 0) {
        var log: [2048]u8 = undefined;
        var n: c.GLsizei = 0;
        c.glGetShaderInfoLog(s, log.len, &n, &log);
        std.log.err("shader compile: {s}", .{log[0..@intCast(n)]});
        return error.Shader;
    }
    return s;
}

fn program(vs: []const u8, fs: []const u8) !c.GLuint {
    const p = c.glCreateProgram();
    c.glAttachShader(p, try shader(c.GL_VERTEX_SHADER, vs));
    c.glAttachShader(p, try shader(c.GL_FRAGMENT_SHADER, fs));
    c.glLinkProgram(p);
    var ok: c.GLint = 0;
    c.glGetProgramiv(p, c.GL_LINK_STATUS, &ok);
    if (ok == 0) {
        var log: [2048]u8 = undefined;
        var n: c.GLsizei = 0;
        c.glGetProgramInfoLog(p, log.len, &n, &log);
        std.log.err("program link: {s}", .{log[0..@intCast(n)]});
        return error.Program;
    }
    return p;
}

// ---------------------------------------------------------------------------
// テクスチャ付き FBO と、出力ごとの「背景」(壁紙 + ブラー段)
// ---------------------------------------------------------------------------

pub const Target = struct {
    tex: c.GLuint = 0,
    fbo: c.GLuint = 0,
    w: c_int = 0,
    h: c_int = 0,

    pub fn ensure(self: *Target, w: c_int, h: c_int) void {
        const ww = @max(w, 1);
        const hh = @max(h, 1);
        if (self.tex != 0 and self.w == ww and self.h == hh) return;
        if (self.tex == 0) {
            c.glGenTextures(1, &self.tex);
            c.glGenFramebuffers(1, &self.fbo);
        }
        self.w = ww;
        self.h = hh;
        c.glBindTexture(c.GL_TEXTURE_2D, self.tex);
        c.glTexImage2D(c.GL_TEXTURE_2D, 0, c.GL_RGBA8, ww, hh, 0, c.GL_RGBA, c.GL_UNSIGNED_BYTE, null);
        c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MIN_FILTER, c.GL_LINEAR);
        c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MAG_FILTER, c.GL_LINEAR);
        c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_WRAP_S, c.GL_CLAMP_TO_EDGE);
        c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_WRAP_T, c.GL_CLAMP_TO_EDGE);
        c.glBindFramebuffer(c.GL_FRAMEBUFFER, self.fbo);
        c.glFramebufferTexture2D(c.GL_FRAMEBUFFER, c.GL_COLOR_ATTACHMENT0, c.GL_TEXTURE_2D, self.tex, 0);
        c.glBindFramebuffer(c.GL_FRAMEBUFFER, 0);
    }
};

pub const WallParams = struct {
    trans: c_int = 0,
    origin: [2]f32 = .{ 0.5, 0.5 },
    time: f32,
    mode: c_int,
    prev_mode: c_int,
    mix: f32,
    img: c.GLuint,
    img_w: f32,
    img_h: f32,
    prev: c.GLuint,
    prev_w: f32,
    prev_h: f32,
    ca: Color,
    cb: Color,
    cc: Color,
};

/// 1つの出力の壁紙と、そのブラー済みテクスチャ。
pub const Backdrop = struct {
    scene: Target = .{},
    levels: [5]Target = .{ .{}, .{}, .{}, .{}, .{} },
    /// パネルがサンプルする最終ブラー
    blurred: c.GLuint = 0,

    /// 壁紙を (pw, ph) の解像度で描き、その後ブラー段を作る。
    pub fn render(self: *Backdrop, gpu: *Gpu, pw: c_int, ph: c_int, p: WallParams, passes: u32) void {
        self.scene.ensure(pw, ph);
        c.glDisable(c.GL_BLEND);
        c.glBindVertexArray(gpu.empty_vao);
        c.glBindFramebuffer(c.GL_FRAMEBUFFER, self.scene.fbo);
        c.glViewport(0, 0, self.scene.w, self.scene.h);
        c.glUseProgram(gpu.wall);
        const P = gpu.wall;
        c.glUniform2f(c.glGetUniformLocation(P, "u_res"), @floatFromInt(self.scene.w), @floatFromInt(self.scene.h));
        c.glUniform1f(c.glGetUniformLocation(P, "u_time"), p.time);
        c.glUniform1i(c.glGetUniformLocation(P, "u_mode"), p.mode);
        c.glUniform1i(c.glGetUniformLocation(P, "u_prev_mode"), p.prev_mode);
        c.glUniform1f(c.glGetUniformLocation(P, "u_mix"), p.mix);
        c.glUniform2f(c.glGetUniformLocation(P, "u_img_size"), p.img_w, p.img_h);
        c.glUniform2f(c.glGetUniformLocation(P, "u_prev_size"), p.prev_w, p.prev_h);
        c.glUniform3f(c.glGetUniformLocation(P, "u_ca"), p.ca.r, p.ca.g, p.ca.b);
        c.glUniform3f(c.glGetUniformLocation(P, "u_cb"), p.cb.r, p.cb.g, p.cb.b);
        c.glUniform3f(c.glGetUniformLocation(P, "u_cc"), p.cc.r, p.cc.g, p.cc.b);
        c.glUniform1i(c.glGetUniformLocation(P, "u_trans"), p.trans);
        c.glUniform2f(c.glGetUniformLocation(P, "u_origin"), p.origin[0], p.origin[1]);
        c.glActiveTexture(c.GL_TEXTURE3);
        c.glBindTexture(c.GL_TEXTURE_2D, if (p.img != 0) p.img else gpu.black_tex);
        c.glActiveTexture(c.GL_TEXTURE4);
        c.glBindTexture(c.GL_TEXTURE_2D, if (p.prev != 0) p.prev else gpu.black_tex);
        c.glActiveTexture(c.GL_TEXTURE0);
        c.glDrawArrays(c.GL_TRIANGLES, 0, 3);

        // dual Kawase: 縮小しながらぼかし、少し拡大して戻す。段数でブラーの強さを調整。
        const n = std.math.clamp(passes, 1, 4);
        var src: *Target = &self.scene;
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const dst = &self.levels[i];
            dst.ensure(@divTrunc(src.w, 2), @divTrunc(src.h, 2));
            pass(gpu.down, src, dst);
            src = dst;
        }
        // 1段だけ戻す(戻しすぎると解像度の割にぼけが弱くなるため)
        if (n >= 2) {
            const dst = &self.levels[4];
            dst.ensure(self.levels[n - 2].w, self.levels[n - 2].h);
            pass(gpu.up, src, dst);
            src = dst;
        }
        self.blurred = src.tex;
        c.glBindFramebuffer(c.GL_FRAMEBUFFER, 0);
    }

    fn pass(prog: c.GLuint, src: *Target, dst: *Target) void {
        c.glBindFramebuffer(c.GL_FRAMEBUFFER, dst.fbo);
        c.glViewport(0, 0, dst.w, dst.h);
        c.glUseProgram(prog);
        c.glUniform2f(c.glGetUniformLocation(prog, "u_half"), 0.5 / @as(f32, @floatFromInt(src.w)), 0.5 / @as(f32, @floatFromInt(src.h)));
        c.glBindTexture(c.GL_TEXTURE_2D, src.tex);
        c.glDrawArrays(c.GL_TRIANGLES, 0, 3);
    }

    /// 壁紙シーンを現在のサーフェス(フレームバッファ0)へ拡大して描く。
    pub fn blitTo(self: *Backdrop, gpu: *Gpu, w: c_int, h: c_int) void {
        c.glBindFramebuffer(c.GL_FRAMEBUFFER, 0);
        c.glViewport(0, 0, w, h);
        c.glDisable(c.GL_BLEND);
        c.glBindVertexArray(gpu.empty_vao);
        c.glUseProgram(gpu.blit);
        c.glActiveTexture(c.GL_TEXTURE0);
        c.glBindTexture(c.GL_TEXTURE_2D, self.scene.tex);
        c.glDrawArrays(c.GL_TRIANGLES, 0, 3);
    }
};

/// RGBA8 画像を GL テクスチャにする(ミップマップ付きで縮小表示もきれいに)。
pub fn uploadImage(rgba: [*]const u8, w: c_int, h: c_int) c.GLuint {
    var t: c.GLuint = 0;
    c.glGenTextures(1, &t);
    c.glBindTexture(c.GL_TEXTURE_2D, t);
    c.glPixelStorei(c.GL_UNPACK_ALIGNMENT, 1);
    c.glTexImage2D(c.GL_TEXTURE_2D, 0, c.GL_RGBA8, w, h, 0, c.GL_RGBA, c.GL_UNSIGNED_BYTE, rgba);
    c.glGenerateMipmap(c.GL_TEXTURE_2D);
    c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MIN_FILTER, c.GL_LINEAR_MIPMAP_LINEAR);
    c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MAG_FILTER, c.GL_LINEAR);
    c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_WRAP_S, c.GL_CLAMP_TO_EDGE);
    c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_WRAP_T, c.GL_CLAMP_TO_EDGE);
    return t;
}

// ---------------------------------------------------------------------------
// Canvas: 1フレーム分の描画命令を積んでまとめて描く
// ---------------------------------------------------------------------------

const INST_FLOATS = 28;

pub const Align = enum { left, center, right };

pub const TextOpts = struct {
    bold: bool = false,
    alignment: Align = .left,
    max_w: f32 = 0, // >0 なら超えた分を「…」で省略
    glow: f32 = 0,
    glow_color: Color = .{ .r = 0.5, .g = 0.75, .b = 1.0, .a = 0.6 },
};

pub const GlassStyle = struct {
    tint: Color,
    sheen: Color = .{ .r = 0.6, .g = 0.8, .b = 1.0, .a = 0.08 },
    rim: Color = .{ .r = 0.75, .g = 0.88, .b = 1.0, .a = 0.55 },
    refraction: f32 = 10,
    sparkle: f32 = 0.7,
};

const Xf = struct { tx: f32 = 0, ty: f32 = 0, s: f32 = 1, a: f32 = 1 };

pub const Canvas = struct {
    gpu: *Gpu,
    fonts: *textmod.Fonts,
    inst: std.ArrayList(f32),
    xf: Xf = .{},
    stack: [32]Xf = undefined,
    depth: usize = 0,
    clip: [4]f32 = .{ 0, 0, 0, 0 },
    cur_img: c.GLuint = 0,
    // フレームごとのサーフェス情報
    size: [2]f32 = .{ 1, 1 },
    scale: f32 = 1,
    origin: [2]f32 = .{ 0, 0 },
    output: [2]f32 = .{ 1, 1 },
    blur_tex: c.GLuint = 0,
    time: f32 = 0,

    pub fn init(alloc: std.mem.Allocator, gpu: *Gpu, fonts: *textmod.Fonts) Canvas {
        return .{ .gpu = gpu, .fonts = fonts, .inst = std.ArrayList(f32).init(alloc) };
    }

    pub fn begin(self: *Canvas, w: f32, h: f32, scale: f32, origin: [2]f32, output: [2]f32, blur: c.GLuint, time: f32) void {
        self.size = .{ w, h };
        self.scale = scale;
        self.origin = origin;
        self.output = output;
        self.blur_tex = if (blur != 0) blur else self.gpu.black_tex;
        self.time = time;
        self.xf = .{};
        self.depth = 0;
        self.clip = .{ 0, 0, 0, 0 };
        self.inst.clearRetainingCapacity();
        self.cur_img = 0;
        c.glBindFramebuffer(c.GL_FRAMEBUFFER, 0);
        c.glViewport(0, 0, @intFromFloat(w * scale), @intFromFloat(h * scale));
        c.glClearColor(0, 0, 0, 0);
        c.glClear(c.GL_COLOR_BUFFER_BIT);
    }

    pub fn end(self: *Canvas) void {
        self.flush();
    }

    pub fn flush(self: *Canvas) void {
        const n = self.inst.items.len / INST_FLOATS;
        if (n == 0) return;
        const g = self.gpu;
        c.glEnable(c.GL_BLEND);
        c.glBlendFunc(c.GL_ONE, c.GL_ONE_MINUS_SRC_ALPHA); // 乗算済みアルファ
        c.glUseProgram(g.ui);
        c.glUniform2f(g.u.size, self.size[0], self.size[1]);
        c.glUniform2f(g.u.origin, self.origin[0], self.origin[1]);
        c.glUniform2f(g.u.output, self.output[0], self.output[1]);
        c.glUniform1f(g.u.scale, self.scale);
        c.glUniform1f(g.u.time, self.time);
        c.glActiveTexture(c.GL_TEXTURE0);
        c.glBindTexture(c.GL_TEXTURE_2D, self.fonts.atlas_tex);
        c.glActiveTexture(c.GL_TEXTURE1);
        c.glBindTexture(c.GL_TEXTURE_2D, self.blur_tex);
        c.glActiveTexture(c.GL_TEXTURE2);
        c.glBindTexture(c.GL_TEXTURE_2D, if (self.cur_img != 0) self.cur_img else g.white_tex);
        c.glActiveTexture(c.GL_TEXTURE0);
        c.glBindVertexArray(g.vao);
        c.glBindBuffer(c.GL_ARRAY_BUFFER, g.inst_vbo);
        c.glBufferData(c.GL_ARRAY_BUFFER, @intCast(self.inst.items.len * 4), self.inst.items.ptr, c.GL_STREAM_DRAW);
        c.glDrawArraysInstanced(c.GL_TRIANGLE_STRIP, 0, 4, @intCast(n));
        c.glBindVertexArray(0);
        self.inst.clearRetainingCapacity();
    }

    // ---- 変換スタック(パネル全体の拡大・移動・フェードを CPU 側で適用) ----

    pub fn save(self: *Canvas) void {
        self.stack[self.depth] = self.xf;
        self.depth += 1;
    }
    pub fn restore(self: *Canvas) void {
        self.depth -= 1;
        self.xf = self.stack[self.depth];
    }
    pub fn translate(self: *Canvas, x: f32, y: f32) void {
        self.xf.tx += x * self.xf.s;
        self.xf.ty += y * self.xf.s;
    }
    /// (cx, cy) を中心に拡大縮小。
    pub fn scaleAbout(self: *Canvas, cx: f32, cy: f32, s: f32) void {
        self.translate(cx, cy);
        self.xf.s *= s;
        self.translate(-cx, -cy);
    }
    pub fn opacity(self: *Canvas, a: f32) void {
        self.xf.a *= std.math.clamp(a, 0, 1);
    }
    /// 論理座標でクリップ(変換後の座標で判定)。w<=0 で解除。
    pub fn setClip(self: *Canvas, x: f32, y: f32, w: f32, h: f32) void {
        if (w <= 0) {
            self.clip = .{ 0, 0, 0, 0 };
            return;
        }
        self.clip = .{ self.xf.tx + x * self.xf.s, self.xf.ty + y * self.xf.s, w * self.xf.s, h * self.xf.s };
    }

    fn push(self: *Canvas, x: f32, y: f32, w: f32, h: f32, c0: Color, c1: Color, c2: Color, p0: [4]f32, p1: [4]f32) void {
        const s = self.xf.s;
        const a = self.xf.a;
        if (a <= 0.001) return;
        const v = [INST_FLOATS]f32{
            self.xf.tx + x * s, self.xf.ty + y * s, w * s,   h * s,
            c0.r,               c0.g,               c0.b,    c0.a * a,
            c1.r,               c1.g,               c1.b,    c1.a * a,
            c2.r,               c2.g,               c2.b,    c2.a * a,
            p0[0] * s,          p0[1],              p0[2],   p0[3] * s,
            p1[0],              p1[1],              p1[2],   p1[3],
            self.clip[0],       self.clip[1],       self.clip[2], self.clip[3],
        };
        self.inst.appendSlice(&v) catch {};
    }

    pub fn rect(self: *Canvas, x: f32, y: f32, w: f32, h: f32, r: f32, col: Color) void {
        self.push(x, y, w, h, col, col, col, .{ r, 0, 0, 0 }, .{ 0, 0, 0, 0 });
    }
    pub fn rectGrad(self: *Canvas, x: f32, y: f32, w: f32, h: f32, r: f32, top: Color, bottom: Color) void {
        self.push(x, y, w, h, top, bottom, top, .{ r, 0, 0, 0 }, .{ 0, 0, 0, 0 });
    }
    pub fn rectBorder(self: *Canvas, x: f32, y: f32, w: f32, h: f32, r: f32, fill: Color, border: Color, bw: f32) void {
        self.push(x, y, w, h, fill, fill, border, .{ r, 0, bw * self.xf.s, 0 }, .{ 0, 0, 0, 0 });
    }
    pub fn shadow(self: *Canvas, x: f32, y: f32, w: f32, h: f32, r: f32, blur: f32, col: Color) void {
        self.push(x, y, w, h, col, col, col, .{ r, 1, 0, blur }, .{ 0, 0, 0, 0 });
    }
    pub fn glass(self: *Canvas, x: f32, y: f32, w: f32, h: f32, r: f32, st: GlassStyle) void {
        // ガラスのアルファは opacity をそのまま掛ける(p1.y)。色ではなく合成率で扱う。
        self.push(x, y, w, h, st.tint, st.sheen, st.rim, .{ r, 2, 0, 0 }, .{ st.refraction * self.xf.s, self.xf.a, st.sparkle, 0 });
    }
    pub fn arc(self: *Canvas, cx: f32, cy: f32, radius: f32, thick: f32, progress: f32, fg: Color, track: Color) void {
        self.push(cx - radius, cy - radius, radius * 2, radius * 2, fg, track, fg, .{ 0, 4, 0, 0 }, .{ std.math.clamp(progress, 0, 1), thick * self.xf.s, 0, 0 });
    }
    /// caelestia 風の枠とドロワーを描く(全画面パス)。それまでの命令は先に描いておく。
    pub fn frameBg(self: *Canvas, sh: *const FrameShape) void {
        self.flush();
        const g = self.gpu;
        const P = g.frame;
        c.glEnable(c.GL_BLEND);
        c.glBlendFunc(c.GL_ONE, c.GL_ONE_MINUS_SRC_ALPHA);
        c.glUseProgram(P);
        c.glBindVertexArray(g.empty_vao);
        c.glUniform2f(c.glGetUniformLocation(P, "u_size"), self.size[0], self.size[1]);
        c.glUniform1f(c.glGetUniformLocation(P, "u_scale"), self.scale);
        c.glUniform2f(c.glGetUniformLocation(P, "u_output"), self.output[0], self.output[1]);
        c.glUniform2f(c.glGetUniformLocation(P, "u_origin"), self.origin[0], self.origin[1]);
        c.glUniform1f(c.glGetUniformLocation(P, "u_time"), self.time);
        c.glUniform4f(c.glGetUniformLocation(P, "u_hole"), sh.hole[0], sh.hole[1], sh.hole[2], sh.hole[3]);
        c.glUniform1f(c.glGetUniformLocation(P, "u_hole_r"), sh.hole_r);
        c.glUniform4fv(c.glGetUniformLocation(P, "u_box"), @intCast(sh.n), @ptrCast(&sh.boxes));
        c.glUniform2fv(c.glGetUniformLocation(P, "u_boxp"), @intCast(sh.n), @ptrCast(&sh.params));
        c.glUniform1i(c.glGetUniformLocation(P, "u_n"), @intCast(sh.n));
        c.glUniform4f(c.glGetUniformLocation(P, "u_tint"), sh.tint.r, sh.tint.g, sh.tint.b, sh.tint.a);
        c.glUniform4f(c.glGetUniformLocation(P, "u_rim"), sh.rim.r, sh.rim.g, sh.rim.b, sh.rim.a);
        c.glUniform4f(c.glGetUniformLocation(P, "u_sheen"), sh.sheen.r, sh.sheen.g, sh.sheen.b, sh.sheen.a);
        c.glUniform1f(c.glGetUniformLocation(P, "u_shadow"), sh.shadow);
        c.glUniform1f(c.glGetUniformLocation(P, "u_sparkle"), sh.sparkle);
        c.glUniform1i(c.glGetUniformLocation(P, "u_blur"), 1);
        c.glActiveTexture(c.GL_TEXTURE1);
        c.glBindTexture(c.GL_TEXTURE_2D, self.blur_tex);
        c.glActiveTexture(c.GL_TEXTURE0);
        c.glDrawArrays(c.GL_TRIANGLES, 0, 3);
    }

    /// 縦書き(時計回りに 90°。英数字は寝かせ、上から下へ読む)。cx は文字列の中心線、y は書き出し位置。
    /// 戻り値は使った長さ(縦方向)。
    pub fn textV(self: *Canvas, cx: f32, y: f32, size: f32, col: Color, str: []const u8, o: TextOpts) f32 {
        const k = size / textmod.BASE_PX;
        const shaped = self.fonts.shape(str, o.bold);
        var len = shaped.width * k;
        var limit = shaped.glyphs.len;
        if (o.max_w > 0 and len > o.max_w) {
            var n: usize = 0;
            for (shaped.glyphs, 0..) |g, i| {
                if ((g.x + g.glyph.left + g.glyph.w) * k > o.max_w - size) break;
                n = i + 1;
            }
            limit = n;
            len = o.max_w;
        }
        const y0 = switch (o.alignment) {
            .left => y,
            .center => y - len / 2,
            .right => y - len,
        };
        // ベースラインは中心線より少し左(字面の高さの中央が cx に来るように)
        const bx = cx - size * 0.36;
        const kk = k * self.xf.s * self.scale;
        var last: f32 = 0;
        for (shaped.glyphs[0..limit]) |pg| {
            const g = pg.glyph;
            const gx = bx + (g.top - g.h - pg.y) * k;
            const gy = y0 + (pg.x + g.left) * k;
            self.push(gx, gy, g.h * k, g.w * k, col, col, o.glow_color, .{ 0, 7, kk, o.glow * self.xf.s * self.scale }, .{ g.u0, g.v0, g.u1, g.v1 });
            last = (pg.x + g.left + g.w) * k;
        }
        if (limit < shaped.glyphs.len) {
            // 省略は縦の「…」(点を 3 つ)
            var i: f32 = 0;
            while (i < 3) : (i += 1) self.rect(cx - 1.2, y0 + last + 4 + i * 4, 2.4, 2.4, 1.2, col);
        }
        return len;
    }

    /// 両端の丸い線分(音声スペクトラムの放射状のバー等)
    pub fn line(self: *Canvas, x0: f32, y0: f32, x1: f32, y1: f32, thick: f32, col: Color) void {
        const pad = thick;
        const minx = @min(x0, x1) - pad;
        const miny = @min(y0, y1) - pad;
        const w = @abs(x1 - x0) + pad * 2;
        const h = @abs(y1 - y0) + pad * 2;
        const cx = minx + w / 2;
        const cy = miny + h / 2;
        const s = self.xf.s;
        self.push(minx, miny, w, h, col, col, col, .{ 0, 8, thick * s, 0 }, .{ (x0 - cx) * s, (y0 - cy) * s, (x1 - cx) * s, (y1 - cy) * s });
    }

    /// 平行四辺形(傾き skew)にくり抜いた画像カード。x,y,w,h は外接矩形。uv は画像のどこを見せるか。
    /// bright: 明るさ(非選択のカードを暗くする)、border: 縁取りの太さと色。
    pub fn skewImage(self: *Canvas, tex: c.GLuint, x: f32, y: f32, w: f32, h: f32, r: f32, skew: f32, uv: [4]f32, bright: f32, border: f32, border_col: Color) void {
        if (tex == 0) return;
        if (self.cur_img != 0 and self.cur_img != tex) self.flush();
        self.cur_img = tex;
        const c0 = Color{ .r = bright, .g = bright, .b = bright, .a = 1 };
        const c1 = Color{ .r = skew, .g = 0, .b = 0, .a = 1 };
        // c1 は opacity を掛けられるが r(傾き)には掛からない
        self.push(x, y, w, h, c0, c1, border_col, .{ r, 9, border * self.xf.s, 0 }, uv);
    }

    pub fn image(self: *Canvas, tex: c.GLuint, x: f32, y: f32, w: f32, h: f32, r: f32) void {
        if (tex == 0) return;
        if (self.cur_img != 0 and self.cur_img != tex) self.flush();
        self.cur_img = tex;
        const white = Color{ .r = 1, .g = 1, .b = 1, .a = 1 };
        self.push(x, y, w, h, white, white, white, .{ r, 5, 0, 0 }, .{ 0, 0, 1, 1 });
    }

    pub fn textWrap(self: *Canvas, x: f32, y: f32, size: f32, col: Color, str: []const u8, max_w: f32, max_lines: usize, line_h: f32) void {
        textWrapImpl(self, x, y, size, col, str, max_w, max_lines, line_h);
    }

    pub fn measure(self: *Canvas, str: []const u8, size: f32, bold: bool) f32 {
        return self.fonts.measure(str, bold, size);
    }

    /// 文字列を描く。y はベースライン。戻り値は描いた幅。
    pub fn text(self: *Canvas, x: f32, y: f32, size: f32, col: Color, str: []const u8, o: TextOpts) f32 {
        const k = size / textmod.BASE_PX;
        const shaped = self.fonts.shape(str, o.bold);
        var width = shaped.width * k;
        var limit_glyphs = shaped.glyphs.len;
        var ell_w: f32 = 0;
        if (o.max_w > 0 and width > o.max_w) {
            // 省略記号の幅を引いた範囲に収まるグリフまで描く
            ell_w = self.fonts.measure("…", o.bold, size);
            const shaped2 = self.fonts.shape(str, o.bold); // measure で scratch が上書きされたため再整形
            var n: usize = 0;
            for (shaped2.glyphs, 0..) |g, i| {
                if ((g.x + g.glyph.left + g.glyph.w) * k > o.max_w - ell_w) break;
                n = i + 1;
            }
            limit_glyphs = n;
            width = o.max_w;
        }
        const x0 = switch (o.alignment) {
            .left => x,
            .center => x - width / 2,
            .right => x - width,
        };
        const kk = k * self.xf.s * self.scale; // 基準px → 画面の物理px
        const shaped3 = self.fonts.shape(str, o.bold);
        var last_x: f32 = 0;
        for (shaped3.glyphs[0..limit_glyphs]) |pg| {
            const g = pg.glyph;
            const gx = x0 + (pg.x + g.left) * k;
            const gy = y - (g.top - pg.y) * k;
            self.push(gx, gy, g.w * k, g.h * k, col, col, o.glow_color, .{ 0, 3, kk, o.glow * self.xf.s * self.scale }, .{ g.u0, g.v0, g.u1, g.v1 });
            last_x = (pg.x + g.left + g.w) * k;
        }
        if (limit_glyphs < shaped3.glyphs.len) {
            _ = self.text(x0 + last_x, y, size, col, "…", .{ .bold = o.bold, .glow = o.glow, .glow_color = o.glow_color });
        }
        return width;
    }
};

/// 折り返し付きの文字列描画。空白か、CJK 文字の間で改行する。最後の行は「…」で省略。
pub fn textWrapImpl(self: *Canvas, x: f32, y: f32, size: f32, col: Color, str: []const u8, max_w: f32, max_lines: usize, line_h: f32) void {
    const k = size / textmod.BASE_PX;
    const shaped = self.fonts.shape(str, false);
    var ranges: [8][2]usize = undefined;
    var n: usize = 0;
    var line_start: usize = 0;
    var line_x: f32 = 0;
    var brk: ?usize = null;
    var brk_x: f32 = 0;
    const lines_max = @min(max_lines, ranges.len);
    for (shaped.glyphs) |g| {
        const cl: usize = g.cluster;
        if (cl > line_start) {
            const prev = str[cl - 1];
            // 直前が空白、またはこの文字が CJK(UTF-8 先頭バイト 0xE3〜0xE9 はおおむね かな/漢字)
            if (prev == ' ' or (str[cl] >= 0xE3 and str[cl] <= 0xE9)) {
                brk = cl;
                brk_x = g.x;
            }
        }
        if ((g.x + g.glyph.left + g.glyph.w - line_x) * k > max_w and n + 1 < lines_max and cl > line_start) {
            const b = brk orelse cl;
            ranges[n] = .{ line_start, b };
            n += 1;
            line_start = b;
            line_x = if (brk != null) brk_x else g.x;
            brk = null;
        }
    }
    ranges[n] = .{ line_start, str.len };
    n += 1;
    for (ranges[0..n], 0..) |r, i| {
        const seg = std.mem.trim(u8, str[r[0]..r[1]], " ");
        _ = self.text(x, y + @as(f32, @floatFromInt(i)) * line_h, size, col, seg, .{ .max_w = max_w });
    }
}

/// 枠の形(frameBg に渡す)。座標はサーフェスの論理 px。
pub const FrameShape = struct {
    hole: [4]f32 = .{ 0, 0, 0, 0 }, // 窓の穴 x, y, w, h
    hole_r: f32 = 25,
    boxes: [14][4]f32 = undefined, // ドロワーの矩形
    params: [14][2]f32 = undefined, // 角丸, smooth-min の幅
    n: usize = 0,
    tint: Color = .{},
    rim: Color = .{},
    sheen: Color = .{},
    shadow: f32 = 0.35,
    sparkle: f32 = 0.6,

    /// 仮想座標で組んだ形を表示倍率に合わせて拡大する
    pub fn scale(self: *FrameShape, s: f32) void {
        for (&self.hole) |*v| v.* *= s;
        self.hole_r *= s;
        for (self.boxes[0..self.n], self.params[0..self.n]) |*b, *p| {
            for (b) |*v| v.* *= s;
            p[0] *= s;
            p[1] *= s;
        }
    }

    pub fn add(self: *FrameShape, x: f32, y: f32, w: f32, h: f32, r: f32, k: f32) void {
        if (self.n >= self.boxes.len or w <= 0.5 or h <= 0.5) return;
        self.boxes[self.n] = .{ x, y, w, h };
        self.params[self.n] = .{ r, k };
        self.n += 1;
    }
};
