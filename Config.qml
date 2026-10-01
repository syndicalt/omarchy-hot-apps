import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Ui
import "Toggler.js" as Toggler

// Hot Apps config picker. Opens on demand with a slot argument and lets the
// user search installed desktop applications; clicking one assigns it to the
// slot. Uses the shell's shared AppLibrary so icons, search, and naming match
// the Omarchy launcher exactly.
Item {
  id: root

  // Injected by omarchy-shell.
  property var shell: null
  property var manifest: null
  // Handed over by the host: the live service instance (kinds: service + menu).
  property var service: null

  readonly property var appLibrary: root.shell ? root.shell.appLibrary : null

  property string slot: "comma"
  property bool opened: false
  property string filter: ""
  property var appRows: []
  property var current: null

  function open(payloadJson) {
    var payload = {}
    try { payload = JSON.parse(payloadJson || "{}") } catch (e) {}
    root.slot = String(payload.slot || "comma")
    root.filter = ""
    root.renderItems()
    root.opened = true
  }

  function close() {
    root.opened = false
  }

  function renderItems() {
    if (!root.appLibrary) return
    var rows = root.appLibrary.sortedEntries(root.filter)
    var out = []
    for (var i = 0; i < rows.length; i++) {
      var e = rows[i].entry
      out.push({
        id: String(e.id || ""),
        name: root.appLibrary.entryName(e),
        subtext: root.appLibrary.entrySubtext(e),
        icon: root.appLibrary.iconSource(String(e.icon || ""))
      })
    }
    root.appRows = out
    root.renderCurrent()
  }

  function renderCurrent() {
    if (!root.service) { root.current = null; return }
    try {
      var listed = JSON.parse(root.service.list() || "[]")
      for (var i = 0; i < listed.length; i++)
        if (listed[i].slot === root.slot) root.current = listed[i]
    } catch (e) { root.current = null }
  }

  function assign(id) {
    if (!root.service || !id) return
    root.service.set(root.slot, id)
    root.close()
  }

  onFilterChanged: root.renderItems()

  PanelWindow {
    id: panel
    visible: root.opened
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "hot-apps-config"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    exclusionMode: ExclusionMode.Ignore

    Rectangle {
      anchors.fill: parent
      color: Util.alpha(Color.popups.background, 0.35)
    }

    MouseArea {
      anchors.fill: parent
      onClicked: root.close()
    }

    BorderSurface {
      id: card
      width: Math.min(Style.space(420), panel.width - Style.gapsOut * 2)
      height: Math.min(Style.space(500), panel.height - Style.gapsOut * 2)
      radius: Style.cornerRadius
      anchors.centerIn: parent
      color: Color.popups.background
      borderSpec: Border.surfaceSpec("popups", "border", Color.popups.border, Math.max(1, Style.space(2)))

      MouseArea { anchors.fill: parent; onClicked: {} }

      Column {
        anchors.fill: parent
        anchors.margins: Style.space(14)
        spacing: Style.space(8)

        Row {
          width: parent.width

          Text {
            anchors.verticalCenter: parent.verticalCenter
            text: root.current && root.current.desktopId
              ? "Hot Apps — " + Toggler.slotInfo(root.slot).label
              : "Hot Apps — assign an app"
            font.family: Style.font.family
            font.pixelSize: Style.font.title
            color: Color.popups.text
          }

          Item { width: 1; height: 1 }

          Button {
            text: "✕"
            onClicked: root.close()
          }
        }

        TextField {
          id: search
          width: parent.width
          placeholderText: "Search applications…"
          text: root.filter
          focus: true
          onTextChanged: root.filter = text
          Keys.onPressed: function(event) {
            if (event.key === Qt.Key_Escape) { root.close(); event.accepted = true }
          }
        }

        Text {
          visible: root.current && root.current.desktopId
          text: "Currently: " + (root.current ? root.current.desktopId : "")
          font.family: Style.font.family
          font.pixelSize: Style.font.bodySmall
          color: Util.alpha(Color.popups.text, 0.6)
        }

        ListView {
          id: appList
          width: parent.width
          height: parent.height - search.height - 70
          clip: true
          model: root.appRows
          spacing: Style.space(4)

          delegate: Item {
            required property var modelData
            width: ListView.view.width
            height: Style.space(38)

            MouseArea {
              anchors.fill: parent
              hoverEnabled: true
              onClicked: root.assign(modelData.id)
            }

            Rectangle {
              anchors.fill: parent
              radius: Style.space(6)
              color: mouseArea.containsMouse ? Util.alpha(Color.accent, 0.12) : "transparent"
            }

            Row {
              anchors.fill: parent
              anchors.leftMargin: Style.space(8)
              spacing: Style.space(10)

              Image {
                width: Style.space(22)
                height: Style.space(22)
                source: modelData.icon
                sourceSize: Qt.size(width, height)
                anchors.verticalCenter: parent.verticalCenter
              }

              Column {
                anchors.verticalCenter: parent.verticalCenter
                spacing: 1

                Text {
                  text: modelData.name
                  font.family: Style.font.family
                  font.pixelSize: Style.font.body
                  color: Color.popups.text
                }

                Text {
                  visible: modelData.subtext !== ""
                  text: modelData.subtext
                  font.family: Style.font.family
                  font.pixelSize: Style.font.bodySmall
                  color: Util.alpha(Color.popups.text, 0.6)
                }
              }
            }
          }
        }
      }
    }
  }

  Keys.onPressed: function(event) {
    if (event.key === Qt.Key_Escape) { root.close(); event.accepted = true }
  }
}
