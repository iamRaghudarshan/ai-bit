package com.personal.aibit.ai_bit

import android.content.Intent
import android.content.res.Configuration
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import android.util.Log
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * Hosts the Flutter engine and registers the channels this app implements
 * itself: the Android floating player, and incoming YouTube links.
 *
 * The channels are registered here rather than as plugins because there is
 * exactly one Activity and both need it — the overlay permission flow wants
 * an Activity context, and a link arrives *as* this Activity's Intent.
 */
class MainActivity : FlutterActivity() {

    private companion object {
        const val CHANNEL = "ai.bit/floating_player"
        const val INCOMING_CHANNEL = "ai.bit/incoming"
        const val TAG = "AiBitFloating"

        /** Dart-side method name for a failure that surfaced after `start`. */
        const val ON_FAILED = "onFailed"

        /** Dart-side method name for entering or leaving Picture in Picture. */
        const val ON_PIP_CHANGED = "onPictureInPictureChanged"

        /** Dart-side method name for a link that arrived while running. */
        const val ON_LINK = "onLink"

        /** App lock asks the window to hide itself from the task switcher. */
        const val WINDOW_CHANNEL = "ai.bit/window"
    }

    private var channel: MethodChannel? = null
    private var incoming: MethodChannel? = null

    /**
     * A link that arrived before Dart asked for it — the launch Intent, or one
     * delivered in the gap before the engine was configured. Handed over once.
     */
    private var pendingLink: String? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // Only a genuinely new launch carries a link worth opening. Android
        // re-delivers the original Intent when the process is recreated or
        // the app is reopened from Recents, and replaying the share then would
        // push the video over whatever the user was doing.
        val fromHistory =
            intent.flags and Intent.FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY != 0
        if (savedInstanceState == null && !fromHistory) {
            pendingLink = linkFrom(intent)
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        val link = linkFrom(intent) ?: return
        val target = incoming
        if (target == null) {
            pendingLink = link
            return
        }
        try {
            target.invokeMethod(ON_LINK, link)
        } catch (e: Exception) {
            Log.w(TAG, "could not deliver the incoming link", e)
            pendingLink = link
        }
    }

    /**
     * The YouTube reference an Intent carries: the URL of a tapped link, or
     * the text of a share. Anything else is not for us and yields null.
     */
    private fun linkFrom(intent: Intent?): String? {
        if (intent == null) return null
        return when (intent.action) {
            Intent.ACTION_VIEW -> intent.dataString
            Intent.ACTION_SEND -> intent.getStringExtra(Intent.EXTRA_TEXT)
            else -> null
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        val incomingChannel =
            MethodChannel(flutterEngine.dartExecutor.binaryMessenger, INCOMING_CHANNEL)
        incoming = incomingChannel
        incomingChannel.setMethodCallHandler { call, result ->
            when (call.method) {
                "initial" -> {
                    result.success(pendingLink)
                    pendingLink = null
                }

                else -> result.notImplemented()
            }
        }

        // App lock's privacy half. The task switcher captures its thumbnail
        // before Flutter can repaint a shield, so with the lock on the
        // switcher still showed whatever was on screen — watch history
        // included. FLAG_SECURE blanks that thumbnail on every Android
        // version (and blocks screenshots while the lock is on, which is the
        // same trade every banking app makes). On 13+ the thumbnail alone is
        // also switched off, the narrower tool, in case FLAG_SECURE is ever
        // relaxed here.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, WINDOW_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "setSecure" -> {
                        val secure = call.arguments == true
                        runOnUiThread {
                            if (secure) {
                                window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
                            } else {
                                window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)
                            }
                            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                                setRecentsScreenshotEnabled(!secure)
                            }
                        }
                        result.success(null)
                    }

                    else -> result.notImplemented()
                }
            }

        val methodChannel =
            MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
        channel = methodChannel

        // The overlay service is started with startForegroundService, which
        // returns before anything can go wrong inside it — so the failures that
        // matter (Android 14 refusing the mediaPlayback service type, the
        // overlay permission revoked between the check and addView) happen with
        // no Result left to fail. This is how they get back to the user instead
        // of being a button that does nothing.
        FloatingPlayerService.onFailure = { message ->
            // The service already runs on the main thread, but the channel is
            // strict about it and a future caller may not be.
            runOnUiThread {
                try {
                    channel?.invokeMethod(ON_FAILED, message)
                } catch (e: Exception) {
                    // The engine can be detached between the failure and this
                    // post. Logged rather than crashed: the failure has already
                    // been logged natively, and there is nobody left to tell.
                    Log.w(TAG, "could not deliver the floating player failure", e)
                }
            }
        }

        methodChannel.setMethodCallHandler { call, result ->
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
                    // Belt and braces with the Dart-side check. A foreground
                    // service typed mediaPlayback is only justified while media
                    // is actually playing, and Android 14 enforces that at
                    // runtime with InvalidForegroundServiceTypeException — so
                    // the one caller that knows the answer sends it, and this
                    // refuses rather than starting a service the OS will kill.
                    val playing = call.argument<Boolean>("playing") == true
                    when {
                        !playing -> {
                            Log.i(TAG, "refusing to float: nothing is playing")
                            result.success(false)
                        }

                        !canDrawOverlays() -> {
                            // Not an error: "you have not granted this yet" is
                            // an ordinary answer, and the Dart side turns it
                            // into the explanation dialog. A PlatformException
                            // here would just be a false alarm in the log.
                            result.success(false)
                        }

                        else -> {
                            startBubble(
                                call.argument<String>("title").orEmpty(),
                                call.argument<String>("subtitle").orEmpty()
                            )
                            result.success(true)
                        }
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

    /**
     * Tells Dart when the Activity enters or leaves Picture in Picture.
     *
     * The player plugin only reports PiP it started itself; automatic PiP
     * (armed with setAutoEnterEnabled, entered by leaving the app) is a
     * system transition nobody else hears. A PiP Activity is only paused, so
     * Flutter's lifecycle says "inactive", which the wakelock logic ignores
     * — and from the docked mini player the screen was let sleep under the
     * floated video. PlaybackController.setInPictureInPicture is the reader.
     */
    override fun onPictureInPictureModeChanged(
        isInPictureInPictureMode: Boolean,
        newConfig: Configuration
    ) {
        super.onPictureInPictureModeChanged(isInPictureInPictureMode, newConfig)
        try {
            channel?.invokeMethod(ON_PIP_CHANGED, isInPictureInPictureMode)
        } catch (e: Exception) {
            Log.w(TAG, "could not report the picture-in-picture change", e)
        }
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        // The service holds this callback in a static field, so leaving it set
        // would pin a dead Activity and its engine for as long as the process
        // lives.
        FloatingPlayerService.onFailure = null
        channel?.setMethodCallHandler(null)
        channel = null
        incoming?.setMethodCallHandler(null)
        incoming = null
        super.cleanUpFlutterEngine(flutterEngine)
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
