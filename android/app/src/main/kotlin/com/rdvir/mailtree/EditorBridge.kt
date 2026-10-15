package com.rdvir.mailtree

import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugins.webviewflutter.WebViewFlutterAndroidExternalApi

/**
 * The message editor's WebView, given the keyboard.
 *
 * A WebView takes keys only once Android has focused it, and Flutter's own
 * focus moving to it does not do that: a tap does, a Tab from Subject did
 * not, and the keys went on to Subject. The WebView plugin hands out its
 * views by the identifier Dart knows them by, so the editor's is the one
 * focused, not the reading pane's that may sit behind it.
 */
class EditorBridge(private val engine: FlutterEngine) : MethodChannel.MethodCallHandler {

    init {
        MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "focus" -> {
                val id = call.argument<Number>("webView")?.toLong()
                // The engine's lookup is marked deprecated in favour of one
                // taking a plugin binding, which an activity does not have.
                @Suppress("DEPRECATION")
                val view = id?.let { WebViewFlutterAndroidExternalApi.getWebView(engine, it) }
                result.success(view?.requestFocus() ?: false)
            }
            else -> result.notImplemented()
        }
    }

    companion object {
        const val CHANNEL = "mailtree/editor"
    }
}
