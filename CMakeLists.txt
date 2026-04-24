cmake_minimum_required(VERSION 3.20)
project(NppAIAssistant LANGUAGES CXX OBJCXX)

# Mirror the shared macOS-plugin build target: C++17, hidden visibility,
# universal arm64+x86_64, deployment target 11.0.
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_OBJCXX_STANDARD 17)
set(CMAKE_CXX_VISIBILITY_PRESET hidden)
set(CMAKE_OSX_DEPLOYMENT_TARGET "11.0")
set(CMAKE_OSX_ARCHITECTURES "arm64;x86_64")

if(NOT CMAKE_BUILD_TYPE)
    set(CMAKE_BUILD_TYPE Release CACHE STRING "" FORCE)
endif()

# Matches NppLLM / NppBeads layout: the host repo sits next to this
# plugin repo under `notepad-plus-plus-macos/`; the Windows upstream
# sits next to both under `notepad-plus-plus/` for the vendored
# Scintilla headers.
set(NPP_MACOS_DIR      "${CMAKE_SOURCE_DIR}/../../notepad-plus-plus-macos")
set(NPP_WIN_DIR        "${CMAKE_SOURCE_DIR}/../../notepad-plus-plus")
set(SCINTILLA_INCLUDE  "${NPP_WIN_DIR}/scintilla/include")
set(NPP_PLUGIN_INCLUDE "${NPP_MACOS_DIR}/src")

add_library(NppAIAssistant SHARED
    # ── Plugin ABI + command dispatch ──
    src/PluginMain.mm

    # ── Pure C++ foundations ──
    src/PromptBuilder.cpp

    # ── Preferences & secure storage ──
    src/Preferences.mm
    src/Keychain.mm

    # ── Editor (Scintilla) + HTTP ──
    src/EditorHelpers.mm
    src/HTTPClient.mm

    # ── Provider API clients ──
    src/ApiClient.mm

    # ── UI ──
    src/AssistantPanelView.mm
    src/SettingsWindowController.mm

    # ── Copilot OAuth device-code flow ──
    src/CopilotAuth.mm
)

target_include_directories(NppAIAssistant PRIVATE
    ${NPP_PLUGIN_INCLUDE}
    ${SCINTILLA_INCLUDE}
    src)

target_link_libraries(NppAIAssistant PRIVATE
    "-framework Cocoa"
    "-framework Security")   # Keychain (SecItemAdd/Copy/Update/Delete)

target_compile_options(NppAIAssistant PRIVATE
    -Wall -Wno-unused-parameter
    -fvisibility=hidden
    $<$<COMPILE_LANGUAGE:OBJCXX>:-fobjc-arc>)

set_target_properties(NppAIAssistant PROPERTIES
    PREFIX ""
    SUFFIX ".dylib")

# Install into the user's plugin folder so a fresh build is immediately
# picked up by the running host.
set(PLUGIN_INSTALL_DIR "$ENV{HOME}/.notepad++/plugins/NppAIAssistant")
install(TARGETS NppAIAssistant DESTINATION "${PLUGIN_INSTALL_DIR}")

# NPPM_ADDTOOLBARICON_FORDARKMODE looks for `<plugin dir>/toolbar.png`
# when no explicit path is given (NppPluginManager.mm fallback).
install(FILES resources/toolbar.png DESTINATION "${PLUGIN_INSTALL_DIR}")

install(DIRECTORY resources/ DESTINATION "${PLUGIN_INSTALL_DIR}/resources"
    PATTERN ".DS_Store" EXCLUDE)
