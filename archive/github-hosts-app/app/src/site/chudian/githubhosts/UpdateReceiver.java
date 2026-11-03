package site.chudian.githubhosts;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;

/** 定时更新 + 开机后重新排程并应用 hosts */
public class UpdateReceiver extends BroadcastReceiver {

    static final String ACTION_UPDATE = "site.chudian.githubhosts.ACTION_UPDATE";

    @Override
    public void onReceive(Context context, Intent intent) {
        final Context ctx = context.getApplicationContext();
        final String action = intent.getAction() == null ? "" : intent.getAction();

        UpdateScheduler.schedule(ctx);

        final boolean boot = Intent.ACTION_BOOT_COMPLETED.equals(action);
        final PendingResult pending = goAsync();
        new Thread(new Runnable() {
            @Override
            public void run() {
                try {
                    if (!boot) {
                        Updater.update(ctx);
                    }
                    // bind mount 的方式重启后会失效，所以开机时也要重新应用一次
                    HostsApplier.apply(ctx);
                } finally {
                    pending.finish();
                }
            }
        }).start();
    }
}
