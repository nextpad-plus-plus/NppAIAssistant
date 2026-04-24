/**
 * test_prompt_builder.cpp — hand-rolled assertion suite mirroring
 * NppLLM's tests/test_core.cpp style. Compiled and run by hand during
 * development; CMake does not drive it.
 *
 *   clang++ -std=c++17 -Wall -O2 -I../src \
 *       ../src/PromptBuilder.cpp test_prompt_builder.cpp \
 *       -o test_prompt_builder
 *   ./test_prompt_builder
 *
 * Success criterion: final line reads "N passed, 0 failed".
 */
#include "PromptBuilder.h"
#include "Preferences.h"

#include <iostream>
#include <string>

using namespace NppAIAssistant;

static int g_passed = 0;
static int g_failed = 0;

static void checkImpl(bool cond, const char* expr, const char* file, int line) {
    if (cond) { ++g_passed; return; }
    ++g_failed;
    std::cerr << file << ":" << line << ": check failed: " << expr << "\n";
}
#define CHECK(cond) checkImpl((cond), #cond, __FILE__, __LINE__)

static bool contains(const std::string& hay, const std::string& needle) {
    return hay.find(needle) != std::string::npos;
}

int main() {
    // 1. Default settings — baseline preamble.
    {
        Settings s;
        std::string out = PromptBuilder::build(s, "hello");
        CHECK(contains(out, "[Single-turn System]"));
        CHECK(contains(out, "Reply language: English."));
        CHECK(contains(out, "Preferred line ending style: LF."));
        CHECK(contains(out, "Provide a balanced answer"));
        CHECK(contains(out, "[Output Rules]"));
        // Default has outputPreserveStyle=true, so that line is present:
        CHECK(contains(out, "Preserve existing naming"));
        // …risks+code-only default off, so neither should appear:
        CHECK(!contains(out, "call out important risks"));
        CHECK(!contains(out, "prefer directly usable output"));
        // No scenario flags by default.
        CHECK(!contains(out, "[Scenario Modules]"));
        CHECK(contains(out, "[User Request]\nhello"));
    }

    // 2. forceCodeOnlyOutput emits the replacement-text rule, regardless
    //    of the outputCodeOnly pref.
    {
        Settings s;
        BuildOptions o;
        o.forceCodeOnlyOutput = true;
        std::string out = PromptBuilder::build(s, "x", o);
        CHECK(contains(out, "Return only the final replacement code or text."));
        // And the softer codeOnly rule must NOT also appear.
        CHECK(!contains(out, "prefer directly usable output"));
    }

    // 3. outputCodeOnly=true with forceCodeOnly=false triggers the soft rule.
    {
        Settings s;
        s.outputCodeOnly = true;
        std::string out = PromptBuilder::build(s, "x");
        CHECK(contains(out, "prefer directly usable output"));
        CHECK(!contains(out, "Return only the final replacement code or text."));
    }

    // 4. Scenario flags — each bit adds exactly one line with the
    //    expected text, and enabling all five shows all five.
    {
        Settings s;
        s.scenarioFlags = ScenarioExplain;
        std::string out = PromptBuilder::build(s, "x");
        CHECK(contains(out, "[Scenario Modules]"));
        CHECK(contains(out, "Be ready to explain existing code"));
        CHECK(!contains(out, "Prioritize identifying root causes"));
    }
    {
        Settings s;
        s.scenarioFlags = ScenarioFix | ScenarioRefactor | ScenarioTests | ScenarioDocs;
        std::string out = PromptBuilder::build(s, "x");
        CHECK(contains(out, "Prioritize identifying root causes"));
        CHECK(contains(out, "Favor maintainable refactors"));
        CHECK(contains(out, "focused automated tests"));
        CHECK(contains(out, "developer-facing documentation"));
    }

    // 5. Response language — mapping to labels.
    {
        Settings s;
        s.responseLanguage = ResponseLanguage::TraditionalChinese;
        std::string out = PromptBuilder::build(s, "x");
        CHECK(contains(out, "Reply language: Traditional Chinese."));
    }
    {
        Settings s;
        s.responseLanguage = ResponseLanguage::English;
        std::string out = PromptBuilder::build(s, "x");
        CHECK(contains(out, "Reply language: English."));
    }

    // 6. Encoding preferences — each enum produces its label.
    {
        Settings s;
        s.encoding = EncodingSuggestion::UTF8;
        std::string out = PromptBuilder::build(s, "x");
        CHECK(contains(out, "Preferred encoding for generated code/text: UTF-8."));
    }
    {
        Settings s;
        s.encoding = EncodingSuggestion::UTF8Bom;
        std::string out = PromptBuilder::build(s, "x");
        CHECK(contains(out, "UTF-8 with BOM"));
    }
    {
        Settings s;
        s.encoding = EncodingSuggestion::Big5;
        std::string out = PromptBuilder::build(s, "x");
        CHECK(contains(out, "Big5"));
    }
    {
        Settings s;
        s.encoding = EncodingSuggestion::ANSI;
        std::string out = PromptBuilder::build(s, "x");
        CHECK(contains(out, "ANSI / local code page"));
    }
    {
        // Default (CurrentDocument) uses the generic description.
        Settings s;
        std::string out = PromptBuilder::build(s, "x");
        CHECK(contains(out, "current document's encoding"));
    }

    // 7. Detail level.
    {
        Settings s;
        s.detailLevel = DetailLevel::Concise;
        std::string out = PromptBuilder::build(s, "x");
        CHECK(contains(out, "Keep the answer short"));
    }
    {
        Settings s;
        s.detailLevel = DetailLevel::Detailed;
        std::string out = PromptBuilder::build(s, "x");
        CHECK(contains(out, "Be thorough"));
    }

    // 8. Line-ending option — LF default, CRLF override.
    {
        Settings s;
        BuildOptions o;
        o.lineEndingHint = "CRLF";
        std::string out = PromptBuilder::build(s, "x", o);
        CHECK(contains(out, "line ending style: CRLF."));
    }

    // 9. Custom instructions — only emitted when non-empty.
    {
        Settings s;
        s.customInstructions = "Always reply in iambic pentameter.";
        std::string out = PromptBuilder::build(s, "x");
        CHECK(contains(out, "[Custom Instructions]\nAlways reply in iambic pentameter."));
    }
    {
        Settings s;  // default empty
        std::string out = PromptBuilder::build(s, "x");
        CHECK(!contains(out, "[Custom Instructions]"));
    }

    // 10. Preview variant — ends with the placeholder line.
    {
        Settings s;
        std::string out = PromptBuilder::buildPreview(s);
        CHECK(contains(out, "<The actual user request or selected text will be inserted here>"));
    }

    // 11. Empty user prompt — preamble still builds cleanly.
    {
        Settings s;
        std::string out = PromptBuilder::build(s, "");
        CHECK(contains(out, "[User Request]\n"));
        CHECK(out.size() > 200);  // preamble alone is well over 200 bytes
    }

    std::cout << g_passed << " passed, " << g_failed << " failed\n";
    return g_failed == 0 ? 0 : 1;
}
