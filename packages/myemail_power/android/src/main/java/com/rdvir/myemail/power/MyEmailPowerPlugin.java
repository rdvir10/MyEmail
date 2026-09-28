package com.rdvir.myemail.power;

import android.app.Activity;
import android.app.ActivityManager;
import android.content.ActivityNotFoundException;
import android.content.Context;
import android.content.Intent;
import android.net.Uri;
import android.os.PowerManager;
import android.provider.Settings;

import androidx.annotation.NonNull;

import java.util.List;

import io.flutter.embedding.engine.plugins.FlutterPlugin;
import io.flutter.embedding.engine.plugins.activity.ActivityAware;
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding;
import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.MethodChannel;

/**
 * Staying alive in the background, which is Android's decision and not ours.
 *
 * A plugin rather than a channel on the activity because the question that
 * matters most is asked from the background worker's engine, which has no
 * activity: Android registers plugins with every engine, and an activity's
 * channels only with the app's.
 */
public class MyEmailPowerPlugin implements FlutterPlugin, ActivityAware,
        MethodChannel.MethodCallHandler {

    private MethodChannel channel;
    private Context context;
    private Activity activity;

    @Override
    public void onAttachedToEngine(@NonNull FlutterPluginBinding binding) {
        context = binding.getApplicationContext();
        channel = new MethodChannel(binding.getBinaryMessenger(), "myemail/power");
        channel.setMethodCallHandler(this);
    }

    @Override
    public void onDetachedFromEngine(@NonNull FlutterPluginBinding binding) {
        channel.setMethodCallHandler(null);
        channel = null;
        context = null;
    }

    @Override
    public void onAttachedToActivity(@NonNull ActivityPluginBinding binding) {
        activity = binding.getActivity();
    }

    @Override
    public void onDetachedFromActivityForConfigChanges() {
        activity = null;
    }

    @Override
    public void onReattachedToActivityForConfigChanges(@NonNull ActivityPluginBinding binding) {
        activity = binding.getActivity();
    }

    @Override
    public void onDetachedFromActivity() {
        activity = null;
    }

    @Override
    public void onMethodCall(@NonNull MethodCall call, @NonNull MethodChannel.Result result) {
        switch (call.method) {
            case "isIgnoringBatteryOptimizations":
                result.success(isIgnoringBatteryOptimizations());
                break;
            case "requestIgnoreBatteryOptimizations":
                result.success(requestIgnoreBatteryOptimizations());
                break;
            case "foregroundServiceRunning":
                result.success(foregroundServiceRunning());
                break;
            default:
                result.notImplemented();
        }
    }

    /** Whether Android lists the app as "Unrestricted" for battery. */
    private boolean isIgnoringBatteryOptimizations() {
        PowerManager power = (PowerManager) context.getSystemService(Context.POWER_SERVICE);
        return power != null && power.isIgnoringBatteryOptimizations(context.getPackageName());
    }

    /**
     * Android's own yes-or-no dialog, falling back to the list of apps where
     * the dialog is missing (some manufacturers remove it). False when
     * neither could be shown.
     */
    private boolean requestIgnoreBatteryOptimizations() {
        if (isIgnoringBatteryOptimizations()) return true;
        Context from = activity != null ? activity : context;
        Intent ask = new Intent(
                Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS,
                Uri.parse("package:" + context.getPackageName()));
        Intent list = new Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS);
        if (activity == null) {
            ask.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
            list.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
        }
        try {
            from.startActivity(ask);
            return true;
        } catch (ActivityNotFoundException | SecurityException e) {
            try {
                from.startActivity(list);
                return true;
            } catch (ActivityNotFoundException | SecurityException e2) {
                return false;
            }
        }
    }

    /**
     * Whether one of the app's own services is running in the foreground.
     *
     * The only honest answer to "is push really running". WorkManager treats
     * a worker it asked to promote as foreground work whether or not Android
     * agreed, and then ignores Android's stop, so a worker whose service was
     * refused carries on with no service and no job: frozen on a Pixel,
     * spinning on a Samsung. getRunningServices is closed to other apps'
     * services, but still reports the caller's own.
     */
    @SuppressWarnings("deprecation")
    private boolean foregroundServiceRunning() {
        ActivityManager manager =
                (ActivityManager) context.getSystemService(Context.ACTIVITY_SERVICE);
        if (manager == null) return false;
        List<ActivityManager.RunningServiceInfo> services =
                manager.getRunningServices(Integer.MAX_VALUE);
        if (services == null) return false;
        String self = context.getPackageName();
        for (ActivityManager.RunningServiceInfo service : services) {
            if (service.foreground && self.equals(service.service.getPackageName())) {
                return true;
            }
        }
        return false;
    }
}
