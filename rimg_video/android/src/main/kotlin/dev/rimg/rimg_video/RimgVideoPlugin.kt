package dev.rimg.rimg_video

import android.content.Context
import android.media.MediaCodecInfo
import android.media.MediaCodecList
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaMetadataRetriever
import android.net.Uri
import android.os.Build
import android.util.Log
import androidx.annotation.OptIn
import androidx.media3.common.Effect
import androidx.media3.common.MediaItem
import androidx.media3.common.MimeTypes
import androidx.media3.common.util.Clock
import androidx.media3.common.util.UnstableApi
import androidx.media3.datasource.DataSourceBitmapLoader
import androidx.media3.exoplayer.source.DefaultMediaSourceFactory
import androidx.media3.effect.FrameDropEffect
import androidx.media3.effect.Presentation
import androidx.media3.transformer.Composition
import androidx.media3.transformer.DefaultAssetLoaderFactory
import androidx.media3.transformer.DefaultDecoderFactory
import androidx.media3.transformer.DefaultEncoderFactory
import androidx.media3.transformer.EditedMediaItem
import androidx.media3.transformer.EditedMediaItemSequence
import androidx.media3.transformer.Effects
import androidx.media3.transformer.ExportException
import androidx.media3.transformer.ExportResult
import androidx.media3.transformer.ProgressHolder
import androidx.media3.transformer.Transformer
import androidx.media3.transformer.VideoEncoderSettings
import io.flutter.embedding.engine.plugins.FlutterPlugin
import java.io.File
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext

/** Video compression with Media3 Transformer (hardware encoder, HDR tone-mapping, rotation). */
class RimgVideoPlugin : FlutterPlugin, RimgVideoHostApi {
  private lateinit var context: Context
  private var flutterApi: RimgVideoFlutterApi? = null
  private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)

  /** Running exports by job id. Touched only on the main thread. */
  private val running = HashMap<String, Running>()
  private val cancelled = HashSet<String>()

  private class Running(val transformer: Transformer, val output: File, val onCancel: () -> Unit)

  override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
    context = binding.applicationContext
    RimgVideoHostApi.setUp(binding.binaryMessenger, this)
    flutterApi = RimgVideoFlutterApi(binding.binaryMessenger)
  }

  override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
    RimgVideoHostApi.setUp(binding.binaryMessenger, null)
    running.keys.toList().forEach { cancel(it) }
    flutterApi = null
    scope.cancel()
  }

  override suspend fun probe(path: String): VideoInfoMsg =
    withContext(Dispatchers.IO) { Probe.read(path) }

  @OptIn(UnstableApi::class)
  override suspend fun compress(request: VideoRequestMsg): VideoResultMsg {
    val input = File(request.inputPath)
    if (!input.canRead()) throw RimgVideoError("input", "Cannot read ${request.inputPath}")
    val output = File(request.outputPath)
    withContext(Dispatchers.IO) {
      output.parentFile?.mkdirs()
      output.delete()
    }

    val effects = mutableListOf<Effect>()
    if (request.maxFps > 0) {
      // Drops frames above maxFps; slo-mo keeps its playback timing.
      effects.add(FrameDropEffect.createDefaultFrameDropEffect(request.maxFps.toFloat()))
    }
    // Output size is given in display orientation; Transformer applies rotation first.
    effects.add(
      Presentation.createForWidthAndHeight(
        request.width.toInt(), request.height.toInt(), Presentation.LAYOUT_SCALE_TO_FIT))

    val isHdr = withContext(Dispatchers.IO) { runCatching { Probe.read(input.path).isHdr }.getOrDefault(false) }
    // HDR -> SDR: GL tone-mapping works on most phones; some GPUs (and the
    // emulator) can't do it, so fall back to the decoder's tone-mapper, then
    // to treating the video as SDR (flatter colours, but the export succeeds).
    val hdrModes = if (isHdr) listOf(
      Composition.HDR_MODE_TONE_MAP_HDR_TO_SDR_USING_OPEN_GL,
      Composition.HDR_MODE_TONE_MAP_HDR_TO_SDR_USING_MEDIACODEC,
      Composition.HDR_MODE_EXPERIMENTAL_FORCE_INTERPRET_HDR_AS_SDR,
    ) else listOf(Composition.HDR_MODE_KEEP_HDR)

    // Some devices (and the emulator) can't encode HEVC at this size; Media3
    // would silently shrink the video, so use H.264 instead.
    var codec = request.codec
    if (codec == VideoCodecMsg.HEVC &&
      !encoderSupports(MimeTypes.VIDEO_H265, request.width.toInt(), request.height.toInt())) {
      Log.w("rimg_video", "No HEVC encoder for ${request.width}x${request.height}; using H.264")
      codec = VideoCodecMsg.H264
    }

    val jobId = request.jobId
    cancelled.remove(jobId)
    var lastError: RimgVideoError? = null
    for (mode in hdrModes) {
      if (jobId in cancelled) throw RimgVideoError("cancelled", "cancelled")
      try {
        export(request, codec, input, output, effects, mode)
        lastError = null
        break
      } catch (e: RimgVideoError) {
        withContext(Dispatchers.IO) { output.delete() }
        lastError = e
        // Only processing/decoding failures are worth retrying with another HDR mode.
        if (e.code == "cancelled" || jobId in cancelled || !isHdr || e.code == "io") break
        Log.w("rimg_video", "HDR mode $mode failed (${e.message}); trying next")
      }
    }
    cancelled.remove(jobId)
    lastError?.let { throw it }

    runCatching { flutterApi?.onProgress(jobId, 1.0) }
    // Report what was actually written (display orientation), not what was asked for.
    val out = withContext(Dispatchers.IO) { Probe.read(output.path) }
    val sideways = out.rotation % 180L != 0L
    return VideoResultMsg(
      width = if (sideways) out.height else out.width,
      height = if (sideways) out.width else out.height,
      durationMs = out.durationMs,
      fileBytes = out.fileBytes,
      videoCodec = codec,
    )
  }

  @OptIn(UnstableApi::class)
  private suspend fun export(
    request: VideoRequestMsg,
    codec: VideoCodecMsg,
    input: File,
    output: File,
    effects: List<Effect>,
    hdrMode: Int,
  ) {
    val item = EditedMediaItem.Builder(MediaItem.fromUri(Uri.fromFile(input)))
      .setEffects(Effects(listOf(), effects))
      .build()
    val composition = Composition.Builder(EditedMediaItemSequence.Builder(item).build())
      .setHdrMode(hdrMode)
      .build()

    val mime = if (codec == VideoCodecMsg.HEVC) MimeTypes.VIDEO_H265 else MimeTypes.VIDEO_H264
    val settings = VideoEncoderSettings.Builder().setBitrate(request.videoBitrate.toInt())
    if (request.constantBitrate) settings.setBitrateMode(MediaCodecInfo.EncoderCapabilities.BITRATE_MODE_CBR)
    val encoders = DefaultEncoderFactory.Builder(context)
      .setRequestedVideoEncoderSettings(settings.build())
      // If the device encoder rejects the exact size/bitrate, use the nearest it supports.
      .setEnableFallback(true)
      .build()

    val jobId = request.jobId
    var progressJob: Job? = null
    try {
      suspendCancellableCoroutine<Unit> { cont ->
        val transformer = Transformer.Builder(context)
          .setVideoMimeType(mime)
          .setEncoderFactory(encoders)
          // If the hardware decoder rejects the input, try the next (e.g. software) decoder.
          .setAssetLoaderFactory(
            DefaultAssetLoaderFactory(
              context,
              DefaultDecoderFactory.Builder(context).setEnableDecoderFallback(true).build(),
              Clock.DEFAULT,
              DefaultMediaSourceFactory(context),
              DataSourceBitmapLoader(context),
            ))
          // Audio: Transformer copies AAC through untouched and transcodes anything else.
          .addListener(object : Transformer.Listener {
            override fun onCompleted(composition: Composition, result: ExportResult) {
              if (running.remove(jobId) != null && cont.isActive) cont.resume(Unit)
            }

            override fun onError(composition: Composition, result: ExportResult, e: ExportException) {
              if (running.remove(jobId) != null && cont.isActive) {
                cont.resumeWithException(RimgVideoError(errorCode(e), "${e.errorCodeName}: ${e.message}"))
              }
            }
          })
          .build()

        running[jobId] = Running(transformer, output) {
          if (cont.isActive) cont.resumeWithException(RimgVideoError("cancelled", "cancelled"))
        }
        transformer.start(composition, output.path)

        progressJob = scope.launch {
          val holder = ProgressHolder()
          while (isActive) {
            delay(250)
            val r = running[jobId] ?: break
            if (r.transformer.getProgress(holder) == Transformer.PROGRESS_STATE_AVAILABLE) {
              runCatching { flutterApi?.onProgress(jobId, holder.progress / 100.0) }
            }
          }
        }
        cont.invokeOnCancellation { scope.launch { cancel(jobId) } }
      }
    } finally {
      progressJob?.cancel()
    }
  }

  override fun cancel(jobId: String) {
    cancelled.add(jobId)
    val r = running.remove(jobId) ?: return
    r.transformer.cancel()
    r.output.delete()
    r.onCancel()
  }

  /** True if some hardware or software encoder for [mime] accepts [w]x[h] (either orientation). */
  private fun encoderSupports(mime: String, w: Int, h: Int): Boolean =
    MediaCodecList(MediaCodecList.REGULAR_CODECS).codecInfos.any { info ->
      info.isEncoder && info.supportedTypes.any { it.equals(mime, ignoreCase = true) } &&
        runCatching {
          val caps = info.getCapabilitiesForType(mime).videoCapabilities
          caps.isSizeSupported(w, h) || caps.isSizeSupported(h, w)
        }.getOrDefault(false)
    }

  @OptIn(UnstableApi::class)
  private fun errorCode(e: ExportException): String = when (e.errorCode / 1000) {
    2 -> "io" // ERROR_CODE_IO_*
    3 -> "input" // ERROR_CODE_DECODER_*, DECODING_FORMAT_UNSUPPORTED
    else -> if (e.errorCode == ExportException.ERROR_CODE_UNSPECIFIED) "input" else "encoder"
  }
}

/** Reads basic facts about a video file with the platform's extractor. */
internal object Probe {
  private const val TRANSFER_ST2084 = 6 // MediaFormat.COLOR_TRANSFER_ST2084 (PQ / HDR10 / Dolby Vision)
  private const val TRANSFER_HLG = 7 // MediaFormat.COLOR_TRANSFER_HLG (iPhone HDR)

  fun read(path: String): VideoInfoMsg {
    val file = File(path)
    if (!file.canRead()) throw RimgVideoError("input", "Cannot read $path")

    var mime = ""
    var fps = 0.0
    var hasAudio = false
    var audioBitrate = 0L
    var transfer = 0
    var hasVideo = false
    val ex = MediaExtractor()
    try {
      ex.setDataSource(path)
      for (i in 0 until ex.trackCount) {
        val f = ex.getTrackFormat(i)
        val m = f.getString(MediaFormat.KEY_MIME) ?: continue
        if (m.startsWith("video/") && !hasVideo) {
          hasVideo = true
          mime = m
          if (f.containsKey(MediaFormat.KEY_FRAME_RATE)) {
            fps = runCatching { f.getInteger(MediaFormat.KEY_FRAME_RATE).toDouble() }
              .getOrElse { f.getFloat(MediaFormat.KEY_FRAME_RATE).toDouble() }
          }
          if (f.containsKey(MediaFormat.KEY_COLOR_TRANSFER)) transfer = f.getInteger(MediaFormat.KEY_COLOR_TRANSFER)
        } else if (m.startsWith("audio/") && !hasAudio) {
          hasAudio = true
          if (f.containsKey(MediaFormat.KEY_BIT_RATE)) audioBitrate = f.getInteger(MediaFormat.KEY_BIT_RATE).toLong()
        }
      }
    } catch (e: Exception) {
      throw RimgVideoError("input", "Not a readable video: ${e.message}")
    } finally {
      ex.release()
    }
    if (!hasVideo) throw RimgVideoError("input", "No video track in $path")

    val mmr = MediaMetadataRetriever()
    try {
      mmr.setDataSource(path)
      fun key(k: Int) = mmr.extractMetadata(k)?.toLongOrNull() ?: 0L
      val durationMs = key(MediaMetadataRetriever.METADATA_KEY_DURATION)
      if (fps <= 0 && Build.VERSION.SDK_INT >= 28 && durationMs > 0) {
        fps = key(MediaMetadataRetriever.METADATA_KEY_VIDEO_FRAME_COUNT) * 1000.0 / durationMs
      }
      if (transfer == 0 && Build.VERSION.SDK_INT >= 30) {
        transfer = key(MediaMetadataRetriever.METADATA_KEY_COLOR_TRANSFER).toInt()
      }
      var bitrate = key(MediaMetadataRetriever.METADATA_KEY_BITRATE)
      if (bitrate <= 0 && durationMs > 0) bitrate = file.length() * 8000 / durationMs
      return VideoInfoMsg(
        width = key(MediaMetadataRetriever.METADATA_KEY_VIDEO_WIDTH),
        height = key(MediaMetadataRetriever.METADATA_KEY_VIDEO_HEIGHT),
        rotation = key(MediaMetadataRetriever.METADATA_KEY_VIDEO_ROTATION),
        durationMs = durationMs,
        bitrate = bitrate,
        frameRate = if (fps > 0) fps else 30.0,
        videoCodec = mime,
        hasAudio = hasAudio,
        audioBitrate = audioBitrate,
        isHdr = transfer == TRANSFER_ST2084 || transfer == TRANSFER_HLG,
        fileBytes = file.length(),
      )
    } catch (e: RimgVideoError) {
      throw e
    } catch (e: Exception) {
      throw RimgVideoError("input", "Not a readable video: ${e.message}")
    } finally {
      mmr.release()
    }
  }
}
