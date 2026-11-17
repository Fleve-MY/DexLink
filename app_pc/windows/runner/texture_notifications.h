#ifndef DEXLINK_TEXTURE_NOTIFICATIONS_H_
#define DEXLINK_TEXTURE_NOTIFICATIONS_H_

#include <chrono>
#include <cstdint>

// Serialize under the session mutex. Keep one latest-frame notification in
// flight; retry if raster did not consume it, including an idle final frame.
class TextureNotifications {
 public:
  using Clock = std::chrono::steady_clock;
  bool Publish(int64_t texture, Clock::time_point now) {
    if (pending_ && texture_ == texture) { ++coalesced; return false; }
    texture_ = texture;
    pending_ = true;
    marked_ = now;
    ++notifications;
    return true;
  }
  void Consumed(int64_t texture) {
    if (texture == texture_) pending_ = false;
  }
  int64_t Retry(Clock::time_point now) {
    if (!pending_ || now - marked_ < std::chrono::milliseconds(32)) return -1;
    marked_ = now;
    ++notifications;
    ++retries;
    return texture_;
  }
  int64_t notifications = 0, coalesced = 0, retries = 0;

 private:
  bool pending_ = false;
  int64_t texture_ = -1;
  Clock::time_point marked_{};
};

#endif
