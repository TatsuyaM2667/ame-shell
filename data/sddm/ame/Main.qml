// ame-shell の SDDM テーマ(ログイン画面)。Super+L のロック画面(src/lock.zig)と同じ見た目:
// ぼかした壁紙の上に、アクセント色で光る大きな時計・日付・丸いユーザーの写真・ガラスの丸い入力欄、
// 入力した文字は ● ではなくアクセント色の丸で表す。大きさ・位置は lock.zig と同じ数値(論理 px)。
// QML は ame-shell では使わない決まりだが、SDDM のテーマは QML でしか書けないので、ここだけの例外。
//
// 背景・写真・アクセント色は、ame-shell がユーザーごとの置き場(theme.conf の sharedir/<ユーザー名>/)に
// 書き出したものを使う(src/sddmshare.zig): backdrop.bmp・avatar.bmp・state(accent= と tinted=)。
// ロックしたときに書き出した背景(tinted=1)は、ロック画面の背景そのもの。無ければ background.jpg
// (scripts/sddm-theme.sh が壁紙から作る)をぼかし、それも無ければオーロラ風の背景。
// state を読むため、SDDM の設定で QML_XHR_ALLOW_FILE_READ=1 を渡している(scripts/sddm-theme.sh)。
import QtQuick
import QtQuick.Effects

Rectangle {
    id: root
    width: 1920
    height: 1080
    color: "#050a18"

    readonly property color textColor: "#eaf2ff"
    readonly property color subText: "#a9b6d6"
    readonly property color errColor: "#ff8a9a"
    readonly property string fontFamily: config.font || "Noto Sans CJK JP"
    readonly property string shareDir: config.sharedir || "/var/lib/ame-shell/greeter"
    // ロック画面と同じ論理 px で描く。高 DPI を Qt が拡大しない画面では、ame-shell と同じく大きな画面ほど拡大
    readonly property real k: Screen.devicePixelRatio > 1 ? 1 : Math.max(1, Math.floor(height / 1200 * 4) / 4)

    property var users: []
    property var sessions: []
    property int userIndex: Math.max(0, userModel.lastIndex)
    property int sessionIndex: Math.max(0, sessionModel.lastIndex)
    property bool busy: false
    property string message: ""

    // ユーザーごとの見た目(ame-shell が書き出したもの)
    property color accent: config.accent || "#7ab8ff"
    property bool tinted: false
    property bool hasShared: false

    // モデルの名前を配列に集める(Qt6 の SDDM ではモデルを index で読むより確実)
    Repeater {
        model: userModel
        delegate: Item { Component.onCompleted: { var a = root.users.slice(); a[index] = model.name; root.users = a } }
    }
    Repeater {
        model: sessionModel
        delegate: Item { Component.onCompleted: { var a = root.sessions.slice(); a[index] = model.name; root.sessions = a } }
    }
    readonly property string userName: users.length > userIndex ? users[userIndex] : (userModel.lastUser || "")
    readonly property string sessionName: sessions.length > sessionIndex ? sessions[sessionIndex] : ""
    readonly property string userDir: "file://" + shareDir + "/" + userName + "/"

    // state("accent=#rrggbb" / "tinted=1")を読む
    function loadState() {
        root.accent = config.accent || "#7ab8ff"
        root.tinted = false
        if (userName === "") return
        var x = new XMLHttpRequest()
        x.open("GET", userDir + "state", false)
        try { x.send(null) } catch (e) { return }
        var lines = (x.responseText || "").split("\n")
        for (var i = 0; i < lines.length; i++) {
            var kv = lines[i].split("=")
            if (kv.length !== 2) continue
            if (kv[0] === "accent" && /^#[0-9a-fA-F]{6}$/.test(kv[1])) root.accent = kv[1]
            if (kv[0] === "tinted") root.tinted = kv[1] === "1"
        }
    }
    onUserNameChanged: loadState()

    // ---- 背景 ----
    // 1. ame-shell が書き出したもの(ロック画面の背景、または ぼかした壁紙)
    Image {
        id: shared
        anchors.fill: parent
        source: root.userName !== "" ? root.userDir + "backdrop.bmp" : ""
        fillMode: Image.PreserveAspectCrop
        smooth: true
        cache: false
        visible: status === Image.Ready
        onStatusChanged: root.hasShared = status === Image.Ready
    }
    // ぼかしただけの壁紙には、ロック画面のガラスの色味(紺 25%)を重ねる
    Rectangle {
        anchors.fill: parent
        visible: shared.visible && !root.tinted
        color: "#40050a18"
    }
    // 2. 壁紙から作った background.jpg をぼかす
    Image {
        id: wall
        anchors.fill: parent
        source: root.hasShared ? "" : (config.background || "background.jpg")
        fillMode: Image.PreserveAspectCrop
        visible: false
    }
    MultiEffect {
        anchors.fill: parent
        source: wall
        blurEnabled: true
        blurMax: 64
        blur: 1.0
        brightness: -0.18
        visible: !root.hasShared && wall.status === Image.Ready
    }
    // 3. どちらも無い: ame-shell のオーロラ風(紺の空に紫・青・緑の帯、ぼかし)
    Item {
        id: aurora
        anchors.fill: parent
        visible: false
        Rectangle { anchors.fill: parent; color: "#0b1024" }
        Repeater {
            model: 9
            Rectangle {
                x: root.width * (index / 9) - root.width * 0.02
                y: root.height * 0.12
                width: root.width * 0.12
                height: root.height * 0.48
                radius: width / 2
                opacity: 0.55 + 0.25 * Math.sin(index * 1.7)
                gradient: Gradient {
                    GradientStop { position: 0.0; color: "#00000000" }
                    GradientStop { position: 0.35; color: index % 3 === 0 ? "#6a5acd" : "#3f5fd0" }
                    GradientStop { position: 0.7; color: "#2c9c86" }
                    GradientStop { position: 1.0; color: "#00000000" }
                }
            }
        }
    }
    MultiEffect {
        anchors.fill: parent
        source: aurora
        blurEnabled: true
        blurMax: 64
        blur: 1.0
        visible: !root.hasShared && wall.status !== Image.Ready
    }

    // ---- 時計と日付(lock.zig: 時計 112px の太字・アクセントの光、ベースラインは高さの 36%)----
    Text {
        id: clock
        anchors.horizontalCenter: parent.horizontalCenter
        y: root.height * 0.36 - baselineOffset
        color: root.textColor
        font.family: root.fontFamily
        font.pixelSize: 112 * root.k
        font.weight: Font.Bold
        text: Qt.formatTime(new Date(), "hh:mm")
        layer.enabled: true
        layer.effect: MultiEffect {
            shadowEnabled: true
            shadowColor: root.accent
            shadowBlur: 1.0
            shadowOpacity: 1.0               // lock.zig: glow 14px・アクセントの 50%(Qt の影は薄く出るので強めに)
            blurMax: 40
            shadowHorizontalOffset: 0
            shadowVerticalOffset: 0
        }
    }
    Text {
        id: date
        anchors.horizontalCenter: parent.horizontalCenter
        y: root.height * 0.36 + 46 * root.k - baselineOffset
        color: root.subText
        font.family: root.fontFamily
        font.pixelSize: 20 * root.k
        text: root.dateText()
    }
    function dateText() {
        var d = new Date()
        var w = ["日", "月", "火", "水", "木", "金", "土"][d.getDay()]
        return (d.getMonth() + 1) + "月" + d.getDate() + "日(" + w + ")"
    }
    Timer {
        interval: 1000; running: true; repeat: true
        onTriggered: { clock.text = Qt.formatTime(new Date(), "hh:mm"); date.text = root.dateText() }
    }

    // ---- 入力欄の位置(lock.zig: 幅 340・高さ 56、上端は高さの 58%)----
    readonly property real fw: 340 * k
    readonly property real fh: 56 * k
    readonly property real fy: height * 0.58

    // ---- ユーザーの写真(64px の丸、アクセントの縁)。無ければ頭文字 ----
    Item {
        id: avatarBox
        readonly property real az: 64 * root.k
        width: az; height: az
        x: root.width / 2 - az / 2
        y: root.fy - az - 18 * root.k
        Rectangle {
            anchors.fill: parent
            anchors.margins: -1 * root.k
            radius: width / 2
            color: "#1a2846"
            border.width: 2 * root.k
            border.color: Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.8)
        }
        Image {
            id: avatarImg
            anchors.fill: parent
            source: root.userName !== "" ? root.userDir + "avatar.bmp" : ""
            fillMode: Image.PreserveAspectCrop
            cache: false
            visible: false
        }
        Rectangle { id: avatarMask; anchors.fill: parent; radius: width / 2; visible: false; layer.enabled: true }
        MultiEffect {
            anchors.fill: parent
            source: avatarImg
            maskEnabled: true
            maskSource: avatarMask
            visible: avatarImg.status === Image.Ready
        }
        Text {
            anchors.centerIn: parent
            visible: avatarImg.status !== Image.Ready
            text: root.userName.length > 0 ? root.userName.charAt(0).toUpperCase() : ""
            color: root.textColor
            font.family: root.fontFamily
            font.pixelSize: 28 * root.k
            font.weight: Font.Bold
        }
        // 複数のユーザーがいれば、写真の左右の ‹ › で切り替え
        Text {
            visible: root.users.length > 1
            anchors.right: parent.left; anchors.rightMargin: 18 * root.k
            anchors.verticalCenter: parent.verticalCenter
            text: "‹"; font.pixelSize: 30 * root.k
            color: prevArea.containsMouse ? root.textColor : root.subText
            MouseArea {
                id: prevArea; anchors.fill: parent; anchors.margins: -10; hoverEnabled: true
                onClicked: { root.userIndex = (root.userIndex + root.users.length - 1) % root.users.length; pw.forceActiveFocus() }
            }
        }
        Text {
            visible: root.users.length > 1
            anchors.left: parent.right; anchors.leftMargin: 18 * root.k
            anchors.verticalCenter: parent.verticalCenter
            text: "›"; font.pixelSize: 30 * root.k
            color: nextArea.containsMouse ? root.textColor : root.subText
            MouseArea {
                id: nextArea; anchors.fill: parent; anchors.margins: -10; hoverEnabled: true
                onClicked: { root.userIndex = (root.userIndex + 1) % root.users.length; pw.forceActiveFocus() }
            }
        }
    }

    // ---- ガラスの丸い入力欄 ----
    Item {
        id: field
        width: root.fw
        height: root.fh
        x: root.width / 2 - width / 2 + shake
        y: root.fy

        // 失敗したら左右に揺らす(lock.zig の shake と同じ)
        property real shake: 0
        SequentialAnimation {
            id: shakeAnim
            NumberAnimation { target: field; property: "shake"; to: -14 * root.k; duration: 50 }
            NumberAnimation { target: field; property: "shake"; to: 12 * root.k; duration: 70 }
            NumberAnimation { target: field; property: "shake"; to: -8 * root.k; duration: 70 }
            NumberAnimation { target: field; property: "shake"; to: 4 * root.k; duration: 60 }
            NumberAnimation { target: field; property: "shake"; to: 0; duration: 60 }
        }

        // 影
        RectangularShadow {
            anchors.fill: parent
            anchors.topMargin: 8 * root.k
            radius: height / 2
            blur: 22 * root.k
            color: "#80000000"
        }
        // ガラス: 背景が透けて少し明るく、縁は白く細い光
        Rectangle {
            anchors.fill: parent
            radius: height / 2
            color: "#1f6c74c8"           // lock.zig の glassStrong に近い、紺がかった薄いガラス
            border.width: 1
            border.color: root.message !== "" ? root.errColor : "#40ffffff"
            Behavior on border.color { ColorAnimation { duration: 180 } }
        }
        // ログイン中はアクセントの縁(lock.zig の busy)
        Rectangle {
            anchors.fill: parent
            radius: height / 2
            color: "transparent"
            visible: root.busy
            border.width: 1.5 * root.k
            border.color: Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.8)
        }

        TextInput {
            id: pw
            anchors.fill: parent
            echoMode: TextInput.Password
            color: "transparent"           // 文字は出さず、下の丸で数だけ見せる
            selectionColor: "transparent"
            cursorVisible: false
            cursorDelegate: Item {}
            focus: true
            enabled: !root.busy
            onTextEdited: root.message = ""
            Keys.onReturnPressed: root.tryLogin()
            Keys.onEnterPressed: root.tryLogin()
            Keys.onEscapePressed: text = ""
        }
        // 文字数ぶんの丸がポップする(間隔 18px、半径 5px、アクセントを明るくした色)
        Row {
            anchors.centerIn: parent
            spacing: 8 * root.k
            Repeater {
                model: Math.min(pw.text.length, 24)
                Rectangle {
                    width: 10 * root.k; height: width; radius: width / 2
                    color: Qt.lighter(root.accent, 1.3)
                    scale: 0
                    Component.onCompleted: scale = 1
                    Behavior on scale { NumberAnimation { duration: 160; easing.type: Easing.OutBack } }
                }
            }
        }
        // 何も入力していないときはユーザー名(lock.zig と同じ)
        Text {
            anchors.centerIn: parent
            visible: pw.text.length === 0 && !root.busy
            text: root.userName !== "" ? root.userName : "パスワード"
            color: Qt.rgba(root.subText.r, root.subText.g, root.subText.b, 0.8)
            font.family: root.fontFamily
            font.pixelSize: 15 * root.k
        }
    }
    // メッセージ(失敗・ログイン中・Caps Lock)。入力欄の下 34px
    Text {
        anchors.horizontalCenter: parent.horizontalCenter
        y: root.fy + root.fh + 34 * root.k - baselineOffset
        text: root.message !== "" ? root.message
            : root.busy ? "ログインしています…"
            : keyboard.capsLock ? "Caps Lock がオンです" : ""
        color: root.message !== "" ? root.errColor : keyboard.capsLock && !root.busy ? "#ffd58a" : root.subText
        font.family: root.fontFamily
        font.pixelSize: 14 * root.k
    }

    function tryLogin() {
        if (root.busy || root.userName === "") return
        root.busy = true
        root.message = ""
        sddm.login(root.userName, pw.text, root.sessionIndex)
    }
    Connections {
        target: sddm
        function onLoginFailed() {
            root.busy = false
            pw.text = ""
            root.message = "パスワードが違います"
            shakeAnim.restart()
            pw.forceActiveFocus()
        }
        function onLoginSucceeded() { root.busy = false }
    }

    // ---- 下の隅: セッション(クリックで切り替え)と電源。ロック画面には無いので控えめに ----
    component Pill: Rectangle {
        property alias label: lbl.text
        signal clicked()
        height: 34 * root.k
        width: lbl.implicitWidth + 30 * root.k
        radius: height / 2
        color: area.containsMouse ? "#26dfe8ff" : "#14dfe8ff"
        border.width: 1
        border.color: area.containsMouse ? Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.6) : "#30ffffff"
        Behavior on color { ColorAnimation { duration: 140 } }
        Text {
            id: lbl
            anchors.centerIn: parent
            color: area.containsMouse ? root.textColor : root.subText
            font.family: root.fontFamily
            font.pixelSize: 13 * root.k
        }
        MouseArea { id: area; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: parent.clicked() }
    }

    Row {
        anchors.left: parent.left
        anchors.bottom: parent.bottom
        anchors.margins: 24 * root.k
        spacing: 10 * root.k
        Pill {
            visible: root.sessions.length > 0
            label: root.sessionName + (root.sessions.length > 1 ? "  ⇄" : "")
            onClicked: { if (root.sessions.length > 1) root.sessionIndex = (root.sessionIndex + 1) % root.sessions.length; pw.forceActiveFocus() }
        }
    }
    Row {
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        anchors.margins: 24 * root.k
        spacing: 10 * root.k
        Pill { visible: sddm.canSuspend; label: "スリープ"; onClicked: sddm.suspend() }
        Pill { visible: sddm.canReboot; label: "再起動"; onClicked: sddm.reboot() }
        Pill { visible: sddm.canPowerOff; label: "電源オフ"; onClicked: sddm.powerOff() }
    }

    Component.onCompleted: { loadState(); pw.forceActiveFocus() }
}
