import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import "sidecar.js" as Sidecar

// What a meeting came to: the summary, what Chris has to do, what the
// others promised, what was decided and what's still open, drafted by Opus
// when the meeting ends. Everything is editable in place and saved as he
// goes, kept apart from the draft; Send files it in Notion.
Rectangle {
    id: root
    color: ui.window

    property double now: Date.now()
    readonly property var m: engine.selectedMeeting
    readonly property var w: engine.wrapup
    readonly property string stage: Sidecar.stage(m)
    readonly property bool drafting: w.state === "drafting"
    readonly property bool hasDoc: !!(w.edited || w.draft)
    readonly property var notion: m.notion || ({})
    signal showLine(int id)

    // The document being edited. It's seeded when another meeting or a new
    // draft comes in, not on every save coming back, so typing is never
    // interrupted by its own echo.
    property var doc: null
    property string seededFor: ""
    readonly property string seedKey: (m.id || "") + "|" + (w.drafted || "") + "|" + (hasDoc ? "doc" : "")
    onSeedKeyChanged: seed()
    Component.onCompleted: seed()
    // Whose doc this is: saves go to that meeting even if another is on
    // screen by the time they fire, and a pending save is flushed before
    // another meeting's doc comes in.
    property string docFor: ""
    property bool seeding: false
    function seed() {
        if (seedKey === seededFor) return
        flush()
        seededFor = seedKey
        seeding = true
        docFor = m.id || ""
        doc = hasDoc ? JSON.parse(JSON.stringify(w.edited || w.draft)) : null
        seeding = false
    }
    function flush() {
        if (save.running) { save.stop(); if (docFor && doc) engine.saveWrapup(docFor, doc) }
    }
    function revert() {
        save.stop()
        engine.saveWrapup(m.id, {})
        seeding = true
        doc = w.draft ? JSON.parse(JSON.stringify(w.draft)) : null
        seeding = false
    }
    Component.onDestruction: flush()
    // Changes made elsewhere (a tick in Follow-ups or Notion, the to-do links
    // a send adds) come in whenever Chris isn't in the middle of typing here.
    onWChanged: Qt.callLater(pickUp)
    function pickUp() {
        if (!doc || docFor !== (m.id || "") || save.running || focusInside()) return
        const fresh = w.edited || w.draft
        if (!fresh || JSON.stringify(fresh) === JSON.stringify(doc)) return
        seeding = true
        doc = JSON.parse(JSON.stringify(fresh))
        seeding = false
    }
    function focusInside() {
        for (let i = win.activeFocusItem; i; i = i.parent)
            if (i === root) return true
        return false
    }
    // Text typed into a field changes the document in place (no rebuild, so
    // the cursor stays put); adding, removing or ticking rebuilds the lists.
    function touched() { saved.running = false; save.restart() }
    function rebuilt() { doc = Object.assign({}, doc); touched() }
    Timer {
        id: save
        interval: 700
        onTriggered: { if (root.docFor && root.doc) engine.saveWrapup(root.docFor, root.doc); saved.restart() }
    }
    Timer { id: saved; interval: 1600 }

    function addItem(list, item) { doc[list] = (doc[list] || []).concat([item]); rebuilt(); focusLast = list }
    function removeItem(list, i) { const a = doc[list].slice(); a.splice(i, 1); doc[list] = a; rebuilt() }
    property string focusLast: ""

    // ---- nothing yet, drafting, or it failed ----
    Item {
        anchors.fill: parent
        visible: !root.hasDoc

        Column {
            anchors.centerIn: parent
            width: Math.min(parent.width - 64, 460)
            spacing: 14

            // Drafting: the dot, how long, and bars standing in for the notes.
            Column {
                width: parent.width
                spacing: 14
                visible: root.drafting
                Row {
                    spacing: 10
                    Rectangle {
                        width: 9; height: 9; radius: 4.5
                        anchors.verticalCenter: parent.verticalCenter
                        color: theme.accent
                        SequentialAnimation on opacity {
                            running: root.drafting && root.visible
                            loops: Animation.Infinite
                            NumberAnimation { to: 0.25; duration: 700; easing.type: Easing.InOutSine }
                            NumberAnimation { to: 1; duration: 700; easing.type: Easing.InOutSine }
                        }
                    }
                    Label {
                        text: qsTr("Opus is reading %n lines…", "", root.m.lines || 0)
                        color: ui.text
                        font.pixelSize: 15
                        font.bold: true
                    }
                }
                Label {
                    width: parent.width
                    wrapMode: Text.Wrap
                    text: qsTr("Usually a minute or two. Keep working; the wrap-up shows up here when it's ready.")
                          + (root.w.started ? "  " + Sidecar.elapsed({ started: root.w.started }, root.now) : "")
                    color: ui.muted
                    font.pixelSize: 12
                }
                Column {
                    width: parent.width
                    spacing: 9
                    topPadding: 6
                    Repeater {
                        model: [0.92, 0.78, 0.86, 0.4, 0.7, 0.55]
                        Rectangle {
                            required property real modelData
                            required property int index
                            width: parent.width * modelData
                            height: index === 3 ? 0 : 9
                            radius: 3
                            color: ui.raised
                            SequentialAnimation on opacity {
                                running: root.drafting && root.visible
                                loops: Animation.Infinite
                                PauseAnimation { duration: index * 90 }
                                NumberAnimation { to: 0.4; duration: 800; easing.type: Easing.InOutSine }
                                NumberAnimation { to: 1; duration: 800; easing.type: Easing.InOutSine }
                            }
                        }
                    }
                }
            }

            // Not drafted yet, or the draft failed.
            Column {
                width: parent.width
                spacing: 10
                visible: !root.drafting
                Label {
                    width: parent.width
                    wrapMode: Text.Wrap
                    text: root.w.state === "failed" ? qsTr("The wrap-up couldn't be drafted")
                        : (root.m.lines || 0) === 0 ? qsTr("Nobody spoke in this one")
                        : qsTr("No wrap-up yet")
                    color: ui.text
                    font.pixelSize: 17
                    font.bold: true
                }
                Label {
                    width: parent.width
                    wrapMode: Text.Wrap
                    visible: text !== ""
                    text: root.w.state === "failed" ? (root.w.error || "")
                        : (root.m.lines || 0) === 0 ? ""
                        : root.m.skipped ? qsTr("Marked as needing no wrap-up. Draft one anyway if you want it.")
                        : qsTr("Opus reads the whole meeting and drafts the summary, what you have to do, what the others committed to, decisions and open questions. You check it, then send it to Notion.")
                    color: root.w.state === "failed" ? ui.danger : ui.muted
                    font.pixelSize: 12
                    lineHeight: 1.25
                }
                Flow {
                    width: parent.width
                    spacing: 8
                    topPadding: 8
                    visible: (root.m.lines || 0) > 0
                    ActionButton {
                        primary: true
                        text: root.w.state === "failed" ? qsTr("Try again") : qsTr("Draft the wrap-up")
                        keys: "D"
                        onClicked: win.act("draft", root.m)
                    }
                    ActionButton {
                        visible: !root.m.skipped
                        text: qsTr("No wrap-up needed")
                        keys: "X"
                        onClicked: win.act("skip", root.m)
                    }
                }
            }
        }
    }

    // ---- the notes ----
    Flickable {
        id: flick
        anchors.fill: parent
        visible: root.hasDoc && root.doc !== null
        contentHeight: page.implicitHeight + 40
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        ColumnLayout {
            id: page
            readonly property real side: root.width < 560 ? 18 : 32
            x: side
            y: 18
            width: Math.min(root.width - side * 2, 820)
            spacing: 0
            opacity: root.drafting ? 0.45 : 1
            Behavior on opacity { NumberAnimation { duration: 200 } }

            // Where it stands: drafted, edited, saved, in Notion, sending.
            Rectangle {
                Layout.fillWidth: true
                Layout.bottomMargin: 12
                implicitHeight: statusRow.implicitHeight + 12
                radius: Math.min(6, theme.radius)
                color: root.stage === "sendFailed" ? ui.wash(ui.danger, 0.1)
                     : root.stage === "sent" ? ui.wash(ui.them, 0.08) : ui.panel
                border.color: root.stage === "sendFailed" ? ui.alpha(ui.danger, 0.45)
                            : root.stage === "sent" ? ui.alpha(ui.them, 0.35) : ui.line
                RowLayout {
                    id: statusRow
                    anchors.fill: parent
                    anchors.margins: 6
                    anchors.leftMargin: 14
                    spacing: 10
                    Rectangle {
                        width: 8; height: 8; radius: 4
                        color: root.stage === "sent" ? ui.them : root.stage === "sendFailed" ? ui.danger
                             : root.stage === "sending" || root.drafting ? theme.accent : ui.muted
                        SequentialAnimation on opacity {
                            running: root.stage === "sending" || root.drafting
                            loops: Animation.Infinite
                            NumberAnimation { to: 0.25; duration: 600 }
                            NumberAnimation { to: 1; duration: 600 }
                        }
                    }
                    // What's next, and how it got here, on one line.
                    RowLayout {
                        Layout.fillWidth: true
                        spacing: 10
                        Label {
                            elide: Text.ElideRight
                            Layout.preferredWidth: implicitWidth
                            Layout.minimumWidth: Math.min(implicitWidth, 60)
                            color: ui.text
                            font.pixelSize: 12
                            font.bold: true
                            text: root.drafting ? qsTr("Drafting again…")
                                : root.stage === "sent" ? qsTr("In Notion")
                                : root.stage === "sending" ? qsTr("Sending to Notion…")
                                : root.stage === "sendFailed" ? qsTr("Couldn't finish sending to Notion")
                                : qsTr("Check it, then send it")
                        }
                        Label {
                            Layout.fillWidth: true
                            Layout.preferredWidth: 0
                            elide: Text.ElideRight
                            visible: text !== ""
                            color: root.stage === "sendFailed" ? ui.danger : ui.faint
                            font.pixelSize: 11
                            text: {
                                if (root.stage === "sendFailed") return root.notion.error || ""
                                if (root.stage === "sending") {
                                    const total = (root.notion.total || 0)
                                    return total ? qsTr("%1 of %2 sections").arg(Math.min(root.notion.sections || 0, total)).arg(total)
                                                   + ((root.notion.lines || 0) ? qsTr(", transcript going in") : "")
                                                 : qsTr("Making the page")
                                }
                                if (root.stage === "sent") return (root.notion.filled ? qsTr("Filled in an existing page") : qsTr("New page in My Meetings"))
                                                                 + (root.notion.sent ? "  ·  " + Sidecar.when(root.notion.sent, root.now) : "")
                                let s = root.w.drafted ? qsTr("Drafted by Opus %1").arg(Sidecar.when(root.w.drafted, root.now)) : ""
                                if (root.w.edited) s += "  ·  " + (save.running ? qsTr("editing") : saved.running ? qsTr("saved") : qsTr("edited"))
                                if (root.w.error) s += "  ·  " + qsTr("the last redraft failed")
                                return s
                            }
                        }
                    }
                    ActionButton {
                        visible: root.stage !== "sent"
                        primary: true
                        implicitHeight: 30
                        busy: root.stage === "sending"
                        enabled: root.stage !== "sending" && !root.drafting
                        text: root.stage === "sendFailed" ? qsTr("Try again") : root.stage === "sending" ? qsTr("Sending")
                            : root.width < 560 ? qsTr("Send") : qsTr("Send to Notion")
                        keys: root.stage === "sending" ? "" : "S"
                        onClicked: win.act("send", root.m)
                    }
                    ActionButton {
                        visible: root.stage === "sent"
                        implicitHeight: 30
                        text: qsTr("Open in Notion ↗")
                        keys: "O"
                        onClicked: win.act("notion", root.m)
                    }
                    ActionButton {
                        visible: root.width >= 440
                        implicitHeight: 30
                        text: qsTr("Email")
                        tip: qsTr("Write the follow-up email, saved to Outlook Drafts (W)")
                        keys: root.width >= 700 ? "W" : ""
                        onClicked: win.act("email", root.m)
                    }
                    ActionButton {
                        visible: root.width >= 520
                        implicitHeight: 30
                        text: qsTr("Copy")
                        tip: qsTr("Copy as Markdown")
                        keys: root.width >= 700 ? "C" : ""
                        onClicked: win.act("copyNotes", root.m)
                    }
                }
            }

            // The title it's filed under in Notion; the header above already
            // says when and how long.
            RowLayout {
                Layout.fillWidth: true
                Layout.bottomMargin: 2
                spacing: 8
                Label {
                    Layout.alignment: Qt.AlignVCenter
                    Layout.topMargin: 2
                    text: qsTr("Filed as")
                    color: ui.faint
                    font.pixelSize: 11
                }
                Field {
                    Layout.fillWidth: true
                    size: 15
                    bold: true
                    placeholder: qsTr("Title")
                    text: root.doc ? root.doc.title : ""
                    onEdited: t => { root.doc.title = t; root.touched() }
                }
            }

            Heading { text: qsTr("TL;DR") }
            Field {
                Layout.fillWidth: true
                size: 15
                multiline: true
                placeholder: qsTr("One or two sentences on what came of it")
                Layout.leftMargin: -6
                text: root.doc ? root.doc.tldr : ""
                onEdited: t => { root.doc.tldr = t; root.touched() }
            }
            Field {
                Layout.fillWidth: true
                Layout.topMargin: 6
                size: 13
                multiline: true
                tone: ui.muted
                placeholder: qsTr("Summary")
                Layout.leftMargin: -6
                text: root.doc ? root.doc.summary : ""
                onEdited: t => { root.doc.summary = t; root.touched() }
            }

            // What Chris has to do: the list that matters most.
            Heading {
                text: qsTr("For me to do")
                count: root.doc ? root.doc.mine.length : 0
                accent: true
                onAdd: root.addItem("mine", { text: "", due: "", at: -1 })
            }
            Repeater {
                model: root.doc ? root.doc.mine : []
                delegate: ItemRow {
                    Layout.fillWidth: true
                    list: "mine"
                    checkable: true
                    placeholder: qsTr("Something to do")
                }
            }
            Empty { visible: !!root.doc && root.doc.mine.length === 0; text: qsTr("Nothing for you. + adds one.") }

            Heading {
                text: qsTr("They committed to")
                count: root.doc ? root.doc.theirs.length : 0
                onAdd: root.addItem("theirs", { who: "They", text: "", due: "", at: -1 })
            }
            Repeater {
                model: root.doc ? root.doc.theirs : []
                delegate: ItemRow { Layout.fillWidth: true; list: "theirs"; hasWho: true; placeholder: qsTr("What they'll do") }
            }
            Empty { visible: !!root.doc && root.doc.theirs.length === 0; text: qsTr("No promises from the others.") }

            Heading {
                text: qsTr("Decided")
                count: root.doc ? root.doc.decisions.length : 0
                onAdd: root.addItem("decisions", { text: "", due: "", at: -1 })
            }
            Repeater {
                model: root.doc ? root.doc.decisions : []
                delegate: ItemRow { Layout.fillWidth: true; list: "decisions"; hasDue: false; placeholder: qsTr("A decision") }
            }
            Empty { visible: !!root.doc && root.doc.decisions.length === 0; text: qsTr("Nothing decided.") }

            Heading {
                text: qsTr("Still open")
                count: root.doc ? root.doc.questions.length : 0
                onAdd: root.addItem("questions", { text: "", due: "", at: -1 })
            }
            Repeater {
                model: root.doc ? root.doc.questions : []
                delegate: ItemRow { Layout.fillWidth: true; list: "questions"; hasDue: false; placeholder: qsTr("An open question") }
            }
            Empty { visible: !!root.doc && root.doc.questions.length === 0; text: qsTr("Nothing left open.") }

            Heading {
                text: qsTr("Topics")
                count: root.doc ? root.doc.topics.length : 0
                onAdd: root.addItem("topics", { title: "", points: [] })
            }
            Repeater {
                model: root.doc ? root.doc.topics : []
                delegate: ColumnLayout {
                    id: topic
                    required property var modelData
                    required property int index
                    Layout.fillWidth: true
                    Layout.bottomMargin: 10
                    spacing: 2
                    RowLayout {
                        Layout.fillWidth: true
                        Field {
                            Layout.fillWidth: true
                            size: 13
                            bold: true
                            placeholder: qsTr("Topic")
                            text: topic.modelData.title
                            onEdited: t => { root.doc.topics[topic.index].title = t; root.touched() }
                        }
                        Remove { onClicked: root.removeItem("topics", topic.index) }
                    }
                    Field {
                        Layout.fillWidth: true
                        Layout.leftMargin: 14
                        size: 12
                        multiline: true
                        tone: ui.muted
                        placeholder: qsTr("Points, one per line")
                        text: topic.modelData.points.map(p => "• " + p).join("\n")
                        onEdited: t => {
                            root.doc.topics[topic.index].points = t.split("\n").map(s => s.replace(/^\s*[•\-*]\s*/, "").trim()).filter(s => s !== "")
                            root.touched()
                        }
                    }
                }
            }

            // How it's filed: the database's own names and tags, and the format.
            Heading { text: qsTr("Filed in Notion as") }
            GridLayout {
                Layout.fillWidth: true
                columns: 2
                columnSpacing: 16
                rowSpacing: 10
                Label { text: qsTr("With"); color: ui.faint; font.pixelSize: 11 }
                Picks { Layout.fillWidth: true; list: "met_with"; none: qsTr("No one from the database's list") }
                Label { text: qsTr("Tags"); color: ui.faint; font.pixelSize: 11 }
                Picks { Layout.fillWidth: true; list: "tags"; none: qsTr("No tags") }
                Label { text: qsTr("Format"); color: ui.faint; font.pixelSize: 11 }
                Row {
                    spacing: 6
                    Repeater {
                        model: ["Video", "Phone", "In person"]
                        Chip {
                            required property string modelData
                            text: modelData
                            filled: !!root.doc && root.doc.format === modelData
                            tone: filled ? theme.accent : ui.faint
                            HoverHandler { cursorShape: Qt.PointingHandCursor }
                            TapHandler { onTapped: { root.doc.format = modelData; root.rebuilt() } }
                        }
                    }
                }
            }
            Label {
                Layout.fillWidth: true
                Layout.topMargin: 14
                wrapMode: Text.Wrap
                text: qsTr("The transcript goes in too, folded away at the bottom of the page.")
                color: ui.faint
                font.pixelSize: 11
            }
        }
    }

    // ---- pieces ----

    // A section's name in small capitals, how many, and + to add one.
    component Heading: RowLayout {
        id: heading
        property string text
        property int count: -1
        property bool accent: false
        signal add()
        Layout.fillWidth: true
        Layout.topMargin: 24
        Layout.bottomMargin: 8
        spacing: 8
        Label {
            text: heading.text.toUpperCase()
            color: heading.accent ? theme.accent : ui.muted
            font.pixelSize: 11
            font.letterSpacing: 1.5
            font.bold: true
        }
        Label {
            visible: heading.count > 0
            text: heading.count
            color: ui.faint
            font.pixelSize: 11
        }
        Rectangle { Layout.fillWidth: true; height: 1; color: ui.line; Layout.alignment: Qt.AlignVCenter }
        Label {
            visible: heading.count >= 0
            text: "+"
            color: addHover.hovered ? theme.accent : ui.faint
            font.pixelSize: 16
            HoverHandler { id: addHover; cursorShape: Qt.PointingHandCursor }
            TapHandler { onTapped: heading.add() }
            ToolTip.visible: addHover.hovered
            ToolTip.delay: 500
            ToolTip.text: qsTr("Add")
        }
    }

    component Empty: Label {
        Layout.fillWidth: true
        color: ui.faint
        font.pixelSize: 12
        font.italic: true
    }

    // Text that's edited where it's read: no box until it's hovered or
    // focused, then a quiet one.
    component Field: Rectangle {
        id: field
        property alias text: edit.text
        property string placeholder
        property int size: 13
        property bool bold: false
        property bool multiline: false
        property bool strike: false
        property color tone: ui.text
        property alias input: edit
        signal edited(string text)
        implicitHeight: edit.implicitHeight + 8
        radius: Math.min(4, theme.radius)
        color: edit.activeFocus ? ui.panel : fieldHover.hovered ? ui.alpha(ui.hover, 0.5) : "transparent"
        border.color: edit.activeFocus ? ui.alpha(theme.accent, 0.6) : "transparent"
        HoverHandler { id: fieldHover; cursorShape: Qt.IBeamCursor }
        TextEdit {
            id: edit
            x: 6
            y: 4
            width: parent.width - 12
            color: field.tone
            font.pixelSize: field.size
            font.bold: field.bold
            font.strikeout: field.strike
            wrapMode: TextEdit.Wrap
            selectByMouse: true
            selectionColor: ui.alpha(theme.accent, 0.35)
            selectedTextColor: ui.text
            onTextChanged: if (activeFocus && !root.seeding) field.edited(text)
            Keys.onReturnPressed: event => { if (field.multiline && !(event.modifiers & Qt.ControlModifier)) event.accepted = false; else edit.focus = false }
            Keys.onEnterPressed: event => { if (field.multiline && !(event.modifiers & Qt.ControlModifier)) event.accepted = false; else edit.focus = false }
            Keys.onEscapePressed: edit.focus = false
            Text {
                visible: edit.text === ""
                text: field.placeholder
                color: ui.faint
                font: edit.font
            }
        }
    }

    component Remove: Label {
        signal clicked()
        text: "×"
        color: removeArea.containsMouse ? ui.danger : ui.faint
        font.pixelSize: 15
        MouseArea {
            id: removeArea
            anchors.fill: parent
            anchors.margins: -4
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: parent.clicked()
        }
        ToolTip.visible: removeArea.containsMouse
        ToolTip.delay: 500
        ToolTip.text: qsTr("Remove")
    }

    // One follow-up, commitment, decision or question: a tick (for Chris's
    // own), who, what, when, and the moment it was said.
    component ItemRow: Rectangle {
        id: item
        required property var modelData
        required property int index
        property string list
        property bool checkable: false
        property bool hasWho: false
        property bool hasDue: true
        property string placeholder
        readonly property bool hovered: rowHover.hovered
        readonly property bool done: !!modelData.done
        implicitHeight: itemRow.implicitHeight + 6
        radius: Math.min(4, theme.radius)
        color: rowHover.hovered ? ui.alpha(ui.hover, 0.35) : "transparent"
        HoverHandler { id: rowHover }
        Component.onCompleted: if (root.focusLast === list && index === root.doc[list].length - 1) {
            root.focusLast = ""
            Qt.callLater(() => what.input.forceActiveFocus())
        }

        RowLayout {
            id: itemRow
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            spacing: 6
            // A tick box, or a bullet.
            Rectangle {
                Layout.alignment: Qt.AlignTop
                Layout.topMargin: 7
                Layout.leftMargin: 4
                width: 14; height: 14
                radius: item.checkable ? Math.min(3, theme.radius) : 7
                visible: item.checkable
                color: item.done ? theme.accent : "transparent"
                border.color: item.done ? theme.accent : ui.muted
                Text { anchors.centerIn: parent; visible: item.done; text: "✓"; color: theme.accentForeground; font.pixelSize: 10; font.bold: true }
                MouseArea {
                    anchors.fill: parent
                    anchors.margins: -4
                    cursorShape: Qt.PointingHandCursor
                    onClicked: { root.doc[item.list][item.index].done = !item.done; root.rebuilt() }
                }
            }
            Rectangle {
                visible: !item.checkable
                Layout.alignment: Qt.AlignTop
                Layout.topMargin: 11
                Layout.leftMargin: 8
                Layout.rightMargin: 2
                width: 5; height: 5; radius: 2.5
                color: ui.muted
            }
            Field {
                visible: item.hasWho
                Layout.alignment: Qt.AlignTop
                Layout.preferredWidth: Math.min(Math.max(60, implicitWidthHint + 16), 160)
                readonly property real implicitWidthHint: whoMetrics.advanceWidth
                TextMetrics { id: whoMetrics; text: item.modelData.who || ""; font.pixelSize: 13; font.bold: true }
                size: 13
                bold: true
                tone: ui.them
                placeholder: qsTr("Who")
                text: item.modelData.who || ""
                onEdited: t => { root.doc[item.list][item.index].who = t; root.touched() }
            }
            Field {
                id: what
                Layout.fillWidth: true
                Layout.alignment: Qt.AlignTop
                size: 13
                multiline: false
                strike: item.done
                tone: item.done ? ui.faint : ui.text
                placeholder: item.placeholder
                text: item.modelData.text
                onEdited: t => { root.doc[item.list][item.index].text = t; root.touched() }
            }
            // When: a quiet chip that's edited in place.
            Field {
                visible: item.hasDue && (item.modelData.due || rowHover.hovered || activeFocusWithin)
                readonly property bool activeFocusWithin: input.activeFocus
                Layout.alignment: Qt.AlignTop
                Layout.preferredWidth: Math.min(Math.max(56, dueMetrics.advanceWidth + 18), root.width < 560 ? 84 : 130)
                TextMetrics { id: dueMetrics; text: item.modelData.due || qsTr("when?"); font.pixelSize: 11 }
                size: 11
                tone: item.modelData.due ? theme.accent : ui.faint
                placeholder: qsTr("when?")
                text: item.modelData.due || ""
                onEdited: t => { root.doc[item.list][item.index].due = t; root.touched() }
            }
            // The moment it was said: a jump into the transcript.
            Label {
                Layout.alignment: Qt.AlignTop
                Layout.topMargin: 6
                // Read again whenever the transcript (re)loads.
                readonly property double said: transcript.count > 0 ? transcript.startOf(item.modelData.at) : 0
                visible: item.modelData.at >= 0 && said > 0
                text: root.width < 560 ? "↗" : "↗ " + Sidecar.seconds(said)
                color: jumpHover.hovered ? theme.accent : ui.faint
                font.pixelSize: 11
                HoverHandler { id: jumpHover; cursorShape: Qt.PointingHandCursor }
                TapHandler { onTapped: root.showLine(item.modelData.at) }
                ToolTip.visible: jumpHover.hovered
                ToolTip.delay: 500
                ToolTip.text: qsTr("Show where it was said")
            }
            Remove {
                Layout.alignment: Qt.AlignTop
                Layout.topMargin: 3
                Layout.rightMargin: 4
                onClicked: root.removeItem(item.list, item.index)
            }
        }
    }

    // The database's names or tags this meeting is filed under; × drops one.
    component Picks: Flow {
        id: picks
        property string list
        property string none
        spacing: 6
        Label {
            visible: !root.doc || (root.doc[picks.list] || []).length === 0
            text: picks.none
            color: ui.faint
            font.pixelSize: 11
            font.italic: true
        }
        Repeater {
            model: root.doc ? root.doc[picks.list] : []
            Chip {
                required property string modelData
                required property int index
                text: modelData + "  ×"
                tone: ui.text
                HoverHandler { cursorShape: Qt.PointingHandCursor }
                TapHandler { onTapped: root.removeItem(picks.list, index) }
            }
        }
    }
}
