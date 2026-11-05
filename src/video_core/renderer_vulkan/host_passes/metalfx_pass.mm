//  SPDX-FileCopyrightText: Copyright 2026 shadPS4 Emulator Project
//  SPDX-License-Identifier: GPL-2.0-or-later

#define VK_USE_PLATFORM_METAL_EXT

#include <Metal/Metal.h>
#include <MetalFX/MetalFX.h>

#include <array>
#include <chrono>
#include <cstdlib>
#include <filesystem>
#include <limits>
#include <optional>
#include <vector>

#include "common/logging/log.h"
#include "video_core/renderer_vulkan/host_passes/metalfx_pass.h"
#include "video_core/renderer_vulkan/vk_instance.h"
#include "video_core/renderer_vulkan/vk_platform.h"
#include "video_core/renderer_vulkan/vk_presenter.h"
#include "video_core/renderer_vulkan/vk_scheduler.h"

namespace Vulkan::HostPasses {

namespace {

// KosmicKrisp creates the Metal texture of both kinds of images with this usage, and the aliasing
// texture must use the same descriptor to share the layout.
constexpr vk::ImageUsageFlags INPUT_USAGE =
    vk::ImageUsageFlagBits::eColorAttachment | vk::ImageUsageFlagBits::eSampled;
constexpr vk::ImageUsageFlags OUTPUT_USAGE = vk::ImageUsageFlagBits::eColorAttachment |
                                             vk::ImageUsageFlagBits::eSampled |
                                             vk::ImageUsageFlagBits::eTransferSrc;
constexpr MTLTextureUsage TEXTURE_USAGE = MTLTextureUsageShaderRead | MTLTextureUsageRenderTarget;

constexpr vk::ImageSubresourceRange COLOR_RANGE{
    .aspectMask = vk::ImageAspectFlagBits::eColor,
    .levelCount = 1,
    .layerCount = 1,
};

constexpr vk::ImageSubresourceLayers COLOR_LAYERS{
    .aspectMask = vk::ImageAspectFlagBits::eColor,
    .layerCount = 1,
};

std::optional<MTLPixelFormat> ToMetalFormat(vk::Format format) {
    switch (format) {
    case vk::Format::eB8G8R8A8Unorm:
        return MTLPixelFormatBGRA8Unorm;
    case vk::Format::eR8G8B8A8Unorm:
        return MTLPixelFormatRGBA8Unorm;
    case vk::Format::eA2B10G10R10UnormPack32:
        return MTLPixelFormatRGB10A2Unorm;
    default:
        return std::nullopt;
    }
}

/// A/B switch for diagnostics: while the file named by SHADPS4_METALFX_OFF_FILE exists, frames
/// take the regular presentation path.
bool IsSwitchedOff() {
    static const char* const path = std::getenv("SHADPS4_METALFX_OFF_FILE");
    if (path == nullptr || path[0] == '\0') {
        return false;
    }
    static std::chrono::steady_clock::time_point next_check{};
    static bool exists{};
    const auto now = std::chrono::steady_clock::now();
    if (now >= next_check) {
        next_check = now + std::chrono::milliseconds(500);
        std::error_code ec;
        exists = std::filesystem::exists(path, ec);
    }
    return exists;
}

} // Anonymous namespace

struct MetalFxPass::Impl {
    struct Target {
        vk::Image image;
        vk::DeviceMemory memory;
        vk::ImageView view;
        id<MTLTexture> texture{};
        vk::Extent2D size{};
        vk::Format format{};
    };

    bool CreateTarget(Target& target, vk::Extent2D size, vk::Format format,
                      vk::ImageUsageFlags usage, MTLPixelFormat pixel_format);
    void DestroyTarget(Target& target);
    vk::Result WaitDone(u64 value, u64 timeout_ns);
    void Encode(id<MTLFXSpatialScaler> scaler, id<MTLTexture> input, id<MTLTexture> output,
                vk::Extent2D input_size, u64 value);

    const Instance* instance{};
    vk::Device device;
    PFN_vkGetMemoryMetalHandleEXT get_metal_handle{};
    bool supported{};

    id<MTLCommandQueue> queue{};
    vk::UniqueSemaphore done;
    u64 serial{};

    // Used by the GPU command thread only. The scaler and the two inputs depend on the input size,
    // the output size and the format.
    id<MTLFXSpatialScaler> scaler{};
    vk::Extent2D input_size{};
    vk::Extent2D output_size{};
    vk::Format format{};
    bool failed{};
    std::array<Target, 2> inputs;
    Frame input_frame{};

    // One output per presentation frame. A frame is prepared on the GPU command thread and then
    // presented on the present thread, never both at once, so its output needs no lock.
    std::vector<Target> outputs;
};

bool MetalFxPass::Impl::CreateTarget(Target& target, vk::Extent2D size, vk::Format format,
                                     vk::ImageUsageFlags usage, MTLPixelFormat pixel_format) {
    target.size = size;
    target.format = format;
    const vk::ExternalMemoryImageCreateInfo external_info{
        .handleTypes = vk::ExternalMemoryHandleTypeFlagBits::eMtlheapEXT,
    };
    target.image = Check<"create MetalFX image">(device.createImage({
        .pNext = &external_info,
        .imageType = vk::ImageType::e2D,
        .format = format,
        .extent = {size.width, size.height, 1},
        .mipLevels = 1,
        .arrayLayers = 1,
        .samples = vk::SampleCountFlagBits::e1,
        .tiling = vk::ImageTiling::eOptimal,
        .usage = usage,
        .initialLayout = vk::ImageLayout::eUndefined,
    }));

    const auto requirements = device.getImageMemoryRequirements(target.image);
    const auto& memory_properties = instance->GetMemoryProperties();
    std::optional<u32> memory_type;
    for (u32 i = 0; i < memory_properties.memoryTypeCount; ++i) {
        if ((requirements.memoryTypeBits & (1U << i)) &&
            (memory_properties.memoryTypes[i].propertyFlags &
             vk::MemoryPropertyFlagBits::eDeviceLocal)) {
            memory_type = i;
            break;
        }
    }
    if (!memory_type) {
        LOG_ERROR(Render_Vulkan, "MetalFX: no device local memory type for the scaler images");
        return false;
    }

    const vk::MemoryDedicatedAllocateInfo dedicated_info{
        .image = target.image,
    };
    const vk::ExportMemoryAllocateInfo export_info{
        .pNext = &dedicated_info,
        .handleTypes = vk::ExternalMemoryHandleTypeFlagBits::eMtlheapEXT,
    };
    target.memory = Check<"allocate MetalFX memory">(device.allocateMemory({
        .pNext = &export_info,
        .allocationSize = requirements.size,
        .memoryTypeIndex = *memory_type,
    }));
    Check<"bind MetalFX memory">(device.bindImageMemory(target.image, target.memory, 0));

    const VkMemoryGetMetalHandleInfoEXT handle_info{
        .sType = VK_STRUCTURE_TYPE_MEMORY_GET_METAL_HANDLE_INFO_EXT,
        .memory = target.memory,
        .handleType = VK_EXTERNAL_MEMORY_HANDLE_TYPE_MTLHEAP_BIT_EXT,
    };
    void* handle{};
    if (get_metal_handle(device, &handle_info, &handle) != VK_SUCCESS || handle == nullptr) {
        LOG_ERROR(Render_Vulkan, "MetalFX: the driver did not export the MTLHeap of an image");
        return false;
    }

    id<MTLHeap> heap = static_cast<id<MTLHeap>>(handle);
    MTLTextureDescriptor* descriptor = [[MTLTextureDescriptor alloc] init];
    descriptor.textureType = MTLTextureType2D;
    descriptor.pixelFormat = pixel_format;
    descriptor.width = size.width;
    descriptor.height = size.height;
    descriptor.depth = 1;
    descriptor.mipmapLevelCount = 1;
    descriptor.sampleCount = 1;
    descriptor.arrayLength = 1;
    descriptor.allowGPUOptimizedContents = YES;
    descriptor.usage = TEXTURE_USAGE;
    descriptor.resourceOptions = heap.resourceOptions;
    target.texture = [heap newTextureWithDescriptor:descriptor offset:0];
    [descriptor release];
    if (target.texture == nil) {
        LOG_ERROR(Render_Vulkan, "MetalFX: could not place a texture in the exported MTLHeap");
        return false;
    }

    target.view = Check<"create MetalFX image view">(device.createImageView({
        .image = target.image,
        .viewType = vk::ImageViewType::e2D,
        .format = format,
        .subresourceRange = COLOR_RANGE,
    }));
    SetObjectName(device, target.image, "MetalFX {}x{}", size.width, size.height);
    return true;
}

void MetalFxPass::Impl::DestroyTarget(Target& target) {
    [target.texture release];
    target.texture = nil;
    if (target.view) {
        device.destroyImageView(target.view);
        target.view = nullptr;
    }
    if (target.image) {
        device.destroyImage(target.image);
        target.image = nullptr;
    }
    if (target.memory) {
        device.freeMemory(target.memory);
        target.memory = nullptr;
    }
    target.size = {};
    target.format = {};
}

vk::Result MetalFxPass::Impl::WaitDone(u64 value, u64 timeout_ns) {
    const vk::Semaphore semaphore = *done;
    const vk::SemaphoreWaitInfo wait_info{
        .semaphoreCount = 1,
        .pSemaphores = &semaphore,
        .pValues = &value,
    };
    return device.waitSemaphores(wait_info, timeout_ns);
}

void MetalFxPass::Impl::Encode(id<MTLFXSpatialScaler> encode_scaler, id<MTLTexture> input,
                               id<MTLTexture> output, vk::Extent2D size, u64 value) {
    @autoreleasepool {
        id<MTLCommandBuffer> command_buffer = [queue commandBuffer];
        encode_scaler.colorTexture = input;
        encode_scaler.outputTexture = output;
        encode_scaler.inputContentWidth = size.width;
        encode_scaler.inputContentHeight = size.height;
        [encode_scaler encodeToCommandBuffer:command_buffer];

        const vk::Device signal_device = device;
        const vk::Semaphore semaphore = *done;
        [command_buffer addCompletedHandler:^(id<MTLCommandBuffer> buffer) {
          if (buffer.error != nil) {
              LOG_ERROR(Render_Vulkan, "MetalFX command buffer failed: {}",
                        buffer.error.localizedDescription.UTF8String);
          }
          Check<"signal the MetalFX semaphore">(signal_device.signalSemaphore({
              .semaphore = semaphore,
              .value = value,
          }));
        }];
        [command_buffer commit];
    }
    [encode_scaler release];
    [input release];
    [output release];
}

MetalFxPass::MetalFxPass() : impl{std::make_unique<Impl>()} {}

MetalFxPass::~MetalFxPass() {
    if (!impl->supported) {
        return;
    }
    if (impl->WaitDone(impl->serial, 2'000'000'000) != vk::Result::eSuccess) {
        LOG_ERROR(Render_Vulkan, "MetalFX: scaler work did not finish before shutdown");
    }
    [impl->scaler release];
    for (auto& input : impl->inputs) {
        impl->DestroyTarget(input);
    }
    for (auto& output : impl->outputs) {
        impl->DestroyTarget(output);
    }
    [impl->queue release];
}

void MetalFxPass::Create(const Instance& instance, u32 num_frames) {
    auto& s = *impl;
    s.instance = &instance;
    s.device = instance.GetDevice();
    s.outputs.resize(num_frames);
    s.get_metal_handle = reinterpret_cast<PFN_vkGetMemoryMetalHandleEXT>(
        s.device.getProcAddr("vkGetMemoryMetalHandleEXT"));

    id<MTLDevice> mtl_device = MTLCreateSystemDefaultDevice();
    s.supported = instance.IsExternalMemoryMetalSupported() && s.get_metal_handle != nullptr &&
                  mtl_device != nil && [MTLFXSpatialScalerDescriptor supportsDevice:mtl_device];
    if (s.supported) {
        s.queue = [mtl_device newCommandQueue];
        const vk::SemaphoreTypeCreateInfo type_info{
            .semaphoreType = vk::SemaphoreType::eTimeline,
            .initialValue = 0,
        };
        s.done = Check<"create the MetalFX semaphore">(
            s.device.createSemaphoreUnique({.pNext = &type_info}));
    }
    [mtl_device release];
    LOG_INFO(Render_Vulkan, "MetalFX spatial scaler {}", s.supported ? "available" : "unavailable");
}

bool MetalFxPass::IsSupported() const {
    return impl->supported;
}

Frame* MetalFxPass::BeginInput(Scheduler& scheduler, const Settings& settings,
                               vk::Extent2D input_size, const Frame& output, vk::Format format) {
    auto& s = *impl;
    const vk::Extent2D output_size{output.width, output.height};
    const auto pixel_format = ToMetalFormat(format);
    if (!settings.enable || !s.supported || !pixel_format || output.id >= s.outputs.size() ||
        output_size.width < input_size.width || output_size.height < input_size.height ||
        output_size == input_size || IsSwitchedOff()) {
        return nullptr;
    }

    auto& out = s.outputs[output.id];
    const bool scaler_changed =
        input_size != s.input_size || output_size != s.output_size || format != s.format;
    const bool output_changed = out.size != output_size || out.format != format;
    if (scaler_changed || output_changed) {
        // Scaler work still in flight reads the old inputs and writes the old outputs.
        scheduler.Finish();
        if (s.WaitDone(s.serial, std::numeric_limits<u64>::max()) != vk::Result::eSuccess) {
            return nullptr;
        }
    }
    if (scaler_changed) {
        [s.scaler release];
        s.scaler = nil;
        for (auto& input : s.inputs) {
            s.DestroyTarget(input);
        }
        s.input_size = input_size;
        s.output_size = output_size;
        s.format = format;
        s.failed = false;

        MTLFXSpatialScalerDescriptor* descriptor = [[MTLFXSpatialScalerDescriptor alloc] init];
        descriptor.inputWidth = input_size.width;
        descriptor.inputHeight = input_size.height;
        descriptor.outputWidth = output_size.width;
        descriptor.outputHeight = output_size.height;
        descriptor.colorTextureFormat = *pixel_format;
        descriptor.outputTextureFormat = *pixel_format;
        descriptor.colorProcessingMode = MTLFXSpatialScalerColorProcessingModePerceptual;
        id<MTLDevice> mtl_device = MTLCreateSystemDefaultDevice();
        s.scaler = [descriptor newSpatialScalerWithDevice:mtl_device];
        [mtl_device release];
        [descriptor release];
        s.failed = s.scaler == nil ||
                   ((s.scaler.colorTextureUsage | s.scaler.outputTextureUsage) & ~TEXTURE_USAGE);
        for (auto& input : s.inputs) {
            s.failed =
                s.failed || !s.CreateTarget(input, input_size, format, INPUT_USAGE, *pixel_format);
        }
        if (s.failed) {
            LOG_WARNING(Render_Vulkan, "MetalFX: scaling {}x{} to {}x{} as {} is not available",
                        input_size.width, input_size.height, output_size.width, output_size.height,
                        vk::to_string(format));
        } else {
            LOG_INFO(Render_Vulkan, "MetalFX spatial scaler: {}x{} -> {}x{}, {}", input_size.width,
                     input_size.height, output_size.width, output_size.height,
                     vk::to_string(format));
        }
        const std::array to_general{
            vk::ImageMemoryBarrier2{
                .dstStageMask = vk::PipelineStageFlagBits2::eAllCommands,
                .oldLayout = vk::ImageLayout::eUndefined,
                .newLayout = vk::ImageLayout::eGeneral,
                .image = s.inputs[0].image,
                .subresourceRange = COLOR_RANGE,
            },
            vk::ImageMemoryBarrier2{
                .dstStageMask = vk::PipelineStageFlagBits2::eAllCommands,
                .oldLayout = vk::ImageLayout::eUndefined,
                .newLayout = vk::ImageLayout::eGeneral,
                .image = s.inputs[1].image,
                .subresourceRange = COLOR_RANGE,
            },
        };
        if (!s.failed) {
            scheduler.CommandBuffer().pipelineBarrier2({
                .imageMemoryBarrierCount = static_cast<u32>(to_general.size()),
                .pImageMemoryBarriers = to_general.data(),
            });
        }
    }
    if (s.failed) {
        return nullptr;
    }
    if (output_changed) {
        s.DestroyTarget(out);
        if (!s.CreateTarget(out, output_size, format, OUTPUT_USAGE, *pixel_format)) {
            s.DestroyTarget(out);
            return nullptr;
        }
        const vk::ImageMemoryBarrier2 to_general{
            .dstStageMask = vk::PipelineStageFlagBits2::eAllCommands,
            .oldLayout = vk::ImageLayout::eUndefined,
            .newLayout = vk::ImageLayout::eGeneral,
            .image = out.image,
            .subresourceRange = COLOR_RANGE,
        };
        scheduler.CommandBuffer().pipelineBarrier2({
            .imageMemoryBarrierCount = 1,
            .pImageMemoryBarriers = &to_general,
        });
    }

    const auto& input = s.inputs[(s.serial + 1) % s.inputs.size()];
    const vk::ImageMemoryBarrier2 to_attachment{
        .dstStageMask = vk::PipelineStageFlagBits2::eColorAttachmentOutput,
        .dstAccessMask = vk::AccessFlagBits2::eColorAttachmentWrite,
        .oldLayout = vk::ImageLayout::eGeneral,
        .newLayout = vk::ImageLayout::eColorAttachmentOptimal,
        .image = input.image,
        .subresourceRange = COLOR_RANGE,
    };
    scheduler.CommandBuffer().pipelineBarrier2({
        .imageMemoryBarrierCount = 1,
        .pImageMemoryBarriers = &to_attachment,
    });
    s.input_frame.width = input_size.width;
    s.input_frame.height = input_size.height;
    s.input_frame.image = input.image;
    s.input_frame.image_view = input.view;
    return &s.input_frame;
}

u64 MetalFxPass::Scale(Scheduler& scheduler, const Frame& output) {
    auto& s = *impl;
    const u64 value = ++s.serial;
    const auto& input = s.inputs[value % s.inputs.size()];
    const auto& out = s.outputs[output.id];

    // The previous scaler that read this input has finished long before in practice; the wait
    // keeps the reuse ordered without pausing the queue.
    SubmitInfo input_info{};
    if (value > s.inputs.size()) {
        input_info.AddWait(*s.done, value - s.inputs.size());
    }
    id<MTLFXSpatialScaler> encode_scaler = [s.scaler retain];
    id<MTLTexture> input_texture = [input.texture retain];
    id<MTLTexture> output_texture = [out.texture retain];
    const vk::Extent2D input_size = s.input_size;
    scheduler.DeferPriorityOperation(
        [&s, encode_scaler, input_texture, output_texture, input_size, value] {
            s.Encode(encode_scaler, input_texture, output_texture, input_size, value);
        });
    scheduler.Flush(input_info);
    return value;
}

void MetalFxPass::CopyOutput(vk::CommandBuffer cmdbuf, Frame& frame, SubmitInfo& info) {
    auto& s = *impl;
    const u64 value = std::exchange(frame.metalfx_value, 0);
    if (value == 0 || frame.id >= s.outputs.size()) {
        return;
    }
    // Waiting here on the host keeps the queue from ever waiting for the scaler.
    if (s.WaitDone(value, std::numeric_limits<u64>::max()) != vk::Result::eSuccess) {
        return;
    }
    const auto& out = s.outputs[frame.id];
    const vk::ImageMemoryBarrier2 to_transfer{
        .dstStageMask = vk::PipelineStageFlagBits2::eCopy,
        .dstAccessMask = vk::AccessFlagBits2::eTransferWrite,
        .oldLayout = vk::ImageLayout::eUndefined,
        .newLayout = vk::ImageLayout::eTransferDstOptimal,
        .image = frame.image,
        .subresourceRange = COLOR_RANGE,
    };
    cmdbuf.pipelineBarrier2({
        .imageMemoryBarrierCount = 1,
        .pImageMemoryBarriers = &to_transfer,
    });
    cmdbuf.copyImage(out.image, vk::ImageLayout::eGeneral, frame.image,
                     vk::ImageLayout::eTransferDstOptimal,
                     vk::ImageCopy{
                         .srcSubresource = COLOR_LAYERS,
                         .dstSubresource = COLOR_LAYERS,
                         .extent = {out.size.width, out.size.height, 1},
                     });
    const vk::ImageMemoryBarrier2 to_general{
        .srcStageMask = vk::PipelineStageFlagBits2::eCopy,
        .srcAccessMask = vk::AccessFlagBits2::eTransferWrite,
        .dstStageMask = vk::PipelineStageFlagBits2::eFragmentShader,
        .dstAccessMask = vk::AccessFlagBits2::eShaderRead,
        .oldLayout = vk::ImageLayout::eTransferDstOptimal,
        .newLayout = vk::ImageLayout::eGeneral,
        .image = frame.image,
        .subresourceRange = COLOR_RANGE,
    };
    cmdbuf.pipelineBarrier2({
        .imageMemoryBarrierCount = 1,
        .pImageMemoryBarriers = &to_general,
    });
    info.AddWait(*s.done, value);
}

} // namespace Vulkan::HostPasses
