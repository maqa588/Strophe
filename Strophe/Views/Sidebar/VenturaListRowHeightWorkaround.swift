//
//  VenturaListRowHeightWorkaround.swift
//  Strophe
//

import SwiftUI

#if os(macOS)
import AppKit

private struct VenturaListRowHeightWorkaround: NSViewRepresentable {
    let rowHeight: CGFloat

    func makeNSView(context: Context) -> NSView {
        NSView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard #unavailable(macOS 14.0) else { return }

        DispatchQueue.main.async {
            configureNearestTable(from: nsView, rowHeight: rowHeight)
        }
    }

    private func configureNearestTable(from view: NSView, rowHeight: CGFloat) {
        var current: NSView? = view
        while let container = current {
            if let tableView = findTableView(in: container) {
                tableView.usesAutomaticRowHeights = false
                tableView.rowHeight = rowHeight
                tableView.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0..<tableView.numberOfRows))
                return
            }
            current = container.superview
        }
    }

    private func findTableView(in view: NSView) -> NSTableView? {
        if let tableView = view as? NSTableView {
            return tableView
        }

        for subview in view.subviews {
            if let tableView = findTableView(in: subview) {
                return tableView
            }
        }

        return nil
    }
}

extension View {
    func venturaFixedListRowHeight(_ rowHeight: CGFloat) -> some View {
        background(VenturaListRowHeightWorkaround(rowHeight: rowHeight))
    }
}
#else
extension View {
    func venturaFixedListRowHeight(_ rowHeight: CGFloat) -> some View {
        self
    }
}
#endif
