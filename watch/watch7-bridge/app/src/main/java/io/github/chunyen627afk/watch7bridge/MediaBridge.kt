package io.github.chunyen627afk.watch7bridge

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context
import android.media.MediaMetadata
import android.media.VolumeProvider
import android.media.session.MediaSession
import android.media.session.PlaybackState
import io.github.chunyen627afk.watch7bridge.ancs.Ams

/**
 * 把 iPhone 正在播放的媒體鏡射成手錶本機的媒體工作階段，
 * 讓手錶內建的媒體控制畫面與錶圈音量可以直接操作 iPhone。
 */
class MediaBridge(private val ctx: Context, private val send: (Int) -> Unit) {

    private val nm = ctx.getSystemService(NotificationManager::class.java)
    private val session = MediaSession(ctx, "iPhone")
    private var title = ""
    private var artist = ""
    private var playing = false

    private val volume = object : VolumeProvider(VOLUME_CONTROL_RELATIVE, VOLUME_STEPS, VOLUME_STEPS / 2) {
        override fun onAdjustVolume(direction: Int) {
            if (direction > 0) send(Ams.CMD_VOLUME_UP)
            if (direction < 0) send(Ams.CMD_VOLUME_DOWN)
        }
    }

    init {
        nm.createNotificationChannel(
            NotificationChannel(CHANNEL, "iPhone 媒體", NotificationManager.IMPORTANCE_LOW),
        )
        session.setCallback(object : MediaSession.Callback() {
            override fun onPlay() = send(Ams.CMD_PLAY)
            override fun onPause() = send(Ams.CMD_PAUSE)
            override fun onSkipToNext() = send(Ams.CMD_NEXT)
            override fun onSkipToPrevious() = send(Ams.CMD_PREVIOUS)
        })
        session.setPlaybackToRemote(volume)
    }

    fun setTrack(title: String, artist: String) {
        this.title = title
        this.artist = artist
        publish()
    }

    fun setPlaying(playing: Boolean) {
        this.playing = playing
        publish()
    }

    /** iPhone 回報的音量為 0 到 1。 */
    fun setVolume(fraction: Float) {
        volume.currentVolume = (fraction.coerceIn(0f, 1f) * VOLUME_STEPS).toInt()
    }

    fun clear() {
        title = ""
        artist = ""
        playing = false
        publish()
    }

    fun release() {
        nm.cancel(NOTIFICATION_ID)
        session.release()
    }

    private fun publish() {
        if (title.isBlank()) {
            session.isActive = false
            nm.cancel(NOTIFICATION_ID)
            return
        }
        session.setMetadata(
            MediaMetadata.Builder()
                .putString(MediaMetadata.METADATA_KEY_TITLE, title)
                .putString(MediaMetadata.METADATA_KEY_ARTIST, artist)
                .build(),
        )
        session.setPlaybackState(
            PlaybackState.Builder()
                .setActions(
                    PlaybackState.ACTION_PLAY or PlaybackState.ACTION_PAUSE or
                        PlaybackState.ACTION_PLAY_PAUSE or
                        PlaybackState.ACTION_SKIP_TO_NEXT or PlaybackState.ACTION_SKIP_TO_PREVIOUS,
                )
                .setState(
                    if (playing) PlaybackState.STATE_PLAYING else PlaybackState.STATE_PAUSED,
                    PlaybackState.PLAYBACK_POSITION_UNKNOWN,
                    if (playing) 1f else 0f,
                )
                .build(),
        )
        session.isActive = true
        nm.notify(
            NOTIFICATION_ID,
            Notification.Builder(ctx, CHANNEL)
                .setSmallIcon(R.drawable.ic_link)
                .setContentTitle(title)
                .setContentText(artist)
                .setOngoing(playing)
                .setOnlyAlertOnce(true)
                .setStyle(Notification.MediaStyle().setMediaSession(session.sessionToken))
                .build(),
        )
    }

    private companion object {
        const val CHANNEL = "media"
        const val NOTIFICATION_ID = 2
        const val VOLUME_STEPS = 16
    }
}
