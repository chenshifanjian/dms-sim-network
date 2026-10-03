import QtQuick
import QtQuick.Layouts
import qs.Common
import qs.Modules.Plugins
import qs.Widgets

PluginSettings {
    id: root
    pluginId: "simNetwork"

    readonly property var backend: pluginService && pluginService.pluginDaemonInstances && pluginService.pluginDaemonInstances[pluginId]
        ? pluginService.pluginDaemonInstances[pluginId] : null
    property string selectedModemId: ""
    property string editingUuid: ""
    property string deleteConfirmUuid: ""
    property bool editorOpen: false
    property bool draftAutoConfig: false
    property bool draftAllowRoaming: true
    property bool draftAutoconnect: true
    property bool draftPasswordChanged: false
    property string draftMetered: "unknown"

    readonly property var selectedModem: {
        if (!backend || !backend.modems.length) return null;
        const match = backend.modems.find(m => m.stableId === selectedModemId);
        return match || backend.modems[0];
    }

    function ensureSelection() {
        if (!backend || !backend.modems.length) return;
        if (!backend.modems.some(m => m.stableId === selectedModemId)) selectModem(backend.modems[0].stableId);
    }

    function selectModem(stableId) {
        selectedModemId = stableId;
        saveValue("selectedModemId", stableId);
    }

    function modemOptions() { return backend ? backend.modems.map(m => backend.modemLabel(m)) : []; }
    function selectByLabel(label) {
        if (!backend) return;
        const modem = backend.modems.find(m => backend.modemLabel(m) === label);
        if (modem) selectModem(modem.stableId);
    }

    function profileClicked(profile) {
        if (!backend || !selectedModem || backend.busy) return;
        if (backend.isActive(profile.uuid, selectedModem.interfaceName)) backend.disconnect(selectedModem.interfaceName, profile.uuid);
        else backend.activate(profile.uuid, selectedModem.interfaceName);
    }

    function beginAdd() {
        editingUuid = "";
        nameInput.text = ""; apnInput.text = ""; usernameInput.text = ""; passwordInput.text = "";
        priorityInput.text = "0"; networkInput.text = ""; mtuInput.text = "";
        draftAutoConfig = false; draftAllowRoaming = true; draftAutoconnect = true;
        draftPasswordChanged = false; draftMetered = "unknown"; editorOpen = true;
    }

    function beginEdit(profile) {
        editingUuid = profile.uuid;
        nameInput.text = profile.name; apnInput.text = profile.apn; usernameInput.text = profile.username;
        passwordInput.text = ""; priorityInput.text = String(profile.autoconnectPriority || 0);
        networkInput.text = profile.networkId || ""; mtuInput.text = profile.mtu || "";
        draftAutoConfig = profile.autoConfig; draftAllowRoaming = profile.allowRoaming;
        draftAutoconnect = profile.autoconnect; draftPasswordChanged = false;
        draftMetered = profile.metered || "unknown"; editorOpen = true;
    }

    function saveDraft() {
        if (!backend) return;
        backend.saveProfile({
            uuid: editingUuid, name: nameInput.text, autoConfig: draftAutoConfig,
            apn: apnInput.text, username: usernameInput.text, password: passwordInput.text,
            passwordChanged: draftPasswordChanged, allowRoaming: draftAllowRoaming,
            autoconnect: draftAutoconnect, autoconnectPriority: Number(priorityInput.text || 0),
            metered: draftMetered, networkId: networkInput.text, mtu: mtuInput.text
        });
    }

    Component.onCompleted: {
        selectedModemId = loadValue("selectedModemId", "");
        if (backend) backend.acquireUi();   // 设置页也算"可见"
    }

    Component.onDestruction: if (backend) backend.releaseUi()

    Connections {
        target: backend
        function onRefreshed() { root.ensureSelection(); }
        function onOperationCompleted(success, operation, uuid) {
            if (success && operation === "save") root.editorOpen = false;
            if (success && operation === "delete") root.deleteConfirmUuid = "";
        }
    }

    StyledText { width: parent.width; text: "SIM Network"; color: Theme.surfaceText; font.pixelSize: Theme.fontSizeLarge; font.weight: Font.Bold }

    RowLayout {
        width: parent.width
        StyledText {
            Layout.fillWidth: true
            text: backend.refreshing ? "正在刷新 NetworkManager 与模块状态…" : (backend.modems.length ? "选择一个档案来连接当前模块。" : "未检测到模块，仍可管理档案。")
            color: Theme.surfaceVariantText; font.pixelSize: Theme.fontSizeSmall; wrapMode: Text.WordWrap
        }
        DankActionButton { iconName: "refresh"; enabled: !backend.refreshing && !backend.busy; onClicked: backend.refresh() }
    }

    DankDropdown {
        visible: backend.modems.length > 1
        width: parent.width
        text: "模块设备"
        options: root.modemOptions()
        currentValue: root.selectedModem ? backend.modemLabel(root.selectedModem) : ""
        onValueChanged: value => root.selectByLabel(value)
    }

    StyledText {
        visible: !!root.selectedModem
        width: parent.width
        text: root.selectedModem ? (backend.modemLabel(root.selectedModem) + " · " + (root.selectedModem.interfaceName || "无 NetworkManager 接口")) : ""
        color: Theme.surfaceVariantText; font.pixelSize: Theme.fontSizeSmall
    }

    StyledText { visible: backend.errorMessage.length > 0; width: parent.width; text: backend.errorMessage; color: Theme.error; wrapMode: Text.WordWrap }
    StyledText { visible: backend.statusMessage.length > 0 && !backend.errorMessage; width: parent.width; text: backend.statusMessage; color: Theme.primary; wrapMode: Text.WordWrap }

    RowLayout {
        width: parent.width
        StyledText { Layout.fillWidth: true; text: "档案"; color: Theme.surfaceText; font.pixelSize: Theme.fontSizeMedium; font.weight: Font.Bold }
        DankButton { text: "添加档案"; iconName: "add"; enabled: !backend.busy; onClicked: root.beginAdd() }
    }

    Repeater {
        model: backend.profiles
        Rectangle {
            required property var modelData
            readonly property bool connected: root.selectedModem && backend.isActive(modelData.uuid, root.selectedModem.interfaceName)
            width: parent.width
            implicitHeight: settingsBody.implicitHeight + Theme.spacingS * 2
            radius: Theme.cornerRadius
            color: cardMouse.containsMouse ? Theme.surfaceContainerHighest : Theme.surfaceContainer
            border.width: connected ? 2 : 1
            border.color: connected ? Theme.primary : Theme.outlineStrong

            MouseArea { id: cardMouse; anchors.fill: parent; hoverEnabled: true; enabled: !!root.selectedModem && !backend.busy; cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor; onClicked: root.profileClicked(modelData) }

            RowLayout {
                id: settingsBody
                anchors.left: parent.left; anchors.right: parent.right; anchors.top: parent.top
                anchors.margins: Theme.spacingS; spacing: Theme.spacingS
                Column {
                    Layout.fillWidth: true
                    spacing: 2
                    StyledText { width: parent.width; text: modelData.name; color: Theme.surfaceText; font.weight: Font.Medium; wrapMode: Text.Wrap }
                    StyledText { width: parent.width; text: (modelData.autoConfig ? "Automatic APN" : (modelData.apn || "No APN")) + (modelData.autoconnect ? " · 自动连接" : ""); color: Theme.surfaceVariantText; font.pixelSize: Theme.fontSizeSmall; wrapMode: Text.Wrap }
                }
                StyledText {
                    text: backend.pendingUuid === modelData.uuid ? (backend.pendingAction === "disconnect" ? "断开中…" : "处理中…") : (parent.parent.connected ? "已连接" : "")
                    color: Theme.primary; font.pixelSize: Theme.fontSizeSmall
                }
                DankActionButton { iconName: "edit"; enabled: !backend.busy; Layout.alignment: Qt.AlignTop; onClicked: root.beginEdit(modelData) }
                DankActionButton { iconName: "delete"; iconColor: Theme.error; enabled: !backend.busy; Layout.alignment: Qt.AlignTop; onClicked: root.deleteConfirmUuid = modelData.uuid }
            }
        }
    }

    Rectangle {
        visible: root.deleteConfirmUuid.length > 0
        width: parent.width
        height: confirmRow.implicitHeight + Theme.spacingM * 2
        radius: Theme.cornerRadius
        color: Theme.surfaceContainerHigh
        RowLayout {
            id: confirmRow; anchors.fill: parent; anchors.margins: Theme.spacingM
            StyledText { Layout.fillWidth: true; text: "确定删除这个 NetworkManager 档案？正在使用的连接可能中断。"; color: Theme.surfaceText; wrapMode: Text.WordWrap }
            DankButton { text: "取消"; onClicked: root.deleteConfirmUuid = "" }
            DankButton { text: "删除"; onClicked: backend.deleteProfile(root.deleteConfirmUuid) }
        }
    }

    Column {
        visible: root.editorOpen
        width: parent.width
        spacing: Theme.spacingS

        StyledText { text: root.editingUuid ? "编辑档案" : "Add Profile"; color: Theme.surfaceText; font.pixelSize: Theme.fontSizeMedium; font.weight: Font.Bold }

        GridLayout {
            width: parent.width
            columns: width >= 620 ? 2 : 1
            columnSpacing: Theme.spacingM; rowSpacing: Theme.spacingS

            Column { Layout.fillWidth: true; StyledText { text: "档案名称 *"; color: Theme.surfaceText } DankTextField { id: nameInput; width: parent.width; placeholderText: "中国移动" } }
            Column { Layout.fillWidth: true; StyledText { text: "APN *"; color: Theme.surfaceText } DankTextField { id: apnInput; width: parent.width; enabled: !root.draftAutoConfig; placeholderText: "cmnet" } }
            DankToggle { Layout.fillWidth: true; text: "自动 APN 配置"; checked: root.draftAutoConfig; onToggled: value => root.draftAutoConfig = value }
            DankToggle { Layout.fillWidth: true; text: "允许漫游"; checked: root.draftAllowRoaming; onToggled: value => root.draftAllowRoaming = value }
            Column { Layout.fillWidth: true; StyledText { text: "用户名"; color: Theme.surfaceText } DankTextField { id: usernameInput; width: parent.width; enabled: !root.draftAutoConfig; placeholderText: "可选" } }
            Column {
                Layout.fillWidth: true
                StyledText { text: root.editingUuid ? "密码（留空表示不修改）" : "密码"; color: Theme.surfaceText }
                DankTextField { id: passwordInput; width: parent.width; enabled: !root.draftAutoConfig; echoMode: TextInput.Password; placeholderText: "可选"; onTextChanged: root.draftPasswordChanged = true }
            }
            DankToggle { Layout.fillWidth: true; text: "自动连接"; checked: root.draftAutoconnect; onToggled: value => root.draftAutoconnect = value }
            Column { Layout.fillWidth: true; StyledText { text: "自动连接优先级"; color: Theme.surfaceText } DankTextField { id: priorityInput; width: parent.width; placeholderText: "0"; validator: IntValidator {} } }
            DankDropdown { Layout.fillWidth: true; text: "计费网络"; options: ["unknown", "yes", "no"]; currentValue: root.draftMetered; onValueChanged: value => root.draftMetered = value }
            Item { Layout.fillWidth: true; implicitHeight: 1 }
            Column { Layout.fillWidth: true; StyledText { text: "网络 ID（MCC/MNC）"; color: Theme.surfaceText } DankTextField { id: networkInput; width: parent.width; placeholderText: "可选"; validator: RegularExpressionValidator { regularExpression: /\d{0,6}/ } } }
            Column { Layout.fillWidth: true; StyledText { text: "MTU"; color: Theme.surfaceText } DankTextField { id: mtuInput; width: parent.width; placeholderText: "自动"; validator: IntValidator { bottom: 1 } } }
        }

        RowLayout {
            width: parent.width
            DankButton { visible: !!root.editingUuid; text: "清除密码"; onClicked: { passwordInput.text = ""; root.draftPasswordChanged = true; } }
            Item { Layout.fillWidth: true }
            DankButton { text: "取消"; onClicked: root.editorOpen = false }
            DankButton { text: backend.busy ? "保存中…" : "保存"; iconName: "save"; enabled: !backend.busy; onClicked: root.saveDraft() }
        }
    }
}
