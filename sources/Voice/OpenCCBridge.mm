//
//  OpenCCBridge.mm
//  Squirrel
//
//  Implements OpenCCBridge against OpenCC's stable C API. The prototypes are
//  declared locally (rather than #including <opencc/opencc.h>) so this file
//  compiles without the OpenCC headers on the search path — their location
//  differs between the local librime build tree and CI. Symbols resolve at
//  link time from libopencc.a (+ libmarisa.a); see OTHER_LDFLAGS.
//

#import "OpenCCBridge.h"

extern "C" {
typedef void *opencc_t;
opencc_t opencc_open(const char *configFileName);
int opencc_close(opencc_t);
char *opencc_convert_utf8(opencc_t, const char *input, size_t length);
void opencc_convert_utf8_free(char *str);
const char *opencc_error(void);
}

// opencc_open returns (opencc_t)-1 — not NULL — on failure.
static opencc_t const kOpenCCInvalid = (opencc_t)(intptr_t)-1;

@implementation OpenCCBridge {
  opencc_t _converter;
}

+ (instancetype)s2twpConverter {
  static OpenCCBridge *shared;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    shared = [[OpenCCBridge alloc] initWithConfig:@"opencc/s2twp.json"];
  });
  return shared;
}

- (instancetype)initWithConfig:(NSString *)config {
  if (self = [super init]) {
    _converter = opencc_open(config.fileSystemRepresentation);
    if (_converter == kOpenCCInvalid) {
      NSLog(@"[SquirrelVoice] OpenCC open failed for %@: %s", config, opencc_error());
      _converter = NULL;
    }
  }
  return self;
}

- (NSString *)convert:(NSString *)input {
  if (_converter == NULL || input.length == 0) {
    return input;
  }
  char *out = opencc_convert_utf8(_converter, input.UTF8String, (size_t)-1);
  if (out == NULL) {
    return input;
  }
  NSString *result = [NSString stringWithUTF8String:out];
  opencc_convert_utf8_free(out);
  return result ?: input;
}

- (void)dealloc {
  if (_converter != NULL && _converter != kOpenCCInvalid) {
    opencc_close(_converter);
  }
}

@end
