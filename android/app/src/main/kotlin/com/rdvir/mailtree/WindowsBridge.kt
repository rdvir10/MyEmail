package com.rdvir.mailtree

import android.app.Activity
import android.app.ActivityManager
import android.content.Context
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
                // Split screen, a pop-up, a DeX window: anything but the
                // whole screen.
                "inMultiWindow" -> result.success(
                    Build.VERSION.SDK_INT >= Build.VERSION_CODES.N && activity.isInMultiWindowMode,
                )
                "open" -> {
                    val route = call.argument<String>("route")
                    if (route.isNullOrEmpty()) {
                        result.error("no-route", "Nothing to open the window on.", null)
                        return
                    }
                    val intent = Intent(activity, WindowActivity::class.java).apply {
                        putExtra("route", route)
                        addFlags(
                            Intent.FLAG_ACTIVITY_NEW_TASK or
                                Intent.FLAG_ACTIVITY_NEW_DOCUMENT or
                                Intent.FLAG_ACTIVITY_MULTIPLE_TASK,
                        )
                        // Beside this one only when there already is a
                        // "beside": in split screen. Asked for from a
                        // full-screen app, One UI answers with the Recents
                        // picker and hands the intent to the activity that
                        // is already running, and no window opens at all.
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N &&
                            activity.isInMultiWindowMode
                        ) {
                            addFlags(Intent.FLAG_ACTIVITY_LAUNCH_ADJACENT)
                        }
                    }
                    val before = taskCount()
                    activity.startActivity(intent)
                    // Say so only once the window exists. The caller closes
                    // its own copy of what it handed over, and must not do
                    // that on the strength of an intent the system swallowed.
                    var opened = false
                    for (attempt in 0 until 10) {
                        if (taskCount() > before) {
                            opened = true
                            break
                        }
                        Thread.sleep(50)
                    }
                    result.success(opened)
                }
                else -> result.notImplemented()
            }
        } catch (e: Exception) {
            result.error("windows", e.message, null)
        }
    }

    /** How many tasks this app has: one per window. */
    private fun taskCount(): Int =
        (activity.getSystemService(Context.ACTIVITY_SERVICE) as? ActivityManager)
            ?.appTasks?.size ?: 0

    companion object {
        const val CHANNEL = "mailtree/windows"
    }
}
