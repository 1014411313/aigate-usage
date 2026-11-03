package com.hyperos.xj.hook;

import android.app.Activity;
import android.app.Application;
import android.content.Context;
import android.os.Bundle;

import com.hyperos.xj.CardOverlay;

import de.robv.android.xposed.IXposedHookLoadPackage;
import de.robv.android.xposed.XC_MethodHook;
import de.robv.android.xposed.XposedBridge;
import de.robv.android.xposed.XposedHelpers;
import de.robv.android.xposed.callbacks.XC_LoadPackage;

public final class HookEntry implements IXposedHookLoadPackage {
    private static final String TARGET_PACKAGE = "com.xiaomi.subscreencenter";
    private static final String TARGET_ACTIVITY = "com.xiaomi.subscreencenter.SubScreenLauncher";
    private static boolean hookInstalled;
    private static boolean callbacksInstalled;

    @Override public void handleLoadPackage(XC_LoadPackage.LoadPackageParam load) {
        if (!TARGET_PACKAGE.equals(load.packageName) || !TARGET_PACKAGE.equals(load.processName)) return;
        synchronized (HookEntry.class) {
            if (hookInstalled) return;
            try {
                XposedHelpers.findAndHookMethod(Application.class, "attach", Context.class, new XC_MethodHook() {
                    @Override protected void afterHookedMethod(MethodHookParam param) {
                        if (!(param.thisObject instanceof Application)) return;
                        Application application = (Application) param.thisObject;
                        try {
                            if (!TARGET_PACKAGE.equals(application.getPackageName())) return;
                            synchronized (HookEntry.class) {
                                if (callbacksInstalled) return;
                                application.registerActivityLifecycleCallbacks(new Application.ActivityLifecycleCallbacks() {
                                    @Override public void onActivityCreated(Activity a, Bundle b) { }
                                    @Override public void onActivityStarted(Activity a) { }
                                    @Override public void onActivityResumed(Activity a) { update(a, true); }
                                    @Override public void onActivityPaused(Activity a) { update(a, false); }
                                    @Override public void onActivityStopped(Activity a) { update(a, false); }
                                    @Override public void onActivitySaveInstanceState(Activity a, Bundle b) { }
                                    @Override public void onActivityDestroyed(Activity a) { update(a, false); }
                                });
                                callbacksInstalled = true;
                            }
                        } catch (Throwable error) {
                            logFailure("lifecycle registration", error);
                        }
                    }
                });
                hookInstalled = true;
            } catch (Throwable error) {
                logFailure("host hook registration", error);
            }
        }
    }

    private static void update(Activity activity, boolean resumed) {
        if (activity == null || !TARGET_ACTIVITY.equals(activity.getClass().getName())) return;
        try {
            if (resumed) CardOverlay.attach(activity);
            else CardOverlay.detach(activity);
        } catch (Throwable error) {
            logFailure("card lifecycle", error);
        }
    }

    private static void logFailure(String stage, Throwable error) {
        try {
            XposedBridge.log("HyperOS_XJ: " + stage + " failed: " + error.getClass().getSimpleName());
        } catch (Throwable ignored) {
        }
    }
}
