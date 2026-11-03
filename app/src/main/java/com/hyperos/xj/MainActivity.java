package com.hyperos.xj;

import android.app.Activity;
import android.graphics.Color;
import android.graphics.drawable.ColorDrawable;
import android.os.Bundle;
import android.view.View;
import android.webkit.WebChromeClient;
import android.webkit.WebSettings;
import android.webkit.WebView;
import android.webkit.WebViewClient;
import android.widget.FrameLayout;
import android.widget.Toast;

import org.json.JSONObject;

import java.io.File;
import java.io.FileOutputStream;
import java.io.InputStream;
import java.io.OutputStream;
import java.nio.charset.StandardCharsets;

public final class MainActivity extends Activity {
    private WebView web;
    private FrameLayout root;
    private NativeShell bridge;
    private File webDir;
    private android.webkit.ValueCallback<android.net.Uri[]> fileCallback;
    private String pageUrl;

    @Override
    protected void onCreate(Bundle state) {
        super.onCreate(state);
        getWindow().setBackgroundDrawable(new ColorDrawable(Color.rgb(10, 12, 18)));
        root = new FrameLayout(this);
        web = new WebView(this);
        root.addView(web, new FrameLayout.LayoutParams(-1, -1));
        setContentView(root);

        webDir = new File(getCacheDir(), "control-web");
        bridge = new NativeShell(this);
        WebSettings settings = web.getSettings();
        settings.setJavaScriptEnabled(true);
        settings.setDomStorageEnabled(true);
        settings.setAllowFileAccess(true);
        settings.setAllowContentAccess(true);
        settings.setAllowFileAccessFromFileURLs(false);
        settings.setAllowUniversalAccessFromFileURLs(false);
        settings.setJavaScriptCanOpenWindowsAutomatically(false);
        settings.setSupportZoom(false);
        settings.setBuiltInZoomControls(false);
        settings.setTextZoom(100);
        settings.setMixedContentMode(WebSettings.MIXED_CONTENT_NEVER_ALLOW);
        web.setBackgroundColor(Color.TRANSPARENT);
        web.setOverScrollMode(View.OVER_SCROLL_NEVER);
        web.setVerticalScrollBarEnabled(false);
        web.setHorizontalScrollBarEnabled(false);
        web.addJavascriptInterface(bridge, "NativeShell");
        web.setWebChromeClient(new WebChromeClient() {
            @Override public boolean onShowFileChooser(WebView view, android.webkit.ValueCallback<android.net.Uri[]> callback, FileChooserParams params) {
                if (fileCallback != null) fileCallback.onReceiveValue(null);
                fileCallback = callback;
                try {
                    android.content.Intent intent = new android.content.Intent(android.content.Intent.ACTION_OPEN_DOCUMENT);
                    intent.addCategory(android.content.Intent.CATEGORY_OPENABLE);
                    intent.setType("*/*");
                    startActivityForResult(intent, 40);
                    return true;
                } catch (Exception e) { fileCallback = null; callback.onReceiveValue(null); return true; }
            }
        });
        web.setWebViewClient(new WebViewClient() {
            @Override public android.webkit.WebResourceResponse shouldInterceptRequest(WebView view, android.webkit.WebResourceRequest request) {
                android.net.Uri uri = request.getUrl();
                String scheme = uri.getScheme();
                boolean trusted = "data".equals(scheme) || "blob".equals(scheme);
                if ("file".equals(scheme)) {
                    try {
                        String file = new File(uri.getPath()).getCanonicalPath();
                        trusted = file.startsWith(webDir.getCanonicalPath() + "/")
                                || file.equals(new File(getCacheDir(), "card.html").getCanonicalPath());
                    } catch (Exception ignored) { }
                }
                if (trusted) return null;
                return new android.webkit.WebResourceResponse("text/plain", "UTF-8", new java.io.ByteArrayInputStream(new byte[0]));
            }
            @Override public boolean shouldOverrideUrlLoading(WebView view, android.webkit.WebResourceRequest request) {
                String url = request.getUrl().toString();
                if (!request.isForMainFrame() && ("about:srcdoc".equals(url) || "about:blank".equals(url))) return false;
                return !isControlPage(url);
            }
            @Override public boolean shouldOverrideUrlLoading(WebView view, String url) {
                return !isControlPage(url);
            }
        });

        try {
            copyAssetTree("control", webDir);
            copyAssetTree("card.html", new File(getCacheDir(), "card.html"));
            pageUrl = new File(webDir, "index.html").toURI().toString();
            web.loadUrl(pageUrl);
        } catch (Exception e) {
            Toast.makeText(this, "控制页面加载失败：" + e.getMessage(), Toast.LENGTH_LONG).show();
        }
    }

    private boolean isControlPage(String url) {
        if (url == null) return false;
        android.net.Uri uri = android.net.Uri.parse(url);
        if (!"file".equals(uri.getScheme()) || uri.getPath() == null) return false;
        try { return new File(uri.getPath()).getCanonicalFile().equals(new File(webDir, "index.html").getCanonicalFile()); }
        catch (Exception e) { return false; }
    }

    private void copyAssetTree(String path, File target) throws Exception {
        String[] children;
        try {
            children = getAssets().list(path);
        } catch (Exception e) {
            children = null;
        }
        if (children == null || children.length == 0) {
            File parent = target.getParentFile();
            if (parent != null && !parent.exists() && !parent.mkdirs()) throw new IllegalStateException("无法创建 WebView 资源目录");
            try (InputStream in = getAssets().open(path); OutputStream out = new FileOutputStream(target)) {
                byte[] buffer = new byte[16384];
                int size;
                while ((size = in.read(buffer)) != -1) out.write(buffer, 0, size);
            }
            return;
        }
        if (!target.exists() && !target.mkdirs()) throw new IllegalStateException("无法创建 WebView 资源目录");
        for (String child : children) copyAssetTree(path + "/" + child, new File(target, child));
    }

    void evaluate(String javascript) {
        if (web != null) web.evaluateJavascript(javascript, null);
    }

    FrameLayout overlayRoot() {
        return root;
    }

    @Override
    public void onBackPressed() {
        if (web != null && web.canGoBack()) web.goBack();
        else super.onBackPressed();
    }

    @Override protected void onActivityResult(int request, int result, android.content.Intent intent) {
        super.onActivityResult(request, result, intent);
        if (request == 40 && fileCallback != null) {
            fileCallback.onReceiveValue(result == RESULT_OK && intent != null && intent.getData() != null
                    ? new android.net.Uri[]{intent.getData()} : null);
            fileCallback = null;
        }
    }

    @Override
    protected void onDestroy() {
        if (fileCallback != null) { fileCallback.onReceiveValue(null); fileCallback = null; }
        if (bridge != null) bridge.close();
        if (web != null) web.destroy();
        super.onDestroy();
    }
}
