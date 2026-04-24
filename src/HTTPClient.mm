/**
 * HTTPClient.mm — NSURLSession-backed blocking HTTP.
 *
 * Kept deliberately minimal. Callers construct a headers map and pass
 * JSON or form-encoded bodies; we add no bearer-auth / provider-aware
 * magic here. That keeps ApiClient and CopilotAuth in charge of the
 * wire format per provider.
 */
#import <Foundation/Foundation.h>

#include "HTTPClient.h"

namespace NppAIAssistant {

namespace {

double g_timeoutSeconds = 300.0;

// Build an NSMutableURLRequest common to POST and GET. Caller sets the
// HTTP method, body, and content-type after.
NSMutableURLRequest* buildRequest(const std::string& url,
                                  const std::map<std::string, std::string>& headers) {
    NSString* ns = [NSString stringWithUTF8String:url.c_str()];
    NSURL* nsurl = [NSURL URLWithString:ns];
    if (!nsurl) return nil;

    NSMutableURLRequest* req = [NSMutableURLRequest
        requestWithURL:nsurl
           cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
       timeoutInterval:g_timeoutSeconds];

    // Use initWithBytes:length:encoding: (rather than
    // stringWithUTF8String:) so embedded NULs don't truncate silently,
    // and strip trailing whitespace — HTTP headers reject CR/LF and
    // NSMutableURLRequest drops headers with trailing whitespace.
    for (const auto& kv : headers) {
        std::string cleaned = kv.second;
        while (!cleaned.empty() &&
               (cleaned.back() == '\n' || cleaned.back() == '\r' ||
                cleaned.back() == ' '  || cleaned.back() == '\t')) {
            cleaned.pop_back();
        }
        NSString* key = [[NSString alloc] initWithBytes:kv.first.data()
                                                 length:kv.first.size()
                                               encoding:NSUTF8StringEncoding];
        NSString* val = [[NSString alloc] initWithBytes:cleaned.data()
                                                 length:cleaned.size()
                                               encoding:NSUTF8StringEncoding];
        if (key && val) [req setValue:val forHTTPHeaderField:key];
    }
    return req;
}

// One-shot blocking send. Pumps the current run loop so blocking on
// the main thread still dispatches UI updates queued by the completion
// handler — same trick NppLLM uses.
HTTPResponse runBlocking(NSMutableURLRequest* req) {
    HTTPResponse out;
    if (!req) {
        out.errorText = "invalid URL";
        return out;
    }

    __block NSData* gotData = nil;
    __block NSHTTPURLResponse* gotResp = nil;
    __block NSError* gotErr = nil;
    __block BOOL done = NO;

    NSURLSessionDataTask* task = [[NSURLSession sharedSession]
        dataTaskWithRequest:req
          completionHandler:^(NSData* data, NSURLResponse* resp, NSError* err) {
            gotData = data;
            gotResp = (NSHTTPURLResponse*)resp;
            gotErr  = err;
            done = YES;
        }];
    [task resume];

    while (!done) {
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                                 beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
    }

    out.statusCode = static_cast<int>([gotResp statusCode]);
    if (gotData) {
        out.body.assign(static_cast<const char*>([gotData bytes]), [gotData length]);
    }
    if (gotErr) {
        out.ok = false;
        out.errorText = [[gotErr localizedDescription] UTF8String] ?: "";
        return out;
    }
    out.ok = (out.statusCode >= 200 && out.statusCode < 300);
    if (!out.ok && out.errorText.empty()) {
        out.errorText = std::string("HTTP ") + std::to_string(out.statusCode);
    }
    return out;
}

}  // namespace

void HTTPClient::setTimeoutSeconds(double seconds) {
    if (seconds > 0) g_timeoutSeconds = seconds;
}

HTTPResponse HTTPClient::post(const std::string& url,
                              const std::string& body,
                              const std::string& contentType,
                              const std::map<std::string, std::string>& headers) {
    NSMutableURLRequest* req = buildRequest(url, headers);
    if (!req) { HTTPResponse r; r.errorText = "invalid URL"; return r; }
    [req setHTTPMethod:@"POST"];
    if (!contentType.empty()) {
        NSString* ct = [NSString stringWithUTF8String:contentType.c_str()];
        [req setValue:ct forHTTPHeaderField:@"Content-Type"];
    }
    [req setHTTPBody:[NSData dataWithBytes:body.c_str() length:body.size()]];
    return runBlocking(req);
}

HTTPResponse HTTPClient::get(const std::string& url,
                             const std::map<std::string, std::string>& headers) {
    NSMutableURLRequest* req = buildRequest(url, headers);
    if (!req) { HTTPResponse r; r.errorText = "invalid URL"; return r; }
    [req setHTTPMethod:@"GET"];
    return runBlocking(req);
}

}  // namespace NppAIAssistant
