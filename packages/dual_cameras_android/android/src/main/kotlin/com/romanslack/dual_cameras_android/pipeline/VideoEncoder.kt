package com.romanslack.dual_cameras_android.pipeline

import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.os.Handler
import android.os.HandlerThread
import android.view.Surface

/**
 * H.264 (default) / HEVC surface-input encoder. The GL thread draws composited
 * frames onto [inputSurface] and stamps PTS via `eglPresentationTimeANDROID`;
 * output is drained on a dedicated thread and handed to the [Muxer].
 *
 * Tuned for sustained dual-cam thermal headroom (ARCHITECTURE.md §6): CBR, no
 * B-frames, 1s GOP, realtime priority. Surface-input encoders never fire
 * `onInputBufferAvailable` — we only drain output and end via
 * `signalEndOfInputStream()` (§12).
 */
class VideoEncoder(
    private val width: Int,
    private val height: Int,
    private val bitRate: Int,
    private val frameRate: Int,
    hevc: Boolean,
    private val muxer: Muxer,
) {
    private val mime =
        if (hevc) MediaFormat.MIMETYPE_VIDEO_HEVC else MediaFormat.MIMETYPE_VIDEO_AVC

    private val codec: MediaCodec = MediaCodec.createEncoderByType(mime)
    val inputSurface: Surface

    private val drainThread = HandlerThread("dcr-video-drain").apply { start() }
    private val handler = Handler(drainThread.looper)
    private val bufferInfo = MediaCodec.BufferInfo()

    @Volatile private var endOfStream = false

    init {
        val format = MediaFormat.createVideoFormat(mime, width, height).apply {
            setInteger(
                MediaFormat.KEY_COLOR_FORMAT,
                MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface,
            )
            setInteger(MediaFormat.KEY_BIT_RATE, bitRate)
            setInteger(MediaFormat.KEY_FRAME_RATE, frameRate)
            setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, 1)
            setInteger(
                MediaFormat.KEY_BITRATE_MODE,
                MediaCodecInfo.EncoderCapabilities.BITRATE_MODE_CBR,
            )
            // SDR BT.709 limited range — tag the file so playback is correct (§principle 4).
            setInteger(MediaFormat.KEY_COLOR_STANDARD, MediaFormat.COLOR_STANDARD_BT709)
            setInteger(MediaFormat.KEY_COLOR_RANGE, MediaFormat.COLOR_RANGE_LIMITED)
            setInteger(MediaFormat.KEY_COLOR_TRANSFER, MediaFormat.COLOR_TRANSFER_SDR_VIDEO)
        }
        codec.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
        inputSurface = codec.createInputSurface()
    }

    fun start() {
        codec.start()
        scheduleDrain()
    }

    private fun scheduleDrain() {
        handler.post(::drain)
    }

    private fun drain() {
        while (true) {
            val index = codec.dequeueOutputBuffer(bufferInfo, DRAIN_TIMEOUT_US)
            when {
                index == MediaCodec.INFO_TRY_AGAIN_LATER -> {
                    if (!endOfStream) handler.postDelayed(::drain, 4)
                    return
                }
                index == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                    muxer.addVideoTrack(codec.outputFormat)
                }
                index >= 0 -> {
                    val buf = codec.getOutputBuffer(index)
                    if (buf != null) muxer.writeVideo(buf, bufferInfo)
                    codec.releaseOutputBuffer(index, false)
                    if (bufferInfo.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) {
                        return
                    }
                }
            }
        }
    }

    /** Called from the GL thread after the last frame is swapped. */
    fun signalEndOfStream() {
        endOfStream = true
        try {
            codec.signalEndOfInputStream()
        } catch (_: Throwable) {
        }
        scheduleDrain()
    }

    fun release() {
        try {
            codec.stop()
        } catch (_: Throwable) {
        }
        codec.release()
        inputSurface.release()
        drainThread.quitSafely()
    }

    companion object {
        private const val DRAIN_TIMEOUT_US = 10_000L
    }
}
