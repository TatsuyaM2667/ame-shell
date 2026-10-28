// Wiki の項目の一覧: .{ スラッグ, 題, カテゴリ, 本文 }。カテゴリは最初に出てきた順に並ぶ。
const G = "Wayland とグラフィックス";
const R = "描画と画像処理";
const F = "文字と組版";
const M = "数学とアニメーション";
const O = "OS とシステム";
const L = "言語とツール";
const A = "音とメディア";

pub const items = .{
    .{ "wiki", "メインページ", "", @embedFile("index.md") },
    // Wayland とグラフィックス
    .{ "wiki/wayland", "Wayland", G, @embedFile("wayland.md") },
    .{ "wiki/compositor", "コンポジタ", G, @embedFile("compositor.md") },
    .{ "wiki/layer-shell", "layer-shell", G, @embedFile("layer-shell.md") },
    .{ "wiki/session-lock", "ext-session-lock", G, @embedFile("session-lock.md") },
    .{ "wiki/frame-callback", "フレームコールバック", G, @embedFile("frame-callback.md") },
    .{ "wiki/vsync", "垂直同期(VSync)", G, @embedFile("vsync.md") },
    .{ "wiki/river", "River", G, @embedFile("river.md") },
    .{ "wiki/egl", "EGL", G, @embedFile("egl.md") },
    .{ "wiki/opengl-es", "OpenGL ES", G, @embedFile("opengl-es.md") },
    .{ "wiki/shader", "シェーダ", G, @embedFile("shader.md") },
    .{ "wiki/fbo", "フレームバッファオブジェクト", G, @embedFile("fbo.md") },
    .{ "wiki/xkb", "XKB", G, @embedFile("xkb.md") },
    // 描画と画像処理
    .{ "wiki/sdf", "符号付き距離場(SDF)", R, @embedFile("sdf.md") },
    .{ "wiki/premultiplied-alpha", "乗算済みアルファ", R, @embedFile("premultiplied-alpha.md") },
    .{ "wiki/instancing", "インスタンス描画", R, @embedFile("instancing.md") },
    .{ "wiki/gaussian-blur", "ガウスぼかし", R, @embedFile("gaussian-blur.md") },
    .{ "wiki/kawase-blur", "Kawase ブラー", R, @embedFile("kawase-blur.md") },
    .{ "wiki/smooth-min", "smooth-min", R, @embedFile("smooth-min.md") },
    .{ "wiki/chromatic-aberration", "色収差", R, @embedFile("chromatic-aberration.md") },
    .{ "wiki/hsl", "HSL 色空間", R, @embedFile("hsl.md") },
    .{ "wiki/dominant-color", "主色抽出", R, @embedFile("dominant-color.md") },
    .{ "wiki/fbm", "fBm(非整数ブラウン運動)", R, @embedFile("fbm.md") },
    // 文字と組版
    .{ "wiki/freetype", "FreeType", F, @embedFile("freetype.md") },
    .{ "wiki/harfbuzz", "HarfBuzz", F, @embedFile("harfbuzz.md") },
    .{ "wiki/fontconfig", "fontconfig", F, @embedFile("fontconfig.md") },
    .{ "wiki/glyph-atlas", "グリフアトラス", F, @embedFile("glyph-atlas.md") },
    // 数学とアニメーション
    .{ "wiki/spring", "ばね-ダンパ系", M, @embedFile("spring.md") },
    .{ "wiki/damping-ratio", "減衰比", M, @embedFile("damping-ratio.md") },
    .{ "wiki/ode", "常微分方程式", M, @embedFile("ode.md") },
    .{ "wiki/euler-method", "オイラー法", M, @embedFile("euler-method.md") },
    .{ "wiki/symplectic", "シンプレクティック積分", M, @embedFile("symplectic.md") },
    .{ "wiki/cubic-bezier", "3 次ベジェ曲線", M, @embedFile("cubic-bezier.md") },
    .{ "wiki/easing", "イージング", M, @embedFile("easing.md") },
    .{ "wiki/fuzzy-matching", "あいまい検索", M, @embedFile("fuzzy-matching.md") },
    .{ "wiki/frecency", "frecency", M, @embedFile("frecency.md") },
    .{ "wiki/dwindle", "dwindle レイアウト", M, @embedFile("dwindle.md") },
    // OS とシステム
    .{ "wiki/epoll", "epoll", O, @embedFile("epoll.md") },
    .{ "wiki/kqueue", "kqueue", O, @embedFile("kqueue.md") },
    .{ "wiki/timerfd", "timerfd", O, @embedFile("timerfd.md") },
    .{ "wiki/inotify", "inotify", O, @embedFile("inotify.md") },
    .{ "wiki/evdev", "evdev", O, @embedFile("evdev.md") },
    .{ "wiki/ioctl", "ioctl", O, @embedFile("ioctl.md") },
    .{ "wiki/syscall", "システムコール", O, @embedFile("syscall.md") },
    .{ "wiki/sigsys", "SIGSYS", O, @embedFile("sigsys.md") },
    .{ "wiki/fork-exec", "fork と exec", O, @embedFile("fork-exec.md") },
    .{ "wiki/pipe", "パイプ", O, @embedFile("pipe.md") },
    .{ "wiki/unix-socket", "Unix ドメインソケット", O, @embedFile("unix-socket.md") },
    .{ "wiki/pam", "PAM", O, @embedFile("pam.md") },
    .{ "wiki/setuid", "setuid", O, @embedFile("setuid.md") },
    .{ "wiki/dbus", "D-Bus", O, @embedFile("dbus.md") },
    .{ "wiki/xdg-runtime-dir", "XDG_RUNTIME_DIR", O, @embedFile("xdg-runtime-dir.md") },
    .{ "wiki/sysctl", "sysctl", O, @embedFile("sysctl.md") },
    .{ "wiki/posix-sh", "POSIX シェル", O, @embedFile("posix-sh.md") },
    // 言語とツール
    .{ "wiki/zig", "Zig", L, @embedFile("zig.md") },
    .{ "wiki/odin", "Odin", L, @embedFile("odin.md") },
    .{ "wiki/webassembly", "WebAssembly", L, @embedFile("webassembly.md") },
    .{ "wiki/wasm3", "wasm3", L, @embedFile("wasm3.md") },
    .{ "wiki/wasi", "WASI", L, @embedFile("wasi.md") },
    .{ "wiki/c-abi", "C ABI", L, @embedFile("c-abi.md") },
    .{ "wiki/translate-c", "translate-c", L, @embedFile("translate-c.md") },
    .{ "wiki/cross-compilation", "クロスコンパイル", L, @embedFile("cross-compilation.md") },
    .{ "wiki/musl", "musl", L, @embedFile("musl.md") },
    // 音とメディア
    .{ "wiki/mpris", "MPRIS", A, @embedFile("mpris.md") },
    .{ "wiki/lrc", "LRC 形式", A, @embedFile("lrc.md") },
    .{ "wiki/pipewire", "PipeWire", A, @embedFile("pipewire.md") },
    .{ "wiki/libmpv", "libmpv", A, @embedFile("libmpv.md") },
    .{ "wiki/va-api", "VA-API", A, @embedFile("va-api.md") },
    .{ "wiki/a2dp-hfp", "A2DP と HFP", A, @embedFile("a2dp-hfp.md") },
};
