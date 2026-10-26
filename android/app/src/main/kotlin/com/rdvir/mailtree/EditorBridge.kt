package com.rdvir.mailtree

import android.webkit.WebView
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugins.webviewflutter.WebViewFlutterAndroidExternalApi

/**
 * The message editor's WebView, given the keyboard and taken off it.
 *
 * A WebView takes keys only once Android has focused it, and Flutter's own
 * focus moving to it does not do that: a tap does, a Tab from Subject did
 * not, and the keys went on to Subject. The WebView plugin hands out its
 * views by the identifier Dart knows them by, so the editor's is the one
 * focused, not the reading pane's that may sit behind it.
 *
 * Blur is the other way: Flutter's focus gone from the page to something
 * that is not a text field (a text field takes Android's focus itself, as
 * it shows its keyboard), where the page would otherwise go on taking what
 * is typed.
 */
class EditorBridge(private val engine: FlutterEngine) : MethodChannel.MethodCallHandler {

    init {
        MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "focus" -> {
                val view = webView(call.argument<Number>("webView"))
                result.success(view?.requestFocus() ?: false)
            }
            "blur" -> {
                val view = webView(call.argument<Number>("webView"))
                // Only from a view that has it: clearing one that does not
                // could move Android's focus from wherever it is now.
                if (view?.hasFocus() == true) view.clearFocus()
                result.success(view != null)
            }
            else -> result.notImplemented()
        }
    }

    private fun webView(id: Number?): WebView? {
        // The engine's lookup is marked deprecated in favour of one taking a
        // plugin binding, which an activity does not have.
        @Suppress("DEPRECATION")
        return id?.let { WebViewFlutterAndroidExternalApi.getWebView(engine, it.toLong()) }
    }

    companion object {
        const val CHANNEL = "mailtree/editor"
    }
}
