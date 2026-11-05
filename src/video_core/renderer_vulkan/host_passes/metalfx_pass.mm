//  SPDX-FileCopyrightText: Copyright 2026 shadPS4 Emulator Project
//  SPDX-License-Identifier: GPL-2.0-or-later

#define VK_USE_PLATFORM_METAL_EXT

#include <Metal/Metal.h>
#include <MetalFX/MetalFX.h>

#include <chrono>
#include <cstdlib>
#include <filesystem>
#include <limits>
#include <optional>

#include "common/logging/log.h"
#include "video_core/renderer_vulkan/host_passes/metalfx_pass.h"
#include "video_core/renderer_vulkan/vk_instance.h"
#include "video_core/renderer_vulkan/vk_platform.h"
#include "video_core/renderer_vulkan/vk_presenter.h"
#include "video_core/renderer_vulkan/vk_scheduler.h"

namespace Vulkan::HostPasses {

namespace {

// KosmicKrisp creates the Metal texture of both images with this usage, and the aliasing texture
// must use the same descriptor to share the layout.
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
    };

    bool CreateTarget(Target& target, vk::Extent2D size, vk::ImageUsageFlags usage,
                      MTLPixelFormat pixel_format);
    void DestroyTarget(Target& target);
    bool CreateResources(MTLPixelFormat pixel_format);
    void DestroyResources();
    vk::Result WaitIdle(u64 timeout_ns);
    void Encode(u64 value);

    const Instance* instance{};
    vk::Device device;
    PFN_vkGetMemoryMetalHandleEXT get_metal_handle{};
    bool supported{};

    id<MTLCommandQueue> queue{};
    id<MTLFXSpatialScaler> scaler{};
    vk::UniqueSemaphore done;
    u64 serial{};

    vk::Format format{};
    vk::Extent2D input_size{};
    vk::Extent2D output_size{};
    bool failed{};
    Target input;
    Target output;
    Frame input_frame{};
};

bool MetalFxPass::Impl::CreateTarget(Target& target, vk::Extent2D size, vk::ImageUsageFlags usage,
                                     MTLPixelFormat pixel_format) {
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
}

bool MetalFxPass::Impl::CreateResources(MTLPixelFormat pixel_format) {
    if (!CreateTarget(input, input_size, INPUT_USAGE, pixel_format) ||
        !CreateTarget(output, output_size, OUTPUT_USAGE, pixel_format)) {
        return false;
    }

    MTLFXSpatialScalerDescriptor* descriptor = [[MTLFXSpatialScalerDescriptor alloc] init];
    descriptor.inputWidth = input_size.width;
    descriptor.inputHeight = input_size.height;
    descriptor.outputWidth = output_size.width;
    descriptor.outputHeight = output_size.height;
    descriptor.colorTextureFormat = pixel_format;
    descriptor.outputTextureFormat = pixel_format;
    descriptor.colorProcessingMode = MTLFXSpatialScalerColorProcessingModePerceptual;
    scaler = [descriptor newSpatialScalerWithDevice:input.texture.device];
    [descriptor release];
    if (scaler == nil) {
        LOG_ERROR(Render_Vulkan, "MetalFX: could not create the spatial scaler");
        return false;
    }
    if ((scaler.colorTextureUsage | scaler.outputTextureUsage) & ~TEXTURE_USAGE) {
        LOG_ERROR(Render_Vulkan, "MetalFX: the scaler needs texture usage {:#x}",
                  static_cast<u64>(scaler.colorTextureUsage | scaler.outputTextureUsage));
        return false;
    }

    input_frame.width = input_size.width;
    input_frame.height = input_size.height;
    input_frame.image = input.image;
    input_frame.image_view = input.view;
    LOG_INFO(Render_Vulkan, "MetalFX spatial scaler: {}x{} -> {}x{}, {}", input_size.width,
             input_size.height, output_size.width, output_size.height, vk::to_string(format));
    return true;
}

void MetalFxPass::Impl::DestroyResources() {
    [scaler release];
    scaler = nil;
    DestroyTarget(input);
    DestroyTarget(output);
}

vk::Result MetalFxPass::Impl::WaitIdle(u64 timeout_ns) {
    const vk::Semaphore semaphore = *done;
    const vk::SemaphoreWaitInfo wait_info{
        .semaphoreCount = 1,
        .pSemaphores = &semaphore,
        .pValues = &serial,
    };
    return device.waitSemaphores(wait_info, timeout_ns);
}

void MetalFxPass::Impl::Encode(u64 value) {
    @autoreleasepool {
        id<MTLCommandBuffer> command_buffer = [queue commandBuffer];
        scaler.colorTexture = input.texture;
        scaler.outputTexture = output.texture;
        scaler.inputContentWidth = input_size.width;
        scaler.inputContentHeight = input_size.height;
        [scaler encodeToCommandBuffer:command_buffer];

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
}

MetalFxPass::MetalFxPass() : impl{std::make_unique<Impl>()} {}

MetalFxPass::~MetalFxPass() {
    if (!impl->supported) {
        return;
    }
    if (impl->WaitIdle(2'000'000'000) != vk::Result::eSuccess) {
        LOG_ERROR(Render_Vulkan, "MetalFX: scaler work did not finish before shutdown");
    }
    impl->DestroyResources();
    [impl->queue release];
}

void MetalFxPass::Create(const Instance& instance) {
    auto& s = *impl;
    s.instance = &instance;
    s.device = instance.GetDevice();
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
    if (!settings.enable || !s.supported || output_size.width < input_size.width ||
        output_size.height < input_size.height || output_size == input_size || IsSwitchedOff()) {
        return nullptr;
    }

    if (input_size != s.input_size || output_size != s.output_size || format != s.format) {
        scheduler.Finish();
        if (s.WaitIdle(std::numeric_limits<u64>::max()) != vk::Result::eSuccess) {
            return nullptr;
        }
        s.DestroyResources();
        s.input_size = input_size;
        s.output_size = output_size;
        s.format = format;
        const auto pixel_format = ToMetalFormat(format);
        s.failed = !pixel_format || !s.CreateResources(*pixel_format);
        if (s.failed) {
            LOG_WARNING(Render_Vulkan, "MetalFX: scaling {}x{} to {}x{} as {} is not available",
                        input_size.width, input_size.height, output_size.width, output_size.height,
                        vk::to_string(format));
            s.DestroyResources();
            return nullptr;
        }
        const std::array to_general{
            vk::ImageMemoryBarrier2{
                .dstStageMask = vk::PipelineStageFlagBits2::eAllCommands,
                .oldLayout = vk::ImageLayout::eUndefined,
                .newLayout = vk::ImageLayout::eGeneral,
                .image = s.input.image,
                .subresourceRange = COLOR_RANGE,
            },
            vk::ImageMemoryBarrier2{
                .dstStageMask = vk::PipelineStageFlagBits2::eAllCommands,
                .oldLayout = vk::ImageLayout::eUndefined,
                .newLayout = vk::ImageLayout::eGeneral,
                .image = s.output.image,
                .subresourceRange = COLOR_RANGE,
            },
        };
        scheduler.CommandBuffer().pipelineBarrier2({
            .imageMemoryBarrierCount = static_cast<u32>(to_general.size()),
            .pImageMemoryBarriers = to_general.data(),
        });
    }
    if (s.failed) {
        return nullptr;
    }

    const vk::ImageMemoryBarrier2 to_attachment{
        .dstStageMask = vk::PipelineStageFlagBits2::eColorAttachmentOutput,
        .dstAccessMask = vk::AccessFlagBits2::eColorAttachmentWrite,
        .oldLayout = vk::ImageLayout::eGeneral,
        .newLayout = vk::ImageLayout::eColorAttachmentOptimal,
        .image = s.input.image,
        .subresourceRange = COLOR_RANGE,
    };
    scheduler.CommandBuffer().pipelineBarrier2({
        .imageMemoryBarrierCount = 1,
        .pImageMemoryBarriers = &to_attachment,
    });
    return &s.input_frame;
}

u64 MetalFxPass::Scale(Scheduler& scheduler, const Frame& output) {
    auto& s = *impl;
    SubmitInfo input_info{};
    if (s.serial > 0) {
        input_info.AddWait(*s.done, s.serial);
    }
    const u64 value = ++s.serial;
    scheduler.DeferPriorityOperation([&s, value] { s.Encode(value); });
    scheduler.Flush(input_info);

    const auto cmdbuf = scheduler.CommandBuffer();
    const vk::ImageMemoryBarrier2 to_transfer{
        .dstStageMask = vk::PipelineStageFlagBits2::eCopy,
        .dstAccessMask = vk::AccessFlagBits2::eTransferWrite,
        .oldLayout = vk::ImageLayout::eUndefined,
        .newLayout = vk::ImageLayout::eTransferDstOptimal,
        .image = output.image,
        .subresourceRange = COLOR_RANGE,
    };
    cmdbuf.pipelineBarrier2({
        .imageMemoryBarrierCount = 1,
        .pImageMemoryBarriers = &to_transfer,
    });
    cmdbuf.copyImage(s.output.image, vk::ImageLayout::eGeneral, output.image,
                     vk::ImageLayout::eTransferDstOptimal,
                     vk::ImageCopy{
                         .srcSubresource = COLOR_LAYERS,
                         .dstSubresource = COLOR_LAYERS,
                         .extent = {s.output_size.width, s.output_size.height, 1},
                     });
    const vk::ImageMemoryBarrier2 to_present{
        .srcStageMask = vk::PipelineStageFlagBits2::eCopy,
        .srcAccessMask = vk::AccessFlagBits2::eTransferWrite,
        .dstStageMask = vk::PipelineStageFlagBits2::eFragmentShader,
        .dstAccessMask = vk::AccessFlagBits2::eShaderRead,
        .oldLayout = vk::ImageLayout::eTransferDstOptimal,
        .newLayout = vk::ImageLayout::eGeneral,
        .image = output.image,
        .subresourceRange = COLOR_RANGE,
    };
    cmdbuf.pipelineBarrier2({
        .imageMemoryBarrierCount = 1,
        .pImageMemoryBarriers = &to_present,
    });
    return value;
}

vk::Semaphore MetalFxPass::DoneSemaphore() const {
    return *impl->done;
}

} // namespace Vulkan::HostPasses
