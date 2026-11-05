// SPDX-FileCopyrightText: Copyright 2022 Kyty contributors
// SPDX-FileCopyrightText: Copyright 2026 shadPS4 Emulator Project
// SPDX-License-Identifier: GPL-2.0-or-later

#pragma once

#include <cstddef>

#include "common/types.h"

namespace Core::Loader {
class SymbolsResolver;
}

namespace Libraries::Json {

enum class ValueType : u32 {
    Null = 0,
    Boolean = 1,
    Integer = 2,
    UInteger = 3,
    Real = 4,
    String = 5,
    Array = 6,
    Object = 7,
};

struct String;
struct Array;
struct Object;

// The layout matches sce::Json::Value. Games allocate these objects themselves and may keep them
// in contiguous containers, so an out-of-line host-only representation is not ABI compatible.
struct Value {
    Value* parent;
    void* root_parameter;
    union {
        bool boolean;
        s64 integer;
        u64 uinteger;
        double real;
        String* string;
        Array* array;
        Object* object;
    };
    u32 padding;
    ValueType type;
};
static_assert(sizeof(Value) == 32);
static_assert(offsetof(Value, type) == 28);

struct ArrayIterator {
    Value* const* position;
};
static_assert(sizeof(ArrayIterator) == 8);

void PS4_SYSV_ABI ValueConstruct(Value* self);
void PS4_SYSV_ABI ValueDestruct(Value* self);
void PS4_SYSV_ABI ValueClear(Value* self);
ValueType PS4_SYSV_ABI ValueGetType(const Value* self);
const bool* PS4_SYSV_ABI ValueGetBoolean(const Value* self);
const s64* PS4_SYSV_ABI ValueGetInteger(const Value* self);
const u64* PS4_SYSV_ABI ValueGetUInteger(const Value* self);
s32 PS4_SYSV_ABI ValueCount(const Value* self);
const String* PS4_SYSV_ABI ValueGetString(const Value* self);
const Array* PS4_SYSV_ABI ValueGetArray(const Value* self);
const Value* PS4_SYSV_ABI ValueIndex(const Value* self, u64 index);
const Value* PS4_SYSV_ABI ValueMember(const Value* self, const char* key);
const char* PS4_SYSV_ABI StringCStr(const String* self);

ArrayIterator* PS4_SYSV_ABI ArrayBegin(ArrayIterator* result, const Array* self);
ArrayIterator* PS4_SYSV_ABI ArrayEnd(ArrayIterator* result, const Array* self);
void PS4_SYSV_ABI ArrayIteratorDestruct(ArrayIterator* self);
ArrayIterator* PS4_SYSV_ABI ArrayIteratorIncrement(ArrayIterator* self);
Value* PS4_SYSV_ABI ArrayIteratorDereference(const ArrayIterator* self);
bool PS4_SYSV_ABI ArrayIteratorNotEqual(const ArrayIterator* self, const ArrayIterator* other);

s32 PS4_SYSV_ABI ParserParse(Value* destination, const char* source, u64 size);

void RegisterLib(Core::Loader::SymbolsResolver* sym);

} // namespace Libraries::Json
