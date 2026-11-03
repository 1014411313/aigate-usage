package site.chudian.githubhosts;

import android.app.AlarmManager;
import android.app.PendingIntent;
import android.content.Context;
import android.content.Intent;
import android.os.Build;
import android.os.SystemClock;

/** 每 12 小时触发一次自动更新。用 setInexactRepeating，免精确闹钟权限 */
final class UpdateScheduler {

    static final long INTERVAL_MS = 12L * 60 * 60 * 1000;
    private static final int REQUEST_CODE = 1001;

    private UpdateScheduler() {
    }

    static void schedule(Context ctx) {
        AlarmManager am = (AlarmManager) ctx.getSystemService(Context.ALARM_SERVICE);
        if (am == null) {
            return;
        }
        Intent intent = new Intent(ctx, UpdateReceiver.class);
        intent.setAction(UpdateReceiver.ACTION_UPDATE);
        int flags = PendingIntent.FLAG_UPDATE_CURRENT;
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            flags |= PendingIntent.FLAG_IMMUTABLE;
        }
        PendingIntent pi = PendingIntent.getBroadcast(ctx, REQUEST_CODE, intent, flags);
        am.setInexactRepeating(AlarmManager.ELAPSED_REALTIME_WAKEUP,
                SystemClock.elapsedRealtime() + INTERVAL_MS, INTERVAL_MS, pi);
    }
}
