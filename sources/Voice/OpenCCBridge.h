//
//  OpenCCBridge.h
//  Squirrel
//
//  Thin Objective-C wrapper over OpenCC's C API, used to force voice-input
//  transcripts to Taiwan Traditional Chinese deterministically — independent of
//  whether the LLM cleanup pass ran or honoured its "output Traditional" rule
//  (SPEC §4.9). The s2twp config + dictionaries already ship in
//  Contents/SharedSupport/opencc (bundled with librime's OpenCC data).
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface OpenCCBridge : NSObject

/// Shared Simplified→Traditional (Taiwan standard, with phrases) converter,
/// opened lazily from `opencc/s2twp.json` relative to SharedSupport (the
/// process cwd set at launch). Reused across calls; the dictionaries load once.
+ (instancetype)s2twpConverter;

/// Convert `input`. Returns `input` unchanged if the converter failed to open
/// or the conversion errors — so text is never lost.
- (NSString *)convert:(NSString *)input;

@end

NS_ASSUME_NONNULL_END
