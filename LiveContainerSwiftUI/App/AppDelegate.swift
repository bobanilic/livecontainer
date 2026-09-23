import UIKit
import SwiftUI
import Intents

@objc class AppDelegate: UIResponder, UIApplicationDelegate {
        
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? ) -> Bool {
        application.shortcutItems = nil
        UserDefaults.standard.removeObject(forKey: "LCNeedToAcquireJIT")
        
        NotificationCenter.default.addObserver(forName: UIApplication.willTerminateNotification, object: nil, queue: .main) { _ in
            // Fix launching app if user opens JIT waiting dialog and kills the app. Won't trigger normally.
            if DataManager.shared.model.isJITModalOpen && !UserDefaults.standard.bool(forKey: "LCKeepSelectedWhenQuit"){
                UserDefaults.standard.removeObject(forKey: "selected")
                UserDefaults.standard.removeObject(forKey: "selectedContainer")
            }
        }
        
        // allow new scene pop up as a new fullscreen window
        method_exchangeImplementations(
            class_getInstanceMethod(UIApplication.self, #selector(UIApplication.requestSceneSessionActivation(_ :userActivity:options:errorHandler:)))!,
            class_getInstanceMethod(UIApplication.self, #selector(UIApplication.hook_requestSceneSessionActivation(_:userActivity:options:errorHandler:)))!)

        // remove symbol caches if user upgraded iOS
        if let lastIOSBuildVersion = LCUtils.appGroupUserDefault.string(forKey: "LCLastIOSBuildVersion"),
           let currentVersion = UIDevice.current.buildVersion,
           lastIOSBuildVersion == currentVersion {
            
        } else {
            LCUtils.appGroupUserDefault.removeObject(forKey: "symbolOffsetCache")
            LCUtils.appGroupUserDefault.setValue(UIDevice.current.buildVersion, forKey: "LCLastIOSBuildVersion")
        }
        
        return true
    }
    
    func application(_ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession, options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
        configuration.delegateClass = SceneDelegate.self
        return configuration
    }
    
    func application(_ application: UIApplication, handlerFor intent: INIntent) -> Any? {
        switch intent {
        case is ViewAppIntent: return ViewAppIntentHandler()
        case is INPlayMediaIntent: return SiriMediaIntentHandler()
        default:
            return nil
        }
    }
}

class SceneDelegate: NSObject, UIWindowSceneDelegate, ObservableObject { // Make SceneDelegate conform ObservableObject
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        self.window = (scene as? UIWindowScene)?.keyWindow
    }
    
}


@objc extension UIApplication {
    
    func hook_requestSceneSessionActivation(
        _ sceneSession: UISceneSession?,
        userActivity: NSUserActivity?,
        options: UIScene.ActivationRequestOptions?,
        errorHandler: ((any Error) -> Void)? = nil
    ) {
        var newOptions = options
        if newOptions == nil {
            newOptions = UIScene.ActivationRequestOptions()
        }
        newOptions!._setRequestFullscreen(UIScreen.main.bounds == self.keyWindow!.bounds)
        self.hook_requestSceneSessionActivation(sceneSession, userActivity: userActivity, options: newOptions, errorHandler: errorHandler)
    }
    
}

public class ViewAppIntentHandler: NSObject, ViewAppIntentHandling
{
    public func provideAppOptionsCollection(for intent: ViewAppIntent, with completion: @escaping (INObjectCollection<App>?, Error?) -> Void)
    {
        completion(INObjectCollection(items:[]), nil)
    }
}


/// Proof-of-concept Siri media router.
///
/// iOS sees LiveContainer as the media-capable host. The first experiment routes a
/// generic Siri music request to a Spotify guest installed in LiveContainer.
/// Provider aliases and additional guest adapters are deliberately left for the
/// next phase, after verifying that SiriKit registration survives sideload signing.
final class SiriMediaIntentHandler: NSObject, INPlayMediaIntentHandling {
    private static let spotifyBundleIdentifiers: Set<String> = [
        "com.spotify.client"
    ]

    /// SiriKit requires media-item resolution for INPlayMediaIntent.
    /// Without this method Siri accepts the permission/capability registration,
    /// but the request can terminate with a generic "there's a problem" response
    /// before the handler is allowed to launch the guest app.
    func resolveMediaItems(
        for intent: INPlayMediaIntent,
        with completion: @escaping ([INPlayMediaMediaItemResolutionResult]) -> Void
    ) {
        guard Self.spotifyGuest() != nil else {
            NSLog("[LCSiri] resolveMediaItems: Spotify guest not found")
            completion([
                INPlayMediaMediaItemResolutionResult.unsupported(forReason: .serviceUnavailable)
            ])
            return
        }

        let search = intent.mediaSearch
        let requestedTitle = [
            search?.mediaName,
            search?.artistName,
            search?.albumName
        ]
        .compactMap { value -> String? in
            guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return nil
            }
            return value
        }
        .joined(separator: " ")

        let title = requestedTitle.isEmpty ? "Spotify" : requestedTitle
        let mediaType: INMediaItemType = {
            guard let type = search?.mediaType, type != .unknown else {
                return .music
            }
            return type
        }()

        let item = INMediaItem(
            identifier: "livecontainer.spotify",
            title: title,
            type: mediaType,
            artwork: nil
        )

        NSLog("[LCSiri] resolveMediaItems: resolved %@", title)
        completion(INPlayMediaMediaItemResolutionResult.successes(with: [item]))
    }

    func handle(intent: INPlayMediaIntent, completion: @escaping (INPlayMediaIntentResponse) -> Void) {
        guard let spotify = Self.spotifyGuest() else {
            NSLog("[LCSiri] Spotify guest not found")
            completion(INPlayMediaIntentResponse(code: .failure, userActivity: nil))
            return
        }

        let deepLink = Self.spotifyDeepLink(for: intent)
        NSLog("[LCSiri] Routing PlayMedia intent to %@ with URL %@", spotify.displayName, deepLink)

        // Report acceptance before switching the host process into the guest.
        // LiveContainer's normal non-multitask launch path restarts/kills the host,
        // so waiting for runApp() to return could prevent Siri from receiving a response.
        completion(INPlayMediaIntentResponse(code: .success, userActivity: nil))

        Task { @MainActor in
            do {
                try await spotify.runApp(multitask: false, urlStr: deepLink)
            } catch {
                NSLog("[LCSiri] Failed to launch Spotify guest: %@", String(describing: error))
            }
        }
    }

    private static func spotifyGuest() -> LCAppModel? {
        let apps = DataManager.shared.model.apps
        return apps.first {
            spotifyBundleIdentifiers.contains($0.bundleIdentifier.lowercased())
        } ?? apps.first {
            $0.displayName.localizedCaseInsensitiveContains("spotify")
        }
    }

    private static func spotifyDeepLink(for intent: INPlayMediaIntent) -> String {
        if let search = intent.mediaSearch {
            let terms: [String] = [
                search.mediaName,
                search.artistName,
                search.albumName
            ].compactMap { value in
                guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    return nil
                }
                return value
            }

            let descriptiveTerms = terms
                + (search.genreNames ?? [])
                + (search.moodNames ?? [])

            if !descriptiveTerms.isEmpty {
                let query = descriptiveTerms.joined(separator: " ")
                let allowed = CharacterSet.urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&?=#"))
                let encoded = query.addingPercentEncoding(withAllowedCharacters: allowed) ?? query
                return "spotify:search:\(encoded)"
            }
        }

        // Generic requests such as "play some music" land on the user's library.
        return "spotify:internal:collection:tracks"
    }
}
