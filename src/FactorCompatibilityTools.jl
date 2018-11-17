"""
Internal function to get all factors in workspace.
"""
function getCurFactors()::Vector{Type}
    return [
        subtypes(IncrementalInference.FunctorSingleton)...,
        subtypes(IncrementalInference.FunctorPairwise)...,
        subtypes(IncrementalInference.FunctorPairwiseMinimize)...];
end

"""
Internal function to get all variables in workspace.
"""
function getCurVars()::Vector{Type}
    return subtypes(IncrementalInference.InferenceVariable);
end

function factorCompatibilityCheck(factor::Type)::Dict{Symbol, Any}
    res = Dict{Symbol, Any}(
        :Docs => "",
        :HasTestConstructor => false,
        :CanSample => false,
        :CanCallResidual => false,
        :CanJsonPack => false,
        :CanJsonUnpack => false,
        :JsonE2EWorks => false,
        :CanProtoPack => false,
        :CanProtoUnpack => false,
        :ProtoE2EWorks => false,
        :GeneralError => ""
    )

    # 1. Get docs
    docStr = eval(Meta.parse("@doc $(string(factor))"))
    res[:Docs] = string(docStr)
    res[:Docs] = startswith(res[:Docs], "No documentation found.") ? "No Documentation" : res[:Docs]

    try
        # 2. Pull the FactorTestingFlag constructor and make one.
        @show str = "$(factor)(FactorTestingFlag)"
        testFactor = eval(Meta.parse(str))
        @info "Successfully made a '$(factor)'"
        res[:HasTestConstructor] = true

        # 3. Can we call it's sampler for values?
        getSample(testFactor, 100)
        res[:CanSample] = true
        # 3b. Can we profile speed of sampler?

        # 4. Can we call residual?
        if isa(testFactor, FunctorPairwise) || isa(testFactor, FunctorPairwiseMinimize)
            #TODO - Dehann can you help here?
        end
        # 4b. Can we profile speed of residual function?

        # 5. Can we JSON pack it?
        try
            @show json = convert(Dict{String, Any}, testFactor)
            res[:CanJsonPack] = true
            @show back = convert(factor, json)
            res[:CanJsonUnpack] = true
            reback = convert(Dict{String, Any}, back)
            @show JSON.json(json)
            @show JSON.json(reback)
            res[:JsonE2EWorks] = JSON.json(json) == JSON.json(reback)
        catch ex
            io = IOBuffer()
            showerror(io, ex, catch_backtrace())
            err = String(take!(io))
            res[:JsonError] = err
            @warn "Error when processing $factor - $err"
        end

        # 6. Can we find a packed type?
        try
            @show str = "Packed$(factor)"
            packedType = eval(Meta.parse(str))

            @show packed = convert(packedType, testFactor)
            res[:CanProtoPack] = true
            @show back = convert(factor, packed)
            res[:CanProtoUnpack] = true
            reback = convert(packedType, back)
            res[:ProtoE2EWorks] = JSON.json(packed) == JSON.json(reback)
        catch ex
            io = IOBuffer()
            showerror(io, ex, catch_backtrace())
            err = String(take!(io))
            res[:ProtoError] = err
            @warn "Error when processing $factor - $err"
        end

    catch ex
        io = IOBuffer()
        showerror(io, ex, catch_backtrace())
        err = String(take!(io))
        res[:GeneralError] = err
        @warn "Error when processing $factor - $err"
    end

    return res
end

"""
    $(SIGNATURES)

Check all factors in the current workspace. Returns the results as a vector.
"""
function checkCurrentFactors()::Vector{Dict{Symbol, Any}}
    res = Vector{Dict{Symbol, Any}}();
    for f in getCurFactors()
        push!(res, factorCompatibilityCheck(f));
    end
    return res;
end
