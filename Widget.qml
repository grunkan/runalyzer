import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Ui

Item {
  id: root

  property var bar
  property string moduleName
  property var settings

  property bool popupOpen: false

  function emptyStatus() {
    return { connected: false, error: "not_connected", authHelpText: "", activities: [], updatedAt: "", lastAttemptAt: "" }
  }

  property var syncStatus: emptyStatus()
  readonly property var activities: syncStatus.activities || []
  readonly property var recentActivities: activities.slice(0, recentCount)

  // The sync script writes every run it fetched and computes nothing, so all
  // windows below are derived here, where the user's settings live. Changing a
  // setting therefore updates the numbers without waiting for a re-sync.
  readonly property var summary: {
    var runs = runsBetween(isoDaysAgo(6), isoDaysAgo(0))
    var durationSec = 0
    var elevationM = 0
    for (var i = 0; i < runs.length; i++) {
      durationSec += runs[i].durationSec || 0
      elevationM += runs[i].elevationM || 0
    }
    return { count: runs.length, distanceKm: totalKm(runs), durationSec: durationSec, elevationM: elevationM }
  }

  readonly property var summaryWeeks: {
    var runs = runsBetween(isoDaysAgo(avgWeeks * 7 - 1), isoDaysAgo(0))
    var km = totalKm(runs)
    return { count: runs.length, distanceKm: km, avgKmPerWeek: km / Math.max(1, avgWeeks) }
  }

  readonly property real previousWeeksKm: totalKm(runsBetween(isoDaysAgo(avgWeeks * 14 - 1), isoDaysAgo(avgWeeks * 7)))
  readonly property bool hasTrendComparison: previousWeeksKm > 0
  readonly property real trendChangePercent: hasTrendComparison
    ? (summaryWeeks.distanceKm - previousWeeksKm) / previousWeeksKm * 100 : 0

  readonly property var summaryYear: {
    var prefix = new Date().getFullYear() + "-"
    var runs = []
    for (var i = 0; i < activities.length; i++)
      if (String(activities[i].date || "").indexOf(prefix) === 0) runs.push(activities[i])
    var km = totalKm(runs)
    return { count: runs.length, distanceKm: km, avgKmPerWeek: km / elapsedWeeksThisYear() }
  }

  // Kilometres per rolling 7-day block, index 0 being the block ending today.
  readonly property var weeklyKm: {
    var buckets = []
    for (var w = 0; w < avgWeeks; w++)
      buckets.push(totalKm(runsBetween(isoDaysAgo(w * 7 + 6), isoDaysAgo(w * 7))))
    return buckets
  }

  readonly property real weeklyKmMax: {
    var max = 0
    for (var i = 0; i < weeklyKm.length; i++) max = Math.max(max, weeklyKm[i])
    return max
  }

  readonly property int streakWeeks: {
    var today = isoDaysAgo(0)
    var active = ({})
    for (var i = 0; i < activities.length; i++) {
      var day = String(activities[i].date || "")
      if (day.length !== 10 || day > today) continue
      active[Math.floor(daysBetween(day, today) / 7)] = true
    }
    // An empty current block shouldn't zero out a streak that is still alive;
    // start from last week in that case.
    var week = active[0] ? 0 : 1
    var count = 0
    while (active[week]) {
      count++
      week++
    }
    return count
  }

  // Highest heart rate ever recorded, used to classify effort. Underestimates
  // for a runner who never goes all out, hence the manual override.
  readonly property int derivedHrMax: {
    var m = 0
    for (var i = 0; i < activities.length; i++) m = Math.max(m, activities[i].maxHr || 0)
    return m
  }

  readonly property int effectiveHrMax: setting("hrMaxManual", false) ? hrMax : derivedHrMax

  // A single run far longer than anything recent is the best-evidenced injury
  // risk in the literature, so the ceiling is expressed as a planning number.
  readonly property real longest30Km: {
    var runs = runsBetween(isoDaysAgo(29), isoDaysAgo(0))
    var longest = 0
    for (var i = 0; i < runs.length; i++) longest = Math.max(longest, runs[i].distanceKm || 0)
    return longest
  }

  readonly property real ceilingKm: longest30Km * 1.3

  // Efficiency only compares like with like. Average heart rate alone lets
  // interval sessions through, because warm-up and recovery drag the average
  // down, so the peak has to stay low too.
  function isEasyRun(a) {
    if (!a.avgHr || !a.maxHr || effectiveHrMax <= 0) return false
    if (a.avgHr > effectiveHrMax * 0.80) return false
    if (a.maxHr > effectiveHrMax * 0.88) return false
    if (!(a.distanceKm > 0) || !(a.durationSec > 0)) return false
    return (a.elevationM || 0) / a.distanceKm < 10
  }

  function easyRunsIn(fromIso, toIso) {
    var runs = runsBetween(fromIso, toIso)
    var result = []
    for (var i = 0; i < runs.length; i++) if (isEasyRun(runs[i])) result.push(runs[i])
    return result
  }

  function meanEfficiency(runs) {
    if (runs.length === 0) return 0
    var total = 0
    for (var i = 0; i < runs.length; i++)
      total += (runs[i].distanceKm * 1000 / (runs[i].durationSec / 60)) / runs[i].avgHr
    return total / runs.length
  }

  readonly property var easyRunsNow: easyRunsIn(isoDaysAgo(avgWeeks * 7 - 1), isoDaysAgo(0))
  readonly property var easyRunsPrevious: easyRunsIn(isoDaysAgo(avgWeeks * 14 - 1), isoDaysAgo(avgWeeks * 7))
  readonly property real efficiencyNow: meanEfficiency(easyRunsNow)
  readonly property real efficiencyPrevious: meanEfficiency(easyRunsPrevious)

  // Three runs is the point below which an average says more about which runs
  // happened to qualify than about fitness.
  readonly property bool hasEfficiency: easyRunsNow.length >= 3 && easyRunsPrevious.length >= 3

  // Strava's Relative Effort is weighted by time in heart rate zones, which is
  // a better measure of how hard a week was than kilometres are.
  function totalEffort(runs) {
    var total = 0
    for (var i = 0; i < runs.length; i++) total += runs[i].relativeEffort || 0
    return total
  }

  readonly property real load7: totalEffort(runsBetween(isoDaysAgo(6), isoDaysAgo(0)))
  readonly property real load28: totalEffort(runsBetween(isoDaysAgo(27), isoDaysAgo(0)))
  readonly property bool hasLoad: load28 > 0
  // Deliberately expressed as a change against your own recent norm rather
  // than as an acute:chronic ratio: the ratio's link to injury has not held up
  // in recent reviews, and a number framed as risk invites being read as one.
  readonly property real loadChangePercent: hasLoad ? ((load7 / 7) / (load28 / 28) - 1) * 100 : 0

  // A different question from isEasyRun(): that one also demands a low peak and
  // flat ground so efficiency compares like with like. Here we only ask whether
  // the session was easy overall, so a hilly easy run still counts as easy.
  function isEasyEffort(a) {
    return a.avgHr > 0 && effectiveHrMax > 0 && a.avgHr <= effectiveHrMax * 0.80
  }

  readonly property var classifiableRuns28: {
    var runs = runsBetween(isoDaysAgo(27), isoDaysAgo(0))
    var result = []
    for (var i = 0; i < runs.length; i++) if (runs[i].avgHr > 0) result.push(runs[i])
    return result
  }

  readonly property int easyRuns28: {
    var count = 0
    for (var i = 0; i < classifiableRuns28.length; i++)
      if (isEasyEffort(classifiableRuns28[i])) count++
    return count
  }

  readonly property bool hasIntensity: classifiableRuns28.length > 0
  readonly property int easySharePercent: hasIntensity
    ? Math.round(easyRuns28 / classifiableRuns28.length * 100) : 0
  readonly property real efficiencyChangePercent: hasEfficiency && efficiencyPrevious > 0
    ? (efficiencyNow - efficiencyPrevious) / efficiencyPrevious * 100 : 0

  // Which tab the popup is showing. Deliberately a plain property rather than
  // a saved setting: it is transient interface state, so it survives closing
  // and reopening the popup but resets when the shell restarts.
  property string activeTab: "summary"

  readonly property color mainColor: bar ? bar.foreground : "white"
  readonly property color mutedColor: bar ? Qt.rgba(bar.foreground.r, bar.foreground.g, bar.foreground.b, 0.55) : "#999999"

  readonly property bool summaryVisible: root.syncStatus.connected === true && root.activeTab === "summary"
  readonly property bool analysisVisible: root.syncStatus.connected === true && root.activeTab === "analysis"
  readonly property bool settingsVisible: root.activeTab === "settings"
  readonly property bool dataTabVisible: root.summaryVisible || root.analysisVisible
  readonly property bool disconnectedPanel: root.syncStatus.connected !== true && root.activeTab !== "settings"

  readonly property bool show7dSection: root.summaryVisible && root.setting("show7d", true)
  readonly property bool showTrendSection: root.summaryVisible && root.setting("show6w", true)
  readonly property bool showYearSection: root.summaryVisible && root.setting("showYear", true)
  readonly property bool showRecentSection: root.summaryVisible && root.setting("showRecent5", true)
  readonly property bool showCeilingSection: root.analysisVisible && root.setting("showCeiling", true)
    && root.longest30Km > 0
  readonly property bool showEfficiencySection: root.analysisVisible && root.setting("showEfficiency", true)
  readonly property bool showLoadSection: root.analysisVisible && root.setting("showLoad", true)
    && root.hasLoad

  function pad(n) { return n < 10 ? "0" + n : "" + n }

  // Activity dates are plain YYYY-MM-DD strings, which compare correctly as
  // strings. Midday anchoring keeps the arithmetic clear of DST shifts.
  function isoDaysAgo(n) {
    var d = new Date()
    d.setHours(12, 0, 0, 0)
    d.setDate(d.getDate() - n)
    return d.getFullYear() + "-" + pad(d.getMonth() + 1) + "-" + pad(d.getDate())
  }

  function isoToDate(iso) {
    var parts = String(iso).split("-")
    return new Date(Number(parts[0]), Number(parts[1]) - 1, Number(parts[2]), 12, 0, 0, 0)
  }

  function daysBetween(fromIso, toIso) {
    return Math.round((isoToDate(toIso) - isoToDate(fromIso)) / 86400000)
  }

  function runsBetween(fromIso, toIso) {
    var result = []
    for (var i = 0; i < activities.length; i++) {
      var day = String(activities[i].date || "")
      if (day >= fromIso && day <= toIso) result.push(activities[i])
    }
    return result
  }

  function totalKm(runs) {
    var km = 0
    for (var i = 0; i < runs.length; i++) km += runs[i].distanceKm || 0
    return km
  }

  function elapsedWeeksThisYear() {
    var now = new Date()
    now.setHours(12, 0, 0, 0)
    var yearStart = new Date(now.getFullYear(), 0, 1, 12, 0, 0, 0)
    return Math.max(1, (Math.round((now - yearStart) / 86400000) + 1) / 7)
  }

  function formatDuration(sec) {
    sec = Math.round(sec)
    var h = Math.floor(sec / 3600)
    var m = Math.floor((sec % 3600) / 60)
    var s = sec % 60
    if (h > 0) return h + ":" + pad(m) + ":" + pad(s)
    return m + ":" + pad(s)
  }

  function formatPace(sec, km) {
    if (!km) return "–"
    var paceSec = Math.round(sec / km)
    var m = Math.floor(paceSec / 60)
    var s = paceSec % 60
    return m + ":" + pad(s) + "/km"
  }

  function setting(name, fallback) {
    var value = root.settings ? root.settings[name] : undefined
    return (value === undefined || value === null) ? fallback : value
  }

  function settingInt(name, fallback, min, max) {
    var value = Math.round(Number(setting(name, fallback)))
    if (!isFinite(value)) value = fallback
    return Math.max(min, Math.min(max, value))
  }

  // Held locally rather than bound straight to `settings` so a changed value
  // applies immediately instead of snapping back until the write round-trips
  // through the bar.
  property int avgWeeks: 6
  property int recentCount: 5
  property int refreshMinutes: 15
  property int hrMax: 185

  function syncSettingValues() {
    avgWeeks = settingInt("avgWeeks", 6, 2, 12)
    recentCount = settingInt("recentCount", 5, 3, 10)
    refreshMinutes = settingInt("refreshMinutes", 15, 5, 60)
    hrMax = settingInt("hrMax", 185, 140, 220)
  }

  onSettingsChanged: syncSettingValues()

  readonly property string pluginDir: Qt.resolvedUrl(".").toString().replace("file://", "")
  readonly property string stateDir: Quickshell.env("HOME") + "/.local/state/omarchy/strava"
  readonly property string statusFilePath: stateDir + "/status.json"
  readonly property string authFilePath: stateDir + "/auth.json"

  property string connectClientIdDefault: ""
  property bool connecting: false
  property string connectMessage: ""

  function applyStatus(raw) {
    try {
      var parsed = JSON.parse(String(raw || ""))
      root.syncStatus = (parsed && typeof parsed === "object") ? parsed : root.emptyStatus()
    } catch (e) {
      root.syncStatus = root.emptyStatus()
    }
  }

  function prefillClientId(raw) {
    try {
      var parsed = JSON.parse(String(raw || ""))
      if (parsed && parsed.clientId) root.connectClientIdDefault = String(parsed.clientId)
    } catch (e) {}
  }

  FileView {
    id: statusFile
    path: root.statusFilePath
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.applyStatus(text())
    onLoadFailed: root.applyStatus("")
  }

  FileView {
    id: authFile
    path: root.authFilePath
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.prefillClientId(text())
  }

  function refresh() {
    if (syncProcess.running) return
    syncProcess.command = ["python3", root.pluginDir + "bin/strava-sync.py"]
    syncProcess.running = true
  }

  Process {
    id: syncProcess
    running: false
    command: []
    stdout: StdioCollector { id: syncStdout; waitForEnd: true }
    stderr: StdioCollector { id: syncStderr; waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode !== 0) console.warn("runalyzer", "sync failed", syncStderr.text)
    }
  }

  Timer {
    interval: root.refreshMinutes * 60 * 1000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  function setToggle(key, value) { enqueueSetting(key, value ? "true" : "false") }
  function setNumber(key, value) { enqueueSetting(key, String(value)) }

  // A Process runs one command at a time, so writes are queued and drained in
  // order. Without the queue, two quick changes would drop one silently.
  property var pendingSettingWrites: []

  function enqueueSetting(key, jsonValue) {
    // An editable SpinBox commits its text on focus loss, re-emitting the
    // value it already had; writing that back would spawn a process for a
    // change that isn't one.
    if (String(setting(key, "")) === jsonValue) return
    pendingSettingWrites = pendingSettingWrites.concat([[key, jsonValue]])
    drainSettingWrites()
  }

  function drainSettingWrites() {
    if (settingsProcess.running || pendingSettingWrites.length === 0) return
    var next = pendingSettingWrites[0]
    pendingSettingWrites = pendingSettingWrites.slice(1)
    // --json makes the value land as a real JSON number/boolean; without it
    // omarchy-bar would store every value as a quoted string.
    settingsProcess.command = ["omarchy-bar", "set", "grunkan.runalyzer", next[0], next[1], "--json"]
    settingsProcess.running = true
  }

  Process {
    id: settingsProcess
    running: false
    command: []
    onExited: Qt.callLater(root.drainSettingWrites)
  }

  IpcHandler {
    target: "grunkan.runalyzer"
    function refresh(): string { root.refresh(); return "ok" }
    function toggle(): string { root.popupOpen = !root.popupOpen; return "ok" }
    function open(): string { root.popupOpen = true; return "ok" }
    function close(): string { root.popupOpen = false; return "ok" }
  }

  Timer { id: connectMessageTimer; interval: 6000; repeat: false; onTriggered: root.connectMessage = "" }

  function beginConnect(clientId, clientSecret) {
    if (connectProcess.running) return
    if (!clientId || !clientSecret) {
      root.connectMessage = "Enter both Client ID and Client Secret"
      connectMessageTimer.restart()
      return
    }
    root.connecting = true
    root.connectMessage = "Opening browser for Strava login…"
    connectProcess.pendingSecret = clientSecret
    connectProcess.command = ["python3", root.pluginDir + "bin/strava-connect.py", "--client-id", clientId]
    connectProcess.running = true
  }

  Process {
    id: connectProcess
    running: false
    command: []
    stdinEnabled: true
    property string pendingSecret: ""
    stdout: StdioCollector { id: connectStdout; waitForEnd: true }
    stderr: StdioCollector { id: connectStderr; waitForEnd: true }
    onStarted: {
      write(pendingSecret + "\n")
      pendingSecret = ""
    }
    onExited: function(exitCode) {
      root.connecting = false
      if (exitCode === 0) {
        root.connectMessage = ""
        root.refresh()
      } else {
        root.connectMessage = String(connectStderr.text || "Connection failed").trim()
        connectMessageTimer.restart()
      }
    }
  }

  implicitWidth: 28
  implicitHeight: bar ? bar.barSize : 26

  Text {
    anchors.centerIn: parent
    text: ""
    font.family: root.bar ? root.bar.fontFamily : "monospace"
    font.pixelSize: 15
    color: root.mainColor
  }

  MouseArea {
    anchors.fill: parent
    cursorShape: Qt.PointingHandCursor
    onClicked: root.triggerPress()
  }

  function close() { root.popupOpen = false }

  function triggerPress() {
    if (root.bar) root.bar.hideTooltip(root)
    root.popupOpen = !root.popupOpen
  }

  property var registeredBar: null

  function syncClickRegistration() {
    if (registeredBar && registeredBar.unregisterClickTarget) registeredBar.unregisterClickTarget(root)
    registeredBar = root.bar
    if (registeredBar && registeredBar.registerClickTarget) registeredBar.registerClickTarget(root)
  }

  onBarChanged: syncClickRegistration()
  Component.onCompleted: {
    syncClickRegistration()
    syncSettingValues()
  }
  Component.onDestruction: if (registeredBar && registeredBar.unregisterClickTarget) registeredBar.unregisterClickTarget(root)

  KeyboardPanel {
    id: popup
    anchorItem: root
    owner: root
    bar: root.bar
    open: root.popupOpen
    focusTarget: keyCatcher
    contentWidth: popup.fittedContentWidth(360)
    contentHeight: popup.fittedContentHeight(contentColumn.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: true

      ScrollView {
        id: scrollArea
        anchors.fill: parent
        clip: true
        ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
        // AlwaysOn rather than AsNeeded: the Basic style's AsNeeded bar is an
        // overlay that only appears while scrolling, leaving no hint that the
        // clipped content continues.
        ScrollBar.vertical.policy: contentColumn.implicitHeight > height
          ? ScrollBar.AlwaysOn : ScrollBar.AlwaysOff

        // Keeps the flickable from swallowing wheel and drag events while
        // the content still fits.
        Binding {
          target: scrollArea.contentItem
          property: "interactive"
          value: contentColumn.implicitHeight > scrollArea.height
        }

        Column {
          id: contentColumn
          width: scrollArea.availableWidth
          spacing: 10

          Item {
            width: parent.width
            height: titleText.implicitHeight

            Text {
              id: titleText
              anchors.centerIn: parent
              text: "Runalyzer"
              color: root.mainColor
              font.pixelSize: 19
              font.bold: true
            }

            Rectangle {
              id: refreshButton
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              width: 22
              height: 22
              radius: 5
              color: refreshArea.containsMouse ? root.mutedColor : "transparent"
              opacity: syncProcess.running ? 0.5 : 1

              Text {
                anchors.centerIn: parent
                text: "⟳"
                color: root.mainColor
                font.pixelSize: 16
              }

              MouseArea {
                id: refreshArea
                anchors.fill: parent
                hoverEnabled: true
                onClicked: root.refresh()
              }

              PanelToolTip {
                visible: refreshArea.containsMouse
                text: "Refresh"
                fontFamily: root.bar ? root.bar.fontFamily : "monospace"
              }
            }

          }

          ButtonGroup {
            anchors.horizontalCenter: parent.horizontalCenter
            focusable: false
            options: [{ value: "summary", label: "Summary" },
                      { value: "analysis", label: "Analysis" },
                      { value: "settings", label: "Settings" }]
            value: root.activeTab
            foreground: root.mainColor
            background: root.bar ? root.bar.background : "#222222"
            accent: root.mainColor
            fontFamily: root.bar ? root.bar.fontFamily : "monospace"
            onChanged: function(tab) { root.activeTab = tab }
          }

          PanelSeparator {
            foreground: root.mainColor
            visible: root.settingsVisible
          }

          Column {
            width: parent.width
            spacing: 8
            visible: root.settingsVisible

            PanelSectionHeader {
              width: parent.width
              text: "Summary sections"
              foreground: root.mainColor
              fontFamily: root.bar ? root.bar.fontFamily : "monospace"
            }

            Toggle {
              width: parent.width
              label: "Last 7 days"
              checked: root.setting("show7d", true)
              foreground: root.mainColor
              accent: root.mainColor
              fontFamily: root.bar ? root.bar.fontFamily : "monospace"
              onClicked: root.setToggle("show7d", !root.setting("show7d", true))
            }

            Toggle {
              width: parent.width
              label: "Weekly trend"
              checked: root.setting("show6w", true)
              foreground: root.mainColor
              accent: root.mainColor
              fontFamily: root.bar ? root.bar.fontFamily : "monospace"
              onClicked: root.setToggle("show6w", !root.setting("show6w", true))
            }

            Toggle {
              width: parent.width
              label: "This year"
              checked: root.setting("showYear", true)
              foreground: root.mainColor
              accent: root.mainColor
              fontFamily: root.bar ? root.bar.fontFamily : "monospace"
              onClicked: root.setToggle("showYear", !root.setting("showYear", true))
            }

            Toggle {
              width: parent.width
              label: "Recent activities"
              checked: root.setting("showRecent5", true)
              foreground: root.mainColor
              accent: root.mainColor
              fontFamily: root.bar ? root.bar.fontFamily : "monospace"
              onClicked: root.setToggle("showRecent5", !root.setting("showRecent5", true))
            }

            PanelSectionHeader {
              width: parent.width
              text: "Analysis sections"
              foreground: root.mainColor
              fontFamily: root.bar ? root.bar.fontFamily : "monospace"
            }

            Toggle {
              width: parent.width
              label: "Long run ceiling"
              description: "Longest run of the last 30 days, and the distance above which a single run is a big jump"
              checked: root.setting("showCeiling", true)
              foreground: root.mainColor
              accent: root.mainColor
              fontFamily: root.bar ? root.bar.fontFamily : "monospace"
              onClicked: root.setToggle("showCeiling", !root.setting("showCeiling", true))
            }

            Toggle {
              width: parent.width
              label: "Efficiency trend"
              description: "Metres per heartbeat on easy runs only, against the preceding period"
              checked: root.setting("showEfficiency", true)
              foreground: root.mainColor
              accent: root.mainColor
              fontFamily: root.bar ? root.bar.fontFamily : "monospace"
              onClicked: root.setToggle("showEfficiency", !root.setting("showEfficiency", true))
            }

            Toggle {
              width: parent.width
              label: "Load & intensity"
              description: "Relative Effort over 7 days against your 4-week average, and the share of sessions kept easy"
              checked: root.setting("showLoad", true)
              foreground: root.mainColor
              accent: root.mainColor
              fontFamily: root.bar ? root.bar.fontFamily : "monospace"
              onClicked: root.setToggle("showLoad", !root.setting("showLoad", true))
            }

            PanelSeparator { foreground: root.mainColor }

            PanelSectionHeader {
              width: parent.width
              text: "Amounts"
              foreground: root.mainColor
              fontFamily: root.bar ? root.bar.fontFamily : "monospace"
            }

            NumberField {
              label: "Weeks in the trend (" + from + "–" + to + ")"
              from: 2
              to: 12
              value: root.avgWeeks
              foreground: root.mainColor
              accent: root.mainColor
              fontFamily: root.bar ? root.bar.fontFamily : "monospace"
              onModified: function(weeks) {
                root.avgWeeks = weeks
                root.setNumber("avgWeeks", weeks)
              }
            }

            NumberField {
              label: "Activities in the list (" + from + "–" + to + ")"
              from: 3
              to: 10
              value: root.recentCount
              foreground: root.mainColor
              accent: root.mainColor
              fontFamily: root.bar ? root.bar.fontFamily : "monospace"
              onModified: function(count) {
                root.recentCount = count
                root.setNumber("recentCount", count)
              }
            }

            NumberField {
              label: "Refresh interval (" + from + "–" + to + " min)"
              from: 5
              to: 60
              stepSize: 5
              value: root.refreshMinutes
              foreground: root.mainColor
              accent: root.mainColor
              fontFamily: root.bar ? root.bar.fontFamily : "monospace"
              onModified: function(minutes) {
                root.refreshMinutes = minutes
                root.setNumber("refreshMinutes", minutes)
              }
            }

            Toggle {
              width: parent.width
              label: "Set max heart rate manually"
              description: root.setting("hrMaxManual", false)
                ? "" : "Now using the highest recorded: " + root.derivedHrMax + " bpm"
              checked: root.setting("hrMaxManual", false)
              foreground: root.mainColor
              accent: root.mainColor
              fontFamily: root.bar ? root.bar.fontFamily : "monospace"
              onClicked: root.setToggle("hrMaxManual", !root.setting("hrMaxManual", false))
            }

            NumberField {
              visible: root.setting("hrMaxManual", false)
              label: "Max heart rate (" + from + "–" + to + " bpm)"
              from: 140
              to: 220
              stepSize: 5
              value: root.hrMax
              foreground: root.mainColor
              accent: root.mainColor
              fontFamily: root.bar ? root.bar.fontFamily : "monospace"
              onModified: function(bpm) {
                root.hrMax = bpm
                root.setNumber("hrMax", bpm)
              }
            }
          }

          PanelSeparator {
            foreground: root.mainColor
            visible: root.disconnectedPanel
          }

          Column {
            width: parent.width
            spacing: 8
            visible: root.disconnectedPanel

            Text {
              width: parent.width
              wrapMode: Text.Wrap
              text: "Not connected to Strava"
              color: root.mainColor
              font.pixelSize: 13
              font.bold: true
            }

            Text {
              width: parent.width
              wrapMode: Text.Wrap
              text: root.syncStatus.authHelpText || "Connect your Strava account to see your latest runs."
              color: root.mutedColor
              font.pixelSize: 11
            }

            Rectangle {
              width: parent.width
              height: 28
              radius: 6
              color: "transparent"
              border.width: 1
              border.color: root.mutedColor

              TextInput {
                id: clientIdField
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                anchors.margins: 7
                verticalAlignment: TextInput.AlignVCenter
                color: root.mainColor
                font.pixelSize: 11
                text: root.connectClientIdDefault
                clip: true

                Text {
                  visible: clientIdField.text.length === 0
                  text: "Client ID"
                  color: root.mutedColor
                  font.pixelSize: 11
                  anchors.left: parent.left
                  anchors.verticalCenter: parent.verticalCenter
                }
              }
            }

            Rectangle {
              width: parent.width
              height: 28
              radius: 6
              color: "transparent"
              border.width: 1
              border.color: root.mutedColor

              TextInput {
                id: clientSecretField
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                anchors.margins: 7
                verticalAlignment: TextInput.AlignVCenter
                color: root.mainColor
                font.pixelSize: 11
                echoMode: TextInput.Password
                clip: true

                Text {
                  visible: clientSecretField.text.length === 0
                  text: "Client Secret"
                  color: root.mutedColor
                  font.pixelSize: 11
                  anchors.left: parent.left
                  anchors.verticalCenter: parent.verticalCenter
                }
              }
            }

            Rectangle {
              id: connectButton
              width: 90
              height: 28
              radius: 6
              color: connectArea.containsMouse ? root.mutedColor : "transparent"
              border.width: 1
              border.color: root.mutedColor

              Text {
                anchors.centerIn: parent
                text: root.connecting ? "…" : "Connect"
                color: root.mainColor
                font.pixelSize: 12
              }

              MouseArea {
                id: connectArea
                anchors.fill: parent
                hoverEnabled: true
                enabled: !root.connecting
                onClicked: root.beginConnect(clientIdField.text, clientSecretField.text)
              }
            }

            Text {
              visible: root.connectMessage !== ""
              width: parent.width
              wrapMode: Text.Wrap
              text: root.connectMessage
              color: root.mutedColor
              font.pixelSize: 10
            }
          }

          PanelSeparator {
            foreground: root.mainColor
            visible: root.show7dSection
          }

          PanelSectionHeader {
            width: parent.width
            text: "Last 7 days"
            foreground: root.mainColor
            fontFamily: root.bar ? root.bar.fontFamily : "monospace"
            visible: root.show7dSection
          }

          Row {
            width: parent.width
            spacing: 8
            visible: root.show7dSection

            Column {
              width: (parent.width - 24) / 4
              spacing: 2
              Text { text: "Runs"; color: root.mutedColor; font.pixelSize: 10 }
              Text { text: root.summary.count; color: root.mainColor; font.pixelSize: 15; font.bold: true }
            }

            Column {
              width: (parent.width - 24) / 4
              spacing: 2
              Text { text: "Km"; color: root.mutedColor; font.pixelSize: 10 }
              Text { text: root.summary.distanceKm.toFixed(1); color: root.mainColor; font.pixelSize: 15; font.bold: true }
            }

            Column {
              width: (parent.width - 24) / 4
              spacing: 2
              Text { text: "Time"; color: root.mutedColor; font.pixelSize: 10 }
              Text { text: root.formatDuration(root.summary.durationSec); color: root.mainColor; font.pixelSize: 15; font.bold: true }
            }

            Column {
              width: (parent.width - 24) / 4
              spacing: 2
              Text { text: "Elev."; color: root.mutedColor; font.pixelSize: 10 }
              Text { text: root.summary.elevationM + " m"; color: root.mainColor; font.pixelSize: 15; font.bold: true }
            }
          }

          PanelSeparator {
            foreground: root.mainColor
            visible: root.showTrendSection
          }

          Item {
            width: parent.width
            height: trendHeader.implicitHeight
            visible: root.showTrendSection

            PanelSectionHeader {
              id: trendHeader
              anchors.left: parent.left
              text: "Last " + root.avgWeeks + " weeks"
              foreground: root.mainColor
              fontFamily: root.bar ? root.bar.fontFamily : "monospace"
            }

            Text {
              anchors.right: parent.right
              anchors.baseline: trendHeader.baseline
              visible: root.hasTrendComparison
              text: (root.trendChangePercent >= 0 ? "▲ +" : "▼ ")
                + root.trendChangePercent.toFixed(0) + "% vs previous"
              color: root.mutedColor
              font.pixelSize: 10
            }
          }

          Row {
            width: parent.width
            spacing: 8
            visible: root.showTrendSection

            Column {
              width: (parent.width - 16) / 3
              spacing: 2
              Text { text: "Runs"; color: root.mutedColor; font.pixelSize: 10 }
              Text { text: root.summaryWeeks.count; color: root.mainColor; font.pixelSize: 15; font.bold: true }
            }

            Column {
              width: (parent.width - 16) / 3
              spacing: 2
              Text { text: "Km"; color: root.mutedColor; font.pixelSize: 10 }
              Text { text: root.summaryWeeks.distanceKm.toFixed(1); color: root.mainColor; font.pixelSize: 15; font.bold: true }
            }

            Column {
              width: (parent.width - 16) / 3
              spacing: 2
              Text { text: "Avg km/wk"; color: root.mutedColor; font.pixelSize: 10 }
              Text { text: root.summaryWeeks.avgKmPerWeek.toFixed(1); color: root.mainColor; font.pixelSize: 15; font.bold: true }
            }
          }

          Row {
            width: parent.width
            height: 44
            spacing: 3
            visible: root.showTrendSection && root.weeklyKmMax > 0

            Repeater {
              model: root.avgWeeks

              Item {
                id: weekBar
                required property int index

                // Oldest block on the left, the one ending today on the right.
                readonly property real km: root.weeklyKm[root.avgWeeks - 1 - index] || 0
                readonly property bool current: index === root.avgWeeks - 1

                width: (parent.width - (root.avgWeeks - 1) * 3) / root.avgWeeks
                height: parent.height

                Rectangle {
                  id: barFill
                  anchors.bottom: parent.bottom
                  width: parent.width
                  height: Math.max(2, parent.height * weekBar.km / Math.max(1, root.weeklyKmMax))
                  radius: 2
                  color: weekBar.current ? root.mainColor : root.mutedColor
                  opacity: weekBarArea.containsMouse || weekBar.current ? 1 : 0.55

                  Behavior on height { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }
                }

                // Sibling of the bar rather than a child: children inherit the
                // 0.55 opacity above, which would wash the numbers out.
                Text {
                  anchors.horizontalCenter: barFill.horizontalCenter
                  anchors.bottom: barFill.bottom
                  anchors.bottomMargin: 2
                  visible: barFill.height >= 12
                  text: Math.round(weekBar.km)
                  color: weekBar.current ? (root.bar ? root.bar.background : "#222222") : root.mainColor
                  font.pixelSize: 9
                  font.family: root.bar ? root.bar.fontFamily : "monospace"
                }

                MouseArea {
                  id: weekBarArea
                  anchors.fill: parent
                  hoverEnabled: true
                }

                PanelToolTip {
                  visible: weekBarArea.containsMouse
                  text: weekBar.km.toFixed(1) + " km"
                  fontFamily: root.bar ? root.bar.fontFamily : "monospace"
                }
              }
            }
          }

          Text {
            width: parent.width
            visible: root.showTrendSection && root.streakWeeks > 1
            text: root.streakWeeks + " weeks in a row with a run"
            color: root.mutedColor
            font.pixelSize: 10
          }

          PanelSeparator {
            foreground: root.mainColor
            visible: root.showCeilingSection
          }

          PanelSectionHeader {
            width: parent.width
            text: "Long run ceiling"
            foreground: root.mainColor
            fontFamily: root.bar ? root.bar.fontFamily : "monospace"
            visible: root.showCeilingSection
          }

          Row {
            width: parent.width
            spacing: 8
            visible: root.showCeilingSection

            Column {
              width: (parent.width - 8) / 2
              spacing: 2
              Text { text: "30-day longest"; color: root.mutedColor; font.pixelSize: 10 }
              Text { text: root.longest30Km.toFixed(1) + " km"; color: root.mainColor; font.pixelSize: 15; font.bold: true }
            }

            Column {
              width: (parent.width - 8) / 2
              spacing: 2
              Text { text: "Caution above"; color: root.mutedColor; font.pixelSize: 10 }
              Text { text: root.ceilingKm.toFixed(1) + " km"; color: root.mainColor; font.pixelSize: 15; font.bold: true }
            }
          }

          PanelSeparator {
            foreground: root.mainColor
            visible: root.showEfficiencySection
          }

          Item {
            width: parent.width
            height: efficiencyHeader.implicitHeight
            visible: root.showEfficiencySection

            PanelSectionHeader {
              id: efficiencyHeader
              anchors.left: parent.left
              text: "Efficiency (easy runs)"
              foreground: root.mainColor
              fontFamily: root.bar ? root.bar.fontFamily : "monospace"
            }

            Text {
              anchors.right: parent.right
              anchors.baseline: efficiencyHeader.baseline
              visible: root.hasEfficiency
              text: (root.efficiencyChangePercent >= 0 ? "▲ +" : "▼ ")
                + root.efficiencyChangePercent.toFixed(1) + "% vs previous"
              color: root.mutedColor
              font.pixelSize: 10
            }
          }

          Row {
            width: parent.width
            spacing: 8
            visible: root.showEfficiencySection && root.hasEfficiency

            Column {
              width: (parent.width - 8) / 2
              spacing: 2
              Text { text: "Metres per beat"; color: root.mutedColor; font.pixelSize: 10 }
              Text { text: root.efficiencyNow.toFixed(2); color: root.mainColor; font.pixelSize: 15; font.bold: true }
            }

            Column {
              width: (parent.width - 8) / 2
              spacing: 2
              Text { text: "Easy runs used"; color: root.mutedColor; font.pixelSize: 10 }
              Text {
                text: root.easyRunsNow.length + " of " + root.runsBetween(root.isoDaysAgo(root.avgWeeks * 7 - 1), root.isoDaysAgo(0)).length
                color: root.mainColor
                font.pixelSize: 15
                font.bold: true
              }
            }
          }

          Text {
            width: parent.width
            wrapMode: Text.Wrap
            visible: root.showEfficiencySection && !root.hasEfficiency
            text: "Not enough easy runs to compare yet."
            color: root.mutedColor
            font.pixelSize: 10
          }

          PanelSeparator {
            foreground: root.mainColor
            visible: root.showLoadSection
          }

          PanelSectionHeader {
            width: parent.width
            text: "Load & intensity"
            foreground: root.mainColor
            fontFamily: root.bar ? root.bar.fontFamily : "monospace"
            visible: root.showLoadSection
          }

          Row {
            width: parent.width
            spacing: 8
            visible: root.showLoadSection

            Column {
              width: (parent.width - 16) / 3
              spacing: 2
              Text { text: "7-day load"; color: root.mutedColor; font.pixelSize: 10 }
              Text { text: Math.round(root.load7); color: root.mainColor; font.pixelSize: 15; font.bold: true }
            }

            Column {
              width: (parent.width - 16) / 3
              spacing: 2
              Text { text: "vs 4-week avg"; color: root.mutedColor; font.pixelSize: 10 }
              Text {
                text: (root.loadChangePercent >= 0 ? "+" : "") + root.loadChangePercent.toFixed(0) + "%"
                color: root.mainColor
                font.pixelSize: 15
                font.bold: true
              }
            }

            Column {
              width: (parent.width - 16) / 3
              spacing: 2
              Text { text: "Easy sessions"; color: root.mutedColor; font.pixelSize: 10 }
              Text {
                text: root.hasIntensity ? root.easySharePercent + "%" : "–"
                color: root.mainColor
                font.pixelSize: 15
                font.bold: true
              }
            }
          }

          PanelSeparator {
            foreground: root.mainColor
            visible: root.showYearSection
          }

          PanelSectionHeader {
            width: parent.width
            text: "This year"
            foreground: root.mainColor
            fontFamily: root.bar ? root.bar.fontFamily : "monospace"
            visible: root.showYearSection
          }

          Row {
            width: parent.width
            spacing: 8
            visible: root.showYearSection

            Column {
              width: (parent.width - 16) / 3
              spacing: 2
              Text { text: "Runs"; color: root.mutedColor; font.pixelSize: 10 }
              Text { text: root.summaryYear.count; color: root.mainColor; font.pixelSize: 15; font.bold: true }
            }

            Column {
              width: (parent.width - 16) / 3
              spacing: 2
              Text { text: "Km"; color: root.mutedColor; font.pixelSize: 10 }
              Text { text: root.summaryYear.distanceKm.toFixed(1); color: root.mainColor; font.pixelSize: 15; font.bold: true }
            }

            Column {
              width: (parent.width - 16) / 3
              spacing: 2
              Text { text: "Avg km/wk"; color: root.mutedColor; font.pixelSize: 10 }
              Text { text: root.summaryYear.avgKmPerWeek.toFixed(1); color: root.mainColor; font.pixelSize: 15; font.bold: true }
            }
          }

          PanelSeparator {
            foreground: root.mainColor
            visible: root.dataTabVisible
          }

          Text {
            visible: root.dataTabVisible && !!root.syncStatus.error
            width: parent.width
            wrapMode: Text.Wrap
            text: root.syncStatus.authHelpText
            color: root.mutedColor
            font.pixelSize: 10
          }

          PanelSectionHeader {
            width: parent.width
            text: "Last " + root.recentCount + " activities"
            foreground: root.mainColor
            fontFamily: root.bar ? root.bar.fontFamily : "monospace"
            visible: root.showRecentSection
          }

          Column {
            width: parent.width
            spacing: 6
            visible: root.showRecentSection

            Repeater {
              model: root.recentActivities

              Rectangle {
                id: card
                required property var modelData

                width: parent ? parent.width : 0
                height: cardCol.implicitHeight + 14
                radius: 8
                color: cardArea.containsMouse ? Qt.rgba(root.mutedColor.r, root.mutedColor.g, root.mutedColor.b, 0.12) : "transparent"
                border.width: 1
                border.color: root.mutedColor

                Column {
                  id: cardCol
                  anchors.fill: parent
                  anchors.margins: 7
                  spacing: 3

                  Text {
                    width: parent.width
                    wrapMode: Text.Wrap
                    textFormat: Text.PlainText
                    color: root.mainColor
                    font.pixelSize: 12
                    font.bold: true
                    text: card.modelData.name + "  •  " + card.modelData.date + "  •  " + card.modelData.time
                  }

                  Text {
                    width: parent.width
                    wrapMode: Text.Wrap
                    color: root.mutedColor
                    font.pixelSize: 12
                    text: card.modelData.distanceKm.toFixed(1) + " km  •  "
                      + root.formatDuration(card.modelData.durationSec) + "  •  "
                      + root.formatPace(card.modelData.durationSec, card.modelData.distanceKm) + "  •  "
                      + card.modelData.elevationM + " m  •  "
                      + (card.modelData.avgHr ? card.modelData.avgHr + " bpm" : "–")
                  }
                }

                MouseArea {
                  id: cardArea
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: if (card.modelData.id) Qt.openUrlExternally("https://www.strava.com/activities/" + card.modelData.id)
                }

                PanelToolTip {
                  visible: cardArea.containsMouse
                  text: "View on Strava"
                  fontFamily: root.bar ? root.bar.fontFamily : "monospace"
                }
              }
            }
          }

          Row {
            anchors.horizontalCenter: parent.horizontalCenter
            spacing: 8
            visible: root.dataTabVisible

            Rectangle {
              id: stravaButton
              width: 90
              height: 28
              radius: 6
              color: stravaArea.containsMouse ? root.mutedColor : "transparent"
              border.width: 1
              border.color: root.mutedColor

              Text {
                anchors.centerIn: parent
                text: "To Strava"
                color: root.mainColor
                font.pixelSize: 12
              }

              MouseArea {
                id: stravaArea
                anchors.fill: parent
                hoverEnabled: true
                onClicked: Qt.openUrlExternally("https://www.strava.com/dashboard")
              }
            }

            Rectangle {
              id: closeButton
              width: 90
              height: 28
              radius: 6
              color: closeArea.containsMouse ? root.mutedColor : "transparent"
              border.width: 1
              border.color: root.mutedColor

              Text {
                anchors.centerIn: parent
                text: "Close"
                color: root.mainColor
                font.pixelSize: 12
              }

              MouseArea {
                id: closeArea
                anchors.fill: parent
                hoverEnabled: true
                onClicked: root.popupOpen = false
              }
            }
          }
        }
      }
    }
  }
}
