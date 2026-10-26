// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
import UIKit
final class FrontendUITests: XCTestCase {
    private var app: XCUIApplication!
    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        app = XCUIApplication(); app.launch()
        app.buttons["playFixture"].tap()
        XCTAssertTrue(app.buttons["gameMenu"].waitForExistence(timeout: 15))
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: app.buttons["gameMenu"])
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 10), .completed)
    }
    private func item(_ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }
    private func prompt(_ title: String) -> XCUIElement {
        XCTAssertTrue(app.staticTexts[title].waitForExistence(timeout: 8))
        return item("gamePrompt")
    }
    private func state(_ part: String) {
        let spy = app.staticTexts["coreSpy"]
        let matched = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", part), object: spy)
        XCTAssertEqual(XCTWaiter.wait(for: [matched], timeout: 8), .completed, spy.label)
    }
    private func picture(_ name: String) {
        // Capture the display rather than the app crop: XCTest's app screenshot
        // can apply the portrait crop after a landscape rotation on Simulator.
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
    private func assertFixtureArtwork(_ cover: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        let decoded = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            guard cover.exists, let image = cover.screenshot().image.cgImage,
                  let center = image.cropping(to: CGRect(x: CGFloat(image.width / 2), y: CGFloat(image.height / 2), width: 1, height: 1)) else { return false }
            var pixel = [UInt8](repeating: 0, count: 4)
            return pixel.withUnsafeMutableBytes { bytes in
                guard let context = CGContext(data: bytes.baseAddress, width: 1, height: 1,
                    bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
                context.draw(center, in: CGRect(x: 0, y: 0, width: 1, height: 1))
                let rgba = bytes.bindMemory(to: UInt8.self)
                return rgba[0] < 80 && rgba[1] > 140 && rgba[2] > 170
            }
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [decoded], timeout: 8), .completed,
                       "The actual decoded fixture bitmap is visible", file: file, line: line)
    }
    func testPortraitLandscapeSideBySideAndInput() throws {
        state("mix=1")
        picture("Portrait controls — layout fixture")
        for orientation in [UIDeviceOrientation.landscapeLeft, .landscapeRight] {
            XCUIDevice.shared.orientation = orientation
            let rotated = XCTNSPredicateExpectation(predicate: NSPredicate { [weak self] _, _ in
                guard let self else { return false }
                return self.app.windows.firstMatch.frame.width > self.app.windows.firstMatch.frame.height
            }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [rotated], timeout: 10), .completed)
            let window = app.windows.firstMatch.frame.insetBy(dx: -0.5, dy: -0.5)
            let top = item("topScreen").frame, bottom = item("bottomScreen").frame
            XCTAssertTrue(window.contains(top))
            XCTAssertTrue(window.contains(bottom))
            XCTAssertGreaterThan(top.width, bottom.width * 2)
            XCTAssertLessThanOrEqual(top.maxX, bottom.minX)
            XCTAssertEqual(top.width / top.height, 400.0 / 240.0, accuracy: 0.02)
            XCTAssertEqual(bottom.width / bottom.height, 320.0 / 240.0, accuracy: 0.02)
            XCTAssertFalse(top.intersects(item("circlePad").frame))
            XCTAssertFalse(bottom.intersects(item("padA").frame))
            let dpad = item("directionPad").frame, circle = item("circlePad").frame
            XCTAssertLessThanOrEqual(dpad.maxY, circle.minY)
            XCTAssertLessThanOrEqual(dpad.maxX, top.minX)
            XCTAssertLessThanOrEqual(item("padB").frame.maxY, bottom.minY)
            for id in ["padA", "padB", "padX", "padY", "padL", "padR", "padStart", "padSelect", "gameMenu"] {
                XCTAssertTrue(item(id).isHittable, id)
                XCTAssertTrue(window.contains(item(id).frame), id)
                XCTAssertGreaterThanOrEqual(item(id).frame.width, 43.9, id)
                XCTAssertGreaterThanOrEqual(item(id).frame.height, 43.9, id)
            }
            app.buttons["padA"].tap(); state("last=700")
            state("loads=1") // rotation never reloads the engine
            picture("Landscape \(orientation.rawValue) — side-by-side displays and outer controls fixture")
        }
    }
    private func swipeBackFromLeftEdge() {
        let window = app.windows.firstMatch
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.002, dy: 0.4))
            .press(forDuration: 0.05, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.65, dy: 0.4)))
    }
    func testPromptButtonsRespondOutsideTheirText() throws {
        app.buttons["gameMenu"].tap()
        app.buttons["saveState"].tap()
        _ = prompt("Save to slot 1?")
        app.buttons["promptCancel"].coordinate(withNormalizedOffset: CGVector(dx: 0.12, dy: 0.5)).tap()
        let dismissedPrompt = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: item("gamePrompt"))
        XCTAssertEqual(XCTWaiter.wait(for: [dismissedPrompt], timeout: 8), .completed)
        app.buttons["saveState"].tap()
        _ = prompt("Save to slot 1?")
        app.buttons["promptConfirm"].coordinate(withNormalizedOffset: CGVector(dx: 0.88, dy: 0.5)).tap()
        XCTAssertTrue(app.staticTexts["Slot 1 saved."].waitForExistence(timeout: 8))
        app.buttons["loadState"].tap()
        _ = prompt("Load slot 1?")
        app.buttons["promptConfirm"].coordinate(withNormalizedOffset: CGVector(dx: 0.12, dy: 0.5)).tap()
        XCTAssertTrue(app.staticTexts["Slot 1 loaded. Tap Resume to continue."].waitForExistence(timeout: 8))
        for _ in 0..<5 where !app.buttons["stopGame"].isHittable { app.swipeUp() }
        app.buttons["stopGame"].tap()
        _ = prompt("Stop game?")
        app.buttons["promptCancel"].coordinate(withNormalizedOffset: CGVector(dx: 0.88, dy: 0.5)).tap()
        let dismissedStop = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: item("gamePrompt"))
        XCTAssertEqual(XCTWaiter.wait(for: [dismissedStop], timeout: 8), .completed)
        state("loads=1")
    }
    func testSearchAndSettingsSupportLeftEdgeBack() throws {
        app.terminate(); app.launchArguments = ["--test-library"]; app.launch()
        app.buttons["consoleSearch"].tap()
        XCTAssertTrue(app.textFields["gameSearch"].waitForExistence(timeout: 8))
        swipeBackFromLeftEdge()
        let searchGone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: app.textFields["gameSearch"])
        XCTAssertEqual(XCTWaiter.wait(for: [searchGone], timeout: 8), .completed)
        let keyboardGone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: app.keyboards.element)
        XCTAssertEqual(XCTWaiter.wait(for: [keyboardGone], timeout: 8), .completed)
        app.tabBars.buttons["Settings"].tap()
        let graphics = app.buttons["settingsGraphics"]
        for _ in 0..<8 where !graphics.isHittable { app.swipeUp() }
        graphics.tap()
        XCTAssertTrue(app.staticTexts["CPU"].waitForExistence(timeout: 8))
        swipeBackFromLeftEdge()
        XCTAssertTrue(graphics.waitForExistence(timeout: 8))
        let returned = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: graphics)
        XCTAssertEqual(XCTWaiter.wait(for: [returned], timeout: 8), .completed, "Back preserves the Settings scroll position")
    }
    func testAllSkinSystemsFitAndSavesOfferBothSortOrders() throws {
        app.terminate(); app.launchArguments = ["--test-library"]; app.launch()
        app.tabBars.buttons["Skins"].tap()
        let picker = item("skinSystemPicker")
        XCTAssertTrue(picker.waitForExistence(timeout: 8))
        for title in ["3DS", "DS", "GBA", "GB", "GBC", "NES"] {
            XCTAssertTrue(picker.buttons[title].isHittable, title + " should be visible without swiping")
            XCTAssertGreaterThanOrEqual(picker.buttons[title].frame.height, 44)
        }
        app.tabBars.buttons["Saves"].tap()
        let sort = app.buttons["saveSort"]
        XCTAssertTrue(sort.waitForExistence(timeout: 8))
        sort.tap(); app.buttons["Oldest first"].tap()
        XCTAssertEqual(sort.value as? String, "Oldest first")
        sort.tap(); app.buttons["Newest first"].tap()
        XCTAssertEqual(sort.value as? String, "Newest first")
    }
    func testMenuVolumeAndResume() throws {
        XCTAssertFalse(app.statusBars.firstMatch.exists, "Gameplay hides the native status bar")
        app.buttons["gameMenu"].tap()
        let volume = app.sliders["gameVolume"]
        XCTAssertTrue(volume.waitForExistence(timeout: 8))
        XCTAssertTrue(item("gameBattery").waitForExistence(timeout: 8), "In-game menu header shows the shared live battery readout")
        XCTAssertFalse(app.statusBars.firstMatch.exists, "The pause menu keeps gameplay immersive")
        volume.adjust(toNormalizedSliderPosition: 0.25)
        let selectedVolume = volume.value as? String
        picture("Game menu — volume and orientation fixture")
        app.buttons["resumeGame"].tap(); state("paused=0")
        XCTAssertFalse(app.statusBars.firstMatch.exists)
        let gain = XCTNSPredicateExpectation(predicate: NSPredicate { [weak self] _, _ in
            guard let text = self?.app.staticTexts["coreSpy"].label,
                  let field = text.split(separator: " ").first(where: { $0.hasPrefix("volume=") }),
                  let value = Double(field.dropFirst(7)) else { return false }
            return abs(value - 0.25) <= 0.03
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [gain], timeout: 8), .completed)
        app.buttons["gameMenu"].tap()
        XCTAssertEqual(app.sliders["gameVolume"].value as? String, selectedVolume)
    }
    func testFailedInitialRestoreContinuesNormalBoot() throws {
        for failure in ["--fail-restore-read", "--reject-restore-request"] {
            app.terminate()
            app.launchArguments = ["--test-initial-restore", failure]
            app.launch(); app.buttons["playFixture"].tap()
            state("running=1 paused=0")
            XCTAssertFalse(app.alerts["Game could not continue"].exists)
            XCTAssertTrue(app.buttons["gameMenu"].isEnabled)
            app.buttons["gameMenu"].tap()
            XCTAssertTrue(app.buttons["resumeGame"].waitForExistence(timeout: 5))
        }
    }
    func testAllHeldButtonsStillLatchWithHapticsEnabled() throws {
        for (name, code) in [("A", 700), ("B", 701), ("X", 702), ("Y", 703),
                             ("Start", 704), ("Select", 705), ("L", 773), ("R", 774)] {
            app.buttons["pad" + name].press(forDuration: 0.08)
            state("last=\(code)")
        }
    }
    func testSpeedPickerAndMenuPause() throws {
        app.buttons["gameMenu"].tap()
        app.buttons["4×"].tap()
        picture("4x speed — game audio muted")
        app.buttons["resumeGame"].tap(); state("speed=4")
        app.buttons["gameMenu"].tap()
        app.buttons["resumeGame"].tap(); state("speed=4")
        app.buttons["gameMenu"].tap()
        app.buttons["2×"].tap()
        app.buttons["resumeGame"].tap(); state("speed=2")
        app.buttons["gameMenu"].tap()
        app.buttons["resumeGame"].tap(); state("speed=2")
        state("loads=1")
    }
    func testSaveLoadAndJoinedExit() throws {
        app.buttons["gameMenu"].tap()
        for _ in 0..<4 where !app.buttons["saveState"].isHittable { app.swipeUp() }
        XCTAssertTrue(app.buttons["saveState"].isHittable)
        app.buttons["saveState"].tap()
        XCTAssertTrue(prompt("Save to slot 1?").waitForExistence(timeout: 8))
        app.buttons["promptConfirm"].tap()
        XCTAssertTrue(app.staticTexts["Slot 1 saved."].waitForExistence(timeout: 8))
        app.buttons["loadState"].tap()
        XCTAssertTrue(prompt("Load slot 1?").waitForExistence(timeout: 8))
        app.buttons["promptConfirm"].tap()
        XCTAssertTrue(app.staticTexts["Slot 1 loaded. Tap Resume to continue."].waitForExistence(timeout: 8))
        app.buttons["saveOptions"].tap()
        app.buttons["saveAndLeave"].tap()
        XCTAssertTrue(prompt("Overwrite slot 1?").waitForExistence(timeout: 8))
        app.buttons["promptConfirm"].tap()
        XCTAssertTrue(app.buttons["playFixture"].waitForExistence(timeout: 10))
        app.buttons["playFixture"].tap()
        XCTAssertTrue(app.alerts["Previous session found—continue?"].waitForExistence(timeout: 8))
        app.alerts.buttons["Continue"].tap()
        state("paused=0")
        state("stops=1"); state("loads=2")
    }
    func testNamedSaveConfirmationAndDelete() throws {
        app.buttons["gameMenu"].tap()
        for _ in 0..<5 where !app.buttons["saveState"].isHittable { app.swipeUp() }
        app.buttons["saveState"].tap()
        let confirmation = prompt("Save to slot 1?")
        XCTAssertTrue(confirmation.waitForExistence(timeout: 8))
        confirmation.buttons["Cancel"].tap(); state("saved=0")
        app.buttons["saveState"].tap()
        confirmation.textFields["saveName"].tap()
        confirmation.textFields["saveName"].typeText("Santalune")
        confirmation.buttons["Save"].tap()
        XCTAssertTrue(app.staticTexts["Slot 1 saved."].waitForExistence(timeout: 8))
        for _ in 0..<5 where !app.buttons["manageStates"].isHittable { app.swipeDown() }
        app.buttons["manageStates"].tap()
        XCTAssertTrue(app.staticTexts["Santalune"].waitForExistence(timeout: 8))
        let frame = app.descendants(matching: .any).matching(identifier: "statePreview1").firstMatch
        let captured = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "Saved gameplay frame"), object: frame)
        XCTAssertEqual(XCTWaiter.wait(for: [captured], timeout: 8), .completed)
        app.buttons["stateMenu1"].tap()
        app.buttons["deleteSlot1"].tap()
        XCTAssertTrue(prompt("Delete this save?").waitForExistence(timeout: 8))
        app.buttons["promptConfirm"].tap()
        XCTAssertTrue(app.staticTexts["No save states yet."].waitForExistence(timeout: 8))
    }
    func testTimedAutosaveIsSeparateFromManualSlots() throws {
        app.terminate(); app.launchArguments = ["--test-autosave"]; app.launch()
        app.buttons["playFixture"].tap()
        state("saved=1")
        app.buttons["gameMenu"].tap()
        for _ in 0..<5 where !app.buttons["manageStates"].isHittable { app.swipeUp() }
        app.buttons["manageStates"].tap()
        XCTAssertTrue(app.staticTexts["Auto Save · Slot 9"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["loadSlot9"].exists)
        XCTAssertFalse(app.buttons["loadSlot1"].exists)
    }

    func testUniversalRuntimeGraphicsDefaults() throws {
        state("resolution=2 upscale=0")
        app.terminate(); app.launchArguments = ["--fixture-a19"]; app.launch()
        app.buttons["playFixture"].tap()
        state("resolution=4 upscale=2")
    }

    func testSkinAlignmentTouchRoutingAndQuickSaveConfirmation() throws {
        app.terminate(); app.launchArguments = ["--test-skin"]; app.launch()
        app.buttons["playFixture"].tap()
        state("paused=0")
        for orientation in [UIDeviceOrientation.landscapeLeft, .landscapeRight] {
            XCUIDevice.shared.orientation = orientation
            let rotated = XCTNSPredicateExpectation(predicate: NSPredicate { [weak self] _, _ in
                guard let self else { return false }
                return self.app.windows.firstMatch.frame.width > self.app.windows.firstMatch.frame.height
            }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [rotated], timeout: 10), .completed)
            XCTAssertTrue(app.buttons["skinQuickSave"].waitForExistence(timeout: 8))
            let top = item("topScreen").frame, bottom = item("bottomScreen").frame
            XCTAssertEqual(top.width / top.height, 5.0 / 3.0, accuracy: 0.02)
            XCTAssertEqual(bottom.width / bottom.height, 4.0 / 3.0, accuracy: 0.02)
            XCTAssertLessThan(top.maxX, bottom.minX)
            XCTAssertLessThan(item("directionPad").frame.maxY, item("circlePad").frame.minY)
            for key in ["A", "B", "X", "Y", "L", "R", "Select", "Start"] {
                let frame = item("pad" + key).frame
                XCTAssertGreaterThanOrEqual(frame.width, 43.9)
                XCTAssertGreaterThanOrEqual(frame.height, 43.9)
                XCTAssertFalse(top.intersects(frame)); XCTAssertFalse(bottom.intersects(frame))
            }
            app.buttons["padA"].tap(); state("last=700")
            item("bottomScreen").coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            state(orientation == .landscapeLeft ? "touches=1" : "touches=2")
            picture("Control Deck \(orientation.rawValue) — skin artwork and native input fixture")
        }
        app.buttons["skinQuickSave"].tap()
        XCTAssertTrue(prompt("Save to slot 1?").waitForExistence(timeout: 8))
        app.buttons["promptCancel"].tap(); state("saved=0")
    }

    func testApprovedLibraryNavigationAndSettings() throws {
        app.terminate(); app.launchArguments = ["--test-library"]; app.launch()
        XCTAssertTrue(app.tabBars.buttons["Library"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.statusBars.firstMatch.exists)
        XCTAssertTrue(app.buttons["importGame"].exists)
        XCTAssertEqual(app.tabBars.count, 1)
        XCTAssertEqual(app.tabBars.buttons.count, 4, "Library, Saves, Skins and Settings use one native tab bar")
        XCTAssertFalse(app.buttons["consoleNavigation"].exists)
        XCTAssertTrue(item("clawBrand").exists)
        XCTAssertFalse(app.buttons["consoleProfile"].exists)
        XCTAssertFalse(app.buttons["librarySort"].exists, "Sorting no longer takes up a home footer")
        XCTAssertGreaterThan(app.tabBars.buttons["Library"].frame.minY, app.buttons["importGame"].frame.maxY)
        app.tabBars.buttons["Saves"].tap()
        XCTAssertTrue(app.staticTexts["Pick up where you left off."].waitForExistence(timeout: 8))
        XCTAssertTrue(app.statusBars.firstMatch.exists)
        XCTAssertFalse(app.buttons["New manual save"].exists)
        app.tabBars.buttons["Skins"].tap()
        XCTAssertTrue(app.buttons["importSkin"].waitForExistence(timeout: 8))
        app.tabBars.buttons["Settings"].tap()
        XCTAssertTrue(app.staticTexts["Make Claw yours."].waitForExistence(timeout: 8))
        XCTAssertTrue(app.statusBars.firstMatch.exists)
        app.buttons["Blue accent"].tap()
        picture("Approved library, saves and settings — actual SwiftUI fixture")
        XCTAssertFalse(app.buttons["Profile"].exists)
        app.tabBars.buttons["Library"].tap()
        app.buttons["consoleSearch"].tap()
        let search = app.textFields["gameSearch"]
        XCTAssertTrue(search.waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["librarySort"].exists, "Search owns the library sort menu")
        search.tap(); search.typeText("No matching game")
        XCTAssertTrue(app.staticTexts["No matching games"].waitForExistence(timeout: 8))
    }

    func testSearchFieldOpensKeyboardFiltersAndLeavingDismisses() throws {
        app.terminate(); app.launchArguments = ["--test-library"]; app.launch()
        XCTAssertTrue(app.tabBars.buttons["Library"].waitForExistence(timeout: 8))
        XCTAssertTrue(item("libraryBattery").waitForExistence(timeout: 8), "Library pill keeps its live battery readout")
        app.buttons["consoleSearch"].tap()
        let search = app.textFields["gameSearch"]
        XCTAssertTrue(search.waitForExistence(timeout: 8), "Search opens from the library action")
        XCTAssertTrue(app.keyboards.element.waitForExistence(timeout: 8), "Entering Search opens the keyboard without another tap")
        XCTAssertLessThanOrEqual(app.buttons["closeLibrarySearch"].frame.maxY, app.keyboards.element.frame.minY + 1,
                                 "Back remains reachable above the keyboard")
        search.typeText("Orb")
        XCTAssertTrue(app.buttons["Orbit Quest, Dual-Screen 3D"].waitForExistence(timeout: 8))
        search.typeText("it")
        XCTAssertTrue(app.buttons["Orbit Quest, Dual-Screen 3D"].exists)
        XCTAssertTrue(app.keyboards.element.exists, "Typing and filtering must not dismiss the keyboard")
        app.buttons["Clear search"].tap()
        XCTAssertTrue(app.buttons["Orbit Quest, Dual-Screen 3D"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.keyboards.element.exists, "Clearing search keeps the field focused")
        search.typeText("Missing")
        XCTAssertTrue(app.staticTexts["No matching games"].waitForExistence(timeout: 8))
        picture("Search field — keyboard, live filtering and empty result")
        app.buttons["closeLibrarySearch"].tap()
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: search)
        XCTAssertEqual(XCTWaiter.wait(for: [gone], timeout: 5), .completed)
        let keyboardGone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: app.keyboards.element)
        XCTAssertEqual(XCTWaiter.wait(for: [keyboardGone], timeout: 5), .completed, "Leaving Search dismisses the keyboard")
    }

    func testRepeatedSearchEntryAndRotationKeepKeyboardInBothInterfaces() throws {
        app.terminate(); app.launchArguments = ["--test-library"]; app.launch()
        for style in ["Claw UI", "Stacked UI"] {
            app.tabBars.buttons["Settings"].tap()
            app.buttons[style].tap()
            app.tabBars.buttons["Library"].tap()
            for attempt in 0..<3 {
                app.buttons["consoleSearch"].tap()
                let search = app.textFields["gameSearch"]
                XCTAssertTrue(search.waitForExistence(timeout: 8))
                XCTAssertTrue(app.keyboards.element.waitForExistence(timeout: 8))
                let value = search.value as? String ?? ""
                XCTAssertTrue(value.isEmpty || value == search.placeholderValue, "Re-entering Search clears the old query")
                search.typeText("Orb")
                XCTAssertTrue(app.buttons["Orbit Quest, Dual-Screen 3D"].waitForExistence(timeout: 8))
                let droppedKeyboard = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: app.keyboards.element)
                droppedKeyboard.isInverted = true
                XCTAssertEqual(XCTWaiter.wait(for: [droppedKeyboard], timeout: 1), .completed,
                               "The keyboard must remain open after layout settles")
                if attempt == 0 {
                    XCUIDevice.shared.orientation = .landscapeLeft
                    let rotated = XCTNSPredicateExpectation(predicate: NSPredicate { [weak self] _, _ in
                        guard let self else { return false }
                        let frame = self.app.windows.firstMatch.frame
                        return frame.width > frame.height
                    }, object: nil)
                    XCTAssertEqual(XCTWaiter.wait(for: [rotated], timeout: 8), .completed)
                    XCTAssertTrue(search.isHittable)
                    search.typeText("it")
                    XCTAssertTrue(app.keyboards.element.exists)
                    XCTAssertTrue(app.buttons["Orbit Quest, Dual-Screen 3D"].exists)
                    XCUIDevice.shared.orientation = .portrait
                    XCTAssertTrue(search.waitForExistence(timeout: 8))
                }
                app.buttons["closeLibrarySearch"].tap()
                let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: app.keyboards.element)
                XCTAssertEqual(XCTWaiter.wait(for: [gone], timeout: 5), .completed)
            }
        }
    }

    func testCarouselImportHubSkinPreviewAndAuthenticLayout() throws {
        app.terminate(); app.launchArguments = ["--test-library", "--test-carousel"]; app.launch()
        let carousel = app.scrollViews["gameCarousel"]
        XCTAssertTrue(carousel.waitForExistence(timeout: 8))
        XCTAssertTrue(app.statusBars.firstMatch.exists, "The real iOS time, signal and battery stay visible")
        for system in ["all", "3ds", "nds"] {
            let control = app.buttons["consoleSystem-" + system]
            XCTAssertTrue(control.exists)
            XCTAssertGreaterThanOrEqual(control.frame.width, 91.9)
            XCTAssertEqual(control.frame.height, 60, accuracy: 1)
        }
        let systems = item("consoleSystemBar")
        for _ in 0..<4 where !app.buttons["consoleSystem-nes"].isHittable { systems.swipeLeft() }
        XCTAssertTrue(app.buttons["consoleSystem-nes"].isHittable, "Further systems scroll into view without shrinking the icons")
        app.buttons["consoleSystem-nes"].tap()
        XCTAssertTrue(app.buttons["consoleSystem-nes"].isSelected)
        for _ in 0..<4 where !app.buttons["consoleSystem-all"].isHittable { systems.swipeRight() }
        app.buttons["consoleSystem-all"].tap()
        let first = app.buttons["Orbit Quest, Dual-Screen 3D"]
        XCTAssertTrue(first.waitForExistence(timeout: 8))
        XCTAssertTrue(first.isSelected)
        carousel.swipeLeft()
        let moved = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isSelected == false"), object: first)
        XCTAssertEqual(XCTWaiter.wait(for: [moved], timeout: 5), .completed)
        picture("Claw carousel — selected cover straight, neighboring covers tilted")
        app.buttons["importGame"].tap()
        XCTAssertTrue(app.buttons["importGamesFromFiles"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["hubImportSkin"].exists)
        XCTAssertTrue(app.buttons["hubImportSaves"].exists)
        picture("Import hub — real interface, no decorative artwork")
        app.buttons["Close import"].tap()
        app.tabBars.buttons["Settings"].tap()
        app.buttons["settingsSkins"].tap()
        XCTAssertTrue(app.buttons["previewSkin-obsidian"].waitForExistence(timeout: 8))
        app.buttons["Landscape"].tap()
        app.buttons["previewSkin-obsidian"].tap()
        XCTAssertTrue(app.buttons["Close preview"].waitForExistence(timeout: 8))
        picture("Full-screen landscape skin preview")
        app.buttons["Close preview"].tap()
        app.buttons["Back"].tap()
        app.tabBars.buttons["Settings"].tap()
        app.buttons["Stacked UI"].tap()
        app.tabBars.buttons["Library"].tap()
        XCTAssertTrue(item("authenticLibrary").waitForExistence(timeout: 8))
        XCTAssertEqual(app.buttons["consoleSystem-3ds"].frame.height, 60, accuracy: 1,
                       "Claw and Authentic use the same system cards")
        picture("Stacked UI — portrait")
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(item("authenticLibrary").waitForExistence(timeout: 8))
        picture("Stacked UI — landscape")
        XCUIDevice.shared.orientation = .portrait
        app.tabBars.buttons["Settings"].tap()
        app.buttons["Claw UI"].tap()
        app.tabBars.buttons["Library"].tap()
        XCTAssertTrue(app.scrollViews["gameCarousel"].waitForExistence(timeout: 8))
    }

    func testImportedSkinMiniAndFullPreviewsKeepCornersAndTransparency() throws {
        app.terminate(); app.launchArguments = ["--test-library", "--test-imported-preview"]; app.launch()
        app.tabBars.buttons["Settings"].tap()
        app.buttons["settingsSkins"].tap()
        let id = "841C391A-F8AC-4B1C-9025-2EBD2BAFD777"
        func assertArtwork(_ element: XCUIElement, source: CGSize) {
            let rendered = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                guard element.exists, let image = element.screenshot().image.cgImage else { return false }
                let scale = min(CGFloat(image.width) / source.width, CGFloat(image.height) / source.height)
                let origin = CGPoint(x: (CGFloat(image.width) - source.width * scale) / 2,
                                     y: (CGFloat(image.height) - source.height * scale) / 2)
                func pixel(_ x: CGFloat, _ y: CGFloat) -> [UInt8]? {
                    let point = CGPoint(x: origin.x + source.width * scale * x,
                                        y: origin.y + source.height * scale * y)
                    guard let sample = image.cropping(to: CGRect(x: point.x.rounded(.down), y: point.y.rounded(.down), width: 1, height: 1)) else { return nil }
                    var rgba = [UInt8](repeating: 0, count: 4)
                    let success = rgba.withUnsafeMutableBytes { bytes -> Bool in
                        guard let context = CGContext(data: bytes.baseAddress, width: 1, height: 1,
                            bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
                        context.draw(sample, in: CGRect(x: 0, y: 0, width: 1, height: 1)); return true
                    }
                    return success ? rgba : nil
                }
                guard let red = pixel(0.05, 0.05), let yellow = pixel(0.95, 0.05),
                      let magenta = pixel(0.05, 0.95), let white = pixel(0.95, 0.95),
                      let clearCorner = pixel(0.06, 0.705), let greenCenter = pixel(0.15, 0.75) else { return false }
                return red[0] > 180 && red[1] < 90 && red[2] < 90 &&
                    yellow[0] > 180 && yellow[1] > 180 && yellow[2] < 90 &&
                    magenta[0] > 180 && magenta[1] < 90 && magenta[2] > 180 &&
                    white[0] > 180 && white[1] > 180 && white[2] > 180 &&
                    clearCorner[0] < 100 && clearCorner[1] < 130 && clearCorner[2] > 140 &&
                    greenCenter[0] < 90 && greenCenter[1] > 180 && greenCenter[2] < 90
            }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [rendered], timeout: 10), .completed,
                           "All four corners, authored control position and transparent edges survive the fitted preview")
        }
        for (orientation, size) in [("Portrait", CGSize(width: 200, height: 400)),
                                    ("Landscape", CGSize(width: 400, height: 200))] {
            app.buttons[orientation].tap()
            let miniature = app.buttons["previewSkin-" + id]
            for _ in 0..<5 {
                if miniature.exists && miniature.isHittable { break }
                app.scrollViews["skinBrowser"].swipeUp()
            }
            XCTAssertTrue(miniature.isHittable)
            assertArtwork(miniature, source: size)
            miniature.tap()
            XCTAssertTrue(app.buttons["Close preview"].waitForExistence(timeout: 8))
            assertArtwork(item("skinPreviewBitmap-" + id), source: size)
            picture("Imported \(orientation) skin — fitted mini/full raster with transparent controls")
            app.buttons["Close preview"].tap()
            app.scrollViews["skinBrowser"].swipeDown()
            app.scrollViews["skinBrowser"].swipeDown()
        }
    }

    func testAppIconChoiceAndAccentMatchingPersist() throws {
        app.terminate()
        app.launchArguments = ["--test-library", "--reset-icon-preferences"]
        app.launch()
        func openIconSettings() {
            XCTAssertTrue(app.tabBars.buttons["Settings"].waitForExistence(timeout: 8))
            app.tabBars.buttons["Settings"].tap()
            let green = app.buttons["Green app icon"]
            for _ in 0..<5 {
                if green.isHittable { break }
                app.scrollViews.firstMatch.swipeUp()
            }
            XCTAssertTrue(green.isHittable)
        }
        openIconSettings()
        app.buttons["Green app icon"].tap()
        let matching = item("appIconMatchesAccent")
        XCTAssertEqual(matching.value as? String, "Off")
        app.terminate(); app.launchArguments = ["--test-library"]; app.launch()
        openIconSettings()
        XCTAssertTrue(app.buttons["Green app icon"].isSelected)
        XCTAssertEqual(item("appIconMatchesAccent").value as? String, "Off")
        item("appIconMatchesAccent").tap()
        XCTAssertEqual(item("appIconMatchesAccent").value as? String, "On")
        picture("App icon colors and automatic accent matching — native icon API disabled in fixture")
    }

    func testLibraryPillAndCoversSurviveBriefBackgrounding() throws {
        app.terminate(); app.launchArguments = ["--test-library"]; app.launch()
        XCTAssertTrue(app.tabBars.buttons["Library"].waitForExistence(timeout: 8))
        let battery = item("libraryBattery")
        XCTAssertTrue(battery.waitForExistence(timeout: 8))
        let cover = app.buttons["Orbit Quest, Dual-Screen 3D"]
        XCTAssertTrue(cover.waitForExistence(timeout: 8))
        assertFixtureArtwork(cover)
        let batteryOrigin = battery.frame.origin, coverOrigin = cover.frame.origin
        XCUIDevice.shared.press(.home)
        Thread.sleep(forTimeInterval: 1.5)
        app.activate()
        XCTAssertTrue(app.tabBars.buttons["Library"].waitForExistence(timeout: 8))
        XCTAssertTrue(battery.waitForExistence(timeout: 8), "The status capsule returns instead of collapsing or replaying its entrance")
        XCTAssertTrue(app.buttons["Orbit Quest, Dual-Screen 3D"].waitForExistence(timeout: 8), "Retained covers survive a short backgrounding")
        XCTAssertFalse(battery.label.isEmpty, "A real battery change while backgrounded is allowed")
        assertFixtureArtwork(cover)
        XCTAssertEqual(battery.frame.origin.x, batteryOrigin.x, accuracy: 1)
        XCTAssertEqual(battery.frame.origin.y, batteryOrigin.y, accuracy: 1)
        XCTAssertEqual(app.buttons["Orbit Quest, Dual-Screen 3D"].frame.origin.x, coverOrigin.x, accuracy: 1)
        XCTAssertEqual(app.buttons["Orbit Quest, Dual-Screen 3D"].frame.origin.y, coverOrigin.y, accuracy: 1)
        picture("Library after a brief backgrounding")
    }

    func testFloatingGameBoyScreensPreservePictureAndInputsAcrossRotation() throws {
        for system in ["gb", "gbc", "gba"] {
            app.terminate()
            app.launchArguments = ["--test-handheld-overlay", "--fixture-system=" + system]
            app.launch(); app.buttons["playFixture"].tap()
            state("paused=0"); state("resolution=1 upscale=0")
            for orientation in [UIDeviceOrientation.portrait, .landscapeLeft, .landscapeRight] {
                XCUIDevice.shared.orientation = orientation
                let rotated = XCTNSPredicateExpectation(predicate: NSPredicate { [weak self] _, _ in
                    guard let self else { return false }
                    let window = self.app.windows.firstMatch.frame
                    return (window.width > window.height) == (orientation != .portrait)
                }, object: nil)
                XCTAssertEqual(XCTWaiter.wait(for: [rotated], timeout: 10), .completed)
                let bounds = app.windows.firstMatch.frame, top = item("topScreen").frame
                XCTAssertEqual(top.width / top.height, system == "gba" ? 1.5 : 160.0 / 144, accuracy: 0.002)
                let status = app.statusBars.firstMatch
                XCTAssertFalse(status.exists, "Gameplay hides status chrome in every orientation")
                let contentHeight = bounds.maxY - (status.exists ? status.frame.maxY : bounds.minY)
                XCTAssertTrue(abs(top.width - bounds.width) < 1 || abs(top.height - contentHeight) < 1,
                              "Game uses the largest complete picture without a control strip")
                XCTAssertFalse(item("bottomScreen").isHittable)
                XCTAssertFalse(item("padX").isHittable)
                XCTAssertFalse(item("padY").isHittable)
                XCTAssertFalse(item("skinQuickSave").isHittable)
                XCTAssertEqual(item("padL").isHittable, system == "gba")
                for key in ["padA", "padB", "padStart", "padSelect", "directionPad", "gameMenu"] {
                    let button = item(key)
                    XCTAssertTrue(button.isHittable, system + ": " + key)
                    XCTAssertGreaterThanOrEqual(button.frame.width, 43.9)
                    XCTAssertGreaterThanOrEqual(button.frame.height, 43.9)
                    XCTAssertTrue(bounds.insetBy(dx: -1, dy: -1).contains(button.frame))
                }
                app.buttons["padA"].tap(); state("last=8"); state("loads=1")
                picture(system + " floating controls, complete picture — mocked core fixture")
            }
        }
    }

    func testFloatingLayoutEditorSaveCancelAndOrientationIsolation() throws {
        app.terminate(); XCUIDevice.shared.orientation = .portrait
        app.launchArguments = ["--test-handheld-overlay", "--fixture-system=gba"]
        app.launch(); app.buttons["playFixture"].tap(); state("paused=0")
        let originalA = item("padA").frame, originalB = item("padB").frame
        func openEditor() {
            app.buttons["gameMenu"].tap()
            let controls = app.buttons["gameControlsSettings"]
            XCTAssertTrue(controls.waitForExistence(timeout: 8)); controls.tap()
            XCTAssertFalse(item("handheldScreenMode").exists)
            XCTAssertFalse(app.buttons["Fill screen"].exists)
            let edit = app.buttons["editHandheldLayout"]
            for _ in 0..<5 where !edit.isHittable { app.swipeUp() }
            XCTAssertTrue(edit.isHittable); edit.tap()
            XCTAssertTrue(item("editControl-a").waitForExistence(timeout: 8))
            state("paused=1"); state("loads=1")
        }
        openEditor()
        let a = item("editControl-a").coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        a.press(forDuration: 0.1, thenDragTo: a.withOffset(CGVector(dx: -20, dy: -32)))
        app.buttons["liveControlTools"].tap()
        app.sliders["A size"].adjust(toNormalizedSliderPosition: 0.65)
        app.buttons["Done"].tap()
        app.buttons["saveHandheldLayout"].tap()
        state("paused=0")
        XCTAssertFalse(item("liveControlsEditor").exists, "Save returns directly to the running game")
        let savedA = item("padA").frame
        XCTAssertEqual(savedA.width, savedA.height, accuracy: 1, "Enlarging A preserves a circle")
        XCTAssertLessThan(savedA.midY, originalA.midY - 20)
        XCTAssertGreaterThan(savedA.width, originalA.width + 8)
        XCTAssertEqual(item("padB").frame.midX, originalB.midX, accuracy: 1)
        XCTAssertEqual(item("padB").frame.midY, originalB.midY, accuracy: 1, "A and B can be edited independently")
        app.buttons["padA"].tap(); state("last=8"); state("loads=1")
        openEditor()
        let b = item("editControl-b").coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        b.press(forDuration: 0.1, thenDragTo: b.withOffset(CGVector(dx: -20, dy: -20)))
        app.buttons["Cancel"].tap()
        app.buttons["Resume"].tap(); state("paused=0")
        XCTAssertEqual(item("padB").frame.midX, originalB.midX, accuracy: 1)
        XCTAssertEqual(item("padB").frame.midY, originalB.midY, accuracy: 1, "Cancel keeps the saved controls")
        for orientation in [UIDeviceOrientation.landscapeLeft, .portrait] {
            XCUIDevice.shared.orientation = orientation
            let rotated = XCTNSPredicateExpectation(predicate: NSPredicate { [weak self] _, _ in
                guard let self else { return false }
                let window = self.app.windows.firstMatch.frame
                return (window.width > window.height) == (orientation != .portrait)
            }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [rotated], timeout: 10), .completed)
            app.buttons["padB"].tap(); state("last=0"); state("loads=1")
        }
        XCTAssertEqual(item("padA").frame.midY, savedA.midY, accuracy: 1)
        XCTAssertEqual(item("padA").frame.width, savedA.width, accuracy: 1)
    }

    func testLiveCustomComboAndJoystickUseRealInputs() throws {
        app.terminate(); XCUIDevice.shared.orientation = .landscapeLeft
        app.launchArguments = ["--test-handheld-overlay", "--fixture-system=gba"]
        app.launch(); app.buttons["playFixture"].tap(); state("paused=0")
        app.buttons["gameMenu"].tap(); app.buttons["gameControlsSettings"].tap()
        XCTAssertFalse(item("handheldScreenMode").exists, "Fill has been removed from the in-game form")
        let movement = item("handheldMovement")
        for _ in 0..<5 where !movement.isHittable { app.swipeUp() }
        XCTAssertTrue(movement.isHittable); movement.buttons["Joystick"].tap()
        let edit = app.buttons["editHandheldLayout"]
        for _ in 0..<5 where !edit.isHittable { app.swipeUp() }
        edit.tap(); state("paused=1"); state("loads=1")
        XCTAssertTrue(item("liveControlsEditor").waitForExistence(timeout: 8))
        XCTAssertFalse(app.buttons["Fill screen"].exists, "Edit opens the editor, never a picker menu")
        picture("Live control editor over actual paused Metal fixture")
        app.buttons["liveControlTools"].tap()
        app.buttons["addComboButton"].tap()
        XCTAssertGreaterThanOrEqual(app.buttons["cancelComboButton"].frame.width, 64, "Cancel has room for its complete label")
        app.buttons["comboInput-r"].tap(); app.buttons["comboInput-b"].tap()
        XCTAssertTrue(app.buttons["saveComboButton"].isEnabled, "Naming a custom button is optional")
        app.buttons["saveComboButton"].tap()
        app.buttons["Done"].tap()
        app.buttons["saveHandheldLayout"].tap(); state("paused=0"); state("loads=1")
        let combo = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "combo-")).firstMatch
        XCTAssertTrue(combo.waitForExistence(timeout: 8)); combo.tap()
        XCTAssertEqual(combo.label, "R+B")
        XCTAssertEqual(combo.frame.width, combo.frame.height, accuracy: 1)
        state("combo=1"); state("held=0")
        XCTAssertTrue(item("circlePad").isHittable)
        XCTAssertFalse(item("directionPad").isHittable)
        item("circlePad").coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        state("last=7"); state("held=0")
    }
    func testDirectControlEditorPausesAndReturnsWithoutReloading() throws {
        app.terminate(); app.launchArguments = ["--test-handheld-overlay", "--fixture-system=gba"]
        app.launch(); app.buttons["playFixture"].tap(); state("paused=0")
        for orientation in [UIDeviceOrientation.portrait, .landscapeLeft] {
            XCUIDevice.shared.orientation = orientation
            let shortcut = app.buttons["quickEditControls"]
            XCTAssertTrue(shortcut.waitForExistence(timeout: 8)); XCTAssertTrue(shortcut.isHittable)
            let original = shortcut.frame
            shortcut.tap(); state("paused=1"); state("loads=1")
            XCTAssertTrue(item("liveControlsEditor").waitForExistence(timeout: 8))
            let hand = item("editControl-edit")
            XCTAssertTrue(hand.isHittable, "The editor toolbar must not cover the hand shortcut")
            let origin = hand.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            origin.press(forDuration: 0.1, thenDragTo: origin.withOffset(CGVector(dx: 0, dy: 80)))
            app.buttons["Cancel"].tap(); state("paused=0")
            XCTAssertFalse(item("liveControlsEditor").exists)
            XCTAssertEqual(shortcut.frame.midY, original.midY, accuracy: 1, "Cancel discards the shortcut move")
            shortcut.tap(); state("paused=1")
            let start = hand.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            start.press(forDuration: 0.1, thenDragTo: start.withOffset(CGVector(dx: 0, dy: 80)))
            app.buttons["saveHandheldLayout"].tap(); state("paused=0"); state("loads=1")
            XCTAssertEqual(shortcut.frame.midY, original.midY + 80, accuracy: 2, "Save moves the actual gameplay shortcut")
            for key in ["padA", "padB", "padSelect", "padStart", "directionPad"] {
                let frame = item(key).frame
                XCTAssertEqual(frame.width, frame.height, accuracy: 1, key + " stays circular")
            }
            for key in ["padL", "padR"] {
                let frame = item(key).frame
                XCTAssertGreaterThan(frame.width, frame.height, key + " is a horizontal pill")
            }
        }
    }
    func testLibraryClockIsDisplayOnly() throws {
        app.terminate(); app.launchArguments = ["--test-library"]; app.launch()
        let clock = item("libraryClock")
        XCTAssertTrue(clock.waitForExistence(timeout: 8)); clock.tap()
        XCTAssertFalse(app.staticTexts["Library activity"].exists)
        XCTAssertEqual(app.sheets.count, 0)
        XCTAssertTrue(app.buttons["continueGame"].isHittable)
    }

    func testAddedSystemsUseNativeScreensAndCorrectControls() throws {
        for system in ["gba", "gb", "gbc", "nes", "nds"] {
            app.terminate()
            XCUIDevice.shared.orientation = .landscapeLeft
            app.launchArguments = ["--test-skin", "--fixture-system=" + system]
            app.launch(); app.buttons["playFixture"].tap()
            state("paused=0"); state("resolution=1 upscale=0")
            XCTAssertTrue(app.buttons["skinQuickSave"].waitForExistence(timeout: 8))
            let top = item("topScreen").frame
            let aspect = system == "gba" ? 1.5 : ["gb", "gbc"].contains(system) ? 160.0 / 144 : 4.0 / 3
            XCTAssertEqual(top.width / top.height, aspect, accuracy: 0.02)
            XCTAssertEqual(item("bottomScreen").isHittable, system == "nds")
            XCTAssertEqual(item("padX").isHittable, system == "nds")
            XCTAssertEqual(item("padY").isHittable, system == "nds")
            XCTAssertEqual(item("padL").isHittable, ["gba", "nds"].contains(system))
            for key in ["padA", "padB", "padStart", "padSelect", "directionPad"] {
                XCTAssertTrue(item(key).isHittable, system + ": " + key)
                XCTAssertFalse(top.intersects(item(key).frame))
            }
            app.buttons["padA"].tap(); state("last=8")
            if system == "nds" {
                let bottom = item("bottomScreen")
                XCTAssertEqual(bottom.frame.width / bottom.frame.height, 4.0 / 3, accuracy: 0.02)
                bottom.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
                state("touches=1")
            }
            picture(system.uppercased() + " native display and system controls — mocked core fixture")
            app.buttons["skinQuickSave"].tap()
            XCTAssertTrue(prompt("Save to slot 1?").waitForExistence(timeout: 8))
            app.buttons["promptConfirm"].tap()
            state("saved=1")
            app.buttons["gameMenu"].tap()
            for _ in 0..<5 where !app.buttons["manageStates"].isHittable { app.swipeUp() }
            XCTAssertTrue(app.buttons["manageStates"].isHittable)
            app.buttons["manageStates"].tap()
            XCTAssertTrue(app.buttons["loadSlot1"].waitForExistence(timeout: 8))
        }
    }

    func testGameBoyReturnToLibraryAndReopenInPortrait() throws {
        app.terminate()
        XCUIDevice.shared.orientation = .portrait
        app.launchArguments = ["--test-skin", "--fixture-system=gb"]
        app.launch(); app.buttons["playFixture"].tap()
        state("paused=0")
        XCTAssertTrue(app.buttons["skinQuickSave"].waitForExistence(timeout: 8))
        picture("Portrait Obsidian handheld controls — mocked core fixture")
        app.buttons["gameMenu"].tap()
        for _ in 0..<4 where !app.buttons["stopGame"].isHittable { app.swipeUp() }
        app.buttons["stopGame"].tap()
        XCTAssertTrue(app.buttons["playFixture"].waitForExistence(timeout: 8))
        app.buttons["playFixture"].tap()
        state("loads=2")
        XCTAssertTrue(app.buttons["skinQuickSave"].waitForExistence(timeout: 8))
    }

}
