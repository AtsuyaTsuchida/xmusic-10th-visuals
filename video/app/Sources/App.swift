import Cocoa
import MetalKit
import UniformTypeIdentifiers

/// 絵を出すビュー。ドラッグで視点を回す、スクロールで寄る、ダブルクリックで戻す
final class MeshView: MTKView {
    weak var owner: AppDelegate?
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with e: NSEvent) {
        if e.clickCount == 2 { owner?.resetView() }
    }
    override func mouseDragged(with e: NSEvent) {
        guard let p = owner?.params else { return }
        p.yaw -= Double(e.deltaX) * 0.005
        p.pitch += Double(e.deltaY) * 0.005
    }
    override func scrollWheel(with e: NSEvent) {
        guard let p = owner?.params else { return }
        let d = Double(e.scrollingDeltaY) * (e.hasPreciseScrollingDeltas ? 1 : 10)
        p.zoom = min(4, max(0.2, p.zoom * exp(-d * 0.001)))
    }
}

/// 値を変えたら中身を呼ぶスライダー
final class ActionSlider: NSSlider {
    var onChange: ((Double) -> Void)?
    @objc func fire() { onChange?(doubleValue) }
    func wire() { target = self; action = #selector(fire); isContinuous = true }
}

/// 外部ディスプレイいっぱいに出す窓(枠なし)
final class OutputWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class AppDelegate: NSObject, NSApplicationDelegate, MTKViewDelegate, NSWindowDelegate {
    let options: Options
    let params = Params()
    let player = Player()
    var device: MTLDevice!
    var window: NSWindow!
    var view: MeshView!                 // 窓の中の描画(確認用の画面)
    var renderer: Renderer?
    var videoSource: VideoSource!       // 動画モードの素材
    var scale = 2
    // 外部ディスプレイへの出力
    var outWindow: OutputWindow?
    var outView: MeshView?
    private var outScreenName = ""
    private var outDrawn = 0

    private let inflight = DispatchSemaphore(value: 1)
    private var controls: NSStackView!
    private var controlsH: CGFloat = 0
    private var controlsVisible = true
    private var shownConstraints: [NSLayoutConstraint] = []
    private var hiddenConstraints: [NSLayoutConstraint] = []
    private var playButton: NSButton!
    private var modeControl: NSSegmentedControl!
    private var videoLabel: NSTextField!
    private var grids: [String: NSView] = [:]
    private var outButton: NSButton!
    private var screenPopup: NSPopUpButton!
    private var seekSlider: ActionSlider!
    private var timeLabel: NSTextField!
    private var labelsFor: [String: [NSTextField]] = [:]
    private var sliders: [String: [ActionSlider]] = [:]
    private var lastLabel = 0.0
    private var started = CFAbsoluteTimeGetCurrent(), drawn = 0, lastInfo = FrameInfo()

    init(_ o: Options) { options = o; super.init() }

    func applicationDidFinishLaunching(_ n: Notification) {
        guard let dev = MTLCreateSystemDefaultDevice() else { fatal("この Mac では Metal が使えません"); return }
        device = dev
        videoSource = VideoSource(device: dev)
        options.apply(to: params)
        player.muted = options.mute
        buildMenu()

        scale = options.scale ?? 1          // 既定は 1920x540 で描く(--scale 2 で縦横 2 倍)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 600),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "WaveMesh"
        window.collectionBehavior = [.fullScreenPrimary]
        window.appearance = NSAppearance(named: .darkAqua)     // 黒い画面に合わせて、部品も暗い見た目にする
        window.backgroundColor = NSColor(white: 0.07, alpha: 1)
        window.delegate = self
        view = makeMeshView()
        buildContent()
        window.setContentSize(idealContentSize(width: 1280))
        window.contentMinSize = NSSize(width: 960, height: 300)
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self = self else { return e }
            return self.handleKey(e) ? nil : e
        }
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged(_:)),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)

        if let url = options.audioURL() { load(url) } else { openAudio(nil) }
        // 動画: 起動時の指定があればそれを、なければ前回選んだものを読む
        let saved = UserDefaults.standard.stringArray(forKey: "videoPaths") ?? []
        let paths = options.videos.isEmpty ? saved : options.videos
        if !paths.isEmpty { loadVideos(paths.map { URL(fileURLWithPath: $0) }, remember: !options.videos.isEmpty) }
        modeChanged()
        if options.fullscreen { setControls(visible: false); window.toggleFullScreen(nil) }
        if options.output { DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [self] in openOutput() } }
        if options.play { player.play(from: options.start) } else if options.start > 0 { player.seek(to: options.start) }
        if let q = options.quitAfter {
            DispatchQueue.main.asyncAfter(deadline: .now() + q) { [self] in
                let el = CFAbsoluteTimeGetCurrent() - started
                let of = outWindow.map { NSStringFromRect($0.frame) } ?? "-"
                print(String(format: "frames=%d seconds=%.2f fps=%.1f audio=%.3f playing=%d k=%d grow=%.3f dolly=%.3f scale=%d",
                             drawn, el, Double(drawn) / el, player.now(), player.playing ? 1 : 0, lastInfo.k, lastInfo.g, lastInfo.dl, scale))
                print("mode=\(params.mode) videos=\(videoSource.clips.count) note=\(lastInfo.note) switches=\(videoSource.switches) lateFrames=\(videoSource.lateFrames) worstLate=\(videoSource.worstLate)")
                print("window content=\(NSStringFromSize(window.contentView!.frame.size)) view=\(NSStringFromSize(view.frame.size)) controls=\(controlsH)")
                print("output screen=\(outWindow == nil ? "-" : outScreenName) frame=\(of) outFrames=\(outDrawn) screens=\(NSScreen.screens.map { $0.localizedName })")
                NSApp.terminate(nil)
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func windowWillClose(_ n: Notification) { if (n.object as? NSWindow) === window { closeOutput(); NSApp.terminate(nil) } }

    func fatal(_ s: String) {
        let a = NSAlert(); a.messageText = s; a.runModal(); NSApp.terminate(nil)
    }

    func makeMeshView() -> MeshView {
        let v = MeshView(frame: NSRect(x: 0, y: 0, width: 1280, height: 360), device: device)
        v.owner = self
        v.colorPixelFormat = .bgra8Unorm
        v.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        v.preferredFramesPerSecond = 60
        v.framebufferOnly = true
        v.delegate = self
        (v.layer as? CAMetalLayer)?.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        return v
    }

    // ---------- 音源 ----------
    func load(_ url: URL) {
        do {
            let track = try Track(url: url)
            let r = try Renderer(device: device, track: track, params: params, scale: scale, drawableFormat: view.colorPixelFormat)
            r.video = videoSource
            inflight.wait(); renderer = r; inflight.signal()
            player.load(track)
            seekSlider.maxValue = track.duration
            seekSlider.doubleValue = 0
            window.title = "WaveMesh — " + url.lastPathComponent
        } catch {
            let a = NSAlert(); a.messageText = "音源を読めません"; a.informativeText = "\(url.path)\n\(error.localizedDescription)"; a.runModal()
        }
    }

    @objc func openAudio(_ sender: Any?) {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.audio]
        p.message = "音源を選んでください"
        if p.runModal() == .OK, let url = p.url { load(url) }
    }

    // ---------- 動画モードの素材 ----------
    func loadVideos(_ urls: [URL], remember: Bool) {
        inflight.wait(); videoSource.load(urls); inflight.signal()
        if remember { UserDefaults.standard.set(urls.map { $0.path }, forKey: "videoPaths") }
        let n = videoSource.clips.count
        videoLabel.stringValue = n == 0 ? "動画が選ばれていません" : "\(n) 本"
    }

    @objc func openVideos(_ sender: Any?) {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.movie, .folder]
        p.allowsMultipleSelection = true
        p.canChooseDirectories = true
        p.message = "動画ファイルか、動画の入ったフォルダを選んでください(複数可)"
        if p.runModal() == .OK, !p.urls.isEmpty {
            loadVideos(p.urls, remember: true)
            if videoSource.clips.isEmpty {
                let a = NSAlert(); a.messageText = "読める動画がありませんでした"; a.informativeText = "mp4 / mov / m4v に対応しています"; a.runModal()
            } else {
                params.mode = 1; modeChanged()
            }
        }
    }

    @objc func modePicked(_ sender: NSSegmentedControl) { params.mode = Double(sender.selectedSegment); modeChanged() }

    /// モードに合わせて、出すスライダーを入れ替える
    func modeChanged() {
        let m = min(3, max(0, Int(params.mode.rounded())))
        modeControl.selectedSegment = m
        let shown = m == 3 ? 2 : m                       // 通しのときは、脳のシーンのスライダーを出す
        for (i, name) in ["mesh", "video", "brain"].enumerated() { grids[name]?.isHidden = i != shown }
    }

    // ---------- 描画(窓の中の画面も、外部への出力も同じ絵) ----------
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in v: MTKView) {
        guard let r = renderer else { return }
        let t = player.now()
        inflight.wait()
        guard let cb = r.queue.makeCommandBuffer(), let pass = v.currentRenderPassDescriptor, let drawable = v.currentDrawable else {
            inflight.signal(); return
        }
        // 絵を描くのは主になる画面(出力中は外部、ふだんは窓)のときだけ。もう一方は同じ絵を写すだけ
        let master = v === (outView ?? view)
        let info = master ? r.encode(cb, time: t, playing: player.playing) : lastInfo
        r.blit(cb, to: pass, drawableSize: v.drawableSize)
        cb.addCompletedHandler { [inflight] _ in inflight.signal() }
        cb.present(drawable)
        cb.commit()
        lastInfo = info
        if v === outView { outDrawn += 1 } else { drawn += 1 }
        if v !== view && !view.isPaused { return }       // 表示の更新は窓の画面に任せる(止めている間は出力側で)
        let nowT = CFAbsoluteTimeGetCurrent()
        if nowT - lastLabel > 0.1 { lastLabel = nowT; updateLabels(t, info) }
    }

    func updateLabels(_ t: Double, _ info: FrameInfo) {
        let m = Int(t / 60), s = t - Double(m * 60)
        timeLabel.stringValue = (params.mode >= 1.5 && !(params.mode >= 2.5 && info.note.isEmpty)) ? String(format: "%d:%04.1f   脳になる量 %.2f   %@", m, s, info.morph, info.note)
                              : (params.mode >= 0.5 && params.mode < 1.5) ? String(format: "%d:%04.1f   深さ %.2f   %@", m, s, info.depth, info.note)
                                                   : String(format: "%d:%04.1f   広がり %.2f   前進 %.2f", m, s, info.g, info.dl)
        if player.playing { seekSlider.doubleValue = t }
        playButton.title = player.playing ? "停止" : "再生"
    }

    // ---------- 外部ディスプレイへの出力 ----------
    /// 出力先の候補。窓のある画面以外を先に並べる(外部ディスプレイが既定になる)
    func outputScreens() -> [NSScreen] {
        let here = window.screen
        return NSScreen.screens.filter { $0 != here } + NSScreen.screens.filter { $0 == here }
    }

    func refreshScreens() {
        let keep = screenPopup.titleOfSelectedItem
        screenPopup.removeAllItems()
        let here = window.screen
        for s in outputScreens() {
            let f = s.frame
            screenPopup.addItem(withTitle: String(format: "%@ (%dx%d)%@", s.localizedName, Int(f.width), Int(f.height), s == here ? " ※この窓と同じ画面" : ""))
        }
        if let k = keep, screenPopup.itemTitles.contains(k) { screenPopup.selectItem(withTitle: k) }
        outButton.title = outWindow == nil ? "外部ディスプレイに出す" : "出力を止める"
    }

    @objc func screensChanged(_ n: Notification) {
        if let w = outWindow, let s = w.screen, NSScreen.screens.contains(s) {
            w.setFrame(s.frame, display: true)           // 解像度が変わっても画面いっぱいを保つ
        } else if outWindow != nil {
            closeOutput()                                // 出力先が抜かれた
        }
        refreshScreens()
    }

    @objc func toggleOutput(_ sender: Any?) { if outWindow == nil { openOutput() } else { closeOutput() } }

    func openOutput() {
        guard outWindow == nil else { return }
        let list = outputScreens()
        let i = max(0, screenPopup.indexOfSelectedItem)
        guard i < list.count else { return }
        let screen = list[i]
        let w = OutputWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 1)     // メニューバーと Dock より上
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        w.backgroundColor = .black
        w.isOpaque = true
        w.hasShadow = false
        let v = makeMeshView()
        v.preferredFramesPerSecond = max(60, screen.maximumFramesPerSecond)
        w.contentView = v
        w.setFrame(screen.frame, display: true)
        outWindow = w; outView = v; outScreenName = screen.localizedName; outDrawn = 0
        if screen == window.screen {
            view.isPaused = true                         // 窓は隠れるので、窓の中の描画は止める
            w.makeKeyAndOrderFront(nil)                  // 同じ画面に出すときは操作の窓が隠れる。Esc か O で戻る
        } else {
            w.ignoresMouseEvents = true                  // 外部の画面はさわらない。操作はこの窓で
            w.orderFrontRegardless()
        }
        refreshScreens()
    }

    func closeOutput() {
        guard let w = outWindow else { return }
        outView?.isPaused = true
        outView?.delegate = nil
        w.orderOut(nil)
        outWindow = nil; outView = nil
        view.isPaused = false
        window.makeKeyAndOrderFront(nil)
        refreshScreens()
    }

    // ---------- 操作 ----------
    @objc func togglePlay(_ sender: Any?) { player.toggle() }
    @objc func resetViewAction(_ sender: Any?) { resetView() }
    func resetView() { params.yaw = 0; params.pitch = 0; params.zoom = 1 }
    @objc func toggleControls(_ sender: Any?) { setControls(visible: !controlsVisible) }
    @objc func toggleFull(_ sender: Any?) { window.toggleFullScreen(nil) }
    @objc func colorChanged(_ w: NSColorWell) {
        if let c = w.color.usingColorSpace(.sRGB) { params.color = SIMD3(Float(c.redComponent), Float(c.greenComponent), Float(c.blueComponent)) }
    }
    @objc func resetParams(_ sender: Any?) {
        let d = Params()
        for info in PARAMS where info.key != "mode" { params[keyPath: info.path] = d[keyPath: info.path]; sliders[info.key]?.forEach { $0.doubleValue = d[keyPath: info.path] }; showValue(info) }
        params.color = d.color
    }

    /// キー操作(どの部品にフォーカスがあっても効くように、窓に届く前に見る)
    func handleKey(_ e: NSEvent) -> Bool {
        if e.modifierFlags.contains(.command) || e.modifierFlags.contains(.control) { return false }
        guard let w = e.window, w === window || w === outWindow else { return false }   // 開く窓や色の窓ではそのまま
        if w.firstResponder is NSTextView { return false }
        let step = e.modifierFlags.contains(.shift) ? 30.0 : 5.0
        switch e.keyCode {
        case 49: player.toggle()                                // スペース
        case 123: player.seek(to: player.now() - step)          // ←
        case 124: player.seek(to: player.now() + step)          // →
        case 115: player.seek(to: 0)                            // Home
        case 53:                                                // Esc: 出力を止める → 全画面を抜ける
            if outWindow != nil { closeOutput() }
            else if window.styleMask.contains(.fullScreen) { window.toggleFullScreen(nil) }
            else { return false }
        default:
            switch (e.charactersIgnoringModifiers ?? "").lowercased() {
            case "1": params.mode = 0; modeChanged()
            case "2": params.mode = 1; modeChanged()
            case "3": params.mode = 2; modeChanged()
            case "4": params.mode = 3; modeChanged()
            case "o": toggleOutput(nil)
            case "p": toggleControls(nil)
            case "f": window.toggleFullScreen(nil)
            case "r": resetView()
            default: return false
            }
        }
        return true
    }

    func showValue(_ info: ParamInfo) {
        let v = params[keyPath: info.path]
        var s = String(format: "%.2f", v)
        while s.contains(".") && (s.hasSuffix("0") || s.hasSuffix(".")) { s.removeLast() }
        let shown = ["grow", "dolly", "vRD", "vDepth", "bMorph"].contains(info.key) && v < 0 ? "自動" : s
        labelsFor[info.key]?.forEach { $0.stringValue = shown }
        sliders[info.key]?.forEach { if abs($0.doubleValue - v) > info.step * 0.5 { $0.doubleValue = v } }   // 同じ値のスライダーが両方のモードにあるとき、そろえる
    }

    // ---------- 窓の中身: 上に描画、下に操作 ----------
    func idealContentSize(width: CGFloat) -> NSSize {
        NSSize(width: width, height: (width * CGFloat(H) / CGFloat(W)).rounded() + (controlsVisible ? controlsH : 0))
    }

    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        guard sender === window, !sender.styleMask.contains(.fullScreen) else { return frameSize }
        let content = sender.contentRect(forFrameRect: NSRect(origin: .zero, size: frameSize)).size
        return sender.frameRect(forContentRect: NSRect(origin: .zero, size: idealContentSize(width: content.width))).size
    }

    func setControls(visible: Bool) {
        guard visible != controlsVisible else { return }
        controlsVisible = visible
        if visible {
            NSLayoutConstraint.deactivate(hiddenConstraints); controls.isHidden = false; NSLayoutConstraint.activate(shownConstraints)
        } else {
            NSLayoutConstraint.deactivate(shownConstraints); controls.isHidden = true; NSLayoutConstraint.activate(hiddenConstraints)
        }
        if !window.styleMask.contains(.fullScreen) {
            let top = window.frame.maxY
            window.setContentSize(idealContentSize(width: window.contentView!.frame.width))
            window.setFrameTopLeftPoint(NSPoint(x: window.frame.minX, y: top))
        }
    }

    func buildContent() {
        func text(_ s: String, width: CGFloat? = nil, mono: Bool = false) -> NSTextField {
            let f = NSTextField(labelWithString: s)
            f.font = mono ? .monospacedDigitSystemFont(ofSize: 11, weight: .regular) : .systemFont(ofSize: 11)
            f.textColor = NSColor(white: 0.78, alpha: 1)
            if let w = width { f.widthAnchor.constraint(equalToConstant: w).isActive = true }
            f.setContentHuggingPriority(.required, for: .horizontal)
            return f
        }
        func button(_ title: String, _ sel: Selector) -> NSButton {
            let b = NSButton(title: title, target: self, action: sel)
            b.controlSize = .small; b.font = .systemFont(ofSize: 11); b.setContentHuggingPriority(.required, for: .horizontal)
            return b
        }

        // 1段目: 再生と位置
        playButton = button("再生", #selector(togglePlay(_:)))
        playButton.widthAnchor.constraint(equalToConstant: 56).isActive = true
        seekSlider = ActionSlider(value: 0, minValue: 0, maxValue: 300, target: nil, action: nil)
        seekSlider.wire(); seekSlider.controlSize = .small
        seekSlider.onChange = { [weak self] v in self?.player.seek(to: v) }
        seekSlider.setContentHuggingPriority(.defaultLow, for: .horizontal)
        timeLabel = text("0:00.0", width: 330, mono: true)
        timeLabel.lineBreakMode = .byTruncatingTail
        let row1 = NSStackView(views: [playButton, seekSlider, timeLabel]); row1.spacing = 10

        // モードの選択と、動画モードの素材
        modeControl = NSSegmentedControl(labels: ["波形メッシュ", "動画", "Curl → 脳", "通し"], trackingMode: .selectOne, target: self, action: #selector(modePicked(_:)))
        modeControl.controlSize = .small; modeControl.font = .systemFont(ofSize: 11)
        modeControl.selectedSegment = 0
        modeControl.setContentHuggingPriority(.required, for: .horizontal)
        videoLabel = text("動画が選ばれていません")
        let spacer0 = NSView(); spacer0.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let rowMode = NSStackView(views: [text("モード"), modeControl, button("動画を選ぶ…", #selector(openVideos(_:))), videoLabel, spacer0])
        rowMode.spacing = 10

        // 2段目: 外部ディスプレイへの出力、視点、色
        screenPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        screenPopup.controlSize = .small; screenPopup.font = .systemFont(ofSize: 11)
        outButton = button("外部ディスプレイに出す", #selector(toggleOutput(_:)))
        outButton.keyEquivalent = ""
        let well = NSColorWell(frame: NSRect(x: 0, y: 0, width: 40, height: 20))
        well.color = .white; well.target = self; well.action = #selector(colorChanged(_:))
        well.widthAnchor.constraint(equalToConstant: 40).isActive = true
        well.heightAnchor.constraint(equalToConstant: 20).isActive = true
        let spacer = NSView(); spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let row2 = NSStackView(views: [text("出力先"), screenPopup, outButton, spacer, text("色"), well,
                                       button("視点を戻す", #selector(resetViewAction(_:))), button("値を戻す", #selector(resetParams(_:)))])
        row2.spacing = 10

        // スライダー: 3列。モードごとに1組ずつ作り、選ばれているほうだけ見せる
        func makeGrid(_ group: String) -> NSStackView {
        let cols = (0..<3).map { _ -> NSStackView in
            let c = NSStackView(); c.orientation = .vertical; c.alignment = .leading; c.spacing = 3; return c
        }
        let shown = PARAMS.filter { $0.group == group || $0.group == "common" }  // 視点(yaw など)はドラッグで動かすので出さない
        let perCol = (shown.count + 2) / 3
        for (i, info) in shown.enumerated() {
            let sl = ActionSlider(value: params[keyPath: info.path], minValue: info.min, maxValue: info.max, target: nil, action: nil)
            sl.wire(); sl.controlSize = .small
            sl.setContentHuggingPriority(.defaultLow, for: .horizontal)
            sl.widthAnchor.constraint(greaterThanOrEqualToConstant: 90).isActive = true
            let val = text("", width: 38, mono: true)
            labelsFor[info.key, default: []].append(val); sliders[info.key, default: []].append(sl)
            sl.onChange = { [weak self] v in
                guard let self = self else { return }
                self.params[keyPath: info.path] = (v / info.step).rounded() * info.step
                self.showValue(info)
            }
            let row = NSStackView(views: [text(info.label, width: 124), sl, val]); row.spacing = 6
            let col = cols[i / perCol]
            col.addArrangedSubview(row)
            row.leadingAnchor.constraint(equalTo: col.leadingAnchor).isActive = true
            row.trailingAnchor.constraint(equalTo: col.trailingAnchor).isActive = true
            showValue(info)
        }
        let grid = NSStackView(views: cols); grid.spacing = 24; grid.distribution = .fillEqually; grid.alignment = .top
        return grid
        }
        let grid = NSView()
        var gridH: CGFloat = 0
        for group in ["mesh", "video", "brain"] {
            let g = makeGrid(group)
            g.translatesAutoresizingMaskIntoConstraints = false
            grid.addSubview(g)
            NSLayoutConstraint.activate([g.topAnchor.constraint(equalTo: grid.topAnchor),
                                         g.leadingAnchor.constraint(equalTo: grid.leadingAnchor),
                                         g.trailingAnchor.constraint(equalTo: grid.trailingAnchor)])
            gridH = max(gridH, g.fittingSize.height)
            grids[group] = g
        }
        grid.heightAnchor.constraint(equalToConstant: gridH.rounded(.up)).isActive = true
        grids["video"]?.isHidden = true; grids["brain"]?.isHidden = true
        let help = text("スペース: 再生/停止   ←→: 5秒(Shift で30秒)   1 / 2 / 3 / 4: モード   O: 外部ディスプレイに出す/止める(Esc でも止まる)   P: 操作を隠す   F: 窓を全画面   ドラッグ: 視点   スクロール: 寄る")
        help.textColor = NSColor(white: 0.5, alpha: 1)
        help.lineBreakMode = .byTruncatingTail
        help.setContentHuggingPriority(.defaultLow, for: .horizontal)
        help.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        controls = NSStackView(views: [row1, rowMode, row2, grid, help])
        controls.orientation = .vertical; controls.alignment = .leading; controls.spacing = 8
        controls.edgeInsets = NSEdgeInsets(top: 10, left: 14, bottom: 10, right: 14)
        for r in [row1, rowMode, row2, grid, help] as [NSView] {
            r.leadingAnchor.constraint(equalTo: controls.leadingAnchor, constant: 14).isActive = true
            r.trailingAnchor.constraint(equalTo: controls.trailingAnchor, constant: -14).isActive = true
        }

        let root = NSView(frame: NSRect(x: 0, y: 0, width: 1280, height: 600))
        view.translatesAutoresizingMaskIntoConstraints = false
        controls.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(view); root.addSubview(controls)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: root.topAnchor),
            view.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            controls.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            controls.trailingAnchor.constraint(equalTo: root.trailingAnchor),
        ])
        shownConstraints = [view.bottomAnchor.constraint(equalTo: controls.topAnchor),
                            controls.bottomAnchor.constraint(equalTo: root.bottomAnchor)]
        hiddenConstraints = [view.bottomAnchor.constraint(equalTo: root.bottomAnchor),
                             controls.topAnchor.constraint(equalTo: root.bottomAnchor)]
        NSLayoutConstraint.activate(shownConstraints)
        window.contentView = root
        root.layoutSubtreeIfNeeded()
        controlsH = controls.fittingSize.height.rounded(.up)
        controls.heightAnchor.constraint(equalToConstant: controlsH).isActive = true
        refreshScreens()
    }

    func buildMenu() {
        let main = NSMenu()
        func add(_ title: String, _ items: [NSMenuItem]) {
            let m = NSMenu(title: title); items.forEach { m.addItem($0) }
            let it = NSMenuItem(title: title, action: nil, keyEquivalent: ""); it.submenu = m; main.addItem(it)
        }
        func item(_ title: String, _ sel: Selector?, _ key: String, _ mods: NSEvent.ModifierFlags = .command, target: AnyObject? = nil) -> NSMenuItem {
            let it = NSMenuItem(title: title, action: sel, keyEquivalent: key); it.keyEquivalentModifierMask = mods; it.target = target; return it
        }
        add("WaveMesh", [item("WaveMesh を隠す", #selector(NSApplication.hide(_:)), "h"),
                         .separator(),
                         item("WaveMesh を終了", #selector(NSApplication.terminate(_:)), "q")])
        add("ファイル", [item("音源を開く…", #selector(openAudio(_:)), "o", target: self),
                        item("動画を選ぶ…", #selector(openVideos(_:)), "o", [.command, .shift], target: self)])
        add("表示", [item("再生 / 停止", #selector(togglePlay(_:)), "", [], target: self),
                    item("外部ディスプレイに出す / 止める", #selector(toggleOutput(_:)), "e", target: self),
                    item("操作を出す / 隠す", #selector(toggleControls(_:)), "p", target: self),
                    item("視点を戻す", #selector(resetViewAction(_:)), "r", target: self),
                    item("窓を全画面", #selector(toggleFull(_:)), "f", [.command, .control], target: self)])
        NSApp.mainMenu = main
    }
}
