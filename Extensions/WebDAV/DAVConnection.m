#import "DAVConnection.h"
#import "HTTPMessage.h"
#import "HTTPFileResponse.h"
#import "HTTPAsyncFileResponse.h"
#import "PUTResponse.h"
#import "DELETEResponse.h"
#import "DAVResponse.h"
#import "HTTPLogging.h"

#define HTTP_BODY_MAX_MEMORY_SIZE (1024 * 1024)
#define HTTP_ASYNC_FILE_RESPONSE_THRESHOLD (16 * 1024 * 1024)

static const int httpLogLevel = HTTP_LOG_LEVEL_WARN;
//static const int httpLogLevel = HTTP_LOG_LEVEL_WARN | HTTP_LOG_FLAG_TRACE;

@implementation DAVConnection

- (void) dealloc {
  [requestContentStream close];
}

- (BOOL) supportsMethod:(NSString*)method atPath:(NSString*)path {
  // HTTPFileResponse & HTTPAsyncFileResponse
  if ([method isEqualToString:@"GET"]) return YES;
	if ([method isEqualToString:@"HEAD"]) return YES;
  
  // PUTResponse
  if ([method isEqualToString:@"PUT"]) return YES;
  
  // DELETEResponse
  if ([method isEqualToString:@"DELETE"]) return YES;
	
  // DAVResponse
  if ([method isEqualToString:@"OPTIONS"]) return YES;
  if ([method isEqualToString:@"PROPFIND"]) return YES;
  if ([method isEqualToString:@"PROPPATCH"]) return YES;
  if ([method isEqualToString:@"MKCOL"]) return YES;
  if ([method isEqualToString:@"MOVE"]) return YES;
  if ([method isEqualToString:@"COPY"]) return YES;
  if ([method isEqualToString:@"LOCK"]) return YES;
  if ([method isEqualToString:@"UNLOCK"]) return YES;

  // POSTResponse
  //if ([method isEqualToString:@"POST"]) return YES;

  return NO;
}

- (BOOL) expectsRequestBodyFromMethod:(NSString*)method atPath:(NSString*)path {
    
    HTTPLogTrace2(@"expectsRequestBodyFromMethod:%@ atPath:%@", method, path);
    
    // PUTResponse
    if ([method isEqualToString:@"PUT"]) {
        return YES;
    }
    if ([method isEqual:@"POST"]) {
        return YES;
    }
    
    // DAVResponse
    if ([method isEqual:@"PROPFIND"] || [method isEqual:@"PROPPATCH"] || [method isEqual:@"MKCOL"]) {
        return [request headerField:@"Content-Length"] ? YES : NO;
    }
    if ([method isEqual:@"LOCK"]) {
        return YES;
    }
    
    return NO;
}

- (void) prepareForBodyWithSize:(UInt64)contentLength {
  NSAssert(requestContentStream == nil, @"requestContentStream should be nil");
  NSAssert(requestContentBody == nil, @"requestContentBody should be nil");
  
  if (contentLength > HTTP_BODY_MAX_MEMORY_SIZE) {
    requestContentBody = [[NSTemporaryDirectory() stringByAppendingString:[[NSProcessInfo processInfo] globallyUniqueString]] copy];
      //NSLog(@"Initialized output stream to file %@, expecting size %llu", requestContentBody, contentLength);
    requestContentStream = [[NSOutputStream alloc] initToFileAtPath:requestContentBody append:NO];
      [requestContentStream scheduleInRunLoop:[NSRunLoop currentRunLoop] forMode:NSRunLoopCommonModes];
      [requestContentStream open];
  } else {
      //NSLog(@"Initialized body memory for expected size %llu", contentLength);
    requestContentBody = [[NSMutableData alloc] initWithCapacity:(NSUInteger)contentLength];
    requestContentStream = nil;
  }
}

- (void) processBodyData:(NSData*)postDataChunk {
	NSAssert(requestContentBody != nil, @"requestContentBody should not be nil");
  if (requestContentStream) {
      //NSLog(@"processBodyData: postdatachunk size = %lu",(unsigned long) [postDataChunk length]);
    [requestContentStream write:[postDataChunk bytes] maxLength:[postDataChunk length]];
  } else {
    [(NSMutableData*)requestContentBody appendData:postDataChunk];
  }
}

- (void) finishBody {
  NSAssert(requestContentBody != nil, @"requestContentBody should not be nil");
  if (requestContentStream) {
    [requestContentStream close];
    [requestContentStream removeFromRunLoop:[NSRunLoop currentRunLoop] forMode:NSRunLoopCommonModes];
    requestContentStream = nil;
  }
}

- (void)finishResponse {
  NSAssert(requestContentStream == nil, @"requestContentStream should be nil");
  requestContentBody = nil;
  
  [super finishResponse];
}

- (NSObject<HTTPResponse>*) httpResponseForMethod:(NSString*)method URI:(NSString*)path {
    
    HTTPLogTrace2(@"httpResponseForMethod:%@ atPath:%@", method, path);
    
  if ([method isEqualToString:@"HEAD"] || [method isEqualToString:@"GET"]) {
    NSString* filePath = [self filePathForURI:path allowDirectory:NO];
    if (filePath) {
      NSDictionary* fileAttributes = [[NSFileManager defaultManager] attributesOfItemAtPath:filePath error:NULL];
      if (fileAttributes) {
        if ([[fileAttributes objectForKey:NSFileSize] unsignedLongLongValue] > HTTP_ASYNC_FILE_RESPONSE_THRESHOLD) {
            HTTPLogTrace2(@"httpResponseForMethod:%@ returning HTTPAsyncFileResponse path:%@",method, filePath);
          return [[HTTPAsyncFileResponse alloc] initWithFilePath:filePath forConnection:self];
        } else {
            HTTPLogTrace2(@"httpResponseForMethod:%@ returning HTTPFileResponse path:%@",method, filePath);
          return [[HTTPFileResponse alloc] initWithFilePath:filePath forConnection:self];
        }
      }
    }
  }
	
	if ([method isEqualToString:@"PUT"]) {
    NSString* filePath = [self filePathForURI:path allowDirectory:YES];
    if (filePath) {
      if ([requestContentBody isKindOfClass:[NSString class]]) {
          HTTPLogTrace2(@"httpResponseForMethod:%@ returning PUTResponse for bodyFile",method);
       return [[PUTResponse alloc] initWithFilePath:filePath headers:[request allHeaderFields] bodyFile:requestContentBody];
      } else if ([requestContentBody isKindOfClass:[NSData class]]) {
          HTTPLogTrace2(@"httpResponseForMethod:%@ returning PUTResponse for bodyData",method);
        return [[PUTResponse alloc] initWithFilePath:filePath headers:[request allHeaderFields] bodyData:requestContentBody];
      } else {
        HTTPLogError(@"Internal error");
      }
    }
  }
	
	if ([method isEqualToString:@"DELETE"]) {
    NSString* filePath = [self filePathForURI:path allowDirectory:YES];
    if (filePath) {
        HTTPLogTrace2(@"httpResponseForMethod:%@ returning DELETEResponse path:%@",method, filePath);
      return [[DELETEResponse alloc] initWithFilePath:filePath];
    }
  }
  
  if ([method isEqualToString:@"OPTIONS"] ||
      [method isEqualToString:@"PROPFIND"] ||
      [method isEqualToString:@"PROPPATCH"] ||
      [method isEqualToString:@"MKCOL"] ||
      [method isEqualToString:@"MOVE"] ||
      [method isEqualToString:@"COPY"] ||
      [method isEqualToString:@"LOCK"] ||
      [method isEqualToString:@"UNLOCK"])
  {
    NSString* filePath = [self filePathForURI:path allowDirectory:YES];
    if (filePath) {
      NSString* rootPath = [config documentRoot];
      NSString* resourcePath = [filePath substringFromIndex:([rootPath length] + 1)];
      if (requestContentBody) {
        if ([requestContentBody isKindOfClass:[NSString class]]) {
          requestContentBody = [NSData dataWithContentsOfFile:requestContentBody];
        } else if (![requestContentBody isKindOfClass:[NSData class]]) {
          HTTPLogError(@"Internal error");
          return nil;
        }
      }
        HTTPLogTrace2(@"httpResponseForMethod:%@ returning DAVResponse resourcePath:%@",method, resourcePath);
      return [[DAVResponse alloc] initWithMethod:method
                                          headers:[request allHeaderFields]
                                         bodyData:requestContentBody
                                     resourcePath:resourcePath
                                         rootPath:rootPath];
    }
  }
  
  return nil;
}

@end
