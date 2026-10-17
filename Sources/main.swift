// rex-to-nvim: receives "open file" events from Finder and LaunchServices,
// forwards them to Rex as a new session running Neovim, then exits.
//
// The app never shows a Dock icon (LSUIElement) or a dialog, and quits as
// soon as the files have been handed off. Failures go to the log.

import AppKit

let rexBundleID = "com.superlogical.rex"
let home = FileManager.default.homeDirectoryForCurrentUser

/// Append to ~/Library/Logs/rex-to-nvim.log. Past 1 MB it's moved to
/// rex-to-nvim.1.log (replacing the previous one), so it never grows unbounded.
func log(_ message: String) {
  let fm = FileManager.default
  let url = home.appendingPathComponent("Library/Logs/rex-to-nvim.log")
  if let size = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? Int, size > 1_000_000 {
    let previous = url.deletingLastPathComponent().appendingPathComponent("rex-to-nvim.1.log")
    try? fm.removeItem(at: previous)
    try? fm.moveItem(at: url, to: previous)
  }
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
  let block: String
  let binary: URL
  let server: String
  let cwd: URL
}

/// A Neovim editor process with an RPC socket. Neovim 0.10+ runs the editor in a
/// child of the UI process that Rex sees in the foreground.
struct NvimProcess {
  let pid: pid_t
  let binary: String
  let socket: String
  let environment: [String: String]
}

/// Every running Neovim that has an RPC socket.
func nvimProcesses() -> [NvimProcess] {
  allProcessIDs().compactMap { pid in
    guard let binary = processPath(pid), (binary as NSString).lastPathComponent == "nvim",
          let (arguments, environment) = processArgumentsAndEnvironment(pid),
          let socket = nvimSocket(pid: pid, arguments: arguments, environment: environment) else { return nil }
    return NvimProcess(pid: pid, binary: binary, socket: socket, environment: environment)
  }
}

/// Neovim listens on `--listen <path>` if given, otherwise on nvim.<pid>.0 in its
/// run directory: $XDG_RUNTIME_DIR if set, else $TMPDIR/nvim.$USER/<random>/.
/// The UI process has no socket of its own.
func nvimSocket(pid: pid_t, arguments: [String], environment: [String: String]) -> String? {
  let fm = FileManager.default
  if let index = arguments.firstIndex(of: "--listen"), index + 1 < arguments.count {
    let address = arguments[index + 1]
    return address.hasPrefix("/") && fm.fileExists(atPath: address) ? address : nil
  }
  let name = "nvim.\(pid).0"
  var bases: [String] = []
  for base in [environment["XDG_RUNTIME_DIR"], environment["TMPDIR"], NSTemporaryDirectory()].compactMap({ $0 })
  where !bases.contains(base) {
    bases.append(base)
  }
  for base in bases.map(URL.init(fileURLWithPath:)) {
    let direct = base.appendingPathComponent(name)
    if fm.fileExists(atPath: direct.path) { return direct.path }
    let userDir = base.appendingPathComponent("nvim.\(NSUserName())")
    for random in (try? fm.contentsOfDirectory(atPath: userDir.path)) ?? [] {
      let candidate = userDir.appendingPathComponent(random).appendingPathComponent(name)
      if fm.fileExists(atPath: candidate.path) { return candidate.path }
    }
  }
  return nil
}

func allProcessIDs() -> [pid_t] {
  let count = proc_listallpids(nil, 0)
  guard count > 0 else { return [] }
  // Leave room for processes started since counting.
  var pids = [pid_t](repeating: 0, count: Int(count) + 64)
  let found = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
  return Array(pids.prefix(Int(max(found, 0))))
}

/// A process's current working directory, or nil if it isn't running.
func processCwd(_ pid: pid_t) -> URL? {
  var info = proc_vnodepathinfo()
  let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
  guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
  let path = withUnsafeBytes(of: info.pvi_cdir.vip_path) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
  return path.isEmpty ? nil : URL(fileURLWithPath: path)
}

func processPath(_ pid: pid_t) -> String? {
  var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
  guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
  return String(cString: buffer)
}

/// A process's arguments (without argv[0]) and environment, from KERN_PROCARGS2:
/// argc, the executable path and its NUL padding, then argv and environ as
/// NUL-terminated strings. Only the user's own processes are readable.
func processArgumentsAndEnvironment(_ pid: pid_t) -> (arguments: [String], environment: [String: String])? {
  var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
  var size = 0
  guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
  var buffer = [UInt8](repeating: 0, count: size)
  guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }
  let argc = Int(buffer.withUnsafeBytes { $0.load(as: Int32.self) })

  var index = MemoryLayout<Int32>.size
  func nextString() -> String? {
    guard index < size else { return nil }
    let start = index
    while index < size && buffer[index] != 0 { index += 1 }
    defer { index += 1 }
    return String(decoding: buffer[start..<index], as: UTF8.self)
  }
  _ = nextString()  // executable path
  while index < size && buffer[index] == 0 { index += 1 }
  var argv: [String] = []
  for _ in 0..<argc {
    guard let argument = nextString() else { break }
    argv.append(argument)
  }
  var environment: [String: String] = [:]
  while let entry = nextString(), !entry.isEmpty {
    guard let equals = entry.firstIndex(of: "=") else { continue }
    environment[String(entry[..<equals])] = String(entry[entry.index(after: equals)...])
  }
  return (Array(argv.dropFirst()), environment)
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

    var lastShown: (session: String, block: String?)?
    for group in groups {
      if config.reuseNvim ?? true, let repo = group.repo {
        if let nvim = runningNvims(in: repo).first(where: { open(group.files, in: $0) }) {
          log("opened \(group.files.map(\.path)) in running nvim in \(nvim.block) (cwd \(nvim.cwd.path))")
          lastShown = (nvim.session, nvim.block)
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
        // A trailing carriage return presses Enter.
        let line = command.map(shellQuote).joined(separator: " ") + "\r"
        let sent = try run(rex, ["send", "-s", session, "-b", block, line])
        guard sent.status == 0 else { throw ForwardError("rex send failed (\(sent.status)): \(sent.stderr)") }
      }
      log("opened \(group.files.map(\.path)) in \(session) (cwd \(group.cwd.path))")
      lastShown = (session, nil)
    }

    if let lastShown { show(session: lastShown.session, block: lastShown.block) }
  }

  /// Run rex and parse its JSON output.
  private func rexJSON(_ arguments: [String]) -> [String: Any]? {
    guard let result = try? run(rex, arguments, timeout: 5), result.status == 0 else { return nil }
    return try? JSONSerialization.jsonObject(with: result.stdout) as? [String: Any]
  }

  /// Neovims in the foreground of a Rex pane whose working directory is inside
  /// `repo`, those at its root first.
  ///
  /// Found from the processes themselves rather than by asking Rex about every
  /// pane: the process's cwd says where it's working, and the REX_SESSION and
  /// REX_BLOCK it inherited from its shell say which pane it's in. Rex is only
  /// asked to confirm a match.
  private func runningNvims(in repo: URL) -> [NvimInstance] {
    var found: [NvimInstance] = []
    for nvim in nvimProcesses() {
      guard let cwd = processCwd(nvim.pid)?.resolvingSymlinksInPath(), gitRoot(of: cwd) == repo,
            let session = nvim.environment["REX_SESSION"], let block = nvim.environment["REX_BLOCK"] else { continue }
      // It must be what the pane shows, not suspended or nested inside another program.
      guard let foreground = rexJSON(["block", "call", "-s", session, "-b", block, "process"])?["foreground"] as? [String: Any],
            let uiPID = (foreground["pid"] as? Int).map(pid_t.init),
            uiPID == nvim.pid || parentPID(of: nvim.pid) == uiPID else { continue }
      found.append(NvimInstance(session: session, block: block, binary: URL(fileURLWithPath: nvim.binary),
                                server: nvim.socket, cwd: cwd))
    }
    return found.filter { $0.cwd == repo } + found.filter { $0.cwd != repo }
  }

  /// Ask a running Neovim to open the files, giving up if it doesn't answer promptly
  /// (for example, while it's waiting at a prompt). The files are opened on Neovim's
  /// next tick, so this doesn't wait for filetype plugins and language servers.
  private func open(_ files: [URL], in nvim: NvimInstance) -> Bool {
    let command = config.openCommand ?? "tab drop"
    let paths = "[" + files.map { vimQuote($0.path) }.joined(separator: ", ") + "]"
    let lua = "vim.schedule(function() for _, f in ipairs(_A[2]) do vim.cmd(_A[1] .. ' ' .. vim.fn.fnameescape(f)) end end)"
    let expression = "luaeval(\(vimQuote(lua)), [\(vimQuote(command)), \(paths)])"
    guard let result = try? run(nvim.binary, ["--server", nvim.server, "--remote-expr", expression], timeout: 3),
          result.status == 0 else {
      log("running nvim in \(nvim.block) didn't open the files; starting a new session")
      return false
    }
    return true
  }

  /// Switch this Mac's Rex app to the session, launching Rex if needed. Focusing a
  /// pane also selects its tab.
  private func show(session: String, block: String? = nil) {
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
    // Web links can arrive if this app ever becomes the default browser; pass them on.
    let links = urls.filter { !$0.isFileURL }
    if !links.isEmpty { handOff(links) }
    let files = urls.filter(\.isFileURL)
    guard !files.isEmpty else {
      if pending == 0 { NSApp.terminate(nil) }
      return
    }
    pending += 1
    DispatchQueue.global(qos: .userInitiated).async {
      do {
        try Forwarder(config: .load()).forward(files)
      } catch {
        log("error opening \(files.map(\.path)): \(error)")
      }
      DispatchQueue.main.async {
        self.pending -= 1
        if self.pending == 0 { NSApp.terminate(nil) }
      }
    }
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    // Files opened at launch arrive before this. Without any, the app was opened on
    // its own (e.g. double-clicked in Finder): nothing to do.
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
      if !self.receivedFiles { NSApp.terminate(nil) }
    }
  }

  /// Open non-file URLs in another app that handles them, since Rex can't.
  private func handOff(_ links: [URL]) {
    let me = Bundle.main.bundleURL.standardizedFileURL
    for link in links {
      guard let other = NSWorkspace.shared.urlsForApplications(toOpen: link).first(where: { $0.standardizedFileURL != me }) else {
        log("no other app can open \(link)")
        continue
      }
      log("handing \(link) to \(other.lastPathComponent)")
      NSWorkspace.shared.open([link], withApplicationAt: other, configuration: NSWorkspace.OpenConfiguration())
    }
  }
}

let delegate = AppDelegate()
NSApplication.shared.delegate = delegate
NSApplication.shared.run()
