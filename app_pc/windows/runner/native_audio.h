#ifndef DEXLINK_NATIVE_AUDIO_H_
#define DEXLINK_NATIVE_AUDIO_H_
#include <flutter/method_channel.h>
#include <windows.h>
#include <mmsystem.h>
#include <list>
#include <memory>
#include <vector>

// Bounded PCM playback on the Windows default output device.
class NativeAudioBridge {
 public:
  explicit NativeAudioBridge(flutter::BinaryMessenger* messenger);
  ~NativeAudioBridge();
 private:
  struct Block { WAVEHDR header{}; std::vector<uint8_t> bytes; };
  void Clear();
  void Reap();
  HWAVEOUT output_ = nullptr;
  int64_t id_ = 0;
  std::list<std::unique_ptr<Block>> blocks_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
};
#endif
