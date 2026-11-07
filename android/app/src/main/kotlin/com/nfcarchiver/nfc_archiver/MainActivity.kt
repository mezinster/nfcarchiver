package com.nfcarchiver.nfc_archiver

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val channelName = "com.nfcarchiver/nfc_capabilities"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
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
