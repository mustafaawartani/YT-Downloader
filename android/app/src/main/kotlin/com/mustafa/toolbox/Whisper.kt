package com.mustafa.toolbox

import java.io.IOException

fun interface ProgressListener {
    fun onProgress(percent: Int)
}

object WhisperLib {
    init {
        System.loadLibrary("voicejni")
    }

    external fun initContext(modelPath: String): Long
    external fun freeContext(contextPtr: Long)
    external fun transcribe(
        contextPtr: Long,
        samples: FloatArray,
        language: String,
        translate: Boolean,
        threads: Int,
        listener: ProgressListener?,
    ): ByteArray?
}

/** Keeps the on-device Whisper model loaded between voice notes. */
object WhisperEngine {
    private var ctx = 0L
    private var loadedPath: String? = null

    @Synchronized
    fun transcribe(modelPath: String, samples: FloatArray, language: String, onProgress: (Int) -> Unit): String {
        if (ctx == 0L || loadedPath != modelPath) {
            if (ctx != 0L) WhisperLib.freeContext(ctx)
            ctx = WhisperLib.initContext(modelPath)
            loadedPath = modelPath
            if (ctx == 0L) throw IOException("Could not load the speech model. Try downloading it again.")
        }
        val threads = Runtime.getRuntime().availableProcessors().coerceIn(1, 4)
        val bytes = WhisperLib.transcribe(ctx, samples, language, false, threads) { onProgress(it) }
            ?: throw IOException("Transcription failed")
        return String(bytes, Charsets.UTF_8).trim()
    }
}
