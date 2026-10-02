import QtQuick
import QtQuick.Layouts
import Quickshell.Wayland
import qs.Common
import qs.Modals.Common
import qs.Modules.Plugins
import qs.Services
import qs.Widgets
import "./components"

PluginComponent {
    id: root

    // DetailHost creates a second widget instance without injecting pluginId or
    // pluginService. Resolve the daemon through the DMS singleton so both the
    // collapsed tile and expanded detail bind to the same persistent Store.
    readonly property var backend: PluginService.pluginDaemonInstances["simNetwork"] || null
    property string selectedModemId: pluginData.selectedModemId || ""
    property string newProfileName: ""
    property string newProfileApn: ""
    property string newProfileUsername: ""
    property string newProfilePassword: ""
    property bool newProfileAutoConfig: false
    property bool newProfileAllowRoaming: true
    property bool newProfileAutoconnect: true
    property bool controlCenterFocusReleased: false
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
        if (pluginService) pluginService.savePluginData(pluginId, "selectedModemId", stableId);
    }

    function modemOptions() { return backend ? backend.modems.map(m => backend.modemLabel(m)) : []; }
    function selectByLabel(label) {
        if (!backend) return;
        const modem = backend.modems.find(m => backend.modemLabel(m) === label);
        if (modem) selectModem(modem.stableId);
    }

    function profileClicked(profile) {
        if (!backend || !selectedModem || backend.busy) return;
        if (backend.isActive(profile.uuid, selectedModem.interfaceName))
            backend.disconnect(selectedModem.interfaceName, profile.uuid);
        else
            backend.activate(profile.uuid, selectedModem.interfaceName);
    }

    function openAddDialog() {
        newProfileName = "";
        newProfileApn = "";
        newProfileUsername = "";
        newProfilePassword = "";
        newProfileAutoConfig = false;
        newProfileAllowRoaming = true;
        newProfileAutoconnect = true;
        if (backend) backend.errorMessage = "";
        releaseControlCenterFocus();
        addProfileModal.open();
    }

    function closeAddDialog() {
        addProfileModal.close();
    }

    function releaseControlCenterFocus() {
        const popout = PopoutService.controlCenterPopout;
        if (!popout || controlCenterFocusReleased) return;
        popout.customKeyboardFocus = WlrKeyboardFocus.None;
        controlCenterFocusReleased = true;
    }

    function restoreControlCenterFocus() {
        const popout = PopoutService.controlCenterPopout;
        if (!popout || !controlCenterFocusReleased) return;
        popout.customKeyboardFocus = Qt.binding(function () {
            return popout.anyModalOpen ? WlrKeyboardFocus.None : null;
        });
        controlCenterFocusReleased = false;
    }

    function saveNewProfile() {
        if (!backend || backend.busy) return;
        backend.saveProfile({
            name: newProfileName,
            apn: newProfileApn,
            autoConfig: newProfileAutoConfig,
            username: newProfileAutoConfig ? "" : newProfileUsername,
            password: newProfileAutoConfig ? "" : newProfilePassword,
            allowRoaming: newProfileAllowRoaming,
            autoconnect: newProfileAutoconnect,
            autoconnectPriority: 0,
            metered: "unknown",
            networkId: "",
            mtu: "",
            passwordChanged: !newProfileAutoConfig && newProfilePassword.length > 0
        });
    }

    // ── Control Center tile ───────────────────────────────────────────────
    ccWidgetIcon: backend && backend.modems.length > 0 && backend.wwanEnabled ? "signal_cellular_alt" : "signal_cellular_off"
    ccWidgetPrimaryText: "SIM Network"
    ccWidgetSecondaryText: {
        if (!backend || (backend.refreshing && !selectedModem)) return "扫描中…";
        if (!selectedModem) return "未找到模块";
        const connected = backend.activeUuidFor(selectedModem.interfaceName);
        if (connected) return (selectedModem.operatorName || "Connected") + " · " + selectedModem.signal + "%";
        return selectedModem.operatorName || "Disconnected";
    }
    ccWidgetIsActive: backend && backend.modems.length > 0 ? backend.wwanEnabled : false
    onCcWidgetToggled: {
        if (backend && backend.modems.length > 0)
            backend.setRadio(!backend.wwanEnabled);
    }

    Connections {
        target: backend
        function onRefreshed() { root.ensureSelection(); }
        function onOperationCompleted(success, operation, uuid) {
            if (success && operation === "save") root.closeAddDialog();
        }
    }

    Component.onDestruction: restoreControlCenterFocus()

    // ── DankBar status bar pill ───────────────────────────────────────────
    horizontalBarPill: Component {
        Row {
            spacing: Theme.spacingS

            DankIcon {
                name: backend && backend.modems.length > 0 && backend.wwanEnabled
                      ? "signal_cellular_alt" : "signal_cellular_off"
                size: Theme.iconSize - 6
                color: backend && backend.wwanEnabled ? Theme.primary : Theme.error
                anchors.verticalCenter: parent.verticalCenter
            }

            StyledText {
                visible: backend && backend.modems.length > 0
                text: backend && backend.modems.length > 0 ? (backend.modems[0].signal + "%") : ""
                color: Theme.surfaceText
                font.pixelSize: Theme.fontSizeSmall
                anchors.verticalCenter: parent.verticalCenter
            }

            StyledText {
                visible: backend && backend.dataUsageAvailable && backend.rxRate > 1024
                text: {
                    if (!backend) return "";
                    const r = backend.rxRate;
                    return "↓" + (r < 1048576 ? (r / 1024).toFixed(1) + "K" : (r / 1048576).toFixed(1) + "M");
                }
                color: Theme.primary
                font.pixelSize: Theme.fontSizeSmall
                anchors.verticalCenter: parent.verticalCenter
            }
        }
    }

    // ── DankBar popout: full tabbed panel ─────────────────────────────────
    popoutContent: Component {
        PopoutComponent {
            id: barPopout
            headerText: "SIM Network"
            showCloseButton: true

            // The panel is taller than the popout, so it needs its own scroll.
            // NOTE: PopoutComponent has no popoutHeight — that lives on the
            // plugin root, and reading it off the component yields undefined
            // (NaN height => the popout renders nothing).
            Flickable {
                width: parent.width
                height: Math.max(200, (root.popoutHeight || 640)
                                 - barPopout.headerHeight - barPopout.detailsHeight)
                contentHeight: Math.max(height, popColumn.implicitHeight)
                clip: true
                boundsBehavior: Flickable.StopAtBounds

                ColumnLayout {
                    id: popColumn
                    width: parent.width
                    spacing: Theme.spacingS

                    ModemTabs {
                        Layout.fillWidth: true
                        backend: root.backend
                        selectedModem: root.selectedModem
                        modemLabels: root.modemOptions()
                        requestAddProfile: root.openAddDialog
                        requestSelectModem: root.selectByLabel
                        requestProfileClick: root.profileClicked
                    }

                }
            }
        }
    }

    popoutWidth: 420
    popoutHeight: 640

    // Give the Control Center detail room for the full tabbed panel.
    ccDetailHeight: 620

    // ── Control Center detail: same tabbed panel ──────────────────────────
    ccDetailContent: Component {
        Rectangle {
            // Compact when the panel is short, capped at ccDetailHeight so a
            // long inbox scrolls instead of overflowing the detail area.
            implicitHeight: Math.min(root.ccDetailHeight,
                                     ccScroll.contentHeight + Theme.spacingM * 2)
            radius: Theme.cornerRadius
            color: Theme.surfaceContainerHigh

            Flickable {
                id: ccScroll
                anchors.fill: parent
                anchors.margins: Theme.spacingM
                contentHeight: ccTabs.implicitHeight
                clip: true
                boundsBehavior: Flickable.StopAtBounds

                ModemTabs {
                    id: ccTabs
                    width: parent.width
                    backend: root.backend
                    selectedModem: root.selectedModem
                    modemLabels: root.modemOptions()
                    requestAddProfile: root.openAddDialog
                    requestSelectModem: root.selectByLabel
                    requestProfileClick: root.profileClicked
                }
            }
        }
    }

    // ── Add-profile dialog ────────────────────────────────────────────────
    DankModal {
        id: addProfileModal

        layerNamespace: "dms:sim-network-add-profile"
        keepPopoutsOpen: true
        allowStacking: true
        modalWidth: 420
        modalHeight: contentLoader.item ? contentLoader.item.implicitHeight + Theme.spacingL * 2 : 520
        enableShadow: true
        onBackgroundClicked: root.closeAddDialog()
        onDialogClosed: root.restoreControlCenterFocus()
        onOpened: Qt.callLater(function () {
            if (contentLoader.item && contentLoader.item.nameInputRef)
                contentLoader.item.nameInputRef.forceActiveFocus();
        })

        content: Component {
            FocusScope {
                anchors.fill: parent
                implicitHeight: addColumn.implicitHeight
                focus: true

                property alias nameInputRef: profileNameInput

                Keys.onPressed: event => {
                    if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                        root.saveNewProfile();
                        event.accepted = true;
                    }
                }

                Column {
                    id: addColumn
                    anchors.fill: parent
                    anchors.margins: Theme.spacingL
                    spacing: Theme.spacingM

                    RowLayout {
                        width: parent.width
                        StyledText {
                            Layout.fillWidth: true
                            text: "添加 SIM 档案"
                            color: Theme.surfaceText
                            font.pixelSize: Theme.fontSizeLarge
                            font.weight: Font.Medium
                        }
                        DankActionButton {
                            iconName: "close"
                            onClicked: root.closeAddDialog()
                        }
                    }

                    Column {
                        width: parent.width
                        spacing: Theme.spacingXS
                        StyledText { text: "档案名称"; color: Theme.surfaceText }
                        DankTextField {
                            id: profileNameInput
                            width: parent.width
                            placeholderText: "中国移动"
                            text: root.newProfileName
                            onTextChanged: root.newProfileName = text
                        }
                    }

                    Column {
                        width: parent.width
                        spacing: Theme.spacingXS
                        StyledText { text: "APN"; color: Theme.surfaceText }
                        DankTextField {
                            width: parent.width
                            placeholderText: "cmnet"
                            enabled: !root.newProfileAutoConfig
                            text: root.newProfileApn
                            onTextChanged: root.newProfileApn = text
                        }
                    }

                    DankToggle {
                        width: parent.width
                        text: "自动 APN 配置"
                        checked: root.newProfileAutoConfig
                        onToggled: value => root.newProfileAutoConfig = value
                    }

                    RowLayout {
                        width: parent.width
                        spacing: Theme.spacingM

                        Column {
                            Layout.fillWidth: true
                            spacing: Theme.spacingXS
                            StyledText { text: "用户名"; color: Theme.surfaceText }
                            DankTextField {
                                width: parent.width
                                placeholderText: "可选"
                                enabled: !root.newProfileAutoConfig
                                text: root.newProfileUsername
                                onTextChanged: root.newProfileUsername = text
                            }
                        }

                        Column {
                            Layout.fillWidth: true
                            spacing: Theme.spacingXS
                            StyledText { text: "密码"; color: Theme.surfaceText }
                            DankTextField {
                                width: parent.width
                                placeholderText: "可选"
                                enabled: !root.newProfileAutoConfig
                                echoMode: TextInput.Password
                                text: root.newProfilePassword
                                onTextChanged: root.newProfilePassword = text
                            }
                        }
                    }

                    RowLayout {
                        width: parent.width
                        spacing: Theme.spacingM
                        DankToggle {
                            Layout.fillWidth: true
                            text: "允许漫游"
                            checked: root.newProfileAllowRoaming
                            onToggled: value => root.newProfileAllowRoaming = value
                        }
                        DankToggle {
                            Layout.fillWidth: true
                            text: "自动连接"
                            checked: root.newProfileAutoconnect
                            onToggled: value => root.newProfileAutoconnect = value
                        }
                    }

                    StyledText {
                        visible: backend && backend.errorMessage.length > 0
                        width: parent.width
                        text: backend ? backend.errorMessage : ""
                        color: Theme.error
                        wrapMode: Text.WordWrap
                    }

                    RowLayout {
                        width: parent.width
                        Item { Layout.fillWidth: true }
                        DankButton { text: "取消"; onClicked: root.closeAddDialog() }
                        DankButton {
                            text: backend && backend.busy ? "保存中…" : "保存"
                            iconName: "save"
                            enabled: backend && !backend.busy
                            onClicked: root.saveNewProfile()
                        }
                    }
                }
            }
        }
    }

}
