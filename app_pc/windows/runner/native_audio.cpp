#include "native_audio.h"
#include <flutter/standard_method_codec.h>

using flutter::EncodableValue;
using flutter::EncodableMap;

namespace {
int64_t Number(const EncodableMap& map, const char* key) {
  auto it = map.find(EncodableValue(key));
  if (it == map.end()) return -1;
  if (auto n = std::get_if<int32_t>(&it->second)) return *n;
  if (auto n = std::get_if<int64_t>(&it->second)) return *n;
  return -1;
}
}

NativeAudioBridge::NativeAudioBridge(flutter::BinaryMessenger* messenger)
    : channel_(std::make_unique<flutter::MethodChannel<EncodableValue>>(
          messenger, "dexlink/audio", &flutter::StandardMethodCodec::GetInstance())) {
  channel_->SetMethodCallHandler([this](const auto& call, auto result) {
    const auto* args = std::get_if<EncodableMap>(call.arguments());
    if (!args) { result->Error("arguments", "Expected audio map"); return; }
    const auto& method = call.method_name();
    if (method == "create") {
      if (Number(*args, "rate") != 48000 || Number(*args, "channels") != 2) {
        result->Error("format", "Unsupported audio format"); return;
      }
      Clear();
      WAVEFORMATEX format{};
      format.wFormatTag = WAVE_FORMAT_PCM;
      format.nChannels = 2;
      format.nSamplesPerSec = 48000;
      format.wBitsPerSample = 16;
      format.nBlockAlign = 4;
      format.nAvgBytesPerSec = 192000;
      const auto code = waveOutOpen(&output_, WAVE_MAPPER, &format, 0, 0, CALLBACK_NULL);
      if (code != MMSYSERR_NOERROR) {
        output_ = nullptr;
        result->Error("output", "Cannot open Windows audio output: " + std::to_string(code)); return;
      }
      result->Success(EncodableValue(++id_)); return;
    }
    if (Number(*args, "id") != id_) { result->Success(); return; }
    if (method == "dispose") { Clear(); result->Success(); return; }
    if (method == "reset") {
      if (output_) {
        waveOutReset(output_);
        Reap();
      }
      result->Success(); return;
    }
    if (method != "push") { result->NotImplemented(); return; }
    auto it = args->find(EncodableValue("data"));
    const auto* bytes = it == args->end() ? nullptr : std::get_if<std::vector<uint8_t>>(&it->second);
    if (!bytes || bytes->empty() || bytes->size() > 3840 || bytes->size() % 4) {
      result->Error("packet", "Invalid PCM packet"); return;
    }
    if (!output_) { result->Error("output", "Audio output is closed"); return; }
    Reap();
    size_t queued = 0;
    for (const auto& block : blocks_) queued += block->bytes.size();
    if (queued + bytes->size() > 23040) {
      // A UI/network stall must not turn into seconds of delayed audio.
      waveOutReset(output_);
      Reap();
    }
    auto block = std::make_unique<Block>();
    block->bytes = *bytes;
    block->header.lpData = reinterpret_cast<LPSTR>(block->bytes.data());
    block->header.dwBufferLength = static_cast<DWORD>(block->bytes.size());
    auto code = waveOutPrepareHeader(output_, &block->header, sizeof(WAVEHDR));
    if (code == MMSYSERR_NOERROR) {
      code = waveOutWrite(output_, &block->header, sizeof(WAVEHDR));
      if (code != MMSYSERR_NOERROR) waveOutUnprepareHeader(output_, &block->header, sizeof(WAVEHDR));
    }
    if (code != MMSYSERR_NOERROR) {
      result->Error("output", "Audio write failed: " + std::to_string(code)); return;
    }
    blocks_.push_back(std::move(block));
    result->Success();
  });
}

void NativeAudioBridge::Reap() {
  for (auto it = blocks_.begin(); it != blocks_.end();) {
    if ((*it)->header.dwFlags & WHDR_DONE) {
      waveOutUnprepareHeader(output_, &(*it)->header, sizeof(WAVEHDR));
      it = blocks_.erase(it);
    } else ++it;
  }
}

void NativeAudioBridge::Clear() {
  if (!output_) return;
  waveOutReset(output_);
  Reap();
  waveOutClose(output_);
  output_ = nullptr;
}

NativeAudioBridge::~NativeAudioBridge() {
  channel_->SetMethodCallHandler(nullptr);
  Clear();
}
