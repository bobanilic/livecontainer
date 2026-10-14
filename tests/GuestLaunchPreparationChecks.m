#import "../LiveContainer/LCGuestLaunchPreparation.h"
#include <stdio.h>
#include <stdlib.h>

static void expect(BOOL value, NSString *message) {
    if (!value) { NSLog(@"FAILED: %@", message); exit(1); }
}

int main(void) {
    @autoreleasepool {
        NSURL *bundle = [[NSURL fileURLWithPath:NSTemporaryDirectory()]
            URLByAppendingPathComponent:NSUUID.UUID.UUIDString];
        [NSFileManager.defaultManager createDirectoryAtURL:bundle withIntermediateDirectories:YES attributes:nil error:nil];
        NSURL *infoURL = [bundle URLByAppendingPathComponent:@"LCAppInfo.plist"];
        expect(LCGuestBundleNeedsPreparation(bundle), @"Missing metadata must route to preparation");
        NSMutableDictionary *metadata = [@{
            @"LCPatchRevision": @7, @"LCDataUUID": @"existing",
            @"LCContainers": @[@{@"folderName": @"existing"}]
        } mutableCopy];
        [metadata writeToURL:infoURL atomically:YES];
        expect(!LCGuestBundleNeedsPreparation(bundle), @"A prepared app retains the fast launch path");
        metadata[@"LBoxNeedsPreparation"] = @YES;
        [metadata writeToURL:infoURL atomically:YES];
        expect(LCGuestBundleNeedsPreparation(bundle), @"Seeded update metadata still needs signing");
        [metadata removeObjectForKey:@"LBoxNeedsPreparation"];
        metadata[@"LCPatchRevision"] = @(-1);
        [metadata writeToURL:infoURL atomically:YES];
        expect(LCGuestBundleNeedsPreparation(bundle), @"An unpatched binary needs preparation");
        metadata[@"LCPatchRevision"] = @7;
        metadata[@"LCContainers"] = @[];
        [metadata writeToURL:infoURL atomically:YES];
        expect(LCGuestBundleNeedsPreparation(bundle), @"Missing containers need initialization");
        [@"corrupt" writeToURL:infoURL atomically:YES encoding:NSUTF8StringEncoding error:nil];
        expect(LCGuestBundleNeedsPreparation(bundle), @"Unreadable metadata must not enter the guest bootstrap");
        NSString *deepLink = @"spotify://search/jazz?q=a+b&name=Jazz & Blues";
        NSString *queued = LCGuestPreparationURL(@"livecontainer", @"Test App.app", @"existing", deepLink);
        NSURLComponents *components = [NSURLComponents componentsWithString:queued];
        NSMutableDictionary *query = [NSMutableDictionary new];
        for (NSURLQueryItem *item in components.queryItems) query[item.name] = item.value;
        NSString *decoded = [[NSString alloc] initWithData:[[NSData alloc] initWithBase64EncodedString:query[@"open-url"] options:0] encoding:NSUTF8StringEncoding];
        expect([query[@"bundle-name"] isEqualToString:@"Test App.app"], @"App names survive queue encoding");
        expect([query[@"container-folder-name"] isEqualToString:@"existing"], @"Selected data container survives the handoff");
        expect([decoded isEqualToString:deepLink], @"Media payload survives the cold-start handoff");
        [NSFileManager.defaultManager removeItemAtURL:bundle error:nil];
        puts("Guest launch preparation checks passed.");
    }
    return 0;
}
