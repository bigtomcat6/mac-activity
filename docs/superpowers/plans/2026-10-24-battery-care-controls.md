# Battery Care Controls Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在保留现有四页及其 UI 的前提下增加跨页电池保养两行控制区；只有通过逐设备、逐系统、逐操作准入的能力才能真实控制硬件。

**Architecture:** 一个 Foundation-only 电池控制模块承载值类型、纯策略、串行会话与语义协议，App 只负责意图、偏好和展示。第一阶段生产装配固定使用不可用服务，测试用可控时钟与模拟后端；以后经 gate 批准的 helper 才成为唯一生产策略／写入所有者，App 不另跑一份硬件策略。硬件适配、完成判据、签名注册及恢复实现必须先取得证据并补充实施计划，不能从本计划推导出未经验证的写操作。

**Tech Stack:** macOS 26 / arm64；Swift tools 6.2（现有 Xcode Swift language setting 为 6.0）、Foundation、SwiftUI/AppKit、XCTest、SwiftPM、XcodeGen；沿用 Sparkle，不增加第三方依赖。ServiceManagement / XPC / Security / IOKit 的生产控制用法属于独立技术准入。

**Spec:** [`docs/superpowers/specs/2026-10-24-battery-care-controls-design.md`](../specs/2026-10-24-battery-care-controls-design.md)，完整产品／行为设计及 C1–C7、D1–D8 已批准；V1–V4 未验证。

**Status:** 2026-10-24，仅计划修订。用户仅批准 A4 分期、A9 接线冒烟、A6 复用本地化检查三项精简；未授权实现、提交、安装、网络操作、执行应用或真实硬件测试，也未降低安全门槛。下列构建／测试命令是未来执行指引，本次未运行。A 阶段任务可在计划审阅及执行授权后实施；G/B 阶段另有明确授权及补充批准要求。

## Global Constraints

- 最低 macOS 26，当前仓库 arm64；不扩到 Intel、旧 macOS 或所有 Apple silicon 机型。
- 上限 **50%–100%**、步长 **1 个百分点**；**管理默认关闭，上限预填 80%**。滑条不隐式启用管理。
- 常规 50%–99% 固定 **5 个百分点回差**；100% 交还系统终充，不做 95%–100% 人工循环。
- 一次性放电只由明确手动动作启动，跟随已提交并接受的新上限，到目标结束；**≤20%** 是异常兜底，不是经认证的安全标准，也不替代有界停止证据。
- 临时充满与常规上限独立；完成／取消恢复最新常规，不自动放电；接受不同上限取消充满，原值提交和预览撤销不取消。
- 拔电、睡眠、退出结束临时模式并**请求**撤销自有控制；唤醒／再接电只在重新核验后恢复常规，故障后另需用户明确重试；退出不保证继续限充。
- 顶部固定两行跨 Overview / Actives / Energy Impact / Audio，保留原标题、导航、卡片、指标和图表；420 pt 基线宽度，560 pt 原预算加实测新增高度，再受屏幕限制。
- 控制只用经验证的系统百分比；图表硬件百分比偏好不改控制口径。未知、缺失、过期、矛盾不能折成 0、false 或“无电池”。
- 意图、接受、回读、物理效果四层分开；超时／部分写入／回读矛盾是结果未知，取消旧回调不等于撤销物理效果。
- 能力未证实逐项禁用；不编造 SMC key/value、满充 API、回执、支持名单或安全时限。仅 UI／stub 完成不等于真实限充、放电或充满完成。
- 不关闭系统优化充电，不与其他控制器抢写；不扩到自动放电、校准、温控、定时、快捷指令、MagSafe 或阻止睡眠。
- 本轮只修改本计划，spec 与产品／测试代码保持不动。未来执行先隔离已有工作；不自动 stash/reset/clean、删除用户文档或提交。提交／PR／合并均须另行明确授权，若合并遵循全局 squash 约定。

## Review Focus

1. **过期写／取消后迟到成功／迟到 UI 快照：** A4 在 backend 边界验证旧风险命令不执行、在途结果不能重启旧模式，A5 单独验证旧快照不覆盖新意图；两者不能互相替代。在途物理效果可能已发生时保留核对责任；helper 重启与真实故障恢复归 G3/G4/B0 后的 B1。
2. **混合电源和时间：** UPS 不能冒充内置电池，CPU 更新不能刷新电池样本年龄，冻结读数和唤醒前数据不能继续放电。测试归 A1–A5/A8；采集真实性归 G1/G3。
3. **存储失败和本地／服务端接受顺序：** 调限不能“显示已保存却未落盘”，拒权不能保存为已启用；关闭／停止即使保存失败也须立即提出撤销。测试归 A1、A5。
4. **跨用户／冒名客户端／升级中的恢复所有权：** 同 bundle ID 不够，合法签名也不等于本会话授权；恢复不能覆盖第三方新状态，升级卸载不能丢失唯一恢复依据。认证、wire、持久恢复的实现与对应负向测试一并经 G3/G4、B0 定案，归 B1/B2；A4 不预建这些机制或认证 fixture，不能只删必要安全测试却留下实现。
5. **两行高度与输入边界：** 长翻译、大文字、屏幕变化、宿主切换、拖动中关闭／切页不能裁掉取消入口或误提交；重复辅助功能动作不能产生写入风暴。测试归 A6/A7/A8。

---

## 0. 基线、工作边界与完成等级

所有后续相对路径和命令工作目录均为 **`/Users/how/Git/How/How/MacActivity/mac-activity`**（执行时替换成隔离 worktree 的产品根），不是其父工作区。spec 也实际位于产品仓库内。

只读核对基线：`d3e6e9f`，分支 `feat/energy-impact-part11-live-context`。当前未跟踪内容包括 `docs/2026-10-24-app-uninstall-and-residual-detection-design.md` 与 `docs/superpowers/`；这些不是可删除的生成物。本轮没有发现产品／工作区的 AGENTS.md 或 CLAUDE.md；遵循已提供的全局约定、`docs/development.md`、`docs/CONTRIBUTING.md`、`docs/release.md`。

已核对的实现事实：

- `BatteryProvider.swift:34–54` 会把缺失 isCharging 折为 false；`BatterySystemPowerSourceReader.swift:6–23` 取首个可解析电源，不证明内置电池身份。二者不能直接成为控制输入或满充检测器。
- `MetricsSnapshot.swift:260–310` 的 timestamp 随任意指标更新，电池没有独立采样序号；严禁用整个 snapshot 的时间判断电池新鲜度。原指标显示路径保持不变。
- `DashboardView.swift:651–680` 有根 header 与现有两种滚动路径；`DashboardPopoverController.swift` 汇总 header/headerDivider/scrollContent，再按 560 截断。panel 又受 `DashboardPanelPlacement` 限制，popover 也必须单独验证。
- `AppDelegate.swift:213–262` 已有异步退出及 audio/scheduler 收尾；现有 120 秒节能电池采样不提供控制停止保障。新增生命周期不能被窗口隐藏或慢速显示调度暂停。
- `Package.swift` 有 Core/App 和两套 XCTest；`project.yml` 现有四个 target。`platform_policy_test.py:23` **写死四个 target 的 deploymentTarget 数量**，新增 target 必须同步修正，不删除平台断言。
- `LocalizationTests.testEveryLocalizationKeyExistsInEveryBundledLocalization` 与 `testLocalizedFormatPlaceholdersMatchEnglish` 已遍历全部 Key／七种语言，A6 直接复用，不新增电池专属完整性清单。发布脚本目前显式重签 Sparkle 与 MacActivityCore，没有 helper 安装／升级协议。
- `PowerFlowModelTests.swift` 已示范注入单调时间、手动推进和可挂起响应；`AppSamplingControllerTests.swift` 已有真实协调器接底层 fake 的生命周期测试。沿用这些简单模式，不新建通用模拟／虚拟调度框架。

完成等级必须分别报告：

| 等级 | 必须成立 | 不得宣称 |
| --- | --- | --- |
| A：无硬件基础 | A1–A9 测试、双构建和 review 通过；生产能力为空，显示真实禁用原因 | 已实现可用限充／主动放电／临时充满 |
| G：准入证据 | 指定设备与操作授权、证据矩阵、技术决策、补充计划审批均闭合 | 一台通过等于全型号支持，或产品批准等于实验授权 |
| B：指定能力可用 | 对应 G 通过，补充计划的生产 helper/适配/部署验证与最终 review 通过 | 未验证的其他能力或所有故障下均恢复 |

依赖：`A1 → A2 → A3 → A4 → A5 → A6 → A7 → A8 → A9`。A2/A3 使用合成 context，A4/A9 的 backend 实现仅在 Tests 中；A5–A9 生产固定使用 Unavailable 服务。A9 的逻辑链依赖 A4 实现的真实 Session／Policy，不依赖延期的 wire、认证或恢复 journal。`G0 → G4 可行性 → G1/G3 → G2（仅充满） → B0 补充批准 → B1/B2 → B3` 是另一条受控路径；G 允许申请单独的研究原型计划，不允许绕过 B0 直接投产。限充也需 G1/G3/G4，不能仅跳过 G2 就无条件启用。

### 执行前隔离（不是现在执行）

- [ ] 用 `git status --short --untracked-files=all`、`git diff`、`git diff --cached`、`git worktree list`、`git log -5 --oneline` 记录基线；读取 using-git-worktrees 技能。
- [ ] 与用户确认实施基线，在新 worktree／分支中执行；不要在当前能源功能分支混写，不自动切换当前分支。未跟踪 spec/plan 不会随 worktree 自动出现，明确复制这两个获准文档并逐文件核对，不搬走或覆盖源文件，不顺带复制其他用户文件。
- [ ] 只核验已安装的 Xcode 26、Swift 6.2、XcodeGen及缓存依赖。project.yml最低要求2.45.0，CI安装脚本固定2.45.4，生成一致性使用已安装的2.45.4。缺少工具或缓存阻塞构建时报告，不运行brew/install、依赖下载或修改机器配置。

## 1. 文件边界与共同契约

### 文件归属

新增 `Sources/MacActivityBatteryControl/` 是一个小型共享模块，**不导入 AppKit、IOKit、Security、ServiceManagement 或 Sparkle**；用于未来 helper 与 App 共享语义且不把现有音频／清理 Core 载入特权进程。

| 文件／目录 | 职责、首次任务 |
| --- | --- |
| `Sources/MacActivityBatteryControl/BatteryCareModels.swift` | 设置、样本、能力、状态及结果值类型，A1 |
| `Sources/MacActivityBatteryControl/BatteryCarePolicy.swift` | 纯 reducer 和常规／临时策略，A2/A3 |
| `Sources/MacActivityBatteryControl/BatteryCareProtocol.swift` | 进程内语义服务／命令／backend 契约，无 wire codec 或认证类型，A4 |
| `Sources/MacActivityBatteryControl/BatteryCareSession.swift` | 调用真实 Policy 的串行所有者、代次／过期／幂等与未确认结果阻断，无持久恢复实现，A4 |
| `Sources/MacActivityBatteryControl/UnavailableBatteryCareService.swift` | 生产默认不具控制能力，不伪造回读，A5 |
| `Sources/MacActivityCore/Preferences/AppPreferences.swift`、`PreferencesController.swift` | 复用现有持久化，只保存常规意图，A1 |
| `Sources/MacActivityApp/Models/BatteryCareModel.swift` | MainActor 预览、提交、展示和服务代理，A5 |
| `Sources/MacActivityApp/Views/BatteryCareControlsView.swift`、`BatteryCareLimitSlider.swift`、`BatteryCareSettingsView.swift` | 两行、原生输入适配、轻量设置，A6 |
| `Sources/MacActivityApp/Views/DashboardView.swift`、`AppShell/DashboardPopoverController.swift` | 顶部插入、模型注入、测量、关闭预览，A6/A7/A8 |
| `Sources/MacActivityApp/AppShell/DashboardAdaptivePopoverHost.swift`、`DashboardPanelHost.swift`、`DashboardPanelSupport.swift` | 两种宿主高度、屏幕约束与内容视口一致，A7 |
| `Sources/MacActivityApp/AppShell/BatteryCareLifecycleBridge.swift`、`AppDelegate.swift` | A6完成App模型注入以保持编译，A8接sleep/wake/quit生命周期 |
| `Sources/MacActivityApp/Localization/AppLocalization.swift`、七个 `Resources/*.lproj/Localizable.strings` | 全部新文案／辅助功能名称，A6 |
| `Tests/MacActivityBatteryControlTests/` | 模型、纯策略与内存会话测试，A1–A4；简单模块级 fake backend，不包含 wire／认证／journal fixture |
| `Tests/MacActivityCoreTests/`、`Tests/MacActivityAppTests/` | 偏好、输入、布局、生命周期回归；A9 少量真实逻辑接线及局部底层 fake，具体文件见各任务 |
| `Package.swift`、`project.yml`、`MacActivity.xcodeproj/project.pbxproj`、`MacActivity.xcodeproj/xcshareddata/xcschemes/MacActivity.xcscheme` | 同一共享模块及测试 target，A1；Xcode 生成文件只经 XcodeGen 更新 |
| `.github/scripts/platform_policy_test.py`、`release_policy_test.py`、`scripts/install-local-release.command` | target 平台规则、新 framework 的签名清单，A1；不是安装许可 |

以下是计划中的新接口，不是声称仓库已有接口。所有跨 actor 值类型 Sendable；A 阶段仅持久化设置要求 Codable，非法设置解码失败而不是夹值。命令／结果是进程内语义值，不预定 JSON、包大小、协议版本、认证载荷或恢复记录格式；这些实现和测试一起留给 G4/B0（恢复依据另需 G1/G3）。纯 reducer 内部状态不直接接受客户端序列化输入。

### 值类型词汇（A1 定义，后续任务不得换名或混用）

- `BatteryCareSettings: Equatable, Codable, Sendable`：`isEnabled: Bool`、`limit: Int`；`init(isEnabled: Bool = false, limit: Int = 80) throws` 验证 50...100，`static let default` 为关闭/80。无 temporaryMode／preview 持久化字段。
- `BatteryCareIdentity`：`batteryID: String`、`modelIdentifier: String`、`osBuild: String`。`BatteryCarePresence` 为 `.internalBattery` / `.absent` / `.unknown`；读不到不能生成 absent。
- `BatteryCareSample`：`identity: BatteryCareIdentity?`、`presence: BatteryCarePresence`、`sequence: UInt64`、`observedAtUptime: UInt64`、`systemPercentage: Double?`、`externalPower: Bool?`、`isCharging: Bool?`、`lowBatteryProtection: Bool?`。最后一项仅为经验证来源的保护状态，不声明已有系统API。时间是采集端同一启动 epoch 下的单调纳秒，不是 UI Date；冻结序号不刷新观测时间。
- `BatteryCareOperation`：`.regularLimit` / `.manualDischarge` / `.temporaryFullCharge` / `.releaseOwnedControls`。每项能力是 `.unverified` / `.unsupported(reason: String)` / `.verified(recordID: String)`，由 helper 核对设备与发布记录，不从 UI、UserDefaults 或 CPU 名称授予。
- `BatteryCareSafetyLimits`：`sampleIntervalNanoseconds`、`maxSampleAgeNanoseconds`、`maxCommandAgeNanoseconds`、`maxReadbackNanoseconds`、`maxStopNanoseconds`、`leaseNanoseconds`、`maxTemporaryModeNanoseconds`、`maxNoProgressNanoseconds`，均为正的UInt64且相互关系经验证。生产未取得 G3 记录时为 nil；**不在 A 阶段填“合理默认硬件秒数”**。
- `BatteryCareCompletion`：`.unknown` / `.notComplete` / `.confirmed(recordID: String, sampleSequence: UInt64)`；生产 A 始终 unknown，测试可注入确认，但确认不能由客户端命令传入。
- `BatteryCareState` 分别持有 accepted settings、常规 confirmed phase（unknown/allowed/inhibited）、临时模式（none/discharging/chargingToFull）、generation、pending request、暂停原因和恢复状态；`BatteryCareTransition` 包含新 state 与有序 `[BatteryCareEffect]`。
- `BatteryCareEffect` 仅内部语义：`.allowCharging`、`.inhibitCharging`、`.startDischarge`、`.endTemporaryMode`、`.releaseOwnedControls`；不是公开任意硬件 API。
- `BatteryCareSnapshot` 分别携带 settings、sample、逐项 capabilities、authorization 状态、请求状态、readback 状态、physicalObservation、恢复状态及 generation/revision。`BatteryCareReply` 携带 requestID/generation/revision 和 accepted/rejected/outcomeUnknown，不设一个综合 success。
- 授权与恢复只保留策略／展示需要的语义状态：未获授权、恢复未知／未确认／冲突均阻断新风险操作，不能从 enabled 偏好推定就绪。A 的就绪／释放结果仅由底层测试输入给出；不定义 `BatteryCareOwnership`、认证身份 fixture、基线格式或 journal。首次写前有效基线、只恢复自有修改及重启核对仍是 G1/G3/G4 → B0 → B1/B2 的强制门槛。

## 2. 可直接细化执行的 A 阶段（无硬件写入）

每项按红 → 最小实现 → 绿 → review 执行。测试名称与断言表是必需覆盖，不要求把测试实现抄进计划。新增 XCTest 类名与文件名一致。以下 `swift test --filter` 命令使用本仓库 SwiftPM 布局；不能把“没有匹配到测试”当通过。边界矩阵留在责任层：A1 模型／偏好，A2/A3 表驱动策略，A4 串行与超时，A5 App contract，A6 控件，A7/A8 布局／生命周期；A9 不再逐项重放。复用简单注入时钟、手动 tick 和可挂起响应，不新增测试平台或共享模拟框架。

### A1：共享模型、偏好迁移与两套构建一致性

**Files:** Create `Sources/MacActivityBatteryControl/BatteryCareModels.swift`、`Tests/MacActivityBatteryControlTests/BatteryCareModelsTests.swift`。Modify 第 1 节列出的两个 Preferences 文件、四个构建文件、两个 Python policy tests 及 `scripts/install-local-release.command`。Test 另扩充 `Tests/MacActivityCoreTests/PreferencesStoreTests.swift`、`PreferencesControllerTests.swift`。

**Interfaces:** 产出共同契约值类型；`AppPreferences.batteryCare: BatteryCareSettings`（init 默认 `.default`）；`PreferencesController.setBatteryCareSettings(_ settings: BatteryCareSettings) throws`，先形成新 state，save 成功才发布；未获授权启用由 A5 拦截。旧偏好字段与现有音频 profile 不变。

- [ ] 先登记新库／测试target的目录与依赖以便发现新测试（仅构建接线，不实现业务），写失败测试：`testLimitsAcceptEveryInteger50Through100`；49/101、非整数序列化设置拒绝；`testMissingOrMalformedBatteryCareKeepsOtherPreferences` 验证旧 JSON 默认关闭/80、损坏 batteryCare 子字段只重置该子项；`testSaveFailureDoesNotPublishSettings` 注入 throwing store；round-trip 不包含临时会话／预览／“已生效”。
- [ ] 先运行 `swift test --filter 'BatteryCareModelsTests|PreferencesStoreTests|PreferencesControllerTests'`，记录缺失接口的失败；用内存 store／独立 suite，禁止 UserDefaults.standard。扩充平台测试使其先因缺少新 target 失败，而非删除原断言。
- [ ] 实现模型与偏好最小迁移。保留 `showsHardwareBatteryPercentage` 原样；编码／解码边界用同一校验器。UI 保存意图不是硬件接受回执。
- [ ] 完成双构建接线：SwiftPM 新增库 product/target `MacActivityBatteryControl` 和 testTarget `MacActivityBatteryControlTests`；Core 和 App 明确依赖库，CoreTests/AppTests 显式添加直接导入的库依赖。XcodeGen 新增同名 framework 与无 host 单测 target、macOS 26/arm64、库生成 Info.plist、唯一 bundle ID `com.how.macactivity.batterycontrol`，测试 ID 加 `.tests`；Core链接、App链接并嵌入共享framework，测试target补对应依赖，MacActivity scheme纳入新测试。未来helper不依赖整个Core。
- [ ] 更新平台 policy test：由写死 4 改为核验当前六个 target 的精确集合与全部 deploymentTarget=26.0；未来 B2 增 helper 时再次同步。发布重签清单加入 `Contents/Frameworks/MacActivityBatteryControl.framework`，先签 framework 后签外层 App，补 `release_policy_test.py` 静态断言，不运行签名或安装脚本。
- [ ] 运行同一 SwiftPM 过滤测试及 `python3 -B -m unittest discover -s .github/scripts -p 'platform_policy_test.py'`、同命令 `-p 'release_policy_test.py'`；随后 `xcodegen generate --quiet` 和第 4 节的 Xcode 定向测试。检查两种构建确实编译新 target；绿后独立 review 模型／迁移／项目映射。

### A2：常规限充纯策略

**Files:** Create `Sources/MacActivityBatteryControl/BatteryCarePolicy.swift`、`Tests/MacActivityBatteryControlTests/BatteryCarePolicyTests.swift`。

**Interfaces:** `BatteryCarePolicy.reduce(state: BatteryCareState, event: BatteryCareEvent, context: BatteryCareContext) -> BatteryCareTransition`。`BatteryCareContext` 包含 sample、capabilities、authorization、recoveryStatus、safetyLimits、completion、`nowUptime: UInt64`；按操作检查其准入前提（普通限充不要求满充证据），缺前提不得产出风险effect。授权／恢复状态在 A 中只是合成输入，不实现认证或恢复所有权判定。事件至少有settingsAccepted、sampleChanged、executionObserved、tick、lifecycle、retryRequested；A3扩充临时操作。tick配合注入now推进纯时限测试，不绑定真实定时器。

- [ ] 写表驱动失败测试，所有“有能力”上下文均为 Tests 内标注的合成记录：

  | 测试 | 必须断言 |
  | --- | --- |
  | `testDefaultAndEditingNeverEnableControl` | 关闭/80 或设置 60 不产生任何启动；无外电只保存意图 |
  | `testHysteresisUsesUnroundedSystemPercentage` | L=80：79.99 初建允许；80/80.01 请求停；确认停后 75.01 保持、75 允许；L=50 的回充点是45 |
  | `testBandKeepsOnlyConfirmedPhase` | 回读未确认不标阶段；同阶段不重复写；不能仅依 isCharging=false 推定是本应用停充 |
  | `testNewLimitRebuildsPhase` | 新 L 或生命周期重建时 p<L 允许、p≥L 停；提交同值不无故重建回差阶段 |
  | `testRegular100ReleasesRestrictionWithoutFullClaim` | p=95/100 都交系统终充，无回差循环、无 confirmed-full、无自动放电 |
  | `testInvalidInputFailsClosed` | NaN、Infinity、负数、>100、nil、旧／冻结样本、身份不符、能力或时限 nil 全部禁风险 effect |
  | `testPresenceIsNotInferredFromPercentage` | absent/unknown（含仅 UPS、未识别内置电池的合成 context）、无identity或不匹配的多源数据即使p有效也禁控制；不能因读数不存在断言无内置电池，真实识别仍归 G1 |
  | `testHardwareDisplayPreferenceCannotChangePolicy` | 同一系统 p 不因图表选择改变结果 |

- [ ] 运行 `swift test --filter BatteryCarePolicyTests` 确认红。
- [ ] 按 spec §6.2 实现 reducer；显示百分比与比较数值隔离，输入不截断、不四舍五入、不夹值；普通高于上限只停充，永不发 startDischarge。
- [ ] 重跑同命令及 `BatteryCareModelsTests` 至绿，review 每个边界和无效输入分支。

### A3：一次性临时模式、充满证据门槛与安全退出

**Files:** Modify `BatteryCareModels.swift`、`BatteryCarePolicy.swift`（均在 `Sources/MacActivityBatteryControl/`）。Create `Tests/MacActivityBatteryControlTests/BatteryCareTemporaryModeTests.swift`、`BatteryCareLifecyclePolicyTests.swift`。

**Interfaces:** A2 reducer 不变。`BatteryCareIntent` 定义 `.setManagement(Bool)`、`.setLimit(Int)`、`.startDischarge`、`.stopDischarge`、`.startFullCharge`、`.cancelFullCharge`、`.retryRegular`、`.releaseOwnedControls(reason: BatteryCareReleaseReason)`；无 setSMC、shell、设置任意 completion 等操作。`BatteryCareLifecycleEvent` 包含 unplugged/willSleep/didWake/pluggedIn/quit/connectionLost，窗口关闭不是该枚举的控制停止事件。

- [ ] 写失败测试：手动启动必须 enabled+外电+p>L+逐项准入+可靠恢复，无其他临时模式；到 p=L 停而非 L−5，结束后 p>L 不重启；预览不改目标，接受新 L 后 p≤L 立即停、p>L 仅本次继续，已发停止不能被降限撤销。
- [ ] 写 `testFullChargeKeepsRegularLimitAndCancelsOnlyOnDifferentAcceptedLimit`：80 保留，临时目标100；提交80不取消，提交85或100先结束覆盖；正常完成／取消不放电；同 L 退出确认后 p>75 停、p≤75 允许；不同 L 按新阈值重建；L=100 禁启动充满并解释原因。
- [ ] 写 `testDisplayed100AndStoppedChargingDoNotConfirmFull`，100%、零电流候选、不充电、优化充电暂停均不是 confirmed；只有匹配设备验证记录及本会话新鲜 sampleSequence 的注入完成证据才能完成。缺证据／过期／矛盾立即退出，不能等最长时限；有效但无进展／等待过期退出且不报完成。
- [ ] 写 `testLifecycleNeverResumesTemporaryMode`：拔电、睡眠、quit、关闭管理、断连及≤20或经验证保护信号均先失效继续意图并请求释放；唤醒丢弃旧样本、常规阶段及会话，仅核验后恢复常规；故障即便通信恢复也需retryRegular。对≤20.0、20.01及p>20但保护信号true分别断言；正常L≥50应更早停，低电条件解除不自动续跑。测试不向真实设备放电到20。
- [ ] 运行 `swift test --filter 'BatteryCareTemporaryModeTests|BatteryCareLifecyclePolicyTests'` 确认红；实现临时模式互斥、停止优先、退出确认后才能重建常规。时限全从 context 注入，测试值仅为虚拟时钟测试参数。
- [ ] 重跑 A2/A3 过滤测试至绿。review：完成与恢复两个事实分别成立，恢复失败时 effective target unknown；关闭窗口不破坏后台会话。

### A4：最小语义接口与可测试串行命令（无硬件后端）

**Files:** Create `Sources/MacActivityBatteryControl/BatteryCareProtocol.swift`、`BatteryCareSession.swift`；Create `Tests/MacActivityBatteryControlTests/BatteryCareSessionTests.swift`、`BatteryCareTestBackend.swift`。不创建 codec、认证或持久恢复文件／测试；相关生产边界见 B0/B1。

**Interfaces:**

- `BatteryCareServicing: Sendable`：`func send(_ command: BatteryCareCommand) async -> BatteryCareReply`、`func handleLifecycle(_ event: BatteryCareLifecycleEvent, generation: UInt64) async -> BatteryCareReply`、`func snapshot() async -> BatteryCareSnapshot`、`func updates() async -> AsyncStream<BatteryCareSnapshot>`。生命周期回复的 requestID 由服务生成；A5 通过同一接口提交意图、转发生命周期并接收结果，未来 XPC client 不另实现策略。
- `BatteryCareCommand` 仅含 `requestID: UUID`、`generation: UInt64`、`intent: BatteryCareIntent`，不要求 Codable，不是 wire DTO。入队时间由 Session 的 now 记录，风险命令按注入的 maxCommandAgeNanoseconds 在入队与执行前检查；跨进程时钟、epoch／连接身份及防重放协议留 B0。UI 不传入 sample、能力、completion 或恢复基线。
- `actor BatteryCareSession: BatteryCareServicing`：`init(backend: any BatteryCareBackend, now: @escaping @Sendable () -> UInt64)`，实现上述服务方法；另有 `func receive(_ event: BatteryCareEvent) async` 接收内部 sampleChanged／tick 等事件。它用注入 now 统一队列检查与 context.nowUptime，实际调用 A2/A3 reducer、串行执行 effect 并发布 snapshot，是 A9 复用的协调逻辑，不是独立测试策略。A 阶段只有 Tests 注入 backend，生产装配不实例化可执行会话。
- `BatteryCareBackend: Sendable`：`func observe() async -> BatteryCareContext`、`func apply(_ effect: BatteryCareEffect) async -> BatteryCareExecution`。Execution 分开返回 accepted、readback、physicalObservation、recoveryStatus；停止／释放也通过 effect 和同一队列。这里不暴露归属对象或基线写口；测试后端只提供观测、记录调用并控制响应，不决定阈值、取消优先级或状态迁移。真实后端与恢复证明在 B0 后共同设计和测试。

- [ ] 写语义入口红测试：越界 setLimit、未授权／能力未验证／恢复未就绪不调用风险 apply；代表性拒绝足够，不复制 A1–A3 全矩阵。当前代次重复 requestID 同意图不重复执行、不同意图拒绝；新意图／生命周期推进 generation 后旧代次拒绝，可清除其记录而不能重新执行。connectionLost 后恢复观测不重放旧请求，新建内存会话不恢复临时模式；不将此称为跨进程重启防重放证明。
- [ ] 写 `testExpiredRiskCommandNeverReachesBackend`：挂起前一响应，手动推进时间，使排队命令到执行前才过期；另覆盖 observe 挂起后代次／样本失效，恢复后仍不得调用风险 apply。断言 backend 调用记录，而非只检查 UI 没变化；时钟倒退／年龄计算溢出保守拒绝，停止／释放不因风险命令过期而被丢弃。
- [ ] 写竞争红测试：暂停 apply 时收到取消/新限/睡眠；actor 在 await 时可重入，要求显式单写队列而非仅依赖 actor。撤销使旧代次失效且排在新风险操作之前；在途写不可假称撤回，晚到结果只用于恢复核对，不重新激活旧模式。连续输入合并为最新未执行意图，停止／释放不得被合并掉。
- [ ] 写 `testLateCompletionCannotRestartCancelledMode` 与 `testTimeoutIsUnknownAndBlocksNewRiskWrites`：取消后迟到成功不能恢复旧模式；超时／部分结果／回读矛盾返回 outcomeUnknown，释放未确认仍阻断新风险写，未决 apply 不能因超时就被当成已结束并与新写并行。测试注入恢复未知／冲突时不盲目继续，不实现基线比对或持久恢复算法。
- [ ] 写显示调度不推进时的独立手动 tick 测试：样本／lease 过期仍能使会话失效并请求释放，但未收到确认不能标 released。运行 `swift test --filter BatteryCareSessionTests` 确认红；最小实现真实 Policy 接线与队列，用注入 now、手动事件、可挂起响应验证，不用真实 sleep 或通用模拟引擎。
- [ ] 重跑同命令及 `swift test --filter 'BatteryCarePolicyTests|BatteryCareTemporaryModeTests|BatteryCareLifecyclePolicyTests'` 至绿并 review。只证明内存语义和调度；具体 wire 编码／资源限额／畸形包、连接身份／授权 fixture、持久归属／恢复及其测试一起延期 G4/B0，恢复还依赖 G1/G3。不得提前留下无安全测试的实现，也不得宣称 helper 认证、真实有界看护或硬件恢复已完成。

### A5：不可用生产服务、预览与诚实展示模型

**Files:** Create `Sources/MacActivityBatteryControl/UnavailableBatteryCareService.swift`、`Sources/MacActivityApp/Models/BatteryCareModel.swift`；Create `Tests/MacActivityBatteryControlTests/UnavailableBatteryCareServiceTests.swift`、`Tests/MacActivityAppTests/BatteryCareModelTests.swift`。

**Interfaces:** `UnavailableBatteryCareService: BatteryCareServicing`；`@MainActor final class BatteryCareModel: ObservableObject`，`init(preferences: PreferencesController, service: any BatteryCareServicing)`；`previewLimit(_ value: Int)`、`cancelPreview()`、`commitPreview() async`、`setManagementEnabled(_ enabled: Bool) async`、`startDischarge() async`、`stopDischarge() async`、`startFullCharge() async`、`cancelFullCharge() async`、`retryRegular() async`、`handleLifecycle(_ event: BatteryCareLifecycleEvent) async`、`shutdown() async -> BatteryCareShutdownResult`。发布 `presentation: BatteryCarePresentation`，分别包含 savedLimit/previewLimit/requestedTarget/effectiveTarget/currentSystemPercentage 和各按钮状态／禁用原因。ShutdownResult 为 noControlAcquired/released/unconfirmed，不把前者当设备已核验释放。

App 为每个新提交意图生成 requestID、推进 generation 并调用 A4 的 `send(_:)`；生命周期推进 generation 后调用服务的 `handleLifecycle(_:generation:)`，shutdown 走 quit，不另跑 reducer。此层 contract 测试可用只记录调用／推送预置回复快照的简单 service fake，验证偏好与展示；不在 fake 里实现策略，也不声称覆盖硬件流程。

- [ ] 写红测试：默认显示未启用/80，拖动N次不调用 service/save，commit只存最终整数一次，Escape/关闭/切页取消未提交预览；合法离线调限保存待应用，不开启管理。明确无内置电池时禁调限；身份未知与未验证状态分开显示，绝不伪装成无电池。
- [ ] 写保存／授权测试：setLimit先校验并保存成功才提交新意图；保存失败回到上次接受值且不发送；已保存后硬件失败保留新值并标未应用。启用必须显式动作且服务授权／准入确认后才持久化true，拒权不写true、不反复提示；启用确认后的保存失败必须请求释放。关闭先失效风险意图，即使save失败仍尝试撤销并报告“关闭设置未保存”。
- [ ] 写状态测试：接受≠回读≠物理效果；`testLateSnapshotCannotOverwriteNewIntent` 覆盖迟到／跨代次／旧 revision 快照不覆盖新意图，与 A4 的过期写隔离分别保留；断连时停止按钮仍可记录取消并显示无法确认；取消/完成恢复失败不先显示常规有效。旧持久 enabled=true+服务不可用只显示暂停，不自动假启用或续跑临时模式。
- [ ] 写 `testUnrelatedMetricsCannotRefreshBatteryControlSample`：模拟CPU持续刷新而服务电池sequence/observedAt不变，控制状态不变新；缺失isCharging仍unknown，图表口径偏好改变不改变顶部系统口径或控制输入。此测试不替代G1的真实多电源识别验证。
- [ ] 写 `testUnavailableServiceNeverReportsAppliedOrReleased`：所有风险请求明确不可用，capabilities全unverified，completion/readback/physical均unknown；本进程从未取得控制仅能报告 noControlAcquired，不能覆盖升级前可能存在的未核对残留。模拟成功状态仅出现在 Tests，不提供用户可打开的“测试支持”开关。
- [ ] 运行 `swift test --filter 'UnavailableBatteryCareServiceTests|BatteryCareModelTests'` 确认红；实现上述接口、服务更新订阅与 generation 校验。A 阶段控制样本不足时当前电量显示“未知／待核验”，不从 `MetricsSnapshot.timestamp` 拼造新鲜控制样本；原图表继续原样展示。
- [ ] 重跑至绿并 review。从未写入且服务不可用可立即返回 shutdown 结果；将来真实服务的有界收尾上限必须来自 G3，不能把 Swift Task.cancel 当物理取消。

### A6：两行控件、输入和轻量设置

**Files:** Create 第1节的三个 BatteryCare View 文件；Modify `Sources/MacActivityApp/AppDelegate.swift`、`Views/DashboardView.swift`、`AppShell/DashboardPopoverController.swift`、`Localization/AppLocalization.swift`；Modify `Sources/MacActivityApp/Resources/en.lproj/Localizable.strings`、`zh-Hans.lproj/Localizable.strings`、`zh-Hant.lproj/Localizable.strings`、`ja.lproj/Localizable.strings`、`ko.lproj/Localizable.strings`、`de.lproj/Localizable.strings`、`fr.lproj/Localizable.strings`。Create `Tests/MacActivityAppTests/BatteryCareControlsViewTests.swift`；Modify同测试目录下的`DashboardPopoverControllerTests.swift`、`DashboardCardLayoutTests.swift`、`DashboardGlassNavigationTests.swift`、`AudioDashboardViewTests.swift`中的现有构造调用；回归`AppSamplingControllerTests.swift`、`AudioControlComponentTests.swift`的AppDelegate测试工厂。直接运行现有 `Tests/MacActivityAppTests/LocalizationTests.swift`，不为电池再增加全 key／占位符检查清单。

**Interfaces:** `BatteryCareControlsView(model: BatteryCareModel)`、`BatteryCareSettingsView(model: BatteryCareModel)`；`BatteryCareLimitSlider(value: Binding<Int>, isEnabled: Bool, onCommit: @escaping () -> Void, onCancel: @escaping () -> Void)`。DashboardView 和两个 DashboardPopoverController init 在 `audioDashboardModel` 后新增显式 `batteryCareModel: BatteryCareModel` 参数；保留原参数／闭包，不用隐藏全局单例或自动创建控制会话。

- [ ] 写失败测试：第一行上限/预览、放电开关、临时充满/取消、四宫格；第二行滑条与独立“当前电量（系统）”。四页同一 model identity；running／inflight均能表达取消，禁止另一临时模式启动。无电池占位不显示假0%；“未验证”“未授权”“helper不兼容”“结果未知”“恢复未确认”不混为一个disabled。
- [ ] 写输入测试：鼠标mouse-up一次提交；键盘左右预览、Return提交、Escape取消；VoiceOver单次增减提交，连续同轮输入合并为最终值，不丢停止动作。优先原生 NSSlider 的 NSViewRepresentable 事件适配，分离 editing/commit/cancel，不假定 SwiftUI onEditingChanged 覆盖键盘；测试同一路径而非单独重写测试逻辑。
- [ ] 写实际控件辅助功能测试：上限与当前电量名称不同，预览／提交／运行／停止中／恢复未确认有正确可读状态，四宫格名称“更多电池设置”，禁用原因可聚焦读取；错误不只hover/颜色，焦点顺序第一行→滑条→旧导航／内容，原控件相对顺序不变。运行／在途及中英／大文字下取消入口完整可达；验证控件暴露的名称、值、动作与焦点，不仅检查翻译字符串存在。
- [ ] 运行 `swift test --filter 'BatteryCareControlsViewTests|LocalizationTests'`：新增行为测试应先红，既有全 key／占位符测试直接作为回归，新 Key 登记后缺译应由它们发现，无需另造电池清单。实现独立两行并插入现有header之前。同步AppDelegate创建唯一BatteryCareModel并注入懒dashboard工厂，连同`testingConfigureDashboardPopoverFactory`注入测试模型，更新所有构造调用，保证本任务可独立编译；通知及退出接线留A8。更多设置仅轻量popover，包含管理开关、操作解释、权限／逐项能力与恢复说明；不新建睡眠／能源设置页。禁用后端仍显示真实不可用，不做成功演示。
- [ ] 重跑测试；随后使用注入假服务、内存偏好进行受控 UI 检查中英／大文字／减少动态效果／减少透明度／增强对比度。不改用户系统设置来模拟环境；无法注入的 OS 辅助功能检查留作获准测试机人工项，不以渲染单测代替 VoiceOver 交互验收。

### A7：实测高度、双宿主和原滚动回归

**Files:** Modify `Sources/MacActivityApp/Views/DashboardView.swift`、`AppShell/DashboardPopoverController.swift`、`DashboardAdaptivePopoverHost.swift`、`DashboardPanelHost.swift`、`DashboardPanelSupport.swift`。Test 扩充 `Tests/MacActivityAppTests/DashboardPopoverControllerTests.swift`、`DashboardAdaptiveHostTests.swift`、`DashboardPanelHostTests.swift`、`DashboardPanelSupportTests.swift`；Create `BatteryCareLayoutTests.swift`。

**Interfaces:** `DashboardContentMeasurementSegment` 增 `.batteryCare`；`DashboardPopoverLayout.contentSize(for measuredSize: NSSize, batteryCareHeight: CGFloat, availableHeight: CGFloat) -> NSSize?`；`DashboardPanelPlacement.availableContentHeight(anchorRect: NSRect, visibleFrame: NSRect, gap: CGFloat, edgeMargin: CGFloat) -> CGFloat`。高度预算 `min(naturalTotal, 560 + measuredBatteryCareHeight, availableHeight)`，新增间距包含在 batteryCare segment。popover availableHeight 必须扣其自身 chrome／箭头空间，不能照搬 panel 的值。

复用现有测量、旧动画失效、宿主切换与滚动测试，只增加 batteryCare 段、双宿主预算／共享模型的少量增量断言；不新建“每个策略边界 × 四页 × 双宿主 × 七语言”的重复矩阵。

- [ ] 写红测试：原自然高度加新段、短页收缩、正常屏不压缩旧视口；窄高预算下顶部／导航固定，剩余高度正确传入现有 Overview ScrollView 和 DashboardListPage。测量未齐／非有限数不能输出错误尺寸；首帧bootstrap到真实测量不得永久卡在560。
- [ ] 写 `testSliderPreviewDoesNotResizeWindow`、`testHostSwitchKeepsModelAndMeasuredHeight`；同样两行占用下50→100、提交／取消短标签不跳高；中英长原因通过说明面板而非第三行或缩小字体。跨屏幕／菜单栏锚点变化重算预算；旧动画完成不得覆盖新根视图／新高度。
- [ ] 运行 `swift test --filter 'BatteryCareLayoutTests|DashboardPopoverControllerTests|DashboardAdaptiveHostTests|DashboardPanelHostTests|DashboardPanelSupportTests'` 确认红；实现共同预算与宿主的可用高度供给，更新 seed/report/size-coordinator/默认尺寸所有调用点。
- [ ] 重跑至绿；注入短屏四页内容，核验最底操作和键盘焦点可达，原卡片／图表尺寸不变，列表滚动与整页overflow不抢轮。frame只裁小但内容未获可滚视口必须失败。极端到固定两行及导航都放不下的几何不编造适配成功，应报告限制并在review中要求明确处理后再通过。

### A8：App 装配、关闭预览与独立生命周期

**Files:** Create `Sources/MacActivityApp/AppShell/BatteryCareLifecycleBridge.swift`、`Tests/MacActivityAppTests/BatteryCareLifecycleBridgeTests.swift`。Modify `Sources/MacActivityApp/AppDelegate.swift`、`AppShell/DashboardPopoverController.swift`；Test 扩充 `AppSamplingControllerTests.swift`、`DashboardPopoverControllerTests.swift`。

**Interfaces:** `@MainActor BatteryCareLifecycleBridge.init(model: BatteryCareModel, workspaceCenter: NotificationCenter)`、`start()`、`stop()`；桥接 NSWorkspace willSleep/didWake 通知。外电与精确采样由未来 helper 的独立来源负责，不能从当前显示 snapshot 提升成控制准入事件。AppDelegate 启动即创建唯一 BatteryCareModel（service 固定 Unavailable），懒创建dashboard仅注入它；增加可注入 battery shutdown 测试闭包，沿用 terminateLater 协议。

- [ ] 写红测试：窗口隐藏／切页只cancelPreview，不停止服务会话、不改变控制时钟；关闭前已提交不取消。睡眠使旧generation无效，唤醒无自动临时启动；重复通知／start/stop不重复注册，停止后无回调。此层验证通知／退出确实经 A5 转发 A4 生命周期接口且不依赖显示 scheduler；显示调度停顿时的会话过期／释放断言复用 A4，不重写策略矩阵。
- [ ] 写退出测试：一开始就发电池撤销，不能先等可能挂起的audio shutdown；重复quit只一次收尾，battery cleanup按有界结果结束，unconfirmed被保留而非映射为released；随后沿用audio/scheduler的必要清理。未完成startup不能晚到重开控制；退出保留设置、关闭管理清除启用意图。
- [ ] 运行 `swift test --filter 'BatteryCareLifecycleBridgeTests|AppSamplingControllerTests|DashboardPopoverControllerTests'` 确认红；实现装配与测试注入，禁止从视图onAppear启动控制，禁止控制改变全局MetricsScheduler采样档。
- [ ] 重跑至绿；核验现有audio shutdown/startup竞争与同一dashboard identity测试仍通过。生产A无授权弹窗、无helper注册、无控制采样／SMC写入；B以后由helper兜底主进程崩溃，不能用本任务的App通知测试充当G3证明。

### A9：少量真实接线冒烟、文档和 review（无硬件）

**Files:** Create `Tests/MacActivityAppTests/BatteryCareIntegrationTests.swift`；Modify `docs/user-guide.md`、`docs/development.md`，必要时在 `docs/release.md` 说明新共享framework签名。此为未来实施任务，不是本轮许可修改这些文件。

**Interfaces:** 消费 A1–A8，不新增产品策略。逻辑冒烟必须走 **App 的 BatteryCareModel → A4 真实 BatteryCareSession: BatteryCareServicing → A2/A3 真实 BatteryCarePolicy → 仅底层 fake BatteryCareBackend**，再由真实 Session 的 reply／updates 返回 App；偏好使用真实 PreferencesController 加内存 store。只复用 A 阶段已有协调逻辑，不提前引入 helper／wire。fake 仅提供合成观测、记录 effect、挂起／恢复响应；可在整合测试文件内定义小型局部 backend，沿用 A4 的简单模式，不依赖另一个 test target 或新增通用 fixture 模块。禁止用重写策略的 service fake 宣称端到端；这些冒烟只证明进程内逻辑接线，不证明 IPC、认证、持久恢复或物理效果。

- [ ] 写 `testCommittedLimitFlowsThroughRealSessionAndPolicy`：合成准入上下文下经 Model 明确启用，预览不写，提交新限仅保存最终值并经真实 Policy 产生预期 effect；挂起／恢复底层响应验证在途→回读，物理观察未知仍显示效果未确认。只取一个代表性上限，不重跑回差／100／缺测矩阵。
- [ ] 写 `testFullChargeLimitChangeWaitsForReleaseBeforeRegularPolicy`：通过 Model 启动临时充满、提交不同上限，挂起底层解除覆盖响应；真实 Session 在确认前不得启动新风险写，确认后真实 Policy 按最新上限恢复且不放电，App 收到对应状态。取消迟到／超时全矩阵仍归 A4，迟到 UI 快照归 A5，四页／双宿主共享状态归 A6–A8，不在此复制。
- [ ] 写默认生产装配防回归：实际 App 组合仍注入 `UnavailableBatteryCareService`，能力未验证、启用／临时操作被拒绝、没有可执行 backend 或风险 effect，不存在用户可打开的测试成功通道。此项验证真实禁用，不用上面可用测试组合冒充生产可用。
- [ ] 运行 `swift test --filter BatteryCareIntegrationTests` 确认红；最小修复连接点，绿后执行第4节全套无硬件命令。任何失败先定位，不放宽断言或删除边界测试来通过。
- [ ] 更新未来用户／开发文档：默认关闭、20兜底非认证标准、常规100语义、系统口径、支持状态、恢复未知、A等级限制；不得在README或发布说明中宣传尚未准入的充放电功能。
- [ ] 独立 reviewer 对 spec覆盖、真实 Model／Session／Policy 接线、SwiftPM/Xcode一致性、A4 写隔离与 A5 迟到快照各自的测试、延期实现与安全测试成对、原UI回归做整合审查；普通修复回到新implementer任务，测试回归至绿，重大方案变化重新规划。记录未运行的图形／人工项，存在实质问题不得声称A完成。
- [ ] 报告A完成与G/B仍阻塞，并停止。不自动提交、PR、发布或开始硬件实验；如用户以后授权提交，提交前另查status/diff/log且只选相关文件。

## 3. 独立受控准入 G 与被阻塞的 B 阶段

本节是**验证问题／产物／放行标准**，不是已确定的SMC实现清单。当前没有首批支持名单、满充判据、有限控制时限、生产helper注册与授权方案。任何重要技术选择不能由实现者顺手决定。

### G0：实验授权和研究计划（所有真实设备操作前）

- [ ] 提交单独研究计划，明确设备资产标识、机型、macOS完整构建、内置电池／适配器、当前系统策略、应用/helper构建与签名身份、操作清单、持续时间、退出／人工处置步骤和诊断脱敏方式。
- [ ] 向用户取得**该设备＋该操作**授权。限充、主动放电、充满、拔插、睡眠、崩溃注入、helper安装／升级／卸载分别列明；绝不以本次设计或计划批准代替。sudo、系统服务注册、网络公证／上传均需对应许可。
- [ ] 先批准保守的中止条件和可操作恢复方法，未建立恢复证据前不做风险主动放电。20%用合成输入验证逻辑，不以真实放到20%作为默认验收步骤。探测脚本与原型须另行review，正式能力许可仍为空。

**未来产物：** `docs/superpowers/specs/2026-10-24-battery-care-hardware-admission.md`（设备范围、技术决策、证据索引）及获批后的专用实验计划；敏感日志不进Git。只预留文档路径，本轮不创建。

### G1 / V1：身份、系统口径与逐项真实控制效果

**问题：** 如何区分内置电池、UPS、多电源、无电池与识别失败？系统百分比的来源／更新时机／误差是什么？该机型和系统上允许充电、停充、主动放电、停止放电、释放限制分别有没有可验证路径？每个操作是否可保留有效恢复依据？

**产物：** 逐操作证据表（精确机型+OS build+电池身份映射；来源、类型、单位、时间戳/序号、请求、独立回读、实际电源／充电观察、恢复前后状态），原始记录摘要及hash。若涉及SMC，具体key/格式/写值只在受控证据和获批补充方案中出现，不从AlDente研究迁移白名单。

**放行：** 请求、回读与物理效果分别可追溯；UPS/缺值/错误机型等反例拒绝；恢复可验证。仅某key可读、返回0、isCharging=false或电量下降均不通过。每个操作独立评定，任一依赖的release未通过则该风险操作不放行。

### G2 / V2：充满完成与反例

**问题：** 是否存在能区别终充、优化充电暂停、温度保护、电源不足和本应用停充的可靠来源？已满时启动如何处理？必要信号缺失／冻结时能否及时终止覆盖？没有明确终充信号时，是否允许组合判据是未决重要技术选择。

**产物：** 同一设备上正常终充、已满启动、未满停充、外电波动、主动停充、冻结/缺失/矛盾读数的带时间轴记录；信号语义、所选算法和反例结果；完成确认、释放、常规恢复三份独立结果。

**放行：** 算法在所有所需反例拒绝误报，说明来源一致性、观察窗口、最长等待及无进展期限；没有信号即不可用。组合判据必须写成技术决策、评审并由用户批准后再计划实现；显示100%、等若干分钟、固定零电流/功率不得代替。G1通过不能顺带通过G2。

### G3 / V3：有界监测、过期、停止和恢复所有权

**问题：** 独立控制采样与helper看护如何在App隐藏、显示节能、客户端断连或崩溃时仍有界？sleep进入前未完成的操作、helper自身重启／强杀、OS重启后如何核对残留？先前状态是否仍属于自己，第三方竞争如何停止而非抢写？

**产物：** 一份完整 `BatteryCareSafetyLimits` 数值／依据表与时间轴：采样间隔、最大年龄、队列/IPC/写/回读/停止上界、lease、临时模式最大时长、无进展上界、允许偏差和保守低电余量；逐个故障注入记录；恢复journal生命周期（持久位置、所有者权限、原子写、版本、损坏/重启处置、清理条件）方案。

**放行：** 先验证有限停止余量足够，再许可启动；取消与过期检查跨排队、执行、回调全程有效；恢复只触及仍可证明归属的状态，无法证明时拒绝风险写并显式未知。睡眠／断电不能保证执行清理，须有可验证残留发现和用户处置路径；不能用“任务被取消”“lease到了”冒充硬件已释放。全部界限未定或独立看护不可行，相应能力继续禁用。

### G4 / V4：生产helper信任、授权与分发可行性

**问题：** macOS26上哪种系统管理的最小特权helper注册路径满足产品分发？实际可用的连接身份验证API与签名requirement是什么？服务注册授权、每个用户／audit session的控制授权、跨用户所有权怎样区分？XPC中断和升级时谁持有最后恢复责任？

**产物：** 使用目标SDK核实的注册/XPC/签名API与原型结果；签名ID及Team来源、客户端和服务端校验、权限授予／拒绝／撤销策略、wire 编码与严格解码／资源上限方案、协议版本兼容矩阵、launchd/job/plist/entitlements/安装布局、归属与恢复威胁模型。编码和包大小从此处证据决定，不预定 JSON 或 64 KiB。身份基于系统给出的连接audit token／动态代码身份验证；只检查PID路径、自报bundle ID或字符串Team ID不合格。验证合法Team但错误App、拷贝bundle ID、ad-hoc/未签名、调试注入、另一个用户／连接都不能越权；客户端也认证helper。

**放行：** 真实Developer ID分发条件成立，最小权限接口不可越界，未授权每次拒绝且不循环弹窗；注册通过不代表控制授权通过；服务端独立参数／能力校验。新旧App/helper错配安全拒绝，新连接不继承旧临时会话；升级／卸载先处理自有控制和journal，不丢失未确认恢复。无法满足时保持不可用，不整体提权、不添加任意SMC或shell接口。具体方案仍需B0批准。

### B0：证据后的补充实施计划（阻塞点，必须重新规划并批准）

- [ ] 将G1–G4结果、失败项与精确支持组合写入hardware-admission文档；把各能力所依赖的验证记录ID与构建hash绑定，未知能力继续unverified。
- [ ] 用planner先编写 `docs/superpowers/plans/2026-10-24-battery-care-hardware-integration.md`，共同锁定具体 wire 编码／版本／资源限额、连接认证与授权、跨进程 epoch／时钟／防重放、首次写前基线及持久恢复所有权／journal；将各自负向测试与实现一起排入 B1/B2。明确具体SDK调用、私有硬件格式、有限时限、文件／接口变更、测试夹具、验证命令及部署顺序；目前这些决定未成立，**B1/B2不能凭下表直接编码，也不能沿用已撤下的 A4 wire／认证／ownership 假定**。
- [ ] 交技术／安全review与用户批准；如结果改变已批准产品语义、低电边界或范围，先给出spec差异再批准。不采用“实现时再看”的隐式授权。G4研究原型不是生产helper已完成。

### B1：生产采集、适配器与唯一helper会话（待B0）

**预留文件边界：** `Sources/MacActivityBatteryHelper/main.swift`、`BatteryCareXPCListener.swift`、`BatteryCareClientAuthenticator.swift`、`BatteryCareHardwareBackend.swift`、`BatteryCareObservationReader.swift`、`BatteryCareRecoveryJournal.swift`；App侧 `Sources/MacActivityApp/Models/BatteryCareXPCClient.swift`；`Tests/MacActivityBatteryHelperTests/`。wire DTO／codec 及其测试的实际位置、共享语义接口需扩充之处由 B0 同步列明，不继承 A4 的编码实现。依赖共享BatteryControl，不导入App/Core展示、音频、清理或Sparkle。

**衔接契约：** XPC client 适配 `BatteryCareServicing` 的意图／生命周期／结果语义，helper 单独拥有真实 Policy／Session，不在 App 另跑策略。A4 的 `BatteryCareBackend` 仅锁定 observe／语义 effect／分层结果边界；真实认证、恢复所有权与基线保护须在 B0 明确其生产适配或必要扩充，同步调用点和测试，不能把 A 的合成恢复就绪状态直接当生产写入许可。实际NSXPC接口声明、SDK身份读取和硬件实现由B0锁定，不宣称已有可用API。

**补充计划必须先列出的红测试／验收：** 非内置／多源／缺字段；独立序号与单调年龄；逐项能力匹配；所选 wire 的往返、缺字段／额外控制字段／未知版本与操作／超限／非法数值、伪造遥测／能力／completion／ownership；真实身份与授权错误（含 UID／audit session／连接不符）、跨进程旧 epoch/session/generation、防重放、过期／未来时间／溢出和有界幂等；首次写前无有效持久基线不写、只恢复仍匹配最后自有写入的状态、第三方变更／归属丢失拒盲恢复；部分写入／timeout unknown、睡眠／断连／双客户端竞争、journal损坏／重启／跨boot核对。具体实现和对应安全测试不可拆开交付；A4 内存竞争测试保留作回归，不能代替这些生产边界测试。假IOKit只验证解析和调度，真实效果必须关联G证据。没有对应证据不切换生产service装配。

### B2：生产签名、安装、升级、卸载和包一致性（待B0）

**预留改动边界：** `Package.swift`、`project.yml`、生成的 `MacActivity.xcodeproj/`；`Configuration/MacActivityBatteryHelper-Info.plist`、`MacActivityBatteryHelper.entitlements` 及注册方案锁定后的job plist；`Sources/MacActivityApp/AppShell/BatteryCareHelperRegistration.swift`；`scripts/install-local-release.command`、`.github/workflows/release.yml`、`.github/scripts/notarize_and_staple.sh`、`release_policy_test.py`、`platform_policy_test.py`；`docs/release.md`、`docs/user-guide.md`。精确job名称、签名requirement和装包位置必须写进B0，不先猜一个launchd plist就称安装有效。

**必须验证：**

- [ ] 双构建加入helper可执行体及测试，SwiftPM测试可编译但不等同Xcode已嵌入／注册；Xcodescheme、Copy Files/依赖、arm64/macOS26、runpath、共享库携带及签名顺序逐一对齐，补平台target计数测试。
- [ ] 先写包结构／签名清单失败测试，再改脚本；共享库→helper嵌套代码→外层App的签名、实际Team/identifier/entitlements、无意外debug权利，使用真实Developer ID产物及公证/staple/Gatekeeper验证。未签名CI和ad-hoc通过不作生产准入证明。
- [ ] 在获准干净测试账户／设备上验证首次注册、拒权、不兼容、用户撤销、再次授权；记录系统服务状态、经过认证的握手及功能状态，不能伪造SMAppService回执。用户启用前不得静默安装或提升权限。
- [ ] 覆盖旧App+新helper、新App+旧helper、升级中断／签名校验失败、Sparkle替换App路径、重复升级；先冻结新风险请求、释放或记录未确认恢复，再转换版本；新进程不自动续跑旧临时模式。失败不删除唯一可恢复journal，也不无限保留旧写入所有者。
- [ ] 验证明确“移除helper”及App卸载流程：先请求释放、核验、再unregister/删除已证实自有资源；失败显示残留和安全处置，不标“已卸载干净”。直接把App拖入废纸篓无法保证执行清理，测试实际孤立job/残留发现与受控移除路径，不能承诺系统必自动清除。
- [ ] 输出生产包hash、签名／公证检查结果、各安装状态和恢复前后记录。外部公证／下载与机器修改只在另行授权阶段执行；不把此清单作为本轮执行命令。

### B3：指定设备最终整合与发布前review（待B1/B2）

先把批准的设备记录变成release能力表测试：只有机型＋OS build＋操作全部匹配才启用；缺记录／升级OS／权限丢失即时禁用并处理活动会话。随后逐设备完成常规边界、一次放电改限、充满与反例、取消竞态、睡眠拔电、崩溃恢复、生产包安装升级卸载。日志区分用户意图/IPC接受/硬件回读/实际效果/恢复；输出失败和未知，不只“pass”。

最后运行A9回归和补充计划的真实测试，独立review关闭所有实质问题，更新支持矩阵、用户说明及发布限制。若仅限充通过，可只报告限充准入，放电／充满保持禁用且整项不能称全部完成。发布、提交和合并仍等用户明确指令。

## 4. 本repo命令与验证边界（以后执行；本轮未运行）

工作目录必须为隔离后的产品根。只用已安装工具和已缓存依赖；如命令试图解析／下载缺失依赖，停止并报告环境阻塞，不擅自联网。测试全部注入无硬件服务和临时存储；Xcode AppTests 为app-hosted，会启动测试host，**不属于当前“仅写文档”授权**。

定向命令与本次分层一致：A4 为 `swift test --filter BatteryCareSessionTests`（无 codec 测试类）；A5 保留 `BatteryCareModelTests` 的独立迟到快照／保存拒权覆盖；A6 的 `swift test --filter 'BatteryCareControlsViewTests|LocalizationTests'` 同时运行新增控件测试和现有全 key／占位符测试；A9 为 `swift test --filter BatteryCareIntegrationTests`，仅上述接线冒烟与生产禁用防回归。延期的 wire／认证／journal 测试类和命令在 B0 随方案补齐，不挂空过滤器，也不能把 A 全绿当成它们已通过。

```bash
# SwiftPM：各任务使用上文 --filter，整合用现有CI形式
swift test --enable-code-coverage

# 配置与发布策略静态测试，不执行安装／签名脚本
python3 -B .github/scripts/check_development_version.py
python3 -B -m unittest discover -s .github/scripts -p '*_test.py'

# project.yml 为源；生成并检查所有产生的差异
xcodegen generate --quiet

# A1起可用的新共享target定向Xcode测试
xcodebuild test -project MacActivity.xcodeproj -scheme MacActivity -destination 'platform=macOS,arch=arm64' -only-testing:MacActivityBatteryControlTests CODE_SIGN_IDENTITY='' CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO

# 整合Xcode测试（对应 .github/workflows/ci-checks.yml 的无签名测试通道）
xcodebuild test -project MacActivity.xcodeproj -scheme MacActivity -destination 'platform=macOS,arch=arm64' CODE_SIGN_IDENTITY='' CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO

# 未签名Release编译，只证明编译／链接，不证明生产helper安装有效
xcodebuild build -project MacActivity.xcodeproj -scheme MacActivity -configuration Release -destination 'platform=macOS,arch=arm64' CODE_SIGN_IDENTITY='' CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO

# 仅在已安装时使用；本仓库CI将其视为advisory
swiftlint lint --config .swiftlint.yml
git diff --check
```

通过标准：SwiftPM/Xcode分别发现并运行新测试（非零数量）且无失败；Python全部通过；Release能链接；生成项目与project.yml一致、再次生成不引入新差异。未提交工作树不能用 `git diff --exit-code -- MacActivity.xcodeproj` 判断本次合法生成“过时”；先核对本轮生成diff，再比较连续两次生成产物，提交后CI才用该命令检查零差异。XcodeGen最低2.45.0，`.github/scripts/install_pinned_xcodegen.sh`固定2.45.4；不运行该下载／安装脚本，也不自动升级。

不得调用 `scripts/install-local-release.command` 默认路径来“顺便验证”，它可能退出用户App、sudo并安装。生产签名／注册验证属于B2，即便仅build-only也不在本轮授权内。普通CI不挂载硬件测试，硬件gate不能被全绿单测替代。已有全套测试中的真实系统访问须在未来执行前审查；新电池测试不得连接真实helper、访问用户持久设置或改电源行为。

## 5. 需求追踪与计划自查

| 设计要求 | 负责任务／必要证据 |
| --- | --- |
| C1 平台；D8逐项准入 | A1双构建与平台测试；A4/A5拒绝未知；G1–G4/B3能力记录 |
| C2/C3/C4、D7 两行跨页／保留原UI／更多设置／拖动提交 | A5/A6输入和共享模型；A7双宿主高度滚动；A8关闭预览 |
| C5、D1/D2 默认、范围、意图不自动放电 | A1持久化／校验；A2禁止隐式启动；A5保存／启用分离 |
| C6、D4 一次放电跟新限、停止优先、20兜底 | A3全边界；A4串行竞争；G1/G3实际停止余量 |
| C7、D5 覆盖分离、完成取消恢复、新限取消 | A3/A5；G2完成判据与反例；G3恢复事实；B1生产适配 |
| D3 常规回差、100特殊、同限退出与新限重建 | A2/A3未取整阈值矩阵 |
| D6 拔电睡眠退出、常规重建、故障手动重试 | A3/A4/A8；G3不保证清理的真实界限；B2升级／移除 |
| §3.4 键盘／VoiceOver／中英／对比度／减少动态效果 | A6 实际控件名称／状态／焦点／取消入口，复用 LocalizationTests 全 key 七语言／占位符；A7 增量布局与受控UI人工验收，未运行必须标未知 |
| §4 无电池/UPS/未知/拒权/断连/无外电/效果未知 | A1/A2/A4/A5；G1原始输入语义、G4真实授权 |
| §5 单所有者、幂等、过期写隔离与迟到状态 | A4 真实内存 Session／Policy 与 backend 调用断言；A5 独立迟到 UI 快照测试；A9 少量真实接线；G3/B1 跨进程与硬件验证 |
| §5 最小helper、wire、签名身份与授权 | G4/B0 一起定案实现／安全测试，B1 严格解码、认证与防重放；B2 真实签名分发，A 不预建这些机制 |
| §5 自有恢复、冲突、显示调度解耦、有限看护 | A3/A4 只验语义阻断／退出／手动 tick，A8 生命周期接线；G1/G3/G4 → B0 → B1/B2 承担基线、持久归属／journal、真实时限与故障证据 |
| §6.4/6.5 未决充满算法、硬件可行性、技术再批准 | G0–G4、B0；无证据不得执行B1/B2或启用能力 |
| §1 不扩展范围，§2静态研究不是可用性证明 | 全局约束；A9/B3审查及完成等级报告 |

自查结论：接口、文件归属、依赖及定向命令已随三项精简同步；A4 不再要求 codec／认证 fixture／ownership 实现，A9 明确复用真实 Session／Policy，A6 不另建电池翻译完整性清单。模型／偏好、表驱动策略、缺测／过期／UPS、保存拒权、回差／100、一次放电、取消超时、生命周期及双宿主增量覆盖仍由各责任层承担；过期写隔离与迟到 UI 快照分别保留。Review Focus 与需求映射显式指向延期实现及其必要安全测试；G1–G4 的真实安全、认证、安装升级卸载门槛不减。A 阶段通过不掩盖 G/B 阻塞，任何支持声明必须有同设备实测和生产部署证据。

**明确延期：** wire 编码／严格解码／版本与资源限额、连接认证／授权及身份 fixture、跨进程时钟／epoch／防重放、有效基线／持久恢复所有权／journal，以及对应负向测试，均待 G4/B0（恢复另需 G1/G3）共同定案后进入 B1/B2；不是省略这些安全责任。A4 的内存串行、过期、取消、超时与结果隔离不延期。

**本次交付停止线：** 仅修订此计划，spec 及其他文档不改。未创建生产模块、测试、helper、硬件准入记录或补充实施计划，未运行构建／测试、应用或硬件命令，未提交。用户批准的是三项计划精简，不是实现许可；下一步仍是审阅计划。
