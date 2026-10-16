#include "wake.h"
#include "c-api.h"
#include <stdlib.h>
#include <string.h>

struct HaloWake {
  const SherpaOnnxKeywordSpotter *spotter;
  const SherpaOnnxOnlineStream *stream;
  const SherpaOnnxVoiceActivityDetector *vad;
};

HaloWake *halo_wake_create(const char *encoder, const char *decoder,
                          const char *joiner, const char *tokens,
                          const char *keywords, const char *vad_model) {
  // This bridge's configuration layout is pinned to the vendored 1.13.8 header.
  if (strcmp(SherpaOnnxGetVersionStr(), "1.13.8") != 0) return NULL;
  HaloWake *wake = calloc(1, sizeof(*wake));
  if (!wake) return NULL;
  SherpaOnnxKeywordSpotterConfig config = {0};
  config.feat_config.sample_rate = 16000;
  config.feat_config.feature_dim = 80;
  config.model_config.transducer.encoder = encoder;
  config.model_config.transducer.decoder = decoder;
  config.model_config.transducer.joiner = joiner;
  config.model_config.tokens = tokens;
  config.model_config.num_threads = 1;
  config.model_config.provider = "cpu";
  config.keywords_file = keywords;
  config.keywords_score = 1.0f;
  config.keywords_threshold = 0.30f;
  config.max_active_paths = 4;
  config.num_trailing_blanks = 1;
  wake->spotter = SherpaOnnxCreateKeywordSpotter(&config);
  if (!wake->spotter) { halo_wake_destroy(wake); return NULL; }
  wake->stream = SherpaOnnxCreateKeywordStream(wake->spotter);
  SherpaOnnxVadModelConfig vad = {0};
  vad.silero_vad.model = vad_model;
  vad.silero_vad.threshold = 0.5f;
  vad.silero_vad.min_silence_duration = 0.8f;
  vad.silero_vad.min_speech_duration = 0.25f;
  vad.silero_vad.window_size = 512;
  vad.silero_vad.max_speech_duration = 20;
  vad.sample_rate = 16000;
  vad.num_threads = 1;
  vad.provider = "cpu";
  wake->vad = SherpaOnnxCreateVoiceActivityDetector(&vad, 30);
  if (!wake->stream || !wake->vad) { halo_wake_destroy(wake); return NULL; }
  return wake;
}

void halo_wake_destroy(HaloWake *wake) {
  if (!wake) return;
  if (wake->stream) SherpaOnnxDestroyOnlineStream(wake->stream);
  if (wake->spotter) SherpaOnnxDestroyKeywordSpotter(wake->spotter);
  if (wake->vad) SherpaOnnxDestroyVoiceActivityDetector(wake->vad);
  free(wake);
}

int halo_wake_accept(HaloWake *wake, const float *samples, int32_t count) {
  SherpaOnnxOnlineStreamAcceptWaveform(wake->stream, 16000, samples, count);
  int detected = 0;
  while (SherpaOnnxIsKeywordStreamReady(wake->spotter, wake->stream)) {
    SherpaOnnxDecodeKeywordStream(wake->spotter, wake->stream);
    const SherpaOnnxKeywordResult *result = SherpaOnnxGetKeywordResult(wake->spotter, wake->stream);
    if (result && result->keyword && strlen(result->keyword)) detected = 1;
    if (result) SherpaOnnxDestroyKeywordResult(result);
    if (detected) break;
  }
  return detected;
}

int halo_vad_accept(HaloWake *wake, const float *samples, int32_t count) {
  SherpaOnnxVoiceActivityDetectorAcceptWaveform(wake->vad, samples, count);
  int detected = SherpaOnnxVoiceActivityDetectorDetected(wake->vad);
  SherpaOnnxVoiceActivityDetectorClear(wake->vad);
  return detected;
}

void halo_wake_reset(HaloWake *wake) {
  SherpaOnnxDestroyOnlineStream(wake->stream);
  wake->stream = SherpaOnnxCreateKeywordStream(wake->spotter);
  SherpaOnnxVoiceActivityDetectorReset(wake->vad);
}
