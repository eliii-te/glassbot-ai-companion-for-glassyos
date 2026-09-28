import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtQuick.Effects
import Quickshell
import Quickshell.Io
import "../"

Item {
    id: root

    MatugenColors { id: theme }

    property var notifModel: null

    // Conversation state for the active chat
    property string activeId: ""
    property string activeTitle: ""
    property var messages: []
    property bool thinking: false
    property string streamingText: ""
    property string ollamaStatus: "checking"
    property string activeModel: ""
    property bool modelPresent: false
    property string activeBackend: ""        // "cloud" or "local" — which served the last turn
    property string defaultBackend: ""       // resolved default at boot
    property bool cloudConfigured: false
    property string cloudModel: ""

    // Sidebar state
    property var chats: []   // [{id, title, updated}]
    property bool sidebarOpen: false

    // Onboarding state — gates the main UI on first run.
    property bool setupDone: true        // true until backend tells us otherwise
    property var suggestedModels: []     // [{name, label, size_gb, recommended}]
    property var installedModels: []
    property int onboardStep: 0          // 0 welcome, 1 model, 2 provider, 3 key
    property string onboardSelectedModel: ""
    property string onboardPullStatus: ""
    property int onboardPullPercent: -1
    property bool onboardModelInstalling: false
    property bool onboardKeyChecking: false
    property string onboardKeyMessage: ""
    property bool onboardKeyValid: false
    property var onboardProviders: []   // [{id, label, tagline, key_page, default_model}]
    property string onboardSelectedProvider: "openrouter"

    readonly property bool empty: messages.length === 0 && streamingText === "" && !thinking

    // ----- Backend bridge -----
    // Resolve the backend path PORTABLY instead of hard-coding /home/<user>:
    //   1. $GLASSBOT_BACKEND if set (explicit override),
    //   2. $HOME/.local/bin/glassbot-backend (default install location),
    //   3. bare "glassbot-backend" (fall back to PATH lookup).
    // Quickshell launches with a stripped PATH that usually omits ~/.local/bin,
    // which is why a bare command name alone never resolved before. Using $HOME
    // instead of a literal /home/elias fixes the silent auto-respawn loop for
    // every username other than "elias".
    readonly property string backendPath: {
        const override = Quickshell.env("GLASSBOT_BACKEND");
        if (override && override !== "")
            return override;
        const home = Quickshell.env("HOME");
        if (home && home !== "")
            return home + "/.local/bin/glassbot-backend";
        return "glassbot-backend";
    }

    Process {
        id: bot
        command: [root.backendPath, "--ipc"]
        running: true
        stdinEnabled: true

        // Auto-respawn if backend dies — keeps onboarding alive across crashes.
        onRunningChanged: {
            if (!running) {
                root.onboardModelInstalling = false;
                root.thinking = false;
                respawnTimer.start();
            }
        }

        stdout: SplitParser {
            onRead: (line) => {
                let j;
                try { j = JSON.parse(line); } catch (e) { return; }

                if (j.type === "delta") {
                    root.streamingText += j.text;
                    Qt.callLater(scrollToBottom);

                } else if (j.type === "end") {
                    if (root.streamingText !== "") {
                        let arr = root.messages.slice();
                        arr.push({
                            role: "assistant",
                            text: root.streamingText,
                            search: !!j.search_used
                        });
                        root.messages = arr;
                    }
                    root.streamingText = "";
                    root.thinking = false;
                    if (j.active_id) root.activeId = j.active_id;
                    Qt.callLater(scrollToBottom);

                } else if (j.type === "search_results") {
                    let arr = root.messages.slice();
                    arr.push({
                        role: "search",
                        text: "",
                        results: j.items,
                        query: j.query
                    });
                    root.messages = arr;
                    Qt.callLater(scrollToBottom);

                } else if (j.type === "status") {
                    root.ollamaStatus = j.ok ? "ok" : "down";
                    root.activeModel = j.model || "";
                    root.modelPresent = !!j.model_present;
                    root.cloudConfigured = !!j.cloud_configured;
                    root.cloudModel = j.cloud_model || "";
                    root.defaultBackend = j.backend_default || "";
                    if (root.activeBackend === "")
                        root.activeBackend = root.defaultBackend;

                } else if (j.type === "backend_used") {
                    root.activeBackend = j.backend || "";

                } else if (j.type === "boot_state") {
                    root.activeId = j.active_id || "";
                    root.messages = j.messages || [];
                    root.chats = j.chats || [];
                    root.streamingText = "";
                    root.thinking = false;
                    if (j.suggested_models) root.suggestedModels = j.suggested_models;
                    if (j.installed_models) root.installedModels = j.installed_models;
                    if (j.providers) root.onboardProviders = j.providers;
                    // Don't reset onboardStep here — backend may respawn
                    // mid-onboarding and a reset would yank user back to Welcome.
                    if (j.setup_done === false) {
                        root.setupDone = false;
                    } else {
                        root.setupDone = true;
                    }
                    Qt.callLater(scrollToBottom);

                } else if (j.type === "setup_state") {
                    root.setupDone = !!j.done;
                    if (j.suggested_models) root.suggestedModels = j.suggested_models;
                    if (j.installed_models) root.installedModels = j.installed_models;
                    if (j.providers) root.onboardProviders = j.providers;
                    if (j.cloud_provider) root.onboardSelectedProvider = j.cloud_provider;

                } else if (j.type === "setup_progress") {
                    root.onboardPullStatus = j.message || "";
                    root.onboardPullPercent = (j.percent === null || j.percent === undefined) ? -1 : j.percent;

                } else if (j.type === "setup_result") {
                    if (j.stage === "model") {
                        root.onboardModelInstalling = false;
                        if (j.ok) {
                            root.onboardPullStatus = "Installed " + (j.model || "");
                            root.onboardPullPercent = 100;
                            root.activeModel = j.model || root.activeModel;
                            root.onboardStep = 2;
                        } else {
                            root.onboardPullStatus = "Failed: " + (j.error || "unknown error");
                            root.onboardPullPercent = -1;
                        }
                    } else if (j.stage === "key") {
                        root.onboardKeyChecking = false;
                        root.onboardKeyValid = !!j.ok;
                        root.onboardKeyMessage = j.message || "";
                        if (j.ok) root.cloudConfigured = true;
                    } else if (j.stage === "finish" || j.stage === "skip") {
                        if (j.ok) {
                            root.setupDone = true;
                            root.onboardStep = 0;
                        }
                    }

                } else if (j.type === "files_read") {
                    let arr = root.messages.slice();
                    arr.push({
                        role: "filesread",
                        text: "",
                        paths: j.paths || []
                    });
                    root.messages = arr;
                    Qt.callLater(scrollToBottom);

                } else if (j.type === "tool_request") {
                    let arr = root.messages.slice();
                    arr.push({
                        role: "toolrequest",
                        toolId: j.id,
                        command: j.command,
                        state: "pending"
                    });
                    root.messages = arr;
                    Qt.callLater(scrollToBottom);

                } else if (j.type === "tool_running") {
                    let arr = root.messages.slice();
                    for (let i = 0; i < arr.length; i++) {
                        if (arr[i].role === "toolrequest" && arr[i].toolId === j.id) {
                            arr[i] = Object.assign({}, arr[i], { state: "running" });
                        }
                    }
                    root.messages = arr;

                } else if (j.type === "tool_result") {
                    let arr = root.messages.slice();
                    for (let i = 0; i < arr.length; i++) {
                        if (arr[i].role === "toolrequest" && arr[i].toolId === j.id) {
                            arr[i] = Object.assign({}, arr[i], {
                                state: j.ok ? "done" : "failed",
                                output: j.output || "",
                                exitCode: j.exit_code,
                                errorMsg: j.error || ""
                            });
                        }
                    }
                    root.messages = arr;
                    root.thinking = true;  // assistant follow-up incoming
                    Qt.callLater(scrollToBottom);

                } else if (j.type === "tool_denied") {
                    let arr = root.messages.slice();
                    for (let i = 0; i < arr.length; i++) {
                        if (arr[i].role === "toolrequest" && arr[i].toolId === j.id) {
                            arr[i] = Object.assign({}, arr[i], { state: "denied" });
                        }
                    }
                    root.messages = arr;

                } else if (j.type === "chats_refresh") {
                    root.chats = j.items || [];
                    if (j.active_id) root.activeId = j.active_id;

                } else if (j.type === "chat_loaded") {
                    root.activeId = j.id || "";
                    root.activeTitle = j.title || "";
                    root.messages = j.messages || [];
                    root.streamingText = "";
                    root.thinking = false;
                    Qt.callLater(scrollToBottom);

                } else if (j.type === "error") {
                    let arr = root.messages.slice();
                    arr.push({ role: "error", text: j.msg });
                    root.messages = arr;
                    root.thinking = false;
                    Qt.callLater(scrollToBottom);
                }
            }
        }
    }

    Timer {
        id: respawnTimer
        interval: 800
        repeat: false
        onTriggered: bot.running = true
    }

    function send(text) {
        let t = text.trim();
        if (t === "" || root.thinking) return;
        if (root.ollamaStatus === "down") return;

        if (t === "/new" || t === "/clear" || t === "/reset") {
            bot.write(JSON.stringify({ type: "new_chat" }) + "\n");
            return;
        }

        let arr = root.messages.slice();
        arr.push({ role: "user", text: t });
        root.messages = arr;
        root.thinking = true;
        root.streamingText = "";
        bot.write(JSON.stringify({ type: "chat", text: t }) + "\n");
        Qt.callLater(scrollToBottom);
    }

    function newChat() {
        bot.write(JSON.stringify({ type: "new_chat" }) + "\n");
    }

    function approveTool(id) {
        bot.write(JSON.stringify({ type: "tool_approve", id: id }) + "\n");
    }

    function denyTool(id) {
        bot.write(JSON.stringify({ type: "tool_deny", id: id }) + "\n");
    }

    // ----- Onboarding actions -----
    function onboardInstallModel(name) {
        root.onboardSelectedModel = name;
        root.onboardModelInstalling = true;
        root.onboardPullStatus = "Starting…";
        root.onboardPullPercent = 0;
        bot.write(JSON.stringify({ type: "setup_install_model", name: name }) + "\n");
    }

    function onboardSkipLocal() {
        root.onboardStep = 2;
    }

    function onboardSaveKey(key) {
        if (!key || key.trim() === "") return;
        root.onboardKeyChecking = true;
        root.onboardKeyMessage = "Validating…";
        bot.write(JSON.stringify({
            type: "setup_save_key",
            key: key.trim(),
            provider: root.onboardSelectedProvider
        }) + "\n");
    }

    function onboardPickProvider(id) {
        root.onboardSelectedProvider = id;
        root.onboardKeyMessage = "";
        root.onboardKeyValid = false;
        root.onboardStep = 3;
    }

    function onboardOpenKeyPage() {
        for (let i = 0; i < root.onboardProviders.length; i++) {
            if (root.onboardProviders[i].id === root.onboardSelectedProvider) {
                Qt.openUrlExternally(root.onboardProviders[i].key_page);
                return;
            }
        }
        Qt.openUrlExternally("https://openrouter.ai/keys");
    }

    function onboardSkipCloud() {
        bot.write(JSON.stringify({ type: "setup_finish" }) + "\n");
    }

    function onboardFinish() {
        bot.write(JSON.stringify({ type: "setup_finish" }) + "\n");
    }

    function openOpenRouter() {
        Qt.openUrlExternally("https://openrouter.ai/keys");
    }

    function openChat(id) {
        if (id === root.activeId) return;
        bot.write(JSON.stringify({ type: "open_chat", id: id }) + "\n");
    }

    function deleteChat(id) {
        bot.write(JSON.stringify({ type: "delete_chat", id: id }) + "\n");
    }

    function scrollToBottom() {
        chatView.positionViewAtEnd();
    }

    // ===================================================================
    // ROOT CARD
    // ===================================================================
    Rectangle {
        id: card
        anchors.fill: parent
        radius: 16
        color: theme.base
        border.width: 1
        border.color: Qt.alpha(theme.text, 0.08)
        clip: true

        Rectangle {
            anchors.fill: parent
            radius: 16
            gradient: Gradient {
                GradientStop { position: 0.0; color: Qt.alpha(theme.surface0, 0.6) }
                GradientStop { position: 0.5; color: "transparent" }
            }
        }

        // ===============================================================
        // MAIN AREA (always full width — sidebar overlays it)
        // ===============================================================
        Item {
            id: mainArea
            anchors.fill: parent

            // Eyes — big when empty, small at top when chatting
            Item {
                id: eyesArea
                anchors.horizontalCenter: parent.horizontalCenter
                property real bigT: root.empty ? 1.0 : 0.0
                Behavior on bigT { NumberAnimation { duration: 500; easing.type: Easing.OutCubic } }

                y: 18 + bigT * 110
                width: 110 + bigT * 130
                height: 56 + bigT * 70

                Row {
                    id: eyesRow
                    anchors.centerIn: parent
                    spacing: 16 + eyesArea.bigT * 24

                    SequentialAnimation on rotation {
                        loops: Animation.Infinite
                        NumberAnimation { to:  4; duration: 3600; easing.type: Easing.InOutSine }
                        NumberAnimation { to: -4; duration: 3600; easing.type: Easing.InOutSine }
                    }

                    Eye { eyeSize: 20 + eyesArea.bigT * 36; blinkSeed: 0.0 }
                    Eye { eyeSize: 20 + eyesArea.bigT * 36; blinkSeed: 0.7 }
                }
            }

            Text {
                id: wazzup
                anchors.top: eyesArea.bottom
                anchors.topMargin: 18
                anchors.horizontalCenter: parent.horizontalCenter
                text: "Whats up mate :)"
                color: theme.text
                font.pixelSize: 22
                font.weight: Font.Medium
                font.letterSpacing: 1.0
                opacity: root.empty ? 0.92 : 0.0
                visible: opacity > 0.01
                Behavior on opacity { NumberAnimation { duration: 280 } }
            }

            Text {
                id: wazzupSub
                anchors.top: wazzup.bottom
                anchors.topMargin: 10
                anchors.horizontalCenter: parent.horizontalCenter
                text: root.ollamaStatus === "ok"
                    ? "ask anything · /search · /new"
                    : root.ollamaStatus === "down"
                        ? "ollama isn’t running — sudo systemctl start ollama"
                        : "talking to ollama..."
                color: theme.subtext0
                font.pixelSize: 12
                opacity: root.empty ? 0.85 : 0.0
                visible: opacity > 0.01
                Behavior on opacity { NumberAnimation { duration: 280 } }
            }

            // ===== Top bar: hamburger left + title + model right =====
            Rectangle {
                id: hamburger
                anchors.left: parent.left
                anchors.top: parent.top
                anchors.leftMargin: 12
                anchors.topMargin: 14
                width: 32; height: 32
                radius: 10
                color: hamburgerHover.containsMouse
                    ? Qt.alpha(theme.text, 0.10)
                    : Qt.alpha(theme.surface0, 0.55)
                border.width: 1
                border.color: Qt.alpha(theme.text, 0.08)
                Behavior on color { ColorAnimation { duration: 140 } }

                // Three lines that morph into "X" when sidebar is open
                Item {
                    anchors.centerIn: parent
                    width: 16; height: 12
                    Rectangle {
                        x: 0; y: root.sidebarOpen ? 5 : 0
                        width: 16; height: 2; radius: 1
                        color: theme.text
                        rotation: root.sidebarOpen ? 45 : 0
                        Behavior on y { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }
                        Behavior on rotation { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }
                    }
                    Rectangle {
                        x: 0; y: 5
                        width: 16; height: 2; radius: 1
                        color: theme.text
                        opacity: root.sidebarOpen ? 0 : 1
                        Behavior on opacity { NumberAnimation { duration: 140 } }
                    }
                    Rectangle {
                        x: 0; y: root.sidebarOpen ? 5 : 10
                        width: 16; height: 2; radius: 1
                        color: theme.text
                        rotation: root.sidebarOpen ? -45 : 0
                        Behavior on y { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }
                        Behavior on rotation { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }
                    }
                }

                MouseArea {
                    id: hamburgerHover
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.sidebarOpen = !root.sidebarOpen
                }
            }

            Text {
                id: chatHeader
                anchors.left: hamburger.right
                anchors.leftMargin: 12
                anchors.right: modelLabel.left
                anchors.rightMargin: 8
                anchors.verticalCenter: hamburger.verticalCenter
                text: root.activeTitle && root.activeTitle.length > 0
                    ? root.activeTitle
                    : "glassbot"
                color: theme.text
                font.pixelSize: 13
                font.bold: !root.empty
                elide: Text.ElideRight
                opacity: root.empty ? 0.55 : 0.92
                Behavior on opacity { NumberAnimation { duration: 240 } }
            }

            Row {
                id: modelLabel
                anchors.right: parent.right
                anchors.rightMargin: 16
                anchors.verticalCenter: hamburger.verticalCenter
                spacing: 6
                opacity: root.empty ? 0.0 : 0.85
                Behavior on opacity { NumberAnimation { duration: 240 } }

                Text {
                    text: root.activeBackend === "cloud"
                        ? (root.cloudModel || "groq")
                        : (root.activeModel || "")
                    color: theme.subtext0
                    font.pixelSize: 10
                    font.italic: true
                    anchors.verticalCenter: parent.verticalCenter
                }

                Rectangle {
                    visible: root.activeBackend !== ""
                    anchors.verticalCenter: parent.verticalCenter
                    width: backendBadgeText.implicitWidth + 10
                    height: 14
                    radius: 7
                    color: root.activeBackend === "cloud"
                        ? Qt.rgba(0.40, 0.78, 1.0, 0.18)
                        : Qt.rgba(0.55, 0.95, 0.65, 0.16)
                    border.width: 1
                    border.color: root.activeBackend === "cloud"
                        ? Qt.rgba(0.40, 0.78, 1.0, 0.45)
                        : Qt.rgba(0.55, 0.95, 0.65, 0.40)

                    Text {
                        id: backendBadgeText
                        anchors.centerIn: parent
                        text: root.activeBackend === "cloud" ? "cloud" : "local"
                        font.pixelSize: 9
                        font.bold: true
                        color: root.activeBackend === "cloud"
                            ? Qt.rgba(0.55, 0.85, 1.0, 1.0)
                            : Qt.rgba(0.65, 0.95, 0.70, 1.0)
                    }
                }
            }

            // Chat list
            ListView {
                id: chatView
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.leftMargin: 14
                anchors.rightMargin: 14
                anchors.top: parent.top
                anchors.topMargin: 56
                anchors.bottom: inputBar.top
                anchors.bottomMargin: 10

                opacity: root.empty ? 0.0 : 1.0
                Behavior on opacity { NumberAnimation { duration: 260 } }

                spacing: 8
                clip: true
                model: root.messages

                ScrollBar.vertical: ScrollBar {
                    policy: ScrollBar.AsNeeded
                    width: 6
                    contentItem: Rectangle { color: Qt.alpha(theme.text, 0.25); radius: 3 }
                }

                onCountChanged: positionViewAtEnd()

                delegate: Loader {
                    width: chatView.width
                    sourceComponent: {
                        if (modelData.role === "search") return searchBubble;
                        if (modelData.role === "error") return errorBubble;
                        if (modelData.role === "filesread") return filesReadBubble;
                        if (modelData.role === "toolrequest") return toolRequestBubble;
                        return chatBubble;
                    }
                    property var msg: modelData
                }

                footer: Item {
                    width: chatView.width
                    height: (root.streamingText !== "" || root.thinking) ? streamWrap.height + 4 : 0
                    visible: root.streamingText !== "" || root.thinking

                    Item {
                        id: streamWrap
                        width: parent.width
                        height: streamingBubble.height

                        Rectangle {
                            id: streamingBubble
                            anchors.left: parent.left
                            width: Math.min(parent.width * 0.85,
                                            Math.max(140, streamText.implicitWidth + 28))
                            height: streamText.implicitHeight + 22
                            radius: 14
                            color: theme.surface0

                            Text {
                                id: streamText
                                anchors.fill: parent
                                anchors.leftMargin: 14
                                anchors.rightMargin: 14
                                anchors.topMargin: 10
                                anchors.bottomMargin: 10
                                text: root.streamingText !== "" ? root.streamingText : "thinking..."
                                wrapMode: Text.Wrap
                                color: theme.text
                                font.pixelSize: 15
                                opacity: root.streamingText !== "" ? 1.0 : 0.55
                                textFormat: Text.PlainText
                            }
                        }
                    }
                }
            }

            // ===== Bubble components =====
            Component {
                id: chatBubble
                Item {
                    width: chatView.width
                    implicitHeight: bubble.height + 4

                    Rectangle {
                        id: bubble
                        anchors.right: msg.role === "user" ? parent.right : undefined
                        anchors.left: msg.role === "user" ? undefined : parent.left
                        width: Math.min(parent.width * 0.88,
                                        Math.max(60, bubbleText.implicitWidth + 28))
                        height: bubbleText.implicitHeight + 22
                        radius: 14
                        color: msg.role === "user" ? theme.surface2 : theme.surface0
                        border.width: msg.search ? 1 : 0
                        border.color: msg.search ? Qt.alpha(theme.blue, 0.45) : "transparent"

                        Text {
                            id: bubbleText
                            anchors.fill: parent
                            anchors.leftMargin: 14
                            anchors.rightMargin: 14
                            anchors.topMargin: 10
                            anchors.bottomMargin: 10
                            text: msg.text || msg.content || ""
                            color: theme.text
                            wrapMode: Text.Wrap
                            font.pixelSize: 15
                            textFormat: Text.PlainText
                        }
                    }
                }
            }

            Component {
                id: errorBubble
                Item {
                    width: chatView.width
                    implicitHeight: ebubble.height + 4
                    Rectangle {
                        id: ebubble
                        anchors.left: parent.left
                        width: Math.min(parent.width * 0.88, etext.implicitWidth + 24)
                        height: etext.implicitHeight + 22
                        radius: 14
                        color: Qt.alpha(theme.red, 0.18)
                        border.width: 1
                        border.color: Qt.alpha(theme.red, 0.45)
                        Text {
                            id: etext
                            anchors.fill: parent
                            anchors.leftMargin: 12
                            anchors.rightMargin: 12
                            anchors.topMargin: 8
                            anchors.bottomMargin: 8
                            text: msg.text || msg.content || ""
                            color: theme.red
                            wrapMode: Text.Wrap
                            font.pixelSize: 14
                            textFormat: Text.PlainText
                        }
                    }
                }
            }

            Component {
                id: searchBubble
                Item {
                    width: chatView.width
                    implicitHeight: sbubble.height + 4
                    Rectangle {
                        id: sbubble
                        anchors.left: parent.left
                        anchors.right: parent.right
                        height: scol.implicitHeight + 16
                        radius: 14
                        color: Qt.alpha(theme.blue, 0.10)
                        border.width: 1
                        border.color: Qt.alpha(theme.blue, 0.35)

                        Column {
                            id: scol
                            anchors.fill: parent
                            anchors.leftMargin: 12
                            anchors.rightMargin: 12
                            anchors.topMargin: 8
                            anchors.bottomMargin: 8
                            spacing: 4

                            Text {
                                text: "🔎  search: " + (msg.query || "")
                                color: theme.blue
                                font.pixelSize: 12
                                font.bold: true
                                textFormat: Text.PlainText
                            }
                            Repeater {
                                model: msg.results || []
                                delegate: Column {
                                    spacing: 0
                                    Text {
                                        text: "[" + (index + 1) + "] " + (modelData.title || "")
                                        color: theme.text
                                        font.pixelSize: 11
                                        font.bold: true
                                        textFormat: Text.PlainText
                                        width: scol.width
                                        wrapMode: Text.Wrap
                                    }
                                    Text {
                                        text: "    " + (modelData.url || "")
                                        color: theme.subtext0
                                        font.pixelSize: 10
                                        textFormat: Text.PlainText
                                        width: scol.width
                                        elide: Text.ElideRight
                                    }
                                }
                            }
                        }
                    }
                }
            }

            Component {
                id: filesReadBubble
                Item {
                    width: chatView.width
                    implicitHeight: fbubble.height + 4
                    Rectangle {
                        id: fbubble
                        anchors.left: parent.left
                        anchors.right: parent.right
                        height: fcol.implicitHeight + 16
                        radius: 14
                        color: Qt.alpha(theme.green, 0.10)
                        border.width: 1
                        border.color: Qt.alpha(theme.green, 0.35)

                        Column {
                            id: fcol
                            anchors.fill: parent
                            anchors.leftMargin: 12
                            anchors.rightMargin: 12
                            anchors.topMargin: 8
                            anchors.bottomMargin: 8
                            spacing: 2

                            Text {
                                text: "📎  attached file" + ((msg.paths || []).length === 1 ? "" : "s")
                                color: theme.green
                                font.pixelSize: 12
                                font.bold: true
                                textFormat: Text.PlainText
                            }
                            Repeater {
                                model: msg.paths || []
                                delegate: Text {
                                    text: "  • " + modelData
                                    color: theme.text
                                    font.pixelSize: 11
                                    font.family: "monospace"
                                    textFormat: Text.PlainText
                                    width: fcol.width
                                    elide: Text.ElideMiddle
                                }
                            }
                        }
                    }
                }
            }

            Component {
                id: toolRequestBubble
                Item {
                    width: chatView.width
                    implicitHeight: tbubble.height + 4

                    readonly property bool pending: msg.state === "pending"
                    readonly property bool running: msg.state === "running"
                    readonly property bool done: msg.state === "done"
                    readonly property bool failed: msg.state === "failed"
                    readonly property bool denied: msg.state === "denied"

                    Rectangle {
                        id: tbubble
                        anchors.left: parent.left
                        anchors.right: parent.right
                        height: tcol.implicitHeight + 16
                        radius: 14
                        color: parent.pending
                            ? Qt.alpha("#ffc857", 0.10)
                            : parent.running
                                ? Qt.alpha(theme.blue, 0.10)
                                : parent.done
                                    ? Qt.alpha(theme.green, 0.10)
                                    : Qt.alpha(theme.red, 0.10)
                        border.width: 1
                        border.color: parent.pending
                            ? Qt.alpha("#ffc857", 0.45)
                            : parent.running
                                ? Qt.alpha(theme.blue, 0.45)
                                : parent.done
                                    ? Qt.alpha(theme.green, 0.45)
                                    : Qt.alpha(theme.red, 0.45)

                        Column {
                            id: tcol
                            anchors.fill: parent
                            anchors.leftMargin: 12
                            anchors.rightMargin: 12
                            anchors.topMargin: 8
                            anchors.bottomMargin: 8
                            spacing: 6

                            Text {
                                text: tbubble.parent.pending
                                    ? "⚙  Glassbot will gerne ausführen:"
                                    : tbubble.parent.running
                                        ? "⏳  Läuft…"
                                        : tbubble.parent.done
                                            ? "✓  Fertig (exit " + (msg.exitCode !== undefined ? msg.exitCode : "?") + ")"
                                            : tbubble.parent.denied
                                                ? "✕  Abgelehnt"
                                                : "✕  Fehlgeschlagen (exit " + (msg.exitCode !== undefined ? msg.exitCode : "?") + ")"
                                color: tbubble.parent.pending
                                    ? "#ffc857"
                                    : tbubble.parent.running
                                        ? theme.blue
                                        : tbubble.parent.done
                                            ? theme.green
                                            : theme.red
                                font.pixelSize: 12
                                font.bold: true
                                textFormat: Text.PlainText
                            }

                            Rectangle {
                                width: parent.width
                                height: cmdText.implicitHeight + 12
                                radius: 8
                                color: Qt.alpha(theme.text, 0.06)
                                border.width: 1
                                border.color: Qt.alpha(theme.text, 0.12)
                                Text {
                                    id: cmdText
                                    anchors.fill: parent
                                    anchors.leftMargin: 10
                                    anchors.rightMargin: 10
                                    anchors.topMargin: 6
                                    anchors.bottomMargin: 6
                                    text: msg.command || ""
                                    color: theme.text
                                    font.family: "monospace"
                                    font.pixelSize: 12
                                    wrapMode: Text.WrapAnywhere
                                    textFormat: Text.PlainText
                                }
                            }

                            Row {
                                spacing: 8
                                visible: tbubble.parent.pending

                                Rectangle {
                                    width: 90; height: 30; radius: 8
                                    color: allowMa.containsMouse
                                        ? Qt.alpha(theme.green, 0.30)
                                        : Qt.alpha(theme.green, 0.16)
                                    border.width: 1
                                    border.color: Qt.alpha(theme.green, 0.55)
                                    Text {
                                        anchors.centerIn: parent
                                        text: "Allow"
                                        color: theme.text
                                        font.pixelSize: 12
                                        font.bold: true
                                    }
                                    MouseArea {
                                        id: allowMa
                                        anchors.fill: parent
                                        hoverEnabled: true
                                        cursorShape: Qt.PointingHandCursor
                                        onClicked: root.approveTool(msg.toolId)
                                    }
                                }

                                Rectangle {
                                    width: 90; height: 30; radius: 8
                                    color: denyMa.containsMouse
                                        ? Qt.alpha(theme.red, 0.30)
                                        : Qt.alpha(theme.red, 0.14)
                                    border.width: 1
                                    border.color: Qt.alpha(theme.red, 0.50)
                                    Text {
                                        anchors.centerIn: parent
                                        text: "Deny"
                                        color: theme.text
                                        font.pixelSize: 12
                                    }
                                    MouseArea {
                                        id: denyMa
                                        anchors.fill: parent
                                        hoverEnabled: true
                                        cursorShape: Qt.PointingHandCursor
                                        onClicked: root.denyTool(msg.toolId)
                                    }
                                }
                            }

                            Rectangle {
                                width: parent.width
                                height: outText.implicitHeight + 12
                                radius: 8
                                color: Qt.alpha(theme.text, 0.04)
                                border.width: 1
                                border.color: Qt.alpha(theme.text, 0.10)
                                visible: (tbubble.parent.done || tbubble.parent.failed)
                                         && (msg.output || msg.errorMsg)
                                Text {
                                    id: outText
                                    anchors.fill: parent
                                    anchors.leftMargin: 10
                                    anchors.rightMargin: 10
                                    anchors.topMargin: 6
                                    anchors.bottomMargin: 6
                                    text: (msg.errorMsg ? msg.errorMsg + "\n" : "") + (msg.output || "")
                                    color: Qt.alpha(theme.text, 0.85)
                                    font.family: "monospace"
                                    font.pixelSize: 11
                                    wrapMode: Text.WrapAnywhere
                                    textFormat: Text.PlainText
                                }
                            }
                        }
                    }
                }
            }

            // ===== Input bar =====
            Rectangle {
                id: inputBar
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.bottom: parent.bottom
                anchors.margins: 12
                height: 52
                radius: 26
                color: theme.surface0
                border.width: 1
                border.color: input.activeFocus
                    ? Qt.alpha(theme.blue, 0.5)
                    : Qt.alpha(theme.text, 0.12)
                Behavior on border.color { ColorAnimation { duration: 180 } }

                Row {
                    anchors.fill: parent
                    anchors.leftMargin: 14
                    anchors.rightMargin: 6
                    spacing: 9

                    Rectangle {
                        width: 8; height: 8; radius: 4
                        anchors.verticalCenter: parent.verticalCenter
                        color: root.ollamaStatus === "ok" ? theme.green
                             : root.ollamaStatus === "down" ? theme.red
                             : theme.subtext1
                        Behavior on color { ColorAnimation { duration: 200 } }
                        SequentialAnimation on opacity {
                            loops: Animation.Infinite
                            running: root.ollamaStatus !== "ok"
                            NumberAnimation { to: 0.35; duration: 700; easing.type: Easing.InOutSine }
                            NumberAnimation { to: 1.0;  duration: 700; easing.type: Easing.InOutSine }
                        }
                    }

                    TextField {
                        id: input
                        width: parent.width - 80
                        anchors.verticalCenter: parent.verticalCenter
                        placeholderText: root.ollamaStatus === "down"
                            ? "ollama is offline"
                            : root.thinking
                                ? "thinking..."
                                : "ask glassbot   ·   /search ...   ·   /new"
                        color: theme.text
                        placeholderTextColor: Qt.alpha(theme.text, 0.45)
                        font.pixelSize: 15
                        selectByMouse: true
                        background: Item {}
                        enabled: !root.thinking && root.ollamaStatus !== "down"

                        Keys.onReturnPressed: {
                            let t = input.text;
                            input.text = "";
                            root.send(t);
                        }
                    }

                    Rectangle {
                        width: 36; height: 36; radius: 18
                        anchors.verticalCenter: parent.verticalCenter
                        color: input.text.length > 0 && !root.thinking && root.ollamaStatus === "ok"
                            ? theme.blue
                            : Qt.alpha(theme.text, 0.18)
                        Behavior on color { ColorAnimation { duration: 180 } }

                        Text {
                            anchors.centerIn: parent
                            text: "→"
                            color: theme.base
                            font.pixelSize: 17
                            font.bold: true
                        }

                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            enabled: input.text.length > 0 && !root.thinking
                            onClicked: {
                                let t = input.text;
                                input.text = "";
                                root.send(t);
                            }
                        }
                    }
                }
            }
        }

        // ===============================================================
        // SIDEBAR DRAWER (overlay) — slides in from the left
        // ===============================================================
        // Scrim
        Rectangle {
            id: scrim
            anchors.fill: parent
            color: Qt.alpha("#000000", 0.35)
            radius: 16
            opacity: root.sidebarOpen ? 1.0 : 0.0
            visible: opacity > 0.01
            Behavior on opacity { NumberAnimation { duration: 200 } }
            MouseArea {
                anchors.fill: parent
                enabled: root.sidebarOpen
                onClicked: root.sidebarOpen = false
            }
        }

        Rectangle {
            id: sidebar
            anchors.top: parent.top
            anchors.bottom: parent.bottom
            width: 200
            x: root.sidebarOpen ? 0 : -width - 6
            color: Qt.alpha(theme.mantle, 0.94)
            radius: 16
            border.width: 1
            border.color: Qt.alpha(theme.text, 0.08)

            Behavior on x { NumberAnimation { duration: 280; easing.type: Easing.OutCubic } }

            // soft right-edge shadow
            Rectangle {
                anchors.right: parent.right
                anchors.rightMargin: -8
                anchors.top: parent.top
                anchors.bottom: parent.bottom
                width: 8
                gradient: Gradient {
                    orientation: Gradient.Horizontal
                    GradientStop { position: 0.0; color: Qt.alpha("#000000", 0.18) }
                    GradientStop { position: 1.0; color: "transparent" }
                }
                opacity: root.sidebarOpen ? 1.0 : 0.0
                Behavior on opacity { NumberAnimation { duration: 200 } }
            }

            Text {
                id: sidebarTitle
                anchors.top: parent.top
                anchors.topMargin: 18
                anchors.left: parent.left
                anchors.leftMargin: 16
                text: "Chats"
                color: theme.text
                font.pixelSize: 15
                font.bold: true
                opacity: 0.75
            }

            // New chat button
            Rectangle {
                id: newChatBtn
                anchors.top: sidebarTitle.bottom
                anchors.topMargin: 12
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.leftMargin: 10
                anchors.rightMargin: 10
                height: 40
                radius: 11
                color: newChatHover.containsMouse
                    ? Qt.alpha(theme.blue, 0.22)
                    : Qt.alpha(theme.surface0, 0.7)
                border.width: 1
                border.color: Qt.alpha(theme.text, 0.10)
                Behavior on color { ColorAnimation { duration: 150 } }

                Row {
                    anchors.centerIn: parent
                    spacing: 8
                    Text {
                        text: "+"
                        color: theme.text
                        font.pixelSize: 19
                        font.bold: true
                        anchors.verticalCenter: parent.verticalCenter
                    }
                    Text {
                        text: "New chat"
                        color: theme.text
                        font.pixelSize: 15
                        anchors.verticalCenter: parent.verticalCenter
                    }
                }

                MouseArea {
                    id: newChatHover
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: {
                        root.newChat();
                        root.sidebarOpen = false;
                    }
                }
            }

            ListView {
                id: chatList
                anchors.top: newChatBtn.bottom
                anchors.topMargin: 10
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.bottom: parent.bottom
                anchors.leftMargin: 6
                anchors.rightMargin: 6
                anchors.bottomMargin: 12
                clip: true
                model: root.chats
                spacing: 2

                ScrollBar.vertical: ScrollBar {
                    policy: ScrollBar.AsNeeded
                    width: 4
                    contentItem: Rectangle { color: Qt.alpha(theme.text, 0.22); radius: 2 }
                }

                delegate: Rectangle {
                    id: chatRow
                    width: chatList.width
                    height: 40
                    radius: 9
                    property bool isActive: modelData.id === root.activeId
                    property bool confirmDel: false
                    color: isActive
                        ? Qt.alpha(theme.blue, 0.20)
                        : (rowHover.containsMouse ? Qt.alpha(theme.text, 0.06) : "transparent")
                    Behavior on color { ColorAnimation { duration: 130 } }

                    Text {
                        anchors.left: parent.left
                        anchors.leftMargin: 10
                        anchors.right: delBtn.left
                        anchors.rightMargin: 4
                        anchors.verticalCenter: parent.verticalCenter
                        text: (modelData.title && modelData.title.length > 0)
                            ? modelData.title
                            : "New chat"
                        color: chatRow.isActive ? theme.text : Qt.alpha(theme.text, 0.92)
                        font.pixelSize: 14
                        font.bold: chatRow.isActive
                        elide: Text.ElideRight
                    }

                    Rectangle {
                        id: delBtn
                        anchors.right: parent.right
                        anchors.rightMargin: 6
                        anchors.verticalCenter: parent.verticalCenter
                        width: 24; height: 24
                        radius: 12
                        color: (delHover.containsMouse || chatRow.confirmDel)
                            ? Qt.alpha(theme.red, 0.35)
                            : "transparent"
                        // immer sichtbar (dezent) -> man findet den Button auch ohne Hover
                        opacity: chatRow.confirmDel ? 1.0 : (delHover.containsMouse ? 1.0 : 0.55)
                        Behavior on opacity { NumberAnimation { duration: 120 } }
                        Behavior on color { ColorAnimation { duration: 120 } }

                        ToolTip.visible: delHover.containsMouse
                        ToolTip.text: chatRow.confirmDel ? "click again to delete" : "delete chat"
                        ToolTip.delay: 500

                        Text {
                            anchors.centerIn: parent
                            text: chatRow.confirmDel ? "✕" : "🗑"
                            color: chatRow.confirmDel ? theme.red : Qt.alpha(theme.text, 0.75)
                            font.pixelSize: chatRow.confirmDel ? 15 : 13
                        }

                        Timer {
                            id: confirmTimer
                            interval: 2600
                            onTriggered: chatRow.confirmDel = false
                        }

                        MouseArea {
                            id: delHover
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: {
                                if (!chatRow.confirmDel) {          // 1. Klick: sicher fragen
                                    chatRow.confirmDel = true;
                                    confirmTimer.restart();
                                } else {                            // 2. Klick: löschen
                                    chatRow.confirmDel = false;
                                    root.deleteChat(modelData.id);
                                }
                            }
                        }
                    }

                    MouseArea {
                        id: rowHover
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        propagateComposedEvents: false
                        onClicked: {
                            if (delHover.containsMouse) return;
                            root.openChat(modelData.id);
                            root.sidebarOpen = false;
                        }
                    }
                }

                Text {
                    anchors.centerIn: parent
                    visible: root.chats.length === 0
                    text: "No chats yet"
                    color: Qt.alpha(theme.text, 0.6)
                    font.pixelSize: 14
                    font.italic: true
                }
            }
        }

        // ===============================================================
        // ONBOARDING OVERLAY — first-run wizard, gates the chat UI
        // ===============================================================
        Rectangle {
            id: onboard
            anchors.fill: parent
            radius: 16
            color: theme.base
            visible: !root.setupDone
            opacity: !root.setupDone ? 1.0 : 0.0
            Behavior on opacity { NumberAnimation { duration: 280; easing.type: Easing.OutCubic } }
            z: 200

            // Block clicks from reaching the chat below
            MouseArea { anchors.fill: parent }

            Rectangle {
                anchors.fill: parent
                radius: 16
                gradient: Gradient {
                    GradientStop { position: 0.0; color: Qt.alpha(theme.surface0, 0.7) }
                    GradientStop { position: 1.0; color: "transparent" }
                }
            }

            // ----- Step 0 — Welcome -----
            Item {
                anchors.fill: parent
                anchors.margins: 28
                visible: root.onboardStep === 0

                Item {
                    id: welcomeEyes
                    anchors.horizontalCenter: parent.horizontalCenter
                    anchors.top: parent.top
                    anchors.topMargin: 60
                    width: 160
                    height: 80
                    Eye { x: 25;  y: 0; eyeSize: 56; blinkSeed: 0.4 }
                    Eye { x: 110; y: 0; eyeSize: 56; blinkSeed: 0.9 }
                }

                Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    anchors.top: welcomeEyes.bottom
                    anchors.topMargin: 32
                    text: "Hello, I'm Glassbot"
                    color: theme.text
                    font.pixelSize: 22
                    font.bold: true
                }

                Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    anchors.top: welcomeEyes.bottom
                    anchors.topMargin: 64
                    text: "your personal GlassyOS AI assistant"
                    color: Qt.alpha(theme.text, 0.7)
                    font.pixelSize: 13
                }

                Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    anchors.top: welcomeEyes.bottom
                    anchors.topMargin: 110
                    width: parent.width - 60
                    horizontalAlignment: Text.AlignHCenter
                    text: "Before we start please set me up :)"
                    color: Qt.alpha(theme.text, 0.85)
                    font.pixelSize: 14
                    wrapMode: Text.Wrap
                }

                Rectangle {
                    id: welcomeBtn
                    anchors.horizontalCenter: parent.horizontalCenter
                    anchors.bottom: parent.bottom
                    anchors.bottomMargin: 20
                    width: 200
                    height: 40
                    radius: 12
                    color: welcomeMA.containsMouse
                        ? Qt.alpha(theme.text, 0.18)
                        : Qt.alpha(theme.text, 0.10)
                    border.width: 1
                    border.color: Qt.alpha(theme.text, 0.25)
                    Text {
                        anchors.centerIn: parent
                        text: "Let's go →"
                        color: theme.text
                        font.pixelSize: 13
                        font.bold: true
                    }
                    MouseArea {
                        id: welcomeMA
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.onboardStep = 1
                    }
                }
            }

            // ----- Step 1 — Pick local model -----
            Item {
                anchors.fill: parent
                anchors.margins: 24
                visible: root.onboardStep === 1

                Text {
                    id: step1Title
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.top: parent.top
                    text: "Pick your local model"
                    color: theme.text
                    font.pixelSize: 18
                    font.bold: true
                }

                Text {
                    id: step1Sub
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.top: step1Title.bottom
                    anchors.topMargin: 6
                    text: "Used when offline or for private chats. Picks one to download (~1–5 GB)."
                    color: Qt.alpha(theme.text, 0.65)
                    font.pixelSize: 11
                    wrapMode: Text.Wrap
                }

                ListView {
                    id: modelList
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.top: step1Sub.bottom
                    anchors.topMargin: 18
                    anchors.bottom: step1Progress.top
                    anchors.bottomMargin: 12
                    clip: true
                    spacing: 8
                    model: root.suggestedModels

                    delegate: Rectangle {
                        id: modelCard
                        width: ListView.view.width
                        height: 64
                        radius: 12
                        property bool isInstalled: root.installedModels.indexOf(modelData.name) !== -1
                        color: cardMa.containsMouse
                            ? Qt.alpha(theme.text, 0.10)
                            : Qt.alpha(theme.text, 0.05)
                        border.width: 1
                        border.color: Qt.alpha(theme.text, 0.15)

                        Column {
                            anchors.left: parent.left
                            anchors.leftMargin: 14
                            anchors.right: installBtn.left
                            anchors.rightMargin: 12
                            anchors.verticalCenter: parent.verticalCenter
                            spacing: 3

                            Row {
                                spacing: 8
                                Text {
                                    text: modelData.label
                                    color: theme.text
                                    font.pixelSize: 13
                                    font.bold: true
                                }
                                Text {
                                    text: "(" + modelData.name + ", " + modelData.size_gb.toFixed(1) + " GB)"
                                    color: Qt.alpha(theme.text, 0.5)
                                    font.pixelSize: 10
                                    anchors.verticalCenter: parent.verticalCenter
                                }
                                Rectangle {
                                    visible: modelCard.isInstalled
                                    width: installedTxt.implicitWidth + 10
                                    height: 14
                                    radius: 7
                                    color: Qt.rgba(0.55, 0.95, 0.65, 0.16)
                                    border.width: 1
                                    border.color: Qt.rgba(0.55, 0.95, 0.65, 0.40)
                                    anchors.verticalCenter: parent.verticalCenter
                                    Text {
                                        id: installedTxt
                                        anchors.centerIn: parent
                                        text: "installed"
                                        color: Qt.rgba(0.65, 0.95, 0.70, 1.0)
                                        font.pixelSize: 9
                                        font.bold: true
                                    }
                                }
                            }
                            Text {
                                text: "Recommended when: " + modelData.recommended
                                color: Qt.alpha(theme.text, 0.65)
                                font.pixelSize: 10
                                wrapMode: Text.Wrap
                                width: parent.width
                            }
                        }

                        Rectangle {
                            id: installBtn
                            anchors.right: parent.right
                            anchors.rightMargin: 12
                            anchors.verticalCenter: parent.verticalCenter
                            width: 80
                            height: 28
                            radius: 8
                            color: installMa.containsMouse
                                ? Qt.alpha(theme.text, 0.20)
                                : Qt.alpha(theme.text, 0.10)
                            border.width: 1
                            border.color: Qt.alpha(theme.text, 0.25)
                            enabled: !root.onboardModelInstalling
                            opacity: enabled ? 1.0 : 0.4
                            Text {
                                anchors.centerIn: parent
                                text: modelCard.isInstalled ? "Use" : "Install"
                                color: theme.text
                                font.pixelSize: 11
                                font.bold: true
                            }
                            MouseArea {
                                id: installMa
                                anchors.fill: parent
                                hoverEnabled: true
                                enabled: !root.onboardModelInstalling
                                cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
                                onClicked: root.onboardInstallModel(modelData.name)
                            }
                        }

                        MouseArea {
                            id: cardMa
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            propagateComposedEvents: true
                            onClicked: root.onboardInstallModel(modelData.name)
                            z: -1
                        }
                    }
                }

                Rectangle {
                    id: step1Progress
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.bottom: step1Buttons.top
                    anchors.bottomMargin: 12
                    height: 36
                    radius: 10
                    visible: root.onboardModelInstalling || root.onboardPullStatus !== ""
                    color: Qt.alpha(theme.text, 0.06)
                    border.width: 1
                    border.color: Qt.alpha(theme.text, 0.12)

                    Rectangle {
                        anchors.left: parent.left
                        anchors.top: parent.top
                        anchors.bottom: parent.bottom
                        anchors.margins: 2
                        width: root.onboardPullPercent > 0
                            ? (parent.width - 4) * (root.onboardPullPercent / 100.0)
                            : 0
                        radius: 8
                        color: Qt.alpha("#7ec8ff", 0.25)
                        Behavior on width { NumberAnimation { duration: 200 } }
                    }

                    Text {
                        anchors.centerIn: parent
                        text: root.onboardPullStatus
                            + (root.onboardPullPercent >= 0 ? "  " + root.onboardPullPercent + "%" : "")
                        color: theme.text
                        font.pixelSize: 11
                    }
                }

                Row {
                    id: step1Buttons
                    anchors.right: parent.right
                    anchors.bottom: parent.bottom
                    spacing: 10

                    Rectangle {
                        width: 110; height: 36; radius: 10
                        color: skipMa.containsMouse
                            ? Qt.alpha(theme.text, 0.10)
                            : Qt.alpha(theme.text, 0.04)
                        border.width: 1
                        border.color: Qt.alpha(theme.text, 0.15)
                        Text {
                            anchors.centerIn: parent
                            text: "Skip — cloud only"
                            color: Qt.alpha(theme.text, 0.7)
                            font.pixelSize: 10
                        }
                        MouseArea {
                            id: skipMa
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: root.onboardSkipLocal()
                        }
                    }
                }
            }

            // ----- Step 2 — Provider picker (OpenRouter vs Groq) -----
            Item {
                anchors.fill: parent
                anchors.margins: 24
                visible: root.onboardStep === 2

                Text {
                    id: step2pTitle
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.top: parent.top
                    text: "Pick a cloud provider"
                    color: theme.text
                    font.pixelSize: 17
                    font.bold: true
                    wrapMode: Text.Wrap
                }

                Text {
                    id: step2pSub
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.top: step2pTitle.bottom
                    anchors.topMargin: 8
                    text: "Both have free tiers and need a key. You can switch later."
                    color: Qt.alpha(theme.text, 0.7)
                    font.pixelSize: 12
                    wrapMode: Text.Wrap
                }

                Column {
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.top: step2pSub.bottom
                    anchors.topMargin: 18
                    spacing: 10

                    Repeater {
                        model: root.onboardProviders
                        delegate: Rectangle {
                            id: provCard
                            width: parent.width
                            height: 70
                            radius: 12
                            color: provMa.containsMouse
                                ? Qt.alpha("#7ec8ff", 0.18)
                                : Qt.alpha(theme.text, 0.05)
                            border.width: 1
                            border.color: provMa.containsMouse
                                ? Qt.alpha("#7ec8ff", 0.50)
                                : Qt.alpha(theme.text, 0.15)

                            Column {
                                anchors.left: parent.left
                                anchors.leftMargin: 16
                                anchors.right: parent.right
                                anchors.rightMargin: 16
                                anchors.verticalCenter: parent.verticalCenter
                                spacing: 4

                                Text {
                                    text: modelData.label
                                    color: theme.text
                                    font.pixelSize: 14
                                    font.bold: true
                                }
                                Text {
                                    text: modelData.tagline
                                    color: Qt.alpha(theme.text, 0.65)
                                    font.pixelSize: 11
                                    wrapMode: Text.Wrap
                                    width: parent.width
                                }
                            }
                            MouseArea {
                                id: provMa
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: root.onboardPickProvider(modelData.id)
                            }
                        }
                    }
                }

                Rectangle {
                    width: 110; height: 32; radius: 10
                    anchors.right: parent.right
                    anchors.bottom: parent.bottom
                    color: skipProvMa.containsMouse
                        ? Qt.alpha(theme.text, 0.10)
                        : Qt.alpha(theme.text, 0.04)
                    border.width: 1
                    border.color: Qt.alpha(theme.text, 0.15)
                    Text {
                        anchors.centerIn: parent
                        text: "Skip for now"
                        color: Qt.alpha(theme.text, 0.7)
                        font.pixelSize: 11
                    }
                    MouseArea {
                        id: skipProvMa
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.onboardSkipCloud()
                    }
                }
            }

            // ----- Step 3 — Cloud key entry (provider-aware) -----
            Item {
                anchors.fill: parent
                anchors.margins: 24
                visible: root.onboardStep === 3

                property var prov: {
                    for (let i = 0; i < root.onboardProviders.length; i++) {
                        if (root.onboardProviders[i].id === root.onboardSelectedProvider)
                            return root.onboardProviders[i];
                    }
                    return { label: "OpenRouter", key_page: "https://openrouter.ai/keys" };
                }

                Text {
                    id: step2Title
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.top: parent.top
                    text: "Set up " + parent.prov.label
                    color: theme.text
                    font.pixelSize: 17
                    font.bold: true
                    wrapMode: Text.Wrap
                }

                Text {
                    id: step2Sub
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.top: step2Title.bottom
                    anchors.topMargin: 8
                    text: "Free tier — each user needs their own key. Takes ~1 minute."
                    color: Qt.alpha(theme.text, 0.7)
                    font.pixelSize: 12
                    wrapMode: Text.Wrap
                }

                Column {
                    id: step2Steps
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.top: step2Sub.bottom
                    anchors.topMargin: 18
                    spacing: 8

                    Repeater {
                        model: [
                            "1. Click the button below — it opens the key page",
                            "2. Sign in (Google, GitHub, or email — takes 30 s)",
                            "3. Click  \"Create Key\"  → give it a name → copy the key",
                            "4. Paste the key here and hit  \"Test & Save\""
                        ]
                        Text {
                            text: modelData
                            color: Qt.alpha(theme.text, 0.85)
                            font.pixelSize: 12
                            wrapMode: Text.Wrap
                            width: parent.width
                        }
                    }
                }

                Rectangle {
                    id: openBtn
                    anchors.left: parent.left
                    anchors.top: step2Steps.bottom
                    anchors.topMargin: 14
                    width: openBtnText.implicitWidth + 28
                    height: 34
                    radius: 10
                    color: openMa.containsMouse
                        ? Qt.alpha("#7ec8ff", 0.28)
                        : Qt.alpha("#7ec8ff", 0.16)
                    border.width: 1
                    border.color: Qt.alpha("#7ec8ff", 0.5)
                    Text {
                        id: openBtnText
                        anchors.centerIn: parent
                        text: "Open " + parent.parent.prov.label + " →"
                        color: theme.text
                        font.pixelSize: 12
                        font.bold: true
                    }
                    MouseArea {
                        id: openMa
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.onboardOpenKeyPage()
                    }
                }

                Rectangle {
                    id: keyFieldBg
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.top: openBtn.bottom
                    anchors.topMargin: 16
                    height: 40
                    radius: 10
                    color: Qt.alpha(theme.text, 0.06)
                    border.width: 1
                    border.color: keyField.activeFocus
                        ? Qt.alpha("#7ec8ff", 0.6)
                        : Qt.alpha(theme.text, 0.15)

                    TextField {
                        id: keyField
                        anchors.fill: parent
                        anchors.leftMargin: 12
                        anchors.rightMargin: 12
                        background: Rectangle { color: "transparent" }
                        placeholderText: root.onboardSelectedProvider === "groq"
                                          ? "gsk_…"
                                          : "sk-or-v1-…"
                        color: theme.text
                        placeholderTextColor: Qt.alpha(theme.text, 0.35)
                        font.pixelSize: 12
                        echoMode: TextInput.Password
                        verticalAlignment: TextInput.AlignVCenter
                        onAccepted: root.onboardSaveKey(text)
                    }
                }

                Text {
                    id: keyMsg
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.top: keyFieldBg.bottom
                    anchors.topMargin: 8
                    text: root.onboardKeyMessage
                    color: root.onboardKeyValid
                        ? Qt.rgba(0.55, 0.95, 0.65, 1.0)
                        : (root.onboardKeyMessage !== "" && !root.onboardKeyChecking)
                            ? Qt.rgba(0.95, 0.6, 0.55, 1.0)
                            : Qt.alpha(theme.text, 0.6)
                    font.pixelSize: 11
                    wrapMode: Text.Wrap
                    visible: root.onboardKeyMessage !== ""
                }

                Row {
                    anchors.right: parent.right
                    anchors.bottom: parent.bottom
                    spacing: 10

                    Rectangle {
                        width: 110; height: 36; radius: 10
                        color: skip2Ma.containsMouse
                            ? Qt.alpha(theme.text, 0.10)
                            : Qt.alpha(theme.text, 0.04)
                        border.width: 1
                        border.color: Qt.alpha(theme.text, 0.15)
                        Text {
                            anchors.centerIn: parent
                            text: "Skip for now"
                            color: Qt.alpha(theme.text, 0.7)
                            font.pixelSize: 11
                        }
                        MouseArea {
                            id: skip2Ma
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: root.onboardSkipCloud()
                        }
                    }

                    Rectangle {
                        width: 130; height: 36; radius: 10
                        property bool ready: keyField.text.trim() !== "" && !root.onboardKeyChecking
                        color: !ready
                            ? Qt.alpha(theme.text, 0.05)
                            : (saveMa.containsMouse
                                ? Qt.alpha("#7ec8ff", 0.32)
                                : Qt.alpha("#7ec8ff", 0.20))
                        border.width: 1
                        border.color: ready
                            ? Qt.alpha("#7ec8ff", 0.55)
                            : Qt.alpha(theme.text, 0.15)
                        opacity: ready ? 1.0 : 0.5
                        Text {
                            anchors.centerIn: parent
                            text: root.onboardKeyChecking
                                ? "Checking…"
                                : (root.onboardKeyValid ? "Saved ✓ Continue" : "Test & Save")
                            color: theme.text
                            font.pixelSize: 12
                            font.bold: true
                        }
                        MouseArea {
                            id: saveMa
                            anchors.fill: parent
                            hoverEnabled: true
                            enabled: parent.ready || root.onboardKeyValid
                            cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
                            onClicked: {
                                if (root.onboardKeyValid) {
                                    root.onboardFinish();
                                } else {
                                    root.onboardSaveKey(keyField.text);
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // ===== Eye component — solid white dot with blink =====
    component Eye: Item {
        id: eye
        property real eyeSize: 60
        property real blinkSeed: 0.0
        property real openness: 1.0

        width: eyeSize
        height: eyeSize

        Timer {
            interval: 3200 + Math.floor((Math.random() + blinkSeed) * 3000)
            running: true
            repeat: true
            onTriggered: {
                interval = 3200 + Math.floor(Math.random() * 3000);
                blinkAnim.start();
            }
        }
        SequentialAnimation {
            id: blinkAnim
            NumberAnimation { target: eye; property: "openness"; to: 0.06; duration: 70;  easing.type: Easing.InQuad }
            PauseAnimation  { duration: 40 }
            NumberAnimation { target: eye; property: "openness"; to: 1.0;  duration: 120; easing.type: Easing.OutQuad }
        }

        Rectangle {
            anchors.centerIn: parent
            width: eye.eyeSize
            height: eye.eyeSize * eye.openness
            radius: width / 2
            color: theme.text
            antialiasing: true
            Behavior on height { NumberAnimation { duration: 60; easing.type: Easing.InOutSine } }
        }
    }

    Component.onCompleted: {
        input.forceActiveFocus();
    }
}
