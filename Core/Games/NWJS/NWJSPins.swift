/// The NW.js releases native runs may download, with the SHA-256 of each
/// macOS archive as `dl.nwjs.io/v<version>/SHASUMS256.txt` listed it on
/// 2026-11-19.
///
/// NW.js ships unsigned for macOS, so nothing on the Mac vouches for a
/// download but its bytes. An archive that does not match is never unpacked,
/// and a release missing here is added by hand (`sevo nwjs add`) until a
/// build of the app lists it.
nonisolated enum NWJSPins {
    /// Version → build flavor → the archive's SHA-256.
    static let archives: [String: [String: String]] = [
        "0.77.0": [
            "osx-arm64": "e396177a7b895b2488fbfe6b17c35ba74fc30bd983fdc4edc47a9a2f6595b126",
            "osx-x64": "34861c649cf97ec9e56ae9d251939e7a300571b96c0d48af48461142c09beb0c",
        ],
        "0.78.0": [
            "osx-arm64": "53ff897c1cd778811d7b2e1f1b44367f54d357fd4eae17ff255bd7322363a123",
            "osx-x64": "5322aa5d23470c6836e917c99d34126b732552455fda4279856db44d065691b6",
        ],
        "0.78.1": [
            "osx-arm64": "fb97a39d1902243326f9333a1f8fc23beca2951758751d6eeb3e5bf74b3c54fa",
            "osx-x64": "7c581659e8d21f98aaa5ea6e6f5a629ecf3e1562a3b3fa08e3f905a39373bb54",
        ],
        "0.79.0": [
            "osx-arm64": "0f115bf2fb6a30afd69f1c8db9408f9f1c192d40b197018b2ed52e7631875c60",
            "osx-x64": "9d149412f9bd236feb8feea390d3de8e9992b004d0823d8eb14684fa602b39cd",
        ],
        "0.79.1": [
            "osx-arm64": "94d33665e691d85c8e83301b8dc5166cef27c7234fc9fc83a55954b7f29a3239",
            "osx-x64": "77cea3005cc5f1c2b6158454fbecc3c95aee89228173aa777a4de54796c9aa3c",
        ],
        "0.80.0": [
            "osx-arm64": "6cdd390f8c63ddef1b8d2e106214f62af7a3631728e9213fd2d61b37698701f6",
            "osx-x64": "9c3170f03f63f97b2739e7e03140b1742fc52b3e5c91ec7d000e71bd83a43329",
        ],
        "0.81.0": [
            "osx-arm64": "b7ed9680e58759610640694e8834103131041efc2ec30dce9d4442c4ad2461a4",
            "osx-x64": "24e4b789fa03295ec62fc1b84c662b71461bd8c1d0241ba853b4c18baa156969",
        ],
        "0.82.0": [
            "osx-arm64": "4059c7f02bd60f5830d1cb2b48e3dd623b1b23bf079e626655ddd2377136e86e",
            "osx-x64": "3979d02e463420a6b657599d6a10047d5f244bcfe8c42643a7ae6d4b0cc36fd6",
        ],
        "0.83.0": [
            "osx-arm64": "6c87b1717104e8fe61a37deb37c55cbfa678d6749bcea2001587bebd00f5ead4",
            "osx-x64": "cf1f3e89cc683d5aee04df2bdd573850410f762442385b6634e9e6e5e3ce78e6",
        ],
        "0.84.0": [
            "osx-arm64": "02e7869e43df33856f763aa631141fe3d39d23f5e5afd015307fe11dd8130472",
            "osx-x64": "152004bc1564590c9ac978f0d3ea13908c917ea8abc869aa85f181cf2f1b58cc",
        ],
        "0.85.0": [
            "osx-arm64": "ea46606f45aff8ee70d016d9924520ffb3485ebda744607ef4af62cef8fb411a",
            "osx-x64": "a4e60fe417b2a784be4612a2dde79fed7b5fed7d8b23daecb8b43e2a20e5cb8a",
        ],
        "0.86.0": [
            "osx-arm64": "9ed9a2a3bfa9962d9e13beee067ae1a3e1e3021e3a793a439e88db4ef9f62f14",
            "osx-x64": "4f3ec047fa0604041ed04d6591774294939c1b2b8a6b6ff96cfb62fa896d5430",
        ],
        "0.87.0": [
            "osx-arm64": "e268a86d93384567bd5a1c991fc08c85d21c58eefb516bd42d24dc3a003763ba",
            "osx-x64": "9f3d01a0d0ba76f010ef3491bc4b07fb9aee4a2ae0e27b108bd410cbe420eb28",
        ],
        "0.88.0": [
            "osx-arm64": "92f748fb7a18617307d2854e378db635f6edafdf90849d1143eeb6bdd46052f3",
            "osx-x64": "f6e4cc79f8bacf8121dc80971650fca48f68084edb50e3131c8ce6cc8ae1f609",
        ],
        "0.89.0": [
            "osx-arm64": "5ba0ee97c36cc6479a2cfe0e02cc216b950622980ce7f712c8f04b938763a085",
            "osx-x64": "d6a8db8bf0275d6d718537c4cbed860b891a881397fb7f1ff6fa0a5062401cb2",
        ],
        "0.90.0": [
            "osx-arm64": "71feb1eff04f81e4401b40dec527a220b94dc65e0cdfea04047365999e537a83",
            "osx-x64": "db3ea8ee69349d47ba6ff3a7e2a5e4d72f42308626ceffc7d7239e596f596df9",
        ],
        "0.91.0": [
            "osx-arm64": "82a7ffac9243084e959c45a8db2451447a03e9e412810d442b8eedf546c8f380",
            "osx-x64": "8608e0753d19d747a4a35462c2b304696d6f2187b1e2d68031bf75c27adcbe76",
        ],
        "0.92.0": [
            "osx-arm64": "c89c4bfbb347efa300b84594de036cf6d389c946e05db02113f0ce83bed76425",
            "osx-x64": "183d9b811862f7deb9e7ac51ea039b03f927071fca5008539698e5144aa73a8e",
        ],
        "0.93.0": [
            "osx-arm64": "f67e57948577a7cedbc27017f293cc9ac5724aa1f85b32c74610c29c455b0a86",
            "osx-x64": "7f008bc40aec3ea19ed55163bea18978d842df9c2ef87d8da5a4ffb7ba700cba",
        ],
        "0.94.0": [
            "osx-arm64": "1423ccddafa0bc4cb1a5497b785080ea4c58cead7ec709d4f0ffc6e193e89141",
            "osx-x64": "93135ce5921a2ae1e39e9839daf0940f38757cd09381df17391acaf50b048bd5",
        ],
        "0.94.1": [
            "osx-arm64": "d754aa04da1c8d6be7870f5a11bc21445b0f2aa4fe99dad3c8ba5622746b11e4",
            "osx-x64": "c75ffbf34e24a4bc05cfdb6c5d5113352fa89be5279d29ca8283537d8f407327",
        ],
        "0.95.0": [
            "osx-arm64": "4e695513bd112027b85913d62764c0d6636084f81fd1b3f0ad6d683ccecf308a",
            "osx-x64": "6d4d6c4b9896a60c40e064311a340f5b7779a6357dafa364eced241bbdb1555a",
        ],
        "0.96.0": [
            "osx-arm64": "fb047d19ce156221b0a6443f0943029bbcca1c40603d689c86fb2f7c8971eece",
            "osx-x64": "966e0650ecc216b182eedc3adf3739183ba8e036f0044e584be3bb4fdd100ce7",
        ],
        "0.97.0": [
            "osx-arm64": "7406e336eb90671a357c236c64d8ed97e43b79036380e8f134e3fba1611cc8f2",
            "osx-x64": "ba27dc0dbf49ac31e14ff79d1a1ef1f6347df490c1d99853fba1e87cda7f44a2",
        ],
        "0.98.0": [
            "osx-arm64": "c45977db63cbc521b43131092d0db975ca40ce629cda363694b832672dda930f",
            "osx-x64": "a8b4e0d03fafdd9ba102a17d4f08ec949d534583ad1ae5d5056da65d14dc28c4",
        ],
        "0.98.1": [
            "osx-arm64": "baacd40dc7802c3af261df406164029466a64c1bf4e49ffe570e951424f38b6e",
            "osx-x64": "d020f7f12c763cd5c318689e719d07f4bc55b9cde547cd86f7926c56507d838a",
        ],
        "0.98.2": [
            "osx-arm64": "6f5c748e07bc6622ca2e3a8aafc19df8f1aec19eb9bd47bb60a8afbee447b109",
            "osx-x64": "7ff0a99843c01b3d3b50a7db5ea5011ab28704d383334d8f4544a101e494b885",
        ],
        "0.99.0": [
            "osx-arm64": "51e5ba5789502308f278da4ae1d04eedc9285ccf18cbf4457615156b982ecdbe",
            "osx-x64": "7660807eac9afae49e35a1c6fa91d7b4aa56a6f43b949cabdbc4ab13239308c8",
        ],
        "0.99.1": [
            "osx-arm64": "e8f60fa37387ac8f9c8d9d312542cca16b44aa89fcae87319ad394280683d13a",
            "osx-x64": "d095d4a5122abaadca2ad182368fe81fc87d24e798677ea3786ae54e5ae84e50",
        ],
        "0.100.0": [
            "osx-arm64": "2b0bfd4c379c53d107ac3c0facb3fd09366d64f37e43dd354255632cc196f215",
            "osx-x64": "7c2a1c3cc44c635404991c2037786669eb7b2e2ddf47db168dc017e36fb6acef",
        ],
        "0.100.1": [
            "osx-arm64": "d2478140779733210c4557f36036f2e8e47e6ba29398c590acd3609ef38fd51c",
            "osx-x64": "f0cacc5fc6148f06c86b45f46b79220ecf133ae23949ef8fdd5c168bd96b0b34",
        ],
        "0.101.0": [
            "osx-arm64": "5338b7e6205ae03ba348a853da1610557d1a74a4c440a44e8f00a2aeeba47dd0",
            "osx-x64": "c7579d334eec595d14bf171c6d409bc360983ab84fdf0da1aaf82e75e878462c",
        ],
        "0.101.1": [
            "osx-arm64": "d5644898374c26035af028bd0061319d16014424efaa06b154199cd48cbb2ee0",
            "osx-x64": "cc391a2c9d807e602ec86fe6cd8240355cd5121f961991f154732c2571da47bb",
        ],
        "0.101.2": [
            "osx-arm64": "8ba4055968436506682535c057b11b8ff3c174d6909d43ab5399e33c17580302",
            "osx-x64": "dc9abd4a7d97c864874dd44f728e96ece0eb7e8b8a37e7d9be6522174922aa01",
        ],
        "0.102.0": [
            "osx-arm64": "e8c4377668c804b2252afef2a173f33d4649b8a1668f53b913d4ff2310a6017e",
            "osx-x64": "0d8d4f791900500579232f12affa13f15b0998f4ddf786d25e3cb5fc28eeb264",
        ],
        "0.102.1": [
            "osx-arm64": "0f7686e99040d0c7a61b42c6d5004d83a7c8636ce205d2c16d0e6cb2b48b68a6",
            "osx-x64": "9e4bf18a334e33e1f326183f1d6a03582e6b65de70975495039df21e9b20c7ee",
        ],
        "0.103.0": [
            "osx-arm64": "d5035805c2e88140ff3b49bccd4e66aecd8433cc603f8a2a4d976d5309b7e6fa",
            "osx-x64": "83e57fb8f91b097f6eec5c5c676aef5c0ac4d022e98b101a9e563f9eb45fe06b",
        ],
        "0.103.1": [
            "osx-arm64": "c60c19e68663d0ad67afda88e008a3d613a1c92d34f13e25f27eac947fba1957",
            "osx-x64": "85a2fddbeee96455df9d2a782697d1c58cc1026f03e22116bf9c15926227bb65",
        ],
        "0.104.0": [
            "osx-arm64": "6314eb601911d29fa20b500cf7a29700c249ef956aa4acbb4ad27e94d02ce465",
            "osx-x64": "0d840cf8bd475d8b82854ba173dc9cd86f89ed5f1105b7b4f66cde4b2e8c8018",
        ],
        "0.104.1": [
            "osx-arm64": "4f57ba60319093962464ad3c4e91855661d0602afb9a75e3f1c95e4fbc2f7e7c",
            "osx-x64": "1b3c7fe48f76e1d72ce2f42377b76bd72e621e37af6e4b6f353e841f8d6d2ee9",
        ],
        "0.105.0": [
            "osx-arm64": "1113bd578630cb708f6ac775a73ccbd35fd31ae0ea6326359c5c5710d2468513",
            "osx-x64": "c74292cbcb36bdc6922647d8b462709039d058b6e2801c5c0745193ea12a1a85",
        ],
        "0.106.0": [
            "osx-arm64": "54a54b1c59df93361702c78ad937594e1871c837f10e120bd41f3851986fe6c2",
            "osx-x64": "407faf72a4417ac35d9d817cf6d289450d86c858a4d514d81426d63cdf9dac2c",
        ],
        "0.106.1": [
            "osx-arm64": "2819bf4ae4971d655d1a8b20a26d838fa3a1a49e5b914087a8574191473381ab",
            "osx-x64": "dcc43f99c18890eebacb75a15b54c94ad8ab45100b65aafe789c3a131598bdc8",
        ],
        "0.107.0": [
            "osx-arm64": "e257e9b7a4a82c5eee0ef4f7dbef0faa0e26ea7435d4e83a3a45365006a73a95",
            "osx-x64": "6492d21a1d38bc012de1f194712ab3a46c7d844b0943bb85e051682de7323253",
        ],
        "0.108.0": [
            "osx-arm64": "8966a3a0c29e18853fb840fac6d90e5660c0a6197c75a96067dd6093fbbba85d",
            "osx-x64": "dad6df119a4f945d99092d005f55bcdb5d64f98448426228a45104d06d364ccf",
        ],
        "0.109.0": [
            "osx-arm64": "1f2b95f64f1c5ca52436318a499290fea14c4df7900e73de472b2efb12fddc2a",
            "osx-x64": "a6b3ceee3151bc7b79d2a6be50d31c350d666bf8e5c32fcf1bb0f755e6383bec",
        ],
        "0.109.1": [
            "osx-arm64": "efa113a6c0e6be5ce80fa0c4b1d5103ad2989a330c13c8fee10741d734652ab5",
            "osx-x64": "ceece6d9d46ff4be68e346ae792972f34282f45667ee24dafa04b65f0b2b281a",
        ],
        "0.110.0": [
            "osx-arm64": "a078ca1fc4b2aab32ac22421a64080dc5fba768f25d3876f503478b5e3209dec",
            "osx-x64": "2743c5cb32ff3239af6c14fc32515794bf375c7cbe6a5b5596794870ee7c27b9",
        ],
        "0.110.1": [
            "osx-arm64": "5ace3e2faf5a49274d7112f00c104bae926fef4b1ce57377291fceb568f1a980",
            "osx-x64": "fd912715faaf94ebca14329f0fafdcf6a05c66ad965eb23db04c77b9a94d08c8",
        ],
        "0.111.0": [
            "osx-arm64": "4d4fecb0026968ba7441134847f49ded55809784a88d2f64687e9c1699f49bdd",
            "osx-x64": "cf62e9cf6ea0080a97453dabe156e2511e0d780d8832caec0e75d10bb3c4702d",
        ],
        "0.111.1": [
            "osx-arm64": "cbc18ded59fa79aca4a0d53c0c761c1c244aa251c0e7a9f4cedd58707365d8c4",
            "osx-x64": "80bbc4720456605848d9b2c4b004eafc147990a29a0075ca46b303637ffef1aa",
        ],
        "0.111.2": [
            "osx-arm64": "efda00a9f91353be1b78b7b38ab6fab12b5871c50e5648c6632fb44059da33f8",
            "osx-x64": "1c0f7d106e8847146eb2b8fadcae475361e0998d92138c59b81af4093f155eb3",
        ],
        "0.111.3": [
            "osx-arm64": "e509136aeb38244a2ad2740d86a07a92a720bb130d8547eabc63ce26c73ac001",
            "osx-x64": "792259b20f4f907d8294ac089a4a3786396adf38218c8963aded06d9fdf42114",
        ],
        "0.112.0": [
            "osx-arm64": "6d503dc078637cacdcb4a530a1a5473092d5ec754c65a324b08a253328a9623f",
            "osx-x64": "28789fd9314f964daa2675a3d73dbddc70b3b99c2b8f1463d58f72eae23037ea",
        ],
        "0.113.0": [
            "osx-arm64": "33a7d41acb2da986ab7da8f7b842c961c976fbc1fb6637fac83d64963047bef4",
            "osx-x64": "55e925bfc21cec6eb812663eb8ed0288075fb39bf6e3ecda682c905cf54dfdab",
        ],
        "0.114.0": [
            "osx-arm64": "49fab09698e1b6f175cd907a8b4ed16d7b9010ee7c1ad2b2403f71ae5a7d59b5",
            "osx-x64": "e7662240e93709b4a122bb690caab2caa6ba9c9249002f3bdabf6b30b277fdd7",
        ],
        "0.114.1": [
            "osx-arm64": "aa4e26a58bc502d3b94039b09229083a1b04b93074fb013e6bd7c5513da2d5b9",
            "osx-x64": "f7146c4283f3176015aacc597d44e36af49d52f3e24f0d196d5eb201e01e0f6d",
        ],
        "0.114.2": [
            "osx-arm64": "6eec9796a1d9690a84e2cef042394af2c6f8a5f1b5988556c8864d2cfe234628",
            "osx-x64": "17dff0f6fa16cf427871c97b4abad28151620a5fd6c4d16db30fd28a2aa3c00b",
        ],
        "0.115.0": [
            "osx-arm64": "faa2d8cdda2d772f44bb74acceabdbf5553e861f1f3c1bbd719e45122ac518e4",
            "osx-x64": "6696a20148e70035c5333f6ffd856d693e8fc93f8d3bb9c0152b9d5d22d505c7",
        ],
        "0.116.0": [
            "osx-arm64": "f2209b78fb1832552adc32d28fd314a970277b0f4d32fbb98d68c31625796f6a",
            "osx-x64": "deaf2b81bb90fa04c8e2558d3ec081b5bb060904ec8066fe86350f2cad584a33",
        ],
        "0.117.0": [
            "osx-arm64": "5632dee65120283cace880bfdc76efdad2e6004b53ad2625b971de0c1a622693",
            "osx-x64": "55362f8eb0c3e165c30eef41d1473bbb8cef1876d0ae0c4570200fd84361631d",
        ],
        "0.118.0": [
            "osx-arm64": "0f59d2e7583f798e3efe611fcf4cb21a94a80098ac88f7768cd3eb9e16242625",
            "osx-x64": "8e090933806ff097e46afccb6f5736293a0a2c7cbcd11b2c88b356616e897d86",
        ],
        "0.119.0": [
            "osx-arm64": "c3ccdc011cfba54ce1f04ebdb950579f8ca93522593fd58d601a8335cbbd2146",
            "osx-x64": "67a9f9d2d43e61a5e65f5afa9216ec806b16355fdc0d793f3ae172b860632795",
        ],
        "0.119.1": [
            "osx-arm64": "5e4c8a9476974359ccb2074f5a8c1894b4cb7ea6c073b2a3b1ba7fd8b21dc708",
            "osx-x64": "2cb462219c68e41b3a628e6ba1d51b3c7f2229df8712cbbbc3d3ceedebc1407c",
        ],
        "0.119.2": [
            "osx-arm64": "e72d9f188184e056fb4408a863062b46e6e0b4f3c8ebe0cd8836ca91a45dd11b",
            "osx-x64": "5c91460473059a14b6689ad43937928d12d03c2bfc8cf4dfcfa74cb1e52975c9",
        ],
        "0.120.0": [
            "osx-arm64": "08ed271fb32b41009c96761c3b292bcf9eeeed79aacb64b7b71a54c6563f6e42",
            "osx-x64": "13d9ce81f9de4bfc49df5abb3a947a5d3e275b17f0a43cd1a8271575f3266da5",
        ],
    ]

    /// The listed releases in the shape the chooser reads.
    static let index: [NWJSRuntime.IndexEntry] = archives.map { version, flavors in
        NWJSRuntime.IndexEntry(version: version, flavors: Array(flavors.keys))
    }
}
