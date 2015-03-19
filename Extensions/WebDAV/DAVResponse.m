#import <libxml/parser.h>

#import "DAVResponse.h"
#import "HTTPLogging.h"
#import "AppDelegate.h"

#define DUMP_DAV_BODY NO
#define DUMP_DAV_RESPONSE NO
#define DUMP_DAV_RESPONSE_SHORT NO

// WebDAV specifications: http://webdav.org/specs/rfc4918.html

typedef enum {
    kDAVProperty_ResourceType = (1 << 0),
    kDAVProperty_CreationDate = (1 << 1),
    kDAVProperty_LastModified = (1 << 2),
    kDAVProperty_ContentLength = (1 << 3),
    kDAVProperty_QuotaAvailableBytes = (1 << 4),
    kDAVProperty_QuotaUsedBytes = (1 << 5),
    kDAVProperty_Quota = (1 << 6), // non-standard, but frequently used, treating them as kDAVProperty_QuotaAvailableBytes
    kDAVProperty_QuotaUsed = (1 << 7), // non-standard, but frequently used, treating them as kDAVProperty_QuotaUsedBytes
    kDAVProperty_ETag = (1 << 8),
    kDAVAllProperties = kDAVProperty_ResourceType | kDAVProperty_CreationDate | kDAVProperty_LastModified | kDAVProperty_ContentLength | kDAVProperty_QuotaAvailableBytes | kDAVProperty_QuotaUsedBytes | kDAVProperty_Quota | kDAVProperty_QuotaUsed | kDAVProperty_ETag
} DAVProperties;

#define kXMLParseOptions (XML_PARSE_NONET | XML_PARSE_RECOVER | XML_PARSE_NOBLANKS | XML_PARSE_COMPACT | XML_PARSE_NOWARNING | XML_PARSE_NOERROR)

static const int httpLogLevel = HTTP_LOG_LEVEL_WARN;

@implementation DAVResponse

+ (NSString *)etagFromAttributes:(NSDictionary*) attributes {
    
    if ([attributes objectForKey:NSFileModificationDate] &&
        [attributes objectForKey:NSFileCreationDate] &&
        [attributes objectForKey:NSFileSystemFileNumber]
        )
    {
        unsigned long fileSystemNumber = [attributes fileSystemFileNumber];
        unsigned long long created = [[attributes fileCreationDate] timeIntervalSince1970];
        unsigned long long lastMod = [[attributes fileModificationDate] timeIntervalSince1970];
        unsigned long long fileSize;
        NSString * etag;
        if ([attributes objectForKey:NSFileSize]) {
            fileSize= [attributes fileSize];
            etag = [NSString stringWithFormat:@"ev1-%lu-%qu-%qu-%qu",fileSystemNumber, lastMod, created, fileSize];
        } else {
            etag = [NSString stringWithFormat:@"ev1-%lu-%qu-%qu-d",fileSystemNumber, lastMod, created];
        }
        // NSLog(@"return etag %@", etag);
        return etag;
    }
    return nil;
}

static NSDateFormatter * _davCreationDateFormatter = nil;

static NSDateFormatter * getCreationDateFormatter() {
    if (_davCreationDateFormatter == nil) {
        NSDateFormatter* formatter = [[NSDateFormatter alloc] init];
        formatter.locale = [[NSLocale alloc] initWithLocaleIdentifier:@"en_US"];
        formatter.timeZone = [NSTimeZone timeZoneWithName:@"GMT"];
        formatter.dateFormat = @"yyyy-MM-dd'T'HH:mm:ss'+00:00'";
        _davCreationDateFormatter = formatter;
    }
    return _davCreationDateFormatter;
}

static NSDateFormatter * _davModificationDateFormatter = nil;

static NSDateFormatter * getModificationDateFormatter() {
    if (_davModificationDateFormatter == nil) {
        NSDateFormatter* formatter = [[NSDateFormatter alloc] init];
        formatter.locale = [[NSLocale alloc] initWithLocaleIdentifier:@"en_US"];
        formatter.timeZone = [NSTimeZone timeZoneWithName:@"GMT"];
        formatter.dateFormat = @"EEE', 'd' 'MMM' 'yyyy' 'HH:mm:ss' GMT'";
        _davModificationDateFormatter = formatter;
    }
    return _davModificationDateFormatter;
}


static void _AddPropertyResponse(NSString* itemPath, NSString* resourcePath, DAVProperties properties, NSMutableString* xmlString) {
    @autoreleasepool {
        static CFStringRef eChars = CFSTR("<&>?+");
        CFStringRef escapedPath = CFURLCreateStringByAddingPercentEscapes(kCFAllocatorDefault, (__bridge CFStringRef)resourcePath, NULL,
                                                                          eChars, kCFStringEncodingUTF8);
        if (escapedPath) {
            NSDictionary* attributes = [[NSFileManager defaultManager] attributesOfItemAtPath:itemPath error:NULL];
            BOOL isDirectory = [[attributes fileType] isEqualToString:NSFileTypeDirectory];
            [xmlString appendString:@"<D:response>"];
            [xmlString appendFormat:@"<D:href>%@</D:href>", escapedPath];
            [xmlString appendString:@"<D:propstat>"];
            [xmlString appendString:@"<D:prop>"];
            
            if (properties & kDAVProperty_ResourceType) {
                if (isDirectory) {
                    [xmlString appendString:@"<D:resourcetype><D:collection/></D:resourcetype>"];
                } else {
                    [xmlString appendString:@"<D:resourcetype/>"];
                }
            }
            
            if ((properties & kDAVProperty_CreationDate) && [attributes objectForKey:NSFileCreationDate]) {
#ifdef INLINE_FORMATTER
                NSDateFormatter* formatter = [[NSDateFormatter alloc] init];
                formatter.locale = [[NSLocale alloc] initWithLocaleIdentifier:@"en_US"];
                formatter.timeZone = [NSTimeZone timeZoneWithName:@"GMT"];
                formatter.dateFormat = @"yyyy-MM-dd'T'HH:mm:ss'+00:00'";
#else
                NSDateFormatter* formatter = getCreationDateFormatter();
#endif
                [xmlString appendFormat:@"<D:creationdate>%@</D:creationdate>", [formatter stringFromDate:[attributes fileCreationDate]]];
            }
            
            if ((properties & kDAVProperty_LastModified) && [attributes objectForKey:NSFileModificationDate]) {
#ifdef INLINE_FORMATTER
                NSDateFormatter* formatter = [[NSDateFormatter alloc] init];
                formatter.locale = [[NSLocale alloc] initWithLocaleIdentifier:@"en_US"];
                formatter.timeZone = [NSTimeZone timeZoneWithName:@"GMT"];
                formatter.dateFormat = @"EEE', 'd' 'MMM' 'yyyy' 'HH:mm:ss' GMT'";
#else
                NSDateFormatter* formatter = getModificationDateFormatter();

#endif
                [xmlString appendFormat:@"<D:getlastmodified>%@</D:getlastmodified>", [formatter stringFromDate:[attributes fileModificationDate]]];
            }
            
            if ((properties & kDAVProperty_ContentLength) && !isDirectory && [attributes objectForKey:NSFileSize]) {
                [xmlString appendFormat:@"<D:getcontentlength>%qu</D:getcontentlength>", [attributes fileSize]];
            }
            
            if ((properties & kDAVProperty_ETag)) {
                NSString * etag = [DAVResponse etagFromAttributes:attributes];
                if (etag != nil) {
                    [xmlString appendFormat:@"<D:getetag>%@</D:getetag>", etag];
                }
            }
            
            if ((properties & kDAVProperty_QuotaAvailableBytes)) {
                [xmlString appendFormat:@"<D:quota-available-bytes>%qu</D:quota-available-bytes>", [AppDelegate freeDiskSpace]];
            }
            
            if ((properties & kDAVProperty_QuotaUsedBytes)) {
                [xmlString appendFormat:@"<D:quota-used-bytes>%qu</D:quota-used-bytes>", [AppDelegate usedDiskSpace]];
            }
            if ((properties & kDAVProperty_Quota)) {
                [xmlString appendFormat:@"<D:quota>%qu</D:quota>", [AppDelegate freeDiskSpace]];
            }
            
            if ((properties & kDAVProperty_QuotaUsed)) {
                [xmlString appendFormat:@"<D:quotaused>%qu</D:quotaused>", [AppDelegate usedDiskSpace]];
            }
            
            [xmlString appendString:@"</D:prop>"];
            [xmlString appendString:@"<D:status>HTTP/1.1 200 OK</D:status>"];
            [xmlString appendString:@"</D:propstat>"];
            [xmlString appendString:@"</D:response>\n"];
            
            CFRelease(escapedPath);
            //NSLog(@"_AddPropertyResponse: set response:\n %@", xmlString);
        }
    }
}

static void _AddPropPatchResponse(NSString* itemPath, NSString* resourcePath, NSArray* propertyNames, NSString* statusString, NSMutableString* xmlString) {
    
    CFStringRef escapedPath = CFURLCreateStringByAddingPercentEscapes(kCFAllocatorDefault, (__bridge CFStringRef)resourcePath, NULL,
                                                                      CFSTR("<&>?+"), kCFStringEncodingUTF8);
    if (escapedPath) {
        [xmlString appendString:@"<D:response>"];
        [xmlString appendFormat:@"<D:href>%@</D:href>", escapedPath];
        [xmlString appendString:@"<D:propstat>"];
        [xmlString appendString:@"<D:prop>"];
        
        for (NSString * propertyName in propertyNames) {
            [xmlString appendFormat:@"<%@/>",propertyName];
        }

        [xmlString appendString:@"</D:prop>"];
        [xmlString appendFormat:@"<D:status>HTTP/1.1 %@</D:status>", statusString];
        [xmlString appendString:@"</D:propstat>"];
        [xmlString appendString:@"</D:response>\n"];
        CFRelease(escapedPath);
        // NSLog(@"_AddPropertyResponseError: set response:\n %@", xmlString);
    }
}

static xmlNodePtr _XMLChildWithName(xmlNodePtr child, const xmlChar* name) {
    while (child) {
        if ((child->type == XML_ELEMENT_NODE) && !xmlStrcmp(child->name, name)) {
            return child;
        }
        child = child->next;
    }
    return NULL;
}

- (id) initWithMethod:(NSString*)method headers:(NSDictionary*)headers bodyData:(NSData*)body resourcePath:(NSString*)resourcePath rootPath:(NSString*)rootPath {
    NSDate * start = [NSDate new];

    if ((self = [super init])) {
        _status = 200;
        _headers = [[NSMutableDictionary alloc] init];
        
        // 10.1 DAV Header
        if ([method isEqualToString:@"OPTIONS"]) {
            if ([[headers objectForKey:@"User-Agent"] hasPrefix:@"WebDAVFS/"]) {  // Mac OS X WebDAV support
                [_headers setObject:@"1, 2" forKey:@"DAV"];
            } else {
                [_headers setObject:@"1" forKey:@"DAV"];
            }
        }

        // 8.2 PROPPATCH Method
        
        if ([method isEqualToString:@"PROPPATCH"]) {
            // Fake PROPPATCH, do not actually store dead properties in order to avoid Windows 7 error dialog
            
            NSString* basePath = [rootPath stringByAppendingPathComponent:resourcePath];
            if (![basePath hasPrefix:rootPath] || ![[NSFileManager defaultManager] fileExistsAtPath:basePath]) {
                return nil;
            }
            
            NSMutableString* xmlString = [NSMutableString stringWithString:@"<?xml version=\"1.0\" encoding=\"utf-8\" ?>"];
            [xmlString appendString:@"<D:multistatus xmlns:D=\"DAV:\">\n"];
            if (![resourcePath hasPrefix:@"/"]) {
                resourcePath = [@"/" stringByAppendingString:resourcePath];
            }
            
            NSMutableArray * propertyNames = [NSMutableArray new];
            
            if (DUMP_DAV_BODY)  {
                NSString * testBody = [[NSString alloc] initWithData:body encoding:NSUTF8StringEncoding];
                NSLog(@"PROPPATCH body=%@", testBody);
            }
            
            xmlDocPtr document = xmlReadMemory(body.bytes, (int)body.length, NULL, NULL, kXMLParseOptions);
            if (document) {
                xmlNodePtr updateNode = _XMLChildWithName(document->children, (const xmlChar*)"propertyupdate");
                if (updateNode) {
                    xmlNodePtr command = updateNode->children;
                    while (command) {
                        xmlNodePtr property = command->children;
                        if (command) {
                            property = _XMLChildWithName(command->children, (const xmlChar*)"prop");
                        }
                        property = property->children;
                        while (property) {
                            if (property->type == XML_ELEMENT_NODE) {
                                // NSLog(@"propertyupdate: cmd = %s, property = %s", command->name, property->name);
                                [propertyNames addObject:[NSString stringWithCString:(char*)property->name encoding:NSUTF8StringEncoding]];
                            }
                            property = property->next;
                        }
                        command = command->next;

                    }

                }
                xmlFreeDoc(document);
            }
            if (propertyNames.count > 0) {
                _AddPropPatchResponse(basePath, resourcePath, propertyNames, @"200 OK", xmlString);
                [xmlString appendString:@"</D:multistatus>"];
                
                [_headers setObject:@"application/xml; charset=\"utf-8\"" forKey:@"Content-Type"];
                _data = [xmlString dataUsingEncoding:NSUTF8StringEncoding];
                _status = 207;
            } else {
                HTTPLogWarn(@"HTTP Server: Invalid PROPPATCH DAV properties\n%@", [[NSString alloc] initWithData:body encoding:NSUTF8StringEncoding]);
                _status = 400;
            }
        }
        
        // 9.1 PROPFIND Method
        if ([method isEqualToString:@"PROPFIND"]) {
            NSInteger depth;
            NSString* depthHeader = [headers objectForKey:@"Depth"];
            if ([depthHeader isEqualToString:@"0"]) {
                depth = 0;
            } else if ([depthHeader isEqualToString:@"1"]) {
                depth = 1;
            } else {
                HTTPLogError(@"Unsupported DAV depth \"%@\"", depthHeader);
                return nil;
            }
            if (DUMP_DAV_BODY)  {
                NSString * testBody = [[NSString alloc] initWithData:body encoding:NSUTF8StringEncoding];
                NSLog(@"PROPFIND body=%@", testBody);
            }
            
            DAVProperties properties = 0;
            xmlDocPtr document = xmlReadMemory(body.bytes, (int)body.length, NULL, NULL, kXMLParseOptions);
            if (document) {
                xmlNodePtr node = _XMLChildWithName(document->children, (const xmlChar*)"propfind");
                if (node) {
                    node = _XMLChildWithName(node->children, (const xmlChar*)"prop");
                }
                if (node) {
                    node = node->children;
                    while (node) {
                        if (!xmlStrcmp(node->name, (const xmlChar*)"resourcetype")) {
                            properties |= kDAVProperty_ResourceType;
                        } else if (!xmlStrcmp(node->name, (const xmlChar*)"creationdate")) {
                            properties |= kDAVProperty_CreationDate;
                        } else if (!xmlStrcmp(node->name, (const xmlChar*)"getlastmodified")) {
                            properties |= kDAVProperty_LastModified;
                        } else if (!xmlStrcmp(node->name, (const xmlChar*)"getcontentlength")) {
                            properties |= kDAVProperty_ContentLength;
                        } else if (!xmlStrcmp(node->name, (const xmlChar*)"quota-available-bytes")) {
                            properties |= kDAVProperty_QuotaAvailableBytes;
                        } else if (!xmlStrcmp(node->name, (const xmlChar*)"quota-used-bytes")) {
                            properties |= kDAVProperty_QuotaAvailableBytes;
                        } else if (!xmlStrcmp(node->name, (const xmlChar*)"quota")) {
                            properties |= kDAVProperty_Quota;
                        } else if (!xmlStrcmp(node->name, (const xmlChar*)"quotaused")) {
                            properties |= kDAVProperty_QuotaUsed;
                        } else if (!xmlStrcmp(node->name, (const xmlChar*)"getetag")) {
                            properties |= kDAVProperty_ETag;
                        } else {
                            HTTPLogWarn(@"Unknown DAV property requested \"%s\" in resource path ‘%@‘ \nrequest:\n%@", node->name, resourcePath, [[NSString alloc] initWithData:body encoding:NSUTF8StringEncoding]);
                        }
                        node = node->next;
                    }
                } else {
                    HTTPLogWarn(@"HTTP Server: Invalid DAV properties\n%@", [[NSString alloc] initWithData:body encoding:NSUTF8StringEncoding]);
                }
                xmlFreeDoc(document);
            }
            if (!properties) {
                properties = kDAVAllProperties;
            }
            
            NSString* basePath = [rootPath stringByAppendingPathComponent:resourcePath];
            if (![basePath hasPrefix:rootPath] || ![[NSFileManager defaultManager] fileExistsAtPath:basePath]) {
                return nil;
            }
            
            NSMutableString* xmlString = [NSMutableString stringWithString:@"<?xml version=\"1.0\" encoding=\"utf-8\" ?>"];
            [xmlString appendString:@"<D:multistatus xmlns:D=\"DAV:\">\n"];
            if (![resourcePath hasPrefix:@"/"]) {
                resourcePath = [@"/" stringByAppendingString:resourcePath];
            }
            _AddPropertyResponse(basePath, resourcePath, properties, xmlString);
            if (depth == 1) {
                if (![resourcePath hasSuffix:@"/"]) {
                    resourcePath = [resourcePath stringByAppendingString:@"/"];
                }
                NSDirectoryEnumerator* enumerator = [[NSFileManager defaultManager] enumeratorAtPath:basePath];
                NSString* path;
                while ((path = [enumerator nextObject])) {
                    _AddPropertyResponse([basePath stringByAppendingPathComponent:path], [resourcePath stringByAppendingString:path], properties, xmlString);
                    [enumerator skipDescendents];
                }
            }
            [xmlString appendString:@"</D:multistatus>"];
            
            [_headers setObject:@"application/xml; charset=\"utf-8\"" forKey:@"Content-Type"];
            _data = [xmlString dataUsingEncoding:NSUTF8StringEncoding];
            _status = 207;
        }
        
        // 9.3 MKCOL Method
        if ([method isEqualToString:@"MKCOL"]) {
            NSString* path = [rootPath stringByAppendingPathComponent:resourcePath];
            if (![path hasPrefix:rootPath]) {
                return nil;
            }
            
            if (![[NSFileManager defaultManager] fileExistsAtPath:[path stringByDeletingLastPathComponent]]) {
                HTTPLogError(@"Missing intermediate collection(s) at \"%@\"", path);
                _status = 409;
            } else if (![[NSFileManager defaultManager] createDirectoryAtPath:path withIntermediateDirectories:NO attributes:nil error:NULL]) {
                HTTPLogError(@"Failed creating collection at \"%@\"", path);
                _status = 405;
            }
        }
        
        // 9.8 COPY Method
        // 9.9 MOVE Method
        if ([method isEqualToString:@"MOVE"] || [method isEqualToString:@"COPY"]) {
            if ([method isEqualToString:@"COPY"] && ![[headers objectForKey:@"Depth"] isEqualToString:@"infinity"]) {
                HTTPLogError(@"Unsupported DAV depth \"%@\"", [headers objectForKey:@"Depth"]);
                return nil;
            }
            
            NSString* sourcePath = [rootPath stringByAppendingPathComponent:resourcePath];
            if (![sourcePath hasPrefix:rootPath] || ![[NSFileManager defaultManager] fileExistsAtPath:sourcePath]) {
                return nil;
            }
            
            NSString* destination = [headers objectForKey:@"Destination"];
            NSRange range = [destination rangeOfString:[headers objectForKey:@"Host"]];
            if (range.location == NSNotFound) {
                return nil;
            }
            NSString* destinationPath = [rootPath stringByAppendingPathComponent:
                                         [[destination substringFromIndex:(range.location + range.length)] stringByReplacingPercentEscapesUsingEncoding:NSUTF8StringEncoding]];
            if (![destinationPath hasPrefix:rootPath] || [[NSFileManager defaultManager] fileExistsAtPath:destinationPath]) {
                return nil;
            }
            
            BOOL isDirectory;
            if (![[NSFileManager defaultManager] fileExistsAtPath:[destinationPath stringByDeletingLastPathComponent] isDirectory:&isDirectory] || !isDirectory) {
                HTTPLogError(@"Invalid destination path \"%@\"", destinationPath);
                _status = 409;
            } else {
                BOOL existing = [[NSFileManager defaultManager] fileExistsAtPath:destinationPath];
                if (existing && [[headers objectForKey:@"Overwrite"] isEqualToString:@"F"]) {
                    HTTPLogError(@"Pre-existing destination path \"%@\"", destinationPath);
                    _status = 412;
                } else {
                    if ([method isEqualToString:@"COPY"]) {
                        if ([[NSFileManager defaultManager] copyItemAtPath:sourcePath toPath:destinationPath error:NULL]) {
                            _status = existing ? 204 : 201;
                        } else {
                            HTTPLogError(@"Failed copying \"%@\" to \"%@\"", sourcePath, destinationPath);
                            _status = 403;
                        }
                    } else {
                        if ([[NSFileManager defaultManager] moveItemAtPath:sourcePath toPath:destinationPath error:NULL]) {
                            _status = existing ? 204 : 201;
                        } else {
                            HTTPLogError(@"Failed moving \"%@\" to \"%@\"", sourcePath, destinationPath);
                            _status = 403;
                        }
                    }
                }
            }
        }
        
        // 9.10 LOCK Method - TODO: Actually lock the resource
        if ([method isEqualToString:@"LOCK"]) {
            NSString* path = [rootPath stringByAppendingPathComponent:resourcePath];
            if (![path hasPrefix:rootPath]) {
                return nil;
            }
            
            NSString* depth = [headers objectForKey:@"Depth"];
            NSString* scope = nil;
            NSString* type = nil;
            NSString* owner = nil;
            NSString* token = nil;
            xmlDocPtr document = xmlReadMemory(body.bytes, (int)body.length, NULL, NULL, kXMLParseOptions);
            if (document) {
                xmlNodePtr node = _XMLChildWithName(document->children, (const xmlChar*)"lockinfo");
                if (node) {
                    xmlNodePtr scopeNode = _XMLChildWithName(node->children, (const xmlChar*)"lockscope");
                    if (scopeNode && scopeNode->children && scopeNode->children->name) {
                        scope = [NSString stringWithUTF8String:(const char*)scopeNode->children->name];
                    }
                    xmlNodePtr typeNode = _XMLChildWithName(node->children, (const xmlChar*)"locktype");
                    if (typeNode && typeNode->children && typeNode->children->name) {
                        type = [NSString stringWithUTF8String:(const char*)typeNode->children->name];
                    }
                    xmlNodePtr ownerNode = _XMLChildWithName(node->children, (const xmlChar*)"owner");
                    if (ownerNode) {
                        ownerNode = _XMLChildWithName(ownerNode->children, (const xmlChar*)"href");
                        if (ownerNode && ownerNode->children && ownerNode->children->content) {
                            owner = [NSString stringWithUTF8String:(const char*)ownerNode->children->content];
                        }
                    }
                } else {
                    HTTPLogWarn(@"HTTP Server: Invalid DAV properties\n%@", [[NSString alloc] initWithData:body encoding:NSUTF8StringEncoding]);
                }
                xmlFreeDoc(document);
            } else {
                // No body, see if they're trying to refresh an existing lock.  If so, then just fake up the scope, type and depth so we fall
                // into the lock create case.
                NSString* lockToken;
                if ((lockToken = [headers objectForKey:@"If"]) != nil) {
                    scope = @"exclusive";
                    type = @"write";
                    depth = @"0";
                    token = [lockToken stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"(<>)"]];
                }
            }
            if ([scope isEqualToString:@"exclusive"] && [type isEqualToString:@"write"] && (depth == nil ||[depth isEqualToString:@"0"]) &&
                ([[NSFileManager defaultManager] fileExistsAtPath:path] || [[NSData data] writeToFile:path atomically:YES])) {
                NSString* timeout = [headers objectForKey:@"Timeout"];
                if (!token) {
                    CFUUIDRef uuid = CFUUIDCreate(kCFAllocatorDefault);
                    NSString *uuidStr = (__bridge_transfer NSString *)CFUUIDCreateString(kCFAllocatorDefault, uuid);
                    token = [NSString stringWithFormat:@"urn:uuid:%@", uuidStr];
                    CFRelease(uuid);
                }
                
                NSMutableString* xmlString = [NSMutableString stringWithString:@"<?xml version=\"1.0\" encoding=\"utf-8\" ?>"];
                [xmlString appendString:@"<D:prop xmlns:D=\"DAV:\">\n"];
                [xmlString appendString:@"<D:lockdiscovery>\n<D:activelock>\n"];
                [xmlString appendFormat:@"<D:locktype><D:%@/></D:locktype>\n", type];
                [xmlString appendFormat:@"<D:lockscope><D:%@/></D:lockscope>\n", scope];
                [xmlString appendFormat:@"<D:depth>%@</D:depth>\n", depth];
                if (owner) {
                    [xmlString appendFormat:@"<D:owner><D:href>%@</D:href></D:owner>\n", owner];
                }
                if (timeout) {
                    [xmlString appendFormat:@"<D:timeout>%@</D:timeout>\n", timeout];
                }
                [xmlString appendFormat:@"<D:locktoken><D:href>%@</D:href></D:locktoken>\n", token];
                NSString* lockroot = [@"http://" stringByAppendingString:[[headers objectForKey:@"Host"] stringByAppendingString:[@"/" stringByAppendingString:resourcePath]]];
                [xmlString appendFormat:@"<D:lockroot><D:href>%@</D:href></D:lockroot>\n", lockroot];
                [xmlString appendString:@"</D:activelock>\n</D:lockdiscovery>\n"];
                [xmlString appendString:@"</D:prop>"];
                
                [_headers setObject:@"application/xml; charset=\"utf-8\"" forKey:@"Content-Type"];
                _data = [xmlString dataUsingEncoding:NSUTF8StringEncoding];
                _status = 200;
                HTTPLogVerbose(@"Pretending to lock \"%@\"", resourcePath);
            } else {
                HTTPLogError(@"Locking request \"%@/%@/%@\" for \"%@\" is not allowed", scope, type, depth, resourcePath);
                _status = 403;
            }
        }
        
        // 9.11 UNLOCK Method - TODO: Actually unlock the resource
        if ([method isEqualToString:@"UNLOCK"]) {
            NSString* path = [rootPath stringByAppendingPathComponent:resourcePath];
            if (![path hasPrefix:rootPath] || ![[NSFileManager defaultManager] fileExistsAtPath:path]) {
                return nil;
            }
            
            NSString* token = [headers objectForKey:@"Lock-Token"];
            _status = token ? 204 : 400;
            HTTPLogVerbose(@"Pretending to unlock \"%@\"", resourcePath);
        }
        
    }
    NSDate * stop = [NSDate new];
    
    if (DUMP_DAV_RESPONSE) NSLog(@"DAV responding with status %ld data:\n%@", (long)_status, [[NSString alloc] initWithData:_data encoding:NSUTF8StringEncoding]);
    
    if (DUMP_DAV_RESPONSE_SHORT) NSLog(@"DAV responding with status %ld len %lu, took %03f", (long)_status, (unsigned long)_data.length, [stop timeIntervalSinceDate:start]);

    return self;
}


- (UInt64) contentLength {
    return _data ? _data.length : 0;
}

- (UInt64) offset {
    return _offset;
}

- (void) setOffset:(UInt64)offset {
    _offset = offset;
}

- (NSData*) readDataOfLength:(NSUInteger)lengthParameter {
    if (_data) {
        NSUInteger remaining = _data.length - (NSUInteger)_offset;
        NSUInteger length = lengthParameter < remaining ? lengthParameter : remaining;
        void* bytes = (void*)(_data.bytes + _offset);
        _offset += length;
        return [NSData dataWithBytesNoCopy:bytes length:length freeWhenDone:NO];
    }
    return nil;
}

- (BOOL) isDone {
    return _data ? _offset == _data.length : YES;
}

- (NSInteger) status {
    return _status;
}

- (NSDictionary*) httpHeaders {
    return _headers;
}

@end
