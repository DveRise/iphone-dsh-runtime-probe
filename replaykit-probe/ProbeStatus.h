#pragma once

#include <stdint.h>

#define ReplayProbePort 46031
#define ReplayProbeQuery 'R'

typedef enum : uint8_t {
    ReplayProbeIdle,
    ReplayProbeWaiting,
    ReplayProbeFrames,
    ReplayProbeVisionError,
    ReplayProbeNoMatch,
    ReplayProbeMatchedChinese,
    ReplayProbeMatchedEnglish,
} ReplayProbeStatus;
