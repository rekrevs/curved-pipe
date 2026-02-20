using Printf

# Dean Flow Solver — Julia port of Collins_Dennis_1975_central.f90
#
# Collins & Dennis (1975) Fox deferred correction method for Dean flow
# in a curved pipe. Three coupled fields (PHI, W, OMEGA) on a polar grid.
#
# Usage: julia dean_flow.jl [b|c]
#   b = grid (b): NR=20, NA=36 (default, ~5 sec)
#   c = grid (c): NR=40, NA=72 (~38 sec)

# ============================================================================
# Slice convention (preserved from Fortran)
# ============================================================================
const ITER_START = 1   # saved at start of outer iteration
const SOR_OLD    = 2   # SOR reads from here
const SOR_NEW    = 3   # SOR writes here; current solution
const CARRY      = 4   # carry-over between D cases

const AA_MMAX = 5      # max Anderson acceleration history depth

# ============================================================================
# Types
# ============================================================================

struct GridParams
    NR::Int
    NA::Int
    NRP1::Int
    NAP1::Int
    NRM1::Int
    NAH::Int
    DR::Float64
    DA::Float64
    DAH::Float64
    DRH::Float64
    DRDAM::Float64
    DRDA::Float64
    DADR::Float64
    PI::Float64
    SA::Vector{Float64}
    COSA::Vector{Float64}
    RINV::Vector{Float64}
    RINV2::Vector{Float64}
    CA::Matrix{Float64}
    DELA::Vector{Float64}
    B::Matrix{Float64}     # (NRP1, 5) PHI SOR coefficients
end

struct CaseConfig
    D::Float64
    EPS::Vector{Float64}       # (3,)
    EPS_OUT::Vector{Float64}   # (3,)
    RHO::Vector{Float64}       # (3,)
    XI::Vector{Float64}        # (4,)
    OMEGA1::Float64
    AA_ON::Bool
end

struct SORParams
    MAXSOR::Int
    MAXOUT::Int
    NOR::Int
    DOR::Vector{Float64}
    MAX_CORR::Int
    CORR_TOL::Float64
    STEP_ITERS::Int
    AA_DEPTH::Int
    AA_BETA::Float64
    AA_REG::Float64
end

mutable struct SolverState
    PHI::Array{Float64,3}      # (NRP1, NAP1, 4)
    W::Array{Float64,3}        # (NRP1, NAP1, 4)
    OMEGA::Array{Float64,3}    # (NRP1, NAP1, 4)
    C::Matrix{Float64}         # (NRP1, NAP1)
    E::Array{Float64,3}        # (NRP1, NAP1, 6)
    EE::Vector{Float64}        # (NRP1,)
    EF::Vector{Float64}        # (NRP1,)
    CO::Vector{Float64}        # (NR,)
    C0_CORR::Matrix{Float64}
    E0_CORR::Matrix{Float64}
    C0_CORR_NEW::Matrix{Float64}
    E0_CORR_NEW::Matrix{Float64}
    C0_CORR_NEW_PREV::Matrix{Float64}
    E0_CORR_NEW_PREV::Matrix{Float64}
    C0_SAVE::Matrix{Float64}
    E0_SAVE::Matrix{Float64}
    PHI_UNCORR::Matrix{Float64}
    W_UNCORR::Matrix{Float64}
    OMEGA_UNCORR::Matrix{Float64}
    PHI_PREV::Matrix{Float64}
    W_PREV::Matrix{Float64}
    OMEGA_PREV::Matrix{Float64}
    C0_CORR_SAVE_PREV::Matrix{Float64}
    E0_CORR_SAVE_PREV::Matrix{Float64}
    DSTART::Float64
end

mutable struct AndersonState
    PHI_GH::Array{Float64,3}   # (NRP1, NAP1, AA_MMAX+1)
    W_GH::Array{Float64,3}
    OMEGA_GH::Array{Float64,3}
    PHI_FH::Array{Float64,3}
    W_FH::Array{Float64,3}
    OMEGA_FH::Array{Float64,3}
    AA_MAT::Matrix{Float64}    # (AA_MMAX+2, AA_MMAX+2)
    AA_RHS::Vector{Float64}
    AA_SOL::Vector{Float64}
    AA_ALPHA::Vector{Float64}
    AA_NHIST::Int
end

# ============================================================================
# Constructors
# ============================================================================

function build_grid(NR::Int, NA::Int)
    NRP1 = NR + 1
    NAP1 = NA + 1
    NRM1 = NR - 1
    NAH = NA ÷ 2 + 1

    PI = 3.14159255  # Schubert (1972) original value

    DR = 1.0 / NR
    DA = PI / NA
    DAH = 0.5 * DA
    DRH = 0.5 * DR
    DRDAM = DR * DA
    DRDA = DR / DA
    DADR = DA / DR

    DELA = Vector{Float64}(undef, NR)
    for i in 1:NR
        DELA[i] = (2i - 1) * DRH * DRDAM
    end

    SA = Vector{Float64}(undef, NAP1)
    COSA = Vector{Float64}(undef, NAP1)
    SA[1] = 0.0
    COSA[1] = 0.0  # not used at j=1
    for j in 2:NA
        SA[j] = sin((j - 1) * DA) * DAH
        COSA[j] = cos((j - 1) * DA)
    end
    SA[NAP1] = 0.0
    COSA[NAP1] = -1.0

    RINV = Vector{Float64}(undef, NRP1)
    RINV2 = Vector{Float64}(undef, NRP1)
    CA = zeros(NRP1, NAP1)

    RINV[NRP1] = 1.0
    RINV2[NRP1] = 1.0
    RINV[1] = 0.0   # not used at i=1
    RINV2[1] = 0.0
    for i in 2:NR
        RINV[i] = 1.0 / ((i - 1) * DR)
        DRRH = DRH * RINV[i]
        RINV2[i] = RINV[i]^2
        for j in 2:NA
            CA[i, j] = DRRH * COSA[j]
        end
    end

    # PHI SOR coefficients (central differencing)
    B = zeros(NRP1, 5)
    for i in 2:NR
        BO = 2.0 * (DADR + DRDA * RINV2[i])
        B[i, 1] = (DADR + 0.5 * DA * RINV[i]) / BO
        B[i, 2] = (DRDA * RINV2[i]) / BO
        B[i, 3] = (DADR - 0.5 * DA * RINV[i]) / BO
        B[i, 4] = B[i, 2]
        B[i, 5] = DRDAM / BO
    end

    GridParams(NR, NA, NRP1, NAP1, NRM1, NAH,
               DR, DA, DAH, DRH, DRDAM, DRDA, DADR, PI,
               SA, COSA, RINV, RINV2, CA, DELA, B)
end

function build_cases(g::GridParams)
    NR = g.NR
    D_CASES = [10.0, 96.0, 100.0, 250.0, 500.0,
               605.72, 1000.0, 2000.0, 3500.0, 5000.0]

    EPS_CASES = [
        [1.0e-5, 1.0e-3, 1.0e-4],    # D=10
        [1.5e-4, 4.0e-3, 4.0e-3],    # D=96
        [2.0e-4, 5.0e-3, 5.0e-3],    # D=100
        [2.0e-3, 2.0e-2, 4.0e-2],    # D=250
        [4.0e-3, 4.0e-2, 8.0e-2],    # D=500
        [4.5e-3, 4.5e-2, 9.0e-2],    # D=605.72
        [5.0e-3, 5.0e-2, 17.0e-2],   # D=1000
        [7.0e-3, 8.0e-2, 3.0e-1],    # D=2000
        [8.0e-3, 10.0e-2, 4.0e-1],   # D=3500
        [1.0e-2, 15.0e-2, 6.0e-1],   # D=5000
    ]

    EPS_OUT_CASES = [copy(e) for e in EPS_CASES]
    if NR >= 40
        # Grid (c): tight EPS_OUT
    else
        # Grid (b): loosened for high D
        EPS_OUT_CASES[9]  = [6.0e-2, 5.0e-1, 8.0e+0]
        EPS_OUT_CASES[10] = [3.0e-1, 2.0e+0, 2.0e+1]
    end

    RHO_CASES = [
        [1.5, 1.8, 1.5],
        [1.5, 1.7, 1.5],
        [1.5, 1.7, 1.5],
        NR >= 40 ? [1.5, 1.7, 1.5] : [1.5, 1.5, 1.5],
        NR >= 40 ? [1.5, 1.7, 1.5] : [1.5, 1.5, 1.5],
        NR >= 40 ? [1.5, 1.7, 1.5] : [1.5, 1.5, 1.5],
        NR >= 40 ? [1.5, 1.7, 1.5] : [1.5, 1.5, 1.5],
        NR >= 40 ? [1.5, 1.7, 1.5] : [1.5, 1.5, 1.5],
        [1.5, 1.5, 1.5],
        [1.5, 1.5, 1.5],
    ]

    XI_CASES = [
        [0.1, 0.1, 0.9, 0.1],
        [0.1, 0.1, 0.9, 0.1],
        [0.1, 0.1, 0.9, 0.1],
        [0.5, 0.1, 0.5, 0.5],
        [0.5, 0.1, 0.5, 0.5],
        [0.5, 0.1, 0.5, 0.5],
        [0.5, 0.1, 0.5, 0.5],
        [0.5, 0.1, 0.5, 0.5],
        [0.5, 0.1, 0.5, 0.5],
        [0.5, 0.1, 0.5, 0.5],
    ]

    OMEGA1_CASES = [1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0,
                    0.1, 0.05, NR >= 40 ? 0.01 : 0.0]

    cases = CaseConfig[]
    for i in 1:10
        aa_on = D_CASES[i] >= 3500.0
        push!(cases, CaseConfig(D_CASES[i], EPS_CASES[i], EPS_OUT_CASES[i],
                                RHO_CASES[i], XI_CASES[i], OMEGA1_CASES[i], aa_on))
    end
    cases
end

function build_sor_params(NR::Int)
    if NR >= 40
        maxsor = 50000
        step_iters = 40
    else
        maxsor = 2500
        step_iters = 20
    end
    SORParams(maxsor, 40000, 3, [0.2, 0.2, 0.2], 800, 5.0e-4,
              step_iters, 4, 0.5, 1.0e-12)
end

function build_state(g::GridParams)
    NRP1, NAP1, NR = g.NRP1, g.NAP1, g.NR
    z2() = zeros(NRP1, NAP1)
    SolverState(
        zeros(NRP1, NAP1, 4),   # PHI
        zeros(NRP1, NAP1, 4),   # W
        zeros(NRP1, NAP1, 4),   # OMEGA
        z2(),                    # C
        zeros(NRP1, NAP1, 6),   # E
        zeros(NRP1),             # EE
        zeros(NRP1),             # EF
        zeros(NR),               # CO
        z2(), z2(),              # C0_CORR, E0_CORR
        z2(), z2(),              # C0_CORR_NEW, E0_CORR_NEW
        z2(), z2(),              # C0_CORR_NEW_PREV, E0_CORR_NEW_PREV
        z2(), z2(),              # C0_SAVE, E0_SAVE
        z2(), z2(), z2(),        # PHI/W/OMEGA_UNCORR
        z2(), z2(), z2(),        # PHI/W/OMEGA_PREV
        z2(), z2(),              # C0/E0_CORR_SAVE_PREV
        0.0                      # DSTART
    )
end

function build_anderson(g::GridParams)
    NRP1, NAP1 = g.NRP1, g.NAP1
    h() = zeros(NRP1, NAP1, AA_MMAX + 1)
    AndersonState(
        h(), h(), h(),                          # GH
        h(), h(), h(),                          # FH
        zeros(AA_MMAX + 2, AA_MMAX + 2),        # AA_MAT
        zeros(AA_MMAX + 2),                      # AA_RHS
        zeros(AA_MMAX + 2),                      # AA_SOL
        zeros(AA_MMAX + 1),                      # AA_ALPHA
        0                                        # AA_NHIST
    )
end

# ============================================================================
# SOR Solvers
# ============================================================================

function sor_phi!(PHI::Array{Float64,3}, OMEGA::Array{Float64,3},
                  B::Matrix{Float64}, C::Matrix{Float64},
                  RHOC1::Float64, RHO1::Float64, EPPS1::Float64,
                  MAXSOR::Int, NR::Int, NA::Int, NRP1::Int, NAP1::Int, NRM1::Int)
    isor_phi = 0
    NR_INNER = NR  # always full stencil (USE_PARABOLIC_WALL=false)

    while true
        iconv = 0
        @inbounds for i in 2:NR_INNER
            for j in 2:NA
                PHI[i,j,SOR_NEW] = RHOC1*PHI[i,j,SOR_OLD] + RHO1*(
                    B[i,1]*PHI[i+1,j,SOR_OLD] + B[i,2]*PHI[i,j+1,SOR_OLD] +
                    B[i,3]*PHI[i-1,j,SOR_NEW] + B[i,4]*PHI[i,j-1,SOR_NEW] + C[i,j])
                if !isfinite(PHI[i,j,SOR_NEW])
                    iconv = 1
                    isor_phi = MAXSOR
                    @goto phi_done
                end
                if abs(PHI[i,j,SOR_OLD] - PHI[i,j,SOR_NEW]) > EPPS1
                    iconv = 1
                end
            end
        end
        if iconv == 0
            @goto phi_done
        end
        isor_phi += 1
        if isor_phi >= MAXSOR
            println("SOR FOR PHI FAILED.")
            @goto phi_done
        end
        @inbounds for i in 2:NR, j in 2:NA
            PHI[i,j,SOR_OLD] = PHI[i,j,SOR_NEW]
        end
    end
    @label phi_done
    return isor_phi
end

function sor_w!(W::Array{Float64,3}, E::Array{Float64,3},
                EPPS2::Float64, RHOC2_in::Float64, RHO2_in::Float64,
                MAXSOR::Int, NR::Int, NA::Int, NRP1::Int, NAP1::Int, NAH::Int,
                E1::Float64, E2::Float64, E3::Float64, E4::Float64,
                DOR::Vector{Float64}, NOR::Int)
    isor_w = 0
    irw = 0
    rhoc2 = RHOC2_in
    rho2 = RHO2_in
    iconv = 0

    while true
        if isor_w >= MAXSOR
            @printf("SOR FOR W FAILED WITH SOR FACTOR =%6.2f\n", rho2)
            if irw >= NOR
                break
            end
            irw += 1
            rho2 -= DOR[irw]
            rhoc2 = 1.0 - rho2
            @inbounds for i in 1:NRP1, j in 1:NAP1
                W[i,j,SOR_NEW] = W[i,j,ITER_START]
            end
            isor_w = 0
            continue
        end
        isor_w += 1
        # Copy new -> old
        @inbounds begin
            W[1,1,SOR_OLD] = W[1,1,SOR_NEW]
            for i in 2:NR, j in 1:NAP1
                W[i,j,SOR_OLD] = W[i,j,SOR_NEW]
            end
        end
        iconv = 0

        # W at origin
        @inbounds begin
            W[1,1,SOR_NEW] = rhoc2 * W[1,1,SOR_OLD] + rho2 * (
                E1 * W[2,1,SOR_OLD] + E2 * W[2,NAH,SOR_OLD] +
                E3 * W[2,NAP1,SOR_OLD] + E4)
            for j in 2:NAP1
                W[1,j,SOR_NEW] = W[1,1,SOR_NEW]
            end
        end
        if abs(W[1,1,SOR_OLD] - W[1,1,SOR_NEW]) > EPPS2
            iconv = 1
        end

        # alpha=0 boundary
        @inbounds for i in 2:NR
            W[i,1,SOR_NEW] = rhoc2 * W[i,1,SOR_OLD] + rho2 * (
                E[i,1,1] * W[i+1,1,SOR_OLD] +
                E[i,1,2] * 2.0 * W[i,2,SOR_OLD] +
                E[i,1,3] * W[i-1,1,SOR_NEW] +
                E[i,1,5])
            if abs(W[i,1,SOR_NEW] - W[i,1,SOR_OLD]) > EPPS2
                iconv = 1
            end
        end

        # Interior
        @inbounds for i in 2:NR, j in 2:NA
            W[i,j,SOR_NEW] = rhoc2 * W[i,j,SOR_OLD] + rho2 * (
                E[i,j,1] * W[i+1,j,SOR_OLD] +
                E[i,j,2] * W[i,j+1,SOR_OLD] +
                E[i,j,3] * W[i-1,j,SOR_NEW] +
                E[i,j,4] * W[i,j-1,SOR_NEW] +
                E[i,j,5])
            if !isfinite(W[i,j,SOR_NEW])
                iconv = 1
                isor_w = MAXSOR
                @goto w_done
            end
            if abs(W[i,j,SOR_OLD] - W[i,j,SOR_NEW]) > EPPS2
                iconv = 1
            end
        end

        # alpha=pi boundary
        @inbounds for i in 2:NR
            W[i,NAP1,SOR_NEW] = rhoc2 * W[i,NAP1,SOR_OLD] + rho2 * (
                E[i,NAP1,1] * W[i+1,NAP1,SOR_OLD] +
                E[i,NAP1,3] * W[i-1,NAP1,SOR_NEW] +
                2.0 * E[i,NAP1,4] * W[i,NA,SOR_NEW] +
                E[i,NAP1,5])
            if abs(W[i,NAP1,SOR_OLD] - W[i,NAP1,SOR_NEW]) > EPPS2
                iconv = 1
            end
        end

        if iconv == 0
            break
        end
    end
    @label w_done
    return (isor_w, iconv, rho2)
end

function sor_omega!(OMEGA::Array{Float64,3}, E::Array{Float64,3},
                    RHOC3::Float64, RHO3::Float64, EPPS3::Float64,
                    MAXSOR::Int, NR::Int, NA::Int, NRP1::Int, NAP1::Int)
    isor_omega = 0
    iconv = 0

    while true
        if isor_omega >= MAXSOR
            @printf("SOR FOR OMEGA FAILED WITH SOR FACTOR =%6.2f\n", RHO3)
            break
        end
        isor_omega += 1
        @inbounds for i in 2:NR, j in 2:NA
            OMEGA[i,j,SOR_OLD] = OMEGA[i,j,SOR_NEW]
        end
        iconv = 0
        @inbounds for i in 2:NR, j in 2:NA
            OMEGA[i,j,SOR_NEW] = RHOC3 * OMEGA[i,j,SOR_OLD] + RHO3 * (
                E[i,j,1] * OMEGA[i+1,j,SOR_OLD] +
                E[i,j,2] * OMEGA[i,j+1,SOR_OLD] +
                E[i,j,3] * OMEGA[i-1,j,SOR_NEW] +
                E[i,j,4] * OMEGA[i,j-1,SOR_NEW] +
                E[i,j,6])
            if !isfinite(OMEGA[i,j,SOR_NEW])
                iconv = 1
                isor_omega = MAXSOR
                @goto omega_done
            end
            if abs(OMEGA[i,j,SOR_OLD] - OMEGA[i,j,SOR_NEW]) > EPPS3
                iconv = 1
            end
        end
        if iconv == 0
            break
        end
    end
    @label omega_done
    return (isor_omega, iconv)
end

function smooth!(ARR::Array{Float64,3}, XI::Float64, XIC::Float64,
                 EPS::Float64, N1::Int, N2::Int)
    icv = 0
    @inbounds for i in 2:N1-1, j in 2:N2-1
        ARR[i,j,SOR_NEW] = XI*ARR[i,j,ITER_START] + XIC*ARR[i,j,SOR_NEW]
        if !isfinite(ARR[i,j,SOR_NEW])
            return 1
        end
        if abs(ARR[i,j,ITER_START] - ARR[i,j,SOR_NEW]) > XIC*EPS
            icv = 1
        end
    end
    return icv
end

# ============================================================================
# Output
# ============================================================================

function output_field(var::String, isor::Int, A::Array{Float64,3}, NR::Int, NA::Int)
    NRP1 = NR + 1
    NAP1 = NA + 1
    @printf("%6s     %5d  SOR ITERATIONS\n\n", var, isor)
    is_phi = (var == "PHI  " || var == "PHI")
    for i in 1:NRP1
        for j in 1:NAP1
            val = A[NRP1 - i + 1, NAP1 - j + 1, SOR_NEW]
            if j == 1
                if is_phi
                    @printf(" %6.2f", val)
                else
                    @printf(" %6.1f", val)
                end
            elseif j == NAP1
                if is_phi
                    @printf("%6.2f", val)
                else
                    @printf("%6.1f", val)
                end
            else
                if is_phi
                    @printf("%7.2f", val)
                else
                    @printf("%7.1f", val)
                end
            end
        end
        println()
    end
end

# ============================================================================
# Coefficient Setup
# ============================================================================

function setup_w_coefficients!(st::SolverState, g::GridParams, D::Float64)
    NR, NA, NRP1, NAP1, NAH = g.NR, g.NA, g.NRP1, g.NAP1, g.NAH
    DA, DRDA, DADR = g.DA, g.DRDA, g.DADR
    RINV, RINV2 = g.RINV, g.RINV2
    DDRDAM = D * g.DRDAM
    DDR2 = D * g.DR^2
    PHI = st.PHI
    E = st.E
    EE = st.EE
    EF = st.EF
    C0_CORR = st.C0_CORR

    # W at origin coefficients
    E0_val = 4.0 + abs(PHI[2, NAH, SOR_NEW])
    E1 = (1.0 - min(PHI[2, NAH, SOR_NEW], 0.0)) / E0_val
    E2 = 2.0 / E0_val
    E3 = (1.0 + max(PHI[2, NAH, SOR_NEW], 0.0)) / E0_val
    E4 = DDR2 / E0_val

    # alpha=0 and alpha=pi boundaries
    @inbounds for i in 2:NR
        DELTA1 = DA - PHI[i, 2, SOR_NEW]
        DELTA2 = DA + PHI[i, NA, SOR_NEW]
        EE[i] = 2.0 * (DADR + DRDA * RINV2[i])
        EE1 = EE[i] + RINV[i] * abs(DELTA1)
        EE2 = EE[i] + RINV[i] * abs(DELTA2)
        EF[i] = DRDA * RINV2[i]

        # alpha=0
        E[i,1,1] = (DADR + RINV[i] * max(DELTA1, 0.0)) / EE1
        E[i,1,2] = EF[i] / EE1
        E[i,1,3] = (DADR - RINV[i] * min(DELTA1, 0.0)) / EE1
        E[i,1,4] = E[i,1,2]
        E[i,1,5] = (DDRDAM + C0_CORR[i,1]) / EE1

        # alpha=pi
        E[i,NAP1,1] = (DADR + RINV[i] * max(DELTA2, 0.0)) / EE2
        E[i,NAP1,2] = EF[i] / EE2
        E[i,NAP1,3] = (DADR - RINV[i] * min(DELTA2, 0.0)) / EE2
        E[i,NAP1,4] = E[i,NAP1,2]
        E[i,NAP1,5] = (DDRDAM + C0_CORR[i,NAP1]) / EE2
    end

    # Interior
    @inbounds for i in 2:NR, j in 2:NA
        GAMMA = 0.5 * (PHI[i+1,j,SOR_NEW] - PHI[i-1,j,SOR_NEW])
        DELTA = DA - 0.5 * (PHI[i,j+1,SOR_NEW] - PHI[i,j-1,SOR_NEW])

        E[i,j,6] = EE[i] + RINV[i] * (abs(GAMMA) + abs(DELTA))
        E[i,j,1] = (DADR + RINV[i] * max(DELTA, 0.0)) / E[i,j,6]
        E[i,j,2] = (EF[i] + RINV[i] * max(GAMMA, 0.0)) / E[i,j,6]
        E[i,j,3] = (DADR - RINV[i] * min(DELTA, 0.0)) / E[i,j,6]
        E[i,j,4] = (EF[i] - RINV[i] * min(GAMMA, 0.0)) / E[i,j,6]
        E[i,j,5] = (DDRDAM + C0_CORR[i,j]) / E[i,j,6]
    end

    return (E1, E2, E3, E4)
end

function compute_omega_source!(st::SolverState, g::GridParams)
    NR, NA = g.NR, g.NA
    SA, CA = g.SA, g.CA
    W = st.W
    E = st.E
    E0_CORR = st.E0_CORR

    @inbounds for i in 2:NR, j in 2:NA
        OMEGA_RHS = -W[i,j,SOR_NEW] * (
            SA[j] * (W[i+1,j,SOR_NEW] - W[i-1,j,SOR_NEW]) +
            CA[i,j] * (W[i,j+1,SOR_NEW] - W[i,j-1,SOR_NEW]))
        E[i,j,6] = (OMEGA_RHS + E0_CORR[i,j]) / E[i,j,6]
    end
end

# ============================================================================
# Anderson Acceleration
# ============================================================================

function solve_small!(A::Matrix{Float64}, b::Vector{Float64},
                      x::Vector{Float64}, n::Int)
    ok = true
    x[1:n] .= 0.0

    for k in 1:n-1
        p = k
        piv = abs(A[k,k])
        for i in k+1:n
            if abs(A[i,k]) > piv
                piv = abs(A[i,k])
                p = i
            end
        end
        if piv <= 0.0
            return false
        end
        if p != k
            for j in k:n
                A[k,j], A[p,j] = A[p,j], A[k,j]
            end
            b[k], b[p] = b[p], b[k]
        end
        for i in k+1:n
            tmp = A[i,k] / A[k,k]
            A[i,k] = 0.0
            for j in k+1:n
                A[i,j] -= tmp * A[k,j]
            end
            b[i] -= tmp * b[k]
        end
    end

    if abs(A[n,n]) <= 0.0
        return false
    end

    for i in n:-1:1
        tmp = b[i]
        for j in i+1:n
            tmp -= A[i,j] * x[j]
        end
        x[i] = tmp / A[i,i]
    end
    return true
end

function anderson_update!(st::SolverState, aa::AndersonState, g::GridParams,
                          sp::SORParams, EPS_OUT::Vector{Float64})
    NR, NA, NRP1, NAP1 = g.NR, g.NA, g.NRP1, g.NAP1
    PHI, W, OMEGA = st.PHI, st.W, st.OMEGA

    # Scaling weights
    S_PHI = 1.0 / max(1.0, maximum(abs, @view PHI[2:NR, 2:NA, SOR_NEW]))
    S_W   = 1.0 / max(1.0, maximum(abs, @view W[2:NR, 2:NA, SOR_NEW]))
    S_OMG = 1.0 / max(1.0, maximum(abs, @view OMEGA[2:NR, 2:NA, SOR_NEW]))

    # Push into history, shift if full
    if aa.AA_NHIST >= AA_MMAX + 1
        for k in 1:AA_MMAX
            @views aa.PHI_GH[:,:,k] .= aa.PHI_GH[:,:,k+1]
            @views aa.W_GH[:,:,k] .= aa.W_GH[:,:,k+1]
            @views aa.OMEGA_GH[:,:,k] .= aa.OMEGA_GH[:,:,k+1]
            @views aa.PHI_FH[:,:,k] .= aa.PHI_FH[:,:,k+1]
            @views aa.W_FH[:,:,k] .= aa.W_FH[:,:,k+1]
            @views aa.OMEGA_FH[:,:,k] .= aa.OMEGA_FH[:,:,k+1]
        end
        aa.AA_NHIST = AA_MMAX
    end
    aa.AA_NHIST += 1
    idx = aa.AA_NHIST

    @views aa.PHI_GH[:,:,idx] .= PHI[:,:,SOR_NEW]
    @views aa.W_GH[:,:,idx] .= W[:,:,SOR_NEW]
    @views aa.OMEGA_GH[:,:,idx] .= OMEGA[:,:,SOR_NEW]

    @views @. aa.PHI_FH[:,:,idx] = PHI[:,:,SOR_NEW] - PHI[:,:,ITER_START]
    @views @. aa.W_FH[:,:,idx] = W[:,:,SOR_NEW] - W[:,:,ITER_START]
    @views @. aa.OMEGA_FH[:,:,idx] = OMEGA[:,:,SOR_NEW] - OMEGA[:,:,ITER_START]

    if aa.AA_NHIST < 2
        return -2  # not enough history, don't change ICV
    end

    p = min(aa.AA_NHIST, sp.AA_DEPTH + 1)
    idx0 = aa.AA_NHIST - p + 1

    # Build Gram matrix
    for ab in 1:p, a in 1:p
        dot = 0.0
        @inbounds for ii in 2:NR, jj in 2:NA
            dot += (S_PHI * aa.PHI_FH[ii,jj,idx0+a-1]) * (S_PHI * aa.PHI_FH[ii,jj,idx0+ab-1]) +
                   (S_W * aa.W_FH[ii,jj,idx0+a-1]) * (S_W * aa.W_FH[ii,jj,idx0+ab-1]) +
                   (S_OMG * aa.OMEGA_FH[ii,jj,idx0+a-1]) * (S_OMG * aa.OMEGA_FH[ii,jj,idx0+ab-1])
        end
        aa.AA_MAT[a,ab] = dot
    end

    # Regularize
    diagmax = 0.0
    for a in 1:p
        diagmax = max(diagmax, aa.AA_MAT[a,a])
    end
    reg = sp.AA_REG * max(1.0, diagmax)
    for a in 1:p
        aa.AA_MAT[a,a] += reg
    end

    # Augmented system
    for a in 1:p
        aa.AA_MAT[a,p+1] = 1.0
        aa.AA_MAT[p+1,a] = 1.0
        aa.AA_RHS[a] = 0.0
    end
    aa.AA_MAT[p+1,p+1] = 0.0
    aa.AA_RHS[p+1] = 1.0

    ok = solve_small!(aa.AA_MAT, aa.AA_RHS, aa.AA_SOL, p + 1)
    if !ok
        aa.AA_NHIST = 1
        return -1  # signal no update
    end

    for a in 1:p
        aa.AA_ALPHA[a] = aa.AA_SOL[a]
    end

    # Safeguard
    if maximum(abs, @view aa.AA_ALPHA[1:p]) > 10.0
        aa.AA_NHIST = 1
        return -1
    end

    # Form accelerated iterate
    PHI[:,:,SOR_NEW] .= 0.0
    W[:,:,SOR_NEW] .= 0.0
    OMEGA[:,:,SOR_NEW] .= 0.0
    for a in 1:p
        alpha = aa.AA_ALPHA[a]
        @views @. PHI[:,:,SOR_NEW] += alpha * aa.PHI_GH[:,:,idx0+a-1]
        @views @. W[:,:,SOR_NEW] += alpha * aa.W_GH[:,:,idx0+a-1]
        @views @. OMEGA[:,:,SOR_NEW] += alpha * aa.OMEGA_GH[:,:,idx0+a-1]
    end

    # Damping toward newest g(x)
    beta = sp.AA_BETA
    if beta < 1.0
        @views @. PHI[:,:,SOR_NEW] = (1.0 - beta) * aa.PHI_GH[:,:,aa.AA_NHIST] + beta * PHI[:,:,SOR_NEW]
        @views @. W[:,:,SOR_NEW] = (1.0 - beta) * aa.W_GH[:,:,aa.AA_NHIST] + beta * W[:,:,SOR_NEW]
        @views @. OMEGA[:,:,SOR_NEW] = (1.0 - beta) * aa.OMEGA_GH[:,:,aa.AA_NHIST] + beta * OMEGA[:,:,SOR_NEW]
    end

    # Enforce hard BCs
    PHI[1, 1:NAP1, SOR_NEW] .= 0.0
    PHI[NRP1, 1:NAP1, SOR_NEW] .= 0.0
    PHI[1:NRP1, 1, SOR_NEW] .= 0.0
    PHI[1:NRP1, NAP1, SOR_NEW] .= 0.0

    OMEGA[1, 1:NAP1, SOR_NEW] .= 0.0
    OMEGA[1:NRP1, 1, SOR_NEW] .= 0.0
    OMEGA[1:NRP1, NAP1, SOR_NEW] .= 0.0

    W[NRP1, 1:NAP1, SOR_NEW] .= 0.0

    # Update convergence
    icv = 0
    if maximum(abs, @views PHI[2:NR, 2:NA, ITER_START] .- PHI[2:NR, 2:NA, SOR_NEW]) > EPS_OUT[1]
        icv = 1
    end
    if maximum(abs, @views W[1:NR, 1:NAP1, ITER_START] .- W[1:NR, 1:NAP1, SOR_NEW]) > EPS_OUT[2]
        icv = 1
    end
    if maximum(abs, @views OMEGA[2:NRP1, 2:NA, ITER_START] .- OMEGA[2:NRP1, 2:NA, SOR_NEW]) > EPS_OUT[3]
        icv = 1
    end
    return icv
end

# ============================================================================
# Fox Correction Computation
# ============================================================================

function compute_fox_corrections!(st::SolverState, g::GridParams, OMEGA1::Float64,
                                  corr_iter::Int)
    NR, NA, NAP1 = g.NR, g.NA, g.NAP1
    DA = g.DA
    RINV = g.RINV
    PHI, W, OMEGA = st.PHI, st.W, st.OMEGA

    st.C0_CORR_NEW .= 0.0
    st.E0_CORR_NEW .= 0.0

    @inbounds for i in 2:NR
        # alpha=0 boundary
        DELTA1 = DA - PHI[i, 2, SOR_NEW]
        st.C0_CORR_NEW[i,1] = -0.5 * RINV[i] * abs(DELTA1) *
            (W[i+1,1,SOR_NEW] + W[i-1,1,SOR_NEW] - 2.0 * W[i,1,SOR_NEW])

        # Interior
        for j in 2:NA
            GAMMA = 0.5 * (PHI[i+1,j,SOR_NEW] - PHI[i-1,j,SOR_NEW])
            DELTA = DA - 0.5 * (PHI[i,j+1,SOR_NEW] - PHI[i,j-1,SOR_NEW])

            st.C0_CORR_NEW[i,j] = -0.5 * RINV[i] * (
                abs(DELTA) * (W[i+1,j,SOR_NEW] + W[i-1,j,SOR_NEW] - 2.0*W[i,j,SOR_NEW]) +
                abs(GAMMA) * (W[i,j+1,SOR_NEW] + W[i,j-1,SOR_NEW] - 2.0*W[i,j,SOR_NEW]))

            st.E0_CORR_NEW[i,j] = -0.5 * RINV[i] * (
                abs(DELTA) * (OMEGA[i+1,j,SOR_NEW] + OMEGA[i-1,j,SOR_NEW] - 2.0*OMEGA[i,j,SOR_NEW]) +
                abs(GAMMA) * (OMEGA[i,j+1,SOR_NEW] + OMEGA[i,j-1,SOR_NEW] - 2.0*OMEGA[i,j,SOR_NEW]))
        end

        # alpha=pi boundary
        DELTA2 = DA + PHI[i, NA, SOR_NEW]
        st.C0_CORR_NEW[i,NAP1] = -0.5 * RINV[i] * abs(DELTA2) *
            (W[i+1,NAP1,SOR_NEW] + W[i-1,NAP1,SOR_NEW] - 2.0 * W[i,NAP1,SOR_NEW])
    end

    # 2-cycle averaging + smoothing
    corr_max_c0 = 0.0
    corr_max_e0 = 0.0
    corr_res_c0 = 0.0
    corr_res_e0 = 0.0

    @inbounds for i in 2:NR
        for j in 1:NAP1
            corr_new_raw = st.C0_CORR_NEW[i,j]
            if corr_iter > 0
                st.C0_CORR_NEW[i,j] = 0.5 * (st.C0_CORR_NEW[i,j] + st.C0_CORR_NEW_PREV[i,j])
            end
            st.C0_CORR_NEW_PREV[i,j] = corr_new_raw
            corr_res_c0 = max(corr_res_c0, abs(st.C0_CORR_NEW[i,j] - st.C0_CORR[i,j]))
            corr_old = st.C0_CORR[i,j]
            st.C0_CORR[i,j] = OMEGA1 * st.C0_CORR_NEW[i,j] + (1.0 - OMEGA1) * st.C0_CORR[i,j]
            corr_max_c0 = max(corr_max_c0, abs(st.C0_CORR[i,j] - corr_old))
        end
        for j in 2:NA
            corr_new_raw = st.E0_CORR_NEW[i,j]
            if corr_iter > 0
                st.E0_CORR_NEW[i,j] = 0.5 * (st.E0_CORR_NEW[i,j] + st.E0_CORR_NEW_PREV[i,j])
            end
            st.E0_CORR_NEW_PREV[i,j] = corr_new_raw
            corr_res_e0 = max(corr_res_e0, abs(st.E0_CORR_NEW[i,j] - st.E0_CORR[i,j]))
            corr_old = st.E0_CORR[i,j]
            st.E0_CORR[i,j] = OMEGA1 * st.E0_CORR_NEW[i,j] + (1.0 - OMEGA1) * st.E0_CORR[i,j]
            corr_max_e0 = max(corr_max_e0, abs(st.E0_CORR[i,j] - corr_old))
        end
    end

    return (corr_max_c0, corr_max_e0, corr_res_c0, corr_res_e0)
end

# ============================================================================
# Central Residuals Check
# ============================================================================

function check_central_residuals(st::SolverState, g::GridParams, D::Float64)
    NR, NA = g.NR, g.NA
    DADR, DRDA, DRDAM = g.DADR, g.DRDA, g.DRDAM
    RINV, RINV2 = g.RINV, g.RINV2
    DA = g.DA
    SA, CA = g.SA, g.CA
    PHI, W, OMEGA = st.PHI, st.W, st.OMEGA
    DDRDAM = D * DRDAM

    maxr_phi = 0.0
    maxr_w = 0.0
    maxr_omg = 0.0

    @inbounds for ii in 2:NR, jj in 2:NA
        # PHI residual
        L = DADR*(PHI[ii+1,jj,SOR_NEW] + PHI[ii-1,jj,SOR_NEW] - 2.0*PHI[ii,jj,SOR_NEW]) +
            DRDA*RINV2[ii]*(PHI[ii,jj+1,SOR_NEW] + PHI[ii,jj-1,SOR_NEW] - 2.0*PHI[ii,jj,SOR_NEW]) +
            0.5*DA*RINV[ii]*(PHI[ii+1,jj,SOR_NEW] - PHI[ii-1,jj,SOR_NEW])
        rphi = L + DRDAM*OMEGA[ii,jj,SOR_NEW]
        maxr_phi = max(maxr_phi, abs(rphi))

        # DELTA/GAMMA
        LDELTA = DA - 0.5*(PHI[ii,jj+1,SOR_NEW] - PHI[ii,jj-1,SOR_NEW])
        LGAMMA = 0.5*(PHI[ii+1,jj,SOR_NEW] - PHI[ii-1,jj,SOR_NEW])

        # W residual
        L = DADR*(W[ii+1,jj,SOR_NEW] + W[ii-1,jj,SOR_NEW] - 2.0*W[ii,jj,SOR_NEW]) +
            DRDA*RINV2[ii]*(W[ii,jj+1,SOR_NEW] + W[ii,jj-1,SOR_NEW] - 2.0*W[ii,jj,SOR_NEW]) +
            0.5*RINV[ii]*LDELTA*(W[ii+1,jj,SOR_NEW] - W[ii-1,jj,SOR_NEW]) +
            0.5*RINV[ii]*LGAMMA*(W[ii,jj+1,SOR_NEW] - W[ii,jj-1,SOR_NEW])
        rw = L + DDRDAM
        maxr_w = max(maxr_w, abs(rw))

        # OMEGA residual
        LOMEGA_RHS = -W[ii,jj,SOR_NEW] * (SA[jj] * (W[ii+1,jj,SOR_NEW] - W[ii-1,jj,SOR_NEW]) +
            CA[ii,jj] * (W[ii,jj+1,SOR_NEW] - W[ii,jj-1,SOR_NEW]))
        L = DADR*(OMEGA[ii+1,jj,SOR_NEW] + OMEGA[ii-1,jj,SOR_NEW] - 2.0*OMEGA[ii,jj,SOR_NEW]) +
            DRDA*RINV2[ii]*(OMEGA[ii,jj+1,SOR_NEW] + OMEGA[ii,jj-1,SOR_NEW] - 2.0*OMEGA[ii,jj,SOR_NEW]) +
            0.5*RINV[ii]*LDELTA*(OMEGA[ii+1,jj,SOR_NEW] - OMEGA[ii-1,jj,SOR_NEW]) +
            0.5*RINV[ii]*LGAMMA*(OMEGA[ii,jj+1,SOR_NEW] - OMEGA[ii,jj-1,SOR_NEW])
        romg = L + LOMEGA_RHS
        maxr_omg = max(maxr_omg, abs(romg))
    end
    return (maxr_phi, maxr_w, maxr_omg)
end

# ============================================================================
# Solve Case
# ============================================================================

function solve_case!(st::SolverState, aa_st::AndersonState, g::GridParams,
                     sp::SORParams, cc::CaseConfig, ctr::Int)
    NR, NA, NRP1, NAP1, NRM1, NAH = g.NR, g.NA, g.NRP1, g.NAP1, g.NRM1, g.NAH
    D_TARGET = cc.D
    EPS = copy(cc.EPS)
    EPS_OUT = copy(cc.EPS_OUT)
    RHO = copy(cc.RHO)
    XI = copy(cc.XI)
    OMEGA1 = cc.OMEGA1
    AA_ON = cc.AA_ON
    PHI, W, OMEGA = st.PHI, st.W, st.OMEGA

    XIC = [1.0 - XI[k] for k in 1:4]
    RHOC = [1.0 - RHO[k] for k in 1:3]
    EPPS = [0.05 * EPS[k] for k in 1:3]

    @printf("\n\n============================================\n")
    @printf("  CASE %2d: D =%9.2f\n", ctr, D_TARGET)
    @printf("============================================\n")
    @printf("             PHI       W     OMEGA\n")
    @printf("     RHO =%6.2f   %6.2f   %6.2f\n", RHO[1], RHO[2], RHO[3])
    @printf("      XI =%6.4f   %6.4f   %6.4f   %6.4f\n", XI[1], XI[2], XI[3], XI[4])
    @printf("     EPS =%6.4f   %6.4f   %6.4f\n", EPS[1], EPS[2], EPS[3])
    @printf("  Scheme: UPWIND + FOX CORRECTION (omega1 =%6.3f)\n", OMEGA1)

    # D-stepping setup
    if D_TARGET > 1000.0 && ctr > 1
        stepping = true
        D_CURRENT = st.DSTART
    else
        stepping = false
        D_CURRENT = D_TARGET
    end

    D = D_CURRENT
    DDRDAM = D * g.DRDAM
    DDR2 = D * g.DR^2
    CON = 4.0 / (g.PI * D)
    st.CO[1] = 16.0 * g.DELA[1] / (3.0 * g.PI * D)
    for i in 2:NR
        st.CO[i] = CON * g.DELA[i]
    end

    # Fox correction initial values
    if stepping
        st.C0_CORR .= 0.0
        st.E0_CORR .= 0.0
    else
        st.C0_CORR .= st.C0_SAVE
        st.E0_CORR .= st.E0_SAVE
    end

    # Initial guess
    @views PHI[:,:,SOR_NEW] .= PHI[:,:,CARRY]
    @views W[:,:,SOR_NEW] .= W[:,:,CARRY]
    @views OMEGA[:,:,SOR_NEW] .= OMEGA[:,:,CARRY]
    if ctr > 1
        @printf("  Initial guess from D =%9.2f\n", st.DSTART)
    else
        @printf("  Initial guess: zero\n")
    end

    # Correction loop
    corr_iter = 0
    corr_converged = false
    failed = false
    phi_max_prev = 0.0
    w_max_prev = 0.0
    st.C0_CORR_NEW_PREV .= 0.0
    st.E0_CORR_NEW_PREV .= 0.0
    corr_res_c0_init = 0.0
    corr_res_e0_init = 0.0

    while true  # CORRECTION_LOOP

        # Save state for collapse detection
        st.PHI_PREV .= @view PHI[:,:,SOR_NEW]
        st.W_PREV .= @view W[:,:,SOR_NEW]
        st.OMEGA_PREV .= @view OMEGA[:,:,SOR_NEW]
        st.C0_CORR_SAVE_PREV .= st.C0_CORR
        st.E0_CORR_SAVE_PREV .= st.E0_CORR

        # Reset SOR parameters
        RHO .= cc.RHO
        for k in 1:3
            RHOC[k] = 1.0 - RHO[k]
        end

        iout = 0
        step_count = 0
        aa_st.AA_NHIST = 0

        # OUTER_ITER
        outer_failed = false
        while true
            if iout >= sp.MAXOUT
                println("OUTER ITERATION FAILED TO CONVERGE.")
                failed = true
                break
            end

            iout += 1
            if !stepping && iout <= 1 && corr_iter == 0
                @printf("\n\nOUTER ITERATION%5d\n\n", iout)
            end

            icv = 0

            @views PHI[:,:,ITER_START] .= PHI[:,:,SOR_NEW]
            @views W[:,:,ITER_START] .= W[:,:,SOR_NEW]
            @views OMEGA[:,:,ITER_START] .= OMEGA[:,:,SOR_NEW]

            # ===== W -> Omega -> PHI =====

            # W coefficient setup
            (E1, E2, E3, E4) = setup_w_coefficients!(st, g, D)

            # SOR for W
            (isor_w, w_iconv, rho2_final) = sor_w!(W, st.E, EPPS[2], RHOC[2], RHO[2],
                sp.MAXSOR, NR, NA, NRP1, NAP1, NAH, E1, E2, E3, E4, sp.DOR, sp.NOR)
            RHO[2] = rho2_final

            # Smoothing for W at origin
            W[1,1,SOR_NEW] = XI[2] * W[1,1,ITER_START] + XIC[2] * W[1,1,SOR_NEW]
            for j in 2:NAP1
                W[1,j,SOR_NEW] = W[1,1,SOR_NEW]
            end
            if abs(W[1,1,ITER_START] - W[1,1,SOR_NEW]) > XIC[2]*EPS[2]
                icv = 1
            end

            icv_s = smooth!(W, XI[2], XIC[2], EPS[2], NRP1, NAP1)
            if icv_s == 1; icv = 1; end

            if !stepping && iout <= 1 && corr_iter == 0
                output_field("W    ", isor_w, W, NR, NA)
            end

            # Omega wall BC
            @inbounds for j in 2:NA
                OMEGA[NRP1,j,SOR_NEW] = XI[3] * OMEGA[NRP1,j,ITER_START] -
                    XIC[3] * 2.0 * g.RINV2[2] * PHI[NR,j,SOR_NEW]
                if abs(OMEGA[NRP1,j,ITER_START] - OMEGA[NRP1,j,SOR_NEW]) > XIC[3]*EPS[3]
                    icv = 1
                end
            end

            # Omega source
            compute_omega_source!(st, g)

            # Propagate boundary values to SOR old
            @views OMEGA[NRP1, 1:NAP1, SOR_OLD] .= OMEGA[NRP1, 1:NAP1, SOR_NEW]
            @views OMEGA[1, 1:NAP1, SOR_OLD] .= OMEGA[1, 1:NAP1, SOR_NEW]
            @views OMEGA[1:NRP1, 1, SOR_OLD] .= OMEGA[1:NRP1, 1, SOR_NEW]
            @views OMEGA[1:NRP1, NAP1, SOR_OLD] .= OMEGA[1:NRP1, NAP1, SOR_NEW]

            # SOR for Omega with retry
            iro = 0
            isor_omega = 0
            while true
                (isor_omega, om_iconv) = sor_omega!(OMEGA, st.E, RHOC[3], RHO[3], EPPS[3],
                    sp.MAXSOR, NR, NA, NRP1, NAP1)
                if om_iconv == 0
                    break
                end
                if isor_omega >= sp.MAXSOR
                    @printf("SOR FOR OMEGA FAILED WITH SOR FACTOR =%6.2f\n", RHO[3])
                    if iro >= sp.NOR
                        break
                    end
                    iro += 1
                    RHO[3] -= sp.DOR[iro]
                    RHOC[3] = 1.0 - RHO[3]
                    @inbounds for i in 1:NRP1, j in 1:NAP1
                        OMEGA[i,j,SOR_NEW] = OMEGA[i,j,ITER_START]
                    end
                else
                    break
                end
            end

            icv_s = smooth!(OMEGA, XI[4], XIC[4], EPS[3], NRP1, NAP1)
            if icv_s == 1; icv = 1; end

            if !stepping && iout <= 1 && corr_iter == 0
                output_field("OMEGA", isor_omega, OMEGA, NR, NA)
            end

            # PHI boundary values
            PHI[1, 1:NAP1, SOR_OLD] .= 0.0
            PHI[NRP1, 1:NAP1, SOR_OLD] .= 0.0
            PHI[1:NRP1, 1, SOR_OLD] .= 0.0
            PHI[1:NRP1, NAP1, SOR_OLD] .= 0.0
            PHI[1, 1:NAP1, SOR_NEW] .= 0.0
            PHI[NRP1, 1:NAP1, SOR_NEW] .= 0.0
            PHI[1:NRP1, 1, SOR_NEW] .= 0.0
            PHI[1:NRP1, NAP1, SOR_NEW] .= 0.0

            # PHI source
            @inbounds for i in 2:NR, j in 2:NA
                st.C[i,j] = g.B[i,5] * OMEGA[i,j,SOR_NEW]
            end

            isor_phi = sor_phi!(PHI, OMEGA, g.B, st.C, RHOC[1], RHO[1], EPPS[1],
                sp.MAXSOR, NR, NA, NRP1, NAP1, NRM1)

            icv_s = smooth!(PHI, XI[1], XIC[1], EPS[1], NRP1, NAP1)
            if icv_s == 1; icv = 1; end

            if !stepping && iout <= 1 && corr_iter == 0
                output_field("PHI  ", isor_phi, PHI, NR, NA)
                @printf("  DIAG: maxPHI=%10.3e maxW=%10.3e maxOMG=%10.3e RES_WALL=%10.3e\n",
                    maximum(abs, @view PHI[2:NR, 2:NA, SOR_NEW]),
                    maximum(abs, @view W[2:NR, 2:NA, SOR_NEW]),
                    maximum(abs, @view OMEGA[2:NR, 2:NA, SOR_NEW]),
                    maximum(j -> abs(OMEGA[NRP1,j,SOR_NEW] + 2.0*g.RINV2[2]*PHI[NR,j,SOR_NEW]), 2:NA))
            end

            # 2-cycle averaging
            use_avg = (NR >= 40 && D_TARGET >= 250.0) || (NR < 40 && D_TARGET >= 2000.0)
            if use_avg && iout > 1
                @views @. PHI[2:NR, 2:NA, SOR_NEW] = 0.5*(PHI[2:NR, 2:NA, ITER_START] + PHI[2:NR, 2:NA, SOR_NEW])
                @views @. W[1:NR, 1:NAP1, SOR_NEW] = 0.5*(W[1:NR, 1:NAP1, ITER_START] + W[1:NR, 1:NAP1, SOR_NEW])
                @views @. OMEGA[2:NR, 2:NA, SOR_NEW] = 0.5*(OMEGA[2:NR, 2:NA, ITER_START] + OMEGA[2:NR, 2:NA, SOR_NEW])
                @views @. OMEGA[NRP1, 2:NA, SOR_NEW] = 0.5*(OMEGA[NRP1, 2:NA, ITER_START] + OMEGA[NRP1, 2:NA, SOR_NEW])

                icv = 0
                if maximum(abs, @views PHI[2:NR, 2:NA, ITER_START] .- PHI[2:NR, 2:NA, SOR_NEW]) > EPS_OUT[1]
                    icv = 1
                end
                if maximum(abs, @views W[1:NR, 1:NAP1, ITER_START] .- W[1:NR, 1:NAP1, SOR_NEW]) > EPS_OUT[2]
                    icv = 1
                end
                if maximum(abs, @views OMEGA[2:NRP1, 2:NA, ITER_START] .- OMEGA[2:NRP1, 2:NA, SOR_NEW]) > EPS_OUT[3]
                    icv = 1
                end
            end

            # D-stepping check
            if stepping
                step_count += 1
                if step_count % sp.STEP_ITERS == 0
                    D_STEP = NR >= 40 ? 5.0 : 10.0
                    D_CURRENT = min(D_CURRENT + D_STEP, D_TARGET)
                    D = D_CURRENT
                    DDRDAM = D * g.DRDAM
                    DDR2 = D * g.DR^2
                    @printf("  D-step: D=%7.1f maxPHI=%9.2e maxW=%9.2e maxOMG=%9.2e\n",
                        D_CURRENT,
                        maximum(abs, @view PHI[2:NR, 2:NA, SOR_NEW]),
                        maximum(abs, @view W[2:NR, 2:NA, SOR_NEW]),
                        maximum(abs, @view OMEGA[2:NR, 2:NA, SOR_NEW]))
                    if D_CURRENT >= D_TARGET
                        stepping = false
                        iout = 0
                        @printf("  D-stepping complete, now converging at D =%9.2f\n", D)
                    end
                end
                icv = 1
                continue  # CYCLE OUTER_ITER
            end

            # Anderson acceleration
            if AA_ON
                aa_icv = anderson_update!(st, aa_st, g, sp, EPS_OUT)
                if aa_icv == -1
                    # Anderson restart, keep iterating (don't change icv)
                elseif aa_icv >= 0
                    icv = aa_icv  # Anderson updated fields and recomputed convergence
                end
                # aa_icv == -2: not enough history, don't change icv
            end

            # Convergence check
            if icv == 0
                break
            end
        end  # OUTER_ITER

        if !failed
            println("OUTER ITERATION CONVERGED TO GIVEN TOLERANCES.")
        end

        # Collapse detection
        W_CUR_MAX = maximum(abs, @view W[2:NR, 2:NA, SOR_NEW])
        s = sum(abs, @view W[:,:,SOR_NEW])
        if s != s  # NaN check
            W_CUR_MAX = -1.0
        end
        w_prev_max = maximum(abs, @view st.W_PREV[2:NR, 2:NA])
        if corr_iter > 0 && w_prev_max > 100.0 &&
           (W_CUR_MAX < 0.0 || W_CUR_MAX != W_CUR_MAX ||
            W_CUR_MAX < 0.5 * w_prev_max)
            @printf("  COLLAPSE DETECTED at correction iter%4d: w_M dropped from%10.2f to%10.2f\n",
                corr_iter, w_prev_max, maximum(abs, @view W[2:NR, 2:NA, SOR_NEW]))
            @views PHI[:,:,SOR_NEW] .= st.PHI_PREV
            @views W[:,:,SOR_NEW] .= st.W_PREV
            @views OMEGA[:,:,SOR_NEW] .= st.OMEGA_PREV
            st.C0_CORR .= st.C0_CORR_SAVE_PREV
            st.E0_CORR .= st.E0_CORR_SAVE_PREV
            println("  Stopping corrections at last good state.")
            corr_converged = true
            break  # EXIT CORRECTION_LOOP
        end

        # Save uncorrected solution
        if corr_iter == 0
            st.PHI_UNCORR .= @view PHI[:,:,SOR_NEW]
            st.W_UNCORR .= @view W[:,:,SOR_NEW]
            st.OMEGA_UNCORR .= @view OMEGA[:,:,SOR_NEW]
        end

        if failed || corr_converged || corr_iter >= sp.MAX_CORR
            break
        end

        # Compute Fox corrections
        (corr_max_c0, corr_max_e0, corr_res_c0, corr_res_e0) =
            compute_fox_corrections!(st, g, OMEGA1, corr_iter)

        corr_iter += 1
        aa_st.AA_NHIST = 0  # reset Anderson history

        if corr_iter == 1
            corr_res_c0_init = corr_res_c0
            corr_res_e0_init = corr_res_e0
        end

        @printf("  Correction iter%4d: res C0=%10.3e, res E0=%10.3e (damped dC0=%10.3e, dE0=%10.3e)\n",
            corr_iter, corr_res_c0, corr_res_e0, corr_max_c0, corr_max_e0)

        # Report intermediate results
        phi_max = maximum(abs, @view PHI[:,:,SOR_NEW])
        w_max = maximum(abs, @view W[:,:,SOR_NEW])
        @printf("    phi_M =%10.4f  w_M =%10.2f\n", phi_max, w_max)

        # Central residuals
        (maxr_phi, maxr_w, maxr_omg) = check_central_residuals(st, g, D)
        @printf("    Central residuals: PHI=%10.3e  W=%10.3e  OMG=%10.3e\n",
            maxr_phi, maxr_w, maxr_omg)

        # Correction convergence check
        if corr_res_c0 < sp.CORR_TOL && corr_res_e0 < sp.CORR_TOL
            @printf("  Corrections converged (residual) after%4d iterations.\n", corr_iter)
            corr_converged = true
            break
        end
        # Physical convergence
        if corr_iter >= 3 && corr_res_c0_init > 0.0 &&
           corr_res_c0 < 0.02 * corr_res_c0_init &&
           corr_res_e0 < 0.02 * corr_res_e0_init &&
           w_max > 1.0 && phi_max > 1.0e-3 &&
           abs(w_max - w_max_prev) < 1.0e-3 * w_max &&
           abs(phi_max - phi_max_prev) < 1.0e-3 * phi_max
            @printf("  Corrections converged (physical) after%4d iters. Res C0=%9.2e E0=%9.2e\n",
                corr_iter, corr_res_c0, corr_res_e0)
            corr_converged = true
            break
        end
        phi_max_prev = phi_max
        w_max_prev = w_max

        stepping = false
    end  # CORRECTION_LOOP

    # Compute and report results
    D = D_TARGET
    CON = 4.0 / (g.PI * D)
    st.CO[1] = 16.0 * g.DELA[1] / (3.0 * g.PI * D)
    for i in 2:NR
        st.CO[i] = CON * g.DELA[i]
    end

    QR = 0.0
    for j in 1:NA
        QR += W[1,j,SOR_NEW] + W[2,j,SOR_NEW] + W[2,j+1,SOR_NEW]
    end
    QR *= st.CO[1]
    for i in 2:NR
        s = 0.0
        for j in 1:NA
            s += W[i,j,SOR_NEW] + W[i+1,j,SOR_NEW] + W[i,j+1,SOR_NEW] + W[i+1,j+1,SOR_NEW]
        end
        QR += st.CO[i] * s
    end

    @printf("FLUX RATIO =%10.5f\n", QR)

    phi_max = maximum(abs, @view PHI[:,:,SOR_NEW])
    w_max = maximum(abs, @view W[:,:,SOR_NEW])
    @printf("PHI_M =%12.4f  W_M =%12.2f  QR =%10.5f\n", phi_max, w_max, QR)

    # Output to file
    file_name = @sprintf("cd_file_D%.2f.dat", D_TARGET)
    @printf("  Output file: %s\n", file_name)
    open(file_name, "w") do io
        println(io, " ", NRP1)
        println(io, " ", NAP1)
        println(io, " ", join(XI, "  "))
        println(io, " ", join(RHO, "  "))
        println(io, " ", join(EPS, "  "))
        println(io, " ", D_TARGET)
        println(io, " ", QR)
        for i in 1:NRP1
            println(io, " ", join([@sprintf("%.15E", PHI[i,j,SOR_NEW]) for j in 1:NAP1], "  "))
        end
        for i in 1:NRP1
            println(io, " ", join([@sprintf("%.15E", W[i,j,SOR_NEW]) for j in 1:NAP1], "  "))
        end
        for i in 1:NRP1
            println(io, " ", join([@sprintf("%.15E", OMEGA[i,j,SOR_NEW]) for j in 1:NAP1], "  "))
        end
    end

    # Save solution for next case
    if D_TARGET > 1000.0
        @views PHI[:,:,CARRY] .= st.PHI_UNCORR
        @views W[:,:,CARRY] .= st.W_UNCORR
        @views OMEGA[:,:,CARRY] .= st.OMEGA_UNCORR
    else
        @views PHI[:,:,CARRY] .= PHI[:,:,SOR_NEW]
        @views W[:,:,CARRY] .= W[:,:,SOR_NEW]
        @views OMEGA[:,:,CARRY] .= OMEGA[:,:,SOR_NEW]
    end
    st.C0_SAVE .= st.C0_CORR
    st.E0_SAVE .= st.E0_CORR
    st.DSTART = D_TARGET

    @printf("  Done with case D =%9.2f\n", D_TARGET)
end

# ============================================================================
# Main
# ============================================================================

function main(; NR::Int=20, NA::Int=36)
    t_start = time()

    g = build_grid(NR, NA)
    cases = build_cases(g)
    sp = build_sor_params(NR)
    st = build_state(g)
    aa_st = build_anderson(g)

    for (ctr, cc) in enumerate(cases)
        solve_case!(st, aa_st, g, sp, cc, ctr)
    end

    elapsed = time() - t_start
    @printf("Elapsed time:%8.1f seconds\n", elapsed)
end

# CLI entry point
if abspath(PROGRAM_FILE) == @__FILE__
    grid = "b"
    if length(ARGS) >= 1
        grid = lowercase(ARGS[1])
    end
    if grid == "c"
        main(NR=40, NA=72)
    else
        main(NR=20, NA=36)
    end
end
