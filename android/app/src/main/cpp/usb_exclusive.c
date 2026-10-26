#include "usb_desc.h"
#include "usb_gain.h"
#include "usb_packet.h"

#include <android/log.h>
#include <errno.h>
#include <fcntl.h>
#include <jni.h>
#include <sys/ioctl.h>
#include <linux/usbdevice_fs.h>
#include <pthread.h>
#include <sched.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <sys/syscall.h>
#include <unistd.h>

#ifndef USBDEVFS_FORBID_SUSPEND
#define USBDEVFS_FORBID_SUSPEND _IO('U', 33)
#endif

static void ensure_death_method(JNIEnv* env);

#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, "LikePod", __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, "LikePod", __VA_ARGS__)

#define URB_COUNT 12
#define MAX_PACKETS 8
#define RING_CAP (256 * 1024)

typedef struct {
    struct usbdevfs_urb* urb;
    uint8_t* buffer;
    int pcm_frames;
    int in_flight;
    int feedback;
    uint32_t epoch;
} UrbSlot;

static JavaVM* g_vm = NULL;
static jclass g_class = NULL;
static jmethodID g_died = NULL;

static pthread_t g_thread;
static int g_thread_started = 0;
static pthread_mutex_t g_mu = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t g_play_cv = PTHREAD_COND_INITIALIZER;

static void wake_playback_wait(void) {
    pthread_mutex_lock(&g_mu);
    pthread_cond_broadcast(&g_play_cv);
    pthread_mutex_unlock(&g_mu);
}

static int g_fd = -1;
static int g_ep_out = 0;
static int g_ep_fb = 0;
static int g_rate = 0;
static int g_frame_bytes = 0;
static int g_subframe = 0;
static atomic_uint g_player_q15 = USB_GAIN_UNITY;
static atomic_uint g_stream_q15 = USB_GAIN_UI_SAFE;
static atomic_int g_stream_known = 0;
static int g_max_packet = 0;
static int g_packets = 1;
static uint32_t g_fb_q16 = 0;
static uint32_t g_fb_acc = 0;
static uint32_t g_nominal_q16 = 0;
static uint32_t g_epoch = 1;
static atomic_int g_running = 0;
static atomic_int g_playing = 0;
static atomic_ullong g_played = 0;
/* Bytes the player has pushed since the stream opened. URB completions do
   not increment this, so a ring that is only draining does not look alive. */
static atomic_ullong g_fed = 0;
static int g_died_sent = 0;

static uint8_t* g_ring = NULL;
static uint32_t g_ring_r = 0;
static uint32_t g_ring_used = 0;

/* Wheel click. The clip peaks near −1.6 dBFS. Q15 623 brings that peak to
   −36 dBFS. The music curve wins when it is quieter, so the click sits under
   the song instead of punching through at a fixed loud level. */
#define CLICK_MAX 16384
#define CLICK_CAP_Q15 623
static int16_t g_click[CLICK_MAX];
static int g_click_frames = 0;
static int g_click_pos = 0;
static pthread_mutex_t g_click_mu = PTHREAD_MUTEX_INITIALIZER;

static int g_keepawake = 0;
static UrbSlot g_slots[URB_COUNT];
static UrbSlot g_feedback;

static void notify_died(const char* reason) {
    atomic_store(&g_running, 0);
    if (g_died_sent || g_vm == NULL) {
        g_died_sent = 1;
        return;
    }
    g_died_sent = 1;
    JNIEnv* env = NULL;
    int attached = 0;
    if ((*g_vm)->GetEnv(g_vm, (void**)&env, JNI_VERSION_1_6) != JNI_OK) {
        if ((*g_vm)->AttachCurrentThread(g_vm, &env, NULL) != 0) {
            return;
        }
        attached = 1;
    }
    ensure_death_method(env);
    if (g_class == NULL || g_died == NULL) {
        if (attached) {
            (*g_vm)->DetachCurrentThread(g_vm);
        }
        return;
    }
    jstring text = (*env)->NewStringUTF(env, reason != NULL ? reason : "等时传输中断");
    (*env)->CallStaticVoidMethod(env, g_class, g_died, text);
    (*env)->ExceptionClear(env);
    if (attached) {
        (*g_vm)->DetachCurrentThread(g_vm);
    }
}

static uint32_t applied_ui_q15(void) {
    uint32_t player = atomic_load(&g_player_q15);
    uint32_t stream = atomic_load(&g_stream_known) ? atomic_load(&g_stream_q15) : USB_GAIN_UI_SAFE;
    return usb_gain_min(player, stream);
}

static uint32_t applied_gain_q15(void) {
    return usb_gain_from_ui_q15(applied_ui_q15());
}

static void clear_click(void) {
    pthread_mutex_lock(&g_click_mu);
    g_click_frames = 0;
    g_click_pos = 0;
    pthread_mutex_unlock(&g_click_mu);
}

static int32_t read_wire(const uint8_t* p, int subframe) {
    if (subframe == 2) {
        return (int16_t)((uint16_t)p[0] | ((uint16_t)p[1] << 8));
    }
    if (subframe == 3) {
        int32_t sample = (int32_t)p[0] | ((int32_t)p[1] << 8) | ((int32_t)p[2] << 16);
        if (sample & 0x800000) {
            sample |= ~0xFFFFFF;
        }
        return sample;
    }
    if (subframe == 4) {
        uint32_t bits = (uint32_t)p[0] |
            ((uint32_t)p[1] << 8) |
            ((uint32_t)p[2] << 16) |
            ((uint32_t)p[3] << 24);
        return (int32_t)bits;
    }
    return 0;
}

static void write_wire(uint8_t* p, int subframe, int32_t sample) {
    if (subframe == 2) {
        if (sample > 32767) sample = 32767;
        if (sample < -32768) sample = -32768;
    } else if (subframe == 3) {
        if (sample > 8388607) sample = 8388607;
        if (sample < -8388608) sample = -8388608;
    }
    for (int i = 0; i < subframe && i < 4; i++) {
        p[i] = (uint8_t)(sample >> (8 * i));
    }
}

static void mix_click(uint8_t* dst, int bytes) {
    if (dst == NULL || bytes <= 0 || g_frame_bytes <= 0 || g_subframe <= 0) {
        return;
    }
    int channels = g_frame_bytes / g_subframe;
    if (channels <= 0) {
        return;
    }
    uint32_t music = applied_gain_q15();
    uint32_t gain = music < CLICK_CAP_Q15 ? music : CLICK_CAP_Q15;
    pthread_mutex_lock(&g_click_mu);
    int frames = bytes / g_frame_bytes;
    for (int frame = 0; frame < frames && g_click_pos < g_click_frames; frame++) {
        int32_t add = g_click[g_click_pos++];
        add = (int32_t)(((int64_t)add * (int64_t)gain) / 32768);
        if (g_subframe == 3) {
            add <<= 8;
        } else if (g_subframe >= 4) {
            add <<= 16;
        }
        uint8_t* base = dst + frame * g_frame_bytes;
        for (int ch = 0; ch < channels; ch++) {
            uint8_t* sample = base + ch * g_subframe;
            int64_t sum = (int64_t)read_wire(sample, g_subframe) + add;
            int64_t limit = g_subframe == 2 ? 32767 : (g_subframe == 3 ? 8388607 : 2147483647LL);
            if (sum > limit) sum = limit;
            if (sum < -limit - 1) sum = -limit - 1;
            write_wire(sample, g_subframe, (int32_t)sum);
        }
    }
    pthread_mutex_unlock(&g_click_mu);
}

static int ring_take(uint8_t* dst, int bytes) {
    if (bytes <= 0) {
        return 0;
    }
    pthread_mutex_lock(&g_mu);
    int take = bytes;
    if (g_ring == NULL || !atomic_load(&g_playing)) {
        take = 0;
    } else {
        if ((int)g_ring_used < take) {
            take = (int)g_ring_used;
        }
        if (g_frame_bytes > 0) {
            take -= take % g_frame_bytes;
        }
    }
    for (int i = 0; i < take; i++) {
        dst[i] = g_ring[g_ring_r];
        g_ring_r = (g_ring_r + 1u) & (RING_CAP - 1u);
    }
    g_ring_used -= (uint32_t)take;
    pthread_mutex_unlock(&g_mu);
    if (take > 0) {
        usb_gain_apply(dst, take, g_subframe, applied_gain_q15());
    }
    if (take < bytes) {
        memset(dst + take, 0, (size_t)(bytes - take));
    }
    mix_click(dst, bytes);
    return take;
}

static int submit_playback(UrbSlot* slot) {
    int packets = g_packets;
    if (packets < 1) {
        packets = 1;
    }
    if (packets > MAX_PACKETS) {
        packets = MAX_PACKETS;
    }
    int max_frames = g_frame_bytes > 0 ? g_max_packet / g_frame_bytes : 1;
    if (max_frames < 1) {
        max_frames = 1;
    }
    int offset = 0;
    int pcm_frames = 0;
    struct usbdevfs_urb* urb = slot->urb;
    memset(urb, 0, sizeof(*urb));
    for (int p = 0; p < packets; p++) {
        int frames = usb_packet_frames(&g_fb_acc, g_fb_q16, max_frames);
        int bytes = frames * g_frame_bytes;
        if (offset + bytes > packets * g_max_packet) {
            bytes = 0;
            frames = 0;
        }
        int got = ring_take(slot->buffer + offset, bytes);
        pcm_frames += g_frame_bytes > 0 ? got / g_frame_bytes : 0;
        urb->iso_frame_desc[p].length = (unsigned int)bytes;
        urb->iso_frame_desc[p].actual_length = 0;
        urb->iso_frame_desc[p].status = 0;
        offset += bytes;
    }
    urb->type = USBDEVFS_URB_TYPE_ISO;
    urb->endpoint = (unsigned char)g_ep_out;
    urb->flags = USBDEVFS_URB_ISO_ASAP;
    urb->buffer = slot->buffer;
    urb->buffer_length = offset;
    urb->number_of_packets = packets;
    urb->usercontext = slot;
    slot->pcm_frames = pcm_frames;
    slot->epoch = g_epoch;
    slot->feedback = 0;
    int rc = ioctl(g_fd, USBDEVFS_SUBMITURB, urb);
    if (rc < 0) {
        slot->in_flight = 0;
        return -errno;
    }
    slot->in_flight = 1;
    return 0;
}

static int submit_feedback(void) {
    if (g_ep_fb == 0 || g_feedback.urb == NULL) {
        return 0;
    }
    struct usbdevfs_urb* urb = g_feedback.urb;
    memset(urb, 0, sizeof(*urb));
    urb->type = USBDEVFS_URB_TYPE_ISO;
    urb->endpoint = (unsigned char)g_ep_fb;
    urb->flags = USBDEVFS_URB_ISO_ASAP;
    urb->buffer = g_feedback.buffer;
    urb->buffer_length = 16;
    urb->number_of_packets = 1;
    urb->iso_frame_desc[0].length = 16;
    urb->usercontext = &g_feedback;
    g_feedback.feedback = 1;
    g_feedback.pcm_frames = 0;
    int rc = ioctl(g_fd, USBDEVFS_SUBMITURB, urb);
    if (rc < 0) {
        g_feedback.in_flight = 0;
        LOGI("USB feedback submit failed: %s", strerror(errno));
        return 0;
    }
    g_feedback.in_flight = 1;
    return 0;
}

static void apply_feedback(const uint8_t* data, int length) {
    uint32_t q16 = 0;
    if (g_packets > 1 && length >= 4) {
        q16 = (uint32_t)data[0]
            | ((uint32_t)data[1] << 8)
            | ((uint32_t)data[2] << 16)
            | ((uint32_t)data[3] << 24);
    } else if (length >= 3) {
        uint32_t raw = (uint32_t)data[0]
            | ((uint32_t)data[1] << 8)
            | ((uint32_t)data[2] << 16);
        q16 = raw << 2;
    }
    if (q16 == 0 || g_nominal_q16 == 0) {
        return;
    }
    if (q16 < g_nominal_q16 / 2 || q16 > g_nominal_q16 * 2) {
        return;
    }
    g_fb_q16 = q16;
}

static atomic_ullong g_late = 0;

/* The isochronous thread has to be rescheduled with the audio threads.
   A background timeslice that arrives after the queued URBs have expired
   completes them as -EXDEV and the DAC goes silent while the player clock
   keeps moving. */
static void raise_thread_priority(void) {
    struct sched_param param;
    memset(&param, 0, sizeof(param));
    param.sched_priority = 2;
    if (sched_setscheduler(0, SCHED_FIFO, &param) != 0) {
        pid_t tid = (pid_t)syscall(SYS_gettid);
        if (setpriority(PRIO_PROCESS, tid, -19) != 0) {
            LOGI("USB thread nice skipped: %s", strerror(errno));
        }
    }
    if (g_vm == NULL) {
        return;
    }
    JNIEnv* env = NULL;
    if ((*g_vm)->AttachCurrentThread(g_vm, &env, NULL) != 0) {
        return;
    }
    jclass process = (*env)->FindClass(env, "android/os/Process");
    if (process != NULL) {
        jmethodID set = (*env)->GetStaticMethodID(env, process, "setThreadPriority", "(I)V");
        if (set != NULL) {
            /* THREAD_PRIORITY_URGENT_AUDIO */
            (*env)->CallStaticVoidMethod(env, process, set, -19);
            if ((*env)->ExceptionCheck(env)) {
                LOGI("USB thread priority refused");
                (*env)->ExceptionClear(env);
            }
        }
        (*env)->DeleteLocalRef(env, process);
    } else {
        (*env)->ExceptionClear(env);
    }
    (*g_vm)->DetachCurrentThread(g_vm);
}

static void* stream_main(void* arg) {
    (void)arg;
    raise_thread_priority();
    while (atomic_load(&g_running)) {
        if (!atomic_load(&g_playing)) {
            pthread_mutex_lock(&g_mu);
            while (atomic_load(&g_running) && !atomic_load(&g_playing)) {
                pthread_cond_wait(&g_play_cv, &g_mu);
            }
            pthread_mutex_unlock(&g_mu);
            continue;
        }
        struct usbdevfs_urb* done = NULL;
        int rc = ioctl(g_fd, USBDEVFS_REAPURBNDELAY, &done);
        if (rc < 0) {
            if (errno == EAGAIN || errno == EINTR) {
                usleep(200);
                continue;
            }
            LOGE("USB reap failed: %s", strerror(errno));
            notify_died("等时传输中断");
            break;
        }
        UrbSlot* slot = (UrbSlot*)done->usercontext;
        if (slot == NULL) {
            continue;
        }
        slot->in_flight = 0;
        if (!atomic_load(&g_running)) {
            break;
        }
        if (done->status == -EXDEV) {
            unsigned long long late = atomic_fetch_add(&g_late, 1);
            if ((late & 63ull) == 0ull) {
                LOGI("USB isochronous late, dropped %llu", late + 1ull);
            }
        } else if (done->status != 0 && done->status != -EPIPE) {
            LOGE("USB urb status %d", done->status);
            notify_died("等时包被拒绝");
            break;
        }
        if (slot->feedback) {
            if (done->iso_frame_desc[0].actual_length > 0) {
                apply_feedback(slot->buffer, (int)done->iso_frame_desc[0].actual_length);
            }
            submit_feedback();
            continue;
        }
        if (done->status == 0 && slot->epoch == g_epoch && slot->pcm_frames > 0) {
            atomic_fetch_add(&g_played, (unsigned long long)slot->pcm_frames);
        }
        int submit = submit_playback(slot);
        if (submit < 0) {
            LOGE("USB resubmit failed: %d", submit);
            notify_died("等时重交失败");
            break;
        }
        /* The framework can allow autosuspend again when the activity stops.
           Re-assert the forbid on this fd so the DAC is not powered down. */
        if ((g_keepawake++ & 31) == 0 && g_fd >= 0) {
            ioctl(g_fd, USBDEVFS_FORBID_SUSPEND, 0);
        }
    }
    return NULL;
}

static void free_slots(void) {
    for (int i = 0; i < URB_COUNT; i++) {
        free(g_slots[i].urb);
        free(g_slots[i].buffer);
        g_slots[i].urb = NULL;
        g_slots[i].buffer = NULL;
        g_slots[i].in_flight = 0;
    }
    free(g_feedback.urb);
    free(g_feedback.buffer);
    g_feedback.urb = NULL;
    g_feedback.buffer = NULL;
    uint8_t* ring = NULL;
    pthread_mutex_lock(&g_mu);
    ring = g_ring;
    g_ring = NULL;
    g_ring_r = 0;
    g_ring_used = 0;
    pthread_mutex_unlock(&g_mu);
    free(ring);
}

static UrbSlot* alloc_slot(UrbSlot* slot, int packets, int packet_bytes) {
    size_t urb_bytes = sizeof(struct usbdevfs_urb) + (size_t)packets * sizeof(struct usbdevfs_iso_packet_desc);
    slot->urb = calloc(1, urb_bytes);
    slot->buffer = calloc(1, (size_t)packets * (size_t)packet_bytes);
    if (slot->urb == NULL || slot->buffer == NULL) {
        return NULL;
    }
    return slot;
}

static void ensure_death_method(JNIEnv* env) {
    if (g_class != NULL && g_died != NULL) {
        return;
    }
    jclass local = (*env)->FindClass(env, "com/likepod/likepod/UsbExclusiveNative");
    if (local == NULL) {
        (*env)->ExceptionClear(env);
        return;
    }
    g_class = (*env)->NewGlobalRef(env, local);
    (*env)->DeleteLocalRef(env, local);
    g_died = (*env)->GetStaticMethodID(env, g_class, "onStreamDied", "(Ljava/lang/String;)V");
    if (g_died == NULL) {
        (*env)->ExceptionClear(env);
    }
}

JNIEXPORT jint JNICALL JNI_OnLoad(JavaVM* vm, void* reserved) {
    (void)reserved;
    g_vm = vm;
    return JNI_VERSION_1_6;
}

JNIEXPORT jint JNICALL Java_com_likepod_likepod_UsbExclusiveNative_nativeStart(
    JNIEnv* env,
    jclass cls,
    jint fd,
    jint ep_out,
    jint ep_fb,
    jint rate,
    jint channels,
    jint subframe,
    jint max_packet,
    jint packets
) {
    (void)cls;
    ensure_death_method(env);
    if (atomic_load(&g_running)) {
        return -EBUSY;
    }
    if (fd < 0 || ep_out <= 0 || rate <= 0 || channels <= 0 || subframe <= 0 || max_packet <= 0) {
        return -EINVAL;
    }
    if (packets < 1) {
        packets = 1;
    }
    if (packets > MAX_PACKETS) {
        packets = MAX_PACKETS;
    }
    int frame_bytes = channels * subframe;
    if (frame_bytes <= 0 || max_packet < frame_bytes) {
        return -EINVAL;
    }
    int dup = fcntl(fd, F_DUPFD_CLOEXEC, 0);
    if (dup < 0) {
        return -errno;
    }
    memset(g_slots, 0, sizeof(g_slots));
    memset(&g_feedback, 0, sizeof(g_feedback));
    g_ring = calloc(1, RING_CAP);
    if (g_ring == NULL) {
        close(dup);
        return -ENOMEM;
    }
    g_ring_r = 0;
    g_ring_used = 0;
    for (int i = 0; i < URB_COUNT; i++) {
        if (alloc_slot(&g_slots[i], packets, max_packet) == NULL) {
            free_slots();
            close(dup);
            return -ENOMEM;
        }
    }
    if (ep_fb != 0 && alloc_slot(&g_feedback, 1, 16) == NULL) {
        free_slots();
        close(dup);
        return -ENOMEM;
    }
    g_fd = dup;
    if (ioctl(g_fd, USBDEVFS_FORBID_SUSPEND, 0) != 0) {
        LOGI("USB autosuspend forbid skipped: %s", strerror(errno));
    } else {
        LOGI("USB autosuspend forbidden");
    }
    g_ep_out = ep_out;
    g_ep_fb = ep_fb;
    g_rate = rate;
    g_frame_bytes = frame_bytes;
    g_subframe = subframe;
    g_max_packet = max_packet;
    g_packets = packets;
    g_nominal_q16 = usb_nominal_q16((uint32_t)rate, (uint32_t)packets * 1000u);
    g_fb_q16 = g_nominal_q16;
    g_fb_acc = 0;
    g_epoch = 1;
    g_died_sent = 0;
    atomic_store(&g_played, 0);
    atomic_store(&g_fed, 0);
    atomic_store(&g_playing, 1);
    atomic_store(&g_running, 1);

    for (int i = 0; i < URB_COUNT; i++) {
        int rc = submit_playback(&g_slots[i]);
        if (rc < 0) {
            atomic_store(&g_running, 0);
            for (int j = 0; j < i; j++) {
                if (g_slots[j].in_flight) {
                    ioctl(g_fd, USBDEVFS_DISCARDURB, g_slots[j].urb);
                }
            }
            for (int j = 0; j < i; j++) {
                struct usbdevfs_urb* done = NULL;
                ioctl(g_fd, USBDEVFS_REAPURBNDELAY, &done);
            }
            free_slots();
            close(g_fd);
            g_fd = -1;
            LOGE("USB submit failed: %s", strerror(-rc));
            return rc;
        }
    }
    submit_feedback();
    int prc = pthread_create(&g_thread, NULL, stream_main, NULL);
    if (prc != 0) {
        atomic_store(&g_running, 0);
        free_slots();
        close(g_fd);
        g_fd = -1;
        return -prc;
    }
    g_thread_started = 1;
    LOGI(
        "USB isochronous started %d Hz %d ch x %d bytes, %d packets, ui %.3f pcm %.5f",
        rate,
        channels,
        subframe,
        packets,
        usb_gain_to_unit(applied_ui_q15()),
        usb_gain_to_unit(applied_gain_q15())
    );
    return 0;
}

static int store_gain(float gain, atomic_uint* slot) {
    if (gain != gain) {
        return 0;
    }
    atomic_store(slot, usb_gain_from_unit(gain));
    return 1;
}

JNIEXPORT jboolean JNICALL Java_com_likepod_likepod_UsbExclusiveNative_nativeSetPlayerGain(
    JNIEnv* env,
    jclass cls,
    jfloat gain
) {
    (void)env;
    (void)cls;
    return store_gain(gain, &g_player_q15) ? JNI_TRUE : JNI_FALSE;
}

JNIEXPORT jboolean JNICALL Java_com_likepod_likepod_UsbExclusiveNative_nativeSetStreamGain(
    JNIEnv* env,
    jclass cls,
    jfloat gain
) {
    (void)env;
    (void)cls;
    if (!store_gain(gain, &g_stream_q15)) {
        return JNI_FALSE;
    }
    atomic_store(&g_stream_known, 1);
    return JNI_TRUE;
}

JNIEXPORT jfloat JNICALL Java_com_likepod_likepod_UsbExclusiveNative_nativeGetGain(JNIEnv* env, jclass cls) {
    (void)env;
    (void)cls;
    return usb_gain_to_unit(applied_gain_q15());
}

JNIEXPORT jfloat JNICALL Java_com_likepod_likepod_UsbExclusiveNative_nativeGetUi(JNIEnv* env, jclass cls) {
    (void)env;
    (void)cls;
    return usb_gain_to_unit(applied_ui_q15());
}

JNIEXPORT jfloat JNICALL Java_com_likepod_likepod_UsbExclusiveNative_nativePcmForUi(
    JNIEnv* env,
    jclass cls,
    jfloat ui
) {
    (void)env;
    (void)cls;
    return usb_gain_to_unit(usb_gain_from_ui(ui));
}

JNIEXPORT jboolean JNICALL Java_com_likepod_likepod_UsbExclusiveNative_nativeStreamGainKnown(
    JNIEnv* env,
    jclass cls
) {
    (void)env;
    (void)cls;
    return atomic_load(&g_stream_known) ? JNI_TRUE : JNI_FALSE;
}

JNIEXPORT void JNICALL Java_com_likepod_likepod_UsbExclusiveNative_nativeStop(JNIEnv* env, jclass cls) {
    (void)env;
    (void)cls;
    atomic_store(&g_running, 0);
    atomic_store(&g_playing, 0);
    wake_playback_wait();
    if (g_fd >= 0) {
        for (int i = 0; i < URB_COUNT; i++) {
            if (g_slots[i].in_flight && g_slots[i].urb != NULL) {
                ioctl(g_fd, USBDEVFS_DISCARDURB, g_slots[i].urb);
            }
        }
        if (g_feedback.in_flight && g_feedback.urb != NULL) {
            ioctl(g_fd, USBDEVFS_DISCARDURB, g_feedback.urb);
        }
    }
    if (g_thread_started) {
        pthread_join(g_thread, NULL);
        g_thread_started = 0;
    }
    if (g_fd >= 0) {
        for (int n = 0; n < URB_COUNT + 2; n++) {
            struct usbdevfs_urb* done = NULL;
            if (ioctl(g_fd, USBDEVFS_REAPURBNDELAY, &done) < 0) {
                break;
            }
        }
        close(g_fd);
        g_fd = -1;
    }
    free_slots();
    clear_click();
}

JNIEXPORT jboolean JNICALL Java_com_likepod_likepod_UsbExclusiveNative_nativeRunning(JNIEnv* env, jclass cls) {
    (void)env;
    (void)cls;
    return atomic_load(&g_running) ? JNI_TRUE : JNI_FALSE;
}

/* Keep the isochronous endpoint alive for a few seconds after a handoff.
   After the exclusive stream stops, the kernel endpoint's bandwidth
   allocation and sync state decay, and any AudioTrack the grabber opened on
   the USB HAL writes into a dead pipe. Re-submitting zero-length playback
   URBs plus feedback URBs for a short window keeps the endpoint scheduled;
   if the grabber's stream is already feeding the same endpoint through the
   HAL, those writes land on a living pipe instead of a dead one. */
JNIEXPORT jboolean JNICALL Java_com_likepod_likepod_UsbExclusiveNative_nativeKeepAlive(
    JNIEnv* env,
    jclass cls,
    jint seconds
) {
    (void)env;
    (void)cls;
    if (g_fd < 0 || g_ep_out <= 0) {
        return JNI_FALSE;
    }
    int iterations = seconds > 0 ? seconds : 3;
    if (iterations > 30) {
        iterations = 30;
    }
    /* Zero-length playback URBs keep the endpoint scheduled without
       sending audible data. One urb, one packet, zero bytes per packet. */
    struct usbdevfs_urb urb;
    memset(&urb, 0, sizeof(urb));
    urb.type = USBDEVFS_URB_TYPE_ISO;
    urb.endpoint = (unsigned char)g_ep_out;
    urb.flags = USBDEVFS_URB_ISO_ASAP;
    urb.buffer = NULL;
    urb.buffer_length = 0;
    urb.number_of_packets = 1;
    urb.iso_frame_desc[0].length = 0;
    for (int i = 0; i < iterations * 800; i++) {
        if (ioctl(g_fd, USBDEVFS_SUBMITURB, &urb) < 0) {
            return JNI_FALSE;
        }
        struct usbdevfs_urb* done = NULL;
        /* Wait for completion with a generous timeout: 800 microframes
           per iteration at 1 ms each ≈ 1.25 ms per URB round. */
        while (ioctl(g_fd, USBDEVFS_REAPURBNDELAY, &done) < 0) {
            if (errno != EAGAIN) {
                return JNI_FALSE;
            }
            usleep(200);
        }
        if (done != &urb) {
            /* A foreign URB completed (should not happen); ignore. */
        }
    }
    return JNI_TRUE;
}

JNIEXPORT jint JNICALL Java_com_likepod_likepod_UsbExclusiveNative_nativeWrite(
    JNIEnv* env,
    jclass cls,
    jbyteArray data,
    jint length
) {
    (void)cls;
    if (data == NULL || length <= 0) {
        return 0;
    }
    if (g_frame_bytes > 0) {
        length -= length % g_frame_bytes;
    }
    if (length <= 0) {
        return 0;
    }
    pthread_mutex_lock(&g_mu);
    if (!atomic_load(&g_running) || g_ring == NULL) {
        pthread_mutex_unlock(&g_mu);
        return 0;
    }
    uint32_t free_bytes = RING_CAP - g_ring_used;
    if ((uint32_t)length > free_bytes) {
        pthread_mutex_unlock(&g_mu);
        return 0;
    }
    jbyte* bytes = (*env)->GetByteArrayElements(env, data, NULL);
    if (bytes == NULL) {
        pthread_mutex_unlock(&g_mu);
        return 0;
    }
    uint32_t w = (g_ring_r + g_ring_used) & (RING_CAP - 1u);
    for (int i = 0; i < length; i++) {
        g_ring[w] = (uint8_t)bytes[i];
        w = (w + 1u) & (RING_CAP - 1u);
    }
    g_ring_used += (uint32_t)length;
    (*env)->ReleaseByteArrayElements(env, data, bytes, JNI_ABORT);
    pthread_mutex_unlock(&g_mu);
    atomic_fetch_add(&g_fed, (unsigned long long)length);
    return length;
}

JNIEXPORT jint JNICALL Java_com_likepod_likepod_UsbExclusiveNative_nativeSpace(JNIEnv* env, jclass cls) {
    (void)env;
    (void)cls;
    pthread_mutex_lock(&g_mu);
    int free_bytes = (int)(RING_CAP - g_ring_used);
    pthread_mutex_unlock(&g_mu);
    return free_bytes;
}

JNIEXPORT jint JNICALL Java_com_likepod_likepod_UsbExclusiveNative_nativeQueuedBytes(JNIEnv* env, jclass cls) {
    (void)env;
    (void)cls;
    pthread_mutex_lock(&g_mu);
    int used = (int)g_ring_used;
    pthread_mutex_unlock(&g_mu);
    return used;
}

JNIEXPORT void JNICALL Java_com_likepod_likepod_UsbExclusiveNative_nativeFlush(JNIEnv* env, jclass cls) {
    (void)env;
    (void)cls;
    pthread_mutex_lock(&g_mu);
    g_ring_r = 0;
    g_ring_used = 0;
    g_epoch++;
    pthread_mutex_unlock(&g_mu);
    atomic_store(&g_played, 0);
    clear_click();
}

JNIEXPORT void JNICALL Java_com_likepod_likepod_UsbExclusiveNative_nativeSetPlaying(
    JNIEnv* env,
    jclass cls,
    jboolean playing
) {
    (void)env;
    (void)cls;
    atomic_store(&g_playing, playing ? 1 : 0);
    wake_playback_wait();
}

JNIEXPORT jboolean JNICALL Java_com_likepod_likepod_UsbExclusiveNative_nativeQueueClick(
    JNIEnv* env,
    jclass cls,
    jbyteArray pcm,
    jint frames,
    jint src_rate
) {
    (void)cls;
    if (!atomic_load(&g_running) || g_rate <= 0 || pcm == NULL || frames <= 0 || src_rate <= 0) {
        return JNI_FALSE;
    }
    jsize length = (*env)->GetArrayLength(env, pcm);
    if (length < frames * 2) {
        return JNI_FALSE;
    }
    jbyte* src = (*env)->GetByteArrayElements(env, pcm, NULL);
    if (src == NULL) {
        return JNI_FALSE;
    }
    int dst_frames = (int)(((int64_t)frames * (int64_t)g_rate) / (int64_t)src_rate);
    if (dst_frames < 1) {
        dst_frames = 1;
    }
    if (dst_frames > CLICK_MAX) {
        dst_frames = CLICK_MAX;
    }
    int16_t staged[CLICK_MAX];
    for (int i = 0; i < dst_frames; i++) {
        double pos = ((double)i * (double)frames) / (double)dst_frames;
        int i0 = (int)pos;
        if (i0 >= frames) {
            i0 = frames - 1;
        }
        int i1 = i0 + 1 < frames ? i0 + 1 : i0;
        double frac = pos - i0;
        int off0 = i0 * 2;
        int off1 = i1 * 2;
        int16_t s0 = (int16_t)((uint16_t)(uint8_t)src[off0] | ((uint16_t)(uint8_t)src[off0 + 1] << 8));
        int16_t s1 = (int16_t)((uint16_t)(uint8_t)src[off1] | ((uint16_t)(uint8_t)src[off1 + 1] << 8));
        int mixed = (int)((double)s0 + ((double)s1 - (double)s0) * frac);
        if (mixed > 32767) mixed = 32767;
        if (mixed < -32768) mixed = -32768;
        staged[i] = (int16_t)mixed;
    }
    (*env)->ReleaseByteArrayElements(env, pcm, src, JNI_ABORT);
    pthread_mutex_lock(&g_click_mu);
    memcpy(g_click, staged, (size_t)dst_frames * sizeof(int16_t));
    g_click_frames = dst_frames;
    g_click_pos = 0;
    pthread_mutex_unlock(&g_click_mu);
    return JNI_TRUE;
}

JNIEXPORT jlong JNICALL Java_com_likepod_likepod_UsbExclusiveNative_nativePlayedFrames(JNIEnv* env, jclass cls) {
    (void)env;
    (void)cls;
    return (jlong)atomic_load(&g_played);
}

JNIEXPORT jlong JNICALL Java_com_likepod_likepod_UsbExclusiveNative_nativeFedBytes(JNIEnv* env, jclass cls) {
    (void)env;
    (void)cls;
    return (jlong)atomic_load(&g_fed);
}

JNIEXPORT void JNICALL Java_com_likepod_likepod_UsbExclusiveNative_nativeForbidSuspend(JNIEnv* env, jclass cls) {
    (void)env;
    (void)cls;
    if (g_fd >= 0) {
        ioctl(g_fd, USBDEVFS_FORBID_SUSPEND, 0);
    }
}

JNIEXPORT jint JNICALL Java_com_likepod_likepod_UsbExclusiveNative_nativeGetSpeed(JNIEnv* env, jclass cls, jint fd) {
    (void)env;
    (void)cls;
    int speed = ioctl(fd, USBDEVFS_GET_SPEED, 0);
    if (speed < 0) {
        return -errno;
    }
    return speed;
}

static int iface_ioctl(int fd, int iface, int code) {
    struct usbdevfs_ioctl cmd;
    memset(&cmd, 0, sizeof(cmd));
    cmd.ifno = iface;
    cmd.ioctl_code = code;
    cmd.data = NULL;
    if (ioctl(fd, USBDEVFS_IOCTL, &cmd) < 0) {
        __android_log_print(
            ANDROID_LOG_INFO,
            "LikePodUsb",
            "kernel ioctl iface=%d code=%d failed: %s",
            iface,
            code,
            strerror(errno)
        );
        return -1;
    }
    __android_log_print(
        ANDROID_LOG_INFO,
        "LikePodUsb",
        "kernel ioctl iface=%d code=%d ok",
        iface,
        code
    );
    return 0;
}

JNIEXPORT void JNICALL Java_com_likepod_likepod_UsbExclusiveNative_nativeDisconnect(
    JNIEnv* env,
    jclass cls,
    jint fd,
    jint iface
) {
    (void)env;
    (void)cls;
    iface_ioctl(fd, iface, USBDEVFS_DISCONNECT);
}

JNIEXPORT jboolean JNICALL Java_com_likepod_likepod_UsbExclusiveNative_nativeConnect(
    JNIEnv* env,
    jclass cls,
    jint fd,
    jint iface
) {
    (void)env;
    (void)cls;
    return iface_ioctl(fd, iface, USBDEVFS_CONNECT) == 0 ? JNI_TRUE : JNI_FALSE;
}

JNIEXPORT jint JNICALL Java_com_likepod_likepod_UsbExclusiveNative_nativeGetDriver(
    JNIEnv* env,
    jclass cls,
    jint fd,
    jint iface
) {
    (void)env;
    (void)cls;
    struct usbdevfs_getdriver query;
    memset(&query, 0, sizeof(query));
    query.interface = (unsigned int)iface;
    if (ioctl(fd, USBDEVFS_GETDRIVER, &query) < 0) {
        /* ENODATA means no kernel driver holds the interface. */
        return 0;
    }
    /* The kernel audio driver is "usb-audio"; any non-empty name counts. */
    return query.driver[0] != '\0' ? 1 : 0;
}

JNIEXPORT jboolean JNICALL Java_com_likepod_likepod_UsbExclusiveNative_nativeResetDevice(
    JNIEnv* env,
    jclass cls,
    jint fd
) {
    (void)env;
    (void)cls;
    /* USBDEVFS_RESET: port-level reset, the equivalent of replug. Forces
     * snd-usb-audio to rebuild its isochronous stream state machine after
     * an exclusive handoff left the endpoint stalled. The device
     * re-enumerates and the framework re-runs attach events. */
    return ioctl(fd, USBDEVFS_RESET) == 0 ? JNI_TRUE : JNI_FALSE;
}

static char g_choose_error[160];

JNIEXPORT jintArray JNICALL Java_com_likepod_likepod_UsbExclusiveNative_nativeChoose(
    JNIEnv* env,
    jclass cls,
    jbyteArray raw,
    jint wanted_rate
) {
    (void)cls;
    g_choose_error[0] = 0;
    if (raw == NULL) {
        snprintf(g_choose_error, sizeof(g_choose_error), "描述符为空");
        return NULL;
    }
    jsize length = (*env)->GetArrayLength(env, raw);
    jbyte* bytes = (*env)->GetByteArrayElements(env, raw, NULL);
    if (bytes == NULL) {
        snprintf(g_choose_error, sizeof(g_choose_error), "描述符读取失败");
        return NULL;
    }
    UsbStreamInfo info;
    int rc = usb_desc_choose((const uint8_t*)bytes, (int)length, wanted_rate, &info, g_choose_error, (int)sizeof(g_choose_error));
    (*env)->ReleaseByteArrayElements(env, raw, bytes, JNI_ABORT);
    if (rc != 0) {
        return NULL;
    }
    jint values[20];
    memset(values, 0, sizeof(values));
    values[0] = info.interface_number;
    values[1] = info.alt;
    values[2] = info.protocol;
    values[3] = info.channels;
    values[4] = info.bits;
    values[5] = info.subframe;
    values[6] = info.endpoint;
    values[7] = info.max_packet;
    values[8] = info.interval;
    values[9] = info.feedback;
    values[10] = info.clock_id;
    values[11] = info.ac_interface;
    values[12] = info.resampled;
    values[13] = info.chosen_rate;
    values[14] = info.continuous;
    values[15] = info.rate_min;
    values[16] = info.rate_max;
    values[17] = info.rate_count;
    jintArray out = (*env)->NewIntArray(env, 20);
    if (out == NULL) {
        return NULL;
    }
    (*env)->SetIntArrayRegion(env, out, 0, 20, values);
    return out;
}

JNIEXPORT jstring JNICALL Java_com_likepod_likepod_UsbExclusiveNative_nativeLastChooseError(JNIEnv* env, jclass cls) {
    (void)cls;
    return (*env)->NewStringUTF(env, g_choose_error);
}
