@import UIKit;
#import "LCSharedUtils.h"
#import "UIKitPrivate.h"
#import "../LiveContainer/utils.h"
#import <LocalAuthentication/LocalAuthentication.h>
#import <Intents/Intents.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import "Localization.h"

UIInterfaceOrientation LCOrientationLock = UIInterfaceOrientationUnknown;
NSMutableArray<NSString*>* LCSupportedUrlSchemes = nil;
BOOL launchURLProcessed = NO;

// URL-scheme helper implemented later in this file.
BOOL canAppOpenItself(NSURL* url);


#pragma mark - Spotify Siri catalog bridge

static void LCSiriDiag(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);

    NSISO8601DateFormatter *formatter = [NSISO8601DateFormatter new];
    NSString *line = [NSString stringWithFormat:@"[%@] GUEST %@",
                      [formatter stringFromDate:[NSDate date]],
                      message ?: @""];
    NSUserDefaults *shared = NSUserDefaults.lcSharedDefaults;
    NSMutableArray<NSString *> *lines =
        [[shared stringArrayForKey:@"LCSiriDiagnosticLog"] mutableCopy] ?: [NSMutableArray new];
    [lines addObject:line];
    if(lines.count > 250) {
        [lines removeObjectsInRange:NSMakeRange(0, lines.count - 250)];
    }
    [shared setObject:lines forKey:@"LCSiriDiagnosticLog"];
    NSLog(@"[LCSiriDiag] %@", message);
}

static void LCSiriDumpSpotifyIntentRuntime(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        SEL handleSel = NSSelectorFromString(@"handlePlayMedia:completion:");
        SEL resolveSel = NSSelectorFromString(@"resolveMediaItemsForPlayMedia:withCompletion:");
        SEL appIntentSel = @selector(application:handlerForIntent:);

        int count = objc_getClassList(NULL, 0);
        if(count > 0) {
            Class *classes = (__unsafe_unretained Class *)calloc((size_t)count, sizeof(Class));
            count = objc_getClassList(classes, count);
            NSMutableArray<NSString *> *matches = [NSMutableArray new];

            for(int i = 0; i < count; i++) {
                Class cls = classes[i];
                const char *raw = class_getName(cls);
                if(!raw) continue;
                NSString *name = [NSString stringWithUTF8String:raw];
                if(!name.length) continue;

                BOOL hasHandle = class_getInstanceMethod(cls, handleSel) != NULL;
                BOOL hasResolve = class_getInstanceMethod(cls, resolveSel) != NULL;
                BOOL hasAppIntent = class_getInstanceMethod(cls, appIntentSel) != NULL;

                NSString *lower = name.lowercaseString;
                BOOL interestingName =
                    [lower containsString:@"siri"] ||
                    [lower containsString:@"intent"] ||
                    [lower containsString:@"spotify"] ||
                    [lower containsString:@"voice"];

                if(hasHandle || hasResolve || (interestingName && hasAppIntent)) {
                    [matches addObject:[NSString stringWithFormat:
                        @"class=%@ handle=%d resolve=%d appHandler=%d",
                        name, hasHandle, hasResolve, hasAppIntent
                    ]];
                }
            }
            free(classes);

            LCSiriDiag(@"runtime intent candidates count=%lu",
                       (unsigned long)matches.count);
            for(NSString *line in matches) {
                LCSiriDiag(@"runtime %@", line);
            }
        }

        NSFileManager *fm = NSFileManager.defaultManager;
        NSURL *bundleURL = NSBundle.mainBundle.bundleURL;
        NSURL *pluginsURL = [bundleURL URLByAppendingPathComponent:@"PlugIns" isDirectory:YES];
        NSArray<NSURL *> *pluginURLs =
            [fm contentsOfDirectoryAtURL:pluginsURL
              includingPropertiesForKeys:nil
                                 options:0
                                   error:nil] ?: @[];

        LCSiriDiag(@"bundle=%@ plugins=%lu",
                   bundleURL.path, (unsigned long)pluginURLs.count);

        for(NSURL *url in pluginURLs) {
            if(![[url.pathExtension lowercaseString] isEqualToString:@"appex"]) continue;
            NSBundle *bundle = [NSBundle bundleWithURL:url];
            NSDictionary *info = bundle.infoDictionary ?: @{};
            NSDictionary *ext = info[@"NSExtension"];
            LCSiriDiag(
                @"appex name=%@ id=%@ point=%@ principal=%@ executable=%@",
                url.lastPathComponent,
                info[@"CFBundleIdentifier"] ?: @"nil",
                [ext isKindOfClass:NSDictionary.class] ? ext[@"NSExtensionPointIdentifier"] : @"nil",
                [ext isKindOfClass:NSDictionary.class] ? ext[@"NSExtensionPrincipalClass"] : @"nil",
                info[@"CFBundleExecutable"] ?: @"nil"
            );
        }
    });
}

static NSString *LCSiriCapturedSpotifyBearerToken = nil;

static void LCSiriCaptureSpotifyBearerToken(NSURLSessionTask *task) {
    NSURLRequest *request = task.currentRequest ?: task.originalRequest;
    NSString *host = request.URL.host.lowercaseString ?: @"";
    if(![host containsString:@"spotify"]) return;

    NSString *auth = [request valueForHTTPHeaderField:@"Authorization"];
    if(![auth hasPrefix:@"Bearer "] || auth.length <= 7) return;

    NSString *token = [auth substringFromIndex:7];
    if(token.length < 20) return;

    BOOL changed = NO;
    @synchronized([NSURLSessionTask class]) {
        changed = ![LCSiriCapturedSpotifyBearerToken isEqualToString:token];
        LCSiriCapturedSpotifyBearerToken = [token copy];
    }
    if(changed) {
        LCSiriDiag(@"captured NEW Spotify bearer token len=%lu host=%@",
                   (unsigned long)token.length, host);
    }
}

@interface NSURLSessionTask (LCSiriTokenCapture)
- (void)lc_siri_resume;
@end

@implementation NSURLSessionTask (LCSiriTokenCapture)
- (void)lc_siri_resume {
    LCSiriCaptureSpotifyBearerToken(self);
    [self lc_siri_resume];
}
@end

static NSString *LCSiriSpotifyTokenWait(NSTimeInterval timeout) {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
    while(deadline.timeIntervalSinceNow > 0) {
        @synchronized([NSURLSessionTask class]) {
            if(LCSiriCapturedSpotifyBearerToken.length > 0) {
                return [LCSiriCapturedSpotifyBearerToken copy];
            }
        }
        [NSThread sleepForTimeInterval:0.10];
    }
    return nil;
}

static NSString *LCSiriFirstNonEmpty(NSArray<NSString *> *values) {
    for(NSString *value in values) {
        if([value isKindOfClass:NSString.class] &&
           [value stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].length > 0) {
            return value;
        }
    }
    return nil;
}

static NSDictionary *LCSiriSpotifySearchDescriptor(INMediaSearch *search) {
    if(!search) return nil;

    NSString *genre = LCSiriFirstNonEmpty(search.genreNames ?: @[]);
    NSString *mood = LCSiriFirstNonEmpty(search.moodNames ?: @[]);
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    NSString *activity = LCSiriFirstNonEmpty(search.activityNames ?: @[]);
#pragma clang diagnostic pop

    if(genre.length || mood.length || activity.length) {
        NSMutableArray<NSString *> *parts = [NSMutableArray new];
        if(genre.length) [parts addObject:genre];
        if(mood.length) [parts addObject:mood];
        if(activity.length) [parts addObject:activity];
        return @{
            @"q": [parts componentsJoinedByString:@" "],
            @"type": @"playlist",
            @"shuffle": @YES
        };
    }

    NSString *media = [search.mediaName stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSString *artist = [search.artistName stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSString *album = [search.albumName stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];

    if(media.length) {
        NSMutableString *q = [NSMutableString stringWithString:media];
        if(artist.length) [q appendFormat:@" %@", artist];
        return @{@"q": q, @"type": @"track", @"shuffle": @NO};
    }
    if(album.length) {
        NSMutableString *q = [NSMutableString stringWithString:album];
        if(artist.length) [q appendFormat:@" %@", artist];
        return @{@"q": q, @"type": @"album", @"shuffle": @NO};
    }
    if(artist.length) {
        return @{@"q": artist, @"type": @"artist", @"shuffle": @YES};
    }
    return nil;
}

static NSDictionary *LCSiriSpotifyDescriptorFromIntent(INPlayMediaIntent *intent) {
    for(INMediaItem *item in intent.mediaItems ?: @[]) {
        NSString *identifier = item.identifier ?: @"";
        NSString *prefix = @"livecontainer.spotify.query:";
        if(![identifier hasPrefix:prefix]) continue;

        NSString *encoded = [identifier substringFromIndex:prefix.length];
        NSData *data = [[NSData alloc] initWithBase64EncodedString:encoded options:0];
        if(!data.length) continue;

        NSError *error = nil;
        NSDictionary *descriptor =
            [NSJSONSerialization JSONObjectWithData:data options:0 error:&error];
        if([descriptor isKindOfClass:NSDictionary.class] &&
           [descriptor[@"q"] isKindOfClass:NSString.class] &&
           [descriptor[@"type"] isKindOfClass:NSString.class]) {
            LCSiriDiag(@"recovered query=%@ type=%@ shuffle=%@",
                       descriptor[@"q"], descriptor[@"type"], descriptor[@"shuffle"]);
            return descriptor;
        }

        NSLog(@"[LCSiri] Failed to decode preserved Siri query: %@", error);
    }

    return LCSiriSpotifySearchDescriptor(intent.mediaSearch);
}


static NSDictionary *LCSiriResolveSpotifyCatalogDescriptor(NSDictionary *descriptor) {
    if(!descriptor) return nil;

    NSString *token = LCSiriSpotifyTokenWait(5.0);
    if(!token.length) {
        LCSiriDiag(@"catalog lookup: NO captured bearer token");
        return nil;
    }

    NSString *query = descriptor[@"q"];
    NSString *type = descriptor[@"type"];
    NSCharacterSet *allowed = NSCharacterSet.URLQueryAllowedCharacterSet;
    NSString *encodedQ = [query stringByAddingPercentEncodingWithAllowedCharacters:allowed] ?: query;
    NSString *urlString = [NSString stringWithFormat:
        @"https://api.spotify.com/v1/search?q=%@&type=%@&limit=1",
        encodedQ, type
    ];
    NSURL *url = [NSURL URLWithString:urlString];
    if(!url) return nil;

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    [request setValue:[@"Bearer " stringByAppendingString:token] forHTTPHeaderField:@"Authorization"];
    [request setValue:@"application/json" forHTTPHeaderField:@"Accept"];
    request.timeoutInterval = 6.0;

    __block NSData *responseData = nil;
    __block NSInteger statusCode = 0;
    __block NSError *requestError = nil;
    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);

    NSURLSessionDataTask *task = [NSURLSession.sharedSession
        dataTaskWithRequest:request
        completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
            responseData = data;
            requestError = error;
            if([response isKindOfClass:NSHTTPURLResponse.class]) {
                statusCode = ((NSHTTPURLResponse *)response).statusCode;
            }
            dispatch_semaphore_signal(semaphore);
        }];
    [task resume];

    if(dispatch_semaphore_wait(
        semaphore,
        dispatch_time(DISPATCH_TIME_NOW, (int64_t)(7.0 * NSEC_PER_SEC))
    ) != 0) {
        NSLog(@"[LCSiri] Spotify catalog lookup timed out for %@", query);
        return nil;
    }

    if(requestError || statusCode != 200 || !responseData.length) {
        LCSiriDiag(@"catalog lookup failed status=%ld error=%@",
                   (long)statusCode, requestError);
        return nil;
    }

    NSError *jsonError = nil;
    NSDictionary *json = [NSJSONSerialization JSONObjectWithData:responseData options:0 error:&jsonError];
    if(![json isKindOfClass:NSDictionary.class] || jsonError) {
        NSLog(@"[LCSiri] Spotify catalog JSON failed: %@", jsonError);
        return nil;
    }

    NSString *containerKey = [type stringByAppendingString:@"s"];
    NSDictionary *container = json[containerKey];
    NSArray *items = [container isKindOfClass:NSDictionary.class] ? container[@"items"] : nil;
    NSDictionary *item = nil;
    for(id candidate in items ?: @[]) {
        if([candidate isKindOfClass:NSDictionary.class] &&
           [candidate[@"uri"] isKindOfClass:NSString.class]) {
            item = candidate;
            break;
        }
    }
    if(!item) {
        NSLog(@"[LCSiri] Spotify catalog returned no %@ result for %@", type, query);
        return nil;
    }

    NSString *uri = item[@"uri"];
    NSString *name = [item[@"name"] isKindOfClass:NSString.class] ? item[@"name"] : query;
    LCSiriDiag(@"catalog resolved query=%@ type=%@ -> name=%@ uri=%@",
               query, type, name, uri);
    return @{
        @"uri": uri,
        @"name": name,
        @"type": type,
        @"shuffle": descriptor[@"shuffle"] ?: @NO
    };
}

static NSDictionary *LCSiriResolveSpotifyCatalog(INPlayMediaIntent *intent) {
    return LCSiriResolveSpotifyCatalogDescriptor(
        LCSiriSpotifyDescriptorFromIntent(intent)
    );
}

static NSString *LCSiriSpotifyPlayCommand(NSString *uri, NSString *title, BOOL shuffle) {
    if(!uri.length) return nil;

    NSString *requestID = NSUUID.UUID.UUIDString.lowercaseString;
    NSString *playbackID = [[NSUUID.UUID.UUIDString stringByReplacingOccurrencesOfString:@"-" withString:@""] lowercaseString];
    NSString *contextURL = [@"context://" stringByAppendingString:uri];

    NSDictionary *payload = @{
        @"action": @"spotify:nl:CAASEKRyTrpCx02MnQ/7yWIbkMMaEDE3OmFub255bWl6ZWQ6NjYgAOADA+gD1e6Ksdwx8AMh",
        @"context": @{
            @"metadata": @{@"autoplay_candidate": @"true"},
            @"uri": uri,
            @"url": contextURL
        },
        @"feedback_details": @{
            @"entity_type": @"track",
            @"has_tracks": @YES,
            @"track_name": title ?: @"Siri",
            @"playlist_name": title ?: @"Siri",
            @"uri": uri
        },
        @"feedback_id": @"PLAY_MYTRACKS",
        @"intent": @"PLAY",
        @"performance_measurements": @{
            @"entry_app_extension": @0,
            @"exit_app_extension": @0,
            @"resolve_play_context_request_finished": @0,
            @"resolve_play_context_request_started": @0
        },
        @"play_options": @{
            @"always_play_something": @YES,
            @"initially_paused": @NO,
            @"playback_id": playbackID,
            @"player_options_override": @{
                @"repeating_context": @NO,
                @"repeating_track": @NO,
                @"shuffling_context": @(shuffle)
            },
            @"session_id": requestID,
            @"suppressions": @{}
        },
        @"play_origin": @{
            @"feature_identifier": @"voice-assistant-siri",
            @"referrer_identifier": @"voice"
        },
        @"req_id": requestID,
        @"result": @"SUCCESS"
    };

    NSError *error = nil;
    NSData *json = [NSJSONSerialization dataWithJSONObject:payload options:0 error:&error];
    if(!json || error) {
        NSLog(@"[LCSiri] Failed to encode Spotify play-command: %@", error);
        return nil;
    }

    return [@"spotify:play-command:" stringByAppendingString:
        [json base64EncodedStringWithOptions:0]];
}

static id LCOriginalSpotifyHandlerForIntent(
    id delegate,
    UIApplication *application,
    INIntent *intent
);

static void LCSiriExecuteResolvedSpotifyURI(
    NSString *uri,
    NSString *title,
    BOOL shuffle,
    id<UIApplicationDelegate> delegate
);

#pragma mark - Siri media bridge while a guest app owns the LiveContainer process

static BOOL LCDeliverURLDirectlyToActiveGuest(NSURL *url) {
    if(!url) return NO;

    UIApplication *application = UIApplication.sharedApplication;
    id<UIApplicationDelegate> delegate = application.delegate;

    SEL modernSelector = @selector(application:openURL:options:);
    if(delegate && [delegate respondsToSelector:modernSelector]) {
        BOOL (*invoke)(id, SEL, UIApplication *, NSURL *, NSDictionary *) =
            (void *)objc_msgSend;
        BOOL handled = invoke(delegate, modernSelector, application, url, @{});
        LCSiriDiag(@"direct URL delivery handled=%d scheme=%@ absolutePrefix=%@",
                   handled, url.scheme, [url.absoluteString substringToIndex:MIN((NSUInteger)80, url.absoluteString.length)]);
        if(handled) return YES;
    }

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    SEL legacySelector = @selector(application:handleOpenURL:);
    if(delegate && [delegate respondsToSelector:legacySelector]) {
        BOOL (*invokeLegacy)(id, SEL, UIApplication *, NSURL *) =
            (void *)objc_msgSend;
        BOOL handled = invokeLegacy(delegate, legacySelector, application, url);
        NSLog(@"[LCSiri] Legacy AppDelegate URL delivery handled=%d url=%@", handled, url);
        if(handled) return YES;
    }
#pragma clang diagnostic pop

    return NO;
}

static BOOL LCHasSpecificMediaRequest(INPlayMediaIntent *intent) {
    return LCSiriSpotifyDescriptorFromIntent(intent) != nil;
}

// INIntentResolutionResult has a private resolvedValue accessor used internally by
// Intents.framework. We use it only to recover the INMediaItem that Spotify itself
// resolved from the user's natural-language request.
static INMediaItem *LCResolvedMediaItem(
    NSArray<INPlayMediaMediaItemResolutionResult *> *results
) {
    SEL selector = NSSelectorFromString(@"resolvedValue");

    for(INPlayMediaMediaItemResolutionResult *result in results) {
        if(![result respondsToSelector:selector]) {
            continue;
        }

        id (*invoke)(id, SEL) = (void *)objc_msgSend;
        id value = invoke(result, selector);
        if([value isKindOfClass:INMediaItem.class]) {
            INMediaItem *item = value;
            NSLog(@"[LCSiri] Spotify resolved media item title=%@ identifier=%@",
                  item.title, item.identifier);
            return item;
        }
    }
    return nil;
}

static INPlayMediaIntent *LCIntentByReplacingMediaItem(
    INPlayMediaIntent *source,
    INMediaItem *item
) {
    return [[INPlayMediaIntent alloc]
        initWithMediaItems:item ? @[item] : source.mediaItems
        mediaContainer:source.mediaContainer
        playShuffled:source.playShuffled
        playbackRepeatMode:source.playbackRepeatMode
        resumePlayback:source.resumePlayback
        playbackQueueLocation:source.playbackQueueLocation
        playbackSpeed:source.playbackSpeed
        mediaSearch:source.mediaSearch];
}

static BOOL LCTryExecuteSpotifyPlayCommand(INPlayMediaIntent *intent) {
    for(INMediaItem *item in intent.mediaItems ?: @[]) {
        NSString *identifier = item.identifier;
        if(![identifier hasPrefix:@"spotify:play-command:"]) {
            continue;
        }

        NSURL *url = [NSURL URLWithString:identifier];
        if(!url) {
            continue;
        }

        NSLog(@"[LCSiri] Executing Spotify native play-command");
        if(LCDeliverURLDirectlyToActiveGuest(url)) {
            return YES;
        }

        [UIApplication.sharedApplication openURL:url
                                         options:@{}
                               completionHandler:^(BOOL success) {
            NSLog(@"[LCSiri] Spotify play-command system fallback success=%d", success);
        }];
        return YES;
    }
    return NO;
}

static void LCSiriExecuteResolvedSpotifyURI(
    NSString *uri,
    NSString *title,
    BOOL shuffle,
    id<UIApplicationDelegate> delegate
) {
    NSString *identifier = LCSiriSpotifyPlayCommand(uri, title, shuffle);
    if(!identifier.length) {
        LCSiriDiag(@"could not build play-command uri=%@", uri);
        return;
    }

    LCSiriDiag(@"built play-command target=%@ title=%@ shuffle=%d payloadLen=%lu",
               uri, title, shuffle, (unsigned long)identifier.length);

    INMediaItem *item = [[INMediaItem alloc]
        initWithIdentifier:identifier
        title:title ?: @"Spotify"
        type:INMediaItemTypeMusic
        artwork:nil];

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    INPlayMediaIntent *intent = [[INPlayMediaIntent alloc]
        initWithMediaItems:@[item]
        mediaContainer:nil
        playShuffled:@(shuffle)
        playbackRepeatMode:INPlaybackRepeatModeNone
        resumePlayback:@NO];
#pragma clang diagnostic pop

    id nativeHandler = LCOriginalSpotifyHandlerForIntent(
        delegate,
        UIApplication.sharedApplication,
        intent
    );

    LCSiriDiag(@"native handler class=%@",
               nativeHandler ? NSStringFromClass([nativeHandler class]) : @"nil");

    if(nativeHandler &&
       [nativeHandler respondsToSelector:@selector(handlePlayMedia:completion:)]) {
        id<INPlayMediaIntentHandling> handler = nativeHandler;
        [handler handlePlayMedia:intent completion:^(INPlayMediaIntentResponse *response) {
            LCSiriDiag(@"native handle response code=%ld target=%@",
                       (long)response.code, uri);
        }];
        return;
    }

    // Keep the URL fallback only as a diagnostic last resort; this path is known
    // to show Spotify's “Couldn't Open Link” alert on some Eevee builds.
    BOOL direct = LCTryExecuteSpotifyPlayCommand(intent);
    LCSiriDiag(@"native handler unavailable; URL fallback attempted=%d", direct);
}

@interface LCSiriGuestMediaIntentHandler : NSObject <INPlayMediaIntentHandling>
@property(nonatomic, strong) id<INPlayMediaIntentHandling> nativeHandler;
+ (instancetype)sharedHandler;
- (void)configureNativeHandler:(id<INPlayMediaIntentHandling>)handler;
@end

@implementation LCSiriGuestMediaIntentHandler

+ (instancetype)sharedHandler {
    static LCSiriGuestMediaIntentHandler *handler;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        handler = [LCSiriGuestMediaIntentHandler new];
    });
    return handler;
}

- (void)configureNativeHandler:(id<INPlayMediaIntentHandling>)handler {
    self.nativeHandler = handler;
}

- (void)resolveMediaItemsForPlayMedia:(INPlayMediaIntent *)intent
                      withCompletion:(void (^)(NSArray<INPlayMediaMediaItemResolutionResult *> *))completion {
    id<INPlayMediaIntentHandling> native = self.nativeHandler;

    if(native &&
       [native respondsToSelector:@selector(resolveMediaItemsForPlayMedia:withCompletion:)]) {
        NSLog(@"[LCSiri] Asking Spotify native resolver for media items");
        [native resolveMediaItemsForPlayMedia:intent
                               withCompletion:^(NSArray<INPlayMediaMediaItemResolutionResult *> *results) {
            INMediaItem *item = LCResolvedMediaItem(results);
            if(item) {
                NSLog(@"[LCSiri] Native resolver produced Spotify identifier %@", item.identifier);
            } else {
                NSLog(@"[LCSiri] Native resolver returned no directly resolved media item");
            }
            completion(results);
        }];
        return;
    }

    NSString *title = intent.mediaSearch.mediaName;
    if(title.length == 0) title = intent.mediaSearch.artistName;
    if(title.length == 0) title = intent.mediaSearch.albumName;
    if(title.length == 0) title = intent.mediaSearch.genreNames.firstObject;
    if(title.length == 0) title = intent.mediaSearch.moodNames.firstObject;
    if(title.length == 0) title = @"Spotify";

    INMediaItem *item = [[INMediaItem alloc] initWithIdentifier:@"livecontainer.spotify"
                                                          title:title
                                                           type:INMediaItemTypeMusic
                                                        artwork:nil];
    completion([INPlayMediaMediaItemResolutionResult successesWithResolvedMediaItems:@[item]]);
}

- (void)handlePlayMedia:(INPlayMediaIntent *)intent
             completion:(void (^)(INPlayMediaIntentResponse *))completion {
    NSDictionary *preservedDescriptor = LCSiriSpotifyDescriptorFromIntent(intent);
    if(preservedDescriptor) {
        completion([[INPlayMediaIntentResponse alloc]
            initWithCode:INPlayMediaIntentResponseCodeSuccess
            userActivity:nil]);

        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            NSDictionary *resolved =
                LCSiriResolveSpotifyCatalogDescriptor(preservedDescriptor);
            if(!resolved) {
                NSLog(@"[LCSiri] Preserved Siri query could not be resolved");
                return;
            }

            dispatch_async(dispatch_get_main_queue(), ^{
                LCSiriExecuteResolvedSpotifyURI(
                    resolved[@"uri"],
                    resolved[@"name"],
                    [resolved[@"shuffle"] boolValue],
                    UIApplication.sharedApplication.delegate
                );
            });
        });
        return;
    }

    // After Siri's resolution pass, Spotify's resolved INMediaItem normally carries
    // a spotify:play-command:<payload> identifier. Execute that command directly so
    // the guest does not depend on iOS believing native Spotify is installed.
    if(LCTryExecuteSpotifyPlayCommand(intent)) {
        completion([[INPlayMediaIntentResponse alloc]
            initWithCode:INPlayMediaIntentResponseCodeSuccess
            userActivity:nil]);
        return;
    }

    id<INPlayMediaIntentHandling> native = self.nativeHandler;
    if(native && [native respondsToSelector:@selector(handlePlayMedia:completion:)]) {
        NSLog(@"[LCSiri] No direct play-command on intent; trying Spotify native handle");
        [native handlePlayMedia:intent completion:^(INPlayMediaIntentResponse *response) {
            if(response.code == INPlayMediaIntentResponseCodeSuccess ||
               response.code == INPlayMediaIntentResponseCodeInProgress ||
               response.code == INPlayMediaIntentResponseCodeHandleInApp) {
                completion(response);
                return;
            }

            NSLog(@"[LCSiri] Spotify native handle failed code=%ld", (long)response.code);
            completion(response);
        }];
        return;
    }

    // Generic fallback remains the known-working Liked Songs playback route.
    NSURL *url = [NSURL URLWithString:@"spotify:internal:collection:tracks"];
    completion([[INPlayMediaIntentResponse alloc]
        initWithCode:INPlayMediaIntentResponseCodeSuccess
        userActivity:nil]);
    dispatch_async(dispatch_get_main_queue(), ^{
        if(!LCDeliverURLDirectlyToActiveGuest(url)) {
            [UIApplication.sharedApplication openURL:url options:@{} completionHandler:nil];
        }
    });
}

@end

static IMP LCOriginalGuestIntentHandlerIMP = NULL;
static Class LCHookedGuestDelegateClass = Nil;

static id LCOriginalSpotifyHandlerForIntent(
    id delegate,
    UIApplication *application,
    INIntent *intent
) {
    if(!LCOriginalGuestIntentHandlerIMP) {
        return nil;
    }

    id (*original)(id, SEL, UIApplication *, INIntent *) = (void *)LCOriginalGuestIntentHandlerIMP;
    id handler = original(
        delegate,
        @selector(application:handlerForIntent:),
        application,
        intent
    );

    LCSiriDiag(@"original Spotify handler lookup -> %@",
               handler ? NSStringFromClass([handler class]) : @"nil");
    return handler;
}

static void LCExecutePendingSpotifyPlayMediaIntent(id<UIApplicationDelegate> delegate) {
    NSUserDefaults *shared = NSUserDefaults.lcSharedDefaults;
    NSData *data = [shared dataForKey:@"LCSiriPendingPlayMediaIntent"];
    NSDate *date = [shared objectForKey:@"LCSiriPendingPlayMediaDate"];

    if(!data) {
        return;
    }

    [shared removeObjectForKey:@"LCSiriPendingPlayMediaIntent"];
    [shared removeObjectForKey:@"LCSiriPendingPlayMediaDate"];

    if(date && fabs(date.timeIntervalSinceNow) > 30.0) {
        NSLog(@"[LCSiri] Ignoring stale pending PlayMedia intent");
        return;
    }

    NSError *error = nil;
    INPlayMediaIntent *intent =
        [NSKeyedUnarchiver unarchivedObjectOfClass:INPlayMediaIntent.class
                                          fromData:data
                                             error:&error];
    if(!intent || error) {
        NSLog(@"[LCSiri] Failed to decode pending PlayMedia intent: %@", error);
        return;
    }

    NSDictionary *preservedDescriptor = LCSiriSpotifyDescriptorFromIntent(intent);
    if(preservedDescriptor) {
        NSLog(@"[LCSiri] Cold start: resolving preserved Siri query through Spotify catalog");
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            NSDictionary *resolved =
                LCSiriResolveSpotifyCatalogDescriptor(preservedDescriptor);
            if(!resolved) {
                NSLog(@"[LCSiri] Cold start: preserved Siri query resolution failed");
                return;
            }

            dispatch_async(dispatch_get_main_queue(), ^{
                LCSiriExecuteResolvedSpotifyURI(
                    resolved[@"uri"],
                    resolved[@"name"],
                    [resolved[@"shuffle"] boolValue],
                    delegate
                );
            });
        });
        return;
    }

    id<INPlayMediaIntentHandling> nativeHandler = LCOriginalSpotifyHandlerForIntent(
        delegate,
        UIApplication.sharedApplication,
        intent
    );

    if(nativeHandler &&
       [nativeHandler respondsToSelector:@selector(resolveMediaItemsForPlayMedia:withCompletion:)]) {
        NSLog(@"[LCSiri] Cold start: resolving specific request with Spotify native resolver");
        [nativeHandler resolveMediaItemsForPlayMedia:intent
                                      withCompletion:^(NSArray<INPlayMediaMediaItemResolutionResult *> *results) {
            INMediaItem *resolvedItem = LCResolvedMediaItem(results);
            if(resolvedItem) {
                INPlayMediaIntent *resolvedIntent =
                    LCIntentByReplacingMediaItem(intent, resolvedItem);

                if(LCTryExecuteSpotifyPlayCommand(resolvedIntent)) {
                    NSLog(@"[LCSiri] Cold start: executed resolved Spotify play-command");
                    return;
                }

                NSLog(@"[LCSiri] Cold start: resolved item had no executable play-command; trying native handle");
                [nativeHandler handlePlayMedia:resolvedIntent
                                    completion:^(INPlayMediaIntentResponse *response) {
                    NSLog(@"[LCSiri] Spotify resolved native response code=%ld", (long)response.code);
                }];
                return;
            }

            NSLog(@"[LCSiri] Cold start: Spotify native resolver produced no resolved item");
            [nativeHandler handlePlayMedia:intent
                                completion:^(INPlayMediaIntentResponse *response) {
                NSLog(@"[LCSiri] Spotify unresolved native response code=%ld", (long)response.code);
            }];
        }];
        return;
    }

    NSLog(@"[LCSiri] Cold start: Spotify native resolver unavailable");
    LCSiriGuestMediaIntentHandler *fallback = [LCSiriGuestMediaIntentHandler sharedHandler];
    [fallback configureNativeHandler:nativeHandler];
    [fallback handlePlayMedia:intent completion:^(INPlayMediaIntentResponse *response) {
        NSLog(@"[LCSiri] Fallback pending response code=%ld", (long)response.code);
    }];
}

static id LCGuestApplicationHandlerForIntent(id self, SEL _cmd, UIApplication *application, INIntent *intent) {
    NSURL *spotifyProbe = [NSURL URLWithString:@"spotify:"];
    if([intent isKindOfClass:INPlayMediaIntent.class] && spotifyProbe && canAppOpenItself(spotifyProbe)) {
        INPlayMediaIntent *playIntent = (INPlayMediaIntent *)intent;
        LCSiriGuestMediaIntentHandler *bridge = [LCSiriGuestMediaIntentHandler sharedHandler];

        if(!LCHasSpecificMediaRequest(playIntent)) {
            [bridge configureNativeHandler:nil];
            NSLog(@"[LCSiri] Generic PlayMedia request -> LC Liked Songs bridge");
            return bridge;
        }

        id<INPlayMediaIntentHandling> native =
            LCOriginalSpotifyHandlerForIntent(self, application, intent);
        [bridge configureNativeHandler:native];

        if(native) {
            NSLog(@"[LCSiri] Specific PlayMedia request -> Spotify resolver + LC executor");
        } else {
            NSLog(@"[LCSiri] Specific PlayMedia request but Spotify native handler unavailable");
        }
        return bridge;
    }

    return LCOriginalSpotifyHandlerForIntent(self, application, intent);
}

static void LCInstallGuestIntentHandlerIfNeeded(id<UIApplicationDelegate> delegate) {
    if(!delegate || LCHookedGuestDelegateClass == [delegate class]) {
        return;
    }

    NSURL *spotifyProbe = [NSURL URLWithString:@"spotify:"];
    if(!spotifyProbe || !canAppOpenItself(spotifyProbe)) {
        return;
    }

    Class cls = [delegate class];
    SEL selector = @selector(application:handlerForIntent:);
    Method visibleMethod = class_getInstanceMethod(cls, selector);
    LCOriginalGuestIntentHandlerIMP = visibleMethod ? method_getImplementation(visibleMethod) : NULL;
    const char *types = visibleMethod ? method_getTypeEncoding(visibleMethod) : "@@:@@";

    if(!class_addMethod(cls, selector, (IMP)LCGuestApplicationHandlerForIntent, types)) {
        class_replaceMethod(cls, selector, (IMP)LCGuestApplicationHandlerForIntent, types);
    }

    LCHookedGuestDelegateClass = cls;
    LCSiriDiag(@"installed Siri bridge delegateClass=%@ originalAppIntentIMP=%d",
               NSStringFromClass(cls), LCOriginalGuestIntentHandlerIMP != NULL);

    dispatch_after(
        dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
        dispatch_get_main_queue(),
        ^{
            LCSiriDumpSpotifyIntentRuntime();
        }
    );

    dispatch_after(
        dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.75 * NSEC_PER_SEC)),
        dispatch_get_main_queue(),
        ^{
            LCExecutePendingSpotifyPlayMediaIntent(delegate);
        }
    );
}

__attribute__((constructor))
static void UIKitGuestHooksInit() {
    if(!NSUserDefaults.lcGuestAppId) return;
    swizzle(UIApplication.class, @selector(_applicationOpenURLAction:payload:origin:), @selector(hook__applicationOpenURLAction:payload:origin:));
    swizzle(UIApplication.class, @selector(_connectUISceneFromFBSScene:transitionContext:), @selector(hook__connectUISceneFromFBSScene:transitionContext:));
    swizzle(UIApplication.class, @selector(openURL:options:completionHandler:), @selector(hook_openURL:options:completionHandler:));
    swizzle(UIApplication.class, @selector(canOpenURL:), @selector(hook_canOpenURL:));
    swizzle(UIApplication.class, @selector(setDelegate:), @selector(hook_setDelegate:));
    swizzle(NSURLSessionTask.class, @selector(resume), @selector(lc_siri_resume));
    swizzle(UIScene.class, @selector(scene:didReceiveActions:fromTransitionContext:), @selector(hook_scene:didReceiveActions:fromTransitionContext:));
    swizzle(UIScene.class, @selector(openURL:options:completionHandler:), @selector(hook_openURL:options:completionHandler:));
    NSInteger LCOrientationLockDirection = [NSUserDefaults.guestAppInfo[@"LCOrientationLock"] integerValue];
    if(LCOrientationLockDirection != 0 && [UIDevice.currentDevice userInterfaceIdiom] == UIUserInterfaceIdiomPhone) {
        switch (LCOrientationLockDirection) {
            case 1:
                LCOrientationLock = UIInterfaceOrientationLandscapeRight;
                break;
            case 2:
                LCOrientationLock = UIInterfaceOrientationPortrait;
                break;
            default:
                break;
        }
        if(!NSUserDefaults.isLiveProcess && LCOrientationLock != UIInterfaceOrientationUnknown) {
//            swizzle(UIApplication.class, @selector(_handleDelegateCallbacksWithOptions:isSuspended:restoreState:), @selector(hook__handleDelegateCallbacksWithOptions:isSuspended:restoreState:));
            swizzle(FBSSceneParameters.class, @selector(initWithXPCDictionary:), @selector(hook_initWithXPCDictionary:));
            swizzle(UIViewController.class, @selector(__supportedInterfaceOrientations), @selector(hook___supportedInterfaceOrientations));
            swizzle(UIViewController.class, @selector(shouldAutorotateToInterfaceOrientation:), @selector(hook_shouldAutorotateToInterfaceOrientation:));
            swizzle(UIWindow.class, @selector(setAutorotates:forceUpdateInterfaceOrientation:), @selector(hook_setAutorotates:forceUpdateInterfaceOrientation:));
        }

    }
}

NSString* findDefaultContainerWithBundleId(NSString* bundleId) {
    // find app's default container
    NSString *appGroupPath = [NSUserDefaults lcAppGroupPath];
    NSString* appGroupFolder = [appGroupPath stringByAppendingPathComponent:@"LiveContainer"];
    
    NSString* bundleInfoPath = [NSString stringWithFormat:@"%@/Applications/%@/LCAppInfo.plist", appGroupFolder, bundleId];
    NSDictionary* infoDict = [NSDictionary dictionaryWithContentsOfFile:bundleInfoPath];
    if(!infoDict) {
        NSString* lcDocFolder = [[NSString stringWithUTF8String:getenv("LC_HOME_PATH")] stringByAppendingPathComponent:@"Documents"];
        
        bundleInfoPath = [NSString stringWithFormat:@"%@/Applications/%@/LCAppInfo.plist", lcDocFolder, bundleId];
        infoDict = [NSDictionary dictionaryWithContentsOfFile:bundleInfoPath];
    }
    
    return infoDict[@"LCDataUUID"];
}

void forEachInstalledNotCurrentLC(BOOL isFree, void (^block)(NSString* scheme, BOOL* isBreak)) {
    for(NSString* scheme in [NSClassFromString(@"LCSharedUtils") lcUrlSchemes]) {
        if([scheme isEqualToString:NSUserDefaults.lcAppUrlScheme]) {
            continue;
        }
        BOOL isInstalled = [UIApplication.sharedApplication canOpenURL:[NSURL URLWithString: [NSString stringWithFormat: @"%@://", scheme]]];
        if(!isInstalled) {
            continue;
        }
        BOOL isBreak = false;
        if(isFree && [NSClassFromString(@"LCSharedUtils") isLCSchemeInUse:scheme]) {
            continue;
        }
        block(scheme, &isBreak);
        if(isBreak) {
            return;
        }
    }
}

void LCShowSwitchAppConfirmation(NSURL *url, NSString* bundleId, bool isSharedApp) {
    NSURLComponents* newUrlComp = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
    
    // check if there's any free LiveContainer to run the app
    if(isSharedApp) {
        __block BOOL anotherLCLaunched = false;
        forEachInstalledNotCurrentLC(YES, ^(NSString * scheme, BOOL* isBreak) {
            newUrlComp.scheme = scheme;
            [UIApplication.sharedApplication openURL:newUrlComp.URL options:@{} completionHandler:nil];
            *isBreak = YES;
            anotherLCLaunched = YES;
            return;
        });
        if(anotherLCLaunched) {
            return;
        }
    }
    
    // if LCSwitchAppWithoutAsking is enabled we directly open the app in current lc
    if ([NSUserDefaults.lcUserDefaults boolForKey:@"LCSwitchAppWithoutAsking"]) {
        [NSClassFromString(@"LCSharedUtils") launchToGuestAppWithURL:url];
        return;
    }

    NSString *message = [@"lc.guestTweak.appSwitchTip %@" localizeWithFormat:bundleId];
    UIWindow *window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"LiveContainer" message:message preferredStyle:UIAlertControllerStyleAlert];
    UIAlertAction* okAction = [UIAlertAction actionWithTitle:@"lc.common.ok".loc style:UIAlertActionStyleDefault handler:^(UIAlertAction * action) {
        [NSUserDefaults.lcUserDefaults setBool:NO forKey:@"LCOpenSideStore"];
        [NSClassFromString(@"LCSharedUtils") launchToGuestAppWithURL:url];
        window.windowScene = nil;
    }];
    [alert addAction:okAction];
    
    if(isSharedApp) {
        forEachInstalledNotCurrentLC(NO, ^(NSString * scheme, BOOL* isBreak) {
            UIAlertAction* openlcAction = [UIAlertAction actionWithTitle:[@"lc.guestTweak.openInLc %@" localizeWithFormat:scheme] style:UIAlertActionStyleDefault handler:^(UIAlertAction * action) {
                newUrlComp.scheme = scheme;
                [UIApplication.sharedApplication openURL:newUrlComp.URL options:@{} completionHandler:nil];
                window.windowScene = nil;
            }];
            [alert addAction:openlcAction];
        });
    }
    
    UIAlertAction* cancelAction = [UIAlertAction actionWithTitle:@"lc.common.cancel".loc style:UIAlertActionStyleCancel handler:^(UIAlertAction * action) {
        window.windowScene = nil;
    }];
    [alert addAction:cancelAction];
    window.rootViewController = [UIViewController new];
    window.windowLevel = UIApplication.sharedApplication.windows.lastObject.windowLevel + 1;
    window.windowScene = (id)UIApplication.sharedApplication.connectedScenes.anyObject;
    [window makeKeyAndVisible];
    [window.rootViewController presentViewController:alert animated:YES completion:nil];
    objc_setAssociatedObject(alert, @"window", window, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

void LCShowAlert(NSString* message) {
    UIWindow *window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"LiveContainer" message:message preferredStyle:UIAlertControllerStyleAlert];
    UIAlertAction* okAction = [UIAlertAction actionWithTitle:@"lc.common.ok".loc style:UIAlertActionStyleDefault handler:^(UIAlertAction * action) {
        window.windowScene = nil;
    }];
    [alert addAction:okAction];
    window.rootViewController = [UIViewController new];
    window.windowLevel = UIApplication.sharedApplication.windows.lastObject.windowLevel + 1;
    window.windowScene = (id)UIApplication.sharedApplication.connectedScenes.anyObject;
    [window makeKeyAndVisible];
    [window.rootViewController presentViewController:alert animated:YES completion:nil];
    objc_setAssociatedObject(alert, @"window", window, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

void LCShowAppNotFoundAlert(NSString* bundleId) {
    LCShowAlert([@"lc.guestTweak.error.bundleNotFound %@" localizeWithFormat: bundleId]);
}

void openUniversalLink(NSString* decodedUrl) {
    NSURL* urlToOpen = [NSURL URLWithString: decodedUrl];
    if(![urlToOpen.scheme isEqualToString:@"https"] && ![urlToOpen.scheme isEqualToString:@"http"]) {
        NSData *data = [decodedUrl dataUsingEncoding:NSUTF8StringEncoding];
        NSString *encodedUrl = [data base64EncodedStringWithOptions:0];
        
        NSString* finalUrl = [NSString stringWithFormat:@"%@://open-url?url=%@", NSUserDefaults.lcAppUrlScheme, encodedUrl];
        NSURL* url = [NSURL URLWithString: finalUrl];
        
        [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:nil];
        return;
    }
    
    UIActivityContinuationManager* uacm = [[UIApplication sharedApplication] _getActivityContinuationManager];
    NSUserActivity* activity = [[NSUserActivity alloc] initWithActivityType:NSUserActivityTypeBrowsingWeb];
    activity.webpageURL = urlToOpen;
    NSDictionary* dict = @{
        @"UIApplicationLaunchOptionsUserActivityKey": activity,
        @"UICanvasConnectionOptionsUserActivityKey": activity,
        @"UIApplicationLaunchOptionsUserActivityIdentifierKey": NSUUID.UUID.UUIDString,
        @"UINSUserActivitySourceApplicationKey": @"com.apple.mobilesafari",
        @"UIApplicationLaunchOptionsUserActivityTypeKey": NSUserActivityTypeBrowsingWeb,
        @"_UISceneConnectionOptionsUserActivityTypeKey": NSUserActivityTypeBrowsingWeb,
        @"_UISceneConnectionOptionsUserActivityKey": activity,
        @"UICanvasConnectionOptionsUserActivityTypeKey": NSUserActivityTypeBrowsingWeb
    };
    
    [uacm handleActivityContinuation:dict isSuspended:nil];
}

void LCOpenWebPage(NSString* webPageUrlString, NSString* originalUrl) {
    if ([NSUserDefaults.lcUserDefaults boolForKey:@"LCOpenWebPageWithoutAsking"]) {
        openUniversalLink(webPageUrlString);
        return;
    }
    
    NSURLComponents* newUrlComp = [NSURLComponents componentsWithString:originalUrl];
    __block BOOL anotherLCLaunched = false;
    forEachInstalledNotCurrentLC(YES, ^(NSString * scheme, BOOL* isBreak) {
        newUrlComp.scheme = scheme;
        [UIApplication.sharedApplication openURL:newUrlComp.URL options:@{} completionHandler:nil];
        *isBreak = YES;
        anotherLCLaunched = YES;
        return;
    });
    if(anotherLCLaunched) {
        return;
    }
    
    NSString *message = @"lc.guestTweak.openWebPageTip".loc;
    UIWindow *window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"LiveContainer" message:message preferredStyle:UIAlertControllerStyleAlert];
    UIAlertAction* okAction = [UIAlertAction actionWithTitle:@"lc.common.ok".loc style:UIAlertActionStyleDefault handler:^(UIAlertAction * action) {
        [NSClassFromString(@"LCSharedUtils") setWebPageUrlForNextLaunch:webPageUrlString];
        [NSClassFromString(@"LCSharedUtils") launchToGuestAppWithClassicMode:0];
    }];
    [alert addAction:okAction];
    UIAlertAction* openNowAction = [UIAlertAction actionWithTitle:@"lc.guestTweak.openInCurrentApp".loc style:UIAlertActionStyleDefault handler:^(UIAlertAction * action) {
        openUniversalLink(webPageUrlString);
        window.windowScene = nil;
    }];

    forEachInstalledNotCurrentLC(NO, ^(NSString * scheme, BOOL* isBreak) {
        UIAlertAction* openlc2Action = [UIAlertAction actionWithTitle:[@"lc.guestTweak.openInLc %@" localizeWithFormat:scheme] style:UIAlertActionStyleDefault handler:^(UIAlertAction * action) {
            newUrlComp.scheme = scheme;
            [UIApplication.sharedApplication openURL:newUrlComp.URL options:@{} completionHandler:nil];
            window.windowScene = nil;
        }];
        [alert addAction:openlc2Action];
    });
    
    [alert addAction:openNowAction];
    UIAlertAction* cancelAction = [UIAlertAction actionWithTitle:@"lc.common.cancel".loc style:UIAlertActionStyleCancel handler:^(UIAlertAction * action) {
        window.windowScene = nil;
    }];
    [alert addAction:cancelAction];
    window.rootViewController = [UIViewController new];
    window.windowLevel = UIApplication.sharedApplication.windows.lastObject.windowLevel + 1;
    window.windowScene = (id)UIApplication.sharedApplication.connectedScenes.anyObject;
    [window makeKeyAndVisible];
    [window.rootViewController presentViewController:alert animated:YES completion:nil];
    objc_setAssociatedObject(alert, @"window", window, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    

}

void LCOpenSideStoreURL(NSURL* sidestoreUrl) {
    if ([NSUserDefaults.lcUserDefaults boolForKey:@"LCSwitchAppWithoutAsking"]) {
        [NSUserDefaults.lcUserDefaults setObject:sidestoreUrl.absoluteString forKey:@"launchAppUrlScheme"];
        [NSUserDefaults.lcUserDefaults setObject:@"builtinSideStore" forKey:@"selected"];
        [NSClassFromString(@"LCSharedUtils") launchToGuestAppWithClassicMode:0];
    }
    NSString *message = [@"lc.guestTweak.appSwitchTip %@" localizeWithFormat:@"SideStore"];
    UIWindow *window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"LiveContainer" message:message preferredStyle:UIAlertControllerStyleAlert];
    UIAlertAction* okAction = [UIAlertAction actionWithTitle:@"lc.common.ok".loc style:UIAlertActionStyleDefault handler:^(UIAlertAction * action) {
        [NSUserDefaults.lcUserDefaults setObject:sidestoreUrl.absoluteString forKey:@"launchAppUrlScheme"];
        [NSUserDefaults.lcUserDefaults setObject:@"builtinSideStore" forKey:@"selected"];
        [NSClassFromString(@"LCSharedUtils") launchToGuestAppWithClassicMode:0];
    }];
    [alert addAction:okAction];
    
    UIAlertAction* cancelAction = [UIAlertAction actionWithTitle:@"lc.common.cancel".loc style:UIAlertActionStyleCancel handler:^(UIAlertAction * action) {
        window.windowScene = nil;
    }];
    [alert addAction:cancelAction];
    window.rootViewController = [UIViewController new];
    window.windowLevel = UIApplication.sharedApplication.windows.lastObject.windowLevel + 1;
    window.windowScene = (id)UIApplication.sharedApplication.connectedScenes.anyObject;
    [window makeKeyAndVisible];
    [window.rootViewController presentViewController:alert animated:YES completion:nil];
    objc_setAssociatedObject(alert, @"window", window, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    
}

void authenticateUser(void (^completion)(BOOL success, NSError *error)) {
    LAContext *context = [[LAContext alloc] init];
    NSError *error = nil;

    if ([context canEvaluatePolicy:LAPolicyDeviceOwnerAuthentication error:&error]) {
        NSString *reason = @"lc.utils.requireAuthentication".loc;

        // Evaluate the policy for both biometric and passcode authentication
        [context evaluatePolicy:LAPolicyDeviceOwnerAuthentication
                localizedReason:reason
                          reply:^(BOOL success, NSError * _Nullable evaluationError) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (success) {
                    completion(YES, nil);
                } else {
                    completion(NO, evaluationError);
                }
            });
        }];
    } else {
        dispatch_async(dispatch_get_main_queue(), ^{
            if([error code] == LAErrorPasscodeNotSet) {
                completion(YES, nil);
            } else {
                completion(NO, error);
            }
        });
    }
}

void handleLiveContainerLaunch(NSString* bundleName, NSString* containerFolderName, NSURL* url) {
    // check if there are other LCs is running this app
        NSString* runningLC = [NSClassFromString(@"LCSharedUtils") getContainerUsingLCSchemeWithFolderName:containerFolderName];
        // the app is running in an lc, that lc is not me, also is not my avatar
        if(runningLC) {
            if([runningLC hasSuffix:@"liveprocess"]) {
                runningLC = runningLC.stringByDeletingPathExtension;
            }
            NSString* urlStr = [NSString stringWithFormat:@"%@://livecontainer-launch?bundle-name=%@&container-folder-name=%@", runningLC, bundleName, containerFolderName];
            [UIApplication.sharedApplication openURL:[NSURL URLWithString:urlStr] options:@{} completionHandler:nil];
            return;
        }
        
        bool isSharedApp = false;
        NSBundle* bundle = [NSClassFromString(@"LCSharedUtils") findBundleWithBundleId: bundleName isSharedAppOut:&isSharedApp];
        NSDictionary* lcAppInfo;
        if(bundle) {
            lcAppInfo = [NSDictionary dictionaryWithContentsOfURL:[bundle URLForResource:@"LCAppInfo" withExtension:@"plist"]];
        }
        
        if(!bundle || ([lcAppInfo[@"isHidden"] boolValue] && [NSUserDefaults.lcSharedDefaults boolForKey:@"LCStrictHiding"])) {
            LCShowAppNotFoundAlert(bundleName);
        } else if ([lcAppInfo[@"isLocked"] boolValue]) {
            // need authentication
            authenticateUser(^(BOOL success, NSError *error) {
                if (success) {
                    LCShowSwitchAppConfirmation(url, bundleName, isSharedApp);
                } else {
                    if ([error.domain isEqualToString:LAErrorDomain]) {
                        if (error.code != LAErrorUserCancel) {
                            NSLog(@"[LC] Authentication Error: %@", error.localizedDescription);
                        }
                    } else {
                        NSLog(@"[LC] Authentication Error: %@", error.localizedDescription);
                    }
                }
            });
        } else {
            LCShowSwitchAppConfirmation(url, bundleName, isSharedApp);
        }
    
}

BOOL shouldRedirectOpenURLToHost(NSURL* url) {
    NSUserDefaults *ud = NSUserDefaults.lcSharedDefaults;
    return NSUserDefaults.isLiveProcess &&
    [ud boolForKey:@"LCRedirectURLToHost"] &&
    [[ud arrayForKey:@"LCGuestURLSchemes"] containsObject:url.scheme];
}
BOOL canAppOpenItself(NSURL* url) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSDictionary *infoDictionary = [[NSBundle mainBundle] infoDictionary];
        NSArray *urlTypes = [infoDictionary objectForKey:@"CFBundleURLTypes"];
        LCSupportedUrlSchemes = [[NSMutableArray alloc] init];
        for (NSDictionary *urlType in urlTypes) {
            NSArray *schemes = [urlType objectForKey:@"CFBundleURLSchemes"];
            for(NSString* scheme in schemes) {
                [LCSupportedUrlSchemes addObject:[scheme lowercaseString]];
            }
        }
    });
    return [LCSupportedUrlSchemes containsObject:[url.scheme lowercaseString]];
}

typedef NS_ENUM(NSInteger, LCControlAppURLHandling) {
    LCControlAppURLHandlingPassThrough,
    LCControlAppURLHandlingReplaceURL,
    LCControlAppURLHandlingStop,
};

static NSString* LCDecodedURLStringFromControlURL(NSURL *url) {
    NSURLComponents* lcUrl = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
    NSString* realUrlEncoded = nil;
    for(NSURLQueryItem *queryItem in lcUrl.queryItems) {
        if([queryItem.name isEqualToString:@"url"]) {
            realUrlEncoded = queryItem.value;
            break;
        }
    }
    if(!realUrlEncoded) {
        realUrlEncoded = lcUrl.queryItems.firstObject.value;
    }
    if(!realUrlEncoded) {
        return nil;
    }
    NSData *decodedData = [[NSData alloc] initWithBase64EncodedString:realUrlEncoded options:0];
    if(!decodedData) {
        return nil;
    }
    return [[NSString alloc] initWithData:decodedData encoding:NSUTF8StringEncoding];
}

static void resolveLaunchExtensionFileBookmark(void) {
    NSData* bookmarkData = [NSUserDefaults.lcSharedDefaults dataForKey:@"LCLaunchExtensionFileBookmark"];
    if(!bookmarkData) {
        return;
    }
    BOOL isStale = NO;
    NSError* error = nil;
    NSURL* resolvedURL = [NSURL URLByResolvingBookmarkData:bookmarkData
                                                   options:(1UL << 10)
                                             relativeToURL:nil
                                       bookmarkDataIsStale:&isStale
                                                     error:&error];
    if(!resolvedURL) {
        NSLog(@"[LC] Failed to resolve shared file bookmark: %@", error.localizedDescription);
    }
    [NSUserDefaults.lcSharedDefaults removeObjectForKey:@"LCLaunchExtensionFileBookmark"];
    
}

static LCControlAppURLHandling LCHandleControlAppURL(NSURL *url, NSString** modifiedURLStr) {
    if(!url || url.isFileURL) {
        return LCControlAppURLHandlingPassThrough;
    }

    // pass through sidestore urls
    if(NSUserDefaults.isSideStore && ![url.scheme isEqualToString:@"livecontainer"]) {
        return LCControlAppURLHandlingPassThrough;
    }

    if([url.scheme isEqualToString:@"sidestore"]) {
        LCOpenSideStoreURL(url);
        return LCControlAppURLHandlingStop;
    }

    NSString *lcScheme = NSUserDefaults.lcAppUrlScheme;
    // pass through any url that should not be handled by current lc
    if(![url.scheme isEqualToString:lcScheme]) {
        return LCControlAppURLHandlingPassThrough;
    }
    NSString* urlHost = url.host;
    
    if([urlHost isEqualToString:@"livecontainer-relaunch"]) {
        return LCControlAppURLHandlingStop;
    }
    
    if([urlHost isEqualToString:@"livecontainer-launch"]) {
        // If it's not current app, then switch, otherwise check if we need to open the url
        NSString* bundleName = nil;
        NSString* openUrl = nil;
        NSString* containerFolderName = nil;
        NSURLComponents* components = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
        for (NSURLQueryItem* queryItem in components.queryItems) {
            if ([queryItem.name isEqualToString:@"bundle-name"]) {
                bundleName = queryItem.value;
            } else if ([queryItem.name isEqualToString:@"open-url"]) {
                NSData *decodedData = [[NSData alloc] initWithBase64EncodedString:queryItem.value options:0];
                openUrl = [[NSString alloc] initWithData:decodedData encoding:NSUTF8StringEncoding];
            } else if ([queryItem.name isEqualToString:@"container-folder-name"]) {
                containerFolderName = queryItem.value;
            }
        }
        
        // launch to LiveContainerUI
        if([bundleName isEqualToString:@"ui"]) {
            LCShowSwitchAppConfirmation(url, @"LiveContainer", false);
            return LCControlAppURLHandlingStop;
        }
        
        NSString* containerId = [NSString stringWithUTF8String:getenv("HOME")].lastPathComponent;
        if(!containerFolderName) {
            containerFolderName = findDefaultContainerWithBundleId(bundleName);
        }
        // current bundlename and container folder name matches OR sidestore is running and we are launching builtinSideStore
        if (([bundleName isEqualToString:NSBundle.mainBundle.bundlePath.lastPathComponent] && [containerId isEqualToString:containerFolderName]) ||
            (NSUserDefaults.isSideStore && [bundleName isEqualToString:@"builtinSideStore"])) {
            if(openUrl) {
                if([openUrl hasPrefix:@"file:"]) {
                    resolveLaunchExtensionFileBookmark();
                    *modifiedURLStr = openUrl;
                    return LCControlAppURLHandlingReplaceURL;
                } else {
                    openUniversalLink(openUrl);
                }
            }
        } else {
            if([bundleName isEqualToString:@"builtinSideStore"]) {
                LCShowSwitchAppConfirmation(url, @"SideStore", NO);
                return LCControlAppURLHandlingStop;
            }
            handleLiveContainerLaunch(bundleName, containerFolderName, url);
        }
        
        return LCControlAppURLHandlingStop;
    }

    if([urlHost isEqualToString:@"open-web-page"]) {
        NSString *decodedUrl = LCDecodedURLStringFromControlURL(url);
        if(decodedUrl) {
            LCOpenWebPage(decodedUrl, url.absoluteString);
        }
        return LCControlAppURLHandlingStop;
    }

    if([urlHost isEqualToString:@"open-url"]) {
        NSString *decodedUrl = LCDecodedURLStringFromControlURL(url);
        if(!decodedUrl) {
            return LCControlAppURLHandlingStop;
        }
        // it's a Universal link, let's call -[UIActivityContinuationManager handleActivityContinuation:isSuspended:]
        if([decodedUrl hasPrefix:@"https"]) {
            openUniversalLink(decodedUrl);
            return LCControlAppURLHandlingStop;
        }
        *modifiedURLStr = decodedUrl;
        return LCControlAppURLHandlingReplaceURL;
    }

    if([urlHost isEqualToString:@"install"]) {
        LCShowAlert(@"lc.guestTweak.restartToInstall".loc);
        return LCControlAppURLHandlingStop;
    }

    return LCControlAppURLHandlingStop;
}

// Handler for AppDelegate
@implementation UIApplication(LiveContainerHook)
- (void)hook__applicationOpenURLAction:(id)action payload:(NSDictionary *)payload origin:(id)origin {
    NSURL *url = [NSURL URLWithString:payload[UIApplicationLaunchOptionsURLKey]];
    NSString* replacementURLString = nil;
    LCControlAppURLHandling decision = LCHandleControlAppURL(url, &replacementURLString);
    if(decision == LCControlAppURLHandlingStop) {
        return;
    }
    if(decision == LCControlAppURLHandlingReplaceURL) {
        NSMutableDictionary* newPayload = [payload mutableCopy];
        newPayload[UIApplicationLaunchOptionsURLKey] = replacementURLString;
        [self hook__applicationOpenURLAction:action payload:newPayload origin:origin];
        return;
    }
    [self hook__applicationOpenURLAction:action payload:payload origin:origin];
}

- (void)hook__connectUISceneFromFBSScene:(id)scene transitionContext:(UIApplicationSceneTransitionContext*)context {
#if !TARGET_OS_MACCATALYST
    NSString* decodedUrlStr = launchURLProcessed ? nil : NSUserDefaults.lcLaunchURL;
    launchURLProcessed = YES;
    NSString* urlStr;
        
    if(!decodedUrlStr && context.payload && (urlStr = context.payload[UIApplicationLaunchOptionsURLKey])) {
        do {
            if([urlStr hasPrefix:[NSString stringWithFormat: @"%@://open-url", NSUserDefaults.lcAppUrlScheme]]) {
                NSURLComponents* lcUrl = [NSURLComponents componentsWithString:urlStr];
                NSString* realUrlEncoded = lcUrl.queryItems[0].value;
                if(!realUrlEncoded) break;
                // Convert the base64 encoded url into String
                NSData *decodedData = [[NSData alloc] initWithBase64EncodedString:realUrlEncoded options:0];
                decodedUrlStr = [[NSString alloc] initWithData:decodedData encoding:NSUTF8StringEncoding];
            } else if([urlStr hasPrefix:NSUserDefaults.lcAppUrlScheme]) {
                context.payload = nil;
                context.actions = nil;
            }
        } while (0);
    }
    
    do {
        if(!decodedUrlStr) break;
        NSURL* decodedUrl = [NSURL URLWithString:decodedUrlStr];
        if(decodedUrl.isFileURL) {
            resolveLaunchExtensionFileBookmark();
        }
        
        NSMutableDictionary* newDict = [context.payload mutableCopy];
        if(!newDict) newDict = [NSMutableDictionary new];
        newDict[UIApplicationLaunchOptionsURLKey] = decodedUrlStr;
        context.payload = newDict;
        
        
        UIOpenURLAction *urlAction = nil;
        for (id obj in context.actions.allObjects) {
            if ([obj isKindOfClass:UIOpenURLAction.class]) {
                urlAction = obj;
                break;
            }
        }
        
        NSMutableSet *newActions = context.actions.mutableCopy;
        if(newActions && urlAction) {
            [newActions removeObject:urlAction];
        }
        if(!newActions) newActions = [NSMutableSet new];
        
        UIOpenURLAction *newUrlAction = [[UIOpenURLAction alloc] initWithURL:decodedUrl];
        [newActions addObject:newUrlAction];
        context.actions = newActions;
        
    } while(0);
    
#endif
    [self hook__connectUISceneFromFBSScene:scene transitionContext:context];
}

-(BOOL)hook__handleDelegateCallbacksWithOptions:(id)arg1 isSuspended:(BOOL)arg2 restoreState:(BOOL)arg3 {
    BOOL ans = [self hook__handleDelegateCallbacksWithOptions:arg1 isSuspended:arg2 restoreState:arg3];
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
//        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            LSApplicationWorkspace* workspace = [objc_lookUpClass("LSApplicationWorkspace") defaultWorkspace];
            [workspace openApplicationWithBundleID:@"com.apple.springboard"];
            [workspace openApplicationWithBundleID:NSUserDefaults.lcMainBundle.bundleIdentifier];
        });

    });


    return ans;
}

- (void)hook_openURL:(NSURL *)url options:(NSDictionary<NSString *,id> *)options completionHandler:(void (^)(_Bool))completion {
    if(NSUserDefaults.isSideStore && ![url.scheme isEqualToString:@"livecontainer"]) {
        [self hook_openURL:url options:options completionHandler:completion];
        return;
    }
    
    BOOL openSelf = canAppOpenItself(url);
    BOOL redirectToHost = shouldRedirectOpenURLToHost(url);;
    if(openSelf || redirectToHost) {
        NSString* schemeToUse = openSelf ? NSUserDefaults.lcAppUrlScheme : @"livecontainer";
        NSData *data = [url.absoluteString dataUsingEncoding:NSUTF8StringEncoding];
        NSString *encodedUrl = [data base64EncodedStringWithOptions:0];
        NSString* finalUrlStr = [NSString stringWithFormat:@"%@://open-url?url=%@", schemeToUse, encodedUrl];
        NSURL* finalUrl = [NSURL URLWithString:finalUrlStr];
        [self hook_openURL:finalUrl options:options completionHandler:completion];
    } else {
        [self hook_openURL:url options:options completionHandler:completion];
    }
}
- (BOOL)hook_canOpenURL:(NSURL *) url {
    return canAppOpenItself(url) || shouldRedirectOpenURLToHost(url) || [self hook_canOpenURL:url];
}

- (void)hook_setDelegate:(id<UIApplicationDelegate>)delegate {
    LCInstallGuestIntentHandlerIfNeeded(delegate);
    if(![delegate respondsToSelector:@selector(application:configurationForConnectingSceneSession:options:)]) {
        // Fix old apps black screen when UIApplicationSupportsMultipleScenes is YES
        swizzle(UIWindow.class, @selector(makeKeyAndVisible), @selector(hook_makeKeyAndVisible));
        swizzle(UIWindow.class, @selector(makeKeyWindow), @selector(hook_makeKeyWindow));
        swizzle(UIWindow.class, @selector(setHidden:), @selector(hook_setHidden:));
        // Fix apps that do not support UISceneDelegate getting 0 status bar frame
        swizzle(UIApplication.class, @selector(statusBarFrame), @selector(hook_statusBarFrame));
    }
    [self hook_setDelegate:delegate];
}

+ (BOOL)_wantsApplicationBehaviorAsExtension {
    // Fix LiveProcess: Make _UIApplicationWantsExtensionBehavior return NO so delegate code runs in the run loop
    return YES;
}

- (CGRect)hook_statusBarFrame {
    UIStatusBarManager* manager = [(UIWindowScene*)(UIApplication.sharedApplication.connectedScenes.anyObject) statusBarManager];
    if(manager) {
        return manager.statusBarFrame;
    } else {
        return [self hook_statusBarFrame];
    }
}

@end

// Handler for SceneDelegate
@implementation UIScene(LiveContainerHook)
- (void)hook_scene:(id)scene didReceiveActions:(NSSet *)actions fromTransitionContext:(id)context {
    UIOpenURLAction *urlAction = nil;
    for (id obj in actions.allObjects) {
        if ([obj isKindOfClass:UIOpenURLAction.class]) {
            urlAction = obj;
            break;
        }
    }

    if(!urlAction) {
        [self hook_scene:scene didReceiveActions:actions fromTransitionContext:context];
        return;
    }
    NSString* replacementURLString = nil;
    LCControlAppURLHandling decision = LCHandleControlAppURL(urlAction.url, &replacementURLString);
    if(decision == LCControlAppURLHandlingStop) {
        return;
    }
    if(decision == LCControlAppURLHandlingReplaceURL) {
        NSURL* finalURL = [NSURL URLWithString:replacementURLString];
        if(!finalURL) {
            return;
        }
        NSMutableSet *newActions = actions.mutableCopy;
        [newActions removeObject:urlAction];
        UIOpenURLAction *newUrlAction = [[UIOpenURLAction alloc] initWithURL:finalURL];
        [newActions addObject:newUrlAction];
        [self hook_scene:scene didReceiveActions:newActions fromTransitionContext:context];
        return;
    }
    [self hook_scene:scene didReceiveActions:actions fromTransitionContext:context];
}

- (void)hook_openURL:(NSURL *)url options:(UISceneOpenExternalURLOptions *)options completionHandler:(void (^)(BOOL success))completion {
    BOOL openSelf = canAppOpenItself(url);
    BOOL redirectToHost = shouldRedirectOpenURLToHost(url);
    if(openSelf || redirectToHost) {
        NSString* schemeToUse = openSelf ? NSUserDefaults.lcAppUrlScheme : @"livecontainer";
        NSData *data = [url.absoluteString dataUsingEncoding:NSUTF8StringEncoding];
        NSString *encodedUrl = [data base64EncodedStringWithOptions:0];
        NSString* finalUrlStr = [NSString stringWithFormat:@"%@://open-url?url=%@", schemeToUse, encodedUrl];
        NSURL* finalUrl = [NSURL URLWithString:finalUrlStr];
        [self hook_openURL:finalUrl options:options completionHandler:completion];
    } else {
        [self hook_openURL:url options:options completionHandler:completion];
    }
}
@end

@implementation FBSSceneParameters(LiveContainerHook)
- (instancetype)hook_initWithXPCDictionary:(NSDictionary*)dict {

    FBSSceneParameters* ans = [self hook_initWithXPCDictionary:dict];
    UIMutableApplicationSceneSettings* settings = [ans.settings mutableCopy];
    UIMutableApplicationSceneClientSettings* clientSettings = [ans.clientSettings mutableCopy];
    [settings setInterfaceOrientation:LCOrientationLock];
    [clientSettings setInterfaceOrientation:LCOrientationLock];
    ans.settings = settings;
    ans.clientSettings = clientSettings;
    return ans;
}
@end



@implementation UIViewController(LiveContainerHook)

- (UIInterfaceOrientationMask)hook___supportedInterfaceOrientations {
    if(LCOrientationLock == UIInterfaceOrientationLandscapeRight) {
        return UIInterfaceOrientationMaskLandscape;
    } else {
        return UIInterfaceOrientationMaskPortrait;
    }

}

- (BOOL)hook_shouldAutorotateToInterfaceOrientation:(NSInteger)orientation {
    return YES;
}

@end

@implementation UIWindow(hook)
- (void)hook_setAutorotates:(BOOL)autorotates forceUpdateInterfaceOrientation:(BOOL)force {
    [self hook_setAutorotates:YES forceUpdateInterfaceOrientation:YES];
}

- (void)hook_makeKeyAndVisible {
    [self updateWindowScene];
    [self hook_makeKeyAndVisible];
}
- (void)hook_makeKeyWindow {
    [self updateWindowScene];
    [self hook_makeKeyWindow];
}
- (void)hook_resignKeyWindow {
    [self updateWindowScene];
    [self hook_resignKeyWindow];
}
- (void)hook_setHidden:(BOOL)hidden {
    [self updateWindowScene];
    [self hook_setHidden:hidden];
}
- (void)updateWindowScene {
    for(UIWindowScene *windowScene in UIApplication.sharedApplication.connectedScenes) {
        if(!self.windowScene && self.screen == windowScene.screen) {
            self.windowScene = windowScene;
            break;
        }
    }
}
@end
