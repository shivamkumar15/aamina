package com.example.aamina_mobile

import android.app.Notification
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder

class AudioCaptureService : Service() {

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        return START_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? {
        return null
    }

    override fun onCreate() {
        super.onCreate()

        val notification =
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {

                Notification.Builder(
                    this,
                    "aamina_channel"
                )
                    .setContentTitle("Aamina")
                    .setContentText("Capturing audio")
                    .setSmallIcon(
                        android.R.drawable.ic_btn_speak_now
                    )
                    .build()

            } else {

                Notification.Builder(this)
                    .setContentTitle("Aamina")
                    .setContentText("Capturing audio")
                    .build()
            }

        // Android 14+ (API 34) requires specifying the
        // foreground service type, otherwise it crashes with
        // MissingForegroundServiceTypeException
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            startForeground(
                1,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION
            )
        } else {
            startForeground(1, notification)
        }
    }
}
