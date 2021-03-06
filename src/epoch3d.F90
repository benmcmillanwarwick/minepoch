PROGRAM pic

  ! EPOCH3D is a Birdsall and Langdon type PIC code derived from the PSC
  ! written by Hartmut Ruhl.

  ! The particle pusher (particles.F90) and the field solver (fields.f90) are
  ! almost exact copies of the equivalent routines from PSC, modified slightly
  ! to allow interaction with the changed portions of the code and for
  ! readability. The MPI routines are exactly equivalent to those in PSC, but
  ! are completely rewritten in a form which is easier to extend with arbitrary
  ! fields and particle properties. The support code is entirely new and is not
  ! equivalent to PSC.

  ! EPOCH3D written by C.S.Brady, Centre for Fusion, Space and Astrophysics,
  ! University of Warwick, UK
  ! PSC written by Hartmut Ruhl

  USE balance
  USE diagnostics
  USE fields
  USE helper
  USE ic_module
  USE mpi_routines
  USE particles
  USE setup
  USE problem_setup_module
  USE finish
  USE welcome
#ifdef PAT_DEBUG
  USE pat_mpi_lib
#endif
  IMPLICIT NONE

  INTEGER :: ispecies, ierr
  LOGICAL :: push = .TRUE.
  CHARACTER(LEN=*), PARAMETER :: data_dir_file = 'USE_DATA_DIRECTORY'
  CHARACTER(LEN=64) :: timestring
#ifdef PAT_DEBUG
  CHARACTER(LEN=17) :: patc_out_fn = "patc_epoch3d.out"//CHAR(0)
#endif
  
  REAL(num) :: runtime
  TYPE(particle_species), POINTER :: species, next_species

  step = 0
  time = 0.0_num

  CALL mpi_minimal_init ! mpi_routines.f90
  real_walltime_start = MPI_WTIME()
  CALL minimal_init     ! setup.f90
  CALL timer_init
  CALL setup_partlists  ! partlist.f90
  CALL welcome_message  ! welcome.f90

  IF (rank == 0) THEN
    OPEN(unit=lu, status='OLD', file=TRIM(data_dir_file), iostat=ierr)
    IF (ierr == 0) THEN
      READ(lu,'(A)') data_dir
      CLOSE(lu)
      PRINT*, 'Using data directory "' // TRIM(data_dir) // '"'
    ELSE
      data_dir = 'Data'
    ENDIF
  ENDIF

  CALL MPI_BCAST(data_dir, 64, MPI_CHARACTER, 0, comm, errcode)
  CALL problem_setup(c_ds_first)
  CALL setup_particle_boundaries ! boundary.f90
  CALL mpi_initialise  ! mpi_routines.f90
  CALL after_control   ! setup.f90

  CALL problem_setup(c_ds_last)
  CALL after_deck_last

  ! auto_load particles
  CALL auto_load
  time = 0.0_num

  CALL manual_load
  CALL set_dt
  CALL deallocate_ic

  npart_global = 0

  next_species => species_list
  DO ispecies = 1, n_species
    species => next_species
    next_species => species%next

    npart_global = npart_global + species%count
  ENDDO

  ! .TRUE. to over_ride balance fraction check
  IF (npart_global > 0) CALL balance_workload(.TRUE.)

  CALL particle_bcs
  CALL efield_bcs
  CALL bfield_final_bcs
  time = time + dt / 2.0_num

  IF (rank == 0) PRINT *, 'Equilibrium set up OK, running code'

  walltime_start = MPI_WTIME()
  CALL output_routines(step) ! diagnostics.f90

  IF (timer_collect) CALL timer_start(c_timer_step)

#ifdef PAT_DEBUG
  CALL pat_mpi_open(patc_out_fn)
#endif
  
  DO
    IF ((step >= nsteps .AND. nsteps >= 0) .OR. (time >= t_end)) EXIT
    IF (timer_collect) THEN
      CALL timer_stop(c_timer_step)
      CALL timer_reset
      timer_first(c_timer_step) = timer_walltime
    ENDIF
    push = (time >= particle_push_start_time)
    CALL update_eb_fields_half
    
    IF (push) THEN
      ! .FALSE. this time to use load balancing threshold
      IF (use_balance) CALL balance_workload(.FALSE.)
      CALL push_particles
    ENDIF

#ifdef PAT_DEBUG
    CALL pat_mpi_monitor(step,1)
#endif
    
    step = step + 1
    time = time + dt / 2.0_num
    CALL output_routines(step)
    time = time - dt / 2.0_num

    CALL update_eb_fields_final
    time = time + dt

    ! This section ensures that the particle count for the species_list
    ! objects is accurate. This makes some things easier, but increases
    ! communication
#ifdef PARTICLE_COUNT_UPDATE
    next_species => species_list
    DO ispecies = 1, n_species
      species => next_species
      next_species => species%next
      CALL MPI_ALLREDUCE(species%attached_list%count, species%count, 1, &
          MPI_INTEGER8, MPI_SUM, comm, errcode)
      species%count_update_step = step
    ENDDO
#endif
    
  ENDDO
 
#ifdef PAT_DEBUG
  CALL pat_mpi_close()
#endif
  
  IF (rank == 0) runtime = MPI_WTIME() - walltime_start

  CALL output_routines(step)

  IF (rank == 0) THEN
    CALL create_full_timestring(runtime, timestring)
    WRITE(*,*) 'Final runtime of core = ' // TRIM(timestring)
  ENDIF

  CALL finalise

END PROGRAM pic
