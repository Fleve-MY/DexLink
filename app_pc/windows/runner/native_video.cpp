#include "native_video.h"

#include <flutter/standard_method_codec.h>
#include "h264_decoder.h"
#include "video_pacing.h"
#include "texture_handoff_wait.h"
#include "latency_samples.h"
#include "texture_notifications.h"
#include "gpu_presentation_health.h"

#include <chrono>
#include <algorithm>
#include <condition_variable>
#include <cstdio>
#include <deque>
#include <mutex>
#include <thread>
#include <utility>

using flutter::EncodableMap;
using flutter::EncodableValue;

namespace {
EncodableMap Timing(const LatencySamples& samples, LatencySamples::Clock::time_point now) {
  const auto s = samples.Snapshot(now);
  return {{EncodableValue("n"), EncodableValue(static_cast<int64_t>(s.count))},
          {EncodableValue("windowMs"), EncodableValue(s.window_ms)},
          {EncodableValue("ageMs"), EncodableValue(s.age_ms)},
          {EncodableValue("p50Ms"), EncodableValue(s.p50_ms)},
          {EncodableValue("p99Ms"), EncodableValue(s.p99_ms)},
          {EncodableValue("maxMs"), EncodableValue(s.max_ms)}};
}

int64_t Integer(const EncodableMap& map, const char* key) {
  auto it = map.find(EncodableValue(key));
  if (it == map.end()) return 0;
  if (const auto* value = std::get_if<int32_t>(&it->second)) return *value;
  if (const auto* value = std::get_if<int64_t>(&it->second)) return *value;
  return 0;
}

struct VideoPacket {
  std::vector<uint8_t> data;
  int64_t pts_us;
  bool key;
  std::chrono::steady_clock::time_point received;
};

// Each raster callback holds its own reference until Flutter releases it.
// Replacing the latest frame never invalidates pixels being uploaded.
struct FrameLease {
  std::shared_ptr<DecodedVideoFrame> frame;
  FlutterDesktopPixelBuffer buffer{};
  explicit FrameLease(std::shared_ptr<DecodedVideoFrame> value)
      : frame(std::move(value)) {
    buffer.buffer = frame->rgba.data();
    buffer.width = frame->width;
    buffer.height = frame->height;
    buffer.release_context = this;
    buffer.release_callback = [](void* context) {
      delete static_cast<FrameLease*>(context);
    };
  }
};

struct GpuFrameLease {
  std::shared_ptr<DecodedVideoFrame> frame;
  FlutterDesktopGpuSurfaceDescriptor surface{};
  explicit GpuFrameLease(std::shared_ptr<DecodedVideoFrame> value) : frame(std::move(value)) {
    surface.struct_size = sizeof(surface);
    surface.handle = frame->shared_handle;
    surface.width = surface.visible_width = frame->width;
    surface.height = surface.visible_height = frame->height;
    surface.format = kFlutterDesktopPixelFormatBGRA8888;
  }
};
}  // namespace

class NativeVideoSession {
 public:
  explicit NativeVideoSession(flutter::TextureRegistrar* registrar)
      : registrar_(registrar) {
    texture_ = std::make_unique<flutter::TextureVariant>(flutter::PixelBufferTexture(
        [this](size_t, size_t) -> const FlutterDesktopPixelBuffer* {
          std::lock_guard<std::mutex> lock(mutex_);
          if (!latest_ || latest_->gpu) return nullptr;
          notifications_.Consumed(id_);
          consumed_.notify_one();
          handoff_wait_.Signal();
          if (presented_sequence_ != decoded_) {
            TracePull();
            presented_sequence_ = decoded_;
            ++presented_;
            const auto now = std::chrono::steady_clock::now();
            if (last_pull_.time_since_epoch().count())
              pull_intervals_.Add(now, std::chrono::duration<double, std::milli>(now - last_pull_).count());
            last_pull_ = now;
            pull_samples_.Add(now, std::chrono::duration<double, std::milli>(now - published_at_).count());
          }
          return &(new FrameLease(latest_))->buffer;
        }));
    id_ = registrar_->RegisterTexture(texture_.get());
    gpu_texture_ = std::make_unique<flutter::TextureVariant>(flutter::GpuSurfaceTexture(
        kFlutterDesktopGpuSurfaceTypeDxgiSharedHandle,
        [this](size_t, size_t) -> const FlutterDesktopGpuSurfaceDescriptor* {
          std::lock_guard<std::mutex> lock(mutex_);
          if (!latest_ || !latest_->gpu) return nullptr;
          notifications_.Consumed(gpu_id_);
          consumed_.notify_one();
          handoff_wait_.Signal();
          latest_->gpu_exposed = true;
          if (presented_sequence_ != decoded_) {
            TracePull();
            presented_sequence_ = decoded_;
            ++presented_;
            const auto now = std::chrono::steady_clock::now();
            if (last_pull_.time_since_epoch().count())
              pull_intervals_.Add(now, std::chrono::duration<double, std::milli>(now - last_pull_).count());
            last_pull_ = now;
            pull_samples_.Add(now, std::chrono::duration<double, std::milli>(now - published_at_).count());
          }
          // Flutter reads descriptor dimensions after its release callback.
          // Keep the descriptor in the session; release only the frame lease.
          gpu_descriptor_ = GpuFrameLease(latest_).surface;
          gpu_descriptor_.release_context = new std::shared_ptr<DecodedVideoFrame>(latest_);
          gpu_descriptor_.release_callback = [](void* context) {
            delete static_cast<std::shared_ptr<DecodedVideoFrame>*>(context);
          };
          return &gpu_descriptor_;
        }));
    gpu_id_ = registrar_->RegisterTexture(gpu_texture_.get());
  }

  ~NativeVideoSession() { Stop(); }
  int64_t id() const { return id_; }
  int64_t gpu_id() const { return gpu_id_; }

  void Start(uint32_t width, uint32_t height, std::string mode, uint32_t fps, bool gpu, bool hevc) {
    worker_ = std::thread([this, width, height, mode, fps, gpu, hevc] {
      const HRESULT com = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
      if (FAILED(com)) { SetError(com); return; }
      {
        auto decoder = std::make_unique<H264Decoder>();
        bool hardware = mode != "software";
        const auto output = [this](DecodedVideoFrame frame) {
          const bool gpu = frame.gpu != nullptr;
          auto next = std::make_shared<DecodedVideoFrame>(std::move(frame));
          bool notify;
          {
            std::unique_lock<std::mutex> lock(mutex_);
            if (latest_ && presented_sequence_ != decoded_) {
              const auto now = std::chrono::steady_clock::now();
              const double oldest = queue_.empty() ? 0.0 :
                  std::chrono::duration<double, std::milli>(now - queue_.front().received).count();
              const auto budget = TextureHandoffBudget(published_at_, now, oldest);
              if (budget.count() > 0) {
                const auto sequence = decoded_;
                ++handoff_waits_;
                if (handoff_wait_.Arm(budget)) {
                  lock.unlock();
                  handoff_wait_.Wait();
                  lock.lock();
                } else {
                  consumed_.wait_for(lock, budget, [this, sequence] {
                    return stopping_ || presented_sequence_ >= sequence;
                  });
                }
                handoff_samples_.Add(std::chrono::steady_clock::now(),
                    std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - now).count());
              }
            }
            if (stopping_) return;
            if (latest_ && presented_sequence_ != decoded_) {
              ++superseded_;
              for (auto& item : trace_) if (item.pts == latest_->pts_us) item.superseded = true;
            }
            latest_.swap(next);
            published_at_ = std::chrono::steady_clock::now();
            for (auto& item : trace_) if (item.pts == latest_->pts_us) item.publish = TraceNow();
            ++decoded_;
            notify = notifications_.Publish(gpu ? gpu_id_ : id_, published_at_);
          }
          // Recycling the old image must not hold up the raster callback.
          next.reset();
          if (notify) registrar_->MarkTextureFrameAvailable(gpu ? gpu_id_ : id_);
          last_output_ = std::chrono::steady_clock::now();
        };
        HRESULT hr = decoder->Open(width, height, output, hardware, gpu && gpu_id_ >= 0, fps, hevc);
        const auto software = [&] {
          decoder = std::make_unique<H264Decoder>();
          hardware = false;
          {
            std::lock_guard<std::mutex> lock(mutex_);
            fallback_ = "hardware-unavailable";
          }
          return decoder->Open(width, height, output, false, false, fps, hevc);
        };
        if (FAILED(hr) && hardware && mode == "auto") hr = software();
        if (FAILED(hr)) {
          SetError(hr);
        } else {
          GpuPresentationHealth presentation_health;
          const auto observe_presentation = [&](double ms, bool input) {
            if (decoder->gpu_presentation_active() && presentation_health.Observe(ms, input))
              decoder->PreferCpuPresentation();
          };
          for (;;) {
            int64_t retry;
            {
              std::lock_guard<std::mutex> lock(mutex_);
              retry = notifications_.Retry(std::chrono::steady_clock::now());
            }
            if (retry >= 0) registrar_->MarkTextureFrameAvailable(retry);
            VideoPacket packet;
            {
              std::unique_lock<std::mutex> lock(mutex_);
              ready_.wait_for(lock, std::chrono::milliseconds(fps >= 60 ? 1 : 2),
                              [this] { return stopping_ || !queue_.empty(); });
              if (stopping_) break;
              if (queue_.empty()) {
                lock.unlock();
                const auto before_poll = std::chrono::steady_clock::now();
                hr = decoder->Poll();
                if (FAILED(hr)) { SetError(hr); break; }
                observe_presentation(std::chrono::duration<double, std::milli>(
                    std::chrono::steady_clock::now() - before_poll).count(), false);
                continue;
              }
              packet = std::move(queue_.front());
              queued_bytes_ -= packet.data.size();
              queue_.pop_front();
              const auto dequeued = std::chrono::steady_clock::now();
              dwell_samples_.Add(dequeued, std::chrono::duration<double, std::milli>(dequeued - packet.received).count());
              // Keep H.264 references intact. Catch up by skipping readback,
              // conversion and texture upload, with a bounded display interval.
              const bool present = ShouldPresentVideoFrame(!queue_.empty(), packet.received,
                  last_output_, std::chrono::steady_clock::now(), fps);
              decoder->set_present_output(present);
              if (!present) ++skipped_;
            }
            const auto before = std::chrono::steady_clock::now();
            hr = decoder->Push(packet.data, packet.pts_us);
            const auto after = std::chrono::steady_clock::now();
            const auto elapsed_ms = std::chrono::duration<double, std::milli>(after - before).count();
            if (SUCCEEDED(hr)) observe_presentation(elapsed_ms, true);
            {
              std::lock_guard<std::mutex> lock(mutex_);
              decode_ms_ = elapsed_ms;
              local_ms_ = std::chrono::duration<double, std::milli>(after - packet.received).count();
              push_samples_.Add(after, decode_ms_);
              gpu_allocations_ = decoder->gpu_allocations();
              gpu_reuses_ = decoder->gpu_reuses();
              backend_ = hardware ? (decoder->hardware_active() ? "hardware" : "starting") : "software";
              if (hardware && decoder->gpu_fallback()) fallback_ = decoder->gpu_presentation_slow()
                  ? "gpu-presentation-slow" : "gpu-presentation-unavailable";
            }
            if (FAILED(hr)) {
              if (hardware && mode == "auto") {
                hr = software();
                if (SUCCEEDED(hr)) {
                  if (packet.key) {
                    hr = decoder->Push(packet.data, packet.pts_us);
                  } else {
                    std::lock_guard<std::mutex> lock(mutex_);
                    RecordQueueDrop(true);
                    queue_.clear();
                    queued_bytes_ = 0;
                    waiting_key_ = true;
                    need_key_ = true;
                  }
                }
                if (SUCCEEDED(hr)) continue;
              }
              SetError(hr); break;
            }
          }
        }
      }
      CoUninitialize();
    });
  }

  void Push(std::vector<uint8_t> data, int64_t pts_us, bool key) {
    std::lock_guard<std::mutex> lock(mutex_);
    if (stopping_ || FAILED(error_)) return;
    const bool stale_key = key && !queue_.empty() &&
        std::chrono::steady_clock::now() - queue_.front().received >= std::chrono::milliseconds(80);
    if (stale_key || queue_.size() >= 32 || queued_bytes_ + data.size() > 8 * 1024 * 1024) {
      RecordQueueDrop(false);
      queue_.clear();
      queued_bytes_ = 0;
      waiting_key_ = true;
      need_key_ = true;
    }
    if (waiting_key_ && !key) { ++dropped_; ++gate_drops_; return; }
    if (key) { waiting_key_ = false; need_key_ = false; }
    queued_bytes_ += data.size();
    trace_.push_back({pts_us, TraceNow()});
    if (trace_.size() > 256) trace_.pop_front();
    queue_.push_back({std::move(data), pts_us, key, std::chrono::steady_clock::now()});
    ready_.notify_one();
  }

  void Stop() {
    {
      std::lock_guard<std::mutex> lock(mutex_);
      stopping_ = true;
      queue_.clear();
      queued_bytes_ = 0;
    }
    ready_.notify_one();
    consumed_.notify_one();
    handoff_wait_.Signal();
    if (worker_.joinable()) worker_.join();
  }

  int64_t Queued() {
    std::lock_guard<std::mutex> lock(mutex_);
    return static_cast<int64_t>(queue_.size());
  }

  EncodableMap Stats(bool trace = false) {
    std::lock_guard<std::mutex> lock(mutex_);
    const auto now = std::chrono::steady_clock::now();
    char error[32]{};
    if (FAILED(error_)) std::snprintf(error, sizeof(error), "MF HRESULT 0x%08lX", static_cast<unsigned long>(error_));
    EncodableMap data{
        {EncodableValue("decoded"), EncodableValue(decoded_)},
        {EncodableValue("presented"), EncodableValue(presented_)},
        {EncodableValue("superseded"), EncodableValue(superseded_)},
        {EncodableValue("textureHandoffWaits"), EncodableValue(handoff_waits_)},
        {EncodableValue("textureHandoffPrecise"), EncodableValue(handoff_wait_.available())},
        {EncodableValue("textureHandoff"), EncodableValue(Timing(handoff_samples_, now))},
        {EncodableValue("textureId"), EncodableValue(latest_ && latest_->gpu ? gpu_id_ : id_)},
        {EncodableValue("gpuSurface"), EncodableValue(latest_ && latest_->gpu != nullptr)},
        {EncodableValue("dropped"), EncodableValue(dropped_)},
        {EncodableValue("queued"), EncodableValue(static_cast<int64_t>(queue_.size()))},
        {EncodableValue("skipped"), EncodableValue(skipped_)},
        {EncodableValue("needKeyframe"), EncodableValue(need_key_ || (!queue_.empty() &&
            now - queue_.front().received >= std::chrono::milliseconds(120)))},
        {EncodableValue("width"), EncodableValue(static_cast<int32_t>(latest_ ? latest_->width : 0))},
        {EncodableValue("height"), EncodableValue(static_cast<int32_t>(latest_ ? latest_->height : 0))},
        {EncodableValue("decodeMs"), EncodableValue(decode_ms_)},
        {EncodableValue("localMs"), EncodableValue(local_ms_)},
        {EncodableValue("nativeDwell"), EncodableValue(Timing(dwell_samples_, now))},
        {EncodableValue("nativeDropDwell"), EncodableValue(Timing(drop_samples_, now))},
        {EncodableValue("pushTime"), EncodableValue(Timing(push_samples_, now))},
        {EncodableValue("texturePull"), EncodableValue(Timing(pull_samples_, now))},
        {EncodableValue("textureInterval"), EncodableValue(Timing(pull_intervals_, now))},
        {EncodableValue("textureNotifications"), EncodableValue(notifications_.notifications)},
        {EncodableValue("textureCoalesced"), EncodableValue(notifications_.coalesced)},
        {EncodableValue("textureRetries"), EncodableValue(notifications_.retries)},
        {EncodableValue("gpuAllocations"), EncodableValue(static_cast<int64_t>(gpu_allocations_))},
        {EncodableValue("gpuReuses"), EncodableValue(static_cast<int64_t>(gpu_reuses_))},
        {EncodableValue("nativeOldestMs"), EncodableValue(queue_.empty() ? 0.0 :
            std::chrono::duration<double, std::milli>(now - queue_.front().received).count())},
        {EncodableValue("nativeClearDrops"), EncodableValue(clear_drops_)},
        {EncodableValue("nativeFallbackDrops"), EncodableValue(fallback_drops_)},
        {EncodableValue("nativeGateDrops"), EncodableValue(gate_drops_)},
        {EncodableValue("nativeClears"), EncodableValue(clears_)},
        {EncodableValue("error"), EncodableValue(error)},
        {EncodableValue("backend"), EncodableValue(backend_)},
        {EncodableValue("fallback"), EncodableValue(fallback_)},
    };
    if (trace) {
      flutter::EncodableList items;
      for (const auto& item : trace_) items.emplace_back(EncodableMap{
          {EncodableValue("pts"), EncodableValue(item.pts)},
          {EncodableValue("inputMs"), EncodableValue(item.input)},
          {EncodableValue("publishMs"), EncodableValue(item.publish)},
          {EncodableValue("pullMs"), EncodableValue(item.pull)},
          {EncodableValue("superseded"), EncodableValue(item.superseded)}});
      data[EncodableValue("frames")] = EncodableValue(items);
    }
    return data;
  }

 private:
  struct FrameTrace { int64_t pts; double input, publish = -1, pull = -1; bool superseded = false; };
  std::deque<FrameTrace> trace_;
  const std::chrono::steady_clock::time_point trace_start_ = std::chrono::steady_clock::now();
  double TraceNow() const {
    return std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - trace_start_).count();
  }
  void TracePull() {
    for (auto& item : trace_) if (item.pts == latest_->pts_us && item.pull < 0) item.pull = TraceNow();
  }
  // Called under mutex before retiring compressed references.
  void RecordQueueDrop(bool fallback) {
    const auto now = std::chrono::steady_clock::now();
    for (const auto& packet : queue_) {
      drop_samples_.Add(now, std::chrono::duration<double, std::milli>(now - packet.received).count());
    }
    const auto count = static_cast<int64_t>(queue_.size());
    dropped_ += count;
    if (fallback) fallback_drops_ += count; else clear_drops_ += count;
    ++clears_;
  }
  void SetError(HRESULT error) {
    std::lock_guard<std::mutex> lock(mutex_);
    error_ = error;
  }
  flutter::TextureRegistrar* registrar_;
  std::unique_ptr<flutter::TextureVariant> texture_;
  std::unique_ptr<flutter::TextureVariant> gpu_texture_;
  FlutterDesktopGpuSurfaceDescriptor gpu_descriptor_{};
  int64_t id_ = -1;
  int64_t gpu_id_ = -1;
  std::thread worker_;
  std::mutex mutex_;
  std::condition_variable ready_;
  std::condition_variable consumed_;
  TextureHandoffWait handoff_wait_;
  std::deque<VideoPacket> queue_;
  size_t queued_bytes_ = 0;
  bool stopping_ = false;
  bool waiting_key_ = true;
  bool need_key_ = false;
  int64_t skipped_ = 0;
  std::chrono::steady_clock::time_point last_output_{};
  HRESULT error_ = S_OK;
  std::shared_ptr<DecodedVideoFrame> latest_;
  int64_t decoded_ = 0;
  int64_t presented_ = 0;
  int64_t superseded_ = 0;
  int64_t handoff_waits_ = 0;
  LatencySamples handoff_samples_;
  int64_t presented_sequence_ = 0;
  int64_t dropped_ = 0;
  double decode_ms_ = 0;
  double local_ms_ = 0;
  LatencySamples dwell_samples_, drop_samples_, push_samples_, pull_samples_;
  LatencySamples pull_intervals_;
  std::chrono::steady_clock::time_point last_pull_{};
  TextureNotifications notifications_;
  uint64_t gpu_allocations_ = 0, gpu_reuses_ = 0;
  std::chrono::steady_clock::time_point published_at_{};
  int64_t clear_drops_ = 0, fallback_drops_ = 0, gate_drops_ = 0, clears_ = 0;
  std::string backend_ = "starting";
  std::string fallback_;
};

NativeVideoBridge::NativeVideoBridge(FlutterDesktopPluginRegistrarRef registrar)
    : registrar_(std::make_unique<flutter::PluginRegistrar>(registrar)),
      channel_(std::make_unique<flutter::MethodChannel<EncodableValue>>(
          registrar_->messenger(), "dexlink/video", &flutter::StandardMethodCodec::GetInstance())) {
  channel_->SetMethodCallHandler([this](const auto& call, auto result) {
    const auto* args = std::get_if<EncodableMap>(call.arguments());
    if (!args) { result->Error("arguments", "Expected a video argument map"); return; }
    const auto& method = call.method_name();
    if (method == "capabilities") {
      bool supported = false;
      const auto size = static_cast<uint32_t>(std::clamp<int64_t>(Integer(*args, "maxSize"), 640, 3840));
      std::thread probe([&] {
        const HRESULT com = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
        if (FAILED(com)) return;
        { H264Decoder decoder;
          supported = SUCCEEDED(decoder.Open(size, size, [](DecodedVideoFrame) {}, true, false, 60, true)); }
        CoUninitialize();
      });
      probe.join();
      result->Success(EncodableValue(EncodableMap{{EncodableValue("hevcHardware"), EncodableValue(supported)}}));
      return;
    }
    if (method == "create") {
      const auto width = Integer(*args, "width");
      const auto height = Integer(*args, "height");
      if (width < 2 || height < 2 || width > 8192 || height > 8192) {
        result->Error("size", "Invalid video size"); return;
      }
      auto session = std::make_shared<NativeVideoSession>(registrar_->texture_registrar());
      if (session->id() < 0) { result->Error("texture", "Texture registration failed"); return; }
      sessions_[session->id()] = session;
      const auto mode_it = args->find(EncodableValue("mode"));
      const auto* mode = mode_it == args->end() ? nullptr : std::get_if<std::string>(&mode_it->second);
      if (!mode || (*mode != "auto" && *mode != "hardware" && *mode != "software")) {
        sessions_.erase(session->id());
        registrar_->texture_registrar()->UnregisterTexture(session->id(), [session] {});
        if (session->gpu_id() >= 0) registrar_->texture_registrar()->UnregisterTexture(session->gpu_id(), [session] {});
        result->Error("mode", "Invalid decoder mode"); return;
      }
      const auto fps = Integer(*args, "fps");
      const auto gpu_it = args->find(EncodableValue("gpu"));
      const bool gpu = gpu_it != args->end() && std::get_if<bool>(&gpu_it->second) &&
          std::get<bool>(gpu_it->second);
      session->Start(static_cast<uint32_t>(width), static_cast<uint32_t>(height), *mode,
                     static_cast<uint32_t>(fps > 0 && fps <= 240 ? fps : 60), gpu,
                     Integer(*args, "codec") == 0x68323635);
      result->Success(EncodableValue(session->id()));
      return;
    }
    const auto id = Integer(*args, "id");
    auto it = sessions_.find(id);
    if (it == sessions_.end()) { result->Error("session", "Video session is closed"); return; }
    auto session = it->second;
    if (method == "queued") {
      result->Success(EncodableValue(session->Queued()));
    } else if (method == "pushBatch") {
      auto packets = args->find(EncodableValue("packets"));
      const auto* batch = packets == args->end() ? nullptr :
          std::get_if<flutter::EncodableList>(&packets->second);
      if (!batch || batch->empty() || batch->size() > 4) {
        result->Error("packet", "Invalid H.264 batch"); return;
      }
      // Validate the whole batch before accepting any access unit.
      for (const auto& entry : *batch) {
        const auto* packet = std::get_if<EncodableMap>(&entry);
        if (!packet) { result->Error("packet", "Invalid H.264 packet"); return; }
        const auto data = packet->find(EncodableValue("data"));
        const auto* bytes = data == packet->end() ? nullptr :
            std::get_if<std::vector<uint8_t>>(&data->second);
        if (!bytes || bytes->empty() || bytes->size() > 16 * 1024 * 1024) {
          result->Error("packet", "Invalid H.264 payload"); return;
        }
      }
      for (const auto& entry : *batch) {
        const auto& packet = std::get<EncodableMap>(entry);
        const auto key = packet.find(EncodableValue("key"));
        session->Push(std::get<std::vector<uint8_t>>(packet.at(EncodableValue("data"))),
            Integer(packet, "pts"), key != packet.end() &&
            std::get_if<bool>(&key->second) && std::get<bool>(key->second));
      }
      result->Success(EncodableValue(session->Queued()));
    } else if (method == "push") {
      auto data = args->find(EncodableValue("data"));
      auto key = args->find(EncodableValue("key"));
      const auto* bytes = data == args->end() ? nullptr : std::get_if<std::vector<uint8_t>>(&data->second);
      if (!bytes || bytes->size() > 16 * 1024 * 1024) {
        result->Error("packet", "Invalid H.264 packet"); return;
      }
      session->Push(*bytes, Integer(*args, "pts"),
                    key != args->end() && std::get_if<bool>(&key->second) && std::get<bool>(key->second));
      result->Success();
    } else if (method == "stats") {
      const auto trace = args->find(EncodableValue("trace"));
      result->Success(EncodableValue(session->Stats(trace != args->end() &&
          std::get_if<bool>(&trace->second) && std::get<bool>(trace->second))));
    } else if (method == "pause" || method == "dispose") {
      session->Stop();
      if (method == "dispose") {
        sessions_.erase(it);
        registrar_->texture_registrar()->UnregisterTexture(id, [session] {});
        if (session->gpu_id() >= 0) registrar_->texture_registrar()->UnregisterTexture(session->gpu_id(), [session] {});
      }
      result->Success();
    } else {
      result->NotImplemented();
    }
  });
}

NativeVideoBridge::~NativeVideoBridge() {
  channel_->SetMethodCallHandler(nullptr);
  for (auto& entry : sessions_) {
    auto session = entry.second;
    session->Stop();
    registrar_->texture_registrar()->UnregisterTexture(entry.first, [session] {});
    if (session->gpu_id() >= 0) registrar_->texture_registrar()->UnregisterTexture(session->gpu_id(), [session] {});
  }
  sessions_.clear();
}
