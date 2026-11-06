// SPDX-FileCopyrightText: Copyright 2024-2026 shadPS4 Emulator Project
// SPDX-License-Identifier: GPL-2.0-or-later

#include <array>
#include <atomic>
#include <cstdlib>
#include <limits>
#include <mutex>
#include <thread>
#include <unordered_map>

#include "aio.h"
#include "common/assert.h"
#include "common/debug.h"
#include "common/logging/log.h"
#include "core/libraries/kernel/equeue.h"
#include "core/libraries/kernel/orbis_error.h"
#include "core/libraries/kernel/time.h"
#include "core/libraries/libs.h"
#include "file_system.h"

namespace Libraries::Kernel {

// Every read or write runs inside the submit call, so a request is already COMPLETED or ABORTED
// when the game receives its id. What the game can still observe is the id bookkeeping. The
// original implementation shared one ring of 511 ids between all threads without a lock and
// marked a slot ABORTED when its id was deleted: two threads submitting at once could be handed
// the same id, and deleting an old id marked a newer request that had reused the slot as ABORTED.
// The default now hands out ids from a counter under a mutex and keeps each request's state until
// that request's own id is deleted. SHADPS4_AIO_LEGACY=1 restores the ring for comparison. Both
// modes count the hazards: an id handed out while its slot was still held, a poll or wait that
// reports ABORTED, and an id the game uses after deleting it.

static constexpr s32 ORBIS_KERNEL_AIO_MAX_QUEUES = 512;

namespace {

bool LegacyMode() {
    static const bool legacy = [] {
        const char* value = std::getenv("SHADPS4_AIO_LEGACY");
        return value != nullptr && value[0] != '\0' && value[0] != '0';
    }();
    return legacy;
}

struct Requests {
    std::mutex mutex;
    std::unordered_map<s32, s32> states;
    s32 next_id = 1;
};
Requests g_requests;

// Legacy ring.
s32* id_state;
s32 id_index;
std::array<std::atomic<u8>, ORBIS_KERNEL_AIO_MAX_QUEUES> legacy_live{};

std::atomic<u64> g_submits{0};
std::atomic<u64> g_overlaps{0};
std::atomic<u64> g_reused_live{0};
std::atomic<u64> g_aborted_seen{0};
std::atomic<u64> g_unknown_ids{0};
std::atomic<s32> g_in_flight{0};

void Note(std::atomic<u64>& counter, const char* what, s32 id) {
    const u64 n = ++counter;
    if (n <= 32 || n % 1000 == 0) {
        LOG_WARNING(Kernel, "aio: {} (id {}; {} so far, {} submits, {} overlapping)", what, id, n,
                    g_submits.load(), g_overlaps.load());
    }
}

struct InFlight {
    InFlight() {
        ++g_submits;
        if (++g_in_flight > 1) {
            ++g_overlaps;
        }
    }
    ~InFlight() {
        --g_in_flight;
    }
};

// Caller holds g_requests.mutex.
s32 AllocateId(s32 state) {
    s32 id;
    do {
        id = g_requests.next_id;
        g_requests.next_id =
            g_requests.next_id == std::numeric_limits<s32>::max() ? 1 : g_requests.next_id + 1;
    } while (g_requests.states.contains(id));
    g_requests.states.emplace(id, state);
    return id;
}

void SetState(s32 id, s32 state) {
    std::scoped_lock lk{g_requests.mutex};
    g_requests.states[id] = state;
}

// Returns false for an id that was never handed out or was already deleted.
bool GetState(s32 id, s32* state) {
    std::scoped_lock lk{g_requests.mutex};
    const auto it = g_requests.states.find(id);
    if (it == g_requests.states.end()) {
        return false;
    }
    *state = it->second;
    return true;
}

s32 RunRead(OrbisKernelAioRWRequest& request) {
    const s64 ret = sceKernelPread(request.fd, request.buf, request.nbyte, request.offset);
    const s32 state = ret < 0 ? ORBIS_KERNEL_AIO_STATE_ABORTED : ORBIS_KERNEL_AIO_STATE_COMPLETED;
    request.result->state = state;
    request.result->returnValue = ret;
    return state;
}

s32 RunWrite(OrbisKernelAioRWRequest& request) {
    const s64 ret = sceKernelPwrite(request.fd, request.buf, request.nbyte, request.offset);
    const s32 state = ret < 0 ? ORBIS_KERNEL_AIO_STATE_ABORTED : ORBIS_KERNEL_AIO_STATE_COMPLETED;
    request.result->state = state;
    request.result->returnValue = ret;
    return state;
}

// Legacy: the slot this submission is about to use; counts a slot reused while still held.
void LegacyClaim(s32 slot) {
    if (legacy_live[slot].exchange(1) != 0) {
        Note(g_reused_live, "id handed out while still held", slot);
    }
}

void LegacyAdvance() {
    id_index = (id_index + 1) % ORBIS_KERNEL_AIO_MAX_QUEUES;
    // Skip id 0: sceKernelAioCancelRequest treats it specially.
    if (!id_index) {
        id_index++;
    }
}

bool LegacyValid(s32 id) {
    return id >= 0 && id < ORBIS_KERNEL_AIO_MAX_QUEUES;
}

s32 ReadState(s32 id, s32* state) {
    if (LegacyMode()) {
        if (!LegacyValid(id)) {
            Note(g_unknown_ids, "id out of range", id);
            return ORBIS_KERNEL_ERROR_ESRCH;
        }
        *state = id_state[id];
    } else if (!GetState(id, state)) {
        Note(g_unknown_ids, "unknown or deleted id", id);
        return ORBIS_KERNEL_ERROR_ESRCH;
    }
    if (*state == ORBIS_KERNEL_AIO_STATE_ABORTED) {
        Note(g_aborted_seen, "request reported as aborted", id);
    }
    return ORBIS_OK;
}

void Delete(s32 id) {
    if (LegacyMode()) {
        if (!LegacyValid(id)) {
            Note(g_unknown_ids, "delete of an id out of range", id);
            return;
        }
        id_state[id] = ORBIS_KERNEL_AIO_STATE_ABORTED;
        legacy_live[id].store(0);
        return;
    }
    std::scoped_lock lk{g_requests.mutex};
    if (g_requests.states.erase(id) == 0) {
        Note(g_unknown_ids, "delete of an unknown or deleted id", id);
    }
}

// Requests finish inside the submit call, so a cancel can only find a finished request (it keeps
// its state) or a request another thread is still running (it becomes ABORTED, as before).
s32 Cancel(s32 id) {
    if (!id) {
        return ORBIS_KERNEL_AIO_STATE_PROCESSING;
    }
    if (LegacyMode()) {
        if (!LegacyValid(id)) {
            Note(g_unknown_ids, "cancel of an id out of range", id);
            return ORBIS_KERNEL_AIO_STATE_ABORTED;
        }
        id_state[id] = ORBIS_KERNEL_AIO_STATE_ABORTED;
        return ORBIS_KERNEL_AIO_STATE_ABORTED;
    }
    std::scoped_lock lk{g_requests.mutex};
    const auto it = g_requests.states.find(id);
    if (it == g_requests.states.end()) {
        Note(g_unknown_ids, "cancel of an unknown or deleted id", id);
        return ORBIS_KERNEL_AIO_STATE_ABORTED;
    }
    if (it->second == ORBIS_KERNEL_AIO_STATE_PROCESSING ||
        it->second == ORBIS_KERNEL_AIO_STATE_SUBMITTED) {
        it->second = ORBIS_KERNEL_AIO_STATE_ABORTED;
    }
    return it->second;
}

bool Processing(s32 id) {
    s32 state;
    if (LegacyMode()) {
        return LegacyValid(id) && id_state[id] == ORBIS_KERNEL_AIO_STATE_PROCESSING;
    }
    return GetState(id, &state) && state == ORBIS_KERNEL_AIO_STATE_PROCESSING;
}

} // namespace

s32 PS4_SYSV_ABI sceKernelAioInitializeImpl(void* p, s32 size) {
    return 0;
}

s32 PS4_SYSV_ABI sceKernelAioDeleteRequest(OrbisKernelAioSubmitId id, s32* ret) {
    if (ret == nullptr) {
        return ORBIS_KERNEL_ERROR_EFAULT;
    }
    Delete(id);
    *ret = 0;
    return 0;
}

s32 PS4_SYSV_ABI sceKernelAioDeleteRequests(OrbisKernelAioSubmitId id[], s32 num, s32 ret[]) {
    if (ret == nullptr) {
        return ORBIS_KERNEL_ERROR_EFAULT;
    }
    for (s32 i = 0; i < num; i++) {
        Delete(id[i]);
        ret[i] = 0;
    }
    return 0;
}

s32 PS4_SYSV_ABI sceKernelAioPollRequest(OrbisKernelAioSubmitId id, s32* state) {
    if (state == nullptr) {
        return ORBIS_KERNEL_ERROR_EFAULT;
    }
    return ReadState(id, state);
}

s32 PS4_SYSV_ABI sceKernelAioPollRequests(OrbisKernelAioSubmitId id[], s32 num, s32 state[]) {
    if (state == nullptr) {
        return ORBIS_KERNEL_ERROR_EFAULT;
    }
    s32 result = 0;
    for (s32 i = 0; i < num; i++) {
        const s32 ret = ReadState(id[i], &state[i]);
        if (ret != ORBIS_OK) {
            state[i] = ORBIS_KERNEL_AIO_STATE_ABORTED;
            result = ret;
        }
    }
    return result;
}

s32 PS4_SYSV_ABI sceKernelAioCancelRequest(OrbisKernelAioSubmitId id, s32* state) {
    if (state == nullptr) {
        return ORBIS_KERNEL_ERROR_EFAULT;
    }
    *state = Cancel(id);
    return 0;
}

s32 PS4_SYSV_ABI sceKernelAioCancelRequests(OrbisKernelAioSubmitId id[], s32 num, s32 state[]) {
    if (state == nullptr) {
        return ORBIS_KERNEL_ERROR_EFAULT;
    }
    for (s32 i = 0; i < num; i++) {
        state[i] = Cancel(id[i]);
    }
    return 0;
}

s32 PS4_SYSV_ABI sceKernelAioWaitRequest(OrbisKernelAioSubmitId id, s32* state, u32* usec) {
    if (state == nullptr) {
        return ORBIS_KERNEL_ERROR_EFAULT;
    }
    u32 timer = 0;
    s32 timeout = 0;
    while (Processing(id)) {
        sceKernelUsleep(10);
        timer += 10;
        if (usec != nullptr && *usec && timer > *usec) {
            timeout = 1;
            break;
        }
    }
    const s32 ret = ReadState(id, state);
    if (timeout) {
        return ORBIS_KERNEL_ERROR_ETIMEDOUT;
    }
    return ret;
}

s32 PS4_SYSV_ABI sceKernelAioWaitRequests(OrbisKernelAioSubmitId id[], s32 num, s32 state[],
                                          u32 mode, u32* usec) {
    if (state == nullptr) {
        return ORBIS_KERNEL_ERROR_EFAULT;
    }
    u32 timer = 0;
    s32 timeout = 0;
    s32 completion = 0;
    s32 result = 0;

    for (s32 i = 0; i < num; i++) {
        if (!completion && !timeout) {
            while (Processing(id[i])) {
                sceKernelUsleep(10);
                timer += 10;
                if (usec != nullptr && *usec && timer > *usec) {
                    timeout = 1;
                    break;
                }
            }
        }
        const s32 ret = ReadState(id[i], &state[i]);
        if (ret != ORBIS_OK) {
            state[i] = ORBIS_KERNEL_AIO_STATE_ABORTED;
            result = ret;
        }
        if (mode == 0x02 && state[i] == ORBIS_KERNEL_AIO_STATE_COMPLETED) {
            completion = 1;
        }
    }

    if (timeout) {
        return ORBIS_KERNEL_ERROR_ETIMEDOUT;
    }
    return result;
}

s32 PS4_SYSV_ABI sceKernelAioSubmitReadCommands(OrbisKernelAioRWRequest req[], s32 size, s32 prio,
                                                OrbisKernelAioSubmitId* id) {
    if (req == nullptr) {
        return ORBIS_KERNEL_ERROR_EFAULT;
    }
    if (id == nullptr) {
        return ORBIS_KERNEL_ERROR_EFAULT;
    }
    InFlight in_flight;
    if (LegacyMode()) {
        const s32 slot = id_index;
        LegacyClaim(slot);
        id_state[slot] = ORBIS_KERNEL_AIO_STATE_PROCESSING;
        for (s32 i = 0; i < size; i++) {
            RunRead(req[i]);
        }
        id_state[slot] = ORBIS_KERNEL_AIO_STATE_COMPLETED;
        *id = id_index;
        LegacyAdvance();
        return 0;
    }

    s32 new_id;
    {
        std::scoped_lock lk{g_requests.mutex};
        new_id = AllocateId(ORBIS_KERNEL_AIO_STATE_PROCESSING);
    }
    for (s32 i = 0; i < size; i++) {
        RunRead(req[i]);
    }
    SetState(new_id, ORBIS_KERNEL_AIO_STATE_COMPLETED);
    *id = new_id;
    return 0;
}

s32 PS4_SYSV_ABI sceKernelAioSubmitReadCommandsMultiple(OrbisKernelAioRWRequest req[], s32 size,
                                                        s32 prio, OrbisKernelAioSubmitId id[]) {
    if (req == nullptr) {
        return ORBIS_KERNEL_ERROR_EFAULT;
    }
    if (id == nullptr) {
        return ORBIS_KERNEL_ERROR_EFAULT;
    }
    InFlight in_flight;
    if (LegacyMode()) {
        for (s32 i = 0; i < size; i++) {
            const s32 slot = id_index;
            LegacyClaim(slot);
            id_state[slot] = ORBIS_KERNEL_AIO_STATE_PROCESSING;
            id_state[slot] = RunRead(req[i]);
            id[i] = id_index;
            LegacyAdvance();
        }
        return 0;
    }

    for (s32 i = 0; i < size; i++) {
        s32 new_id;
        {
            std::scoped_lock lk{g_requests.mutex};
            new_id = AllocateId(ORBIS_KERNEL_AIO_STATE_PROCESSING);
        }
        SetState(new_id, RunRead(req[i]));
        id[i] = new_id;
    }
    return 0;
}

s32 PS4_SYSV_ABI sceKernelAioSubmitWriteCommands(OrbisKernelAioRWRequest req[], s32 size, s32 prio,
                                                 OrbisKernelAioSubmitId* id) {
    if (req == nullptr) {
        return ORBIS_KERNEL_ERROR_EFAULT;
    }
    if (id == nullptr) {
        return ORBIS_KERNEL_ERROR_EFAULT;
    }
    InFlight in_flight;
    if (LegacyMode()) {
        const s32 slot = id_index;
        LegacyClaim(slot);
        for (s32 i = 0; i < size; i++) {
            id_state[slot] = ORBIS_KERNEL_AIO_STATE_PROCESSING;
            id_state[slot] = RunWrite(req[i]);
        }
        *id = id_index;
        LegacyAdvance();
        return 0;
    }

    s32 new_id;
    {
        std::scoped_lock lk{g_requests.mutex};
        new_id = AllocateId(ORBIS_KERNEL_AIO_STATE_PROCESSING);
    }
    s32 state = ORBIS_KERNEL_AIO_STATE_COMPLETED;
    for (s32 i = 0; i < size; i++) {
        state = RunWrite(req[i]);
    }
    SetState(new_id, state);
    *id = new_id;
    return 0;
}

s32 PS4_SYSV_ABI sceKernelAioSubmitWriteCommandsMultiple(OrbisKernelAioRWRequest req[], s32 size,
                                                         s32 prio, OrbisKernelAioSubmitId id[]) {
    if (req == nullptr) {
        return ORBIS_KERNEL_ERROR_EFAULT;
    }
    if (id == nullptr) {
        return ORBIS_KERNEL_ERROR_EFAULT;
    }
    InFlight in_flight;
    if (LegacyMode()) {
        for (s32 i = 0; i < size; i++) {
            const s32 slot = id_index;
            LegacyClaim(slot);
            id_state[slot] = ORBIS_KERNEL_AIO_STATE_PROCESSING;
            id_state[slot] = RunWrite(req[i]);
            id[i] = id_index;
            LegacyAdvance();
        }
        return 0;
    }

    for (s32 i = 0; i < size; i++) {
        s32 new_id;
        {
            std::scoped_lock lk{g_requests.mutex};
            new_id = AllocateId(ORBIS_KERNEL_AIO_STATE_PROCESSING);
        }
        SetState(new_id, RunWrite(req[i]));
        id[i] = new_id;
    }
    return 0;
}

s32 PS4_SYSV_ABI sceKernelAioSetParam() {
    LOG_ERROR(Kernel, "(STUBBED) called");
    return ORBIS_OK;
}

s32 PS4_SYSV_ABI sceKernelAioInitializeParam() {
    LOG_ERROR(Kernel, "(STUBBED) called");
    return ORBIS_OK;
}

void RegisterAio(Core::Loader::SymbolsResolver* sym) {
    id_index = 1;
    id_state = reinterpret_cast<s32*>(malloc(sizeof(s32) * ORBIS_KERNEL_AIO_MAX_QUEUES));
    memset(id_state, 0, sizeof(s32) * ORBIS_KERNEL_AIO_MAX_QUEUES);
    if (LegacyMode()) {
        LOG_WARNING(Kernel, "aio: SHADPS4_AIO_LEGACY is set, using the shared ring of 511 ids");
    }

    LIB_FUNCTION("fR521KIGgb8", "libkernel", 1, "libkernel", sceKernelAioCancelRequest);
    LIB_FUNCTION("3Lca1XBrQdY", "libkernel", 1, "libkernel", sceKernelAioCancelRequests);
    LIB_FUNCTION("5TgME6AYty4", "libkernel", 1, "libkernel", sceKernelAioDeleteRequest);
    LIB_FUNCTION("Ft3EtsZzAoY", "libkernel", 1, "libkernel", sceKernelAioDeleteRequests);
    LIB_FUNCTION("vYU8P9Td2Zo", "libkernel", 1, "libkernel", sceKernelAioInitializeImpl);
    LIB_FUNCTION("nu4a0-arQis", "libkernel", 1, "libkernel", sceKernelAioInitializeParam);
    LIB_FUNCTION("2pOuoWoCxdk", "libkernel", 1, "libkernel", sceKernelAioPollRequest);
    LIB_FUNCTION("o7O4z3jwKzo", "libkernel", 1, "libkernel", sceKernelAioPollRequests);
    LIB_FUNCTION("9WK-vhNXimw", "libkernel", 1, "libkernel", sceKernelAioSetParam);
    LIB_FUNCTION("HgX7+AORI58", "libkernel", 1, "libkernel", sceKernelAioSubmitReadCommands);
    LIB_FUNCTION("lXT0m3P-vs4", "libkernel", 1, "libkernel",
                 sceKernelAioSubmitReadCommandsMultiple);
    LIB_FUNCTION("XQ8C8y+de+E", "libkernel", 1, "libkernel", sceKernelAioSubmitWriteCommands);
    LIB_FUNCTION("xT3Cpz0yh6Y", "libkernel", 1, "libkernel",
                 sceKernelAioSubmitWriteCommandsMultiple);
    LIB_FUNCTION("KOF-oJbQVvc", "libkernel", 1, "libkernel", sceKernelAioWaitRequest);
    LIB_FUNCTION("lgK+oIWkJyA", "libkernel", 1, "libkernel", sceKernelAioWaitRequests);
}

} // namespace Libraries::Kernel
