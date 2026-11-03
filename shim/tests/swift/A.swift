// Module A: types that gain conformances only when libB is loaded (retroactive conformances in a later image).
public struct Late { public init() {} }
public struct LateG<T> { public init() {} }
public class LateC { public init() {} }
public class LateSub: LateC {}
