#ifndef DEXLINK_VIDEO_PACING_H_
#define DEXLINK_VIDEO_PACING_H_

#include <algorithm>
#include <chrono>
#include <cstdint>

// Give a freshly published texture one short opportunity to be consumed when
// decoder/GPU completions arrive together. Never accumulate a playback queue
// or hold up catching up from a real compressed-input backlog.
inline std::chrono::microseconds TextureHandoffBudget(
    std::chrono::steady_clock::time_point published,
    std::chrono::steady_clock::time_point now, double oldest_input_ms) {
  if (oldest_input_ms >= 20.0 || now < published) return std::chrono::microseconds(0);
  const auto remaining = std::chrono::microseconds(8000) -
      std::chrono::duration_cast<std::chrono::microseconds>(now - published);
  return std::clamp(remaining, std::chrono::microseconds(0), std::chrono::microseconds(4000));
}

// TCP can deliver several fresh access units together. A short queue alone
// does not mean the decoder is late; preserve those frames until latency grows.
inline bool ShouldPresentVideoFrame(
    bool more_packets, std::chrono::steady_clock::time_point received,
    std::chrono::steady_clock::time_point last_output,
    std::chrono::steady_clock::time_point now, uint32_t fps) {
  const auto interval = std::chrono::microseconds(1000000 / std::clamp(fps, 1u, 240u));
  return !more_packets || now - received <= interval * 2 ||
      now - last_output >= interval;
}

#endif
