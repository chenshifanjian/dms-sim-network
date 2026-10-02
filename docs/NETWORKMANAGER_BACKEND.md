# NetworkManager 移动网络后端设计

## DMS 插件集成规范

实现必须遵循 [DankMaterialShell Plugin Development](https://danklinux.com/docs/dankmaterialshell/plugin-development)
中的组件、manifest、状态与调试约定。

### Manifest

`plugin.json` 使用 composite plugin 结构：

```json
{
  "id": "modemManager",
  "type": "composite",
  "capabilities": ["daemon", "control-center"],
  "components": {
    "daemon": "./Store.qml",
    "widget": "./ModemWidget.qml"
  },
  "settings": "./ModemSettings.qml",
  "startupCheck": "./StartupCheck.qml",
  "dependencies": ["mmcli", "nmcli"],
  "permissions": ["process", "settings_read", "settings_write"]
}
```

- `process` 用于执行 `nmcli` 和只读 `mmcli` 查询；
- `settings_read` / `settings_write` 只用于 modem 选择和 UI 偏好，不存 APN
  Profile；
- `dependencies` 与 `startupCheck` 负责在插件启用前报告缺失命令；
- manifest 的 `id` 、Settings 的 `pluginId` 和 reload/status 命令中的 ID 必须
  始终为 `modemManager`。

### Control Center 主组件

`ModemWidget.qml` 的根组件必须是 `PluginComponent`，并从 DMS 自动注入的
`pluginData`、`pluginService` 和 `pluginId` 取得插件上下文，不要重新声明这些
属性。Control Center 入口使用 DMS 提供的属性和信号：

- `ccWidgetIcon`：移动网络图标；
- `ccWidgetPrimaryText`：`SIM Network`；
- `ccWidgetSecondaryText`：运营商、接入制式或断开状态；
- `ccWidgetIsActive`：以 NetworkManager 的 WWAN/活动连接状态派生，不以
  ModemManager bearer 猜测；
- Control Center 展开内容才承载 modem 选择和 Profile 卡片。

DMS 的 widget surface 可能按 Bar 和屏幕创建多个实例。因此页面实例不是
数据权威：每次打开、执行操作或收到刷新信号后，都必须重读
NetworkManager。不得仅修改某个 QML 实例的本地布尔值来表示连接成功。

### Settings 组件

`ModemSettings.qml` 的根组件必须是：

```qml
PluginSettings {
    id: root
    pluginId: "modemManager"
    // 稳定的列表、结构化 Profile 表单和明确的 Save 操作
}
```

不能用普通 `Item` 、`Column` 或 `ScrollView` 作为 Settings 文件的顶层来替代
`PluginSettings`；页面内容作为它的子项。标准的简单偏好可用
`StringSetting`、`ToggleSetting` 和 `SelectionSetting`，但 APN Profile 是
NetworkManager 外部数据，必须使用自定义结构化表单、显式 Save 按钮和
NetworkManager CRUD，不能伪装成一组 `settingKey` 写入插件设置。

`pluginData` 只用来同步适合自动保存的 UI 偏好。Profile 编辑 draft 仅存在
页面生命周期内，点击 Save 后通过 NetworkManager 提交，不调用
`savePluginData()` 保存 APN Profile。

### 调试与加载

```sh
dms ipc call plugins reload modemManager
dms ipc call plugins status modemManager
dms ipc call plugins list
```

测试流程是在 DMS Settings 中扫描并启用插件，然后检查 shell 日志和
`nmcli` 实际状态。热加载后也必须能从 NetworkManager 重建界面状态。

## 目标与边界

插件使用 NetworkManager 统一管理移动网络连接。一个 APN Profile 就是一个
持久化的 `connection.type=gsm` NetworkManager 连接，不是插件私有对象，也不是
ModemManager 的临时 bearer。

职责划分：

| 操作 | 唯一负责人 |
| --- | --- |
| Profile 创建、修改、删除和持久化 | NetworkManager / `nmcli connection` |
| Profile 启用、切换、停用 | NetworkManager / `nmcli connection up` + `nmcli device disconnect` |
| WWAN 总开关 | NetworkManager / `nmcli radio wwan` |
| 当前活动连接与 APN | NetworkManager |
| Modem、SIM、信号、注册状态和接入制式 | ModemManager / `mmcli`（只读） |
| Bearer 创建与销毁 | NetworkManager，插件不得直接处理 |

插件不得再调用 `mmcli --simple-connect`、`--simple-disconnect`，也不得手动删除
bearer。NetworkManager 激活 GSM Profile 时会经由 ModemManager 完成底层操作。

### ModemManager 严格只读约束

插件允许调用的 `mmcli` 操作仅限查询，例如：

```sh
mmcli --list-modems --output-json
mmcli --modem MODEM_ID --output-json
mmcli --sim SIM_ID --output-json
mmcli --bearer BEARER_ID --output-json
```

最后一条仅用于诊断展示现有 bearer，不能据此修改或删除 bearer。以下类型的
ModemManager 操作在插件中全部禁止：

- 创建、连接、断开或删除 bearer；
- `--simple-connect`、`--simple-disconnect`；
- enable、disable、reset modem；
- 修改 allowed/preferred mode、band、网络注册或 SIM 状态；
- 发送 PIN/PUK、修改 SIM PIN；
- 任何以“先让 mmcli 断开，再让 nmcli 连接”为形式的混合流程。

即使 NetworkManager 激活失败，插件也只能显示 NetworkManager 的错误并允许用户
修改或重试 Profile，不能绕过 NetworkManager 直接调用 ModemManager 建立连接。

## Profile 标识与接口独立性

- 内部唯一标识必须是 `connection.uuid`。
- `connection.id` 是显示名称；插件要求 GSM Profile 名称唯一，但修改、
  删除和启用仍必须使用 UUID。
- 插件创建的 Profile 默认不绑定 modem、SIM、运营商或接口。
- 设置页展示全部 NetworkManager GSM Profile，不按 modem 分组或过滤。

`connection.interface-name=cdc-wdm0` 不是可靠的持久身份。接口名可能改变；新建
Profile 使用 nmcli 的 `ifname "*"` 创建接口无关配置。这里的 `*` 会被 nmcli
解释为“不设置 `connection.interface-name`”，读回时应为空/`--`，不是把星号
作为接口名保存。需要指定本次激活设备时，可给 `nmcli connection up` 传具体
`ifname`，但不得顺便修改 Profile 的持久属性。

ModemManager 的 `/Modem/0`、`/Modem/1` 等编号只用于一次刷新内定位对象，不能
写入 Profile。因此 modem 编号变化不会影响保存的 Profile。

NetworkManager 中已有的 GSM Profile 可能包含 `gsm.device-id`、`gsm.device-uid`、
`gsm.sim-id` 或 `gsm.sim-operator-id`。插件遵守以下规则：

- 不在前端提供这些绑定字段；
- 不自行判断这些字段与当前 modem 是否兼容；
- 修改 APN 等受支持字段时不写入、清空或覆盖这些已有字段；
- 激活是否兼容完全以 NetworkManager 的结果为准；
- 激活失败时显示 NetworkManager 错误，不调用 ModemManager 绕过限制。

### Modem Device selection

NetworkManager 没有独立的全局“active modem”配置。当前 modem 是 GSM Profile
激活后产生的运行状态，而不是预先保存的 NetworkManager 设置。

插件始终选择一个具体 modem，不提供 `Auto`：

- 未检测到 modem 时没有选择，Profile 只能编辑，不能启用或停用；
- 只检测到一个 modem 时自动选中它，并隐藏选择器；
- 检测到多个 modem 时显示全部 modem，必须选中其中一个；
- 选择保存稳定的 modem device ID，不保存 `/Modem/N` 或接口名；
- 已保存选择仍然存在时恢复该设备；
- 已保存设备消失时自动选择当前列表的第一个 modem，并提示用户；
- 所有手动 Profile 启用操作都传入所选 modem 当前的 `ifname`；
- 设备选择是插件 UI 偏好，不是 Profile 绑定，也不是活动连接状态。

三个概念必须分开：

| 概念 | 存储位置 | 含义 |
| --- | --- | --- |
| Selected Modem Device | 插件设置 | Profile 操作当前针对的设备 |
| Profile 中已有的设备限制 | NetworkManager Profile | 由 NetworkManager 管理，插件不编辑 |
| Active GSM device | NetworkManager 运行状态 | 当前活动 GSM connection 实际使用的设备 |

设备下拉框决定 Profile 操作针对哪个 modem。手动激活始终传该 modem 的具体
`ifname`，但绝不能隐式改写任何 Profile 持久属性。

### 每个 modem 的 Active Profile

插件可以显示每个 modem 当前承载的 Active Profile，但这个映射只来自
NetworkManager 运行状态：

```text
active connection DEVICE -> modem 当前接口
active connection UUID   -> Profile UUID
```

例如 `cdc-wdm0 -> Profile A`、`cdc-wdm1 -> Profile B`。后端通过
`connection show --active` 的 `UUID,TYPE,DEVICE` 建立映射，只处理 `TYPE=gsm`。
没有活动 GSM connection 的设备，其 Active Profile 为空。

用户为指定 modem 手动切换 Profile 时执行：

```sh
nmcli connection up uuid PROFILE_UUID ifname MODEM_INTERFACE
```

插件不保存 `activeProfileByModem`，也不能把上次 UI 选择伪装成 Active 状态。
“当前 Active Profile”和“重启后的默认 Profile”必须分开：

- 当前切换由 `connection up ... ifname ...` 完成；
- 重启、拔插或 radio 恢复后的选择由 NetworkManager autoconnect 完成；
- 重启后的默认选择只使用 NetworkManager 已有的 Profile 条件、autoconnect 和
  priority，插件不增加自己的每设备规则；
- 插件不得在启动时读取自建映射并主动重连，以免与 NetworkManager 竞争。

## 自动连接与重连

自动连接完全由 NetworkManager 决定。插件保存以下属性：

- `connection.autoconnect`：是否允许该 Profile 自动激活；
- `connection.autoconnect-priority`：多个可用 GSM Profile 的优先级，数值越大
  越优先；
- `connection.autoconnect-retries`：失败后的尝试次数，第一版保留
  NetworkManager 默认值 `-1`。

系统启动、modem 插入、WWAN radio 重新打开或设备恢复可用时，NetworkManager
自行从可用且允许自动连接的 Profile 中选择并激活。插件不保存“上次 bearer”，
也不在启动时主动执行 `connection up`。

当多个 Profile 都兼容时：

1. NetworkManager 排除 `connection.autoconnect=no` 或不适用的 Profile；
2. 优先使用较大的 `connection.autoconnect-priority`；
3. 相同优先级的最终选择交给 NetworkManager，插件不复制其内部选择算法；
4. 前端将活动 UUID 标记为 Active，但不能把“当前下拉选中项”误当成活动连接。

用户点击非活动 Profile 卡片时调用
`nmcli connection up uuid UUID ifname SELECTED_INTERFACE`。这是一次明确的手动
激活，但不会隐式修改 `connection.autoconnect` 或任何 Profile 属性。若用户希望
下次自动使用该 Profile，应在编辑页单独打开“自动连接”，必要时提高优先级。

关闭 WWAN radio 只改变全局 radio 状态，不删除、禁用或改写任何 Profile。
重新打开后，NetworkManager 可以根据上述规则自动恢复连接。

## Control Center 交互

Control Center 只承担快速选择和连接：

```text
SIM Network                            Add  Settings
Modem Device: modem A / modem B            # 多设备时显示

┌─────────────────────────────────────────┐
│ ● Profile A                   Connected │
│   cbnet                                 │
└─────────────────────────────────────────┘
┌─────────────────────────────────────────┐
│   Profile B                             │
│   cmnet                                 │
└─────────────────────────────────────────┘
```

- 不提供独立的 Activate 或 Disconnect 按钮；
- 点击非活动 Profile 卡片，在所选 modem 上激活该 Profile；
- 点击已连接 Profile 卡片，断开所选 modem；
- 已连接卡片使用强调色 border，右侧只显示 `Connected`，不显示“点击断开”；
- 正在激活的卡片显示 `Connecting…`，正在断开的卡片显示
  `Disconnecting…`，操作期间禁止重复点击；
- 激活失败时保留真实 Active 标记，并在目标卡片下显示 NetworkManager 错误；
- 添加入口位于 Control Center 展开页标题栏右上角，不在 Profile 列表底部插入表单；
- 添加入口打开独立轻量弹窗，包含名称、自动 APN、APN、用户名、密码、漫游和自动
  连接；优先级、计费模式、Network ID 与 MTU 等高级字段仍在 Settings 中编辑；
- 添加成功后刷新并选中新 Profile，但不自动激活；
- Control Center 不提供编辑和删除，完整管理只放在 Settings。

## 设置页结构

设置页不按 modem 建立多层 Profile 树，只围绕一个有效设备展示状态：

```text
SIM Network
├── WWAN radio
├── Modem Device: modem A / modem B         # 仅多个设备时显示
├── 当前实际设备 / 连接状态 / 活动 Profile
├── saved profile 1（点击连接/断开、编辑、删除）
├── saved profile 2（点击连接/断开、编辑、删除）
└── 添加 Profile
```

Profile 列表展示所有 NetworkManager GSM Profile：

- 不按设备、SIM 或运营商分组和过滤；
- 不根据插件推断结果禁止 Profile 卡片点击；
- NetworkManager 已有但包含设备限制的 Profile 仍然正常显示；
- 如果所选 modem 不适用，点击启用后展示 NetworkManager 返回的错误；
- Connected 状态依据所选 modem 的 `DEVICE -> UUID` 映射；切换 Modem
  Device 后，Profile 列表不变，但高亮 border 和 `Connected` 标记切换到
  该 modem 当前使用的 Profile；
- 点击某个非活动 Profile 卡片只切换所选 modem，不应主动停用其他 modem；
- “停用”只对所选 modem 当前的活动 UUID 执行。

Settings 中使用与 Control Center 相同的卡片交互，不放独立 Activate 或
Disconnect 按钮。非活动 Profile 卡片点击激活；已连接 Profile 卡片点击断开，
并用强调色 border 和 `Connected` 表示状态。编辑和删除图标必须消费点击
事件，不能冒泡触发连接或断开。

编辑页面必须有明确的“保存”按钮。编辑操作修改原 UUID，不能创建一个新的
Profile。删除活动 Profile 时，先停用；只有停用成功后才删除。

### 前端页面状态

设置页不能直接以异步查询结果拼接临时 QML 节点。页面持有稳定的模型：

```text
SettingsModel
├── modems[]
├── selectedModemId
├── selectedModem
├── profiles[]
├── activeConnections[]
├── activeProfileByDevice{}  # 由 activeConnections[] 派生，不持久化
├── radioEnabled
├── loading
├── operationByUuid{}
└── pageError
```

- `modems[]` 来自 ModemManager 只读查询；
- `profiles[]` 和 `activeConnections[]` 来自 NetworkManager；
- `activeProfileByDevice` 由活动 GSM connection 的 `DEVICE -> UUID` 实时派生；
- `selectedModemId` 是插件唯一需要保存的设备选择偏好；
- `selectedModem` 是稳定 ID 匹配到的当前设备；有设备时必须非空；
- 刷新完成后一次性替换模型，刷新过程中保留上一次成功内容；
- Profile 行使用 UUID 作为 key；
- 一个 Profile 的保存/启用/删除只禁用该行，不应让整个设置页消失；
- 页面再次可见时刷新，但不能在每次属性变化时递归发起刷新。

### Profile 编辑草稿

打开新增或编辑页面时创建独立 draft，输入过程不能直接修改已加载 Profile：

```text
ProfileDraft
├── uuid                 # 新增时为空
├── name
├── apn / autoConfig
├── username
├── password + passwordChanged
├── allowRoaming
├── autoconnect / autoconnectPriority / metered
├── networkId
└── mtu
```

点击“取消”丢弃 draft；点击“保存”先前端校验，再提交一个完整的结构化对象给
NetworkManager 后端。后端返回成功并读回相同 UUID 后，才关闭编辑器。失败时
保留 draft 和输入内容，并在编辑器内显示原始 `nmcli` 错误。

新增和编辑必须走两个明确分支：

- `uuid` 为空：创建新 Profile；
- `uuid` 非空：修改该 UUID；

不能通过名称判断新增/修改，也不能通过“删除旧 Profile 再新建”实现编辑。

## 字段映射

### 基本字段

| 前端字段 | NetworkManager 属性 | 行为 |
| --- | --- | --- |
| 名称 | `connection.id` | 仅显示名称 |
| APN | `gsm.apn` | 关闭自动配置时必填 |
| 自动运营商配置 | `gsm.auto-config` | 从移动宽带运营商数据库选择 APN/认证信息 |
| 用户名 | `gsm.username` | 可选 |
| 密码 | `gsm.password` | 可选 secret |
| 允许漫游 | `!gsm.home-only` | `home-only=yes` 表示禁止漫游 |
| 自动连接 | `connection.autoconnect` | 布尔值 |
| 自动连接优先级 | `connection.autoconnect-priority` | 整数 |
| 按流量计费 | `connection.metered` | unknown/yes/no |

启用 `gsm.auto-config` 时，前端禁用手动 APN、用户名和密码输入。不能同时保存
“自动配置”和一组看起来正在生效的手动配置。

### 高级字段

| 前端字段 | NetworkManager 属性 | 说明 |
| --- | --- | --- |
| 强制注册网络 | `gsm.network-id` | MCC+MNC，高级设置 |
| MTU | `gsm.mtu` | 空值/0 表示自动 |

`gsm.network-id` 会影响网络注册，不等同于普通的运营商标签，不能根据当前运营商
名称自动填写。

### Password 处理

- `gsm.password-flags` 控制 password 的存储方式。
- `nmcli connection show` 返回 `<hidden>` 或空值时，前端不能把它当成真实空值。
- 编辑时密码留空表示“不修改”；清除密码必须使用单独的明确动作。
- 日志不能输出 APN 密码。

### 明确不提供的字段

- IPv4/IPv6 method、DNS、route 和 route metric；
- 普通 APN Authentication Type；NetworkManager 的 GSM setting 没有对应的通用
  PAP/CHAP 属性，不能错误映射 PPP 或 initial EPS 选项；
- SIM PIN；它属于 SIM 解锁，不是 APN；
- `gsm.device-id`、`gsm.device-uid`、`gsm.sim-id`、`gsm.sim-operator-id`；
- `gsm.number`、`serial` 和 `ppp`；
- 全部 `gsm.initial-eps-bearer-*` 字段。

新建时这些字段完全交给 NetworkManager 默认值；编辑现有 Profile 时使用选择性
`connection modify`，不得清空或覆盖未提供的字段。

## 后端命令约定

所有已有 Profile 的变更都按 UUID 操作。实现必须把每个值作为独立进程参数传入，
不得把用户输入拼成 shell 命令。

### 前后端接口

`Store.qml` 作为 DMS daemon surface 常驻，并持有 NetworkManager/ModemManager
查询得到的唯一运行时状态。Control Center 与 Settings 只绑定该 Store，不创建各自的
查询后端。QML 页面不直接组织 `nmcli` 参数。NetworkManager 后端提供以下逻辑接口：

| 接口 | 输入 | 成功结果 |
| --- | --- | --- |
| `refresh()` | 无 | modem、Profile、活动连接和 radio 快照 |
| `createProfile(draft)` | 结构化 draft | 新 Profile 的 UUID 和读回数据 |
| `updateProfile(uuid, draft)` | UUID、结构化 draft | 同一 UUID 的读回数据 |
| `activateProfile(uuid, device?)` | UUID、可选目标设备 | 活动连接快照 |
| `deactivateProfile(uuid)` | UUID | 更新后的活动连接快照 |
| `deleteProfile(uuid)` | UUID | 更新后的 Profile 列表 |
| `setWwanRadio(enabled)` | 布尔值 | 实际 radio 状态 |

每次响应至少包含：

```text
success
operation
uuid
exitCode
message
```

失败响应必须保留 `nmcli` 的 stderr/stdout 文本供界面显示和日志诊断，但要过滤
密码和 PIN。前端不得通过匹配英文成功字符串判断结果，只认进程退出码和后续读回。

后端的唯一写通道是 `nmcli`/NetworkManager。即使 `refresh()` 同时读取
ModemManager，任何 mutation 接口都不能执行 `mmcli`。

### 枚举

```sh
LC_ALL=C nmcli --terse --escape yes \
  --fields UUID,NAME,TYPE,DEVICE,AUTOCONNECT connection show
```

只保留 `TYPE=gsm`，再按 UUID 查询编辑页需要的明确字段。禁止解析本地化的
`nmcli connection edit -> print` 对齐文本。后端统一设置 `LC_ALL=C`，使用
`--terse`、`--escape yes` 和显式字段列表。

第一条列表查询只负责取得 UUID。每个 UUID 的详情至少读取：

```text
connection.id
connection.uuid
connection.type
connection.interface-name
connection.autoconnect
connection.autoconnect-priority
connection.autoconnect-retries
connection.metered
gsm.auto-config
gsm.apn
gsm.username
gsm.password-flags
gsm.home-only
gsm.network-id
gsm.mtu
```

字段缺失必须按“当前 NetworkManager 版本不支持”处理，不能导致整个 Profile 列表
解析失败。后端应保存一个 capability 集合，让前端隐藏或禁用不受支持的高级字段。

### 创建

创建或重命名前，先枚举 `NAME,UUID,TYPE`。若存在另一个 `TYPE=gsm`
且名称完全相同的 Profile，立即返回表单错误，不执行创建或修改。

```sh
nmcli connection add type gsm ifname "*" con-name PROFILE_NAME \
  gsm.apn APN
```

`ifname "*"` 表示接口无关。创建成功后必须读回并确认
`connection.interface-name` 为空；如果读回为字面量 `*` 或具体接口，视为创建
验证失败。

不传入 `connection.uuid`，由 NetworkManager 生成 UUID。因为插件已经确保名称
唯一，创建成功后可以按 `connection.id` 查询刚创建的 UUID，再用
`connection modify uuid UUID` 写其余字段。如果第二步
失败，应显示“Profile 已创建但配置未完成”并允许用户删除，不能静默新建第二份。

### 修改

```sh
nmcli connection modify uuid UUID \
  connection.id PROFILE_NAME \
  gsm.apn APN \
  gsm.auto-config no
```

只有用户明确执行“清除”时才给属性写空值。

### 启用与切换

存在 selected modem 时：

```sh
nmcli connection up uuid UUID ifname INTERFACE
```

没有 selected modem 时禁止启用。插件不提供省略 `ifname` 的手动激活路径。

后端不自行判断 Profile 与所选 modem/SIM 是否兼容。NetworkManager 拒绝激活时，
原样返回结构化错误；不能为了适配所选设备而修改 Profile。

只有命令成功退出，且 UUID 随后出现在 `connection show --active` 中，才能显示
启用成功。之后刷新 Profile、NM device 和 ModemManager 状态。

### 停用、删除和总开关

```sh
nmcli device disconnect INTERFACE
nmcli connection delete uuid UUID
nmcli radio wwan on
nmcli radio wwan off
```

WWAN 总开关和 Profile 激活状态是两个概念。关闭 WWAN 不会删除 Profile。

点击已连接 Profile 时，以所选 modem 的 interface 执行 `device disconnect`。
该操作只断开当前设备，不修改 Profile 的 `connection.autoconnect`。

## 当前状态

活动 Profile 必须以 NetworkManager 为准：

```sh
LC_ALL=C nmcli --terse --escape yes \
  --fields UUID,NAME,TYPE,DEVICE connection show --active

LC_ALL=C nmcli --terse --escape yes \
  --fields GENERAL.DEVICE,GENERAL.TYPE,GENERAL.STATE,GENERAL.CONNECTION device show
```

界面中的“当前 APN”来自活动 GSM UUID 对应的 `gsm.apn`。ModemManager bearer
信息只能作为诊断详情，不能覆盖 NetworkManager 的活动状态。

同一查询也用于建立每个 modem 的 Active Profile：以 `DEVICE` 找到当前 modem，
以 `UUID` 找到 Profile。该映射只存在于当前刷新快照中，不写入插件设置。

NetworkManager modem 接口提供的当前 `Apn` 可以作为交叉检查，但 UI 中 Profile
名称和配置 APN 仍从活动 UUID 对应的持久化 Profile 读取。若活动连接存在、但
Profile 的 APN 为空且启用了 auto-config，界面显示 NetworkManager 报告的当前
APN，并注明它是自动配置结果。

## 刷新、并发与错误

- 设置组件显示时刷新；创建、保存、启用、停用、删除完成后再次刷新。
- 刷新期间保留上一次成功的数据，避免 QML 列表消失或无法点击。
- 同一 UUID 的变更操作串行执行，操作期间禁用该行按钮。
- 必须检查进程退出码并展示 `nmcli` stderr，不能以“进程已启动”作为成功。
- 启用失败后保留 Profile，允许编辑和重试。
- 删除失败后恢复行状态，不得先从前端模型中永久移除。

## 完全重构与旧数据处理

本次实现不兼容旧的插件 Profile 数据，也不提供迁移：

- 不读取 DMS 中旧的 `apnProfiles`；
- 不读取或保存 `selectedApnByModem`；
- 不展示 Legacy profiles 或导入按钮；
- 不把旧 Profile 转换为 NetworkManager Profile；
- 不保留旧的 mmcli 连接路径作为 fallback；
- 不进行 NetworkManager 和插件 Store 双写。

新版本启动后只枚举 NetworkManager 已有的 `connection.type=gsm` Profile。用户
需要的 APN 若尚未存在，应直接在新设置页面中重新创建。

旧 QML 可以整体移除后按本文档的数据模型重写，不要求沿用原组件边界或状态结构。
需要保留的产品入口只有：

- DMS plugin manifest、Settings 入口和 Control Center capability；
- Control Center 的移动网络卡片与设置按钮；
- NetworkManager WWAN radio 控制；
- ModemManager 只读设备信息。

重构完成后，代码库中不应再出现以下运行时键或命令：

```text
apnProfiles
selectedApnByModem
mmcli --simple-connect
mmcli --simple-disconnect
```

## 验收测试

### Profile CRUD

1. 新建名称和 APN 均不同的两个 Profile，确认获得两个不同 UUID。
2. 修改其中一个 APN，确认 UUID 不变且另一个 Profile 不受影响。
3. 使用相同名称新建，或将另一个 Profile 改为已存在的名称，确认
   前端报重名错误且 NetworkManager 没有被修改。
4. 删除非活动 Profile，刷新和重新打开设置页后不再出现。
5. 删除活动 Profile，确认先停用后删除；停用失败时 Profile 仍存在。

### 启用与自动重连

1. 启用 Profile A，确认活动 UUID 是 A，而不是只检查 modem 显示 connected。
2. 启用 Profile B，确认 NetworkManager 完成切换且 A 不再活动。
3. 给 B 设置 `autoconnect=yes` 和更高 priority，执行 WWAN off/on，确认自动恢复 B。
4. 重启后确认 NetworkManager 自动激活兼容 Profile，插件启动过程没有主动调用
   `connection up`。
5. 将 `connection.interface-name` 留空后重复重启测试，确认不依赖 `cdc-wdm0`。
6. 新建 Profile 时传入 `ifname "*"`，确认读回的 `connection.interface-name` 为空。
7. 两个 modem 分别活动时，确认 `DEVICE -> UUID` 正确显示各自 Active Profile。
8. 手动切换其中一个 modem 的 Profile，确认另一个 modem 的 Active 映射不被
   前端错误覆盖。
9. 重启插件后确认 Active 映射完全从 NetworkManager 重建，没有读取插件缓存。

### Modem Device selection 与编号变化

1. 没有 modem 时确认 Profile 可以编辑但不能启用或停用。
2. 只有一个 modem 时确认自动选中该设备、选择器隐藏，激活命令包含其 `ifname`。
3. 准备两个 modem 或模拟两组稳定标识，确认选择器只显示两个具体设备，没有
   `Auto`。
4. 选择 modem B 后启用 Profile，确认命令使用 B 当前的接口名。
5. 确认设备选择不会修改任何 Profile 持久属性。
6. 选择 modem B 后移除它，确认选择切换到列表中第一个可用 modem，并显示提示；
   Profile 列表仍然存在。
7. 重启 ModemManager 使 `/Modem/N` 编号变化，确认已保存选择仍按稳定 device ID
   识别同一设备。
8. 接口名变化后，确认下次激活使用刷新后解析出的新接口名。
9. NetworkManager 中带已有设备限制的 Profile 仍显示；选错 modem 时由
   NetworkManager 拒绝激活，插件展示错误且不改写 Profile。

### 只读边界

测试期间记录插件启动的所有进程参数，确认：

- 所有 `mmcli` 命令都是查询；
- 所有 APN/Profile/radio mutation 都以 `nmcli` 开头；
- 不存在 `--simple-connect`、`--simple-disconnect`、bearer delete、modem enable、
  disable 或 reset；
- NetworkManager 操作失败时没有自动回退到 ModemManager 写操作。

## 官方参考

- [NetworkManager GSM 属性](https://www.networkmanager.dev/docs/api/latest/settings-gsm.html)
- [nmcli Profile 属性与格式](https://www.networkmanager.dev/docs/api/latest/nm-settings-nmcli.html)
- [NetworkManager Modem D-Bus 接口](https://networkmanager.dev/docs/api/latest/gdbus-org.freedesktop.NetworkManager.Device.Modem.html)
