# NppAIAssistant — macOS Port Plan

Source of truth for the port. Written before any code is committed.
Update in lockstep with implementation.

## Scope

Port `notepad-plus-plus-mac/nppPluginsWin64/NppAIAssistant` (upstream by
PingKuei Lin 
a 3-provider AI chat panel with scenario-tuned prompt builder
and selection-action context menu) to macOS as a native AppKit plugin
against host v1.0.4 and the plugin ABI in `NppPluginInterfaceMac.h`.

The Windows panel UI is rudimentary and crowded (see reference
screenshot — 7 controls crammed into a single row with clipped labels).
The mac port will match the Windows **feature set 1:1** but ship a
cleaner AppKit layout. Zoom In / Zoom Out buttons are dropped per
user's instruction. Settings sheet will mirror the Windows layout
exactly, field-for-field, in mac-native controls.

## Feature parity vs Windows (verbatim from upstream)

| Feature | Windows | macOS port |
|---|---|---|
| Providers | OpenAI, Gemini, Claude, GitHub Copilot | same |
| Dock panel | yes (right dock) | yes (via `NPPM_DMM_REGISTERPANEL`) |
| Chat history | in-memory only, not persisted | same |
| Streaming | none — all HTTP blocking | same (blocking with async dispatch) |
| A+ / A− font buttons | yes | **dropped** (per user) |
| Sign-in button (Copilot) | yes, OAuth device flow | yes |
| Context menu on selection | Explain, Refactor, Add Comments, Fix | same |
| Settings: per-provider API keys | DPAPI-encrypted `.key` files | **macOS Keychain** |
| Settings: plain prefs | INI in `%APPDATA%\Notepad++\plugins\config\` | INI in `~/.notepad++/plugins/Config/` |
| Settings: preset + response language + encoding + detail + scenario flags + output rules | 17 persisted keys | same schema + filenames |
| Prompt builder (Single-turn + Scenario + Output Rules + User) | yes | same exact composition |
| i18n | hardcoded English + Traditional Chinese, auto-detect from `NPPM_GETNATIVELANGFILENAME` | English-only in v1.0.0, localize via `NppLocalizer` follow-up |
| Menu items | 6 (Open / Explain / Refactor / Comment / Fix / Settings…) | same |

## Architecture & file layout

```
nppPluginsMacOS/NppAIAssistant/
├── CMakeLists.txt                    # universal arm64+x86_64 Release build, install to ~/.notepad++/plugins/NppAIAssistant/
├── README.md
├── PORT_PLAN.md                      # (this file)
├── resources/
│   └── toolbar.png                   # toolbar icon for "Open AI Assistant"
├── src/
│   ├── PluginMain.mm                 # ABI exports, menu registration, panel host, context-menu wiring
│   ├── AssistantPanelView.h/mm       # NSView subclass = the dock panel
│   ├── SettingsWindowController.h/mm # settings window (matches Windows layout)
│   ├── PromptBuilder.h/cpp           # pure C++ — composes system prompt from config (shared, testable)
│   ├── ApiClient.h/mm                # thin adapter over HTTPClient for OpenAI/Gemini/Claude/Copilot
│   ├── CopilotAuth.h/mm              # OAuth device-code state machine (polling, refresh, persistence)
│   ├── Preferences.h/mm              # INI read/write for non-secret prefs (reused IniDoc pattern)
│   ├── Keychain.h/mm                 # Security-framework wrapper for API keys (replaces DPAPI)
│   ├── EditorHelpers.h/mm            # selection read/replace via Scintilla (forked from NppLLM)
│   ├── HTTPClient.h/mm               # NSURLSession blocking POST/GET with headers (reused from NppLLM, minor trim)
│   └── tests/
│       └── test_prompt_builder.cpp   # PromptBuilder unit tests
└── build/
```

### Reuse map vs NppLLM

| NppLLM module | NppAIAssistant treatment | Why |
|---|---|---|
| `HTTPClient.h/mm` | **copy + trim** (keep blocking POST/GET, drop streaming) | works identically; Copilot + Gemini just add headers |
| `ConfigManager`'s `IniDoc` + parser | **extract → `Preferences.h/mm`** | reuse parse/write; schema is different |
| `EditorHelpers.h/mm` | **copy** | identical Scintilla messaging |
| `RequestFormatters.cpp/h` | **new in this repo** (Gemini absent from NppLLM) | different shape — 4 providers here, only 3 in NppLLM |
| `ResponseParsers.cpp/h` | **new** | same reason |
| `StreamParser.h/cpp` | **not ported** | plugin is non-streaming |
| `EditorHelpers` test harness | **adapt** for PromptBuilder | new test suite |

Rationale for not cross-importing: keeping the plugins independently
buildable (no "shared" parent folder) matches the convention of every
other macOS plugin in the fleet. Small duplication, easier to ship.

## UI: dock panel design

The Windows panel is one row of 7 controls stacked above a flat
read-only text box. It looks cramped. Mac version: compose vertically
where it makes sense and use NSStackView for spacing.

```
┌─ AI Assistant ────────────────────────────── ⤢ ✕ ─┐  PanelFrame titlebar (host provides)
├────────────────────────────────────────────────────┤
│ Provider ▾  Model ▾          Sign in   Settings  Clear │  top toolbar (NSStackView, 28pt row)
├────────────────────────────────────────────────────┤
│                                                    │
│                                                    │
│   (chat history — NSTextView, read-only,           │
│    selectable, word-wrap, monospace blocks)        │
│                                                    │
│                                                    │
├────────────────────────────────────────────────────┤
│ ┌────────────────────────────────────────────┐ Send │  input row: NSTextView (3-line default),
│ │ input field…                               │      │  resizable vertically via split view,
│ └────────────────────────────────────────────┘      │  Send button right, Cmd+Enter or Enter
└────────────────────────────────────────────────────┘
```

- **Provider menu**: NSPopUpButton — OpenAI / Gemini / Claude / Copilot
- **Model menu**: NSPopUpButton — populated from provider's list API,
  falls back to defaults if no API key
- **Sign in**: shown only when Copilot selected (via hidden/visible
  binding); text toggles "Sign in" ↔ "Cancel" during device flow
- **Clear**: wipes the chat history (in-memory, NSTextView)
- **Settings**: opens `SettingsWindowController` as a sheet on the main window
- **Chat history**: `NSTextView` with an attributed-string writer —
  user turns in bold, assistant turns in regular weight, timestamps
  muted; no markdown rendering (matches Windows)
- **Input field**: `NSTextView` inside a bordered scroll view. Enter to
  send if "Require Ctrl+Enter" pref is off; ⌃↵ to send if pref is on;
  ⇧↵ always inserts a newline. Mac translates the Windows pref to ⌃↵.
- **Send**: NSButton, disabled when input is empty or a request is
  in flight

No zoom buttons. No titlebar of our own — the host's `PanelFrame`
provides that (pop-out + close buttons are free). Panel is registered
via `NPPM_DMM_REGISTERPANEL` with title `"AI Assistant"`.

## UI: Settings window (1:1 mirror of Windows)

Per user's instruction the settings look "exactly the same" as the
Windows screenshot. Using NSBox for the group frames to match Windows
GroupBox visuals; left-aligned labels + right-aligned fields; secure
NSSecureTextField for API keys.

Layout sections top to bottom, matching Windows (`IDD_AIASSISTANT_SETTINGS`):

1. **API keys** (3 secure text fields, inline labels on left)
   - OpenAI / Gemini / Claude
2. **Default Provider** (NSBox group)
   - "Select default AI provider" — NSPopUpButton
   - "Language" — NSPopUpButton (Follow Notepad++ / English / 中文)
   - "Require Ctrl+Enter to send from AI panel" — NSButton checkbox
3. **Single-turn Prompt Profile** (NSBox)
   - Preset, Response language, Encoding suggestion, Response detail — four NSPopUpButtons
4. **Scenario Modules** (NSBox)
   - 5 NSButton checkboxes: Explain code / Fix bugs / Refactor / Generate tests / Write docs
5. **Output Rules** (NSBox)
   - 3 NSButton checkboxes: Code only when suitable / Preserve project style / Mention risks and assumptions
6. **Prompt Preview** (NSBox)
   - Multi-line read-only NSTextView reflecting the composed system prompt. Re-runs `PromptBuilder::build(...)` on any field change.
7. **How to get API Keys** (NSBox)
   - 3 static labels (platform.openai.com / ai.google.dev / console.anthropic.com)
8. **Footer buttons**
   - "Test Default Connection" (left) / "OK" / "Cancel" (right)

Uses autolayout with explicit widths matching the Windows 380×590
design proportions. On OK: write Keychain entries (only if field
changed — avoid overwriting with empty masked values), then write
Preferences INI, dispatch `NPPAIPreferencesChanged` notification.
On Cancel: discard.

## Persistence

### API keys → macOS Keychain

Service name: `NppAIAssistant` (generic password entries). Account
name matches the Windows key name so migration paths are symmetrical:

| Account | Holds |
|---|---|
| `openai_apikey` | OpenAI key |
| `gemini_apikey` | Gemini key |
| `claude_apikey` | Claude key |
| `copilot_oauth_token` | Copilot OAuth access token (refreshable; not the short-lived chat token) |

Wrapper at `Keychain.h/mm`:
- `saveKey(service, account, value)` → `SecItemAdd` / `SecItemUpdate`
- `loadKey(service, account)` → `SecItemCopyMatching` returning NSString or nil
- `deleteKey(service, account)` → `SecItemDelete`
- `hasKey(service, account)` → existence check

On first run the wrapper tries to import any legacy Windows DPAPI blobs
(there won't be any on mac but the symmetry keeps future tooling
simple).

### Non-secret prefs → INI

Path: `~/.notepad++/plugins/Config/NppAIAssistant.ini`
Section: `[Settings]`
Keys (same names as Windows, value formats preserved for
cross-platform parity):

```
schema_version=1
default_provider=0
ui_language_preference=0
prompt_response_language=0
prompt_encoding_preference=0
prompt_preset=0
prompt_detail_level=1
prompt_scenario_flags=0
prompt_output_code_only=0
prompt_output_preserve_style=1
prompt_output_mention_risks=0
prompt_custom_instructions=
require_ctrl_enter=0
```

`Preferences.h/mm` wraps a tiny key/value INI parser — the one used in
NppLLM's ConfigManager fits here unchanged.

## PromptBuilder — shared C++

Pure C++ (`.cpp/.h`), no Objective-C deps. Input: a `Config` struct.
Output: the final system prompt string. Identical structure to Windows
`buildEffectivePromptForConfig()`:

```
[Single-turn System]
- Treat this as a fully independent single-turn request. Do not rely on prior conversation.
- Work only from the information in this message.
- Reply language: <responseLanguage>.
- Preferred encoding for generated code/text: <encoding>.
- Preferred line ending style: <lineEnding>.
- <detailInstruction>.
- The answer may be pasted back into an editor or code file.

[Output Rules]
- Preserve existing naming, formatting, and project style where possible.  (if preserveStyle)
- Briefly call out important risks, assumptions, or edge cases.            (if mentionRisks)
- Return only the final replacement code or text. …                       (if forceCodeOnly / selection replace)

[Scenario Modules]
- …                                                                       (one line per enabled flag)

[User Request]
<user text>
```

Unit tests verify:
- Each preset produces expected system prompt for canonical input
- Toggling each Scenario flag adds exactly one predicted line
- `forceCodeOnly=true` overrides the `codeOnly` output rule
- Line-ending preference on mac defaults to LF (diverges from
  Windows CRLF default — documented)

Test rig: same approach as NppLLM (`tests/test_core.cpp`) — handroll
assertions, count pass/fail, run under CMake or directly.

## Menu commands

6 FuncItems, matching Windows order:

| Index | Label | Shortcut | Handler |
|---|---|---|---|
| 0 | Open AI Assistant | ⌘⇧A | `cmdTogglePanel()` |
| 1 | Explain Selection | — | `cmdExplainSelection()` |
| 2 | Refactor Selection | — | `cmdRefactorSelection()` |
| 3 | Add Comments to Selection | — | `cmdAddComments()` |
| 4 | Fix Selection | — | `cmdFixSelection()` |
| 5 | Settings… | — | `cmdOpenSettings()` |

Shortcut ⌘⇧A for the primary (Windows has none — we add one because
mac users expect keyboard access to dock panels). Toolbar icon on
index 0 via `NPPM_ADDTOOLBARICON_FORDARKMODE`.

## Selection-action flow

For Refactor / Add Comments / Fix:

1. `EditorHelpers::getSelection(sci)` → UTF-8 string
2. Compose user-prompt = `<action verb>: \n\n <selection text>`
3. `PromptBuilder::build(config, userPrompt, forceCodeOnly=true)`
4. Dispatch HTTP call to current provider on a background queue
   (`dispatch_async`, `NSURLSession` completion on main)
5. On success, if reply doesn't start with `[Error]` / `[Notice]`,
   call `EditorHelpers::replaceSelection(sci, replyText)` wrapped in
   `SCI_BEGINUNDOACTION` / `SCI_ENDUNDOACTION`
6. Append user-prompt + reply to chat history in the panel (so the
   action leaves a visible trail)

For Explain: step 4 stays, step 5 is skipped — reply goes only to
the panel.

## HTTP & threading

- `HTTPClient` (reused from NppLLM): `performBlocking(url, body, headers, &result)`.
- Call sites wrap in `dispatch_async(dispatch_get_global_queue(...), ^{ … dispatch_async(main_queue, ^{ UI updates }) })` to keep the UI responsive.
- A single in-flight flag per panel prevents double-submit; Send button is disabled while a request runs.
- No streaming (plugin is non-streaming upstream).

## GitHub Copilot device-code flow

State machine in `CopilotAuth.mm`:

```
Idle ── Sign in ──▶ InitiatingDeviceCode ──▶ ShowUserCode (opens browser)
  ▲                                               │
  │                                               ▼
  └── Cancel / Error / Timeout ────────── PollingAccessToken (NSTimer, interval from server, default 5s)
                                                  │ success
                                                  ▼
                                        Authenticated (token → Keychain)
                                                  │
                                                  │ 60s before expiry
                                                  ▼
                                             RefreshToken
```

State persisted in Keychain under `copilot_oauth_token`. UI bindings:
panel's Sign in button title toggles, status label (transient — we'll
show it as an NSTextField overlay when `InitiatingDeviceCode` /
`ShowUserCode` / `PollingAccessToken`).

## Localization

v1.0.0 ships English only. All user-facing strings wrapped in
`NppLocalizer translate:` so later localization via host's
137-language map is trivial. Japanese / Traditional Chinese
translations from upstream are available for future import.

## Build

```cmake
# CMakeLists.txt (mirror of NppLLM)
cmake_minimum_required(VERSION 3.20)
project(NppAIAssistant LANGUAGES CXX OBJCXX)
set(CMAKE_OSX_DEPLOYMENT_TARGET "11.0")
set(CMAKE_OSX_ARCHITECTURES "arm64;x86_64")
# -fobjc-arc, -fvisibility=hidden, NPP_MACOS_DIR + NPP_WIN_DIR for headers
# target: NppAIAssistant.dylib
# install to ~/.notepad++/plugins/NppAIAssistant/
```

Installed layout:
```
~/.notepad++/plugins/NppAIAssistant/
  NppAIAssistant.dylib
  toolbar.png
```

## Deliverable & release targets

- v1.0.0: every Windows feature present, dark-mode aware, English
  UI, tested against live OpenAI + Claude + Gemini + Copilot.
- Plugin list entry with `dylib-id`, `dylib-built`, `npp-min-version: 1.0.4`.
- README covering setup + 4 providers + Copilot OAuth flow + Keychain
  storage policy.

## Work breakdown

1. Scaffolding: CMakeLists, directory skeleton, toolbar.png
2. `HTTPClient` + `EditorHelpers` + `Preferences` + `Keychain` + `PromptBuilder` (+ tests for PromptBuilder)
3. `ApiClient` — OpenAI / Gemini / Claude call + listModels
4. `AssistantPanelView` + `PluginMain` (panel register, menu commands, context menu wiring)
5. `SettingsWindowController` — full 1:1 mirror of Windows settings layout
6. Selection-action workflow wired end-to-end
7. `CopilotAuth` + Sign-in flow
8. Localization pass, icons, final polish
9. Release zip, sha256 + dylib-id, plugin list entry, GitHub release

## Known deltas from Windows

- No A+ / A− zoom buttons (dropped per user)
- Line-ending default is LF on mac (Windows defaults to CRLF) — documented in Settings ❋
- API key storage is Keychain (Windows uses DPAPI) — invisible to the user
- `Ctrl+Enter` mapped to `⌃↵` on mac (literal Control-Return, not ⌘↵) to match the Windows mental model
- ⌘⇧A shortcut added for the primary "Open AI Assistant" (Windows has none)

## Open questions (answer before implementation)

None blocking. Starting work.
