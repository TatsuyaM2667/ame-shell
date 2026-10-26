// 全ての C ライブラリをここで一度だけ取り込む(@cImport を複数箇所に書くと
// 型が別物として扱われ、モジュール間で受け渡せなくなるため)。
pub usingnamespace @cImport({
    @cDefine("_GNU_SOURCE", "1");
    // libc / Linux
    @cInclude("stdlib.h");
    @cInclude("string.h");
    @cInclude("unistd.h");
    @cInclude("fcntl.h");
    @cInclude("time.h");
    @cInclude("signal.h");
    @cInclude("dirent.h");
    @cInclude("dlfcn.h");
    @cInclude("sys/mman.h");
    @cInclude("sys/epoll.h");
    @cInclude("sys/timerfd.h");
    @cInclude("sys/signalfd.h");
    @cInclude("sys/inotify.h");
    @cInclude("sys/socket.h");
    @cInclude("sys/un.h");
    @cInclude("sys/wait.h");
    @cInclude("sys/stat.h");
    @cInclude("sys/resource.h");
    @cInclude("sys/statvfs.h");
    @cInclude("sys/ioctl.h");
    @cInclude("locale.h");
    // Wayland
    @cInclude("wayland-client.h");
    @cInclude("wayland-egl.h");
    @cInclude("wlr-layer-shell-unstable-v1-client-protocol.h");
    @cInclude("river-status-unstable-v1-client-protocol.h");
    @cInclude("river-control-unstable-v1-client-protocol.h");
    @cInclude("xdg-shell-client-protocol.h");
    @cInclude("ext-session-lock-v1-client-protocol.h");
    @cInclude("cursor-shape-v1-client-protocol.h");
    @cInclude("idle-inhibit-unstable-v1-client-protocol.h");
    @cInclude("river-window-management-v1-client-protocol.h");
    @cInclude("river-xkb-bindings-v1-client-protocol.h");
    @cInclude("river-layer-shell-v1-client-protocol.h");
    @cInclude("xkbcommon/xkbcommon.h");
    // GPU
    @cInclude("EGL/egl.h");
    @cInclude("EGL/eglext.h");
    @cInclude("GLES3/gl3.h");
    // テキスト
    @cInclude("ft2build.h");
    @cInclude("freetype/freetype.h");
    @cInclude("freetype/ftmodapi.h");
    @cInclude("hb.h");
    @cInclude("hb-ft.h");
    @cInclude("fontconfig/fontconfig.h");
    // D-Bus(通知デーモン/MPRIS)
    @cInclude("dbus/dbus.h");
    // WASM ランタイムと画像
    @cInclude("wasm3/source/wasm3.h");
    @cInclude("stb_image.h");
    @cInclude("stdio.h");
    @cInclude("nanosvg.h");
    @cInclude("nanosvgrast.h");
});
