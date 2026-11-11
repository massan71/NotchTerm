import AppKit
import Testing
@testable import NotchTerm

@Suite struct ConfigTests {
    @Test func emptyObjectGivesDefaults() {
        let (config, error) = ConfigStore.decode(Data("{}".utf8))
        #expect(error == nil)
        #expect(config == Config())
    }

    @Test func nestedKeysMergeOverDefaults() {
        let json = #"{"font": {"size": 15}, "commandNotify": {"minDuration": 3}, "theme": "nord"}"#
        let (config, error) = ConfigStore.decode(Data(json.utf8))
        #expect(error == nil)
        #expect(config.font.size == 15)
        #expect(config.font.name == "")            // default conservato
        #expect(config.commandNotify.minDuration == 3)
        #expect(config.commandNotify.liveIndicator) // default conservato
        #expect(config.theme == "nord")
    }

    @Test func invalidJSONReportsError() {
        let (config, error) = ConfigStore.decode(Data("{ nope".utf8))
        #expect(error != nil)
        #expect(config == Config())
    }

    @Test func nonObjectReportsError() {
        let (_, error) = ConfigStore.decode(Data("[1, 2]".utf8))
        #expect(error != nil)
    }

    @Test func everyThemeResolves() {
        for name in Themes.names {
            var c = Config()
            c.theme = name
            let theme = Themes.resolve(c)
            #expect(theme.ansi.count == 16, "tema \(name)")
            #expect(NSColor(hex: theme.background) != nil, "tema \(name)")
        }
    }

    @Test func hexColors() {
        #expect(NSColor(hex: "#ff0000") != nil)
        #expect(NSColor(hex: "ff000080") != nil)
        #expect(NSColor(hex: "#zzz") == nil)
    }
}

@Suite struct HotKeyTests {
    @Test func parsesCommonSpecs() {
        #expect(HotKey.parse("ctrl+`") != nil)
        #expect(HotKey.parse("cmd+shift+t") != nil)
        #expect(HotKey.parse("option+space") != nil)
        #expect(HotKey.parse("f12") != nil)
    }

    @Test func rejectsInvalidSpecs() {
        #expect(HotKey.parse("") == nil)
        #expect(HotKey.parse("ctrl+nonexistent") == nil)
        #expect(HotKey.parse("hyper+a") == nil)
    }

    @Test func modifiersAreCombined() {
        let a = HotKey.parse("ctrl+a")
        let b = HotKey.parse("ctrl+shift+a")
        #expect(a?.0 == b?.0)
        #expect(a?.1 != b?.1)
    }
}

@Suite struct CommandTests {
    @Test func durationFormat() {
        #expect(CommandResult.format(4.4) == "4 s")
        #expect(CommandResult.format(133) == "2 min 13 s")
        #expect(CommandResult.format(3840) == "1 h 4 min")
    }

    @Test func clockFormat() {
        #expect(CommandResult.clock(5) == "0:05")
        #expect(CommandResult.clock(760) == "12:40")
        #expect(CommandResult.clock(3723) == "1:02:03")
        #expect(CommandResult.clock(-3) == "0:00")
    }

    @Test func parsesStatusMessage() {
        #expect(CommandResult.parse(message: "0 12.5", failed: false) == (0, 12.5))
        #expect(CommandResult.parse(message: "2 1,25", failed: true) == (2, 1.25))
        #expect(CommandResult.parse(message: "", failed: true) == (1, 0))
        #expect(CommandResult.parse(message: "", failed: false) == (0, 0))
    }

    @Test func ignoresInteractivePrograms() {
        let list = Config().commandNotify.ignore
        #expect(CommandResult.isIgnored("vim README.md", list: list))
        #expect(CommandResult.isIgnored("/usr/bin/less log.txt", list: list))
        #expect(CommandResult.isIgnored("sudo vim /etc/hosts", list: list))
        #expect(CommandResult.isIgnored("EDITOR=x TERM=y ssh host", list: list))
        #expect(!CommandResult.isIgnored("make test", list: list))
        #expect(!CommandResult.isIgnored("npm run build", list: list))
        #expect(!CommandResult.isIgnored("", list: list))
        #expect(!CommandResult.isIgnored("vim", list: []))
    }
}

@MainActor @Suite struct TabTests {
    @Test func tabTitleFromShellTitle() {
        #expect(TerminalSession.tabTitle(shellTitle: "max@MacBook:~/progetti/app", displayTitle: "") == "app")
        #expect(TerminalSession.tabTitle(shellTitle: "max@MacBook:~", displayTitle: "") == "~")
        #expect(TerminalSession.tabTitle(shellTitle: "htop", displayTitle: "~") == "htop")
        #expect(TerminalSession.tabTitle(shellTitle: "", displayTitle: "~/Documents/x") == "x")
        #expect(TerminalSession.tabTitle(shellTitle: "", displayTitle: "~") == "~")
    }

    @Test func compactsLongSpaces() {
        #expect(TerminalSession.compactSpaces("~        12:00\na  b") == "~  12:00\na  b")
    }

        @Test func savedTabsDropMissingFolders() {
        let tabs = SavedTabs(directories: ["/a", "/gone", "/c", "/gone2", "/e"], selected: 3)
        let v = tabs.validated { !$0.hasPrefix("/gone") }
        #expect(v == SavedTabs(directories: ["/a", "/c", "/e"], selected: 1))
    }

    @Test func savedTabsAllMissing() {
        let tabs = SavedTabs(directories: ["/gone"], selected: 0)
        #expect(tabs.validated { _ in false } == nil)
    }

    @Test func savedTabsRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("tabs.json")
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        TabStore.save(SavedTabs(directories: [home, "/nonexistent-\(UUID())", "/tmp"], selected: 2), to: url)
        #expect(TabStore.load(from: url) == SavedTabs(directories: [home, "/tmp"], selected: 1))
    }

    @Test func shellEscape() {
        #expect(NotchController.shellEscape("/Users/max/My File (1).txt") == #"/Users/max/My\ File\ \(1\).txt"#)
        #expect(NotchController.shellEscape("/tmp/plain") == "/tmp/plain")
        #expect(NotchController.shellEscape("a'b\"c$d") == #"a\'b\"c\$d"#)
    }
}

@Suite struct ShapeTests {
    /// L'animazione interpola solo path con gli stessi elementi.
    @Test func closedAndOpenPathsHaveSameStructure() {
        func elements(_ p: CGPath) -> [CGPathElementType] {
            var types: [CGPathElementType] = []
            p.applyWithBlock { types.append($0.pointee.type) }
            return types
        }
        let closed = NotchShape.path(body: CGRect(x: 100, y: 268, width: 190, height: 32), ear: 6, radius: 11)
        let open = NotchShape.path(body: CGRect(x: 10, y: 0, width: 800, height: 300), ear: 10, radius: 22)
        let tiny = NotchShape.path(body: CGRect(x: 0, y: 0, width: 4, height: 4), ear: 50, radius: 50)
        #expect(elements(closed) == elements(open))
        #expect(elements(closed) == elements(tiny))
    }

    @Test func pathTopEdgeMatchesBody() {
        let body = CGRect(x: 20, y: 0, width: 300, height: 100)
        let box = NotchShape.path(body: body, ear: 10, radius: 20).boundingBoxOfPath
        #expect(box.maxY == body.maxY)
        #expect(box.minX == body.minX - 10)
        #expect(box.maxX == body.maxX + 10)
    }
}
