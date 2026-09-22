package com.rdvir.mailtree

import android.app.Activity
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.ActivityNotFoundException
import android.content.Intent
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Point
import android.graphics.Typeface
import android.net.Uri
import android.os.Build
import android.util.TypedValue
import android.view.DragEvent
import android.view.View
import android.view.ViewGroup
import android.webkit.MimeTypeMap
import androidx.core.content.FileProvider
import androidx.core.content.IntentCompat
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * Files leaving and entering the app: opening an attachment in another app,
 * dragging one out, copying one to the clipboard, and the same three the
 * other way round.
 *
 * All of it is one Android idea — a content URI another app is granted
 * permission to read — wearing four different hats. The app never hands over
 * a file path: a path to this app's private storage is unreadable to anyone
 * else, and handing one out throws FileUriExposedException on anything
 * modern. FileProvider turns the file into a URI, and the grant travels with
 * the intent, the clip or the drag.
 */
class FilesBridge(
    private val activity: Activity,
    messenger: BinaryMessenger,
) : MethodChannel.MethodCallHandler {

    private val channel =
        MethodChannel(messenger, CHANNEL).also { it.setMethodCallHandler(this) }

    private val authority: String
        get() = "${activity.packageName}.files"

    /// The transparent sheet that catches drops. Kept so it can be put back
    /// on top after anything else is added over it.
    private var catcher: View? = null

    /// A share that arrived before Dart was ready to hear about it. On a
    /// cold start the intent is here long before the Flutter side has set a
    /// handler, so it waits to be asked for.
    private var pendingShare: Map<String, Any?>? = null

    /**
     * Something shared to this app from another: files under EXTRA_STREAM,
     * text under EXTRA_TEXT, a subject if the sender gave one. Copied in
     * now, while the grant that came with the intent still holds.
     *
     * Kept for Dart to collect on a cold start, and pushed straight across
     * when the app was already running.
     */
    fun takeShare(intent: Intent?, pushNow: Boolean) {
        if (intent == null) return
        val action = intent.action
        if (action != Intent.ACTION_SEND && action != Intent.ACTION_SEND_MULTIPLE) return

        val uris = mutableListOf<Uri>()
        if (action == Intent.ACTION_SEND) {
            IntentCompat.getParcelableExtra(intent, Intent.EXTRA_STREAM, Uri::class.java)
                ?.let { uris.add(it) }
        } else {
            IntentCompat.getParcelableArrayListExtra(intent, Intent.EXTRA_STREAM, Uri::class.java)
                ?.let { uris.addAll(it) }
        }
        intent.clipData?.let { clip ->
            for (i in 0 until clip.itemCount) {
                clip.getItemAt(i).uri?.let { if (it !in uris) uris.add(it) }
            }
        }

        val share = mapOf(
            "files" to copyIn(uris),
            "text" to intent.getStringExtra(Intent.EXTRA_TEXT),
            "subject" to intent.getStringExtra(Intent.EXTRA_SUBJECT),
        )
        // The same intent is not a share twice: a rotation hands the
        // activity its launching intent again.
        intent.action = null
        if (pushNow) {
            channel.invokeMethod("shared", share)
        } else {
            pendingShare = share
        }
    }

    /// Called when the app comes back to the front: a platform view added
    /// while it was away — a WebView opening a message — is added above
    /// whatever was there, and the catcher has to be above that.
    fun keepOnTop() = catcher?.bringToFront()

    /**
     * Listen for files dragged into the window from another app.
     *
     * On the decor view rather than anywhere smaller: in split screen the
     * drop can land on any part of this app, and Flutter draws its whole UI
     * into one view, so there is nothing smaller to attach it to that would
     * still catch every drop.
     */
    fun listenForDrops() {
        val listener = View.OnDragListener { _, event ->
            when (event.action) {
                // True whatever is being dragged. Refusing by type here
                // means never hearing about the drop, and what can be made
                // of it is better judged when it lands.
                DragEvent.ACTION_DRAG_STARTED -> true
                DragEvent.ACTION_DROP -> handleDrop(event)
                else -> true
            }
        }

        val root = activity.findViewById<ViewGroup>(android.R.id.content)
        if (root == null) {
            activity.window.decorView.setOnDragListener(listener)
            return
        }

        // A sheet of glass over the whole app, and the reason for it:
        //
        // Android gives a drop to the deepest view that said it wanted the
        // drag, and a WebView always says yes. The message editor is a
        // WebView, so dropping a file onto the body of a message being
        // written went to the WebView, which can do nothing with a PDF, and
        // the app never heard about the drop at all. Dropping on the header
        // worked, which is how this was found.
        //
        // The catcher sits above everything, so it is the deepest
        // interested view wherever the file lands. It takes no touches: a
        // view that is not clickable returns false from onTouchEvent, and
        // the dispatch carries on to the app underneath.
        val view = View(activity).apply {
            layoutParams = ViewGroup.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.MATCH_PARENT,
            )
            isClickable = false
            isFocusable = false
            importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO
            setOnDragListener(listener)
        }
        catcher = view
        // Posted, not added now. This runs while the activity is being set
        // up, before Flutter has put its own view in — so adding the
        // catcher here puts it underneath, where the WebView inside Flutter
        // takes every drop before it. Hence the first version of this: a
        // file dropped on a message header attached, and the same file
        // dropped on the body vanished.
        root.post {
            root.addView(view)
            view.bringToFront()
        }

        // The window itself as well, for a drop that lands somewhere the
        // catcher does not cover — a dialog, or a system-drawn inset.
        activity.window.decorView.setOnDragListener(listener)
    }

    private fun handleDrop(event: DragEvent): Boolean {
        val clip = event.clipData ?: return false
        // Without this the URIs in the drag belong to the app that started
        // it and reading them throws. The permission lasts as long as the
        // activity, which is long enough to copy the bytes out.
        val permissions =
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                activity.requestDragAndDropPermissions(event)
            } else {
                null
            }
        try {
            val files = copyIn(clip)
            android.util.Log.i(
                "MyEmail",
                "drop: ${clip.itemCount} item(s) offered, ${files.size} taken",
            )
            // A text item rides along with this app's own drags: the ids
            // of the messages, so a copy of the app can move them.
            val text = (0 until clip.itemCount)
                .firstNotNullOfOrNull { clip.getItemAt(it).text?.toString() }
            if (files.isEmpty() && text == null) return false
            channel.invokeMethod(
                "dropped",
                mapOf(
                    "files" to files,
                    "label" to clip.description?.label?.toString(),
                    "text" to text,
                    "x" to event.x,
                    "y" to event.y,
                ),
            )
            return true
        } catch (e: Exception) {
            android.util.Log.e("MyEmail", "could not take the dropped files", e)
            return false
        } finally {
            permissions?.release()
        }
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "open" -> {
                    view(call.argument<String>("path")!!, call.argument<String>("mime"))
                    result.success(null)
                }
                "share" -> {
                    share(call.argument<String>("path")!!, call.argument<String>("mime"))
                    result.success(null)
                }
                "copy" -> {
                    copy(
                        call.argument<String>("path")!!,
                        call.argument<String>("mime"),
                        call.argument<String>("name") ?: "Attachment",
                    )
                    result.success(null)
                }
                "paste" -> result.success(paste())
                "takeShare" -> {
                    result.success(pendingShare)
                    pendingShare = null
                }
                "startDrag" -> result.success(
                    startDrag(
                        call.argument<String>("path")!!,
                        call.argument<String>("mime"),
                        call.argument<String>("name") ?: "Attachment",
                    ),
                )
                "startDragMany" -> result.success(
                    startDragMany(
                        call.argument<List<String>>("paths") ?: emptyList(),
                        call.argument<List<String?>>("mimes") ?: emptyList(),
                        call.argument<List<String>>("names") ?: emptyList(),
                        call.argument<String>("label"),
                        call.argument<String>("text"),
                    ),
                )
                else -> result.notImplemented()
            }
        } catch (e: Exception) {
            result.error("files-failed", e.message, null)
        }
    }

    private fun uriFor(path: String): Uri =
        FileProvider.getUriForFile(activity, authority, File(path))

    private fun view(path: String, mime: String?) {
        val type = typeFor(mime, File(path).name)
        val intent = Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(uriFor(path), type)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        // The plain intent first, so a PDF goes straight to whatever the
        // person chose to read PDFs with. Wrapping every open in a chooser
        // means being asked every time and never being able to answer:
        // "Always" has nothing to attach itself to.
        //
        // With nothing installed for the type that throws, and the chooser
        // is the fallback, because it says "no apps can open this" rather
        // than crashing.
        try {
            activity.startActivity(intent)
        } catch (e: ActivityNotFoundException) {
            activity.startActivity(Intent.createChooser(intent, null))
        }
    }

    /**
     * What to tell Android this file is.
     *
     * The caller has already preferred the file name over whatever the
     * sender claimed. This is the second line of defence: a type with
     * parameters on it (application/pdf; name=x.pdf) matches nothing, and
     * a vague one is worth one more look at the extension before giving
     * up. A mail system that calls every attachment a stream of bytes is
     * how a PDF ends up being offered to an archive viewer.
     */
    private fun typeFor(mime: String?, name: String): String {
        val given = mime?.substringBefore(';')?.trim()?.lowercase()
        if (!given.isNullOrEmpty() && !vague(given)) return given
        val extension = name.substringAfterLast('.', "").lowercase()
        val known = MimeTypeMap.getSingleton()
            .getMimeTypeFromExtension(extension)
        return known ?: given ?: "*/*"
    }

    private fun vague(type: String): Boolean =
        type == "application/octet-stream" ||
            type == "binary/octet-stream" ||
            type == "application/unknown" ||
            type == "*/*"

    private fun share(path: String, mime: String?) {
        val intent = Intent(Intent.ACTION_SEND).apply {
            type = mime ?: "*/*"
            putExtra(Intent.EXTRA_STREAM, uriFor(path))
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        activity.startActivity(Intent.createChooser(intent, null))
    }

    private fun copy(path: String, mime: String?, name: String) {
        val clipboard =
            activity.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
        // newUri, not newPlainText: this is the file itself, so it pastes
        // into Files or Drive as a file rather than as its own name.
        val clip = ClipData.newUri(activity.contentResolver, name, uriFor(path))
        clipboard.setPrimaryClip(clip)
    }

    /** Files on the clipboard, copied in and handed over as paths. */
    private fun paste(): List<Map<String, Any?>> {
        val clipboard =
            activity.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
        // Android only lets the focused app read this, which is the case
        // here because reading it is something the person just asked for.
        val clip = clipboard.primaryClip
        val taken = if (clip == null) emptyList() else copyIn(clip)
        // Shapes, not contents: how many items were on the clipboard, how
        // many of them were files, and how many came across. Enough to tell
        // an empty clipboard from one this app could not read, without
        // putting what was copied into the system log.
        android.util.Log.i(
            "MyEmail",
            "paste: clip=${clip != null} items=${clip?.itemCount ?: 0} " +
                "uris=${clip?.let { c -> (0 until c.itemCount).count { c.getItemAt(it).uri != null } } ?: 0} " +
                "taken=${taken.size}",
        )
        return taken
    }

    /**
     * Copy whatever a clip points at into this app's own storage.
     *
     * The URI in a clip or a drag is borrowed: the permission behind it is
     * withdrawn the moment the drag ends or the other app decides so. What
     * is kept has to be a copy, made now.
     */
    private fun copyIn(clip: ClipData): List<Map<String, Any?>> =
        copyIn(
            (0 until clip.itemCount).mapNotNull { clip.getItemAt(it).uri },
        )

    private fun copyIn(uris: List<Uri>): List<Map<String, Any?>> {
        val incoming = File(activity.cacheDir, "incoming").apply { mkdirs() }
        val taken = mutableListOf<Map<String, Any?>>()
        for ((i, uri) in uris.withIndex()) {
            val name = displayName(uri) ?: "file-${System.currentTimeMillis()}-$i"
            val target = File(incoming, name.replace(File.separatorChar, '_'))
            try {
                activity.contentResolver.openInputStream(uri).use { input ->
                    if (input == null) return@use
                    target.outputStream().use { output -> input.copyTo(output) }
                }
            } catch (e: Exception) {
                android.util.Log.e("MyEmail", "could not copy $uri", e)
                continue
            }
            if (!target.exists() || target.length() == 0L) continue
            taken.add(
                mapOf(
                    "path" to target.absolutePath,
                    "name" to name,
                    "mime" to (activity.contentResolver.getType(uri) ?: "application/octet-stream"),
                    "size" to target.length(),
                ),
            )
        }
        return taken
    }

    private fun displayName(uri: Uri): String? {
        activity.contentResolver.query(uri, null, null, null, null)?.use { cursor ->
            val column = cursor.getColumnIndex(android.provider.OpenableColumns.DISPLAY_NAME)
            if (column >= 0 && cursor.moveToFirst()) return cursor.getString(column)
        }
        return uri.lastPathSegment?.substringAfterLast('/')
    }

    /**
     * Several files in one drag: the first makes the ClipData, the rest
     * are added, and a line of text goes last for whoever knows to read
     * it. The label is how this app recognises its own drag coming back.
     */
    private fun startDragMany(
        paths: List<String>,
        mimes: List<String?>,
        names: List<String>,
        label: String?,
        text: String?,
    ): Boolean {
        if (paths.isEmpty()) return false
        val clip = ClipData(
            label ?: names.firstOrNull() ?: "Files",
            arrayOf(mimes.firstOrNull() ?: "*/*"),
            ClipData.Item(uriFor(paths[0])),
        )
        for (i in 1 until paths.size) clip.addItem(ClipData.Item(uriFor(paths[i])))
        if (text != null) clip.addItem(ClipData.Item(text))
        val shown = if (names.size == 1) names[0] else "${names.size} messages"
        val flags = View.DRAG_FLAG_GLOBAL or View.DRAG_FLAG_GLOBAL_URI_READ
        return activity.window.decorView.startDragAndDrop(
            clip,
            NameShadow(activity, shown),
            null,
            flags,
        )
    }

    private fun startDrag(path: String, mime: String?, name: String): Boolean {
        val clip = ClipData.newUri(activity.contentResolver, name, uriFor(path))
        // GLOBAL, or the drag cannot leave this app; GLOBAL_URI_READ, or it
        // leaves and lands somewhere that is not allowed to read it.
        val flags = View.DRAG_FLAG_GLOBAL or View.DRAG_FLAG_GLOBAL_URI_READ
        return activity.window.decorView.startDragAndDrop(
            clip,
            NameShadow(activity, name),
            null,
            flags,
        )
    }

    /**
     * What follows the finger: the file's name on a small dark slab.
     *
     * The default shadow is a picture of the view the drag started from,
     * which here is the whole window — dragging a screenshot of the app
     * across the screen rather than a file.
     */
    private class NameShadow(context: Context, private val name: String) :
        View.DragShadowBuilder() {

        private val density = context.resources.displayMetrics.density
        private val text = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            color = Color.WHITE
            textSize = TypedValue.applyDimension(
                TypedValue.COMPLEX_UNIT_SP,
                13f,
                context.resources.displayMetrics,
            )
            typeface = Typeface.DEFAULT_BOLD
        }
        private val slab = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            color = Color.argb(235, 32, 33, 36)
        }

        private val padding = 12f * density
        private val width =
            (text.measureText(name) + padding * 2).coerceAtMost(280f * density)
        private val height = 40f * density

        override fun onProvideShadowMetrics(size: Point, touch: Point) {
            size.set(width.toInt(), height.toInt())
            touch.set((width / 2).toInt(), (height / 2).toInt())
        }

        override fun onDrawShadow(canvas: Canvas) {
            val radius = 8f * density
            canvas.drawRoundRect(0f, 0f, width, height, radius, radius, slab)
            val baseline = height / 2 - (text.descent() + text.ascent()) / 2
            canvas.drawText(name, padding, baseline, text)
        }
    }

    companion object {
        const val CHANNEL = "mailtree/files"
    }
}
