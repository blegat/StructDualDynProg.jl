export SDDP

type SDDPSolution
    status
    objval
    sol
    attrs
end

"""
$(SIGNATURES)

Runs one iteration of the SDDP algorithm on the lattice given by `g`.
A total of `Ktot` paths will be explored up to `num_stages` stages.
The paths will be selected according to `pathsampler` and equivalent paths might be merged if their difference is smaller than `ztol` and `mergepaths` is true.
The parameter `ztol` is also used to check whether a new cut is useful.
When a scenario is infeasible and `stopatinf` is true then no other scenario with the same ancestor is run. Note that since the order in which the different scenarios is run is not deterministic, this might introduce nondeterminism even if the sampling is deterministic.
"""
function iteration{S}(g::AbstractSDDPTree{S}, Ktot::Int, num_stages, verbose, pathsampler, stopatinf, mergepaths, ztol)
    stats = SDDPStats()

	master, initialstate = getmaster(g)
	StateT = typeof(initialstate)
    stats.solvertime += @_time mastersol = loadAndSolve(master)
    stats.nsolved += 1
    stats.niterations += 1
    infeasibility_detected = mastersol.status == :Infeasible
    if infeasibility_detected
        pathsd = Tuple{StateT, Vector{SDDPPath}}[]
    else
        pathsd = Tuple{StateT, Vector{SDDPPath}}[(initialstate, [SDDPPath(mastersol, [mastersol.objvalx], [1.], [Ktot], length(master.children))])]
    end
    endedpaths = SDDPPath[]

    for t in 2:num_stages
        if verbose >= 3
            println("Stage $t/$num_stages")
        end

        # Merge paths
        if mergepaths
            pathsd = mergesamepaths(pathsd, stats, ztol)
        end

        # Make jobs
        jobsd = Dict{StateT, Vector{SDDPJob}}()
        for (state, paths) in pathsd
			if haschildren(g, state)
                for path in paths
                    # Adding Jobs
                    npaths = samplepaths(pathsampler, g, state, path.K, t, num_stages)
					childocuts = Array{Any}(nchildren(g, state))
                    for i in 1:nchildren(g, state)
                        if t == 2 || sum(npaths[i]) != 0 || needallchildsol(cutgen(g, state))
							addjob!(jobsd, getchild(g, state, i), SDDPJob(path.proba * getproba(g, state, i), npaths[i], state, path, i))
                        end
                    end
                end
			else
                append!(endedpaths, paths)
            end
        end

        # Solve Jobs (parallelism possible here)
        for (state, jobs) in jobsd
            for job in jobs
                if !stopatinf || job.parent.childs_feasible
                    stats.setxtime += @_time setchildx(job.parentnode, job.i, job.parent.sol)
                    stats.nsetx += 1
                    stats.solvertime += @_time job.sol = loadAndSolve(state)
                    job.parent.childsols[job.i] = job.sol
                    stats.nsolved += 1
                    if get(job.sol).status == :Infeasible
                        job.parent.childs_feasible = false
                    elseif get(job.sol).status == :Unbounded
                        job.parent.childs_bounded = false
                    end
                end
            end
        end

        # Add cuts
        # Feasibility cut
        # D = π T
        # d = π h + σ d
        # Optimality cut
        # E = π T
        # e = π h + ρ e + σ d
        for (parent, paths) in pathsd
            for path in paths
                if path.childs_feasible
                    gencut(cutgen(g, parent), parent, path, stats, ztol)
                else
                    for i in 1:length(parent.children)
                        if !isnull(path.childsols[i])
                            childsol = get(path.childsols[i])
                            if childsol.status == :Infeasible
                                a = childsol.πT
                                β = childsol.πh + childsol.σd
                                infeasibility_detected = true
                                stats.nfcuts += 1
                                stats.fcutstime += @_time pushfeasibilitycut!(parent.children[i], a, β, parent)
                            end
                        end
                    end
                end
            end
        end

        # Apply cut addition
        for (state, paths) in pathsd
            for child in children(g, state)
                applyfeasibilitycut!(child)
            end
            applycut(cutgen(g, state), state, g)
        end

        # Jobs -> Paths
        empty!(pathsd)
        for (state, jobs) in jobsd
            K = [find(job.K .!= 0) for job in jobs]
            keep = find(Bool[jobs[i].parent.childs_feasible && !isempty(K[i]) for i in 1:length(jobs)])
            if !isempty(keep)
				paths = SDDPPath[SDDPPath(get(jobs[i].sol), jobs[i].parent.z[K[i]]+get(jobs[i].sol).objvalx, jobs[i].proba[K[i]], jobs[i].K[K[i]], nchildren(g, state)) for i in keep]
                push!(pathsd, (state, paths))
            end
        end
    end

    if infeasibility_detected
        z_UB = Inf # FIXME assumes minimization
        σ = 0
    else
        for (_, paths) in pathsd
            append!(endedpaths, paths)
        end
        z_UB, σ = meanstdpaths(endedpaths, Ktot)
    end

    # update stats
    stats.upperbound = z_UB
    stats.σ_UB = σ
    stats.npaths = Ktot
    stats.lowerbound = mastersol.objval

    mastersol, stats
end

"""
$(SIGNATURES)

Runs the SDDP algorithms on the lattice given by `g`.
The algorithm will do iterations until `stopcrit` decides to stop or when the root node is infeasible.
In each iterations, `K` paths will be explored up to `num_stages` stages.
The paths will be selected according to `pathsampler` and equivalent paths might be merged if their difference is smaller than `ztol` and `mergepaths` is true.
The parameter `ztol` is also used to check whether a new cut is useful.
When a scenario is infeasible and `stopatinf` is true then no other scenario with the same ancestor is run. Note that since the order in which the different scenarios is run is not deterministic, this might introduce nondeterminism even if the sampling is deterministic.
"""
function SDDP(g::AbstractSDDPTree, num_stages; K::Int=25, stopcrit::AbstractStoppingCriterion=Pereira(), verbose=0, pathsampler::AbstractPathSampler=ProbaPathSampler(true), mergepaths=true, ztol=1e-6, stopatinf=false)
    mastersol = nothing
    totalstats = SDDPStats()
    stats = SDDPStats()
    stats.niterations = 1

    while (mastersol === nothing || mastersol.status != :Infeasible) && !stop(stopcrit, stats, totalstats)
        itertime = @_time mastersol, stats = iteration(g, K, num_stages, verbose, pathsampler, stopatinf, mergepaths, ztol)
        stats.time = itertime

        totalstats += stats
        if verbose >= 2
            println("Iteration $(totalstats.niterations) completed in $itertime s (Total time is $(stats.time))")
            println("Status: $(mastersol.status)")
            println("Upper Bound: $(totalstats.upperbound)")
            println("Lower Bound: $(totalstats.lowerbound)")
            #println(" Solution value: $(mastersol.x)")
            println("Stats for this iteration:")
            println(stats)
            println("Total stats:")
            println(totalstats)
        end
    end

    if verbose >= 1
        println("SDDP completed in $(totalstats.niterations) iterations in $(totalstats.time) s")
        println("Status: $(mastersol.status)")
        #println("Objective value: $(mastersol.objval)")
        println("Upper Bound: $(totalstats.upperbound)")
        println("Lower Bound: $(totalstats.lowerbound)")
        #println(" Solution value: $(mastersol.x)")
        println("Total stats:")
        println(totalstats)
    end

    attrs = Dict()
    attrs[:stats] = totalstats
    attrs[:niter] = totalstats.niterations
    attrs[:nfcuts] = totalstats.nfcuts
    attrs[:nocuts] = totalstats.nocuts
    SDDPSolution(mastersol.status, mastersol.objval, mastersol.x, attrs)
end
