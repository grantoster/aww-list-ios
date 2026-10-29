import XCTest
import UIKit
@testable import AwwList

final class BrandTests: XCTestCase {
    /// The bundled Baloo 2 fonts must load; otherwise the app silently falls back to the system font.
    func testBrandFontsLoad() {
        XCTAssertNotNil(UIFont(name: Theme.displayFont, size: 12))
        XCTAssertNotNil(UIFont(name: Theme.bodyFont, size: 12))
        XCTAssertTrue(Theme.hasBrandFonts)
    }
}
