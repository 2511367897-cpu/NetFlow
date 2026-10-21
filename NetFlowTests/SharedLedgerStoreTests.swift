import XCTest
@testable import NetFlow

final class SharedLedgerStoreTests: XCTestCase {
    func testStandardWidgetUsesExplicitParentGroup() throws {
        XCTAssertEqual(try SharedLedgerStore.resolveSharedGroup(
            defaultGroup: "TEAM.com.jack.flowledger.widget", bundleIdentifier: "com.jack.flowledger.widget"),
            "TEAM.com.jack.flowledger")
    }

    func testStandardAppKeepsItsGroup() throws {
        XCTAssertEqual(try SharedLedgerStore.resolveSharedGroup(
            defaultGroup: "TEAM.com.jack.flowledger", bundleIdentifier: "com.jack.flowledger"),
            "TEAM.com.jack.flowledger")
    }

    func testEnterpriseLiteralWildcardIsNeverExpandedIntoAnUnentitledGroup() throws {
        for bundleID in ["com.jack.flowledger", "com.jack.flowledger.widget"] {
            XCTAssertEqual(try SharedLedgerStore.resolveSharedGroup(
                defaultGroup: "TEAM.*", bundleIdentifier: bundleID), "TEAM.*")
        }
    }

    func testResignedCommonIdentityIsNotReplacedWithOriginalBundleID() throws {
        for bundleID in ["com.jack.flowledger", "com.jack.flowledger.widget"] {
            XCTAssertEqual(try SharedLedgerStore.resolveSharedGroup(
                defaultGroup: "TEAM.app.resigned.identity", bundleIdentifier: bundleID),
                "TEAM.app.resigned.identity")
        }
    }

    func testExplicitSharedGroupIsPreserved() throws {
        XCTAssertEqual(try SharedLedgerStore.resolveSharedGroup(
            defaultGroup: "TEAM.shared.ledger", bundleIdentifier: "com.jack.flowledger.widget"),
            "TEAM.shared.ledger")
    }

    func testInvalidAndTokenGroupsAreRejected() {
        for group in ["", "TEAM", ".group", "TEAM.", "com.apple.token"] {
            XCTAssertThrowsError(try SharedLedgerStore.resolveSharedGroup(
                defaultGroup: group, bundleIdentifier: "com.jack.flowledger"))
        }
    }
}
