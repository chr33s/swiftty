import SwifttyCore
import Testing

struct DamageTests {
    @Test(arguments: [Int.min, -513, -1], [false, true])
    func `negative rows are outside every damage region`(_ row: Int, _ full: Bool) {
        var damage = DamageRegion(full: full)
        let original = damage
        #expect(!damage.contains(row: row))
        damage.insert(row: row)
        #expect(damage == original)
    }

    @Test(arguments: [
        (Int.min ..< 0, 0 ..< 0, false),
        (Int.min ..< 2, 0 ..< 2, false),
        (-3 ..< 3, 0 ..< 3, false),
        (63 ..< 66, 63 ..< 66, false),
        (511 ..< 512, 511 ..< 512, false),
        (0 ..< 513, 0 ..< 512, true),
        (512 ..< 513, 0 ..< 0, true),
        (1000 ..< 1000, 0 ..< 0, false),
        (1000 ..< Int.max, 0 ..< 0, true),
        (Int.min ..< Int.max, 0 ..< 512, true),
    ])
    func `row ranges clip negative rows and retain the full damage fallback`(_ fixture: (Range<Int>, Range<Int>, Bool)) {
        var damage = DamageRegion()
        damage.insert(rows: fixture.0)
        var expected = DamageRegion(full: fixture.2)
        for row in fixture.1 {
            expected.insert(row: row)
        }
        #expect(damage == expected)
        #expect(!damage.contains(row: -1))
    }
}
