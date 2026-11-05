// SPDX-FileCopyrightText: Copyright 2026 shadPS4 Emulator Project
// SPDX-License-Identifier: GPL-2.0-or-later

#include <algorithm>
#include <array>
#include <optional>

#include "common/logging/log.h"
#include "shader_recompiler/ir/ir_emitter.h"
#include "shader_recompiler/ir/passes/ir_passes.h"
#include "shader_recompiler/ir/passes/resource_pass.h"
#include "shader_recompiler/ir/program.h"
#include "shader_recompiler/profile.h"

namespace Shader::Optimization {

namespace {

// Scalar loads through a table pointer may use an offset that depends on control flow, such as a
// loop over a light list. The host walker cannot evaluate those offsets before the draw, so without
// direct memory access the load is redirected to a raw buffer that starts at the table pointer.
constexpr u32 DynamicTableWindowSize = 64 * 1024;
constexpr u8 SizedWindowsBit = 0x80;

bool IsComposite(const IR::Inst& inst) {
    switch (inst.GetOpcode()) {
    case IR::Opcode::CompositeConstructU32x2:
    case IR::Opcode::CompositeConstructU32x3:
    case IR::Opcode::CompositeConstructU32x4:
    case IR::Opcode::CompositeConstructU32x2x2:
        return true;
    default:
        return false;
    }
}

/// True when the value is assembled into a resource descriptor (T#, V#, S#) instead of being
/// used as data. Those reads belong to resource discovery (image arrays, dynamic sharps).
bool FeedsSharp(const IR::Inst& read, u32 depth = 0) {
    for (const IR::Use& use : read.Uses()) {
        const IR::Inst& user = *use.user;
        if (IsImageInstruction(user) || IsBufferInstruction(user)) {
            return true;
        }
        if (depth < 2 && IsComposite(user) && FeedsSharp(user, depth + 1)) {
            return true;
        }
    }
    return false;
}

/// Size in bytes of the table the base points to, from the shader's SRT metadata. Handles a
/// pointer held in user data and a pointer stored at a constant offset of such a table.
std::optional<u32> TableSize(const IR::Program& program, const IR::Value& lo, const IR::Value& hi) {
    if (!program.info.params || lo.IsImmediate() || hi.IsImmediate()) {
        return std::nullopt;
    }
    const IR::Inst* lo_inst = lo.Inst();
    const IR::Inst* hi_inst = hi.Inst();
    std::optional<Shader::ShaderParams::SrtPointer> pointer;
    if (lo_inst->GetOpcode() == IR::Opcode::GetUserData &&
        hi_inst->GetOpcode() == IR::Opcode::GetUserData) {
        const u32 reg = static_cast<u32>(lo_inst->Arg(0).ScalarReg());
        if (static_cast<u32>(hi_inst->Arg(0).ScalarReg()) != reg + 1) {
            return std::nullopt;
        }
        pointer = program.info.params->FindSrtPointer(reg);
    } else if (lo_inst->GetOpcode() == IR::Opcode::ReadConst &&
               hi_inst->GetOpcode() == IR::Opcode::ReadConst && lo_inst->Arg(1).IsImmediate() &&
               hi_inst->Arg(1).IsImmediate() && lo_inst->Arg(0) == hi_inst->Arg(0)) {
        const IR::Inst* parent = lo_inst->Arg(0).TryInst();
        if (!parent || parent->GetOpcode() != IR::Opcode::CompositeConstructU32x2) {
            return std::nullopt;
        }
        const IR::Inst* plo = parent->Arg(0).TryInst();
        const IR::Inst* phi = parent->Arg(1).TryInst();
        if (!plo || !phi || plo->GetOpcode() != IR::Opcode::GetUserData ||
            phi->GetOpcode() != IR::Opcode::GetUserData) {
            return std::nullopt;
        }
        const u32 reg = static_cast<u32>(plo->Arg(0).ScalarReg());
        const u32 offset = lo_inst->Arg(1).U32();
        if (hi_inst->Arg(1).U32() != offset + 1) {
            return std::nullopt;
        }
        const std::array<u32, 1> offsets{offset};
        pointer = program.info.params->FindSrtPointer(reg, offsets);
    }
    if (!pointer || pointer->size_in_dwords == 0) {
        return std::nullopt;
    }
    return std::min<u32>(pointer->size_in_dwords * 4u, DynamicTableWindowSize);
}

bool IsSharpSource(const IR::Value& value) {
    if (value.IsImmediate()) {
        return true;
    }
    const IR::Inst* inst = value.Inst();
    return inst->GetOpcode() == IR::Opcode::GetUserData ||
           inst->GetOpcode() == IR::Opcode::ReadConst;
}

bool IsWalkerOffset(const IR::Value& value, u32 depth = 0) {
    if (value.IsImmediate()) {
        return true;
    }
    if (depth > 32) {
        return false;
    }
    const IR::Inst* inst = value.Inst();
    switch (inst->GetOpcode()) {
    case IR::Opcode::GetUserData:
        return true;
    case IR::Opcode::ReadConst:
        return IsWalkerOffset(inst->Arg(1), depth + 1);
    case IR::Opcode::IAdd32:
    case IR::Opcode::ISub32:
    case IR::Opcode::IMul32:
    case IR::Opcode::ShiftLeftLogical32:
    case IR::Opcode::ShiftRightLogical32:
    case IR::Opcode::BitwiseAnd32:
    case IR::Opcode::BitwiseOr32:
    case IR::Opcode::BitwiseXor32:
    case IR::Opcode::BitwiseNot32:
    case IR::Opcode::UMin32:
    case IR::Opcode::UMax32:
    case IR::Opcode::BitFieldUExtract:
        for (size_t i = 0; i < inst->NumArgs(); ++i) {
            if (!IsWalkerOffset(inst->Arg(i), depth + 1)) {
                return false;
            }
        }
        return true;
    default:
        return false;
    }
}

} // Anonymous namespace

void LowerDynamicReadConstPass(IR::Program& program, const Profile& profile) {
    if (profile.direct_memory_access && profile.support_bda) {
        return;
    }
    const u32 stage_bit = 1u << static_cast<u32>(program.info.hw_stage);
    if ((profile.dynamic_srt_stages & stage_bit) == 0) {
        if (profile.dynamic_srt_stages == 0) {
            return;
        }
        // Report shaders in the stages left out, so a wrong color can be traced to one.
        u32 num_candidates{};
        for (IR::Block* const block : program.blocks) {
            for (const IR::Inst& inst : block->Instructions()) {
                if (inst.GetOpcode() == IR::Opcode::ReadConst && !IsWalkerOffset(inst.Arg(1))) {
                    ++num_candidates;
                }
            }
        }
        if (num_candidates != 0) {
            LOG_INFO(Render_Recompiler, "Left {} dynamic table reads in {} shader {:#x}",
                     num_candidates, program.info.hw_stage, program.info.pgm_hash);
        }
        return;
    }
    u32 num_lowered{};
    u32 num_sized{};
    u32 num_sharp_reads{};
    for (IR::Block* const block : program.blocks) {
        for (IR::Inst& inst : block->Instructions()) {
            if (inst.GetOpcode() != IR::Opcode::ReadConst || IsWalkerOffset(inst.Arg(1))) {
                continue;
            }
            const IR::Inst* address = inst.Arg(0).TryInst();
            if (!address || address->GetOpcode() != IR::Opcode::CompositeConstructU32x2) {
                continue;
            }
            const IR::Value base_lo = address->Arg(0);
            const IR::Value base_hi = address->Arg(1);
            if (!IsSharpSource(base_lo) || !IsSharpSource(base_hi)) {
                continue;
            }
            u32 window_size = DynamicTableWindowSize;
            if (profile.dynamic_srt_stages & SizedWindowsBit) {
                if (FeedsSharp(inst)) {
                    ++num_sharp_reads;
                    continue;
                }
                if (const auto size = TableSize(program, base_lo, base_hi)) {
                    window_size = std::max<u32>(*size, 16u);
                    ++num_sized;
                }
            }
            IR::IREmitter ir{*block, IR::Block::InstructionList::s_iterator_to(inst)};
            const IR::Value handle = ir.CompositeConstruct(base_lo, base_hi,
                                                           ir.Imm32(window_size), ir.Imm32(0U));
            const IR::U32 value = ir.ReadConstBuffer(handle, IR::U32{inst.Arg(1)}, {});
            inst.ReplaceUsesWithAndRemove(value);
            ++num_lowered;
        }
    }
    if (num_lowered != 0 || num_sharp_reads != 0) {
        LOG_INFO(Render_Recompiler,
                 "Lowered {} dynamic table reads ({} with SRT-sized windows, {} sharp reads left) "
                 "in {} shader {:#x}",
                 num_lowered, num_sized, num_sharp_reads, program.info.hw_stage,
                 program.info.pgm_hash);
    }
}

} // namespace Shader::Optimization
