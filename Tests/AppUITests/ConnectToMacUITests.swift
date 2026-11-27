import XCTest

/// Connect to Mac on a device (spec.connection-setup.md D1–D5): a pasted
/// code with matching and mismatched SSH keys, Nearby Macs against a real
/// `_swiftty._tcp` registration, and the Local Network and camera
/// permission prompts. Run through Scripts/test-app-ui.sh; the Nearby
/// case needs `RST_UI_ADVERTISE=<name>`, the denial case
/// `RST_UI_LOCAL_NETWORK=deny` on a fresh install.
@MainActor
final class ConnectToMacUITests: XCTestCase {
  private var env: [String: String] = [:]
  private var app: XCUIApplication!
  private var springboard: XCUIApplication {
    XCUIApplication(bundleIdentifier: "com.apple.springboard")
  }

  override func setUp() async throws {
    continueAfterFailure = false
    #if !os(iOS) || targetEnvironment(macCatalyst)
    throw XCTSkip("Connect to Mac discovery and scanning are iPhone/iPad only")
    #else
    env = ProcessInfo.processInfo.environment
    guard env["RST_UI_HOST"] != nil, env["RST_UI_FINGERPRINT"] != nil else {
      throw XCTSkip("Run through Scripts/test-app-ui.sh (RST_UI_* not set)")
    }
    app = XCUIApplication()
    app.launchArguments += ["-ui-testing"]
    #endif
  }

  override func tearDown() async throws {
    app?.terminate()
    try await super.tearDown()
  }

  private var allowsLocalNetwork: Bool { env["RST_UI_LOCAL_NETWORK"] != "deny" }

  // MARK: Pasted code

  /// The code's key matches: trust shows it matched, sign-in follows, and
  /// the workspace chooser opens without creating anything.
  func testPastedCodeWithMatchingKeyPairsThenShowsChooser() throws {
    try XCTSkipUnless(allowsLocalNetwork)
    app.launch()
    try paste(code(fingerprint: env["RST_UI_FINGERPRINT"]!))
    connectCandidate(expectingCode: true)
    XCTAssertTrue(element("trust.paired").waitForExistence(timeout: 30))
    XCTAssertEqual(
      text(of: element("trust.fingerprint")),
      env["RST_UI_FINGERPRINT"]
    )
    press(element("trust.accept"))
    signIn()
    // Mac → Workspace: listed, nothing created.
    XCTAssertTrue(element("workspace.new").waitForExistence(timeout: 30))
    press(element("workspace.cancel"))
    returnToHosts()
    XCTAssertTrue(hostRow("Code Mac").waitForExistence(timeout: 10))
  }

  /// Another key in the code blocks before any password is requested and
  /// saves nothing.
  func testPastedCodeWithOtherKeyBlocksBeforePassword() throws {
    try XCTSkipUnless(allowsLocalNetwork)
    app.launch()
    try paste(code(fingerprint: "SHA256:" + String(repeating: "A", count: 43)))
    connectCandidate(expectingCode: true)
    let error = element("host.error")
    XCTAssertTrue(error.waitForExistence(timeout: 30), "no pairing error")
    XCTAssertTrue(
      text(of: error).contains("match the code"),
      "unexpected error: \(text(of: error))"
    )
    XCTAssertFalse(element("password.field").exists)
    XCTAssertFalse(element("trust.fingerprint").exists)
    press(element("Cancel", byLabel: true))
    returnToHosts()
    XCTAssertFalse(hostRow("Code Mac").waitForExistence(timeout: 3))
  }

  // MARK: Nearby Macs

  /// A real registration is found, resolved and confirmed; pairing runs
  /// the ordinary unknown-key flow and ends at the chooser.
  func testNearbyMacsFindsTheAdvertisedMacAndPairs() throws {
    try XCTSkipUnless(allowsLocalNetwork)
    let name = try XCTUnwrap(
      env["RST_UI_NEARBY"].flatMap { $0.isEmpty ? nil : $0 },
      "set RST_UI_ADVERTISE"
    )
    app.launch()
    openConnectMenu("connect.nearby")
    // Asked once per install; a granted earlier run shows no prompt.
    answerSystemAlertIfShown(allow: true)
    let candidate = app.buttons
      .matching(NSPredicate(format: "label CONTAINS %@", name)).firstMatch
    XCTAssertTrue(candidate.waitForExistence(timeout: 60), "Mac not found")
    press(candidate)
    let port = element("host.port")
    XCTAssertTrue(port.waitForExistence(timeout: 30), "not resolved")
    XCTAssertEqual(port.value as? String, env["RST_UI_PORT"])
    XCTAssertTrue(anyText("Found on this network").exists)
    replaceText(in: element("host.username"), with: env["RST_UI_USER"] ?? "rst")
    press(element("host.connect"))
    XCTAssertTrue(element("trust.fingerprint").waitForExistence(timeout: 30))
    XCTAssertFalse(element("trust.paired").exists)
    XCTAssertEqual(
      text(of: element("trust.fingerprint")),
      env["RST_UI_FINGERPRINT"]
    )
    press(element("trust.accept"))
    signIn()
    XCTAssertTrue(element("workspace.new").waitForExistence(timeout: 30))
    press(element("workspace.cancel"))
  }

  /// Local Network denied: the browser reports the policy denial and
  /// manual entry stays available.
  func testNearbyMacsReportsLocalNetworkDenial() throws {
    try XCTSkipIf(allowsLocalNetwork, "run with RST_UI_LOCAL_NETWORK=deny")
    app.launch()
    openConnectMenu("connect.nearby")
    answerSystemAlert(allow: false)
    XCTAssertTrue(element("nearby.denied").waitForExistence(timeout: 30))
    XCTAssertTrue(anyText("Local Network access is off").exists)
    press(element("Cancel", byLabel: true))
    returnToHosts()
  }

  // MARK: Camera

  /// Refusing the camera leaves pasting; allowing it shows the viewfinder.
  func testCameraDenialLeavesPasteAndAllowanceShowsViewfinder() throws {
    #if os(iOS)
    app.resetAuthorizationStatus(for: .camera)
    app.launch()
    openConnectMenu("connect.scan")
    answerSystemAlert(allow: false)
    XCTAssertTrue(element("scan.unavailable").waitForExistence(timeout: 15))
    press(element("scan.paste"))
    XCTAssertTrue(element("paste.code").waitForExistence(timeout: 10))
    press(element("Cancel", byLabel: true))

    app.terminate()
    app.resetAuthorizationStatus(for: .camera)
    app.launch()
    openConnectMenu("connect.scan")
    answerSystemAlert(allow: true)
    XCTAssertTrue(
      app.descendants(matching: .any)["Camera viewfinder"]
        .waitForExistence(timeout: 15)
    )
    press(element("Cancel", byLabel: true))
    #endif
  }

  /// The physical scan: with `RST_UI_SCAN=1`, waits for the camera to be
  /// pointed at the Mac's Connect a Device pairing code, then checks the
  /// confirmation screen it opens. Nothing connects until Connect.
  func testScanningTheMacPairingCodeOpensConfirmation() throws {
    try XCTSkipUnless(env["RST_UI_SCAN"] == "1", "set RST_UI_SCAN=1")
    app.launch()
    openConnectMenu("connect.scan")
    answerSystemAlertIfShown(allow: true)
    // A camera already aimed at the code can skip straight past the
    // viewfinder to the confirmation.
    let confirm = element("candidate.confirmSource")
    XCTAssertTrue(
      confirm.waitForExistence(timeout: 300),
      "no code scanned within 5 minutes"
    )
    let host = element("host.address").value as? String ?? ""
    let port = element("host.port").value as? String ?? ""
    let user = element("host.username").value as? String ?? ""
    let keys = app.staticTexts
      .matching(NSPredicate(format: "label BEGINSWITH 'SHA256:'"))
      .allElementsBoundByIndex.map { $0.label }
    let summary = "scanned host=\(host) port=\(port) user=\(user) keys=\(keys)"
    print(summary)
    add(XCTAttachment(string: summary))
    XCTAssertFalse(host.isEmpty)
    XCTAssertFalse(keys.isEmpty)
    XCTAssertFalse(element("host.connect").isEnabled)
    XCTAssertFalse(element("password.field").exists)
    press(element("Cancel", byLabel: true))
  }

  // MARK: Steps

  private func code(fingerprint: String) -> String {
    // Key-sorted compact JSON, as the Mac's exporter writes it.
    let host = env["RST_UI_HOST"]!
    let port = env["RST_UI_PORT"]!
    let user = env["RST_UI_USER"] ?? "rst"
    return #"{"hostKeys":[{"algorithm":"ssh-ed25519","sha256":""# + fingerprint
      + #""}],"kind":"swiftty-host","name":"Code Mac","# + #""ssh":{"host":""#
      + host + #"","port":"# + port + #","username":""# + user
      + #""},"version":1}"#
  }

  /// Enters the code as the camera-free path does. The device test runner
  /// cannot write the system pasteboard, so the code is typed.
  private func paste(_ code: String) throws {
    openConnectMenu("connect.paste")
    let field = element("paste.code")
    XCTAssertTrue(field.waitForExistence(timeout: 10))
    press(field)
    field.typeText(code)
    press(element("paste.continue"))
  }

  private func connectCandidate(expectingCode: Bool) {
    let confirm = element("candidate.confirmSource")
    XCTAssertTrue(confirm.waitForExistence(timeout: 10), "no candidate form")
    let connect = element("host.connect")
    if expectingCode {
      // Connect waits for the source confirmation.
      XCTAssertFalse(connect.isEnabled)
      if let toggle = confirm.switches.allElementsBoundByIndex.first {
        press(toggle)
      } else {
        press(confirm)
      }
    }
    XCTAssertTrue(connect.isEnabled)
    press(connect)
    answerSystemAlertIfShown(allow: allowsLocalNetwork)
  }

  private func signIn() {
    let field = element("password.field")
    XCTAssertTrue(field.waitForExistence(timeout: 30), "no password prompt")
    press(field)
    field.typeText(env["RST_UI_PASSWORD"] ?? "")
    press(element("password.submit"))
  }

  /// Connect to Mac lives in Settings › Connect to Mac.
  private func openConnectMenu(_ item: String) {
    let settings = element("settings")
    XCTAssertTrue(settings.waitForExistence(timeout: 20), "no Settings")
    press(settings)
    let connect = element("settings.connect")
    XCTAssertTrue(connect.waitForExistence(timeout: 5), "no Connect to Mac")
    press(connect)
    let entry = element(item)
    XCTAssertTrue(entry.waitForExistence(timeout: 5), "no \(item)")
    press(entry)
  }

  /// The system permission alert (Local Network or camera).
  private func answerSystemAlert(allow: Bool) {
    XCTAssertTrue(
      springboard.alerts.firstMatch.waitForExistence(timeout: 15),
      "no permission prompt"
    )
    answerSystemAlertIfShown(allow: allow)
  }

  private func answerSystemAlertIfShown(allow: Bool) {
    let alert = springboard.alerts.firstMatch
    guard alert.waitForExistence(timeout: 5) else { return }
    let buttons = alert.buttons.allElementsBoundByIndex
    let refuse = buttons.first { $0.label.contains("Don") }
    let accept = buttons.first {
      !$0.label.contains("Don")
        && ($0.label.contains("Allow") || $0.label == "OK")
    }
    if let button = allow ? accept : refuse { button.tap() }
  }

  // MARK: Helpers

  /// Connect to Mac is presented from Settings › Connect to Mac. Closing its
  /// sheet leaves that submenu visible, so host-list assertions must navigate
  /// back to Settings and then Hosts.
  private func returnToHosts() {
    let backToSettings = app.navigationBars["Connect to Mac"].buttons["Settings"]
    if backToSettings.waitForExistence(timeout: 5) {
      press(backToSettings)
    }
    let back = app.navigationBars["Settings"].buttons["Hosts"]
    XCTAssertTrue(back.waitForExistence(timeout: 10))
    press(back)
    XCTAssertTrue(element("hosts.add").waitForExistence(timeout: 10))
  }

  private func element(_ id: String, byLabel: Bool = false) -> XCUIElement {
    let predicate =
      byLabel
      ? NSPredicate(format: "label == %@", id)
      : NSPredicate(format: "identifier == %@", id)
    return app.descendants(matching: .any).matching(predicate).firstMatch
  }

  private func text(of element: XCUIElement) -> String {
    if !element.label.isEmpty { return element.label }
    return element.value as? String ?? ""
  }

  private func anyText(_ text: String) -> XCUIElement {
    app.descendants(matching: .any)
      .matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
  }

  private func hostRow(_ nickname: String) -> XCUIElement {
    app.descendants(matching: .any)
      .matching(
        NSPredicate(
          format: "label == %@ OR label BEGINSWITH %@",
          nickname,
          nickname + ","
        )
      )
      .firstMatch
  }

  private func replaceText(in field: XCUIElement, with text: String) {
    XCTAssertTrue(field.waitForExistence(timeout: 10))
    press(field)
    if let current = field.value as? String, !current.isEmpty,
      current != field.placeholderValue
    {
      field.typeText(
        String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count)
      )
    }
    field.typeText(text)
  }

  private func press(_ element: XCUIElement) { element.tap() }
}
