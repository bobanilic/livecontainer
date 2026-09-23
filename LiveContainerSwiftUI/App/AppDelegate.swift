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

    private static func siriDiag(_ message: String) {
        let formatter = ISO8601DateFormatter()
        let line = "[\(formatter.string(from: Date()))] HOST \(message)"
        var lines = LCUtils.appGroupUserDefault.stringArray(forKey: "LCSiriDiagnosticLog") ?? []
        lines.append(line)
        if lines.count > 250 {
            lines.removeFirst(lines.count - 250)
        }
        LCUtils.appGroupUserDefault.set(lines, forKey: "LCSiriDiagnosticLog")
        NSLog("[LCSiriDiag] %@", message)
    }


    /// Probe whether Siri preserves an explicitly requested provider name anywhere
    /// in the archived INPlayMediaIntent. This does not change routing yet.
    private static func providerProbe(_ intent: INPlayMediaIntent, stage: String) {
        let knownProviders = [
            "spotify", "youtube", "youtube music", "yt music", "ytmusic",
            "deezer", "tidal", "soundcloud", "pandora",
            "apple music", "amazon music"
        ]

        var hits: [String] = []
        if let data = try? NSKeyedArchiver.archivedData(
            withRootObject: intent,
            requiringSecureCoding: true
        ) {
            let bytes = [UInt8](data)
            let lowerPatterns = knownProviders.map { ($0, Array($0.utf8)) }

            for (name, pattern) in lowerPatterns where !pattern.isEmpty {
                if bytes.count >= pattern.count {
                    outer: for i in 0...(bytes.count - pattern.count) {
                        for j in 0..<pattern.count {
                            let b = bytes[i + j]
                            let normalized: UInt8 = (65...90).contains(b) ? b + 32 : b
                            if normalized != pattern[j] {
                                continue outer
                            }
                        }
                        hits.append(name)
                        break
                    }
                }
            }

            siriDiag(
                "providerProbe stage=\(stage) archiveBytes=\(data.count) hits=\(hits)"
            )
        } else {
            siriDiag("providerProbe stage=\(stage) archiveFailed")
        }

        let guests = DataManager.shared.model.apps.map {
            "\($0.displayName)|\($0.bundleIdentifier)"
        }.joined(separator: ", ")
        siriDiag("installedGuests [\(guests)]")
    }

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

        Self.providerProbe(intent, stage: "resolve")
        let search = intent.mediaSearch
        var titleParts = [
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
        titleParts.append(contentsOf: search?.genreNames ?? [])
        titleParts.append(contentsOf: search?.moodNames ?? [])
        titleParts.append(contentsOf: search?.activityNames ?? [])
        let requestedTitle = titleParts.joined(separator: " ")

        let title = requestedTitle.isEmpty ? "Spotify" : requestedTitle
        let mediaType: INMediaItemType = {
            guard let type = search?.mediaType, type != .unknown else {
                return .music
            }
            return type
        }()

        let descriptor = Self.spotifySearchDescriptor(search)
        let identifier: String = {
            guard
                let descriptor,
                let data = try? JSONSerialization.data(withJSONObject: descriptor),
                !data.isEmpty
            else {
                return "livecontainer.spotify"
            }
            return "livecontainer.spotify.query:" + data.base64EncodedString()
        }()

        let item = INMediaItem(
            identifier: identifier,
            title: title,
            type: mediaType,
            artwork: nil
        )

        Self.siriDiag(
            "resolve title=\(title) descriptor=\(descriptor.map { String(describing: $0) } ?? "nil") identifierPrefix=\(identifier.prefix(48))"
        )
        completion(INPlayMediaMediaItemResolutionResult.successes(with: [item]))
    }

    func handle(intent: INPlayMediaIntent, completion: @escaping (INPlayMediaIntentResponse) -> Void) {
        Self.providerProbe(intent, stage: "handle")
        guard let spotify = Self.spotifyGuest() else {
            NSLog("[LCSiri] Spotify guest not found")
            completion(INPlayMediaIntentResponse(code: .failure, userActivity: nil))
            return
        }

        let hasSpecificRequest = Self.hasSpecificMediaRequest(intent)
        let deepLink = hasSpecificRequest ? nil : "spotify:internal:collection:tracks"
        Self.siriDiag(
            "handle specific=\(hasSpecificRequest) mediaSearch=\(String(describing: intent.mediaSearch)) mediaItems=\(String(describing: intent.mediaItems?.map { [$0.title, $0.identifier ?? "nil"] }))"
        )

        if hasSpecificRequest {
            do {
                let archivedIntent = try NSKeyedArchiver.archivedData(
                    withRootObject: intent,
                    requiringSecureCoding: true
                )
                LCUtils.appGroupUserDefault.set(archivedIntent, forKey: "LCSiriPendingPlayMediaIntent")
                LCUtils.appGroupUserDefault.set(Date(), forKey: "LCSiriPendingPlayMediaDate")
                Self.siriDiag("stored pending specific intent bytes=\(archivedIntent.count)")
            } catch {
                Self.siriDiag("archive failed error=\(String(describing: error))")
            }
        }

        NSLog(
            "[LCSiri] Routing PlayMedia intent to %@ specific=%d url=%@",
            spotify.displayName,
            hasSpecificRequest,
            deepLink ?? "(native Spotify intent)"
        )

        // Report acceptance before switching the host process into the guest.
        completion(INPlayMediaIntentResponse(code: .success, userActivity: nil))

        Task { @MainActor in
            do {
                try await spotify.runApp(multitask: false, urlStr: deepLink)
            } catch {
                Self.siriDiag("guest launch failed error=\(String(describing: error))")
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

    private static func spotifySearchDescriptor(_ search: INMediaSearch?) -> [String: Any]? {
        guard let search else { return nil }

        func firstNonEmpty(_ values: [String]?) -> String? {
            values?.first {
                !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
        }

        if let genre = firstNonEmpty(search.genreNames) {
            return ["q": genre, "type": "playlist", "shuffle": true]
        }
        if let mood = firstNonEmpty(search.moodNames) {
            return ["q": mood, "type": "playlist", "shuffle": true]
        }
        if let activity = firstNonEmpty(search.activityNames) {
            return ["q": activity, "type": "playlist", "shuffle": true]
        }

        let media = search.mediaName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let artist = search.artistName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let album = search.albumName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if !media.isEmpty {
            let query = artist.isEmpty ? media : "\(media) \(artist)"
            return ["q": query, "type": "track", "shuffle": false]
        }
        if !album.isEmpty {
            let query = artist.isEmpty ? album : "\(album) \(artist)"
            return ["q": query, "type": "album", "shuffle": false]
        }
        if !artist.isEmpty {
            return ["q": artist, "type": "artist", "shuffle": true]
        }
        return nil
    }

    private static func hasSpecificMediaRequest(_ intent: INPlayMediaIntent) -> Bool {
        if intent.mediaItems?.contains(where: {
            $0.identifier?.hasPrefix("livecontainer.spotify.query:") == true
        }) == true {
            return true
        }

        return spotifySearchDescriptor(intent.mediaSearch) != nil
    }}
