package com.hyperos.xj;

import android.app.Activity;
import android.content.ContentResolver;
import android.content.res.Configuration;
import android.graphics.Bitmap;
import android.net.Uri;
import android.net.http.SslError;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.os.SystemClock;
import android.view.Gravity;
import android.view.View;
import android.view.ViewGroup;
import android.webkit.RenderProcessGoneDetail;
import android.webkit.SslErrorHandler;
import android.webkit.WebResourceError;
import android.webkit.WebResourceRequest;
import android.webkit.WebResourceResponse;
import android.webkit.WebSettings;
import android.webkit.WebView;
import android.webkit.WebViewClient;
import android.widget.FrameLayout;

import org.json.JSONObject;

import java.io.ByteArrayInputStream;
import java.lang.ref.WeakReference;
import java.nio.charset.StandardCharsets;
import java.util.WeakHashMap;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.atomic.AtomicBoolean;

public final class CardOverlay {
    private static final Uri URI = Uri.parse("content://" + RearSnapshotProvider.AUTHORITY);
    private static final String PAGE_URL = "https://local.hyperos.xj/";
    private static final long REFRESH_MS = 1000L;
    private static final long TTL_MS = 5000L;
    private static final Handler MAIN = new Handler(Looper.getMainLooper());
    private static final WeakHashMap<Activity, Instance> INSTANCES = new WeakHashMap<>();
    private static final AtomicBoolean IN_FLIGHT = new AtomicBoolean();
    private static final ExecutorService READER = Executors.newSingleThreadExecutor(task -> {
        Thread thread = new Thread(task, "xj-rear-reader");
        thread.setDaemon(true);
        return thread;
    });

    private CardOverlay() {}

    public static void attach(Activity activity) {
        if (Looper.myLooper() != Looper.getMainLooper()) return;
        if (activity == null || activity.isFinishing() || activity.isDestroyed()) return;
        if (INSTANCES.containsKey(activity)) return;
        Instance instance = new Instance(activity);
        INSTANCES.put(activity, instance);
        instance.tick.run();
    }

    public static void detach(Activity activity) {
        if (Looper.myLooper() != Looper.getMainLooper()) return;
        Instance instance = INSTANCES.remove(activity);
        if (instance != null) instance.close();
    }

    private static final class Instance {
        final WeakReference<Activity> activity;
        final ContentResolver resolver;
        volatile boolean active = true;
        volatile String health = "observing";
        String html;
        WebView web;
        ViewGroup decor;
        JSONObject snapshot;
        long expiresAt;
        long loadStarted;
        long renderStarted;
        long retryAfter;
        boolean loaded;
        boolean rendering;
        String lastJson = "";

        final Runnable expire = new Runnable() {
            @Override public void run() {
                if (!active) return;
                if (!usable()) {
                    snapshot = null;
                    health = "stale";
                    removeCard();
                }
            }
        };

        final Runnable tick = new Runnable() {
            @Override public void run() {
                if (!active) return;
                Activity owner = activity.get();
                if (owner == null || owner.isFinishing() || owner.isDestroyed()) {
                    close();
                    return;
                }
                try {
                    if (snapshot != null && !usable()) {
                        snapshot = null;
                        health = "stale";
                        removeCard();
                    }
                    long now = SystemClock.elapsedRealtime();
                    if (web != null && !"visible".equals(health) && now - loadStarted >= 10000L) failCard();
                    if (rendering && now - renderStarted >= TTL_MS) failCard();
                    read();
                } catch (Throwable ignored) {
                    failCard();
                } finally {
                    if (active) MAIN.postDelayed(this, REFRESH_MS);
                }
            }
        };

        Instance(Activity owner) {
            activity = new WeakReference<>(owner);
            resolver = owner.getApplicationContext().getContentResolver();
        }

        void read() {
            if (!active || !IN_FLIGHT.compareAndSet(false, true)) return;
            final boolean needHtml = html == null;
            final String state = health;
            try {
                READER.execute(() -> {
                    JSONObject data = null;
                    String page = null;
                    String outcome = state;
                    try {
                        if (!active) return;
                        Bundle result = call(RearSnapshotProvider.METHOD_SNAPSHOT, null);
                        String json = result.getString("json", "");
                        if (json.length() > RearSnapshotProvider.MAX_SNAPSHOT_BYTES) throw new IllegalArgumentException("快照过大");
                        data = RearSnapshotProvider.parseSnapshot(json.getBytes(StandardCharsets.UTF_8), false);
                        if (!RearSnapshotProvider.isFresh(data) || !result.getBoolean("fresh", false)) {
                            data = null;
                            outcome = "stale";
                        } else if (!data.getBoolean("rearscreen")) {
                            outcome = "disabled";
                        } else if (needHtml && active) {
                            page = call(RearSnapshotProvider.METHOD_CARD, null).getString("html", "");
                            if (page.isEmpty() || page.length() > 512 * 1024) throw new IllegalArgumentException("卡片资源无效");
                            outcome = "loading";
                        }
                    } catch (Throwable ignored) {
                        data = null;
                        outcome = "error";
                    } finally {
                        final JSONObject received = data;
                        final String receivedHtml = page;
                        final String receivedState = outcome;
                        try {
                            if (active) MAIN.post(() -> accept(received, receivedHtml, receivedState));
                            if (active) call(RearSnapshotProvider.METHOD_REPORT_HEALTH, outcome);
                        } catch (Throwable ignored) {
                        } finally {
                            IN_FLIGHT.set(false);
                        }
                    }
                });
            } catch (Throwable ignored) {
                IN_FLIGHT.set(false);
                health = "error";
                snapshot = null;
                removeCard();
            }
        }

        Bundle call(String method, String arg) {
            if (Looper.myLooper() == Looper.getMainLooper()) throw new IllegalStateException("禁止主线程 Provider 访问");
            if (!active) return Bundle.EMPTY;
            Bundle result = resolver.call(URI, method, arg, null);
            return result == null ? Bundle.EMPTY : result;
        }

        void accept(JSONObject data, String page, String state) {
            if (!active) return;
            Activity owner = activity.get();
            if (owner == null || owner.isFinishing() || owner.isDestroyed()) {
                close();
                return;
            }
            MAIN.removeCallbacks(expire);
            if (data == null || !RearSnapshotProvider.isFresh(data) || !data.optBoolean("rearscreen", false)) {
                snapshot = null;
                health = data != null && !data.optBoolean("rearscreen", false) ? "disabled" : state;
                removeCard();
                return;
            }
            try {
                snapshot = data;
                long remaining = TTL_MS - (System.currentTimeMillis() - RearSnapshotProvider.timestampMillis(data));
                if (remaining <= 0) {
                    snapshot = null;
                    health = "stale";
                    removeCard();
                    return;
                }
                expiresAt = SystemClock.elapsedRealtime() + remaining;
                MAIN.postDelayed(expire, remaining);
                if (page != null) html = page;
                if (web == null && html != null && SystemClock.elapsedRealtime() >= retryAfter) createCard(owner);
                render();
            } catch (Throwable ignored) {
                failCard();
            }
        }

        boolean usable() {
            return active && snapshot != null && snapshot.optBoolean("rearscreen", false)
                    && RearSnapshotProvider.isFresh(snapshot) && SystemClock.elapsedRealtime() < expiresAt;
        }

        void createCard(Activity owner) {
            try {
                View root = owner.getWindow().getDecorView();
                if (!(root instanceof ViewGroup)) throw new IllegalStateException("无覆盖层容器");
                decor = (ViewGroup) root;
                web = new WebView(owner);
                final WebView current = web;
                current.setVisibility(View.INVISIBLE);
                WebSettings settings = current.getSettings();
                settings.setJavaScriptEnabled(true);
                settings.setDomStorageEnabled(false);
                settings.setAllowFileAccess(false);
                settings.setAllowContentAccess(false);
                settings.setAllowFileAccessFromFileURLs(false);
                settings.setAllowUniversalAccessFromFileURLs(false);
                settings.setBlockNetworkLoads(true);
                settings.setMixedContentMode(WebSettings.MIXED_CONTENT_NEVER_ALLOW);
                settings.setJavaScriptCanOpenWindowsAutomatically(false);
                settings.setSupportMultipleWindows(false);
                settings.setSupportZoom(false);
                settings.setBuiltInZoomControls(false);
                settings.setTextZoom(100);
                current.setBackgroundColor(0xFF000000);
                current.setVerticalScrollBarEnabled(false);
                current.setHorizontalScrollBarEnabled(false);
                current.setOverScrollMode(WebView.OVER_SCROLL_NEVER);
                current.setOnLongClickListener(view -> true);
                current.setWebViewClient(new WebViewClient() {
                    @Override public boolean shouldOverrideUrlLoading(WebView view, String url) { return true; }
                    @Override public boolean shouldOverrideUrlLoading(WebView view, WebResourceRequest request) { return true; }
                    @Override public WebResourceResponse shouldInterceptRequest(WebView view, WebResourceRequest request) {
                        return blockedResponse();
                    }
                    @Override public WebResourceResponse shouldInterceptRequest(WebView view, String url) {
                        return blockedResponse();
                    }
                    @Override public void onPageStarted(WebView view, String url, Bitmap icon) {
                        if (view == web && !PAGE_URL.equals(url) && !"about:blank".equals(url)) failCard();
                    }
                    @Override public void onPageFinished(WebView view, String url) {
                        if (!active || view != web) return;
                        if (!PAGE_URL.equals(url)) { failCard(); return; }
                        loaded = true;
                        lastJson = "";
                        render();
                    }
                    @Override public void onReceivedError(WebView view, WebResourceRequest request, WebResourceError error) {
                        if (view == web && request.isForMainFrame()) failCard();
                    }
                    @Override public void onReceivedHttpError(WebView view, WebResourceRequest request, WebResourceResponse error) {
                        if (view == web && request.isForMainFrame()) failCard();
                    }
                    @Override public void onReceivedSslError(WebView view, SslErrorHandler handler, SslError error) {
                        handler.cancel();
                        if (view == web) failCard();
                    }
                    @Override public boolean onRenderProcessGone(WebView view, RenderProcessGoneDetail detail) {
                        if (view == web) failCard();
                        return true;
                    }
                });
                FrameLayout.LayoutParams params = new FrameLayout.LayoutParams(
                        FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.MATCH_PARENT, Gravity.FILL);
                decor.addView(current, params);
                health = "loading";
                loadStarted = SystemClock.elapsedRealtime();
                current.loadDataWithBaseURL(PAGE_URL, html, "text/html", "UTF-8", null);
            } catch (Throwable ignored) {
                failCard();
            }
        }

        private WebResourceResponse blockedResponse() {
            return new WebResourceResponse("text/plain", "UTF-8", new ByteArrayInputStream(new byte[0]));
        }

        void render() {
            if (!active || !loaded || web == null || rendering) return;
            if (!usable()) { removeCard(); return; }
            try {
                final String json = snapshot.toString();
                if (json.equals(lastJson)) return;
                final WebView current = web;
                rendering = true;
                renderStarted = SystemClock.elapsedRealtime();
                String script = "(function(){try{var d=JSON.parse(" + JSONObject.quote(json) + ");"
                        + "if(typeof window.__rear!=='function')return false;window.__rear(d);"
                        + "var t=d.theme||'dark';if(t==='system')t=" + JSONObject.quote(systemTheme()) + ";"
                        + "document.documentElement.setAttribute('data-theme',t);"
                        + "document.documentElement.style.setProperty('--fs',String(d.font_scale||1));"
                        + "document.documentElement.style.setProperty('--accent-rgb',d.accent||'245,158,11');"
                        + "var s=document.getElementById('xj-appearance');if(!s){s=document.createElement('style');s.id='xj-appearance';document.head.appendChild(s);}"
                        + "s.textContent='[data-theme=light] #screen,[data-theme=light] .board,[data-theme=light] .panel,[data-theme=light] .status-pill{background:#fff;color:#111}'"
                        + "+'[data-theme=light] .fluid{background:#fff}[data-theme=light] .d-val b,[data-theme=light] .pw{color:#111;text-shadow:none}'"
                        + "+'[data-theme=light] .d-head,[data-theme=light] .d-val em,[data-theme=light] .unit{color:#666}[data-theme=light] .track{stroke:rgba(0,0,0,.12)}'"
                        + "+'.d-head{font-size:calc(17px * var(--fs,1))}.d-val b{font-size:calc(46px * var(--fs,1))}.d-val em{font-size:calc(20px * var(--fs,1))}'"
                        + "+'.status-pill{font-size:calc(16px * var(--fs,1))}.pw{font-size:calc(72px * var(--fs,1))}.unit{font-size:calc(18px * var(--fs,1))}';"
                        + "return true;}catch(e){return false;}})()";
                current.evaluateJavascript(script, result -> {
                    if (!active || web != current) return;
                    rendering = false;
                    if (!"true".equals(result)) { failCard(); return; }
                    if (!usable()) { removeCard(); return; }
                    lastJson = json;
                    try {
                        current.postVisualStateCallback(0, new WebView.VisualStateCallback() {
                            @Override public void onComplete(long requestId) {
                                if (!active || web != current) return;
                                try {
                                    if (!usable()) { removeCard(); return; }
                                    current.setVisibility(View.VISIBLE);
                                    health = "visible";
                                } catch (Throwable ignored) {
                                    failCard();
                                }
                            }
                        });
                        if (!json.equals(snapshot.toString())) render();
                    } catch (Throwable ignored) {
                        failCard();
                    }
                });
            } catch (Throwable ignored) {
                failCard();
            }
        }

        String systemTheme() {
            Activity owner = activity.get();
            return owner != null && (owner.getResources().getConfiguration().uiMode & Configuration.UI_MODE_NIGHT_MASK)
                    == Configuration.UI_MODE_NIGHT_YES ? "dark" : "light";
        }

        void failCard() {
            health = "error";
            retryAfter = SystemClock.elapsedRealtime() + TTL_MS;
            removeCard();
        }

        void removeCard() {
            WebView old = web;
            web = null;
            loaded = false;
            rendering = false;
            lastJson = "";
            if (old != null) {
                try { old.setVisibility(View.GONE); } catch (Throwable ignored) { }
                try {
                    if (old.getParent() instanceof ViewGroup) ((ViewGroup) old.getParent()).removeView(old);
                } catch (Throwable ignored) { }
                try { old.stopLoading(); } catch (Throwable ignored) { }
                try { old.setWebViewClient(null); } catch (Throwable ignored) { }
                try { old.removeAllViews(); } catch (Throwable ignored) { }
                try { old.destroy(); } catch (Throwable ignored) { }
            }
            decor = null;
        }

        void close() {
            active = false;
            MAIN.removeCallbacks(tick);
            MAIN.removeCallbacks(expire);
            snapshot = null;
            html = null;
            health = "paused";
            removeCard();
        }
    }
}
