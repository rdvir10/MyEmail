package com.rdvir.mailtree

import com.google.mlkit.nl.entityextraction.DateTimeEntity
import com.google.mlkit.nl.entityextraction.Entity
import com.google.mlkit.nl.entityextraction.EntityExtraction
import com.google.mlkit.nl.entityextraction.EntityExtractionParams
import com.google.mlkit.nl.entityextraction.EntityExtractor
import com.google.mlkit.nl.entityextraction.EntityExtractorOptions
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.TimeZone

/**
 * Dates and times in a piece of text, found on the phone by ML Kit's
 * entity extraction: for a meeting typed in a line, and for the dates in a
 * message, which the reading pane underlines.
 *
 * English only: ML Kit's extractor has no Hebrew model. The model is
 * downloaded once, the first time it is asked for, and nothing read here
 * leaves the phone.
 */
class EntityBridge(messenger: BinaryMessenger) : MethodChannel.MethodCallHandler {

    private val channel = MethodChannel(messenger, CHANNEL)

    private val extractor: EntityExtractor by lazy {
        EntityExtraction.getClient(
            EntityExtractorOptions.Builder(EntityExtractorOptions.ENGLISH).build(),
        )
    }

    init {
        channel.setMethodCallHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                // The model, downloaded where it is not here yet. True once
                // it is; false where it could not be had (no connection).
                "prepare" -> extractor.downloadModelIfNeeded()
                    .addOnSuccessListener { result.success(true) }
                    .addOnFailureListener { result.success(false) }
                "dates" -> {
                    val text = call.argument<String>("text") ?: ""
                    val now = call.argument<Number>("now")?.toLong()
                        ?: System.currentTimeMillis()
                    val params = EntityExtractionParams.Builder(text)
                        .setEntityTypesFilter(setOf(Entity.TYPE_DATE_TIME))
                        .setReferenceTime(now)
                        .setReferenceTimeZone(TimeZone.getDefault())
                        .build()
                    // Only once the model is there: annotate would otherwise
                    // wait on a download the reader never asked for.
                    extractor.downloadModelIfNeeded()
                        .onSuccessTask { extractor.annotate(params) }
                        .addOnSuccessListener { annotations ->
                            val found = mutableListOf<Map<String, Any>>()
                            for (a in annotations) {
                                for (e in a.entities) {
                                    if (e !is DateTimeEntity) continue
                                    found.add(
                                        mapOf(
                                            "start" to a.start,
                                            "end" to a.end,
                                            "text" to a.annotatedText,
                                            "at" to e.timestampMillis,
                                            "granularity" to e.dateTimeGranularity,
                                        ),
                                    )
                                }
                            }
                            result.success(found)
                        }
                        .addOnFailureListener { err ->
                            result.error("dates", err.message, null)
                        }
                }
                else -> result.notImplemented()
            }
        } catch (e: Exception) {
            result.error("dates", e.message, null)
        }
    }

    fun close() {
        channel.setMethodCallHandler(null)
        extractor.close()
    }

    companion object {
        const val CHANNEL = "mailtree/dates"
    }
}
