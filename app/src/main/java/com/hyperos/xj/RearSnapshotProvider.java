package com.hyperos.xj;

import android.content.ContentProvider;
import android.content.ContentValues;
import android.database.Cursor;
import android.net.Uri;
import android.os.Binder;
import android.os.Bundle;
import android.os.SystemClock;
import android.util.AtomicFile;
import android.util.Base64;

import org.json.JSONArray;
import org.json.JSONObject;
import org.json.JSONTokener;

import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.FileOutputStream;
import java.io.InputStream;
import java.nio.ByteBuffer;
import java.nio.charset.CodingErrorAction;
import java.nio.charset.StandardCharsets;
import java.util.Arrays;
import java.util.HashSet;
import java.util.Iterator;
import java.util.Set;

public final class RearSnapshotProvider extends ContentProvider {
    public static final String AUTHORITY = "com.hyperos.xj.rearsnapshot";
    public static final String METHOD_SNAPSHOT = "snapshot";
    public static final String METHOD_CARD = "card_html";
    public static final String METHOD_REPORT_HEALTH = "report_health";
    public static final String METHOD_HEALTH = "health";
    static final int MAX_SNAPSHOT_BYTES = 64 * 1024;
    private static final long SNAPSHOT_TTL_MS = 5000L;
    private static final String HOST_PACKAGE = "com.xiaomi.subscreencenter";
    private static final Set<String> FIELD_NAMES = new HashSet<>(Arrays.asList(
            "temp", "soc", "volt", "cur", "power", "status", "des", "full", "health", "cycle", "fake", "proto", "rm", "soh"));
    private static final Set<String> KEYS = new HashSet<>(Arrays.asList(
            "temp", "soc", "volt", "cur", "power", "status", "des", "full", "health", "cycle", "fake", "proto", "rm", "soh",
            "schema", "timestamp", "fresh", "charging", "fields", "rearscreen", "theme", "accent", "font_scale",
            "mode", "power_mode", "unlock", "pps", "apl", "cloud", "fv_v", "term_v", "fv_force",
            "pack_volt", "kv", "thermal", "desired", "effective", "actual"));
    private final Object lock = new Object();
    private AtomicFile snapshotFile;
    private JSONObject lastSnapshot;
    private String cardHtml;
    private long healthTime;
    private long healthElapsed;
    private String healthState = "unknown";

    @Override public boolean onCreate() {
        snapshotFile = new AtomicFile(new File(getContext().getFilesDir(), "snapshot.json"));
        synchronized (lock) {
            try (InputStream in = snapshotFile.openRead()) {
                lastSnapshot = parseSnapshot(readLimited(in, MAX_SNAPSHOT_BYTES), false);
            } catch (Exception ignored) {
                lastSnapshot = null;
            }
        }
        return true;
    }

    @Override public Bundle call(String method, String arg, Bundle extras) {
        int uid = Binder.getCallingUid();
        if ("publish_snapshot".equals(method)) {
            if (uid != 0) throw new SecurityException("仅 Root 可发布状态快照");
            Bundle result = new Bundle();
            try {
                if (arg == null || arg.length() > ((MAX_SNAPSHOT_BYTES + 2) / 3) * 4 + 2048) {
                    throw new IllegalArgumentException("快照过大");
                }
                byte[] data = Base64.decode(arg, Base64.DEFAULT);
                JSONObject snapshot = parseSnapshot(data, true);
                byte[] encoded = snapshot.toString().getBytes(StandardCharsets.UTF_8);
                if (encoded.length > MAX_SNAPSHOT_BYTES) throw new IllegalArgumentException("快照过大");
                synchronized (lock) {
                    // Binder retains the root caller identity; storage must use the provider identity.
                    long identity = Binder.clearCallingIdentity();
                    FileOutputStream out = null;
                    try {
                        out = snapshotFile.startWrite();
                        out.write(encoded);
                        snapshotFile.finishWrite(out);
                        lastSnapshot = snapshot;
                    } catch (Exception error) {
                        if (out != null) snapshotFile.failWrite(out);
                        throw error;
                    } finally {
                        Binder.restoreCallingIdentity(identity);
                    }
                }
                result.putBoolean("ok", true);
            } catch (Exception error) {
                result.putBoolean("ok", false);
                result.putString("error", error.getClass().getSimpleName());
            }
            return result;
        }
        boolean own = uid == android.os.Process.myUid();
        boolean host = isHost(uid);
        if (!own && !host) throw new SecurityException("仅背屏宿主和本应用可读取");
        if (METHOD_REPORT_HEALTH.equals(method) && !host) {
            throw new SecurityException("仅背屏宿主可报告心跳");
        }
        if (METHOD_HEALTH.equals(method) && !own) {
            throw new SecurityException("仅本应用可读取心跳");
        }
        Bundle result = new Bundle();
        try {
            if (METHOD_CARD.equals(method)) {
                synchronized (lock) {
                    if (cardHtml == null) {
                        try (InputStream in = getContext().getAssets().open("card.html")) {
                            cardHtml = new String(readLimited(in, 512 * 1024), StandardCharsets.UTF_8);
                        }
                    }
                    result.putString("html", cardHtml);
                }
            } else if (METHOD_SNAPSHOT.equals(method)) {
                synchronized (lock) {
                    JSONObject snapshot = lastSnapshot == null ? new JSONObject()
                            : new JSONObject(lastSnapshot.toString());
                    boolean fresh = isFresh(snapshot);
                    snapshot.put("fresh", fresh);
                    result.putString("json", snapshot.toString());
                    result.putBoolean("fresh", fresh);
                }
            } else if (METHOD_REPORT_HEALTH.equals(method)) {
                if (!isHealthState(arg)) throw new IllegalArgumentException("无效心跳");
                synchronized (lock) {
                    healthState = arg;
                    healthTime = System.currentTimeMillis();
                    healthElapsed = SystemClock.elapsedRealtime();
                }
                result.putBoolean("ok", true);
            } else if (METHOD_HEALTH.equals(method)) {
                synchronized (lock) {
                    long age = SystemClock.elapsedRealtime() - healthElapsed;
                    result.putString("state", healthState);
                    result.putLong("timestamp", healthTime);
                    result.putBoolean("fresh", healthTime != 0 && age >= 0 && age <= SNAPSHOT_TTL_MS);
                }
            } else {
                result.putString("error", "不支持的接口");
            }
        } catch (Exception error) {
            result.putString("error", error.getClass().getSimpleName());
        }
        return result;
    }

    private boolean isHost(int uid) {
        long identity = Binder.clearCallingIdentity();
        try {
            return getContext().getPackageManager().getApplicationInfo(HOST_PACKAGE, 0).uid == uid;
        } catch (Exception ignored) {
            return false;
        } finally {
            Binder.restoreCallingIdentity(identity);
        }
    }

    private static boolean isHealthState(String state) {
        return "observing".equals(state) || "disabled".equals(state) || "stale".equals(state)
                || "loading".equals(state) || "visible".equals(state) || "error".equals(state)
                || "paused".equals(state);
    }

    static JSONObject parseSnapshot(byte[] data, boolean publishing) throws Exception {
        if (data.length == 0 || data.length > MAX_SNAPSHOT_BYTES) throw new IllegalArgumentException("快照大小无效");
        String text = StandardCharsets.UTF_8.newDecoder().onMalformedInput(CodingErrorAction.REPORT)
                .onUnmappableCharacter(CodingErrorAction.REPORT).decode(ByteBuffer.wrap(data)).toString();
        JSONTokener tokener = new JSONTokener(text);
        Object value = tokener.nextValue();
        if (!(value instanceof JSONObject) || tokener.nextClean() != 0) throw new IllegalArgumentException("无效 JSON");
        JSONObject dataObject = (JSONObject) value;
        Iterator<String> keys = dataObject.keys();
        while (keys.hasNext()) {
            if (!KEYS.contains(keys.next())) throw new IllegalArgumentException("未知字段");
        }
        Object schema = dataObject.get("schema");
        if (!(schema instanceof Integer || schema instanceof Long) || ((Number) schema).longValue() != 1) {
            throw new IllegalArgumentException("不支持的 schema");
        }
        timestampMillis(dataObject);
        if (!(dataObject.get("fresh") instanceof Boolean)
                || !(dataObject.get("charging") instanceof Boolean)
                || !(dataObject.get("rearscreen") instanceof Boolean)) throw new IllegalArgumentException("无效开关");
        for (String key : new String[]{"temp", "volt", "cur", "power", "soc"}) {
            requireNumber(dataObject, key, true);
        }
        if (!dataObject.isNull("soc")) {
            double soc = dataObject.getDouble("soc");
            if (soc < 0 || soc > 100) throw new IllegalArgumentException("无效电量");
        }
        requireString(dataObject, "status", 64);
        Object fields = dataObject.get("fields");
        if (!(fields instanceof JSONArray) || ((JSONArray) fields).length() != 4) throw new IllegalArgumentException("需要四个字段");
        for (int i = 0; i < 4; i++) {
            Object field = ((JSONArray) fields).get(i);
            if (!(field instanceof String) || !FIELD_NAMES.contains(field)) {
                throw new IllegalArgumentException("无效显示字段");
            }
        }
        if (dataObject.has("theme")) {
            String theme = requireString(dataObject, "theme", 16);
            if (!Arrays.asList("dark", "light", "system", "aurora", "holographic", "neon-dark", "aurora-vivid", "cyber", "lava", "glacier", "moonsea").contains(theme)) {
                throw new IllegalArgumentException("无效主题");
            }
        }
        if (dataObject.has("accent")) {
            String accent = requireString(dataObject, "accent", 32);
            if (!accent.matches("[0-9]{1,3}\\s*,\\s*[0-9]{1,3}\\s*,\\s*[0-9]{1,3}")) throw new IllegalArgumentException("无效强调色");
            for (String channel : accent.split(",")) {
                if (Integer.parseInt(channel.trim()) > 255) throw new IllegalArgumentException("无效强调色");
            }
        }
        if (dataObject.has("font_scale")) {
            requireNumber(dataObject, "font_scale", false);
            double scale = dataObject.getDouble("font_scale");
            if (scale < 0.5 || scale > 2) throw new IllegalArgumentException("无效字号");
        }
        for (String key : new String[]{"des", "full", "cycle", "fake", "rm", "soh", "pack_volt"}) {
            if (dataObject.has(key)) requireNumber(dataObject, key, true);
        }
        if (dataObject.has("health") && !dataObject.isNull("health")) {
            if (dataObject.get("health") instanceof Number) requireNumber(dataObject, "health", false);
            else requireString(dataObject, "health", 64);
        }
        for (String key : new String[]{"proto", "mode", "power_mode", "unlock", "pps", "apl", "cloud", "fv_v", "term_v", "fv_force"}) {
            if (dataObject.has(key)) requireString(dataObject, key, 128);
        }
        if (dataObject.has("kv")) {
            JSONObject kv = dataObject.getJSONObject("kv");
            if (kv.length() > 160) throw new IllegalArgumentException("扩展字段过多");
            Iterator<String> fieldsIterator = kv.keys();
            while (fieldsIterator.hasNext()) {
                String key = fieldsIterator.next();
                if (!key.matches("[A-Za-z0-9_]{1,64}")) throw new IllegalArgumentException("无效扩展字段名");
                requireString(kv, key, 4096);
            }
        }
        for (String key : new String[]{"thermal", "desired", "effective", "actual"}) {
            if (dataObject.has(key)) dataObject.getJSONObject(key);
        }
        if (publishing && !timestampFresh(dataObject)) throw new IllegalArgumentException("快照已过期或来自未来");
        return dataObject;
    }

    private static void requireNumber(JSONObject data, String key, boolean nullable) throws Exception {
        Object value = data.get(key);
        if (nullable && value == JSONObject.NULL) return;
        if (!(value instanceof Number)) throw new IllegalArgumentException("无效数字");
        double number = ((Number) value).doubleValue();
        if (Double.isNaN(number) || Double.isInfinite(number)) throw new IllegalArgumentException("无效数字");
    }

    private static String requireString(JSONObject data, String key, int limit) throws Exception {
        Object value = data.get(key);
        if (!(value instanceof String) || ((String) value).length() > limit) throw new IllegalArgumentException("无效文本");
        String text = (String) value;
        for (int i = 0; i < text.length(); i++) {
            if (text.charAt(i) < 32) throw new IllegalArgumentException("无效文本");
        }
        return text;
    }

    static long timestampMillis(JSONObject data) throws Exception {
        Object value = data.get("timestamp");
        if (!(value instanceof Integer || value instanceof Long)) throw new IllegalArgumentException("无效时间戳");
        long seconds = ((Number) value).longValue();
        if (seconds <= 0 || seconds > Long.MAX_VALUE / 1000L) throw new IllegalArgumentException("无效时间戳");
        return seconds * 1000L;
    }

    private static boolean timestampFresh(JSONObject data) throws Exception {
        long timestamp = timestampMillis(data);
        long now = System.currentTimeMillis();
        return timestamp <= now && now - timestamp <= SNAPSHOT_TTL_MS;
    }

    static boolean isFresh(JSONObject data) {
        try {
            return Boolean.TRUE.equals(data.get("fresh")) && timestampFresh(data);
        } catch (Exception ignored) {
            return false;
        }
    }

    private static byte[] readLimited(InputStream in, int limit) throws Exception {
        ByteArrayOutputStream out = new ByteArrayOutputStream();
        byte[] buffer = new byte[4096];
        int count;
        while ((count = in.read(buffer)) != -1) {
            if (out.size() + count > limit) throw new IllegalArgumentException("数据过大");
            out.write(buffer, 0, count);
        }
        return out.toByteArray();
    }

    @Override public Cursor query(Uri uri, String[] projection, String selection, String[] args, String sort) { throw new UnsupportedOperationException(); }
    @Override public String getType(Uri uri) { return null; }
    @Override public Uri insert(Uri uri, ContentValues values) { throw new UnsupportedOperationException(); }
    @Override public int delete(Uri uri, String selection, String[] args) { throw new UnsupportedOperationException(); }
    @Override public int update(Uri uri, ContentValues values, String selection, String[] args) { throw new UnsupportedOperationException(); }
}
