import UIKit
import Darwin

// Real UIKit integration fixture. State is written by the guest, so host tests verify
// that input reached iOS rather than merely checking that the host sent a message.
@MainActor final class QAState {
    static let shared = QAState()
    var values: [String: Any] = ["taps": 0, "moves": 0, "begins": 0, "ends": 0, "maxTouches": 0, "text": "", "keyboardVisible": false, "keyboardHeight": 0]
    func set(_ key: String, _ value: Any) { values[key] = value; save() }
    func increment(_ key: String) { set(key, (values[key] as? Int ?? 0) + 1) }
    func save() {
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        if let data = try? JSONSerialization.data(withJSONObject: values, options: [.sortedKeys]) {
            try? data.write(to: directory.appendingPathComponent("state.json"), options: .atomic)
        }
    }
}

final class TouchCanvas: UIView {
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        QAState.shared.increment("begins")
        QAState.shared.set("maxTouches", max(QAState.shared.values["maxTouches"] as? Int ?? 0, event?.allTouches?.count ?? 0))
    }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) { QAState.shared.increment("moves") }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { QAState.shared.increment("ends") }
}

final class QAController: UIViewController {
    let text = UITextField()
    let button = UIButton(type: .system)
    let canvas = TouchCanvas()
    var keyboardStateTimer: Timer?
    override var canBecomeFirstResponder: Bool { true }
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        becomeFirstResponder()
    }
    override func motionEnded(_ motion: UIEvent.EventSubtype, with event: UIEvent?) {
        if motion == .motionShake { QAState.shared.increment("shakes") }
        super.motionEnded(motion, with: event)
    }
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        let title = UILabel()
        title.text = "Siniulator · Input QA"
        title.font = .systemFont(ofSize: 24, weight: .semibold)
        title.frame = CGRect(x: 24, y: 70, width: 350, height: 40)
        view.addSubview(title)
        text.borderStyle = .roundedRect
        text.placeholder = "Type here"
        text.autocorrectionType = .no
        text.autocapitalizationType = .none
        // Keep this input fixture deterministic: a new guest's multilingual
        // keyboard onboarding otherwise intercepts the software keyboard toggle.
        text.keyboardType = .asciiCapable
        text.addTarget(self, action: #selector(changed), for: .editingChanged)
        text.frame = CGRect(x: 24, y: 130, width: 350, height: 48)
        view.addSubview(text)
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardFrameChanged), name: UIResponder.keyboardDidChangeFrameNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardHidden), name: UIResponder.keyboardDidHideNotification, object: nil)
        if let library = dlopen("/System/Library/PrivateFrameworks/GraphicsServices.framework/GraphicsServices", RTLD_LAZY),
           let symbol = dlsym(library, "GSEventIsHardwareKeyboardAttached") {
            let attached = unsafeBitCast(symbol, to: (@convention(c) () -> Bool).self)
            keyboardStateTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
                MainActor.assumeIsolated {
                    let value = attached()
                    if QAState.shared.values["hardwareKeyboardAttached"] as? Bool != value {
                        QAState.shared.set("hardwareKeyboardAttached", value)
                    }
                }
            }
        }
        button.setTitle("Tap counter: 0", for: .normal)
        button.backgroundColor = .systemBlue.withAlphaComponent(0.12)
        button.layer.cornerRadius = 10
        button.frame = CGRect(x: 24, y: 200, width: 350, height: 56)
        button.addTarget(self, action: #selector(tapped), for: .touchUpInside)
        view.addSubview(button)
        canvas.backgroundColor = .systemTeal.withAlphaComponent(0.2)
        canvas.layer.cornerRadius = 12
        canvas.isMultipleTouchEnabled = true
        canvas.frame = CGRect(x: 24, y: 290, width: 350, height: 360)
        view.addSubview(canvas)
        QAState.shared.set("ready", true)
    }
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        QAState.shared.set("width", view.bounds.width)
        QAState.shared.set("height", view.bounds.height)
    }
    @objc func changed() { QAState.shared.set("text", text.text ?? "") }
    @objc func keyboardFrameChanged(_ notification: Notification) {
        guard let frame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
        let overlap = view.bounds.intersection(view.convert(frame, from: nil))
        let height = overlap.isNull ? 0 : overlap.height
        QAState.shared.values["keyboardHeight"] = height
        QAState.shared.set("keyboardVisible", height > 150)
    }
    @objc func keyboardHidden(_ notification: Notification) {
        QAState.shared.values["keyboardHeight"] = 0
        QAState.shared.set("keyboardVisible", false)
    }
    @objc func tapped() {
        text.resignFirstResponder()
        becomeFirstResponder()
        QAState.shared.increment("taps")
        button.setTitle("Tap counter: \(QAState.shared.values["taps"]!)", for: .normal)
        let tap = QAState.shared.values["taps"] as? Int ?? 0
        let started = CACurrentMediaTime()
        UIView.animate(withDuration: 0.2, delay: 0, options: [.curveLinear]) {
            self.canvas.alpha = tap.isMultiple(of: 2) ? 1 : 0.6
        } completion: { _ in
            QAState.shared.values["animationTap"] = tap
            QAState.shared.set("animationDuration", CACurrentMediaTime() - started)
        }
    }
}

final class QAWindow: UIWindow {
    override func sendEvent(_ event: UIEvent) {
        if let touch = event.allTouches?.first {
            QAState.shared.values["eventReceiptUptime"] = CACurrentMediaTime()
            if event.allTouches?.contains(where: { $0.phase == .began }) == true {
                QAState.shared.values["touchBeginReceiptUptime"] = CACurrentMediaTime()
            }
            QAState.shared.values["touchPositions"] = (event.allTouches ?? []).map {
                let point = $0.location(in: self)
                return ["x": point.x, "y": point.y]
            }
            let point = touch.location(in: self)
            QAState.shared.set("eventX", point.x)
            QAState.shared.set("eventY", point.y)
            QAState.shared.increment("events")
        }
        super.sendEvent(event)
    }
}

final class QAScene: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let scene = scene as? UIWindowScene else { return }
        window = QAWindow(windowScene: scene)
        window?.rootViewController = QAController()
        window?.makeKeyAndVisible()
        QAState.shared.set("foreground", true)
    }
    func sceneDidEnterBackground(_ scene: UIScene) { QAState.shared.set("foreground", false) }
    func sceneDidBecomeActive(_ scene: UIScene) { QAState.shared.set("foreground", true) }
}

@main final class QAApp: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession, options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: "QA", sessionRole: connectingSceneSession.role)
        configuration.delegateClass = QAScene.self
        return configuration
    }
}
