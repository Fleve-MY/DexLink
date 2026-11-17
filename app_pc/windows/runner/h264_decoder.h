#ifndef DEXLINK_H264_DECODER_H_
#define DEXLINK_H264_DECODER_H_

#include <windows.h>
#include <mfidl.h>
#include <mftransform.h>
#include <wrl/client.h>
#include <d3d11.h>

#include <cstdint>
#include <functional>
#include <deque>
#include <memory>
#include <vector>
#include "pixel_buffer_pool.h"
#include "gpu_surface_pool.h"

struct DecodedVideoFrame {
  DecodedVideoFrame() = default;
  DecodedVideoFrame(DecodedVideoFrame&&) = default;
  DecodedVideoFrame& operator=(DecodedVideoFrame&&) = default;
  DecodedVideoFrame(const DecodedVideoFrame&) = delete;
  DecodedVideoFrame& operator=(const DecodedVideoFrame&) = delete;
  ~DecodedVideoFrame() {
    if (pixel_pool) pixel_pool->Release(std::move(rgba));
    if (gpu_pool && gpu_surface && gpu_complete && !gpu_exposed)
      gpu_pool->Release(std::move(gpu_surface));
  }
  uint32_t width = 0;
  uint32_t height = 0;
  int64_t pts_us = 0;
  std::vector<uint8_t> rgba;
  std::shared_ptr<PixelBufferPool> pixel_pool;
  Microsoft::WRL::ComPtr<ID3D11Texture2D> gpu;
  HANDLE shared_handle = nullptr;
  std::shared_ptr<GpuSurface> gpu_surface;
  std::shared_ptr<GpuSurfacePool> gpu_pool;
  bool gpu_complete = false, gpu_exposed = false;
};

// Used only on the decoder's MTA worker. No Flutter or UI dependency.
class H264Decoder {
 public:
  using Output = std::function<void(DecodedVideoFrame)>;
  ~H264Decoder();
  HRESULT Open(uint32_t width, uint32_t height, Output output, bool hardware = false,
               bool gpu_output = false, uint32_t fps = 60, bool hevc = false);
  bool hardware_active() const { return hardware_output_; }
  bool gpu_fallback() const { return gpu_fallback_; }
  bool gpu_presentation_active() const { return gpu_output_; }
  bool gpu_presentation_slow() const { return cpu_presentation_requested_; }
  void PreferCpuPresentation() { cpu_presentation_requested_ = true; }
  uint64_t gpu_allocations() const { return gpu_allocations_; }
  uint64_t gpu_reuses() const { return gpu_reuses_; }
  // Decode reference pictures even when their expensive pixel upload is skipped.
  void set_present_output(bool enabled) { present_output_ = enabled; }
  HRESULT Push(const std::vector<uint8_t>& annex_b, int64_t pts_us);
  HRESULT Drain();
  HRESULT Poll();

 private:
  HRESULT SetOutputType();
  HRESULT ReadOutput();
  HRESULT Convert(IMFSample* sample);
  HRESULT EnableHardware();
  HRESULT QueueReadback(ID3D11Texture2D* texture, UINT subresource, IMFSample* sample);
  HRESULT Readback(bool wait);
  HRESULT ConvertGpu(ID3D11Texture2D* source, UINT subresource, IMFSample* sample);
  HRESULT FinishGpu(bool wait);
  HRESULT ConvertPixels(const uint8_t* bytes, uint32_t pitch, uint32_t storage_height,
                        IMFSample* sample);
  Microsoft::WRL::ComPtr<IMFTransform> decoder_;
  Microsoft::WRL::ComPtr<ID3D11Device> device_;
  Microsoft::WRL::ComPtr<ID3D11DeviceContext> context_;
  Microsoft::WRL::ComPtr<IMFDXGIDeviceManager> device_manager_;
  struct PendingReadback {
    Microsoft::WRL::ComPtr<ID3D11Texture2D> texture;
    Microsoft::WRL::ComPtr<IMFSample> sample;
    uint32_t height;
  };
  std::deque<PendingReadback> readbacks_;
  std::vector<Microsoft::WRL::ComPtr<ID3D11Texture2D>> readback_pool_;
  struct PendingGpu {
    DecodedVideoFrame frame;
    Microsoft::WRL::ComPtr<ID3D11Query> completed;
    Microsoft::WRL::ComPtr<IMFSample> source;
  };
  std::deque<PendingGpu> gpu_pending_;
  std::shared_ptr<GpuSurfacePool> gpu_pool_ = std::make_shared<GpuSurfacePool>();
  uint64_t gpu_allocations_ = 0, gpu_reuses_ = 0;
  bool first_readback_ = true;
  bool hardware_requested_ = false;
  bool hardware_output_ = false;
  bool present_output_ = true;
  bool gpu_output_ = false;
  bool gpu_fallback_ = false;
  bool cpu_presentation_requested_ = false;
  uint32_t fps_ = 60;
  Microsoft::WRL::ComPtr<ID3D11VideoProcessorEnumerator> processor_enum_;
  Microsoft::WRL::ComPtr<ID3D11VideoProcessor> processor_;
  Output output_;
  std::shared_ptr<PixelBufferPool> pixel_pool_ = std::make_shared<PixelBufferPool>();
  uint32_t width_ = 0;
  uint32_t height_ = 0;
  uint32_t visible_width_ = 0;
  uint32_t visible_height_ = 0;
  uint32_t crop_x_ = 0;
  uint32_t crop_y_ = 0;
  LONG stride_ = 0;
  bool bt709_ = false;
  bool full_range_ = false;
  bool started_ = false;
  bool precise_timer_ = false;
  bool hevc_ = false;
};

#endif
