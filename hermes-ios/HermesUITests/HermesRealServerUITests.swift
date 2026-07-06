import XCTest

// Tests that require a live Hermes server. Run separately from the mock-server suite.
// Server: http://host:3001 (reachable from the simulator or device)
final class HermesRealServerUITests: XCTestCase {

    var app: XCUIApplication!
    // Use loopback so URLSession SSE streams close cleanly; some VPN links add enough latency to hang asyncBytes.lines.
    // Defaults to the local mock on 3001. Point at a live Hermes server by
    // setting HERMES_REAL_SERVER_URL and HERMES_REAL_SERVER_API_KEY.
    private static let environment = ProcessInfo.processInfo.environment
    static let serverURL = environment["HERMES_REAL_SERVER_URL"] ?? "http://127.0.0.1:3001"
    static let apiKey    = environment["HERMES_REAL_SERVER_API_KEY"] ?? ""
    static let isLocalServer = serverURL.contains("127.0.0.1") || serverURL.contains("localhost")
    let screenshotDir    = "/tmp/uat_screenshots_real"

    override func setUpWithError() throws {
        continueAfterFailure = false
        try XCTSkipIf(!Self.isLocalServer && Self.apiKey.isEmpty,
                      "Set HERMES_REAL_SERVER_API_KEY for live-server UI tests")
        try FileManager.default.createDirectory(atPath: screenshotDir, withIntermediateDirectories: true)
        app = XCUIApplication()
        app.launchArguments = ["-hermes.serverURL", Self.serverURL,
                               "-hermes.apiKey",    Self.apiKey]
        app.launch()
        XCTAssertTrue(app.navigationBars["Hermes"].waitForExistence(timeout: 15),
                      "Sidebar must appear within 15s — is the server reachable?")
    }

    override func tearDownWithError() throws {
        app.terminate()
    }

    // MARK: - UAT 1.1 — Connection Setup Screen (typed credentials)

    /// Re-launches with no credentials so ConnectionSetupView appears, then types in real values.
    func test_UAT_01_ConnectionSetupFlow() throws {
        app.terminate()
        app.launchArguments = ["-hermes.serverURL", "", "-hermes.apiKey", ""]
        app.launch()
        save("01_setup_launched")

        // Connect button and URL field should be visible
        let urlField = app.textFields.firstMatch
        XCTAssertTrue(urlField.waitForExistence(timeout: 8), "URL text field appears")
        let connectBtn = app.buttons.matching(
            NSPredicate(format: "label == 'Connect'")).firstMatch
        XCTAssertTrue(connectBtn.waitForExistence(timeout: 3), "Connect button visible")

        // 1.1.3 — Connect disabled before URL is entered
        XCTAssertFalse(connectBtn.isEnabled, "Connect disabled without URL (UAT 1.1.3)")
        save("01_connect_disabled")

        // Enter server URL
        urlField.tap()
        urlField.typeText(Self.serverURL)
        save("01_url_typed")

        // Connect should enable once URL is non-empty
        XCTAssertTrue(connectBtn.isEnabled, "Connect enabled after URL entry")

        // Enter API key in the secure field
        let keyField = app.secureTextFields.firstMatch
        if !Self.apiKey.isEmpty, keyField.waitForExistence(timeout: 2) {
            keyField.tap()
            keyField.typeText(Self.apiKey)
            save("01_apikey_typed")
        }

        // 1.1.6 — Tap Connect, spinner appears, then sidebar
        connectBtn.tap()
        save("01_connecting")

        XCTAssertTrue(app.navigationBars["Hermes"].waitForExistence(timeout: 20),
                      "Sidebar appears after successful connection (UAT 1.1.6)")
        save("01_connected_sidebar")
    }

    // MARK: - UAT 1.2 — Returning User

    func test_UAT_01_ReturningUser_ChatsLoaded() throws {
        // Real chats should load from server
        let chatCell = app.collectionViews.cells.firstMatch
        XCTAssertTrue(chatCell.waitForExistence(timeout: 10), "Chats loaded from real server")
        save("01_returning_user_chats_loaded")
    }

    // MARK: - UAT 4.1 / 4.2 — Send Message & Streaming Response

    func test_UAT_04_SendAndStream() throws {
        openNewChat()
        save("04_new_chat")

        let field = composerField()
        XCTAssertTrue(field.waitForExistence(timeout: 5), "Composer found")
        field.tap()
        field.typeText("Reply with exactly the word: PONG")
        save("04_message_typed")

        let sendBtn = app.buttons["arrow.up.circle.fill"].firstMatch
        XCTAssertTrue(sendBtn.waitForExistence(timeout: 3) && sendBtn.isEnabled, "Send enabled")
        sendBtn.tap()
        save("04_sent")

        // User bubble appears
        let userMsg = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS 'PONG'")).firstMatch
        XCTAssertTrue(userMsg.waitForExistence(timeout: 8), "User message bubble appeared")
        save("04_user_bubble")

        // Wait for streaming to complete
        waitForStreamingToFinish()
        save("04_stream_complete")

        // AI response should contain "PONG"
        let aiReply = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS[c] 'pong'")).firstMatch
        XCTAssertTrue(aiReply.waitForExistence(timeout: 5), "AI response contains PONG")
        save("04_response_received")
    }

    // MARK: - UAT 4.3 — Markdown: Code Block

    func test_UAT_04_MarkdownCodeBlock() throws {
        openNewChat()

        let field = composerField()
        XCTAssertTrue(field.waitForExistence(timeout: 5), "Composer found")
        field.tap()
        field.typeText("Show a Python hello world in a fenced code block. Be brief, one block only.")
        app.buttons["arrow.up.circle.fill"].firstMatch.tap()
        save("04_code_request_sent")

        waitForStreamingToFinish()
        save("04_code_response_done")

        // Code block should be visible. The language label ("python") is a StaticText;
        // the highlighted code body is a UITextView (value property, not label).
        let codeLang = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS 'python'")).firstMatch
        let codeBody = app.textViews.matching(
            NSPredicate(format: "value CONTAINS 'print' OR value CONTAINS 'Hello, World'")).firstMatch
        XCTAssertTrue(
            codeLang.waitForExistence(timeout: 8) || codeBody.waitForExistence(timeout: 1),
            "Code block content rendered")
        save("04_code_block_visible")
    }

    // MARK: - UAT 4.4 — Copy Code Block

    func test_UAT_04_CopyCodeBlock() throws {
        openNewChat()

        let field = composerField()
        XCTAssertTrue(field.waitForExistence(timeout: 5), "Composer found")
        field.tap()
        field.typeText("Give me exactly this python snippet in a code block: print('hi')")
        app.buttons["arrow.up.circle.fill"].firstMatch.tap()
        save("04_copy_request_sent")

        waitForStreamingToFinish()
        save("04_copy_response_done")

        // Find and tap the copy button on the code block
        let copyBtn = app.buttons.matching(
            NSPredicate(format: "label CONTAINS 'copy' OR label CONTAINS 'Copy'")).firstMatch
        if copyBtn.waitForExistence(timeout: 5) {
            copyBtn.tap()
            save("04_copy_tapped")
            // Checkmark should flash briefly
            let check = app.images.matching(
                NSPredicate(format: "label CONTAINS 'checkmark'")).firstMatch
            _ = check.waitForExistence(timeout: 2)
            save("04_copy_checkmark")
        } else {
            save("04_no_copy_button")
            XCTAssertTrue(copyBtn.exists, "Copy button visible on code block")
        }
    }

    // MARK: - UAT 4.5 — Message Branching

    func test_UAT_04_MessageBranching() throws {
        openNewChat()

        // Send first message
        let field = composerField()
        XCTAssertTrue(field.waitForExistence(timeout: 5), "Composer found")
        field.tap()
        field.typeText("Say ALPHA and nothing else")
        app.buttons["arrow.up.circle.fill"].firstMatch.tap()
        save("04_branch_first_sent")

        let userMsg = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS 'ALPHA'")).firstMatch
        XCTAssertTrue(userMsg.waitForExistence(timeout: 8), "First user message bubble")
        waitForStreamingToFinish()
        save("04_branch_first_response")

        // Long press the user message bubble to get Edit option
        userMsg.press(forDuration: 1.2)
        save("04_branch_context_menu")

        let editBtn = app.buttons["Edit"].firstMatch
        XCTAssertTrue(editBtn.waitForExistence(timeout: 4), "Edit option in context menu")
        editBtn.tap()
        save("04_branch_edit_mode")

        // Edit field should appear pre-filled with the original message.
        // Find it by its content value; the TextField(axis:.vertical) may appear
        // as a textView in XCTest on iOS 17+ rather than as a textField.
        let editField: XCUIElement
        let tfByVal = app.textFields.matching(
            NSPredicate(format: "value CONTAINS 'ALPHA'")).firstMatch
        let tvByVal = app.textViews.matching(
            NSPredicate(format: "value CONTAINS 'ALPHA'")).firstMatch
        if tfByVal.waitForExistence(timeout: 4) {
            editField = tfByVal
        } else if tvByVal.waitForExistence(timeout: 2) {
            editField = tvByVal
        } else {
            XCTFail("Edit field did not appear with ALPHA content")
            return
        }
        save("04_branch_edit_mode_found")
        editField.tap()
        editField.selectAllText()
        editField.typeText("Say BETA and nothing else")
        save("04_branch_retyped")

        // Tap the Send button inside the edit bubble (text button, not composer's arrow)
        let sendBtn = app.buttons["Send"].firstMatch
        XCTAssertTrue(sendBtn.waitForExistence(timeout: 3), "Send button for edit visible")
        sendBtn.tap()
        save("04_branch_edit_sent")

        waitForStreamingToFinish()
        save("04_branch_second_response")

        // Branch navigation arrows should appear. The nav row shows "2 / 2" text
        // and chevron buttons whose accessibility labels match the SF symbol name.
        let branchArrow = app.buttons.matching(
            NSPredicate(format: "label CONTAINS 'chevron.left' OR label CONTAINS 'chevron.right'")
        ).firstMatch
        let branchText = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS ' / '")).firstMatch
        let branchVisible = branchArrow.waitForExistence(timeout: 5) || branchText.waitForExistence(timeout: 1)
        XCTAssertTrue(branchVisible, "Branch navigation visible")
        save("04_branch_nav_visible")
    }

    // MARK: - UAT 9.2 — AI Model Settings with Real Models

    func test_UAT_09_RealModelPicker() throws {
        let nav = app.navigationBars["Hermes"]
        findButton(nav, names: ["gearshape", "Settings"]).tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        app.staticTexts["AI Model"].firstMatch.tap()
        save("09_real_ai_model_open")

        // Real server should return at least one model, without assuming a
        // particular provider or model family.
        let emptyState = app.staticTexts["No models available"].firstMatch
        XCTAssertFalse(emptyState.waitForExistence(timeout: 5), "Real server returned no models")
        save("09_real_models_listed")

        goBack(); dismissSettings()
        save("09_real_model_done")
    }

    // MARK: - UAT 11 — Export Chat with Real Messages

    func test_UAT_11_ExportRealChat() throws {
        // UAT 11: Export a chat as Markdown.
        // Open a new chat, send a message, then use the … menu to export.
        // (Sidebar List(selection:) taps are unreliable in XCTest on iOS 26 NavigationSplitView;
        //  creating a new chat via button is the stable path.)
        openNewChat()
        save("11_chat_opened")

        let field = composerField()
        XCTAssertTrue(field.waitForExistence(timeout: 5), "Composer found")
        field.tap()
        field.typeText("Hello, export test message")
        app.buttons["arrow.up.circle.fill"].firstMatch.tap()
        save("11_message_sent")

        waitForStreamingToFinish()
        save("11_chat_with_messages")

        // Tap … (ellipsis) menu in the chat nav bar
        let chatNavBar = app.navigationBars.matching(
            NSPredicate(format: "NOT (identifier == 'Hermes')")).firstMatch
        XCTAssertTrue(chatNavBar.waitForExistence(timeout: 5), "Chat nav bar visible")
        let ellipsis = findButton(chatNavBar,
                                  names: ["ellipsis", "ellipsis.circle", "More", "..."])
        XCTAssertTrue(ellipsis.waitForExistence(timeout: 3), "Ellipsis button")
        ellipsis.tap()
        save("11_more_menu")

        let exportMd = app.buttons.matching(
            NSPredicate(format: "label CONTAINS 'Export' OR label CONTAINS 'Markdown'")).firstMatch
        XCTAssertTrue(exportMd.waitForExistence(timeout: 3), "Export Markdown option")
        exportMd.tap()
        save("11_export_sheet_open")

        // Export sheet: share button should be present
        let shareBtn = app.buttons.matching(
            NSPredicate(format: "label CONTAINS 'Share' OR label CONTAINS 'share'")).firstMatch
        _ = shareBtn.waitForExistence(timeout: 5)
        save("11_export_content")

        // Dismiss
        let done = app.buttons["Done"].firstMatch
        if done.waitForExistence(timeout: 2) { done.tap() }
        else if app.buttons["Cancel"].firstMatch.waitForExistence(timeout: 2) {
            app.buttons["Cancel"].firstMatch.tap()
        }
        save("11_export_done")
    }

    // MARK: - Helpers

    private func openNewChat() {
        let nav = app.navigationBars["Hermes"]
        XCTAssertTrue(nav.waitForExistence(timeout: 5))
        findButton(nav, names: ["square.and.pencil", "New Chat"]).tap()
        XCTAssertTrue(waitForChatView(), "Chat view appeared")
    }

    private func composerField() -> XCUIElement {
        let tf = app.textFields.firstMatch
        return tf.exists ? tf : app.textViews.firstMatch
    }

    private func waitForChatView() -> Bool {
        // On iPhone + NavigationSplitView the chat nav bar title != "Hermes"
        let chatNav = app.navigationBars.matching(
            NSPredicate(format: "NOT (identifier == 'Hermes')")).firstMatch
        if chatNav.waitForExistence(timeout: 8) { return true }
        // Fallback 1: composer text field or text view appeared
        if app.textFields.firstMatch.waitForExistence(timeout: 2) { return true }
        // Fallback 2: the chat-specific ellipsis menu button
        let ellipsis = app.buttons.matching(
            NSPredicate(format: "label CONTAINS 'ellipsis'")).firstMatch
        return ellipsis.waitForExistence(timeout: 2)
    }

    /// Waits until the streaming stop button appears and then disappears (or skips if response was instant).
    private func waitForStreamingToFinish(timeout: TimeInterval = 90) {
        let stopBtn = app.buttons.matching(
            NSPredicate(format: "label CONTAINS 'Stop' OR label CONTAINS 'stop'")).firstMatch
        if stopBtn.waitForExistence(timeout: 12) {
            let gone = NSPredicate(format: "exists == false")
            let exp = XCTNSPredicateExpectation(predicate: gone, object: stopBtn)
            wait(for: [exp], timeout: timeout)
        }
        // Brief settle time for final render
        _ = XCTWaiter().wait(for: [XCTestExpectation()], timeout: 1)
    }

    private func findButton(_ parent: XCUIElement, names: [String]) -> XCUIElement {
        for name in names {
            let btn = parent.buttons[name]
            if btn.exists { return btn }
        }
        return parent.buttons.firstMatch
    }

    private func goBack() {
        let backBtn = app.navigationBars.buttons.matching(
            NSPredicate(format: "label == 'Settings'")).firstMatch
        if backBtn.waitForExistence(timeout: 2) { backBtn.tap() }
        else { app.navigationBars.buttons.firstMatch.tap() }
        _ = app.navigationBars["Settings"].waitForExistence(timeout: 3)
    }

    private func dismissSettings() {
        let done = app.buttons["Done"].firstMatch
        if done.waitForExistence(timeout: 2) { done.tap() }
        _ = app.navigationBars["Hermes"].waitForExistence(timeout: 3)
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

    // MARK: - Real memory (decode fix)
    // The server returns user_md/memory_md as strings alongside a nested
    // `limits` dict. getMemory used to decode the whole object as
    // [String:String], which threw on `limits`, leaving the screen blank.
    func test_UAT_09_RealMemoryLoads() throws {
        // Only meaningful against a live Hermes server; the mock returns empty
        // memory. Point serverURL at a real host to exercise this.
        try XCTSkipIf(Self.isLocalServer,
                      "Real-server memory test — set serverURL to a live Hermes server")
        let gear = app.buttons.matching(
            NSPredicate(format: "label CONTAINS[c] 'gear' OR label CONTAINS[c] 'settings'")).firstMatch
        XCTAssertTrue(gear.waitForExistence(timeout: 8), "Settings gear visible")
        gear.tap()

        let memRow = app.staticTexts["Memory"].firstMatch
        XCTAssertTrue(memRow.waitForExistence(timeout: 5), "Memory row visible")
        memRow.tap()
        save("09_real_memory_open")

        let userHeader = app.staticTexts["USER.md"].firstMatch
        let memoryHeader = app.staticTexts["MEMORY.md"].firstMatch
        let appeared = userHeader.waitForExistence(timeout: 8) && memoryHeader.waitForExistence(timeout: 2)
        save("09_real_memory_content")
        XCTAssertTrue(appeared, "Memory editor rendered after loading real server payload")
    }

    // MARK: - Real tools catalog (populated from Hermes inventory)
    func test_UAT_10_RealToolsCatalog() throws {
        try XCTSkipIf(Self.isLocalServer,
                      "Real-server tools test — set serverURL to a live Hermes server")
        let gear = app.buttons.matching(
            NSPredicate(format: "label CONTAINS[c] 'gear' OR label CONTAINS[c] 'settings'")).firstMatch
        XCTAssertTrue(gear.waitForExistence(timeout: 8), "Settings gear visible")
        gear.tap()

        let toolsRow = app.staticTexts["Tools"].firstMatch
        XCTAssertTrue(toolsRow.waitForExistence(timeout: 5), "Tools row visible")
        toolsRow.tap()
        save("10_real_tools_open")

        // Known toolset labels from the live catalog should render.
        let pred = NSPredicate(format: "label CONTAINS 'Web Search' OR label CONTAINS 'Browser' OR label CONTAINS 'Terminal' OR label CONTAINS 'Memory'")
        let row = app.staticTexts.matching(pred).firstMatch
        let appeared = row.waitForExistence(timeout: 8)
        save("10_real_tools_catalog")
        XCTAssertTrue(appeared, "Toolset catalog must populate from the Hermes inventory")
    }





    func test_UAT_10_PerChatToolOverride() throws {
        try XCTSkipIf(Self.isLocalServer,
                      "Real-server test — set serverURL to a live Hermes server")
        openNewChat()
        save("10_override_new_chat")

        // Open the chat menu → Tools for this chat. The Menu's SF-symbol label
        // is auto-labelled (often "More"/"ellipsis.circle"); fall back to the
        // trailing nav-bar button.
        var ellipsis = app.buttons.matching(
            NSPredicate(format: "label CONTAINS[c] 'ellipsis' OR label CONTAINS[c] 'more'")).firstMatch
        if !ellipsis.waitForExistence(timeout: 5) {
            let navButtons = app.navigationBars.buttons
            ellipsis = navButtons.element(boundBy: navButtons.count - 1)
        }
        XCTAssertTrue(ellipsis.waitForExistence(timeout: 3), "Chat menu visible")
        ellipsis.tap()
        let toolsItem = app.buttons.matching(
            NSPredicate(format: "label CONTAINS 'Tools'")).firstMatch
        XCTAssertTrue(toolsItem.waitForExistence(timeout: 3), "Tools menu item visible")
        toolsItem.tap()
        save("10_override_sheet")

        // Turn on the per-chat override, enable a distinctive toolset (Terminal)
        let overrideToggle = app.switches.matching(
            NSPredicate(format: "label CONTAINS 'chat-specific'")).firstMatch
        XCTAssertTrue(overrideToggle.waitForExistence(timeout: 4), "Override toggle visible")
        overrideToggle.tap()
        // SwiftUI Toggle taps sometimes land on the label; retry on the switch's
        // trailing edge until the value flips on.
        if (overrideToggle.value as? String) != "1" {
            overrideToggle.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        }
        XCTAssertEqual(overrideToggle.value as? String, "1", "Override must turn on")

        let terminalToggle = app.switches.matching(
            NSPredicate(format: "label CONTAINS 'Terminal'")).firstMatch
        XCTAssertTrue(terminalToggle.waitForExistence(timeout: 4),
                      "Toolset list must appear when override is on")
        terminalToggle.tap()
        if (terminalToggle.value as? String) != "1" {
            terminalToggle.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        }
        save("10_override_configured")
        app.buttons["Save"].firstMatch.tap()

        // Send a message — the run should carry enabled_toolsets
        let field = composerField()
        XCTAssertTrue(field.waitForExistence(timeout: 5), "Composer found")
        field.tap()
        field.typeText("hello")
        app.buttons["arrow.up.circle.fill"].firstMatch.tap()
        save("10_override_sent")
        waitForStreamingToFinish()
        save("10_override_done")
    }

    // MARK: - Tool spinner clears on completion
    func test_UAT_04_ToolSpinnerClears() throws {
        try XCTSkipIf(Self.isLocalServer,
                      "Real-server test — set serverURL to a live Hermes server")
        openNewChat()
        let field = composerField()
        XCTAssertTrue(field.waitForExistence(timeout: 5), "Composer found")
        field.tap()
        field.typeText("Search the web for the current population of Tokyo and tell me the number.")
        app.buttons["arrow.up.circle.fill"].firstMatch.tap()
        save("04_tool_sent")

        // A tool timeline should appear ("N tool(s) used")
        let timeline = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS 'tool' AND label CONTAINS 'used'")).firstMatch
        XCTAssertTrue(timeline.waitForExistence(timeout: 30), "Tool timeline appears")
        save("04_tool_running")

        waitForStreamingToFinish()
        // Let the final render settle, then confirm no spinner remains anywhere.
        _ = XCTWaiter().wait(for: [XCTestExpectation()], timeout: 2)
        save("04_tool_done")
        XCTAssertEqual(app.activityIndicators.count, 0,
                       "No progress spinner should remain after the run completes")
    }
}

extension XCUIElement {
    func selectAllText() {
        tap()
        // Triple-tap selects all in most text fields
        tap(withNumberOfTaps: 3, numberOfTouches: 1)
        let menu = XCUIApplication().menuItems["Select All"]
        if menu.waitForExistence(timeout: 1) { menu.tap() }
    }
}
