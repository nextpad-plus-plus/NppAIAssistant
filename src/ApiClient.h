/**
 * ApiClient.h — unified entry point for talking to OpenAI, Gemini,
 * Claude, and (via CopilotAuth) GitHub Copilot.
 *
 * All methods dispatch HTTP on a background queue and call the
 * completion block on the main queue. Caller is responsible for any
 * UI state changes (spinner, button enable) around the request.
 */
#ifndef NPPAIASSISTANT_API_CLIENT_H
#define NPPAIASSISTANT_API_CLIENT_H

#include <string>
#include <vector>

#include "Preferences.h"   // Provider enum

namespace NppAIAssistant {

struct LLMResult {
    bool         ok = false;
    std::string  content;       // reply text on success
    std::string  errorText;     // error message on failure
    int          statusCode = 0;
};

struct ModelListResult {
    bool                      ok = false;
    std::vector<std::string>  models;
    std::string               errorText;
    int                       statusCode = 0;
};

// Completion callback types. Typedef-ed so the .mm can forward-declare
// cleanly. Invoked on the main queue.
using LLMCompletion       = void (^)(const LLMResult& /*result*/);
using ModelListCompletion = void (^)(const ModelListResult& /*result*/);

// Per-provider endpoint override. An empty URL means "use the
// provider's default"; a non-empty URL replaces the default entirely.
//
// For Gemini, the URL is templated — use the literal substring
// `{model}` to mark where the model slug belongs. Defaults to
// `https://generativelanguage.googleapis.com/v1beta/models/{model}:generateContent`
// when blank.
struct EndpointOverrides {
    std::string openaiUrl;
    std::string geminiUrl;
    std::string claudeUrl;
};

class ApiClient {
public:
    // Send a prompt to the chosen provider. `fullPrompt` is the complete
    // message body (system preamble + user request) as produced by
    // PromptBuilder. Pass endpoint overrides to retarget the request at
    // a local or self-hosted service speaking the same wire format.
    //
    // For Provider::Copilot, `apiKey` must be the short-lived
    // copilotToken (CopilotTokens::copilotToken), not the OAuth token;
    // caller is expected to refresh via CopilotAuth first.
    static void send(Provider provider,
                     const std::string& apiKey,
                     const std::string& model,
                     const std::string& fullPrompt,
                     const EndpointOverrides& endpoints,
                     LLMCompletion completion);

    // Fetch the list of chat-capable models for `provider`. OpenAI
    // filters to gpt-*/chatgpt-*/o-series; Gemini filters to models
    // with generateContent; Claude returns every model.
    //
    // Note: model-list endpoints are siblings of the chat endpoints
    // (e.g. OpenAI's /v1/models vs /v1/chat/completions). Custom
    // servers often only implement the chat path — the model-list
    // fetch will fail silently in that case and fall back to the
    // default-model dropdown entry.
    static void listModels(Provider provider,
                           const std::string& apiKey,
                           const EndpointOverrides& endpoints,
                           ModelListCompletion completion);

    // Default model name used when the user hasn't explicitly picked
    // one yet. Matches the Windows defaults.
    static std::string defaultModel(Provider provider);

    // Short display name for the provider, used in menus + chat history.
    static std::string providerName(Provider provider);
};

}  // namespace NppAIAssistant

#endif
