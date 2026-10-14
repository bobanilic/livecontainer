#import <Foundation/Foundation.h>

// Shared by the guest handoff and cold-start bootstrap. An update can replace
// a bundle outside LiveContainer, so readable metadata alone is insufficient.
static inline BOOL LCGuestBundleNeedsPreparation(NSURL *bundleURL) {
    if (!bundleURL) return YES;
    NSDictionary *info = [NSDictionary dictionaryWithContentsOfURL:
        [bundleURL URLByAppendingPathComponent:@"LCAppInfo.plist"]];
    if (!info) return YES;
    id marker = info[@"LBoxNeedsPreparation"];
    if (marker && (![marker isKindOfClass:NSNumber.class] || [marker boolValue])) return YES;
    NSNumber *revision = info[@"LCPatchRevision"];
    NSArray *containers = info[@"LCContainers"];
    NSString *dataUUID = info[@"LCDataUUID"];
    if (![revision isKindOfClass:NSNumber.class] || revision.integerValue <= 0 ||
        ![containers isKindOfClass:NSArray.class] || containers.count == 0 ||
        ![dataUUID isKindOfClass:NSString.class] || dataUUID.length == 0) return YES;
    return NO;
}

static inline NSString *LCGuestPreparationURL(NSString *scheme, NSString *bundleName,
                                             NSString *container, NSString *openURL) {
    NSURLComponents *components = [NSURLComponents new];
    components.scheme = scheme;
    components.host = @"livecontainer-launch";
    NSMutableArray *query = [NSMutableArray arrayWithObject:
        [NSURLQueryItem queryItemWithName:@"bundle-name" value:bundleName]];
    if (container) [query addObject:[NSURLQueryItem queryItemWithName:@"container-folder-name" value:container]];
    if (openURL) [query addObject:[NSURLQueryItem queryItemWithName:@"open-url"
        value:[[openURL dataUsingEncoding:NSUTF8StringEncoding] base64EncodedStringWithOptions:0]]];
    components.queryItems = query;
    return components.URL.absoluteString;
}
