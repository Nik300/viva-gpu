// Viva Metal - minimal LLVM C API binding, resolved at runtime from the
// system libLLVM (macOS: GPUCompiler.framework; iOS 16: /usr/lib/libLLVM.dylib; both in the dyld shared cache). No llvm-c
// headers ship with the Command Line Tools, so the subset we use is declared here.
// Enum values are those of the stable LLVM C API.
#pragma once
#include <stddef.h>
#include <stdbool.h>
#include <stdint.h>
#include "vmg.h"

typedef struct LLVMOpaqueContext *LLVMContextRef;
typedef struct LLVMOpaqueModule *LLVMModuleRef;
typedef struct LLVMOpaqueType *LLVMTypeRef;
typedef struct LLVMOpaqueValue *LLVMValueRef;
typedef struct LLVMOpaqueBasicBlock *LLVMBasicBlockRef;
typedef struct LLVMOpaqueMemoryBuffer *LLVMMemoryBufferRef;
typedef struct LLVMOpaqueTargetData *LLVMTargetDataRef;
typedef struct LLVMOpaqueError *LLVMErrorRef;
typedef struct LLVMOpaquePassBuilderOptions *LLVMPassBuilderOptionsRef;
typedef struct LLVMOpaquePassManager *LLVMPassManagerRef;
typedef int LLVMBool;

typedef enum {
    LLVMVoidTypeKind = 0, LLVMHalfTypeKind, LLVMFloatTypeKind, LLVMDoubleTypeKind, LLVMX86_FP80TypeKind,
    LLVMFP128TypeKind, LLVMPPC_FP128TypeKind, LLVMLabelTypeKind, LLVMIntegerTypeKind, LLVMFunctionTypeKind,
    LLVMStructTypeKind, LLVMArrayTypeKind, LLVMPointerTypeKind, LLVMVectorTypeKind, LLVMMetadataTypeKind,
    LLVMX86_MMXTypeKind, LLVMTokenTypeKind, LLVMScalableVectorTypeKind, LLVMBFloatTypeKind
} LLVMTypeKind;

typedef enum {
    LLVMRet = 1, LLVMBr = 2, LLVMSwitch = 3, LLVMIndirectBr = 4, LLVMInvoke = 5, LLVMUnreachable = 7,
    LLVMAdd = 8, LLVMFAdd = 9, LLVMSub = 10, LLVMFSub = 11, LLVMMul = 12, LLVMFMul = 13, LLVMUDiv = 14,
    LLVMSDiv = 15, LLVMFDiv = 16, LLVMURem = 17, LLVMSRem = 18, LLVMFRem = 19, LLVMShl = 20, LLVMLShr = 21,
    LLVMAShr = 22, LLVMAnd = 23, LLVMOr = 24, LLVMXor = 25, LLVMAlloca = 26, LLVMLoad = 27, LLVMStore = 28,
    LLVMGetElementPtr = 29, LLVMTrunc = 30, LLVMZExt = 31, LLVMSExt = 32, LLVMFPToUI = 33, LLVMFPToSI = 34,
    LLVMUIToFP = 35, LLVMSIToFP = 36, LLVMFPTrunc = 37, LLVMFPExt = 38, LLVMPtrToInt = 39, LLVMIntToPtr = 40,
    LLVMBitCast = 41, LLVMICmp = 42, LLVMFCmp = 43, LLVMPHI = 44, LLVMCall = 45, LLVMSelect = 46,
    LLVMExtractElement = 50, LLVMInsertElement = 51, LLVMShuffleVector = 52, LLVMExtractValue = 53,
    LLVMInsertValue = 54, LLVMFence = 55, LLVMAtomicCmpXchg = 56, LLVMAtomicRMW = 57, LLVMAddrSpaceCast = 60,
    LLVMFNeg = 66, LLVMFreeze = 68
} LLVMOpcode;

typedef enum {
    LLVMIntEQ = 32, LLVMIntNE, LLVMIntUGT, LLVMIntUGE, LLVMIntULT, LLVMIntULE, LLVMIntSGT, LLVMIntSGE, LLVMIntSLT, LLVMIntSLE
} LLVMIntPredicate;

typedef enum {
    LLVMRealPredicateFalse = 0, LLVMRealOEQ, LLVMRealOGT, LLVMRealOGE, LLVMRealOLT, LLVMRealOLE, LLVMRealONE,
    LLVMRealORD, LLVMRealUNO, LLVMRealUEQ, LLVMRealUGT, LLVMRealUGE, LLVMRealULT, LLVMRealULE, LLVMRealUNE,
    LLVMRealPredicateTrue
} LLVMRealPredicate;

#define TS_LLVM_FUNCS(X) \
    X(LLVMContextRef, LLVMContextCreate, (void)) \
    X(void, LLVMContextDispose, (LLVMContextRef)) \
    X(LLVMMemoryBufferRef, LLVMCreateMemoryBufferWithMemoryRange, (const char *, size_t, const char *, LLVMBool)) \
    X(LLVMBool, LLVMParseBitcodeInContext2, (LLVMContextRef, LLVMMemoryBufferRef, LLVMModuleRef *)) \
    X(void, LLVMDisposeMemoryBuffer, (LLVMMemoryBufferRef)) \
    X(void, LLVMDisposeModule, (LLVMModuleRef)) \
    X(LLVMModuleRef, LLVMCloneModule, (LLVMModuleRef)) \
    X(char *, LLVMPrintModuleToString, (LLVMModuleRef)) \
    X(char *, LLVMPrintValueToString, (LLVMValueRef)) \
    X(void, LLVMDisposeMessage, (char *)) \
    X(unsigned, LLVMGetNamedMetadataNumOperands, (LLVMModuleRef, const char *)) \
    X(void, LLVMGetNamedMetadataOperands, (LLVMModuleRef, const char *, LLVMValueRef *)) \
    X(unsigned, LLVMGetMDNodeNumOperands, (LLVMValueRef)) \
    X(void, LLVMGetMDNodeOperands, (LLVMValueRef, LLVMValueRef *)) \
    X(const char *, LLVMGetMDString, (LLVMValueRef, unsigned *)) \
    X(const char *, LLVMGetValueName2, (LLVMValueRef, size_t *)) \
    X(const char *, LLVMGetDataLayoutStr, (LLVMModuleRef)) \
    X(LLVMTargetDataRef, LLVMCreateTargetData, (const char *)) \
    X(void, LLVMDisposeTargetData, (LLVMTargetDataRef)) \
    X(unsigned long long, LLVMOffsetOfElement, (LLVMTargetDataRef, LLVMTypeRef, unsigned)) \
    X(unsigned long long, LLVMABISizeOfType, (LLVMTargetDataRef, LLVMTypeRef)) \
    X(unsigned long long, LLVMStoreSizeOfType, (LLVMTargetDataRef, LLVMTypeRef)) \
    X(LLVMTypeRef, LLVMTypeOf, (LLVMValueRef)) \
    X(LLVMTypeKind, LLVMGetTypeKind, (LLVMTypeRef)) \
    X(unsigned, LLVMGetIntTypeWidth, (LLVMTypeRef)) \
    X(unsigned, LLVMGetVectorSize, (LLVMTypeRef)) \
    X(unsigned, LLVMGetArrayLength, (LLVMTypeRef)) \
    X(LLVMTypeRef, LLVMGetElementType, (LLVMTypeRef)) \
    X(unsigned, LLVMCountStructElementTypes, (LLVMTypeRef)) \
    X(LLVMTypeRef, LLVMStructGetTypeAtIndex, (LLVMTypeRef, unsigned)) \
    X(unsigned, LLVMGetPointerAddressSpace, (LLVMTypeRef)) \
    X(unsigned, LLVMCountParams, (LLVMValueRef)) \
    X(LLVMValueRef, LLVMGetParam, (LLVMValueRef, unsigned)) \
    X(LLVMBasicBlockRef, LLVMGetFirstBasicBlock, (LLVMValueRef)) \
    X(LLVMBasicBlockRef, LLVMGetNextBasicBlock, (LLVMBasicBlockRef)) \
    X(LLVMValueRef, LLVMGetFirstInstruction, (LLVMBasicBlockRef)) \
    X(LLVMValueRef, LLVMGetNextInstruction, (LLVMValueRef)) \
    X(LLVMValueRef, LLVMGetBasicBlockTerminator, (LLVMBasicBlockRef)) \
    X(LLVMOpcode, LLVMGetInstructionOpcode, (LLVMValueRef)) \
    X(int, LLVMGetNumOperands, (LLVMValueRef)) \
    X(LLVMValueRef, LLVMGetOperand, (LLVMValueRef, unsigned)) \
    X(LLVMIntPredicate, LLVMGetICmpPredicate, (LLVMValueRef)) \
    X(LLVMRealPredicate, LLVMGetFCmpPredicate, (LLVMValueRef)) \
    X(unsigned, LLVMGetNumIndices, (LLVMValueRef)) \
    X(const unsigned *, LLVMGetIndices, (LLVMValueRef)) \
    X(LLVMValueRef, LLVMGetCalledValue, (LLVMValueRef)) \
    X(unsigned, LLVMGetNumArgOperands, (LLVMValueRef)) \
    X(unsigned, LLVMCountIncoming, (LLVMValueRef)) \
    X(LLVMValueRef, LLVMGetIncomingValue, (LLVMValueRef, unsigned)) \
    X(LLVMBasicBlockRef, LLVMGetIncomingBlock, (LLVMValueRef, unsigned)) \
    X(unsigned, LLVMGetNumSuccessors, (LLVMValueRef)) \
    X(LLVMBasicBlockRef, LLVMGetSuccessor, (LLVMValueRef, unsigned)) \
    X(LLVMBool, LLVMIsConditional, (LLVMValueRef)) \
    X(LLVMValueRef, LLVMGetCondition, (LLVMValueRef)) \
    X(LLVMBasicBlockRef, LLVMValueAsBasicBlock, (LLVMValueRef)) \
    X(LLVMTypeRef, LLVMGetAllocatedType, (LLVMValueRef)) \
    X(LLVMValueRef, LLVMIsAConstantInt, (LLVMValueRef)) \
    X(LLVMValueRef, LLVMIsAConstantFP, (LLVMValueRef)) \
    X(LLVMValueRef, LLVMIsAConstant, (LLVMValueRef)) \
    X(LLVMValueRef, LLVMIsAConstantDataSequential, (LLVMValueRef)) \
    X(LLVMValueRef, LLVMIsAConstantVector, (LLVMValueRef)) \
    X(LLVMValueRef, LLVMIsAConstantStruct, (LLVMValueRef)) \
    X(LLVMValueRef, LLVMIsAConstantArray, (LLVMValueRef)) \
    X(LLVMValueRef, LLVMIsAConstantAggregateZero, (LLVMValueRef)) \
    X(LLVMValueRef, LLVMIsAConstantPointerNull, (LLVMValueRef)) \
    X(LLVMValueRef, LLVMIsAConstantExpr, (LLVMValueRef)) \
    X(LLVMValueRef, LLVMIsAGlobalVariable, (LLVMValueRef)) \
    X(LLVMValueRef, LLVMIsAFunction, (LLVMValueRef)) \
    X(LLVMValueRef, LLVMIsAArgument, (LLVMValueRef)) \
    X(LLVMValueRef, LLVMIsAInstruction, (LLVMValueRef)) \
    X(LLVMBool, LLVMIsUndef, (LLVMValueRef)) \
    X(LLVMOpcode, LLVMGetConstOpcode, (LLVMValueRef)) \
    X(LLVMValueRef, LLVMGetInitializer, (LLVMValueRef)) \
    X(LLVMValueRef, LLVMGetElementAsConstant, (LLVMValueRef, unsigned)) \
    X(long long, LLVMConstIntGetSExtValue, (LLVMValueRef)) \
    X(unsigned long long, LLVMConstIntGetZExtValue, (LLVMValueRef)) \
    X(double, LLVMConstRealGetDouble, (LLVMValueRef, LLVMBool *)) \
    X(unsigned, LLVMGetAlignment, (LLVMValueRef)) \
    X(void *, LLVMGetFirstUse, (LLVMValueRef)) \
    X(LLVMBool, LLVMLinkModules2, (LLVMModuleRef, LLVMModuleRef)) \
    X(LLVMValueRef, LLVMGetNamedFunction, (LLVMModuleRef, const char *)) \
    X(LLVMValueRef, LLVMGetFirstFunction, (LLVMModuleRef)) \
    X(LLVMValueRef, LLVMGetNextFunction, (LLVMValueRef)) \
    X(LLVMBool, LLVMIsDeclaration, (LLVMValueRef)) \
    X(void, LLVMSetValueName2, (LLVMValueRef, const char *, size_t)) \
    X(void, LLVMSetLinkage, (LLVMValueRef, int)) \
    X(int, LLVMGetLinkage, (LLVMValueRef)) \
    X(void, LLVMReplaceAllUsesWith, (LLVMValueRef, LLVMValueRef)) \
    X(void, LLVMDeleteFunction, (LLVMValueRef)) \
    X(LLVMValueRef, LLVMConstBitCast, (LLVMValueRef, LLVMTypeRef)) \
    X(LLVMValueRef, LLVMGetFirstGlobal, (LLVMModuleRef)) \
    X(LLVMValueRef, LLVMGetNextGlobal, (LLVMValueRef)) \
    X(void *, LLVMGetNextUse, (void *)) \
    X(LLVMValueRef, LLVMGetUser, (void *))

typedef struct LLVMOpaqueAttributeRef *LLVMAttributeRef;
// Optional: resolved when present (NULL otherwise); used for forced inlining.
#define TS_LLVM_OPTIONAL_FUNCS(X) \
    X(unsigned, LLVMGetEnumAttributeKindForName, (const char *, size_t)) \
    X(void, LLVMRemoveEnumAttributeAtIndex, (LLVMValueRef, unsigned, unsigned)) \
    X(LLVMAttributeRef, LLVMCreateEnumAttribute, (LLVMContextRef, unsigned, uint64_t)) \
    X(void, LLVMAddAttributeAtIndex, (LLVMValueRef, unsigned, LLVMAttributeRef)) \
    X(LLVMContextRef, LLVMGetModuleContext, (LLVMModuleRef)) \
    /* new pass manager and opaque-pointer era (macOS); iOS 16's libLLVM (~LLVM 11, typed pointers) has the legacy ones */ \
    X(LLVMPassBuilderOptionsRef, LLVMCreatePassBuilderOptions, (void)) \
    X(void, LLVMDisposePassBuilderOptions, (LLVMPassBuilderOptionsRef)) \
    X(LLVMErrorRef, LLVMRunPasses, (LLVMModuleRef, const char *, void *, LLVMPassBuilderOptionsRef)) \
    X(char *, LLVMGetErrorMessage, (LLVMErrorRef)) \
    X(void, LLVMDisposeErrorMessage, (char *)) \
    X(LLVMTypeRef, LLVMGetGEPSourceElementType, (LLVMValueRef)) \
    X(unsigned, LLVMGetNumMaskElements, (LLVMValueRef)) \
    X(int, LLVMGetMaskValue, (LLVMValueRef, unsigned)) \
    X(LLVMBool, LLVMIsPoison, (LLVMValueRef)) \
    X(LLVMAttributeRef, LLVMGetStringAttributeAtIndex, (LLVMValueRef, unsigned, const char *, unsigned)) \
    X(const char *, LLVMGetStringAttributeValue, (LLVMAttributeRef, unsigned *)) \
    X(LLVMPassManagerRef, LLVMCreatePassManager, (void)) \
    X(LLVMBool, LLVMRunPassManager, (LLVMPassManagerRef, LLVMModuleRef)) \
    X(void, LLVMDisposePassManager, (LLVMPassManagerRef)) \
    X(void, LLVMAddAlwaysInlinerPass, (LLVMPassManagerRef)) \
    X(void, LLVMAddFunctionInliningPass, (LLVMPassManagerRef)) \
    X(void, LLVMAddScalarReplAggregatesPass, (LLVMPassManagerRef)) \
    X(void, LLVMAddPromoteMemoryToRegisterPass, (LLVMPassManagerRef)) \
    X(void, LLVMAddEarlyCSEPass, (LLVMPassManagerRef)) \
    X(void, LLVMAddInstructionCombiningPass, (LLVMPassManagerRef)) \
    X(void, LLVMAddDeadStoreEliminationPass, (LLVMPassManagerRef)) \
    X(void, LLVMAddAggressiveDCEPass, (LLVMPassManagerRef)) \
    X(void, LLVMAddCFGSimplificationPass, (LLVMPassManagerRef))

#define TS_LLVM_DECLARE(ret, name, args) extern ret (*ts_##name) args;
TS_LLVM_FUNCS(TS_LLVM_DECLARE)
TS_LLVM_OPTIONAL_FUNCS(TS_LLVM_DECLARE)
#undef TS_LLVM_DECLARE

// Loads libLLVM and resolves every function above; returns 0 (with a reason) if anything is missing.
int vmg_llvm_load(const char **error);

// A1 (vmg_air.c): bitcode parsed, visible functions linked, everything inlined into the entry point, IR cleaned.
// Shared by the AIR -> NIR translator and the AIR -> Valhall ISA compiler (driver/isa).
bool vmg_air_module_load(const vmg_air_input *in, LLVMContextRef *ctx, LLVMModuleRef *mod, char **error);
void vmg_air_module_free(LLVMContextRef ctx, LLVMModuleRef mod);
