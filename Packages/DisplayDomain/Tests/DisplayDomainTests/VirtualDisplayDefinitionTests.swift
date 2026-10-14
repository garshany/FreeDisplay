import XCTest
@testable import DisplayDomain

final class VirtualDisplayDefinitionTests: XCTestCase {
    func testDefaultsAndRoundTrip() throws {
        let definition = VirtualDisplayDefinition(name: "Workspace")
        XCTAssertNil(definition.validationError)
        XCTAssertEqual(try JSONDecoder().decode(VirtualDisplayDefinition.self,
                          from: JSONEncoder().encode(definition)), definition)
    }
    func testInvalidBoundaryAndCorruptDefinitionsAreRejected() {
        XCTAssertNotNil(VirtualDisplayDefinition(name: "\0screen").validationError)
        XCTAssertNotNil(VirtualDisplayDefinition(name: "   ").validationError)
        XCTAssertNotNil(VirtualDisplayDefinition(name: "Screen", pixelWidth: 0).validationError)
        XCTAssertNotNil(VirtualDisplayDefinition(name: "Screen", refreshRate: .nan).validationError)
        XCTAssertNotNil(VirtualDisplayDefinition(name: "Screen", refreshRate: .infinity).validationError)
        XCTAssertNotNil(VirtualDisplayDefinition(name: "Screen", pixelWidth: 1921, hiDPI: true).validationError)
        XCTAssertNil(VirtualDisplayDefinition(name: "Screen", pixelWidth: 8192, pixelHeight: 8192,
                                             refreshRate: 120, hiDPI: true).validationError)
    }
}
