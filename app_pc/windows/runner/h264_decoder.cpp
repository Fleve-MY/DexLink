#include "h264_decoder.h"

#include <codecapi.h>
#include <mfapi.h>
#include <mferror.h>
#include <wmcodecdsp.h>
#include <emmintrin.h>
#include <mfobjects.h>
#include <d3d10.h>
#include <timeapi.h>

#include <algorithm>
#include <cstring>
#include <utility>
#include <chrono>
#include <thread>

using Microsoft::WRL::ComPtr;

namespace {
// Eight NV12 pixels at a time. Saturating arithmetic is safe here: all
// overflow values are outside the visible 0..255 range and must be clamped.
void ConvertRow(const uint8_t* y, const uint8_t* uv, uint8_t* dst,
                uint32_t width, bool bt709, bool full_range) {
  const int cy = full_range ? 64 : 74;
  const int cr = full_range ? (bt709 ? 101 : 90) : (bt709 ? 115 : 102);
  const int cgu = full_range ? (bt709 ? 12 : 22) : (bt709 ? 14 : 25);
  const int cgv = full_range ? (bt709 ? 30 : 46) : (bt709 ? 34 : 52);
  const int cb = full_range ? (bt709 ? 119 : 113) : (bt709 ? 135 : 129);
  const __m128i zero = _mm_setzero_si128();
  const __m128i center = _mm_set1_epi16(128);
  const __m128i offset = _mm_set1_epi16(full_range ? 0 : 16);
  uint32_t x = 0;
  for (; x + 8 <= width; x += 8) {
    const __m128i yy = _mm_mullo_epi16(
        _mm_sub_epi16(_mm_unpacklo_epi8(
            _mm_loadl_epi64(reinterpret_cast<const __m128i*>(y + x)), zero), offset),
        _mm_set1_epi16(static_cast<short>(cy)));
    const __m128i chroma = _mm_loadl_epi64(reinterpret_cast<const __m128i*>(uv + x));
    const __m128i u4 = _mm_and_si128(chroma, _mm_set1_epi16(255));
    const __m128i v4 = _mm_srli_epi16(chroma, 8);
    const __m128i u = _mm_sub_epi16(_mm_unpacklo_epi16(u4, u4), center);
    const __m128i v = _mm_sub_epi16(_mm_unpacklo_epi16(v4, v4), center);
    const __m128i r = _mm_srai_epi16(_mm_adds_epi16(yy,
        _mm_mullo_epi16(v, _mm_set1_epi16(static_cast<short>(cr)))), 6);
    const __m128i g = _mm_srai_epi16(_mm_subs_epi16(_mm_subs_epi16(yy,
        _mm_mullo_epi16(u, _mm_set1_epi16(static_cast<short>(cgu)))),
        _mm_mullo_epi16(v, _mm_set1_epi16(static_cast<short>(cgv)))), 6);
    const __m128i b = _mm_srai_epi16(_mm_adds_epi16(yy,
        _mm_mullo_epi16(u, _mm_set1_epi16(static_cast<short>(cb)))), 6);
    const __m128i rg = _mm_unpacklo_epi8(_mm_packus_epi16(r, zero), _mm_packus_epi16(g, zero));
    const __m128i ba = _mm_unpacklo_epi8(_mm_packus_epi16(b, zero), _mm_set1_epi8(-1));
    _mm_storeu_si128(reinterpret_cast<__m128i*>(dst + x * 4), _mm_unpacklo_epi16(rg, ba));
    _mm_storeu_si128(reinterpret_cast<__m128i*>(dst + x * 4 + 16), _mm_unpackhi_epi16(rg, ba));
  }
  for (; x < width; ++x) {
    const int yy = cy * (static_cast<int>(y[x]) - (full_range ? 0 : 16));
    const int u = static_cast<int>(uv[x & ~1u]) - 128;
    const int v = static_cast<int>(uv[(x & ~1u) + 1]) - 128;
    dst[x * 4] = static_cast<uint8_t>(std::clamp((yy + cr * v) >> 6, 0, 255));
    dst[x * 4 + 1] = static_cast<uint8_t>(std::clamp((yy - cgu * u - cgv * v) >> 6, 0, 255));
    dst[x * 4 + 2] = static_cast<uint8_t>(std::clamp((yy + cb * u) >> 6, 0, 255));
    dst[x * 4 + 3] = 255;
  }
}
}  // namespace

H264Decoder::~H264Decoder() {
  gpu_pending_.clear();
  readbacks_.clear();
  readback_pool_.clear();
  decoder_.Reset();
  device_manager_.Reset();
  context_.Reset();
  device_.Reset();
  if (started_) MFShutdown();
  if (precise_timer_) timeEndPeriod(1);
}

HRESULT H264Decoder::Open(uint32_t width, uint32_t height, Output output, bool hardware,
                         bool gpu_output, uint32_t fps, bool hevc) {
  // The worker polls pending GPU copies every 1-2 ms. The default Windows
  // timer quantum can turn that into 15.6 ms, almost an entire 60 Hz frame.
  // Scope the request to live decoders at 60 FPS or above and balance it on
  // shutdown; no persistent Windows setting is changed.
  if (fps >= 60 && !precise_timer_) precise_timer_ = timeBeginPeriod(1) == TIMERR_NOERROR;
  HRESULT hr = MFStartup(MF_VERSION, MFSTARTUP_LITE);
  if (FAILED(hr)) return hr;
  started_ = true;
  width_ = width;
  height_ = height;
  output_ = std::move(output);
  hevc_ = hevc;
  if (hevc) {
    MFT_REGISTER_TYPE_INFO type{MFMediaType_Video, MFVideoFormat_HEVC};
    IMFActivate** candidates = nullptr;
    UINT32 count = 0;
    hr = MFTEnumEx(MFT_CATEGORY_VIDEO_DECODER,
        MFT_ENUM_FLAG_SYNCMFT | MFT_ENUM_FLAG_LOCALMFT | MFT_ENUM_FLAG_SORTANDFILTER,
        &type, nullptr, &candidates, &count);
    if (SUCCEEDED(hr)) {
      hr = MF_E_TOPO_CODEC_NOT_FOUND;
      for (UINT32 i = 0; i < count; ++i) {
        if (!decoder_) hr = candidates[i]->ActivateObject(IID_PPV_ARGS(&decoder_));
        candidates[i]->Release();
      }
    }
    CoTaskMemFree(candidates);
  } else {
    hr = CoCreateInstance(CLSID_CMSH264DecoderMFT, nullptr, CLSCTX_INPROC_SERVER,
                          IID_PPV_ARGS(&decoder_));
  }
  if (FAILED(hr)) return hr;
  hardware_requested_ = hardware;
  gpu_output_ = gpu_output && hardware;
  fps_ = std::clamp<uint32_t>(fps, 1, 240);
  if (hardware) {
    hr = EnableHardware();
    if (FAILED(hr)) return hr;
  }
  ComPtr<IMFAttributes> attributes;
  if (SUCCEEDED(decoder_->GetAttributes(&attributes))) {
    attributes->SetUINT32(MF_LOW_LATENCY, TRUE);
  }
  ComPtr<ICodecAPI> codec;
  if (SUCCEEDED(decoder_.As(&codec))) {
    VARIANT low_latency{};
    low_latency.vt = VT_BOOL;
    low_latency.boolVal = VARIANT_TRUE;
    codec->SetValue(&CODECAPI_AVLowLatencyMode, &low_latency);
  }
  ComPtr<IMFMediaType> input;
  hr = MFCreateMediaType(&input);
  if (FAILED(hr)) return hr;
  input->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video);
  input->SetGUID(MF_MT_SUBTYPE, hevc_ ? MFVideoFormat_HEVC : MFVideoFormat_H264);
  MFSetAttributeSize(input.Get(), MF_MT_FRAME_SIZE, width, height);
  MFSetAttributeRatio(input.Get(), MF_MT_FRAME_RATE, fps_, 1);
  input->SetUINT32(MF_MT_INTERLACE_MODE, MFVideoInterlace_Progressive);
  hr = decoder_->SetInputType(0, input.Get(), 0);
  if (FAILED(hr)) return hr;
  hr = SetOutputType();
  if (FAILED(hr)) return hr;
  decoder_->ProcessMessage(MFT_MESSAGE_NOTIFY_BEGIN_STREAMING, 0);
  return decoder_->ProcessMessage(MFT_MESSAGE_NOTIFY_START_OF_STREAM, 0);
}

HRESULT H264Decoder::EnableHardware() {
  ComPtr<IMFAttributes> attributes;
  HRESULT hr = decoder_->GetAttributes(&attributes);
  if (FAILED(hr)) return hr;
  if (!MFGetAttributeUINT32(attributes.Get(), MF_SA_D3D11_AWARE, FALSE)) return E_NOINTERFACE;
  hr = D3D11CreateDevice(nullptr, D3D_DRIVER_TYPE_HARDWARE, nullptr,
      D3D11_CREATE_DEVICE_VIDEO_SUPPORT | D3D11_CREATE_DEVICE_BGRA_SUPPORT,
      nullptr, 0, D3D11_SDK_VERSION, &device_, nullptr, &context_);
  if (FAILED(hr)) return hr;
  ComPtr<ID3D10Multithread> multithread;
  if (SUCCEEDED(context_.As(&multithread))) multithread->SetMultithreadProtected(TRUE);
  ComPtr<ID3D11VideoDevice> video;
  hr = device_.As(&video);
  if (FAILED(hr)) return hr;
  BOOL supported = FALSE;
  hr = video->CheckVideoDecoderFormat(hevc_ ? &D3D11_DECODER_PROFILE_HEVC_VLD_MAIN : &D3D11_DECODER_PROFILE_H264_VLD_NOFGT,
                                     DXGI_FORMAT_NV12, &supported);
  if (FAILED(hr) || !supported) return DXGI_ERROR_UNSUPPORTED;
  UINT token = 0;
  hr = MFCreateDXGIDeviceManager(&token, &device_manager_);
  if (FAILED(hr)) return hr;
  hr = device_manager_->ResetDevice(device_.Get(), token);
  if (FAILED(hr)) return hr;
  return decoder_->ProcessMessage(MFT_MESSAGE_SET_D3D_MANAGER,
                                 reinterpret_cast<ULONG_PTR>(device_manager_.Get()));
}

HRESULT H264Decoder::SetOutputType() {
  for (DWORD index = 0;; ++index) {
    ComPtr<IMFMediaType> type;
    HRESULT hr = decoder_->GetOutputAvailableType(0, index, &type);
    if (FAILED(hr)) return hr;
    GUID subtype{};
    if (FAILED(type->GetGUID(MF_MT_SUBTYPE, &subtype)) || subtype != MFVideoFormat_NV12) continue;
    hr = decoder_->SetOutputType(0, type.Get(), 0);
    if (FAILED(hr)) continue;
    MFGetAttributeSize(type.Get(), MF_MT_FRAME_SIZE, &width_, &height_);
    if (width_ == 0 || height_ == 0 || width_ > 8192 || height_ > 8192 ||
        (width_ & 1) || (height_ & 1)) return MF_E_INVALIDMEDIATYPE;
    stride_ = static_cast<LONG>(MFGetAttributeUINT32(type.Get(), MF_MT_DEFAULT_STRIDE, width_));
    visible_width_ = width_;
    visible_height_ = height_;
    crop_x_ = crop_y_ = 0;
    // H.264 coded dimensions may include macroblock padding (e.g. 1088 for
    // a 1080-wide phone). The aperture describes the actual screen pixels.
    MFVideoArea aperture{};
    UINT32 aperture_size = 0;
    if (SUCCEEDED(type->GetBlob(MF_MT_MINIMUM_DISPLAY_APERTURE,
        reinterpret_cast<UINT8*>(&aperture), sizeof(aperture), &aperture_size)) &&
        aperture_size == sizeof(aperture) && aperture.OffsetX.value >= 0 &&
        aperture.OffsetY.value >= 0 && aperture.Area.cx > 0 && aperture.Area.cy > 0 &&
        static_cast<uint32_t>(aperture.OffsetX.value + aperture.Area.cx) <= width_ &&
        static_cast<uint32_t>(aperture.OffsetY.value + aperture.Area.cy) <= height_) {
      crop_x_ = aperture.OffsetX.value;
      crop_y_ = aperture.OffsetY.value;
      visible_width_ = aperture.Area.cx;
      visible_height_ = aperture.Area.cy;
    }
    if ((crop_x_ & 1) || (crop_y_ & 1) || (visible_width_ & 1)) return MF_E_INVALIDMEDIATYPE;
    bt709_ = MFGetAttributeUINT32(type.Get(), MF_MT_YUV_MATRIX, MFVideoTransferMatrix_BT601) == MFVideoTransferMatrix_BT709;
    full_range_ = MFGetAttributeUINT32(type.Get(), MF_MT_VIDEO_NOMINAL_RANGE, MFNominalRange_16_235) == MFNominalRange_0_255;
    processor_.Reset();
    processor_enum_.Reset();
    gpu_pool_->Clear();
    return S_OK;
  }
}

HRESULT H264Decoder::Push(const std::vector<uint8_t>& bytes, int64_t pts_us) {
  if (bytes.empty() || bytes.size() > 16 * 1024 * 1024) return E_INVALIDARG;
  ComPtr<IMFMediaBuffer> buffer;
  HRESULT hr = MFCreateMemoryBuffer(static_cast<DWORD>(bytes.size()), &buffer);
  if (FAILED(hr)) return hr;
  BYTE* data = nullptr;
  hr = buffer->Lock(&data, nullptr, nullptr);
  if (FAILED(hr)) return hr;
  std::memcpy(data, bytes.data(), bytes.size());
  buffer->Unlock();
  buffer->SetCurrentLength(static_cast<DWORD>(bytes.size()));
  ComPtr<IMFSample> sample;
  hr = MFCreateSample(&sample);
  if (FAILED(hr)) return hr;
  sample->AddBuffer(buffer.Get());
  sample->SetSampleTime(pts_us * 10);
  sample->SetSampleDuration(10000000 / fps_);
  hr = decoder_->ProcessInput(0, sample.Get(), 0);
  if (hr == MF_E_NOTACCEPTING) {
    hr = ReadOutput();
    if (FAILED(hr)) return hr;
    hr = decoder_->ProcessInput(0, sample.Get(), 0);
  }
  if (FAILED(hr)) return hr;
  hr = ReadOutput();
  return FAILED(hr) ? hr : Poll();
}

HRESULT H264Decoder::Drain() {
  HRESULT hr = decoder_->ProcessMessage(MFT_MESSAGE_COMMAND_DRAIN, 0);
  if (SUCCEEDED(hr)) hr = ReadOutput();
  if (SUCCEEDED(hr)) hr = Readback(true);
  return FAILED(hr) ? hr : FinishGpu(true);
}

HRESULT H264Decoder::Poll() {
  HRESULT hr = Readback(false);
  return FAILED(hr) ? hr : FinishGpu(false);
}

HRESULT H264Decoder::ReadOutput() {
  for (;;) {
    MFT_OUTPUT_STREAM_INFO stream{};
    HRESULT hr = decoder_->GetOutputStreamInfo(0, &stream);
    if (FAILED(hr)) return hr;
    ComPtr<IMFSample> sample;
    if (!(stream.dwFlags & MFT_OUTPUT_STREAM_PROVIDES_SAMPLES)) {
      hr = MFCreateSample(&sample);
      if (FAILED(hr)) return hr;
      ComPtr<IMFMediaBuffer> buffer;
      hr = MFCreateMemoryBuffer(std::max<DWORD>(stream.cbSize, width_ * height_ * 3 / 2), &buffer);
      if (FAILED(hr)) return hr;
      sample->AddBuffer(buffer.Get());
    }
    MFT_OUTPUT_DATA_BUFFER out{};
    out.pSample = sample.Get();
    DWORD status = 0;
    hr = decoder_->ProcessOutput(0, 1, &out, &status);
    if (out.pEvents) out.pEvents->Release();
    if (hr == MF_E_TRANSFORM_NEED_MORE_INPUT) return S_OK;
    if (hr == MF_E_TRANSFORM_STREAM_CHANGE) {
      hr = Readback(true);
      if (SUCCEEDED(hr)) hr = FinishGpu(true);
      if (FAILED(hr)) return hr;
      readback_pool_.clear();
      hr = SetOutputType();
      if (FAILED(hr)) return hr;
      continue;
    }
    if (!sample && out.pSample) sample.Attach(out.pSample);
    if (FAILED(hr)) return hr;
    if (!sample) return E_UNEXPECTED;
    hr = present_output_ ? Convert(sample.Get()) : S_OK;
    // Without a Map/present to submit GPU work, some DXVA drivers wait for
    // their batch timeout before releasing skipped decoder surfaces.
    if (!present_output_ && context_) context_->Flush();
    if (FAILED(hr)) return hr;
  }
}

HRESULT H264Decoder::Convert(IMFSample* sample) {
  if (gpu_output_ && cpu_presentation_requested_) {
    // Complete the old surfaces in order before publishing a CPU image. Keep
    // the decoder and its reference pictures; this changes presentation only.
    HRESULT hr = FinishGpu(true);
    if (FAILED(hr)) return hr;
    gpu_output_ = false;
    gpu_fallback_ = true;
  }
  ComPtr<IMFMediaBuffer> buffer;
  HRESULT hr = sample->GetBufferByIndex(0, &buffer);
  if (FAILED(hr)) return hr;
  ComPtr<IMFDXGIBuffer> dxgi;
  if (SUCCEEDED(buffer.As(&dxgi))) {
    ComPtr<ID3D11Texture2D> texture;
    hr = dxgi->GetResource(IID_PPV_ARGS(&texture));
    if (FAILED(hr)) return hr;
    UINT subresource = 0;
    hr = dxgi->GetSubresourceIndex(&subresource);
    if (FAILED(hr)) return hr;
    if (gpu_output_) {
      hr = ConvertGpu(texture.Get(), subresource, sample);
      if (SUCCEEDED(hr)) {
        hardware_output_ = true;
        return hr;
      }
      // Some drivers decode NV12 but cannot process shared BGRA surfaces.
      // Keep hardware decode and use the existing CPU presentation path.
      gpu_output_ = false;
      gpu_fallback_ = true;
      gpu_pending_.clear();
    }
    hardware_output_ = true;
    return QueueReadback(texture.Get(), subresource, sample);
  }
  // Never report hardware decode merely because device creation succeeded.
  if (hardware_requested_) return MF_E_UNSUPPORTED_D3D_TYPE;
  hr = sample->ConvertToContiguousBuffer(&buffer);
  if (FAILED(hr)) return hr;
  BYTE* bytes = nullptr;
  DWORD length = 0;
  hr = buffer->Lock(&bytes, nullptr, &length);
  if (FAILED(hr)) return hr;
  // The synchronous decoder returns a contiguous NV12 buffer with the output
  // type's stride. Reject truncated buffers before reading either plane.
  if (stride_ < static_cast<LONG>(width_) ||
      length < static_cast<uint64_t>(stride_) * height_ * 3 / 2) {
    buffer->Unlock();
    return MF_E_BUFFERTOOSMALL;
  }
  hr = ConvertPixels(bytes, static_cast<uint32_t>(stride_), height_, sample);
  buffer->Unlock();
  return hr;
}

HRESULT H264Decoder::QueueReadback(ID3D11Texture2D* texture, UINT subresource, IMFSample* sample) {
  D3D11_TEXTURE2D_DESC desc{};
  texture->GetDesc(&desc);
  if (!context_ || desc.Format != DXGI_FORMAT_NV12 ||
      desc.Width < width_ || desc.Height < height_) return MF_E_INVALIDMEDIATYPE;
  // Bound retained decoder surfaces and staging allocations. Normally the copy
  // completes while the next access unit is being decoded, so Map never waits.
  HRESULT hr = Readback(readbacks_.size() >= 3);
  if (FAILED(hr)) return hr;
  ComPtr<ID3D11Texture2D> target;
  if (!readback_pool_.empty()) {
    target = std::move(readback_pool_.back());
    readback_pool_.pop_back();
  } else {
    desc.Usage = D3D11_USAGE_STAGING;
    desc.BindFlags = desc.MiscFlags = 0;
    desc.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
    desc.ArraySize = desc.MipLevels = 1;
    hr = device_->CreateTexture2D(&desc, nullptr, &target);
    if (FAILED(hr)) return hr;
  }
  context_->CopySubresourceRegion(target.Get(), 0, 0, 0, 0, texture, subresource, nullptr);
  readbacks_.push_back({target, sample, desc.Height});
  context_->Flush();
  // Preserve immediate startup; subsequent frames use nonblocking readback.
  hr = Readback(first_readback_);
  first_readback_ = false;
  return hr;
}

HRESULT H264Decoder::Readback(bool wait) {
  while (!readbacks_.empty()) {
    auto& pending = readbacks_.front();
    D3D11_MAPPED_SUBRESOURCE mapped{};
    HRESULT hr = context_->Map(pending.texture.Get(), 0, D3D11_MAP_READ,
                              wait ? 0 : D3D11_MAP_FLAG_DO_NOT_WAIT, &mapped);
    if (hr == DXGI_ERROR_WAS_STILL_DRAWING) return S_OK;
    if (FAILED(hr)) return hr;
    hr = ConvertPixels(static_cast<const uint8_t*>(mapped.pData), mapped.RowPitch,
                       pending.height, pending.sample.Get());
    context_->Unmap(pending.texture.Get(), 0);
    readback_pool_.push_back(std::move(pending.texture));
    readbacks_.pop_front();
    if (FAILED(hr)) return hr;
  }
  return S_OK;
}

HRESULT H264Decoder::ConvertGpu(ID3D11Texture2D* source, UINT subresource, IMFSample* sample) {
  HRESULT hr = FinishGpu(gpu_pending_.size() >= 3);
  if (FAILED(hr)) return hr;
  ComPtr<ID3D11VideoDevice> video;
  ComPtr<ID3D11VideoContext> video_context;
  hr = device_.As(&video);
  if (FAILED(hr)) return hr;
  hr = context_.As(&video_context);
  if (FAILED(hr)) return hr;
  D3D11_TEXTURE2D_DESC input_desc{};
  source->GetDesc(&input_desc);
  if (!processor_) {
    D3D11_VIDEO_PROCESSOR_CONTENT_DESC content{};
    content.InputFrameFormat = D3D11_VIDEO_FRAME_FORMAT_PROGRESSIVE;
    content.InputFrameRate = {fps_, 1};
    content.OutputFrameRate = {fps_, 1};
    content.InputWidth = input_desc.Width;
    content.InputHeight = input_desc.Height;
    content.OutputWidth = visible_width_;
    content.OutputHeight = visible_height_;
    content.Usage = D3D11_VIDEO_USAGE_PLAYBACK_NORMAL;
    hr = video->CreateVideoProcessorEnumerator(&content, &processor_enum_);
    if (FAILED(hr)) return hr;
    hr = video->CreateVideoProcessor(processor_enum_.Get(), 0, &processor_);
    if (FAILED(hr)) return hr;
  }
  // Exposed frames remain immutable. Only an unconsumed, GPU-complete frame
  // may recycle its texture/view/query when replaced by a newer picture.
  DecodedVideoFrame frame;
  frame.width = visible_width_;
  frame.height = visible_height_;
  LONGLONG time = 0;
  sample->GetSampleTime(&time);
  frame.pts_us = time / 10;
  D3D11_TEXTURE2D_DESC desc{};
  desc.Width = frame.width;
  desc.Height = frame.height;
  desc.MipLevels = desc.ArraySize = 1;
  desc.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
  desc.SampleDesc.Count = 1;
  desc.Usage = D3D11_USAGE_DEFAULT;
  desc.BindFlags = D3D11_BIND_RENDER_TARGET | D3D11_BIND_SHADER_RESOURCE;
  // ANGLE's shared-handle import does not perform our keyed-mutex protocol.
  // Publish an immutable ordinary shared resource only after its GPU event.
  desc.MiscFlags = D3D11_RESOURCE_MISC_SHARED;
  frame.gpu_pool = gpu_pool_;
  frame.gpu_surface = gpu_pool_->Acquire(frame.width, frame.height, processor_enum_.Get());
  if (frame.gpu_surface) {
    ++gpu_reuses_;
  } else {
    auto surface = std::make_shared<GpuSurface>();
    surface->width = frame.width;
    surface->height = frame.height;
    surface->enumerator = processor_enum_;
    hr = device_->CreateTexture2D(&desc, nullptr, &surface->texture);
    if (FAILED(hr)) return hr;
    ComPtr<IDXGIResource> resource;
    hr = surface->texture.As(&resource);
    if (FAILED(hr)) return hr;
    hr = resource->GetSharedHandle(&surface->handle);
    if (FAILED(hr)) return hr;
    D3D11_VIDEO_PROCESSOR_OUTPUT_VIEW_DESC out{};
    out.ViewDimension = D3D11_VPOV_DIMENSION_TEXTURE2D;
    hr = video->CreateVideoProcessorOutputView(surface->texture.Get(), processor_enum_.Get(), &out, &surface->view);
    if (FAILED(hr)) return hr;
    D3D11_QUERY_DESC query_desc{D3D11_QUERY_EVENT, 0};
    hr = device_->CreateQuery(&query_desc, &surface->completed);
    if (FAILED(hr)) return hr;
    frame.gpu_surface = std::move(surface);
    ++gpu_allocations_;
  }
  frame.gpu = frame.gpu_surface->texture;
  frame.shared_handle = frame.gpu_surface->handle;
  D3D11_VIDEO_PROCESSOR_INPUT_VIEW_DESC in{};
  in.ViewDimension = D3D11_VPIV_DIMENSION_TEXTURE2D;
  in.Texture2D.MipSlice = subresource % input_desc.MipLevels;
  in.Texture2D.ArraySlice = subresource / input_desc.MipLevels;
  ComPtr<ID3D11VideoProcessorInputView> input;
  hr = video->CreateVideoProcessorInputView(source, processor_enum_.Get(), &in, &input);
  if (FAILED(hr)) return hr;
  RECT src{static_cast<LONG>(crop_x_), static_cast<LONG>(crop_y_),
           static_cast<LONG>(crop_x_ + frame.width), static_cast<LONG>(crop_y_ + frame.height)};
  RECT dst{0, 0, static_cast<LONG>(frame.width), static_cast<LONG>(frame.height)};
  video_context->VideoProcessorSetStreamSourceRect(processor_.Get(), 0, TRUE, &src);
  video_context->VideoProcessorSetStreamDestRect(processor_.Get(), 0, TRUE, &dst);
  video_context->VideoProcessorSetOutputTargetRect(processor_.Get(), TRUE, &dst);
  video_context->VideoProcessorSetStreamAutoProcessingMode(processor_.Get(), 0, FALSE);
  video_context->VideoProcessorSetStreamAlpha(processor_.Get(), 0, TRUE, 1.0f);
  video_context->VideoProcessorSetOutputAlphaFillMode(processor_.Get(),
      D3D11_VIDEO_PROCESSOR_ALPHA_FILL_MODE_OPAQUE, 0);
  D3D11_VIDEO_PROCESSOR_COLOR_SPACE color{};
  color.YCbCr_Matrix = bt709_ ? 1 : 0;
  color.Nominal_Range = full_range_ ? D3D11_VIDEO_PROCESSOR_NOMINAL_RANGE_0_255
                                  : D3D11_VIDEO_PROCESSOR_NOMINAL_RANGE_16_235;
  video_context->VideoProcessorSetStreamColorSpace(processor_.Get(), 0, &color);
  D3D11_VIDEO_PROCESSOR_COLOR_SPACE rgb{};
  rgb.Nominal_Range = D3D11_VIDEO_PROCESSOR_NOMINAL_RANGE_0_255;
  video_context->VideoProcessorSetOutputColorSpace(processor_.Get(), &rgb);
  D3D11_VIDEO_PROCESSOR_STREAM stream{};
  stream.Enable = TRUE;
  stream.pInputSurface = input.Get();
  hr = video_context->VideoProcessorBlt(processor_.Get(), frame.gpu_surface->view.Get(), 0, 1, &stream);
  if (FAILED(hr)) return hr;
  auto completed = frame.gpu_surface->completed;
  context_->End(completed.Get());
  // GetData below permits driver submission. Forcing Flush for every picture
  // can block this decoder worker in the driver for hundreds of milliseconds.
  // Keep the decoder sample alive until the processor has finished reading it.
  gpu_pending_.push_back({std::move(frame), completed, sample});
  return FinishGpu(false);
}

HRESULT H264Decoder::FinishGpu(bool wait) {
  const auto deadline = std::chrono::steady_clock::now() + std::chrono::milliseconds(100);
  while (!gpu_pending_.empty()) {
    auto& pending = gpu_pending_.front();
    // Allow submission of deferred driver work; DONOTFLUSH can leave the
    // video-processor event pending indefinitely even after an explicit Flush.
    HRESULT hr = context_->GetData(pending.completed.Get(), nullptr, 0, 0);
    if (hr == S_FALSE) {
      if (!wait) return S_OK;
      if (std::chrono::steady_clock::now() >= deadline) return HRESULT_FROM_WIN32(WAIT_TIMEOUT);
      std::this_thread::sleep_for(std::chrono::milliseconds(1));
      continue;
    }
    if (FAILED(hr)) return hr;
    auto frame = std::move(pending.frame);
    frame.gpu_complete = true;
    gpu_pending_.pop_front();
    output_(std::move(frame));
  }
  return S_OK;
}

HRESULT H264Decoder::ConvertPixels(const uint8_t* bytes, uint32_t pitch,
                                   uint32_t storage_height, IMFSample* sample) {
  DecodedVideoFrame frame;
  frame.width = visible_width_;
  frame.height = visible_height_;
  LONGLONG time = 0;
  sample->GetSampleTime(&time);
  frame.pts_us = time / 10;
  frame.pixel_pool = pixel_pool_;
  frame.rgba = pixel_pool_->Acquire(static_cast<size_t>(frame.width) * frame.height * 4);
  const auto* uv = bytes + static_cast<size_t>(pitch) * storage_height;
  for (uint32_t row = 0; row < frame.height; ++row) {
    ConvertRow(bytes + static_cast<size_t>(row + crop_y_) * pitch + crop_x_,
               uv + static_cast<size_t>((row + crop_y_) / 2) * pitch + crop_x_,
               frame.rgba.data() + static_cast<size_t>(row) * frame.width * 4,
               frame.width, bt709_, full_range_);
  }
  output_(std::move(frame));
  return S_OK;
}
