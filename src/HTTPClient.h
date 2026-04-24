/**
 * HTTPClient.h — thin NSURLSession wrapper used by ApiClient and
 * CopilotAuth. Generic headers map rather than per-provider switches
 * because this plugin hits four very differently-shaped APIs:
 *   - OpenAI:   Authorization: Bearer …
 *   - Gemini:   x-goog-api-key: …
 *   - Claude:   x-api-key + anthropic-version
 *   - Copilot:  multiple headers incl. Editor-Version, bearer tokens,
 *               device-flow form posts, etc.
 *
 * Non-streaming. All requests are blocking from the caller's point of
 * view — callers are expected to wrap calls in dispatch_async(global,
 * ...) to stay off the main thread.
 */
#ifndef NPPAIASSISTANT_HTTP_CLIENT_H
#define NPPAIASSISTANT_HTTP_CLIENT_H

#include <map>
#include <string>

namespace NppAIAssistant {

struct HTTPResponse {
    bool        ok         = false;        // true iff statusCode in [200, 300)
    int         statusCode = 0;             // HTTP status; 0 means transport error
    std::string body;                       // raw response bytes
    std::string errorText;                  // "" on success
};

class HTTPClient {
public:
    // POST with JSON or form body. `contentType` is the Content-Type
    // header; pass "application/json" or "application/x-www-form-urlencoded".
    static HTTPResponse post(const std::string& url,
                             const std::string& body,
                             const std::string& contentType,
                             const std::map<std::string, std::string>& headers);

    static HTTPResponse get(const std::string& url,
                            const std::map<std::string, std::string>& headers);

    // Same timeout override as the Windows plugin uses (30s default).
    // 300s gives Ollama-style slow-first-token backends headroom even
    // though we're aimed at cloud providers.
    static void setTimeoutSeconds(double seconds);
};

}  // namespace NppAIAssistant

#endif
