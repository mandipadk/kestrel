import AVFoundation
import SwiftUI
import UIKit

/// Full-height sheet with the camera, looking for a Kestrel setup code.
struct ScannerSheet: View {
    let onCode: (String) -> Void
    @Environment(\.dismiss) var dismiss
    @State private var denied = AVCaptureDevice.authorizationStatus(for: .video) == .denied

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if denied {
                VStack(spacing: 16) {
                    Image(systemName: "camera").font(.system(size: 28)).foregroundStyle(Ink.muted)
                    Text("Kestrel needs the camera to read the code.").font(.geist(16)).multilineTextAlignment(.center)
                    Button("Open Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                    }
                    .font(.geist(16, .semibold))
                    .foregroundStyle(Ink.accent)
                }
                .padding(32)
            } else {
                CameraView(onCode: onCode).ignoresSafeArea()
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(Color.white.opacity(0.9), lineWidth: 2)
                    .frame(width: 248, height: 248)
                VStack {
                    Spacer()
                    Text("Point at the code on the Kestrel page")
                        .font(.geist(15, .medium))
                        .padding(.horizontal, 16).padding(.vertical, 10)
                        .background(.black.opacity(0.6), in: Capsule())
                        .padding(.bottom, 48)
                }
            }
            VStack {
                HStack {
                    Spacer()
                    Button { dismiss() } label: {
                        Image(systemName: "xmark").font(.system(size: 15, weight: .semibold))
                            .frame(width: 44, height: 44)
                            .background(.black.opacity(0.5), in: Circle())
                    }
                    .accessibilityLabel("Close")
                }
                Spacer()
            }
            .padding(16)
        }
        .foregroundStyle(Ink.ink)
    }
}

struct CameraView: UIViewControllerRepresentable {
    let onCode: (String) -> Void
    func makeUIViewController(context: Context) -> CameraController { CameraController(onCode: onCode) }
    func updateUIViewController(_ vc: CameraController, context: Context) {}
}

final class CameraController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    private let session = AVCaptureSession()
    private let onCode: (String) -> Void
    private var done = false

    init(onCode: @escaping (String) -> Void) {
        self.onCode = onCode
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else { return }
        session.addInput(input)
        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else { return }
        session.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: .main)
        output.metadataObjectTypes = [.qr]
        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.videoGravity = .resizeAspectFill
        preview.frame = view.bounds
        view.layer.addSublayer(preview)
        DispatchQueue.global(qos: .userInitiated).async { self.session.startRunning() }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        view.layer.sublayers?.first?.frame = view.bounds
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if session.isRunning { session.stopRunning() }
    }

    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput objects: [AVMetadataObject], from connection: AVCaptureConnection) {
        guard !done,
              let code = (objects.first as? AVMetadataMachineReadableCodeObject)?.stringValue,
              code.hasPrefix("kestrel1:") else { return }
        done = true
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        onCode(code)
    }
}
