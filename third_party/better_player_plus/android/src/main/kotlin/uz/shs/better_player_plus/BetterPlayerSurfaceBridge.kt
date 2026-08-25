package uz.shs.better_player_plus

import android.os.Handler
import android.os.Looper
import android.util.Log
import android.view.Surface

/**
 * PATCH 18: the one public seam that lets the host app render this plugin's
 * video somewhere the plugin knows nothing about.
 *
 * WHY THIS EXISTS. AI BIT draws a floating bubble in a system overlay window
 * (`FloatingPlayerService` in the app module) and that bubble is meant to show
 * the video, not just its title. There is exactly one native player in the app
 * and it is attached to the Flutter texture, so the only honest way to get
 * pixels into a second window is to move the *output* of that one player —
 * `ExoPlayer.setVideoSurface` — rather than to start a second player. A second
 * player would decode the same stream twice and fight the first one for audio
 * focus, and every stale-notification bug in this project came from assuming a
 * player per video.
 *
 * WHY A PUBLIC OBJECT RATHER THAN A METHOD CHANNEL. The `Surface` being handed
 * over lives in the app module's overlay service; it cannot be marshalled
 * through Dart. The app module already compiles against this plugin module, so
 * a static seam is the shortest path. It deliberately speaks only in
 * `android.view.Surface` and `Boolean`: [BetterPlayer] and every media3 type is
 * `implementation`-scoped here and is NOT on the app module's compile
 * classpath, so exposing one would break the app's build rather than this one's.
 *
 * WHY IT IS SAFE TO DETACH. [attach] never overwrites the Flutter surface;
 * `BetterPlayer.surface` is created once in `setupVideoPlayer` and is still
 * held, so [detach] is a re-set of a field we never lost. That is the whole
 * reason the handoff is reversible, and it is the property to preserve if this
 * is ever edited.
 */
object BetterPlayerSurfaceBridge {

    private const val TAG = "BetterPlayerSurface"

    /**
     * The player the host app means by "what is playing". Volatile because it
     * is written from the player (main thread) and read from the overlay
     * service's `SurfaceHolder` callbacks, which are also main thread today but
     * are not contractually promised to stay that way.
     *
     * Private, so the fact that its type is `internal` never leaks into this
     * object's public surface.
     */
    @Volatile
    private var current: BetterPlayer? = null

    private val main = Handler(Looper.getMainLooper())

    /** Last player to be created or told to play; see the class comment. */
    internal fun register(player: BetterPlayer) {
        current = player
    }

    /**
     * Identity-checked: a player being disposed must not clear a registration
     * that a newer player has already taken over.
     */
    internal fun unregister(player: BetterPlayer) {
        if (current === player) current = null
    }

    /**
     * True when there is a player whose video could be borrowed. The overlay
     * asks this *before* it inflates, so it can lay itself out as a text-only
     * bubble instead of showing an empty black rectangle.
     */
    @JvmStatic
    fun hasPlayer(): Boolean = current != null

    /**
     * Points the current player's video output at [surface].
     *
     * Returns false when there is no player, or when the handoff threw — the
     * caller is expected to fall back to a control-only bubble rather than
     * show a black hole.
     */
    @JvmStatic
    fun attach(surface: Surface): Boolean {
        if (!surface.isValid) {
            Log.w(TAG, "refusing to attach an invalid surface")
            return false
        }
        return onPlayer("attach") { it.attachExternalSurface(surface) }
    }

    /**
     * Gives the video back to Flutter. A no-op when nothing was attached, so
     * callers may — and this app's overlay service deliberately does — call it
     * from more than one teardown path.
     */
    @JvmStatic
    fun detach(): Boolean = onPlayer("detach") { it.detachExternalSurface() }

    /** Whether an external surface is currently holding the video. */
    @JvmStatic
    fun isAttached(): Boolean = current?.hasExternalSurface() == true

    private fun onPlayer(what: String, action: (BetterPlayer) -> Unit): Boolean {
        val player = current
        if (player == null) {
            // Not an error worth an exception: "nothing is playing" is an
            // ordinary answer to "can I borrow the video". Logged rather than
            // returned silently, because a bubble that shows no picture and no
            // reason is indistinguishable from a broken one.
            Log.i(TAG, "$what: no player registered")
            return false
        }
        if (Looper.myLooper() != Looper.getMainLooper()) {
            // ExoPlayer is built on the main looper here, and setVideoSurface
            // must run on the player's application thread or media3 throws.
            // Posting loses the return value, so this reports "requested" —
            // the in-practice path is main-thread and answers honestly.
            main.post { runPlayerAction(what, player, action) }
            return true
        }
        return runPlayerAction(what, player, action)
    }

    private fun runPlayerAction(
        what: String,
        player: BetterPlayer,
        action: (BetterPlayer) -> Unit
    ): Boolean = try {
        action(player)
        true
    } catch (e: Exception) {
        // Almost always a released ExoPlayer: the app was swiped out of recents
        // while the bubble was up, so dispose() ran between the null check and
        // here. Logged, never rethrown — a failed handoff must not take down a
        // foreground service that is holding the user's audio.
        Log.w(TAG, "$what failed", e)
        false
    }
}
