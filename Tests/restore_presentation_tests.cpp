// SPDX-License-Identifier: GPL-3.0-or-later
#include "RestorePresentation.hpp"
#include <cassert>
#include <iostream>

int main() {
    Claw::RestorePresentation policy;
    assert(!policy.Ready() && !policy.BypassScaler() && !policy.HasCompletedFrame());
    policy.Begin();
    const auto first = policy.Generation();
    for (int i = 0; i < 10; ++i) policy.Completed(first);
    assert(!policy.Ready() && policy.BypassScaler() && !policy.HasCompletedFrame());
    policy.Warmed();
    policy.Completed(first);
    assert(policy.HasCompletedFrame() && !policy.Ready());
    for (int i = 1; i < 3; ++i) policy.Completed(first);
    assert(!policy.BypassScaler() && !policy.Ready());
    policy.Completed(first); assert(!policy.Ready());
    policy.Completed(first); assert(policy.Ready() && !policy.AwaitingFrames());
    policy.Begin(); policy.Warmed();
    for (int i = 0; i < 20; ++i) policy.Completed(first); // Old GPU slots cannot reveal it.
    assert(!policy.Ready() && policy.BypassScaler() && !policy.HasCompletedFrame());
    const auto second = policy.Generation();
    for (int i = 0; i < 5; ++i) policy.Completed(second);
    assert(policy.Ready());
    policy.Reset(); assert(!policy.Ready() && !policy.HasCompletedFrame());
    std::cout << "PASS: restore generations, shader readiness, three-frame scaler bypass and five completed presentations\n";
}
