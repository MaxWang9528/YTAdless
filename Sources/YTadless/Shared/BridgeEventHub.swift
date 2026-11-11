// BridgeEventHub: fan-out of decoded bridge messages (PLAN.md §5.5). Owner: P0 (frozen).

import YTCore

@MainActor
final class BridgeEventHub {
    struct Event: Sendable {
        let role: WebRole
        let isMainFrame: Bool
        let message: BridgeMessage
    }

    private final class Subscription {
        let handler: @MainActor (Event) -> Void
        init(_ handler: @escaping @MainActor (Event) -> Void) { self.handler = handler }
    }

    private struct WeakSubscription {
        weak var value: Subscription?
    }

    private var subscriptions: [WeakSubscription] = []

    init() {}

    /// Keep the returned token; dropping it unsubscribes.
    func subscribe(_ handler: @escaping @MainActor (Event) -> Void) -> AnyObject {
        let subscription = Subscription(handler)
        subscriptions.append(WeakSubscription(value: subscription))
        return subscription
    }

    /// Delivers to every live subscriber, in subscription order. Subscribers added during a
    /// publish see the next event, not this one.
    func publish(_ event: Event) {
        subscriptions.removeAll { $0.value == nil }
        for subscription in subscriptions {
            subscription.value?.handler(event)
        }
    }
}
