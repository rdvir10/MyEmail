package com.rdvir.mailtree

import android.app.Activity
import android.content.Context
import android.print.PrintAttributes
import android.print.PrintManager
import android.webkit.WebView
import android.webkit.WebViewClient
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Printing a message, and saving it as a PDF, which on Android are the
 * same dialog: the system's print sheet offers "Save as PDF" as one of its
 * printers.
 *
 * The page is laid out by a WebView of our own, off screen: the one the
 * reading pane shows is Flutter's platform view and cannot be reached
 * from here, and a print needs the whole document at page width rather
 * than the scrolled window of it. The WebView must stay referenced until
 * the print job has taken what it needs, hence the field.
 */
class PrintBridge(
    private val activity: Activity,
    messenger: BinaryMessenger,
) : MethodChannel.MethodCallHandler {

    init {
        MethodChannel(messenger, CHANNEL).setMethodCallHandler(this)
    }

    private var printing: WebView? = null

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "print" -> {
                    val title = call.argument<String>("title") ?: "Message"
                    val html = call.argument<String>("html")
                    if (html.isNullOrEmpty()) {
                        result.error("no-html", "Nothing to print.", null)
                        return
                    }
                    print(title, html)
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        } catch (e: Exception) {
            result.error("print", e.message, null)
        }
    }

    private fun print(title: String, html: String) {
        val web = WebView(activity)
        printing = web
        web.settings.javaScriptEnabled = false
        web.settings.loadsImagesAutomatically = true
        web.webViewClient = object : WebViewClient() {
            override fun onPageFinished(view: WebView, url: String?) {
                val manager = activity.getSystemService(Context.PRINT_SERVICE) as PrintManager
                val job = title.take(80)
                manager.print(
                    job,
                    view.createPrintDocumentAdapter(job),
                    PrintAttributes.Builder().build(),
                )
                // Let go once the system has the adapter; it holds its own
                // reference for the length of the job.
                printing = null
            }
        }
        web.loadDataWithBaseURL(null, html, "text/html", "utf-8", null)
    }

    companion object {
        const val CHANNEL = "mailtree/print"
    }
}
