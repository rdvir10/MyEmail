package com.rdvir.mailtree

import android.Manifest
import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.provider.ContactsContract
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * The device's address book, as far as the app needs it: names and email
 * addresses matching what has been typed so far, whether someone on a
 * message is in it, and the contacts app's own screens to add them or to
 * see them.
 *
 * Reading contacts needs a permission Android grants at runtime, and the
 * asking has to go through an Activity. The answer arrives later, in
 * [onPermissionResult], so a request is held until then.
 *
 * Nothing here writes to the address book, and nothing about it leaves the
 * device: a query goes to the contacts provider and the matches go to the
 * app. Adding someone is the contacts app's new-contact screen with their
 * name and address filled in, where the person picks which account keeps
 * it and saves it themselves; no permission is needed for that.
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
                "find" -> result.success(find(call.argument<String>("email") ?: ""))
                "insert" -> result.success(
                    insert(call.argument<String>("name"), call.argument<String>("email") ?: ""),
                )
                "open" -> result.success(open(call.argument<String>("uri") ?: ""))
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

    /**
     * The contact that holds [email], as the link that opens it and the name
     * it is filed under, or null: none does, or the address book may not be
     * read. The address book's filter matches the start of an address, so
     * each match is compared whole, the way mail compares one: ignoring case.
     */
    private fun find(email: String): Map<String, String?>? {
        val wanted = email.trim()
        if (!hasPermission() || wanted.isEmpty()) return null
        val uri = Uri.withAppendedPath(
            ContactsContract.CommonDataKinds.Email.CONTENT_FILTER_URI,
            Uri.encode(wanted),
        )
        val projection = arrayOf(
            ContactsContract.CommonDataKinds.Email.ADDRESS,
            ContactsContract.CommonDataKinds.Email.CONTACT_ID,
            ContactsContract.CommonDataKinds.Email.LOOKUP_KEY,
            ContactsContract.CommonDataKinds.Email.DISPLAY_NAME_PRIMARY,
        )
        activity.contentResolver.query(uri, projection, null, null, null)?.use { cursor ->
            val addressColumn = cursor.getColumnIndex(ContactsContract.CommonDataKinds.Email.ADDRESS)
            val idColumn = cursor.getColumnIndex(ContactsContract.CommonDataKinds.Email.CONTACT_ID)
            val keyColumn = cursor.getColumnIndex(ContactsContract.CommonDataKinds.Email.LOOKUP_KEY)
            val nameColumn = cursor.getColumnIndex(ContactsContract.CommonDataKinds.Email.DISPLAY_NAME_PRIMARY)
            while (cursor.moveToNext()) {
                val address = cursor.getString(addressColumn)?.trim().orEmpty()
                if (!address.equals(wanted, ignoreCase = true)) continue
                // A lookup link rather than the row id: it still finds the
                // contact after the address book merges or re-syncs it.
                val link = ContactsContract.Contacts.getLookupUri(
                    cursor.getLong(idColumn),
                    cursor.getString(keyColumn),
                ) ?: continue
                return mapOf(
                    "uri" to link.toString(),
                    "name" to cursor.getString(nameColumn)?.trim()?.takeIf { it.isNotEmpty() },
                )
            }
        }
        return null
    }

    /**
     * The contacts app's own new-contact screen, with [name] and [email]
     * filled in. The person sees what is about to be kept, picks the account
     * that keeps it, and saves; the app writes nothing itself. False where
     * no app takes it.
     */
    private fun insert(name: String?, email: String): Boolean {
        if (email.isBlank()) return false
        val intent = Intent(ContactsContract.Intents.Insert.ACTION).apply {
            type = ContactsContract.RawContacts.CONTENT_TYPE
            name?.trim()?.takeIf { it.isNotEmpty() }?.let {
                putExtra(ContactsContract.Intents.Insert.NAME, it)
            }
            putExtra(ContactsContract.Intents.Insert.EMAIL, email.trim())
            // Back to the message once it is saved, rather than on to the
            // new contact: the contacts app reads this, as Google's and the
            // stock one both do.
            putExtra("finishActivityOnSaveCompleted", true)
        }
        return start(intent)
    }

    /**
     * A contact [find] gave, in the contacts app. Only a link into the
     * address book is opened: anything else handed over is refused.
     */
    private fun open(uri: String): Boolean {
        val link = Uri.parse(uri)
        if (link.scheme != "content" || link.authority != ContactsContract.AUTHORITY) return false
        return start(Intent(Intent.ACTION_VIEW, link))
    }

    private fun start(intent: Intent): Boolean = try {
        activity.startActivity(intent)
        true
    } catch (e: ActivityNotFoundException) {
        false
    }

    companion object {
        const val CHANNEL = "mailtree/contacts"
        private const val REQUEST_CODE = 4127
    }
}
