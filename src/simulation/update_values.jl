function update_values!(integrator)
    (nvars, ncells) = size(integrator.u)

    nandetected = false
    infdetected = false

    # Update the timestep
    if integrator.p.adaptive
        SciMLBase.set_proposed_dt!(integrator, integrator.p.CFL * integrator.p.max_timestep[1])
    end

    @inbounds for j in 1:ncells, i in 1:nvars
        if isnan(integrator.u[i, j])
            println("NaN detected in variable $i in cell $j at time $(integrator.t)")
            nandetected = true
            terminate!(integrator, :NaNDetected)
            break
        elseif isinf(integrator.u[i, j])
            println("Inf detected in variable $i in cell $j at time $(integrator.t)")
            infdetected = true
            terminate!(integrator, :InfDetected)
            break
        end
    end

    if !nandetected && !infdetected
        update_values!(integrator.u, integrator.p, integrator.t)
    end
end

#update useful quantities relevant for potential, electron energy and fluid solve
function update_values!(U, params, t = 0)
    (;z_cell, index, A_ch) = params
    (;B, ue, Tev, ∇ϕ, ϕ, pe, ne, μ, ∇pe, νan, νc, νen, νei, νw, Z_eff, νiz, νex, νe, ji, Id) = params.cache

    # Update the current iteration
    params.iteration[1] += 1

    # Apply fluid boundary conditions
    @views left_boundary_state!(U[:, 1], U, params)
    @views right_boundary_state!(U[:, end], U, params)

    ncells = size(U, 2)

    # Update electron quantities
    @inbounds for i in 1:ncells
        ne[i] = max(params.config.min_number_density, electron_density(U, params, i))
        Tev[i] = 2/3 * max(params.config.min_electron_temperature, U[index.nϵ, i]/ne[i])
        pe[i] = if params.config.LANDMARK
            3/2 * ne[i] * Tev[i]
        else
            ne[i] * Tev[i]
        end
        νen[i] = freq_electron_neutral(U, params, i)
        νei[i] = freq_electron_ion(U, params, i)
        νw[i] = freq_electron_wall(U, params, i)
        νan[i] = freq_electron_anom(U, params, i)
        νc[i] = νen[i] + νei[i]
        if params.config.LANDMARK
            νc[i] += νiz[i] + νex[i]
        end
        νe[i] = νc[i] + νan[i] + νw[i]
        μ[i] = electron_mobility(νe[i], B[i])
        Z_eff[i] = compute_Z_eff(U, params, i)
        ji[i] = ion_current_density(U, params, i)
    end

    # Compute the discharge current by integrating the momentum equation over the whole domain
    Id[] = discharge_current(U, params)

    # Compute the electron velocity and electron kinetic energy
    @inbounds for i in 1:ncells
        # je + ji = Id / A_ch
        ue[i] = (ji[i] - Id[] / A_ch) / e / ne[i]

        # Kinetic energy in both axial and azimuthal directions is accounted for
        params.cache.K[i] = electron_kinetic_energy(U, params, i)
    end

    # update electrostatic potential and potential gradient on edges
    solve_potential_edge!(U, params)

    # Compute potential gradient and pressure gradient
    compute_gradients!(∇ϕ, ∇pe, params)

    # Update the electron temperature and pressure
    update_electron_energy!(U, params)
end

function compute_gradients!(∇ϕ, ∇pe, params)
    (; ϕ, pe, ϕ_cell) = params.cache
    (;z_cell, z_edge) = params

    ncells = length(z_cell)

    # Interpolate potential to cells
    ϕ_cell[1] = ϕ[1]
    ϕ_cell[end] = ϕ[end]
    @turbo for i in 2:ncells-1
        ϕ_cell[i] = lerp(z_cell[i], z_edge[i-1], z_edge[i], ϕ[i-1], ϕ[i])
    end

    # Potential gradient (centered)
    ∇ϕ[1] = forward_difference(ϕ[1], ϕ[2], ϕ[3], z_edge[1], z_edge[2], z_edge[3])

    # Pressure gradient (forward)
    ∇pe[1] = forward_difference(pe[1], pe[2], pe[3], z_cell[1], z_cell[2], z_cell[3])

    # Centered difference in interior cells
    @inbounds for j in 2:ncells-1
        # Compute potential gradient
        ∇ϕ[j] = (ϕ[j] - ϕ[j-1]) / (z_edge[j] - z_edge[j-1])

        # Compute pressure gradient
        ∇pe[j] = central_difference(pe[j-1], pe[j], pe[j+1], z_cell[j-1], z_cell[j], z_cell[j+1])
    end

    # Potential gradient (centered)
    ∇ϕ[end] = backward_difference(ϕ[end-2], ϕ[end-1], ϕ[end], z_edge[end-2], z_edge[end-1], z_edge[end])
    # pressure gradient (backward)
    ∇pe[end] = backward_difference(pe[end-2], pe[end-1], pe[end], z_cell[end-2], z_cell[end-1], z_cell[end])

    return nothing
end