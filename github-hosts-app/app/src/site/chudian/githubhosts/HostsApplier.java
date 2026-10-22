package site.chudian.githubhosts;

import android.content.Context;

import java.io.File;

/** 把生成的 hosts 应用到系统 */
public final class HostsApplier {

    private HostsApplier() {
    }

    public static String apply(Context ctx) {
        File hosts = new File(ctx.getFilesDir(), Updater.FILE_HOSTS);
        if (!hosts.exists()) {
            return "FAIL: 还没有生成 hosts，请先执行一次更新";
        }
        String src = hosts.getAbsolutePath();
        StringBuilder tries = new StringBuilder();

        // 1) systemless hosts 模块目录（KernelSU / Magisk），装了 metamodule 时重启后仍生效
        RootShell.Result mod = RootShell.su(
                "[ -d /data/adb/modules/hosts/system/etc ] && cp -f '" + src + "' /data/adb/modules/hosts/system/etc/hosts && echo __ok");
        if (mod.out.contains("__ok")) {
            return "OK: 已写入 systemless hosts 模块，重启后仍生效";
        }
        tries.append("模块目录：").append(oneLine(mod.out)).append('\n');

        // 2) bind mount 覆盖 /system/etc/hosts
        RootShell.Result bind = RootShell.su("mount -o bind '" + src + "' /system/etc/hosts && echo __ok");
        if (bind.out.contains("__ok")) {
            return "OK: 已 bind mount 到 /system/etc/hosts（重启后需重新应用）";
        }
        tries.append("bind mount：").append(oneLine(bind.out)).append('\n');

        // 3) 直接覆盖（老设备 /system 可写时）
        RootShell.Result write = RootShell.su(
                "mount -o rw,remount /system 2>/dev/null; cat '" + src + "' > /system/etc/hosts && echo __ok");
        if (write.out.contains("__ok")) {
            return "OK: 已直接写入 /system/etc/hosts";
        }
        tries.append("直接写入：").append(oneLine(write.out)).append('\n');

        return "FAIL: 三种方式都失败\n" + tries;
    }

    /** 撤销 bind mount（恢复系统原 hosts） */
    public static String restore(Context ctx) {
        RootShell.Result r = RootShell.su("umount /system/etc/hosts 2>/dev/null; echo __ok");
        if (r.out.contains("__ok")) {
            return "OK: 已撤销挂载";
        }
        return "FAIL: " + oneLine(r.out);
    }

    static String describeRoot() {
        RootShell.Result r = RootShell.su("id");
        if (r.ok() && r.out.contains("uid=0")) {
            return "可用";
        }
        return "不可用" + (r.out.isEmpty() ? "" : "（" + oneLine(r.out) + "）");
    }

    private static String oneLine(String s) {
        if (s == null) {
            return "";
        }
        String t = s.replace('\n', ' ').trim();
        return t.length() > 160 ? t.substring(0, 160) + "…" : t;
    }
}
