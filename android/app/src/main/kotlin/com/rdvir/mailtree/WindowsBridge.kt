package com.rdvir.mailtree

import android.app.Activity
import android.content.Intent
import android.os.Build
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * A second window of the app.
 *
 * Android has no windows as such; it has tasks, and a launcher or a
 * multi-window system shows each task in a window of its own. So a new
 * window is a new task holding a new copy of [MainActivity], which
 * Flutter gives its own engine and Dart isolate: a second copy of the app,
 * sharing the mail cache on disk and nothing in memory.
 *
 * NEW_DOCUMENT with MULTIPLE_TASK is what makes it a new task rather than
 * a return to the one that exists; LAUNCH_ADJACENT asks the system to put
 * it beside this one, which in split screen means the other half and in
 * DeX means a new window. The route extra is what FlutterActivity reads
 * as the initial route, and is how the new copy learns what to show.
 */
class WindowsBridge(
    private val activity: Activity,
    messenger: BinaryMessenger,
) : MethodChannel.MethodCallHandler {

    init {
        MethodChannel(messenger, CHANNEL).setMethodCallHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "available" -> result.success(Build.VERSION.SDK_INT >= Build.VERSION_CODES.N)
                "open" -> {
                    val route = call.argument<String>("route")
                    if (route.isNullOrEmpty()) {
                        result.error("no-route", "Nothing to open the window on.", null)
                        return
                    }
                    val intent = Intent(activity, MainActivity::class.java).apply {
                        putExtra("route", route)
                        addFlags(
                            Intent.FLAG_ACTIVITY_NEW_TASK or
                                Intent.FLAG_ACTIVITY_NEW_DOCUMENT or
                                Intent.FLAG_ACTIVITY_MULTIPLE_TASK or
                                Intent.FLAG_ACTIVITY_LAUNCH_ADJACENT,
                        )
                    }
                    activity.startActivity(intent)
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        } catch (e: Exception) {
            result.error("windows", e.message, null)
        }
    }

    companion object {
        const val CHANNEL = "mailtree/windows"
    }
}
