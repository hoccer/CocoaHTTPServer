#import "DELETEResponse.h"
#import "HTTPLogging.h"

// HTTP methods: http://www.w3.org/Protocols/rfc2616/rfc2616-sec9.html
// HTTP headers: http://www.w3.org/Protocols/rfc2616/rfc2616-sec14.html
// HTTP status codes: http://www.w3.org/Protocols/rfc2616/rfc2616-sec10.html

static const int httpLogLevel = HTTP_LOG_LEVEL_WARN;

@implementation DELETEResponse

+ (short)getPosixPermissionsForPath:(NSString*)myFilePath {
    NSError * error = nil;
    NSDictionary * attributes = [[NSFileManager defaultManager] attributesOfItemAtPath:myFilePath error:&error];
    if (error != nil) {
        NSLog(@"Error setting posix permission for path %@, error=%@", myFilePath, error);
        return -1;
    }
    return [attributes filePosixPermissions];
}

/*
+ (BOOL)setPosixPermissionsReadOnlyForPath:(NSString*)myFilePath {
    return [self setPosixPermissions:[@(0444) shortValue] forPath:myFilePath];
}

+ (BOOL)setPosixPermissionsReadWriteForPath:(NSString*)myFilePath {
    return [self setPosixPermissions:[@(0644) shortValue] forPath:myFilePath];
}
*/

+(BOOL)isUserReadOnlyFile:(NSString*)myFilePath {
    short permissions = [self getPosixPermissionsForPath:myFilePath];
    if (permissions != -1) {
        return (permissions & 0200) == 0;
    }
    return NO;
}
/*
+(BOOL)isUserReadWriteFile:(NSString*)myFilePath {
    short permissions = [self getPosixPermissionsForPath:myFilePath];
    if (permissions != -1) {
        return (permissions & 0600) == 0600;
    }
    return NO;
}
*/

- (id) initWithFilePath:(NSString*)path {
    if ((self = [super init])) {
        BOOL exists = [[NSFileManager defaultManager] fileExistsAtPath:path];
        BOOL readOnly = [DELETEResponse isUserReadOnlyFile:path];
        if (readOnly) {
            _status = 405;
            HTTPLogError(@"Failed deleting readonly file \"%@\"", path);
        } else {
            if ([[NSFileManager defaultManager] removeItemAtPath:path error:NULL]) {
                _status = exists ? 200 : 204;
            } else {
                HTTPLogError(@"Failed deleting \"%@\"", path);
                _status = 404;
            }
        }
    }
    return self;
}

- (UInt64) contentLength {
  return 0;
}

- (UInt64) offset {
  return 0;
}

- (void)setOffset:(UInt64)offset {
  ;
}

- (NSData*) readDataOfLength:(NSUInteger)length {
  return nil;
}

- (BOOL) isDone {
  return YES;
}

- (NSInteger) status {
  return _status;
}

@end
