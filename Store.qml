import QtQuick
import Quickshell
import Quickshell.Io
import qs.Common
import qs.Modules.Plugins

PluginComponent {
    id: backendStore

    // ── 可移植路径 ────────────────────────────────────────────────
    // 公开发布前必须去掉本机硬编码：不同机器 HOME 不同，写死会让彩信、
    // 通知、归档、ModemManager 自愈在别人机器上全部静默失败。
    // SIMNETWORK_HELPER_DIR / SIMNETWORK_STATE_DIR 可用环境变量覆盖。
    readonly property string homeDir: Quickshell.env("HOME") || "/home"
    readonly property string helperDir: Quickshell.env("SIMNETWORK_HELPER_DIR") || (homeDir + "/.local/bin")
    readonly property string stateDir: Quickshell.env("SIMNETWORK_STATE_DIR") || (homeDir + "/.local/state/simNetwork")

    // ── 后台开销的三个开关 ─────────────────────────────────────────
    // hasModem           没有猫就整套停手，USB 拔了不再空转
    // uiVisible          只有 popout / 控制中心详情真的开着才做重量级刷新
    // heal/mmsExporter…  extras 没装就不跑看门狗和 mms-export，否则每次都是一个
    //                    必然失败的子进程（没装就别跑）
    readonly property bool hasModem: modems.length > 0
    property int uiUsers: 0
    readonly property bool uiVisible: uiUsers > 0
    property bool healHelperInstalled: false
    property bool mmsExporterInstalled: false

    // 面板/设置页真的打开了才算一次"用户动作"——IP 模式改在这一刻读，
    // 平时不轮询：该值只可能由 setIpMode 或外部改动引起。
    function acquireUi() {
        uiUsers = uiUsers + 1;
        refreshIpMode();                 // IP 模式：用户动作才读
        if (!refreshing && !busy) refresh();   // 打开面板即把 APN 列表/WWAN 开关补上
    }
    function releaseUi() { uiUsers = Math.max(0, uiUsers - 1) }

    FileView {
        id: healHelperProbe
        path: backendStore.helperDir + "/eg25-mm-heal"
        printErrors: false
        onLoaded: backendStore.healHelperInstalled = true
        onLoadFailed: backendStore.healHelperInstalled = false
    }
    FileView {
        id: mmsExporterProbe
        path: backendStore.helperDir + "/mms-export"
        printErrors: false
        onLoaded: backendStore.mmsExporterInstalled = true
        onLoadFailed: backendStore.mmsExporterInstalled = false
    }

    property string commandPrefix: "simNetwork"
    property var modems: []
    property var profiles: []
    property var activeByDevice: ({})
    property bool wwanEnabled: false
    property bool wwanKnown: false
    property bool refreshing: false
    property bool busy: false
    property string pendingAction: ""
    property string pendingUuid: ""
    property string errorMessage: ""
    property string statusMessage: ""

    // ── Data usage tracking ──────────────────────────────────────────────
    property string statsInterface: "wwp0s20f0u1i4"

    // WAN addressing. IPv4 here is the carrier's private/CGNAT address, not what
    // the internet sees — publicIPv4 is the carrier NAT egress, fetched on demand.
    property string wanIPv4: ""
    property string wanIPv6: ""
    property string wanGateway: ""
    property string publicIPv4: ""
    property string publicIPv6: ""
    property string publicIPStatus: ""

    // Which IP stack the 4G bearer asks for. NetworkManager keeps this in the
    // connection profile, so it survives reconnects — the carrier default is
    // dual stack.
    property string wanConnUuid: ""
    property string ipMode: ""            // "both" | "v4" | "v6"
    property string ipModeStatus: ""
    property int rxBytes: 0
    property int txBytes: 0
    property real rxRate: 0       // bytes/s since last sample
    property real txRate: 0
    property int sessionRxBytes: 0
    property int sessionTxBytes: 0
    property real sessionRxRate: 0
    property real sessionTxRate: 0
    property int prevRxBytes: 0
    property int prevTxBytes: 0
    property bool dataUsageAvailable: false

    // ── SMS state ────────────────────────────────────────────────────────
    property var smsMessages: []        // [{path, number, text, timestamp, read}]
    property int smsUnreadCount: 0
    property bool smsSending: false
    property string smsStatusMessage: ""

    // ── Voice call state ─────────────────────────────────────────────────
    property string callState: ""           // "", "dialing", "ringing", "active", "held"
    property string callNumber: ""
    property string callPath: ""
    property bool voiceAvailable: false

    // ── GPS / Location state ─────────────────────────────────────────────
    property real latitude: 0
    property real longitude: 0
    property real altitude: 0
    property real gpsSpeed: 0
    property real gpsAccuracy: 0
    property string gpsTimestamp: ""
    property bool gpsEnabled: false
    property bool gpsFixAvailable: false

    signal refreshed
    signal operationCompleted(bool success, string operation, string uuid)
    signal smsListUpdated
    signal locationUpdated

    function splitEscaped(text, separator) {
        const values = [];
        let value = "";
        let escaped = false;
        for (let i = 0; i < text.length; ++i) {
            const ch = text[i];
            if (escaped) {
                value += ch;
                escaped = false;
            } else if (ch === "\\") {
                escaped = true;
            } else if (ch === separator) {
                values.push(value);
                value = "";
            } else {
                value += ch;
            }
        }
        values.push(value);
        return values;
    }

    function clean(value) {
        const text = String(value === undefined || value === null ? "" : value);
        return text === "--" ? "" : text;
    }

    // ModemManager 返回的时间戳时区缺分钟（"...T23:00:28+08"），JS Date.parse 解析会失败。
    // 统一补成 "+08:00" 再解析，否则通知去重的时间判断会失效。
    function normalizeStamp(value) {
        let t = String(value === undefined || value === null ? "" : value).trim();
        if (!t) return "";
        t = t.replace(/([+-]\d{2})$/, "$1:00");
        return t;
    }

    function parseStamp(value) {
        const t = backendStore.normalizeStamp(value);
        if (!t) return NaN;
        return Date.parse(t);
    }

    function asBool(value, fallback) {
        const text = clean(value).toLowerCase();
        if (["yes", "true", "on", "1"].includes(text)) return true;
        if (["no", "false", "off", "0"].includes(text)) return false;
        return fallback;
    }

    function modemId(path) {
        const parts = String(path).split("/");
        return parts[parts.length - 1];
    }

    function modemLabel(modem) {
        if (!modem) return "";
        return (modem.manufacturer ? modem.manufacturer + " " : "") + modem.model;
    }

    function activeUuidFor(interfaceName) {
        return activeByDevice[interfaceName] || "";
    }

    function isActive(uuid, interfaceName) {
        return !!uuid && activeUuidFor(interfaceName) === uuid;
    }

    function formatBytes(bytes) {
        if (bytes < 1024) return bytes + " B";
        if (bytes < 1048576) return (bytes / 1024).toFixed(1) + " KB";
        if (bytes < 1073741824) return (bytes / 1048576).toFixed(1) + " MB";
        return (bytes / 1073741824).toFixed(2) + " GB";
    }

    function formatRate(bytesPerSec) {
        if (bytesPerSec < 1024) return bytesPerSec.toFixed(0) + " B/s";
        if (bytesPerSec < 1048576) return (bytesPerSec / 1024).toFixed(1) + " KB/s";
        return (bytesPerSec / 1048576).toFixed(1) + " MB/s";
    }

    // ── Main refresh ─────────────────────────────────────────────────────

    function refresh() {
        if (refreshing || busy) return;
        refreshing = true;
        errorMessage = "";
        readDataUsage();
        if (gpsEnabled) refreshLocation();
        loadModems();
        if (uiVisible) {
            loadRadio();
            loadProfiles();
        } else {
            // 面板关着时 APN 列表和 WWAN 开关状态没人看：这两样
            //（2 个 nmcli）改到打开面板那一刻才查。
            finishPart("profiles");
        }
    }

    // 只刷流量计数器：5 秒一次也不会给 nmcli/mmcli 添负担。
    function refreshCounters() {
        if (refreshing || busy) return;
        readDataUsage();
    }

    function loadRadio() {
        Proc.runCommand(commandPrefix + ".radio", ["env", "LC_ALL=C", "nmcli", "--terse", "--fields", "WWAN", "radio"], (output, code) => {
            if (code === 0) {
                backendStore.wwanEnabled = output.trim().toLowerCase() === "enabled";
                backendStore.wwanKnown = true;
                backendStore.refreshed();
            }
        });
    }

    function setRadio(enabled) {
        if (busy) return;
        busy = true; pendingAction = "radio"; pendingUuid = ""; errorMessage = "";
        Proc.runCommand(commandPrefix + ".radio.set", ["env", "LC_ALL=C", "nmcli", "radio", "wwan", enabled ? "on" : "off"], (output, code) => {
            if (code === 0) { backendStore.wwanEnabled = enabled; backendStore.wwanKnown = true; backendStore.refreshed(); }
            backendStore.finish(code === 0, "radio", "", code === 0 ? (enabled ? "WWAN enabled" : "WWAN disabled") : output);
        });
    }

    property bool modemLoadDone: false
    property bool profileLoadDone: false

    function finishPart(part) {
        if (part === "modems") modemLoadDone = true;
        if (part === "profiles") profileLoadDone = true;
        if (modemLoadDone && profileLoadDone) {
            refreshing = false;
            modemLoadDone = false;
            profileLoadDone = false;
            refreshed();
        }
    }

    function loadModems() {
        Proc.runCommand(commandPrefix + ".modems", ["mmcli", "--list-modems", "--output-json"], (output, code) => {
            if (code !== 0) {
                backendStore.errorMessage = "Unable to read ModemManager devices: " + output.trim();
                backendStore.finishPart("modems");
                return;
            }
            let paths = [];
            try { paths = JSON.parse(output)["modem-list"] || []; }
            catch (error) { backendStore.errorMessage = "Invalid response from ModemManager"; }
            if (!paths.length) {
                backendStore.modems = [];
                backendStore.refreshed();
                backendStore.finishPart("modems");
                return;
            }
            const found = [];
            let pending = paths.length;
            paths.forEach((path) => {
                const id = backendStore.modemId(path);
                Proc.runCommand(backendStore.commandPrefix + ".modem." + id, ["mmcli", "--modem", id, "--output-json"], (info, infoCode) => {
                    if (infoCode === 0) {
                        try {
                            const response = JSON.parse(info).modem || {};
                            const generic = response.generic || {};
                            const cellular = response["3gpp"] || {};
                            const quality = generic["signal-quality"] || {};
                            const access = generic["access-technologies"] || [];
                            const ports = generic.ports || [];
                            let netIface = "";
                            for (let pi = 0; pi < ports.length; pi++) {
                                if (String(ports[pi]).indexOf("net") !== -1) {
                                    netIface = String(ports[pi]).split(" ")[0];
                                    break;
                                }
                            }
                            found.push({
                                id: String(id),
                                stableId: clean(generic["device-identifier"] || generic["equipment-identifier"] || generic.device || id),
                                manufacturer: clean(generic.manufacturer),
                                model: clean(generic.model) || ("Modem " + id),
                                interfaceName: clean(generic["primary-port"]),
                                netInterface: netIface,
                                ownNumbers: clean((generic["own-numbers"] || [])[0] || ""),
                                simPath: clean(generic.sim || ""),
                                state: clean(generic.state) || "unknown",
                                operatorName: clean(cellular["operator-name"]),
                                signal: Number(quality.value || 0),
                                access: Array.isArray(access) ? access.join(", ") : clean(access),
                                mmBearerPath: clean(generic["bearers"] && generic["bearers"][0] ? generic["bearers"][0] : ""),
                                hasVoice: Array.isArray(access) && (access.includes("lte") || access.includes("umts") || access.includes("gsm")),
                                hasAccess: Array.isArray(access) && access.length > 0
                            });
                        } catch (error) { console.warn("[SimNetwork] invalid modem JSON", id); }
                    }
                    if (--pending === 0) {
                        found.sort((a, b) => Number(a.id) - Number(b.id));
                        backendStore.modems = found;
                        if (found.length && found[0].simPath) backendStore.loadSimIdentity(found[0].simPath);
                        backendStore.refreshed();
                        backendStore.finishPart("modems");
                    }
                });
            });
        });
    }

    function loadProfiles() {
        Proc.runCommand(commandPrefix + ".profiles", ["env", "LC_ALL=C", "nmcli", "--terse", "--escape", "yes", "--get-values", "UUID,TYPE", "connection", "show"], (output, code) => {
            if (code !== 0) {
                backendStore.errorMessage = "Unable to read NetworkManager profiles: " + output.trim();
                backendStore.loadActive();
                return;
            }
            const uuids = [];
            output.split("\n").forEach((line) => {
                const values = backendStore.splitEscaped(line, ":");
                if (values.length >= 2 && values[1] === "gsm") uuids.push(values[0]);
            });
            if (!uuids.length) {
                backendStore.profiles = [];
                backendStore.refreshed();
                backendStore.loadActive();
                return;
            }
            const found = [];
            let pending = uuids.length;
            uuids.forEach((uuid) => backendStore.readProfile(uuid, (profile) => {
                if (profile) found.push(profile);
                if (--pending === 0) {
                    found.sort((a, b) => a.name.localeCompare(b.name));
                    backendStore.profiles = found;
                    backendStore.refreshed();
                    backendStore.loadActive();
                }
            }));
        });
    }

    function readProfile(uuid, done) {
        const fields = ["connection.id", "connection.uuid", "connection.autoconnect", "connection.autoconnect-priority", "connection.metered", "gsm.auto-config", "gsm.apn", "gsm.username", "gsm.home-only", "gsm.network-id", "gsm.mtu"];
        Proc.runCommand(commandPrefix + ".profile." + uuid, ["env", "LC_ALL=C", "nmcli", "--terse", "--escape", "yes", "--get-values", fields.join(","), "connection", "show", "uuid", uuid], (output, code) => {
            if (code !== 0) { done(null); return; }
            const values = output.replace(/\r/g, "").split("\n");
            if (values.length && values[values.length - 1] === "") values.pop();
            while (values.length < fields.length) values.push("");
            const mtu = clean(values[10]);
            done({
                name: clean(values[0]), uuid: clean(values[1]) || uuid,
                autoconnect: asBool(values[2], true), autoconnectPriority: Number(values[3] || 0),
                metered: clean(values[4]) || "unknown", autoConfig: asBool(values[5], false),
                apn: clean(values[6]), username: clean(values[7]),
                allowRoaming: !asBool(values[8], false), networkId: clean(values[9]), mtu: mtu === "auto" ? "" : mtu
            });
        });
    }

    function loadActive() {
        Proc.runCommand(commandPrefix + ".active", ["env", "LC_ALL=C", "nmcli", "--terse", "--escape", "yes", "--get-values", "UUID,TYPE,DEVICE", "connection", "show", "--active"], (output, code) => {
            const active = {};
            if (code === 0) output.split("\n").forEach((line) => {
                const values = backendStore.splitEscaped(line, ":");
                if (values.length >= 3 && values[1] === "gsm" && values[2]) active[values[2]] = values[0];
            });
            backendStore.activeByDevice = active;
            backendStore.refreshed();
            backendStore.finishPart("profiles");
        });
    }

    function validationError(profile) {
        if (!String(profile.name || "").trim()) return "Profile name is required";
        if (!profile.autoConfig && !String(profile.apn || "").trim()) return "APN is required";
        if (profile.networkId && !/^\d{5,6}$/.test(profile.networkId)) return "Network ID must contain 5 or 6 digits";
        if (profile.mtu && (!/^\d+$/.test(profile.mtu) || Number(profile.mtu) <= 0)) return "MTU must be a positive integer";
        return "";
    }

    function addArg(args, key, value) { args.push(key); args.push(String(value)); }

    function modifyArgs(uuid, profile) {
        const args = ["env", "LC_ALL=C", "nmcli", "connection", "modify", "uuid", uuid];
        addArg(args, "connection.id", profile.name.trim());
        addArg(args, "connection.autoconnect", profile.autoconnect ? "yes" : "no");
        addArg(args, "connection.autoconnect-priority", Number(profile.autoconnectPriority || 0));
        addArg(args, "connection.metered", profile.metered || "unknown");
        addArg(args, "gsm.auto-config", profile.autoConfig ? "yes" : "no");
        addArg(args, "gsm.apn", profile.autoConfig ? "" : String(profile.apn || "").trim());
        addArg(args, "gsm.username", profile.username || "");
        addArg(args, "gsm.home-only", profile.allowRoaming ? "no" : "yes");
        addArg(args, "gsm.network-id", profile.networkId || "");
        addArg(args, "gsm.mtu", profile.mtu || "0");
        if (profile.passwordChanged) addArg(args, "gsm.password", profile.password || "");
        return args;
    }

    function saveProfile(profile) {
        const error = validationError(profile);
        if (busy || error) { if (error) errorMessage = error; return; }
        busy = true; pendingAction = "save"; pendingUuid = profile.uuid || ""; errorMessage = "";
        checkNameAvailable(profile.name.trim(), profile.uuid || "", (available, details) => {
            if (!available) { backendStore.finish(false, "save", profile.uuid || "", details); return; }
            if (profile.uuid) { backendStore.runModify(profile.uuid, profile, false); return; }
            backendStore.createProfile(profile);
        });
    }

    function checkNameAvailable(name, ownUuid, done) {
        Proc.runCommand(commandPrefix + ".checkName", ["env", "LC_ALL=C", "nmcli", "--terse", "--escape", "yes", "--get-values", "NAME,UUID,TYPE", "connection", "show"], (output, code) => {
            if (code !== 0) { done(false, "Unable to check existing profile names: " + output.trim()); return; }
            let duplicate = false;
            output.split("\n").forEach((line) => {
                const values = backendStore.splitEscaped(line, ":");
                if (values.length >= 3 && values[0] === name && values[1] !== ownUuid && values[2] === "gsm") duplicate = true;
            });
            done(!duplicate, duplicate ? "A mobile profile named '" + name + "' already exists" : "");
        });
    }

    function createProfile(profile) {
        const args = ["env", "LC_ALL=C", "nmcli", "connection", "add", "type", "gsm", "ifname", "*", "con-name", profile.name.trim()];
        if (!profile.autoConfig) { args.push("apn"); args.push(String(profile.apn || "").trim()); }
        Proc.runCommand(commandPrefix + ".create", args, (output, code) => {
            if (code !== 0) { backendStore.finish(false, "save", "", output); return; }
            backendStore.lookupCreatedUuid(profile);
        });
    }

    function lookupCreatedUuid(profile) {
        Proc.runCommand(commandPrefix + ".createdUuid", ["env", "LC_ALL=C", "nmcli", "--get-values", "connection.uuid", "connection", "show", "id", profile.name.trim()], (output, code) => {
            const uuid = output.trim();
            if (code !== 0 || !uuid) {
                backendStore.finish(false, "save", "", "Profile was created, but NetworkManager did not return its UUID: " + output.trim());
                return;
            }
            backendStore.pendingUuid = uuid;
            backendStore.runModify(uuid, profile, true);
        });
    }

    function runModify(uuid, profile, created) {
        Proc.runCommand(commandPrefix + ".modify." + uuid, modifyArgs(uuid, profile), (output, code) => {
            backendStore.finish(code === 0, "save", uuid, code === 0 ? "Profile saved" : (created ? "Profile created, but update failed: " : "") + output);
        });
    }

    function activate(uuid, interfaceName) {
        if (busy || !interfaceName) return;
        busy = true; pendingAction = "connect"; pendingUuid = uuid; errorMessage = "";
        Proc.runCommand(commandPrefix + ".connect." + uuid, ["env", "LC_ALL=C", "nmcli", "connection", "up", "uuid", uuid, "ifname", interfaceName], (output, code) => backendStore.finish(code === 0, "connect", uuid, code === 0 ? "Connected" : output));
    }

    function disconnect(interfaceName, uuid) {
        if (busy || !interfaceName) return;
        busy = true; pendingAction = "disconnect"; pendingUuid = uuid || ""; errorMessage = "";
        Proc.runCommand(commandPrefix + ".disconnect." + interfaceName, ["env", "LC_ALL=C", "nmcli", "device", "disconnect", interfaceName], (output, code) => backendStore.finish(code === 0, "disconnect", uuid || "", code === 0 ? "Disconnected" : output));
    }

    function deleteProfile(uuid) {
        if (busy) return;
        busy = true; pendingAction = "delete"; pendingUuid = uuid; errorMessage = "";
        Proc.runCommand(commandPrefix + ".delete." + uuid, ["env", "LC_ALL=C", "nmcli", "connection", "delete", "uuid", uuid], (output, code) => backendStore.finish(code === 0, "delete", uuid, code === 0 ? "Profile deleted" : output));
    }

    function finish(success, action, uuid, details) {
        busy = false;
        pendingAction = "";
        pendingUuid = "";
        errorMessage = success ? "" : String(details || "NetworkManager operation failed").trim();
        statusMessage = success ? String(details || "Done").trim() : "";
        operationCompleted(success, action, uuid);
        refreshDelay.restart();
    }

    property Timer refreshDelay: Timer { interval: 600; onTriggered: backendStore.refresh() }

    Component.onCompleted: {
        console.info("[SimNetwork] daemon store started");
        backendStore.loadUsageHistory();
        backendStore.loadSmsHistory();
        backendStore.loadReadKeys();
        backendStore.loadSimSettings();
        backendStore.loadQuota();
        backendStore.probeObsidian();
        backendStore.loadMmsMessages();
        backendStore.notifySeedTimer.start();
        backendStore.messagePollTimer.start();
        backendStore.refresh();
    }

    // 首次加载 10 秒后，把已有消息全部标记为"已通知"——否则一重启就弹一堆旧消息。
    property Timer notifySeedTimer: Timer {
        interval: 10000
        repeat: false
        onTriggered: backendStore.seedNotified()
    }

    // 新消息轮询：短信走 mmcli（loadSmsList），彩信走 mms-export；
    // 语音能力也只在这里查（它不会几秒一变）。
    property Timer messagePollTimer: Timer {
        interval: backendStore.uiVisible ? 30000 : 60000
        repeat: true
        onTriggered: {
            if (!backendStore.hasModem) return;
            backendStore.loadSmsList();
            // mms-export 是 Python 进程，装了才跑；没装就别每分钟白起一次
            if (backendStore.mmsExporterInstalled) backendStore.loadMmsMessages();
        }
    }

    Component.onDestruction: backendStore.saveUsageHistory()

    // 流量计数走 FileView 直读 /sys（0 个子进程），有猫才跑。
    Timer {
        id: counterTimer
        interval: 8000
        repeat: true
        running: backendStore.hasModem
        onTriggered: backendStore.refreshCounters()
    }

    // 全量刷新是重量级的（每个 profile、每个 modem 各起一个 nmcli/mmcli）：
    // 面板开着才 15 秒一刷，关掉降到 60 秒，只够顶栏小组件显示信号/运营商。
    Timer {
        interval: backendStore.uiVisible ? 15000 : 60000
        repeat: true
        running: backendStore.hasModem
        onTriggered: backendStore.refresh()
    }

    // The carrier reassigns the address on every reconnect, so re-read it —
    // but only while the traffic page can actually be seen. IP mode is not
    // polled at all: it only changes through setIpMode (and on first open),
    // so a 60 s nmcli poll was pure overhead.
    Timer {
        interval: 20000
        repeat: true
        running: backendStore.hasModem && backendStore.uiVisible
        triggeredOnStart: true
        onTriggered: backendStore.refreshWanAddresses();
    }

    // Flush the usage ledger and check the monthly carrier quota.
    Timer {
        interval: 60000
        repeat: true
        running: true
        onTriggered: {
            backendStore.saveUsageHistory();
            backendStore.maybeAutoQuotaQuery();
        }
    }

    // ═════════════════════════════════════════════════════════════════════
    // DATA USAGE TRACKING
    //
    // The kernel keeps per-interface byte counters that reset on reboot or
    // interface flap, so we sample them and accumulate deltas into a
    // per-day ledger persisted through the DMS plugin state API.
    // Retention: 30 days, matching the Network Indicator plugin convention.
    // ═════════════════════════════════════════════════════════════════════

    property var usageDays: ({})      // "yyyy-MM-dd" -> { rx, tx }
    property int retentionDays: 30
    property real todayRx: 0
    property real todayTx: 0
    property real _sampleRx: -1       // last raw kernel counter
    property real _sampleTx: -1
    property string _ledgerKey: ""
    property real _pendingRx: 0       // bytes not yet flushed to state
    property real _pendingTx: 0
    property real lifetimeRx: 0       // monotonic; never pruned, used as quota baseline
    property real lifetimeTx: 0

    function usageDayKey() {
        return Qt.formatDate(new Date(), "yyyy-MM-dd");
    }

    function loadUsageHistory() {
        if (!pluginService || !pluginId) return;
        let days = {};
        try { days = JSON.parse(JSON.stringify(pluginService.loadPluginState(pluginId, "usageDays", {}) || {})); }
        catch (e) { days = {}; }
        backendStore.usageDays = days;
        backendStore._sampleRx = pluginService.loadPluginState(pluginId, "lastSampleRx", -1);
        backendStore._sampleTx = pluginService.loadPluginState(pluginId, "lastSampleTx", -1);
        backendStore.lifetimeRx = pluginService.loadPluginState(pluginId, "lifetimeRx", 0) || 0;
        backendStore.lifetimeTx = pluginService.loadPluginState(pluginId, "lifetimeTx", 0) || 0;
        backendStore._ledgerKey = backendStore.usageDayKey();
        const today = backendStore.usageDays[backendStore._ledgerKey] || { rx: 0, tx: 0 };
        backendStore.todayRx = today.rx || 0;
        backendStore.todayTx = today.tx || 0;
    }

    function pruneOldDays() {
        const cutoff = new Date();
        cutoff.setDate(cutoff.getDate() - backendStore.retentionDays);
        const cutoffStr = Qt.formatDate(cutoff, "yyyy-MM-dd");
        const keys = Object.keys(backendStore.usageDays);
        for (let i = 0; i < keys.length; i++) {
            if (keys[i] < cutoffStr) delete backendStore.usageDays[keys[i]];
        }
    }

    function saveUsageHistory() {
        if (!pluginService || !pluginId) return;
        backendStore._ledgerKey = backendStore.usageDayKey();
        backendStore.usageDays[backendStore._ledgerKey] = {
            rx: Math.round(backendStore.todayRx),
            tx: Math.round(backendStore.todayTx)
        };
        backendStore.pruneOldDays();
        pluginService.savePluginState(pluginId, "usageDays", backendStore.usageDays);
        pluginService.savePluginState(pluginId, "lastSampleRx", backendStore._sampleRx);
        pluginService.savePluginState(pluginId, "lastSampleTx", backendStore._sampleTx);
        pluginService.savePluginState(pluginId, "lifetimeRx", Math.round(backendStore.lifetimeRx));
        pluginService.savePluginState(pluginId, "lifetimeTx", Math.round(backendStore.lifetimeTx));
        backendStore._pendingRx = 0;
        backendStore._pendingTx = 0;
    }

    // Newest first, `count` entries (gaps filled with zeroes).
    function recentUsageDays(count) {
        const out = [];
        const d = new Date();
        for (let i = 0; i < count; i++) {
            const k = Qt.formatDate(d, "yyyy-MM-dd");
            const day = backendStore.usageDays[k] || { rx: 0, tx: 0 };
            out.push({ key: k, rx: day.rx || 0, tx: day.tx || 0 });
            d.setDate(d.getDate() - 1);
        }
        return out;
    }

    function monthUsage() {
        const prefix = Qt.formatDate(new Date(), "yyyy-MM");
        let rx = 0, tx = 0;
        const keys = Object.keys(backendStore.usageDays);
        for (let i = 0; i < keys.length; i++) {
            if (keys[i].indexOf(prefix) !== 0) continue;
            rx += backendStore.usageDays[keys[i]].rx || 0;
            tx += backendStore.usageDays[keys[i]].tx || 0;
        }
        // Include the live delta for today so the figure tracks in real time.
        return { rx: rx, tx: tx };
    }

    // "ip -j" gives JSON, which avoids parsing the human-readable table.
    function refreshWanAddresses() {
        const iface = backendStore.statsInterface;
        if (!iface || iface.length === 0) return;

        Proc.runCommand(backendStore.commandPrefix + ".ip.addr",
            ["ip", "-j", "addr", "show", "dev", iface], (output, code) => {
            if (code !== 0 || !output) {
                backendStore.wanIPv4 = "";
                backendStore.wanIPv6 = "";
                return;
            }
            let v4 = "", v6 = "";
            try {
                const info = (JSON.parse(output)[0] || {}).addr_info || [];
                for (let i = 0; i < info.length; i++) {
                    const a = info[i];
                    if (a.family === "inet" && !v4)
                        v4 = a.local + "/" + a.prefixlen;
                    else if (a.family === "inet6" && !v6 && a.scope === "global")
                        v6 = a.local;
                }
            } catch (e) { return; }
            backendStore.wanIPv4 = v4;
            backendStore.wanIPv6 = v6;
        });

        Proc.runCommand(backendStore.commandPrefix + ".ip.gw",
            ["ip", "-j", "route", "show", "default", "dev", iface], (output, code) => {
            if (code !== 0 || !output) { backendStore.wanGateway = ""; return; }
            try {
                const r = JSON.parse(output);
                backendStore.wanGateway = (r[0] && r[0].gateway) || "";
            } catch (e) { backendStore.wanGateway = ""; }
        });
    }

    // Bound to the WWAN interface so a VPN / the wifi default route cannot
    // answer instead, and queried per family.
    //
    // ipinfo.io has no AAAA record, so "curl -6 https://ipinfo.io/ip" silently
    // returns nothing — the service itself is IPv4-only. api64.ipify.org serves
    // both families, which is why it is used here.
    // On demand only: these are outbound HTTP requests.
    function queryPublicAddresses() {
        const iface = backendStore.statsInterface;
        if (!iface || iface.length === 0) return;
        const base = backendStore.commandPrefix;
        backendStore.publicIPv4 = "";
        backendStore.publicIPv6 = "";
        backendStore.publicIPStatus = "查询中…";

        // Sequential rather than parallel: one status line at the end, and no
        // nested helper functions to worry about in QML's JS.
        Proc.runCommand(base + ".ip.pub.v4",
            ["curl", "-4", "-s", "--max-time", "8", "--interface", iface,
             "https://api64.ipify.org"], (o4, c4) => {
            const v4 = String(o4 || "").trim();
            if (c4 === 0 && v4.length > 0 && v4.length < 64 && v4.indexOf(" ") === -1)
                backendStore.publicIPv4 = v4;
            Proc.runCommand(base + ".ip.pub.v6",
                ["curl", "-6", "-s", "--max-time", "8", "--interface", iface,
                 "https://api64.ipify.org"], (o6, c6) => {
                const v6 = String(o6 || "").trim();
                if (c6 === 0 && v6.length > 0 && v6.length < 64 && v6.indexOf(" ") === -1)
                    backendStore.publicIPv6 = v6;
                backendStore.publicIPStatus = (backendStore.publicIPv4 || backendStore.publicIPv6)
                    ? "" : "查询失败（走了代理或被拦截？）";
            });
        });
    }

    // The connection can be renamed, so find it by type rather than by name.
    function refreshIpMode() {
        Proc.runCommand(backendStore.commandPrefix + ".ipmode.find",
            ["nmcli", "-t", "-f", "UUID,TYPE,ACTIVE", "connection", "show"], (output, code) => {
            if (code !== 0 || !output) return;
            let uuid = "", fallback = "";
            const lines = String(output).split("\n");
            for (let i = 0; i < lines.length; i++) {
                const f = lines[i].split(":");
                if (f.length < 3 || f[1] !== "gsm") continue;
                if (f[2] === "yes") { uuid = f[0]; break; }
                if (!fallback) fallback = f[0];
            }
            uuid = uuid || fallback;
            if (!uuid) return;
            backendStore.wanConnUuid = uuid;

            Proc.runCommand(backendStore.commandPrefix + ".ipmode.read",
                ["nmcli", "-g", "ipv4.method,ipv6.method", "connection", "show", uuid],
                (out, code2) => {
                if (code2 !== 0 || !out) return;
                const parts = String(out).trim().split("\n");
                const v4 = (parts[0] || "").trim();
                const v6 = (parts[1] || "").trim();
                const v4off = (v4 === "disabled" || v4 === "ignore");
                const v6off = (v6 === "disabled" || v6 === "ignore");
                backendStore.ipMode = v4off ? "v6" : (v6off ? "v4" : "both");
            });
        });
    }

    // Switching re-establishes the bearer, so the link drops for a few seconds.
    function setIpMode(mode) {
        const uuid = backendStore.wanConnUuid;
        if (!uuid) { backendStore.ipModeStatus = "还没识别到 4G 连接"; return; }
        let v4 = "auto", v6 = "auto";
        if (mode === "v4") v6 = "ignore";
        else if (mode === "v6") v4 = "disabled";
        backendStore.ipModeStatus = "正在切换…";
        Proc.runCommand(backendStore.commandPrefix + ".ipmode.set",
            ["nmcli", "connection", "modify", uuid, "ipv4.method", v4, "ipv6.method", v6],
            (o1, c1) => {
            if (c1 !== 0) {
                backendStore.ipModeStatus = "修改失败：" + String(o1 || "").trim().slice(0, 70);
                return;
            }
            Proc.runCommand(backendStore.commandPrefix + ".ipmode.up",
                ["nmcli", "connection", "up", uuid], (o2, c2) => {
                if (c2 !== 0) {
                    backendStore.ipModeStatus = "重连失败：" + String(o2 || "").trim().slice(0, 70);
                    return;
                }
                backendStore.ipModeStatus = "已切换并重连";
                backendStore.refreshIpMode();
                backendStore.refreshWanAddresses();
                backendStore.refresh();
            });
        });
    }

    // FileView 直读 /sys 计数器（原先每 5 秒派 2 个 cat，
    // 一分钟 24 个进程）。两个文件都读到才结算，否则速率会一格有一格没有。
    FileView {
        id: counterRxFile
        path: "/sys/class/net/" + backendStore.statsInterface + "/statistics/rx_bytes"
        printErrors: false
        onLoaded: { backendStore._rxFresh = true; backendStore.adoptCounters(); }
        onLoadFailed: backendStore.dataUsageAvailable = false
    }
    FileView {
        id: counterTxFile
        path: "/sys/class/net/" + backendStore.statsInterface + "/statistics/tx_bytes"
        printErrors: false
        onLoaded: { backendStore._txFresh = true; backendStore.adoptCounters(); }
        onLoadFailed: backendStore.dataUsageAvailable = false
    }

    function readDataUsage() {
        if (modems.length > 0 && modems[0].netInterface && modems[0].netInterface !== statsInterface)
            statsInterface = modems[0].netInterface;
        if (!hasModem || !statsInterface) {
            dataUsageAvailable = false;
            return;
        }
        _rxFresh = false;
        _txFresh = false;
        counterRxFile.reload();
        counterTxFile.reload();
    }

    property bool _rxFresh: false
    property bool _txFresh: false

    function adoptCounters() {
        if (!_rxFresh || !_txFresh) return;
        _rxFresh = false;
        _txFresh = false;
        {
                const newRx = parseInt(counterRxFile.text(), 10) || 0;
                const newTx = parseInt(counterTxFile.text(), 10) || 0;

                // Roll the ledger over at midnight before accumulating.
                const key = backendStore.usageDayKey();
                if (key !== backendStore._ledgerKey) {
                    backendStore.saveUsageHistory();
                    backendStore._ledgerKey = key;
                    backendStore.todayRx = 0;
                    backendStore.todayTx = 0;
                }

                if (backendStore._sampleRx < 0) {
                    // First sample after load: adopt as baseline, no delta.
                    backendStore._sampleRx = newRx;
                    backendStore._sampleTx = newTx;
                } else {
                    // A counter that went backwards means the interface reset;
                    // skip that delta rather than booking a bogus jump.
                    if (newRx >= backendStore._sampleRx) {
                        const dRx = newRx - backendStore._sampleRx;
                        backendStore.todayRx += dRx;
                        backendStore._pendingRx += dRx;
                        backendStore.lifetimeRx += dRx;
                    }
                    if (newTx >= backendStore._sampleTx) {
                        const dTx = newTx - backendStore._sampleTx;
                        backendStore.todayTx += dTx;
                        backendStore._pendingTx += dTx;
                        backendStore.lifetimeTx += dTx;
                    }
                    backendStore._sampleRx = newRx;
                    backendStore._sampleTx = newTx;
                }

                const elapsed = Math.max(1, counterTimer.interval / 1000);
                backendStore.rxRate = Math.max(0, newRx - backendStore.prevRxBytes) / elapsed;
                backendStore.txRate = Math.max(0, newTx - backendStore.prevTxBytes) / elapsed;
                backendStore.prevRxBytes = backendStore.rxBytes;
                backendStore.prevTxBytes = backendStore.txBytes;
                backendStore.rxBytes = newRx;
                backendStore.txBytes = newTx;
                backendStore.dataUsageAvailable = true;

                if (backendStore._pendingRx + backendStore._pendingTx > 1048576)
                    backendStore.saveUsageHistory();
        }
    }

    // ═════════════════════════════════════════════════════════════════════
    // INCOMING SMS HISTORY
    //
    // mmcli only exposes what is currently stored on the SIM/modem, so a
    // message disappears from the UI once it is deleted on the modem or the
    // SIM is swapped. We mirror every message we ever see into a persisted
    // ledger so the inbox survives that.
    // ═════════════════════════════════════════════════════════════════════

    property var smsHistory: []          // newest first, persisted
    property var smsReadKeys: ({})       // "number|timestamp" already seen
    property var smsDeletedKeys: ({})    // tombstones: never resurrect from the vault
    property int smsRetentionDays: 0     // 0 = keep everything (Obsidian archives it)
    property int smsHistoryCap: 5000
    property bool smsHistoryLoaded: false

    // Identity of the SIM the messages belong to, so a second number's
    // traffic stays distinguishable in the archive.
    property var simIdentity: ({})       // { label, operator, imsi, iccid, ownNumber }
    property string simLabelOverride: ""
    // The modem reports an empty own-number for this SIM (CNUM is not
    // provisioned), so the number is settable by hand and remembered.
    property string simOwnNumberOverride: ""
    property string smsExportStatus: ""
    property bool smsExportEnabled: false
    // ── MMS (彩信) ───────────────────────────────────────────────────
    // mmsd-tng 把彩信以原始 PDU 落盘；mms-export 解析成 JSON，插件只读这个 JSON。
    property var mmsMessages: []
    property int mmsRevision: 0
    property string mmsJson: stateDir + "/mms.json"
    property string mmsExporter: helperDir + "/mms-export"
    property string pluginIcon: Qt.resolvedUrl("assets/control-center.png").toString().replace("file://", "")
    property string mmsExportStatus: ""

    // ── 新消息桌面通知 ───────────────────────────────────────────────
    property bool notifyEnabled: true
    property bool notifyReady: false      // 首次加载完成为 true，避免开机把旧消息全弹一遍
    property var notifiedKeys: ({})

    property string obsidianExporter: helperDir + "/eg25-sms-obsidian"
    property bool obsidianReady: false      // 归档脚本 + 笔记库目录都在时为 true
    property string obsidianVault: homeDir + "/Documents"

    function defaultSimLabel(operatorCode, iccid) {
        const names = { "46011": "中国电信", "46000": "中国移动", "46001": "中国联通", "46015": "中国广电" };
        const base = names[operatorCode] || (operatorCode ? operatorCode : "本机");
        const tail = String(iccid || "").slice(-4);
        return tail ? (base + " …" + tail) : base;
    }

    function simLabel() {
        if (backendStore.simLabelOverride) return backendStore.simLabelOverride;
        return backendStore.simIdentity.label || "";
    }

    // Effective number to display: manual entry wins over what the modem says.
    function ownNumber() {
        if (backendStore.simOwnNumberOverride) return backendStore.simOwnNumberOverride;
        return backendStore.simIdentity.ownNumber || "";
    }

    function setOwnNumber(value) {
        const v = String(value || "").replace(/[^0-9+]/g, "");
        backendStore.simOwnNumberOverride = v;
        const id = Object.assign({}, backendStore.simIdentity);
        id.ownNumber = v;
        backendStore.simIdentity = id;
        backendStore.saveSimSettings();
        // The exporter reads the state file, and writes to it are debounced,
        // so give the flush a moment before re-rendering the vault note.
        exportDelay.restart();
    }

    function loadSimSettings() {
        if (!pluginService || !pluginId) return;
        backendStore.simLabelOverride = pluginService.loadPluginState(pluginId, "simLabelOverride", "");
        backendStore.simOwnNumberOverride = pluginService.loadPluginState(pluginId, "simOwnNumberOverride", "");
        backendStore.smsExportEnabled = pluginService.loadPluginState(pluginId, "smsExportEnabled", false);
        backendStore.notifyEnabled = pluginService.loadPluginState(pluginId, "notifyEnabled", true);
        backendStore.obsidianExporter = pluginService.loadPluginState(pluginId, "obsidianExporter",
            backendStore.obsidianExporter);
        backendStore.obsidianVault = pluginService.loadPluginState(pluginId, "obsidianVault",
            backendStore.obsidianVault);
    }

    function notifyMessage(title, body) {
        if (!backendStore.notifyEnabled) return;
        if (!body) body = "";
        if (body.length > 160) body = body.slice(0, 160) + "…";
        // 这里刻意【不传 id】：Proc.runCommand 的第一个参数是去重键，同一个 id 在 debounce
        // 窗口（默认 50ms）内被重复调用时，后一条会覆盖前一条，只有最后一条真正执行 ——
        // 曾因此导致「同一轮到的多条短信只弹最后一条」。不传 id 时内部改用随机键，
        // 且命令结束后会自动销毁计时器和条目（不会泄漏）。
        // DMS 内置通知，不再依赖 libnotify 的 notify-send
        // （CONTRIBUTING.md「Built-in Alternatives」）。参数对齐原语义：
        // --app = 应用名，--icon = 图标，--timeout 9000ms。
        Proc.runCommand(undefined,
            ["dms", "notify", title, body,
             "--app", "SIM Network", "--icon", backendStore.pluginIcon,
             "--timeout", "9000"],
            function (out, code) {
                if (code !== 0)
                    console.warn("[SimNetwork] dms notify failed: "
                                 + String(out || "").slice(0, 120));
            }, 0);
    }

    // 只对"会话启动之后新到的"消息弹提示：notifyReady 之前一律不弹。
    // 插件启动时刻：只有在这之后到达的消息才允许弹通知。
    // 否则每次开机，模块里还存着的旧短信（key 与历史对不上的）会被当成新消息重弹。
    property double notifyFloor: Date.now()
    property bool notifyFloorSet: false

    function maybeNotify(m) {
        if (!backendStore.notifyReady || !backendStore.notifyEnabled) return;
        if (m.isSubmit) return;          // 自己发出的不提醒
        const k = String(m.key || backendStore.smsKey(m));
        const ts = backendStore.parseStamp(m.timestamp);
        // 「启动前的旧消息一律静默」只在时间戳能解析时生效。
        //
        // 但绝不能反过来把「解析不了」当成旧消息 —— 那样只要某个调用点忘了传
        // timestamp（真实发生过：短信和彩信两处都没传），全量通知会被静默掉，
        // 而且 dbus 上看确实是"没弹"，很容易误判为"修好了"。解析不了时退回
        // 按 key 去重：启动时历史里的 key 已全部播种，所以新 key 就一定是新消息。
        if (!isNaN(ts) && ts < backendStore.notifyFloor) {
            const seen0 = Object.assign({}, backendStore.notifiedKeys);
            seen0[k] = true;
            backendStore.notifiedKeys = seen0;
            return;
        }
        const seen = Object.assign({}, backendStore.notifiedKeys);
        if (seen[k]) return;
        seen[k] = true;
        backendStore.notifiedKeys = seen;
        const num = String(m.number || m.from || "未知号码");
        const label = m.kind === "mms" ? "新彩信" : (m.isSubmit ? "短信已发出" : "新短信");
        let body = m.kind === "mms"
            ? ((m.attachments && m.attachments.length) ? ("图片彩信（" + m.attachments.length + " 个附件）" + (m.text ? "：" + m.text : "")) : (m.text || ""))
            : (m.text || "");
        backendStore.notifyMessage(label + " · " + num, body);
    }

    function seedNotified() {
        const seen = {};
        for (let i = 0; i < backendStore.smsHistory.length; i++) {
            const m = backendStore.smsHistory[i];
            seen[String(m.key || backendStore.smsKey(m))] = true;
        }
        for (let i = 0; i < backendStore.mmsMessages.length; i++) {
            const m = backendStore.mmsMessages[i];
            seen["mms:" + m.id] = true;
        }
        backendStore.notifiedKeys = seen;
        if (!backendStore.notifyFloorSet) {
            backendStore.notifyFloor = Date.now();
            backendStore.notifyFloorSet = true;
        }
        backendStore.notifyReady = true;
    }

    // 解析彩信（mms-export 输出 JSON），再读回来作为 mmsMessages。
    function loadMmsMessages() {
        Proc.runCommand(backendStore.commandPrefix + ".mms.export",
            [backendStore.mmsExporter, "--json", backendStore.mmsJson, "--save-attachments"],
            function (output, code) {
                if (code !== 0) {
                    backendStore.mmsExportStatus = "mms-export 失败: " + String(output || "").slice(0, 120);
                    return;
                }
                Proc.runCommand(backendStore.commandPrefix + ".mms.read",
                    ["cat", backendStore.mmsJson],
                    function (raw, rcode) {
                        if (rcode !== 0 || !raw) return;
                        let list = [];
                        try {
                            const data = JSON.parse(raw);
                            list = data.messages || [];
                        } catch (e) {
                            backendStore.mmsExportStatus = "彩信 JSON 解析失败";
                            return;
                        }
                        const sig = function (arr) {
                            return arr.map(function (x) {
                                return x.id + ":" + ((x.attachments || []).length) + ":" + (x.bytes || 0);
                            }).join(",");
                        };
                        const before = sig(backendStore.mmsMessages);
                        backendStore.mmsMessages = list;
                        // 只有内容真变了才 bump，否则每 30 秒白重算一遍会话模型
                        if (before !== sig(list)) backendStore.mmsRevision = backendStore.mmsRevision + 1;
                        backendStore.mmsExportStatus = list.length
                            ? ("彩信 " + list.length + " 条") : "";
                        if (backendStore.notifyReady && backendStore.notifyEnabled) {
                            for (let i = 0; i < list.length; i++) {
                                backendStore.maybeNotify({
                                    key: "mms:" + list[i].id,
                                    number: list[i].number || list[i].from || "",
                                    text: list[i].text || "",
                                    timestamp: list[i].timestamp || list[i].date || list[i].received
                                               || list[i].sent || "",   // 同上，必须带上
                                    kind: "mms",
                                    attachments: list[i].attachments || []
                                });
                            }
                        }
                    });
            });
    }

    function saveSimSettings() {
        if (!pluginService || !pluginId) return;
        pluginService.savePluginState(pluginId, "simLabelOverride", backendStore.simLabelOverride);
        pluginService.savePluginState(pluginId, "simOwnNumberOverride", backendStore.simOwnNumberOverride);
        pluginService.savePluginState(pluginId, "smsExportEnabled", backendStore.smsExportEnabled);
        pluginService.savePluginState(pluginId, "notifyEnabled", backendStore.notifyEnabled);
        pluginService.savePluginState(pluginId, "obsidianExporter", backendStore.obsidianExporter);
        pluginService.savePluginState(pluginId, "obsidianVault", backendStore.obsidianVault);
        pluginService.savePluginState(pluginId, "simIdentity", backendStore.simIdentity);
    }

    // Mirror the ledger into the Obsidian vault. The exporter reads the plugin
    // state file itself, so nothing has to be passed through the shell.
    // 归档依赖「本机辅助脚本 + 笔记库目录」。先探测再跑：别人装上插件时
    // 这两样往往不存在，不探测就会在启动时看到一条莫名其妙的 Export failed。
    function probeObsidian() {
        Proc.runCommand(commandPrefix + ".obsidian.probe",
            ["sh", "-c", "test -x \"$1\" && test -d \"$2\"", "probe",
             backendStore.obsidianExporter, backendStore.obsidianVault],
            (output, code) => {
                backendStore.obsidianReady = (code === 0);
                console.info("[SimNetwork] obsidian archive: "
                    + (backendStore.obsidianReady ? "enabled"
                       : "disabled (missing " + backendStore.obsidianExporter + ")"));
                if (backendStore.obsidianReady) {
                    backendStore.importSmsFromObsidian();
                    backendStore.exportSmsToObsidian();
                }
            });
    }

    function exportSmsToObsidian() {
        if (!backendStore.smsExportEnabled) return;
        if (!backendStore.obsidianExporter) return;
        if (!backendStore.obsidianReady) {
            backendStore.smsExportStatus = "归档不可用：缺少 " + backendStore.obsidianExporter;
            return;
        }
        Proc.runCommand(backendStore.commandPrefix + ".sms.export",
            [backendStore.obsidianExporter, "--vault", backendStore.obsidianVault],
            (output, code) => {
                backendStore.smsExportStatus = code === 0
                    ? "Archived to Obsidian — " + String(output).trim()
                    : "Export failed: " + String(output).trim();
            });
    }

    // Reads the SIM card identity reported by ModemManager.
    function loadSimIdentity(simPath) {
        if (!simPath) return;
        Proc.runCommand(backendStore.commandPrefix + ".sim", ["mmcli", "--sim=" + simPath, "-J"], (output, code) => {
            if (code !== 0 || !output) return;
            try {
                const props = (JSON.parse(output).sim || {}).properties || {};
                const iccid = clean(props.iccid || "");
                const operatorCode = clean(props["operator-code"] || "");
                backendStore.simIdentity = {
                    label: backendStore.simLabelOverride
                        || backendStore.defaultSimLabel(operatorCode, iccid),
                    operator: clean(props["operator-name"] || "") || operatorCode,
                    imsi: clean(props.imsi || ""),
                    iccid: iccid,
                    ownNumber: backendStore.simOwnNumberOverride
                        || ((backendStore.modems.length && backendStore.modems[0].ownNumbers)
                            ? backendStore.modems[0].ownNumbers : ""),
                    netInterface: backendStore.statsInterface
                };
                backendStore.saveSimSettings();
                backendStore.importSmsFromObsidian();
            } catch (e) { /* identity is best-effort */ }
        });
    }

    Timer {
        id: mmHealTimer
        interval: 4000
        repeat: false
        onTriggered: backendStore.recoverModemManager("")
    }

    // 周期性兜底：万一被 SIGKILL 等极端情况留下停机状态，也能自己站起来
    Timer {
        id: mmWatchdog
        interval: 60000
        repeat: true
        // 脚本没装就别起 sh（那是必然失败的一次子进程），没猫也没必要看门
        running: backendStore.healHelperInstalled && backendStore.hasModem
        triggeredOnStart: true
        onTriggered: {
            // 只有在上次运行留下标记（$XDG_RUNTIME_DIR/eg25-mm-stopped）时才检查，避免多余调用
            Proc.runCommand(backendStore.commandPrefix + ".mmwatch",
                ["sh", "-c",
                 // 只在「持有标记的进程已经不在了」或「标记超过 10 分钟」时才动手，
                 // 否则会把正在进行的 AT 发送打断。
                 "f=${XDG_RUNTIME_DIR:-/tmp}/eg25-mm-stopped; [ -f \"$f\" ] || exit 0; "
                 + "pid=$(cut -d: -f1 \"$f\"); ts=$(cut -d: -f2 \"$f\"); now=$(date +%s); "
                 + "kill -0 \"$pid\" 2>/dev/null && [ $((now - ${ts:-0})) -lt 600 ] && exit 0; "
                 + "rm -f \"$f\"; "
                 + "exec \"" + backendStore.helperDir + "/eg25-mm-heal\""],
                function () {});
        }
    }

    Timer {
        id: smsReloadTimer
        interval: 1500
        repeat: false
        onTriggered: backendStore.loadSmsList()
    }

    function historyKey(number, timestamp) {
        return String(number || "").replace(/\D/g, "") + "|" + String(timestamp || "");
    }

    function isSmsRead(number, text, timestamp, pduType) {
        if (pduType === "submit") return true;   // our own outgoing message
        return !!backendStore.smsReadKeys[backendStore.historyKey(number, timestamp)];
    }

    function loadReadKeys() {
        if (!pluginService || !pluginId) return;
        let k = {};
        try { k = pluginService.loadPluginState(pluginId, "smsReadKeys", {}) || {}; }
        catch (e) { k = {}; }
        backendStore.smsReadKeys = k;
        let d = {};
        try { d = pluginService.loadPluginState(pluginId, "smsDeletedKeys", {}) || {}; }
        catch (e) { d = {}; }
        backendStore.smsDeletedKeys = d;
    }

    function saveReadKeys() {
        if (!pluginService || !pluginId) return;
        pluginService.savePluginState(pluginId, "smsReadKeys", backendStore.smsReadKeys);
        pluginService.savePluginState(pluginId, "smsDeletedKeys", backendStore.smsDeletedKeys);
    }

    // Quickshell.clipboardText only updates an in-process value here — it never
    // reaches the Wayland clipboard (verified: wl-paste stays empty).
    // 用 DMS 内置的 dms clipboard copy（CONTRIBUTING「Built-in Alternatives」），
    // 它会同时进剪贴板历史；Quickshell 属性仍作兜底。
    function copyToClipboard(text) {
        const t = String(text || "");
        if (!t.length) return;
        Proc.runCommand(backendStore.commandPrefix + ".clip",
            ["dms", "clipboard", "copy", t],
            function (output, code) {
                if (code !== 0) {
                    Quickshell.clipboardText = t;
                    console.warn("[SimNetwork] dms clipboard exited " + code
                                 + "; fell back to Quickshell clipboard");
                } else {
                    console.info("[SimNetwork] copied " + t.length + " chars");
                }
            });
    }

    function markSmsDeleted(key) {
        if (!key) return;
        const d = Object.assign({}, backendStore.smsDeletedKeys);
        d[key] = true;
        backendStore.smsDeletedKeys = d;
        backendStore.saveReadKeys();
    }

    function recomputeUnread() {
        let n = 0;
        for (let i = 0; i < backendStore.smsHistory.length; i++) {
            const m = backendStore.smsHistory[i];
            if (m.isSubmit) continue;
            if (!backendStore.smsReadKeys[backendStore.historyKey(m.number, m.timestamp)]) n++;
        }
        // 彩信也算未读——否则会话里有角标、总计数却不认，两边对不上
        const mms = backendStore.mmsMessages || [];
        for (let i = 0; i < mms.length; i++) {
            const mm = mms[i];
            const num = mm.number || mm.from || "";
            if (!backendStore.smsReadKeys[backendStore.historyKey(num, mm.date)]) n++;
        }
        backendStore.smsUnreadCount = n;
    }

    // Mark every received message in one conversation as read.
    function markSmsThreadRead(items) {
        if (!items || !items.length) return;
        const k = Object.assign({}, backendStore.smsReadKeys);
        let n = 0;
        for (let i = 0; i < items.length; i++) {
            const m = items[i];
            if (m.isSubmit) continue;
            const key = backendStore.historyKey(m.number, m.timestamp);
            if (!k[key]) { k[key] = true; n++; }
        }
        if (n === 0) return;
        backendStore.smsReadKeys = k;
        backendStore.saveReadKeys();
        backendStore.recomputeUnread();
    }

    function markSmsHistoryRead() {
        const keys = {};
        for (let i = 0; i < backendStore.smsHistory.length; i++) {
            const m = backendStore.smsHistory[i];
            if (m.isSubmit) continue;
            keys[backendStore.historyKey(m.number, m.timestamp)] = true;
        }
        backendStore.smsReadKeys = keys;
        backendStore.smsUnreadCount = 0;
        backendStore.saveReadKeys();
    }

    function smsKey(m) {
        return String(m.number || "").replace(/\D/g, "")
             + "|" + String(m.timestamp || "")
             + "|" + String(m.text || "").slice(0, 60)
             + "|" + (m.isSubmit ? "out" : "in");
    }

    function sameNumber(a, b) {
        const x = String(a || "").replace(/\D/g, "");
        const y = String(b || "").replace(/\D/g, "");
        if (!x || !y) return false;
        return x === y || x.endsWith(y) || y.endsWith(x);
    }

    function loadSmsHistory() {
        if (!pluginService || !pluginId) return;
        let h = [];
        try { h = JSON.parse(JSON.stringify(pluginService.loadPluginState(pluginId, "smsHistory", []) || [])); }
        catch (e) { h = []; }
        if (!Array.isArray(h)) h = [];
        backendStore.smsHistory = h;
        // Repair older data: outgoing rows used to be stored without a
        // timestamp (ranked last, looked unrecorded) and a key mismatch
        // against the vault index could duplicate them on re-import.
        if (backendStore.normalizeSmsHistory()) backendStore.saveSmsHistory();
        backendStore.smsHistoryLoaded = true;
    }

    function pruneSmsHistory() {
        if (backendStore.smsRetentionDays <= 0) return;   // 0 = keep everything
        const cutoff = new Date();
        cutoff.setDate(cutoff.getDate() - backendStore.smsRetentionDays);
        const cutoffStr = Qt.formatDate(cutoff, "yyyy-MM-dd");
        const kept = [];
        for (let i = 0; i < backendStore.smsHistory.length; i++) {
            const m = backendStore.smsHistory[i];
            const day = String(m.timestamp || "").slice(0, 10);
            // Keep entries we cannot date rather than silently dropping them.
            if (!/^\d{4}-\d{2}-\d{2}$/.test(day) || day >= cutoffStr) kept.push(m);
            else backendStore.markSmsDeleted(m.key);
        }
        backendStore.smsHistory = kept;
    }

    // Bumped whenever the ledger changes so the UI's derived conversation
    // model re-evaluates: QML does not notify on in-place array mutation.
    property int smsRevision: 0

    function saveSmsHistory() {
        if (!pluginService || !pluginId) return;
        // 每次落盘前先去重/补时间戳：只靠启动时那一次，运行期新增的重复
        // （比如归档回读 + 本地记录撞车）要等下次重启才清理。
        backendStore.normalizeSmsHistory();
        backendStore.pruneSmsHistory();
        if (backendStore.smsHistory.length > backendStore.smsHistoryCap)
            backendStore.smsHistory = backendStore.smsHistory.slice(0, backendStore.smsHistoryCap);
        pluginService.savePluginState(pluginId, "smsHistory", backendStore.smsHistory);
        backendStore.smsRevision = backendStore.smsRevision + 1;
    }

    // Mirrors freshly read modem messages into the ledger and feeds any
    // carrier quota reply to the parser.
    // Identity for de-duplication: a message is the same message whatever
    // key/timestamp it carries. Key-based dedupe fails once timestamps get
    // backfilled, which duplicated sent rows against the vault index.
    function smsIdentity(m) {
        return String(m.number || "").replace(/\D/g, "")
             + "|" + String(m.text || "").slice(0, 200)
             + "|" + (m.isSubmit ? "out" : "in");
    }

    // Fill missing timestamps and collapse duplicates (keeping the copy that
    // has a real timestamp / SIM info). Returns true when anything changed.
    function normalizeSmsHistory() {
        const p2 = (n) => String(n).padStart(2, "0");
        function stampFor(e) {
            if (e.timestamp) return e.timestamp;
            const d = new Date(e.importedAt || Date.now());
            const off = -d.getTimezoneOffset();
            const sg = off >= 0 ? "+" : "-";
            const a = Math.abs(off);
            return d.getFullYear() + "-" + p2(d.getMonth() + 1) + "-" + p2(d.getDate())
                 + "T" + p2(d.getHours()) + ":" + p2(d.getMinutes()) + ":" + p2(d.getSeconds())
                 + sg + p2(Math.floor(a / 60)) + ":" + p2(a % 60);
        }
        const best = {};
        const out = [];
        for (let i = 0; i < backendStore.smsHistory.length; i++) {
            const e = backendStore.smsHistory[i];
            if (!e) continue;
            // 彩信由 mms.json 提供；历史上的彩信残留（早期归档回读造成）丢弃
            if (String(e.key || "").startsWith("mms:") || e.kind === "mms") continue;
            const id = backendStore.smsIdentity(e);
            const prev = best[id];
            if (prev) {
                if (!prev.timestamp && e.timestamp) prev.timestamp = e.timestamp;
                if (!prev.simIccid && e.simIccid) { prev.simIccid = e.simIccid; prev.simLabel = e.simLabel; }
                if (!prev.importedAt && e.importedAt) prev.importedAt = e.importedAt;
                continue;
            }
            if (!e.timestamp) e.timestamp = stampFor(e);
            e.key = backendStore.smsKey(e);
            best[id] = e;
            out.push(e);
        }
        const changed = out.length !== backendStore.smsHistory.length;
        backendStore.smsHistory = out;
        return changed;
    }

    // Local wall-clock stamp shaped like ModemManager's incoming stamps
    // (2026-09-21T19:13:07+08:00) so both sort together as strings.
    function localIsoStamp() {
        const d = new Date();
        const p = (n) => String(n).padStart(2, "0");
        const off = -d.getTimezoneOffset();
        const sign = off >= 0 ? "+" : "-";
        const a = Math.abs(off);
        return d.getFullYear() + "-" + p(d.getMonth() + 1) + "-" + p(d.getDate())
             + "T" + p(d.getHours()) + ":" + p(d.getMinutes()) + ":" + p(d.getSeconds())
             + sign + p(Math.floor(a / 60)) + ":" + p(a % 60);
    }

    // The modem keeps no sent items (AT+CPMS sent storage is empty and
    // AT+CMGL=3 returns nothing) and ModemManager drops its SMS object the
    // moment the submit succeeds, so an outgoing message exists nowhere but
    // here. Record it at send time, with a real timestamp.
    function recordSentSms(number, text) {
        if (!number || !text) return;
        const stamp = backendStore.localIsoStamp();
        const probe = { number: String(number), text: String(text), timestamp: stamp, isSubmit: true };
        const k = backendStore.smsKey(probe);
        const ident = backendStore.smsIdentity(probe);
        for (let i = 0; i < backendStore.smsHistory.length; i++) {
            const e = backendStore.smsHistory[i];
            // key 相同（同一条）或内容相同（同号码同正文同方向）都不再重复记
            if (e.key === k || backendStore.smsIdentity(e) === ident) return;
        }
        backendStore.smsHistory.unshift({
            key: k,
            number: probe.number,
            text: probe.text,
            timestamp: stamp,
            isSubmit: true,
            simLabel: backendStore.simLabel(),
            simIccid: backendStore.simIdentity.iccid || "",
            importedAt: new Date().toISOString()
        });
        backendStore.saveSmsHistory();
        backendStore.exportSmsToObsidian();
        backendStore.smsListUpdated();
    }

    // ── 发彩信 ────────────────────────────────────────────────────────────
    // 走模块原生 MMS AT 命令（mmsd-tng 那条路发不出去：电信彩信提交必须经
    // WAP 网关 10.0.0.200，普通数据 APN 不可达）。发送要独占 AT 口 →
    // 必须先停 ModemManager，所以配了一条最小 sudoers 规则。
    property string mmsImagePath: ""
    property string mmsSendStatus: ""
    property bool mmsSending: false
    property string mmsSenderBin: helperDir + "/eg25-mms-send"
    property string mmsAttachDir: stateDir + "/mms-att"

    function pickMmsImage() {
        Proc.runCommand(commandPrefix + ".mms.pick",
            ["zenity", "--file-selection", "--title=选择要发送的图片",
             "--file-filter=图片 (*.jpg *.jpeg *.png *.gif *.webp) | *.jpg *.jpeg *.png *.gif *.webp",
             "--file-filter=所有文件 | *"],
            (output, code) => {
                const picked = String(output || "").trim();
                if (code === 0 && picked.length > 0) {
                    backendStore.mmsImagePath = picked;
                    backendStore.mmsSendStatus = "";
                }
            });
    }

    // ModemManager 被 eg25-mms-send 临时停掉后若没起回来，整个 4G 都会哑掉
    // （信号 0% / 上不了网 / 短信收不到）。这里做兜底自愈。
    function recoverModemManager(tag) {
        // 交给 eg25-mm-heal：它不只把 ModemManager 起回来，还会在模块落到
        // state: failed / unknown-capabilities（硬杀后 MM 在半死状态下重启）
        // 时清掉 QMI/PDP 残留上下文，真正恢复到 connected。
        Proc.runCommand(backendStore.commandPrefix + ".mmheal",
            [backendStore.helperDir + "/eg25-mm-heal"],
            function (out, code) {
                if (code === 0) return;
                if (tag) backendStore.mmsSendStatus = String(tag);
            });
    }

    function sendMms(number, image, done) {
        if (!number || !image) return;
        backendStore.mmsSending = true;
        backendStore.mmsSendStatus = "正在发送…（临时停 ModemManager，约 20-40 秒，这期间别的页面会短暂显示无模块）";
        Proc.runCommand(commandPrefix + ".mms.send",
            // 不需要 sudo：脚本内部用 sudo -n systemctl 停/启 ModemManager，
            // 走的是系统里已有的 systemctl 免密规则。
            [backendStore.mmsSenderBin, String(number), String(image)],
            (output, code) => {
                const text = String(output || "");
                backendStore.mmsSending = false;
                const m = /err=(\d+)\s+HTTP=(\d+)/.exec(text);
                if (code === 0 && m && m[1] === "0") {
                    backendStore.mmsSendStatus = "✓ 彩信已发出（HTTP " + m[2] + "）";
                    backendStore.recordSentMms(String(number), String(image));
                    if (done) done(true, "sent");
                    smsReloadTimer.restart();
                } else {
                    let hint = "";
                    if (/not allowed|password|密码/i.test(text))
                        hint = "（停/启 ModemManager 需要免密：/etc/sudoers.d 里只放行 systemctl start/stop ModemManager 这两条，"
                             + "别整条放行 /usr/bin/systemctl）";
                    const trimmed = text.trim();
                    const detail = m ? ("err=" + m[1] + " HTTP=" + m[2])
                                     : (trimmed ? trimmed.split("\n").slice(-3).join(" / ").slice(0, 220)
                                                : "脚本被打断了（退出码 " + code + "，没有任何输出）——"
                                                  + "发送中如果重启 DMS / 关掉窗口就会这样。"
                                                  + "ModemManager 自愈机制已接管，20~90 秒内 4G 会自动恢复");
                    backendStore.mmsSendStatus = "✗ 发送失败：" + detail + " " + hint;
                    if (done) done(false, detail);
                    // 失败常常是因为脚本中途被杀 → 停掉的 ModemManager 没起回来
                    mmHealTimer.restart();
                }
                // 成功路径不再排自愈：脚本自己会把 ModemManager 起回来，
                // 这里再调一次只会平白重启服务。
            });
    }

    function recordSentMms(number, image) {
        if (!number || !image) return;
        const stamp = backendStore.localIsoStamp();
        const base = String(image).split("/").pop();
        const safe = stamp.replace(/[:+]/g, "").replace(/\.[0-9]+$/, "");
        const dest = backendStore.mmsAttachDir + "/" + safe + "-" + base;
        // 把图片留一份到插件目录，免得原图被删后归档与缩略图失效
        Proc.runCommand(commandPrefix + ".mms.archive", ["cp", "-n", String(image), dest], (o, c) => {
            const stored = (c === 0) ? dest : String(image);
            backendStore.smsHistory.unshift({
                key: "mms:" + String(number).replace(/\D/g, "") + ":" + stamp,
                number: String(number),
                text: "",
                timestamp: backendStore.normalizeStamp(stamp),
                isSubmit: true,
                kind: "mms",
                attachments: [{ path: stored, name: base, mime: "image/jpeg", bytes: 0 }],
                simLabel: backendStore.simLabel(),
                simIccid: backendStore.simIdentity.iccid || "",
                importedAt: new Date().toISOString()
            });
            backendStore.saveSmsHistory();
            backendStore.exportSmsToObsidian();
            backendStore.smsListUpdated();
        });
    }

    function importSmsToHistory(found) {
        if (!found || !found.length) return;
        const seen = {};
        for (let i = 0; i < backendStore.smsHistory.length; i++)
            seen[backendStore.smsHistory[i].key] = true;
        let added = 0;
        for (let i = 0; i < found.length; i++) {
            const m = found[i];
            // Evaluate the carrier-quota parser on every poll, not only on
            // first sight: the reply may predate a plugin reload.
            backendStore.considerQuotaReply(m);
            const k = backendStore.smsKey(m);
            if (seen[k]) continue;
            seen[k] = true;
            backendStore.smsHistory.unshift({
                key: k,
                number: m.number || "",
                text: m.text || "",
                timestamp: m.timestamp || "",
                isSubmit: !!m.isSubmit,
                simLabel: backendStore.simLabel(),
                simIccid: backendStore.simIdentity.iccid || "",
                importedAt: new Date().toISOString()
            });
            backendStore.maybeNotify({
                key: k, number: m.number || "", text: m.text || "",
                timestamp: m.timestamp || "",       // 少了这个 → 一律被判成旧消息而静音
                isSubmit: !!m.isSubmit, kind: "sms"
            });
            added++;
        }
        if (added > 0) {
            backendStore.saveSmsHistory();
            backendStore.exportSmsToObsidian();
        }
    }

    // Treat any parseable reply from the query number as the carrier figure.
    // Gated on the reply's own key so one reply is only recorded once, even
    // across plugin reloads, and on its month so stale replies are ignored.
    function considerQuotaReply(m) {
        if (!m || m.isSubmit) return;
        if (!backendStore.sameNumber(m.number, backendStore.quotaQueryNumber)) return;
        const hk = backendStore.historyKey(m.number, m.timestamp);
        if (backendStore.quotaSourceKey === hk) { backendStore.quotaQueryPending = false; return; }
        const replyMonth = String(m.timestamp || "").slice(0, 7);
        if (replyMonth && replyMonth !== backendStore.quotaMonth()) {
            backendStore.quotaQueryPending = false;
            return;
        }
        if (!backendStore.parseQuotaText(m.text)) {
            if (backendStore.quotaQueryPending)
                backendStore.quotaStatus = "Carrier replied but the figures were not readable — enter them by hand.";
            backendStore.quotaQueryPending = false;
            return;
        }
        if (backendStore.applyQuotaFromText(m.text, "carrier")) {
            backendStore.quotaSourceKey = hk;
            backendStore.saveQuotaSettings();
        }
    }

    // Read the vault's index back so the archive is the master record: if the
    // plugin state is ever reset, the inbox is re-seeded from Obsidian.
    function importSmsFromObsidian() {
        if (!backendStore.smsExportEnabled) return;
        if (!backendStore.obsidianVault) return;
        const path = backendStore.obsidianVault + "/短信记录/.sms-index.json";
        Proc.runCommand(backendStore.commandPrefix + ".sms.import", ["cat", path], (output, code) => {
            if (code !== 0 || !output) return;
            let arr = [];
            try { arr = JSON.parse(output); } catch (e) { return; }
            if (!Array.isArray(arr) || !arr.length) return;
            const seen = {};
            const seenContent = {};
            for (let i = 0; i < backendStore.smsHistory.length; i++) {
                seen[backendStore.smsHistory[i].key] = true;
                seenContent[backendStore.smsIdentity(backendStore.smsHistory[i])] = true;
            }
            let added = 0;
            for (let i = 0; i < arr.length; i++) {
                const m = arr[i];
                const k = m.key || backendStore.smsKey(m);
                // Same message coming back from the archive must not be added
                // again just because its key/timestamp differs.
                if (String(m.key || "").startsWith("mms:") || m.kind === "mms") continue;
                if (seen[k] || seenContent[backendStore.smsIdentity(m)]) continue;
                if (backendStore.smsDeletedKeys[k]) continue;
                seen[k] = true;
                backendStore.smsHistory.push({
                    key: k,
                    number: m.number || "",
                    text: m.text || "",
                    timestamp: m.timestamp || "",
                    isSubmit: !!m.isSubmit,
                    simLabel: m.simLabel || backendStore.simLabel(),
                    simIccid: m.simIccid || backendStore.simIdentity.iccid || "",
                    importedAt: m.importedAt || new Date().toISOString(),
                    fromArchive: true
                });
                added++;
            }
            if (added > 0) {
                backendStore.smsHistory.sort((a, b) =>
                    String(b.timestamp || b.importedAt || "").localeCompare(String(a.timestamp || a.importedAt || "")));
                backendStore.saveSmsHistory();
                backendStore.recomputeUnread();
            }
        });
    }

    function deleteSmsHistoryItem(key) {
        // Record a tombstone: the vault archive still holds the message, so
        // without it the read-back would resurrect it on the next poll.
        backendStore.markSmsDeleted(key);
        const kept = [];
        for (let i = 0; i < backendStore.smsHistory.length; i++)
            if (backendStore.smsHistory[i].key !== key) kept.push(backendStore.smsHistory[i]);
        backendStore.smsHistory = kept;
        backendStore.saveSmsHistory();
    }

    function clearSmsHistory() {
        for (let i = 0; i < backendStore.smsHistory.length; i++)
            backendStore.markSmsDeleted(backendStore.smsHistory[i].key);
        // 彩信也要记墓碑，否则"清空收件箱"清不掉它们（它们来自 mms.json）
        const mms = backendStore.mmsMessages || [];
        for (let i = 0; i < mms.length; i++)
            backendStore.markSmsDeleted("mms:" + mms[i].id);
        backendStore.smsHistory = [];
        backendStore.saveSmsHistory();
        backendStore.mmsRevision = backendStore.mmsRevision + 1;
    }

    // ═════════════════════════════════════════════════════════════════════
    // CARRIER DATA QUOTA
    //
    // Operators answer a query SMS with the month's used/remaining data.
    // We keep that figure as a baseline and add our own local byte ledger on
    // top, so the panel shows a running estimate between carrier replies.
    // The baseline is monthly: a new month asks for a fresh figure.
    // ═════════════════════════════════════════════════════════════════════

    property var quota: null                  // { used, remaining, month, at, raw, source, lifetimeAtCapture }
    property bool quotaQueryPending: false
    property string quotaStatus: ""
    property bool quotaAutoQuery: false       // 默认关：自动给运营商号发短信得用户自己点头
    property string quotaQueryNumber: "10001" // China Telecom self-service
    property string quotaQueryText: "108"     // China Telecom data query
    property string lastAutoQueryMonth: ""
    property string quotaSourceKey: ""

    function quotaMonth() {
        return Qt.formatDate(new Date(), "yyyy-MM");
    }

    function loadQuota() {
        if (!pluginService || !pluginId) return;
        let q = null;
        try { q = pluginService.loadPluginState(pluginId, "quota", null); }
        catch (e) { q = null; }
        backendStore.quota = q && typeof q === "object" ? q : null;
        backendStore.quotaAutoQuery = pluginService.loadPluginState(pluginId, "quotaAutoQuery", false);
        backendStore.quotaQueryNumber = pluginService.loadPluginState(pluginId, "quotaQueryNumber", "10001");
        backendStore.quotaQueryText = pluginService.loadPluginState(pluginId, "quotaQueryText", "108");
        backendStore.lastAutoQueryMonth = pluginService.loadPluginState(pluginId, "lastAutoQueryMonth", "");
        backendStore.quotaSourceKey = pluginService.loadPluginState(pluginId, "quotaSourceKey", "");
    }

    function saveQuotaSettings() {
        if (!pluginService || !pluginId) return;
        pluginService.savePluginState(pluginId, "quota", backendStore.quota);
        pluginService.savePluginState(pluginId, "quotaAutoQuery", backendStore.quotaAutoQuery);
        pluginService.savePluginState(pluginId, "quotaQueryNumber", backendStore.quotaQueryNumber);
        pluginService.savePluginState(pluginId, "quotaQueryText", backendStore.quotaQueryText);
        pluginService.savePluginState(pluginId, "lastAutoQueryMonth", backendStore.lastAutoQueryMonth);
        pluginService.savePluginState(pluginId, "quotaSourceKey", backendStore.quotaSourceKey);
    }

    function quotaIsCurrentMonth() {
        return !!backendStore.quota && backendStore.quota.month === backendStore.quotaMonth();
    }

    function unitToBytes(value, unit) {
        const n = parseFloat(value);
        if (isNaN(n)) return -1;
        const u = String(unit || "").toUpperCase();
        if (u.indexOf("T") === 0) return n * 1099511627776;
        if (u.indexOf("G") === 0 || u === "兆") return n * 1073741824;
        if (u.indexOf("M") === 0) return n * 1048576;
        if (u.indexOf("K") === 0) return n * 1024;
        return n;
    }

    // Best-effort parse of an operator reply. Returns null when nothing
    // recognisable is found so the UI can fall back to manual entry.
    function parseQuotaText(text) {
        if (!text) return null;
        // A unit is mandatory: without it "本月21日" would read as 21 bytes and
        // shadow the real figure.
        const re = /(已使用|已用|超出|使用|剩余|还剩|可用|包含|总|流量|套餐|本月)[^0-9]{0,18}([0-9]+(?:\.[0-9]+)?)\s*(TB|GB|MB|KB|T|G|M|K|兆)/gi;
        let used = -1, remaining = -1, total = -1;
        let m;
        while ((m = re.exec(text)) !== null) {
            const label = m[1];
            const bytes = backendStore.unitToBytes(m[2], m[3]);
            if (bytes < 0) continue;
            if (/剩余|还剩|可用/.test(label)) { if (remaining < 0) remaining = bytes; }
            else if (/已使用|已用|超出|使用/.test(label)) { if (used < 0) used = bytes; }
            else if (/包含|总|流量|套餐/.test(label)) { if (total < 0) total = bytes; }
        }
        // Operators often quote total + used instead of remaining.
        if (remaining < 0 && total >= 0 && used >= 0) remaining = Math.max(0, total - used);
        if (used < 0 && remaining < 0) return null;
        return { used: used, remaining: remaining, total: total };
    }

    function computeQuotaEstimate() {
        if (!backendStore.quota) return null;
        const localSince = Math.max(0, (backendStore.lifetimeRx + backendStore.lifetimeTx)
                                       - (backendStore.quota.lifetimeAtCapture || 0));
        const used = backendStore.quota.used >= 0 ? backendStore.quota.used + localSince : -1;
        const remaining = backendStore.quota.remaining >= 0
            ? Math.max(0, backendStore.quota.remaining - localSince) : -1;
        let total = backendStore.quota.total >= 0 ? backendStore.quota.total : -1;
        if (total < 0 && used >= 0 && remaining >= 0) total = used + remaining;
        return { used: used, remaining: remaining, total: total, localSince: localSince };
    }

    function recordQuota(usedBytes, remainingBytes, rawText, source, totalBytes) {
        let total = typeof totalBytes === "number" ? totalBytes : -1;
        if (total < 0 && usedBytes >= 0 && remainingBytes >= 0) total = usedBytes + remainingBytes;
        backendStore.quota = {
            used: usedBytes,
            remaining: remainingBytes,
            total: total,
            month: backendStore.quotaMonth(),
            at: new Date().toISOString(),
            raw: String(rawText || "").slice(0, 500),
            source: source || "carrier",
            lifetimeAtCapture: backendStore.lifetimeRx + backendStore.lifetimeTx
        };
        backendStore.quotaQueryPending = false;
        backendStore.quotaStatus = "Quota recorded.";
        backendStore.saveQuotaSettings();
    }

    function applyQuotaFromText(text, source) {
        const parsed = backendStore.parseQuotaText(text);
        if (!parsed) {
            backendStore.quotaQueryPending = false;
            backendStore.quotaStatus = "Could not parse the carrier reply — enter the figures by hand.";
            return false;
        }
        backendStore.recordQuota(parsed.used, parsed.remaining, text, source, parsed.total);
        return true;
    }

    function setQuotaManual(usedText, remainingText, totalText) {
        const u = String(usedText || "").trim();
        const r = String(remainingText || "").trim();
        const t = String(totalText || "").trim();
        if (!u && !r && !t) { backendStore.quotaStatus = "填写已用 / 剩余 / 总量 中至少一项"; return; }
        const usedBytes = u ? backendStore.unitToBytes(parseFloat(u), backendStore.guessUnit(u)) : -1;
        const remBytes = r ? backendStore.unitToBytes(parseFloat(r), backendStore.guessUnit(r)) : -1;
        const totBytes = t ? backendStore.unitToBytes(parseFloat(t), backendStore.guessUnit(t)) : -1;
        if (usedBytes < 0 && remBytes < 0 && totBytes < 0) {
            backendStore.quotaStatus = "Could not read those values.";
            return;
        }
        // Fill in whichever of the three the user left out.
        let used = usedBytes, remaining = remBytes, total = totBytes;
        if (total >= 0 && used >= 0 && remaining < 0) remaining = Math.max(0, total - used);
        if (total >= 0 && remaining >= 0 && used < 0) used = Math.max(0, total - remaining);
        backendStore.recordQuota(used, remaining, "manual", "manual", total);
    }

    // Bare numbers are read as GB, which is how operators usually quote quota.
    function guessUnit(raw) {
        if (/[a-zA-Z兆]/.test(raw)) return String(raw).replace(/[^a-zA-Z兆]/g, "");
        return "GB";
    }

    function requestQuotaQuery() {
        const n = String(backendStore.quotaQueryNumber || "").trim();
        const t = String(backendStore.quotaQueryText || "").trim();
        if (!n || !t) { backendStore.quotaStatus = "Set the carrier query number and text first."; return; }
        if (!modems.length) { backendStore.quotaStatus = "No modem available."; return; }
        backendStore.quotaQueryPending = true;
        backendStore.quotaStatus = "Query sent to " + n + " — waiting for the reply…";
        backendStore.sendSms(n, t, (ok, msg) => {
            if (!ok) {
                backendStore.quotaQueryPending = false;
                backendStore.quotaStatus = "Query failed: " + msg;
            }
        });
    }

    // Fires at most once per month, and only while this month has no figure.
    function maybeAutoQuotaQuery() {
        if (!backendStore.quotaAutoQuery) return;
        if (backendStore.quotaIsCurrentMonth()) return;
        if (backendStore.quotaQueryPending) return;
        if (!modems.length || smsSending) return;
        const month = backendStore.quotaMonth();
        if (backendStore.lastAutoQueryMonth === month) return;
        if (!String(backendStore.quotaQueryNumber || "").trim()) return;
        if (!String(backendStore.quotaQueryText || "").trim()) return;
        backendStore.lastAutoQueryMonth = month;
        backendStore.saveQuotaSettings();
        backendStore.requestQuotaQuery();
    }

    // ═════════════════════════════════════════════════════════════════════
    // SMS via mmcli
    // ═════════════════════════════════════════════════════════════════════

    function getModemId() {
        if (!modems.length) return "";
        return modems[0].id;
    }

    // path -> 已解析的短信。原先每 30 秒给每条存量短信各起一个
    // mmcli（23 条 = 23 个进程一轮），现在终态的短信直接用缓存，只查新的
    // 和还在发送中的。
    property var smsDetailCache: ({})

    function smsStateSettled(state) {
        const s = String(state || "").toLowerCase();
        return s === "received" || s === "sent" || s === "stored";
    }

    function loadSmsList() {
        const id = getModemId();
        if (!id) return;
        Proc.runCommand(commandPrefix + ".sms.list", ["mmcli", "--modem", id, "--messaging-list-sms", "--output-json"], (output, code) => {
            if (code !== 0) { backendStore.smsMessages = []; return; }
            try {
                if (!output) throw new Error("empty response");
                const data = JSON.parse(output);
                // mmcli flattens the object path into the key: {"modem.messaging.sms": [...]}
                const smsPaths = data["modem.messaging.sms"] || data["sms"] || [];
                if (!smsPaths.length) {
                    backendStore.smsDetailCache = {};
                    backendStore.smsMessages = [];
                    backendStore.recomputeUnread();
                    backendStore.smsListUpdated();
                    return;
                }

                const cache = {};
                const old = backendStore.smsDetailCache || {};
                const listed = {};
                smsPaths.forEach((p) => { listed[p] = true; });
                // 模组上已被删除的，从缓存里剔掉（历史台账里仍留着）
                Object.keys(old).forEach((p) => { if (listed[p]) cache[p] = old[p]; });
                backendStore.smsDetailCache = cache;

                const publish = () => {
                    // read 由"最新已读键"算出，不能跟着缓存冻住：
                    // 用户刚在面板里标了已读，这一拍就得变灰。
                    const found = smsPaths.map((p) => cache[p]).filter(Boolean).map((m) => Object.assign({}, m, {
                        read: isSmsRead(m.number, m.text, m.timestamp, m.pduType)
                    }));
                    found.sort((a, b) => (b.timestamp || "").localeCompare(a.timestamp || ""));
                    backendStore.smsMessages = found;
                    backendStore.importSmsToHistory(found);
                    backendStore.recomputeUnread();
                    backendStore.smsListUpdated();
                };

                // 只有"没见过的"和"状态还没落定的"才值得再起一个 mmcli
                const stale = smsPaths.filter((p) => {
                    const hit = cache[p];
                    return !hit || !smsStateSettled(hit.state);
                });
                if (!stale.length) { publish(); return; }

                let pending = stale.length;
                stale.forEach((path) => {
                    const smsId = backendStore.modemId(path);
                    Proc.runCommand(backendStore.commandPrefix + ".sms." + smsId, ["mmcli", "--sms", smsId, "--output-json"], (smsInfo, smsCode) => {
                        if (smsCode === 0) {
                            try {
                                const smsData = (smsInfo ? JSON.parse(smsInfo).sms : null) || {};
                                // number/text live under "content"; state/timestamp under "properties".
                                const content = smsData.content || {};
                                const props = smsData.properties || {};
                                cache[path] = {
                                    path: path,
                                    number: clean(content.number || props.number || ""),
                                    text: clean(content.text || props.text || ""),
                                    timestamp: backendStore.normalizeStamp(clean(props.timestamp || "")),
                                    state: clean(props.state || ""),
                                    pduType: clean(props["pdu-type"] || ""),
                                    isSubmit: clean(props["pdu-type"] || "") === "submit"
                                };
                            } catch (e) {}
                        }
                        if (--pending === 0) publish();
                    });
                });
            } catch (e) {
                backendStore.smsMessages = [];
                backendStore.recomputeUnread();
            }
        });
    }

    // mmcli's --messaging-create-sms takes one key=value property string, and
    // values containing spaces/commas must be double-quoted with escapes.
    function smsPropertyString(number, text) {
        function q(v) {
            return '"' + String(v).replace(/\\/g, "\\\\").replace(/"/g, '\\"') + '"';
        }
        return "number=" + q(number) + ",text=" + q(text);
    }

    function sendSms(number, text, done) {
        if (!number || !text) return;
        smsSending = true;
        smsStatusMessage = "";
        const id = getModemId();
        if (!id) {
            smsSending = false;
            smsStatusMessage = "No modem available";
            if (done) done(false, "No modem available");
            return;
        }
        const props = smsPropertyString(number, text);
        Proc.runCommand(commandPrefix + ".sms.create", ["mmcli", "--modem", id, "--messaging-create-sms=" + props, "-J"], (output, code) => {
            if (code !== 0) {
                backendStore.smsSending = false;
                backendStore.smsStatusMessage = "Failed to create SMS: " + output.trim();
                if (done) done(false, output.trim());
                return;
            }
            let smsPath = "";
            try {
                smsPath = ((JSON.parse(output).modem || {}).messaging || {})["created-sms"] || "";
            } catch (e) {
                smsPath = "";
            }
            if (!smsPath) {
                backendStore.smsSending = false;
                backendStore.smsStatusMessage = "Modem did not return an SMS path";
                if (done) done(false, "No SMS path");
                return;
            }
            Proc.runCommand(backendStore.commandPrefix + ".sms.send", ["mmcli", "--sms", smsPath, "--send"], (sendOut, sendCode) => {
                backendStore.smsSending = false;
                if (sendCode === 0) {
                    backendStore.smsStatusMessage = "SMS sent";
                    backendStore.recordSentSms(number, text);
                    if (done) done(true, "SMS sent");
                    smsReloadTimer.restart();
                } else {
                    backendStore.smsStatusMessage = "Send failed: " + sendOut.trim();
                    if (done) done(false, sendOut.trim());
                }
            });
        });
    }

    function deleteSms(path, done) {
        const id = backendStore.modemId(path);
        if (!id) return;
        Proc.runCommand(commandPrefix + ".sms.delete." + id, ["mmcli", "--sms", id, "--delete"], (output, code) => {
            if (code === 0) {
                backendStore.loadSmsList();
                if (done) done(true, "Deleted");
            } else {
                if (done) done(false, output.trim());
            }
        });
    }

    // ═════════════════════════════════════════════════════════════════════
    // VOICE CALLS via mmcli
    // ═════════════════════════════════════════════════════════════════════

    function dialCall(number) {
        if (!number) return;
        const id = getModemId();
        if (!id) { errorMessage = "No modem available"; return; }
        busy = true; pendingAction = "dial"; errorMessage = "";
        // ModemManager takes one key=value properties string, not separate flags.
        Proc.runCommand(commandPrefix + ".voice.create", ["mmcli", "--modem", id, "--voice-create-call=number=" + number], (output, code) => {
            if (code !== 0) {
                backendStore.finish(false, "dial", "", "Failed to create call: " + output.trim());
                return;
            }
            // Plain-text response: "Successfully created new call: /org/.../Call/1"
            const match = /(\/org\/freedesktop\/ModemManager1\/Call\/\d+)/.exec(output);
            if (!match) {
                backendStore.finish(false, "dial", "", "Modem did not return a call path");
                return;
            }
            const callPath = match[1];
            backendStore.callPath = callPath;
            backendStore.callNumber = number;
            Proc.runCommand(backendStore.commandPrefix + ".voice.start", ["mmcli", "--call", callPath, "--start"], (dialOut, dialCode) => {
                backendStore.busy = false;
                if (dialCode === 0) {
                    backendStore.callState = "dialing";
                    backendStore.statusMessage = "Calling " + number;
                } else {
                    backendStore.callState = "";
                    backendStore.callNumber = "";
                    backendStore.callPath = "";
                    backendStore.errorMessage = "Call failed: " + dialOut.trim();
                }
                backendStore.callStateChanged();
            });
        });
    }

    function answerCall() {
        if (!callPath) return;
        Proc.runCommand(commandPrefix + ".voice.accept", ["mmcli", "--call", callPath, "--accept"], (output, code) => {
            if (code === 0) {
                backendStore.callState = "active";
                backendStore.statusMessage = "Call active";
            } else {
                backendStore.errorMessage = "Answer failed: " + output.trim();
            }
            backendStore.callStateChanged();
        });
    }

    function hangUp() {
        if (!callPath) return;
        Proc.runCommand(commandPrefix + ".voice.hangup", ["mmcli", "--call", callPath, "--hangup"], (output, code) => {
            backendStore.callState = "";
            backendStore.callNumber = "";
            backendStore.callPath = "";
            backendStore.statusMessage = code === 0 ? "Call ended" : "Hangup failed";
            backendStore.busy = false;
            backendStore.callStateChanged();
        });
    }

    // ═════════════════════════════════════════════════════════════════════
    // GPS / LOCATION via mmcli
    // ═════════════════════════════════════════════════════════════════════

    function enableLocation(enable) {
        const id = getModemId();
        if (!id) return;
        gpsEnabled = enable;
        if (enable) {
            Proc.runCommand(commandPrefix + ".gps.enable." + id, ["mmcli", "--modem", id, "--location-enable-gps-raw"], (output, code) => {
                if (code === 0) {
                    backendStore.gpsEnabled = true;
                    backendStore.refreshLocation();
                } else {
                    backendStore.gpsEnabled = false;
                    backendStore.errorMessage = "GPS enable failed: " + output.trim();
                }
            });
        } else {
            Proc.runCommand(commandPrefix + ".gps.disable." + id, ["mmcli", "--modem", id, "--location-disable-gps-raw"], (output, code) => {
                backendStore.gpsEnabled = false;
                backendStore.gpsFixAvailable = false;
            });
        }
    }

    function refreshLocation() {
        const id = getModemId();
        if (!id || !gpsEnabled) return;
        Proc.runCommand(commandPrefix + ".gps.location." + id, ["mmcli", "--modem", id, "--location-get", "--output-json"], (output, code) => {
            if (code !== 0) { backendStore.gpsFixAvailable = false; return; }
            try {
                const data = JSON.parse(output);
                const location = data.modem ? (data.modem.location || {}) : (data.location || {});
                const gps = location.gps || {};
                const lat = parseFloat(gps.latitude);
                const lon = parseFloat(gps.longitude);
                if (!isNaN(lat) && !isNaN(lon)) {
                    backendStore.latitude = lat;
                    backendStore.longitude = lon;
                    backendStore.altitude = parseFloat(gps.altitude) || 0;
                    backendStore.gpsSpeed = parseFloat(gps.speed) || 0;
                    backendStore.gpsAccuracy = parseFloat(gps["accuracy-horizontal"]) || 0;
                    backendStore.gpsTimestamp = clean(gps.utc || gps["utc-time"] || "");
                    backendStore.gpsFixAvailable = true;
                    backendStore.locationUpdated();
                } else {
                    backendStore.gpsFixAvailable = false;
                }
            } catch (e) {
                backendStore.gpsFixAvailable = false;
            }
        });
    }

    Timer {
        id: exportDelay
        interval: 900
        repeat: false
        onTriggered: backendStore.exportSmsToObsidian()
    }
}
