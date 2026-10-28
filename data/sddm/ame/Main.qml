// ame-shell の SDDM テーマ(ログイン画面)。Super+L のロック画面と同じ見た目:
// 壁紙(ぼかし・暗め)の上に、光る大きな時計・日付・ガラスの丸い入力欄。
// QML は ame-shell では使わない決まりだが、SDDM のテーマは QML でしか書けないので、ここだけの例外。
// 背景は scripts/sddm-theme.sh がその人の ame-shell の壁紙から作る background.jpg。Qt6 の SDDM 用。
import QtQuick
import QtQuick.Effects

Rectangle {
    id: root
    width: 1920
    height: 1080
    color: "#050a18"

    readonly property color accent: config.accent || "#7ab8ff"
    readonly property color textColor: "#eef3ff"
    readonly property color subText: "#a9b6d6"
    readonly property color errColor: "#ff6b81"
    readonly property string fontFamily: config.font || "Noto Sans CJK JP"
    // 画面の大きさに合わせて全体を拡大縮小(基準は 1080p)
    readonly property real s: Math.max(0.6, Math.min(width / 1920, height / 1080) * 1.0)

    property var users: []
    property var sessions: []
    property int userIndex: Math.max(0, userModel.lastIndex)
    property int sessionIndex: Math.max(0, sessionModel.lastIndex)
    property bool busy: false
    property string message: ""

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

    // ---- 背景: 壁紙をぼかして少し暗く ----
    Image {
        id: wall
        anchors.fill: parent
        source: config.background || "background.jpg"
        fillMode: Image.PreserveAspectCrop
        asynchronous: false
        visible: false
    }
    MultiEffect {
        anchors.fill: parent
        source: wall
        blurEnabled: true
        blurMax: 48
        blur: 0.85
        brightness: -0.22
        saturation: 0.05
        visible: wall.status === Image.Ready
    }
    // 上下の陰り(時計と入力欄を読みやすく)
    Rectangle {
        anchors.fill: parent
        gradient: Gradient {
            GradientStop { position: 0.0; color: "#73050a18" }
            GradientStop { position: 0.5; color: "#4d050a18" }
            GradientStop { position: 1.0; color: "#b3050a18" }
        }
    }

    // ---- 時計と日付 ----
    Item {
        id: clockBox
        anchors.horizontalCenter: parent.horizontalCenter
        y: parent.height * 0.19
        width: clock.width
        height: clock.height

        Text {
            id: clock
            anchors.centerIn: parent
            color: root.textColor
            font.family: root.fontFamily
            font.pixelSize: 168 * root.s
            font.weight: Font.Bold
            text: Qt.formatTime(new Date(), "hh:mm")
            layer.enabled: true
            layer.effect: MultiEffect {
                shadowEnabled: true
                shadowColor: Qt.lighter(root.accent, 1.3)
                shadowBlur: 1.0
                shadowOpacity: 0.85
                shadowHorizontalOffset: 0
                shadowVerticalOffset: 0
            }
        }
    }
    Text {
        id: date
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.top: clockBox.bottom
        anchors.topMargin: 6 * root.s
        color: root.subText
        font.family: root.fontFamily
        font.pixelSize: 30 * root.s
        layer.enabled: true
        layer.effect: MultiEffect { shadowEnabled: true; shadowColor: "#000000"; shadowBlur: 0.6; shadowOpacity: 0.7; shadowVerticalOffset: 1 }
        text: {
            var d = new Date()
            var w = ["日", "月", "火", "水", "木", "金", "土"][d.getDay()]
            return (d.getMonth() + 1) + "月" + d.getDate() + "日(" + w + ")"
        }
    }
    Timer {
        interval: 1000; running: true; repeat: true
        onTriggered: {
            clock.text = Qt.formatTime(new Date(), "hh:mm")
            var d = new Date()
            var w = ["日", "月", "火", "水", "木", "金", "土"][d.getDay()]
            date.text = (d.getMonth() + 1) + "月" + d.getDate() + "日(" + w + ")"
        }
    }

    // ---- ユーザー名(複数いれば ‹ › で切り替え)----
    Row {
        id: userRow
        anchors.horizontalCenter: parent.horizontalCenter
        y: parent.height * 0.555
        spacing: 18 * root.s
        Text {
            visible: root.users.length > 1
            text: "‹"
            color: prevArea.containsMouse ? root.textColor : root.subText
            font.pixelSize: 34 * root.s
            anchors.verticalCenter: parent.verticalCenter
            MouseArea {
                id: prevArea; anchors.fill: parent; anchors.margins: -10; hoverEnabled: true
                onClicked: { root.userIndex = (root.userIndex + root.users.length - 1) % root.users.length; pw.forceActiveFocus() }
            }
        }
        Text {
            text: root.userName
            color: root.textColor
            font.family: root.fontFamily
            font.pixelSize: 26 * root.s
            layer.enabled: true
            layer.effect: MultiEffect { shadowEnabled: true; shadowColor: "#000000"; shadowBlur: 0.6; shadowOpacity: 0.7; shadowVerticalOffset: 1 }
            font.weight: Font.Medium
            anchors.verticalCenter: parent.verticalCenter
        }
        Text {
            visible: root.users.length > 1
            text: "›"
            color: nextArea.containsMouse ? root.textColor : root.subText
            font.pixelSize: 34 * root.s
            anchors.verticalCenter: parent.verticalCenter
            MouseArea {
                id: nextArea; anchors.fill: parent; anchors.margins: -10; hoverEnabled: true
                onClicked: { root.userIndex = (root.userIndex + 1) % root.users.length; pw.forceActiveFocus() }
            }
        }
    }

    // ---- ガラスの丸い入力欄 ----
    Item {
        id: field
        width: 520 * root.s
        height: 76 * root.s
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.top: userRow.bottom
        anchors.topMargin: 20 * root.s

        // 失敗したら左右に揺らす
        property real shake: 0
        transform: Translate { x: field.shake }
        SequentialAnimation {
            id: shakeAnim
            NumberAnimation { target: field; property: "shake"; to: -14 * root.s; duration: 50 }
            NumberAnimation { target: field; property: "shake"; to: 12 * root.s; duration: 70 }
            NumberAnimation { target: field; property: "shake"; to: -8 * root.s; duration: 70 }
            NumberAnimation { target: field; property: "shake"; to: 4 * root.s; duration: 60 }
            NumberAnimation { target: field; property: "shake"; to: 0; duration: 60 }
        }

        Rectangle {
            id: glass
            anchors.fill: parent
            radius: height / 2
            color: "#590c1630"
            border.width: 1.5
            border.color: root.message !== "" ? root.errColor
                        : pw.activeFocus ? Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.75)
                        : "#55a9b6d6"
            Behavior on border.color { ColorAnimation { duration: 180 } }
            // 上側のハイライト(ガラスの縁の光)
            Rectangle {
                anchors { left: parent.left; right: parent.right; top: parent.top; margins: parent.radius * 0.6 }
                anchors.topMargin: 2
                height: 1
                color: "#33ffffff"
            }
        }

        TextInput {
            id: pw
            anchors.fill: parent
            anchors.leftMargin: 34 * root.s
            anchors.rightMargin: 34 * root.s
            verticalAlignment: TextInput.AlignVCenter
            horizontalAlignment: TextInput.AlignHCenter
            echoMode: TextInput.Password
            passwordCharacter: "●"
            color: root.textColor
            font.family: root.fontFamily
            font.pixelSize: 24 * root.s
            font.letterSpacing: 4 * root.s
            selectionColor: root.accent
            clip: true
            focus: true
            enabled: !root.busy
            onTextEdited: root.message = ""
            Keys.onReturnPressed: root.tryLogin()
            Keys.onEnterPressed: root.tryLogin()
            Keys.onEscapePressed: text = ""
        }
        Text {
            anchors.centerIn: parent
            visible: pw.text.length === 0
            text: root.busy ? "ログインしています…" : (root.message !== "" ? root.message : "パスワード")
            color: root.message !== "" ? root.errColor : root.subText
            font.family: root.fontFamily
            font.pixelSize: 21 * root.s
            opacity: root.busy ? 0.9 : 0.75
        }
    }
    Text {
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.top: field.bottom
        anchors.topMargin: 14 * root.s
        visible: keyboard.capsLock
        text: "Caps Lock がオンです"
        color: "#ffd58a"
        font.family: root.fontFamily
        font.pixelSize: 17 * root.s
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

    // ---- 下: セッション(クリックで切り替え)と電源 ----
    component Pill: Rectangle {
        property alias label: lbl.text
        signal clicked()
        height: 44 * root.s
        width: lbl.implicitWidth + 40 * root.s
        radius: height / 2
        color: area.containsMouse ? "#4d1a2846" : "#330c1630"
        border.width: 1
        border.color: area.containsMouse ? Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.6) : "#40a9b6d6"
        Behavior on color { ColorAnimation { duration: 140 } }
        Text {
            id: lbl
            anchors.centerIn: parent
            color: area.containsMouse ? root.textColor : root.subText
            font.family: root.fontFamily
            font.pixelSize: 17 * root.s
        }
        MouseArea { id: area; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: parent.clicked() }
    }

    Row {
        anchors.left: parent.left
        anchors.bottom: parent.bottom
        anchors.margins: 36 * root.s
        spacing: 12 * root.s
        Pill {
            visible: root.sessions.length > 0
            label: "セッション: " + root.sessionName + (root.sessions.length > 1 ? "  ⇄" : "")
            onClicked: { if (root.sessions.length > 1) root.sessionIndex = (root.sessionIndex + 1) % root.sessions.length; pw.forceActiveFocus() }
        }
    }
    Row {
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        anchors.margins: 36 * root.s
        spacing: 12 * root.s
        Pill { visible: sddm.canSuspend; label: "スリープ"; onClicked: sddm.suspend() }
        Pill { visible: sddm.canReboot; label: "再起動"; onClicked: sddm.reboot() }
        Pill { visible: sddm.canPowerOff; label: "電源オフ"; onClicked: sddm.powerOff() }
    }

    Component.onCompleted: pw.forceActiveFocus()
}
