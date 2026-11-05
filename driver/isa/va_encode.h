// Valhall v9 instruction encoder (tables generated from Arm's isa-v9-v14.xml by gen_va_v9.py).
#pragma once
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include "va_v9_gen.h"

// Field values of one instruction, by field id (VAF_*); unset fields take their exact, computed or default value.
typedef struct {
    int64_t v[VAF_COUNT];
    uint8_t set[VAF_COUNT];
} va_vals;

void va_vals_init(va_vals *x);
static inline void va_set(va_vals *x, enum va_field f, int64_t val) { x->v[f] = val; x->set[f] = 1; }

// 0 and *out = the 64-bit instruction word, or -1 with a message in err.
int va_encode(enum va_op op, const va_vals *x, uint64_t *out, char *err, size_t errsz);
// Whether w has op's fixed fields (opcode bits) and zero reserved bits.
bool va_matches(enum va_op op, uint64_t w);
int64_t va_field_get(enum va_op op, uint64_t w, enum va_field field, bool *found);
bool va_has_field(enum va_op op, enum va_field field);

// Source operand byte (SourceEncoding).
#define VA_SRC_REG(r, last) ((uint8_t)(((last) ? 0x40 : 0) | ((r) & 63)))
#define VA_SRC_FAU(i) ((uint8_t)(0x80 | ((i) & 63)))            // user uniform word i % 64 (page = i / 64)
#define VA_SRC_IMM(i) ((uint8_t)(0xC0 | ((i) & 31)))            // hardware small-constant table entry (0 = zero)
#define VA_SRC_SPECIAL(i) ((uint8_t)(0xE0 | ((i) & 31)))        // special FAU (page in fau_page_index)
