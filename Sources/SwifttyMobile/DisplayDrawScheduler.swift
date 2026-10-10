#if canImport(UIKit)
import UIKit

/// Coalesces updates at the display rate, then pauses after the last dirty frame.
@MainActor
final class DisplayDrawScheduler {
  private var link: CADisplayLink?
  private var active = false
  private var pending = false
  private var framesPerSecond = 60
  private let draw: () -> Void

  init(draw: @escaping () -> Void) { self.draw = draw }

  var isActive: Bool { active }

  isolated deinit { link?.invalidate() }

  func configure(active: Bool, framesPerSecond: Int) {
    self.active = active
    self.framesPerSecond = max(1, framesPerSecond)
    if let link { configureRate(link) }
    if active, pending { wake() } else { link?.isPaused = true }
  }

  func request() {
    pending = true
    if active { wake() }
  }

  private func wake() {
    if link == nil {
      let link = CADisplayLink(
        target: Target(self),
        selector: #selector(Target.tick)
      )
      configureRate(link)
      link.add(to: .main, forMode: .common)
      self.link = link
    }
    link?.isPaused = false
  }

  private func configureRate(_ link: CADisplayLink) {
    let maximum = Float(framesPerSecond)
    link.preferredFrameRateRange = CAFrameRateRange(
      minimum: min(60, maximum),
      maximum: maximum,
      preferred: maximum
    )
  }

  private func tick() {
    guard active, pending else {
      link?.isPaused = true;
      return
    }
    pending = false
    draw()
    // Keep the next callback scheduled while output is flowing. With no
    // further update it pauses without drawing, avoiding per-frame restarts.
  }

  @MainActor
  private final class Target: NSObject {
    weak var scheduler: DisplayDrawScheduler?
    init(_ scheduler: DisplayDrawScheduler) { self.scheduler = scheduler }

    @objc
    func tick() { scheduler?.tick() }
  }
}
#endif
