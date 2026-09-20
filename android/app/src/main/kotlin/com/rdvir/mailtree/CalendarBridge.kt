package com.rdvir.mailtree

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.Intent
import android.provider.CalendarContract
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

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
