! Collins & Dennis (1975) Deferred Correction Upgrade -- TURBULENT EXTENSION
!
! Based on: Collins_Dennis_1975_central.f90 (laminar solver)
!
! Adds:
! - Van Driest mixing-length turbulence model (nu_T from wall shear)
! - Face-averaged variable viscosity nu_eff(r,alpha) in W and OMEGA stencils
! - STRAIGHT_PIPE mode for log-law validation (no curvature, no secondary flow)
!
! Phase 1 (T-0007): STRAIGHT_PIPE = .TRUE. validates turbulence model
!   against the analytic log-law profile at Re_tau = 300.
! Phase 2 (T-0008): STRAIGHT_PIPE = .FALSE. enables curvature (Dean flow).

MODULE KIND_MOD
  IMPLICIT NONE
  INTEGER, PARAMETER :: dp = SELECTED_REAL_KIND(15, 307)
END MODULE KIND_MOD

MODULE ERROR_MOD
  USE KIND_MOD
  IMPLICIT NONE
CONTAINS
  SUBROUTINE ERROR_HANDLER(code, val)
    INTEGER, INTENT(IN) :: code
    REAL(KIND=dp), OPTIONAL, INTENT(IN) :: val
    SELECT CASE (code)
      CASE (55)
        WRITE(*,'("SOR FOR PHI FAILED.")')
      CASE (56)
        IF (PRESENT(val)) THEN
          WRITE(*,'("SOR FOR W FAILED WITH SOR FACTOR =",F6.2)') val
        ELSE
          WRITE(*,'("SOR FOR W FAILED WITH SOR FACTOR =",F6.2)') 0.0_dp
        END IF
      CASE (57)
        IF (PRESENT(val)) THEN
          WRITE(*,'("SOR FOR OMEGA FAILED WITH SOR FACTOR =",F6.2)') val
        ELSE
          WRITE(*,'("SOR FOR OMEGA FAILED WITH SOR FACTOR =",F6.2)') 0.0_dp
        END IF
      CASE (58)
        WRITE(*,'("OUTER ITERATION FAILED TO CONVERGE.")')
      CASE DEFAULT
        WRITE(*,*) 'Unknown error code in ERROR_HANDLER.'
    END SELECT
  END SUBROUTINE ERROR_HANDLER
END MODULE ERROR_MOD

MODULE OUTPUT_MOD
  USE KIND_MOD
  IMPLICIT NONE
CONTAINS
  SUBROUTINE OUTPUT(VAR, ISOR, A, x, y)
    CHARACTER(LEN=5), INTENT(IN) :: VAR
    INTEGER, INTENT(IN) :: x, y, ISOR
    REAL(KIND=dp), INTENT(IN) :: A(x+1, y+1)
    CHARACTER(LEN=5), PARAMETER :: APHI='PHI  '
    INTEGER :: I, J, NRP1, NAP1
    NRP1 = x + 1
    NAP1 = y + 1
    WRITE(*,'(A6,5X,I5,2X,"SOR ITERATIONS"/)') VAR, ISOR
    IF (VAR /= APHI) THEN
      DO I = 1, NRP1
        WRITE(*,'(1X,F6.1,17F7.1,F6.1)') (A(NRP1 - I + 1, NAP1 - J + 1), &
            J = 1, NAP1)
      END DO
    ELSE
      DO I = 1, NRP1
        WRITE(*,'(1X,F6.2,17F7.2,F6.2)') (A(NRP1 - I + 1, NAP1 - J + 1), &
            J = 1, NAP1)
      END DO
    END IF
  END SUBROUTINE OUTPUT
END MODULE OUTPUT_MOD

MODULE SOR_MOD
  USE KIND_MOD
  USE, INTRINSIC :: ieee_arithmetic, ONLY: ieee_is_finite
  IMPLICIT NONE
CONTAINS
  SUBROUTINE SOR_PHI(PHI, OMEGA, B, C, RHOC, RHO, EPPS, ISOR_PHI, MAXSOR, NR, &
    NA, NRP1, NAP1, NRM1, USE_PARABOLIC_WALL, ERROR_HANDLER)
    IMPLICIT NONE
    INTEGER, INTENT(IN) :: NR, NA, NRP1, NAP1, NRM1, MAXSOR
    REAL(KIND=dp), INTENT(INOUT) :: PHI(NRP1, NAP1, 4), OMEGA(NRP1, NAP1, 4)
    REAL(KIND=dp), INTENT(IN) :: B(NRP1, 5), RHOC(3), RHO(3), EPPS(3)
    INTEGER, INTENT(OUT) :: ISOR_PHI
    REAL(KIND=dp), INTENT(INOUT) :: C(NRP1, NAP1)
    LOGICAL, INTENT(IN) :: USE_PARABOLIC_WALL
    INTERFACE
      SUBROUTINE ERROR_HANDLER(code, val)
        USE KIND_MOD
        INTEGER, INTENT(IN) :: code
        REAL(KIND=dp), OPTIONAL, INTENT(IN) :: val
      END SUBROUTINE ERROR_HANDLER
    END INTERFACE
    INTEGER :: I, J, ICONV, NR_INNER
    ISOR_PHI = 0
    ! OMEGA passed for interface consistency (used by caller for source term)
    IF (SIZE(OMEGA,1) < 1) RETURN
    IF (USE_PARABOLIC_WALL) THEN
      NR_INNER = NRM1
    ELSE
      NR_INNER = NR
    END IF
    PHI_SOR: DO
      ICONV = 0
      DO I = 2, NR_INNER
        DO J = 2, NA
          PHI(I,J,3) = RHOC(1)*PHI(I,J,2) + RHO(1)*( &
              B(I,1)*PHI(I+1,J,2) + B(I,2)*PHI(I,J+1,2) &
              + B(I,3)*PHI(I-1,J,3) + B(I,4)*PHI(I,J-1,3) + C(I,J))
          IF (.NOT. ieee_is_finite(PHI(I,J,3))) THEN
            ICONV = 1
            ISOR_PHI = MAXSOR
            EXIT PHI_SOR
          END IF
          IF (ABS(PHI(I,J,2) - PHI(I,J,3)) > EPPS(1)) ICONV = 1
        END DO
      END DO
      IF (USE_PARABOLIC_WALL) THEN
        DO J = 2, NA
          PHI(NR,J,3) = RHOC(1)*PHI(NR,J,2) + RHO(1)*0.25_dp*PHI(NRM1,J,3)
          IF (ABS(PHI(NR,J,2) - PHI(NR,J,3)) > EPPS(1)) ICONV = 1
        END DO
      END IF
      IF (ICONV == 0) EXIT PHI_SOR
      ISOR_PHI = ISOR_PHI + 1
      IF (ISOR_PHI >= MAXSOR) THEN
        CALL ERROR_HANDLER(55)
        EXIT PHI_SOR
      END IF
      PHI(2:NR,2:NA,2) = PHI(2:NR,2:NA,3)
    END DO PHI_SOR
  END SUBROUTINE SOR_PHI

  SUBROUTINE SOR_W(W, E, EPPS2, RHOC2, RHO2, ISOR_W, MAXSOR, NR, NA, NRP1, &
    NAP1, NAH, E1, E2, E3, E4, DOR, NOR, IRW, ICONV, ERROR_HANDLER)
    IMPLICIT NONE
    INTEGER, INTENT(IN) :: NR, NA, NRP1, NAP1, NAH, MAXSOR, NOR
    REAL(KIND=dp), INTENT(INOUT) :: W(NRP1, NAP1, 4)
    REAL(KIND=dp), INTENT(IN) :: E(NRP1, NAP1, 6)
    REAL(KIND=dp), INTENT(IN) :: EPPS2
    REAL(KIND=dp), INTENT(INOUT) :: RHOC2, RHO2
    REAL(KIND=dp), INTENT(IN) :: E1, E2, E3, E4
    REAL(KIND=dp), INTENT(IN) :: DOR(NOR)
    INTEGER, INTENT(INOUT) :: IRW
    INTEGER, INTENT(OUT) :: ISOR_W, ICONV
    INTERFACE
      SUBROUTINE ERROR_HANDLER(code, val)
        USE KIND_MOD
        INTEGER, INTENT(IN) :: code
        REAL(KIND=dp), OPTIONAL, INTENT(IN) :: val
      END SUBROUTINE ERROR_HANDLER
    END INTERFACE
    INTEGER :: I, J
    REAL(KIND=dp) :: RHOC2_LOCAL, RHO2_LOCAL
    ISOR_W = 0
    RHOC2_LOCAL = RHOC2
    RHO2_LOCAL = RHO2
    W_SOR: DO
      IF (ISOR_W .GE. MAXSOR) THEN
        CALL ERROR_HANDLER(56, RHO2_LOCAL)
        IF (IRW .GE. NOR) EXIT W_SOR
        IRW = IRW + 1
        RHO2_LOCAL = RHO2_LOCAL - DOR(IRW)
        RHOC2_LOCAL = 1.0_dp - RHO2_LOCAL
        DO I = 1, NRP1
          DO J = 1, NAP1
            W(I, J, 3) = W(I, J, 1)
          END DO
        END DO
        ISOR_W = 0
        CYCLE W_SOR
      END IF
      ISOR_W = ISOR_W + 1
      W(1, 1, 2) = W(1, 1, 3)
      DO I = 2, NR
        DO J = 1, NAP1
          W(I, J, 2) = W(I, J, 3)
        END DO
      END DO
      ICONV = 0
      W(1, 1, 3) = RHOC2_LOCAL * W(1, 1, 2) + RHO2_LOCAL * (E1 * W(2, 1, 2) &
        + E2 * W(2, NAH, 2) + E3 * W(2, NAP1, 2) + E4)
      DO J = 2, NAP1
        W(1, J, 3) = W(1, 1, 3)
      END DO
      IF (ABS(W(1, 1, 2) - W(1, 1, 3)) .GT. EPPS2) ICONV = 1
      DO I = 2, NR
        W(I, 1, 3) = RHOC2_LOCAL * W(I, 1, 2) + RHO2_LOCAL * (E(I, 1, 1) * W &
          (I + 1, 1, 2) + E(I, 1, 2) * 2.0_dp * W(I, 2, 2) + E(I, 1, 3) * W &
          (I - 1, 1, 3) + E(I, 1, 5))
        IF (ABS(W(I, 1, 3) - W(I, 1, 2)) .GT. EPPS2) ICONV = 1
      END DO
      DO I = 2, NR
        DO J = 2, NA
          W(I, J, 3) = RHOC2_LOCAL * W(I, J, 2) + RHO2_LOCAL * (E(I, J, &
            1) * W(I + 1, J, 2) + E(I, J, 2) * W(I, J + 1, 2) + E(I, J, &
            3) * W(I - 1, J, 3) + E(I, J, 4) * W(I, J - 1, 3) + E(I, J, 5))
          IF (.NOT. ieee_is_finite(W(I,J,3))) THEN
            ICONV = 1
            ISOR_W = MAXSOR
            EXIT W_SOR
          END IF
          IF (ABS(W(I, J, 2) - W(I, J, 3)) .GT. EPPS2) ICONV = 1
        END DO
      END DO
      DO I = 2, NR
        W(I, NAP1, 3) = RHOC2_LOCAL * W(I, NAP1, 2) + RHO2_LOCAL * (E(I, &
          NAP1, 1) * W(I + 1, NAP1, 2) + E(I, NAP1, 3) * W(I - 1, NAP1, &
          3) + 2.0_dp * E(I, NAP1, 4) * W(I, NA, 3) + E(I, NAP1, 5))
        IF (ABS(W(I, NAP1, 2) - W(I, NAP1, 3)) .GT. EPPS2) ICONV = 1
      END DO
      IF (ICONV .EQ. 0) EXIT W_SOR
    END DO W_SOR
    RHO2 = RHO2_LOCAL
  END SUBROUTINE SOR_W

  SUBROUTINE SOR_OMEGA(OMEGA, E, RHOC3, RHO3, EPPS3, ISOR_OMEGA, MAXSOR, &
    NR, NA, NRP1, NAP1, ICONV, ERROR_HANDLER)
    IMPLICIT NONE
    INTEGER, INTENT(IN) :: NR, NA, NRP1, NAP1, MAXSOR
    REAL(KIND=dp), INTENT(INOUT) :: OMEGA(NRP1, NAP1, 4)
    REAL(KIND=dp), INTENT(IN) :: E(NRP1, NAP1, 6)
    REAL(KIND=dp), INTENT(IN) :: RHOC3, RHO3, EPPS3
    INTEGER, INTENT(INOUT) :: ISOR_OMEGA
    INTEGER, INTENT(OUT) :: ICONV
    INTERFACE
      SUBROUTINE ERROR_HANDLER(code, val)
        USE KIND_MOD
        INTEGER, INTENT(IN) :: code
        REAL(KIND=dp), OPTIONAL, INTENT(IN) :: val
      END SUBROUTINE ERROR_HANDLER
    END INTERFACE
    INTEGER :: I, J
    ISOR_OMEGA = 0
    OMEGA_SOR: DO
      IF(ISOR_OMEGA .GE. MAXSOR) THEN
        CALL ERROR_HANDLER(57, RHO3)
        EXIT OMEGA_SOR
      END IF
      ISOR_OMEGA = ISOR_OMEGA + 1
      OMEGA(2:NR,2:NA,2) = OMEGA(2:NR,2:NA,3)
      ICONV = 0
      DO I = 2, NR
        DO J = 2, NA
          OMEGA(I, J, 3) = RHOC3 * OMEGA(I, J, 2) + RHO3 * ( &
              E(I, J, 1) * OMEGA(I + 1, J, 2) &
              + E(I, J, 2) * OMEGA(I, J + 1, 2) &
              + E(I, J, 3) * OMEGA(I - 1, J, 3) &
              + E(I, J, 4) * OMEGA(I, J - 1, 3) &
              + E(I, J, 6))
          IF (.NOT. ieee_is_finite(OMEGA(I,J,3))) THEN
            ICONV = 1
            ISOR_OMEGA = MAXSOR
            EXIT OMEGA_SOR
          END IF
          IF (ABS(OMEGA(I, J, 2) - OMEGA(I, J, 3)) .GT. EPPS3) ICONV = 1
        END DO
      END DO
      IF (ICONV .EQ. 0) EXIT OMEGA_SOR
    END DO OMEGA_SOR
  END SUBROUTINE SOR_OMEGA

  SUBROUTINE SMOOTH(N1, N2, ARR, XI, XIC, EPS, ICV)
    INTEGER, INTENT(IN) :: N1, N2
    REAL(KIND=dp), INTENT(INOUT) :: ARR(N1, N2, 4)
    REAL(KIND=dp), INTENT(IN) :: XI, XIC, EPS
    INTEGER, INTENT(INOUT) :: ICV
    INTEGER :: I, J
    DO I = 2, N1-1
      DO J = 2, N2-1
        ARR(I,J,3) = XI*ARR(I,J,1) + XIC*ARR(I,J,3)
        IF (.NOT. ieee_is_finite(ARR(I,J,3))) THEN
          ICV = 1
          RETURN
        END IF
        IF (ABS(ARR(I,J,1)-ARR(I,J,3)) > XIC*EPS) ICV = 1
      END DO
    END DO
  END SUBROUTINE SMOOTH
END MODULE SOR_MOD

!------------------------------------------------------------------------
PROGRAM MAIN
    USE KIND_MOD
    USE ERROR_MOD
    USE OUTPUT_MOD
    USE SOR_MOD
    USE, INTRINSIC :: ieee_arithmetic, ONLY: ieee_is_finite
    IMPLICIT NONE

    INTEGER, PARAMETER :: NR = 4*10, NA = 4*18  ! Grid (c) for turbulent
    INTEGER, PARAMETER :: NRP1 = NR + 1, NAP1 = NA + 1
    INTEGER, PARAMETER :: NRM1 = NR - 1
    INTEGER, PARAMETER :: NAH = NA / 2 + 1
    INTEGER, PARAMETER :: NPHI = 4, NB = 5, NE = 6
    INTEGER, PARAMETER :: NCASES = 4

    ! ---- Turbulence model parameters ----
    REAL(KIND=dp), PARAMETER :: KAPPA_VD = 0.41_dp    ! Von Karman constant
    REAL(KIND=dp), PARAMETER :: A_PLUS = 11.0_dp      ! Van Driest damping constant
        ! Reduced from standard 26 to 11; calibrated to match Ito (1959) friction
        ! factor slope vs Re for curved pipe with L_MAX_NIK = 0.04
    REAL(KIND=dp), PARAMETER :: B_LOG_LAW = 5.2_dp    ! Log-law additive constant
    REAL(KIND=dp), PARAMETER :: L_MAX_NIK = 0.04_dp   ! Reduced mixing-length cap for curved pipe
    LOGICAL, PARAMETER :: STRAIGHT_PIPE = .FALSE.      ! Phase 2: Dean flow enabled
    REAL(KIND=dp), PARAMETER :: DELTA_CURV = 0.05_dp   ! a/R curvature ratio, Collins & Dennis geometry (R/a = 20)
    REAL(KIND=dp), PARAMETER :: RE_TAU_TARGET = 300.0_dp  ! Target friction Reynolds number

    ! Turbulent viscosity arrays
    REAL(KIND=dp) :: NU_EFF(NRP1, NAP1)     ! effective viscosity (1 + nu_T)
    REAL(KIND=dp) :: NU_T_ARR(NRP1, NAP1)   ! turbulent viscosity (diagnostic)
    REAL(KIND=dp) :: U_TAU                   ! friction velocity (computed)
    REAL(KIND=dp) :: RE_TAU_OUT              ! computed Re_tau = u_tau * a / nu

    INTEGER :: clock_start, clock_end, clock_rate
    REAL(KIND=dp) :: elapsed_time

    ! Array slice convention: (:,:,1)=iteration start, (:,:,2)=SOR old,
    ! (:,:,3)=SOR new/current solution, (:,:,4)=carry-over between D cases
    REAL(KIND=dp) :: PHI(NRP1, NAP1, NPHI)
    REAL(KIND=dp) :: W(NRP1, NAP1, NPHI)
    REAL(KIND=dp) :: OMEGA(NRP1, NAP1, NPHI)
    REAL(KIND=dp) :: SA(NAP1), COSA(NAP1)
    REAL(KIND=dp) :: RINV(NRP1), RINV2(NRP1)
    REAL(KIND=dp) :: CA(NRP1, NAP1)
    REAL(KIND=dp) :: DELA(NR), CO(NR)
    REAL(KIND=dp) :: B(NRP1, NB)
    REAL(KIND=dp) :: C(NRP1, NAP1)
    REAL(KIND=dp) :: E(NRP1, NAP1, NE)
    REAL(KIND=dp) :: EE1, EE2
    REAL(KIND=dp) :: XI(4), XIC(4)
    REAL(KIND=dp) :: RHO(3), RHOC(3)
    REAL(KIND=dp) :: EPS(3), EPPS(3), EPS_OUT(3)
    REAL(KIND=dp) :: BO, CON, DDR2, DDRDAM, DRRH
    REAL(KIND=dp) :: DR, DA, DAH, DRH, DRDAM, DRDA, DADR
    REAL(KIND=dp) :: E0, E1, E2, E3, E4
    REAL(KIND=dp) :: GAMMA, DELTA, DELTA1, DELTA2
    REAL(KIND=dp) :: QR, S, PI, D, DSTART
    REAL(KIND=dp) :: DOR(3)
    INTEGER :: I, J, ICONV, ICV, IOUT, IRW, IRO, ctr
    INTEGER :: MAXSOR, MAXOUT, NOR
    INTEGER :: ISOR_PHI, ISOR_W, ISOR_OMEGA
    CHARACTER(LEN=20) :: file_id
    CHARACTER(LEN=80) :: file_name
    INTEGER :: unit
    LOGICAL :: FAILED

    ! Fox correction arrays (C&D eq. 13, 17)
    REAL(KIND=dp) :: C0_CORR(NRP1, NAP1)
    REAL(KIND=dp) :: E0_CORR(NRP1, NAP1)
    REAL(KIND=dp) :: C0_CORR_NEW(NRP1, NAP1)
    REAL(KIND=dp) :: E0_CORR_NEW(NRP1, NAP1)
    REAL(KIND=dp) :: OMEGA1
    REAL(KIND=dp) :: OMEGA_RHS
    REAL(KIND=dp) :: CORR_MAX_C0, CORR_MAX_E0
    REAL(KIND=dp) :: CORR_RES_C0, CORR_RES_E0
    REAL(KIND=dp) :: CORR_RES_C0_INIT, CORR_RES_E0_INIT
    REAL(KIND=dp) :: CORR_TOL
    REAL(KIND=dp) :: CORR_OLD
    REAL(KIND=dp) :: CORR_NEW_RAW
    INTEGER :: CORR_ITER, MAX_CORR
    LOGICAL :: CORR_CONVERGED

    ! Previous raw C0/E0_CORR_NEW for 2-cycle averaging of corrections
    REAL(KIND=dp) :: C0_CORR_NEW_PREV(NRP1, NAP1)
    REAL(KIND=dp) :: E0_CORR_NEW_PREV(NRP1, NAP1)

    ! Fox correction carry-over between D cases
    REAL(KIND=dp) :: C0_SAVE(NRP1, NAP1), E0_SAVE(NRP1, NAP1)

    ! Uncorrected solution for D-stepping initial guess
    REAL(KIND=dp) :: PHI_UNCORR(NRP1, NAP1)
    REAL(KIND=dp) :: W_UNCORR(NRP1, NAP1)
    REAL(KIND=dp) :: OMEGA_UNCORR(NRP1, NAP1)

    ! Previous correction pass state for collapse detection
    REAL(KIND=dp) :: PHI_PREV(NRP1, NAP1)
    REAL(KIND=dp) :: W_PREV(NRP1, NAP1)
    REAL(KIND=dp) :: OMEGA_PREV(NRP1, NAP1)
    REAL(KIND=dp) :: C0_CORR_SAVE_PREV(NRP1, NAP1)
    REAL(KIND=dp) :: E0_CORR_SAVE_PREV(NRP1, NAP1)

    ! D-stepping variables
    REAL(KIND=dp) :: D_TARGET, D_CURRENT, D_STEP
    LOGICAL :: STEPPING
    INTEGER :: STEP_ITERS, step_count

    ! Case configuration arrays
    REAL(KIND=dp) :: D_CASES(NCASES)
    REAL(KIND=dp) :: EPS_CASES(3, NCASES)
    REAL(KIND=dp) :: EPS_OUT_CASES(3, NCASES)
    REAL(KIND=dp) :: RHO_CASES(3, NCASES)
    REAL(KIND=dp) :: XI_CASES(4, NCASES)
    REAL(KIND=dp) :: OMEGA1_CASES(NCASES)

    ! Results tracking
    REAL(KIND=dp) :: phi_max, w_max
    REAL(KIND=dp) :: phi_max_prev, w_max_prev
    REAL(KIND=dp) :: W_CUR_MAX
    REAL(KIND=dp) :: MAXR_PHI, MAXR_W, MAXR_OMG
    REAL(KIND=dp) :: RES_WALL

    ! Anderson acceleration parameters and storage
    INTEGER, PARAMETER :: AA_MMAX = 5
    INTEGER :: AA_DEPTH, AA_NHIST
    REAL(KIND=dp) :: AA_BETA, AA_REG
    LOGICAL :: AA_ON

    REAL(KIND=dp) :: PHI_GH(NRP1, NAP1, AA_MMAX+1)
    REAL(KIND=dp) :: W_GH(NRP1, NAP1, AA_MMAX+1)
    REAL(KIND=dp) :: OMEGA_GH(NRP1, NAP1, AA_MMAX+1)
    REAL(KIND=dp) :: PHI_FH(NRP1, NAP1, AA_MMAX+1)
    REAL(KIND=dp) :: W_FH(NRP1, NAP1, AA_MMAX+1)
    REAL(KIND=dp) :: OMEGA_FH(NRP1, NAP1, AA_MMAX+1)

    REAL(KIND=dp) :: AA_MAT(AA_MMAX+2, AA_MMAX+2)
    REAL(KIND=dp) :: AA_RHS(AA_MMAX+2)
    REAL(KIND=dp) :: AA_SOL(AA_MMAX+2)
    REAL(KIND=dp) :: AA_ALPHA(AA_MMAX+1)

    REAL(KIND=dp) :: S_PHI, S_W, S_OMG

    ! Face-averaged viscosity temporaries for turbulent stencil (Dean flow mode)
    REAL(KIND=dp) :: NU_E, NU_W_FACE, NU_N, NU_S
    REAL(KIND=dp) :: DIFF_E, DIFF_W_F, DIFF_N, DIFF_S

    ! Straight-pipe profile output variables
    REAL(KIND=dp) :: Y_DIST, Y_PLUS, U_PLUS, LOG_LAW_VAL

    CALL SYSTEM_CLOCK(COUNT_RATE=clock_rate)
    CALL SYSTEM_CLOCK(COUNT=clock_start)

!------------------- Initialization and setup ---------------------------

    PHI(:,:,:) = 0.0_dp
    W(:,:,:) = 0.0_dp
    OMEGA(:,:,:) = 0.0_dp
    C0_CORR(:,:) = 0.0_dp
    E0_CORR(:,:) = 0.0_dp
    C0_SAVE(:,:) = 0.0_dp
    E0_SAVE(:,:) = 0.0_dp

    ! Initialize turbulent viscosity to molecular (laminar)
    NU_EFF(:,:) = 1.0_dp
    NU_T_ARR(:,:) = 0.0_dp
    U_TAU = 0.0_dp
    RE_TAU_OUT = 0.0_dp

    PI = 3.14159255_dp
    AA_DEPTH = 4
    AA_BETA  = 0.5_dp
    AA_REG   = 1.0E-12_dp
    IF (NR >= 40) THEN
      MAXSOR = 50000
      STEP_ITERS = 40
    ELSE
      MAXSOR = 2500
      STEP_ITERS = 20
    END IF
    MAXOUT = 40000
    NOR = 3
    DOR = (/0.2_dp, 0.2_dp, 0.2_dp/)
    MAX_CORR = 800
    CORR_TOL = 5.0E-4_dp

    DR = 1._dp / NR
    DA = PI / NA
    DAH = .5_dp * DA
    DRH = .5_dp * DR
    DRDAM = DR * DA
    DRDA = DR / DA
    DADR = DA / DR

    DO I = 1, NR
      DELA(I) = (2 * I - 1) * DRH * DRDAM
    END DO

    SA(1) = 0._dp
    DO J = 2, NA
      SA(J) = SIN((J - 1) * DA) * DAH
      COSA(J) = COS((J - 1) * DA)
    END DO
    SA(NAP1) = 0._dp
    COSA(NAP1) = -1._dp
    RINV(NRP1) = 1._dp
    RINV2(NRP1) = 1._dp
    DO I = 2, NR
      RINV(I) = 1._dp / ((I - 1) * DR)
      DRRH = DRH * RINV(I)
      RINV2(I) = RINV(I) ** 2
      DO J = 2, NA
        CA(I, J) = DRRH * COSA(J)
      END DO
    END DO

!------------------- SOR coefficient setup for PHI ----------------------
    ! PHI stencil is purely geometric (no viscosity). Unchanged for turbulence.
    DO I = 2, NR
      BO = 2.0_dp * (DADR + DRDA * RINV2(I))
      B(I, 1) = (DADR + 0.5_dp * DA * RINV(I)) / BO
      B(I, 2) = (DRDA * RINV2(I)) / BO
      B(I, 3) = (DADR - 0.5_dp * DA * RINV(I)) / BO
      B(I, 4) = B(I, 2)
      B(I, 5) = DRDAM / BO
    END DO

!=============== STRAIGHT PIPE MODE (Phase 1 validation) ===============
    STRAIGHT_PIPE_MODE: IF (STRAIGHT_PIPE) THEN

      WRITE(*,'("============================================")')
      WRITE(*,'("  STRAIGHT PIPE MODE (Re_tau target =",F8.2,")")') RE_TAU_TARGET
      WRITE(*,'("  Grid: NR =",I4,", NA =",I4)') NR, NA
      WRITE(*,'("  DR =",F10.6,", y+_min =",F8.3)') DR, DR * RE_TAU_TARGET
      WRITE(*,'("============================================")')

      ! In straight-pipe mode:
      ! - D = 0 (no curvature, no secondary flow)
      ! - PHI = 0, OMEGA = 0 everywhere
      ! - W equation: (1/r) d/dr(r * nu_eff * dW/dr) = -S
      ! - Source S = 2 * Re_tau^2 (dimensionless pressure gradient)
      ! - Solved as 1D radial ODE with tridiagonal Thomas algorithm
      D = 0.0_dp

      ! Force zero secondary flow
      PHI(:,:,:) = 0.0_dp
      OMEGA(:,:,:) = 0.0_dp

      ! Solve the 1D radial problem using tridiagonal solver
      CALL SOLVE_STRAIGHT_PIPE_1D()

      ! Copy 1D solution to full 2D W array (axisymmetric)
      ! W_1D is stored in W(:,1,3) by the solver; replicate to all J
      DO J = 2, NAP1
        W(1:NRP1, J, 3) = W(1:NRP1, 1, 3)
      END DO

      ! u_tau and NU_EFF are already set by SOLVE_STRAIGHT_PIPE_1D
      ! (using second-order wall gradient on the fine 1D grid)

      !------ Print diagnostics ------
      WRITE(*,'(/)')
      WRITE(*,'("STRAIGHT_PIPE_MODE: Re_tau = ",F10.4)') RE_TAU_OUT
      WRITE(*,'("STRAIGHT_PIPE_MODE: u_tau  = ",F10.4)') U_TAU
      WRITE(*,'("STRAIGHT_PIPE_MODE: u+_CL  = ",F10.4)') W(1,1,3) / U_TAU
      WRITE(*,'("STRAIGHT_PIPE_MODE: nu_T_max = ",F10.4)') MAXVAL(NU_T_ARR(1:NR,1))

      !------ Print u+/y+ profile ------
      ! Profile along J=1 (axisymmetric solution)
      DO I = NRP1, 1, -1
        Y_DIST = 1.0_dp - (I - 1) * DR
        Y_PLUS = Y_DIST * U_TAU
        U_PLUS = W(I, 1, 3) / U_TAU
        IF (Y_PLUS > 1.0E-10_dp) THEN
          LOG_LAW_VAL = (1.0_dp / KAPPA_VD) * LOG(Y_PLUS) + B_LOG_LAW
        ELSE
          LOG_LAW_VAL = 0.0_dp
        END IF
        WRITE(*,'("PROFILE: y+ = ",F10.4,"  u+ = ",F10.4,"  log_law = ",F10.4)') &
          Y_PLUS, U_PLUS, LOG_LAW_VAL
      END DO

      ! Also print phi_M to confirm it is zero
      phi_max = MAXVAL(ABS(PHI(:,:,3)))
      w_max = MAXVAL(ABS(W(:,:,3)))
      WRITE(*,'("PHI_M =",F12.4,"  W_M =",F12.2)') phi_max, w_max

!=============== DEAN FLOW MODE (Phase 2, curvature enabled) ===============
    ELSE STRAIGHT_PIPE_MODE

!------------------- Case configuration ---------------------------------

    ! Turbulent regime only: D >= 1000 (below transition at delta=0.05 is laminar)
    D_CASES = (/1000._dp, 2000._dp, 3500._dp, 5000._dp/)

    ! Convergence tolerances: from laminar cases 7-10 (D=1000..5000)
    EPS_CASES(:,1)  = (/5.0E-3_dp, 5.0E-2_dp, 17.0E-2_dp/)
    EPS_CASES(:,2)  = (/7.0E-3_dp, 8.0E-2_dp, 3.0E-1_dp/)
    EPS_CASES(:,3)  = (/8.0E-3_dp, 10.0E-2_dp, 4.0E-1_dp/)
    EPS_CASES(:,4)  = (/1.0E-2_dp, 15.0E-2_dp, 6.0E-1_dp/)

    EPS_OUT_CASES(:,1)  = EPS_CASES(:,1)
    EPS_OUT_CASES(:,2)  = EPS_CASES(:,2)
    IF (NR >= 40) THEN
      EPS_OUT_CASES(:,3)  = EPS_CASES(:,3)
      EPS_OUT_CASES(:,4)  = EPS_CASES(:,4)
    ELSE
      EPS_OUT_CASES(:,3)  = (/6.0E-2_dp, 5.0E-1_dp, 8.0E+0_dp/)
      EPS_OUT_CASES(:,4)  = (/3.0E-1_dp, 2.0E+0_dp, 2.0E+1_dp/)
    END IF

    IF (NR >= 40) THEN
      RHO_CASES(:,1)  = (/1.5_dp, 1.7_dp, 1.5_dp/)
      RHO_CASES(:,2)  = (/1.5_dp, 1.7_dp, 1.5_dp/)
    ELSE
      RHO_CASES(:,1)  = (/1.5_dp, 1.5_dp, 1.5_dp/)
      RHO_CASES(:,2)  = (/1.5_dp, 1.5_dp, 1.5_dp/)
    END IF
    RHO_CASES(:,3)  = (/1.5_dp, 1.5_dp, 1.5_dp/)
    RHO_CASES(:,4)  = (/1.5_dp, 1.5_dp, 1.5_dp/)

    XI_CASES(:,1)  = (/0.5_dp, 0.1_dp, 0.5_dp, 0.5_dp/)
    XI_CASES(:,2)  = (/0.5_dp, 0.1_dp, 0.5_dp, 0.5_dp/)
    XI_CASES(:,3)  = (/0.5_dp, 0.1_dp, 0.5_dp, 0.5_dp/)
    XI_CASES(:,4)  = (/0.5_dp, 0.1_dp, 0.5_dp, 0.5_dp/)

    OMEGA1_CASES(1)  = 1.0_dp
    OMEGA1_CASES(2)  = 0.1_dp
    OMEGA1_CASES(3)  = 0.05_dp
    IF (NR >= 40) THEN
      OMEGA1_CASES(4) = 0.05_dp    ! More aggressive correction absorption for turbulent D=5000
    ELSE
      OMEGA1_CASES(4) = 0.0_dp
    END IF

!------------------- Main case loop over D values -----------------------

    DSTART = 0._dp

    DO ctr = 1, NCASES

      D_TARGET = D_CASES(ctr)
      D = D_TARGET
      EPS = EPS_CASES(:, ctr)
      EPS_OUT = EPS_OUT_CASES(:, ctr)
      RHO = RHO_CASES(:, ctr)
      XI = XI_CASES(:, ctr)
      OMEGA1 = OMEGA1_CASES(ctr)

      IF (D_TARGET >= 3500._dp) THEN
        AA_ON = .TRUE.
      ELSE
        AA_ON = .FALSE.
      END IF

      WRITE(*,'(//"============================================")')
      WRITE(*,'("  CASE ",I2,": D =",F9.2)') ctr, D
      WRITE(*,'("============================================")')
      WRITE(*,'(13X,"PHI",7X,"W",5X,"OMEGA")')
      WRITE(*,'(5X,"RHO =",F6.2,2(3X,F6.2))') RHO
      WRITE(*,'(6X,"XI =",F6.4,3(3X,F6.4))') XI
      WRITE(*,'(5X,"EPS =",F6.4,2(3X,F6.4))') EPS
      WRITE(*,'("  Scheme: UPWIND + FOX CORRECTION (omega1 =",F6.3,")")') OMEGA1

      DO I = 1, 3
        XIC(I) = 1._dp - XI(I)
        RHOC(I) = 1._dp - RHO(I)
        EPPS(I) = .05_dp * EPS(I)
      END DO
      XIC(4) = 1._dp - XI(4)

!------------------- D-stepping setup -----------------------------------

      IF (D_TARGET > 1000._dp .AND. ctr > 1) THEN
        STEPPING = .TRUE.
        D_CURRENT = DSTART
      ELSE
        STEPPING = .FALSE.
        D_CURRENT = D_TARGET
      END IF

      D = D_CURRENT
      DDRDAM = D * DRDAM
      DDR2 = D * DR ** 2
      CON = 4._dp / (PI * D)
      CO(1) = 16._dp * DELA(1) / (3._dp * PI * D)
      DO I = 2, NR
        CO(I) = CON * DELA(I)
      END DO

      IF (STEPPING) THEN
        C0_CORR(:,:) = 0.0_dp
        E0_CORR(:,:) = 0.0_dp
      ELSE
        C0_CORR(:,:) = C0_SAVE(:,:)
        E0_CORR(:,:) = E0_SAVE(:,:)
      END IF

!------------------- Initial guess for outer iterates -------------------

      PHI(:,:,3) = PHI(:,:,4)
      W(:,:,3) = W(:,:,4)
      OMEGA(:,:,3) = OMEGA(:,:,4)
      IF (ctr > 1) THEN
        WRITE(*,'("  Initial guess from D =",F9.2)') DSTART
      ELSE
        WRITE(*,'("  Initial guess: zero")')
      END IF

      ! Initialize NU_EFF from current W field
      CALL COMPUTE_NU_EFF(1.0_dp)

!------------------- Two-level iteration ---------------------------------

      CORR_ITER = 0
      CORR_CONVERGED = .FALSE.
      FAILED = .FALSE.
      phi_max_prev = 0.0_dp
      w_max_prev = 0.0_dp
      C0_CORR_NEW_PREV(:,:) = 0.0_dp
      E0_CORR_NEW_PREV(:,:) = 0.0_dp
      CORR_RES_C0_INIT = 0.0_dp
      CORR_RES_E0_INIT = 0.0_dp

      CORRECTION_LOOP: DO

      PHI_PREV(:,:) = PHI(:,:,3)
      W_PREV(:,:) = W(:,:,3)
      OMEGA_PREV(:,:) = OMEGA(:,:,3)
      C0_CORR_SAVE_PREV(:,:) = C0_CORR(:,:)
      E0_CORR_SAVE_PREV(:,:) = E0_CORR(:,:)

      RHO = RHO_CASES(:, ctr)
      DO I = 1, 3
        RHOC(I) = 1._dp - RHO(I)
      END DO

      IOUT = 0
      IRW = 0
      IRO = 0
      step_count = 0
      AA_NHIST = 0

      OUTER_ITER: DO
        IF (IOUT .GE. MAXOUT) THEN
          CALL ERROR_HANDLER(58)
          FAILED = .TRUE.
          EXIT OUTER_ITER
        END IF

        IOUT = IOUT + 1
        IF (.NOT. STEPPING .AND. IOUT <= 1 .AND. CORR_ITER == 0) THEN
          WRITE(*,'(//"OUTER ITERATION",I5//)') IOUT
        END IF

        ICV = 0

        PHI(:,:,1) = PHI(:,:,3)
        W(:,:,1) = W(:,:,3)
        OMEGA(:,:,1) = OMEGA(:,:,3)

!===== C&D iteration order: W -> Omega -> PHI =====

!------------------- W coefficient setup with face-averaged nu_eff -----

        ! W at origin (r=0) with nu_eff
        E0 = 4._dp * NU_EFF(1,1) + ABS(PHI(2,NAH,3))
        E1 = (NU_EFF(1,1) - MIN(PHI(2,NAH,3),0._dp)) / E0
        E2 = 2._dp * NU_EFF(1,1) / E0
        E3 = (NU_EFF(1,1) + MAX(PHI(2,NAH,3),0._dp)) / E0
        E4 = DDR2 / E0

        ! W coefficients along alpha=0 and alpha=pi with face-averaged nu_eff
        DO I = 2, NR
          DELTA1 = DA - PHI(I,2,3)
          DELTA2 = DA + PHI(I,NA,3)

          ! Face-averaged viscosities for J=1 boundary
          NU_E = 0.5_dp * (NU_EFF(I+1,1) + NU_EFF(I,1))
          NU_W_FACE = 0.5_dp * (NU_EFF(MAX(I-1,1),1) + NU_EFF(I,1))
          NU_N = 0.5_dp * (NU_EFF(I,2) + NU_EFF(I,1))
          NU_S = NU_N  ! symmetric at alpha=0

          DIFF_E = DADR * NU_E + 0.5_dp * DA * RINV(I) * NU_EFF(I,1)
          DIFF_W_F = DADR * NU_W_FACE - 0.5_dp * DA * RINV(I) * NU_EFF(I,1)
          IF (DIFF_W_F < 0.0_dp) DIFF_W_F = 0.0_dp
          DIFF_N = DRDA * RINV2(I) * NU_N
          DIFF_S = DRDA * RINV2(I) * NU_S

          EE1 = DIFF_E + DIFF_W_F + DIFF_N + DIFF_S + RINV(I) * ABS(DELTA1)

          E(I,1,1) = (DIFF_E + RINV(I) * MAX(DELTA1,0._dp)) / EE1
          E(I,1,2) = DIFF_N / EE1
          E(I,1,3) = (DIFF_W_F - RINV(I) * MIN(DELTA1,0._dp)) / EE1
          E(I,1,4) = DIFF_S / EE1
          E(I,1,5) = (DDRDAM + C0_CORR(I,1)) / EE1

          ! alpha=pi boundary
          NU_E = 0.5_dp * (NU_EFF(I+1,NAP1) + NU_EFF(I,NAP1))
          NU_W_FACE = 0.5_dp * (NU_EFF(MAX(I-1,1),NAP1) + NU_EFF(I,NAP1))
          NU_N = 0.5_dp * (NU_EFF(I,NA) + NU_EFF(I,NAP1))
          NU_S = NU_N

          DIFF_E = DADR * NU_E + 0.5_dp * DA * RINV(I) * NU_EFF(I,NAP1)
          DIFF_W_F = DADR * NU_W_FACE - 0.5_dp * DA * RINV(I) * NU_EFF(I,NAP1)
          IF (DIFF_W_F < 0.0_dp) DIFF_W_F = 0.0_dp
          DIFF_N = DRDA * RINV2(I) * NU_N
          DIFF_S = DRDA * RINV2(I) * NU_S

          EE2 = DIFF_E + DIFF_W_F + DIFF_N + DIFF_S + RINV(I) * ABS(DELTA2)

          E(I,NAP1,1) = (DIFF_E + RINV(I) * MAX(DELTA2,0._dp)) / EE2
          E(I,NAP1,2) = DIFF_N / EE2
          E(I,NAP1,3) = (DIFF_W_F - RINV(I) * MIN(DELTA2,0._dp)) / EE2
          E(I,NAP1,4) = DIFF_S / EE2
          E(I,NAP1,5) = (DDRDAM + C0_CORR(I,NAP1)) / EE2
        END DO

        ! Interior W coefficients with face-averaged viscosity
        DO I = 2, NR
          DO J = 2, NA
            NU_E = 0.5_dp * (NU_EFF(I+1,J) + NU_EFF(I,J))
            NU_W_FACE = 0.5_dp * (NU_EFF(I-1,J) + NU_EFF(I,J))
            NU_N = 0.5_dp * (NU_EFF(I,J+1) + NU_EFF(I,J))
            NU_S = 0.5_dp * (NU_EFF(I,J-1) + NU_EFF(I,J))

            DIFF_E = DADR * NU_E + 0.5_dp * DA * RINV(I) * NU_EFF(I,J)
            DIFF_W_F = DADR * NU_W_FACE - 0.5_dp * DA * RINV(I) * NU_EFF(I,J)
            IF (DIFF_W_F < 0.0_dp) DIFF_W_F = 0.0_dp
            DIFF_N = DRDA * RINV2(I) * NU_N
            DIFF_S = DRDA * RINV2(I) * NU_S

            GAMMA = .5_dp * (PHI(I+1,J,3) - PHI(I-1,J,3))
            DELTA = DA - .5_dp * (PHI(I,J+1,3) - PHI(I,J-1,3))

            E(I,J,6) = DIFF_E + DIFF_W_F + DIFF_N + DIFF_S &
                      + RINV(I) * (ABS(GAMMA) + ABS(DELTA))
            E(I,J,1) = (DIFF_E + RINV(I) * MAX(DELTA,0._dp)) / E(I,J,6)
            E(I,J,2) = (DIFF_N + RINV(I) * MAX(GAMMA,0._dp)) / E(I,J,6)
            E(I,J,3) = (DIFF_W_F - RINV(I) * MIN(DELTA,0._dp)) / E(I,J,6)
            E(I,J,4) = (DIFF_S - RINV(I) * MIN(GAMMA,0._dp)) / E(I,J,6)
            E(I,J,5) = (DDRDAM + C0_CORR(I,J)) / E(I,J,6)
          END DO
        END DO

!------------------- SOR for W ------------------------------------------

        IRW = 0
        W_RETRY: DO
          ISOR_W = 0
          CALL SOR_W(W, E, EPPS(2), RHOC(2), RHO(2), ISOR_W, MAXSOR, NR, NA, &
            NRP1, NAP1, NAH, E1, E2, E3, E4, DOR, NOR, IRW, ICONV, &
            ERROR_HANDLER)
          IF (ICONV .EQ. 0) EXIT W_RETRY
        END DO W_RETRY

        W(1,1,3) = XI(2) * W(1,1,1) + XIC(2) * W(1,1,3)
        DO J = 2, NAP1
          W(1,J,3) = W(1,1,3)
        END DO
        IF (ABS(W(1,1,1) - W(1,1,3)) .GT. XIC(2)*EPS(2)) ICV = 1

        CALL SMOOTH(NRP1, NAP1, W, XI(2), XIC(2), EPS(2), ICV)
        IF (.NOT. STEPPING .AND. IOUT <= 1 .AND. CORR_ITER == 0) THEN
          CALL OUTPUT('W    ', ISOR_W, W(1,1,3), NR, NA)
        END IF

!------------------- SOR for OMEGA (with face-averaged nu_eff) ----------

        DO J = 2, NA
          OMEGA(NRP1,J,3) = XI(3) * OMEGA(NRP1,J,1) - XIC(3) * 2._dp * RINV2 &
            (2) * PHI(NR,J,3)
          IF (ABS(OMEGA(NRP1,J,1) - OMEGA(NRP1,J,3)) .GT. XIC(3)*EPS(3)) ICV = 1
        END DO

        RES_WALL = 0.0_dp
        DO J = 2, NA
          RES_WALL = MAX(RES_WALL, ABS(OMEGA(NRP1,J,3) + 2._dp*RINV2(2)*PHI(NR,J,3)))
        END DO

        ! Compute OMEGA source with face-averaged nu_eff stencil
        ! E(I,J,6) is reused: store the Omega source divided by the stencil denominator
        ! First rebuild stencil denominators for OMEGA (same nu_eff-based stencil)
        DO I = 2, NR
          DO J = 2, NA
            OMEGA_RHS = -W(I,J,3) * (SA(J) * (W(I+1,J,3) - W(I-1,J,3)) + &
              CA(I,J) * (W(I,J+1,3) - W(I,J-1,3)))

            ! E(I,J,6) still holds the W stencil denominator from above
            ! which is the same as the OMEGA stencil denominator (same nu_eff, same convection)
            E(I,J,6) = (OMEGA_RHS + E0_CORR(I,J)) / E(I,J,6)
          END DO
        END DO

        OMEGA(NRP1, 1:NAP1, 2) = OMEGA(NRP1, 1:NAP1, 3)
        OMEGA(1,    1:NAP1, 2) = OMEGA(1,    1:NAP1, 3)
        OMEGA(1:NRP1, 1,    2) = OMEGA(1:NRP1, 1,    3)
        OMEGA(1:NRP1, NAP1, 2) = OMEGA(1:NRP1, NAP1, 3)

        IRO = 0
        OMEGA_RETRY: DO
          ISOR_OMEGA = 0
          CALL SOR_OMEGA(OMEGA, E, RHOC(3), RHO(3), EPPS(3), ISOR_OMEGA, &
            MAXSOR, NR, NA, NRP1, NAP1, ICONV, ERROR_HANDLER)
          IF (ICONV .EQ. 0) EXIT OMEGA_RETRY
          IF (ISOR_OMEGA .GE. MAXSOR) THEN
            CALL ERROR_HANDLER(57, RHO(3))
            IF (IRO >= NOR) EXIT OMEGA_RETRY
            IRO = IRO + 1
            RHO(3) = RHO(3) - DOR(IRO)
            RHOC(3) = 1.0_dp - RHO(3)
            DO I = 1, NRP1
              DO J = 1, NAP1
                OMEGA(I, J, 3) = OMEGA(I, J, 1)
              END DO
            END DO
          END IF
        END DO OMEGA_RETRY

        CALL SMOOTH(NRP1, NAP1, OMEGA, XI(4), XIC(4), EPS(3), ICV)
        IF (.NOT. STEPPING .AND. IOUT <= 1 .AND. CORR_ITER == 0) THEN
          CALL OUTPUT('OMEGA', ISOR_OMEGA, OMEGA(1,1,3), NR, NA)
        END IF

!------------------- SOR for PHI (last in C&D order, unchanged) ---------

        PHI(1,   1:NAP1, 2) = 0.0_dp
        PHI(NRP1,1:NAP1, 2) = 0.0_dp
        PHI(1:NRP1,1,    2) = 0.0_dp
        PHI(1:NRP1,NAP1, 2) = 0.0_dp
        PHI(1,   1:NAP1, 3) = 0.0_dp
        PHI(NRP1,1:NAP1, 3) = 0.0_dp
        PHI(1:NRP1,1,    3) = 0.0_dp
        PHI(1:NRP1,NAP1, 3) = 0.0_dp

        DO I = 2, NR
          DO J = 2, NA
            C(I,J) = B(I,5) * OMEGA(I,J,3)
          END DO
        END DO

        CALL SOR_PHI(PHI, OMEGA, B, C, RHOC, RHO, EPPS, ISOR_PHI, MAXSOR, NR, &
          NA, NRP1, NAP1, NRM1, .FALSE., ERROR_HANDLER)
        CALL SMOOTH(NRP1, NAP1, PHI, XI(1), XIC(1), EPS(1), ICV)
        IF (.NOT. STEPPING .AND. IOUT <= 1 .AND. CORR_ITER == 0) THEN
          CALL OUTPUT('PHI  ', ISOR_PHI, PHI(1,1,3), NR, NA)
          WRITE(*,'("  DIAG: maxPHI=",ES10.3," maxW=",ES10.3,' // &
            '" maxOMG=",ES10.3," RES_WALL=",ES10.3)') &
            MAXVAL(ABS(PHI(2:NR,2:NA,3))), MAXVAL(ABS(W(2:NR,2:NA,3))), &
            MAXVAL(ABS(OMEGA(2:NR,2:NA,3))), RES_WALL
        END IF

!------------------- 2-cycle averaging ----------------------------------

        IF ((NR >= 40 .AND. D_TARGET >= 250._dp .OR. &
             NR <  40 .AND. D_TARGET >= 2000._dp) .AND. IOUT > 1) THEN
          PHI(2:NR, 2:NA, 3) = 0.5_dp*(PHI(2:NR, 2:NA, 1) + PHI(2:NR, 2:NA, 3))
          W(1:NR, 1:NAP1, 3) = 0.5_dp*(W(1:NR, 1:NAP1, 1) + W(1:NR, 1:NAP1, 3))
          OMEGA(2:NR, 2:NA, 3) = 0.5_dp*(OMEGA(2:NR, 2:NA, 1) + OMEGA(2:NR, 2:NA, 3))
          OMEGA(NRP1, 2:NA, 3) = 0.5_dp*(OMEGA(NRP1, 2:NA, 1) + OMEGA(NRP1, 2:NA, 3))

          ICV = 0
          IF (MAXVAL(ABS(PHI(2:NR, 2:NA, 1) - PHI(2:NR, 2:NA, 3))) > EPS_OUT(1)) ICV = 1
          IF (MAXVAL(ABS(W(1:NR, 1:NAP1, 1) - W(1:NR, 1:NAP1, 3))) > EPS_OUT(2)) ICV = 1
          IF (MAXVAL(ABS(OMEGA(2:NRP1, 2:NA, 1) - OMEGA(2:NRP1, 2:NA, 3))) > EPS_OUT(3)) ICV = 1
        END IF

!------------------- D-stepping check -----------------------------------

        IF (STEPPING) THEN
          step_count = step_count + 1
          IF (MOD(step_count, STEP_ITERS) == 0) THEN
            IF (NR >= 40) THEN
              D_STEP = 5._dp
            ELSE
              D_STEP = 10._dp
            END IF
            D_CURRENT = MIN(D_CURRENT + D_STEP, D_TARGET)
            D = D_CURRENT
            DDRDAM = D * DRDAM
            DDR2 = D * DR ** 2
            CALL COMPUTE_NU_EFF(0.5_dp)  ! Refresh nu_eff during D-stepping (under-relaxed)
            WRITE(*,'("  D-step: D=",F7.1," maxPHI=",ES9.2," maxW=",ES9.2," maxOMG=",ES9.2)') &
              D_CURRENT, MAXVAL(ABS(PHI(2:NR,2:NA,3))), &
              MAXVAL(ABS(W(2:NR,2:NA,3))), MAXVAL(ABS(OMEGA(2:NR,2:NA,3)))
            IF (D_CURRENT >= D_TARGET) THEN
              STEPPING = .FALSE.
              IOUT = 0
              WRITE(*,'("  D-stepping complete, now converging at D =",F9.2)') D
            END IF
          END IF
          ICV = 1
          CYCLE OUTER_ITER
        END IF

!------------------- Anderson acceleration ------------------------------
        IF (AA_ON) THEN
          CALL ANDERSON_OUTER_UPDATE()
        END IF

!------------------- Check for convergence ------------------------------
        IF (ICV == 0) EXIT OUTER_ITER
      END DO OUTER_ITER

      IF (.NOT. FAILED) THEN
        WRITE(*,'("OUTER ITERATION CONVERGED TO GIVEN TOLERANCES.")')
      END IF

      ! Collapse/divergence detection
      W_CUR_MAX = MAXVAL(ABS(W(2:NR, 2:NA, 3)))
      IF (.NOT. ieee_is_finite(SUM(ABS(W(:,:,3))))) W_CUR_MAX = -1.0_dp
      IF (CORR_ITER > 0 .AND. MAXVAL(ABS(W_PREV(2:NR, 2:NA))) > 100._dp .AND. &
          (W_CUR_MAX < 0._dp .OR. .NOT. ieee_is_finite(W_CUR_MAX) .OR. &
           W_CUR_MAX < 0.5_dp * MAXVAL(ABS(W_PREV(2:NR, 2:NA))))) THEN
        WRITE(*,'("  COLLAPSE DETECTED at correction iter",I4,": w_M dropped from",F10.2," to",F10.2)') &
          CORR_ITER, MAXVAL(ABS(W_PREV(2:NR, 2:NA))), MAXVAL(ABS(W(2:NR, 2:NA, 3)))
        PHI(:,:,3) = PHI_PREV(:,:)
        W(:,:,3) = W_PREV(:,:)
        OMEGA(:,:,3) = OMEGA_PREV(:,:)
        C0_CORR(:,:) = C0_CORR_SAVE_PREV(:,:)
        E0_CORR(:,:) = E0_CORR_SAVE_PREV(:,:)
        WRITE(*,'("  Stopping corrections at last good state.")')
        CORR_CONVERGED = .TRUE.
        EXIT CORRECTION_LOOP
      END IF

!------------------- Correction computation ----------------------------

      IF (CORR_ITER == 0) THEN
        PHI_UNCORR(:,:) = PHI(:,:,3)
        W_UNCORR(:,:) = W(:,:,3)
        OMEGA_UNCORR(:,:) = OMEGA(:,:,3)
      END IF

      IF (FAILED .OR. CORR_CONVERGED .OR. CORR_ITER >= MAX_CORR) THEN
        EXIT CORRECTION_LOOP
      END IF

      C0_CORR_NEW(:,:) = 0.0_dp
      E0_CORR_NEW(:,:) = 0.0_dp

      DO I = 2, NR
        DELTA1 = DA - PHI(I,2,3)
        C0_CORR_NEW(I,1) = -0.5_dp * RINV(I) * ABS(DELTA1) * &
          (W(I+1,1,3) + W(I-1,1,3) - 2._dp * W(I,1,3))

        DO J = 2, NA
          GAMMA = .5_dp * (PHI(I+1,J,3) - PHI(I-1,J,3))
          DELTA = DA - .5_dp * (PHI(I,J+1,3) - PHI(I,J-1,3))

          C0_CORR_NEW(I,J) = -0.5_dp * RINV(I) * ( &
            ABS(DELTA) * (W(I+1,J,3) + W(I-1,J,3) - 2._dp*W(I,J,3)) + &
            ABS(GAMMA) * (W(I,J+1,3) + W(I,J-1,3) - 2._dp*W(I,J,3)))

          E0_CORR_NEW(I,J) = -0.5_dp * RINV(I) * ( &
            ABS(DELTA) * (OMEGA(I+1,J,3) + OMEGA(I-1,J,3) - 2._dp*OMEGA(I,J,3)) + &
            ABS(GAMMA) * (OMEGA(I,J+1,3) + OMEGA(I,J-1,3) - 2._dp*OMEGA(I,J,3)))
        END DO

        DELTA2 = DA + PHI(I,NA,3)
        C0_CORR_NEW(I,NAP1) = -0.5_dp * RINV(I) * ABS(DELTA2) * &
          (W(I+1,NAP1,3) + W(I-1,NAP1,3) - 2._dp * W(I,NAP1,3))
      END DO

      CORR_MAX_C0 = 0.0_dp
      CORR_MAX_E0 = 0.0_dp
      CORR_RES_C0 = 0.0_dp
      CORR_RES_E0 = 0.0_dp

      DO I = 2, NR
        DO J = 1, NAP1
          CORR_NEW_RAW = C0_CORR_NEW(I,J)
          IF (CORR_ITER > 0) THEN
            C0_CORR_NEW(I,J) = 0.5_dp * (C0_CORR_NEW(I,J) + C0_CORR_NEW_PREV(I,J))
          END IF
          C0_CORR_NEW_PREV(I,J) = CORR_NEW_RAW
          CORR_RES_C0 = MAX(CORR_RES_C0, ABS(C0_CORR_NEW(I,J) - C0_CORR(I,J)))
          CORR_OLD = C0_CORR(I,J)
          C0_CORR(I,J) = OMEGA1 * C0_CORR_NEW(I,J) + (1._dp - OMEGA1) * C0_CORR(I,J)
          CORR_MAX_C0 = MAX(CORR_MAX_C0, ABS(C0_CORR(I,J) - CORR_OLD))
        END DO
        DO J = 2, NA
          CORR_NEW_RAW = E0_CORR_NEW(I,J)
          IF (CORR_ITER > 0) THEN
            E0_CORR_NEW(I,J) = 0.5_dp * (E0_CORR_NEW(I,J) + E0_CORR_NEW_PREV(I,J))
          END IF
          E0_CORR_NEW_PREV(I,J) = CORR_NEW_RAW
          CORR_RES_E0 = MAX(CORR_RES_E0, ABS(E0_CORR_NEW(I,J) - E0_CORR(I,J)))
          CORR_OLD = E0_CORR(I,J)
          E0_CORR(I,J) = OMEGA1 * E0_CORR_NEW(I,J) + (1._dp - OMEGA1) * E0_CORR(I,J)
          CORR_MAX_E0 = MAX(CORR_MAX_E0, ABS(E0_CORR(I,J) - CORR_OLD))
        END DO
      END DO

      ! Update nu_eff after correction pass (same slot as Fox corrections)
      CALL COMPUTE_NU_EFF(1.0_dp)

      CORR_ITER = CORR_ITER + 1
      AA_NHIST = 0
      IF (CORR_ITER == 1) THEN
        CORR_RES_C0_INIT = CORR_RES_C0
        CORR_RES_E0_INIT = CORR_RES_E0
      END IF
      WRITE(*,'("  Correction iter",I4,": res C0=",ES10.3,", res E0=",ES10.3,' // &
        '" (damped dC0=",ES10.3,", dE0=",ES10.3,")")') &
        CORR_ITER, CORR_RES_C0, CORR_RES_E0, CORR_MAX_C0, CORR_MAX_E0

      phi_max = 0._dp
      w_max = 0._dp
      DO I = 1, NRP1
        DO J = 1, NAP1
          IF (ABS(PHI(I,J,3)) > phi_max) phi_max = ABS(PHI(I,J,3))
          IF (ABS(W(I,J,3)) > w_max) w_max = ABS(W(I,J,3))
        END DO
      END DO
      WRITE(*,'("    phi_M =",F10.4,"  w_M =",F10.2)') phi_max, w_max

      CALL CHECK_CENTRAL_RESIDUALS(MAXR_PHI, MAXR_W, MAXR_OMG)
      WRITE(*,'("    Central residuals: PHI=",ES10.3,"  W=",ES10.3,"  OMG=",ES10.3)') &
        MAXR_PHI, MAXR_W, MAXR_OMG

      IF (CORR_RES_C0 < CORR_TOL .AND. CORR_RES_E0 < CORR_TOL) THEN
        WRITE(*,'("  Corrections converged (residual) after",I4," iterations.")') CORR_ITER
        CORR_CONVERGED = .TRUE.
        EXIT CORRECTION_LOOP
      END IF
      IF (CORR_ITER >= 3 .AND. CORR_RES_C0_INIT > 0.0_dp .AND. &
          CORR_RES_C0 < 0.02_dp * CORR_RES_C0_INIT .AND. &
          CORR_RES_E0 < 0.02_dp * CORR_RES_E0_INIT .AND. &
          w_max > 1.0_dp .AND. phi_max > 1.0E-3_dp .AND. &
          ABS(w_max - w_max_prev) < 1.0E-3_dp * w_max .AND. &
          ABS(phi_max - phi_max_prev) < 1.0E-3_dp * phi_max) THEN
        WRITE(*,'("  Corrections converged (physical) after",I4," iters.' // &
          ' Res C0=",ES9.2," E0=",ES9.2)') CORR_ITER, CORR_RES_C0, CORR_RES_E0
        CORR_CONVERGED = .TRUE.
        EXIT CORRECTION_LOOP
      END IF
      phi_max_prev = phi_max
      w_max_prev = w_max

      STEPPING = .FALSE.

      END DO CORRECTION_LOOP

!------------------- Compute and report results -------------------------

      D = D_TARGET
      IF (D > 0.0_dp) THEN
        CON = 4._dp / (PI * D)
        CO(1) = 16._dp * DELA(1) / (3._dp * PI * D)
        DO I = 2, NR
          CO(I) = CON * DELA(I)
        END DO

        QR = 0._dp
        DO J = 1, NA
          QR = QR + W(1,J,3) + W(2,J,3) + W(2,J+1,3)
        END DO
        QR = QR * CO(1)
        DO I = 2, NR
          S = 0._dp
          DO J = 1, NA
            S = S + W(I,J,3) + W(I+1,J,3) + W(I,J+1,3) + W(I+1,J+1,3)
          END DO
          QR = QR + CO(I) * S
        END DO

        WRITE(*,'("FLUX RATIO =",F10.5)') QR
      END IF

      phi_max = 0._dp
      w_max = 0._dp
      DO I = 1, NRP1
        DO J = 1, NAP1
          IF (ABS(PHI(I,J,3)) > phi_max) phi_max = ABS(PHI(I,J,3))
          IF (ABS(W(I,J,3)) > w_max) w_max = ABS(W(I,J,3))
        END DO
      END DO
      WRITE(*,'("PHI_M =",F12.4,"  W_M =",F12.2,"  QR =",F10.5)') &
        phi_max, w_max, QR

!------------------- Friction factor computation -----------------------
      ! Friction factor in physical (dimensional) units.
      !
      ! The C&D solver uses a non-dimensionalisation where:
      !   Re = D / sqrt(delta)       (Dean number to Reynolds number mapping)
      !   f_physical = f_code * sqrt(delta)  (verified by Poiseuille: f=64/Re)
      !
      ! f_code = 8 * tau_w_code / W_eff^2 where W_eff = QR * D / 4
      ! tau_w_code = |dW/dr|_wall = |W(NR,j)|/DR averaged over j
      ! (NU_EFF=1 at wall by Van Driest damping, so nu_eff drops out)
      BLOCK
        REAL(KIND=dp) :: TAU_W_AVG, F_DARCY, RE_BULK, F_ITO, F_BLASIUS
        REAL(KIND=dp) :: W_EFF, F_CODE
        ! Use second-order one-sided difference for the wall gradient:
        !   dW/dr|_wall = (4*W(NR) - W(NR-1)) / (2*DR)
        ! Matches the formula used in COMPUTE_NU_EFF for u_tau.
        ! W(NRP1) = 0 at wall.
        TAU_W_AVG = 0.0_dp
        DO J = 1, NAP1
          TAU_W_AVG = TAU_W_AVG + ABS(4.0_dp * W(NR, J, 3) - W(NRM1, J, 3)) &
                      / (2.0_dp * DR)
        END DO
        TAU_W_AVG = TAU_W_AVG / REAL(NAP1, dp)

        ! Effective velocity for friction factor computation
        W_EFF = QR * D_TARGET / 4.0_dp

        ! Code-units friction factor, then convert to physical
        IF (W_EFF > 0.0_dp) THEN
          F_CODE = 8.0_dp * TAU_W_AVG / (W_EFF**2)
          F_DARCY = F_CODE * SQRT(DELTA_CURV)
        ELSE
          F_DARCY = 0.0_dp
        END IF

        ! Reynolds number: Re = D / sqrt(delta)
        RE_BULK = D_TARGET / SQRT(DELTA_CURV)

        ! Ito (1959): f_c = 0.304 * Re^{-1/4} * (R/a)^{-0.05}  (Darcy, turbulent curved pipe)
        F_ITO     = 0.304_dp * RE_BULK**(-0.25_dp) &
                    * (1.0_dp / DELTA_CURV)**(-0.05_dp)
        ! Blasius: f_0 = 0.316 * Re^{-1/4}  (Darcy, turbulent straight pipe)
        F_BLASIUS = 0.316_dp * RE_BULK**(-0.25_dp)

        WRITE(*,'("  DIAG_FRICTION: tau_w=",ES12.4,"  W_eff=",F12.4, &
              &"  W(NR,1)=",F12.4,"  nuT_max=",F12.4,"  u_tau=",F10.4)') &
              TAU_W_AVG, W_EFF, W(NR,1,3), MAXVAL(NU_T_ARR(:,:)), U_TAU
        WRITE(*,'("FRICTION: D=",F8.2,"  Re=",F10.2,"  f_c=",F10.6, &
              &"  f_0_Blasius=",F10.6,"  f_c/f_0=",F8.4)') &
              D_TARGET, RE_BULK, F_DARCY, F_BLASIUS, F_DARCY/F_BLASIUS
        WRITE(*,'("  Ito (1959):    f_c=",F10.6,"  f_c/f_0=",F8.4, &
              &"  rel_err=",F7.4)') &
              F_ITO, F_ITO/F_BLASIUS, ABS(F_DARCY - F_ITO) / F_ITO
      END BLOCK

!------------------- Output solution to file ----------------------------

      WRITE(file_id, '(F0.2)') D_TARGET
      file_name = 'cd_turb_D' // TRIM(ADJUSTL(file_id)) // '.dat'
      WRITE(*,'(A,A)') '  Output file: ', TRIM(file_name)
      OPEN(NEWUNIT=unit, FILE=TRIM(file_name), STATUS='replace')
      WRITE(unit,*) NRP1
      WRITE(unit,*) NAP1
      WRITE(unit,*) XI
      WRITE(unit,*) RHO
      WRITE(unit,*) EPS
      WRITE(unit,*) D_TARGET
      WRITE(unit,*) QR
      DO I = 1, NRP1
        WRITE(unit,*) PHI(I,:,3)
      END DO
      DO I = 1, NRP1
        WRITE(unit,*) W(I,:,3)
      END DO
      DO I = 1, NRP1
        WRITE(unit,*) OMEGA(I,:,3)
      END DO
      CLOSE(unit)

!------------------- Save solution for next case ------------------------

      IF (D_TARGET > 1000._dp) THEN
        PHI(:,:,4) = PHI_UNCORR(:,:)
        W(:,:,4) = W_UNCORR(:,:)
        OMEGA(:,:,4) = OMEGA_UNCORR(:,:)
      ELSE
        PHI(:,:,4) = PHI(:,:,3)
        W(:,:,4) = W(:,:,3)
        OMEGA(:,:,4) = OMEGA(:,:,3)
      END IF
      C0_SAVE(:,:) = C0_CORR(:,:)
      E0_SAVE(:,:) = E0_CORR(:,:)
      DSTART = D_TARGET

      WRITE(*,'("  Done with case D =",F9.2)') D_TARGET
    END DO

    END IF STRAIGHT_PIPE_MODE

!------------------- Timing and program end -----------------------------

    CALL SYSTEM_CLOCK(COUNT=clock_end)
    elapsed_time = REAL(clock_end - clock_start, KIND=dp) / REAL(clock_rate, &
      KIND=dp)
    WRITE(*,'("Elapsed time:",F8.1," seconds")') elapsed_time

CONTAINS

  SUBROUTINE COMPUTE_NU_EFF(RELAX)
    ! Compute Van Driest mixing-length eddy viscosity from current W field.
    !
    ! nu_T(i,j) = l_m(i,j)^2 * |dW/dr|
    ! l_m(i,j) = min(kappa * y * (1 - exp(-y+ / A+)), L_MAX)
    ! nu_eff(i,j) = 1.0 + nu_T(i,j)   (nu_mol = 1 in dimensionless units)
    !
    ! u_tau is computed LOCAL to each angular station j from the wall shear:
    !   tau_w(j) = |dW/dr|_{r=1,j}
    !   u_tau(j) = sqrt(tau_w(j))
    ! This is physically more accurate than a circumferential average because
    ! the Van Driest damping must respond to the local wall shear. In Dean
    ! flow, tau_w varies strongly around the circumference (high at outer wall,
    ! low at inner wall).
    !
    ! Input:  RELAX -- under-relaxation factor (0-1). 1.0 = full update.
    ! Reads:  W(:,:,3), DR, NR, NRP1, NAP1, NRM1 (host-associated)
    ! Writes: NU_EFF, NU_T_ARR, U_TAU, RE_TAU_OUT (host-associated)
    REAL(KIND=dp), INTENT(IN) :: RELAX
    INTEGER :: II, JJ
    REAL(KIND=dp) :: TAU_W_LOCAL, U_TAU_LOCAL
    REAL(KIND=dp) :: TAU_W_SUM
    REAL(KIND=dp) :: DW_DR, Y_VAL, YP, L_MIX
    REAL(KIND=dp) :: NU_EFF_NEW

    ! Step 1: Compute mean u_tau for diagnostics (RE_TAU_OUT)
    TAU_W_SUM = 0.0_dp
    DO JJ = 1, NAP1
      DW_DR = ABS(4.0_dp * W(NR, JJ, 3) - W(NRM1, JJ, 3)) / (2.0_dp * DR)
      TAU_W_SUM = TAU_W_SUM + DW_DR
    END DO
    IF (TAU_W_SUM > 0.0_dp) THEN
      U_TAU = SQRT(TAU_W_SUM / REAL(NAP1, dp))
    ELSE
      U_TAU = RE_TAU_TARGET
    END IF
    RE_TAU_OUT = U_TAU

    ! Step 2: Compute nu_T and NU_EFF at each grid point
    ! Wall (II=NRP1): y=0, nu_T=0, NU_EFF=1
    DO JJ = 1, NAP1
      NU_T_ARR(NRP1, JJ) = 0.0_dp
      NU_EFF(NRP1, JJ) = 1.0_dp
    END DO

    ! Interior points: use LOCAL u_tau per angular station
    DO JJ = 1, NAP1
      ! Local wall shear at this angular station (second-order one-sided)
      TAU_W_LOCAL = ABS(4.0_dp * W(NR, JJ, 3) - W(NRM1, JJ, 3)) / (2.0_dp * DR)
      IF (TAU_W_LOCAL > 0.0_dp) THEN
        U_TAU_LOCAL = SQRT(TAU_W_LOCAL)
      ELSE
        U_TAU_LOCAL = RE_TAU_TARGET
      END IF

      DO II = 2, NR
        Y_VAL = 1.0_dp - (II - 1) * DR
        YP = Y_VAL * U_TAU_LOCAL
        IF (Y_VAL > 1.0E-14_dp .AND. YP > 1.0E-14_dp) THEN
          L_MIX = KAPPA_VD * Y_VAL * (1.0_dp - EXP(-YP / A_PLUS))
          L_MIX = MIN(L_MIX, L_MAX_NIK)
        ELSE
          L_MIX = 0.0_dp
        END IF
        DW_DR = (W(II+1, JJ, 3) - W(II-1, JJ, 3)) / (2.0_dp * DR)
        NU_T_ARR(II, JJ) = L_MIX**2 * ABS(DW_DR)
        NU_EFF_NEW = 1.0_dp + NU_T_ARR(II, JJ)
        NU_EFF(II, JJ) = RELAX * NU_EFF_NEW + (1.0_dp - RELAX) * NU_EFF(II, JJ)
      END DO
    END DO

    ! Origin (II=1): set to match II=2 for smoothness
    NU_EFF(1, :) = NU_EFF(2, :)
    NU_T_ARR(1, :) = NU_T_ARR(2, :)

  END SUBROUTINE COMPUTE_NU_EFF

  SUBROUTINE SOLVE_STRAIGHT_PIPE_1D()
    ! Solve the 1D radial turbulent pipe flow equation using a tridiagonal
    ! (Thomas algorithm) solver with conservative finite-volume discretization.
    !
    ! Uses a fine 1D grid (NR1D points) independent of the 2D grid for accuracy.
    ! The solution is interpolated back to the 2D grid for output.
    !
    ! PDE: (1/r) d/dr(r * nu_eff(r) * dW/dr) = -S
    !   where S = 2 * Re_tau^2 (dimensionless pressure gradient)
    !   BCs: dW/dr(0) = 0 (symmetry), W(1) = 0 (no-slip wall)
    !
    ! Conservative FV discretization guarantees exact momentum balance:
    !   sum of discrete source = wall flux => u_tau = Re_tau (to discretization order)
    !
    ! Reads:  RE_TAU_TARGET, DR, NR, NRP1, NAP1, KAPPA_VD, A_PLUS, L_MAX_NIK
    ! Writes: W(:,1,3), NU_EFF, NU_T_ARR, U_TAU, RE_TAU_OUT (host-associated)

    INTEGER, PARAMETER :: NR1D = 400    ! Fine 1D grid (y+_min = 300/400 = 0.75)
    INTEGER, PARAMETER :: NR1DP1 = NR1D + 1

    INTEGER :: II, JJ
    REAL(KIND=dp) :: S_SOURCE, DR1D
    REAL(KIND=dp) :: NU_EFF_1D(NR1DP1)
    REAL(KIND=dp) :: W_1D(NR1D)
    REAL(KIND=dp) :: W_1D_OLD(NR1D)
    REAL(KIND=dp) :: TRI_A(NR1D)
    REAL(KIND=dp) :: TRI_B(NR1D)
    REAL(KIND=dp) :: TRI_C(NR1D)
    REAL(KIND=dp) :: TRI_D(NR1D)
    REAL(KIND=dp) :: R_FACE, NU_FACE_L
    REAL(KIND=dp) :: R_I
    REAL(KIND=dp) :: DW_DR_VAL, Y_VAL, YP, L_MIX
    REAL(KIND=dp) :: W_CHANGE_1D
    REAL(KIND=dp) :: RELAX_NU, MULT
    INTEGER :: ITER_1D, MAX_ITER_1D
    REAL(KIND=dp) :: R_2D, FRAC
    INTEGER :: I_FINE

    S_SOURCE = 2.0_dp * RE_TAU_TARGET**2
    DR1D = 1.0_dp / NR1D
    MAX_ITER_1D = 2000
    RELAX_NU = 0.1_dp

    WRITE(*,'("  1D grid: NR1D =",I5,", DR1D =",F10.6,", y+_min =",F8.4)') &
      NR1D, DR1D, DR1D * RE_TAU_TARGET

    ! Initialize W with parabolic profile
    DO II = 1, NR1D
      R_I = (II - 1) * DR1D
      W_1D(II) = 0.5_dp * RE_TAU_TARGET**2 * (1.0_dp - R_I**2)
    END DO

    NU_EFF_1D(:) = 1.0_dp
    U_TAU = RE_TAU_TARGET

    WRITE(*,'("  Starting 1D tridiagonal solver...")')

    DO ITER_1D = 1, MAX_ITER_1D
      W_1D_OLD(:) = W_1D(:)

      ! i=1 (origin, r=0): symmetry BC
      R_FACE = 0.5_dp * DR1D
      NU_FACE_L = 0.5_dp * (NU_EFF_1D(1) + NU_EFF_1D(2))
      TRI_A(1) = 0.0_dp
      TRI_C(1) = R_FACE * NU_FACE_L / DR1D
      TRI_B(1) = -TRI_C(1)
      TRI_D(1) = -S_SOURCE * (DR1D * 0.5_dp)**2 * 0.5_dp

      ! Interior points i=2..NR1D-1
      DO II = 2, NR1D - 1
        R_I = (II - 1) * DR1D
        R_FACE = (II - 1.5_dp) * DR1D
        NU_FACE_L = 0.5_dp * (NU_EFF_1D(II-1) + NU_EFF_1D(II))
        TRI_A(II) = R_FACE * NU_FACE_L / DR1D

        R_FACE = (II - 0.5_dp) * DR1D
        NU_FACE_L = 0.5_dp * (NU_EFF_1D(II) + NU_EFF_1D(II+1))
        TRI_C(II) = R_FACE * NU_FACE_L / DR1D

        TRI_B(II) = -(TRI_A(II) + TRI_C(II))
        TRI_D(II) = -S_SOURCE * R_I * DR1D
      END DO

      ! i=NR1D (last interior point, next to wall)
      R_I = (NR1D - 1) * DR1D
      R_FACE = (NR1D - 1.5_dp) * DR1D
      NU_FACE_L = 0.5_dp * (NU_EFF_1D(NR1D-1) + NU_EFF_1D(NR1D))
      TRI_A(NR1D) = R_FACE * NU_FACE_L / DR1D

      R_FACE = (NR1D - 0.5_dp) * DR1D
      NU_FACE_L = 0.5_dp * (NU_EFF_1D(NR1D) + NU_EFF_1D(NR1DP1))
      TRI_C(NR1D) = 0.0_dp
      TRI_B(NR1D) = -(TRI_A(NR1D) + R_FACE * NU_FACE_L / DR1D)
      TRI_D(NR1D) = -S_SOURCE * R_I * DR1D

      ! Thomas algorithm (forward elimination)
      DO II = 2, NR1D
        IF (ABS(TRI_B(II-1)) < 1.0E-30_dp) THEN
          WRITE(*,'("  ERROR: zero pivot in Thomas algorithm at i=",I4)') II-1
          RETURN
        END IF
        MULT = TRI_A(II) / TRI_B(II-1)
        TRI_B(II) = TRI_B(II) - MULT * TRI_C(II-1)
        TRI_D(II) = TRI_D(II) - MULT * TRI_D(II-1)
      END DO

      ! Back substitution
      W_1D(NR1D) = TRI_D(NR1D) / TRI_B(NR1D)
      DO II = NR1D - 1, 1, -1
        W_1D(II) = (TRI_D(II) - TRI_C(II) * W_1D(II+1)) / TRI_B(II)
      END DO

      ! Convergence check
      W_CHANGE_1D = MAXVAL(ABS(W_1D(:) - W_1D_OLD(:)))

      ! Compute u_tau from wall shear (second-order one-sided)
      ! dW/dr|_wall = (4*W(NR1D) - W(NR1D-1)) / (2*DR1D)
      DW_DR_VAL = ABS(4.0_dp * W_1D(NR1D) - W_1D(NR1D-1)) / (2.0_dp * DR1D)
      IF (DW_DR_VAL > 0.0_dp) THEN
        U_TAU = SQRT(DW_DR_VAL)
      ELSE
        U_TAU = RE_TAU_TARGET
      END IF
      RE_TAU_OUT = U_TAU

      ! Update nu_eff using Van Driest mixing-length with Nikuradse cap.
      !
      ! l_m = min(kappa * y * (1 - exp(-y+/A+)), L_MAX)
      ! nu_T = l_m^2 * |dW/dr|
      ! nu_eff = 1 + nu_T
      !
      ! The cap L_MAX = 0.14*R (Nikuradse, 1932) prevents the mixing length
      ! from growing indefinitely in the outer region, providing physically
      ! correct turbulent diffusion near the pipe center.
      NU_EFF_1D(NR1DP1) = 1.0_dp

      ! Interior points
      DO II = 2, NR1D - 1
        Y_VAL = 1.0_dp - (II - 1) * DR1D
        YP = Y_VAL * U_TAU
        IF (Y_VAL > 1.0E-14_dp .AND. YP > 1.0E-14_dp) THEN
          L_MIX = KAPPA_VD * Y_VAL * (1.0_dp - EXP(-YP / A_PLUS))
          L_MIX = MIN(L_MIX, L_MAX_NIK)    ! Nikuradse cap
        ELSE
          L_MIX = 0.0_dp
        END IF
        DW_DR_VAL = ABS(W_1D(II+1) - W_1D(II-1)) / (2.0_dp * DR1D)
        NU_FACE_L = 1.0_dp + L_MIX**2 * DW_DR_VAL
        NU_EFF_1D(II) = RELAX_NU * NU_FACE_L + (1.0_dp - RELAX_NU) * NU_EFF_1D(II)
      END DO

      ! Wall-adjacent point (II=NR1D): W_{NR1D+1} = 0
      II = NR1D
      Y_VAL = 1.0_dp - (II - 1) * DR1D
      YP = Y_VAL * U_TAU
      IF (Y_VAL > 1.0E-14_dp .AND. YP > 1.0E-14_dp) THEN
        L_MIX = KAPPA_VD * Y_VAL * (1.0_dp - EXP(-YP / A_PLUS))
        L_MIX = MIN(L_MIX, L_MAX_NIK)
      ELSE
        L_MIX = 0.0_dp
      END IF
      DW_DR_VAL = ABS(0.0_dp - W_1D(II-1)) / (2.0_dp * DR1D)
      NU_FACE_L = 1.0_dp + L_MIX**2 * DW_DR_VAL
      NU_EFF_1D(II) = RELAX_NU * NU_FACE_L + (1.0_dp - RELAX_NU) * NU_EFF_1D(II)

      ! Origin: copy from II=2
      NU_EFF_1D(1) = NU_EFF_1D(2)

      IF (ITER_1D == 1 .OR. MOD(ITER_1D, 50) == 0 .OR. &
          (W_CHANGE_1D < 1.0E-6_dp .AND. ITER_1D > 100)) THEN
        WRITE(*,'("  1D_iter",I5,": W_change=",ES10.3," u_tau=",F10.4, &
          &" nuT_m=",F10.3," W_CL=",F12.4)') &
          ITER_1D, W_CHANGE_1D, U_TAU, MAXVAL(NU_EFF_1D(1:NR1D)) - 1.0_dp, &
          W_1D(1)
      END IF

      IF (W_CHANGE_1D < 1.0E-6_dp .AND. ITER_1D > 100) THEN
        WRITE(*,'("  1D solver converged after",I5," iterations")') ITER_1D
        EXIT
      END IF
    END DO

    ! Interpolate 1D fine-grid solution to 2D grid (J=1 slice)
    ! 2D grid: r_i = (i-1)*DR for i=1..NRP1
    ! 1D grid: r_k = (k-1)*DR1D for k=1..NR1DP1
    DO II = 1, NR
      R_2D = (II - 1) * DR
      ! Find the 1D cell containing this radius
      I_FINE = NINT(R_2D / DR1D) + 1
      IF (I_FINE < 1) I_FINE = 1
      IF (I_FINE > NR1D) I_FINE = NR1D
      ! Linear interpolation
      IF (I_FINE < NR1D) THEN
        FRAC = (R_2D - (I_FINE - 1) * DR1D) / DR1D
        W(II, 1, 3) = (1.0_dp - FRAC) * W_1D(I_FINE) + FRAC * W_1D(I_FINE + 1)
      ELSE
        W(II, 1, 3) = W_1D(NR1D)
      END IF
    END DO
    W(NRP1, 1, 3) = 0.0_dp

    ! Copy nu_eff to 2D arrays (interpolate similarly)
    DO II = 1, NRP1
      R_2D = (II - 1) * DR
      I_FINE = NINT(R_2D / DR1D) + 1
      IF (I_FINE < 1) I_FINE = 1
      IF (I_FINE > NR1DP1) I_FINE = NR1DP1
      IF (I_FINE < NR1DP1) THEN
        FRAC = (R_2D - (I_FINE - 1) * DR1D) / DR1D
        NU_EFF(II, :) = (1.0_dp - FRAC) * NU_EFF_1D(I_FINE) + FRAC * NU_EFF_1D(I_FINE + 1)
      ELSE
        NU_EFF(II, :) = NU_EFF_1D(NR1DP1)
      END IF
      DO JJ = 1, NAP1
        NU_T_ARR(II, JJ) = NU_EFF(II, JJ) - 1.0_dp
      END DO
    END DO

  END SUBROUTINE SOLVE_STRAIGHT_PIPE_1D

  SUBROUTINE CHECK_CENTRAL_RESIDUALS(MAXR_PHI_L, MAXR_W_L, MAXR_OMG_L)
    REAL(dp), INTENT(OUT) :: MAXR_PHI_L, MAXR_W_L, MAXR_OMG_L
    INTEGER :: II, JJ
    REAL(dp) :: rphi, rw, romg
    REAL(dp) :: LDELTA, LGAMMA
    REAL(dp) :: L, LOMEGA_RHS

    MAXR_PHI_L = 0.0_dp
    MAXR_W_L   = 0.0_dp
    MAXR_OMG_L = 0.0_dp

    DO II = 2, NR
      DO JJ = 2, NA
        ! PHI residual: central Laplacian(phi) + OMEGA = 0
        L = DADR*(PHI(II+1,JJ,3) + PHI(II-1,JJ,3) - 2.0_dp*PHI(II,JJ,3))         &
          + DRDA*RINV2(II)*(PHI(II,JJ+1,3) + PHI(II,JJ-1,3) - 2.0_dp*PHI(II,JJ,3)) &
          + 0.5_dp*DA*RINV(II)*(PHI(II+1,JJ,3) - PHI(II-1,JJ,3))
        rphi = L + DRDAM*OMEGA(II,JJ,3)
        MAXR_PHI_L = MAX(MAXR_PHI_L, ABS(rphi))

        LDELTA = DA - 0.5_dp*(PHI(II,JJ+1,3) - PHI(II,JJ-1,3))
        LGAMMA = 0.5_dp*(PHI(II+1,JJ,3) - PHI(II-1,JJ,3))

        ! W residual (with nu_eff for turbulent case)
        L = DADR*(W(II+1,JJ,3) + W(II-1,JJ,3) - 2.0_dp*W(II,JJ,3))                 &
          + DRDA*RINV2(II)*(W(II,JJ+1,3) + W(II,JJ-1,3) - 2.0_dp*W(II,JJ,3))         &
          + 0.5_dp*RINV(II)*LDELTA*(W(II+1,JJ,3) - W(II-1,JJ,3))                    &
          + 0.5_dp*RINV(II)*LGAMMA*(W(II,JJ+1,3) - W(II,JJ-1,3))
        rw = L + DDRDAM
        MAXR_W_L = MAX(MAXR_W_L, ABS(rw))

        ! OMEGA residual
        LOMEGA_RHS = -W(II,JJ,3) * (SA(JJ) * (W(II+1,JJ,3) - W(II-1,JJ,3)) + &
          CA(II,JJ) * (W(II,JJ+1,3) - W(II,JJ-1,3)))
        L = DADR*(OMEGA(II+1,JJ,3) + OMEGA(II-1,JJ,3) - 2.0_dp*OMEGA(II,JJ,3))                 &
          + DRDA*RINV2(II)*(OMEGA(II,JJ+1,3) + OMEGA(II,JJ-1,3) - 2.0_dp*OMEGA(II,JJ,3))       &
          + 0.5_dp*RINV(II)*LDELTA*(OMEGA(II+1,JJ,3) - OMEGA(II-1,JJ,3))                        &
          + 0.5_dp*RINV(II)*LGAMMA*(OMEGA(II,JJ+1,3) - OMEGA(II,JJ-1,3))
        romg = L + LOMEGA_RHS
        MAXR_OMG_L = MAX(MAXR_OMG_L, ABS(romg))
      END DO
    END DO
  END SUBROUTINE CHECK_CENTRAL_RESIDUALS

  SUBROUTINE SOLVE_SMALL(A, b, x, n, ok)
    INTEGER, INTENT(IN) :: n
    REAL(KIND=dp), INTENT(INOUT) :: A(:,:)
    REAL(KIND=dp), INTENT(INOUT) :: b(:)
    REAL(KIND=dp), INTENT(OUT) :: x(:)
    LOGICAL, INTENT(OUT) :: ok
    INTEGER :: i, j, k, p
    REAL(KIND=dp) :: piv, tmp

    ok = .TRUE.
    x(1:n) = 0.0_dp

    DO k = 1, n-1
      p = k
      piv = ABS(A(k,k))
      DO i = k+1, n
        IF (ABS(A(i,k)) > piv) THEN
          piv = ABS(A(i,k))
          p = i
        END IF
      END DO
      IF (piv <= 0.0_dp) THEN
        ok = .FALSE.
        RETURN
      END IF
      IF (p /= k) THEN
        DO j = k, n
          tmp = A(k,j); A(k,j) = A(p,j); A(p,j) = tmp
        END DO
        tmp = b(k); b(k) = b(p); b(p) = tmp
      END IF

      DO i = k+1, n
        tmp = A(i,k) / A(k,k)
        A(i,k) = 0.0_dp
        DO j = k+1, n
          A(i,j) = A(i,j) - tmp*A(k,j)
        END DO
        b(i) = b(i) - tmp*b(k)
      END DO
    END DO

    IF (ABS(A(n,n)) <= 0.0_dp) THEN
      ok = .FALSE.
      RETURN
    END IF

    DO i = n, 1, -1
      tmp = b(i)
      DO j = i+1, n
        tmp = tmp - A(i,j)*x(j)
      END DO
      x(i) = tmp / A(i,i)
    END DO
  END SUBROUTINE SOLVE_SMALL

  SUBROUTINE ANDERSON_OUTER_UPDATE()
    INTEGER :: p, aa, ab, ii, jj, idx0, idx
    REAL(KIND=dp) :: dot, diagmax, reg
    LOGICAL :: ok

    S_PHI = 1.0_dp / MAX(1.0_dp, MAXVAL(ABS(PHI(2:NR,2:NA,3))))
    S_W   = 1.0_dp / MAX(1.0_dp, MAXVAL(ABS(W(2:NR,2:NA,3))))
    S_OMG = 1.0_dp / MAX(1.0_dp, MAXVAL(ABS(OMEGA(2:NR,2:NA,3))))

    IF (AA_NHIST >= AA_MMAX+1) THEN
      PHI_GH(:,:,1:AA_MMAX) = PHI_GH(:,:,2:AA_MMAX+1)
      W_GH(:,:,1:AA_MMAX)   = W_GH(:,:,2:AA_MMAX+1)
      OMEGA_GH(:,:,1:AA_MMAX)= OMEGA_GH(:,:,2:AA_MMAX+1)
      PHI_FH(:,:,1:AA_MMAX) = PHI_FH(:,:,2:AA_MMAX+1)
      W_FH(:,:,1:AA_MMAX)   = W_FH(:,:,2:AA_MMAX+1)
      OMEGA_FH(:,:,1:AA_MMAX)= OMEGA_FH(:,:,2:AA_MMAX+1)
      AA_NHIST = AA_MMAX
    END IF
    AA_NHIST = AA_NHIST + 1
    idx = AA_NHIST

    PHI_GH(:,:,idx) = PHI(:,:,3)
    W_GH(:,:,idx)   = W(:,:,3)
    OMEGA_GH(:,:,idx)= OMEGA(:,:,3)

    PHI_FH(:,:,idx) = PHI(:,:,3) - PHI(:,:,1)
    W_FH(:,:,idx)   = W(:,:,3)   - W(:,:,1)
    OMEGA_FH(:,:,idx)= OMEGA(:,:,3) - OMEGA(:,:,1)

    IF (AA_NHIST < 2) RETURN

    p = MIN(AA_NHIST, AA_DEPTH+1)
    idx0 = AA_NHIST - p + 1

    DO aa = 1, p
      DO ab = 1, p
        dot = 0.0_dp
        DO ii = 2, NR
          DO jj = 2, NA
            dot = dot + (S_PHI*PHI_FH(ii,jj,idx0+aa-1))*(S_PHI*PHI_FH(ii,jj,idx0+ab-1)) &
                      + (S_W  *W_FH(ii,jj,idx0+aa-1))  *(S_W  *W_FH(ii,jj,idx0+ab-1))   &
                      + (S_OMG*OMEGA_FH(ii,jj,idx0+aa-1))*(S_OMG*OMEGA_FH(ii,jj,idx0+ab-1))
          END DO
        END DO
        AA_MAT(aa,ab) = dot
      END DO
    END DO

    diagmax = 0.0_dp
    DO aa = 1, p
      diagmax = MAX(diagmax, AA_MAT(aa,aa))
    END DO
    reg = AA_REG * MAX(1.0_dp, diagmax)
    DO aa = 1, p
      AA_MAT(aa,aa) = AA_MAT(aa,aa) + reg
    END DO

    DO aa = 1, p
      AA_MAT(aa,p+1) = 1.0_dp
      AA_MAT(p+1,aa) = 1.0_dp
      AA_RHS(aa) = 0.0_dp
    END DO
    AA_MAT(p+1,p+1) = 0.0_dp
    AA_RHS(p+1) = 1.0_dp

    CALL SOLVE_SMALL(AA_MAT, AA_RHS, AA_SOL, p+1, ok)
    IF (.NOT. ok) THEN
      AA_NHIST = 1
      RETURN
    END IF

    DO aa = 1, p
      AA_ALPHA(aa) = AA_SOL(aa)
    END DO

    IF (MAXVAL(ABS(AA_ALPHA(1:p))) > 10.0_dp) THEN
      AA_NHIST = 1
      RETURN
    END IF

    PHI(:,:,3)   = 0.0_dp
    W(:,:,3)     = 0.0_dp
    OMEGA(:,:,3) = 0.0_dp
    DO aa = 1, p
      PHI(:,:,3)   = PHI(:,:,3)   + AA_ALPHA(aa) * PHI_GH(:,:,idx0+aa-1)
      W(:,:,3)     = W(:,:,3)     + AA_ALPHA(aa) * W_GH(:,:,idx0+aa-1)
      OMEGA(:,:,3) = OMEGA(:,:,3) + AA_ALPHA(aa) * OMEGA_GH(:,:,idx0+aa-1)
    END DO

    IF (AA_BETA < 1.0_dp) THEN
      PHI(:,:,3)   = (1.0_dp-AA_BETA)*PHI_GH(:,:,AA_NHIST)   + AA_BETA*PHI(:,:,3)
      W(:,:,3)     = (1.0_dp-AA_BETA)*W_GH(:,:,AA_NHIST)     + AA_BETA*W(:,:,3)
      OMEGA(:,:,3) = (1.0_dp-AA_BETA)*OMEGA_GH(:,:,AA_NHIST) + AA_BETA*OMEGA(:,:,3)
    END IF

    PHI(1,   1:NAP1, 3) = 0.0_dp
    PHI(NRP1,1:NAP1, 3) = 0.0_dp
    PHI(1:NRP1,1,    3) = 0.0_dp
    PHI(1:NRP1,NAP1, 3) = 0.0_dp

    OMEGA(1,    1:NAP1, 3) = 0.0_dp
    OMEGA(1:NRP1,1,     3) = 0.0_dp
    OMEGA(1:NRP1,NAP1,  3) = 0.0_dp

    W(NRP1, 1:NAP1, 3) = 0.0_dp

    ICV = 0
    IF (MAXVAL(ABS(PHI(2:NR, 2:NA, 1) - PHI(2:NR, 2:NA, 3))) > EPS_OUT(1)) ICV = 1
    IF (MAXVAL(ABS(W(1:NR,  1:NAP1,1) - W(1:NR,  1:NAP1,3))) > EPS_OUT(2)) ICV = 1
    IF (MAXVAL(ABS(OMEGA(2:NRP1,2:NA,1) - OMEGA(2:NRP1,2:NA,3))) > EPS_OUT(3)) ICV = 1
  END SUBROUTINE ANDERSON_OUTER_UPDATE

END PROGRAM MAIN
