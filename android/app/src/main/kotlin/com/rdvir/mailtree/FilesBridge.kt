package com.rdvir.mailtree

import android.app.Activity
import android.content.ClipData
import android.content.ClipDescription
import android.content.ClipboardManager
import android.content.Context
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
import androidx.core.content.FileProvider
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

    /**
     * Listen for files dragged into the window from another app.
     *
     * On the decor view rather than anywhere smaller: in split screen the
     * drop can land on any part of this app, and Flutter draws its whole UI
     * into one view, so there is nothing smaller to attach it to that would
     * still catch every drop.
     */
    fun listenForDrops() {
        activity.window.decorView.setOnDragListener { _, event ->
            when (event.action) {
                DragEvent.ACTION_DRAG_STARTED ->
                    event.clipDescription?.hasMimeType("*/*") == true ||
                        event.clipDescription?.let { hasAnything(it) } == true
                DragEvent.ACTION_DROP -> handleDrop(event)
                else -> true
            }
        }
    }

    private fun hasAnything(description: ClipDescription): Boolean {
        for (i in 0 until description.mimeTypeCount) {
            if (description.getMimeType(i) != null) return true
        }
        return false
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
            if (files.isEmpty()) return false
            channel.invokeMethod("dropped", files)
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
                "startDrag" -> result.success(
                    startDrag(
                        call.argument<String>("path")!!,
                        call.argument<String>("mime"),
                        call.argument<String>("name") ?: "Attachment",
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
        val intent = Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(uriFor(path), mime ?: "*/*")
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        // A chooser rather than the bare intent: with no app for the type,
        // startActivity throws and a chooser says "no apps can open this",
        // which is the difference between a crash and an answer.
        activity.startActivity(Intent.createChooser(intent, null))
    }

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
        val clip = clipboard.primaryClip ?: return emptyList()
        return copyIn(clip)
    }

    /**
     * Copy whatever a clip points at into this app's own storage.
     *
     * The URI in a clip or a drag is borrowed: the permission behind it is
     * withdrawn the moment the drag ends or the other app decides so. What
     * is kept has to be a copy, made now.
     */
    private fun copyIn(clip: ClipData): List<Map<String, Any?>> {
        val incoming = File(activity.cacheDir, "incoming").apply { mkdirs() }
        val taken = mutableListOf<Map<String, Any?>>()
        for (i in 0 until clip.itemCount) {
            val uri = clip.getItemAt(i).uri ?: continue
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
