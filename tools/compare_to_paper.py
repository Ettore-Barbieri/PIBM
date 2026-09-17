#!/usr/bin/env python3
"""Compare a PIBM BATS run against the published output shipped in Run/.

PIBM is stochastic: random_seed() at Main.f90:20 draws from OS entropy, and the
initial trait assignment, the vertical random walk and mutation are all random.
A rerun is therefore never bit-identical to the paper's -- not even for the
authors. This script separates the two things that can be checked:

  Tier 1  Prescribed forcing and grid (Temp, Kv, Z_r, Z_w). These do not depend
          on the random draw, so they must match to round-off. A failure here
          means the configuration, forcing files or grid are wrong -- not that
          the run is merely a different realisation.

  Tier 2  Biological fields and trait diagnostics. These differ between
          realisations, so a bare percentage is meaningless on its own. The
          script calibrates against the authors' own variant runs
          (Euler_5K/10K/50K.nc, the same experiment at other super-individual
          counts) and reports whether each deviation falls inside the span
          those runs already show relative to Euler.nc.

Usage:
    python3 tools/compare_to_paper.py [new.nc] [reference.nc]

Defaults: Run_BATS/Euler.nc against Run/Euler.nc
Requires netCDF4:  python3 -m venv ~/.venvs/pibm && ~/.venvs/pibm/bin/pip install netCDF4
"""
import os
import sys
import numpy as np

try:
    import netCDF4 as nc
except ImportError:
    sys.exit("netCDF4 not found. See the header of this file for a venv one-liner.")

DETERMINISTIC = ["Z_r", "Z_w", "Temp", "Kv"]
FIELDS = ["NO3", "CHL", "NPP", "PC", "PN", "DET",
          "Topt_avg", "CDiv_avg", "Lnalpha_avg"]
SEASONAL = ["CHL", "NPP", "NO3"]
VARIANTS = [("5K", "Euler_5K.nc"), ("10K", "Euler_10K.nc"), ("50K", "Euler_50K.nc")]

YEAR, TOL, SURF = 365, 1e-10, -50.0


def rule(title):
    print(f"\n{title}\n{'-' * len(title)}")


def final_year_mean(d, f):
    return float(np.asarray(d[f][-YEAR:]).mean())


def climatology(d, f, surf, years=3):
    v = np.asarray(d[f][:])
    n = YEAR * years
    if v.shape[0] < n:
        years = v.shape[0] // YEAR
        n = YEAR * years
    if years < 1:
        return None
    return v[-n:, surf].mean(axis=1).reshape(years, YEAR).mean(axis=0)


def main():
    new_f = sys.argv[1] if len(sys.argv) > 1 else "Run_BATS/Euler.nc"
    ref_f = sys.argv[2] if len(sys.argv) > 2 else "Run/Euler.nc"

    a, b = nc.Dataset(new_f), nc.Dataset(ref_f)
    print("PIBM BATS run vs published reference")
    print(f"  new run   : {new_f}  ({a.dimensions['Time'].size} records)")
    print(f"  reference : {ref_f}  ({b.dimensions['Time'].size} records)")

    # ---------------- Tier 1 ----------------
    failures = []
    rule("Tier 1 - prescribed forcing and grid (must match)")
    for v in DETERMINISTIC:
        if v not in a.variables or v not in b.variables:
            print(f"  {v:<12} not present in both files -- skipped")
            continue
        x, y = np.asarray(a[v][:]), np.asarray(b[v][:])
        if x.shape != y.shape:
            n = min(x.shape[0], y.shape[0])
            x, y = x[:n], y[:n]
        d = float(np.abs(x - y).max())
        ok = d / (float(np.abs(y).max()) or 1.0) < TOL
        print(f"  {v:<12} max|diff| = {d:.3e}   {'OK' if ok else '*** MISMATCH ***'}")
        if not ok:
            failures.append(v)
    if failures:
        print(f"\n  {', '.join(failures)} differ. These do not depend on the random draw,")
        print("  so this is a configuration problem: check param.nml, time.nml, the")
        print("  BATS_*.dat forcing files, and that NZOO = 20.")
    else:
        print("\n  Grid and forcing reproduce exactly -- the configuration matches.")

    # ------------- calibration from the authors' own runs -------------
    surf = np.asarray(b["Z_r"][:]) >= SURF
    refm = {f: final_year_mean(b, f) for f in FIELDS if f in b.variables}
    refc = {f: climatology(b, f, surf) for f in SEASONAL if f in b.variables}

    refdir = os.path.dirname(os.path.abspath(ref_f))
    spans, rspans, found = {}, {}, []
    for tag, fname in VARIANTS:
        path = os.path.join(refdir, fname)
        if not os.path.exists(path):
            continue
        d = nc.Dataset(path)
        found.append(tag)
        for f in refm:
            if f in d.variables:
                spans.setdefault(f, []).append(
                    (final_year_mean(d, f) - refm[f]) / abs(refm[f]) * 100)
        for f in refc:
            if f in d.variables and refc[f] is not None:
                c = climatology(d, f, surf)
                if c is not None:
                    rspans.setdefault(f, []).append(float(np.corrcoef(c, refc[f])[0, 1]))
        d.close()

    # ---------------- Tier 2 ----------------
    rule("Tier 2 - biological fields and traits, final-year column means")
    if found:
        print(f"  Calibrated against the authors' own {', '.join(found)} runs, which differ")
        print(f"  from {os.path.basename(ref_f)} by the amounts in the last column.\n")
        head = f"  {'field':<12}{'new':>10}{'reference':>11}{'difference':>12}   {'authors own span':<20}"
    else:
        print("  No Euler_*K.nc variant runs found alongside the reference, so there is")
        print("  no calibration for these differences -- judge them in context.\n")
        head = f"  {'field':<12}{'new':>10}{'reference':>11}{'difference':>12}"
    print(head)

    outside = []
    for f in FIELDS:
        if f not in a.variables or f not in refm:
            continue
        x = final_year_mean(a, f)
        dev = (x - refm[f]) / abs(refm[f]) * 100
        line = f"  {f:<12}{x:10.4f}{refm[f]:11.4f}{dev:>+11.1f}%"
        if f in spans:
            lo, hi = min(spans[f]), max(spans[f])
            inside = lo <= dev <= hi
            line += f"   {lo:+.1f}% .. {hi:+.1f}%".ljust(23) + ("inside" if inside else "OUTSIDE")
            if not inside:
                outside.append(f)
        print(line)

    # ---------------- seasonal cycle ----------------
    rule(f"Tier 2 - seasonal cycle, surface {abs(SURF):.0f} m, final 3 years")
    for f in SEASONAL:
        if f not in a.variables or f not in refc or refc[f] is None:
            continue
        ca = climatology(a, f, surf)
        if ca is None:
            print(f"  {f:<12} not enough years to form a climatology")
            continue
        r = float(np.corrcoef(ca, refc[f])[0, 1])
        line = (f"  {f:<12} r = {r:5.3f}   amplitude  new {ca.max()-ca.min():7.3f}"
                f"   ref {refc[f].max()-refc[f].min():7.3f}")
        if f in rspans:
            line += f"   authors own: {min(rspans[f]):.3f} .. {max(rspans[f]):.3f}"
        print(line)

    # ---------------- verdict ----------------
    rule("Verdict")
    if failures:
        print("  TIER 1 FAILED. Fix the configuration before interpreting anything else.")
    elif not found:
        print("  Tier 1 passed. No calibration runs available for Tier 2.")
    elif not outside:
        print("  Tier 1 exact, and every Tier 2 field falls inside the span the authors'")
        print("  own runs already show. This run is consistent with the published output.")
    else:
        print(f"  Tier 1 exact. {', '.join(outside)} fall outside the authors' span.")
        print("  That span comes from only a few runs and conflates super-individual")
        print("  count with stochastic spread, so a small excursion is not a failure --")
        print("  but check whether the affected fields move together in a physically")
        print("  coherent way (cell size, C:Chl and production co-vary) or independently.")
    print("\n  The seasonal correlation is stronger evidence than any column mean: it")
    print("  shows the run reproduces the published behaviour, which is what the")
    print("  paper's figures actually display. For those figures, the MATLAB (FIG*.m)")
    print("  and R scripts in Run/ regenerate the paper's panels from an Euler.nc.")

    a.close()
    b.close()
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
