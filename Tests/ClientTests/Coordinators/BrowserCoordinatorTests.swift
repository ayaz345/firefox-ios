// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import Common
import XCTest
import WebKit
@testable import Client

final class BrowserCoordinatorTests: XCTestCase {
    private var mockRouter: MockRouter!
    private var profile: MockProfile!
    private var overlayModeManager: MockOverlayModeManager!
    private var screenshotService: ScreenshotService!
    private var routeBuilder: RouteBuilder!
    private var tabManager: MockTabManager!
    private var applicationHelper: MockApplicationHelper!
    private var glean: MockGleanWrapper!
    private var wallpaperManager: WallpaperManagerMock!

    override func setUp() {
        super.setUp()
        DependencyHelperMock().bootstrapDependencies()
        LegacyFeatureFlagsManager.shared.initializeDeveloperFeatures(with: AppContainer.shared.resolve())
        self.routeBuilder = RouteBuilder { false }
        self.mockRouter = MockRouter(navigationController: MockNavigationController())
        self.profile = MockProfile()
        self.overlayModeManager = MockOverlayModeManager()
        self.screenshotService = ScreenshotService()
        self.tabManager = MockTabManager()
        self.applicationHelper = MockApplicationHelper()
        self.glean = MockGleanWrapper()
        self.wallpaperManager = WallpaperManagerMock()
    }

    override func tearDown() {
        super.tearDown()
        self.routeBuilder = nil
        self.mockRouter = nil
        self.profile = nil
        self.overlayModeManager = nil
        self.screenshotService = nil
        self.tabManager = nil
        self.applicationHelper = nil
        self.glean = nil
        self.wallpaperManager = nil
        AppContainer.shared.reset()
    }

    func testInitialState() {
        let subject = createSubject()

        XCTAssertNotNil(subject.browserViewController)
        XCTAssertTrue(subject.childCoordinators.isEmpty)
        XCTAssertEqual(mockRouter.setRootViewControllerCalled, 0)
    }

    func testWithoutLaunchType_startsBrowserOnly() {
        let subject = createSubject()
        subject.start(with: nil)

        XCTAssertNotNil(mockRouter.pushedViewController as? BrowserViewController)
        XCTAssertEqual(mockRouter.pushCalled, 1)
        XCTAssertTrue(subject.childCoordinators.isEmpty)
    }

    func testWithLaunchType_startsLaunchCoordinator() {
        let subject = createSubject()
        subject.start(with: .defaultBrowser)

        XCTAssertNotNil(mockRouter.pushedViewController as? BrowserViewController)
        XCTAssertEqual(mockRouter.pushCalled, 1)
        XCTAssertEqual(subject.childCoordinators.count, 1)
        XCTAssertNotNil(subject.childCoordinators[0] as? LaunchCoordinator)
    }

    func testChildLaunchCoordinatorIsDone_deallocatesAndDismiss() throws {
        let subject = createSubject()
        subject.start(with: .defaultBrowser)

        let childLaunchCoordinator = try XCTUnwrap(subject.childCoordinators[0] as? LaunchCoordinator)
        subject.didFinishLaunch(from: childLaunchCoordinator)

        XCTAssertTrue(subject.childCoordinators.isEmpty)
        XCTAssertEqual(mockRouter.dismissCalled, 1)
    }

    // MARK: - Show homepage

    func testShowHomepage_addsOneHomepageOnly() {
        let subject = createSubject()
        subject.showHomepage(inline: true,
                             homepanelDelegate: subject.browserViewController,
                             libraryPanelDelegate: subject.browserViewController,
                             sendToDeviceDelegate: subject.browserViewController,
                             overlayManager: overlayModeManager)

        let secondHomepage = HomepageViewController(profile: profile, overlayManager: overlayModeManager)
        XCTAssertFalse(subject.browserViewController.contentContainer.canAdd(content: secondHomepage))
        XCTAssertNotNil(subject.homepageViewController)
        XCTAssertNil(subject.webviewController)
    }

    func testShowHomepage_reuseExistingHomepage() {
        let subject = createSubject()
        subject.showHomepage(inline: true,
                             homepanelDelegate: subject.browserViewController,
                             libraryPanelDelegate: subject.browserViewController,
                             sendToDeviceDelegate: subject.browserViewController,
                             overlayManager: overlayModeManager)
        let firstHomepage = subject.homepageViewController
        XCTAssertNotNil(subject.homepageViewController)

        subject.showHomepage(inline: true,
                             homepanelDelegate: subject.browserViewController,
                             libraryPanelDelegate: subject.browserViewController,
                             sendToDeviceDelegate: subject.browserViewController,
                             overlayManager: overlayModeManager)
        let secondHomepage = subject.homepageViewController
        XCTAssertEqual(firstHomepage, secondHomepage)
    }

    // MARK: - Show webview

    func testShowWebview_embedNewWebview() {
        let webview = WKWebView()
        let subject = createSubject()
        let mbvc = MockBrowserViewController(profile: profile, tabManager: tabManager)
        subject.browserViewController = mbvc
        subject.show(webView: webview)

        XCTAssertNil(subject.homepageViewController)
        XCTAssertNotNil(subject.webviewController)
        XCTAssertEqual(mbvc.embedContentCalled, 1)
        XCTAssertEqual(mbvc.saveEmbeddedContent?.contentType, .webview)
    }

    func testShowWebview_reuseExistingWebview() {
        let webview = WKWebView()
        let subject = createSubject()
        let mbvc = MockBrowserViewController(profile: profile, tabManager: tabManager)
        subject.browserViewController = mbvc
        subject.show(webView: webview)
        let firstWebview = subject.webviewController
        XCTAssertNotNil(firstWebview)

        subject.show(webView: webview)
        let secondWebview = subject.webviewController

        XCTAssertEqual(firstWebview, secondWebview)
        XCTAssertEqual(mbvc.embedContentCalled, 1)
        XCTAssertEqual(mbvc.frontEmbeddedContentCalled, 1)
        XCTAssertEqual(mbvc.saveEmbeddedContent?.contentType, .webview)
    }

    func testShowWebview_setsScreenshotService() {
        let webview = WKWebView()
        let subject = createSubject()
        subject.show(webView: webview)

        XCTAssertNotNil(screenshotService.screenshotableView)
    }

    // MARK: - BrowserNavigationHandler

    func testShowSettings() throws {
        let subject = createSubject()
        subject.show(settings: .general)

        XCTAssertEqual(subject.childCoordinators.count, 1)
        XCTAssertNotNil(subject.childCoordinators[0] as? SettingsCoordinator)
        let presentedVC = try XCTUnwrap(mockRouter.presentedViewController as? ThemedNavigationController)
        XCTAssertEqual(mockRouter.presentCalled, 1)
        XCTAssertTrue(presentedVC.topViewController is AppSettingsTableViewController)
    }

    // MARK: - Search route

    func testHandleSearchQuery_returnsTrue() {
        let query = "test query"
        let subject = createSubject()
        let mbvc = MockBrowserViewController(profile: profile, tabManager: tabManager)
        subject.browserViewController = mbvc
        let result = subject.handle(route: .searchQuery(query: query))
        XCTAssertTrue(result)
        XCTAssertTrue(mbvc.handleQueryCalled)
        XCTAssertEqual(mbvc.handleQuery, query)
        XCTAssertEqual(mbvc.handleQueryCount, 1)
    }

    func testHandleSearch_returnsTrue() {
        let subject = createSubject()
        let mbvc = MockBrowserViewController(profile: profile, tabManager: tabManager)
        subject.browserViewController = mbvc
        let result = subject.handle(route: .search(url: URL(string: "https://example.com")!, isPrivate: false, options: nil))
        XCTAssertTrue(result)
        XCTAssertTrue(mbvc.switchToTabForURLOrOpenCalled)
        XCTAssertEqual(mbvc.switchToTabForURLOrOpenURL, URL(string: "https://example.com")!)
        XCTAssertEqual(mbvc.switchToTabForURLOrOpenCount, 1)
    }

    func testHandleSearchWithNormalMode_returnsTrue() {
        let subject = createSubject()
        let mbvc = MockBrowserViewController(profile: profile, tabManager: tabManager)
        subject.browserViewController = mbvc
        let result = subject.handle(route: .search(url: URL(string: "https://example.com")!, isPrivate: false, options: [.switchToNormalMode]))
        XCTAssertTrue(result)
        XCTAssertTrue(mbvc.switchToPrivacyModeCalled)
        XCTAssertFalse(mbvc.switchToPrivacyModeIsPrivate)
        XCTAssertTrue(mbvc.switchToTabForURLOrOpenCalled)
        XCTAssertEqual(mbvc.switchToTabForURLOrOpenURL, URL(string: "https://example.com")!)
        XCTAssertEqual(mbvc.switchToTabForURLOrOpenCount, 1)
    }

    func testHandleSearchWithNilURL_returnsTrue() {
        let subject = createSubject()
        let mbvc = MockBrowserViewController(profile: profile, tabManager: tabManager)
        subject.browserViewController = mbvc
        let result = subject.handle(route: .search(url: nil, isPrivate: false))
        XCTAssertTrue(result)
        XCTAssertTrue(mbvc.openBlankNewTabCalled)
        XCTAssertFalse(mbvc.openBlankNewTabIsPrivate)
        XCTAssertEqual(mbvc.openBlankNewTabCount, 1)
    }

    func testHandleSearchURL_returnsTrue() {
        let subject = createSubject()
        let mbvc = MockBrowserViewController(profile: profile, tabManager: tabManager)
        subject.browserViewController = mbvc
        let result = subject.handle(route: .searchURL(url: URL(string: "https://example.com")!, tabId: "1234"))
        XCTAssertTrue(result)
        XCTAssertTrue(mbvc.switchToTabForURLOrOpenCalled)
        XCTAssertEqual(mbvc.switchToTabForURLOrOpenURL, URL(string: "https://example.com")!)
        XCTAssertEqual(mbvc.switchToTabForURLOrOpenCount, 1)
    }

    func testHandleNilSearchURL_returnsTrue() {
        let subject = createSubject()
        let mbvc = MockBrowserViewController(profile: profile, tabManager: tabManager)
        subject.browserViewController = mbvc
        let result = subject.handle(route: .searchURL(url: nil, tabId: "1234"))
        XCTAssertTrue(result)
        XCTAssertTrue(mbvc.openBlankNewTabCalled)
        XCTAssertFalse(mbvc.openBlankNewTabIsPrivate)
        XCTAssertEqual(mbvc.openBlankNewTabCount, 1)
    }

    // MARK: - Homepanel route

    func testHandleHomepanelBookmarks_returnsTrue() {
        let subject = createSubject()
        let mbvc = MockBrowserViewController(profile: profile, tabManager: tabManager)
        subject.browserViewController = mbvc
        let route = routeBuilder.makeRoute(url: URL(string: "firefox://deep-link?url=/homepanel/bookmarks")!)
        let result = subject.handle(route: route!)
        XCTAssertTrue(result)
        XCTAssertTrue(mbvc.showLibraryCalled)
        XCTAssertEqual(mbvc.showLibraryPanel, .bookmarks)
        XCTAssertEqual(mbvc.showLibraryCount, 1)
    }

    func testHandleHomepanelHistory_returnsTrue() {
        let subject = createSubject()
        let mbvc = MockBrowserViewController(profile: profile, tabManager: tabManager)
        subject.browserViewController = mbvc
        let route = routeBuilder.makeRoute(url: URL(string: "firefox://deep-link?url=/homepanel/history")!)
        let result = subject.handle(route: route!)
        XCTAssertTrue(result)
        XCTAssertTrue(mbvc.showLibraryCalled)
        XCTAssertEqual(mbvc.showLibraryPanel, .history)
        XCTAssertEqual(mbvc.showLibraryCount, 1)
    }

    func testHandleHomepanelReadingList_returnsTrue() {
        let subject = createSubject()
        let mbvc = MockBrowserViewController(profile: profile, tabManager: tabManager)
        subject.browserViewController = mbvc
        let route = routeBuilder.makeRoute(url: URL(string: "firefox://deep-link?url=/homepanel/reading-list")!)
        let result = subject.handle(route: route!)
        XCTAssertTrue(result)
        XCTAssertTrue(mbvc.showLibraryCalled)
        XCTAssertEqual(mbvc.showLibraryPanel, .readingList)
        XCTAssertEqual(mbvc.showLibraryCount, 1)
    }

    func testHandleHomepanelDownloads_returnsTrue() {
        let subject = createSubject()
        let mbvc = MockBrowserViewController(profile: profile, tabManager: tabManager)
        subject.browserViewController = mbvc
        let route = routeBuilder.makeRoute(url: URL(string: "firefox://deep-link?url=/homepanel/downloads")!)
        let result = subject.handle(route: route!)
        XCTAssertTrue(result)
        XCTAssertTrue(mbvc.showLibraryCalled)
        XCTAssertEqual(mbvc.showLibraryPanel, .downloads)
        XCTAssertEqual(mbvc.showLibraryCount, 1)
    }

    func testHandleHomepanelTopSites_returnsTrue() {
        // Given
        let topSitesURL = URL(string: "firefox://deep-link?url=/homepanel/top-sites")!
        let subject = createSubject()
        let mbvc = MockBrowserViewController(profile: profile, tabManager: tabManager)
        subject.browserViewController = mbvc

        // When
        let route = routeBuilder.makeRoute(url: topSitesURL)
        let result = subject.handle(route: route!)

        // Then
        XCTAssertTrue(result)
        XCTAssertEqual(mbvc.openURLInNewTabCount, 1)
        XCTAssertEqual(mbvc.openURLInNewTabURL, HomePanelType.topSites.internalUrl)
        XCTAssertEqual(mbvc.openURLInNewTabIsPrivate, false)
    }

    func testHandleNewPrivateTab_returnsTrue() {
        // Given
        let newPrivateTabURL = URL(string: "firefox://deep-link?url=/homepanel/new-private-tab")!
        let subject = createSubject()
        let mbvc = MockBrowserViewController(profile: profile, tabManager: tabManager)
        subject.browserViewController = mbvc

        // When
        let route = routeBuilder.makeRoute(url: newPrivateTabURL)
        let result = subject.handle(route: route!)

        // Then
        XCTAssertTrue(result)
        XCTAssertEqual(mbvc.openBlankNewTabCount, 1)
        XCTAssertFalse(mbvc.openBlankNewTabFocusLocationField)
        XCTAssertEqual(mbvc.openBlankNewTabIsPrivate, true)
    }

    func testHandleHomepanelNewTab_returnsTrue() {
        // Given
        let newTabURL = URL(string: "firefox://deep-link?url=/homepanel/new-tab")!
        let subject = createSubject()
        let mbvc = MockBrowserViewController(profile: profile, tabManager: tabManager)
        subject.browserViewController = mbvc

        // When
        let route = routeBuilder.makeRoute(url: newTabURL)
        let result = subject.handle(route: route!)

        // Then
        XCTAssertTrue(result)
        XCTAssertEqual(mbvc.openBlankNewTabCount, 1)
        XCTAssertFalse(mbvc.openBlankNewTabFocusLocationField)
        XCTAssertEqual(mbvc.openBlankNewTabIsPrivate, false)
    }

    // MARK: - Default browser route

    func testDefaultBrowser_systemSettings_handlesRoute() {
        let route = Route.defaultBrowser(section: .systemSettings)
        let subject = createSubject()

        let result = subject.handle(route: route)

        XCTAssertTrue(result)
        XCTAssertEqual(applicationHelper.openSettingsCalled, 1)
    }

    func testDefaultBrowser_tutorial_handlesRoute() {
        let route = Route.defaultBrowser(section: .tutorial)
        let subject = createSubject()

        let result = subject.handle(route: route)

        XCTAssertTrue(result)
        XCTAssertNotNil(mockRouter.presentedViewController as? DefaultBrowserOnboardingViewController)
        XCTAssertEqual(mockRouter.presentCalled, 1)
        XCTAssertEqual(subject.childCoordinators.count, 1)
        XCTAssertNotNil(subject.childCoordinators[0] as? LaunchCoordinator)
    }

    // MARK: - Glean route

    func testGleanRoute_handlesRoute() {
        let expectedURL = URL(string: "www.example.com")!
        let route = Route.glean(url: expectedURL)
        let subject = createSubject()

        let result = subject.handle(route: route)

        XCTAssertTrue(result)
        XCTAssertEqual(glean.handleDeeplinkUrlCalled, 1)
        XCTAssertEqual(glean.savedHandleDeeplinkUrl, expectedURL)
    }

    // MARK: - Settings route

    func testGeneralSettingsRoute_showsGeneralSettingsPage() throws {
        let route = Route.settings(section: .general)
        let subject = createSubject()

        let result = subject.handle(route: route)

        XCTAssertTrue(result)
        let presentedVC = try XCTUnwrap(mockRouter.presentedViewController as? ThemedNavigationController)
        XCTAssertEqual(mockRouter.presentCalled, 1)
        XCTAssertTrue(presentedVC.topViewController is AppSettingsTableViewController)
    }

    func testNewTabSettingsRoute_returnsNewTabSettingsPage() throws {
        let route = Route.SettingsSection.newTab
        let subject = createSubject()

        let result = subject.getSettingsViewController(settingsSection: route)

        XCTAssertTrue(result is NewTabContentSettingsViewController)
    }

    func testHomepageSettingsRoute_returnsHomepageSettingsPage() throws {
        let route = Route.SettingsSection.homePage
        let subject = createSubject()

        let result = subject.getSettingsViewController(settingsSection: route)

        XCTAssertTrue(result is HomePageSettingViewController)
    }

    func testMailtoSettingsRoute_returnsMailtoSettingsPage() throws {
        let route = Route.SettingsSection.mailto
        let subject = createSubject()

        let result = subject.getSettingsViewController(settingsSection: route)

        XCTAssertTrue(result is OpenWithSettingsViewController)
    }

    func testSearchSettingsRoute_returnsSearchSettingsPage() throws {
        let route = Route.SettingsSection.search
        let subject = createSubject()

        let result = subject.getSettingsViewController(settingsSection: route)

        XCTAssertTrue(result is SearchSettingsTableViewController)
    }

    func testClearPrivateDataSettingsRoute_returnsClearPrivateDataSettingsPage() throws {
        let route = Route.SettingsSection.clearPrivateData
        let subject = createSubject()

        let result = subject.getSettingsViewController(settingsSection: route)

        XCTAssertTrue(result is ClearPrivateDataTableViewController)
    }

    func testFxaSettingsRoute_returnsFxaSettingsPage() throws {
        let route = Route.SettingsSection.fxa
        let subject = createSubject()

        let result = subject.getSettingsViewController(settingsSection: route)

        XCTAssertTrue(result is SyncContentSettingsViewController)
    }

    func testThemeSettingsRoute_returnsThemeSettingsPage() throws {
        let route = Route.SettingsSection.theme
        let subject = createSubject()

        let result = subject.getSettingsViewController(settingsSection: route)

        XCTAssertTrue(result is ThemeSettingsController)
    }

    func testWallpaperSettingsRoute_canShow_returnsWallpaperSettingsPage() throws {
        wallpaperManager.canSettingsBeShown = true
        let route = Route.SettingsSection.wallpaper
        let subject = createSubject()

        let result = subject.getSettingsViewController(settingsSection: route)

        XCTAssertTrue(result is WallpaperSettingsViewController)
    }

    func testWallpaperSettingsRoute_cannotShow_returnsWallpaperSettingsPage() throws {
        wallpaperManager.canSettingsBeShown = false
        let route = Route.SettingsSection.wallpaper
        let subject = createSubject()

        let result = subject.getSettingsViewController(settingsSection: route)

        XCTAssertNil(result)
    }

    func testSettingsRoute_addSettingsCoordinator() {
        let subject = createSubject(isSettingsCoordinatorEnabled: true)

        let result = subject.handle(route: .settings(section: .general))

        XCTAssertTrue(result)
        XCTAssertEqual(subject.childCoordinators.count, 1)
        XCTAssertNotNil(subject.childCoordinators[0] as? SettingsCoordinator)
    }

    func testPresentedCompletion_callsDidFinishSettings_removesChild() {
        let subject = createSubject(isSettingsCoordinatorEnabled: true)

        let result = subject.handle(route: .settings(section: .general))
        mockRouter.savedCompletion?()

        XCTAssertTrue(result)
        XCTAssertEqual(mockRouter.dismissCalled, 1)
        XCTAssertTrue(subject.childCoordinators.isEmpty)
    }

    func testSettingsCoordinatorDelegate_openURLinNewTab() {
        let expectedURL = URL(string: "www.mozilla.com")!
        let subject = createSubject()
        let mbvc = MockBrowserViewController(profile: profile, tabManager: tabManager)
        subject.browserViewController = mbvc

        subject.openURLinNewTab(expectedURL)

        XCTAssertEqual(mbvc.openURLInNewTabCount, 1)
        XCTAssertEqual(mbvc.openURLInNewTabURL, expectedURL)
    }

    func testSettingsCoordinatorDelegate_didFinishSettings_removesChild() {
        let subject = createSubject(isSettingsCoordinatorEnabled: true)

        let result = subject.handle(route: .settings(section: .general))
        let settingsCoordinator = subject.childCoordinators[0] as! SettingsCoordinator
        subject.didFinishSettings(from: settingsCoordinator)

        XCTAssertTrue(result)
        XCTAssertEqual(mockRouter.dismissCalled, 1)
        XCTAssertTrue(subject.childCoordinators.isEmpty)
    }

    // MARK: - Sign in route

    func testHandleFxaSignIn_returnsTrue() {
        // Given
        let subject = createSubject()
        let mbvc = MockBrowserViewController(profile: profile, tabManager: tabManager)
        subject.browserViewController = mbvc

        // When
        let route = routeBuilder.makeRoute(url: URL(string: "firefox://fxa-signin?signin=coolcodes&user=foo&email=bar")!)
        let result = subject.handle(route: route!)

        // Then
        XCTAssertTrue(result)
        XCTAssertEqual(mbvc.presentSignInCount, 1)
        XCTAssertEqual(mbvc.presentSignInFlowType, .emailLoginFlow)
        XCTAssertEqual(mbvc.presentSignInFxaOptions, FxALaunchParams(entrypoint: .fxaDeepLinkNavigation, query: ["signin": "coolcodes", "user": "foo", "email": "bar"]))
        XCTAssertEqual(mbvc.presentSignInReferringPage, ReferringPage.none)
    }

    // MARK: - App action route

    func testHandleHandleQRCode_returnsTrue() {
        // Given
        let shortcutItem = UIApplicationShortcutItem(type: "com.example.app.QRCode", localizedTitle: "QR Code")

        let subject = createSubject()
        let mbvc = MockBrowserViewController(profile: profile, tabManager: tabManager)
        subject.browserViewController = mbvc

        // When
        let route = routeBuilder.makeRoute(shortcutItem: shortcutItem, tabSetting: .blankPage)
        let result = subject.handle(route: route!)

        // Then
        XCTAssertTrue(result)
        XCTAssertEqual(mbvc.qrCodeCount, 1)
    }

    func testHandleClosePrivateTabs_returnsTrue() {
        // Given
        let url = URL(string: "firefox://widget-small-quicklink-close-private-tabs")!
        let subject = createSubject()
        let mbvc = MockBrowserViewController(profile: profile, tabManager: tabManager)
        subject.browserViewController = mbvc

        // When
        let route = routeBuilder.makeRoute(url: url)
        let result = subject.handle(route: route!)

        // Then
        XCTAssertTrue(result)
        XCTAssertEqual(mbvc.closePrivateTabsCount, 1)
    }

    // MARK: - Helpers
    private func createSubject(isSettingsCoordinatorEnabled: Bool = false,
                               file: StaticString = #file,
                               line: UInt = #line) -> BrowserCoordinator {
        let subject = BrowserCoordinator(router: mockRouter,
                                         screenshotService: screenshotService,
                                         profile: profile,
                                         glean: glean,
                                         applicationHelper: applicationHelper,
                                         wallpaperManager: wallpaperManager,
                                         isSettingsCoordinatorEnabled: isSettingsCoordinatorEnabled)

        trackForMemoryLeaks(subject, file: file, line: line)
        return subject
    }
}
