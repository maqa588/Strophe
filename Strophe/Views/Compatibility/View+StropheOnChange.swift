import SwiftUI

extension View {
    @ViewBuilder
    func stropheOnChange<Value: Equatable>(
        of value: Value,
        perform action: @escaping (_ newValue: Value) -> Void
    ) -> some View {
        if #available(macOS 14.0, iOS 17.0, tvOS 17.0, watchOS 10.0, visionOS 1.0, *) {
            self.onChange(of: value) { _, newValue in
                action(newValue)
            }
        } else {
            self.onChange(of: value, perform: action)
        }
    }
}
