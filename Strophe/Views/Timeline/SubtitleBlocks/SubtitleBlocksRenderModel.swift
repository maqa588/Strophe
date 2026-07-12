import Combine
import SwiftUI

/// A narrow projection of SubtitleProject for the timeline renderer.
///
/// SubtitleProject owns playback, document, selection and editor state. Observing it
/// directly from every subtitle block caused unrelated changes (for example the
/// current subtitle index) to invalidate the entire block hierarchy. This model only
/// republishes values that can actually change block pixels or block interaction.
@MainActor
final class SubtitleBlocksRenderModel: ObservableObject {
    private struct SnapEdge {
        let time: Double
        let itemID: UUID
    }

    @Published private(set) var items: [SubtitleItem]
    @Published private(set) var selectedIDs: Set<UUID>
    @Published private(set) var editingMode: TimelineEditingMode
    @Published private(set) var activeSlapSubtitleID: UUID?
    @Published private(set) var groups: [SubGroupItem]
    @Published private(set) var styles: [SubgroupStyle]

    private(set) var renderRevision: UInt64 = 0
    private(set) var timelineIndex = TimelineIndex()
    private var itemByID: [UUID: SubtitleItem] = [:]
    private var groupByID: [UUID: SubGroupItem] = [:]
    private var cachedSortedGroups: [SubGroupItem] = []
    private var snapEdgesByGroupID: [UUID: [SnapEdge]] = [:]
    private var overlapIntervalsByGroupID: [UUID: [SubtitleProject.OverlapInterval]] = [:]
    private var cancellables = Set<AnyCancellable>()

    init(project: SubtitleProject, store: StyleAndGroupStore = .shared) {
        items = project.items
        selectedIDs = project.selectedIDs
        editingMode = project.editingMode
        activeSlapSubtitleID = project.activeSlapSubtitleID
        groups = store.groups
        styles = store.styles
        rebuildGroupLookup()
        rebuildItemIndexes()

        project.$items
            .dropFirst()
            .sink { [weak self] in self?.replaceItems($0) }
            .store(in: &cancellables)
        project.$selectedIDs
            .dropFirst()
            .sink { [weak self] newValue in
                guard let self, self.selectedIDs != newValue else { return }
                self.renderRevision &+= 1
                self.selectedIDs = newValue
            }
            .store(in: &cancellables)
        project.$editingMode
            .dropFirst()
            .sink { [weak self] in self?.editingMode = $0 }
            .store(in: &cancellables)
        project.$activeSlapSubtitleID
            .dropFirst()
            .sink { [weak self] in self?.activeSlapSubtitleID = $0 }
            .store(in: &cancellables)
        store.$groups
            .dropFirst()
            .sink { [weak self] newValue in
                guard let self, self.groups != newValue else { return }
                self.renderRevision &+= 1
                self.groups = newValue
                self.rebuildGroupLookup()
                self.rebuildItemIndexes()
            }
            .store(in: &cancellables)
        store.$styles
            .dropFirst()
            .sink { [weak self] in self?.styles = $0 }
            .store(in: &cancellables)
    }

    func item(id: UUID?) -> SubtitleItem? {
        id.flatMap { itemByID[$0] }
    }

    func visibleItems(in range: ClosedRange<Double>) -> [SubtitleItem] {
        timelineIndex.visibleItems(in: range)
    }

    func group(for item: SubtitleItem) -> SubGroupItem? {
        item.groupID.flatMap { groupByID[$0] } ?? groups.first
    }

    var activeGroupID: UUID? {
        groups.first(where: \.isActive)?.id ?? groups.first?.id
    }

    var sortedGroups: [SubGroupItem] {
        cachedSortedGroups
    }

    func nearestSnapPoint(
        to time: Double,
        groupID: UUID?,
        ignoring ignoredItemIDs: Set<UUID>
    ) -> Double? {
        guard let groupID,
              let edges = snapEdgesByGroupID[groupID],
              !edges.isEmpty else { return nil }

        var low = 0
        var high = edges.count
        while low < high {
            let middle = low + (high - low) / 2
            if edges[middle].time < time {
                low = middle + 1
            } else {
                high = middle
            }
        }

        var left = low - 1
        var right = low
        var bestTime: Double?
        var bestDistance = Double.infinity

        while left >= 0 || right < edges.count {
            let leftDistance = left >= 0 ? abs(edges[left].time - time) : .infinity
            let rightDistance = right < edges.count ? abs(edges[right].time - time) : .infinity
            let useLeft = leftDistance <= rightDistance
            let candidate = useLeft ? edges[left] : edges[right]
            let distance = useLeft ? leftDistance : rightDistance
            if useLeft { left -= 1 } else { right += 1 }

            if distance > bestDistance { break }
            guard !ignoredItemIDs.contains(candidate.itemID) else { continue }
            bestTime = candidate.time
            bestDistance = distance
            if distance == 0 { break }
        }
        return bestTime
    }

    func overlappingIntervals(in groupID: UUID?) -> [SubtitleProject.OverlapInterval] {
        guard let groupID else { return [] }
        return overlapIntervalsByGroupID[groupID] ?? []
    }

    private func replaceItems(_ newItems: [SubtitleItem]) {
        guard items != newItems else { return }
        renderRevision &+= 1
        items = newItems
        rebuildItemIndexes()
    }

    private func rebuildGroupLookup() {
        groupByID = Dictionary(uniqueKeysWithValues: groups.map { ($0.id, $0) })
        cachedSortedGroups = groups.sorted { lhs, rhs in
            lhs.sortOrder == rhs.sortOrder ? lhs.name < rhs.name : lhs.sortOrder < rhs.sortOrder
        }
    }

    private func rebuildItemIndexes() {
        itemByID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        timelineIndex.rebuild(with: items)

        var result: [UUID: [SnapEdge]] = [:]
        var overlaps: [UUID: [SubtitleProject.OverlapInterval]] = [:]
        var maxEndByGroup: [UUID: Double] = [:]

        // TimelineIndex has already sorted this list, so every per-group stream
        // is sorted too. Build snap and overlap caches without another filter/sort.
        for item in timelineIndex.itemsByStartTime {
            guard let groupID = group(for: item)?.id,
                  let start = item.startTime else { continue }
            result[groupID, default: []].append(SnapEdge(time: start, itemID: item.id))
            if let end = item.endTime {
                result[groupID, default: []].append(SnapEdge(time: end, itemID: item.id))
            }

            let end = item.endTime ?? (start + 0.1)
            if let maxEnd = maxEndByGroup[groupID], start < maxEnd {
                let overlapEnd = min(end, maxEnd)
                if start < overlapEnd {
                    overlaps[groupID, default: []].append(.init(start: start, end: overlapEnd))
                }
                maxEndByGroup[groupID] = max(maxEnd, end)
            } else {
                maxEndByGroup[groupID] = end
            }
        }
        for groupID in Array(result.keys) {
            result[groupID]?.sort {
                $0.time == $1.time
                    ? $0.itemID.uuidString < $1.itemID.uuidString
                    : $0.time < $1.time
            }
        }
        snapEdgesByGroupID = result
        overlapIntervalsByGroupID = overlaps
    }
}
