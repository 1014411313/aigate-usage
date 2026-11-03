package site.chudian.aigate.usage;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.app.Service;
import android.content.Intent;
import android.graphics.PixelFormat;
import android.graphics.drawable.GradientDrawable;
import android.os.Build;
import android.os.Handler;
import android.os.IBinder;
import android.os.Looper;
import android.util.TypedValue;
import android.view.Gravity;
import android.view.MotionEvent;
import android.view.View;
import android.view.WindowManager;
import android.widget.LinearLayout;
import android.widget.TextView;

import org.json.JSONArray;
import org.json.JSONObject;

import java.io.BufferedReader;
import java.io.InputStream;
import java.io.InputStreamReader;
import java.io.OutputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.nio.charset.StandardCharsets;
import java.text.SimpleDateFormat;
import java.util.Arrays;
import java.util.Date;
import java.util.HashSet;
import java.util.LinkedHashMap;
import java.util.Locale;
import java.util.Map;
import java.util.Set;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

/** 桌面悬浮窗：定时拉取用量，按页面选定的项目逐行显示，带自动更新倒计时 */
public class OverlayService extends Service {

    public static final String ACTION_START = "site.chudian.aigate.usage.START";
    public static final String ACTION_STOP = "site.chudian.aigate.usage.STOP";
    public static final String EXTRA_KEY = "key";
    public static final String EXTRA_PRICE = "priceYi";
    public static final String EXTRA_SECONDS = "seconds";
    public static final String EXTRA_ITEMS = "items";

    private static final String ORIGIN = "https://aigate.chudian.site";
    private static final String CHANNEL_ID = "aigate_overlay";
    private static final int NOTIFICATION_ID = 1001;
    private static final String[] ITEM_KEYS = {"token", "today", "month", "monthMoney", "spent", "leftMoney", "countdown"};

    private static volatile boolean running = false;
    private static volatile OverlayService instance;

    public static boolean isRunning() {
        return running;
    }

    /** 页面改了 Key / 单价 / 间隔 / 显示项时调用，不必关掉重开 */
    public static void setCredentials(String key, String priceYi, String seconds, String items) {
        final OverlayService service = instance;
        if (service == null || key == null || key.trim().isEmpty()) return;
        service.apiKey = key.trim();
        service.priceYi = parseDouble(priceYi, 29);
        service.intervalMs = (long) (parseDouble(seconds, 60) * 1000);
        service.items = parseItems(items);
        service.handler.post(new Runnable() {
            @Override
            public void run() {
                service.applyItems();
                service.refreshNow();
            }
        });
    }

    private static double parseDouble(String raw, double fallback) {
        try {
            double v = Double.parseDouble(raw);
            return v > 0 ? v : fallback;
        } catch (Exception e) {
            return fallback;
        }
    }

    private static Set<String> parseItems(String raw) {
        Set<String> set = new HashSet<>();
        if (raw == null || raw.trim().isEmpty()) {
            set.addAll(Arrays.asList(ITEM_KEYS));
            return set;
        }
        for (String part : raw.split(",")) {
            String key = part.trim();
            if (Arrays.asList(ITEM_KEYS).contains(key)) set.add(key);
        }
        return set;
    }

    private WindowManager windowManager;
    private WindowManager.LayoutParams params;
    private View overlayView;
    private final Map<String, TextView> lines = new LinkedHashMap<>();

    private final Handler handler = new Handler(Looper.getMainLooper());
    private final ExecutorService executor = Executors.newSingleThreadExecutor();
    private volatile boolean fetching = false;
    private volatile String apiKey;
    private volatile double priceYi = 29;
    private volatile long intervalMs = 60000L;
    private volatile Set<String> items = new HashSet<>(Arrays.asList(ITEM_KEYS));
    private volatile long nextRefreshAt = 0;
    private volatile long lastUpdatedAt = 0;

    private final Runnable ticker = new Runnable() {
        @Override
        public void run() {
            if (lastUpdatedAt > 0 && System.currentTimeMillis() >= nextRefreshAt) {
                refreshNow();
            }
            renderCountdown();
            handler.postDelayed(this, 1000);
        }
    };

    @Override
    public IBinder onBind(Intent intent) {
        return null;
    }

    @Override
    public int onStartCommand(Intent intent, int flags, int startId) {
        if (intent == null || ACTION_STOP.equals(intent.getAction())) {
            stopSelf();
            return START_NOT_STICKY;
        }
        String key = intent.getStringExtra(EXTRA_KEY);
        if (key == null || key.trim().isEmpty()) {
            stopSelf();
            return START_NOT_STICKY;
        }
        apiKey = key.trim();
        priceYi = parseDouble(intent.getStringExtra(EXTRA_PRICE), 29);
        intervalMs = (long) (parseDouble(intent.getStringExtra(EXTRA_SECONDS), 60) * 1000);
        items = parseItems(intent.getStringExtra(EXTRA_ITEMS));
        instance = this;

        startForegroundCompat();
        if (overlayView == null) {
            showOverlay();
        }
        applyItems();
        refreshNow();
        handler.removeCallbacks(ticker);
        handler.post(ticker);
        return START_NOT_STICKY;
    }

    @Override
    public void onDestroy() {
        running = false;
        instance = null;
        handler.removeCallbacks(ticker);
        executor.shutdownNow();
        if (overlayView != null && windowManager != null) {
            try {
                windowManager.removeView(overlayView);
            } catch (Exception ignored) {
                // 已被系统移除
            }
            overlayView = null;
        }
        super.onDestroy();
    }

    private void startForegroundCompat() {
        NotificationManager nm = (NotificationManager) getSystemService(NOTIFICATION_SERVICE);
        Notification.Builder builder;
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            NotificationChannel channel = new NotificationChannel(CHANNEL_ID, "用量悬浮窗", NotificationManager.IMPORTANCE_MIN);
            channel.setShowBadge(false);
            nm.createNotificationChannel(channel);
            builder = new Notification.Builder(this, CHANNEL_ID);
        } else {
            builder = new Notification.Builder(this);
        }
        Intent open = new Intent(this, MainActivity.class);
        PendingIntent pending = PendingIntent.getActivity(this, 0, open, PendingIntent.FLAG_IMMUTABLE);
        Notification notification = builder
                .setContentTitle("AIGate 用量悬浮窗")
                .setContentText("正在显示实时用量")
                .setSmallIcon(android.R.drawable.stat_notify_sync)
                .setContentIntent(pending)
                .setOngoing(true)
                .build();
        startForeground(NOTIFICATION_ID, notification);
    }

    private void showOverlay() {
        windowManager = (WindowManager) getSystemService(WINDOW_SERVICE);

        LinearLayout card = new LinearLayout(this);
        card.setOrientation(LinearLayout.VERTICAL);
        card.setPadding(dp(13), dp(10), dp(13), dp(11));
        GradientDrawable bg = new GradientDrawable();
        bg.setColor(0xF21E293B);
        bg.setCornerRadius(dp(16));
        bg.setStroke(dp(1), 0x4DFFFFFF);
        card.setBackground(bg);

        LinearLayout header = new LinearLayout(this);
        header.setOrientation(LinearLayout.HORIZONTAL);
        header.setGravity(Gravity.CENTER_VERTICAL);

        TextView title = new TextView(this);
        title.setText("AIGate 用量");
        title.setTextColor(0xFF94A3B8);
        title.setTextSize(TypedValue.COMPLEX_UNIT_SP, 10);
        header.addView(title, new LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f));

        TextView close = new TextView(this);
        close.setText("✕");
        close.setTextColor(0xFF94A3B8);
        close.setTextSize(TypedValue.COMPLEX_UNIT_SP, 13);
        close.setPadding(dp(10), 0, 0, 0);
        close.setOnClickListener(new View.OnClickListener() {
            @Override
            public void onClick(View v) {
                stopSelf();
            }
        });
        header.addView(close);
        card.addView(header);

        for (String key : ITEM_KEYS) {
            TextView line = new TextView(this);
            line.setTextSize(TypedValue.COMPLEX_UNIT_SP, "countdown".equals(key) ? 10 : 14);
            line.setTextColor("countdown".equals(key) ? 0xFF94A3B8 : 0xFFF1F5F9);
            line.setPadding(0, dp("countdown".equals(key) ? 5 : 6), 0, 0);
            lines.put(key, line);
            card.addView(line);
        }
        renderCountdown();

        params = new WindowManager.LayoutParams(
                WindowManager.LayoutParams.WRAP_CONTENT,
                WindowManager.LayoutParams.WRAP_CONTENT,
                Build.VERSION.SDK_INT >= Build.VERSION_CODES.O
                        ? WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY
                        : WindowManager.LayoutParams.TYPE_PHONE,
                WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE | WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL,
                PixelFormat.TRANSLUCENT);
        params.gravity = Gravity.TOP | Gravity.START;
        params.x = dp(12);
        params.y = dp(160);

        card.setOnTouchListener(new View.OnTouchListener() {
            private float downX, downY;
            private int startX, startY;
            private boolean moved;

            @Override
            public boolean onTouch(View v, MotionEvent event) {
                switch (event.getActionMasked()) {
                    case MotionEvent.ACTION_DOWN:
                        downX = event.getRawX();
                        downY = event.getRawY();
                        startX = params.x;
                        startY = params.y;
                        moved = false;
                        return true;
                    case MotionEvent.ACTION_MOVE:
                        int dx = (int) (event.getRawX() - downX);
                        int dy = (int) (event.getRawY() - downY);
                        if (Math.abs(dx) > dp(8) || Math.abs(dy) > dp(8)) moved = true;
                        params.x = startX + dx;
                        params.y = startY + dy;
                        windowManager.updateViewLayout(overlayView, params);
                        return true;
                    case MotionEvent.ACTION_UP:
                        if (!moved) refreshNow();
                        return true;
                    default:
                        return false;
                }
            }
        });

        overlayView = card;
        windowManager.addView(overlayView, params);
        running = true;
    }

    private void applyItems() {
        if (lines.isEmpty()) return;
        for (Map.Entry<String, TextView> entry : lines.entrySet()) {
            entry.getValue().setVisibility(items.contains(entry.getKey()) ? View.VISIBLE : View.GONE);
        }
    }

    private void refreshNow() {
        if (overlayView == null) return;
        setLine("countdown", "正在刷新…");
        fetchAndRender();
    }

    private void fetchAndRender() {
        if (fetching || apiKey == null) return;
        fetching = true;
        executor.execute(new Runnable() {
            @Override
            public void run() {
                try {
                    String month = new SimpleDateFormat("yyyy-MM", Locale.CHINA).format(new Date());
                    JSONObject balance = getJson("/user/balance");
                    JSONObject monthly = getJson("/user/usage/monthly?month=" + month);
                    JSONObject credit = postJson("/pay/credit-usage",
                            "{\"api_key\":" + JSONObject.quote(apiKey) + ",\"month\":" + JSONObject.quote(month) + ",\"per_page\":1}");
                    render(balance, credit, monthly);
                    lastUpdatedAt = System.currentTimeMillis();
                    nextRefreshAt = lastUpdatedAt + intervalMs;
                } catch (Exception e) {
                    setLine("countdown", "更新失败：" + e.getMessage());
                    nextRefreshAt = System.currentTimeMillis() + intervalMs;
                } finally {
                    fetching = false;
                }
            }
        });
    }

    private void render(JSONObject balanceRoot, JSONObject creditRoot, JSONObject monthlyRoot) {
        JSONObject balance = opt(balanceRoot, "data");
        JSONObject creditData = opt(creditRoot, "data");
        JSONObject quota = opt(creditData, "balance");
        JSONObject monthly = opt(monthlyRoot, "data");
        JSONObject summary = opt(monthly, "summary");
        JSONObject full = opt(quota, "token");
        JSONObject creditQuota = opt(quota, "credit");
        JSONObject moneyQuota = opt(quota, "money");

        double ratio = creditData.optDouble("credit_to_token_ratio", 0);
        long remaining = balance.optLong("token_balance", full.optLong("remaining", 0));
        double perToken = priceYi / 1e8;
        double usedTokens = full.optDouble("used", 0) + creditQuota.optDouble("used", 0) * ratio;
        double leftTokens = full.optDouble("remaining", 0) + creditQuota.optDouble("remaining", 0) * ratio;

        long todayTokens = 0;
        double todayCost = 0;
        String todayKey = new SimpleDateFormat("yyyy-MM-dd", Locale.CHINA).format(new Date());
        JSONArray daily = monthly.optJSONArray("daily");
        if (daily != null) {
            for (int i = 0; i < daily.length(); i++) {
                JSONObject row = daily.optJSONObject(i);
                if (row != null && todayKey.equals(row.optString("date"))) {
                    todayTokens = row.optLong("total_tokens", 0);
                    todayCost = row.optDouble("quota_cost", 0);
                    break;
                }
            }
        }

        setLine("token", "剩余 " + compactTokens(remaining));
        setLine("today", "今日消耗 " + compactTokens(todayCost));
        setLine("month", "本月消耗 " + compactTokens(summary.optDouble("total_cost", 0)));
        setLine("monthMoney", "本月已花 " + yuan(summary.optDouble("total_cost", 0) * perToken));
        setLine("spent", "总共已花 " + yuan(usedTokens * perToken + moneyQuota.optDouble("used", 0)));
        setLine("leftMoney", "剩余金额 " + yuan(leftTokens * perToken + moneyQuota.optDouble("remaining", 0)));
        renderCountdown();
    }

    private JSONObject opt(JSONObject parent, String name) {
        JSONObject child = parent == null ? null : parent.optJSONObject(name);
        return child == null ? new JSONObject() : child;
    }

    private void renderCountdown() {
        if (lastUpdatedAt == 0) return;
        long left = Math.max(0, (nextRefreshAt - System.currentTimeMillis()) / 1000);
        String time = new SimpleDateFormat("HH:mm:ss", Locale.CHINA).format(new Date(lastUpdatedAt));
        setLine("countdown", "更新 " + time + " · " + left + " 秒后刷新");
    }

    private void setLine(final String key, final String text) {
        handler.post(new Runnable() {
            @Override
            public void run() {
                TextView line = lines.get(key);
                if (line != null) line.setText(text);
            }
        });
    }

    /** 悬浮窗窄，token 用万 / 亿缩写，避免一行放不下 */
    private static String compactTokens(double value) {
        if (Math.abs(value) >= 1e8) return String.format(Locale.CHINA, "%.2f亿", value / 1e8);
        if (Math.abs(value) >= 1e4) return String.format(Locale.CHINA, "%.0f万", value / 1e4);
        return String.format(Locale.CHINA, "%.0f", value);
    }

    private static String yuan(double value) {
        return String.format(Locale.CHINA, "¥%.2f", value);
    }

    private JSONObject getJson(String path) throws Exception {
        HttpURLConnection conn = (HttpURLConnection) new URL(ORIGIN + path).openConnection();
        conn.setRequestProperty("Authorization", "Bearer " + apiKey);
        return request(conn);
    }

    private JSONObject postJson(String path, String body) throws Exception {
        HttpURLConnection conn = (HttpURLConnection) new URL(ORIGIN + path).openConnection();
        conn.setRequestMethod("POST");
        conn.setDoOutput(true);
        conn.setRequestProperty("Content-Type", "application/json");
        try (OutputStream out = conn.getOutputStream()) {
            out.write(body.getBytes(StandardCharsets.UTF_8));
        }
        return request(conn);
    }

    private JSONObject request(HttpURLConnection conn) throws Exception {
        try {
            conn.setConnectTimeout(15000);
            conn.setReadTimeout(15000);
            int code = conn.getResponseCode();
            InputStream in = code >= 400 ? conn.getErrorStream() : conn.getInputStream();
            StringBuilder sb = new StringBuilder();
            if (in != null) {
                try (BufferedReader reader = new BufferedReader(new InputStreamReader(in, StandardCharsets.UTF_8))) {
                    String line;
                    while ((line = reader.readLine()) != null) sb.append(line);
                }
            }
            if (code >= 400) throw new IllegalStateException(errorMessage(sb.toString(), code));
            return new JSONObject(sb.toString());
        } finally {
            conn.disconnect();
        }
    }

    /** 服务端错误体形如 {"error":{"message":"..."}} 或 {"error":"API Key 无效"}，取出来直接给人看 */
    private String errorMessage(String body, int code) {
        try {
            JSONObject json = new JSONObject(body);
            JSONObject nested = json.optJSONObject("error");
            if (nested != null) {
                String message = nested.optString("message", "");
                if (!message.isEmpty()) return message;
            }
            String flat = json.optString("error_message", json.optString("error", ""));
            if (!flat.isEmpty()) return flat;
        } catch (Exception ignored) {
            // 非 JSON 错误体，回退到状态码
        }
        return "HTTP " + code;
    }

    private int dp(int value) {
        return (int) (value * getResources().getDisplayMetrics().density);
    }
}
