#import <Foundation/Foundation.h>

#include "CopilotAuth.h"

namespace NppAIAssistant {

bool CopilotAuth::isAuthenticated() {
    return false;
}

std::string CopilotAuth::notAvailableMessage() {
    return "GitHub Copilot device-flow sign-in will land in a follow-up release. "
           "For now, use OpenAI / Gemini / Claude with their API keys in Settings.";
}

}  // namespace NppAIAssistant
