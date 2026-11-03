// Module B, dlopen'ed by the corpus after the first round of lookups.
import A
extension Late: @retroactive Equatable { public static func == (a: Late, b: Late) -> Bool { true } }
extension LateG: @retroactive Equatable where T: Equatable { public static func == (a: LateG, b: LateG) -> Bool { true } }
extension LateC: @retroactive CustomStringConvertible { public var description: String { "LateC" } }
