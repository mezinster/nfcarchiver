package com.nfcarchiver.nfc_archiver

import android.content.Intent
import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val channelName = "com.nfcarchiver/nfc_capabilities"
    private var shareInbox: ShareInbox? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // Cold start from a share. A restored activity, or one relaunched
        // from Recents, carries the original share intent again: skip those
        // so an old share is not taken twice. Dart takes it after its first
        // frame.
        val fromHistory =
            intent.flags and Intent.FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY != 0
        if (savedInstanceState == null && !fromHistory) {
            shareInbox?.accept(intent)
        }
    }

    // singleTop: a share (or an NFC tag) arriving while the app runs.
    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        if (shareInbox?.accept(intent) == true) shareInbox?.notifyAvailable()
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        PhotoEncoder(flutterEngine.dartExecutor.binaryMessenger)
        shareInbox = ShareInbox(applicationContext, flutterEngine.dartExecutor.binaryMessenger)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    // "com.nxp.mifare" is the standard Android system feature
                    // reported by devices whose NFC controller implements
                    // CRYPTO1. Absent on Broadcom/Samsung S3FWRN5 controllers.
                    "hasMifareClassic" -> result.success(
                        packageManager.hasSystemFeature("com.nxp.mifare")
                    )
                    // BLE permission rules split at Android 12 (API 31); the
                    // Dart side picks which permissions to request from this.
                    "androidSdkInt" -> result.success(android.os.Build.VERSION.SDK_INT)
                    else -> result.notImplemented()
                }
            }
    }
}
