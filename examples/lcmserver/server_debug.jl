#=
LCM Server: an LCM interface to Caesar.jl

=#

using JLD
using Caesar, RoME
using TransformUtils, Rotations, CoordinateTransformations
using Distributions
using PyCall, PyLCM
using LibBSON
using CloudGraphs # for sorryPedro

function gen_bindings()
    @show lcmtpath = joinpath(dirname(@__FILE__),"lcmtypes")
    run(`lcm-gen -p --ppath $(lcmtpath) $(lcmtpath)/rome_point_cloud_t.lcm`)
    run(`lcm-gen -p --ppath $(lcmtpath) $(lcmtpath)/rome_pose_node_t.lcm`)
    run(`lcm-gen -p --ppath $(lcmtpath) $(lcmtpath)/rome_pose_pose_nh_t.lcm`)
    run(`lcm-gen -p --ppath $(lcmtpath) $(lcmtpath)/rome_pose_pose_xyh_t.lcm`)
    run(`lcm-gen -p --ppath $(lcmtpath) $(lcmtpath)/rome_prior_zpr_t.lcm`)
    println("Adding lcmtypes dir to Python path: $(lcmtpath)")
    unshift!(PyVector(pyimport("sys")["path"]),lcmtpath)
end

println("[Caesar.jl] (re)generating LCM bindings")
gen_bindings()

println("[Caesar.jl] Importing LCM message types")
@pyimport rome


function initialize!(backend_config,
                    user_config)
    # TODO: init interface should be made cleaner/more straight forward
    println("[Caesar.jl] Setting up factor graph")
    fg = Caesar.initfg(sessionname=user_config["session"], cloudgraph=backend_config)
    println("[Caesar.jl] Creating SLAM client/object")
    return  SLAMWrapper(fg, nothing, 0)
end

function sorryPedro(cg::CloudGraph, session::AbstractString)
  hauvconfig = Dict()
  hauvconfig["robot"] = "hauv"
  hauvconfig["bTc"] = [0.0;0.0;0.0; 1.0; 0.0; 0.0; 0.0]
  hauvconfig["bTc_format"] = "xyzqwqxqyqz"
  # currently unused, but upcoming
  hauvconfig["pointcloud_description_name"] = "BSONpointcloud"
  hauvconfig["pointcloud_color_description_name"] = "BSONcolors"
  # robotdata = json(hauvconfig).data

  # Actually modify the databases
  insertrobotdatafirstpose!(cg, session, hauvconfig)
  nothing
end

"""

Adds pose nodes to graph with a prior on Z, pitch, and roll.
"""
function handle_poses!(slam::SLAMWrapper,
                       message_data)

    println("[Caesar.jl] Received message ")
    message = rome.pose_node_t[:decode](message_data)

    id = message[:id]

    mean = message[:mean]
    covar = message[:covar]
    t = [mean[1], mean[2], mean[3]]
    qw = mean[4]
    qxyz = [mean[5], mean[6], mean[7]]
    q = Quaternion(qw,qxyz) # why not a (w,x,y,z) constructor?
    pose = SE3(t,q)
    # euler = Euler(q)

    node_label = Symbol("x$(id)")
    xn = addNode!(slam.fg, node_label, labels=["POSE"], dims=6) # this is an incremental inference call
    slam.lastposesym = node_label; # update object

    if id == 1
        println("[Caesar.jl] First pose")
        # this is the first message, and it does not carry odometry, but the prior on the first node.

        # add 6dof prior
        initPosePrior = PriorPose3( MvNormal( veeEuler(pose), diagm([covar...]) ) )
        addFactor!(slam.fg, [xn], initPosePrior)

        # auto init is coming, this code will likely be removed
        initializeNode!(slam.fg, node_label)

        # set robot parameters in the first pose, this will become a separate node in the future
        sorryPedro(slam.fg.cg, slam.fg.sessionname)
    end
end

function handle_priors!(slam::SLAMWrapper,
                         message_data)

    println("[Caesar.jl] Adding prior on RPZ")

    message = rome.prior_zpr_t[:decode](message_data)

    id = message[:id]
    node_label = Symbol("x$(id)")
    xn = getVert(slam.fg,node_label)

    z = message[:z]
    pitch = message[:pitch]
    roll = message[:roll]

    var_z = message[:var_z]
    var_pitch = message[:var_pitch]
    var_roll = message[:var_roll]

    rp_dist = MvNormal( [roll;pitch], diagm([var_roll, var_pitch]))
    z_dist = Normal(z, var_z)
    prior_rpz = PartialPriorRollPitchZ(rp_dist, z_dist)
    addFactor!(slam.fg, [xn], prior_rpz)
end


function handle_partials!(slam::SLAMWrapper,
                         message_data)
    # add XYH factor
    println("[Caesar.jl] Adding odometry constraint on XYH")

    message = rome.pose_pose_xyh_t[:decode](message_data)

    origin_id = message[:node_1_id]
    destination_id = message[:node_2_id]
    origin_label = Symbol("x$(origin_id)")
    destination_label = Symbol("x$(destination_id)")

    delta_x = message[:delta_x]
    delta_y = message[:delta_y]
    delta_yaw = message[:delta_yaw]

    var_x = message[:var_x]
    var_y = message[:var_y]
    var_yaw = message[:var_yaw]

    xo = getVert(slam.fg,origin_label)
    xd = getVert(slam.fg,destination_label)

    xyh_dist = MvNormal([delta_x, delta_y, delta_yaw], diagm([var_x, var_y, var_yaw]))
    xyh_factor = PartialPose3XYYaw(xyh_dist)
    addFactor!(slam.fg, [xo;xd], xyh_factor)


    initializeNode!(slam.fg, destination_label)
end


"""
   handle_clouds(slam::SLAMWrapper, message_data)

Callback for rome_point_cloud_t messages. Adds point cloud to SLAM_Client
"""
function handle_clouds!(slam::SLAMWrapper,
                        message_data)
    # TODO: interface here should be as simple as slam_client.add_pointcloud(pc::SomeCloudType)

    message = rome.point_cloud_t[:decode](message_data)

    id = message[:id]

    last_pose = Symbol("x$(id)")
    println("[Caesar.jl] Got cloud $id")

    # TODO: check if vert exists or not (may happen if messages are lost or out of order)
    vert = getVert(slam.fg, last_pose, api=IncrementalInference.dlapi) # fetch from database

    # 2d arrays of points and colors (from LCM data into arrays{arrays})
    points = [[pt[1], pt[2], pt[3]] for pt in message[:points]]
    colors = [[UInt8(c.data[1]),UInt8(c.data[2]),UInt8(c.data[3])] for c in message[:colors]]

    # push to mongo (using BSON as a quick fix)
    # (for deserialization, see src/DirectorVisService.jl:cachepointclouds!)
    serialized_point_cloud = BSONObject(Dict("pointcloud" => points))
    appendvertbigdata!(slam.fg, vert, "BSONpointcloud", string(serialized_point_cloud).data)
    serialized_colors = BSONObject(Dict("colors" => colors))
    appendvertbigdata!(slam.fg, vert, "BSONcolors", string(serialized_colors).data)
end

# this function handles lcm messages
function listener!(slam::SLAMWrapper,
                   lcm_node::LCMCore.LCM)

    # handle traffic
    while true
        handle(lcm_node)
    end
end


# prepare the factor graph with just one node
# (will prompt on stdin for db credentials)
# TODO: why keep usrcfg and backendcfg? the former contains the latter
#println("[Caesar.jl] Prompting user for configuration")
 # @load "usercfg.jld"
include(joinpath(dirname(@__FILE__),"..","database","blandauthremote.jl"))
user_config = addrdict
user_config["session"] = "SESSHAUVDEV5"
backend_config, user_config = standardcloudgraphsetup(addrdict=user_config)

# Juno.breakpoint("/home/dehann/.julia/v0.5/CloudGraphs/src/CloudGraphs.jl", 291)

# TODO: need better name for "slam_client"
println("[Caesar.jl] Setting up local solver")
slam_client = initialize!(backend_config,user_config)
# TODO: should take default install values as args?
# TODO: supress/redirect standard server output to log
# NOTE: "Please also enter information for:"

# create new handlers to pass in additional data
lcm_pose_handler = (channel, message_data) -> handle_poses!(slam_client, message_data )
lcm_odom_handler = (channel, message_data) -> handle_partials!(slam_client, message_data )
lcm_prior_handler = (channel, message_data) -> handle_priors!(slam_client, message_data )
lcm_cloud_handler = (channel, message_data) -> handle_clouds!(slam_client, message_data )

# create LCM object and subscribe to messages on the following channels
lcm_node = LCM()
subscribe(lcm_node, "ROME_POSES", lcm_pose_handler)
subscribe(lcm_node, "ROME_PARTIAL_XYH", lcm_odom_handler)
subscribe(lcm_node, "ROME_PARTIAL_ZPR", lcm_prior_handler)
subscribe(lcm_node, "ROME_POINT_CLOUDS", lcm_cloud_handler)

println("[Caesar.jl] Running LCM listener")
@async listener!(slam_client, lcm_node)

println("waiting for compilation")
sleep(5.0)
println("assuming compilation is done and moving on.")

# need some data


# send the first pose
msg = rome.pose_node_t()
msg[:utime] = 0
msg[:id] = 1
msg[:mean_dim] = 7
msg[:mean] = Float64[0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0]
msg[:covar_dim] = 6
msg[:covar] = Float64[0.001, 0.001, 0.001, 0.001, 0.001, 0.001]

publish(lcm_node, "ROME_POSES", msg)
sleep(0.01)

# send the second pose
msg = rome.pose_node_t()
msg[:utime] = 0
msg[:id] = 2
msg[:mean_dim] = 7
msg[:mean] = Float64[-1.0, -1.0, -1.0, 0.0, 0.0, 0.0, -1.0]
msg[:covar_dim] = 6
msg[:covar] = Float64[0.001, 0.001, 0.001, 0.001, 0.001, 0.001]

publish(lcm_node, "ROME_POSES", msg)
sleep(0.01)

# send zpr for x2
msg = rome.prior_zpr_t()
msg[:utime] = 0
msg[:id] = 2
msg[:z] = 0.0
msg[:pitch] = 0.0
msg[:roll] = 0.0
msg[:var_z] = 0.001
msg[:var_pitch] = 0.001
msg[:var_roll] = 0.001

publish(lcm_node, "ROME_PARTIAL_ZPR", msg)
sleep(0.01)

# send first zpr
msg = rome.pose_pose_xyh_t()
msg[:utime] = 0
msg[:node_1_utime] = 0
msg[:node_1_id] = 1

msg[:node_2_utime] = 0
msg[:node_2_id] = 2

msg[:delta_x] = 20.0
msg[:delta_y] = 0.0
msg[:delta_yaw] = 0.0

msg[:var_x] = 0.001
msg[:var_y] = 0.001
msg[:var_yaw] = 0.001

publish(lcm_node, "ROME_PARTIAL_XYH", msg)




## ========================================================================== ##

# send the first pose
msg = rome.pose_node_t()
msg[:utime] = 0
msg[:id] = 1
msg[:mean_dim] = 7
q1 = convert(Quaternion, Euler(0.155858, -0.0151844, 2.14152))
msg[:mean] = Float64[16.3, 1.15, 5.78, q1.s, q1.v...]
msg[:covar_dim] = 6
msg[:covar] = Float64[0.001, 0.001, 0.001, 0.001, 0.001, 0.001]
publish(lcm_node, "ROME_POSES", msg)
sleep(0.01)


# send the second pose
msg = rome.pose_node_t()
msg[:utime] = 0
msg[:id] = 2
msg[:mean_dim] = 7
q2 = convert(Quaternion, Euler(0.23285, 0.000118684, 2.28345))
wTx2 = SE3([18.7389, 2.31, 5.77108], q2)
msg[:mean] = Float64[wTx2.t..., q2.s, q2.v...]
msg[:covar_dim] = 6
msg[:covar] = Float64[0.001, 0.001, 0.001, 0.001, 0.001, 0.001]
publish(lcm_node, "ROME_POSES", msg)
sleep(0.01)

msg = rome.prior_zpr_t()
msg[:utime] = 0
msg[:id] = 2
msg[:z] = 5.77108
msg[:pitch] = 0.000118684
msg[:roll] = 0.23285
msg[:var_z] = 0.01
msg[:var_pitch] = 0.001
msg[:var_roll] = 0.001
publish(lcm_node, "ROME_PARTIAL_ZPR", msg)
sleep(0.01)

msg = rome.pose_pose_xyh_t()
msg[:utime] = 0
msg[:node_1_utime] = 0
msg[:node_1_id] = 1
msg[:node_2_utime] = 0
msg[:node_2_id] = 2
msg[:delta_x] = -0.341546
msg[:delta_y] = -2.64716
msg[:delta_yaw] = 0.137918
msg[:var_x] = 0.001
msg[:var_y] = 0.001
msg[:var_yaw] = 0.001
publish(lcm_node, "ROME_PARTIAL_XYH", msg)



# send the third pose
msg = rome.pose_node_t()
msg[:utime] = 0
msg[:id] = 3
msg[:mean_dim] = 7
q3 = convert(Quaternion, Euler(0.196432, 0.00841811, 2.37419))
wTx3 = SE3([21.0984, 3.44, 5.75921], q3)
msg[:mean] = Float64[wTx3.t..., q3.s, q3.v...]
msg[:covar_dim] = 6
msg[:covar] = Float64[0.001, 0.001, 0.001, 0.001, 0.001, 0.001]
publish(lcm_node, "ROME_POSES", msg)
sleep(0.01)

msg = rome.prior_zpr_t()
msg[:utime] = 0
msg[:id] = 3
msg[:z] = 5.75921
msg[:pitch] = 0.00841811
msg[:roll] = 0.196432
msg[:var_z] = 0.01
msg[:var_pitch] = 0.001
msg[:var_roll] = 0.001

x2Tx3 = wTx2\wTx3
wRx2 = SE3(zeros(3), wTx2.R)
wTx2x3 = wRx2*x2Tx3
wTx2x3_wxyh = SE3([wTx2x3.t[1:2]...,0.0], Euler(0.0,0.0,convert(Euler, wTx2x3.R).Y))
x2Tx3_wxyh = wRx2\wTx2x3_wxyh
msg = rome.pose_pose_xyh_t()
msg[:utime] = 0
msg[:node_1_utime] = 0
msg[:node_1_id] = 2
msg[:node_2_utime] = 0
msg[:node_2_id] = 3
msg[:delta_x] = wTx2x3.t[1]
msg[:delta_y] = wTx2x3.t[2]
msg[:delta_yaw] = convert(Euler, wTx2x3.R).Y
msg[:var_x] = 0.001
msg[:var_y] = 0.001
msg[:var_yaw] = 0.001
publish(lcm_node, "ROME_PARTIAL_XYH", msg)



slam_client


plotKDE(slam_client.fg, :x2, dims=[2;3])


#
