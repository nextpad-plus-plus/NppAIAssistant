/**
 * Keychain.h — API key storage in the macOS login Keychain.
 *
 * Replaces the Windows DPAPI-encrypted `.key` files. Each entry is a
 * generic password with:
 *   kSecAttrService = "NppAIAssistant"
 *   kSecAttrAccount = account name (same as the Windows filename stem:
 *                     openai_apikey, gemini_apikey, claude_apikey,
 *                     copilot_oauth_token)
 *   kSecValueData   = UTF-8 bytes of the key
 *
 * All methods are main-thread safe; SecItem* calls may briefly block
 * during a keychain unlock prompt on first access.
 */
#ifndef NPPAIASSISTANT_KEYCHAIN_H
#define NPPAIASSISTANT_KEYCHAIN_H

#include <string>

namespace NppAIAssistant {

class Keychain {
public:
    // Account names. Shared strings so callers never typo them.
    static constexpr const char* kOpenAIKey        = "openai_apikey";
    static constexpr const char* kGeminiKey        = "gemini_apikey";
    static constexpr const char* kClaudeKey        = "claude_apikey";
    static constexpr const char* kCopilotOauth     = "copilot_oauth_token";

    // Return the stored value or an empty string if missing.
    static std::string load(const std::string& account);

    // Create or update the entry. Pass an empty value to delete.
    static bool save(const std::string& account, const std::string& value);

    static bool remove(const std::string& account);
    static bool has(const std::string& account);
};

}  // namespace NppAIAssistant

#endif
