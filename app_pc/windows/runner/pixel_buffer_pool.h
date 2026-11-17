#ifndef DEXLINK_PIXEL_BUFFER_POOL_H_
#define DEXLINK_PIXEL_BUFFER_POOL_H_

#include <cstdint>
#include <mutex>
#include <utility>
#include <vector>

// A raster lease can outlive its decoder. Only buffers returned by the final
// frame owner are reusable; never overwrite pixels Flutter is still uploading.
class PixelBufferPool {
 public:
  PixelBufferPool() { available_.reserve(4); }

  std::vector<uint8_t> Acquire(size_t size) {
    std::vector<uint8_t> pixels;
    {
      std::lock_guard<std::mutex> lock(mutex_);
      for (auto it = available_.begin(); it != available_.end(); ++it) {
        if (it->size() == size) {
          pixels = std::move(*it);
          available_.erase(it);
          break;
        }
      }
      if (pixels.empty() && !available_.empty()) {
        pixels = std::move(available_.back());
        available_.pop_back();
      }
    }
    pixels.resize(size);
    return pixels;
  }

  void Release(std::vector<uint8_t> pixels) {
    if (pixels.empty()) return;
    std::lock_guard<std::mutex> lock(mutex_);
    if (available_.size() < 4) available_.push_back(std::move(pixels));
  }

 private:
  std::mutex mutex_;
  std::vector<std::vector<uint8_t>> available_;
};

#endif
