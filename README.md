# 温控解容工具箱（MiWKJR）

HyperOS 统一版项目仓库（远程 `1014411313/aigate-usage`）。主目录：

- `app/` — Android 控制端，包名 `com.MiWKJR`：WebView 控制界面 + `NativeShell` 固定白名单 Root API + LSPosed Hook（背屏卡片）。
- `hyperos-thermal-module/` — Root 模块，id `MiWKJR`：温控 / 电池解容脚本、`snapshotd` 只读采样、模块管理器只读页，以及构建与发布工具。

一句话架构：控制端 WebView 经 `NativeShell` 白名单调用模块 `api/app_api.sh` 读写配置；模块 `snapshotd` 采样生成 `run/snapshot.json`，经控制端 ContentProvider 交给背屏 LSPosed Hook 渲染；更新检查读取本仓库 `hyperos-thermal-module/latest.json`。

与之无关的独立项目（旧 App、其它模块与实验项目）已归档到 `archive/`，不参与当前构建；详见 [archive/README.md](archive/README.md)。

## 文档

- [docs/architecture.md](docs/architecture.md) — 组件职责、数据流、权限边界。
- [docs/build-and-maintenance.md](docs/build-and-maintenance.md) — 构建、打包、测试、凭据外置、发布与版本清单。
