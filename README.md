# NppAIAssistant for Notepad++ (macOS)

A dockable AI-chat side panel for the macOS port of Notepad++. Talk to
OpenAI, Google Gemini, Anthropic Claude, or any **OpenAI-compatible
local server** (LM Studio, AnythingLLM, Ollama-via-openai-shim, LiteLLM,
vLLM, LocalAI, …) without leaving the editor.

Ported from the Windows upstream
[NppAIAssistant](https://github.com/notepad-plus-plus/NppAIAssistant)
by Don HO, with macOS-native AppKit UI and full provider-endpoint
customization.

## Requirements

- macOS 11.0+ (arm64 or x86_64 — universal binary)
- Notepad++ for macOS v1.0.4 or later

## Features

| | |
|---|---|
| **Providers** | OpenAI, Gemini, Claude, plus any endpoint speaking one of those wire formats |
| **Dock panel** | Right side of the main window, via `NPPM_DMM_REGISTERPANEL` |
| **Context menu** | Explain / Refactor / Add Comments / Fix on the current selection |
| **Scenario-tuned prompts** | 5 scenario flags × 3 output rules × 3 detail levels, composed into a system preamble |
| **Prompt preview** | Settings sheet renders the composed prompt live as you tweak |
| **Per-provider default model** | Persists across launches — set once, forget |
| **Per-provider endpoint override** | Point OpenAI at `http://localhost:1234/v1/chat/completions` and you're driving LM Studio; point it at your AnythingLLM OpenAI proxy and the model field becomes a workspace slug |
| **Keychain storage** | API keys live in the macOS login Keychain, not a plaintext file |
| **⌘+/-/0 zoom** | Rescales the chat-history font; ⌘0 resets |
| **Dark mode aware** | Panel follows the system appearance |

## Install

```bash
cd /path/to/NppAIAssistant
mkdir build && cd build
cmake .. -DCMAKE_BUILD_TYPE=Release
make -j$(sysctl -n hw.ncpu)
make install   # → ~/.notepad++/plugins/NppAIAssistant/
```

Restart Notepad++. The plugin appears under **Plugins → NppAIAssistant**.

## Configure

**Plugins → NppAIAssistant → Open AI Assistant** (⌘⇧A) opens the dock
panel. The ⋯ button in the panel toolbar opens **Settings…** and
**Clear conversation**.

The Settings sheet has three input columns per provider:

- **API Key** — stored in Keychain (service: `NppAIAssistant`).
  "Show keys" toggles masked ↔ cleartext for all three at once.
- **Endpoint URL** *(optional override)* — leave blank to use the
  provider's default. Useful for local or self-hosted servers.
  Gemini URLs may use `{model}` as a substitution placeholder.
- **Default model** — prefilled in the panel's Model combo on every
  launch. Leave blank to use the provider's canonical default.

### Example: point "OpenAI" at AnythingLLM

| Setting | Value |
|---|---|
| API Key (OpenAI row) | Your AnythingLLM developer API key |
| Endpoint URL (OpenAI row) | `http://localhost:3001/api/v1/openai/chat/completions` |
| Default model (OpenAI row) | Your workspace slug (e.g. `my-workspace`) |

Save. The panel now routes all "OpenAI" requests to your local
AnythingLLM workspace, using its OpenAI-compatible proxy.

### Example: LM Studio

```
API Key:      any non-empty string (LM Studio ignores it)
Endpoint URL: http://localhost:1234/v1/chat/completions
Default model: your loaded model id (e.g. qwen2.5-7b-instruct-q4)
```

## Menu commands

| Menu item | Shortcut | Action |
|---|---|---|
| Open AI Assistant | ⌘⇧A | Toggle the dock panel |
| Explain Selection | — | Ask the model to explain the selection; reply goes to the panel only |
| Refactor Selection | — | Replace the selection with a refactored version |
| Add Comments to Selection | — | Replace the selection with a commented version |
| Fix Selection | — | Replace the selection with a bugfix |
| Settings… | — | Open the Settings sheet |

Selection actions that replace code use `forceCodeOnlyOutput = true`
in the prompt builder so the reply comes back as plain replacement
code without markdown fences.

## Development

### Unit tests

```bash
cd tests
clang++ -std=c++17 -Wall -O2 -I../src \
    ../src/PromptBuilder.cpp \
    test_prompt_builder.cpp -o test_prompt_builder
./test_prompt_builder
```

Expected: `36 passed, 0 failed`. Tests cover every scenario flag,
every output rule, every preset / encoding / detail enum, custom
instructions round-trip, preview variant, empty prompt.

### Module layout

| File | Purpose |
|---|---|
| `PluginMain.mm` | Plugin ABI, 6 menu commands, panel registration |
| `AssistantPanelView.{h,mm}` | Dock panel NSView — chat history, input, toolbar |
| `SettingsWindowController.{h,mm}` | Settings sheet (Credentials / Default Provider / Prompt Profile / Scenarios / Output Rules / Preview) |
| `PromptBuilder.{h,cpp}` | Pure-C++ system-prompt composer (testable) |
| `ApiClient.{h,mm}` | Per-provider request/response + listModels; async via GCD |
| `HTTPClient.{h,mm}` | Thin NSURLSession blocking POST/GET wrapper |
| `Preferences.{h,mm}` | INI settings in `~/.notepad++/plugins/Config/NppAIAssistant.ini` |
| `Keychain.{h,mm}` | Security-framework wrapper for API keys |
| `EditorHelpers.{h,mm}` | Scintilla selection read / replace helpers |
| `CopilotAuth.{h,mm}` | Placeholder for GitHub Copilot OAuth (planned) |

## Compatibility notes

- **API keys**: stored in the login Keychain, not on disk. DPAPI blobs
  from the Windows upstream aren't transferable — users re-enter keys
  on first macOS run.
- **Smart substitutions**: all credential fields run with macOS
  auto-dash / auto-quote / auto-replacement disabled, and the save
  path normalizes any leaked en/em-dashes and curly quotes back to
  ASCII. Paste keys freely without worrying about typographic
  rewrites.
- **Send**: triggered only by the Send button. Enter inserts a
  newline.
- **⌘+/-/0**: scale the chat-history font size within 7–28pt.

## License

GPL, same as the upstream plugin.

## Credits

- Upstream plugin: [notepad-plus-plus/NppAIAssistant](https://github.com/notepad-plus-plus/NppAIAssistant) by Don HO
- macOS port: Andrey Letov
