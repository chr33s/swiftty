#if canImport(UIKit)
import SwifttyCore
import UIKit

/// Application delegate for the reference iOS/iPadOS app. An app target
/// needs only `@main` on a subclass, or this in its `main.swift`:
///
///     UIApplicationMain(CommandLine.argc, CommandLine.unsafeArgv, nil,
///                       NSStringFromClass(SwifttyMobileAppDelegate.self))
@MainActor
open class SwifttyMobileAppDelegate: UIResponder, UIApplicationDelegate {
  /// `Documents/config` in Ghostty syntax (shared through the Files
  /// app), with themes from `Documents/themes`; the defaults when absent.
  public static func loadConfiguration() -> Configuration {
    guard
      let documents = FileManager.default
        .urls(for: .documentDirectory, in: .userDomainMask).first
    else { return Configuration() }
    var configuration = Configuration.load(
      from: documents.appendingPathComponent("config")
    )
    configuration.themeDirectories.insert(
      documents.appendingPathComponent("themes"),
      at: 0
    )
    return configuration
  }

  open func application(
    _ application: UIApplication,
    configurationForConnecting connectingSceneSession: UISceneSession,
    options: UIScene.ConnectionOptions,
  ) -> UISceneConfiguration {
    let configuration = UISceneConfiguration(
      name: nil,
      sessionRole: connectingSceneSession.role
    )
    configuration.delegateClass = SwifttyMobileSceneDelegate.self
    return configuration
  }
}

/// One terminal per window scene (each Split View or Stage Manager
/// window), connected to the local demo source.
@MainActor
open class SwifttyMobileSceneDelegate: UIResponder, UIWindowSceneDelegate {
  public var window: UIWindow?

  open func scene(
    _ scene: UIScene,
    willConnectTo session: UISceneSession,
    options connectionOptions: UIScene.ConnectionOptions
  ) {
    guard let scene = scene as? UIWindowScene else { return }
    let window = UIWindow(windowScene: scene)
    window.rootViewController = TerminalViewController(
      configuration: SwifttyMobileAppDelegate.loadConfiguration()
    )
    window.makeKeyAndVisible()
    self.window = window
  }
}

/// Hosts a `TerminalUIView` inside the safe area and connects it to a
/// `DemoSource`. Apps with a real transport create their own session
/// and pass it to `init(session:configuration:)`.
@MainActor
open class TerminalViewController: UIViewController {
  public let session: TerminalSession
  public let configuration: Configuration
  private var demo: DemoSource?
  public private(set) var terminal: TerminalUIView?

  /// - Parameters:
  ///   - session: Connected session; nil creates a demo session.
  ///   - configuration: Session and view settings.
  public init(
    session: TerminalSession? = nil,
    configuration: Configuration = Configuration()
  ) {
    self.configuration = configuration
    if let session {
      self.session = session
    } else {
      let scheme: ColorScheme =
        UITraitCollection.current.userInterfaceStyle == .light ? .light : .dark
      self.session = TerminalSession(
        configuration: configuration.sessionConfiguration(scheme: scheme)
      )
      demo = DemoSource(session: self.session)
    }
    super.init(nibName: nil, bundle: nil)
  }

  @available(*, unavailable)
  public required init?(coder: NSCoder) { fatalError() }

  override open func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .black
    // Translucent backgrounds blur what is behind the window.
    if configuration.backgroundOpacity < 1 {
      view.backgroundColor = .clear
      if configuration.backgroundBlur > 0 {
        let blur = UIVisualEffectView(
          effect: UIBlurEffect(style: .systemUltraThinMaterialDark)
        )
        blur.frame = view.bounds
        blur.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(blur)
      }
    }
    do {
      let terminal = try TerminalUIView(
        session: session,
        configuration: configuration
      )
      terminal.translatesAutoresizingMaskIntoConstraints = false
      terminal.onTitle = { [weak self] title in self?.title = title }
      terminal.onBackgroundColor = { [weak self] color in
        self?.view.backgroundColor = color
      }
      view.addSubview(terminal)
      let safe = view.safeAreaLayoutGuide
      NSLayoutConstraint.activate([
        terminal.leadingAnchor.constraint(equalTo: safe.leadingAnchor),
        terminal.trailingAnchor.constraint(equalTo: safe.trailingAnchor),
        terminal.topAnchor.constraint(equalTo: safe.topAnchor),
        // The terminal handles the keyboard itself, so it spans
        // to the bottom edge rather than the keyboard guide.
        terminal.bottomAnchor.constraint(equalTo: safe.bottomAnchor),
      ])
      self.terminal = terminal
    } catch {
      let label = UILabel()
      label.text = "Metal unavailable: \(error)"
      label.textColor = .white
      label.frame = view.bounds
      view.addSubview(label)
    }
    demo?.start()
  }

  override open func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    terminal?.becomeFirstResponder()
  }

  override open var preferredStatusBarStyle: UIStatusBarStyle { .default }
}
#endif
