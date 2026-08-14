import AVFoundation
import Cocoa
import CoreGraphics
import FlutterMacOS
import ImageIO
import ScreenCaptureKit
import Speech

private enum InteractiveCaptureMode {
  case region
  case window
}

private enum CaptureSelection {
  case region(NSRect)
  case window(NSPoint)
}

private final class InteractiveCaptureView: NSView {
  private let mode: InteractiveCaptureMode
  private let completion: (CaptureSelection?) -> Void
  private var startPoint: NSPoint?
  private var currentPoint: NSPoint?

  init(frame: NSRect, mode: InteractiveCaptureMode, completion: @escaping (CaptureSelection?) -> Void) {
    self.mode = mode
    self.completion = completion
    super.init(frame: frame)
    wantsLayer = true
    layer?.backgroundColor = NSColor.black.withAlphaComponent(0.08).cgColor
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override var acceptsFirstResponder: Bool { true }

  override func mouseDown(with event: NSEvent) {
    let point = convert(event.locationInWindow, from: nil)
    startPoint = point
    currentPoint = point
    needsDisplay = true
  }

  override func mouseDragged(with event: NSEvent) {
    currentPoint = convert(event.locationInWindow, from: nil)
    needsDisplay = true
  }

  override func mouseUp(with event: NSEvent) {
    let point = convert(event.locationInWindow, from: nil)
    switch mode {
    case .window:
      // Use AppKit's global mouse position directly. Converting through the
      // temporary selection panel can produce an offset when the panel is on
      // a Retina display, a secondary display, or a space with a different
      // origin. Window lookup below converts this global AppKit point to the
      // Core Graphics coordinate space.
      completion(.window(NSEvent.mouseLocation))
    case .region:
      guard let startPoint else {
        completion(nil)
        return
      }
      let rect = NSRect(
        x: min(startPoint.x, point.x),
        y: min(startPoint.y, point.y),
        width: abs(point.x - startPoint.x),
        height: abs(point.y - startPoint.y)
      )
      completion(rect.width > 4 && rect.height > 4 ? .region(rect) : nil)
    }
  }

  override func keyDown(with event: NSEvent) {
    if event.keyCode == 53 { completion(nil) } else { super.keyDown(with: event) }
  }

  override func draw(_ dirtyRect: NSRect) {
    super.draw(dirtyRect)
    guard mode == .region, let startPoint, let currentPoint else { return }
    let rect = NSRect(
      x: min(startPoint.x, currentPoint.x),
      y: min(startPoint.y, currentPoint.y),
      width: abs(currentPoint.x - startPoint.x),
      height: abs(currentPoint.y - startPoint.y)
    )
    NSColor.white.setStroke()
    let path = NSBezierPath(rect: rect)
    path.lineWidth = 2
    path.stroke()
  }
}

final class RecorderOverlayController: NSObject {
  static let shared = RecorderOverlayController()

  private weak var flutterViewController: FlutterViewController?
  private var channel: FlutterMethodChannel?
  private var panel: NSPanel?
  private var toolbarPosition: NSPoint?
  private var interactivePanel: NSPanel?
  private var captureLabel: NSTextField?
  private var confirmationGeneration = 0
  private var screenCaptureAccessRequested = false
  private var voiceButton: NSButton?
  private var audioEngine: AVAudioEngine?
  private var recognitionTask: SFSpeechRecognitionTask?
  private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
  private var transcript = ""
  private var recognizedTranscript = ""
  private var segmentStartTranscript = ""

  func configure(with controller: FlutterViewController) {
    flutterViewController = controller
    channel = FlutterMethodChannel(
      name: "screenshot_story_recorder/overlay",
      binaryMessenger: controller.engine.binaryMessenger
    )
    channel?.setMethodCallHandler { [weak self] call, result in
      switch call.method {
      case "showToolbar":
        self?.showToolbar()
        result(nil)
      case "hideToolbar":
        if let panel = self?.panel {
          self?.toolbarPosition = panel.frame.origin
          panel.orderOut(nil)
        }
        result(nil)
      case "captureConfirmation":
        self?.showCaptureConfirmation(call.arguments as? String ?? "")
        result(nil)
      case "captureScreen":
        guard let arguments = call.arguments as? [String: Any],
              let path = arguments["path"] as? String else {
          result(FlutterError(code: "INVALID_PATH", message: "Kein Bildpfad", details: nil))
          return
        }
        self?.captureScreen(to: path) { error in
          if let error {
            result(FlutterError(code: "CAPTURE_FAILED", message: error.localizedDescription, details: nil))
          } else {
            result(nil)
          }
        }
      case "captureRegion":
        guard let arguments = call.arguments as? [String: Any],
              let path = arguments["path"] as? String else {
          result(FlutterError(code: "INVALID_PATH", message: "Kein Bildpfad", details: nil))
          return
        }
        self?.beginInteractiveCapture(mode: .region, path: path, result: result)
      case "captureWindow":
        guard let arguments = call.arguments as? [String: Any],
              let path = arguments["path"] as? String else {
          result(FlutterError(code: "INVALID_PATH", message: "Kein Bildpfad", details: nil))
          return
        }
        self?.beginInteractiveCapture(mode: .window, path: path, result: result)
      case "voiceBoundary":
        result(self?.finishVoiceSegment() ?? "")
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  private func showToolbar() {
    if panel == nil { createPanel() }
    guard let panel else { return }
    if let toolbarPosition {
      panel.setFrameOrigin(toolbarPosition)
    } else if let screen = NSScreen.main {
      let visible = screen.visibleFrame
      let initialPosition = NSPoint(
        x: visible.maxX - panel.frame.width - 24,
        y: visible.maxY - panel.frame.height - 24
      )
      self.toolbarPosition = initialPosition
      panel.setFrameOrigin(initialPosition)
    }
    panel.orderFrontRegardless()
  }

  private func createPanel() {
    let photo = NSButton(title: "📸 Foto", target: self, action: #selector(capture))
    photo.bezelStyle = .texturedRounded
    let region = NSButton(title: "✂️ Auswahl", target: self, action: #selector(captureRegion))
    region.bezelStyle = .texturedRounded
    let window = NSButton(title: "▣ Fenster", target: self, action: #selector(captureWindow))
    window.bezelStyle = .texturedRounded
    let voice = NSButton(title: "🎙 Voice", target: self, action: #selector(toggleVoice))
    voice.bezelStyle = .texturedRounded
    voiceButton = voice
    let confirmation = NSTextField(labelWithString: "")
    confirmation.textColor = .white
    confirmation.font = NSFont.systemFont(ofSize: 12, weight: .medium)
    confirmation.lineBreakMode = .byTruncatingTail
    confirmation.isHidden = true
    confirmation.setContentHuggingPriority(.defaultLow, for: .horizontal)
    captureLabel = confirmation

    let stack = NSStackView(views: [photo, region, window, voice, confirmation])
    stack.orientation = .horizontal
    stack.spacing = 8
    stack.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)

    let panel = NSPanel(
      contentRect: NSRect(x: 0, y: 0, width: 520, height: 46),
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false
    )
    panel.contentView = stack
    stack.frame = panel.contentView?.bounds ?? .zero
    stack.autoresizingMask = [.width, .height]
    panel.isFloatingPanel = true
    panel.level = .floating
    panel.hidesOnDeactivate = false
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    panel.backgroundColor = NSColor(calibratedWhite: 0.08, alpha: 0.96)
    panel.isOpaque = false
    panel.hasShadow = true
    panel.isMovableByWindowBackground = true
    self.panel = panel
  }

  private func showCaptureConfirmation(_ text: String) {
    if panel == nil { createPanel() }
    captureLabel?.stringValue = text
    captureLabel?.isHidden = false
    confirmationGeneration += 1
    let generation = confirmationGeneration
    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
      guard let self, self.confirmationGeneration == generation else { return }
      self.captureLabel?.isHidden = true
    }
  }

  @objc private func capture() {
    channel?.invokeMethod("capture", arguments: "screen")
  }

  @objc private func captureRegion() {
    channel?.invokeMethod("capture", arguments: "region")
  }

  @objc private func captureWindow() {
    channel?.invokeMethod("capture", arguments: "window")
  }

  private func captureScreen(to path: String, completion: @escaping (Error?) -> Void) {
    guard #available(macOS 14.0, *) else {
      completion(NSError(domain: "ScreenCapture", code: 10, userInfo: [
        NSLocalizedDescriptionKey: "ScreenCaptureKit benötigt macOS 14 oder neuer."
      ]))
      return
    }
    do { try ensureScreenCaptureAccess() } catch { completion(error); return }
    SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { [weak self] content, error in
      guard let self else { return }
      guard let content, error == nil else {
        completion(error ?? self.captureError("Kein freigegebener Bildschirm gefunden."))
        return
      }
      let displayID = self.displayID(for: NSScreen.main ?? NSScreen.screens[0])
      guard let display = content.displays.first(where: { $0.displayID == displayID }) ?? content.displays.first else {
        completion(self.captureError("Kein freigegebener Bildschirm gefunden."))
        return
      }
      let filter = SCContentFilter(display: display, excludingWindows: [])
      let configuration = self.screenshotConfiguration(width: display.width, height: display.height)
      SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration) { image, error in
        guard let image, error == nil else {
          completion(error ?? self.captureError("Der Bildschirm konnte nicht aufgenommen werden."))
          return
        }
        do {
          try self.saveImage(image, to: path)
          completion(nil)
        } catch { completion(error) }
      }
    }
  }

  @available(macOS 14.0, *)
  private func screenshotConfiguration(width: Int, height: Int, sourceRect: CGRect = .zero) -> SCStreamConfiguration {
    let configuration = SCStreamConfiguration()
    configuration.width = max(width, 1)
    configuration.height = max(height, 1)
    configuration.sourceRect = sourceRect
    configuration.showsCursor = false
    configuration.capturesAudio = false
    return configuration
  }

  private func captureError(_ message: String) -> NSError {
    NSError(domain: "ScreenCapture", code: 11, userInfo: [NSLocalizedDescriptionKey: message])
  }

  private func saveImage(_ image: CGImage, to path: String) throws {
    let url = URL(fileURLWithPath: path) as CFURL
    guard let destination = CGImageDestinationCreateWithURL(
      url,
      "public.png" as CFString,
      1,
      nil
    ) else {
      throw NSError(domain: "ScreenCapture", code: 2, userInfo: [
        NSLocalizedDescriptionKey: "Die PNG-Datei konnte nicht erstellt werden."
      ])
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
      throw NSError(domain: "ScreenCapture", code: 3, userInfo: [
        NSLocalizedDescriptionKey: "Die PNG-Datei konnte nicht gespeichert werden."
      ])
    }
  }

  private func beginInteractiveCapture(
    mode: InteractiveCaptureMode,
    path: String,
    result: @escaping FlutterResult
  ) {
    do {
      try ensureScreenCaptureAccess()
    } catch {
      result(FlutterError(code: "SCREEN_CAPTURE_DENIED", message: error.localizedDescription, details: nil))
      return
    }
    guard let screen = NSScreen.main else {
      result(FlutterError(code: "NO_SCREEN", message: "Kein Bildschirm gefunden", details: nil))
      return
    }

    let selectionView = InteractiveCaptureView(
      frame: screen.frame,
      mode: mode
    ) { [weak self] selection in
      self?.finishInteractiveCapture(selection, mode: mode, screen: screen, path: path, result: result)
    }
    let overlay = NSPanel(
      contentRect: screen.frame,
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false
    )
    overlay.level = .screenSaver
    overlay.isOpaque = false
    overlay.backgroundColor = .clear
    overlay.hasShadow = false
    overlay.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    overlay.contentView = selectionView
    interactivePanel = overlay
    overlay.makeKeyAndOrderFront(nil)
    selectionView.window?.makeFirstResponder(selectionView)
  }

  private func ensureScreenCaptureAccess() throws {
    if #available(macOS 10.15, *) {
      // This method is reached only from the user-initiated capture action.
      // The bundle identifier is part of macOS TCC's identity. After an app
      // rename or a new build identity, macOS may need a fresh approval.
      guard !CGPreflightScreenCaptureAccess() else { return }

      if !screenCaptureAccessRequested {
        // CGRequestScreenCaptureAccess() returns before the user finishes the
        // Settings dialog. Do not start ScreenCaptureKit in this same call;
        // the permission is not active until the user approves it and, on
        // macOS versions affected by TCC caching, restarts the app.
        screenCaptureAccessRequested = true
        _ = CGRequestScreenCaptureAccess()
        throw captureError(
          "Bildschirmaufnahme wurde angefordert. Bitte S2S in den macOS-Systemeinstellungen erlauben und anschließend neu starten."
        )
      }

      // The request was already shown during this app run. Avoid opening the
      // prompt repeatedly and never attempt a capture without an active grant.
      throw captureError(
        "Bildschirmaufnahme ist noch nicht aktiv. Bitte S2S nach der Freigabe in den macOS-Systemeinstellungen neu starten."
      )
    }
  }

  private func finishInteractiveCapture(
    _ selection: CaptureSelection?,
    mode: InteractiveCaptureMode,
    screen: NSScreen,
    path: String,
    result: @escaping FlutterResult
  ) {
    interactivePanel?.orderOut(nil)
    interactivePanel = nil
    guard let selection else {
      result(FlutterError(code: "CAPTURE_CANCELLED", message: "Aufnahme abgebrochen", details: nil))
      return
    }
    guard #available(macOS 14.0, *) else {
      result(FlutterError(code: "CAPTURE_FAILED", message: "ScreenCaptureKit benötigt macOS 14 oder neuer.", details: nil))
      return
    }

    DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
      guard let self else { return }
      switch (mode, selection) {
      case let (.region, .region(rect)):
        let globalRect = rect.offsetBy(dx: screen.frame.minX, dy: screen.frame.minY)
        self.captureRegion(globalRect: globalRect, screen: screen, path: path, result: result)
      case let (.window, .window(point)):
        self.captureWindow(at: point, path: path, result: result)
      default:
        result(FlutterError(code: "CAPTURE_FAILED", message: "Ungültige Auswahl.", details: nil))
      }
    }
  }

  private func imageForWindow(at point: CGPoint) -> CGImage? {
    guard let windows = CGWindowListCopyWindowInfo(
      [.optionOnScreenOnly, .excludeDesktopElements],
      kCGNullWindowID
    ) as? [[String: Any]] else { return nil }
    let ownProcessID = ProcessInfo.processInfo.processIdentifier
    for window in windows {
      let layer = (window[kCGWindowLayer as String] as? NSNumber)?.intValue ?? -1
      let alpha = (window[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 0
      let ownerProcessID = (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value
      guard layer == 0, alpha > 0,
            ownerProcessID != ownProcessID,
            let bounds = window[kCGWindowBounds as String] as? NSDictionary else { continue }
      var rect = CGRect.zero
      guard CGRectMakeWithDictionaryRepresentation(bounds, &rect),
            rect.width > 80, rect.height > 60,
            // The user can naturally click on a window shadow or a one-pixel
            // title-bar edge. Allow a small hit tolerance while retaining
            // front-to-back ordering from CGWindowListCopyWindowInfo.
            rect.insetBy(dx: -8, dy: -8).contains(point),
            let number = (window[kCGWindowNumber as String] as? NSNumber)?.uint32Value else { continue }
      return CGWindowListCreateImage(
        .null,
        .optionIncludingWindow,
        number,
        [.bestResolution, .boundsIgnoreFraming]
      )
    }
    return nil
  }

  @available(macOS 14.0, *)
  private func captureRegion(globalRect: NSRect, screen: NSScreen, path: String, result: @escaping FlutterResult) {
    SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { [weak self] content, error in
      guard let self else { return }
      guard let content, error == nil else {
        result(FlutterError(code: "CAPTURE_FAILED", message: error?.localizedDescription ?? "Kein freigegebener Bildschirm gefunden.", details: nil))
        return
      }
      let displayID = self.displayID(for: screen)
      guard let display = content.displays.first(where: { $0.displayID == displayID }) ?? content.displays.first else {
        result(FlutterError(code: "CAPTURE_FAILED", message: "Kein freigegebener Bildschirm gefunden.", details: nil))
        return
      }
      let quartzRect = self.quartzRect(for: globalRect)
      let displayFrame = display.frame
      let sourceRect = CGRect(
        x: quartzRect.minX - displayFrame.minX,
        y: quartzRect.minY - displayFrame.minY,
        width: quartzRect.width,
        height: quartzRect.height
      )
      let scale = CGFloat(display.width) / max(displayFrame.width, 1)
      let filter = SCContentFilter(display: display, excludingWindows: [])
      let configuration = self.screenshotConfiguration(
        width: Int(sourceRect.width * scale),
        height: Int(sourceRect.height * scale),
        sourceRect: sourceRect
      )
      SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration) { image, error in
        guard let image, error == nil else {
          result(FlutterError(code: "CAPTURE_FAILED", message: error?.localizedDescription ?? "Der ausgewählte Bereich konnte nicht aufgenommen werden.", details: nil))
          return
        }
        do {
          try self.saveImage(image, to: path)
          result(nil)
        } catch {
          result(FlutterError(code: "CAPTURE_FAILED", message: error.localizedDescription, details: nil))
        }
      }
    }
  }

  @available(macOS 14.0, *)
  private func captureWindow(at point: NSPoint, path: String, result: @escaping FlutterResult) {
    let quartzPoint = quartzPoint(for: point)
    guard let windowID = windowIDForWindow(at: quartzPoint) else {
      result(FlutterError(code: "CAPTURE_FAILED", message: "Kein Fenster an dieser Stelle gefunden.", details: nil))
      return
    }
    SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { [weak self] content, error in
      guard let self else { return }
      guard let content, error == nil else {
        result(FlutterError(code: "CAPTURE_FAILED", message: error?.localizedDescription ?? "Fenster konnten nicht ermittelt werden.", details: nil))
        return
      }
      guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
        result(FlutterError(code: "CAPTURE_FAILED", message: "Das ausgewählte Fenster ist nicht freigegeben.", details: nil))
        return
      }
      let filter = SCContentFilter(desktopIndependentWindow: window)
      let scale = CGFloat(max(filter.pointPixelScale, 1))
      let configuration = self.screenshotConfiguration(
        width: Int(window.frame.width * scale),
        height: Int(window.frame.height * scale)
      )
      SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration) { image, error in
        guard let image, error == nil else {
          result(FlutterError(code: "CAPTURE_FAILED", message: error?.localizedDescription ?? "Das Fenster konnte nicht aufgenommen werden.", details: nil))
          return
        }
        do {
          try self.saveImage(image, to: path)
          result(nil)
        } catch {
          result(FlutterError(code: "CAPTURE_FAILED", message: error.localizedDescription, details: nil))
        }
      }
    }
  }

  private func windowIDForWindow(at point: CGPoint) -> CGWindowID? {
    guard let windows = CGWindowListCopyWindowInfo(
      [.optionOnScreenOnly, .excludeDesktopElements],
      kCGNullWindowID
    ) as? [[String: Any]] else { return nil }
    let ownProcessID = ProcessInfo.processInfo.processIdentifier
    for window in windows {
      let layer = (window[kCGWindowLayer as String] as? NSNumber)?.intValue ?? -1
      let alpha = (window[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 0
      let ownerProcessID = (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value
      guard layer == 0, alpha > 0, ownerProcessID != ownProcessID,
            let bounds = window[kCGWindowBounds as String] as? NSDictionary else { continue }
      var rect = CGRect.zero
      guard CGRectMakeWithDictionaryRepresentation(bounds, &rect),
            rect.width > 80, rect.height > 60,
            // Include a small margin so a click on a window shadow or title
            // bar edge still resolves to the intended frontmost window.
            rect.insetBy(dx: -8, dy: -8).contains(point),
            let number = (window[kCGWindowNumber as String] as? NSNumber)?.uint32Value else { continue }
      return number
    }
    return nil
  }

  /// AppKit uses a bottom-left origin for screen points while Core Graphics
  /// uses a top-left origin for window-list bounds. Convert through the full
  /// virtual desktop, rather than assuming the main display starts at (0, 0).
  private func quartzPoint(for cocoaPoint: NSPoint) -> CGPoint {
    var displayCount: UInt32 = 0
    var displayList = [CGDirectDisplayID](repeating: 0, count: 16)
    guard CGGetActiveDisplayList(UInt32(displayList.count), &displayList, &displayCount) == .success,
          displayCount > 0 else {
      let display = CGDisplayBounds(CGMainDisplayID())
      return CGPoint(x: cocoaPoint.x, y: display.height - cocoaPoint.y)
    }

    var virtualBounds = CGRect.null
    for index in 0..<Int(displayCount) {
      virtualBounds = virtualBounds.union(CGDisplayBounds(displayList[index]))
    }
    return CGPoint(
      x: cocoaPoint.x - virtualBounds.minX,
      y: virtualBounds.maxY - cocoaPoint.y
    )
  }

  private func quartzRect(for cocoaRect: NSRect) -> CGRect {
    var displayCount: UInt32 = 0
    var displayList = [CGDirectDisplayID](repeating: 0, count: 16)
    guard CGGetActiveDisplayList(UInt32(displayList.count), &displayList, &displayCount) == .success,
          displayCount > 0 else {
      let display = CGDisplayBounds(CGMainDisplayID())
      return CGRect(
        x: cocoaRect.minX,
        y: display.maxY - cocoaRect.maxY,
        width: cocoaRect.width,
        height: cocoaRect.height
      )
    }

    var virtualBounds = CGRect.null
    for index in 0..<Int(displayCount) {
      virtualBounds = virtualBounds.union(CGDisplayBounds(displayList[index]))
    }
    return CGRect(
      x: cocoaRect.minX - virtualBounds.minX,
      y: virtualBounds.maxY - cocoaRect.maxY,
      width: cocoaRect.width,
      height: cocoaRect.height
    )
  }

  private func displayID(for screen: NSScreen) -> CGDirectDisplayID {
    let key = NSDeviceDescriptionKey("NSScreenNumber")
    return (screen.deviceDescription[key] as? NSNumber)?.uint32Value ?? CGMainDisplayID()
  }

  @objc private func toggleVoice() {
    if audioEngine?.isRunning == true {
      stopVoice()
    } else {
      startVoice()
    }
  }

  private func startVoice() {
    guard let speechUsage = Bundle.main.object(forInfoDictionaryKey: "NSSpeechRecognitionUsageDescription") as? String,
          !speechUsage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
          let microphoneUsage = Bundle.main.object(forInfoDictionaryKey: "NSMicrophoneUsageDescription") as? String,
          !microphoneUsage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      channel?.invokeMethod("voiceState", arguments: "error")
      return
    }
    SFSpeechRecognizer.requestAuthorization { [weak self] authorization in
      guard let self else { return }
      DispatchQueue.main.async {
        guard authorization == .authorized else {
          self.channel?.invokeMethod("voiceState", arguments: "error")
          return
        }
        self.beginVoiceCapture()
      }
    }
  }

  private func beginVoiceCapture() {
    guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "de-DE")),
          recognizer.supportsOnDeviceRecognition else {
      channel?.invokeMethod("voiceState", arguments: "localUnavailable")
      return
    }
    guard recognizer.isAvailable else {
      channel?.invokeMethod("voiceState", arguments: "localUnavailable")
      return
    }
    let engine = AVAudioEngine()
    let request = SFSpeechAudioBufferRecognitionRequest()
    request.requiresOnDeviceRecognition = true
    request.shouldReportPartialResults = true
    let input = engine.inputNode
    input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { buffer, _ in
      request.append(buffer)
    }
    recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
      if let result, let self {
        let fullText = result.bestTranscription.formattedString
        self.recognizedTranscript = fullText
        if fullText.hasPrefix(self.segmentStartTranscript) {
          self.transcript = String(fullText.dropFirst(self.segmentStartTranscript.count))
        } else {
          // Speech recognition can revise punctuation/spacing at a boundary.
          // In that case use the current result as the new segment instead of
          // appending the previous segment again.
          self.segmentStartTranscript = ""
          self.transcript = fullText
        }
      }
      if error != nil { self?.stopVoice() }
    }
    do {
      try engine.start()
      audioEngine = engine
      recognitionRequest = request
      transcript = ""
      recognizedTranscript = ""
      segmentStartTranscript = ""
      voiceButton?.title = "⏹ Stop"
      channel?.invokeMethod("voiceState", arguments: "recording")
    } catch {
      input.removeTap(onBus: 0)
      channel?.invokeMethod("voiceState", arguments: "error")
    }
  }

  private func stopVoice() {
    audioEngine?.stop()
    audioEngine?.inputNode.removeTap(onBus: 0)
    recognitionRequest?.endAudio()
    recognitionTask?.cancel()
    audioEngine = nil
    recognitionRequest = nil
    recognitionTask = nil
    voiceButton?.title = "🎙 Voice"
    let text = finishVoiceSegment()
    if !text.isEmpty { channel?.invokeMethod("voiceText", arguments: text) }
    channel?.invokeMethod("voiceState", arguments: "idle")
  }

  /// Ends the current spoken comment without stopping the microphone or
  /// speech recognizer. A new segment starts immediately with the next words.
  private func finishVoiceSegment() -> String {
    let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
    segmentStartTranscript = recognizedTranscript
    transcript = ""
    return text
  }
}
