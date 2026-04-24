/**
 * SettingsWindowController.mm — settings window, AppKit controls
 * in a compact layout.
 *
 * Sections (top to bottom):
 *   1. Credentials         (3 rows: key + optional endpoint URL per provider)
 *   2. Default Provider    (provider, language, Ctrl+Enter checkbox)
 *   3. Prompt Profile      (2-column: preset/detail, response-lang/encoding)
 *   4. Scenario Modules    (5 checkboxes in one row)
 *   5. Output Rules        (3 checkboxes in one row)
 *   6. Prompt Preview      (live read-only NSTextView)
 *   7. Key sources hint    (3 short lines)
 *
 * Footer: Test Default Connection · (result) · OK · Cancel
 */
#import "SettingsWindowController.h"

#include "ApiClient.h"
#include "Keychain.h"
#include "Preferences.h"
#include "PromptBuilder.h"

using NppAIAssistant::ApiClient;
using NppAIAssistant::DetailLevel;
using NppAIAssistant::EncodingSuggestion;
using NppAIAssistant::EndpointOverrides;
using NppAIAssistant::Keychain;
using NppAIAssistant::LLMResult;
using NppAIAssistant::ModelListResult;
using NppAIAssistant::Preferences;
using NppAIAssistant::PromptBuilder;
using NppAIAssistant::PromptPreset;
using NppAIAssistant::Provider;
using NppAIAssistant::ResponseLanguage;
using NppAIAssistant::ScenarioDocs;
using NppAIAssistant::ScenarioExplain;
using NppAIAssistant::ScenarioFix;
using NppAIAssistant::ScenarioRefactor;
using NppAIAssistant::ScenarioTests;
using NppAIAssistant::Settings;
using NppAIAssistant::UiLanguage;

@interface SettingsWindowController () <NSTextFieldDelegate>

// ── Credentials
// Each API-key row has both a secure and a plain field overlaid in the
// same spot; the "Show keys" checkbox toggles which one is visible.
// Text is kept in sync between them so toggling mid-edit is lossless.
@property (nonatomic, strong) NSSecureTextField* openaiKeySecure;
@property (nonatomic, strong) NSTextField*       openaiKeyPlain;
@property (nonatomic, strong) NSTextField*       openaiUrlField;
@property (nonatomic, strong) NSTextField*       openaiModelField;
@property (nonatomic, strong) NSSecureTextField* geminiKeySecure;
@property (nonatomic, strong) NSTextField*       geminiKeyPlain;
@property (nonatomic, strong) NSTextField*       geminiUrlField;
@property (nonatomic, strong) NSTextField*       geminiModelField;
@property (nonatomic, strong) NSSecureTextField* claudeKeySecure;
@property (nonatomic, strong) NSTextField*       claudeKeyPlain;
@property (nonatomic, strong) NSTextField*       claudeUrlField;
@property (nonatomic, strong) NSTextField*       claudeModelField;
@property (nonatomic, strong) NSButton*          showKeysCheck;

// ── Default Provider
@property (nonatomic, strong) NSPopUpButton*     providerPopup;
@property (nonatomic, strong) NSPopUpButton*     languagePopup;
@property (nonatomic, strong) NSButton*          requireCtrlEnterCheck;

// ── Prompt Profile
@property (nonatomic, strong) NSPopUpButton*     presetPopup;
@property (nonatomic, strong) NSPopUpButton*     detailPopup;
@property (nonatomic, strong) NSPopUpButton*     responseLanguagePopup;
@property (nonatomic, strong) NSPopUpButton*     encodingPopup;

// ── Scenario Modules
@property (nonatomic, strong) NSButton*          scenarioExplain;
@property (nonatomic, strong) NSButton*          scenarioFix;
@property (nonatomic, strong) NSButton*          scenarioRefactor;
@property (nonatomic, strong) NSButton*          scenarioTests;
@property (nonatomic, strong) NSButton*          scenarioDocs;

// ── Output Rules
@property (nonatomic, strong) NSButton*          outputCodeOnly;
@property (nonatomic, strong) NSButton*          outputPreserveStyle;
@property (nonatomic, strong) NSButton*          outputMentionRisks;

// ── Preview + footer
@property (nonatomic, strong) NSTextView*        previewTextView;
@property (nonatomic, strong) NSButton*          okButton;
@property (nonatomic, strong) NSButton*          cancelButton;
@property (nonatomic, strong) NSButton*          testConnectionButton;
@property (nonatomic, strong) NSTextField*       testResultLabel;

// API-key edit tracking so masked placeholders don't overwrite Keychain.
@property (nonatomic) BOOL openaiEdited;
@property (nonatomic) BOOL geminiEdited;
@property (nonatomic) BOOL claudeEdited;

@property (nonatomic) Settings currentSettings;

@end

@implementation SettingsWindowController {
    Settings _settings;
}

// ──────────────────────────────────────────────────────────────────────
// Entry point
// ──────────────────────────────────────────────────────────────────────

+ (void)presentFromWindow:(NSWindow*)parent {
    static SettingsWindowController* instance;
    if (!instance) instance = [[SettingsWindowController alloc] initWindow];
    [instance loadCurrentSettings];
    if (parent) {
        [parent beginSheet:instance.window completionHandler:^(NSModalResponse r){ (void)r; }];
    } else {
        [instance showWindow:nil];
        [instance.window makeKeyAndOrderFront:nil];
    }
}

- (instancetype)initWindow {
    NSRect frame = NSMakeRect(0, 0, 640, 624);
    NSWindow* win = [[NSWindow alloc]
        initWithContentRect:frame
                  styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable)
                    backing:NSBackingStoreBuffered
                      defer:YES];
    win.title = @"NppAIAssistant Settings";
    [win center];
    if ((self = [super initWithWindow:win])) {
        [self buildUI];
    }
    return self;
}

- (void)loadCurrentSettings {
    _settings = Preferences::load();

    // API keys: load the real value into both the secure and plain
    // fields — the secure field will render bullets automatically;
    // the plain field stays behind it until the user ticks "Show keys".
    // This means we never show a fake placeholder; the field either has
    // the actual key or is empty. That avoids the earlier "masked
    // placeholder committed back to Keychain as literal ••••••" trap.
    std::string openaiKey = Keychain::load(Keychain::kOpenAIKey);
    std::string geminiKey = Keychain::load(Keychain::kGeminiKey);
    std::string claudeKey = Keychain::load(Keychain::kClaudeKey);
    NSString* o = [NSString stringWithUTF8String:openaiKey.c_str()] ?: @"";
    NSString* g = [NSString stringWithUTF8String:geminiKey.c_str()] ?: @"";
    NSString* c = [NSString stringWithUTF8String:claudeKey.c_str()] ?: @"";
    _openaiKeySecure.stringValue = o;  _openaiKeyPlain.stringValue = o;
    _geminiKeySecure.stringValue = g;  _geminiKeyPlain.stringValue = g;
    _claudeKeySecure.stringValue = c;  _claudeKeyPlain.stringValue = c;
    _openaiEdited = _geminiEdited = _claudeEdited = NO;

    // Endpoint URLs — placeholder rendered by NSTextField.placeholderString
    // shows the default when the field is empty.
    _openaiUrlField.stringValue = [NSString stringWithUTF8String:_settings.openaiEndpoint.c_str()] ?: @"";
    _geminiUrlField.stringValue = [NSString stringWithUTF8String:_settings.geminiEndpoint.c_str()] ?: @"";
    _claudeUrlField.stringValue = [NSString stringWithUTF8String:_settings.claudeEndpoint.c_str()] ?: @"";

    _openaiModelField.stringValue = [NSString stringWithUTF8String:_settings.openaiDefaultModel.c_str()] ?: @"";
    _geminiModelField.stringValue = [NSString stringWithUTF8String:_settings.geminiDefaultModel.c_str()] ?: @"";
    _claudeModelField.stringValue = [NSString stringWithUTF8String:_settings.claudeDefaultModel.c_str()] ?: @"";

    [_providerPopup          selectItemAtIndex:static_cast<NSInteger>(_settings.defaultProvider)];
    [_languagePopup          selectItemAtIndex:static_cast<NSInteger>(_settings.uiLanguage)];
    _requireCtrlEnterCheck.state = _settings.requireCtrlEnter ? NSControlStateValueOn : NSControlStateValueOff;

    [_presetPopup            selectItemAtIndex:static_cast<NSInteger>(_settings.preset)];
    [_detailPopup            selectItemAtIndex:static_cast<NSInteger>(_settings.detailLevel)];
    [_responseLanguagePopup  selectItemAtIndex:static_cast<NSInteger>(_settings.responseLanguage)];
    [_encodingPopup          selectItemAtIndex:static_cast<NSInteger>(_settings.encoding)];

    _scenarioExplain.state  = (_settings.scenarioFlags & ScenarioExplain)  ? NSControlStateValueOn : NSControlStateValueOff;
    _scenarioFix.state      = (_settings.scenarioFlags & ScenarioFix)      ? NSControlStateValueOn : NSControlStateValueOff;
    _scenarioRefactor.state = (_settings.scenarioFlags & ScenarioRefactor) ? NSControlStateValueOn : NSControlStateValueOff;
    _scenarioTests.state    = (_settings.scenarioFlags & ScenarioTests)    ? NSControlStateValueOn : NSControlStateValueOff;
    _scenarioDocs.state     = (_settings.scenarioFlags & ScenarioDocs)     ? NSControlStateValueOn : NSControlStateValueOff;

    _outputCodeOnly.state      = _settings.outputCodeOnly      ? NSControlStateValueOn : NSControlStateValueOff;
    _outputPreserveStyle.state = _settings.outputPreserveStyle ? NSControlStateValueOn : NSControlStateValueOff;
    _outputMentionRisks.state  = _settings.outputMentionRisks  ? NSControlStateValueOn : NSControlStateValueOff;

    _testResultLabel.stringValue = @"";
    [self refreshPreview];
}

// ──────────────────────────────────────────────────────────────────────
// UI construction (compact layout, NSFont size 11 throughout)
// ──────────────────────────────────────────────────────────────────────

- (NSTextField*)label:(NSString*)text {
    NSTextField* tf = [NSTextField labelWithString:text];
    tf.translatesAutoresizingMaskIntoConstraints = NO;
    tf.font = [NSFont systemFontOfSize:11];
    return tf;
}
- (NSTextField*)hint:(NSString*)text {
    NSTextField* tf = [self label:text];
    tf.textColor = NSColor.secondaryLabelColor;
    tf.font = [NSFont systemFontOfSize:10];
    return tf;
}
- (NSBox*)box:(NSString*)title {
    NSBox* b = [[NSBox alloc] init];
    b.translatesAutoresizingMaskIntoConstraints = NO;
    b.title = title;
    b.titleFont = [NSFont systemFontOfSize:10 weight:NSFontWeightMedium];
    b.contentViewMargins = NSMakeSize(8, 6);
    return b;
}
- (NSButton*)check:(NSString*)title {
    NSButton* b = [NSButton checkboxWithTitle:title target:self action:@selector(anyFieldChanged:)];
    b.translatesAutoresizingMaskIntoConstraints = NO;
    b.font = [NSFont systemFontOfSize:11];
    return b;
}
- (NSPopUpButton*)popup:(NSArray<NSString*>*)titles action:(SEL)action {
    NSPopUpButton* p = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    p.translatesAutoresizingMaskIntoConstraints = NO;
    p.font = [NSFont systemFontOfSize:11];
    [p addItemsWithTitles:titles];
    p.target = self;
    p.action = action ?: @selector(anyFieldChanged:);
    return p;
}
- (NSTextField*)urlField {
    NSTextField* tf = [[NSTextField alloc] init];
    tf.translatesAutoresizingMaskIntoConstraints = NO;
    tf.font = [NSFont userFixedPitchFontOfSize:10];
    tf.controlSize = NSControlSizeSmall;
    tf.cell.usesSingleLineMode = YES;
    return tf;
}
- (NSSecureTextField*)secureField {
    NSSecureTextField* tf = [[NSSecureTextField alloc] init];
    tf.translatesAutoresizingMaskIntoConstraints = NO;
    tf.font = [NSFont systemFontOfSize:11];
    tf.controlSize = NSControlSizeSmall;
    tf.delegate = self;
    return tf;
}
- (NSTextField*)plainKeyField {
    // Same shape as secureField but the bytes are visible. Used when
    // "Show keys" is toggled on. Kept in sync with the secure peer via
    // controlTextDidChange:.
    NSTextField* tf = [[NSTextField alloc] init];
    tf.translatesAutoresizingMaskIntoConstraints = NO;
    tf.font = [NSFont userFixedPitchFontOfSize:10];
    tf.controlSize = NSControlSizeSmall;
    tf.delegate = self;
    return tf;
}

- (void)buildUI {
    NSView* root = self.window.contentView;

    // ──────────────────────── Credentials box ────────────────────────
    NSBox* credBox = [self box:@"Credentials  (endpoint URL optional — blank = provider default)"];
    NSView* cred = credBox.contentView;

    _openaiKeySecure = [self secureField];  _openaiKeySecure.tag = 1;
    _geminiKeySecure = [self secureField];  _geminiKeySecure.tag = 2;
    _claudeKeySecure = [self secureField];  _claudeKeySecure.tag = 3;
    _openaiKeyPlain  = [self plainKeyField]; _openaiKeyPlain.tag = 11; _openaiKeyPlain.hidden = YES;
    _geminiKeyPlain  = [self plainKeyField]; _geminiKeyPlain.tag = 12; _geminiKeyPlain.hidden = YES;
    _claudeKeyPlain  = [self plainKeyField]; _claudeKeyPlain.tag = 13; _claudeKeyPlain.hidden = YES;

    _openaiUrlField = [self urlField];
    _geminiUrlField = [self urlField];
    _claudeUrlField = [self urlField];
    _openaiUrlField.placeholderString = @"https://api.openai.com/v1/chat/completions";
    _geminiUrlField.placeholderString = @"https://generativelanguage.googleapis.com/v1beta/models/{model}:generateContent";
    _claudeUrlField.placeholderString = @"https://api.anthropic.com/v1/messages";

    _openaiModelField = [self urlField];
    _geminiModelField = [self urlField];
    _claudeModelField = [self urlField];
    _openaiModelField.placeholderString = @"gpt-4o-mini";
    _geminiModelField.placeholderString = @"gemini-2.0-flash";
    _claudeModelField.placeholderString = @"claude-sonnet-4-20250514";
    _openaiModelField.delegate = self;
    _geminiModelField.delegate = self;
    _claudeModelField.delegate = self;

    NSTextField* oKey = [self label:@"OpenAI"];
    NSTextField* gKey = [self label:@"Gemini"];
    NSTextField* cKey = [self label:@"Claude"];
    NSTextField* keyHeader   = [self hint:@"API Key"];
    NSTextField* urlHeader   = [self hint:@"Endpoint URL  (optional override)"];
    NSTextField* modelHeader = [self hint:@"Default model"];

    _showKeysCheck = [NSButton checkboxWithTitle:@"Show keys"
                                           target:self
                                           action:@selector(showKeysToggled:)];
    _showKeysCheck.translatesAutoresizingMaskIntoConstraints = NO;
    _showKeysCheck.font = [NSFont systemFontOfSize:10];

    [cred addSubview:keyHeader];
    [cred addSubview:urlHeader];
    [cred addSubview:modelHeader];
    [cred addSubview:_showKeysCheck];
    [cred addSubview:oKey];     [cred addSubview:_openaiKeySecure]; [cred addSubview:_openaiKeyPlain]; [cred addSubview:_openaiUrlField]; [cred addSubview:_openaiModelField];
    [cred addSubview:gKey];     [cred addSubview:_geminiKeySecure]; [cred addSubview:_geminiKeyPlain]; [cred addSubview:_geminiUrlField]; [cred addSubview:_geminiModelField];
    [cred addSubview:cKey];     [cred addSubview:_claudeKeySecure]; [cred addSubview:_claudeKeyPlain]; [cred addSubview:_claudeUrlField]; [cred addSubview:_claudeModelField];

    // 4-column layout: label | key | url | default-model
    const CGFloat keyWidth   = 200;
    const CGFloat modelWidth = 120;

    [NSLayoutConstraint activateConstraints:@[
        [keyHeader.topAnchor         constraintEqualToAnchor:cred.topAnchor],
        [keyHeader.leadingAnchor     constraintEqualToAnchor:cred.leadingAnchor constant:44],

        [urlHeader.topAnchor         constraintEqualToAnchor:keyHeader.topAnchor],
        [urlHeader.leadingAnchor     constraintEqualToAnchor:_openaiUrlField.leadingAnchor],

        [modelHeader.topAnchor       constraintEqualToAnchor:keyHeader.topAnchor],
        [modelHeader.leadingAnchor   constraintEqualToAnchor:_openaiModelField.leadingAnchor],

        // "Show keys" goes UNDER the Claude row, aligned to the API Key
        // column so it's visually grouped with what it unmasks.
        [_showKeysCheck.topAnchor     constraintEqualToAnchor:_claudeKeySecure.bottomAnchor constant:6],
        [_showKeysCheck.leadingAnchor constraintEqualToAnchor:_openaiKeySecure.leadingAnchor],

        // OpenAI row
        [oKey.topAnchor              constraintEqualToAnchor:keyHeader.bottomAnchor constant:4],
        [oKey.leadingAnchor          constraintEqualToAnchor:cred.leadingAnchor],
        [oKey.widthAnchor            constraintEqualToConstant:40],
        [_openaiKeySecure.centerYAnchor constraintEqualToAnchor:oKey.centerYAnchor],
        [_openaiKeySecure.leadingAnchor constraintEqualToAnchor:oKey.trailingAnchor constant:4],
        [_openaiKeySecure.widthAnchor   constraintEqualToConstant:keyWidth],
        [_openaiKeyPlain.topAnchor      constraintEqualToAnchor:_openaiKeySecure.topAnchor],
        [_openaiKeyPlain.leadingAnchor  constraintEqualToAnchor:_openaiKeySecure.leadingAnchor],
        [_openaiKeyPlain.widthAnchor    constraintEqualToAnchor:_openaiKeySecure.widthAnchor],
        [_openaiKeyPlain.heightAnchor   constraintEqualToAnchor:_openaiKeySecure.heightAnchor],
        [_openaiUrlField.centerYAnchor  constraintEqualToAnchor:oKey.centerYAnchor],
        [_openaiUrlField.leadingAnchor  constraintEqualToAnchor:_openaiKeySecure.trailingAnchor constant:6],
        [_openaiUrlField.trailingAnchor constraintEqualToAnchor:_openaiModelField.leadingAnchor constant:-6],
        [_openaiModelField.centerYAnchor constraintEqualToAnchor:oKey.centerYAnchor],
        [_openaiModelField.widthAnchor   constraintEqualToConstant:modelWidth],
        [_openaiModelField.trailingAnchor constraintEqualToAnchor:cred.trailingAnchor],

        // Gemini row
        [gKey.topAnchor              constraintEqualToAnchor:oKey.bottomAnchor constant:6],
        [gKey.leadingAnchor          constraintEqualToAnchor:oKey.leadingAnchor],
        [gKey.widthAnchor            constraintEqualToAnchor:oKey.widthAnchor],
        [_geminiKeySecure.centerYAnchor constraintEqualToAnchor:gKey.centerYAnchor],
        [_geminiKeySecure.leadingAnchor constraintEqualToAnchor:_openaiKeySecure.leadingAnchor],
        [_geminiKeySecure.widthAnchor   constraintEqualToAnchor:_openaiKeySecure.widthAnchor],
        [_geminiKeyPlain.topAnchor      constraintEqualToAnchor:_geminiKeySecure.topAnchor],
        [_geminiKeyPlain.leadingAnchor  constraintEqualToAnchor:_geminiKeySecure.leadingAnchor],
        [_geminiKeyPlain.widthAnchor    constraintEqualToAnchor:_geminiKeySecure.widthAnchor],
        [_geminiKeyPlain.heightAnchor   constraintEqualToAnchor:_geminiKeySecure.heightAnchor],
        [_geminiUrlField.centerYAnchor  constraintEqualToAnchor:gKey.centerYAnchor],
        [_geminiUrlField.leadingAnchor  constraintEqualToAnchor:_openaiUrlField.leadingAnchor],
        [_geminiUrlField.trailingAnchor constraintEqualToAnchor:_openaiUrlField.trailingAnchor],
        [_geminiModelField.centerYAnchor constraintEqualToAnchor:gKey.centerYAnchor],
        [_geminiModelField.leadingAnchor constraintEqualToAnchor:_openaiModelField.leadingAnchor],
        [_geminiModelField.widthAnchor   constraintEqualToAnchor:_openaiModelField.widthAnchor],

        // Claude row
        [cKey.topAnchor              constraintEqualToAnchor:gKey.bottomAnchor constant:6],
        [cKey.leadingAnchor          constraintEqualToAnchor:oKey.leadingAnchor],
        [cKey.widthAnchor            constraintEqualToAnchor:oKey.widthAnchor],
        [_claudeKeySecure.centerYAnchor constraintEqualToAnchor:cKey.centerYAnchor],
        [_claudeKeySecure.leadingAnchor constraintEqualToAnchor:_openaiKeySecure.leadingAnchor],
        [_claudeKeySecure.widthAnchor   constraintEqualToAnchor:_openaiKeySecure.widthAnchor],
        [_claudeKeyPlain.topAnchor      constraintEqualToAnchor:_claudeKeySecure.topAnchor],
        [_claudeKeyPlain.leadingAnchor  constraintEqualToAnchor:_claudeKeySecure.leadingAnchor],
        [_claudeKeyPlain.widthAnchor    constraintEqualToAnchor:_claudeKeySecure.widthAnchor],
        [_claudeKeyPlain.heightAnchor   constraintEqualToAnchor:_claudeKeySecure.heightAnchor],
        [_claudeUrlField.centerYAnchor  constraintEqualToAnchor:cKey.centerYAnchor],
        [_claudeUrlField.leadingAnchor  constraintEqualToAnchor:_openaiUrlField.leadingAnchor],
        [_claudeUrlField.trailingAnchor constraintEqualToAnchor:_openaiUrlField.trailingAnchor],
        [_claudeModelField.centerYAnchor constraintEqualToAnchor:cKey.centerYAnchor],
        [_claudeModelField.leadingAnchor constraintEqualToAnchor:_openaiModelField.leadingAnchor],
        [_claudeModelField.widthAnchor   constraintEqualToAnchor:_openaiModelField.widthAnchor],
    ]];
    [root addSubview:credBox];

    // ──────────────────────── Default Provider box ────────────────────────
    NSBox* dpBox = [self box:@"Default Provider"];
    NSView* dp   = dpBox.contentView;

    NSTextField* dpLabel   = [self label:@"Default:"];
    NSTextField* langLabel = [self label:@"Language:"];
    _providerPopup         = [self popup:@[@"OpenAI", @"Gemini", @"Claude", @"Copilot"] action:nil];
    _languagePopup         = [self popup:@[@"Follow Notepad++", @"English", @"中文"] action:nil];
    _requireCtrlEnterCheck = [self check:@"Require Ctrl+Enter to send from AI panel"];

    [dp addSubview:dpLabel];   [dp addSubview:_providerPopup];
    [dp addSubview:langLabel]; [dp addSubview:_languagePopup];
    [dp addSubview:_requireCtrlEnterCheck];

    [NSLayoutConstraint activateConstraints:@[
        [dpLabel.topAnchor        constraintEqualToAnchor:dp.topAnchor constant:2],
        [dpLabel.leadingAnchor    constraintEqualToAnchor:dp.leadingAnchor],
        [_providerPopup.centerYAnchor constraintEqualToAnchor:dpLabel.centerYAnchor],
        [_providerPopup.leadingAnchor constraintEqualToAnchor:dpLabel.trailingAnchor constant:4],
        [_providerPopup.widthAnchor   constraintEqualToConstant:110],

        [langLabel.centerYAnchor  constraintEqualToAnchor:dpLabel.centerYAnchor],
        [langLabel.leadingAnchor  constraintEqualToAnchor:_providerPopup.trailingAnchor constant:18],
        [_languagePopup.centerYAnchor constraintEqualToAnchor:dpLabel.centerYAnchor],
        [_languagePopup.leadingAnchor constraintEqualToAnchor:langLabel.trailingAnchor constant:4],
        [_languagePopup.widthAnchor   constraintEqualToConstant:150],

        [_requireCtrlEnterCheck.topAnchor     constraintEqualToAnchor:dpLabel.bottomAnchor constant:6],
        [_requireCtrlEnterCheck.leadingAnchor constraintEqualToAnchor:dp.leadingAnchor],
    ]];
    [root addSubview:dpBox];

    // ──────────────────────── Prompt Profile box (2 columns) ────────────────────────
    NSBox* ppBox = [self box:@"Single-turn Prompt Profile"];
    NSView* pp   = ppBox.contentView;

    NSTextField* presetL  = [self label:@"Preset:"];
    NSTextField* detailL  = [self label:@"Detail:"];
    NSTextField* rlangL   = [self label:@"Response language:"];
    NSTextField* encL     = [self label:@"Encoding:"];

    _presetPopup = [self popup:@[@"Custom", @"Code fix", @"Refactor", @"Explain",
                                 @"Generate tests", @"Write docs"]
                         action:@selector(presetChanged:)];
    _detailPopup = [self popup:@[@"Concise", @"Standard", @"Detailed"] action:nil];
    _responseLanguagePopup = [self popup:@[@"Follow interface", @"繁體中文", @"English"] action:nil];
    _encodingPopup = [self popup:@[@"Current doc", @"UTF-8", @"UTF-8 w/ BOM", @"Big5", @"ANSI / local"]
                           action:nil];

    [pp addSubview:presetL];  [pp addSubview:_presetPopup];
    [pp addSubview:detailL];  [pp addSubview:_detailPopup];
    [pp addSubview:rlangL];   [pp addSubview:_responseLanguagePopup];
    [pp addSubview:encL];     [pp addSubview:_encodingPopup];

    const CGFloat leftLabelW = 115;
    [NSLayoutConstraint activateConstraints:@[
        [presetL.topAnchor           constraintEqualToAnchor:pp.topAnchor constant:2],
        [presetL.leadingAnchor       constraintEqualToAnchor:pp.leadingAnchor],
        [presetL.widthAnchor         constraintEqualToConstant:leftLabelW],
        [_presetPopup.centerYAnchor  constraintEqualToAnchor:presetL.centerYAnchor],
        [_presetPopup.leadingAnchor  constraintEqualToAnchor:presetL.trailingAnchor],
        [_presetPopup.widthAnchor    constraintEqualToConstant:160],

        [detailL.centerYAnchor       constraintEqualToAnchor:presetL.centerYAnchor],
        [detailL.leadingAnchor       constraintEqualToAnchor:_presetPopup.trailingAnchor constant:16],
        [_detailPopup.centerYAnchor  constraintEqualToAnchor:presetL.centerYAnchor],
        [_detailPopup.leadingAnchor  constraintEqualToAnchor:detailL.trailingAnchor constant:4],
        [_detailPopup.widthAnchor    constraintEqualToConstant:110],

        [rlangL.topAnchor            constraintEqualToAnchor:presetL.bottomAnchor constant:6],
        [rlangL.leadingAnchor        constraintEqualToAnchor:presetL.leadingAnchor],
        [rlangL.widthAnchor          constraintEqualToConstant:leftLabelW],
        [_responseLanguagePopup.centerYAnchor constraintEqualToAnchor:rlangL.centerYAnchor],
        [_responseLanguagePopup.leadingAnchor constraintEqualToAnchor:rlangL.trailingAnchor],
        [_responseLanguagePopup.widthAnchor   constraintEqualToConstant:160],

        [encL.centerYAnchor          constraintEqualToAnchor:rlangL.centerYAnchor],
        [encL.leadingAnchor          constraintEqualToAnchor:_responseLanguagePopup.trailingAnchor constant:16],
        [_encodingPopup.centerYAnchor constraintEqualToAnchor:rlangL.centerYAnchor],
        [_encodingPopup.leadingAnchor constraintEqualToAnchor:encL.trailingAnchor constant:4],
        [_encodingPopup.widthAnchor   constraintEqualToConstant:110],
    ]];
    [root addSubview:ppBox];

    // ──────────────────────── Scenario + Output (single row each) ────────────────────────
    NSBox* scBox = [self box:@"Scenario Modules"];
    NSView* sc   = scBox.contentView;
    _scenarioExplain  = [self check:@"Explain code"];
    _scenarioFix      = [self check:@"Fix bugs"];
    _scenarioRefactor = [self check:@"Refactor"];
    _scenarioTests    = [self check:@"Generate tests"];
    _scenarioDocs     = [self check:@"Write docs"];
    [sc addSubview:_scenarioExplain];
    [sc addSubview:_scenarioFix];
    [sc addSubview:_scenarioRefactor];
    [sc addSubview:_scenarioTests];
    [sc addSubview:_scenarioDocs];
    [NSLayoutConstraint activateConstraints:@[
        [_scenarioExplain.topAnchor     constraintEqualToAnchor:sc.topAnchor constant:2],
        [_scenarioExplain.leadingAnchor constraintEqualToAnchor:sc.leadingAnchor],

        [_scenarioFix.centerYAnchor     constraintEqualToAnchor:_scenarioExplain.centerYAnchor],
        [_scenarioFix.leadingAnchor     constraintEqualToAnchor:_scenarioExplain.trailingAnchor constant:12],

        [_scenarioRefactor.centerYAnchor constraintEqualToAnchor:_scenarioExplain.centerYAnchor],
        [_scenarioRefactor.leadingAnchor constraintEqualToAnchor:_scenarioFix.trailingAnchor constant:12],

        [_scenarioTests.centerYAnchor   constraintEqualToAnchor:_scenarioExplain.centerYAnchor],
        [_scenarioTests.leadingAnchor   constraintEqualToAnchor:_scenarioRefactor.trailingAnchor constant:12],

        [_scenarioDocs.centerYAnchor    constraintEqualToAnchor:_scenarioExplain.centerYAnchor],
        [_scenarioDocs.leadingAnchor    constraintEqualToAnchor:_scenarioTests.trailingAnchor constant:12],
    ]];
    [root addSubview:scBox];

    NSBox* orBox = [self box:@"Output Rules"];
    NSView* or_  = orBox.contentView;
    _outputCodeOnly      = [self check:@"Code only when suitable"];
    _outputPreserveStyle = [self check:@"Preserve project style"];
    _outputMentionRisks  = [self check:@"Mention risks and assumptions"];
    [or_ addSubview:_outputCodeOnly];
    [or_ addSubview:_outputPreserveStyle];
    [or_ addSubview:_outputMentionRisks];
    [NSLayoutConstraint activateConstraints:@[
        [_outputCodeOnly.topAnchor        constraintEqualToAnchor:or_.topAnchor constant:2],
        [_outputCodeOnly.leadingAnchor    constraintEqualToAnchor:or_.leadingAnchor],
        [_outputPreserveStyle.centerYAnchor constraintEqualToAnchor:_outputCodeOnly.centerYAnchor],
        [_outputPreserveStyle.leadingAnchor constraintEqualToAnchor:_outputCodeOnly.trailingAnchor constant:12],
        [_outputMentionRisks.centerYAnchor  constraintEqualToAnchor:_outputCodeOnly.centerYAnchor],
        [_outputMentionRisks.leadingAnchor  constraintEqualToAnchor:_outputPreserveStyle.trailingAnchor constant:12],
    ]];
    [root addSubview:orBox];

    // ──────────────────────── Prompt preview box ────────────────────────
    NSBox* pvBox = [self box:@"Prompt Preview"];
    NSScrollView* pvScroll = [[NSScrollView alloc] init];
    pvScroll.translatesAutoresizingMaskIntoConstraints = NO;
    pvScroll.hasVerticalScroller = YES;
    pvScroll.borderType = NSLineBorder;
    _previewTextView = [[NSTextView alloc] init];
    _previewTextView.editable = NO;
    _previewTextView.selectable = YES;
    _previewTextView.font = [NSFont userFixedPitchFontOfSize:10];
    _previewTextView.textContainerInset = NSMakeSize(4, 3);
    pvScroll.documentView = _previewTextView;
    [pvBox.contentView addSubview:pvScroll];
    [NSLayoutConstraint activateConstraints:@[
        [pvScroll.topAnchor      constraintEqualToAnchor:pvBox.contentView.topAnchor],
        [pvScroll.leadingAnchor  constraintEqualToAnchor:pvBox.contentView.leadingAnchor],
        [pvScroll.trailingAnchor constraintEqualToAnchor:pvBox.contentView.trailingAnchor],
        [pvScroll.bottomAnchor   constraintEqualToAnchor:pvBox.contentView.bottomAnchor],
        [pvScroll.heightAnchor   constraintGreaterThanOrEqualToConstant:100],
    ]];
    [root addSubview:pvBox];

    // ──────────────────────── Hints (short, single line) ────────────────────────
    NSTextField* hint = [self hint:
        @"Get an API key:  OpenAI · platform.openai.com    "
         "Gemini · ai.google.dev    Claude · console.anthropic.com"];
    [root addSubview:hint];

    // ──────────────────────── Footer ────────────────────────
    _testConnectionButton = [NSButton buttonWithTitle:@"Test Default Connection"
                                                target:self
                                                action:@selector(testConnectionPressed:)];
    _testConnectionButton.translatesAutoresizingMaskIntoConstraints = NO;
    _testConnectionButton.bezelStyle = NSBezelStyleRounded;
    _testConnectionButton.controlSize = NSControlSizeSmall;
    [root addSubview:_testConnectionButton];

    _testResultLabel = [self hint:@""];
    [root addSubview:_testResultLabel];

    _cancelButton = [NSButton buttonWithTitle:@"Cancel" target:self action:@selector(cancelPressed:)];
    _cancelButton.translatesAutoresizingMaskIntoConstraints = NO;
    _cancelButton.keyEquivalent = @"\e";
    _cancelButton.bezelStyle = NSBezelStyleRounded;
    _cancelButton.controlSize = NSControlSizeSmall;
    [root addSubview:_cancelButton];

    _okButton = [NSButton buttonWithTitle:@"OK" target:self action:@selector(okPressed:)];
    _okButton.translatesAutoresizingMaskIntoConstraints = NO;
    _okButton.keyEquivalent = @"\r";
    _okButton.bezelStyle = NSBezelStyleRounded;
    _okButton.controlSize = NSControlSizeSmall;
    [root addSubview:_okButton];

    // ──────────────────────── Global layout ────────────────────────
    const CGFloat pad = 10;
    [NSLayoutConstraint activateConstraints:@[
        [credBox.topAnchor       constraintEqualToAnchor:root.topAnchor constant:pad],
        [credBox.leadingAnchor   constraintEqualToAnchor:root.leadingAnchor constant:pad],
        [credBox.trailingAnchor  constraintEqualToAnchor:root.trailingAnchor constant:-pad],
        [credBox.heightAnchor    constraintEqualToConstant:150],

        [dpBox.topAnchor         constraintEqualToAnchor:credBox.bottomAnchor constant:pad],
        [dpBox.leadingAnchor     constraintEqualToAnchor:credBox.leadingAnchor],
        [dpBox.trailingAnchor    constraintEqualToAnchor:credBox.trailingAnchor],
        [dpBox.heightAnchor      constraintEqualToConstant:70],

        [ppBox.topAnchor         constraintEqualToAnchor:dpBox.bottomAnchor constant:pad],
        [ppBox.leadingAnchor     constraintEqualToAnchor:credBox.leadingAnchor],
        [ppBox.trailingAnchor    constraintEqualToAnchor:credBox.trailingAnchor],
        [ppBox.heightAnchor      constraintEqualToConstant:68],

        [scBox.topAnchor         constraintEqualToAnchor:ppBox.bottomAnchor constant:pad],
        [scBox.leadingAnchor     constraintEqualToAnchor:credBox.leadingAnchor],
        [scBox.trailingAnchor    constraintEqualToAnchor:credBox.trailingAnchor],
        [scBox.heightAnchor      constraintEqualToConstant:42],

        [orBox.topAnchor         constraintEqualToAnchor:scBox.bottomAnchor constant:pad],
        [orBox.leadingAnchor     constraintEqualToAnchor:credBox.leadingAnchor],
        [orBox.trailingAnchor    constraintEqualToAnchor:credBox.trailingAnchor],
        [orBox.heightAnchor      constraintEqualToConstant:42],

        [pvBox.topAnchor         constraintEqualToAnchor:orBox.bottomAnchor constant:pad],
        [pvBox.leadingAnchor     constraintEqualToAnchor:credBox.leadingAnchor],
        [pvBox.trailingAnchor    constraintEqualToAnchor:credBox.trailingAnchor],
        [pvBox.heightAnchor      constraintEqualToConstant:120],

        [hint.topAnchor          constraintEqualToAnchor:pvBox.bottomAnchor constant:6],
        [hint.leadingAnchor      constraintEqualToAnchor:root.leadingAnchor constant:pad],

        // Footer
        [_testConnectionButton.topAnchor      constraintEqualToAnchor:hint.bottomAnchor constant:6],
        [_testConnectionButton.leadingAnchor  constraintEqualToAnchor:root.leadingAnchor constant:pad],
        [_testConnectionButton.bottomAnchor   constraintEqualToAnchor:root.bottomAnchor constant:-pad],

        [_testResultLabel.centerYAnchor        constraintEqualToAnchor:_testConnectionButton.centerYAnchor],
        [_testResultLabel.leadingAnchor        constraintEqualToAnchor:_testConnectionButton.trailingAnchor constant:8],
        [_testResultLabel.trailingAnchor       constraintLessThanOrEqualToAnchor:_cancelButton.leadingAnchor constant:-8],

        [_okButton.centerYAnchor     constraintEqualToAnchor:_testConnectionButton.centerYAnchor],
        [_okButton.trailingAnchor    constraintEqualToAnchor:root.trailingAnchor constant:-pad],
        [_okButton.widthAnchor       constraintGreaterThanOrEqualToConstant:60],

        [_cancelButton.centerYAnchor  constraintEqualToAnchor:_testConnectionButton.centerYAnchor],
        [_cancelButton.trailingAnchor constraintEqualToAnchor:_okButton.leadingAnchor constant:-6],
        [_cancelButton.widthAnchor    constraintGreaterThanOrEqualToConstant:60],
    ]];
}

// ──────────────────────────────────────────────────────────────────────
// Delegate / actions
// ──────────────────────────────────────────────────────────────────────

// macOS auto-substitution turns hyphens into en-dashes, straight
// quotes into curly quotes, "..." into "…", etc. API keys and URLs
// break under any of these. Disable all three smart-substitutions on
// the field editor that services our credential inputs. Applies to
// every NSTextField / NSSecureTextField bound to this controller.
- (BOOL)control:(NSControl*)control textShouldBeginEditing:(NSText*)fieldEditor {
    if ([fieldEditor isKindOfClass:[NSTextView class]]) {
        NSTextView* tv = (NSTextView*)fieldEditor;
        tv.automaticDashSubstitutionEnabled    = NO;
        tv.automaticQuoteSubstitutionEnabled   = NO;
        tv.automaticTextReplacementEnabled     = NO;
        tv.automaticSpellingCorrectionEnabled  = NO;
        tv.smartInsertDeleteEnabled            = NO;
    }
    return YES;
}

- (void)controlTextDidChange:(NSNotification*)note {
    // Keep secure ↔ plain peers in sync so toggling "Show keys" mid-edit
    // is lossless, and mark which provider's key was actually touched.
    NSControl* c = note.object;
    if      (c == _openaiKeySecure) { _openaiKeyPlain.stringValue = _openaiKeySecure.stringValue; _openaiEdited = YES; }
    else if (c == _openaiKeyPlain)  { _openaiKeySecure.stringValue = _openaiKeyPlain.stringValue;  _openaiEdited = YES; }
    else if (c == _geminiKeySecure) { _geminiKeyPlain.stringValue  = _geminiKeySecure.stringValue; _geminiEdited = YES; }
    else if (c == _geminiKeyPlain)  { _geminiKeySecure.stringValue = _geminiKeyPlain.stringValue;  _geminiEdited = YES; }
    else if (c == _claudeKeySecure) { _claudeKeyPlain.stringValue  = _claudeKeySecure.stringValue; _claudeEdited = YES; }
    else if (c == _claudeKeyPlain)  { _claudeKeySecure.stringValue = _claudeKeyPlain.stringValue;  _claudeEdited = YES; }
    [self refreshPreview];
}

- (void)showKeysToggled:(id)sender {
    BOOL showPlain = (_showKeysCheck.state == NSControlStateValueOn);
    _openaiKeySecure.hidden = showPlain;  _openaiKeyPlain.hidden = !showPlain;
    _geminiKeySecure.hidden = showPlain;  _geminiKeyPlain.hidden = !showPlain;
    _claudeKeySecure.hidden = showPlain;  _claudeKeyPlain.hidden = !showPlain;
}

- (void)anyFieldChanged:(id)sender { [self refreshPreview]; }

- (void)presetChanged:(id)sender {
    PromptPreset p = static_cast<PromptPreset>(_presetPopup.indexOfSelectedItem);
    switch (p) {
        case PromptPreset::CodeFix:
            _scenarioFix.state = NSControlStateValueOn;
            [_detailPopup selectItemAtIndex:1];
            _outputCodeOnly.state      = NSControlStateValueOn;
            _outputPreserveStyle.state = NSControlStateValueOn;
            _outputMentionRisks.state  = NSControlStateValueOn;
            break;
        case PromptPreset::Refactor:
            _scenarioRefactor.state = NSControlStateValueOn;
            [_detailPopup selectItemAtIndex:1];
            _outputCodeOnly.state      = NSControlStateValueOn;
            _outputPreserveStyle.state = NSControlStateValueOn;
            _outputMentionRisks.state  = NSControlStateValueOn;
            break;
        case PromptPreset::Explain:
            _scenarioExplain.state = NSControlStateValueOn;
            [_detailPopup selectItemAtIndex:2];
            _outputCodeOnly.state      = NSControlStateValueOff;
            _outputPreserveStyle.state = NSControlStateValueOn;
            _outputMentionRisks.state  = NSControlStateValueOff;
            break;
        case PromptPreset::GenerateTests:
            _scenarioTests.state = NSControlStateValueOn;
            [_detailPopup selectItemAtIndex:1];
            _outputCodeOnly.state      = NSControlStateValueOn;
            _outputPreserveStyle.state = NSControlStateValueOn;
            _outputMentionRisks.state  = NSControlStateValueOn;
            break;
        case PromptPreset::WriteDocs:
            _scenarioDocs.state = NSControlStateValueOn;
            [_detailPopup selectItemAtIndex:1];
            _outputCodeOnly.state      = NSControlStateValueOff;
            _outputPreserveStyle.state = NSControlStateValueOn;
            _outputMentionRisks.state  = NSControlStateValueOff;
            break;
        case PromptPreset::Manual:
        default:
            break;
    }
    [self refreshPreview];
}

- (Settings)gatherSettings {
    Settings s = _settings;
    s.defaultProvider     = static_cast<Provider>(_providerPopup.indexOfSelectedItem);
    s.uiLanguage          = static_cast<UiLanguage>(_languagePopup.indexOfSelectedItem);
    s.requireCtrlEnter    = _requireCtrlEnterCheck.state == NSControlStateValueOn;
    s.preset              = static_cast<PromptPreset>(_presetPopup.indexOfSelectedItem);
    s.responseLanguage    = static_cast<ResponseLanguage>(_responseLanguagePopup.indexOfSelectedItem);
    s.encoding            = static_cast<EncodingSuggestion>(_encodingPopup.indexOfSelectedItem);
    s.detailLevel         = static_cast<DetailLevel>(_detailPopup.indexOfSelectedItem);
    s.scenarioFlags = 0;
    if (_scenarioExplain.state  == NSControlStateValueOn) s.scenarioFlags |= ScenarioExplain;
    if (_scenarioFix.state      == NSControlStateValueOn) s.scenarioFlags |= ScenarioFix;
    if (_scenarioRefactor.state == NSControlStateValueOn) s.scenarioFlags |= ScenarioRefactor;
    if (_scenarioTests.state    == NSControlStateValueOn) s.scenarioFlags |= ScenarioTests;
    if (_scenarioDocs.state     == NSControlStateValueOn) s.scenarioFlags |= ScenarioDocs;
    s.outputCodeOnly      = _outputCodeOnly.state      == NSControlStateValueOn;
    s.outputPreserveStyle = _outputPreserveStyle.state == NSControlStateValueOn;
    s.outputMentionRisks  = _outputMentionRisks.state  == NSControlStateValueOn;
    s.openaiEndpoint      = [self normalize:_openaiUrlField.stringValue];
    s.geminiEndpoint      = [self normalize:_geminiUrlField.stringValue];
    s.claudeEndpoint      = [self normalize:_claudeUrlField.stringValue];
    s.openaiDefaultModel  = [self normalize:_openaiModelField.stringValue];
    s.geminiDefaultModel  = [self normalize:_geminiModelField.stringValue];
    s.claudeDefaultModel  = [self normalize:_claudeModelField.stringValue];
    return s;
}

- (void)refreshPreview {
    Settings live = [self gatherSettings];
    std::string preview = PromptBuilder::buildPreview(live);
    [_previewTextView setString:[NSString stringWithUTF8String:preview.c_str()] ?: @""];
}

// Undo macOS smart substitutions so API keys / URLs stay as the plain
// ASCII the user typed. Covers en/em-dashes, curly quotes, ellipses.
- (std::string)normalize:(NSString*)input {
    if (!input) return "";
    NSMutableString* m = [input mutableCopy];
    // en-dash U+2013, em-dash U+2014, minus sign U+2212 → hyphen
    [m replaceOccurrencesOfString:@"–" withString:@"-" options:0 range:NSMakeRange(0, m.length)];
    [m replaceOccurrencesOfString:@"—" withString:@"-" options:0 range:NSMakeRange(0, m.length)];
    [m replaceOccurrencesOfString:@"−" withString:@"-" options:0 range:NSMakeRange(0, m.length)];
    // Curly double quotes → straight double quote
    [m replaceOccurrencesOfString:@"“" withString:@"\"" options:0 range:NSMakeRange(0, m.length)];
    [m replaceOccurrencesOfString:@"”" withString:@"\"" options:0 range:NSMakeRange(0, m.length)];
    // Curly single quotes → straight apostrophe
    [m replaceOccurrencesOfString:@"‘" withString:@"'"  options:0 range:NSMakeRange(0, m.length)];
    [m replaceOccurrencesOfString:@"’" withString:@"'"  options:0 range:NSMakeRange(0, m.length)];
    // Horizontal ellipsis → three dots
    [m replaceOccurrencesOfString:@"…" withString:@"..." options:0 range:NSMakeRange(0, m.length)];
    return std::string([m UTF8String] ?: "");
}

- (void)okPressed:(id)sender {
    Settings s = [self gatherSettings];
    Preferences::save(s);

    // Always use the secure peer's stringValue — they're kept in sync
    // on every keystroke, so either holds the authoritative value.
    //
    // Normalize typographic substitutions we can't fully prevent (en/em
    // dashes, curly quotes, ellipses) to their ASCII equivalents. API
    // keys are supposed to be plain ASCII; silently rewriting them
    // prevents "my key doesn't work" after macOS auto-correct flips a
    // hyphen.
    if (_openaiEdited)
        Keychain::save(Keychain::kOpenAIKey, [self normalize:_openaiKeySecure.stringValue]);
    if (_geminiEdited)
        Keychain::save(Keychain::kGeminiKey, [self normalize:_geminiKeySecure.stringValue]);
    if (_claudeEdited)
        Keychain::save(Keychain::kClaudeKey, [self normalize:_claudeKeySecure.stringValue]);

    [[NSNotificationCenter defaultCenter] postNotificationName:@"NppAIAPreferencesChanged" object:nil];
    [self _close];
}

- (void)cancelPressed:(id)sender { [self _close]; }

- (void)_close {
    NSWindow* parent = self.window.sheetParent;
    if (parent) [parent endSheet:self.window returnCode:NSModalResponseOK];
    else        [self.window close];
}

- (void)testConnectionPressed:(id)sender {
    Settings live = [self gatherSettings];
    Provider p = live.defaultProvider;

    std::string key;
    if      (p == Provider::OpenAI) key = _openaiEdited
        ? std::string([_openaiKeySecure.stringValue UTF8String] ?: "")
        : Keychain::load(Keychain::kOpenAIKey);
    else if (p == Provider::Gemini) key = _geminiEdited
        ? std::string([_geminiKeySecure.stringValue UTF8String] ?: "")
        : Keychain::load(Keychain::kGeminiKey);
    else if (p == Provider::Claude) key = _claudeEdited
        ? std::string([_claudeKeySecure.stringValue UTF8String] ?: "")
        : Keychain::load(Keychain::kClaudeKey);
    else {
        _testResultLabel.stringValue = @"Copilot test requires sign-in flow";
        _testResultLabel.textColor   = NSColor.systemOrangeColor;
        return;
    }

    if (key.empty()) {
        _testResultLabel.stringValue = @"No API key for this provider";
        _testResultLabel.textColor   = NSColor.systemRedColor;
        return;
    }

    EndpointOverrides eo;
    eo.openaiUrl = live.openaiEndpoint;
    eo.geminiUrl = live.geminiEndpoint;
    eo.claudeUrl = live.claudeEndpoint;

    _testResultLabel.stringValue = @"Testing…";
    _testResultLabel.textColor   = NSColor.secondaryLabelColor;

    __weak __typeof(self) weakSelf = self;
    ApiClient::listModels(p, key, eo, ^(const ModelListResult& r) {
        __strong __typeof(weakSelf) self = weakSelf;
        if (!self) return;
        if (r.ok) {
            self->_testResultLabel.stringValue = [NSString stringWithFormat:
                @"✓ %lu models available", (unsigned long)r.models.size()];
            self->_testResultLabel.textColor = NSColor.systemGreenColor;
        } else {
            self->_testResultLabel.stringValue = [NSString stringWithFormat:
                @"✗ %s", r.errorText.c_str()];
            self->_testResultLabel.textColor = NSColor.systemRedColor;
        }
    });
}

@end
