#ifndef LIKEPOD_USB_PACKET_H
#define LIKEPOD_USB_PACKET_H

#include <stdint.h>

/* Samples for one isochronous service interval.

   feedback_q16 is samples-per-interval in 16.16 fixed point.
   Over a second the sum stays on the USB clock instead of AudioFlinger's 48 kHz.
*/
static inline int usb_packet_frames(uint32_t* acc, uint32_t feedback_q16, int max_frames) {
    if (max_frames < 1) {
        max_frames = 1;
    }
    *acc += feedback_q16;
    int frames = (int)(*acc >> 16);
    *acc &= 0xFFFFu;
    if (frames < 0) {
        frames = 0;
    }
    if (frames > max_frames) {
        uint32_t extra = (uint32_t)(frames - max_frames);
        frames = max_frames;
        *acc += extra << 16;
    }
    return frames;
}

static inline uint32_t usb_nominal_q16(uint32_t sample_rate, uint32_t packets_per_sec) {
    if (packets_per_sec == 0) {
        packets_per_sec = 1000;
    }
    return (uint32_t)(((uint64_t)sample_rate << 16) / packets_per_sec);
}

#endif
