package com.rdvir.mailtree

import android.app.Activity
import android.appwidget.AppWidgetManager
import android.content.ComponentName
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
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
open class MainActivity : FlutterActivity() {

    private val channelName = "mailtree/installer"
    private val widgetChannelName = "mailtree/widget"
    private val oauthChannelName = "mailtree/oauth"

    private var widgetChannel: MethodChannel? = null
    private var oauthChannel: MethodChannel? = null

    private var files: FilesBridge? = null
    private var contacts: ContactsBridge? = null

    /**
     * Whether this start is Android bringing the app back rather than
     * someone sharing to it: the activity rebuilt from saved state after
     * Android stopped the app in the background, or reopened from Recents.
     * Either way it comes with the intent it was first started with, a
     * share that was sent long ago among them, and taking that again
     * opened a new message with the same files attached.
     */
    private var restarted = false

    override fun onCreate(savedInstanceState: Bundle?) {
        // Before super, which is where configureFlutterEngine runs.
        restarted = savedInstanceState != null ||
            (intent.flags and Intent.FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY) != 0
        super.onCreate(savedInstanceState)
    }

    /**
     * A route only for a window the app itself opened.
     *
     * FlutterActivity takes the initial route from a "route" extra on
     * whatever intent started it, and this activity is exported: it is the
     * launcher and the share target. Any app could therefore start it on a
     * window route naming a file, and the app used to read that file and
     * delete it — the stored sign-ins among the files it could reach. The
     * window activity is not exported, so only the app can start that.
     */
    override fun getInitialRoute(): String? =
        if (this is WindowActivity) super.getInitialRoute() else null

    /**
     * Hand a sign-in redirect to Dart, and nothing else: only a URL on the
     * app's own Google scheme, whichever activity sent it.
     */
    private fun passOAuthRedirect(intent: Intent?) {
        val data = intent?.data ?: return
        if (intent.action != Intent.ACTION_VIEW) return
        if (data.scheme?.startsWith(OAUTH_SCHEME_PREFIX) != true) return
        oauthChannel?.invokeMethod("redirect", data.toString())
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // Attachments in and out: opening, sharing, the clipboard and drag
        // and drop, all of which are content URIs underneath.
        // Recipients suggested from the address book, with the permission
        // that needs asked through this activity.
        contacts = ContactsBridge(this, flutterEngine.dartExecutor.binaryMessenger)
        // A second window: another copy of this activity, in its own task.
        WindowsBridge(this, flutterEngine.dartExecutor.binaryMessenger)
        // Print, and save as PDF, through the system's print sheet.
        PrintBridge(this, flutterEngine.dartExecutor.binaryMessenger)
        // Events handed to the calendar app's own new-event screen.
        CalendarBridge(this, flutterEngine.dartExecutor.binaryMessenger)

        files = FilesBridge(this, flutterEngine.dartExecutor.binaryMessenger)
            .also {
                it.listenForDrops()
                // Opened from a share sheet: the files and text are on the
                // intent that started us, and Dart will ask for them.
                if (!restarted) it.takeShare(intent, pushNow = false)
            }

        // The URL the browser came back with after a Google sign-in, from
        // OAuthRedirectActivity. Only the main window takes it: a second
        // window is a copy of this activity with no sign-in of its own.
        if (this !is WindowActivity) {
            oauthChannel = MethodChannel(
                flutterEngine.dartExecutor.binaryMessenger,
                oauthChannelName,
            )
            passOAuthRedirect(intent)
        }

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

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        if (contacts?.onPermissionResult(requestCode, grantResults) == true) return
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
    }

    override fun onResume() {
        super.onResume()
        // Anything Flutter adds — the web view a message body renders in —
        // goes above what was there, so the drop catcher is put back on top.
        files?.keepOnTop()
    }

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
        // Back from the browser after a Google sign-in, by way of
        // OAuthRedirectActivity.
        passOAuthRedirect(intent)
        // Shared to an app that was already running: Dart is up, so it is
        // told straight away.
        files?.takeShare(intent, pushNow = true)
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

    companion object {
        /** Google's reverse-client-ID schemes all begin this way. */
        const val OAUTH_SCHEME_PREFIX = "com.googleusercontent.apps."
    }
}
