! Test: Anderson acceleration converges where Picard iteration diverges.
!
! T(x) = J x + b + 0.05 sin(x_shifted), with J block-diagonal holding the
! modes seen in the Dean-flow outer iteration (docs/adsd/probe-validation.md):
! a complex pair 1.03*exp(+-i pi/4) (unstable, period ~8), a real -1.1
! (unstable, period 2), and contractive modes. Picard diverges; Anderson must
! reach ||T(x)-x|| < 1e-10.
!
!   gfortran -O2 -o test_anderson anderson_mod.f90 test_anderson.f90 && ./test_anderson

PROGRAM TEST_ANDERSON
  USE ANDERSON_MOD
  IMPLICIT NONE
  INTEGER, PARAMETER :: n = 40
  REAL(dp) :: jm(n, n), b(n), x(n), gx(n), xn(n), r0, r
  TYPE(AA_STATE) :: aa
  INTEGER :: i, it, fails
  REAL(dp), PARAMETER :: pi = 3.14159265358979_dp

  jm = 0.0_dp
  jm(1, 1) = 1.03_dp * COS(pi / 4); jm(1, 2) = -1.03_dp * SIN(pi / 4)
  jm(2, 1) = 1.03_dp * SIN(pi / 4); jm(2, 2) = 1.03_dp * COS(pi / 4)
  jm(3, 3) = -1.1_dp
  DO i = 4, n
    jm(i, i) = 0.6_dp * COS(0.37_dp * i)
    IF (i < n) jm(i, i + 1) = 0.1_dp
  END DO
  DO i = 1, n
    b(i) = SIN(1.3_dp * i)
  END DO
  fails = 0

  ! Picard
  x = 0.0_dp
  CALL T(x, gx); r0 = NORM2(gx - x)
  DO it = 1, 200
    CALL T(x, gx); x = gx
  END DO
  CALL T(x, gx); r = NORM2(gx - x)
  WRITE(*, '("Picard   residual: start ",ES10.3,"  after 200 its ",ES10.3)') r0, r
  IF (.NOT. (r > r0)) THEN
    WRITE(*, '("FAIL: Picard was expected to diverge")'); fails = fails + 1
  END IF

  ! Anderson
  CALL AA_INIT(aa, n, depth=4, beta=0.5_dp)
  x = 0.0_dp
  DO it = 1, 200
    CALL T(x, gx)
    r = NORM2(gx - x)
    IF (r < 1.0e-10_dp) EXIT
    CALL AA_STEP(aa, x, gx, xn)
    x = xn
  END DO
  WRITE(*, '("Anderson residual ",ES10.3," after ",I4," its, ",I3," restarts")') r, it, aa%restarts
  IF (.NOT. (r < 1.0e-10_dp)) THEN
    WRITE(*, '("FAIL: Anderson did not converge")'); fails = fails + 1
  END IF

  IF (fails == 0) THEN
    WRITE(*, '("PASS")')
  ELSE
    ERROR STOP 1
  END IF

CONTAINS

  SUBROUTINE T(xin, out)
    REAL(dp), INTENT(IN) :: xin(n)
    REAL(dp), INTENT(OUT) :: out(n)
    out = MATMUL(jm, xin) + b + 0.05_dp * SIN(CSHIFT(xin, 1))
  END SUBROUTINE T

END PROGRAM TEST_ANDERSON
