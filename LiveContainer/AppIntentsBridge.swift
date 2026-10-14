import AppIntents
import LiveContainerSwiftUI

@available(iOS 17.0, *)
struct LiveContainerAppIntentsPackage: AppIntentsPackage {
    static var includedPackages: [any AppIntentsPackage.Type] {
        [LCUniversalMediaIntentsPackage.self]
    }
}
