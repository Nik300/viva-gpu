// TeraScale Metal Shim - driver log, shared with the files that cannot include TSPrivate.h (TSGlass.m uses the
// legacy OpenGL headers, which do not mix with gl3.h).
#pragma once
#import <Foundation/Foundation.h>

// Driver log: os_log subsystem com.terascale.mtlshim, one category per kind of event
// (docs/FASE4-INTERFACCE.md). Each call site logs at most TS_LOG_SITE_LIMIT lines per
// process, so a per-frame failure cannot flood the system log. General lines are info
// level and are only formatted when someone streams them. TSMTL_LOG=1 copies everything
// to stderr (injection tests).
typedef enum { TSLogGeneral, TSLogWarning, TSLogError, TSLogUnimplemented, TSLogPolicy, TSLogStats, TSLogCompute, TSLogGlass, TSLogSwift, TSLogCategoryCount } TSLogCategory;
#define TS_LOG_SITE_LIMIT 20
void TSMtlLogAt(TSLogCategory category, _Atomic uint32_t *site, NSString *fmt, ...) NS_FORMAT_FUNCTION(3, 4);
#define TS_LOG_AT(category, ...) do { static _Atomic uint32_t _tsLogSite; TSMtlLogAt(category, &_tsLogSite, __VA_ARGS__); } while (0)
#define TSMtlLog(...)    TS_LOG_AT(TSLogGeneral, __VA_ARGS__)
#define TSMtlWarn(...)   TS_LOG_AT(TSLogWarning, __VA_ARGS__)
#define TSMtlError(...)  TS_LOG_AT(TSLogError, __VA_ARGS__)
#define TSMtlUnimpl(...) TS_LOG_AT(TSLogUnimplemented, __VA_ARGS__)
#define TSMtlCompute(...) TS_LOG_AT(TSLogCompute, __VA_ARGS__)   // TeraScale Compute (docs/PIANO-COMPUTE.md)
#define TSMtlGlass(...) TS_LOG_AT(TSLogGlass, __VA_ARGS__)       // TeraScale Glass (docs/PIANO-GLASS.md)
#define TSMtlSwift(...) TS_LOG_AT(TSLogSwift, __VA_ARGS__)       // TeraScale Swift (docs/OTTIMIZZAZIONE-SWIFT.md)
extern int gTSMtlLogOn;   // TSMTL_LOG=1
