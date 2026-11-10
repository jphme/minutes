import Combine
import SwiftUI

/// Stand-in for SwiftUI's `@State`.
/// On the macOS 27 SDK `@State` is a compiler macro whose plugin ships only with Xcode, not with the
/// Command Line Tools this project builds with. `@StateObject` is still a plain property wrapper,
/// so view-local state lives in a tiny observable box instead.
@propertyWrapper
struct Local<Value>: DynamicProperty {
    @StateObject private var box: Box

    init(wrappedValue: Value) {
        _box = StateObject(wrappedValue: Box(wrappedValue))
    }

    var wrappedValue: Value {
        get { box.value }
        nonmutating set { box.value = newValue }
    }

    var projectedValue: Binding<Value> {
        Binding(get: { box.value }, set: { box.value = $0 })
    }

    final class Box: ObservableObject {
        @Published var value: Value
        init(_ value: Value) { self.value = value }
    }
}
