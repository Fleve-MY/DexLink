#ifndef DEXLINK_NATIVE_VIDEO_H_
#define DEXLINK_NATIVE_VIDEO_H_

#include <flutter/method_channel.h>
#include <flutter/plugin_registrar.h>
#include <map>
#include <memory>

class NativeVideoSession;

class NativeVideoBridge {
 public:
  explicit NativeVideoBridge(FlutterDesktopPluginRegistrarRef registrar);
  ~NativeVideoBridge();

 private:
  std::unique_ptr<flutter::PluginRegistrar> registrar_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
  std::map<int64_t, std::shared_ptr<NativeVideoSession>> sessions_;
};

#endif
