# 构建与维护

## 环境与工具链（外置）

构建工具链与签名凭据都在仓库外 `/root/android-toolchain`：

- `ecj.jar`：ECJ 编译器。
- `platform/android-34-ext12/android.jar`：编译用 android.jar。
- `debs/ext/usr/bin/{aapt2,zipalign}` 与 `debs/ext/usr/lib/...`（arm64，须设 `LD_LIBRARY_PATH`）。
- `build-tools/d8`、`build-tools/lib/apksigner.jar`。
- `hyperos-xj.keystore`：签名密钥库，别名 `hyperosxj`。

这些路径由 `hyperos-thermal-module/tools/build_app.py` 内的 `TOOL` 常量引用；Xposed 编译依赖为 `app/libs/xposed-api-82.jar`。控制端签名须始终使用同一 keystore，升级安装才不被拒。

## 构建控制端 App

在 `hyperos-thermal-module/` 目录下：

```bash
python3 tools/build_app.py           # 编译 + 打包签名，产物 build/MiWKJR.apk
python3 tools/build_app.py --check   # 只跑 ECJ 编译，不出 APK
```

`build_app.py` 会：ECJ 编译 `app/src/main/java` → aapt2 编译/链接资源 → D8 出 dex → zipalign → apksigner 签名，并校验包名 `com.MiWKJR`、`versionCode`/`versionName`、APK 签名与 keystore 一致、`assets/control/index.html` 与 `src/hyperosui/` 源码一致。控制页由 `src/hyperosui/index.html` 经 `control_html()` 生成并注入 CSP 与 `bridge.js`。

## 打包模块 ZIP

```bash
python3 tools/pack.py [输出路径]      # 默认输出到 dist/
```

`pack.py` 从 `src/` 收集文件（排除 `src/hyperosui` 与开发期 `*.bak` 等备份），写入已构建的 APK，并把「构建日期」替换为打包当天；要求存在 `src/webroot/index.html`，并调用 `build_app.verify_apk` 复核 APK 与当前源码一致。

## 版本号与打包（不发不推）

```bash
python3 tools/release.py build [版本号]   # versionCode+1、打包到 dist/，不发不推
```

产物命名 `温控解容工具箱_v<版本>.zip`。改完先本地打包发用户测试。

## 测试与自验

仓库未提供独立测试脚本，现有校验都在构建链里，按改动范围选用：

- `python3 tools/build_app.py --check`：ECJ 编译通过（Java 改动的第一道门）。
- `python3 tools/pack.py`：触发 `verify_apk`，校验 APK 与 `src/hyperosui` 控制页、`bridge.js`、Xposed 入口、签名一致。
- WebUI 个人自验用 Firefox headless 渲染 `src/hyperosui/index.html`，Mock `window.ksu` 命令通道（chromium 在本容器不可用）。
- 真机验证（LSPosed 作用域、Provider Relay、实际充电效果）由用户完成，未验证项须如实说明。

## 配置与凭据

- 签名口令不写入仓库；`build_app.py` 从环境变量 `HYPEROS_KEYSTORE_PASSWORD` 读取（缺省 `android`），失败信息中会屏蔽口令。
- 模块运行期配置与备份在设备上，不进仓库：`/data/adb/modules/MiWKJR/config/`、`/data/adb/MiWKJR_data/`。
- 升级/重装时用户设置由 `config_backup.sh` 同步到 `/data/adb/MiWKJR_data`，安装脚本 `customize.sh` 与 `thermal_core.sh` 启动时优先恢复。

## 发布（须明确授权）

**publish / push / 更新线上清单必须先获得用户明确同意，且只对当次有效。**

```bash
python3 tools/release.py publish                 # 更新 latest.json、只留最近 3 版、提交推送、校验 CDN
python3 tools/release.py publish --no-push       # 干跑，只改本地文件
```

`release.py` 内 `REPO_SLUG = 1014411313/aigate-usage`、`BRANCH = main` 为硬编码；`publish` 会 `git add hyperos-thermal-module`、`git commit`、`git push origin main`，并对 `testingcf.jsdelivr.net` 校验 HEAD 200。

> 注意：`publish` 的 add 范围只含 `hyperos-thermal-module`。2026-11-03 整理后控制端源码在仓库根的 `app/`，
> 发布前需先把 add 范围一并扩到 `app/`（否则 App 源码不会进入提交，线上包与仓库源码会脱节）。

## 版本清单与升级

- `hyperos-thermal-module/latest.json`：更新检查读取的清单，含 `versionName`、`versionCode`、`zip`/`zipCN`/`zipRaw`、`sha256`、`size` 与 `versions[]`（`publish` 以 `dist/` 实际文件重建，保留最近 3 版）。
- 模块版本：`hyperos-thermal-module/src/module.prop` 的 `version` / `versionCode`。
- 控制端版本：`app/src/main/AndroidManifest.xml` 与 `tools/build_app.py` 的 `VERSION_CODE` / `VERSION_NAME`（两处须一致，构建会校验）。
- 更新检查入口：`src/hyperosui/index.html` 的 `UPDATE_JSON` 等常量指向本仓库 `hyperos-thermal-module/latest.json`。

## 上游同步（可选）

```bash
python3 tools/sync_upstream.py list
python3 tools/sync_upstream.py check  <battery|thermal> <上游zip>
python3 tools/sync_upstream.py apply  <battery|thermal> <上游zip> [--include-new rel ...] [--skip rel ...]
```

基线哈希记在 `upstream/manifest.json`，改动过的文件另存快照到 `upstream/<组件>/base/`。
