import XCTest

final class HermesUITests: XCTestCase {

    var app: XCUIApplication!
    let screenshotDir = "/tmp/uat_screenshots"

    override func setUpWithError() throws {
        continueAfterFailure = false
        try FileManager.default.createDirectory(atPath: screenshotDir, withIntermediateDirectories: true)
        app = XCUIApplication()
        app.launchArguments = ["-hermes.serverURL", "http://127.0.0.1:3001", "-hermes.apiKey", ""]
        app.launch()
        XCTAssertTrue(app.navigationBars["Hermes"].waitForExistence(timeout: 8))
    }

    override func tearDownWithError() throws {
        app.terminate()
    }

    // MARK: - Section 2: Sidebar & Chat List

    func test_UAT_02_SidebarElements() throws {
        let nav = app.navigationBars["Hermes"]
        XCTAssertTrue(nav.exists, "Hermes navigation bar exists")
        save("02_sidebar")

        let gearBtn = findButton(nav, names: ["gearshape", "Settings"])
        XCTAssertTrue(gearBtn.exists, "Settings gear button visible")

        let composeBtn = findButton(nav, names: ["square.and.pencil", "New Chat", "compose"])
        XCTAssertTrue(composeBtn.exists, "Compose button visible")

        let searchField = app.searchFields.firstMatch
        XCTAssertTrue(searchField.waitForExistence(timeout: 3), "Search chats bar visible")
    }

    func test_UAT_02_NewChat() throws {
        let nav = app.navigationBars["Hermes"]
        let composeBtn = findButton(nav, names: ["square.and.pencil", "New Chat", "compose"])
        XCTAssertTrue(composeBtn.exists, "Compose button must exist")
        composeBtn.tap()
        save("02_after_new_chat_tap")

        XCTAssertTrue(waitForChat(), "Chat view appears after tapping compose")
        save("02_chat_view")
    }

    func test_UAT_02_SearchBar() throws {
        let searchField = app.searchFields.firstMatch
        XCTAssertTrue(searchField.waitForExistence(timeout: 3), "Search bar exists")
        searchField.tap()
        save("02_search_focused")

        searchField.typeText("hello")
        save("02_search_typed")

        let cancel = app.buttons["Cancel"]
        if cancel.waitForExistence(timeout: 2) { cancel.tap() }
        save("02_search_cancelled")
    }

    func test_UAT_02_SwipeActions() throws {
        try ensureChatInSidebar()
        save("02_before_swipe")

        // SwiftUI List(.sidebar) renders as UICollectionView in iOS 16+.
        // Swipe on a cell found via collection view; fall back to any "New Chat" static text.
        let swipeTarget = chatRowElement()
        XCTAssertTrue(swipeTarget.waitForExistence(timeout: 5), "Chat row element found for swipe test")

        // Slow press-drag from right→left to reveal trailing swipe actions
        let startPt = swipeTarget.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5))
        let endPt   = swipeTarget.coordinate(withNormalizedOffset: CGVector(dx: 0.1,  dy: 0.5))
        startPt.press(forDuration: 0.05, thenDragTo: endPt)
        save("02_swipe_left")

        let deleteBtn  = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Delete'")).firstMatch
        let archiveBtn = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Archive'")).firstMatch
        let pinBtn     = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Pin'")).firstMatch

        XCTAssertTrue(deleteBtn.waitForExistence(timeout: 3), "Delete swipe action visible")
        let hasMoreActions = archiveBtn.waitForExistence(timeout: 2) || pinBtn.waitForExistence(timeout: 1)
        XCTAssertTrue(hasMoreActions, "Archive or Pin swipe action visible")
        save("02_swipe_actions_revealed")

        swipeTarget.swipeRight()
        save("02_swipe_dismissed")
    }

    func test_UAT_02_ContextMenu() throws {
        try ensureChatInSidebar()
        let cell = chatRowElement()
        XCTAssertTrue(cell.waitForExistence(timeout: 5), "Chat row element found for context menu")

        cell.press(forDuration: 1.5)
        save("02_context_menu")

        let renameBtn = app.buttons["Rename"].firstMatch
        let deleteBtn = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Delete'")).firstMatch
        XCTAssertTrue(
            renameBtn.waitForExistence(timeout: 3) || deleteBtn.waitForExistence(timeout: 1),
            "Context menu items visible")
        save("02_context_menu_visible")

        if app.buttons["Cancel"].waitForExistence(timeout: 1) {
            app.buttons["Cancel"].tap()
        } else {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.95)).tap()
        }
        save("02_context_dismissed")
    }

    // MARK: - Section 3: Projects

    func test_UAT_02_NewProject() throws {
        let nav = app.navigationBars["Hermes"]
        let projBtn = findButton(nav, names: ["folder.badge.plus", "New Project"])
        XCTAssertTrue(projBtn.exists, "New project button exists")
        projBtn.tap()
        save("02_new_project_sheet")

        let newProjNav = app.navigationBars["New Project"]
        let appeared = newProjNav.waitForExistence(timeout: 3)
        XCTAssertTrue(appeared, "New project sheet appears")

        // Create button disabled without a name
        let createBtn = app.buttons["Create"]
        if createBtn.waitForExistence(timeout: 2) {
            XCTAssertFalse(createBtn.isEnabled, "Create disabled without name entered")
        }
        save("02_new_project_create_disabled")

        // Enter a project name
        let nameField = app.textFields.firstMatch
        if nameField.waitForExistence(timeout: 2) {
            nameField.tap()
            nameField.typeText("My Project")
        }
        save("02_new_project_name_entered")

        if createBtn.waitForExistence(timeout: 2) {
            XCTAssertTrue(createBtn.isEnabled, "Create enabled after name entered")
        }

        let cancel = app.buttons["Cancel"]
        if cancel.waitForExistence(timeout: 2) { cancel.tap() }
        save("02_new_project_dismissed")
    }

    // MARK: - Section 4: Composer & Send Button

    func test_UAT_03_ComposerElements() throws {
        let nav = app.navigationBars["Hermes"]
        let composeBtn = findButton(nav, names: ["square.and.pencil", "New Chat", "compose"])
        composeBtn.tap()
        XCTAssertTrue(waitForChat(), "Chat view appears")
        save("03_composer_view")

        let textView = app.textViews.firstMatch
        let textField = app.textFields.firstMatch
        let hasInput = textView.waitForExistence(timeout: 3) || textField.waitForExistence(timeout: 1)
        XCTAssertTrue(hasInput, "Composer text input exists")
        save("03_composer_ready")
    }

    func test_UAT_03_TypeMessage() throws {
        let nav = app.navigationBars["Hermes"]
        let composeBtn = findButton(nav, names: ["square.and.pencil", "New Chat", "compose"])
        composeBtn.tap()
        XCTAssertTrue(waitForChat(), "Chat view appears")

        let textView = app.textViews.firstMatch
        let textField = app.textFields.firstMatch

        if textView.waitForExistence(timeout: 3) {
            textView.tap()
            textView.typeText("Hello, Hermes!")
            save("03_message_typed")
        } else if textField.waitForExistence(timeout: 1) {
            textField.tap()
            textField.typeText("Hello, Hermes!")
            save("03_message_typed_field")
        } else {
            XCTFail("No composer input found")
        }
    }

    func test_UAT_04_SendButtonState() throws {
        let nav = app.navigationBars["Hermes"]
        let composeBtn = findButton(nav, names: ["square.and.pencil", "New Chat", "compose"])
        composeBtn.tap()
        XCTAssertTrue(waitForChat(), "Chat view appears")
        save("04_chat_open_empty")

        // Send button should be disabled (or absent) when composer is empty
        let sendBtn = app.buttons["arrow.up.circle.fill"].firstMatch
        if sendBtn.waitForExistence(timeout: 2) {
            XCTAssertFalse(sendBtn.isEnabled, "Send button disabled when composer is empty")
        }
        save("04_send_disabled_empty")

        // Type a message
        let textField = app.textFields.firstMatch
        let textView = app.textViews.firstMatch
        if textField.waitForExistence(timeout: 2) {
            textField.tap()
            textField.typeText("Hello!")
        } else if textView.waitForExistence(timeout: 2) {
            textView.tap()
            textView.typeText("Hello!")
        }
        save("04_text_entered")

        // Send button should now be present and enabled
        XCTAssertTrue(sendBtn.waitForExistence(timeout: 3), "Send button visible with text")
        XCTAssertTrue(sendBtn.isEnabled, "Send button enabled with text")
        save("04_send_enabled")
    }

    func test_UAT_03_PhotoPickerButton() throws {
        let nav = app.navigationBars["Hermes"]
        let composeBtn = findButton(nav, names: ["square.and.pencil", "New Chat", "compose"])
        composeBtn.tap()
        XCTAssertTrue(waitForChat(), "Chat view appears")

        // Photo button — try SF symbol names and label fragments
        let photoBtn = app.buttons.matching(
            NSPredicate(format: "label CONTAINS 'photo' OR label CONTAINS 'Photo' OR label CONTAINS 'image'")
        ).firstMatch
        XCTAssertTrue(photoBtn.waitForExistence(timeout: 3), "Photo picker button exists in composer")
        save("03_photo_button_exists")

        photoBtn.tap()
        save("03_photo_picker_tap")

        // Picker sheet should appear
        let pickerSheet = app.sheets.firstMatch
        let pickerNav = app.navigationBars.matching(
            NSPredicate(format: "NOT (identifier == 'Hermes') AND NOT (identifier == 'New Chat')")
        ).firstMatch
        let appeared = pickerSheet.waitForExistence(timeout: 4) || pickerNav.waitForExistence(timeout: 3)
        XCTAssertTrue(appeared, "Photo picker appeared")
        save("03_photo_picker_sheet")

        let cancel = app.buttons["Cancel"].firstMatch
        if cancel.waitForExistence(timeout: 2) { cancel.tap() }
        save("03_photo_picker_dismissed")
    }

    // MARK: - Section 5: Settings (main sheet)

    func test_UAT_05_SettingsSheet() throws {
        let nav = app.navigationBars["Hermes"]
        let gearBtn = findButton(nav, names: ["gearshape", "Settings"])
        XCTAssertTrue(gearBtn.exists, "Gear button exists")
        gearBtn.tap()
        save("05_settings_opening")

        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 4), "Settings sheet opens")
        save("05_settings_open")

        let connectionLabel = app.staticTexts["Connection"]
        let modelLabel = app.staticTexts["AI Model"]
        XCTAssertTrue(connectionLabel.exists || modelLabel.exists, "Settings content visible")

        let done = app.buttons["Done"]
        if done.waitForExistence(timeout: 2) { done.tap() }
        XCTAssertTrue(app.navigationBars["Hermes"].waitForExistence(timeout: 3), "Returns to sidebar")
        save("05_settings_dismissed")
    }

    // MARK: - Section 9: Settings Sub-Screens

    func test_UAT_09_SettingsConnection() throws {
        openSettings()

        let row = app.staticTexts["Connection"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 3), "Connection row visible")
        row.tap()
        save("09_connection_open")

        // URL field should be pre-filled from launch args
        let urlField = app.textFields.firstMatch
        XCTAssertTrue(urlField.waitForExistence(timeout: 4), "Server URL field visible")
        let urlValue = urlField.value as? String ?? ""
        XCTAssertTrue(urlValue.contains("127.0.0.1") || urlValue.contains("3001"),
                      "Server URL pre-filled: \(urlValue)")
        save("09_connection_fields")

        // Test Connection button
        let testBtn = app.buttons.matching(
            NSPredicate(format: "label CONTAINS 'Test'")).firstMatch
        if testBtn.waitForExistence(timeout: 2) {
            testBtn.tap()
            save("09_connection_test_tapped")
            let statusText = app.staticTexts.matching(
                NSPredicate(format: "label CONTAINS 'Connected' OR label CONTAINS 'connected' OR label CONTAINS '✓'")
            ).firstMatch
            _ = statusText.waitForExistence(timeout: 5)
            save("09_connection_test_result")
        }

        goBackToSettings()
        dismissSettings()
        save("09_connection_done")
    }

    func test_UAT_09_SettingsAIModel() throws {
        openSettings()

        let row = app.staticTexts["AI Model"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 3), "AI Model row visible")
        row.tap()
        save("09_ai_model_open")

        // Should show model picker or system prompt controls.
        let content = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS 'Model' OR label CONTAINS 'System' OR label CONTAINS 'Context'")
        ).firstMatch
        XCTAssertTrue(content.waitForExistence(timeout: 4), "AI Model settings content visible")
        save("09_ai_model_content")

        goBackToSettings()
        dismissSettings()
        save("09_ai_model_done")
    }

    func test_UAT_09_SettingsVoice() throws {
        openSettings()

        let row = app.staticTexts["Voice"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 3), "Voice row visible")
        row.tap()
        save("09_voice_open")

        let content = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS 'Voice' OR label CONTAINS 'TTS' OR label CONTAINS 'Engine' OR label CONTAINS 'Auto' OR label CONTAINS 'Speech'")
        ).firstMatch
        XCTAssertTrue(content.waitForExistence(timeout: 4), "Voice settings content visible")
        save("09_voice_content")

        goBackToSettings()
        dismissSettings()
        save("09_voice_done")
    }

    func test_UAT_09_SettingsAppearance() throws {
        openSettings()

        let row = app.staticTexts["Appearance"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 3), "Appearance row visible")
        row.tap()
        save("09_appearance_open")

        let content = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS 'Font' OR label CONTAINS 'Size' OR label CONTAINS 'Density' OR label CONTAINS 'Message'")
        ).firstMatch
        XCTAssertTrue(content.waitForExistence(timeout: 4), "Appearance settings content visible")
        save("09_appearance_content")

        goBackToSettings()
        dismissSettings()
        save("09_appearance_done")
    }

    func test_UAT_09_SettingsTools() throws {
        openSettings()

        let row = app.staticTexts["Tools"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 3), "Tools row visible")
        row.tap()
        save("09_tools_open")

        // Mock returns empty tools list — expect "No tools" message or empty list
        let content = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS 'tool' OR label CONTAINS 'Tool' OR label CONTAINS 'No' OR label CONTAINS 'empty'")
        ).firstMatch
        XCTAssertTrue(content.waitForExistence(timeout: 4), "Tools settings content visible")
        save("09_tools_content")

        goBackToSettings()
        dismissSettings()
        save("09_tools_done")
    }

    func test_UAT_09_SettingsMemory() throws {
        openSettings()

        let row = app.staticTexts["Memory"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 3), "Memory row visible")
        row.tap()
        save("09_memory_open")

        let content = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS 'USER' OR label CONTAINS 'MEMORY' OR label CONTAINS 'Memory' OR label CONTAINS 'Save'")
        ).firstMatch
        XCTAssertTrue(content.waitForExistence(timeout: 4), "Memory settings content visible")
        save("09_memory_content")

        goBackToSettings()
        dismissSettings()
        save("09_memory_done")
    }

    // MARK: - Section 11: Export

    func test_UAT_11_ExportMenu() throws {
        // Open a new chat
        let nav = app.navigationBars["Hermes"]
        let composeBtn = findButton(nav, names: ["square.and.pencil", "New Chat", "compose"])
        composeBtn.tap()
        XCTAssertTrue(waitForChat(), "Chat view appears")
        save("11_chat_open")

        // Find the ellipsis/more button in the chat nav bar
        let chatNavBtns = app.navigationBars.buttons
        let ellipsisBtn = findButton(app.navigationBars.element(boundBy: 0),
                                     names: ["ellipsis", "ellipsis.circle", "More", "..."])
        // Fallback: the rightmost nav bar button (index 1, since index 0 is back)
        let fallbackBtn = chatNavBtns.element(boundBy: chatNavBtns.count > 1 ? 1 : 0)

        let menuBtn = ellipsisBtn.waitForExistence(timeout: 3) ? ellipsisBtn : fallbackBtn
        guard menuBtn.exists else {
            save("11_no_more_button")
            XCTFail("More/ellipsis button not found in chat navigation bar")
            return
        }

        menuBtn.tap()
        save("11_more_menu_open")

        let exportBtn = app.buttons.matching(
            NSPredicate(format: "label CONTAINS 'Export' OR label CONTAINS 'Markdown' OR label CONTAINS 'JSON'")
        ).firstMatch
        XCTAssertTrue(exportBtn.waitForExistence(timeout: 3), "Export option visible in menu")
        save("11_export_options_visible")

        // Dismiss menu
        if app.buttons["Cancel"].waitForExistence(timeout: 1) {
            app.buttons["Cancel"].tap()
        } else {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.15)).tap()
        }
        save("11_export_menu_dismissed")
    }

    // MARK: - Helpers

    private func findButton(_ parent: XCUIElement, names: [String]) -> XCUIElement {
        for name in names {
            let btn = parent.buttons[name]
            if btn.exists { return btn }
        }
        return parent.buttons.firstMatch
    }

    private func waitForChat() -> Bool {
        let textView = app.textViews.firstMatch
        let chatNav = app.navigationBars.matching(
            NSPredicate(format: "NOT (identifier == 'Hermes')")
        ).firstMatch
        let emptyState = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS 'New Chat' OR label CONTAINS 'message' OR label CONTAINS 'Hello'")
        ).firstMatch

        return textView.waitForExistence(timeout: 5)
            || chatNav.waitForExistence(timeout: 3)
            || emptyState.waitForExistence(timeout: 2)
    }

    private func openSettings() {
        let nav = app.navigationBars["Hermes"]
        XCTAssertTrue(nav.waitForExistence(timeout: 5), "Hermes sidebar visible before opening settings")
        let gearBtn = findButton(nav, names: ["gearshape", "Settings"])
        gearBtn.tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5), "Settings sheet opened")
    }

    private func goBackToSettings() {
        // Back button in the sub-screen nav bar is labeled "Settings"
        let backBtn = app.navigationBars.buttons.matching(
            NSPredicate(format: "label == 'Settings'")).firstMatch
        if backBtn.waitForExistence(timeout: 2) {
            backBtn.tap()
        } else {
            app.navigationBars.buttons.firstMatch.tap()
        }
        _ = app.navigationBars["Settings"].waitForExistence(timeout: 3)
    }

    private func dismissSettings() {
        let done = app.buttons["Done"].firstMatch
        if done.waitForExistence(timeout: 2) { done.tap() }
        _ = app.navigationBars["Hermes"].waitForExistence(timeout: 3)
    }

    private func ensureChatInSidebar() throws {
        let nav = app.navigationBars["Hermes"]
        XCTAssertTrue(nav.waitForExistence(timeout: 5), "Hermes sidebar visible")

        let cell = findFirstChatCell()
        if !cell.waitForExistence(timeout: 2) {
            // No chats yet — create one via compose then go back
            let composeBtn = findButton(nav, names: ["square.and.pencil", "New Chat", "compose"])
            composeBtn.tap()
            _ = waitForChat()
            let backBtn = app.navigationBars.buttons.firstMatch
            if backBtn.waitForExistence(timeout: 2) { backBtn.tap() }
            XCTAssertTrue(nav.waitForExistence(timeout: 5), "Back at sidebar after creating chat")
        }
    }

    /// Returns the best swipe/press target for a "New Chat" row.
    /// SwiftUI List(.sidebar) uses UICollectionView in iOS 16+; falls back to raw static text.
    private func chatRowElement() -> XCUIElement {
        let cv = app.collectionViews.cells.containing(.staticText, identifier: "New Chat").firstMatch
        if cv.exists { return cv }
        let tv = app.tables.cells.containing(.staticText, identifier: "New Chat").firstMatch
        if tv.exists { return tv }
        return app.staticTexts.matching(NSPredicate(format: "label == 'New Chat'")).firstMatch
    }

    private func findFirstChatCell() -> XCUIElement {
        // Prefer collection view (iOS 16+ SwiftUI List internals), then table, then text
        let cv = app.collectionViews.cells.firstMatch
        if cv.exists { return cv }
        let tv = app.tables.cells.firstMatch
        if tv.exists { return tv }
        return app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Chat'")).firstMatch
    }

    private func save(_ name: String) {
        let shot = app.screenshot()
        if let data = shot.pngRepresentation as Data? {
            let path = "\(screenshotDir)/\(name).png"
            try? data.write(to: URL(fileURLWithPath: path))
        }
        let att = XCTAttachment(screenshot: shot)
        att.name = name
        att.lifetime = .keepAlways
        add(att)
    }
}
