! Probe: does this compiler's MAX / MAXVAL hide NaN?
!
! In the C&D solver (T-0005) a diverged run "converged" with phi_M = w_M = 0
! because gfortran's MAX(a, NaN) returns a, MAXVAL ignores NaN, and NaN > 0 is
! false. Run this once per compiler/flags before trusting MAX-based
! convergence tests.
!
!   gfortran -O2 -o nan_max_probe nan_max_probe.f90 && ./nan_max_probe

PROGRAM NAN_MAX_PROBE
  USE, INTRINSIC :: IEEE_ARITHMETIC, ONLY: IEEE_VALUE, IEEE_QUIET_NAN, IEEE_IS_FINITE
  USE, INTRINSIC :: ISO_FORTRAN_ENV, ONLY: dp => REAL64
  IMPLICIT NONE
  REAL(dp), VOLATILE :: nan, a(3)   ! VOLATILE: defeat constant folding
  REAL(dp) :: m
  LOGICAL :: hidden

  nan = IEEE_VALUE(1.0_dp, IEEE_QUIET_NAN)
  a = [1.0_dp, nan, 2.0_dp]
  hidden = .FALSE.

  m = MAX(1.0_dp, nan)
  WRITE(*, '("MAX(1, NaN)        = ",G0)') m
  IF (IEEE_IS_FINITE(m)) hidden = .TRUE.

  m = MAX(nan, 1.0_dp)
  WRITE(*, '("MAX(NaN, 1)        = ",G0)') m
  IF (IEEE_IS_FINITE(m)) hidden = .TRUE.

  m = 0.0_dp
  m = MAX(m, ABS(a(2)))       ! running-max reduction, as in convergence loops
  WRITE(*, '("m=0; m=MAX(m,NaN)  = ",G0)') m
  IF (IEEE_IS_FINITE(m)) hidden = .TRUE.

  m = MAXVAL(ABS(a))
  WRITE(*, '("MAXVAL([1,NaN,2])  = ",G0)') m
  IF (IEEE_IS_FINITE(m)) hidden = .TRUE.

  WRITE(*, '("NaN > 0            = ",L1)') nan > 0.0_dp
  WRITE(*, '("SUM([1,NaN,2])     = ",G0,"   (SUM propagates NaN)")') SUM(a)

  IF (hidden) THEN
    WRITE(*, '("RESULT: MAX-style reductions HIDE NaN on this compiler -> use IEEE_IS_FINITE / SUM checks")')
  ELSE
    WRITE(*, '("RESULT: MAX-style reductions propagate NaN on this compiler")')
  END IF
END PROGRAM NAN_MAX_PROBE
