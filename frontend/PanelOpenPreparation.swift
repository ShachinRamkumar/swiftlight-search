import Foundation
import Combine

@MainActor final class PanelOpenPreparation {
    private var subscription: AnyCancellable?

    init(center: NotificationCenter = .default, name: Notification.Name, object: AnyObject,
         isReady: @escaping @MainActor () -> Bool, notify: @escaping @MainActor () -> Void) {
        subscription = center.publisher(for: name, object: object)
            .receive(on: DispatchQueue.main)
            .sink { _ in
                MainActor.assumeIsolated {
                    if isReady() { notify() }
                }
            }
    }
}
