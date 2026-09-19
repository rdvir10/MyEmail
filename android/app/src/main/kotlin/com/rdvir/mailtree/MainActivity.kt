package com.rdvir.mailtree

import android.app.Activity
import android.appwidget.AppWidgetManager
import android.content.ComponentName
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * The native half of the in-app updater.
 *
 * Three methods, because that is all Android needs and all an install plugin
 * would have given us. Handing a downloaded APK to the package installer is
 * one intent; the rest is the permission that guards it. This project already
 * lost a day to a plugin that stopped building against a new Android Gradle
 * Plugin, and forty lines we own are worth more than a dependency here.
 *
 * Nothing here installs anything by itself. Android shows its own
 * confirmation, and there is no way around that short of device-owner
 * privileges, which belong to management software and not to a mail client.
 */
class MainActivity : FlutterActivity() {

    private val channelName = "mailtree/installer"
    private val widgetChannelName = "mailtree/widget"

    private var widgetChannel: MethodChannel? = null

    private var files: FilesBridge? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // Attachments in and out: opening, sharing, the clipboard and drag
        // and drop, all of which are content URIs underneath.
        files = FilesBridge(this, flutterEngine.dartExecutor.binaryMessenger)
            .also { it.listenForDrops() }

        widgetChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            widgetChannelName,
        ).apply {
            setMethodCallHandler { call, result ->
                when (call.method) {
                    // Which widgets are actually on the home screen. Android
                    // never tells the app when one is dragged to the bin, so
                    // without asking, a widget's mailbox is remembered and
                    // recounted forever after it is gone.
                    "placedWidgets" -> result.success(placedWidgetIds())
                    else -> result.notImplemented()
                }
            }
        }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "canInstall" -> result.success(canRequestInstalls())
                    "openInstallSettings" -> {
                        openInstallSettings()
                        result.success(null)
                    }
                    "install" -> {
                        val path = call.argument<String>("path")
                        if (path.isNullOrEmpty()) {
                            result.error("no-path", "No file was given to install.", null)
                        } else {
                            try {
                                install(File(path))
                                result.success(null)
                            } catch (e: Exception) {
                                result.error("install-failed", e.message, null)
                            }
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun placedWidgetIds(): List<String> =
        AppWidgetManager.getInstance(this)
            .getAppWidgetIds(ComponentName(this, MailboxCountWidgetProvider::class.java))
            .map { it.toString() }

    /**
     * Placing a home-screen widget while the app is already running.
     *
     * Android sends the configure intent to the activity that is already
     * there rather than starting a new one, so Dart's main() does not run
     * again and nothing would ask which mailbox the widget should show. The
     * placement would then be cancelled and the widget would vanish, which
     * looks exactly like a bug.
     *
     * setIntent matters as much as the message: the plugin reads the
     * activity's current intent when the choice is made, and without this it
     * would still be looking at the one that launched the app.
     */
    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        if (intent.action != AppWidgetManager.ACTION_APPWIDGET_CONFIGURE) return

        val id = intent.getIntExtra(
            AppWidgetManager.EXTRA_APPWIDGET_ID,
            AppWidgetManager.INVALID_APPWIDGET_ID,
        )
        if (id == AppWidgetManager.INVALID_APPWIDGET_ID) return
        // Cancelled until the choice is made, so backing out leaves no
        // half-configured widget behind. The same default the plugin sets on
        // a cold start.
        setResult(Activity.RESULT_CANCELED)
        widgetChannel?.invokeMethod("configure", id.toString())
    }

    /**
     * Whether the user has allowed MyEmail to ask. Android 8 made this a
     * per-app setting; before that the manifest permission was enough.
     */
    private fun canRequestInstalls(): Boolean =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            packageManager.canRequestPackageInstalls()
        } else {
            true
        }

    private fun openInstallSettings() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            startActivity(
                Intent(
                    Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                    Uri.parse("package:$packageName"),
                ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
            )
        }
    }

    /**
     * The APK sits in this app's private storage, so a bare file:// URI would
     * be unreadable by the installer and throws FileUriExposedException on
     * anything modern. FileProvider hands over a content:// URI instead, and
     * the read permission grant is what makes it openable.
     */
    private fun install(file: File) {
        if (!file.exists()) throw IllegalStateException("The downloaded file is gone.")

        val uri = FileProvider.getUriForFile(
            this,
            "$packageName.updates",
            file,
        )
        val intent = Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(uri, "application/vnd.android.package-archive")
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        startActivity(intent)
    }
}
