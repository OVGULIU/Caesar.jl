export
    Packed_Normal,
    Packed_MvNormal,
    Packed_AliasingScalarSampler

mutable struct Packed_Normal
  mean::Float64
  std::Float64
  distType::String
end

mutable struct Packed_MvNormal
  mean::Vector{Float64}
  cov::Vector{Float64}
  distType::String
end

mutable struct Packed_AliasingScalarSampler
  samples::Vector{Float64}
  weights::Vector{Float64}
  quantile::Nullable{Float64}
  distType::String # AliasingScalarSampler
end
