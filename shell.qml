import QtQuick
import QtQuick.Layouts
import Qt5Compat.GraphicalEffects
import QtMultimedia
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Services.Mpris

// Spotify Visualizer — QuickShell rewrite
// Replaces spotify-visualizer.py (374 lines, 5 threads) with declarative QML.
// beats.py feeds beat events via stdout → Process{} here.
// cava feeds bar data via FIFO → Process{cat fifo} here.
ShellRoot {
    PanelWindow {
        id: root

        // ── Wayland layer shell — full-screen, non-interactive overlay ──────
        Component.onCompleted: {
            if (root.WlrLayershell != null) {
                root.WlrLayershell.layer = WlrLayer.Background
                root.WlrLayershell.keyboardFocus = WlrKeyboardFocus.None
            }
        }
        exclusionMode: ExclusionMode.Ignore
        anchors {
            left:   true
            right:  true
            top:    true
            bottom: true
        }
        color: "black"
        focusable: false

        // ── Visual CONFIG ─────────────────────────────────────────────────
        readonly property int   imgSize:  500
        readonly property int   barMax:   100   // radial bar max length in px
        readonly property int   barGap:   2

        // ── Beat / animation state ────────────────────────────────────────
        property real beatStrength: 0.0   // written by beatProc, decays in Timer
        property real breathScale:  1.0   // drives album art size pulse

        // ── Cava bar values ───────────────────────────────────────────────
        property var barValues: []
        // Smoothed version — per-bar lerp (fast rise, slow decay)
        property var smoothedValues: []

        // ── Lyrics ────────────────────────────────────────────────────────
        property var    lyricsLines:        []   // [{t: ms, text: string}, ...]
        property int    currentLyricIdx:    -1
        property string currentTrackTitle:  root.spotifyPlayer ? (root.spotifyPlayer.trackTitle  || "") : ""
        property string currentTrackArtist: root.spotifyPlayer ? (root.spotifyPlayer.trackArtist || "") : ""
        onCurrentTrackTitleChanged: {
            if (root.currentTrackTitle.length > 0) {
                root.lyricsLines     = []
                root.currentLyricIdx = -1
                lyricsProc.running   = false
                lyricsProc.running   = true
                // Also reset & restart canvas fetch on each track change
                root.canvasActive = false
                canvasPlayer.stop()
                canvasPlayer.source = ""
                canvasProc.running  = false
                canvasProc.running  = true
            }
        }

        // ── Canvas ────────────────────────────────────────────────────────
        property bool   canvasActive: false   // true when canvas video is loaded & playing

        // ── Toggle overrides — controlled via IPC (qs ipc call toggleLyrics) ──
        property bool showLyricsOverride: true
        property bool showCanvasOverride: true
        // Effective display state — combines real data state + user override
        readonly property bool effectiveLyrics: lyricsLines.length > 0 && showLyricsOverride
        readonly property bool effectiveCanvas: canvasActive && showCanvasOverride

        // ── Glow color — dynamically extracted from album art dominant color
        property color glowColor: Qt.rgba(0.39, 0.71, 1.0, 1.0)
        Behavior on glowColor { ColorAnimation { duration: 500; easing.type: Easing.OutQuad } }

        // ── Track art URL — watched for changes to re-run color extractor
        property string currentArtUrl: root.spotifyPlayer ? root.spotifyPlayer.trackArtUrl : ""
        property string lastColoredUrl: ""
        // colorUrl is set *explicitly* before starting colorProc so the command
        // always captures the current URL (avoids QML binding evaluation lag).
        property string colorUrl: ""
        onCurrentArtUrlChanged: {
            if (currentArtUrl.length > 0 && currentArtUrl !== root.lastColoredUrl) {
                root.lastColoredUrl = currentArtUrl
                root.colorUrl = currentArtUrl   // set synchronously BEFORE process start
                colorProc.running = true
            }
        }

        // ── Trigger color extraction immediately on startup if player already active
        Timer {
            interval: 800
            running:  true
            repeat:   false
            onTriggered: {
                if (root.currentArtUrl.length > 0) {
                    root.lastColoredUrl = root.currentArtUrl
                    root.colorUrl = root.currentArtUrl   // explicit, not via binding
                    colorProc.running = true
                }
            }
        }

        // ── Trigger lyrics fetch on startup if player already active ──────
        Timer {
            interval: 1200
            running:  true
            repeat:   false
            onTriggered: {
                if (root.currentTrackTitle.length > 0)
                    lyricsProc.running = true
            }
        }

        // ── Trigger canvas fetch on startup if player already active ──────
        Timer {
            interval: 1500
            running:  true
            repeat:   false
            onTriggered: {
                if (root.currentTrackTitle.length > 0) {
                    canvasProc.running = true
                }
            }
        }

        // ── MPRIS — find Spotify player ───────────────────────────────────
        property var spotifyPlayer: {
            var players = Mpris.players.values
            for (var i = 0; i < players.length; i++) {
                if (players[i].identity.toLowerCase().includes("spotify"))
                    return players[i]
            }
            return null
        }

        // ── Dominant color extractor — runs dominantcolor.py on each track change
        Process {
            id: colorProc
            command: ["python3", "/home/iyad/.config/hypr/scripts/dominantcolor.py", root.colorUrl]
            running: false
            stdout: SplitParser {
                onRead: (data) => {
                    if (data.startsWith("COLOR ")) {
                        var parts = data.trim().split(" ")
                        root.glowColor = Qt.rgba(
                            parseInt(parts[1]) / 255.0,
                            parseInt(parts[2]) / 255.0,
                            parseInt(parts[3]) / 255.0,
                            1.0
                        )
                    }
                }
            }
        }

        // ── Beat process — reads beats.py stdout ──────────────────────────
        // beats.py prints "BEAT 0.85" lines — SplitParser delivers one line
        // at a time so we get low latency (~10ms per chunk).
        Process {
            id: beatProc
            command: ["python3", "/home/iyad/.config/hypr/scripts/beats.py"]
            running: true
            stdout: SplitParser {
                onRead: (data) => {
                    if (data.startsWith("BEAT ")) {
                        root.beatStrength = parseFloat(data.split(" ")[1]) || 0.0
                    }
                }
            }
        }

        // ── Lyrics fetcher — queries Spotify internal lyrics API ──────────
        Process {
            id: lyricsProc
            command: ["python3", "/home/iyad/.config/hypr/scripts/lyrics.py"]
            running: false
            stdout: SplitParser {
                onRead: (data) => {
                    if (data.startsWith("LYRICS_DATA ")) {
                        try {
                            root.lyricsLines = JSON.parse(data.substring(12))
                        } catch(e) {
                            root.lyricsLines = []
                        }
                    } else {
                        root.lyricsLines = []
                    }
                    root.currentLyricIdx = -1
                }
            }
        }

        // ── Cava process — reads /tmp/cava-fifo ───────────────────────────
        // Direct "cat" child of quickshell — dies with quickshell, zero orphans.
        // When FIFO resets (cava restart), cat gets EOF, exits, and cavaRestartTimer
        // relaunches it after 150 ms. No bash wrapper → no stale processes.
        Process {
            id: cavaProc
            command: ["cat", "/tmp/cava-fifo"]
            running: true
            onRunningChanged: {
                if (!running) cavaRestartTimer.restart()
            }
            stdout: SplitParser {
                onRead: (data) => {
                    var raw  = data.trim().replace(/;$/, "")
                    if (raw.length === 0) return
                    var vals = raw.split(";").map(function(v) {
                        // Clamp to [0,100] — prevents burst/corrupt data from spiking scale
                        var n = parseInt(v)
                        return isNaN(n) ? 0 : Math.min(100, Math.max(0, n))
                    })
                    if (vals.length > 0) root.barValues = vals
                }
            }
        }

        // Relaunches cavaProc 150 ms after FIFO disconnect — debounces rapid restarts
        Timer {
            id: cavaRestartTimer
            interval: 150
            repeat:   false
            onTriggered: cavaProc.running = true
        }

        // ── Canvas fetcher — runs canvas.py on each track change ─────────
        Process {
            id: canvasProc
            command: ["python3", "/home/iyad/.config/hypr/scripts/canvas.py"]
            running: false
            stdout: SplitParser {
                onRead: (data) => {
                    if (data.startsWith("CANVAS_URL ")) {
                        // Small delay so the download finishes writing before we load
                        canvasLoadDelay.restart()
                    } else if (data.startsWith("CANVAS_NONE") || data.startsWith("CANVAS_ERROR")) {
                        root.canvasActive = false
                    }
                }
            }
        }

        // Short delay after canvas.py reports URL, before loading video
        Timer {
            id: canvasLoadDelay
            interval: 300
            repeat:   false
            onTriggered: {
                canvasPlayer.stop()
                canvasPlayer.source = "file:///tmp/spotify-canvas.mp4"
                canvasPlayer.play()
                root.canvasActive = true
            }
        }

        // ── Canvas video player ───────────────────────────────────────────
        MediaPlayer {
            id: canvasPlayer
            loops: MediaPlayer.Infinite
            videoOutput: canvasOutput
            // no audioOutput — canvas MP4s are always silent
        }

        // ── Cava energy → image scale (≈60fps) ────────────────────────────
        // Power curve (^2.5) keeps low energy flat and surges above ~60% threshold.
        // Bounce feel: fast grow AND fast shrink (symmetric lerp).
        // Silence → 0.6×  |  verse → ~0.85×  |  chorus → 1.5×  |  drop → 2.0×
        Timer {
            interval: 16
            running:  true
            repeat:   true
            onTriggered: {
                // Average ALL cava bars → energy 0.0–1.0
                var energy = 0.0
                if (root.barValues.length > 0) {
                    var sum = 0
                    for (var i = 0; i < root.barValues.length; i++)
                        sum += root.barValues[i]
                    energy = (sum / root.barValues.length) / 100.0
                }
                // Hard clamp — prevents any corrupt burst pushing scale to 3x+
                energy = Math.min(1.0, Math.max(0.0, energy))

                // Power curve ^2.5: reactive from mid-energy, explodes at drop.
                // Base 0.6 = shrinks in silence → dramatic contrast when drop hits.
                // Range: 0.6 (silence) → 2.0 (full drop)
                var powered = Math.pow(energy, 2.5)
                var target  = Math.min(2.0, 0.6 + powered * 1.4)

                // Asymmetric lerp: fast rise, moderate decay — matches Caelestia BeatTracker feel
                var diff = target - root.breathScale
                if (diff > 0) {
                    root.breathScale += diff * 0.40   // fast rise — hits on beat
                } else {
                    root.breathScale += diff * 0.12   // moderate fall — not too sticky
                }
                // No JS per-bar lerp — cava handles smoothing natively via
                // noise_reduction + gravity in spotipaper.conf (matches Caelestia libcava approach)
                root.smoothedValues = root.barValues
            }
        }

        // ── Lyrics sync — polls MPRIS position every 250ms ────────────────
        Timer {
            interval: 250
            running:  true
            repeat:   true
            onTriggered: {
                if (!root.spotifyPlayer || root.lyricsLines.length === 0) return
                root.spotifyPlayer.positionChanged()   // force MPRIS position refresh
                var posMs = (root.spotifyPlayer.position || 0) * 1000
                var lines = root.lyricsLines
                var idx   = -1
                for (var i = 0; i < lines.length; i++) {
                    if (lines[i].t <= posMs) idx = i
                    else break
                }
                root.currentLyricIdx = idx
            }
        }

        // ── IPC toggle handlers ───────────────────────────────────────────
        IpcHandler {
            target: "toggleLyrics"
            function handle(): void {
                root.showLyricsOverride = !root.showLyricsOverride
            }
        }
        IpcHandler {
            target: "toggleCanvas"
            function handle(): void {
                root.showCanvasOverride = !root.showCanvasOverride
            }
        }

        // ── Main canvas ───────────────────────────────────────────────────
        Item {
            id: canvas
            anchors.fill: parent

            // cx: album art center x-position (non-readonly so Behavior can animate it)
            // — nothing:            50%  (screen center)
            // — canvas only:        70%  (right of canvas at 30%)
            // — lyrics only:        30%  (left of lyrics at 70%)
            // — canvas + lyrics:    50%  (middle, canvas 25%, lyrics 75%)
            property real cx: {
                if (root.effectiveCanvas && root.effectiveLyrics) return width * 0.50
                if (root.effectiveCanvas)                         return width * 0.70
                if (root.effectiveLyrics)                         return width * 0.30
                return width * 0.50
            }
            readonly property real cy:        height / 2
            readonly property real elemGap:   80    // px gap between canvas⟷album and album⟷lyrics
            readonly property real scaledImg: root.imgSize * root.breathScale
            readonly property real halfImg:   scaledImg / 2

            Behavior on cx { NumberAnimation { duration: 600; easing.type: Easing.OutQuad } }

            // ── Radial bars — rotated Items around album art circle ───────
            // Each Item sits at (canvas.cx, canvas.cy), rotated by angle°,
            // Rectangle child extends outward from the circle edge.
            Repeater {
                model: 48
                delegate: Item {
                    required property int modelData
                    property real angle: (modelData / 48) * 360
                    property real val:   root.barValues.length > modelData ? root.barValues[modelData] / 100.0 : 0
                    property real barH:  Math.max(2, val * root.barMax)

                    x: canvas.cx
                    y: canvas.cy
                    width:  0
                    height: 0
                    rotation: angle

                    Rectangle {
                        width:  14
                        height: parent.barH
                        x:      -width / 2
                        y:      -(canvas.halfImg + parent.barH)
                        color: Qt.rgba(
                            root.glowColor.r,
                            root.glowColor.g,
                            root.glowColor.b,
                            0.25 + parent.val * 0.75
                        )
                        radius: 3
                    }
                }
            }

            // ── Album art — circle-clipped with glow ring ────────────────
            // Outer glow rings (3 layered for soft glow effect)
            Rectangle {
                width:  artContainer.width + 18
                height: artContainer.width + 18
                x: parent.cx - width  / 2
                y: parent.cy - height / 2
                radius: width / 2
                color:  "transparent"
                border.color: Qt.rgba(root.glowColor.r, root.glowColor.g, root.glowColor.b, 0.15)
                border.width: 8
            }
            Rectangle {
                width:  artContainer.width + 9
                height: artContainer.width + 9
                x: parent.cx - width  / 2
                y: parent.cy - height / 2
                radius: width / 2
                color:  "transparent"
                border.color: Qt.rgba(root.glowColor.r, root.glowColor.g, root.glowColor.b, 0.35)
                border.width: 4
            }
            Rectangle {
                width:  artContainer.width + 3
                height: artContainer.width + 3
                x: parent.cx - width  / 2
                y: parent.cy - height / 2
                radius: width / 2
                color:  "transparent"
                border.color: Qt.rgba(root.glowColor.r, root.glowColor.g, root.glowColor.b, 0.80)
                border.width: 2
            }

            // Circle-clipped album art via OpacityMask
            // (clip:true on Rectangle only clips to bounding box, not radius)
            Item {
                id: artContainer
                width:  root.imgSize * root.breathScale
                height: root.imgSize * root.breathScale
                x: parent.cx - width  / 2
                y: parent.cy - height / 2

                Image {
                    id: artImage
                    anchors.fill: parent
                    source:       root.currentArtUrl
                    fillMode:     Image.PreserveAspectCrop
                    smooth:       true
                    antialiasing: true
                    visible:      false  // hidden — OpacityMask uses it as source
                }

                // Circular mask shape
                Rectangle {
                    id: circleMask
                    anchors.fill: parent
                    radius:  width / 2
                    color:   "white"
                    visible: false
                }

                // Composites artImage clipped to circleMask shape
                OpacityMask {
                    anchors.fill: parent
                    source:       artImage
                    maskSource:   circleMask
                }
            }

            // ── Canvas video — positioned in right half (canvas only) or
            //    middle third (canvas + lyrics). Animated on layout change.
            Item {
                id: canvasContainer
                width:   400
                height:  400
                // canvas only  → 30% (left of album at 70%)
                // canvas+lyrics → 25% (left third)
                x: (root.effectiveLyrics ? parent.width * 0.25 : parent.width * 0.30) - width / 2 - parent.elemGap
                y: parent.height / 2 - height / 2
                // Opacity handles visibility so fade-out animation plays fully
                visible: opacity > 0.0

                Behavior on x { NumberAnimation { duration: 600; easing.type: Easing.OutQuad } }

                // Canvas video output (hidden — used as source for OpacityMask)
                VideoOutput {
                    id: canvasOutput
                    anchors.fill: parent
                    fillMode: VideoOutput.PreserveAspectCrop
                    visible: false
                }

                // Rounded mask shape
                Rectangle {
                    id: canvasMask
                    anchors.fill: parent
                    radius: 16
                    color:  "white"
                    visible: false
                }

                // Composites video clipped to rounded rect
                OpacityMask {
                    anchors.fill: parent
                    source:       canvasOutput
                    maskSource:   canvasMask
                }

                // Fade in/out
                opacity: root.effectiveCanvas ? 1.0 : 0.0
                Behavior on opacity { NumberAnimation { duration: 500; easing.type: Easing.OutQuad } }
            }

            // ── Lyrics panel — right side karaoke ────────────────────────
            // no canvas → 70% (right of album at 30%)
            // canvas+lyrics → 75% (right third)
            Item {
                id: lyricsPanel
                visible: root.effectiveLyrics
                anchors.verticalCenter: parent.verticalCenter
                x: (root.effectiveCanvas ? parent.width * 0.75 : parent.width * 0.70) - width / 2 + parent.elemGap
                width:  parent.width  * 0.27
                height: parent.height * 0.80

                Behavior on x { NumberAnimation { duration: 600; easing.type: Easing.OutQuad } }

                // ── Lyrics area with top/bottom fade ───────────────────
                Item {
                    id: lyricsArea
                    anchors.fill: parent
                    clip: true

                    Column {
                        anchors.verticalCenter: parent.verticalCenter
                        anchors.left:           parent.left
                        anchors.right:          parent.right
                        spacing: 20

                        Repeater {
                            model: 6   // offsets: -2, -1, 0 (active), +1, +2, +3

                            delegate: Item {
                                required property int modelData

                                readonly property int    offset:   modelData - 2
                                readonly property int    lineIdx:  root.currentLyricIdx + offset
                                readonly property bool   isActive: offset === 0
                                readonly property bool   isValid:  lineIdx >= 0 && lineIdx < root.lyricsLines.length
                                readonly property string lineText: isValid ? root.lyricsLines[lineIdx].text : ""
                                readonly property real lineOpacity: {
                                    if (offset === 0)  return 1.0
                                    if (offset === -1) return 0.60
                                    if (offset ===  1) return 0.48
                                    if (offset === -2) return 0.27
                                    if (offset ===  2) return 0.20
                                    return 0.10
                                }

                                width:          parent.width
                                implicitHeight: lyricText.implicitHeight
                                visible:        lineText.length > 0

                                // ── Scale + Glow — active line text with DropShadow bloom ──
                                Text {
                                    id: lyricText
                                    anchors.left:  parent.left
                                    anchors.right: parent.right

                                    text:    lineText

                                    font.family:    "JetBrainsMono Nerd Font"
                                    font.pixelSize: isActive ? 30 : 15
                                    font.bold:      isActive

                                    color: isActive
                                        ? Qt.rgba(root.glowColor.r, root.glowColor.g, root.glowColor.b, 1.0)
                                        : Qt.rgba(0.85, 0.85, 0.85, lineOpacity)

                                    wrapMode:            Text.WordWrap
                                    horizontalAlignment: Text.AlignLeft

                                    // Glow effect — rendered via layer+DropShadow when active
                                    layer.enabled: isActive
                                    layer.effect: DropShadow {
                                        horizontalOffset: 0
                                        verticalOffset:   0
                                        radius:           10
                                        samples:          37
                                        color:            Qt.rgba(root.glowColor.r, root.glowColor.g, root.glowColor.b, 0.85)
                                        spread:           0.02
                                        transparentBorder: true
                                    }

                                    Behavior on font.pixelSize {
                                        NumberAnimation { duration: 220; easing.type: Easing.OutQuad }
                                    }
                                    Behavior on color {
                                        ColorAnimation { duration: 220 }
                                    }
                                }
                            }
                        }
                    }

                    // Top fade — blends lyrics into the black background
                    Rectangle {
                        anchors.top: parent.top
                        width: parent.width
                        height: 80
                        gradient: Gradient {
                            orientation: Gradient.Vertical
                            GradientStop { position: 0.0; color: "#ff000000" }
                            GradientStop { position: 1.0; color: "#00000000" }
                        }
                    }

                    // Bottom fade
                    Rectangle {
                        anchors.bottom: parent.bottom
                        width: parent.width
                        height: 80
                        gradient: Gradient {
                            orientation: Gradient.Vertical
                            GradientStop { position: 0.0; color: "#00000000" }
                            GradientStop { position: 1.0; color: "#ff000000" }
                        }
                    }
                }
            }

            // ── Top edge cava bars — Canvas-based, hang downward from top ─
            Canvas {
                id: topCavaCanvas
                anchors.top:   parent.top
                anchors.left:  parent.left
                anchors.right: parent.right
                height: 120

                Connections {
                    target: root
                    function onSmoothedValuesChanged() { topCavaCanvas.requestPaint() }
                    function onGlowColorChanged()      { topCavaCanvas.requestPaint() }
                }

                onPaint: {
                    var ctx = getContext("2d")
                    ctx.clearRect(0, 0, width, height)
                    var vals = root.smoothedValues
                    if (!vals || vals.length === 0) return
                    var n        = vals.length
                    var barW     = width / n
                    var maxH     = 80
                    var fadeZone = 0.12
                    var cr = Math.round(root.glowColor.r * 255)
                    var cg = Math.round(root.glowColor.g * 255)
                    var cb = Math.round(root.glowColor.b * 255)
                    for (var i = 0; i < n; i++) {
                        var val  = vals[i] || 0
                        if (val < 1) continue
                        var barH = Math.max(2, (val / 100.0) * maxH)
                        var x    = i * barW
                        var w    = Math.max(1, barW - 10)
                        var norm = (i + 0.5) / n
                        var edgeAlpha = 1.0
                        if      (norm < fadeZone)          edgeAlpha = norm / fadeZone
                        else if (norm > (1.0 - fadeZone))  edgeAlpha = (1.0 - norm) / fadeZone
                        var alpha = (0.25 + (val / 100.0) * 0.75) * edgeAlpha
                        ctx.fillStyle = "rgba(" + cr + "," + cg + "," + cb + "," + alpha.toFixed(3) + ")"
                        ctx.fillRect(x, 0, w, barH)
                    }
                }
            }

            // ── Bottom edge cava bars — Canvas-based, grow upward from bottom
            Canvas {
                id: bottomCavaCanvas
                anchors.bottom: parent.bottom
                anchors.left:   parent.left
                anchors.right:  parent.right
                height: 120

                Connections {
                    target: root
                    function onSmoothedValuesChanged() { bottomCavaCanvas.requestPaint() }
                    function onGlowColorChanged()      { bottomCavaCanvas.requestPaint() }
                }

                onPaint: {
                    var ctx = getContext("2d")
                    ctx.clearRect(0, 0, width, height)
                    var vals = root.smoothedValues
                    if (!vals || vals.length === 0) return
                    var n        = vals.length
                    var barW     = width / n
                    var maxH     = 80
                    var fadeZone = 0.12
                    var cr = Math.round(root.glowColor.r * 255)
                    var cg = Math.round(root.glowColor.g * 255)
                    var cb = Math.round(root.glowColor.b * 255)
                    for (var i = 0; i < n; i++) {
                        var val  = vals[i] || 0
                        if (val < 1) continue
                        var barH = Math.max(2, (val / 100.0) * maxH)
                        var x    = i * barW
                        var w    = Math.max(1, barW - 10)
                        var norm = (i + 0.5) / n
                        var edgeAlpha = 1.0
                        if      (norm < fadeZone)          edgeAlpha = norm / fadeZone
                        else if (norm > (1.0 - fadeZone))  edgeAlpha = (1.0 - norm) / fadeZone
                        var alpha = (0.25 + (val / 100.0) * 0.75) * edgeAlpha
                        ctx.fillStyle = "rgba(" + cr + "," + cg + "," + cb + "," + alpha.toFixed(3) + ")"
                        ctx.fillRect(x, height - barH, w, barH)
                    }
                }
            }
        }
    }
}
