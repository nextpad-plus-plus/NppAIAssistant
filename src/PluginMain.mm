/**
 * PluginMain.mm — plugin ABI exports + command dispatch for the macOS
 * port of NppAIAssistant.
 *
 * Menu layout (matches the Windows screenshot):
 *   0. Open AI Assistant              ⌘⇧A  → cmdTogglePanel
 *   1. Explain Selection                    → cmdSelectionAction(Explain)
 *   2. Refactor Selection                   → cmdSelectionAction(Refactor)
 *   3. Add Comments to Selection            → cmdSelectionAction(AddComments)
 *   4. Fix Selection                        → cmdSelectionAction(Fix)
 *   5. Settings…                            → cmdOpenSettings
 *
 * The dock panel is registered with the host via NPPM_DMM_REGISTERPANEL
 * at NPPN_READY. The toolbar icon is attached to command 0.
 */
#import <Cocoa/Cocoa.h>

#include "NppPluginInterfaceMac.h"
#include "Scintilla.h"   // SCNotification definition

#include <cstring>
#include <cstdint>
#include <string>

#include "AssistantPanelView.h"
#include "EditorHelpers.h"
#include "Preferences.h"
#include "SettingsWindowController.h"

#if defined(__GNUC__)
#  define NPP_EXPORT __attribute__((visibility("default")))
#else
#  define NPP_EXPORT
#endif

namespace {

constexpr const char* kPluginName    = "NppAIAssistant";
constexpr const char* kPluginVersion = "1.0.0";
constexpr int         kNumFuncs      = 6;

NppData                    g_npp = {};
FuncItem                   g_funcs[kNumFuncs] = {};
ShortcutKey*               g_shortcutPrimary = nullptr;
std::intptr_t              g_panelHandle = 0;     // from NPPM_DMM_REGISTERPANEL
bool                       g_toolbarRegistered = false;

// --- Command stubs (defined below) -------------------------------------

static void cmdTogglePanel();
static void cmdExplainSelection();
static void cmdRefactorSelection();
static void cmdAddComments();
static void cmdFixSelection();
static void cmdOpenSettings();

// --- Helpers -----------------------------------------------------------

// Convenience: register/show the dock panel. Safe to call multiple
// times; NPPM_DMM_REGISTERPANEL returns the existing handle for a
// repeat with the same NSView.
void ensurePanelRegistered() {
    if (g_panelHandle) return;
    AssistantPanelView* view = [AssistantPanelView shared];
    const char* title = "AI Assistant";
    std::intptr_t handle = g_npp._sendMessage(g_npp._nppHandle,
        NPPM_DMM_REGISTERPANEL,
        reinterpret_cast<uintptr_t>((__bridge void*)view),
        reinterpret_cast<intptr_t>(title));
    if (handle) {
        g_panelHandle = handle;
        [view reloadFromPreferences];
    }
}

void showPanel() {
    ensurePanelRegistered();
    if (g_panelHandle) {
        g_npp._sendMessage(g_npp._nppHandle, NPPM_DMM_SHOWPANEL,
                           static_cast<uintptr_t>(g_panelHandle), 0);
    }
}

// Selection-action entry point shared by the four action commands.
void runActionOnCurrentSelection(NppAIAction action) {
    ensurePanelRegistered();
    std::intptr_t sci = NppAIAssistant::Editor::current();
    std::string sel = NppAIAssistant::Editor::getSelectedText(sci);
    if (sel.empty()) {
        NSAlert* a = [[NSAlert alloc] init];
        a.messageText     = @"NppAIAssistant";
        a.informativeText = @"Select some text first — this action operates on the current selection.";
        [a runModal];
        return;
    }
    NSString* text = [NSString stringWithUTF8String:sel.c_str()] ?: @"";
    [[AssistantPanelView shared] runSelectionAction:action
                                      selectionText:text
                                       editorHandle:sci];
    showPanel();
}

// --- ABI exports --------------------------------------------------------

}  // namespace

extern "C" NPP_EXPORT const char* getName(void) {
    return kPluginName;
}

extern "C" NPP_EXPORT void setInfo(NppData data) {
    g_npp = data;
    NppAIAssistant::Editor::setNppData(data);

    // Seed the Preferences file on first run so the user can inspect it.
    (void)NppAIAssistant::Preferences::load();

    auto setItem = [&](int i, const char* name, PFUNCPLUGINCMD fn,
                       ShortcutKey* sk, bool initialCheck) {
        std::strncpy(g_funcs[i]._itemName, name, NPP_MENU_ITEM_SIZE - 1);
        g_funcs[i]._itemName[NPP_MENU_ITEM_SIZE - 1] = '\0';
        g_funcs[i]._pFunc      = fn;
        g_funcs[i]._pShKey     = sk;
        g_funcs[i]._init2Check = initialCheck;
    };

    // ⌘⇧A for the primary command. Windows has no shortcut — mac users
    // expect a keyboard path for dock panels, and A doesn't clash with
    // host defaults.
    g_shortcutPrimary = new ShortcutKey{};
    g_shortcutPrimary->_isCmd   = true;
    g_shortcutPrimary->_isShift = true;
    g_shortcutPrimary->_key     = 0x41;  // 'A'

    setItem(0, "Open AI Assistant",           cmdTogglePanel,      g_shortcutPrimary, false);
    setItem(1, "Explain Selection",           cmdExplainSelection, nullptr, false);
    setItem(2, "Refactor Selection",          cmdRefactorSelection,nullptr, false);
    setItem(3, "Add Comments to Selection",   cmdAddComments,      nullptr, false);
    setItem(4, "Fix Selection",               cmdFixSelection,     nullptr, false);
    setItem(5, "Settings…",              cmdOpenSettings,     nullptr, false);
}

extern "C" NPP_EXPORT FuncItem* getFuncsArray(int* nbF) {
    if (nbF) *nbF = kNumFuncs;
    return g_funcs;
}

extern "C" NPP_EXPORT void beNotified(SCNotification* n) {
    if (!n) return;
    switch (n->nmhdr.code) {
        case NPPN_READY:
            // Register the dock panel + attach the toolbar icon now that
            // the host has assigned cmdIDs to our FuncItems.
            ensurePanelRegistered();
            if (!g_toolbarRegistered && g_funcs[0]._cmdID != 0) {
                g_npp._sendMessage(g_npp._nppHandle,
                                   NPPM_ADDTOOLBARICON_FORDARKMODE,
                                   static_cast<uintptr_t>(g_funcs[0]._cmdID),
                                   0);
                g_toolbarRegistered = true;
            }
            break;
        case NPPN_SHUTDOWN:
            if (g_panelHandle) {
                g_npp._sendMessage(g_npp._nppHandle,
                                   NPPM_DMM_UNREGISTERPANEL,
                                   static_cast<uintptr_t>(g_panelHandle),
                                   0);
                g_panelHandle = 0;
            }
            break;
        default:
            break;
    }
}

extern "C" NPP_EXPORT LRESULT messageProc(UINT, WPARAM, LPARAM) {
    return TRUE;
}

extern "C" NPP_EXPORT BOOL isUnicode(void) {
    return TRUE;
}

// --- Command implementations -------------------------------------------

namespace {

void cmdTogglePanel() {
    // Simple toggle: if registered + visible, hide; otherwise show. The
    // host's SHOW/HIDE messages are idempotent so either pattern works.
    // We don't track visibility ourselves; HIDE-on-hidden is a no-op.
    ensurePanelRegistered();
    if (!g_panelHandle) return;
    AssistantPanelView* view = [AssistantPanelView shared];
    if (view.window && view.window.isVisible) {
        g_npp._sendMessage(g_npp._nppHandle, NPPM_DMM_HIDEPANEL,
                           static_cast<uintptr_t>(g_panelHandle), 0);
    } else {
        g_npp._sendMessage(g_npp._nppHandle, NPPM_DMM_SHOWPANEL,
                           static_cast<uintptr_t>(g_panelHandle), 0);
    }
}

void cmdExplainSelection()   { runActionOnCurrentSelection(NppAIActionExplain); }
void cmdRefactorSelection()  { runActionOnCurrentSelection(NppAIActionRefactor); }
void cmdAddComments()        { runActionOnCurrentSelection(NppAIActionAddComments); }
void cmdFixSelection()       { runActionOnCurrentSelection(NppAIActionFix); }

void cmdOpenSettings() {
    [SettingsWindowController presentFromWindow:NSApp.mainWindow];
}

}  // namespace
