// SPDX-License-Identifier: GPL-3.0-only
#pragma once

#include <stddef.h>
#include <string.h>

// Avoid colliding with the full ZXTouch service.
#define PROBE_PORT 46030

enum ProbeCommand { ProbeInvalid, ProbeStatus, ProbeScreenshot, ProbeRecognize };

static inline enum ProbeCommand ProbeParse(const char *bytes, size_t size) {
    if (size != 4) return ProbeInvalid;
    if (memcmp(bytes, "00\r\n", 4) == 0) return ProbeStatus;
    if (memcmp(bytes, "30\r\n", 4) == 0) return ProbeScreenshot;
    if (memcmp(bytes, "27\r\n", 4) == 0) return ProbeRecognize;
    return ProbeInvalid;
}
