/**
 * AssistantPanelView.mm — the dock-panel UI.
 *
 * Layout (autolayout):
 *   ┌ Provider ▾  Model ▾   Sign in   Settings   Clear ┐   toolbar row, 28pt
 *   ├─────────────────────────────────────────────────┤
 *   │                                                 │
 *   │   chat history (NSTextView, read-only)          │
 *   │                                                 │
 *   ├─────────────────────────────────────────────────┤
 *   │ ┌─────────────────────────────────────┐  Send  │   input row
 *   │ │ input field…                        │        │
 *   │ └─────────────────────────────────────┘        │
 *   └─────────────────────────────────────────────────┘
 *
 * Keyboard: Enter inserts a newline; Send is triggered only by the
 * Send button. Escape clears the input field.
 */
#import "AssistantPanelView.h"
#import "SettingsWindowController.h"

#include "ApiClient.h"
#include "EditorHelpers.h"
#include "Keychain.h"
#include "Preferences.h"
#include "PromptBuilder.h"

using NppAIAssistant::ApiClient;
using NppAIAssistant::BuildOptions;
using NppAIAssistant::LLMResult;
using NppAIAssistant::ModelListResult;
using NppAIAssistant::Preferences;
using NppAIAssistant::PromptBuilder;
using NppAIAssistant::Provider;
using NppAIAssistant::Settings;
using NppAIAssistant::Keychain;

// ──────────────────────────────────────────────────────────────────────
// History NSTextView subclass — handles ⌘+/-/0 to scale every font run
// in the text storage. Size state lives on the instance so scrollback
// that gets appended later picks up the current size.
// ──────────────────────────────────────────────────────────────────────

static const CGFloat kHistoryFontDefault = 10.0;  // default chat-output font size
static const CGFloat kHistoryFontMin     = 7.0;
static const CGFloat kHistoryFontMax     = 28.0;
static const CGFloat kInputFontDefault   = 11.0;  // default user-input font size

@interface NppAIAHistoryTextView : NSTextView
@property (nonatomic) CGFloat currentFontSize;
- (void)adjustFontSizeBy:(CGFloat)delta;
- (void)resetFontSize;
@end

@implementation NppAIAHistoryTextView

- (instancetype)initWithFrame:(NSRect)frame {
    if ((self = [super initWithFrame:frame])) {
        _currentFontSize = kHistoryFontDefault;
    }
    return self;
}

// ⌘+ / ⌘= / ⌘- / ⌘0. performKeyEquivalent fires before keyDown:, so it
// works even when the enclosing window's menubar doesn't own the
// equivalent — important because this NSTextView lives inside a plugin
// dock panel, not a document window.
- (BOOL)performKeyEquivalent:(NSEvent*)event {
    const NSEventModifierFlags mods = event.modifierFlags & NSEventModifierFlagDeviceIndependentFlagsMask;
    if ((mods & NSEventModifierFlagCommand) == 0) return [super performKeyEquivalent:event];

    NSString* chars = event.charactersIgnoringModifiers ?: @"";
    if (chars.length != 1) return [super performKeyEquivalent:event];
    unichar c = [chars characterAtIndex:0];

    if (c == '+' || c == '=') { [self adjustFontSizeBy:+1.0]; return YES; }
    if (c == '-' || c == '_') { [self adjustFontSizeBy:-1.0]; return YES; }
    if (c == '0')             { [self resetFontSize];        return YES; }
    return [super performKeyEquivalent:event];
}

- (void)adjustFontSizeBy:(CGFloat)delta {
    CGFloat next = _currentFontSize + delta;
    if (next < kHistoryFontMin) next = kHistoryFontMin;
    if (next > kHistoryFontMax) next = kHistoryFontMax;
    [self _applyFontSize:next];
}

- (void)resetFontSize {
    [self _applyFontSize:kHistoryFontDefault];
}

- (void)_applyFontSize:(CGFloat)size {
    if (fabs(size - _currentFontSize) < 0.01) return;
    _currentFontSize = size;

    // Set the default font that new typing-style would use (harmless
    // here — the history is read-only — but keeps the machinery honest
    // if we ever enable editing).
    self.font = [NSFont systemFontOfSize:size];

    // Walk every font-attribute run in the text storage and replace
    // each font with a same-weight-but-new-size variant. Preserves the
    // header-bold / body-regular distinction we set in _appendChatRole:.
    NSTextStorage* ts = self.textStorage;
    [ts beginEditing];
    [ts enumerateAttribute:NSFontAttributeName
                   inRange:NSMakeRange(0, ts.length)
                   options:0
                usingBlock:^(id value, NSRange range, BOOL* stop) {
        NSFont* oldFont = value;
        NSFontManager* fm = [NSFontManager sharedFontManager];
        NSFont* newFont;
        if (oldFont) {
            NSFontTraitMask traits = [fm traitsOfFont:oldFont];
            newFont = [fm fontWithFamily:oldFont.familyName
                                 traits:traits
                                 weight:(NSInteger)[fm weightOfFont:oldFont]
                                   size:size];
            // Fall back to a plain system font if the font manager
            // couldn't match the family+traits combination at the new
            // size (rare, but happens for Helvetica Neue on older macOS).
            if (!newFont) newFont = [NSFont systemFontOfSize:size];
        } else {
            newFont = [NSFont systemFontOfSize:size];
        }
        [ts addAttribute:NSFontAttributeName value:newFont range:range];
    }];
    [ts endEditing];
}

@end

// ──────────────────────────────────────────────────────────────────────
// Input NSTextView subclass.
//
// Enter / Return no longer triggers a send — the user explicitly asked
// for it to insert a newline like a normal NSTextView. Send is now
// button-only. Escape still clears the field.
// ──────────────────────────────────────────────────────────────────────

@protocol NppAIAInputTextViewDelegate <NSObject>
- (void)inputViewDidRequestCancel;   // Escape pressed
@end

@interface NppAIAInputTextView : NSTextView
@property (nonatomic, weak) id<NppAIAInputTextViewDelegate> sendDelegate;
@end

@implementation NppAIAInputTextView

- (void)keyDown:(NSEvent*)event {
    if (event.keyCode == 53 /* Escape */) {
        [self.sendDelegate inputViewDidRequestCancel];
        return;
    }
    [super keyDown:event];   // everything else (incl. Return) is default
}

@end

// ──────────────────────────────────────────────────────────────────────
// Panel
// ──────────────────────────────────────────────────────────────────────

@interface AssistantPanelView () <NppAIAInputTextViewDelegate>
@property (nonatomic, strong) NSPopUpButton*     providerCombo;
// Editable combo so users can type custom model names (e.g. AnythingLLM
// workspace slugs) that won't be in any /models list. NSComboBox is the
// AppKit "editable dropdown".
@property (nonatomic, strong) NSComboBox*        modelCombo;
@property (nonatomic, strong) NSButton*          signInButton;
// Overflow "⋯" button replacing separate Clear / Settings buttons.
// Matches NppBeads' toolbar convention.
@property (nonatomic, strong) NSButton*          menuButton;
@property (nonatomic, strong) NppAIAHistoryTextView* historyView;
@property (nonatomic, strong) NSScrollView*      historyScroll;
@property (nonatomic, strong) NppAIAInputTextView* inputView;
@property (nonatomic, strong) NSScrollView*      inputScroll;
@property (nonatomic, strong) NSButton*          sendButton;
@property (nonatomic, strong) NSProgressIndicator* spinner;
@property (nonatomic, strong) NSTextField*       statusLabel;

@property (nonatomic, strong) NSMutableArray<NSDictionary*>* chatHistory;  // {role, text, timestamp}
@property (nonatomic) BOOL requestInFlight;
@property (nonatomic) Settings currentSettings;  // hoisted via dumb accessor
@end

@implementation AssistantPanelView {
    Settings _settings;
}

+ (instancetype)shared {
    static AssistantPanelView* inst;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        inst = [[AssistantPanelView alloc] initWithFrame:NSMakeRect(0, 0, 340, 480)];
    });
    return inst;
}

- (instancetype)initWithFrame:(NSRect)frame {
    if ((self = [super initWithFrame:frame])) {
        _chatHistory = [NSMutableArray array];
        [self buildUI];
        [[NSNotificationCenter defaultCenter]
            addObserver:self selector:@selector(_preferencesChanged:)
                   name:@"NppAIAPreferencesChanged" object:nil];
        [self reloadFromPreferences];
    }
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)_preferencesChanged:(NSNotification*)n {
    [self reloadFromPreferences];
}

// -----------------------------------------------------------------
// UI construction
// -----------------------------------------------------------------

- (void)buildUI {
    self.translatesAutoresizingMaskIntoConstraints = NO;
    self.wantsLayer = YES;

    // ── Provider combo — same compact styling as NppBeads' toolbar popups
    _providerCombo = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    [_providerCombo addItemsWithTitles:@[@"OpenAI", @"Gemini", @"Claude", @"Copilot"]];
    _providerCombo.target = self;
    _providerCombo.action = @selector(_providerChanged:);
    _providerCombo.translatesAutoresizingMaskIntoConstraints = NO;
    _providerCombo.bezelStyle = NSBezelStyleRounded;
    _providerCombo.controlSize = NSControlSizeSmall;
    _providerCombo.font = [NSFont systemFontOfSize:11];
    [self addSubview:_providerCombo];

    // ── Model combo — editable NSComboBox so custom slugs (AnythingLLM
    // workspace, LM Studio load path, etc.) can be typed. Same compact
    // sizing as NppBeads.
    _modelCombo = [[NSComboBox alloc] initWithFrame:NSZeroRect];
    _modelCombo.translatesAutoresizingMaskIntoConstraints = NO;
    _modelCombo.editable = YES;
    _modelCombo.hasVerticalScroller = YES;
    _modelCombo.completes = NO;
    _modelCombo.controlSize = NSControlSizeSmall;
    _modelCombo.font = [NSFont systemFontOfSize:11];
    [self addSubview:_modelCombo];

    // ── Sign in (only visible for Copilot) — same compact size
    _signInButton = [NSButton buttonWithTitle:@"Sign in"
                                       target:self
                                       action:@selector(_signInPressed:)];
    _signInButton.bezelStyle = NSBezelStyleRounded;
    _signInButton.controlSize = NSControlSizeSmall;
    _signInButton.font = [NSFont systemFontOfSize:11];
    _signInButton.hidden = YES;
    _signInButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:_signInButton];

    // ── Overflow "⋯" menu — replaces Clear + Settings. Click opens
    // the panel's menu; the menu's actions are Settings… and Clear.
    _menuButton = [[NSButton alloc] init];
    _menuButton.translatesAutoresizingMaskIntoConstraints = NO;
    _menuButton.bezelStyle = NSBezelStyleRegularSquare;
    _menuButton.bordered = NO;
    _menuButton.imagePosition = NSImageOnly;
    _menuButton.toolTip = @"More actions";
    _menuButton.target = self;
    _menuButton.action = @selector(_menuButtonTapped:);
    if (@available(macOS 11.0, *)) {
        _menuButton.image = [NSImage imageWithSystemSymbolName:@"ellipsis.circle"
                                      accessibilityDescription:@"More actions"];
    }
    [self addSubview:_menuButton];

    // Build the menu that the button opens.
    NSMenu* menu = [[NSMenu alloc] init];
    NSMenuItem* settingsItem = [[NSMenuItem alloc] initWithTitle:@"Settings…"
                                                           action:@selector(_settingsPressed:)
                                                    keyEquivalent:@""];
    settingsItem.target = self;
    [menu addItem:settingsItem];
    NSMenuItem* clearItem = [[NSMenuItem alloc] initWithTitle:@"Clear conversation"
                                                        action:@selector(_clearPressed:)
                                                 keyEquivalent:@""];
    clearItem.target = self;
    [menu addItem:clearItem];
    self.menu = menu;  // shared by the ⋯ button and any right-click

    // ── Chat history — full panel width, horizontal + vertical scrollers,
    // theme-adaptive text/background colors. The container is set to
    // grow without wrapping so long code/output lines get a real
    // horizontal scrollbar instead of wrapping.
    _historyScroll = [[NSScrollView alloc] initWithFrame:NSZeroRect];
    _historyScroll.translatesAutoresizingMaskIntoConstraints = NO;
    _historyScroll.hasVerticalScroller   = YES;
    _historyScroll.hasHorizontalScroller = NO;   // word-wrap: nothing to scroll horizontally
    _historyScroll.autohidesScrollers    = YES;
    _historyScroll.borderType            = NSNoBorder;
    _historyScroll.drawsBackground       = YES;
    _historyScroll.backgroundColor       = NSColor.textBackgroundColor;

    // Initial frame MUST be zero-sized — the text view is a document
    // view of a scroll view, and NSView autoresize applies the
    // scroll-view-size delta on top of the initial frame. If we start
    // non-zero, the text view ends up wider than the scroll view and
    // word-wrap lays out at that oversized width instead.
    _historyView = [[NppAIAHistoryTextView alloc] initWithFrame:NSZeroRect];
    _historyView.editable   = NO;
    _historyView.selectable = YES;
    _historyView.richText   = YES;
    _historyView.drawsBackground  = YES;
    _historyView.backgroundColor  = NSColor.textBackgroundColor;
    _historyView.textColor        = NSColor.labelColor;   // adapts to dark mode
    // Default size is kHistoryFontDefault (9pt); ⌘+/-/0 adjust at runtime.
    _historyView.font             = [NSFont systemFontOfSize:kHistoryFontDefault];
    _historyView.textContainerInset = NSMakeSize(6, 6);
    // Allow the text view + its container to grow beyond the visible
    // width so long lines don't wrap — the horizontal scrollbar takes
    // care of the rest.
    // Word-wrap: container width tracks the view width so lines break
    // at the visible edge. Horizontal scroll is therefore unused (and
    // auto-hides by default since we set autohidesScrollers=YES above).
    _historyView.minSize = NSMakeSize(0, 0);
    _historyView.maxSize = NSMakeSize(CGFLOAT_MAX, CGFLOAT_MAX);
    _historyView.verticallyResizable   = YES;
    _historyView.horizontallyResizable = NO;
    _historyView.autoresizingMask      = NSViewWidthSizable;
    _historyView.textContainer.widthTracksTextView = YES;
    _historyView.textContainer.containerSize       = NSMakeSize(FLT_MAX, FLT_MAX);
    _historyScroll.documentView = _historyView;
    [self addSubview:_historyScroll];

    // ── Status label (transient, under history, above input)
    _statusLabel = [NSTextField labelWithString:@""];
    _statusLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _statusLabel.font = [NSFont systemFontOfSize:10];
    _statusLabel.textColor = NSColor.secondaryLabelColor;
    [self addSubview:_statusLabel];

    // ── Input — borderless, full-width, auto-hiding H+V scrollers.
    _inputScroll = [[NSScrollView alloc] initWithFrame:NSZeroRect];
    _inputScroll.translatesAutoresizingMaskIntoConstraints = NO;
    _inputScroll.hasVerticalScroller   = YES;
    _inputScroll.hasHorizontalScroller = NO;     // word-wrap: nothing to scroll horizontally
    _inputScroll.autohidesScrollers    = YES;
    _inputScroll.borderType            = NSNoBorder;
    _inputScroll.drawsBackground       = YES;
    _inputScroll.backgroundColor       = NSColor.textBackgroundColor;

    // Same zero-size-at-init rule as the history text view — otherwise
    // the document view stays wider than the visible scroll area and
    // word-wrap measures against that oversized width.
    _inputView = [[NppAIAInputTextView alloc] initWithFrame:NSZeroRect];
    _inputView.sendDelegate = self;
    _inputView.font                = [NSFont systemFontOfSize:kInputFontDefault];
    _inputView.textContainerInset  = NSMakeSize(4, 4);
    _inputView.richText            = NO;
    _inputView.editable            = YES;
    _inputView.selectable          = YES;
    _inputView.allowsUndo          = YES;
    _inputView.drawsBackground     = YES;
    _inputView.backgroundColor     = NSColor.textBackgroundColor;
    _inputView.textColor           = NSColor.labelColor;
    _inputView.insertionPointColor = NSColor.labelColor;
    // Word-wrap: container width tracks the view width so typed lines
    // wrap at the edge. Horizontal scrollbar auto-hides since nothing
    // exceeds the width; vertical kicks in once the text is taller
    // than the field.
    _inputView.minSize = NSMakeSize(0, 0);
    _inputView.maxSize = NSMakeSize(CGFLOAT_MAX, CGFLOAT_MAX);
    _inputView.verticallyResizable   = YES;
    _inputView.horizontallyResizable = NO;
    _inputView.autoresizingMask      = NSViewWidthSizable;
    _inputView.textContainer.widthTracksTextView = YES;
    _inputView.textContainer.containerSize       = NSMakeSize(FLT_MAX, FLT_MAX);
    _inputScroll.documentView = _inputView;
    [self addSubview:_inputScroll];

    // ── Send
    _sendButton = [NSButton buttonWithTitle:@"Send"
                                     target:self
                                     action:@selector(_sendPressed:)];
    _sendButton.bezelStyle = NSBezelStyleRounded;
    _sendButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:_sendButton];

    // ── Spinner
    _spinner = [[NSProgressIndicator alloc] initWithFrame:NSZeroRect];
    _spinner.translatesAutoresizingMaskIntoConstraints = NO;
    _spinner.style = NSProgressIndicatorStyleSpinning;
    _spinner.controlSize = NSControlSizeSmall;
    _spinner.displayedWhenStopped = NO;
    [self addSubview:_spinner];

    // ── Autolayout
    const CGFloat pad = 8;
    [NSLayoutConstraint activateConstraints:@[
        // Top row: Provider | Model | (spacer) | Sign in | ⋯
        [_providerCombo.topAnchor      constraintEqualToAnchor:self.topAnchor constant:pad],
        [_providerCombo.leadingAnchor  constraintEqualToAnchor:self.leadingAnchor constant:pad],
        [_providerCombo.widthAnchor    constraintEqualToConstant:92],

        [_modelCombo.centerYAnchor     constraintEqualToAnchor:_providerCombo.centerYAnchor],
        [_modelCombo.leadingAnchor     constraintEqualToAnchor:_providerCombo.trailingAnchor constant:4],
        [_modelCombo.widthAnchor       constraintGreaterThanOrEqualToConstant:120],

        [_signInButton.centerYAnchor   constraintEqualToAnchor:_providerCombo.centerYAnchor],
        [_signInButton.leadingAnchor   constraintEqualToAnchor:_modelCombo.trailingAnchor constant:6],

        // Overflow ⋯ button at the far right, matching NppBeads' 18×18 spec.
        [_menuButton.centerYAnchor     constraintEqualToAnchor:_providerCombo.centerYAnchor],
        [_menuButton.trailingAnchor    constraintEqualToAnchor:self.trailingAnchor constant:-pad],
        [_menuButton.widthAnchor       constraintEqualToConstant:18],
        [_menuButton.heightAnchor      constraintEqualToConstant:18],

        // History fills the middle — edge-to-edge, no horizontal pad,
        // matching the XML Navigator / Folder-as-Workspace convention.
        [_historyScroll.topAnchor      constraintEqualToAnchor:_providerCombo.bottomAnchor constant:pad],
        [_historyScroll.leadingAnchor  constraintEqualToAnchor:self.leadingAnchor],
        [_historyScroll.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
        [_historyScroll.bottomAnchor   constraintEqualToAnchor:_statusLabel.topAnchor constant:-4],

        // Status + spinner above input (keep small insets since they're
        // labels, not content).
        [_statusLabel.leadingAnchor    constraintEqualToAnchor:self.leadingAnchor constant:pad],
        [_statusLabel.trailingAnchor   constraintEqualToAnchor:_spinner.leadingAnchor constant:-4],
        [_statusLabel.bottomAnchor     constraintEqualToAnchor:_inputScroll.topAnchor constant:-4],

        [_spinner.centerYAnchor        constraintEqualToAnchor:_statusLabel.centerYAnchor],
        [_spinner.trailingAnchor       constraintEqualToAnchor:self.trailingAnchor constant:-pad],
        [_spinner.widthAnchor          constraintEqualToConstant:14],
        [_spinner.heightAnchor         constraintEqualToConstant:14],

        // Input spans the full panel width. Send sits directly below.
        [_inputScroll.leadingAnchor    constraintEqualToAnchor:self.leadingAnchor],
        [_inputScroll.trailingAnchor   constraintEqualToAnchor:self.trailingAnchor],
        [_inputScroll.bottomAnchor     constraintEqualToAnchor:_sendButton.topAnchor constant:-6],
        [_inputScroll.heightAnchor     constraintEqualToConstant:64],

        [_sendButton.trailingAnchor    constraintEqualToAnchor:self.trailingAnchor constant:-pad],
        [_sendButton.bottomAnchor      constraintEqualToAnchor:self.bottomAnchor constant:-pad],
        [_sendButton.widthAnchor       constraintGreaterThanOrEqualToConstant:70],
    ]];
}

// -----------------------------------------------------------------
// Preference reloading
// -----------------------------------------------------------------

- (void)reloadFromPreferences {
    _settings = Preferences::load();
    [_providerCombo selectItemAtIndex:static_cast<NSInteger>(_settings.defaultProvider)];
    // NOTE: settings.requireCtrlEnter is retained in Preferences for
    // future use but doesn't drive anything today — Enter always
    // inserts a newline, only the Send button triggers requests.
    [self _refreshSignInVisibility];
    [self _refreshModelList];
}

- (void)_refreshSignInVisibility {
    Provider p = static_cast<Provider>(_providerCombo.indexOfSelectedItem);
    _signInButton.hidden = (p != Provider::Copilot);
}

- (void)_refreshModelList {
    Provider p = static_cast<Provider>(_providerCombo.indexOfSelectedItem);
    [_modelCombo removeAllItems];

    // Prefer the user's saved default (from Settings) over the hard-coded
    // provider baseline. Switching providers clears whatever was typed
    // since it belonged to the old provider.
    std::string savedDefault;
    switch (p) {
        case Provider::OpenAI:  savedDefault = _settings.openaiDefaultModel; break;
        case Provider::Gemini:  savedDefault = _settings.geminiDefaultModel; break;
        case Provider::Claude:  savedDefault = _settings.claudeDefaultModel; break;
        case Provider::Copilot: break;
    }
    std::string defaultModel = savedDefault.empty() ? ApiClient::defaultModel(p) : savedDefault;
    NSString* defaultNS = [NSString stringWithUTF8String:defaultModel.c_str()] ?: @"";
    [_modelCombo addItemWithObjectValue:defaultNS];
    _modelCombo.stringValue = defaultNS;

    // Best-effort: fetch live model list if the provider has a key.
    std::string account;
    switch (p) {
        case Provider::OpenAI: account = Keychain::kOpenAIKey; break;
        case Provider::Gemini: account = Keychain::kGeminiKey; break;
        case Provider::Claude: account = Keychain::kClaudeKey; break;
        case Provider::Copilot: return;   // no public model list
    }
    std::string key = Keychain::load(account);
    if (key.empty()) return;

    NppAIAssistant::EndpointOverrides eo;
    eo.openaiUrl = _settings.openaiEndpoint;
    eo.geminiUrl = _settings.geminiEndpoint;
    eo.claudeUrl = _settings.claudeEndpoint;

    __weak __typeof(self) weakSelf = self;
    ApiClient::listModels(p, key, eo, ^(const ModelListResult& r) {
        __strong __typeof(weakSelf) self = weakSelf;
        if (!self || !r.ok) return;
        // Preserve whatever the user currently has typed / selected so
        // hand-entered workspace slugs survive a refresh.
        NSString* preserved = self->_modelCombo.stringValue ?: @"";
        [self->_modelCombo removeAllItems];
        for (const auto& m : r.models) {
            NSString* ns = [NSString stringWithUTF8String:m.c_str()] ?: @"";
            if (ns.length) [self->_modelCombo addItemWithObjectValue:ns];
        }
        if (preserved.length) {
            self->_modelCombo.stringValue = preserved;
        } else if (self->_modelCombo.numberOfItems > 0) {
            [self->_modelCombo selectItemAtIndex:0];
        }
    });
}

// -----------------------------------------------------------------
// History rendering
// -----------------------------------------------------------------

- (void)_appendChatRole:(NSString*)role text:(NSString*)text {
    NSMutableAttributedString* as = [[NSMutableAttributedString alloc] init];
    // Use the history view's live current size so newly-appended turns
    // stay in sync with any ⌘+/-/0 the user has made.
    const CGFloat size = _historyView.currentFontSize ?: kHistoryFontDefault;
    NSFont* bold = [NSFont boldSystemFontOfSize:size];
    NSFont* body = [NSFont systemFontOfSize:size];

    // Both header and body get explicit theme-adaptive colors.
    // NSAttributedString with no foreground attribute can fall back
    // to solid black under NSTextView in some rendering paths, which
    // makes replies unreadable in Dark Mode.
    NSAttributedString* header = [[NSAttributedString alloc]
        initWithString:[NSString stringWithFormat:@"%@\n", role]
            attributes:@{ NSFontAttributeName: bold,
                          NSForegroundColorAttributeName: NSColor.secondaryLabelColor }];
    NSAttributedString* contentLine = [[NSAttributedString alloc]
        initWithString:[NSString stringWithFormat:@"%@\n\n", text]
            attributes:@{ NSFontAttributeName: body,
                          NSForegroundColorAttributeName: NSColor.labelColor }];
    [as appendAttributedString:header];
    [as appendAttributedString:contentLine];

    [_historyView.textStorage appendAttributedString:as];
    [_historyView scrollRangeToVisible:NSMakeRange(_historyView.string.length, 0)];
}

- (void)clearConversation {
    [_chatHistory removeAllObjects];
    [_historyView.textStorage
        replaceCharactersInRange:NSMakeRange(0, _historyView.textStorage.length)
                      withString:@""];
    _statusLabel.stringValue = @"";
}

// -----------------------------------------------------------------
// Send flow
// -----------------------------------------------------------------

- (void)_sendPressed:(id)sender { [self _startSendWithText:_inputView.string action:NppAIActionNone sci:0]; }

- (void)inputViewDidRequestCancel {
    [_inputView setString:@""];
}

- (void)runSelectionAction:(NppAIAction)action
               selectionText:(NSString*)selectionText
                 editorHandle:(std::intptr_t)sci {
    if (!selectionText.length) return;
    NSString* verb = @"";
    switch (action) {
        case NppAIActionExplain:     verb = @"Explain this code:";        break;
        case NppAIActionRefactor:    verb = @"Refactor this code for better readability and performance:"; break;
        case NppAIActionAddComments: verb = @"Add detailed comments to this code:"; break;
        case NppAIActionFix:         verb = @"Find and fix bugs in this code:"; break;
        case NppAIActionNone:        return;
    }
    NSString* userText = [NSString stringWithFormat:@"%@\n\n%@", verb, selectionText];
    [self _startSendWithText:userText action:action sci:sci];
}

- (void)_startSendWithText:(NSString*)text
                    action:(NppAIAction)action
                       sci:(std::intptr_t)sci {
    if (_requestInFlight) return;
    if (!text.length)     return;

    Provider provider = static_cast<Provider>(_providerCombo.indexOfSelectedItem);
    std::string keyAccount;
    switch (provider) {
        case Provider::OpenAI:  keyAccount = Keychain::kOpenAIKey; break;
        case Provider::Gemini:  keyAccount = Keychain::kGeminiKey; break;
        case Provider::Claude:  keyAccount = Keychain::kClaudeKey; break;
        case Provider::Copilot:
            [self _appendChatRole:@"System"
                             text:@"[Error] GitHub Copilot support is not yet wired up."];
            return;
    }
    std::string key = Keychain::load(keyAccount);
    if (key.empty()) {
        [self _appendChatRole:@"System"
                         text:@"[Error] API key missing for this provider. Open Settings and enter one."];
        return;
    }

    // NSComboBox — take whatever's in the text field, whether the user
    // picked it from the dropdown or typed it free-form.
    std::string model = std::string([_modelCombo.stringValue UTF8String] ?: "");
    if (model.empty()) model = ApiClient::defaultModel(provider);

    // Compose prompt via PromptBuilder
    BuildOptions opts;
    opts.forceCodeOnlyOutput = (action == NppAIActionRefactor ||
                                action == NppAIActionAddComments ||
                                action == NppAIActionFix);
    opts.lineEndingHint = "LF";
    std::string user   = [text UTF8String] ?: "";
    std::string prompt = PromptBuilder::build(_settings, user, opts);

    // Show user turn in history immediately; clear input.
    [self _appendChatRole:[NSString stringWithFormat:@"You → %s",
                            ApiClient::providerName(provider).c_str()]
                     text:text];
    [_inputView setString:@""];
    _requestInFlight = YES;
    _sendButton.enabled = NO;
    [_spinner startAnimation:nil];
    _statusLabel.stringValue = @"Waiting for reply…";

    NppAIAssistant::EndpointOverrides eo;
    eo.openaiUrl = _settings.openaiEndpoint;
    eo.geminiUrl = _settings.geminiEndpoint;
    eo.claudeUrl = _settings.claudeEndpoint;

    __weak __typeof(self) weakSelf = self;
    ApiClient::send(provider, key, model, prompt, eo, ^(const LLMResult& r) {
        __strong __typeof(weakSelf) self = weakSelf;
        if (!self) return;
        self.requestInFlight = NO;
        self.sendButton.enabled = YES;
        [self.spinner stopAnimation:nil];
        self.statusLabel.stringValue = @"";

        if (!r.ok || r.content.empty()) {
            NSString* err = [NSString stringWithFormat:@"[Error] %s",
                             r.errorText.empty() ? "Request failed" : r.errorText.c_str()];
            [self _appendChatRole:@"System" text:err];
            return;
        }

        NSString* reply = [NSString stringWithUTF8String:r.content.c_str()] ?: @"";
        [self _appendChatRole:[NSString stringWithUTF8String:
                                ApiClient::providerName(static_cast<Provider>(
                                    self.providerCombo.indexOfSelectedItem)).c_str()]
                         text:reply];

        // For replace-selection actions, feed the reply back to the editor.
        const BOOL shouldReplace = (action == NppAIActionRefactor ||
                                    action == NppAIActionAddComments ||
                                    action == NppAIActionFix);
        const BOOL replyIsDiagnostic = [reply hasPrefix:@"[Error]"] ||
                                       [reply hasPrefix:@"[Notice]"];
        if (shouldReplace && !replyIsDiagnostic && sci != 0) {
            std::string replyUtf8 = r.content;
            NppAIAssistant::Editor::replaceSelection(sci, replyUtf8);
        }
    });
}

- (void)_providerChanged:(id)sender {
    [self _refreshSignInVisibility];
    [self _refreshModelList];
}

- (void)_signInPressed:(id)sender {
    NSAlert* a = [[NSAlert alloc] init];
    a.messageText     = @"GitHub Copilot sign-in";
    a.informativeText = @"Copilot device-flow sign-in will land in a follow-up release. For now, use OpenAI / Gemini / Claude with their API keys in Settings.";
    [a runModal];
}

- (void)_settingsPressed:(id)sender {
    [SettingsWindowController presentFromWindow:self.window];
}

- (void)_clearPressed:(id)sender {
    [self clearConversation];
}

- (void)_menuButtonTapped:(NSButton*)sender {
    // Pop the panel's own NSMenu (Settings… + Clear) from below the button,
    // same trick NppBeads uses for its overflow ⋯.
    NSPoint pt = NSMakePoint(0, sender.bounds.size.height + 2);
    [self.menu popUpMenuPositioningItem:nil
                             atLocation:[sender convertPoint:pt toView:nil]
                                 inView:sender.window.contentView];
}

@end
