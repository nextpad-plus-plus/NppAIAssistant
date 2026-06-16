/**
 * Preferences.h — non-secret settings persistence for NppAIAssistant.
 *
 * Schema is wire-compatible with the Windows upstream: same key names,
 * same integer codings, same 0/1 bool encoding. Stored as INI at
 *   <NPPM_GETPLUGINSCONFIGDIR>/NppAIAssistant.ini
 *   (e.g. ~/Library/Application Support/Nextpad++/plugins/Config/NppAIAssistant.ini)
 * under the [Settings] section.
 *
 * API-style keys (openai_apikey, gemini_apikey, claude_apikey,
 * copilot_oauth_token) live in the Keychain, not here — see Keychain.h.
 */
#ifndef NPPAIASSISTANT_PREFERENCES_H
#define NPPAIASSISTANT_PREFERENCES_H

#include <cstdint>
#include <string>

namespace NppAIAssistant {

// Enum values mirror Windows integer codings exactly so an INI file
// copied between platforms parses identically.
enum class Provider : int {
    OpenAI  = 0,
    Gemini  = 1,
    Claude  = 2,
    Copilot = 3,
};

enum class UiLanguage : int {
    FollowNotepadPP = 0,
    English         = 1,
    Chinese         = 2,  // Traditional Chinese
};

enum class ResponseLanguage : int {
    FollowInterface     = 0,
    TraditionalChinese  = 1,
    English             = 2,
};

enum class EncodingSuggestion : int {
    CurrentDocument = 0,
    UTF8            = 1,
    UTF8Bom         = 2,
    Big5            = 3,
    ANSI            = 4,
};

enum class PromptPreset : int {
    Manual        = 0,
    CodeFix       = 1,
    Refactor      = 2,
    Explain       = 3,
    GenerateTests = 4,
    WriteDocs     = 5,
};

enum class DetailLevel : int {
    Concise  = 0,
    Standard = 1,
    Detailed = 2,
};

// Bitflags matching Windows `prompt_scenario_flags` layout.
enum ScenarioFlag : std::uint32_t {
    ScenarioExplain  = 1u << 0,
    ScenarioFix      = 1u << 1,
    ScenarioRefactor = 1u << 2,
    ScenarioTests    = 1u << 3,
    ScenarioDocs     = 1u << 4,
};

// The settings bundle. Defaults here match Windows defaults exactly
// (see SettingsStorage.cpp and NppAIAssistant.cpp line ~734).
//
// Endpoint override semantics: empty string → use the provider's
// default URL baked into ApiClient. Non-empty → use the override
// verbatim (the Gemini default uses a `{model}` placeholder; overrides
// may too and it gets substituted at request time).
struct Settings {
    Provider           defaultProvider       = Provider::OpenAI;
    UiLanguage         uiLanguage            = UiLanguage::FollowNotepadPP;
    ResponseLanguage   responseLanguage      = ResponseLanguage::FollowInterface;
    EncodingSuggestion encoding              = EncodingSuggestion::CurrentDocument;
    PromptPreset       preset                = PromptPreset::Manual;
    DetailLevel        detailLevel           = DetailLevel::Standard;
    std::uint32_t      scenarioFlags         = 0;
    bool               outputCodeOnly        = false;
    bool               outputPreserveStyle   = true;
    bool               outputMentionRisks    = false;
    std::string        customInstructions;
    bool               requireCtrlEnter      = false;
    int                schemaVersion         = 1;

    // Optional per-provider endpoint overrides — blank = use default.
    std::string        openaiEndpoint;
    std::string        geminiEndpoint;
    std::string        claudeEndpoint;

    // Optional per-provider default model. Blank falls back to
    // ApiClient::defaultModel(). Persists across launches so someone
    // using a local provider with a non-standard slug (e.g. an
    // AnythingLLM workspace name) doesn't have to retype it.
    std::string        openaiDefaultModel;
    std::string        geminiDefaultModel;
    std::string        claudeDefaultModel;
};

class Preferences {
public:
    // Returns the full path to the INI file, creating the parent
    // directory if it doesn't already exist.
    static std::string filePath();

    // Load from disk. On first run (file missing) returns defaults and
    // writes them back so the file exists for the user to inspect.
    static Settings load();

    // Write in place. Preserves the order of keys under [Settings] by
    // always writing the full known set.
    static bool save(const Settings& s);

    // Helper for writing from NSUserDefaults-style single-key updates
    // (mostly for tests and future one-off writers).
    static bool saveKey(const std::string& key, const std::string& value);
};

}  // namespace NppAIAssistant

#endif
