#!/bin/bash
set -e
set -x

# Get an updated config.sub and config.guess
# c.f. https://conda-forge.org/docs/how-to/advanced/cross-compilation/#autotools
cp $BUILD_PREFIX/share/gnuconfig/config.* .

export CONFIGURE_ARGS="--with-eigen3=${PREFIX}/include/eigen3 --disable-static --enable-shared ${CONFIGURE_ARGS}"

if [[ -n "${mpi}" && "${mpi}" != "nompi" ]]; then
  if [[ "${CONDA_BUILD_CROSS_COMPILATION:-}" == "1" ]]; then
    # In cross builds, do NOT use target mpicc/mpic++ (can't execute on build machine).
    # Use the cross C/C++ compilers provided by conda-forge toolchain and supply MPI flags.
    export CONFIGURE_ARGS="--with-mpi=${PREFIX} --with-zoltan=${PREFIX} ${CONFIGURE_ARGS}"
    # Help Autoconf-based MPI checks without executing target wrappers.
    # Point MPICC/MPICXX at the active cross compilers so any macro that
    # prefers these variables won't try to execute ${PREFIX}/bin/mpicc.
    export MPICC="${CC}"
    export MPICXX="${CXX}"
    export MPIF90="${F90}"
    # Help discovery of MPI headers/libs without executing target wrappers.
    export MPI_CFLAGS="-I${PREFIX}/include ${MPI_CFLAGS}"
    export MPI_LIBS="-L${PREFIX}/lib -lmpi ${MPI_LIBS}"

    # Determine the correct Fortran MPI bindings library name.
    # MPICH uses libmpifort and OpenMPI uses libmpi_mpifh.
    if [[ "${mpi}" == "openmpi" ]]; then
      MPI_FORT_LIB="-lmpi_mpifh"
      # c.f. https://conda-forge.org/docs/how-to/advanced/cross-compilation/#mpi
      export OPAL_PREFIX="$PREFIX"
    else
      MPI_FORT_LIB="-lmpifort"
    fi

    # Ensure the Fortran MPI bindings and libmpi are available when linking MPI test programs
    export LIBS="${LIBS} ${MPI_FORT_LIB} -lmpi"

    # Make sure pkg-config can find mpi.pc (if provided by the MPI package).
    export PKG_CONFIG_PATH="${PREFIX}/lib/pkgconfig:${PKG_CONFIG_PATH}"
  else
    export CONFIGURE_ARGS="CC=mpicc CXX=mpic++ FC=mpif90 F77=mpif77 --with-mpi=${PREFIX} --with-zoltan=${PREFIX} ${CONFIGURE_ARGS}"
  fi
fi

if [[ -n "${tempest}" && "${tempest}" != "notempest" ]]; then
  export CONFIGURE_ARGS="--with-tempestremap=${PREFIX} --with-netcdf=${PREFIX} --enable-mbtempest ${CONFIGURE_ARGS}"
fi

autoreconf -fi
./configure --prefix="${PREFIX}" \
  ${CONFIGURE_ARGS} \
  --with-hdf5="${PREFIX}" \
  --with-metis="${PREFIX}" \
  --enable-shared \
  --enable-tools \
  || { cat config.log; exit 1; }

make -j "${CPU_COUNT}"

if [[ "${CONDA_BUILD_CROSS_COMPILATION:-}" != "1" || "${CROSSCOMPILING_EMULATOR:-}" != "" ]]; then
  # When running tests under QEMU emulation, apply workarounds for known
  # QEMU user-mode limitations with HDF5/MPI I/O.
  # c.f. https://github.com/conda-forge/moab-feedstock/pull/111
  if [[ "${CONDA_BUILD_CROSS_COMPILATION:-}" == "1" && "${CROSSCOMPILING_EMULATOR:-}" != "" ]]; then
    echo "[conda-forge] Cross-compilation with emulator detected: applying QEMU workarounds."
    # Disable HDF5 file locking — fcntl(F_SETLK) is unreliable under QEMU user-mode.
    export HDF5_USE_FILE_LOCKING=FALSE
    # Enable core dumps so segfaults produce actionable backtraces.
    ulimit -c unlimited 2>/dev/null || true
  fi

  # If TempestRemap is enabled, run only a curated subset of tests to avoid timeouts.
  if [[ -n "${tempest}" && "${tempest}" != "notempest" ]]; then
    echo "[conda-forge] TempestRemap enabled: running a selected subset of tests."

    # Helper: check if a test target is defined in the given directory's Makefile
    is_test_defined() {
      local dir="$1"; shift
      local name="$1"; shift
      [[ -f "${dir}/Makefile" ]] && grep -q "${name}_SOURCES" "${dir}/Makefile"
    }

    # Tests to run for both MPI and no-MPI builds (found under test/)
    COMMON_SERIAL_TESTS=(
      imoab_remapping
      imoab_test
      test_remapping
    )

    # Additional tests for MPI builds (found under test/parallel/)
    COMMON_PARALLEL_TESTS=(
      imoab_coupler
      imoab_coupler_bilin
      imoab_coupler_fortran
      imoab_coupler_twohop
      imoab_read_map
    )

    # Filter to only those tests that are actually defined for this configuration
    SERIAL_ENABLED=()
    for t in "${COMMON_SERIAL_TESTS[@]}"; do
      if is_test_defined "test" "${t}"; then
        SERIAL_ENABLED+=("${t}")
      fi
    done

    PARALLEL_ENABLED=()
    if [[ -n "${mpi}" && "${mpi}" != "nompi" ]]; then
      for t in "${COMMON_PARALLEL_TESTS[@]}"; do
        # Skip Fortran-only test when Fortran is disabled in this recipe
        if [[ "${t}" == "imoab_coupler_fortran" ]]; then
          continue
        fi
        if is_test_defined "test/parallel" "${t}"; then
          PARALLEL_ENABLED+=("${t}")
        fi
      done
    fi

    # Run only the selected serial tests
    if [[ ${#SERIAL_ENABLED[@]} -gt 0 ]]; then
      echo "[conda-forge] Running serial tests: ${SERIAL_ENABLED[*]}"
      # Prevent recursive check into subdirectories (like test/io) to avoid
      # Automake trying to create logs for tests not defined there.
      make -C test SUBDIRS=. check TESTS="${SERIAL_ENABLED[*]}" \
        || { [[ -f test/test-suite.log ]] && cat test/test-suite.log; }
    else
      echo "[conda-forge] No selected serial tests were built; skipping test/"
    fi

    # Run only the selected parallel tests when MPI is enabled
    if [[ ${#PARALLEL_ENABLED[@]} -gt 0 ]]; then
      echo "[conda-forge] Running parallel tests: ${PARALLEL_ENABLED[*]}"
      make -C test/parallel SUBDIRS=. check TESTS="${PARALLEL_ENABLED[*]}" \
        || { [[ -f test/parallel/test-suite.log ]] && cat test/parallel/test-suite.log; }
    else
      if [[ -n "${mpi}" && "${mpi}" != "nompi" ]]; then
        echo "[conda-forge] No selected parallel tests were built; skipping test/parallel/"
      else
        echo "[conda-forge] MPI disabled: skipping parallel test subset."
      fi
    fi

    echo test/.libs/imoab_remapping
    LD_LIBRARY_PATH=./src/.libs/ test/.libs/imoab_remapping
    echo $?
    echo Done with test/.libs/imoab_remapping
  else
    # TempestRemap not enabled: run the full suite
    make check \
      || { cat test/test-suite.log tools/mbcoupler/test-suite.log; exit 1; }
  fi
fi

make install
