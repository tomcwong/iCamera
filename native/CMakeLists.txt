cmake_minimum_required(VERSION 3.18)
project(icamera_native VERSION 1.0.0 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# ── Source files (paths relative to this CMakeLists.txt) ─────────────────────
set(NATIVE_SRCS
    image_pipeline.cpp
    lut_engine.cpp
    bokeh_kernel.cpp
    lens_sim.cpp
)

add_library(icamera_native SHARED ${NATIVE_SRCS})

# Export the C API header
target_include_directories(icamera_native PUBLIC ${CMAKE_CURRENT_SOURCE_DIR})

# ── Platform-specific linking ─────────────────────────────────────────────────
if(ANDROID)
    find_library(log-lib log)
    target_link_libraries(icamera_native ${log-lib})
endif()

# ── Compiler flags ───────────────────────────────────────────────────────────
# Note: -O3 / -ffast-math are already passed via build.gradle cppFlags for
# Android. We set them here too so cmake --build works standalone.
target_compile_options(icamera_native PRIVATE
    -O3
    -ffast-math
    -funroll-loops
    -fvisibility=hidden  # hide all symbols not marked extern "C"
)

# Ensure C functions are visible in the shared library
set_target_properties(icamera_native PROPERTIES
    CXX_VISIBILITY_PRESET hidden
    VISIBILITY_INLINES_HIDDEN YES
)
