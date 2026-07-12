import XCTest
@testable import LonelyBull

final class LocalLLMManagerTests: XCTestCase {
    func testTemplateHints() {
        XCTAssertEqual(LocalLLMManager.templateHint(repoID: "bartowski/Llama-3.2-1B-Instruct-GGUF", fileName: "Llama-3.2-1B-Instruct-Q4_K_M.gguf"), "llama3")
        XCTAssertEqual(LocalLLMManager.templateHint(repoID: "unsloth/Qwen3-0.6B-GGUF", fileName: "Qwen3-0.6B-Q4_K_M.gguf"), "chatml")
        XCTAssertEqual(LocalLLMManager.templateHint(repoID: "google/gemma-2-2b-GGUF", fileName: "gemma-2-2b.Q4_K_M.gguf"), "gemma")
        XCTAssertEqual(LocalLLMManager.templateHint(repoID: "x/Mistral-7B-GGUF", fileName: "mistral.gguf"), "mistral")
    }

    func testPrettyName() {
        XCTAssertEqual(
            LocalLLMManager.prettyName(from: "Qwen2.5-Coder-1.5B-Instruct-abliterated-Q4_K_M.gguf"),
            "Qwen2.5 Coder 1.5B Instruct abliterated Q4_K_M"
        )
    }

    func testLocalModelPrefixRoundTrip() {
        var settings = AppSettings.default()
        settings.selectedChatModel = AppSettings.localModelPrefix + "model-Q4_K_M.gguf"
        XCTAssertTrue(settings.selectedModelIsLocal)
        XCTAssertEqual(settings.selectedLocalModelFileName, "model-Q4_K_M.gguf")
        settings.selectedChatModel = "qwen2.5:latest"
        XCTAssertFalse(settings.selectedModelIsLocal)
        XCTAssertNil(settings.selectedLocalModelFileName)
    }
}

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
