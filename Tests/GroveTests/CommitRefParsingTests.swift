import XCTest
@testable import Grove

final class CommitRefParsingTests: XCTestCase {
    func testParsesRefDecoration() {
        let refs = CommitRef.parse("HEAD -> main, origin/main, tag: v1.0", remotes: ["origin"])
        XCTAssertEqual(refs.count, 3)
        XCTAssertEqual(refs[0], CommitRef(name: "main", kind: .head))
        XCTAssertEqual(refs[1], CommitRef(name: "origin/main", kind: .remoteBranch))
        XCTAssertEqual(refs[2], CommitRef(name: "v1.0", kind: .tag))
    }

    func testEmptyDecorationYieldsNothing() {
        XCTAssertTrue(CommitRef.parse("").isEmpty)
        XCTAssertTrue(CommitRef.parse("   ").isEmpty)
    }

    func testDetachedHeadAlone() {
        XCTAssertEqual(CommitRef.parse("HEAD"), [CommitRef(name: "HEAD", kind: .head)])
    }

    func testLocalBranchWithSlashIsNotMistakenForRemote() {
        let refs = CommitRef.parse("feature/login", remotes: ["origin"])
        XCTAssertEqual(refs, [CommitRef(name: "feature/login", kind: .localBranch)])
    }

    func testRemoteBranchIsRecognizedByKnownRemoteName() {
        let refs = CommitRef.parse("origin/feature/login", remotes: ["origin"])
        XCTAssertEqual(refs, [CommitRef(name: "origin/feature/login", kind: .remoteBranch)])
    }

    func testRemoteNamePrefixDoesNotFalselyMatch() {
        let refs = CommitRef.parse("origin/main", remotes: ["orig"])
        XCTAssertEqual(refs[0].kind, .localBranch)
    }

    func testWithoutKnownRemotesEverythingIsLocal() {
        XCTAssertEqual(CommitRef.parse("origin/main")[0].kind, .localBranch)
    }
}
