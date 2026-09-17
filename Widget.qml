import QtQuick
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
  readonly property var summary: syncStatus.summary || { count: 0, distanceKm: 0, durationSec: 0, elevationM: 0 }
  readonly property var summaryWeeks: syncStatus.summaryWeeks6 || { count: 0, distanceKm: 0, avgKmPerWeek: 0 }
  readonly property var summaryYear: syncStatus.summaryYear || { count: 0, distanceKm: 0, avgKmPerWeek: 0 }

  property bool showSettingsPanel: false

  readonly property color mainColor: bar ? bar.foreground : "white"
  readonly property color mutedColor: bar ? Qt.rgba(bar.foreground.r, bar.foreground.g, bar.foreground.b, 0.55) : "#999999"

  function pad(n) { return n < 10 ? "0" + n : "" + n }

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
    interval: Math.max(5, parseInt(root.setting("refreshMinutes", 15), 10) || 15) * 60 * 1000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  function setToggle(key, value) {
    settingsProcess.command = ["omarchy-bar", "set", "grunkan.runalyzer", key, value ? "true" : "false", "--json"]
    settingsProcess.running = true
  }

  Process {
    id: settingsProcess
    running: false
    command: []
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
    onClicked: root.popupOpen = !root.popupOpen
  }

  function close() { root.popupOpen = false }

  KeyboardPanel {
    id: popup
    anchorItem: root
    owner: root
    bar: root.bar
    open: root.popupOpen
    focusTarget: clientIdField
    contentWidth: popup.fittedContentWidth(360)
    contentHeight: popup.fittedContentHeight(contentColumn.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: true

      Column {
        id: contentColumn
        width: parent.width
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

            Rectangle {
              visible: refreshArea.containsMouse
              anchors.top: parent.bottom
              anchors.right: parent.right
              anchors.topMargin: 4
              height: refreshTooltipText.implicitHeight + 6
              width: refreshTooltipText.implicitWidth + 12
              radius: 4
              color: root.bar ? root.bar.background : "#222222"
              border.width: 1
              border.color: root.mutedColor
              z: 10
              Text { id: refreshTooltipText; anchors.centerIn: parent; text: "Refresh"; color: root.mainColor; font.pixelSize: 10 }
            }
          }

          Rectangle {
            id: settingsButton
            anchors.right: refreshButton.left
            anchors.rightMargin: 4
            anchors.verticalCenter: parent.verticalCenter
            width: 22
            height: 22
            radius: 5
            color: settingsArea.containsMouse || root.showSettingsPanel ? root.mutedColor : "transparent"

            Text {
              anchors.centerIn: parent
              text: "⚙"
              color: root.mainColor
              font.pixelSize: 14
            }

            MouseArea {
              id: settingsArea
              anchors.fill: parent
              hoverEnabled: true
              onClicked: root.showSettingsPanel = !root.showSettingsPanel
            }

            Rectangle {
              visible: settingsArea.containsMouse
              anchors.top: parent.bottom
              anchors.right: parent.right
              anchors.topMargin: 4
              height: settingsTooltipText.implicitHeight + 6
              width: settingsTooltipText.implicitWidth + 12
              radius: 4
              color: root.bar ? root.bar.background : "#222222"
              border.width: 1
              border.color: root.mutedColor
              z: 10
              Text { id: settingsTooltipText; anchors.centerIn: parent; text: "Settings"; color: root.mainColor; font.pixelSize: 10 }
            }
          }
        }

        Rectangle {
          width: parent.width
          height: 1
          color: root.mutedColor
          opacity: 0.4
        }

        Column {
          width: parent.width
          spacing: 8
          visible: root.showSettingsPanel

          Text {
            width: parent.width
            text: "Settings"
            color: root.mainColor
            font.pixelSize: 13
            font.bold: true
          }

          Row {
            width: parent.width
            Text {
              width: parent.width - 60
              text: "Last 7 days"
              color: root.mainColor
              font.pixelSize: 12
              anchors.verticalCenter: parent.verticalCenter
            }
            Rectangle {
              width: 50
              height: 24
              radius: 12
              border.width: 1
              border.color: root.mutedColor
              color: root.setting("show7d", true) ? root.mutedColor : "transparent"
              Text {
                anchors.centerIn: parent
                text: root.setting("show7d", true) ? "On" : "Off"
                color: root.mainColor
                font.pixelSize: 11
              }
              MouseArea {
                anchors.fill: parent
                onClicked: root.setToggle("show7d", !root.setting("show7d", true))
              }
            }
          }

          Row {
            width: parent.width
            Text {
              width: parent.width - 60
              text: "Last 6 weeks"
              color: root.mainColor
              font.pixelSize: 12
              anchors.verticalCenter: parent.verticalCenter
            }
            Rectangle {
              width: 50
              height: 24
              radius: 12
              border.width: 1
              border.color: root.mutedColor
              color: root.setting("show6w", true) ? root.mutedColor : "transparent"
              Text {
                anchors.centerIn: parent
                text: root.setting("show6w", true) ? "On" : "Off"
                color: root.mainColor
                font.pixelSize: 11
              }
              MouseArea {
                anchors.fill: parent
                onClicked: root.setToggle("show6w", !root.setting("show6w", true))
              }
            }
          }

          Row {
            width: parent.width
            Text {
              width: parent.width - 60
              text: "This year"
              color: root.mainColor
              font.pixelSize: 12
              anchors.verticalCenter: parent.verticalCenter
            }
            Rectangle {
              width: 50
              height: 24
              radius: 12
              border.width: 1
              border.color: root.mutedColor
              color: root.setting("showYear", true) ? root.mutedColor : "transparent"
              Text {
                anchors.centerIn: parent
                text: root.setting("showYear", true) ? "On" : "Off"
                color: root.mainColor
                font.pixelSize: 11
              }
              MouseArea {
                anchors.fill: parent
                onClicked: root.setToggle("showYear", !root.setting("showYear", true))
              }
            }
          }

          Row {
            width: parent.width
            Text {
              width: parent.width - 60
              text: "Last 5 activities"
              color: root.mainColor
              font.pixelSize: 12
              anchors.verticalCenter: parent.verticalCenter
            }
            Rectangle {
              width: 50
              height: 24
              radius: 12
              border.width: 1
              border.color: root.mutedColor
              color: root.setting("showRecent5", true) ? root.mutedColor : "transparent"
              Text {
                anchors.centerIn: parent
                text: root.setting("showRecent5", true) ? "On" : "Off"
                color: root.mainColor
                font.pixelSize: 11
              }
              MouseArea {
                anchors.fill: parent
                onClicked: root.setToggle("showRecent5", !root.setting("showRecent5", true))
              }
            }
          }
        }

        Column {
          width: parent.width
          spacing: 8
          visible: root.syncStatus.connected !== true && !root.showSettingsPanel

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

        Text {
          text: "Last 7 days"
          color: root.mutedColor
          font.pixelSize: 12
          font.bold: true
          visible: root.syncStatus.connected === true && !root.showSettingsPanel && root.setting("show7d", true)
        }

        Row {
          width: parent.width
          spacing: 8
          visible: root.syncStatus.connected === true && !root.showSettingsPanel && root.setting("show7d", true)

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

        Rectangle {
          width: parent.width
          height: 1
          color: root.mutedColor
          opacity: 0.4
          visible: root.syncStatus.connected === true && !root.showSettingsPanel && root.setting("show6w", true)
        }

        Text {
          text: "Last 6 weeks"
          color: root.mutedColor
          font.pixelSize: 12
          font.bold: true
          visible: root.syncStatus.connected === true && !root.showSettingsPanel && root.setting("show6w", true)
        }

        Row {
          width: parent.width
          spacing: 8
          visible: root.syncStatus.connected === true && !root.showSettingsPanel && root.setting("show6w", true)

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

        Rectangle {
          width: parent.width
          height: 1
          color: root.mutedColor
          opacity: 0.4
          visible: root.syncStatus.connected === true && !root.showSettingsPanel && root.setting("showYear", true)
        }

        Text {
          text: "This year"
          color: root.mutedColor
          font.pixelSize: 12
          font.bold: true
          visible: root.syncStatus.connected === true && !root.showSettingsPanel && root.setting("showYear", true)
        }

        Row {
          width: parent.width
          spacing: 8
          visible: root.syncStatus.connected === true && !root.showSettingsPanel && root.setting("showYear", true)

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

        Rectangle {
          width: parent.width
          height: 1
          color: root.mutedColor
          opacity: 0.4
          visible: root.syncStatus.connected === true && !root.showSettingsPanel
        }

        Text {
          visible: root.syncStatus.connected === true && !root.showSettingsPanel && !!root.syncStatus.error
          width: parent.width
          wrapMode: Text.Wrap
          text: root.syncStatus.authHelpText
          color: root.mutedColor
          font.pixelSize: 10
        }

        Text {
          text: "Last 5 activities"
          color: root.mutedColor
          font.pixelSize: 12
          font.bold: true
          visible: root.syncStatus.connected === true && !root.showSettingsPanel && root.setting("showRecent5", true)
        }

        Column {
          width: parent.width
          spacing: 6
          visible: root.syncStatus.connected === true && !root.showSettingsPanel && root.setting("showRecent5", true)

          Repeater {
            model: root.activities

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

              Rectangle {
                visible: cardArea.containsMouse
                anchors.top: parent.top
                anchors.right: parent.right
                anchors.margins: 4
                height: cardTooltipText.implicitHeight + 6
                width: cardTooltipText.implicitWidth + 12
                radius: 4
                color: root.bar ? root.bar.background : "#222222"
                border.width: 1
                border.color: root.mutedColor
                z: 10
                Text { id: cardTooltipText; anchors.centerIn: parent; text: "View on Strava"; color: root.mainColor; font.pixelSize: 10 }
              }
            }
          }
        }

        Row {
          anchors.horizontalCenter: parent.horizontalCenter
          spacing: 8
          visible: !root.showSettingsPanel

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
