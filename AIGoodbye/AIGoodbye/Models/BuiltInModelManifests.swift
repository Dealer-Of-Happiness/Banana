//
//  BuiltInModelManifests.swift
//  AIGoodbye
//
//  The exact files of every built-in model, pinned to the Hugging Face
//  commit the app was tested with: path, byte size, SHA-256 and the git
//  object id Hugging Face reports (used for the loader's metadata sidecar).
//
//  Hugging Face is unreachable from some networks, mainland China above
//  all, where every model download failed with a network error. ModelScope
//  (modelscope.cn) carries byte-identical copies of these repositories, so
//  the prefetcher can fall back to it. Nothing from that mirror is trusted
//  on its word: every file it serves is checked against the SHA-256 here,
//  which is Hugging Face's own fingerprint of the original file.
//
//  Generated from the Hugging Face and ModelScope APIs (every file's
//  SHA-256 matched on both). Regenerate when a built-in model changes.
//

import Foundation

nonisolated struct PinnedModelFile: Sendable, Equatable {
    let path: String
    let size: Int64
    let sha256: String
    /// The id Hugging Face reports for the file - the LFS SHA-256 for large
    /// files, the git blob hash for small ones - which is what the loader's
    /// metadata sidecar records as the etag.
    let etag: String
}

nonisolated struct PinnedModelManifest: Sendable {
    /// The Hugging Face commit these files come from.
    let commit: String
    let files: [PinnedModelFile]

    var totalBytes: Int64 { files.reduce(0) { $0 + $1.size } }
}

nonisolated enum BuiltInModelManifests {
    static func manifest(for huggingFaceId: String) -> PinnedModelManifest? {
        all[huggingFaceId]
    }

    static let all: [String: PinnedModelManifest] = [
        "mlx-community/Qwen3-VL-2B-Instruct-4bit": PinnedModelManifest(
            commit: "9c4f5209e57b31f4b9dfba735de3fb983739c9cc",
            files: [
                PinnedModelFile(path: "added_tokens.json", size: 707, sha256: "c0284b582e14987fbd3d5a2cb2bd139084371ed9acbae488829a1c900833c680", etag: "b54f9135e44c1e81047e8d05cb027af8bc039eed"),
                PinnedModelFile(path: "chat_template.jinja", size: 5292, sha256: "3636d0f0bd6bef02654cdffdc447b79cb2cef8ab02cc75267345946291a489e4", etag: "124386803f142761528f710e77ae483f5f8c4fc4"),
                PinnedModelFile(path: "chat_template.json", size: 5502, sha256: "6f8a6a55027e3da5160105556cda5dd69f6423f1c32645f6730d32de7773d0c4", etag: "e49e75bdda104c8de941eb20e0b3765184fb27bc"),
                PinnedModelFile(path: "config.json", size: 7137, sha256: "6e992843f82cbaf02e8eae2f1c803f8a56f70951fa8a1f30fc1bf8d9ec2d7ec3", etag: "6ee5e6230af083a079913fa2f5272200990f1f0e"),
                PinnedModelFile(path: "generation_config.json", size: 269, sha256: "1e241830b48b397cb0900101421df5450baddc7adf01e5fc86b5615865f3bae4", etag: "7bb37933d2d86e4ceaabcc6540be989658f238e9"),
                PinnedModelFile(path: "model.safetensors", size: 1782040921, sha256: "4750d95a2162829e127a94e83ac350d498d02070aab216c4687da48804a06ffb", etag: "4750d95a2162829e127a94e83ac350d498d02070aab216c4687da48804a06ffb"),
                PinnedModelFile(path: "model.safetensors.index.json", size: 82780, sha256: "30ba24b1c93436450f2e202de402058ecea7417cf66785d4c73e52d1575e6d97", etag: "bfcea108a637b20f7565603b5ec17227a7a4a6c4"),
                PinnedModelFile(path: "preprocessor_config.json", size: 782, sha256: "93585062a80db5e8ca038efc7726a3e6411d9db948472d81d63c6303993be8c5", etag: "2fa6553554f69b4e3a6b742a75264ff9dff90ad0"),
                PinnedModelFile(path: "special_tokens_map.json", size: 613, sha256: "76862e765266b85aa9459767e33cbaf13970f327a0e88d1c65846c2ddd3a1ecd", etag: "ac23c0aaa2434523c494330aeb79c58395378103"),
                PinnedModelFile(path: "tokenizer.json", size: 11422654, sha256: "aeb13307a71acd8fe81861d94ad54ab689df773318809eed3cbe794b4492dae4", etag: "aeb13307a71acd8fe81861d94ad54ab689df773318809eed3cbe794b4492dae4"),
                PinnedModelFile(path: "tokenizer_config.json", size: 5445, sha256: "81ec7bb9530159b326c0bef1d0b6c33d392090524014ea3f0123a3c1eb9c2af5", etag: "fec7f182135c384a08ea2fc9635566ca79c45afc"),
                PinnedModelFile(path: "video_preprocessor_config.json", size: 817, sha256: "59c5c9eb52182eb14c06ffb10ca9effd29adce5f238a95de23ca14a38dbd2cb1", etag: "e32b1d90356f74457edbfca27aa1e121dab7cdc7"),
                PinnedModelFile(path: "vocab.json", size: 2776833, sha256: "ca10d7e9fb3ed18575dd1e277a2579c16d108e32f27439684afa0e10b1440910", etag: "4783fe10ac3adce15ac8f358ef5462739852c569"),
            ]
        ),
        "mlx-community/Qwen3-VL-8B-Instruct-4bit": PinnedModelManifest(
            commit: "defcdea7cc7a4b0858fea563cbbce171d328e457",
            files: [
                PinnedModelFile(path: "added_tokens.json", size: 707, sha256: "c0284b582e14987fbd3d5a2cb2bd139084371ed9acbae488829a1c900833c680", etag: "b54f9135e44c1e81047e8d05cb027af8bc039eed"),
                PinnedModelFile(path: "chat_template.jinja", size: 5292, sha256: "3636d0f0bd6bef02654cdffdc447b79cb2cef8ab02cc75267345946291a489e4", etag: "124386803f142761528f710e77ae483f5f8c4fc4"),
                PinnedModelFile(path: "chat_template.json", size: 5499, sha256: "5c72a170d2a4a1a3bc5adad2e689ae28138a9700e5b8c96c0266331e86c0acce", etag: "1081bacf1af7c7c6de4a585ce02cd0fd34e382da"),
                PinnedModelFile(path: "config.json", size: 7140, sha256: "cb750ae5688f3df07b110381d3dd54a7f2bfa9ec5175ae11e41305b516f3059a", etag: "58c3644a49cfca24347064001e5de92b7129a579"),
                PinnedModelFile(path: "generation_config.json", size: 269, sha256: "8469742d1fce0de951c8909b26a2c0c0d8490837ce476efb114da9e0cefc4d44", etag: "e116347d7ef42621c7a5957f82c015c38d939c1f"),
                PinnedModelFile(path: "model-00001-of-00002.safetensors", size: 5353972197, sha256: "7c637158b2203e321d83596d3661f33b7b98a72beddfaaaa0eddc512acbdd1fb", etag: "7c637158b2203e321d83596d3661f33b7b98a72beddfaaaa0eddc512acbdd1fb"),
                PinnedModelFile(path: "model-00002-of-00002.safetensors", size: 406693049, sha256: "77190cd1dcf244522869bf923558340112b26d7db2ef3692f88407dd9b33c25d", etag: "77190cd1dcf244522869bf923558340112b26d7db2ef3692f88407dd9b33c25d"),
                PinnedModelFile(path: "model.safetensors.index.json", size: 67759, sha256: "520b2e05079402e9468a8701d03d1154d14b2599593afb6effa7fb60c1bff070", etag: "5857ec62530eb589b1876034dd5386f1d98131a6"),
                PinnedModelFile(path: "preprocessor_config.json", size: 782, sha256: "93585062a80db5e8ca038efc7726a3e6411d9db948472d81d63c6303993be8c5", etag: "2fa6553554f69b4e3a6b742a75264ff9dff90ad0"),
                PinnedModelFile(path: "special_tokens_map.json", size: 613, sha256: "76862e765266b85aa9459767e33cbaf13970f327a0e88d1c65846c2ddd3a1ecd", etag: "ac23c0aaa2434523c494330aeb79c58395378103"),
                PinnedModelFile(path: "tokenizer.json", size: 11422654, sha256: "aeb13307a71acd8fe81861d94ad54ab689df773318809eed3cbe794b4492dae4", etag: "aeb13307a71acd8fe81861d94ad54ab689df773318809eed3cbe794b4492dae4"),
                PinnedModelFile(path: "tokenizer_config.json", size: 5445, sha256: "81ec7bb9530159b326c0bef1d0b6c33d392090524014ea3f0123a3c1eb9c2af5", etag: "fec7f182135c384a08ea2fc9635566ca79c45afc"),
                PinnedModelFile(path: "video_preprocessor_config.json", size: 817, sha256: "59c5c9eb52182eb14c06ffb10ca9effd29adce5f238a95de23ca14a38dbd2cb1", etag: "e32b1d90356f74457edbfca27aa1e121dab7cdc7"),
                PinnedModelFile(path: "vocab.json", size: 2776833, sha256: "ca10d7e9fb3ed18575dd1e277a2579c16d108e32f27439684afa0e10b1440910", etag: "4783fe10ac3adce15ac8f358ef5462739852c569"),
            ]
        ),
        "mlx-community/SmolVLM2-500M-Video-Instruct-mlx": PinnedModelManifest(
            commit: "fa57db46815177fbdfd65cc85a2b3416a8332268",
            files: [
                PinnedModelFile(path: "added_tokens.json", size: 4739, sha256: "74135b8664b56088c0006f1c8e848d79a8eba003411f72ebf1dc2ee96227be3a", etag: "71dc811700b6aa9274d3697ee7d4fb2d5375e766"),
                PinnedModelFile(path: "chat_template.json", size: 430, sha256: "b585e3598909a5687f9f9d738d35223724dedef256b9b274e1cbfb32b13c74bf", etag: "1d342e4f070c962a14ba4ece4e06212bc70d8e36"),
                PinnedModelFile(path: "config.json", size: 10200, sha256: "36159a671d8834df337219b588c03a1dde01e4b472f1e305746e837aaf75ec5d", etag: "11859dc2e0037e29f2d3d824220ec2ce9e87b261"),
                PinnedModelFile(path: "model.safetensors", size: 1015023993, sha256: "a9839c8f79ecc93e54a00dc73cc0e68ba477debcd065d50c1c289fbb1075f981", etag: "a9839c8f79ecc93e54a00dc73cc0e68ba477debcd065d50c1c289fbb1075f981"),
                PinnedModelFile(path: "model.safetensors.index.json", size: 39556, sha256: "87dd860d59f2e9818f09bc6a844c22d5aa65d2a226656d89749952b12df4db38", etag: "1923836dbcb85653932c902189e7ebc68f57ef32"),
                PinnedModelFile(path: "preprocessor_config.json", size: 599, sha256: "149e315d9410368e5491455bb06e0f763426e9e56cca731c13b24404a29b6374", etag: "bf7669a38692ad141d333db3be18bd55cb6e2c59"),
                PinnedModelFile(path: "processor_config.json", size: 67, sha256: "f3ad45028447b3562b4752be0d5916d6806c1ef589091a469608dcf0faa1737c", etag: "83df8c48da1f41e1a9129a4bc2aba000eb2b529f"),
                PinnedModelFile(path: "special_tokens_map.json", size: 868, sha256: "2dfea2a426162316ff1567c82bc6d36d9690cd9f90455f075c77daca78b45c60", etag: "2b5aee28d56c0e9d89ff6bc70818fba986a90ca9"),
                PinnedModelFile(path: "tokenizer.json", size: 3548256, sha256: "5ece781dc8d2b2f3e2f289ca0ae50b17cfc27dd27bfe7971bb8241e0b964331a", etag: "a4005d1cf3170a31600a5c96f95768166cbc2b28"),
                PinnedModelFile(path: "tokenizer_config.json", size: 28626, sha256: "dd9ce2ab89a3dd881bd9378f1a79b943a064b9275a7e1706d5b7b47b68977913", etag: "e4042a1126290fdb96ece2a4ad8dd7108c5de484"),
                PinnedModelFile(path: "vocab.json", size: 800662, sha256: "82b84012e3add4d01d12ba14442026e49b8cbbaead1f79ecf3d919784f82dc79", etag: "0ad5ecc2035b7031b88afb544ee95e2d49baa484"),
            ]
        ),
        "mlx-community/Qwen2-VL-2B-Instruct-4bit": PinnedModelManifest(
            commit: "01af461cdb9574acc09084a0ef94e216e142b085",
            files: [
                PinnedModelFile(path: "added_tokens.json", size: 392, sha256: "7fa54985b58718a8fdb4f4d97484c4bd908db114847675e4bf3afe3e1d5d7bd4", etag: "caa81304af029feb531f1fe80a096dc539ea0153"),
                PinnedModelFile(path: "chat_template.json", size: 1049, sha256: "94174d7176c52a7192f96fc34eb2cf23c7c2059d63cdbfadca1586ba89731fb7", etag: "13303be6f396b038cf397b34a8096819d403836b"),
                PinnedModelFile(path: "config.json", size: 1408, sha256: "3c6bdaacede67a811e0e122def203d9465301416a3df11835a2f238e1f349b9e", etag: "2c55e43b343cfd774e7a72e4407813aae80d9292"),
                PinnedModelFile(path: "model.safetensors", size: 1245868907, sha256: "3534d3dcfaacd0cd00e935469bc34b6d692b2ba0749c5d9ee422f3f2175cf992", etag: "3534d3dcfaacd0cd00e935469bc34b6d692b2ba0749c5d9ee422f3f2175cf992"),
                PinnedModelFile(path: "model.safetensors.index.json", size: 107605, sha256: "ddc9492d4ec6dc9031d4f96050be9a233a451a3a0c07720fbbffc0b950e69669", etag: "0aa857ff7d8c7934412e16babf3debe92e7c1d02"),
                PinnedModelFile(path: "preprocessor_config.json", size: 499, sha256: "56fd296c1d6dc1ae216c84b39b10381784a02ff42db425dbf02683b42a7e3f65", etag: "e8abd23b3ec5289bb1b8e809e1f4b1ac6a30b909"),
                PinnedModelFile(path: "special_tokens_map.json", size: 613, sha256: "76862e765266b85aa9459767e33cbaf13970f327a0e88d1c65846c2ddd3a1ecd", etag: "ac23c0aaa2434523c494330aeb79c58395378103"),
                PinnedModelFile(path: "tokenizer.json", size: 11420371, sha256: "091aa7594dc2fcfbfa06b9e3c22a5f0562ac14f30375c13af7309407a0e67b8a", etag: "091aa7594dc2fcfbfa06b9e3c22a5f0562ac14f30375c13af7309407a0e67b8a"),
                PinnedModelFile(path: "tokenizer_config.json", size: 4297, sha256: "eb3c5a310899d7d65feec0dee4dff9067d7bc4ad2a17e2005bc9163f1ace0531", etag: "6287abf187a01a1ad531bdc60bacfe972d51254e"),
                PinnedModelFile(path: "vocab.json", size: 2776833, sha256: "ca10d7e9fb3ed18575dd1e277a2579c16d108e32f27439684afa0e10b1440910", etag: "4783fe10ac3adce15ac8f358ef5462739852c569"),
            ]
        ),
        "mlx-community/Qwen3.5-0.8B-4bit": PinnedModelManifest(
            commit: "da28692b5f139cb0ec58a356b437486b7dac7462",
            files: [
                PinnedModelFile(path: "chat_template.jinja", size: 7755, sha256: "273d8e0e683b885071fb17e08d71e5f2a5ddfb5309756181681de4f5a1822d80", etag: "0ef09f214eaa6d9bca297988afc1454b5827b2c7"),
                PinnedModelFile(path: "config.json", size: 3112, sha256: "ba7770da23eae5ebd6827571f086e331956b33f4442a9e876fb4aa10969a6772", etag: "f2a232ff3224989be3b1a4db407475dbef3247f6"),
                PinnedModelFile(path: "model.safetensors", size: 625229487, sha256: "f5a0d9dd3efa73510542a8023d610ff26be2b4b020d181cfc4bedaa1fcc5dd9e", etag: "f5a0d9dd3efa73510542a8023d610ff26be2b4b020d181cfc4bedaa1fcc5dd9e"),
                PinnedModelFile(path: "model.safetensors.index.json", size: 71473, sha256: "6e48f2fa5d6f033a6d77bf833abfa9698ca24d1715ecea4c67447bcfaee44650", etag: "e9a7b6207ef38295c02bbdb5e5e98a27161a4a51"),
                PinnedModelFile(path: "preprocessor_config.json", size: 390, sha256: "27225450ac9c6529872ee1924fcb0962ff5634834f817040f444118116f4e516", etag: "2ea84a437d448ff71b08df68fdd949d5cc4ebb64"),
                PinnedModelFile(path: "processor_config.json", size: 1300, sha256: "14932921ca485d458a04dafd8069fbb0a4505622a48208d19ed247115801385b", etag: "7ad6acdf4203f22b7b990e36ccc3a1fe38563d5e"),
                PinnedModelFile(path: "tokenizer.json", size: 19989343, sha256: "87a7830d63fcf43bf241c3c5242e96e62dd3fdc29224ca26fed8ea333db72de4", etag: "87a7830d63fcf43bf241c3c5242e96e62dd3fdc29224ca26fed8ea333db72de4"),
                PinnedModelFile(path: "tokenizer_config.json", size: 1139, sha256: "e98f1901ac6f0adff67b1d540bfa0c36ac1a0cf59eb72ed78146ef89aafa1182", etag: "a068e2468cff426a9b105006e74e044030a6faf4"),
                PinnedModelFile(path: "video_preprocessor_config.json", size: 385, sha256: "7768af27c1fafa9cc9011c1dc20067e03f8915e03b63504550e11d5066986d13", etag: "3ba673a5ad7d4d13f54155ecd38b2a94a6dac8fe"),
                PinnedModelFile(path: "vocab.json", size: 6722759, sha256: "ce99b4cb2983d118806ce0a8b777a35b093e2000a503ebde25853284c9dfa003", etag: "0aa0ce0658d60ac4a5d609f4eadb0e8e43514176"),
            ]
        ),
        "mlx-community/Qwen3.5-2B-4bit": PinnedModelManifest(
            commit: "674aaa7240b91e8012fcad5d791b7dfe5ba90207",
            files: [
                PinnedModelFile(path: "chat_template.jinja", size: 7755, sha256: "273d8e0e683b885071fb17e08d71e5f2a5ddfb5309756181681de4f5a1822d80", etag: "0ef09f214eaa6d9bca297988afc1454b5827b2c7"),
                PinnedModelFile(path: "config.json", size: 3113, sha256: "beb7fc5a6e0405fe332821cf1a8ef7b69bb390a8c8933171647de5579debf949", etag: "6d901903a287e72c3677c1f8242a9f30c39dd117"),
                PinnedModelFile(path: "model.safetensors", size: 1722271785, sha256: "713fe7e5d3c3965f7106b0d0ee17615f7869c23c8d327996df8c1196fbcf07d5", etag: "713fe7e5d3c3965f7106b0d0ee17615f7869c23c8d327996df8c1196fbcf07d5"),
                PinnedModelFile(path: "model.safetensors.index.json", size: 81722, sha256: "8294c05cca7d53a6c33e3db2b379539bd296d054e0b689711b16b6ac93c7e49d", etag: "2d9ef9d4c10685ab801a5d2011821d700b688d5f"),
                PinnedModelFile(path: "preprocessor_config.json", size: 390, sha256: "27225450ac9c6529872ee1924fcb0962ff5634834f817040f444118116f4e516", etag: "2ea84a437d448ff71b08df68fdd949d5cc4ebb64"),
                PinnedModelFile(path: "processor_config.json", size: 1300, sha256: "14932921ca485d458a04dafd8069fbb0a4505622a48208d19ed247115801385b", etag: "7ad6acdf4203f22b7b990e36ccc3a1fe38563d5e"),
                PinnedModelFile(path: "tokenizer.json", size: 19989343, sha256: "87a7830d63fcf43bf241c3c5242e96e62dd3fdc29224ca26fed8ea333db72de4", etag: "87a7830d63fcf43bf241c3c5242e96e62dd3fdc29224ca26fed8ea333db72de4"),
                PinnedModelFile(path: "tokenizer_config.json", size: 1139, sha256: "e98f1901ac6f0adff67b1d540bfa0c36ac1a0cf59eb72ed78146ef89aafa1182", etag: "a068e2468cff426a9b105006e74e044030a6faf4"),
                PinnedModelFile(path: "video_preprocessor_config.json", size: 385, sha256: "7768af27c1fafa9cc9011c1dc20067e03f8915e03b63504550e11d5066986d13", etag: "3ba673a5ad7d4d13f54155ecd38b2a94a6dac8fe"),
                PinnedModelFile(path: "vocab.json", size: 6722759, sha256: "ce99b4cb2983d118806ce0a8b777a35b093e2000a503ebde25853284c9dfa003", etag: "0aa0ce0658d60ac4a5d609f4eadb0e8e43514176"),
            ]
        ),
        "mlx-community/Qwen3.5-4B-4bit": PinnedModelManifest(
            commit: "0e7ffd5c629ef7719d4cbc04069232580bfa9d9c",
            files: [
                PinnedModelFile(path: "chat_template.jinja", size: 7756, sha256: "a4aee8afcf2e0711942cf848899be66016f8d14a889ff9ede07bca099c28f715", etag: "a585dec894e63da457d9440ec6aa7caa16d20860"),
                PinnedModelFile(path: "config.json", size: 3366, sha256: "f3efc81b2ea8d96a45301037d3ccccbcccdef44a961845c87f286aaddbc6eaaa", etag: "cb3e1a878a5c4a0505e0c9967da45820b2ca6bd3"),
                PinnedModelFile(path: "model.safetensors", size: 3034300695, sha256: "5fb9acd0246866381cf8c5c354c6db1019f6498eec4ccb4f5edcc71ffeacb2db", etag: "5fb9acd0246866381cf8c5c354c6db1019f6498eec4ccb4f5edcc71ffeacb2db"),
                PinnedModelFile(path: "model.safetensors.index.json", size: 101944, sha256: "52e534c41f7b97708329c85f762e5882bf48bd5955a422c6ae74eba321e6048a", etag: "40196ba58595ef9b3fad25a8a6daf3288b953c19"),
                PinnedModelFile(path: "preprocessor_config.json", size: 390, sha256: "27225450ac9c6529872ee1924fcb0962ff5634834f817040f444118116f4e516", etag: "2ea84a437d448ff71b08df68fdd949d5cc4ebb64"),
                PinnedModelFile(path: "processor_config.json", size: 1300, sha256: "14932921ca485d458a04dafd8069fbb0a4505622a48208d19ed247115801385b", etag: "7ad6acdf4203f22b7b990e36ccc3a1fe38563d5e"),
                PinnedModelFile(path: "tokenizer.json", size: 19989343, sha256: "87a7830d63fcf43bf241c3c5242e96e62dd3fdc29224ca26fed8ea333db72de4", etag: "87a7830d63fcf43bf241c3c5242e96e62dd3fdc29224ca26fed8ea333db72de4"),
                PinnedModelFile(path: "tokenizer_config.json", size: 1139, sha256: "e98f1901ac6f0adff67b1d540bfa0c36ac1a0cf59eb72ed78146ef89aafa1182", etag: "a068e2468cff426a9b105006e74e044030a6faf4"),
                PinnedModelFile(path: "video_preprocessor_config.json", size: 385, sha256: "7768af27c1fafa9cc9011c1dc20067e03f8915e03b63504550e11d5066986d13", etag: "3ba673a5ad7d4d13f54155ecd38b2a94a6dac8fe"),
                PinnedModelFile(path: "vocab.json", size: 6722759, sha256: "ce99b4cb2983d118806ce0a8b777a35b093e2000a503ebde25853284c9dfa003", etag: "0aa0ce0658d60ac4a5d609f4eadb0e8e43514176"),
            ]
        ),
        "mlx-community/Qwen3.5-9B-4bit": PinnedModelManifest(
            commit: "8b2b98c00a6b4d291155e4890773ca8f769aee53",
            files: [
                PinnedModelFile(path: "chat_template.jinja", size: 7756, sha256: "a4aee8afcf2e0711942cf848899be66016f8d14a889ff9ede07bca099c28f715", etag: "a585dec894e63da457d9440ec6aa7caa16d20860"),
                PinnedModelFile(path: "config.json", size: 3331, sha256: "a96942cb6a8a1d3f1d17514d81a1925d04362a6a3233b389d13012211baaa9f8", etag: "0435ae3f4b3c8b907f7359a2f8f7150d316f3435"),
                PinnedModelFile(path: "model-00001-of-00002.safetensors", size: 5349771222, sha256: "a68b87558c6ef43f74c2bd63ce7e9092ceddc3101f3def0030774bae5f42aadd", etag: "a68b87558c6ef43f74c2bd63ce7e9092ceddc3101f3def0030774bae5f42aadd"),
                PinnedModelFile(path: "model-00002-of-00002.safetensors", size: 600449850, sha256: "b0a770bf8469c7f3f18756a0e0283f1c1174344a83e059a4e483f6af4907352d", etag: "b0a770bf8469c7f3f18756a0e0283f1c1174344a83e059a4e483f6af4907352d"),
                PinnedModelFile(path: "model.safetensors.index.json", size: 123592, sha256: "dd023913fb87cfdae27fb11dcf695117c925833796ccac3c64117d6652d8ff1e", etag: "d366fa524ccd8f4ed93a67c7857597dc56172b92"),
                PinnedModelFile(path: "preprocessor_config.json", size: 390, sha256: "27225450ac9c6529872ee1924fcb0962ff5634834f817040f444118116f4e516", etag: "2ea84a437d448ff71b08df68fdd949d5cc4ebb64"),
                PinnedModelFile(path: "processor_config.json", size: 1300, sha256: "14932921ca485d458a04dafd8069fbb0a4505622a48208d19ed247115801385b", etag: "7ad6acdf4203f22b7b990e36ccc3a1fe38563d5e"),
                PinnedModelFile(path: "tokenizer.json", size: 19989343, sha256: "87a7830d63fcf43bf241c3c5242e96e62dd3fdc29224ca26fed8ea333db72de4", etag: "87a7830d63fcf43bf241c3c5242e96e62dd3fdc29224ca26fed8ea333db72de4"),
                PinnedModelFile(path: "tokenizer_config.json", size: 1139, sha256: "e98f1901ac6f0adff67b1d540bfa0c36ac1a0cf59eb72ed78146ef89aafa1182", etag: "a068e2468cff426a9b105006e74e044030a6faf4"),
                PinnedModelFile(path: "video_preprocessor_config.json", size: 385, sha256: "7768af27c1fafa9cc9011c1dc20067e03f8915e03b63504550e11d5066986d13", etag: "3ba673a5ad7d4d13f54155ecd38b2a94a6dac8fe"),
                PinnedModelFile(path: "vocab.json", size: 6722759, sha256: "ce99b4cb2983d118806ce0a8b777a35b093e2000a503ebde25853284c9dfa003", etag: "0aa0ce0658d60ac4a5d609f4eadb0e8e43514176"),
            ]
        ),
        "mlx-community/gemma-4-e2b-it-4bit": PinnedModelManifest(
            commit: "238767527555cb75a05732a84dff5d6ba0dd6809",
            files: [
                PinnedModelFile(path: "chat_template.jinja", size: 17336, sha256: "2f1b4d75d067bae3fe44e676721c7f077d243bc007156cb9c2f8b5836613d082", etag: "c19999a347da729cf62806a8ddb7eb8e315223b5"),
                PinnedModelFile(path: "config.json", size: 6395, sha256: "6397cb6eca41b911d1dcab74e17941351057bd759284052a2331918ff6f9246c", etag: "1f8a26de63cd505f2fb5c98ad3f08f3e7f47a9de"),
                PinnedModelFile(path: "generation_config.json", size: 208, sha256: "d4226bbe3117d2d253ba4609720ba82c6c4ce4627a9a6ae05387c78983ac03de", etag: "e605bb4523b1462ea9d9a3810b9e3ecf7ab7b1f6"),
                PinnedModelFile(path: "model.safetensors", size: 3550670554, sha256: "038e39a37a7667373d2c3991375446b10c96ae1d717a68674870343db376b76e", etag: "038e39a37a7667373d2c3991375446b10c96ae1d717a68674870343db376b76e"),
                PinnedModelFile(path: "model.safetensors.index.json", size: 218323, sha256: "edb157dbf495e23f37377af4a628a9ad13c4ee7937f93ccb36ec9e9a19940f16", etag: "b145d4f0cf82ffc8c1f9bef70da4b4083646382d"),
                PinnedModelFile(path: "processor_config.json", size: 1316, sha256: "de3e580aebdc98272d4c4547daffe6525fcbae18a83a0e0bcf0d7444d4ee6f37", etag: "a086fb7e04b477c291a120b0a004abb78b11c6d2"),
                PinnedModelFile(path: "tokenizer.json", size: 32169626, sha256: "cc8d3a0ce36466ccc1278bf987df5f71db1719b9ca6b4118264f45cb627bfe0f", etag: "cc8d3a0ce36466ccc1278bf987df5f71db1719b9ca6b4118264f45cb627bfe0f"),
                PinnedModelFile(path: "tokenizer_config.json", size: 2740, sha256: "080d9e1aff284e2f6043889cd05367966f7c7b80e025fbc0b06745e218158656", etag: "cf6235aee46a24bf71f251c0a4e7a0379948f7d2"),
            ]
        ),
        "mlx-community/gemma-4-e4b-it-4bit": PinnedModelManifest(
            commit: "475b9088d29754a3379866cf5aeb6b41acd313c2",
            files: [
                PinnedModelFile(path: "chat_template.jinja", size: 17336, sha256: "2f1b4d75d067bae3fe44e676721c7f077d243bc007156cb9c2f8b5836613d082", etag: "c19999a347da729cf62806a8ddb7eb8e315223b5"),
                PinnedModelFile(path: "config.json", size: 6628, sha256: "780ccb3a514a5f1ced161d383f948fc22eca9b84b752ca19494f625bd9bad7a6", etag: "4ee08502c4f98810dd43800ec849bd69f94adc98"),
                PinnedModelFile(path: "generation_config.json", size: 208, sha256: "d4226bbe3117d2d253ba4609720ba82c6c4ce4627a9a6ae05387c78983ac03de", etag: "e605bb4523b1462ea9d9a3810b9e3ecf7ab7b1f6"),
                PinnedModelFile(path: "model.safetensors", size: 5146800534, sha256: "932b8271fc3fe65adcc78b96c10c6268bbfb13e8f67d1358727c0d6ee97e1eff", etag: "932b8271fc3fe65adcc78b96c10c6268bbfb13e8f67d1358727c0d6ee97e1eff"),
                PinnedModelFile(path: "model.safetensors.index.json", size: 240961, sha256: "f8accac59ee7efe87e0c298c854610b262c3cadd477407503147c71209ff0093", etag: "c03ce5f7086b735345038501f731634de064493b"),
                PinnedModelFile(path: "processor_config.json", size: 1316, sha256: "de3e580aebdc98272d4c4547daffe6525fcbae18a83a0e0bcf0d7444d4ee6f37", etag: "a086fb7e04b477c291a120b0a004abb78b11c6d2"),
                PinnedModelFile(path: "tokenizer.json", size: 32169626, sha256: "cc8d3a0ce36466ccc1278bf987df5f71db1719b9ca6b4118264f45cb627bfe0f", etag: "cc8d3a0ce36466ccc1278bf987df5f71db1719b9ca6b4118264f45cb627bfe0f"),
                PinnedModelFile(path: "tokenizer_config.json", size: 2740, sha256: "080d9e1aff284e2f6043889cd05367966f7c7b80e025fbc0b06745e218158656", etag: "cf6235aee46a24bf71f251c0a4e7a0379948f7d2"),
            ]
        ),
        "mlx-community/Qwen3.5-0.8B-8bit": PinnedModelManifest(
            commit: "87e768fbfa03994095f3d14527c80c5ae70c5758",
            files: [
                PinnedModelFile(path: "chat_template.jinja", size: 7755, sha256: "273d8e0e683b885071fb17e08d71e5f2a5ddfb5309756181681de4f5a1822d80", etag: "0ef09f214eaa6d9bca297988afc1454b5827b2c7"),
                PinnedModelFile(path: "config.json", size: 3112, sha256: "be287fbd6f3549b1ca08a61d69833e48f72d884a0957084f4cbc7b5e3eac23db", etag: "9bb95955e9161e75b13366fc2e367934f87c108e"),
                PinnedModelFile(path: "model.safetensors", size: 1001176958, sha256: "9a887c5731520e33bbd324378ecb7b560c1f750af16a6dc28229d500304e656c", etag: "9a887c5731520e33bbd324378ecb7b560c1f750af16a6dc28229d500304e656c"),
                PinnedModelFile(path: "model.safetensors.index.json", size: 71474, sha256: "46e263363b4a4ad4e450ac06024ab804d8686149690a955f68397fcc6483f5e9", etag: "f75d94dbe4b9fe6b0366e825b79ac5a3c676e613"),
                PinnedModelFile(path: "preprocessor_config.json", size: 390, sha256: "27225450ac9c6529872ee1924fcb0962ff5634834f817040f444118116f4e516", etag: "2ea84a437d448ff71b08df68fdd949d5cc4ebb64"),
                PinnedModelFile(path: "processor_config.json", size: 1300, sha256: "14932921ca485d458a04dafd8069fbb0a4505622a48208d19ed247115801385b", etag: "7ad6acdf4203f22b7b990e36ccc3a1fe38563d5e"),
                PinnedModelFile(path: "tokenizer.json", size: 19989343, sha256: "87a7830d63fcf43bf241c3c5242e96e62dd3fdc29224ca26fed8ea333db72de4", etag: "87a7830d63fcf43bf241c3c5242e96e62dd3fdc29224ca26fed8ea333db72de4"),
                PinnedModelFile(path: "tokenizer_config.json", size: 1139, sha256: "e98f1901ac6f0adff67b1d540bfa0c36ac1a0cf59eb72ed78146ef89aafa1182", etag: "a068e2468cff426a9b105006e74e044030a6faf4"),
                PinnedModelFile(path: "video_preprocessor_config.json", size: 385, sha256: "7768af27c1fafa9cc9011c1dc20067e03f8915e03b63504550e11d5066986d13", etag: "3ba673a5ad7d4d13f54155ecd38b2a94a6dac8fe"),
                PinnedModelFile(path: "vocab.json", size: 6722759, sha256: "ce99b4cb2983d118806ce0a8b777a35b093e2000a503ebde25853284c9dfa003", etag: "0aa0ce0658d60ac4a5d609f4eadb0e8e43514176"),
            ]
        ),
    ]
}
