import UIKit
import SwiftUI
import Intents
import AppIntents

@objc class AppDelegate: UIResponder, UIApplicationDelegate {
        
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? ) -> Bool {
        application.shortcutItems = nil
        UserDefaults.standard.removeObject(forKey: "LCNeedToAcquireJIT")
        if #available(iOS 16.0, *) {
            LCUniversalMediaShortcuts.updateAppShortcutParameters()
        }
        
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

    private static func universalDescriptor(
        provider: LCUniversalMediaProvider,
        search: INMediaSearch?
    ) -> [String: Any] {
        [
            "provider": provider.rawValue,
            "query": LCUniversalMediaRouter.query(from: search) ?? ""
        ]
    }

    private static func universalDescriptor(from intent: INPlayMediaIntent) -> [String: Any]? {
        let prefix = "livecontainer.universal:"
        for item in intent.mediaItems ?? [] {
            guard let identifier = item.identifier, identifier.hasPrefix(prefix) else { continue }
            let encoded = String(identifier.dropFirst(prefix.count))
            guard
                let data = Data(base64Encoded: encoded),
                let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else {
                continue
            }
            return object
        }
        return nil
    }

    /// SiriKit requires media-item resolution for INPlayMediaIntent.
    /// Without this method Siri accepts the permission/capability registration,
    /// but the request can terminate with a generic "there's a problem" response
    /// before the handler is allowed to launch the guest app.
    func resolveMediaItems(
        for intent: INPlayMediaIntent,
        with completion: @escaping ([INPlayMediaMediaItemResolutionResult]) -> Void
    ) {
        let selectedProvider = LCUniversalMediaRouter.selectedProvider
        if selectedProvider == .spotify, Self.spotifyGuest() == nil {
            NSLog("[LCSiri] resolveMediaItems: Spotify guest not found")
            completion([
                INPlayMediaMediaItemResolutionResult.unsupported(forReason: .serviceUnavailable)
            ])
            return
        }

        Self.providerProbe(intent, stage: "resolve")
        Self.siriDiag("resolve selectedProvider=\(selectedProvider.displayName)")
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

        let title = requestedTitle.isEmpty ? selectedProvider.displayName : requestedTitle
        let mediaType: INMediaItemType = {
            guard let type = search?.mediaType, type != .unknown else {
                return .music
            }
            return type
        }()

        let identifier: String
        let descriptorDescription: String

        if selectedProvider == .spotify {
            let descriptor = Self.spotifySearchDescriptor(search)
            descriptorDescription = descriptor.map { String(describing: $0) } ?? "nil"
            identifier = {
                guard
                    let descriptor,
                    let data = try? JSONSerialization.data(withJSONObject: descriptor),
                    !data.isEmpty
                else {
                    return "livecontainer.spotify"
                }
                return "livecontainer.spotify.query:" + data.base64EncodedString()
            }()
        } else {
            let descriptor = Self.universalDescriptor(
                provider: selectedProvider,
                search: search
            )
            descriptorDescription = String(describing: descriptor)
            let data = try? JSONSerialization.data(withJSONObject: descriptor)
            identifier = "livecontainer.universal:" + (data?.base64EncodedString() ?? "")
        }

        let item = INMediaItem(
            identifier: identifier,
            title: title,
            type: mediaType,
            artwork: nil
        )

        Self.siriDiag(
            "resolve title=\(title) descriptor=\(descriptorDescription) identifierPrefix=\(identifier.prefix(48))"
        )
        completion(INPlayMediaMediaItemResolutionResult.successes(with: [item]))
    }

    func handle(intent: INPlayMediaIntent, completion: @escaping (INPlayMediaIntentResponse) -> Void) {
        Self.providerProbe(intent, stage: "handle")

        let preserved = Self.universalDescriptor(from: intent)
        let provider: LCUniversalMediaProvider = {
            if
                let raw = preserved?["provider"] as? String,
                let decoded = LCUniversalMediaProvider(rawValue: raw)
            {
                return decoded
            }
            return LCUniversalMediaRouter.selectedProvider
        }()

        if provider != .spotify {
            let preservedQuery = (preserved?["query"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let query = (preservedQuery?.isEmpty == false)
                ? preservedQuery
                : LCUniversalMediaRouter.query(from: intent.mediaSearch)

            Self.siriDiag(
                "handle universal provider=\(provider.displayName) query=\(query ?? "<generic>")"
            )
            completion(INPlayMediaIntentResponse(code: .success, userActivity: nil))

            Task { @MainActor in
                do {
                    try await LCUniversalMediaRouter.route(provider: provider, query: query)
                } catch {
                    Self.siriDiag(
                        "universal guest launch failed provider=\(provider.displayName) error=\(String(describing: error))"
                    )
                }
            }
            return
        }

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


enum LCUniversalMediaProvider: String {
    case spotify
    case youtube
    case youtubeMusic
    case deezer

    var displayName: String {
        switch self {
        case .spotify: return "Spotify"
        case .youtube: return "YouTube"
        case .youtubeMusic: return "YouTube Music"
        case .deezer: return "Deezer"
        }
    }

    var bundleIdentifiers: Set<String> {
        switch self {
        case .spotify:
            return ["com.spotify.client"]
        case .youtube:
            return ["com.google.ios.youtube"]
        case .youtubeMusic:
            return ["com.google.ios.youtubemusic"]
        case .deezer:
            return ["com.deezer.deezer"]
        }
    }

    var nameAliases: [String] {
        switch self {
        case .spotify: return ["spotify"]
        case .youtube: return ["youtube"]
        case .youtubeMusic: return ["youtube music", "yt music", "ytmusic"]
        case .deezer: return ["deezer"]
        }
    }
}

enum LCUniversalMediaRouter {
    static let selectedProviderKey = "LCUniversalSelectedMediaProvider"

    static var selectedProvider: LCUniversalMediaProvider {
        get {
            guard
                let raw = LCUtils.appGroupUserDefault.string(forKey: selectedProviderKey),
                let provider = LCUniversalMediaProvider(rawValue: raw)
            else {
                return .spotify
            }
            return provider
        }
        set {
            LCUtils.appGroupUserDefault.set(newValue.rawValue, forKey: selectedProviderKey)
            diag("selected provider=\(newValue.displayName)")
        }
    }

    static func select(provider: LCUniversalMediaProvider) {
        selectedProvider = provider
    }

    static func query(from search: INMediaSearch?) -> String? {
        guard let search else { return nil }

        func clean(_ value: String?) -> String? {
            guard let value else { return nil }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }

        if let media = clean(search.mediaName) {
            if let artist = clean(search.artistName) {
                return "\(media) \(artist)"
            }
            return media
        }
        if let album = clean(search.albumName) {
            if let artist = clean(search.artistName) {
                return "\(album) \(artist)"
            }
            return album
        }
        if let artist = clean(search.artistName) {
            return artist
        }
        if let genre = search.genreNames?.first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            return genre
        }
        if let mood = search.moodNames?.first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            return mood
        }
        if let activity = search.activityNames?.first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            return activity
        }
        return nil
    }

    private static let genreWords: Set<String> = [
        "jazz", "rock", "pop", "house", "techno", "trance", "classical",
        "hip hop", "hip-hop", "rap", "metal", "blues", "country", "reggae",
        "r&b", "soul", "funk", "ambient", "edm", "dance"
    ]

    @MainActor
    static func route(provider: LCUniversalMediaProvider, query: String?) async throws {
        let normalizedQuery = query?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "something", with: "", options: [.caseInsensitive])
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let guest = findGuest(provider) else {
            diag("universal provider=\(provider.displayName) unavailable")
            throw NSError(
                domain: "LiveContainer.UniversalMediaRouter",
                code: 404,
                userInfo: [NSLocalizedDescriptionKey: "\(provider.displayName) is not installed in LiveContainer."]
            )
        }

        diag(
            "universal route provider=\(provider.displayName) guest=\(guest.displayName)|\(guest.bundleIdentifier) query=\(normalizedQuery ?? "<generic>")"
        )

        switch provider {
        case .spotify:
            try await routeSpotify(guest: guest, query: normalizedQuery)

        case .youtube:
            try await routeYouTube(
                guest: guest,
                query: normalizedQuery,
                music: false
            )

        case .youtubeMusic:
            try await routeYouTube(
                guest: guest,
                query: normalizedQuery,
                music: true
            )

        case .deezer:
            let launchURL: String?
            if let q = normalizedQuery, !q.isEmpty {
                let encoded = q.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? q
                launchURL = "deezer://search?q=\(encoded)"
            } else {
                launchURL = rootSchemeURL(for: guest, preferred: ["deezer"])
            }
            try await guest.runApp(multitask: false, urlStr: launchURL)
        }
    }

    @MainActor
    private static func routeSpotify(guest: LCAppModel, query: String?) async throws {
        guard let query, !query.isEmpty else {
            try await guest.runApp(
                multitask: false,
                urlStr: "spotify:internal:collection:tracks"
            )
            return
        }

        let lower = query.lowercased()
        let isGenre = genreWords.contains(lower)
        let descriptor: [String: Any] = [
            "q": query,
            "type": isGenre ? "playlist" : "track",
            "shuffle": isGenre
        ]

        let data = try JSONSerialization.data(withJSONObject: descriptor)
        LCUtils.appGroupUserDefault.set(data, forKey: "LCUniversalSpotifyDescriptor")
        LCUtils.appGroupUserDefault.set(Date(), forKey: "LCUniversalSpotifyDescriptorDate")
        diag("universal spotify queued descriptor=\(descriptor)")
        try await guest.runApp(multitask: false, urlStr: nil)
    }

    @MainActor
    private static func routeYouTube(
        guest: LCAppModel,
        query: String?,
        music: Bool
    ) async throws {
        let effectiveQuery: String
        if let query, !query.isEmpty {
            effectiveQuery = query
        } else {
            effectiveQuery = music ? "music" : "trending music"
        }

        if let videoID = await resolveYouTubeVideoID(query: effectiveQuery, music: music) {
            let preferredSchemes = music
                ? ["youtubemusic", "vnd.youtube.music"]
                : ["youtube", "vnd.youtube"]
            let scheme = firstScheme(for: guest, preferred: preferredSchemes)
                ?? (music ? "youtubemusic" : "youtube")
            let launchURL = "\(scheme)://watch?v=\(videoID)"
            diag(
                "universal youtube resolved provider=\(music ? "YouTube Music" : "YouTube") query=\(effectiveQuery) videoID=\(videoID) scheme=\(scheme)"
            )
            try await guest.runApp(multitask: false, urlStr: launchURL)
            return
        }

        let encoded = effectiveQuery.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)
            ?? effectiveQuery
        let fallback: String
        if music {
            let scheme = firstScheme(for: guest, preferred: ["youtubemusic"])
                ?? "youtubemusic"
            fallback = "\(scheme)://search?q=\(encoded)"
        } else {
            let scheme = firstScheme(for: guest, preferred: ["youtube", "vnd.youtube"])
                ?? "youtube"
            fallback = "\(scheme)://results?search_query=\(encoded)"
        }
        diag("universal youtube search fallback url=\(fallback)")
        try await guest.runApp(multitask: false, urlStr: fallback)
    }

    private static func resolveYouTubeVideoID(query: String, music: Bool) async -> String? {
        var components = URLComponents(
            string: music
                ? "https://music.youtube.com/search"
                : "https://www.youtube.com/results"
        )
        components?.queryItems = [
            URLQueryItem(name: music ? "q" : "search_query", value: query)
        ]
        guard let url = components?.url else { return nil }

        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        request.setValue(
            "Mozilla/5.0 (iPhone; CPU iPhone OS 26_0 like Mac OS X) AppleWebKit/605.1.15 Mobile/15E148",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                diag("universal youtube web lookup status=\(http.statusCode)")
                return nil
            }

            guard let html = String(data: data, encoding: .utf8) else {
                return nil
            }

            let regex = try NSRegularExpression(
                pattern: #"\"videoId\":\"([A-Za-z0-9_-]{11})\""#
            )
            let range = NSRange(html.startIndex..<html.endIndex, in: html)
            guard
                let match = regex.firstMatch(in: html, range: range),
                match.numberOfRanges > 1,
                let idRange = Range(match.range(at: 1), in: html)
            else {
                diag("universal youtube web lookup found no videoID")
                return nil
            }

            return String(html[idRange])
        } catch {
            diag("universal youtube web lookup error=\(error.localizedDescription)")
            return nil
        }
    }

    @MainActor
    private static func findGuest(_ provider: LCUniversalMediaProvider) -> LCAppModel? {
        let allApps = DataManager.shared.model.apps + DataManager.shared.model.hiddenApps
        if let exact = allApps.first(where: {
            provider.bundleIdentifiers.contains($0.bundleIdentifier.lowercased())
        }) {
            return exact
        }

        return allApps.first(where: { app in
            let name = app.displayName.lowercased()
            return provider.nameAliases.contains(where: { name.contains($0) })
        })
    }

    private static func firstScheme(
        for guest: LCAppModel,
        preferred: [String]
    ) -> String? {
        let schemes = (guest.appInfo.urlSchemes() as? [String]) ?? []
        for wanted in preferred {
            if let match = schemes.first(where: {
                $0.caseInsensitiveCompare(wanted) == .orderedSame
            }) {
                return match
            }
        }
        return schemes.first
    }

    private static func rootSchemeURL(
        for guest: LCAppModel,
        preferred: [String]
    ) -> String? {
        guard let scheme = firstScheme(for: guest, preferred: preferred) else {
            return nil
        }
        return "\(scheme)://"
    }

    private static func diag(_ message: String) {
        let formatter = ISO8601DateFormatter()
        let line = "[\(formatter.string(from: Date()))] ROUTER \(message)"
        var lines = LCUtils.appGroupUserDefault.stringArray(forKey: "LCSiriDiagnosticLog") ?? []
        lines.append(line)
        if lines.count > 250 {
            lines.removeFirst(lines.count - 250)
        }
        LCUtils.appGroupUserDefault.set(lines, forKey: "LCSiriDiagnosticLog")
        NSLog("[LCMediaRouter] %@", message)
    }
}

@available(iOS 16.0, *)
struct LCMediaQueryEntity: AppEntity {
    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Media")
    static var defaultQuery = LCMediaQueryEntityQuery()

    let id: String
    let text: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(text)")
    }
}

@available(iOS 16.0, *)
struct LCMediaQueryEntityQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [LCMediaQueryEntity] {
        identifiers.map { LCMediaQueryEntity(id: $0, text: $0) }
    }

    func entities(matching string: String) async throws -> [LCMediaQueryEntity] {
        let value = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return [] }
        return [LCMediaQueryEntity(id: value, text: value)]
    }

    func suggestedEntities() async throws -> [LCMediaQueryEntity] {
        []
    }
}

@available(iOS 16.0, *)
struct LCPlaySpotifyIntent: AppIntent {
    static var title: LocalizedStringResource = "Play on Spotify"
    static var description = IntentDescription("Play media in the Spotify guest inside LiveContainer.")
    static var openAppWhenRun = true

    @Parameter(title: "What to play")
    var query: LCMediaQueryEntity

    @MainActor
    func perform() async throws -> some IntentResult {
        try await LCUniversalMediaRouter.route(provider: .spotify, query: query.text)
        return .result()
    }
}

@available(iOS 16.0, *)
struct LCPlaySomethingSpotifyIntent: AppIntent {
    static var title: LocalizedStringResource = "Play something on Spotify"
    static var openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        try await LCUniversalMediaRouter.route(provider: .spotify, query: nil)
        return .result()
    }
}

@available(iOS 16.0, *)
struct LCPlayYouTubeIntent: AppIntent {
    static var title: LocalizedStringResource = "Play on YouTube"
    static var description = IntentDescription("Play a matching video in the YouTube guest inside LiveContainer.")
    static var openAppWhenRun = true

    @Parameter(title: "What to play")
    var query: LCMediaQueryEntity

    @MainActor
    func perform() async throws -> some IntentResult {
        try await LCUniversalMediaRouter.route(provider: .youtube, query: query.text)
        return .result()
    }
}

@available(iOS 16.0, *)
struct LCPlaySomethingYouTubeIntent: AppIntent {
    static var title: LocalizedStringResource = "Play something on YouTube"
    static var openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        try await LCUniversalMediaRouter.route(provider: .youtube, query: nil)
        return .result()
    }
}

@available(iOS 16.0, *)
struct LCPlayYouTubeMusicIntent: AppIntent {
    static var title: LocalizedStringResource = "Play on YouTube Music"
    static var description = IntentDescription("Play a matching song in the YouTube Music guest inside LiveContainer.")
    static var openAppWhenRun = true

    @Parameter(title: "What to play")
    var query: LCMediaQueryEntity

    @MainActor
    func perform() async throws -> some IntentResult {
        try await LCUniversalMediaRouter.route(provider: .youtubeMusic, query: query.text)
        return .result()
    }
}

@available(iOS 16.0, *)
struct LCPlaySomethingYouTubeMusicIntent: AppIntent {
    static var title: LocalizedStringResource = "Play something on YouTube Music"
    static var openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        try await LCUniversalMediaRouter.route(provider: .youtubeMusic, query: nil)
        return .result()
    }
}

@available(iOS 16.0, *)
struct LCPlayDeezerIntent: AppIntent {
    static var title: LocalizedStringResource = "Play on Deezer"
    static var description = IntentDescription("Play media in the Deezer guest inside LiveContainer.")
    static var openAppWhenRun = true

    @Parameter(title: "What to play")
    var query: LCMediaQueryEntity

    @MainActor
    func perform() async throws -> some IntentResult {
        try await LCUniversalMediaRouter.route(provider: .deezer, query: query.text)
        return .result()
    }
}

@available(iOS 16.0, *)
struct LCPlaySomethingDeezerIntent: AppIntent {
    static var title: LocalizedStringResource = "Play something on Deezer"
    static var openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        try await LCUniversalMediaRouter.route(provider: .deezer, query: nil)
        return .result()
    }
}

@available(iOS 16.0, *)
struct LCSelectSpotifyIntent: AppIntent {
    static var title: LocalizedStringResource = "Use Spotify in LiveContainer"

    @MainActor
    func perform() async throws -> some IntentResult {
        LCUniversalMediaRouter.select(provider: .spotify)
        return .result()
    }
}

@available(iOS 16.0, *)
struct LCSelectYouTubeIntent: AppIntent {
    static var title: LocalizedStringResource = "Use YouTube in LiveContainer"

    @MainActor
    func perform() async throws -> some IntentResult {
        LCUniversalMediaRouter.select(provider: .youtube)
        return .result()
    }
}

@available(iOS 16.0, *)
struct LCSelectYouTubeMusicIntent: AppIntent {
    static var title: LocalizedStringResource = "Use YouTube Music in LiveContainer"

    @MainActor
    func perform() async throws -> some IntentResult {
        LCUniversalMediaRouter.select(provider: .youtubeMusic)
        return .result()
    }
}

@available(iOS 16.0, *)
struct LCSelectDeezerIntent: AppIntent {
    static var title: LocalizedStringResource = "Use Deezer in LiveContainer"

    @MainActor
    func perform() async throws -> some IntentResult {
        LCUniversalMediaRouter.select(provider: .deezer)
        return .result()
    }
}

@available(iOS 17.0, *)
public struct LCUniversalMediaIntentsPackage: AppIntentsPackage {
    public init() {}
}

@available(iOS 16.0, *)
struct LCUniversalMediaShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: LCSelectSpotifyIntent(),
            phrases: [
                "Use Spotify in \(.applicationName)",
                "Switch \(.applicationName) to Spotify"
            ],
            shortTitle: "Use Spotify",
            systemImageName: "music.note"
        )
        AppShortcut(
            intent: LCSelectYouTubeIntent(),
            phrases: [
                "Use YouTube in \(.applicationName)",
                "Switch \(.applicationName) to YouTube"
            ],
            shortTitle: "Use YouTube",
            systemImageName: "play.rectangle"
        )
        AppShortcut(
            intent: LCSelectYouTubeMusicIntent(),
            phrases: [
                "Use YouTube Music in \(.applicationName)",
                "Switch \(.applicationName) to YouTube Music"
            ],
            shortTitle: "Use YouTube Music",
            systemImageName: "music.note"
        )
        AppShortcut(
            intent: LCSelectDeezerIntent(),
            phrases: [
                "Use Deezer in \(.applicationName)",
                "Switch \(.applicationName) to Deezer"
            ],
            shortTitle: "Use Deezer",
            systemImageName: "waveform"
        )
        AppShortcut(
            intent: LCPlaySpotifyIntent(),
            phrases: [
                "Play \(\.$query) on Spotify with \(.applicationName)",
                "\(.applicationName) play \(\.$query) on Spotify"
            ],
            shortTitle: "Spotify",
            systemImageName: "music.note"
        )
        AppShortcut(
            intent: LCPlaySomethingSpotifyIntent(),
            phrases: [
                "Play something on Spotify with \(.applicationName)",
                "\(.applicationName) play something on Spotify"
            ],
            shortTitle: "Spotify Something",
            systemImageName: "music.note.list"
        )
        AppShortcut(
            intent: LCPlayYouTubeIntent(),
            phrases: [
                "Play \(\.$query) on YouTube with \(.applicationName)",
                "\(.applicationName) play \(\.$query) on YouTube"
            ],
            shortTitle: "YouTube",
            systemImageName: "play.rectangle"
        )
        AppShortcut(
            intent: LCPlaySomethingYouTubeIntent(),
            phrases: [
                "Play something on YouTube with \(.applicationName)",
                "\(.applicationName) play something on YouTube"
            ],
            shortTitle: "YouTube Something",
            systemImageName: "play.rectangle"
        )
        AppShortcut(
            intent: LCPlayYouTubeMusicIntent(),
            phrases: [
                "Play \(\.$query) on YouTube Music with \(.applicationName)",
                "\(.applicationName) play \(\.$query) on YouTube Music"
            ],
            shortTitle: "YouTube Music",
            systemImageName: "music.note"
        )
        AppShortcut(
            intent: LCPlaySomethingYouTubeMusicIntent(),
            phrases: [
                "Play something on YouTube Music with \(.applicationName)",
                "\(.applicationName) play something on YouTube Music"
            ],
            shortTitle: "YouTube Music Something",
            systemImageName: "music.note.list"
        )
        AppShortcut(
            intent: LCPlayDeezerIntent(),
            phrases: [
                "Play \(\.$query) on Deezer with \(.applicationName)",
                "\(.applicationName) play \(\.$query) on Deezer"
            ],
            shortTitle: "Deezer",
            systemImageName: "waveform"
        )
        AppShortcut(
            intent: LCPlaySomethingDeezerIntent(),
            phrases: [
                "Play something on Deezer with \(.applicationName)",
                "\(.applicationName) play something on Deezer"
            ],
            shortTitle: "Deezer Something",
            systemImageName: "waveform"
        )
    }
}
