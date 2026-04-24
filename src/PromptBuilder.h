/**
 * PromptBuilder.h — pure C++, no Foundation/AppKit dependency so this
 * module is unit-testable on its own. Produces the full system prompt
 * that gets prepended to the user's message, byte-for-byte identical
 * to the Windows upstream's buildEffectivePromptForConfig().
 *
 * The composition order is fixed:
 *     [Single-turn System]  ← response language, encoding, line-ending, detail
 *     [Output Rules]        ← preserve-style, mention-risks, code-only
 *     [Scenario Modules]    ← one line per enabled bit in Settings::scenarioFlags
 *     [User Request]        ← user-provided prompt text
 */
#ifndef NPPAIASSISTANT_PROMPT_BUILDER_H
#define NPPAIASSISTANT_PROMPT_BUILDER_H

#include <string>

#include "Preferences.h"

namespace NppAIAssistant {

struct BuildOptions {
    // When true, emits the "Return only the final replacement code or
    // text. Do not include markdown fences or explanation." rule. The
    // selection-action workflow (Refactor / Add Comments / Fix) sets
    // this so replies drop cleanly back into the editor.
    bool forceCodeOnlyOutput = false;

    // Line-ending preference ("LF" on macOS, "CRLF" on Windows). Defaults
    // to LF for this plugin since we target macOS — but the field is
    // explicit so tests can verify both branches.
    std::string lineEndingHint = "LF";
};

class PromptBuilder {
public:
    // Build the full prompt (system preamble + user request), ready to
    // send as the user message body. `userPrompt` is appended under the
    // [User Request] header.
    static std::string build(const Settings& settings,
                             const std::string& userPrompt,
                             const BuildOptions& opts = {});

    // Preview variant used by the Settings dialog's "Prompt Preview"
    // box — same preamble, but appends a placeholder user-request line.
    static std::string buildPreview(const Settings& settings,
                                    const BuildOptions& opts = {});
};

}  // namespace NppAIAssistant

#endif
