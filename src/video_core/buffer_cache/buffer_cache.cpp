// SPDX-FileCopyrightText: Copyright 2024 shadPS4 Emulator Project
// SPDX-License-Identifier: GPL-2.0-or-later

#include <algorithm>
#include <chrono>
#include <filesystem>
#include <magic_enum/magic_enum.hpp>
#include <xxhash.h>

#include "common/alignment.h"
#include "core/debug_state.h"
#include "core/memory.h"
#include "video_core/amdgpu/liverpool.h"
#include "video_core/buffer_cache/buffer.h"
#include "video_core/buffer_cache/buffer_cache.h"
#include "video_core/buffer_cache/memory_tracker.h"
#include "video_core/buffer_cache/region_definitions.h"
#include "video_core/renderer_vulkan/vk_graphics_pipeline.h"
#include "video_core/renderer_vulkan/vk_instance.h"
#include "video_core/renderer_vulkan/vk_runtime.h"
#include "video_core/renderer_vulkan/vk_scheduler.h"
#include "video_core/texture_cache/texture_cache.h"

#include <vk_mem_alloc.h>

namespace VideoCore {

namespace {

/// A/B switch file for diagnostics, named by an environment variable. Hot paths ask per fault or
/// per upload, so the file is looked at no more than twice a second (a stat costs microseconds
/// under Rosetta, and counting calls still cost 4% of the GPU thread on a per-binding path).
class SwitchFile {
public:
    explicit SwitchFile(const char* env) : path{std::getenv(env)} {}

    bool Exists() {
        if (path == nullptr || path[0] == '\0') {
            return false;
        }
        const s64 now = std::chrono::steady_clock::now().time_since_epoch().count();
        s64 next = next_check.load(std::memory_order_relaxed);
        if (now >= next && next_check.compare_exchange_strong(
                               next, now + 500'000'000, std::memory_order_relaxed)) {
            std::error_code ec;
            exists.store(std::filesystem::exists(path, ec), std::memory_order_relaxed);
        }
        return exists.load(std::memory_order_relaxed);
    }

private:
    const char* path;
    std::atomic<s64> next_check{};
    std::atomic<bool> exists{};
};

} // Anonymous namespace

static constexpr size_t GDS_BUFFER_SIZE = 64_KB;
static constexpr size_t NULL_INDEX_BUFFER_SIZE = 16;
static constexpr size_t STREAM_BUFFER_SIZE = 128_MB;
constexpr std::optional<u32> CmaskColorExpandedValue(u32 num_samples) {
    switch (num_samples) {
    case 1:
        return 0xFFFFFFFF;
    case 2:
        return 0xDDDDDDDD;
    case 4:
        return 0xEEEEEEEE;
    case 8:
        return 0xFFFFFFFF;
    default:
        return 0;
    }
}
static_assert(CmaskColorExpandedValue(1) == 0xFFFFFFFF);
static_assert(CmaskColorExpandedValue(2) == 0xDDDDDDDD);
static_assert(CmaskColorExpandedValue(4) == 0xEEEEEEEE);
static_assert(CmaskColorExpandedValue(8) == 0xFFFFFFFF);

static constexpr auto ARENA_USAGE =
    vk::BufferUsageFlagBits::eTransferSrc | vk::BufferUsageFlagBits::eTransferDst |
    vk::BufferUsageFlagBits::eUniformBuffer | vk::BufferUsageFlagBits::eStorageBuffer |
    vk::BufferUsageFlagBits::eIndexBuffer | vk::BufferUsageFlagBits::eVertexBuffer |
    vk::BufferUsageFlagBits::eIndirectBuffer | vk::BufferUsageFlagBits::eShaderDeviceAddress;

std::optional<u32> FindMemoryType(const vk::PhysicalDeviceMemoryProperties& properties,
                                  vk::MemoryPropertyFlags wanted, u32 memory_type_bits) {
    for (u32 i = 0; i < properties.memoryTypeCount; ++i) {
        if (((memory_type_bits >> i) & 1) == 0) {
            continue;
        }
        const auto flags = properties.memoryTypes[i].propertyFlags;
        if ((flags & wanted) == wanted) {
            return i;
        }
    }
    return std::nullopt;
}

BufferCache::BufferCache(const Vulkan::Instance& instance_, Vulkan::Scheduler& scheduler_,
                         Vulkan::Runtime& runtime_, AmdGpu::Liverpool* liverpool_,
                         TextureCache& texture_cache_, PageManager& tracker)
    : instance{instance_}, scheduler{scheduler_}, runtime{runtime_},
      staging_pool{runtime_.GetStagingPool()}, liverpool{liverpool_},
      memory{Core::Memory::Instance()}, texture_cache{texture_cache_},
      memory_tracker{std::make_unique<MemoryTracker>(tracker)},
      stream_buffer{instance, scheduler, MemoryType::Stream, STREAM_BUFFER_SIZE},
      gds_buffer{instance, 0, GDS_BUFFER_SIZE, MemoryType::Stream, "GDS Buffer"},
      memory_semaphore{instance} {
    const vk::BufferCreateInfo probe_ci = {
        .flags =
            vk::BufferCreateFlagBits::eSparseBinding | vk::BufferCreateFlagBits::eSparseResidency,
        .size = ARENA_PAGE_SIZE,
        .usage = SupportedUsage(instance, ARENA_USAGE),
        .sharingMode = vk::SharingMode::eExclusive,
    };
    const vk::DeviceBufferMemoryRequirements req_info = {
        .pCreateInfo = &probe_ci,
    };
    const auto device = instance.GetDevice();
    const auto reqs = device.getBufferMemoryRequirements(req_info).memoryRequirements;
    block_size = Common::AlignUp(std::max<u64>(reqs.alignment, MIN_BLOCK_SIZE), reqs.alignment);
    ASSERT_MSG(std::popcount(block_size) == 1, "Sparse block size {} is not a power of 2",
               block_size);
    block_shift = std::bit_width(block_size) - 1;
    blocks_per_arena_page = ARENA_PAGE_SIZE / block_size;
    blocks_per_arena_page_shift = ARENA_PAGE_BITS - block_shift;
    arena_memory_type_index =
        FindMemoryType(instance.GetMemoryProperties(), vk::MemoryPropertyFlagBits::eDeviceLocal,
                       reqs.memoryTypeBits)
            .value();
    const auto& memory_properties = instance.GetMemoryProperties();
    for (u32 i = 0; i < memory_properties.memoryTypeCount; ++i) {
        LOG_INFO(Render_Vulkan, "Memory type {}: heap {} {}{}", i,
                 memory_properties.memoryTypes[i].heapIndex,
                 vk::to_string(memory_properties.memoryTypes[i].propertyFlags),
                 ((reqs.memoryTypeBits >> i) & 1) ? " (sparse arena capable)" : "");
    }
    // SHADPS4_DIRECT_DOWNLOAD=1 backs the arena with host-visible memory so readbacks can copy
    // finished GPU writes directly instead of draining the whole queue.
    if (const char* value = std::getenv("SHADPS4_DIRECT_DOWNLOAD");
        value != nullptr && value[0] == '1') {
        constexpr auto host_flags = vk::MemoryPropertyFlagBits::eDeviceLocal |
                                    vk::MemoryPropertyFlagBits::eHostVisible |
                                    vk::MemoryPropertyFlagBits::eHostCoherent;
        if (const auto index =
                FindMemoryType(memory_properties, host_flags, reqs.memoryTypeBits)) {
            arena_memory_type_index = *index;
            direct_downloads = true;
        } else {
            LOG_WARNING(Render_Vulkan, "No host-visible memory type can back the sparse arena");
        }
    }
    LOG_INFO(Render_Vulkan, "Buffer arena: memory type {}, block size {:#x}, direct downloads {}",
             arena_memory_type_index, block_size, direct_downloads);
    if (const char* value = std::getenv("SHADPS4_FAULT_EXPAND"); value != nullptr && value[0] == '1') {
        expand_faults = true;
    }
    if (const char* value = std::getenv("SHADPS4_DEFER_UPLOADS"); value != nullptr && value[0] == '1') {
        defer_uploads = true;
    }
    LOG_INFO(Render_Vulkan, "Uploads before the session when possible: {}", defer_uploads);
    LOG_INFO(Render_Vulkan, "Hot block release on write faults: {}", expand_faults);

    const u64 bda_pagetable_size =
        (blocks_per_arena_page * NUM_ARENA_PAGES) * sizeof(vk::DeviceAddress);
    fault_manager = std::make_unique<FaultManager>(instance, scheduler, *this, block_shift,
                                                   blocks_per_arena_page * NUM_ARENA_PAGES);
    runtime.FillBuffer(fault_manager->GetFaultBuffer(), 0u,
                       fault_manager->GetFaultBuffer()->SizeBytes(), 0u);
    bda_pagetable_buffer = std::make_unique<Buffer>(
        instance, 0, bda_pagetable_size, MemoryType::DeviceLocal, "BDA Page Table Buffer");
    runtime.FillBuffer(bda_pagetable_buffer.get(), 0u, bda_pagetable_size, 0u);
    if (!instance.IsMaintenance6Supported()) {
        null_index_buffer = std::make_unique<Buffer>(instance, 0, NULL_INDEX_BUFFER_SIZE,
                                                     MemoryType::DeviceLocal, "Null Index Buffer");
        runtime.FillBuffer(null_index_buffer.get(), 0u, NULL_INDEX_BUFFER_SIZE, 0u);
    }
}

BufferCache::~BufferCache() = default;

void BufferCache::TickFrame() {
    if (std::exchange(fault_process_pending, false)) {
        fault_manager->ProcessFaultBuffer();
    }
}

void BufferCache::InvalidateMemory(VAddr device_addr, u64 size, bool assume_locks) {
    memory_tracker->InvalidateRegion(device_addr, size, [this, device_addr, size, assume_locks] {
        ReadMemory(device_addr, size, true, false, assume_locks);
    });
    if (expand_faults) {
        ReleaseHotBlock(device_addr);
    }
}

void BufferCache::ReleaseHotBlock(VAddr device_addr) {
    // Guest code that streams per-frame data (constant rings, instance data) writes every 4 KB page
    // of a block once per frame, and each first write is a fault. Under Rosetta a fault costs tens
    // of microseconds, and FC26 took ~17k of them per second. After a block has faulted a few times
    // in the current epoch, its remaining clean pages are released at once; they are uploaded on
    // their next GPU use, like any CPU-modified page.
    static SwitchFile expand_off{"SHADPS4_FAULT_EXPAND_OFF_FILE"};
    if (expand_off.Exists()) {
        return;
    }
    constexpr u64 BlockBits = 16;
    constexpr u64 Threshold = 3;
    const u64 block = device_addr >> BlockBits;
    const u64 epoch = (DebugState.GetFrameNum() >> 3) & 0xffff;
    auto& slot = hot_blocks[(block ^ (block >> 12)) & (HotBlockSlots - 1)];
    u64 value = slot.load(std::memory_order_relaxed);
    u64 count;
    for (;;) {
        const bool same = (value >> 24) == block && ((value >> 8) & 0xffff) == epoch;
        count = same ? std::min<u64>((value & 0xff) + 1, 0xff) : 1;
        const u64 next = (block << 24) | (epoch << 8) | count;
        if (slot.compare_exchange_weak(value, next, std::memory_order_relaxed)) {
            break;
        }
    }
    if (count != Threshold) {
        return;
    }
    // Only pages that were uploaded (write-protected, clean) are released; pages never used by the
    // GPU are still marked CPU modified and are skipped.
    const VAddr block_addr = block << BlockBits;
    const u64 released = memory_tracker->ReleaseCleanPages(block_addr, u64{1} << BlockBits);
    DebugState.AddPerf(DebugStateType::DebugStateImpl::PerfCounter::ReleasedPages, released);
}

void BufferCache::UnmarkRegionAsGpuModified(VAddr device_addr, u64 size, bool is_write) {
    memory_tracker->UnmarkRegionAsGpuModified(device_addr, size, is_write);
    gpu_modified_ranges.Subtract(device_addr, size);
}

void BufferCache::ReadMemory(VAddr device_addr, u64 size, bool is_write, bool async,
                             bool assume_locks) {
    const auto flush_request = [this, device_addr, size, is_write, async] {
        const u32 first_block = device_addr >> block_shift;
        const u32 last_block = (device_addr + size - 1) >> block_shift;
        const auto* arena = GetArena(first_block, last_block);

        // GPU-modified ranges come as many small scattered islands,
        // so the download is widened to a window around the request
        constexpr u64 WindowSize = 512_KB;
        const VAddr arena_end = arena->cpu_addr + arena->size_bytes;
        const VAddr window_start =
            std::max<VAddr>(Common::AlignDown(device_addr, WindowSize), arena->cpu_addr);
        const VAddr window_end = std::min<VAddr>(
            std::max<VAddr>(window_start + WindowSize, device_addr + size), arena_end);
        DownloadMemory(arena, window_start, window_end - window_start, async);
        if (is_write) {
            memory_tracker->MarkRegionAsCpuModified(device_addr, size);
        }
    };
    if (assume_locks) {
        flush_request();
    } else {
        liverpool->SendCommand<true>(std::move(flush_request));
    }
}

void BufferCache::DownloadMemory(const Buffer* arena, VAddr device_addr, u64 size, bool async) {
    boost::container::small_vector<vk::BufferCopy, 1> copies;
    u64 total_size_bytes = 0;
    const VAddr arena_base = arena->cpu_addr;
    memory_tracker->ForEachDownloadRange<false>(device_addr, size, [&](u64 address, u64 size) {
        const auto add_download = [&](VAddr start, VAddr end) {
            const u64 new_offset = start - arena_base;
            const u64 new_size = end - start;
            copies.push_back(vk::BufferCopy{
                .srcOffset = new_offset,
                .dstOffset = total_size_bytes,
                .size = new_size,
            });
            // Align up to avoid cache conflicts
            constexpr u64 align = 64ULL;
            constexpr u64 mask = ~(align - 1ULL);
            total_size_bytes += (new_size + align - 1) & mask;
        };
        gpu_modified_ranges.ForEachInRange(address, size, add_download);
        gpu_modified_ranges.Subtract(address, size);
    });
    if (total_size_bytes == 0) {
        return;
    }
    DebugState.AddPerf(DebugStateType::DebugStateImpl::PerfCounter::Downloads);
    if (!async && TryDirectDownload(arena_base, copies)) {
        memory_tracker->UnmarkRegionAsGpuModified(device_addr, size, false);
        return;
    }
    const auto download =
        staging_pool.Request(total_size_bytes, VideoCore::MemoryType::HostCached, 16, async);
    for (auto& copy : copies) {
        copy.dstOffset += download.offset;
    }
    runtime.CopyBuffer(arena, download.buffer, copies);

    const auto write_data = [this, arena_base, device_addr, size, download, async,
                             copies = std::move(copies)] {
        download.Invalidate();
        for (const auto& copy : copies) {
            auto* dst_addr = std::bit_cast<u8*>(arena_base + copy.srcOffset);
            memory->TryWriteBacking(dst_addr, download.mapped + (copy.dstOffset - download.offset),
                                    copy.size);
        }
        memory_tracker->UnmarkRegionAsGpuModified(device_addr, size, false);

        if (async) {
            staging_pool.FreeDeferred(download);
        }
    };

    if (async) {
        scheduler.DeferOperation(std::move(write_data));
    } else {
        scheduler.Finish();
        write_data();
    }
}

void BufferCache::MarkBlocksWritten(VAddr addr, u64 size) {
    if (!direct_downloads || size == 0) {
        return;
    }
    const u64 tick = scheduler.CurrentTick();
    const u64 last_block = (addr + size - 1) >> block_shift;
    for (u64 block = addr >> block_shift; block <= last_block; ++block) {
        block_write_ticks[block] = tick;
    }
}

bool BufferCache::TryDirectDownload(VAddr arena_base, std::span<const vk::BufferCopy> copies) {
    if (!direct_downloads) {
        return false;
    }
    // A/B switch: while SHADPS4_DIRECT_DOWNLOAD_OFF_FILE names an existing file, use the queue path.
    static const char* const off_file = std::getenv("SHADPS4_DIRECT_DOWNLOAD_OFF_FILE");
    if (off_file != nullptr && off_file[0] != '\0') {
        std::error_code ec;
        if (std::filesystem::exists(off_file, ec)) {
            return false;
        }
    }
    // Every block must be resident in mapped memory and have a known last writer.
    u64 wait_tick = 0;
    for (const auto& copy : copies) {
        const VAddr start = arena_base + copy.srcOffset;
        const u64 last_block = (start + copy.size - 1) >> block_shift;
        for (u64 block = start >> block_shift; block <= last_block; ++block) {
            const auto tick = block_write_ticks.find(block);
            const auto backing = resident_ranges.Find(block);
            if (tick == block_write_ticks.end() || backing == resident_ranges.end() ||
                backing->mapped == nullptr) {
                return false;
            }
            wait_tick = std::max(wait_tick, tick->second);
        }
    }
    if (scheduler.IsFree(wait_tick)) {
        DebugState.AddPerf(DebugStateType::DebugStateImpl::PerfCounter::DirectDownloadsNoWait);
    } else {
        scheduler.Wait(wait_tick);
    }
    DebugState.AddPerf(DebugStateType::DebugStateImpl::PerfCounter::DirectDownloads);
    for (const auto& copy : copies) {
        VAddr addr = arena_base + copy.srcOffset;
        u64 remaining = copy.size;
        while (remaining != 0) {
            const u64 block = addr >> block_shift;
            const auto backing = resident_ranges.Find(block);
            const u64 in_block = addr & (u64{block_size} - 1);
            const u64 chunk =
                std::min<u64>(remaining, ((backing->end - block) << block_shift) - in_block);
            const u8* src =
                backing->mapped + ((backing->offset + (block - backing->start)) << block_shift) +
                in_block;
            memory->TryWriteBacking(std::bit_cast<u8*>(addr), src, chunk);
            addr += chunk;
            remaining -= chunk;
        }
    }
    return true;
}

std::pair<const Buffer*, u64> BufferCache::ObtainBuffer(VAddr device_addr, u32 size,
                                                        ObtainBufferFlags flags) {
    const bool is_written = True(flags & ObtainBufferFlags::IsWritten);
    const bool is_texel_buffer = True(flags & ObtainBufferFlags::IsTexelBuffer);
    const bool skip_stream_buffer = True(flags & ObtainBufferFlags::IgnoreStreamBuffer);
    // For read-only buffers use device local stream buffer to reduce renderpass breaks.
    if (!is_written && !skip_stream_buffer && size <= STREAM_THRESHOLD &&
        !IsRegionGpuModified(device_addr, size)) {
        const auto [data, offset] = stream_buffer.Map(size, instance.UniformMinAlignment());
        memory->CopySparseMemory(device_addr, data, size);
        stream_buffer.Commit();
        return {&stream_buffer, offset};
    }
    const u64 first_block = device_addr >> block_shift;
    const u64 last_block = (device_addr + size - 1) >> block_shift;
    const auto* arena = GetArena(first_block, last_block);
    EnsureResident(arena, first_block, last_block);
    if (is_written) {
        texture_cache.MarkAsMaybeGpuDirty(device_addr, size);
    }
    if (session_used_serial != scheduler.SessionSerial()) {
        session_used.Clear();
        session_used_serial = scheduler.SessionSerial();
    }
    obtain_caller = __builtin_return_address(0);
    SynchronizeMemory(arena, device_addr, size, defer_uploads, is_written, is_texel_buffer);
    // An unbounded binding spans up to the arena page (tens of MB). Recording only its head lets
    // later uploads in that span run before the session (FC26 replays: ~40 fewer pass splits per
    // frame) but is unsafe when the shader reads past the head: off by default since FC26 showed
    // exploded crowd-card geometry with a 64 KB head. SHADPS4_UNBOUNDED_FOOTPRINT_KB=64 tries it.
    u64 used_size = size;
    if (True(flags & ObtainBufferFlags::LooseFootprint) && !is_written) {
        static const u64 footprint = [] {
            const char* value = std::getenv("SHADPS4_UNBOUNDED_FOOTPRINT_KB");
            return (value != nullptr ? std::strtoull(value, nullptr, 10) : u64{0}) << 10;
        }();
        static SwitchFile footprint_off{"SHADPS4_UNBOUNDED_FOOTPRINT_OFF_FILE"};
        if (footprint != 0 && !footprint_off.Exists()) {
            used_size = std::min<u64>(size, footprint);
        }
    }
    session_used.Add(device_addr, used_size);
    if (is_written) {
        gpu_modified_ranges.Add(device_addr, size);
        MarkBlocksWritten(device_addr, size);
    }
    return {arena, arena->Offset(device_addr)};
}

std::pair<const Buffer*, u64> BufferCache::ObtainBufferForImage(VAddr device_addr, u32 size) {
    if (IsRegionGpuModified(device_addr, size)) {
        return ObtainBuffer(device_addr, size);
    }
    const auto staging = staging_pool.Request(size, VideoCore::MemoryType::HostUncached,
                                              instance.StorageMinAlignment());
    memory->CopySparseMemory(device_addr, staging.mapped, staging.size);
    staging.Flush();
    return {staging.buffer, staging.offset};
}

bool BufferCache::IsRegionCpuModified(VAddr addr, size_t size) {
    return memory_tracker->IsRegionCpuModified(addr, size);
}

bool BufferCache::IsRegionGpuModified(VAddr addr, size_t size) {
    return memory_tracker->IsRegionGpuModified(addr, size);
}

void BufferCache::MarkRegionAsGpuModified(VAddr addr, size_t size) {
    texture_cache.MarkAsMaybeGpuDirty(addr, size);
    memory_tracker->MarkRegionAsGpuModified(addr, size);
    gpu_modified_ranges.Add(addr, size);
}

void BufferCache::ReadEdgeImagePages(const Image& image) {
    // May happen that after downloading the image and invalidating region,
    // that there were GPU modified ranges that are lost due to CPU reuploading.
    // This doesn't change tracker state and it is spected to call DownloadImageMemory after this.
    const VAddr image_addr = image.info.guest_address;
    const u64 image_size = image.info.guest_size;
    const VAddr image_end = image_addr + image_size;
    const VAddr page_start = PageManager::GetPageAddr(image_addr);
    const VAddr page_end = PageManager::GetNextPageAddr(image_end - 1);
    boost::container::small_vector<vk::BufferCopy, 2> copies;
    u64 total_size_bytes = 0;
    const auto [buffer, offset] = ObtainBuffer(page_start, page_end - page_start);
    const auto add_download = [&](VAddr start, VAddr end) {
        const u64 new_offset = start - buffer->CpuAddr();
        const u64 new_size = end - start;
        copies.push_back(vk::BufferCopy{
            .srcOffset = new_offset,
            .dstOffset = total_size_bytes,
            .size = new_size,
        });
        // Align up to avoid cache conflicts
        constexpr u64 align = 64ULL;
        constexpr u64 mask = ~(align - 1ULL);
        total_size_bytes += (new_size + align - 1) & mask;
    };
    gpu_modified_ranges.ForEachInRange(page_start, image_addr - page_start, add_download);
    gpu_modified_ranges.ForEachInRange(image_end, page_end - image_end, add_download);
    gpu_modified_ranges.Subtract(page_start, page_end - page_start);
    if (total_size_bytes == 0) {
        return;
    }
    const auto download =
        staging_pool.Request(total_size_bytes, VideoCore::MemoryType::HostCached, 16, true);
    for (auto& copy : copies) {
        // Modify copies to have the staging offset in mind
        copy.dstOffset += download.offset;
    }
    scheduler.EndRendering();
    runtime.CopyBuffer(buffer, download.buffer, copies);
    scheduler.DeferOperation(
        [this, base = buffer->CpuAddr(), download, copies = std::move(copies)]() {
            download.Invalidate();
            auto* memory = Core::Memory::Instance();
            for (const auto& copy : copies) {
                const VAddr copy_device_addr = base + copy.srcOffset;
                const u64 dst_offset = copy.dstOffset - download.offset;
                memory->TryWriteBacking(std::bit_cast<u8*>(copy_device_addr),
                                        download.mapped + dst_offset, copy.size);
            }
            staging_pool.FreeDeferred(download);
        });
}

void BufferCache::SynchronizeDmaBuffers() {
    fault_process_pending = true;
    for (const auto& range : resident_ranges) {
        const u64 page = range.start >> (ARENA_PAGE_BITS - block_shift);
        const VAddr device_addr = range.start << block_shift;
        const u64 size = (range.end - range.start) << block_shift;
        SynchronizeMemory(address_space[page], device_addr, size, false, false, false);
    }
}

void BufferCache::PreloadDmaSrt(VAddr device_addr) {
    if (device_addr == 0 || !memory->IsValidGpuMapping(device_addr, block_size) ||
        !memory->IsValidMapping(device_addr, block_size)) {
        return;
    }

    // Dynamic SRT indexing is evaluated by the guest shader, so the host walker cannot know the
    // exact descriptor offset. Upload one sparse-page worth of the table from its known root. The
    // normal fault path remains available if a genuinely larger table crosses this window.
    (void)ObtainBuffer(device_addr, block_size, ObtainBufferFlags::IgnoreStreamBuffer);
}

const Buffer* BufferCache::GetArena(u64 first_block, u64 last_block) {
    const u64 first_page = first_block >> blocks_per_arena_page_shift;
    const u64 last_page = last_block >> blocks_per_arena_page_shift;
    ASSERT_MSG(last_page - first_page <= 1,
               "Buffer request cannot span more than two VA arena pages");

    const auto* first_arena = address_space[first_page];
    const auto* last_arena = address_space[last_page];
    if (first_arena == last_arena) {
        if (!first_arena) {
            const u64 base_block = Common::AlignDownPow2<u64>(first_block, blocks_per_arena_page);
            const u64 num_pages = last_page - first_page + 1;
            const auto* new_arena =
                &arenas.emplace_back(instance, base_block << block_shift,
                                     num_pages << ARENA_PAGE_BITS, MemoryType::Sparse);
            address_space[first_page] = new_arena;
            address_space[last_page] = new_arena;
        }
        return address_space[first_page];
    }

    LOG_WARNING(Render, "Migrating arena for blocks {:#x}..{:#x} (VA {:#x}..{:#x})", first_block,
                last_block, first_block << block_shift, (last_block + 1) << block_shift);

    const u64 first_addr = first_arena ? first_arena->cpu_addr : (first_page << ARENA_PAGE_BITS);
    const u64 first_size = first_arena ? first_arena->size_bytes : ARENA_PAGE_SIZE;
    const u64 last_size = last_arena ? last_arena->size_bytes : ARENA_PAGE_SIZE;

    const u64 base_block = first_addr >> block_shift;
    const u64 total_size = first_size + last_size;
    const u64 end_block = (first_addr + total_size) >> block_shift;
    auto* new_arena = &arenas.emplace_back(instance, first_addr, total_size, MemoryType::Sparse);
    auto* bind = BindsForArena(new_arena);
    resident_ranges.ForEachInRange(base_block, end_block, [&](const Backing& backing) {
        const u64 start = std::max(base_block, backing.start);
        const u64 end = std::min(end_block, backing.end);
        bind->binds.push_back(vk::SparseMemoryBind{
            .resourceOffset = (start - base_block) << block_shift,
            .size = (end - start) << block_shift,
            .memory = backing.memory,
            .memoryOffset = (backing.offset + start - backing.start) << block_shift,
        });
    });

    u64 base_page = first_addr >> ARENA_PAGE_BITS;
    for (u32 page = 0; page < (first_size >> ARENA_PAGE_BITS); ++page) {
        address_space[base_page + page] = new_arena;
    }
    base_page = last_page;
    for (u32 page = 0; page < (last_size >> ARENA_PAGE_BITS); ++page) {
        address_space[base_page + page] = new_arena;
    }
    return new_arena;
}

void BufferCache::EnsureResident(const Buffer* arena, u64 first_block, u64 last_block) {
    u32 resident_blocks{};
    IntervalList bind_ranges;
    resident_ranges.ForEachGap(first_block, last_block + 1, [&](u64 start, u64 end) {
        resident_blocks += end - start;
        bind_ranges.Add({start, end});
    });

    if (bind_ranges.Empty()) {
        return;
    }

    const bool has_bda = instance.IsBufferDeviceAddressSupported();
    const vk::MemoryAllocateFlagsInfo alloc_flags = {
        .flags = vk::MemoryAllocateFlagBits::eDeviceAddress,
    };
    const vk::MemoryAllocateInfo alloc_info = {
        .pNext = has_bda ? &alloc_flags : nullptr,
        .allocationSize = resident_blocks << block_shift,
        .memoryTypeIndex = arena_memory_type_index,
    };
    const auto device_memory = Vulkan::Check(instance.GetDevice().allocateMemory(alloc_info));
    u8* mapped_memory = nullptr;
    if (direct_downloads) {
        const auto [map_result, pointer] =
            instance.GetDevice().mapMemory(device_memory, 0, VK_WHOLE_SIZE);
        if (map_result == vk::Result::eSuccess) {
            mapped_memory = static_cast<u8*>(pointer);
        } else {
            LOG_WARNING(Render_Vulkan, "Could not map arena memory ({}), direct downloads off",
                        vk::to_string(map_result));
            direct_downloads = false;
        }
    }

    boost::container::small_vector<vk::BufferCopy, 8> copies;
    const auto staging =
        staging_pool.Request(resident_blocks * sizeof(vk::DeviceAddress), MemoryType::HostUncached);

    u64 memory_offset{};
    ArenaBinds* binds = BindsForArena(arena);
    auto* bda_addrs = reinterpret_cast<vk::DeviceAddress*>(staging.mapped);
    u64 offset = staging.offset;
    for (const auto& range : bind_ranges) {
        Backing backing;
        backing.start = range.start;
        backing.end = range.end;
        backing.memory = device_memory;
        backing.offset = memory_offset >> block_shift;
        backing.mapped = mapped_memory;
        resident_ranges.Add(backing);

        LOG_INFO(Render, "Making range start={}, end={} resident", backing.start, backing.end);

        const auto& bind = binds->binds.emplace_back(vk::SparseMemoryBind{
            .resourceOffset = (range.start << block_shift) - arena->cpu_addr,
            .size = (range.end - range.start) << block_shift,
            .memory = device_memory,
            .memoryOffset = memory_offset,
        });
        memory_offset += bind.size;

        if (!has_bda) {
            continue;
        }
        for (u32 block = 0; block < bind.size; block += block_size) {
            *(bda_addrs++) = arena->BufferDeviceAddress() + bind.resourceOffset + block;
        }
        const u64 copy_size = (backing.end - backing.start) * sizeof(vk::DeviceAddress);
        copies.emplace_back(offset, backing.start * sizeof(vk::DeviceAddress), copy_size);
        offset += copy_size;
    }

    if (has_bda) {
        staging.Flush();
        runtime.CopyBuffer(staging.buffer, bda_pagetable_buffer.get(), copies);
    }
}

void BufferCache::LogInlineUpload(const Buffer* arena, VAddr device_addr, u32 size,
                                  std::span<const vk::BufferCopy> copies, bool is_written) {
    // SHADPS4_INLINE_UPLOAD_LOG=<file>: creating the file logs the next 400 uploads that end an
    // open render pass, then the file is removed.
    static const char* const trigger = std::getenv("SHADPS4_INLINE_UPLOAD_LOG");
    static u32 budget{};
    static u32 calls{};
    if (trigger == nullptr || trigger[0] == '\0') {
        return;
    }
    if (budget == 0) {
        if ((++calls & 63) != 0) {
            return;
        }
        std::error_code ec;
        if (!std::filesystem::exists(trigger, ec)) {
            return;
        }
        std::filesystem::remove(trigger, ec);
        budget = 400;
    }
    --budget;
    u64 dirty_bytes{};
    VAddr first_dirty = ~VAddr{0};
    for (const auto& copy : copies) {
        dirty_bytes += copy.size;
        first_dirty = std::min<VAddr>(first_dirty, arena->cpu_addr + copy.dstOffset);
    }
    LOG_INFO(Render_Vulkan,
             "Inline upload session={} bound={:#x}+{:#x} written={} dirty={:#x} ranges={} "
             "bytes={:#x} caller={}",
             scheduler.SessionSerial(), device_addr, size, is_written, first_dirty, copies.size(),
             dirty_bytes, fmt::ptr(obtain_caller));
}

bool BufferCache::SynchronizeMemory(const Buffer* arena, VAddr device_addr, u32 size,
                                    bool allow_defer, bool is_written, bool is_texel_buffer) {
    boost::container::small_vector<vk::BufferCopy, 4> copies;
    size_t total_size_bytes{};
    memory_tracker->ForEachUploadRange(device_addr, size, is_written, [&](u64 addr, u64 size) {
        copies.emplace_back(total_size_bytes, addr, size);
        total_size_bytes += size;
    });
    if (!copies.empty()) {
        DebugState.AddPerf(DebugStateType::DebugStateImpl::PerfCounter::UploadBytes, total_size_bytes);
        const auto staging = staging_pool.Request(total_size_bytes, MemoryType::HostUncached);
        for (auto& copy : copies) {
            memory->CopySparseMemory(copy.dstOffset, staging.mapped + copy.srcOffset, copy.size);
            copy.srcOffset += staging.offset;
            copy.dstOffset -= arena->cpu_addr;
        }
        staging.Flush();
        // Uploads are recorded while draws are bound, so the copy would end the open render pass,
        // and on a tiler every split stores and reloads all attachments. When nothing in this
        // session has used the destination yet, run the copy before the session instead.
        static SwitchFile defer_off{"SHADPS4_DEFER_UPLOADS_OFF_FILE"};
        bool defer = allow_defer && !defer_off.Exists();
        for (const auto& copy : copies) {
            if (!defer) {
                break;
            }
            defer = !session_used.Intersects(arena->cpu_addr + copy.dstOffset, copy.size);
        }
        if (defer) {
            runtime.CopyBufferBeforeSession(staging.buffer, arena, copies);
            DebugState.AddPerf(DebugStateType::DebugStateImpl::PerfCounter::DeferredUploads);
        } else {
            if (scheduler.IsRendering()) {
                // Attribute the split to the binding that asked for the buffer (diagnostics).
                DebugState.AddPassEnd(obtain_caller);
                LogInlineUpload(arena, device_addr, size, copies, is_written);
            }
            runtime.CopyBuffer(staging.buffer, arena, copies);
        }
        for (const auto& copy : copies) {
            MarkBlocksWritten(arena->cpu_addr + copy.dstOffset, copy.size);
        }
    }
    if (is_texel_buffer && !is_written) {
        return SynchronizeMemoryFromImage(arena, device_addr, size);
    }
    return false;
}

bool BufferCache::SynchronizeMemoryFromImage(const Buffer* arena, VAddr device_addr, u32 size) {
    if (const auto meta = texture_cache.GetMetaInfo(device_addr)) {
        if (meta->type == TextureCache::MetaType::HTile) {
            static constexpr u32 ZmaskUncompressed = 0xf;
            runtime.FillBuffer(arena, arena->Offset(device_addr), size, ZmaskUncompressed);
            MarkBlocksWritten(device_addr, size);
            return true;
        } else if (meta->type == TextureCache::MetaType::CMask) {
            const auto expanded_value = CmaskColorExpandedValue(meta->num_samples);
            if (!expanded_value) {
                LOG_WARNING(Render_Vulkan,
                            "Unsupported CMask sample count: address={:#x}, size={:#x}, "
                            "samples={}, owner={}:{}",
                            device_addr, size, meta->num_samples, meta->owner_id.index,
                            meta->owner_uid);
                return false;
            }
            runtime.FillBuffer(arena, arena->Offset(device_addr), size, *expanded_value);
            MarkBlocksWritten(device_addr, size);
            return true;
        } else {
            LOG_WARNING(Render_Vulkan, "Unhandled metadata type {}",
                        magic_enum::enum_name(meta->type));
        }
    }
    const ImageId image_id = texture_cache.FindImageFromRange(device_addr, size);
    if (!image_id) {
        return false;
    }
    Image& image = texture_cache.GetImage(image_id);
    const VAddr image_addr = image.info.guest_address;
    const u64 image_size = image.info.guest_size;
    const VAddr image_end = image_addr + image_size;
    const VAddr buffer_end = device_addr + size;
    if (image_size == 0 || image_end < image_addr || buffer_end < device_addr ||
        device_addr >= image_end || buffer_end <= image_addr) {
        LOG_WARNING(Render_Vulkan,
                    "Texel buffer range does not overlap its aliased image: "
                    "buffer={:#x}+{:#x}, image={:#x}+{:#x}",
                    device_addr, size, image_addr, image_size);
        return false;
    }

    // A formatted buffer can partially overlap a GPU-written image: it may start inside the image
    // and extend beyond it, or cover the image from an earlier address. Tile the full authoritative
    // image back to its original guest range so the overlapping bytes are coherent while the
    // buffer-only prefix or suffix keeps its existing contents. Shifting the image to device_addr
    // would corrupt the byte layout seen by the shader.
    const VAddr arena_end = arena->cpu_addr + arena->size_bytes;
    if (image_addr < arena->cpu_addr || image_end > arena_end) {
        LOG_WARNING(Render_Vulkan,
                    "Aliased image does not fit the buffer arena: image={:#x}+{:#x}, "
                    "arena={:#x}+{:#x}",
                    image_addr, image_size, arena->cpu_addr, arena->size_bytes);
        return false;
    }
    const u64 image_first_block = image_addr >> block_shift;
    const u64 image_last_block = (image_end - 1) >> block_shift;
    EnsureResident(arena, image_first_block, image_last_block);
    const u64 arena_offset = arena->Offset(image_addr);
    boost::container::small_vector<vk::BufferImageCopy, 8> buffer_copies;
    for (u32 mip = 0; mip < image.info.resources.levels; mip++) {
        const auto& mip_info = image.info.mips_layout[mip];
        const u32 width = std::max(image.info.size.width >> mip, 1u);
        const u32 height = std::max(image.info.size.height >> mip, 1u);
        const u32 depth = std::max(image.info.size.depth >> mip, 1u);
        if (arena_offset + mip_info.offset + mip_info.size > arena->size_bytes) {
            break;
        }
        buffer_copies.push_back(vk::BufferImageCopy{
            .bufferOffset = mip_info.offset,
            .bufferRowLength = mip_info.pitch,
            .bufferImageHeight = mip_info.height,
            .imageSubresource{
                .aspectMask = image.aspect_mask & ~vk::ImageAspectFlagBits::eStencil,
                .mipLevel = mip,
                .baseArrayLayer = 0,
                .layerCount = image.info.resources.layers,
            },
            .imageOffset = {0, 0, 0},
            .imageExtent = {width, height, depth},
        });
    }
    if (buffer_copies.empty()) {
        return false;
    }
    auto& tile_manager = texture_cache.GetTileManager();
    tile_manager.TileImage(image, buffer_copies, arena, arena_offset);
    MarkBlocksWritten(image_addr, image_size);
    return true;
}

void BufferCache::SubmitPendingArenaBinds(Vulkan::SubmitInfo& info) {
    if (pending_binds.empty()) {
        return;
    }

    std::vector<vk::SparseBufferMemoryBindInfo> buffer_binds;
    buffer_binds.reserve(pending_binds.size());

    for (const auto& binds : pending_binds) {
        buffer_binds.emplace_back(vk::SparseBufferMemoryBindInfo{
            .buffer = binds.arena->Handle(),
            .bindCount = static_cast<u32>(binds.binds.size()),
            .pBinds = binds.binds.data(),
        });
    }

    const u64 signal_tick = memory_semaphore.NextTick();
    const auto signal_sema = memory_semaphore.Handle();

    const vk::TimelineSemaphoreSubmitInfo timeline_si = {
        .signalSemaphoreValueCount = 1u,
        .pSignalSemaphoreValues = &signal_tick,
    };

    const vk::BindSparseInfo sparse_info = {
        .pNext = &timeline_si,
        .bufferBindCount = static_cast<u32>(buffer_binds.size()),
        .pBufferBinds = buffer_binds.data(),
        .signalSemaphoreCount = 1u,
        .pSignalSemaphores = &signal_sema,
    };

    info.AddWait(signal_sema, signal_tick);
    auto submit_result = instance.GetGraphicsQueue().bindSparse(sparse_info);
    ASSERT_MSG(submit_result != vk::Result::eErrorDeviceLost, "Device lost during submit");

    pending_binds.clear();
}

} // namespace VideoCore
