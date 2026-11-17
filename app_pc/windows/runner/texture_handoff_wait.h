#ifndef DEXLINK_TEXTURE_HANDOFF_WAIT_H_
#define DEXLINK_TEXTURE_HANDOFF_WAIT_H_

#include <windows.h>
#include <chrono>

// A decoder-local deadline, independent of the process-wide timer period.
// The caller arms under the texture mutex, then unlocks before waiting so
// raster consumption or shutdown can signal it without losing a wakeup.
class TextureHandoffWait {
 public:
  TextureHandoffWait() {
    consumed_ = CreateEventW(nullptr, FALSE, FALSE, nullptr);
    timer_ = CreateWaitableTimerExW(nullptr, nullptr, 0x00000002,
        TIMER_MODIFY_STATE | SYNCHRONIZE);  // CREATE_WAITABLE_TIMER_HIGH_RESOLUTION
  }
  ~TextureHandoffWait() {
    if (timer_) CloseHandle(timer_);
    if (consumed_) CloseHandle(consumed_);
  }
  TextureHandoffWait(const TextureHandoffWait&) = delete;
  TextureHandoffWait& operator=(const TextureHandoffWait&) = delete;
  bool available() const { return timer_ && consumed_; }
  bool Arm(std::chrono::microseconds budget) {
    if (!available() || budget.count() <= 0) return false;
    ResetEvent(consumed_);
    LARGE_INTEGER due;
    due.QuadPart = -budget.count() * 10;
    return SetWaitableTimerEx(timer_, &due, 0, nullptr, nullptr, nullptr, 0) != FALSE;
  }
  bool Wait() {
    HANDLE handles[]{consumed_, timer_};
    const auto result = WaitForMultipleObjects(2, handles, FALSE, 50);
    CancelWaitableTimer(timer_);
    return result == WAIT_OBJECT_0;
  }
  void Signal() { if (consumed_) SetEvent(consumed_); }

 private:
  HANDLE consumed_ = nullptr;
  HANDLE timer_ = nullptr;
};

#endif
