import Cocoa
import AVFoundation
import CoreAudio
import Carbon.HIToolbox

// Playback — 書き出した動画を、外部モニターに全画面で出して再生するための小さな再生ソフト。
//   Playback [動画.mov]
//   Playback --self-test 動画.mov    画面を出さずに、動画が読めるか・長さ・音の出力先を確かめて終わる
// 窓は手元の操作用(小さな確認画面つき)。「外部モニターに出す」で、選んだ画面いっぱいに同じ映像を出す。
// 音は Mac の「サウンド」で選んである出力先から出る。このソフトでは出力先の名前を表示するだけで、切り替えはしない。

/// Mac でいま選ばれている音の出力先の名前
func defaultOutputName() -> String {
    var id = AudioDeviceID(0), size = UInt32(MemoryLayout<AudioDeviceID>.size)
    var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id) == noErr else { return "不明" }
    var name: Unmanaged<CFString>?
    var nsize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    var naddr = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    guard AudioObjectGetPropertyData(id, &naddr, 0, nil, &nsize, &name) == noErr, let n = name?.takeRetainedValue() else { return "不明" }
    var rate = Float64(0), rsize = UInt32(MemoryLayout<Float64>.size)
    var raddr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    AudioObjectGetPropertyData(id, &raddr, 0, nil, &rsize, &rate)
    return rate > 0 ? String(format: "%@(%.0f Hz)", n as String, rate) : n as String
}

/// 映像を写す画面。上に、フラッシュ用の白と、フェード用の黒を重ねられる
/// 絵は AVPlayerLayer ではなく、再生機から取り出したコマをそのまま貼る(1 台の再生機を 2 つの AVPlayerLayer につなぐと、片方にしか絵が出ないため)
final class VideoView: NSView {
    let playerLayer = CALayer()
    private let white = CALayer(), black = CALayer()
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        playerLayer.contentsGravity = .resizeAspect
        playerLayer.backgroundColor = NSColor.black.cgColor
        white.backgroundColor = NSColor.white.cgColor; white.opacity = 0
        black.backgroundColor = NSColor.black.cgColor; black.opacity = 0
        for l in [playerLayer, black, white] { layer?.addSublayer(l) }
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for l in [playerLayer, black, white] { l.frame = bounds }
        CATransaction.commit()
    }
    /// いまのコマを貼る
    func show(_ surface: IOSurfaceRef) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        playerLayer.contents = surface
        CATransaction.commit()
    }
    /// 一瞬だけ画面全体を白くする(出力の確認用)
    func flash() {
        let a = CABasicAnimation(keyPath: "opacity")
        a.fromValue = 1; a.toValue = 0; a.duration = 0.35
        white.add(a, forKey: "flash")
    }
    /// 黒をかぶせる量(0 = 映像そのまま, 1 = 真っ黒)
    func setDim(_ v: Float) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        black.opacity = v
        CATransaction.commit()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let player = AVPlayer()
    var window: NSWindow!
    let preview = VideoView(frame: .zero)
    var outWindow: NSWindow?, outView: VideoView?
    var screenPopup: NSPopUpButton!, outButton: NSButton!, playButton: NSButton!
    var seek: NSSlider!, timeLabel: NSTextField!, audioLabel: NSTextField!, fileLabel: NSTextField!
    var fadeField: NSTextField!
    var outStatus: NSTextField!
    var brightSlider: NSSlider!, volumeSlider: NSSlider!, brightLabel: NSTextField!, volumeLabel: NSTextField!
    var bright = Float(1), volume = Float(1)           // 映像の明るさ(0 = 真っ黒)と音量(0 = 無音)
    var duration = 0.0, seeking = false
    var fadeTimer: Timer?
    let engine = AVAudioEngine()
    var toneLeft = 0, tonePhase = 0.0
    var startURL: URL?
    // 出力している間だけ有効にする Esc のホットキー。ほかのアプリが手前にあっても、入力欄にカーソルがあっても効く
    var escHotKey: EventHotKeyRef?, escHandlerInstalled = false
    func setEscHotKey(_ on: Bool) {
        if on, escHotKey == nil {
            if !escHandlerInstalled {
                escHandlerInstalled = true
                var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
                InstallEventHandler(GetApplicationEventTarget(), { _, _, ctx in
                    let me = Unmanaged<AppDelegate>.fromOpaque(ctx!).takeUnretainedValue()
                    DispatchQueue.main.async { me.closeOutput() }
                    return noErr
                }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), nil)
            }
            RegisterEventHotKey(UInt32(kVK_Escape), 0, EventHotKeyID(signature: OSType(0x504C4259), id: 1), GetApplicationEventTarget(), 0, &escHotKey)
        } else if !on, let h = escHotKey {
            UnregisterEventHotKey(h); escHotKey = nil
        }
    }
    var videoOut: AVPlayerItemVideoOutput?, lastSurface: IOSurfaceRef?, lastBuffer: CVPixelBuffer?, framesShown = 0

    func applicationDidFinishLaunching(_ n: Notification) {
        buildMenu(); buildWindow()
        // 再生機から 1 コマずつ絵を取り出して、手元の確認画面と出力先の両方に貼る
        let pump = Timer(timeInterval: 1 / 120.0, repeats: true) { [weak self] _ in self?.pumpFrame() }
        RunLoop.main.add(pump, forMode: .common)
        player.actionAtItemEnd = .pause
        player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 10), queue: .main) { [weak self] t in self?.tick(t.seconds) }
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        // Mac の出力先が切り替わったら、表示を追いかける
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, .main) { [weak self] _, _ in self?.refreshAudio() }
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.refreshAudio() }
        refreshAudio(); refreshScreens()
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in (self?.key(e) ?? false) ? nil : e }
        if let u = startURL { open(u) }
        // --output を付けて起動したら、外部の画面があれば、すぐそこへ全画面で出す
        if CommandLine.arguments.contains("--output"), NSScreen.screens.count > 1, ProcessInfo.processInfo.environment["PLAYBACK_TEST"] == nil {
            screenPopup.selectItem(at: 1); toggleOutput(nil)
        }
        // 出力の自己確認(PLAYBACK_TEST=1): いちばん最後の画面へ出力して 4 秒再生し、出力先の窓の位置と、届いたコマ数を出して終わる
        if ProcessInfo.processInfo.environment["PLAYBACK_TEST"] != nil {
            screenPopup.selectItem(at: NSScreen.screens.count - 1)
            toggleOutput(nil); player.seek(to: CMTime(seconds: 60, preferredTimescale: 600)); player.play()
            DispatchQueue.main.asyncAfter(deadline: .now() + (Double(ProcessInfo.processInfo.environment["PLAYBACK_TEST"] ?? "") ?? 4)) {
                let w = self.outWindow
                if ProcessInfo.processInfo.environment["PLAYBACK_ESC"] != nil {       // Esc のホットキーの確認: キーを 1 回送って、出力が閉じるかを見る
                    let src = CGEventSource(stateID: .hidSystemState)
                    CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(kVK_Escape), keyDown: true)?.post(tap: .cghidEventTap)
                    CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(kVK_Escape), keyDown: false)?.post(tap: .cghidEventTap)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { print("Esc を送ったあと: 出力は" + (self.outWindow == nil ? "閉じた" : "開いたまま") + "  ホットキー登録=" + (self.escHotKey == nil ? "なし" : "あり")); exit(0) }
                    return
                }
                print(String(format: "画面の数 %d  出力先 %@  窓の枠 %@  画面の枠 %@  窓は表示中=%@  届いたコマ %d  再生位置 %.1f 秒",
                             NSScreen.screens.count, w?.screen?.localizedName ?? "なし", NSStringFromRect(w?.frame ?? .zero), NSStringFromRect(w?.screen?.frame ?? .zero),
                             (w?.isVisible ?? false) ? "はい" : "いいえ", self.framesShown, self.player.currentTime().seconds))
                if let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] {
                    for i in info where (i[kCGWindowOwnerName as String] as? String) == "Playback" { print("  画面上の窓:", i[kCGWindowBounds as String] ?? "", "layer", i[kCGWindowLayer as String] ?? "") }
                }
                exit(0)
            }
        }
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ a: NSApplication) -> Bool { true }
    func windowWillClose(_ n: Notification) { if (n.object as? NSWindow) === window { closeOutput() } }

    // ---------- 動画 ----------
    func pumpFrame() {
        guard let vo = videoOut else { return }
        let t = vo.itemTime(forHostTime: CACurrentMediaTime())
        guard vo.hasNewPixelBuffer(forItemTime: t), let pb = vo.copyPixelBuffer(forItemTime: t, itemTimeForDisplay: nil),
              let sf = CVPixelBufferGetIOSurface(pb)?.takeUnretainedValue() else { return }
        lastSurface = sf; lastBuffer = pb; framesShown += 1
        preview.show(sf); outView?.show(sf)
    }
    func open(_ url: URL) {
        let item = AVPlayerItem(url: url)
        let vo = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()])
        item.add(vo); videoOut = vo; lastSurface = nil
        player.replaceCurrentItem(with: item)
        resetFade()
        fileLabel.stringValue = url.lastPathComponent
        window.title = "Playback — " + url.lastPathComponent
        Task { @MainActor in
            let d = (try? await item.asset.load(.duration).seconds) ?? 0
            self.duration = d.isFinite ? d : 0
            self.seek.maxValue = max(1, self.duration)
            self.tick(0)
        }
    }
    @objc func openFile(_ s: Any?) {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.movie]
        p.message = "再生する動画を選んでください"
        if p.runModal() == .OK, let u = p.url { open(u) }
    }
    @objc func togglePlay(_ s: Any?) {
        if player.rate != 0 { player.pause() } else {
            if duration > 0, player.currentTime().seconds >= duration - 0.05 { player.seek(to: .zero) }
            player.play()
        }
        tick(player.currentTime().seconds)
    }
    @objc func toStart(_ s: Any?) { player.pause(); player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero); resetFade() }
    @objc func seekChanged(_ s: NSSlider) {
        player.seek(to: CMTime(seconds: s.doubleValue, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }
    func tick(_ t: Double) {
        func f(_ x: Double) -> String { String(format: "%d:%04.1f", Int(x / 60), x - Double(Int(x / 60) * 60)) }
        timeLabel.stringValue = f(max(0, t)) + " / " + f(duration)
        if NSApp.currentEvent?.type != .leftMouseDragged { seek.doubleValue = t }
        playButton.title = player.rate != 0 ? "停止" : "再生"
    }

    // ---------- 映像の出力先 ----------
    @objc func screensChanged() {
        if let w = outWindow, !NSScreen.screens.contains(where: { $0 === w.screen }) { closeOutput() }   // 画面が抜かれたら出力を閉じる
        refreshScreens()
    }
    func refreshScreens() {
        let keep = screenPopup.indexOfSelectedItem
        screenPopup.removeAllItems()
        for (i, s) in NSScreen.screens.enumerated() {
            let main = s === NSScreen.screens.first
            screenPopup.addItem(withTitle: String(format: "%d: %@  %.0f×%.0f%@", i + 1, s.localizedName, s.frame.width * s.backingScaleFactor, s.frame.height * s.backingScaleFactor, main ? "(手元)" : ""))
        }
        // 外部の画面があれば、最初はそれを選ぶ
        if keep >= 0, keep < NSScreen.screens.count { screenPopup.selectItem(at: keep) } else { screenPopup.selectItem(at: NSScreen.screens.count > 1 ? 1 : 0) }
        outButton.title = outWindow == nil ? "外部モニターに全画面で出す" : "出力を止める"
        outStatus?.stringValue = outWindow.map { "出力中: " + ($0.screen?.localizedName ?? "?") } ?? "出力していません"
        outStatus?.textColor = outWindow == nil ? .secondaryLabelColor : .systemGreen
    }
    @objc func toggleOutput(_ s: Any?) {
        if outWindow != nil { closeOutput(); return }
        let i = max(0, screenPopup.indexOfSelectedItem)
        guard i < NSScreen.screens.count else { return }
        let screen = NSScreen.screens[i]
        // screen を渡すときの位置は「その画面の左下から」なので、原点 0 で作ってから、画面全体の枠に合わせる
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: screen.frame.size), styleMask: [.borderless], backing: .buffered, defer: false, screen: screen)
        w.level = .screenSaver; w.backgroundColor = .black; w.isReleasedWhenClosed = false
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        let v = VideoView(frame: NSRect(origin: .zero, size: screen.frame.size))
        if let sf = lastSurface { v.show(sf) }
        v.setDim(1 - bright)
        w.contentView = v
        w.setFrame(screen.frame, display: true)
        w.orderFrontRegardless()
        outWindow = w; outView = v
        setEscHotKey(true)
        window.makeKeyAndOrderFront(nil)                  // 操作は手元の窓で続ける
        refreshScreens()
    }
    func closeOutput() {
        setEscHotKey(false)
        outWindow?.orderOut(nil)
        outWindow = nil; outView = nil
        refreshScreens()
    }

    // ---------- 音の出力先(表示だけ) ----------
    func refreshAudio() { audioLabel.stringValue = defaultOutputName() }

    // ---------- 出力の確認 ----------
    @objc func flash(_ s: Any?) { preview.flash(); outView?.flash() }
    /// テスト音: 1 kHz の音を 1 秒(左 → 右 → 両方 の順に 0.33 秒ずつ)。Mac で選んである出力先から出る
    @objc func testTone(_ s: Any?) {
        if !engine.isRunning {
            let fmt = engine.outputNode.inputFormat(forBus: 0)
            let sr = fmt.sampleRate > 0 ? fmt.sampleRate : 48000
            let src = AVAudioSourceNode { [weak self] _, _, count, abl -> OSStatus in
                guard let self = self else { return noErr }
                let bufs = UnsafeMutableAudioBufferListPointer(abl)
                let total = Int(sr)
                for i in 0..<Int(count) {
                    var l: Float = 0, r: Float = 0
                    if self.toneLeft > 0 {
                        let done = total - self.toneLeft, part = done * 3 / total       // 0 = 左, 1 = 右, 2 = 両方
                        let pos = Double(done % (total / 3)) / Double(total / 3)
                        let env = Float(min(1, min(pos, 1 - pos) * 40))                  // 出だしと終わりをなめらかに
                        let v = Float(sin(self.tonePhase)) * 0.25 * env
                        self.tonePhase += 2 * .pi * 1000 / sr
                        l = part == 1 ? 0 : v; r = part == 0 ? 0 : v
                        self.toneLeft -= 1
                    }
                    for (c, b) in bufs.enumerated() { b.mData?.assumingMemoryBound(to: Float.self)[i] = c == 0 ? l : r }
                }
                return noErr
            }
            engine.attach(src)
            engine.connect(src, to: engine.mainMixerNode, format: AVAudioFormat(standardFormatWithSampleRate: sr, channels: 2))
            do { try engine.start() } catch { NSSound.beep(); return }
        }
        tonePhase = 0
        toneLeft = Int(engine.outputNode.inputFormat(forBus: 0).sampleRate > 0 ? engine.outputNode.inputFormat(forBus: 0).sampleRate : 48000)
    }

    // ---------- 映像の明るさと音量(別々に動かせる)、フェードアウト ----------
    func applyFade() {
        player.volume = volume
        preview.setDim(1 - bright); outView?.setDim(1 - bright)
        brightSlider?.floatValue = bright * 100; volumeSlider?.floatValue = volume * 100
        brightLabel?.stringValue = String(format: "%.0f%%", bright * 100); volumeLabel?.stringValue = String(format: "%.0f%%", volume * 100)
    }
    @objc func brightChanged(_ s: NSSlider) { stopFade(); bright = s.floatValue / 100; applyFade() }
    @objc func volumeChanged(_ s: NSSlider) { stopFade(); volume = s.floatValue / 100; applyFade() }
    func stopFade() { fadeTimer?.invalidate(); fadeTimer = nil }
    func resetFade() { stopFade(); bright = 1; volume = 1; applyFade() }
    @objc func resetFadeAction(_ s: Any?) { resetFade() }
    /// いまの値から 0 まで、欄の秒数かけて下げる。what: 0 = 映像と音, 1 = 映像だけ, 2 = 音だけ。途中でスライダーを動かすか、もう一度押すと止まる
    func fadeDown(_ what: Int) {
        if fadeTimer != nil { stopFade(); return }
        let secs = max(0.1, fadeField.doubleValue), t0 = CACurrentMediaTime(), b0 = bright, v0 = volume
        fadeTimer = Timer.scheduledTimer(withTimeInterval: 1 / 60.0, repeats: true) { [weak self] tm in
            guard let self = self else { tm.invalidate(); return }
            let x = Float(min(1, (CACurrentMediaTime() - t0) / secs)), k = 1 - x * x * (3 - 2 * x)   // 出だしと終わりをなめらかに
            if what != 2 { self.bright = b0 * k }
            if what != 1 { self.volume = v0 * k }
            self.applyFade()
            if x >= 1 { tm.invalidate(); self.fadeTimer = nil }
        }
    }
    @objc func fadeBoth(_ s: Any?) { fadeDown(0) }
    @objc func fadeVideo(_ s: Any?) { fadeDown(1) }
    @objc func fadeAudio(_ s: Any?) { fadeDown(2) }

    func key(_ e: NSEvent) -> Bool {
        if e.modifierFlags.contains(.command) { return false }
        if e.keyCode == 53, outWindow != nil { closeOutput(); return true }      // Esc は、入力欄にカーソルがあっても出力を止める
        if window.firstResponder is NSTextView { return false }
        switch e.keyCode {
        case 49: togglePlay(nil)                                          // スペース
        case 53: if outWindow != nil { closeOutput() } else { return false }   // Esc: 出力を止める
        case 123: player.seek(to: CMTime(seconds: max(0, player.currentTime().seconds - 5), preferredTimescale: 600))
        case 124: player.seek(to: CMTime(seconds: player.currentTime().seconds + 5, preferredTimescale: 600))
        default: return false
        }
        return true
    }

    // ---------- 窓 ----------
    func buildMenu() {
        let main = NSMenu(), appItem = NSMenuItem(), fileItem = NSMenuItem()
        main.addItem(appItem); main.addItem(fileItem)
        let am = NSMenu(); am.addItem(withTitle: "Playback を終了", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"); appItem.submenu = am
        let fm = NSMenu(title: "ファイル"); fm.addItem(withTitle: "動画を開く…", action: #selector(openFile(_:)), keyEquivalent: "o"); fileItem.submenu = fm
        NSApp.mainMenu = main
    }
    func buildWindow() {
        func text(_ s: String, bold: Bool = false) -> NSTextField {
            let t = NSTextField(labelWithString: s); t.font = bold ? .boldSystemFont(ofSize: 12) : .systemFont(ofSize: 12); t.lineBreakMode = .byTruncatingMiddle; return t
        }
        func button(_ s: String, _ a: Selector) -> NSButton { let b = NSButton(title: s, target: self, action: a); b.bezelStyle = .rounded; return b }
        func row(_ v: [NSView]) -> NSStackView { let r = NSStackView(views: v); r.spacing = 10; r.alignment = .centerY; return r }
        func head(_ s: String) -> NSTextField { let t = text(s, bold: true); t.textColor = .secondaryLabelColor; return t }
        func spacer() -> NSView { let v = NSView(); v.setContentHuggingPriority(.defaultLow, for: .horizontal); return v }

        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 580), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Playback"; window.delegate = self; window.center(); window.isReleasedWhenClosed = false

        preview.translatesAutoresizingMaskIntoConstraints = false
        preview.heightAnchor.constraint(equalTo: preview.widthAnchor, multiplier: 540.0 / 1920.0).isActive = true

        fileLabel = text("動画が選ばれていません")
        playButton = button("再生", #selector(togglePlay(_:))); playButton.keyEquivalent = ""
        seek = NSSlider(value: 0, minValue: 0, maxValue: 1, target: self, action: #selector(seekChanged(_:)))
        seek.isContinuous = true; seek.setContentHuggingPriority(.defaultLow, for: .horizontal)
        timeLabel = text("0:00.0 / 0:00.0"); timeLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)

        screenPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        outButton = button("外部モニターに全画面で出す", #selector(toggleOutput(_:)))
        outStatus = text("出力していません"); outStatus.textColor = .secondaryLabelColor
        audioLabel = text("—")
        let audioNote = text("出力先の切り替えは、Mac の「システム設定 → サウンド」で行います"); audioNote.textColor = .secondaryLabelColor; audioNote.font = .systemFont(ofSize: 11)
        fadeField = NSTextField(string: "5"); fadeField.alignment = .right
        fadeField.widthAnchor.constraint(equalToConstant: 48).isActive = true
        brightSlider = NSSlider(value: 100, minValue: 0, maxValue: 100, target: self, action: #selector(brightChanged(_:)))
        volumeSlider = NSSlider(value: 100, minValue: 0, maxValue: 100, target: self, action: #selector(volumeChanged(_:)))
        for sl in [brightSlider!, volumeSlider!] { sl.isContinuous = true; sl.setContentHuggingPriority(.defaultLow, for: .horizontal) }
        brightLabel = text("100%"); volumeLabel = text("100%")
        for l in [brightLabel!, volumeLabel!] { l.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular); l.alignment = .right; l.widthAnchor.constraint(equalToConstant: 44).isActive = true }
        let bName = text("映像の明るさ"), vName = text("音量")
        for l in [bName, vName] { l.widthAnchor.constraint(equalToConstant: 84).isActive = true }

        let stack = NSStackView(views: [
            preview,
            row([button("動画を開く…", #selector(openFile(_:))), fileLabel, spacer()]),
            row([playButton, button("頭に戻す", #selector(toStart(_:))), seek, timeLabel]),
            head("映像の出力先"),
            row([screenPopup, outButton, outStatus, spacer()]),
            head("音の出力先(表示だけ)"),
            row([audioLabel, spacer()]),
            audioNote,
            head("出力の確認"),
            row([button("フラッシュ", #selector(flash(_:))), button("テスト音", #selector(testTone(_:))), text("白く光る / 1kHz を 左 → 右 → 両方"), spacer()]),
            head("映像の明るさと音量(0% で真っ黒 / 無音)"),
            row([bName, brightSlider, brightLabel]),
            row([vName, volumeSlider, volumeLabel]),
            row([fadeField, text("秒かけて"), button("両方フェードアウト", #selector(fadeBoth(_:))), button("映像だけ", #selector(fadeVideo(_:))), button("音だけ", #selector(fadeAudio(_:))), button("100% に戻す", #selector(resetFadeAction(_:))), spacer()]),
            text("スペース: 再生/停止   ←→: 5秒   Esc: 出力を止める   ⌘O: 動画を開く"),
        ])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 14, right: 16)
        stack.setCustomSpacing(14, after: stack.views[2]); stack.setCustomSpacing(14, after: stack.views[4]); stack.setCustomSpacing(14, after: stack.views[7]); stack.setCustomSpacing(14, after: stack.views[9])
        for v in stack.views where v is NSStackView || v === preview {
            v.leadingAnchor.constraint(equalTo: stack.leadingAnchor, constant: 16).isActive = true
            v.trailingAnchor.constraint(equalTo: stack.trailingAnchor, constant: -16).isActive = true
        }
        window.contentView = stack
    }
}

// ---------- 起動 ----------
let args = Array(CommandLine.arguments.dropFirst())
if args.first == "--self-test" {
    guard args.count > 1 else { print("動画を指定してください"); exit(1) }
    let asset = AVURLAsset(url: URL(fileURLWithPath: args[1]))
    let sem = DispatchSemaphore(value: 0)
    var ok = false
    Task {
        do {
            let d = try await asset.load(.duration).seconds
            let playable = try await asset.load(.isPlayable)
            let v = try await asset.loadTracks(withMediaType: .video), a = try await asset.loadTracks(withMediaType: .audio)
            let size = try await v.first?.load(.naturalSize) ?? .zero
            let fps = try await v.first?.load(.nominalFrameRate) ?? 0
            print(String(format: "長さ %.1f 秒  再生できる=%@  映像 %.0f×%.0f %.0f コマ/秒  音声トラック %d 本", d, playable ? "はい" : "いいえ", size.width, size.height, fps, a.count))
            ok = playable && !v.isEmpty && !a.isEmpty
        } catch { print("読めません: \(error.localizedDescription)") }
        sem.signal()
    }
    sem.wait()
    print("音の出力先: " + defaultOutputName())
    print("画面: " + NSScreen.screens.map { String(format: "%@ %.0f×%.0f", $0.localizedName, $0.frame.width * $0.backingScaleFactor, $0.frame.height * $0.backingScaleFactor) }.joined(separator: " / "))
    exit(ok ? 0 : 1)
}
let app = NSApplication.shared
let delegate = AppDelegate()
if let p = args.first(where: { !$0.hasPrefix("-") }) { delegate.startURL = URL(fileURLWithPath: p) }
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
