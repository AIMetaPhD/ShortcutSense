import Foundation
import XCTest
@testable import ShortcutSenseCore

/// D-036: the model must never be hard-coded, and a cloud-hosted model must never be
/// offered. Loopback alone does not prove the model runs on this machine.
final class OllamaModelPolicyTests: XCTestCase {
    func testOrdinaryLocalModelsAreAccepted() {
        for name in ["qwen3.5:9b", "llama3.2:latest", "mistral:7b-instruct",
                     "qwen2.5:7b", "phi3:mini"] {
            XCTAssertTrue(OllamaModelPolicy.isLocallyExecutable(name), name)
        }
    }

    func testCloudModelsAreRejected() {
        for name in ["gpt-oss:120b-cloud", "deepseek-v3.1:671b-cloud",
                     "cloud/llama3", "something:cloud"] {
            XCTAssertFalse(OllamaModelPolicy.isLocallyExecutable(name), name)
            XCTAssertNotNil(OllamaModelPolicy.rejectionReason(name))
        }
    }

    func testCaseInsensitive() {
        XCTAssertFalse(OllamaModelPolicy.isLocallyExecutable("GPT-OSS:120B-CLOUD"))
    }

    func testEmptyNameIsRejected() {
        XCTAssertFalse(OllamaModelPolicy.isLocallyExecutable(""))
    }

    func testFilteringKeepsOrderAndDropsOnlyCloud() {
        let models = [
            OllamaModel(name: "qwen3.5:9b", sizeBytes: 6_594_474_711, family: "qwen3"),
            OllamaModel(name: "gpt-oss:120b-cloud", sizeBytes: 0, family: nil),
            OllamaModel(name: "llama3.2:latest", sizeBytes: 2_000_000_000, family: "llama"),
        ]
        let kept = OllamaModelPolicy.locallyExecutable(from: models)
        XCTAssertEqual(kept.map(\.name), ["qwen3.5:9b", "llama3.2:latest"])
    }

    func testModelCarriesLocalityFlag() {
        XCTAssertTrue(OllamaModel(name: "qwen3.5:9b", sizeBytes: 1, family: nil).isLocallyExecutable)
        XCTAssertFalse(OllamaModel(name: "x:1b-cloud", sizeBytes: 1, family: nil).isLocallyExecutable)
    }
}

/// D-036: discovery reads whatever the service advertises instead of assuming a name.
final class OllamaTagsParserTests: XCTestCase {
    private func payload(_ json: String) -> Data { Data(json.utf8) }

    func testParsesModelsWithSizesAndFamilies() throws {
        let data = payload("""
        {"models":[
          {"name":"qwen3.5:9b","model":"qwen3.5:9b","size":6594474711,
           "details":{"family":"qwen3","parameter_size":"9B"}},
          {"name":"llama3.2:latest","size":2000000000,"details":{"family":"llama"}}
        ]}
        """)
        let models = try OllamaTagsParser.parse(data)
        XCTAssertEqual(models.count, 2)
        XCTAssertEqual(models[0].name, "qwen3.5:9b")
        XCTAssertEqual(models[0].sizeBytes, 6_594_474_711)
        XCTAssertEqual(models[0].family, "qwen3")
        XCTAssertEqual(models[1].name, "llama3.2:latest")
    }

    func testEmptyModelListIsValid() throws {
        XCTAssertTrue(try OllamaTagsParser.parse(payload(#"{"models":[]}"#)).isEmpty)
    }

    func testEntriesWithoutNameAreSkipped() throws {
        let data = payload(#"{"models":[{"size":1},{"name":"ok:1b","size":2}]}"#)
        XCTAssertEqual(try OllamaTagsParser.parse(data).map(\.name), ["ok:1b"])
    }

    func testMalformedPayloadThrows() {
        XCTAssertThrowsError(try OllamaTagsParser.parse(payload("not json")))
        XCTAssertThrowsError(try OllamaTagsParser.parse(payload(#"{"nope":1}"#)))
    }

    func testCloudModelsSurviveParsingThenGetFiltered() throws {
        let data = payload(#"{"models":[{"name":"gpt-oss:120b-cloud","size":0}]}"#)
        let parsed = try OllamaTagsParser.parse(data)
        XCTAssertEqual(parsed.count, 1)
        XCTAssertTrue(OllamaModelPolicy.locallyExecutable(from: parsed).isEmpty)
    }
}
