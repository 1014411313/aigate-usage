package site.chudian.githubhosts;

import android.app.Activity;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.view.ViewGroup;
import android.webkit.JavascriptInterface;
import android.webkit.WebSettings;
import android.webkit.WebView;
import android.widget.Toast;

import org.json.JSONObject;

import java.util.concurrent.Callable;

/** 界面是 assets/index.html，通过 Android 这个 JS 桥调用原生能力 */
public class MainActivity extends Activity {

    private WebView webView;
    private final Handler handler = new Handler(Looper.getMainLooper());

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);

        webView = new WebView(this);
        WebSettings s = webView.getSettings();
        s.setJavaScriptEnabled(true);
        s.setDomStorageEnabled(true);
        s.setAllowFileAccess(true);
        webView.setBackgroundColor(0xFF0F1115);
        webView.addJavascriptInterface(new JsApi(), "Android");

        setContentView(webView, new ViewGroup.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT));
        webView.loadUrl("file:///android_asset/index.html");

        UpdateScheduler.schedule(this);
    }

    @Override
    protected void onDestroy() {
        if (webView != null) {
            webView.destroy();
            webView = null;
        }
        super.onDestroy();
    }

    /** 耗时操作放到后台线程，完成后回调 window.__onResult(kind, text) */
    private void runAsync(final String kind, final Callable<String> job) {
        new Thread(new Runnable() {
            @Override
            public void run() {
                String result;
                try {
                    result = job.call();
                } catch (Throwable t) {
                    result = "错误：" + t;
                }
                final String js = "window.__onResult(" + JSONObject.quote(kind) + ","
                        + JSONObject.quote(result) + ")";
                handler.post(new Runnable() {
                    @Override
                    public void run() {
                        if (webView != null) {
                            webView.evaluateJavascript(js, null);
                        }
                    }
                });
            }
        }).start();
    }

    public class JsApi {

        @JavascriptInterface
        public String sources() {
            return Updater.loadSources(MainActivity.this);
        }

        @JavascriptInterface
        public void saveSources(String json) {
            Updater.saveSources(MainActivity.this, json);
        }

        @JavascriptInterface
        public String disabled() {
            return Updater.loadDisabled(MainActivity.this);
        }

        @JavascriptInterface
        public void saveDisabled(String list) {
            Updater.saveDisabled(MainActivity.this, list);
        }

        @JavascriptInterface
        public String status() {
            return Updater.status(MainActivity.this);
        }

        @JavascriptInterface
        public String log() {
            return Updater.readLog(MainActivity.this);
        }

        @JavascriptInterface
        public String rootState() {
            return HostsApplier.describeRoot();
        }

        @JavascriptInterface
        public void update() {
            runAsync("update", new Callable<String>() {
                @Override
                public String call() {
                    return Updater.update(MainActivity.this);
                }
            });
        }

        @JavascriptInterface
        public void apply() {
            runAsync("apply", new Callable<String>() {
                @Override
                public String call() {
                    return HostsApplier.apply(MainActivity.this);
                }
            });
        }

        @JavascriptInterface
        public void restore() {
            runAsync("restore", new Callable<String>() {
                @Override
                public String call() {
                    return HostsApplier.restore(MainActivity.this);
                }
            });
        }

        @JavascriptInterface
        public void testNet() {
            runAsync("net", new Callable<String>() {
                @Override
                public String call() {
                    return Updater.testNet();
                }
            });
        }

        @JavascriptInterface
        public void probe(String url) {
            final String u = url;
            runAsync("probe", new Callable<String>() {
                @Override
                public String call() {
                    return Mirror.probeAll(u);
                }
            });
        }

        @JavascriptInterface
        public void downloadUrl(String url) {
            final String u = url;
            runAsync("download", new Callable<String>() {
                @Override
                public String call() {
                    return Mirror.download(MainActivity.this, u);
                }
            });
        }

        @JavascriptInterface
        public void toast(String msg) {
            final String m = msg;
            handler.post(new Runnable() {
                @Override
                public void run() {
                    Toast.makeText(MainActivity.this, m, Toast.LENGTH_SHORT).show();
                }
            });
        }
    }
}
