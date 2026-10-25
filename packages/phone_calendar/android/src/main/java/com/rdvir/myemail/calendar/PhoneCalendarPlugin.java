package com.rdvir.myemail.calendar;

import android.Manifest;
import android.app.Activity;
import android.content.ContentProviderOperation;
import android.content.ContentResolver;
import android.content.ContentUris;
import android.content.ContentValues;
import android.content.Context;
import android.content.pm.PackageManager;
import android.database.Cursor;
import android.net.Uri;
import android.os.Handler;
import android.os.Looper;
import android.provider.CalendarContract;
import android.provider.CalendarContract.Calendars;
import android.provider.CalendarContract.Events;
import android.provider.CalendarContract.Reminders;

import androidx.annotation.NonNull;

import java.util.ArrayList;
import java.util.HashMap;
import java.util.HashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.TimeZone;
import java.util.concurrent.Callable;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

import io.flutter.embedding.engine.plugins.FlutterPlugin;
import io.flutter.embedding.engine.plugins.activity.ActivityAware;
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding;
import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.MethodChannel;
import io.flutter.plugin.common.PluginRegistry;

/**
 * The phone's own calendar, written to: a calendar per Microsoft account in
 * Android's calendar provider, filled from Outlook, so Samsung's or Google's
 * calendar app shows its meetings with their reminders and widgets. One
 * way, and read only there: the calendar app does not offer to change what
 * the next pass would put back.
 *
 * Each calendar is a local one (ACCOUNT_TYPE_LOCAL) under the account's
 * address, named "myemail:" and the app's key for it, and written as its
 * sync adapter. An event carries the server's id in _SYNC_ID and a digest of
 * what it says in SYNC_DATA1, so a pass writes only what changed.
 *
 * A plugin rather than a channel on the activity because the background
 * worker's engine has no activity, and Android registers plugins with every
 * engine. The provider is asked off the main thread; the answers go back on
 * it.
 */
public class PhoneCalendarPlugin implements FlutterPlugin, ActivityAware,
        MethodChannel.MethodCallHandler, PluginRegistry.RequestPermissionsResultListener {

    private static final String CHANNEL = "mailtree/phone-calendar";
    private static final String PREFIX = "myemail:";
    private static final int REQUEST_CODE = 4127;
    private static final String[] PERMISSIONS = {
            Manifest.permission.READ_CALENDAR, Manifest.permission.WRITE_CALENDAR,
    };

    /** How many operations go to the provider in one batch. */
    private static final int BATCH = 300;

    private MethodChannel channel;
    private Context context;
    private ActivityPluginBinding activity;
    private MethodChannel.Result pendingPermission;
    private final ExecutorService worker = Executors.newSingleThreadExecutor();
    private final Handler main = new Handler(Looper.getMainLooper());

    @Override
    public void onAttachedToEngine(@NonNull FlutterPluginBinding binding) {
        context = binding.getApplicationContext();
        channel = new MethodChannel(binding.getBinaryMessenger(), CHANNEL);
        channel.setMethodCallHandler(this);
    }

    @Override
    public void onDetachedFromEngine(@NonNull FlutterPluginBinding binding) {
        channel.setMethodCallHandler(null);
        channel = null;
    }

    @Override
    public void onAttachedToActivity(@NonNull ActivityPluginBinding binding) {
        activity = binding;
        binding.addRequestPermissionsResultListener(this);
    }

    @Override
    public void onDetachedFromActivityForConfigChanges() {
        onDetachedFromActivity();
    }

    @Override
    public void onReattachedToActivityForConfigChanges(@NonNull ActivityPluginBinding binding) {
        onAttachedToActivity(binding);
    }

    @Override
    public void onDetachedFromActivity() {
        if (activity != null) activity.removeRequestPermissionsResultListener(this);
        activity = null;
    }

    @Override
    public void onMethodCall(@NonNull MethodCall call, @NonNull MethodChannel.Result result) {
        switch (call.method) {
            case "hasPermission":
                result.success(hasPermission());
                return;
            case "requestPermission":
                requestPermission(result);
                return;
            case "calendars":
                run(result, this::calendars);
                return;
            case "ensureCalendar": {
                final String key = call.argument("key");
                final String account = call.argument("account");
                final String name = call.argument("name");
                final int color = ((Number) call.argument("color")).intValue();
                run(result, () -> ensureCalendar(key, account, name, color));
                return;
            }
            case "sync": {
                final long calendarId = ((Number) call.argument("calendarId")).longValue();
                final String account = call.argument("account");
                final long from = ((Number) call.argument("from")).longValue();
                final List<Map<String, Object>> events = call.argument("events");
                run(result, () -> sync(calendarId, account, from, events));
                return;
            }
            case "remove": {
                final String key = call.argument("key");
                run(result, () -> remove(key));
                return;
            }
            default:
                result.notImplemented();
        }
    }

    /** [work] off the main thread, its answer or failure back on it. */
    private void run(MethodChannel.Result result, Callable<Object> work) {
        worker.execute(() -> {
            try {
                final Object answer = work.call();
                main.post(() -> result.success(answer));
            } catch (SecurityException e) {
                main.post(() -> result.error("no-permission", e.getMessage(), null));
            } catch (Exception e) {
                main.post(() -> result.error("phone-calendar-failed", e.getMessage(), null));
            }
        });
    }

    // --- permission ---------------------------------------------------------------

    private boolean hasPermission() {
        for (String p : PERMISSIONS) {
            if (context.checkSelfPermission(p) != PackageManager.PERMISSION_GRANTED) {
                return false;
            }
        }
        return true;
    }

    /** Android's own dialog; false with no activity to show it on. */
    private void requestPermission(MethodChannel.Result result) {
        if (hasPermission()) {
            result.success(true);
            return;
        }
        Activity shown = activity == null ? null : activity.getActivity();
        if (shown == null) {
            result.success(false);
            return;
        }
        // One at a time: a second ask while the dialog is up would leave the
        // first waiting for an answer that never comes.
        if (pendingPermission != null) pendingPermission.success(false);
        pendingPermission = result;
        shown.requestPermissions(PERMISSIONS, REQUEST_CODE);
    }

    @Override
    public boolean onRequestPermissionsResult(int requestCode, @NonNull String[] permissions,
            @NonNull int[] grantResults) {
        if (requestCode != REQUEST_CODE) return false;
        MethodChannel.Result waiting = pendingPermission;
        pendingPermission = null;
        if (waiting != null) waiting.success(hasPermission());
        return true;
    }

    // --- calendars ------------------------------------------------------------------

    /** As this app's sync adapter for [account]'s local calendar. */
    private static Uri asSyncAdapter(Uri uri, String account) {
        return uri.buildUpon()
                .appendQueryParameter(CalendarContract.CALLER_IS_SYNCADAPTER, "true")
                .appendQueryParameter(Calendars.ACCOUNT_NAME, account)
                .appendQueryParameter(Calendars.ACCOUNT_TYPE, CalendarContract.ACCOUNT_TYPE_LOCAL)
                .build();
    }

    /** The calendars this app made: id, key, account and name each. */
    private List<Map<String, Object>> calendars() {
        List<Map<String, Object>> found = new ArrayList<>();
        try (Cursor c = context.getContentResolver().query(
                Calendars.CONTENT_URI,
                new String[]{Calendars._ID, Calendars.NAME, Calendars.ACCOUNT_NAME,
                        Calendars.CALENDAR_DISPLAY_NAME},
                Calendars.ACCOUNT_TYPE + " = ? AND " + Calendars.NAME + " LIKE ?",
                new String[]{CalendarContract.ACCOUNT_TYPE_LOCAL, PREFIX + "%"},
                null)) {
            while (c != null && c.moveToNext()) {
                Map<String, Object> row = new HashMap<>();
                row.put("id", c.getLong(0));
                row.put("key", c.getString(1).substring(PREFIX.length()));
                row.put("account", c.getString(2));
                row.put("name", c.getString(3));
                found.add(row);
            }
        }
        return found;
    }

    /** [key]'s calendar's row and account, or null. */
    private Object[] find(String key) {
        try (Cursor c = context.getContentResolver().query(
                Calendars.CONTENT_URI,
                new String[]{Calendars._ID, Calendars.ACCOUNT_NAME},
                Calendars.ACCOUNT_TYPE + " = ? AND " + Calendars.NAME + " = ?",
                new String[]{CalendarContract.ACCOUNT_TYPE_LOCAL, PREFIX + key},
                null)) {
            if (c != null && c.moveToFirst()) return new Object[]{c.getLong(0), c.getString(1)};
        }
        return null;
    }

    /** [key]'s calendar, made if it is not there, named and coloured as given. */
    private long ensureCalendar(String key, String account, String name, int color) {
        ContentResolver resolver = context.getContentResolver();
        ContentValues values = new ContentValues();
        values.put(Calendars.CALENDAR_DISPLAY_NAME, name);
        values.put(Calendars.CALENDAR_COLOR, color);
        Object[] here = find(key);
        if (here != null) {
            long id = (Long) here[0];
            resolver.update(
                    asSyncAdapter(ContentUris.withAppendedId(Calendars.CONTENT_URI, id),
                            (String) here[1]),
                    values, null, null);
            return id;
        }
        values.put(Calendars.ACCOUNT_NAME, account);
        values.put(Calendars.ACCOUNT_TYPE, CalendarContract.ACCOUNT_TYPE_LOCAL);
        values.put(Calendars.NAME, PREFIX + key);
        values.put(Calendars.OWNER_ACCOUNT, account);
        values.put(Calendars.CALENDAR_ACCESS_LEVEL, Calendars.CAL_ACCESS_READ);
        values.put(Calendars.VISIBLE, 1);
        values.put(Calendars.SYNC_EVENTS, 1);
        values.put(Calendars.CALENDAR_TIME_ZONE, TimeZone.getDefault().getID());
        Uri made = resolver.insert(asSyncAdapter(Calendars.CONTENT_URI, account), values);
        if (made == null) throw new IllegalStateException("The calendar was not made");
        return ContentUris.parseId(made);
    }

    /** [key]'s calendar gone, and its events with it. */
    private boolean remove(String key) {
        Object[] here = find(key);
        if (here == null) return false;
        context.getContentResolver().delete(
                asSyncAdapter(ContentUris.withAppendedId(Calendars.CONTENT_URI, (Long) here[0]),
                        (String) here[1]),
                null, null);
        return true;
    }

    // --- events ----------------------------------------------------------------------

    /**
     * [events] into [calendarId]: new ones added, changed ones rewritten,
     * and ones starting from [from] on that are no longer there deleted.
     * Earlier ones stay, as they were. Answers how many of each.
     */
    private Map<String, Object> sync(long calendarId, String account, long from,
            List<Map<String, Object>> events) throws Exception {
        ContentResolver resolver = context.getContentResolver();
        Map<String, long[]> rows = new HashMap<>();
        Map<String, String> digests = new HashMap<>();
        try (Cursor c = resolver.query(
                Events.CONTENT_URI,
                new String[]{Events._ID, Events._SYNC_ID, Events.SYNC_DATA1, Events.DTSTART},
                Events.CALENDAR_ID + " = ?",
                new String[]{String.valueOf(calendarId)},
                null)) {
            while (c != null && c.moveToNext()) {
                String id = c.getString(1);
                if (id == null) continue;
                rows.put(id, new long[]{c.getLong(0), c.getLong(3)});
                digests.put(id, c.getString(2));
            }
        }

        Uri eventsUri = asSyncAdapter(Events.CONTENT_URI, account);
        Uri remindersUri = asSyncAdapter(Reminders.CONTENT_URI, account);
        ArrayList<ContentProviderOperation> ops = new ArrayList<>();
        Set<String> seen = new HashSet<>();
        int added = 0, changed = 0, removed = 0;
        for (Map<String, Object> e : events) {
            String id = (String) e.get("id");
            String digest = (String) e.get("digest");
            seen.add(id);
            long[] here = rows.get(id);
            if (here != null && digest != null && digest.equals(digests.get(id))) continue;
            ContentValues values = eventValues(calendarId, e);
            Object minutes = e.get("reminder");
            if (here == null) {
                int index = ops.size();
                ops.add(ContentProviderOperation.newInsert(eventsUri).withValues(values).build());
                if (minutes != null) {
                    ops.add(ContentProviderOperation.newInsert(remindersUri)
                            .withValueBackReference(Reminders.EVENT_ID, index)
                            .withValue(Reminders.MINUTES, ((Number) minutes).intValue())
                            .withValue(Reminders.METHOD, Reminders.METHOD_ALERT)
                            .build());
                }
                added++;
            } else {
                long row = here[0];
                ops.add(ContentProviderOperation
                        .newUpdate(ContentUris.withAppendedId(eventsUri, row))
                        .withValues(values)
                        .build());
                ops.add(ContentProviderOperation.newDelete(remindersUri)
                        .withSelection(Reminders.EVENT_ID + " = ?",
                                new String[]{String.valueOf(row)})
                        .build());
                if (minutes != null) {
                    ops.add(ContentProviderOperation.newInsert(remindersUri)
                            .withValue(Reminders.EVENT_ID, row)
                            .withValue(Reminders.MINUTES, ((Number) minutes).intValue())
                            .withValue(Reminders.METHOD, Reminders.METHOD_ALERT)
                            .build());
                }
                changed++;
            }
            // Whole events to a batch: a reminder's back reference counts
            // within its own.
            if (ops.size() >= BATCH) {
                resolver.applyBatch(CalendarContract.AUTHORITY, ops);
                ops.clear();
            }
        }
        for (Map.Entry<String, long[]> row : rows.entrySet()) {
            if (seen.contains(row.getKey()) || row.getValue()[1] < from) continue;
            ops.add(ContentProviderOperation
                    .newDelete(ContentUris.withAppendedId(eventsUri, row.getValue()[0]))
                    .build());
            removed++;
            if (ops.size() >= BATCH) {
                resolver.applyBatch(CalendarContract.AUTHORITY, ops);
                ops.clear();
            }
        }
        if (!ops.isEmpty()) resolver.applyBatch(CalendarContract.AUTHORITY, ops);

        Map<String, Object> answer = new HashMap<>();
        answer.put("added", added);
        answer.put("changed", changed);
        answer.put("removed", removed);
        return answer;
    }

    private static ContentValues eventValues(long calendarId, Map<String, Object> e) {
        boolean allDay = Boolean.TRUE.equals(e.get("allDay"));
        ContentValues v = new ContentValues();
        v.put(Events.CALENDAR_ID, calendarId);
        v.put(Events._SYNC_ID, (String) e.get("id"));
        v.put(Events.SYNC_DATA1, (String) e.get("digest"));
        v.put(Events.TITLE, (String) e.get("title"));
        v.put(Events.DTSTART, ((Number) e.get("start")).longValue());
        v.put(Events.DTEND, ((Number) e.get("end")).longValue());
        v.put(Events.ALL_DAY, allDay ? 1 : 0);
        // An all-day event is midnight to midnight in UTC, as the provider
        // wants it; a timed one shows in whatever zone the phone is in.
        v.put(Events.EVENT_TIMEZONE, allDay ? "UTC" : TimeZone.getDefault().getID());
        v.put(Events.EVENT_LOCATION, (String) e.get("location"));
        v.put(Events.DESCRIPTION, (String) e.get("description"));
        v.put(Events.ORGANIZER, (String) e.get("organizer"));
        Object availability = e.get("availability");
        v.put(Events.AVAILABILITY,
                availability == null ? Events.AVAILABILITY_BUSY : ((Number) availability).intValue());
        v.put(Events.STATUS, Boolean.TRUE.equals(e.get("tentative"))
                ? Events.STATUS_TENTATIVE
                : Events.STATUS_CONFIRMED);
        v.put(Events.HAS_ALARM, e.get("reminder") == null ? 0 : 1);
        return v;
    }
}
