#ifndef DEXLINK_GPU_SURFACE_POOL_H_
#define DEXLINK_GPU_SURFACE_POOL_H_

#include <d3d11.h>
#include <wrl/client.h>
#include <memory>
#include <cstdint>
#include <mutex>
#include <vector>

struct GpuSurface {
  Microsoft::WRL::ComPtr<ID3D11Texture2D> texture;
  Microsoft::WRL::ComPtr<ID3D11VideoProcessorOutputView> view;
  Microsoft::WRL::ComPtr<ID3D11VideoProcessorEnumerator> enumerator;
  Microsoft::WRL::ComPtr<ID3D11Query> completed;
  HANDLE handle = nullptr;
  uint32_t width = 0, height = 0;
};

// Only GPU-complete surfaces never exposed to Flutter may enter this pool.
// Flutter's handle-open callback does not mean its GPU has finished sampling.
class GpuSurfacePool {
 public:
  std::shared_ptr<GpuSurface> Acquire(uint32_t width, uint32_t height,
                                     ID3D11VideoProcessorEnumerator* enumerator) {
    std::lock_guard<std::mutex> lock(mutex_);
    for (auto it = surfaces_.begin(); it != surfaces_.end();) {
      if ((*it)->width == width && (*it)->height == height &&
          (*it)->enumerator.Get() == enumerator) {
        auto result = std::move(*it);
        surfaces_.erase(it);
        return result;
      }
      // A resize changes the processor enumerator as well as dimensions.
      // Retired generations must not occupy every reusable slot forever.
      it = surfaces_.erase(it);
    }
    return nullptr;
  }
  void Release(std::shared_ptr<GpuSurface> surface) {
    std::lock_guard<std::mutex> lock(mutex_);
    if (surfaces_.size() < 3) surfaces_.push_back(std::move(surface));
  }
  void Clear() {
    std::lock_guard<std::mutex> lock(mutex_);
    surfaces_.clear();
  }

 private:
  std::mutex mutex_;
  std::vector<std::shared_ptr<GpuSurface>> surfaces_;
};

#endif
