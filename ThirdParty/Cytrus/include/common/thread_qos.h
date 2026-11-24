// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once

#if defined(__APPLE__)
#include <TargetConditionals.h>
#if TARGET_OS_IPHONE
#include <pthread/qos.h>
#endif
#endif

namespace Common {

enum class ThreadQoS { Inherit, Utility, UserInitiated };

inline void ConfigureCurrentThreadQoS(ThreadQoS qos) {
#if defined(__APPLE__) && TARGET_OS_IPHONE
    if (qos != ThreadQoS::Inherit) {
        // Do not combine this with pthread_setschedparam: that opts a thread
        // out of Apple's QoS scheduling. This is a hint, not core affinity.
        const auto qos_class =
            qos == ThreadQoS::UserInitiated ? QOS_CLASS_USER_INITIATED : QOS_CLASS_UTILITY;
        (void)pthread_set_qos_class_self_np(qos_class, 0);
    }
#else
    (void)qos;
#endif
}

} // namespace Common
