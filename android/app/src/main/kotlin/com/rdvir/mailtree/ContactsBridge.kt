package com.rdvir.mailtree

import android.Manifest
import android.app.Activity
import android.content.pm.PackageManager
import android.net.Uri
import android.provider.ContactsContract
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * The device's address book, as far as recipients need it: names and
 * email addresses matching what has been typed so far.
 *
 * Reading contacts needs a permission Android grants at runtime, and the
 * asking has to go through an Activity. The answer arrives later, in
 * [onPermissionResult], so a request is held until then.
 *
 * Nothing here writes to the address book, and nothing about it leaves the
 * device: a query goes to the contacts provider and the matches go to the
 * compose screen.
 */
class ContactsBridge(
    private val activity: Activity,
    messenger: BinaryMessenger,
) : MethodChannel.MethodCallHandler {

    init {
        MethodChannel(messenger, CHANNEL).setMethodCallHandler(this)
    }

    private var pendingPermission: MethodChannel.Result? = null

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "hasPermission" -> result.success(hasPermission())
                "requestPermission" -> requestPermission(result)
                "search" -> result.success(
                    search(call.argument<String>("query") ?: "", call.argument<Int>("limit") ?: 12),
                )
                else -> result.notImplemented()
            }
        } catch (e: Exception) {
            result.error("contacts-failed", e.message, null)
        }
    }

    private fun hasPermission(): Boolean =
        ContextCompat.checkSelfPermission(activity, Manifest.permission.READ_CONTACTS) ==
            PackageManager.PERMISSION_GRANTED

    private fun requestPermission(result: MethodChannel.Result) {
        if (hasPermission()) {
            result.success(true)
            return
        }
        // One at a time. A second ask while the dialog is up would leave the
        // first one waiting for an answer that never comes.
        pendingPermission?.success(false)
        pendingPermission = result
        ActivityCompat.requestPermissions(
            activity,
            arrayOf(Manifest.permission.READ_CONTACTS),
            REQUEST_CODE,
        )
    }

    /** Called by the activity when Android answers. */
    fun onPermissionResult(requestCode: Int, grantResults: IntArray): Boolean {
        if (requestCode != REQUEST_CODE) return false
        val granted = grantResults.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED
        pendingPermission?.success(granted)
        pendingPermission = null
        return true
    }

    /**
     * Contacts whose name or address starts with [query], as the address
     * book's own filter understands it: a word anywhere in the name counts,
     * so "dv" finds "Ron Dvir".
     */
    private fun search(query: String, limit: Int): List<Map<String, String?>> {
        if (!hasPermission() || query.isBlank()) return emptyList()
        val uri = Uri.withAppendedPath(
            ContactsContract.CommonDataKinds.Email.CONTENT_FILTER_URI,
            Uri.encode(query.trim()),
        )
        val projection = arrayOf(
            ContactsContract.CommonDataKinds.Email.ADDRESS,
            ContactsContract.CommonDataKinds.Email.DISPLAY_NAME_PRIMARY,
            ContactsContract.CommonDataKinds.Email.TIMES_CONTACTED,
        )
        val found = mutableListOf<Map<String, String?>>()
        activity.contentResolver.query(
            uri,
            projection,
            null,
            null,
            "${ContactsContract.CommonDataKinds.Email.TIMES_CONTACTED} DESC",
        )?.use { cursor ->
            val addressColumn = cursor.getColumnIndex(ContactsContract.CommonDataKinds.Email.ADDRESS)
            val nameColumn = cursor.getColumnIndex(ContactsContract.CommonDataKinds.Email.DISPLAY_NAME_PRIMARY)
            while (cursor.moveToNext() && found.size < limit) {
                val address = cursor.getString(addressColumn)?.trim().orEmpty()
                if (address.isEmpty() || '@' !in address) continue
                found.add(
                    mapOf(
                        "email" to address,
                        "name" to cursor.getString(nameColumn)?.trim()?.takeIf { it.isNotEmpty() },
                    ),
                )
            }
        }
        return found
    }

    companion object {
        const val CHANNEL = "mailtree/contacts"
        private const val REQUEST_CODE = 4127
    }
}
