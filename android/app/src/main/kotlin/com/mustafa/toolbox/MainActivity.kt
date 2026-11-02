package com.mustafa.toolbox

import android.content.ContentValues
import android.content.Intent
import android.media.MediaPlayer
import android.net.Uri
import android.os.Bundle
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.provider.DocumentsContract
import android.provider.MediaStore
import android.provider.OpenableColumns
import android.util.Log
import android.webkit.MimeTypeMap
import androidx.core.content.IntentCompat
import com.google.android.gms.tasks.Tasks
import com.google.mlkit.common.model.DownloadConditions
import com.google.mlkit.nl.translate.TranslateLanguage
import com.google.mlkit.nl.translate.Translation
import com.google.mlkit.nl.translate.Translator
import com.google.mlkit.nl.translate.TranslatorOptions
import com.yausername.ffmpeg.FFmpeg
import com.yausername.youtubedl_android.YoutubeDL
import com.yausername.youtubedl_android.YoutubeDLRequest
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.IOException
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors
import java.util.concurrent.locks.ReentrantReadWriteLock
import kotlin.concurrent.read
import kotlin.concurrent.write

/**
 * Native side of the toolbox. Three channels:
 *  - toolbox/ytdlp  : yt-dlp (youtubedl-android: embedded Python + FFmpeg + QuickJS)
 *  - toolbox/voice  : on-device Whisper, ML Kit translation, voice-notes folder, playback
 *  - toolbox/share  : files / links shared into the app from WhatsApp, YouTube, ...
 */
class MainActivity : FlutterActivity() {
    private val io = Executors.newCachedThreadPool()
    private val main = Handler(Looper.getMainLooper())

    private lateinit var ytCh: MethodChannel
    private lateinit var voiceCh: MethodChannel
    private lateinit var shareCh: MethodChannel

    private val cancelled = ConcurrentHashMap.newKeySet<String>()
    // Updating swaps the yt-dlp files on disk: never do it while a command is running.
    private val ytLock = ReentrantReadWriteLock()
    private val ytInitLock = Any()
    @Volatile private var ytReady = false

    private var player: MediaPlayer? = null
    private var folderResult: MethodChannel.Result? = null
    private val translators = HashMap<String, Translator>()

    private var pendingShare: Map<String, Any?>? = null
    private var dartListening = false

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger
        ytCh = MethodChannel(messenger, "toolbox/ytdlp").also { it.setMethodCallHandler(::onYtDlp) }
        voiceCh = MethodChannel(messenger, "toolbox/voice").also { it.setMethodCallHandler(::onVoice) }
        shareCh = MethodChannel(messenger, "toolbox/share").also { it.setMethodCallHandler(::onShare) }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (BuildConfig.SELF_TEST) intent?.getStringExtra("toolbox_selftest")?.let { url -> io.execute { runSelfTest(url) } }
        if (savedInstanceState == null) handleShareIntent(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        handleShareIntent(intent)
    }

    // ------------------------------------------------------------------ helpers

    private fun <T> background(result: MethodChannel.Result, work: () -> T) {
        io.execute {
            try {
                val value = work()
                main.post { result.success(value) }
            } catch (e: Throwable) {
                Log.e(TAG, "native call failed", e)
                main.post { result.error("error", describe(e), null) }
            }
        }
    }

    /** "Class: message" for the whole cause chain, so errors on screen are actionable. */
    private fun describe(e: Throwable): String {
        val parts = mutableListOf<String>()
        var t: Throwable? = e
        while (t != null && parts.size < 4) {
            parts += "${t.javaClass.simpleName}: ${t.message ?: ""}".trim()
            t = t.cause.takeIf { it !== t }
        }
        return parts.joinToString(" ← ").take(600)
    }

    private fun uriOf(source: String): Uri =
        if (source.startsWith("content:") || source.startsWith("file:")) Uri.parse(source) else Uri.fromFile(File(source))

    private fun displayName(uri: Uri): String? = runCatching {
        contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use {
            if (it.moveToFirst()) it.getString(0) else null
        }
    }.getOrNull()

    /** Copies a content uri into the app cache so Dart / Python can read it as a file. */
    private fun copyToCache(uri: Uri, dir: File): File {
        dir.mkdirs()
        var name = displayName(uri) ?: uri.lastPathSegment?.substringAfterLast('/') ?: "file"
        name = name.replace(Regex("[\\\\/:*?\"<>|]"), "_")
        if (!name.contains('.')) {
            val ext = MimeTypeMap.getSingleton().getExtensionFromMimeType(contentResolver.getType(uri) ?: "")
            if (ext != null) name = "$name.$ext"
        }
        val out = File(dir, name)
        contentResolver.openInputStream(uri)?.use { input -> out.outputStream().use { input.copyTo(it) } }
            ?: throw IOException("Can't open $name")
        return out
    }

    // ------------------------------------------------------------------ yt-dlp

    private fun ensureYtDlp() {
        if (ytReady) return
        synchronized(ytInitLock) {
            if (ytReady) return
            YoutubeDL.getInstance().init(applicationContext)
            FFmpeg.getInstance().init(applicationContext)
            ytReady = true
        }
    }

    private fun onYtDlp(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "init" -> background(result) { ensureYtDlp(); null }
            "run" -> {
                val jobId = call.argument<String>("jobId")!!
                val args = call.argument<List<String>>("args")!!
                background(result) { runYtDlp(jobId, args) }
            }
            "cancel" -> {
                val jobId = call.argument<String>("jobId")!!
                cancelled.add(jobId)
                runCatching { YoutubeDL.getInstance().destroyProcessById(jobId) }
                result.success(null)
            }
            "version" -> background(result) {
                ensureYtDlp()
                YoutubeDL.getInstance().versionName(applicationContext)
                    ?: YoutubeDL.getInstance().version(applicationContext) ?: "?"
            }
            "update" -> background(result) {
                ensureYtDlp()
                val status = ytLock.write {
                    YoutubeDL.getInstance().updateYoutubeDL(applicationContext, YoutubeDL.UpdateChannel._STABLE)
                }
                when (status) {
                    YoutubeDL.UpdateStatus.DONE -> "Updated to the latest yt-dlp"
                    YoutubeDL.UpdateStatus.ALREADY_UP_TO_DATE -> "yt-dlp is already up to date"
                    else -> "Done"
                }
            }
            "saveToDownloads" -> background(result) {
                saveToDownloads(File(call.argument<String>("path")!!), call.argument<String>("folder")!!)
            }
            else -> result.notImplemented()
        }
    }

    private fun runYtDlp(jobId: String, args: List<String>, onLine: ((String) -> Unit)? = null): Map<String, Any?> {
        ensureYtDlp()
        if (cancelled.remove(jobId)) return mapOf("cancelled" to true)
        val request = YoutubeDLRequest(emptyList<String>()).addCommands(args)
        return try {
            val response = ytLock.read {
                YoutubeDL.getInstance().execute(request, jobId, false) { _, _, line ->
                    if (onLine != null) onLine(line)
                    else main.post { ytCh.invokeMethod("line", mapOf("jobId" to jobId, "line" to line)) }
                }
            }
            if (cancelled.remove(jobId)) mapOf("cancelled" to true)
            else mapOf("exitCode" to response.exitCode, "out" to response.out, "err" to response.err)
        } catch (e: YoutubeDL.CanceledException) {
            cancelled.remove(jobId)
            mapOf("cancelled" to true)
        } catch (e: Exception) {
            Log.w(TAG, "yt-dlp failed: ${describe(e)}")
            if (cancelled.remove(jobId)) mapOf("cancelled" to true)
            else mapOf("exitCode" to 1, "out" to "", "err" to describe(e))
        }
    }

    /**
     * CI-only end-to-end check of the native download path on an emulator
     * (adb shell am start ... --es toolbox_selftest <url>). Logs "TOOLBOX_SELFTEST ..." lines.
     */
    private fun runSelfTest(url: String) {
        var pass = 0
        var fail = 0
        fun step(name: String, block: () -> String) {
            try {
                val detail = block()
                pass++
                Log.i(TAG, "TOOLBOX_SELFTEST PASS $name: $detail")
            } catch (e: Throwable) {
                fail++
                Log.e(TAG, "TOOLBOX_SELFTEST FAIL $name: ${describe(e)}", e)
            }
        }
        fun check(r: Map<String, Any?>): String {
            if (r["exitCode"] != 0) throw IOException("exit=${r["exitCode"]} err=${r["err"]}")
            return (r["out"] as String).take(200)
        }
        val dir = File(cacheDir, "selftest").apply { deleteRecursively(); mkdirs() }
        step("init") { ensureYtDlp(); "ok" }
        step("version") { check(runYtDlp("st-v", listOf("--version"))) }
        step("info") { check(runYtDlp("st-i", listOf("--no-warnings", "-J", "--flat-playlist", url))).take(80) }
        step("download-mp3") {
            val files = mutableListOf<String>()
            check(runYtDlp("st-d", listOf(
                "--no-warnings", "-P", "home:${dir.absolutePath}", "-o", "%(title).80B.%(ext)s",
                "--no-simulate", "--print", "after_move:@@F|%(filepath)s",
                "-f", "ba/b", "-x", "--audio-format", "mp3", url,
            )) { line -> if (line.startsWith("@@F|")) files += line.removePrefix("@@F|").trim() })
            val f = File(files.single())
            if (!f.exists() || f.length() < 1000 || f.extension != "mp3") throw IOException("bad output $f (${f.length()} bytes)")
            "${f.name} ${f.length()} bytes"
        }
        step("save-to-downloads") {
            val f = dir.listFiles()!!.first { it.extension == "mp3" }
            saveToDownloads(f, "Toolbox/SelfTest")
        }
        Log.i(TAG, "TOOLBOX_SELFTEST DONE pass=$pass fail=$fail")
    }

    /** Publishes a finished file into the public Download/<folder> via MediaStore (no permission needed). */
    private fun saveToDownloads(file: File, folder: String): String {
        val ext = file.extension.lowercase()
        val mime = MimeTypeMap.getSingleton().getMimeTypeFromExtension(ext) ?: "application/octet-stream"
        val values = ContentValues().apply {
            put(MediaStore.Downloads.DISPLAY_NAME, file.name)
            put(MediaStore.Downloads.MIME_TYPE, mime)
            put(MediaStore.Downloads.RELATIVE_PATH, "${Environment.DIRECTORY_DOWNLOADS}/$folder")
            put(MediaStore.Downloads.IS_PENDING, 1)
        }
        val uri = contentResolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values)
            ?: throw IOException("Couldn't create the file in Downloads")
        try {
            contentResolver.openOutputStream(uri)?.use { out -> file.inputStream().use { it.copyTo(out) } }
                ?: throw IOException("Couldn't write to Downloads")
            values.clear()
            values.put(MediaStore.Downloads.IS_PENDING, 0)
            contentResolver.update(uri, values, null, null)
        } catch (e: Exception) {
            contentResolver.delete(uri, null, null)
            throw e
        }
        val name = displayName(uri) ?: file.name
        file.delete()
        return "Download/$folder/$name"
    }

    // ------------------------------------------------------------------ voice

    private fun onVoice(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "transcribe" -> {
                val id = call.argument<String>("id")!!
                val source = call.argument<String>("source")!!
                val model = call.argument<String>("model")!!
                val language = call.argument<String>("language") ?: "es"
                background(result) {
                    val samples = AudioDecoder.decode(applicationContext, uriOf(source))
                    if (samples.size < 4_000) throw IOException("The audio is empty or too short")
                    var last = -1
                    WhisperEngine.transcribe(model, samples, language) { p ->
                        if (p != last) {
                            last = p
                            main.post { voiceCh.invokeMethod("progress", mapOf("id" to id, "p" to p)) }
                        }
                    }
                }
            }
            "prepareTranslation" -> {
                val from = call.argument<String>("from") ?: "es"
                background(result) {
                    for (to in listOf("en", "ar")) {
                        if (to != from) Tasks.await(translator(from, to).downloadModelIfNeeded(DownloadConditions.Builder().build()))
                    }
                    null
                }
            }
            "translate" -> {
                val text = call.argument<String>("text")!!
                val from = call.argument<String>("from") ?: "es"
                val to = call.argument<String>("to")!!
                background(result) {
                    if (from == to) text
                    else {
                        val t = translator(from, to)
                        Tasks.await(t.downloadModelIfNeeded(DownloadConditions.Builder().build()))
                        Tasks.await(t.translate(text))
                    }
                }
            }
            "pickFolder" -> {
                folderResult?.success(null)
                folderResult = result
                val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE)
                    .putExtra(DocumentsContract.EXTRA_INITIAL_URI, VoiceFolder.initialUri())
                @Suppress("DEPRECATION")
                startActivityForResult(intent, REQ_FOLDER)
            }
            "hasFolderAccess" -> {
                val uri = Uri.parse(call.argument<String>("uri")!!)
                result.success(contentResolver.persistedUriPermissions.any { it.uri == uri && it.isReadPermission })
            }
            "listFolder" -> {
                val uri = Uri.parse(call.argument<String>("uri")!!)
                background(result) { VoiceFolder.list(applicationContext, uri) }
            }
            "copyToCache" -> {
                val source = call.argument<String>("source")!!
                background(result) { copyToCache(uriOf(source), File(cacheDir, "upload")).absolutePath }
            }
            "play" -> {
                stopPlayback()
                try {
                    player = MediaPlayer().apply {
                        setDataSource(this@MainActivity, uriOf(call.argument<String>("source")!!))
                        setOnCompletionListener { stopPlayback() }
                        prepare()
                        start()
                    }
                    result.success(null)
                } catch (e: Exception) {
                    stopPlayback()
                    result.error("play", e.message, null)
                }
            }
            "stop" -> {
                stopPlayback()
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    private fun translator(from: String, to: String): Translator = synchronized(translators) {
        translators.getOrPut("$from>$to") {
            val src = TranslateLanguage.fromLanguageTag(from) ?: throw IOException("Unsupported language: $from")
            val dst = TranslateLanguage.fromLanguageTag(to) ?: throw IOException("Unsupported language: $to")
            Translation.getClient(TranslatorOptions.Builder().setSourceLanguage(src).setTargetLanguage(dst).build())
        }
    }

    private fun stopPlayback() {
        player?.release()
        player = null
    }

    @Deprecated("Deprecated in Java")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != REQ_FOLDER) return
        val uri = data?.data
        if (uri != null) {
            runCatching { contentResolver.takePersistableUriPermission(uri, Intent.FLAG_GRANT_READ_URI_PERMISSION) }
        }
        folderResult?.success(uri?.toString())
        folderResult = null
    }

    override fun onStop() {
        super.onStop()
        stopPlayback()
    }

    // ------------------------------------------------------------------ sharing

    private fun onShare(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "takePending" -> {
                dartListening = true
                result.success(pendingShare)
                pendingShare = null
            }
            else -> result.notImplemented()
        }
    }

    /** Voice note / exported chat from WhatsApp, or a link from YouTube & co. */
    private fun handleShareIntent(intent: Intent?) {
        intent ?: return
        val uris: List<Uri> = when (intent.action) {
            Intent.ACTION_SEND -> listOfNotNull(IntentCompat.getParcelableExtra(intent, Intent.EXTRA_STREAM, Uri::class.java))
            Intent.ACTION_SEND_MULTIPLE ->
                IntentCompat.getParcelableArrayListExtra(intent, Intent.EXTRA_STREAM, Uri::class.java).orEmpty()
            else -> return
        }
        val text = intent.getStringExtra(Intent.EXTRA_TEXT)
        intent.action = null
        io.execute {
            val dir = File(cacheDir, "shared/${System.currentTimeMillis()}")
            File(cacheDir, "shared").listFiles()?.filter { it != dir }?.forEach { it.deleteRecursively() }
            val files = uris.mapNotNull { runCatching { copyToCache(it, dir).absolutePath }.getOrNull() }
            val payload = mapOf("files" to files, "text" to if (files.isEmpty()) text else null)
            main.post {
                if (dartListening) shareCh.invokeMethod("shared", payload) else pendingShare = payload
            }
        }
    }

    companion object {
        private const val TAG = "Toolbox"
        private const val REQ_FOLDER = 4242
    }
}
