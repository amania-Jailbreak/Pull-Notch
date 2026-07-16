import Foundation
import Observation

enum ExpandedPageNavigationDirection: Equatable {
    case forward
    case backward
}

/// Owns expanded-page selection independently from the page descriptors and UI.
///
/// The overlay remains responsible for producing the available pages. This model
/// only keeps the current selection valid and determines animation direction.
@Observable
final class ExpandedPageNavigationModel {
    private(set) var currentPageID: String?
    private(set) var direction: ExpandedPageNavigationDirection = .forward

    @discardableResult
    func synchronize(pageIDs: [String]) -> Bool {
        let nextPageID: String?
        if let currentPageID, pageIDs.contains(currentPageID) {
            nextPageID = currentPageID
        } else {
            nextPageID = pageIDs.first
        }

        guard currentPageID != nextPageID else { return false }
        currentPageID = nextPageID
        return true
    }

    @discardableResult
    func select(pageID: String, in pageIDs: [String]) -> Bool {
        guard let targetIndex = pageIDs.firstIndex(of: pageID) else { return false }

        let nextDirection: ExpandedPageNavigationDirection
        if let currentPageID,
           let currentIndex = pageIDs.firstIndex(of: currentPageID),
           currentIndex != targetIndex {
            nextDirection = targetIndex > currentIndex ? .forward : .backward
        } else {
            nextDirection = .forward
        }

        let didChange = currentPageID != pageID || direction != nextDirection
        currentPageID = pageID
        direction = nextDirection
        return didChange
    }

    @discardableResult
    func selectPrevious(in pageIDs: [String]) -> Bool {
        move(by: -1, direction: .backward, in: pageIDs)
    }

    @discardableResult
    func selectNext(in pageIDs: [String]) -> Bool {
        move(by: 1, direction: .forward, in: pageIDs)
    }

    private func move(
        by offset: Int,
        direction nextDirection: ExpandedPageNavigationDirection,
        in pageIDs: [String]
    ) -> Bool {
        guard
            let currentPageID,
            let currentIndex = pageIDs.firstIndex(of: currentPageID)
        else {
            return false
        }

        let targetIndex = currentIndex + offset
        guard pageIDs.indices.contains(targetIndex) else { return false }

        self.currentPageID = pageIDs[targetIndex]
        direction = nextDirection
        return true
    }
}
