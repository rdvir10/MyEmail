package com.rdvir.mailtree

import android.app.Activity
import android.content.Intent
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.speech.tts.TextToSpeech
import android.speech.tts.UtteranceProgressListener
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.Locale

/**
 * Read Aloud, in Android's own voice: whatever text-to-speech engine the
 * phone has, on the phone, with no network.
 *
 * One piece of a message at a time. Dart decides what each piece is and
 * which language it is in, and hears back as each one finishes, so
 * pausing, skipping and the language of the next piece are all its
 * business. This side only speaks, stops, and says what it has.
 */
class SpeechBridge(
    private val activity: Activity,
    messenger: BinaryMessenger,
) : MethodChannel.MethodCallHandler {

    private val channel =
        MethodChannel(messenger, "mailtree/speech").also { it.setMethodCallHandler(this) }

    private val main = Handler(Looper.getMainLooper())

    private var tts: TextToSpeech? = null
    private var ready = false

    /** What was asked while the engine was starting, run once it has. */
    private val waiting = mutableListOf<(TextToSpeech?) -> Unit>()

    /**
     * The engine, started the first time it is wanted: it takes a moment,
     * and most messages are never read aloud. Null to [then] where the
     * phone has none that works.
     */
    private fun engine(then: (TextToSpeech?) -> Unit) {
        val existing = tts
        if (existing != null && ready) {
            then(existing)
            return
        }
        waiting.add(then)
        if (existing != null) return
        tts = TextToSpeech(activity.applicationContext) { status ->
            main.post {
                ready = status == TextToSpeech.SUCCESS
                val engine = tts
                if (ready && engine != null) {
                    engine.setOnUtteranceProgressListener(progress)
                } else {
                    engine?.shutdown()
                    tts = null
                }
                val run = waiting.toList()
                waiting.clear()
                for (each in run) each(if (ready) tts else null)
            }
        }
    }

    private val progress = object : UtteranceProgressListener() {
        override fun onStart(utteranceId: String) {}

        override fun onDone(utteranceId: String) {
            main.post { channel.invokeMethod("done", utteranceId) }
        }

        @Deprecated("Still called by engines that predate the other")
        override fun onError(utteranceId: String) {
            main.post { channel.invokeMethod("error", utteranceId) }
        }

        override fun onError(utteranceId: String, errorCode: Int) {
            main.post { channel.invokeMethod("error", utteranceId) }
        }

        /** Stopped or skipped on purpose: not finished, and not a failure. */
        override fun onStop(utteranceId: String, interrupted: Boolean) {}
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "speak" -> {
                val id = call.argument<String>("id") ?: ""
                val text = call.argument<String>("text") ?: ""
                val language = call.argument<String>("language")
                val rate = call.argument<Double>("rate") ?: 1.0
                engine { tts ->
                    if (tts == null) {
                        result.error("unavailable", "This phone has no text-to-speech.", null)
                        return@engine
                    }
                    if (!language.isNullOrEmpty()) {
                        tts.language = Locale.forLanguageTag(language)
                    }
                    tts.setSpeechRate(rate.toFloat())
                    // In place of whatever was being read: a skip or a new
                    // start is never meant to wait for the rest of the old.
                    val queued = tts.speak(text, TextToSpeech.QUEUE_FLUSH, Bundle(), id)
                    result.success(queued == TextToSpeech.SUCCESS)
                }
            }
            "stop" -> {
                tts?.stop()
                result.success(null)
            }
            "hasLanguage" -> {
                val language = call.argument<String>("language") ?: ""
                engine { tts ->
                    val answer = tts?.isLanguageAvailable(Locale.forLanguageTag(language))
                        ?: TextToSpeech.LANG_NOT_SUPPORTED
                    result.success(answer >= TextToSpeech.LANG_AVAILABLE)
                }
            }
            // Where a voice for another language is installed.
            "openSettings" -> {
                try {
                    activity.startActivity(
                        Intent("com.android.settings.TTS_SETTINGS")
                            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
                    )
                    result.success(true)
                } catch (e: Exception) {
                    result.success(false)
                }
            }
            else -> result.notImplemented()
        }
    }

    /** With the activity: an engine left running holds its voice. */
    fun shutdown() {
        tts?.stop()
        tts?.shutdown()
        tts = null
        ready = false
        waiting.clear()
    }
}
