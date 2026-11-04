#if os(macOS)
import AppKit
import ObjectiveC

/// Reads an accessibility attribute through the legacy informal protocol.
/// Attributes such as `AXEnhancedUserInterface` have no NSAccessibility
/// protocol method, so send the selector directly rather than reference the
/// deprecated declaration.
func legacyAccessibilityValue(
  _ object: NSObject,
  _ attribute: NSAccessibility.Attribute
) -> Any? {
  typealias Getter =
    @convention(c) (NSObject, Selector, NSString) -> Unmanaged<AnyObject>?
  let selector = NSSelectorFromString("accessibilityAttributeValue:")
  guard object.responds(to: selector),
    let method = class_getMethodImplementation(type(of: object), selector)
  else { return nil }
  let getter = unsafeBitCast(method, to: Getter.self)
  return getter(object, selector, attribute.rawValue as NSString)?
    .takeUnretainedValue()
}

/// Writes an accessibility attribute through the legacy informal protocol.
func setLegacyAccessibilityValue(
  _ object: NSObject,
  _ value: Any?,
  _ attribute: NSAccessibility.Attribute
) {
  typealias Setter =
    @convention(c) (NSObject, Selector, AnyObject?, NSString) -> Void
  let selector = NSSelectorFromString("accessibilitySetValue:forAttribute:")
  guard object.responds(to: selector),
    let method = class_getMethodImplementation(type(of: object), selector)
  else { return }
  let setter = unsafeBitCast(method, to: Setter.self)
  setter(object, selector, value as AnyObject?, attribute.rawValue as NSString)
}

/// Turns on `AXEnhancedUserInterface` so SwiftUI publishes its accessibility
/// tree, and returns a closure that restores the previous setting.
@MainActor
func enableEnhancedUserInterface() -> () -> Void {
  let attribute = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
  let previous = legacyAccessibilityValue(NSApp, attribute) as? Bool ?? false
  setLegacyAccessibilityValue(NSApp, true, attribute)
  return { setLegacyAccessibilityValue(NSApp, previous, attribute) }
}
#endif
