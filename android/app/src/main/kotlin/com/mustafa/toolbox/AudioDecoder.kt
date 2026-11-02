package com.mustafa.toolbox

import android.content.Context
import android.media.AudioFormat
import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.net.Uri
import java.io.IOException
import java.nio.ByteOrder

/** Decodes any audio file Android understands (WhatsApp .opus included) to 16 kHz mono floats for Whisper. */
object AudioDecoder {
    private const val TARGET_RATE = 16_000
    private const val TIMEOUT_US = 10_000L

    fun decode(context: Context, uri: Uri): FloatArray {
        val extractor = MediaExtractor()
        try {
            extractor.setDataSource(context, uri, null)
            val track = (0 until extractor.trackCount).firstOrNull {
                extractor.getTrackFormat(it).getString(MediaFormat.KEY_MIME)?.startsWith("audio/") == true
            } ?: throw IOException("No audio found in this file")
            extractor.selectTrack(track)
            val format = extractor.getTrackFormat(track)
            val codec = MediaCodec.createDecoderByType(format.getString(MediaFormat.KEY_MIME)!!)
            try {
                codec.configure(format, null, null, 0)
                codec.start()
                return drain(extractor, codec, format)
            } finally {
                runCatching { codec.stop() }
                codec.release()
            }
        } finally {
            extractor.release()
        }
    }

    private fun drain(extractor: MediaExtractor, codec: MediaCodec, inputFormat: MediaFormat): FloatArray {
        var sampleRate = inputFormat.getInteger(MediaFormat.KEY_SAMPLE_RATE)
        var channels = inputFormat.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
        var floatPcm = false
        val out = FloatList()
        var resampler: Resampler? = null
        val info = MediaCodec.BufferInfo()
        var inputDone = false
        var outputDone = false

        while (!outputDone) {
            if (!inputDone) {
                val inIndex = codec.dequeueInputBuffer(TIMEOUT_US)
                if (inIndex >= 0) {
                    val buf = codec.getInputBuffer(inIndex)!!
                    val size = extractor.readSampleData(buf, 0)
                    if (size < 0) {
                        codec.queueInputBuffer(inIndex, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                        inputDone = true
                    } else {
                        codec.queueInputBuffer(inIndex, 0, size, extractor.sampleTime, 0)
                        extractor.advance()
                    }
                }
            }

            val outIndex = codec.dequeueOutputBuffer(info, TIMEOUT_US)
            if (outIndex >= 0) {
                if (info.size > 0) {
                    val rs = resampler ?: Resampler(sampleRate, TARGET_RATE, out).also { resampler = it }
                    val buf = codec.getOutputBuffer(outIndex)!!.order(ByteOrder.nativeOrder())
                    buf.position(info.offset)
                    buf.limit(info.offset + info.size)
                    val ch = channels.coerceAtLeast(1)
                    if (floatPcm) {
                        val fb = buf.asFloatBuffer()
                        val frames = fb.remaining() / ch
                        for (i in 0 until frames) {
                            var sum = 0f
                            for (c in 0 until ch) sum += fb.get()
                            rs.push(sum / ch)
                        }
                    } else {
                        val sb = buf.asShortBuffer()
                        val frames = sb.remaining() / ch
                        for (i in 0 until frames) {
                            var sum = 0f
                            for (c in 0 until ch) sum += sb.get() / 32768f
                            rs.push(sum / ch)
                        }
                    }
                }
                codec.releaseOutputBuffer(outIndex, false)
                if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) outputDone = true
            } else if (outIndex == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                val f = codec.outputFormat
                sampleRate = f.getInteger(MediaFormat.KEY_SAMPLE_RATE)
                channels = f.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
                floatPcm = f.containsKey(MediaFormat.KEY_PCM_ENCODING) &&
                    f.getInteger(MediaFormat.KEY_PCM_ENCODING) == AudioFormat.ENCODING_PCM_FLOAT
            }
        }
        return out.toArray()
    }

    /** Streaming resampler: averages input when downsampling (e.g. 48k -> 16k), repeats when upsampling. */
    private class Resampler(srcRate: Int, dstRate: Int, private val out: FloatList) {
        private val step = srcRate.toDouble() / dstRate
        private var acc = 0.0
        private var n = 0
        private var pos = 0.0

        fun push(sample: Float) {
            if (step >= 1.0) {
                acc += sample
                n++
                pos += 1.0
                if (pos >= step) {
                    out.add((acc / n).toFloat())
                    acc = 0.0
                    n = 0
                    pos -= step
                }
            } else {
                pos += 1.0
                while (pos >= step) {
                    out.add(sample)
                    pos -= step
                }
            }
        }
    }

    private class FloatList {
        private var data = FloatArray(TARGET_RATE * 60)
        private var size = 0

        fun add(v: Float) {
            if (size == data.size) data = data.copyOf(size * 2)
            data[size++] = v
        }

        fun toArray(): FloatArray = data.copyOf(size)
    }
}
