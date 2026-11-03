# 架构

HyperOS 统一版由三部分组成：Android 控制端 `app/`、Root 模块 `hyperos-thermal-module/`，以及运行在背屏宿主进程内的 LSPosed Hook。

## 组件职责

### app/ — Android 控制端（`com.MiWKJR`）

- `MainActivity`：把构建期生成的 `assets/control/` 拷到缓存目录，用受限 WebView 加载控制页，注入 `NativeShell` 桥。
- `NativeShell`：页面与 Root 之间的固定白名单 API。`request(action, json, callback)` 只放行脚本内的固定 action 集合（`snapshot`、`settings.*`、`battery.*`、`rear.settings.*`、`bypass.*`、`thermal.apply`、`hyperspeed.set`、`device.*`、`module.*`、`notice.*`、`logs.*`、`profile.*`、`backup.*`、`action.run`、`job.get`）以及少数特例（`card.resource`、`apps.list`、`links.open`、`updates.fetch`、`hook.health`），未列出的返回「未授权的 API 操作」。
- `RootRunner`：以 root 执行 `su -c sh /data/adb/modules/MiWKJR/api/app_api.sh <操作> <base64(json)>`，带回 JSON。
- `RearSnapshotProvider`：ContentProvider Relay，`authority = com.MiWKJR.rearsnapshot`，向背屏宿主转发 Root 快照并回收心跳。
- `CardOverlay` / `hook/HookEntry`：LSPosed Hook，作用于 `com.xiaomi.subscreencenter`。

### hyperos-thermal-module/ — Root 模块（`MiWKJR`）

- `src/thermal_core.sh`、`src/thermal/`：动态温控档位与旁路。
- `src/battery/`：电池解容子模块（BAA、smart_fv、PPS、循环、电压等），脚本在 `src/battery/scripts/`。
- `src/api/app_api.sh`：控制端唯一入口分发器，逐操作校验后调用上述脚本或读写配置。
- `src/api/snapshotd.sh`：只读采样守护进程，循环汇总数据生成 `run/snapshot.json`。
- `src/api/snapshot_ro.sh`、`src/api/snapshot.awk`：只读节点采集与快照拼装。
- `src/hyperosui/index.html`：控制端界面源码，构建时经 `tools/build_app.py` 生成到 `app` 的 `assets/control/`。
- `src/webroot/index.html`：模块管理器只读页。

### LSPosed Hook（宿主 `com.xiaomi.subscreencenter`）

`HookEntry` 在宿主 `Application.attach` 后注册活动生命周期回调；当 `SubScreenLauncher` 活动恢复/暂停时，由 `CardOverlay` 挂载或移除背屏卡片覆盖层。

## 数据流

1. 采样：`service.sh` 以 `setsid` 后台启动 `api/snapshotd.sh`。snapshotd 每约 1 秒汇总——`battery/scripts/status_fast.sh`（快变）、`battery/scripts/detail_kv.sh` 与 `api/snapshot_ro.sh`（约每 8 秒或缓存缺失时）、`config/rearscreen.json`、`battery/config/settings.conf` 与运行态——写入 `run/snapshot.input`，再由 `api/snapshot.awk` 生成 `run/snapshot.json`。
2. 发布：snapshotd 将 `run/snapshot.json` base64 后执行 `content call --uri content://com.MiWKJR.rearsnapshot --method publish_snapshot`（仅当检测到已安装 `com.MiWKJR`；安装状态每 300 秒复核一次）。
3. 背屏：控制端 `RearSnapshotProvider` 校验并落盘快照；`CardOverlay` 每 1 秒经 `snapshot` / `card_html` 读取，用受限 WebView 渲染，并通过 `report_health` 回写状态。
4. 控制：控制页 `bridge.js` 调 `NativeShell.request(...)` → 白名单 → `RootRunner` 执行 `api/app_api.sh` → 结果回传页面。
5. 模块管理器页：`src/webroot/index.html` 只读，用管理器 `ksu.exec` 读 `/data/adb/modules/MiWKJR/run/snapshot.json`，约每 1.5 秒轮询，不写入。
6. 更新检查：`src/hyperosui/index.html` 的 `UPDATE_JSON` / `UPDATE_JSON_ALT` / `UPDATE_JSON_RAW` 指向本仓库 `hyperos-thermal-module/latest.json`，经 `updates.fetch` 拉取。

## 权限边界

- `NativeShell`：只放行固定 action 集合；`snapshot` 先读 `RearSnapshotProvider` 缓存（`fresh` 时直接返回），否则以 `8s` 超时走 Root，其余 action 走 `30s`；`callback` 名须匹配标识符；`json` 长度 ≤ 700000；结果只在 `MainActivity` 页面回传。
- `RootRunner`：`8s`/`30s` 超时，单项输出 ≤ 2 MB；`job.get` 在分发器缺失时回退到 `/data/adb/MiWKJR_data/api-jobs/<id>/runtime/job.sh`。
- `app_api.sh`：请求 ≤ 1400000 字符，base64 往返一致才接受，且必须是 JSON 对象；写操作加锁；逐操作校验键名与取值域（如 `fv_v` 4300–4700、`term_v` 2800–3500）。
- `RearSnapshotProvider`：`publish_snapshot` 仅 `uid == 0`；`snapshot` / `card_html` 仅本应用或宿主 `com.xiaomi.subscreencenter` 可读；`report_health` 仅宿主可写、`health` 仅本应用可读；快照要求 `schema == 1`、字段白名单、TTL 5 秒。
- WebView：控制页允许 `file`/`content` 访问但关闭跨源（`file`→`file` 与通用跨源均禁），子资源仅信任 `data`/`blob` 与缓存目录内的 `file`，其余请求返回空；主框架仅允许控制页 `index.html`。背屏卡片 WebView 禁文件与内容访问、禁网络、禁多窗口，仅加载 `https://local.hyperos.xj/`。
- 外链仅放行 `https`/`http`/`mqqapi`/`mqqopensdkapi`；更新源仅放行 `testingcf.jsdelivr.net` / `cdn.jsdelivr.net` / `raw.githubusercontent.com`，且路径须以 `/hyperos-thermal-module/latest.json` 结尾并包含 `1014411313/aigate-usage`。
