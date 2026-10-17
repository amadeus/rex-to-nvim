// rex-to-nvim: receives "open file" events from Finder and LaunchServices,
// forwards them to Rex as a new session running Neovim, then exits.
//
// The app never shows a Dock icon (LSUIElement) and quits as soon as the
// files have been handed off.

import AppKit

let rexBundleID = "com.superlogical.rex"
let home = FileManager.default.homeDirectoryForCurrentUser

func log(_ message: String) {
  let url = home.appendingPathComponent("Library/Logs/rex-to-nvim.log")
  let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
  if let handle = try? FileHandle(forWritingTo: url) {
    handle.seekToEndOfFile()
    handle.write(line.data(using: .utf8)!)
    try? handle.close()
  } else {
    try? line.write(to: url, atomically: true, encoding: .utf8)
  }
}

struct ForwardError: Error, CustomStringConvertible {
  let description: String
  init(_ description: String) { self.description = description }
}

// MARK: - Config

/// Optional overrides, read from ~/.config/rex-to-nvim/config.json.
struct Config: Decodable {
  /// Path to the rex binary. Defaults to PATH, then the newest Rex server install.
  var rex: String?
  /// Rex app to switch to the new session: "auto" (this Mac), "none", or a client label or ID.
  var client: String?
  /// Command to run in the session. "{files}" expands to every opened path, "{file}" to the first.
  var command: [String]?
  /// Run the command from a shell, so quitting it leaves a shell instead of ending
  /// the session. Default true.
  var keepShell: Bool?
  /// Working directory: "gitRoot" (the file's git repository, else its folder) or "parent".
  var cwd: String?
  /// Open files from a git repository in a Neovim already running in that repository,
  /// instead of starting a new session. Default true.
  var reuseNvim: Bool?
  /// Ex command a reused Neovim opens each file with. Default "tab drop".
  var openCommand: String?

  static func load() -> Config {
    let url = home.appendingPathComponent(".config/rex-to-nvim/config.json")
    guard let data = try? Data(contentsOf: url) else { return Config() }
    do {
      return try JSONDecoder().decode(Config.self, from: data)
    } catch {
      log("ignoring invalid config \(url.path): \(error)")
      return Config()
    }
  }
}

// MARK: - Processes

struct ProcessResult {
  let status: Int32
  let stdout: Data
  let stderr: String
}

/// Run a command to completion. With a timeout, a command still running after it
/// is terminated (and reports a nonzero status).
@discardableResult
func run(_ executable: URL, _ arguments: [String], timeout: TimeInterval? = nil) throws -> ProcessResult {
  let process = Process()
  process.executableURL = executable
  process.arguments = arguments
  let stdout = Pipe(), stderr = Pipe()
  process.standardOutput = stdout
  process.standardError = stderr
  try process.run()
  if let timeout {
    DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
      if process.isRunning { process.terminate() }
    }
  }
  // Drain stderr concurrently so a chatty command can't fill the pipe and stall.
  var errData = Data()
  let errDone = DispatchSemaphore(value: 0)
  DispatchQueue.global().async {
    errData = stderr.fileHandleForReading.readDataToEndOfFile()
    errDone.signal()
  }
  let outData = stdout.fileHandleForReading.readDataToEndOfFile()
  errDone.wait()
  process.waitUntilExit()
  return ProcessResult(status: process.terminationStatus, stdout: outData,
                       stderr: String(decoding: errData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
}

let loginShell = URL(fileURLWithPath: String(cString: getpwuid(getuid()).pointee.pw_shell)).lastPathComponent

/// Quote a word so the login shell reads it back unchanged.
func shellQuote(_ word: String) -> String {
  let plain = !word.isEmpty && word.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "-_./+:,@".contains($0)) }
  if plain { return word }
  if loginShell == "fish" {
    return "'" + word.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'") + "'"
  }
  return "'" + word.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

func parentPID(of pid: pid_t) -> pid_t? {
  var info = kinfo_proc()
  var size = MemoryLayout<kinfo_proc>.stride
  var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
  guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
  return info.kp_eproc.e_ppid
}

// MARK: - Git

/// The nearest folder containing .git, which is a folder in a normal clone and a
/// file in a worktree or submodule.
func gitRoot(of start: URL) -> URL? {
  var dir = start.resolvingSymlinksInPath()
  // Stop below the home folder, so a dotfiles repo at ~ doesn't swallow everything.
  let homePath = home.resolvingSymlinksInPath().path
  while dir.path != "/" && dir.path != homePath {
    if FileManager.default.fileExists(atPath: dir.appendingPathComponent(".git").path) {
      return dir
    }
    dir = dir.deletingLastPathComponent()
  }
  return nil
}

// MARK: - Neovim

/// A Neovim running in the foreground of a Rex pane.
struct NvimInstance {
  let session: String
  let window: String
  let block: String
  let binary: URL
  let server: String
  let cwd: URL
}

/// Neovim's UI process runs the editor in a child process, which listens on
/// $TMPDIR/nvim.$USER/<random>/nvim.<pid>.0. Older versions listen in the UI process itself.
func nvimServer(forUI uiPID: pid_t) -> String? {
  let fm = FileManager.default
  let base = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("nvim.\(NSUserName())")
  for dir in (try? fm.contentsOfDirectory(atPath: base.path)) ?? [] {
    let dirURL = base.appendingPathComponent(dir)
    for file in (try? fm.contentsOfDirectory(atPath: dirURL.path)) ?? [] {
      guard file.hasPrefix("nvim."), file.hasSuffix(".0"), let pid = pid_t(file.dropFirst(5).dropLast(2)) else { continue }
      if pid == uiPID || parentPID(of: pid) == uiPID {
        return dirURL.appendingPathComponent(file).path
      }
    }
  }
  return nil
}

/// Quote a string as a Vim single-quoted string literal.
func vimQuote(_ string: String) -> String {
  "'" + string.replacingOccurrences(of: "'", with: "''") + "'"
}

// MARK: - Forwarding

struct Forwarder {
  let config: Config
  let rex: URL

  init(config: Config) throws {
    self.config = config
    guard let rex = Forwarder.findRex(config) else {
      throw ForwardError("Couldn't find the rex command. Set \"rex\" in ~/.config/rex-to-nvim/config.json.")
    }
    self.rex = rex
  }

  static func findRex(_ config: Config) -> URL? {
    let fm = FileManager.default
    if let path = config.rex {
      return URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    }
    for dir in (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":") {
      let candidate = URL(fileURLWithPath: String(dir)).appendingPathComponent("rex")
      if fm.isExecutableFile(atPath: candidate.path) { return candidate }
    }
    // GUI apps don't inherit the shell's PATH, so fall back to the newest server install.
    let versions = home.appendingPathComponent("Library/Application Support/com.superlogical.rex/RexServer/Versions")
    let installed = (try? fm.contentsOfDirectory(atPath: versions.path)) ?? []
    for version in installed.compactMap(Int.init).sorted(by: >) {
      let candidate = versions.appendingPathComponent("\(version)/Rex Server.app/Contents/MacOS/rex")
      if fm.isExecutableFile(atPath: candidate.path) { return candidate }
    }
    return nil
  }

  func forward(_ urls: [URL]) throws {
    // One session per working directory, with every file from it open in tabs.
    var groups: [(cwd: URL, repo: URL?, files: [URL])] = []
    for url in urls {
      let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
      let folder = isDirectory ? url : url.deletingLastPathComponent()
      let repo = gitRoot(of: folder)
      let cwd = config.cwd == "parent" ? folder : repo ?? folder
      if let index = groups.firstIndex(where: { $0.cwd == cwd }) {
        groups[index].files.append(url)
      } else {
        groups.append((cwd, repo, [url]))
      }
    }

    var lastShown: (session: String, window: String?, block: String?)?
    for group in groups {
      if config.reuseNvim ?? true, let repo = group.repo {
        if let nvim = runningNvims(in: repo).first(where: { open(group.files, in: $0) }) {
          log("opened \(group.files.map(\.path)) in running nvim in \(nvim.block) (cwd \(nvim.cwd.path))")
          lastShown = (nvim.session, nvim.window, nvim.block)
          continue
        }
      }

      // Paths inside the working directory are passed relative to it, which reads
      // better in shell history.
      let root = group.cwd.resolvingSymlinksInPath().path + "/"
      let paths = group.files.map { file in
        let path = file.resolvingSymlinksInPath().path
        return path.hasPrefix(root) ? String(path.dropFirst(root.count)) : file.path
      }
      let template = config.command ?? ["nvim", "-p", "{files}"]
      let command = template.flatMap { part in
        part == "{files}" ? paths : [part.replacingOccurrences(of: "{file}", with: paths[0])]
      }
      let keepShell = config.keepShell ?? true
      var arguments = ["new", "-c", group.cwd.path, "--json"]
      if !keepShell { arguments += ["--"] + command }
      let result = try run(rex, arguments)
      guard result.status == 0 else {
        throw ForwardError("rex new failed (\(result.status)): \(result.stderr)")
      }
      guard let json = try? JSONSerialization.jsonObject(with: result.stdout) as? [String: Any],
            let session = json["session_id"] as? String else {
        throw ForwardError("Couldn't read the session ID from rex new.")
      }
      if keepShell {
        // Type the command into the session's shell, which buffers it until its prompt is ready.
        guard let windows = json["initial_windows"] as? [[String: Any]],
              let block = (windows.first?["block_ids"] as? [String])?.first else {
          throw ForwardError("Couldn't read the terminal ID from rex new.")
        }
        let line = command.map(shellQuote).joined(separator: " ")
        for input in [["send", "-s", session, "-b", block, line], ["send-key", "-s", session, "-b", block, "enter"]] {
          let sent = try run(rex, input)
          guard sent.status == 0 else { throw ForwardError("rex \(input[0]) failed (\(sent.status)): \(sent.stderr)") }
        }
      }
      log("opened \(group.files.map(\.path)) in \(session) (cwd \(group.cwd.path))")
      lastShown = (session, nil, nil)
    }

    if let lastShown { show(session: lastShown.session, window: lastShown.window, block: lastShown.block) }
  }

  /// Run rex and parse its JSON output.
  private func rexJSON(_ arguments: [String]) -> [String: Any]? {
    guard let result = try? run(rex, arguments, timeout: 5), result.status == 0 else { return nil }
    return try? JSONSerialization.jsonObject(with: result.stdout) as? [String: Any]
  }

  /// Neovims in the foreground of any Rex pane whose working directory is inside
  /// `repo`, those at its root first.
  private func runningNvims(in repo: URL) -> [NvimInstance] {
    let sessions = (rexJSON(["ls", "--json"])?["sessions"] as? [[String: Any]] ?? []).compactMap { $0["session_id"] as? String }
    var panes: [(session: String, window: String, block: String)] = []
    for session in sessions {
      for block in rexJSON(["block", "ls", "-s", session, "--json"])?["blocks"] as? [[String: Any]] ?? [] {
        if let id = block["block_id"] as? String, let window = block["window_id"] as? String {
          panes.append((session, window, id))
        }
      }
    }

    var found: [NvimInstance] = []
    let lock = NSLock()
    DispatchQueue.concurrentPerform(iterations: panes.count) { index in
      let pane = panes[index]
      guard let process = rexJSON(["block", "call", "-s", pane.session, "-b", pane.block, "process"]),
            let foreground = process["foreground"] as? [String: Any],
            foreground["name"] as? String == "nvim",
            let pid = foreground["pid"] as? Int, let path = foreground["path"] as? String,
            let cwdPath = foreground["cwd"] as? String,
            gitRoot(of: URL(fileURLWithPath: cwdPath)) == repo,
            let server = nvimServer(forUI: pid_t(pid)) else { return }
      let nvim = NvimInstance(session: pane.session, window: pane.window, block: pane.block,
                              binary: URL(fileURLWithPath: path), server: server,
                              cwd: URL(fileURLWithPath: cwdPath).resolvingSymlinksInPath())
      lock.lock(); found.append(nvim); lock.unlock()
    }
    return found.filter { $0.cwd == repo } + found.filter { $0.cwd != repo }
  }

  /// Ask a running Neovim to open the files, giving up if it doesn't answer promptly
  /// (for example, while it's waiting at a prompt).
  private func open(_ files: [URL], in nvim: NvimInstance) -> Bool {
    let command = config.openCommand ?? "tab drop"
    let expression = files
      .map { "execute(\(vimQuote(command)) .. ' ' .. fnameescape(\(vimQuote($0.path))))" }
      .joined(separator: " .. ")
    guard let result = try? run(nvim.binary, ["--server", nvim.server, "--remote-expr", expression], timeout: 3),
          result.status == 0 else {
      log("running nvim in \(nvim.block) didn't open the files; starting a new session")
      return false
    }
    return true
  }

  /// Switch this Mac's Rex app to the session (and pane), launching Rex if needed.
  private func show(session: String, window: String? = nil, block: String? = nil) {
    if let block {
      _ = try? run(rex, ["focus", "-s", session, block])
    }
    let choice = config.client ?? "auto"
    guard choice != "none" else { return }

    var client = choice == "auto" ? localAppClient() : choice
    if client == nil {
      openRex()
      for _ in 0..<50 where client == nil {
        Thread.sleep(forTimeInterval: 0.1)
        client = localAppClient()
      }
    }
    guard let client else {
      log("no Rex app connected; left \(session) in the background")
      return
    }
    do {
      var arguments = ["-C", client, "do", "session.select", "session_id=\(session)"]
      if let window { arguments.append("window_id=\(window)") }
      let result = try run(rex, arguments)
      if result.status != 0 { log("session.select failed: \(result.stderr)") }
    } catch {
      log("session.select failed: \(error)")
    }
    openRex()
  }

  /// The Rex app connected over the local socket, preferring the running Rex.app's process.
  private func localAppClient() -> String? {
    guard let result = try? run(rex, ["client", "ls", "--json"]), result.status == 0,
          let json = try? JSONSerialization.jsonObject(with: result.stdout) as? [String: Any],
          let clients = json["clients"] as? [[String: Any]] else { return nil }

    let apps = clients.filter { client in
      let info = client["info"] as? [String: Any]
      let principal = client["principal"] as? [String: Any]
      return info?["kind"] as? String == "app"
        && principal?["transport"] as? String == "unix"
        && client["connection_state"] as? String == "connected"
    }
    let rexPIDs = Set(NSRunningApplication.runningApplications(withBundleIdentifier: rexBundleID).map(\.processIdentifier))
    let preferred = apps.first { client in
      guard let pid = (client["principal"] as? [String: Any])?["pid"] as? Int else { return false }
      return rexPIDs.contains(pid_t(pid))
    }
    return (preferred ?? apps.first)?["client_id"] as? String
  }

  /// Launch or bring Rex.app to the front, waiting until LaunchServices has done so.
  private func openRex() {
    guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: rexBundleID) else { return }
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.activates = true
    let done = DispatchSemaphore(value: 0)
    NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { _, error in
      if let error { log("couldn't open Rex: \(error)") }
      done.signal()
    }
    _ = done.wait(timeout: .now() + 5)
  }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
  private var pending = 0
  private var receivedFiles = false

  func application(_ application: NSApplication, open urls: [URL]) {
    receivedFiles = true
    pending += 1
    DispatchQueue.global(qos: .userInitiated).async {
      var failure: Error?
      do {
        try Forwarder(config: .load()).forward(urls)
      } catch {
        log("error: \(error)")
        failure = error
      }
      DispatchQueue.main.async {
        if let failure { self.showError(failure, urls: urls) }
        self.pending -= 1
        if self.pending == 0 { NSApp.terminate(nil) }
      }
    }
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    // Launched without any files (e.g. double-clicked in Finder): nothing to do.
    DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
      if !self.receivedFiles { NSApp.terminate(nil) }
    }
  }

  private func showError(_ error: Error, urls: [URL]) {
    if #available(macOS 14, *) {
      NSApp.activate()
    } else {
      NSApp.activate(ignoringOtherApps: true)
    }
    let alert = NSAlert()
    alert.messageText = "Couldn't open \(urls.map(\.lastPathComponent).joined(separator: ", ")) in Rex"
    alert.informativeText = String(describing: error)
    alert.runModal()
  }
}

let delegate = AppDelegate()
NSApplication.shared.delegate = delegate
NSApplication.shared.run()
