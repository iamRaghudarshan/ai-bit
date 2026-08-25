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
import android.view.View
import android.view.ViewGroup
import android.view.WindowManager
import android.widget.ImageButton
import android.widget.LinearLayout
import android.widget.TextView
import kotlin.math.abs

/**
 * The Android floating player: a draggable bubble in a system overlay window
 * that survives leaving the app.
 *
 * WHY A SERVICE AT ALL. A view added to the WindowManager belongs to whatever
 * context added it. Added from the Activity it dies with the Activity, which is
 * precisely the moment the bubble is supposed to appear. A started foreground
 * service is the only component that reliably outlives the Activity, so it owns
 * the window.
 *
 * WHY THERE IS NO VIDEO IN IT. There is exactly one native player in this app
 * and it is attached to the Flutter view (see CLAUDE.md, "One player for the
 * whole app"). Its surface cannot be in two windows at once, so the bubble
 * carries the title and the controls while the audio keeps playing through the
 * existing background-playback path. Trying to hand the surface over would mean
 * a second player, and every stale-lock-screen bug in this project came from
 * assuming a player per video.
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
    }

    private var windowManager: WindowManager? = null
    private var bubble: View? = null
    private var titleView: TextView? = null
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
        // startForeground within a few seconds is killed with a ForegroundServiceDidNotStartInTimeException.
        startInForeground()

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
        layoutParams = null
        windowManager = null
        super.onDestroy()
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

        val text = TextView(this).apply {
            text = displayText(title, subtitle)
            setTextColor(Color.WHITE)
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 13f)
            maxLines = 2
            ellipsize = TextUtils.TruncateAt.END
            // Bounded, or a long video title makes the bubble as wide as the
            // screen and there is nothing left to drag it by.
            maxWidth = dp(150)
        }
        titleView = text

        val close = ImageButton(this).apply {
            setImageResource(android.R.drawable.ic_menu_close_clear_cancel)
            // A framework drawable rather than a new resource: AAPT2 renames
            // resources in release builds, and one less app resource is one
            // less thing that can go missing in an APK nobody can build here.
            imageTintList = ColorStateList.valueOf(Color.WHITE)
            background = null
            setPadding(dp(8), dp(8), dp(8), dp(8))
            contentDescription = "Close the floating player"
            setOnClickListener { stopSelf() }
        }

        val root = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(dp(12), dp(8), dp(4), dp(8))
            background = GradientDrawable().apply {
                cornerRadius = dp(20).toFloat()
                // Near-opaque rather than solid, so it reads as floating above
                // whatever is underneath it.
                setColor(Color.parseColor("#F0101114"))
            }
            elevation = dp(8).toFloat()
            addView(
                text,
                LinearLayout.LayoutParams(
                    ViewGroup.LayoutParams.WRAP_CONTENT,
                    ViewGroup.LayoutParams.WRAP_CONTENT
                )
            )
            addView(
                close,
                LinearLayout.LayoutParams(dp(36), dp(36))
            )
        }

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
            android.graphics.PixelFormat.TRANSLUCENT
        ).apply {
            gravity = Gravity.TOP or Gravity.START
            x = dp(12)
            y = dp(120)
        }
        layoutParams = params

        // Touches that land on the close button are consumed by the button
        // before they reach here, so dragging never fights the close tap.
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
        // real player.
        stopSelf()
    }

    private fun startInForeground() {
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

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            // Android 10 introduced the type, and Android 14 made declaring one
            // mandatory. mediaPlayback rather than specialUse because the
            // bubble only ever exists while this app is playing media, and the
            // matching FOREGROUND_SERVICE_MEDIA_PLAYBACK permission is already
            // in the manifest for the player's own notification.
            startForeground(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
    }
}
