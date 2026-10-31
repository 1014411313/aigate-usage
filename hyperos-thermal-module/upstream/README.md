# 上游同步框架（电池解容工具箱 / 动态温控）

本模块是二改整合版，由两个会持续更新的上游组成。这个目录用来记录「我们整合的是哪个版本」，
并支撑三方合并，避免每次上游更新都靠人肉比对。

| 组件 | 上游 | 模块目录 | 基线版本 | 目标目录 |
|---|---|---|---|---|
| `battery` | 电池解容工具箱（Dimples1337） | `battery_tune` | v3.12.6 | `src/battery` |
| `thermal` | 动态温控 K2（Axiaojiux） | `HyperOS_XJ` | K2 | `src` |

## 职责边界（硬规则）

- **充电的一切归电池解容**：充电电流/功率档、`wired_chg_curr`、`wireless_chg_curr`、`ctrl_limit`、
  `*_thermal_remove`、PPS、BAA 载荷挂载、循环伪装、电池电压、云控屏蔽、APL 爬坡、DTBO。
- **温控的一切归动态温控**：`/data/vendor/thermal/config/*.conf`（mi_thermald 的 trip 表）、
  温控档位、充电/游戏/息屏场景、旁路供电。
- 冲突时的让路顺序：**温控让充电**。温控不得为了压温度去改充电电流/功率档；
  需要限制功率时只改温控配置，或在 UI 里提示用户去电池页调功率档。
- 电池侧的 `thermal_guard`（温控守护）默认保持关闭，避免和动态温控的档位重复限流。
- 系统层「高温停充」由 `persist.vendor.high_temp_stop_charge` 控制，属于温控页的独立开关
  （见 `src/thermal_core.sh` 的 `hitemp_guard`），不归电池解容管。

## 本地改动约定（三方合并要能活下来的部分）

1. **模块路径**：所有脚本里的 `XBT` 固定为 `/data/adb/modules/HyperOS_XJ/battery`
   （上游是 `/data/adb/modules/battery_tune`）。合并后必须复查：
   `grep -rn "battery_tune" src/battery/scripts src/battery/service.sh`
   —— `pgrep -f` 的模式串也要一起改，否则单实例判断、看门狗会误判。
2. **不引入上游的安装器与第二套界面**：`customize.sh`、`webroot/` 一律 `--skip`，
   安装逻辑在 `src/customize.sh`，界面在 `src/hyperosui/`。
3. **APL 默认关闭**：`service.sh` 里启动 `apl.sh` 的条件是
   `power_limit=inf` **且** `apl_enable=1`（整合版默认 `apl_enable=0`），
   开关在电池页「自适应功率爬坡（APL）」，运行时由 `scripts/apl_toggle.sh` 停/起进程。
4. **status_kv 只增不减**：WebUI 依赖的输出键（`fv_v`、`dev_maxw`、`cycle_real`、`apl_enable` 等）
   在合并后要复查一遍，缺一个就是前端静默失效。
5. **DTBO**：二进制不参与文本合并。上游改了就整体替换；我们只在「本地没改过」时接受上游版本。

## 同步流程

```sh
# 1) 看差异（不写文件）
python3 tools/sync_upstream.py check battery ~/下载/电池解容工具箱_vX.Y.Z.zip
# 2) 试运行：能自动合并多少、有几处冲突
python3 tools/sync_upstream.py apply battery ~/下载/...zip --dry
# 3) 正式合并（新功能脚本要显式点名引入）
python3 tools/sync_upstream.py apply battery ~/下载/...zip \
    --include-new scripts/新脚本.sh --skip customize.sh webroot/index.html
# 4) 冲突文件会保留原样，另存 <文件>.merge 供人工裁决；处理完删掉 .merge
# 5) 复查路径与依赖键
grep -rn "battery_tune" src/battery/scripts src/battery/service.sh
sh -n src/battery/scripts/*.sh
python3 -c "import re;s=open('src/hyperosui/index.html',encoding='utf-8').read();open('/tmp/m.js','w').write(re.findall(r'<script>(.*?)</script>',s,re.S)[-1])" && node --check /tmp/m.js
# 6) 打包给用户测试
python3 tools/release.py build
```

`apply` 结束后会自动把 `manifest.json` 的基线更新到新版本，并把「我们改过的文件」重新快照到
`upstream/<组件>/base/`，下次合并继续以它作为共同祖先。

## manifest 字段

- `files`：上游文件的 sha256（基线原样）
- `local_modified`：我们改过的文件（三方合并的共同祖先取 `base/<文件>`）
- `local_only`：本地缺失的上游文件（一般是故意不引入的）
- `skip_prefixes`：不参与同步的目录（电池侧的 `config/`、`tools/` 是我们自己的）
