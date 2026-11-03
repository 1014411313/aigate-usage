package com.hyperos.xj;

import android.util.Base64;
import org.json.JSONObject;
import java.io.ByteArrayOutputStream;
import java.io.InputStream;
import java.nio.charset.StandardCharsets;
import java.util.concurrent.ExecutionException;
import java.util.concurrent.FutureTask;
import java.util.concurrent.TimeUnit;

final class RootRunner {
    static final String MOD = "/data/adb/modules/HyperOS_XJ";
    private RootRunner() { }

    static JSONObject run(String operation, JSONObject payload, long timeoutMs) {
        Process process = null;
        FutureTask<String> reader = null;
        try {
            String encoded = Base64.encodeToString(payload.toString().getBytes(StandardCharsets.UTF_8), Base64.NO_WRAP);
            String dispatcher = MOD + "/api/app_api.sh";
            String shell = "sh " + quote(dispatcher) + " " + quote(operation) + " " + quote(encoded);
            if ("job.get".equals(operation)) {
                String id = payload.optString("jobId");
                if (!id.matches("j[A-Za-z0-9]{10}")) return error("无效任务编号");
                String retained = "/data/adb/HyperOS_XJ_data/api-jobs/" + id + "/runtime/job.sh";
                shell = "if [ -f " + quote(dispatcher) + " ]; then " + shell + "; else sh "
                        + quote(retained) + " --get " + quote(id) + "; fi";
            }
            process = new ProcessBuilder("/system/bin/su", "-c", shell).redirectErrorStream(true).start();
            process.getOutputStream().close();
            final Process child = process;
            reader = new FutureTask<>(() -> {
                try (InputStream in = child.getInputStream(); ByteArrayOutputStream out = new ByteArrayOutputStream()) {
                    byte[] buffer = new byte[4096];
                    int n;
                    while ((n = in.read(buffer)) != -1) {
                        if (out.size() + n > 2 * 1024 * 1024) {
                            child.destroyForcibly();
                            throw new IllegalStateException("操作输出超过限制");
                        }
                        out.write(buffer, 0, n);
                    }
                    return new String(out.toByteArray(), StandardCharsets.UTF_8);
                }
            });
            Thread worker = new Thread(reader, "xj-root-output");
            worker.setDaemon(true);
            worker.start();
            if (!process.waitFor(timeoutMs, TimeUnit.MILLISECONDS)) return error("Root 操作超时，请检查授权或任务状态");
            String text = reader.get(2000, TimeUnit.MILLISECONDS);
            if (process.exitValue() != 0) return error(text.trim().isEmpty() ? "Root 操作失败" : text.trim());
            return new JSONObject().put("ok", true).put("raw", text);
        } catch (Exception e) {
            Throwable reason = e instanceof ExecutionException && e.getCause() != null ? e.getCause() : e;
            return error(reason.getClass().getSimpleName() + ": " + String.valueOf(reason.getMessage()));
        } finally {
            if (reader != null) reader.cancel(true);
            if (process != null) {
                if (process.isAlive()) process.destroyForcibly();
                try { process.getInputStream().close(); } catch (Exception ignored) { }
                try { process.getErrorStream().close(); } catch (Exception ignored) { }
            }
        }
    }

    static JSONObject error(String message) {
        JSONObject result = new JSONObject();
        try { result.put("ok", false).put("error", message).put("raw", ""); } catch (Exception ignored) { }
        return result;
    }

    static String output(JSONObject result) { return result.optString("raw", result.optString("error", "")); }
    private static String quote(String value) { return "'" + value.replace("'", "'\\''") + "'"; }
}
