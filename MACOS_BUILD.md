# Building and running PIBM 1.0 on macOS (Apple Silicon)

Notes for running Sala & Chen (2025), *GMD* **18**, 4155, on macOS with the
Homebrew toolchain, replacing the cluster-specific `job-Archie` script.

---

## 1. Prerequisites

```bash
brew install gcc open-mpi netcdf netcdf-fortran
```

`netcdf-fortran` must be built against the *same* gfortran you compile with —
Homebrew guarantees this. Verify:

```bash
nf-config --fc      # should be /opt/homebrew/bin/gfortran
mpif90 --version    # same GCC major version
```

## 2. Build

`job-Archie` hard-codes Intel compilers (`mpiifort`), Intel-only flags
(`-r8 -i4 -xHost -fp-model=precise`) and the ARCHIE-WeSt module system, so it
cannot run here. Use `build-macos.sh` instead:

```bash
./build-macos.sh Run_simple      # -> Run_simple/IBM
./build-macos.sh Run_BATS        # -> Run_BATS/IBM
Test=1 ./build-macos.sh Run_simple   # debug build: -fcheck=all, FPE traps
```

It keeps `job-Archie`'s structure (assemble a `Compile/` directory, substitute
flags into `src/Makefile`, build, move the executable up) but:

| job-Archie (Intel/ARCHIE) | build-macos.sh (Homebrew) |
|---|---|
| `mpiifort` | `mpif90` (gfortran) |
| `-r8 -i4` | `-fdefault-real-8 -fdefault-double-8` |
| `-xHost` | `-mcpu=native` |
| `module load netcdf/...`, hard-coded paths | `nf-config` / `nc-config` |
| explicit `-L$MPIDIR/lib -lmpi` | handled by the `mpif90` wrapper |

**Important:** the build copies `src/*.f90` first, then the run directory's own
`*.f90` on top. A run directory's `params.f90` / `variables.f90` therefore
*override* the `src/` versions — this is how a configuration is selected, and
it is why each configuration needs its own build.

## 3. Patch applied to the upstream source

`src/GMK98_Ind_Size.f90` — **added here; not in the upstream release.**

`src/Makefile` lists `GMK98_Ind_Size.f90` in `SRCS`, and `Geider_Lag.f90:325`
calls `GMK98_Ind_Size(...)` for `Model_ID = GMK98_Size`, but the file was never
committed (it is absent from the entire git history). Because these are
external subroutines with no interface blocks, compilation succeeds and the
**link** fails with an undefined symbol — for *every* `Model_ID`, including the
fully implemented ones.

The added file is a stub that stops with a clear message if reached, matching
the convention the other unimplemented branches of that `SELECT CASE` already
use (`stop "To be developed..."`). It invents no model formulation.

Neither target configuration reaches it: `Run_simple` uses `Model_ID = 1`,
BATS uses `Model_ID = 8`. Only `Model_ID = 3` would.

## 4. The two configurations

|  | `Run_simple` | `Run_BATS` (from `Run/`) |
|---|---|---|
| `Model_ID` | 1 — `GMK98_simple` | 8 — `GMK98_ToptSizeLight` |
| Traits | none | size (`Cdiv`), `Topt`, `alphaChl` |
| Mutation | off (`NTrait = 0`) | on (`NTrait = 3`, `nu = 1e-12`, `sigma = 0.1`) |
| Zooplankton | 1 class (own `variables.f90`) | 20 size classes, 0.8–3600 µm (`src/variables.f90`) |
| `QNmax` allometry | off (`QNmax_b = 0`) | on (`QNmax_b = -0.07`) |
| `mu0` | 2.0 d⁻¹ | 5.0 d⁻¹ |

`Run_simple` is the reduced NPZD-with-particles case; BATS is the full paper
configuration. `Run_BATS/` is a clean copy of `Run/`'s inputs — `Run/` itself
holds the authors' **published** `Euler.nc` (69 MB, git-tracked) and other
result files that a run there would silently overwrite. It has deliberately
**no** `variables.f90`, so it inherits `NZOO = 20` from `src/`.

## 5. Running

```bash
cd Run_simple
mpirun -np 4 ./IBM > out 2>&1
```

`-np 4` is the sweet spot on an M2 (4 performance cores). Measured on the
random-walk phase, which is the only MPI-parallel part:

| ranks | random walk |
|---|---|
| 1 (serial) | 0.045 h |
| 4 | 0.012 h (3.7×) |
| 5 | 0.012 h (no gain, I/O worsens) |

Everything else — biology, Eulerian physics, all netCDF I/O — runs on the
master rank only, so total speedup is bounded well below 4×.

## 6. Output, and a sizing trap

- `Euler.nc` — Eulerian fields (nutrient, ZOO, detritus, Chl, NPP …), daily.
- `ParY<n>.nc` — the 20 000 phytoplankton super-individuals.
- `PassY<n>.nc` — the 1 000 passive tracer particles.
- `restart.nc` — rewritten each save; set `read_previous_output = 1` in
  `time.nml` to continue from it.

`timestep.f90:78` saves particles **daily for every year except the last**,
where it switches to **hourly**:

```fortran
If (current_year < NDay_Run/365) then
   par_save_freq = d_per_s      ! daily
Else
   par_save_freq = s_per_h      ! hourly  <- final year
Endif
```

So for the default `NDay_Run = 2190` (6 years): years 1–5 ≈ 470 MB each,
year 6 ≈ 11 GB. Budget ~14 GB per run.

Note this uses **integer division**. Any `NDay_Run < 365` gives `0`, so a short
test run takes the *hourly* branch and writes ~24× more output than expected —
worth knowing when you shorten `NDay_Run` to test something.

## 7. Discrepancy in the README

`README.md` numbers the models differently from the code. `variables.f90` is
authoritative:

| | README | code (`variables.f90`) |
|---|---|---|
| `GMK98_Size` | 4 | **3** |
| `GMK98_Light` | 3 | **4** |
| `GMK98_ToptLight` | 6 | **5** |
| `GMK98_ToptSize` | 7 | **6** |
| `GMK98_SizeLight` | 5 | **7** |

`Model_ID = 8` (`ToptSizeLight`) agrees in both, so the BATS run is unaffected.

## 8. Verification performed

- Total nitrogen conserved exactly (431.6720 every day, both configurations).
- Nitrate depleted at the surface, increasing with depth; Chl ≈ 0.15 mg m⁻³ —
  consistent with oligotrophic BATS.
- No NaNs in any Eulerian field.
- Serial (`./IBM`) and MPI (`mpirun -np N`) give the same behaviour.
