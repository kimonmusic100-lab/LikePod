# The app reaches this type by name. It calls ExoPlayer.setPreferredAudioDevice
# directly, which also keeps that method in the release build.
-keep class com.ryanheise.just_audio.UsbPreferredDevice { *; }
-keepclassmembers class com.ryanheise.just_audio.UsbDirectSink {
    public static boolean inDirect();
}
-keep class com.likepod.likepod.UsbExclusiveNative { *; }
-keepclassmembers class androidx.media3.exoplayer.ExoPlayerImpl {
    public void setPreferredAudioDevice(android.media.AudioDeviceInfo);
}
-keepclassmembers class * {
    public void setPreferredAudioDevice(android.media.AudioDeviceInfo);
}
