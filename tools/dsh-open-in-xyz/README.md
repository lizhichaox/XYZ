# dsh-open-in-xyz

> XYZ 仓库内的本地 DSH 插件（`tools/dsh-open-in-xyz/`）。**不发布**：npm 包标记为
> `private`，不进插件市场，只从本 checkout 安装；MIT 许可与 XYZ 仓库根目录一致。

DeepSeek Harness（DSH）本地插件：在**会话头部**放一个「在 XYZ 中打开」分体按钮，
把当前 Session 的工作目录交给本机已安装的 XYZ 打开。外观、尺寸与 hover 行为对齐
官方 Open In 按钮，菜单里另提供「在 VS Code 中打开」（未检测到 VS Code 时隐藏）
和「在 Finder 中显示」。

- 零设置：不加设置页、不写用户配置；Host 半自动探测 XYZ 安装位置。
- 保留官方 `@deepseek-ai/dsh-host-open-in-app` / `@deepseek-ai/dsh-client-ui-open-in-app`：
  文件级「打开方式」、文档预览控件、右键菜单全部照旧，只有会话头部那一个按钮被替换。
- 本地化：`en` + `zh`（其余语言回退英文）。

## 安装（保留官方 Open In 插件）

1. **安装依赖**（profile 目录）：`~/.dsh/profiles/desktop/package.json`

   ```json
   {
     "dsh": { "profile": { "bundles": [ "……", "dsh-open-in-xyz" ] } },
     "dependencies": {
       "dsh-open-in-xyz": "link:/Users/lizhichao/Developer/XYZ/tools/dsh-open-in-xyz"
     }
   }
   ```

   然后在 `~/.dsh/profiles/desktop` 执行 `pnpm install`（用 DSH 自带的 pnpm），
   让 `node_modules/dsh-open-in-xyz` 指向 XYZ 仓库里的 `tools/dsh-open-in-xyz/`。

2. 本包的 `cordis.patch.yml` 通过 `dsh.bundle.patch` 自动把 Host 半插入插件树：

   ```yaml
   - insert:
       - id: open-in-xyz
         name: 'dsh-open-in-xyz'
   ```

3. **重启 DSH**（Host 插件只在启动时加载）。

> 也可以直接 insert：仍按第 1 步把 `dependencies` 指到本 checkout 并 `pnpm install`，
> 但不把 `dsh-open-in-xyz` 加进 `dsh.profile.bundles`，改为在
> `~/.dsh/profiles/desktop/cordis.patch.yml` 里加同样的 `- insert:` 行；两种方式
> 得到同一棵插件树。

## 官方按钮是怎么让位的

两套机制同时生效，互为兜底（都只影响 `conversation.session.header.utilities`
这一个 list slot 里的官方 `open-in-app` 条目）：

1. **Slot 同 id 低优先级 shadow（主）**：`SlotCore` 对 list slot 的同一个 id
   只渲染一个 winner，按 priority 升序取最低者。本插件以
   `id: 'open-in-app', priority: -1` 注册一个渲染 `null` 的条目，官方 header
   组件因此不再渲染。这是 slot 注册 API 自身文档化的替换语义
   （注册冲突报错原文：*"register at a different priority to shadow it (lowest renders)"*），
   不是 DOM hack，官方插件的其它注册（文件级 Open In）不受影响。
2. **极窄 CSS 兜底**：万一未来 DSH 拒绝同 id 注册，样式表里还有两条互补的
   `display:none` 规则：一条匹配该 slot 内带官方 `data-open-target="directory"`
   标记的 split 容器，另一条匹配直接子 `span` 中包裹该标记的 slot 单元
   （`[data-slot="conversation.session.header.utilities"] [data-open-target="directory"]`
   与同前缀的 `>span:has(>[data-open-target="directory"])`）。两条都只命中官方条目，
   匹配不到本插件自己的按钮，也匹配不到其它 slot 或其它 header 工具按钮。

## 安全边界

Host 半只在 `webServer` 上挂 3 条路由，且全部先过 composition 的
`connection.requestRejection()` 信任围栏（Host/Origin 防 DNS rebinding + 浏览器登录态）：

| 路由 | 说明 |
|---|---|
| `GET /open-in-xyz/state` | `{ ok, available, platform, appPath, cliPath }` 可用性探测 |
| `POST /open-in-xyz/open` | 打开工作目录：JSON body `{ "path": "<绝对路径>" }` |
| `POST /open-in-xyz/reveal` | 在 Finder 中显示该目录：同上 body |

POST 路由在围栏之外还做 wire 级校验：`application/json`、64 KiB 上限、仅一个 `path`
字段（多余字段直接拒绝）、必须是绝对路径（≤4096 字符、不含 NUL）、`stat` 确认为
已存在目录；程序固定为 Host 半探测出的 XYZ（`/Applications/XYZ.app`、
`~/Applications/XYZ.app`，或 `/opt/homebrew/bin/xyz`、`/usr/local/bin/xyz` CLI 兜底），
**浏览器无法指定要打开的可执行文件或额外参数**。进程一律通过 `execFile` 的 argv 数组
启动，不经过 shell：应用包走 `/usr/bin/open -a <app> <dir>`，只有 `xyz` CLI 时直接走
`xyz <dir>`，`reveal` 走 `/usr/bin/open -R <dir>`。

## 行为细节

- 按钮：`<mark 9px 墨高> + <chevron 10px>`，24px 高、`.5px` hairline 边框、
  `--dsw-radius-sm` 圆角、11px 字号，hover/focus 与官方一致。
- 头部标记和菜单标记都是**内联矢量 `_xyz` wordmark**（不再是缩小的方形 app 图标）：
  取自 XYZ 图标在小尺寸下（Finder 列表 / Open With 菜单）专用的「small style」字形
  （Inter ExtraBold、更宽更重的字母与字距），任何 DPR 下都是矢量清晰；字母用
  `currentColor` 跟随主题（浅色深字 / 深色浅字），下划线的品牌蓝 `#0078D4` 不变。
  - 头部：9px 墨高（约 28px 宽，和最初版本的视觉体量一致）；viewBox 向上多留了 `y`
    的下伸部高度，使 **x-height 带正好落在盒子中心**，flex 居中后视觉上是居中的
    （不这样做字母会偏高约 1.7px）。
  - 菜单行：同一个 SVG 以 **6.3px 墨高（约 20px 宽）** 绘制。菜单原生的 14px 图标槽
    放不下可辨认的 "xyz"（方图标缩到 14px 时文字只有约 2–3px 高），所以标记以 inline
    style 覆盖 primitive 的 `svg{width:14px;height:14px}` 规则，向两侧各溢出约 3px、
    正好用掉图标与文字间的间隙；行高与文字位置不变。
  原因：完整 app 图标缩到 13px 时，瓷砖里的 "xyz" 只有 ~3px 高，必然糊成一团；
  官方按钮的「应用图标」范式在这个微缩尺寸下无法辨认文字，wordmark 才读得出来。
  插件清单用的 `./icon` 导出是单独的 256px app 图标大图，只用于 Plugins 列表展示。
- 主按钮 = 在 XYZ 打开当前工作目录（`useSessions` 读当前 Session 的 `cwd`）。
- 下拉 = 「在 XYZ 中打开」/「在 VS Code 中打开」/「在 Finder 中显示」。
- VS Code 项复用官方 host 的已装应用目录：探测 `/open-in-app/apps`，图标走
  `/open-in-app/icon/vscode`，启动 POST `/open-in-app/open`（body
  `{ "app": "vscode", "path": "<绝对路径>" }`）。因此不必重复实现应用探测/启动映射；
  VS Code 未安装或官方目录探测失败时，该项自动隐藏（零设置，不需要配置）。
  代价：VS Code 项依赖官方 `@deepseek-ai/dsh-host-open-in-app` 保持启用（默认安装如此；
  XYZ / Finder 两项不依赖它）。
- 探测到 XYZ 不存在时：**整个按钮隐藏**（与官方「没有可解析应用就不渲染按钮」一致），
  并在控制台 `console.warn` 一次。探测返回前会先乐观渲染一次——本地探测很快，已安装
  XYZ 时头部不闪、不位移；只有未安装时会出现一次短暂隐藏。理由：禁用态按钮在 Chromium
  下收不到 hover 事件，tooltip 不可靠；一个永远点不动的按钮只是噪音。
- 请求失败（含并发点击）通过 `contextMenus.notify()` 用当前语言提示；
  同一手势进行中会忽略重复点击。
- 语言：完整 `zh` / `en`，其它语言回退英文。
- 生效方式：只改 `client.js` 不需要重启 DSH——Web 组合里的 `client-hmr` 每 500ms
  stat 轮询各 client bundle，检测到变化后推送 rebuilt 帧，页面里的模块会被热替换；
  若热替换没有生效，刷新页面（Cmd+R）即可。改 Host 半（`index.js` 等）则需要重启 DSH。

## 回滚

1. 从 `~/.dsh/profiles/desktop/package.json` 的 `dsh.profile.bundles` 与
   `dependencies` 里删掉 `dsh-open-in-xyz`；
2. 在 profile 目录执行 `pnpm install`；
3. 重启 DSH，官方 Open In 按钮回归（本插件不再加载，shadow 条目随插件卸载消失）。

也可以临时只禁用插件：在 profile 的 `cordis.patch.yml` 里加
`- id: open-in-xyz` / `disabled: true`（保留依赖，重启生效）。

## 本地自检

在 `tools/dsh-open-in-xyz/` 里执行：

```sh
npm test          # node --check + 无头 smoke
```

`test/smoke.mjs` 不联网、不启动任何应用：先校验清单契约与 256px 插件图标，
再用假的 Cordis ctx 跑 Host 路由（信任围栏、方法、body 校验、启动 argv），
最后用最小 React/模块加载器桩跑 Client 半（slot 注册参数、shadow 优先级、
CSS 选择器、组件渲染，以及忙碌态、错误提示、样式表复用、探测失败等路径）。

## 图标清晰度（2026-11-09 优化）

用户反馈「xyz 的 logo 看不清、太糊了」。根因与处理：

| 方案 | 实际效果 | 结论 |
|---|---|---|
| 256px 大图 app 图标缩到 13px（原方案） | 瓷砖内文字仅 ~3px 高，糊成色块 | 弃用 |
| app 自带 32/64px small-style 图标 | 字母更大更重，但 13px 下仍难辨认 | 弃用 |
| app 图标放大到 16px | 仍看不清 "xyz" | 不采用 |
| 矢量 wordmark（最终方案） | `_xyz` 在 6.3px（菜单）与 9px（头部）墨高下都清晰可读，且深浅色自适应 | 头部与菜单都采用 |

wordmark 由同仓库 `tools/make_icons.py` 的「small style」字体参数生成后内联进
`client.js`（运行时不读取 XYZ 仓库或字体文件）。

## 已知限制

- 官方按钮让位依赖 DSH 的 slot 语义；DSH 大改版后若两套机制同时失效，可能出现
  两个 Open In 按钮（官方 + 本插件），届时按上面「回滚」，或改为不保留官方插件的
  做法：禁用 `@deepseek-ai/dsh-client-ui-open-in-app`（代价是文件级 Open In 一起消失）。
- 只在 macOS 上验证；`reveal` 走 `/usr/bin/open -R`，非 macOS 返回 501。
- 不发布：`private: true`，随 XYZ 仓库一起维护，只从本 checkout 安装；不做插件市场索引。

## 许可

MIT，与 XYZ 仓库一致（见仓库根目录 `LICENSE`）。
