package com.personal.aibit.ai_bit

import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings
import android.util.Log
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * Hosts the Flutter engine and registers the one channel this app implements
 * itself: the Android floating player.
 *
 * The channel is registered here rather than as a plugin because there is
 * exactly one Activity and the overlay permission flow needs it — starting the
 * settings screen and starting a foreground service both want an Activity
 * context, and a FlutterPlugin would have to go and find one.
 */
class MainActivity : FlutterActivity() {

    private companion object {
        const val CHANNEL = "ai.bit/floating_player"
        const val TAG = "AiBitFloating"
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    // The Dart side already gates on the platform; this exists
                    // so a future device check has somewhere to live.
                    "isSupported" -> result.success(true)

                    "hasPermission" -> result.success(canDrawOverlays())

                    "requestPermission" -> {
                        openOverlaySettings()
                        // Reports the permission as it stands *now*, which is
                        // almost always false: the grant happens in the
                        // Settings app, in another task, with no result coming
                        // back to us. Dart re-checks when the user returns.
                        result.success(canDrawOverlays())
                    }

                    "isRunning" -> result.success(FloatingPlayerService.isRunning)

                    "start" -> {
                        if (!canDrawOverlays()) {
                            // Not an error: "you have not granted this yet" is
                            // an ordinary answer, and the Dart side turns it
                            // into the explanation dialog. A PlatformException
                            // here would just be a false alarm in the log.
                            result.success(false)
                        } else {
                            startBubble(
                                call.argument<String>("title").orEmpty(),
                                call.argument<String>("subtitle").orEmpty()
                            )
                            result.success(true)
                        }
                    }

                    "stop" -> {
                        stopService(Intent(this, FloatingPlayerService::class.java))
                        result.success(true)
                    }

                    else -> result.notImplemented()
                }
            }
    }

    private fun canDrawOverlays(): Boolean =
        // The permission did not exist before Android 6; on anything older the
        // overlay simply works.
        Build.VERSION.SDK_INT < Build.VERSION_CODES.M || Settings.canDrawOverlays(this)

    private fun openOverlaySettings() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return
        try {
            startActivity(
                Intent(
                    Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
                    Uri.parse("package:$packageName")
                ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            )
        } catch (e: Exception) {
            // Some manufacturer builds (Xiaomi among them, which is the test
            // device) rename or hide this screen and throw
            // ActivityNotFoundException. Logged rather than crashed: the user
            // can still reach it through the app's own settings page, and a
            // dead-end permission is not worth taking the app down for.
            Log.w(TAG, "could not open the overlay permission screen", e)
        }
    }

    private fun startBubble(title: String, subtitle: String) {
        val intent = Intent(this, FloatingPlayerService::class.java)
            .putExtra(FloatingPlayerService.EXTRA_TITLE, title)
            .putExtra(FloatingPlayerService.EXTRA_SUBTITLE, subtitle)
        // Started while the Activity is in the foreground, which is what makes
        // this legal at all: from Android 12 an app in the background may not
        // start a foreground service. The user tapping the button is the
        // guarantee that we are in front.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            startForegroundService(intent)
        } else {
            startService(intent)
        }
    }
}
