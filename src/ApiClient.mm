/**
 * ApiClient.mm — per-provider request/response formatting.
 *
 * Uses NSJSONSerialization for both directions so we don't need to pull
 * in nlohmann/json. Response paths per provider (consumed by the parser
 * helpers below):
 *
 *   OpenAI:  choices[0].message.content   (string)
 *   Gemini:  candidates[0].content.parts[0].text   (string)
 *   Claude:  content[0].text              (string, type="text"; may include
 *                                          multiple parts — we concatenate
 *                                          every .text of type "text")
 *
 * ModelList paths:
 *   OpenAI:  data[*].id  (filtered: gpt-/chatgpt-/o1/o3/o4)
 *   Gemini:  models[*].name (strip "models/" prefix, filter: starts with
 *                            "gemini" and supportedGenerationMethods
 *                            includes "generateContent")
 *   Claude:  data[*].id
 */
#import <Foundation/Foundation.h>

#include "ApiClient.h"

#include "HTTPClient.h"

namespace NppAIAssistant {

namespace {

// ---------- JSON helpers (NSDictionary walking) -------------------------

// Safe cast + subscript chain. Returns nil on any miss.
id valueAtPath(NSDictionary* root, NSArray<NSString*>* keys) {
    id cur = root;
    for (NSString* k in keys) {
        if (![cur isKindOfClass:[NSDictionary class]]) return nil;
        cur = ((NSDictionary*)cur)[k];
        if (!cur) return nil;
    }
    return cur;
}

NSString* firstErrorMessage(NSDictionary* root) {
    // Most providers expose an { "error": { "message": "…" } } envelope.
    id err = root[@"error"];
    if ([err isKindOfClass:[NSDictionary class]]) {
        id msg = ((NSDictionary*)err)[@"message"];
        if ([msg isKindOfClass:[NSString class]]) return (NSString*)msg;
    }
    // Many servers use a plain {"error": "text"} or top-level "message".
    if ([err isKindOfClass:[NSString class]]) return (NSString*)err;
    id msg = root[@"message"];
    if ([msg isKindOfClass:[NSString class]]) return (NSString*)msg;
    // AnythingLLM-style {"textResponse": "…"} on some errors.
    id tr = root[@"textResponse"];
    if ([tr isKindOfClass:[NSString class]]) return (NSString*)tr;
    // Last resort: {"detail": "…"} (FastAPI, AnythingLLM on some paths).
    id detail = root[@"detail"];
    if ([detail isKindOfClass:[NSString class]]) return (NSString*)detail;
    return nil;
}

// Parse a JSON body string into an NSDictionary, or nil on failure.
NSDictionary* parseJsonDict(const std::string& body) {
    if (body.empty()) return nil;
    NSData* d = [NSData dataWithBytesNoCopy:(void*)body.data()
                                     length:body.size()
                               freeWhenDone:NO];
    id parsed = [NSJSONSerialization JSONObjectWithData:d options:0 error:nil];
    if (![parsed isKindOfClass:[NSDictionary class]]) return nil;
    return (NSDictionary*)parsed;
}

// Serialize an NSDictionary/NSArray/etc. to a UTF-8 std::string.
std::string jsonToString(id obj) {
    NSError* err = nil;
    NSData* d = [NSJSONSerialization dataWithJSONObject:obj options:0 error:&err];
    if (!d || err) return "";
    return std::string(static_cast<const char*>([d bytes]), [d length]);
}

NSString* nstr(const std::string& s) {
    return [NSString stringWithUTF8String:s.c_str()] ?: @"";
}
std::string stdstr(NSString* s) {
    if (!s) return "";
    return [s UTF8String] ?: "";
}

// When an HTTP request fails and we can't pull a structured error
// out of the body, fall back to showing a short prefix of the raw
// response so the user can see what the server actually said.
std::string truncateForDisplay(const std::string& body, size_t limit = 400) {
    if (body.size() <= limit) return body;
    return body.substr(0, limit) + "…";
}

// Attach useful server-side detail to an HTTP-level error. Handles all
// three common shapes (json envelope, plain-text body, empty body).
// Templated so LLMResult and ModelListResult both flow through the
// same enrichment path.
template <typename R>
void enrichHttpError(R& r, const HTTPResponse& http) {
    r.errorText = http.errorText;
    NSDictionary* err = parseJsonDict(http.body);
    NSString* msg = err ? firstErrorMessage(err) : nil;
    if (msg) {
        r.errorText += std::string(": ") + stdstr(msg);
    } else if (!http.body.empty()) {
        r.errorText += std::string(": ") + truncateForDisplay(http.body);
    }
}

// Run `work` on a background queue and dispatch `done` on main.
void dispatchBackground(void (^work)(void)) {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), work);
}
void dispatchMain(void (^work)(void)) {
    dispatch_async(dispatch_get_main_queue(), work);
}

// ---------- OpenAI ------------------------------------------------------

// Derive the list-models URL from a chat-completions URL by swapping
// `/chat/completions` with `/models`. Heuristic — servers that host
// the chat endpoint at the same prefix as `/models` (OpenAI's own,
// LM Studio, vLLM, AnythingLLM) get accurate model lists; ones that
// don't just return an error and we keep the default.
std::string siblingModelsUrl(const std::string& chatUrl) {
    const std::string needle = "/chat/completions";
    auto pos = chatUrl.rfind(needle);
    if (pos == std::string::npos) {
        // Fall back to OpenAI's canonical location.
        return "https://api.openai.com/v1/models";
    }
    return chatUrl.substr(0, pos) + "/models";
}

LLMResult callOpenAI(const std::string& apiKey,
                     const std::string& model,
                     const std::string& prompt,
                     const std::string& endpointOverride) {
    LLMResult r;
    if (apiKey.empty()) { r.errorText = "OpenAI API key is not configured"; return r; }

    NSDictionary* body = @{
        @"model":    nstr(model),
        @"messages": @[ @{ @"role": @"user", @"content": nstr(prompt) } ],
        @"max_tokens": @2048,
    };
    std::map<std::string, std::string> headers;
    headers["Authorization"] = std::string("Bearer ") + apiKey;

    const std::string url = endpointOverride.empty()
        ? std::string("https://api.openai.com/v1/chat/completions")
        : endpointOverride;

    HTTPResponse http = HTTPClient::post(url,
                                         jsonToString(body),
                                         "application/json", headers);
    r.statusCode = http.statusCode;
    if (!http.ok) { enrichHttpError(r, http); return r; }

    NSDictionary* root = parseJsonDict(http.body);
    if (!root) { r.errorText = "Failed to parse OpenAI response"; return r; }

    id choices = root[@"choices"];
    if ([choices isKindOfClass:[NSArray class]] && [(NSArray*)choices count] > 0) {
        id first = [(NSArray*)choices firstObject];
        id content = valueAtPath(first, @[@"message", @"content"]);
        if ([content isKindOfClass:[NSString class]]) {
            r.ok = true;
            r.content = stdstr((NSString*)content);
            return r;
        }
    }
    r.errorText = "OpenAI returned no content";
    return r;
}

ModelListResult listOpenAIModels(const std::string& apiKey,
                                 const std::string& endpointOverride) {
    ModelListResult r;
    if (apiKey.empty()) { r.errorText = "OpenAI API key is not configured"; return r; }

    std::map<std::string, std::string> headers;
    headers["Authorization"] = std::string("Bearer ") + apiKey;
    const std::string url = endpointOverride.empty()
        ? std::string("https://api.openai.com/v1/models")
        : siblingModelsUrl(endpointOverride);
    HTTPResponse http = HTTPClient::get(url, headers);
    r.statusCode = http.statusCode;
    if (!http.ok) { enrichHttpError(r, http); return r; }

    // Custom endpoints (LM Studio, Ollama-via-openai-shim, LiteLLM, …)
    // serve arbitrary model names that don't match OpenAI's gpt-/o-
    // prefix conventions, so skip the filter when an override is set.
    const bool filterPrefixes = endpointOverride.empty();

    NSDictionary* root = parseJsonDict(http.body);
    id data = root ? root[@"data"] : nil;
    if ([data isKindOfClass:[NSArray class]]) {
        for (id item in (NSArray*)data) {
            if (![item isKindOfClass:[NSDictionary class]]) continue;
            id idv = ((NSDictionary*)item)[@"id"];
            if (![idv isKindOfClass:[NSString class]]) continue;
            NSString* m = (NSString*)idv;
            if (filterPrefixes &&
                ![m hasPrefix:@"gpt-"]    &&
                ![m hasPrefix:@"chatgpt-"] &&
                ![m hasPrefix:@"o1"]       &&
                ![m hasPrefix:@"o3"]       &&
                ![m hasPrefix:@"o4"]) {
                continue;
            }
            r.models.push_back(stdstr(m));
        }
    }
    if (r.models.empty()) { r.errorText = "No chat models returned"; return r; }
    r.ok = true;
    return r;
}

// ---------- Gemini ------------------------------------------------------

std::string substituteModel(const std::string& tmpl, const std::string& model) {
    std::string out = tmpl;
    const std::string needle = "{model}";
    size_t pos = 0;
    while ((pos = out.find(needle, pos)) != std::string::npos) {
        out.replace(pos, needle.size(), model);
        pos += model.size();
    }
    return out;
}

LLMResult callGemini(const std::string& apiKey,
                     const std::string& model,
                     const std::string& prompt,
                     const std::string& endpointOverride) {
    LLMResult r;
    if (apiKey.empty()) { r.errorText = "Gemini API key is not configured"; return r; }

    const std::string tmpl = endpointOverride.empty()
        ? std::string("https://generativelanguage.googleapis.com/v1beta/models/{model}:generateContent")
        : endpointOverride;
    const std::string url = substituteModel(tmpl, model);
    NSDictionary* body = @{
        @"contents": @[ @{ @"parts": @[ @{ @"text": nstr(prompt) } ] } ],
    };
    std::map<std::string, std::string> headers;
    headers["x-goog-api-key"] = apiKey;

    HTTPResponse http = HTTPClient::post(url, jsonToString(body),
                                         "application/json", headers);
    r.statusCode = http.statusCode;
    if (!http.ok) { enrichHttpError(r, http); return r; }

    NSDictionary* root = parseJsonDict(http.body);
    if (!root) { r.errorText = "Failed to parse Gemini response"; return r; }

    id cand = root[@"candidates"];
    if ([cand isKindOfClass:[NSArray class]] && [(NSArray*)cand count] > 0) {
        id parts = valueAtPath([(NSArray*)cand firstObject], @[@"content", @"parts"]);
        if ([parts isKindOfClass:[NSArray class]]) {
            NSMutableString* acc = [NSMutableString string];
            for (id p in (NSArray*)parts) {
                id t = [p isKindOfClass:[NSDictionary class]] ? ((NSDictionary*)p)[@"text"] : nil;
                if ([t isKindOfClass:[NSString class]]) [acc appendString:(NSString*)t];
            }
            if (acc.length > 0) {
                r.ok = true;
                r.content = stdstr(acc);
                return r;
            }
        }
    }
    r.errorText = "Gemini returned no content";
    return r;
}

ModelListResult listGeminiModels(const std::string& apiKey,
                                 const std::string& endpointOverride) {
    ModelListResult r;
    if (apiKey.empty()) { r.errorText = "Gemini API key is not configured"; return r; }

    std::map<std::string, std::string> headers;
    headers["x-goog-api-key"] = apiKey;

    // Derive the /models URL from the chat URL override by stripping
    // everything after the last "/models". If the user left the
    // override blank, use Google's canonical path.
    std::string url = "https://generativelanguage.googleapis.com/v1beta/models";
    if (!endpointOverride.empty()) {
        auto pos = endpointOverride.rfind("/models");
        if (pos != std::string::npos) {
            url = endpointOverride.substr(0, pos + 7 /* len("/models") */);
        }
    }
    HTTPResponse http = HTTPClient::get(url, headers);
    r.statusCode = http.statusCode;
    if (!http.ok) { enrichHttpError(r, http); return r; }

    NSDictionary* root = parseJsonDict(http.body);
    id models = root ? root[@"models"] : nil;
    if ([models isKindOfClass:[NSArray class]]) {
        for (id m in (NSArray*)models) {
            if (![m isKindOfClass:[NSDictionary class]]) continue;
            id name    = ((NSDictionary*)m)[@"name"];
            id methods = ((NSDictionary*)m)[@"supportedGenerationMethods"];
            if (![name isKindOfClass:[NSString class]]) continue;

            NSString* ns = (NSString*)name;
            if ([ns hasPrefix:@"models/"]) ns = [ns substringFromIndex:7];
            if (![ns hasPrefix:@"gemini"]) continue;

            bool supportsGenerate = true;
            if ([methods isKindOfClass:[NSArray class]]) {
                supportsGenerate = [(NSArray*)methods containsObject:@"generateContent"];
            }
            if (!supportsGenerate) continue;

            r.models.push_back(stdstr(ns));
        }
    }
    if (r.models.empty()) { r.errorText = "Gemini returned no compatible models"; return r; }
    r.ok = true;
    return r;
}

// ---------- Claude ------------------------------------------------------

LLMResult callClaude(const std::string& apiKey,
                     const std::string& model,
                     const std::string& prompt,
                     const std::string& endpointOverride) {
    LLMResult r;
    if (apiKey.empty()) { r.errorText = "Claude API key is not configured"; return r; }

    NSDictionary* body = @{
        @"model":      nstr(model),
        @"max_tokens": @2048,
        @"messages":   @[ @{ @"role": @"user", @"content": nstr(prompt) } ],
    };
    std::map<std::string, std::string> headers;
    headers["x-api-key"]          = apiKey;
    headers["anthropic-version"]  = "2023-06-01";

    const std::string url = endpointOverride.empty()
        ? std::string("https://api.anthropic.com/v1/messages")
        : endpointOverride;

    HTTPResponse http = HTTPClient::post(url,
                                         jsonToString(body),
                                         "application/json", headers);
    r.statusCode = http.statusCode;
    if (!http.ok) { enrichHttpError(r, http); return r; }

    NSDictionary* root = parseJsonDict(http.body);
    id content = root ? root[@"content"] : nil;
    if ([content isKindOfClass:[NSArray class]]) {
        NSMutableString* acc = [NSMutableString string];
        for (id block in (NSArray*)content) {
            if (![block isKindOfClass:[NSDictionary class]]) continue;
            id type = ((NSDictionary*)block)[@"type"];
            id text = ((NSDictionary*)block)[@"text"];
            if ([type isKindOfClass:[NSString class]] &&
                [(NSString*)type isEqualToString:@"text"] &&
                [text isKindOfClass:[NSString class]]) {
                [acc appendString:(NSString*)text];
            }
        }
        if (acc.length > 0) {
            r.ok = true;
            r.content = stdstr(acc);
            return r;
        }
    }
    r.errorText = "Claude returned no content";
    return r;
}

ModelListResult listClaudeModels(const std::string& apiKey,
                                 const std::string& endpointOverride) {
    ModelListResult r;
    if (apiKey.empty()) { r.errorText = "Claude API key is not configured"; return r; }

    std::map<std::string, std::string> headers;
    headers["x-api-key"]         = apiKey;
    headers["anthropic-version"] = "2023-06-01";

    // Swap /messages → /models on the override if present.
    std::string url = "https://api.anthropic.com/v1/models";
    if (!endpointOverride.empty()) {
        auto pos = endpointOverride.rfind("/messages");
        if (pos != std::string::npos) {
            url = endpointOverride.substr(0, pos) + "/models";
        } else {
            url = endpointOverride;   // user pointed somewhere bespoke
        }
    }
    HTTPResponse http = HTTPClient::get(url, headers);
    r.statusCode = http.statusCode;
    if (!http.ok) { enrichHttpError(r, http); return r; }

    NSDictionary* root = parseJsonDict(http.body);
    id data = root ? root[@"data"] : nil;
    if ([data isKindOfClass:[NSArray class]]) {
        for (id item in (NSArray*)data) {
            if (![item isKindOfClass:[NSDictionary class]]) continue;
            id idv = ((NSDictionary*)item)[@"id"];
            if ([idv isKindOfClass:[NSString class]]) {
                r.models.push_back(stdstr((NSString*)idv));
            }
        }
    }
    if (r.models.empty()) { r.errorText = "Claude returned no models"; return r; }
    r.ok = true;
    return r;
}

}  // namespace

// ----------------------------------------------------------------------
// Public interface — wrap provider-specific helpers in a single async
// entry point.
// ----------------------------------------------------------------------

void ApiClient::send(Provider provider,
                     const std::string& apiKey,
                     const std::string& model,
                     const std::string& fullPrompt,
                     const EndpointOverrides& endpoints,
                     LLMCompletion completion) {
    // VALUE-capture every C++ string into locals before dispatching to
    // the background queue. Blocks capture references as-is, and our
    // caller's `std::string` args live on their stack frame — they're
    // long gone by the time the block runs on the worker thread. Prior
    // bug produced a Bearer header with stack garbage instead of the
    // real key. Do not revert.
    LLMCompletion cb       = [completion copy];
    std::string keyCopy    = apiKey;
    std::string modelCopy  = model;
    std::string promptCopy = fullPrompt;
    EndpointOverrides eo   = endpoints;
    dispatchBackground(^{
        LLMResult result;
        switch (provider) {
            case Provider::OpenAI:
                result = callOpenAI(keyCopy, modelCopy, promptCopy, eo.openaiUrl);
                break;
            case Provider::Gemini:
                result = callGemini(keyCopy, modelCopy, promptCopy, eo.geminiUrl);
                break;
            case Provider::Claude:
                result = callClaude(keyCopy, modelCopy, promptCopy, eo.claudeUrl);
                break;
            case Provider::Copilot:
                result.errorText = "GitHub Copilot support is not wired yet — see CopilotAuth.";
                break;
        }
        if (cb) dispatchMain(^{ cb(result); });
    });
}

void ApiClient::listModels(Provider provider,
                           const std::string& apiKey,
                           const EndpointOverrides& endpoints,
                           ModelListCompletion completion) {
    // Same value-capture rule as send() — the by-value copies are
    // what the block safely owns. See comment in send().
    ModelListCompletion cb = [completion copy];
    std::string keyCopy    = apiKey;
    EndpointOverrides eo   = endpoints;
    dispatchBackground(^{
        ModelListResult result;
        switch (provider) {
            case Provider::OpenAI: result = listOpenAIModels(keyCopy, eo.openaiUrl); break;
            case Provider::Gemini: result = listGeminiModels(keyCopy, eo.geminiUrl); break;
            case Provider::Claude: result = listClaudeModels(keyCopy, eo.claudeUrl); break;
            case Provider::Copilot:
                result.errorText = "Copilot model list is not available via public API";
                break;
        }
        if (cb) dispatchMain(^{ cb(result); });
    });
}

std::string ApiClient::defaultModel(Provider p) {
    switch (p) {
        case Provider::OpenAI:  return "gpt-4o-mini";
        case Provider::Gemini:  return "gemini-2.0-flash";
        case Provider::Claude:  return "claude-sonnet-4-20250514";
        case Provider::Copilot: return "gpt-4o";
    }
    return "";
}

std::string ApiClient::providerName(Provider p) {
    switch (p) {
        case Provider::OpenAI:  return "OpenAI";
        case Provider::Gemini:  return "Gemini";
        case Provider::Claude:  return "Claude";
        case Provider::Copilot: return "Copilot";
    }
    return "";
}

}  // namespace NppAIAssistant
