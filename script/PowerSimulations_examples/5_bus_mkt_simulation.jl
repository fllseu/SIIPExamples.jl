# # 5-bus Market simulation with [PowerSimulations.jl](https://github.com/NREL/PowerSimulations.jl)

# **Originally Contributed by**: Clayton Barrows

# ## Introduction

# PowerSimulations.jl supports simulations that consist of sequential optimization problems
# where results from previous problems inform subsequent problems in a variety of ways. This
# example demonstrates some of these capabilities to represent electricitty market clearing.

# ## Dependencies and Data
# First, let's create `System`s to represent the Day-Ahead and Real-Time market clearing
# process with hourly, and 5-minute forecast data, respectively.
using SIIPExamples
pkgpath = dirname(dirname(pathof(SIIPExamples)))
# ### Modeling Packages
using InfrastructureSystems
const IS = InfrastructureSystems
using PowerSystems
const PSY = PowerSystems
using PowerSimulations
const PSI = PowerSimulations

# ### Data management packages
using Dates
using DataFrames

# ### Optimization packages
using JuMP
using Cbc #solver
solver = optimizer_with_attributes(Cbc.Optimizer, "logLevel" => 1, "ratioGap" => 0.5)

# ### 5-bus Data
# The five bus system data here includes hourly day-ahead data, 5-minute real-time market
# data, and 6-scond actual data.
base_dir = PSY.download(PSY.TestData; branch = "5-bus-ts");
pm_data = PSY.PowerModelsData(joinpath(base_dir, "matpower", "case5_re_uc.m"))

FORECASTS_DIR = joinpath(base_dir,"forecasts","5bus_ts","7day")

tsp_da = IS.read_time_series_metadata(joinpath(FORECASTS_DIR,"timeseries_pointers_da_7day.json"))
tsp_rt = IS.read_time_series_metadata(joinpath(FORECASTS_DIR,"timeseries_pointers_rt_7day.json"))
tsp_agc = IS.read_time_series_metadata(joinpath(FORECASTS_DIR,"timeseries_pointers_agc_7day.json"))

sys_DA = System(pm_data)
reserves = [VariableReserve{ReserveUp}("REG1", 5.0, 0.1),
            VariableReserve{ReserveUp}("REG2", 5.0, 0.06),
            VariableReserve{ReserveUp}("REG3", 5.0, 0.03),
            VariableReserve{ReserveUp}("REG4", 5.0, 0.02)]
contributing_devices = get_components(Generator, sys_DA)
for r in reserves
    add_service!(sys_DA, r, contributing_devices)
end

add_forecasts!(sys_DA, tsp_da)

sys_RT = System(pm_data)
add_forecasts!(sys_RT, tsp_rt)

sys_AGC = System(pm_data)
add_forecasts!(sys_AGC, tsp_agc)

# ## `OperationsProblemTemplate`s
template_uc = template_unit_commitment()
devices = Dict(
    :Generators => DeviceModel(ThermalStandard, ThermalDispatch),
    :Ren => DeviceModel(RenewableDispatch, RenewableFullDispatch),
    :Loads => DeviceModel(PowerLoad, StaticPowerLoad),
    :HydroROR => DeviceModel(HydroDispatch, HydroDispatchRunOfRiver),
    :RenFx => DeviceModel(RenewableFix, RenewableFixed),
)
template_ed = template_economic_dispatch(devices = devices)

# ### Define the Simulation Sequence

stages_definition = Dict("UC" => Stage(GenericOpProblem, template_uc, sys_DA, solver),
                         "ED" => Stage(GenericOpProblem, template_ed, sys_RT, solver))


feedforward_chronologies = Dict(("UC" => "ED") => Synchronize(periods = 24))

feedforward = Dict(("ED", :devices, :Generators) => SemiContinuousFF(binary_from_stage = PSI.ON,
                                                         affected_variables = [PSI.ACTIVE_POWER]))

cache = Dict("UC" => [TimeStatusChange(PSY.ThermalStandard, PSI.ON)])

order = Dict(1 => "UC", 2 => "ED")
horizons = Dict("UC" => 24, "ED" =>12)
intervals = Dict("UC" => (Hour(24), Consecutive()),
                 "ED" => (Hour(1), Consecutive()))

DA_RT_sequence = SimulationSequence(step_resolution = Hour(24),
                                    order = order,
                                    horizons = horizons,
                                    intervals = intervals,
                                    ini_cond_chronology = InterStageChronology(),
                                    feedforward_chronologies = feedforward_chronologies,
                                    feedforward = feedforward,
                                    #cache = cache,
                                    )

# ## `Simulation`

file_path = tempdir()
sim = Simulation(name = "5bus-test",
                steps = 1,
                stages = stages_definition,
                stages_sequence = DA_RT_sequence,
                simulation_folder = file_path)

# ### Build simulaiton

build!(sim)

# ### Execute simulation

sim_results = execute!(sim)

# ## Results
uc_results = load_simulation_results(sim_results, "UC");
ed_results = load_simulation_results(sim_results, "ED");

