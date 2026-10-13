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
    private var net: NetBridge!     // 给网页开 TCP（微端直连），见文件末尾

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        loadConfig()
        createWeb()
        buildErrorView()
        if let u = home { web.load(URLRequest(url: u)) } else { showError() }
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
