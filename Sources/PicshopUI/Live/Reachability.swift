#if canImport(SwiftUI) && canImport(UIKit)
import Foundation
import Network
import Observation

/// Whether the network is usable, for the brain choice: offline at Live start
/// means the local route and a notice.
@MainActor
@Observable
final class LiveReachability {
    private(set) var isOnline = true
    @ObservationIgnored private let monitor = NWPathMonitor()

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            Task { @MainActor [weak self] in
                guard let self, self.isOnline != online else { return }
                self.isOnline = online
            }
        }
        monitor.start(queue: DispatchQueue(label: "picshop.live.reachability", qos: .utility))
    }
}
#endif
