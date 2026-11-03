// TeraScale Swift validation corpus: every case is asked through the runtime's exported entry points (what
// AttributeGraph calls) and through a dynamic cast; tests/swift/run.sh compares the output with and without the
// accelerator. Each case is asked once per protocol, cold, as the cases the accelerator answers are cold lookups.
import A
import CoreGraphics
import Foundation

typealias Conforms = @convention(c) (UnsafeRawPointer, UnsafeRawPointer) -> UnsafeRawPointer?
let entries: [(String, Conforms)] = ["swift_conformsToProtocol", "swift_conformsToProtocol2", "swift_conformsToProtocolCommon"].map {
    ($0, unsafeBitCast(dlsym(UnsafeMutableRawPointer(bitPattern: -2), $0)!, to: Conforms.self))
}
func proto(_ module: String, _ name: String) -> UnsafeRawPointer {
    let sym = module == "s" ? "$s\(name)Mp" : "$s\(module.count)\(module)\(name.count)\(name)Mp"
    guard let p = dlsym(UnsafeMutableRawPointer(bitPattern: -2), sym) else { fatalError("no \(sym)") }
    return UnsafeRawPointer(p)
}
let Eq = proto("s", "SQ"), Hash = proto("s", "SH"), Desc = proto("s", "s23CustomStringConvertible")
let Mine = proto("Corpus", "MyProto"), Other = proto("Corpus", "OtherProto")
let protos: [(String, UnsafeRawPointer)] = [("Equatable", Eq), ("Hashable", Hash), ("CustomStringConvertible", Desc),
                                           ("MyProto", Mine), ("OtherProto", Other)]
var round = 0
// Entry point by case so that all three are exercised; the cast goes through the runtime's dynamic-cast path.
func check(_ name: String, _ t: Any.Type) {
    let md = unsafeBitCast(t, to: UnsafeRawPointer.self)
    var line = "\(name):"
    for (i, (pn, p)) in protos.enumerated() {
        let e = entries[(name.utf8.count + i) % 3].1
        line += " \(pn)=\(e(md, p) != nil ? 1 : 0)"
    }
    print(line)
}
func cast(_ name: String, _ v: Any) {
    print("\(name) cast: Equatable=\(v is any Equatable ? 1 : 0) Hashable=\(v is any Hashable ? 1 : 0) MyProto=\(v is any MyProto ? 1 : 0)")
}

public protocol MyProto {}
public protocol OtherProto {}
struct NE {}
enum NEE { case a, b(Int) }
struct Eqs: Equatable, MyProto { var x = 0 }
enum EqE: Hashable { case a }
struct G<T> {}
extension G: Equatable where T: Equatable {}
extension G: MyProto where T: MyProto {}
struct Two<A, B> {}
extension Two: Equatable where A: Equatable, B: Hashable { static func == (a: Two, b: Two) -> Bool { true } }
struct Three<A, B, C> {}
extension Three: Equatable where C: Equatable { static func == (a: Three, b: Three) -> Bool { true } }
struct Outer<T> { struct Inner<U> {} }
extension Outer.Inner: Equatable where U: Equatable {}
struct SameT<T> {}
extension SameT: Equatable where T == Int {}
struct Assoc<T: Sequence> {}
extension Assoc: Equatable where T.Element: Equatable { static func == (a: Assoc, b: Assoc) -> Bool { true } }
struct Multi<T> {}
extension Multi: MyProto where T: Equatable, T: Hashable {}
enum GE<T> { case v(T) }
extension GE: Equatable where T: Equatable {}
class Root {}
class EqBase: Equatable { static func == (a: EqBase, b: EqBase) -> Bool { true } }
class EqSub: EqBase {}
class EqSubSub: EqSub {}
class NSSub: NSObject {}
class NSSubMine: NSObject, MyProto {}
class NSSubSub: NSSubMine {}
extension DateFormatter: MyProto {}
class DFSub: DateFormatter, @unchecked Sendable {}
class GC<T> {}
extension GC: Equatable where T: Equatable { static func == (a: GC, b: GC) -> Bool { true } }
class GSubInt: GC<Int> {}
class GSubNE: GC<NE> {}
@objc(TSCorpusNamed) class Named: NSObject {}
extension Named: OtherProto {}
actor Act {}
final class Fin: MyProto {}
class FinSub {}
extension FinSub: Hashable { static func == (a: FinSub, b: FinSub) -> Bool { true }; func hash(into h: inout Hasher) {} }

func all() {
    round += 1
    let r = "r\(round)"
    check("\(r) Int", Int.self); check("\(r) String", String.self); check("\(r) NE", NE.self); check("\(r) NEE", NEE.self)
    check("\(r) Eqs", Eqs.self); check("\(r) EqE", EqE.self)
    check("\(r) G<Int>", G<Int>.self); check("\(r) G<NE>", G<NE>.self); check("\(r) G<G<NE>>", G<G<NE>>.self)
    check("\(r) G<G<Int>>", G<G<Int>>.self); check("\(r) G<Eqs>", G<Eqs>.self); check("\(r) G<Root>", G<Root>.self)
    check("\(r) G<EqSub>", G<EqSub>.self); check("\(r) G<(Int,Int)>", G<(Int, Int)>.self)
    check("\(r) Two<Int,Int>", Two<Int, Int>.self); check("\(r) Two<NE,Int>", Two<NE, Int>.self)
    check("\(r) Two<Int,NE>", Two<Int, NE>.self); check("\(r) Two<Int,Eqs>", Two<Int, Eqs>.self)
    check("\(r) Three<NE,NE,Int>", Three<NE, NE, Int>.self); check("\(r) Three<Int,Int,NE>", Three<Int, Int, NE>.self)
    check("\(r) Outer<NE>.Inner<Int>", Outer<NE>.Inner<Int>.self); check("\(r) Outer<Int>.Inner<NE>", Outer<Int>.Inner<NE>.self)
    check("\(r) SameT<Int>", SameT<Int>.self); check("\(r) SameT<String>", SameT<String>.self)
    check("\(r) Assoc<[Int]>", Assoc<[Int]>.self); check("\(r) Assoc<[NE]>", Assoc<[NE]>.self)
    check("\(r) Multi<Int>", Multi<Int>.self); check("\(r) Multi<Eqs>", Multi<Eqs>.self); check("\(r) Multi<NE>", Multi<NE>.self)
    check("\(r) GE<Int>", GE<Int>.self); check("\(r) GE<NE>", GE<NE>.self)
    // Deep conditional chains (SwiftUI's ModifiedContent<ModifiedContent<...>>), past the recursion depth of 0.12.0.
    check("\(r) G^8<NE>", G<G<G<G<G<G<G<G<NE>>>>>>>>.self); check("\(r) G^8<Int>", G<G<G<G<G<G<G<G<Int>>>>>>>>.self)
    check("\(r) Two^6", Two<Int, Two<Int, Two<Int, Two<Int, Two<Int, Two<Int, NE>>>>>>.self)
    check("\(r) Two^6 ok", Two<Int, Two<Int, Two<Int, Two<Int, Two<Int, Two<Int, Int>>>>>>.self)
    check("\(r) [[[[[[NE?]]]]]]", [[[[[[NE?]]]]]].self); check("\(r) G^12<Root>", G<G<G<G<G<G<G<G<G<G<G<G<Root>>>>>>>>>>>>.self)
    check("\(r) [Int]", [Int].self); check("\(r) [NE]", [NE].self); check("\(r) [[NE]]", [[NE]].self)
    check("\(r) [Int:NE]", [Int: NE].self); check("\(r) [Int:Int]", [Int: Int].self); check("\(r) Set<Int>", Set<Int>.self)
    check("\(r) NE?", Optional<NE>.self); check("\(r) Int?", Optional<Int>.self); check("\(r) Root?", Optional<Root>.self)
    check("\(r) Result<Int,CocoaError>", Result<Int, CocoaError>.self); check("\(r) Result<NE,CocoaError>", Result<NE, CocoaError>.self)
    check("\(r) timespec", timespec.self); check("\(r) CGPoint", CGPoint.self); check("\(r) NSRange", NSRange.self)
    check("\(r) ComparisonResult", ComparisonResult.self); check("\(r) CGRect?", Optional<CGRect>.self)
    check("\(r) NSString.CompareOptions", NSString.CompareOptions.self); check("\(r) CocoaError", CocoaError.self)
    check("\(r) Root", Root.self); check("\(r) EqBase", EqBase.self); check("\(r) EqSub", EqSub.self); check("\(r) EqSubSub", EqSubSub.self)
    check("\(r) NSObject", NSObject.self); check("\(r) NSSub", NSSub.self); check("\(r) NSSubMine", NSSubMine.self)
    check("\(r) NSSubSub", NSSubSub.self); check("\(r) NSString", NSString.self); check("\(r) NSMutableString", NSMutableString.self)
    check("\(r) DateFormatter", DateFormatter.self); check("\(r) DFSub", DFSub.self); check("\(r) NumberFormatter", NumberFormatter.self)
    check("\(r) GC<Int>", GC<Int>.self); check("\(r) GC<NE>", GC<NE>.self); check("\(r) GSubInt", GSubInt.self); check("\(r) GSubNE", GSubNE.self)
    check("\(r) Named", Named.self); check("\(r) Act", Act.self); check("\(r) Fin", Fin.self); check("\(r) FinSub", FinSub.self)
    check("\(r) (Int,Int)", (Int, Int).self); check("\(r) (NE,Int)", (NE, Int).self); check("\(r) (Int)->Int", ((Int) -> Int).self)
    check("\(r) Int.Type", Int.Type.self); check("\(r) any Error", (any Error).self); check("\(r) any Error.Type", (any Error.Type).self)
    check("\(r) any Equatable", (any Equatable).self); check("\(r) AnyObject", AnyObject.self); check("\(r) Any", Any.self)
    check("\(r) Late", Late.self); check("\(r) LateG<Int>", LateG<Int>.self); check("\(r) LateG<NE>", LateG<NE>.self)
    check("\(r) LateC", LateC.self); check("\(r) LateSub", LateSub.self)
    cast("\(r) NE()", NE()); cast("\(r) G<NE>()", G<NE>()); cast("\(r) G<Int>()", G<Int>()); cast("\(r) [NE]", [NE()])
    cast("\(r) Root()", Root()); cast("\(r) EqSub()", EqSub()); cast("\(r) NSSub()", NSSub()); cast("\(r) \"s\" as NSString", "s" as NSString)
    cast("\(r) DFSub()", DFSub()); cast("\(r) (1,2)", (1, 2)); cast("\(r) Late()", Late()); cast("\(r) LateC()", LateC())
}

all()
// Retroactive conformances arrive with a later image: the same types must now conform.
let libB = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "libB.dylib"
guard dlopen(libB, RTLD_NOW) != nil else { fatalError(String(cString: dlerror())) }
all()
// Concurrent first lookups on many threads (the index is built under contention).
DispatchQueue.concurrentPerform(iterations: 8) { i in
    for _ in 0..<200 {
        _ = entries[i % 3].1(unsafeBitCast(G<G<G<NE>>>.self, to: UnsafeRawPointer.self), Eq)
        _ = entries[(i + 1) % 3].1(unsafeBitCast(GSubNE.self, to: UnsafeRawPointer.self), Hash)
    }
}
print("concurrent: done")
