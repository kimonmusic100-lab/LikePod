#ifndef LIKEPOD_USB_GAIN_H
#define LIKEPOD_USB_GAIN_H

#include <stdint.h>

/* Q15 amplitudes. 32768 == 1.0 (unity, samples unchanged). 0 == silence.
   UI positions are stored in this scale, then mapped to a much smaller
   PCM multiplier: (ui^3) times a −12 dBFS ceiling (8230). 4% UI is about
   one 16-bit LSB (−90 dB), not the old linear 0.04 (−28 dB). 100% UI
   never reaches digital full scale. Unknown UI starts at 10% (3277).
   Multiply when an isochronous packet is filled so a new gain hits the
   next packet without flushing PCM already queued. Never amplify.
*/
#define USB_GAIN_UNITY 32768u
#define USB_GAIN_CEILING_Q15 8230u
#define USB_GAIN_UI_SAFE 3277u

uint32_t usb_gain_from_unit(float linear);
float usb_gain_to_unit(uint32_t gain_q15);
uint32_t usb_gain_min(uint32_t a, uint32_t b);

/* Cubic UI fraction, then the −12 dB ceiling. Monotonic. Never above the ceiling. */
uint32_t usb_gain_from_ui_q15(uint32_t ui_q15);
uint32_t usb_gain_from_ui(float ui);

/* In-place little-endian PCM. bytes_per_sample is 2, 3, or 4.
   Any other width is silenced. Unity leaves bytes unchanged.
*/
void usb_gain_apply(uint8_t* pcm, int bytes, int bytes_per_sample, uint32_t gain_q15);

#endif
