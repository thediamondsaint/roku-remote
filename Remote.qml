import Quickshell
import Quickshell.Io
import QtQuick
import QtQuick.Controls
import qs.Commons

// Roku remote (floating window). Toggle: omarchy-shell shell toggle charles.roku-remote '{}'
// Talks to the Roku's ECP API (http://<ip>:8060) directly for key presses, and uses the
// bundled bin/roku for discovery / device info.
Item {
  id: root

  property string omarchyPath: Quickshell.env("OMARCHY_PATH")
  property var shell: null
  property var manifest: null

  property bool opened: false
  property bool typing: false
  property string typed: ""
  property bool limited: false
  property bool unreachable: false
  property string ip: ""
  property string deviceName: ""
  property string power: ""
  property string activeApp: ""
  property string flashKey: ""
  property string notice: ""
  property var devices: []
  property var apps: []

  // Bundled CLI next to this file (bin/roku); falls back to ~/.local/bin/roku.
  readonly property string rokuBin: {
    var u = Qt.resolvedUrl("bin/roku").toString()
    return u.indexOf("file://") === 0 ? decodeURIComponent(u.slice(7)) : Quickshell.env("HOME") + "/.local/bin/roku"
  }

  // Used when the TV won't list its apps (Limited mode). Well-known channel ids.
  readonly property var fallbackApps: [
    { id: "12", name: "Netflix" }, { id: "837", name: "YouTube" },
    { id: "13", name: "Prime Video" }, { id: "2285", name: "Hulu" },
    { id: "291097", name: "Disney+" }, { id: "61322", name: "Max" },
    { id: "13535", name: "Plex" }, { id: "22297", name: "Spotify" },
    { id: "551012", name: "Apple TV" }, { id: "593099", name: "Peacock" },
    { id: "31440", name: "Paramount+" }, { id: "41468", name: "Tubi" }
  ]
  readonly property var pinned: ["netflix", "youtube", "prime video", "hulu", "disney+", "disney plus",
                                 "max", "plex", "spotify", "apple tv", "peacock", "paramount+"]

  function glyph(cp) { return String.fromCodePoint(cp) }

  // ---- lifecycle -----------------------------------------------------------
  function open(payloadJson) {
    root.opened = true
    root.typing = false
    root.typed = ""
    root.notice = ""
    root.refresh()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }
  function close() { root.opened = false }
  function dismiss() {
    root.opened = false
    if (root.shell && typeof root.shell.hide === "function")
      root.shell.hide((root.manifest && root.manifest.id) || "charles.roku-remote")
  }
  function toggle() {
    if (root.opened) root.dismiss()
    else root.open("{}")
  }

  // ---- device info ---------------------------------------------------------
  function refresh() {
    infoProc.command = root.ip ? [root.rokuBin, "-d", root.ip, "info"] : [root.rokuBin, "info"]
    infoProc.running = true
  }

  function sortApps(list) {
    var rank = function(n) {
      var i = root.pinned.indexOf((n || "").toLowerCase())
      return i < 0 ? 1000 : i
    }
    return list.slice().sort(function(a, b) {
      var d = rank(a.name) - rank(b.name)
      return d !== 0 ? d : (a.name || "").localeCompare(b.name || "")
    })
  }

  function applyInfo(text) {
    var d
    try { d = JSON.parse(text) } catch (e) {
      root.unreachable = true
      return
    }
    root.unreachable = false
    root.ip = d.ip
    root.deviceName = d.name || d.ip
    root.power = d.power || ""
    root.activeApp = d.app || ""
    root.limited = d.limited === true
    root.devices = d.devices || []
    var listed = d.apps && d.apps.length > 0
    root.apps = root.sortApps(listed ? d.apps : root.fallbackApps)
  }

  function cycleDevice() {
    if (root.devices.length < 2) return
    var idx = 0
    for (var i = 0; i < root.devices.length; i++)
      if (root.devices[i].ip === root.ip) idx = i
    root.ip = root.devices[(idx + 1) % root.devices.length].ip
    root.apps = []
    root.refresh()
  }

  // ---- sending -------------------------------------------------------------
  function post(path, onDone) {
    if (!root.ip) return
    var x = new XMLHttpRequest()
    x.onreadystatechange = function() {
      if (x.readyState !== XMLHttpRequest.DONE) return
      if (x.status === 403) root.limited = true
      else if (x.status === 0) root.unreachable = true
      else if (x.status === 200) { root.unreachable = false; if (path.indexOf("/keypress/") === 0) root.limited = false }
      if (onDone) onDone(x.status)
    }
    x.open("POST", "http://" + root.ip + ":8060" + path)
    x.send("")
  }

  function press(key) {
    root.flashKey = key
    flashTimer.restart()
    root.post("/keypress/" + key)
  }

  function launch(app) {
    if (!app) return
    root.notice = "Launching " + app.name + "…"
    noticeTimer.restart()
    root.post("/launch/" + app.id, function(status) {
      if (status === 200) root.activeApp = app.name
      else root.notice = "Couldn't launch " + app.name
    })
  }

  function togglePower() {
    root.press(root.power === "PowerOn" ? "PowerOff" : "PowerOn")
  }

  // ---- keyboard ------------------------------------------------------------
  function handleKey(event) {
    var k = event.key
    var t = event.text
    var rep = event.isAutoRepeat
    if (event.modifiers & (Qt.ControlModifier | Qt.AltModifier | Qt.MetaModifier)) return false

    if (root.typing) {
      if (k === Qt.Key_Escape) { root.typing = false; return true }
      if (k === Qt.Key_Backspace) { root.typed = root.typed.slice(0, -1); root.press("Backspace"); return true }
      if (k === Qt.Key_Return || k === Qt.Key_Enter) { root.typed = ""; root.press("Enter"); return true }
      if (t && t.length === 1 && t.charCodeAt(0) >= 32 && t.charCodeAt(0) !== 127) {
        root.typed += t
        root.post("/keypress/Lit_" + encodeURIComponent(t))
        return true
      }
      return true
    }

    if (k === Qt.Key_Escape) { root.dismiss(); return true }
    if (k === Qt.Key_Tab) { if (!rep) root.cycleDevice(); return true }
    if (k === Qt.Key_Up || t === "k") { root.press("Up"); return true }
    if (k === Qt.Key_Down || t === "j") { root.press("Down"); return true }
    if (k === Qt.Key_Left || t === "h") { root.press("Left"); return true }
    if (k === Qt.Key_Right || t === "l") { root.press("Right"); return true }
    if (t === "+" || t === "=") { root.press("VolumeUp"); return true }
    if (t === "-" || t === "_") { root.press("VolumeDown"); return true }
    if (rep) return true
    if (k === Qt.Key_Return || k === Qt.Key_Enter) { root.press("Select"); return true }
    if (k === Qt.Key_Backspace || t === "b") { root.press("Back"); return true }
    if (k === Qt.Key_Home || t === "g") { root.press("Home"); return true }
    if (k === Qt.Key_Space) { root.press("Play"); return true }
    if (t === ",") { root.press("Rev"); return true }
    if (t === ".") { root.press("Fwd"); return true }
    if (t === "r") { root.press("InstantReplay"); return true }
    if (t === "i" || t === "*") { root.press("Info"); return true }
    if (t === "m") { root.press("VolumeMute"); return true }
    if (t === "p") { root.togglePower(); return true }
    if (t === "t" || t === "/") { root.typing = true; root.typed = ""; return true }
    if (t >= "1" && t <= "9") { root.launch(root.apps[Number(t) - 1]); return true }
    return true
  }

  Timer { id: flashTimer; interval: 160; onTriggered: root.flashKey = "" }
  Timer { id: noticeTimer; interval: 2500; onTriggered: root.notice = "" }

  Process {
    id: infoProc
    stdout: StdioCollector {
      onStreamFinished: root.applyInfo(text)
    }
    stderr: StdioCollector {
      onStreamFinished: if (text.length > 0 && !root.ip) root.unreachable = true
    }
  }

  // ---- Roku-remote look ----------------------------------------------------
  // A physical-remote lookalike: fixed dark body, round buttons, Roku purple accents.
  readonly property color rokuPurple: "#662d91"
  readonly property color bodyColor: "#141416"
  readonly property color btnColor: "#2f2f35"
  readonly property color btnHover: "#3f3f47"
  readonly property color glyphColor: "#e9e9ee"
  readonly property real pad: Style.space(18)
  readonly property real bodyW: Style.space(220)
  readonly property real colW: bodyW - 2 * pad
  readonly property real sp: Style.space(10)

  function appColor(name) {
    var n = (name || "").toLowerCase()
    if (n.indexOf("netflix") >= 0) return "#c9151e"
    if (n.indexOf("youtube") >= 0) return "#d8201a"
    if (n.indexOf("hulu") >= 0) return "#1ce783"
    if (n.indexOf("disney") >= 0) return "#1d3fbf"
    if (n.indexOf("prime") >= 0) return "#0a86b4"
    if (n.indexOf("max") >= 0) return "#5822b4"
    if (n.indexOf("apple") >= 0) return "#26262a"
    if (n.indexOf("plex") >= 0) return "#b8860b"
    if (n.indexOf("spotify") >= 0) return "#169c46"
    return "#4b3a66"
  }
  function appLabel(name) {
    var n = (name || "").toLowerCase()
    if (n.indexOf("netflix") >= 0) return "NETFLIX"
    if (n.indexOf("youtube") >= 0) return "YouTube"
    if (n.indexOf("prime") >= 0) return "prime"
    if (n.indexOf("hulu") >= 0) return "hulu"
    if (n.indexOf("disney") >= 0) return "Disney+"
    if (n.indexOf("apple tv") >= 0) return "tv"
    if (n.indexOf("apple music") >= 0) return "Music"
    if (n === "max" || n.indexOf("max") === 0) return "max"
    var w = (name || "").split(" ")[0]
    return w.length > 7 ? w.slice(0, 7) : w
  }
  function appTextColor(name) {
    return (name || "").toLowerCase().indexOf("hulu") >= 0 ? "#0b0b0d" : "#ffffff"
  }

  // Round / pill button.
  component RBtn: Item {
    id: b
    property string cmd: ""
    property string hint: ""
    property string icon: ""
    property string label: ""
    property real fontPx: Style.font.iconLarge
    property bool flash: cmd !== "" && root.flashKey === cmd
    property bool lit: false
    property color glyph: root.glyphColor
    signal activated()
    Rectangle {
      anchors.fill: parent
      radius: Math.min(width, height) / 2
      color: ma.pressed || b.flash || b.lit ? root.rokuPurple : ma.containsMouse ? root.btnHover : root.btnColor
      Behavior on color { ColorAnimation { duration: 90 } }
    }
    Text {
      anchors.centerIn: parent
      text: b.icon !== "" ? b.icon : b.label
      color: b.glyph
      font.family: Style.font.family
      font.pixelSize: b.fontPx
      font.bold: b.label !== ""
    }
    MouseArea {
      id: ma
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: { b.activated(); keyCatcher.forceActiveFocus() }
    }
    ToolTip.visible: ma.containsMouse && b.hint !== ""
    ToolTip.text: b.hint
    ToolTip.delay: 500
  }

  // The circular direction ring with the OK button in the middle.
  component DPad: Item {
    id: dp
    width: root.colW
    height: root.colW
    Rectangle {
      anchors.fill: parent
      radius: width / 2
      color: "#25252a"
      border.width: 1
      border.color: "#38383f"
    }
    Repeater {
      model: [
        { cmd: "Up",    g: 0xF0143, ax: 0,  ay: -1, hint: "Up (↑ / k)" },
        { cmd: "Down",  g: 0xF0140, ax: 0,  ay: 1,  hint: "Down (↓ / j)" },
        { cmd: "Left",  g: 0xF0141, ax: -1, ay: 0,  hint: "Left (← / h)" },
        { cmd: "Right", g: 0xF0142, ax: 1,  ay: 0,  hint: "Right (→ / l)" }
      ]
      delegate: Item {
        id: arrow
        required property var modelData
        width: dp.width * 0.30
        height: width
        x: dp.width / 2 + modelData.ax * dp.width * 0.355 - width / 2
        y: dp.height / 2 + modelData.ay * dp.height * 0.355 - height / 2
        Rectangle {
          anchors.fill: parent
          radius: width / 2
          color: am.pressed || root.flashKey === arrow.modelData.cmd ? root.rokuPurple
               : am.containsMouse ? "#3a3a41" : "transparent"
        }
        Text {
          anchors.centerIn: parent
          text: root.glyph(arrow.modelData.g)
          color: root.glyphColor
          font.family: Style.font.family
          font.pixelSize: Style.font.iconLarge + Style.space(4)
        }
        MouseArea {
          id: am
          anchors.fill: parent
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onClicked: { root.press(arrow.modelData.cmd); keyCatcher.forceActiveFocus() }
        }
        ToolTip.visible: am.containsMouse
        ToolTip.text: arrow.modelData.hint
        ToolTip.delay: 500
      }
    }
    Rectangle {
      id: ok
      width: dp.width * 0.40
      height: width
      radius: width / 2
      anchors.centerIn: parent
      color: om.pressed || root.flashKey === "Select" ? root.rokuPurple : om.containsMouse ? root.btnHover : root.btnColor
      border.width: 1
      border.color: "#4a4a52"
      Behavior on color { ColorAnimation { duration: 90 } }
      Text {
        anchors.centerIn: parent
        text: "OK"
        color: root.glyphColor
        font.family: Style.font.family
        font.pixelSize: Style.font.title
        font.bold: true
      }
      MouseArea {
        id: om
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: { root.press("Select"); keyCatcher.forceActiveFocus() }
      }
      ToolTip.visible: om.containsMouse
      ToolTip.text: "Select (⏎)"
      ToolTip.delay: 500
    }
  }

  // A real (floating) window, not a layer-shell overlay: Hyprland places it via the
  // rule in ~/.config/hypr/hyprland.lua (title "Roku Remote"). The window is transparent;
  // the rounded remote body is drawn inside it.
  FloatingWindow {
    id: panel
    visible: root.opened
    title: "Roku Remote"
    color: "transparent"
    implicitWidth: root.bodyW
    implicitHeight: content.implicitHeight + root.pad * 2
    minimumSize: Qt.size(implicitWidth, implicitHeight)
    maximumSize: Qt.size(implicitWidth, implicitHeight)

    onVisibleChanged: if (!visible && root.opened) root.dismiss()

    Rectangle {
      id: card
      anchors.fill: parent
      radius: Style.space(38)
      color: root.bodyColor
      border.width: 1
      border.color: "#2c2c32"

      MouseArea { anchors.fill: parent; onClicked: keyCatcher.forceActiveFocus() }

      Item {
        id: keyCatcher
        anchors.fill: parent
        focus: true
        Keys.priority: Keys.BeforeItem
        Keys.onPressed: function(event) {
          if (root.handleKey(event)) event.accepted = true
        }
      }

      Column {
        id: content
        x: root.pad
        y: root.pad
        width: root.colW
        spacing: root.sp

        // Top: keyboard (typing) | Roku wordmark | power
        Item {
          width: parent.width
          height: Style.space(38)
          RBtn {
            width: parent.height; height: parent.height
            anchors.left: parent.left
            icon: root.glyph(0xF030C)
            fontPx: Style.font.icon
            lit: root.typing
            hint: "Type text (t)"
            onActivated: { root.typing = !root.typing; root.typed = "" }
          }
          Text {
            anchors.centerIn: parent
            text: "Roku"
            color: "#a56bd6"
            font.family: Style.font.family
            font.pixelSize: Style.font.heading + Style.space(2)
            font.bold: true
            font.italic: true
          }
          RBtn {
            width: parent.height; height: parent.height
            anchors.right: parent.right
            icon: root.glyph(0xF0425)
            fontPx: Style.font.icon
            glyph: "#ff7a7a"
            flash: root.flashKey === "PowerOff" || root.flashKey === "PowerOn"
            hint: "Power (p)"
            onActivated: root.togglePower()
          }
        }

        // Status: which TV, what's playing / typing field / problems
        Item {
          width: parent.width
          height: Style.space(34)

          Column {
            visible: !root.typing && !(root.limited || root.unreachable)
            anchors.centerIn: parent
            spacing: Style.space(2)
            Row {
              anchors.horizontalCenter: parent.horizontalCenter
              spacing: Style.space(7)
              Rectangle {
                width: Style.space(8); height: width; radius: width / 2
                anchors.verticalCenter: parent.verticalCenter
                color: root.power === "PowerOn" ? "#3ddc84" : "#77777f"
              }
              Text {
                text: root.deviceName || "Looking for Roku…"
                color: root.glyphColor
                font.family: Style.font.family
                font.pixelSize: Style.font.bodySmall
                font.bold: true
                MouseArea {
                  anchors.fill: parent
                  cursorShape: root.devices.length > 1 ? Qt.PointingHandCursor : Qt.ArrowCursor
                  onClicked: { root.cycleDevice(); keyCatcher.forceActiveFocus() }
                }
              }
            }
            Text {
              anchors.horizontalCenter: parent.horizontalCenter
              text: root.power && root.power !== "PowerOn" ? "standby" : root.activeApp
              color: root.glyphColor
              opacity: 0.5
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
              elide: Text.ElideRight
              width: Math.min(implicitWidth, root.colW)
              horizontalAlignment: Text.AlignHCenter
            }
          }

          Text {
            visible: root.typing
            anchors.fill: parent
            verticalAlignment: Text.AlignVCenter
            horizontalAlignment: Text.AlignHCenter
            text: root.typed || "Typing to Roku… (esc to stop)"
            color: root.typed ? root.glyphColor : "#a56bd6"
            font.family: Style.font.family
            font.pixelSize: Style.font.body
            elide: Text.ElideLeft
          }
        }

        // Problem banner (Limited mode / unreachable)
        Rectangle {
          visible: root.limited || root.unreachable
          width: parent.width
          height: visible ? bannerText.implicitHeight + Style.space(12) : 0
          radius: Style.space(10)
          color: Util.alpha(Color.urgent, 0.16)
          border.width: 1
          border.color: Color.urgent
          Text {
            id: bannerText
            x: Style.space(8); y: Style.space(6)
            width: parent.width - Style.space(16)
            wrapMode: Text.WordWrap
            color: root.glyphColor
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
            text: root.unreachable
              ? "Can't reach this Roku. Is it on, and on the same network?"
              : "TV is in Limited mode and ignores buttons. On the TV: Settings › System › Advanced system settings › Control by mobile apps › Network access › Permissive."
          }
        }

        // Back | Home
        Row {
          spacing: root.sp
          RBtn { width: (root.colW - root.sp) / 2; height: Style.space(40); cmd: "Back"; icon: root.glyph(0xF004D); hint: "Back (⌫ / b)"; onActivated: root.press("Back") }
          RBtn { width: (root.colW - root.sp) / 2; height: Style.space(40); cmd: "Home"; icon: root.glyph(0xF02DC); hint: "Home (g)"; onActivated: root.press("Home") }
        }

        DPad {}

        // Replay | Options
        Row {
          spacing: root.sp
          RBtn { width: (root.colW - root.sp) / 2; height: Style.space(40); cmd: "InstantReplay"; icon: root.glyph(0xF0709); hint: "Instant replay (r)"; onActivated: root.press("InstantReplay") }
          RBtn { width: (root.colW - root.sp) / 2; height: Style.space(40); cmd: "Info"; label: "✱"; fontPx: Style.font.heading + Style.space(4); hint: "Options (i)"; onActivated: root.press("Info") }
        }

        // Rewind | Play/Pause | Fast-forward
        Row {
          spacing: root.sp
          RBtn { width: (root.colW - 2 * root.sp) / 3; height: Style.space(40); cmd: "Rev"; icon: root.glyph(0xF045F); hint: "Rewind (,)"; onActivated: root.press("Rev") }
          RBtn { width: (root.colW - 2 * root.sp) / 3; height: Style.space(40); cmd: "Play"; icon: root.glyph(0xF040E); hint: "Play / pause (space)"; onActivated: root.press("Play") }
          RBtn { width: (root.colW - 2 * root.sp) / 3; height: Style.space(40); cmd: "Fwd"; icon: root.glyph(0xF0211); hint: "Fast forward (.)"; onActivated: root.press("Fwd") }
        }

        // Volume down | Mute | Volume up
        Row {
          spacing: root.sp
          RBtn { width: (root.colW - 2 * root.sp) / 3; height: Style.space(40); cmd: "VolumeDown"; icon: root.glyph(0xF057F); hint: "Volume down (-)"; onActivated: root.press("VolumeDown") }
          RBtn { width: (root.colW - 2 * root.sp) / 3; height: Style.space(40); cmd: "VolumeMute"; icon: root.glyph(0xF0581); hint: "Mute (m)"; onActivated: root.press("VolumeMute") }
          RBtn { width: (root.colW - 2 * root.sp) / 3; height: Style.space(40); cmd: "VolumeUp"; icon: root.glyph(0xF057E); hint: "Volume up (+)"; onActivated: root.press("VolumeUp") }
        }

        // App shortcut buttons (keys 1-4; 5-8 also work)
        Row {
          spacing: Style.space(6)
          Repeater {
            model: root.apps.slice(0, 4)
            delegate: Item {
              id: appBtn
              required property int index
              required property var modelData
              width: (root.colW - 3 * Style.space(6)) / 4
              height: Style.space(32)
              Rectangle {
                anchors.fill: parent
                radius: Style.space(7)
                color: root.appColor(appBtn.modelData.name)
                border.width: root.activeApp === appBtn.modelData.name ? 2 : 0
                border.color: "#ffffff"
                opacity: am2.pressed ? 0.7 : am2.containsMouse ? 1.0 : 0.88
                Behavior on opacity { NumberAnimation { duration: 90 } }
              }
              Text {
                anchors.fill: parent
                anchors.margins: Style.space(2)
                horizontalAlignment: Text.AlignHCenter
                verticalAlignment: Text.AlignVCenter
                text: root.appLabel(appBtn.modelData.name)
                color: root.appTextColor(appBtn.modelData.name)
                font.family: Style.font.family
                font.pixelSize: Style.font.caption - 1
                font.bold: true
                fontSizeMode: Text.Fit
                minimumPixelSize: 6
                elide: Text.ElideRight
                wrapMode: Text.NoWrap
              }
              MouseArea {
                id: am2
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: { root.launch(appBtn.modelData); keyCatcher.forceActiveFocus() }
              }
              ToolTip.visible: am2.containsMouse
              ToolTip.text: appBtn.modelData.name + " (" + (appBtn.index + 1) + ")"
              ToolTip.delay: 500
            }
          }
        }

        Text {
          width: parent.width
          horizontalAlignment: Text.AlignHCenter
          wrapMode: Text.WordWrap
          text: root.notice ? root.notice : "hjkl · ⏎ · ⌫ back · g home · t type · 1-8 apps · esc"
          color: root.glyphColor
          opacity: root.notice ? 0.9 : 0.35
          font.family: Style.font.family
          font.pixelSize: Style.font.caption - 1
        }
      }
    }
  }
}
