package com.romanslack.dual_cameras_android.pipeline

import android.Manifest
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.AudioTimestamp
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.media.MediaRecorder
import android.os.Build
import androidx.annotation.RequiresPermission

/**
 * Mic capture ([AudioRecord]) -> AAC ([MediaCodec]) on its own thread.
 *
 * The crux is A/V sync (ARCHITECTURE.md §5): audio PTS is derived from
 * `AudioRecord.getTimestamp(TIMEBASE_MONOTONIC)` minus the shared [startNanos]
 * — the SAME CLOCK_MONOTONIC base the GL thread uses to stamp video frames — so
 * the two tracks line up. PTS is clamped monotonic per track.
 */
class AudioEncoder(
    private val muxer: Muxer,
    private val startNanos: Long,
    private val sampleRate: Int = 48_000,
) {
    private val channelConfig = AudioFormat.CHANNEL_IN_MONO
    private val audioFormat = AudioFormat.ENCODING_PCM_16BIT
    private val minBuffer = AudioRecord.getMinBufferSize(sampleRate, channelConfig, audioFormat)
    private val readSize = maxOf(minBuffer, 4096)

    private val codec: MediaCodec =
        MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_AUDIO_AAC)
    private var record: AudioRecord? = null

    @Volatile private var running = false
    private var thread: Thread? = null
    private val bufferInfo = MediaCodec.BufferInfo()
    private var lastPtsUs = -1L

    // Anchor from the first getTimestamp(): frames -> nanoTime mapping.
    private var anchorFrames = -1L
    private var anchorNanos = 0L
    private var totalFramesRead = 0L

    @RequiresPermission(Manifest.permission.RECORD_AUDIO)
    fun start() {
        val format = MediaFormat.createAudioFormat(
            MediaFormat.MIMETYPE_AUDIO_AAC, sampleRate, 1,
        ).apply {
            setInteger(
                MediaFormat.KEY_AAC_PROFILE,
                MediaCodecInfo.CodecProfileLevel.AACObjectLC,
            )
            setInteger(MediaFormat.KEY_BIT_RATE, 128_000)
            setInteger(MediaFormat.KEY_MAX_INPUT_SIZE, readSize)
        }
        codec.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
        codec.start()

        record = AudioRecord(
            MediaRecorder.AudioSource.CAMCORDER,
            sampleRate, channelConfig, audioFormat, readSize * 2,
        )
        record?.startRecording()
        running = true
        thread = Thread(::loop, "dcr-audio").apply { start() }
    }

    private fun loop() {
        val rec = record ?: return
        val pcm = ByteArray(readSize)
        while (running) {
            val read = rec.read(pcm, 0, pcm.size)
            if (read <= 0) continue
            val ptsUs = computePtsUs(rec, framesInRead = read / 2)
            queueInput(pcm, read, ptsUs, endOfStream = false)
            drain()
        }
        // Flush EOS.
        queueInput(pcm, 0, computePtsUs(rec, 0), endOfStream = true)
        drain()
    }

    private fun computePtsUs(rec: AudioRecord, framesInRead: Int): Long {
        val chunkStartFrame = totalFramesRead
        totalFramesRead += framesInRead

        var ptsNs: Long
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            val ts = AudioTimestamp()
            if (rec.getTimestamp(ts, AudioTimestamp.TIMEBASE_MONOTONIC) ==
                AudioRecord.SUCCESS
            ) {
                if (anchorFrames < 0) {
                    anchorFrames = ts.framePosition
                    anchorNanos = ts.nanoTime
                }
                ptsNs = anchorNanos +
                    (chunkStartFrame - anchorFrames) * 1_000_000_000L / sampleRate
            } else {
                ptsNs = startNanos + chunkStartFrame * 1_000_000_000L / sampleRate
            }
        } else {
            ptsNs = startNanos + chunkStartFrame * 1_000_000_000L / sampleRate
        }
        var ptsUs = (ptsNs - startNanos) / 1000
        if (ptsUs <= lastPtsUs) ptsUs = lastPtsUs + 1
        lastPtsUs = ptsUs
        return ptsUs
    }

    private fun queueInput(pcm: ByteArray, size: Int, ptsUs: Long, endOfStream: Boolean) {
        val index = codec.dequeueInputBuffer(10_000L)
        if (index < 0) return
        val buf = codec.getInputBuffer(index) ?: return
        buf.clear()
        if (size > 0) buf.put(pcm, 0, size)
        val flags = if (endOfStream) MediaCodec.BUFFER_FLAG_END_OF_STREAM else 0
        codec.queueInputBuffer(index, 0, size, ptsUs, flags)
    }

    private fun drain() {
        while (true) {
            val index = codec.dequeueOutputBuffer(bufferInfo, 0)
            when {
                index == MediaCodec.INFO_TRY_AGAIN_LATER -> return
                index == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED ->
                    muxer.addAudioTrack(codec.outputFormat)
                index >= 0 -> {
                    val buf = codec.getOutputBuffer(index)
                    if (buf != null) muxer.writeAudio(buf, bufferInfo)
                    codec.releaseOutputBuffer(index, false)
                    if (bufferInfo.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) return
                }
            }
        }
    }

    fun stop() {
        running = false
        thread?.join(500)
        try {
            record?.stop()
        } catch (_: Throwable) {
        }
        record?.release()
        record = null
        try {
            codec.stop()
        } catch (_: Throwable) {
        }
        codec.release()
    }
}
