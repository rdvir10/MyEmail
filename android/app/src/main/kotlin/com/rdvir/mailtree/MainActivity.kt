package com.rdvir.mailtree

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

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

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
