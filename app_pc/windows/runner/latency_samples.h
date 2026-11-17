#ifndef DEXLINK_LATENCY_SAMPLES_H_
#define DEXLINK_LATENCY_SAMPLES_H_

#include <algorithm>
#include <array>
#include <chrono>
#include <cstddef>

// Fixed storage; caller owns synchronization. Ages distinguish stale samples
// from a healthy current window, including when no new frames are produced.
class LatencySamples {
 public:
  using Clock = std::chrono::steady_clock;
  struct Summary {
    size_t count = 0;
    double window_ms = 0, age_ms = 0, p50_ms = 0, p99_ms = 0, max_ms = 0;
  };
  void Add(Clock::time_point at, double ms) {
    values_[next_] = ms;
    times_[next_] = at;
    next_ = (next_ + 1) % values_.size();
    count_ = std::min(count_ + 1, values_.size());
  }
  Summary Snapshot(Clock::time_point now) const {
    Summary result;
    result.count = count_;
    if (!count_) return result;
    auto sorted = values_;
    std::sort(sorted.begin(), sorted.begin() + count_);
    const auto range = std::minmax_element(times_.begin(), times_.begin() + count_);
    result.window_ms = std::chrono::duration<double, std::milli>(*range.second - *range.first).count();
    result.age_ms = std::chrono::duration<double, std::milli>(now - *range.second).count();
    result.p50_ms = sorted[(count_ * 50 + 99) / 100 - 1];
    result.p99_ms = sorted[(count_ * 99 + 99) / 100 - 1];
    result.max_ms = sorted[count_ - 1];
    return result;
  }
 private:
  std::array<double, 256> values_{};
  std::array<Clock::time_point, 256> times_{};
  size_t count_ = 0, next_ = 0;
};

#endif
