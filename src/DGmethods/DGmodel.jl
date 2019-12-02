abstract type Direction end
struct EveryDirection <: Direction end
struct HorizontalDirection <: Direction end
struct VerticalDirection <: Direction end

struct DGModel{BL,G,NFND,NFD,GNF,AS,DS,D}
  balancelaw::BL
  grid::G
  numfluxnondiff::NFND
  numfluxdiff::NFD
  gradnumflux::GNF
  auxstate::AS
  diffstate::DS
  direction::D
end
function DGModel(balancelaw, grid, numfluxnondiff, numfluxdiff, gradnumflux;
                 auxstate=create_auxstate(balancelaw, grid),
                 diffstate=create_diffstate(balancelaw, grid),
                 direction=EveryDirection())
  DGModel(balancelaw, grid, numfluxnondiff, numfluxdiff, gradnumflux, auxstate,
          diffstate, direction)
end

function (dg::DGModel)(dQdt, Q, ::Nothing, t; increment=false)
  bl = dg.balancelaw
  device = typeof(Q.data) <: Array ? CPU() : CUDA()

  grid = dg.grid
  topology = grid.topology

  dim = dimensionality(grid)
  N = polynomialorder(grid)
  Nq = N + 1
  Nqk = dim == 2 ? 1 : Nq
  Nfp = Nq * Nqk
  nrealelem = length(topology.realelems)

  Qvisc = dg.diffstate
  auxstate = dg.auxstate

  FT = eltype(Q)
  nviscstate = num_diffusive(bl, FT)

  lgl_weights_vec = grid.ω
  Dmat = grid.D
  vgeo = grid.vgeo
  sgeo = grid.sgeo
  vmapM = grid.vmapM
  vmapP = grid.vmapP
  elemtobndy = grid.elemtobndy
  polyorder = polynomialorder(dg.grid)

  Np = dofs_per_element(grid)

  communicate = !(isstacked(topology) &&
                  typeof(dg.direction) <: VerticalDirection)

  update_aux!(dg, bl, Q, t)

  ########################
  # Gradient Computation #
  ########################
  if communicate
    MPIStateArrays.start_ghost_exchange!(Q)
    MPIStateArrays.start_ghost_exchange!(auxstate)
  end

  if nviscstate > 0

    @launch(device, threads=(Nq, Nq, Nqk), blocks=nrealelem,
            volumeviscterms!(bl, Val(dim), Val(polyorder), dg.direction, Q.data,
                             Qvisc.data, auxstate.data, vgeo, t, Dmat,
                             topology.realelems))

    if communicate
      MPIStateArrays.finish_ghost_recv!(Q)
      MPIStateArrays.finish_ghost_recv!(auxstate)
    end

    @launch(device, threads=Nfp, blocks=nrealelem,
            faceviscterms!(bl, Val(dim), Val(polyorder), dg.direction,
                           dg.gradnumflux, Q.data, Qvisc.data, auxstate.data,
                           vgeo, sgeo, t, vmapM, vmapP, elemtobndy,
                           topology.realelems))

    communicate && MPIStateArrays.start_ghost_exchange!(Qvisc)
  end

  ###################
  # RHS Computation #
  ###################
  @launch(device, threads=(Nq, Nq, Nqk), blocks=nrealelem,
          volumerhs!(bl, Val(dim), Val(polyorder), dg.direction, dQdt.data,
                     Q.data, Qvisc.data, auxstate.data, vgeo, t,
                     lgl_weights_vec, Dmat, topology.realelems, increment))

  if communicate
    if nviscstate > 0
      MPIStateArrays.finish_ghost_recv!(Qvisc)
    else
      MPIStateArrays.finish_ghost_recv!(Q)
      MPIStateArrays.finish_ghost_recv!(auxstate)
    end
  end

  @launch(device, threads=Nfp, blocks=nrealelem,
          facerhs!(bl, Val(dim), Val(polyorder), dg.direction,
                   dg.numfluxnondiff,
                   dg.numfluxdiff,
                   dQdt.data, Q.data, Qvisc.data,
                   auxstate.data, vgeo, sgeo, t, vmapM, vmapP, elemtobndy,
                   topology.realelems))

  # Just to be safe, we wait on the sends we started.
  if communicate
    MPIStateArrays.finish_ghost_send!(Qvisc)
    MPIStateArrays.finish_ghost_send!(Q)
  end
end

function init_ode_state(dg::DGModel, args...;
                        device=arraytype(dg.grid) <: Array ? CPU() : CUDA(),
                        commtag=888)
  array_device = arraytype(dg.grid) <: Array ? CPU() : CUDA()
  @assert device == CPU() || device == array_device

  bl = dg.balancelaw
  grid = dg.grid

  state = create_state(bl, grid, commtag)

  topology = grid.topology
  Np = dofs_per_element(grid)

  auxstate = dg.auxstate
  dim = dimensionality(grid)
  polyorder = polynomialorder(grid)
  vgeo = grid.vgeo
  nrealelem = length(topology.realelems)

  if device == array_device
    @launch(device, threads=(Np,), blocks=nrealelem,
            initstate!(bl, Val(dim), Val(polyorder), state.data, auxstate.data, vgeo,
                     topology.realelems, args...))
  else
    h_vgeo = Array(vgeo)
    h_state = similar(state, Array)
    h_auxstate = similar(auxstate, Array)
    h_auxstate .= auxstate
    @launch(device, threads=(Np,), blocks=nrealelem,
      initstate!(bl, Val(dim), Val(polyorder), h_state.data, h_auxstate.data, h_vgeo,
          topology.realelems, args...))
    state .= h_state
  end  

  MPIStateArrays.start_ghost_exchange!(state)
  MPIStateArrays.finish_ghost_exchange!(state)

  return state
end

function indefinite_stack_integral!(dg::DGModel, m::BalanceLaw,
                                    Q::MPIStateArray, auxstate::MPIStateArray,
                                    t::Real)

  device = typeof(Q.data) <: Array ? CPU() : CUDA()

  grid = dg.grid
  topology = grid.topology

  dim = dimensionality(grid)
  N = polynomialorder(grid)
  Nq = N + 1
  Nqk = dim == 2 ? 1 : Nq

  FT = eltype(Q)

  vgeo = grid.vgeo
  polyorder = polynomialorder(dg.grid)

  # do integrals
  nintegrals = num_integrals(m, FT)
  nelem = length(topology.elems)
  nvertelem = topology.stacksize
  nhorzelem = div(nelem, nvertelem)

  @launch(device, threads=(Nq, Nqk, 1), blocks=nhorzelem,
          knl_indefinite_stack_integral!(m, Val(dim), Val(polyorder),
                                         Val(nvertelem), Q.data, auxstate.data,
                                         vgeo, grid.Imat, 1:nhorzelem,
                                         Val(nintegrals)))
end

# fallback
function update_aux!(dg::DGModel, bl::BalanceLaw, Q::MPIStateArray, t::Real)
end

function reverse_indefinite_stack_integral!(dg::DGModel, m::BalanceLaw,
                                            auxstate::MPIStateArray, t::Real)

  device = typeof(auxstate.data) <: Array ? CPU() : CUDA()

  grid = dg.grid
  topology = grid.topology

  dim = dimensionality(grid)
  N = polynomialorder(grid)
  Nq = N + 1
  Nqk = dim == 2 ? 1 : Nq

  FT = eltype(auxstate)

  vgeo = grid.vgeo
  polyorder = polynomialorder(dg.grid)

  # do integrals
  nintegrals = num_integrals(m, FT)
  nelem = length(topology.elems)
  nvertelem = topology.stacksize
  nhorzelem = div(nelem, nvertelem)

  @launch(device, threads=(Nq, Nqk, 1), blocks=nhorzelem,
          knl_reverse_indefinite_stack_integral!(Val(dim), Val(polyorder),
                                                 Val(nvertelem), auxstate.data,
                                                 1:nhorzelem,
                                                 Val(nintegrals)))
end

function nodal_update_aux!(f!, dg::DGModel, m::BalanceLaw, Q::MPIStateArray,
                           t::Real)
  device = typeof(Q.data) <: Array ? CPU() : CUDA()

  grid = dg.grid
  topology = grid.topology

  dim = dimensionality(grid)
  N = polynomialorder(grid)
  Nq = N + 1
  nrealelem = length(topology.realelems)

  polyorder = polynomialorder(dg.grid)

  Np = dofs_per_element(grid)

  ### update aux variables
  @launch(device, threads=(Np,), blocks=nrealelem,
          knl_nodal_update_aux!(m, Val(dim), Val(polyorder), f!,
                          Q.data, dg.auxstate.data, dg.diffstate.data, t,
                          topology.realelems))
end

"""
    nodal_transfer_state!(f!, grid, dst_m, dst_Q, dst_auxstate,
                          src_m, src_Q, src_auxstate, t)

Use the function `f` to transfer the state (and/or the auxiliary state) between two different balance laws
"""
function nodal_transfer_state!(f!, grid,
                       dst_m::BalanceLaw, dst_Q::MPIStateArray, dst_auxstate::MPIStateArray,
                       src_m::BalanceLaw, src_Q::MPIStateArray, src_auxstate::MPIStateArray,
                       t::Real)
  dst_device = typeof(dst_Q.data) <: Array ? CPU() : CUDA()
  src_device = typeof(src_Q.data) <: Array ? CPU() : CUDA()
  @assert dst_device == src_device

  topology = grid.topology
  dim = dimensionality(grid)
  nrealelem = length(topology.realelems)
  polyorder = polynomialorder(grid)
  Np = dofs_per_element(grid)

  ### update aux variables
  @launch(dst_device, threads=(Np,), blocks=nrealelem,
          knl_nodal_transfer_state!(Val(dim), Val(polyorder), topology.realelems, f!,
                                    dst_m, dst_Q.data, dst_auxstate.data,
                                    src_m, src_Q.data, src_auxstate.data,
                                    t))
end

"""
    grad_auxiliary_state!(disc, i, (ix1, ix2, ix3)
Computes the gradient of a the field `i` of the constant auxiliary state of
`disc` and stores the `x1, x2, x3` compoment in fields `ix1, ix2, ix3` of constant
auxiliary state.
!!! note
    This only computes the element gradient not a DG gradient. If your constant
    auxiliary state is discontinuous this may or may not be what you want!
"""
function grad_auxiliary_state!(dg::DGModel, id, (idx1, idx2, idx3))
  grid = dg.grid
  topology = grid.topology

  dim = dimensionality(grid)
  N = polynomialorder(grid)

  auxstate = dg.auxstate

  nauxstate = size(auxstate, 2)

  @assert nauxstate >= max(id, idx1, idx2, idx3)
  @assert 0 < min(id, idx1, idx2, idx3)
  @assert allunique((idx1, idx2, idx3))

  lgl_weights_vec = grid.ω
  Dmat = grid.D
  vgeo = grid.vgeo

  device = typeof(auxstate.data) <: Array ? CPU() : CUDA()

  nelem = length(topology.elems)
  Nq = N + 1
  Nqk = dim == 2 ? 1 : Nq

  @launch(device, threads=(Nq, Nq, Nqk), blocks=nelem,
          elem_grad_field!(Val(dim), Val(N), Val(nauxstate), auxstate.data, vgeo,
                           lgl_weights_vec, Dmat, topology.elems,
                           id, idx1, idx2, idx3))
end

function MPIStateArrays.MPIStateArray(dg::DGModel, commtag=888)
  bl = dg.balancelaw
  grid = dg.grid

  state = create_state(bl, grid, commtag)

  return state
end
