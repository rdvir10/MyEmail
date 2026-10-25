package com.rdvir.mailtree

import android.content.Context
import android.os.Handler
import android.os.Looper
import com.google.android.gms.tasks.Tasks
import com.google.mlkit.genai.common.DownloadCallback
import com.google.mlkit.genai.common.FeatureStatus
import com.google.mlkit.genai.common.GenAiException
import com.google.mlkit.genai.proofreading.Proofreader
import com.google.mlkit.genai.proofreading.ProofreaderOptions
import com.google.mlkit.genai.proofreading.Proofreading
import com.google.mlkit.genai.proofreading.ProofreadingRequest
import com.google.mlkit.genai.rewriting.Rewriter
import com.google.mlkit.genai.rewriting.RewriterOptions
import com.google.mlkit.genai.rewriting.Rewriting
import com.google.mlkit.genai.rewriting.RewritingRequest
import com.google.mlkit.genai.summarization.Summarization
import com.google.mlkit.genai.summarization.SummarizationRequest
import com.google.mlkit.genai.summarization.Summarizer
import com.google.mlkit.genai.summarization.SummarizerOptions
import com.google.mlkit.nl.smartreply.SmartReply
import com.google.mlkit.nl.smartreply.SmartReplySuggestionResult
import com.google.mlkit.nl.smartreply.TextMessage
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.ExecutionException
import java.util.concurrent.Executors

/**
 * The phone's own AI, as far as the app uses it, with nothing leaving the
 * phone: a summary of a long message, a draft proofread or rewritten
 * (Gemini Nano through Android's AICore, ML Kit's GenAI APIs, which the
 * Pixel 9 Pro has and the Tab S9+ does not), and short replies suggested
 * for a message (ML Kit's Smart Reply, its model inside the app, English
 * only).
 *
 * The models answer slowly and their calls block, so each call runs on a
 * worker thread and answers on the main one. A feature's client is made the
 * first time it is asked for and kept for the app's life.
 */
class AiBridge(
    private val context: Context,
    messenger: BinaryMessenger,
) : MethodChannel.MethodCallHandler {

    init {
        MethodChannel(messenger, CHANNEL).setMethodCallHandler(this)
    }

    private val worker = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())

    private val summarizer: Summarizer by lazy {
        Summarization.getClient(
            SummarizerOptions.builder(context)
                .setInputType(SummarizerOptions.InputType.ARTICLE)
                .setOutputType(SummarizerOptions.OutputType.THREE_BULLETS)
                .setLanguage(SummarizerOptions.Language.ENGLISH)
                .setLongInputAutoTruncationEnabled(true)
                .build(),
        )
    }

    private val proofreader: Proofreader by lazy {
        Proofreading.getClient(
            ProofreaderOptions.builder(context)
                .setInputType(ProofreaderOptions.InputType.KEYBOARD)
                .setLanguage(ProofreaderOptions.Language.ENGLISH)
                .build(),
        )
    }

    private val rewriters = HashMap<String, Rewriter>()

    private fun rewriter(style: String): Rewriter = rewriters.getOrPut(style) {
        Rewriting.getClient(
            RewriterOptions.builder(context)
                .setOutputType(
                    when (style) {
                        "shorter" -> RewriterOptions.OutputType.SHORTEN
                        "friendlier" -> RewriterOptions.OutputType.FRIENDLY
                        "formal" -> RewriterOptions.OutputType.PROFESSIONAL
                        "longer" -> RewriterOptions.OutputType.ELABORATE
                        else -> RewriterOptions.OutputType.REPHRASE
                    },
                )
                .setLanguage(RewriterOptions.Language.ENGLISH)
                .build(),
        )
    }

    private val smartReply by lazy { SmartReply.getClient() }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "status" -> run(result) { statusOf(call.argument<String>("feature") ?: "") }
            "download" -> run(result) { download(call.argument<String>("feature") ?: "") }
            "summarize" -> run(result) {
                summarizer.runInference(
                    SummarizationRequest.builder(call.argument<String>("text") ?: "").build(),
                ).get().summary
            }
            "proofread" -> run(result) {
                proofreader.runInference(
                    ProofreadingRequest.builder(call.argument<String>("text") ?: "").build(),
                ).get().results.map { it.text }
            }
            "rewrite" -> run(result) {
                rewriter(call.argument<String>("style") ?: "rephrase").runInference(
                    RewritingRequest.builder(call.argument<String>("text") ?: "").build(),
                ).get().results.map { it.text }
            }
            "suggestReplies" -> run(result) {
                suggestReplies(call.argument<List<Map<String, Any?>>>("messages") ?: emptyList())
            }
            else -> result.notImplemented()
        }
    }

    /** [work] on the worker thread, its answer or failure back on the main one. */
    private fun run(result: MethodChannel.Result, work: () -> Any?) {
        worker.execute {
            try {
                val answer = work()
                main.post { result.success(answer) }
            } catch (e: Throwable) {
                val cause = if (e is ExecutionException) e.cause ?: e else e
                val code = if (cause is GenAiException) "ai-${cause.errorCode}" else "ai-failed"
                main.post { result.error(code, cause.message ?: cause.toString(), null) }
            }
        }
    }

    /**
     * Whether [feature] can be used here: "available", "downloadable" (its
     * model fetched first), "downloading", or "unavailable" (no AICore, or a
     * phone it does not run on).
     */
    private fun statusOf(feature: String): String {
        if (feature == "smartReply") return "available"
        val status = try {
            when (feature) {
                "summarize" -> summarizer.checkFeatureStatus().get()
                "proofread" -> proofreader.checkFeatureStatus().get()
                "rewrite" -> rewriter("rephrase").checkFeatureStatus().get()
                else -> FeatureStatus.UNAVAILABLE
            }
        } catch (e: Throwable) {
            FeatureStatus.UNAVAILABLE
        }
        return when (status) {
            FeatureStatus.AVAILABLE -> "available"
            FeatureStatus.DOWNLOADABLE -> "downloadable"
            FeatureStatus.DOWNLOADING -> "downloading"
            else -> "unavailable"
        }
    }

    /** [feature]'s model fetched, waiting until it has been. */
    private fun download(feature: String): Boolean {
        val quiet = object : DownloadCallback {
            override fun onDownloadStarted(bytesToDownload: Long) {}
            override fun onDownloadProgress(totalBytesDownloaded: Long) {}
            override fun onDownloadCompleted() {}
            override fun onDownloadFailed(e: GenAiException) {}
        }
        when (feature) {
            "summarize" -> summarizer.downloadFeature(quiet).get()
            "proofread" -> proofreader.downloadFeature(quiet).get()
            "rewrite" -> rewriter("rephrase").downloadFeature(quiet).get()
            else -> return false
        }
        return true
    }

    /**
     * Up to three short replies to the last of [messages], oldest first,
     * each `text`, `time` (ms), `local` (the account's own) and `sender`.
     * None where the language is not English or nothing fits.
     */
    private fun suggestReplies(messages: List<Map<String, Any?>>): List<String> {
        val conversation = messages.map { m ->
            val text = m["text"] as? String ?: ""
            val time = (m["time"] as? Number)?.toLong() ?: System.currentTimeMillis()
            if (m["local"] == true) {
                TextMessage.createForLocalUser(text, time)
            } else {
                TextMessage.createForRemoteUser(text, time, m["sender"] as? String ?: "them")
            }
        }
        if (conversation.isEmpty()) return emptyList()
        val answer = Tasks.await(smartReply.suggestReplies(conversation))
        return if (answer.status == SmartReplySuggestionResult.STATUS_SUCCESS) {
            answer.suggestions.map { it.text }
        } else {
            emptyList()
        }
    }

    companion object {
        const val CHANNEL = "mailtree/ai"
    }
}
