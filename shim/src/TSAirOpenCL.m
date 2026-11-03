// TeraScale Compute - AIR (Metal's LLVM IR) kernel -> OpenCL C 1.2 (docs/PIANO-COMPUTE.md).
//
// Kernels the GL path cannot run (device stores, atomics, threadgroup memory, barriers, scattered
// writes) are emitted as OpenCL C and run on the GPU through TSMtlComputeCL.m. OpenCL C is plain C
// with pointers and goto, so unlike the GLSL translator nothing has to be rebuilt:
//   - every SSA value is a variable declared at kernel scope; every basic block is a label, branches
//     are gotos and phis become parallel copies on the incoming edges (the CL compiler, clang based,
//     structurizes by itself);
//   - pointers are byte pointers (`<space> uchar *`); GEPs add byte offsets computed from the AIR
//     data layout, loads and stores cast to the accessed type (vloadN/vstoreN when the IR alignment is
//     below OpenCL's natural vector alignment, vload_half/vstore_half for half data);
//   - integers are unsigned CL types of the same width (i1 = bool, i1 vectors = intN masks of 0/-1),
//     signed operations reinterpret with as_<signed>; half is computed in float;
//   - buffers are kernel arguments (base pointer + byte offset of the binding), threadgroup memory is
//     __local, textures are image arguments (read_write: a read view and a write view of the same GL
//     texture), samplers are sampler_t arguments or program-scope constants (constexpr samplers);
//   - the Metal grid built-ins come from get_global_id & co. plus four uint4 arguments the dispatcher
//     sets (grid size, threadgroup offset of a partial enqueue, threadgroups per grid, threadgroup size).
// Not supported (the kernel is rejected with a reason): simdgroup/quadgroup functions, 64-bit atomics,
// double, argument buffers, imageblocks, texture buffers, cube textures, depth textures, 3D writes.
#import "TSPrivate.h"
#import "TSLLVM.h"

#define KEY(p) [NSValue valueWithPointer:(const void *)(p)]
#define FAIL(...) do { if (!self->_error) self->_error = [NSString stringWithFormat:__VA_ARGS__]; return nil; } while (0)
#define FAILB(...) do { if (!self->_error) self->_error = [NSString stringWithFormat:__VA_ARGS__]; return NO; } while (0)

@implementation TSCLKernelSource
@end

#pragma mark - Metadata helpers

static NSString *TSCLMDString(LLVMValueRef v) {
    if (!v) return nil;
    unsigned len = 0;
    const char *s = ts_LLVMGetMDString(v, &len);
    return s ? [[NSString alloc] initWithBytes:s length:len encoding:NSUTF8StringEncoding] : nil;
}

static NSArray *TSCLMDOperands(LLVMValueRef node) {
    unsigned n = ts_LLVMGetMDNodeNumOperands(node);
    LLVMValueRef *ops = calloc(MAX(n, 1), sizeof *ops);
    ts_LLVMGetMDNodeOperands(node, ops);
    NSMutableArray *a = [NSMutableArray arrayWithCapacity:n];
    for (unsigned i = 0; i < n; i++) [a addObject:KEY(ops[i])];
    free(ops);
    return a;
}

static LLVMValueRef TSCLOp(NSArray *ops, NSUInteger i) { return i < ops.count ? (LLVMValueRef)[ops[i] pointerValue] : NULL; }

static long TSCLMDIntAfter(NSArray *ops, NSString *key, long fallback) {
    for (NSUInteger i = 0; i + 1 < ops.count; i++) {
        if (![TSCLMDString(TSCLOp(ops, i)) isEqualToString:key]) continue;
        LLVMValueRef v = TSCLOp(ops, i + 1);
        if (v && ts_LLVMIsAConstantInt(v)) return (long)ts_LLVMConstIntGetSExtValue(v);
    }
    return fallback;
}

static BOOL TSCLMDHas(NSArray *ops, NSString *key) {
    for (NSUInteger i = 0; i < ops.count; i++) if ([TSCLMDString(TSCLOp(ops, i)) isEqualToString:key]) return YES;
    return NO;
}

static NSString *TSCLMDStringAfter(NSArray *ops, NSString *key) {
    for (NSUInteger i = 0; i + 1 < ops.count; i++)
        if ([TSCLMDString(TSCLOp(ops, i)) isEqualToString:key]) return TSCLMDString(TSCLOp(ops, i + 1));
    return nil;
}

// Exact float literal (hex), as OpenCL C (C99) accepts.
static NSString *TSCLFloat(double d) {
    if (isnan(d)) return @"NAN";
    if (isinf(d)) return d > 0 ? @"INFINITY" : @"(-INFINITY)";
    return [NSString stringWithFormat:@"%af", (double)(float)d];
}

static NSString *TSCLComp(unsigned i) { return [NSString stringWithFormat:@"s%X", i]; }

#pragma mark - Values

typedef enum { TSCLVExpr, TSCLVTexture, TSCLVSampler } TSCLVKind;

@interface TSCLV : NSObject {
@public
    TSCLVKind kind;
    NSString *expr;      // C expression (variables, constants) or argument name (textures, samplers)
    NSString *space;     // pointers: "__global", "__local", "__constant" or "" (private)
    int slot;            // textures, samplers: Metal index (-1: constexpr sampler / read sampler)
    BOOL readSampler;    // air.get_read_sampler: sampler-less read
    // samplers: per-axis addressing OpenCL's single mode cannot express (B3). Argument samplers carry it in the
    // uint argument ts_s<slot>_am set by the dispatcher (0 = the CL sampler does it all); constexpr samplers
    // have it in their word (key) and an edge-clamping twin (edgeExpr) for the manual path.
    NSString *amExpr, *edgeExpr;
    uint64_t key;
    BOOL constexprKey;
    // textures
    unsigned dims;       // 1, 2, 3
    BOOL array, rw;
    char elem;           // 'f', 'u', 'i'
}
@end
@implementation TSCLV
@end

static TSCLV *TSCLExpr(NSString *e, NSString *space) { TSCLV *v = [TSCLV new]; v->kind = TSCLVExpr; v->expr = e; v->space = space; return v; }

#pragma mark - Translator

@interface TSCLTranslator : NSObject {
@public
    LLVMModuleRef _mod;
    LLVMTargetDataRef _td;
    LLVMValueRef _fn;
    NSMutableString *_types, *_helpers, *_globals, *_params, *_decls, *_body, *_prologue;
    NSMutableDictionary<NSValue *, TSCLV *> *_vals;
    NSMutableDictionary<NSValue *, NSString *> *_typeNames;
    NSMutableSet<NSString *> *_helperSet;
    NSMutableDictionary<NSValue *, NSNumber *> *_labels;
    NSMutableData *_args;
    int _vars;
    NSUInteger _tgStatic;
    BOOL _barriers, _fastMath, _shape, _localArgs;
    NSMutableIndexSet *_nullSlots, *_lodSlots;   // textures tested with is_null_texture / used at a mip level != 0
    NSString *_error;
}
@end

@implementation TSCLTranslator

#pragma mark Types

- (unsigned)lanes:(LLVMTypeRef)t { return ts_LLVMGetTypeKind(t) == LLVMVectorTypeKind ? ts_LLVMGetVectorSize(t) : 1; }
- (LLVMTypeRef)scalarOf:(LLVMTypeRef)t { return ts_LLVMGetTypeKind(t) == LLVMVectorTypeKind ? ts_LLVMGetElementType(t) : t; }
- (BOOL)isFloat:(LLVMTypeRef)t {
    LLVMTypeKind k = ts_LLVMGetTypeKind([self scalarOf:t]);
    return k == LLVMFloatTypeKind || k == LLVMHalfTypeKind;
}
- (BOOL)isHalf:(LLVMTypeRef)t { return ts_LLVMGetTypeKind([self scalarOf:t]) == LLVMHalfTypeKind; }
- (unsigned)intWidth:(LLVMTypeRef)t {
    LLVMTypeRef s = [self scalarOf:t];
    return ts_LLVMGetTypeKind(s) == LLVMIntegerTypeKind ? ts_LLVMGetIntTypeWidth(s) : 0;
}

// Unsigned (or float) scalar name of a lane type; nil if unsupported.
- (NSString *)laneName:(LLVMTypeRef)s {
    switch (ts_LLVMGetTypeKind(s)) {
    case LLVMHalfTypeKind: case LLVMFloatTypeKind: return @"float";
    case LLVMIntegerTypeKind:
        switch (ts_LLVMGetIntTypeWidth(s)) {
        case 1: return @"bool"; case 8: return @"uchar"; case 16: return @"ushort"; case 32: return @"uint"; case 64: return @"ulong";
        }
        return nil;
    default: return nil;
    }
}

static BOOL TSCLLanesOK(unsigned n) { return n == 2 || n == 3 || n == 4 || n == 8 || n == 16; }

// CL type of an SSA value of type t.
- (NSString *)ctype:(LLVMTypeRef)t {
    switch (ts_LLVMGetTypeKind(t)) {
    case LLVMVoidTypeKind: return @"void";
    case LLVMHalfTypeKind: case LLVMFloatTypeKind: case LLVMIntegerTypeKind: {
        NSString *n = [self laneName:t];
        if (!n) FAIL(@"unsupported scalar type (i%u)", [self intWidth:t]);
        return n;
    }
    case LLVMDoubleTypeKind: FAIL(@"double");
    case LLVMVectorTypeKind: {
        unsigned n = ts_LLVMGetVectorSize(t);
        if (!TSCLLanesOK(n)) FAIL(@"vector of %u lanes", n);
        LLVMTypeRef e = ts_LLVMGetElementType(t);
        NSString *b = [self laneName:e];
        if (!b) FAIL(@"unsupported vector lane type");
        if ([b isEqualToString:@"bool"]) b = @"int";
        return [NSString stringWithFormat:@"%@%u", b, n];
    }
    case LLVMPointerTypeKind: return [NSString stringWithFormat:@"%@ uchar *", [self spaceOfAS:ts_LLVMGetPointerAddressSpace(t)]];
    case LLVMStructTypeKind: case LLVMArrayTypeKind: return [self aggregateName:t];
    default: FAIL(@"unsupported type kind %d", ts_LLVMGetTypeKind(t));
    }
}

- (NSString *)spaceOfAS:(unsigned)as {
    switch (as) { case 1: case 2: return @"__global"; case 3: return @"__local"; default: return @""; }
}

- (NSString *)aggregateName:(LLVMTypeRef)t {
    NSString *name = _typeNames[KEY(t)];
    if (name) return name;
    NSMutableString *def = [NSMutableString stringWithString:@"typedef struct { "];
    if (ts_LLVMGetTypeKind(t) == LLVMStructTypeKind) {
        unsigned n = ts_LLVMCountStructElementTypes(t);
        for (unsigned i = 0; i < n; i++) {
            LLVMTypeRef m = ts_LLVMStructGetTypeAtIndex(t, i);
            if (ts_LLVMGetTypeKind(m) == LLVMPointerTypeKind) FAIL(@"pointer inside an aggregate value");
            NSString *mt = [self ctype:m];
            if (!mt) return nil;
            [def appendFormat:@"%@ m%u; ", mt, i];
        }
        if (!n) [def appendString:@"uchar m_empty; "];
    } else {
        LLVMTypeRef e = ts_LLVMGetElementType(t);
        if (ts_LLVMGetTypeKind(e) == LLVMPointerTypeKind) FAIL(@"array of pointers");
        NSString *et = [self ctype:e];
        if (!et) return nil;
        [def appendFormat:@"%@ a[%u]; ", et, MAX(ts_LLVMGetArrayLength(t), 1u)];
    }
    name = [NSString stringWithFormat:@"ts_ty%lu", (unsigned long)_typeNames.count];
    [def appendFormat:@"} %@;\n", name];
    [_types appendString:def];
    _typeNames[KEY(t)] = name;
    return name;
}

// Signed counterpart of an unsigned integer CL type ("uint4" -> "int4").
static NSString *TSCLSigned(NSString *u) { return [u hasPrefix:@"u"] ? [u substringFromIndex:1] : u; }

// Integer type of the same lane width for select() masks.
- (NSString *)maskTypeFor:(LLVMTypeRef)t {
    unsigned n = [self lanes:t];
    LLVMTypeRef s = [self scalarOf:t];
    unsigned bits = [self isFloat:s] ? 32 : [self intWidth:s];
    NSString *b = bits == 8 ? @"char" : bits == 16 ? @"short" : bits == 64 ? @"long" : @"int";
    return n > 1 ? [NSString stringWithFormat:@"%@%u", b, n] : b;
}

#pragma mark Values and constants

- (NSString *)newVar:(NSString *)type {
    NSString *name = [NSString stringWithFormat:@"v%d", _vars++];
    if ([type hasSuffix:@"*"]) [_decls appendFormat:@"  %@%@;\n", type, name];
    else [_decls appendFormat:@"  %@ %@;\n", type, name];
    return name;
}

- (NSString *)zeroOf:(LLVMTypeRef)t {
    switch (ts_LLVMGetTypeKind(t)) {
    case LLVMHalfTypeKind: case LLVMFloatTypeKind: return @"0.0f";
    case LLVMIntegerTypeKind: return ts_LLVMGetIntTypeWidth(t) == 1 ? @"false" : [NSString stringWithFormat:@"((%@)0)", [self ctype:t]];
    case LLVMVectorTypeKind: { NSString *ct = [self ctype:t]; return ct ? [NSString stringWithFormat:@"((%@)(0))", ct] : nil; }
    case LLVMPointerTypeKind: return [NSString stringWithFormat:@"((%@)0)", [self ctype:t]];
    case LLVMStructTypeKind: case LLVMArrayTypeKind: {
        NSString *ct = [self ctype:t];
        if (!ct) return nil;
        NSString *z = [NSString stringWithFormat:@"ts_zero_%@", ct];
        if (![_helperSet containsObject:z]) {
            [_helperSet addObject:z];
            [_globals appendFormat:@"__constant %@ %@ = { 0 };\n", ct, z];
        }
        return z;
    }
    default: FAIL(@"no zero for type kind %d", ts_LLVMGetTypeKind(t));
    }
}

- (NSString *)constant:(LLVMValueRef)v {
    LLVMTypeRef t = ts_LLVMTypeOf(v);
    if (ts_LLVMIsUndef(v) || ts_LLVMIsPoison(v) || ts_LLVMIsAConstantAggregateZero(v)) return [self zeroOf:t];
    if (ts_LLVMIsAConstantPointerNull(v)) return [self zeroOf:t];
    if (ts_LLVMIsAConstantInt(v)) {
        unsigned w = ts_LLVMGetIntTypeWidth(t);
        unsigned long long x = ts_LLVMConstIntGetZExtValue(v);
        if (w == 1) return x ? @"true" : @"false";
        if (w == 32) return [NSString stringWithFormat:@"%lluu", x];
        if (w == 64) return [NSString stringWithFormat:@"%lluul", x];
        return [NSString stringWithFormat:@"((%@)%lluu)", [self ctype:t], x];
    }
    if (ts_LLVMIsAConstantFP(v)) {
        LLVMBool lost;
        return TSCLFloat(ts_LLVMConstRealGetDouble(v, &lost));
    }
    if (ts_LLVMGetTypeKind(t) == LLVMVectorTypeKind) {
        unsigned n = ts_LLVMGetVectorSize(t);
        BOOL mask = [self intWidth:t] == 1;
        NSString *ct = [self ctype:t];
        if (!ct) return nil;
        NSMutableArray *lanes = [NSMutableArray array];
        for (unsigned i = 0; i < n; i++) {
            LLVMValueRef e = ts_LLVMIsAConstantDataSequential(v) ? ts_LLVMGetElementAsConstant(v, i) : ts_LLVMGetOperand(v, i);
            if (!e) FAIL(@"vector constant");
            NSString *c;
            if (mask) c = ts_LLVMIsAConstantInt(e) && ts_LLVMConstIntGetZExtValue(e) ? @"-1" : @"0";
            else c = [self constant:e];
            if (!c) return nil;
            [lanes addObject:c];
        }
        return [NSString stringWithFormat:@"((%@)(%@))", ct, [lanes componentsJoinedByString:@", "]];
    }
    if (ts_LLVMIsAGlobalVariable(v)) { TSCLV *g = [self global:v]; return g ? g->expr : nil; }
    if (ts_LLVMIsAConstantExpr(v)) {
        LLVMOpcode op = ts_LLVMGetConstOpcode(v);
        if (op == LLVMBitCast || op == LLVMAddrSpaceCast) {
            TSCLV *base = [self value:ts_LLVMGetOperand(v, 0)];
            return base ? base->expr : nil;
        }
        if (op == LLVMGetElementPtr) return [self gepOf:v base:ts_LLVMGetOperand(v, 0) into:nil];
        FAIL(@"constant expression (opcode %d)", op);
    }
    FAIL(@"unsupported constant");
}

- (TSCLV *)value:(LLVMValueRef)v {
    TSCLV *hit = _vals[KEY(v)];
    if (hit) return hit;
    if (ts_LLVMIsAInstruction(v)) FAIL(@"use of an instruction before its definition");
    if (ts_LLVMIsAArgument(v)) FAIL(@"unsupported kernel argument");
    if (ts_LLVMIsAGlobalVariable(v)) return [self global:v];
    if (ts_LLVMIsAConstantExpr(v) && (ts_LLVMGetConstOpcode(v) == LLVMBitCast || ts_LLVMGetConstOpcode(v) == LLVMAddrSpaceCast)) {
        TSCLV *base = [self value:ts_LLVMGetOperand(v, 0)];
        if (base) _vals[KEY(v)] = base;
        return base;
    }
    NSString *c = [self constant:v];
    if (!c) return nil;
    NSString *space = ts_LLVMGetTypeKind(ts_LLVMTypeOf(v)) == LLVMPointerTypeKind
                    ? [self spaceOfAS:ts_LLVMGetPointerAddressSpace(ts_LLVMTypeOf(v))] : nil;
    if (ts_LLVMIsAConstantExpr(v) && ts_LLVMGetConstOpcode(v) == LLVMGetElementPtr) {
        TSCLV *base = [self value:ts_LLVMGetOperand(v, 0)];
        space = base ? base->space : space;
    }
    return TSCLExpr(c, space);
}

- (NSString *)expr:(LLVMValueRef)v {
    TSCLV *x = [self value:v];
    if (!x) return nil;
    if (x->kind != TSCLVExpr) FAIL(@"texture or sampler used as a value");
    return x->expr;
}

// Serializes a constant initializer into bytes laid out as the AIR data layout says.
- (BOOL)bytesOf:(LLVMValueRef)c type:(LLVMTypeRef)t into:(uint8_t *)out {
    if (ts_LLVMIsUndef(c) || ts_LLVMIsPoison(c) || ts_LLVMIsAConstantAggregateZero(c) || ts_LLVMIsAConstantPointerNull(c)) return YES;
    switch (ts_LLVMGetTypeKind(t)) {
    case LLVMIntegerTypeKind: {
        unsigned long long x = ts_LLVMConstIntGetZExtValue(c);
        unsigned bytes = (ts_LLVMGetIntTypeWidth(t) + 7) / 8;
        for (unsigned i = 0; i < bytes && i < 8; i++) out[i] = (uint8_t)(x >> (8 * i));
        return YES;
    }
    case LLVMFloatTypeKind: { LLVMBool l; float f = (float)ts_LLVMConstRealGetDouble(c, &l); memcpy(out, &f, 4); return YES; }
    case LLVMHalfTypeKind: { LLVMBool l; __fp16 h = (__fp16)ts_LLVMConstRealGetDouble(c, &l); memcpy(out, &h, 2); return YES; }
    case LLVMArrayTypeKind: case LLVMVectorTypeKind: {
        LLVMTypeRef e = ts_LLVMGetElementType(t);
        unsigned n = ts_LLVMGetTypeKind(t) == LLVMArrayTypeKind ? ts_LLVMGetArrayLength(t) : ts_LLVMGetVectorSize(t);
        unsigned long long stride = ts_LLVMABISizeOfType(_td, e);
        if (ts_LLVMGetTypeKind(t) == LLVMVectorTypeKind) stride = ts_LLVMStoreSizeOfType(_td, e);
        for (unsigned i = 0; i < n; i++) {
            LLVMValueRef ec = ts_LLVMIsAConstantDataSequential(c) ? ts_LLVMGetElementAsConstant(c, i) : ts_LLVMGetOperand(c, i);
            if (!ec || ![self bytesOf:ec type:e into:out + i * stride]) return NO;
        }
        return YES;
    }
    case LLVMStructTypeKind: {
        unsigned n = ts_LLVMCountStructElementTypes(t);
        for (unsigned i = 0; i < n; i++) {
            LLVMValueRef ec = ts_LLVMGetOperand(c, i);
            if (!ec || ![self bytesOf:ec type:ts_LLVMStructGetTypeAtIndex(t, i) into:out + ts_LLVMOffsetOfElement(_td, t, i)]) return NO;
        }
        return YES;
    }
    default: FAILB(@"constant table with unsupported element type");
    }
}

// Module globals: constexpr samplers, threadgroup memory, constant tables.
- (TSCLV *)global:(LLVMValueRef)g {
    TSCLV *hit = _vals[KEY(g)];
    if (hit) return hit;
    size_t len;
    const char *name = ts_LLVMGetValueName2(g, &len);
    LLVMValueRef init = ts_LLVMGetInitializer(g);
    LLVMTypeRef t = ts_LLVMGetElementType(ts_LLVMTypeOf(g));
    unsigned as = ts_LLVMGetPointerAddressSpace(ts_LLVMTypeOf(g));
    TSCLV *v;
    if (name && !strncmp(name, "__air_sampler_state", 19)) {
        LLVMValueRef word = init ? (ts_LLVMIsAConstantDataSequential(init) ? ts_LLVMGetElementAsConstant(init, 0) : ts_LLVMGetOperand(init, 0)) : NULL;
        uint64_t key = word ? ts_LLVMConstIntGetZExtValue(word) : 0;
        v = [TSCLV new];
        v->kind = TSCLVSampler;
        v->slot = -1;
        v->expr = [NSString stringWithFormat:@"ts_cs_%llx", key];
        v->key = key;
        v->constexprKey = YES;
        if (![_helperSet containsObject:v->expr]) {
            [_helperSet addObject:v->expr];
            [_globals appendFormat:@"const sampler_t %@ = %@;\n", v->expr, TSCLConstexprSampler(key)];
        }
        _vals[KEY(g)] = v;
        return v;
    }
    unsigned long long size = MAX(ts_LLVMABISizeOfType(_td, t), 1ull);
    NSString *var = [NSString stringWithFormat:@"g%lu", (unsigned long)_vals.count];
    if (as == 3) {
        [_prologue appendFormat:@"  __local uchar %@[%llu] __attribute__((aligned(16)));\n", var, size];
        _tgStatic += (size + 15) & ~15ull;
        v = TSCLExpr([NSString stringWithFormat:@"((__local uchar *)%@)", var], @"__local");
    } else {
        if (!init) FAIL(@"global %s without initializer", name);
        uint8_t *bytes = calloc(size, 1);
        BOOL ok = [self bytesOf:init type:t into:bytes];
        if (ok) {
            NSMutableString *list = [NSMutableString string];
            for (unsigned long long i = 0; i < size; i++) [list appendFormat:i ? @",%u" : @"%u", bytes[i]];
            [_globals appendFormat:@"__constant uchar %@[%llu] __attribute__((aligned(16))) = { %@ };\n", var, size, list];
        }
        free(bytes);
        if (!ok) return nil;
        v = TSCLExpr([NSString stringWithFormat:@"((__constant uchar *)%@)", var], @"__constant");
    }
    _vals[KEY(g)] = v;
    return v;
}

// Metal constexpr sampler word (layout in TSGLSamplerForConstexpr) -> CL sampler literal. CL has one
// addressing mode for all axes and one filter; mipmaps are not sampled (level 0).
static NSString *TSCLConstexprSampler(uint64_t key) {
    BOOL normalized = !((key >> 15) & 1);
    return [NSString stringWithFormat:@"%@ | %@ | %@", normalized ? @"CLK_NORMALIZED_COORDS_TRUE" : @"CLK_NORMALIZED_COORDS_FALSE",
            TSCLAddressMode((unsigned)(key & 7), normalized), ((key >> 9) & 3) || ((key >> 11) & 3) ? @"CLK_FILTER_LINEAR" : @"CLK_FILTER_NEAREST"];
}

// Per-axis addressing done in the kernel (B3), one 4-bit code per axis (s, t, r) plus bit 15 = normalized
// coordinates: 0 clamp to edge (left to an edge-clamping CL sampler), 1 repeat, 2 mirrored repeat, 3 clamp to
// zero / border color (transparent black), 4 mirror clamp to edge. The dispatcher computes the same word for
// MTLSamplerState arguments (TSMtlComputeCL.m). Linear filtering does not wrap across a repeat seam.
static unsigned TSCLAxisCode(unsigned airAddress) {
    static const unsigned codes[8] = { 3, 0, 1, 2, 3, 4, 0, 0 };
    return codes[airAddress & 7];
}

// Manual addressing word of a constexpr sampler for a texture of `dims` axes, 0 when the CL sampler suffices.
static unsigned TSCLConstexprAM(uint64_t key, unsigned dims) {
    BOOL normalized = !((key >> 15) & 1);
    unsigned c[3] = { TSCLAxisCode((unsigned)key & 7), TSCLAxisCode((unsigned)(key >> 3) & 7), TSCLAxisCode((unsigned)(key >> 6) & 7) };
    BOOL manual = NO;
    for (unsigned i = 0; i < dims; i++) manual |= c[i] != c[0] || c[i] == 4;
    if (!manual) return 0;
    unsigned am = normalized ? 0x8000u : 0;
    for (unsigned i = 0; i < dims; i++) am |= c[i] << (4 * i);
    return am ?: 0x10000u;   // never 0 when manual (pixel coordinates, all edge but one zero axis)
}

static NSString *const kTSCLAddressHelpers =
    @"float ts_am1(float x, uint m) {\n"
     "  if (m == 1u) return x - floor(x);\n"
     "  if (m == 2u) { float t = x - 2.0f * floor(x * 0.5f); return t > 1.0f ? 2.0f - t : t; }\n"
     "  if (m == 4u) return fmin(fabs(x), 1.0f);\n"
     "  return x;\n"
     "}\n"
     "bool ts_amz1(float x, uint m, float lim) { return m == 3u && (x < 0.0f || x >= lim); }\n"
     "float2 ts_am2(float2 c, uint am) { return (float2)(ts_am1(c.x, am & 15u), ts_am1(c.y, (am >> 4) & 15u)); }\n"
     "bool ts_amz2(float2 c, uint am, float2 l) { return ts_amz1(c.x, am & 15u, l.x) || ts_amz1(c.y, (am >> 4) & 15u, l.y); }\n"
     "float3 ts_am3(float3 c, uint am) { return (float3)(ts_am1(c.x, am & 15u), ts_am1(c.y, (am >> 4) & 15u), ts_am1(c.z, (am >> 8) & 15u)); }\n"
     "bool ts_amz3(float3 c, uint am, float3 l) {\n"
     "  return ts_amz1(c.x, am & 15u, l.x) || ts_amz1(c.y, (am >> 4) & 15u, l.y) || ts_amz1(c.z, (am >> 8) & 15u, l.z);\n"
     "}\n";

// AIR address codes: 0 clamp_to_zero, 1 clamp_to_edge, 2 repeat, 3 mirrored_repeat, 4 clamp_to_border, 5 mirror_clamp_to_edge.
static NSString *TSCLAddressMode(unsigned a, BOOL normalized) {
    switch (a) {
    case 0: case 4: return @"CLK_ADDRESS_CLAMP";
    case 2: return normalized ? @"CLK_ADDRESS_REPEAT" : @"CLK_ADDRESS_CLAMP_TO_EDGE";
    case 3: return normalized ? @"CLK_ADDRESS_MIRRORED_REPEAT" : @"CLK_ADDRESS_CLAMP_TO_EDGE";
    default: return @"CLK_ADDRESS_CLAMP_TO_EDGE";
    }
}

- (void)needHelper:(NSString *)name code:(NSString *)code {
    if ([_helperSet containsObject:name]) return;
    [_helperSet addObject:name];
    [_helpers appendString:code];
}

#pragma mark Definitions

- (TSCLV *)define:(LLVMValueRef)inst expr:(NSString *)e {
    LLVMTypeRef t = ts_LLVMTypeOf(inst);
    NSString *ct = [self ctype:t];
    if (!ct) return nil;
    NSString *space = ts_LLVMGetTypeKind(t) == LLVMPointerTypeKind ? [self spaceOfAS:ts_LLVMGetPointerAddressSpace(t)] : nil;
    return [self define:inst expr:e type:ct space:space];
}

- (TSCLV *)define:(LLVMValueRef)inst expr:(NSString *)e type:(NSString *)ct space:(NSString *)space {
    TSCLV *pre = _vals[KEY(inst)];   // phis are declared up front
    NSString *var = pre ? pre->expr : [self newVar:ct];
    [_body appendFormat:@"  %@ = %@;\n", var, e];
    TSCLV *v = pre ?: TSCLExpr(var, space);
    _vals[KEY(inst)] = v;
    return v;
}

// Pointer type of a value in a given space.
static NSString *TSCLPtrType(NSString *space, NSString *pointee) {
    return space.length ? [NSString stringWithFormat:@"%@ %@ *", space, pointee] : [NSString stringWithFormat:@"%@ *", pointee];
}

#pragma mark Memory

// GEP (instruction or constant expression) as a byte-pointer expression.
- (NSString *)gepOf:(LLVMValueRef)gep base:(LLVMValueRef)baseValue into:(NSString **)spaceOut {
    TSCLV *base = [self value:baseValue];
    if (!base) return nil;
    if (base->kind != TSCLVExpr) FAIL(@"GEP on a texture or sampler");
    LLVMTypeRef t = ts_LLVMGetGEPSourceElementType(gep);
    int n = ts_LLVMGetNumOperands(gep);
    long long constOff = 0;
    NSMutableArray *terms = [NSMutableArray array];
    for (int i = 1; i < n; i++) {
        LLVMValueRef idx = ts_LLVMGetOperand(gep, (unsigned)i);
        if (i > 1 && ts_LLVMGetTypeKind(t) == LLVMStructTypeKind) {
            unsigned field = (unsigned)ts_LLVMConstIntGetZExtValue(idx);
            constOff += (long long)ts_LLVMOffsetOfElement(_td, t, field);
            t = ts_LLVMStructGetTypeAtIndex(t, field);
            continue;
        }
        unsigned long long size = i == 1 ? ts_LLVMABISizeOfType(_td, t) : ts_LLVMABISizeOfType(_td, ts_LLVMGetElementType(t));
        if (i > 1) t = ts_LLVMGetElementType(t);
        if (ts_LLVMIsAConstantInt(idx)) { constOff += ts_LLVMConstIntGetSExtValue(idx) * (long long)size; continue; }
        if (ts_LLVMGetTypeKind(ts_LLVMTypeOf(idx)) == LLVMVectorTypeKind) FAIL(@"vector GEP");
        NSString *ie = [self expr:idx];
        if (!ie) return nil;
        unsigned w = ts_LLVMGetIntTypeWidth(ts_LLVMTypeOf(idx));
        // Device pointers are 32-bit here (CL_DEVICE_ADDRESS_BITS): offsets are computed in int.
        NSString *si = w == 32 ? [NSString stringWithFormat:@"as_int(%@)", ie] : w == 64 ? [NSString stringWithFormat:@"(int)(%@)", ie]
                                : [NSString stringWithFormat:@"(int)(%@)", ie];
        [terms addObject:size == 1 ? si : [NSString stringWithFormat:@"%@ * %llu", si, size]];
    }
    if (constOff) [terms addObject:[NSString stringWithFormat:@"%lld", constOff]];
    if (spaceOut) *spaceOut = base->space;
    if (!terms.count) return base->expr;
    return [NSString stringWithFormat:@"(%@ + (%@))", base->expr, [terms componentsJoinedByString:@" + "]];
}

// Natural CL alignment of a vector type (3-vectors take 4 lanes).
- (unsigned long long)clAlignOf:(LLVMTypeRef)t {
    unsigned n = [self lanes:t];
    unsigned long long e = ts_LLVMStoreSizeOfType(_td, [self scalarOf:t]);
    if ([self isHalf:t]) e = 4;   // half lanes are floats in registers, loaded with vload_half
    return (n == 3 ? 4 : n) * e;
}

// Statements loading type t at byte pointer p into lvalue dst.
- (BOOL)emitLoad:(NSString *)dst type:(LLVMTypeRef)t ptr:(NSString *)p space:(NSString *)space align:(unsigned)align {
    LLVMTypeKind k = ts_LLVMGetTypeKind(t);
    if (k == LLVMStructTypeKind) {
        unsigned n = ts_LLVMCountStructElementTypes(t);
        for (unsigned i = 0; i < n; i++) {
            unsigned long long off = ts_LLVMOffsetOfElement(_td, t, i);
            if (![self emitLoad:[NSString stringWithFormat:@"%@.m%u", dst, i] type:ts_LLVMStructGetTypeAtIndex(t, i)
                            ptr:[NSString stringWithFormat:@"(%@ + %llu)", p, off] space:space align:off ? 1 : align]) return NO;
        }
        return YES;
    }
    if (k == LLVMArrayTypeKind) {
        LLVMTypeRef e = ts_LLVMGetElementType(t);
        unsigned n = ts_LLVMGetArrayLength(t);
        unsigned long long stride = ts_LLVMABISizeOfType(_td, e);
        for (unsigned i = 0; i < n; i++)
            if (![self emitLoad:[NSString stringWithFormat:@"%@.a[%u]", dst, i] type:e ptr:[NSString stringWithFormat:@"(%@ + %llu)", p, i * stride]
                          space:space align:i ? 1 : align]) return NO;
        return YES;
    }
    NSString *e = [self loadExpr:t ptr:p space:space align:align];
    if (!e) return NO;
    [_body appendFormat:@"  %@ = %@;\n", dst, e];
    return YES;
}

- (NSString *)loadExpr:(LLVMTypeRef)t ptr:(NSString *)p space:(NSString *)space align:(unsigned)align {
    unsigned n = [self lanes:t];
    if (ts_LLVMGetTypeKind(t) == LLVMPointerTypeKind) FAIL(@"pointer loaded from memory (argument buffers)");
    if ([self isHalf:t])
        return n > 1 ? [NSString stringWithFormat:@"vload_half%u(0, (%@)(%@))", n, TSCLPtrType(space, @"const half"), p]
                     : [NSString stringWithFormat:@"vload_half(0, (%@)(%@))", TSCLPtrType(space, @"const half"), p];
    if ([self intWidth:t] == 1) {
        if (n > 1) FAIL(@"bool vector in memory");
        return [NSString stringWithFormat:@"(*(%@)(%@) != 0)", TSCLPtrType(space, @"const uchar"), p];
    }
    NSString *ct = [self ctype:t];
    if (!ct) return nil;
    if (n > 1 && align < [self clAlignOf:t]) {
        NSString *lane = [self laneName:[self scalarOf:t]];
        return [NSString stringWithFormat:@"vload%u(0, (%@)(%@))", n, TSCLPtrType(space, [@"const " stringByAppendingString:lane]), p];
    }
    return [NSString stringWithFormat:@"*(%@)(%@)", TSCLPtrType(space, [@"const " stringByAppendingString:ct]), p];
}

- (BOOL)emitStore:(NSString *)value type:(LLVMTypeRef)t ptr:(NSString *)p space:(NSString *)space align:(unsigned)align {
    if ([space isEqualToString:@"__constant"]) FAILB(@"store into constant memory");
    LLVMTypeKind k = ts_LLVMGetTypeKind(t);
    if (k == LLVMStructTypeKind) {
        unsigned n = ts_LLVMCountStructElementTypes(t);
        for (unsigned i = 0; i < n; i++) {
            unsigned long long off = ts_LLVMOffsetOfElement(_td, t, i);
            if (![self emitStore:[NSString stringWithFormat:@"%@.m%u", value, i] type:ts_LLVMStructGetTypeAtIndex(t, i)
                             ptr:[NSString stringWithFormat:@"(%@ + %llu)", p, off] space:space align:off ? 1 : align]) return NO;
        }
        return YES;
    }
    if (k == LLVMArrayTypeKind) {
        LLVMTypeRef e = ts_LLVMGetElementType(t);
        unsigned n = ts_LLVMGetArrayLength(t);
        unsigned long long stride = ts_LLVMABISizeOfType(_td, e);
        for (unsigned i = 0; i < n; i++)
            if (![self emitStore:[NSString stringWithFormat:@"%@.a[%u]", value, i] type:e ptr:[NSString stringWithFormat:@"(%@ + %llu)", p, i * stride]
                           space:space align:i ? 1 : align]) return NO;
        return YES;
    }
    if (k == LLVMPointerTypeKind) FAILB(@"pointer stored to memory (argument buffers)");
    unsigned n = [self lanes:t];
    if ([self isHalf:t]) {
        if (n > 1) [_body appendFormat:@"  vstore_half%u_rte(%@, 0, (%@)(%@));\n", n, value, TSCLPtrType(space, @"half"), p];
        else [_body appendFormat:@"  vstore_half_rte(%@, 0, (%@)(%@));\n", value, TSCLPtrType(space, @"half"), p];
        return YES;
    }
    if ([self intWidth:t] == 1) {
        if (n > 1) FAILB(@"bool vector in memory");
        [_body appendFormat:@"  *(%@)(%@) = (uchar)(%@);\n", TSCLPtrType(space, @"uchar"), p, value];
        return YES;
    }
    NSString *ct = [self ctype:t];
    if (!ct) return NO;
    if (n > 1 && align < [self clAlignOf:t])
        [_body appendFormat:@"  vstore%u(%@, 0, (%@)(%@));\n", n, value, TSCLPtrType(space, [self laneName:[self scalarOf:t]]), p];
    else
        [_body appendFormat:@"  *(%@)(%@) = %@;\n", TSCLPtrType(space, ct), p, value];
    return YES;
}

#pragma mark Instructions

- (TSCLV *)binary:(LLVMValueRef)inst op:(LLVMOpcode)op {
    NSString *a = [self expr:ts_LLVMGetOperand(inst, 0)], *b = [self expr:ts_LLVMGetOperand(inst, 1)];
    if (!a || !b) return nil;
    LLVMTypeRef t = ts_LLVMTypeOf(inst);
    NSString *ct = [self ctype:t];
    if (!ct) return nil;
    unsigned n = [self lanes:t], w = [self intWidth:t];
    if (w == 1) {
        // i1 (bool / 0,-1 masks): and, or, xor; add = xor, mul = and.
        NSString *o = op == LLVMAnd || op == LLVMMul ? @"&" : op == LLVMOr ? @"|" : op == LLVMXor || op == LLVMAdd || op == LLVMSub ? @"^" : nil;
        if (!o) FAIL(@"i1 arithmetic (opcode %d)", op);
        return [self define:inst expr:n > 1 ? [NSString stringWithFormat:@"(%@ %@ %@)", a, o, b]
                                            : [NSString stringWithFormat:@"((%@) %@ (%@)) != 0", a, o, b]];
    }
    NSString *sct = TSCLSigned(ct), *e = nil;
    switch (op) {
    case LLVMAdd: case LLVMFAdd: e = [NSString stringWithFormat:@"%@ + %@", a, b]; break;
    case LLVMSub: case LLVMFSub: e = [NSString stringWithFormat:@"%@ - %@", a, b]; break;
    case LLVMMul: case LLVMFMul: e = [NSString stringWithFormat:@"%@ * %@", a, b]; break;
    case LLVMFDiv: case LLVMUDiv: e = [NSString stringWithFormat:@"%@ / %@", a, b]; break;
    case LLVMURem: e = [NSString stringWithFormat:@"%@ %% %@", a, b]; break;
    case LLVMFRem: e = [NSString stringWithFormat:@"fmod(%@, %@)", a, b]; break;
    case LLVMAnd: e = [NSString stringWithFormat:@"%@ & %@", a, b]; break;
    case LLVMOr: e = [NSString stringWithFormat:@"%@ | %@", a, b]; break;
    case LLVMXor: e = [NSString stringWithFormat:@"%@ ^ %@", a, b]; break;
    case LLVMShl: e = [NSString stringWithFormat:@"%@ << %@", a, b]; break;
    case LLVMLShr: e = [NSString stringWithFormat:@"%@ >> %@", a, b]; break;
    case LLVMAShr: e = [NSString stringWithFormat:@"as_%@(as_%@(%@) >> as_%@(%@))", ct, sct, a, sct, b]; break;
    case LLVMSDiv: e = [NSString stringWithFormat:@"as_%@(as_%@(%@) / as_%@(%@))", ct, sct, a, sct, b]; break;
    case LLVMSRem: e = [NSString stringWithFormat:@"as_%@(as_%@(%@) %% as_%@(%@))", ct, sct, a, sct, b]; break;
    default: FAIL(@"binary opcode %d", op);
    }
    // Scalars narrower than int are promoted by C: cut back to the type.
    if (n == 1 && (w == 8 || w == 16)) e = [NSString stringWithFormat:@"(%@)(%@)", ct, e];
    else e = [NSString stringWithFormat:@"(%@)", e];
    if ([ct hasPrefix:@"uchar"] && n > 1 && (op == LLVMAShr || op == LLVMSDiv || op == LLVMSRem)) {}   // as_ keeps the width
    return [self define:inst expr:e];
}

// Comparison result: bool for scalars, intN of 0/-1 for vectors.
- (NSString *)maskOf:(NSString *)cmp lanes:(unsigned)n {
    return n > 1 ? [NSString stringWithFormat:@"convert_int%u(%@)", n, cmp] : cmp;
}

- (TSCLV *)compare:(LLVMValueRef)inst float:(BOOL)isFloat {
    LLVMValueRef x = ts_LLVMGetOperand(inst, 0);
    NSString *a = [self expr:x], *b = [self expr:ts_LLVMGetOperand(inst, 1)];
    if (!a || !b) return nil;
    LLVMTypeRef t = ts_LLVMTypeOf(x);
    unsigned n = [self lanes:t];
    NSString *e;
    if (isFloat) {
        LLVMRealPredicate p = ts_LLVMGetFCmpPredicate(inst);
        static NSString *const ops[] = { nil, @"==", @">", @">=", @"<", @"<=", @"!=", nil, nil, @"==", @">", @">=", @"<", @"<=", @"!=", nil };
        if (p == LLVMRealPredicateFalse || p == LLVMRealPredicateTrue) {
            BOOL tr = p == LLVMRealPredicateTrue;
            return [self define:inst expr:n > 1 ? [NSString stringWithFormat:@"((int%u)(%d))", n, tr ? -1 : 0] : (tr ? @"true" : @"false")];
        }
        if (p == LLVMRealORD || p == LLVMRealUNO) {
            NSString *nan = [NSString stringWithFormat:@"(isnan(%@) | isnan(%@))", a, b];
            e = p == LLVMRealUNO ? nan : [NSString stringWithFormat:@"!%@", nan];
            if (n > 1) e = p == LLVMRealUNO ? nan : [NSString stringWithFormat:@"~%@", nan];
            return [self define:inst expr:n > 1 ? e : [NSString stringWithFormat:@"(%@) != 0", e]];
        }
        e = [NSString stringWithFormat:@"(%@ %@ %@)", a, ops[p], b];
    } else {
        LLVMIntPredicate p = ts_LLVMGetICmpPredicate(inst);
        BOOL sgn = p >= LLVMIntSGT;
        static NSString *const ops[] = { @"==", @"!=", @">", @">=", @"<", @"<=", @">", @">=", @"<", @"<=" };
        if (sgn && [self intWidth:t] > 1) {
            NSString *st = TSCLSigned([self ctype:t]);
            a = [NSString stringWithFormat:@"as_%@(%@)", st, a];
            b = [NSString stringWithFormat:@"as_%@(%@)", st, b];
        }
        e = [NSString stringWithFormat:@"(%@ %@ %@)", a, ops[p - LLVMIntEQ], b];
        if ([self intWidth:t] == 1 && n > 1) e = [NSString stringWithFormat:@"(%@ %@ %@)", a, ops[p - LLVMIntEQ], b];   // masks compare as ints
    }
    return [self define:inst expr:[self maskOf:e lanes:n]];
}

- (TSCLV *)cast:(LLVMValueRef)inst op:(LLVMOpcode)op {
    LLVMValueRef src = ts_LLVMGetOperand(inst, 0);
    LLVMTypeRef from = ts_LLVMTypeOf(src), to = ts_LLVMTypeOf(inst);
    if (op == LLVMBitCast || op == LLVMAddrSpaceCast || op == LLVMFreeze) {
        if (ts_LLVMGetTypeKind(to) == LLVMPointerTypeKind) {
            TSCLV *p = [self value:src];
            if (!p) return nil;
            if (p->kind != TSCLVExpr) { _vals[KEY(inst)] = p; return p; }   // texture/sampler pointer casts
            if (op == LLVMAddrSpaceCast && ![p->space isEqualToString:[self spaceOfAS:ts_LLVMGetPointerAddressSpace(to)]])
                FAIL(@"address space cast");
            _vals[KEY(inst)] = p;
            return p;
        }
        NSString *x = [self expr:src];
        if (!x) return nil;
        if (op == LLVMFreeze || from == to) return [self define:inst expr:x];
        return [self define:inst expr:[self bitcast:x from:from to:to]];
    }
    if (op == LLVMPtrToInt || op == LLVMIntToPtr) FAIL(@"pointer/integer conversion");
    NSString *x = [self expr:src];
    if (!x) return nil;
    NSString *ct = [self ctype:to], *ft = [self ctype:from];
    if (!ct || !ft) return nil;
    unsigned n = [self lanes:to], fw = [self intWidth:from], tw = [self intWidth:to];
    NSString *conv = n > 1 ? [NSString stringWithFormat:@"convert_%@", ct] : [NSString stringWithFormat:@"(%@)", ct];
    NSString *e = nil;
    switch (op) {
    case LLVMTrunc:
        if (tw == 1) e = n > 1 ? [NSString stringWithFormat:@"(-convert_int%u((%@) & (%@)(1)))", n, x, ft]
                               : [NSString stringWithFormat:@"((%@) & 1) != 0", x];
        else e = [NSString stringWithFormat:@"%@(%@)", conv, x];
        break;
    case LLVMZExt:
        if (fw == 1) e = n > 1 ? [NSString stringWithFormat:@"%@(-(%@))", conv, x] : [NSString stringWithFormat:@"(%@)(%@)", ct, x];
        else e = [NSString stringWithFormat:@"%@(%@)", conv, x];
        break;
    case LLVMSExt: {
        if (fw == 1) { e = n > 1 ? [NSString stringWithFormat:@"as_%@(convert_%@(%@))", ct, TSCLSigned(ct), x]
                                 : [NSString stringWithFormat:@"((%@) ? (%@)~(%@)0 : (%@)0)", x, ct, ct, ct]; break; }
        NSString *sft = TSCLSigned(ft), *sct = TSCLSigned(ct);
        e = n > 1 ? [NSString stringWithFormat:@"as_%@(convert_%@(as_%@(%@)))", ct, sct, sft, x]
                  : [NSString stringWithFormat:@"(%@)(%@)as_%@(%@)", ct, sct, sft, x];
        break;
    }
    case LLVMFPToUI: case LLVMFPToSI: {
        if (tw == 1) { e = n > 1 ? [NSString stringWithFormat:@"convert_int%u(%@ != 0.0f)", n, x] : [NSString stringWithFormat:@"(%@ != 0.0f)", x]; break; }
        NSString *target = op == LLVMFPToSI ? TSCLSigned(ct) : ct;
        e = n > 1 ? [NSString stringWithFormat:@"as_%@(convert_%@(%@))", ct, target, x] : [NSString stringWithFormat:@"(%@)(%@)(%@)", ct, target, x];
        break;
    }
    case LLVMUIToFP: case LLVMSIToFP: {
        if (fw == 1) {
            NSString *one = op == LLVMSIToFP ? @"-1.0f" : @"1.0f";
            e = n > 1 ? [NSString stringWithFormat:@"select((%@)(0.0f), (%@)(%@), %@)", ct, ct, one, x]
                      : [NSString stringWithFormat:@"((%@) ? %@ : 0.0f)", x, one];
            break;
        }
        NSString *s = op == LLVMSIToFP ? [NSString stringWithFormat:@"as_%@(%@)", TSCLSigned(ft), x] : x;
        e = [NSString stringWithFormat:@"%@(%@)", conv, s];
        break;
    }
    case LLVMFPTrunc: case LLVMFPExt: e = x; break;   // half is computed in float
    default: FAIL(@"cast opcode %d", op);
    }
    return [self define:inst expr:e];
}

// Memory representation of a register type for bitcasts: half lanes become ushort bits.
- (NSString *)bitcast:(NSString *)x from:(LLVMTypeRef)from to:(LLVMTypeRef)to {
    unsigned fn = [self lanes:from], tn = [self lanes:to];
    NSString *ft = [self ctype:from], *tt = [self ctype:to];
    if (!ft || !tt) return nil;
    if ([self intWidth:from] == 1 || [self intWidth:to] == 1) FAIL(@"bitcast of i1");
    // Encode half lanes to their bits.
    NSString *src = x, *srcType = ft;
    if ([self isHalf:from]) {
        [self needHalfHelpers];
        srcType = fn > 1 ? [NSString stringWithFormat:@"ushort%u", fn] : @"ushort";
        src = fn > 1 ? [NSString stringWithFormat:@"ts_f2h%u(%@)", fn, x] : [NSString stringWithFormat:@"ts_f2h(%@)", x];
        [self needHalfVector:fn];
    }
    NSString *dstType = tt;
    if ([self isHalf:to]) dstType = tn > 1 ? [NSString stringWithFormat:@"ushort%u", tn] : @"ushort";
    NSString *bits;
    if ([srcType isEqualToString:dstType]) bits = src;
    else if (fn != 3 && tn != 3) bits = [NSString stringWithFormat:@"as_%@(%@)", dstType, src];
    else {
        NSString *h = [NSString stringWithFormat:@"ts_bc_%@_%@", srcType, dstType];
        [self needHelper:h code:[NSString stringWithFormat:@"static inline %@ %@(%@ x) { union { %@ a; %@ b; } u; u.b = (%@)(0); u.a = x; return u.b; }\n",
                                 dstType, h, srcType, srcType, dstType, dstType]];
        bits = [NSString stringWithFormat:@"%@(%@)", h, src];
    }
    if ([self isHalf:to]) {
        [self needHalfHelpers];
        [self needHalfVector:tn];
        return tn > 1 ? [NSString stringWithFormat:@"ts_h2f%u(%@)", tn, bits] : [NSString stringWithFormat:@"ts_h2f(%@)", bits];
    }
    return bits;
}

- (void)needHalfHelpers {
    [self needHelper:@"ts_f2h" code:@"static inline ushort ts_f2h(float f) { ushort h; vstore_half_rte(f, 0, (half *)&h); return h; }\n"
                                     "static inline float ts_h2f(ushort h) { return vload_half(0, (const half *)&h); }\n"];
}

- (void)needHalfVector:(unsigned)n {
    if (n < 2) return;
    NSString *name = [NSString stringWithFormat:@"ts_f2h%u", n];
    [self needHelper:name code:[NSString stringWithFormat:
        @"static inline ushort%u ts_f2h%u(float%u f) { ushort%u h; vstore_half%u_rte(f, 0, (half *)&h); return h; }\n"
         "static inline float%u ts_h2f%u(ushort%u h) { return vload_half%u(0, (const half *)&h); }\n", n, n, n, n, n, n, n, n, n]];
}

- (TSCLV *)gepInst:(LLVMValueRef)inst {
    NSString *space = nil;
    NSString *e = [self gepOf:inst base:ts_LLVMGetOperand(inst, 0) into:&space];
    if (!e) return nil;
    return [self define:inst expr:e type:TSCLPtrType(space, @"uchar") space:space];
}

- (TSCLV *)loadInst:(LLVMValueRef)inst {
    TSCLV *p = [self value:ts_LLVMGetOperand(inst, 0)];
    if (!p) return nil;
    if (p->kind != TSCLVExpr) {   // loads of texture/sampler handles (AIR passes them by pointer in some forms)
        _vals[KEY(inst)] = p;
        return p;
    }
    LLVMTypeRef t = ts_LLVMTypeOf(inst);
    NSString *ct = [self ctype:t];
    if (!ct) return nil;
    NSString *var = [self newVar:ct];
    if (![self emitLoad:var type:t ptr:p->expr space:p->space align:ts_LLVMGetAlignment(inst)]) return nil;
    TSCLV *v = TSCLExpr(var, nil);
    _vals[KEY(inst)] = v;
    return v;
}

- (BOOL)storeInst:(LLVMValueRef)inst {
    LLVMValueRef val = ts_LLVMGetOperand(inst, 0);
    TSCLV *p = [self value:ts_LLVMGetOperand(inst, 1)];
    if (!p) return NO;
    if (p->kind != TSCLVExpr) FAILB(@"store through a texture or sampler pointer");
    NSString *v = [self expr:val];
    if (!v) return NO;
    return [self emitStore:v type:ts_LLVMTypeOf(val) ptr:p->expr space:p->space align:ts_LLVMGetAlignment(inst)];
}

- (TSCLV *)allocaInst:(LLVMValueRef)inst {
    LLVMTypeRef t = ts_LLVMGetAllocatedType(inst);
    unsigned long long size = MAX(ts_LLVMABISizeOfType(_td, t), 1ull);
    NSString *arr = [NSString stringWithFormat:@"a%d", _vars++];
    [_decls appendFormat:@"  uchar %@[%llu] __attribute__((aligned(16)));\n", arr, size];
    TSCLV *v = TSCLExpr([NSString stringWithFormat:@"((uchar *)%@)", arr], @"");
    _vals[KEY(inst)] = v;
    return v;
}

- (TSCLV *)extractElement:(LLVMValueRef)inst {
    LLVMValueRef vec = ts_LLVMGetOperand(inst, 0), idx = ts_LLVMGetOperand(inst, 1);
    NSString *v = [self expr:vec];
    if (!v) return nil;
    LLVMTypeRef vt = ts_LLVMTypeOf(vec);
    BOOL mask = [self intWidth:vt] == 1;
    NSString *e;
    if (ts_LLVMIsAConstantInt(idx)) {
        unsigned i = (unsigned)ts_LLVMConstIntGetZExtValue(idx);
        e = [NSString stringWithFormat:@"(%@).%@", v, TSCLComp(i)];
    } else {
        NSString *ie = [self expr:idx];
        if (!ie) return nil;
        NSString *tmp = [self newVar:[self ctype:vt]];
        [_body appendFormat:@"  %@ = %@;\n", tmp, v];
        NSString *lane = mask ? @"int" : [self laneName:[self scalarOf:vt]];
        e = [NSString stringWithFormat:@"((%@ *)&%@)[%@]", lane, tmp, ie];
    }
    if (mask) e = [NSString stringWithFormat:@"(%@ != 0)", e];
    return [self define:inst expr:e];
}

- (TSCLV *)insertElement:(LLVMValueRef)inst {
    LLVMValueRef vec = ts_LLVMGetOperand(inst, 0), val = ts_LLVMGetOperand(inst, 1), idx = ts_LLVMGetOperand(inst, 2);
    LLVMTypeRef vt = ts_LLVMTypeOf(inst);
    NSString *ct = [self ctype:vt];
    if (!ct) return nil;
    NSString *v = ts_LLVMIsUndef(vec) || ts_LLVMIsPoison(vec) ? nil : [self expr:vec];
    NSString *x = [self expr:val];
    if (!x || (!v && !(ts_LLVMIsUndef(vec) || ts_LLVMIsPoison(vec)))) return nil;
    BOOL mask = [self intWidth:vt] == 1;
    if (mask) x = [NSString stringWithFormat:@"((%@) ? -1 : 0)", x];
    NSString *var = [self newVar:ct];
    if (v) [_body appendFormat:@"  %@ = %@;\n", var, v];
    if (ts_LLVMIsAConstantInt(idx)) {
        [_body appendFormat:@"  %@.%@ = %@;\n", var, TSCLComp((unsigned)ts_LLVMConstIntGetZExtValue(idx)), x];
    } else {
        NSString *ie = [self expr:idx];
        if (!ie) return nil;
        NSString *lane = mask ? @"int" : [self laneName:[self scalarOf:vt]];
        [_body appendFormat:@"  ((%@ *)&%@)[%@] = %@;\n", lane, var, ie, x];
    }
    TSCLV *r = TSCLExpr(var, nil);
    _vals[KEY(inst)] = r;
    return r;
}

- (TSCLV *)shuffle:(LLVMValueRef)inst {
    LLVMValueRef a = ts_LLVMGetOperand(inst, 0), b = ts_LLVMGetOperand(inst, 1);
    NSString *ae = [self expr:a], *be = [self expr:b];
    if (!ae || !be) return nil;
    unsigned na = [self lanes:ts_LLVMTypeOf(a)], n = ts_LLVMGetNumMaskElements(inst);
    LLVMTypeRef t = ts_LLVMTypeOf(inst);
    NSString *ct = [self ctype:t];
    if (!ct) return nil;
    NSString *zero = [self intWidth:t] == 1 ? @"0" : [self zeroOf:[self scalarOf:t]];
    NSMutableArray *lanes = [NSMutableArray array];
    for (unsigned i = 0; i < n; i++) {
        int m = ts_LLVMGetMaskValue(inst, i);
        if (m < 0) [lanes addObject:zero];
        else if ((unsigned)m < na) [lanes addObject:[NSString stringWithFormat:@"(%@).%@", ae, TSCLComp((unsigned)m)]];
        else [lanes addObject:[NSString stringWithFormat:@"(%@).%@", be, TSCLComp((unsigned)m - na)]];
    }
    return [self define:inst expr:[NSString stringWithFormat:@"(%@)(%@)", ct, [lanes componentsJoinedByString:@", "]]];
}

- (NSString *)memberPath:(LLVMValueRef)inst type:(LLVMTypeRef)t {
    unsigned n = ts_LLVMGetNumIndices(inst);
    const unsigned *idx = ts_LLVMGetIndices(inst);
    NSMutableString *path = [NSMutableString string];
    for (unsigned i = 0; i < n; i++) {
        if (ts_LLVMGetTypeKind(t) == LLVMStructTypeKind) { [path appendFormat:@".m%u", idx[i]]; t = ts_LLVMStructGetTypeAtIndex(t, idx[i]); }
        else { [path appendFormat:@".a[%u]", idx[i]]; t = ts_LLVMGetElementType(t); }
    }
    return path;
}

- (TSCLV *)aggregate:(LLVMValueRef)inst insert:(BOOL)insert {
    LLVMValueRef agg = ts_LLVMGetOperand(inst, 0);
    LLVMTypeRef at = ts_LLVMTypeOf(agg);
    if (!insert) {
        TSCLV *a = [self value:agg];
        if (!a) return nil;
        if (a->kind != TSCLVExpr) FAIL(@"extractvalue of a handle");
        return [self define:inst expr:[a->expr stringByAppendingString:[self memberPath:inst type:at]]];
    }
    NSString *ct = [self ctype:at];
    NSString *x = [self expr:ts_LLVMGetOperand(inst, 1)];
    if (!ct || !x) return nil;
    NSString *var = [self newVar:ct];
    if (!(ts_LLVMIsUndef(agg) || ts_LLVMIsPoison(agg))) {
        NSString *a = [self expr:agg];
        if (!a) return nil;
        [_body appendFormat:@"  %@ = %@;\n", var, a];
    }
    [_body appendFormat:@"  %@%@ = %@;\n", var, [self memberPath:inst type:at], x];
    TSCLV *r = TSCLExpr(var, nil);
    _vals[KEY(inst)] = r;
    return r;
}

- (TSCLV *)select:(LLVMValueRef)inst {
    LLVMValueRef c = ts_LLVMGetOperand(inst, 0);
    TSCLV *a = [self value:ts_LLVMGetOperand(inst, 1)], *b = [self value:ts_LLVMGetOperand(inst, 2)];
    NSString *ce = [self expr:c];
    if (!a || !b || !ce) return nil;
    if (a->kind != TSCLVExpr || b->kind != TSCLVExpr) FAIL(@"select between textures or samplers");
    LLVMTypeRef t = ts_LLVMTypeOf(inst);
    if (ts_LLVMGetTypeKind(ts_LLVMTypeOf(c)) == LLVMVectorTypeKind) {
        unsigned n = [self lanes:t];
        NSString *mt = [self maskTypeFor:t];
        NSString *m = [mt isEqualToString:[NSString stringWithFormat:@"int%u", n]] ? ce : [NSString stringWithFormat:@"convert_%@(%@)", mt, ce];
        return [self define:inst expr:[NSString stringWithFormat:@"select(%@, %@, %@)", b->expr, a->expr, m]];
    }
    if (ts_LLVMGetTypeKind(t) == LLVMPointerTypeKind) {
        if (![a->space isEqualToString:b->space]) FAIL(@"select between pointers of different address spaces");
        return [self define:inst expr:[NSString stringWithFormat:@"(%@) ? %@ : %@", ce, a->expr, b->expr] type:TSCLPtrType(a->space, @"uchar") space:a->space];
    }
    return [self define:inst expr:[NSString stringWithFormat:@"(%@) ? %@ : %@", ce, a->expr, b->expr]];
}

#pragma mark Calls

- (NSArray<NSString *> *)argExprs:(LLVMValueRef)call from:(unsigned)first {
    unsigned n = ts_LLVMGetNumArgOperands(call);
    NSMutableArray *a = [NSMutableArray array];
    for (unsigned i = first; i < n; i++) {
        NSString *e = [self expr:ts_LLVMGetOperand(call, i)];
        if (!e) return nil;
        [a addObject:e];
    }
    return a;
}

- (TSCLV *)call:(LLVMValueRef)inst {
    LLVMValueRef callee = ts_LLVMGetCalledValue(inst);
    size_t len = 0;
    const char *cname = callee ? ts_LLVMGetValueName2(callee, &len) : NULL;
    if (!cname || !len) FAIL(@"indirect call");
    NSString *name = [[NSString alloc] initWithBytes:cname length:len encoding:NSUTF8StringEncoding];
    if ([name hasPrefix:@"llvm.lifetime"] || [name hasPrefix:@"llvm.dbg"] || [name hasPrefix:@"llvm.assume"] ||
        [name hasPrefix:@"llvm.experimental.noalias"] || [name hasPrefix:@"llvm.invariant"])
        return [TSCLV new];
    if ([name hasPrefix:@"air.wg.barrier"] || [name hasPrefix:@"air.mem_barrier"]) {
        LLVMValueRef f = ts_LLVMGetOperand(inst, 0);
        unsigned flags = f && ts_LLVMIsAConstantInt(f) ? (unsigned)ts_LLVMConstIntGetZExtValue(f) : 3;
        NSMutableArray *fences = [NSMutableArray array];
        if (flags & 2) [fences addObject:@"CLK_LOCAL_MEM_FENCE"];
        if (flags & 5) [fences addObject:@"CLK_GLOBAL_MEM_FENCE"];
        if (!fences.count) [fences addObject:@"CLK_LOCAL_MEM_FENCE"];
        BOOL barrier = [name hasPrefix:@"air.wg.barrier"];
        _barriers |= barrier;
        [_body appendFormat:@"  %@(%@);\n", barrier ? @"barrier" : @"mem_fence", [fences componentsJoinedByString:@" | "]];
        return [TSCLV new];
    }
    if ([name hasPrefix:@"air.simd"] || [name hasPrefix:@"air.quad"]) FAIL(@"simdgroup function %@ (no subgroups in OpenCL 1.2)", name);
    if ([name isEqualToString:@"air.get_read_sampler"]) {
        TSCLV *s = [TSCLV new];
        s->kind = TSCLVSampler; s->slot = -1; s->readSampler = YES;
        _vals[KEY(inst)] = s;
        return s;
    }
    if ([name hasPrefix:@"llvm.memcpy"] || [name hasPrefix:@"llvm.memmove"] || [name hasPrefix:@"llvm.memset"]) return [self memoryIntrinsic:inst name:name];
    NSArray<NSString *> *parts = [name componentsSeparatedByString:@"."];
    if ([name hasPrefix:@"air.atomic."]) return [self atomic:inst parts:parts];
    if ([name hasPrefix:@"air."] && parts.count > 1 && [self isTextureCall:parts[1]]) return [self texture:inst name:parts[1] parts:parts];
    if ([name hasPrefix:@"air.convert."]) return [self convert:inst parts:parts];
    if ([name hasPrefix:@"air."] || [name hasPrefix:@"llvm."]) return [self math:inst parts:parts];
    FAIL(@"call to %@ (not inlined)", name);
}

- (TSCLV *)memoryIntrinsic:(LLVMValueRef)inst name:(NSString *)name {
    TSCLV *dst = [self value:ts_LLVMGetOperand(inst, 0)];
    NSString *len = [self expr:ts_LLVMGetOperand(inst, 2)];
    if (!dst || !len) return nil;
    if ([dst->space isEqualToString:@"__constant"]) FAIL(@"%@ into constant memory", name);
    NSString *d = TSCLPtrType(dst->space, @"uchar");
    if ([name hasPrefix:@"llvm.memset"]) {
        NSString *b = [self expr:ts_LLVMGetOperand(inst, 1)];
        if (!b) return nil;
        [_body appendFormat:@"  for (uint ts_i = 0; ts_i < (uint)(%@); ts_i++) ((%@)%@)[ts_i] = %@;\n", len, d, dst->expr, b];
        return [TSCLV new];
    }
    TSCLV *src = [self value:ts_LLVMGetOperand(inst, 1)];
    if (!src) return nil;
    NSString *s = TSCLPtrType(src->space, @"const uchar");
    if ([name hasPrefix:@"llvm.memmove"])
        [_body appendFormat:@"  if ((uint)(%@) > 0) { if ((%@)%@ < (%@)%@) for (uint ts_i = 0; ts_i < (uint)(%@); ts_i++) ((%@)%@)[ts_i] = ((%@)%@)[ts_i];"
                             " else for (uint ts_i = (uint)(%@); ts_i-- > 0;) ((%@)%@)[ts_i] = ((%@)%@)[ts_i]; }\n",
                             len, d, dst->expr, d, src->expr, len, d, dst->expr, s, src->expr, len, d, dst->expr, s, src->expr];
    else
        [_body appendFormat:@"  for (uint ts_i = 0; ts_i < (uint)(%@); ts_i++) ((%@)%@)[ts_i] = ((%@)%@)[ts_i];\n", len, d, dst->expr, s, src->expr];
    return [TSCLV new];
}

// air.atomic.<global|local>.<op>[.<u|s>].<i32|f32>(ptr, [operand(s)], order(s), scope, volatile)
- (TSCLV *)atomic:(LLVMValueRef)inst parts:(NSArray<NSString *> *)parts {
    if (parts.count < 5) FAIL(@"malformed %@", [parts componentsJoinedByString:@"."]);
    NSString *op = parts[3], *type = parts.lastObject;
    BOOL sgn = [parts containsObject:@"s"];
    if (![type isEqualToString:@"i32"] && ![type isEqualToString:@"f32"]) FAIL(@"atomic on %@ (only 32-bit atomics in OpenCL 1.2)", type);
    TSCLV *p = [self value:ts_LLVMGetOperand(inst, 0)];
    if (!p || p->kind != TSCLVExpr) return nil;
    NSString *it = sgn ? @"int" : @"uint";
    NSString *ptr = [NSString stringWithFormat:@"(volatile %@)(%@)", TSCLPtrType(p->space, it), p->expr];
    NSString *uptr = [NSString stringWithFormat:@"(volatile %@)(%@)", TSCLPtrType(p->space, @"uint"), p->expr];
    BOOL isFloat = [type isEqualToString:@"f32"];
    if ([op isEqualToString:@"load"]) {
        NSString *e = [NSString stringWithFormat:@"*%@", uptr];
        return [self define:inst expr:isFloat ? [NSString stringWithFormat:@"as_float(%@)", e] : e];
    }
    NSString *v = [self expr:ts_LLVMGetOperand(inst, 1)];
    if (!v) return nil;
    if (isFloat) v = [NSString stringWithFormat:@"as_uint(%@)", v];
    if ([op isEqualToString:@"store"]) { [_body appendFormat:@"  atomic_xchg(%@, %@);\n", uptr, v]; return [TSCLV new]; }
    if ([op isEqualToString:@"cmpxchg"]) {
        // (ptr, expected* (thread), desired, order, order, scope, volatile) -> bool; *expected = old value.
        TSCLV *exp = [self value:ts_LLVMGetOperand(inst, 1)];
        NSString *des = [self expr:ts_LLVMGetOperand(inst, 2)];
        if (!exp || !des) return nil;
        if (isFloat) des = [NSString stringWithFormat:@"as_uint(%@)", des];
        NSString *ep = [NSString stringWithFormat:@"(%@)(%@)", TSCLPtrType(exp->space, @"uint"), exp->expr];
        NSString *old = [self newVar:@"uint"];
        [_body appendFormat:@"  %@ = atomic_cmpxchg(%@, *%@, %@);\n", old, uptr, ep, des];
        NSString *ok = [NSString stringWithFormat:@"(%@ == *%@)", old, ep];
        TSCLV *r = [self define:inst expr:ok];
        [_body appendFormat:@"  *%@ = %@;\n", ep, old];
        return r;
    }
    if (isFloat) {
        if (![op isEqualToString:@"add"] && ![op isEqualToString:@"sub"] && ![op isEqualToString:@"xchg"]) FAIL(@"float atomic %@", op);
        if ([op isEqualToString:@"xchg"]) return [self define:inst expr:[NSString stringWithFormat:@"as_float(atomic_xchg(%@, %@))", uptr, v]];
        NSString *h = [NSString stringWithFormat:@"ts_atomic_addf_%@", p->space.length ? p->space : @"private"];
        [self needHelper:h code:[NSString stringWithFormat:
            @"static inline float %@(volatile %@p, float v) {\n"
             "  uint old = *p, seen;\n  do { seen = old; old = atomic_cmpxchg(p, seen, as_uint(as_float(seen) + v)); } while (old != seen);\n"
             "  return as_float(old);\n}\n", h, TSCLPtrType(p->space, @"uint")]];
        NSString *val = [op isEqualToString:@"sub"] ? [NSString stringWithFormat:@"-as_float(%@)", v] : [NSString stringWithFormat:@"as_float(%@)", v];
        return [self define:inst expr:[NSString stringWithFormat:@"%@(%@, %@)", h, uptr, val]];
    }
    static NSDictionary *names;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        names = @{ @"add": @"atomic_add", @"sub": @"atomic_sub", @"min": @"atomic_min", @"max": @"atomic_max", @"and": @"atomic_and",
                   @"or": @"atomic_or", @"xor": @"atomic_xor", @"xchg": @"atomic_xchg" };
    });
    NSString *fn = names[op];
    if (!fn) FAIL(@"atomic %@", op);
    NSString *arg = sgn ? [NSString stringWithFormat:@"as_int(%@)", v] : v;
    NSString *e = [NSString stringWithFormat:@"%@(%@, %@)", fn, sgn ? ptr : uptr, arg];
    return [self define:inst expr:sgn ? [NSString stringWithFormat:@"as_uint(%@)", e] : e];
}

- (TSCLV *)convert:(LLVMValueRef)inst parts:(NSArray<NSString *> *)parts {
    // air.convert.<dst kind>.<dst type>.<src kind>.<src type>, kinds f / u / s
    if (parts.count < 6) FAIL(@"malformed %@", [parts componentsJoinedByString:@"."]);
    NSString *dk = parts[2], *sk = parts[4];
    LLVMValueRef src = ts_LLVMGetOperand(inst, 0);
    NSString *x = [self expr:src];
    if (!x) return nil;
    LLVMTypeRef to = ts_LLVMTypeOf(inst), from = ts_LLVMTypeOf(src);
    NSString *ct = [self ctype:to], *ft = [self ctype:from];
    if (!ct || !ft) return nil;
    unsigned n = [self lanes:to], fw = [self intWidth:from], tw = [self intWidth:to];
    if ([dk isEqualToString:@"f"]) {
        if ([sk isEqualToString:@"f"]) return [self define:inst expr:x];
        if (fw == 1) return [self define:inst expr:n > 1 ? [NSString stringWithFormat:@"convert_%@(-(%@))", ct, x] : [NSString stringWithFormat:@"((%@) ? 1.0f : 0.0f)", x]];
        NSString *s = [sk isEqualToString:@"s"] ? [NSString stringWithFormat:@"as_%@(%@)", TSCLSigned(ft), x] : x;
        return [self define:inst expr:n > 1 ? [NSString stringWithFormat:@"convert_%@(%@)", ct, s] : [NSString stringWithFormat:@"(float)(%@)", s]];
    }
    if (tw == 1) {
        NSString *zero = [sk isEqualToString:@"f"] ? @"0.0f" : @"0";
        return [self define:inst expr:n > 1 ? [NSString stringWithFormat:@"convert_int%u(%@ != %@)", n, x, zero] : [NSString stringWithFormat:@"((%@) != %@)", x, zero]];
    }
    NSString *target = [dk isEqualToString:@"s"] ? TSCLSigned(ct) : ct;
    NSString *e;
    if ([sk isEqualToString:@"f"]) {
        // Metal float -> integer conversions saturate (NaN -> 0).
        e = [NSString stringWithFormat:@"convert_%@_sat(%@)", target, x];
    } else if (fw == 1) {
        e = n > 1 ? [NSString stringWithFormat:@"convert_%@(-(%@))", target, x] : [NSString stringWithFormat:@"(%@)(%@)", target, x];
    } else {
        NSString *s = [sk isEqualToString:@"s"] ? [NSString stringWithFormat:@"as_%@(%@)", TSCLSigned(ft), x] : x;
        e = n > 1 ? [NSString stringWithFormat:@"convert_%@(%@)", target, s] : [NSString stringWithFormat:@"(%@)(%@)", target, s];
    }
    if (![target isEqualToString:ct]) e = n > 1 ? [NSString stringWithFormat:@"as_%@(%@)", ct, e] : [NSString stringWithFormat:@"(%@)(%@)", ct, e];
    return [self define:inst expr:e];
}

- (TSCLV *)math:(LLVMValueRef)inst parts:(NSArray<NSString *> *)parts {
    NSString *base = parts.count > 1 ? parts[1] : @"";
    if ([base hasPrefix:@"fast_"]) base = [base substringFromIndex:5];
    if ([base hasPrefix:@"precise_"]) base = [base substringFromIndex:8];
    BOOL sgn = [parts containsObject:@"s"];
    NSArray<NSString *> *a = [self argExprs:inst from:0];
    if (!a) return nil;
    LLVMTypeRef t = ts_LLVMTypeOf(inst);
    BOOL isVoid = ts_LLVMGetTypeKind(t) == LLVMVoidTypeKind;
    LLVMTypeRef at = ts_LLVMGetNumArgOperands(inst) ? ts_LLVMTypeOf(ts_LLVMGetOperand(inst, 0)) : t;
    BOOL isInt = !isVoid && [self intWidth:t] > 1;
    NSString *ct = isVoid ? nil : [self ctype:t];
    NSString *e = nil;
    static NSDictionary<NSString *, NSString *> *same;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableDictionary *s = [NSMutableDictionary dictionary];
        for (NSString *n in @[@"sin", @"cos", @"tan", @"asin", @"acos", @"atan", @"sinh", @"cosh", @"tanh", @"asinh", @"acosh", @"atanh",
                              @"exp", @"exp2", @"exp10", @"log", @"log2", @"log10", @"sqrt", @"rsqrt", @"floor", @"ceil", @"trunc", @"round",
                              @"rint", @"sign", @"normalize", @"length", @"dot", @"cross", @"distance", @"mix", @"step", @"smoothstep",
                              @"pow", @"powr", @"fma", @"mad", @"radians", @"degrees", @"atan2", @"fmod", @"copysign", @"ldexp", @"fdim",
                              @"sinpi", @"cospi", @"tanpi", @"asinpi", @"acospi", @"atanpi", @"cbrt", @"nextafter", @"hypot", @"logb",
                              @"fast_distance", @"fast_length", @"fast_normalize"])
            s[n] = n;
        s[@"fmuladd"] = @"fma"; s[@"minnum"] = @"fmin"; s[@"maxnum"] = @"fmax"; s[@"fmin"] = @"fmin"; s[@"fmax"] = @"fmax";
        s[@"fabs"] = @"fabs"; s[@"roundeven"] = @"rint"; s[@"exp10"] = @"exp10";
        same = s;
    });
    NSString *fn = same[base];
    if ([base isEqualToString:@"abs"] && !isInt) fn = @"fabs";
    if (([base isEqualToString:@"min"] || [base isEqualToString:@"max"]) && !isInt) fn = [@"f" stringByAppendingString:base];
    if ([base isEqualToString:@"clamp"] && !isInt) fn = @"clamp";
    if (fn && !isInt) {
        // GLSL-style scalar arguments to vector functions are fine in CL for mix/clamp/step/smoothstep/fmin/fmax.
        e = [NSString stringWithFormat:@"%@(%@)", fn, [a componentsJoinedByString:@", "]];
        if ([fn isEqualToString:@"ldexp"] && a.count == 2) e = [NSString stringWithFormat:@"ldexp(%@, as_int%@(%@))", a[0],
                                                               [self lanes:t] > 1 ? [NSString stringWithFormat:@"%u", [self lanes:t]] : @"", a[1]];
    } else if (isInt && ([base isEqualToString:@"min"] || [base isEqualToString:@"max"] || [base isEqualToString:@"clamp"] ||
                         [base isEqualToString:@"smin"] || [base isEqualToString:@"smax"] || [base isEqualToString:@"umin"] ||
                         [base isEqualToString:@"umax"] || [base isEqualToString:@"abs"] || [base isEqualToString:@"add_sat"] ||
                         [base isEqualToString:@"addsat"] || [base isEqualToString:@"sub_sat"] || [base isEqualToString:@"subsat"] ||
                         [base isEqualToString:@"mul_hi"] || [base isEqualToString:@"mulhi"] || [base isEqualToString:@"hadd"] ||
                         [base isEqualToString:@"rhadd"] || [base isEqualToString:@"absdiff"] || [base isEqualToString:@"rotate"] ||
                         [base isEqualToString:@"uadd"] || [base isEqualToString:@"sadd"] || [base isEqualToString:@"usub"] ||
                         [base isEqualToString:@"ssub"])) {
        NSString *b = base;
        if ([b hasPrefix:@"s"] && ([b hasSuffix:@"min"] || [b hasSuffix:@"max"])) { sgn = YES; b = [b substringFromIndex:1]; }
        if ([b hasPrefix:@"u"] && ([b hasSuffix:@"min"] || [b hasSuffix:@"max"])) { sgn = NO; b = [b substringFromIndex:1]; }
        NSDictionary *map = @{ @"addsat": @"add_sat", @"subsat": @"sub_sat", @"mulhi": @"mul_hi", @"absdiff": @"abs_diff",
                               @"uadd": @"add_sat", @"sadd": @"add_sat", @"usub": @"sub_sat", @"ssub": @"sub_sat" };
        if ([parts containsObject:@"sat"] || map[b]) b = map[b] ?: b;
        if ([base hasPrefix:@"sadd"] || [base hasPrefix:@"ssub"]) sgn = YES;
        if ([b isEqualToString:@"abs"] && a.count == 2 && [parts.firstObject isEqualToString:@"llvm"]) { a = @[a[0]]; sgn = YES; }
        NSMutableArray *args = [NSMutableArray array];
        NSString *st = TSCLSigned(ct);
        for (NSString *x in a) [args addObject:sgn ? [NSString stringWithFormat:@"as_%@(%@)", st, x] : x];
        e = [NSString stringWithFormat:@"%@(%@)", b, [args componentsJoinedByString:@", "]];
        if (sgn && ![b isEqualToString:@"abs"] && ![b isEqualToString:@"abs_diff"]) e = [NSString stringWithFormat:@"as_%@(%@)", ct, e];
    } else if ([base isEqualToString:@"fract"]) {
        e = [NSString stringWithFormat:@"fmin(%@ - floor(%@), 0x1.fffffep-1f)", a[0], a[0]];
    } else if ([base isEqualToString:@"saturate"]) {
        e = [NSString stringWithFormat:@"clamp(%@, 0.0f, 1.0f)", a[0]];
    } else if ([base isEqualToString:@"isnan"] || [base isEqualToString:@"isinf"] || [base isEqualToString:@"isfinite"] ||
               [base isEqualToString:@"signbit"] || [base isEqualToString:@"isnormal"]) {
        e = [NSString stringWithFormat:@"%@(%@)", base, a[0]];
        if ([self lanes:t] == 1) e = [NSString stringWithFormat:@"(%@ != 0)", e];
    } else if ([base isEqualToString:@"all"] || [base isEqualToString:@"any"]) {
        e = [self lanes:at] > 1 ? [NSString stringWithFormat:@"(%@(%@) != 0)", base, a[0]] : a[0];
    } else if ([base isEqualToString:@"popcount"] || [base isEqualToString:@"ctpop"]) {
        e = [NSString stringWithFormat:@"popcount(%@)", a[0]];
    } else if ([base isEqualToString:@"clz"] || [base isEqualToString:@"ctlz"]) {
        e = [NSString stringWithFormat:@"clz(%@)", a[0]];
    } else if ([base isEqualToString:@"ctz"] || [base isEqualToString:@"cttz"]) {
        // ctz(x) = bits - 1 - clz(x & -x), and the full width for 0.
        unsigned w = [self intWidth:t];
        e = [NSString stringWithFormat:@"select((%@)(%u - 1) - clz((%@) & (~(%@) + (%@)(1))), (%@)(%u), (%@) == (%@)(0))",
             ct, w, a[0], a[0], ct, ct, w, a[0], ct];
        if ([self lanes:t] == 1) e = [NSString stringWithFormat:@"((%@) == 0 ? (%@)%u : (%@)(%u - 1 - clz((%@) & (~(%@) + 1))))", a[0], ct, w, ct, w, a[0], a[0]];
    } else if ([base isEqualToString:@"reverse_bits"] || [base isEqualToString:@"bitreverse"]) {
        if ([self intWidth:t] != 32) FAIL(@"reverse_bits on i%u", [self intWidth:t]);
        NSString *h = [NSString stringWithFormat:@"ts_rev_%@", ct];
        [self needHelper:h code:[NSString stringWithFormat:@"static inline %@ %@(%@ x) {\n"
            "  x = ((x >> 1) & (%@)0x55555555u) | ((x & (%@)0x55555555u) << 1); x = ((x >> 2) & (%@)0x33333333u) | ((x & (%@)0x33333333u) << 2);\n"
            "  x = ((x >> 4) & (%@)0x0F0F0F0Fu) | ((x & (%@)0x0F0F0F0Fu) << 4); x = ((x >> 8) & (%@)0x00FF00FFu) | ((x & (%@)0x00FF00FFu) << 8);\n"
            "  return (x >> 16) | (x << 16);\n}\n", ct, h, ct, ct, ct, ct, ct, ct, ct, ct, ct]];
        e = [NSString stringWithFormat:@"%@(%@)", h, a[0]];
    } else if ([base isEqualToString:@"bswap"]) {
        if ([self intWidth:t] != 32 || [self lanes:t] != 1) FAIL(@"bswap on this type");
        e = [NSString stringWithFormat:@"as_uint(as_uchar4(%@).s3210)", a[0]];
    } else if ([base isEqualToString:@"fmin3"] || [base isEqualToString:@"min3"] || [base isEqualToString:@"fmax3"] || [base isEqualToString:@"max3"]) {
        BOOL mn = [base containsString:@"min"];
        NSString *f = isInt ? (mn ? @"min" : @"max") : (mn ? @"fmin" : @"fmax");
        if (isInt && sgn) {
            NSString *st = TSCLSigned(ct);
            e = [NSString stringWithFormat:@"as_%@(%@(as_%@(%@), %@(as_%@(%@), as_%@(%@))))", ct, f, st, a[0], f, st, a[1], st, a[2]];
        } else e = [NSString stringWithFormat:@"%@(%@, %@(%@, %@))", f, a[0], f, a[1], a[2]];
    } else if ([base isEqualToString:@"fmedian3"] || [base isEqualToString:@"median3"]) {
        if (isInt) FAIL(@"integer median3");
        e = [NSString stringWithFormat:@"fmax(fmin(%@, %@), fmin(fmax(%@, %@), %@))", a[0], a[1], a[0], a[1], a[2]];
    } else if ([base isEqualToString:@"reflect"]) {
        e = [NSString stringWithFormat:@"(%@ - 2.0f * dot(%@, %@) * %@)", a[0], a[1], a[0], a[1]];
    } else if ([base isEqualToString:@"refract"]) {
        NSString *h = @"ts_refract";
        [self needHelper:[h stringByAppendingString:ct] code:[NSString stringWithFormat:
            @"static inline %@ %@_%@(%@ i, %@ n, float eta) { float d = dot(n, i), k = 1.0f - eta * eta * (1.0f - d * d);\n"
             "  return k < 0.0f ? (%@)(0.0f) : eta * i - (eta * d + sqrt(k)) * n; }\n", ct, h, ct, ct, ct, ct]];
        e = [NSString stringWithFormat:@"%@_%@(%@, %@, %@)", h, ct, a[0], a[1], a[2]];
    } else if ([base isEqualToString:@"extract_bits"] && a.count == 3 && isInt) {
        // (x >> offset) & mask(bits), sign-extended for the signed form.
        unsigned w = [self intWidth:t];
        NSString *st = TSCLSigned(ct);
        e = sgn ? [NSString stringWithFormat:@"((%@) == 0 ? (%@)0 : as_%@((as_%@(%@) << (%u - (%@) - (%@))) >> (%u - (%@))))", a[2], ct, ct, st, a[0], w, a[1], a[2], w, a[2]]
                : [NSString stringWithFormat:@"((%@) == 0 ? (%@)0 : ((%@) << (%u - (%@) - (%@))) >> (%u - (%@)))", a[2], ct, a[0], w, a[1], a[2], w, a[2]];
    } else if ([base isEqualToString:@"insert_bits"] && a.count == 4 && isInt) {
        e = [NSString stringWithFormat:@"((%@) == 0 ? (%@) : (((%@) & ~(((~(%@)0) >> (%u - (%@))) << (%@))) | (((%@) << (%@)) & (((~(%@)0) >> (%u - (%@))) << (%@)))))",
             a[3], a[0], a[0], ct, [self intWidth:t], a[3], a[2], a[1], a[2], ct, [self intWidth:t], a[3], a[2]];
    } else if ([base isEqualToString:@"fshl"] || [base isEqualToString:@"fshr"]) {
        if (![a[0] isEqualToString:a[1]]) FAIL(@"funnel shift of two values");
        e = [base isEqualToString:@"fshl"] ? [NSString stringWithFormat:@"rotate(%@, %@)", a[0], a[2]]
                                           : [NSString stringWithFormat:@"rotate(%@, (%@)(%u) - (%@))", a[0], ct, [self intWidth:t], a[2]];
    } else if (([base isEqualToString:@"pack"] || [base isEqualToString:@"unpack"]) && parts.count > 2) {
        e = [self packing:base format:parts[2] arg:a[0]];
        if (!e) FAIL(@"unsupported %@", [parts componentsJoinedByString:@"."]);
    } else if ([base isEqualToString:@"select"] && a.count == 3) {
        e = [NSString stringWithFormat:@"((%@) ? %@ : %@)", a[2], a[1], a[0]];
    } else if ([base isEqualToString:@"dfdx"] || [base isEqualToString:@"dfdy"] || [base isEqualToString:@"fwidth"]) {
        FAIL(@"derivative in a kernel");
    } else {
        FAIL(@"unsupported intrinsic %@", [parts componentsJoinedByString:@"."]);
    }
    if (isVoid) { [_body appendFormat:@"  %@;\n", e]; return [TSCLV new]; }
    return [self define:inst expr:e];
}

- (NSString *)packing:(NSString *)op format:(NSString *)fmt arg:(NSString *)x {
    if ([op isEqualToString:@"pack"]) {
        if ([fmt isEqualToString:@"unorm4x8"]) return [NSString stringWithFormat:@"as_uint(convert_uchar4_sat_rte(clamp(%@, 0.0f, 1.0f) * 255.0f))", x];
        if ([fmt isEqualToString:@"snorm4x8"]) return [NSString stringWithFormat:@"as_uint(convert_char4_sat_rte(clamp(%@, -1.0f, 1.0f) * 127.0f))", x];
        if ([fmt isEqualToString:@"unorm2x16"]) return [NSString stringWithFormat:@"as_uint(convert_ushort2_sat_rte(clamp(%@, 0.0f, 1.0f) * 65535.0f))", x];
        if ([fmt isEqualToString:@"snorm2x16"]) return [NSString stringWithFormat:@"as_uint(convert_short2_sat_rte(clamp(%@, -1.0f, 1.0f) * 32767.0f))", x];
        return nil;
    }
    if ([fmt isEqualToString:@"unorm4x8"]) return [NSString stringWithFormat:@"(convert_float4(as_uchar4(%@)) / 255.0f)", x];
    if ([fmt isEqualToString:@"snorm4x8"]) return [NSString stringWithFormat:@"clamp(convert_float4(as_char4(%@)) / 127.0f, -1.0f, 1.0f)", x];
    if ([fmt isEqualToString:@"unorm2x16"]) return [NSString stringWithFormat:@"(convert_float2(as_ushort2(%@)) / 65535.0f)", x];
    if ([fmt isEqualToString:@"snorm2x16"]) return [NSString stringWithFormat:@"clamp(convert_float2(as_short2(%@)) / 32767.0f, -1.0f, 1.0f)", x];
    return nil;
}

#pragma mark Textures

- (BOOL)isTextureCall:(NSString *)base {
    return [base hasPrefix:@"sample_"] || [base hasPrefix:@"read_"] || [base hasPrefix:@"gather_"] || [base hasPrefix:@"get_width_"] ||
           [base hasPrefix:@"get_height_"] || [base hasPrefix:@"get_depth_"] || [base hasPrefix:@"get_num_mip_levels_"] ||
           [base hasPrefix:@"get_array_size_"] || [base hasPrefix:@"get_num_samples_"] || [base hasPrefix:@"write_"] ||
           [base hasPrefix:@"fence_"] || [base hasPrefix:@"is_null_"];
}

// gather_texture_2d(tex, sampler, coord, [i1, offset], [i32 component], ...): the 2x2 footprint of a bilinear sample,
// read texel by texel (no gather in OpenCL 1.2). Lanes as Metal orders them: (0,1), (1,1), (1,0), (0,0).
- (TSCLV *)gather:(LLVMValueRef)inst texture:(TSCLV *)tex function:(NSString *)rfn fix:(NSString *(^)(NSString *))fix {
    if (tex->dims != 2 || tex->array) FAIL(@"gather on this texture shape");
    TSCLV *smp = [self value:ts_LLVMGetOperand(inst, 1)];
    NSString *c = [self expr:ts_LLVMGetOperand(inst, 2)];
    if (!smp || !c) return nil;
    unsigned n = ts_LLVMGetNumArgOperands(inst);
    NSString *off = @"(int2)(0)", *comp = @"0";
    if (n > 4) {
        LLVMValueRef o = ts_LLVMGetOperand(inst, 4);
        if (ts_LLVMGetTypeKind(ts_LLVMTypeOf(o)) == LLVMVectorTypeKind) {
            NSString *oe = [self expr:o];
            if (!oe) return nil;
            off = [NSString stringWithFormat:@"convert_int2(%@)", oe];
        }
    }
    if (n > 6) {
        LLVMValueRef cv = ts_LLVMGetOperand(inst, 5);
        if (ts_LLVMGetTypeKind(ts_LLVMTypeOf(cv)) == LLVMIntegerTypeKind) { comp = [self expr:cv]; if (!comp) return nil; }
    }
    BOOL pixel = smp->slot < 0 && !smp->readSampler && [smp->expr hasPrefix:@"ts_cs_"] &&
                 ((strtoull(smp->expr.UTF8String + 6, NULL, 16) >> 15) & 1);
    NSString *rd = tex->expr;
    NSString *size = [NSString stringWithFormat:@"(int2)(get_image_width(%@), get_image_height(%@))", rd, rd];
    NSString *base = [self newVar:@"int2"], *v = [self newVar:@"float4"];
    [_body appendFormat:@"  %@ = convert_int2(floor(%@%@ - 0.5f)) + %@;\n", base, c, pixel ? @"" : [NSString stringWithFormat:@" * convert_float2(%@)", size], off];
    static const int dx[4] = { 0, 1, 1, 0 }, dy[4] = { 1, 1, 0, 0 };
    NSMutableArray *lanes = [NSMutableArray array];
    for (int i = 0; i < 4; i++)
        [lanes addObject:[NSString stringWithFormat:@"((float *)&ts_g%d)[%@]", i, comp]];
    [_body appendString:@"  {\n"];
    for (int i = 0; i < 4; i++)
        [_body appendFormat:@"    float4 ts_g%d = convert_float4(%@(%@, clamp(%@ + (int2)(%d, %d), (int2)(0), %@ - 1)));\n", i, rfn, rd, base, dx[i], dy[i], size];
    [_body appendFormat:@"    %@ = (float4)(%@);\n  }\n", v, [lanes componentsJoinedByString:@", "]];
    LLVMTypeRef rt = ts_LLVMTypeOf(inst);
    LLVMTypeRef vt = ts_LLVMGetTypeKind(rt) == LLVMStructTypeKind ? ts_LLVMStructGetTypeAtIndex(rt, 0) : rt;
    NSString *vct = [self ctype:vt];
    NSString *val = [vct hasPrefix:@"float"] ? v : [NSString stringWithFormat:@"convert_%@(%@)", vct, v];
    (void)fix;
    return [self texResult:inst value:val];
}

// Value of a texture call returning { <4 x T>, i8 } or <4 x T>.
- (TSCLV *)texResult:(LLVMValueRef)inst value:(NSString *)e {
    LLVMTypeRef rt = ts_LLVMTypeOf(inst);
    // ushort/short textures: read_imageui/i return 32-bit lanes.
    LLVMTypeRef vt = ts_LLVMGetTypeKind(rt) == LLVMStructTypeKind ? ts_LLVMStructGetTypeAtIndex(rt, 0) : rt;
    unsigned w = [self intWidth:vt];
    if (w && w != 32 && [self lanes:vt] > 1) e = [NSString stringWithFormat:@"convert_%@(%@)", [self ctype:vt], e];
    if (ts_LLVMGetTypeKind(rt) != LLVMStructTypeKind) return [self define:inst expr:e];
    NSString *ct = [self ctype:rt];
    if (!ct) return nil;
    NSString *var = [self newVar:ct];
    [_body appendFormat:@"  %@.m0 = %@;\n", var, e];
    if (ts_LLVMCountStructElementTypes(rt) > 1) [_body appendFormat:@"  %@.m1 = %@;\n", var, [self zeroOf:ts_LLVMStructGetTypeAtIndex(rt, 1)]];
    TSCLV *v = TSCLExpr(var, nil);
    _vals[KEY(inst)] = v;
    return v;
}

- (TSCLV *)texture:(LLVMValueRef)inst name:(NSString *)base parts:(NSArray<NSString *> *)parts {
    if ([base hasPrefix:@"fence_"]) return [TSCLV new];
    if ([base containsString:@"depth"]) FAIL(@"depth texture");
    if ([base containsString:@"cube"]) FAIL(@"cube texture");
    if ([base containsString:@"_ms"]) FAIL(@"multisample texture");
    if ([base containsString:@"buffer"]) FAIL(@"texture buffer");
    LLVMValueRef texArg = ts_LLVMGetOperand(inst, 0);
    if (ts_LLVMIsUndef(texArg) || ts_LLVMIsPoison(texArg)) {
        LLVMTypeRef rt = ts_LLVMTypeOf(inst);
        if (ts_LLVMGetTypeKind(rt) == LLVMVoidTypeKind) return [TSCLV new];
        LLVMTypeRef vt = ts_LLVMGetTypeKind(rt) == LLVMStructTypeKind ? ts_LLVMStructGetTypeAtIndex(rt, 0) : rt;
        return [self texResult:inst value:[self zeroOf:vt]];
    }
    TSCLV *tex = [self value:texArg];
    if (!tex) return nil;
    if (tex->kind != TSCLVTexture) FAIL(@"texture call on a non-texture");
    NSString *rd = tex->expr, *wr = tex->rw ? [tex->expr stringByAppendingString:@"_w"] : tex->expr;
    char k = [parts containsObject:@"u"] ? 'u' : [parts containsObject:@"s"] ? 'i' : 'f';
    NSString *rfn = k == 'u' ? @"read_imageui" : k == 'i' ? @"read_imagei" : @"read_imagef";
    NSString *(^fix)(NSString *) = ^NSString *(NSString *x) { return k == 'i' ? [NSString stringWithFormat:@"as_uint4(%@)", x] : x; };
    unsigned dims = tex->dims;
    BOOL array = tex->array;

    // B5: bit <slot> of ts_null is set when no texture is bound (the dispatcher passes a 1x1 placeholder image).
    if ([base hasPrefix:@"is_null_"]) {
        if (tex->slot < 0) return [self define:inst expr:@"false"];
        [_nullSlots addIndex:(NSUInteger)tex->slot];
        return [self define:inst expr:[NSString stringWithFormat:@"((ts_null >> %du) & 1u) != 0u", tex->slot]];
    }
    if ([base hasPrefix:@"gather_"]) return [self gather:inst texture:tex function:rfn fix:fix];
    if ([base hasPrefix:@"get_"]) {
        NSString *e;
        if ([base hasPrefix:@"get_width_"]) e = [NSString stringWithFormat:@"(uint)get_image_width(%@)", rd];
        else if ([base hasPrefix:@"get_height_"]) e = [NSString stringWithFormat:@"(uint)get_image_height(%@)", rd];
        else if ([base hasPrefix:@"get_depth_"]) e = [NSString stringWithFormat:@"(uint)get_image_depth(%@)", rd];
        else if ([base hasPrefix:@"get_array_size_"]) e = [NSString stringWithFormat:@"(uint)get_image_array_size(%@)", rd];
        else e = @"1u";   // mip levels, samples: images are one level of the GL texture
        if (([base hasPrefix:@"get_width_"] || [base hasPrefix:@"get_height_"] || [base hasPrefix:@"get_depth_"]) && ts_LLVMGetNumArgOperands(inst) > 1) {
            LLVMValueRef lod = ts_LLVMGetOperand(inst, 1);
            if (!(ts_LLVMIsAConstantInt(lod) && ts_LLVMConstIntGetZExtValue(lod) == 0)) {
                NSString *le = [self expr:lod];
                if (!le) return nil;
                e = [NSString stringWithFormat:@"max(%@ >> (%@), 1u)", e, le];
            }
        }
        LLVMTypeRef rt = ts_LLVMTypeOf(inst);
        if ([self intWidth:rt] != 32) e = [NSString stringWithFormat:@"(%@)(%@)", [self ctype:rt], e];
        return [self define:inst expr:e];
    }
    if ([base hasPrefix:@"write_"]) {
        // write_<shape>(tex, coord, [layer], value, lod, access)
        if (dims == 3) FAIL(@"3D texture write (no cl_khr_3d_image_writes)");
        [self noteLod:ts_LLVMGetOperand(inst, ts_LLVMGetNumArgOperands(inst) - 2) texture:tex];
        unsigned i = 1;
        NSString *c = [self expr:ts_LLVMGetOperand(inst, i++)];
        if (!c) return nil;
        NSString *coord = [self intCoord:c dims:dims];
        if (array) {
            NSString *layer = [self expr:ts_LLVMGetOperand(inst, i++)];
            if (!layer) return nil;
            coord = [NSString stringWithFormat:@"(int4)(%@, (int)(%@), 0)", coord, layer];
        }
        NSString *v = [self expr:ts_LLVMGetOperand(inst, i++)];
        if (!v) return nil;
        NSString *wfn = k == 'u' ? @"write_imageui" : k == 'i' ? @"write_imagei" : @"write_imagef";
        unsigned vw = [self intWidth:ts_LLVMTypeOf(ts_LLVMGetOperand(inst, i - 1))];
        if (k == 'i') v = vw == 32 ? [NSString stringWithFormat:@"as_int4(%@)", v] : [NSString stringWithFormat:@"convert_int4(as_%@(%@))",
                                    TSCLSigned([self ctype:ts_LLVMTypeOf(ts_LLVMGetOperand(inst, i - 1))]), v];
        else if (k == 'u' && vw != 32) v = [NSString stringWithFormat:@"convert_uint4(%@)", v];
        [_body appendFormat:@"  %@(%@, %@, %@);\n", wfn, wr, coord, v];
        return [TSCLV new];
    }
    if ([base hasPrefix:@"read_"]) {
        // read_<shape>(tex, sampler, coord, [layer], [offset], lod, access)
        [self noteLod:ts_LLVMGetOperand(inst, ts_LLVMGetNumArgOperands(inst) - 2) texture:tex];
        NSString *c = [self expr:ts_LLVMGetOperand(inst, 2)];
        if (!c) return nil;
        unsigned next = 3;
        NSString *coord = [self intCoord:c dims:dims];
        if (array) {
            NSString *layer = [self expr:ts_LLVMGetOperand(inst, next++)];
            if (!layer) return nil;
            coord = [NSString stringWithFormat:@"(int4)(%@, (int)(%@), 0)", coord, layer];
        }
        return [self texResult:inst value:fix([NSString stringWithFormat:@"%@(%@, %@)", rfn, rd, coord])];
    }
    // sample_<shape>[_grad](tex, sampler, coord, [layer], [i1, offset], i1 isLod, float lod/bias, float minLod, i32)
    if ([base hasSuffix:@"_grad"] || [base hasPrefix:@"sample_compare"]) FAIL(@"%@ in a kernel", base);
    TSCLV *smp = [self value:ts_LLVMGetOperand(inst, 1)];
    if (!smp) return nil;
    if (smp->kind != TSCLVSampler) FAIL(@"sample() without a sampler");
    // ..., i1 isLod, float lod/bias, float minLod, i32: compute kernels sample level 0 plus lod or bias.
    [self noteLod:ts_LLVMGetOperand(inst, ts_LLVMGetNumArgOperands(inst) - 3) texture:tex];
    NSString *c = [self expr:ts_LLVMGetOperand(inst, 2)];
    if (!c) return nil;
    unsigned i = 3;
    NSString *layer = nil;
    if (array) {
        layer = [self expr:ts_LLVMGetOperand(inst, i++)];
        if (!layer) return nil;
    }
    if (i + 1 < ts_LLVMGetNumArgOperands(inst) && dims == 2) {
        LLVMValueRef off = ts_LLVMGetOperand(inst, i + 1);
        if (ts_LLVMGetTypeKind(ts_LLVMTypeOf(off)) == LLVMVectorTypeKind && !ts_LLVMIsAConstantAggregateZero(off) && !ts_LLVMIsUndef(off)) {
            NSString *o = [self expr:off];
            if (!o) return nil;
            // Texel offset: normalized samplers move by offset / size, pixel samplers by the offset itself.
            NSString *size = [NSString stringWithFormat:@"(float2)(get_image_width(%@), get_image_height(%@))", rd, rd];
            NSString *shift = [NSString stringWithFormat:@"convert_float2(as_int2(%@))", o];
            NSString *normalizedShift = [NSString stringWithFormat:@"(%@ + %@ / %@)", c, shift, size];
            if (smp->constexprKey) c = (smp->key >> 15) & 1 ? [NSString stringWithFormat:@"(%@ + %@)", c, shift] : normalizedShift;
            else c = normalizedShift;
        }
    }
    // Per-axis addressing (B3): wrap the coordinates by hand and zero clamp-to-zero axes outside the image.
    NSString *sampler = smp->readSampler ? @"ts_read_sampler" : smp->expr;
    NSString *am = nil;
    if (smp->constexprKey) {
        unsigned word = TSCLConstexprAM(smp->key, dims);
        if (word) {
            am = [NSString stringWithFormat:@"0x%xu", word];
            sampler = [smp->expr stringByAppendingString:@"_e"];
            if (![_helperSet containsObject:sampler]) {
                [_helperSet addObject:sampler];
                BOOL normalized = !((smp->key >> 15) & 1);
                [_globals appendFormat:@"const sampler_t %@ = %@ | CLK_ADDRESS_CLAMP_TO_EDGE | %@;\n", sampler,
                 normalized ? @"CLK_NORMALIZED_COORDS_TRUE" : @"CLK_NORMALIZED_COORDS_FALSE",
                 ((smp->key >> 9) & 3) || ((smp->key >> 11) & 3) ? @"CLK_FILTER_LINEAR" : @"CLK_FILTER_NEAREST"];
            }
        }
    } else if (smp->amExpr) {
        am = smp->amExpr;
    }
    NSString *zero = nil;
    if (am) {
        [self needHelper:@"ts_am" code:kTSCLAddressHelpers];
        unsigned n = MIN(dims, 3u);
        NSString *ft = n == 1 ? @"float" : [NSString stringWithFormat:@"float%u", n];
        NSString *dim = n == 1 ? [NSString stringWithFormat:@"(float)get_image_width(%@)", rd]
                      : n == 2 ? [NSString stringWithFormat:@"convert_float2(get_image_dim(%@))", rd]
                               : [NSString stringWithFormat:@"convert_float4(get_image_dim(%@)).xyz", rd];
        NSString *cv = [self newVar:ft];
        [_body appendFormat:@"  %@ = %@;\n", cv, c];
        zero = [NSString stringWithFormat:@"ts_amz%u(%@, %@, (%@ & 0x8000u) ? (%@)(1.0f) : %@)", n, cv, am, am, ft, dim];
        if (n == 1) zero = [NSString stringWithFormat:@"ts_amz1(%@, %@ & 15u, (%@ & 0x8000u) ? 1.0f : %@)", cv, am, am, dim];
        c = n == 1 ? [NSString stringWithFormat:@"ts_am1(%@, %@ & 15u)", cv, am] : [NSString stringWithFormat:@"ts_am%u(%@, %@)", n, cv, am];
    }
    NSString *coord = dims == 3 ? [NSString stringWithFormat:@"(float4)(%@, 0.0f)", c] : c;
    if (array) coord = [NSString stringWithFormat:@"(float4)(%@, (float)(%@), 0.0f)", c, layer];
    if (smp->readSampler)
        [self needHelper:@"ts_read_sampler" code:@"const sampler_t ts_read_sampler = CLK_NORMALIZED_COORDS_FALSE | CLK_ADDRESS_NONE | CLK_FILTER_NEAREST;\n"];
    // Integer images only take nearest filtering; float coordinates are fine for read_imageui with a sampler.
    NSString *read = [NSString stringWithFormat:@"%@(%@, %@, %@)", rfn, rd, sampler, coord];
    if (zero) read = [NSString stringWithFormat:@"(%@ ? (%@)(0) : %@)", zero, k == 'u' ? @"uint4" : k == 'i' ? @"int4" : @"float4", read];
    return [self texResult:inst value:fix(read)];
}

// A mip level, lod or bias that is not the constant 0: the CL image is level 0 of the GL texture, so the
// dispatcher refuses such a dispatch when the bound texture has more than one level (B4).
- (void)noteLod:(LLVMValueRef)lod texture:(TSCLV *)tex {
    if (!lod || tex->slot < 0) return;
    if (ts_LLVMIsAConstantInt(lod) && ts_LLVMConstIntGetZExtValue(lod) == 0) return;
    if (ts_LLVMIsAConstantFP(lod)) {
        LLVMBool lossy;
        if (ts_LLVMConstRealGetDouble(lod, &lossy) == 0.0) return;
    }
    if (ts_LLVMIsUndef(lod) || ts_LLVMIsPoison(lod)) return;
    [_lodSlots addIndex:(NSUInteger)tex->slot];
}

// Integer texel coordinates (Metal passes uint or ushort lanes).
- (NSString *)intCoord:(NSString *)c dims:(unsigned)dims {
    if (dims == 1) return [NSString stringWithFormat:@"(int)(%@)", c];
    if (dims == 2) return [NSString stringWithFormat:@"convert_int2(%@)", c];
    return [NSString stringWithFormat:@"(int4)(convert_int3(%@), 0)", c];
}

#pragma mark Control flow

- (NSString *)label:(LLVMBasicBlockRef)bb {
    NSNumber *n = _labels[KEY(bb)];
    if (!n) { n = @(_labels.count); _labels[KEY(bb)] = n; }
    return [NSString stringWithFormat:@"bb%@", n];
}

// Phi copies for the edge from -> to, then the jump (parallel copy through *_n temporaries).
- (NSString *)jumpFrom:(LLVMBasicBlockRef)from to:(LLVMBasicBlockRef)to {
    NSMutableString *s = [NSMutableString string], *commit = [NSMutableString string];
    for (LLVMValueRef i = ts_LLVMGetFirstInstruction(to); i && ts_LLVMGetInstructionOpcode(i) == LLVMPHI; i = ts_LLVMGetNextInstruction(i)) {
        unsigned n = ts_LLVMCountIncoming(i);
        LLVMValueRef in = NULL;
        for (unsigned k = 0; k < n; k++) if (ts_LLVMGetIncomingBlock(i, k) == from) { in = ts_LLVMGetIncomingValue(i, k); break; }
        if (!in) continue;
        TSCLV *phi = _vals[KEY(i)];
        TSCLV *v = [self value:in];
        if (!phi || !v) return nil;
        if (v->kind != TSCLVExpr) FAIL(@"phi of textures or samplers");
        [s appendFormat:@"%@_n = %@; ", phi->expr, v->expr];
        [commit appendFormat:@"%@ = %@_n; ", phi->expr, phi->expr];
    }
    return [NSString stringWithFormat:@"%@%@goto %@;", s, commit, [self label:to]];
}

- (BOOL)terminator:(LLVMValueRef)term block:(LLVMBasicBlockRef)bb {
    switch (ts_LLVMGetInstructionOpcode(term)) {
    case LLVMRet: case LLVMUnreachable: [_body appendString:@"  return;\n"]; return YES;
    case LLVMBr: {
        if (!ts_LLVMIsConditional(term)) {
            NSString *j = [self jumpFrom:bb to:ts_LLVMGetSuccessor(term, 0)];
            if (!j) return NO;
            [_body appendFormat:@"  %@\n", j];
            return YES;
        }
        NSString *c = [self expr:ts_LLVMGetCondition(term)];
        NSString *t = [self jumpFrom:bb to:ts_LLVMGetSuccessor(term, 0)], *f = [self jumpFrom:bb to:ts_LLVMGetSuccessor(term, 1)];
        if (!c || !t || !f) return NO;
        [_body appendFormat:@"  if (%@) { %@ } else { %@ }\n", c, t, f];
        return YES;
    }
    case LLVMSwitch: {
        NSString *c = [self expr:ts_LLVMGetOperand(term, 0)];
        if (!c) return NO;
        [_body appendFormat:@"  switch (%@) {\n", c];
        int n = ts_LLVMGetNumOperands(term);
        for (int i = 2; i + 1 < n; i += 2) {
            LLVMValueRef cv = ts_LLVMGetOperand(term, (unsigned)i);
            NSString *j = [self jumpFrom:bb to:ts_LLVMValueAsBasicBlock(ts_LLVMGetOperand(term, (unsigned)i + 1))];
            if (!j) return NO;
            [_body appendFormat:@"  case %llu: %@\n", ts_LLVMConstIntGetZExtValue(cv), j];
        }
        NSString *d = [self jumpFrom:bb to:ts_LLVMValueAsBasicBlock(ts_LLVMGetOperand(term, 1))];
        if (!d) return NO;
        [_body appendFormat:@"  default: %@\n  }\n", d];
        return YES;
    }
    default: FAILB(@"terminator opcode %d", ts_LLVMGetInstructionOpcode(term));
    }
}

- (BOOL)instruction:(LLVMValueRef)inst {
    LLVMOpcode op = ts_LLVMGetInstructionOpcode(inst);
    switch (op) {
    case LLVMPHI: return YES;   // declared up front, assigned on the edges
    case LLVMAdd: case LLVMFAdd: case LLVMSub: case LLVMFSub: case LLVMMul: case LLVMFMul: case LLVMUDiv: case LLVMSDiv:
    case LLVMFDiv: case LLVMURem: case LLVMSRem: case LLVMFRem: case LLVMShl: case LLVMLShr: case LLVMAShr: case LLVMAnd:
    case LLVMOr: case LLVMXor:
        return [self binary:inst op:op] != nil;
    case LLVMFNeg: { NSString *x = [self expr:ts_LLVMGetOperand(inst, 0)]; return x && [self define:inst expr:[NSString stringWithFormat:@"(-%@)", x]]; }
    case LLVMICmp: return [self compare:inst float:NO] != nil;
    case LLVMFCmp: return [self compare:inst float:YES] != nil;
    case LLVMTrunc: case LLVMZExt: case LLVMSExt: case LLVMFPToUI: case LLVMFPToSI: case LLVMUIToFP: case LLVMSIToFP:
    case LLVMFPTrunc: case LLVMFPExt: case LLVMBitCast: case LLVMAddrSpaceCast: case LLVMPtrToInt: case LLVMIntToPtr: case LLVMFreeze:
        return [self cast:inst op:op] != nil;
    case LLVMGetElementPtr: return [self gepInst:inst] != nil;
    case LLVMLoad: return [self loadInst:inst] != nil;
    case LLVMStore: return [self storeInst:inst];
    case LLVMAlloca: return [self allocaInst:inst] != nil;
    case LLVMExtractElement: return [self extractElement:inst] != nil;
    case LLVMInsertElement: return [self insertElement:inst] != nil;
    case LLVMShuffleVector: return [self shuffle:inst] != nil;
    case LLVMExtractValue: return [self aggregate:inst insert:NO] != nil;
    case LLVMInsertValue: return [self aggregate:inst insert:YES] != nil;
    case LLVMSelect: return [self select:inst] != nil;
    case LLVMCall: return [self call:inst] != nil;
    case LLVMFence: [_body appendString:@"  mem_fence(CLK_GLOBAL_MEM_FENCE | CLK_LOCAL_MEM_FENCE);\n"]; return YES;
    case LLVMAtomicRMW: case LLVMAtomicCmpXchg: FAILB(@"LLVM atomic instruction");
    default: FAILB(@"opcode %d", op);
    }
}

#pragma mark Entry

- (void)addArg:(TSCLArgSpec)spec { [_args appendBytes:&spec length:sizeof spec]; }

// Kernel parameters from !air.kernel. Built-ins become expressions; resources become CL arguments.
- (BOOL)declareParams:(NSArray *)params {
    unsigned nparams = ts_LLVMCountParams(_fn);
    for (id entry in params) {
        NSArray *ops = TSCLMDOperands((LLVMValueRef)[entry pointerValue]);
        LLVMValueRef idxv = TSCLOp(ops, 0);
        if (!idxv || !ts_LLVMIsAConstantInt(idxv)) FAILB(@"malformed argument metadata");
        unsigned idx = (unsigned)ts_LLVMConstIntGetZExtValue(idxv);
        if (idx >= nparams) continue;
        LLVMValueRef param = ts_LLVMGetParam(_fn, idx);
        NSString *kind = TSCLMDString(TSCLOp(ops, 1));
        BOOL used = ts_LLVMGetFirstUse(param) != NULL;
        long slot = TSCLMDIntAfter(ops, @"air.location_index", -1);
        LLVMTypeRef pt = ts_LLVMTypeOf(param);
        if ([kind isEqualToString:@"air.buffer"]) {
            if (!used) continue;
            long as = TSCLMDIntAfter(ops, @"air.address_space", 1);
            if (slot < 0 || slot > 30) FAILB(@"buffer index %ld", slot);
            if (as == 3) {
                [_params appendFormat:@", __local uchar *ts_l%ld", slot];
                _localArgs = YES;
                _vals[KEY(param)] = TSCLExpr([NSString stringWithFormat:@"ts_l%ld", slot], @"__local");
                [self addArg:(TSCLArgSpec){ TSCLArgLocal, (uint8_t)slot }];
                continue;
            }
            if (as != 1 && as != 2) FAILB(@"buffer in address space %ld", as);
            BOOL written = as == 1 && (TSCLMDHas(ops, @"air.read_write") || TSCLMDHas(ops, @"air.write"));
            [_params appendFormat:@", __global uchar *ts_b%ld, uint ts_b%ld_off", slot, slot];
            NSString *var = [NSString stringWithFormat:@"p%u", idx];
            [_prologue appendFormat:@"  __global uchar *%@ = ts_b%ld + ts_b%ld_off;\n", var, slot, slot];
            _vals[KEY(param)] = TSCLExpr(var, @"__global");
            [self addArg:(TSCLArgSpec){ TSCLArgBuffer, (uint8_t)slot, written }];
            continue;
        }
        if ([kind isEqualToString:@"air.texture"]) {
            if (!used) continue;
            NSString *tn = TSCLMDStringAfter(ops, @"air.arg_type_name") ?: @"";
            if (slot < 0 || slot > 31) FAILB(@"texture index %ld", slot);
            TSCLV *v = [TSCLV new];
            v->kind = TSCLVTexture;
            v->slot = (int)slot;
            v->expr = [NSString stringWithFormat:@"ts_t%ld", slot];
            v->dims = [tn hasPrefix:@"texture3d"] ? 3 : [tn hasPrefix:@"texture1d"] ? 1 : 2;
            v->array = [tn containsString:@"_array"];
            if ([tn hasPrefix:@"depth"]) FAILB(@"depth texture argument");
            if ([tn hasPrefix:@"texturecube"]) FAILB(@"cube texture argument");
            if ([tn hasPrefix:@"texture_buffer"]) FAILB(@"texture buffer argument");
            if ([tn containsString:@"_ms"]) FAILB(@"multisample texture argument");
            BOOL rw = TSCLMDHas(ops, @"air.read_write"), w = TSCLMDHas(ops, @"air.write");
            v->rw = rw;
            NSString *img = v->dims == 3 ? @"image3d_t" : v->dims == 1 ? (v->array ? @"image1d_array_t" : @"image1d_t")
                                                                       : (v->array ? @"image2d_array_t" : @"image2d_t");
            if (rw) [_params appendFormat:@", __read_only %@ ts_t%ld, __write_only %@ ts_t%ld_w", img, slot, img, slot];
            else [_params appendFormat:@", %@ %@ ts_t%ld", w ? @"__write_only" : @"__read_only", img, slot];
            _vals[KEY(param)] = v;
            [self addArg:(TSCLArgSpec){ TSCLArgTexture, (uint8_t)slot, (uint8_t)(w || rw), (uint8_t)rw, (uint8_t)v->dims, (uint8_t)v->array }];
            continue;
        }
        if ([kind isEqualToString:@"air.sampler"]) {
            if (!used) continue;
            if (slot < 0 || slot > 15) FAILB(@"sampler index %ld", slot);
            TSCLV *v = [TSCLV new];
            v->kind = TSCLVSampler;
            v->slot = (int)slot;
            v->expr = [NSString stringWithFormat:@"ts_s%ld", slot];
            v->amExpr = [NSString stringWithFormat:@"ts_s%ld_am", slot];
            [_params appendFormat:@", sampler_t ts_s%ld, uint ts_s%ld_am", slot, slot];
            _vals[KEY(param)] = v;
            [self addArg:(TSCLArgSpec){ TSCLArgSampler, (uint8_t)slot }];
            continue;
        }
        if (!used) continue;   // unused built-ins and resources need no CL argument
        if ([kind isEqualToString:@"air.imageblock"]) FAILB(@"imageblock argument (Apple GPUs only)");
        if ([kind containsString:@"quadgroup"]) FAILB(@"%@ (no quad groups in OpenCL 1.2)", kind);
        NSString *e = [self builtin:kind type:pt];
        if (!e) {
            if (!_error) _error = [NSString stringWithFormat:@"kernel argument %@", kind];
            return NO;
        }
        // Kernels that only read their grid position can run with any work-group shape.
        if (used && ![kind isEqualToString:@"air.thread_position_in_grid"] && ![kind isEqualToString:@"air.threads_per_grid"]) _shape = YES;
        _vals[KEY(param)] = TSCLExpr(e, nil);
    }
    return YES;
}

// Metal grid built-ins. ts_goff: threadgroup offset of a partial enqueue (edges of a dispatchThreads grid).
- (NSString *)builtin:(NSString *)role type:(LLVMTypeRef)t {
    NSArray<NSString *> *comps = nil;
    NSArray<NSString *> *(^dims)(NSString *, BOOL) = ^NSArray<NSString *> *(NSString *f, BOOL field) {
        NSMutableArray *a = [NSMutableArray array];
        for (int d = 0; d < 3; d++)
            [a addObject:field ? [NSString stringWithFormat:f, "xyz"[d]] : [NSString stringWithFormat:f, d]];
        return a;
    };
    if ([role isEqualToString:@"air.thread_position_in_grid"]) comps = dims(@"(uint)get_global_id(%d)", NO);
    else if ([role isEqualToString:@"air.thread_position_in_threadgroup"]) comps = dims(@"(uint)get_local_id(%d)", NO);
    else if ([role isEqualToString:@"air.threads_per_threadgroup"]) comps = dims(@"(uint)get_local_size(%d)", NO);
    else if ([role isEqualToString:@"air.threadgroup_position_in_grid"]) {
        comps = @[ @"((uint)get_group_id(0) + ts_goff.x)", @"((uint)get_group_id(1) + ts_goff.y)", @"((uint)get_group_id(2) + ts_goff.z)" ];
    }
    else if ([role isEqualToString:@"air.dispatch_threads_per_threadgroup"]) comps = dims(@"ts_tg.%c", YES);
    else if ([role isEqualToString:@"air.threads_per_grid"]) comps = dims(@"ts_grid.%c", YES);
    else if ([role isEqualToString:@"air.threadgroups_per_grid"]) comps = dims(@"ts_ngroups.%c", YES);
    NSString *index = @"(uint)(get_local_id(0) + get_local_size(0) * (get_local_id(1) + get_local_size(1) * get_local_id(2)))";
    NSString *scalar = nil;
    if ([role isEqualToString:@"air.thread_index_in_threadgroup"]) scalar = index;
    else if ([role isEqualToString:@"air.thread_execution_width"] || [role isEqualToString:@"air.threads_per_simdgroup"]) scalar = @"64u";
    else if ([role isEqualToString:@"air.simdgroup_index_in_threadgroup"]) scalar = [index stringByAppendingString:@" / 64u"];
    else if ([role isEqualToString:@"air.thread_index_in_simdgroup"]) scalar = [index stringByAppendingString:@" % 64u"];
    else if ([role isEqualToString:@"air.simdgroups_per_threadgroup"] || [role isEqualToString:@"air.dispatch_simdgroups_per_threadgroup"])
        scalar = @"(uint)((get_local_size(0) * get_local_size(1) * get_local_size(2) + 63) / 64)";
    if (!comps && !scalar) return nil;
    NSString *ct = [self ctype:t];
    if (!ct) return nil;
    unsigned n = [self lanes:t];
    NSString *lane = [self laneName:[self scalarOf:t]];
    if (scalar) return [lane isEqualToString:@"uint"] ? scalar : [NSString stringWithFormat:@"(%@)(%@)", lane, scalar];
    if (n == 1) return [lane isEqualToString:@"uint"] ? comps[0] : [NSString stringWithFormat:@"(%@)(%@)", lane, comps[0]];
    NSMutableArray *c = [NSMutableArray array];
    for (unsigned i = 0; i < n && i < 3; i++) [c addObject:[NSString stringWithFormat:@"(%@)(%@)", lane, comps[i]]];
    return [NSString stringWithFormat:@"(%@)(%@)", ct, [c componentsJoinedByString:@", "]];
}

// Blocks in reverse post-order: every definition is emitted before its uses (phis aside, which are declared
// up front). Gotos make the textual order irrelevant to what runs.
- (NSArray *)blocksOf:(LLVMValueRef)fn {
    NSMutableArray *post = [NSMutableArray array];
    NSMutableSet *seen = [NSMutableSet set];
    NSMutableArray *stack = [NSMutableArray array];   // (block, next successor index)
    LLVMBasicBlockRef entry = ts_LLVMGetFirstBasicBlock(fn);
    if (!entry) return post;
    [seen addObject:KEY(entry)];
    [stack addObject:@[KEY(entry), @0]];
    while (stack.count) {
        NSArray *top = stack.lastObject;
        LLVMBasicBlockRef b = [top[0] pointerValue];
        unsigned next = [top[1] unsignedIntValue];
        LLVMValueRef term = ts_LLVMGetBasicBlockTerminator(b);
        unsigned n = term ? ts_LLVMGetNumSuccessors(term) : 0;
        if (next < n) {
            stack[stack.count - 1] = @[top[0], @(next + 1)];
            LLVMBasicBlockRef s = ts_LLVMGetSuccessor(term, next);
            if (![seen containsObject:KEY(s)]) { [seen addObject:KEY(s)]; [stack addObject:@[KEY(s), @0]]; }
        } else {
            [post addObject:top[0]];
            [stack removeLastObject];
        }
    }
    return post.reverseObjectEnumerator.allObjects;
}

- (TSCLKernelSource *)translate {
    unsigned nk = ts_LLVMGetNamedMetadataNumOperands(_mod, "air.kernel");
    if (!nk) FAIL(@"not a kernel");
    LLVMValueRef node;
    ts_LLVMGetNamedMetadataOperands(_mod, "air.kernel", &node);
    NSArray *ops = TSCLMDOperands(node);
    _fn = TSCLOp(ops, 0);
    if (!_fn || !ts_LLVMIsAFunction(_fn)) FAIL(@"entry point not found");
    LLVMValueRef params = TSCLOp(ops, 2);
    if (![self declareParams:params ? TSCLMDOperands(params) : @[]]) return nil;
    unsigned nopts = ts_LLVMGetNamedMetadataNumOperands(_mod, "air.compile_options");
    if (nopts) {
        LLVMValueRef *opts = calloc(nopts, sizeof *opts);
        ts_LLVMGetNamedMetadataOperands(_mod, "air.compile_options", opts);
        for (unsigned i = 0; i < nopts; i++)
            for (id o in TSCLMDOperands(opts[i]))
                if ([TSCLMDString((LLVMValueRef)[o pointerValue]) isEqualToString:@"air.compile.fast_math_enable"]) _fastMath = YES;
        free(opts);
    }
    NSArray *blocks = [self blocksOf:_fn];
    // Phis first: their variables (and the _n copies) exist before any edge assigns them.
    for (NSValue *bv in blocks)
        for (LLVMValueRef i = ts_LLVMGetFirstInstruction((LLVMBasicBlockRef)bv.pointerValue); i && ts_LLVMGetInstructionOpcode(i) == LLVMPHI;
             i = ts_LLVMGetNextInstruction(i)) {
            LLVMTypeRef t = ts_LLVMTypeOf(i);
            NSString *ct = [self ctype:t];
            if (!ct) return nil;
            NSString *space = ts_LLVMGetTypeKind(t) == LLVMPointerTypeKind ? [self spaceOfAS:ts_LLVMGetPointerAddressSpace(t)] : nil;
            NSString *var = [self newVar:ct];
            [_decls appendFormat:@"  %@%@%@_n;\n", ct, [ct hasSuffix:@"*"] ? @"" : @" ", var];
            _vals[KEY(i)] = TSCLExpr(var, space);
        }
    for (NSValue *bv in blocks) {
        LLVMBasicBlockRef bb = bv.pointerValue;
        [_body appendFormat:@"%@: ;\n", [self label:bb]];
        LLVMValueRef term = ts_LLVMGetBasicBlockTerminator(bb);
        for (LLVMValueRef i = ts_LLVMGetFirstInstruction(bb); i && i != term; i = ts_LLVMGetNextInstruction(i))
            if (![self instruction:i]) { if (!_error) _error = @"translation failed"; return nil; }
        if (!term || ![self terminator:term block:bb]) { if (!_error) _error = @"bad terminator"; return nil; }
    }
    // Texture flags found in the body (B4, B5).
    TSCLArgSpec *specs = _args.mutableBytes;
    for (NSUInteger a = 0; a < _args.length / sizeof(TSCLArgSpec); a++) {
        if (specs[a].kind != TSCLArgTexture) continue;
        specs[a].nullable = [_nullSlots containsIndex:specs[a].slot];
        specs[a].lod = [_lodSlots containsIndex:specs[a].slot];
    }
    // C4: kernels that only see their grid position run as one enqueue rounded up to a work-group shape of the
    // dispatcher's choosing; the extra threads leave at once. Barriers and threadgroup memory pin the shape.
    BOOL guarded = !_shape && !_barriers && !_localArgs && !_tgStatic;
    NSMutableString *src = [NSMutableString stringWithString:@"// TeraScale Compute: translated from AIR\n"];
    [src appendString:_types];
    [src appendString:_globals];
    [src appendString:_helpers];
    [src appendFormat:@"__kernel void ts_kernel(uint4 ts_grid, uint4 ts_goff, uint4 ts_ngroups, uint4 ts_tg, uint ts_null%@) {\n", _params];
    if (guarded)
        [src appendString:@"  if (get_global_id(0) >= ts_grid.x || get_global_id(1) >= ts_grid.y || get_global_id(2) >= ts_grid.z) return;\n"];
    [src appendString:_prologue];
    [src appendString:_decls];
    [src appendString:_body];
    [src appendString:@"}\n"];
    TSCLKernelSource *k = [TSCLKernelSource new];
    k.source = src;
    k.options = _fastMath ? @"-cl-fast-relaxed-math" : @"-cl-mad-enable";
    k.args = _args;
    k.staticThreadgroupMemory = _tgStatic;
    k.barriers = _barriers;
    k.shapeSensitive = _shape;
    k.guarded = guarded;
    return k;
}

@end

#pragma mark - Public entry

static const char *kTSCLCleanupPasses =
    "inline,function(sroa,loop-unroll-full,sroa,early-cse,instcombine,dse,adce,simplifycfg,instcombine)";

static NSString *TSCLRunPasses(LLVMModuleRef mod, const char *pipeline) {
    LLVMPassBuilderOptionsRef opts = ts_LLVMCreatePassBuilderOptions();
    LLVMErrorRef err = ts_LLVMRunPasses(mod, pipeline, NULL, opts);
    ts_LLVMDisposePassBuilderOptions(opts);
    if (!err) return nil;
    char *msg = ts_LLVMGetErrorMessage(err);
    NSString *s = msg ? @(msg) : @"pass pipeline failed";
    ts_LLVMDisposeErrorMessage(msg);
    return s;
}

static TSCLKernelSource *TSCLTranslateModule(LLVMModuleRef mod, NSString **error) {
    TSCLTranslator *t = [TSCLTranslator new];
    t->_mod = mod;
    t->_td = ts_LLVMCreateTargetData(ts_LLVMGetDataLayoutStr(mod));
    t->_types = [NSMutableString string];
    t->_helpers = [NSMutableString string];
    t->_globals = [NSMutableString string];
    t->_params = [NSMutableString string];
    t->_decls = [NSMutableString string];
    t->_body = [NSMutableString string];
    t->_prologue = [NSMutableString string];
    t->_vals = [NSMutableDictionary dictionary];
    t->_typeNames = [NSMutableDictionary dictionary];
    t->_helperSet = [NSMutableSet set];
    t->_labels = [NSMutableDictionary dictionary];
    t->_args = [NSMutableData data];
    t->_nullSlots = [NSMutableIndexSet indexSet];
    t->_lodSlots = [NSMutableIndexSet indexSet];
    TSCLKernelSource *k = nil;
    @autoreleasepool { k = [t translate]; }
    if (!k && error) *error = t->_error ?: @"translation failed";
    ts_LLVMDisposeTargetData(t->_td);
    return k;
}

NSString *TSAirOpenCLTag(void) { return @"tscl-2 " __DATE__ " " __TIME__; }

TSCLKernelSource *TSAirTranslateOpenCL(NSData *bitcode, NSString **error) {
    const char *loadError = NULL;
    if (!TSLLVMLoad(&loadError)) { if (error) *error = @(loadError); return nil; }
    LLVMContextRef ctx = ts_LLVMContextCreate();
    LLVMMemoryBufferRef mb = ts_LLVMCreateMemoryBufferWithMemoryRange(bitcode.bytes, bitcode.length, "air", 0);
    LLVMModuleRef mod = NULL;
    BOOL parseFailed = ts_LLVMParseBitcodeInContext2(ctx, mb, &mod) || !mod;
    ts_LLVMDisposeMemoryBuffer(mb);
    if (parseFailed) {
        if (error) *error = @"bitcode parse failed";
        ts_LLVMContextDispose(ctx);
        return nil;
    }
    TSCLKernelSource *k = nil;
    NSString *first = nil;
    LLVMModuleRef clean = ts_LLVMCloneModule(mod);
    NSString *perr = TSCLRunPasses(clean, kTSCLCleanupPasses);
    if (!perr) k = TSCLTranslateModule(clean, &first);
    ts_LLVMDisposeModule(clean);
    if (!k) k = TSCLTranslateModule(mod, error);   // the original IR, in case the passes made something we cannot express
    if (!k && error && first) *error = first;
    ts_LLVMDisposeModule(mod);
    ts_LLVMContextDispose(ctx);
    return k;
}
