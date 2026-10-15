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

  property int generation: 0
  property int infoGeneration: -1
  property bool scanning: false
  property bool opened: false
  property bool typing: false
  property bool pickerOpen: false
  property int pickerIndex: 0
  property string defaultIp: ""
  property string typed: ""
  property bool limited: false
  property bool unreachable: false
  property string ip: ""
  property string deviceName: ""
  property string power: ""
  property string activeApp: ""
  property string flashKey: ""
  property string notice: ""
  property bool editingVolume: false
  property bool settingVolume: false
  property string yodelLog: ""
  property string yodelStatus: ""
  property bool showingYodel: false
  property bool yodelRecoveryNeeded: false
  property var bridgePending: ({})
  property var bridgeQueue: []
  property int bridgeSequence: 0
  property bool bridgeReady: false
  property string controlTransport: ""
  property var devices: []
  property var apps: []
  property var savedShortcuts: []
  property bool editingShortcuts: false
  property var draftShortcuts: []
  property int saveGeneration: -1
  readonly property var quickApps: savedShortcuts.length === 4 ? savedShortcuts : apps.slice(0, 4)

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

  // Status dot: red = unreachable, amber = TV ignores buttons (Limited mode), green = on, grey = standby.
  readonly property color statusColor: unreachable ? "#ff5f5f" : limited ? "#f0a030"
                                     : power === "PowerOn" ? "#3ddc84" : "#77777f"
  readonly property string statusNote: unreachable ? "TV is offline or unreachable. Power on will try Wake-on-LAN using its saved MAC address."
    : limited ? "Network control was refused. On the TV: Settings › System › Advanced system settings › Control by mobile apps › Network access › Enabled."
    : root.controlTransport === "ecp-2" ? "Connected using authenticated ECP-2" : ""

  function glyph(cp) { return String.fromCodePoint(cp) }

  // ---- lifecycle -----------------------------------------------------------
  function open(payloadJson) {
    root.generation++
    root.ip = ""
    try {
      var payload = JSON.parse(payloadJson || "{}")
      if (payload.ip && /^\d+\.\d+\.\d+\.\d+$/.test(payload.ip)) root.ip = payload.ip
    } catch (e) {}
    root.deviceName = ""
    root.apps = []
    root.controlTransport = ""
    root.savedShortcuts = []
    root.editingShortcuts = false
    root.editingVolume = false
    root.power = ""
    root.activeApp = ""
    root.limited = false
    root.unreachable = false
    root.opened = true
    root.typing = false
    root.pickerOpen = false
    root.typed = ""
    root.notice = ""
    root.refresh()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }
  function close() { root.opened = false; controlProc.running = false }
  function dismiss() {
    root.opened = false
    controlProc.running = false
    if (root.shell && typeof root.shell.hide === "function")
      root.shell.hide((root.manifest && root.manifest.id) || "charles.roku-remote")
  }
  function toggle() {
    if (root.opened) root.dismiss()
    else root.open("{}")
  }

  // ---- device info ---------------------------------------------------------
  function refresh() {
    if (!root.opened || infoProc.running || root.scanning || shortcutProc.running) return
    root.infoGeneration = root.generation
    infoProc.command = root.ip ? [root.rokuBin, "-d", root.ip, "info"] : [root.rokuBin, "info"]
    infoProc.running = true
  }

  function rescan() {
    if (root.scanning) return
    root.generation++
    root.scanning = true
    scanProc.running = true
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
    if (!root.opened || root.infoGeneration !== root.generation) return
    var d
    try { d = JSON.parse(text) } catch (e) {
      root.unreachable = true
      return
    }
    root.unreachable = d.unreachable === true
    root.ip = d.ip
    root.deviceName = d.name || d.ip
    root.power = d.power || ""
    root.activeApp = d.app || ""
    root.limited = d.limited === true
    root.devices = d.devices || []
    root.defaultIp = d.default || ""
    var listed = d.apps && d.apps.length > 0
    root.apps = root.sortApps(listed ? d.apps : root.fallbackApps)
    if (!shortcutProc.running) root.savedShortcuts = d.shortcuts || []
  }

  function editShortcuts() {
    if (!root.ip || root.quickApps.length !== 4 || shortcutProc.running) return
    root.draftShortcuts = root.quickApps.slice()
    root.pickerOpen = false
    root.editingShortcuts = true
  }

  function chooseShortcut(slot, app) {
    var draft = root.draftShortcuts.slice()
    draft[slot] = app
    root.draftShortcuts = draft
  }

  function saveShortcuts() {
    if (shortcutProc.running || root.draftShortcuts.length !== 4) return
    root.generation++
    root.saveGeneration = root.generation
    shortcutProc.command = [root.rokuBin, "-d", root.ip, "shortcuts", JSON.stringify(root.draftShortcuts)]
    shortcutProc.running = true
  }

  function togglePicker() {
    if (root.pickerOpen) { root.pickerOpen = false; return }
    var idx = 0
    for (var i = 0; i < root.devices.length; i++)
      if (root.devices[i].ip === root.ip) idx = i
    root.pickerIndex = idx
    root.pickerOpen = true
  }

  function selectDevice(ip) {
    root.pickerOpen = false
    if (!ip || ip === root.ip) return
    for (var i = 0; i < root.devices.length; i++)
      if (root.devices[i].ip === ip) root.deviceName = root.devices[i].name
    root.generation++
    root.ip = ip
    root.apps = []
    root.controlTransport = ""
    root.savedShortcuts = []
    root.editingShortcuts = false
    root.editingVolume = false
    root.settingVolume = false
    root.limited = false
    root.unreachable = false
    root.power = ""
    root.activeApp = ""
    root.refresh()
  }

  function cycleDevice() {
    if (root.devices.length < 2) return
    var idx = 0
    for (var i = 0; i < root.devices.length; i++)
      if (root.devices[i].ip === root.ip) idx = i
    root.selectDevice(root.devices[(idx + 1) % root.devices.length].ip)
  }

  // ---- sending -------------------------------------------------------------
  function flushBridge() {
    if (!root.bridgeReady) return
    var queue = root.bridgeQueue
    root.bridgeQueue = []
    for (var i = 0; i < queue.length; i++) controlProc.write(JSON.stringify(queue[i]) + "\n")
  }

  function post(path, onDone) {
    if (!root.ip) return
    if (yodelProc.running) {
      root.notice = "Yodel Nuke is running; TV controls resume after restoration"
      noticeTimer.restart()
      return
    }
    if (Object.keys(root.bridgePending).length >= 128) {
      root.notice = "Waiting for TV commands…"
      noticeTimer.restart()
      return
    }
    var id = String(++root.bridgeSequence)
    root.bridgePending[id] = { generation: root.generation, done: onDone }
    root.bridgeQueue.push({id:id, ip:root.ip, path:path})
    if (!controlProc.running) controlProc.running = true
    root.flushBridge()
  }

  function applyControl(text) {
    var result
    try { result = JSON.parse(text) } catch (e) { return }
    var pending = root.bridgePending[result.id]
    delete root.bridgePending[result.id]
    if (!pending || pending.generation !== root.generation) return
    var status = result.status
    if (status === 403) root.limited = true
    else if (status === 0) root.unreachable = true
    else if (status >= 200 && status < 300) {
      root.unreachable = false
      root.limited = false
      if (result.transport !== "volume") root.controlTransport = result.transport || "http"
    }
    if (result.error) { root.notice = result.error; noticeTimer.restart() }
    if (pending.done) pending.done(status)
  }

  function press(key) {
    root.flashKey = key
    flashTimer.restart()
    root.post("/keypress/" + key)
  }

  function setVolume(value) {
    if (!Number.isInteger(value) || value < 0 || value > 100) return
    if (!root.ip || yodelProc.running || root.settingVolume || Object.keys(root.bridgePending).length >= 128) return
    root.settingVolume = true
    root.notice = "Setting volume to " + value + "…"
    root.post("/volume/" + value, function(status) {
      root.settingVolume = false
      if (status === 200) root.notice = "Volume: " + value
      noticeTimer.restart()
    })
  }

  function startYodel(restore) {
    if (yodelProc.running) return
    root.yodelLog = ""
    root.yodelStatus = restore ? "Restoring TVs…" : "Running on all TVs…"
    root.yodelRecoveryNeeded = false
    root.showingYodel = true
    yodelProc.command = [root.rokuBin, restore ? "yodel-restore" : "yodel-nuke", "--json"]
    yodelProc.running = true
  }

  function applyYodel(text) {
    var result
    try { result = JSON.parse(text) } catch (e) { return }
    root.yodelLog += result.name + ": " + result.message + "\n"
    if (result.status === "complete") root.yodelStatus = result.message
    if (result.status === "error" && /restoration|yodel-restore/i.test(result.message)) root.yodelRecoveryNeeded = true
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

    if (root.editingShortcuts) {
      if (k === Qt.Key_Escape && !shortcutProc.running) root.editingShortcuts = false
      return true
    }

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

    if (k === Qt.Key_F5) { root.rescan(); return true }

    if (root.pickerOpen) {
      var n = root.devices.length
      if (k === Qt.Key_Escape || t === "d") { root.pickerOpen = false; return true }
      if (k === Qt.Key_Down || k === Qt.Key_Tab || t === "j") { if (n) root.pickerIndex = (root.pickerIndex + 1) % n; return true }
      if (k === Qt.Key_Up || t === "k") { if (n) root.pickerIndex = (root.pickerIndex - 1 + n) % n; return true }
      if (k === Qt.Key_Return || k === Qt.Key_Enter) {
        if (n) root.selectDevice(root.devices[root.pickerIndex].ip); else root.pickerOpen = false
        return true
      }
      if (t >= "1" && t <= "9") { if (Number(t) <= n) root.selectDevice(root.devices[Number(t) - 1].ip); return true }
      return true
    }

    if (k === Qt.Key_Escape) { root.dismiss(); return true }
    if (t === "d") { root.togglePicker(); return true }
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
    if (t >= "1" && t <= "9") { root.launch(Number(t) <= 4 ? root.quickApps[Number(t) - 1] : root.apps[Number(t) - 1]); return true }
    return true
  }

  Timer { interval: 5000; repeat: true; running: root.opened; onTriggered: root.refresh() }
  // A separate process keeps restoring TVs even when the remote window is closed.
  Process {
    id: yodelProc
    stdout: SplitParser { onRead: function(data) { root.applyYodel(data) } }
    stderr: StdioCollector {
      onStreamFinished: if (text.trim()) root.yodelLog += text.trim() + "\n"
    }
    onExited: function(exitCode, exitStatus) {
      if (exitCode !== 0) root.yodelStatus = "Finished with errors; see results"
      else if (root.yodelStatus === "Running on all TVs…" || root.yodelStatus === "Restoring TVs…") root.yodelStatus = "Finished"
      root.refresh()
    }
  }
  Process {
    id: controlProc
    command: [root.rokuBin, "bridge"]
    stdinEnabled: true
    onStarted: { root.bridgeReady = true; root.flushBridge() }
    onExited: {
      root.bridgeReady = false
      root.bridgeQueue = []
      root.bridgePending = ({})
      root.settingVolume = false
      if (root.opened) { root.notice = "Control connection stopped. Check Node.js 22 or newer is installed."; noticeTimer.restart() }
    }
    stdout: SplitParser { onRead: function(data) { root.applyControl(data) } }
    stderr: StdioCollector { onStreamFinished: if (text.trim() && root.opened) { root.notice = text.trim(); noticeTimer.restart() } }
  }
  Process {
    id: shortcutProc
    stdout: StdioCollector {
      onStreamFinished: {
        if (root.saveGeneration !== root.generation || !text.trim()) return
        try {
          root.savedShortcuts = JSON.parse(text)
          root.editingShortcuts = false
          root.notice = "Shortcuts saved"
          noticeTimer.restart()
          keyCatcher.forceActiveFocus()
        } catch (e) { root.notice = "Couldn't save shortcuts"; noticeTimer.restart() }
      }
    }
    stderr: StdioCollector {
      onStreamFinished: if (text.trim() && root.saveGeneration === root.generation) {
        root.notice = "Couldn't save shortcuts. Please try again."
        noticeTimer.restart()
      }
    }
  }
  Process {
    id: scanProc
    command: [root.rokuBin, "list"]
    stderr: StdioCollector {
      onStreamFinished: if (text.trim()) { root.notice = "Scan failed. Check your network."; noticeTimer.restart() }
    }
    onExited: {
      root.scanning = false
      Qt.callLater(function() { root.refresh() })
    }
  }
  Timer { id: flashTimer; interval: 160; onTriggered: root.flashKey = "" }
  Timer { id: noticeTimer; interval: 2500; onTriggered: root.notice = "" }

  Process {
    id: infoProc
    onExited: if (root.infoGeneration !== root.generation) Qt.callLater(function() { root.refresh() })
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
  readonly property real colW: bodyW - 2 * pad - Style.space(24)
  readonly property real sp: Style.space(10)

  function appColor(name) {
    var n = (name || "").toLowerCase()
    if (n.indexOf("netflix") >= 0) return "#c9151e"
    if (n.indexOf("youtube") >= 0) return "#d8201a"
    if (n.indexOf("hulu") >= 0) return "#087f47"
    if (n.indexOf("disney") >= 0) return "#1d3fbf"
    if (n.indexOf("prime") >= 0) return "#08749b"
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
      border.width: 1
      border.color: ma.pressed ? "#111115" : "#414148"
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
    // Molded purple cross, like the physical Roku direction pad.
    Canvas {
      anchors.fill: parent
      onPaint: {
        var c = getContext("2d")
        var w = width, h = height, lo = 0.32, hi = 0.68, r = width * 0.08
        c.clearRect(0, 0, w, h)
        c.beginPath()
        c.moveTo(w * lo + r, 1)
        c.lineTo(w * hi - r, 1); c.quadraticCurveTo(w * hi, 1, w * hi, r)
        c.lineTo(w * hi, h * lo); c.lineTo(w - r, h * lo)
        c.quadraticCurveTo(w - 1, h * lo, w - 1, h * lo + r)
        c.lineTo(w - 1, h * hi - r); c.quadraticCurveTo(w - 1, h * hi, w - r, h * hi)
        c.lineTo(w * hi, h * hi); c.lineTo(w * hi, h - r)
        c.quadraticCurveTo(w * hi, h - 1, w * hi - r, h - 1)
        c.lineTo(w * lo + r, h - 1); c.quadraticCurveTo(w * lo, h - 1, w * lo, h - r)
        c.lineTo(w * lo, h * hi); c.lineTo(r, h * hi)
        c.quadraticCurveTo(1, h * hi, 1, h * hi - r)
        c.lineTo(1, h * lo + r); c.quadraticCurveTo(1, h * lo, r, h * lo)
        c.lineTo(w * lo, h * lo); c.lineTo(w * lo, r)
        c.quadraticCurveTo(w * lo, 1, w * lo + r, 1)
        c.closePath()
        var gradient = c.createLinearGradient(0, 0, 0, h)
        gradient.addColorStop(0, "#a264cf"); gradient.addColorStop(1, "#66359a")
        c.fillStyle = gradient; c.fill()
        c.strokeStyle = "#bb85dc"; c.lineWidth = 1; c.stroke()
      }
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
          color: am.pressed || root.flashKey === arrow.modelData.cmd ? "#bb83ed"
               : am.containsMouse ? "#995bc9" : "transparent"
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
      width: dp.width * 0.34
      height: width
      radius: width / 2
      anchors.centerIn: parent
      color: om.pressed || root.flashKey === "Select" ? root.rokuPurple : om.containsMouse ? "#a469d4" : "#7845a6"
      border.width: 1
      border.color: "#be8ddd"
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
    implicitHeight: content.implicitHeight + root.pad * 2 + Style.space(16)
    minimumSize: Qt.size(implicitWidth, implicitHeight)
    maximumSize: Qt.size(implicitWidth, implicitHeight)

    onVisibleChanged: if (!visible && root.opened) root.dismiss()

    Rectangle {
      id: card
      anchors.fill: parent
      radius: Style.space(48)
      gradient: Gradient {
        orientation: Gradient.Horizontal
        GradientStop { position: 0; color: "#111114" }
        GradientStop { position: 0.12; color: "#303034" }
        GradientStop { position: 0.5; color: "#202024" }
        GradientStop { position: 0.9; color: "#19191c" }
        GradientStop { position: 1; color: "#08080a" }
      }
      border.width: 1
      border.color: "#2c2c32"

      MouseArea { anchors.fill: parent; onClicked: keyCatcher.forceActiveFocus() }

      Column {
        x: card.width - Style.space(30)
        y: Style.space(215)
        spacing: Style.space(8)
        Rectangle {
          width: Style.space(25); height: Style.space(82); radius: width / 2
          color: "#111114"; border.width: 1; border.color: "#43434a"
          Column {
            anchors.centerIn: parent
            RBtn { width: Style.space(23); height: Style.space(38); cmd: "VolumeUp"; label: "+"; fontPx: Style.space(20); hint: "Volume up (+)"; onActivated: root.press("VolumeUp") }
            RBtn { width: Style.space(23); height: Style.space(38); cmd: "VolumeDown"; label: "−"; fontPx: Style.space(20); hint: "Volume down (-)"; onActivated: root.press("VolumeDown") }
          }
        }
        RBtn { width: Style.space(25); height: Style.space(32); cmd: "VolumeMute"; icon: root.glyph(0xF0581); fontPx: Style.space(15); hint: "Mute (m)"; onActivated: root.press("VolumeMute") }
        Button {
          width: Style.space(28); height: Style.space(28)
          text: "Set"
          enabled: !!root.ip && !yodelProc.running && !root.settingVolume
          onClicked: { root.editingVolume = true; volumeInput.forceActiveFocus() }
          ToolTip.visible: hovered
          ToolTip.text: "Set exact volume (0–100)"
        }
      }

      Rectangle {
        z: 22
        anchors.fill: parent
        radius: card.radius
        color: "#fa202024"
        visible: root.showingYodel
        MouseArea { anchors.fill: parent }
        Column {
          anchors.centerIn: parent
          width: parent.width - root.pad * 2
          spacing: Style.space(10)
          Text {
            text: "Yodel Nuke"
            color: root.glyphColor; font.family: Style.font.family; font.bold: true
          }
          Text {
            width: parent.width; wrapMode: Text.WordWrap
            text: root.yodelStatus
            color: "#cdb1e4"; font.family: Style.font.family
          }
          ScrollView {
            width: parent.width; height: card.height * 0.55
            clip: true
            contentWidth: availableWidth
            TextArea {
              text: root.yodelLog
              readOnly: true; selectByMouse: true; wrapMode: TextEdit.Wrap
              color: root.glyphColor
              font.family: Style.font.family; font.pixelSize: Style.space(10)
              background: Rectangle { color: "#111114"; radius: Style.space(6) }
            }
          }
          Button {
            width: parent.width; text: "Retry restoration"
            visible: root.yodelRecoveryNeeded
            enabled: !yodelProc.running
            onClicked: root.startYodel(true)
          }
          Button {
            width: parent.width; text: "Close results"
            onClicked: { root.showingYodel = false; keyCatcher.forceActiveFocus() }
          }
        }
      }

      Rectangle {
        z: 21
        anchors.fill: parent
        radius: card.radius
        color: "#f0202024"
        visible: root.editingVolume
        MouseArea { anchors.fill: parent }
        Column {
          anchors.centerIn: parent
          width: parent.width - root.pad * 2
          spacing: Style.space(12)
          Text {
            text: "Set volume (0–100)"
            color: root.glyphColor; font.family: Style.font.family; font.bold: true
          }
          TextField {
            id: volumeInput
            width: parent.width
            placeholderText: "Enter volume"
            validator: IntValidator { bottom: 0; top: 100 }
            inputMethodHints: Qt.ImhDigitsOnly
            onAccepted: if (acceptableInput && !root.settingVolume) volumeSetButton.clicked()
            Keys.onEscapePressed: { root.editingVolume = false; keyCatcher.forceActiveFocus() }
          }
          Button {
            id: volumeSetButton
            width: parent.width
            text: "Set volume"
            enabled: volumeInput.acceptableInput && !root.settingVolume
            onClicked: {
              root.setVolume(Number(volumeInput.text))
              root.editingVolume = false
              keyCatcher.forceActiveFocus()
            }
          }
          Button {
            width: parent.width; text: "Cancel"
            onClicked: { root.editingVolume = false; keyCatcher.forceActiveFocus() }
          }
        }
      }

      Rectangle {
        z: 20
        anchors.fill: parent
        radius: card.radius
        color: "#f0202024"
        visible: root.editingShortcuts
        MouseArea { anchors.fill: parent }
        Column {
          anchors.centerIn: parent
          width: parent.width - root.pad * 2
          spacing: Style.space(12)
          Text {
            width: parent.width; wrapMode: Text.WordWrap
            text: "Customize shortcuts"
            color: root.glyphColor; font.family: Style.font.family; font.bold: true
          }
          Text {
            width: parent.width; wrapMode: Text.WordWrap
            text: "Choose the four apps for " + root.deviceName + ". Keys 1–4 follow this order."
            color: "#b6b1be"; font.family: Style.font.family; font.pixelSize: Style.space(11)
          }
          Repeater {
            model: root.draftShortcuts
            delegate: Column {
              required property int index
              required property var modelData
              width: parent.width
              Text { text: "Button " + (parent.index + 1); color: "#b6a1c8"; font.pixelSize: Style.space(11) }
              ComboBox {
                width: parent.width
                model: root.apps
                textRole: "name"
                enabled: !shortcutProc.running
                currentIndex: {
                  for (var i = 0; i < root.apps.length; i++)
                    if (root.apps[i].id === parent.modelData.id) return i
                  return -1
                }
                displayText: parent.modelData.name
                onActivated: function(i) { root.chooseShortcut(parent.index, root.apps[i]) }
              }
            }
          }
          Button { width: parent.width; text: shortcutProc.running ? "Saving…" : "Save shortcuts"; enabled: !shortcutProc.running; onClicked: root.saveShortcuts() }
          Button { width: parent.width; text: "Cancel"; enabled: !shortcutProc.running; onClicked: { root.editingShortcuts = false; keyCatcher.forceActiveFocus() } }
        }
      }

      // Click anywhere else to dismiss the TV list
      MouseArea {
        z: 9
        anchors.fill: parent
        visible: root.pickerOpen
        onClicked: { root.pickerOpen = false; keyCatcher.forceActiveFocus() }
      }

      // TV list (drop-down)
      Rectangle {
        id: picker
        z: 10
        visible: root.pickerOpen
        x: root.pad
        y: content.y + statusArea.y + statusArea.height + Style.space(2)
        width: root.colW
        height: pickerList.implicitHeight + Style.space(12)
        radius: Style.space(16)
        color: "#1f1f24"
        border.width: 1
        border.color: "#3a3a42"

        Column {
          id: pickerList
          x: Style.space(6)
          y: Style.space(6)
          width: parent.width - Style.space(12)
          spacing: Style.space(2)

          Text {
            visible: root.devices.length === 0
            width: parent.width
            padding: Style.space(10)
            wrapMode: Text.WordWrap
            horizontalAlignment: Text.AlignHCenter
            text: "No Rokus found. Click Rescan to search your network."
            color: root.glyphColor
            opacity: 0.7
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
          }

          Button {
            width: parent.width
            text: root.scanning ? "Scanning…" : "Rescan TVs (F5)"
            enabled: !root.scanning
            onClicked: { root.rescan(); keyCatcher.forceActiveFocus() }
          }

          Repeater {
            model: root.devices
            delegate: Rectangle {
              id: devRow
              required property int index
              required property var modelData
              readonly property bool isCurrent: modelData.ip === root.ip
              width: pickerList.width
              height: Style.space(40)
              radius: Style.space(11)
              color: dm.containsMouse || root.pickerIndex === index ? "#3a3a42"
                   : isCurrent ? "#2a2a31" : "transparent"

              Text {
                x: Style.space(12)
                y: Style.space(5)
                width: parent.width - Style.space(48)
                text: devRow.modelData.name
                color: root.glyphColor
                font.family: Style.font.family
                font.pixelSize: Style.font.bodySmall
                font.bold: devRow.isCurrent
                elide: Text.ElideRight
              }
              Text {
                x: Style.space(12)
                y: Style.space(21)
                text: devRow.modelData.ip + (devRow.modelData.reachable === false ? " · offline" : "") + (devRow.modelData.ip === root.defaultIp ? "  ·  default" : "")
                color: root.glyphColor
                opacity: 0.45
                font.family: Style.font.family
                font.pixelSize: Style.font.bodySmall
              }
              Text {
                visible: devRow.isCurrent
                anchors.right: parent.right
                anchors.rightMargin: Style.space(12)
                anchors.verticalCenter: parent.verticalCenter
                text: root.glyph(0xF012C)
                color: root.rokuPurple
                font.family: Style.font.family
                font.pixelSize: Style.font.icon
              }
              MouseArea {
                id: dm
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onEntered: root.pickerIndex = devRow.index
                onClicked: { root.selectDevice(devRow.modelData.ip); keyCatcher.forceActiveFocus() }
              }
            }
          }
        }
      }

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

        // TV power sits alone at the crown, as on the hardware remote.
        Item {
          width: parent.width
          height: Style.space(44)
          RBtn {
            width: Style.space(34); height: width
            anchors.centerIn: parent
            icon: root.glyph(0xF0425)
            fontPx: Style.font.icon
            glyph: "#ff666b"
            flash: root.flashKey === "PowerOff" || root.flashKey === "PowerOn"
            hint: "Power (p)"
            onActivated: root.togglePower()
          }
        }

        // Status: which TV (click to open the TV list), what's playing, or the typing field
        Item {
          id: statusArea
          width: parent.width
          height: Style.space(34)

          Column {
            visible: !root.typing
            anchors.centerIn: parent
            spacing: Style.space(2)

            Item {
              id: nameRow
              anchors.horizontalCenter: parent.horizontalCenter
              width: nameRowInner.implicitWidth
              height: nameRowInner.implicitHeight
              Row {
                id: nameRowInner
                spacing: Style.space(7)
                Rectangle {
                  width: Style.space(8); height: width; radius: width / 2
                  anchors.verticalCenter: parent.verticalCenter
                  color: root.statusColor
                }
                Text {
                  width: Math.min(implicitWidth, root.colW - Style.space(35))
                  elide: Text.ElideRight
                  text: root.deviceName || "Looking for Roku…"
                  color: root.glyphColor
                  font.family: Style.font.family
                  font.pixelSize: Style.font.bodySmall
                  font.bold: true
                }
                Text {
                  visible: root.devices.length > 1
                  anchors.verticalCenter: parent.verticalCenter
                  text: root.glyph(0xF0140)
                  color: root.glyphColor
                  opacity: 0.6
                  font.family: Style.font.family
                  font.pixelSize: Style.font.bodySmall
                }
              }
              MouseArea {
                id: nameMa
                anchors.fill: parent
                anchors.margins: -Style.space(6)
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: { root.togglePicker(); keyCatcher.forceActiveFocus() }
              }
              ToolTip.visible: nameMa.containsMouse && !root.pickerOpen
              ToolTip.text: root.statusNote !== "" ? root.statusNote : (root.devices.length > 1 ? "Switch TV (d)" : "")
              ToolTip.delay: 400
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

        // Back | Home
        Row {
          anchors.horizontalCenter: parent.horizontalCenter
          spacing: root.colW - Style.space(88)
          RBtn { width: Style.space(44); height: width; cmd: "Back"; icon: root.glyph(0xF004D); hint: "Back (⌫ / b)"; onActivated: root.press("Back") }
          RBtn { width: Style.space(44); height: width; cmd: "Home"; icon: root.glyph(0xF02DC); hint: "Home (g)"; onActivated: root.press("Home") }
        }

        DPad {}

        // Replay | keyboard entry | Options. Keyboard entry replaces voice search.
        Row {
          anchors.horizontalCenter: parent.horizontalCenter
          spacing: Style.space(12)
          RBtn { width: Style.space(40); height: width; cmd: "InstantReplay"; icon: root.glyph(0xF0709); hint: "Instant replay (r)"; onActivated: root.press("InstantReplay") }
          RBtn {
            width: Style.space(40); height: width
            icon: root.glyph(0xF030C); fontPx: Style.font.icon; lit: root.typing
            hint: "Type into the TV keyboard (t)"
            onActivated: { root.typing = !root.typing; root.typed = "" }
          }
          RBtn { width: Style.space(40); height: width; cmd: "Info"; label: "✱"; hint: "Options (i)"; onActivated: root.press("Info") }
        }

        // Rewind | Play/Pause | Fast-forward
        Row {
          spacing: root.sp
          RBtn { width: (root.colW - 2 * root.sp) / 3; height: Style.space(40); cmd: "Rev"; icon: root.glyph(0xF045F); hint: "Rewind (,)"; onActivated: root.press("Rev") }
          RBtn { width: (root.colW - 2 * root.sp) / 3; height: Style.space(40); cmd: "Play"; icon: root.glyph(0xF040E); hint: "Play / pause (space)"; onActivated: root.press("Play") }
          RBtn { width: (root.colW - 2 * root.sp) / 3; height: Style.space(40); cmd: "Fwd"; icon: root.glyph(0xF0211); hint: "Fast forward (.)"; onActivated: root.press("Fwd") }
        }

        // App shortcut buttons (keys 1-4; 5-8 also work)
        Grid {
          columns: 2
          spacing: Style.space(9)
          Repeater {
            model: root.quickApps
            delegate: Item {
              id: appBtn
              required property int index
              required property var modelData
              width: (root.colW - Style.space(9)) / 2
              height: Style.space(34)
              Rectangle {
                anchors.fill: parent
                radius: Style.space(7)
                color: "#eeedf0"
                border.width: root.activeApp === appBtn.modelData.name ? 2 : 0
                border.color: root.rokuPurple
                opacity: am2.pressed ? 0.7 : am2.containsMouse ? 1.0 : 0.88
                Behavior on opacity { NumberAnimation { duration: 90 } }
              }
              Text {
                anchors.fill: parent
                anchors.margins: Style.space(2)
                horizontalAlignment: Text.AlignHCenter
                verticalAlignment: Text.AlignVCenter
                text: root.appLabel(appBtn.modelData.name)
                color: root.appColor(appBtn.modelData.name)
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
                acceptedButtons: Qt.LeftButton | Qt.RightButton
                onClicked: function(mouse) {
                  if (mouse.button === Qt.RightButton) root.editShortcuts()
                  else { root.launch(appBtn.modelData); keyCatcher.forceActiveFocus() }
                }
                onPressAndHold: root.editShortcuts()
              }
              ToolTip.visible: am2.containsMouse
              ToolTip.text: appBtn.modelData.name + " (" + (appBtn.index + 1) + ") · Right-click to customize"
              ToolTip.delay: 500
            }
          }
        }

        Text {
          width: parent.width
          horizontalAlignment: Text.AlignHCenter
          text: "Edit shortcuts"
          color: "#b6a1c8"
          font.family: Style.font.family
          font.pixelSize: Style.space(10)
          MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: root.editShortcuts() }
        }
        Button {
          width: parent.width
          text: yodelProc.running ? "Yodel Nuke · running…" : "Yodel Nuke"
          enabled: !yodelProc.running && !root.settingVolume
          onClicked: root.startYodel(false)
          ToolTip.visible: hovered
          ToolTip.text: "All TVs: volume 25, YouTube for 25 seconds, then restore. Ads may count."
        }
        Text {
          width: parent.width
          horizontalAlignment: Text.AlignHCenter
          text: root.yodelStatus ? "View Yodel Nuke results" : "All TVs · 25 seconds · ads may count"
          color: "#b6a1c8"; font.family: Style.font.family; font.pixelSize: Style.space(9)
          MouseArea {
            anchors.fill: parent
            enabled: !!root.yodelStatus
            cursorShape: Qt.PointingHandCursor
            onClicked: root.showingYodel = true
          }
        }
        Text {
          width: parent.width
          horizontalAlignment: Text.AlignHCenter
          text: "Roku"
          color: "#a875d2"
          font.family: "sans-serif"
          font.pixelSize: Style.space(30)
          font.bold: true
          font.letterSpacing: -1
        }
        Text {
          width: parent.width
          horizontalAlignment: Text.AlignHCenter
          text: "<a href='https://github.com/thediamondsaint/roku-remote' style='color:#a9a0b5;text-decoration:none'>by thediamondsaint</a>"
          textFormat: Text.RichText
          font.family: Style.font.family
          font.pixelSize: Style.space(10)
          onLinkActivated: function(link) { Qt.openUrlExternally(link) }
          MouseArea { id: creditHover; anchors.fill: parent; hoverEnabled: true; acceptedButtons: Qt.NoButton; cursorShape: Qt.PointingHandCursor }
          ToolTip.visible: creditHover.containsMouse
          ToolTip.text: "Made by Charles Nardella (@thediamondsaint) · v1.7.0\nView source, installation instructions, and issues on GitHub"
          ToolTip.delay: 400
        }
        Text {
          width: parent.width
          horizontalAlignment: Text.AlignHCenter
          wrapMode: Text.WordWrap
          visible: root.notice !== ""
          text: root.notice
          color: root.glyphColor
          opacity: root.notice ? 0.9 : 0.35
          font.family: Style.font.family
          font.pixelSize: Style.font.caption - 1
        }
      }
    }
  }
}
