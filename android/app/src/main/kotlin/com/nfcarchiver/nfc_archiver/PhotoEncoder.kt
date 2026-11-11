package com.nfcarchiver.nfc_archiver

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.ColorSpace
import android.graphics.ImageDecoder
import android.graphics.Matrix
import android.graphics.Paint
import android.media.ExifInterface
import android.os.Build
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.FileInputStream
import java.util.concurrent.Executors
import kotlin.math.max
import kotlin.math.roundToInt

/**
 * `com.nfcarchiver/photo`: decodes a photo once per size and re-encodes it as a
 * metadata-free JPEG at any longest side and quality.
 *
 * Each scaled bitmap has the EXIF orientation baked in, sits on white, and is
 * cached per maxSide so the fit search's repeated encodes at one size skip the
 * decode. All work runs on one background thread, which also owns [sessions];
 * results are posted back on the main thread.
 *
 * Errors never carry the file path: diagnostics must not log paths.
 */
class PhotoEncoder(messenger: BinaryMessenger) {
    private class DecodeFailed : Exception()
    private class NoSession : Exception()

    private class Session(val file: File, val longestSide: Int) {
        var width = 0
        var height = 0
        // Access order: iteration starts at the least recently used size.
        val cache = LinkedHashMap<Int, Bitmap>(8, 0.75f, true)
    }

    private val main = Handler(Looper.getMainLooper())
    private val sessions = HashMap<Int, Session>()
    private var nextId = 1

    init {
        MethodChannel(messenger, CHANNEL).setMethodCallHandler { call, result ->
            executor.execute {
                val reply = runCatching { handle(call) }
                main.post {
                    reply.fold(
                        onSuccess = { if (it === NOT_IMPLEMENTED) result.notImplemented() else result.success(it) },
                        onFailure = { e ->
                            when (e) {
                                is DecodeFailed, is OutOfMemoryError ->
                                    result.error("decode_failed", "The image could not be decoded", null)
                                is NoSession ->
                                    result.error("no_session", "Unknown photo session", null)
                                is IllegalArgumentException ->
                                    result.error("bad_args", "Invalid photo channel arguments", null)
                                else -> result.error("encode_failed", "The image could not be encoded", null)
                            }
                        },
                    )
                }
            }
        }
    }

    // Runs on the executor thread.
    private fun handle(call: MethodCall): Any? = when (call.method) {
        "open" -> open(call.argument<String>("path") ?: throw IllegalArgumentException())
        "encode" -> {
            val id = call.argument<Int>("id") ?: throw IllegalArgumentException()
            val maxSide = call.argument<Int>("maxSide") ?: throw IllegalArgumentException()
            val quality = call.argument<Int>("quality") ?: throw IllegalArgumentException()
            require(maxSide > 0 && quality in 1..100)
            val session = sessions[id] ?: throw NoSession()
            encode(session, maxSide, quality)
        }
        "close" -> {
            call.argument<Int>("id")?.let { sessions.remove(it) }
            null
        }
        else -> NOT_IMPLEMENTED
    }

    private fun open(path: String): Map<String, Int> {
        val file = File(path)
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeFile(file.path, bounds)
        val longest = if (bounds.outWidth > 0 && bounds.outHeight > 0) {
            max(bounds.outWidth, bounds.outHeight)
        } else if (Build.VERSION.SDK_INT >= 28) {
            headerLongestSide(file)
        } else {
            throw DecodeFailed()
        }
        val session = Session(file, longest)
        // Decode the original size now: it proves the file decodes, gives the
        // dimensions after orientation, and is the fit search's first encode.
        val original = bitmap(session, longest)
        session.width = original.width
        session.height = original.height
        val id = nextId++
        sessions[id] = session
        return mapOf("id" to id, "width" to session.width, "height" to session.height)
    }

    private fun encode(session: Session, maxSide: Int, quality: Int): ByteArray {
        // Never upscale.
        val bitmap = bitmap(session, minOf(maxSide, session.longestSide))
        val out = ByteArrayOutputStream()
        // Bitmap.compress writes a bare JFIF: no EXIF, XMP or GPS.
        if (!bitmap.compress(Bitmap.CompressFormat.JPEG, quality, out)) throw IllegalStateException()
        return out.toByteArray()
    }

    /** The oriented, white-backed bitmap whose longest side is [side], cached. */
    private fun bitmap(session: Session, side: Int): Bitmap {
        session.cache[side]?.let { return it }
        val decoded = try {
            if (Build.VERSION.SDK_INT >= 28) decodeModern(session.file, side) else decodeLegacy(session.file, side)
        } catch (e: DecodeFailed) {
            throw e
        } catch (e: Exception) {
            throw DecodeFailed()
        }
        // API 34+ decodes an Ultra HDR gain map by default, and compress()
        // would write it as a second image after EOI, with MPF and XMP.
        if (Build.VERSION.SDK_INT >= 34) decoded.gainmap = null
        val bitmap = onWhite(decoded)
        session.cache[side] = bitmap
        var total = session.cache.values.sumOf { it.allocationByteCount.toLong() }
        val iter = session.cache.entries.iterator()
        while (total > CACHE_BUDGET_BYTES && session.cache.size > 1) {
            val eldest = iter.next()
            total -= eldest.value.allocationByteCount
            iter.remove()
        }
        return bitmap
    }

    private fun headerLongestSide(file: File): Int {
        var longest = 0
        try {
            ImageDecoder.decodeBitmap(ImageDecoder.createSource(file)) { decoder, info, _ ->
                longest = max(info.size.width, info.size.height)
                decoder.setTargetSampleSize(max(1, longest / 64))
                decoder.allocator = ImageDecoder.ALLOCATOR_SOFTWARE
            }
        } catch (e: Exception) {
            throw DecodeFailed()
        }
        if (longest <= 0) throw DecodeFailed()
        return longest
    }

    /** API 28+: ImageDecoder applies EXIF orientation itself. */
    private fun decodeModern(file: File, side: Int): Bitmap =
        ImageDecoder.decodeBitmap(ImageDecoder.createSource(file)) { decoder, info, _ ->
            val w = info.size.width
            val h = info.size.height
            val scale = minOf(1.0, side.toDouble() / max(w, h))
            // Proportional target: correct whether or not the reported size
            // is already oriented.
            decoder.setTargetSize(
                max(1, (w * scale).roundToInt()),
                max(1, (h * scale).roundToInt()),
            )
            decoder.allocator = ImageDecoder.ALLOCATOR_SOFTWARE
            // The ICC profile does not survive the metadata strip, so the
            // pixels themselves must be sRGB (Display P3 sources included).
            decoder.setTargetColorSpace(ColorSpace.get(ColorSpace.Named.SRGB))
        }

    /** API < 28: BitmapFactory subsampling, exact scaling, then EXIF rotation. */
    private fun decodeLegacy(file: File, side: Int): Bitmap {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeFile(file.path, bounds)
        val w = bounds.outWidth
        val h = bounds.outHeight
        if (w <= 0 || h <= 0) throw DecodeFailed()
        val longest = max(w, h)
        var sample = 1
        while (longest / (sample * 2) >= side) sample *= 2
        val opts = BitmapFactory.Options().apply {
            inSampleSize = sample
            inPreferredConfig = Bitmap.Config.ARGB_8888
            // API 26+: convert wide-gamut sources; the ICC profile is stripped.
            if (Build.VERSION.SDK_INT >= 26) inPreferredColorSpace = ColorSpace.get(ColorSpace.Named.SRGB)
        }
        var bitmap = BitmapFactory.decodeFile(file.path, opts) ?: throw DecodeFailed()

        val scale = minOf(1.0, side.toDouble() / longest)
        val tw = max(1, (w * scale).roundToInt())
        val th = max(1, (h * scale).roundToInt())
        if (bitmap.width != tw || bitmap.height != th) {
            bitmap = Bitmap.createScaledBitmap(bitmap, tw, th, true)
        }

        val orientation = FileInputStream(file).use {
            ExifInterface(it).getAttributeInt(
                ExifInterface.TAG_ORIENTATION, ExifInterface.ORIENTATION_NORMAL,
            )
        }
        val m = Matrix()
        when (orientation) {
            ExifInterface.ORIENTATION_FLIP_HORIZONTAL -> m.setScale(-1f, 1f)
            ExifInterface.ORIENTATION_ROTATE_180 -> m.setRotate(180f)
            ExifInterface.ORIENTATION_FLIP_VERTICAL -> m.setScale(1f, -1f)
            ExifInterface.ORIENTATION_TRANSPOSE -> { m.setRotate(90f); m.postScale(-1f, 1f) }
            ExifInterface.ORIENTATION_ROTATE_90 -> m.setRotate(90f)
            ExifInterface.ORIENTATION_TRANSVERSE -> { m.setRotate(-90f); m.postScale(-1f, 1f) }
            ExifInterface.ORIENTATION_ROTATE_270 -> m.setRotate(-90f)
            else -> return bitmap
        }
        return Bitmap.createBitmap(bitmap, 0, 0, bitmap.width, bitmap.height, m, true)
    }

    /** JPEG has no alpha: Bitmap.compress would turn transparency black. */
    private fun onWhite(src: Bitmap): Bitmap {
        if (!src.hasAlpha()) return src
        val out = Bitmap.createBitmap(src.width, src.height, Bitmap.Config.ARGB_8888)
        Canvas(out).apply {
            drawColor(Color.WHITE)
            drawBitmap(src, 0f, 0f, Paint(Paint.FILTER_BITMAP_FLAG))
        }
        return out
    }

    private companion object {
        const val CHANNEL = "com.nfcarchiver/photo"
        /** A 12 MP photo alone is ~48 MB, so the newest entry is always kept. */
        const val CACHE_BUDGET_BYTES = 64L * 1024 * 1024
        val NOT_IMPLEMENTED = Any()
        /** Shared across engines, so a recreated activity doesn't leak a thread. */
        val executor = Executors.newSingleThreadExecutor()
    }
}
