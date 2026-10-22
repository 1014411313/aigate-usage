package site.chudian.aigate.usage;

import android.app.Activity;
import android.app.DownloadManager;
import android.content.ClipData;
import android.content.ClipboardManager;
import android.content.Intent;
import android.content.pm.PackageInfo;
import android.graphics.Color;
import android.net.Uri;
import android.os.Build;
import android.os.Bundle;
import android.os.Environment;
import android.os.Message;
import android.provider.Settings;
import android.webkit.JavascriptInterface;
import android.webkit.WebChromeClient;
import android.webkit.WebResourceRequest;
import android.webkit.WebSettings;
import android.webkit.WebView;
import android.webkit.WebViewClient;
import android.widget.Toast;

import org.json.JSONObject;

import java.io.BufferedReader;
import java.io.ByteArrayOutputStream;
import java.io.InputStream;
import java.io.InputStreamReader;
import java.net.HttpURLConnection;
import java.net.URL;
import java.nio.charset.StandardCharsets;

public class MainActivity extends Activity {

    /** 仓库里的版本清单，推新版时一并更新 */
    private static final String UPDATE_MANIFEST =
            "https://raw.githubusercontent.com/1014411313/aigate-usage/main/dist/latest.json";

    private WebView webView;
    private WebView relay;

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        webView = new WebView(this);
        webView.setBackgroundColor(Color.parseColor("#f1f5f9"));

        WebSettings settings = webView.getSettings();
        settings.setJavaScriptEnabled(true);
        settings.setDomStorageEnabled(true);

        // 页面本身不发跳转，出现导航就是要离开用量页（购买、文档等）
        webView.setWebViewClient(new WebViewClient() {
            @Override
            public boolean shouldOverrideUrlLoading(WebView view, WebResourceRequest request) {
                route(request.getUrl().toString());
                return true;
            }
        });

        webView.setWebChromeClient(new WebChromeClient() {
            @Override
            public boolean onCreateWindow(WebView view, boolean isDialog, boolean isUserGesture, Message resultMsg) {
                relay = new WebView(MainActivity.this);
                relay.setWebViewClient(new WebViewClient() {
                    @Override
                    public boolean shouldOverrideUrlLoading(WebView v, WebResourceRequest request) {
                        route(request.getUrl().toString());
                        return true;
                    }
                });
                ((WebView.WebViewTransport) resultMsg.obj).setWebView(relay);
                resultMsg.sendToTarget();
                return true;
            }
        });

        setContentView(webView);
        webView.addJavascriptInterface(new HostBridge(), "AndroidHost");
        webView.loadDataWithBaseURL("https://aigate.chudian.site/", readAsset("index.html"), "text/html", "utf-8", null);
    }

    /** 页面里的按钮通过这个桥接对象调用原生能力：剪贴板、应用内浏览页、实时悬浮窗 */
    private class HostBridge {
        @JavascriptInterface
        public boolean copy(String text) {
            try {
                ClipboardManager cm = (ClipboardManager) getSystemService(CLIPBOARD_SERVICE);
                cm.setPrimaryClip(ClipData.newPlainText("API Key", text));
                return true;
            } catch (Exception e) {
                return false;
            }
        }

        @JavascriptInterface
        public boolean isOverlayRunning() {
            return OverlayService.isRunning();
        }

        /** 返回 ok / need_permission / error */
        @JavascriptInterface
        public String startOverlay(String key, String priceYi, String seconds, String items) {
            if (!Settings.canDrawOverlays(MainActivity.this)) {
                try {
                    startActivity(new Intent(Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
                            Uri.parse("package:" + getPackageName())));
                } catch (Exception e) {
                    return "error";
                }
                return "need_permission";
            }
            Intent service = new Intent(MainActivity.this, OverlayService.class);
            service.setAction(OverlayService.ACTION_START);
            service.putExtra(OverlayService.EXTRA_KEY, key);
            service.putExtra(OverlayService.EXTRA_PRICE, priceYi);
            service.putExtra(OverlayService.EXTRA_SECONDS, seconds);
            service.putExtra(OverlayService.EXTRA_ITEMS, items);
            try {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) startForegroundService(service);
                else startService(service);
            } catch (Exception e) {
                return "error";
            }
            return "ok";
        }

        @JavascriptInterface
        public boolean stopOverlay() {
            stopService(new Intent(MainActivity.this, OverlayService.class));
            return true;
        }

        @JavascriptInterface
        public void updateOverlay(String key, String priceYi, String seconds, String items) {
            OverlayService.setCredentials(key, priceYi, seconds, items);
        }

        @JavascriptInterface
        public String appVersion() {
            try {
                return getPackageManager().getPackageInfo(getPackageName(), 0).versionName;
            } catch (Exception e) {
                return "unknown";
            }
        }

        /** 比对仓库清单与本地版本，返回 JSON；出错时带 error 字段，不影响其它功能 */
        @JavascriptInterface
        public String checkUpdate() {
            JSONObject result = new JSONObject();
            try {
                PackageInfo info = getPackageManager().getPackageInfo(getPackageName(), 0);
                result.put("currentName", info.versionName);
                result.put("currentCode", info.versionCode);
                JSONObject latest = fetchJson(UPDATE_MANIFEST);
                result.put("latestName", latest.optString("versionName"));
                result.put("latestCode", latest.optLong("versionCode"));
                result.put("apk", latest.optString("apk"));
                result.put("notes", latest.optString("notes"));
                result.put("hasUpdate", latest.optLong("versionCode") > info.versionCode);
            } catch (Exception e) {
                result.remove("error");
                try {
                    result.put("error", String.valueOf(e.getMessage()));
                } catch (Exception ignored) {
                    // JSONObject 不可能在这里失败
                }
            }
            return result.toString();
        }

        /** 交给系统下载器下载安装包，完成后用户在通知里点安装 */
        @JavascriptInterface
        public String downloadUpdate(String url, String fileName) {
            try {
                DownloadManager manager = (DownloadManager) getSystemService(DOWNLOAD_SERVICE);
                DownloadManager.Request request = new DownloadManager.Request(Uri.parse(url));
                request.setTitle("AIGate 用量 " + fileName);
                request.setDescription("下载完成后点通知安装");
                request.setMimeType("application/vnd.android.package-archive");
                request.setNotificationVisibility(DownloadManager.Request.VISIBILITY_VISIBLE_NOTIFY_COMPLETED);
                request.setDestinationInExternalPublicDir(Environment.DIRECTORY_DOWNLOADS, fileName);
                manager.enqueue(request);
                return "ok";
            } catch (Exception e) {
                return "error: " + e.getMessage();
            }
        }
    }

    @Override
    public void onBackPressed() {
        if (webView.canGoBack()) {
            webView.goBack();
        } else {
            super.onBackPressed();
        }
    }

    private JSONObject fetchJson(String url) throws Exception {
        HttpURLConnection conn = (HttpURLConnection) new URL(url).openConnection();
        try {
            conn.setConnectTimeout(10000);
            conn.setReadTimeout(10000);
            int code = conn.getResponseCode();
            if (code >= 400) throw new IllegalStateException("HTTP " + code);
            StringBuilder sb = new StringBuilder();
            try (BufferedReader reader = new BufferedReader(new InputStreamReader(conn.getInputStream(), StandardCharsets.UTF_8))) {
                String line;
                while ((line = reader.readLine()) != null) sb.append(line);
            }
            return new JSONObject(sb.toString());
        } finally {
            conn.disconnect();
        }
    }

    private void route(String url) {
        if (url.startsWith("http://") || url.startsWith("https://")) {
            startActivity(new Intent(this, WebPageActivity.class).putExtra(WebPageActivity.EXTRA_URL, url));
        } else {
            launchExternal(url);
        }
    }

    private void launchExternal(String url) {
        try {
            startActivity(new Intent(Intent.ACTION_VIEW, Uri.parse(url)));
        } catch (Exception e) {
            Toast.makeText(this, "没有可打开该链接的应用：" + url, Toast.LENGTH_LONG).show();
        }
    }

    private String readAsset(String name) {
        try (InputStream in = getAssets().open(name)) {
            ByteArrayOutputStream out = new ByteArrayOutputStream();
            byte[] buf = new byte[8192];
            int n;
            while ((n = in.read(buf)) > 0) out.write(buf, 0, n);
            return out.toString(StandardCharsets.UTF_8.name());
        } catch (Exception e) {
            return "<html><body style='font-family:sans-serif;padding:24px'>内置页面读取失败：" + e + "</body></html>";
        }
    }
}
