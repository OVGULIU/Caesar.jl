using Caesar
using DataFrames
using Test
using Distributions
using JSON
using CSV

function getCurFactors()::Vector{Type}
    return [
        subtypes(IncrementalInference.FunctorSingleton)...,
        subtypes(IncrementalInference.FunctorPairwise)...,
        subtypes(IncrementalInference.FunctorPairwiseMinimize)...];
end

function getCurVars()::Vector{Type}
    return subtypes(IncrementalInference.InferenceVariable);
end

vars = getCurVars();
factors = getCurFactors();

dfFactors = DataFrame(FactorType=factors, Name = string.(factors), ParentType = string.(supertype.(factors)))
dfFactors[:HasTestConstructor] = false
dfFactors[:CanSample] = false
dfFactors[:CanCallResidual] = false
dfFactors[:CanProtoPack] = false
dfFactors[:CanProtoUnpack] = false
dfFactors[:ProtoE2EWorks] = false
dfFactors[:CanJsonPack] = false
dfFactors[:CanJsonUnpack] = false
dfFactors[:JsonE2EWorks] = false
dfFactors[:Docs] = ""
sort!(dfFactors, (:Name))

for i = 1:length(factors)
    # 1. Get docs
    docStr = eval(Meta.parse("@doc $(dfFactors[:Name][i])"))
    dfFactors[:Docs][i] = string(docStr)
    dfFactors[:Docs][i] = startswith(dfFactors[:Docs][i], "No documentation found.") ? "No Documentation" : dfFactors[:Docs][i]

    try
        # 2. Pull the FactorTestingFlag constructor and make one.
        @show str = "$(factors[i])(FactorTestingFlag)"
        testFactor = eval(Meta.parse(str))
        @info "Successfully made a '$(factors[i])'"
        dfFactors[:HasTestConstructor][i] = true

        # 3. Can we call it's sampler for values?
        getSample(testFactor, 100)
        dfFactors[:CanSample][i] = true
        # 3b. Can we profile speed of sampler?

        # 4. Can we call residual?
        if isa(testFactor, FunctorPairwise) || isa(testFactor, FunctorPairwiseMinimize)
            #TODO - Dehann can you help here?
        end
        # 4b. Can we profile speed of residual function?

        # 5. Can we JSON pack it?
        try
            @show json = convert(Dict{String, Any}, testFactor)
            dfFactors[:CanJsonPack][i] = true
            @show back = convert(factors[i], json)
            dfFactors[:CanJsonUnpack][i] = true
            reback = convert(Dict{String, Any}, back)
            @show JSON.json(json)
            @show JSON.json(reback)
            dfFactors[:JsonE2EWorks][i] = JSON.json(json) == JSON.json(reback)
        catch ex
            @warn "Error when processing $(factors[i]) - $ex"
        end

        # 6. Can we find a packed type?
        try
            @show str = "Packed$(factors[i])"
            packedType = eval(Meta.parse(str))

            @show packed = convert(packedType, testFactor)
            dfFactors[:CanProtoPack][i] = true
            @show back = convert(factors[i], packed)
            dfFactors[:CanProtoUnpack][i] = true
            reback = convert(packedType, back)
            dfFactors[:ProtoE2EWorks][i] = JSON.json(packed) == JSON.json(reback)
        catch ex
            io = IOBuffer()
            showerror(io, ex, catch_backtrace())
            err = String(take!(io))
            @warn "Error when Proto packing/unpacking $(factors[i]) - $err"
        end

    catch ex
        @warn "Error when processing $(factors[i]) - $ex"
    end
end

CSV.write(joinpath(dirname(pathof(Caesar)), "..","test", "factorcompatibility", "FactorCompatibility.csv"), dfFactors)
