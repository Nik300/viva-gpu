// Valhall v9 instruction encoder on the tables generated from Arm's ISA description (gen_va_v9.py).
#include "va_encode.h"
#include <stdio.h>
#include <string.h>

void va_vals_init(va_vals *x) { memset(x, 0, sizeof *x); }

int va_encode(enum va_op op, const va_vals *x, uint64_t *out, char *err, size_t errsz)
{
    const struct va_op_info *oi = &va_op_info[op];
    int64_t v[VAF_COUNT];
    memcpy(v, x->v, sizeof v);
    // Computed fields read the values of other fields (caller-set, exact or default): resolve those first.
    for (unsigned k = 0; k < oi->nfields; k++) {
        const struct va_field_info *f = &oi->fields[k];
        if (f->field == VAF_COUNT) continue;
        if (f->has_exact) v[f->field] = f->exact;
        else if (!x->set[f->field] && f->has_default) v[f->field] = f->def;
    }
    uint64_t w = 0;
    for (unsigned k = 0; k < oi->nfields; k++) {
        const struct va_field_info *f = &oi->fields[k];
        uint64_t mask = f->width >= 64 ? ~0ull : ((1ull << f->width) - 1);
        int64_t val;
        if (f->kind == VA_K_ZERO || f->kind == VA_K_IGNORE) val = 0;
        else if (f->has_exact) val = f->exact;
        else if (x->set[f->field]) val = x->v[f->field];
        else if (f->computed) val = oi->compute(f->field, v);
        else if (f->has_default) val = f->def;
        else if (f->field == VAF_flow || f->field == VAF_fau_page_index) val = 0;
        else {
            snprintf(err, errsz, "%s%s%s: field %s not set", oi->name, oi->variant ? "." : "", oi->variant ? oi->variant : "",
                     va_field_name[f->field]);
            return -1;
        }
        if (f->allowed && (val < 0 || val > 63 || !((f->allowed >> val) & 1))) {
            snprintf(err, errsz, "%s%s%s: field %s = %lld not allowed", oi->name, oi->variant ? "." : "", oi->variant ? oi->variant : "",
                     va_field_name[f->field], (long long)val);
            return -1;
        }
        if (f->align && (val % f->align)) {
            snprintf(err, errsz, "%s: field %s = %lld not aligned to %u", oi->name, va_field_name[f->field], (long long)val, f->align);
            return -1;
        }
        // align(n) is a constraint on the value, not a scale: Mesa packs 64-bit destinations as the plain register
        // index (va_pack_dest), and halving it wrote IMUL.u64 and other pair results to the wrong registers.
        if (f->shift) {
            if (val & ((1ll << f->shift) - 1)) {
                snprintf(err, errsz, "%s: field %s = %lld not a multiple of %u", oi->name, va_field_name[f->field], (long long)val, 1u << f->shift);
                return -1;
            }
            val >>= f->shift;
        }
        if (f->kind == VA_K_INT) {
            int64_t lo = -(1ll << (f->width - 1)), hi = (1ll << (f->width - 1)) - 1;
            if (val < lo || val > hi) {
                snprintf(err, errsz, "%s: field %s = %lld out of range", oi->name, va_field_name[f->field], (long long)val);
                return -1;
            }
        } else if ((uint64_t)val & ~mask) {
            snprintf(err, errsz, "%s: field %s = %lld does not fit %u bits", oi->name, va_field_name[f->field], (long long)val, f->width);
            return -1;
        }
        w |= ((uint64_t)val & mask) << f->pos;
    }
    *out = w;
    return 0;
}

bool va_matches(enum va_op op, uint64_t w)
{
    const struct va_op_info *oi = &va_op_info[op];
    for (unsigned k = 0; k < oi->nfields; k++) {
        const struct va_field_info *f = &oi->fields[k];
        uint64_t mask = f->width >= 64 ? ~0ull : ((1ull << f->width) - 1);
        uint64_t got = (w >> f->pos) & mask;
        if (f->kind == VA_K_IGNORE) continue;
        if (f->kind == VA_K_ZERO) { if (got) return false; continue; }
        if (f->has_exact && got != ((uint64_t)f->exact & mask)) return false;
    }
    return true;
}

int64_t va_field_get(enum va_op op, uint64_t w, enum va_field field, bool *found)
{
    const struct va_op_info *oi = &va_op_info[op];
    for (unsigned k = 0; k < oi->nfields; k++) {
        const struct va_field_info *f = &oi->fields[k];
        if (f->field != field) continue;
        uint64_t mask = f->width >= 64 ? ~0ull : ((1ull << f->width) - 1);
        int64_t val = (int64_t)((w >> f->pos) & mask);
        if (f->kind == VA_K_INT && (val >> (f->width - 1)) & 1) val -= (1ll << f->width);
        val <<= f->shift;
        if (found) *found = true;
        return val;
    }
    if (found) *found = false;
    return 0;
}

bool va_has_field(enum va_op op, enum va_field field)
{
    bool found;
    va_field_get(op, 0, field, &found);
    return found;
}
