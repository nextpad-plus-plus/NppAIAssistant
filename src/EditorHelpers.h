/**
 * EditorHelpers.h — Scintilla operations the plugin needs, wrapped in
 * thin C++ helpers. All calls go through NppData._sendMessage which
 * the macOS host hands us at setInfo time; we never touch the
 * ScintillaView directly.
 *
 * Main-thread only. Background work (HTTP callbacks) MUST dispatch
 * back to the main thread before invoking these.
 */
#ifndef NPPAIASSISTANT_EDITOR_HELPERS_H
#define NPPAIASSISTANT_EDITOR_HELPERS_H

#include <cstdint>
#include <string>

struct NppData;

namespace NppAIAssistant {

class Editor {
public:
    // Called once at setInfo; stores a copy of NppData internally.
    static void setNppData(const NppData& data);

    // Handle of the Scintilla view that currently has focus (main or
    // secondary). 0 if no editor is active.
    static std::intptr_t current();

    // Npp main-window handle. Used by NPPM_* messages.
    static std::intptr_t nppHandle();

    // Full text currently selected in `sci`. Empty if no selection.
    static std::string getSelectedText(std::intptr_t sci);

    // Replace the current selection (or insert at caret if none) with
    // `text`. Wraps the edit in a single undo group.
    static void replaceSelection(std::intptr_t sci, const std::string& text);

    // Position range helpers used by the selection-action workflow to
    // restore the caret after a replace-selection reply arrives.
    static void getSelectionRange(std::intptr_t sci,
                                  std::intptr_t* outStart,
                                  std::intptr_t* outEnd);
    static void setSelectionRange(std::intptr_t sci,
                                  std::intptr_t start,
                                  std::intptr_t end);
};

}  // namespace NppAIAssistant

#endif
