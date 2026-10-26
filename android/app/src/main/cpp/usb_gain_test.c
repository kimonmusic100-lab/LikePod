#include "usb_gain.h"

#include <stdio.h>
#include <string.h>

static int g_failures = 0;

static void expect(int cond, const char* message) {
    if (!cond) {
        fprintf(stderr, "FAIL %s\n", message);
        g_failures++;
    }
}

static void test_units(void) {
    expect(usb_gain_from_unit(0.f) == 0, "zero");
    expect(usb_gain_from_unit(-1.f) == 0, "negative clamps to silence");
    expect(usb_gain_from_unit(0.10f) == USB_GAIN_UI_SAFE, "10 percent UI");
    expect(usb_gain_from_unit(1.f) == USB_GAIN_UNITY, "unity");
    expect(usb_gain_from_unit(2.f) == USB_GAIN_UNITY, "never amplify");
    expect(usb_gain_to_unit(USB_GAIN_UNITY) == 1.f, "unity reads back");
    expect(usb_gain_min(usb_gain_from_unit(0.2f), USB_GAIN_UNITY) == usb_gain_from_unit(0.2f), "min with unity");
    expect(usb_gain_min(USB_GAIN_UNITY, usb_gain_from_unit(0.3f)) == usb_gain_from_unit(0.3f), "stream can duck player");
}

static void test_curve(void) {
    uint32_t linear4 = usb_gain_from_unit(0.04f);
    uint32_t curved4 = usb_gain_from_ui(0.04f);
    expect(curved4 > 0, "4 percent is one quiet step, not hard mute");
    expect(curved4 * 16u < linear4, "4 percent is much quieter than 0.04 linear");
    expect(usb_gain_from_ui(0.f) == 0, "zero UI is silence");
    expect(usb_gain_from_ui(1.f) == USB_GAIN_CEILING_Q15, "100 percent is the -12 dB ceiling");
    expect(usb_gain_from_ui(1.f) < USB_GAIN_UNITY, "100 percent is not digital full scale");
    expect(usb_gain_from_ui(1.5f) == USB_GAIN_CEILING_Q15, "UI above 1 does not amplify");
    uint32_t ten = usb_gain_from_ui_q15(USB_GAIN_UI_SAFE);
    expect(ten > curved4, "10 percent is louder than 4 percent");
    expect(ten * 8u < USB_GAIN_UI_SAFE, "10 percent perceptual is far below 10 percent linear");
    uint32_t prev = 0;
    const float steps[] = {0.f, 0.04f, 0.08f, 0.16f, 0.32f, 0.5f, 0.75f, 1.f};
    for (int i = 0; i < 8; i++) {
        uint32_t gain = usb_gain_from_ui(steps[i]);
        expect(gain >= prev, "curve is monotonic");
        prev = gain;
    }
    /* Lower control wins, then the curve. Same as curving each and taking min. */
    uint32_t low = usb_gain_from_ui_q15(usb_gain_min(usb_gain_from_unit(0.04f), usb_gain_from_unit(0.8f)));
    expect(low == curved4, "min of controls then curve matches the lower control");
}

static void test_s16(void) {
    uint8_t pcm[4] = {0xFF, 0x7F, 0x00, 0x80};
    usb_gain_apply(pcm, 4, 2, USB_GAIN_UNITY);
    expect(pcm[0] == 0xFF && pcm[1] == 0x7F && pcm[2] == 0x00 && pcm[3] == 0x80, "unity is bit-exact");

    uint8_t quiet[2] = {0xFF, 0x7F};
    usb_gain_apply(quiet, 2, 2, 0);
    expect(quiet[0] == 0 && quiet[1] == 0, "zero gain is silence");

    uint8_t lsb[2] = {0xFF, 0x7F};
    usb_gain_apply(lsb, 2, 2, 1);
    int16_t faint = (int16_t)((uint16_t)lsb[0] | ((uint16_t)lsb[1] << 8));
    expect(faint == 1, "one LSB of gain still yields a 16-bit step");

    uint8_t quarter[2] = {0xFF, 0x7F};
    usb_gain_apply(quarter, 2, 2, 8192);
    int16_t got = (int16_t)((uint16_t)quarter[0] | ((uint16_t)quarter[1] << 8));
    expect(got > 8000 && got < 8300, "25 percent of full scale is near 8192");

    uint8_t half[2] = {0xE8, 0x03}; /* 1000 */
    usb_gain_apply(half, 2, 2, usb_gain_from_unit(0.5f));
    int16_t halved = (int16_t)((uint16_t)half[0] | ((uint16_t)half[1] << 8));
    expect(halved == 500, "half of 1000");
}

static void test_wider(void) {
    uint8_t s24[3] = {0x00, 0xFF, 0x7F};
    usb_gain_apply(s24, 3, 3, USB_GAIN_UNITY);
    expect(s24[0] == 0x00 && s24[1] == 0xFF && s24[2] == 0x7F, "24-bit unity unchanged");
    usb_gain_apply(s24, 3, 3, 0);
    expect(s24[0] == 0 && s24[1] == 0 && s24[2] == 0, "24-bit silence");

    uint8_t bad[4] = {1, 2, 3, 4};
    usb_gain_apply(bad, 4, 1, USB_GAIN_UNITY);
    expect(bad[0] == 0 && bad[1] == 0 && bad[2] == 0 && bad[3] == 0, "unknown width is silenced");
}

int main(void) {
    test_units();
    test_curve();
    test_s16();
    test_wider();
    if (g_failures != 0) {
        fprintf(stderr, "%d failures\n", g_failures);
        return 1;
    }
    printf("usb_gain ok\n");
    return 0;
}
