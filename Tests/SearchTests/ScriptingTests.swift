import AppKit
import Foundation
import Testing
@testable import Search

// AppleScript (Fork/Scripting.swift, Fork/Copper.sdef): every class and key the
// dictionary names exists on the Swift side, so a typo in either is a failed
// test rather than a script that says "can't get" on someone's Mac. And what a
// page returns reaches AppleScript as something it can hold.

@Suite("AppleScript")
struct ScriptingTests {
    static let sdef = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/Search/Fork/Copper.sdef")

    /// (class, its cocoa keys and handler methods) as the dictionary has them.
    static func dictionary() throws -> [(cocoa: String, keys: [String], methods: [String])] {
        let xml = try XMLDocument(contentsOf: sdef, options: [])
        return try xml.nodes(forXPath: "//class").compactMap { node in
            guard let element = node as? XMLElement,
                  let cocoa = try element.nodes(forXPath: "cocoa/@class").first?.stringValue else { return nil }
            let keys = try element.nodes(forXPath: "property/cocoa/@key | element/cocoa/@key").compactMap(\.stringValue)
            let methods = try element.nodes(forXPath: "responds-to/cocoa/@method").compactMap(\.stringValue)
            return (cocoa, keys, methods)
        }
    }

    @Test("The dictionary's classes, keys and handlers are all there")
    func dictionaryMatchesTheCode() throws {
        let classes = try Self.dictionary()
        #expect(classes.map(\.cocoa) == ["NSApplication", "CopperScriptWindow", "CopperScriptTab"])
        for entry in classes {
            let type: AnyClass = try #require(NSClassFromString(entry.cocoa), "no class \(entry.cocoa)")
            let app = ObjectIdentifier(type) == ObjectIdentifier(NSApplication.self)
            for key in entry.keys where !app || key == "scriptWindows" {
                #expect(class_respondsToSelector(type, NSSelectorFromString(key)), "\(entry.cocoa) has no \(key)")
            }
            for method in entry.methods {
                #expect(class_respondsToSelector(type, NSSelectorFromString(method)), "\(entry.cocoa) has no \(method)")
            }
        }
        // Settable in the dictionary, settable here; make new tab / window go in here.
        #expect(ScriptWindow.instancesRespond(to: NSSelectorFromString("setActiveTabIndex:")))
        #expect(ScriptWindow.instancesRespond(to: NSSelectorFromString("setURL:")))
        #expect(ScriptTab.instancesRespond(to: NSSelectorFromString("setURL:")))
        #expect(ScriptWindow.instancesRespond(to: NSSelectorFromString("insertObject:inTabsAtIndex:")))
        #expect(NSApplication.instancesRespond(to: NSSelectorFromString("insertObject:inScriptWindowsAtIndex:")))
    }

    @Test("Page answers become AppleScript values")
    func pageValues() {
        #expect(Scripting.descriptor("Example Domain").stringValue == "Example Domain")
        #expect(Scripting.descriptor(NSNumber(value: 42.0)).descriptorType == typeSInt32)
        #expect(Scripting.descriptor(NSNumber(value: 42.0)).int32Value == 42)
        #expect(Scripting.descriptor(NSNumber(value: 1.5)).doubleValue == 1.5)
        #expect(Scripting.descriptor(NSNumber(value: true)).descriptorType == typeTrue || Scripting.descriptor(NSNumber(value: true)).booleanValue)
        #expect(Scripting.descriptor(nil).descriptorType == typeNull)
        #expect(Scripting.descriptor(NSNull()).descriptorType == typeNull)
        let list = Scripting.descriptor(["a", NSNumber(value: 1)] as [Any])
        #expect(list.numberOfItems == 2 && list.atIndex(1)?.stringValue == "a" && list.atIndex(2)?.int32Value == 1)
        #expect(Scripting.descriptor(["a": 1] as [String: Any]).stringValue == #"{"a":1}"#)
        #expect(Scripting.descriptor([["nested"]] as [Any]).stringValue == #"[["nested"]]"#)
    }

    @Test("Task Manager sizes")
    func sizes() {
        #expect(TaskManager.size(512 * 1_048_576) == "512 MB")
        #expect(TaskManager.size(3 * 1_073_741_824 / 2) == "1.5 GB")
    }
}
