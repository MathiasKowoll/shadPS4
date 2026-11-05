// SPDX-FileCopyrightText: Copyright 2026 shadPS4 Emulator Project
// SPDX-License-Identifier: GPL-2.0-or-later

#include <cstring>

#include <gtest/gtest.h>

#include "core/libraries/json/json.h"

namespace Libraries::Json {
namespace {

TEST(JsonTest, ParsesNestedValuesWithFirmwareAbiLayout) {
    constexpr char text[] = R"({"enabled":true,"count":42,"name":"menu","items":[1,2,3]})";
    Value root{};
    ValueConstruct(&root);

    ASSERT_EQ(ParserParse(&root, text, std::strlen(text)), 0);
    EXPECT_EQ(ValueGetType(&root), ValueType::Object);
    EXPECT_EQ(*ValueGetBoolean(ValueMember(&root, "enabled")), true);
    EXPECT_EQ(*ValueGetUInteger(ValueMember(&root, "count")), 42u);
    EXPECT_STREQ(StringCStr(ValueGetString(ValueMember(&root, "name"))), "menu");

    const Value* items = ValueMember(&root, "items");
    ASSERT_EQ(ValueGetType(items), ValueType::Array);
    ASSERT_EQ(ValueCount(items), 3);
    EXPECT_EQ(*ValueGetUInteger(ValueIndex(items, 1)), 2u);

    ValueDestruct(&root);
}

TEST(JsonTest, ArrayIteratorUsesTheGuestSretAbi) {
    constexpr char text[] = R"(["first","second"])";
    Value root{};
    ValueConstruct(&root);
    ASSERT_EQ(ParserParse(&root, text, std::strlen(text)), 0);

    ArrayIterator current{};
    ArrayIterator end{};
    ASSERT_EQ(ArrayBegin(&current, ValueGetArray(&root)), &current);
    ASSERT_EQ(ArrayEnd(&end, ValueGetArray(&root)), &end);
    ASSERT_TRUE(ArrayIteratorNotEqual(&current, &end));
    EXPECT_STREQ(StringCStr(ValueGetString(ArrayIteratorDereference(&current))), "first");
    ArrayIteratorIncrement(&current);
    EXPECT_STREQ(StringCStr(ValueGetString(ArrayIteratorDereference(&current))), "second");
    ArrayIteratorIncrement(&current);
    EXPECT_FALSE(ArrayIteratorNotEqual(&current, &end));

    ValueDestruct(&root);
}

TEST(JsonTest, InvalidInputPreservesThePreviousValue) {
    constexpr char valid[] = R"({"name":"kept"})";
    constexpr char invalid[] = "{not-json";
    Value root{};
    ValueConstruct(&root);
    ASSERT_EQ(ParserParse(&root, valid, std::strlen(valid)), 0);

    EXPECT_NE(ParserParse(&root, invalid, std::strlen(invalid)), 0);
    EXPECT_STREQ(StringCStr(ValueGetString(ValueMember(&root, "name"))), "kept");

    ValueDestruct(&root);
}

} // namespace
} // namespace Libraries::Json
