package com.nfcarchiver.nfc_archiver

import android.content.ContentResolver
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.OpenableColumns
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.UUID
import java.util.concurrent.Executors

/**
 * `com.nfcarchiver/share_in`: one photo or file shared into the app through
 * `ACTION_SEND` / `ACTION_SEND_MULTIPLE`.
 *
 * [accept] copies the first `EXTRA_STREAM` item into `cacheDir/share_in/<uuid>/`
 * at once, while the intent's read grant on the content:// URI is certainly
 * valid, and keeps the copy pending until Dart calls `take`. `take` hands the
 * copy over (`{path, name, isImage, count}`) and forgets it, so a second `take`
 * returns null. A newer share replaces a pending one and deletes its copy.
 *
 * A share with nothing usable (text only, file://) is kept as unreadable, so
 * `take` answers `share_unreadable` and Dart tells the user.
 *
 * Copies and `take` run in order on one background thread, which also owns
 * [pending]; replies are posted on the main thread. Errors never carry a name
 * or path: diagnostics must not log them.
 */
class ShareInbox(context: Context, messenger: BinaryMessenger) {
    private class Item(
        val file: File,
        val name: String?,
        val isImage: Boolean,
        val count: Int,
    )

    /** A share that arrived but could not be read; `take` reports it once. */
    private object Unreadable

    private val resolver: ContentResolver = context.contentResolver
    private val root = File(context.cacheDir, DIR_NAME)
    private val main = Handler(Looper.getMainLooper())
    private val channel = MethodChannel(messenger, CHANNEL)

    // Owned by [executor]: null, an [Item] or [Unreadable].
    private var pending: Any? = null

    init {
        channel.setMethodCallHandler { call, result ->
            if (call.method != "take") {
                result.notImplemented()
                return@setMethodCallHandler
            }
            executor.execute {
                val taken = pending
                pending = null
                main.post {
                    when (taken) {
                        is Item -> result.success(
                            mapOf(
                                "path" to taken.file.absolutePath,
                                "name" to taken.name,
                                "isImage" to taken.isImage,
                                "count" to taken.count,
                            )
                        )
                        Unreadable -> result.error(
                            "share_unreadable", "The shared item could not be read.", null
                        )
                        else -> result.success(null)
                    }
                }
            }
        }
    }

    /**
     * Takes [intent] if it is a share; returns whether it did. A share the
     * app cannot use (text only, a file:// URI, an unreadable extra) is
     * still taken, as [Unreadable], so the user is told rather than left on
     * Home. Every other action is left alone.
     *
     * The extras are sender-controlled parcels and this runs in
     * onCreate/onNewIntent: nothing in here may throw.
     */
    fun accept(intent: Intent?): Boolean {
        if (intent == null) return false
        val action = intent.action
        if (action != Intent.ACTION_SEND && action != Intent.ACTION_SEND_MULTIPLE) return false
        try {
            val (uri, count) = if (action == Intent.ACTION_SEND) {
                (streamOf(intent) ?: clipUri(intent)) to 1
            } else {
                val list = streamsOf(intent)
                (list?.firstOrNull() ?: clipUri(intent)) to
                    maxOf(list?.size ?: 0, intent.clipData?.itemCount ?: 0, 1)
            }
            // file:// would let any app make us read our own private files.
            if (uri == null || uri.scheme != ContentResolver.SCHEME_CONTENT) {
                executor.execute { replacePending(Unreadable) }
                return true
            }
            val intentType = runCatching { intent.type }.getOrNull()
            executor.execute { copy(uri, intentType, count) }
            return true
        } catch (t: Throwable) {
            return false
        }
    }

    /** Tells Dart a share arrived while the app is running. */
    fun notifyAvailable() {
        main.post { channel.invokeMethod("onShareAvailable", null) }
    }

    // Runs on [executor].
    private fun copy(uri: Uri, intentType: String?, count: Int) {
        replacePending(null)
        val type = runCatching { resolver.getType(uri) }.getOrNull()
            ?: intentType?.takeUnless { it.contains('*') }
        val name = displayName(uri)
        val dir = File(root, UUID.randomUUID().toString())
        val file = File(dir, name ?: FALLBACK_NAME)
        pending = try {
            if (!dir.mkdirs()) throw java.io.IOException()
            val input = resolver.openInputStream(uri) ?: throw java.io.IOException()
            input.use { src -> file.outputStream().use { src.copyTo(it) } }
            Item(file, name, type?.startsWith("image/") == true, count)
        } catch (t: Throwable) {
            runCatching { dir.deleteRecursively() }
            Unreadable
        }
    }

    // Runs on [executor]. A newer share replaces a pending one and its copy.
    private fun replacePending(value: Any?) {
        (pending as? Item)?.let { deleteItem(it.file) }
        pending = value
    }

    private fun deleteItem(file: File) {
        file.parentFile?.deleteRecursively()
    }

    private fun displayName(uri: Uri): String? {
        val raw = runCatching {
            resolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)
                ?.use { c ->
                    val i = c.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                    if (i >= 0 && c.moveToFirst()) c.getString(i) else null
                }
        }.getOrNull()
        return sanitise(raw)
    }

    // The typed getters are broken on API 33 (they can throw on a valid
    // extra), so they are used from 34 on only; below that the untyped ones,
    // checked element by element: a sender can put anything in the list.
    @Suppress("DEPRECATION")
    private fun streamOf(intent: Intent): Uri? =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            intent.getParcelableExtra(Intent.EXTRA_STREAM, Uri::class.java)
        } else {
            intent.getParcelableExtra<android.os.Parcelable>(Intent.EXTRA_STREAM) as? Uri
        }

    @Suppress("DEPRECATION")
    private fun streamsOf(intent: Intent): List<Uri>? =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            intent.getParcelableArrayListExtra(Intent.EXTRA_STREAM, Uri::class.java)
        } else {
            intent.getParcelableArrayListExtra<android.os.Parcelable>(Intent.EXTRA_STREAM)
                ?.filterIsInstance<Uri>()
        }

    /** Some senders put the URI only in ClipData, which also carries the grant. */
    private fun clipUri(intent: Intent): Uri? {
        val clip = intent.clipData ?: return null
        return if (clip.itemCount > 0) clip.getItemAt(0)?.uri else null
    }

    companion object {
        private const val CHANNEL = "com.nfcarchiver/share_in"
        /** Matches path_provider's getTemporaryDirectory() + `share_in`. */
        private const val DIR_NAME = "share_in"
        private const val FALLBACK_NAME = "shared"
        private const val MAX_NAME_CHARS = 200

        /**
         * One thread for the whole process, like PhotoEncoder's: an engine
         * recreated with the activity gets a new inbox, not a new thread.
         */
        private val executor = Executors.newSingleThreadExecutor()

        /** The last path segment only, with no separators, NULs or dot names. */
        internal fun sanitise(raw: String?): String? {
            if (raw == null) return null
            val name = raw.substringAfterLast('/').substringAfterLast('\\')
                .filter { it != '\u0000' && !it.isISOControl() }
                .trim()
                .take(MAX_NAME_CHARS)
            return if (name.isEmpty() || name == "." || name == "..") null else name
        }
    }
}
