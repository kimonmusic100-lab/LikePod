#include "usb_desc.h"

#include <stdio.h>
#include <string.h>

typedef struct {
    int if_num;
    int alt;
    int class_code;
    int subclass;
    int protocol;
    int channels;
    int bits;
    int subframe;
    int is_pcm;
    int saw_general;
    int endpoint;
    int max_packet;
    int interval;
    int feedback;
    int terminal_link;
    int continuous;
    int rate_min;
    int rate_max;
    int rate_count;
    int rates[8];
    int ac_interface;
    int default_clock;
    int clock_term[8];
    int clock_id_for_term[8];
    int clock_count;
    UsbStreamInfo alts[8];
    int alt_count;
} Parse;

static int u16(const uint8_t* p) {
    return p[0] | (p[1] << 8);
}

static int u24(const uint8_t* p) {
    return p[0] | (p[1] << 8) | (p[2] << 16);
}

static void remember_clock(Parse* p, int terminal, int clock) {
    if (clock <= 0) {
        return;
    }
    p->default_clock = clock;
    if (terminal <= 0 || p->clock_count >= 8) {
        return;
    }
    p->clock_term[p->clock_count] = terminal;
    p->clock_id_for_term[p->clock_count] = clock;
    p->clock_count++;
}

static int lookup_clock(const Parse* p, int terminal) {
    for (int i = 0; i < p->clock_count; i++) {
        if (p->clock_term[i] == terminal) {
            return p->clock_id_for_term[i];
        }
    }
    return 0;
}

static void reset_alt(Parse* p) {
    p->channels = 0;
    p->bits = 0;
    p->subframe = 0;
    p->is_pcm = 0;
    p->saw_general = 0;
    p->endpoint = 0;
    p->max_packet = 0;
    p->interval = 1;
    p->feedback = 0;
    p->terminal_link = 0;
    p->continuous = 0;
    p->rate_min = 0;
    p->rate_max = 0;
    p->rate_count = 0;
}

static void commit_alt(Parse* p) {
    if (p->class_code != 1 || p->subclass != 2) {
        return;
    }
    if (p->endpoint == 0 || !p->is_pcm || p->channels <= 0 || p->bits <= 0 || p->subframe <= 0) {
        return;
    }
    if (p->alt_count >= 8) {
        return;
    }
    UsbStreamInfo* a = &p->alts[p->alt_count++];
    memset(a, 0, sizeof(*a));
    a->interface_number = p->if_num;
    a->alt = p->alt;
    a->protocol = p->protocol;
    a->channels = p->channels;
    a->bits = p->bits;
    a->subframe = p->subframe;
    a->endpoint = p->endpoint;
    a->max_packet = p->max_packet;
    a->interval = p->interval;
    a->feedback = p->feedback;
    a->terminal_link = p->terminal_link;
    a->continuous = p->continuous;
    a->rate_min = p->rate_min;
    a->rate_max = p->rate_max;
    a->rate_count = p->rate_count;
    a->ac_interface = p->ac_interface;
    for (int i = 0; i < p->rate_count && i < 8; i++) {
        a->rates[i] = p->rates[i];
    }
}

static int nearest_rate(const UsbStreamInfo* alt, int wanted) {
    int best = alt->rates[0];
    int best_diff = best > wanted ? best - wanted : wanted - best;
    for (int i = 1; i < alt->rate_count; i++) {
        int rate = alt->rates[i];
        int diff = rate > wanted ? rate - wanted : wanted - rate;
        if (diff < best_diff) {
            best = rate;
            best_diff = diff;
        }
    }
    return best;
}

static int score_alt(const UsbStreamInfo* alt, int resampled, int chosen, int wanted) {
    int score = 0;
    if (alt->channels != 2) {
        score += 100;
    }
    if (alt->bits != 16) {
        score += 20;
    }
    if (resampled) {
        score += 80;
    }
    int diff = chosen > wanted ? chosen - wanted : wanted - chosen;
    score += diff / 100;
    return score;
}

static void fail(char* error, int cap, const char* text) {
    if (error == NULL || cap <= 0) {
        return;
    }
    snprintf(error, (size_t)cap, "%s", text);
}

int usb_desc_choose(const uint8_t* desc, int length, int wanted_rate, UsbStreamInfo* out, char* error, int error_cap) {
    if (out == NULL) {
        fail(error, error_cap, "描述符解析失败");
        return -1;
    }
    memset(out, 0, sizeof(*out));
    if (desc == NULL || length < 9) {
        fail(error, error_cap, "描述符太短");
        return -1;
    }
    if (wanted_rate <= 0) {
        wanted_rate = 44100;
    }

    Parse p;
    memset(&p, 0, sizeof(p));
    p.ac_interface = -1;
    p.if_num = -1;

    int i = 0;
    if (length > 2 && desc[1] == 0x01) {
        int dlen = desc[0];
        if (dlen < 2 || dlen > length) {
            fail(error, error_cap, "设备描述符损坏");
            return -1;
        }
        i = dlen;
    }

    while (i + 1 < length) {
        int blen = desc[i];
        int type = desc[i + 1];
        if (blen < 2 || i + blen > length) {
            break;
        }
        const uint8_t* b = desc + i;
        if (type == 0x04 && blen >= 9) {
            commit_alt(&p);
            reset_alt(&p);
            p.if_num = b[2];
            p.alt = b[3];
            p.class_code = b[5];
            p.subclass = b[6];
            p.protocol = b[7];
            if (p.class_code == 1 && p.subclass == 1) {
                p.ac_interface = p.if_num;
            }
        } else if (type == 0x24 && blen >= 3 && p.class_code == 1) {
            int subtype = b[2];
            if (p.subclass == 1 && subtype == 0x0A && blen >= 4) {
                remember_clock(&p, 0, b[3]);
            } else if (p.subclass == 1 && subtype == 0x02 && blen >= 8 && p.protocol == 0x20) {
                int terminal = b[3];
                int kind = u16(b + 4);
                int clock = b[7];
                if (kind == 0x0101) {
                    remember_clock(&p, terminal, clock);
                } else if (p.default_clock == 0) {
                    remember_clock(&p, terminal, clock);
                }
            } else if (p.subclass == 2 && subtype == 0x01 && blen >= 6) {
                p.saw_general = 1;
                p.terminal_link = b[3];
                if (p.protocol == 0x20 && blen >= 11) {
                    int formats = b[6] | (b[7] << 8) | (b[8] << 16) | (b[9] << 24);
                    p.is_pcm = (formats & 0x1) != 0;
                    p.channels = b[10];
                } else {
                    int tag = u16(b + 5);
                    p.is_pcm = tag == 0x0001;
                }
            } else if (p.subclass == 2 && subtype == 0x02 && blen >= 6 && b[3] == 0x01) {
                if (!p.saw_general) {
                    p.is_pcm = 1;
                }
                if (!p.is_pcm && p.saw_general) {
                    /* A non-PCM tag already rejected this alt. */
                } else if (p.protocol == 0x20) {
                    p.subframe = b[4];
                    p.bits = b[5];
                    p.is_pcm = 1;
                } else if (blen >= 8) {
                    p.channels = b[4];
                    p.subframe = b[5];
                    p.bits = b[6];
                    int freq_type = b[7];
                    p.is_pcm = 1;
                    if (freq_type == 0 && blen >= 14) {
                        p.continuous = 1;
                        p.rate_min = u24(b + 8);
                        p.rate_max = u24(b + 11);
                    } else {
                        for (int f = 0; f < freq_type && f < 8; f++) {
                            int off = 8 + (f * 3);
                            if (off + 3 > blen) {
                                break;
                            }
                            p.rates[p.rate_count++] = u24(b + off);
                        }
                    }
                }
            }
        } else if (type == 0x05 && blen >= 7 && p.class_code == 1 && p.subclass == 2) {
            int address = b[2];
            int attr = b[3];
            int iso = (attr & 0x3) == 0x01;
            int out = (address & 0x80) == 0;
            if (iso && out && p.endpoint == 0) {
                int raw = u16(b + 4);
                int size = raw & 0x7FF;
                int mult = ((raw >> 11) & 0x3) + 1;
                p.endpoint = address;
                p.max_packet = size * mult;
                p.interval = b[6];
                if (blen >= 9 && b[8] != 0) {
                    p.feedback = b[8];
                }
            }
        }
        i += blen;
    }
    commit_alt(&p);

    for (int n = 0; n < p.alt_count; n++) {
        UsbStreamInfo* alt = &p.alts[n];
        int clock = lookup_clock(&p, alt->terminal_link);
        alt->clock_id = clock != 0 ? clock : p.default_clock;
        if (alt->ac_interface < 0) {
            alt->ac_interface = p.ac_interface;
        }
    }

    if (p.alt_count == 0) {
        fail(error, error_cap, "描述符里没有 PCM 播放端点");
        return -1;
    }

    int best = -1;
    int best_score = 0x7fffffff;
    int best_rate = 0;
    int best_resampled = 0;
    for (int n = 0; n < p.alt_count; n++) {
        UsbStreamInfo* alt = &p.alts[n];
        int chosen = 0;
        int resampled = 0;
        int programmable = alt->rate_count == 0 && !alt->continuous;
        if (alt->rate_count > 0) {
            int exact = 0;
            for (int r = 0; r < alt->rate_count; r++) {
                if (alt->rates[r] == wanted_rate) {
                    exact = 1;
                    break;
                }
            }
            if (exact) {
                chosen = wanted_rate;
            } else {
                chosen = nearest_rate(alt, wanted_rate);
                resampled = 1;
            }
        } else if (alt->continuous) {
            if (wanted_rate >= alt->rate_min && wanted_rate <= alt->rate_max) {
                chosen = wanted_rate;
            } else if (wanted_rate < alt->rate_min) {
                chosen = alt->rate_min;
                resampled = 1;
            } else {
                chosen = alt->rate_max;
                resampled = 1;
            }
        } else if (programmable) {
            chosen = wanted_rate;
        } else {
            continue;
        }
        if (chosen <= 0) {
            continue;
        }
        int value = score_alt(alt, resampled, chosen, wanted_rate);
        if (value < best_score) {
            best = n;
            best_score = value;
            best_rate = chosen;
            best_resampled = resampled;
        }
    }
    if (best < 0) {
        fail(error, error_cap, "没有可用的 PCM 播放设置");
        return -1;
    }
    *out = p.alts[best];
    out->chosen_rate = best_rate;
    out->resampled = best_resampled;
    return 0;
}
