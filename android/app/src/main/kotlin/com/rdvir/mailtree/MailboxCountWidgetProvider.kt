package com.rdvir.mailtree

import android.appwidget.AppWidgetManager
import android.content.Context
import android.content.SharedPreferences
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
 */
class MailboxCountWidgetProvider : HomeWidgetProvider() {

    override fun onUpdate(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetIds: IntArray,
        widgetData: SharedPreferences,
    ) {
        appWidgetIds.forEach { widgetId ->
            val folderId = widgetData.getString("widget.$widgetId.folder", null)
            val views = RemoteViews(context.packageName, R.layout.mailbox_count_widget).apply {
                setOnClickPendingIntent(
                    R.id.mailbox_widget_root,
                    HomeWidgetLaunchIntent.getActivity(context, MainActivity::class.java),
                )

                if (folderId == null) {
                    // Placed but never set up, or the mailbox it was set up
                    // with has gone. Either way the honest thing is to say so
                    // rather than show a confident zero.
                    setTextViewText(R.id.mailbox_widget_name, context.getString(R.string.mailbox_widget_unset))
                    setTextViewText(R.id.mailbox_widget_new, "—")
                    setTextViewText(R.id.mailbox_widget_total, context.getString(R.string.mailbox_widget_open_app))
                } else {
                    val fresh = widgetData.getInt("count.$folderId.new", 0)
                    val total = widgetData.getInt("count.$folderId.total", 0)
                    setTextViewText(
                        R.id.mailbox_widget_name,
                        widgetData.getString("count.$folderId.label", null)
                            ?: context.getString(R.string.mailbox_widget_unset),
                    )
                    setTextViewText(R.id.mailbox_widget_new, fresh.toString())
                    setTextViewText(
                        R.id.mailbox_widget_total,
                        context.getString(R.string.mailbox_widget_total, total),
                    )
                }
            }
            appWidgetManager.updateAppWidget(widgetId, views)
        }
    }
}
