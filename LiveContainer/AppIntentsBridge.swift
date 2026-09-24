import AppIntents
import LiveContainerSwiftUI

@available(iOS 16.0, *)
struct LiveContainerAppIntentsPackage: AppIntentsPackage {
    static var includedPackages: [any AppIntentsPackage.Type] {
        [LCUniversalMediaIntentsPackage.self]
    }
}
