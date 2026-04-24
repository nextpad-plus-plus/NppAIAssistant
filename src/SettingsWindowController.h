/**
 * SettingsWindowController.h — modal settings window mirroring the
 * Windows IDD_AIASSISTANT_SETTINGS layout section-for-section.
 */
#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

@interface SettingsWindowController : NSWindowController

// Show the settings window as a modal sheet on the given parent window
// (or as a standalone window if parent is nil).
+ (void)presentFromWindow:(nullable NSWindow*)parent;

@end

NS_ASSUME_NONNULL_END
