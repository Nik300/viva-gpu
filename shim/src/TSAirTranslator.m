// TeraScale Metal Shim - AIR (Metal's LLVM IR) -> GLSL 4.10 translator.
//
// Input is the per-function bitcode Metal.framework keeps in every MTLFunction; it is
// parsed with the system libLLVM. Output follows the shim shader ABI (TSMtlPipeline.m).
//
// Design:
//   - Entry arguments and outputs come from the !air.vertex / !air.fragment metadata.
//   - Kernels (!air.kernel) whose only side effect is one texture written at thread_position_in_grid
//     become fragment shaders (TeraScale Compute, GL path): gid = gl_FragCoord.xy, the write is output
//     o0, and a thread that writes nothing discards (the pipeline's wrapper tests ts_wrote). Anything a
//     fragment cannot do (device stores, atomics, barriers, threadgroup memory, other write
//     coordinates, a second written texture) fails the translation: those kernels need OpenCL.
//   - Buffer memory is never mapped to GLSL structs (std140 would not match Metal's
//     layout). Pointers into buffers are (buffer, byte offset) pairs and every load is
//     rebuilt from 32-bit words: constant buffers come from a uvec4 uniform block,
//     device buffers from a R32UI texture buffer (GL 4.1 has no SSBOs).
//   - Private memory (allocas, constant tables) becomes ordinary GLSL variables; pointers
//     into it are lvalue paths.
//   - The IR is cleaned first with the system LLVM passes (inline, sroa, unroll,
//     instcombine, simplifycfg). Control flow becomes structured GLSL (if/else, while
//     with break/continue) planned from dominators and post-dominators; phis become copies
//     on the incoming edges. CFGs the planner cannot nest are retried after LLVM's
//     structurizecfg, and only then emitted as a while/switch state machine, which is
//     correct for any graph but slow on GPUs.
//   - Integers are GLSL int (two's complement); unsigned operations cast through uint.
#import "TSPrivate.h"
#import "TSLLVM.h"
#import <dlfcn.h>

#define KEY(p) [NSValue valueWithPointer:(const void *)(p)]

#pragma mark - libLLVM loading

#define TS_LLVM_DEFINE(ret, name, args) ret (*ts_##name) args;
TS_LLVM_FUNCS(TS_LLVM_DEFINE)
#undef TS_LLVM_DEFINE

int TSLLVMLoad(const char **error) {
    static int loaded = -1;
    static const char *failure;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        const char *paths[] = {
            "/System/Library/PrivateFrameworks/GPUCompiler.framework/Versions/32023/Libraries/libLLVM.dylib",
            "/System/Library/PrivateFrameworks/GPUCompiler.framework/Libraries/libLLVM.dylib",
        };
        void *h = NULL;
        for (unsigned i = 0; i < sizeof paths / sizeof paths[0] && !h; i++) h = dlopen(paths[i], RTLD_NOW | RTLD_LOCAL);
        if (!h) { failure = "libLLVM not found"; loaded = 0; return; }
#define TS_LLVM_RESOLVE(ret, name, args) \
        if (!(ts_##name = (ret (*) args)dlsym(h, #name))) { failure = "libLLVM lacks " #name; loaded = 0; return; }
        TS_LLVM_FUNCS(TS_LLVM_RESOLVE)
#undef TS_LLVM_RESOLVE
        loaded = 1;
    });
    if (error) *error = failure;
    return loaded == 1;
}

#pragma mark - Values

// WordPtr: private memory accessed with other types or at byte offsets (type punning), kept as uint words:
// expr = the uint[] variable, cst = byte offset.
typedef enum { TSVExpr, TSVBufPtr, TSVVarPtr, TSVTexture, TSVSampler, TSVTexResult, TSVWordPtr } TSVKind;

@interface TSBuf : NSObject {
@public
    int index, addressSpace, size;
    NSString *name;     // vbuf3 / fssbo2
    BOOL wide;          // device buffer: RGBA32UI view <name>_4 declared
    BOOL pair;          // device buffer: RG32UI view <name>_2 declared
    BOOL split;         // device buffer: coalesced loads emitted, TSU_<stage><index> selects the word-by-word fallback
}
@end
@implementation TSBuf
@end

@interface TSVal : NSObject {
@public
    TSVKind kind;
    NSString *expr;         // rvalue (Expr, TexResult), lvalue path (VarPtr), dynamic offset or nil (BufPtr)
    long cst;               // constant byte offset (BufPtr)
    long align;             // BufPtr: power of two dividing the dynamic part of the offset (0 = no dynamic part)
    TSBuf *buf;
    LLVMTypeRef type;       // value type, or pointee type for pointers
    LLVMTypeRef varType;    // VarPtr: type of the variable the path started from
    int texIndex;           // Texture: Metal texture index; Sampler: Metal sampler index (-1 = constexpr / read sampler)
    NSString *texTypeName;  // Texture: air.arg_type_name
    uint64_t samplerKey;    // Sampler: constexpr state word
    BOOL readSampler;
    NSString *arrayPath;    // VarPtr to an array element: the array lvalue (expr == arrayPath[idx] elemSuffix)
    NSString *elemSuffix;   // VarPtr: ".a" when the elements are wrapped inner arrays (see -wrapperOf:), else nil
    NSString *idx;          // VarPtr: element index expression; pending phi: its int variable
    BOOL pendingPhi;        // pointer phi whose memory kind is fixed by its first incoming value
}
@end
@implementation TSVal
@end

// Alignment bookkeeping for buffer offsets: powers of two, 0 meaning "no constraint".
static long TSLowBit(long v) { return v ? (v & -v) : 0; }
static long TSMinAlign(long a, long b) { return !a ? b : !b ? a : MIN(a, b); }
// Largest power of two (up to 16) known to divide p's offset + extra.
static long TSPtrAlign(TSVal *p, long extra) {
    long a = TSMinAlign(p->expr ? (p->align ? p->align : 1) : 0, TSLowBit(p->cst + extra));
    return !a || a > 16 ? 16 : a;
}

// Largest power of two (up to 16) known to divide the integer value v, from the instructions that compute it.
// P1: Dawn indexes buffers as u32 arrays (buf[i * 20 | 1], buf[i * 20 | 2]...): with the true alignment of i * 20
// the words of one record fall in known 16-byte blocks and share one fetch.
static long TSKnownAlign(LLVMValueRef v, int depth) {
    if (ts_LLVMIsAConstantInt(v)) { long c = (long)ts_LLVMConstIntGetSExtValue(v); return c ? MIN(TSLowBit(c), 16) : 16; }
    if (depth > 8 || !ts_LLVMIsAInstruction(v)) return 1;
    LLVMOpcode op = ts_LLVMGetInstructionOpcode(v);
    switch (op) {
    case LLVMMul: return MIN(TSKnownAlign(ts_LLVMGetOperand(v, 0), depth + 1) * TSKnownAlign(ts_LLVMGetOperand(v, 1), depth + 1), 16);
    case LLVMShl: {
        LLVMValueRef k = ts_LLVMGetOperand(v, 1);
        if (!ts_LLVMIsAConstantInt(k)) return 1;
        long sh = (long)ts_LLVMConstIntGetZExtValue(k);
        return sh >= 4 ? 16 : MIN(TSKnownAlign(ts_LLVMGetOperand(v, 0), depth + 1) << sh, 16);
    }
    case LLVMAdd: case LLVMSub: case LLVMOr: case LLVMXor:
        return MIN(TSKnownAlign(ts_LLVMGetOperand(v, 0), depth + 1), TSKnownAlign(ts_LLVMGetOperand(v, 1), depth + 1));
    case LLVMAnd:
        return MAX(TSKnownAlign(ts_LLVMGetOperand(v, 0), depth + 1), TSKnownAlign(ts_LLVMGetOperand(v, 1), depth + 1));
    case LLVMSelect:
        return MIN(TSKnownAlign(ts_LLVMGetOperand(v, 1), depth + 1), TSKnownAlign(ts_LLVMGetOperand(v, 2), depth + 1));
    case LLVMSExt: case LLVMZExt: case LLVMTrunc: {
        LLVMTypeRef t = ts_LLVMTypeOf(op == LLVMTrunc ? v : ts_LLVMGetOperand(v, 0));
        return ts_LLVMGetIntTypeWidth(t) >= 8 ? TSKnownAlign(ts_LLVMGetOperand(v, 0), depth + 1) : 1;
    }
    default: return 1;
    }
}

// v = *base + *c, c constant: add/sub of a constant, or of one with no bit in common with the other operand (below
// its alignment), through extensions of 32-bit values (GLSL computes every index in 32-bit int, where all of these
// are equal modulo 2^32). Returns NO when v is already its own base (no extension, no constant part); stripping the
// extensions alone makes equal bases look equal (sext i, i).
static BOOL TSSplitConstant(LLVMValueRef v, LLVMValueRef *base, long *c) {
    long sum = 0;
    LLVMValueRef cur = v;
    for (int i = 0; i < 6 && ts_LLVMIsAInstruction(cur); i++) {
        LLVMOpcode op = ts_LLVMGetInstructionOpcode(cur);
        if (op == LLVMSExt || op == LLVMZExt) {
            if (ts_LLVMGetIntTypeWidth(ts_LLVMTypeOf(ts_LLVMGetOperand(cur, 0))) < 32) break;
            cur = ts_LLVMGetOperand(cur, 0);
            continue;
        }
        if (op != LLVMAdd && op != LLVMSub && op != LLVMOr) break;
        LLVMValueRef a = ts_LLVMGetOperand(cur, 0), b = ts_LLVMGetOperand(cur, 1);
        if (op != LLVMSub && ts_LLVMIsAConstantInt(a) && !ts_LLVMIsAConstantInt(b)) { LLVMValueRef t = a; a = b; b = t; }
        if (!ts_LLVMIsAConstantInt(b)) break;
        long k = (long)ts_LLVMConstIntGetSExtValue(b);
        if (op == LLVMOr && !(k >= 0 && k < TSKnownAlign(a, 0))) break;
        sum += op == LLVMSub ? -k : k;
        cur = a;
    }
    if (cur == v) return NO;
    *base = cur;
    *c = sum;
    return YES;
}

static TSVal *TSExpr(NSString *e, LLVMTypeRef t) { TSVal *v = [TSVal new]; v->kind = TSVExpr; v->expr = e; v->type = t; return v; }

#pragma mark - Structured control flow planning

// A plan is a tree of nodes; the translator walks it to emit GLSL. Blocks may appear more
// than once (tail duplication when two branches reach a block that is not their merge);
// every temp lives at function scope, so a duplicated block just reassigns its temps.
typedef enum { TSNBlock, TSNEdge, TSNIf, TSNLoop, TSNContinue, TSNBreak, TSNReturn } TSNodeKind;

@interface TSNode : NSObject {
@public
    TSNodeKind kind;
    LLVMBasicBlockRef bb, to;               // Block/If/Return: the block; Edge: bb -> to (phi copies)
    NSMutableArray<NSMutableArray<TSNode *> *> *arms;   // If: one sequence per distinct successor
    NSMutableArray<NSValue *> *targets;     // If: successor of each arm
    NSMutableArray<TSNode *> *body;         // Loop
}
@end
@implementation TSNode
@end

static TSNode *TSNodeMake(TSNodeKind k, LLVMBasicBlockRef bb, LLVMBasicBlockRef to) {
    TSNode *n = [TSNode new]; n->kind = k; n->bb = bb; n->to = to; return n;
}

// Plans structured code for one function. Blocks are numbered in reverse post-order, so
// on a reducible CFG every edge to a lower number is a back edge and the rest form a DAG.
// Merges are immediate post-dominators on that DAG (virtual exit = n); inside a loop a
// merge outside the loop body means "no merge" (each arm ends in break/continue/return).
@interface TSStructurer : NSObject {
@public
    int n;
    LLVMBasicBlockRef *bb;
    int **succ, *nsucc, **pred, *npred;
    int *idom, *ipdom, *exitOf;
    BOOL *terminal, *ends;             // ends: ret or unreachable
    uint8_t **body;                    // body[h]: natural loop of header h (NULL if h is no header)
    int stack[64], depth;              // active loops, innermost last
    int emitted, budget;
    BOOL returnInLoop;
}
@end

@implementation TSStructurer

- (void)dealloc {
    for (int i = 0; i < n; i++) { free(succ[i]); free(pred[i]); free(body[i]); }
    free(bb); free(succ); free(nsucc); free(pred); free(npred); free(idom); free(ipdom); free(exitOf); free(terminal); free(ends); free(body);
}

- (int)indexOf:(LLVMBasicBlockRef)b {
    for (int i = 0; i < n; i++) if (bb[i] == b) return i;
    return -1;
}

static BOOL TSDominates(const int *idom, int a, int b) {
    while (b > a) b = idom[b];
    return b == a;
}

- (instancetype)initWithBlocks:(NSArray<NSValue *> *)blocks {
    if (!(self = [super init])) return nil;
    n = (int)blocks.count;
    bb = calloc(n, sizeof *bb); succ = calloc(n, sizeof *succ); nsucc = calloc(n, sizeof *nsucc);
    pred = calloc(n, sizeof *pred); npred = calloc(n, sizeof *npred);
    idom = calloc(n, sizeof *idom); ipdom = calloc(n + 1, sizeof *ipdom); exitOf = calloc(n, sizeof *exitOf);
    terminal = calloc(n, sizeof *terminal); ends = calloc(n, sizeof *ends); body = calloc(n, sizeof *body);
    for (int i = 0; i < n; i++) { bb[i] = blocks[i].pointerValue; pred[i] = calloc(n, sizeof(int)); }
    for (int i = 0; i < n; i++) {
        LLVMValueRef term = ts_LLVMGetBasicBlockTerminator(bb[i]);
        LLVMOpcode op = term ? ts_LLVMGetInstructionOpcode(term) : LLVMUnreachable;
        ends[i] = op == LLVMRet || op == LLVMUnreachable;
        if (op != LLVMRet && op != LLVMUnreachable && op != LLVMBr && op != LLVMSwitch) return nil;
        unsigned k = ends[i] ? 0 : ts_LLVMGetNumSuccessors(term);
        succ[i] = calloc(MAX(k, 1), sizeof(int));
        for (unsigned j = 0; j < k; j++) {
            int s = [self indexOf:ts_LLVMGetSuccessor(term, j)];
            if (s < 0) return nil;
            succ[i][nsucc[i]++] = s;
        }
    }
    for (int i = 0; i < n; i++) for (int k = 0; k < nsucc[i]; k++) {
        int s = succ[i][k];
        BOOL dup = NO;
        for (int j = 0; j < npred[s]; j++) dup |= pred[s][j] == i;
        if (!dup) pred[s][npred[s]++] = i;
    }
    return self;
}

- (BOOL)analyze {
    // Dominators (Cooper, Harvey, Kennedy) over reverse post-order numbers.
    for (int i = 0; i < n; i++) idom[i] = -1;
    idom[0] = 0;
    for (BOOL changed = YES; changed;) {
        changed = NO;
        for (int b = 1; b < n; b++) {
            int nd = -1;
            for (int k = 0; k < npred[b]; k++) {
                int p = pred[b][k];
                if (idom[p] < 0) continue;
                if (nd < 0) { nd = p; continue; }
                int x = p, y = nd;
                while (x != y) { while (x > y) x = idom[x]; while (y > x) y = idom[y]; }
                nd = x;
            }
            if (nd != idom[b]) { idom[b] = nd; changed = YES; }
        }
    }
    // Back edges and natural loops; any other retreating edge means an irreducible CFG.
    for (int i = 0; i < n; i++) for (int k = 0; k < nsucc[i]; k++) {
        int h = succ[i][k];
        if (h > i) continue;
        if (!TSDominates(idom, h, i)) return NO;
        if (!body[h]) body[h] = calloc(n, 1);
        body[h][h] = 1;
        int *work = malloc(sizeof(int) * (n + 1)), top = 0;
        if (!body[h][i]) { body[h][i] = 1; work[top++] = i; }
        while (top) {
            int x = work[--top];
            for (int q = 0; q < npred[x]; q++) {
                int p = pred[x][q];
                if (!body[h][p]) { body[h][p] = 1; work[top++] = p; }
            }
        }
        free(work);
    }
    // Terminal blocks: every path ends in ret/unreachable without looping; safe to duplicate.
    for (BOOL changed = YES; changed;) {
        changed = NO;
        for (int i = n - 1; i >= 0; i--) {
            if (terminal[i]) continue;
            BOOL t = ends[i];
            if (!t && nsucc[i]) { t = YES; for (int k = 0; k < nsucc[i]; k++) if (!terminal[succ[i][k]]) t = NO; }
            if (t) { terminal[i] = YES; changed = YES; }
        }
    }
    // Loop exits: a single exit target becomes `break`; with several, at most one may be
    // non-terminal (the break target) and the terminal ones are emitted in place.
    for (int h = 0; h < n; h++) {
        exitOf[h] = -1;
        if (!body[h]) continue;
        int first = -1;
        BOOL several = NO;
        for (int i = 0; i < n; i++) if (body[h][i]) for (int k = 0; k < nsucc[i]; k++) {
            int s = succ[i][k];
            if (body[h][s]) continue;
            if (first < 0) first = s;
            else if (s != first) several = YES;
            if (terminal[s]) continue;
            if (exitOf[h] >= 0 && exitOf[h] != s) return NO;
            exitOf[h] = s;
        }
        if (!several) exitOf[h] = first;
    }
    // Post-dominators on the DAG of forward edges; DAG successors have higher numbers.
    ipdom[n] = n;
    for (int b = n - 1; b >= 0; b--) {
        int pd = -1;
        for (int k = 0; k < nsucc[b]; k++) {
            int s = succ[b][k];
            if (s <= b) continue;
            if (pd < 0) { pd = s; continue; }
            int x = s, y = pd;
            while (x != y) { while (x < y) x = ipdom[x]; while (y < x) y = ipdom[y]; }
            pd = x;
        }
        ipdom[b] = pd < 0 ? n : pd;
    }
    budget = 2 * n + 16;
    return YES;
}

// Classifies the target of an edge: -1 = control stops here (merge reached, or continue /
// break appended), -2 = not expressible (multi-level break/continue), else the block to emit.
- (int)next:(int)to follow:(int)follow into:(NSMutableArray *)out {
    if (to < 0 || to == follow) return -1;
    for (int k = depth - 1; k >= 0; k--) {
        int kind = to == stack[k] ? TSNContinue : to == exitOf[stack[k]] ? TSNBreak : -1;
        if (kind < 0) continue;
        if (k != depth - 1) return -2;
        [out addObject:TSNodeMake(kind, NULL, NULL)];
        return -1;
    }
    return to;
}

- (BOOL)seq:(NSMutableArray *)out from:(int)b follow:(int)follow skipLoop:(BOOL)skip {
    while (b >= 0 && b != follow) {
        if (body[b] && !skip) {
            if (depth >= 64) return NO;
            stack[depth++] = b;
            TSNode *loop = TSNodeMake(TSNLoop, bb[b], NULL);
            loop->body = [NSMutableArray array];
            BOOL ok = [self seq:loop->body from:b follow:-1 skipLoop:YES];
            depth--;
            if (!ok) return NO;
            [out addObject:loop];
            if ((b = [self next:exitOf[b] follow:follow into:out]) == -2) return NO;
            continue;
        }
        skip = NO;
        if (++emitted > budget) return NO;
        [out addObject:TSNodeMake(TSNBlock, bb[b], NULL)];
        if (ends[b]) {
            [out addObject:TSNodeMake(TSNReturn, bb[b], NULL)];
            if (depth) returnInLoop = YES;
            return YES;
        }
        int d[nsucc[b] + 1], nd = 0;
        for (int k = 0; k < nsucc[b]; k++) {
            BOOL seen = NO;
            for (int j = 0; j < nd; j++) seen |= d[j] == succ[b][k];
            if (!seen) d[nd++] = succ[b][k];
        }
        if (nd == 1) {
            [out addObject:TSNodeMake(TSNEdge, bb[b], bb[d[0]])];
            if ((b = [self next:d[0] follow:follow into:out]) == -2) return NO;
            continue;
        }
        int m = ipdom[b] == n ? -1 : ipdom[b];
        if (m >= 0 && depth && !body[stack[depth - 1]][m]) m = -1;
        TSNode *node = TSNodeMake(TSNIf, bb[b], NULL);
        node->arms = [NSMutableArray array];
        node->targets = [NSMutableArray array];
        for (int j = 0; j < nd; j++) {
            NSMutableArray *arm = [NSMutableArray arrayWithObject:TSNodeMake(TSNEdge, bb[b], bb[d[j]])];
            int nb = [self next:d[j] follow:m into:arm];
            if (nb == -2 || (nb >= 0 && ![self seq:arm from:nb follow:m skipLoop:NO])) return NO;
            [node->arms addObject:arm];
            [node->targets addObject:KEY(bb[d[j]])];
        }
        [out addObject:node];
        b = m;
    }
    return YES;
}
@end

#pragma mark - Translator

@interface TSAirTranslator : NSObject {
@public
    LLVMModuleRef _mod;
    LLVMTargetDataRef _td;
    LLVMValueRef _fn;
    BOOL _vertex;
    BOOL _kernel;                               // compute kernel emitted as a fragment shader
    LLVMValueRef _writeParam;                   // kernel: the texture argument it writes
    NSString *_outType;                         // kernel: GLSL type of o0
    char _sp;                                   // 'v' or 'f'
    NSMutableString *_globals, *_decls, *_body;
    NSMutableDictionary<NSValue *, TSVal *> *_vals;
    NSMutableDictionary<NSValue *, NSString *> *_structs;
    NSMutableDictionary<NSValue *, NSString *> *_wraps;   // inner array type of an array of arrays -> wrapper struct
    NSMutableDictionary<NSNumber *, TSBuf *> *_bufs;
    NSMutableSet<NSString *> *_declared;
    NSMutableArray<NSString *> *_outputs;       // per return member: GLSL target, or "" for ignored
    NSMutableDictionary<NSValue *, NSNumber *> *_blockIds;
    NSDictionary<NSString *, NSString *> *_interpolation;   // varying key -> qualifier (from the fragment shader)
    NSMutableDictionary<NSString *, NSString *> *_varyingQualifiers;
    int _temps;
    BOOL _multiBlock;
    NSString *_error;
    // Emission context of the function being emitted (the entry point or an inlined callee).
    NSString *_bbVar, *_doneVar, *_retTemp;
    BOOL _isEntry;
    int _inlineDepth;
    BOOL _calleeBreak;          // structured callee: a non-final return jumps out of do { } while (false)
    NSMutableDictionary<NSString *, NSString *> *_words;   // buffer words and offset temps already computed in the current block
@public
    BOOL _usedStateMachine;     // some function needed the while/switch fallback
    BOOL _noStruct;             // TSAirNoStructure: always emit the state machine
    BOOL _noCoalesce;           // TSAirNoCoalesce: one fetch per buffer word (P1 off)
}
@end

#define FAIL(...) do { if (!self->_error) self->_error = [NSString stringWithFormat:__VA_ARGS__]; return nil; } while (0)

static NSString *TSMDString(LLVMValueRef v) {
    if (!v) return nil;
    unsigned len = 0;
    const char *s = ts_LLVMGetMDString(v, &len);
    return s ? [[NSString alloc] initWithBytes:s length:len encoding:NSUTF8StringEncoding] : nil;
}

static NSArray *TSMDOperands(LLVMValueRef node) {
    unsigned n = ts_LLVMGetMDNodeNumOperands(node);
    LLVMValueRef *ops = calloc(MAX(n, 1), sizeof *ops);
    ts_LLVMGetMDNodeOperands(node, ops);
    NSMutableArray *a = [NSMutableArray arrayWithCapacity:n];
    for (unsigned i = 0; i < n; i++) [a addObject:KEY(ops[i])];
    free(ops);
    return a;
}

static LLVMValueRef TSOp(NSArray *ops, NSUInteger i) { return i < ops.count ? (LLVMValueRef)[ops[i] pointerValue] : NULL; }

// Strings of a metadata argument description, plus the integer following a given key.
static NSArray<NSString *> *TSMDStrings(NSArray *ops) {
    NSMutableArray *s = [NSMutableArray array];
    for (NSUInteger i = 0; i < ops.count; i++) { NSString *str = TSMDString(TSOp(ops, i)); [s addObject:str ? str : @""]; }
    return s;
}

static long TSMDIntAfter(NSArray *ops, NSString *key, long fallback) {
    for (NSUInteger i = 0; i + 1 < ops.count; i++) {
        if (![TSMDString(TSOp(ops, i)) isEqualToString:key]) continue;
        LLVMValueRef v = TSOp(ops, i + 1);
        if (v && ts_LLVMIsAConstantInt(v)) return (long)ts_LLVMConstIntGetSExtValue(v);
    }
    return fallback;
}

static NSString *TSMDStringAfter(NSArray *ops, NSString *key) {
    for (NSUInteger i = 0; i + 1 < ops.count; i++)
        if ([TSMDString(TSOp(ops, i)) isEqualToString:key]) return TSMDString(TSOp(ops, i + 1));
    return nil;
}

static NSString *TSSanitize(NSString *key) {
    NSMutableString *s = [NSMutableString stringWithString:@"v_"];
    for (NSUInteger i = 0; i < key.length; i++) {
        unichar c = [key characterAtIndex:i];
        [s appendFormat:@"%C", (unichar)(isalnum(c) ? c : '_')];
    }
    return s;
}

static NSString *TSFloatLiteral(double d) {
    if (isnan(d)) return @"uintBitsToFloat(0x7fc00000u)";
    if (isinf(d)) return d > 0 ? @"uintBitsToFloat(0x7f800000u)" : @"uintBitsToFloat(0xff800000u)";
    NSString *s = [NSString stringWithFormat:@"%.9g", d];
    if ([s rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@".e"]].location == NSNotFound)
        s = [s stringByAppendingString:@".0"];
    return s;
}

@implementation TSAirTranslator

#pragma mark Types

- (BOOL)isFloat:(LLVMTypeRef)t {
    LLVMTypeKind k = ts_LLVMGetTypeKind(t);
    if (k == LLVMVectorTypeKind) k = ts_LLVMGetTypeKind(ts_LLVMGetElementType(t));
    return k == LLVMFloatTypeKind || k == LLVMHalfTypeKind || k == LLVMDoubleTypeKind;
}

- (BOOL)isBool:(LLVMTypeRef)t {
    if (ts_LLVMGetTypeKind(t) == LLVMVectorTypeKind) t = ts_LLVMGetElementType(t);
    return ts_LLVMGetTypeKind(t) == LLVMIntegerTypeKind && ts_LLVMGetIntTypeWidth(t) == 1;
}

- (unsigned)lanes:(LLVMTypeRef)t { return ts_LLVMGetTypeKind(t) == LLVMVectorTypeKind ? ts_LLVMGetVectorSize(t) : 1; }

- (NSString *)glslType:(LLVMTypeRef)t {
    switch (ts_LLVMGetTypeKind(t)) {
    case LLVMHalfTypeKind: case LLVMFloatTypeKind: case LLVMDoubleTypeKind: return @"float";
    case LLVMIntegerTypeKind: return ts_LLVMGetIntTypeWidth(t) == 1 ? @"bool" : @"int";
    case LLVMVectorTypeKind: {
        unsigned n = ts_LLVMGetVectorSize(t);
        if (n < 2 || n > 4) FAIL(@"vector of %u elements", n);
        NSString *p = [self isFloat:t] ? @"" : [self isBool:t] ? @"b" : @"i";
        return [NSString stringWithFormat:@"%@vec%u", p, n];
    }
    case LLVMArrayTypeKind: {
        LLVMTypeRef et = ts_LLVMGetElementType(t);
        NSString *e = ts_LLVMGetTypeKind(et) == LLVMArrayTypeKind ? [self wrapperOf:et] : [self glslType:et];
        if (!e) return nil;
        return [NSString stringWithFormat:@"%@[%u]", e, ts_LLVMGetArrayLength(t)];
    }
    case LLVMStructTypeKind: {
        NSString *name = _structs[KEY(t)];
        if (name) return name;
        name = [NSString stringWithFormat:@"S%lu", (unsigned long)_structs.count];
        _structs[KEY(t)] = name;   // reserved before the members, so nested structs get their own numbers
        NSMutableString *decl = [NSMutableString stringWithFormat:@"struct %@ {", name];
        unsigned n = ts_LLVMCountStructElementTypes(t);
        for (unsigned i = 0; i < n; i++) {
            NSString *m = [self glslType:ts_LLVMStructGetTypeAtIndex(t, i)];
            if (!m) return nil;
            [decl appendFormat:@" %@ m%u;", m, i];
        }
        [decl appendString:@" };\n"];
        [_globals appendString:decl];
        return name;
    }
    default: FAIL(@"unsupported type kind %d", ts_LLVMGetTypeKind(t));
    }
}

// GLSL 4.10 has no arrays of arrays: the inner array of [N x [M x T]] becomes `struct A<k> { T a[M]; }` and the
// outer one A<k>[N]. Element paths of such arrays end in ".a", so x[i].a is still an lvalue of type T[M].
- (NSString *)wrapperOf:(LLVMTypeRef)inner {
    NSString *name = _wraps[KEY(inner)];
    if (name) return name;
    NSString *m = [self glslType:inner];
    if (!m) return nil;
    name = [NSString stringWithFormat:@"A%lu", (unsigned long)_wraps.count];
    [_globals appendFormat:@"struct %@ { %@ a; };\n", name, m];
    _wraps[KEY(inner)] = name;
    return name;
}

- (BOOL)wrapsElements:(LLVMTypeRef)t {
    return ts_LLVMGetTypeKind(t) == LLVMArrayTypeKind && ts_LLVMGetTypeKind(ts_LLVMGetElementType(t)) == LLVMArrayTypeKind;
}

// Element i of an aggregate value being built: wrapped when t is an array of arrays.
- (NSString *)element:(NSString *)e of:(LLVMTypeRef)t {
    if (!e || ![self wrapsElements:t]) return e;
    NSString *w = [self wrapperOf:ts_LLVMGetElementType(t)];
    return w ? [NSString stringWithFormat:@"%@(%@)", w, e] : nil;
}

- (NSString *)zeroOf:(LLVMTypeRef)t {
    switch (ts_LLVMGetTypeKind(t)) {
    case LLVMHalfTypeKind: case LLVMFloatTypeKind: case LLVMDoubleTypeKind: return @"0.0";
    case LLVMIntegerTypeKind: return ts_LLVMGetIntTypeWidth(t) == 1 ? @"false" : @"0";
    case LLVMVectorTypeKind: {
        NSString *ty = [self glslType:t];
        return ty ? [NSString stringWithFormat:@"%@(%@)", ty, [self zeroOf:ts_LLVMGetElementType(t)]] : nil;
    }
    case LLVMArrayTypeKind: case LLVMStructTypeKind: {
        NSString *ty = [self glslType:t];
        if (!ty) return nil;
        BOOL arr = ts_LLVMGetTypeKind(t) == LLVMArrayTypeKind;
        unsigned n = arr ? ts_LLVMGetArrayLength(t) : ts_LLVMCountStructElementTypes(t);
        NSMutableArray *parts = [NSMutableArray array];
        for (unsigned i = 0; i < n; i++) {
            NSString *z = [self element:[self zeroOf:arr ? ts_LLVMGetElementType(t) : ts_LLVMStructGetTypeAtIndex(t, i)] of:t];
            if (!z) return nil;
            [parts addObject:z];
        }
        return [NSString stringWithFormat:@"%@(%@)", ty, [parts componentsJoinedByString:@", "]];
    }
    default: FAIL(@"no zero for type kind %d", ts_LLVMGetTypeKind(t));
    }
}

// uint view of an int expression (scalar or vector).
- (NSString *)asUnsigned:(NSString *)e type:(LLVMTypeRef)t {
    unsigned n = [self lanes:t];
    return n > 1 ? [NSString stringWithFormat:@"uvec%u(%@)", n, e] : [NSString stringWithFormat:@"uint(%@)", e];
}

- (NSString *)intTypeOfLanes:(unsigned)n { return n > 1 ? [NSString stringWithFormat:@"ivec%u", n] : @"int"; }
- (NSString *)floatTypeOfLanes:(unsigned)n { return n > 1 ? [NSString stringWithFormat:@"vec%u", n] : @"float"; }

#pragma mark Constants and values

- (NSString *)constant:(LLVMValueRef)v {
    LLVMTypeRef t = ts_LLVMTypeOf(v);
    if (ts_LLVMIsUndef(v) || ts_LLVMIsPoison(v) || ts_LLVMIsAConstantAggregateZero(v) || ts_LLVMIsAConstantPointerNull(v))
        return [self zeroOf:t];
    if (ts_LLVMIsAConstantInt(v)) {
        unsigned w = ts_LLVMGetIntTypeWidth(t);
        if (w == 1) return ts_LLVMConstIntGetZExtValue(v) ? @"true" : @"false";
        long long s = ts_LLVMConstIntGetSExtValue(v);
        if (w <= 32 && s < 0 && w < 32) s = (long long)ts_LLVMConstIntGetZExtValue(v);   // i8/i16 are kept zero-extended
        if (s > INT32_MAX || s < INT32_MIN) return [NSString stringWithFormat:@"int(0x%llxu)", (unsigned long long)s & 0xffffffffull];
        return [NSString stringWithFormat:@"%lld", s];
    }
    if (ts_LLVMIsAConstantFP(v)) {
        LLVMBool lossy;
        return TSFloatLiteral(ts_LLVMConstRealGetDouble(v, &lossy));
    }
    LLVMTypeKind k = ts_LLVMGetTypeKind(t);
    if (k == LLVMVectorTypeKind || k == LLVMArrayTypeKind || k == LLVMStructTypeKind) {
        NSString *ty = [self glslType:t];
        if (!ty) return nil;
        unsigned n = k == LLVMVectorTypeKind ? ts_LLVMGetVectorSize(t) : k == LLVMArrayTypeKind ? ts_LLVMGetArrayLength(t)
                                                                                                : ts_LLVMCountStructElementTypes(t);
        BOOL sequential = ts_LLVMIsAConstantDataSequential(v) != NULL;
        NSMutableArray *parts = [NSMutableArray array];
        for (unsigned i = 0; i < n; i++) {
            LLVMValueRef e = sequential ? ts_LLVMGetElementAsConstant(v, i) : ts_LLVMGetOperand(v, i);
            NSString *s = [self element:[self constant:e] of:t];
            if (!s) return nil;
            [parts addObject:s];
        }
        return [NSString stringWithFormat:@"%@(%@)", ty, [parts componentsJoinedByString:@", "]];
    }
    char *p = ts_LLVMPrintValueToString(v);
    NSString *desc = @(p);
    ts_LLVMDisposeMessage(p);
    FAIL(@"unsupported constant %@", desc);
}

- (TSVal *)value:(LLVMValueRef)v {
    TSVal *known = _vals[KEY(v)];
    if (known) return known;
    if (ts_LLVMIsAConstantExpr(v)) {
        LLVMOpcode op = ts_LLVMGetConstOpcode(v);
        if (op == LLVMBitCast || op == LLVMAddrSpaceCast) {
            TSVal *inner = [self value:ts_LLVMGetOperand(v, 0)];
            if (!inner) return nil;
            if (inner->kind == TSVSampler || inner->kind == TSVTexture) return inner;
            if (inner->kind == TSVBufPtr || inner->kind == TSVVarPtr) {
                TSVal *c = [self copyPointer:inner];
                c->type = ts_LLVMGetElementType(ts_LLVMTypeOf(v));
                return c;
            }
        }
        if (op == LLVMGetElementPtr) FAIL(@"constant GEP expressions are not supported yet");
        FAIL(@"unsupported constant expression (opcode %d)", op);
    }
    if (ts_LLVMIsAGlobalVariable(v)) return [self global:v];
    if (ts_LLVMIsAConstant(v)) {
        NSString *c = [self constant:v];
        return c ? TSExpr(c, ts_LLVMTypeOf(v)) : nil;
    }
    FAIL(@"value used before definition");
}

- (NSString *)expr:(LLVMValueRef)v {
    TSVal *val = [self value:v];
    if (!val) return nil;
    if (val->kind != TSVExpr && val->kind != TSVTexResult) FAIL(@"pointer or handle used as a value");
    return val->expr;
}

- (TSVal *)copyPointer:(TSVal *)p {
    TSVal *c = [TSVal new];
    c->kind = p->kind; c->expr = p->expr; c->cst = p->cst; c->align = p->align; c->buf = p->buf; c->type = p->type; c->varType = p->varType;
    c->arrayPath = p->arrayPath; c->idx = p->idx; c->elemSuffix = p->elemSuffix;
    return c;
}

// Module-level globals: constexpr samplers and constant tables.
- (TSVal *)global:(LLVMValueRef)g {
    size_t len;
    const char *name = ts_LLVMGetValueName2(g, &len);
    LLVMValueRef init = ts_LLVMGetInitializer(g);
    LLVMTypeRef t = ts_LLVMGetElementType(ts_LLVMTypeOf(g));
    if (name && !strncmp(name, "__air_sampler_state", 19)) {
        TSVal *s = [TSVal new];
        s->kind = TSVSampler;
        s->texIndex = -1;
        LLVMValueRef word = init ? (ts_LLVMIsAConstantDataSequential(init) ? ts_LLVMGetElementAsConstant(init, 0) : ts_LLVMGetOperand(init, 0)) : NULL;
        s->samplerKey = word ? ts_LLVMConstIntGetZExtValue(word) : 0;
        _vals[KEY(g)] = s;
        return s;
    }
    if (_kernel && ts_LLVMGetPointerAddressSpace(ts_LLVMTypeOf(g)) == 3) FAIL(@"kernel uses threadgroup memory");
    if (!init) FAIL(@"global %s without initializer", name);
    NSString *ty = [self glslType:t], *c = [self constant:init];
    if (!ty || !c) return nil;
    NSString *var = [NSString stringWithFormat:@"g%lu", (unsigned long)_vals.count];
    [_globals appendFormat:@"const %@ %@ = %@;\n", ty, var, c];
    TSVal *p = [TSVal new];
    p->kind = TSVVarPtr; p->expr = var; p->type = t; p->varType = t;
    _vals[KEY(g)] = p;
    return p;
}

- (NSString *)newTemp:(LLVMTypeRef)t {
    NSString *ty = [self glslType:t];
    if (!ty) return nil;
    NSString *name = [NSString stringWithFormat:@"t%d", _temps++];
    [_decls appendFormat:@"  %@ %@;\n", ty, name];
    return name;
}

// Same, with a second form of the expression for the program variant where the texture slot is a
// GL_TEXTURE_RECTANGLE (an IOSurface sampled in place, see -rectSlotFor:). `slot` nil = one form only.
- (TSVal *)define:(LLVMValueRef)inst expr:(NSString *)e rect:(NSString *)rectExpr slot:(NSString *)slot {
    if (!slot || !rectExpr) return [self define:inst expr:e];
    if (!e) return nil;
    LLVMTypeRef t = ts_LLVMTypeOf(inst);
    NSString *tmp = [self newTemp:t];
    if (!tmp) return nil;
    [_body appendFormat:@"#if %@\n  %@ = %@;\n#else\n  %@ = %@;\n#endif\n", slot, tmp, rectExpr, tmp, e];
    TSVal *v = TSExpr(tmp, t);
    _vals[KEY(inst)] = v;
    return v;
}

// Assigns an expression to a fresh temp and records it as the value of the instruction.
- (TSVal *)define:(LLVMValueRef)inst expr:(NSString *)e {
    if (!e) return nil;
    LLVMTypeRef t = ts_LLVMTypeOf(inst);
    NSString *tmp = [self newTemp:t];
    if (!tmp) return nil;
    [_body appendFormat:@"  %@ = %@;\n", tmp, e];
    TSVal *v = TSExpr(tmp, t);
    _vals[KEY(inst)] = v;
    return v;
}

#pragma mark Buffer loads

- (NSString *)offsetExpr:(TSVal *)p plus:(long)extra {
    long c = p->cst + extra;
    if (!p->expr) return [NSString stringWithFormat:@"%ld", c];
    return c ? [NSString stringWithFormat:@"(%@ + %ld)", p->expr, c] : p->expr;
}

- (NSString *)word:(TSBuf *)b offset:(NSString *)o { return [NSString stringWithFormat:@"ts_ld_%@(%@)", b->name, o]; }

// 32-bit word containing byte offset p + extra (whose low two bits are dropped when the
// dynamic part is word-aligned). Constant offsets into constant buffers become static
// component reads; other words are fetched once per basic block and reused (A3), and words
// of the same 16-byte block share one fetch (P1, -blockWord:).
- (NSString *)wordAt:(TSVal *)p extra:(long)extra {
    TSBuf *b = p->buf;
    long c = (p->cst + extra) & ~3L;
    if (!p->expr && b->addressSpace == 2) return [NSString stringWithFormat:@"%@_d[%ld].%c", b->name, c >> 4, "xyzw"[(c >> 2) & 3]];
    NSString *key = [NSString stringWithFormat:@"%@|%@|%ld", b->name, p->expr ?: @"", c];
    NSString *w = _words[key];
    if (w) return w;
    NSString *fetch = [self word:b offset:p->expr ? (c ? [NSString stringWithFormat:@"(%@ + %ld)", p->expr, c] : p->expr)
                                                  : [NSString stringWithFormat:@"%ld", c]];
    NSString *block = [self blockWord:p at:c];
    if (block && b->addressSpace == 2) w = block;   // a component of a uvec4 already in a temp
    else {
        w = [NSString stringWithFormat:@"w%d", _temps++];
        [_decls appendFormat:@"  uint %@;\n", w];
        if (block) [_body appendFormat:@"#if TSU_%c%d\n  %@ = %@;\n#else\n  %@ = %@;\n#endif\n", _sp, b->index, w, fetch, w, block];
        else [_body appendFormat:@"  %@ = %@;\n", w, fetch];
    }
    _words[key] = w;
    return w;
}

// P1 (docs/OTTIMIZZAZIONE-AIR.md §4.1): the word at byte c of p as a component of the 16-byte block (8-byte
// pair when the dynamic part is only 8-aligned) holding it, fetched once per basic block; nil = no such block.
// The driver's deferred compile grows superlinearly with the number of fetches (13-50x measured). Constant
// buffers: the uniform block element, always aligned (unaligned bindings are copied, TSMtlRender.m); a pair is
// its .xy or .zw, picked by bit 3 of the offset instead of indexing the components (B7: constant half4). Device buffers: the RGBA32UI / RG32UI views, which
// index from the start of the buffer, so the binding offset must be a multiple of 16; Metal only promises 4
// for scalar loads, so the word-by-word form stays under TSU_<stage><index> and the pipeline links that
// variant when a binding is not 16-aligned (-[TSMtlRenderPipelineState programForRectMask:]).
- (NSString *)blockWord:(TSVal *)p at:(long)c {
    TSBuf *b = p->buf;
    if (_noCoalesce) return nil;
    long a = !p->expr ? 16 : p->align ? MIN(p->align, 16) : 1;
    int span = a >= 16 ? 16 : a == 8 ? 8 : 0;
    if (!span) return nil;
    long base = c & ~(long)(span - 1);
    NSString *key = [NSString stringWithFormat:@"blk|%@|%@|%ld", b->name, p->expr ?: @"", base];
    NSString *q = _words[key];
    if (!q) {
        NSString *o = !p->expr ? [NSString stringWithFormat:@"%ld", base] : base ? [NSString stringWithFormat:@"(%@ + %ld)", p->expr, base] : p->expr;
        q = [NSString stringWithFormat:@"q%d", _temps++];
        [_decls appendFormat:@"  %@ %@;\n", span == 16 ? @"uvec4" : @"uvec2", q];
        if (b->addressSpace == 2 && span == 16) [_body appendFormat:@"  %@ = %@_d[%@ >> 4];\n", q, b->name, o];
        else if (b->addressSpace == 2) {
            NSString *e = [NSString stringWithFormat:@"q%d", _temps++];
            [_decls appendFormat:@"  uvec4 %@;\n", e];
            [_body appendFormat:@"  %@ = %@_d[%@ >> 4];\n  %@ = (%@ & 8) != 0 ? %@.zw : %@.xy;\n", e, b->name, o, q, o, e, e];
        } else {
            if (!b->split) {
                b->split = YES;
                [_globals appendFormat:@"#ifndef TSU_%c%d\n#define TSU_%c%d 0\n#endif\n", _sp, b->index, _sp, b->index];
            }
            NSString *view = span == 16 ? [self wideView:b] : [self pairView:b];
            [_body appendFormat:@"#if !TSU_%c%d\n  %@ = texelFetch(%@, (%@_off + %@) >> %d)%@;\n#endif\n", _sp, b->index, q, view, b->name, o,
                                span == 16 ? 4 : 3, span == 16 ? @"" : @".xy"];
        }
        _words[key] = q;
    }
    return [NSString stringWithFormat:@"%@.%c", q, "xyzw"[(c - base) >> 2]];
}

- (NSString *)wideView:(TSBuf *)b {
    if (!b->wide) {
        b->wide = YES;
        [_globals appendFormat:@"uniform usamplerBuffer %@_4;\n", b->name];
    }
    return [b->name stringByAppendingString:@"_4"];
}

- (NSString *)pairView:(TSBuf *)b {
    if (!b->pair) {
        b->pair = YES;
        [_globals appendFormat:@"uniform usamplerBuffer %@_2;\n", b->name];
    }
    return [b->name stringByAppendingString:@"_2"];
}

// uvec4 at a 16-byte aligned offset: one fetch instead of four (constant buffers: the block
// element itself; device buffers: the RGBA32UI view, legal because Metal requires binding
// offsets aligned to the type read, up to 16 bytes).
- (NSString *)vec4At:(TSVal *)p extra:(long)extra {
    TSBuf *b = p->buf;
    long c = p->cst + extra;
    NSString *o = !p->expr ? [NSString stringWithFormat:@"%ld", c] : c ? [NSString stringWithFormat:@"(%@ + %ld)", p->expr, c] : p->expr;
    if (b->addressSpace == 2) return [NSString stringWithFormat:@"%@_d[%@ >> 4]", b->name, o];
    return [NSString stringWithFormat:@"texelFetch(%@, (%@_off + %@) >> 4)", [self wideView:b], b->name, o];
}

- (NSString *)load:(TSVal *)p type:(LLVMTypeRef)t extra:(long)extra {
    NSString *o = [self offsetExpr:p plus:extra];
    TSBuf *b = p->buf;
    long align = TSPtrAlign(p, extra);
    LLVMTypeKind k = ts_LLVMGetTypeKind(t);
    if (k == LLVMVectorTypeKind && ts_LLVMGetVectorSize(t) == 4 && align >= 16) {
        LLVMTypeRef et = ts_LLVMGetElementType(t);
        LLVMTypeKind ek = ts_LLVMGetTypeKind(et);
        if (ek == LLVMFloatTypeKind) return [NSString stringWithFormat:@"uintBitsToFloat(%@)", [self vec4At:p extra:extra]];
        if (ek == LLVMIntegerTypeKind && ts_LLVMGetIntTypeWidth(et) == 32) return [NSString stringWithFormat:@"ivec4(%@)", [self vec4At:p extra:extra]];
    }
    // Word-aligned dynamic part: the byte position inside the word is a compile-time constant.
    BOOL wordAligned = align >= 4 || (!p->expr) || (p->align && p->align >= 4);
    switch (k) {
    case LLVMFloatTypeKind:
        return [NSString stringWithFormat:@"uintBitsToFloat(%@)", align >= 4 ? [self wordAt:p extra:extra] : [self word:b offset:o]];
    case LLVMHalfTypeKind:
        [self needHalf];
        if (wordAligned) return [NSString stringWithFormat:@"ts_h2f((%@ >> %ldu) & 0xFFFFu)", [self wordAt:p extra:extra], ((p->cst + extra) & 2) * 8];
        return [NSString stringWithFormat:@"ts_h2f((%@ >> uint((%@ & 2) * 8)) & 0xFFFFu)", [self word:b offset:o], o];
    case LLVMIntegerTypeKind: {
        unsigned w = ts_LLVMGetIntTypeWidth(t);
        if (w >= 32) return [NSString stringWithFormat:@"int(%@)", align >= 4 ? [self wordAt:p extra:extra] : [self word:b offset:o]];
        NSString *bits = wordAligned
            ? [NSString stringWithFormat:@"((%@ >> %ldu) & %@)", [self wordAt:p extra:extra], ((p->cst + extra) & 3) * 8, w == 16 ? @"0xFFFFu" : @"0xFFu"]
            : [NSString stringWithFormat:@"((%@ >> uint((%@ & 3) * 8)) & %@)", [self word:b offset:o], o, w == 16 ? @"0xFFFFu" : @"0xFFu"];
        return w == 1 ? [NSString stringWithFormat:@"(%@ != 0u)", bits] : [NSString stringWithFormat:@"int(%@)", bits];
    }
    case LLVMVectorTypeKind: case LLVMArrayTypeKind: case LLVMStructTypeKind: {
        NSString *ty = [self glslType:t];
        if (!ty) return nil;
        unsigned n = k == LLVMVectorTypeKind ? ts_LLVMGetVectorSize(t) : k == LLVMArrayTypeKind ? ts_LLVMGetArrayLength(t)
                                                                       : ts_LLVMCountStructElementTypes(t);
        NSMutableArray *parts = [NSMutableArray array];
        for (unsigned i = 0; i < n; i++) {
            LLVMTypeRef et = k == LLVMStructTypeKind ? ts_LLVMStructGetTypeAtIndex(t, i) : ts_LLVMGetElementType(t);
            long off = k == LLVMStructTypeKind ? (long)ts_LLVMOffsetOfElement(_td, t, i) : (long)(i * ts_LLVMABISizeOfType(_td, et));
            if (k == LLVMVectorTypeKind) off = (long)(i * ts_LLVMStoreSizeOfType(_td, et));
            NSString *e = [self element:[self load:p type:et extra:extra + off] of:t];
            if (!e) return nil;
            [parts addObject:e];
        }
        return [NSString stringWithFormat:@"%@(%@)", ty, [parts componentsJoinedByString:@", "]];
    }
    default: FAIL(@"cannot load type kind %d from a buffer", ts_LLVMGetTypeKind(t));
    }
}

- (void)needHalf {
    if ([_declared containsObject:@"ts_h2f"]) return;
    [_declared addObject:@"ts_h2f"];
    // GLSL 4.10 has no unpackHalf2x16. Shift the exponent and mantissa into float position and
    // rescale by 2^112; inf/NaN (exponent all ones) get the float exponent by an add instead and
    // keep their payload; the sign comes from a negation, which only flips the sign bit (NaN too).
    // 1.42 -> 1.19 ms on bench/gpubench [5] against masking and OR-ing (B7). Half denormals land
    // on float denormals, which the GPU flushes to zero.
    [_globals appendString:@"float ts_h2f(uint h) {\n"
     "  uint u = (h & 0x7FFFu) << 13;\n"
     "  float f = u >= 0x0F800000u ? uintBitsToFloat(u + 0x70000000u) : uintBitsToFloat(u) * uintBitsToFloat(0x77800000u);\n"
     "  return (h & 0x8000u) != 0u ? -f : f;\n}\n"];
}

- (void)needHalfEncode {
    if ([_declared containsObject:@"ts_f2h"]) return;
    [_declared addObject:@"ts_f2h"];
    // GLSL 4.10 has no packHalf2x16: float -> half bits, round to nearest even, overflow to inf,
    // NaN stays NaN, results below the half range become half denormals or signed zero.
    [_globals appendString:@"uint ts_f2h(float f) {\n"
     "  uint x = floatBitsToUint(f), s = (x >> 16) & 0x8000u, e = (x >> 23) & 0xFFu, m = x & 0x7FFFFFu;\n"
     "  if (e == 0xFFu) return s | 0x7C00u | (m != 0u ? 0x200u | (m >> 13) : 0u);\n"
     "  int ne = int(e) - 112;\n"
     "  if (ne >= 31) return s | 0x7C00u;\n"
     "  if (ne <= 0) {\n"
     "    if (ne < -10) return s;\n"
     "    m |= 0x800000u;\n"
     "    uint sh = uint(14 - ne), hm = m >> sh, rem = m & ((1u << sh) - 1u), hf = 1u << (sh - 1u);\n"
     "    return s | (hm + ((rem > hf || (rem == hf && (hm & 1u) != 0u)) ? 1u : 0u));\n"
     "  }\n"
     "  uint h = s | (uint(ne) << 10) | (m >> 13), rem = m & 0x1FFFu;\n"
     "  return h + ((rem > 0x1000u || (rem == 0x1000u && (h & 1u) != 0u)) ? 1u : 0u);\n}\n"];
}

#pragma mark Entry interface

- (BOOL)declareInputs:(NSArray *)inputs {
    unsigned nparams = ts_LLVMCountParams(_fn);
    for (id entry in inputs) {
        NSArray *ops = TSMDOperands((LLVMValueRef)[entry pointerValue]);
        LLVMValueRef idxv = TSOp(ops, 0);
        if (!idxv || !ts_LLVMIsAConstantInt(idxv)) { _error = @"malformed input metadata"; return NO; }
        unsigned idx = (unsigned)ts_LLVMConstIntGetZExtValue(idxv);
        if (idx >= nparams) continue;
        LLVMValueRef param = ts_LLVMGetParam(_fn, idx);
        LLVMTypeRef pt = ts_LLVMTypeOf(param);
        NSArray<NSString *> *strs = TSMDStrings(ops);
        NSString *role = strs.count > 1 ? strs[1] : @"";
        TSVal *v = nil;
        if ([role isEqualToString:@"air.vertex_input"]) {
            long loc = TSMDIntAfter(ops, @"air.location_index", idx);
            NSString *ty = [self glslType:pt];
            if (!ty) return NO;
            [_globals appendFormat:@"layout(location = %ld) in %@ a%ld;\n", loc, ty, loc];
            v = TSExpr([NSString stringWithFormat:@"a%ld", loc], pt);
        } else if ([role isEqualToString:@"air.vertex_id"]) {
            v = TSExpr(@"gl_VertexID", pt);
        } else if ([role isEqualToString:@"air.instance_id"]) {
            [self needUniform:@"uniform int ts_base_instance;\n"];
            v = TSExpr(@"(gl_InstanceID + ts_base_instance)", pt);
        } else if ([role isEqualToString:@"air.base_instance"]) {
            [self needUniform:@"uniform int ts_base_instance;\n"];
            v = TSExpr(@"ts_base_instance", pt);
        } else if ([role isEqualToString:@"air.base_vertex"]) {
            [self needUniform:@"uniform int ts_base_vertex;\n"];
            v = TSExpr(@"ts_base_vertex", pt);
        } else if ([role isEqualToString:@"air.fragment_input"]) {
            NSString *key = strs.count > 2 ? strs[2] : @"";
            NSString *ty = [self glslType:pt];
            if (!ty) return NO;
            NSMutableString *q = [NSMutableString string];
            if ([strs containsObject:@"air.flat"] || ![self isFloat:pt]) [q appendString:@"flat "];
            else if ([strs containsObject:@"air.no_perspective"]) [q appendString:@"noperspective "];
            if ([strs containsObject:@"air.centroid"]) [q appendString:@"centroid "];
            else if ([strs containsObject:@"air.sample"]) [q appendString:@"sample "];
            NSString *name = TSSanitize(key);
            _varyingQualifiers[key] = q;
            [_globals appendFormat:@"%@in %@ %@;\n", q, ty, name];
            v = TSExpr(name, pt);
        } else if ([role isEqualToString:@"air.position"]) {
            v = TSExpr(@"gl_FragCoord", pt);
        } else if ([role isEqualToString:@"air.front_facing"]) {
            v = TSExpr(@"gl_FrontFacing", pt);
        } else if ([role isEqualToString:@"air.point_coord"]) {
            v = TSExpr(@"gl_PointCoord", pt);
        } else if ([role isEqualToString:@"air.sample_id"]) {
            v = TSExpr(@"gl_SampleID", pt);
        } else if ([role isEqualToString:@"air.buffer"]) {
            TSBuf *b = [TSBuf new];
            b->index = (int)TSMDIntAfter(ops, @"air.location_index", 0);
            b->addressSpace = (int)TSMDIntAfter(ops, @"air.address_space", ts_LLVMGetPointerAddressSpace(pt));
            b->size = (int)TSMDIntAfter(ops, @"air.buffer_size", 0);
            [self declareBuffer:b];
            v = [TSVal new];
            v->kind = TSVBufPtr; v->buf = b; v->type = ts_LLVMGetElementType(pt);
        } else if ([role isEqualToString:@"air.texture"]) {
            v = [TSVal new];
            v->kind = TSVTexture;
            v->texIndex = (int)TSMDIntAfter(ops, @"air.location_index", 0);
            v->texTypeName = TSMDStringAfter(ops, @"air.arg_type_name");
        } else if ([role isEqualToString:@"air.sampler"]) {
            v = [TSVal new];
            v->kind = TSVSampler;
            v->texIndex = (int)TSMDIntAfter(ops, @"air.location_index", 0);
        } else if (_kernel && (v = [self kernelBuiltin:role type:pt])) {
        } else {
            _error = [NSString stringWithFormat:@"unsupported input %@", role];
            return NO;
        }
        _vals[KEY(param)] = v;
    }
    return YES;
}

- (void)needUniform:(NSString *)decl {
    if ([_declared containsObject:decl]) return;
    [_declared addObject:decl];
    [_globals appendString:decl];
}

- (void)declareBuffer:(TSBuf *)b {
    if (b->addressSpace == 2) {
        // Constant buffer -> uniform block of raw words sized from the metadata (64 KB when unknown).
        b->name = [NSString stringWithFormat:@"%cbuf%d", _sp, b->index];
        int vecs = b->size > 0 ? (b->size + 15) / 16 : 4096;
        [_globals appendFormat:@"uniform %@ { uvec4 %@_d[%d]; };\n", b->name, b->name, MIN(vecs, 4096)];
        [_globals appendFormat:@"uint ts_ld_%@(int o) { return %@_d[o >> 4][(o >> 2) & 3]; }\n", b->name, b->name];
    } else {
        // Device buffer -> read-only R32UI texture buffer; the bound offset arrives in <name>_off.
        b->name = [NSString stringWithFormat:@"%cssbo%d", _sp, b->index];
        [_globals appendFormat:@"uniform usamplerBuffer %@; uniform int %@_off;\n", b->name, b->name];
        [_globals appendFormat:@"uint ts_ld_%@(int o) { return texelFetch(%@, (%@_off + o) >> 2).r; }\n", b->name, b->name, b->name];
    }
}

- (BOOL)declareOutputs:(NSArray *)outputs {
    _outputs = [NSMutableArray array];
    for (id entry in outputs) {
        NSArray *ops = TSMDOperands((LLVMValueRef)[entry pointerValue]);
        NSArray<NSString *> *strs = TSMDStrings(ops);
        NSString *role = strs.count ? strs[0] : @"";
        NSString *typeName = TSMDStringAfter(ops, @"air.arg_type_name");
        NSUInteger member = _outputs.count;
        LLVMTypeRef mt = [self returnMemberType:member];
        if (!mt) { _error = @"return type does not match the output metadata"; return NO; }
        NSString *ty = [self glslType:mt];
        if (!ty) return NO;
        if ([role isEqualToString:@"air.position"]) {
            [_outputs addObject:@"gl_Position"];
        } else if ([role isEqualToString:@"air.vertex_output"]) {
            NSString *key = strs.count > 1 ? strs[1] : @"";
            NSString *q = _interpolation[key] ?: (![self isFloat:mt] ? @"flat " : @"");
            NSString *name = TSSanitize(key);
            [_globals appendFormat:@"%@out %@ %@;\n", q, ty, name];
            [_outputs addObject:name];
        } else if ([role isEqualToString:@"air.point_size"]) {
            [_outputs addObject:@"gl_PointSize"];
        } else if ([role isEqualToString:@"air.render_target"]) {
            LLVMValueRef iv = TSOp(ops, 1);
            long idx = iv && ts_LLVMIsAConstantInt(iv) ? (long)ts_LLVMConstIntGetZExtValue(iv) : 0;
            NSString *outTy = ty;
            if (![self isFloat:mt] && [typeName hasPrefix:@"uint"]) outTy = [ty stringByReplacingOccurrencesOfString:@"ivec" withString:@"uvec"];
            if ([outTy isEqualToString:@"int"] && [typeName hasPrefix:@"uint"]) outTy = @"uint";
            // Dual-source blending: [[color(0), index(1)]] is the second operand after the location.
            LLVMValueRef bv = TSOp(ops, 2);
            long blendIndex = bv && ts_LLVMIsAConstantInt(bv) ? (long)ts_LLVMConstIntGetZExtValue(bv) : 0;
            NSString *oname = blendIndex ? [NSString stringWithFormat:@"o%ld_%ld", idx, blendIndex] : [NSString stringWithFormat:@"o%ld", idx];
            if (blendIndex) [_globals appendFormat:@"layout(location = %ld, index = %ld) out %@ %@;\n", idx, blendIndex, outTy, oname];
            else [_globals appendFormat:@"layout(location = %ld) out %@ %@;\n", idx, outTy, oname];
            [_outputs addObject:[NSString stringWithFormat:@"%@%@", [outTy isEqualToString:ty] ? @"" : [NSString stringWithFormat:@"#%@#", outTy], oname]];
        } else if ([role isEqualToString:@"air.depth"]) {
            [_outputs addObject:@"gl_FragDepth"];
        } else if ([role isEqualToString:@"air.sample_mask"]) {
            [_outputs addObject:@"gl_SampleMask[0]"];
        } else if ([role isEqualToString:@"air.clip_distance"]) {
            [_outputs addObject:@""];   // not supported, dropped
        } else {
            _error = [NSString stringWithFormat:@"unsupported output %@", role];
            return NO;
        }
    }
    return YES;
}

- (LLVMTypeRef)returnType {
    // LLVMTypeOf(function) is a pointer to the function type; the return type is the element of
    // that function type, reachable through the first instruction-independent route: a ret.
    for (LLVMBasicBlockRef bb = ts_LLVMGetFirstBasicBlock(_fn); bb; bb = ts_LLVMGetNextBasicBlock(bb)) {
        LLVMValueRef term = ts_LLVMGetBasicBlockTerminator(bb);
        if (term && ts_LLVMGetInstructionOpcode(term) == LLVMRet && ts_LLVMGetNumOperands(term) > 0)
            return ts_LLVMTypeOf(ts_LLVMGetOperand(term, 0));
    }
    return NULL;
}

- (LLVMTypeRef)returnMemberType:(NSUInteger)i {
    LLVMTypeRef rt = [self returnType];
    if (!rt) return NULL;
    if (ts_LLVMGetTypeKind(rt) == LLVMStructTypeKind) return i < ts_LLVMCountStructElementTypes(rt) ? ts_LLVMStructGetTypeAtIndex(rt, (unsigned)i) : NULL;
    return i == 0 ? rt : NULL;
}

- (NSString *)emitReturn:(LLVMValueRef)term {
    if (ts_LLVMGetNumOperands(term) == 0) return @"";
    LLVMValueRef rv = ts_LLVMGetOperand(term, 0);
    LLVMTypeRef rt = ts_LLVMTypeOf(rv);
    BOOL aggregate = ts_LLVMGetTypeKind(rt) == LLVMStructTypeKind;
    NSString *e = [self expr:rv];
    if (!e) return nil;
    NSMutableString *s = [NSMutableString string];
    for (NSUInteger i = 0; i < _outputs.count; i++) {
        NSString *target = _outputs[i];
        if (!target.length) continue;
        NSString *val = aggregate ? [NSString stringWithFormat:@"%@.m%lu", e, (unsigned long)i] : e;
        if ([target hasPrefix:@"#"]) {   // output declared with a different integer signedness
            NSArray *p = [target componentsSeparatedByString:@"#"];
            target = p[2];
            val = [NSString stringWithFormat:@"%@(%@)", p[1], val];
        }
        if ([target isEqualToString:@"gl_SampleMask[0]"]) val = [NSString stringWithFormat:@"int(%@)", val];
        [s appendFormat:@"  %@ = %@;\n", target, val];
    }
    return s;
}

#pragma mark Instructions

- (TSVal *)binary:(LLVMValueRef)inst op:(LLVMOpcode)op {
    LLVMValueRef a = ts_LLVMGetOperand(inst, 0), b = ts_LLVMGetOperand(inst, 1);
    LLVMTypeRef t = ts_LLVMTypeOf(inst);
    NSString *x = [self expr:a], *y = [self expr:b];
    if (!x || !y) return nil;
    unsigned n = [self lanes:t];
    NSString *e = nil;
    if ([self isBool:t] && (op == LLVMAnd || op == LLVMOr || op == LLVMXor)) {
        if (n == 1) e = [NSString stringWithFormat:@"(%@ %@ %@)", x, op == LLVMAnd ? @"&&" : op == LLVMOr ? @"||" : @"^^", y];
        else e = [NSString stringWithFormat:@"notEqual(uvec%u(%@) %@ uvec%u(%@), uvec%u(0))", n, x, op == LLVMAnd ? @"&" : op == LLVMOr ? @"|" : @"^", n, y, n];
        return [self define:inst expr:e];
    }
    switch (op) {
    case LLVMFAdd: case LLVMAdd: e = [NSString stringWithFormat:@"(%@ + %@)", x, y]; break;
    case LLVMFSub: case LLVMSub: e = [NSString stringWithFormat:@"(%@ - %@)", x, y]; break;
    case LLVMFMul: case LLVMMul: e = [NSString stringWithFormat:@"(%@ * %@)", x, y]; break;
    case LLVMFDiv: case LLVMSDiv: e = [NSString stringWithFormat:@"(%@ / %@)", x, y]; break;
    case LLVMFRem: e = [NSString stringWithFormat:@"(%@ - %@ * trunc(%@ / %@))", x, y, x, y]; break;
    case LLVMSRem: e = [NSString stringWithFormat:@"(%@ - %@ * (%@ / %@))", x, y, x, y]; break;
    case LLVMUDiv: e = [NSString stringWithFormat:@"%@(%@ / %@)", [self intTypeOfLanes:n], [self asUnsigned:x type:t], [self asUnsigned:y type:t]]; break;
    case LLVMURem: e = [NSString stringWithFormat:@"%@(%@ %% %@)", [self intTypeOfLanes:n], [self asUnsigned:x type:t], [self asUnsigned:y type:t]]; break;
    case LLVMShl: e = [NSString stringWithFormat:@"(%@ << %@)", x, y]; break;
    case LLVMAShr: e = [NSString stringWithFormat:@"(%@ >> %@)", x, y]; break;
    case LLVMLShr: e = [NSString stringWithFormat:@"%@(%@ >> %@)", [self intTypeOfLanes:n], [self asUnsigned:x type:t], [self asUnsigned:y type:t]]; break;
    case LLVMAnd: e = [NSString stringWithFormat:@"(%@ & %@)", x, y]; break;
    case LLVMOr: e = [NSString stringWithFormat:@"(%@ | %@)", x, y]; break;
    case LLVMXor: e = [NSString stringWithFormat:@"(%@ ^ %@)", x, y]; break;
    default: FAIL(@"binary opcode %d", op);
    }
    return [self define:inst expr:e];
}

// Pointer comparison: same array (element indices) or same buffer (byte offsets).
- (TSVal *)comparePointers:(LLVMValueRef)inst {
    TSVal *a = [self value:ts_LLVMGetOperand(inst, 0)], *b = [self value:ts_LLVMGetOperand(inst, 1)];
    if (!a || !b) return nil;
    NSString *x, *y;
    if (a->kind == TSVVarPtr && b->kind == TSVVarPtr && a->arrayPath && [a->arrayPath isEqualToString:b->arrayPath]) { x = a->idx; y = b->idx; }
    else if (a->kind == TSVBufPtr && b->kind == TSVBufPtr && a->buf == b->buf) { x = [self offsetExpr:a plus:0]; y = [self offsetExpr:b plus:0]; }
    else FAIL(@"comparison of unrelated pointers");
    NSString *op;
    switch (ts_LLVMGetICmpPredicate(inst)) {
    case LLVMIntEQ: op = @"=="; break;
    case LLVMIntNE: op = @"!="; break;
    case LLVMIntUGT: case LLVMIntSGT: op = @">"; break;
    case LLVMIntUGE: case LLVMIntSGE: op = @">="; break;
    case LLVMIntULT: case LLVMIntSLT: op = @"<"; break;
    default: op = @"<="; break;
    }
    return [self define:inst expr:[NSString stringWithFormat:@"(%@ %@ %@)", x, op, y]];
}

- (TSVal *)compare:(LLVMValueRef)inst float:(BOOL)isFloat {
    LLVMValueRef a = ts_LLVMGetOperand(inst, 0), b = ts_LLVMGetOperand(inst, 1);
    LLVMTypeRef t = ts_LLVMTypeOf(a);
    if (!isFloat && ts_LLVMGetTypeKind(t) == LLVMPointerTypeKind) return [self comparePointers:inst];
    NSString *x = [self expr:a], *y = [self expr:b];
    if (!x || !y) return nil;
    unsigned n = [self lanes:t];
    NSString *op = nil, *fn = nil;
    BOOL unsignedCmp = NO;
    if (isFloat) {
        LLVMRealPredicate p = ts_LLVMGetFCmpPredicate(inst);
        switch (p) {
        case LLVMRealOEQ: case LLVMRealUEQ: op = @"=="; fn = @"equal"; break;
        case LLVMRealONE: case LLVMRealUNE: op = @"!="; fn = @"notEqual"; break;
        case LLVMRealOGT: case LLVMRealUGT: op = @">"; fn = @"greaterThan"; break;
        case LLVMRealOGE: case LLVMRealUGE: op = @">="; fn = @"greaterThanEqual"; break;
        case LLVMRealOLT: case LLVMRealULT: op = @"<"; fn = @"lessThan"; break;
        case LLVMRealOLE: case LLVMRealULE: op = @"<="; fn = @"lessThanEqual"; break;
        case LLVMRealORD:
            return [self define:inst expr:n > 1 ? [NSString stringWithFormat:@"not(bvec%u(uvec%u(isnan(%@)) | uvec%u(isnan(%@))))", n, n, x, n, y]
                                                 : [NSString stringWithFormat:@"!(isnan(%@) || isnan(%@))", x, y]];
        case LLVMRealUNO:
            return [self define:inst expr:n > 1 ? [NSString stringWithFormat:@"bvec%u(uvec%u(isnan(%@)) | uvec%u(isnan(%@)))", n, n, x, n, y]
                                                 : [NSString stringWithFormat:@"(isnan(%@) || isnan(%@))", x, y]];
        case LLVMRealPredicateTrue: return [self define:inst expr:n > 1 ? [NSString stringWithFormat:@"bvec%u(true)", n] : @"true"];
        default: return [self define:inst expr:n > 1 ? [NSString stringWithFormat:@"bvec%u(false)", n] : @"false"];
        }
    } else {
        switch (ts_LLVMGetICmpPredicate(inst)) {
        case LLVMIntEQ: op = @"=="; fn = @"equal"; break;
        case LLVMIntNE: op = @"!="; fn = @"notEqual"; break;
        case LLVMIntUGT: unsignedCmp = YES; /* fallthrough */
        case LLVMIntSGT: op = @">"; fn = @"greaterThan"; break;
        case LLVMIntUGE: unsignedCmp = YES; /* fallthrough */
        case LLVMIntSGE: op = @">="; fn = @"greaterThanEqual"; break;
        case LLVMIntULT: unsignedCmp = YES; /* fallthrough */
        case LLVMIntSLT: op = @"<"; fn = @"lessThan"; break;
        case LLVMIntULE: unsignedCmp = YES; /* fallthrough */
        case LLVMIntSLE: op = @"<="; fn = @"lessThanEqual"; break;
        }
        if ([self isBool:t]) {   // bool comparisons only make sense as (in)equality
            if (n == 1) return [self define:inst expr:[NSString stringWithFormat:@"(%@ %@ %@)", x, [op isEqualToString:@"=="] ? @"==" : @"!=", y]];
            x = [NSString stringWithFormat:@"uvec%u(%@)", n, x];
            y = [NSString stringWithFormat:@"uvec%u(%@)", n, y];
        } else if (unsignedCmp) {
            x = [self asUnsigned:x type:t];
            y = [self asUnsigned:y type:t];
        }
    }
    if (n > 1) return [self define:inst expr:[NSString stringWithFormat:@"%@(%@, %@)", fn, x, y]];
    return [self define:inst expr:[NSString stringWithFormat:@"(%@ %@ %@)", x, op, y]];
}

- (TSVal *)cast:(LLVMValueRef)inst op:(LLVMOpcode)op {
    LLVMValueRef a = ts_LLVMGetOperand(inst, 0);
    LLVMTypeRef from = ts_LLVMTypeOf(a), to = ts_LLVMTypeOf(inst);
    if (op == LLVMBitCast && (ts_LLVMGetTypeKind(to) == LLVMPointerTypeKind)) {
        TSVal *p = [self value:a];
        if (!p) return nil;
        if (p->kind == TSVTexture || p->kind == TSVSampler) { _vals[KEY(inst)] = p; return p; }
        if (p->kind != TSVBufPtr && p->kind != TSVVarPtr && p->kind != TSVWordPtr) FAIL(@"bitcast of a non-pointer to a pointer");
        TSVal *c = [self copyPointer:p];
        c->type = ts_LLVMGetElementType(to);
        _vals[KEY(inst)] = c;
        return c;
    }
    if (op == LLVMAddrSpaceCast) {
        TSVal *p = [self value:a];
        if (!p) return nil;
        _vals[KEY(inst)] = p;
        return p;
    }
    NSString *x = [self expr:a];
    if (!x) return nil;
    unsigned n = [self lanes:to];
    NSString *it = [self intTypeOfLanes:n], *ft = [self floatTypeOfLanes:n];
    unsigned fw = [self isFloat:from] || ts_LLVMGetTypeKind(from) == LLVMPointerTypeKind ? 32
        : ts_LLVMGetIntTypeWidth(ts_LLVMGetTypeKind(from) == LLVMVectorTypeKind ? ts_LLVMGetElementType(from) : from);
    unsigned tw = [self isFloat:to] ? 32 : ts_LLVMGetIntTypeWidth(ts_LLVMGetTypeKind(to) == LLVMVectorTypeKind ? ts_LLVMGetElementType(to) : to);
    switch (op) {
    case LLVMFPExt: case LLVMFPTrunc: case LLVMFreeze: return [self define:inst expr:x];
    case LLVMSIToFP:
        if (fw == 1) return [self define:inst expr:[NSString stringWithFormat:@"-%@(%@)", ft, x]];
        return [self define:inst expr:[NSString stringWithFormat:@"%@(%@)", ft, x]];
    case LLVMUIToFP: return [self define:inst expr:fw == 1 ? [NSString stringWithFormat:@"%@(%@)", ft, x]
                                                           : [NSString stringWithFormat:@"%@(%@)", ft, [self asUnsigned:x type:from]]];
    case LLVMFPToSI: case LLVMFPToUI:
        if (tw == 1) return [self define:inst expr:n > 1 ? [NSString stringWithFormat:@"notEqual(%@, %@(0.0))", x, ft]
                                                         : [NSString stringWithFormat:@"(%@ != 0.0)", x]];
        if (op == LLVMFPToUI) break;
        return [self define:inst expr:[NSString stringWithFormat:@"%@(%@)", it, x]];
    default: break;
    }
    switch (op) {
    case LLVMFPToUI: return [self define:inst expr:[NSString stringWithFormat:@"%@(%@(%@))", it, n > 1 ? [NSString stringWithFormat:@"uvec%u", n] : @"uint", x]];
    case LLVMZExt:
        if (fw == 1) return [self define:inst expr:[NSString stringWithFormat:@"%@(%@)", it, x]];
        if (fw >= 32) return [self define:inst expr:x];
        return [self define:inst expr:[NSString stringWithFormat:@"(%@ & %d)", x, fw == 16 ? 0xFFFF : 0xFF]];
    case LLVMSExt:
        if (fw == 1) return [self define:inst expr:[NSString stringWithFormat:@"(-%@(%@))", it, x]];
        if (fw >= 32) return [self define:inst expr:x];
        return [self define:inst expr:[NSString stringWithFormat:@"((%@ << %u) >> %u)", x, 32 - fw, 32 - fw]];
    case LLVMTrunc:
        if (tw == 1) return [self define:inst expr:n > 1 ? [NSString stringWithFormat:@"notEqual(%@ & %@(1), %@(0))", x, it, it]
                                                         : [NSString stringWithFormat:@"((%@ & 1) != 0)", x]];
        if (tw >= 32) return [self define:inst expr:x];
        return [self define:inst expr:[NSString stringWithFormat:@"(%@ & %d)", x, tw == 16 ? 0xFFFF : 0xFF]];
    case LLVMBitCast:
        if ([self lanes:from] != n || [self isHalf:from] || [self isHalf:to]) return [self repack:inst value:x from:from to:to];
        if ([self isFloat:from] && ![self isFloat:to]) return [self define:inst expr:[NSString stringWithFormat:@"floatBitsToInt(%@)", x]];
        if (![self isFloat:from] && [self isFloat:to]) return [self define:inst expr:[NSString stringWithFormat:@"intBitsToFloat(%@)", x]];
        return [self define:inst expr:x];
    default: FAIL(@"cast opcode %d", op);
    }
}

- (BOOL)isHalf:(LLVMTypeRef)t {
    if (ts_LLVMGetTypeKind(t) == LLVMVectorTypeKind) t = ts_LLVMGetElementType(t);
    return ts_LLVMGetTypeKind(t) == LLVMHalfTypeKind;
}

// Bit width of a bitcast lane: 8/16/32-bit integers, half, float. 0 = not supported here.
- (unsigned)laneBits:(LLVMTypeRef)t {
    if (ts_LLVMGetTypeKind(t) == LLVMVectorTypeKind) t = ts_LLVMGetElementType(t);
    switch (ts_LLVMGetTypeKind(t)) {
    case LLVMHalfTypeKind: return 16;
    case LLVMFloatTypeKind: return 32;
    case LLVMIntegerTypeKind: { unsigned w = ts_LLVMGetIntTypeWidth(t); return w == 8 || w == 16 || w == 32 ? w : 0; }
    default: return 0;
    }
}

// Bitcast that changes the lane count or involves half (e.g. VectorKit's i32 -> <4 x i8> after
// pack_half_to_unorm4x8): the source lanes are packed little-endian into 32-bit words, then the
// destination lanes are cut out of them. Integers are zero-extended in GLSL ints; half is a float
// whose bits come from ts_f2h / go through ts_h2f.
- (TSVal *)repack:(LLVMValueRef)inst value:(NSString *)x from:(LLVMTypeRef)from to:(LLVMTypeRef)to {
    unsigned fw = [self laneBits:from], tw = [self laneBits:to], fn = [self lanes:from], tn = [self lanes:to];
    if (!fw || !tw || fw * fn != tw * tn) FAIL(@"bitcast from %u x %u to %u x %u bits", fn, fw, tn, tw);
    static NSString *const comp[4] = { @"x", @"y", @"z", @"w" };
    NSMutableArray<NSString *> *words = [NSMutableArray array];
    for (unsigned i = 0; i < fn; i++) {
        NSString *lane = fn > 1 ? [NSString stringWithFormat:@"(%@).%@", x, comp[i]] : x;
        NSString *bits;
        if ([self isHalf:from]) { [self needHalfEncode]; bits = [NSString stringWithFormat:@"ts_f2h(%@)", lane]; }
        else if ([self isFloat:from]) bits = [NSString stringWithFormat:@"floatBitsToUint(%@)", lane];
        else if (fw == 32) bits = [NSString stringWithFormat:@"uint(%@)", lane];
        else bits = [NSString stringWithFormat:@"(uint(%@) & %uu)", lane, fw == 16 ? 0xFFFFu : 0xFFu];
        unsigned bit = i * fw;
        if (bit % 32) [words replaceObjectAtIndex:bit / 32 withObject:[NSString stringWithFormat:@"%@ | (%@ << %uu)", words[bit / 32], bits, bit % 32]];
        else [words addObject:bits];
    }
    NSMutableArray<NSString *> *lanes = [NSMutableArray array];
    for (unsigned j = 0; j < tn; j++) {
        unsigned bit = j * tw;
        NSString *w = [NSString stringWithFormat:@"(%@)", words[bit / 32]];
        if (tw < 32) w = [NSString stringWithFormat:@"((%@ >> %uu) & %uu)", w, bit % 32, tw == 16 ? 0xFFFFu : 0xFFu];
        if ([self isHalf:to]) { [self needHalf]; [lanes addObject:[NSString stringWithFormat:@"ts_h2f(%@)", w]]; }
        else if ([self isFloat:to]) [lanes addObject:[NSString stringWithFormat:@"uintBitsToFloat(%@)", w]];
        else [lanes addObject:[NSString stringWithFormat:@"int(%@)", w]];
    }
    NSString *ty = [self isFloat:to] ? [self floatTypeOfLanes:tn] : [self intTypeOfLanes:tn];
    return [self define:inst expr:tn > 1 ? [NSString stringWithFormat:@"%@(%@)", ty, [lanes componentsJoinedByString:@", "]] : lanes[0]];
}

// A dynamic GEP index of `size`-byte elements: its constant part goes to the constant offset, the rest to the
// dynamic terms, and the alignment of the dynamic part accounts for what the index is known to be a multiple of.
- (BOOL)addIndex:(LLVMValueRef)idx size:(long)size to:(TSVal *)p dyn:(NSMutableArray *)dyn {
    LLVMValueRef base = idx;
    long k = 0;
    if (!_noCoalesce && TSSplitConstant(idx, &base, &k)) p->cst += k * size;
    else base = idx;
    NSString *e = [self expr:base];
    if (!e) return NO;
    [dyn addObject:[NSString stringWithFormat:@"%@ * %ld", e, size]];
    p->align = TSMinAlign(p->align, _noCoalesce ? TSLowBit(size) : MIN(TSLowBit(size) * TSKnownAlign(base, 0), 16));
    return YES;
}

- (TSVal *)gep:(LLVMValueRef)inst {
    TSVal *base = [self value:ts_LLVMGetOperand(inst, 0)];
    if (!base) return nil;
    if (base->kind == TSVWordPtr) return [self wordGEP:inst base:base];
    if (base->kind != TSVBufPtr && base->kind != TSVVarPtr) FAIL(@"GEP on a non-pointer");
    TSVal *p = [self copyPointer:base];
    LLVMTypeRef t = ts_LLVMGetGEPSourceElementType(inst);
    int nops = ts_LLVMGetNumOperands(inst);
    NSMutableArray *dyn = [NSMutableArray array];
    if (p->expr && p->kind == TSVBufPtr) [dyn addObject:p->expr];
    for (int i = 1; i < nops; i++) {
        LLVMValueRef idx = ts_LLVMGetOperand(inst, i);
        BOOL isConst = ts_LLVMIsAConstantInt(idx) != NULL;
        long c = isConst ? (long)ts_LLVMConstIntGetSExtValue(idx) : 0;
        if (i == 1) {
            // First index steps over whole objects of the source element type.
            if (p->kind == TSVVarPtr) {
                if (isConst && c == 0) continue;
                if (!p->arrayPath) FAIL(@"pointer arithmetic outside an array in private memory");
                NSString *e = isConst ? [NSString stringWithFormat:@"%ld", c] : [self expr:idx];
                if (!e) return nil;
                NSString *tmp = [NSString stringWithFormat:@"t%d", _temps++];
                [_decls appendFormat:@"  int %@;\n", tmp];
                [_body appendFormat:@"  %@ = %@ + %@;\n", tmp, p->idx, e];
                p->idx = tmp;
                p->expr = [NSString stringWithFormat:@"%@[%@]%@", p->arrayPath, tmp, p->elemSuffix ?: @""];
            } else {
                long size = (long)ts_LLVMABISizeOfType(_td, t);
                if (isConst) p->cst += c * size;
                else if (![self addIndex:idx size:size to:p dyn:dyn]) return nil;
            }
            continue;
        }
        LLVMTypeKind k = ts_LLVMGetTypeKind(t);
        if (k == LLVMStructTypeKind) {
            if (p->kind == TSVBufPtr) p->cst += (long)ts_LLVMOffsetOfElement(_td, t, (unsigned)c);
            else { p->expr = [NSString stringWithFormat:@"%@.m%ld", p->expr, c]; p->arrayPath = nil; p->idx = nil; p->elemSuffix = nil; }
            t = ts_LLVMStructGetTypeAtIndex(t, (unsigned)c);
        } else if (k == LLVMArrayTypeKind || k == LLVMVectorTypeKind) {
            LLVMTypeRef et = ts_LLVMGetElementType(t);
            NSString *e = isConst ? [NSString stringWithFormat:@"%ld", c] : [self expr:idx];
            if (!e) return nil;
            if (p->kind == TSVBufPtr) {
                long size = (long)(k == LLVMVectorTypeKind ? ts_LLVMStoreSizeOfType(_td, et) : ts_LLVMABISizeOfType(_td, et));
                if (isConst) p->cst += c * size;
                else if (![self addIndex:idx size:size to:p dyn:dyn]) return nil;
            } else {
                p->arrayPath = p->expr;
                p->idx = e;
                p->elemSuffix = [self wrapsElements:t] ? @".a" : nil;
                p->expr = [NSString stringWithFormat:@"%@[%@]%@", p->expr, e, p->elemSuffix ?: @""];
            }
            t = et;
        } else {
            FAIL(@"GEP into type kind %d", k);
        }
    }
    p->type = t;
    if (p->kind == TSVBufPtr && dyn.count) {
        // Materialize the dynamic part of the offset so later loads see a stable value; the
        // same expression in the same block reuses its temp, so equal addresses look equal.
        NSString *e = [dyn componentsJoinedByString:@" + "];
        NSString *key = [@"gep|" stringByAppendingString:e];
        NSString *tmp = _words[key];
        if (!tmp) {
            tmp = [NSString stringWithFormat:@"t%d", _temps++];
            [_decls appendFormat:@"  int %@;\n", tmp];
            [_body appendFormat:@"  %@ = %@;\n", tmp, e];
            _words[key] = tmp;
        }
        p->expr = tmp;
    }
    _vals[KEY(inst)] = p;
    return p;
}

#pragma mark Type-punned private memory

// A scalar or vector alloca read or written with another type, or through byte offsets (`store half` into the
// two halves of a float and `load float`, left by SROA in RenderBox's alpha_effect): path-based variables
// cannot express it, so it lives in uint words. Only uses through bitcasts, constant GEPs, loads and stores.
- (BOOL)isPunned:(LLVMValueRef)alloca type:(LLVMTypeRef)t {
    LLVMTypeKind k = ts_LLVMGetTypeKind(t);
    if (k == LLVMArrayTypeKind || k == LLVMStructTypeKind || ts_LLVMABISizeOfType(_td, t) > 16) return NO;
    NSString *own = [self glslType:t];
    if (!own) { _error = nil; return NO; }
    NSMutableArray *work = [NSMutableArray arrayWithObject:KEY(alloca)];
    BOOL punned = NO;
    while (work.count) {
        LLVMValueRef v = [work.lastObject pointerValue];
        [work removeLastObject];
        for (void *u = ts_LLVMGetFirstUse(v); u; u = ts_LLVMGetNextUse(u)) {
            LLVMValueRef user = ts_LLVMGetUser(u);
            if (!ts_LLVMIsAInstruction(user)) return NO;
            switch (ts_LLVMGetInstructionOpcode(user)) {
            case LLVMBitCast: [work addObject:KEY(user)]; break;
            case LLVMGetElementPtr:
                for (int i = 1; i < ts_LLVMGetNumOperands(user); i++)
                    if (!ts_LLVMIsAConstantInt(ts_LLVMGetOperand(user, i))) return NO;
                [work addObject:KEY(user)];
                break;
            case LLVMLoad: {
                NSString *g = [self glslType:ts_LLVMTypeOf(user)];
                if (!g || ![g isEqualToString:own] || v != alloca) punned = YES;
                break;
            }
            case LLVMStore: {
                if (ts_LLVMGetOperand(user, 0) == v) return NO;   // the address itself is stored
                NSString *g = [self glslType:ts_LLVMTypeOf(ts_LLVMGetOperand(user, 0))];
                if (!g || ![g isEqualToString:own] || v != alloca) punned = YES;
                break;
            }
            case LLVMCall: {
                LLVMValueRef callee = ts_LLVMGetCalledValue(user);
                size_t len = 0;
                const char *n = callee ? ts_LLVMGetValueName2(callee, &len) : NULL;
                if (!n || strncmp(n, "llvm.lifetime", 13)) return NO;
                break;
            }
            default: return NO;
            }
        }
    }
    _error = nil;
    return punned;
}

- (TSVal *)wordGEP:(LLVMValueRef)inst base:(TSVal *)base {
    TSVal *p = [self copyPointer:base];
    LLVMTypeRef t = ts_LLVMGetGEPSourceElementType(inst);
    for (int i = 1; i < ts_LLVMGetNumOperands(inst); i++) {
        LLVMValueRef idx = ts_LLVMGetOperand(inst, i);
        if (!ts_LLVMIsAConstantInt(idx)) FAIL(@"dynamic index into type-punned private memory");
        long c = (long)ts_LLVMConstIntGetSExtValue(idx);
        if (i == 1) { p->cst += c * (long)ts_LLVMABISizeOfType(_td, t); continue; }
        LLVMTypeKind k = ts_LLVMGetTypeKind(t);
        if (k == LLVMStructTypeKind) {
            p->cst += (long)ts_LLVMOffsetOfElement(_td, t, (unsigned)c);
            t = ts_LLVMStructGetTypeAtIndex(t, (unsigned)c);
        } else if (k == LLVMArrayTypeKind || k == LLVMVectorTypeKind) {
            LLVMTypeRef et = ts_LLVMGetElementType(t);
            p->cst += c * (long)(k == LLVMVectorTypeKind ? ts_LLVMStoreSizeOfType(_td, et) : ts_LLVMABISizeOfType(_td, et));
            t = et;
        } else FAIL(@"GEP into type kind %d", k);
    }
    p->type = t;
    _vals[KEY(inst)] = p;
    return p;
}

// Lanes of a scalar or vector type: element type, count, size in bytes.
- (BOOL)wordLanes:(LLVMTypeRef)t elem:(LLVMTypeRef *)et count:(unsigned *)n size:(unsigned *)size {
    *et = ts_LLVMGetTypeKind(t) == LLVMVectorTypeKind ? ts_LLVMGetElementType(t) : t;
    *n = [self lanes:t];
    unsigned bits = [self isFloat:*et] ? ([self isHalf:*et] ? 16 : 32) : ts_LLVMGetIntTypeWidth(*et);
    *size = bits == 1 ? 1 : bits / 8;
    return bits == 1 || bits == 8 || bits == 16 || bits == 32;
}

- (NSString *)wordLoad:(TSVal *)p type:(LLVMTypeRef)t {
    LLVMTypeRef et; unsigned n, size;
    if (![self wordLanes:t elem:&et count:&n size:&size]) FAIL(@"type-punned load of %@", [self glslType:t]);
    NSMutableArray *lanes = [NSMutableArray array];
    for (unsigned i = 0; i < n; i++) {
        long off = p->cst + (long)(i * size);
        if (off < 0 || off % size) FAIL(@"misaligned type-punned load");
        NSString *w = [NSString stringWithFormat:@"%@[%ld]", p->expr, off / 4];
        NSString *bits = size == 4 ? w : [NSString stringWithFormat:@"((%@ >> %ldu) & %uu)", w, (off % 4) * 8, size == 2 ? 0xFFFFu : 0xFFu];
        if ([self isHalf:et]) [self needHalf];
        NSString *lane = [self isHalf:et] ? [NSString stringWithFormat:@"ts_h2f(%@)", bits]
                       : [self isFloat:et] ? [NSString stringWithFormat:@"uintBitsToFloat(%@)", bits]
                       : [self isBool:et] ? [NSString stringWithFormat:@"(%@ != 0u)", bits]
                       : [NSString stringWithFormat:@"int(%@)", bits];
        [lanes addObject:lane];
    }
    return n == 1 ? lanes[0] : [NSString stringWithFormat:@"%@(%@)", [self glslType:t], [lanes componentsJoinedByString:@", "]];
}

- (BOOL)wordStore:(TSVal *)p type:(LLVMTypeRef)t value:(NSString *)v {
    LLVMTypeRef et; unsigned n, size;
    if (![self wordLanes:t elem:&et count:&n size:&size]) { _error = @"type-punned store of an unsupported type"; return NO; }
    NSString *tmp = [self newTemp:t];
    if (!tmp) return NO;
    [_body appendFormat:@"  %@ = %@;\n", tmp, v];
    for (unsigned i = 0; i < n; i++) {
        long off = p->cst + (long)(i * size);
        if (off < 0 || off % size) { _error = @"misaligned type-punned store"; return NO; }
        NSString *lane = n == 1 ? tmp : [NSString stringWithFormat:@"%@[%u]", tmp, i];
        if ([self isHalf:et]) [self needHalfEncode];
        NSString *bits = [self isHalf:et] ? [NSString stringWithFormat:@"ts_f2h(%@)", lane]
                       : [self isFloat:et] ? [NSString stringWithFormat:@"floatBitsToUint(%@)", lane]
                       : [self isBool:et] ? [NSString stringWithFormat:@"(%@ ? 1u : 0u)", lane]
                       : [NSString stringWithFormat:@"uint(%@)", lane];
        NSString *w = [NSString stringWithFormat:@"%@[%ld]", p->expr, off / 4];
        if (size == 4) [_body appendFormat:@"  %@ = %@;\n", w, bits];
        else {
            unsigned mask = size == 2 ? 0xFFFFu : 0xFFu, sh = (unsigned)(off % 4) * 8;
            [_body appendFormat:@"  %@ = (%@ & ~(%uu << %uu)) | ((%@ & %uu) << %uu);\n", w, w, mask, sh, bits, mask, sh];
        }
    }
    return YES;
}

- (TSVal *)loadInst:(LLVMValueRef)inst {
    TSVal *p = [self value:ts_LLVMGetOperand(inst, 0)];
    if (!p) return nil;
    LLVMTypeRef t = ts_LLVMTypeOf(inst);
    if (p->kind == TSVBufPtr) return [self define:inst expr:[self load:p type:t extra:0]];
    if (p->kind == TSVWordPtr) {
        NSString *e = [self wordLoad:p type:t];
        return e ? [self define:inst expr:e] : nil;
    }
    if (p->kind == TSVVarPtr) {
        if (p->type != t && ![[self glslType:p->type] isEqualToString:[self glslType:t]]) FAIL(@"type-punned load from private memory");
        return [self define:inst expr:p->expr];
    }
    if (p->kind == TSVSampler || p->kind == TSVTexture) { _vals[KEY(inst)] = p; return p; }
    FAIL(@"load from a non-pointer");
}

- (BOOL)storeInst:(LLVMValueRef)inst {
    TSVal *p = [self value:ts_LLVMGetOperand(inst, 1)];
    if (!p) return NO;
    if (p->kind == TSVBufPtr && _kernel) { _error = @"kernel stores to device memory"; return NO; }
    if (p->kind == TSVBufPtr) {
        TSMtlUnimpl(@"AIR: store to device memory dropped (not supported in vertex/fragment stages on GL 4.1)");
        return YES;
    }
    if (p->kind == TSVWordPtr) {
        NSString *v = [self expr:ts_LLVMGetOperand(inst, 0)];
        return v && [self wordStore:p type:ts_LLVMTypeOf(ts_LLVMGetOperand(inst, 0)) value:v];
    }
    if (p->kind != TSVVarPtr) { _error = @"store to a non-pointer"; return NO; }
    NSString *v = [self expr:ts_LLVMGetOperand(inst, 0)];
    if (!v) return NO;
    if (![[self glslType:ts_LLVMTypeOf(ts_LLVMGetOperand(inst, 0))] isEqualToString:[self glslType:p->type]]) {
        _error = @"type-punned store to private memory";
        return NO;
    }
    [_body appendFormat:@"  %@ = %@;\n", p->expr, v];
    return YES;
}

- (TSVal *)shuffle:(LLVMValueRef)inst {
    LLVMValueRef a = ts_LLVMGetOperand(inst, 0), b = ts_LLVMGetOperand(inst, 1);
    unsigned na = [self lanes:ts_LLVMTypeOf(a)], n = ts_LLVMGetNumMaskElements(inst);
    NSString *x = [self expr:a], *y = [self expr:b];
    if (!x || !y) return nil;
    LLVMTypeRef t = ts_LLVMTypeOf(inst);
    NSString *zero = [self zeroOf:ts_LLVMGetElementType(t)];
    static const char comps[] = "xyzw";
    NSMutableArray *parts = [NSMutableArray array];
    for (unsigned i = 0; i < n; i++) {
        int m = ts_LLVMGetMaskValue(inst, i);
        if (m < 0) [parts addObject:zero];
        else if ((unsigned)m < na) [parts addObject:[NSString stringWithFormat:@"%@.%c", x, comps[m]]];
        else [parts addObject:[NSString stringWithFormat:@"%@.%c", y, comps[m - na]]];
    }
    NSString *ty = [self glslType:t];
    if (!ty) return nil;
    return [self define:inst expr:n == 1 ? parts[0] : [NSString stringWithFormat:@"%@(%@)", ty, [parts componentsJoinedByString:@", "]]];
}

- (TSVal *)aggregate:(LLVMValueRef)inst insert:(BOOL)insert {
    unsigned n = ts_LLVMGetNumIndices(inst);
    const unsigned *idx = ts_LLVMGetIndices(inst);
    TSVal *agg = [self value:ts_LLVMGetOperand(inst, 0)];
    if (!agg) return nil;
    if (agg->kind == TSVTexResult && !insert) {   // { value, residency } from a texture call
        if (n == 1 && idx[0] == 0) { _vals[KEY(inst)] = TSExpr(agg->expr, ts_LLVMTypeOf(inst)); return _vals[KEY(inst)]; }
        return [self define:inst expr:@"1"];
    }
    if (agg->kind != TSVExpr) FAIL(@"aggregate operation on a pointer");
    NSMutableString *path = [NSMutableString string];
    LLVMTypeRef t = ts_LLVMTypeOf(ts_LLVMGetOperand(inst, 0));
    for (unsigned i = 0; i < n; i++) {
        if (ts_LLVMGetTypeKind(t) == LLVMStructTypeKind) { [path appendFormat:@".m%u", idx[i]]; t = ts_LLVMStructGetTypeAtIndex(t, idx[i]); }
        else { [path appendFormat:@"[%u]%@", idx[i], [self wrapsElements:t] ? @".a" : @""]; t = ts_LLVMGetElementType(t); }
    }
    if (!insert) return [self define:inst expr:[agg->expr stringByAppendingString:path]];
    NSString *v = [self expr:ts_LLVMGetOperand(inst, 1)];
    TSVal *r = [self define:inst expr:agg->expr];
    if (!r || !v) return nil;
    [_body appendFormat:@"  %@%@ = %@;\n", r->expr, path, v];
    return r;
}

- (TSVal *)select:(LLVMValueRef)inst {
    LLVMValueRef c = ts_LLVMGetOperand(inst, 0);
    TSVal *tv = [self value:ts_LLVMGetOperand(inst, 1)], *fv = [self value:ts_LLVMGetOperand(inst, 2)];
    NSString *ce = [self expr:c];
    if (!tv || !fv || !ce) return nil;
    if (tv->kind == TSVBufPtr && fv->kind == TSVBufPtr && tv->buf == fv->buf) {
        TSVal *p = [self copyPointer:tv];
        NSString *tmp = [NSString stringWithFormat:@"t%d", _temps++];
        [_decls appendFormat:@"  int %@;\n", tmp];
        [_body appendFormat:@"  %@ = %@ ? %@ : %@;\n", tmp, ce, [self offsetExpr:tv plus:0], [self offsetExpr:fv plus:0]];
        p->align = TSMinAlign(TSPtrAlign(tv, 0), TSPtrAlign(fv, 0));
        p->expr = tmp; p->cst = 0;
        _vals[KEY(inst)] = p;
        return p;
    }
    if (tv->kind != TSVExpr || fv->kind != TSVExpr) FAIL(@"select between pointers or handles");
    LLVMTypeRef t = ts_LLVMTypeOf(inst);
    unsigned n = [self lanes:ts_LLVMTypeOf(c)];
    if (n == 1) return [self define:inst expr:[NSString stringWithFormat:@"(%@ ? %@ : %@)", ce, tv->expr, fv->expr]];
    if ([self isFloat:t]) return [self define:inst expr:[NSString stringWithFormat:@"mix(%@, %@, %@)", fv->expr, tv->expr, ce]];
    NSString *ty = [self glslType:t];
    NSMutableArray *parts = [NSMutableArray array];
    for (unsigned i = 0; i < n; i++)
        [parts addObject:[NSString stringWithFormat:@"(%@[%u] ? %@[%u] : %@[%u])", ce, i, tv->expr, i, fv->expr, i]];
    return [self define:inst expr:[NSString stringWithFormat:@"%@(%@)", ty, [parts componentsJoinedByString:@", "]]];
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

- (TSVal *)call:(LLVMValueRef)inst {
    LLVMValueRef callee = ts_LLVMGetCalledValue(inst);
    size_t len = 0;
    const char *cname = callee ? ts_LLVMGetValueName2(callee, &len) : NULL;
    if (!cname || !len) FAIL(@"indirect call");
    NSString *name = [[NSString alloc] initWithBytes:cname length:len encoding:NSUTF8StringEncoding];
    if (_kernel && ([name hasPrefix:@"air.wg.barrier"] || [name hasPrefix:@"air.mem_barrier"] || [name containsString:@"atomic"] ||
                    [name hasPrefix:@"air.simd_"] || [name hasPrefix:@"air.quad_"]))
        FAIL(@"kernel calls %@", name);
    if ([name hasPrefix:@"llvm.lifetime"] || [name hasPrefix:@"llvm.dbg"] || [name hasPrefix:@"llvm.assume"] ||
        [name hasPrefix:@"llvm.experimental.noalias"] || [name hasPrefix:@"air.wg.barrier"])
        return [TSVal new];
    if ([name isEqualToString:@"air.discard_fragment"]) { [_body appendString:@"  discard;\n"]; return [TSVal new]; }
    if ([name hasPrefix:@"air.get_num_samples."]) return [self define:inst expr:_vertex || _kernel ? @"1" : @"gl_NumSamples"];   // GLSL 4.00+
    if ([name isEqualToString:@"air.get_read_sampler"]) {
        TSVal *s = [TSVal new];
        s->kind = TSVSampler; s->texIndex = -1; s->readSampler = YES;
        _vals[KEY(inst)] = s;
        return s;
    }
    if ([name hasPrefix:@"llvm.memcpy"] || [name hasPrefix:@"llvm.memset"]) return [self memoryIntrinsic:inst name:name];
    NSArray<NSString *> *parts = [name componentsSeparatedByString:@"."];
    if ([name hasPrefix:@"air."] && [self isTextureCall:parts[1]]) return [self texture:inst name:parts[1]];
    if ([name hasPrefix:@"air.convert."]) return [self convert:inst parts:parts];
    if ([name hasPrefix:@"air."] || [name hasPrefix:@"llvm."]) return [self math:inst parts:parts];
    if (ts_LLVMGetFirstBasicBlock(callee)) return [self inlineCall:inst callee:callee];
    FAIL(@"call to external function %@", name);
}

- (TSVal *)memoryIntrinsic:(LLVMValueRef)inst name:(NSString *)name {
    TSVal *dst = [self value:ts_LLVMGetOperand(inst, 0)];
    if (!dst) return nil;
    if (dst->kind != TSVVarPtr) {
        if (dst->kind == TSVBufPtr) return [TSVal new];   // writes to buffers are dropped
        FAIL(@"%@ into unsupported memory", name);
    }
    LLVMTypeRef vt = dst->varType;
    if ([dst->expr rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@".["]].location != NSNotFound)
        FAIL(@"%@ into part of a private variable", name);
    if ([name hasPrefix:@"llvm.memset"]) {
        [_body appendFormat:@"  %@ = %@;\n", dst->expr, [self zeroOf:vt]];
        return [TSVal new];
    }
    TSVal *src = [self value:ts_LLVMGetOperand(inst, 1)];
    if (!src) return nil;
    if (src->kind == TSVVarPtr && src->varType == vt) [_body appendFormat:@"  %@ = %@;\n", dst->expr, src->expr];
    else if (src->kind == TSVBufPtr) {
        NSString *e = [self load:src type:vt extra:0];
        if (!e) return nil;
        [_body appendFormat:@"  %@ = %@;\n", dst->expr, e];
    } else FAIL(@"memcpy between different types");
    return [TSVal new];
}

- (TSVal *)convert:(LLVMValueRef)inst parts:(NSArray<NSString *> *)parts {
    // air.convert.<dst sign>.<dst type>.<src sign>.<src type>
    if (parts.count < 6) FAIL(@"malformed %@", [parts componentsJoinedByString:@"."]);
    NSString *dk = parts[2], *sk = parts[4];
    NSString *x = [self expr:ts_LLVMGetOperand(inst, 0)];
    if (!x) return nil;
    LLVMTypeRef to = ts_LLVMTypeOf(inst), from = ts_LLVMTypeOf(ts_LLVMGetOperand(inst, 0));
    unsigned n = [self lanes:to];
    NSString *ut = n > 1 ? [NSString stringWithFormat:@"uvec%u", n] : @"uint";
    if ([dk isEqualToString:@"f"]) {
        if ([sk isEqualToString:@"f"]) return [self define:inst expr:x];
        NSString *src = [sk isEqualToString:@"u"] ? [self asUnsigned:x type:from] : x;
        return [self define:inst expr:[NSString stringWithFormat:@"%@(%@)", [self floatTypeOfLanes:n], src]];
    }
    NSString *it = [self intTypeOfLanes:n];
    unsigned tw = ts_LLVMGetIntTypeWidth(n > 1 ? ts_LLVMGetElementType(to) : to);
    if ([sk isEqualToString:@"f"]) {
        // bool(x) is x != 0; narrow integers stay zero-extended like every other i8/i16.
        if (tw == 1) return [self define:inst expr:n > 1 ? [NSString stringWithFormat:@"notEqual(%@, %@(0.0))", x, [self floatTypeOfLanes:n]]
                                                         : [NSString stringWithFormat:@"(%@ != 0.0)", x]];
        NSString *e = [dk isEqualToString:@"u"] ? [NSString stringWithFormat:@"%@(%@(max(%@, 0.0)))", it, ut, x] : [NSString stringWithFormat:@"%@(%@)", it, x];
        if (tw < 32) e = [NSString stringWithFormat:@"(%@ & %d)", e, tw == 16 ? 0xFFFF : 0xFF];
        return [self define:inst expr:e];
    }
    if (tw == 1) return [self define:inst expr:n > 1 ? [NSString stringWithFormat:@"notEqual(%@, %@(0))", x, it] : [NSString stringWithFormat:@"(%@ != 0)", x]];
    if ([self isBool:from]) return [self define:inst expr:[NSString stringWithFormat:@"%@(%@)", it, x]];
    if (tw < 32) return [self define:inst expr:[NSString stringWithFormat:@"(%@ & %d)", x, tw == 16 ? 0xFFFF : 0xFF]];
    return [self define:inst expr:x];
}

// air.pack.<fmt> / air.unpack.<fmt> (pack_float_to_unorm4x8 and friends). Integers are GLSL int;
// packSnorm2x16/unpackSnorm2x16 only exist from GLSL 4.20, so those are spelled out.
- (NSString *)packing:(NSString *)op format:(NSString *)fmt arg:(NSString *)x {
    if ([op isEqualToString:@"pack"]) {
        if ([fmt isEqualToString:@"unorm4x8"]) return [NSString stringWithFormat:@"int(packUnorm4x8(vec4(%@)))", x];
        if ([fmt isEqualToString:@"snorm4x8"]) return [NSString stringWithFormat:@"int(packSnorm4x8(vec4(%@)))", x];
        if ([fmt isEqualToString:@"unorm2x16"]) return [NSString stringWithFormat:@"int(packUnorm2x16(vec2(%@)))", x];
        if ([fmt isEqualToString:@"snorm2x16"])
            return [NSString stringWithFormat:@"(ivec2(round(clamp(vec2(%@), -1.0, 1.0) * 32767.0)).x & 0xFFFF | "
                                               "ivec2(round(clamp(vec2(%@), -1.0, 1.0) * 32767.0)).y << 16)", x, x];
        return nil;
    }
    if ([fmt isEqualToString:@"unorm4x8"]) return [NSString stringWithFormat:@"unpackUnorm4x8(uint(%@))", x];
    if ([fmt isEqualToString:@"snorm4x8"]) return [NSString stringWithFormat:@"unpackSnorm4x8(uint(%@))", x];
    if ([fmt isEqualToString:@"unorm2x16"]) return [NSString stringWithFormat:@"unpackUnorm2x16(uint(%@))", x];
    if ([fmt isEqualToString:@"snorm2x16"])
        return [NSString stringWithFormat:@"clamp(vec2(ivec2(int(%@) << 16, int(%@)) >> 16) / 32767.0, -1.0, 1.0)", x, x];
    return nil;
}

- (TSVal *)math:(LLVMValueRef)inst parts:(NSArray<NSString *> *)parts {
    NSString *base = parts.count > 1 ? parts[1] : @"";
    if ([base hasPrefix:@"fast_"]) base = [base substringFromIndex:5];
    if ([base hasPrefix:@"precise_"]) base = [base substringFromIndex:8];
    BOOL unsignedOp = [parts containsObject:@"u"];
    NSArray<NSString *> *a = [self argExprs:inst from:0];
    if (!a) return nil;
    LLVMTypeRef t = ts_LLVMTypeOf(inst);
    NSString *e = nil;
    static NSDictionary<NSString *, NSString *> *same, *renamed;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSArray *names = @[@"sin", @"cos", @"tan", @"asin", @"acos", @"atan", @"sinh", @"cosh", @"tanh", @"asinh", @"acosh", @"atanh",
                           @"exp", @"exp2", @"log", @"log2", @"sqrt", @"floor", @"ceil", @"trunc", @"round", @"fract", @"sign",
                           @"normalize", @"length", @"abs", @"dot", @"cross", @"distance", @"reflect", @"refract", @"mix", @"clamp",
                           @"step", @"smoothstep", @"min", @"max", @"pow", @"fma", @"isnan", @"isinf", @"radians", @"degrees"];
        NSMutableDictionary *s = [NSMutableDictionary dictionary];
        for (NSString *n in names) s[n] = n;
        same = s;
        renamed = @{ @"rsqrt": @"inversesqrt", @"fabs": @"abs", @"rint": @"roundEven", @"fmin": @"min", @"fmax": @"max",
                     @"minnum": @"min", @"maxnum": @"max", @"powr": @"pow", @"atan2": @"atan", @"popcount": @"bitCount",
                     @"ctpop": @"bitCount", @"reverse_bits": @"bitfieldReverse", @"fmuladd": @"fma", @"smin": @"min",
                     @"smax": @"max", @"fmin3": @"", @"fmax3": @"" };
    });
    if ([base isEqualToString:@"umin"] || [base isEqualToString:@"umax"]) { unsignedOp = YES; base = [base substringFromIndex:1]; }
    NSString *fn = same[base] ?: renamed[base];
    if (fn.length && ![self isFloat:t] && unsignedOp && ([fn isEqualToString:@"min"] || [fn isEqualToString:@"max"] || [fn isEqualToString:@"clamp"])) {
        NSMutableArray *ua = [NSMutableArray array];
        for (NSUInteger i = 0; i < a.count; i++) [ua addObject:[self asUnsigned:a[i] type:t]];
        e = [NSString stringWithFormat:@"%@(%@(%@))", [self intTypeOfLanes:[self lanes:t]], fn, [ua componentsJoinedByString:@", "]];
    } else if ([base isEqualToString:@"abs"] && a.count == 2) {
        e = [NSString stringWithFormat:@"abs(%@)", a[0]];   // llvm.abs(x, is_int_min_poison)
    } else if (fn.length) {
        e = [NSString stringWithFormat:@"%@(%@)", fn, [a componentsJoinedByString:@", "]];
        if ([fn isEqualToString:@"bitCount"] || [fn isEqualToString:@"bitfieldReverse"]) e = [NSString stringWithFormat:@"%@(%@)", [self intTypeOfLanes:[self lanes:t]], e];
    } else if ([base isEqualToString:@"all"] || [base isEqualToString:@"any"]) {
        e = [self lanes:ts_LLVMTypeOf(ts_LLVMGetOperand(inst, 0))] > 1 ? [NSString stringWithFormat:@"%@(%@)", base, a[0]] : a[0];
    } else if ([base isEqualToString:@"saturate"]) {
        e = [NSString stringWithFormat:@"clamp(%@, 0.0, 1.0)", a[0]];
    } else if ([base isEqualToString:@"fmod"]) {
        e = [NSString stringWithFormat:@"(%@ - %@ * trunc(%@ / %@))", a[0], a[1], a[0], a[1]];
    } else if ([base isEqualToString:@"exp10"]) {
        e = [NSString stringWithFormat:@"exp2(%@ * 3.32192809)", a[0]];
    } else if ([base isEqualToString:@"log10"]) {
        e = [NSString stringWithFormat:@"(log2(%@) * 0.30103)", a[0]];
    } else if ([base isEqualToString:@"copysign"]) {
        e = [NSString stringWithFormat:@"mix(abs(%@), -abs(%@), lessThan(%@, %@(0.0)))", a[0], a[0], a[1], [self glslType:t]];
        if ([self lanes:t] == 1) e = [NSString stringWithFormat:@"(%@ < 0.0 ? -abs(%@) : abs(%@))", a[1], a[0], a[0]];
    } else if ([base isEqualToString:@"clz"] || [base isEqualToString:@"ctlz"]) {
        e = [NSString stringWithFormat:@"(31 - findMSB(%@))", [self asUnsigned:a[0] type:t]];
    } else if ([base isEqualToString:@"ctz"] || [base isEqualToString:@"cttz"]) {
        e = [NSString stringWithFormat:@"findLSB(%@)", a[0]];
    } else if ([base isEqualToString:@"fmin3"] || [base isEqualToString:@"min3"]) {
        e = [NSString stringWithFormat:@"min(%@, min(%@, %@))", a[0], a[1], a[2]];
    } else if ([base isEqualToString:@"fmax3"] || [base isEqualToString:@"max3"]) {
        e = [NSString stringWithFormat:@"max(%@, max(%@, %@))", a[0], a[1], a[2]];
    } else if ([base isEqualToString:@"extract_bits"] && a.count == 3) {
        // extract_bits(x, offset, bits): the unsigned form zero-extends, the signed one sign-extends (like GLSL).
        e = unsignedOp ? [NSString stringWithFormat:@"%@(bitfieldExtract(%@, %@, %@))", [self intTypeOfLanes:[self lanes:t]],
                                                    [self asUnsigned:a[0] type:t], a[1], a[2]]
                       : [NSString stringWithFormat:@"bitfieldExtract(%@, %@, %@)", a[0], a[1], a[2]];
    } else if ([base isEqualToString:@"insert_bits"] && a.count == 4) {
        e = [NSString stringWithFormat:@"bitfieldInsert(%@, %@, %@, %@)", a[0], a[1], a[2], a[3]];
    } else if ([base isEqualToString:@"ldexp"] && a.count == 2) {
        e = [NSString stringWithFormat:@"ldexp(%@, %@)", a[0], a[1]];
    } else if ([base isEqualToString:@"dfdx"]) {
        e = [NSString stringWithFormat:@"dFdx(%@)", a[0]];
    } else if ([base isEqualToString:@"dfdy"]) {
        e = [NSString stringWithFormat:@"dFdy(%@)", a[0]];   // GL window y runs along Metal rows (see the vertex wrapper)
    } else if ([base isEqualToString:@"fwidth"]) {
        e = [NSString stringWithFormat:@"fwidth(%@)", a[0]];
    } else if (([base isEqualToString:@"pack"] || [base isEqualToString:@"unpack"]) && parts.count > 2 &&
               (e = [self packing:base format:parts[2] arg:a[0]])) {
    } else {
        FAIL(@"unsupported intrinsic %@", [parts componentsJoinedByString:@"."]);
    }
    if (ts_LLVMGetTypeKind(t) == LLVMVoidTypeKind) { [_body appendFormat:@"  %@;\n", e]; return [TSVal new]; }
    return [self define:inst expr:e];
}

#pragma mark Textures

- (BOOL)isTextureCall:(NSString *)base {
    return [base hasPrefix:@"sample_"] || [base hasPrefix:@"read_"] || [base hasPrefix:@"gather_"] || [base hasPrefix:@"get_width_"] ||
           [base hasPrefix:@"get_height_"] || [base hasPrefix:@"get_depth_"] || [base hasPrefix:@"get_num_mip_levels_"] ||
           [base hasPrefix:@"get_array_size_"] || [base hasPrefix:@"get_num_samples_"] || [base hasPrefix:@"write_"];
}

// GLSL sampler uniform for a (texture, sampler) pair, declared on first use.
- (NSString *)samplerFor:(TSVal *)tex sampler:(TSVal *)smp shape:(NSString *)shape compare:(BOOL)compare {
    NSString *tn = tex->texTypeName ?: @"";
    NSString *prefix = @"";
    NSRange lt = [tn rangeOfString:@"<"];
    if (lt.location != NSNotFound) {
        NSString *elem = [tn substringFromIndex:lt.location + 1];
        if ([elem hasPrefix:@"uint"] || [elem hasPrefix:@"ushort"]) prefix = @"u";
        else if ([elem hasPrefix:@"int"] || [elem hasPrefix:@"short"]) prefix = @"i";
    }
    NSString *suffix;
    if (!smp || smp->readSampler) suffix = @"";
    else if (smp->texIndex >= 0) suffix = [NSString stringWithFormat:@"_s%d", smp->texIndex];
    else suffix = [NSString stringWithFormat:@"_k%016llx", smp->samplerKey];
    NSString *name = [NSString stringWithFormat:@"%ctex%d%@%@", _sp, tex->texIndex, suffix, compare ? @"_c" : @""];
    NSString *type = [NSString stringWithFormat:@"%@sampler%@%@", prefix, shape, compare ? @"Shadow" : @""];
    NSString *slot = [self rectSlotFor:tex shape:shape compare:compare];
    if (slot)
        [self needUniform:[NSString stringWithFormat:@"#ifndef %@\n#define %@ 0\n#endif\n#if %@\nuniform %@sampler2DRect %@;\n#else\n"
                                                     "uniform %@ %@;\n#endif\n", slot, slot, slot, prefix, name, type, name]];
    else
        [self needUniform:[NSString stringWithFormat:@"uniform %@ %@;\n", type, name]];
    return name;
}

// Plain 2D color textures may be IOSurfaces, which GL can only bind as GL_TEXTURE_RECTANGLE
// (CGLTexImageIOSurface2D rejects GL_TEXTURE_2D, measured). Their samplers and calls are emitted
// in two forms selected by the macro TSR_<stage><index>; the pipeline links the variant with the
// macro set to 1 when an IOSurface is bound to that slot, so it is sampled in place without a copy.
- (NSString *)rectSlotFor:(TSVal *)tex shape:(NSString *)shape compare:(BOOL)compare {
    if (compare || ![shape isEqualToString:@"2D"] || [tex->texTypeName hasPrefix:@"depth"]) return nil;
    return [NSString stringWithFormat:@"TSR_%c%d", _sp, tex->texIndex];
}

// Normalized -> texel coordinates for a rectangle sampler.
static NSString *TSRectUV(NSString *s, NSString *c) { return [NSString stringWithFormat:@"((%@) * vec2(textureSize(%@)))", c, s]; }

// constexpr sampler with coord::pixel (state word bit 15): GL has unnormalized coordinates only for rectangle
// textures, so 1D/2D samples divide by the level-0 size; the rectangle variant takes the texel coordinate as is.
static BOOL TSPixelCoords(TSVal *smp, NSString *shape) {
    return smp && !smp->readSampler && smp->texIndex < 0 && ((smp->samplerKey >> 15) & 1) &&
           ([shape isEqualToString:@"2D"] || [shape isEqualToString:@"1D"]);
}

static NSString *TSNormalizedUV(NSString *s, NSString *c, NSString *shape) {
    return [shape isEqualToString:@"1D"] ? [NSString stringWithFormat:@"((%@) / float(textureSize(%@, 0)))", c, s]
                                         : [NSString stringWithFormat:@"((%@) / vec2(textureSize(%@, 0)))", c, s];
}

static NSString *TSShape(NSString *base) {
    if ([base containsString:@"cube_array"]) return @"CubeArray";
    if ([base containsString:@"cube"]) return @"Cube";
    if ([base containsString:@"2d_ms"]) return @"2DMS";
    if ([base containsString:@"2d_array"]) return @"2DArray";
    if ([base containsString:@"1d_array"]) return @"1DArray";
    if ([base containsString:@"3d"]) return @"3D";
    if ([base containsString:@"1d"]) return @"1D";
    if ([base containsString:@"buffer"]) return @"Buffer";
    return @"2D";
}

// ivec2(sample count, mip level count) of the texture bound at the slot, set by the encoder.
- (NSString *)texInfo:(TSVal *)tex {
    NSString *name = [NSString stringWithFormat:@"%@texinfo%d", _vertex ? @"v" : @"f", tex->texIndex];
    if (![_declared containsObject:name]) {
        [_declared addObject:name];
        [_globals appendFormat:@"uniform ivec2 %@;\n", name];
    }
    return name;
}

// Depth textures carry an extra i32 (always 1 so far) before the coordinate, also without compare:
// sample_depth_2d(tex, sampler, i32 1, float2 coord, ...).
- (BOOL)depthArgAt:(LLVMValueRef)inst index:(unsigned)i depth:(BOOL)isDepth {
    if (!isDepth || i >= ts_LLVMGetNumArgOperands(inst)) return NO;
    LLVMTypeRef t = ts_LLVMTypeOf(ts_LLVMGetOperand(inst, i));
    return ts_LLVMGetTypeKind(t) == LLVMIntegerTypeKind && ts_LLVMGetIntTypeWidth(t) == 32;
}

- (TSVal *)texture:(LLVMValueRef)inst name:(NSString *)base {
    LLVMValueRef texArg = ts_LLVMGetOperand(inst, 0);
    if (ts_LLVMIsUndef(texArg) || ts_LLVMIsPoison(texArg)) {
        // A texture argument removed by function-constant specialization: Metal reads zeros.
        LLVMTypeRef rt = ts_LLVMTypeOf(inst);
        LLVMTypeRef vt = ts_LLVMGetTypeKind(rt) == LLVMStructTypeKind ? ts_LLVMStructGetTypeAtIndex(rt, 0) : rt;
        TSVal *v = TSExpr([self zeroOf:vt], vt);
        if (!v->expr) return nil;
        v->kind = ts_LLVMGetTypeKind(rt) == LLVMStructTypeKind ? TSVTexResult : TSVExpr;
        _vals[KEY(inst)] = v;
        return v;
    }
    TSVal *tex = [self value:texArg];
    if (!tex) return nil;
    if (tex->kind != TSVTexture) FAIL(@"texture call on a non-texture");
    NSString *shape = TSShape(base);
    if (_kernel && _writeParam && tex == [self value:_writeParam]) return [self kernelOutput:inst name:base shape:shape];
    if ([base hasPrefix:@"write_"]) FAIL(@"texture write outside a kernel, or to a second texture");
    BOOL array = [shape hasSuffix:@"Array"], cube = [shape hasPrefix:@"Cube"];
    BOOL isDepth = [base containsString:@"depth"];
    LLVMTypeRef rt = ts_LLVMTypeOf(inst);
    LLVMTypeRef vt = ts_LLVMGetTypeKind(rt) == LLVMStructTypeKind ? ts_LLVMStructGetTypeAtIndex(rt, 0) : rt;
    NSString *vty = [self glslType:vt];
    if (!vty) return nil;
    NSString *e = nil, *er = nil, *rectSlot = nil;   // er: the expression for the rectangle-texture variant

    if ([base hasPrefix:@"get_"]) {
        NSString *s = [self samplerFor:tex sampler:nil shape:shape compare:NO];
        NSString *lod = ts_LLVMGetNumArgOperands(inst) > 1 ? [self expr:ts_LLVMGetOperand(inst, 1)] : @"0";
        if (!lod) return nil;
        // GLSL 4.10 has neither textureSamples nor textureQueryLevels: the counts come from a per-texture
        // uniform the encoder fills from the bound texture. A literal 1 is not an option: the driver
        // miscompiles while(true) loops whose trip count folds to a constant (ANGLE's MSAA resolve
        // loop over get_num_samples came out all zero).
        if ([base hasPrefix:@"get_num_samples_"]) return [self define:inst expr:[[self texInfo:tex] stringByAppendingString:@".x"]];
        if ([base hasPrefix:@"get_num_mip_levels_"]) return [self define:inst expr:[[self texInfo:tex] stringByAppendingString:@".y"]];
        if ([shape isEqualToString:@"2DMS"]) e = [NSString stringWithFormat:@"textureSize(%@)", s];
        else e = [NSString stringWithFormat:@"textureSize(%@, %@)", s, lod];
        NSString *comp = [base hasPrefix:@"get_width_"] ? @".x" : [base hasPrefix:@"get_height_"] ? @".y" : @".z";
        if ([shape isEqualToString:@"1D"] || [shape isEqualToString:@"Buffer"]) comp = @"";
        if ([base hasPrefix:@"get_array_size_"] && [shape isEqualToString:@"1DArray"]) comp = @".y";
        e = [e stringByAppendingString:comp];
        NSString *slot = [self rectSlotFor:tex shape:shape compare:NO];
        return [self define:inst expr:e rect:[NSString stringWithFormat:@"textureSize(%@)%@", s, comp] slot:slot];
    }

    if ([base hasPrefix:@"read_"]) {
        // read(coord [, layer/face] , lod) -> texelFetch; Metal and our GL storage share row 0 on top.
        NSString *s = [self samplerFor:tex sampler:nil shape:shape compare:NO];
        NSString *c = [self expr:ts_LLVMGetOperand(inst, 2)];
        if (!c) return nil;
        unsigned next = 3;
        if (array || cube) {
            NSString *layer = [self expr:ts_LLVMGetOperand(inst, next++)];
            if (!layer) return nil;
            c = [NSString stringWithFormat:@"ivec3(%@, %@)", c, layer];
        }
        // An int2 offset may follow for 2D reads.
        if (next < ts_LLVMGetNumArgOperands(inst) && [self lanes:ts_LLVMTypeOf(ts_LLVMGetOperand(inst, next))] > 1) next++;
        NSString *lod = next < ts_LLVMGetNumArgOperands(inst) ? [self expr:ts_LLVMGetOperand(inst, next)] : @"0";
        if (!lod) return nil;
        e = [NSString stringWithFormat:@"texelFetch(%@, %@, %@)", s, c, lod];
        rectSlot = [self rectSlotFor:tex shape:shape compare:NO];
        er = [NSString stringWithFormat:@"texelFetch(%@, %@)", s, c];
    } else if ([base hasPrefix:@"gather_"]) {
        // gather_<shape>(tex, sampler, [i32 1 for depth], coord, [layer], [i1 normalized, int2 offset], [i32 component], i32)
        TSVal *smp = [self value:ts_LLVMGetOperand(inst, 1)];
        NSString *s = [self samplerFor:tex sampler:smp shape:shape compare:NO];
        unsigned i = [self depthArgAt:inst index:2 depth:isDepth] ? 3 : 2;
        NSString *c = [self expr:ts_LLVMGetOperand(inst, i++)];
        if (!c) return nil;
        BOOL pixel = TSPixelCoords(smp, shape);
        NSString *rc = pixel ? c : TSRectUV(s, c);
        if (pixel) c = TSNormalizedUV(s, c, shape);
        if (array) {
            NSString *layer = [self expr:ts_LLVMGetOperand(inst, i++)];
            if (!layer) return nil;
            c = cube ? [NSString stringWithFormat:@"vec4(%@, float(%@))", c, layer] : [NSString stringWithFormat:@"vec3(%@, float(%@))", c, layer];
        }
        NSString *offset = nil;
        if (!cube) {
            i++;   // normalized-coordinates flag
            LLVMValueRef off = ts_LLVMGetOperand(inst, i++);
            if (!ts_LLVMIsAConstantAggregateZero(off)) { offset = [self constant:off]; if (!offset) return nil; }
        }
        NSString *comp = !isDepth && i + 1 < ts_LLVMGetNumArgOperands(inst) ? [self expr:ts_LLVMGetOperand(inst, i)] : @"0";
        if (!comp) return nil;
        e = offset ? [NSString stringWithFormat:@"textureGatherOffset(%@, %@, %@, %@)", s, c, offset, comp]
                   : [NSString stringWithFormat:@"textureGather(%@, %@, %@)", s, c, comp];
        rectSlot = [self rectSlotFor:tex shape:shape compare:NO];
        er = offset ? [NSString stringWithFormat:@"textureGatherOffset(%@, %@, %@, %@)", s, rc, offset, comp]
                    : [NSString stringWithFormat:@"textureGather(%@, %@, %@)", s, rc, comp];
    } else {
        // sample[_compare]_<shape>[_grad](tex, sampler, [i32 1 for compare], coord, [layer], [ref], ...)
        BOOL compare = [base hasPrefix:@"sample_compare"];
        BOOL grad = [base hasSuffix:@"_grad"];
        TSVal *smp = [self value:ts_LLVMGetOperand(inst, 1)];
        if (!smp) return nil;
        NSString *s = [self samplerFor:tex sampler:smp shape:shape compare:compare];
        rectSlot = [self rectSlotFor:tex shape:shape compare:compare];
        unsigned i = compare || [self depthArgAt:inst index:2 depth:isDepth] ? 3 : 2;
        NSString *c = [self expr:ts_LLVMGetOperand(inst, i++)];
        if (!c) return nil;
        BOOL pixel = TSPixelCoords(smp, shape);
        NSString *rc = pixel ? c : TSRectUV(s, c);
        if (pixel) c = TSNormalizedUV(s, c, shape);
        // A texel offset that is not a constant (QuartzCore's simple_rim loops over it) cannot use textureOffset:
        // it moves the coordinates instead, in texels of the sampled level (level 0 for implicit LODs).
        BOOL dynOffset = NO;
        if (!grad && !cube) {
            unsigned oi = i + (array ? 1 : 0) + (compare ? 1 : 0) + 1;
            LLVMValueRef off = oi < ts_LLVMGetNumArgOperands(inst) ? ts_LLVMGetOperand(inst, oi) : NULL;
            if (off && !ts_LLVMIsAConstant(off)) {
                NSString *o = [self expr:off];
                if (!o) return nil;
                LLVMValueRef isLod = ts_LLVMGetOperand(inst, oi + 1), amount = ts_LLVMGetOperand(inst, oi + 2);
                BOOL explicitLod = ts_LLVMIsAConstantInt(isLod) && ts_LLVMConstIntGetZExtValue(isLod);
                NSString *lv = explicitLod ? [self expr:amount] : @"0.0";
                if (!lv) return nil;
                unsigned dims = [shape hasPrefix:@"3D"] ? 3 : [shape hasPrefix:@"1D"] ? 1 : 2;
                NSString *ft = dims == 1 ? @"float" : [NSString stringWithFormat:@"vec%u", dims];
                NSString *size = [NSString stringWithFormat:@"textureSize(%@, int(%@))", s, lv];
                if (array && dims > 1) size = [NSString stringWithFormat:@"%@.xy", size];
                c = [NSString stringWithFormat:@"(%@ + %@(%@) / %@(%@))", c, ft, o, ft, size];
                rc = [NSString stringWithFormat:@"(%@ + %@(%@))", rc, ft, o];
                dynOffset = YES;
            }
        }
        if (array) {
            NSString *layer = [self expr:ts_LLVMGetOperand(inst, i++)];
            if (!layer) return nil;
            c = cube ? [NSString stringWithFormat:@"vec4(%@, float(%@))", c, layer] : [NSString stringWithFormat:@"vec3(%@, float(%@))", c, layer];
        }
        if (compare) {
            NSString *ref = [self expr:ts_LLVMGetOperand(inst, i++)];
            if (!ref) return nil;
            c = [NSString stringWithFormat:@"vec%u(%@, %@)", (unsigned)([shape isEqualToString:@"2D"] ? 3 : 4), c, ref];
        }
        if (grad) {
            NSString *dx = [self expr:ts_LLVMGetOperand(inst, i)], *dy = [self expr:ts_LLVMGetOperand(inst, i + 1)];
            if (!dx || !dy) return nil;
            e = [NSString stringWithFormat:@"textureGrad(%@, %@, %@, %@)", s, c, dx, dy];
            er = [NSString stringWithFormat:@"texture(%@, %@)", s, rc];   // no mipmaps: gradients do not matter
        } else {
            // Remaining: [i1 normalized, offset] (not for cube), i1 isLod, float lod/bias, float minLod, i32
            if (!cube) i++;   // normalized-coordinates flag
            NSString *offset = nil;
            if (!cube) {
                LLVMValueRef off = ts_LLVMGetOperand(inst, i++);
                if (!dynOffset && !ts_LLVMIsAConstantAggregateZero(off)) { offset = [self constant:off]; if (!offset) return nil; }
            }
            LLVMValueRef isLod = ts_LLVMGetOperand(inst, i++);
            LLVMValueRef amount = ts_LLVMGetOperand(inst, i++);
            BOOL lod = ts_LLVMIsAConstantInt(isLod) && ts_LLVMConstIntGetZExtValue(isLod);
            NSString *amt = [self expr:amount];
            if (!amt) return nil;
            BOOL zeroBias = ts_LLVMIsAConstantFP(amount) && [amt isEqualToString:@"0.0"];
            if (!_vertex && !lod && compare && [shape isEqualToString:@"CubeArray"]) lod = NO;
            // Rectangle textures have no mipmaps, LOD or bias: plain (offset) sampling at texel coordinates.
            er = offset ? [NSString stringWithFormat:@"textureOffset(%@, %@, %@)", s, rc, offset]
                        : [NSString stringWithFormat:@"texture(%@, %@)", s, rc];
            if (lod || _vertex || _kernel) {
                // Vertex shaders and kernels have no derivatives: an implicit-LOD sample means level 0 (bias ignored).
                NSString *level = lod ? amt : @"0.0";
                e = offset ? [NSString stringWithFormat:@"textureLodOffset(%@, %@, %@, %@)", s, c, level, offset]
                           : [NSString stringWithFormat:@"textureLod(%@, %@, %@)", s, c, level];
            } else if (zeroBias) {
                e = offset ? [NSString stringWithFormat:@"textureOffset(%@, %@, %@)", s, c, offset]
                           : [NSString stringWithFormat:@"texture(%@, %@)", s, c];
            } else {
                e = offset ? [NSString stringWithFormat:@"textureOffset(%@, %@, %@, %@)", s, c, offset, amt]
                           : [NSString stringWithFormat:@"texture(%@, %@, %@)", s, c, amt];
            }
        }
        if (isDepth && !compare) e = [e stringByAppendingString:@".r"];
    }
    NSString *(^finish)(NSString *) = ^NSString *(NSString *x) {
        if ([vty isEqualToString:@"float"] && ![x hasSuffix:@".r"] && ![base hasPrefix:@"sample_compare"]) x = [x stringByAppendingString:@".r"];
        if ([vty hasPrefix:@"ivec"] && ![x hasPrefix:@"ivec"]) x = [NSString stringWithFormat:@"%@(%@)", vty, x];   // usampler -> int lanes
        return x;
    };
    e = finish(e);
    NSString *tmp = [self newTemp:vt];
    if (!tmp) return nil;
    if (rectSlot && er) [_body appendFormat:@"#if %@\n  %@ = %@;\n#else\n  %@ = %@;\n#endif\n", rectSlot, tmp, finish(er), tmp, e];
    else [_body appendFormat:@"  %@ = %@;\n", tmp, e];
    TSVal *v = TSExpr(tmp, vt);
    v->kind = ts_LLVMGetTypeKind(rt) == LLVMStructTypeKind ? TSVTexResult : TSVExpr;
    _vals[KEY(inst)] = v;
    return v;
}

#pragma mark Kernels as fragment shaders

// Kernel built-ins in terms of the fragment: one thread per pixel of the viewport (the grid), and the
// threadgroup shape from uniforms the encoder sets (ts_grid, ts_tg). Grids are 2D (depth 1).
- (TSVal *)kernelBuiltin:(NSString *)role type:(LLVMTypeRef)pt {
    unsigned n = [self lanes:pt];
    NSString *swz = n == 1 ? @".x" : n == 2 ? @".xy" : @".xyz";
    NSString *g3 = @"ivec3(ivec2(gl_FragCoord.xy), 0)", *e = nil;
    BOOL grid = NO, tg = NO;
    if ([role isEqualToString:@"air.thread_position_in_grid"])
        e = n == 1 ? @"int(gl_FragCoord.x)" : n == 2 ? @"ivec2(gl_FragCoord.xy)" : g3;
    else if ([role isEqualToString:@"air.threads_per_grid"]) { e = [@"ts_grid" stringByAppendingString:swz]; grid = YES; }
    else if ([role isEqualToString:@"air.threads_per_threadgroup"]) { e = [@"ts_tg" stringByAppendingString:swz]; tg = YES; }
    else if ([role isEqualToString:@"air.thread_position_in_threadgroup"]) { e = [NSString stringWithFormat:@"(%@ %% ts_tg)%@", g3, swz]; tg = YES; }
    else if ([role isEqualToString:@"air.threadgroup_position_in_grid"]) { e = [NSString stringWithFormat:@"(%@ / ts_tg)%@", g3, swz]; tg = YES; }
    else if ([role isEqualToString:@"air.threadgroups_per_grid"]) { e = [@"((ts_grid + ts_tg - 1) / ts_tg)" stringByAppendingString:swz]; grid = tg = YES; }
    else if ([role isEqualToString:@"air.thread_index_in_threadgroup"]) {
        e = [NSString stringWithFormat:@"((%@ %% ts_tg).x + (%@ %% ts_tg).y * ts_tg.x)", g3, g3];
        tg = YES;
    }
    if (!e) return nil;
    if (grid) [self needUniform:@"uniform ivec3 ts_grid;\n"];
    if (tg) [self needUniform:@"uniform ivec3 ts_tg;\n"];
    return TSExpr(e, pt);
}

// The written texture: its size is the render target's (ts_out_size), its write at gid is the output.
- (TSVal *)kernelOutput:(LLVMValueRef)inst name:(NSString *)base shape:(NSString *)shape {
    if ([base hasPrefix:@"get_width_"] || [base hasPrefix:@"get_height_"]) {
        [self needUniform:@"uniform ivec2 ts_out_size;\n"];
        return [self define:inst expr:[base hasPrefix:@"get_width_"] ? @"ts_out_size.x" : @"ts_out_size.y"];
    }
    if (![base hasPrefix:@"write_"]) FAIL(@"kernel calls %@ on the texture it writes", base);
    if (![shape isEqualToString:@"2D"]) FAIL(@"kernel writes a %@ texture", shape);
    NSString *coord = [self expr:ts_LLVMGetOperand(inst, 1)];
    if (!coord) return nil;
    if (![coord isEqualToString:@"ivec2(gl_FragCoord.xy)"]) FAIL(@"kernel writes at %@, not at thread_position_in_grid", coord);
    LLVMValueRef lod = ts_LLVMGetNumArgOperands(inst) > 3 ? ts_LLVMGetOperand(inst, 3) : NULL;
    if (lod && !(ts_LLVMIsAConstantInt(lod) && ts_LLVMConstIntGetZExtValue(lod) == 0)) FAIL(@"kernel writes a mipmap level other than 0");
    NSString *v = [self expr:ts_LLVMGetOperand(inst, 2)];
    if (!v) return nil;
    [_body appendFormat:@"  o0 = %@(%@);\n  ts_wrote = true;\n", _outType, v];
    return [TSVal new];
}

// Kernel entry: exactly one texture argument written, directly by the entry function (callees are
// inlined by the clean-up passes). Declares o0 with that texture's element type.
- (BOOL)declareKernelOutput {
    for (LLVMBasicBlockRef bb = ts_LLVMGetFirstBasicBlock(_fn); bb; bb = ts_LLVMGetNextBasicBlock(bb))
        for (LLVMValueRef i = ts_LLVMGetFirstInstruction(bb); i; i = ts_LLVMGetNextInstruction(i)) {
            if (ts_LLVMGetInstructionOpcode(i) != LLVMCall) continue;
            LLVMValueRef callee = ts_LLVMGetCalledValue(i);
            size_t len = 0;
            const char *name = callee ? ts_LLVMGetValueName2(callee, &len) : NULL;
            if (!name || strncmp(name, "air.write_texture", 17)) continue;
            LLVMValueRef t = ts_LLVMGetOperand(i, 0);
            if (!ts_LLVMIsAArgument(t)) { _error = @"kernel writes a texture it does not receive as an argument"; return NO; }
            if (_writeParam && _writeParam != t) { _error = @"kernel writes more than one texture"; return NO; }
            _writeParam = t;
        }
    if (!_writeParam) { _error = @"kernel writes no texture at thread_position_in_grid"; return NO; }
    TSVal *tex = _vals[KEY(_writeParam)];
    NSString *tn = tex->texTypeName ?: @"";
    NSRange lt = [tn rangeOfString:@"<"];
    NSString *elem = lt.location != NSNotFound ? [tn substringFromIndex:lt.location + 1] : @"float";
    _outType = [elem hasPrefix:@"uint"] || [elem hasPrefix:@"ushort"] ? @"uvec4" : [elem hasPrefix:@"int"] || [elem hasPrefix:@"short"] ? @"ivec4" : @"vec4";
    // The marker tells the pipeline which texture slot to render into (it survives the disk cache).
    [_globals appendFormat:@"// ts_kernel_output %d\nlayout(location = 0) out %@ o0;\nbool ts_wrote = false;\n", tex->texIndex, _outType];
    return YES;
}

#pragma mark Control flow

- (NSArray *)reversePostOrder:(LLVMValueRef)fn {
    NSMutableArray *order = [NSMutableArray array];
    NSMutableSet *seen = [NSMutableSet set];
    // Iterative DFS keeping (block, next successor index).
    NSMutableArray *stack = [NSMutableArray array];
    LLVMBasicBlockRef entry = ts_LLVMGetFirstBasicBlock(fn);
    [stack addObject:@[KEY(entry), @0]];
    [seen addObject:KEY(entry)];
    while (stack.count) {
        NSArray *top = stack.lastObject;
        LLVMBasicBlockRef bb = [top[0] pointerValue];
        unsigned next = [top[1] unsignedIntValue];
        LLVMValueRef term = ts_LLVMGetBasicBlockTerminator(bb);
        unsigned n = term ? ts_LLVMGetNumSuccessors(term) : 0;
        if (next < n) {
            stack[stack.count - 1] = @[top[0], @(next + 1)];
            LLVMBasicBlockRef s = ts_LLVMGetSuccessor(term, next);
            if (![seen containsObject:KEY(s)]) { [seen addObject:KEY(s)]; [stack addObject:@[KEY(s), @0]]; }
        } else {
            [order addObject:top[0]];
            [stack removeLastObject];
        }
    }
    return order.reverseObjectEnumerator.allObjects;
}

// Copies for the phis of `to` when leaving `from` (parallel-copy safe).
- (NSString *)phiCopiesFrom:(LLVMBasicBlockRef)from to:(LLVMBasicBlockRef)to {
    NSMutableString *pre = [NSMutableString string], *post = [NSMutableString string];
    int k = 0;
    for (LLVMValueRef i = ts_LLVMGetFirstInstruction(to); i && ts_LLVMGetInstructionOpcode(i) == LLVMPHI; i = ts_LLVMGetNextInstruction(i)) {
        TSVal *phi = _vals[KEY(i)];
        unsigned n = ts_LLVMCountIncoming(i);
        for (unsigned j = 0; j < n; j++) {
            if (ts_LLVMGetIncomingBlock(i, j) != from) continue;
            TSVal *in = [self value:ts_LLVMGetIncomingValue(i, j)];
            if (!in) return nil;
            NSString *src, *ty;
            if (phi->pendingPhi) {
                // First incoming value decides what the pointer phi points into.
                phi->pendingPhi = NO;
                if (in->kind == TSVBufPtr) {
                    phi->kind = TSVBufPtr; phi->buf = in->buf; phi->cst = 0; phi->expr = phi->idx; phi->type = in->type; phi->align = 1;
                } else if (in->kind == TSVVarPtr && in->arrayPath) {
                    phi->kind = TSVVarPtr; phi->arrayPath = in->arrayPath; phi->type = in->type; phi->varType = in->varType;
                    phi->elemSuffix = in->elemSuffix;
                    phi->expr = [NSString stringWithFormat:@"%@[%@]%@", in->arrayPath, phi->idx, phi->elemSuffix ?: @""];
                } else FAIL(@"pointer phi over unsupported memory");
            }
            if (phi->kind == TSVBufPtr) {
                if (in->kind != TSVBufPtr || phi->buf != in->buf) FAIL(@"pointer phi mixes memory kinds");
                src = [self offsetExpr:in plus:0];
                ty = @"int";
            } else if (phi->kind == TSVVarPtr) {
                if (in->kind != TSVVarPtr || ![in->arrayPath isEqualToString:phi->arrayPath]) FAIL(@"pointer phi mixes arrays");
                src = in->idx;
                ty = @"int";
            } else {
                if (in->kind != TSVExpr && in->kind != TSVTexResult) FAIL(@"phi of pointers into private memory");
                src = in->expr;
                ty = [self glslType:ts_LLVMTypeOf(i)];
            }
            [pre appendFormat:@" %@ c%d = %@;", ty, k, src];
            [post appendFormat:@" %@ = c%d;", phi->kind == TSVExpr || phi->kind == TSVTexResult ? phi->expr : phi->idx, k];
            k++;
            break;
        }
    }
    return k ? [NSString stringWithFormat:@"{%@%@ }", pre, post] : @"";
}

- (NSString *)jumpFrom:(LLVMBasicBlockRef)from to:(LLVMBasicBlockRef)to {
    NSString *copies = [self phiCopiesFrom:from to:to];
    if (!copies) return nil;
    NSNumber *target = _blockIds[KEY(to)];
    return [NSString stringWithFormat:@"%@ %@ = %@; break;", copies, _bbVar, target];
}

- (BOOL)terminator:(LLVMValueRef)term block:(LLVMBasicBlockRef)bb {
    LLVMOpcode op = ts_LLVMGetInstructionOpcode(term);
    if (op == LLVMRet && !_isEntry) {
        if (_retTemp && ts_LLVMGetNumOperands(term) > 0) {
            NSString *v = [self expr:ts_LLVMGetOperand(term, 0)];
            if (!v) return NO;
            [_body appendFormat:@"  %@ = %@;\n", _retTemp, v];
        }
        if (_multiBlock) [_body appendFormat:@"  %@ = true; break;\n", _doneVar];
        return YES;
    }
    if (op == LLVMRet) {
        NSString *r = [self emitReturn:term];
        if (!r) return NO;
        [_body appendString:r];
        if (_multiBlock) [_body appendString:@"  return;\n"];
        return YES;
    }
    if (op == LLVMUnreachable) {
        if (_isEntry) [_body appendString:@"  return;\n"];
        else if (_multiBlock) [_body appendFormat:@"  %@ = true; break;\n", _doneVar];
        return YES;
    }
    if (!_multiBlock) { _error = @"branch in a single-block function"; return NO; }
    if (op == LLVMBr) {
        if (!ts_LLVMIsConditional(term)) {
            NSString *j = [self jumpFrom:bb to:ts_LLVMGetSuccessor(term, 0)];
            if (!j) return NO;
            [_body appendFormat:@"  %@\n", j];
            return YES;
        }
        NSString *c = [self expr:ts_LLVMGetCondition(term)];
        NSString *a = [self jumpFrom:bb to:ts_LLVMGetSuccessor(term, 0)], *b = [self jumpFrom:bb to:ts_LLVMGetSuccessor(term, 1)];
        if (!c || !a || !b) return NO;
        [_body appendFormat:@"  if (%@) { %@ } else { %@ }\n", c, a, b];
        return YES;
    }
    if (op == LLVMSwitch) {
        NSString *v = [self expr:ts_LLVMGetOperand(term, 0)];
        if (!v) return NO;
        int n = ts_LLVMGetNumOperands(term);
        NSMutableString *s = [NSMutableString stringWithString:@"  "];
        for (int i = 2; i + 1 < n; i += 2) {
            NSString *cv = [self constant:ts_LLVMGetOperand(term, i)];
            NSString *j = [self jumpFrom:bb to:ts_LLVMValueAsBasicBlock(ts_LLVMGetOperand(term, i + 1))];
            if (!cv || !j) return NO;
            [s appendFormat:@"if (%@ == %@) { %@ } else ", v, cv, j];
        }
        NSString *d = [self jumpFrom:bb to:ts_LLVMValueAsBasicBlock(ts_LLVMGetOperand(term, 1))];
        if (!d) return NO;
        [s appendFormat:@"{ %@ }\n", d];
        [_body appendString:s];
        return YES;
    }
    _error = [NSString stringWithFormat:@"terminator opcode %d", op];
    return NO;
}

- (BOOL)instruction:(LLVMValueRef)inst {
    LLVMOpcode op = ts_LLVMGetInstructionOpcode(inst);
    switch (op) {
    case LLVMFAdd: case LLVMAdd: case LLVMFSub: case LLVMSub: case LLVMFMul: case LLVMMul: case LLVMFDiv: case LLVMSDiv:
    case LLVMUDiv: case LLVMFRem: case LLVMSRem: case LLVMURem: case LLVMShl: case LLVMLShr: case LLVMAShr: case LLVMAnd:
    case LLVMOr: case LLVMXor:
        return [self binary:inst op:op] != nil;
    case LLVMFNeg: {
        NSString *x = [self expr:ts_LLVMGetOperand(inst, 0)];
        return x && [self define:inst expr:[NSString stringWithFormat:@"(-%@)", x]];
    }
    case LLVMICmp: return [self compare:inst float:NO] != nil;
    case LLVMFCmp: return [self compare:inst float:YES] != nil;
    case LLVMTrunc: case LLVMZExt: case LLVMSExt: case LLVMFPToUI: case LLVMFPToSI: case LLVMUIToFP: case LLVMSIToFP:
    case LLVMFPTrunc: case LLVMFPExt: case LLVMBitCast: case LLVMAddrSpaceCast: case LLVMFreeze:
        return [self cast:inst op:op] != nil;
    case LLVMSelect: return [self select:inst] != nil;
    case LLVMExtractElement: {
        NSString *v = [self expr:ts_LLVMGetOperand(inst, 0)];
        LLVMValueRef idx = ts_LLVMGetOperand(inst, 1);
        if (!v) return NO;
        if (ts_LLVMIsAConstantInt(idx)) return [self define:inst expr:[NSString stringWithFormat:@"%@[%llu]", v, ts_LLVMConstIntGetZExtValue(idx)]] != nil;
        NSString *i = [self expr:idx];
        if (i && [self isBool:ts_LLVMTypeOf(idx)]) i = [NSString stringWithFormat:@"int(%@)", i];   // i1 index: lane 0 or 1
        return i && [self define:inst expr:[NSString stringWithFormat:@"%@[%@]", v, i]];
    }
    case LLVMInsertElement: {
        NSString *v = [self expr:ts_LLVMGetOperand(inst, 0)], *e = [self expr:ts_LLVMGetOperand(inst, 1)];
        LLVMValueRef idx = ts_LLVMGetOperand(inst, 2);
        NSString *i = ts_LLVMIsAConstantInt(idx) ? [NSString stringWithFormat:@"%llu", ts_LLVMConstIntGetZExtValue(idx)] : [self expr:idx];
        if (i && !ts_LLVMIsAConstantInt(idx) && [self isBool:ts_LLVMTypeOf(idx)]) i = [NSString stringWithFormat:@"int(%@)", i];
        TSVal *r = v && e && i ? [self define:inst expr:v] : nil;
        if (!r) return NO;
        [_body appendFormat:@"  %@[%@] = %@;\n", r->expr, i, e];
        return YES;
    }
    case LLVMShuffleVector: return [self shuffle:inst] != nil;
    case LLVMExtractValue: return [self aggregate:inst insert:NO] != nil;
    case LLVMInsertValue: return [self aggregate:inst insert:YES] != nil;
    case LLVMAlloca: {
        LLVMTypeRef t = ts_LLVMGetAllocatedType(inst);
        if ([self isPunned:inst type:t]) {
            unsigned words = (unsigned)((ts_LLVMABISizeOfType(_td, t) + 3) / 4);
            NSString *name = [NSString stringWithFormat:@"l%d", _temps++];
            [_decls appendFormat:@"  uint %@[%u];\n", name, words];
            TSVal *p = [TSVal new];
            p->kind = TSVWordPtr; p->expr = name; p->type = t; p->varType = t; p->cst = 0;
            _vals[KEY(inst)] = p;
            return YES;
        }
        NSString *ty = [self glslType:t];
        if (!ty) return NO;
        NSString *name = [NSString stringWithFormat:@"l%d", _temps++];
        [_decls appendFormat:@"  %@ %@;\n", ty, name];
        TSVal *p = [TSVal new];
        p->kind = TSVVarPtr; p->expr = name; p->type = t; p->varType = t;
        _vals[KEY(inst)] = p;
        return YES;
    }
    case LLVMGetElementPtr: return [self gep:inst] != nil;
    case LLVMLoad: return [self loadInst:inst] != nil;
    case LLVMStore: return [self storeInst:inst];
    case LLVMCall: return [self call:inst] != nil;
    case LLVMPHI: return YES;   // values assigned on incoming edges
    case LLVMFence: return YES;
    default:
        _error = [NSString stringWithFormat:@"unsupported instruction opcode %d", op];
        return NO;
    }
}

- (BOOL)declarePhis:(NSArray *)blocks {
    for (NSValue *bv in blocks) {
        LLVMBasicBlockRef bb = bv.pointerValue;
        for (LLVMValueRef i = ts_LLVMGetFirstInstruction(bb); i && ts_LLVMGetInstructionOpcode(i) == LLVMPHI; i = ts_LLVMGetNextInstruction(i)) {
            LLVMTypeRef t = ts_LLVMTypeOf(i);
            TSVal *v;
            if (ts_LLVMGetTypeKind(t) == LLVMPointerTypeKind) {
                NSString *tmp = [NSString stringWithFormat:@"t%d", _temps++];
                [_decls appendFormat:@"  int %@;\n", tmp];
                v = [TSVal new];
                v->kind = TSVBufPtr; v->pendingPhi = YES; v->idx = tmp; v->type = ts_LLVMGetElementType(t);
            } else {
                NSString *tmp = [self newTemp:t];
                if (!tmp) return NO;
                v = TSExpr(tmp, t);
            }
            _vals[KEY(i)] = v;
        }
    }
    return YES;
}

- (NSString *)translate {
    unsigned nv = ts_LLVMGetNamedMetadataNumOperands(_mod, "air.vertex");
    unsigned nf = ts_LLVMGetNamedMetadataNumOperands(_mod, "air.fragment");
    unsigned nk = ts_LLVMGetNamedMetadataNumOperands(_mod, "air.kernel");
    if (!nv && !nf && !nk) FAIL(@"not a vertex, fragment or kernel function");
    _vertex = nv > 0;
    _kernel = !nv && !nf;
    _sp = _vertex ? 'v' : 'f';
    LLVMValueRef node;
    ts_LLVMGetNamedMetadataOperands(_mod, _vertex ? "air.vertex" : _kernel ? "air.kernel" : "air.fragment", &node);
    NSArray *ops = TSMDOperands(node);
    _fn = TSOp(ops, 0);
    if (!_fn || !ts_LLVMIsAFunction(_fn)) FAIL(@"entry point not found");
    LLVMValueRef outs = TSOp(ops, 1), ins = TSOp(ops, 2);
    if (![self declareInputs:ins ? TSMDOperands(ins) : @[]]) return nil;
    if (![self declareOutputs:outs ? TSMDOperands(outs) : @[]]) return nil;
    if (_kernel && ![self declareKernelOutput]) return nil;

    _blockIds = [NSMutableDictionary dictionary];
    _bbVar = @"ts_bb";
    _isEntry = YES;
    NSString *code = [self emitFunction:_fn];
    if (!code) return nil;
    NSMutableString *out = [NSMutableString stringWithString:_globals];
    [out appendString:@"void main() {\n"];
    [out appendString:_decls];
    [out appendString:code];
    [out appendString:@"}\n"];
    return out;
}

// Emits a function body in the current context (_bbVar, _doneVar, _retTemp, _isEntry):
// structured when the planner can nest the CFG, otherwise as a while/switch state machine.
- (NSString *)emitFunction:(LLVMValueRef)fn {
    NSArray *blocks = [self reversePostOrder:fn];
    BOOL savedMulti = _multiBlock, savedBreak = _calleeBreak;
    NSMutableString *savedBody = _body;
    _multiBlock = blocks.count > 1;
    _body = [NSMutableString string];
    if (![self declarePhis:blocks]) return nil;
    NSMutableString *code = [NSMutableString string];
    NSArray *plan = [self planFor:blocks];
    if (plan) {
        _calleeBreak = NO;
        if (![self emitSeq:plan top:YES]) return nil;
        if (_calleeBreak) [code appendFormat:@"  do {\n%@  } while (false);\n", _body];
        else [code appendString:_body];
    } else {
        _usedStateMachine = YES;
        for (NSUInteger i = 0; i < blocks.count; i++) _blockIds[blocks[i]] = @(i);
        for (NSUInteger b = 0; b < blocks.count; b++) {
            LLVMBasicBlockRef bb = [blocks[b] pointerValue];
            if (_multiBlock) [_body appendFormat:@"  case %lu: {\n", (unsigned long)b];
            [_words removeAllObjects];
            LLVMValueRef term = ts_LLVMGetBasicBlockTerminator(bb);
            for (LLVMValueRef i = ts_LLVMGetFirstInstruction(bb); i && i != term; i = ts_LLVMGetNextInstruction(i))
                if (![self instruction:i]) return nil;
            if (!term || ![self terminator:term block:bb]) return _error ? nil : (_error = @"block without terminator", nil);
            if (_multiBlock) [_body appendString:@"  }\n"];
        }
        if (!_multiBlock) [code appendString:_body];
        else if (_isEntry) [code appendFormat:@"  int %@ = 0;\n  while (true) {\n  switch (%@) {\n%@  default: return;\n  }\n  }\n", _bbVar, _bbVar, _body];
        else [code appendFormat:@"  int %@ = 0; bool %@ = false;\n  while (!%@) {\n  switch (%@) {\n%@  default: %@ = true;\n  }\n  }\n",
              _bbVar, _doneVar, _doneVar, _bbVar, _body, _doneVar];
    }
    _body = savedBody;
    _multiBlock = savedMulti;
    _calleeBreak = savedBreak;
    return code;
}

- (NSArray *)planFor:(NSArray *)blocks {
    if (_noStruct) return nil;
    TSStructurer *st = [[TSStructurer alloc] initWithBlocks:blocks];
    if (!st || ![st analyze]) return nil;
    NSMutableArray *plan = [NSMutableArray array];
    if (![st seq:plan from:0 follow:-1 skipLoop:NO]) return nil;
    if (!_isEntry && st->returnInLoop) return nil;   // a callee return inside a loop has no structured exit
    return plan;
}

- (BOOL)emitSeq:(NSArray<TSNode *> *)seq top:(BOOL)top {
    for (NSUInteger idx = 0; idx < seq.count; idx++) {
        TSNode *nd = seq[idx];
        BOOL last = top && idx + 1 == seq.count;
        switch (nd->kind) {
        case TSNBlock: {
            [_words removeAllObjects];
            LLVMValueRef term = ts_LLVMGetBasicBlockTerminator(nd->bb);
            for (LLVMValueRef i = ts_LLVMGetFirstInstruction(nd->bb); i && i != term; i = ts_LLVMGetNextInstruction(i))
                if (![self instruction:i]) return NO;
            break;
        }
        case TSNEdge: {
            NSString *copies = [self phiCopiesFrom:nd->bb to:nd->to];
            if (!copies) return NO;
            if (copies.length) [_body appendFormat:@"  %@\n", copies];
            break;
        }
        case TSNContinue: [_body appendString:@"  continue;\n"]; break;
        case TSNBreak: [_body appendString:@"  break;\n"]; break;
        case TSNReturn: if (![self structuredReturn:nd->bb last:last]) return NO; break;
        case TSNLoop:
            [_body appendString:@"  while (true) {\n"];
            if (![self emitSeq:nd->body top:NO]) return NO;
            [_body appendString:@"  }\n"];
            break;
        case TSNIf: if (![self emitIf:nd]) return NO; break;
        }
    }
    return YES;
}

- (NSString *)emitArm:(NSArray<TSNode *> *)arm {
    NSMutableString *saved = _body;
    _body = [NSMutableString string];
    BOOL ok = [self emitSeq:arm top:NO];
    NSString *code = _body;
    _body = saved;
    return ok ? code : nil;
}

- (BOOL)emitIf:(TSNode *)nd {
    LLVMValueRef term = ts_LLVMGetBasicBlockTerminator(nd->bb);
    NSMutableArray<NSString *> *arms = [NSMutableArray array];
    for (NSArray *arm in nd->arms) {
        NSString *code = [self emitArm:arm];
        if (!code) return NO;
        [arms addObject:code];
    }
    if (ts_LLVMGetInstructionOpcode(term) == LLVMBr) {
        NSString *c = [self expr:ts_LLVMGetCondition(term)];
        if (!c) return NO;
        if ([nd->targets[0] pointerValue] != ts_LLVMGetSuccessor(term, 0)) { NSString *t = arms[0]; arms[0] = arms[1]; arms[1] = t; }
        if (!arms[1].length) [_body appendFormat:@"  if (%@) {\n%@  }\n", c, arms[0]];
        else if (!arms[0].length) [_body appendFormat:@"  if (!%@) {\n%@  }\n", c, arms[1]];
        else [_body appendFormat:@"  if (%@) {\n%@  } else {\n%@  }\n", c, arms[0], arms[1]];
        return YES;
    }
    // switch: an if/else-if chain over the non-default targets, default last.
    NSString *v = [self expr:ts_LLVMGetOperand(term, 0)];
    if (!v) return NO;
    LLVMBasicBlockRef def = ts_LLVMValueAsBasicBlock(ts_LLVMGetOperand(term, 1));
    int nops = ts_LLVMGetNumOperands(term);
    NSMutableString *s = [NSMutableString stringWithString:@"  "];
    NSString *defArm = @"";
    for (NSUInteger a = 0; a < nd->targets.count; a++) {
        LLVMBasicBlockRef t = [nd->targets[a] pointerValue];
        if (t == def) { defArm = arms[a]; continue; }
        NSMutableArray *conds = [NSMutableArray array];
        for (int i = 2; i + 1 < nops; i += 2) {
            if (ts_LLVMValueAsBasicBlock(ts_LLVMGetOperand(term, i + 1)) != t) continue;
            NSString *cv = [self constant:ts_LLVMGetOperand(term, i)];
            if (!cv) return NO;
            [conds addObject:[NSString stringWithFormat:@"%@ == %@", v, cv]];
        }
        [s appendFormat:@"if (%@) {\n%@  } else ", [conds componentsJoinedByString:@" || "], arms[a]];
    }
    [s appendFormat:@"{\n%@  }\n", defArm];
    [_body appendString:s];
    return YES;
}

- (BOOL)structuredReturn:(LLVMBasicBlockRef)bb last:(BOOL)last {
    LLVMValueRef term = ts_LLVMGetBasicBlockTerminator(bb);
    BOOL ret = term && ts_LLVMGetInstructionOpcode(term) == LLVMRet;
    if (_isEntry) {
        if (ret) {
            NSString *r = [self emitReturn:term];
            if (!r) return NO;
            [_body appendString:r];
        }
        if (!last) [_body appendString:@"  return;\n"];
        return YES;
    }
    if (ret && _retTemp && ts_LLVMGetNumOperands(term) > 0) {
        NSString *v = [self expr:ts_LLVMGetOperand(term, 0)];
        if (!v) return NO;
        [_body appendFormat:@"  %@ = %@;\n", _retTemp, v];
    }
    if (!last) { [_body appendString:@"  break;\n"]; _calleeBreak = YES; }
    return YES;
}

// Calls to functions defined in the module are inlined: GLSL could not receive our
// texture/sampler/buffer handles as parameters.
- (TSVal *)inlineCall:(LLVMValueRef)inst callee:(LLVMValueRef)callee {
    if (++_inlineDepth > 8) FAIL(@"call nesting too deep (recursion?)");
    unsigned n = ts_LLVMCountParams(callee);
    for (unsigned i = 0; i < n; i++) {
        TSVal *arg = [self value:ts_LLVMGetOperand(inst, i)];
        if (!arg) return nil;
        _vals[KEY(ts_LLVMGetParam(callee, i))] = arg;
    }
    LLVMTypeRef rt = ts_LLVMTypeOf(inst);
    NSString *ret = nil;
    if (ts_LLVMGetTypeKind(rt) != LLVMVoidTypeKind && !(ret = [self newTemp:rt])) return nil;
    NSString *savedBB = _bbVar, *savedDone = _doneVar, *savedRet = _retTemp;
    BOOL savedEntry = _isEntry;
    int id = _temps++;
    _bbVar = [NSString stringWithFormat:@"ts_bb%d", id];
    _doneVar = [NSString stringWithFormat:@"ts_done%d", id];
    _retTemp = ret;
    _isEntry = NO;
    NSString *code = [self emitFunction:callee];
    [_words removeAllObjects];   // words fetched inside the callee may sit in branches the caller does not see
    _bbVar = savedBB; _doneVar = savedDone; _retTemp = savedRet; _isEntry = savedEntry;
    _inlineDepth--;
    if (!code) return nil;
    [_body appendFormat:@"  {\n%@  }\n", code];
    TSVal *v = ret ? TSExpr(ret, rt) : [TSVal new];
    _vals[KEY(inst)] = v;
    return v;
}
@end

#pragma mark - Public entry

// IR clean-up before translation (docs/OTTIMIZZAZIONE.md, A1). Removes allocas, struct
// copies and zeroing loops, inlines callees and folds the CFG. Structurization (A2) runs
// only for CFGs the planner could not nest by itself.
static const char *kTSCleanupPasses =
    "inline,function(sroa,loop-unroll-full,sroa,early-cse,instcombine,dse,adce,simplifycfg,instcombine)";
// TSAirNoUnroll (mslbundle P2): the same without full unrolling, for shaders whose unrolled loops cost the driver more.
static const char *kTSCleanupPassesNoUnroll = "inline,function(sroa,early-cse,instcombine,dse,adce,simplifycfg,instcombine)";
static const char *kTSStructurizePasses = "function(lowerswitch,fix-irreducible,unify-loop-exits,structurizecfg)";

static NSString *TSRunPasses(LLVMModuleRef mod, const char *pipeline) {
    LLVMPassBuilderOptionsRef opts = ts_LLVMCreatePassBuilderOptions();   // NULL options crash LLVMRunPasses
    LLVMErrorRef err = ts_LLVMRunPasses(mod, pipeline, NULL, opts);
    ts_LLVMDisposePassBuilderOptions(opts);
    if (!err) return nil;
    char *msg = ts_LLVMGetErrorMessage(err);
    NSString *s = msg ? @(msg) : @"pass pipeline failed";
    ts_LLVMDisposeErrorMessage(msg);
    return s;
}

static NSString *TSTranslateModule(LLVMModuleRef mod, NSDictionary<NSString *, NSString *> *interpolation,
                                   NSDictionary **varyingQualifiers, NSString **error, BOOL *stateMachine, unsigned flags) {
    TSAirTranslator *t = [TSAirTranslator new];
    t->_noStruct = (flags & TSAirNoStructure) != 0;
    t->_noCoalesce = (flags & TSAirNoCoalesce) != 0;
    t->_mod = mod;
    t->_td = ts_LLVMCreateTargetData(ts_LLVMGetDataLayoutStr(mod));
    t->_globals = [NSMutableString string];
    t->_decls = [NSMutableString string];
    t->_body = [NSMutableString string];
    t->_vals = [NSMutableDictionary dictionary];
    t->_structs = [NSMutableDictionary dictionary];
    t->_wraps = [NSMutableDictionary dictionary];
    t->_bufs = [NSMutableDictionary dictionary];
    t->_declared = [NSMutableSet set];
    t->_interpolation = interpolation;
    t->_varyingQualifiers = [NSMutableDictionary dictionary];
    t->_words = [NSMutableDictionary dictionary];
    NSString *result = nil;
    @autoreleasepool { result = [t translate]; }
    if (!result && error) *error = t->_error ?: @"translation failed";
    if (result && varyingQualifiers) *varyingQualifiers = t->_varyingQualifiers;
    if (stateMachine) *stateMachine = t->_usedStateMachine;
    ts_LLVMDisposeTargetData(t->_td);
    return result;
}

// Identifies the GLSL this build emits (disk cache and .mslbundle key): any change to the translator, or a
// different translation mode, invalidates cached translations.
NSString *TSAirTranslatorTag(void) {
#ifndef TS_TRANSLATOR_REV
#define TS_TRANSLATOR_REV __DATE__ " " __TIME__
#endif
    return [NSString stringWithFormat:@"tsair-3b " TS_TRANSLATOR_REV " passes=%d struct=%d coalesce=%d",
            !getenv("TSMTL_NO_PASSES"), !getenv("TSMTL_NO_STRUCT"), !getenv("TSMTL_NO_COALESCE")];
}

// TSMTL_NO_PASSES=1 / TSMTL_NO_STRUCT=1 / TSMTL_NO_COALESCE=1 disable the clean-up passes / structured emission /
// load coalescing (A/B tests).
unsigned TSAirDefaultFlags(void) {
    static unsigned flags;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        flags = (getenv("TSMTL_NO_PASSES") ? TSAirNoPasses : 0) | (getenv("TSMTL_NO_STRUCT") ? TSAirNoStructure : 0) |
                (getenv("TSMTL_NO_COALESCE") ? TSAirNoCoalesce : 0);
    });
    return flags;
}

NSString *TSAirTranslate(NSData *bitcode, NSDictionary<NSString *, NSString *> *interpolation,
                         NSDictionary<NSString *, NSString *> **varyingQualifiers, NSString **error) {
    return TSAirTranslateWithFlags(bitcode, interpolation, varyingQualifiers, error, TSAirDefaultFlags());
}

NSString *TSAirTranslateWithFlags(NSData *bitcode, NSDictionary<NSString *, NSString *> *interpolation,
                                  NSDictionary<NSString *, NSString *> **varyingQualifiers, NSString **error, unsigned flags) {
    return TSAirTranslateLinked(bitcode, nil, interpolation, varyingQualifiers, error, flags);
}

static const char kTSVisibleRef[] = ".MTL_VISIBLE_FN_REF";

BOOL TSAirNeedsLinking(NSData *bitcode) {
    return bitcode.length && memmem(bitcode.bytes, bitcode.length, kTSVisibleRef, sizeof kTSVisibleRef - 1) != NULL;
}

// Resolves the visible function references of `mod` (`declare @<name>.MTL_VISIBLE_FN_REF`, section
// "air.externally_defined") with the pipeline's linked functions: each one is parsed into the same
// context, its definition renamed to a private name, the module linked in, and the reference replaced
// by the definition, which the clean-up passes then inline. `linked` maps names to bitcode.
static NSString *TSLinkVisibleFunctions(LLVMContextRef ctx, LLVMModuleRef mod, NSDictionary<NSString *, NSData *> *linked) {
    NSMutableArray<NSValue *> *refs = [NSMutableArray array];
    for (LLVMValueRef f = ts_LLVMGetFirstFunction(mod); f; f = ts_LLVMGetNextFunction(f)) {
        size_t len = 0;
        const char *n = ts_LLVMGetValueName2(f, &len);
        if (ts_LLVMIsDeclaration(f) && len > sizeof kTSVisibleRef - 1 &&
            !memcmp(n + len - (sizeof kTSVisibleRef - 1), kTSVisibleRef, sizeof kTSVisibleRef - 1))
            [refs addObject:KEY(f)];
    }
    unsigned serial = 0;
    for (NSValue *v in refs) {
        LLVMValueRef ref = v.pointerValue;
        size_t len = 0;
        const char *n = ts_LLVMGetValueName2(ref, &len);
        NSString *name = [[NSString alloc] initWithBytes:n length:len - (sizeof kTSVisibleRef - 1) encoding:NSUTF8StringEncoding];
        NSData *bc = linked[name];
        if (!bc) return [NSString stringWithFormat:@"no linked function %@", name];
        LLVMMemoryBufferRef mb = ts_LLVMCreateMemoryBufferWithMemoryRange(bc.bytes, bc.length, "linked", 0);
        LLVMModuleRef src = NULL;
        BOOL bad = ts_LLVMParseBitcodeInContext2(ctx, mb, &src) || !src;
        ts_LLVMDisposeMemoryBuffer(mb);
        if (bad) return [NSString stringWithFormat:@"linked function %@: bitcode parse failed", name];
        // The definition: the function with the linked name, else the only external definition.
        LLVMValueRef def = ts_LLVMGetNamedFunction(src, name.UTF8String);
        if (!def || ts_LLVMIsDeclaration(def)) {
            unsigned defs = 0;
            def = NULL;
            for (LLVMValueRef f = ts_LLVMGetFirstFunction(src); f; f = ts_LLVMGetNextFunction(f))
                if (!ts_LLVMIsDeclaration(f) && ts_LLVMGetLinkage(f) == 0 /* external */) { def = f; defs++; }
            if (defs != 1) { ts_LLVMDisposeModule(src); return [NSString stringWithFormat:@"linked function %@ not found", name]; }
        }
        // Helpers and globals of the linked module become internal, so the linker renames them on clashes.
        for (LLVMValueRef f = ts_LLVMGetFirstFunction(src); f; f = ts_LLVMGetNextFunction(f))
            if (!ts_LLVMIsDeclaration(f)) ts_LLVMSetLinkage(f, 8 /* LLVMInternalLinkage */);
        for (LLVMValueRef g = ts_LLVMGetFirstGlobal(src); g; g = ts_LLVMGetNextGlobal(g))
            if (!ts_LLVMIsDeclaration(g)) ts_LLVMSetLinkage(g, 8);
        char unique[64];
        snprintf(unique, sizeof unique, "ts_linked_%u", serial++);
        ts_LLVMSetValueName2(def, unique, strlen(unique));
        ts_LLVMSetLinkage(def, 0 /* LLVMExternalLinkage: kept by the linker */);
        if (ts_LLVMLinkModules2(mod, src)) return [NSString stringWithFormat:@"linking %@ failed", name];   // consumes src
        LLVMValueRef linkedDef = ts_LLVMGetNamedFunction(mod, unique);
        if (!linkedDef) return [NSString stringWithFormat:@"linked function %@ lost", name];
        LLVMTypeRef want = ts_LLVMTypeOf(ref);
        ts_LLVMReplaceAllUsesWith(ref, ts_LLVMTypeOf(linkedDef) == want ? linkedDef : ts_LLVMConstBitCast(linkedDef, want));
        ts_LLVMSetLinkage(linkedDef, 8);
    }
    return nil;
}

NSString *TSAirTranslateLinked(NSData *bitcode, NSDictionary<NSString *, NSData *> *linked,
                               NSDictionary<NSString *, NSString *> *interpolation,
                               NSDictionary<NSString *, NSString *> **varyingQualifiers, NSString **error, unsigned flags) {
    const char *loadError = NULL;
    if (!TSLLVMLoad(&loadError)) { if (error) *error = @(loadError); return nil; }
    TSMtlStat(TSStatTranslations, 1);
    BOOL noPasses = (flags & TSAirNoPasses) != 0;
    LLVMContextRef ctx = ts_LLVMContextCreate();
    // Fully parsed modules keep no reference to the buffer, so it can wrap the NSData without a copy.
    LLVMMemoryBufferRef mb = ts_LLVMCreateMemoryBufferWithMemoryRange(bitcode.bytes, bitcode.length, "air", 0);
    LLVMModuleRef mod = NULL;
    BOOL parseFailed = ts_LLVMParseBitcodeInContext2(ctx, mb, &mod) || !mod;
    ts_LLVMDisposeMemoryBuffer(mb);
    if (parseFailed) {
        if (error) *error = @"bitcode parse failed";
        ts_LLVMContextDispose(ctx);
        return nil;
    }
    NSString *linkError = TSAirNeedsLinking(bitcode) ? TSLinkVisibleFunctions(ctx, mod, linked) : nil;
    if (linkError) {
        if (error) *error = linkError;
        ts_LLVMDisposeModule(mod);
        ts_LLVMContextDispose(ctx);
        return nil;
    }
    NSString *result = nil, *firstError = nil, *how = nil;
    BOOL sm = NO;
    if (!noPasses) {
        // 1. cleaned IR; 2. cleaned + structurized when 1 needed the state machine.
        LLVMModuleRef clean = ts_LLVMCloneModule(mod);
        NSString *perr = TSRunPasses(clean, (flags & TSAirNoUnroll) ? kTSCleanupPassesNoUnroll : kTSCleanupPasses);
        if (perr) TSMtlWarn(@"AIR: clean-up passes failed: %@", perr);
        else {
            result = TSTranslateModule(clean, interpolation, varyingQualifiers, &firstError, &sm, flags);
            how = @"cleaned";
            if (result && sm && !(flags & TSAirNoStructure)) {
                LLVMModuleRef structured = ts_LLVMCloneModule(clean);
                NSString *serr = TSRunPasses(structured, kTSStructurizePasses), *e2 = nil;
                BOOL sm2 = YES;
                NSDictionary *q2 = nil;
                NSString *r2 = serr ? nil : TSTranslateModule(structured, interpolation, &q2, &e2, &sm2, flags);
                if (r2 && !sm2) {
                    result = r2; sm = NO; how = @"cleaned+structurizecfg";
                    if (varyingQualifiers) *varyingQualifiers = q2;
                }
                ts_LLVMDisposeModule(structured);
            }
            if (!result && getenv("TSMTL_DUMP_IR")) {   // the cleaned IR the translator refused
                char *ir = ts_LLVMPrintModuleToString(clean);
                fprintf(stderr, "[TSMtl] cleaned IR (%s):\n%s\n", firstError.UTF8String, ir);
                ts_LLVMDisposeMessage(ir);
            }
            // Kernels the GL path cannot express are expected (they go to OpenCL): not a warning.
            if (!result && [firstError hasPrefix:@"kernel"]) TSMtlLog(@"AIR: cleaned IR not translatable (%@), retrying the original IR", firstError);
            else if (!result) TSMtlWarn(@"AIR: cleaned IR not translatable (%@), retrying the original IR", firstError);
        }
        ts_LLVMDisposeModule(clean);
    }
    if (!result) {
        result = TSTranslateModule(mod, interpolation, varyingQualifiers, error, &sm, flags);
        how = @"original";
    }
    if (result) TSMtlLog(@"AIR: translated from %@ IR, %@ control flow", how, sm ? @"state-machine" : @"structured");
    ts_LLVMDisposeModule(mod);
    ts_LLVMContextDispose(ctx);
    return result;
}
