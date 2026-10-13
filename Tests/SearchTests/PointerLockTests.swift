import Testing
@testable import Search

// Who gets pointer lock (Fork/PointerLock.swift, #52): only a page in the real
// key window of the app in front. A granted lock hides the cursor for the whole
// Mac, so every other case is a refusal, and the order says why.

@Test func pointerLockIsGrantedToThePageInTheKeyWindowOfTheAppInFront() {
    #expect(PointerLock.verdict(headless: false, hasWindow: true, backstage: false, appActive: true, isKey: true) == .granted)
}

@Test func pointerLockIsNeverGrantedHeadless() {
    #expect(PointerLock.verdict(headless: true, hasWindow: true, backstage: false, appActive: true, isKey: true) == .headless)
}

@Test func pointerLockIsNeverGrantedToABackstageTab() {
    // Backstage.Window says it is key; AppKit may even be in front.
    #expect(PointerLock.verdict(headless: false, hasWindow: true, backstage: true, appActive: true, isKey: true) == .backstage)
}

@Test func pointerLockIsRefusedBehindAnotherAppOrWindow() {
    #expect(PointerLock.verdict(headless: false, hasWindow: true, backstage: false, appActive: false, isKey: true) == .inactive)
    #expect(PointerLock.verdict(headless: false, hasWindow: true, backstage: false, appActive: true, isKey: false) == .notKey)
    #expect(PointerLock.verdict(headless: false, hasWindow: false, backstage: false, appActive: true, isKey: false) == .windowless)
}
