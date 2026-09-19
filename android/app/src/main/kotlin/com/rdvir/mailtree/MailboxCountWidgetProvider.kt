package com.rdvir.mailtree

import android.appwidget.AppWidgetManager
import android.content.Context
import android.content.SharedPreferences
import android.net.Uri
import android.view.View
import android.widget.RemoteViews
import es.antonborri.home_widget.HomeWidgetLaunchIntent
import es.antonborri.home_widget.HomeWidgetProvider

/**
 * The home-screen widget: one mailbox, two numbers.
 *
 * It draws nothing of its own. Every value it shows was written by the Dart
 * side — by the app when it is open, and by the background sync pass when it
 * is not — because a home-screen widget is redrawn at times the app has no
 * say over, including while it is not running at all.
 *
 * Each placed widget has its own mailbox, chosen when it was dropped on the
 * home screen, so the folder is looked up per widget id and everything else
 * follows from that.
 *
 * One rule governs everything below: nothing in here may throw. A widget
 * provider is a receiver in the app's own process, so an exception here is
 * not a widget that fails to draw — it is MyEmail crashing, over and over,
 * every time the launcher asks for a redraw. That has happened once. A
 * widget showing yesterday's numbers is always the better failure.
 */
class MailboxCountWidgetProvider : HomeWidgetProvider() {

    override fun onUpdate(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetIds: IntArray,
        widgetData: SharedPreferences,
    ) {
        appWidgetIds.forEach { widgetId ->
            try {
                draw(context, appWidgetManager, widgetId, widgetData)
            } catch (e: Exception) {
                // Deliberately everything. Whatever is wrong with one
                // widget's stored values, the app has to keep running.
                android.util.Log.e("MyEmail", "widget $widgetId did not draw", e)
            }
        }
    }

    private fun draw(
        context: Context,
        appWidgetManager: AppWidgetManager,
        widgetId: Int,
        widgetData: SharedPreferences,
    ) {
        val folderId = widgetData.getString("widget.$widgetId.folder", null)
        val views = RemoteViews(context.packageName, R.layout.mailbox_count_widget).apply {
            // Tapping opens the folder this widget is counting, not just
            // the app. Two widgets on two folders get two intents: the
            // data differs, which is what makes them tell apart.
            setOnClickPendingIntent(
                R.id.mailbox_widget_root,
                HomeWidgetLaunchIntent.getActivity(
                    context,
                    MainActivity::class.java,
                    folderId?.let {
                        Uri.Builder()
                            .scheme("myemail")
                            .authority("folder")
                            .appendQueryParameter("id", it)
                            .build()
                    },
                ),
            )

            setInt(
                R.id.mailbox_widget_tile,
                "setColorFilter",
                number(widgetData, "widget.$widgetId.colour", DEFAULT_COLOUR),
            )

            if (folderId == null) {
                // Placed but never set up, or the mailbox it was showing
                // has gone. Either way the honest thing is to say so
                // rather than show a confident zero.
                setTextViewText(R.id.mailbox_widget_name, context.getString(R.string.mailbox_widget_unset))
                setViewVisibility(R.id.mailbox_widget_new, View.GONE)
                setViewVisibility(R.id.mailbox_widget_total, View.GONE)
            } else {
                val fresh = number(widgetData, "count.$folderId.new", 0)
                // Everything in the folder, or only what is unread:
                // chosen per widget when it was placed.
                val unread = widgetData.getString("widget.$widgetId.mode", null) == "unread"
                val total = number(
                    widgetData,
                    if (unread) "count.$folderId.unread" else "count.$folderId.total",
                    0,
                )

                setTextViewText(
                    R.id.mailbox_widget_name,
                    // A name of its own beats the folder's, which is how
                    // two widgets on the same mailbox are told apart.
                    widgetData.getString("widget.$widgetId.label", null)
                        ?: widgetData.getString("count.$folderId.label", null)
                        ?: context.getString(R.string.mailbox_widget_unset),
                )
                // Nothing new is no badge at all. A nought in a red
                // circle reads as an alert about nothing.
                setViewVisibility(
                    R.id.mailbox_widget_new,
                    if (fresh > 0) View.VISIBLE else View.GONE,
                )
                setTextViewText(R.id.mailbox_widget_new, badge(fresh, 99))
                setViewVisibility(R.id.mailbox_widget_total, View.VISIBLE)
                setTextViewText(R.id.mailbox_widget_total, badge(total, 9999))
            }
        }
        appWidgetManager.updateAppWidget(widgetId, views)
    }

    /**
     * A number the Dart side wrote, whichever way it wrote it.
     *
     * Values cross from Dart as Integer or Long depending on their size —
     * an opaque colour is over two billion, so it arrives as a Long and is
     * stored with putLong, while a message count arrives as an Integer.
     * getInt on the first of those throws ClassCastException, which crashed
     * the app for everyone with a widget on their home screen. Reading the
     * value and asking what it is costs nothing and cannot be got wrong.
     */
    private fun number(data: SharedPreferences, key: String, fallback: Int): Int =
        when (val stored = data.all[key]) {
            is Int -> stored
            is Long -> stored.toInt()
            else -> fallback
        }

    private companion object {
        /** The app's own orange, for a widget placed before there was a
         *  choice of colour. */
        const val DEFAULT_COLOUR = 0xFFFF7A18.toInt()
    }

    /**
     * A count that has to fit in a badge the size of a fingernail.
     *
     * Exact up to [plain], then thousands, then a bare cap. A mailbox with
     * 31,402 messages in it is telling you "a great many" whatever the
     * digits say, and four characters is all there is room for.
     */
    private fun badge(count: Int, plain: Int): String = when {
        count <= plain -> count.toString()
        // A badge that caps, the way every notification badge does, rather
        // than rounding: "99+" says more than "2k" about what is unread.
        plain < 1000 -> "$plain+"
        count < 100_000 -> "${count / 1000}k"
        else -> "99k+"
    }
}
