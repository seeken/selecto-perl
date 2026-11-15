#include "EXTERN.h"
#include "perl.h"
#include "XSUB.h"

/* Work on private scalar copies: stringification must not change the driver's
 * dualvar or numeric caches. Unsupported columns fall back before any edit.
 * No SQL, session state, encoding decoding, JSON parsing or dates live here. */
static int
plain_column(AV *rows, SSize_t column, int kind)
{
    SSize_t r, n = av_len(rows);
    if (SvMAGICAL((SV *)rows)) return 0;
    for (r = 0; r <= n; r++) {
        SV **rp = av_fetch(rows, r, 0), **cell;
        if (!rp || !SvROK(*rp) || SvTYPE(SvRV(*rp)) != SVt_PVAV
            || SvMAGICAL(SvRV(*rp))) return 0;
        cell = av_fetch((AV *)SvRV(*rp), column, 0);
        if (!cell || SvMAGICAL(*cell) || SvROK(*cell)) return 0;
        if (!SvOK(*cell)) continue;
        if (kind == 2) {
            if (!SvIOK(*cell) || SvPOK(*cell)) return 0;
        } else if (kind != 3) {
            SV *copy = sv_2mortal(newSVsv(*cell));
            STRLEN len, j;
            const char *p = SvPV(copy, len);
            for (j = 0; j < len; j++) if ((U8)p[j] >= 128) return 0;
        }
    }
    return 1;
}

MODULE = Selecto PACKAGE = Selecto::PostgreSQL::CanonicalXS
PROTOTYPES: DISABLE

int
convert_column(SV *rows_ref, IV column, IV kind)
    PREINIT:
        AV *rows;
        SSize_t r, n;
    CODE:
        RETVAL = 0;
        if (column >= 0 && kind >= 0 && kind <= 3 && SvROK(rows_ref)
            && SvTYPE(SvRV(rows_ref)) == SVt_PVAV) {
            rows = (AV *)SvRV(rows_ref);
            if (plain_column(rows, column, kind)) {
                RETVAL = 1;
                n = av_len(rows);
                for (r = 0; kind != 2 && r <= n; r++) {
                    AV *row = (AV *)SvRV(*av_fetch(rows, r, 0));
                    SV *cell = *av_fetch(row, column, 0), *copy, *out;
                    STRLEN len, end, j;
                    const char *p;
                    int utf8;
                    if (!SvOK(cell)) continue;
                    copy = sv_2mortal(newSVsv(cell));
                    p = SvPV(copy, len);
                    utf8 = SvUTF8(copy) ? 1 : 0;
                    end = len;
                    if (kind == 3) {
                        out = newSViv(len == 1 && (p[0] == 't' || p[0] == '1') ? 1 : 0);
                    } else if (kind == 0) {
                        /* The decimal suffix regex has ASCII digit semantics
                         * here; Unicode values already took the Perl fallback. */
                        j = end;
                        while (j && p[j-1] >= '0' && p[j-1] <= '9') j--;
                        if (j && p[j-1] == '.') {
                            while (end > j && p[end-1] == '0') end--;
                        }
                        if (end && p[end-1] == '.') end--;
                        if (end == 2 && p[0] == '-' && p[1] == '0') {
                            out = newSVpvn("0", 1);
                            utf8 = 0;
                        } else out = newSVpvn(p, end);
                        if (utf8) SvUTF8_on(out);
                    } else {
                        STRLEN suffix = 0;
                        if (end >= 6 && memEQ(p + end - 6, "+00:00", 6)) suffix = 6;
                        else if (end >= 3 && memEQ(p + end - 3, "+00", 3)) suffix = 3;
                        else if (end && p[end-1] == 'Z') suffix = 1;
                        if (suffix) {
                            end -= suffix;
                            j = end;
                            while (j && p[j-1] == '0') j--;
                            if (j < end && j && p[j-1] == '.') end = j-1;
                        }
                        out = newSVpvn(p, end);
                        for (j = 0; j < end; j++) if (SvPVX(out)[j] == ' ') SvPVX(out)[j] = 'T';
                        if (utf8) SvUTF8_on(out);
                    }
                    /* av_store takes ownership of out and releases old cell. */
                    if (!av_store(row, column, out)) SvREFCNT_dec(out);
                }
            }
        }
    OUTPUT:
        RETVAL
