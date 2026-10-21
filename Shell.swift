// iOS 外壳：一个全屏横屏的原生窗口，里面只放游戏页面（WKWebView）。
// 只编一次（GitHub Actions 的 macOS 上 swiftc 直接编，不用 Xcode 工程），所有服主共用这个可执行文件；
// 名字、Bundle ID、图标、地址都是服务器出包时换的（Info.plist + shell.json）。
import UIKit
import WebKit
import Network

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(_ app: UIApplication,
                     didFinishLaunchingWithOptions opts: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        app.isIdleTimerDisabled = true   // 屏幕常亮
        return true
    }
}

// 用场景生命周期（iOS 26 之后苹果要求必须用）；Info.plist 里按 "SceneDelegate" 这个名字找
@objc(SceneDelegate)
final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession,
               options: UIScene.ConnectionOptions) {
        guard let ws = scene as? UIWindowScene else { return }
        let w = UIWindow(windowScene: ws)
        w.backgroundColor = .black
        w.rootViewController = ShellViewController()
        w.makeKeyAndVisible()
        window = w
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
        UIApplication.shared.isIdleTimerDisabled = true
    }
}

final class ShellViewController: UIViewController, WKNavigationDelegate, WKUIDelegate, UIScrollViewDelegate {
    private var web: WKWebView!
    private let errorView = UIView()
    private var home: URL?
    private var agent = ""
    private var gateKey = ""        // 打包密钥（见 setGateCookie）
    private var net: NetBridge!     // 给网页开 TCP（微端直连），见文件末尾
    private var fs: FsBridge!       // 本机文件桥（读写本机补丁），见文件末尾
    // 运行目录 ROOT = Application Support/game（私有、不进 iCloud 备份，LOCALRES.md §0）
    private let gameRoot = ShellViewController.makeRoot()
    // 包里的资源包 Shell.app/bundle/（appshell/bundle.mjs 打的：bundle.json、patch/**、mui/**）
    private let bundleDir = Bundle.main.bundleURL.appendingPathComponent("bundle", isDirectory: true)
    private var bundleInfo: [String: Any]?
    private var muiHash = ""
    private var installLabel: UILabel?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        loadConfig()
        loadBundleInfo()
        createWeb()
        buildErrorView()
        // 先把包里的补丁释放到 ROOT（第一次 / 补丁换了），再写 cookie 开页面（cookie 存储是异步的：写好再开，第一个请求就带上）
        if let u = home {
            prepareBundle { [weak self] in self?.setGateCookie { [weak self] in self?.web.load(URLRequest(url: u)) } }
        } else { showError() }
        // 电量：WKWebView 没有 navigator.getBattery，壳推给网页 window.__rkmBattery（mobileui/hud.mjs 读）
        UIDevice.current.isBatteryMonitoringEnabled = true
        for n in [UIDevice.batteryLevelDidChangeNotification, UIDevice.batteryStateDidChangeNotification] {
            NotificationCenter.default.addObserver(forName: n, object: nil, queue: .main) { [weak self] _ in
                self?.pushBattery()
            }
        }
    }

    private func pushBattery() {
        let d = UIDevice.current
        guard d.batteryLevel >= 0 else { return }   // 模拟器 / 拿不到是 -1
        let ch = d.batteryState == .charging || d.batteryState == .full
        web?.evaluateJavaScript("window.__rkmBattery={level:\(d.batteryLevel),charging:\(ch)}", completionHandler: nil)
    }

    // 换页（登录 -> 游戏）以后 window 是新的，再推一次
    func webView(_ v: WKWebView, didFinish n: WKNavigation!) { pushBattery() }

    // 换页了：上一页开的连接作废
    func webView(_ v: WKWebView, didStartProvisionalNavigation n: WKNavigation!) { net.closeAll() }

    private func loadConfig() {
        guard let f = Bundle.main.url(forResource: "shell", withExtension: "json"),
              let d = try? Data(contentsOf: f),
              let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { return }
        if let s = o["url"] as? String { home = URL(string: s) }
        agent = (o["agent"] as? String) ?? ""
        gateKey = Self.unmask((o["pk"] as? String) ?? "", (o["pm"] as? String) ?? "")
    }

    static func makeRoot() -> URL {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        var r = base.appendingPathComponent("game", isDirectory: true)
        try? fm.createDirectory(at: r, withIntermediateDirectories: true)
        var rv = URLResourceValues()
        rv.isExcludedFromBackup = true
        try? r.setResourceValues(rv)
        return r
    }

    private func loadBundleInfo() {
        guard let d = try? Data(contentsOf: bundleDir.appendingPathComponent("bundle.json")),
              let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { return }
        bundleInfo = o
        muiHash = ((o["muiHash"] as? String) ?? "").filter { $0.isHexDigit }
    }

    private func rootHash() -> String? {
        guard let d = try? Data(contentsOf: gameRoot.appendingPathComponent(".rkm/bundle.json")),
              let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { return nil }
        return o["patchHash"] as? String
    }

    /// 包里 bundle.json 的 patchHash 和 ROOT/.rkm/bundle.json 记的不一样（第一次 / 换了补丁）：把 bundle/patch/ 下的文件释放到 ROOT
    /// （覆盖同名，不删多出来的 —— 那些是微端拉的），最后记 .rkm/bundle.json。手机界面不释放，走 rkmb://mui/（MuiSchemeHandler）
    private func prepareBundle(_ then: @escaping () -> Void) {
        guard let b = bundleInfo else { then(); return }
        let want = (b["patchHash"] as? String) ?? ""
        if want == rootHash() { then(); return }
        let label = UILabel(frame: view.bounds)
        label.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        label.backgroundColor = .black
        label.textColor = .white
        label.font = .systemFont(ofSize: 18)
        label.textAlignment = .center
        label.text = "第一次运行，正在释放游戏资源……"
        view.addSubview(label)
        installLabel = label
        let files = (b["files"] as? [[String: Any]]) ?? []
        let root = gameRoot, src = bundleDir.appendingPathComponent("patch", isDirectory: true)
        let bj = bundleDir.appendingPathComponent("bundle.json")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let fm = FileManager.default
            let total = max(1, files.reduce(Int64(0)) { $0 + (($1["size"] as? NSNumber)?.int64Value ?? 0) })
            var done: Int64 = 0, lastPct = -1
            var err: String?
            do {
                for f in files {
                    guard let p = f["p"] as? String else { continue }
                    let dst = try FsBridge.resolve(root, p, false)   // 路径规矩和网页那边一样；已有的按不分大小写认
                    try fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
                    let tmp = URL(fileURLWithPath: dst.path + ".rkmtmp")
                    try? fm.removeItem(at: tmp)
                    try fm.copyItem(at: src.appendingPathComponent(p), to: tmp)   // 同一个 APFS 卷上是克隆，不占时间也不占两份地方
                    if fm.fileExists(atPath: dst.path) { try fm.removeItem(at: dst) }
                    try fm.moveItem(at: tmp, to: dst)
                    done += (f["size"] as? NSNumber)?.int64Value ?? 0
                    let pct = Int(done * 100 / total)
                    if pct != lastPct {
                        lastPct = pct
                        DispatchQueue.main.async { self?.installLabel?.text = "第一次运行，正在释放游戏资源……  \(pct)%" }
                    }
                }
                let mark = root.appendingPathComponent(".rkm", isDirectory: true)
                try fm.createDirectory(at: mark, withIntermediateDirectories: true)
                try Data(contentsOf: bj).write(to: mark.appendingPathComponent("bundle.json"), options: .atomic)
            } catch {
                err = "\(error)"
            }
            DispatchQueue.main.async {
                self?.installLabel?.removeFromSuperview()
                self?.installLabel = nil
                if let e = err { NSLog("rkm: 释放游戏资源失败 %@", e) }   // 失败了照样进游戏：缺的图微端会补
                then()
            }
        }
    }

    // 打包密钥：shell.json 里是「密钥 XOR 掩码」和掩码两段（appshell/packkey.mjs），异或回来
    private static func unmask(_ pk: String, _ pm: String) -> String {
        let a = Array(pk.utf8), b = Array(pm.utf8)
        guard a.count == 64, b.count == 64 else { return "" }
        func hx(_ c: UInt8) -> Int? { Int(String(UnicodeScalar(c)), radix: 16) }
        var out = ""
        for i in stride(from: 0, to: 64, by: 2) {
            guard let a1 = hx(a[i]), let a2 = hx(a[i + 1]), let b1 = hx(b[i]), let b2 = hx(b[i + 1]) else { return "" }
            out += String(format: "%02x", ((a1 << 4) | a2) ^ ((b1 << 4) | b2))
        }
        return out
    }

    // 服主没开网页访问时，站点只认带 __rkmkey cookie 的请求（App 外的浏览器拿不到）
    private func setGateCookie(_ done: @escaping () -> Void) {
        guard !gateKey.isEmpty, let u = home, let h = u.host else { done(); return }
        var p: [HTTPCookiePropertyKey: Any] = [.name: "__rkmkey", .value: gateKey, .domain: h, .path: "/",
                                               .maximumAge: "31536000"]
        if u.scheme == "https" { p[.secure] = "TRUE" }
        guard let c = HTTPCookie(properties: p) else { done(); return }
        WKWebsiteDataStore.default().httpCookieStore.setCookie(c) { done() }
    }

    private func createWeb() {
        let cfg = WKWebViewConfiguration()
        cfg.allowsInlineMediaPlayback = true
        cfg.mediaTypesRequiringUserActionForPlayback = []
        cfg.websiteDataStore = .default()
        // iPad 默认按电脑版打开网页，强制手机版，触屏逻辑和手机一致
        cfg.defaultWebpagePreferences.preferredContentMode = .mobile
        // UA 末尾加 App 标识，网页端据此知道是在 App 里（保留 Mobile/ 段，页面的手机判断不受影响）
        // 再带上包自己的版本号（服主后台「打包 App」填的，进了 CFBundleShortVersionString），登录框左上角显示它
        let ver = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")
            .filter { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_" }
        cfg.applicationNameForUserAgent = agent.isEmpty ? "Mobile/15E148"
            : "Mobile/15E148 " + agent + (ver.isEmpty ? "" : " RKMVer/" + ver)
        // 长按不出系统菜单、不选字（输入框照常能选），不能缩放
        let css = "*{-webkit-touch-callout:none;-webkit-user-select:none;-webkit-tap-highlight-color:transparent}"
            + "input,textarea{-webkit-user-select:auto}"
        let js = """
        (function(){var s=document.createElement('style');s.textContent='\(css)';
        (document.head||document.documentElement).appendChild(s);
        var m=document.querySelector('meta[name=viewport]');if(!m){m=document.createElement('meta');m.name='viewport';
        (document.head||document.documentElement).appendChild(m);}
        m.content='width=device-width,initial-scale=1,maximum-scale=1,user-scalable=no,viewport-fit=cover';})();
        """
        cfg.userContentController.addUserScript(
            WKUserScript(source: js, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        // 微端直连：网页里开不了 TCP，壳替它开（nativenet.mjs 用 webkit.messageHandlers.rkmnet）
        net = NetBridge(homeHost: home?.host ?? "")
        cfg.userContentController.add(net, name: "rkmnet")
        cfg.userContentController.addUserScript(
            WKUserScript(source: "window.__rkmNetVer=1", injectionTime: .atDocumentStart, forMainFrameOnly: true))
        // 游戏里的「退出」（大退）：网页问过、点了确定才 postMessage，真把 App 关掉（见文件末尾 AppBridge）
        cfg.userContentController.add(AppBridge(homeHost: home?.host ?? ""), name: "rkmapp")
        // 网页认这个才走原生震动（haptic.mjs）：没有它（老壳）就是没震动，不报错
        cfg.userContentController.addUserScript(
            WKUserScript(source: "window.__rkmHaptic=1", injectionTime: .atDocumentStart, forMainFrameOnly: true))
        // 本机文件桥（localfs.mjs）：await webkit.messageHandlers.rkmfs.postMessage({ op, ... })，见文件末尾 FsBridge
        fs = FsBridge(root: gameRoot, home: home)
        fs.muiHash = muiHash
        cfg.userContentController.addScriptMessageHandler(fs, contentWorld: .page, name: "rkmfs")
        // 包里的手机界面：rkmb://mui/ui/xxx.json、rkmb://mui/res/xxx.png（MuiSchemeHandler），页面看 __rkmMui.base 换地址
        cfg.setURLSchemeHandler(MuiSchemeHandler(base: bundleDir.appendingPathComponent("mui", isDirectory: true),
                                                 home: home, gateKey: gateKey), forURLScheme: "rkmb")
        cfg.userContentController.addUserScript(WKUserScript(
            source: "window.__rkmFsVer=1" + (muiHash.isEmpty ? "" : ";window.__rkmMui={base:'rkmb://mui/',hash:'\(muiHash)'}"),
            injectionTime: .atDocumentStart, forMainFrameOnly: true))

        let w = WKWebView(frame: view.bounds, configuration: cfg)
        w.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        w.isOpaque = false
        w.backgroundColor = .black
        w.scrollView.backgroundColor = .black
        w.scrollView.isScrollEnabled = false
        w.scrollView.bounces = false
        w.scrollView.contentInsetAdjustmentBehavior = .never
        w.scrollView.showsVerticalScrollIndicator = false
        w.scrollView.showsHorizontalScrollIndicator = false
        w.scrollView.delegate = self
        w.scrollView.pinchGestureRecognizer?.isEnabled = false
        w.allowsLinkPreview = false
        w.allowsBackForwardNavigationGestures = false
        w.navigationDelegate = self
        w.uiDelegate = self
        view.insertSubview(w, at: 0)
        web = w
        net.web = w
        fs.web = w
    }

    // 不让双击 / 双指缩放
    func viewForZooming(in scrollView: UIScrollView) -> UIView? { nil }

    // 站内链接留在游戏里；站外（充值、客服等）交给系统打开
    func webView(_ v: WKWebView, decidePolicyFor a: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let u = a.request.url else { decisionHandler(.cancel); return }
        let scheme = u.scheme?.lowercased() ?? ""
        if scheme == "about" || scheme == "blob" || scheme == "data" { decisionHandler(.allow); return }
        if let h = home?.host, let uh = u.host, h.caseInsensitiveCompare(uh) == .orderedSame {
            decisionHandler(.allow); return
        }
        if a.targetFrame?.isMainFrame == false { decisionHandler(.allow); return }
        UIApplication.shared.open(u)
        decisionHandler(.cancel)
    }

    // 页面要开新窗口（target=_blank / window.open）时也交给系统
    func webView(_ v: WKWebView, createWebViewWith c: WKWebViewConfiguration,
                 for a: WKNavigationAction, windowFeatures f: WKWindowFeatures) -> WKWebView? {
        if let u = a.request.url { UIApplication.shared.open(u) }
        return nil
    }
    // 页面的 alert / confirm / prompt 用原生弹框（WKWebView 默认什么都不显示）
    func webView(_ v: WKWebView, runJavaScriptAlertPanelWithMessage m: String,
                 initiatedByFrame f: WKFrameInfo, completionHandler done: @escaping () -> Void) {
        let a = UIAlertController(title: nil, message: m, preferredStyle: .alert)
        a.addAction(UIAlertAction(title: "确定", style: .default) { _ in done() })
        present(a, animated: true)
    }

    func webView(_ v: WKWebView, runJavaScriptConfirmPanelWithMessage m: String,
                 initiatedByFrame f: WKFrameInfo, completionHandler done: @escaping (Bool) -> Void) {
        let a = UIAlertController(title: nil, message: m, preferredStyle: .alert)
        a.addAction(UIAlertAction(title: "取消", style: .cancel) { _ in done(false) })
        a.addAction(UIAlertAction(title: "确定", style: .default) { _ in done(true) })
        present(a, animated: true)
    }

    func webView(_ v: WKWebView, runJavaScriptTextInputPanelWithPrompt p: String, defaultText t: String?,
                 initiatedByFrame f: WKFrameInfo, completionHandler done: @escaping (String?) -> Void) {
        let a = UIAlertController(title: nil, message: p, preferredStyle: .alert)
        a.addTextField { $0.text = t }
        a.addAction(UIAlertAction(title: "取消", style: .cancel) { _ in done(nil) })
        a.addAction(UIAlertAction(title: "确定", style: .default) { _ in done(a.textFields?.first?.text) })
        present(a, animated: true)
    }

    // 断网 / 服务器连不上：显示 App 自己的提示页，不出现浏览器错误页
    func webView(_ v: WKWebView, didFailProvisionalNavigation n: WKNavigation!, withError e: Error) {
        if (e as NSError).code != NSURLErrorCancelled { showError() }
    }

    func webView(_ v: WKWebView, didFail n: WKNavigation!, withError e: Error) {
        if (e as NSError).code != NSURLErrorCancelled { showError() }
    }

    // 页面进程被系统杀掉（内存不足）时重新加载，不让 App 白屏
    func webViewWebContentProcessDidTerminate(_ v: WKWebView) {
        net.closeAll()
        if let u = home { v.load(URLRequest(url: u)) }
    }

    private func buildErrorView() {
        errorView.frame = view.bounds
        errorView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        errorView.backgroundColor = .black
        errorView.isHidden = true
        let label = UILabel()
        label.text = "网络连接失败，请检查网络后重试"
        label.textColor = .white
        label.font = .systemFont(ofSize: 18)
        label.textAlignment = .center
        let btn = UIButton(type: .system)
        btn.setTitle("重新连接", for: .normal)
        btn.titleLabel?.font = .systemFont(ofSize: 18)
        btn.addTarget(self, action: #selector(retry), for: .touchUpInside)
        let stack = UIStackView(arrangedSubviews: [label, btn])
        stack.axis = .vertical
        stack.spacing = 24
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        errorView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: errorView.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: errorView.centerYAnchor),
        ])
        view.addSubview(errorView)
    }

    private func showError() {
        web.isHidden = true
        errorView.isHidden = false
    }

    @objc private func retry() {
        guard let u = home else { return }
        errorView.isHidden = true
        web.isHidden = false
        web.load(URLRequest(url: u))
    }

    // 全屏横屏：藏状态栏，底部横条自动隐藏，从屏幕边缘滑不会误触系统手势
    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }
    override var preferredScreenEdgesDeferringSystemGestures: UIRectEdge { .all }
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .landscape }
    override var preferredInterfaceOrientationForPresentation: UIInterfaceOrientation { .landscapeRight }
}

// 网页叫的「关 App」：webkit.messageHandlers.rkmapp.postMessage({ op: 'quit' })，只认壳自己打包的那个站点的主页面。
// 震动：postMessage({ op: 'haptic', ms }) —— iOS 网页里没有 navigator.vibrate，壳替它震一下（轻 / 中 / 重三档按 ms 挑）。
// iOS 没有公开的「退出 App」：先像按了 Home 键那样退到桌面（suspend），再结束进程 ——
// 直接 exit 看着像闪退。退到桌面以后再 exit，下次点图标是重新启动
final class AppBridge: NSObject, WKScriptMessageHandler {
    private let homeHost: String

    init(homeHost: String) { self.homeHost = homeHost.lowercased() }

    func userContentController(_ uc: WKUserContentController, didReceive m: WKScriptMessage) {
        guard m.frameInfo.isMainFrame, !homeHost.isEmpty,
              m.frameInfo.securityOrigin.host.lowercased() == homeHost,
              let o = m.body as? [String: Any] else { return }
        if (o["op"] as? String) == "haptic" {
            let ms = (o["ms"] as? NSNumber)?.intValue ?? 10
            let style: UIImpactFeedbackGenerator.FeedbackStyle = ms >= 25 ? .heavy : ms >= 15 ? .medium : .light
            let g = UIImpactFeedbackGenerator(style: style)
            g.impactOccurred()
            return
        }
        guard (o["op"] as? String) == "quit" else { return }
        UIControl().sendAction(#selector(URLSessionTask.suspend), to: UIApplication.shared, for: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { exit(0) }
    }
}

// 给网页开原生 TCP —— 微端直连用（网页里只能开 WebSocket，微端说的是自己那套 TCP 协议）。
// 网页那边是 nativenet.mjs：postMessage({ op: 'open' | 'send' | 'close', id, host, port, data(base64) })，
// 这边回 window.__rkmNet(id, 'o' 连上 | 'd' 数据(base64) | 'c' 断了, 内容)。
// 只认壳自己打包的那个站点的主页面；内网、本机、组播地址一律不连（不让页面拿手机去扫它所在的局域网）。
// conns 只在主线程碰。
final class NetBridge: NSObject, WKScriptMessageHandler {
    weak var web: WKWebView?
    private let homeHost: String
    private var conns: [Int: NWConnection] = [:]
    private let q = DispatchQueue(label: "rkmnet")

    init(homeHost: String) { self.homeHost = homeHost.lowercased() }

    func userContentController(_ uc: WKUserContentController, didReceive m: WKScriptMessage) {
        guard m.frameInfo.isMainFrame, !homeHost.isEmpty,
              m.frameInfo.securityOrigin.host.lowercased() == homeHost,
              let o = m.body as? [String: Any], let op = o["op"] as? String,
              let id = (o["id"] as? NSNumber)?.intValue else { return }
        switch op {
        case "open":
            open(id, o["host"] as? String ?? "", (o["port"] as? NSNumber)?.intValue ?? 0)
        case "send":
            guard let c = conns[id], let s = o["data"] as? String, let d = Data(base64Encoded: s) else { return }
            c.send(content: d, completion: .contentProcessed { _ in })
        case "close":
            conns.removeValue(forKey: id)?.cancel()
        default:
            break
        }
    }

    func closeAll() {
        for c in conns.values { c.cancel() }
        conns.removeAll()
    }

    private func open(_ id: Int, _ host: String, _ port: Int) {
        guard !host.isEmpty, host.count <= 253, (1...65535).contains(port),
              let p = NWEndpoint.Port(rawValue: UInt16(port)) else { emit(id, "c", "bad address"); return }
        guard conns.count < 16 else { emit(id, "c", "too many"); return }
        q.async { [weak self] in
            let ip = NetBridge.resolvePublic(host)
            DispatchQueue.main.async {
                guard let self = self else { return }
                if let ip = ip { self.start(id, ip, p) } else { self.emit(id, "c", "private address") }
            }
        }
    }

    private func start(_ id: Int, _ ip: String, _ port: NWEndpoint.Port) {
        let c = NWConnection(host: NWEndpoint.Host(ip), port: port, using: .tcp)
        conns[id] = c
        var opened = false
        c.stateUpdateHandler = { [weak self] st in
            DispatchQueue.main.async {
                guard let self = self else { return }
                switch st {
                case .ready:
                    if !opened { opened = true; self.emit(id, "o", ""); self.receive(id, c) }
                case .failed(let e):
                    self.drop(id, c, "\(e)")
                case .waiting(let e):
                    if !opened { self.drop(id, c, "\(e)") }   // 没网 / 对面不通：别一直等
                case .cancelled:
                    self.drop(id, c, "closed")
                default:
                    break
                }
            }
        }
        c.start(queue: q)
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            if !opened { self?.drop(id, c, "timeout") }
        }
    }

    private func receive(_ id: Int, _ c: NWConnection) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, done, err in
            DispatchQueue.main.async {
                guard let self = self, self.conns[id] === c else { return }
                if let d = data, !d.isEmpty { self.emit(id, "d", d.base64EncodedString()) }
                if done || err != nil { self.drop(id, c, err.map { "\($0)" } ?? "closed") }
                else { self.receive(id, c) }
            }
        }
    }

    /// 这条断了：只报一次（网页主动关的已经从 conns 里拿掉了，不再报）
    private func drop(_ id: Int, _ c: NWConnection, _ why: String) {
        guard conns[id] === c else { return }
        conns.removeValue(forKey: id)
        c.cancel()
        emit(id, "c", why)
    }

    private static let safeChars = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=_ .-")

    private func emit(_ id: Int, _ ev: String, _ data: String) {
        // base64 和我们自己写的原因只有这些字符；防万一把引号、反斜杠、换行去掉
        let safe = String(data.filter { NetBridge.safeChars.contains($0) })
        web?.evaluateJavaScript("window.__rkmNet&&window.__rkmNet(\(id),'\(ev)','\(safe)')", completionHandler: nil)
    }

    /// 解析出第一个公网地址（内网、本机、链路本地、组播、运营商 NAT 段都不要）。在后台队列上调。
    static func resolvePublic(_ host: String) -> String? {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &res) == 0, let first = res else { return nil }
        defer { freeaddrinfo(first) }
        var p: UnsafeMutablePointer<addrinfo>? = first
        while let a = p {
            if a.pointee.ai_family == AF_INET, let sa = a.pointee.ai_addr {
                var sin = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
                if publicV4(UInt32(bigEndian: sin.sin_addr.s_addr)) {
                    var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                    if inet_ntop(AF_INET, &sin.sin_addr, &buf, socklen_t(INET_ADDRSTRLEN)) != nil { return String(cString: buf) }
                }
            } else if a.pointee.ai_family == AF_INET6, let sa = a.pointee.ai_addr {
                var sin6 = sa.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee }
                let b = withUnsafeBytes(of: &sin6.sin6_addr) { Array($0) }
                if publicV6(b) {
                    var buf = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
                    if inet_ntop(AF_INET6, &sin6.sin6_addr, &buf, socklen_t(INET6_ADDRSTRLEN)) != nil { return String(cString: buf) }
                }
            }
            p = a.pointee.ai_next
        }
        return nil
    }

    static func publicV4(_ v: UInt32) -> Bool {
        let a = v >> 24, b = (v >> 16) & 0xff
        if a == 0 || a == 10 || a == 127 || a >= 224 { return false }
        if a == 169 && b == 254 { return false }
        if a == 172 && b >= 16 && b <= 31 { return false }
        if a == 192 && b == 168 { return false }
        if a == 100 && b >= 64 && b <= 127 { return false }
        if a == 198 && (b == 18 || b == 19) { return false }
        return true
    }

    static func publicV6(_ b: [UInt8]) -> Bool {
        guard b.count == 16 else { return false }
        if b[0..<10].allSatisfy({ $0 == 0 }) && b[10] == 0xff && b[11] == 0xff {   // ::ffff:a.b.c.d
            let v = UInt32(b[12]) << 24 | UInt32(b[13]) << 16 | UInt32(b[14]) << 8 | UInt32(b[15])
            return publicV4(v)
        }
        if b[0..<15].allSatisfy({ $0 == 0 }) { return false }                     // :: 和 ::1
        if b[0] == 0xff { return false }                                           // 组播
        if b[0] == 0xfe && (b[1] & 0xc0) == 0x80 { return false }                 // fe80::/10
        if (b[0] & 0xfe) == 0xfc { return false }                                  // fc00::/7
        return true
    }
}

// 本机文件桥 —— 打包客户端读写本机补丁（LOCALRES.md §1，和 exe / 安卓壳同一套语义）。
// 网页那边是 localfs.mjs：const r = await webkit.messageHandlers.rkmfs.postMessage({ op, path, offset, length, data, size, dir, from, to })
// 应答 = { ok: true, r: 结果 } 或 { ok: false, err: '原因' }（localfs.mjs 文件头）；结果：stat 的对象 / null、read 的 base64 字符串、true、list 的数组。
// 消息里带了数字 id 的回 window.__rkmfsCb(id, 应答)（localfs.mjs 用这个）；postMessage 返回的 Promise 也给同一个应答（不带 id 时用它）。
// 根目录 ROOT = Application Support/game。路径相对 ROOT，正反斜杠都认；不许 ..、盘符、绝对路径、: * ? " < > | 和控制字符，最长 260。
// 手机文件系统分大小写：每一级先找同名的，没有再按不分大小写找已有的。一次最多读 16MB。
// 只认壳自己打包的那个站点的主页面（协议 + 主机 + 端口都对上）。文件操作在一条后台队列上按到达顺序做。
struct FsErr: Error {
    let msg: String
    init(_ m: String) { msg = m }
}

final class FsBridge: NSObject, WKScriptMessageHandlerWithReply {
    static let maxRead = 16 << 20
    weak var web: WKWebView?
    var muiHash = ""
    private let root: URL
    private let home: URL?
    private let q = DispatchQueue(label: "rkmfs")

    init(root: URL, home: URL?) {
        self.root = root
        self.home = home
    }

    private func allowed(_ m: WKScriptMessage) -> Bool {
        guard m.frameInfo.isMainFrame, let h = home, let hh = h.host?.lowercased(), let hs = h.scheme?.lowercased() else { return false }
        let o = m.frameInfo.securityOrigin
        guard o.host.lowercased() == hh, o.protocol.lowercased() == hs else { return false }
        let def = hs == "https" ? 443 : 80
        return (o.port == 0 ? def : o.port) == (h.port ?? def)
    }

    func userContentController(_ uc: WKUserContentController, didReceive m: WKScriptMessage,
                               replyHandler: @escaping (Any?, String?) -> Void) {
        guard allowed(m), let o = m.body as? [String: Any] else { replyHandler(["ok": false, "err": "not allowed"], nil); return }
        let id = (o["id"] as? NSNumber)?.intValue
        q.async { [weak self] in
            guard let self = self else { return }
            let r = self.handle(o)
            DispatchQueue.main.async {
                replyHandler(r, nil)
                if let id = id, let d = try? JSONSerialization.data(withJSONObject: r, options: .fragmentsAllowed),
                   let s = String(data: d, encoding: .utf8) {
                    self.web?.evaluateJavaScript("window.__rkmfsCb&&window.__rkmfsCb(\(id),\(s))", completionHandler: nil)
                }
            }
        }
    }

    private func handle(_ o: [String: Any]) -> Any {
        do {
            let r = try op(o)
            return ["ok": true, "r": r]
        }
        catch let e as FsErr { return ["ok": false, "err": e.msg] }
        catch {
            let e = error as NSError
            if (e.domain == NSCocoaErrorDomain && (e.code == NSFileNoSuchFileError || e.code == NSFileReadNoSuchFileError))
                || (e.domain == NSPOSIXErrorDomain && e.code == Int(ENOENT)) { return ["ok": false, "err": "not found"] }
            if (e.domain == NSCocoaErrorDomain && e.code == NSFileWriteOutOfSpaceError)
                || (e.domain == NSPOSIXErrorDomain && e.code == Int(ENOSPC)) { return ["ok": false, "err": "disk full"] }
            return ["ok": false, "err": "io error"]
        }
    }

    private static func str(_ o: [String: Any], _ k: String) throws -> String {
        guard let s = o[k] as? String else { throw FsErr("bad path") }
        return s
    }

    private static func num(_ o: [String: Any], _ k: String) -> Int64? { (o[k] as? NSNumber)?.int64Value }

    private func op(_ o: [String: Any]) throws -> Any {
        let fm = FileManager.default
        switch o["op"] as? String ?? "" {
        case "info":
            let free = (try? root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
                .volumeAvailableCapacityForImportantUsage ?? 0
            var r: [String: Any] = ["root": root.path, "free": free, "version": 1, "maxRead": FsBridge.maxRead, "platform": "ios"]
            r["mui"] = muiHash.isEmpty ? NSNull() : ["base": "rkmb://mui/", "hash": muiHash]
            return r
        case "stat":
            let u = try FsBridge.resolve(root, FsBridge.str(o, "path"), false)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: u.path, isDirectory: &isDir) else { return NSNull() }
            let a = try fm.attributesOfItem(atPath: u.path)
            let mt = ((a[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0) * 1000
            var r: [String: Any] = ["size": isDir.boolValue ? 0 : ((a[.size] as? NSNumber)?.int64Value ?? 0), "mtime": Int64(mt)]
            if isDir.boolValue { r["dir"] = true }
            return r
        case "read":
            let u = try FsBridge.resolve(root, FsBridge.str(o, "path"), false)
            let off = max(0, FsBridge.num(o, "offset") ?? 0)
            var len = FsBridge.num(o, "length") ?? -1
            if len < 0 || len > Int64(FsBridge.maxRead) { len = Int64(FsBridge.maxRead) }
            let h = try FileHandle(forReadingFrom: u)
            defer { try? h.close() }
            let size = try h.seekToEnd()
            if UInt64(off) >= size { return "" }
            try h.seek(toOffset: UInt64(off))
            let n = Int(min(UInt64(len), size - UInt64(off)))
            return (try h.read(upToCount: n) ?? Data()).base64EncodedString()
        case "write":
            let u = try FsBridge.resolve(root, FsBridge.str(o, "path"), false)
            if FsBridge.execExt(u.lastPathComponent) { throw FsErr("denied") }
            let off = FsBridge.num(o, "offset") ?? 0
            if off < -1 { throw FsErr("bad offset") }
            let s = o["data"] as? String ?? ""
            guard let d = s.isEmpty ? Data() : Data(base64Encoded: s, options: .ignoreUnknownCharacters) else { throw FsErr("bad data") }
            try fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !fm.fileExists(atPath: u.path) && !fm.createFile(atPath: u.path, contents: nil) { throw FsErr("io error") }
            let h = try FileHandle(forWritingTo: u)
            defer { try? h.close() }
            if off == -1 { _ = try h.seekToEnd() } else { try h.seek(toOffset: UInt64(off)) }
            try h.write(contentsOf: d)
            return true
        case "truncate":
            let u = try FsBridge.resolve(root, FsBridge.str(o, "path"), false)
            if FsBridge.execExt(u.lastPathComponent) { throw FsErr("denied") }
            guard let size = FsBridge.num(o, "size"), size >= 0 else { throw FsErr("bad size") }
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: u.path, isDirectory: &isDir), !isDir.boolValue else { throw FsErr("not found") }
            let h = try FileHandle(forWritingTo: u)
            defer { try? h.close() }
            try h.truncate(atOffset: UInt64(size))
            return true
        case "list":
            let d = try FsBridge.resolve(root, o["dir"] != nil ? FsBridge.str(o, "dir") : FsBridge.str(o, "path"), true)
            let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey]
            guard let items = try? fm.contentsOfDirectory(at: d, includingPropertiesForKeys: keys) else { return [Any]() }
            return items.map { u -> [String: Any] in
                let v = try? u.resourceValues(forKeys: Set(keys))
                let dir = v?.isDirectory ?? false
                return ["name": u.lastPathComponent, "dir": dir, "size": dir ? 0 : (v?.fileSize ?? 0)]
            }
        case "remove":
            let u = try FsBridge.resolve(root, FsBridge.str(o, "path"), false)
            if FsBridge.execExt(u.lastPathComponent) { throw FsErr("denied") }
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: u.path, isDirectory: &isDir) else { return true }
            if isDir.boolValue { throw FsErr("is directory") }
            try fm.removeItem(at: u)
            return true
        case "rename":
            let a = try FsBridge.resolve(root, FsBridge.str(o, "from"), false)
            let b = try FsBridge.resolve(root, FsBridge.str(o, "to"), false)
            if FsBridge.execExt(a.lastPathComponent) || FsBridge.execExt(b.lastPathComponent) { throw FsErr("denied") }
            guard fm.fileExists(atPath: a.path) else { throw FsErr("not found") }
            if a.path == b.path { return true }
            try fm.createDirectory(at: b.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fm.fileExists(atPath: b.path) { try fm.removeItem(at: b) }   // 覆盖目标
            try fm.moveItem(at: a, to: b)
            return true
        default:
            throw FsErr("bad op")
        }
    }

    // 一段路径里不许的：空、. / ..、结尾是点或空格、设备名（和 exe 壳一样，免得同一套补丁换个平台就不认）
    static func badSeg(_ s: String) -> Bool {
        if s.isEmpty || s == "." || s == ".." { return true }
        if s.hasSuffix(".") || s.hasSuffix(" ") { return true }
        let base = (s.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? s).uppercased()
        if ["CON", "PRN", "AUX", "NUL"].contains(base) { return true }
        if base.count == 4 && (base.hasPrefix("COM") || base.hasPrefix("LPT")),
           let c = base.unicodeScalars.last, c.value >= 48 && c.value <= 57 { return true }
        return false
    }

    /// 相对路径拆成一段段（不合法抛 bad path）；空：allowRoot 时给空数组（= ROOT 本身）
    static func segs(_ rel: String, _ allowRoot: Bool) throws -> [String] {
        guard rel.utf16.count <= 260 else { throw FsErr("bad path") }
        let bad = Set("<>:\"|?*".unicodeScalars)
        for c in rel.unicodeScalars where c.value < 32 || bad.contains(c) { throw FsErr("bad path") }
        var s = rel.replacingOccurrences(of: "\\", with: "/")
        if s.hasSuffix("/") { s.removeLast() }
        if s.hasPrefix("/") { throw FsErr("bad path") }
        if s.isEmpty {
            if allowRoot { return [] }
            throw FsErr("bad path")
        }
        let parts = s.components(separatedBy: "/")
        for p in parts where badSeg(p) { throw FsErr("bad path") }
        return parts
    }

    /// 相对路径 → ROOT 下的文件。每一级先认同名的，没有再不分大小写找已有的；都没有就照给的名字（新建用）
    static func resolve(_ root: URL, _ rel: String, _ allowRoot: Bool) throws -> URL {
        let fm = FileManager.default
        var cur = root
        var exists = true
        for p in try segs(rel, allowRoot) {
            var next = cur.appendingPathComponent(p)
            if exists && !fm.fileExists(atPath: next.path) {
                if let m = (try? fm.contentsOfDirectory(atPath: cur.path))?
                    .first(where: { $0.caseInsensitiveCompare(p) == .orderedSame }) {
                    next = cur.appendingPathComponent(m)
                } else { exists = false }
            }
            cur = next
        }
        return cur
    }

    // 改动类操作不许碰可执行的东西（和 exe 壳同一张表）
    static func execExt(_ name: String) -> Bool {
        guard let d = name.lastIndex(of: ".") else { return false }
        let e = name[name.index(after: d)...].lowercased()
        return ["exe", "dll", "com", "bat", "cmd", "scr", "pif", "cpl", "msi", "lnk", "ps1", "vbs", "vbe",
                "js", "jse", "wsf", "hta", "reg", "sys", "url"].contains(e)
    }
}

// 包里的手机界面：rkmb://mui/ui/game.json、rkmb://mui/res/Game/x.png → Shell.app/bundle/mui/...；
// 包里没有的到站点自己的 /mobileui/... 去拿（带打包密钥 cookie）。回的都带 Access-Control-Allow-Origin: *（页面是 http(s) 的，fetch 跨源）。
// WKWebView 拦不了 http(s)，只能换个自定义协议 —— 页面看 window.__rkmMui.base（'rkmb://mui/'）换 uiBase / res。
final class MuiSchemeHandler: NSObject, WKURLSchemeHandler {
    private let base: URL
    private let home: URL?
    private let gateKey: String
    private var live = Set<ObjectIdentifier>()   // 还没被 stop 的请求（stop 了再回会崩）

    init(base: URL, home: URL?, gateKey: String) {
        self.base = base
        self.home = home
        self.gateKey = gateKey
    }

    func webView(_ v: WKWebView, start t: WKURLSchemeTask) {
        live.insert(ObjectIdentifier(t))
        guard let u = t.request.url, u.host?.lowercased() == "mui" else { respond(t, 404, Data()); return }
        let rel = String(u.path.drop(while: { $0 == "/" }))
        guard rel.hasPrefix("ui/") || rel.hasPrefix("res/"), !rel.contains(".."), !rel.contains("//") else {
            respond(t, 404, Data()); return
        }
        if let d = try? Data(contentsOf: base.appendingPathComponent(rel)) { respond(t, 200, d); return }
        guard let h = home, var c = URLComponents(url: h, resolvingAgainstBaseURL: false) else { respond(t, 404, Data()); return }
        c.path = "/mobileui/" + rel
        c.query = nil
        c.fragment = nil
        guard let nu = c.url else { respond(t, 404, Data()); return }
        var req = URLRequest(url: nu)
        if !gateKey.isEmpty { req.setValue("__rkmkey=" + gateKey, forHTTPHeaderField: "Cookie") }
        URLSession.shared.dataTask(with: req) { [weak self] data, resp, _ in
            DispatchQueue.main.async {
                let code = data == nil ? 502 : ((resp as? HTTPURLResponse)?.statusCode ?? 502)
                self?.respond(t, code, data ?? Data())
            }
        }.resume()
    }

    func webView(_ v: WKWebView, stop t: WKURLSchemeTask) { live.remove(ObjectIdentifier(t)) }

    private func respond(_ t: WKURLSchemeTask, _ code: Int, _ d: Data) {
        guard live.remove(ObjectIdentifier(t)) != nil, let u = t.request.url else { return }
        let ext = u.pathExtension.lowercased()
        let mime = ["json": "application/json; charset=utf-8", "png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg",
                    "webp": "image/webp", "gif": "image/gif", "svg": "image/svg+xml", "mp3": "audio/mpeg", "ogg": "audio/ogg"][ext]
            ?? "application/octet-stream"
        guard let r = HTTPURLResponse(url: u, statusCode: code, httpVersion: "HTTP/1.1", headerFields: [
            "Content-Type": mime, "Content-Length": String(d.count),
            "Access-Control-Allow-Origin": "*", "Cache-Control": "no-cache"]) else { return }
        t.didReceive(r)
        t.didReceive(d)
        t.didFinish()
    }
}
