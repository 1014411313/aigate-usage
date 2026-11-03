package com.hyperos.xj;

import android.app.Activity;
import android.content.Intent;
import android.content.pm.ApplicationInfo;
import android.net.Uri;
import android.os.Bundle;
import android.webkit.JavascriptInterface;
import org.json.JSONArray;
import org.json.JSONObject;
import java.io.ByteArrayOutputStream;
import java.io.InputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.nio.charset.StandardCharsets;
import java.util.Arrays;
import java.util.HashSet;
import java.util.Set;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

public final class NativeShell {
    private static final Set<String> ROOT_ACTIONS = new HashSet<>(Arrays.asList(
            "snapshot", "settings.get", "settings.save", "battery.setting.get", "battery.setting.set",
            "battery.power", "battery.apl", "battery.unlock", "battery.pps", "battery.cloud", "battery.cycle",
            "battery.voltage.start", "battery.voltage.stop", "battery.voltage.restore", "battery.rearscreen",
            "rear.settings.get", "rear.settings.save", "bypass.get", "bypass.set", "thermal.apply",
            "hyperspeed.set", "device.runtime", "device.os", "device.root", "module.info", "module.changelog",
            "notice.get", "notice.seen", "logs.read", "logs.append", "logs.export", "profile.load",
            "profile.summary", "profile.save", "backup.run", "backup.ui.export", "backup.full.export",
            "backup.full.restore", "action.run", "job.get"));
    private final Activity activity;
    private final ExecutorService queue = Executors.newFixedThreadPool(2);
    private volatile boolean closed;

    NativeShell(Activity activity) { this.activity = activity; }

    @JavascriptInterface public void request(String action, String json, String callback) {
        if (closed || callback == null || !callback.matches("[A-Za-z_$][A-Za-z0-9_$]{0,100}")) return;
        if (json == null || json.length() > 700000) { deliver(callback, RootRunner.error("请求大小无效")); return; }
        queue.execute(() -> {
            JSONObject result;
            try {
                JSONObject payload = new JSONObject(json);
                if ("snapshot".equals(action)) {
                    Bundle cached = activity.getContentResolver().call(Uri.parse("content://" + RearSnapshotProvider.AUTHORITY), "snapshot", null, null);
                    if (cached != null && cached.getBoolean("fresh", false)) result = ok(cached.getString("json", "{}"));
                    else result = RootRunner.run("snapshot", new JSONObject(), 8000);
                } else if (ROOT_ACTIONS.contains(action)) {
                    result = RootRunner.run(action, payload, 30000);
                } else if ("card.resource".equals(action)) {
                    try (InputStream in = activity.getAssets().open("card.html"); ByteArrayOutputStream out = new ByteArrayOutputStream()) {
                        byte[] buffer = new byte[4096]; int size;
                        while ((size = in.read(buffer)) != -1) {
                            if (out.size() + size > 512 * 1024) throw new IllegalStateException("卡片资源过大");
                            out.write(buffer, 0, size);
                        }
                        result = ok(new String(out.toByteArray(), StandardCharsets.UTF_8));
                    }
                } else if ("apps.list".equals(action)) {
                    result = ok(apps(payload.optBoolean("includeSystem", false)).toString());
                } else if ("links.open".equals(action)) {
                    Uri uri = Uri.parse(payload.getString("url"));
                    if (!Arrays.asList("https", "http", "mqqapi", "mqqopensdkapi").contains(uri.getScheme())) {
                        throw new IllegalArgumentException("不支持的外链协议");
                    }
                    activity.runOnUiThread(() -> {
                        try { activity.startActivity(new Intent(Intent.ACTION_VIEW, uri)); }
                        catch (Exception ignored) { android.widget.Toast.makeText(activity, "未找到可打开链接的应用", 0).show(); }
                    });
                    result = ok("");
                } else if ("updates.fetch".equals(action)) {
                    result = ok(fetchUpdate(payload.getString("url")));
                } else if ("hook.health".equals(action)) {
                    Bundle health = activity.getContentResolver().call(Uri.parse("content://" + RearSnapshotProvider.AUTHORITY), "health", null, null);
                    JSONObject info = new JSONObject();
                    if (health != null) info.put("state", health.getString("state", "unknown"))
                            .put("fresh", health.getBoolean("fresh", false)).put("timestamp", health.getLong("timestamp"));
                    result = ok(info.toString());
                } else {
                    result = RootRunner.error("未授权的 API 操作");
                }
            } catch (Exception e) {
                result = RootRunner.error(e.getClass().getSimpleName() + ": " + String.valueOf(e.getMessage()));
            }
            deliver(callback, result);
        });
    }

    private void deliver(String callback, JSONObject result) {
        activity.runOnUiThread(() -> {
            if (!closed && activity instanceof MainActivity) {
                ((MainActivity) activity).evaluate("window[" + JSONObject.quote(callback) + "]&&window["
                        + JSONObject.quote(callback) + "](" + result.toString() + ")");
            }
        });
    }

    private JSONArray apps(boolean includeSystem) throws Exception {
        JSONArray result = new JSONArray();
        for (ApplicationInfo info : activity.getPackageManager().getInstalledApplications(0)) {
            if (!includeSystem && (info.flags & ApplicationInfo.FLAG_SYSTEM) != 0) continue;
            String label;
            try { label = activity.getPackageManager().getApplicationLabel(info).toString(); }
            catch (Exception e) { label = info.packageName; }
            result.put(new JSONObject().put("pkg", info.packageName).put("name", label).put("apk", ""));
        }
        return result;
    }

    private String fetchUpdate(String address) throws Exception {
        URL url = new URL(address);
        String host = url.getHost();
        if (!"https".equals(url.getProtocol()) || !Arrays.asList("testingcf.jsdelivr.net", "cdn.jsdelivr.net", "raw.githubusercontent.com").contains(host)
                || !(url.getPath().endsWith("/hyperos-thermal-module/latest.json"))
                || !url.getPath().contains("1014411313/aigate-usage") || url.getUserInfo() != null || url.getPort() != -1) {
            throw new IllegalArgumentException("更新源不在白名单中");
        }
        HttpURLConnection connection = (HttpURLConnection) url.openConnection();
        connection.setConnectTimeout(8000); connection.setReadTimeout(8000); connection.setInstanceFollowRedirects(false);
        try (InputStream in = connection.getInputStream(); ByteArrayOutputStream out = new ByteArrayOutputStream()) {
            byte[] buffer = new byte[4096]; int n;
            while ((n = in.read(buffer)) != -1) {
                if (out.size() + n > 65536) throw new IllegalStateException("更新清单过大");
                out.write(buffer, 0, n);
            }
            String text = new String(out.toByteArray(), StandardCharsets.UTF_8);
            new JSONObject(text);
            return text;
        } finally { connection.disconnect(); }
    }

    private JSONObject ok(String raw) throws Exception { return new JSONObject().put("ok", true).put("raw", raw); }
    void close() { closed = true; queue.shutdownNow(); }
}
