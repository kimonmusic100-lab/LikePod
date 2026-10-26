#include "usb_desc.h"
#include "usb_packet.h"

#include <stdio.h>
#include <string.h>

static int g_failures = 0;

static void expect(int cond, const char* message) {
    if (!cond) {
        fprintf(stderr, "FAIL %s\n", message);
        g_failures++;
    }
}

static void push(uint8_t* buf, int* len, const uint8_t* src, int n) {
    memcpy(buf + *len, src, (size_t)n);
    *len += n;
}

static void test_packets(void) {
    uint32_t acc = 0;
    uint32_t q16 = usb_nominal_q16(44100, 1000);
    int sum = 0;
    for (int i = 0; i < 1000; i++) {
        sum += usb_packet_frames(&acc, q16, 200);
    }
    /* 16.16 nominal loses at most one sample per second. */
    expect(sum >= 44099 && sum <= 44100, "44100 full-speed frames");

    acc = 0;
    q16 = usb_nominal_q16(44100, 8000);
    sum = 0;
    for (int i = 0; i < 8000; i++) {
        int frames = usb_packet_frames(&acc, q16, 16);
        expect(frames >= 5 && frames <= 6, "high-speed packet is 5 or 6 frames");
        sum += frames;
    }
    expect(sum >= 44099 && sum <= 44100, "44100 high-speed frames");
}

static void test_uac1(void) {
    uint8_t raw[256];
    int len = 0;
    const uint8_t device[] = {18, 1, 0, 2, 0, 0, 0, 64, 0, 0, 0, 0, 0, 1, 0, 0, 0, 1};
    const uint8_t ac[] = {9, 4, 0, 0, 0, 1, 1, 0, 0};
    const uint8_t as0[] = {9, 4, 1, 0, 0, 1, 2, 0, 0};
    const uint8_t as1[] = {9, 4, 1, 1, 1, 1, 2, 0, 0};
    const uint8_t general[] = {7, 0x24, 1, 1, 1, 1, 0};
    const uint8_t format[] = {
        14, 0x24, 2, 1, 2, 2, 16, 2,
        0x44, 0xAC, 0x00,
        0x80, 0xBB, 0x00
    };
    const uint8_t endpoint[] = {9, 5, 0x01, 0x05, 0xC0, 0x00, 1, 0, 0x81};
    uint8_t body[128];
    int body_len = 0;
    push(body, &body_len, ac, 9);
    push(body, &body_len, as0, 9);
    push(body, &body_len, as1, 9);
    push(body, &body_len, general, 7);
    push(body, &body_len, format, 14);
    push(body, &body_len, endpoint, 9);
    int total = 9 + body_len;
    const uint8_t config[] = {9, 2, (uint8_t)(total & 0xFF), (uint8_t)((total >> 8) & 0xFF), 2, 1, 0, 0x80, 50};
    push(raw, &len, device, 18);
    push(raw, &len, config, 9);
    push(raw, &len, body, body_len);

    UsbStreamInfo info;
    char error[80];
    int rc = usb_desc_choose(raw, len, 44100, &info, error, 80);
    expect(rc == 0, error);
    expect(info.interface_number == 1, "uac1 interface");
    expect(info.alt == 1, "uac1 alt");
    expect(info.channels == 2, "uac1 channels");
    expect(info.bits == 16, "uac1 bits");
    expect(info.subframe == 2, "uac1 subframe");
    expect(info.endpoint == 0x01, "uac1 endpoint");
    expect(info.max_packet == 192, "uac1 packet");
    expect(info.feedback == 0x81, "uac1 feedback");
    expect(info.chosen_rate == 44100, "uac1 follows 44.1");
    expect(info.resampled == 0, "uac1 not resampled");
    expect(info.protocol == 0, "uac1 protocol");

    rc = usb_desc_choose(raw, len, 96000, &info, error, 80);
    expect(rc == 0, "uac1 nearest");
    expect(info.chosen_rate == 48000, "nearest is 48 kHz");
    expect(info.resampled == 1, "96 kHz must resample");
}

static void test_uac2(void) {
    uint8_t raw[256];
    int len = 0;
    const uint8_t ac[] = {9, 4, 0, 0, 0, 1, 1, 0x20, 0};
    const uint8_t clock[] = {8, 0x24, 0x0A, 9, 0, 0, 0, 0};
    uint8_t terminal[17];
    memset(terminal, 0, sizeof(terminal));
    terminal[0] = 17;
    terminal[1] = 0x24;
    terminal[2] = 0x02;
    terminal[3] = 1;
    terminal[4] = 0x01;
    terminal[5] = 0x01;
    terminal[7] = 9;
    const uint8_t as[] = {9, 4, 1, 1, 1, 1, 2, 0x20, 0};
    const uint8_t general[] = {
        16, 0x24, 1, 1, 0, 1,
        1, 0, 0, 0,
        2,
        3, 0, 0, 0,
        0
    };
    const uint8_t format[] = {6, 0x24, 2, 1, 3, 24};
    const uint8_t endpoint[] = {9, 5, 0x02, 0x05, 0x00, 0x02, 1, 0, 0};
    uint8_t body[160];
    int body_len = 0;
    push(body, &body_len, ac, 9);
    push(body, &body_len, clock, 8);
    push(body, &body_len, terminal, 17);
    push(body, &body_len, as, 9);
    push(body, &body_len, general, 16);
    push(body, &body_len, format, 6);
    push(body, &body_len, endpoint, 9);
    int total = 9 + body_len;
    const uint8_t config[] = {9, 2, (uint8_t)(total & 0xFF), 0, 2, 1, 0, 0x80, 50};
    push(raw, &len, config, 9);
    push(raw, &len, body, body_len);

    UsbStreamInfo info;
    char error[80];
    int rc = usb_desc_choose(raw, len, 44100, &info, error, 80);
    expect(rc == 0, error[0] ? error : "uac2 choose");
    expect(info.protocol == 0x20, "uac2 protocol");
    expect(info.channels == 2, "uac2 channels");
    expect(info.bits == 24, "uac2 bits");
    expect(info.subframe == 3, "uac2 subframe");
    expect(info.endpoint == 0x02, "uac2 endpoint");
    expect(info.max_packet == 512, "uac2 packet");
    expect(info.clock_id == 9, "uac2 clock");
    expect(info.ac_interface == 0, "uac2 ac");
    expect(info.chosen_rate == 44100, "uac2 programmable 44.1");
    expect(info.resampled == 0, "uac2 not marked resampled");
}

int main(void) {
    test_packets();
    test_uac1();
    test_uac2();
    if (g_failures != 0) {
        fprintf(stderr, "%d failures\n", g_failures);
        return 1;
    }
    printf("usb descriptor and packet tests passed\n");
    return 0;
}
