# XYZ 工程化与流程分析（process.md）

- 分析对象：`/Users/lizhichao/Developer/XYZ`，版本 **0.5.28 (build 44)**，HEAD `db12a62`（2026-11-07 11:12:20 +0800，merge PR #4）。
- 方式：只读分析；静态读文件 + 轻量命令（`plutil`、`sh Scripts/xyz-test.sh`、`git`、`codesign`、`diff`、Python 解析）。**未运行 xcodebuild**。构建基线（macOS Debug/Release、iOS Simulator、`swift test`）由 Lead 负责，本文引用其结论。
- 本机工具（实测）：Xcode 27.2 (27B52)、Swift 6.4.2、swiftlint 0.65.1、swiftformat 0.64.6、xcodegen 2.46.0（仓库内**无** `project.yml`、无 SwiftLint/SwiftFormat 配置）。
- Lead 已用 GitHub API 交叉核实（本文标为「API 核实」）：仓库 public，创建 2026-10-23，描述 “An AI Editor.”，**0 tag / 0 release**；CI 累计 380 runs（success 137 / failure 172 / cancelled 71），最近 100 runs 仅 **10 success**，2026-11-06 单日 16 success / 101 failure / 22 cancelled；HEAD run `42332912178` 失败于 `Check original UI acceptance`，其后三个 launch/menu 步骤被 skip，iOS Simulator build 与 XYZCore tests 通过。

---

## 0. 摘要（先看这里）

1. **构建配置本身是「手写 pbxproj + xcconfig 单一版本源」，版本声明是真的**：内置产物（Debug / Release / iOS Simulator）的 `Info.plist` 实测均为 `0.5.28 (44)`，`project.pbxproj` 中没有任何 `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` / `DEVELOPMENT_TEAM` 覆盖（`grep` 为空），本机已安装的 `/Applications/XYZ.app` 实测为 `0.5.27 (43)`，与 CHANGELOG 第 5 行、docs/architecture.md 第 3 行一致。
2. **但「发布」这一整环不存在**：无 tag、无 release workflow、无 archive/notarization/Developer ID 签名；Release 仍 `ENABLE_HARDENED_RUNTIME = NO`；HEAD 本身在自家 CI 的 acceptance 门禁上是红的（run 42332912178），且 0.5.28/44 这一个版本号被 18 个提交共用，docs 指定的「rollback」提交 `02dac3c` 早于 0.5.28 记录里的修复。
3. **CI 的「通过」验证的是与用户实际运行不同的二进制**：CI 用 `CODE_SIGNING_ALLOWED=NO` 构建，再用 `codesign --force --deep --sign -` ad-hoc 重签；实测同类本机构建产物 `codesign -d --entitlements -` 为**空**，即 CI 跑的是**无沙盒、无 iCloud、无 bookmarks** 的 app；而已安装的 0.5.27 是带 App Sandbox/iCloud entitlements 的开发签名包。沙盒、iCloud 同步、书签路径全部不经 CI。
4. **UI 验收是进程内自检（2459 行 `GutterSnapshot.swift` 常驻发布包）+ 窗口截图 OCR**：依赖 WindowServer/TCC/Vision 与已废弃的 `CGWindowListCreateImage`；90 秒硬超时；已知 5 个 acceptance case 失败且 `da9730d` 之后代码未再修改（CI 历史 137/380 成功、最近 100 runs 仅 10 次成功，证明门禁又慢又红）。它不能证明产品正确，只能证明「检查器自己没报错」。
5. **双语承诺只完成了一半**：`Localizable.xcstrings` 234 key / 232 条 zh-Hans（覆盖率看起来高），但对代码做字面量比对后，**至少 47 条用户可见文案不在 catalog 里**（菜单、标签页右键、搜索面板、状态栏、设置），中文界面会回退英文；catalog 同时残留已删功能的 key（Format 菜单、侧栏过滤等）。CI 的中文检查只 grep 一个「打开文件夹…」。
6. **CLI `xyz` 有文档化但实际不可用的功能**：`xyz ~` / `xyz ~/Notes` 因 POSIX `case` 模式会做波浪号展开而永远匹配不到 `~)` 分支，实测报 `No such file or directory`；其自带 `--help` 第 30 行和 README 第 28 行都在宣传这个用法，`Scripts/xyz-test.sh` 没有覆盖。
7. **仓库卫生总体不错**（clean tree、无 build/.build 入库、`.gitignore` 覆盖、repo 仅 1.5 MB、plist 全部 lint OK），但没有任何 lint/format 门禁、没有 app 测试 target、没有缓存/超时、分支与 tag 策略缺失；154 个提交集中在 2 天内（153 个在 11-02~11-03），提交信息呈 AI 代理迭代日志风格（5 个 Cursor Agent 提交，10 个带 `Co-Authored-By: Claude 5.5`）。

---

## 1. 构建 / 签名配置

### 1.1 pbxproj 是手写的，不是 Xcode 或 xcodegen 生成的

**结论**：`XYZ.xcodeproj/project.pbxproj`（560 行）是**手工维护/由临时脚本生成后手工维护**的项目文件，不是 Xcode GUI 的正常产物，也不是 xcodegen 产物。

证据：

- 仓库无 `project.yml`（`ls project.yml` 无；根目录无任何 yml），本机装的是 xcodegen 2.46.0 但未使用；pbxproj 内无 `XcodeGen` / `DO NOT EDIT` / `generated` 标记。
- UUID 是合成编号而非 Xcode 的随机 24 位十六进制：`8A0000000000000000000001`、`8B…0001`、`8C…0001` 体系（`project.pbxproj:10`、`:46`、`:235`、`:545`）；全文件 95 个唯一 24-hex ID，全部符合 `8[ABC]0…` 顺序模式。Xcode 正常会写成随机 hex（如 `A1B2C3D4…`），且会带 `LastSwiftMigration`/`LastSwiftUpdateCheck` 等元数据。
- 版本格式旧：`objectVersion = 56`（`project.pbxproj:6`）、`compatibilityVersion = "Xcode 14.0"`（`:248`）、`LastUpgradeCheck = 2600`（`:239`）、`CreatedOnToolsVersion = 26.0`（`:243`）。
- 文件引用全手工登记：39 个 `PBXFileReference`、27 个源文件引用；用脚本比对磁盘 `XYZ/**.swift` 与 pbxproj 引用，**27/27 一一对应，无遗漏无多列**（当前状态正确）。资源 `bin` 是 folder reference（`:77`、`:278`）。

**影响**：新增/改名源文件必须手工改 pbxproj 文本；漏登记不会报错，只会「文件存在但不参与编译」——这是手写 pbxproj 最典型的静默故障。当前树恰好一致，但没有任何机制保证未来一致。

**建议**：引入 `project.yml` + xcodegen（工具已装，2.46.0）生成 pbxproj；或在 CI 加一个 10 行脚本，用 `xcodebuild -list` 或解析 pbxproj 与磁盘文件列表做 diff，不一致即失败。

### 1.2 xcconfig 版本单一来源：声明成立，但有一个隐含依赖

**结论**：`Config/Base.xcconfig:6-7` 的 `MARKETING_VERSION = 0.5.28`、`CURRENT_PROJECT_VERSION = 44` 确实是**唯一版本源**；pbxproj 没有覆盖（`grep -n "MARKETING_VERSION\|CURRENT_PROJECT_VERSION\|DEVELOPMENT_TEAM" project.pbxproj` 无结果），且两个 target 配置都挂了 `baseConfigurationReference`（`project.pbxproj:433` Debug、`:478` Release）。

实测验证（Lead 构建产物，本机 `build/`）：

- macOS Debug `XYZ.app/Contents/Info.plist`：`CFBundleShortVersionString = 0.5.28`、`CFBundleVersion = 44`；
- macOS Release：同样 0.5.28 / 44；
- iOS Simulator Debug：同样 0.5.28 / 44；
- About 窗口读 `Bundle.main`（`XYZ/Workspace/EditorCommands.swift:1288-1289`），因此 About 显示的版本也来自这套生成后的 plist。

**隐含依赖**：两个手写 plist 本身**不含**版本键（`XYZ/Info.plist`、`XYZ/Info-macOS.plist` 均无 `CFBundleShortVersionString`/`CFBundleVersion`），版本能出现是因为 `GENERATE_INFOPLIST_FILE = YES`（`project.pbxproj:444`、`:489`）会把 `$(MARKETING_VERSION)`/`$(CURRENT_PROJECT_VERSION)` 合并进指定 plist（实测 macOS 产物同时含手写键 `NSUbiquitousContainers` 与生成键 `LSMinimumSystemVersion=14.0`）。一旦有人把 `GENERATE_INFOPLIST_FILE` 关掉，版本会静默消失。

**建议**：CI 增加一行断言（`plutil -extract CFBundleShortVersionString` 必须等于 `Config/Base.xcconfig` 里的值），把「单一来源」变成可执行契约。

### 1.3 DEVELOPMENT_TEAM 空值 + CI 关签名：CI 产物不是用户运行的那个 app

**结论**：`Config/Base.xcconfig:4` 的 `DEVELOPMENT_TEAM =` 为空、`:5` 用 `#include? "Local.xcconfig"` 读取本地（被 `.gitignore:10` 忽略，`git ls-files Config` 只有 `Base.xcconfig` 和 `Local.xcconfig.example`）；CI checkout 后没有 `Local.xcconfig`，团队 ID 为空，且 CI 显式关闭签名（`.github/workflows/ci.yml:71-75`、iOS 步骤 `:209-212`）。

更关键的是**重签名剥离 entitlements**：CI 每个启动步骤都执行 `codesign --force --deep --sign - "$APP"`（ci.yml:83、:135、:156、:180）。对同类本机构建产物实测：

- `build/analysis-macos/Build/Products/Debug/XYZ.app`：`codesign -dv` → `Signature=adhoc, linker-signed`，`codesign -d --entitlements -` **输出为空**；
- `build/analysis-macos-release/…/Release/XYZ.app`：同样 ad-hoc、无 entitlements；
- 对照 `/Applications/XYZ.app`（0.5.27 安装版）：带 `com.apple.security.app-sandbox=true`、`network.client`、`files.user-selected.read-write`、`files.bookmarks.app-scope`、iCloud container、`get-task-allow`，由 `Apple Development: Zhichao Li (T293LA2YX9)` 签名。

CI 注释（ci.yml:132-134）写「unsigned CI build carries iCloud entitlements，ad-hoc sign without them so the process can start」——**前半句与实际不符**：`CODE_SIGNING_ALLOWED=NO` 的构建不嵌入 entitlements（实测为空）；后半句描述的操作确实会去掉/不会带上 entitlements。结果是：CI 的 gutter / launch / menu / acceptance 全部运行在**非沙盒**进程中。

**影响**：

- 沙盒相关的真实缺陷（security-scoped bookmark、容器内路径、iCloud 文档范围、用户选择文件权限）永远不会被 CI 发现；
- 0.5.28 反复强调的「用户 Mac / iCloud 未验证」在 CI 侧有结构性原因，而不只是环境缺失；
- 每个启动步骤重复一次 `--deep` 重签（Apple 明确不推荐 `--deep`），并且一旦某天真把 app 签上 entitlements，这套 ad-hoc 重签会直接失败/崩溃。

**建议**：把 CI 拆成「无签名快速构建」与「有 team 的 advisory 签名构建」两条；后者用 secret 注入 `DEVELOPMENT_TEAM`，启动带 entitlements 的 app 做最小 smoke；若短期不签，至少在 README/CHANGELOG 明确「CI 的 UI 证据来自无沙盒进程」。

### 1.4 Hardened Runtime 关闭：发布配置不可公证

`project.pbxproj:442`（Debug）与 `:487`（Release）都是 `ENABLE_HARDENED_RUNTIME = NO`。README:114 解释「off so that unsigned build can succeed」——但 CI 是 `CODE_SIGNING_ALLOWED=NO`，根本不签名，Hardened Runtime 与「unsigned build 能否成功」无关，这条解释是误导性的。

**影响**：macOS 直接分发的公证（notarytool）要求 Hardened Runtime；只要 Release 保持关闭，就不可能有可公证产物。当前安装版用的是 Apple Development 证书（本机实测），不是 Developer ID，也不能对外分发。

**建议**：Release 打开 Hardened Runtime（Debug 可关）；补 `archive` + `notarytool` 的发布脚本；README 改掉不准确的因果关系。

### 1.5 Debug / Release 差异

**相同**（两配置逐项一致，说明「按配置切换」的能力基本没用上）：`ENABLE_HARDENED_RUNTIME=NO`（`:442`/`:487`）、`CODE_SIGN_ENTITLEMENTS` 及 sdk 条件（`:437-440`/`:482-485`）、`GENERATE_INFOPLIST_FILE=YES`（`:444`/`:489`）、`INFOPLIST_FILE` 及 macOS 覆盖（`:445-446`/`:490-491`）、`PRODUCT_BUNDLE_IDENTIFIER=com.lizhichao.XYZ`（`:461`/`:506`）、`SUPPORTED_PLATFORMS`（`:465`/`:510`）、`SWIFT_VERSION=5.0`（`:471`/`:516`）、`SWIFT_STRICT_CONCURRENCY=minimal`（`:470`/`:515`）、`ENABLE_PREVIEWS=YES`（`:443`/`:488`）。

**不同**：`DEBUG_INFORMATION_FORMAT` dwarf → dwarf-with-dsym（`:366`/`:415`）；`GCC_OPTIMIZATION_LEVEL` 0 → s（`:372`/`:420`）；`SWIFT_OPTIMIZATION_LEVEL` -Onone → -O（`:383`/`:426`）；Release 加 `SWIFT_COMPILATION_MODE=wholemodule`（`:425`）、`ENABLE_NS_ASSERTIONS=NO`（`:416`）；Debug 有 `ENABLE_TESTABILITY=YES`（`:368`）、`ONLY_ACTIVE_ARCH=YES`（`:380`）、`SWIFT_ACTIVE_COMPILATION_CONDITIONS=DEBUG`（`:382`）。实测 Debug 产物是 arm64-only，Release 是 universal（x86_64+arm64）。

**缺口**：

- CI 只构建 **Debug**（ci.yml:70、`:208`），Release 的 wholemodule/`-O` 路径从未在 CI 编译（本机 Lead 构建通过，只是这次运气）；
- 无 `SWIFT_TREAT_WARNINGS_AS_ERRORS`、无 `GCC_TREAT_WARNINGS_AS_ERRORS`，warning 不会阻断；
- Swift 6.4.2 工具链下仍是 Swift 5 语言模式 + minimal 并发检查：并发正确性不设防（见 P2）。

### 1.6 macOS / iOS target 与 Info.plist、entitlements 的一致性

**结构**：单一 `PBXNativeTarget`（`project.pbxproj:211-231`），`SDKROOT=auto`（`:464`/`:509`），`SUPPORTED_PLATFORMS = iphoneos iphonesimulator macosx`（`:465`/`:510`），用 `[sdk=…]` 条件切换 plist 与 entitlements（`:437-440`、`:445-446`、`:482-485`、`:490-491`）。

**一致的部分**（实测产物）：

- `NSUbiquitousContainers` 容器 `iCloud.com.lizhichao.XYZ` 同时出现在 `XYZ/Info.plist:55-66`、`XYZ/Info-macOS.plist:67-78`，与 entitlements 的 `icloud-container-identifiers` / `ubiquity-container-identifiers` / `icloud-services=CloudDocuments` 对齐（`XYZ/XYZ-macOS.entitlements:13-24`、`XYZ/XYZ-iOS.entitlements:5-16`）；macOS/iOS 两个内置产物都含该键。
- macOS-only 能力只在 mac entitlements：App Sandbox（`:5-6`）、`network.client`（`:7-8`，README:16 说明 iOS 不加该键，符合 WKWebView 在 iOS 沙盒的默认行为）、user-selected read-write（`:9-10`）、app-scope bookmarks（`:11-12`）；iOS entitlements 只留 iCloud（`:5-16`），没有多塞沙盒/网络键。
- `CFBundleDocumentTypes`：两个 plist 都声明 Markdown + plain text（`XYZ/Info.plist:5-31`、`XYZ/Info-macOS.plist:5-30`），macOS 额外声明 folder（`XYZ/Info-macOS.plist:31-43`），与 Mac 文件夹工作区、iOS 文档浏览器的产品定位一致；`UTImportedTypeDeclarations` 两处相同。
- `LSMinimumSystemVersion` 不在手写 plist 里，但由 `MACOSX_DEPLOYMENT_TARGET=14.0`（`project.pbxproj:378`/`:422`）生成，实测 macOS 产物为 `14.0`；iOS 产物无此键（正确）。
- 内置 iOS 产物：`CFBundleShortVersionString=0.5.28`、`UISupportsDocumentBrowser=true`、`LSSupportsOpeningDocumentsInPlace=true`、`NSUbiquitousContainers` 存在、`zh-Hans.lproj`/`en.lproj` 存在。

**不一致/冗余**：

- `INFOPLIST_KEY_*` 全部无条件生效（`:447-455`、`:492-500`），所以**实测 macOS 产物的 Info.plist 里带着 iOS-only 键**：`UILaunchScreen`、`UIStatusBarStyle`、`UISupportedInterfaceOrientations`、`UISupportsDocumentBrowser`、`UIApplicationSupportsIndirectInputEvents`。对一个 macOS app 无功能影响，但说明配置没有按平台收敛，后续接 App Store 校验/审查时会出现无意义告警。
- 容器 ID、bundle ID 在多处硬编码（pbxproj:461/506、两个 plist、两个 entitlements、CLI 第 6 行、`Scripts/xyz-test.sh:31` 等），没有单一常量或 CI 一致性检查（见 P2-5）。

---

## 2. CI 逐 step 评估

工作流：`.github/workflows/ci.yml`（212 行），触发 `push`（全部分支）+ `pull_request`（`:3-5`），`concurrency.group` 按 ref 且 `cancel-in-progress: true`（`:7-9`），`permissions: contents: read`（`:11-12`），单 job `build` 在 `macos-latest`（`:15-16`）。

### 2.1 「Select newest Xcode」（`:20-52`）

- 做法：Python 扫 `/Applications/Xcode*.app`，读 `CFBundleShortVersionString` 按数字 tuple 排序，取最新，写 `/tmp/xyz-xcode-path`，`sudo xcode-select -s`，并把 `DEVELOPER_DIR` 写进 `$GITHUB_ENV`，打印版本。
- **脆弱点**：`macos-latest` 是浮动的（runner 镜像/预装 Xcode 会变）；「永远选最新」意味着同 commit 在不同日期可能用不同 Xcode 编译，历史绿跑不可复现。CHANGELOG:25 记录的云端 run 是「Xcode 26.6, MacOSX 26.5 SDK」，而本机是 Xcode 27.2——同一提交在两套工具链下的结果不等价。
- 使用 `sudo xcode-select -s` 与 `DEVELOPER_DIR` 双保险（`:49-50`）属于冗余；`/tmp/xyz-xcode-path` 固定路径在共享 runner 上可被预置（低风险）；未固定 SDK/模拟器 runtime。
- **建议**：项目文档固定一个 Xcode 版本区间（或 `XCODE_VERSION` env），CI 改为「找指定版本，找不到就显式失败」，避免静默换工具链。

### 2.2 「Test xyz command」（`:54-55`）→ 见 §5，6/6 通过但只测 dry-run 输出。

### 2.3 「Test XYZCore」（`:57-59`）

- `swift test --package-path XYZCore`：只覆盖本地 Swift 包（Lead 实测 191 tests / 0 failures）。**app target 没有任何 XCTest target**（pbxproj 只有 1 个 native target；scheme 的 `TestAction` 为空，`XYZ.xcodeproj/xcshareddata/xcschemes/XYZ.xcscheme:25-30`），所以 WorkspaceSession/WorkspaceView/EditorChrome 等 2 万行 app 代码没有可跑的单元测试。
- 无 `--enable-code-coverage`、无测试结果/`xcresult` 上传、无缓存：每次 run 重新拉 `swift-markdown`/`swift-cmark`（Package.resolved 固定 revision，但网络是额外故障源）。

### 2.4 「Build macOS」（`:61-75`）

`xcodebuild -project … -scheme XYZ -destination 'platform=macOS' -configuration Debug -derivedDataPath build/macos CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=- build`。

- 只 Debug、只 unsigned；`CODE_SIGN_IDENTITY=-` 与 `CODE_SIGNING_ALLOWED=NO` 同时出现属于自相矛盾（后者已让前者失效），只是把「ad-hoc」意图写在命令行里；
- 只有构建，没有任何 `xcodebuild analyze`/`-enableAddressSanitizer`/Release 编译。

### 2.5 「Check Editing line numbers」（`:77-101`）

- 找产物 → `codesign --force --deep --sign -`（`:83`，剥离 entitlements，见 §1.3）→ 设 `XYZWindowShots` 后直接执行 `XYZ.app/Contents/MacOS/XYZ -XYZCheckGutter -ApplePersistenceIgnoreState YES`（`:87`，不用 `open`，无沙盒）→ 90 次 × 1 秒轮询，超时 kill 并 `exit 1`（`:90-101`）。
- `-XYZCheckGutter` 的实现（`XYZ/Editor/GutterSnapshot.swift:9-50`）是在 `applicationDidFinishLaunching` 里同步跑完整套自检后 `exit(0/1)`（hook 在 `XYZ/Workspace/WorkspaceWindowController.swift:602`）：离屏渲染 TextKit 1/2 像素计数、合成层截图、窗口级 `CGWindowListCreateImage` + Vision OCR、文件回读、侧栏 fit、8 个 UI acceptance case。
- **脆弱点**：
  1. **90 秒硬预算**覆盖上述全部内容（含多次截图 + OCR + 8 个 case，每个 case 内部还有 `waitUntil(4)`/`waitUntil(6)`）；慢 runner 上会假红。CI 历史 172/380 失败、最近 100 runs 仅 10 success 与这种重门禁一致（API 核实）。
  2. **窗口截图依赖已废弃 API**：`CGWindowListCreateImage`（`GutterSnapshot.swift:1031`，macOS 15 起 deprecated），需要 Screen Recording TCC；取不到时回退 `compositedImage`（`:1063`，渲染 layer，不是 WindowServer 画面）。代码用「capture control」自检区分盲截（`:458-500`、`:486-497`），这是优点，但也意味着 CI 绿不绿受 runner 的 TCC/WindowServer 行为支配。
  3. **窗口截图看不到 WKWebView**：代码自己承认（`GutterSnapshot.swift:659` 打印 "window picture does not include web views"），CHANGELOG:48 也写明「window capture does not show web-view pixels」。也就是说，产品主界面 Reading（Markdown 渲染）**从未被窗口截图验证**。
  4. 失败时只 `cat` 日志，日志文件（`gutter.log`/`launch.log`/`menu*.log`）**不作为 artifact 上传**；唯一上传的是截图目录（`:117-123`），诊断价值有限。

### 2.6 「Check original UI acceptance」（`:103-115`）

- 读同一个 `gutter.log`，`grep -q 'ACCEPTANCE_OK'` 才通过；否则 grep `ACCEPTANCE` 行并 `exit 1`。
- 实现上这是**诚实的拆分**：body 结果（`GUTTER_OK`/`GUTTER_MISSING`，`GutterSnapshot.swift:41-48`）与 UI acceptance 结果（`:1604-1631`，8 个 case，全部 pass 才打印 `ACCEPTANCE_OK`，否则 `ACCEPTANCE_FAIL N`）分开；CHANGELOG:32 明确「body 结果与 UI acceptance 结果是分开的」。
- **问题**：
  1. **HEAD 目前红在这里**：CHANGELOG:40 记录 `da9730d` 上 5 个 case 失败（nested-file / collapse-header / dividers / mode-labels / empty-line-prefs，`ACCEPTANCE_FAIL 5`），而 `da9730d..HEAD` 对 `XYZ/Editor/GutterSnapshot.swift` **零改动**（`git log --oneline da9730d..HEAD -- XYZ/Editor/GutterSnapshot.swift` 为空），HEAD 仅多出文档/删除 XCUI 的提交。API 核实的 HEAD run `42332912178` 正是在此步失败。
  2. **失败会掩埋后续检查**：acceptance 失败后，后面 `if: steps.macos.conclusion == 'success'` 的 Launch/Menu 步骤被 skip（API 核实的 run 即如此），一次只能暴露一个阶段的问题，导致修复-重跑循环极长（172 次失败、71 次 cancelled）。
  3. **判定方式是 grep**，不是结构化报告；`ACCEPTANCE_FAIL` 的计数和失败项只在日志里，没有 JUnit/摘要。
  4. **「pass」的含义有限**：这些 case 是在同一个进程里对合成 fixture 窗口用 `trackingClick`/事件注入做的（`GutterSnapshot.swift:1618-1625` 及各 `accept*` 函数），不是真实用户输入；XCUI 路径尝试过并放弃（`4785e4c` 加了 `XYZUISmoke` target，`84d4d5d` 又删除；CHANGELOG:25 记录 runner 上 `Runningboard error 5 / Launchd job spawn failed`，应用从未启动）。因此**不存在真实点击/UI 自动化验证**。

### 2.7 「Upload editor window shots」（`:117-123`）

`if: always()` + `actions/upload-artifact@v4`，路径 `build/macos/shots`，`if-no-files-found: ignore`。失败也上传是优点，但只传截图不传日志；且 artifact 默认 90 天过期，CHANGELOG 里大量「cloud window pictures」证据会随时间消失（见 P1-9）。

### 2.8 Launch / Menu / Chinese Menu（`:125-198`）

- Launch（`:125-148`）：重签 → 直接跑二进制 → **只检查 8 秒内没退出**，然后 `kill`。应用挂死/无窗口/白屏都算「通过」。
- Open Folder menu（`:150-172`）：`-XYZCheckFileMenu`（`XYZ/Workspace/FolderOpening.swift:499-527`），检查 File 菜单里 localized 的 "Open Folder…" 项存在、⌘⇧O、target 正确、`openPanelHooked`/`openDocumentHooked`（`:519-525`）→ 打印 `FILEMENU_OK` 并 exit code。范围仅限菜单项/hook，不验证打开面板真的能选目录。
- Chinese menu（`:174-198`）：加 `-AppleLanguages '(zh-Hans)'`，先 `test -d "$APP/Contents/Resources/zh-Hans.lproj"`（`:181`），再 **只 grep 一个 `打开文件夹…`**（`:190`）。catalog 里恰好有这条，所以永真；其余 47 条缺失翻译（§4）测不到。

### 2.9 「Build iOS Simulator」（`:200-212`）

- `-destination 'generic/platform=iOS Simulator'`、Debug、unsigned，仅编译。没有 boot simulator、没有 iOS XCTest/XCUI、没有 `-derivedDataPath`（产物落在默认 DerivedData，不保留）、没有 entitlements 校验。
- 与 macOS 共享同一 target/版本/plist 合并逻辑，iOS 侧编译通过只能说明「能编译」。

### 2.10 CI 结构性缺口

- 无缓存（SPM / DerivedData），每次全量拉依赖+编译；
- 无 `timeout-minutes`（job 默认 6 小时；某次卡死可烧满时长）；
- `push`（全部分支）+ `pull_request` 双触发（`:3-5`），而 `concurrency` 按 ref 分组，**push run 与 PR run 互不取消**，同一提交跑两遍（CHANGELOG 里也分别引用 push run 和 PR run，如第 38 行）；无 `paths-ignore`；
- 构建步骤用 `if: ${{ !cancelled() }}`（`:63`、`:201`），即使 `swift test` 已失败仍继续跑全量 macOS/iOS 构建和 UI 检查（浪费，但也算刻意收集更多失败信息）；
- 无 lint/format 步骤（本机装了 swiftlint 0.65.1 / swiftformat 0.64.6，仓库无配置；Lead 用默认规则跑出 app 468 / core 138 条，多为 style——说明有债但无门禁）；
- 无 plist lint、无 pbxproj/磁盘一致性检查、无版本一致性检查、无 Release 构建、无 archive/公证/tag/release job；
- 无 job 矩阵，无 `xcodebuild test`（因为没有 test target）。

### 2.11 本地可复现程度

- `sh Scripts/xyz-test.sh` 可本地复现（实测 6/6 ok）；`swift test --package-path XYZCore` 可复现（Lead：191/0）；README:84-106 给了 macOS/iOS 的 unsigned 构建命令，Lead 实测 Debug/Release/iOS Simulator 均 BUILD SUCCEEDED（仅 1 条 run-script 警告）。
- **UI 检查不可随手复现**：`-XYZCheckGutter`/`-XYZCheckFileMenu` 没有任何 README/开发文档说明如何本地跑（`grep` 只在 CHANGELOG 和 ci.yml 里出现）；结果依赖 WindowServer/TCC/Vision 与 macOS 版本，本机跑与 cloud runner 跑不等价。
- 本机 `Config/Local.xcconfig` 存在（`DEVELOPMENT_TEAM = Z4FMG2KTPM`，被忽略），所以本地 Xcode 可以签名；干净 clone 不能。

### 2.12 哪些「通过」其实不代表产品正确（明确清单）

| CI 信号 | 实际证明的内容 | 不证明的内容 |
|---|---|---|
| `GUTTER_OK`（body） | 离屏/合成层渲染中 gutter 像素计数、合成 fixture 的窗口 OCR、文件回读没报错 | 真实用户文件、真实字体/输入法、真实窗口合成 |
| `ACCEPTANCE_OK` | 8 个合成 fixture 的进程内事件注入 case 全过（当前 HEAD 过不了） | 真实点击/拖拽、真实 Explorer、XCUI |
| `FILEMENU_OK` + 中文 grep | File→Open Folder 菜单项存在、标题对、hook 装了 | 打开面板真实可用、其余菜单/界面中文化 |
| `swift test` | XYZCore 纯逻辑 | app target 任何代码 |
| iOS build | 能编译 | iOS 运行、iOS 文档浏览器、iCloud |
| Launch 8s | 进程没立刻崩 | 窗口出现、内容正确、不挂死 |
| 全部 | 一个 **无沙盒、无 entitlements、Debug** 的 ad-hoc 二进制 | 用户实际运行的沙盒 Release/iCloud 路径 |

CHANGELOG:36 自己承认「Cloud only. No user Mac, no real input method, no iCloud.」；CHANGELOG:44 承认 0.5.28 未安装、未发布。这是项目诚实性的亮点，也说明验收能力不足。

---

## 3. 版本与发布

### 3.1 0.5.28/44 与文档声明对得上（逐项抽查）

| 声明 | 证据 | 结论 |
|---|---|---|
| 版本 0.5.28 (44) | `Config/Base.xcconfig:6-7`；pbxproj 无覆盖；Debug/Release/iOS 产物 plist 实测均 0.5.28/44 | ✅ 成立 |
| 「0.5.28 是候选，未安装」 | `CHANGELOG.md:5`；本机 `/Applications/XYZ.app` 实测 `0.5.27`/`43` | ✅ 成立（本机实测） |
| 「0.5.27 (43) `a0f85fa…` 仍是安装版」 | `git show a0f85fa:Config/Base.xcconfig` = 0.5.27/43；安装版 0.5.27/43 | ✅ 版本一致；但无法从已装二进制反推 commit，文档的 commit 绑定无法本地证明 |
| 「Rollback that cloud CI accepted: `02dac3c`（0.5.28, build 44）」 | `docs/architecture.md:3`；`git show 02dac3c:Config/Base.xcconfig` = 0.5.28/44 | ⚠️ 版本号对，但「CI accepted」的范围与今天不同（见下） |
| 0.5.28 的改动 commit `02dac3c`/`ee0b4bd`/`d834720` | `CHANGELOG.md:29-32`，三个 commit 均存在 | ✅ 成立 |
| 「0.5.28 未增加 build number 只为记录」 | `CHANGELOG.md:23`；build 44 在 `e3b4b79`（11-03，版本 bump commit）设定后未再变 | ✅ 成立 |

### 3.2 版本身份模糊：一个 0.5.28/44 对应两棵不同的树

- 版本 bump 在 `e3b4b79`（`git show e3b4b79 -- Config/Base.xcconfig`：0.5.27/43 → 0.5.28/44）。
- `02dac3c` 也是 0.5.28/44，`git rev-list --count 02dac3c..HEAD` = **18**：其后 18 个提交（含 0.5.28 记录里的 `ee0b4bd`、`d834720` 等修复）仍共享同一个版本号，且**无 tag**（`git tag` 为空）。
- docs/architecture.md:3 把 `02dac3c` 当作 0.5.28 的 rollback 提交；但 CHANGELOG:21-31 描述 0.5.28 的文本/磁盘竞态修复是 `ee0b4bd`（**在 02dac3c 之后**），New File 修复是 `d834720`（同样之后）。按 docs 回滚到 `02dac3c` 会丢掉 0.5.28 记录里的两个修复。

**影响**：只凭「0.5.28 (44)」无法定位到一段确定的代码；「回滚到 0.5.28」不可执行。对一个宣称用 MAJOR.MINOR.PATCH + build number 的项目，这是发布纪律缺口。

**建议**：在 CI 首绿的那次 commit 上打 `v0.5.28` tag（annotated），把 build number 与 tag 绑定；rollback 文档写 tag 而不是裸 commit；或采用「每个 build number 只对应一个 commit」的规则。

### 3.3 CHANGELOG 的诚实性：是亮点，也证明验收不足

- 0.5.28 段（`CHANGELOG.md:3-44`）明确写了「It is not installed」「a user test of it was not recorded」（`:5`）、撤回 0.5.24/0.5.25 的错误声明（`:11`）、失败项列表（`:40` `ACCEPTANCE_FAIL 5`）、仍未做项（`:44`：XCUI 启动失败、真实中文输入法、iCloud、0.5.28 未安装未发布）。
- README:153 把这种「不把未验证的检查写成通过」写进项目政策，属于工程诚信的正面做法。
- 但同一段文本也暴露：
  1. **验收依赖云端截图/OCR**，而窗口截图看不到 WebView（CHANGELOG:48；`GutterSnapshot.swift:659`）；
  2. **XCUI 尝试失败即放弃**（`4785e4c` 加 target、`84d4d5d` 删除；CHANGELOG:25），没有替代的真实 UI 自动化；
  3. **5 个 acceptance case 记录为失败后未修复**（`da9730d` 之后 `GutterSnapshot.swift` 零改动）；HEAD 的 CI 因此是红的（API 核实 run 42332912178）——「候选版本」在自家门禁上从未绿过。

### 3.4 「CI accepted 02dac3c」的表述不精确（可验证）

- acceptance 检查步骤是后来才加进 CI 的：`git log -S "Check original UI acceptance" -- .github/workflows/ci.yml` → 只有 `da9730d` 一个提交。
- `git show 02dac3c:.github/workflows/ci.yml` 里 grep 不到 `ACCEPTANCE`；`git show 02dac3c:XYZ/Editor/GutterSnapshot.swift` 里 grep 不到 `ACCEPTANCE`（该文件当时还没有 acceptance 输出）。即 02dac3c 的「绿」是**没有 UI acceptance 门禁的绿**。
- 同一份 docs 第 3 行还说「0.5.28 是 this tree 的版本记录」：而今天 HEAD（含 18 个后续提交）与 02dac3c 是两个 0.5.28。把「CI 接受过的 rollback 点」写成 0.5.28 的代表 commit，会让读者误以为 0.5.28 的完整改动曾整体通过 CI。

**建议**：docs 改成「02dac3c：当时 CI（无 acceptance 门禁）通过；当前 acceptance 门禁在 HEAD 未通过」；把 CI 门禁版本化（记录 run 的 commit + workflow 版本）。

### 3.5 无 tag / 无 release 流程的影响

- `git tag` 为空；`.github/workflows/` 只有 `ci.yml`，无 release/notarize job；README 只描述「Build and run」，没有发布步骤；无 `CHANGELOG` release link。
- 已安装 0.5.27 用 Apple Development 证书签名（本机实测），不是 Developer ID，不能分发；Release 无 Hardened Runtime（§1.4），无法公证。
- CHANGELOG 的「证据」是 GitHub Actions run URL（`:17`、`:25`、`:38`、`:40`）与 CI artifact 里的截图，artifact 90 天过期 → 版本记录在数月后不可复核。
- **影响**：无法从版本号重建产物；无法做可信回滚；无法对外发布；审计链依赖易失的云端日志。

**建议**：加 release checklist（tag、archive、notarize、sparkle/下载页、CHANGELOG 校验）；把关键截图/日志以文本摘要形式入库（或至少保留 run ID + commit + Xcode 版本 + artifact hash）；签名改 Developer ID（或明确只内部分发）。

---

## 4. 本地化

### 4.1 catalog 本体

- `XYZ/Resources/Localizable.xcstrings`（49 KB）：`sourceLanguage = en`，**234 个 key**；其中 **232 个有 zh-Hans 翻译**（state 均为 `translated`），仅 2 个 key 标 `shouldTranslate: false`（`English`、`简体中文`，见 `python` 解析与 `AppSettings.swift:52` 的注释「Each language is named in itself」）。
- 编译产物验证：macOS Debug `Contents/Resources/zh-Hans.lproj/Localizable.strings` 实测 **232 key**，与 catalog 一致；`en.lproj` 只有 `Localizable.stringsdict`（`%lld words` 的 plural 变体）。语言列表 `knownRegions` 含 `en/Base/zh-Hans`（`project.pbxproj:251-255`）。
- 机制：代码中**没有** `NSLocalizedString`；用 `String(localized:)`（221 处调用）与 SwiftUI `LocalizedStringKey`（`Text`/`Button`/`Picker` 等），另有 5 处 `String.LocalizationValue` 动态查表（如编码/换行符/菜单名：`XYZ/Workspace/EditorChrome.swift:987`、`:1031`、`:1050`）。因此「catalog 里有 key」是中文显示的前提。

### 4.2 双语承诺不成立：至少 47 条用户可见文案不在 catalog

对 `XYZ/**.swift` 抽取 `String(localized: "…")` 与 `Text/Button/Toggle/Label/Picker/navigationTitle/help/alert("…")` 的字面量（排除字符串插值），与 catalog key 精确比对：**47 个唯一文案缺失**（`Missing`）。代表性证据（全部中文界面会回退英文）：

- 菜单（`XYZ/XYZApp.swift`）：`Find and Replace`（`:107`）、`Use Selection for Find`（`:112`）、`Search Notes`（`:117`）、`Install 'xyz' Command in PATH…`（`:141`）、`Uninstall 'xyz' Command…`（`:144`）、`Settings…`（`:151`）。
- 标签页右键（`XYZ/Workspace/EditorChrome.swift`）：`Unpin`（`:606`）、`Pin`（`:608`）、`Close Others`（`:610`）、`Close to the Right`（`:611`）、`Close All`（`:612`）；状态栏 `Wrapped`（`:326`）、`Wrap`（`:947`）。
- 搜索面板（`XYZ/Workspace/GlobalSearchPanel.swift`）：`Open a folder to search notes.`（`:62`）、`Search files and text`（`:226`）、`All`/`Content`/`Files`（`:241-243`）、`Recent`（`:374`）、`Type to search names and text`（`:377`）、`Ln %lld`（`:175`）、`%lld more`/`%lld+ more`（`:527-529`）。
- 侧栏（`XYZ/Workspace/WorkspaceSidebar.swift`）：`Explorer`（`:824`）、`Refresh Explorer`（`:1082`）、`Collapse All`（`:1083`）、`Expanded`/`Collapsed`（`:1122`）。
- 设置（`XYZ/Settings/SettingsView.swift`）：面板标题 `Settings`（`:132`）、`Latin`（`:50`）、`Chinese`（`:56`）；字体名 `SF Mono`/`Menlo`/`JetBrains Mono`/`PingFang SC`/`Songti SC`/`Heiti SC`（`:52-59`，专有名词可不译，但同样不在表里）。
- 命令帮助（`XYZ/Workspace/EditorCommands.swift`）：`Replace in Folder…`（`:870`）、`Replace in Folder`（`:646`）、`Copy`（`:1797`）、`Go to line 1–%lld`（`:1850`）、安装/卸载 xyz 的说明文本（`:1780`、`:1787-1788`）。

来源判断：catalog 最近一次改动是 `bfc33f7`（2026-11-03），而上述字符串来自 11-03 之后/同期仍在变化的菜单与面板代码；仓库**没有**任何提取/比对脚本或 CI 检查把新字符串同步进 catalog。

### 4.3 catalog 反向漂移：残留已删功能的 key（保守列举）

以下 key 在 catalog 中仍有中文翻译，但当前源码中已无字面量引用，且对应功能已按 CHANGELOG 删除（`grep` 0 次命中）：

- Format 菜单：`Bold`、`Italic`（仅剩 `EditorCommands.swift:915` 的「找系统菜单」用途）、`Bulleted List`、`Numbered List`、`Task List`、`Inline Code`、`Code Block`、`Heading %lld` —— 对应 `CHANGELOG.md:232`「There is no Markdown formatting menu…」。
- 侧栏过滤：`Filter`、`Filter Files`、`Filter files`、`Include files`、`Exclude files` —— 对应 `CHANGELOG.md:222`「The sidebar has no filter field」。
- 旧设置：`Editing always shows line numbers. Reading hides them unless this is on.`、`Show line numbers in Reading mode`、`Show Line Numbers in Reading` —— 0.5.26 起 Reading 不再有行号（`CHANGELOG.md:55`）。
- 另有一批编码/语言/文件类型 key（`UTF-8`、`Windows-1252`、`Markdown`、`Swift`…）可能是 `String.LocalizationValue` 动态查表的有效条目（如 `EditorChrome.swift:987`/`:1031`），**不能**一律当死 key；这也是为什么不建议只看「字面量是否出现」来清理 catalog。

### 4.4 CI 对本地化的保障接近于零

- 唯一的 zh 断言是 `grep -q "打开文件夹…"`（`ci.yml:190`）+ `test -d zh-Hans.lproj`（`:181`）。前者恰好是 catalog 里存在的 key（`python` 验证：`Open Folder…` → `打开文件夹…`），所以该检查**永真**，无法发现 §4.2 的 47 条回退。
- README:46 声称「The interface is in English and Simplified Chinese, from `XYZ/Resources/Localizable.xcstrings`」——对上述菜单/面板不成立。

**建议**：加本地化检查脚本（`xcrun extractLocStrings` 或 `xcodebuild -exportLocalizations` 导出 → 与 catalog diff；或自写 Swift 源码字面量扫描），在 CI 中要求「新增用户可见 key 必须有 zh-Hans」；同时清理死 key；中文检查至少覆盖 File/Edit/View 三个菜单的已知项。

---

## 5. CLI 与脚本

### 5.1 `XYZ/Resources/bin/xyz`（137 行，随 app 打进 `Contents/Resources/bin/xyz`）

功能：`resolve_self` 解析符号链接（`:8-19`）→ 推出 app 路径（`:21-22`）→ `-h/-V/-n/--` 解析（`:72-90`）→ 路径规范化（`:50-70`）→ 经 `/tmp` 临时文件传递（`:92-117`）→ `open -b com.lizhichao.XYZ`（`:119-137`），`XYZ_CLI_DRY_RUN=1` 只打印不执行（`:124-131`）。

实测（仓库内 CLI + 已安装 app 的 CLI）：

- `xyz --version`：已安装版输出 `0.5.27`（读 `Contents/Info.plist` 的 `CFBundleShortVersionString`，`:41-48`）；经 `/tmp` 符号链接调用也输出 `0.5.27` → `resolve_self` 工作。
- `xyz -z`：`unknown option`，exit 2 ✅；`xyz -- -n`：按路径处理，报 `No such file`，exit 1 ✅；`sh Scripts/xyz-test.sh` 6/6 ok ✅。

**Bug（P1）：文档化的 `~` / `~/...` 路径是坏的。** POSIX 规定 `case` 模式要经过波浪号展开，所以 `:53` 的 `~)` 和 `:54` 的 `~/*)` 模式在运行时变成 `$HOME` / `$HOME/*`，永远匹配不到字面量 `~`；参数落到 `:56` 的 `*)` 分支，被拼成 `$PWD/~...` 而报错。实测：

```
$ XYZ_CLI_DRY_RUN=1 XYZ/Resources/bin/xyz '~'
xyz: ~: No such file or directory   (exit 1)
$ XYZ_CLI_DRY_RUN=1 XYZ/Resources/bin/xyz '~/Notes'
xyz: ~/Notes: No such file or directory
```

而 CLI 自己的 `--help` 第 30 行写着「xyz ~/Notes Open a folder.」，README:28 也教用户 `xyz ~/Notes`。`Scripts/xyz-test.sh` 没有覆盖 `~`、空格、`--`、`-V`、未知选项、符号链接等（`:27-48` 只测了 help/./相对文件/-n/missing/bare）。

**其他问题**：

- 可预测临时文件 `/tmp/xyz-cli-paths.$$`、`/tmp/xyz-cli-fail.$$`（`:98`、`:102-105`、`:116-117`）：共享 `/tmp` 上的符号链接/预置文件攻击面 + 并发冲突；应用 `mktemp -d` + `trap`。
- `xyz ""`（空参数）被静默丢弃（`:95-96` 跳过空行），行为等同 `xyz`，与「打开当前目录」直觉不符。
- `resolve_self` 的 `while [ -L "$target" ]`（`:10-17`）无跳数上限，符号链接环会死循环。
- 硬编码 bundle id（`:6`）与 pbxproj:461/506 重复，无一致性检查；bundle id 改动后 CLI 静默失效。
- `exec open $flags "$@"`（`:137`）中 `$flags` 未加引号（shellcheck SC2086），靠参数可控才安全；`resolved=""`（`:92`）为未使用变量（shellcheck SC2034）。

### 5.2 `Scripts/xyz-test.sh`（50 行）

- 覆盖：`--help` 首行、`.`、相对文件、`-n` 多路径、缺失路径错误、无参数（`:27-48`）；用 `mktemp -d` + `trap` 清理（`:22-23`）。本地实测 6/6 ok；CI 每 run 都跑（`ci.yml:54-55`）。
- 盲区：全部是 `XYZ_CLI_DRY_RUN=1` 的**字符串比对**，从未调用 `open`，因此不验证「CLI 真的能打开 app / Launch Services 用 bundle id 找到 app / 沙盒扩展是否授予」；不测 `~`（即上述 bug）、空格路径、`--`、`-V`、未知选项、符号链接、多路径混合、路径规范化。测试期望值本身也是手写的，bundle id/输出格式变化时测试跟 CLI 一起改，无法发现二者不一致。

### 5.3 `tools/make_icons.py`（195 行）

- 依赖：`fontTools` 在**模块顶层** import（`:26-31`），没有 `requirements.txt`/venv pin；本机未安装 fontTools → `python3 tools/make_icons.py --help` 直接 `ModuleNotFoundError: No module named 'fontTools'`（实测）。README:161 只说「It needs fontTools (`pip3 install fonttools`) and Inter…」，没有版本。
- 渲染依赖硬编码路径的 headless Chrome（`:36`；可用 `CHROME` 覆盖），`--headless=new` 每张 60s 超时（`:147-151`）；字体目录 `FONT_DIRS`（`:37-38`）在 `/usr/share/fonts` 递归 glob `**/Inter-*.otf`，可能很慢。
- 可重复性：`--write` 会重写 13 张已入库 PNG（`XYZ/Resources/Assets.xcassets/AppIcon.appiconset/`，最大 52 KB）与 `Design/Icon/*.svg`（`:154-165`）；Chrome/fontTools/Inter 版本变化会产生字节级差异 → 二进制 churn 且无法 review。`Contents.json` 与磁盘文件当前一致（13 个引用、13 张 PNG，无缺失/多余，实测）。
- 无测试、无 CI 步骤、无 `--check` 模式（无法验证「图标是否与脚本一致」）；`write()` 不创建输出目录（`:157` 直接写），目录缺失时报错信息不友好。

---

## 6. 仓库卫生

**好的部分**：

- `git status` clean；`git ls-files` 107 个文件、合计 1.8 MB；`.git` 1.5 MB；无 `build/`、`.build/`、`DerivedData/` 入库（`git ls-files | grep -E '(^|/)(\.build|build)/'` 为空）；最大 tracked 文件是 127 KB 的 `highlight.min.js` 与 117 KB 的 `GutterSnapshot.swift`，仓库很轻。
- `.gitignore` 覆盖 `.DS_Store`（`:2`）、`build/`（`:8`）、`Config/Local.xcconfig`（`:10`）、`xcuserdata` 系列（`:23-26`）、`.build/`（`:29`）、`.swiftpm/`（`:30`）；`Package.resolved` 两处都刻意入库（可复现）。
- `plutil -lint` 对 2 个 plist、2 个 entitlements 全 OK；scheme XML 合法；安装版/构建产物/CLI 可执行位正常（`bin/xyz` 在产物里 `-rwxr-xr-x`，由 pbxproj 的 `Make xyz executable` phase 保证，`project.pbxproj:285-299`）。
- LICENSE (MIT, 2026)、README/CHANGELOG/docs 分层清晰，CHANGELOG 引用 commit 全部存在（实测 `02dac3c`、`a0f85fa`、`2bcd032`、`ee0b4bd`、`d834720`、`fa9b5fe`、`ba42002`、`56bd310`、`4785e4c`、`da9730d`、`d5c4f25` 均 `git cat-file -t commit` 成功）。

**问题**：

1. **无 lint/format 配置、无 CI lint**：本机装了 swiftlint 0.65.1、swiftformat 0.64.6，仓库无 `.swiftlint.yml`/`.swiftformat`；Lead 用默认规则跑出 app 468 / core 138 条（多为 style）。风格债存在但没有任何门禁或基线，未来只会增加。
2. **无 tag / 无 release / 无发布脚本**（见 §3.5）；无 `CONTRIBUTING`、无 COOWNERS、无 issue/PR 模板。
3. **分支策略缺失**：`main` 领先 `feat/ios-app` **154** 个提交（`git rev-list --left-right --count`）；`feat/ios-app` 最后提交 `06fa239` 停在 2026-10-23 19:20（两周前，实质死分支）；`origin/cursor/vscode-style-editor-2a6c` 已通过 PR #4（`db12a62`）合入 main，但远端分支仍未删除。无 tag、无 `git describe` 可用。
4. **提交粒度与风格**：154 个提交中 **153 个落在 2026-11-02~11-03（2 天）**（`git log --format='%ad' --date=short` 统计：11-02 2 个、11-03 151 个、11-07 1 个 merge；`--since/--until` 计数 153）；提交信息像 AI 代理迭代日志，例如 `Try one XCUI click of the Edit menu on the cloud runner`、`Record that the XCUI click never launched on this runner`、`Keep the nested-file click out of the body result`。作者分布：151 个 `LIZHICHAO`、5 个 `Cursor Agent <cursoragent@cursor.com>`；10 个提交带 `Co-Authored-By: Claude Opus 5.5` 与 `Claude-Session: https://claude.ai/code/session_01…` trailer（另有 1 个 `Co-authored-by: Claude`）。信息本身可读、粒度细，适合 AI 迭代，但不适合 code review/审计（一个行为修复分散在多个提交，且大量「记录」类提交）。
5. **CHANGELOG 与提交一致**：0.5.28 的「What changed」列出的 commit 都存在且内容可对应（`git show --stat` 抽查 `ee0b4bd`/`d834720`/`2bcd032`）；CHANGELOG 的失败项（nested-file 等）在代码里仍是未修状态（`GutterSnapshot.swift` 自 `da9730d` 起未变），与 CHANGELOG:40 的「失败就是失败」一致。
6. **两个 `Package.resolved` 漂移**：`XYZCore/Package.resolved` 是旧格式（`"version": 2`），`XYZ.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved` 是新格式（`"version": 3` + `originHash`）；`diff` 仅这两处不同（pins 一致）。但 CI 的 `swift test` 用前者、`xcodebuild` 用后者，未来 bump 依赖时可能只改一处。
7. `.gitignore` 小瑕疵：`DerivedData/` 重复（`:11` 与 `:33`）；无 `*.xcresult`；`build/` 规则只按目录名匹配（当前够用）。

---

## 7. 发现清单（按严重度）

### P0 — 构建/发布/安全/诚信风险

**P0-1 没有任何可发布的构建：无 tag、无 release/公证流程、Release 关闭 Hardened Runtime、安装版是开发证书签名**
- 证据：`git tag` 为空；`.github/workflows/` 仅有 `ci.yml`（无 release job）；`project.pbxproj:487`（Release `ENABLE_HARDENED_RUNTIME = NO`）；本机 `/Applications/XYZ.app` 的 `codesign -dv` = `Authority=Apple Development: Zhichao Li (T293LA2YX9)`（非 Developer ID）；README:114 的理由与 `CODE_SIGNING_ALLOWED=NO` 无关。
- 影响：0.5.28 无法变成可分发产物；公证不可能；用户在 Gatekeeper 下无法安装；「rollback/候选版本」只存在于开发机。
- 建议：Release 打开 Hardened Runtime；加 `archive` + `notarytool` 发布 job（Developer ID 证书/密钥走 secrets）；tag 与 build number 绑定；README 修正 Hardened Runtime 解释。

**P0-2 CI 验证的二进制与用户运行的 app 不同：无签名构建 + ad-hoc 重签剥离 entitlements，CI 从不测试沙盒/iCloud/bookmarks**
- 证据：`ci.yml:71-75`（`CODE_SIGNING_ALLOWED=NO`）、`:83`/`:135`/`:156`/`:180`（`codesign --force --deep --sign -`）；本机同类构建产物 `codesign -d --entitlements -` 为空、`Signature=adhoc, linker-signed`；安装版 0.5.27 带 `app-sandbox`/iCloud/bookmarks（实测）；`ci.yml:132-134` 注释错误地称 unsigned build 带 iCloud entitlements。
- 影响：security-scoped bookmark、容器路径、iCloud 文档、用户选择文件权限、沙盒内 WKWebView 等真实路径零覆盖；CI 绿与「沙盒里能跑」无关。
- 建议：CI 增加带 team 的 advisory 签名 job（secret 注入），跑最小启动/文件读写/bookmark smoke；至少把「CI 无沙盒」写进 README/CHANGELOG，避免误读。

**P0-3 0.5.28/44 在自家 CI 上是红的，且同一版本号对应两棵不同的树（无 tag 可定位）**
- 证据：API 核实 HEAD run `42332912178` 失败于 `Check original UI acceptance`；`CHANGELOG.md:40` 记录 `ACCEPTANCE_FAIL 5`；`git log --oneline da9730d..HEAD -- XYZ/Editor/GutterSnapshot.swift` 为空（失败用例未修）；`git rev-list --count 02dac3c..HEAD` = 18，且这 18 个提交都是 0.5.28/44（`git show 02dac3c:Config/Base.xcconfig` 与 `HEAD:` 相同）；`git tag` 为空。
- 影响：对外若有人按文档 checkout/tag 0.5.28，可能得到未通过验收的树；无法复现「通过 CI 的 0.5.28」。
- 建议：先在 acceptance 全绿时冻结 commit 并打 `v0.5.28`；失败 case 修复前不要宣称 candidate 可发布；把「当前门禁版本 + green commit」写入 CHANGELOG。

### P1 — 高维护成本 / CI 假阳性与假阴性

**P1-1 手写 pbxproj（无 project.yml/xcodegen）→ 新增文件靠手工登记，漏登记会静默不编译**
- 证据：无 `project.yml`（`find`/`ls` 无；xcodegen 2.46.0 已装未用）；pbxproj 无生成器标记；UUID 为 `8A/8B/8C0…` 顺序合成（`project.pbxproj:10`、`:46`）；手写 `PBXFileReference` 39 条、sources 27 条，当前与磁盘 27/27 一致（脚本比对）。
- 影响：维护成本高、易错；CI 不做磁盘↔pbxproj 一致性检查。
- 建议：迁移 xcodegen（`project.yml` 入库）或 CI 加一致性校验脚本。

**P1-2 CI 门禁又慢又红且工具链浮动：380 runs 仅 137 success、最近 100 runs 仅 10 success，失败会 skip 后续步骤**
- 证据：API 核实统计（137/172/71；最近 100 runs 10 success；11-06 单日 16/101/22）；`ci.yml:20-52`「选最新 Xcode」+ `macos-latest`；`ci.yml:90-101` 90 秒硬超时；acceptance 失败后 `if: steps.macos.conclusion == 'success'` 的 launch/menu 步骤被 skip（API 核实的 42332912178）。
- 影响：反馈周期长、一次只暴露一个阶段问题；历史绿跑不可复现（CHANGELOG:25 的 run 在 Xcode 26.6，本机 27.2）。
- 建议：固定 Xcode 版本；给每个 step `timeout-minutes`；失败时用 `always()` 跑后续信息采集步骤；把 acceptance 拆成独立 job 并输出结构化失败清单。

**P1-3 2459 行自检代码常驻发布包（无 `#if DEBUG`），承担「测试框架」职责却不在 test target 里**
- 证据：`XYZ/Editor/GutterSnapshot.swift:9-50`（`-XYZCheckGutter` 全套自检）；hook 在 `XYZ/Workspace/WorkspaceWindowController.swift:602`（同上 `:625` 的 `FileMenuCheck`）无条件编译；pbxproj 只有 1 个 target、scheme `TestAction` 为空（`XYZ.xcscheme:25-30`）。
- 影响：发布二进制包含 Vision/截图/文件回读代码；测试逻辑与产品逻辑耦合（改产品代码必须同时维持自检）；无法用 XCTest 单测 app 层。
- 建议：把自检拆到独立 UI test target（或至少 `#if DEBUG`）；为 WorkspaceSession/WorkspaceFilePolicy 等纯逻辑补 XCTest。

**P1-4 双语承诺对至少 47 条用户可见文案不成立，CI 只检查一个菜单标题**
- 证据：§4.2 的逐条 `file:line`（菜单 `XYZ/XYZApp.swift:107/112/117/141/144/151`；右键 `EditorChrome.swift:606-612`；搜索面板 `GlobalSearchPanel.swift:62/226/241-243/374-377/527-529`；侧栏 `WorkspaceSidebar.swift:824/1082-1083/1122`；设置 `SettingsView.swift:50/56/132`）；catalog 234 key/232 zh（实测）；catalog 最后改动 `bfc33f7`（11-03）；CI 的 `grep 打开文件夹…`（`ci.yml:190`）恰好命中已翻译项。
- 影响：中文用户会看到英文菜单/面板；README:46 的承诺失真。
- 建议：加「本地化提取 + catalog diff」CI 检查；新增字符串强制 zh-Hans；扩展到 File/Edit/View 菜单与搜索面板。

**P1-5 CLI `xyz` 的 `~` / `~/...` 路径按帮助文本宣传但实际不可用**
- 证据：`XYZ/Resources/bin/xyz:53-54`（`~)`/`~/*)` 模式）；`:30`（Usage 示例 `xyz ~/Notes`）；README:28；POSIX 下 `case` 模式做波浪号展开（实测 `sh -c 'case "~" in ~) …'` = NOMATCH）；实测 `XYZ_CLI_DRY_RUN=1 xyz '~'` 与 `xyz '~/…'` 均 exit 1、`No such file or directory`；`Scripts/xyz-test.sh:27-48` 未覆盖。
- 影响：README/帮助教用户的功能直接报错；用户的 shell 脚本会失败。
- 建议：改用 `case $input in "~"|"~/"*) …` 或先做 `$HOME` 前缀判断；补测试（`~`、`~/x`、空格、`--`、`-V`、未知选项、符号链接）。

**P1-6 发布/版本记录依赖易失的云端证据：CHANGELOG 的 run URL + 90 天 artifact，无法长期复核**
- 证据：`CHANGELOG.md:17/25/38/40`（GitHub Actions run URL）；`ci.yml:117-123`（仅上传截图，未上传日志）；截图/日志只存在于 artifact（默认 90 天）。
- 影响：版本记录的「在哪里验证」在数月后不可访问；第三方无法审计。
- 建议：把每个 run 的 commit、Xcode/macOS 版本、关键日志摘要（`GUTTER_OK`/`ACCEPTANCE_FAIL` 行）与截图哈希入库；或使用可长期引用的 release asset。

**P1-7 无 app 测试 target、无 Release 构建、无 lint 门禁：CI 只证明「Debug 能编 + 自检器能跑」**
- 证据：pbxproj 单 target；scheme `TestAction` 空（`XYZ.xcscheme:25-30`）；`ci.yml:61-75` 只 Debug，`:200-212` iOS 只编译；无 lint 步骤（`grep lint ci.yml` 为空）；本机装有 swiftlint/swiftformat 但仓库无配置（`find` 无 `.swiftlint*`/`.swiftformat`）；Lead 默认规则计数 app 468 / core 138。
- 影响：Release-only 编译错误/优化器问题不可见；风格债无门禁；app 层无单测。
- 建议：CI 增加 Release 构建（至少 macOS）；加 lint（先生成基线、逐步收紧）；为 app 层引入 XCTest target。

**P1-8 xyz CLI 使用可预测的 `/tmp` 临时文件（符号链接/并发风险）**
- 证据：`XYZ/Resources/bin/xyz:98`（`/tmp/xyz-cli-fail.$$`）、`:102`（`/tmp/xyz-cli-paths.$$`）、`:103-105`、`:116-117`。
- 影响：共享 `/tmp` 上可被预置符号链接指向任意可写文件（截断/写入），并发调用互相覆盖；属于本地安全卫生问题。
- 建议：`mktemp -d` + `trap 'rm -rf' EXIT`；避免用固定文件名与 `$$`。

**P1-9 未验证即记录的风险：版本记录承认失败，但「已通过」的证据形态（窗口 OCR 截图）看不到 Reading 主界面**
- 证据：`GutterSnapshot.swift:659`（窗口截图不含 web view）；`CHANGELOG.md:48`（window capture 不显示 web-view 像素）；`CHANGELOG.md:44`（XCUI 未启动、真实中文输入法未跑、iCloud 未跑）；`docs/architecture.md:29`。
- 影响：Markdown Reading（产品核心）在窗口级验证里是盲区；其他「通过」项也可能只在合成环境成立。
- 建议：为 Reading 增加 WebKit snapshot 断言（代码里已有 `webSnapshot`，`GutterSnapshot.swift:1003`，但目前只作为旁证）；补真实 IME/iCloud 的验收清单。

**P1-10 图标生成脚本不可复现/依赖未声明**
- 证据：`tools/make_icons.py:26-31`（顶层 import fontTools；本机实测 `--help` 即 `ModuleNotFoundError`）；`:36`（硬编码 Chrome 路径）；`:147-151`（headless Chrome 渲染）；`:154-165`（重写 13 张已入库 PNG）；README:161 只写「pip3 install fonttools」；无 requirements/版本 pin/CI。
- 影响：换机器无法重生成图标；Chrome/fontTools 版本差异导致 PNG 二进制漂移，review 困难；README 与仓库实际能力不符。
- 建议：加 `tools/requirements.txt`（pin）；把字体/Chrome 版本写进脚本；`--check` 模式校验产物哈希；或把渲染移出仓库生成流程。

### P2 — 改进项

**P2-1 `.gitignore` 冗余/遗漏**：`DerivedData/` 重复（`.gitignore:11`、`:33`）；无 `*.xcresult`；建议顺手清理。

**P2-2 macOS 产物带 iOS-only INFOPLIST_KEY**：`project.pbxproj:447-455`/`:492-500` 无条件生效，实测 macOS Info.plist 含 `UILaunchScreen`/`UIStatusBarStyle`/`UISupportedInterfaceOrientations`/`UISupportsDocumentBrowser`/`UIApplicationSupportsIndirectInputEvents`；建议用 `[sdk=iphoneos*]`/`[sdk=iphonesimulator*]` 条件或拆 plist 键。

**P2-3 Swift 5 语言模式 + `SWIFT_STRICT_CONCURRENCY=minimal`（Swift 6.4 工具链）**：`project.pbxproj:384`/`:427`、`:470`/`:471`、`:515`/`:516`；建议逐步升到 Swift 6 模式或至少 `complete` 并发检查，否则并发正确性不设防（该项目大量 `@MainActor`/`Task` 代码）。

**P2-4 CI 成本/触发策略**：`push` 全分支 + `pull_request` 双跑（`ci.yml:3-5`），`concurrency` 按 ref 不互相取消（`:7-9`）；无 `paths-ignore`、无缓存、无 `timeout-minutes`；`if: !cancelled()` 在测试失败后仍跑全量构建（`:63`、`:201`）；artifact 只有截图。建议改触发条件、加缓存与超时、失败时上传日志。

**P2-5 标识符硬编码/多源**：`com.lizhichao.XYZ` 出现在 `project.pbxproj:461`/`:506`、`XYZ/Resources/bin/xyz:6`、`Scripts/xyz-test.sh:31`、README 示例；iCloud container `iCloud.com.lizhichao.XYZ` 出现在两个 plist、两个 entitlements。建议抽到 xcconfig（`BUNDLE_ID`/`ICLOUD_CONTAINER`）并在 CLI 中从 `Info.plist` 读取 bundle id，CI 加一致性检查。

**P2-6 两个 `Package.resolved` 格式/内容漂移**：`XYZCore/Package.resolved`（version 2）vs `XYZ.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`（version 3 + originHash），pins 目前一致；建议统一生成来源并 CI diff。

**P2-7 Launch 检查断言过弱**：`ci.yml:139-148` 只验证 8 秒内进程未退出；建议检查窗口数/标题/主窗口存在（如 `-XYZCheckLaunch` 输出 `LAUNCH_OK` 并断言）。

**P2-8 菜单查找依赖英文标题/本地化标题的 hack**：`EditorCommands.swift:915`（按 `String(localized: "Italic")` 找系统菜单）、`:950`（先比 `"Use Selection for Find"` 英文再退回 action/tag）、`:1122`（View 菜单先按标识符/⌃⌘F 等 action 找，最后才按标题）、`FolderOpening.swift:407`（`item.title == "File"` 兜底）。建议统一用 action/identifier，避免系统语言或 catalog 翻译变化导致失效。

**P2-9 无开发文档描述如何本地复现 UI 检查**：`-XYZCheckGutter`/`-XYZCheckFileMenu` 只出现在 CHANGELOG 和 ci.yml；README 的 Build and run 没有这一步。建议补一节「本地跑 CI 检查」及所需 TCC/WindowServer 说明。

**P2-10 分支/仓库元数据**：`feat/ios-app` 停留 2026-10-23（`06fa239`），`origin/cursor/vscode-style-editor-2a6c` 已 merge 未删；无 `CONTRIBUTING`/CODEOWNERS/issue 模板；建议删已合并分支、明确 `feat/*` 生命周期。

**P2-11 提交历史是 AI 迭代日志**：154 个提交中 153 个在 2 天内、5 个 Cursor Agent、10 个带 Claude session trailer；按「一个行为一个提交」可读，但 review/审计困难。建议发布前 squash 或维护 `release-notes` 映射。

**P2-12 `make_icons.py` 无 `--check`、CI 不校验图标产物**：见 P1-10；可在 CI 加 `--sheet` 快速冒烟或哈希校验（低成本）。

---

## 8. 附：本次分析的实测命令与结果（可复核）

| 命令 | 结果 |
|---|---|
| `sh Scripts/xyz-test.sh` | 6/6 `ok`，exit 0 |
| `sh -n Scripts/xyz-test.sh` / `sh -n XYZ/Resources/bin/xyz` | 语法 OK；`shellcheck` 报 5×SC1007、1×SC2034、1×SC2086 |
| `plutil -lint` ×4 | 全部 OK |
| `XYZ_CLI_DRY_RUN=1 xyz '~'` / `'~/dir'` | exit 1，`No such file or directory`（bug 确认） |
| `/Applications/XYZ.app/.../xyz --version` / 经符号链接 | `0.5.27` / `0.5.27` |
| `codesign -dv` 本机构建产物（Debug/Release） | `Signature=adhoc, linker-signed`；`--entitlements` 为空 |
| `codesign -dv/--entitlements` 安装版 | Apple Development 证书；含 app-sandbox、iCloud、bookmarks、network.client、get-task-allow |
| `plutil` 内置 macOS Debug/Release + iOS plist | 均 `0.5.28`/`44`；macOS `LSMinimumSystemVersion=14.0`；iOS `UISupportsDocumentBrowser=true` |
| catalog 解析 | 234 key / 232 zh-Hans / 2 `shouldTranslate:false`；内置 `zh-Hans.lproj` 232 条；源码缺失 key 47 个 |
| 图标 catalog | `AppIcon.appiconset` Contents.json 13 引用 ↔ 13 PNG 一致；`make_icons.py --help` 报 `ModuleNotFoundError: fontTools` |
| git | HEAD `db12a62`；main 领先 `feat/ios-app` 154 个提交；0 tag；153 个提交落在 11-02~11-03 |
| Lead 实测（引用） | macOS Debug/Release、iOS Simulator Debug `BUILD SUCCEEDED`（1 条 run-script 警告）；`swift test` 191/0；swiftlint 默认规则 app 468 / core 138 |

> 说明：以上「API 核实」与「Lead 实测」的数据来自 Lead 的 GitHub API/本地构建，不在本会话内重复抓取；本报告其余结论均可由仓库内文件与上表命令复现。
