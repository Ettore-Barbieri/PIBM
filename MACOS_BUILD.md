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
| `-xHost` | `-mcpu=native` (arm64) / `-march=native` (x86_64), auto-detected |
| `module load netcdf/...`, hard-coded paths | `nf-config` / `nc-config` |
| explicit `-L$MPIDIR/lib -lmpi` | handled by the `mpif90` wrapper |

### Moving to another Mac

The scripts are self-contained; nothing is hard-coded to a particular machine.

```bash
git clone https://github.com/Ettore-Barbieri/PIBM.git
cd PIBM && git checkout macos-port
brew install gcc open-mpi netcdf netcdf-fortran
./build-macos.sh Run_simple
./run-macos.sh  Run_simple            # or: ./run-macos.sh Run_simple <nranks>
```

Both Apple Silicon and Intel Macs work: `build-macos.sh` picks `-mcpu=native`
or `-march=native` from `uname -m`, and netCDF paths come from `nf-config` /
`nc-config`, so the Homebrew prefix (`/opt/homebrew` vs `/usr/local`) does not
matter. Rebuild on the target machine rather than copying the `IBM` binary —
`-m*=native` bakes in CPU-specific instructions.

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

Match `-np` to the number of **performance** cores
(`sysctl -n hw.perflevel0.logicalcpu`); on an Intel Mac use physical cores,
`sysctl -n hw.physicalcpu`. Measured on an M2 (4 P-cores) for the random-walk
phase, which is the only MPI-parallel part:

| ranks | random walk |
|---|---|
| 1 (serial) | 0.045 h |
| 4 | 0.012 h (3.7×) |
| 5 | 0.012 h (no gain, I/O worsens) |

Everything else — biology, Eulerian physics, all netCDF I/O — runs on the
master rank only, so total speedup is bounded well below the rank count. A
machine with more cores will help less than you would expect; single-core
speed and disk throughput matter more. OpenMPI also busy-waits, so idle ranks
still burn 100% CPU — do not run two configurations concurrently.

`run-macos.sh` now picks this number itself (`hw.perflevel0.logicalcpu`,
falling back to `hw.physicalcpu`); pass a second argument to override it.

Section 7 has measured timings for full-length runs of both configurations.

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

## 7. Performance changes

Two hot spots were fixed. Both are pure restructuring: the arithmetic and the
bytes written are unchanged, and output is **bit-identical** (verified — see
below).

**netCDF particle output (`netcdf_IO.f90`).** `write_PHY_particlefile` issued
one `NF90_PUT_VAR` per particle *per variable* — 15 x 20 000 = 300 000 library
calls for every saved record, each with its own bounds-checking and offset
bookkeeping. `write_Pass_particlefile` did the same (3 x 1 000). Both now gather
each field into a contiguous buffer and write the whole `(N x 1)` slab in a
single call: **303 000 calls per record become 18**.

**Grid-cell lookup (`lagrange.f90`).** The random walk located each particle's
cell with a linear scan over all `nlev` levels, run *twice* per sub-step — with
`Nrand = 200` and 21 000 particles that is ~840 million comparisons per
biological timestep. `Z_w` is monotonic and a particle moves only a fraction of
a cell per sub-step, so the search now starts from the cell the particle was
already in and walks outward, which is O(1) in practice. It returns exactly the
same index, including the tie-break to the lowest valid cell when a particle
lands precisely on a cell face.

Measured on 4 simulated days, `-np 4`, hourly particle output:

| phase | before | after | speedup |
|---|---|---|---|
| saving data | 0.052 h | 0.002 h | 26x |
| random walk | 0.015 h | 0.007 h | 2.1x |
| biology | 0.001 h | 0.001 h | - |
| **total wall** | **297 s** | **48 s** | **6.2x** |

The gain is largest in the final year, which writes particles hourly and was
overwhelmingly I/O-bound.

### Production timings

Full `NDay_Run = 2190` (six-year) runs of both configurations with the
optimised code, on a Mac Studio with 12 performance cores:

| phase | `Run_simple`, `-np 4` | BATS, `-np 12` |
|---|---|---|
| Biology | 0.209 h | 1.821 h |
| Random walk | 1.857 h | 0.650 h |
| Saving data | 0.534 h | 0.539 h |
| Environmental interpolation | 0.131 h | 0.140 h |
| Diffusion / detritus sinking | 0.001 h | 0.002 h |
| **Total wall** | **2.73 h** | **3.15 h** |

Total nitrogen was conserved to the printed precision (a single value,
`431.6720`, across all 2190 days) in both runs, and each produced ~12 GB of
output.

Three things worth taking from this:

**Rank scaling of the random walk is near-linear.** 1.857 h at 4 ranks to
0.650 h at 12 is 95% of ideal. The missing 5% is the serial `MPI_SEND` loop at
the top of `LAGRANGE`, in which the master sends the full particle arrays to
each worker in turn — its cost grows with the rank count.

**Biology costs 8.7x more for `Model_ID = 8` than for `Model_ID = 1`**
(0.209 h against 1.821 h): three evolving traits with mutation, and 20
zooplankton size classes rather than 1. Short test runs badly under-predict
this — an earlier estimate from a few simulated days put it at ~5x.

**The profile inverts between the two configurations.** In `Run_simple` the
random walk is 68% of the runtime and scales with cores. In BATS it is 21%,
while the serial part — biology, saving and interpolation, all of which run on
the master rank — is 2.50 h of the 3.15 h total. Adding cores to a BATS run
therefore buys very little, and 2.50 h is its floor.

The only remaining target of any size is `BIOLOGY`, which is not parallelised.
Distributing its per-particle loop the way `LAGRANGE` already distributes the
random walk would be a structural change to the science code rather than a
tweak, and is not attempted here.

### Verifying that results are unchanged

`random_seed()` is called with no arguments (`Main.f90:20`), which seeds from OS
entropy, so ordinary runs are not reproducible. To compare two builds, pin the
seed in a *scratch copy* of the tree (do not commit it):

```fortran
block
  integer :: sd_n
  integer, allocatable :: sd(:)
  call random_seed(size=sd_n)
  allocate(sd(sd_n))
  sd = 20260916
  call random_seed(put=sd)
end block
```

With that in place, two independent runs of the same build produce byte-for-byte
identical `Euler.nc`, `ParY1.nc` and `PassY1.nc`, so `md5` on those files is a
sound regression check. The optimisations above were confirmed identical this
way against the unmodified upstream code.

## 8. Comparing a run against the published output

`Run/` ships the authors' own BATS output: `Euler.nc` is a full six-year
`Model_ID = 8` run (2192 records, `NZOO = 20`), with `Euler_5K.nc`,
`Euler_10K.nc` and `Euler_50K.nc` the same experiment at other super-individual
counts. This is the reference to compare a local run against, and the reason
`Run/` is kept pristine and runs go in `Run_BATS/`.

**A rerun is never bit-identical to the paper**, not even for the authors:
`random_seed()` at `Main.f90:20` draws from OS entropy, and the initial trait
assignment, the vertical random walk and mutation are all stochastic. Only two
things can be checked, and `tools/compare_to_paper.py` separates them:

```bash
python3 -m venv ~/.venvs/pibm && ~/.venvs/pibm/bin/pip install netCDF4
~/.venvs/pibm/bin/python tools/compare_to_paper.py Run_BATS/Euler.nc Run/Euler.nc
```

**Tier 1 -- prescribed forcing and grid** (`Z_r`, `Z_w`, `Temp`, `Kv`). These do
not depend on the random draw and must reproduce to round-off. A mismatch means
the configuration is wrong -- wrong namelist, wrong forcing files, or
`NZOO != 20` -- rather than a different realisation. This is pass/fail.

**Tier 2 -- biological fields and traits** (`NO3`, `CHL`, `NPP`, `PC`, `PN`,
`DET`, `Topt_avg`, `CDiv_avg`, `Lnalpha_avg`). These differ between
realisations and are not supposed to match. The useful yardstick is the spread
among the authors' own published runs: comparing `Euler_5K.nc` against
`Euler.nc` gives

| | |
|---|---|
| Tier 1 fields | identical to round-off |
| Final-year means | up to 16% apart (`PN` -15.9%, `CHL` -14.6%, `NO3` +1.0%) |
| Seasonal cycle correlation | `r` = 0.92 (CHL), 0.99 (NPP), 1.00 (NO3) |

So differences of a few percent to the mid-teens on final-year means are
ordinary. The stronger evidence is the seasonal cycle: a high correlation with
a similar amplitude means the run reproduces the published *behaviour*, which
is what the paper's figures actually show.

For the figures themselves, the MATLAB (`FIG*.m`) and R (`Fig4_BATS_obs_mod_knn.R`,
`Fig10Size_spectra.R`, `Rao2D.R`) scripts in `Run/` regenerate the paper's
panels, and the observational data they validate against (`bats_NO3.csv`,
`bats_pigments.csv`, `BATS_Primary_Production.csv`, `*knn.csv`) is alongside
them. Point those at your own `Euler.nc` and compare against the published
figures.

## 9. Discrepancy in the README

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

## 10. Verification performed

- Total nitrogen conserved exactly (431.6720 every day, both configurations).
- Nitrate depleted at the surface, increasing with depth; Chl ≈ 0.15 mg m⁻³ —
  consistent with oligotrophic BATS.
- No NaNs in any Eulerian field.
- Serial (`./IBM`) and MPI (`mpirun -np N`) give the same behaviour.
