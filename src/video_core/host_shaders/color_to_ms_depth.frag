// SPDX-FileCopyrightText: Copyright 2024 shadPS4 Emulator Project
// SPDX-License-Identifier: GPL-2.0-or-later

#version 450 core
#extension GL_EXT_samplerless_texture_functions : require

#if defined(SRC_MSAA)
layout (binding = 0, set = 0) uniform texture2DMS color;
#else
layout (binding = 0, set = 0) uniform texture2D color;
#endif

layout (location = 0) in vec2 uv;

void main()
{
#if defined(SRC_MSAA)
    gl_FragDepth = texelFetch(color, ivec2(gl_FragCoord.xy), gl_SampleID).x;
#else
    ivec2 coord = ivec2(uv * vec2(textureSize(color, 0).xy));
    gl_FragDepth = texelFetch(color, coord, 0)[gl_SampleID];
#endif
}
