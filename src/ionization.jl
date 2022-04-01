Base.@kwdef struct IonizationReaction{I}
    ionization_energy::Float64
    reactant::Species
    product::Species
    rate_coeff::I
end

function species_indices(reactions, species_range_dict)
    reactant_indices = zeros(Int, length(reactions))
    product_indices = zeros(Int, length(reactions))
    for (i, reaction) in enumerate(reactions)
        reactant_indices[i] = species_range_dict[reaction.reactant.symbol][1]
        product_indices[i] = species_range_dict[reaction.product.symbol][1]
    end
    return reactant_indices, product_indices
end

function Base.show(io::IO, i::IonizationReaction)
    electron_input = "e-"
    electron_output = string(i.product.Z - i.reactant.Z + 1) * "e-"
    reactant_str = string(i.reactant)
    product_str = string(i.product)
    rxn_str = electron_input * " + " * reactant_str * " -> "
    rxn_str *= electron_output * " + " * product_str
    return print(io, rxn_str)
end

abstract type IonizationModel end

struct LandmarkIonizationLUT <: IonizationModel end

Base.@kwdef struct IonizationLUT <: IonizationModel
    extra_paths::Vector{String} = String[]
end

struct IonizationFit <: IonizationModel end

"""
    supported_gases(model::IonizationModel)::Vector{HallThruster.Gas}
Check which gases are supported by a given ionization model
"""
@inline supported_gases(::IonizationModel) = Gas[]
@inline supported_gases(::IonizationLUT)   = Gas[]
@inline supported_gases(::IonizationFit)   = [Xenon]
@inline supported_gases(::LandmarkIonizationLUT) = [Xenon]

"""
    maximum_charge_state(model::IonizationModel)::Int
Return the maximum supported charge state for a given ionization model
"""
@inline maximum_charge_state(::IonizationModel) = 0
@inline maximum_charge_state(::IonizationLUT)   = 0
@inline maximum_charge_state(::IonizationFit)   = 3
@inline maximum_charge_state(::LandmarkIonizationLUT) = 1

function _load_ionization_reactions(model::IonizationModel, species)
    supported = supported_gases(model)
    if length(supported) > 0
        for s in species
            if s.element ∉ supported
                throw(ArgumentError("$(s.element) is not supported by the provided ionization model. The list of supported gases is $(supported)"))
            end
        end
    end

    max_charge = maximum_charge_state(model)
    if max_charge > 0
        for s in species
            if s.Z > max_charge
                throw(ArgumentError("The provided ionization model does not support ions with a charge state of $(s.Z). The maximum supported charge state is $(max_charge)."))
            end
        end
    end

    load_ionization_reactions(model, species)
end

@inline load_ionization_reactions(i::IonizationModel, species) = throw(ArgumentError("Function load_ionization_reactions(model, species) not implemented for $(typeof(i))."))

function load_ionization_reactions(model::IonizationLUT, species)
    species_sorted = sort(species; by=x -> x.Z)
    reactions = IonizationReaction{LinearInterpolation{Float64,Float64}}[]
    folders = [model.extra_paths; REACTION_FOLDER]
    for i in 1:length(species)
        for j in (i + 1):length(species)
            found = false
            reactant = species_sorted[i]
            product = species_sorted[j]
            for folder in folders
                filename = rate_coeff_filename(reactant, product, "ionization", folder)
                if ispath(filename)
                    reaction = load_ionization_reaction(reactant, product, folder)
                    push!(reactions, reaction)
                    found = true
                    break
                end
            end
            if !found
                throw(ArgumentError("No reactions including $(reactant) and $(product) in provided directories."))
            end
        end
    end

    return reactions
end

function load_ionization_reaction(reactant, product, folder = REACTION_FOLDER)
    rates_file = rate_coeff_filename(reactant, product, "ionization", folder)
    if ispath(rates_file)
        ionization_energy, rates = open(rates_file) do io
            ionization_energy = split(readline(io), ':')[2] |> strip |> parse $ (Float64)
            rates = readdlm(io, skipstart=1)
            ionization_energy, rates
        end
    else
        throw(ArgumentError("$rates_file not found. This should normally be unreachable."))
    end
    Te = rates[:, 1]
    k = rates[:, 2]
    rate_coeff = LinearInterpolation(Te, k)
    return IonizationReaction(ionization_energy, reactant, product, rate_coeff)
end

function rate_coeff_filename(reactant, product, reaction_type, folder = REACTION_FOLDER)
    return joinpath(folder, join([reaction_type, repr(reactant), repr(product)], "_") * ".dat")
end

function load_ionization_reactions(::LandmarkIonizationLUT, species)
    rates = readdlm(LANDMARK_RATES_FILE, ',', skipstart = 1)
    ϵ = rates[:, 1]
    k_ionization = rates[:, 2]
    rate_coeff = LinearInterpolation(ϵ, k_ionization)
    return [IonizationReaction(12.12, Xenon(0), Xenon(1), rate_coeff)]
end

@inline function load_ionization_reactions(::IonizationFit, species)
    ncharge = maximum(s.Z for s in species)
    return ionization_fits_Xe(ncharge)
end

struct Biexponential{T}
    c1::T
    c2::T
    c3::T
    c4::T
    c5::T
end

@inline (b::Biexponential)(x) = b.c1 * (exp(-b.c2 / (x + b.c5)) - b.c4 * exp(-b.c2 * b.c3 / (x + b.c5)))

function ionization_fits_Xe(ncharge::Int)

    Xe0_Xe1 = IonizationReaction(
        12.1298437, Xenon(0), Xenon(1), Biexponential(3.6e-13, 40.0, 0.0, 0.0, 3.0)
    )

    Xe0_Xe2 = IonizationReaction(
        33.1048437, Xenon(0), Xenon(2), Biexponential(3.8e-14, 57.0, 10.0, 0.7, 0.0)
    )

    Xe0_Xe3 = IonizationReaction(
        64.1548427, Xenon(0), Xenon(3), Biexponential(1.7e-14, 120.0, 6.0, 0.5, 0.0)
    )

    Xe1_Xe2 = IonizationReaction(
        20.975, Xenon(1), Xenon(2), Biexponential(1.48e-13, 35.0, 11.0, 0.45, 0.0)
    )

    Xe1_Xe3 = IonizationReaction(
        52.025, Xenon(1), Xenon(3), Biexponential(4e-14, 100.0, 4.0, 0.8, 0.0)
    )

    Xe2_Xe3 = IonizationReaction(
        31.05, Xenon(2), Xenon(3), Biexponential(1.11e-13, 43.0, 7.0, 0.68, 0.0)
    )

    if ncharge == 1
        return [Xe0_Xe1]
    elseif ncharge == 2
        return [Xe0_Xe1, Xe0_Xe2, Xe1_Xe2]
    elseif ncharge == 3
        return [Xe0_Xe1, Xe0_Xe2, Xe0_Xe3, Xe1_Xe2, Xe1_Xe3, Xe2_Xe3]
    else
        throw(ArgumentError("ncharge must be 1, 2, or 3"))
    end
end

@inline function maxwellian_vdf(Tev, v)
    sqrt(2/π) * v^2 * (me / e / Tev)^(3/2) * exp(-me * v^2 / 2 / e/ Tev)
end

function compute_rate_coeffs(energies, cross_section_func)
    integrand(Te, v) = let ϵ = 1/2 * me * v^2 / e
        cross_section_func(ϵ) * v * maxwellian_vdf(Te, v)
    end

    rate_coeffs = [
        quadgk(integrand $ (2/3 * ϵ), 0.0, 10 * sqrt(2 * e * ϵ / me))[1] for ϵ in energies
    ]
    return rate_coeffs
end

function compute_rate_coeffs(cross_section_filename)
    data = readdlm(cross_section_filename, ',')
    energies = 1.0:150.0

    ϵ, σ = data[:, 1], data[:, 2] * 1e-20
    cross_section_func = LinearInterpolation(ϵ, σ)
    rate_coeffs = compute_rate_coeffs(energies, cross_section_func)

    fname = splitpath(cross_section_filename)[end]
    open("reactions/$fname", "w") do io
        println(io, "Energy (eV)	Rate coefficient (m3/s)")
        writedlm(io, [energies rate_coeffs])
    end
end