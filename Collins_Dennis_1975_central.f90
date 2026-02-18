! Collins & Dennis (1975) Deferred Correction Upgrade
!
! Based on: Schubert (1972) FORTRAN Program for Secondary Flow
!
! Implementation of Fox's difference correction method following
! Collins & Dennis (1975) "The steady motion of a viscous fluid
! in a curved tube", Q. Jl Mech. appl. Math., 28(2), 133-156.
!
! The method uses the stable upwind-differenced scheme as the base
! SOR solver (guaranteed diagonal dominance and convergence), with
! Fox's correction terms C_0, E_0 added as frozen source terms to
! achieve central-difference (2nd-order) accuracy.
!
! Key changes from original Schubert code:
! 1. Fox correction C_0 for W equation (C&D eq. 13)
! 2. Fox correction E_0 for Omega equation (C&D eq. 17)
! 3. Correction smoothing for D > 1000 (C&D eq. 21)
! 4. D-stepping strategy for high Dean numbers
! 5. Additional D cases: D=96, D=605.72 (matching C&D paper)

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
    CHARACTER(LEN=5), PARAMETER :: APHI='PHI  ', AW='W    ', AOMEGA='OMEGA'
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
  IMPLICIT NONE
CONTAINS
  SUBROUTINE SOR_PHI(PHI, OMEGA, B, C, RHOC, RHO, EPPS, ISOR_PHI, MAXSOR, NR, &
    NA, NRP1, NAP1, NRM1, ERROR_HANDLER)
    IMPLICIT NONE
    INTEGER, INTENT(IN) :: NR, NA, NRP1, NAP1, NRM1, MAXSOR
    REAL(KIND=dp), INTENT(INOUT) :: PHI(NRP1, NAP1, 4), OMEGA(NRP1, NAP1, 4)
    REAL(KIND=dp), INTENT(IN) :: B(NRP1, 5), RHOC(3), RHO(3), EPPS(3)
    INTEGER, INTENT(OUT) :: ISOR_PHI
    REAL(KIND=dp), INTENT(INOUT) :: C(NRP1, NAP1)
    INTERFACE
      SUBROUTINE ERROR_HANDLER(code, val)
        USE KIND_MOD
        INTEGER, INTENT(IN) :: code
        REAL(KIND=dp), OPTIONAL, INTENT(IN) :: val
      END SUBROUTINE ERROR_HANDLER
    END INTERFACE
    INTEGER :: I, J, ICONV
    ISOR_PHI = 0
    PHI_SOR: DO
      ICONV = 0
      DO I = 2, NR
        DO J = 2, NA
          PHI(I,J,3) = RHOC(1)*PHI(I,J,2) + RHO(1)*( &
              B(I,1)*PHI(I+1,J,2) + B(I,2)*PHI(I,J+1,2) &
              + B(I,3)*PHI(I-1,J,3) + B(I,4)*PHI(I,J-1,3) + C(I,J))
          IF (ABS(PHI(I,J,2) - PHI(I,J,3)) > EPPS(1)) ICONV = 1
        END DO
      END DO
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
        ! Convergence judged on *unrelaxed* update: (old-relaxed) = XIC*(old-raw)
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
    IMPLICIT NONE

    INTEGER, PARAMETER :: NR = 2*10, NA = 2*18
    INTEGER, PARAMETER :: NRP1 = NR + 1, NAP1 = NA + 1
    INTEGER, PARAMETER :: NRM1 = NR - 1
    INTEGER, PARAMETER :: NAH = NA / 2 + 1
    INTEGER, PARAMETER :: NPHI = 4, NB = 5, NE = 6
    INTEGER, PARAMETER :: NCASES = 10

    INTEGER :: clock_start, clock_end, clock_rate
    REAL(KIND=dp) :: elapsed_time

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
    REAL(KIND=dp) :: EE(NRP1), EF(NRP1)
    REAL(KIND=dp) :: EE1, EE2
    REAL(KIND=dp) :: XI(4), XIC(4)
    REAL(KIND=dp) :: RHO(3), RHOC(3)
    REAL(KIND=dp) :: EPS(3), EPPS(3)
    REAL(KIND=dp) :: BO, CON, DDR2, DDRDAM, DRRH
    REAL(KIND=dp) :: DR, DA, DAH, DRH, DRDAM, DRDA, DADR
    REAL(KIND=dp) :: E0, E1, E2, E3, E4
    REAL(KIND=dp) :: GAMMA, DELTA, DELTA1, DELTA2
    REAL(KIND=dp) :: QR, S, PI, D, DSTART
    REAL(KIND=dp) :: DOR(3)
    INTEGER :: I, J, ICONV, ICV, IOUT, IRW, IRO, ctr
    INTEGER :: MAXSOR, MAXOUT, NOR, ISAVE, IUSE, IFIL
    INTEGER :: ISOR_PHI, ISOR_W, ISOR_OMEGA
    CHARACTER(LEN=20) :: file_id
    CHARACTER(LEN=80) :: file_name
    INTEGER :: unit
    LOGICAL :: FAILED

    ! Fox correction arrays (C&D eq. 13, 17)
    ! C0_CORR: correction for W equation
    ! E0_CORR: correction for Omega equation
    REAL(KIND=dp) :: C0_CORR(NRP1, NAP1)
    REAL(KIND=dp) :: E0_CORR(NRP1, NAP1)
    REAL(KIND=dp) :: C0_CORR_NEW(NRP1, NAP1)  ! newly computed C0 corrections
    REAL(KIND=dp) :: E0_CORR_NEW(NRP1, NAP1)  ! newly computed E0 corrections
    REAL(KIND=dp) :: OMEGA1             ! correction smoothing parameter (C&D eq. 21)
    REAL(KIND=dp) :: OMEGA_RHS          ! temporary for Omega source computation
    REAL(KIND=dp) :: CORR_MAX_C0, CORR_MAX_E0  ! max correction change
    REAL(KIND=dp) :: CORR_TOL           ! correction convergence tolerance
    REAL(KIND=dp) :: CORR_OLD           ! temp for tracking change
    INTEGER :: CORR_ITER, MAX_CORR      ! correction iteration counter and limit
    LOGICAL :: CORR_CONVERGED           ! correction convergence flag

    ! Fox correction carry-over between D cases
    REAL(KIND=dp) :: C0_SAVE(NRP1, NAP1), E0_SAVE(NRP1, NAP1)

    ! D-stepping variables
    REAL(KIND=dp) :: D_TARGET, D_CURRENT, D_STEP
    LOGICAL :: STEPPING
    INTEGER :: STEP_ITERS, step_count

    ! Case configuration arrays
    REAL(KIND=dp) :: D_CASES(NCASES)
    REAL(KIND=dp) :: EPS_CASES(3, NCASES)
    REAL(KIND=dp) :: RHO_CASES(3, NCASES)
    REAL(KIND=dp) :: XI_CASES(4, NCASES)
    REAL(KIND=dp) :: OMEGA1_CASES(NCASES)  ! correction smoothing per case

    ! Results tracking
    REAL(KIND=dp) :: phi_max, w_max
    REAL(KIND=dp) :: phi_max_prev, w_max_prev  ! for correction convergence check
    REAL(KIND=dp) :: MAXR_PHI, MAXR_W, MAXR_OMG  ! central-discretization residuals
    REAL(KIND=dp) :: RES_WALL                      ! wall BC residual diagnostic

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

    PI = 3.14159255_dp
    MAXSOR = 2500
    MAXOUT = 5000
    NOR = 3
    DOR = (/0.2_dp, 0.2_dp, 0.2_dp/)
    STEP_ITERS = 10
    MAX_CORR = 30
    CORR_TOL = 5.0E-4_dp   ! Correction convergence tolerance

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

    ! Central differencing of (1/r)*dPHI/dr gives +/- (DA/(2r)) contributions.
    DO I = 2, NR
      BO = 2.0_dp * (DADR + DRDA * RINV2(I))
      B(I, 1) = (DADR + 0.5_dp * DA * RINV(I)) / BO
      B(I, 2) = (DRDA * RINV2(I)) / BO
      B(I, 3) = (DADR - 0.5_dp * DA * RINV(I)) / BO
      B(I, 4) = B(I, 2)
      B(I, 5) = DRDAM / BO
    END DO

!------------------- Case configuration ---------------------------------

    D_CASES = (/10._dp, 96._dp, 100._dp, 250._dp, 500._dp, &
                605.72_dp, 1000._dp, 2000._dp, 3500._dp, 5000._dp/)

    EPS_CASES(:,1)  = (/1.0E-5_dp, 1.0E-3_dp, 1.0E-4_dp/)    ! D=10
    EPS_CASES(:,2)  = (/1.5E-4_dp, 4.0E-3_dp, 4.0E-3_dp/)    ! D=96
    EPS_CASES(:,3)  = (/2.0E-4_dp, 5.0E-3_dp, 5.0E-3_dp/)    ! D=100
    EPS_CASES(:,4)  = (/2.0E-3_dp, 2.0E-2_dp, 4.0E-2_dp/)    ! D=250
    EPS_CASES(:,5)  = (/4.0E-3_dp, 4.0E-2_dp, 8.0E-2_dp/)    ! D=500
    EPS_CASES(:,6)  = (/4.5E-3_dp, 4.5E-2_dp, 9.0E-2_dp/)    ! D=605.72
    EPS_CASES(:,7)  = (/5.0E-3_dp, 5.0E-2_dp, 17.0E-2_dp/)   ! D=1000
    EPS_CASES(:,8)  = (/7.0E-3_dp, 8.0E-2_dp, 3.0E-1_dp/)    ! D=2000
    EPS_CASES(:,9)  = (/8.0E-3_dp, 10.0E-2_dp, 4.0E-1_dp/)   ! D=3500
    EPS_CASES(:,10) = (/1.0E-2_dp, 15.0E-2_dp, 6.0E-1_dp/)   ! D=5000

    RHO_CASES(:,1)  = (/1.5_dp, 1.8_dp, 1.5_dp/)
    RHO_CASES(:,2)  = (/1.5_dp, 1.7_dp, 1.5_dp/)
    RHO_CASES(:,3)  = (/1.5_dp, 1.7_dp, 1.5_dp/)
    RHO_CASES(:,4)  = (/1.5_dp, 1.5_dp, 1.5_dp/)
    RHO_CASES(:,5)  = (/1.5_dp, 1.5_dp, 1.5_dp/)
    RHO_CASES(:,6)  = (/1.5_dp, 1.5_dp, 1.5_dp/)
    RHO_CASES(:,7)  = (/1.5_dp, 1.5_dp, 1.5_dp/)
    RHO_CASES(:,8)  = (/0.8_dp*1.5_dp, 0.8_dp*1.5_dp, 0.8_dp*1.3_dp/)
    RHO_CASES(:,9)  = (/0.8_dp*1.5_dp, 0.8_dp*1.5_dp, 0.8_dp*1.3_dp/)
    RHO_CASES(:,10) = (/0.8_dp*1.5_dp, 0.8_dp*1.5_dp, 0.8_dp*1.3_dp/)

    XI_CASES(:,1)  = (/0.1_dp, 0.1_dp, 0.9_dp, 0.1_dp/)
    XI_CASES(:,2)  = (/0.1_dp, 0.1_dp, 0.9_dp, 0.1_dp/)
    XI_CASES(:,3)  = (/0.1_dp, 0.1_dp, 0.9_dp, 0.1_dp/)
    XI_CASES(:,4)  = (/0.5_dp, 0.1_dp, 0.5_dp, 0.5_dp/)
    XI_CASES(:,5)  = (/0.5_dp, 0.1_dp, 0.5_dp, 0.5_dp/)
    XI_CASES(:,6)  = (/0.5_dp, 0.1_dp, 0.5_dp, 0.5_dp/)
    XI_CASES(:,7)  = (/0.5_dp, 0.1_dp, 0.5_dp, 0.5_dp/)
    XI_CASES(:,8)  = (/0.85_dp, 0.50_dp, 0.90_dp, 0.85_dp/)   ! D=2000
    XI_CASES(:,9)  = (/0.90_dp, 0.60_dp, 0.93_dp, 0.90_dp/)   ! D=3500
    XI_CASES(:,10) = (/0.93_dp, 0.65_dp, 0.95_dp, 0.93_dp/)   ! D=5000

    ! Fox correction smoothing parameter omega1 (C&D eq. 21)
    ! omega1 = 1.0 means full update (no smoothing)
    ! Lower values needed at high D for stability
    OMEGA1_CASES(1)  = 1.0_dp    ! D=10
    OMEGA1_CASES(2)  = 1.0_dp    ! D=96
    OMEGA1_CASES(3)  = 1.0_dp    ! D=100
    OMEGA1_CASES(4)  = 1.0_dp    ! D=250
    OMEGA1_CASES(5)  = 1.0_dp    ! D=500
    OMEGA1_CASES(6)  = 1.0_dp    ! D=605.72
    OMEGA1_CASES(7)  = 1.0_dp    ! D=1000
    OMEGA1_CASES(8)  = 0.1_dp    ! D=2000
    OMEGA1_CASES(9)  = 0.05_dp   ! D=3500
    OMEGA1_CASES(10) = 0.01_dp   ! D=5000

!------------------- Main case loop over D values -----------------------

    ISAVE = 1
    IUSE = 1
    IFIL = 1
    DSTART = 0._dp

    DO ctr = 1, NCASES

      D_TARGET = D_CASES(ctr)
      D = D_TARGET
      EPS = EPS_CASES(:, ctr)
      RHO = RHO_CASES(:, ctr)
      XI = XI_CASES(:, ctr)
      OMEGA1 = OMEGA1_CASES(ctr)

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

      STEPPING = .FALSE.
      IF (D_TARGET > 200._dp .AND. DSTART > 0._dp .AND. D_TARGET > DSTART) THEN
        D_CURRENT = DSTART
        STEPPING = .TRUE.
        WRITE(*,'("  D-stepping from D =",F9.2," to D =",F9.2)') DSTART, D_TARGET
      ELSE
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

      ! Carry Fox corrections from previous D case as initial guess
      C0_CORR(:,:) = C0_SAVE(:,:)
      E0_CORR(:,:) = E0_SAVE(:,:)

!------------------- Initial guess for outer iterates -------------------

      IF (IUSE .NE. 0) THEN
        PHI(:,:,3) = PHI(:,:,4)
        W(:,:,3) = W(:,:,4)
        OMEGA(:,:,3) = OMEGA(:,:,4)
        IF (ctr > 1) THEN
          WRITE(*,'("  Initial guess from D =",F9.2)') DSTART
        ELSE
          WRITE(*,'("  Initial guess: zero")')
        END IF
      ELSE
        PHI(:,:,3) = 0.0_dp
        W(:,:,3) = 0.0_dp
        OMEGA(:,:,3) = 0.0_dp
      END IF

!------------------- Two-level iteration (C&D Section 4) ---------------
! Outer level: correction loop (updates C_0, E_0)
! Inner level: convergence loop (fixed C_0, E_0)

      CORR_ITER = 0
      CORR_CONVERGED = .FALSE.
      FAILED = .FALSE.
      phi_max_prev = 0.0_dp
      w_max_prev = 0.0_dp

      CORRECTION_LOOP: DO

      ! Reset SOR parameters (may have been reduced during failed attempts)
      RHO = RHO_CASES(:, ctr)
      DO I = 1, 3
        RHOC(I) = 1._dp - RHO(I)
      END DO

      IOUT = 0
      IRW = 0
      IRO = 0
      step_count = 0

      OUTER_ITER: DO
        IF (IOUT .GE. MAXOUT) THEN
          CALL ERROR_HANDLER(58)
          FAILED = .TRUE.
          EXIT OUTER_ITER
        END IF

        IOUT = IOUT + 1
        IF (.NOT. STEPPING .AND. (IOUT <= 3 .OR. MOD(IOUT,100) == 0)) THEN
          WRITE(*,'(//"OUTER ITERATION",I5//)') IOUT
        END IF

        ICV = 0

        PHI(:,:,1) = PHI(:,:,3)
        W(:,:,1) = W(:,:,3)
        OMEGA(:,:,1) = OMEGA(:,:,3)

        ! Enforce PHI boundary values (Dirichlet zero on all boundaries)
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
            C(I,J) = B(I,5) * OMEGA(I,J,1)
          END DO
        END DO

!------------------- SOR for PHI ----------------------------------------

        CALL SOR_PHI(PHI, OMEGA, B, C, RHOC, RHO, EPPS, ISOR_PHI, MAXSOR, NR, &
          NA, NRP1, NAP1, NRM1, ERROR_HANDLER)
        CALL SMOOTH(NRP1, NAP1, PHI, XI(1), XIC(1), EPS(1), ICV)
        IF (.NOT. STEPPING .AND. IOUT <= 3) THEN
          CALL OUTPUT('PHI  ', ISOR_PHI, PHI(1,1,3), NR, NA)
        END IF

!------------------- W coefficient setup (UPWIND base) ------------------
! Uses original Schubert upwind stencil for diagonal dominance.
! Fox's correction C_0 is added as a source term.

        ! W at origin (r=0) - original upwind treatment
        E0 = 4._dp + ABS(PHI(2,NAH,3))
        E1 = (1._dp - MIN(PHI(2,NAH,3),0._dp)) / E0
        E2 = 2._dp / E0
        E3 = (1._dp + MAX(PHI(2,NAH,3),0._dp)) / E0
        E4 = DDR2 / E0

        ! W coefficients along alpha=0 and alpha=pi - UPWIND
        DO I = 2, NR
          DELTA1 = DA - PHI(I,2,3)
          DELTA2 = DA + PHI(I,NA,3)
          EE(I) = 2._dp * (DADR + DRDA * RINV2(I))
          EE1 = EE(I) + RINV(I) * ABS(DELTA1)
          EE2 = EE(I) + RINV(I) * ABS(DELTA2)
          EF(I) = DRDA * RINV2(I)

          ! alpha=0 boundary: upwind + fixed Fox correction
          E(I,1,1) = (DADR + RINV(I) * MAX(DELTA1,0._dp)) / EE1
          E(I,1,2) = EF(I) / EE1
          E(I,1,3) = (DADR - RINV(I) * MIN(DELTA1,0._dp)) / EE1
          E(I,1,4) = E(I,1,2)
          E(I,1,5) = (DDRDAM + C0_CORR(I,1)) / EE1

          ! alpha=pi boundary: upwind + fixed Fox correction
          E(I,NAP1,1) = (DADR + RINV(I) * MAX(DELTA2,0._dp)) / EE2
          E(I,NAP1,2) = EF(I) / EE2
          E(I,NAP1,3) = (DADR - RINV(I) * MIN(DELTA2,0._dp)) / EE2
          E(I,NAP1,4) = E(I,NAP1,2)
          E(I,NAP1,5) = (DDRDAM + C0_CORR(I,NAP1)) / EE2
        END DO

        ! Interior W coefficients: UPWIND stencil + Fox correction C_0
        DO I = 2, NR
          DO J = 2, NA
            GAMMA = .5_dp * (PHI(I+1,J,3) - PHI(I-1,J,3))
            DELTA = DA - .5_dp * (PHI(I,J+1,3) - PHI(I,J-1,3))

            ! UPWIND stencil (same as original Schubert code)
            E(I,J,6) = EE(I) + RINV(I) * (ABS(GAMMA) + ABS(DELTA))
            E(I,J,1) = (DADR + RINV(I) * MAX(DELTA,0._dp)) / E(I,J,6)
            E(I,J,2) = (EF(I) + RINV(I) * MAX(GAMMA,0._dp)) / E(I,J,6)
            E(I,J,3) = (DADR - RINV(I) * MIN(DELTA,0._dp)) / E(I,J,6)
            E(I,J,4) = (EF(I) - RINV(I) * MIN(GAMMA,0._dp)) / E(I,J,6)

            ! Source term with fixed Fox correction C_0 (updated between correction iterations)
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

        ! Smoothing for W at origin
        W(1,1,3) = XI(2) * W(1,1,1) + XIC(2) * W(1,1,3)
        DO J = 2, NAP1
          W(1,J,3) = W(1,1,3)
        END DO
        IF (ABS(W(1,1,1) - W(1,1,3)) .GT. XIC(2)*EPS(2)) ICV = 1

        CALL SMOOTH(NRP1, NAP1, W, XI(2), XIC(2), EPS(2), ICV)
        IF (.NOT. STEPPING .AND. IOUT <= 3) THEN
          CALL OUTPUT('W    ', ISOR_W, W(1,1,3), NR, NA)
        END IF

!------------------- SOR for OMEGA --------------------------------------

        ! Wall boundary condition (C&D eq. 19)
        DO J = 2, NA
          OMEGA(NRP1,J,3) = XI(3) * OMEGA(NRP1,J,1) - XIC(3) * 2._dp * RINV2 &
            (2) * PHI(NR,J,3)
          IF (ABS(OMEGA(NRP1,J,1) - OMEGA(NRP1,J,3)) .GT. XIC(3)*EPS(3)) ICV = 1
        END DO

        ! Wall BC residual: how well does Omega_wall satisfy the Woods/Thom formula?
        RES_WALL = 0.0_dp
        DO J = 2, NA
          RES_WALL = MAX(RES_WALL, ABS(OMEGA(NRP1,J,3) + 2._dp*RINV2(2)*PHI(NR,J,3)))
        END DO

        ! Compute OMEGA source term: w*(sin*dw/dr + cos/r*dw/dalpha) + fixed E_0
        ! E(I,J,6) is overwritten with normalized Omega source
        DO I = 2, NR
          DO J = 2, NA
            ! Original vorticity source from W field
            OMEGA_RHS = -W(I,J,3) * (SA(J) * (W(I+1,J,3) - W(I-1,J,3)) + &
              CA(I,J) * (W(I,J+1,3) - W(I,J-1,3)))

            ! Combined source: vorticity + fixed Fox correction E_0
            E(I,J,6) = (OMEGA_RHS + E0_CORR(I,J)) / E(I,J,6)
          END DO
        END DO

        ! Propagate all boundary values to SOR "old" array (slice 2)
        OMEGA(NRP1, 1:NAP1, 2) = OMEGA(NRP1, 1:NAP1, 3)   ! wall (r=1)
        OMEGA(1,    1:NAP1, 2) = OMEGA(1,    1:NAP1, 3)   ! r=0
        OMEGA(1:NRP1, 1,    2) = OMEGA(1:NRP1, 1,    3)   ! alpha=0
        OMEGA(1:NRP1, NAP1, 2) = OMEGA(1:NRP1, NAP1, 3)   ! alpha=pi

        ! SOR for OMEGA with retry
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
        IF (.NOT. STEPPING .AND. IOUT <= 3) THEN
          CALL OUTPUT('OMEGA', ISOR_OMEGA, OMEGA(1,1,3), NR, NA)
        END IF
        IF (.NOT. STEPPING .AND. (IOUT <= 3 .OR. MOD(IOUT,100) == 0)) THEN
          ! Diagnostic: field maxima and wall BC after each outer iteration
          WRITE(*,'("  DIAG: maxPHI=",ES10.3," maxW=",ES10.3,' // &
            '" maxOMG=",ES10.3," maxOMG_wall=",ES10.3," RES_WALL=",ES10.3)') &
            MAXVAL(ABS(PHI(2:NR,2:NA,3))), MAXVAL(ABS(W(2:NR,2:NA,3))), &
            MAXVAL(ABS(OMEGA(2:NR,2:NA,3))), MAXVAL(ABS(OMEGA(NRP1,2:NA,3))), &
            RES_WALL
        END IF

!------------------- D-stepping check -----------------------------------

        IF (STEPPING) THEN
          step_count = step_count + 1
          IF (MOD(step_count, STEP_ITERS) == 0) THEN
            D_STEP = 10._dp
            D_CURRENT = MIN(D_CURRENT + D_STEP, D_TARGET)
            D = D_CURRENT
            DDRDAM = D * DRDAM
            DDR2 = D * DR ** 2
            IF (D_CURRENT >= D_TARGET) THEN
              STEPPING = .FALSE.
              IOUT = 0
              WRITE(*,'("  D-stepping complete, now converging at D =",F9.2)') D
            ELSE IF (MOD(step_count, STEP_ITERS * 10) == 0) THEN
              WRITE(*,'("  D-stepping: D =",F9.2)') D_CURRENT
            END IF
          END IF
          ICV = 1
          CYCLE OUTER_ITER
        END IF

!------------------- Check for convergence ------------------------------

        IF (ICV == 0) EXIT OUTER_ITER
      END DO OUTER_ITER

      IF (.NOT. FAILED) THEN
        WRITE(*,'("OUTER ITERATION CONVERGED TO GIVEN TOLERANCES.")')
      END IF

!------------------- Correction computation (C&D Section 4) ------------
! After inner convergence, compute new Fox corrections from converged
! solution and check if another correction iteration is needed.

      IF (FAILED .OR. CORR_CONVERGED .OR. CORR_ITER >= MAX_CORR) THEN
        EXIT CORRECTION_LOOP
      END IF

      ! Compute new C_0 corrections from converged W field (C&D eq. 13)
      C0_CORR_NEW(:,:) = 0.0_dp
      E0_CORR_NEW(:,:) = 0.0_dp

      DO I = 2, NR
        ! alpha=0 boundary (GAMMA=0 by symmetry)
        DELTA1 = DA - PHI(I,2,3)
        C0_CORR_NEW(I,1) = -0.5_dp * RINV(I) * ABS(DELTA1) * &
          (W(I+1,1,3) + W(I-1,1,3) - 2._dp * W(I,1,3))

        ! Interior points
        DO J = 2, NA
          GAMMA = .5_dp * (PHI(I+1,J,3) - PHI(I-1,J,3))
          DELTA = DA - .5_dp * (PHI(I,J+1,3) - PHI(I,J-1,3))

          ! C_0 for W equation
          C0_CORR_NEW(I,J) = -0.5_dp * RINV(I) * ( &
            ABS(DELTA) * (W(I+1,J,3) + W(I-1,J,3) - 2._dp*W(I,J,3)) + &
            ABS(GAMMA) * (W(I,J+1,3) + W(I,J-1,3) - 2._dp*W(I,J,3)))

          ! E_0 for Omega equation (same form, using Omega field)
          E0_CORR_NEW(I,J) = -0.5_dp * RINV(I) * ( &
            ABS(DELTA) * (OMEGA(I+1,J,3) + OMEGA(I-1,J,3) - 2._dp*OMEGA(I,J,3)) + &
            ABS(GAMMA) * (OMEGA(I,J+1,3) + OMEGA(I,J-1,3) - 2._dp*OMEGA(I,J,3)))
        END DO

        ! alpha=pi boundary (GAMMA=0 by symmetry)
        DELTA2 = DA + PHI(I,NA,3)
        C0_CORR_NEW(I,NAP1) = -0.5_dp * RINV(I) * ABS(DELTA2) * &
          (W(I+1,NAP1,3) + W(I-1,NAP1,3) - 2._dp * W(I,NAP1,3))
      END DO

      ! Apply smoothing (C&D eq. 21) and track max change
      CORR_MAX_C0 = 0.0_dp
      CORR_MAX_E0 = 0.0_dp

      DO I = 2, NR
        DO J = 1, NAP1
          CORR_OLD = C0_CORR(I,J)
          C0_CORR(I,J) = OMEGA1 * C0_CORR_NEW(I,J) + (1._dp - OMEGA1) * C0_CORR(I,J)
          CORR_MAX_C0 = MAX(CORR_MAX_C0, ABS(C0_CORR(I,J) - CORR_OLD))
        END DO
        DO J = 2, NA
          CORR_OLD = E0_CORR(I,J)
          E0_CORR(I,J) = OMEGA1 * E0_CORR_NEW(I,J) + (1._dp - OMEGA1) * E0_CORR(I,J)
          CORR_MAX_E0 = MAX(CORR_MAX_E0, ABS(E0_CORR(I,J) - CORR_OLD))
        END DO
      END DO

      CORR_ITER = CORR_ITER + 1
      WRITE(*,'("  Correction iter",I3,": max dC0=",ES10.3,", max dE0=",ES10.3)') &
        CORR_ITER, CORR_MAX_C0, CORR_MAX_E0

      ! Report intermediate results
      phi_max = 0._dp
      w_max = 0._dp
      DO I = 1, NRP1
        DO J = 1, NAP1
          IF (ABS(PHI(I,J,3)) > phi_max) phi_max = ABS(PHI(I,J,3))
          IF (ABS(W(I,J,3)) > w_max) w_max = ABS(W(I,J,3))
        END DO
      END DO
      WRITE(*,'("    phi_M =",F10.4,"  w_M =",F10.2)') phi_max, w_max

      ! Check central-discretization residuals
      CALL CHECK_CENTRAL_RESIDUALS(MAXR_PHI, MAXR_W, MAXR_OMG)
      WRITE(*,'("    Central residuals: PHI=",ES10.3,"  W=",ES10.3,"  OMG=",ES10.3)') &
        MAXR_PHI, MAXR_W, MAXR_OMG

      ! Check correction convergence: corrections small enough
      IF (CORR_MAX_C0 < CORR_TOL .AND. CORR_MAX_E0 < CORR_TOL) THEN
        WRITE(*,'("  Corrections converged after",I3," iterations.")') CORR_ITER
        CORR_CONVERGED = .TRUE.
        CYCLE CORRECTION_LOOP
      END IF
      phi_max_prev = phi_max
      w_max_prev = w_max

      ! D-stepping should not re-activate on subsequent passes
      STEPPING = .FALSE.

      END DO CORRECTION_LOOP

!------------------- Compute and report results -------------------------

      D = D_TARGET
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

!------------------- Output solution to file ----------------------------

      IF (IFIL .NE. 0) THEN
        WRITE(file_id, '(F0.2)') D_TARGET
        file_name = 'cd_file_D' // TRIM(ADJUSTL(file_id)) // '.dat'
        PRINT *, "*file name is ", TRIM(file_name)
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
      END IF

      IF (IFIL .NE. 0) WRITE(*,'("SOLUTION WAS OUTPUT TO FILE.")')

!------------------- Save solution for next case ------------------------

      PHI(:,:,4) = PHI(:,:,3)
      W(:,:,4) = W(:,:,3)
      OMEGA(:,:,4) = OMEGA(:,:,3)
      C0_SAVE(:,:) = C0_CORR(:,:)
      E0_SAVE(:,:) = E0_CORR(:,:)
      DSTART = D_TARGET

      PRINT *, 'Done with case D =', D_TARGET
    END DO

!------------------- Timing and program end -----------------------------

    CALL SYSTEM_CLOCK(COUNT=clock_end)
    elapsed_time = REAL(clock_end - clock_start, KIND=dp) / REAL(clock_rate, &
      KIND=dp)
    PRINT *, '[SYSTEM_CLOCK] Elapsed CPU time (seconds):', elapsed_time

CONTAINS

  SUBROUTINE CHECK_CENTRAL_RESIDUALS(MAXR_PHI, MAXR_W, MAXR_OMG)
    REAL(dp), INTENT(OUT) :: MAXR_PHI, MAXR_W, MAXR_OMG
    INTEGER :: II, JJ
    REAL(dp) :: rphi, rw, romg
    REAL(dp) :: LDELTA, LGAMMA
    REAL(dp) :: L, LOMEGA_RHS

    MAXR_PHI = 0.0_dp
    MAXR_W   = 0.0_dp
    MAXR_OMG = 0.0_dp

    DO II = 2, NR
      DO JJ = 2, NA
        ! ---- PHI residual: central Laplacian(phi) + OMEGA = 0
        L = DADR*(PHI(II+1,JJ,3) + PHI(II-1,JJ,3) - 2.0_dp*PHI(II,JJ,3))         &
          + DRDA*RINV2(II)*(PHI(II,JJ+1,3) + PHI(II,JJ-1,3) - 2.0_dp*PHI(II,JJ,3)) &
          + 0.5_dp*DA*RINV(II)*(PHI(II+1,JJ,3) - PHI(II-1,JJ,3))
        rphi = L + DRDAM*OMEGA(II,JJ,3)
        MAXR_PHI = MAX(MAXR_PHI, ABS(rphi))

        ! ---- DELTA/GAMMA for W and OMEGA residuals
        LDELTA = DA - 0.5_dp*(PHI(II,JJ+1,3) - PHI(II,JJ-1,3))
        LGAMMA = 0.5_dp*(PHI(II+1,JJ,3) - PHI(II-1,JJ,3))

        ! ---- W residual: central operator + DDRDAM = 0
        L = DADR*(W(II+1,JJ,3) + W(II-1,JJ,3) - 2.0_dp*W(II,JJ,3))                 &
          + DRDA*RINV2(II)*(W(II,JJ+1,3) + W(II,JJ-1,3) - 2.0_dp*W(II,JJ,3))         &
          + 0.5_dp*RINV(II)*LDELTA*(W(II+1,JJ,3) - W(II-1,JJ,3))                    &
          + 0.5_dp*RINV(II)*LGAMMA*(W(II,JJ+1,3) - W(II,JJ-1,3))
        rw = L + DDRDAM
        MAXR_W = MAX(MAXR_W, ABS(rw))

        ! ---- OMEGA residual: central operator + RHS = 0
        LOMEGA_RHS = -W(II,JJ,3) * (SA(JJ) * (W(II+1,JJ,3) - W(II-1,JJ,3)) + &
          CA(II,JJ) * (W(II,JJ+1,3) - W(II,JJ-1,3)))
        L = DADR*(OMEGA(II+1,JJ,3) + OMEGA(II-1,JJ,3) - 2.0_dp*OMEGA(II,JJ,3))                 &
          + DRDA*RINV2(II)*(OMEGA(II,JJ+1,3) + OMEGA(II,JJ-1,3) - 2.0_dp*OMEGA(II,JJ,3))       &
          + 0.5_dp*RINV(II)*LDELTA*(OMEGA(II+1,JJ,3) - OMEGA(II-1,JJ,3))                        &
          + 0.5_dp*RINV(II)*LGAMMA*(OMEGA(II,JJ+1,3) - OMEGA(II,JJ-1,3))
        romg = L + LOMEGA_RHS
        MAXR_OMG = MAX(MAXR_OMG, ABS(romg))
      END DO
    END DO
  END SUBROUTINE CHECK_CENTRAL_RESIDUALS

END PROGRAM MAIN
