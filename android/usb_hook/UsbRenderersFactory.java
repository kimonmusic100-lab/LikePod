package com.ryanheise.just_audio;

import android.content.Context;
import androidx.media3.exoplayer.DefaultRenderersFactory;
import androidx.media3.exoplayer.audio.AudioSink;

/** Same renderers as just_audio, with a sink that can write PCM straight to USB. */
public final class UsbRenderersFactory extends DefaultRenderersFactory {
    public UsbRenderersFactory(Context context) {
        super(context);
    }

    @Override
    protected AudioSink buildAudioSink(
            Context context,
            boolean enableFloatOutput,
            boolean enableAudioTrackPlaybackParams) {
        AudioSink inner = super.buildAudioSink(context, enableFloatOutput, enableAudioTrackPlaybackParams);
        if (inner == null) {
            return null;
        }
        return new UsbDirectSink(inner);
    }
}
