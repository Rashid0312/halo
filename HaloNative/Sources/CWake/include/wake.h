#pragma once
#include <stdint.h>
typedef struct HaloWake HaloWake;
HaloWake *halo_wake_create(const char *encoder, const char *decoder,
                          const char *joiner, const char *tokens,
                          const char *keywords, const char *vad_model);
void halo_wake_destroy(HaloWake *wake);
int halo_wake_accept(HaloWake *wake, const float *samples, int32_t count);
int halo_vad_accept(HaloWake *wake, const float *samples, int32_t count);
void halo_wake_reset(HaloWake *wake);
