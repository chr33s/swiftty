#if os(iOS) && !targetEnvironment(macCatalyst)
import AVFoundation
import HostConnection
import SwiftUI
import UIKit

/// Scan Mac Code (MobileClient only). The camera starts only here, after
/// the user chose to scan, and stops on a valid code, dismissal or
/// backgrounding. Frames are inspected for QR metadata only; no image is
/// captured or stored. Camera refusal leaves pasting available.
struct ScanCodeView: View {
  let select: (HostCandidate) -> Void
  let paste: () -> Void
  let cancel: () -> Void

  @State
  private var access = AVCaptureDevice.authorizationStatus(for: .video)
  @State
  private var scanner = QRScanner()
  @Environment(\.scenePhase)
  private var scenePhase

  var body: some View {
    NavigationStack {
      VStack(spacing: 16) {
        switch access {
        case .authorized:
          CameraPreview(session: scanner.session)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .accessibilityLabel(Text("Camera viewfinder", bundle: #bundle))
          if let notice = scanner.notice {
            Label(notice, systemImage: "exclamationmark.triangle")
              .foregroundStyle(.orange).font(.footnote)
          }
          Text(
            "Point the camera at the code in the Mac's Connect a Device panel.",
            bundle: #bundle
          )
          .font(.footnote).foregroundStyle(.secondary)
        case .notDetermined:
          ProgressView(.localized("Asking for camera access…"))
        default:
          ContentUnavailableView(
            .localized("Camera Unavailable"),
            systemImage: "camera.badge.ellipsis",
            description: Text(
              access == .restricted
                ? "Camera use is restricted on this device."
                : "Allow camera access in Settings to scan, or paste the code instead."
            )
          )
          .accessibilityIdentifier("scan.unavailable")
        }
        Button(
          .localized("Paste Code Instead"),
          systemImage: "doc.on.clipboard",
          action: paste
        )
        .accessibilityIdentifier("scan.paste")
      }
      .padding().navigationTitle(.localized("Scan Mac Code"))
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button(.localized("Cancel"), action: close)
        }
      }
    }
    .task {
      if access == .notDetermined {
        _ = await AVCaptureDevice.requestAccess(for: .video)
        access = AVCaptureDevice.authorizationStatus(for: .video)
      }
      if access == .authorized { scanner.start(found: found) }
    }
    .onChange(of: scenePhase) { _, phase in
      switch phase {
      case .background: scanner.stop()
      case .active:
        access = AVCaptureDevice.authorizationStatus(for: .video)
        if access == .authorized { scanner.start(found: found) }
      default: break
      }
    }
    .onDisappear { scanner.stop() }
  }

  private func found(_ descriptor: HostConnectionDescriptor) {
    scanner.stop()
    select(HostCandidate(descriptor: descriptor))
  }

  private func close() {
    scanner.stop()
    cancel()
  }
}

/// Owns the capture session; decodes QR payloads with the bounded
/// descriptor decoder and reports the first valid one.
@MainActor
@Observable
final class QRScanner: NSObject, AVCaptureMetadataOutputObjectsDelegate {
  /// Created on first use, not when the sheet's view is built: the
  /// view's `@State` initial value is evaluated on every parent redraw.
  @ObservationIgnored
  private(set) lazy var session = AVCaptureSession()
  private(set) var notice: String?
  @ObservationIgnored
  private var found: ((HostConnectionDescriptor) -> Void)?
  @ObservationIgnored
  private var configured = false
  @ObservationIgnored
  private let queue = DispatchQueue(label: "dev.swiftty.roaming.scan")
  @ObservationIgnored
  private var lastRejected: String?

  func start(found: @escaping (HostConnectionDescriptor) -> Void) {
    self.found = found
    if !configured {
      configured = true
      guard let device = AVCaptureDevice.default(for: .video),
        let input = try? AVCaptureDeviceInput(device: device),
        session.canAddInput(input)
      else {
        notice = String(
          localized: "The camera could not be started.",
          bundle: #bundle
        )
        return
      }
      session.beginConfiguration()
      session.addInput(input)
      let output = AVCaptureMetadataOutput()
      if session.canAddOutput(output) {
        session.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: .main)
        output.metadataObjectTypes = [.qr]
      }
      session.commitConfiguration()
    }
    let capture = Capture(session: session)
    queue.async {
      if !capture.session.isRunning { capture.session.startRunning() }
    }
  }

  func stop() {
    found = nil
    let capture = Capture(session: session)
    queue.async {
      if capture.session.isRunning { capture.session.stopRunning() }
    }
  }

  /// Start and stop run on one serial queue, as AVFoundation requires.
  ///
  /// Sendable: none: immutable after init. The session is configured on the
  /// main actor before being sent, then started and stopped only on `queue`;
  /// each queued block retains the session through its copy of this value.
  private struct Capture: @unchecked Sendable { let session: AVCaptureSession }

  nonisolated func metadataOutput(
    _ output: AVCaptureMetadataOutput,
    didOutput objects: [AVMetadataObject],
    from connection: AVCaptureConnection
  ) {
    let payloads = objects.compactMap {
      ($0 as? AVMetadataMachineReadableCodeObject)?.stringValue
    }
    MainActor.assumeIsolated {
      for payload in payloads { self.consider(payload) }
    }
  }

  private func consider(_ payload: String) {
    guard let found, payload.utf8.count <= HostConnectionDescriptor.maxBytes
    else { return }
    do {
      let descriptor = try HostConnectionDescriptor.decode(payload)
      self.found = nil
      found(descriptor)
    } catch {
      guard payload != lastRejected else { return }
      lastRejected = payload
      notice = error.message
    }
  }
}

/// The live viewfinder; displays frames without recording them.
private struct CameraPreview: UIViewRepresentable {
  let session: AVCaptureSession

  func makeUIView(context: Context) -> PreviewView {
    let view = PreviewView()
    view.previewLayer.session = session
    view.previewLayer.videoGravity = .resizeAspectFill
    return view
  }

  func updateUIView(_ view: PreviewView, context: Context) {}

  final class PreviewView: UIView {
    override static var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var previewLayer: AVCaptureVideoPreviewLayer {
      layer as! AVCaptureVideoPreviewLayer
    }
  }
}
#endif
