# GPU 智能升频

高通 KGSL 平台的 GPU 下限动态调节模块。只调 GPU，不动 CPU。

作者：AiCode　　版本：V1.2

---

## 它解决什么问题

部分高通机型上，`msm-adreno-tz` 依据 `devfreq/gpu_load` 做调频决策，而这个值在真机上会被严重低估——实测只有 `gpu_busy_percentage` 的 1/3 ~ 1/5（比值大致等于「当前频率 ÷ 最高频率」）。

结果是：GPU 真实繁忙度已经 70%，governor 却认为它很闲，把频率按在 222~342MHz 不动。游戏因此在低频死锁：

```
频率低 → 归一化负载看起来低 → governor 认为不用升频 → 频率继续低
```

本模块绕开 governor 的负载口径，直接读 `gpu_busy_percentage`（真实繁忙度），动态抬高 `min_pwrlevel` 下限，把 GPU 推到够用的档位；负载回落再逐档放回。

**只写 `min_pwrlevel` 一个节点，不改 governor、不改 CPU、不改刷新率。**

## 功能

- **按真实负载动态升档**：繁忙度超阈值持续若干次采样就升一档，低于下限持续若干次就降一档，中间为滞回带
- **温度保护**：读 GPU 自身温度节点，超过阈值直接压档
- **熄屏回落**：熄屏时回到最省电档
- **应用级档位锁定**：可把某个应用钉死在固定档位，不受动态调整影响（学习页「采纳建议」即写入此项）
- **游戏名单**：名单内的应用在前台时，不等负载爬升直接拉到设定档位；温控仍然优先
- **学习采样**：记录每个前台应用稳定后的档位与负载，WebUI「学习」页据此给出收紧/放宽建议
- **WebUI**：KernelSU / APatch 管理器内直接打开，无需浏览器、不加载外部资源
- **检查更新**：可选。配置更新源后手动检查新版，模块只提示，不自动下载安装

## 安装

Magisk / KernelSU / APatch 均可，建议 KernelSU。

1. 管理器内安装本 zip
2. 重启生效

安装后：

- 模块目录：`/data/adb/modules/gpu_autoboost`
- 数据目录：`/data/adb/gpu_autoboost`（配置、学习样本、日志都在这里，升级模块不会丢）
- 配置文件：`/data/adb/gpu_autoboost/config.conf`

## 使用

打开 KernelSU 管理器 → 模块 → GPU 智能升频，即可进入 WebUI。

四个页签：

| 页签 | 内容 |
|---|---|
| 首页 | 实时繁忙度、当前频率、生效档位、温度、档位表、运行日志 |
| 配置 | 采样间隔、升频/降频阈值、观察次数、档位范围、温度保护、熄屏回落 |
| 学习 | 各应用的平均档位与负载，给收紧/放宽建议，可一键采纳 |
| 关于 | 模块信息、重启/停止/暂停守护 |

### 档位与频率

`pwrlevel` 越小频率越高。以骁龙 8 Elite 为例：

```
L0 1100MHz  L3 900MHz  L6 660MHz   L9 443MHz   L12 222MHz
```

`L12` 是系统默认下限，`L13`（160MHz）通常被系统排除。

### 采纳建议的含义

- **建议收紧** → 锁定到最低档（最省电）。适合确定不需要 GPU 性能的应用
- **建议放宽** → 锁定到比当前高两档的位置

锁定后该应用在前台时不再动态调整，直到点「取消锁定」。

**误锁游戏会明显掉帧**，注意区分。

## 配置项

| 键 | 默认 | 说明 |
|---|---|---|
| `INTERVAL_MS` | 300 | 采样间隔（毫秒），50~2000 |
| `BUSY_HIGH` | 65 | 升频阈值（%），20~100 |
| `BUSY_LOW` | 35 | 降频阈值（%），1~95 |
| `HOLD_UP` | 4 | 连续多少次达标才升档 |
| `HOLD_DOWN` | 10 | 连续多少次达标才降档 |
| `LEVEL_MIN` | 1 | 最高档位（最激进） |
| `LEVEL_MAX` | 12 | 最低档位（最省电） |
| `LEVEL_START` | 12 | 启动时的初始档位 |
| `TH_CAP` | 1 | 温控开关 |
| `TH_HIGH` | 75 | 触发温度（℃） |
| `TH_LOW` | 68 | 放开温度（℃） |
| `LEVEL_THERMAL` | 8 | 过热时压到哪一档 |
| `SCREEN_IDLE` | 1 | 熄屏回落到最低档 |
| `LEARN` | 1 | 学习采样开关 |
| `LEARN_FLUSH_S` | 300 | 学习样本聚合间隔（秒） |
| `GAME_BOOST` | 1 | 游戏名单开关 |
| `GAME_LEVEL` | 1 | 游戏时锁到的档位（1 = 接近最高频） |
| `UPDATE_URL` | 空 | 更新源地址，空 = 不检查 |

改完不用重启：守护按 mtime 巡检，一个周期内自动重载。非法值会被夹回合法范围。

## 兼容性

| 项目 | 说明 |
|---|---|
| 平台 | 高通 KGSL（`/sys/class/kgsl/kgsl-3d0`），**不支持 Mali / 其他 GPU** |
| 架构 | 无需二进制，纯 shell 实现 |
| 管理器 | WebUI 需 KernelSU / APatch 的 root 桥；Magisk 下多半只能用命令行 |
| 与 CPU 限频模块 | 无写冲突。本模块只写 `min_pwrlevel`，不碰 CPU 节点 |

### 已验证 / 未验证

如实说明，不替没测过的场景打包票：

- **已验证**：守护启动与单实例、真实繁忙度采样、滞回升降档、应用级锁定、学习采样落盘、WebUI 后端全部接口（`ping` / `status` / `levels` / `conf_get` / `log` / `advice` / `mode_set` / `mode_del`）
- **未充分验证**：真实游戏场景下的帧率收益、长时间运行的稳定性、WebUI 前端在各管理器 WebView 中的完整交互
- **已知限制**：学习建议基于 `gpu_busy_percentage` 的均值，样本量少时参考价值有限；应用锁定按包名匹配，多开/分身场景可能不准

## 命令行

```sh
API=/data/adb/modules/gpu_autoboost/webroot/api.sh

sh $API status          # 运行状态
sh $API levels          # 档位-频率对照
sh $API conf_get        # 读配置
sh $API conf_set BUSY_HIGH 70
sh $API advice          # 学习建议
sh $API modes_list      # 已锁定的应用
sh $API mode_set <包名> <档位>
sh $API mode_del <包名>
sh $API games_list      # 游戏名单
sh $API game_add <包名>
sh $API game_del <包名>
sh $API check_update    # 需先配置 UPDATE_URL
sh $API log 50
sh $API restart
```

## 卸载

管理器内卸载即可。`uninstall.sh` 会停止守护并把 `min_pwrlevel` 还原成安装前的值，然后删除数据目录。

## 更新日志

### V1.2

- 新增：游戏名单（`games.conf`），命中后不等负载爬升直接拉到 `GAME_LEVEL`，温控仍优先
- 新增：检查更新（需在关于页填写更新源地址；只提示，不自动下载安装）
- 新增：关于页直接显示本更新日志
- 新增：学习页可直接维护游戏名单

### V1.1

- 新增：应用级档位锁定（`app_modes.conf`），守护在前台应用命中时固定档位不再动态调整
- 新增：WebUI 学习页「采纳建议 / 取消锁定」按钮
- 新增：后端 `mode_set` / `mode_del` / `modes_list` 命令
- 修复：配置页滑块右侧数值显示为 `-`（HTML label 的 id 与 JS 查找的键名不一致）
- 修复：看门狗可能拉起多个守护实例（拉起前先清理 `/proc` 中所有残留的 `gpud` 进程）
- 修复：学习样本写入路径曾被配置项 `LEARN` 覆盖，导致写入失败（变量名冲突）

### V1.0

- 首个版本：按真实 GPU 繁忙度动态调整 `min_pwrlevel`
- 滞回升降档、温度保护、熄屏回落
- 学习采样与 WebUI
