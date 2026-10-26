#ifndef LIKEPOD_USB_DESC_H
#define LIKEPOD_USB_DESC_H

#include <stdint.h>

/* One PCM playback alternate setting chosen from a USB audio descriptor. */
typedef struct {
    int interface_number;
    int alt;
    int protocol;
    int channels;
    int bits;
    int subframe;
    int endpoint;
    int max_packet;
    int interval;
    int feedback;
    int clock_id;
    int ac_interface;
    int terminal_link;
    int chosen_rate;
    int resampled;
    int continuous;
    int rate_min;
    int rate_max;
    int rate_count;
    int rates[8];
} UsbStreamInfo;

/* 0 on success. On failure returns -1 and writes a short UTF-8 reason. */
int usb_desc_choose(const uint8_t* desc, int length, int wanted_rate, UsbStreamInfo* out, char* error, int error_cap);

#endif
