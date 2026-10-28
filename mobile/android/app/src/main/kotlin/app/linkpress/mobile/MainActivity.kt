package app.linkpress.mobile

import android.Manifest
import android.content.ContentValues
import android.content.Intent
import android.content.pm.PackageManager
import android.media.MediaScannerConnection
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.os.StatFs
import android.provider.MediaStore
import android.provider.OpenableColumns
import com.yausername.youtubedl_android.YoutubeDL
import com.yausername.youtubedl_android.YoutubeDLRequest
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import java.io.File
import java.io.FileInputStream

class MainActivity : FlutterActivity() {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val main = Handler(Looper.getMainLooper())
    private val initLock = Mutex()
    private var ytdlpReady = false
    private var channel: MethodChannel? = null
    private var progressSink: EventChannel.EventSink? = null
    private var pendingPick: MethodChannel.Result? = null
    private var initialShare: Map<String, Any?>? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger
        EventChannel(messenger, "linkpress/progress").setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink) { progressSink = events }
            override fun onCancel(arguments: Any?) { progressSink = null }
        })
        channel = MethodChannel(messenger, "linkpress/native").also { ch ->
            ch.setMethodCallHandler { call, result ->
                when (call.method) {
                    "initialShare" -> { result.success(initialShare); initialShare = null }
                    "initYtdlp" -> background(result) { ensureYtdlp(); null }
                    "ytdlpInfo" -> background(result) { ytdlpInfo(call.argument<String>("url")!!) }
                    "ytdlpDownload" -> background(result) {
                        ytdlpDownload(call.argument("jobId")!!, call.argument("url")!!, call.argument("format")!!, call.argument("dir")!!)
                    }
                    "ytdlpCancel" -> { YoutubeDL.getInstance().destroyProcessById(call.argument<String>("jobId")!!); result.success(null) }
                    "ytdlpUpdate" -> background(result) {
                        ensureYtdlp()
                        YoutubeDL.getInstance().updateYoutubeDL(applicationContext, YoutubeDL.UpdateChannel._STABLE)?.name
                    }
                    "pickVideos" -> pickVideos(result)
                    "saveToGallery" -> background(result) {
                        saveToGallery(call.argument("path")!!, call.argument("name")!!, call.argument("folder")!!)
                    }
                    "openVideo" -> {
                        val intent = Intent(Intent.ACTION_VIEW).setDataAndType(Uri.parse(call.argument("uri")), "video/mp4")
                            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                        startActivity(intent)
                        result.success(null)
                    }
                    "freeBytes" -> result.success(StatFs(call.argument<String>("path")!!).availableBytes)
                    "keepAlive" -> { askNotificationPermission(); KeepAliveService.update(this, call.argument("text") ?: ""); result.success(null) }
                    "stopKeepAlive" -> { KeepAliveService.stop(this); result.success(null) }
                    else -> result.notImplemented()
                }
            }
        }
        initialShare = shareFrom(intent)
    }

    // A share while the app is already open arrives here instead of in onCreate.
    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        shareFrom(intent)?.let { channel?.invokeMethod("onShared", it) }
    }

    private fun shareFrom(intent: Intent?): Map<String, Any?>? {
        if (intent == null) return null
        if (intent.action != Intent.ACTION_SEND && intent.action != Intent.ACTION_SEND_MULTIPLE) return null
        val text = intent.getStringExtra(Intent.EXTRA_TEXT)
        val uris = mutableListOf<Uri>()
        if (intent.action == Intent.ACTION_SEND_MULTIPLE) {
            @Suppress("DEPRECATION")
            intent.getParcelableArrayListExtra<Uri>(Intent.EXTRA_STREAM)?.let { uris.addAll(it) }
        } else {
            @Suppress("DEPRECATION")
            (intent.getParcelableExtra<Uri>(Intent.EXTRA_STREAM))?.let { uris.add(it) }
        }
        if (text == null && uris.isEmpty()) return null
        return mapOf("text" to text, "files" to uris.map { describe(it) })
    }

    private fun <T> background(result: MethodChannel.Result, work: suspend () -> T) {
        scope.launch {
            try {
                val value = work()
                main.post { result.success(value) }
            } catch (e: YoutubeDL.CanceledException) {
                main.post { result.error("canceled", "Canceled", null) }
            } catch (e: Throwable) {
                main.post { result.error("failed", cleanError(e.message ?: e.toString()), null) }
            }
        }
    }

    // First launch unpacks Python + yt-dlp (a few seconds); later launches are instant.
    private suspend fun ensureYtdlp() = initLock.withLock {
        if (!ytdlpReady) {
            YoutubeDL.getInstance().init(applicationContext)
            ytdlpReady = true
        }
    }

    private suspend fun ytdlpInfo(url: String): String {
        ensureYtdlp()
        val req = YoutubeDLRequest(url).apply {
            addOption("-J")
            addOption("--flat-playlist")
            addOption("--no-warnings")
        }
        return YoutubeDL.getInstance().execute(req).out
    }

    private suspend fun ytdlpDownload(jobId: String, url: String, format: String, dir: String): String {
        ensureYtdlp()
        val req = YoutubeDLRequest(url).apply {
            addOption("--no-playlist")
            addOption("--no-mtime")
            addOption("--continue")
            addOption("--restrict-filenames")
            addOption("--newline")
            addOption("-f", format)
            addOption("-o", "$dir/%(id)s.f%(format_id)s.%(ext)s")
            // --print implies --quiet; --progress keeps the progress lines the callback parses.
            addOption("--progress")
            addOption("--print", "after_move:LPFILE|%(filepath)s")
        }
        val resp = YoutubeDL.getInstance().execute(req, jobId) { progress, eta, _ ->
            main.post { progressSink?.success(mapOf("jobId" to jobId, "progress" to progress.toDouble(), "eta" to eta)) }
        }
        val path = resp.out.lines().firstOrNull { it.startsWith("LPFILE|") }?.removePrefix("LPFILE|")?.trim()
        return path ?: File(dir).listFiles()?.filter { !it.name.endsWith(".part") }?.maxByOrNull { it.lastModified() }?.absolutePath
            ?: throw IllegalStateException("yt-dlp finished without an output file")
    }

    // Opens the system picker; content:// URIs go straight to ffmpeg-kit (no copy, so 10 GB files are fine).
    private fun pickVideos(result: MethodChannel.Result) {
        pendingPick?.success(emptyList<Any>())
        pendingPick = result
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = "video/*"
            putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true)
        }
        @Suppress("DEPRECATION")
        startActivityForResult(intent, PICK_REQUEST)
    }

    @Deprecated("Deprecated in Java")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        @Suppress("DEPRECATION")
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != PICK_REQUEST) return
        val res = pendingPick ?: return
        pendingPick = null
        if (resultCode != RESULT_OK || data == null) return res.success(emptyList<Any>())
        val uris = mutableListOf<Uri>()
        data.clipData?.let { clip -> for (i in 0 until clip.itemCount) uris.add(clip.getItemAt(i).uri) }
        if (uris.isEmpty()) data.data?.let { uris.add(it) }
        // Keep read access after a restart, so a saved queue can resume.
        for (u in uris) runCatching { contentResolver.takePersistableUriPermission(u, Intent.FLAG_GRANT_READ_URI_PERMISSION) }
        res.success(uris.map { describe(it) })
    }

    private fun describe(uri: Uri): Map<String, Any?> {
        var name = uri.lastPathSegment ?: "video"
        var size = 0L
        runCatching {
            contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE), null, null, null)?.use { c ->
                if (c.moveToFirst()) {
                    c.getString(0)?.let { name = it }
                    if (!c.isNull(1)) size = c.getLong(1)
                }
            }
        }
        return mapOf("uri" to uri.toString(), "name" to name, "size" to size)
    }

    // Writes into Movies/LinkPress or Download/LinkPress so the Samsung Gallery shows it right away.
    private suspend fun saveToGallery(path: String, name: String, folder: String): String = withContext(Dispatchers.IO) {
        val src = File(path)
        val isDownloads = folder.equals("Download", ignoreCase = true)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val collection = if (isDownloads) MediaStore.Downloads.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
            else MediaStore.Video.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
            val values = ContentValues().apply {
                put(MediaStore.MediaColumns.DISPLAY_NAME, name)
                put(MediaStore.MediaColumns.MIME_TYPE, "video/mp4")
                put(MediaStore.MediaColumns.RELATIVE_PATH, (if (isDownloads) Environment.DIRECTORY_DOWNLOADS else Environment.DIRECTORY_MOVIES) + "/LinkPress")
                put(MediaStore.MediaColumns.IS_PENDING, 1)
            }
            val uri = contentResolver.insert(collection, values) ?: throw IllegalStateException("Could not create the gallery file")
            try {
                contentResolver.openOutputStream(uri)!!.use { out -> FileInputStream(src).use { it.copyTo(out, 1 shl 20) } }
                values.clear()
                values.put(MediaStore.MediaColumns.IS_PENDING, 0)
                contentResolver.update(uri, values, null, null)
            } catch (e: Throwable) {
                contentResolver.delete(uri, null, null)
                throw e
            }
            src.delete()
            uri.toString()
        } else {
            val base = Environment.getExternalStoragePublicDirectory(if (isDownloads) Environment.DIRECTORY_DOWNLOADS else Environment.DIRECTORY_MOVIES)
            val dir = File(base, "LinkPress").apply { mkdirs() }
            var dest = File(dir, name)
            var n = 2
            while (dest.exists()) dest = File(dir, name.replace(Regex("\\.mp4$"), " ($n).mp4")).also { n++ }
            src.copyTo(dest)
            src.delete()
            MediaScannerConnection.scanFile(applicationContext, arrayOf(dest.absolutePath), arrayOf("video/mp4"), null)
            Uri.fromFile(dest).toString()
        }
    }

    private fun askNotificationPermission() {
        if (Build.VERSION.SDK_INT >= 33 && checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) {
            requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), NOTIFY_REQUEST)
        }
    }

    private fun cleanError(msg: String): String =
        msg.lines().lastOrNull { it.contains("ERROR", ignoreCase = true) }?.substringAfter("ERROR:")?.trim() ?: msg.lines().first()

    companion object {
        private const val PICK_REQUEST = 4101
        private const val NOTIFY_REQUEST = 4102
    }
}
