#ifndef CATOMICS_H
#define CATOMICS_H

#include <stdint.h>

// Minimal acquire/release atomics for handing data to the real-time audio thread
// without locks (Swift's Synchronization.Atomic needs macOS 15).

static inline void ca_store_ptr(void *_Nullable *_Nonnull p, void *_Nullable v) {
    __atomic_store_n(p, v, __ATOMIC_RELEASE);
}

static inline void *_Nullable ca_load_ptr(void *_Nullable *_Nonnull p) {
    return __atomic_load_n(p, __ATOMIC_ACQUIRE);
}

static inline void ca_store_u64(uint64_t *_Nonnull p, uint64_t v) {
    __atomic_store_n(p, v, __ATOMIC_RELEASE);
}

static inline uint64_t ca_load_u64(uint64_t *_Nonnull p) {
    return __atomic_load_n(p, __ATOMIC_ACQUIRE);
}

static inline void ca_store_float(float *_Nonnull p, float v) {
    __atomic_store(p, &v, __ATOMIC_RELAXED);
}

static inline float ca_load_float(float *_Nonnull p) {
    float v;
    __atomic_load(p, &v, __ATOMIC_RELAXED);
    return v;
}

#endif
