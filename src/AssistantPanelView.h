/**
 * AssistantPanelView.h — the dock panel NSView.
 *
 * Created lazily on first use by PluginMain.showPanel. Registered with
 * the host via NPPM_DMM_REGISTERPANEL; the host strong-retains the
 * view, so the singleton-style getter keeps a weak reference.
 */
#import <Cocoa/Cocoa.h>

#include <string>

#include "Preferences.h"

NS_ASSUME_NONNULL_BEGIN

// Actions initiated from the main menu or Scintilla context menu.
// Mirror the Windows SelectionAction enum.
typedef NS_ENUM(NSInteger, NppAIAction) {
    NppAIActionNone          = 0,
    NppAIActionExplain       = 1,  // show reply in panel only
    NppAIActionRefactor      = 2,  // replace selection with reply
    NppAIActionAddComments   = 3,  // replace selection with reply
    NppAIActionFix           = 4,  // replace selection with reply
};

@interface AssistantPanelView : NSView

// Shared instance. Created on first access.
+ (instancetype)shared;

// Applied after load and after Settings → OK. Re-reads the current
// settings into the UI (provider combo selection, model list, …).
- (void)reloadFromPreferences;

// Kick off a selection-driven action. Sets up the prompt, pushes a
// chat entry, and ships it to the ApiClient; caller should ensure the
// panel is visible first.
- (void)runSelectionAction:(NppAIAction)action
               selectionText:(NSString*)selectionText
                 editorHandle:(std::intptr_t)sci;

// Clears the in-memory chat history.
- (void)clearConversation;

@end

NS_ASSUME_NONNULL_END
