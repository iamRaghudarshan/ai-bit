package com.personal.aibit.ai_bit

import android.annotation.SuppressLint
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.content.res.ColorStateList
import android.graphics.Color
import android.graphics.drawable.GradientDrawable
import android.os.Build
import android.os.IBinder
import android.text.TextUtils
import android.util.Log
import android.util.TypedValue
import android.view.Gravity
import android.view.MotionEvent
import android.view.SurfaceHolder
import android.view.SurfaceView
import android.view.View
import android.view.ViewGroup
import android.view.WindowManager
import android.widget.FrameLayout
import android.widget.ImageButton
import android.widget.TextView
import uz.shs.better_player_plus.BetterPlayerSurfaceBridge
import kotlin.math.abs

/**
 * The Android floating player: a draggable window that shows the video playing
 * over whatever app is in front, and survives leaving AI BIT.
 *
 * WHY A SERVICE AT ALL. A view added to the WindowManager belongs to whatever
 * context added it. Added from the Activity it dies with the Activity, which is
 * precisely the moment the bubble is supposed to appear. A started foreground
 * service is the only component that reliably outlives the Activity, so it owns
 * the window.
 *
 * HOW THERE IS VIDEO IN IT. There is exactly one native player in this app (see
 * CLAUDE.md, "One player for the whole app") and starting a second one would
 * double-decode the stream and fight the first for audio focus. So the video is
 * not copied — its *output* is moved. This window holds a [SurfaceView], and
 * `BetterPlayerSurfaceBridge` (PATCH 18 in the vendored plugin) points the live
 * ExoPlayer at that surface for as long as the window is up, then points it
 * back at Flutter's texture when it comes down.
 *
 * SO THE IN-APP VIDEO GOES BLANK WHILE THIS IS SHOWING. That is correct, not a
 * bug: one decoder has one output. System Picture-in-Picture behaves the same
 * way. What matters is that the way back is airtight, so the surface is handed
 * back from three independent places — [SurfaceHolder.Callback.surfaceDestroyed],
 * [onDestroy], and (from Dart) a stop on app resume — and the handoff itself
 * never overwrites the Flutter surface it has to restore.
 *
 * IF THE HANDOFF IS UNAVAILABLE — nothing playing, plugin released — the window
 * falls back to the title-and-close bubble it used to be, rather than showing a
 * black rectangle.
 */
class FloatingPlayerService : Service() {

    companion object {
        const val EXTRA_TITLE = "title"
        const val EXTRA_SUBTITLE = "subtitle"

        private const val TAG = "AiBitFloating"
        private const val CHANNEL_ID = "ai_bit_floating_player"
        private const val NOTIFICATION_ID = 4711

        /**
         * Read from the Flutter side over the method channel, written here.
         * Volatile because those are different threads: the channel handler
         * runs on the main thread and the service's lifecycle callbacks can
         * arrive on it at a different time.
         */
        @Volatile
        var isRunning: Boolean = false
            private set

        /**
         * Set by [MainActivity] so a failure that happens *after* the service
         * has been started can still reach the user.
         *
         * `startForegroundService` returns immediately and the interesting
         * failures (Android 14 rejecting the service type, the overlay
         * permission revoked between the check and `addView`) happen later, in
         * here, where there is no `MethodChannel.Result` left to fail. Without
         * this the user taps the button, nothing appears, and nothing says why.
         *
         * Nulled out when the engine goes, so this never pins a dead Activity.
         */
        @Volatile
        var onFailure: ((String) -> Unit)? = null
    }

    private var windowManager: WindowManager? = null
    private var bubble: View? = null
    private var titleView: TextView? = null
    private var videoView: SurfaceView? = null
    private var layoutParams: WindowManager.LayoutParams? = null

    // Where the window was when the current drag started, and where the finger
    // touched. Both are needed because the window moves in absolute screen
    // coordinates while the touch reports raw screen coordinates.
    private var windowStartX = 0
    private var windowStartY = 0
    private var touchStartX = 0f
    private var touchStartY = 0f
    private var dragged = false

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val title = intent?.getStringExtra(EXTRA_TITLE).orEmpty()
        val subtitle = intent?.getStringExtra(EXTRA_SUBTITLE).orEmpty()

        // The notification must be posted before anything can go wrong below:
        // a service started with startForegroundService that does not call
        // startForeground within a few seconds is killed with a
        // ForegroundServiceDidNotStartInTimeException.
        if (!startInForeground()) {
            // stopSelf() here is not just tidying — stopping the service is
            // what cancels the "did not start in time" watchdog that
            // startForegroundService armed. Leaving it running would turn a
            // soft failure into a crash a few seconds later.
            reportFailure("Android would not let the floating player run in the background.")
            stopSelf()
            return START_NOT_STICKY
        }

        if (bubble == null) {
            try {
                showBubble(title, subtitle)
            } catch (e: Exception) {
                // Most likely the overlay permission was revoked between the
                // Dart-side check and this call, which throws
                // BadTokenException from addView. Logged rather than swallowed,
                // and the service stops rather than lingering as a foreground
                // notification with no window under it.
                Log.w(TAG, "could not add the overlay window", e)
                reportFailure("Could not draw over other apps. Check the permission and try again.")
                stopSelf()
                return START_NOT_STICKY
            }
        } else {
            // Already up: a second start is a title change, not a new bubble.
            titleView?.text = displayText(title, subtitle)
        }

        isRunning = true
        // NOT sticky. If Android kills this the app is gone too, and a bubble
        // that reappears on its own pointing at nothing is worse than no
        // bubble.
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        isRunning = false

        // FIRST, before the window is touched. Every other line in this method
        // can fail; the video must be back with Flutter regardless, or the app
        // is left rendering into a surface that is about to stop existing and
        // every video is black until the process restarts. Called
        // unconditionally, with no local "did I attach?" flag to disagree with
        // reality — the bridge's detach is a no-op when nothing is attached,
        // which makes the blunt call the safe one.
        detachVideo()

        val view = bubble
        if (view != null) {
            try {
                windowManager?.removeView(view)
            } catch (e: IllegalArgumentException) {
                // The view was already detached — the window token died with
                // the display, or removeView ran twice. Nothing to undo.
                Log.w(TAG, "overlay window was already gone", e)
            }
        }
        bubble = null
        titleView = null
        videoView = null
        layoutParams = null
        windowManager = null
        super.onDestroy()
    }

    /** Hands the video back to Flutter. Idempotent, and never throws. */
    private fun detachVideo() {
        try {
            BetterPlayerSurfaceBridge.detach()
        } catch (e: Exception) {
            // Cannot be allowed to propagate out of a teardown path: the bridge
            // already logs, and there is nothing further to try. Logged again
            // here so the failure is attributable to this window rather than to
            // the plugin in isolation.
            Log.w(TAG, "handing the video back to Flutter failed", e)
        }
    }

    private fun reportFailure(message: String) {
        Log.w(TAG, "floating player failed: $message")
        try {
            onFailure?.invoke(message)
        } catch (e: Exception) {
            // The Activity may be mid-teardown, and a dead channel must not
            // turn a soft failure into a crash inside the service.
            Log.w(TAG, "could not report the failure to Flutter", e)
        }
    }

    private fun displayText(title: String, subtitle: String): String = when {
        title.isEmpty() -> "AI BIT"
        subtitle.isEmpty() -> title
        else -> "$title\n$subtitle"
    }

    private fun dp(value: Int): Int = (value * resources.displayMetrics.density).toInt()

    @SuppressLint("ClickableViewAccessibility")
    private fun showBubble(title: String, subtitle: String) {
        val manager = getSystemService(WINDOW_SERVICE) as WindowManager
        windowManager = manager

        // Asked before laying out, not after: with no player to borrow from,
        // a SurfaceView would be a black rectangle with no explanation, so the
        // window is built as the old text bubble instead.
        val wantsVideo = BetterPlayerSurfaceBridge.hasPlayer()

        val text = TextView(this).apply {
            text = displayText(title, subtitle)
            setTextColor(Color.WHITE)
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 13f)
            maxLines = 2
            ellipsize = TextUtils.TruncateAt.END
            // Bounded, or a long video title makes the bubble as wide as the
            // screen and there is nothing left to drag it by.
            maxWidth = dp(150)
            // Right padding reserves the close button's corner: in a FrameLayout
            // the two overlap rather than sitting side by side, and without
            // this the button covers the end of the title.
            setPadding(dp(10), dp(8), dp(34), dp(8))
            visibility = if (wantsVideo) View.GONE else View.VISIBLE
        }
        titleView = text

        val close = ImageButton(this).apply {
            setImageResource(android.R.drawable.ic_menu_close_clear_cancel)
            // A framework drawable rather than a new resource: AAPT2 renames
            // resources in release builds, and one less app resource is one
            // less thing that can go missing in an APK nobody can build here.
            imageTintList = ColorStateList.valueOf(Color.WHITE)
            background = null
            setPadding(dp(6), dp(6), dp(6), dp(6))
            contentDescription = "Close the floating player"
            setOnClickListener { stopSelf() }
        }

        val video = if (wantsVideo) buildVideoView() else null
        videoView = video

        val root = FrameLayout(this).apply {
            // Small inset so the rounded background reads as a frame around the
            // picture. It cannot round the video itself: a SurfaceView is its
            // own compositor layer and clipToOutline does not reach it.
            setPadding(dp(3), dp(3), dp(3), dp(3))
            background = GradientDrawable().apply {
                cornerRadius = dp(14).toFloat()
                // Near-opaque rather than solid, so it reads as floating above
                // whatever is underneath it.
                setColor(Color.parseColor("#F0101114"))
            }
            elevation = dp(8).toFloat()
            contentDescription = displayText(title, subtitle)
        }

        // Order matters. A SurfaceView composites BELOW its host window and
        // clears its own rectangle out of that window's buffer, so anything
        // added after it draws on top of the picture — which is how the close
        // button stays visible over the video. Anything added before it would
        // be erased by that clear.
        if (video != null) {
            root.addView(
                video,
                FrameLayout.LayoutParams(videoWidth(), videoHeight(), Gravity.CENTER)
            )
        }
        root.addView(
            text,
            FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.WRAP_CONTENT,
                ViewGroup.LayoutParams.WRAP_CONTENT,
                Gravity.CENTER_VERTICAL or Gravity.START
            )
        )
        root.addView(
            close,
            FrameLayout.LayoutParams(dp(30), dp(30), Gravity.TOP or Gravity.END)
        )

        val params = WindowManager.LayoutParams(
            ViewGroup.LayoutParams.WRAP_CONTENT,
            ViewGroup.LayoutParams.WRAP_CONTENT,
            overlayWindowType(),
            // NOT_FOCUSABLE, and nothing else. It keeps the keyboard and the
            // back key with whatever app is actually in front, and it implies
            // NOT_TOUCH_MODAL — which is the flag that matters, because a
            // touch-modal overlay swallows every tap on the screen and leaves
            // the phone unusable until the bubble is closed.
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE,
            // TRANSLUCENT is what allows the SurfaceView to punch its hole; an
            // opaque window format would leave the video invisible behind the
            // window's own background.
            android.graphics.PixelFormat.TRANSLUCENT
        ).apply {
            gravity = Gravity.TOP or Gravity.START
            x = dp(12)
            y = dp(120)
        }
        layoutParams = params

        // Touches that land on the close button are consumed by the button
        // before they reach here, so dragging never fights the close tap. A
        // SurfaceView is not clickable, so touches on the picture fall through
        // to this listener as intended.
        root.setOnTouchListener { view, event ->
            when (event.actionMasked) {
                MotionEvent.ACTION_DOWN -> {
                    windowStartX = params.x
                    windowStartY = params.y
                    touchStartX = event.rawX
                    touchStartY = event.rawY
                    dragged = false
                    true
                }

                MotionEvent.ACTION_MOVE -> {
                    val dx = (event.rawX - touchStartX).toInt()
                    val dy = (event.rawY - touchStartY).toInt()
                    // A slop check, so a tap with a shaky thumb still counts as
                    // a tap instead of a one-pixel drag that eats the click.
                    if (abs(dx) > dp(6) || abs(dy) > dp(6)) dragged = true
                    params.x = windowStartX + dx
                    params.y = windowStartY + dy
                    manager.updateViewLayout(view, params)
                    true
                }

                MotionEvent.ACTION_UP -> {
                    if (!dragged) openApp()
                    true
                }

                else -> false
            }
        }

        manager.addView(root, params)
        bubble = root
    }

    // 16:9, sized so the window is big enough to actually watch and small
    // enough to leave the app underneath usable.
    private fun videoWidth(): Int = dp(180)

    private fun videoHeight(): Int = videoWidth() * 9 / 16

    private fun buildVideoView(): SurfaceView = SurfaceView(this).apply {
        holder.addCallback(object : SurfaceHolder.Callback {
            override fun surfaceCreated(holder: SurfaceHolder) {
                // The surface only exists from here; attaching any earlier
                // hands ExoPlayer something that is not yet valid.
                attachVideo(holder)
            }

            override fun surfaceChanged(
                holder: SurfaceHolder,
                format: Int,
                width: Int,
                height: Int
            ) {
                // Nothing to do: the window never resizes, and ExoPlayer scales
                // to whatever surface it was given.
            }

            override fun surfaceDestroyed(holder: SurfaceHolder) {
                // The primary restore path, and the one that fires even if this
                // service is killed rather than stopped cleanly. onDestroy
                // repeats it because "killed rather than stopped" is not a
                // promise either way.
                detachVideo()
            }
        })
    }

    private fun attachVideo(holder: SurfaceHolder) {
        val attached = try {
            BetterPlayerSurfaceBridge.attach(holder.surface)
        } catch (e: Exception) {
            // Logged, not swallowed into a bare false: a window that silently
            // shows no picture is the exact failure this feature was rewritten
            // to remove.
            Log.w(TAG, "could not borrow the video surface", e)
            false
        }
        if (!attached) {
            // Degrade to the control-only bubble rather than show a black box.
            // Not reported as a user-facing failure: the bubble still works as
            // a handle back into the app, and the audio never stopped.
            Log.w(TAG, "no video available for the floating player, showing the title instead")
            videoView?.visibility = View.GONE
            titleView?.visibility = View.VISIBLE
        }
    }

    /**
     * TYPE_APPLICATION_OVERLAY is the only overlay type an ordinary app may use
     * from Android 8; the old TYPE_PHONE was taken away in the same release and
     * throws on newer versions. Both are here because minSdk is below 26.
     */
    @Suppress("DEPRECATION")
    private fun overlayWindowType(): Int =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY
        } else {
            WindowManager.LayoutParams.TYPE_PHONE
        }

    /** Brings the app back to the front, then takes the bubble down. */
    private fun openApp() {
        val launch = packageManager.getLaunchIntentForPackage(packageName)
        if (launch == null) {
            Log.w(TAG, "no launch intent for $packageName")
            return
        }
        launch.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
        // Android 10 blocks starting an activity from the background, but
        // holding SYSTEM_ALERT_WINDOW is one of the documented exemptions —
        // and this service cannot exist without that permission, so the
        // exemption always applies here.
        startActivity(launch)
        // Back in the app, the bubble is redundant and would sit on top of the
        // real player — and stopping is what returns the video to Flutter.
        stopSelf()
    }

    /**
     * Returns false when the service could not legally go foreground, instead
     * of taking the app down with it.
     */
    private fun startInForeground(): Boolean {
        val manager = getSystemService(NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            // Re-creating an existing channel is a no-op, so this needs no
            // "already created" bookkeeping.
            manager.createNotificationChannel(
                NotificationChannel(
                    CHANNEL_ID,
                    "Floating player",
                    // LOW: no sound, no heads-up. The notification only exists
                    // because a foreground service is required to have one.
                    NotificationManager.IMPORTANCE_LOW
                )
            )
        }

        val launch = packageManager.getLaunchIntentForPackage(packageName)
        // FLAG_IMMUTABLE is mandatory from Android 12 and nothing here needs to
        // fill the intent in later - but the constant itself only exists from
        // API 23, and an unguarded reference is a fatal NewApi finding in the
        // lintVitalRelease that runs as part of a release assemble. Branched
        // rather than assumed, because minSdk here comes from Flutter's
        // toolchain and moves without this file being touched.
        val pendingFlags = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        } else {
            PendingIntent.FLAG_UPDATE_CURRENT
        }
        val contentIntent = if (launch == null) {
            null
        } else {
            PendingIntent.getActivity(this, 0, launch, pendingFlags)
        }

        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        val notification = builder
            .setContentTitle("AI BIT is floating")
            .setContentText("Tap to go back to the app")
            // A framework drawable, deliberately: notification small icons must
            // be a white-on-transparent silhouette, which the launcher icon is
            // not, and this avoids adding a resource that cannot be verified
            // without building the APK.
            .setSmallIcon(android.R.drawable.ic_media_play)
            .setOngoing(true)
            .apply { if (contentIntent != null) setContentIntent(contentIntent) }
            .build()

        return try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                // Android 10 introduced the type, and Android 14 made declaring
                // one mandatory. mediaPlayback rather than specialUse because
                // the bubble only ever exists while this app is playing media,
                // and the matching FOREGROUND_SERVICE_MEDIA_PLAYBACK permission
                // is already in the manifest for the player's own notification.
                startForeground(
                    NOTIFICATION_ID,
                    notification,
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK
                )
            } else {
                startForeground(NOTIFICATION_ID, notification)
            }
            true
        } catch (e: Exception) {
            // Android 14 judges the *justification* for a service type at
            // runtime, not just the manifest: with no active media session it
            // throws InvalidForegroundServiceTypeException, and from the
            // background it throws ForegroundServiceStartNotAllowedException.
            // Both are IllegalStateException subclasses and both are the
            // system's decision, not a bug to crash on — Dart only ever asks
            // for this while playback is running, so reaching here means the
            // OS disagreed and the honest response is to say so and stop.
            // SecurityException lands here too, if the permission is missing.
            Log.w(TAG, "startForeground was refused", e)
            false
        }
    }
}
