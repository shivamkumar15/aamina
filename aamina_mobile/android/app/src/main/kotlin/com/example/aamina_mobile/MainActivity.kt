package com.example.aamina_mobile

import android.app.Activity
import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context
import android.content.Intent
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioRecord
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
                        startMode(mode)
                        result.success(true)
                    }
                    "stopCapture" -> {
                        stopCapture()
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
        if (requestCode == requestCodeProjection && resultCode == Activity.RESULT_OK && data != null) {
            mediaProjection = projectionManager!!.getMediaProjection(resultCode, data)
            startInternalAudioCapture()
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
                val socket = Socket("127.0.0.1", 5000)
                audioSocket = socket
                Log.i("Aamina", "Connected to laptop 127.0.0.1:5000")
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
        try {
            mediaProjection?.stop()
        } catch (_: Exception) {
        }
        mediaProjection = null
        stopService(Intent(this, AudioCaptureService::class.java))
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
