/**
 * CopilotAuth.h — placeholder interface for the GitHub Copilot OAuth
 * device-code flow. Real implementation will live here in a follow-up;
 * this stub exists so the build links and the UI can show a clear
 * "not yet available" message instead of crashing.
 */
#ifndef NPPAIASSISTANT_COPILOT_AUTH_H
#define NPPAIASSISTANT_COPILOT_AUTH_H

#include <string>

namespace NppAIAssistant {

class CopilotAuth {
public:
    // Returns true iff a persisted OAuth token is present in the
    // Keychain AND has been validated against the Copilot endpoint
    // at least once this session.
    static bool isAuthenticated();

    // Placeholder. Real flow lands in a follow-up release.
    static std::string notAvailableMessage();
};

}  // namespace NppAIAssistant

#endif
