#include "PromptBuilder.h"

#include <sstream>

namespace NppAIAssistant {

namespace {

const char* replyLanguageLabel(ResponseLanguage rl, UiLanguage ui) {
    switch (rl) {
        case ResponseLanguage::TraditionalChinese: return "Traditional Chinese";
        case ResponseLanguage::English:            return "English";
        case ResponseLanguage::FollowInterface:
        default:
            // Windows derives this from the interface language. With
            // no i18n yet in the mac port we default to English; when
            // localization lands this will branch on `ui`.
            (void)ui;
            return "English";
    }
}

const char* encodingLabel(EncodingSuggestion e) {
    switch (e) {
        case EncodingSuggestion::UTF8:       return "UTF-8";
        case EncodingSuggestion::UTF8Bom:    return "UTF-8 with BOM";
        case EncodingSuggestion::Big5:       return "Big5";
        case EncodingSuggestion::ANSI:       return "ANSI / local code page";
        case EncodingSuggestion::CurrentDocument:
        default:                             return "the current document's encoding";
    }
}

const char* detailInstruction(DetailLevel d) {
    switch (d) {
        case DetailLevel::Concise:  return "Keep the answer short and focused";
        case DetailLevel::Detailed: return "Be thorough with reasoning, examples, and edge cases";
        case DetailLevel::Standard:
        default:                    return "Provide a balanced answer with the essential reasoning";
    }
}

void appendScenarioLines(std::ostringstream& os, std::uint32_t flags) {
    bool any = false;
    auto line = [&](const char* text) {
        if (!any) { os << "[Scenario Modules]\n"; any = true; }
        os << "- " << text << "\n";
    };
    if (flags & ScenarioExplain)
        line("Be ready to explain existing code, behavior, dependencies, or editor output.");
    if (flags & ScenarioFix)
        line("Prioritize identifying root causes and proposing the smallest correct fix.");
    if (flags & ScenarioRefactor)
        line("Favor maintainable refactors that preserve behavior unless asked otherwise.");
    if (flags & ScenarioTests)
        line("When useful, include or suggest focused automated tests.");
    if (flags & ScenarioDocs)
        line("When useful, produce clear developer-facing documentation or comments.");
    if (any) os << "\n";
}

void appendOutputRules(std::ostringstream& os, const Settings& s, bool forceCodeOnly) {
    bool any = false;
    auto line = [&](const char* text) {
        if (!any) { os << "[Output Rules]\n"; any = true; }
        os << "- " << text << "\n";
    };
    if (s.outputPreserveStyle)
        line("Preserve existing naming, formatting, and project style where possible.");
    if (s.outputMentionRisks)
        line("Briefly call out important risks, assumptions, or edge cases.");
    if (forceCodeOnly) {
        line("Return only the final replacement code or text. "
             "Do not include markdown fences or explanation.");
    } else if (s.outputCodeOnly) {
        line("When the task is code generation or code transformation, "
             "prefer directly usable output and keep explanation minimal.");
    }
    if (any) os << "\n";
}

void appendSingleTurnPreamble(std::ostringstream& os,
                              const Settings& s,
                              const BuildOptions& opts) {
    os << "[Single-turn System]\n";
    os << "- Treat this as a fully independent single-turn request. "
          "Do not rely on prior conversation.\n";
    os << "- Work only from the information in this message.\n";
    os << "- Reply language: "
       << replyLanguageLabel(s.responseLanguage, s.uiLanguage) << ".\n";
    os << "- Preferred encoding for generated code/text: "
       << encodingLabel(s.encoding) << ".\n";
    os << "- Preferred line ending style: " << opts.lineEndingHint << ".\n";
    os << "- " << detailInstruction(s.detailLevel) << ".\n";
    os << "- The answer may be pasted back into an editor or code file.\n";
    os << "\n";
}

}  // namespace

std::string PromptBuilder::build(const Settings& settings,
                                 const std::string& userPrompt,
                                 const BuildOptions& opts) {
    std::ostringstream os;
    appendSingleTurnPreamble(os, settings, opts);
    appendOutputRules(os, settings, opts.forceCodeOnlyOutput);
    appendScenarioLines(os, settings.scenarioFlags);
    if (!settings.customInstructions.empty()) {
        os << "[Custom Instructions]\n" << settings.customInstructions << "\n\n";
    }
    os << "[User Request]\n" << userPrompt;
    return os.str();
}

std::string PromptBuilder::buildPreview(const Settings& settings,
                                        const BuildOptions& opts) {
    std::ostringstream os;
    appendSingleTurnPreamble(os, settings, opts);
    appendOutputRules(os, settings, opts.forceCodeOnlyOutput);
    appendScenarioLines(os, settings.scenarioFlags);
    if (!settings.customInstructions.empty()) {
        os << "[Custom Instructions]\n" << settings.customInstructions << "\n\n";
    }
    os << "[User Request]\n"
          "<The actual user request or selected text will be inserted here>";
    return os.str();
}

}  // namespace NppAIAssistant
