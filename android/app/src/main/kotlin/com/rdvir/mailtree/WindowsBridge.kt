package com.rdvir.mailtree

import android.app.Activity
import android.content.Intent
import android.os.Build
import android.os.Handler
import android.os.Looper
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
                    // Say so only once the window exists. The caller closes
                    // its own copy of what it handed over, and must not do
                    // that on the strength of an intent the system swallowed;
                    // nor give up on one that did open, because it then
                    // deletes the hand-off and the window comes up empty.
                    //
                    // The window says so itself, from its onCreate. Counting
                    // the app's tasks before and after was the old test, and
                    // Recents keeps only eight documents of one activity: at
                    // the eighth, each new window pushed the oldest out, the
                    // count stayed where it was, and every window opened on
                    // nothing while the draft opened behind it. The wait
                    // also slept on the main thread, the one the new
                    // window's onCreate has to run on.
                    val timeout = Runnable {
                        if (waiting.remove(route) != null) result.success(false)
                    }
                    waiting[route] = Waiting(result, timeout)
                    try {
                        activity.startActivity(intent)
                    } catch (e: Exception) {
                        waiting.remove(route)
                        throw e
                    }
                    main.postDelayed(timeout, OPEN_TIMEOUT_MS)
                }
                else -> result.notImplemented()
            }
        } catch (e: Exception) {
            result.error("windows", e.message, null)
        }
    }

    private class Waiting(val result: MethodChannel.Result, val timeout: Runnable)

    companion object {
        const val CHANNEL = "mailtree/windows"

        /**
         * How long a window has to start before it counts as one the system
         * did not open. Started, one has taken under a tenth of a second.
         */
        private const val OPEN_TIMEOUT_MS = 3000L

        private val main = Handler(Looper.getMainLooper())

        /**
         * Windows asked for and not yet started, by route. Only touched on
         * the main thread: channel calls, onCreate and the timeout all run
         * there.
         */
        private val waiting = HashMap<String, Waiting>()

        /** A window has started on [route]: tell whoever opened it. */
        fun arrived(route: String?) {
            val window = waiting.remove(route ?: return) ?: return
            main.removeCallbacks(window.timeout)
            window.result.success(true)
        }
    }
}
