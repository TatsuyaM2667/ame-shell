// ホスト(ame-shell)と WASM ウィジェットが共有するメモリレイアウト。
// 両側がこの1ファイルを import するので、構造体の食い違いが起きない。
// 非網羅的(_)にしておく: 壊れた/悪意あるウィジェットが未知の値を書いてもホストは無視するだけ
pub const CmdKind = enum(u32) { rect = 1, grad = 2, border = 3, glass = 4, shadow = 5, text = 6, arc = 7, art = 8, clip = 9, wrap = 10, _ };

pub const Cmd = extern struct {
    kind: u32,
    x: f32,
    y: f32,
    w: f32,
    h: f32,
    r: f32,
    col: u32, // 0xRRGGBBAA
    col2: u32,
    a: f32,
    b: f32,
    str_ptr: u32, // ウィジェットのリニアメモリ上のアドレス
    str_len: u32,
    flags: u32, // text: bit0=bold, bit1-2=align(0左,1中,2右)
    _pad: [3]u32 = .{ 0, 0, 0 },
};

pub const Store = extern struct {
    year: i32 = 0,
    month: i32 = 1,
    mday: i32 = 1,
    wday: i32 = 0,
    hour: i32 = 0,
    min: i32 = 0,
    sec: i32 = 0,
    cpu: f32 = 0,
    mem: f32 = 0,
    temp: f32 = -1,
    volume: f32 = 0,
    muted: u32 = 0,
    brightness: f32 = -1,
    battery: f32 = -1,
    charging: u32 = 0,
    wifi_on: u32 = 0,
    bt_on: u32 = 0,
    dnd: u32 = 0,
    media_status: u32 = 0, // 0=無し 1=再生 2=一時停止
    media_pos: f32 = 0,
    media_len: f32 = 0,
    has_art: u32 = 0,
    accent: u32 = 0x7ab8ff,
    text: u32 = 0xeaf2ff,
    subtext: u32 = 0x9fb4d6,
    title_len: u32 = 0,
    title: [160]u8 = [_]u8{0} ** 160,
    artist_len: u32 = 0,
    artist: [160]u8 = [_]u8{0} ** 160,
    player_len: u32 = 0,
    player: [48]u8 = [_]u8{0} ** 48,
};

pub const Action = enum(u32) {
    media_toggle = 1,
    media_next = 2,
    media_prev = 3,
    set_volume = 4,
    set_brightness = 5,
    toggle_wifi = 6,
    toggle_bt = 7,
    toggle_dnd = 8,
    open_launcher = 9,
    mute = 10,
    _,
};

pub const PointerKind = enum(u32) { motion = 0, press = 1, release = 2, leave = 3, scroll_up = 4, scroll_down = 5, _ };
