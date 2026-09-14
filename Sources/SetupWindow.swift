import AppKit

/// Identity + SSH key, the stuff you do once on a new machine.
final class SetupWindow: NSObject {

    static let shared = SetupWindow()

    private(set) var window: NSWindow?
    private var logSink: ((String, Bool) -> Void)?

    private let gitLabel = V.label("", tone: .soft, delta: -1)
    private let nameField = V.field("Your name 名字")
    private let mailField = V.field("Your email 邮箱")
    private let keyLabel = V.label("", tone: .soft, delta: -1)
    private let keyView = SkinTextView()
    private let hostField = V.field("github.com")
    private let testLabel = V.label("", tone: .soft, delta: -1)
    private var copyBtn = SkinButton()
    private var createBtn = SkinButton()
    private var testBtn = SkinButton()
    private var creatingKey = false
    private var testing = false
    var operationInProgress: Bool { creatingKey || testing }

    func show(log: @escaping (String, Bool) -> Void) {
        logSink = log
        if window == nil {
            build()
            window?.center()          // only the first time; after that the frame is remembered
        }
        reload()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func build() {
        guard window == nil else { return }
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 520),
                         styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        w.title = "Setup 环境与 SSH"
        w.isReleasedWhenClosed = false
        w.titlebarAppearsTransparent = true
        w.minSize = NSSize(width: 520, height: 480)
        if !SelfTest.headless { w.setFrameAutosaveName("JustGitSetup") }

        let content = SkinView()
        w.contentView = content

        hostField.stringValue = "github.com"

        let saveBtn = V.button("Save identity 保存身份", self, #selector(save), kind: .primary)
        createBtn = SkinButton("Create SSH key 生成钥匙", self, #selector(createKey), kind: .primary)
        copyBtn = SkinButton("Copy public key 复制公钥", self, #selector(copyKey))
        testBtn = V.button("Test 测试连接", self, #selector(test))
        let openBtn = V.button("Open GitHub keys page", self, #selector(openKeysPage), kind: .micro)

        keyView.isEditable = false
        keyView.usesConsoleColours = false
        keyView.textContainerInset = NSSize(width: 10, height: 8)
        keyView.restyle()
        keyView.isVerticallyResizable = true
        keyView.autoresizingMask = [.width]
        keyView.textContainer?.widthTracksTextView = true
        let keyScroll = SkinWell()
        keyScroll.usesConsoleColours = false
        keyScroll.documentView = keyView
        keyScroll.restyle()
        keyScroll.heightAnchor.constraint(equalToConstant: 92).isActive = true

        let rows: [NSView] = [
            V.title("1 · Git"),
            gitLabel,
            V.hairline(),
            V.title("2 · Who are you 你是谁"),
            nameField, mailField,
            V.hstack([saveBtn, NSView()]),
            V.hairline(),
            V.title("3 · SSH key 免密钥匙"),
            keyLabel,
            keyScroll,
            V.hstack([createBtn, copyBtn, NSView()]),
            V.hstack([openBtn, NSView()]),
            V.label("Paste the public key into your git host's SSH-keys page.\n把公钥贴到代码平台的 SSH Keys 页面。",
                    tone: .faint, delta: -2),
            V.hairline(),
            V.title("4 · Test 测一下"),
            V.hstack([hostField, testBtn]),
            testLabel,
        ]
        let stack = V.vstack(rows, spacing: 9, align: .leading)
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 18),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -18),
        ])
        for r in rows {
            r.translatesAutoresizingMaskIntoConstraints = false
            r.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        hostField.widthAnchor.constraint(equalToConstant: 240).isActive = true
        testLabel.lineBreakMode = .byWordWrapping
        testLabel.maximumNumberOfLines = 3
        window = w
        Skin.repaint(w)
        // No skin observer: Skin.set already repaints every open window, and
        // re-reading git config and the key file on each skin change would run
        // three subprocesses for nothing.
    }

    private func reload() {
        gitLabel.stringValue = Git.installed ? GitEnv.version : "git is NOT installed — run: xcode-select --install"
        gitLabel.tone = Git.installed ? .soft : .negative
        if nameField.stringValue.isEmpty { nameField.stringValue = GitEnv.globalConfig("user.name") }
        if mailField.stringValue.isEmpty { mailField.stringValue = GitEnv.globalConfig("user.email") }
        let has = GitEnv.hasKey
        keyLabel.stringValue = has ? "✓ " + GitEnv.keyPath : "no key yet 还没有钥匙"
        keyLabel.tone = has ? .positive : .caution
        let publicKey = GitEnv.publicKey
        keyView.string = publicKey
        createBtn.title = has ? "Recover public key 恢复公钥" : "Create SSH key 生成钥匙"
        createBtn.restyle()
        createBtn.isEnabled = !creatingKey && (!has || publicKey.isEmpty)
        copyBtn.isEnabled = !publicKey.isEmpty
        if has && publicKey.isEmpty {
            keyLabel.stringValue = "Private key exists, but the public key is missing or unreadable."
            keyLabel.tone = .caution
        }
        if let window = window { UI.fit(window) }
    }

    @objc private func save() {
        let n = nameField.stringValue.trimmingCharacters(in: .whitespaces)
        let m = mailField.stringValue.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty, !m.isEmpty else { UI.error("Name and email required 名字和邮箱都要填"); return }
        for (key, value) in [("user.name", n), ("user.email", m)] {
            let result = GitEnv.setGlobal(key, value)
            guard result.ok else {
                UI.error("Could not save identity", result.text + "\nCheck permissions on ~/.gitconfig, then retry.")
                return
            }
        }
        logSink?("Git identity saved.", false)
        UI.info("Saved 已保存", "\(n) <\(m)>")
    }

    /// ssh-keygen plus ssh-add can take a few seconds; doing that on the main
    /// thread freezes the whole app, so it runs in the background with the
    /// buttons locked out.
    @objc private func createKey() {
        guard !creatingKey else { return }
        let mail = mailField.stringValue.trimmingCharacters(in: .whitespaces)
        guard GitEnv.hasKey || !mail.isEmpty else { UI.error("Fill your email first 先填邮箱"); return }
        creatingKey = true
        createBtn.isEnabled = false
        keyLabel.stringValue = "making a key… 正在生成"
        keyLabel.tone = .soft
        DispatchQueue.global(qos: .userInitiated).async {
            let r = GitEnv.createKey(comment: mail)
            DispatchQueue.main.async {
                self.creatingKey = false
                if r.ok {
                    UI.copyToClipboard(GitEnv.publicKey)
                    self.logSink?("SSH key created, public key copied to clipboard", false)
                    self.reload()
                    UI.info("Key created 钥匙已生成", "Public key is on your clipboard.\n公钥已复制，去代码平台粘贴。")
                } else {
                    self.logSink?("ssh-keygen failed: " + r.text, true)
                    self.reload()
                    UI.error("ssh-keygen failed", r.text)
                }
            }
        }
    }

    @objc private func copyKey() {
        guard !GitEnv.publicKey.isEmpty else {
            reload()
            UI.error("Public key unavailable", "Use Recover public key first.")
            return
        }
        UI.copyToClipboard(GitEnv.publicKey)
        // say it next to the button that was pressed, not down in section 4
        keyLabel.stringValue = "public key copied 公钥已复制"
        keyLabel.tone = .positive
    }

    @objc private func openKeysPage() {
        if let u = URL(string: "https://github.com/settings/ssh/new") { NSWorkspace.shared.open(u) }
    }

    @objc private func test() {
        guard !testing else { return }
        let host = hostField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else { return }
        testing = true
        testBtn.isEnabled = false
        testLabel.stringValue = "testing… 测试中"
        testLabel.tone = .soft
        DispatchQueue.global().async {
            let r = GitEnv.testConnection(host: host)
            let out = r.text.split(separator: "\n").prefix(2).joined(separator: " ")
            DispatchQueue.main.async {
                self.testing = false
                self.testBtn.isEnabled = true
                let good = GitEnv.connectionSucceeded(r)
                self.testLabel.stringValue = out.isEmpty ? (good ? "reachable 通了" : "denied") : out
                self.testLabel.tone = good ? .positive : .negative
                self.logSink?("ssh \(host): " + (out.isEmpty ? "no output" : out), !good)
            }
        }
    }
}
