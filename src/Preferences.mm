#import <Foundation/Foundation.h>

#include "Preferences.h"

#include <sys/stat.h>
#include <cstdlib>
#include <fstream>
#include <map>
#include <sstream>
#include <unistd.h>
#include <vector>

namespace NppAIAssistant {

namespace {

const char* kSectionHeader = "[Settings]";

const char* kKeySchemaVersion       = "schema_version";
const char* kKeyDefaultProvider     = "default_provider";
const char* kKeyUiLanguage          = "ui_language_preference";
const char* kKeyResponseLanguage    = "prompt_response_language";
const char* kKeyEncoding            = "prompt_encoding_preference";
const char* kKeyPreset              = "prompt_preset";
const char* kKeyDetailLevel         = "prompt_detail_level";
const char* kKeyScenarioFlags       = "prompt_scenario_flags";
const char* kKeyOutputCodeOnly      = "prompt_output_code_only";
const char* kKeyOutputPreserveStyle = "prompt_output_preserve_style";
const char* kKeyOutputMentionRisks  = "prompt_output_mention_risks";
const char* kKeyCustomInstructions  = "prompt_custom_instructions";
const char* kKeyRequireCtrlEnter    = "require_ctrl_enter";
const char* kKeyOpenAIEndpoint      = "openai_endpoint";
const char* kKeyGeminiEndpoint      = "gemini_endpoint";
const char* kKeyClaudeEndpoint      = "claude_endpoint";
const char* kKeyOpenAIDefaultModel  = "openai_default_model";
const char* kKeyGeminiDefaultModel  = "gemini_default_model";
const char* kKeyClaudeDefaultModel  = "claude_default_model";

std::string configDir() {
    const char* home = getenv("HOME");
    std::string dir = (home ? home : "") + std::string("/.nextpad++/plugins/Config");
    mkdir(dir.c_str(), 0755);  // idempotent; HOME/.nextpad++ already exists in practice
    return dir;
}

// --- tiny INI reader/writer ---------------------------------------------
// Not a general-purpose parser; only understands the two-section layout
// we produce ourselves. Matches Windows' line-based "key=value" shape.

using Kv = std::map<std::string, std::string>;

std::string trim(const std::string& s) {
    size_t a = s.find_first_not_of(" \t\r\n");
    if (a == std::string::npos) return "";
    size_t b = s.find_last_not_of(" \t\r\n");
    return s.substr(a, b - a + 1);
}

Kv readIniSection(const std::string& path, const std::string& section) {
    Kv out;
    std::ifstream f(path);
    if (!f.is_open()) return out;
    std::string line;
    bool inSection = false;
    while (std::getline(f, line)) {
        std::string t = trim(line);
        if (t.empty() || t[0] == ';' || t[0] == '#') continue;
        if (t.front() == '[' && t.back() == ']') {
            inSection = (t == section);
            continue;
        }
        if (!inSection) continue;
        size_t eq = t.find('=');
        if (eq == std::string::npos) continue;
        out[trim(t.substr(0, eq))] = trim(t.substr(eq + 1));
    }
    return out;
}

// Escape backslash, newline, carriage return, tab. Mirrors the Windows
// writer so custom_instructions round-trip between platforms.
std::string escape(const std::string& s) {
    std::string out;
    out.reserve(s.size());
    for (char c : s) {
        switch (c) {
            case '\\': out += "\\\\"; break;
            case '\n': out += "\\n";  break;
            case '\r': out += "\\r";  break;
            case '\t': out += "\\t";  break;
            default:   out += c;      break;
        }
    }
    return out;
}

std::string unescape(const std::string& s) {
    std::string out;
    out.reserve(s.size());
    for (size_t i = 0; i < s.size(); ++i) {
        if (s[i] == '\\' && i + 1 < s.size()) {
            char n = s[i + 1];
            if (n == 'n')      { out += '\n'; ++i; continue; }
            if (n == 'r')      { out += '\r'; ++i; continue; }
            if (n == 't')      { out += '\t'; ++i; continue; }
            if (n == '\\')     { out += '\\'; ++i; continue; }
        }
        out += s[i];
    }
    return out;
}

bool writeIni(const std::string& path, const Kv& kv,
              const std::vector<std::string>& keyOrder) {
    std::ofstream f(path, std::ios::trunc);
    if (!f.is_open()) return false;
    f << "; NppAIAssistant preferences\n";
    f << "; Schema is wire-compatible with the Windows upstream plugin.\n";
    f << "; API keys live in the macOS Keychain, not here.\n\n";
    f << kSectionHeader << "\n";
    for (const auto& k : keyOrder) {
        auto it = kv.find(k);
        if (it != kv.end()) {
            f << k << "=" << it->second << "\n";
        }
    }
    return static_cast<bool>(f);
}

int toInt(const std::string& v, int fallback) {
    if (v.empty()) return fallback;
    try { return std::stoi(v); } catch (...) { return fallback; }
}
std::uint32_t toU32(const std::string& v, std::uint32_t fallback) {
    if (v.empty()) return fallback;
    try { return static_cast<std::uint32_t>(std::stoul(v)); }
    catch (...) { return fallback; }
}
bool toBool(const std::string& v, bool fallback) {
    if (v.empty()) return fallback;
    return v == "1" || v == "true";
}

}  // namespace

std::string Preferences::filePath() {
    return configDir() + "/NppAIAssistant.ini";
}

Settings Preferences::load() {
    const std::string path = filePath();

    struct stat st;
    if (stat(path.c_str(), &st) != 0) {
        // First run — seed the file with defaults so the user can
        // inspect/edit it outside the GUI.
        Settings defaults;
        save(defaults);
        return defaults;
    }

    const Kv kv = readIniSection(path, kSectionHeader);
    Settings s;
    s.schemaVersion       = toInt (kv.count(kKeySchemaVersion)       ? kv.at(kKeySchemaVersion)       : "", 1);
    s.defaultProvider     = static_cast<Provider>(
                              toInt (kv.count(kKeyDefaultProvider)     ? kv.at(kKeyDefaultProvider)     : "", 0));
    s.uiLanguage          = static_cast<UiLanguage>(
                              toInt (kv.count(kKeyUiLanguage)          ? kv.at(kKeyUiLanguage)          : "", 0));
    s.responseLanguage    = static_cast<ResponseLanguage>(
                              toInt (kv.count(kKeyResponseLanguage)    ? kv.at(kKeyResponseLanguage)    : "", 0));
    s.encoding            = static_cast<EncodingSuggestion>(
                              toInt (kv.count(kKeyEncoding)            ? kv.at(kKeyEncoding)            : "", 0));
    s.preset              = static_cast<PromptPreset>(
                              toInt (kv.count(kKeyPreset)              ? kv.at(kKeyPreset)              : "", 0));
    s.detailLevel         = static_cast<DetailLevel>(
                              toInt (kv.count(kKeyDetailLevel)         ? kv.at(kKeyDetailLevel)         : "", 1));
    s.scenarioFlags       = toU32 (kv.count(kKeyScenarioFlags)       ? kv.at(kKeyScenarioFlags)       : "", 0);
    s.outputCodeOnly      = toBool(kv.count(kKeyOutputCodeOnly)      ? kv.at(kKeyOutputCodeOnly)      : "", false);
    s.outputPreserveStyle = toBool(kv.count(kKeyOutputPreserveStyle) ? kv.at(kKeyOutputPreserveStyle) : "", true);
    s.outputMentionRisks  = toBool(kv.count(kKeyOutputMentionRisks)  ? kv.at(kKeyOutputMentionRisks)  : "", false);
    s.customInstructions  = unescape(kv.count(kKeyCustomInstructions) ? kv.at(kKeyCustomInstructions) : "");
    s.requireCtrlEnter    = toBool(kv.count(kKeyRequireCtrlEnter)    ? kv.at(kKeyRequireCtrlEnter)    : "", false);
    s.openaiEndpoint      = kv.count(kKeyOpenAIEndpoint) ? kv.at(kKeyOpenAIEndpoint) : "";
    s.geminiEndpoint      = kv.count(kKeyGeminiEndpoint) ? kv.at(kKeyGeminiEndpoint) : "";
    s.claudeEndpoint      = kv.count(kKeyClaudeEndpoint) ? kv.at(kKeyClaudeEndpoint) : "";
    s.openaiDefaultModel  = kv.count(kKeyOpenAIDefaultModel) ? kv.at(kKeyOpenAIDefaultModel) : "";
    s.geminiDefaultModel  = kv.count(kKeyGeminiDefaultModel) ? kv.at(kKeyGeminiDefaultModel) : "";
    s.claudeDefaultModel  = kv.count(kKeyClaudeDefaultModel) ? kv.at(kKeyClaudeDefaultModel) : "";
    return s;
}

bool Preferences::save(const Settings& s) {
    Kv kv;
    kv[kKeySchemaVersion]       = std::to_string(s.schemaVersion);
    kv[kKeyDefaultProvider]     = std::to_string(static_cast<int>(s.defaultProvider));
    kv[kKeyUiLanguage]          = std::to_string(static_cast<int>(s.uiLanguage));
    kv[kKeyResponseLanguage]    = std::to_string(static_cast<int>(s.responseLanguage));
    kv[kKeyEncoding]            = std::to_string(static_cast<int>(s.encoding));
    kv[kKeyPreset]              = std::to_string(static_cast<int>(s.preset));
    kv[kKeyDetailLevel]         = std::to_string(static_cast<int>(s.detailLevel));
    kv[kKeyScenarioFlags]       = std::to_string(static_cast<unsigned long>(s.scenarioFlags));
    kv[kKeyOutputCodeOnly]      = s.outputCodeOnly      ? "1" : "0";
    kv[kKeyOutputPreserveStyle] = s.outputPreserveStyle ? "1" : "0";
    kv[kKeyOutputMentionRisks]  = s.outputMentionRisks  ? "1" : "0";
    kv[kKeyCustomInstructions]  = escape(s.customInstructions);
    kv[kKeyRequireCtrlEnter]    = s.requireCtrlEnter    ? "1" : "0";
    kv[kKeyOpenAIEndpoint]      = s.openaiEndpoint;
    kv[kKeyGeminiEndpoint]      = s.geminiEndpoint;
    kv[kKeyClaudeEndpoint]      = s.claudeEndpoint;
    kv[kKeyOpenAIDefaultModel]  = s.openaiDefaultModel;
    kv[kKeyGeminiDefaultModel]  = s.geminiDefaultModel;
    kv[kKeyClaudeDefaultModel]  = s.claudeDefaultModel;

    // Preserve a predictable key order across writes.
    std::vector<std::string> order = {
        kKeySchemaVersion,
        kKeyDefaultProvider,
        kKeyUiLanguage,
        kKeyRequireCtrlEnter,
        kKeyPreset,
        kKeyResponseLanguage,
        kKeyEncoding,
        kKeyDetailLevel,
        kKeyScenarioFlags,
        kKeyOutputCodeOnly,
        kKeyOutputPreserveStyle,
        kKeyOutputMentionRisks,
        kKeyCustomInstructions,
        kKeyOpenAIEndpoint,
        kKeyOpenAIDefaultModel,
        kKeyGeminiEndpoint,
        kKeyGeminiDefaultModel,
        kKeyClaudeEndpoint,
        kKeyClaudeDefaultModel,
    };
    return writeIni(filePath(), kv, order);
}

bool Preferences::saveKey(const std::string& key, const std::string& value) {
    Kv kv = readIniSection(filePath(), kSectionHeader);
    kv[key] = value;
    std::vector<std::string> order;
    order.reserve(kv.size());
    for (const auto& p : kv) order.push_back(p.first);
    return writeIni(filePath(), kv, order);
}

}  // namespace NppAIAssistant
