! Appendix: FORTRAN Program for Secondary Flow, by A. B. Schubert (1972)
!
! Nils T. Basse (2025):
!     Complete modern Fortran version created with the assistance of GitHub
!     Copilot (ChatGPT-4.1).
!
! Modified (2026): second-order accurate version using Fox's deferred
!     correction as in Collins & Dennis (1975), Q. J. Mech. Appl. Math.
!     28(2), 133. Changes: central differences in the PHI equation, PHI
!     equation also solved at r = 1-h, wall vorticity actually coupled into
!     the OMEGA sweep, NaN-safe SOR convergence tests, deferred-correction
!     outer loop, continuation in D. Prints RESULT lines.

MODULE KIND_MOD
  !------------------------------------------------------------------------
  !> Defines the kind parameter for double precision real numbers (dp).
  !! This ensures consistent numerical precision throughout the program.
  !! dp = SELECTED_REAL_KIND(15, 307) corresponds to at least 15 decimal
  !! digits of precision and an exponent range of at least 10^+-307.
  !------------------------------------------------------------------------
  IMPLICIT NONE
  INTEGER, PARAMETER :: dp = SELECTED_REAL_KIND(15, 307)
END MODULE KIND_MOD

MODULE ERROR_MOD
  USE KIND_MOD
  IMPLICIT NONE
CONTAINS
  !------------------------------------------------------------------------
  !> Handles error codes and prints appropriate error messages.
  !! code : Error code (integer)
  !! val  : Optional value, used for some error messages (real)
  !------------------------------------------------------------------------
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
  !------------------------------------------------------------------------
  !> Outputs the solution array for a given variable (PHI, W, or OMEGA).
  !! VAR  : Name of variable to output ('PHI  ', 'W    ', 'OMEGA')
  !! ISOR : Number of SOR iterations performed
  !! A    : Solution array to output
  !! x, y : Grid dimensions
  !------------------------------------------------------------------------
  SUBROUTINE OUTPUT(VAR, ISOR, A, x, y)
    CHARACTER(LEN=5), INTENT(IN) :: VAR
    INTEGER, INTENT(IN) :: x, y, ISOR
    REAL(KIND=dp), INTENT(IN) :: A(x+1, y+1)

    CHARACTER(LEN=5), PARAMETER :: APHI='PHI  ', AW='W    ', AOMEGA='OMEGA'
    INTEGER :: I, J, NRP1, NAP1

    NRP1 = x + 1
    NAP1 = y + 1

    WRITE(*,'(A6,5X,I5,2X,"SOR ITERATIONS"/)') VAR, ISOR

    ! Output array in reverse order for both indices for better
    !   visualization
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
  ! Wall treatment for PHI at r = 1 - h:
  !   0: PHI(NR) = PHI(NR-1)/4 (Schubert)
  !   1: Poisson equation also at r = 1 - h, with PHI = 0 at the wall
  INTEGER :: PHIWALL = 0
CONTAINS
  !------------------------------------------------------------------------
  !> Performs SOR iteration for PHI variable.
  !  Updates PHI using SOR until convergence or maximum iterations.
  !------------------------------------------------------------------------
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
      ! ICONV is a local SOR convergence flag: set to 1 if any update
      !   exceeds tolerance.
      ! Update PHI at interior points (2 <= r <= NR-1, 2 <= alpha <= NA)
      DO I = 2, NRM1
        DO J = 2, NA
          PHI(I,J,3) = RHOC(1)*PHI(I,J,2) + RHO(1)*( &
              B(I,1)*PHI(I+1,J,2) + B(I,2)*PHI(I,J+1,2) &
              + B(I,3)*PHI(I-1,J,3) + B(I,4)*PHI(I,J-1,3) + C(I,J))
          IF (.NOT. (ABS(PHI(I,J,2) - PHI(I,J,3)) <= EPPS(1))) ICONV = 1
        END DO
      END DO
      ! Update PHI at the outer boundary (r = NR)
      DO J = 2, NA
        IF (PHIWALL == 0) THEN
          PHI(NR,J,3) = RHOC(1)*PHI(NR,J,2) + RHO(1)*0.25_dp*PHI(NRM1,J,3)
        ELSE
          PHI(NR,J,3) = RHOC(1)*PHI(NR,J,2) + RHO(1)*( &
              B(NR,2)*PHI(NR,J+1,2) + B(NR,3)*PHI(NRM1,J,3) &
              + B(NR,4)*PHI(NR,J-1,3) + C(NR,J))
        END IF
        IF (.NOT. (ABS(PHI(NR,J,2) - PHI(NR,J,3)) <= EPPS(1))) ICONV = 1
      END DO
      ! Check for convergence: if no updates exceed tolerance, exit SOR loop
      IF (ICONV == 0) EXIT PHI_SOR
      ISOR_PHI = ISOR_PHI + 1
      IF (ISOR_PHI >= MAXSOR) THEN
        ! PHI iteration failed: skip to next case
        CALL ERROR_HANDLER(55)
        EXIT PHI_SOR
      END IF
      ! Prepare for next SOR iteration by copying new values to previous
      !   iterate
      PHI(2:NR,2:NA,2) = PHI(2:NR,2:NA,3)
    END DO PHI_SOR
  END SUBROUTINE SOR_PHI

  !------------------------------------------------------------------------
  !> Performs SOR iteration for W variable, with possible reduction of
  !  over-relaxation factor if convergence fails.
  !------------------------------------------------------------------------
  SUBROUTINE SOR_W(W, E, EPPS2, RHOC2, RHO2, ISOR_W, MAXSOR, NR, NA, NRP1, &
    NAP1, NAH, E1, E2, E3, E4, DOR, NOR, IRW, ICONV, ERROR_HANDLER)
    IMPLICIT NONE
    INTEGER, INTENT(IN) :: NR, NA, NRP1, NAP1, NAH, MAXSOR, NOR
    REAL(KIND=dp), INTENT(INOUT) :: W(NRP1, NAP1, 4)
    REAL(KIND=dp), INTENT(IN) :: E(NRP1, NAP1, 6)
    REAL(KIND=dp), INTENT(IN) :: EPPS2
    REAL(KIND=dp), INTENT(INOUT) :: RHOC2
    REAL(KIND=dp), INTENT(INOUT) :: RHO2
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
      ! If maximum SOR iterations reached, reduce RHO2 and retry if allowed
      IF (ISOR_W .GE. MAXSOR) THEN
        ! W iteration failed: reduce over-relaxation factor and try again
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

      ! Update previous SOR iterates for W
      W(1, 1, 2) = W(1, 1, 3)
      DO I = 2, NR
        DO J = 1, NAP1
          W(I, J, 2) = W(I, J, 3)
        END DO
      END DO

      ICONV = 0

      ! ICONV is a local SOR convergence flag: set to 1 if any update
      !   exceeds tolerance.
      ! Update W at the origin (r=0)
      W(1, 1, 3) = RHOC2_LOCAL * W(1, 1, 2) + RHO2_LOCAL * (E1 * W(2, 1, 2) &
        + E2 * W(2, NAH, 2) + E3 * W(2, NAP1, 2) + E4)
      DO J = 2, NAP1
        W(1, J, 3) = W(1, 1, 3)
      END DO
      IF (.NOT. (ABS(W(1, 1, 2) - W(1, 1, 3)) <= EPPS2)) ICONV = 1

      ! Update W along alpha=0 (excluding r=0 and r=1)
      DO I = 2, NR
        W(I, 1, 3) = RHOC2_LOCAL * W(I, 1, 2) + RHO2_LOCAL * (E(I, 1, 1) * W &
          (I + 1, 1, 2) + E(I, 1, 2) * 2.0_dp * W(I, 2, 2) + E(I, 1, 3) * W &
          (I - 1, 1, 3) + E(I, 1, 5))
        IF (.NOT. (ABS(W(I, 1, 3) - W(I, 1, 2)) <= EPPS2)) ICONV = 1
      END DO

      ! Update W in the interior (2 <= r <= NR, 2 <= alpha <= NA)
      DO I = 2, NR
        DO J = 2, NA
          W(I, J, 3) = RHOC2_LOCAL * W(I, J, 2) + RHO2_LOCAL * (E(I, J, &
            1) * W(I + 1, J, 2) + E(I, J, 2) * W(I, J + 1, 2) + E(I, J, &
            3) * W(I - 1, J, 3) + E(I, J, 4) * W(I, J - 1, 3) + E(I, J, 5))
          IF (.NOT. (ABS(W(I, J, 2) - W(I, J, 3)) <= EPPS2)) ICONV = 1
        END DO
      END DO

      ! Update W along alpha=pi (excluding r=0 and r=1)
      DO I = 2, NR
        W(I, NAP1, 3) = RHOC2_LOCAL * W(I, NAP1, 2) + RHO2_LOCAL * (E(I, &
          NAP1, 1) * W(I + 1, NAP1, 2) + E(I, NAP1, 3) * W(I - 1, NAP1, &
          3) + 2.0_dp * E(I, NAP1, 4) * W(I, NA, 3) + E(I, NAP1, 5))
        IF (.NOT. (ABS(W(I, NAP1, 2) - W(I, NAP1, 3)) <= EPPS2)) ICONV = 1
      END DO

      ! Check for convergence: if no updates exceed tolerance, exit SOR loop
      IF (ICONV .EQ. 0) EXIT W_SOR
    END DO W_SOR

    ! Update RHO2 in caller if changed
    RHO2 = RHO2_LOCAL

  END SUBROUTINE SOR_W

  !------------------------------------------------------------------------
  !> Performs SOR iteration for OMEGA variable.
  !  Updates OMEGA using SOR until convergence or maximum iterations.
  !------------------------------------------------------------------------
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
      ! If maximum SOR iterations reached, call error handler and exit
      IF(ISOR_OMEGA .GE. MAXSOR) THEN
        CALL ERROR_HANDLER(57, RHO3)
        EXIT OMEGA_SOR
      END IF

      ISOR_OMEGA = ISOR_OMEGA + 1

      ! Update previous SOR iterates for OMEGA
      OMEGA(2:NR,2:NA,2) = OMEGA(2:NR,2:NA,3)

      ICONV = 0

      ! ICONV is a local SOR convergence flag: set to 1 if any update
      !   exceeds tolerance.
      ! Update OMEGA at interior points (2 <= r <= NR, 2 <= alpha <= NA)
      DO I = 2, NR
        DO J = 2, NA
          OMEGA(I, J, 3) = RHOC3 * OMEGA(I, J, 2) + RHO3 * ( &
              E(I, J, 1) * OMEGA(I + 1, J, 2) &
              + E(I, J, 2) * OMEGA(I, J + 1, 2) &
              + E(I, J, 3) * OMEGA(I - 1, J, 3) &
              + E(I, J, 4) * OMEGA(I, J - 1, 3) &
              + E(I, J, 6))
          IF (.NOT. (ABS(OMEGA(I, J, 2) - OMEGA(I, J, 3)) <= EPPS3)) ICONV = 1
        END DO
      END DO

      ! Check for convergence: if no updates exceed tolerance, exit SOR loop
      IF (ICONV .EQ. 0) EXIT OMEGA_SOR
    END DO OMEGA_SOR
  END SUBROUTINE SOR_OMEGA

  !------------------------------------------------------------------------
  !> Smooths the solution array for a given variable.
  !  Used to blend new and previous iterates and check for convergence.
  !  Smoothing blends new and previous iterates to damp oscillations and
  !    improve convergence.
  !------------------------------------------------------------------------
  SUBROUTINE SMOOTH(N1, N2, ARR, XI, XIC, EPS, ICV)
    INTEGER, INTENT(IN) :: N1, N2
    REAL(KIND=dp), INTENT(INOUT) :: ARR(N1, N2, 4)
    REAL(KIND=dp), INTENT(IN) :: XI, XIC, EPS
    INTEGER, INTENT(INOUT) :: ICV
    INTEGER :: I, J
    ! Smooth the solution to stabilize convergence and update the
    !   convergence flag.
    DO I = 2, N1-1
      DO J = 2, N2-1
        ARR(I,J,3) = XI*ARR(I,J,1) + XIC*ARR(I,J,3)
        IF (ABS(ARR(I,J,1)-ARR(I,J,3)) > EPS) ICV = 1
      END DO
    END DO
  END SUBROUTINE SMOOTH
END MODULE SOR_MOD

!------------------------------------------------------------------------
!> Main program: Solves for flow in a curved tube using SOR and outer
!! iteration methods, with Fox's deferred correction (Collins & Dennis
!! 1975) to raise the convective differences from upwind (first order) to
!! central (second order). Handles multiple cases for different D values.
!!
!! Two-level iteration:
!!   (1) with the correction sources CW (W eq.) and COM (OMEGA eq.) frozen,
!!       iterate PHI, W, OMEGA to convergence (Schubert's outer iteration);
!!   (2) recompute the corrections from the converged fields, blend them
!!       with factor OMEGA1, and repeat until the corrections converge.
!------------------------------------------------------------------------
PROGRAM MAIN
    USE KIND_MOD
    USE ERROR_MOD
    USE SOR_MOD
    IMPLICIT NONE

! PHI(:,:,1): previous outer iterate (from last outer iteration)
! PHI(:,:,2): previous SOR iterate (from last SOR sweep)
! PHI(:,:,3): current SOR iterate (being updated in this sweep)
! PHI(:,:,4): storage for next case (used as initial guess for next D)
! The same convention applies to W and OMEGA arrays.

    INTEGER, PARAMETER :: NR = 2*10, NA = 2*18
    INTEGER, PARAMETER :: NRP1 = NR + 1, NAP1 = NA + 1
    INTEGER, PARAMETER :: NRM1 = NR - 1
    INTEGER, PARAMETER :: NAH = NA / 2 + 1
    INTEGER, PARAMETER :: NPHI = 4, NB = 5, NE = 6
    INTEGER, PARAMETER :: NCASE = 17

    REAL(KIND=dp) :: PHI(NRP1, NAP1, NPHI), W(NRP1, NAP1, NPHI)
    REAL(KIND=dp) :: OMEGA(NRP1, NAP1, NPHI)
    REAL(KIND=dp) :: SA(NAP1), COSA(NAP1), RINV(NRP1), RINV2(NRP1)
    REAL(KIND=dp) :: CA(NRP1, NAP1)
    REAL(KIND=dp) :: B(NRP1, NB), C(NRP1, NAP1), E(NRP1, NAP1, NE)
    REAL(KIND=dp) :: EE(NRP1), EF(NRP1), EE1, EE2
    ! Deferred-correction source terms (C_0 and E_0 of Collins & Dennis),
    !   in the code's normalisation (equation multiplied by DR*DA).
    !   CW(1,1) holds the correction at the origin.
    REAL(KIND=dp) :: CW(NRP1, NAP1), COM(NRP1, NAP1)
    REAL(KIND=dp) :: CWN(NRP1, NAP1), COMN(NRP1, NAP1)
    REAL(KIND=dp) :: XI(4), XIC(4), RHO(3), RHOC(3), EPS(3), EPPS(3)
    REAL(KIND=dp) :: RHO0(3)
    REAL(KIND=dp) :: BO, DDR2, DDRDAM, DRRH, DR, DA, DAH, DRH, DRDAM, DRDA
    REAL(KIND=dp) :: DADR, E0, E1, E2, E3, E4, GAMMA, DELTA, DELTA1, DELTA2
    REAL(KIND=dp) :: PI, D, DOR(3)
    LOGICAL :: REPORT(NCASE)
    REAL(KIND=dp) :: DLIST(NCASE), OMEGA1, TOLR, TOLC
    REAL(KIND=dp) :: SPHI, SW, SOM, DCW, DCOM, PHIM, WM, PHIM0, WM0
    INTEGER :: I, J, ICONV, ICV, IOUT, IRW, IRO, ctr, MAXSOR, MAXOUT, NOR
    INTEGER :: ISOR_PHI, ISOR_W, ISOR_OMEGA, IDC, MAXDC, NOUTTOT
    LOGICAL :: FAILED, INNERFAIL, DCDONE
    LOGICAL :: UPWIND          ! diagnostic: run with argument "upwind" to
                               !   switch the deferred correction off
    CHARACTER(LEN=16) :: ARG
    REAL(KIND=dp) :: TLIMIT       ! wall-clock limit (s); later cases FAILED
    LOGICAL :: TIMEUP
    REAL(KIND=dp) :: OMW
    LOGICAL :: VERBOSE = .FALSE.
    INTEGER(KIND=8) :: NSW(3)     ! SOR sweep counters (PHI, W, OMEGA)
    INTEGER :: clock_start, clock_end, clock_rate
    REAL(KIND=dp) :: elapsed_time

    CALL SYSTEM_CLOCK(COUNT_RATE=clock_rate)
    ARG = " "
    IF (COMMAND_ARGUMENT_COUNT() > 0) CALL GET_COMMAND_ARGUMENT(1, ARG)
    UPWIND = (TRIM(ARG) == "upwind")
    TLIMIT = 540._dp
    IF (COMMAND_ARGUMENT_COUNT() > 1) THEN
      CALL GET_COMMAND_ARGUMENT(2, ARG)
      READ(ARG,*) TLIMIT
    END IF
    TIMEUP = .FALSE.
    VERBOSE = (COMMAND_ARGUMENT_COUNT() > 2)
    NSW = 0
    ! Poisson equation for PHI also at r = 1 - h (PHI = 0 at the wall);
    !   Schubert's PHI(NR) = PHI(NR-1)/4 rule gives PHI_M about 2.5% high.
    PHIWALL = 1
    CALL SYSTEM_CLOCK(COUNT=clock_start)

    PHI(:,:,:) = 0.0_dp
    W(:,:,:) = 0.0_dp
    OMEGA(:,:,:) = 0.0_dp
    CW(:,:) = 0.0_dp
    COM(:,:) = 0.0_dp
    CWN(:,:) = 0.0_dp
    COMN(:,:) = 0.0_dp
    E(:,:,:) = 0.0_dp

    PI = ACOS(-1.0_dp)
    MAXSOR = 20000
    MAXOUT = 20000
    MAXDC = 2000
    NOR = 3
    DOR = (/0.2_dp, 0.2_dp, 0.2_dp/)

    ! Continuation in D; only the target values (REPORT = .TRUE.) are
    !   reported, the others are intermediate steps.
    DLIST = (/96.0_dp, 200.0_dp, 300.0_dp, 400.0_dp, 500.0_dp, 605.72_dp, &
      800.0_dp, 1000.0_dp, 1250.0_dp, 1500.0_dp, 1750.0_dp, 2000.0_dp, &
      2500.0_dp, 3000.0_dp, 3500.0_dp, 4250.0_dp, 5000.0_dp/)
    REPORT = .FALSE.
    REPORT((/1, 5, 6, 8, 12, 15, 17/)) = .TRUE.

    DR = 1._dp / NR
    DA = PI / NA
    DAH = .5_dp * DA
    DRH = .5_dp * DR
    DRDAM = DR * DA
    DRDA = DR / DA
    DADR = DA / DR

    SA(1) = 0._dp
    COSA(1) = 1._dp
    DO J = 2, NA
      SA(J) = SIN((J - 1) * DA) * DAH
      COSA(J) = COS((J - 1) * DA)
    END DO
    SA(NAP1) = 0._dp
    COSA(NAP1) = -1._dp
    RINV(1) = 0._dp
    RINV2(1) = 0._dp
    RINV(NRP1) = 1._dp
    RINV2(NRP1) = 1._dp
    CA(:,:) = 0._dp
    DO I = 2, NR
      RINV(I) = 1._dp / ((I - 1) * DR)
      DRRH = DRH * RINV(I)
      RINV2(I) = RINV(I) ** 2
      DO J = 2, NA
        CA(I, J) = DRRH * COSA(J)
      END DO
    END DO

!------------------- SOR coefficient setup for PHI ----------------------
! Central differences for the Laplacian, including the (1/r) dPHI/dr term
!   (Schubert used a one-sided difference here).
    B(:,:) = 0._dp
    DO I = 2, NR
      BO = 2._dp * (DADR + DRDA * RINV2(I))
      B(I, 1) = (DADR + DAH * RINV(I)) / BO
      B(I, 2) = DRDA * RINV2(I) / BO
      B(I, 3) = (DADR - DAH * RINV(I)) / BO
      B(I, 4) = B(I, 2)
      B(I, 5) = DRDAM / BO
    END DO

    NOUTTOT = 0

    DO ctr = 1, NCASE
      D = DLIST(ctr)
      ! SOR factors, smoothing factors and correction smoothing per case
      IF (D < 1500._dp) THEN
        RHO0 = (/1.5_dp, 1.2_dp, 1.2_dp/)
        OMEGA1 = 0.5_dp
      ELSE
        RHO0 = (/1.2_dp, 1.2_dp, 1.04_dp/)
        OMEGA1 = 0.3_dp
      END IF
      ! Smoothing (weight on previous outer iterate): PHI, W, wall OMEGA,
      !   interior OMEGA. Interior OMEGA needs strong damping, the wall
      !   vorticity only light damping, otherwise the outer iteration falls
      !   into a limit cycle at D >= 1250 (see REPORT.md).
      XI = (/0.5_dp, 0.0_dp, 0.2_dp, 0.9_dp/)
      RHO = RHO0
      TOLR = 1.0E-7_dp     ! inner (frozen-correction) relative tolerance
      TOLC = 1.0E-5_dp     ! relative tolerance on the corrections

      DDRDAM = D * DRDAM
      DDR2 = D * DR ** 2

      DO I = 1, 3
        XIC(I) = 1._dp - XI(I)
        RHOC(I) = 1._dp - RHO(I)
      END DO
      XIC(4) = 1._dp - XI(4)

      PHI(:,:,3) = PHI(:,:,4)
      W(:,:,3) = W(:,:,4)
      OMEGA(:,:,3) = OMEGA(:,:,4)

      ! Initial corrections from the starting fields
      CALL CORRECTIONS()
      CW = CWN
      COM = COMN

      FAILED = .FALSE.
      DCDONE = .FALSE.
      PHIM0 = 0._dp
      WM0 = 0._dp

!------------------- Deferred-correction (level 2) loop -----------------
      DC_ITER: DO IDC = 1, MAXDC
        ! Tolerances scaled with current field magnitudes
        SPHI = MAX(MAXVAL(ABS(PHI(:,:,3))), 1.0E-2_dp * D / 96._dp)
        SW = MAX(MAXVAL(ABS(W(:,:,3))), 0.25_dp * D * 0.5_dp)
        SOM = MAX(MAXVAL(ABS(OMEGA(:,:,3))), 1.0_dp)
        EPS = TOLR * (/SPHI, SW, SOM/)
        EPPS = 0.05_dp * EPS

        IF (TIMEUP) THEN
          FAILED = .TRUE.
          EXIT DC_ITER
        END IF
        CALL INNER(INNERFAIL)
        IF (INNERFAIL) THEN
          FAILED = .TRUE.
          EXIT DC_ITER
        END IF

        CALL CORRECTIONS()
        DCW = MAXVAL(ABS(CWN - CW)) / MAX(MAXVAL(ABS(CWN)), 1.0E-30_dp)
        DCOM = MAXVAL(ABS(COMN - COM)) / MAX(MAXVAL(ABS(COMN)), 1.0E-30_dp)
        CW = OMEGA1 * CWN + (1._dp - OMEGA1) * CW
        COM = OMEGA1 * COMN + (1._dp - OMEGA1) * COM

        PHIM = MAXVAL(ABS(PHI(:,:,3)))
        WM = MAXVAL(ABS(W(:,:,3)))
        IF (MOD(IDC, 20) == 0 .OR. IDC <= 3) THEN
          WRITE(*,'("  DC",I5," IOUT",I6," dCW",ES10.2," dCOM",ES10.2, &
            &" phiM",F10.5," wM",F10.4)') IDC, IOUT, DCW, DCOM, PHIM, WM
          FLUSH(6)
        END IF
        IF (DCW < TOLC .AND. DCOM < TOLC .AND. &
            ABS(PHIM - PHIM0) < 1.0E-6_dp * PHIM .AND. &
            ABS(WM - WM0) < 1.0E-6_dp * WM) THEN
          DCDONE = .TRUE.
          EXIT DC_ITER
        END IF
        IF (.NOT. (DCW < 1.0E10_dp)) THEN
          FAILED = .TRUE.
          EXIT DC_ITER
        END IF
        PHIM0 = PHIM
        WM0 = WM
      END DO DC_ITER
      IF (.NOT. DCDONE) FAILED = .TRUE.

      PHIM = MAXVAL(ABS(PHI(:,:,3)))
      WM = MAXVAL(ABS(W(:,:,3)))
      WRITE(*,'("  D =",F9.2," correction cycles =",I5, &
        &" outer its =",I8," sweeps",3I10," t=",F7.1)') D, IDC, NOUTTOT, &
        NSW, ELAPSED()
      FLUSH(6)
      IF (.NOT. REPORT(ctr)) THEN
        CONTINUE
      ELSE IF (FAILED) THEN
        WRITE(*,'("RESULT D=",F0.2," PHI_M=",F0.4," W_M=",F0.3, &
          &" STATUS=FAILED")') D, PHIM, WM
      ELSE
        WRITE(*,'("RESULT D=",F0.2," PHI_M=",F0.4," W_M=",F0.3, &
          &" STATUS=CONVERGED")') D, PHIM, WM
      END IF

      ! Store current solution as initial guess for next D (only if sane)
      IF (.NOT. FAILED) THEN
        PHI(:,:,4) = PHI(:,:,3)
        W(:,:,4) = W(:,:,3)
        OMEGA(:,:,4) = OMEGA(:,:,3)
      END IF
    END DO

    CALL SYSTEM_CLOCK(COUNT=clock_end)
    elapsed_time = REAL(clock_end - clock_start, KIND=dp) / REAL(clock_rate, &
      KIND=dp)
    PRINT *, '[SYSTEM_CLOCK] Elapsed time (seconds):', elapsed_time

CONTAINS

  REAL(KIND=dp) FUNCTION ELAPSED()
    INTEGER :: CNOW
    CALL SYSTEM_CLOCK(COUNT=CNOW)
    ELAPSED = REAL(CNOW - clock_start, KIND=dp) / REAL(clock_rate, KIND=dp)
  END FUNCTION ELAPSED

  !----------------------------------------------------------------------
  !> Deferred corrections from the current fields (PHI, W, OMEGA)(:,:,3):
  !!   CWN  = -(1/2r) [ |DELTA| d2r(W) + |GAMMA| d2a(W) ]
  !!   COMN = -(1/2r) [ |DELTA| d2r(OMEGA) + |GAMMA| d2a(OMEGA) ]
  !! with DELTA, GAMMA exactly as in the upwind coefficients, so that
  !! upwind operator + correction = central-difference operator.
  !----------------------------------------------------------------------
  SUBROUTINE CORRECTIONS()
    INTEGER :: II, JJ
    REAL(KIND=dp) :: G, DL, P
    CWN = 0._dp
    COMN = 0._dp
    DO II = 2, NR
      DO JJ = 2, NA
        G = .5_dp * (PHI(II+1,JJ,3) - PHI(II-1,JJ,3))
        DL = DA - .5_dp * (PHI(II,JJ+1,3) - PHI(II,JJ-1,3))
        CWN(II,JJ) = -.5_dp * RINV(II) * ( &
          ABS(DL) * (W(II+1,JJ,3) + W(II-1,JJ,3) - 2._dp * W(II,JJ,3)) &
          + ABS(G) * (W(II,JJ+1,3) + W(II,JJ-1,3) - 2._dp * W(II,JJ,3)))
        COMN(II,JJ) = -.5_dp * RINV(II) * ( &
          ABS(DL) * (OMEGA(II+1,JJ,3) + OMEGA(II-1,JJ,3) &
            - 2._dp * OMEGA(II,JJ,3)) &
          + ABS(G) * (OMEGA(II,JJ+1,3) + OMEGA(II,JJ-1,3) &
            - 2._dp * OMEGA(II,JJ,3)))
      END DO
      ! Symmetry lines alpha = 0 and alpha = pi (GAMMA = 0 there)
      DL = DA - PHI(II,2,3)
      CWN(II,1) = -.5_dp * RINV(II) * ABS(DL) * &
        (W(II+1,1,3) + W(II-1,1,3) - 2._dp * W(II,1,3))
      DL = DA + PHI(II,NA,3)
      CWN(II,NAP1) = -.5_dp * RINV(II) * ABS(DL) * &
        (W(II+1,NAP1,3) + W(II-1,NAP1,3) - 2._dp * W(II,NAP1,3))
    END DO
    ! Origin (scaled by DR**2 like the origin equation)
    P = PHI(2,NAH,3)
    CWN(1,1) = -.5_dp * ABS(P) * (W(2,1,3) + W(2,NAP1,3) - 2._dp * W(1,1,3))
    IF (UPWIND) THEN
      CWN = 0._dp
      COMN = 0._dp
    END IF
  END SUBROUTINE CORRECTIONS

  !----------------------------------------------------------------------
  !> Schubert's outer iteration with frozen corrections CW, COM.
  !----------------------------------------------------------------------
  SUBROUTINE INNER(FAIL)
    LOGICAL, INTENT(OUT) :: FAIL
    INTEGER :: II, JJ
    FAIL = .FALSE.
    IOUT = 0
    OUTER_ITER: DO
      IF (ELAPSED() > TLIMIT) THEN
        TIMEUP = .TRUE.
        FAIL = .TRUE.
        EXIT OUTER_ITER
      END IF
      IF (IOUT >= MAXOUT) THEN
        CALL ERROR_HANDLER(58)
        FAIL = .TRUE.
        EXIT OUTER_ITER
      END IF
      IOUT = IOUT + 1
      NOUTTOT = NOUTTOT + 1
      ICV = 0

      PHI(:,:,1) = PHI(:,:,3)
      W(:,:,1) = W(:,:,3)
      OMEGA(:,:,1) = OMEGA(:,:,3)

      DO II = 2, NR
        DO JJ = 2, NA
          C(II,JJ) = B(II,5) * OMEGA(II,JJ,1)
        END DO
      END DO

      PHI(:,:,2) = PHI(:,:,3)
      CALL SOR_PHI(PHI, OMEGA, B, C, RHOC, RHO, EPPS, ISOR_PHI, MAXSOR, NR, &
        NA, NRP1, NAP1, NRM1, ERROR_HANDLER)
      NSW(1) = NSW(1) + ISOR_PHI
      CALL SMOOTH(NRP1, NAP1, PHI, XI(1), XIC(1), EPS(1), ICV)

      ! Origin coefficients for W (upwind) + deferred correction
      E0 = 4._dp + ABS(PHI(2,NAH,3))
      E1 = (1._dp - MIN(PHI(2,NAH,3),0._dp)) / E0
      E2 = 2._dp / E0
      E3 = (1._dp + MAX(PHI(2,NAH,3),0._dp)) / E0
      E4 = (DDR2 + CW(1,1)) / E0

      DO II = 2, NR
        DELTA1 = DA - PHI(II,2,3)
        DELTA2 = DA + PHI(II,NA,3)
        EE(II) = 2._dp * (DADR + DRDA * RINV2(II))
        EE1 = EE(II) + RINV(II) * ABS(DELTA1)
        EE2 = EE(II) + RINV(II) * ABS(DELTA2)
        E(II,1,1) = (DADR + RINV(II) * MAX(DELTA1,0._dp)) / EE1
        E(II,NAP1,1) = (DADR + RINV(II) * MAX(DELTA2,0._dp)) / EE2
        EF(II) = DRDA * RINV2(II)
        E(II,1,2) = EF(II) / EE1
        E(II,NAP1,2) = EF(II) / EE2
        E(II,1,3) = (DADR - RINV(II) * MIN(DELTA1,0._dp)) / EE1
        E(II,NAP1,3) = (DADR - RINV(II) * MIN(DELTA2,0._dp)) / EE2
        E(II,1,4) = E(II,1,2)
        E(II,NAP1,4) = E(II,NAP1,2)
        E(II,1,5) = (DDRDAM + CW(II,1)) / EE1
        E(II,NAP1,5) = (DDRDAM + CW(II,NAP1)) / EE2
      END DO

      DO II = 2, NR
        DO JJ = 2, NA
          GAMMA = .5_dp * (PHI(II+1,JJ,3) - PHI(II-1,JJ,3))
          DELTA = DA - .5_dp * (PHI(II,JJ+1,3) - PHI(II,JJ-1,3))
          E(II,JJ,6) = EE(II) + RINV(II) * (ABS(GAMMA) + ABS(DELTA))
          E(II,JJ,1) = (DADR + RINV(II) * MAX(DELTA,0._dp)) / E(II,JJ,6)
          E(II,JJ,2) = (EF(II) + RINV(II) * MAX(GAMMA,0._dp)) / E(II,JJ,6)
          E(II,JJ,3) = (DADR - RINV(II) * MIN(DELTA,0._dp)) / E(II,JJ,6)
          E(II,JJ,4) = (EF(II) - RINV(II) * MIN(GAMMA,0._dp)) / E(II,JJ,6)
          E(II,JJ,5) = (DDRDAM + CW(II,JJ)) / E(II,JJ,6)
        END DO
      END DO

      IRW = 0
      W(:,:,3) = W(:,:,1)
      CALL SOR_W(W, E, EPPS(2), RHOC(2), RHO(2), ISOR_W, MAXSOR, NR, NA, &
        NRP1, NAP1, NAH, E1, E2, E3, E4, DOR, NOR, IRW, ICONV, &
        ERROR_HANDLER)
      RHOC(2) = 1._dp - RHO(2)
      NSW(2) = NSW(2) + ISOR_W
      IF (ICONV /= 0) THEN
        FAIL = .TRUE.
        EXIT OUTER_ITER
      END IF

      W(1,1,3) = XI(2) * W(1,1,1) + XIC(2) * W(1,1,3)
      DO JJ = 2, NAP1
        W(1,JJ,3) = W(1,1,3)
      END DO
      IF (ABS(W(1,1,1) - W(1,1,3)) .GT. EPS(2)) ICV = 1
      ! Smooth W including the symmetry lines alpha = 0, pi
      DO II = 2, NR
        DO JJ = 1, NAP1
          W(II,JJ,3) = XI(2) * W(II,JJ,1) + XIC(2) * W(II,JJ,3)
          IF (ABS(W(II,JJ,1) - W(II,JJ,3)) > EPS(2)) ICV = 1
        END DO
      END DO

      ! Wall vorticity (Thom's formula), smoothed
      DO JJ = 2, NA
        OMW = -2._dp * RINV2(2) * PHI(NR,JJ,3)
        OMEGA(NRP1,JJ,3) = XI(3) * OMEGA(NRP1,JJ,1) + XIC(3) * OMW
        IF (ABS(OMEGA(NRP1,JJ,1) - OMEGA(NRP1,JJ,3)) .GT. EPS(3)) ICV = 1
      END DO

      DO II = 2, NR
        DO JJ = 2, NA
          E(II,JJ,6) = (-W(II,JJ,3) * (SA(JJ) * (W(II+1,JJ,3) - &
            W(II-1,JJ,3)) + CA(II,JJ) * (W(II,JJ+1,3) - W(II,JJ-1,3))) &
            + COM(II,JJ)) / E(II,JJ,6)
        END DO
      END DO

      ! Wall row must be visible to the SOR sweep (slot 2 is used for I+1);
      !   the original only copied rows 2:NR, so OMEGA at the wall was 0.
      OMEGA(NRP1,:,2) = OMEGA(NRP1,:,3)
      IRO = 0
      OMEGA_RETRY: DO
        CALL SOR_OMEGA(OMEGA, E, RHOC(3), RHO(3), EPPS(3), ISOR_OMEGA, &
          MAXSOR, NR, NA, NRP1, NAP1, ICONV, ERROR_HANDLER)
        NSW(3) = NSW(3) + ISOR_OMEGA
        IF (ICONV .EQ. 0) EXIT OMEGA_RETRY
        IF (IRO >= NOR) THEN
          FAIL = .TRUE.
          EXIT OUTER_ITER
        END IF
        IRO = IRO + 1
        RHO(3) = RHO(3) - DOR(IRO)
        RHOC(3) = 1.0_dp - RHO(3)
        OMEGA(2:NR,2:NA,3) = OMEGA(2:NR,2:NA,1)
      END DO OMEGA_RETRY

      CALL SMOOTH(NRP1, NAP1, OMEGA, XI(4), XIC(4), EPS(3), ICV)

      IF (.NOT. (ABS(W(1,1,3)) < 1.0E8_dp)) THEN
        FAIL = .TRUE.
        EXIT OUTER_ITER
      END IF
      IF (VERBOSE) WRITE(*,'(4X,F8.1,I6,3I6,3ES13.5)') D, IOUT, ISOR_PHI, ISOR_W, &
        ISOR_OMEGA, MAXVAL(ABS(PHI(:,:,3))), MAXVAL(ABS(W(:,:,3))), &
        MAXVAL(ABS(OMEGA(:,:,3)))
      IF (ICV == 0) EXIT OUTER_ITER
    END DO OUTER_ITER
  END SUBROUTINE INNER

END PROGRAM MAIN
