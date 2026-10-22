package site.chudian.githubhosts;

import android.content.Context;

import org.json.JSONArray;
import org.json.JSONObject;

import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.HttpURLConnection;
import java.net.InetSocketAddress;
import java.net.Socket;
import java.net.URL;
import java.text.SimpleDateFormat;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Comparator;
import java.util.Date;
import java.util.HashSet;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Set;
import java.util.concurrent.Callable;
import java.util.concurrent.CompletionService;
import java.util.concurrent.ExecutorCompletionService;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.Future;
import java.util.concurrent.TimeUnit;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/** 下载多个源、按域名合并去重、生成 hosts */
public final class Updater {

    static final String FILE_SOURCES = "sources.json";
    static final String FILE_DISABLED = "disabled.list";
    static final String FILE_HOSTS = "hosts";
    static final String FILE_LOG = "log.txt";
    static final String DIR_BACKUP = "backup";

    private static final int MAX_BACKUP = 10;
    private static final int MIN_LINES = 5;
    private static final int MAX_LOG_LINES = 400;
    private static final String HEADER = "# GitHub Hosts 自动生成于 ";
    private static final Pattern URL_PATTERN = Pattern.compile("\"url\"\\s*:\\s*\"([^\"]+)\"");
    private static final Pattern RAW_PATTERN =
            Pattern.compile("^https://raw\\.githubusercontent\\.com/([^/]+)/([^/]+)/([^/]+)/(.+)$");
    private static final String[] GITHUB_PROXIES = {
            "https://gh-proxy.com/", "https://ghfast.top/", "https://ghproxy.net/"
    };

    private Updater() {
    }

    static void ensureDefaults(Context ctx) {
        File dir = ctx.getFilesDir();
        if (!dir.exists() && !dir.mkdirs()) {
            return;
        }
        File src = new File(dir, FILE_SOURCES);
        if (!src.exists()) {
            copyAsset(ctx, FILE_SOURCES, src);
        }
        File dis = new File(dir, FILE_DISABLED);
        if (!dis.exists()) {
            try {
                writeText(dis, "");
            } catch (IOException ignored) {
            }
        }
    }

    static String loadSources(Context ctx) {
        ensureDefaults(ctx);
        return readText(new File(ctx.getFilesDir(), FILE_SOURCES));
    }

    static void saveSources(Context ctx, String json) {
        try {
            writeText(new File(ctx.getFilesDir(), FILE_SOURCES), json);
        } catch (IOException ignored) {
        }
    }

    static String loadDisabled(Context ctx) {
        ensureDefaults(ctx);
        return readText(new File(ctx.getFilesDir(), FILE_DISABLED));
    }

    static void saveDisabled(Context ctx, String list) {
        try {
            writeText(new File(ctx.getFilesDir(), FILE_DISABLED), list);
        } catch (IOException ignored) {
        }
    }

    static String readLog(Context ctx) {
        return readText(new File(ctx.getFilesDir(), FILE_LOG));
    }

    static void appendLog(Context ctx, String msg) {
        File f = new File(ctx.getFilesDir(), FILE_LOG);
        String time = new SimpleDateFormat("MM-dd HH:mm:ss").format(new Date());
        String all = readText(f) + time + "  " + msg + "\n";
        String[] lines = all.split("\n");
        if (lines.length > MAX_LOG_LINES) {
            StringBuilder sb = new StringBuilder();
            for (int i = lines.length - MAX_LOG_LINES; i < lines.length; i++) {
                sb.append(lines[i]).append('\n');
            }
            all = sb.toString();
        }
        try {
            writeText(f, all);
        } catch (IOException ignored) {
        }
    }

    /** 执行一次更新，返回给界面显示的结果文本 */
    static String update(Context ctx) {
        ensureDefaults(ctx);
        long t0 = System.currentTimeMillis();
        File dir = ctx.getFilesDir();

        List<Source> sources = parseSources(readText(new File(dir, FILE_SOURCES)));
        Set<String> disabled = new HashSet<String>();
        for (String line : readText(new File(dir, FILE_DISABLED)).split("\n")) {
            String s = line.trim();
            if (!s.isEmpty()) {
                disabled.add(s);
            }
        }

        List<Source> active = new ArrayList<Source>();
        List<String> uniqueUrls = new ArrayList<String>();
        for (Source s : sources) {
            if (disabled.contains(s.key())) {
                continue;
            }
            active.add(s);
            if (!uniqueUrls.contains(s.url)) {
                uniqueUrls.add(s.url);
            }
        }

        // 同一个 URL 只下载一次；多个源可以共用它但各设不同的过滤器
        String[] bodies = downloadAll(uniqueUrls);
        LinkedHashMap<String, String> bodyByUrl = new LinkedHashMap<String, String>();
        for (int i = 0; i < uniqueUrls.size(); i++) {
            bodyByUrl.put(uniqueUrls.get(i), bodies[i]);
        }

        LinkedHashMap<String, String> byDomain = new LinkedHashMap<String, String>();
        int total = active.size();
        int ok = 0;
        for (Source s : active) {
            String body = bodyByUrl.get(s.url);
            if (body == null) {
                appendLog(ctx, "下载失败: " + s.url);
                continue;
            }
            ok++;
            for (String line : body.split("\n")) {
                String t = line.trim();
                if (t.isEmpty() || t.charAt(0) == '#') {
                    continue;
                }
                String[] parts = t.split("\\s+");
                if (parts.length < 2 || !isIp(parts[0])) {
                    continue;
                }
                String domain = parts[1];
                if (!s.matches(domain)) {
                    continue;
                }
                if (!byDomain.containsKey(domain)) {
                    byDomain.put(domain, parts[0] + " " + domain);
                }
            }
        }

        if (ok == 0) {
            appendLog(ctx, "全部源下载失败，保留现有 hosts");
            return "FAIL: 全部源下载失败";
        }
        if (byDomain.size() < MIN_LINES) {
            appendLog(ctx, "合并结果异常：" + byDomain.size() + " 行，放弃写入");
            return "FAIL: 合并结果异常（" + byDomain.size() + " 行）";
        }

        StringBuilder sb = new StringBuilder();
        sb.append(HEADER).append(new SimpleDateFormat("yyyy-MM-dd HH:mm:ss").format(new Date())).append('\n');
        sb.append("127.0.0.1 localhost\n::1 localhost\n");
        for (String v : byDomain.values()) {
            sb.append(v).append('\n');
        }

        File hosts = new File(dir, FILE_HOSTS);
        backup(ctx, hosts);
        try {
            writeText(hosts, sb.toString());
        } catch (IOException e) {
            return "FAIL: 写入失败 " + e.getMessage();
        }

        long costMs = System.currentTimeMillis() - t0;
        String msg = "源 " + ok + "/" + total + " 成功，合并 " + byDomain.size()
                + " 行，用时 " + costMs + " ms";
        appendLog(ctx, "更新完成：" + msg);
        return "OK: " + msg;
    }

    /** 界面状态：条目数、最后更新时间、root 是否可用 */
    static String status(Context ctx) {
        ensureDefaults(ctx);
        String text = readText(new File(ctx.getFilesDir(), FILE_HOSTS));
        int count = 0;
        String time = "";
        for (String line : text.split("\n")) {
            String s = line.trim();
            if (s.isEmpty()) {
                continue;
            }
            if (s.charAt(0) != '#') {
                count++;
            }
            if (time.isEmpty() && s.startsWith(HEADER)) {
                time = s.substring(HEADER.length()).trim();
            }
        }
        JSONObject o = new JSONObject();
        try {
            o.put("count", count);
            o.put("time", time.isEmpty() ? "—" : time);
            o.put("root", RootShell.isRootAvailable());
        } catch (Exception ignored) {
        }
        return o.toString();
    }

    static String testNet() {
        Socket s = new Socket();
        try {
            s.connect(new InetSocketAddress("github.com", 443), 5000);
            return "OK";
        } catch (Exception e) {
            return "FAIL";
        } finally {
            try {
                s.close();
            } catch (IOException ignored) {
            }
        }
    }
    /** 查仓库里的 version.json，返回 JSON 文本 */
    static String checkUpdate(Context ctx) {
        String current = "";
        try {
            current = ctx.getPackageManager()
                    .getPackageInfo(ctx.getPackageName(), 0).versionName;
        } catch (Exception ignored) {
        }

        String base = "1014411313/aigate-usage@main/github-hosts-app/version.json";
        String[] urls = {
                "https://fastly.jsdelivr.net/gh/" + base,
                "https://gcore.jsdelivr.net/gh/" + base,
                "https://gh-proxy.com/https://raw.githubusercontent.com/1014411313/aigate-usage/main/github-hosts-app/version.json"
        };

        String body = null;
        for (String u : urls) {
            String b = fetchOne(u);
            if (b != null && b.indexOf("version") >= 0) {
                body = b;
                break;
            }
        }
        if (body == null) {
            return "FAIL: 无法获取版本信息";
        }

        JSONObject out = new JSONObject();
        try {
            JSONObject o = new JSONObject(body);
            String latest = o.optString("version", "");
            if (latest.isEmpty()) {
                return "FAIL: 版本信息格式错误";
            }
            out.put("current", current);
            out.put("latest", latest);
            out.put("hasNew", !latest.equals(current));
            out.put("page", o.optString("page", ""));
            out.put("apk", o.optString("apk", ""));
        } catch (Exception e) {
            return "FAIL: " + e.getMessage();
        }
        return out.toString();
    }

    static List<String> extractUrls(String json) {
        List<String> list = new ArrayList<String>();
        Matcher m = URL_PATTERN.matcher(json == null ? "" : json);
        while (m.find()) {
            list.add(m.group(1));
        }
        return list;
    }

    /** 一个源：名称、地址、可选的域名过滤器（逗号分隔，任一命中即保留） */
    static final class Source {
        String name = "";
        String url = "";
        String filter = "";

        String key() {
            return filter.isEmpty() ? url : url + "|" + filter;
        }

        boolean matches(String domain) {
            if (filter.isEmpty()) {
                return true;
            }
            String d = domain.toLowerCase();
            for (String raw : filter.toLowerCase().split(",")) {
                String k = raw.trim();
                if (k.isEmpty()) {
                    continue;
                }
                if (k.startsWith("=")) {
                    // =t.me 表示域名等于 t.me 或它的子域，避免子串误命中（如 chat.messenger.com）
                    String v = k.substring(1);
                    if (d.equals(v) || d.endsWith("." + v)) {
                        return true;
                    }
                } else if (d.contains(k)) {
                    return true;
                }
            }
            return false;
        }
    }

    static List<Source> parseSources(String json) {
        List<Source> list = new ArrayList<Source>();
        try {
            JSONArray arr = new JSONArray(json == null ? "[]" : json);
            for (int i = 0; i < arr.length(); i++) {
                JSONObject o = arr.optJSONObject(i);
                if (o == null) {
                    continue;
                }
                Source s = new Source();
                s.name = o.optString("name", "");
                s.url = o.optString("url", "");
                s.filter = o.optString("filter", "");
                if (!s.url.isEmpty()) {
                    list.add(s);
                }
            }
        } catch (Exception ignored) {
        }
        return list;
    }

    private static boolean isIp(String s) {
        if (s.indexOf(':') >= 0) {
            return true;
        }
        int dots = 0;
        for (int i = 0; i < s.length(); i++) {
            char ch = s.charAt(i);
            if (ch == '.') {
                dots++;
            } else if (ch < '0' || ch > '9') {
                return false;
            }
        }
        return dots == 3;
    }

    /** 并行下载所有源，返回与 urls 等长的数组，失败的位置为 null */
    private static String[] downloadAll(List<String> urls) {
        final int n = urls.size();
        final String[] out = new String[n];
        ExecutorService pool = Executors.newFixedThreadPool(Math.max(1, Math.min(4, n)));
        List<Future<?>> tasks = new ArrayList<Future<?>>();
        for (int i = 0; i < n; i++) {
            final int idx = i;
            final String url = urls.get(i);
            tasks.add(pool.submit(new Runnable() {
                @Override
                public void run() {
                    out[idx] = fetch(url);
                }
            }));
        }
        pool.shutdown();
        for (Future<?> f : tasks) {
            try {
                f.get(60, TimeUnit.SECONDS);
            } catch (Exception ignored) {
            }
        }
        return out;
    }

    /** 多候选并发抢答，返回第一份看起来正常的内容 */
    private static String fetch(String url) {
        List<String> cands = candidates(url);
        if (cands.isEmpty()) {
            return null;
        }
        if (cands.size() == 1) {
            String body = fetchOne(cands.get(0));
            return (body != null && body.indexOf("github") >= 0) ? body : null;
        }

        // 逐个试的话第一个不可达就要干等一个超时；改成并发请求，谁先回来用谁
        ExecutorService pool = Executors.newFixedThreadPool(Math.min(cands.size(), 3));
        CompletionService<String> cs = new ExecutorCompletionService<String>(pool);
        for (final String c : cands) {
            cs.submit(new Callable<String>() {
                @Override
                public String call() {
                    String body = fetchOne(c);
                    return (body != null && body.indexOf("github") >= 0) ? body : null;
                }
            });
        }
        String result = null;
        long deadline = System.currentTimeMillis() + 25000L;
        for (int i = 0; i < cands.size(); i++) {
            long remain = deadline - System.currentTimeMillis();
            if (remain <= 0) {
                break;
            }
            try {
                Future<String> f = cs.poll(remain, TimeUnit.MILLISECONDS);
                if (f == null) {
                    break;
                }
                String body = f.get();
                if (body != null) {
                    result = body;
                    break;
                }
            } catch (Exception ignored) {
            }
        }
        pool.shutdownNow();
        return result;
    }

    /** 候选地址：原地址 + jsDelivr 节点替换 + GitHub 镜像前缀 */
    static List<String> candidates(String url) {
        List<String> list = new ArrayList<String>();
        list.add(url);

        // cdn.jsdelivr.net 在国内常不可达，换同源的 fastly / gcore 节点
        if (url.contains("cdn.jsdelivr.net")) {
            list.add(url.replace("cdn.jsdelivr.net", "fastly.jsdelivr.net"));
            list.add(url.replace("cdn.jsdelivr.net", "gcore.jsdelivr.net"));
        }

        if (url.contains("github.com") || url.contains("githubusercontent.com")) {
            Matcher m = RAW_PATTERN.matcher(url);
            if (m.matches()) {
                String path = "gh/" + m.group(1) + "/" + m.group(2) + "@" + m.group(3) + "/" + m.group(4);
                list.add("https://fastly.jsdelivr.net/" + path);
                list.add("https://gcore.jsdelivr.net/" + path);
            }
            for (String proxy : GITHUB_PROXIES) {
                list.add(proxy + url);
            }
        }
        return list;
    }

    private static String fetchOne(String url) {
        HttpURLConnection c = null;
        try {
            c = (HttpURLConnection) new URL(url).openConnection();
            c.setConnectTimeout(5000);
            c.setReadTimeout(15000);
            c.setInstanceFollowRedirects(true);
            c.setRequestProperty("User-Agent", "github-hosts/1.0");
            if (c.getResponseCode() / 100 != 2) {
                return null;
            }
            InputStream in = c.getInputStream();
            ByteArrayOutputStream bo = new ByteArrayOutputStream();
            byte[] buf = new byte[8192];
            int n;
            while ((n = in.read(buf)) > 0) {
                bo.write(buf, 0, n);
            }
            in.close();
            return new String(bo.toByteArray(), "UTF-8");
        } catch (Exception e) {
            return null;
        } finally {
            if (c != null) {
                c.disconnect();
            }
        }
    }

    private static void backup(Context ctx, File hosts) {
        if (!hosts.exists()) {
            return;
        }
        File dir = new File(ctx.getFilesDir(), DIR_BACKUP);
        if (!dir.exists() && !dir.mkdirs()) {
            return;
        }
        try {
            writeText(new File(dir, "hosts." + System.currentTimeMillis() / 1000), readText(hosts));
        } catch (IOException e) {
            return;
        }
        File[] files = dir.listFiles();
        if (files == null || files.length <= MAX_BACKUP) {
            return;
        }
        Arrays.sort(files, new Comparator<File>() {
            @Override
            public int compare(File a, File b) {
                return Long.valueOf(b.lastModified()).compareTo(a.lastModified());
            }
        });
        for (int i = MAX_BACKUP; i < files.length; i++) {
            files[i].delete();
        }
    }

    static String readText(File f) {
        if (f == null || !f.exists()) {
            return "";
        }
        FileInputStream in = null;
        try {
            in = new FileInputStream(f);
            ByteArrayOutputStream bo = new ByteArrayOutputStream();
            byte[] buf = new byte[8192];
            int n;
            while ((n = in.read(buf)) > 0) {
                bo.write(buf, 0, n);
            }
            return new String(bo.toByteArray(), "UTF-8");
        } catch (IOException e) {
            return "";
        } finally {
            close(in);
        }
    }

    static void writeText(File f, String s) throws IOException {
        FileOutputStream out = new FileOutputStream(f);
        try {
            out.write(s.getBytes("UTF-8"));
        } finally {
            out.close();
        }
    }

    private static void copyAsset(Context ctx, String name, File dst) {
        InputStream in = null;
        OutputStream out = null;
        try {
            in = ctx.getAssets().open(name);
            out = new FileOutputStream(dst);
            byte[] buf = new byte[8192];
            int n;
            while ((n = in.read(buf)) > 0) {
                out.write(buf, 0, n);
            }
        } catch (IOException ignored) {
        } finally {
            close(in);
            close(out);
        }
    }

    private static void close(java.io.Closeable c) {
        if (c != null) {
            try {
                c.close();
            } catch (IOException ignored) {
            }
        }
    }
}
