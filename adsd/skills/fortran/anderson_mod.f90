! Anderson acceleration for a fixed-point iteration x <- T(x), on flat vectors.
!
! Retained skill from T-0005 (Collins_Dennis_1975_central.f90,
! ANDERSON_OUTER_UPDATE), extracted into a standalone, solver-agnostic module.
! Constrained least-squares form (Walker & Ni 2011):
!   f_k = T(x_k) - x_k,  min || sum_k alpha_k f_k ||_W  s.t.  sum_k alpha_k = 1
!   x_new = (1-beta) T(x_newest) + beta * sum_k alpha_k T(x_k)
! Safeguards that mattered in practice: weighted inner product (fields of very
! different magnitude), diagonal regularisation, restart when max|alpha| > 10,
! and a restart whenever the map T changes (new correction terms, new parameter).
!
! Usage:
!   TYPE(AA_STATE) :: aa
!   CALL AA_INIT(aa, n, depth=4, beta=0.5_dp)
!   DO
!     gx = T(x)
!     CALL AA_STEP(aa, x, gx, xnew)
!     x = xnew
!   END DO
!   CALL AA_RESET(aa)   ! whenever T changes

MODULE ANDERSON_MOD
  USE, INTRINSIC :: ISO_FORTRAN_ENV, ONLY: dp => REAL64
  IMPLICIT NONE
  PRIVATE
  PUBLIC :: dp, AA_STATE, AA_INIT, AA_RESET, AA_STEP

  TYPE :: AA_STATE
    INTEGER :: n = 0, depth = 4, nhist = 0, restarts = 0
    REAL(dp) :: beta = 0.5_dp, reg = 1.0e-12_dp, alpha_max = 10.0_dp
    REAL(dp), ALLOCATABLE :: g(:,:), f(:,:), wts(:)
  END TYPE AA_STATE

CONTAINS

  SUBROUTINE AA_INIT(s, n, depth, beta, wts)
    TYPE(AA_STATE), INTENT(INOUT) :: s
    INTEGER, INTENT(IN) :: n
    INTEGER, INTENT(IN), OPTIONAL :: depth
    REAL(dp), INTENT(IN), OPTIONAL :: beta
    REAL(dp), INTENT(IN), OPTIONAL :: wts(n)   ! per-component weights (e.g. 1/max|field|)
    s%n = n
    IF (PRESENT(depth)) s%depth = depth
    IF (PRESENT(beta)) s%beta = beta
    IF (ALLOCATED(s%g)) DEALLOCATE(s%g, s%f, s%wts)
    ALLOCATE(s%g(n, s%depth + 2), s%f(n, s%depth + 2), s%wts(n))
    s%wts = 1.0_dp
    IF (PRESENT(wts)) s%wts = wts
    s%nhist = 0
    s%restarts = 0
  END SUBROUTINE AA_INIT

  SUBROUTINE AA_RESET(s)
    TYPE(AA_STATE), INTENT(INOUT) :: s
    s%nhist = 0
  END SUBROUTINE AA_RESET

  SUBROUTINE AA_STEP(s, x, gx, xnew)
    TYPE(AA_STATE), INTENT(INOUT) :: s
    REAL(dp), INTENT(IN) :: x(s%n), gx(s%n)
    REAL(dp), INTENT(OUT) :: xnew(s%n)
    INTEGER :: p, i, j, idx0, cap
    REAL(dp) :: a(s%depth + 2, s%depth + 2), rhs(s%depth + 2), sol(s%depth + 2)
    REAL(dp) :: diagmax
    LOGICAL :: ok

    cap = s%depth + 1
    IF (s%nhist >= cap) THEN                       ! drop the oldest pair
      s%g(:, 1:cap - 1) = s%g(:, 2:cap)
      s%f(:, 1:cap - 1) = s%f(:, 2:cap)
      s%nhist = cap - 1
    END IF
    s%nhist = s%nhist + 1
    s%g(:, s%nhist) = gx
    s%f(:, s%nhist) = gx - x

    xnew = gx
    IF (s%nhist < 2) RETURN

    p = s%nhist
    idx0 = 1
    DO i = 1, p
      DO j = i, p
        a(i, j) = SUM((s%wts * s%f(:, idx0 + i - 1)) * (s%wts * s%f(:, idx0 + j - 1)))
        a(j, i) = a(i, j)
      END DO
    END DO
    diagmax = 0.0_dp
    DO i = 1, p
      diagmax = MAX(diagmax, a(i, i))
    END DO
    DO i = 1, p
      a(i, i) = a(i, i) + s%reg * MAX(1.0_dp, diagmax)
      a(i, p + 1) = 1.0_dp
      a(p + 1, i) = 1.0_dp
      rhs(i) = 0.0_dp
    END DO
    a(p + 1, p + 1) = 0.0_dp
    rhs(p + 1) = 1.0_dp

    CALL SOLVE_DENSE(a(1:p + 1, 1:p + 1), rhs(1:p + 1), sol(1:p + 1), p + 1, ok)
    IF (.NOT. ok .OR. MAXVAL(ABS(sol(1:p))) > s%alpha_max) THEN
      s%g(:, 1) = s%g(:, s%nhist)                  ! restart from the newest pair
      s%f(:, 1) = s%f(:, s%nhist)
      s%nhist = 1
      s%restarts = s%restarts + 1
      RETURN
    END IF

    xnew = 0.0_dp
    DO i = 1, p
      xnew = xnew + sol(i) * s%g(:, idx0 + i - 1)
    END DO
    xnew = (1.0_dp - s%beta) * gx + s%beta * xnew
  END SUBROUTINE AA_STEP

  SUBROUTINE SOLVE_DENSE(a, b, x, n, ok)
    ! Gaussian elimination with partial pivoting for the small augmented system.
    INTEGER, INTENT(IN) :: n
    REAL(dp), INTENT(IN) :: a(n, n), b(n)
    REAL(dp), INTENT(OUT) :: x(n)
    LOGICAL, INTENT(OUT) :: ok
    REAL(dp) :: m(n, n + 1), t(n + 1), fac
    INTEGER :: i, k, piv
    m(:, 1:n) = a
    m(:, n + 1) = b
    ok = .FALSE.
    DO k = 1, n
      piv = k - 1 + MAXLOC(ABS(m(k:n, k)), 1)
      IF (ABS(m(piv, k)) < 1.0e-300_dp) RETURN
      IF (piv /= k) THEN
        t = m(k, :)
        m(k, :) = m(piv, :)
        m(piv, :) = t
      END IF
      DO i = k + 1, n
        fac = m(i, k) / m(k, k)
        m(i, k:n + 1) = m(i, k:n + 1) - fac * m(k, k:n + 1)
      END DO
    END DO
    DO i = n, 1, -1
      x(i) = (m(i, n + 1) - SUM(m(i, i + 1:n) * x(i + 1:n))) / m(i, i)
    END DO
    ok = ALL(x == x)                               ! reject NaN
  END SUBROUTINE SOLVE_DENSE

END MODULE ANDERSON_MOD
