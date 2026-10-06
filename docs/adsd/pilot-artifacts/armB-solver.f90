! Second-order (central-difference) Dean-flow solver.
!
! Modified copy of the Schubert (1972) secondary-flow program
! (Schubert_1972_complete_modern_Fortran.f90, Nils T. Basse 2025), extended
! with Fox's deferred correction as used by Collins & Dennis (1975):
!
!   * PHI (Poisson, no convection) is discretised with central differences
!     directly, including (1/r) dPHI/dr, and is solved on every interior row
!     up to r = 1 - h with PHI = 0 at the wall (Schubert instead imposed
!     PHI(NR) = PHI(NR-1)/4).  The wall vorticity follows from Thom's
!     formula OMEGA_w = -2 PHI(NR)/h^2.  PI = ACOS(-1) (was 3.14159255).
!   * W and OMEGA keep Schubert's stable upwind SOR operator.  The frozen
!     correction terms C_0 (W) and E_0 (OMEGA),
!        C_0 = -(1/2r) [ |DELTA| (W_E+W_W-2W_0) + |GAMMA| (W_N+W_S-2W_0) ],
!     are added to the numerator of the SOR update before division by the
!     diagonal (E(I,J,6) in Schubert's notation).  Upwind + C_0 is exactly
!     the central operator, so at convergence of both iteration levels the
!     fields satisfy the central equations (checked by CENTRAL_RESIDUALS).
!   * Two-level iteration.  Inner level: with C_0, E_0 frozen, the coupled
!     fields are iterated to convergence by nonlinear Gauss-Seidel (one SOR
!     sweep of PHI, W, OMEGA in turn per iteration; the wall vorticity is
!     relaxed with XI_WALL = 0.9).  Outer level: new C_0, E_0 from the
!     converged fields, C_0 <- omega1*C_0_new + (1-omega1)*C_0, until the
!     unrelaxed change |C_0_new - C_0| is small.  Block Picard (each field
!     solved fully) with averaging + Anderson acceleration is kept as an
!     option (NLGS = .FALSE.); it is unstable at large D (see REPORT.md).
!   * Each D is reached by continuation of the uncorrected (upwind) solution,
!     handing over the uncorrected fields (corrections reset to zero).
!
! Output: one line per D,
!   RESULT D=<D> PHI_M=<max|PHI|> W_M=<max|W|> STATUS=<CONVERGED|FAILED>
!
! Grid as in Schubert: r = (I-1)h, I = 1..NR+1, alpha = (J-1)k, J = 1..NA+1,
! symmetric about alpha = 0, pi.  Equations in Schubert's scaling (each
! equation multiplied by h*k):  lap(PHI) = -OMEGA,  lap(W) + conv(W) + D = 0,
! lap(OMEGA) + conv(OMEGA) + S(W) = 0.

MODULE KIND_MOD
  IMPLICIT NONE
  INTEGER, PARAMETER :: dp = SELECTED_REAL_KIND(15, 307)
END MODULE KIND_MOD

!------------------------------------------------------------------------
! Anderson acceleration (adsd/skills/fortran/anderson_mod.f90, inlined so
! that the solver is a single file).
!------------------------------------------------------------------------
MODULE ANDERSON_MOD
  USE KIND_MOD
  IMPLICIT NONE
  PRIVATE
  PUBLIC :: AA_STATE, AA_INIT, AA_RESET, AA_STEP

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
    REAL(dp), INTENT(IN), OPTIONAL :: wts(n)
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
    INTEGER :: p, i, j, cap
    REAL(dp) :: a(s%depth + 2, s%depth + 2), rhs(s%depth + 2), sol(s%depth + 2)
    REAL(dp) :: diagmax
    LOGICAL :: ok

    cap = s%depth + 1
    IF (s%nhist >= cap) THEN
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
    DO i = 1, p
      DO j = i, p
        a(i, j) = SUM((s%wts * s%f(:, i)) * (s%wts * s%f(:, j)))
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
      s%g(:, 1) = s%g(:, s%nhist)
      s%f(:, 1) = s%f(:, s%nhist)
      s%nhist = 1
      s%restarts = s%restarts + 1
      RETURN
    END IF

    xnew = 0.0_dp
    DO i = 1, p
      xnew = xnew + sol(i) * s%g(:, i)
    END DO
    xnew = (1.0_dp - s%beta) * gx + s%beta * xnew
  END SUBROUTINE AA_STEP

  SUBROUTINE SOLVE_DENSE(a, b, x, n, ok)
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
    ok = ALL(x == x)
  END SUBROUTINE SOLVE_DENSE

END MODULE ANDERSON_MOD

!------------------------------------------------------------------------
! Grid, fields, coefficients and the three SOR solvers.
!------------------------------------------------------------------------
MODULE DEAN_MOD
  USE KIND_MOD
  USE, INTRINSIC :: IEEE_ARITHMETIC, ONLY: IEEE_IS_FINITE
  IMPLICIT NONE

  INTEGER, PARAMETER :: NR = 2*10, NA = 2*18
  INTEGER, PARAMETER :: NRP1 = NR + 1, NAP1 = NA + 1, NAH = NA/2 + 1
  INTEGER, PARAMETER :: MAXSOR = 20000

  REAL(dp) :: PI, DR, DA, DADR, DRDA, DRDAM, D
  REAL(dp) :: RINV(NRP1), RINV2(NRP1), EE(NRP1), EF(NRP1)
  REAL(dp) :: SA(NAP1), CA(NRP1, NAP1)
  REAL(dp) :: B(NRP1, 5)                 ! central PHI stencil: E, N, W, S, source

  ! Fields (single level; SOR is in place)
  REAL(dp) :: PHI(NRP1, NAP1), W(NRP1, NAP1), OMEGA(NRP1, NAP1)
  ! Upwind W/OMEGA coefficients from the current PHI:
  ! E(:,:,1..4) east/north/west/south (unnormalised), E(:,:,6) diagonal
  REAL(dp) :: E(NRP1, NAP1, 6), GAM(NRP1, NAP1), DEL(NRP1, NAP1)
  REAL(dp) :: PO                         ! PHI(2,NAH): convection at origin
  ! Deferred corrections (scaled like the numerator of the SOR update);
  ! CW(1,1) is the origin correction for W.
  REAL(dp) :: CW(NRP1, NAP1), CO(NRP1, NAP1)

  REAL(dp) :: RHO_PHI = 1.6_dp, RHO_W = 1.0_dp, RHO_OM = 1.0_dp
  REAL(dp) :: SOR_TOL = 1.0e-11_dp       ! relative to max|field|
  LOGICAL :: BAD = .FALSE.               ! non-finite value detected
  INTEGER :: NSORFAIL = 0                ! SOR solves that hit MAXSOR
  INTEGER :: NSWEEP = MAXSOR             ! max SOR sweeps per field per outer iteration
  REAL(dp) :: XI_WALL = 0.9_dp           ! relaxation of the wall vorticity
  LOGICAL :: USE_AA = .TRUE., USE_AVG = .TRUE.
  REAL(dp) :: THETA = 0.5_dp            ! averaging weight (0.5 = two-cycle averaging)

CONTAINS

  SUBROUTINE SETUP_GRID()
    INTEGER :: I, J
    REAL(dp) :: BO
    PI = ACOS(-1.0_dp)
    DR = 1._dp / NR
    DA = PI / NA
    DRDAM = DR * DA
    DRDA = DR / DA
    DADR = DA / DR
    SA = 0._dp
    DO J = 2, NA
      SA(J) = SIN((J - 1) * DA) * 0.5_dp * DA
    END DO
    RINV = 0._dp; RINV2 = 0._dp; CA = 0._dp
    DO I = 2, NRP1
      RINV(I) = 1._dp / ((I - 1) * DR)
      RINV2(I) = RINV(I)**2
      DO J = 2, NA
        CA(I, J) = 0.5_dp * DR * RINV(I) * COS((J - 1) * DA)
      END DO
      EE(I) = 2._dp * (DADR + DRDA * RINV2(I))
      EF(I) = DRDA * RINV2(I)
    END DO
    ! Central PHI stencil (Schubert used a forward difference for (1/r)dPHI/dr)
    DO I = 2, NR
      BO = 2._dp * (DADR + DRDA * RINV2(I))
      B(I, 1) = (DADR + 0.5_dp * DA * RINV(I)) / BO
      B(I, 2) = DRDA * RINV2(I) / BO
      B(I, 3) = (DADR - 0.5_dp * DA * RINV(I)) / BO
      B(I, 4) = B(I, 2)
      B(I, 5) = DRDAM / BO
    END DO
  END SUBROUTINE SETUP_GRID

  ! Hard boundary / symmetry conditions
  SUBROUTINE APPLY_BC()
    PHI(1, :) = 0._dp; PHI(NRP1, :) = 0._dp
    PHI(:, 1) = 0._dp; PHI(:, NAP1) = 0._dp
    W(NRP1, :) = 0._dp
    W(1, 2:NAP1) = W(1, 1)
    OMEGA(1, :) = 0._dp; OMEGA(:, 1) = 0._dp; OMEGA(:, NAP1) = 0._dp
  END SUBROUTINE APPLY_BC

  ! Wall vorticity from Thom's formula, relaxed (it is part of the state)
  SUBROUTINE WALL_OMEGA()
    OMEGA(NRP1, 2:NA) = XI_WALL * OMEGA(NRP1, 2:NA) &
        - (1._dp - XI_WALL) * 2._dp * RINV2(2) * PHI(NR, 2:NA)
  END SUBROUTINE WALL_OMEGA

  LOGICAL FUNCTION FINITE_FIELD(X)
    REAL(dp), INTENT(IN) :: X(:,:)
    FINITE_FIELD = ALL(IEEE_IS_FINITE(X))
  END FUNCTION FINITE_FIELD

  !----------------------------------------------------------------------
  ! PHI: central Poisson, I = 2..NR, J = 2..NA.
  !----------------------------------------------------------------------
  SUBROUTINE SOR_PHI()
    INTEGER :: I, J, IT
    REAL(dp) :: OLD, NEW, DMAX, TOL
    TOL = SOR_TOL * MAX(1._dp, MAXVAL(ABS(PHI)))
    DO IT = 1, NSWEEP
      DMAX = 0._dp
      DO I = 2, NR
        DO J = 2, NA
          OLD = PHI(I, J)
          NEW = B(I,1)*PHI(I+1,J) + B(I,2)*PHI(I,J+1) + B(I,3)*PHI(I-1,J) &
              + B(I,4)*PHI(I,J-1) + B(I,5)*OMEGA(I,J)
          PHI(I, J) = OLD + RHO_PHI * (NEW - OLD)
          DMAX = MAX(DMAX, ABS(PHI(I, J) - OLD))
        END DO
      END DO
      IF (.NOT. FINITE_FIELD(PHI)) THEN
        BAD = .TRUE.; RETURN
      END IF
      IF (DMAX < TOL) RETURN
    END DO
    IF (NSWEEP == MAXSOR) NSORFAIL = NSORFAIL + 1
  END SUBROUTINE SOR_PHI

  !----------------------------------------------------------------------
  ! Upwind coefficients for W and OMEGA from PHI (Schubert's E array, but
  ! not yet divided by the diagonal).  DELTA includes the DA term that
  ! comes from (1/r) dW/dr, so the correction also centres that term.
  !----------------------------------------------------------------------
  SUBROUTINE COEFFS()
    INTEGER :: I, J
    REAL(dp) :: G, DL
    DO I = 2, NR
      DO J = 1, NAP1
        IF (J == 1) THEN
          G = 0._dp
          DL = DA - PHI(I, 2)                 ! PHI(I,0) = -PHI(I,2)
        ELSE IF (J == NAP1) THEN
          G = 0._dp
          DL = DA + PHI(I, NA)                ! PHI(I,NA+2) = -PHI(I,NA)
        ELSE
          G = 0.5_dp * (PHI(I+1, J) - PHI(I-1, J))
          DL = DA - 0.5_dp * (PHI(I, J+1) - PHI(I, J-1))
        END IF
        GAM(I, J) = G
        DEL(I, J) = DL
        E(I, J, 6) = EE(I) + RINV(I) * (ABS(G) + ABS(DL))
        E(I, J, 1) = DADR + RINV(I) * MAX(DL, 0._dp)
        E(I, J, 2) = EF(I) + RINV(I) * MAX(G, 0._dp)
        E(I, J, 3) = DADR - RINV(I) * MIN(DL, 0._dp)
        E(I, J, 4) = EF(I) - RINV(I) * MIN(G, 0._dp)
      END DO
    END DO
    PO = PHI(2, NAH)
  END SUBROUTINE COEFFS

  ! W with symmetric mirror images at alpha = 0, pi
  PURE REAL(dp) FUNCTION WN(I, J)
    INTEGER, INTENT(IN) :: I, J
    IF (J == NAP1) THEN
      WN = W(I, NA)
    ELSE
      WN = W(I, J + 1)
    END IF
  END FUNCTION WN

  PURE REAL(dp) FUNCTION WS(I, J)
    INTEGER, INTENT(IN) :: I, J
    IF (J == 1) THEN
      WS = W(I, 2)
    ELSE
      WS = W(I, J - 1)
    END IF
  END FUNCTION WS

  !----------------------------------------------------------------------
  ! W: upwind SOR with source D*h*k + C_0 (origin: D*h^2 + C_0(1,1)).
  !----------------------------------------------------------------------
  SUBROUTINE SOR_W()
    INTEGER :: I, J, IT
    REAL(dp) :: OLD, NEW, DMAX, TOL, E0, DDRDAM, DDR2
    DDRDAM = D * DRDAM
    DDR2 = D * DR**2
    E0 = 4._dp + ABS(PO)
    TOL = SOR_TOL * MAX(1._dp, MAXVAL(ABS(W)))
    DO IT = 1, NSWEEP
      DMAX = 0._dp
      OLD = W(1, 1)
      NEW = ((1._dp - MIN(PO, 0._dp)) * W(2, 1) + 2._dp * W(2, NAH) &
          + (1._dp + MAX(PO, 0._dp)) * W(2, NAP1) + DDR2 + CW(1, 1)) / E0
      W(1, 1) = OLD + RHO_W * (NEW - OLD)
      W(1, 2:NAP1) = W(1, 1)
      DMAX = MAX(DMAX, ABS(W(1, 1) - OLD))
      DO I = 2, NR
        DO J = 1, NAP1
          OLD = W(I, J)
          NEW = (E(I,J,1)*W(I+1,J) + E(I,J,2)*WN(I,J) + E(I,J,3)*W(I-1,J) &
              + E(I,J,4)*WS(I,J) + DDRDAM + CW(I,J)) / E(I,J,6)
          W(I, J) = OLD + RHO_W * (NEW - OLD)
          DMAX = MAX(DMAX, ABS(W(I, J) - OLD))
        END DO
      END DO
      IF (.NOT. FINITE_FIELD(W)) THEN
        BAD = .TRUE.; RETURN
      END IF
      IF (DMAX < TOL) RETURN
    END DO
    IF (NSWEEP == MAXSOR) NSORFAIL = NSORFAIL + 1
  END SUBROUTINE SOR_W

  ! Source of the OMEGA equation (central differences of W)
  PURE REAL(dp) FUNCTION SRC_OM(I, J)
    INTEGER, INTENT(IN) :: I, J
    SRC_OM = -W(I, J) * (SA(J) * (W(I+1, J) - W(I-1, J)) &
                         + CA(I, J) * (W(I, J+1) - W(I, J-1)))
  END FUNCTION SRC_OM

  !----------------------------------------------------------------------
  ! OMEGA: upwind SOR with source S(W) + E_0, I = 2..NR, J = 2..NA.
  !----------------------------------------------------------------------
  SUBROUTINE SOR_OMEGA()
    INTEGER :: I, J, IT
    REAL(dp) :: OLD, NEW, DMAX, TOL, S(NRP1, NAP1)
    DO I = 2, NR
      DO J = 2, NA
        S(I, J) = SRC_OM(I, J) + CO(I, J)
      END DO
    END DO
    TOL = SOR_TOL * MAX(1._dp, MAXVAL(ABS(OMEGA)))
    DO IT = 1, NSWEEP
      DMAX = 0._dp
      DO I = 2, NR
        DO J = 2, NA
          OLD = OMEGA(I, J)
          NEW = (E(I,J,1)*OMEGA(I+1,J) + E(I,J,2)*OMEGA(I,J+1) &
              + E(I,J,3)*OMEGA(I-1,J) + E(I,J,4)*OMEGA(I,J-1) + S(I,J)) &
              / E(I,J,6)
          OMEGA(I, J) = OLD + RHO_OM * (NEW - OLD)
          DMAX = MAX(DMAX, ABS(OMEGA(I, J) - OLD))
        END DO
      END DO
      IF (.NOT. FINITE_FIELD(OMEGA)) THEN
        BAD = .TRUE.; RETURN
      END IF
      IF (DMAX < TOL) RETURN
    END DO
    IF (NSWEEP == MAXSOR) NSORFAIL = NSORFAIL + 1
  END SUBROUTINE SOR_OMEGA

  !----------------------------------------------------------------------
  ! One outer (Picard) sweep with frozen corrections.
  !----------------------------------------------------------------------
  SUBROUTINE SWEEP()
    CALL APPLY_BC()
    CALL SOR_PHI()
    CALL WALL_OMEGA()                    ! wall vorticity from the new PHI
    CALL COEFFS()
    CALL SOR_W()
    CALL SOR_OMEGA()
  END SUBROUTINE SWEEP

  !----------------------------------------------------------------------
  ! Deferred corrections from the current fields:
  !   C = central(convection) - upwind(convection)
  !----------------------------------------------------------------------
  SUBROUTINE CORRECTIONS(CWN, CON)
    REAL(dp), INTENT(OUT) :: CWN(NRP1, NAP1), CON(NRP1, NAP1)
    INTEGER :: I, J
    CWN = 0._dp; CON = 0._dp
    CWN(1, 1) = -0.5_dp * ABS(PO) * (W(2, 1) + W(2, NAP1) - 2._dp * W(1, 1))
    DO I = 2, NR
      DO J = 1, NAP1
        CWN(I, J) = -0.5_dp * RINV(I) * ( &
            ABS(DEL(I,J)) * (W(I+1,J) + W(I-1,J) - 2._dp*W(I,J)) &
          + ABS(GAM(I,J)) * (WN(I,J) + WS(I,J) - 2._dp*W(I,J)))
      END DO
      DO J = 2, NA
        CON(I, J) = -0.5_dp * RINV(I) * ( &
            ABS(DEL(I,J)) * (OMEGA(I+1,J) + OMEGA(I-1,J) - 2._dp*OMEGA(I,J)) &
          + ABS(GAM(I,J)) * (OMEGA(I,J+1) + OMEGA(I,J-1) - 2._dp*OMEGA(I,J)))
      END DO
    END DO
  END SUBROUTINE CORRECTIONS

  !----------------------------------------------------------------------
  ! Residuals of the *central* equations, written out independently of
  ! the upwind/correction split (consistency probe).  Scaled by the size
  ! of the forcing term of each equation.
  !----------------------------------------------------------------------
  SUBROUTINE CENTRAL_RESIDUALS(RP, RW, RO)
    REAL(dp), INTENT(OUT) :: RP, RW, RO
    INTEGER :: I, J
    REAL(dp) :: G, DL, R, SCO
    RP = 0._dp; RW = 0._dp; RO = 0._dp
    ! origin, W (scaled by h^2)
    R = W(2,1) + W(2,NAP1) + 2._dp*W(2,NAH) - 4._dp*W(1,1) &
      - 0.5_dp * PHI(2,NAH) * (W(2,1) - W(2,NAP1)) + D*DR**2
    RW = MAX(RW, ABS(R) / (D*DR**2))
    SCO = 1.0e-30_dp
    DO I = 2, NR
      DO J = 2, NA
        SCO = MAX(SCO, ABS(SRC_OM(I, J)))
      END DO
    END DO
    DO I = 2, NR
      DO J = 1, NAP1
        IF (J == 1) THEN
          G = 0._dp; DL = DA - PHI(I, 2)
        ELSE IF (J == NAP1) THEN
          G = 0._dp; DL = DA + PHI(I, NA)
        ELSE
          G = 0.5_dp * (PHI(I+1, J) - PHI(I-1, J))
          DL = DA - 0.5_dp * (PHI(I, J+1) - PHI(I, J-1))
        END IF
        R = DADR * (W(I+1,J) - 2._dp*W(I,J) + W(I-1,J)) &
          + EF(I) * (WN(I,J) - 2._dp*W(I,J) + WS(I,J)) &
          + 0.5_dp * RINV(I) * (DL * (W(I+1,J) - W(I-1,J)) + G * (WN(I,J) - WS(I,J))) &
          + D * DRDAM
        RW = MAX(RW, ABS(R) / (D*DRDAM))
        IF (J >= 2 .AND. J <= NA) THEN
          R = DADR * (OMEGA(I+1,J) - 2._dp*OMEGA(I,J) + OMEGA(I-1,J)) &
            + EF(I) * (OMEGA(I,J+1) - 2._dp*OMEGA(I,J) + OMEGA(I,J-1)) &
            + 0.5_dp * RINV(I) * (DL * (OMEGA(I+1,J) - OMEGA(I-1,J)) &
                                 + G * (OMEGA(I,J+1) - OMEGA(I,J-1))) &
            + SRC_OM(I, J)
          RO = MAX(RO, ABS(R) / SCO)
          R = DADR * (PHI(I+1,J) - 2._dp*PHI(I,J) + PHI(I-1,J)) &
            + EF(I) * (PHI(I,J+1) - 2._dp*PHI(I,J) + PHI(I,J-1)) &
            + 0.5_dp * DA * RINV(I) * (PHI(I+1,J) - PHI(I-1,J)) &
            + DRDAM * OMEGA(I, J)
          RP = MAX(RP, ABS(R) / (DRDAM * MAX(1._dp, MAXVAL(ABS(OMEGA)))))
        END IF
      END DO
    END DO
  END SUBROUTINE CENTRAL_RESIDUALS

  ! State vector for Anderson: PHI, W, OMEGA interior (+ W origin)
  INTEGER FUNCTION NSTATE()
    NSTATE = 3 * NRP1 * NAP1
  END FUNCTION NSTATE

  SUBROUTINE PACK_STATE(X)
    REAL(dp), INTENT(OUT) :: X(:)
    INTEGER :: N
    N = NRP1 * NAP1
    X(1:N) = RESHAPE(PHI, [N])
    X(N+1:2*N) = RESHAPE(W, [N])
    X(2*N+1:3*N) = RESHAPE(OMEGA, [N])
  END SUBROUTINE PACK_STATE

  SUBROUTINE UNPACK_STATE(X)
    REAL(dp), INTENT(IN) :: X(:)
    INTEGER :: N
    N = NRP1 * NAP1
    PHI = RESHAPE(X(1:N), [NRP1, NAP1])
    W = RESHAPE(X(N+1:2*N), [NRP1, NAP1])
    OMEGA = RESHAPE(X(2*N+1:3*N), [NRP1, NAP1])
    CALL APPLY_BC()
  END SUBROUTINE UNPACK_STATE

END MODULE DEAN_MOD

!------------------------------------------------------------------------
! Main program
!------------------------------------------------------------------------
PROGRAM MAIN
  USE KIND_MOD
  USE DEAN_MOD
  USE ANDERSON_MOD
  IMPLICIT NONE

  INTEGER, PARAMETER :: NCASE = 7
  REAL(dp), PARAMETER :: DLIST(NCASE) = [96._dp, 500._dp, 605.72_dp, &
      1000._dp, 2000._dp, 3500._dp, 5000._dp]
  REAL(dp), PARAMETER :: OMEGA1 = 0.5_dp        ! correction smoothing
  REAL(dp), PARAMETER :: TOL_IN = 1.0e-11_dp    ! inner (fields) tolerance
  REAL(dp), PARAMETER :: TOL_C = 1.0e-8_dp      ! correction tolerance
  INTEGER, PARAMETER :: MAXCORR = 400
  INTEGER :: MAXIN = 100000, MAXIN_T
  INTEGER, PARAMETER :: NRUNG = 7
  REAL(dp), PARAMETER :: THETA_L(NRUNG) = [0.5_dp, 0.25_dp, 0.25_dp, 0.125_dp, &
      0.125_dp, 0.0833_dp, 0.0625_dp]
  REAL(dp), PARAMETER :: XI_L(NRUNG) = [0.9_dp, 0.9_dp, 0.95_dp, 0.9_dp, &
      0.95_dp, 0.9_dp, 0.9_dp]
  INTEGER :: RUNG = 1, AA_DEPTH = 4
  LOGICAL :: NLGS = .TRUE., TRACE_INNER = .FALSE.
  REAL(dp) :: AA_BETA = 0.5_dp, DCFAC = 1.0e-4_dp

  REAL(dp), ALLOCATABLE :: X(:), GX(:), XNEW(:), WTS(:)
  REAL(dp) :: PHI_U(NRP1, NAP1), W_U(NRP1, NAP1), OM_U(NRP1, NAP1)
  REAL(dp) :: CWN(NRP1, NAP1), CON(NRP1, NAP1), CWOLD(NRP1, NAP1), COOLD(NRP1, NAP1)
  REAL(dp) :: OM1
  INTEGER :: NOK
  REAL(dp) :: DPREV, DTGT, DSTEP, DC, RP, RW, RO, PHIM, WM
  TYPE(AA_STATE) :: AA
  INTEGER :: ICASE, KC, NIN, NTOT, N, clock_start, clock_end, clock_rate, UT
  LOGICAL :: OK, CONV
  CHARACTER(LEN=64) :: FNAME
  CHARACTER(LEN=12) :: S1, S2, S3, STATUS

  CALL SYSTEM_CLOCK(COUNT_RATE=clock_rate)
  CALL SYSTEM_CLOCK(COUNT=clock_start)
  CALL SETUP_GRID()
  N = NSTATE()
  ALLOCATE(X(N), GX(N), XNEW(N), WTS(N))

  PHI = 0._dp; W = 0._dp; OMEGA = 0._dp
  CW = 0._dp; CO = 0._dp
  DPREV = 0._dp

  ! Diagnostic test mode (one inner solve at fixed D, trace in trace_test.csv):
  !   ./solver test D XI_WALL MODE MAXIT [D0 [THETA [DEPTH [RHO [NSWEEP]]]]]
  ! MODE: 0 Picard, 1 Anderson, 2 averaging, 3 averaging + Anderson.
  ! D0 > 0: continuation from 0 to D0 first (state saved to state_D0.bin);
  ! D0 < 0: start from state_|D0|.bin.
  IF (COMMAND_ARGUMENT_COUNT() >= 4) THEN
    CALL GET_COMMAND_ARGUMENT(2, FNAME); READ(FNAME, *) D
    CALL GET_COMMAND_ARGUMENT(3, FNAME); READ(FNAME, *) XI_WALL
    CALL GET_COMMAND_ARGUMENT(4, FNAME); READ(FNAME, *) KC
    USE_AA = (MOD(KC, 2) /= 0)
    USE_AVG = (KC >= 2)
    CALL GET_COMMAND_ARGUMENT(5, FNAME); READ(FNAME, *) MAXIN_T
    KC = 0; DC = 0._dp; NTOT = 0
    IF (COMMAND_ARGUMENT_COUNT() >= 7) THEN
      CALL GET_COMMAND_ARGUMENT(7, FNAME); READ(FNAME, *) THETA
    END IF
    IF (COMMAND_ARGUMENT_COUNT() >= 8) THEN
      CALL GET_COMMAND_ARGUMENT(8, FNAME); READ(FNAME, *) AA_DEPTH
    END IF
    IF (COMMAND_ARGUMENT_COUNT() >= 10) THEN
      CALL GET_COMMAND_ARGUMENT(10, FNAME); READ(FNAME, *) NSWEEP
    END IF
    IF (COMMAND_ARGUMENT_COUNT() >= 9) THEN
      CALL GET_COMMAND_ARGUMENT(9, FNAME); READ(FNAME, *) RHO_W
      RHO_OM = RHO_W
    END IF
    IF (COMMAND_ARGUMENT_COUNT() >= 6) CALL GET_COMMAND_ARGUMENT(6, FNAME)
    IF (COMMAND_ARGUMENT_COUNT() >= 6) READ(FNAME, *) DTGT
    IF (COMMAND_ARGUMENT_COUNT() >= 6 .AND. DTGT < 0._dp) THEN   ! load saved state
      WRITE(FNAME, '("state_",I0,".bin")') NINT(-DTGT)
      OPEN(NEWUNIT=UT, FILE=TRIM(FNAME), FORM='UNFORMATTED', STATUS='OLD')
      READ(UT) PHI, W, OMEGA
      CLOSE(UT)
    ELSE IF (COMMAND_ARGUMENT_COUNT() >= 6) THEN     ! continuation up to D0 first
      DPREV = D; D = 0._dp
      DO WHILE (D < DTGT)
        D = MIN(D + MAX(0.05_dp * D, 20._dp), DTGT)
        CALL INNER(OK, NIN)
        WRITE(*, '("  cont D=",F9.2," ok=",L1," its=",I5," phi_M=",F9.4)') D, OK, NIN, MAXVAL(ABS(PHI))
      END DO
      WRITE(FNAME, '("state_",I0,".bin")') NINT(DTGT)
      OPEN(NEWUNIT=UT, FILE=TRIM(FNAME), FORM='UNFORMATTED', STATUS='REPLACE')
      WRITE(UT) PHI, W, OMEGA
      CLOSE(UT)
      D = DPREV
      CALL GET_COMMAND_ARGUMENT(3, FNAME); READ(FNAME, *) XI_WALL
      THETA = 0.5_dp
      IF (COMMAND_ARGUMENT_COUNT() >= 7) THEN
        CALL GET_COMMAND_ARGUMENT(7, FNAME); READ(FNAME, *) THETA
      END IF
    END IF
    TRACE_INNER = .TRUE.
    OPEN(NEWUNIT=UT, FILE='trace_test.csv', STATUS='REPLACE')
    WRITE(UT, '(A)') 'iter,level,phiM,wM,omgM,phiMid,wMid,dx,dC,resW,resO'
    MAXIN = MAXIN_T
    CALL INNER1(OK, NIN)
    WRITE(*, '("SOR solves not converged:",I8)') NSORFAIL
    WRITE(*, '("test: ok=",L1," its=",I6," phi_M=",F10.5," w_M=",F10.4)') OK, NIN, &
        MAXVAL(ABS(PHI)), MAXVAL(ABS(W))
    STOP
  END IF

  DO ICASE = 1, NCASE
    DTGT = DLIST(ICASE)
    ! one trace row per correction level (the outer iteration of Fox's scheme)
    WRITE(FNAME, '("trace_D",I0,".csv")') NINT(DTGT)
    OPEN(NEWUNIT=UT, FILE=TRIM(FNAME), STATUS='REPLACE')
    WRITE(UT, '(A)') 'level,phiM,wM,omgM,phiMid,wMid,dC,resPhi,resW,resO,innerIts'
    NTOT = 0

    !---- continuation of the uncorrected (upwind) solution, C = 0 --------
    PHI = PHI_U; W = W_U; OMEGA = OM_U
    IF (ICASE == 1) THEN
      PHI = 0._dp; W = 0._dp; OMEGA = 0._dp
    END IF
    CW = 0._dp; CO = 0._dp
    D = DPREV; KC = 0; DC = 0._dp; NIN = 0
    DO
      DSTEP = MAX(0.05_dp * D, 20._dp)
      D = MIN(D + DSTEP, DTGT)
      CALL INNER(OK, NIN)
      IF (.NOT. OK) WRITE(*, '("  continuation step D=",F9.2," not converged")') D
      IF (D >= DTGT) EXIT
    END DO
    PHI_U = PHI; W_U = W; OM_U = OMEGA
    WRITE(*, '("D=",F8.2,"  upwind:  phi_M=",F9.4,"  w_M=",F9.3)') D, &
        MAXVAL(ABS(PHI)), MAXVAL(ABS(W))

    !---- deferred-correction level --------------------------------------
    CONV = .FALSE.
    OM1 = OMEGA1; NOK = 0
    DO KC = 1, MAXCORR
      CALL CORRECTIONS(CWN, CON)
      DC = MAX(MAXVAL(ABS(CWN - CW)) / MAX(1.0e-30_dp, MAXVAL(ABS(CWN))), &
               MAXVAL(ABS(CON - CO)) / MAX(1.0e-30_dp, MAXVAL(ABS(CON))))
      CALL CENTRAL_RESIDUALS(RP, RW, RO)
      WRITE(UT, '(I5,9(",",ES16.8),",",I7)') KC, MAXVAL(ABS(PHI)), MAXVAL(ABS(W)), &
          MAXVAL(ABS(OMEGA)), PHI(NR/2, NA/2), W(NR/2, NA/2), DC, RP, RW, RO, NIN
      IF (MOD(KC, 10) == 1) WRITE(*, '("  corr ",I4,"  dC=",ES9.2,"  res(phi,W,om)=",3ES9.2, &
          & "  phi_M=",F9.4,"  w_M=",F9.3)') KC, DC, RP, RW, RO, MAXVAL(ABS(PHI)), MAXVAL(ABS(W))
      IF (DC < TOL_C .AND. KC > 1) THEN
        CONV = .TRUE.
        EXIT
      END IF
      CWOLD = CW; COOLD = CO
      DO
        CW = OM1 * CWN + (1._dp - OM1) * CW
        CO = OM1 * CON + (1._dp - OM1) * CO
        CALL INNER(OK, NIN, MIN(NRUNG, RUNG + 1))
        IF (OK) EXIT
        ! fields were restored by INNER; restore corrections, smaller omega1
        CW = CWOLD; CO = COOLD
        OM1 = 0.5_dp * OM1
        WRITE(*, '("  inner failed at correction level",I5,": omega1 ->",F8.5)') KC, OM1
        IF (OM1 < 1.0_dp / 256._dp) EXIT
      END DO
      IF (.NOT. OK) EXIT
      NOK = NOK + 1
      IF (NOK >= 5 .AND. OM1 < OMEGA1) THEN        ! cautiously grow omega1 again
        OM1 = MIN(OMEGA1, 1.5_dp * OM1); NOK = 0
      END IF
    END DO
    CLOSE(UT)

    CALL CENTRAL_RESIDUALS(RP, RW, RO)
    PHIM = MAXVAL(ABS(PHI)); WM = MAXVAL(ABS(W))
    WRITE(*, '("  final central residuals (phi,W,omega):",3ES10.2, "  outer its:",I8)') &
        RP, RW, RO, NTOT
    ! converged: corrections stopped changing AND the fields satisfy the
    ! central equations (relative residuals)
    STATUS = 'FAILED'
    IF (CONV .AND. .NOT. BAD .AND. MAX(RP, RW, RO) < 1.0e-5_dp) STATUS = 'CONVERGED'
    WRITE(S1, '(F12.2)') DTGT
    WRITE(S2, '(F12.4)') PHIM
    WRITE(S3, '(F12.3)') WM
    WRITE(*, '(9A)') 'RESULT D=', TRIM(ADJUSTL(S1)), ' PHI_M=', TRIM(ADJUSTL(S2)), &
        ' W_M=', TRIM(ADJUSTL(S3)), ' STATUS=', TRIM(STATUS)
    BAD = .FALSE.
    DPREV = DTGT
  END DO

  CALL SYSTEM_CLOCK(COUNT=clock_end)
  WRITE(*, '("Elapsed time (s):",F9.2)') REAL(clock_end - clock_start, dp) / clock_rate

CONTAINS

  !----------------------------------------------------------------------
  ! Inner level (fields with frozen corrections) with a damping ladder: if an attempt fails (NaN, blow-up
  ! or stagnation), restore the starting state and retry with stronger
  ! averaging (THETA) and wall-vorticity relaxation (XI_WALL).  The rung
  ! reached is kept for subsequent calls (it only changes the map, not
  ! its fixed points).
  !----------------------------------------------------------------------
  SUBROUTINE INNER(OK, NIT, MAXRUNG)
    LOGICAL, INTENT(OUT) :: OK
    INTEGER, INTENT(OUT) :: NIT
    INTEGER, INTENT(IN), OPTIONAL :: MAXRUNG
    INTEGER :: RMAX
    REAL(dp) :: XSAVE(N)
    INTEGER :: NIT1
    RMAX = NRUNG
    IF (PRESENT(MAXRUNG)) RMAX = MAXRUNG
    CALL APPLY_BC()
    CALL PACK_STATE(XSAVE)
    NIT = 0
    DO
      THETA = THETA_L(RUNG); XI_WALL = XI_L(RUNG)
      IF (NLGS) THEN                 ! nonlinear Gauss-Seidel: one sweep per field
        THETA = 1._dp; USE_AA = .FALSE.; NSWEEP = 1
      END IF
      CALL INNER1(OK, NIT1)
      NIT = NIT + NIT1
      IF (OK) RETURN
      CALL UNPACK_STATE(XSAVE)
      IF (RUNG >= RMAX) RETURN
      RUNG = RUNG + 1
      WRITE(*, '("    D=",F9.2,": inner failed, damping rung ->",I2," (theta=",F7.4,", xi_wall=",F6.3,")")') &
          D, RUNG, THETA_L(RUNG), XI_L(RUNG)
    END DO
  END SUBROUTINE INNER

  ! One attempt at the inner level.  Default (NLGS): nonlinear Gauss-Seidel,
  ! one SOR sweep of PHI, W and OMEGA per iteration.  Alternative: block
  ! Picard (each field solved to SOR convergence) with averaging and
  ! Anderson acceleration.  Stops when the fields stop changing.
  SUBROUTINE INNER1(OK, NIT)
    LOGICAL, INTENT(OUT) :: OK
    INTEGER, INTENT(OUT) :: NIT
    INTEGER :: M, LASTBEST
    REAL(dp) :: DX, SP, SW, SO, DXMIN
    M = NRP1 * NAP1
    SP = 1._dp / MAX(1._dp, MAXVAL(ABS(PHI)))
    SW = 1._dp / MAX(1._dp, MAXVAL(ABS(W)))
    SO = 1._dp / MAX(1._dp, MAXVAL(ABS(OMEGA)))
    WTS(1:M) = SP; WTS(M+1:2*M) = SW; WTS(2*M+1:3*M) = SO
    CALL AA_INIT(AA, N, depth=AA_DEPTH, beta=AA_BETA, wts=WTS)
    OK = .FALSE.
    BAD = .FALSE.
    SOR_TOL = 1.0e-6_dp
    DXMIN = HUGE(1._dp); LASTBEST = 0
    CALL APPLY_BC()
    DO NIT = 1, MAXIN
      CALL PACK_STATE(X)
      CALL SWEEP()
      IF (BAD) RETURN
      CALL PACK_STATE(GX)
      ! averaging of the whole coupled iterate: x <- x + theta (T(x) - x)
      IF (USE_AVG) GX = X + THETA * (GX - X)
      DX = MAXVAL(WTS * ABS(GX - X))
      ! inexact inner solves: SOR tolerance follows the outer step
      SOR_TOL = MAX(1.0e-12_dp, MIN(1.0e-6_dp, 1.0e-3_dp * DX))
      NTOT = NTOT + 1
      IF (TRACE_INNER) WRITE(UT, '(I7,",",I4,9(",",ES16.8))') NTOT, KC, MAXVAL(ABS(PHI)), MAXVAL(ABS(W)), &
          MAXVAL(ABS(OMEGA)), PHI(NR/2, NA/2), W(NR/2, NA/2), DX, DC, RW, RO
      IF (DX < MAX(TOL_IN, DCFAC * DC)) THEN
        OK = .TRUE.
        RETURN
      END IF
      IF (DX /= DX .OR. DX > 1.0e3_dp * MIN(DXMIN, 1._dp)) RETURN    ! blow-up
      IF (DX < 0.5_dp * DXMIN) THEN
        DXMIN = DX; LASTBEST = NIT
      END IF
      IF (NIT - LASTBEST > 2000) RETURN                                 ! stagnation
      IF (USE_AA) THEN
        CALL AA_STEP(AA, X, GX, XNEW)
        CALL UNPACK_STATE(XNEW)
      ELSE
        CALL UNPACK_STATE(GX)
      END IF
    END DO
  END SUBROUTINE INNER1

END PROGRAM MAIN
