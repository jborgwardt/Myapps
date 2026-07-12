import XCTest
@testable import LonelyBull

final class OllamaPasteParserTests: XCTestCase {
    func testParsesRunCommand() {
        XCTAssertEqual(
            OllamaPasteParser.modelName(from: "ollama run richardyoung/qwythos-9b-abliterated"),
            "richardyoung/qwythos-9b-abliterated"
        )
    }

    func testParsesOllamaComLink() {
        XCTAssertEqual(
            OllamaPasteParser.modelName(from: "https://ollama.com/richardyoung/qwythos-9b-abliterated"),
            "richardyoung/qwythos-9b-abliterated"
        )
    }

    func testParsesLibraryLink() {
        XCTAssertEqual(
            OllamaPasteParser.modelName(from: "https://ollama.com/library/llama3.2"),
            "llama3.2"
        )
    }

    func testParsesTaggedName() {
        XCTAssertEqual(
            OllamaPasteParser.modelName(from: "richardyoung/qwythos-9b-abliterated:Q4_K_M"),
            "richardyoung/qwythos-9b-abliterated:Q4_K_M"
        )
    }

    func testRejectsSentence() {
        XCTAssertNil(OllamaPasteParser.modelName(from: "please install a model for me"))
    }

    func testEmpty() {
        XCTAssertNil(OllamaPasteParser.modelName(from: "   "))
    }
}

final class OllamaClientHelpersTests: XCTestCase {
    func testNormalizeHfCoHost() {
        XCTAssertEqual(
            OllamaClient.normalizePullName("hf.co/bartowski/Llama-3.2-1B-Instruct-GGUF:Q4_K_M"),
            "huggingface.co/bartowski/Llama-3.2-1B-Instruct-GGUF:Q4_K_M"
        )
    }

    func testNormalizeStripsScheme() {
        XCTAssertEqual(
            OllamaClient.normalizePullName("https://huggingface.co/foo/bar"),
            "huggingface.co/foo/bar"
        )
    }

    func testModelMatchIgnoresLatestTag() {
        XCTAssertTrue(
            OllamaClient.modelMatchesPull(
                localName: "richardyoung/qwythos-9b-abliterated:latest",
                pullName: "richardyoung/qwythos-9b-abliterated"
            )
        )
    }

    func testModelMatchAcrossHfHosts() {
        XCTAssertTrue(
            OllamaClient.modelMatchesPull(
                localName: "hf.co/bartowski/Llama-3.2-1B-Instruct-GGUF:Q4_K_M",
                pullName: "huggingface.co/bartowski/Llama-3.2-1B-Instruct-GGUF:Q4_K_M"
            )
        )
    }

    func testModelMatchNegative() {
        XCTAssertFalse(
            OllamaClient.modelMatchesPull(localName: "llama3.2:3b", pullName: "phi3:mini")
        )
    }
}
