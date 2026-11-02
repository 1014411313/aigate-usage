# 仓库协作规则

本工作区是**多项目仓库**（远程 `1014411313/aigate-usage`），一个子目录一个项目：
`aigate-usage/`、`github-hosts-app/`、`hyperos-thermal-module/`、`xiaomi-8Elite-charge-boost/`、`gpu_autoboost/` 等。

## 通用

- 只在当前任务相关的子目录内改动，不动其它项目，不擅自 `git commit` / `push` / `reset`。
- 提交信息用中文，沿用仓库现有风格（`feat:` / `fix:` / `chore(release):`）。
- GitHub 在容器里经常连不上，推送要写重试；不要因为一次失败就放弃或改用其它通道。
- 改完代码先自验（语法检查、静态校验、能跑就跑），再汇报；未验证的部分要如实说明。
- 思考过程（推理）一律用中文写，不用英文。

## 会话状态（自动维护，不得遗漏）

状态拆成多个分片，放在 `hyperos-thermal-module/state/`，避免一次加载过长上下文：

| 文件 | 内容 |
|---|---|
| `index.json` | 必读：当前版本、分片目录、待办 |
| `thermal.json` | 温控：档位阀值、四场景、旁路、配置加密 |
| `battery.json` | 解容：BAA / smart_fv / PSS / 循环 / 电压 / 协议 |
| `ui.json` | 界面：页面结构、样式规范、取数陷阱 |
| `apk.json` | 控制台 APK：签名、dex/arsc、图标去重 |
| `release.json` | 发布流程、仓库结构、版本历史 |
| `pitfalls.json` | 踩坑与已定方案 |
| `device.json` | 本机信息与当前运行状态 |

规则：

- **新会话：先读 `state/index.json`**，再按任务只读相关分片；不需要用户发提示词。
- **每次任务结束：更新相关分片**（版本号写进 `index.json` 的 `meta.current_version`，版本历史追加到 `release.json`，状态/待办变化同步到 `device.json` / `index.json`）。
- 涉及不相关模块时不要读无关分片，保持上下文精简。

## 发布类操作（硬性）

- **本地打包不需要征求同意**：改完直接打包并发给用户测试。
- **上传 / 推送 / 更新线上清单必须等用户明确同意**（用户会说「发布」「上传」）。同意只对当次有效。

## hyperos-thermal-module（HyperOS - 动态温控·解容）

模块 id `HyperOS_XJ`，二改整合版：动态温控 K2 + 电池解容工具箱 v3.9.6 + 公版 PPS + DTBO 刷入。
维护者：小米热炸了。原作者：Axiaojiux（动态温控）、听夜风1337（解容工具箱）。

### 目录

```
src/            模块源码（battery/ 为解容子模块，hyperosui/index.html 为控制台界面）
tools/pack.py   打包：python3 tools/pack.py [输出路径]
tools/release.py build   版本号 +1、打包到 dist/、不发不推
tools/release.py publish 更新 latest.json、只留最近 3 版、提交推送、校验 CDN
dist/           发布包，命名「动态温控·解容工具箱_vN.zip」
latest.json     版本清单
```

### 使用说明（强制，不要等用户提醒）

- **每次新增功能**（新页面、新开关、新脚本能力、新参数、新的交互方式）必须在同一次改动里做全四件事：
  1. 更新完整使用说明：`src/hyperosui/index.html` 里的 `USAGE_TEXT` 常量（关于页 →「使用说明」弹层显示），按【主页/温控/电池/外观/关于】分组补上「这个功能是什么、怎么用、有什么前提」；
  2. 更新欢迎页摘要：`.notice-title` 下方 `.notice-body` 加一行要点（欢迎页只放摘要 + 指向完整说明，不贴全文）；
  3. 往 `src/更新日志.log` 末尾追加本版条目；
  4. 有默认值/开关的，同步写进 `src/default_settings.json` 或 `src/battery/config/settings.conf`（带注释）。
- 说明写「是什么 + 怎么用」，不要写成更新摘要；一个功能一行，太长就换行。

### 三条发布线（强制，先判线再打包）

| 线 | 分支 | 包名 | 线上清单 |
|---|---|---|---|
| 原版正式版 | `main` | `动态温控·解容工具箱_vX.Y.Z.zip`（无后缀） | 进 `latest.json` |
| 原版测试版 | `test/main` | `动态温控·解容工具箱_原版测试版_vX.Y.Z.zip` | 不进正式清单，包推送到本分支 |
| 背屏测试版 | `test/rearscreen` | `动态温控·解容工具箱_背屏版_vX.Y.Z-betaN.zip` | 不进正式清单，包推送到本分支 |

- **三条线都在远端**：正式版在 `main`，原版测试版在 `test/main`，背屏测试版在 `test/rearscreen`；
  各分支的 `dist/` 里放自己带线别的包，下载链接按分支区分（`@main` / `@test/main` / `@test/rearscreen`）。
- **当前基线**：原版正式版 = **v2.0.0（versionCode 124）**；原版测试版 = v2.0.1（vc 125）；背屏测试版 = 2.1.0-beta（`test/rearscreen` 分支）。
- 只有**原版正式版**允许 `tools/release.py publish`（改 `latest.json`、清理旧版、提交推送、校验 CDN）。
- 测试线打包后**推送到自己的分支**（`git push origin test/main` / `test/rearscreen`），但**不动 `main` 的 `latest.json`**，也不触发 `release.py publish`。
- 背屏版代码只留在 `test/rearscreen`，**不合入 `main`**（曾误合一次，已 reset 回 `d5cfb84`）。
- 测试版改名发送时可直接复制 zip（内容不动），保持与线上包 sha256 可对比。
- 发版本时文件名必须带线别，避免用户装错包。

### 发布流程

1. 改完执行 `python3 tools/release.py build`，把 zip 发到聊天里给用户测试。
2. **每次改动后都要写更新日志**：只要动了模块内容（代码、界面、脚本、配置），就在 `src/更新日志.log` 末尾追加本版改动，按「界面 / 修复 / 优化」三类分条写，不要等用户提醒、也不要只在发布时补。
3. 用户说「发布」后执行 `python3 tools/release.py publish`（一条命令完成清单更新、清理旧版、提交推送、CDN 校验）。
4. **发布完成后必须把下载链接发到聊天里**（CDN 直链 + raw 备用），并**附本次更新要点**（从 `src/更新日志.log` 最新一段提炼 3~6 条，不要贴全文），不要只说「已发布」；
   容器网络抖动弹不出 200 时，如实说明并以发布命令里的校验结果为准。
5. 干跑用 `publish --no-push`。

### 界面统一性（强制，不要等用户提醒）

- 新增或修改的任何 UI **必须复用页面已有样式类与组件**：`notice-mask` / `notice-card` / `notice-title` / `notice-body` / `btn` / `btn secondary` / `pref` / `card` / `mini-grid` / `small-title` 等，不得自带一套独立内联样式。
- 弹层一律沿用欢迎弹窗那套组件，保证圆角、阴影、`noticeIn` 入场动画、`--fs` 字号缩放、主题变量一致；层叠 `zIndex: 100001`。
- 弹层属于「必须看清」的元素：**不跟随外观页的卡片透明度**，背景按主题取近实色（浅 `rgba(255,255,255,.97)` / 深 `rgba(28,28,30,.96)`），正文用 `var(--text)`，禁用次要色。
- 颜色、圆角、字号一律走 CSS 变量，适配浅色 / 深色主题与字体缩放。
- 不使用系统原生 `confirm` / `alert`（会弹「file:// 的网页显示」），统一走自绘弹层。

### 工具与路径

- **构建日期自动写入**：设备信息里的「构建日期」由 `tools/pack.py` 在打包时自动替换为当天日期（源码 `index.html` 里的旧值不维护、不要手改）；本地打包和 `release.py build/publish` 都走这条路径，每次打包后包内日期即为打包当天。
- 签名：`~/android-toolchain/hyperos-xj.keystore`，别名 `hyperosxj`，口令与工具链其它 keystore 一致（从 build18 起使用；升级必须同一签名）。
- arm64 工具（x86_64 版跑不了）：`~/android-toolchain/debs/ext/usr/bin/{zipalign,aapt2}`，需
  `LD_LIBRARY_PATH=.../usr/lib/aarch64-linux-gnu/android:.../usr/lib:.../usr/lib/7zip`。

### 已知坑

- **改 `classes.dex` 后必须重算头部**：`d[12:32]=sha1(d[32:])`、`d[8:12]=adler32(d[12:])`，否则 ART 拒绝加载、App 开机闪退。
- **不要改 dex 里的方法名**：曾把 `hideSystemBars` 等长替换为 `showSystemBars`（校验字段也补了），App 仍闪退；用户已确认状态栏不是必须的，不再尝试。
- 改 `resources.arsc` 优先用**等长替换**；追加字符串要同步 `stringCount`/`size`/`stringsStart` 并整体平移后续 chunk。
- 控制台 APK 内 10 张图标内容相同，资源表路径等长替换为 `res/3S.png` 后可删掉其余 9 张（2.35MB → 259KB）。
- `status_kv.sh` 的 `power_w` 是**档位名**（inf/fast/mid/slow），不是瓦数；真实功率用 `battery_power_w`。
- 中文文件名在 jsDelivr / raw 实测都返回 200，可用。
- `testingcf` 节点的 `latest.json` 缓存滞后明显，`cdn.jsdelivr.net` 与 raw 更及时；检查更新采用多源取最高版本规避。
- 解容侧「温控守护」`thermal_guard` 与动态温控档位都会降充电功率，默认保持关闭，让降功率由动态温控档位统一负责。
