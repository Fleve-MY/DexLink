#ifndef DEXLINK_GPU_PRESENTATION_HEALTH_H_
#define DEXLINK_GPU_PRESENTATION_HEALTH_H_

// Ignore decoder startup. A six-frame deadline miss in steady streaming is
// enough to prefer compatibility presentation for the rest of this connection.
class GpuPresentationHealth {
 public:
  bool Observe(double elapsed_ms, bool input = true) {
    if (input && samples_ <= 8) ++samples_;
    return samples_ > 8 && elapsed_ms >= 100.0;
  }
 private:
  unsigned samples_ = 0;
};

#endif
