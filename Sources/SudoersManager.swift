import Foundation
import OSLog

private let logger = Logger(subsystem: "com.local.ChangeIcon", category: "SudoersManager")

// MARK: - Errors

enum SudoersError: LocalizedError {
    case sudoNotAvailable(String)
    case installFailed(String)
    case uninstallFailed(String)
    case validationFailed(String)
    case scriptError(String)
    case adminCancelled

    var errorDescription: String? {
        switch self {
        case .sudoNotAvailable(let m):
            return "sudo 不可用: \(m)"
        case .installFailed(let m):
            return "sudoers 安装失败: \(m)"
        case .uninstallFailed(let m):
            return "sudoers 清理失败: \(m)"
        case .validationFailed(let m):
            return "验证失败: \(m)"
        case .scriptError(let m):
            return "脚本执行失败: \(m)"
        case .adminCancelled:
            return "管理员授权被取消"
        }
    }
}

// MARK: - SudoersManager

/// Manages the lifecycle of `/etc/sudoers.d/changeicon` — the NOPASSWD rule
/// that allows ChangeIcon to invoke `seticon_helper` via `sudo` without a
/// password prompt on every icon switch.
///
/// ## Architecture
///
/// - `checkConfiguration()` checks `/etc/sudoers.d/changeicon` file existence.
///   Since the file was validated by `visudo -c` at install time, file presence
///   is sufficient to confirm the rule is active.
/// - `install()` uses `osascript with administrator privileges` to write
///   the sudoers rule file and, if necessary, amend `/etc/sudoers` with
///   `#includedir /etc/sudoers.d`.
/// - `uninstall()` removes the rule file but leaves `/etc/sudoers` untouched
///   (other applications may rely on `#includedir`).
/// - `validateRuleContent()` compares the helper path baked into the rule
///   with the current bundle path so that App-update path changes are detected.
@MainActor
final class SudoersManager: ObservableObject {
    @Published var isConfigured = false

    static let shared = SudoersManager()

    /// Absolute path to the sudoers drop-in file managed by ChangeIcon.
    nonisolated static let sudoersDropInPath = "/etc/sudoers.d/changeicon"

    /// Path to the system sudoers main file.
    nonisolated static let sudoersMainPath = "/etc/sudoers"

    private let defaults = UserDefaults.standard
    private let rejectionKey = "sudoers_setup_rejected"

    // MARK: - Public API

    /// Verify whether the NOPASSWD rule is active.
    ///
    /// Checks for the presence of `/etc/sudoers.d/changeicon` on disk.
    /// The file contents were validated by `visudo -c` at install time.
    ///
    /// We intentionally do **not** test `sudo -n true` because the rule
    /// only covers the `seticon` helper and its `set`/`remove` subcommands
    /// — testing an arbitrary command like `true` produces a false negative.
    ///
    /// - Returns: `true` when the drop-in file exists.
    @discardableResult
    func checkConfiguration() async -> Bool {
        logger.info("checkConfiguration: checking rule file existence")
        let fileExists = checkFileExists()
        logger.info("checkConfiguration: fileExists=\(fileExists) → isConfigured = \(fileExists)")
        isConfigured = fileExists
        return fileExists
    }

    /// Check whether the sudoers drop-in file exists on disk.
    ///
    /// Uses a `test -f` shell command which can traverse `/etc/sudoers.d/`
    /// without requiring sudo or special entitlements on macOS.
    ///
    /// - Returns: `true` when `/etc/sudoers.d/changeicon` is present.
    func checkFileExists() -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/test")
        p.arguments = ["-f", Self.sudoersDropInPath]
        p.standardOutput = Pipe()
        p.standardError = Pipe()
        do {
            try p.run()
            p.waitUntilExit()
        } catch {
            logger.warning("checkFileExists: test -f failed to run: \(error.localizedDescription)")
            // Fall back to FileManager
            return FileManager.default.fileExists(atPath: Self.sudoersDropInPath)
        }
        let exists = p.terminationStatus == 0
        logger.info("checkFileExists: \(Self.sudoersDropInPath, privacy: .public) → \(exists)")
        return exists
    }

    /// Install the ChangeIcon sudoers rule so that `seticon_helper` can be
    /// invoked via `sudo -n` without a password prompt.
    ///
    /// This method presents **one** `osascript with administrator privileges`
    /// dialog to the user.  The elevated shell script:
    ///
    /// 1. Appends `#includedir /etc/sudoers.d` to `/etc/sudoers` if missing.
    /// 2. Writes the rule to `/etc/sudoers.d/changeicon` (mode 0440).
    /// 3. Validates both files with `visudo -c`.
    /// 4. Rolls back on any failure.
    ///
    /// - Throws: `SudoersError` on any failure.
    func install() async throws {
        logger.info("install: starting sudoers rule installation")

        guard let helperPath = resolveHelperPath() else {
            throw SudoersError.installFailed("无法定位 seticon helper 路径")
        }

        let username = NSUserName()
        let ruleContent = Self.makeRuleContent(username: username, helperPath: helperPath)
        let installScript = Self.makeInstallScript(ruleContent: ruleContent)

        logger.info("install: helperPath=\(helperPath, privacy: .public) username=\(username, privacy: .public)")

        do {
            let output = try await runAdminShellScript(installScript, prompt: "ChangeIcon 需要一次性配置管理员权限，以便后续免密码切换图标。")
            logger.info("install: success — output: \(output, privacy: .public)")
            isConfigured = true
            defaults.set(false, forKey: rejectionKey)
        } catch let error as SudoersError {
            logger.error("install: failed — \(error.errorDescription ?? "unknown", privacy: .public)")
            throw error
        } catch {
            logger.error("install: failed — \(error.localizedDescription, privacy: .public)")
            throw SudoersError.installFailed(error.localizedDescription)
        }
    }

    /// Remove the ChangeIcon sudoers rule file.
    ///
    /// The `#includedir` directive in `/etc/sudoers` is intentionally **not**
    /// removed because other applications may depend on it.
    ///
    /// - Throws: `SudoersError` on any failure.
    func uninstall() async throws {
        logger.info("uninstall: removing sudoers rule")

        let script = """
        if [ -f '\(Self.sudoersDropInPath)' ]; then
            rm -f '\(Self.sudoersDropInPath)'
            echo "REMOVED"
        else
            echo "NOT_FOUND"
        fi
        """

        do {
            let output = try await runAdminShellScript(script, prompt: "ChangeIcon 需要管理员权限来移除免密码授权配置。")
            logger.info("uninstall: result — \(output, privacy: .public)")
            isConfigured = false
            defaults.set(false, forKey: rejectionKey)
        } catch let error as SudoersError {
            logger.error("uninstall: failed — \(error.errorDescription ?? "unknown", privacy: .public)")
            throw error
        } catch {
            logger.error("uninstall: failed — \(error.localizedDescription, privacy: .public)")
            throw SudoersError.uninstallFailed(error.localizedDescription)
        }
    }

    /// Compare the helper path recorded in `/etc/sudoers.d/changeicon` against
    /// the current bundle's helper path.
    ///
    /// When the App bundle moves (e.g. user drags a new version into
    /// `/Applications`) the baked-in path becomes stale.  This method detects
    /// that mismatch so the application can guide the user to re-install.
    ///
    /// - Returns: `true` when the rule file exists and its helper path matches
    ///   the current bundle.
    func validateRuleContent() -> Bool {
        guard let currentHelper = resolveHelperPath() else {
            logger.warning("validateRuleContent: cannot resolve current helper path")
            return false
        }

        guard let ruleContent = try? String(contentsOfFile: Self.sudoersDropInPath, encoding: .utf8) else {
            logger.info("validateRuleContent: rule file not found at \(Self.sudoersDropInPath, privacy: .public)")
            return false
        }

        // The rule contains the helper path; check that it appears in the file
        let matches = ruleContent.contains(currentHelper)
        if !matches {
            logger.warning("validateRuleContent: path mismatch — rule does not contain \(currentHelper, privacy: .public)")
        } else {
            logger.info("validateRuleContent: path matches")
        }
        return matches
    }

    /// Whether the user has previously declined the sudoers setup prompt.
    var hasUserRejected: Bool {
        defaults.bool(forKey: rejectionKey)
    }

    /// Record that the user declined the sudoers setup prompt.
    func recordRejection() {
        defaults.set(true, forKey: rejectionKey)
        logger.info("recordRejection: user declined sudoers setup")
    }

    // MARK: - Private Helpers

    /// Execute a shell script via `osascript with administrator privileges`.
    ///
    /// This is the **only** path that presents an authentication dialog.
    /// It is used once during initial setup (`install()`) and once during
    /// teardown (`uninstall()`).
    private func runAdminShellScript(_ script: String, prompt: String) async throws -> String {
        // Escape the script for safe embedding in an AppleScript string literal.
        // We use a heredoc-style approach: write script to temp file, run it.
        let tmpDir = FileManager.default.temporaryDirectory
        let scriptURL = tmpDir.appendingPathComponent("changeicon_sudoers_\(UUID().uuidString).sh")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: scriptURL) }

        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scriptURL.path)

        let promptEscaped = prompt.replacingOccurrences(of: "\"", with: "\\\"")
        // Use /bin/bash explicitly — the minimal shell environment under
        // `osascript with administrator privileges` may not have bash in PATH.
        let osaScript = "do shell script \"/bin/bash '\(scriptURL.path)' 2>&1\" with administrator privileges with prompt \"\(promptEscaped)\""

        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            p.arguments = ["-e", osaScript]

            let outPipe = Pipe()
            let errPipe = Pipe()
            p.standardOutput = outPipe
            p.standardError = errPipe

            p.terminationHandler = { proc in
                let outStr = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let errStr = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

                if proc.terminationStatus == 0 {
                    cont.resume(returning: outStr)
                } else {
                    let combined = errStr.isEmpty ? outStr : errStr
                    if combined.contains("authorization") || combined.contains("cancel") || combined.contains("用户取消") {
                        cont.resume(throwing: SudoersError.adminCancelled)
                    } else {
                        cont.resume(throwing: SudoersError.scriptError(combined.isEmpty ? "未知错误" : combined))
                    }
                }
            }

            do {
                try p.run()
            } catch {
                cont.resume(throwing: SudoersError.scriptError("无法启动 osascript: \(error.localizedDescription)"))
            }
        }
    }

    /// Resolve the absolute path to the `seticon` helper binary embedded in
    /// the current app bundle.
    private func resolveHelperPath() -> String? {
        for candidate in [
            Bundle.main.path(forResource: "seticon", ofType: nil),
            Bundle.main.bundlePath + "/Contents/Resources/seticon",
            Bundle.main.bundlePath + "/Contents/MacOS/seticon",
        ] {
            if let p = candidate, FileManager.default.fileExists(atPath: p) {
                return p
            }
        }
        return nil
    }

    // MARK: - Static helpers (non-isolated for script generation)

    /// Build the content of `/etc/sudoers.d/changeicon`.
    nonisolated private static func makeRuleContent(username: String, helperPath: String) -> String {
        return """
        # Managed by ChangeIcon — do not edit manually
        \(username) ALL=(root) NOPASSWD: \(helperPath) set *
        \(username) ALL=(root) NOPASSWD: \(helperPath) remove *
        """
    }

    /// Build the install shell script executed with administrator privileges.
    ///
    /// Uses absolute paths for all commands because the shell environment
    /// provided by `osascript with administrator privileges` is minimal
    /// and may not include `/usr/sbin` (where `visudo` lives) in PATH.
    nonisolated private static func makeInstallScript(ruleContent: String) -> String {
        return """
        export PATH=/usr/bin:/bin:/usr/sbin:/sbin

        set -euo pipefail

        SUDOERS_FILE='\(sudoersDropInPath)'
        SUDOERS_MAIN='\(sudoersMainPath)'

        # 1. Ensure #includedir directive exists in /etc/sudoers
        if ! /usr/bin/grep -qE '^[#@]includedir[[:space:]]+/etc/sudoers\\.d' "$SUDOERS_MAIN" 2>/dev/null; then
            /bin/echo "#includedir /etc/sudoers.d" >> "$SUDOERS_MAIN"
            /bin/echo "ADDED_INCLUDEDIR"
        else
            /bin/echo "INCLUDEDIR_EXISTS"
        fi

        # 2. Write the rule file
        /bin/cat > "$SUDOERS_FILE" << 'RULE_EOF'
        \(ruleContent)
        RULE_EOF
        /bin/chmod 0440 "$SUDOERS_FILE"
        /bin/echo "RULE_WRITTEN"

        # 3. Validate syntax for both files
        VISUDO_OUTPUT=$(/usr/sbin/visudo -c -f "$SUDOERS_FILE" 2>&1) || {
            /bin/echo "VISUDO_FAILED: $VISUDO_OUTPUT"
            # Rollback: remove the rule file we just wrote
            /bin/rm -f "$SUDOERS_FILE"
            /bin/echo "ROLLED_BACK"
            exit 1
        }
        /bin/echo "VISUDO_DROPIN_OK"

        VISUDO_MAIN_OUTPUT=$(/usr/sbin/visudo -c -f "$SUDOERS_MAIN" 2>&1) || {
            /bin/echo "VISUDO_MAIN_FAILED: $VISUDO_MAIN_OUTPUT"
            # Rollback: remove the rule file (includedir is left; harmless on its own)
            /bin/rm -f "$SUDOERS_FILE"
            /bin/echo "ROLLED_BACK"
            exit 1
        }
        /bin/echo "VISUDO_MAIN_OK"
        /bin/echo "INSTALL_SUCCESS"
        """
    }
}
