package com.rdvir.mailtree

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.Intent
import android.provider.CalendarContract
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.TimeZone

/**
 * Handing an event to the device's calendar.
 *
 * Through the calendar app's own "new event" screen (ACTION_INSERT), with
 * the fields filled in, rather than writing to the calendar provider:
 * the person sees what is about to be kept, picks which calendar, and
 * can change anything before saving. No calendar permission is needed,
 * and none is asked for.
 */
class CalendarBridge(
    private val activity: Activity,
    messenger: BinaryMessenger,
) : MethodChannel.MethodCallHandler {

    init {
        MethodChannel(messenger, CHANNEL).setMethodCallHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "available" -> result.success(true)
                // The zone by its IANA name, which is what a calendar server
                // is told a meeting's time is in. Dart has the offset and the
                // abbreviation, and neither names the zone.
                "timeZone" -> result.success(TimeZone.getDefault().id)
                "insert" -> {
                    val intent = Intent(Intent.ACTION_INSERT).apply {
                        data = CalendarContract.Events.CONTENT_URI
                        putExtra(CalendarContract.Events.TITLE, call.argument<String>("title") ?: "")
                        call.argument<String>("description")?.let {
                            putExtra(CalendarContract.Events.DESCRIPTION, it)
                        }
                        call.argument<String>("location")?.let {
                            putExtra(CalendarContract.Events.EVENT_LOCATION, it)
                        }
                        call.argument<Number>("start")?.let {
                            putExtra(CalendarContract.EXTRA_EVENT_BEGIN_TIME, it.toLong())
                        }
                        call.argument<Number>("end")?.let {
                            putExtra(CalendarContract.EXTRA_EVENT_END_TIME, it.toLong())
                        }
                        putExtra(
                            CalendarContract.EXTRA_EVENT_ALL_DAY,
                            call.argument<Boolean>("allDay") ?: false,
                        )
                        // The attendees, whom the calendar app invites once
                        // the event is saved. One string with commas between,
                        // which is how ACTION_INSERT documents this extra and
                        // what the calendar app's new-event screen splits; the
                        // array a share sheet puts under the same key is read
                        // there as nobody.
                        call.argument<List<String>>("attendees")?.let {
                            if (it.isNotEmpty()) putExtra(Intent.EXTRA_EMAIL, it.joinToString(","))
                        }
                    }
                    try {
                        activity.startActivity(intent)
                        result.success(true)
                    } catch (e: ActivityNotFoundException) {
                        result.success(false)
                    }
                }
                else -> result.notImplemented()
            }
        } catch (e: Exception) {
            result.error("calendar", e.message, null)
        }
    }

    companion object {
        const val CHANNEL = "mailtree/calendar"
    }
}
