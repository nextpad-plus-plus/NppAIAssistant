/**
 * EditorHelpers.mm — implementation.
 *
 * Ported from NppLLM's EditorHelpers, trimmed to the subset this plugin
 * needs (no streaming primitives — NppAIAssistant is non-streaming).
 */
#import <Foundation/Foundation.h>

#include "EditorHelpers.h"

#include "NppPluginInterfaceMac.h"
#include "Scintilla.h"

namespace NppAIAssistant {

namespace {
    NppData g_npp = {};

    inline std::intptr_t scintillaSend(std::intptr_t sci, uint32_t msg,
                                       uintptr_t wParam, intptr_t lParam) {
        if (!g_npp._sendMessage || !sci) return 0;
        return g_npp._sendMessage(static_cast<NppHandle>(sci),
                                  msg, wParam, lParam);
    }
    inline std::intptr_t nppSend(uint32_t msg, uintptr_t wParam,
                                 intptr_t lParam) {
        if (!g_npp._sendMessage || !g_npp._nppHandle) return 0;
        return g_npp._sendMessage(g_npp._nppHandle, msg, wParam, lParam);
    }
}

void Editor::setNppData(const NppData& data) {
    g_npp = data;
}

std::string Editor::pluginConfigDir() {
    char buf[1024] = {0};
    nppSend(NPPM_GETPLUGINSCONFIGDIR, (uintptr_t)sizeof(buf), (intptr_t)buf);
    if (buf[0] != '\0') return std::string(buf);
    // Fallback only if the host returns empty (it does not on shipped versions):
    // the macOS app-support base, NOT a legacy ~/.nextpad++ dot-folder.
    NSString* dir = [NSHomeDirectory()
        stringByAppendingPathComponent:@"Library/Application Support/Nextpad++/plugins/Config"];
    return std::string([dir UTF8String]);
}

std::intptr_t Editor::current() {
    int which = -1;
    nppSend(NPPM_GETCURRENTSCINTILLA, 0, reinterpret_cast<intptr_t>(&which));
    if (which == 0) return static_cast<std::intptr_t>(g_npp._scintillaMainHandle);
    if (which == 1) return static_cast<std::intptr_t>(g_npp._scintillaSecondHandle);
    return static_cast<std::intptr_t>(g_npp._scintillaMainHandle);
}

std::intptr_t Editor::nppHandle() {
    return static_cast<std::intptr_t>(g_npp._nppHandle);
}

std::string Editor::getSelectedText(std::intptr_t sci) {
    if (!sci) return "";
    const sptr_t selStart = scintillaSend(sci, SCI_GETSELECTIONSTART, 0, 0);
    const sptr_t selEnd   = scintillaSend(sci, SCI_GETSELECTIONEND,   0, 0);
    if (selEnd <= selStart) return "";

    std::string buf(static_cast<size_t>(selEnd - selStart), '\0');
    Sci_TextRangeFull tr;
    tr.chrg.cpMin = selStart;
    tr.chrg.cpMax = selEnd;
    tr.lpstrText  = &buf[0];
    scintillaSend(sci, SCI_GETTEXTRANGEFULL, 0, reinterpret_cast<intptr_t>(&tr));
    return buf;
}

void Editor::replaceSelection(std::intptr_t sci, const std::string& text) {
    if (!sci) return;
    scintillaSend(sci, SCI_BEGINUNDOACTION, 0, 0);
    scintillaSend(sci, SCI_REPLACESEL, 0,
                  reinterpret_cast<intptr_t>(text.c_str()));
    scintillaSend(sci, SCI_ENDUNDOACTION, 0, 0);
}

void Editor::getSelectionRange(std::intptr_t sci,
                               std::intptr_t* outStart,
                               std::intptr_t* outEnd) {
    if (outStart) *outStart = scintillaSend(sci, SCI_GETSELECTIONSTART, 0, 0);
    if (outEnd)   *outEnd   = scintillaSend(sci, SCI_GETSELECTIONEND,   0, 0);
}

void Editor::setSelectionRange(std::intptr_t sci,
                               std::intptr_t start,
                               std::intptr_t end) {
    scintillaSend(sci, SCI_SETSEL, start, end);
}

}  // namespace NppAIAssistant
