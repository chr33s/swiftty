import Testing

/// Retains fixture bytes while making terminal control characters safe in test output.
public struct TestFixture<Value>: CustomTestStringConvertible, CustomReflectable {
    public let value: Value

    public init(_ value: Value) {
        self.value = value
    }

    public var testDescription: String {
        escapedTestText(String(describingForTest: value))
    }

    /// Swift Testing also expands reflected children when an assertion fails.
    public var customMirror: Mirror {
        Mirror(self, children: ["value": testDescription], displayStyle: .struct)
    }
}

extension TestFixture: Sendable where Value: Sendable {}

extension TestFixture: Equatable where Value: Equatable {}

/// Use for diagnostic comments as well as fixture descriptions.
public func escapedTestText(_ text: String) -> String {
    var result = ""
    for scalar in text.unicodeScalars {
        switch scalar.value {
        case 0 ... 0x1F, 0x7F ... 0x9F:
            result += "\\u{" + String(scalar.value, radix: 16, uppercase: true) + "}"
        default:
            result.unicodeScalars.append(scalar)
        }
    }
    return result
}
