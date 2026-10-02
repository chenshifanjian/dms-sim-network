import QtQuick
import QtQuick.Layouts
import qs.Common
import qs.Widgets

// Shared tabbed panel for the SIM Network plugin.
// Instantiated by both the Control Center detail view and the DankBar popout,
// so the two entry points stay in sync instead of duplicating the UI.
ColumnLayout {
    id: tabs

    // Key of the SMS row whose text was just copied (drives the ✓ feedback).
    property string copiedKey: ""

    // Inline editor for the SIM's own number (the modem reports it as empty).
    property bool editingOwnNumber: false

    // ── Conversations ──────────────────────────────────────────────────
    // Grouped by phone number: one row per contact, newest thread first,
    // each row expanding into its own messages (newest first) with per-thread
    // paging. The global pager walks the conversation list.
    property string smsSearch: ""
    property int smsPage: 1
    property int smsPageSize: 20
    readonly property var smsPageSizeOptions: [10, 20, 50, 100]
    property var smsOpenThreads: ({})     // { digits: true }
    property var smsThreadPages: ({})     // { digits: visibleCount }
    readonly property int smsThreadPageSize: 10

    function smsThreadKeyOf(m) {
        const d = String(m.number || "").replace(/\D/g, "");
        return d.length ? d : "unknown";
    }

    readonly property var smsThreads: {
        // 依赖两个 revision，任一变化都重算
        const rev = (tabs.backend ? tabs.backend.smsRevision : 0)
                  + (tabs.backend ? tabs.backend.mmsRevision : 0);
        const all = [];
        const hist = (tabs.backend && tabs.backend.smsHistory) ? tabs.backend.smsHistory : [];
        for (let i = 0; i < hist.length; i++) all.push(hist[i]);
        // 彩信（来自 mms.json）与短信同一份列表，按号码归入同一会话
        const mms = (tabs.backend && tabs.backend.mmsMessages) ? tabs.backend.mmsMessages : [];
        for (let i = 0; i < mms.length; i++) {
            const mm = mms[i];
            // 点过删除的彩信留了墓碑 → 不再显示（否则删除按钮对它没反应）
            if (tabs.backend && tabs.backend.smsDeletedKeys
                && tabs.backend.smsDeletedKeys["mms:" + mm.id]) continue;
            all.push({
                key: "mms:" + mm.id,
                number: mm.number || mm.from || "",
                text: mm.text || "",
                timestamp: mm.date || "",
                isSubmit: false,
                kind: "mms",
                attachments: mm.attachments || [],
                mmsBytes: mm.bytes || 0,
                simLabel: tabs.backend ? tabs.backend.simLabel() : "",
                simIccid: ""
            });
        }
        const map = {};
        const order = [];
        for (let i = 0; i < all.length; i++) {
            const m = all[i];
            const k = tabs.smsThreadKeyOf(m);
            let th = map[k];
            if (!th) {
                th = { digits: k, number: String(m.number || ""), items: [], count: 0, unread: 0, latest: m, label: "" };
                map[k] = th;
                order.push(k);
            }
            th.items.push(m);
        }
        const q = String(tabs.smsSearch || "").trim().toLowerCase();
        const out = [];
        for (let i = 0; i < order.length; i++) {
            const th = map[order[i]];
            th.items.sort((a, b) => String(b.timestamp || "").localeCompare(String(a.timestamp || "")));
            th.latest = th.items[0];
            th.count = th.items.length;
            th.label = th.number || "未知号码";
            for (let j = 0; j < th.items.length; j++) {
                const it = th.items[j];
                it.preview = (it.kind === "mms")
                    ? (it.text || (it.attachments && it.attachments.length ? "[图片彩信]" : "[彩信]"))
                    : (it.text || "");
            }
            let unread = 0;
            for (let j = 0; j < th.items.length; j++) {
                const it = th.items[j];
                if (it.isSubmit) continue;
                if (!tabs.backend || !tabs.backend.smsReadKeys[tabs.backend.historyKey(it.number, it.timestamp)]) unread++;
            }
            th.unread = unread;
            if (q.length) {
                let hit = (String(th.number) + " " + String(th.label)).toLowerCase().indexOf(q) !== -1;
                if (!hit) {
                    for (let j = 0; j < th.items.length; j++) {
                        const s2 = (String(th.items[j].text || "") + " " + String(th.items[j].timestamp || "")
                                    + " " + String(th.items[j].simLabel || "")).toLowerCase();
                        if (s2.indexOf(q) !== -1) { hit = true; break; }
                    }
                }
                if (!hit) continue;
            }
            out.push(th);
        }
        out.sort((a, b) => String(b.latest.timestamp || "").localeCompare(String(a.latest.timestamp || "")));
        return out;
    }

    readonly property int smsPageCount: Math.max(1,
        Math.ceil(tabs.smsThreads.length / Math.max(1, tabs.smsPageSize)))

    readonly property int smsCurrentPage: Math.min(Math.max(1, tabs.smsPage), tabs.smsPageCount)

    readonly property var smsThreadPageItems: {
        const size = Math.max(1, tabs.smsPageSize);
        const start = (tabs.smsCurrentPage - 1) * size;
        return tabs.smsThreads.slice(start, start + size);
    }

    function isSmsThreadOpen(digits) {
        return !!tabs.smsOpenThreads[digits];
    }

    function toggleSmsThread(digits) {
        const o = Object.assign({}, tabs.smsOpenThreads);
        if (o[digits]) delete o[digits];
        else o[digits] = true;
        tabs.smsOpenThreads = o;
        if (o[digits]) {
            const pages = Object.assign({}, tabs.smsThreadPages);
            if (!pages[digits]) { pages[digits] = tabs.smsThreadPageSize; tabs.smsThreadPages = pages; }
            if (tabs.backend) tabs.backend.markSmsThreadRead(tabs.smsThreadAll(digits));
        }
    }

    function smsThreadShown(digits) {
        return tabs.smsThreadPages[digits] || tabs.smsThreadPageSize;
    }

    function moreSmsThread(digits) {
        const pages = Object.assign({}, tabs.smsThreadPages);
        pages[digits] = tabs.smsThreadShown(digits) + tabs.smsThreadPageSize;
        tabs.smsThreadPages = pages;
    }

    function showAllSmsThread(th) {
        if (!th) return;
        const pages = Object.assign({}, tabs.smsThreadPages);
        pages[th.digits] = th.count;
        tabs.smsThreadPages = pages;
    }

    // Reads smsThreadPages so the binding refreshes when "show older" is used.
    // 会话里全部消息（用于"打开即全部标已读"，不受当前显示条数限制）
    function smsThreadAll(digits) {
        const list = tabs.smsThreads;
        for (let i = 0; i < list.length; i++) {
            if (list[i].digits === digits) return list[i].items;
        }
        return [];
    }

    function smsThreadVisible(digits) {
        const shown = tabs.smsThreadShown(digits);
        const list = tabs.smsThreads;
        for (let i = 0; i < list.length; i++) {
            if (list[i].digits === digits) return list[i].items.slice(0, shown);
        }
        return [];
    }

    // Call states arrive from ModemManager in English.
    function callStateLabel(state) {
        const map = {
            "ringing": "响铃中", "incoming": "来电", "dialing": "拨号中",
            "outgoing": "呼出", "active": "通话中", "held": "保持中",
            "waiting": "等待中", "terminated": "已结束"
        };
        const k = String(state || "").toLowerCase();
        return map[k] || String(state || "");
    }

    function cycleSmsPageSize() {
        const opts = tabs.smsPageSizeOptions;
        let idx = opts.indexOf(tabs.smsPageSize);
        idx = (idx + 1) % opts.length;
        tabs.smsPageSize = opts[idx];
        tabs.smsPage = 1;
    }

    // Injected by the host (ModemWidget.qml)
    property var backend: null
    property var selectedModem: null
    property var modemLabels: []
    property var requestAddProfile: null
    property var requestSelectModem: null
    property var requestProfileClick: null

    // Local UI state (shared by every host instance)
    property int activeTab: 0
    readonly property var tabNames: ["网络", "短信", "电话", "定位"]
    property string smsRecipient: ""
    property string smsText: ""
    property string dialNumber: ""
    property bool confirmClearInbox: false
    property bool quotaSettingsOpen: false
    property bool quotaManualOpen: false
    property string quotaUsedInput: ""
    property string quotaRemainingInput: ""
    property string quotaTotalInput: ""

    spacing: Theme.spacingS

    function bytesLabel(value) {
        const b = Number(value) || 0;
        if (b < 1024) return b.toFixed(0) + " B";
        if (b < 1048576) return (b / 1024).toFixed(1) + " KB";
        if (b < 1073741824) return (b / 1048576).toFixed(1) + " MB";
        return (b / 1073741824).toFixed(2) + " GB";
    }

    function rateLabel(value) {
        const b = Number(value) || 0;
        if (b < 1024) return b.toFixed(0) + " B/s";
        if (b < 1048576) return (b / 1024).toFixed(1) + " KB/s";
        return (b / 1048576).toFixed(1) + " MB/s";
    }

    // ── Header ────────────────────────────────────────────────────────────
    RowLayout {
        Layout.fillWidth: true
        spacing: Theme.spacingS

        StyledText {
            Layout.fillWidth: true
            text: "SIM Network"
            color: Theme.surfaceText
            font.pixelSize: Theme.fontSizeLarge
            font.weight: Font.Medium
        }

        DankButton {
            visible: tabs.activeTab === 0
            text: "添加"
            iconName: "add"
            buttonHeight: 32
            horizontalPadding: Theme.spacingM
            backgroundColor: Theme.withAlpha(Theme.surfaceContainerHigh, 0)
            textColor: Theme.primary
            enabled: tabs.backend && !tabs.backend.busy
            onClicked: if (tabs.requestAddProfile) tabs.requestAddProfile()
        }

        DankActionButton {
            iconName: "refresh"
            enabled: tabs.backend && !tabs.backend.refreshing && !tabs.backend.busy
            onClicked: if (tabs.backend) tabs.backend.refresh()
        }
    }

    // ── Modem line ────────────────────────────────────────────────────────
    StyledText {
        Layout.fillWidth: true
        visible: tabs.selectedModem !== null
        text: tabs.selectedModem
              ? ((tabs.selectedModem.operatorName || "No network") + " · " + tabs.selectedModem.signal + "%"
                 + (tabs.selectedModem.access ? " · " + String(tabs.selectedModem.access).toUpperCase() : ""))
              : ""
        color: Theme.surfaceVariantText
        font.pixelSize: Theme.fontSizeSmall
        wrapMode: Text.Wrap
    }

    // ── Tab bar ───────────────────────────────────────────────────────────
    RowLayout {
        Layout.fillWidth: true
        spacing: Theme.spacingXS

        Repeater {
            model: tabs.tabNames.length

            Rectangle {
                required property int index
                Layout.fillWidth: true
                height: 30
                radius: Theme.cornerRadius
                color: tabs.activeTab === index
                       ? Theme.primary
                       : (tabMouse.containsMouse ? Theme.surfaceContainerHighest : Theme.surfaceContainer)

                StyledText {
                    anchors.centerIn: parent
                    text: {
                        const name = tabs.tabNames[index];
                        if (index === 2 && tabs.backend && tabs.backend.smsUnreadCount > 0)
                            return name + " (" + tabs.backend.smsUnreadCount + ")";
                        return name;
                    }
                    color: tabs.activeTab === index ? Theme.onPrimary : Theme.surfaceText
                    font.pixelSize: Theme.fontSizeSmall
                    font.weight: tabs.activeTab === index ? Font.Bold : Font.Normal
                }

                MouseArea {
                    id: tabMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: {
                        tabs.activeTab = index;
                        // Opening the inbox clears the badge.
                        if (index === 2 && tabs.backend) tabs.backend.markSmsHistoryRead();
                    }
                }
            }
        }
    }

    StyledText {
        Layout.fillWidth: true
        visible: tabs.backend !== null && tabs.backend.errorMessage.length > 0
        text: tabs.backend ? tabs.backend.errorMessage : ""
        color: Theme.error
        font.pixelSize: Theme.fontSizeSmall
        wrapMode: Text.WordWrap
    }

    // ── Tab 0: Profiles + Data (network page) ────────────────────────────
    ColumnLayout {
        id: tabProfiles
        Layout.fillWidth: true
        visible: tabs.activeTab === 0
        spacing: Theme.spacingS

        DankDropdown {
            Layout.fillWidth: true
            visible: tabs.backend !== null && tabs.backend.modems.length > 1
            text: "模块设备"
            options: tabs.modemLabels
            currentValue: tabs.selectedModem && tabs.backend ? tabs.backend.modemLabel(tabs.selectedModem) : ""
            onValueChanged: value => { if (tabs.requestSelectModem) tabs.requestSelectModem(value); }
        }

        Repeater {
            model: tabs.backend ? tabs.backend.profiles : []

            Rectangle {
                id: profileRow
                required property var modelData
                Layout.fillWidth: true
                // Height follows the profile name / APN text.
                Layout.preferredHeight: profileBody.implicitHeight + Theme.spacingS * 2
                radius: Theme.cornerRadius
                color: profileMouse.containsMouse ? Theme.surfaceContainerHighest : Theme.surfaceContainer
                border.width: connected ? 2 : 1
                border.color: connected ? Theme.primary : Theme.outlineStrong

                readonly property bool connected: tabs.backend && tabs.selectedModem
                    ? tabs.backend.isActive(modelData.uuid, tabs.selectedModem.interfaceName) : false

                RowLayout {
                    id: profileBody
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.top: parent.top
                    anchors.margins: Theme.spacingS
                    spacing: Theme.spacingS

                    Column {
                        Layout.fillWidth: true
                        spacing: 2
                        StyledText {
                            width: parent.width
                            text: modelData.name
                            color: Theme.surfaceText
                            font.weight: Font.Medium
                            wrapMode: Text.Wrap
                        }
                        StyledText {
                            width: parent.width
                            text: modelData.autoConfig ? "自动 APN" : (modelData.apn || "无 APN")
                            color: Theme.surfaceVariantText
                            font.pixelSize: Theme.fontSizeSmall
                            wrapMode: Text.Wrap
                        }
                    }

                    StyledText {
                        text: tabs.backend && tabs.backend.pendingUuid === modelData.uuid
                              ? (tabs.backend.pendingAction === "disconnect" ? "Disconnecting…" : "Connecting…")
                              : (connected ? "Connected" : "")
                        color: Theme.primary
                        font.pixelSize: Theme.fontSizeSmall
                    }
                }

                MouseArea {
                    id: profileMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    enabled: tabs.selectedModem !== null && tabs.backend && !tabs.backend.busy
                    cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
                    onClicked: if (tabs.requestProfileClick) tabs.requestProfileClick(modelData)
                }
            }
        }


        // WWAN radio toggle — the master switch lives only on the network page,
        // not under every tab.
        DankButton {
            Layout.fillWidth: true
            text: tabs.backend && tabs.backend.wwanEnabled ? "关闭 WWAN（断开 4G）" : "开启 WWAN"
            buttonHeight: 32
            backgroundColor: tabs.backend && tabs.backend.wwanEnabled ? Theme.error : Theme.primary
            textColor: Theme.onPrimary
            enabled: tabs.backend !== null && !tabs.backend.busy
            onClicked: if (tabs.backend) tabs.backend.setRadio(!tabs.backend.wwanEnabled)
        }

        Rectangle { Layout.fillWidth: true; height: 1; color: Theme.border }

        // ── This SIM's own number ─────────────────────────────────────────
        // The modem reports own-numbers as empty for this SIM, so it is typed
        // in once by hand and remembered.
        RowLayout {
            Layout.fillWidth: true
            spacing: Theme.spacingS

            StyledText {
                text: "本机号码"
                color: Theme.surfaceVariantText
                font.pixelSize: Theme.fontSizeSmall
            }

            StyledText {
                Layout.fillWidth: true
                text: {
                    if (!tabs.backend) return "--";
                    const n = String(tabs.backend.ownNumber() || "");
                    return n.length > 0 ? n : "未填写";
                }
                color: {
                    if (!tabs.backend) return Theme.surfaceText;
                    return String(tabs.backend.ownNumber() || "").length > 0
                           ? Theme.surfaceText : Theme.surfaceVariantText;
                }
                font.pixelSize: Theme.fontSizeLarge
                font.weight: Font.Medium
                wrapMode: Text.Wrap
            }

            StyledText {
                text: tabs.backend ? tabs.backend.simLabel() : ""
                color: Theme.surfaceVariantText
                font.pixelSize: Theme.fontSizeSmall
            }

            DankActionButton {
                iconName: tabs.editingOwnNumber ? "close" : "edit"
                onClicked: tabs.editingOwnNumber = !tabs.editingOwnNumber
            }
        }

        RowLayout {
            Layout.fillWidth: true
            visible: tabs.editingOwnNumber
            spacing: Theme.spacingS

            DankTextField {
                id: ownNumberField
                Layout.fillWidth: true
                placeholderText: "本机号码，例如 13800138000"
                text: tabs.backend ? tabs.backend.ownNumber() : ""
            }

            DankButton {
                text: "保存"
                buttonHeight: 32
                onClicked: {
                    if (tabs.backend) tabs.backend.setOwnNumber(ownNumberField.text);
                    tabs.editingOwnNumber = false;
                }
            }
        }

        // ── Headline figures ──────────────────────────────────────────────
        GridLayout {
            Layout.fillWidth: true
            columns: 2
            columnSpacing: Theme.spacingM
            rowSpacing: Theme.spacingXS

            StyledText {
                text: "总流量"
                color: Theme.surfaceVariantText
                font.pixelSize: Theme.fontSizeSmall
            }
            StyledText {
                Layout.fillWidth: true
                text: {
                    if (!tabs.backend) return "--";
                    const e = tabs.backend.computeQuotaEstimate();
                    if (!e || e.total < 0) return "未记录（点「查询」获取）";
                    return tabs.bytesLabel(e.total);
                }
                color: Theme.surfaceText
                font.pixelSize: Theme.fontSizeSmall
                wrapMode: Text.Wrap
            }

            StyledText {
                text: "已用流量"
                color: Theme.surfaceVariantText
                font.pixelSize: Theme.fontSizeSmall
            }
            StyledText {
                Layout.fillWidth: true
                text: {
                    if (!tabs.backend) return "--";
                    const e = tabs.backend.computeQuotaEstimate();
                    if (!e || e.used < 0) return "--";
                    return tabs.bytesLabel(e.used) + (e.localSince > 0 ? ("（含本机 +" + tabs.bytesLabel(e.localSince) + "）") : "");
                }
                color: Theme.surfaceText
                font.pixelSize: Theme.fontSizeSmall
                font.weight: Font.Medium
                wrapMode: Text.Wrap
            }

            StyledText {
                text: "剩余流量"
                color: Theme.surfaceVariantText
                font.pixelSize: Theme.fontSizeSmall
            }
            StyledText {
                Layout.fillWidth: true
                text: {
                    if (!tabs.backend) return "--";
                    const e = tabs.backend.computeQuotaEstimate();
                    if (!e || e.remaining < 0) return "--";
                    return tabs.bytesLabel(e.remaining);
                }
                color: {
                    if (!tabs.backend) return Theme.surfaceText;
                    const e = tabs.backend.computeQuotaEstimate();
                    if (!e || e.remaining < 0 || e.total <= 0) return Theme.surfaceText;
                    const left = e.remaining / e.total;
                    return left < 0.1 ? Theme.error : (left < 0.25 ? Theme.warning : Theme.success);
                }
                font.pixelSize: Theme.fontSizeSmall
                font.weight: Font.Medium
                wrapMode: Text.Wrap
            }

            StyledText {
                text: "今日流量"
                color: Theme.surfaceVariantText
                font.pixelSize: Theme.fontSizeSmall
            }
            StyledText {
                Layout.fillWidth: true
                text: tabs.backend
                      ? ("↓" + tabs.bytesLabel(tabs.backend.todayRx) + "   ↑" + tabs.bytesLabel(tabs.backend.todayTx))
                      : "--"
                color: Theme.surfaceText
                font.pixelSize: Theme.fontSizeSmall
                wrapMode: Text.Wrap
            }

            StyledText {
                text: "当前流速"
                color: Theme.surfaceVariantText
                font.pixelSize: Theme.fontSizeSmall
            }
            StyledText {
                Layout.fillWidth: true
                text: tabs.backend
                      ? ("↓" + tabs.rateLabel(tabs.backend.rxRate) + "   ↑" + tabs.rateLabel(tabs.backend.txRate))
                      : "--"
                color: tabs.backend && (tabs.backend.rxRate > 0 || tabs.backend.txRate > 0)
                       ? Theme.primary : Theme.surfaceText
                font.pixelSize: Theme.fontSizeSmall
                wrapMode: Text.Wrap
            }
        }

        // Used share of the plan.
        Rectangle {
            Layout.fillWidth: true
            height: 6
            radius: 3
            color: Theme.surfaceContainerHighest
            visible: {
                if (!tabs.backend) return false;
                const e = tabs.backend.computeQuotaEstimate();
                return !!e && e.used >= 0 && e.total > 0;
            }
            Rectangle {
                height: parent.height
                radius: parent.radius
                color: {
                    if (!tabs.backend) return Theme.primary;
                    const e = tabs.backend.computeQuotaEstimate();
                    if (!e || e.used < 0 || e.total <= 0) return Theme.primary;
                    const pct = e.used / e.total;
                    return pct > 0.9 ? Theme.error : (pct > 0.75 ? Theme.warning : Theme.primary);
                }
                width: {
                    if (!tabs.backend) return 0;
                    const e = tabs.backend.computeQuotaEstimate();
                    if (!e || e.used < 0 || e.total <= 0) return 0;
                    return Math.min(parent.width, parent.width * (e.used / e.total));
                }
            }
        }

        StyledText {
            Layout.fillWidth: true
            text: {
                if (!tabs.backend) return "";
                if (!tabs.backend.quotaIsCurrentMonth())
                    return "本月还没有账单：发 " + tabs.backend.quotaQueryText + " 到 " + tabs.backend.quotaQueryNumber + " 获取";
                const q = tabs.backend.quota;
                return (q.source === "manual" ? "手动输入" : "运营商回复")
                     + " · " + String(q.at || "").slice(0, 16).replace("T", "")
                     + " · " + q.month;
            }
            color: Theme.surfaceVariantText
            font.pixelSize: Theme.fontSizeSmall
            wrapMode: Text.Wrap
        }

        RowLayout {
            Layout.fillWidth: true
            spacing: Theme.spacingS

            DankButton {
                Layout.fillWidth: true
                text: tabs.backend && tabs.backend.quotaQueryPending ? "等待回复…" : "查询运营商"
                iconName: "sms"
                buttonHeight: 32
                enabled: tabs.backend && !tabs.backend.quotaQueryPending && !tabs.backend.smsSending
                onClicked: if (tabs.backend) tabs.backend.requestQuotaQuery()
            }
            DankActionButton {
                iconName: tabs.quotaManualOpen ? "expand_less" : "edit"
                onClicked: tabs.quotaManualOpen = !tabs.quotaManualOpen
            }
            DankActionButton {
                iconName: tabs.quotaSettingsOpen ? "expand_less" : "tune"
                onClicked: tabs.quotaSettingsOpen = !tabs.quotaSettingsOpen
            }
        }

        StyledText {
            Layout.fillWidth: true
            visible: tabs.backend !== null && tabs.backend.quotaStatus.length > 0
            text: tabs.backend ? tabs.backend.quotaStatus : ""
            color: Theme.primary
            font.pixelSize: Theme.fontSizeSmall
            wrapMode: Text.WordWrap
        }

        // Manual entry: total / used / remaining.
        ColumnLayout {
            Layout.fillWidth: true
            visible: tabs.quotaManualOpen
            spacing: Theme.spacingXS
            StyledText {
                Layout.fillWidth: true
                text: "手动填写（三项填任意一到三项，纯数字按 GB 算）"
                color: Theme.surfaceVariantText
                font.pixelSize: Theme.fontSizeSmall
                wrapMode: Text.WordWrap
            }
            RowLayout {
                Layout.fillWidth: true
                spacing: Theme.spacingS
                DankTextField {
                    Layout.fillWidth: true
                    placeholderText: "总量"
                    text: tabs.quotaTotalInput
                    onTextChanged: tabs.quotaTotalInput = text
                }
                DankTextField {
                    Layout.fillWidth: true
                    placeholderText: "已用"
                    text: tabs.quotaUsedInput
                    onTextChanged: tabs.quotaUsedInput = text
                }
                DankTextField {
                    Layout.fillWidth: true
                    placeholderText: "剩余"
                    text: tabs.quotaRemainingInput
                    onTextChanged: tabs.quotaRemainingInput = text
                }
                DankButton {
                    text: "保存"
                    buttonHeight: 32
                    enabled: tabs.quotaTotalInput.length > 0 || tabs.quotaUsedInput.length > 0
                             || tabs.quotaRemainingInput.length > 0
                    onClicked: {
                        if (!tabs.backend) return;
                        tabs.backend.setQuotaManual(tabs.quotaUsedInput, tabs.quotaRemainingInput, tabs.quotaTotalInput);
                        tabs.quotaTotalInput = "";
                        tabs.quotaUsedInput = "";
                        tabs.quotaRemainingInput = "";
                        tabs.quotaManualOpen = false;
                    }
                }
            }
        }

        ColumnLayout {
            Layout.fillWidth: true
            visible: tabs.quotaSettingsOpen
            spacing: Theme.spacingXS
            StyledText {
                Layout.fillWidth: true
                text: "查询号码 / 查询内容"
                color: Theme.surfaceVariantText
                font.pixelSize: Theme.fontSizeSmall
            }
            RowLayout {
                Layout.fillWidth: true
                spacing: Theme.spacingS
                DankTextField {
                    Layout.fillWidth: true
                    placeholderText: "10001"
                    text: tabs.backend ? tabs.backend.quotaQueryNumber : ""
                    onTextChanged: {
                        if (!tabs.backend) return;
                        tabs.backend.quotaQueryNumber = text;
                        tabs.backend.saveQuotaSettings();
                    }
                }
                DankTextField {
                    Layout.fillWidth: true
                    placeholderText: "108"
                    text: tabs.backend ? tabs.backend.quotaQueryText : ""
                    onTextChanged: {
                        if (!tabs.backend) return;
                        tabs.backend.quotaQueryText = text;
                        tabs.backend.saveQuotaSettings();
                    }
                }
            }
            DankToggle {
                Layout.fillWidth: true
                text: "每月自动查询一次"
                checked: tabs.backend ? tabs.backend.quotaAutoQuery : false
                onToggled: value => {
                    if (!tabs.backend) return;
                    tabs.backend.quotaAutoQuery = value;
                    tabs.backend.saveQuotaSettings();
                }
            }
        }

        Rectangle { Layout.fillWidth: true; height: 1; color: Theme.border }

        // ── Local ledger detail ───────────────────────────────────────────
        GridLayout {
            Layout.fillWidth: true
            columns: 2
            columnSpacing: Theme.spacingM
            rowSpacing: Theme.spacingXS

            StyledText { text: "本机累计"; color: Theme.surfaceVariantText; font.pixelSize: Theme.fontSizeSmall }
            StyledText {
                Layout.fillWidth: true
                text: tabs.backend
                      ? ("↓" + tabs.bytesLabel(tabs.backend.lifetimeRx) + "   ↑" + tabs.bytesLabel(tabs.backend.lifetimeTx))
                      : "--"
                color: Theme.surfaceText
                font.pixelSize: Theme.fontSizeSmall
            }

            StyledText { text: "接口"; color: Theme.surfaceVariantText; font.pixelSize: Theme.fontSizeSmall }
            StyledText { Layout.fillWidth: true; text: tabs.backend ? tabs.backend.statsInterface : "--"; color: Theme.surfaceText; font.pixelSize: Theme.fontSizeSmall; wrapMode: Text.Wrap }

            StyledText { text: "IPv4"; color: Theme.surfaceVariantText; font.pixelSize: Theme.fontSizeSmall }
            RowLayout {
                Layout.fillWidth: true
                spacing: Theme.spacingXS
                StyledText {
                    Layout.fillWidth: true
                    text: tabs.backend && tabs.backend.wanIPv4 ? tabs.backend.wanIPv4 : "未获取"
                    color: tabs.backend && tabs.backend.wanIPv4 ? Theme.surfaceText : Theme.surfaceVariantText
                    font.pixelSize: Theme.fontSizeSmall
                    wrapMode: Text.Wrap
                }
                DankActionButton {
                    iconName: tabs.copiedKey === "wan-ipv4" ? "check" : "content_copy"
                    visible: tabs.backend && tabs.backend.wanIPv4.length > 0
                    onClicked: {
                        if (!tabs.backend) return;
                        tabs.backend.copyToClipboard(tabs.backend.wanIPv4);
                        tabs.copiedKey = "wan-ipv4";
                        copyReset.restart();
                    }
                }
            }

            StyledText { text: "IPv6"; color: Theme.surfaceVariantText; font.pixelSize: Theme.fontSizeSmall }
            RowLayout {
                Layout.fillWidth: true
                spacing: Theme.spacingXS
                StyledText {
                    Layout.fillWidth: true
                    text: tabs.backend && tabs.backend.wanIPv6 ? tabs.backend.wanIPv6 : "无"
                    color: tabs.backend && tabs.backend.wanIPv6 ? Theme.surfaceText : Theme.surfaceVariantText
                    font.pixelSize: Theme.fontSizeSmall
                    wrapMode: Text.Wrap
                }
                DankActionButton {
                    iconName: tabs.copiedKey === "wan-ipv6" ? "check" : "content_copy"
                    visible: tabs.backend && tabs.backend.wanIPv6.length > 0
                    onClicked: {
                        if (!tabs.backend) return;
                        tabs.backend.copyToClipboard(tabs.backend.wanIPv6);
                        tabs.copiedKey = "wan-ipv6";
                        copyReset.restart();
                    }
                }
            }

            StyledText { text: "网关"; color: Theme.surfaceVariantText; font.pixelSize: Theme.fontSizeSmall }
            StyledText { Layout.fillWidth: true; text: tabs.backend && tabs.backend.wanGateway ? tabs.backend.wanGateway : "--"; color: Theme.surfaceText; font.pixelSize: Theme.fontSizeSmall; wrapMode: Text.Wrap }

            StyledText { text: "公网 IPv4"; color: Theme.surfaceVariantText; font.pixelSize: Theme.fontSizeSmall }
            RowLayout {
                Layout.fillWidth: true
                spacing: Theme.spacingXS
                StyledText {
                    Layout.fillWidth: true
                    text: tabs.backend && tabs.backend.publicIPv4.length > 0
                          ? tabs.backend.publicIPv4 : "未查询"
                    color: tabs.backend && tabs.backend.publicIPv4.length > 0
                           ? Theme.primary : Theme.surfaceVariantText
                    font.pixelSize: Theme.fontSizeSmall
                    wrapMode: Text.Wrap
                }
                DankActionButton {
                    iconName: tabs.copiedKey === "public-ipv4" ? "check" : "content_copy"
                    visible: tabs.backend && tabs.backend.publicIPv4.length > 0
                    onClicked: {
                        if (!tabs.backend) return;
                        tabs.backend.copyToClipboard(tabs.backend.publicIPv4);
                        tabs.copiedKey = "public-ipv4";
                        copyReset.restart();
                    }
                }
            }

            StyledText { text: "公网 IPv6"; color: Theme.surfaceVariantText; font.pixelSize: Theme.fontSizeSmall }
            RowLayout {
                Layout.fillWidth: true
                spacing: Theme.spacingXS
                StyledText {
                    Layout.fillWidth: true
                    text: tabs.backend && tabs.backend.publicIPv6.length > 0
                          ? tabs.backend.publicIPv6 : "未查询"
                    color: tabs.backend && tabs.backend.publicIPv6.length > 0
                           ? Theme.primary : Theme.surfaceVariantText
                    font.pixelSize: Theme.fontSizeSmall
                    wrapMode: Text.Wrap
                }
                DankActionButton {
                    iconName: tabs.copiedKey === "public-ipv6" ? "check" : "content_copy"
                    visible: tabs.backend && tabs.backend.publicIPv6.length > 0
                    onClicked: {
                        if (!tabs.backend) return;
                        tabs.backend.copyToClipboard(tabs.backend.publicIPv6);
                        tabs.copiedKey = "public-ipv6";
                        copyReset.restart();
                    }
                }
            }

            RowLayout {
                Layout.fillWidth: true
                Layout.columnSpan: 2
                spacing: Theme.spacingS
                StyledText {
                    Layout.fillWidth: true
                    text: tabs.backend && tabs.backend.publicIPStatus.length > 0
                          ? tabs.backend.publicIPStatus : "（运营商出口地址，需联网查询）"
                    color: Theme.surfaceVariantText
                    font.pixelSize: Theme.fontSizeSmall
                    wrapMode: Text.Wrap
                }
                DankButton {
                    text: "查询公网 IP"
                    buttonHeight: 26
                    enabled: tabs.backend !== null && tabs.backend.publicIPStatus.length === 0
                    onClicked: if (tabs.backend) tabs.backend.queryPublicAddresses()
                }
            }

            // ── IP protocol selector (IPv4 / IPv6 / dual stack) ───────────
            StyledText { text: "IP 协议"; color: Theme.surfaceVariantText; font.pixelSize: Theme.fontSizeSmall }
            StyledText {
                Layout.fillWidth: true
                text: {
                    if (!tabs.backend) return "--";
                    const m = tabs.backend.ipMode;
                    return m === "v4" ? "仅 IPv4" : (m === "v6" ? "仅 IPv6" : (m === "both" ? "双栈" : "未知"));
                }
                color: Theme.surfaceText
                font.pixelSize: Theme.fontSizeSmall
            }

            Item { Layout.fillWidth: true; implicitHeight: 1 }
            RowLayout {
                Layout.fillWidth: true
                Layout.columnSpan: 2
                spacing: Theme.spacingS

                DankButton {
                    Layout.fillWidth: true
                    text: "双栈"
                    buttonHeight: 28
                    backgroundColor: tabs.backend && tabs.backend.ipMode === "both"
                                     ? Theme.primary : Theme.surfaceContainerHighest
                    textColor: tabs.backend && tabs.backend.ipMode === "both"
                               ? Theme.onPrimary : Theme.surfaceText
                    onClicked: if (tabs.backend) tabs.backend.setIpMode("both")
                }
                DankButton {
                    Layout.fillWidth: true
                    text: "仅 IPv4"
                    buttonHeight: 28
                    backgroundColor: tabs.backend && tabs.backend.ipMode === "v4"
                                     ? Theme.primary : Theme.surfaceContainerHighest
                    textColor: tabs.backend && tabs.backend.ipMode === "v4"
                               ? Theme.onPrimary : Theme.surfaceText
                    onClicked: if (tabs.backend) tabs.backend.setIpMode("v4")
                }
                DankButton {
                    Layout.fillWidth: true
                    text: "仅 IPv6"
                    buttonHeight: 28
                    backgroundColor: tabs.backend && tabs.backend.ipMode === "v6"
                                     ? Theme.primary : Theme.surfaceContainerHighest
                    textColor: tabs.backend && tabs.backend.ipMode === "v6"
                               ? Theme.onPrimary : Theme.surfaceText
                    onClicked: if (tabs.backend) tabs.backend.setIpMode("v6")
                }
            }

            StyledText {
                Layout.fillWidth: true
                Layout.columnSpan: 2
                visible: tabs.backend !== null && tabs.backend.ipModeStatus.length > 0
                text: tabs.backend
                      ? (tabs.backend.ipModeStatus === "已切换并重连"
                         ? "已切换并重连（切换时会短暂断网）"
                         : tabs.backend.ipModeStatus)
                      : ""
                color: Theme.surfaceVariantText
                font.pixelSize: Theme.fontSizeSmall
                wrapMode: Text.Wrap
            }

            StyledText { text: "WWAN"; color: Theme.surfaceVariantText; font.pixelSize: Theme.fontSizeSmall }
            StyledText {
                Layout.fillWidth: true
                text: tabs.backend && tabs.backend.wwanEnabled ? "已启用" : "已关闭"
                color: tabs.backend && tabs.backend.wwanEnabled ? Theme.success : Theme.surfaceText
                font.pixelSize: Theme.fontSizeSmall
            }
        }

        RowLayout {
            Layout.fillWidth: true
            spacing: Theme.spacingS
            StyledText {
                Layout.fillWidth: true
                text: "最近 7 天"
                color: Theme.surfaceText
                font.pixelSize: Theme.fontSizeSmall
                font.weight: Font.Medium
            }
            StyledText {
                text: "账本 " + (tabs.backend && tabs.backend.retentionDays > 0 ? tabs.backend.retentionDays + " 天" : "不限")
                color: Theme.surfaceVariantText
                font.pixelSize: Theme.fontSizeSmall
            }
        }

        Repeater {
            model: tabs.backend ? tabs.backend.recentUsageDays(7) : []

            RowLayout {
                required property var modelData
                Layout.fillWidth: true
                spacing: Theme.spacingS
                StyledText {
                    Layout.preferredWidth: 84
                    text: modelData.key
                    color: Theme.surfaceVariantText
                    font.pixelSize: Theme.fontSizeSmall
                }
                StyledText {
                    Layout.fillWidth: true
                    text: "↓" + tabs.bytesLabel(modelData.rx) + "   ↑" + tabs.bytesLabel(modelData.tx)
                    color: Theme.surfaceText
                    font.pixelSize: Theme.fontSizeSmall
                }
            }
        }

        StyledText {
            Layout.fillWidth: true
            visible: tabs.backend !== null && !tabs.backend.dataUsageAvailable
            text: "该接口暂无实时计数器。"
            color: Theme.surfaceVariantText
            font.pixelSize: Theme.fontSizeSmall
            wrapMode: Text.WordWrap
        }
    }

    // ── Tab 1: SMS ────────────────────────────────────────────────────────
    ColumnLayout {
        id: tabSms
        Layout.fillWidth: true
        visible: tabs.activeTab === 1
        spacing: Theme.spacingS

        DankTextField {
            Layout.fillWidth: true
            placeholderText: "对方号码"
            text: tabs.smsRecipient
            onTextChanged: tabs.smsRecipient = text
        }

        DankTextField {
            Layout.fillWidth: true
            placeholderText: "短信内容"
            text: tabs.smsText
            onTextChanged: tabs.smsText = text
        }

        DankButton {
            Layout.fillWidth: true
            text: tabs.backend && tabs.backend.smsSending ? "发送中…" : "发送短信"
            iconName: "send"
            buttonHeight: 34
            enabled: tabs.backend && !tabs.backend.smsSending
                     && tabs.smsRecipient.length > 0 && tabs.smsText.length > 0
            onClicked: {
                if (!tabs.backend) return;
                tabs.backend.sendSms(tabs.smsRecipient, tabs.smsText, (ok, msg) => {
                    if (ok) tabs.smsText = "";
                });
            }
        }

        StyledText {
            Layout.fillWidth: true
            visible: text.length > 0
            text: tabs.backend ? tabs.backend.smsStatusMessage : ""
            color: Theme.surfaceVariantText
            font.pixelSize: Theme.fontSizeSmall
            wrapMode: Text.WordWrap
        }

        Rectangle { Layout.fillWidth: true; height: 1; color: Theme.border }

        // ── 彩信：用上面那个"对方号码"，选一张图发出去 ──────────────────
        StyledText {
            Layout.fillWidth: true
            text: "彩信（图片自动压到 100KB 以内 —— 模块存储很小）"
            color: Theme.surfaceVariantText
            font.pixelSize: Theme.fontSizeSmall
        }

        RowLayout {
            Layout.fillWidth: true
            spacing: Theme.spacingS

            DankButton {
                Layout.fillWidth: true
                text: {
                    const picked = tabs.backend ? tabs.backend.mmsImagePath : "";
                    return picked.length > 0 ? ("图片：" + picked.split("/").pop()) : "选择图片";
                }
                iconName: "image"
                buttonHeight: 34
                enabled: tabs.backend && !tabs.backend.mmsSending
                onClicked: if (tabs.backend) tabs.backend.pickMmsImage()
            }

            DankButton {
                text: tabs.backend && tabs.backend.mmsSending ? "发送中…" : "发送彩信"
                iconName: "send"
                buttonHeight: 34
                enabled: tabs.backend && !tabs.backend.mmsSending
                         && tabs.smsRecipient.length > 0
                         && tabs.backend.mmsImagePath.length > 0
                onClicked: {
                    if (!tabs.backend) return;
                    tabs.backend.sendMms(tabs.smsRecipient, tabs.backend.mmsImagePath);
                }
            }
        }

        Image {
            Layout.fillWidth: true
            Layout.maximumHeight: 150
            visible: tabs.backend && tabs.backend.mmsImagePath.length > 0
            source: (tabs.backend && tabs.backend.mmsImagePath.length > 0)
                    ? ("file://" + tabs.backend.mmsImagePath) : ""
            fillMode: Image.PreserveAspectFit
            sourceSize.height: 300
            asynchronous: true
        }

        StyledText {
            Layout.fillWidth: true
            visible: text.length > 0
            text: tabs.backend ? tabs.backend.mmsSendStatus : ""
            color: Theme.surfaceVariantText
            font.pixelSize: Theme.fontSizeSmall
            wrapMode: Text.WordWrap
        }

        // Kept inbox: polled messages are mirrored into a persisted ledger so
        // they survive deletion on the modem or a SIM swap.
        RowLayout {
            Layout.fillWidth: true
            spacing: Theme.spacingS
            StyledText {
                Layout.fillWidth: true
                text: "收件箱"
                color: Theme.surfaceText
                font.pixelSize: Theme.fontSizeSmall
                font.weight: Font.Medium
            }
            StyledText {
                text: {
                    if (!tabs.backend) return "";
                    const total = tabs.backend.smsHistory.length;
                    const shown = tabs.smsFiltered.length;
                    if (tabs.smsSearch.trim().length > 0 && shown !== total)
                        return shown + " / " + total;
                    return total + " kept";
                }
                color: Theme.surfaceVariantText
                font.pixelSize: Theme.fontSizeSmall
            }
            DankActionButton {
                iconName: "delete_sweep"
                enabled: tabs.backend && tabs.backend.smsHistory.length > 0
                onClicked: tabs.confirmClearInbox = true
            }
        }

        RowLayout {
            Layout.fillWidth: true
            visible: tabs.confirmClearInbox
            spacing: Theme.spacingS
            StyledText {
                Layout.fillWidth: true
                text: "确定清空收件箱里的全部短信？"
                color: Theme.error
                font.pixelSize: Theme.fontSizeSmall
            }
            DankButton {
                text: "取消"
                buttonHeight: 28
                onClicked: tabs.confirmClearInbox = false
            }
            DankButton {
                text: "清空"
                buttonHeight: 28
                backgroundColor: Theme.error
                textColor: Theme.onPrimary
                onClicked: {
                    if (tabs.backend) tabs.backend.clearSmsHistory();
                    tabs.confirmClearInbox = false;
                }
            }
        }

        // ── Search ────────────────────────────────────────────────────────
        RowLayout {
            Layout.fillWidth: true
            spacing: Theme.spacingS

            DankTextField {
                id: smsSearchField
                Layout.fillWidth: true
                placeholderText: "搜索号码 / 内容 / 日期"
                text: tabs.smsSearch
                onTextChanged: {
                    tabs.smsSearch = text;
                    tabs.smsPage = 1;
                }
            }

            DankActionButton {
                iconName: "search_off"
                visible: tabs.smsSearch.length > 0
                onClicked: {
                    smsSearchField.text = "";
                    tabs.smsSearch = "";
                    tabs.smsPage = 1;
                }
            }
        }

        // ── Pager ─────────────────────────────────────────────────────────
        RowLayout {
            Layout.fillWidth: true
            spacing: Theme.spacingXS

            DankActionButton {
                iconName: "first_page"
                enabled: tabs.smsCurrentPage > 1
                onClicked: tabs.smsPage = 1
            }
            DankActionButton {
                iconName: "chevron_left"
                enabled: tabs.smsCurrentPage > 1
                onClicked: tabs.smsPage = tabs.smsCurrentPage - 1
            }
            StyledText {
                text: tabs.smsCurrentPage + " / " + tabs.smsPageCount + " 页 · 共 " + tabs.smsThreads.length + " 个会话"
                color: Theme.surfaceText
                font.pixelSize: Theme.fontSizeSmall
            }
            DankActionButton {
                iconName: "chevron_right"
                enabled: tabs.smsCurrentPage < tabs.smsPageCount
                onClicked: tabs.smsPage = tabs.smsCurrentPage + 1
            }
            DankActionButton {
                iconName: "last_page"
                enabled: tabs.smsCurrentPage < tabs.smsPageCount
                onClicked: tabs.smsPage = tabs.smsPageCount
            }

            Item { Layout.fillWidth: true }

            StyledText {
                text: "每页 " + tabs.smsPageSize + " 个会话"
                color: Theme.surfaceVariantText
                font.pixelSize: Theme.fontSizeSmall
            }
            DankActionButton {
                iconName: "format_list_numbered"
                onClicked: tabs.cycleSmsPageSize()
            }
        }

        StyledText {
            Layout.fillWidth: true
            visible: tabs.backend !== null && tabs.backend.smsHistory.length === 0
            text: "还没有短信 —— 收到的会自动出现在这里。"
            color: Theme.surfaceVariantText
            font.pixelSize: Theme.fontSizeSmall
            wrapMode: Text.WordWrap
        }

        StyledText {
            Layout.fillWidth: true
            visible: tabs.backend !== null && tabs.backend.smsHistory.length > 0
                     && tabs.smsThreads.length === 0
            text: "没有匹配的短信 —— 换个关键词试试。"
            color: Theme.surfaceVariantText
            font.pixelSize: Theme.fontSizeSmall
            wrapMode: Text.Wrap
        }

        Repeater {
            model: tabs.smsThreadPageItems

            Rectangle {
                id: smsThreadCard
                required property var modelData
                Layout.fillWidth: true
                // Grows with the expanded conversation, never clipped.
                Layout.preferredHeight: smsThreadBody.implicitHeight + Theme.spacingS * 2
                radius: Theme.cornerRadius
                color: Theme.surfaceContainer

                ColumnLayout {
                    id: smsThreadBody
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.top: parent.top
                    anchors.margins: Theme.spacingS
                    spacing: Theme.spacingXS

                    // ── Header: number + latest message (always visible) ──
                    RowLayout {
                        Layout.fillWidth: true
                        spacing: Theme.spacingS

                        DankIcon {
                            name: smsThreadCard.modelData.latest.isSubmit ? "call_made" : "call_received"
                            size: 16
                            Layout.alignment: Qt.AlignTop
                            color: smsThreadCard.modelData.latest.isSubmit
                                   ? Theme.surfaceVariantText : Theme.primary
                        }

                        ColumnLayout {
                            Layout.fillWidth: true
                            spacing: 2

                            RowLayout {
                                Layout.fillWidth: true
                                spacing: Theme.spacingXS

                                StyledText {
                                    Layout.fillWidth: true
                                    text: smsThreadCard.modelData.label
                                    color: Theme.primary
                                    font.pixelSize: Theme.fontSizeSmall
                                    font.weight: Font.Medium
                                    elide: Text.ElideRight
                                }

                                Rectangle {
                                    visible: smsThreadCard.modelData.unread > 0
                                    implicitWidth: smsUnreadLabel.implicitWidth + Theme.spacingXS * 2
                                    implicitHeight: smsUnreadLabel.implicitHeight + 2
                                    radius: height / 2
                                    color: Theme.primary

                                    StyledText {
                                        id: smsUnreadLabel
                                        anchors.centerIn: parent
                                        text: smsThreadCard.modelData.unread
                                        color: Theme.onPrimary
                                        font.pixelSize: Theme.fontSizeSmall
                                        font.weight: Font.Medium
                                    }
                                }

                                StyledText {
                                    text: smsThreadCard.modelData.count + " 条"
                                    color: Theme.surfaceVariantText
                                    font.pixelSize: Theme.fontSizeSmall
                                }
                            }

                            StyledText {
                                Layout.fillWidth: true
                                text: (smsThreadCard.modelData.latest.isSubmit ? "我：" : "")
                                      + (smsThreadCard.modelData.latest.kind === "mms" ? "【彩信】" : "")
                                      + String(smsThreadCard.modelData.latest.preview
                                               || smsThreadCard.modelData.latest.text || "")
                                color: Theme.surfaceText
                                font.pixelSize: Theme.fontSizeSmall
                                elide: Text.ElideRight
                                maximumLineCount: 1
                            }

                            StyledText {
                                Layout.fillWidth: true
                                text: String(smsThreadCard.modelData.latest.timestamp || "")
                                color: Theme.surfaceVariantText
                                font.pixelSize: Theme.fontSizeSmall
                            }
                        }

                        DankActionButton {
                            iconName: tabs.isSmsThreadOpen(smsThreadCard.modelData.digits)
                                      ? "expand_less" : "expand_more"
                            Layout.alignment: Qt.AlignTop
                            onClicked: tabs.toggleSmsThread(smsThreadCard.modelData.digits)
                        }
                    }

                    // ── Expanded conversation (newest first), paged ──
                    ColumnLayout {
                        Layout.fillWidth: true
                        visible: tabs.isSmsThreadOpen(smsThreadCard.modelData.digits)
                        spacing: Theme.spacingXS

                        Repeater {
                            model: tabs.smsThreadVisible(smsThreadCard.modelData.digits)

                            Rectangle {
                                id: smsRow
                                required property var modelData
                                Layout.fillWidth: true
                                Layout.preferredHeight: smsRowBody.implicitHeight + Theme.spacingS * 2
                                radius: Theme.cornerRadius
                                color: Theme.surfaceContainerHighest

                                RowLayout {
                                    id: smsRowBody
                                    anchors.left: parent.left
                                    anchors.right: parent.right
                                    anchors.top: parent.top
                                    anchors.margins: Theme.spacingS
                                    spacing: Theme.spacingS

                                    DankIcon {
                                        name: smsRow.modelData.isSubmit ? "call_made" : "call_received"
                                        size: 14
                                        Layout.alignment: Qt.AlignTop
                                        color: smsRow.modelData.isSubmit
                                               ? Theme.surfaceVariantText : Theme.primary
                                    }

                                    Column {
                                        Layout.fillWidth: true
                                        spacing: 2

                                        // 彩信标记
                                        Rectangle {
                                            visible: smsRow.modelData.kind === "mms"
                                            width: mmsChip.implicitWidth + Theme.spacingXS * 2
                                            height: mmsChip.implicitHeight + 2
                                            radius: height / 2
                                            color: Theme.primaryContainer

                                            StyledText {
                                                id: mmsChip
                                                anchors.centerIn: parent
                                                text: "彩信"
                                                color: Theme.primary
                                                font.pixelSize: Theme.fontSizeSmall
                                                font.weight: Font.Medium
                                            }
                                        }

                                        // 彩信附件（图片）——按原始比例铺满行宽
                                        Repeater {
                                            model: smsRow.modelData.attachments
                                                   ? smsRow.modelData.attachments : []

                                            Image {
                                                required property var modelData
                                                width: Math.min(parent.width, 360)
                                                height: implicitWidth > 0
                                                        ? width * (implicitHeight / implicitWidth) : 0
                                                source: modelData.path ? ("file://" + modelData.path) : ""
                                                sourceSize.width: 720
                                                fillMode: Image.PreserveAspectFit
                                                asynchronous: true
                                                cache: true
                                                visible: status === Image.Ready
                                                smooth: true
                                            }
                                        }

                                        StyledText {
                                            width: parent.width
                                            text: smsRow.modelData.text || ""
                                            color: Theme.surfaceText
                                            font.pixelSize: Theme.fontSizeSmall
                                            wrapMode: Text.Wrap
                                        }

                                        StyledText {
                                            width: parent.width
                                            text: String(smsRow.modelData.timestamp || "")
                                            color: Theme.surfaceVariantText
                                            font.pixelSize: Theme.fontSizeSmall
                                            wrapMode: Text.Wrap
                                        }
                                    }

                                    DankActionButton {
                                        iconName: tabs.copiedKey === smsRow.modelData.key
                                                  ? "check" : "content_copy"
                                        Layout.alignment: Qt.AlignTop
                                        onClicked: {
                                            if (tabs.backend) tabs.backend.copyToClipboard(smsRow.modelData.text || "");
                                            tabs.copiedKey = smsRow.modelData.key;
                                            copyReset.restart();
                                        }
                                    }

                                    DankActionButton {
                                        iconName: "delete"
                                        Layout.alignment: Qt.AlignTop
                                        onClicked: if (tabs.backend)
                                            tabs.backend.deleteSmsHistoryItem(smsRow.modelData.key)
                                    }
                                }
                            }
                        }

                        // Per-thread paging: reveal older messages in chunks.
                        RowLayout {
                            Layout.fillWidth: true
                            spacing: Theme.spacingXS
                            visible: smsThreadCard.modelData.count
                                     > tabs.smsThreadShown(smsThreadCard.modelData.digits)

                            DankActionButton {
                                iconName: "expand_more"
                                onClicked: tabs.moreSmsThread(smsThreadCard.modelData.digits)
                            }
                            StyledText {
                                text: "显示更早的 "
                                      + Math.min(tabs.smsThreadPageSize,
                                                 smsThreadCard.modelData.count
                                                 - tabs.smsThreadShown(smsThreadCard.modelData.digits))
                                      + " 条"
                                color: Theme.surfaceVariantText
                                font.pixelSize: Theme.fontSizeSmall
                            }
                            Item { Layout.fillWidth: true }
                            DankActionButton {
                                iconName: "unfold_more"
                                onClicked: tabs.showAllSmsThread(smsThreadCard.modelData)
                            }
                            StyledText {
                                text: "共 " + smsThreadCard.modelData.count + " 条"
                                color: Theme.surfaceVariantText
                                font.pixelSize: Theme.fontSizeSmall
                            }
                        }
                    }
                }
            }
        }

        StyledText {
            Layout.fillWidth: true
            text: {
                if (!tabs.backend) return "";
                const keep = tabs.backend.smsRetentionDays > 0
                    ? ("保留 " + tabs.backend.smsRetentionDays + " 天")
                    : "不删除（永久保留）";
                const sim = tabs.backend.simLabel();
                return "收件箱 " + keep + (sim ? (" · 本机 " + sim) : "");
            }
            color: Theme.surfaceVariantText
            font.pixelSize: Theme.fontSizeSmall
            wrapMode: Text.WordWrap
        }

        StyledText {
            Layout.fillWidth: true
            visible: tabs.backend !== null && tabs.backend.mmsExportStatus.length > 0
            text: tabs.backend ? tabs.backend.mmsExportStatus : ""
            color: Theme.surfaceVariantText
            font.pixelSize: Theme.fontSizeSmall
            wrapMode: Text.WordWrap
        }

        StyledText {
            Layout.fillWidth: true
            visible: tabs.backend !== null && tabs.backend.smsExportStatus.length > 0
            text: tabs.backend ? tabs.backend.smsExportStatus : ""
            color: Theme.surfaceVariantText
            font.pixelSize: Theme.fontSizeSmall
            wrapMode: Text.WordWrap
        }

        // Obsidian archive controls.
        ColumnLayout {
            Layout.fillWidth: true
            spacing: Theme.spacingXS

            DankToggle {
                Layout.fillWidth: true
                text: "新消息弹出通知"
                checked: tabs.backend ? tabs.backend.notifyEnabled : false
                onToggled: value => {
                    if (!tabs.backend) return;
                    tabs.backend.notifyEnabled = value;
                    tabs.backend.saveSimSettings();
                }
            }
            DankToggle {
                Layout.fillWidth: true
                text: "同步到 Obsidian 笔记库"
                checked: tabs.backend ? tabs.backend.smsExportEnabled : false
                onToggled: value => {
                    if (!tabs.backend) return;
                    tabs.backend.smsExportEnabled = value;
                    tabs.backend.saveSimSettings();
                    if (value) tabs.backend.exportSmsToObsidian();
                }
            }
            RowLayout {
                Layout.fillWidth: true
                spacing: Theme.spacingS
                DankTextField {
                    Layout.fillWidth: true
                    placeholderText: "本机号码标签（区分是哪个号）"
                    text: tabs.backend ? (tabs.backend.simLabelOverride || tabs.backend.simLabel()) : ""
                    onTextChanged: {
                        if (!tabs.backend) return;
                        tabs.backend.simLabelOverride = text;
                        tabs.backend.saveSimSettings();
                    }
                }
                DankActionButton {
                    iconName: "sync"
                    onClicked: if (tabs.backend) tabs.backend.exportSmsToObsidian()
                }
            }
        }
    }

    // ── Tab 2: Phone ──────────────────────────────────────────────────────
    ColumnLayout {
        id: tabPhone
        Layout.fillWidth: true
        visible: tabs.activeTab === 2
        spacing: Theme.spacingS

        StyledText {
            Layout.fillWidth: true
            visible: tabs.backend !== null && !tabs.backend.voiceAvailable
            text: "当前网络注册不支持语音通话。"
            color: Theme.surfaceVariantText
            font.pixelSize: Theme.fontSizeSmall
            wrapMode: Text.WordWrap
        }

        Rectangle {
            id: callBanner
            Layout.fillWidth: true
            visible: tabs.backend !== null && tabs.backend.callState.length > 0
            Layout.preferredHeight: callBody.implicitHeight + Theme.spacingS * 2
            radius: Theme.cornerRadius
            color: Theme.primaryContainer

            ColumnLayout {
                id: callBody
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.top: parent.top
                anchors.margins: Theme.spacingS
                spacing: 0

                StyledText {
                    Layout.fillWidth: true
                    text: tabs.backend ? (tabs.backend.callNumber || "通话") : ""
                    color: Theme.surfaceText
                    font.weight: Font.Medium
                    wrapMode: Text.Wrap
                }
                StyledText {
                    Layout.fillWidth: true
                    text: tabs.backend ? tabs.callStateLabel(tabs.backend.callState) : ""
                    color: Theme.primary
                    font.pixelSize: Theme.fontSizeSmall
                }
            }
        }

        RowLayout {
            Layout.fillWidth: true
            spacing: Theme.spacingS

            DankTextField {
                Layout.fillWidth: true
                placeholderText: "号码"
                text: tabs.dialNumber
                onTextChanged: tabs.dialNumber = text
                Keys.onPressed: event => {
                    if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                        if (tabs.backend && tabs.dialNumber.length > 0) tabs.backend.dialCall(tabs.dialNumber);
                        event.accepted = true;
                    }
                }
            }

            DankButton {
                text: "拨打"
                iconName: "call"
                buttonHeight: 34
                enabled: tabs.backend && tabs.backend.callState.length === 0 && tabs.dialNumber.length > 0
                onClicked: if (tabs.backend) tabs.backend.dialCall(tabs.dialNumber)
            }
        }

        RowLayout {
            Layout.fillWidth: true
            spacing: Theme.spacingS

            DankButton {
                Layout.fillWidth: true
                text: "接听"
                iconName: "call_received"
                buttonHeight: 34
                enabled: tabs.backend && tabs.backend.callState === "ringing"
                onClicked: if (tabs.backend) tabs.backend.answerCall()
            }

            DankButton {
                Layout.fillWidth: true
                text: "挂断"
                iconName: "call_end"
                buttonHeight: 34
                backgroundColor: Theme.error
                textColor: Theme.onPrimary
                enabled: tabs.backend && tabs.backend.callState.length > 0
                onClicked: if (tabs.backend) tabs.backend.hangUp()
            }
        }

        DankButton {
            Layout.fillWidth: true
            text: "清除"
            iconName: "call_end"
            buttonHeight: 30
            enabled: tabs.backend && tabs.backend.callState.length > 0
            onClicked: {
                if (!tabs.backend) return;
                tabs.backend.callState = "";
                tabs.backend.callNumber = "";
                tabs.backend.callPath = "";
            }
        }
    }

    // ── Tab 3: GPS ────────────────────────────────────────────────────────
    ColumnLayout {
        id: tabGps
        Layout.fillWidth: true
        visible: tabs.activeTab === 3
        spacing: Theme.spacingS

        RowLayout {
            Layout.fillWidth: true
            spacing: Theme.spacingS

            DankButton {
                Layout.fillWidth: true
                text: tabs.backend && tabs.backend.gpsEnabled ? "停止定位" : "启动定位"
                iconName: tabs.backend && tabs.backend.gpsEnabled ? "location_off" : "my_location"
                buttonHeight: 34
                onClicked: if (tabs.backend) tabs.backend.enableLocation(!tabs.backend.gpsEnabled)
            }

            DankActionButton {
                iconName: "refresh"
                enabled: tabs.backend && tabs.backend.gpsEnabled
                onClicked: if (tabs.backend) tabs.backend.refreshLocation()
            }
        }

        GridLayout {
            Layout.fillWidth: true
            columns: 2
            columnSpacing: Theme.spacingM
            rowSpacing: Theme.spacingXS

            StyledText { text: "纬度"; color: Theme.surfaceVariantText; font.pixelSize: Theme.fontSizeSmall }
            StyledText {
                Layout.fillWidth: true
                text: tabs.backend && tabs.backend.gpsFixAvailable ? tabs.backend.latitude.toFixed(6) : "--"
                color: Theme.surfaceText
                font.pixelSize: Theme.fontSizeSmall
            }

            StyledText { text: "经度"; color: Theme.surfaceVariantText; font.pixelSize: Theme.fontSizeSmall }
            StyledText {
                Layout.fillWidth: true
                text: tabs.backend && tabs.backend.gpsFixAvailable ? tabs.backend.longitude.toFixed(6) : "--"
                color: Theme.surfaceText
                font.pixelSize: Theme.fontSizeSmall
            }

            StyledText { text: "海拔"; color: Theme.surfaceVariantText; font.pixelSize: Theme.fontSizeSmall }
            StyledText {
                Layout.fillWidth: true
                text: tabs.backend && tabs.backend.gpsFixAvailable ? (tabs.backend.altitude.toFixed(1) + " m") : "--"
                color: Theme.surfaceText
                font.pixelSize: Theme.fontSizeSmall
            }

            StyledText { text: "UTC 时间"; color: Theme.surfaceVariantText; font.pixelSize: Theme.fontSizeSmall }
            StyledText {
                Layout.fillWidth: true
                text: tabs.backend && tabs.backend.gpsTimestamp.length > 0 ? tabs.backend.gpsTimestamp : "--"
                color: Theme.surfaceText
                font.pixelSize: Theme.fontSizeSmall
            }
        }

        StyledText {
            Layout.fillWidth: true
            visible: tabs.backend !== null && tabs.backend.gpsEnabled && !tabs.backend.gpsFixAvailable
            text: "正在搜星 —— 需要天空开阔无遮挡。"
            color: Theme.surfaceVariantText
            font.pixelSize: Theme.fontSizeSmall
            wrapMode: Text.WordWrap
        }
    }

    Timer {
        id: copyReset
        interval: 1600
        repeat: false
        onTriggered: tabs.copiedKey = ""
    }
}
