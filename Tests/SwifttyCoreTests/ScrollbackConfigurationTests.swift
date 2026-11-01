import TestSupport
@testable import SwifttyCore
import Testing

struct ScrollbackConfigurationTests {
  @Test
  func `scrollback aliases share one budget and validate finite values`() {
    var config = Configuration.configured([
      ("scrollback-limit", "2000000"), ("scrollback-limit-bytes", "3000000"),
      ("scrollback-limit-lines", "5000"), ("scrollback-compression", "false"),
    ])
    #expect(config.diagnostics.isEmpty)
    #expect(config.scrollbackLimit == 3_000_000)
    #expect(config.scrollbackLimitLines == 5_000)
    #expect(!config.scrollbackCompression)
    let session = config.sessionConfiguration()
    #expect(session.scrollbackLimitBytes == 3_000_000)
    #expect(session.scrollbackLimitRows == 5_000)
    #expect(!session.scrollbackCompression)
    // The last valid assignment wins, whichever alias it uses.
    #expect(config.set("scrollback-limit", "42") == nil)
    #expect(config.scrollbackLimit == 42)
    for key in ["scrollback-limit-bytes", "scrollback-limit-lines"] {
      for bad in ["-1", "unlimited", "99999999999999999999999"] {
        #expect(config.set(key, bad) != nil, "\(key) = \(bad)")
      }
    }
    #expect(
      config.scrollbackLimit == 42 && config.scrollbackLimitLines == 5_000
    )
    #expect(config.set("scrollback-compression", "maybe") != nil)
    #expect(config.set("scrollback-limit-lines", "0") == nil)
    #expect(config.sessionConfiguration().scrollbackLimitRows == 0)
    // Empty values reset to the defaults.
    #expect(config.set("scrollback-limit-bytes", "") == nil)
    #expect(config.set("scrollback-limit-lines", "") == nil)
    #expect(config.set("scrollback-compression", "") == nil)
    #expect(config.scrollbackLimit == 10_000_000)
    #expect(config.scrollbackLimitLines == 100_000)
    #expect(config.scrollbackCompression)
  }
}
