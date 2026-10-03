package com.example.aamina_mobile

import android.app.Activity
import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context
import android.content.Intent
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioRecord
import android.media.AudioTrack
import android.media.MediaRecorder
import android.media.projection.MediaProjection
import android.media.projection.MediaProjectionManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.PowerManager
import android.provider.Settings
import android.util.Log
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.IOException
import java.net.Socket
import java.util.concurrent.atomic.AtomicReference
import kotlin.concurrent.thread
import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.sin

class MainActivity : FlutterActivity() {
    private val channelName = "aamina/audio"
    private val requestCodeProjection = 1001
    private val sampleRate = 44100

    private var projectionManager: MediaProjectionManager? = null
    private var mediaProjection: MediaProjection? = null

    private var audioRecord: AudioRecord? = null
    private var captureThread: Thread? = null
    private var toneThread: Thread? = null
    @Volatile private var isCapturing = false
    @Volatile private var currentMode = "internal"
    @Volatile private var audioSocket: Socket? = null
    @Volatile private var targetHost = "127.0.0.1"
    private var targetPort = 5000

    /// Silent local player used during "Mute phone" mode: it replays the
    /// captured stream locally at volume 0 so the internal-audio pipeline
    /// stays active while nothing comes out of the phone speaker.
    private var silentPlayer: AudioTrack? = null

    /// Holds the Flutter result for "internal" mode until the user
    /// grants/denies the MediaProjection permission dialog.
    private var pendingStartResult: MethodChannel.Result? = null

    /// "Mute phone" flag for the in-flight internal-mode start request.
    private var pendingMutePhone = false

    /// Phone STREAM_MUSIC volume saved before muting, restored on stop.
    private var savedVolume: Int? = null

    /// Latest per-second average captured sample level (diagnostics).
    private val lastCaptureAvg = AtomicReference(0.0)

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        projectionManager = getSystemService(MEDIA_PROJECTION_SERVICE) as MediaProjectionManager

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel("aamina_channel", "Aamina Audio", NotificationManager.IMPORTANCE_LOW)
            val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            manager.createNotificationChannel(channel)
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "startCapture" -> {
                        val mode = call.argument<String>("mode") ?: "internal"
                        val host = call.argument<String>("host") ?: "127.0.0.1"
                        val port = (call.argument<Int>("port") ?: 5000)
                        targetHost = host
                        targetPort = port
                        if (mode == "internal") {
                            // Async: result is answered after the user grants
                            // the MediaProjection dialog (see onActivityResult).
                            pendingStartResult?.error("CANCELLED", "Superseded by a new start request", null)
                            pendingStartResult = result
                            // Applied AFTER the user grants the dialog.
                            pendingMutePhone = call.argument<Boolean>("mutePhone") ?: false
                            startMode(mode)
                        } else {
                            try {
                                startMode(mode)
                                result.success(true)
                            } catch (e: SecurityException) {
                                Log.e("Aamina", "startCapture failed (permission)", e)
                                result.error("PERMISSION", e.message, null)
                            } catch (e: Exception) {
                                Log.e("Aamina", "startCapture failed", e)
                                result.error("START_FAILED", e.message, null)
                            }
                        }
                    }
                    "stopCapture" -> {
                        stopCapture()
                        result.success(true)
                    }
                    "getVolume" -> {
                        result.success(getStreamVolume())
                    }
                    "setVolume" -> {
                        val volume = call.argument<Int>("volume") ?: 0
                        setStreamVolume(volume)
                        result.success(true)
                    }
                    "getVolume" -> {
                        val audioManager = getSystemService(Context.AUDIO_SERVICE) as AudioManager
                        result.success(audioManager.getStreamVolume(AudioManager.STREAM_MUSIC))
                    }
                    "setVolume" -> {
                        val volume = call.argument<Int>("volume") ?: 0
                        val audioManager = getSystemService(Context.AUDIO_SERVICE) as AudioManager
                        val max = audioManager.getStreamMaxVolume(AudioManager.STREAM_MUSIC)
                        audioManager.setStreamVolume(AudioManager.STREAM_MUSIC, volume.coerceIn(0, max), 0)
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun startMode(mode: String) {
        if (isCapturing) stopCapture()
        currentMode = mode

        when (mode) {
            "mic" -> startMicCapture()
            "tone" -> startToneStream()
            else -> requestProjectionPermission()
        }
    }

    private fun requestProjectionPermission() {
        ensureBatteryOptimizationDisabled()
        val serviceIntent = Intent(this, AudioCaptureService::class.java)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) startForegroundService(serviceIntent) else startService(serviceIntent)
        startActivityForResult(projectionManager!!.createScreenCaptureIntent(), requestCodeProjection)
    }

    private fun ensureBatteryOptimizationDisabled() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return
        val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
        if (pm.isIgnoringBatteryOptimizations(packageName)) return
        try {
            val intent = Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS)
            intent.data = Uri.parse("package:$packageName")
            startActivity(intent)
        } catch (e: Exception) {
            Log.w("Aamina", "Battery optimization screen open failed", e)
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == requestCodeProjection) {
            if (resultCode == Activity.RESULT_OK && data != null) {
                mediaProjection = projectionManager!!.getMediaProjection(resultCode, data)
                try {
                    startInternalAudioCapture()
                    // Mute the phone speaker but keep the stream flowing:
                    // route captured audio to a silent local player too.
                    if (pendingMutePhone) {
                        savedVolume = getStreamVolume()
                        // EXPERIMENTAL: does capture survive STREAM_MUSIC=0
                        // on this device? Verified via the mute probe below.
                        setStreamVolume(0)
                        runMuteVolumeProbe()
                        startSilentPlayer()
                    }
                    pendingMutePhone = false
                    pendingStartResult?.success(true)
                } catch (e: Exception) {
                    Log.e("Aamina", "Internal capture start failed", e)
                    pendingMutePhone = false
                    pendingStartResult?.error("START_FAILED", e.message, null)
                } finally {
                    pendingStartResult = null
                }
            } else {
                Log.w("Aamina", "MediaProjection permission denied by user")
                pendingMutePhone = false
                stopCapture()
                pendingStartResult?.error("DENIED", "Screen-capture permission was denied", null)
                pendingStartResult = null
            }
        }
    }

    private fun startInternalAudioCapture() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            Log.e("Aamina", "Internal audio requires Android 10+")
            return
        }
        stopAudioPipelineOnly()

        try {
            val minBuffer = AudioRecord.getMinBufferSize(sampleRate, AudioFormat.CHANNEL_IN_STEREO, AudioFormat.ENCODING_PCM_16BIT)
            val config = android.media.AudioPlaybackCaptureConfiguration.Builder(mediaProjection!!)
                .addMatchingUsage(AudioAttributes.USAGE_MEDIA)
                .addMatchingUsage(AudioAttributes.USAGE_GAME)
                .addMatchingUsage(AudioAttributes.USAGE_UNKNOWN)
                .build()

            audioRecord = AudioRecord.Builder()
                .setAudioFormat(
                    AudioFormat.Builder()
                        .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                        .setSampleRate(sampleRate)
                        .setChannelMask(AudioFormat.CHANNEL_IN_STEREO)
                        .build()
                )
                .setBufferSizeInBytes(minBuffer * 2)
                .setAudioPlaybackCaptureConfig(config)
                .build()

            if (audioRecord?.state != AudioRecord.STATE_INITIALIZED) {
                Log.e("Aamina", "Internal AudioRecord init failed")
                return
            }

            audioRecord?.startRecording()
            isCapturing = true
            captureThread = spawnRecordThread(minBuffer)
        } catch (e: Exception) {
            Log.e("Aamina", "Internal capture failed", e)
            isCapturing = false
        }
    }

    private fun startMicCapture() {
        stopAudioPipelineOnly()
        try {
            val minBuffer = AudioRecord.getMinBufferSize(sampleRate, AudioFormat.CHANNEL_IN_STEREO, AudioFormat.ENCODING_PCM_16BIT)
            audioRecord = AudioRecord(
                MediaRecorder.AudioSource.MIC,
                sampleRate,
                AudioFormat.CHANNEL_IN_STEREO,
                AudioFormat.ENCODING_PCM_16BIT,
                minBuffer * 2
            )

            if (audioRecord?.state != AudioRecord.STATE_INITIALIZED) {
                Log.e("Aamina", "MIC AudioRecord init failed")
                return
            }

            audioRecord?.startRecording()
            isCapturing = true
            captureThread = spawnRecordThread(minBuffer)
        } catch (e: Exception) {
            Log.e("Aamina", "Mic capture failed", e)
            isCapturing = false
        }
    }

    private fun spawnRecordThread(bufferSize: Int): Thread {
        return thread(start = true) {
            val buffer = ByteArray(bufferSize)
            var bytes = 0L
            var levelSum = 0L
            var levelCount = 0L
            var peak = 0
            var last = System.currentTimeMillis()

            try {
                while (isCapturing && !Thread.currentThread().isInterrupted) {
                    val rec = audioRecord ?: break
                    val read = rec.read(buffer, 0, buffer.size, AudioRecord.READ_BLOCKING)
                    if (read <= 0) continue

                    var i = 0
                    while (i + 1 < read) {
                        val s = ((buffer[i + 1].toInt() shl 8) or (buffer[i].toInt() and 0xFF)).toShort()
                        val a = abs(s.toInt())
                        levelSum += a.toLong()
                        levelCount += 1
                        if (a > peak) peak = a
                        i += 2
                    }

                    val out = ensureOutputStream() ?: continue
                    try {
                        out.write(buffer, 0, read)
                        bytes += read.toLong()
                    } catch (_: IOException) {
                        closeSocketQuietly()
                    }

                    val now = System.currentTimeMillis()
                    if (now - last >= 1000) {
                        val kbps = (bytes * 8.0) / 1000.0
                        val avg = if (levelCount > 0) levelSum.toDouble() / levelCount.toDouble() else 0.0
                        lastCaptureAvg.set(avg)
                        Log.i("Aamina", "mode=$currentMode kbps=${"%.1f".format(kbps)} avg=${"%.1f".format(avg)} peak=$peak")
                        bytes = 0
                        levelSum = 0
                        levelCount = 0
                        peak = 0
                        last = now
                    }
                }
            } finally {
                closeSocketQuietly()
                isCapturing = false
            }
        }
    }

    private fun startToneStream() {
        stopAudioPipelineOnly()
        isCapturing = true
        toneThread = thread(start = true) {
            val frames = 1024
            val buffer = ByteArray(frames * 2 * 2)
            var phase = 0.0
            val freq = 440.0
            var bytes = 0L
            var last = System.currentTimeMillis()

            try {
                while (isCapturing && !Thread.currentThread().isInterrupted) {
                    var idx = 0
                    repeat(frames) {
                        val v = (sin(phase) * 0.2 * Short.MAX_VALUE).toInt().toShort()
                        phase += 2.0 * PI * freq / sampleRate.toDouble()
                        if (phase > 2.0 * PI) phase -= 2.0 * PI
                        val lo = (v.toInt() and 0xFF).toByte()
                        val hi = ((v.toInt() shr 8) and 0xFF).toByte()
                        buffer[idx++] = lo
                        buffer[idx++] = hi
                        buffer[idx++] = lo
                        buffer[idx++] = hi
                    }

                    val out = ensureOutputStream() ?: continue
                    try {
                        out.write(buffer)
                        bytes += buffer.size.toLong()
                    } catch (_: IOException) {
                        closeSocketQuietly()
                    }

                    val now = System.currentTimeMillis()
                    if (now - last >= 1000) {
                        val kbps = (bytes * 8.0) / 1000.0
                        Log.i("Aamina", "mode=tone kbps=${"%.1f".format(kbps)}")
                        bytes = 0
                        last = now
                    }
                }
            } finally {
                closeSocketQuietly()
                isCapturing = false
            }
        }
    }

    private fun ensureOutputStream(): java.io.OutputStream? {
        while (isCapturing && !Thread.currentThread().isInterrupted) {
            val existing = audioSocket
            if (existing != null && existing.isConnected && !existing.isClosed) {
                return try {
                    existing.getOutputStream()
                } catch (_: IOException) {
                    closeSocketQuietly()
                    null
                }
            }

            try {
                val socket = Socket(targetHost, targetPort)
                audioSocket = socket
                Log.i("Aamina", "Connected to $targetHost:$targetPort")
                return socket.getOutputStream()
            } catch (_: IOException) {
                try {
                    Thread.sleep(250)
                } catch (_: InterruptedException) {
                    Thread.currentThread().interrupt()
                    return null
                }
            }
        }
        return null
    }

    private fun stopAudioPipelineOnly() {
        isCapturing = false
        captureThread?.interrupt()
        toneThread?.interrupt()
        captureThread?.join(200)
        toneThread?.join(200)
        captureThread = null
        toneThread = null

        stopSilentPlayer()
        closeSocketQuietly()

        try {
            audioRecord?.stop()
        } catch (_: Exception) {
        }
        try {
            audioRecord?.release()
        } catch (_: Exception) {
        }
        audioRecord = null
    }

    private fun stopCapture() {
        stopAudioPipelineOnly()
        restoreVolume()
        try {
            mediaProjection?.stop()
        } catch (_: Exception) {
        }
        mediaProjection = null
        stopService(Intent(this, AudioCaptureService::class.java))
    }

    private fun getStreamVolume(): Int {
        val audioManager = getSystemService(Context.AUDIO_SERVICE) as AudioManager
        return audioManager.getStreamVolume(AudioManager.STREAM_MUSIC)
    }

    private fun setStreamVolume(volume: Int) {
        val audioManager = getSystemService(Context.AUDIO_SERVICE) as AudioManager
        val max = audioManager.getStreamMaxVolume(AudioManager.STREAM_MUSIC)
        audioManager.setStreamVolume(AudioManager.STREAM_MUSIC, volume.coerceIn(0, max), 0)
    }

    private fun restoreVolume() {
        val v = savedVolume ?: return
        savedVolume = null
        try {
            setStreamVolume(v)
        } catch (e: Exception) {
            Log.w("Aamina", "Volume restore failed", e)
        }
    }

    /**
     * EXPERIMENTAL "mute phone" helper: replays the captured PCM locally
     * through a silent AudioTrack so the originating app keeps rendering
     * audio (and capture keeps flowing) while the phone speaker stays
     * quiet. Whether capture survives STREAM_MUSIC=0 is device-dependent:
     * verify via logcat ("Aamina muteprobe ...").
     */
    private fun startSilentPlayer() {
        stopSilentPlayer()
        try {
            val minOut = AudioTrack.getMinBufferSize(sampleRate, android.media.AudioFormat.CHANNEL_OUT_STEREO, android.media.AudioFormat.ENCODING_PCM_16BIT)
            val track = AudioTrack.Builder()
                .setAudioAttributes(
                    AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_MEDIA)
                        .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC)
                        .build()
                )
                .setAudioFormat(
                    android.media.AudioFormat.Builder()
                        .setEncoding(android.media.AudioFormat.ENCODING_PCM_16BIT)
                        .setSampleRate(sampleRate)
                        .setChannelMask(android.media.AudioFormat.CHANNEL_OUT_STEREO)
                        .build()
                )
                .setBufferSizeInBytes(minOut * 2)
                .setTransferMode(AudioTrack.MODE_STREAM)
                .build()
            track.setVolume(0f)
            track.play()
            silentPlayer = track
        } catch (e: Exception) {
            Log.w("Aamina", "Silent player start failed", e)
            silentPlayer = null
        }
    }

    private fun stopSilentPlayer() {
        try {
            silentPlayer?.stop()
        } catch (_: Exception) {
        }
        try {
            silentPlayer?.release()
        } catch (_: Exception) {
        }
        silentPlayer = null
    }

    /**
     * One-shot diagnostic: records the captured signal level for ~2.5s at
     * full volume and ~2.5s at volume 0, then logs the verdict and puts
     * the volume back the way mute mode wants it (0). Run automatically
     * when mute mode starts. Watch with:
     *   adb logcat -s Aamina
     */
    private fun runMuteVolumeProbe() {
        thread(start = true) {
            try {
                val before = getStreamVolume()
                setStreamVolume((getSystemService(Context.AUDIO_SERVICE) as AudioManager).getStreamMaxVolume(AudioManager.STREAM_MUSIC))
                Thread.sleep(2500)
                val loudLevel = lastCaptureAvg.get()
                setStreamVolume(0)
                Thread.sleep(2500)
                val muteLevel = lastCaptureAvg.get()
                // Leave it muted for the actual mute-mode session.
                setStreamVolume(0)
                val survives = muteLevel > 5.0 && muteLevel > loudLevel * 0.25
                Log.i("Aamina", "muteprobe loud=$loudLevel mute=$muteLevel before=$before survives=$survives")
            } catch (e: Exception) {
                Log.w("Aamina", "mute probe failed", e)
            }
        }
    }

    private fun closeSocketQuietly() {
        try {
            audioSocket?.close()
        } catch (_: Exception) {
        }
        audioSocket = null
    }

    override fun onDestroy() {
        stopCapture()
        super.onDestroy()
    }
}
