package site.chudian.githubhosts;

import android.content.ContentValues;
import android.content.Context;
import android.net.Uri;
import android.os.Build;
import android.os.Environment;
import android.provider.MediaStore;

import org.json.JSONArray;
import org.json.JSONObject;

import java.io.File;
import java.io.FileOutputStream;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.Callable;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.Future;
import java.util.concurrent.TimeUnit;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/** GitHub 下载加速：生成镜像候选、并发测速、下载到系统下载目录 */
public final class Mirror {

    private static final Pattern RAW_PATTERN =
            Pattern.compile("^https://raw\\.githubusercontent\\.com/([^/]+)/([^/]+)/([^/]+)/(.+)$");

    private static final String[] PROXIES = {
            "https://gh-proxy.com/", "https://ghfast.top/", "https://ghproxy.net/"
    };

    private static final int PROBE_LIMIT = 256 * 1024;
    private static final int PROBE_TIMEOUT_MS = 4000;

    private Mirror() {
    }

    /** 生成 [名称, 地址] 的候选列表 */
    static List<String[]> candidates(String url) {
        List<String[]> list = new ArrayList<String[]>();
        list.add(new String[]{"直连", url});

        if (url.contains("cdn.jsdelivr.net")) {
            list.add(new String[]{"jsDelivr fastly", url.replace("cdn.jsdelivr.net", "fastly.jsdelivr.net")});
            list.add(new String[]{"jsDelivr gcore", url.replace("cdn.jsdelivr.net", "gcore.jsdelivr.net")});
        }

        Matcher m = RAW_PATTERN.matcher(url);
        if (m.matches()) {
            String path = "gh/" + m.group(1) + "/" + m.group(2) + "@" + m.group(3) + "/" + m.group(4);
            list.add(new String[]{"jsDelivr fastly", "https://fastly.jsdelivr.net/" + path});
            list.add(new String[]{"jsDelivr gcore", "https://gcore.jsdelivr.net/" + path});
        }

        if (url.contains("github.com") || url.contains("githubusercontent.com")) {
            for (String p : PROXIES) {
                list.add(new String[]{hostName(p), p + url});
            }
        }
        return list;
    }

    /** 并发测速所有候选，返回 JSON 数组 */
    static String probeAll(String url) {
        final List<String[]> cands = candidates(url);
        ExecutorService pool = Executors.newFixedThreadPool(Math.min(cands.size(), 5));
        List<Future<JSONObject>> tasks = new ArrayList<Future<JSONObject>>();
        for (final String[] c : cands) {
            tasks.add(pool.submit(new Callable<JSONObject>() {
                @Override
                public JSONObject call() {
                    JSONObject o = new JSONObject();
                    try {
                        o.put("name", c[0]);
                        o.put("url", c[1]);
                        long t0 = System.currentTimeMillis();
                        long bytes = measure(c[1]);
                        long ms = System.currentTimeMillis() - t0;
                        o.put("ok", bytes > 0);
                        o.put("ms", ms);
                        o.put("speed", ms > 0 ? bytes * 1000 / ms : 0);
                    } catch (Exception ignored) {
                    }
                    return o;
                }
            }));
        }
        pool.shutdown();

        JSONArray arr = new JSONArray();
        for (Future<JSONObject> f : tasks) {
            try {
                JSONObject o = f.get(PROBE_TIMEOUT_MS + 8000, TimeUnit.MILLISECONDS);
                if (o != null) {
                    arr.put(o);
                }
            } catch (Exception ignored) {
            }
        }
        return arr.toString();
    }

    /** 取候选里可用的最快一个 */
    static String fastest(String url) {
        List<String[]> cands = candidates(url);
        String best = null;
        long bestSpeed = 0;
        for (String[] c : cands) {
            long t0 = System.currentTimeMillis();
            long bytes = measure(c[1]);
            if (bytes <= 0) {
                continue;
            }
            long ms = Math.max(1, System.currentTimeMillis() - t0);
            long speed = bytes * 1000 / ms;
            if (speed > bestSpeed) {
                bestSpeed = speed;
                best = c[1];
            }
        }
        return best != null ? best : url;
    }

    /** 下载到系统「下载」目录，返回结果文本 */
    static String download(Context ctx, String url) {
        HttpURLConnection c = null;
        InputStream in = null;
        OutputStream out = null;
        try {
            c = (HttpURLConnection) new URL(url).openConnection();
            c.setConnectTimeout(8000);
            c.setReadTimeout(60000);
            c.setInstanceFollowRedirects(true);
            c.setRequestProperty("User-Agent", "github-hosts/1.1");
            if (c.getResponseCode() / 100 != 2) {
                return "FAIL: HTTP " + c.getResponseCode();
            }
            in = c.getInputStream();
            String name = fileName(url);

            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                ContentValues cv = new ContentValues();
                cv.put(MediaStore.Downloads.DISPLAY_NAME, name);
                cv.put(MediaStore.Downloads.MIME_TYPE, "application/octet-stream");
                Uri uri = ctx.getContentResolver()
                        .insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, cv);
                if (uri == null) {
                    return "FAIL: 无法创建下载项";
                }
                out = ctx.getContentResolver().openOutputStream(uri);
            } else {
                File dir = Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS);
                if (!dir.exists() && !dir.mkdirs()) {
                    return "FAIL: 无法创建下载目录";
                }
                out = new FileOutputStream(new File(dir, name));
            }
            if (out == null) {
                return "FAIL: 无法打开输出流";
            }

            byte[] buf = new byte[32768];
            long total = 0;
            long t0 = System.currentTimeMillis();
            int n;
            while ((n = in.read(buf)) > 0) {
                out.write(buf, 0, n);
                total += n;
            }
            out.flush();
            Updater.appendLog(ctx, "下载完成 " + name + " " + total + " 字节");
            long ms = Math.max(1, System.currentTimeMillis() - t0);
            return "OK: 已保存到「下载」/" + name + "（" + (total / 1024) + " KB，用时 "
                    + ms + " ms，约 " + (total * 1000 / ms / 1024) + " KB/s）";
        } catch (Exception e) {
            return "FAIL: " + e;
        } finally {
            close(in);
            close(out);
            if (c != null) {
                c.disconnect();
            }
        }
    }

    private static long measure(String url) {
        HttpURLConnection c = null;
        InputStream in = null;
        try {
            c = (HttpURLConnection) new URL(url).openConnection();
            c.setConnectTimeout(PROBE_TIMEOUT_MS);
            c.setReadTimeout(PROBE_TIMEOUT_MS);
            c.setInstanceFollowRedirects(true);
            c.setRequestProperty("User-Agent", "github-hosts/1.1");
            c.setRequestProperty("Range", "bytes=0-" + (PROBE_LIMIT - 1));
            if (c.getResponseCode() / 100 != 2) {
                return 0;
            }
            in = c.getInputStream();
            byte[] buf = new byte[16384];
            long total = 0;
            long deadline = System.currentTimeMillis() + PROBE_TIMEOUT_MS;
            int n;
            while ((n = in.read(buf)) > 0) {
                total += n;
                if (total >= PROBE_LIMIT || System.currentTimeMillis() > deadline) {
                    break;
                }
            }
            return total;
        } catch (Exception e) {
            return 0;
        } finally {
            close(in);
            if (c != null) {
                c.disconnect();
            }
        }
    }

    private static String hostName(String proxy) {
        String s = proxy.replace("https://", "").replace("http://", "");
        if (s.endsWith("/")) {
            s = s.substring(0, s.length() - 1);
        }
        return s;
    }

    private static String fileName(String url) {
        String s = url;
        int q = s.indexOf('?');
        if (q >= 0) {
            s = s.substring(0, q);
        }
        int slash = s.lastIndexOf('/');
        String name = slash >= 0 ? s.substring(slash + 1) : "";
        if (name.isEmpty()) {
            name = "download.bin";
        }
        return name;
    }

    private static void close(java.io.Closeable c) {
        if (c != null) {
            try {
                c.close();
            } catch (Exception ignored) {
            }
        }
    }
}
