// PlayerPresentation (PLAN.md §5.5, §6.3). Owner: P0 (frozen contract). The state machine and
// mini-player geometry are Module C's, in other files of this directory.

import Foundation

public enum PlayerPresentation: Equatable, Hashable, Sendable {
    public enum Corner: CaseIterable, Hashable, Sendable {
        case topLeading, topTrailing, bottomLeading, bottomTrailing
    }

    case hidden, expanded, docked, mini(Corner)
}
