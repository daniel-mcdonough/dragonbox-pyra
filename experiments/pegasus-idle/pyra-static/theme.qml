// A deliberately inert theme: no animations, no transitions, no Behaviors,
// nothing that redraws unless a key is pressed. Its only purpose is to measure
// what a moving theme costs on this machine.
import QtQuick 2.0

FocusScope {
    focus: true

    Rectangle { anchors.fill: parent; color: "#101014" }

    Text {
        id: header
        anchors { top: parent.top; left: parent.left; margins: 24 }
        color: "#d0d0d8"
        font.pixelSize: 24
        text: api.allGames.count + " games in " + api.collections.count + " collections"
    }

    ListView {
        id: list
        anchors {
            top: header.bottom; topMargin: 24
            left: parent.left; leftMargin: 24
            right: parent.right; bottom: parent.bottom
        }
        focus: true
        model: api.allGames
        highlightMoveDuration: 0
        highlightResizeDuration: 0
        highlightFollowsCurrentItem: true
        keyNavigationWraps: true
        highlight: Rectangle { color: "#203050" }
        delegate: Text {
            height: 40
            verticalAlignment: Text.AlignVCenter
            color: ListView.isCurrentItem ? "#ffffff" : "#8a8a95"
            font.pixelSize: 22
            text: modelData.title
        }
        Keys.onPressed: {
            if (!event.isAutoRepeat && api.keys.isAccept(event)) {
                event.accepted = true;
                api.allGames.get(list.currentIndex).launch();
            }
        }
    }
}
