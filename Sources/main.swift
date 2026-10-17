// ft-forwarder: receives "open file" events from Finder and LaunchServices,
// forwards them to Rex as a new session running Neovim, then exits.
//
// The app never shows a Dock icon (LSUIElement) and quits as soon as the
// files have been handed off.

import AppKit

let rexBundleID = "com.superlogical.rex"
let home = FileManager.default.homeDirectoryForCurrentUser

func log(_ message: String) {
  let url = home.appendingPathComponent("Library/Logs/ft-forwarder.log")
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

/// Optional overrides, read from ~/.config/ft-forwarder/config.json.
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

  static func load() -> Config {
    let url = home.appendingPathComponent(".config/ft-forwarder/config.json")
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

@discardableResult
func run(_ executable: URL, _ arguments: [String]) throws -> ProcessResult {
  let process = Process()
  process.executableURL = executable
  process.arguments = arguments
  let stdout = Pipe(), stderr = Pipe()
  process.standardOutput = stdout
  process.standardError = stderr
  try process.run()
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

// MARK: - Forwarding

struct Forwarder {
  let config: Config
  let rex: URL

  init(config: Config) throws {
    self.config = config
    guard let rex = Forwarder.findRex(config) else {
      throw ForwardError("Couldn't find the rex command. Set \"rex\" in ~/.config/ft-forwarder/config.json.")
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
    var groups: [(cwd: URL, files: [URL])] = []
    for url in urls {
      let cwd = workingDirectory(for: url)
      if let index = groups.firstIndex(where: { $0.cwd == cwd }) {
        groups[index].files.append(url)
      } else {
        groups.append((cwd, [url]))
      }
    }

    var lastSession: String?
    for group in groups {
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
      let label = group.files.count == 1 ? group.files[0].lastPathComponent : group.cwd.lastPathComponent
      let keepShell = config.keepShell ?? true
      var arguments = ["new", label, "-c", group.cwd.path, "--json"]
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
      lastSession = session
    }

    if let lastSession { show(session: lastSession) }
  }

  private func workingDirectory(for url: URL) -> URL {
    let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
    let start = isDirectory ? url : url.deletingLastPathComponent()
    guard config.cwd != "parent" else { return start }

    // The nearest folder containing .git, which is a folder in a normal clone and a
    // file in a worktree or submodule.
    var dir = start.standardizedFileURL
    // Stop below the home folder, so a dotfiles repo at ~ doesn't swallow everything.
    while dir.path != "/" && dir.path != home.standardizedFileURL.path {
      if FileManager.default.fileExists(atPath: dir.appendingPathComponent(".git").path) {
        return dir
      }
      dir = dir.deletingLastPathComponent()
    }
    return start
  }

  /// Switch this Mac's Rex app to the session, launching Rex if needed.
  private func show(session: String) {
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
      let result = try run(rex, ["-C", client, "do", "session.select", "session_id=\(session)"])
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
