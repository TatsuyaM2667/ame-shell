// ame-shell ドキュメントサイトの読み込み役。
// 本文を HTML にするのは site.wasm(Zig、site/src/main.zig)、デモの計算は anim.wasm
// (ame-shell 本体と同じ anim/anim.odin を Odin で freestanding_wasm32 にしたもの)。
// ここでは wasm を読み込み、結果を DOM に入れ、Canvas に描くだけ。ライブラリは使わない。

const dec = new TextDecoder();
const enc = new TextEncoder();
let S = null; // site.wasm の exports
let A = null; // anim.wasm の exports
let base = 0; // anim.wasm の中で、デモが使う作業領域の先頭
let cleanups = [];

// file:// で開いたとき(fetch が使えない)は XMLHttpRequest で読む
function xhr(url) {
  return new Promise((ok, ng) => {
    const r = new XMLHttpRequest();
    r.open("GET", url);
    r.responseType = "arraybuffer";
    r.onload = () => (r.response ? ok(r.response) : ng(new Error(url)));
    r.onerror = () => ng(new Error(url));
    r.send();
  });
}

async function load(url) {
  let buf;
  try {
    const res = await fetch(url);
    if (!res.ok) throw new Error(`${url}: ${res.status}`);
    buf = await res.arrayBuffer();
  } catch (e) {
    buf = await xhr(url);
  }
  const { instance } = await WebAssembly.instantiate(buf, {});
  return { ex: instance.exports, size: buf.byteLength };
}

const kb = (n) => (n / 1024).toFixed(1) + " KB";
const out = (len) => dec.decode(new Uint8Array(S.memory.buffer, S.out_ptr(), len));

function pageIndex(slug) {
  const b = enc.encode(slug).slice(0, 255);
  new Uint8Array(S.memory.buffer, S.in_ptr(), b.length).set(b);
  return S.find_page(b.length);
}

// ---- ルーティング: #/ページ#見出し ----
function parseHash() {
  const m = location.hash.match(/^#\/([^#]*)(?:#(.*))?$/);
  if (!m) return { slug: "", anchor: location.hash.slice(1) || "" };
  return { slug: decodeURIComponent(m[1]), anchor: m[2] || "" };
}

let curSlug = null;
function render() {
  const { slug, anchor } = parseHash();
  if (slug !== curSlug) {
    curSlug = slug;
    for (const f of cleanups) f();
    cleanups = [];
    const i = pageIndex(slug);
    const idx = i < 0 ? 9999 : i;
    const main = document.getElementById("main");
    main.innerHTML = out(S.render_page(idx));
    main.dataset.page = i < 0 ? "missing" : slug || "home";
    document.getElementById("nav").innerHTML = out(S.render_nav(idx));
    document.getElementById("toc").innerHTML = i < 0 ? "" : out(S.render_toc(idx));
    const title = i < 0 ? "見つかりません" : out(S.page_title(idx));
    document.title = i === 0 ? "ame-shell — ばねで動く Wayland シェル" : `${title} — ame-shell`;
    main.classList.remove("enter");
    void main.offsetWidth;
    main.classList.add("enter");
    setupPage(main);
    if (!anchor) window.scrollTo({ top: 0 });
    const on = document.querySelector("#nav a.on");
    if (on) on.scrollIntoView({ block: "nearest", inline: "center" });
  }
  if (anchor) {
    const el = document.getElementById(anchor);
    if (el) el.scrollIntoView({ behavior: "smooth" });
  }
}

// ページ内の「#見出し」へのリンクは、ページの指定を残したまま移動する
document.addEventListener("click", (e) => {
  const a = e.target.closest("a[href^='#']");
  if (!a) return;
  const href = a.getAttribute("href");
  if (href.startsWith("#/")) return;
  e.preventDefault();
  const id = href.slice(1);
  history.replaceState(null, "", `#/${curSlug ?? ""}#${id}`);
  const el = document.getElementById(id);
  if (el) el.scrollIntoView({ behavior: "smooth" });
});

function setupPage(root) {
  // 動画: 見えている間だけ再生
  const vids = root.querySelectorAll("video");
  const vo = new IntersectionObserver((ents) => {
    for (const en of ents) {
      const v = en.target;
      if (en.isIntersecting) {
        if (v.preload === "none") v.preload = "auto";
        v.play().catch(() => {});
      } else v.pause();
    }
  }, { threshold: 0.35 });
  vids.forEach((v) => vo.observe(v));
  cleanups.push(() => vo.disconnect());

  // 写真: クリックで拡大
  root.querySelectorAll(".media img").forEach((img) => {
    img.addEventListener("click", () => {
      const lb = document.getElementById("lightbox");
      lb.querySelector("img").src = img.src;
      lb.hidden = false;
    });
  });

  // 目次: 今読んでいる見出しに印
  const toc = document.getElementById("toc");
  const heads = root.querySelectorAll("h2[id]");
  const ho = new IntersectionObserver((ents) => {
    for (const en of ents) {
      if (!en.isIntersecting) continue;
      toc.querySelectorAll("a").forEach((a) => a.classList.toggle("on", a.getAttribute("href") === "#" + en.target.id));
    }
  }, { rootMargin: "-80px 0px -70% 0px" });
  heads.forEach((h) => ho.observe(h));
  cleanups.push(() => ho.disconnect());

  // デモ
  root.querySelectorAll(".demo[data-demo]").forEach((el) => {
    const f = { spring: springDemo, fuzzy: fuzzyDemo, color: colorDemo }[el.dataset.demo];
    if (f) f(el);
  });
}

document.getElementById("lightbox").addEventListener("click", (e) => { e.currentTarget.hidden = true; });
addEventListener("keydown", (e) => { if (e.key === "Escape") document.getElementById("lightbox").hidden = true; });

// ---------------------------------------------------------------------------
// デモ 1: ばね(Odin の ame_spring_step)と ベジェ曲線
// ---------------------------------------------------------------------------

// CSS の cubic-bezier と同じ: x(t) = 時間の割合 から t を求めて y(t)
function bezier(x1, y1, x2, y2) {
  const cx = (t) => 3 * x1 * t * (1 - t) ** 2 + 3 * x2 * t * t * (1 - t) + t ** 3;
  const cy = (t) => 3 * y1 * t * (1 - t) ** 2 + 3 * y2 * t * t * (1 - t) + t ** 3;
  return (x) => {
    let lo = 0, hi = 1, t = x;
    for (let k = 0; k < 30; k++) {
      t = (lo + hi) / 2;
      if (cx(t) < x) lo = t; else hi = t;
    }
    return cy(t);
  };
}

function springDemo(el) {
  el.innerHTML = `
    <h4><span class="tag">WebAssembly</span>ばね(ame-shell の Odin のコード) と ベジェ曲線</h4>
    <canvas height="300"></canvas>
    <div class="row">
      <button data-act="burst">連打(0.18 秒ごとに行き先を変える)</button>
      <label>応答 <input type="range" min="0.12" max="0.9" step="0.01" value="0.36" data-k="resp"> <span data-v="resp">0.36 秒</span></label>
      <label>減衰 <input type="range" min="0.25" max="1.2" step="0.01" value="0.68" data-k="damp"> <span data-v="damp">0.68</span></label>
    </div>
    <div class="row legend"><span><i style="background:#7ab8ff"></i>ばね(速度がつながる)</span><span><i style="background:#ff8fb8"></i>ベジェ cubic-bezier(.05,.9,.1,1.05)・0.6 秒(行き先が変わると最初から)</span></div>`;
  const cv = el.querySelector("canvas");
  const ctx = cv.getContext("2d");
  const f32 = () => new Float32Array(A.memory.buffer, base, 5);
  // Spring { x, v, target, response, damping }
  const sp = f32();
  sp.set([0.15, 0, 0.15, 0.36, 0.68]);
  const ease = bezier(0.05, 0.9, 0.1, 1.05);
  const bz = { from: 0.15, to: 0.15, t0: 0, dur: 0.6, x: 0.15, v: 0 };
  let target = 0.15;
  let clock = 0; // 秒。requestAnimationFrame の時刻にそろえる(ばねとベジェで同じ時計)
  const hist = []; // [ばねの速度, ベジェの速度]
  let last = performance.now();
  let raf = 0;
  let burst = 0;

  const setTarget = (t) => {
    target = Math.min(0.95, Math.max(0.05, t));
    f32()[2] = target;
    bz.from = bz.x;
    bz.to = target;
    bz.t0 = clock;
  };
  const posFrom = (e) => {
    const r = cv.getBoundingClientRect();
    return (e.clientX - r.left) / r.width;
  };
  // 触るまでは自動で: ときどき行き先を変え、ときどき連打する(違いがすぐ見えるように)
  let touched = false;
  let autoAt = 0;
  let dragging = false;
  cv.addEventListener("pointerdown", (e) => { touched = true; dragging = true; cv.setPointerCapture(e.pointerId); setTarget(posFrom(e)); });
  cv.addEventListener("pointermove", (e) => { if (dragging) setTarget(posFrom(e)); });
  cv.addEventListener("pointerup", () => { dragging = false; });
  el.querySelector("[data-act=burst]").addEventListener("click", () => { touched = true; burst = 14; });
  el.querySelectorAll("input[type=range]").forEach((inp) => {
    inp.addEventListener("input", () => {
      const v = parseFloat(inp.value);
      if (inp.dataset.k === "resp") { f32()[3] = v; el.querySelector("[data-v=resp]").textContent = v.toFixed(2) + " 秒"; }
      else { f32()[4] = v; el.querySelector("[data-v=damp]").textContent = v.toFixed(2); }
    });
  });

  let burstAt = 0;
  const frame = (now) => {
    const dt = Math.min(0.05, (now - last) / 1000);
    clock = now / 1000;
    last = now;
    if (!touched && burst === 0 && now - autoAt > 1900) {
      autoAt = now;
      if (Math.random() < 0.45) burst = 6; else setTarget(f32()[2] < 0.5 ? 0.7 + Math.random() * 0.2 : 0.1 + Math.random() * 0.2);
    }
    if (burst > 0 && now - burstAt > 180) {
      burstAt = now;
      burst--;
      setTarget(0.1 + Math.random() * 0.8);
    }
    // ばね: ame-shell と同じ関数で dt だけ進める
    const prevS = f32()[0];
    A.ame_spring_step(base, dt);
    const s = f32();
    // ベジェ: 時間の割合から位置を求め、速度は差分から
    const t = Math.min(1, Math.max(0, (clock - bz.t0) / bz.dur));
    const prevB = bz.x;
    bz.x = bz.from + (bz.to - bz.from) * ease(t);
    bz.v = dt > 0 ? (bz.x - prevB) / dt : 0;
    hist.push([s[1], bz.v]);
    if (hist.length > 220) hist.shift();
    draw(s[0], bz.x, prevS);
    raf = requestAnimationFrame(frame);
  };

  function draw(xs, xb) {
    const dpr = devicePixelRatio || 1;
    const W = cv.clientWidth, H = 300;
    if (cv.width !== Math.round(W * dpr)) { cv.width = Math.round(W * dpr); cv.height = Math.round(H * dpr); }
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    ctx.clearRect(0, 0, W, H);
    ctx.font = "13px 'Noto Sans JP', sans-serif";
    const lane = (y, x, col, label) => {
      ctx.fillStyle = "rgba(167,182,216,.85)";
      ctx.fillText(label, 14, y - 22);
      ctx.strokeStyle = "rgba(160,190,255,.15)";
      ctx.lineWidth = 2;
      ctx.beginPath(); ctx.moveTo(14, y); ctx.lineTo(W - 14, y); ctx.stroke();
      // 行き先
      ctx.strokeStyle = "rgba(255,255,255,.35)";
      ctx.setLineDash([4, 4]);
      ctx.beginPath(); ctx.moveTo(target * W, y - 14); ctx.lineTo(target * W, y + 14); ctx.stroke();
      ctx.setLineDash([]);
      ctx.shadowColor = col; ctx.shadowBlur = 18;
      ctx.fillStyle = col;
      ctx.beginPath(); ctx.arc(x * W, y, 11, 0, Math.PI * 2); ctx.fill();
      ctx.shadowBlur = 0;
    };
    lane(58, xs, "#7ab8ff", "ばね — ame-shell(anim.wasm の ame_spring_step を毎フレーム呼んでいる)");
    lane(132, xb, "#ff8fb8", "ベジェ曲線 — 時間と曲線で決める動き");
    // 速度のグラフ
    const gy = 168, gh = 118;
    ctx.fillStyle = "rgba(167,182,216,.6)";
    ctx.fillText("速度", 14, gy + 4);
    ctx.strokeStyle = "rgba(160,190,255,.12)";
    ctx.beginPath(); ctx.moveTo(14, gy + gh / 2 + 6); ctx.lineTo(W - 14, gy + gh / 2 + 6); ctx.stroke();
    const sc = gh / 2 / 6;
    for (const [k, col] of [[1, "#ff8fb8"], [0, "#7ab8ff"]]) {
      ctx.strokeStyle = col; ctx.lineWidth = 2;
      ctx.beginPath();
      hist.forEach((h, i) => {
        const x = 14 + (i / 219) * (W - 28);
        const y = gy + gh / 2 + 6 - Math.max(-6, Math.min(6, h[k])) * sc;
        i ? ctx.lineTo(x, y) : ctx.moveTo(x, y);
      });
      ctx.stroke();
    }
  }
  raf = requestAnimationFrame(frame);
  cleanups.push(() => cancelAnimationFrame(raf));
}

// ---------------------------------------------------------------------------
// デモ 2: あいまい検索(Odin の ame_fuzzy_score)
// ---------------------------------------------------------------------------

const APPS = ["Firefox", "foot", "Files", "Thunderbird", "GIMP", "Inkscape", "Blender", "VLC media player", "mpv", "Steam",
  "Discord", "Spotify", "Obsidian", "Visual Studio Code", "Zed", "Neovim", "htop", "btop", "LibreOffice Writer",
  "LibreOffice Calc", "LibreOffice Impress", "Kdenlive", "OBS Studio", "Krita", "Telegram Desktop", "Signal", "Element",
  "KeePassXC", "qBittorrent", "PulseAudio Volume Control", "Network Manager", "Bluetooth", "Calculator", "Chromium",
  "Thunar File Manager", "Document Viewer", "Okular", "Audacity", "Godot Engine", "fcitx5-configtool", "music-tui",
  "Wallpaper Picker", "Lock Screen", "Screenshot", "Reboot", "Power Off", "ame-update"];

function fuzzyDemo(el) {
  el.innerHTML = `
    <h4><span class="tag">WebAssembly</span>あいまい検索(ランチャーと同じ ame_fuzzy_score)</h4>
    <input type="search" value="vsc" placeholder="アプリ名の一部を打ってみる(例: ff, vsc, lo w, gp)" aria-label="検索">
    <ul class="fz-list"></ul>
    <div class="row">先頭・区切り(空白 - _ . /)・camelCase の境目・連続した一致ほど高い点数。早く始まる・短い名前も少し有利。</div>`;
  const inp = el.querySelector("input");
  const list = el.querySelector(".fz-list");
  const pat = base + 64, txt = base + 512;
  const score = (p, t) => {
    const mem = new Uint8Array(A.memory.buffer);
    const pb = enc.encode(p).slice(0, 400), tb = enc.encode(t).slice(0, 400);
    mem.set(pb, pat);
    mem.set(tb, txt);
    return A.ame_fuzzy_score(pat, pb.length, txt, tb.length);
  };
  // ame_fuzzy_score と同じ順番(前から貪欲に)で一致した位置に印
  const mark = (p, t) => {
    let pi = 0, html = "";
    for (const ch of t) {
      if (pi < p.length && ch.toLowerCase() === p[pi].toLowerCase()) { html += `<mark>${esc(ch)}</mark>`; pi++; }
      else html += esc(ch);
    }
    return html;
  };
  const update = () => {
    const q = inp.value;
    const rows = APPS.map((a) => [a, score(q, a)]).filter((r) => r[1] >= 0).sort((x, y) => y[1] - x[1]).slice(0, 8);
    list.innerHTML = rows.map(([a, s]) => `<li><span>${mark(q, a)}</span><span class="sc">${s}</span></li>`).join("") ||
      `<li><span>一致なし</span><span class="sc">-1</span></li>`;
  };
  inp.addEventListener("input", update);
  update();
}

const esc = (s) => s.replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" })[c]);

// ---------------------------------------------------------------------------
// デモ 3: 壁紙の主色(Odin の ame_dominant_color)
// ---------------------------------------------------------------------------

const SAMPLES = ["shot-hero.jpg", "shot-theme-from-wallpaper.jpg", "shot-media.jpg", "wallpaper.jpg", "shot-launcher.jpg", "windows.jpg"];

function colorDemo(el) {
  el.innerHTML = `
    <h4><span class="tag">WebAssembly</span>画像の主色(壁紙・アルバムアートから配色を作る ame_dominant_color)</h4>
    <div class="cl-grid"></div>
    <div class="row"><label><button type="button" data-act="pick">自分の画像で試す</button><input type="file" accept="image/*" hidden></label>
      <span>画像はブラウザの中だけで処理します(どこにも送りません)</span></div>
    <div class="cl-preview"><b>アクセント</b> <span data-hex></span> — この色がガラスの縁・ボタン・光に使われます</div>`;
  const grid = el.querySelector(".cl-grid");
  const prev = el.querySelector(".cl-preview");
  const file = el.querySelector("input[type=file]");
  el.querySelector("[data-act=pick]").addEventListener("click", () => file.click());
  const W = 160, H = 90;
  const canvas = document.createElement("canvas");
  canvas.width = W; canvas.height = H;
  const c2 = canvas.getContext("2d", { willReadFrequently: true });
  const pix = base + 4096, work = base + 65536;

  const dominant = (img) => {
    c2.drawImage(img, 0, 0, W, H);
    const data = c2.getImageData(0, 0, W, H).data;
    new Uint8Array(A.memory.buffer, pix, data.length).set(data);
    const rgb = A.ame_dominant_color(pix, W * H, 1, work) >>> 0;
    return "#" + rgb.toString(16).padStart(6, "0");
  };
  const show = (hex) => {
    prev.style.background = `linear-gradient(135deg, ${hex}26, rgba(14,22,46,.8))`;
    prev.style.borderColor = hex;
    prev.querySelector("b").style.color = hex;
    prev.querySelector("[data-hex]").textContent = hex;
  };
  const add = (src, name, select) => {
    const img = new Image();
    img.onload = () => {
      const hex = dominant(img);
      const b = document.createElement("button");
      b.className = "cl-item";
      b.type = "button";
      b.innerHTML = `<img alt="" src="${src}"><div><i style="background:${hex};color:${hex}"></i>${hex}</div>`;
      b.title = name;
      b.addEventListener("click", () => show(hex));
      grid.appendChild(b);
      if (select) show(hex);
    };
    img.src = src;
  };
  SAMPLES.forEach((s, i) => add("media/" + s, s, i === 0));
  file.addEventListener("change", () => {
    const f = file.files && file.files[0];
    if (f) add(URL.createObjectURL(f), f.name, true);
  });
}

// ---------------------------------------------------------------------------

async function main() {
  try {
    const [s, a] = await Promise.all([load("site.wasm"), load("anim.wasm")]);
    S = s.ex;
    A = a.ex;
    // デモ用の作業領域(3 ページ = 192 KiB)を anim.wasm のメモリの後ろに足す
    base = A.memory.grow(3) * 65536;
    document.getElementById("wsize").textContent = `site.wasm ${kb(s.size)}`;
    document.getElementById("asize").textContent = `anim.wasm ${kb(a.size)}`;
    addEventListener("hashchange", render);
    render();
  } catch (e) {
    document.getElementById("main").innerHTML =
      `<h1>読み込めませんでした</h1><p>${esc(String(e))}</p><p>このサイトは WebAssembly を使います。内容は <a href="https://github.com/TatsuyaM2667/ame-shell">GitHub の README</a> でも読めます。</p>`;
  }
}
main();
