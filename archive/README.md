# archive/ — 已存档项目

2026-11-03 仓库整理：以下独立项目与当前主项目（统一版 HyperOS 控制端 App + Root 模块）无关，
源码移入此处留存查阅，**不参与当前构建与发布**。

| 目录 | 说明 |
|---|---|
| `aigate-usage/` | 早期用量查询 App（Android，`build.sh` 构建）。注意：根目录 `dist/latest.json` 曾指向 `aigate-usage/dist/aigate-usage-1.13.apk`，旧更新入口已于 2026-11-03 下线，旧版客户端不再收到更新提示。 |
| `github-hosts-app/` | GitHub Hosts 小工具 App。 |
| `gpu_autoboost/` | GPU 自动升频模块。 |
| `perf-tuner/` | 性能调节模块。 |
| `mcp-client/` | MCP 客户端实验项目（Node/TS）。源码与配置已入库；`node_modules/` 是生成依赖，未纳入外部备份（容器分层文件系统中有不可读取的载体条目），需要时在本目录执行 `npm install` 重建。 |

外部完整备份（逐文件 SHA-256 校验）在仓库外 `/root/repository-backups/2026-11-03/unrelated-main/`，
清单见同目录 `manifest.json`。
