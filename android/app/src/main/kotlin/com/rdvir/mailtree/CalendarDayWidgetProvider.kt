package com.rdvir.mailtree

import android.appwidget.AppWidgetManager
import android.content.ComponentName
import android.content.Context
import android.content.SharedPreferences
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.drawable.AdaptiveIconDrawable
import android.graphics.drawable.ColorDrawable
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.util.TypedValue
import android.view.View
import android.widget.RemoteViews
import es.antonborri.home_widget.HomeWidgetLaunchIntent
import es.antonborri.home_widget.HomeWidgetPlugin
import es.antonborri.home_widget.HomeWidgetProvider
import org.json.JSONArray
import java.util.Calendar

/**
 * The calendar as an app icon (calendar idea #87): the weekday and the day
 * of the month on a tile, and a badge for how many meetings are still to
 * come today, the size and shape of the mailbox widget, so the two sit side
 * by side as a pair. A tap anywhere opens the calendar on today, by the
 * link the calendar widget's date uses.
 *
 * The date is Android's own clock text (TextClock in its layout), which
 * turns over at midnight with nothing of MyEmail's running. The count is
 * worked out here as it is drawn, from the meetings CalendarUpkeep wrote
 * for the calendar widget (calendar.widget.meetings), which are already
 * only those on the calendars shown and none cancelled: today's timed
 * ones, not declined, that have not ended. It is drawn whenever the
 * calendar widget is: when the app writes the meetings, and on Android's
 * half hour for the calendar widget (CalendarWidgetProvider calls
 * [drawAll]); and on a half hour of its own, as the calendar widget has
 * (calendar_day_widget_info.xml), for when it is on the home screen alone.
 *
 * And as the other two, nothing in here may throw: a widget provider is a
 * receiver in the app's own process, and an exception here is MyEmail
 * crashing each time the launcher asks for a redraw.
 */
class CalendarDayWidgetProvider : HomeWidgetProvider() {

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

    /** Moved, or the tablet turned: drawn at the cell's new size. */
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
            // Everything, as the other two do: whatever is wrong with what
            // was written, the app has to keep running.
            android.util.Log.e("MyEmail", "calendar icon widget $widgetId did not draw", e)
        }
    }

    private fun draw(
        context: Context,
        appWidgetManager: AppWidgetManager,
        widgetId: Int,
        widgetData: SharedPreferences,
    ) {
        val left = leftToday(widgetData, System.currentTimeMillis())
        val views = RemoteViews(context.packageName, R.layout.calendar_day_widget).apply {
            // The mailbox widget's size, worked out by its own sum, so the
            // two are the same size side by side.
            val options = appWidgetManager.getAppWidgetOptions(widgetId)
            val icon = MailboxCountWidgetProvider().iconDpFor(context, options) ?: 56f
            paintTile(context, icon)
            sizeTo(context, icon)

            // Anywhere on it: the calendar, on today.
            setOnClickPendingIntent(
                R.id.calendar_day_widget_root,
                HomeWidgetLaunchIntent.getActivity(
                    context,
                    MainActivity::class.java,
                    Uri.parse("myemail://calendar"),
                ),
            )

            // None left is no badge at all, rather than a nought.
            if (left > 0) {
                setViewVisibility(R.id.calendar_day_widget_count, View.VISIBLE)
                setTextViewText(
                    R.id.calendar_day_widget_count,
                    if (left > 99) "99+" else left.toString(),
                )
                setContentDescription(
                    R.id.calendar_day_widget_count,
                    context.resources.getQuantityString(
                        R.plurals.calendar_day_widget_left,
                        left,
                        left,
                    ),
                )
            } else {
                setViewVisibility(R.id.calendar_day_widget_count, View.GONE)
            }
        }
        appWidgetManager.updateAppWidget(widgetId, views)
    }

    /**
     * How many of the meetings CalendarUpkeep wrote are today's, timed (not
     * lasting a day or more), not declined, and not over by [now]. Nought where it wrote nothing yet.
     * What it wrote runs to the end of tomorrow, so after midnight the new
     * day's are there before the app has run.
     */
    private fun leftToday(data: SharedPreferences, now: Long): Int {
        val text = data.getString(KEY, null) ?: return 0
        val array = try {
            JSONArray(text)
        } catch (e: Exception) {
            return 0
        }
        val tomorrow = dayStart(now, 1)
        var left = 0
        for (i in 0 until array.length()) {
            val o = array.optJSONObject(i) ?: continue
            // Whole days, meetings of a day or more, and those declined are
            // not meetings still to come.
            if (o.optBoolean("a", false) ||
                o.optBoolean("m", false) ||
                o.optBoolean("d", false)
            ) {
                continue
            }
            if (o.optLong("e", 0) > now && o.optLong("s", 0) < tomorrow) left++
        }
        return left
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
     * The tile as the launcher draws an app icon: plain white, cut to the
     * system's icon shape by AdaptiveIconDrawable, at [icon] dp, as the
     * mailbox widget paints its own. A bitmap, which RemoteViews can carry
     * and a drawable built here it cannot.
     */
    private fun RemoteViews.paintTile(context: Context, icon: Float) {
        val px = (icon * context.resources.displayMetrics.density).toInt()
        val bitmap = Bitmap.createBitmap(px, px, Bitmap.Config.ARGB_8888)
        AdaptiveIconDrawable(ColorDrawable(TILE), ColorDrawable(Color.TRANSPARENT)).apply {
            setBounds(0, 0, px, px)
            draw(Canvas(bitmap))
        }
        setImageViewBitmap(R.id.calendar_day_widget_tile, bitmap)
    }

    /**
     * The tile and its face at [icon] dp, and the text to match: the date
     * in dp, a picture on the tile that a larger font in Android's settings
     * must not push off it; the badge and the name as the mailbox widget
     * sizes its total and its name, in sp.
     *
     * API 31 and up, as there. Below that the layout's sizes stand.
     */
    private fun RemoteViews.sizeTo(context: Context, icon: Float) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) return
        for (id in intArrayOf(R.id.calendar_day_widget_tile, R.id.calendar_day_widget_face)) {
            setViewLayoutWidth(id, icon, TypedValue.COMPLEX_UNIT_DIP)
            setViewLayoutHeight(id, icon, TypedValue.COMPLEX_UNIT_DIP)
        }
        // The weekday near the top and the day under it, clear of the
        // badge in the bottom corner.
        val density = context.resources.displayMetrics.density
        setViewPadding(R.id.calendar_day_widget_face, 0, (icon * 0.08f * density).toInt(), 0, 0)
        setTextViewTextSize(
            R.id.calendar_day_widget_weekday,
            TypedValue.COMPLEX_UNIT_DIP,
            icon * 0.19f,
        )
        setTextViewTextSize(R.id.calendar_day_widget_day, TypedValue.COMPLEX_UNIT_DIP, icon * 0.40f)

        val count = (icon * 0.26f).coerceIn(17f, 26f)
        setViewLayoutHeight(R.id.calendar_day_widget_count, count, TypedValue.COMPLEX_UNIT_DIP)
        setTextViewTextSize(
            R.id.calendar_day_widget_count,
            TypedValue.COMPLEX_UNIT_SP,
            count * 0.58f,
        )
        setTextViewTextSize(
            R.id.calendar_day_widget_name,
            TypedValue.COMPLEX_UNIT_SP,
            (icon * 0.23f).coerceIn(11f, 15f),
        )
    }

    companion object {
        /** Where CalendarUpkeep writes the meetings; CalendarWidgetProvider
         *  reads them from there too. */
        private const val KEY = "calendar.widget.meetings"

        /** The tile: white, as a calendar's page, on any home screen. */
        private const val TILE = 0xFFFFFFFF.toInt()

        /**
         * Draw every one placed, from what home_widget keeps: called by
         * CalendarWidgetProvider each time it draws. Never throws.
         */
        fun drawAll(context: Context) {
            try {
                val manager = AppWidgetManager.getInstance(context)
                val ids = manager.getAppWidgetIds(
                    ComponentName(context, CalendarDayWidgetProvider::class.java),
                )
                if (ids.isEmpty()) return
                CalendarDayWidgetProvider().onUpdate(
                    context,
                    manager,
                    ids,
                    HomeWidgetPlugin.getData(context),
                )
            } catch (e: Exception) {
                android.util.Log.e("MyEmail", "calendar icon widgets not drawn", e)
            }
        }
    }
}
