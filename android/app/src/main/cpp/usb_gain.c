#include "usb_gain.h"

#include <string.h>

uint32_t usb_gain_from_unit(float linear) {
    if (!(linear > 0.f)) {
        return 0;
    }
    if (linear >= 1.f) {
        return USB_GAIN_UNITY;
    }
    float scaled = linear * 32768.f;
    if (!(scaled < 32768.f)) {
        return USB_GAIN_UNITY;
    }
    return (uint32_t)(scaled + 0.5f);
}

float usb_gain_to_unit(uint32_t gain_q15) {
    if (gain_q15 >= USB_GAIN_UNITY) {
        return 1.f;
    }
    return (float)gain_q15 / 32768.f;
}

uint32_t usb_gain_min(uint32_t a, uint32_t b) {
    if (a > USB_GAIN_UNITY) {
        a = USB_GAIN_UNITY;
    }
    if (b > USB_GAIN_UNITY) {
        b = USB_GAIN_UNITY;
    }
    return a < b ? a : b;
}

uint32_t usb_gain_from_ui_q15(uint32_t ui_q15) {
    if (ui_q15 == 0) {
        return 0;
    }
    if (ui_q15 > USB_GAIN_UNITY) {
        ui_q15 = USB_GAIN_UNITY;
    }
    /* round(ui^3 * ceiling), with ui = ui_q15/32768. Denominator is 32768^3. */
    uint64_t u = ui_q15;
    uint64_t num = u * u * u * (uint64_t)USB_GAIN_CEILING_Q15;
    const uint64_t den = 35184372088832ULL;
    uint64_t q = (num + (den / 2u)) / den;
    if (q > USB_GAIN_CEILING_Q15) {
        q = USB_GAIN_CEILING_Q15;
    }
    return (uint32_t)q;
}

uint32_t usb_gain_from_ui(float ui) {
    return usb_gain_from_ui_q15(usb_gain_from_unit(ui));
}

static int32_t scale_sample(int32_t sample, uint32_t gain_q15) {
    if (gain_q15 >= USB_GAIN_UNITY) {
        return sample;
    }
    if (gain_q15 == 0 || sample == 0) {
        return 0;
    }
    /* Round so a 1-LSB gain still moves a full-scale sample to ±1. */
    int64_t num = (int64_t)sample * (int64_t)gain_q15;
    if (num >= 0) {
        return (int32_t)((num + 16384) / 32768);
    }
    return (int32_t)((num - 16384) / 32768);
}

static void apply_s16(uint8_t* pcm, int bytes, uint32_t gain_q15) {
    for (int i = 0; i + 1 < bytes; i += 2) {
        int32_t sample = (int32_t)(int16_t)((uint16_t)pcm[i] | ((uint16_t)pcm[i + 1] << 8));
        int32_t scaled = scale_sample(sample, gain_q15);
        if (scaled > 32767) {
            scaled = 32767;
        } else if (scaled < -32768) {
            scaled = -32768;
        }
        pcm[i] = (uint8_t)scaled;
        pcm[i + 1] = (uint8_t)(scaled >> 8);
    }
}

static void apply_s24(uint8_t* pcm, int bytes, uint32_t gain_q15) {
    for (int i = 0; i + 2 < bytes; i += 3) {
        int32_t sample = (int32_t)pcm[i] | ((int32_t)pcm[i + 1] << 8) | ((int32_t)pcm[i + 2] << 16);
        if (sample & 0x800000) {
            sample |= ~0xFFFFFF;
        }
        int32_t scaled = scale_sample(sample, gain_q15);
        if (scaled > 8388607) {
            scaled = 8388607;
        } else if (scaled < -8388608) {
            scaled = -8388608;
        }
        pcm[i] = (uint8_t)scaled;
        pcm[i + 1] = (uint8_t)(scaled >> 8);
        pcm[i + 2] = (uint8_t)(scaled >> 16);
    }
}

static void apply_s32(uint8_t* pcm, int bytes, uint32_t gain_q15) {
    for (int i = 0; i + 3 < bytes; i += 4) {
        uint32_t bits = (uint32_t)pcm[i] |
            ((uint32_t)pcm[i + 1] << 8) |
            ((uint32_t)pcm[i + 2] << 16) |
            ((uint32_t)pcm[i + 3] << 24);
        int32_t scaled = scale_sample((int32_t)bits, gain_q15);
        pcm[i] = (uint8_t)scaled;
        pcm[i + 1] = (uint8_t)(scaled >> 8);
        pcm[i + 2] = (uint8_t)(scaled >> 16);
        pcm[i + 3] = (uint8_t)(scaled >> 24);
    }
}

void usb_gain_apply(uint8_t* pcm, int bytes, int bytes_per_sample, uint32_t gain_q15) {
    if (pcm == NULL || bytes <= 0) {
        return;
    }
    if (gain_q15 > USB_GAIN_UNITY) {
        gain_q15 = USB_GAIN_UNITY;
    }
    if (bytes_per_sample != 2 && bytes_per_sample != 3 && bytes_per_sample != 4) {
        memset(pcm, 0, (size_t)bytes);
        return;
    }
    if (gain_q15 >= USB_GAIN_UNITY) {
        return;
    }
    if (bytes_per_sample == 2) {
        apply_s16(pcm, bytes, gain_q15);
    } else if (bytes_per_sample == 3) {
        apply_s24(pcm, bytes, gain_q15);
    } else {
        apply_s32(pcm, bytes, gain_q15);
    }
}
