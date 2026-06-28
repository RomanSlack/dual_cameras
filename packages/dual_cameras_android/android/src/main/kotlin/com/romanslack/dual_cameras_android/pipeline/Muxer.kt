package com.romanslack.dual_cameras_android.pipeline

import android.media.MediaCodec
import android.media.MediaFormat
import android.media.MediaMuxer
import java.nio.ByteBuffer

/**
 * Thread-safe wrapper over [MediaMuxer] for the two encoder drain threads.
 *
 * Enforces the corrupt-file rules from ARCHITECTURE.md §12: `addTrack` only from
 * an encoder's output-format-changed; `start()` only after BOTH tracks are
 * added; all calls serialized under one lock; `stop()` only after both streams
 * signalled end-of-stream.
 */
class Muxer(outputPath: String, private val expectAudio: Boolean) {

    private val muxer = MediaMuxer(outputPath, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
    private val lock = Any()

    private var videoTrack = -1
    private var audioTrack = -1
    private var started = false
    private var stopped = false

    fun addVideoTrack(format: MediaFormat) = synchronized(lock) {
        if (videoTrack < 0) videoTrack = muxer.addTrack(format)
        maybeStart()
    }

    fun addAudioTrack(format: MediaFormat) = synchronized(lock) {
        if (audioTrack < 0) audioTrack = muxer.addTrack(format)
        maybeStart()
    }

    private fun maybeStart() {
        if (started) return
        val videoReady = videoTrack >= 0
        val audioReady = !expectAudio || audioTrack >= 0
        if (videoReady && audioReady) {
            muxer.start()
            started = true
        }
    }

    fun writeVideo(buffer: ByteBuffer, info: MediaCodec.BufferInfo) =
        write(videoTrack, buffer, info)

    fun writeAudio(buffer: ByteBuffer, info: MediaCodec.BufferInfo) =
        write(audioTrack, buffer, info)

    private fun write(track: Int, buffer: ByteBuffer, info: MediaCodec.BufferInfo) =
        synchronized(lock) {
            if (!started || stopped || track < 0) return
            // Codec config buffers carry CSD; that already went via addTrack().
            if (info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG != 0) return
            if (info.size <= 0) return
            buffer.position(info.offset)
            buffer.limit(info.offset + info.size)
            muxer.writeSampleData(track, buffer, info)
        }

    fun stopAndRelease() = synchronized(lock) {
        if (stopped) return
        stopped = true
        try {
            if (started) muxer.stop()
        } catch (_: Throwable) {
            // Avoid masking the original error on a short/empty track.
        } finally {
            muxer.release()
        }
    }
}
