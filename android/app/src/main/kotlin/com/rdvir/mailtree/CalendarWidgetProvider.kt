package com.rdvir.mailtree

import android.app.ActivityOptions
import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
import android.content.res.Configuration
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.text.format.DateFormat
import android.view.View
import android.widget.RemoteViews
import es.antonborri.home_widget.HomeWidgetLaunchIntent
import es.antonborri.home_widget.HomeWidgetPlugin
import es.antonborri.home_widget.HomeWidgetProvider
import org.json.JSONArray
import java.util.Calendar
import java.util.Date

/**
 * The calendar widget: today's and tomorrow's meetings, from every
 * account, each in its account's colour. A meeting tapped opens in
 * MyEmail; Join opens its link in Teams, Meet or Zoom; the date opens the
 * calendar.
 *
 * Like the mailbox widget, it shows only what the Dart side wrote down:
 * here calendar.widget.meetings, written by CalendarUpkeep from the
 * background passes and the app, every quarter of an hour at most. What it
 * works out for itself is the time. A meeting that is over is left off,
 * and "Today" is today, whenever Android asks for a drawing: every half
 * hour at least (calendar_widget_info.xml), so it stays right between
 * MyEmail's writes.
 *
 * And as there, nothing in here may throw: a widget provider is a
 * receiver in the app's own process, and an exception here is MyEmail
 * crashing each time the launcher asks for a redraw.
 */
class CalendarWidgetProvider : HomeWidgetProvider() {

    override fun onUpdate(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetIds: IntArray,
        widgetData: SharedPreferences,
    ) {
        appWidgetIds.forEach { widgetId ->
            drawSafely(context, appWidgetManager, widgetId, widgetData)
        }
    }

    /** Resized: as many meetings as fit now. */
    override fun onAppWidgetOptionsChanged(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetId: Int,
        newOptions: Bundle,
    ) {
        super.onAppWidgetOptionsChanged(context, appWidgetManager, appWidgetId, newOptions)
        drawSafely(context, appWidgetManager, appWidgetId, HomeWidgetPlugin.getData(context))
    }

    private fun drawSafely(
        context: Context,
        appWidgetManager: AppWidgetManager,
        widgetId: Int,
        widgetData: SharedPreferences,
    ) {
        try {
            draw(context, appWidgetManager, widgetId, widgetData)
        } catch (e: Exception) {
            // Everything, as the mailbox widget does: whatever is wrong
            // with what was written, the app has to keep running.
            android.util.Log.e("MyEmail", "calendar widget $widgetId did not draw", e)
        }
    }

    private class Meeting(
        val title: String,
        val start: Long,
        val end: Long,
        val allDay: Boolean,
        val declined: Boolean,
        val colour: Int,
        val where: String?,
        val join: String?,
        val link: String?,
    )

    /** What CalendarUpkeep wrote, or nothing where it wrote nothing yet. */
    private fun meetings(data: SharedPreferences): List<Meeting> {
        val text = data.getString(KEY, null) ?: return emptyList()
        val array = try {
            JSONArray(text)
        } catch (e: Exception) {
            return emptyList()
        }
        val found = ArrayList<Meeting>()
        for (i in 0 until array.length()) {
            val o = array.optJSONObject(i) ?: continue
            found.add(
                Meeting(
                    title = o.optString("t", ""),
                    start = o.optLong("s", 0),
                    end = o.optLong("e", 0),
                    allDay = o.optBoolean("a", false),
                    declined = o.optBoolean("d", false),
                    colour = o.optLong("c", DEFAULT_COLOUR.toLong()).toInt(),
                    where = o.optString("w", "").ifEmpty { null },
                    join = o.optString("j", "").ifEmpty { null },
                    link = o.optString("l", "").ifEmpty { null },
                ),
            )
        }
        return found
    }

    private fun draw(
        context: Context,
        appWidgetManager: AppWidgetManager,
        widgetId: Int,
        widgetData: SharedPreferences,
    ) {
        val now = System.currentTimeMillis()
        val today = dayStart(now, 0)
        val tomorrow = dayStart(now, 1)
        val dayAfter = dayStart(now, 2)
        val views = RemoteViews(context.packageName, R.layout.calendar_widget)
        views.setTextViewText(
            R.id.calendar_widget_date,
            DateFormat.format("EEEE d MMMM", Date(today)),
        )
        views.setOnClickPendingIntent(
            R.id.calendar_widget_header,
            HomeWidgetLaunchIntent.getActivity(
                context,
                MainActivity::class.java,
                Uri.parse("myemail://calendar"),
            ),
        )
        views.removeAllViews(R.id.calendar_widget_list)

        val shown = meetings(widgetData).filter { it.end > now && it.start < dayAfter }
        var room = roomDp(context, appWidgetManager.getAppWidgetOptions(widgetId))
        if (shown.isEmpty()) {
            views.addView(R.id.calendar_widget_list, line(context, R.string.calendar_widget_nothing))
        }
        var day = today
        for ((i, m) in shown.withIndex()) {
            val its = if (m.start < tomorrow) today else tomorrow
            if (its != day) {
                if (room < LINE_DP + ROW_DP) break
                // Tomorrow's first: today has nothing more, and says so.
                if (i == 0) {
                    views.addView(
                        R.id.calendar_widget_list,
                        line(context, R.string.calendar_widget_nothing_more),
                    )
                    room -= LINE_DP
                }
                views.addView(R.id.calendar_widget_list, line(context, R.string.calendar_widget_tomorrow))
                room -= LINE_DP
                day = its
            }
            if (room < ROW_DP) break
            views.addView(R.id.calendar_widget_list, row(context, m, now, its == today))
            room -= ROW_DP
        }
        appWidgetManager.updateAppWidget(widgetId, views)
    }

    private fun line(context: Context, text: Int): RemoteViews =
        RemoteViews(context.packageName, R.layout.calendar_widget_day).apply {
            setTextViewText(R.id.calendar_day_text, context.getString(text))
        }

    private fun row(context: Context, m: Meeting, now: Long, today: Boolean): RemoteViews =
        RemoteViews(context.packageName, R.layout.calendar_widget_row).apply {
            setInt(R.id.calendar_row_colour, "setColorFilter", m.colour)
            setTextViewText(R.id.calendar_row_title, m.title)
            val clock = DateFormat.getTimeFormat(context)
            val time = if (m.allDay) {
                context.getString(R.string.calendar_widget_all_day)
            } else {
                "${clock.format(Date(m.start))}–${clock.format(Date(m.end))}"
            }
            setTextViewText(
                R.id.calendar_row_when,
                listOfNotNull(
                    if (m.declined) context.getString(R.string.calendar_widget_declined) else null,
                    time,
                    m.where,
                ).joinToString(" · "),
            )
            m.link?.let {
                setOnClickPendingIntent(
                    R.id.calendar_row_root,
                    HomeWidgetLaunchIntent.getActivity(context, MainActivity::class.java, Uri.parse(it)),
                )
            }
            // Join on today's, from the app the link belongs to.
            val join = m.join
            if (join != null && today && !m.allDay && m.end > now) {
                setViewVisibility(R.id.calendar_row_join, View.VISIBLE)
                setOnClickPendingIntent(R.id.calendar_row_join, openLink(context, join))
            } else {
                setViewVisibility(R.id.calendar_row_join, View.GONE)
            }
        }

    /** [url] opened by whichever app takes it, as the home screen may. */
    private fun openLink(context: Context, url: String): PendingIntent {
        val intent = Intent(Intent.ACTION_VIEW, Uri.parse(url))
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        val flags = PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        if (Build.VERSION.SDK_INT < 34) {
            return PendingIntent.getActivity(context, 0, intent, flags)
        }
        val options = ActivityOptions.makeBasic()
        if (Build.VERSION.SDK_INT >= 35) {
            options.setPendingIntentCreatorBackgroundActivityStartMode(
                ActivityOptions.MODE_BACKGROUND_ACTIVITY_START_ALLOWED,
            )
        } else {
            @Suppress("DEPRECATION")
            options.pendingIntentBackgroundActivityStartMode =
                ActivityOptions.MODE_BACKGROUND_ACTIVITY_START_ALLOWED
        }
        return PendingIntent.getActivity(context, 0, intent, flags, options.toBundle())
    }

    /** Midnight [days] after the one before [now], on the phone's clock. */
    private fun dayStart(now: Long, days: Int): Long =
        Calendar.getInstance().apply {
            timeInMillis = now
            set(Calendar.HOUR_OF_DAY, 0)
            set(Calendar.MINUTE, 0)
            set(Calendar.SECOND, 0)
            set(Calendar.MILLISECOND, 0)
            add(Calendar.DAY_OF_MONTH, days)
        }.timeInMillis

    /**
     * The height there is for meetings, in dp: the widget's, less its
     * padding and the date across the top. MIN and MAX swap with the
     * orientation, as MailboxCountWidgetProvider explains.
     */
    private fun roomDp(context: Context, options: Bundle): Int {
        val portrait = context.resources.configuration.orientation ==
            Configuration.ORIENTATION_PORTRAIT
        val height = options.getInt(
            if (portrait) AppWidgetManager.OPTION_APPWIDGET_MAX_HEIGHT
            else AppWidgetManager.OPTION_APPWIDGET_MIN_HEIGHT,
            0,
        )
        val tall = if (height > 0) height else 110
        return tall - 20 - 32
    }

    private companion object {
        const val KEY = "calendar.widget.meetings"
        const val ROW_DP = 40
        const val LINE_DP = 24
        /** The app's own orange, for a meeting whose account has gone. */
        const val DEFAULT_COLOUR = 0xFFFF7A18.toInt()
    }
}
