# GitHub 加速（Android App）

通过修改 hosts 把 GitHub 相关域名解析到可用 IP，解决网页访问慢、图片加载不出来的问题；同时内置**镜像加速下载**，用来绕过从 GitHub 下载文件（比如 KernelSU 模块 zip）慢的问题。

## 功能

- **多源合并**：内置 6 个 GitHub 加速源，下载后按域名去重，同一域名只保留靠前的源给的 IP
- **自动更新**：每 12 小时一次（AlarmManager），也可手动触发
- **应用 hosts**：通过 root 写入系统，三种方式自动尝试（见下）
- **镜像加速下载**：粘贴任意 GitHub 链接，并发测速各镜像，一键下载到系统「下载」目录
- **源管理**：内置源可单独开关，可增删自定义源
- **备份与日志**：更新前备份，保留最近 10 份；带时间戳的日志

## 安装

下载 APK 直接安装。需要 **root**（KernelSU / SterSU / Magisk 均可），首次执行需要授权的操作时会弹 su 请求。

## 使用

1. **立即更新**：下载所有启用中的源并合并，不需要 root。
2. **应用到系统**：把合并结果写进系统 hosts，需要 root。按顺序尝试：
   1. 写入 systemless hosts 模块目录 `/data/adb/modules/hosts/system/etc/hosts`（装了 `meta-overlayfs` 等 metamodule 时持久生效）
   2. `mount -o bind` 覆盖 `/system/etc/hosts`（立即生效，重启后失效，重启时由开机广播重新应用）
   3. 直接覆盖 `/system/etc/hosts`（仅 `/system` 可写的老设备）
   界面会显示实际走的是哪条，失败时给出原因。
3. **撤销挂载**：解除 bind mount，恢复系统原 hosts。
4. **GitHub 下载加速**：粘贴链接 → 测速 → 选最快的一条下载。

## 镜像加速下载

候选地址的生成规则：

| 原地址 | 追加的候选 |
| --- | --- |
| `cdn.jsdelivr.net` | `fastly.jsdelivr.net`、`gcore.jsdelivr.net` |
| `raw.githubusercontent.com` | jsDelivr（fastly / gcore），自动转换路径 |
| 含 `github.com` / `githubusercontent.com` | `gh-proxy.com`、`ghfast.top`、`ghproxy.net` 前缀代理 |

测速对每个候选发一个限量的 Range 请求（最多 256 KB 或 4 秒），按实测速度排序，界面直接给出 KB/s。

> 说明：这里做的是**加速下载器**，不是代理。HTTPS 请求加密后路径不可见，真要改写请求地址只能做中间人解密，不安全也不现实。

## 构建

```sh
bash build.sh
```

产物在 `build/github-hosts.apk`。

构建走手工管线（无 Gradle / AndroidX）：`ecj` 编译 → `d8` 生成 dex → `aapt2` 编译资源 → `zipalign` → `apksigner` 签名。依赖 `$ANDROID_TOOLS`（默认 `~/android-toolchain`）下的 `build-tools`、`platform/android.jar`、`ecj.jar`，以及 `debs/ext` 里解包的 arm64 版 `aapt2` / `zipalign`。

## 目录结构

```
app/AndroidManifest.xml
app/assets/index.html          界面（WebView）
app/assets/sources.json        内置源
app/src/site/chudian/githubhosts/
    MainActivity.java          WebView 容器 + JS 桥
    Updater.java               多源下载、按域名合并、生成 hosts、备份、日志
    HostsApplier.java          把 hosts 应用到系统
    Mirror.java                镜像候选生成、并发测速、下载落盘
    RootShell.java             执行 su 命令
    UpdateScheduler.java       12 小时定时
    UpdateReceiver.java        定时与开机广播
tools/MakeIcon.java            生成启动图标
build.sh
```

运行时数据位于应用私有目录：`sources.json`、`disabled.list`、`hosts`、`log.txt`、`backup/`。

## 已知限制

- 界面里的「下载」依赖系统「下载」目录：Android 10+ 走 MediaStore 免权限，Android 9 及以下需要存储权限。
- bind mount 方式**重启后失效**，靠 `BOOT_COMPLETED` 重新应用；Android 8+ 的后台执行限制下不保证成功。
- 开机自动重新应用、各设备上的 su 行为，都未在多种机型/系统版本上验证过。

## 相关项目

- KernelSU 模块版：[1014411313/github-hosts](https://github.com/1014411313/github-hosts)

## 数据来源

- [521xueweihan/GitHub520](https://github.com/521xueweihan/GitHub520)
- [ineo6/hosts](https://github.com/ineo6/hosts)
- [ittuann/GitHub-IP-hosts](https://github.com/ittuann/GitHub-IP-hosts)
- [Fetch GitHub Hosts](https://hosts.gitcdn.top/)
