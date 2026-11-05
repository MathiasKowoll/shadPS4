// SPDX-FileCopyrightText: Copyright 2022 Kyty contributors
// SPDX-FileCopyrightText: Copyright 2026 shadPS4 Emulator Project
// SPDX-License-Identifier: GPL-2.0-or-later

#include <cstring>
#include <map>
#include <mutex>
#include <string>
#include <vector>

#include <nlohmann/json.hpp>

#include "common/logging/log.h"
#include "core/libraries/json/json.h"
#include "core/libraries/libs.h"

namespace Libraries::Json {
namespace {

constexpr s32 ORBIS_JSON_ERROR_PARSE_INVALID_CHARACTER = static_cast<s32>(0x80848101);
constexpr s32 ORBIS_JSON_ERROR_INVALID_ARGUMENT = static_cast<s32>(0x80848120);

struct StringStorage {
    std::string text;
};

struct ArrayStorage {
    std::vector<Value*> values;
};

struct ObjectStorage {
    std::map<std::string, Value*> values;
};

std::recursive_mutex g_json_mutex;

StringStorage* StringImpl(String* value) {
    return value == nullptr ? nullptr : reinterpret_cast<StringStorage**>(value)[0];
}

const StringStorage* StringImpl(const String* value) {
    static const StringStorage empty;
    if (value == nullptr) {
        return &empty;
    }
    const auto* impl = reinterpret_cast<StringStorage* const*>(value)[0];
    return impl == nullptr ? &empty : impl;
}

void SetStringImpl(String* value, StringStorage* impl) {
    reinterpret_cast<StringStorage**>(value)[0] = impl;
}

ArrayStorage* ArrayImpl(Array* value) {
    return value == nullptr ? nullptr : reinterpret_cast<ArrayStorage**>(value)[0];
}

const ArrayStorage* ArrayImpl(const Array* value) {
    static const ArrayStorage empty;
    if (value == nullptr) {
        return &empty;
    }
    const auto* impl = reinterpret_cast<ArrayStorage* const*>(value)[0];
    return impl == nullptr ? &empty : impl;
}

void SetArrayImpl(Array* value, ArrayStorage* impl) {
    reinterpret_cast<ArrayStorage**>(value)[0] = impl;
}

ObjectStorage* ObjectImpl(Object* value) {
    return value == nullptr ? nullptr : reinterpret_cast<ObjectStorage**>(value)[0];
}

void SetObjectImpl(Object* value, ObjectStorage* impl) {
    reinterpret_cast<ObjectStorage**>(value)[0] = impl;
}

void InitializeValue(Value* value) {
    if (value != nullptr) {
        std::memset(value, 0, sizeof(*value));
        value->type = ValueType::Null;
    }
}

Value* NewValue() {
    auto* value = new Value;
    InitializeValue(value);
    return value;
}

String* NewString(std::string text) {
    auto* value =
        reinterpret_cast<String*>(new StringStorage* {new StringStorage{std::move(text)}});
    return value;
}

Array* NewArray() {
    return reinterpret_cast<Array*>(new ArrayStorage* {new ArrayStorage});
}

Object* NewObject() {
    return reinterpret_cast<Object*>(new ObjectStorage* {new ObjectStorage});
}

void DeleteString(String* value) {
    if (value != nullptr) {
        delete StringImpl(value);
        delete reinterpret_cast<StringStorage**>(value);
    }
}

void ClearValue(Value* value);

void ReparentChildren(Value* value) {
    if (value == nullptr) {
        return;
    }
    if (value->type == ValueType::Array) {
        if (auto* impl = ArrayImpl(value->array); impl != nullptr) {
            for (auto* child : impl->values) {
                child->parent = value;
                ReparentChildren(child);
            }
        }
    } else if (value->type == ValueType::Object && value->object != nullptr) {
        if (auto* impl = reinterpret_cast<ObjectStorage**>(value->object)[0]; impl != nullptr) {
            for (auto& [key, child] : impl->values) {
                child->parent = value;
                ReparentChildren(child);
            }
        }
    }
}

void DeleteValue(Value* value) {
    if (value != nullptr) {
        ClearValue(value);
        delete value;
    }
}

void DeleteArray(Array* value) {
    if (value == nullptr) {
        return;
    }
    if (auto* impl = ArrayImpl(value); impl != nullptr) {
        for (auto* child : impl->values) {
            DeleteValue(child);
        }
        delete impl;
    }
    delete reinterpret_cast<ArrayStorage**>(value);
}

void DeleteObject(Object* value) {
    if (value == nullptr) {
        return;
    }
    if (auto* impl = ObjectImpl(value); impl != nullptr) {
        for (auto& [key, child] : impl->values) {
            DeleteValue(child);
        }
        delete impl;
    }
    delete reinterpret_cast<ObjectStorage**>(value);
}

void ClearValue(Value* value) {
    if (value == nullptr) {
        return;
    }
    switch (value->type) {
    case ValueType::String:
        DeleteString(value->string);
        break;
    case ValueType::Array:
        DeleteArray(value->array);
        break;
    case ValueType::Object:
        DeleteObject(value->object);
        break;
    default:
        break;
    }
    InitializeValue(value);
}

bool BuildValue(Value* destination, const nlohmann::json& source) {
    if (destination == nullptr) {
        return false;
    }
    if (source.is_null()) {
        return true;
    }
    if (source.is_boolean()) {
        destination->type = ValueType::Boolean;
        destination->boolean = source.get<bool>();
        return true;
    }
    if (source.is_number_unsigned()) {
        destination->type = ValueType::UInteger;
        destination->uinteger = source.get<u64>();
        return true;
    }
    if (source.is_number_integer()) {
        destination->type = ValueType::Integer;
        destination->integer = source.get<s64>();
        return true;
    }
    if (source.is_number_float()) {
        destination->type = ValueType::Real;
        destination->real = source.get<double>();
        return true;
    }
    if (source.is_string()) {
        destination->type = ValueType::String;
        destination->string = NewString(source.get<std::string>());
        return true;
    }
    if (source.is_array()) {
        destination->type = ValueType::Array;
        destination->array = NewArray();
        auto* impl = ArrayImpl(destination->array);
        for (const auto& item : source) {
            auto* child = NewValue();
            child->parent = destination;
            if (!BuildValue(child, item)) {
                DeleteValue(child);
                return false;
            }
            impl->values.push_back(child);
        }
        return true;
    }
    if (source.is_object()) {
        destination->type = ValueType::Object;
        destination->object = NewObject();
        auto* impl = ObjectImpl(destination->object);
        for (const auto& [key, item] : source.items()) {
            auto* child = NewValue();
            child->parent = destination;
            if (!BuildValue(child, item)) {
                DeleteValue(child);
                return false;
            }
            impl->values.emplace(key, child);
        }
        return true;
    }
    return false;
}

Value* NullValue() {
    static Value value{};
    return &value;
}

String* EmptyString() {
    static String* value = NewString({});
    return value;
}

Array* EmptyArray() {
    static Array* value = NewArray();
    return value;
}

void PS4_SYSV_ABI InitializerConstruct(void*) {}
void PS4_SYSV_ABI InitializerDestruct(void*) {}
s32 PS4_SYSV_ABI InitializerInitialize(void*, const void*) {
    return 0;
}

void PS4_SYSV_ABI MemAllocatorConstruct(void*) {}
void PS4_SYSV_ABI MemAllocatorDestruct(void*) {}
void PS4_SYSV_ABI MemAllocatorNotifyError(void*, s32 error, u64 size, void* context) {
    LOG_WARNING(Lib_Json, "JSON allocator error {:#x}, size {}, context {}", error, size, context);
}

void PS4_SYSV_ABI ValueSetNullAccessCallback(void*, void*, void*) {
    // Missing members retain the firmware default: a shared null Value. A callback can be added
    // once its invocation contract is verified independently of a title.
}

} // namespace

void PS4_SYSV_ABI ValueConstruct(Value* self) {
    std::scoped_lock lock{g_json_mutex};
    InitializeValue(self);
}

void PS4_SYSV_ABI ValueDestruct(Value* self) {
    std::scoped_lock lock{g_json_mutex};
    ClearValue(self);
}

void PS4_SYSV_ABI ValueClear(Value* self) {
    std::scoped_lock lock{g_json_mutex};
    ClearValue(self);
}

ValueType PS4_SYSV_ABI ValueGetType(const Value* self) {
    std::scoped_lock lock{g_json_mutex};
    return self == nullptr ? ValueType::Null : self->type;
}

const bool* PS4_SYSV_ABI ValueGetBoolean(const Value* self) {
    std::scoped_lock lock{g_json_mutex};
    static const bool zero{};
    return self != nullptr && self->type == ValueType::Boolean ? &self->boolean : &zero;
}

const s64* PS4_SYSV_ABI ValueGetInteger(const Value* self) {
    std::scoped_lock lock{g_json_mutex};
    static const s64 zero{};
    return self != nullptr &&
                   (self->type == ValueType::Integer || self->type == ValueType::UInteger)
               ? &self->integer
               : &zero;
}

const u64* PS4_SYSV_ABI ValueGetUInteger(const Value* self) {
    std::scoped_lock lock{g_json_mutex};
    static const u64 zero{};
    return self != nullptr &&
                   (self->type == ValueType::Integer || self->type == ValueType::UInteger)
               ? &self->uinteger
               : &zero;
}

s32 PS4_SYSV_ABI ValueCount(const Value* self) {
    std::scoped_lock lock{g_json_mutex};
    if (self == nullptr) {
        return 0;
    }
    if (self->type == ValueType::Array) {
        return static_cast<s32>(ArrayImpl(self->array)->values.size());
    }
    if (self->type == ValueType::Object) {
        const auto* impl = self->object == nullptr
                               ? nullptr
                               : reinterpret_cast<ObjectStorage* const*>(self->object)[0];
        return impl == nullptr ? 0 : static_cast<s32>(impl->values.size());
    }
    return 0;
}

const String* PS4_SYSV_ABI ValueGetString(const Value* self) {
    std::scoped_lock lock{g_json_mutex};
    return self != nullptr && self->type == ValueType::String ? self->string : EmptyString();
}

const Array* PS4_SYSV_ABI ValueGetArray(const Value* self) {
    std::scoped_lock lock{g_json_mutex};
    return self != nullptr && self->type == ValueType::Array ? self->array : EmptyArray();
}

const Value* PS4_SYSV_ABI ValueIndex(const Value* self, u64 index) {
    std::scoped_lock lock{g_json_mutex};
    if (self == nullptr || self->type != ValueType::Array) {
        return NullValue();
    }
    const auto* impl = ArrayImpl(self->array);
    return index < impl->values.size() ? impl->values[index] : NullValue();
}

const Value* PS4_SYSV_ABI ValueMember(const Value* self, const char* key) {
    std::scoped_lock lock{g_json_mutex};
    if (self == nullptr || self->type != ValueType::Object || key == nullptr ||
        self->object == nullptr) {
        return NullValue();
    }
    const auto* impl = reinterpret_cast<ObjectStorage* const*>(self->object)[0];
    if (impl == nullptr) {
        return NullValue();
    }
    const auto it = impl->values.find(key);
    return it == impl->values.end() ? NullValue() : it->second;
}

const char* PS4_SYSV_ABI StringCStr(const String* self) {
    std::scoped_lock lock{g_json_mutex};
    return StringImpl(self)->text.c_str();
}

ArrayIterator* PS4_SYSV_ABI ArrayBegin(ArrayIterator* result, const Array* self) {
    std::scoped_lock lock{g_json_mutex};
    const auto* impl = ArrayImpl(self);
    result->position = impl->values.data();
    return result;
}

ArrayIterator* PS4_SYSV_ABI ArrayEnd(ArrayIterator* result, const Array* self) {
    std::scoped_lock lock{g_json_mutex};
    const auto* impl = ArrayImpl(self);
    result->position = impl->values.data() + impl->values.size();
    return result;
}

void PS4_SYSV_ABI ArrayIteratorDestruct(ArrayIterator*) {}

ArrayIterator* PS4_SYSV_ABI ArrayIteratorIncrement(ArrayIterator* self) {
    ++self->position;
    return self;
}

Value* PS4_SYSV_ABI ArrayIteratorDereference(const ArrayIterator* self) {
    return self == nullptr || self->position == nullptr ? NullValue() : *self->position;
}

bool PS4_SYSV_ABI ArrayIteratorNotEqual(const ArrayIterator* self, const ArrayIterator* other) {
    return self != nullptr && other != nullptr && self->position != other->position;
}

s32 PS4_SYSV_ABI ParserParse(Value* destination, const char* source, u64 size) {
    std::scoped_lock lock{g_json_mutex};
    if (destination == nullptr || source == nullptr) {
        return ORBIS_JSON_ERROR_INVALID_ARGUMENT;
    }

    const auto parsed = nlohmann::json::parse(source, source + size, nullptr, false, true);
    if (parsed.is_discarded()) {
        LOG_WARNING(Lib_Json, "JSON parse failed for {} bytes", size);
        return ORBIS_JSON_ERROR_PARSE_INVALID_CHARACTER;
    }

    Value replacement{};
    InitializeValue(&replacement);
    if (!BuildValue(&replacement, parsed)) {
        ClearValue(&replacement);
        return ORBIS_JSON_ERROR_PARSE_INVALID_CHARACTER;
    }
    ClearValue(destination);
    std::memcpy(destination, &replacement, sizeof(*destination));
    ReparentChildren(destination);
    LOG_DEBUG(Lib_Json, "Parsed {} JSON bytes into root type {}", size,
              static_cast<u32>(destination->type));
    return 0;
}

void RegisterLib(Core::Loader::SymbolsResolver* sym) {
    LIB_FUNCTION("cK6bYHf-Q5E", "libSceJson2", 1, "libSceJson", InitializerConstruct);
    LIB_FUNCTION("RujUxbr3haM", "libSceJson2", 1, "libSceJson", InitializerDestruct);
    LIB_FUNCTION("Cxwy7wHq4J0", "libSceJson2", 1, "libSceJson", InitializerInitialize);
    LIB_FUNCTION("-hJRce8wn1U", "libSceJson2", 1, "libSceJson", MemAllocatorConstruct);
    LIB_FUNCTION("OcAgPxcq5Vk", "libSceJson2", 1, "libSceJson", MemAllocatorDestruct);
    LIB_FUNCTION("i-XwZjw0OOY", "libSceJson2", 1, "libSceJson", MemAllocatorNotifyError);
    LIB_FUNCTION("qBMjqyBn3OM", "libSceJson2", 1, "libSceJson", ValueConstruct);
    LIB_FUNCTION("WTtYf+cNnXI", "libSceJson2", 1, "libSceJson", ValueDestruct);
    LIB_FUNCTION("FIjXN2TkuTs", "libSceJson2", 1, "libSceJson", ValueClear);
    LIB_FUNCTION("Xbl-LYVFNEE", "libSceJson2", 1, "libSceJson", ValueSetNullAccessCallback);
    LIB_FUNCTION("zTwZdI8AZ5Y", "libSceJson2", 1, "libSceJson", ValueGetBoolean);
    LIB_FUNCTION("DIxvoy7Ngvk", "libSceJson2", 1, "libSceJson", ValueGetInteger);
    LIB_FUNCTION("sn4HNCtNRzY", "libSceJson2", 1, "libSceJson", ValueGetUInteger);
    LIB_FUNCTION("RBw+4NukeGQ", "libSceJson2", 1, "libSceJson", ValueCount);
    LIB_FUNCTION("SHtAad20YYM", "libSceJson2", 1, "libSceJson", ValueGetType);
    LIB_FUNCTION("epJ6x2LV0kU", "libSceJson2", 1, "libSceJson", ValueGetString);
    LIB_FUNCTION("ONT8As5R1ug", "libSceJson2", 1, "libSceJson", ValueGetArray);
    LIB_FUNCTION("HwDt5lD9Bfo", "libSceJson2", 1, "libSceJson", ValueMember);
    LIB_FUNCTION("XlWbvieLj2M", "libSceJson2", 1, "libSceJson", ValueIndex);
    LIB_FUNCTION("L1KAkYWml-M", "libSceJson2", 1, "libSceJson", StringCStr);
    LIB_FUNCTION("bcH5EnFE2xY", "libSceJson2", 1, "libSceJson", ArrayBegin);
    LIB_FUNCTION("WXF2ihRF+B8", "libSceJson2", 1, "libSceJson", ArrayEnd);
    LIB_FUNCTION("9yLjn46Ypfs", "libSceJson2", 1, "libSceJson", ArrayIteratorDestruct);
    LIB_FUNCTION("w5+VCznos5E", "libSceJson2", 1, "libSceJson", ArrayIteratorIncrement);
    LIB_FUNCTION("wcgr5mte7T8", "libSceJson2", 1, "libSceJson", ArrayIteratorDereference);
    LIB_FUNCTION("5AZPp99ogrc", "libSceJson2", 1, "libSceJson", ArrayIteratorNotEqual);
    LIB_FUNCTION("S5JxQnoGF3E", "libSceJson2", 1, "libSceJson", ParserParse);
}

} // namespace Libraries::Json
