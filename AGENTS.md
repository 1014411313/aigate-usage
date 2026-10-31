# 仓库协作规则

本工作区是**多项目仓库**（远程 `1014411313/aigate-usage`），一个子目录一个项目：
`aigate-usage/`、`github-hosts-app/`、`hyperos-thermal-module/`、`xiaomi-8Elite-charge-boost/`、`gpu_autoboost/` 等。

## 通用

- 只在当前任务相关的子目录内改动，不动其它项目，不擅自 `git commit` / `push` / `reset`。
- 提交信息用中文，沿用仓库现有风格（`feat:` / `fix:` / `chore(release):`）。
- GitHub 在容器里经常连不上，推送要写重试；不要因为一次失败就放弃或改用其它通道。
- 改完代码先自验（语法检查、静态校验、能跑就跑），再汇报；未验证的部分要如实说明。

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

### 发布流程

1. 改完执行 `python3 tools/release.py build`，把 zip 发到聊天里给用户测试。
2. **每次发布前必须更新 `src/更新日志.log`**：在文件末尾追加本版改动，按「界面 / 修复 / 优化」三类分条写，不要等用户提醒。
3. 用户说「发布」后执行 `python3 tools/release.py publish`（一条命令完成清单更新、清理旧版、提交推送、CDN 校验）。
4. 干跑用 `publish --no-push`。

### 界面统一性（强制，不要等用户提醒）

- 新增或修改的任何 UI **必须复用页面已有样式类与组件**：`notice-mask` / `notice-card` / `notice-title` / `notice-body` / `btn` / `btn secondary` / `pref` / `card` / `mini-grid` / `small-title` 等，不得自带一套独立内联样式。
- 弹层一律沿用欢迎弹窗那套组件，保证圆角、阴影、`noticeIn` 入场动画、`--fs` 字号缩放、主题变量一致；层叠 `zIndex: 100001`。
- 弹层属于「必须看清」的元素：**不跟随外观页的卡片透明度**，背景按主题取近实色（浅 `rgba(255,255,255,.97)` / 深 `rgba(28,28,30,.96)`），正文用 `var(--text)`，禁用次要色。
- 颜色、圆角、字号一律走 CSS 变量，适配浅色 / 深色主题与字体缩放。
- 不使用系统原生 `confirm` / `alert`（会弹「file:// 的网页显示」），统一走自绘弹层。

### 工具与路径

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
