SUBROUTINE GMK98_Ind_Size(Temp, PAR, NO3, C, N, Chl, Cdiv, dC, dN, dChl)
!==============================================================================
! PLACEHOLDER -- not part of the upstream PIBM 1.0 release.
!
! src/Makefile lists GMK98_Ind_Size.f90 in SRCS and Geider_Lag.f90 calls
! GMK98_Ind_Size() for Model_ID = GMK98_Size (= 3 in variables.f90), but the
! file was never committed to the repository, so the link step fails with an
! undefined symbol for EVERY Model_ID -- including the ones that are fully
! implemented.
!
! This stub restores linkability without inventing model formulation. It
! follows the same convention the other unimplemented branches of the
! SELECT CASE in Geider_Lag.f90 use: stop with a message if reached.
!
! Model_ID = 1 (Run_simple) and Model_ID = 8 (Run/BATS) never call this.
!==============================================================================
implicit none

real, intent(in)  :: Temp   ! Associated temperature [degree C]
real, intent(in)  :: PAR    ! Associated PAR [W m-2]
real, intent(in)  :: NO3    ! Associated NO3 concentration [mmol N m-3]
real, intent(in)  :: C      ! Current cellular carbon [pmol C cell-1]
real, intent(in)  :: N      ! Current cellular nitrogen [pmol N cell-1]
real, intent(in)  :: Chl    ! Current cellular Chl [pg Chl cell-1]
real, intent(in)  :: Cdiv   ! Cellular carbon content threshold for division [pmol]

real, intent(out) :: dC     ! Change in cellular carbon [pmol C cell-1]
real, intent(out) :: dN     ! Change in cellular nitrogen [pmol N cell-1]
real, intent(out) :: dChl   ! Change in cellular Chl [pg Chl cell-1]

dC   = 0d0
dN   = 0d0
dChl = 0d0

write(6,*) 'GMK98_Ind_Size: Temp=', Temp, ' PAR=', PAR, ' NO3=', NO3, &
           ' C=', C, ' N=', N, ' Chl=', Chl, ' Cdiv=', Cdiv

stop "Model_ID = GMK98_Size is not available: src/GMK98_Ind_Size.f90 is missing from the PIBM release."

END SUBROUTINE GMK98_Ind_Size
