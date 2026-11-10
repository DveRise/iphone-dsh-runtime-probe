#pragma once

#include <stdint.h>

#define ReplayProbePort 46031
#define ReplayProbeQuery 'R'
#define ReplayProbeTestCodeQuery 'C'
#define ReplayProbeNoTestCode UINT16_MAX

typedef enum : uint8_t {
    ReplayProbeIdle,
    ReplayProbeWaiting,
    ReplayProbeFrames,
    ReplayProbeVisionError,
    ReplayProbeNoMatch,
    ReplayProbeMatchedChinese,
    ReplayProbeMatchedEnglish,
    ReplayProbeMatchedTestCode,
} ReplayProbeStatus;
