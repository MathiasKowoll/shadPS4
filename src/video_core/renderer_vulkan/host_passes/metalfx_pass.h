//  SPDX-FileCopyrightText: Copyright 2026 shadPS4 Emulator Project
//  SPDX-License-Identifier: GPL-2.0-or-later

#pragma once

#include <memory>

#include "common/types.h"
#include "video_core/renderer_vulkan/vk_common.h"

namespace Vulkan {
class Instance;
class Scheduler;
struct Frame;
struct SubmitInfo;
} // namespace Vulkan

namespace Vulkan::HostPasses {

/// Upscales the presented frame with the MetalFX spatial scaler.
///
/// The scaler images live in dedicated memory whose MTLHeap is exported with
/// VK_EXT_external_memory_metal, and a Metal texture with the driver's descriptor is placed at
/// offset 0 of that heap. The post-processing pass renders the game image into one of two inputs
/// at game resolution. Once that submission completes, MetalFX writes the output of the frame on
/// its own Metal queue and signals a timeline semaphore from the host. The present thread waits for
/// that value on the host before it copies the output into the frame, so the game's queue never
/// waits for the scaler.
class MetalFxPass {
public:
    struct Settings {
        bool enable{false};
    };

    MetalFxPass();
    ~MetalFxPass();

    void Create(const Instance& instance, u32 num_frames);

    bool IsSupported() const;

    /// Returns the target for the post-processing pass, or nullptr when the frame is not scaled.
    Frame* BeginInput(Scheduler& scheduler, const Settings& settings, vk::Extent2D input_size,
                      const Frame& output, vk::Format format);

    /// Submits the input and queues the scaler behind it. Returns the value that the present
    /// thread waits for before copying the output into `output`.
    u64 Scale(Scheduler& scheduler, const Frame& output);

    /// Present thread: copies the scaled image into the frame once the scaler has finished.
    void CopyOutput(vk::CommandBuffer cmdbuf, Frame& frame, SubmitInfo& info);

private:
    struct Impl;
    std::unique_ptr<Impl> impl;
};

} // namespace Vulkan::HostPasses
