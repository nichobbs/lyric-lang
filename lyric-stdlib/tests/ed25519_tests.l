//! Std.Ed25519 tests: the RFC 8032 section 7.1 vectors, the Wycheproof
//! ed25519 verification vectors (C2SP/wycheproof testvectors_v1/ed25519_test.json),
//! and the strict-verification edge cases of D248 Decision 2.
//!
//! The Wycheproof table is generated: each case's expected result is
//! Wycheproof's ("valid" must verify, "invalid" must not). Its "acceptable"
//! cases are pinned to this implementation's policy: a small-order public key
//! is rejected, and a mixed-order key is accepted when the cofactorless
//! equation holds.
package Std.Ed25519.Tests

import Std.Core
import Std.Collections
import Std.Encoding
import Std.Ed25519
import Std.Testing

record Rfc8032Vector {
  name: String
  seed: String
  publicKey: String
  message: String
  signature: String
}

record VerifyCase {
  id: Int
  publicKey: String
  message: String
  signature: String
  expected: Bool
}

func hexBytes(s: in String): slice[Byte] {
  match tryDecodeHex(s) {
    case Some(b) -> b
    case None -> panic("bad hex in test data: " + s)
  }
}

func lower(b: in slice[Byte]): String {
  encodeHex(b).toLower()
}

func rfc8032Vectors(): List[Rfc8032Vector] {
  val v: List[Rfc8032Vector] = newList()
  v.add(
    Rfc8032Vector(
      name = "1",
      seed = "9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60",
      publicKey = "d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a",
      message = "",
      signature = "e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e065224901555fb8821590a33bacc61e39701cf9b46b" +
        "d25bf5f0595bbe24655141438e7a100b"
    )
  )
  v.add(
    Rfc8032Vector(
      name = "2",
      seed = "4ccd089b28ff96da9db6c346ec114e0f5b8a319f35aba624da8cf6ed4fb8a6fb",
      publicKey = "3d4017c3e843895a92b70aa74d1b7ebc9c982ccf2ec4968cc0cd55f12af4660c",
      message = "72",
      signature = "92a009a9f0d4cab8720e820b5f642540a2b27b5416503f8fb3762223ebdb69da085ac1e43e15996e458f3613d0f11d8c" +
        "387b2eaeb4302aeeb00d291612bb0c00"
    )
  )
  v.add(
    Rfc8032Vector(
      name = "3",
      seed = "c5aa8df43f9f837bedb7442f31dcb7b166d38535076f094b85ce3a2e0b4458f7",
      publicKey = "fc51cd8e6218a1a38da47ed00230f0580816ed13ba3303ac5deb911548908025",
      message = "af82",
      signature = "6291d657deec24024827e69c3abe01a30ce548a284743a445e3680d7db5ac3ac18ff9b538d16f290ae67f760984dc659" +
        "4a7c15e9716ed28dc027beceea1ec40a"
    )
  )
  v.add(
    Rfc8032Vector(
      name = "1024",
      seed = "f5e5767cf153319517630f226876b86c8160cc583bc013744c6bf255f5cc0ee5",
      publicKey = "278117fc144c72340f67d0f2316e8386ceffbf2b2428c9c51fef7c597f1d426e",
      message = "08b8b2b733424243760fe426a4b54908632110a66c2f6591eabd3345e3e4eb98fa6e264bf09efe12ee50f8f54e9f77b1" +
        "e355f6c50544e23fb1433ddf73be84d879de7c0046dc4996d9e773f4bc9efe5738829adb26c81b37c93a1b270b20329d" +
        "658675fc6ea534e0810a4432826bf58c941efb65d57a338bbd2e26640f89ffbc1a858efcb8550ee3a5e1998bd177e93a" +
        "7363c344fe6b199ee5d02e82d522c4feba15452f80288a821a579116ec6dad2b3b310da903401aa62100ab5d1a36553e" +
        "06203b33890cc9b832f79ef80560ccb9a39ce767967ed628c6ad573cb116dbefefd75499da96bd68a8a97b928a8bbc10" +
        "3b6621fcde2beca1231d206be6cd9ec7aff6f6c94fcd7204ed3455c68c83f4a41da4af2b74ef5c53f1d8ac70bdcb7ed1" +
        "85ce81bd84359d44254d95629e9855a94a7c1958d1f8ada5d0532ed8a5aa3fb2d17ba70eb6248e594e1a2297acbbb39d" +
        "502f1a8c6eb6f1ce22b3de1a1f40cc24554119a831a9aad6079cad88425de6bde1a9187ebb6092cf67bf2b13fd65f270" +
        "88d78b7e883c8759d2c4f5c65adb7553878ad575f9fad878e80a0c9ba63bcbcc2732e69485bbc9c90bfbd62481d9089b" +
        "eccf80cfe2df16a2cf65bd92dd597b0707e0917af48bbb75fed413d238f5555a7a569d80c3414a8d0859dc65a46128ba" +
        "b27af87a71314f318c782b23ebfe808b82b0ce26401d2e22f04d83d1255dc51addd3b75a2b1ae0784504df543af8969b" +
        "e3ea7082ff7fc9888c144da2af58429ec96031dbcad3dad9af0dcbaaaf268cb8fcffead94f3c7ca495e056a9b47acdb7" +
        "51fb73e666c6c655ade8297297d07ad1ba5e43f1bca32301651339e22904cc8c42f58c30c04aafdb038dda0847dd988d" +
        "cda6f3bfd15c4b4c4525004aa06eeff8ca61783aacec57fb3d1f92b0fe2fd1a85f6724517b65e614ad6808d6f6ee34df" +
        "f7310fdc82aebfd904b01e1dc54b2927094b2db68d6f903b68401adebf5a7e08d78ff4ef5d63653a65040cf9bfd4aca7" +
        "984a74d37145986780fc0b16ac451649de6188a7dbdf191f64b5fc5e2ab47b57f7f7276cd419c17a3ca8e1b939ae49e4" +
        "88acba6b965610b5480109c8b17b80e1b7b750dfc7598d5d5011fd2dcc5600a32ef5b52a1ecc820e308aa342721aac09" +
        "43bf6686b64b2579376504ccc493d97e6aed3fb0f9cd71a43dd497f01f17c0e2cb3797aa2a2f256656168e6c496afc5f" +
        "b93246f6b1116398a346f1a641f3b041e989f7914f90cc2c7fff357876e506b50d334ba77c225bc307ba537152f3f161" +
        "0e4eafe595f6d9d90d11faa933a15ef1369546868a7f3a45a96768d40fd9d03412c091c6315cf4fde7cb68606937380d" +
        "b2eaaa707b4c4185c32eddcdd306705e4dc1ffc872eeee475a64dfac86aba41c0618983f8741c5ef68d3a101e8a3b8ca" +
        "c60c905c15fc910840b94c00a0b9d0",
      signature = "0aab4c900501b3e24d7cdf4663326a3a87df5e4843b2cbdb67cbf6e460fec350aa5371b1508f9f4528ecea23c436d94b" +
        "5e8fcd4f681e30a6ac00a9704a188a03"
    )
  )
  v.add(
    Rfc8032Vector(
      name = "SHA(abc)",
      seed = "833fe62409237b9d62ec77587520911e9a759cec1d19755b7da901b96dca3d42",
      publicKey = "ec172b93ad5e563bf4932c70e1245034c35467ef2efd4d64ebf819683467e2bf",
      message = "ddaf35a193617abacc417349ae20413112e6fa4e89a97ea20a9eeee64b55d39a2192992a274fc1a836ba3c23a3feebbd" +
        "454d4423643ce80e2a9ac94fa54ca49f",
      signature = "dc2a4459e7369633a52b1bf277839a00201009a3efbf3ecb69bea2186c26b58909351fc9ac90b3ecfdfbc7c66431e030" +
        "3dca179c138ac17ad9bef1177331a704"
    )
  )
  v
}

func wycheproofCases0(): List[VerifyCase] {
  val v: List[VerifyCase] = newList()
  v.add(
    VerifyCase(
      id = 1,
      publicKey = "7d4d0e7f6153a69b6242b522abbee685fda4420f8834b108c3bdae369ef549fa",
      message = "",
      signature = "d4fbdb52bfa726b44d1786a8c0d171c3e62ca83c9e5bbe63de0bb2483f8fd6cc1429ab72cafc41ab56af02ff8fcc43b9" +
        "9bfe4c7ae940f60f38ebaa9d311c4007",
      expected = true
    )
  )
  v.add(
    VerifyCase(
      id = 2,
      publicKey = "7d4d0e7f6153a69b6242b522abbee685fda4420f8834b108c3bdae369ef549fa",
      message = "78",
      signature = "d80737358ede548acb173ef7e0399f83392fe8125b2ce877de7975d8b726ef5b1e76632280ee38afad12125ea44b961b" +
        "f92f1178c9fa819d020869975bcbe109",
      expected = true
    )
  )
  v.add(
    VerifyCase(
      id = 3,
      publicKey = "7d4d0e7f6153a69b6242b522abbee685fda4420f8834b108c3bdae369ef549fa",
      message = "54657374",
      signature = "7c38e026f29e14aabd059a0f2db8b0cd783040609a8be684db12f82a27774ab07a9155711ecfaf7f99f277bad0c6ae7e" +
        "39d4eef676573336a5c51eb6f946b30d",
      expected = true
    )
  )
  v.add(
    VerifyCase(
      id = 4,
      publicKey = "7d4d0e7f6153a69b6242b522abbee685fda4420f8834b108c3bdae369ef549fa",
      message = "48656c6c6f",
      signature = "1c1ad976cbaae3b31dee07971cf92c928ce2091a85f5899f5e11ecec90fc9f8e93df18c5037ec9b29c07195ad284e63d" +
        "548cd0a6fe358cc775bd6c1608d2c905",
      expected = true
    )
  )
  v.add(
    VerifyCase(
      id = 5,
      publicKey = "7d4d0e7f6153a69b6242b522abbee685fda4420f8834b108c3bdae369ef549fa",
      message = "313233343030",
      signature = "657c1492402ab5ce03e2c3a7f0384d051b9cf3570f1207fc78c1bcc98c281c2bf0cf5b3a289976458a1be6277a505554" +
        "5253b45b07dcc1abd96c8b989c00f301",
      expected = true
    )
  )
  v.add(
    VerifyCase(
      id = 6,
      publicKey = "7d4d0e7f6153a69b6242b522abbee685fda4420f8834b108c3bdae369ef549fa",
      message = "000000000000000000000000",
      signature = "d46543bfb892f84ec124dcdfc847034c19363bf3fc2fa89b1267833a14856e52e60736918783f950b6f1dd8d40dc3432" +
        "47cd43ce054c2d68ef974f7ed0f3c60f",
      expected = true
    )
  )
  v.add(
    VerifyCase(
      id = 7,
      publicKey = "7d4d0e7f6153a69b6242b522abbee685fda4420f8834b108c3bdae369ef549fa",
      message = "616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161" +
        "6161616161616161616161616161616161",
      signature = "879350045543bc14ed2c08939b68c30d22251d83e018cacbaf0c9d7a48db577e80bdf76ce99e5926762bc13b7b348326" +
        "0a5ef63d07e34b58eb9c14621ac92f00",
      expected = true
    )
  )
  v.add(
    VerifyCase(
      id = 8,
      publicKey = "7d4d0e7f6153a69b6242b522abbee685fda4420f8834b108c3bdae369ef549fa",
      message = "202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f404142434445464748494a4b4c4d4e4f" +
        "505152535455565758595a5b5c5d5e5f60",
      signature = "7bdc3f9919a05f1d5db4a3ada896094f6871c1f37afc75db82ec3147d84d6f237b7e5ecc26b59cfea0c7eaf1052dc427" +
        "b0f724615be9c3d3e01356c65b9b5109",
      expected = true
    )
  )
  v.add(
    VerifyCase(
      id = 9,
      publicKey = "7d4d0e7f6153a69b6242b522abbee685fda4420f8834b108c3bdae369ef549fa",
      message = "ffffffffffffffffffffffffffffffff",
      signature = "5dbd7360e55aa38e855d6ad48c34bd35b7871628508906861a7c4776765ed7d1e13d910faabd689ec8618b78295c8ab8" +
        "f0e19c8b4b43eb8685778499e943ae04",
      expected = true
    )
  )
  v.add(
    VerifyCase(
      id = 10,
      publicKey = "7d4d0e7f6153a69b6242b522abbee685fda4420f8834b108c3bdae369ef549fa",
      message = "3f",
      signature = "000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000" +
        "00000000000000000000000000000000",
      expected = false
    )
  )
  v.add(
    VerifyCase(
      id = 11,
      publicKey = "7d4d0e7f6153a69b6242b522abbee685fda4420f8834b108c3bdae369ef549fa",
      message = "3f",
      signature = "000000000000000000000000000000000000000000000000000000000000000001000000000000000000000000000000" +
        "00000000000000000000000000000000",
      expected = false
    )
  )
  v.add(
    VerifyCase(
      id = 12,
      publicKey = "7d4d0e7f6153a69b6242b522abbee685fda4420f8834b108c3bdae369ef549fa",
      message = "3f",
      signature = "0000000000000000000000000000000000000000000000000000000000000000ecd3f55c1a631258d69cf7a2def9de14" +
        "00000000000000000000000000000010",
      expected = false
    )
  )
  v.add(
    VerifyCase(
      id = 13,
      publicKey = "7d4d0e7f6153a69b6242b522abbee685fda4420f8834b108c3bdae369ef549fa",
      message = "3f",
      signature = "0000000000000000000000000000000000000000000000000000000000000000edd3f55c1a631258d69cf7a2def9de14" +
        "00000000000000000000000000000010",
      expected = false
    )
  )
  v.add(
    VerifyCase(
      id = 14,
      publicKey = "7d4d0e7f6153a69b6242b522abbee685fda4420f8834b108c3bdae369ef549fa",
      message = "3f",
      signature = "0000000000000000000000000000000000000000000000000000000000000000edffffffffffffffffffffffffffffff" +
        "ffffffffffffffffffffffffffffff7f",
      expected = false
    )
  )
  v.add(
    VerifyCase(
      id = 15,
      publicKey = "7d4d0e7f6153a69b6242b522abbee685fda4420f8834b108c3bdae369ef549fa",
      message = "3f",
      signature = "010000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000" +
        "00000000000000000000000000000000",
      expected = false
    )
  )
  v.add(
    VerifyCase(
      id = 16,
      publicKey = "7d4d0e7f6153a69b6242b522abbee685fda4420f8834b108c3bdae369ef549fa",
      message = "3f",
      signature = "010000000000000000000000000000000000000000000000000000000000000001000000000000000000000000000000" +
        "00000000000000000000000000000000",
      expected = false
    )
  )
  v.add(
    VerifyCase(
      id = 17,
      publicKey = "7d4d0e7f6153a69b6242b522abbee685fda4420f8834b108c3bdae369ef549fa",
      message = "3f",
      signature = "0100000000000000000000000000000000000000000000000000000000000000ecd3f55c1a631258d69cf7a2def9de14" +
        "00000000000000000000000000000010",
      expected = false
    )
  )
  v.add(
    VerifyCase(
      id = 18,
      publicKey = "7d4d0e7f6153a69b6242b522abbee685fda4420f8834b108c3bdae369ef549fa",
      message = "3f",
      signature = "0100000000000000000000000000000000000000000000000000000000000000edd3f55c1a631258d69cf7a2def9de14" +
        "00000000000000000000000000000010",
      expected = false
    )
  )
  v.add(
    VerifyCase(
      id = 19,
      publicKey = "7d4d0e7f6153a69b6242b522abbee685fda4420f8834b108c3bdae369ef549fa",
      message = "3f",
      signature = "0100000000000000000000000000000000000000000000000000000000000000edffffffffffffffffffffffffffffff" +
        "ffffffffffffffffffffffffffffff7f",
      expected = false
    )
  )
  v.add(
    VerifyCase(
      id = 20,
      publicKey = "7d4d0e7f6153a69b6242b522abbee685fda4420f8834b108c3bdae369ef549fa",
      message = "3f",
      signature = "edd3f55c1a631258d69cf7a2def9de140000000000000000000000000000001000000000000000000000000000000000" +
        "00000000000000000000000000000000",
      expected = false
    )
  )
  v.add(
    VerifyCase(
      id = 21,
      publicKey = "7d4d0e7f6153a69b6242b522abbee685fda4420f8834b108c3bdae369ef549fa",
      message = "3f",
      signature = "edd3f55c1a631258d69cf7a2def9de140000000000000000000000000000001001000000000000000000000000000000" +
        "00000000000000000000000000000000",
      expected = false
    )
  )
  v.add(
    VerifyCase(
      id = 22,
      publicKey = "7d4d0e7f6153a69b6242b522abbee685fda4420f8834b108c3bdae369ef549fa",
      message = "3f",
      signature = "edd3f55c1a631258d69cf7a2def9de1400000000000000000000000000000010ecd3f55c1a631258d69cf7a2def9de14" +
        "00000000000000000000000000000010",
      expected = false
    )
  )
  v.add(
    VerifyCase(
      id = 23,
      publicKey = "7d4d0e7f6153a69b6242b522abbee685fda4420f8834b108c3bdae369ef549fa",
      message = "3f",
      signature = "edd3f55c1a631258d69cf7a2def9de1400000000000000000000000000000010edd3f55c1a631258d69cf7a2def9de14" +
        "00000000000000000000000000000010",
      expected = false
    )
  )
  v.add(
    VerifyCase(
      id = 24,
      publicKey = "7d4d0e7f6153a69b6242b522abbee685fda4420f8834b108c3bdae369ef549fa",
      message = "3f",
      signature = "edd3f55c1a631258d69cf7a2def9de1400000000000000000000000000000010edffffffffffffffffffffffffffffff" +
        "ffffffffffffffffffffffffffffff7f",
      expected = false
    )
  )
  v.add(
    VerifyCase(
      id = 25,
      publicKey = "7d4d0e7f6153a69b6242b522abbee685fda4420f8834b108c3bdae369ef549fa",
      message = "3f",
      signature = "edffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f00000000000000000000000000000000" +
        "00000000000000000000000000000000",
      expected = false
    )
  )
  v.add(
    VerifyCase(
      id = 26,
      publicKey = "7d4d0e7f6153a69b6242b522abbee685fda4420f8834b108c3bdae369ef549fa",
      message = "3f",
      signature = "edffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f01000000000000000000000000000000" +
        "00000000000000000000000000000000",
      expected = false
    )
  )
  v.add(
    VerifyCase(
      id = 27,
      publicKey = "7d4d0e7f6153a69b6242b522abbee685fda4420f8834b108c3bdae369ef549fa",
      message = "3f",
      signature = "edffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7fecd3f55c1a631258d69cf7a2def9de14" +
        "00000000000000000000000000000010",
      expected = false
    )
  )
  v.add(
    VerifyCase(
      id = 28,
      publicKey = "7d4d0e7f6153a69b6242b522abbee685fda4420f8834b108c3bdae369ef549fa",
      message = "3f",
      signature = "edffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7fedd3f55c1a631258d69cf7a2def9de14" +
        "00000000000000000000000000000010",
      expected = false
    )
  )
  v.add(
    VerifyCase(
      id = 29,
      publicKey = "7d4d0e7f6153a69b6242b522abbee685fda4420f8834b108c3bdae369ef549fa",
      message = "3f",
      signature = "edffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7fedffffffffffffffffffffffffffffff" +
        "ffffffffffffffffffffffffffffff7f",
      expected = false
    )
  )
  v.add(
    VerifyCase(
      id = 30,
      publicKey = "7d4d0e7f6153a69b6242b522abbee685fda4420f8834b108c3bdae369ef549fa",
      message = "54657374",
      signature = "",
      expected = false
    )
  )
  v
}

func wycheproofCases1(): List[VerifyCase] {
  val v: List[VerifyCase] = newList()
  v.add(
    VerifyCase(
      id = 31,
      publicKey = "7d4d0e7f6153a69b6242b522abbee685fda4420f8834b108c3bdae369ef549fa",
      message = "54657374",
      signature = "7c38e026f29e14aabd059a0f2db8b0cd783040609a8be684db12f82a27774ab0",
      expected = false
    )
  )
  v.add(
    VerifyCase(
      id = 32,
      publicKey = "7d4d0e7f6153a69b6242b522abbee685fda4420f8834b108c3bdae369ef549fa",
      message = "54657374",
      signature = "7c38e026f29e14aabd059a0f2db8b0cd783040609a8be684db12f82a27774ab07a9155711ecfaf7f99f277bad0c6ae7e" +
        "39d4eef676573336a5c51eb6f946",
      expected = false
    )
  )
  v.add(
    VerifyCase(
      id = 33,
      publicKey = "7d4d0e7f6153a69b6242b522abbee685fda4420f8834b108c3bdae369ef549fa",
      message = "54657374",
      signature = "7c38e026f29e14aabd059a0f2db8b0cd783040609a8be684db12f82a27774ab07a9155711ecfaf7f99f277bad0c6ae7e" +
        "39d4eef676573336a5c51eb6f946b30d2020",
      expected = false
    )
  )
  v.add(
    VerifyCase(
      id = 34,
      publicKey = "7d4d0e7f6153a69b6242b522abbee685fda4420f8834b108c3bdae369ef549fa",
      message = "54657374",
      signature = "7c38e026f29e14aabd059a0f2db8b0cd783040609a8be684db12f82a27774ab07a9155711ecfaf7f99f277bad0c6ae7e" +
        "39d4eef676573336a5c51eb6f946b30d7d4d0e7f6153a69b6242b522abbee685fda4420f8834b108c3bdae369ef549fa",
      expected = false
    )
  )
  v.add(
    VerifyCase(
      id = 35,
      publicKey = "7d4d0e7f6153a69b6242b522abbee685fda4420f8834b108c3bdae369ef549fa",
      message = "54657374",
      signature = "007c38e026f29e14aabd059a0f2db8b0cd783040609a8be684db12f82a27774ab07a9155711ecfaf7f99f277bad0c6ae" +
        "7e39d4eef676573336a5c51eb6f946b30d",
      expected = false
    )
  )
  v.add(
    VerifyCase(
      id = 36,
      publicKey = "7d4d0e7f6153a69b6242b522abbee685fda4420f8834b108c3bdae369ef549fa",
      message = "54657374",
      signature = "7c38e026f29e14aabd059a0f2db8b0cd783040609a8be684db12f82a27774ab0007a9155711ecfaf7f99f277bad0c6ae" +
        "7e39d4eef676573336a5c51eb6f946b30d",
      expected = false
    )
  )
  v.add(
    VerifyCase(
      id = 37,
      publicKey = "7d4d0e7f6153a69b6242b522abbee685fda4420f8834b108c3bdae369ef549fa",
      message = "54657374",
      signature = "7c38e026f29e14aabd059a0f2db8b0cd783040609a8be684db12f82a27774ab07a9155711ecfaf7f99f277bad0c6ae7e" +
        "39d4eef676573336a5c51eb6f946b30d00",
      expected = false
    )
  )
  v.add(
    VerifyCase(
      id = 38,
      publicKey = "7d4d0e7f6153a69b6242b522abbee685fda4420f8834b108c3bdae369ef549fa",
      message = "546573743137",
      signature = "93de3ca252426c95f735cb9edd92e83321ac62372d5aa5b379786bae111ab6b17251330e8f9a7c30d6993137c596007d" +
        "7b001409287535ac4804e662bc58a3",
      expected = false
    )
  )
  v.add(
    VerifyCase(
      id = 39,
      publicKey = "7d4d0e7f6153a69b6242b522abbee685fda4420f8834b108c3bdae369ef549fa",
      message = "54657374313236",
      signature = "dffed33a7f420b62bb1731cfd03be805affd18a281ec02b1067ba6e9d20826569e742347df59c88ae96db1f1969fb189" +
        "b0ec34381d85633e1889da48d95e0e",
      expected = false
    )
  )
  v.add(
    VerifyCase(
      id = 40,
      publicKey = "7d4d0e7f6153a69b6242b522abbee685fda4420f8834b108c3bdae369ef549fa",
      message = "546573743530",
      signature = "6e170c719577c25e0e1e8b8aa7a6346f8b109f37385cc2e85dc3b4c0f46a9c6bcafd67f52324c5dbaf40a1b673fb29c4" +
        "a56052d2d6999d0838a8337bccb502",
      expected = false
    )
  )
  v.add(
    VerifyCase(
      id = 41,
      publicKey = "7d4d0e7f6153a69b6242b522abbee685fda4420f8834b108c3bdae369ef549fa",
      message = "54657374333437",
      signature = "b0928b46e99fbbad3f5cb502d2cd309d94a7e86cfd4d84b1fcf4cea18075a9c36993c0582dba1e9e519fae5a8654f454" +
        "201ae0c3cb397c37b8f4f8eef18400",
      expected = false
    )
  )
  v.add(
    VerifyCase(
      id = 42,
      publicKey = "7d4d0e7f6153a69b6242b522abbee685fda4420f8834b108c3bdae369ef549fa",
      message = "313233343030",
      signature = "647c1492402ab5ce03e2c3a7f0384d051b9cf3570f1207fc78c1bcc98c281c2b1d125e5538f38afbcc1c84e489521083" +
        "041d24bc6240767029da063271a1ff0c",
      expected = false
    )
  )
  v.add(
    VerifyCase(
      id = 43,
      publicKey = "7d4d0e7f6153a69b6242b522abbee685fda4420f8834b108c3bdae369ef549fa",
      message = "313233343030",
      signature = "677c1492402ab5ce03e2c3a7f0384d051b9cf3570f1207fc78c1bcc98c281c2bc108ca4b87a49c9ed2cf383aecad8f54" +
        "a962b2899da891e12004d7993a627e01",
      expected = false
    )
  )
  v.add(
    VerifyCase(
      id = 44,
      publicKey = "7d4d0e7f6153a69b6242b522abbee685fda4420f8834b108c3bdae369ef549fa",
      message = "313233343030",
      signature = "617c1492402ab5ce03e2c3a7f0384d051b9cf3570f1207fc78c1bcc98c281c2b9ce23fc6213ed5b87912e9bbf92f5e2c" +
        "780eae26d15c50a112d1e97d2ea33c06",
      expected = false
    )
  )
  v.add(
    VerifyCase(
      id = 45,
      publicKey = "7d4d0e7f6153a69b6242b522abbee685fda4420f8834b108c3bdae369ef549fa",
      message = "313233343030",
      signature = "e57c1492402ab5ce03e2c3a7f0384d051b9cf3570f1207fc78c1bcc98c281c2bbb3eb51cd98dddb235a5f46f2bded6af" +
        "184a58d09cce928bda43f41d69118a03",
      expected = false
    )
  )
  v.add(
    VerifyCase(
      id = 46,
      publicKey = "7d4d0e7f6153a69b6242b522abbee685fda4420f8834b108c3bdae369ef549fa",
      message = "313233343030",
      signature = "657d1492402ab5ce03e2c3a7f0384d051b9cf3570f1207fc78c1bcc98c281c2bcd237dda9a116501f67a5705a854b9ad" +
        "c304f34720803a91b324f2c13e0f5a09",
      expected = false
    )
  )
  v.add(
    VerifyCase(
      id = 47,
      publicKey = "7d4d0e7f6153a69b6242b522abbee685fda4420f8834b108c3bdae369ef549fa",
      message = "313233343030",
      signature = "657c1592402ab5ce03e2c3a7f0384d051b9cf3570f1207fc78c1bcc98c281c2b6b167bbdc0d881cc04d28905552c1876" +
        "f3709851abc5007376940cc8a435c300",
      expected = false
    )
  )
  v.add(
    VerifyCase(
      id = 48,
      publicKey = "7d4d0e7f6153a69b6242b522abbee685fda4420f8834b108c3bdae369ef549fa",
      message = "313233343030",
      signature = "657c1412402ab5ce03e2c3a7f0384d051b9cf3570f1207fc78c1bcc98c281c2b7fd2ac7da14afffcceeb13f2a0d6b887" +
        "941cb1a5eb57a52f3cb131a16cce7b0e",
      expected = false
    )
  )
  v.add(
    VerifyCase(
      id = 49,
      publicKey = "7d4d0e7f6153a69b6242b522abbee685fda4420f8834b108c3bdae369ef549fa",
      message = "313233343030",
      signature = "657c1492412ab5ce03e2c3a7f0384d051b9cf3570f1207fc78c1bcc98c281c2b7373ba13ebbef99cd2a8ead55ce735c9" +
        "87d85a35320925a8e871702dc7c5c40d",
      expected = false
    )
  )
  v.add(
    VerifyCase(
      id = 50,
      publicKey = "7d4d0e7f6153a69b6242b522abbee685fda4420f8834b108c3bdae369ef549fa",
      message = "313233343030",
      signature = "657c1492402ab54e03e2c3a7f0384d051b9cf3570f1207fc78c1bcc98c281c2bd35bd331c03f0855504ca1cab87b83c3" +
        "6a028425a3cf007ede4f4254c261cb00",
      expected = false
    )
  )
  v.add(
    VerifyCase(
      id = 51,
      publicKey = "7d4d0e7f6153a69b6242b522abbee685fda4420f8834b108c3bdae369ef549fa",
      message = "313233343030",
      signature = "657c1492402ab5ce02e2c3a7f0384d051b9cf3570f1207fc78c1bcc98c281c2bcb35101f73cf467deac8c1a03b6c3dc3" +
        "5af544132734b7e57ab20c89b2e4750d",
      expected = false
    )
  )
  v.add(
    VerifyCase(
      id = 52,
      publicKey = "7d4d0e7f6153a69b6242b522abbee685fda4420f8834b108c3bdae369ef549fa",
      message = "313233343030",
      signature = "657c1492402ab5ce03e2c3a7f2384d051b9cf3570f1207fc78c1bcc98c281c2bb58d2e8878290bff8d3355fdd4ea3819" +
        "24ee578752354eb6dee678ab4011c301",
      expected = false
    )
  )
  v.add(
    VerifyCase(
      id = 53,
      publicKey = "7d4d0e7f6153a69b6242b522abbee685fda4420f8834b108c3bdae369ef549fa",
      message = "313233343030",
      signature = "657c1492402ab5ce03e2c3a7f0384d851b9cf3570f1207fc78c1bcc98c281c2bb978c866187ffb1cc7b29a0b4045aefc" +
        "08768df65717194ff0c6e63f4dea0d02",
      expected = false
    )
  )
  v.add(
    VerifyCase(
      id = 54,
      publicKey = "7d4d0e7f6153a69b6242b522abbee685fda4420f8834b108c3bdae369ef549fa",
      message = "313233343030",
      signature = "657c1492402ab5ce03e2c3a7f0384d051b9cf3570f1207fc78c1bcc98c281d2b0576ecf8eaf675f00f3dfbe19f75b83b" +
        "7607a6c96414f6821af920a2498d0305",
      expected = false
    )
  )
  v.add(
    VerifyCase(
      id = 55,
      publicKey = "7d4d0e7f6153a69b6242b522abbee685fda4420f8834b108c3bdae369ef549fa",
      message = "313233343030",
      signature = "657c1492402ab5ce03e2c3a7f0384d051b9cf3570f1207fc78c1bcc98c289c2be5241a345c7b5428054c74b7c382fa10" +
        "d4a5f1e8f8b79a71d3fdea2254f1ff0e",
      expected = false
    )
  )
  v.add(
    VerifyCase(
      id = 56,
      publicKey = "7d4d0e7f6153a69b6242b522abbee685fda4420f8834b108c3bdae369ef549fa",
      message = "313233343030",
      signature = "657c1492402ab5ce03e2c3a7f0384d051b9cf3570f1207fc78c1bcc98c281c2a63950c85cd6dc96364e768de50ff7732" +
        "b538f8a0b1615d799190ab600849230e",
      expected = false
    )
  )
  v.add(
    VerifyCase(
      id = 57,
      publicKey = "7d4d0e7f6153a69b6242b522abbee685fda4420f8834b108c3bdae369ef549fa",
      message = "313233343030",
      signature = "657c1492402ab5ce03e2c3a7f0384d051b9cf3570f1207fc78c1bcc98c281c0b543bd3da0a56a8c9c152f59c9fec12f3" +
        "1fa66434d48b817b30d90cb4efa8b501",
      expected = false
    )
  )
  v.add(
    VerifyCase(
      id = 58,
      publicKey = "7d4d0e7f6153a69b6242b522abbee685fda4420f8834b108c3bdae369ef549fa",
      message = "313233343030",
      signature = "657c1492402ab5ce03e2c3a7f0384d051b9cf3570f1207fc78c1bcc98c281c6b8da07efd07a6dafb015ed6a32fe13631" +
        "9a972ffbc341f3a0beae97ccf8136505",
      expected = false
    )
  )
  v.add(
    VerifyCase(
      id = 59,
      publicKey = "7d4d0e7f6153a69b6242b522abbee685fda4420f8834b108c3bdae369ef549fa",
      message = "313233343030",
      signature = "657c1492402ab5ce03e2c3a7f0384d051b9cf3570f1207fc78c1bcc98c281cab227aedf259f910f0f3a759a335062665" +
        "217925d019173b88917eae294f75d40f",
      expected = false
    )
  )
  v.add(
    VerifyCase(
      id = 60,
      publicKey = "7d4d0e7f6153a69b6242b522abbee685fda4420f8834b108c3bdae369ef549fa",
      message = "313233343030",
      signature = "0000000000000000000000000000000000000000000000000000000000000000e0b8e7770d51c7a36375d006c5bffd6a" +
        "f43ff54aaf47e4330dc118c71d61ec02",
      expected = false
    )
  )
  v
}

func wycheproofCases2(): List[VerifyCase] {
  val v: List[VerifyCase] = newList()
  v.add(
    VerifyCase(
      id = 61,
      publicKey = "7d4d0e7f6153a69b6242b522abbee685fda4420f8834b108c3bdae369ef549fa",
      message = "313233343030",
      signature = "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff463a1908382e7eb7693acef9884f7cf9" +
        "31a215e0791876be22c631a59881fd0e",
      expected = false
    )
  )
  v.add(
    VerifyCase(
      id = 62,
      publicKey = "7d4d0e7f6153a69b6242b522abbee685fda4420f8834b108c3bdae369ef549fa",
      message = "313233343030",
      signature = "9a83eb6dbfd54a31fc1d3c580fc7b2fae4630ca8f0edf803873e433673d7e3d40e94254586cb6188c5386c3febed477c" +
        "b9a6cb29e3979adc4cb27cf5278fb70a",
      expected = false
    )
  )
  v.add(
    VerifyCase(
      id = 63,
      publicKey = "7d4d0e7f6153a69b6242b522abbee685fda4420f8834b108c3bdae369ef549fa",
      message = "54657374",
      signature = "7c38e026f29e14aabd059a0f2db8b0cd783040609a8be684db12f82a27774ab067654bce3832c2d76f8f6f5dafc08d93" +
        "39d4eef676573336a5c51eb6f946b31d",
      expected = false
    )
  )
  v.add(
    VerifyCase(
      id = 64,
      publicKey = "7d4d0e7f6153a69b6242b522abbee685fda4420f8834b108c3bdae369ef549fa",
      message = "54657374",
      signature = "7c38e026f29e14aabd059a0f2db8b0cd783040609a8be684db12f82a27774ab05439412b5395d42f462c67008eba6ca8" +
        "39d4eef676573336a5c51eb6f946b32d",
      expected = false
    )
  )
  v.add(
    VerifyCase(
      id = 65,
      publicKey = "7d4d0e7f6153a69b6242b522abbee685fda4420f8834b108c3bdae369ef549fa",
      message = "54657374",
      signature = "7c38e026f29e14aabd059a0f2db8b0cd783040609a8be684db12f82a27774ab02ee12ce5875bf9dff26556464bae2ad2" +
        "39d4eef676573336a5c51eb6f946b34d",
      expected = false
    )
  )
  v.add(
    VerifyCase(
      id = 66,
      publicKey = "7d4d0e7f6153a69b6242b522abbee685fda4420f8834b108c3bdae369ef549fa",
      message = "54657374",
      signature = "7c38e026f29e14aabd059a0f2db8b0cd783040609a8be684db12f82a27774ab0e2300459f1e742404cd934d2c595a625" +
        "3ad4eef676573336a5c51eb6f946b38d",
      expected = false
    )
  )
  v.add(
    VerifyCase(
      id = 67,
      publicKey = "7d4d0e7f6153a69b6242b522abbee685fda4420f8834b108c3bdae369ef549fa",
      message = "54657374",
      signature = "7c38e026f29e14aabd059a0f2db8b0cd783040609a8be684db12f82a27774ab07a9155711ecfaf7f99f277bad0c6ae7e" +
        "39d4eef676573336a5c51eb6f946b32d",
      expected = false
    )
  )
  v.add(
    VerifyCase(
      id = 68,
      publicKey = "7d4d0e7f6153a69b6242b522abbee685fda4420f8834b108c3bdae369ef549fa",
      message = "54657374",
      signature = "7c38e026f29e14aabd059a0f2db8b0cd783040609a8be684db12f82a27774ab07a9155711ecfaf7f99f277bad0c6ae7e" +
        "39d4eef676573336a5c51eb6f946b34d",
      expected = false
    )
  )
  v.add(
    VerifyCase(
      id = 69,
      publicKey = "7d4d0e7f6153a69b6242b522abbee685fda4420f8834b108c3bdae369ef549fa",
      message = "54657374",
      signature = "7c38e026f29e14aabd059a0f2db8b0cd783040609a8be684db12f82a27774ab07a9155711ecfaf7f99f277bad0c6ae7e" +
        "39d4eef676573336a5c51eb6f946b38d",
      expected = false
    )
  )
  v.add(
    VerifyCase(
      id = 70,
      publicKey = "7d4d0e7f6153a69b6242b522abbee685fda4420f8834b108c3bdae369ef549fa",
      message = "54657374",
      signature = "7c38e026f29e14aabd059a0f2db8b0cd783040609a8be684db12f82a27774ab0679155711ecfaf7f99f277bad0c6ae7e" +
        "39d4eef676573336a5c51eb6f946b38d",
      expected = false
    )
  )
  v.add(
    VerifyCase(
      id = 71,
      publicKey = "a12c2beb77265f2aac953b5009349d94155a03ada416aad451319480e983ca4c",
      message = "",
      signature = "5056325d2ab440bf30bbf0f7173199aa8b4e6fbc091cf3eb6bc6cf87cd73d992ffc216c85e4ab5b8a0bbc7e9a6e9f8d3" +
        "3b7f6e5ac0ffdc22d9fcaf784af84302",
      expected = true
    )
  )
  v.add(
    VerifyCase(
      id = 72,
      publicKey = "a12c2beb77265f2aac953b5009349d94155a03ada416aad451319480e983ca4c",
      message = "78",
      signature = "481fafbf4364d7b682475282f517a3ac0538c9a6b6a562e99a3d8e5afb4f90a559b056b9f07af023905753b02d95eb32" +
        "9a35c77f154b79abbcd291615ce42f02",
      expected = true
    )
  )
  v.add(
    VerifyCase(
      id = 73,
      publicKey = "a12c2beb77265f2aac953b5009349d94155a03ada416aad451319480e983ca4c",
      message = "54657374",
      signature = "8a9bb4c465a3863abc9fd0dd35d80bb28f7d33d37d74679802d63f82b20da114b8d765a1206b3e9ad7cf2b2d8d778bb8" +
        "651f1fa992db293c0039eacb6161480f",
      expected = true
    )
  )
  v.add(
    VerifyCase(
      id = 74,
      publicKey = "a12c2beb77265f2aac953b5009349d94155a03ada416aad451319480e983ca4c",
      message = "48656c6c6f",
      signature = "d839c20abfda1fd429531831c64f813f84b913e9928540310cf060b44c3dbf9457d44a7721fdc0d67724ff81cb450dd3" +
        "9b10cfb65db15dda4b8bf09d26bd3801",
      expected = true
    )
  )
  v.add(
    VerifyCase(
      id = 75,
      publicKey = "a12c2beb77265f2aac953b5009349d94155a03ada416aad451319480e983ca4c",
      message = "313233343030",
      signature = "9bbb1052dcfa8ad2715c2eb716ae4f1902dea353d42ee09fd4c0b4fcb8b52b5219e2200016e1199d0061891c263e31b0" +
        "bc3b55673c19610c4e0fa5408004160b",
      expected = true
    )
  )
  v.add(
    VerifyCase(
      id = 76,
      publicKey = "a12c2beb77265f2aac953b5009349d94155a03ada416aad451319480e983ca4c",
      message = "000000000000000000000000",
      signature = "f63b5c0667c7897fc283296416f7f60e84bbde9cbd832e56be463ed9f568069702b17a2f7c341ebf590706a6388ac76a" +
        "c613c1675ec0f2c7118f2573422a500b",
      expected = true
    )
  )
  v.add(
    VerifyCase(
      id = 77,
      publicKey = "a12c2beb77265f2aac953b5009349d94155a03ada416aad451319480e983ca4c",
      message = "616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161" +
        "6161616161616161616161616161616161",
      signature = "1bc44d7001e6b5b9090fef34b2ca480f9786bbefa7d279353e5881e8dfb91b803ccd46500e270ef0109bfd7410375588" +
        "32120bc2a4f20fbe7b5fb3c3aaf23e08",
      expected = true
    )
  )
  v.add(
    VerifyCase(
      id = 78,
      publicKey = "a12c2beb77265f2aac953b5009349d94155a03ada416aad451319480e983ca4c",
      message = "202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f404142434445464748494a4b4c4d4e4f" +
        "505152535455565758595a5b5c5d5e5f60",
      signature = "ea8e22143b02372e76e99aece3ed36aec529768a27e2bb49bdc135d44378061e1f62d1ac518f33ebf37b2ee8cc6dde68" +
        "a4bd7d4a2f4d6cb77f015f71ca9fc30d",
      expected = true
    )
  )
  v.add(
    VerifyCase(
      id = 79,
      publicKey = "a12c2beb77265f2aac953b5009349d94155a03ada416aad451319480e983ca4c",
      message = "ffffffffffffffffffffffffffffffff",
      signature = "8acd679e1a914fc45d5fa83d3021f0509c805c8d271df54e52f43cfbd00cb6222bf81d58fe1de2de378df67ee9f45378" +
        "6626961fe50a9b05f12b6f0899ebdd0a",
      expected = true
    )
  )
  v.add(
    VerifyCase(
      id = 80,
      publicKey = "d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a",
      message = "",
      signature = "e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e065224901555fb8821590a33bacc61e39701cf9b46b" +
        "d25bf5f0595bbe24655141438e7a100b",
      expected = true
    )
  )
  v.add(
    VerifyCase(
      id = 81,
      publicKey = "3d4017c3e843895a92b70aa74d1b7ebc9c982ccf2ec4968cc0cd55f12af4660c",
      message = "72",
      signature = "92a009a9f0d4cab8720e820b5f642540a2b27b5416503f8fb3762223ebdb69da085ac1e43e15996e458f3613d0f11d8c" +
        "387b2eaeb4302aeeb00d291612bb0c00",
      expected = true
    )
  )
  v.add(
    VerifyCase(
      id = 82,
      publicKey = "fc51cd8e6218a1a38da47ed00230f0580816ed13ba3303ac5deb911548908025",
      message = "af82",
      signature = "6291d657deec24024827e69c3abe01a30ce548a284743a445e3680d7db5ac3ac18ff9b538d16f290ae67f760984dc659" +
        "4a7c15e9716ed28dc027beceea1ec40a",
      expected = true
    )
  )
  v.add(
    VerifyCase(
      id = 83,
      publicKey = "278117fc144c72340f67d0f2316e8386ceffbf2b2428c9c51fef7c597f1d426e",
      message = "08b8b2b733424243760fe426a4b54908632110a66c2f6591eabd3345e3e4eb98fa6e264bf09efe12ee50f8f54e9f77b1" +
        "e355f6c50544e23fb1433ddf73be84d879de7c0046dc4996d9e773f4bc9efe5738829adb26c81b37c93a1b270b20329d" +
        "658675fc6ea534e0810a4432826bf58c941efb65d57a338bbd2e26640f89ffbc1a858efcb8550ee3a5e1998bd177e93a" +
        "7363c344fe6b199ee5d02e82d522c4feba15452f80288a821a579116ec6dad2b3b310da903401aa62100ab5d1a36553e" +
        "06203b33890cc9b832f79ef80560ccb9a39ce767967ed628c6ad573cb116dbefefd75499da96bd68a8a97b928a8bbc10" +
        "3b6621fcde2beca1231d206be6cd9ec7aff6f6c94fcd7204ed3455c68c83f4a41da4af2b74ef5c53f1d8ac70bdcb7ed1" +
        "85ce81bd84359d44254d95629e9855a94a7c1958d1f8ada5d0532ed8a5aa3fb2d17ba70eb6248e594e1a2297acbbb39d" +
        "502f1a8c6eb6f1ce22b3de1a1f40cc24554119a831a9aad6079cad88425de6bde1a9187ebb6092cf67bf2b13fd65f270" +
        "88d78b7e883c8759d2c4f5c65adb7553878ad575f9fad878e80a0c9ba63bcbcc2732e69485bbc9c90bfbd62481d9089b" +
        "eccf80cfe2df16a2cf65bd92dd597b0707e0917af48bbb75fed413d238f5555a7a569d80c3414a8d0859dc65a46128ba" +
        "b27af87a71314f318c782b23ebfe808b82b0ce26401d2e22f04d83d1255dc51addd3b75a2b1ae0784504df543af8969b" +
        "e3ea7082ff7fc9888c144da2af58429ec96031dbcad3dad9af0dcbaaaf268cb8fcffead94f3c7ca495e056a9b47acdb7" +
        "51fb73e666c6c655ade8297297d07ad1ba5e43f1bca32301651339e22904cc8c42f58c30c04aafdb038dda0847dd988d" +
        "cda6f3bfd15c4b4c4525004aa06eeff8ca61783aacec57fb3d1f92b0fe2fd1a85f6724517b65e614ad6808d6f6ee34df" +
        "f7310fdc82aebfd904b01e1dc54b2927094b2db68d6f903b68401adebf5a7e08d78ff4ef5d63653a65040cf9bfd4aca7" +
        "984a74d37145986780fc0b16ac451649de6188a7dbdf191f64b5fc5e2ab47b57f7f7276cd419c17a3ca8e1b939ae49e4" +
        "88acba6b965610b5480109c8b17b80e1b7b750dfc7598d5d5011fd2dcc5600a32ef5b52a1ecc820e308aa342721aac09" +
        "43bf6686b64b2579376504ccc493d97e6aed3fb0f9cd71a43dd497f01f17c0e2cb3797aa2a2f256656168e6c496afc5f" +
        "b93246f6b1116398a346f1a641f3b041e989f7914f90cc2c7fff357876e506b50d334ba77c225bc307ba537152f3f161" +
        "0e4eafe595f6d9d90d11faa933a15ef1369546868a7f3a45a96768d40fd9d03412c091c6315cf4fde7cb68606937380d" +
        "b2eaaa707b4c4185c32eddcdd306705e4dc1ffc872eeee475a64dfac86aba41c0618983f8741c5ef68d3a101e8a3b8ca" +
        "c60c905c15fc910840b94c00a0b9d0",
      signature = "0aab4c900501b3e24d7cdf4663326a3a87df5e4843b2cbdb67cbf6e460fec350aa5371b1508f9f4528ecea23c436d94b" +
        "5e8fcd4f681e30a6ac00a9704a188a03",
      expected = true
    )
  )
  v.add(
    VerifyCase(
      id = 84,
      publicKey = "100fdf47fb94f1536a4f7c3fda27383fa03375a8f527c537e6f1703c47f94f86",
      message = "124e583f8b8eca58bb29c271b41d36986bbc45541f8e51f9cb0133eca447601e",
      signature = "dac119d6ca87fc59ae611c157048f4d4fc932a149dbe20ec6effd1436abf83ea05c7df0fef06147241259113909bc71b" +
        "d3c53ba4464ffcad3c0968f2ffffff0f",
      expected = true
    )
  )
  v.add(
    VerifyCase(
      id = 85,
      publicKey = "100fdf47fb94f1536a4f7c3fda27383fa03375a8f527c537e6f1703c47f94f86",
      message = "6a0bc2b0057cedfc0fa2e3f7f7d39279b30f454a69dfd1117c758d86b19d85e0",
      signature = "0971f86d2c9c78582524a103cb9cf949522ae528f8054dc20107d999be673ff4e25ebf2f2928766b1248bec6e9169777" +
        "5f8446639ede46ad4df4053000000010",
      expected = false
    )
  )
  v.add(
    VerifyCase(
      id = 86,
      publicKey = "8fd659b77b558ed93882c1157438450ac86ec62d421d568e98ee236f3810295a",
      message = "b0729a713593a92e46b56eaa66b9e435f7a09a8e7de03b078f6f282285276635f301e7aaafe42187c45d6f5b13f9f16b" +
        "11195cc125c05b90d24dfe4c",
      signature = "7db17557ac470c0eda4eedaabce99197ab62565653cf911f632ee8be0e5ffcfc88fb94276b42e0798fd3aa2f0318be7f" +
        "c6a29fae75f70c3dcdc414a0ad866601",
      expected = true
    )
  )
  v.add(
    VerifyCase(
      id = 87,
      publicKey = "2a606bf67ac770c607038b004101b325edb569efd3413d2d1f2c3e6b4e6e3082",
      message = "a8546e50ba31cae3234310d32672447be213fad91a227a19669c53d309b959782b0e6b71f8791fdb470043b581220031" +
        "57d2d96a43a6cbd7d3a8d86bf4c97391883e268d50af80e1e6e12939c2bd50ca746cdadfad4edf1bda87529974072414" +
        "8efb1ebe73fb60088cda890317658627a5f7ab5a0c075d9d8f3f97b6492b35519e50ff6b38377432a7081f9176bb1c29" +
        "a862deac1336ca20b097a47829cec10a6a7cec178eda2d12f6dc6c87f910454af0123555ba184e68804d9cced60fd5c8" +
        "c90943e56599c8f0ba59a38491ba5e5a53460682474c07e40ca142983314fd762856bb1093f359da6eb0a756bd93a316" +
        "0c10dd8feea6b97e7c6a17cb54bd5d7649c05c66d7bdee056671dfdaf689fa3945bb8e29a429f4bd5d355dce9687b06f" +
        "01d5e33e3999f0e8",
      signature = "67d84d4c3945aaf06e06d524be63acbfb5dbb1988c4aea96a5ee9f7a9b9eecc29df4f66b8aa1d9e8607a58fb1ef0c2ad" +
        "69aac005b4f58e34103344a9c8871a09",
      expected = true
    )
  )
  v.add(
    VerifyCase(
      id = 88,
      publicKey = "c9c946cbc5544ac74eef491f07c5881c16faf7ec31ce4aa91bb60ae7b4539051",
      message = "cd2212eddb0706f62c995cef958634f0cb7793444cbf4d30e81c27c41ebea6cb02607510131f9c015692dfd521b14884" +
        "1e9a2d3564d20ac401f6cb8e40f520fe0cafbeaa88840b83013369d879f013463fe52a13267aa0c8c59c45cde9399cd1" +
        "e6be8cc64cf48315ac2eb31a1c567a4fb7d601746d1f63b5ac020712adbbe07519bded6f",
      signature = "24087d47f3e20af51b9668ae0a88ce76586802d0ec75d8c0f28fc30962b5e1d1a1d509571a1624ed125a8df92a6e9637" +
        "28d6b5de99200b8e285f70feb6f05207",
      expected = true
    )
  )
  v.add(
    VerifyCase(
      id = 89,
      publicKey = "32ad026f693d0d2afe7f4388d91c4c964426fcb9e3665c3ebd8650009b815c8e",
      message = "ec5c7cb078",
      signature = "d920d421a5956b69bfe1ba834c025e2babb6c7a6d78c97de1d9bb1116dfdd1185147b2887e34e15578172e150774275e" +
        "a2aad9e02106f7e8ca1caa669a066f0c",
      expected = true
    )
  )
  v.add(
    VerifyCase(
      id = 90,
      publicKey = "32ad026f693d0d2afe7f4388d91c4c964426fcb9e3665c3ebd8650009b815c8e",
      message = "4668c6a76f0e482190a7175b9f3806a5fe4314a004fa69f988373f7a",
      signature = "4f62daf7f7c162038552ad7d306e195baa37ecf6ca7604142679d7d1128e1f8af52e4cb3545748c44ef1ff1c64e877e4" +
        "f4d248259b7f6eb56e3ef72097dc8e0c",
      expected = true
    )
  )
  v
}

func wycheproofCases3(): List[VerifyCase] {
  val v: List[VerifyCase] = newList()
  v.add(
    VerifyCase(
      id = 91,
      publicKey = "c29ec1894e06d27b4e40486b4fa5063d66a746c7f9c323b12203c03b72b8b78a",
      message = "0f325ffd87e58131ffa23c05ea4579513b287fdba87b44",
      signature = "6669acf94667c5b541afe5307bde9476b13ae7e0e6058a772101ac8eb0a94331428eb4db0a2c68a9b6c1763b8624dab2" +
        "59b0876cdcfaeacc17b21a18e3fc010a",
      expected = true
    )
  )
  v.add(
    VerifyCase(
      id = 92,
      publicKey = "cfda5b899e35764c5229e59295fe1222b7ddce176643697c29e46ecbba10cf10",
      message = "ec5c7cb078",
      signature = "30490c28f806298225df62103521dcee047153912c33ab8ab8bbdd1ffabd70fd4fdb360f05be535b067d1cf4e78c2cb4" +
        "32206bf280aab3bd21aaa1cb894c5b06",
      expected = true
    )
  )
  v.add(
    VerifyCase(
      id = 93,
      publicKey = "32ad026f693d0d2afe7f4388d91c4c964426fcb9e3665c3ebd8650009b815c8e",
      message = "5dc9bb87eb11621a93f92abe53515697d2611b2eef73",
      signature = "deecafb6f2ede73fec91a6f10e45b9c1c61c4b9bfbe6b6147e2de0b1df6938971f7896c3ab83851fb5d9e537037bff0f" +
        "ca0ccb4a3cc38f056f91f7d7a0557e08",
      expected = true
    )
  )
  v.add(
    VerifyCase(
      id = 94,
      publicKey = "cfda5b899e35764c5229e59295fe1222b7ddce176643697c29e46ecbba10cf10",
      message = "67484059b2490b1a0a4f8dee77979e26",
      signature = "4cd4f77ed473a6647387f3163541c67a1708a3c3bd1673247cb87f0cb68b3c56f04bfa72970c8a483efe659c87009ab4" +
        "020b590b6641316b3deddb5450544e02",
      expected = true
    )
  )
  v.add(
    VerifyCase(
      id = 95,
      publicKey = "32ad026f693d0d2afe7f4388d91c4c964426fcb9e3665c3ebd8650009b815c8e",
      message = "7dcfe60f881e1285676f35b68a1b2dbcdd7be6f719a288ababc28d36e3a42ac3010a1ca54b32760e74",
      signature = "7f8663cf98cbd39d5ff553f00bcf3d0d520605794f8866ce75714d77cc51e66c91818b657d7b0dae430a68353506edc4" +
        "a714c345f5ddb5c8b958ba3d035f7a01",
      expected = true
    )
  )
  v.add(
    VerifyCase(
      id = 96,
      publicKey = "cfda5b899e35764c5229e59295fe1222b7ddce176643697c29e46ecbba10cf10",
      message = "a020a4381dc9141f47ee508871ab7a8b5a3648727c4281ae9932376f23a8e1bcda0626b7129197d864178631ec89c433" +
        "2dbb18",
      signature = "1e41a24fe732bd7cab14c2a2f5134ee8c87fcbd2e987e60957ed9239e5c32404d56977e1b4282871896cb10625a19374" +
        "68e4dc266e16a9c1b8e9891177eca802",
      expected = true
    )
  )
  v.add(
    VerifyCase(
      id = 97,
      publicKey = "32ad026f693d0d2afe7f4388d91c4c964426fcb9e3665c3ebd8650009b815c8e",
      message = "58e456064dff471109def4ca27fa8310a1df32739655b624f27e6418d34b7f007173f3faa5",
      signature = "6aab49e5c0bc309b783378ee03ffda282f0185cdf94c847701ff307a6ee8d0865411c44e0a8206f6a5f606107451940c" +
        "2593af790ce1860f4c14ab25b2deae08",
      expected = true
    )
  )
  v.add(
    VerifyCase(
      id = 98,
      publicKey = "529919c9c780985a841c42ba6c180ff2d67a276ccfbe281080e47ab71a758f56",
      message = "e1cbf2d86827825613fb7a85811d",
      signature = "01abfa4d6bbc726b196928ec84fd03f0c953a4fa2b228249562ff1442a4f63a7150b064f3712b51c2af768d2c2711a71" +
        "aabf8d186833e941a0301b82f0502905",
      expected = true
    )
  )
  v.add(
    VerifyCase(
      id = 99,
      publicKey = "cfda5b899e35764c5229e59295fe1222b7ddce176643697c29e46ecbba10cf10",
      message = "a25176b3afea318b2ec11ddacb10caf7179c0b3f8eabbfa2895581138d3c1e0e",
      signature = "2a833aadecd9f28235cb5896bf3781521dc71f28af2e91dbe1735a61dce3e31ac15ca24b3fc47817a59d386bbbb2ce60" +
        "a6adc0a2703bb2bdea8f70f91051f706",
      expected = true
    )
  )
  v.add(
    VerifyCase(
      id = 100,
      publicKey = "32ad026f693d0d2afe7f4388d91c4c964426fcb9e3665c3ebd8650009b815c8e",
      message = "a1",
      signature = "1a74ed2cbdc7d8f3827014e8e6ecf8fd2698ac8f86833acccdd400df710fe0d6b0543c9cfa00d52bf024ab7ce0d91981" +
        "944097233ec134d5c7abbd44bfd32d0d",
      expected = true
    )
  )
  v.add(
    VerifyCase(
      id = 101,
      publicKey = "2252b3d57c74cbf8bc460dc2e082847926bc022f09ab6ae95756362bfd1167c1",
      message = "975ef941710071a9e1e6325a0c860becd7c695b5117c3107b686e330e5",
      signature = "af0fd9dda7e03e12313410d8d8844ebb6fe6b7f65141f22d7bcba5695a25414a9e54326fb44d59fb14707899a8aae708" +
        "57b23d4080d7ab2c396ef3a36d45ce02",
      expected = true
    )
  )
  v.add(
    VerifyCase(
      id = 102,
      publicKey = "c0a773110f975de3732355bb7ec7f0c41c091c0252966070205516693b992a4a",
      message = "",
      signature = "0280427e713378f49d478df6373c6cac847b622b567daa2376c839e7ac10e22c380ab0fa8617c9dcfe76c4d9db5459b2" +
        "1dc1413726e46cc8f387d359e344f407",
      expected = true
    )
  )
  v.add(
    VerifyCase(
      id = 103,
      publicKey = "cfda5b899e35764c5229e59295fe1222b7ddce176643697c29e46ecbba10cf10",
      message = "a9e6d94870a67a9fe1cf13b1e6f9150cdd407bf6480ec841ea586ae3935e9787163cf419c1",
      signature = "c97e3190f83bae7729ba473ad46b420b8aad735f0808ea42c0f898ccfe6addd4fd9d9fa3355d5e67ee21ab7e1f805cd0" +
        "7f1fce980e307f4d7ad36cc924eef00c",
      expected = true
    )
  )
  v.add(
    VerifyCase(
      id = 104,
      publicKey = "32ad026f693d0d2afe7f4388d91c4c964426fcb9e3665c3ebd8650009b815c8e",
      message = "11cb1eafa4c42a8402c4193c4696f7b2e6d4585e4b42dcf1a8b67a80b2da80bc9d4b649fb2f35eaf1f56c426fd0b",
      signature = "14ceb2eaf4688d995d482f44852d71ad878cd7c77b41e60b0065fd01a59b054ee74759224187dbde9e59a763a70277c9" +
        "60892ef89fba997aba2576b2c54ba608",
      expected = true
    )
  )
  v.add(
    VerifyCase(
      id = 105,
      publicKey = "c9c946cbc5544ac74eef491f07c5881c16faf7ec31ce4aa91bb60ae7b4539051",
      message = "27d465bc632743522aefa23c",
      signature = "c2656951e2a0285585a51ff0eda7e9a23c2dfd2ffa273aee7808f4604e8f9a8c8ea49e9fce4eb2d8d75d36b7238fe6fc" +
        "13b6c5d9427dd58f8c6615d033c0bd0f",
      expected = true
    )
  )
  v.add(
    VerifyCase(
      id = 106,
      publicKey = "c29ec1894e06d27b4e40486b4fa5063d66a746c7f9c323b12203c03b72b8b78a",
      message = "5ffa",
      signature = "931e5152fcef078c22cc5d6a3a65f06e396289f6f5f2d1efa6340254a53526ef5dc6874eeddf35c3f50991c53cd02bf0" +
        "6313e37d93ee1f7022128ffa3b8f300b",
      expected = true
    )
  )
  v.add(
    VerifyCase(
      id = 107,
      publicKey = "529919c9c780985a841c42ba6c180ff2d67a276ccfbe281080e47ab71a758f56",
      message = "25",
      signature = "e4ae21f7a8f4b3b325c161a8c6e53e2edd7005b9c2f8a2e3b0ac4ba94aa80be6f2ee22ac8d4a96b9a3eb73a825e7bb5a" +
        "ff4a3393bf5b4a38119e9c9b1b041106",
      expected = true
    )
  )
  v.add(
    VerifyCase(
      id = 108,
      publicKey = "2252b3d57c74cbf8bc460dc2e082847926bc022f09ab6ae95756362bfd1167c1",
      message = "80fdd6218f29c8c8f6bd820945f9b0854e3a8824",
      signature = "e097e0bd0370bff5bde359175a11b728ee9639095d5df8eda496395565616edfe079977f7d4dc8c75d6113a83d6a55e6" +
        "e1676408c0967a2906339b43337dcb01",
      expected = true
    )
  )
  v.add(
    VerifyCase(
      id = 109,
      publicKey = "2a606bf67ac770c607038b004101b325edb569efd3413d2d1f2c3e6b4e6e3082",
      message = "b477b0480bb84642608b908d29a51cf2fce63f24ee95",
      signature = "28fafbb62b4d688fa79e1ac92851f46e319b161f801d4dc09acc21fdd6780a2c4292b8c1003c61c2bcebe7f3f88ccc4b" +
        "b26d407387c5f27cb8c94cf6ce810405",
      expected = true
    )
  )
  v.add(
    VerifyCase(
      id = 110,
      publicKey = "32ad026f693d0d2afe7f4388d91c4c964426fcb9e3665c3ebd8650009b815c8e",
      message = "aa365b442d12b7f3c925",
      signature = "83c40ce13d483cc58ff65844875862d93df4bd367af77efa469ec06a8ed9e6d7905a04879535708ddf225567a815c9b9" +
        "41d405c98e918fd0c151165cea7fb101",
      expected = true
    )
  )
  v.add(
    VerifyCase(
      id = 111,
      publicKey = "54cda623245759ad6d43e620a606908befc633d60792bc7798447a0ef38e7311",
      message = "27e792b28b2f1702",
      signature = "14d9b497c19b91d43481c55bb6f5056de252d9ecb637575c807e58e9b4c5eac8b284089d97e2192dc242014363208e2c" +
        "9a3435edf8928fb1d893553e9be4c703",
      expected = true
    )
  )
  v.add(
    VerifyCase(
      id = 112,
      publicKey = "2362bac514d5fad33802642e979a1e82de6eb6f1bcbf6a5b304f2bb02b9e57fe",
      message = "eef3bb0f617c17d0420c115c21c28e3762edc7b7fb048529b84a9c2bc6",
      signature = "242ddb3a5d938d07af690b1b0ef0fa75842c5f9549bf39c8750f75614c712e7cbaf2e37cc0799db38b858d41aec5b9dd" +
        "2fca6a3c8e082c10408e2cf3932b9d08",
      expected = true
    )
  )
  v.add(
    VerifyCase(
      id = 113,
      publicKey = "32ad026f693d0d2afe7f4388d91c4c964426fcb9e3665c3ebd8650009b815c8e",
      message = "475f",
      signature = "71a4a06a34075f2fd47bc3abf4714d46db7e97b08cb6180d3f1539ac50b18ce51f8af8ae95ed21d4fa0daab723592563" +
        "1ecea1fd9d0d8a2ba7a7583fd04b900c",
      expected = true
    )
  )
  v.add(
    VerifyCase(
      id = 114,
      publicKey = "037b55b427dc8daa0f80fcebaf0846902309f8a6cf18b465c0ce9b6539629ac8",
      message = "01234567",
      signature = "c964e100033ce8888b23466677da4f4aea29923f642ae508f9d0888d788150636ab9b2c3765e91bbb05153801114d9e5" +
        "2dc700df377212222bb766be4b8c020d",
      expected = true
    )
  )
  v.add(
    VerifyCase(
      id = 115,
      publicKey = "9c0007698f177998a7666c7cf7973e2b88e9c4946e33804a7bbe8968d2394b2e",
      message = "9399a6db9433d2a28d2b0c11c8794ab7d108c95b",
      signature = "176065c6d64a136a2227687d77f61f3fca3b16122c966276fd9a8b14a1a2cea4c33b3533d11101717016684e3810efbe" +
        "a63bb23773f7cc480174199abd734f08",
      expected = true
    )
  )
  v.add(
    VerifyCase(
      id = 116,
      publicKey = "ed3a6f9721dc9729c1f76635bcf080d7036e1c2f0228654ccbbe1e738c17b963",
      message = "7af783afbbd44c1833ab7237ecaf63b94ffdd003",
      signature = "7ca69331eec8610d38f00e2cdbd46966cb359dcde98a257ac6f362cc00c8f4fe85c02285fe4d66e31a44cadb2bf474e1" +
        "a7957609eb4fe95a71473fe6699aa70d",
      expected = true
    )
  )
  v.add(
    VerifyCase(
      id = 117,
      publicKey = "4abfb535313705a6570018440cdec1a3ae33e51f352112fa6acbd0c6bc3ea859",
      message = "321b5f663c19e30ee7bbb85e48ecf44db9d3f512",
      signature = "f296715e855d8aecccba782b670163dedc4458fe4eb509a856bcac450920fd2e95a3a3eb212d2d9ccaf948c39ae46a25" +
        "48af125f8e2ad9b77bd18f92d59f9200",
      expected = true
    )
  )
  v.add(
    VerifyCase(
      id = 118,
      publicKey = "4f2162e6bf03a712db0efa418b7e7006e23871d9d7ec555a313885c4afd96385",
      message = "c48890e92aeeb3af04858a8dc1d34f16a4347b91",
      signature = "367d07253a9d5a77d054b9c1a82d3c0a448a51905343320b3559325ef41839608aa45564978da1b2968c556cfb23b0c9" +
        "8a9be83e594d5e769d69d1156e1b1506",
      expected = true
    )
  )
  v.add(
    VerifyCase(
      id = 119,
      publicKey = "4abfb535313705a6570018440cdec1a3ae33e51f352112fa6acbd0c6bc3ea859",
      message = "321b5f663c19e30ee7bbb85e48ecf44db9d3f512",
      signature = "f296715e855d8aecccba782b670163dedc4458fe4eb509a856bcac450920fd2e95a3a3eb212d2d9ccaf948c39ae46a25" +
        "48af125f8e2ad9b77bd18f92d59f9200",
      expected = true
    )
  )
  v.add(
    VerifyCase(
      id = 120,
      publicKey = "4f2162e6bf03a712db0efa418b7e7006e23871d9d7ec555a313885c4afd96385",
      message = "c48890e92aeeb3af04858a8dc1d34f16a4347b91",
      signature = "367d07253a9d5a77d054b9c1a82d3c0a448a51905343320b3559325ef41839608aa45564978da1b2968c556cfb23b0c9" +
        "8a9be83e594d5e769d69d1156e1b1506",
      expected = true
    )
  )
  v
}

func wycheproofCases4(): List[VerifyCase] {
  val v: List[VerifyCase] = newList()
  v.add(
    VerifyCase(
      id = 121,
      publicKey = "0717d75ce27ea181ed5a30e6456c649b5cf453a6b4c12cd3f9fd16b31e0c25cd",
      message = "26d5f0631f49106db58c4cfc903691134811b33c",
      signature = "9588e02bc815649d359ce710cdc69814556dd8c8bab1c468f40a49ebefb7f0de7ed49725edfd1b708fa1bad277c35d6c" +
        "1b9c5ec25990997645780f9203d7dd08",
      expected = true
    )
  )
  v.add(
    VerifyCase(
      id = 122,
      publicKey = "db5b9eab7e84e5a13505865fa711c9c896c898609fc11fc9bc1e55028f9496df",
      message = "2a71f064af982a3a1103a75cef898732d7881981",
      signature = "2217a0be57dd0d6c0090641496bcb65e37213f02a0df50aff0368ee2808e1376504f37b37494132dfc4d4887f58b9e86" +
        "eff924040db3925ee4f8e1428c4c500e",
      expected = true
    )
  )
  v.add(
    VerifyCase(
      id = 123,
      publicKey = "7bac18f6d2625d3915f233434cda38a577247a7332a5170b37142a34644145e0",
      message = "bf26796cef4ddafcf5033c8d105057db0210b6ad",
      signature = "1fda6dd4519fdbefb515bfa39e8e5911f4a0a8aa65f40ef0c542b8b34b87f9c249dc57f320718ff457ed5915c4d0fc35" +
        "2affc1287724d3f3a9de1ff777a02e01",
      expected = true
    )
  )
  v.add(
    VerifyCase(
      id = 124,
      publicKey = "7bac18f6d2625d3915f233434cda38a577247a7332a5170b37142a34644145e0",
      message = "bf26796cef4ddafcf5033c8d105057db0210b6ad",
      signature = "1fda6dd4519fdbefb515bfa39e8e5911f4a0a8aa65f40ef0c542b8b34b87f9c249dc57f320718ff457ed5915c4d0fc35" +
        "2affc1287724d3f3a9de1ff777a02e01",
      expected = true
    )
  )
  v.add(
    VerifyCase(
      id = 125,
      publicKey = "38ead304624abebf3e2b31e20e5629531e3fc659008887c9106f5e55adbbc62a",
      message = "ae03da6997e40cea67935020152d3a9a365cc055",
      signature = "068eafdc2f36b97f9bae7fbda88b530d16b0e35054d3a351e3a4c914b22854c711505e49682e1a447e10a69e3b04d075" +
        "9c859897b64f71137acf355b63faf100",
      expected = true
    )
  )
  v.add(
    VerifyCase(
      id = 126,
      publicKey = "e9bc95049af7e4817b17c402269ba5e767b7348757ac8002fec9e08390c0a9cf",
      message = "489d473f7fb83c7f6823baf65482517bccd8f4ea",
      signature = "43670abc9f09a8a415e76f4a21c6a46156f066b5a37b3c1e867cf67248c7b927e8d13a763e37abf936f5f27f7a8aa290" +
        "539d21f740efd26b65fd5ad27085f400",
      expected = true
    )
  )
  v.add(
    VerifyCase(
      id = 127,
      publicKey = "ee8155ca4e8fe7bc5bca5992044eab7f8c3c6a13db1176f42f46c29da5b064f4",
      message = "1b704d6692d60a07ad1e1d047b65e105a80d3459",
      signature = "56388f2228893b14ce4f2a5e0cc626591061de3a57c50a5ecab7b9d5bb2caeea191560a1cf2344c75fdb4a085444aa68" +
        "d727b39f498169eaa82cf64a31f59803",
      expected = true
    )
  )
  v.add(
    VerifyCase(
      id = 128,
      publicKey = "db507bfcc9576393f7157bb360532b05c5fcf2e764b690cc6698a4a30d349095",
      message = "dc87030862c4c32f56261e93a367caf458c6be27",
      signature = "553e5845fc480a577da6544e602caadaa00ae3e5aa3dce9ef332b1541b6d5f21bdf1d01e98baf80b8435f9932f89b3eb" +
        "70f02da24787aac8e77279e797d0bd0b",
      expected = true
    )
  )
  v.add(
    VerifyCase(
      id = 129,
      publicKey = "994eaf03309d6ad9d95a656bc1744e2886f029023a3750b34f35086b3c7227f8",
      message = "7f41ef68508343ef18813cb2fb332445ec6480cd",
      signature = "bc10f88081b7be1f2505b6e76c5c82e358cf21ec11b7df1f334fb587bada465b53d9f7b4d4fec964432ee91ead1bc32e" +
        "d3c82f2167da1c834a37515df7fe130e",
      expected = true
    )
  )
  v.add(
    VerifyCase(
      id = 130,
      publicKey = "127d37e406e0d83e4b55a09e21e8f50fb88af47e4a43f018cdebffc1948757f0",
      message = "e1ce107971534bc46a42ac609a1a37b4ca65791d",
      signature = "00c11e76b5866b7c37528b0670188c1a0473fb93c33b72ae604a8865a7d6e094ff722e8ede3cb18389685ff3c4086c29" +
        "006047466f81e71a329711e0b9294709",
      expected = true
    )
  )
  v.add(
    VerifyCase(
      id = 131,
      publicKey = "d83ba84edfb4bec49f29be31d80a64b7c0b5a502438cdb1d0dd1e0e3e55786de",
      message = "869a827397c585cf35acf88a8728833ab1c8c81e",
      signature = "0a6f0ac47ea136cb3ff00f7a96638e4984048999ee2da0af6e5c86bffb0e70bb97406b6ad5a4b764f7c99ebb6ec0fd43" +
        "4b8efe253b0423ef876c037998e8ab07",
      expected = true
    )
  )
  v.add(
    VerifyCase(
      id = 132,
      publicKey = "d3c9aa2f3d6ef217a166e8ae403ed436c37facbbe3beceb78df6eb439f8fa04a",
      message = "619d8c4f2c93104be01cd574a385ceca08c33a9e",
      signature = "b7cbb942a6661e2312f79548224f3e44f5841c6e880c68340756a00ce94a914e8404858265985e6bb97ef01d2d7e5e41" +
        "340309606bfc43c8c6a8f925126b3d09",
      expected = true
    )
  )
  v.add(
    VerifyCase(
      id = 133,
      publicKey = "d53280367c1c0b95ac4112218b92c6a71c51fb6312ce668de196c7d52a136155",
      message = "5257a0bae8326d259a6ce97420c65e6c2794afe2",
      signature = "27a4f24009e579173ff3064a6eff2a4d20224f8f85fdec982a9cf2e6a3b51537348a1d7851a3a932128a923a393ea84e" +
        "6b35eb3473c32dceb9d7e9cab03a0f0d",
      expected = true
    )
  )
  v.add(
    VerifyCase(
      id = 134,
      publicKey = "94ac2336ba97a476fb4c9f2b5563e4167ca292c6e99e422350a911ae3172c315",
      message = "5acb6afc9b368f7acac0e71f6a4831c72d628405",
      signature = "985b605fe3f449f68081197a68c714da0bfbf6ac2ab9abb0508b6384ea4999cb8d79af98e86f589409e8d2609a8f8bd7" +
        "e80aaa8d92a84e7737fbe8dcef41920a",
      expected = true
    )
  )
  v.add(
    VerifyCase(
      id = 135,
      publicKey = "e1e7316d231f7f275bdf403360304da1509fdf1af1fd25ca214eaac0a289398f",
      message = "3c87b3453277b353941591fc7eaa7dd37604b42a",
      signature = "1c8fbda3d39e2b441f06da6071c13115cb4115c7c3341704cf6513324d4cf1ef4a1dd7678a048b0dde84e48994d080be" +
        "fcd70854079d44b6a0b0f9fa002d130c",
      expected = true
    )
  )
  v.add(
    VerifyCase(
      id = 136,
      publicKey = "fffbeea71215efaf9888fec2cc68edb3703ff11a66fd629b53cbda5eabc18750",
      message = "0a68e27ef6847bfd9e398b328a0ded3679d4649d",
      signature = "59097233eb141ed948b4f3c28a9496b9a7eca77454ecfe7e46737d1449a0b76b15aacf77cf48af27a668aa4434cfa26c" +
        "504d75a2bcc4feac46465446234c0508",
      expected = true
    )
  )
  v.add(
    VerifyCase(
      id = 137,
      publicKey = "19ccc0527599cb032e0b4c4d74e60f13901768a99df041c3bc1bf6c0ef271169",
      message = "4e9bef60737c7d4dd10bd52567e1473a36d3573d",
      signature = "519105608508fe2f1b6da4cc8b23e39798b1d18d25972beed0404cec722e01ba1b6a0f85e99e092cca8076b101b60d4a" +
        "c5035684357f4d0daacdc642da742a06",
      expected = true
    )
  )
  v.add(
    VerifyCase(
      id = 138,
      publicKey = "0e726e27047563aa0a1a9c2e085d8d26af2acba129d0869c65031e3e6cac329a",
      message = "cc82b3163efda3ba7e9240e765112caa69113694",
      signature = "d8b03ee579e73f16477527fc9dc37a72eaac0748a733772c483ba013944f01ef64fb4ec5e3a95021dc22f4ae282baff6" +
        "e9b9cc8433c6b6710d82e7397d72ef04",
      expected = true
    )
  )
  v.add(
    VerifyCase(
      id = 139,
      publicKey = "e77717b54a2b5e5bce5bccb8f0c5fdb5fd7df77ac254020fc9120dc0d4df4178",
      message = "923a5c9e7b5635bb6c32c5a408a4a15b652450eb",
      signature = "26da61fdfd38e6d01792813f27840c8b4766b0faaed39d0ee898cb450d94a5d5f57e58b6a003d7f9b56b20561954c6ed" +
        "cf66492d116b8b5e91f205a3a6449d0b",
      expected = true
    )
  )
  v.add(
    VerifyCase(
      id = 140,
      publicKey = "6220972d3f7d150b36790d7d522384876d64d640cd9913186815e1629582ed36",
      message = "6f2f0245de4587062979d0422d349f93ccdc3af2",
      signature = "4adeaff7a58c5010a5a067feea0ae504d37b0c6a76c6c153e222f13409dff2df0fab69bc5059b97d925dc1b89e9851d7" +
        "c627cb82d65585f9fd976124553f8902",
      expected = true
    )
  )
  v.add(
    VerifyCase(
      id = 141,
      publicKey = "7b64a28c50ec7678a90e3e1a21522e30ac9db7b5215aea2bfb33bea037eab987",
      message = "6e911edb27a170b983d4dee1110554f804330f41",
      signature = "4204d620cde0c3008c0b2901f5d6b44f88f0e3cb4f4d62252bf6f3cb37c1fb150a9ccb296afe5e7c75f65b5c8edd13dc" +
        "4910ffe1e1265b3707c59042cf9a5902",
      expected = true
    )
  )
  v.add(
    VerifyCase(
      id = 142,
      publicKey = "724452210a9e4c994819229bf12bf84e95768a3a97c08d8d8f5f939a4cad34c5",
      message = "b8cf807eea809aaf739aa091f3b7a3f2fd39fb51",
      signature = "f8a69d3fd8c2ff0a9dec41e4c6b43675ce08366a35e220b1185ffc246c339e22c20ac661e866f52054015efd04f42eca" +
        "2adcee6834c4df923b4a62576e4dff0e",
      expected = true
    )
  )
  v.add(
    VerifyCase(
      id = 143,
      publicKey = "bad265b294ed2f422cb6a141694086238fbfe987571aa765d8b4f3a24105aa01",
      message = "01a2b5f7fee813b4e9bd7fc25137648004795010",
      signature = "61792c9442bc6338ac41fd42a40bee9b02ec1836503d60ff725128c63d72808880c36e6190b7da525cbee5d12900aa04" +
        "3547dd14a2709ef9e49d628f37f6b70c",
      expected = true
    )
  )
  v.add(
    VerifyCase(
      id = 144,
      publicKey = "0aaee4b723db9b51ba7d22eb23eb8a76a5ac02f4fc9dd06f77bea42e1d37ec5a",
      message = "0fbf5d47cb5d498feace8f98f1896208da38a885",
      signature = "fa3cd41e3a8c00b19eecd404a63c3cb787cd30de0dfc936966cff2117f5aff18db6bef80fcfd8856f3fb2e9c3dc47593" +
        "e9471103032af918feee638a33d40505",
      expected = true
    )
  )
  v.add(
    VerifyCase(
      id = 145,
      publicKey = "812344af15a91ba83c2c91e96f1727ac0f3c4c41385b9fa84efa399ada5168be",
      message = "36e67c1939750bffb3e4ba6cb85562612275e862",
      signature = "97fbbcd7a1d0eb42d2f8c42448ef35a2c2472740556b645547865330d6c57068af377fced08aaf810c08cd3c43d296f1" +
        "975710312e9334c98b485f831efa4103",
      expected = true
    )
  )
  v.add(
    VerifyCase(
      id = 146,
      publicKey = "0ee5cb5597fbdf8dccc48b01485e39b33aa133b52d30d23740277267cfec3e3e",
      message = "13945c894c1d3fe8562e8b20e5f0efaa26ade8e3",
      signature = "d7dbaa337ffd2a5fd8d5fd8ad5aeccc0c0f83795c2c59fe62a40b87903b1ae62ed748a8df5af4d32f9f822a65d0e498b" +
        "6f40eaf369a9342a1164ee7d08b58103",
      expected = true
    )
  )
  v.add(
    VerifyCase(
      id = 147,
      publicKey = "9fba1de92b60b5b4703089763d0d6f9125e4dd7efae41f08a22882aef96892c4",
      message = "4de142af4b8402f80a47fa812df84f42e283cee7",
      signature = "09a2ed303a2fa7027a1dd7c3b0d25121eeed2b644a2fbc17aa0c8aea4524071ede7e7dd7a536d5497f8165d29e4e1b63" +
        "200f74bbae39fbbbccb29889c62c1f09",
      expected = true
    )
  )
  v.add(
    VerifyCase(
      id = 148,
      publicKey = "7582ab1b52e1316e5c13671f43b39ca36b28133cd0832831bcddd0b0f23398cb",
      message = "563357f41b8b23b1d83f19f5667177a67da20b18",
      signature = "e6884a6e6b2e60a0b5862251c001e7c79d581d777d6fc11d218d0aecd79f26a30e2ca22cc7c4674f8b72655bc4ee5cb5" +
        "494ca07c05177656142ac55cc9d33e02",
      expected = true
    )
  )
  v.add(
    VerifyCase(
      id = 149,
      publicKey = "dd2d678bae222f3fb6e8278f08cc9e1a66339c926c29ac0a16f9717f5ee18cd8",
      message = "931bbf9c877a6571cf7d4609fc3eb867edd43f51",
      signature = "6124c206d864507ea5d984b363b4cf583314db6856a45ded5e61eebff4d5e337e0b4c82b445ae2e52d549d2d961eace2" +
        "ea01f81158e09a9686baa040db65ad08",
      expected = true
    )
  )
  v.add(
    VerifyCase(
      id = 150,
      publicKey = "ccbe7cb2e4bc215cee2f885e1d22f7e0d582b2bbbd782c104e548b152d26fc69",
      message = "44530b0b34f598767a7b875b0caee3c7b9c502d1",
      signature = "cfbd450a2c83cb8436c348822fe3ee347d4ee937b7f2ea11ed755cc52852407c9eec2c1fa30d2f9aef90e89b2cc3bcef" +
        "2b1b9ca59f712110d19894a9cf6a2802",
      expected = true
    )
  )
  v
}

func wycheproofCases5(): List[VerifyCase] {
  val v: List[VerifyCase] = newList()
  v.add(
    VerifyCase(
      id = 151,
      publicKey = "d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a",
      message = "313233343030",
      signature = "0100000000000000000000000000000000000000000000000000000000000080c803ee1f2342aa96ff698a393d1ab5e6" +
        "6f3eda101d6d120b394c3fd32c117d0a",
      expected = false
    )
  )
  v.add(
    VerifyCase(
      id = 152,
      publicKey = "0100000000000000000000000000000000000000000000000000000000000000",
      message = "6d657373616765",
      signature = "586666666666666666666666666666666666666666666666666666666666666601000000000000000000000000000000" +
        "00000000000000000000000000000000",
      expected = false
    )
  )
  v.add(
    VerifyCase(
      id = 153,
      publicKey = "c7176a703d4dd84fba3c0b760d10670f2a2053fa2c39ccc64ec7fd7792ac037a",
      message = "746f7273696f6e2d312d3134",
      signature = "b63dd4baa9c75ea9f3f1021ada3bf7dd6872e4cfbdac9653965ef78c4be9845d27df2ce4101220ec96bc5ccbcefa1336" +
        "871b76e6ef52a0fb35745bb187b1a10d",
      expected = false
    )
  )
  v.add(
    VerifyCase(
      id = 154,
      publicKey = "0000000000000000000000000000000000000000000000000000000000000080",
      message = "",
      signature = "c459280d27f66a3285aa648ca1cc444cdfcde27a6062d117c6cb399e0969d6edf8b80551824c3e7275922ac8751e59a4" +
        "2793406560453c4e366999f900480506",
      expected = false
    )
  )
  v.add(
    VerifyCase(
      id = 155,
      publicKey = "26e8958fc2b227b045c3f489f2ef98f0d5dfac05d3c63339b13802886d53fc05",
      message = "746f7273696f6e2d332d34",
      signature = "afd0270f467226b517fa8f911d1d320906df0065fe0045593c8fd0394770b83e6bb6f264bca826f9a4631816571f8f42" +
        "681a94db6d3f032e64721265a06c7009",
      expected = false
    )
  )
  v.add(
    VerifyCase(
      id = 156,
      publicKey = "ecffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f",
      message = "",
      signature = "f8cea2efb481e92ca61b8972098e07aa1c16f2166cbd8da7ae682b55e433693920b491d7e08ab6c8e521b2f0300befbf" +
        "cbfd7078340bc153a251896ef8b7c805",
      expected = false
    )
  )
  v.add(
    VerifyCase(
      id = 157,
      publicKey = "26e8958fc2b227b045c3f489f2ef98f0d5dfac05d3c63339b13802886d53fc85",
      message = "746f7273696f6e2d352d3231",
      signature = "54df79ed63c1bfdc39fd6408ad5f04143bcfc22b7e1dd0e5ea3bc00eccbbbf8260faa75789f6428d7a8a5a3b850b6779" +
        "171de7edd504ffcfb5db320dd9864b06",
      expected = false
    )
  )
  v.add(
    VerifyCase(
      id = 158,
      publicKey = "0000000000000000000000000000000000000000000000000000000000000000",
      message = "",
      signature = "520679470254237dbe8f93dc12e8b05363f5236b5671ebff01251649930f6c287531efeb34b73a6fe0f3170a211ce386" +
        "ae269b0d145d5a7e63bb4ba15ce0c408",
      expected = false
    )
  )
  v.add(
    VerifyCase(
      id = 159,
      publicKey = "c7176a703d4dd84fba3c0b760d10670f2a2053fa2c39ccc64ec7fd7792ac03fa",
      message = "746f7273696f6e2d372d39",
      signature = "b57aca4330dc58dcfd4ca75a1f7f3161aaf394a57769c7a9e9837d27cf7a80f7e88557a67e0b4792628285f53ed0f4fa" +
        "c97bc187e436fac5ea0513d320d5560f",
      expected = false
    )
  )
  v.add(
    VerifyCase(
      id = 160,
      publicKey = "15deb30729eb3e465c88f11b57d0c8d36eb0f670c3b22d2f80ea6049eeb2c23b",
      message = "6d697865642d6f726465722d302d312d38",
      signature = "49b0d4daf5493b98c7220f7b785fdf10f4befad3262e00f2cd6813c90d1319f6a7c6c0d69149f691d0c6b428642bb08d" +
        "7046e0abff7e68e6b83547129f51080b",
      expected = true
    )
  )
  v.add(
    VerifyCase(
      id = 161,
      publicKey = "31f20adf0f25a04f6d0940d2eb6a0b7d4aa2f18c9571a6f7eb74bf059b0d7215",
      message = "",
      signature = "d9f1148f0b13b3e801455c65d8314e7103706166ac6844ad43ead64ee310cc9f04e345b79bca79e83fbe7511fb5d17b3" +
        "47e2a2a98c247a92ba81b4a182116b0f",
      expected = true
    )
  )
  v.add(
    VerifyCase(
      id = 162,
      publicKey = "db3274482b52f4937b405c00496b0511a364c58d4798ceae171262803d465729",
      message = "6d697865642d6f726465722d302d332d31",
      signature = "989e808156e71fb17c146080890b2726d0e9ba1ab29a0832b680bac5849c41e04e97cb8d756d0890b1c8d7eff77de4b1" +
        "a0301404338874b8819c4bb5bf204a08",
      expected = true
    )
  )
  v.add(
    VerifyCase(
      id = 163,
      publicKey = "fb8ae86afa72f86ab074c3a51440df0d72c13c44cd1c4ae510681b419504974a",
      message = "",
      signature = "df0ea594369382b35dd6c26bb71a7984f0fda2890a19bbb69bbbaf62242ee74dd7f1bba3c0da7caa20ebf1337bcc2d39" +
        "a2547e4e95e132a2daaf272439af8a05",
      expected = true
    )
  )
  v.add(
    VerifyCase(
      id = 164,
      publicKey = "d8214cf8d614c1b9a3770ee4a82f372c914f098f3c4dd2d07f159fb6114d3dc4",
      message = "6d697865642d6f726465722d302d352d32",
      signature = "f31beed5c32641a1baca414ba1f6a39cd4e0da3fe95027d937a41df3d6a6e5a7f70d47674a0fb90b618e6465e7bd133f" +
        "1615ae72eb790b05082342e12021180d",
      expected = true
    )
  )
  v.add(
    VerifyCase(
      id = 165,
      publicKey = "bc0df520f0da5fb092f6bf2d1495f482b55d0e736a8e5908148b40fa64f28dea",
      message = "",
      signature = "bef3aa8b7c0a70ef4b689bc839aff99c7cb5d62b3ec733079338400ec5deb0ccabaafcae9ecd7d8cff17c1094353e85e" +
        "c9d201e41f308589a3141c23895c030d",
      expected = true
    )
  )
  v.add(
    VerifyCase(
      id = 166,
      publicKey = "12cd8bb7d4ad0b6c84bfa3ffb694faee5c9b3a72b8673151e8ed9d7fc2b9a8d6",
      message = "6d697865642d6f726465722d302d372d33",
      signature = "71e7486ab6df0686580902797c785ffcfb2fe3b61d46c8e5da432e168e05d9c59ec91d092c7c8c635de89a97b37e383a" +
        "4cec89d3c6015fb3fa7fbf43900dae04",
      expected = true
    )
  )
  v.add(
    VerifyCase(
      id = 167,
      publicKey = "c1b047f0106ff174487ba336a56d48127ed0563dcca139fd555cf113f609ac71",
      message = "",
      signature = "3c48db3cce8f2f154ddfe665a697de2f8dce6dd965eb0a18dbb95e90df01f2d595225ab03a2452216368b9f6f7590b72" +
        "b804bb8d3258c4c9caa15922e3bff50a",
      expected = true
    )
  )
  v.add(
    VerifyCase(
      id = 168,
      publicKey = "280fa1145bb421c1586eeadfb0f96ba1a25673111eca768773dafedf9b4e5a38",
      message = "6d697865642d6f726465722d312d322d38",
      signature = "5c56e4644b99902901a9666a72c52ab6b029d4e81b07bb84b875c39f8f911938db1068dfa06b293fdeadafa97613fe10" +
        "b2684b85184f5fccc6503096c316ba00",
      expected = true
    )
  )
  v.add(
    VerifyCase(
      id = 169,
      publicKey = "66f35e3ae56c736132dde77ae1faaeb01ebfc1bd79c98d43737e945b0744aaed",
      message = "",
      signature = "5caa2cb4b66f9db52ca1dfa1a3068e36ba0fa66f3a5912d7ab9a55808edb6fe29be93e6714f72d9a0d83e736b88a4a74" +
        "bd7237d739c85edbbfa99d5c518c7505",
      expected = true
    )
  )
  v.add(
    VerifyCase(
      id = 170,
      publicKey = "c243dfb46f771baa41247bdb387f07475c78b8b9bb99b1089be6fd371420ccc3",
      message = "6d697865642d6f726465722d312d342d31",
      signature = "66250edaea83744886f3dfa139424148ced9e0646be033ab72b75d8413afbea453eefb6735dabe1491aff1f308bbd730" +
        "60c669c3c3772ae2f94ab4f387642a02",
      expected = true
    )
  )
  v.add(
    VerifyCase(
      id = 171,
      publicKey = "2c4fb80fef900e8bb7845cc95a92b7ed812fa9c2335ec602aaa30eec09f6538e",
      message = "",
      signature = "fc91f328ca137afe81ff69d75118b89455b96d6fd6cb88a46b99fc68074175b1ac6be310033c348fe42f41cbef8c0047" +
        "74563c77ab781217c165d13fc273b202",
      expected = true
    )
  )
  v.add(
    VerifyCase(
      id = 172,
      publicKey = "c5f05eeba44bde3ea79115204f06945e5da98ceee13589788c25012064b1a5c7",
      message = "6d697865642d6f726465722d312d362d34",
      signature = "cc93d04669be4a2b68dd7d82944563b4468fa1392ae97fa36fe388d89e3d81a59588aa307e357bd12635702d077014da" +
        "f525afd7400acb78d0c9a2f9f506c60a",
      expected = true
    )
  )
  v.add(
    VerifyCase(
      id = 173,
      publicKey = "870ca1c51a938c9ecd2218851e05514fe1403e42863672bc8c816ba4f8bb5512",
      message = "",
      signature = "c28aa73d32d98a6f0f956392279cd13fc35d9d67ea54c99941eadea5d08ba760398f5845bbbb509102326b53ab93e333" +
        "98b6c673331a194dd85173495e13ff0a",
      expected = true
    )
  )
  v.add(
    VerifyCase(
      id = 174,
      publicKey = "85e7bfc77e932799ae948a1abd8ea287c56dd48fb8b4221931e4f8652e1eea20",
      message = "6d697865642d6f726465722d322d312d30",
      signature = "e85ba67b317ad0f48848892ce0a585d2d47ccd49e7895bf93629bf3e4723f92c3de51cdced1b12654fc834d3e675488e" +
        "98f2628fa0a01b058f17dfb81603c300",
      expected = true
    )
  )
  v.add(
    VerifyCase(
      id = 175,
      publicKey = "349a3840d09eb68a97b06eae781f4fbece569c6ffd70c238ff8406ec82fb587d",
      message = "",
      signature = "1505ddb0ea2479d7751bdb60693727d448d1c22193cfe548ce6905f8c5da1a0c13a889c2a7d2b30c3b78015086972386" +
        "d377060c9a97ea15d6dd8da04f8c7702",
      expected = true
    )
  )
  v.add(
    VerifyCase(
      id = 176,
      publicKey = "0cf1b0a8da530a0f0b30f5b130391652f249680e0f3f7c80284bdc5ab955cfa3",
      message = "6d697865642d6f726465722d322d332d33",
      signature = "793423634e1945c284aa538008fa41767a46964acf14fddabc2ac7eeb3733b4a81b3075118fcaaf8499749a992df4949" +
        "bc866de91ab0b1a98cae9459db2f710f",
      expected = true
    )
  )
  v.add(
    VerifyCase(
      id = 177,
      publicKey = "628c21a85bec28f1d0c0ea44b2c6e731f47a1b01be58d1028892f947351bfa61",
      message = "",
      signature = "f8410c87623213d696e74b9a23b30926fbf8036a931678db8155956440ac192e4ed451d782a41df339f56cd4e8482de5" +
        "5601eefd92301d55bb067e90bb5db009",
      expected = true
    )
  )
  v.add(
    VerifyCase(
      id = 178,
      publicKey = "68184038816cd866516b75e542715d783a922b70474bdde6ce1b079ad1e115df",
      message = "6d697865642d6f726465722d322d352d38",
      signature = "a02a0c28d4735b1fa7803ce1e1f410828ffd07018b0b1f5255fe69381a04d788d575682aceb9efe1c12f158b920ef213" +
        "bfbcc53cdbb36dbd81383ecd91b7dc03",
      expected = true
    )
  )
  v.add(
    VerifyCase(
      id = 179,
      publicKey = "b965c7bf2f614975684f915187e0b04131a96390028f3dc7007bf9137d04a782",
      message = "",
      signature = "358d21d481ef812343dffa2b55b1398ade7d630c64ff2a4f48c9a634f7ae9b9f99766d982121c3ea719b338e942d9555" +
        "7cf41e3385c269ba6f51aa31a4956e0a",
      expected = true
    )
  )
  v.add(
    VerifyCase(
      id = 180,
      publicKey = "e10e4f5725acf5f0f4cf0a4ecfc6e9ad0db697f1f0c0837fd7b423a546aa305c",
      message = "6d697865642d6f726465722d322d372d32",
      signature = "abce1d42c9c8da97d4ecebbbf58934b5d0f86a775a43c57fc0261b39be7a1ea1b0f208edcf4093ef5c61c9552bbcdd29" +
        "46be36d1a1e7878d669a42bc523c5d0d",
      expected = true
    )
  )
  v
}

func wycheproofCases6(): List[VerifyCase] {
  val v: List[VerifyCase] = newList()
  v.add(
    VerifyCase(
      id = 181,
      publicKey = "f2741795058d07954f8b3c5aebbf20f28d3ec3bb32e3b51aef97e4be6afb68b5",
      message = "6d657373616765",
      signature = "854619fb2351b7a4f6ff982512e3be8c35bbb551991f42d241d44c7406dab4398188e758a19c325d24d683556dec79f7" +
        "d72291a8e5c65f0ea440a95a28d4470d",
      expected = true
    )
  )
  v.add(
    VerifyCase(
      id = 182,
      publicKey = "f2741795058d07954f8b3c5aebbf20f28d3ec3bb32e3b51aef97e4be6afb68b5",
      message = "746f7273696f6e2d312d3134",
      signature = "e1427249d2d8f07b7ed4ef639de59e17c823e821ad0d0b1e693b826bdc4cf29e94a83d6d3f382dfe0a0c1f18b73d6a1b" +
        "501bb9bcd1f7232cd60db05c8a9dc009",
      expected = true
    )
  )
  v.add(
    VerifyCase(
      id = 183,
      publicKey = "f2741795058d07954f8b3c5aebbf20f28d3ec3bb32e3b51aef97e4be6afb68b5",
      message = "",
      signature = "8dfc13f28ef98fc6a766f3bbd0c80cde4f9cafe4ba7687e7a993851f82338844a371f634c6f2e1629242942622609034" +
        "7e4d19c6ce60eb0e169fe9a00003d30b",
      expected = true
    )
  )
  v.add(
    VerifyCase(
      id = 184,
      publicKey = "f2741795058d07954f8b3c5aebbf20f28d3ec3bb32e3b51aef97e4be6afb68b5",
      message = "746f7273696f6e2d332d34",
      signature = "b149c4197787df8113491f36cb24dc5f11c1e80f9f51e1ae0031e674ea279f499df81717719f9c27b44611042cf20abb" +
        "9bf0cbf0449a3b8040ea0fdaf1e93f01",
      expected = true
    )
  )
  v.add(
    VerifyCase(
      id = 185,
      publicKey = "f2741795058d07954f8b3c5aebbf20f28d3ec3bb32e3b51aef97e4be6afb68b5",
      message = "",
      signature = "7274931dbc8c3a18a739ff8f187bdb5e6b524320c6d3976b70ce7fc016449344cdfd9e0cc96ba9efe1bf71d8ef5339d9" +
        "b70f8bceacfc66547e3b94d4e2deef06",
      expected = true
    )
  )
  v.add(
    VerifyCase(
      id = 186,
      publicKey = "f2741795058d07954f8b3c5aebbf20f28d3ec3bb32e3b51aef97e4be6afb68b5",
      message = "746f7273696f6e2d352d3231",
      signature = "7e17e7cdfda11ab37b2bf09f724b0bc2c61bbbbe6516d261b291f44ac35238502071de037a3296bba04ee65258ae39b6" +
        "3407aba333342775a1d7b830b11c9a0a",
      expected = true
    )
  )
  v.add(
    VerifyCase(
      id = 187,
      publicKey = "f2741795058d07954f8b3c5aebbf20f28d3ec3bb32e3b51aef97e4be6afb68b5",
      message = "",
      signature = "42558ff4b1a47724c98fb3c15e1d64f68b49ab538b37c33f1c11d0fb44cc201d1b7557b725655fec353a5ae7a47d37e9" +
        "2ef62f9870ccd845298acb2e12246202",
      expected = true
    )
  )
  v.add(
    VerifyCase(
      id = 188,
      publicKey = "f2741795058d07954f8b3c5aebbf20f28d3ec3bb32e3b51aef97e4be6afb68b5",
      message = "746f7273696f6e2d372d39",
      signature = "37dcc58c48d0bae5b932bcda52d52361abc2a5616bf77508a3978af9ca42964b9a481ff328c8b2263fdfd6e4a15cfa66" +
        "908edb16891c9c05183cdfb87ea0fa0a",
      expected = true
    )
  )
  v.add(
    VerifyCase(
      id = 189,
      publicKey = "f2741795058d07954f8b3c5aebbf20f28d3ec3bb32e3b51aef97e4be6afb68b5",
      message = "6d697865642d6f726465722d302d312d38",
      signature = "0ae8d293de2640c14c01f5a8c7c56d5a756128e90e436d3a2ffece7fd5830ba17181539db012fdf463ed03af9f531c66" +
        "3639fb86a9e2c3fee98690db160ae90a",
      expected = true
    )
  )
  v.add(
    VerifyCase(
      id = 190,
      publicKey = "f2741795058d07954f8b3c5aebbf20f28d3ec3bb32e3b51aef97e4be6afb68b5",
      message = "",
      signature = "61c6d52a5a68f19f24ba14e5cf78fd8a7152ca7d3d40094d58852b2adef86e6959159edc65f0e997d058f1921fe7a042" +
        "a70e0b4663008187a531ecd3e83a8604",
      expected = true
    )
  )
  v.add(
    VerifyCase(
      id = 191,
      publicKey = "f2741795058d07954f8b3c5aebbf20f28d3ec3bb32e3b51aef97e4be6afb68b5",
      message = "6d697865642d6f726465722d302d332d31",
      signature = "ec00e7504ffa36aec4fb8e721b7f808ec6ca0cfc04a5017af6cdd48efc73d730c40e1874e3e43ff521d62142c8d5dfcb" +
        "cc214ba2c47f7b5825f2956bd9f19505",
      expected = true
    )
  )
  v.add(
    VerifyCase(
      id = 192,
      publicKey = "f2741795058d07954f8b3c5aebbf20f28d3ec3bb32e3b51aef97e4be6afb68b5",
      message = "",
      signature = "4be9edab3535cc97587f84f2ed5881338755702cdc975a572e328352a5450dd56ff0fb42afb2cb9a1028eebb3ee0fba0" +
        "61789d4f7abaab06ca38ea332b1ed90c",
      expected = true
    )
  )
  v.add(
    VerifyCase(
      id = 193,
      publicKey = "f2741795058d07954f8b3c5aebbf20f28d3ec3bb32e3b51aef97e4be6afb68b5",
      message = "6d697865642d6f726465722d302d352d32",
      signature = "fe7c8cfaefecc01cae674fb2fc92626d175752824d9756548dd601be73e4353072fd18da1e55e552d1becb2d3be3fe7b" +
        "b60a2748fd648faa5f08a46d1b963004",
      expected = true
    )
  )
  v.add(
    VerifyCase(
      id = 194,
      publicKey = "f2741795058d07954f8b3c5aebbf20f28d3ec3bb32e3b51aef97e4be6afb68b5",
      message = "",
      signature = "a0a03118b7d9746f89b3d5a0deb5147c0f440e7d914ceb181232b972a099caefad8258c0fb0fef3e1da74d413d1da6c3" +
        "8a06f2a93abf3cec796ea701c1b1d601",
      expected = true
    )
  )
  v.add(
    VerifyCase(
      id = 195,
      publicKey = "f2741795058d07954f8b3c5aebbf20f28d3ec3bb32e3b51aef97e4be6afb68b5",
      message = "6d697865642d6f726465722d302d372d33",
      signature = "944b48f67a3d51c002e3781990778b57bf71017639e0441de7ae467c55fabc26bef8cf69bfda88633828d56751cfd6c8" +
        "c8180cec5efe057f97fc6c20b2a5290a",
      expected = true
    )
  )
  v.add(
    VerifyCase(
      id = 196,
      publicKey = "2bbc204b9088e455bedb8424c780f8b8a387474644664ef7641902c8ebdf333c",
      message = "",
      signature = "98b7602a3e45efb7d899687ee0ec2f81f7afe8056837a720e703b3e803cf1f8f3bbb3adeeaf502dd7222db467d04c0a8" +
        "859a6a80f67c33a84674e2d0476a860e",
      expected = true
    )
  )
  v.add(
    VerifyCase(
      id = 197,
      publicKey = "2bbc204b9088e455bedb8424c780f8b8a387474644664ef7641902c8ebdf333c",
      message = "6d697865642d6f726465722d312d322d38",
      signature = "c0f317d6b580cfd42ac199e94ce489706b6f33bb31c5300b5e13e97ca93a3e5b1268b95e1c103624704528f1c56d456b" +
        "f957f7b627b4a4c33ff53a4ffe3ea007",
      expected = true
    )
  )
  v.add(
    VerifyCase(
      id = 198,
      publicKey = "2bbc204b9088e455bedb8424c780f8b8a387474644664ef7641902c8ebdf333c",
      message = "",
      signature = "920dc46731eabe1a17f4ecc0c494fdf61f75e25f11e04de75f632d574a5d51fc61d298f11ca8e5c3f9ccae708b5b2ded" +
        "b525bf543cfa7b15a0fee46450544e0c",
      expected = true
    )
  )
  v.add(
    VerifyCase(
      id = 199,
      publicKey = "2bbc204b9088e455bedb8424c780f8b8a387474644664ef7641902c8ebdf333c",
      message = "6d697865642d6f726465722d312d342d31",
      signature = "26eb6f36777f5d04275cc0e5743c8ab428799288c2df0d5b8700aaebbfc0c664ffa55f90637bc6817390c114526dadfd" +
        "3bd8a49e1512ddaf0b1b975778f1ea0b",
      expected = true
    )
  )
  v.add(
    VerifyCase(
      id = 200,
      publicKey = "2bbc204b9088e455bedb8424c780f8b8a387474644664ef7641902c8ebdf333c",
      message = "",
      signature = "f107a692bf3ce4f10338f7b546bc16a194f625bf034e57ea9259b6102bfd9082c74224294c828a41ff069bac623f26b8" +
        "15cafe1b4af1bc0cf8297d0e39ea0505",
      expected = true
    )
  )
  v.add(
    VerifyCase(
      id = 201,
      publicKey = "2bbc204b9088e455bedb8424c780f8b8a387474644664ef7641902c8ebdf333c",
      message = "6d697865642d6f726465722d312d362d34",
      signature = "4683fec91d18d841760debf390e7d41cd92ea386b9bb095a5e4629ea7a0f1c41c1daeb539b4a9373858d5f4b843022e9" +
        "1051dbd461b1359c20e2a0775a671300",
      expected = true
    )
  )
  v.add(
    VerifyCase(
      id = 202,
      publicKey = "2bbc204b9088e455bedb8424c780f8b8a387474644664ef7641902c8ebdf333c",
      message = "",
      signature = "390a6f169020d371c8a63ff2580fac5b24cccda3929ccf88d9481aa97d32be2fe410f91c0a22ce4a008e2191a3fc1d6e" +
        "a2f26afb6d764328c478b40f1322a804",
      expected = true
    )
  )
  v.add(
    VerifyCase(
      id = 203,
      publicKey = "8b73de57a413d70e2f3f15bb4d3918ce0b85e4fe41a72efd776d06b8cae4059e",
      message = "6d697865642d6f726465722d322d312d30",
      signature = "d637793ab7d172e2156000955e1fa77c3ba0641d9f6dd20362d208c8eb6d5de62d67eeebb72fe8fc50a77b5e7862dca0" +
        "c5e40f1fde27a29e9a9c9fe81c545007",
      expected = true
    )
  )
  v.add(
    VerifyCase(
      id = 204,
      publicKey = "8b73de57a413d70e2f3f15bb4d3918ce0b85e4fe41a72efd776d06b8cae4059e",
      message = "",
      signature = "46d9381b0b3838aa7ee64fe8a1c7cfed680dc4c40e087417d5afe9bb38352ac06dfbfe9fac07dc83e62c61c1a75cfffe" +
        "e394644c5e3ff8431d3f41a119448b05",
      expected = true
    )
  )
  v.add(
    VerifyCase(
      id = 205,
      publicKey = "8b73de57a413d70e2f3f15bb4d3918ce0b85e4fe41a72efd776d06b8cae4059e",
      message = "6d697865642d6f726465722d322d332d33",
      signature = "c12e8b07833d88c5c016117273fc60a9531c39ebf89de916839ae8789b535bbc6ebac6f1bc2f3523afa93142573d9364" +
        "3cb20a57f56a4c22dac587da32ddfd04",
      expected = true
    )
  )
  v.add(
    VerifyCase(
      id = 206,
      publicKey = "8b73de57a413d70e2f3f15bb4d3918ce0b85e4fe41a72efd776d06b8cae4059e",
      message = "",
      signature = "ea080c9adc37a7c93155883251286c8fd6dced33073582f6042c5a8cf02790f3b923a0a877b56c5dec0f79b7152f0192" +
        "f74f3902281f165a4ccff2953d36590b",
      expected = true
    )
  )
  v.add(
    VerifyCase(
      id = 207,
      publicKey = "8b73de57a413d70e2f3f15bb4d3918ce0b85e4fe41a72efd776d06b8cae4059e",
      message = "6d697865642d6f726465722d322d352d38",
      signature = "f6e379c50289cf1ac8c5c8caab924740c6bc07475104c9b714bda0288f7a91e986c33153568615a8d0f519d6a65b8821" +
        "d2fcc7b1d8dc8d93fdef3f2142df100d",
      expected = true
    )
  )
  v.add(
    VerifyCase(
      id = 208,
      publicKey = "8b73de57a413d70e2f3f15bb4d3918ce0b85e4fe41a72efd776d06b8cae4059e",
      message = "",
      signature = "c275256bd5699eea59126cd9f5b22c540ebb873c80c046eb4dc7523bd2367a982283d5edbc2042101e67b803a9725e9f" +
        "7b23f809172845e9ce670d511fab580f",
      expected = true
    )
  )
  v.add(
    VerifyCase(
      id = 209,
      publicKey = "8b73de57a413d70e2f3f15bb4d3918ce0b85e4fe41a72efd776d06b8cae4059e",
      message = "6d697865642d6f726465722d322d372d32",
      signature = "845813c2ac916dc3977f05862e28fccb403d32f71fbcc817ae3ebe10d841c189dc8b663018aaa36438193f081ea7f57c" +
        "904d32af78eb2fb20394d8eb640e6f06",
      expected = true
    )
  )
  v.add(
    VerifyCase(
      id = 210,
      publicKey = "d1e06adf4e05e248e1e52beca14b6be4da0af01b41645d2849b407ec22f41d47",
      message = "af82",
      signature = "6291d657deec24024827e69c3abe01a30ce548a284743a445e3680d7db5ac3ac18ff9b538d16f290ae67f760984dc659" +
        "4a7c15e9716ed28dc027beceea1ec40a",
      expected = false
    )
  )
  v
}

func testRfc8032PublicKeys(): Unit {
  for v in rfc8032Vectors() {
    assertEqual(lower(ed25519PublicKey(hexBytes(v.seed))), v.publicKey, "RFC 8032 " + v.name + ": public key")
  }
}

func testRfc8032Signatures(): Unit {
  for v in rfc8032Vectors() {
    val sig = ed25519Sign(hexBytes(v.seed), hexBytes(v.message))
    assertEqual(lower(sig), v.signature, "RFC 8032 " + v.name + ": signature")
  }
}

func testRfc8032Verify(): Unit {
  for v in rfc8032Vectors() {
    val pk = hexBytes(v.publicKey)
    val msg = hexBytes(v.message)
    val sig = hexBytes(v.signature)
    assertTrue(ed25519Verify(pk, msg, sig), "RFC 8032 " + v.name + ": verifies")
    val tampered = msg.concat([1u8])
    assertTrue(not ed25519Verify(pk, tampered, sig), "RFC 8032 " + v.name + ": a changed message does not verify")
  }
}

func runCases(cases: in List[VerifyCase]): Unit {
  for c in cases {
    val got = ed25519Verify(hexBytes(c.publicKey), hexBytes(c.message), hexBytes(c.signature))
    assertTrue(got == c.expected, "Wycheproof tcId " + toString(c.id) + ": expected " + toString(c.expected))
  }
}

func testWycheproof(): Unit {
  runCases(wycheproofCases0())
  runCases(wycheproofCases1())
  runCases(wycheproofCases2())
  runCases(wycheproofCases3())
  runCases(wycheproofCases4())
  runCases(wycheproofCases5())
  runCases(wycheproofCases6())
}

func testStrictChecks(): Unit {
  val pk = hexBytes("d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a")
  val empty: slice[Byte] = []
  val sPlusL = hexBytes(
    "e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e065224901554c8c7872aa064e049dbb3013fbf29380d25bf5f0595bbe24655141438e7a101b"
  )
  assertTrue(not ed25519Verify(pk, empty, sPlusL), "S + L (a malleated signature) is rejected")
  val sig = hexBytes(
    "e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e065224901555fb8821590a33bacc61e39701cf9b46bd25bf5f0595bbe24655141438e7a100b"
  )
  assertTrue(
    not ed25519Verify(hexBytes("f0ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f"), empty, sig),
    "a y coordinate encoded as y + p is rejected"
  )
  assertTrue(
    not ed25519Verify(hexBytes("0100000000000000000000000000000000000000000000000000000000000080"), empty, sig),
    "x = 0 with the sign bit set is rejected"
  )
  assertTrue(
    not ed25519Verify(hexBytes("0100000000000000000000000000000000000000000000000000000000000000"), empty, sig),
    "the identity (small order) as a public key is rejected"
  )
  assertTrue(not ed25519Verify(pk.slice(0, 31), empty, sig), "a 31-byte public key is rejected")
  assertTrue(not ed25519Verify(pk, empty, sig.slice(0, 63)), "a 63-byte signature is rejected")
  assertTrue(not ed25519Verify(pk, empty, sig.concat([0u8])), "a 65-byte signature is rejected")
}

func testRoundTrip(): Unit {
  val seed = hexBytes("000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f")
  val message = encodeUtf8("lyric-plugin-sig-v1\n")
  val pk = ed25519PublicKey(seed)
  assertEqual(
    lower(pk),
    "03a107bff3ce10be1d70dd18e74bc09967e4d6309ba50d5f1ddc8664125531b8",
    "public key matches the reference"
  )
  val sig = ed25519Sign(seed, message)
  assertEqual(
    lower(sig),
    "79d2031bcea1be1dbb6a366fa6656dd5107c3a2dcb50e28b58ed17ea2ad0362fa70b6a18163ba0fe53346ef276e06343038c39213d696eafde03f2d5d098990e",
    "signature matches the reference"
  )
  assertTrue(ed25519Verify(pk, message, sig), "own signature verifies")
  assertTrue(lower(ed25519Sign(seed, message)) == lower(sig), "signing is deterministic")
  val other = ed25519PublicKey(hexBytes("0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f20"))
  assertTrue(not ed25519Verify(other, message, sig), "another key does not verify it")
}

func main(): Int {
  testRfc8032PublicKeys()
  testRfc8032Signatures()
  testRfc8032Verify()
  testRoundTrip()
  testStrictChecks()
  testWycheproof()
  println("ed25519 tests: ok")
  return 0
}
