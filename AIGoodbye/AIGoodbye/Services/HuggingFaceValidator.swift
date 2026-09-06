//
//  HuggingFaceValidator.swift
//  AIGoodbye
//
//  Checks a Hugging Face repo BEFORE anything is downloaded: that it exists,
//  that it holds the files MLX needs, how big it is, whether it can see
//  images, and whether this phone has the memory to run it. A four gigabyte
//  download that then fails to load is the worst possible outcome, so every
//  check that can be done over a few kilobytes of JSON is done first.
//

import Foundation

enum ModelValidationError: LocalizedError {
    case badFormat
    case notFound
    case network
    case missingFiles
    case tooLargeForDevice(neededGB: Int, deviceGB: Int)
    case notEnoughSpace(needed: String, free: String)
    case alreadyAdded

    var errorDescription: String? {
        switch self {
        case .badFormat:
            return L10n.text("That doesn't look like a model address. Use the form owner/model-name, for example mlx-community/Qwen3-VL-2B-Instruct-4bit.")
        case .notFound:
            return L10n.text("No model with that name was found on Hugging Face. Check the spelling, and note that private and gated models can't be used.")
        case .network:
            return L10n.text("Couldn't reach Hugging Face. Check your connection and try again.")
        case .missingFiles:
            return L10n.text("This repository isn't an MLX model. Look for a version converted for MLX - the mlx-community organization publishes thousands of them.")
        case .tooLargeForDevice(let neededGB, let deviceGB):
            return L10n.text("This model needs about \(neededGB) GB of memory and this device has \(deviceGB) GB. It would run out of memory.")
        case .notEnoughSpace(let needed, let free):
            return L10n.text("This model needs \(needed) and only \(free) is free.")
        case .alreadyAdded:
            return L10n.text("That model has already been added.")
        }
    }
}

enum HuggingFaceValidator {

    /// Accepts "owner/name", a full huggingface.co URL, or either with
    /// surrounding whitespace, and returns the canonical "owner/name".
    static func normalize(_ raw: String) -> String? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["https://huggingface.co/", "http://huggingface.co/", "huggingface.co/"] {
            if text.lowercased().hasPrefix(prefix) {
                text = String(text.dropFirst(prefix.count))
            }
        }
        // Drop anything after the repo path (tree/main, ?query, #anchor).
        if let hash = text.firstIndex(of: "#") { text = String(text[text.startIndex..<hash]) }
        if let query = text.firstIndex(of: "?") { text = String(text[text.startIndex..<query]) }
        while text.hasSuffix("/") { text.removeLast() }

        let parts = text.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard parts.count >= 2 else { return nil }
        let owner = parts[0]
        let name = parts[1]

        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._")
        guard !owner.isEmpty, !name.isEmpty,
              owner.unicodeScalars.allSatisfy(allowed.contains),
              name.unicodeScalars.allSatisfy(allowed.contains) else { return nil }
        // The repo id becomes a directory name, so a component of dots would
        // let a delete escape the model cache.
        guard !owner.allSatisfy({ $0 == "." }), !name.allSatisfy({ $0 == "." }) else { return nil }
        return "\(owner)/\(name)"
    }

    /// A friendly display name derived from the repo name.
    static func displayName(for repoId: String) -> String {
        let name = repoId.split(separator: "/").last.map(String.init) ?? repoId
        return name
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
    }

    /// Families whose names don't say "vision" but that carry an image
    /// encoder. Getting this wrong costs a multi-gigabyte download that then
    /// fails to load, so the list is worth keeping.
    /// Family names distinctive enough to match anywhere inside a repo id,
    /// model type or architecture - including run-together CamelCase names
    /// like `Idefics3ForConditionalGeneration`.
    private static let visionSubstrings = [
        "vision", "llava", "idefics", "minicpm-v", "internvl", "molmo",
        "florence", "paligemma", "pixtral", "smolvlm", "moondream"
    ]

    /// Short markers that only mean "vision" as a whole word.
    ///
    /// `"vl"` as a substring flagged every repo whose owner happened to be
    /// called something like "vlad", and the app then sent a plain Llama to
    /// the vision factory, where it can only ever fail to load.
    private static let visionTokens: Set<String> = ["vl", "vlm"]

    /// True when a model config describes something with a vision encoder.
    static func looksLikeVisionModel(config: [String: Any], repoId: String) -> Bool {
        // A positive signal in the config settles it.
        if config["vision_config"] != nil
            || config["image_token_id"] != nil
            || config["image_token_index"] != nil { return true }

        // Families that ship both multimodal and text-only members label the
        // text ones plainly: `gemma-3-1b-it` is text only and reports
        // `model_type: "gemma3_text"`.
        let modelType = (config["model_type"] as? String)?.lowercased() ?? ""
        if modelType.hasSuffix("_text") { return false }

        var haystack: [String] = [repoId.lowercased()]
        if !modelType.isEmpty { haystack.append(modelType) }
        if let architectures = config["architectures"] as? [String] {
            haystack.append(contentsOf: architectures.map { $0.lowercased() })
        }

        if haystack.contains(where: { text in visionSubstrings.contains { text.contains($0) } }) {
            return true
        }
        return haystack.contains { text in
            let tokens = text.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
                .map(String.init)
            return tokens.contains { visionTokens.contains($0) }
        }
    }

    // MARK: - The check

    static func validate(_ input: String) async throws -> CustomModelSpec {
        guard let repoId = normalize(input) else { throw ModelValidationError.badFormat }

        guard let treeURL = URL(string: "https://huggingface.co/api/models/\(repoId)/tree/main?recursive=true") else {
            throw ModelValidationError.badFormat
        }

        let treeData: Data
        do {
            let (data, response) = try await URLSession.shared.data(from: treeURL)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 404 || status == 401 || status == 403 { throw ModelValidationError.notFound }
            guard status == 200 else { throw ModelValidationError.network }
            treeData = data
        } catch let error as ModelValidationError {
            throw error
        } catch {
            throw ModelValidationError.network
        }

        guard let entries = try? JSONDecoder().decode([TreeEntry].self, from: treeData) else {
            throw ModelValidationError.network
        }

        // Exactly the set `ModelPrefetcher` downloads, subfolders included.
        // Counting only root-level files promised 1.8 GB for a repo with an
        // `original/` folder and then pulled down five - failing late, on a
        // nearly-full phone, having already told the user it would fit.
        let files = entries.filter {
            $0.type == "file"
                && ($0.path.hasSuffix(".safetensors") || $0.path.hasSuffix(".json"))
        }
        let paths = files.map(\.path)
        let hasWeights = paths.contains { $0.hasSuffix(".safetensors") }
        let hasConfig = paths.contains("config.json")
        let hasTokenizer = paths.contains("tokenizer.json")
        // MLX needs the chat template and special tokens from here; without
        // it the download succeeds and the load fails.
        let hasTokenizerConfig = paths.contains("tokenizer_config.json")
        guard hasWeights, hasConfig, hasTokenizer, hasTokenizerConfig else {
            throw ModelValidationError.missingFiles
        }

        let sizeBytes = files.reduce(Int64(0)) { $0 + $1.actualSize }
        guard sizeBytes > 0 else { throw ModelValidationError.missingFiles }

        // Memory: refuse before the download rather than crashing after it.
        // Compared against the device's stable budget, and the message quotes
        // the same number - it used to compare against instantaneous free
        // memory and then report physical RAM, so a 12 GB phone was told a
        // 2 GB model wouldn't fit on a device with 12 GB.
        let neededGB = AIModel.workingSetGB(forModelBytes: sizeBytes)
        let budgetGB = DeviceCapability.memoryBudgetGB
        if neededGB > budgetGB {
            throw ModelValidationError.tooLargeForDevice(
                neededGB: neededGB, deviceGB: budgetGB
            )
        }

        // Disk: leave a gigabyte of headroom for iOS itself.
        if let free = freeDiskBytes(), free < sizeBytes + 1_000_000_000 {
            throw ModelValidationError.notEnoughSpace(
                needed: ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file),
                free: ByteCountFormatter.string(fromByteCount: free, countStyle: .file)
            )
        }

        // The config decides which MLX factory loads the model, so guessing
        // from the name alone would mean a multi-gigabyte download that then
        // refuses to load. It's a few kilobytes: insist on reading it.
        guard let configURL = URL(string: "https://huggingface.co/\(repoId)/resolve/main/config.json"),
              let (configData, configResponse) = try? await URLSession.shared.data(from: configURL),
              (configResponse as? HTTPURLResponse)?.statusCode == 200,
              let config = try? JSONSerialization.jsonObject(with: configData) as? [String: Any] else {
            throw ModelValidationError.missingFiles
        }
        let supportsVision = looksLikeVisionModel(config: config, repoId: repoId)

        return CustomModelSpec(
            repoId: repoId,
            displayName: displayName(for: repoId),
            sizeBytes: sizeBytes,
            supportsVision: supportsVision
        )
    }

    private static func freeDiskBytes() -> Int64? {
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    private struct TreeEntry: Decodable {
        let type: String
        let path: String
        let size: Int64?
        let lfs: LFS?

        struct LFS: Decodable { let size: Int64? }

        var actualSize: Int64 { lfs?.size ?? size ?? 0 }
    }
}
