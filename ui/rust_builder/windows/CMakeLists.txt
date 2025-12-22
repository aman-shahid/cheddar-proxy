# The Flutter tooling requires that developers have a version of Visual Studio
# installed that includes CMake 3.14 or later. You should not increase this
# version, as doing so will cause the plugin to fail to compile for some
# customers of the plugin.
cmake_minimum_required(VERSION 3.14)

# Project-level configuration.
set(PROJECT_NAME "rust_lib_cheddarproxy")
project(${PROJECT_NAME} LANGUAGES CXX)

# Check for pre-built DLL from cargo build (debug or release)
set(PREBUILT_DLL_DEBUG "${CMAKE_CURRENT_SOURCE_DIR}/../../../../../../../core/target/debug/rust_lib_cheddarproxy.dll")
set(PREBUILT_DLL_RELEASE "${CMAKE_CURRENT_SOURCE_DIR}/../../../../../../../core/target/release/rust_lib_cheddarproxy.dll")
get_filename_component(PREBUILT_DLL_DEBUG "${PREBUILT_DLL_DEBUG}" ABSOLUTE)
get_filename_component(PREBUILT_DLL_RELEASE "${PREBUILT_DLL_RELEASE}" ABSOLUTE)

# Prefer debug DLL for development, fall back to release
if(EXISTS "${PREBUILT_DLL_DEBUG}")
  set(PREBUILT_DLL "${PREBUILT_DLL_DEBUG}")
elseif(EXISTS "${PREBUILT_DLL_RELEASE}")
  set(PREBUILT_DLL "${PREBUILT_DLL_RELEASE}")
else()
  set(PREBUILT_DLL "")
endif()

if(NOT "${PREBUILT_DLL}" STREQUAL "")
  message(STATUS "Using pre-built Rust library: ${PREBUILT_DLL}")
  
  # Copy pre-built DLL to output directory
  if (CMAKE_CONFIGURATION_TYPES)
    set(OUTPUT_DIR "${CMAKE_CURRENT_BINARY_DIR}/$<CONFIG>")
  else()
    set(OUTPUT_DIR "${CMAKE_CURRENT_BINARY_DIR}")
  endif()
  
  set(OUTPUT_LIB "${OUTPUT_DIR}/rust_lib_cheddarproxy.dll")
  
  add_custom_command(
    OUTPUT "${OUTPUT_LIB}"
    COMMAND ${CMAKE_COMMAND} -E make_directory "${OUTPUT_DIR}"
    COMMAND ${CMAKE_COMMAND} -E copy "${PREBUILT_DLL}" "${OUTPUT_LIB}"
    DEPENDS "${PREBUILT_DLL}"
    COMMENT "Copying pre-built rust_lib_cheddarproxy.dll"
    VERBATIM
  )
  
  add_custom_target("${PROJECT_NAME}_cargokit" ALL DEPENDS "${OUTPUT_LIB}")
  
  set(rust_lib_cheddarproxy_bundled_libraries
    "${OUTPUT_LIB}"
    PARENT_SCOPE
  )
else()
  message(STATUS "Pre-built DLL not found, using Cargokit to build")
  include("../cargokit/cmake/cargokit.cmake")
  apply_cargokit(${PROJECT_NAME} ../../../../../../../core rust_lib_cheddarproxy "")

  # List of absolute paths to libraries that should be bundled with the plugin.
  set(rust_lib_cheddarproxy_bundled_libraries
    "${${PROJECT_NAME}_cargokit_lib}"
    PARENT_SCOPE
  )
endif()
