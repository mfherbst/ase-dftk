module asedftk
using PyCall
import JSON
import DFTK: PlaneWaveBasis, Model, self_consistent_field, load_psp
import DFTK: load_lattice, load_atoms, ElementPsp, model_DFT, forces
import DFTK: Smearing, kgrid_size_from_minimal_spacing

ase_units = pyimport("ase.units")
ase_io = pyimport("ase.io")
calculator = pyimport("ase.calculators.calculator")


# Discussion of valid parameters:
#
# - xc, kpts, smearing, nbands as in
#   https://wiki.fysik.dtu.dk/ase/development/proposals/calculators.html
# - functional: If specified, defines the precise functionals used from libxc,
#   if not autodetermined from xc parameter.
# - pps: Pseudopotential family employed. Valid are "hgh" and "hgh.k" in which
#   case the semi-core versions of the HGH pseudopotentials is used.
# - scftol: SCF convergence tolerance.
# - ecut: Kinetic energy cutoff (in eV)
#

@pydef mutable struct DFTK <: calculator.Calculator
    implemented_properties = ["energy", "free_energy", "forces"]

    function __init__(self; atoms=nothing, label="dftk", kwargs...)
        self.default_parameters = Dict{String,Any}(
            "xc"          => "LDA",
            "kpts"        => 0.25,
            "smearing"    => nothing,
            "nbands"      => nothing,
            "charge"      => 0.0,
            "functionals" => nothing,
            "pps"         => "hgh",
            "scftol"      => 1e-5,
            "ecut"        => 400,
        )

        calculator.Calculator.__init__(self; label=label, kwargs...)
        self.scfres = nothing   # Results of the most recent SCF run
    end

    function reset(self)
        # Reset internal state by purging all intermediates
        calculator.Calculator.reset(self)
        self.scfres = nothing
    end

    function read(self, label)
        calculator.Calculator.read(self, label)

        saved_dict = open(JSON.parse, label * ".json", "r")
        self.parameters = calculator.Parameters(saved_dict["parameters"])
        self.results = saved_dict["results"]
        @pywith pyimport("io").StringIO(saved_dict["atoms"]) as f begin
            self.atoms = ase_io.read(f, format="json")
        end

        self.scfres = nothing  # Discard any cached results
    end

    function set(self; kwargs...)
        changed_parameters = calculator.Calculator.set(self; kwargs...)
        if !isempty(changed_parameters)
            # Currently reset on all parameter changes
            # TODO Improve
            self.reset()
        end
    end

    function check_state(self, atoms)
        system_changes = calculator.Calculator.check_state(self, atoms)
        if "pbc" in system_changes
            # Ignore boundary conditions (we always use PBCs)
            deleteat!(system_changes, findfirst(isequal("pbc"), system_changes))
        end
        system_changes
    end

    function get_spin_polarized(self)
        if isnothing(self.scfres)
            false
        else
            self.scfres.basis.model.spin_polarisation in (:full, :collinear)
        end
    end

    function get_dftk_model(self)
        inputerror(s) = pyraise(calculator.InputError(s))
        inputerror_param(param) = inputerror("Unknown value to $param: " *
                                             "$(self.parameters[param])")
        if isnothing(self.atoms)
            pyraise(calculator.CalculatorSetupError("An Atoms object must be provided to " *
                                                    "perform a calculation"))
        end


        # Parse psp and DFT functional parameters
        functionals = [:lda_xc_teter93]
        if lowercase(self.parameters["xc"]) == "lda"
            psp_functional = "lda"
            functionals = [:lda_xc_teter93]
        elseif lowercase(self.parameters["xc"]) == "pbe"
            psp_functional = "pbe"
            functionals = [:gga_x_pbe, :gga_c_pbe]
        else
            inputerror_param("xc")
        end

        if !isnothing(self.parameters["functionals"])
            funs = self.parameters["functionals"]
            if funs isa AbstractArray
                functionals = Symbol.(funs)
            else
                functionals = [Symbol(funs)]
            end
        end

        if self.parameters["pps"] == "hgh"
            psp_family = "hgh"
            psp_core = :fullcore
        elseif self.parameters["pps"] == "hgh.k"
            psp_family = "hgh"
            psp_core = :semicore
        else
            inputerror_param("pps")
        end

        # Parse smearing and temperature
        temperature = 0.0
        smearing = nothing
        if !isnothing(self.parameters["smearing"])
            psmear = self.parameters["smearing"]
            if lowercase(psmear[1]) == "fermi-dirac"
                smearing = DFTK.Smearing.FermiDirac()
            elseif lowercase(psmear[1]) == "gaussian"
                smearing = DFTK.Smearing.Gaussian()
            elseif lowercase(psmear[1]) == "methfessel-paxton"
                # This if can go in the next DFTK version
                # because it will be built into DFTK
                if psmear[3] == 0
                    smearing = Gaussian()
                elseif psmear[3] == 1
                    smearing = MethfesselPaxton1()
                elseif psmear[3] == 2
                    smearing = MethfesselPaxton2()
                else
                    inputerror("Methfessel-Paxton smearing beyond order 2 not " *
                               "implemented in DFTK.")
                end
            else
                inputerror_param("smearing")
            end
            temperature = psmear[2] / ase_units.Hartree
        end

        if self.parameters["charge"] != 0.0
            inputerror("Charged systems not supported in DFTK.")
        end

        # TODO This is the place where spin-polarisation should be added
        #      once it is in DFTK.

        # Build DFTK atoms
        psploader(symbol) = load_psp(symbol, functional=psp_functional,
                                     family=psp_family, core=psp_core)
        lattice = load_lattice(self.atoms)
        atoms = [ElementPsp(element.symbol, psp=psploader(element.symbol)) => positions
                 for (element, positions) in load_atoms(self.atoms)]

        model_DFT(lattice, atoms, functionals; temperature=temperature,
                  smearing=smearing)
    end

    function get_dftk_basis(self; model=self.get_dftk_model())
        inputerror(s) = pyraise(calculator.InputError(s))
        inputerror_param(param) = inputerror("Unknown value to $param: " *
                                             "$(self.parameters[param])")

        # Build kpoint mesh
        kpts = self.parameters["kpts"]
        kgrid = [1, 1, 1]
        if kpts isa Number
            kgrid = kgrid_size_from_minimal_spacing(model.lattice, kpts / ase_units.Bohr)
        elseif length(kpts) == 3 && all(kpt isa Number for kpt in kpts)
            kgrid = kpts  # Just a plain MP grid
        elseif length(kpts) == 4 && all(kpt isa Number for kpt in kpts[1:3])
            # MP grid shifted to always contain Gamma
            if kpts[4] == "gamma"
                inputerror("Shifted Monkhorst-Pack grids not supported by DFTK.")
            else
                inputerror_param("kpts")
            end
        elseif kpts isa AbstractArray
            inputerror("Explicit kpoint list not yet supported by DFTK calculator.")
        end

        # Convert ecut to Hartree
        Ecut = self.parameters["ecut"] / ase_units.Hartree
        PlaneWaveBasis(model, Ecut, kgrid=kgrid)
    end

    function get_dftk_scfres(self; basis=self.get_dftk_basis())
        extraargs=()
        if !isnothing(self.parameters["nbands"])
            extraargs = (n_bands=self.parameters["nbands"], )
        end
        try
            tol = self.parameters["scftol"]  # TODO Maybe unit conversion here!
            self_consistent_field(basis; tol=tol, callback=info -> (), extraargs...)
        catch e
            pyraise(calculator.SCFError(string(e)))
        end
    end

    function write(self, label=self.label)
        if isnothing(self.atoms)
            pyraise(calculator.CalculatorSetupError("An Atoms object must be present " *
                                                    "in the calculator to use write"))
        end

        # Convert atoms to json
        atoms_json = ""
        @pywith pyimport("io").StringIO() as f begin
            ase_io.write(f, self.atoms.copy(), format="json")
            atoms_json = f.getvalue()
        end

        open(label * ".json", "w") do fp
            save_dict = Dict(
                "parameters" => self.parameters,
                "results" => self.results,
                "atoms" => atoms_json,
            )
            JSON.print(fp, save_dict)
        end
    end

    function calculate(self, atoms=nothing, properties=["energy"],
                       system_changes=calculator.all_changes)
        calculator.Calculator.calculate(self, atoms=atoms, properties=properties,
                                        system_changes=system_changes)
        results = self.results  # Load old results

        # Run the SCF and update the energy
        scfres = isnothing(self.scfres) ? self.get_dftk_scfres() : self.scfres
        results["energy"] = sum(values(scfres.energies)) * ase_units.Hartree

        # Compute forces, if requested:
        if "forces" in properties
            # TODO If the calculation fails, ASE expects an
            #      calculator.CalculationFailed exception
            fvalues = hcat((Array(d) for fatom in forces(scfres) for d in fatom)...)'
            results["forces"] = fvalues * (ase_units.Hartree / ase_units.Bohr)
        end

        # Commit results and dump them to disk:
        self.results = results
        self.scfres = scfres
        self.write()
    end
end

end
