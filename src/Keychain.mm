#import <Foundation/Foundation.h>
#import <Security/Security.h>

#include "Keychain.h"

namespace NppAIAssistant {

namespace {

constexpr const char* kService = "NppAIAssistant";

NSDictionary* baseQuery(const std::string& account) {
    NSString* svc = [NSString stringWithUTF8String:kService];
    NSString* acc = [NSString stringWithUTF8String:account.c_str()];
    return @{
        (__bridge id)kSecClass:       (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: svc,
        (__bridge id)kSecAttrAccount: acc,
    };
}

}  // namespace

std::string Keychain::load(const std::string& account) {
    NSMutableDictionary* q = [baseQuery(account) mutableCopy];
    q[(__bridge id)kSecReturnData]  = @YES;
    q[(__bridge id)kSecMatchLimit]  = (__bridge id)kSecMatchLimitOne;

    CFTypeRef out = nullptr;
    OSStatus st = SecItemCopyMatching((__bridge CFDictionaryRef)q, &out);
    if (st != errSecSuccess || !out) return "";
    NSData* data = (__bridge_transfer NSData*)out;
    if (!data) return "";
    return std::string(static_cast<const char*>([data bytes]), [data length]);
}

bool Keychain::save(const std::string& account, const std::string& value) {
    if (value.empty()) return remove(account);

    NSData* data = [NSData dataWithBytes:value.c_str() length:value.size()];
    NSMutableDictionary* q = [baseQuery(account) mutableCopy];

    // SecItemUpdate first — it's the hot path for existing keys.
    NSDictionary* attrs = @{ (__bridge id)kSecValueData: data };
    OSStatus st = SecItemUpdate((__bridge CFDictionaryRef)q,
                                (__bridge CFDictionaryRef)attrs);
    if (st == errSecSuccess) return true;
    if (st != errSecItemNotFound) return false;

    // Not found → add.
    NSMutableDictionary* addQ = [baseQuery(account) mutableCopy];
    addQ[(__bridge id)kSecValueData] = data;
    // kSecAttrAccessible default (AfterFirstUnlock) is fine — plugin
    // needs the key available after login, not before.
    addQ[(__bridge id)kSecAttrAccessible] = (__bridge id)kSecAttrAccessibleAfterFirstUnlock;
    st = SecItemAdd((__bridge CFDictionaryRef)addQ, nullptr);
    return st == errSecSuccess;
}

bool Keychain::remove(const std::string& account) {
    OSStatus st = SecItemDelete((__bridge CFDictionaryRef)baseQuery(account));
    return st == errSecSuccess || st == errSecItemNotFound;
}

bool Keychain::has(const std::string& account) {
    NSMutableDictionary* q = [baseQuery(account) mutableCopy];
    q[(__bridge id)kSecMatchLimit] = (__bridge id)kSecMatchLimitOne;
    OSStatus st = SecItemCopyMatching((__bridge CFDictionaryRef)q, nullptr);
    return st == errSecSuccess;
}

}  // namespace NppAIAssistant
