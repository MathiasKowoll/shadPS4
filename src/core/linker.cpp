// SPDX-FileCopyrightText: Copyright 2025-2026 shadPS4 Emulator Project
// SPDX-License-Identifier: GPL-2.0-or-later

#include <atomic>
#include <cctype>
#include <cstdlib>
#include <deque>
#include <memory>
#include <mutex>
#include <string_view>
#include <vector>

#include <xbyak/xbyak.h>

#include "common/alignment.h"
#include "common/arch.h"
#include "common/assert.h"
#include "common/elf_info.h"
#include "common/io_file.h"
#include "common/logging/formatter.h"
#include "common/logging/log.h"
#include "common/path_util.h"
#include "common/singleton.h"
#include "common/string_util.h"
#include "common/thread.h"
#include "core/aerolib/aerolib.h"
#include "core/aerolib/stubs.h"
#include "core/devtools/widget/module_list.h"
#include "core/emulator_settings.h"
#include "core/file_sys/backends/host_fs.h"
#include "core/file_sys/fs.h"
#include "core/libraries/kernel/kernel.h"
#include "core/libraries/kernel/memory.h"
#include "core/libraries/kernel/threads.h"
#include "core/libraries/libc_internal/libc_internal.h"
#include "core/libraries/sysmodule/sysmodule.h"
#include "core/libraries/sysmodule/sysmodule_internal.h"
#include "core/linker.h"
#include "core/memory.h"
#include "core/tls.h"
#include "ipc/ipc.h"

#ifndef _WIN32
#include <signal.h>
#endif

namespace Core {

namespace {

struct ImportTraceRule {
    std::string importer;
    std::string library;
};

struct ImportTraceEntry {
    std::string importer;
    std::string library;
    std::string nid;
    VAddr target{};
    std::atomic<u64> calls{};
    std::unique_ptr<Xbyak::CodeGenerator> code;
};

std::mutex import_trace_mutex;
std::deque<std::unique_ptr<ImportTraceEntry>> import_trace_entries;

std::string_view TrimTraceToken(std::string_view value) {
    while (!value.empty() && std::isspace(static_cast<unsigned char>(value.front()))) {
        value.remove_prefix(1);
    }
    while (!value.empty() && std::isspace(static_cast<unsigned char>(value.back()))) {
        value.remove_suffix(1);
    }
    return value;
}

const std::vector<ImportTraceRule>& GetImportTraceRules() {
    static const std::vector<ImportTraceRule> rules = [] {
        std::vector<ImportTraceRule> result;
        const char* environment = std::getenv("SHADPS4_TRACE_IMPORTS");
        if (!environment || environment[0] == '\0') {
            return result;
        }

        std::string_view remaining{environment};
        while (!remaining.empty()) {
            const size_t separator = remaining.find(';');
            const std::string_view token = TrimTraceToken(remaining.substr(0, separator));
            const size_t arrow = token.find("->");
            if (arrow != std::string_view::npos) {
                const std::string_view importer = TrimTraceToken(token.substr(0, arrow));
                const std::string_view library = TrimTraceToken(token.substr(arrow + 2));
                if (!importer.empty() && !library.empty()) {
                    result.push_back({std::string{importer}, std::string{library}});
                }
            }
            if (separator == std::string_view::npos) {
                break;
            }
            remaining.remove_prefix(separator + 1);
        }
        return result;
    }();
    return rules;
}

bool TraceNameMatches(std::string_view rule, std::string_view actual) {
    if (rule == "*" || rule == actual) {
        return true;
    }
    const size_t extension = actual.find_last_of('.');
    return extension != std::string_view::npos && rule == actual.substr(0, extension);
}

bool ShouldTraceImport(std::string_view importer, std::string_view library) {
    return std::ranges::any_of(GetImportTraceRules(), [&](const ImportTraceRule& rule) {
        return TraceNameMatches(rule.importer, importer) && TraceNameMatches(rule.library, library);
    });
}

void PS4_SYSV_ABI LogTracedImport(u64 index, VAddr return_address, u64 arg0, u64 arg1, u64 arg2,
                                  u64 arg3) {
    ImportTraceEntry* entry{};
    {
        std::scoped_lock lock{import_trace_mutex};
        if (index >= import_trace_entries.size()) {
            return;
        }
        entry = import_trace_entries[index].get();
    }

    const u64 call = entry->calls.fetch_add(1, std::memory_order_relaxed) + 1;
    const bool power_of_two = (call & (call - 1)) == 0;
    if (call <= 16 || power_of_two || call % 600 == 0) {
        LOG_INFO(Core_ImportTrace,
                 "Import trace: {} -> {} nid={} call={} return={:#x} target={:#x} args=[{:#x}, "
                 "{:#x}, {:#x}, {:#x}] thread={}",
                 entry->importer, entry->library, entry->nid, call, return_address, entry->target,
                 arg0, arg1, arg2, arg3, Common::GetCurrentThreadName());
    }
}

VAddr TraceImport(std::string_view importer, const Loader::SymbolResolver& symbol, VAddr target) {
    if (!target || symbol.type != Loader::SymbolType::Function ||
        !ShouldTraceImport(importer, symbol.library)) {
        return target;
    }

    std::scoped_lock lock{import_trace_mutex};
    for (const auto& existing : import_trace_entries) {
        if (existing->importer == importer && existing->library == symbol.library &&
            existing->nid == symbol.name && existing->target == target) {
            return reinterpret_cast<VAddr>(existing->code->getCode());
        }
    }

    auto entry = std::make_unique<ImportTraceEntry>();
    entry->importer = importer;
    entry->library = symbol.library;
    entry->nid = symbol.name;
    entry->target = target;
    entry->code = std::make_unique<Xbyak::CodeGenerator>(512, Xbyak::AutoGrow);
    auto& code = *entry->code;

    // Preserve every caller-saved integer and SIMD register so tracing does not alter the guest
    // ABI. On SysV x86-64 the original stack is 8 mod 16 at function entry; nine pushes and the
    // 256-byte SIMD save area leave it correctly aligned for the host logging call.
    code.push(code.rax);
    code.push(code.rcx);
    code.push(code.rdx);
    code.push(code.rsi);
    code.push(code.rdi);
    code.push(code.r8);
    code.push(code.r9);
    code.push(code.r10);
    code.push(code.r11);
    constexpr int SimdSaveSize = 16 * 16;
    constexpr int GprSaveSize = 9 * 8;
    code.sub(code.rsp, SimdSaveSize);
    for (int i = 0; i < 16; ++i) {
        code.movdqu(code.ptr[code.rsp + i * 16], Xbyak::Xmm{i});
    }

    const u64 index = import_trace_entries.size();
    code.mov(code.rdx, code.ptr[code.rsp + SimdSaveSize + 4 * 8]);
    code.mov(code.rcx, code.ptr[code.rsp + SimdSaveSize + 5 * 8]);
    code.mov(code.r8, code.ptr[code.rsp + SimdSaveSize + 6 * 8]);
    code.mov(code.r9, code.ptr[code.rsp + SimdSaveSize + 7 * 8]);
    code.mov(code.rdi, index);
    code.mov(code.rsi, code.ptr[code.rsp + SimdSaveSize + GprSaveSize]);
    code.mov(code.rax, reinterpret_cast<VAddr>(&LogTracedImport));
    code.call(code.rax);

    for (int i = 0; i < 16; ++i) {
        code.movdqu(Xbyak::Xmm{i}, code.ptr[code.rsp + i * 16]);
    }
    code.add(code.rsp, SimdSaveSize);
    code.pop(code.r11);
    code.pop(code.r10);
    code.pop(code.r9);
    code.pop(code.r8);
    code.pop(code.rdi);
    code.pop(code.rsi);
    code.pop(code.rdx);
    code.pop(code.rcx);
    code.pop(code.rax);
    code.jmp(code.ptr[code.rip]);
    code.dq(target);
    code.ready();

    const VAddr wrapper = reinterpret_cast<VAddr>(code.getCode());
    LOG_INFO(Core_ImportTrace, "Installed import trace: {} -> {} nid={} target={:#x} wrapper={:#x}",
             entry->importer, entry->library, entry->nid, entry->target, wrapper);
    import_trace_entries.push_back(std::move(entry));
    return wrapper;
}

} // namespace

static PS4_SYSV_ABI void ProgramExitFunc() {
    LOG_ERROR(Core_Linker, "Exit function called");
}

static PS4_SYSV_ABI void* RunMainEntry [[noreturn]](EntryParams* params) {
#ifdef ARCH_X86_64
    // Start shared library modules
    asm volatile("andq $-16, %%rsp\n" // Align to 16 bytes
                 "subq $8, %%rsp\n"   // videoout_basic expects the stack to be misaligned

                 // Kernel also pushes some more things here during process init
                 // at least: environment, auxv, possibly other things

                 "pushq 8(%1)\n" // copy EntryParams to top of stack like the kernel does
                 "pushq 0(%1)\n" // OpenOrbis expects to find it there

                 "movq %1, %%rdi\n" // also pass params and exit func
                 "movq %2, %%rsi\n" // as before

                 "jmp *%0\n" // can't use call here, as that would mangle the prepared stack.
                             // there's no coming back
                 :
                 : "r"(params->entry_addr), "r"(params), "r"(ProgramExitFunc)
                 : "rax", "rsi", "rdi");
    UNREACHABLE();
#else
    UNREACHABLE_MSG("RunMainEntry unimplemented for current architecture.");
#endif
}

Linker::Linker() : memory{Memory::Instance()} {}

Linker::~Linker() = default;

void Linker::Execute(const std::vector<std::string>& args) {
    if (EmulatorSettings.IsDebugDump()) {
        DebugDump();
    }

    // Calculate static TLS size.
    Module* module = m_modules[0].get();
    static_tls_size = module->tls.offset = module->tls.image_size;

    // Map libSceLibcInternal
    const auto& libc_internal_path =
        EmulatorSettings.GetSysModulesDir() / "libSceLibcInternal.sprx";
    bool has_libcinternal = false;
    if (std::filesystem::exists(libc_internal_path)) {
        LoadModule(libc_internal_path);
        has_libcinternal = true;
    } else {
        // Need to load HLE, LLE isn't present
        LOG_INFO(Core_Linker, "Can't Load libSceLibcInternal.sprx switching to HLE");
        Libraries::LibcInternal::RegisterLib(&GetHLESymbols());
    }

    // Relocate all modules
    RelocateAllImports();

    // libkernel entry is responsible for initializing malloc-related elements of libSceLibcInternal
    // this is done through calling _malloc_init, and sceLibcInternalMemoryMutexEnable.
    static PS4_SYSV_ABI s32 (*malloc_init)() = nullptr;
    static PS4_SYSV_ABI void (*sceLibcInternalMemoryMutexEnable)() = nullptr;

    if (has_libcinternal) {
        for (const auto& m : m_modules) {
            const auto& mod = m.get();
            if (mod->name.contains("libSceLibcInternal.sprx")) {
                malloc_init =
                    reinterpret_cast<PS4_SYSV_ABI s32 (*)()>(mod->FindByName("_malloc_init"));
                sceLibcInternalMemoryMutexEnable = reinterpret_cast<PS4_SYSV_ABI void (*)()>(
                    mod->FindByName("sceLibcInternalMemoryMutexEnable"));
                break;
            }
        }
    }

    // Configure the direct and flexible memory regions.
    u64 fmem_size = ORBIS_KERNEL_FLEXIBLE_MEMORY_SIZE;
    bool use_extended_mem1 = true, use_extended_mem2 = true;

    const auto* proc_param = GetProcParam();
    ASSERT(proc_param);

    Core::OrbisKernelMemParam mem_param{};
    if (proc_param->size >= offsetof(OrbisProcParam, mem_param) + sizeof(OrbisKernelMemParam*)) {
        if (proc_param->mem_param) {
            mem_param = *proc_param->mem_param;
            if (mem_param.size >=
                offsetof(OrbisKernelMemParam, flexible_memory_size) + sizeof(u64*)) {
                if (const auto* flexible_size = mem_param.flexible_memory_size) {
                    fmem_size = *flexible_size + ORBIS_KERNEL_FLEXIBLE_MEMORY_BASE;
                }
            }
        }
    }

    if (mem_param.size < offsetof(OrbisKernelMemParam, extended_memory_1) + sizeof(u64*)) {
        mem_param.extended_memory_1 = nullptr;
    }
    if (mem_param.size < offsetof(OrbisKernelMemParam, extended_memory_2) + sizeof(u64*)) {
        mem_param.extended_memory_2 = nullptr;
    }

    const u64 sdk_ver = proc_param->sdk_version;
    if (sdk_ver < Common::ElfInfo::FW_500) {
        use_extended_mem1 = mem_param.extended_memory_1 ? *mem_param.extended_memory_1 : false;
        use_extended_mem2 = mem_param.extended_memory_2 ? *mem_param.extended_memory_2 : false;
    }

    memory->SetupMemoryRegions(fmem_size, use_extended_mem1, use_extended_mem2);

    main_thread.Run([this, module, &args, has_libcinternal](std::stop_token) {
        Common::SetCurrentThreadName("Game:Main");

#ifndef _WIN32 // Clear any existing signal mask for game threads.
        sigset_t emptyset;
        sigemptyset(&emptyset);
        pthread_sigmask(SIG_SETMASK, &emptyset, nullptr);
#endif
        if (auto& ipc = IPC::Instance()) {
            ipc.WaitForStart();
        }

        // Load libSceLibcInternal, run malloc_init.
        if (has_libcinternal) {
            LoadLibcInternal();

            if (malloc_init && sceLibcInternalMemoryMutexEnable) {
                // Call _malloc_init
                s32 ret = malloc_init();
                ASSERT_MSG(ret == 0, "malloc_init failed");
                sceLibcInternalMemoryMutexEnable();
            }
        }

        // Have libSceSysmodule preload our libraries.
        Libraries::SysModule::sceSysmodulePreloadModuleForLibkernel();

        // Load and start custom modules from the user directory.
        std::string_view id = Common::ElfInfo::Instance().GameSerial();
        const auto& custom_mod_directory =
            Common::FS::GetUserPath(Common::FS::PathType::CustomModulesDir) / id;
        if (!std::filesystem::exists(custom_mod_directory)) {
            std::filesystem::create_directory(custom_mod_directory);
        }
        for (const auto& entry : std::filesystem::directory_iterator(custom_mod_directory)) {
            if (entry.is_regular_file()) {
                LOG_INFO(Core_Linker, "Loading custom module: {}",
                         fmt::UTF(entry.path().u8string()));
                if (LoadAndStartModule(entry.path(), 0, nullptr, nullptr) == -1) {
                    LOG_ERROR(Core_Linker, "Failed to load custom module: {}",
                              fmt::UTF(entry.path().u8string()));
                }
            }
        }

        // Simulate libSceGnmDriver initialization, which maps a chunk of direct memory.
        // Some games fail without accurately emulating this behavior.
        s64 phys_addr{};
        s32 result = Libraries::Kernel::sceKernelAllocateDirectMemory(
            0, Libraries::Kernel::sceKernelGetDirectMemorySize(), 0x10000, 0x10000, 3, &phys_addr);
        if (result == 0) {
            void* addr{reinterpret_cast<void*>(0xfe0000000)};
            result = Libraries::Kernel::sceKernelMapNamedDirectMemory(
                &addr, 0x10000, 0x13, 0, phys_addr, 0x10000, "SceGnmDriver");
        }
        ASSERT_MSG(result == 0, "Unable to emulate libSceGnmDriver initialization");

        // Add all guest arguments, we will always have the executable path in argv[0]
        EntryParams& params = Libraries::Kernel::entry_params;
        constexpr int MaxArgs = sizeof(params.argv) / sizeof(params.argv[0]);
        params.argc = std::min<int>(args.size(), MaxArgs);
        for (int i = 0; i < params.argc; i++) {
            params.argv[i] = args[i].c_str();
        }

        // Run the game's entry function
        params.entry_addr = module->GetEntryAddress();
        RunMainEntry(&params);
    });
}

s32 Linker::LoadModule(const std::filesystem::path& elf_name, bool is_dynamic) {
    std::scoped_lock lk{mutex};
    auto* mnt = Common::Singleton<Core::FileSys::MntPoints>::Instance();
    const std::string as_guest = elf_name.generic_string();
    std::unique_ptr<Core::FileSys::IFile> handle;
    if (!as_guest.empty() && as_guest.front() == '/') {
        handle = mnt->Open(as_guest, /*writable=*/false);
    }
    if (!handle) {
        if (!std::filesystem::exists(elf_name)) {
            LOG_ERROR(Core_Linker, "Provided file {} does not exist", elf_name.string());
            return -1;
        }
        auto host = std::make_unique<Core::FileSys::HostFile>(
            elf_name, Common::FS::FileAccessMode::Read, /*read_only=*/true);
        if (!host->IsOpen()) {
            LOG_ERROR(Core_Linker, "Provided file {} could not be opened", elf_name.string());
            return -1;
        }
        handle = std::move(host);
    }

    s32 mod_id = m_modules.size();
    auto module =
        std::make_unique<Module>(memory, elf_name, std::move(handle), max_tls_index, mod_id);
    ASSERT_MSG(module->IsValid(),
               "Provided file {} is not valid ELF file. This usually indicated a corrupted dump.",
               elf_name.string());

    num_static_modules += !is_dynamic;
    m_modules.emplace_back(std::move(module));

    Core::Devtools::Widget::ModuleList::AddModule(elf_name.filename().string(), elf_name);

    return mod_id;
}

s32 Linker::LoadAndStartModule(const std::filesystem::path& path, u64 args, const void* argp,
                               int* pRes) {
    u32 handle = FindByName(path);
    if (handle != -1) {
        return handle;
    }
    handle = LoadModule(path, true);
    if (handle == -1) {
        return -1;
    }
    auto* module = GetModule(handle);
    RelocateAnyImports(module);

    // If the new module has a TLS image, trigger its load when TlsGetAddr is called.
    if (module->tls.image_size != 0) {
        AdvanceGenerationCounter();
    }

    // Retrieve and verify proc param according to libkernel.
    auto* param = module->GetProcParam<OrbisProcParam*>();
    ASSERT_MSG(!param || param->size >= 0x18, "Invalid module param size: {}", param->size);
    s32 ret = module->Start(args, argp, param);
    if (pRes) {
        *pRes = ret;
    }

    return handle;
}

Module* Linker::FindByAddress(VAddr address) {
    for (auto& module : m_modules) {
        const VAddr base = module->GetBaseAddress();
        if (address >= base && address < base + module->aligned_base_size) {
            return module.get();
        }
    }
    return nullptr;
}

void Linker::Relocate(Module* module) {
    module->ForEachRelocation([&](elf_relocation* rel, u32 i, bool is_jmp_rel) {
        const u32 num_relocs = module->dynamic_info.relocation_table_size / sizeof(elf_relocation);
        const u32 bit_idx = (is_jmp_rel ? num_relocs : 0) + i;
        if (module->TestRelaBit(bit_idx)) {
            return;
        }
        auto type = rel->GetType();
        auto symbol = rel->GetSymbol();
        auto addend = rel->rel_addend;
        auto* symbol_table = module->dynamic_info.symbol_table;
        auto* names_tlb = module->dynamic_info.str_table;

        const VAddr rel_base_virtual_addr = module->GetBaseAddress();
        const VAddr rel_virtual_addr = rel_base_virtual_addr + rel->rel_offset;
        bool rel_is_resolved = false;
        u64 rel_value = 0;
        Loader::SymbolType rel_sym_type = Loader::SymbolType::Unknown;
        std::string rel_name;

        switch (type) {
        case R_X86_64_RELATIVE:
            rel_value = rel_base_virtual_addr + addend;
            rel_is_resolved = true;
            module->SetRelaBit(bit_idx);
            break;
        case R_X86_64_DTPMOD64:
            rel_value = static_cast<u64>(module->tls.modid);
            rel_is_resolved = true;
            rel_sym_type = Loader::SymbolType::Tls;
            module->SetRelaBit(bit_idx);
            break;
        case R_X86_64_GLOB_DAT:
        case R_X86_64_JUMP_SLOT:
            addend = 0;
        case R_X86_64_64: {
            auto sym = symbol_table[symbol];
            auto sym_bind = sym.GetBind();
            auto sym_type = sym.GetType();
            auto sym_visibility = sym.GetVisibility();
            u64 symbol_virtual_addr = 0;
            Loader::SymbolRecord symrec{};
            switch (sym_type) {
            case STT_FUN:
                rel_sym_type = Loader::SymbolType::Function;
                break;
            case STT_OBJECT:
                rel_sym_type = Loader::SymbolType::Object;
                break;
            case STT_NOTYPE:
                rel_sym_type = Loader::SymbolType::NoType;
                break;
            default:
                ASSERT_MSG(0, "unknown symbol type {}", sym_type);
            }

            if (sym_visibility != 0) {
                LOG_INFO(Core_Linker, "symbol visibility !=0");
            }

            switch (sym_bind) {
            case STB_LOCAL:
                symbol_virtual_addr = rel_base_virtual_addr + sym.st_value;
                module->SetRelaBit(bit_idx);
                break;
            case STB_GLOBAL:
            case STB_WEAK: {
                rel_name = names_tlb + sym.st_name;
                if (Resolve(rel_name, rel_sym_type, module, &symrec)) {
                    // Only set the rela bit if the symbol was actually resolved and not stubbed.
                    module->SetRelaBit(bit_idx);
                }
                symbol_virtual_addr = symrec.virtual_address;
                break;
            }
            default:
                UNREACHABLE_MSG("Unknown bind type {}", sym_bind);
            }
            rel_is_resolved = (symbol_virtual_addr != 0);
            rel_value = (rel_is_resolved ? symbol_virtual_addr + addend : 0);
            rel_name = symrec.symbol.name;
            break;
        }
        default:
            LOG_INFO(Core_Linker, "UNK type {:#010x} rel symbol : {:#010x}", type, symbol);
        }

        if (rel_is_resolved) {
            std::memcpy(reinterpret_cast<void*>(rel_virtual_addr), &rel_value, sizeof(rel_value));
        } else if (rel_sym_type == Loader::SymbolType::Function) {
            LOG_INFO(Core_Linker, "Function not patched! {}", rel_name);
        }
    });
}

bool Linker::Resolve(const std::string& name, Loader::SymbolType sym_type, Module* m,
                     Loader::SymbolRecord* return_info) {
    const auto ids = Common::SplitString(name, '#');
    const LibraryInfo* library;
    const ModuleInfo* module;
    if (ids.size() != 3 && sym_type != Loader::SymbolType::NoType) {
        return_info->virtual_address = 0;
        return_info->symbol.name = ids.at(0);
        LOG_ERROR(Core_Linker, "Not Resolved {}", name);
        return false;
    } else if (ids.size() == 1 && sym_type == Loader::SymbolType::NoType) {
        LOG_DEBUG(Core_Linker, "NoType export {}", name);
        library = m->FindLibrary("");
        module = m->FindModule("");
    } else {
        library = m->FindLibrary(ids[1]);
        module = m->FindModule(ids[2]);
    }

    ASSERT_MSG(library && module, "Unable to find library and module");

    Loader::SymbolResolver sr{};
    sr.name = ids.at(0);
    sr.library = library->name;
    sr.library_version = library->version;
    sr.module = module->name;
    sr.type = sym_type;

    const auto* record = m_hle_symbols.FindSymbol(sr);
    if (record) {
        *return_info = *record;
        return_info->virtual_address = TraceImport(m->name, sr, return_info->virtual_address);
        Core::Devtools::Widget::ModuleList::AddModule(sr.library);
        return true;
    }

    // Check if it an exported function from one of our loaded libraries
    for (const auto& mod : m_modules) {
        if (!std::ranges::contains(mod->GetExportLibs(), *library) ||
            !std::ranges::contains(mod->GetExportModules(), *module)) {
            continue;
        }
        if (mod->export_sym.GetSize() == 0) {
            continue;
        }
        record = mod->export_sym.FindSymbol(sr);
        if (record) {
            *return_info = *record;
            return_info->virtual_address = TraceImport(m->name, sr, return_info->virtual_address);
            return true;
        }
    }

    const auto aeronid = AeroLib::FindByNid(sr.name.c_str());
    if (sym_type == Loader::SymbolType::Object) {
        return_info->symbol.nidName = aeronid ? aeronid->name : "Unknown object";
        return_info->virtual_address = 0;
    } else if (aeronid) {
        return_info->symbol.nidName = aeronid->name;
        return_info->virtual_address = AeroLib::GetStub(aeronid->nid);
    } else {
        return_info->virtual_address = AeroLib::GetStub(sr.name.c_str());
        return_info->symbol.nidName = "Unknown !!!";
    }
    return_info->virtual_address = TraceImport(m->name, sr, return_info->virtual_address);
    if (library->name != "libc" && library->name != "libSceFios2") {
        LOG_WARNING(Core_Linker, "Linker: Stub resolved {} as {} (lib: {}, mod: {})", sr.name,
                    return_info->symbol.nidName, library->name, module->name);
    } else {
        if (library->name == "libc" && return_info->symbol.nidName == "Need_sceLibc") {
            Libraries::SysModule::g_need_scelibc = true;
        }
        if (library->name == "libSceFios2" && return_info->symbol.nidName == "sceFiosInitialize") {
            Libraries::SysModule::g_need_scelibc = true;
        }
    }
    return false;
}

void* Linker::TlsGetAddr(u64 module_index, u64 offset) {
    std::scoped_lock lk{mutex};

    ASSERT_MSG(module_index > 0 && module_index <= max_tls_index,
               "Invalid TLS module index {} (maximum {})", module_index, max_tls_index);

    DtvEntry* dtv_table = GetTcbBase()->tcb_dtv;
    if (dtv_table[0].counter != dtv_generation_counter) {
        // Generation counter changed, a dynamic module was either loaded or unloaded.
        const u32 old_num_dtvs = dtv_table[1].counter;
        ASSERT_MSG(max_tls_index > old_num_dtvs, "Module unloading unsupported");
        // Module was loaded, increase DTV table size.
        DtvEntry* new_dtv_table = new DtvEntry[max_tls_index + 2]{};
        std::memcpy(new_dtv_table + 2, dtv_table + 2, old_num_dtvs * sizeof(DtvEntry));
        new_dtv_table[0].counter = dtv_generation_counter;
        new_dtv_table[1].counter = max_tls_index;
        delete[] dtv_table;

        // Update TCB pointer.
        GetTcbBase()->tcb_dtv = new_dtv_table;
        dtv_table = new_dtv_table;
    }

    u8* addr = dtv_table[module_index + 1].pointer;
    Module* module = nullptr;
    for (const auto& candidate : m_modules) {
        if (candidate->tls.modid == module_index) {
            module = candidate.get();
            break;
        }
    }
    ASSERT_MSG(module, "No module owns TLS index {}", module_index);
    ASSERT_MSG(offset < module->tls.image_size, "TLS offset {} exceeds module {} image size {}",
               offset, module->name, module->tls.image_size);
    if (!addr) {
        // Module was just loaded by above code. Allocate TLS block for it.
        const u32 init_image_size = module->tls.init_image_size;
        u8* dest{};
        if (heap_api && heap_api->heap_malloc) {
            dest = reinterpret_cast<u8*>(heap_api->heap_malloc(module->tls.image_size));
        } else {
            dest = reinterpret_cast<u8*>(std::malloc(module->tls.image_size));
        }
        const u8* src = reinterpret_cast<const u8*>(module->tls.image_virtual_addr);
        std::memcpy(dest, src, init_image_size);
        std::memset(dest + init_image_size, 0, module->tls.image_size - init_image_size);
        dtv_table[module_index + 1].pointer = dest;
        addr = dest;
    }
    return addr + offset;
}

void* Linker::AllocateTlsForThread(bool is_primary) {
    static constexpr size_t TcbSize = 0x40;
    static constexpr size_t TlsAllocAlign = 0x20;
    const size_t total_tls_size = Common::AlignUp(static_tls_size, TlsAllocAlign) + TcbSize;

    // If sceKernelMapNamedFlexibleMemory is being called from libkernel and addr = 0
    // it automatically places mappings in system reserved area instead of managed.
    // Since the system reserved area already has a mapping in it, this address is slightly higher.
    static constexpr VAddr KernelAllocBase = 0x881000000ULL;

    // The kernel module has a few different paths for TLS allocation.
    // For SDK < 1.7 it allocates both main and secondary thread blocks using libc mspace/malloc.
    // In games compiled with newer SDK, the main thread gets mapped from flexible memory,
    // with addr = 0, so system managed area. Here we will only implement the latter.
    void* addr_out{reinterpret_cast<void*>(KernelAllocBase)};
    if (is_primary) {
        const size_t tls_aligned = Common::AlignUp(total_tls_size, 16_KB);
        const int ret = Libraries::Kernel::sceKernelMapNamedFlexibleMemory(
            &addr_out, tls_aligned, 3, 0, "SceKernelPrimaryTcbTls");
        ASSERT_MSG(ret == 0, "Unable to allocate TLS+TCB for the primary thread");
    } else {
        if (heap_api && heap_api->heap_malloc) {
            addr_out = heap_api->heap_malloc(total_tls_size);
        } else {
            addr_out = std::malloc(total_tls_size);
        }
    }
    return addr_out;
}

void Linker::FreeTlsForNonPrimaryThread(void* pointer) {
    if (heap_api && heap_api->heap_free) {
        heap_api->heap_free(pointer);
    } else {
        std::free(pointer);
    }
}

void Linker::DebugDump() {
    const auto& log_dir = Common::FS::GetUserPath(Common::FS::PathType::LogDir);
    const std::filesystem::path debug(log_dir / "debugdump");
    std::filesystem::create_directory(debug);
    for (const auto& m : m_modules) {
        Module* module = m.get();
        auto& elf = module->elf;
        const std::filesystem::path filepath(debug / module->file.stem());
        std::filesystem::create_directory(filepath);
        module->import_sym.DebugDump(filepath / "imports.txt");
        module->export_sym.DebugDump(filepath / "exports.txt");
        Common::FS::IOFile relocations{filepath / "relocations.txt",
                                       Common::FS::FileAccessMode::Create,
                                       Common::FS::FileType::TextFile};
        const u32 num_relocs = module->dynamic_info.relocation_table_size / sizeof(elf_relocation);
        module->ForEachRelocation([&](const elf_relocation* rel, u32 index, bool is_jump) {
            const u32 bit_index = (is_jump ? num_relocs : 0) + index;
            const u32 symbol_index = rel->GetSymbol();
            const auto& symbol = module->dynamic_info.symbol_table[symbol_index];
            const char* name = module->dynamic_info.str_table + symbol.st_name;
            const VAddr target = module->GetBaseAddress() + rel->rel_offset;
            u64 value{};
            std::memcpy(&value, reinterpret_cast<const void*>(target), sizeof(value));
            relocations.WriteString(
                fmt::format("0x{:<16x} 0x{:<16x} {:<5} {:<10} {:<8} {}\n", target, value,
                            rel->GetType(), module->TestRelaBit(bit_index) ? "resolved" : "stubbed",
                            is_jump ? "jump" : "regular", name));
        });
        if (elf.IsSelfFile()) {
            elf.SelfHeaderDebugDump(filepath / "selfHeader.txt");
            elf.SelfSegHeaderDebugDump(filepath / "selfSegHeaders.txt");
        }
        elf.ElfHeaderDebugDump(filepath / "elfHeader.txt");
        elf.PHeaderDebugDump(filepath / "elfPHeaders.txt");
    }
}

} // namespace Core
