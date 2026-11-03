# 仓库协作规则

## 开工第一步（强制，先于一切动作）

任何会改文件的动作之前，回复或待办里的第一项必须是「分工决定」：

1. 定级：A 小改（单文件 <50 行）/ B 常规（单模块）/ C 有风险（跨文件、发布链路、数据契约、权限）/ D 疑难。
2. 写清「派给谁 + 档位 + 文件所有权」；不派时写明理由，且理由只能是：只读诊断、验收抽查、架构决策、不可逆操作、密钥，或改动小于派发开销（当场说明）。
3. 没有这条决定，不得调用修改文件的工具。

事实（容易误判）：`task` 省略 `agent` 参数会创建**继承本会话全部工具的默认通用子代理**，可写文件、可执行命令；「可用子代理」清单里的 Explore 只是只读代理之一，不代表没有可写代理。

远程 `1014411313/aigate-usage`。**2026-11-03 起以统一版 App 为主项目**：

```
app/                        控制端 App 源码（com.MiWKJR）：WebView 界面 + NativeShell 白名单 Root API + LSPosed 背屏 Hook
hyperos-thermal-module/     Root 模块（MiWKJR）：温控/解容脚本、api 采样、模块管理器只读页、构建与发布工具
docs/                       architecture.md（组件与数据流）、build-and-maintenance.md（构建/打包/发布）
archive/                    已存档独立项目：aigate-usage、github-hosts-app、gpu_autoboost、perf-tuner、mcp-client
health/                     个人文档，与项目无关
xiaomi-8Elite-charge-boost/ 独立 Git 仓库（嵌套），保持原位，勿移动其 .git
```

整理说明（2026-11-03）：

- 统一版 App 与模块代码已从 `work/unified-app` 工作树迁入 `main` 工作树；`/root/unified`、`/root/rs_beta`
  两个旧工作树仍保留原状（其未提交改动未动）。
- 仓库外备份在 `/root/repository-backups/2026-11-03/`：`main-current/`（整理前模块全量 + 逐文件 SHA-256 清单）、
  `unrelated-main/`（旧项目与素材）、`workspace-module-before-swap/`（替换前模块目录）、`workspace-state/`（整理前状态分片）。
- 旧解包副本、历史 ZIP、一次性素材已移出工作区（备份后删除）；旧下载链接不再维护，
  根级 `dist/latest.json` 旧更新入口已于 2026-11-03 下线，旧版客户端不再收到更新提示。

## 分工（强制）

完整流程见 [docs/team-process.md](docs/team-process.md)（老板已确认 v1），要点：

- 老板只定目标、优先级与拍板；**副总（主代理）负责拆解、定级、派单、验收、汇报，不亲自写业务代码**。
- 主管＝子代理 standard/strong 档（出方案、拆子任务、评审）；员工＝子代理 light 档（搜索、机械修改、跑测试、打包核验）。
- **任务四级定流水线**：A 小改→派 1 员工 + 副总抽查；B 常规→派 1 员工 + 副总抽查关键点；C 有风险（跨文件 / 发布链路 / 数据契约 / 权限）→主管出方案 + 主管 Review + 副总终审；D 疑难→副总只读定性 + 必要时 strong 档 + 副总终审。
- **副总自己动手**仅限：只读诊断、验收抽查、架构决策、发布/推送/删除等不可逆操作、密钥；以及工作量小于派发开销的小事（需当场说明为什么没派）。
- 子代理不能嵌套派子代理，全局最多 5 个并发；同一文件同一时间只允许一个代理写。
- 派活六要素：目标、已核实事实、输入输出、允许改动范围、验收标准、禁止事项（另加文件所有权）。
- **省钱硬规则**：一次派完整；同一问题 2 次未果即停，不允许第 3 次；已核实事实不重查；档位就低；对老板不贴工作日志。
- 保留在副总、不外派：架构取舍、跨条线接口、密钥与发布、破坏性操作、最终验收。

## 通用

- 只在当前任务相关的子目录内改动，不动其它项目，不擅自 `git commit` / `push` / `reset`。
- 提交信息用中文，沿用仓库现有风格（`feat:` / `fix:` / `chore(release):`）。
- GitHub 在容器里经常连不上，推送要写重试；不要因为一次失败就放弃或改用其它通道。
- 改完代码先自验（语法检查、静态校验、能跑就跑），再汇报；未验证的部分要如实说明。
- 思考过程（推理）一律用中文写，不用英文。

## Bug 反馈处理（强制：先记，等「修复」再统一修）

- **收到 bug 反馈只记录，不动代码**：用户发来的报错、截图、诊断包、口头描述（「xx 不对」「闪退」「显示错误」等）一律先写进 `hyperos-thermal-module/state/bugs.json` 的 `collecting`，**不顺手改 `src/`、不打包、不发版、不改版本号**。
- 允许做**只读排查**再落条目：读代码定位可疑行、解包分析诊断包、写临时复现脚本（放 `~/workspace/.aicode/tmp/`），把结论写进条目的 `root_cause` / `evidence` / `affected` / `fix_plan`，但不动源码。
- 条目字段固定：`id`（bug-00N）、`title`、`reported`、`evidence`（截图/日志/诊断包路径）、`root_cause`、`fix_plan`、`affected`（文件:行）、`status`（默认「待修」）。
- 同一条问题再次反馈时**不新建条目**，在原条目补 `evidence` 并更新时间；用户表达的是需求而非 bug 时，同样先记（`type: feature`），不要直接开做。
- **只有用户明确说「修复」/「统一修复」/「开始修」才动代码**，且以一次性处理 `collecting` 全部条目为准：逐条对照 `fix_plan` 修，不要只挑其中一条。
- 修复完成：条目从 `collecting` 移到 `fixed`，补 `fixed_in`（版本号 codeN）与 `status`（写明待真机复测/未发布），版本历史追加到 `release.json`；新功能类条目仍走「使用说明四件套」。
- 用户明确说某条不做时，移到 `cancelled` 并注明「用户决定不做（日期）」，不再重提。
- bug 修复与功能开发不混在一次改动里；用户没说修复，但期间有其它功能任务，功能照做、bug 只继续攒。

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
| `bugs.json` | 用户反馈收集区：先攒，等用户说「修复」再统一修 |
| `pitfalls.json` | 踩坑与已定方案 |
| `device.json` | 本机信息与当前运行状态 |

规则：

- **新会话：先读 `state/index.json`**，再按任务只读相关分片；不需要用户发提示词。
- **每次任务结束：更新相关分片**（版本号写进 `index.json` 的 `meta.current_version`，版本历史追加到 `release.json`，状态/待办变化同步到 `device.json` / `index.json`）。
- 涉及不相关模块时不要读无关分片，保持上下文精简。

## 发布类操作（硬性）

- **本地打包不需要征求同意**：改完直接打包并发给用户测试。
- **UI 改动是唯一例外**：凡是改到界面的，先出预览图给用户看，用户点头后才打包（见下节）。
- **上传 / 推送 / 更新线上清单必须等用户明确同意**（用户会说「发布」「上传」）。同意只对当次有效。

## UI 修改预览（强制：先出预览图，用户点头再打包）

- 适用范围：`src/hyperosui/index.html` 的页面/弹层/样式/文案排版/主题/图标，以及控制台 APK 的资源与界面改动。
- 改完**先渲染预览图发到聊天里**，等用户明确说「打包」/「可以」/「就这样」才执行 `tools/pack.py` 或 `tools/release.py build`；**没点头不打包、不改版本号、不发包**。只改脚本/后端/温控逻辑的不受此限，照旧直接打包。
- 预览图要能看清改动点：涉及的页面与弹层各一张，浅色与深色主题各一张，窄屏（320/360px）与默认宽度各一张；只贴与改动相关的图。
- 渲染方式（容器内已验证可用）：用 `/root/.aicode/venvs/skills/bin/python`（已装 Playwright）跑脚本，**Firefox headless + `firefox_user_prefs={"security.sandbox.content.level": 0}`（或 `MOZ_DISABLE_CONTENT_SANDBOX=1`）**；chromium 在本容器必然 SIGTRAP(133)，不要用。
- 直接 `file://` 打开 `src/hyperosui/index.html`，页面启动时就探测命令通道，所以必须用 `add_init_script` **在页面脚本前**给 `window.ksu`（不是 `__kexec`，那是页面内部函数）：
  ```js
  window.ksu = { exec: function (cmd, opts, cb) {
    let out = ''; for (const [k, v] of MAP) if (cmd.indexOf(k) >= 0) { out = v; break; }
    setTimeout(() => { if (window[cb]) window[cb](0, out, ''); }, 0);
  } };
  ```
  `MAP` 按命令关键字返回假 stdout（`status_kv.sh` 造整机读数、`detail_kv.sh` 造容量/寿命，字段名照脚本实际输出，不匹配的格子会显示 `--`）；没 mock 到位时页面会提示「未检测到 root 命令通道」。要预置皮肤就复制一份 HTML，把 `data-skin` 与 `--p` 写死进首屏再截（页面定时器会把 evaluate 改的样式刷回真实值）。
- 预览文件放 `~/workspace/.aicode/tmp/ui_preview/<日期>/`（`.aicode/` 已在 .gitignore），用 `sendFile` 发图，并说明「改了什么、看图看哪里、当前只是源码预览未打包」。
- 用户提修改意见就改完重新出图，循环到用户点头为止；用户当次说「不用预览，直接打包」按当次放行，下一次 UI 改动仍要预览。
- 截图已知坑：容器浏览器对大圆角 `backdrop-filter` 页面可能截出空白，此时截前给 body 加 `fx-lite` 并 inline 禁用 animation/backdropFilter（几何与 canvas 用 evaluate 验），但要在发图时说明「毛玻璃/流光实际观感预览图不还原，以真机为准」。

## hyperos-thermal-module（温控解容工具箱）

模块 id `MiWKJR`，二改整合版：动态温控 K2 + 电池解容工具箱 v3.9.6 + 公版 PPS + DTBO 刷入。
维护者：小米热炸了。原作者：Axiaojiux（动态温控）、听夜风1337（解容工具箱）。

### 目录

```
src/                 模块源码（battery/ 为解容子模块，api/ 为 Root API 与只读采样，hyperosui/index.html 为控制台界面）
tools/build_app.py   构建控制端 App：python3 tools/build_app.py（ECJ + d8 + aapt2 + 原证书签名，产物 build/MiWKJR.apk）
tools/pack.py        打包模块：python3 tools/pack.py [输出路径]
tools/release.py     build 版本号 +1 并打包到 dist/（不发不推）；publish 更新 latest.json、只留最近 3 版、提交推送、校验 CDN
dist/                发布包，命名「温控解容工具箱_vN.zip」
latest.json          版本清单
upstream/            双上游同步基线（manifest.json + base/ 快照）
```

### 使用说明（强制，不要等用户提醒）

- **每次新增功能**（新页面、新开关、新脚本能力、新参数、新的交互方式）必须在同一次改动里做全四件事：
  1. 更新完整使用说明：`src/hyperosui/index.html` 里的 `USAGE_TEXT` 常量（关于页 →「使用说明」弹层显示），按【主页/温控/电池/外观/关于】分组补上「这个功能是什么、怎么用、有什么前提」；
  2. 更新欢迎页摘要：`.notice-title` 下方 `.notice-body` 加一行要点（欢迎页只放摘要 + 指向完整说明，不贴全文）；
  3. 往 `src/更新日志.log` 末尾追加本版条目；
  4. 有默认值/开关的，同步写进 `src/default_settings.json` 或 `src/battery/config/settings.conf`（带注释）。
- 说明写「是什么 + 怎么用」，不要写成更新摘要；一个功能一行，太长就换行。

### 发布线（强制：只维护统一版一条线）

- **只维护统一版**：分支 `main`，包名 `温控解容工具箱_统一测试版_vX.Y.Z-unified.zip`；真机验证通过后转正式命名 `温控解容工具箱_vX.Y.Z.zip` 进 `latest.json`。
- 旧线于 2026-11-03 停止维护：`test/rearscreen`（背屏线）本地与**远端分支**及 `/root/rs_beta`、`/root/unified` 两个工作树已删除（远端 `git push origin --delete test/rearscreen` 已完成），备份在 `/root/repository-backups/2026-11-03/cleanup-2026-11-03/`。
- `test/main` 冻结：不再发新包，保留备查，不新增提交。
- **背屏只走统一版方案**：App `com.MiWKJR`（LSPosed legacy82）+ 作用域 `com.xiaomi.subscreencenter`，Hook `SubScreenLauncher` 贴 `CardOverlay`，数据走 `content://com.MiWKJR.rearsnapshot`。不再维护独立 `rearcard` 壳与 `am --display 1` 投屏方案。
- **当前基线**：统一版 2.1.0-unified（module code 140 / APK versionCode 2001）；上一正式版 v2.0.0（code 124）仍在线。
- 只有统一版允许 `tools/release.py publish`（改 `latest.json`、清理旧版、提交推送、校验 CDN）。
- 发版本时文件名必须带线别，避免用户装错包。
- **`main` 的 `dist/` 只允许放统一版测试包与正式包命名**，其它线别包与历史遗留命名一律不入库（`release.py publish` 的 stage 已按命名排除）。

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
