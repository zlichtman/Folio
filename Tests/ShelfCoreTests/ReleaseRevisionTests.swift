import XCTest
@testable import ShelfCore

final class ReleaseRevisionTests: XCTestCase {
    typealias R = ReleaseRevision
    func testVersionsComeFromTags() {
        XCTAssertEqual(R.version(fromTag:"v1.2"),"1.2")
        XCTAssertEqual(R.version(fromTag:"1.2.3"),"1.2.3")
        XCTAssertEqual(R.version(fromTag:"V2"),"2")
        for bad in ["","v","1.2.3.4","1..2","v1.2-beta","1.2a","latest","12345.1"," 1.2"] { XCTAssertNil(R.version(fromTag:bad),bad) }
        XCTAssertEqual(R.compare("1.10","1.9"),.orderedDescending)
        XCTAssertEqual(R.compare("1.2","1.2.0"),.orderedSame)
        XCTAssertEqual(R.compare("0.9","1.0"),.orderedAscending)
    }
    func testBuildMarkerMustBeSingleAndWellFormed() {
        XCTAssertEqual(R.build(in:"## What's new\n- Faster\n\n<!-- folio-build:42 -->\n"),42)
        XCTAssertEqual(R.build(in:"Notes\r\n  <!-- folio-build:7 -->  \r\n"),7)
        XCTAssertNil(R.build(in:nil))
        XCTAssertNil(R.build(in:"No marker"))
        XCTAssertNil(R.build(in:"<!-- folio-build:4 -->\n<!-- folio-build:5 -->"))
        for bad in ["<!-- folio-build: -->","<!-- folio-build:0 -->","<!-- folio-build:-3 -->","<!-- folio-build:3x -->","<!-- folio-build:3-->","<!-- folio-build:9999999999 -->"] { XCTAssertNil(R.build(in:bad),bad) }
        XCTAssertNil(R.build(in:"<!-- macspaces-build:9 -->"))
        XCTAssertTrue(R.isNewer(3,than:2)); XCTAssertFalse(R.isNewer(2,than:2)); XCTAssertFalse(R.isNewer(0,than:-1))
        XCTAssertEqual(R.notes("## Fixes\r\n- One\r\n\r\n<!-- folio-build:9 -->\r\n"),"## Fixes\n- One")
    }
    func feed(_ tag: String, build: Int?, draft: Bool = false, prerelease: Bool = false) -> Data {
        let body = "Notes\n" + (build.map { "<!-- folio-build:\($0) -->" } ?? "")
        let object: [String:Any] = ["tag_name":tag,"body":body,"draft":draft,"prerelease":prerelease,"html_url":"https://github.com/zlichtman/Folio/releases/tag/\(tag)",
            "assets":[["name":"Folio.dmg","browser_download_url":"https://github.com/zlichtman/Folio/releases/download/\(tag)/Folio.dmg"]]]
        return try! JSONSerialization.data(withJSONObject:object)
    }
    func testLatestReleaseRejectsDraftsPrereleasesAndMissingMarkers() {
        XCTAssertEqual(R.latest(from:feed("v1.2",build:12))?.build,12)
        XCTAssertEqual(R.latest(from:feed("v1.2",build:12))?.version,"1.2")
        XCTAssertNil(R.latest(from:feed("v1.4",build:14,draft:true)))
        XCTAssertNil(R.latest(from:feed("v1.3",build:13,prerelease:true)))
        XCTAssertNil(R.latest(from:feed("v9",build:nil)))
        XCTAssertNil(R.latest(from:feed("nightly",build:99)))
        XCTAssertNil(R.latest(from:Data("[]".utf8)))
        XCTAssertNil(R.latest(from:Data("{}".utf8)))
    }
    func testDecodesGitHubFeedAndPinsAssetHosts() throws {
        let json = """
        {"tag_name":"v1.3","name":"Folio 1.3","body":"Hi\\n<!-- folio-build:13 -->","draft":false,"prerelease":false,"html_url":"https://github.com/zlichtman/Folio/releases/tag/v1.3",
          "assets":[{"name":"folio.DMG","browser_download_url":"https://github.com/zlichtman/Folio/releases/download/v1.3/Folio.dmg"},{"name":"Folio.zip","browser_download_url":"https://example.com/x.zip"}]}
        """
        let latest = try XCTUnwrap(R.latest(from:Data(json.utf8)))
        XCTAssertEqual(latest.build,13); XCTAssertEqual(latest.release.page?.lastPathComponent,"v1.3")
        let asset = try XCTUnwrap(R.asset(in:latest.release))
        XCTAssertTrue(R.isTrustedDownload(asset.url))
        for url in ["http://github.com/a.dmg","https://evil.example/Folio.dmg","https://github.com.evil.example/a","https://user@github.com/a","file:///tmp/Folio.dmg"] {
            XCTAssertFalse(R.isTrustedDownload(URL(string:url)!),url)
        }
        XCTAssertTrue(R.isTrustedDownload(URL(string:"https://release-assets.githubusercontent.com/github-production-release-asset/1")!))
    }
    func testOnlyCopiesInApplicationsReplaceThemselves() {
        for ok in ["/Applications/Folio.app","/Applications/Utilities/Folio.app"] { XCTAssertTrue(R.canReplaceApp(at:ok),ok) }
        for bad in ["/Volumes/Folio/Folio.app","/Users/me/Downloads/Folio.app","/Users/me/Applications/Folio.app","/private/var/folders/x/AppTranslocation/1/d/Folio.app",
                    "/Applications/../tmp/Folio.app","/Applications/","/Applications/.app","/opt/homebrew/Caskroom/folio/1.3/Folio.app","/usr/local/bin/Folio"] {
            XCTAssertFalse(R.canReplaceApp(at:bad),bad)
        }
    }
    func testNotesBecomeSections() {
        let body = "**2.15**\n\n## New\n\n- Boards everywhere.\n- Find **Duplicates**.\n\n## Fixes\n\n- A fix.\n\n<!-- folio-build:15 -->\n"
        let sections = ReleaseRevision.sections(in:body)
        XCTAssertEqual(sections.map(\.title),["New","Fixes"])
        XCTAssertEqual(sections[0].points,["Boards everywhere.","Find Duplicates."])
        XCTAssertTrue(ReleaseRevision.sections(in:nil).isEmpty)
    }
}
