import Crypto
import Darwin

/// Blowfish with the "expensive key schedule" bcrypt uses, only as far as
/// `bcrypt_pbkdf` needs it (spec.ssh-identity.md §6.4). Not a general
/// cipher: there is no decryption and no padding.
struct Blowfish {
  /// P-array (18 words) followed by S-boxes S0–S3 (256 words each).
  private var state: [UInt32]

  private static let sBase = 18

  init() { state = Self.initialP + Self.initialS }

  /// The ordinary Blowfish key schedule (test vectors).
  init(key: [UInt8]) {
    self.init()
    expand0(key: key)
  }

  /// Big-endian word from `data` at `j`, wrapping cyclically.
  @inline(__always)
  private static func streamWord(
    _ data: UnsafeBufferPointer<UInt8>,
    _ j: inout Int
  ) -> UInt32 {
    var word: UInt32 = 0
    for _ in 0 ..< 4 {
      if j >= data.count { j = 0 }
      word = word << 8 | UInt32(data[j])
      j += 1
    }
    return word
  }

  @inline(__always)
  private static func encipher(
    _ s: UnsafeMutableBufferPointer<UInt32>,
    _ left: inout UInt32,
    _ right: inout UInt32
  ) {
    @inline(__always)
    func f(_ x: UInt32) -> UInt32 {
      let a = s[sBase + Int(x >> 24)]
      let b = s[sBase + 0x100 + Int((x >> 16) & 0xFF)]
      let c = s[sBase + 0x200 + Int((x >> 8) & 0xFF)]
      let d = s[sBase + 0x300 + Int(x & 0xFF)]
      return ((a &+ b) ^ c) &+ d
    }
    var l = left ^ s[0]
    var r = right
    var n = 1
    while n < 17 {
      r ^= f(l) ^ s[n]
      l ^= f(r) ^ s[n + 1]
      n += 2
    }
    left = r ^ s[17]
    right = l
  }

  /// Encrypts consecutive 64-bit blocks of `words` in place (ECB).
  mutating func encrypt(_ words: inout [UInt32]) {
    state.withUnsafeMutableBufferPointer { s in
      var i = 0
      while i + 1 < words.count {
        var (l, r) = (words[i], words[i + 1])
        Self.encipher(s, &l, &r)
        (words[i], words[i + 1]) = (l, r)
        i += 2
      }
    }
  }

  /// `Blowfish_expand0state`: mixes `key` into P, then regenerates the
  /// whole state by repeated encryption.
  mutating func expand0(key: [UInt8]) {
    key.withUnsafeBufferPointer { key in
      state.withUnsafeMutableBufferPointer { s in
        var j = 0
        for i in 0 ..< 18 { s[i] ^= Self.streamWord(key, &j) }
        var l: UInt32 = 0
        var r: UInt32 = 0
        var i = 0
        while i < s.count {
          Self.encipher(s, &l, &r)
          s[i] = l
          s[i + 1] = r
          i += 2
        }
      }
    }
  }

  /// `Blowfish_expandstate`: as `expand0`, also mixing `data` into each
  /// block before it is encrypted.
  mutating func expand(data: [UInt8], key: [UInt8]) {
    key.withUnsafeBufferPointer { key in
      data.withUnsafeBufferPointer { data in
        state.withUnsafeMutableBufferPointer { s in
          var j = 0
          for i in 0 ..< 18 { s[i] ^= Self.streamWord(key, &j) }
          j = 0
          var l: UInt32 = 0
          var r: UInt32 = 0
          var i = 0
          while i < s.count {
            l ^= Self.streamWord(data, &j)
            r ^= Self.streamWord(data, &j)
            Self.encipher(s, &l, &r)
            s[i] = l
            s[i + 1] = r
            i += 2
          }
        }
      }
    }
  }

  mutating func reset() {
    state.withUnsafeMutableBytes {
      _ = memset_s($0.baseAddress, $0.count, 0, $0.count)
    }
  }
}

/// OpenBSD's `bcrypt_pbkdf`, the KDF of encrypted `openssh-key-v1` files
/// (spec.ssh-identity.md §6.4). Callers bound `rounds` before calling.
enum BcryptPBKDF {
  static let hashSize = 32
  private static let magic = Array("OxychromaticBlowfishSwatDynamite".utf8)

  enum Failure: Error, Equatable { case invalidParameters, cancelled }

  /// Derives `length` bytes. `isCancelled` is polled once per round.
  static func derive(
    passphrase: [UInt8],
    salt: [UInt8],
    rounds: Int,
    length: Int,
    isCancelled: () -> Bool = { false }
  ) throws(Failure) -> [UInt8] {
    guard rounds >= 1, !passphrase.isEmpty, !salt.isEmpty,
      salt.count <= 1 << 20, length > 0, length <= hashSize * hashSize
    else { throw .invalidParameters }
    let stride = (length + hashSize - 1) / hashSize
    let amount = (length + stride - 1) / stride
    var sha2pass = Array(SHA512.hash(data: passphrase))
    defer { sha2pass.resetBytes() }
    var key = [UInt8](repeating: 0, count: length)
    var remaining = length
    var count: UInt32 = 1
    while remaining > 0 {
      var countSalt = salt
      countSalt += withUnsafeBytes(of: count.bigEndian, Array.init)
      var sha2salt = Array(SHA512.hash(data: countSalt))
      var block = hash(sha2pass, sha2salt)
      var output = block
      defer {
        sha2salt.resetBytes()
        block.resetBytes()
        output.resetBytes()
      }
      for _ in 1 ..< rounds {
        if isCancelled() {
          key.resetBytes()
          throw .cancelled
        }
        sha2salt = Array(SHA512.hash(data: block))
        block = hash(sha2pass, sha2salt)
        for i in 0 ..< hashSize { output[i] ^= block[i] }
      }
      // Output bytes are interleaved across the blocks.
      var written = 0
      for i in 0 ..< min(amount, remaining) {
        let destination = i * stride + Int(count - 1)
        if destination >= length { break }
        key[destination] = output[i]
        written += 1
      }
      remaining -= written
      count += 1
    }
    return key
  }

  /// `bcrypt_hash`: 64 rounds of the expensive key schedule keyed by both
  /// digests, then the magic string encrypted 64 times.
  static func hash(_ sha2pass: [UInt8], _ sha2salt: [UInt8]) -> [UInt8] {
    var cipher = Blowfish()
    defer { cipher.reset() }
    cipher.expand(data: sha2salt, key: sha2pass)
    for _ in 0 ..< 64 {
      cipher.expand0(key: sha2salt)
      cipher.expand0(key: sha2pass)
    }
    var words = [UInt32](repeating: 0, count: 8)
    for i in 0 ..< 8 {
      for byte in magic[4 * i ..< 4 * i + 4] {
        words[i] = words[i] << 8 | UInt32(byte)
      }
    }
    for _ in 0 ..< 64 { cipher.encrypt(&words) }
    // Little-endian output, as OpenBSD's implementation writes it.
    var out = [UInt8](repeating: 0, count: hashSize)
    for (i, word) in words.enumerated() {
      out[4 * i] = UInt8(truncatingIfNeeded: word)
      out[4 * i + 1] = UInt8(truncatingIfNeeded: word >> 8)
      out[4 * i + 2] = UInt8(truncatingIfNeeded: word >> 16)
      out[4 * i + 3] = UInt8(truncatingIfNeeded: word >> 24)
    }
    return out
  }
}
