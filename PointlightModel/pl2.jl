using Makie
using AbstractPlotting
using MakieLayout
using Gen
using LinearAlgebra
using LightGraphs
using MetaGraphs
using Random
using Images
using TikzGraphs
using TikzPictures
using ShiftedArrays
using ColorSchemes
using Statistics
using StatsBase

#- One main question is whether we are going to try to reconstruct the identity after the fact. I.e. Are the xs and ys completely known in time and space We can do simultaneous inference on x and y values wrt t. Can also do sequential monte carlo. 

#- starting with init positions b/c this is the type of custom proposal you will get from the tectum. you won't get offests for free. this model accounts for distance effects and velocity effects by traversing the tree. 

#- One thing you might want to think about is keeping the same exact structure but resampling the timeseries. If you do this, may be a good way to test good choices in structure vs sample.

#want a balance between inferability and smoothness
framerate = 60
time_duration = 10
num_velocity_points = time_duration * 4
#num_velocity_points = time_duration*framerate

# filling in n-1 samples for every interpolation, where n is the
# length of the velocity vector. your final amount of samples doubles this each time, then adds 1. 
interp_iters = round(Int64, log(2, (framerate * time_duration) / (num_velocity_points -1)))


function interpolate_coords(vel, iter)
    if iter == 0
        return vel
    else
        interped_vel = vcat([[vel[i], mean([vel[i], vel[i+1]])] for i in 1:length(vel)-1]...)
        push!(interped_vel, vel[end])
        interpolate_coords(vcat(interped_vel...), iter-1)        
    end
end


@gen function populate_edges(motion_tree::MetaDiGraph{Int64, Float64},
                             candidate_pairs::Array{Tuple, 1})
    if isempty(candidate_pairs)
        return motion_tree
    end
    (current_dot, cand_parent) = first(candidate_pairs)
    if has_edge(motion_tree, current_dot, cand_parent) || ne(motion_tree) == nv(motion_tree) - 1
        add_edge = { (:edge, cand_parent, current_dot) } ~  bernoulli(0)

    else
        if isempty(inneighbors(motion_tree, cand_parent))
            add_edge = { (:edge, cand_parent, current_dot) } ~  bernoulli(.3)
        else
            add_edge = { (:edge, cand_parent, current_dot) } ~  bernoulli(.1)
        end
    end
    if add_edge
        add_edge!(motion_tree, cand_parent, current_dot)
    end
    {*} ~ populate_edges(motion_tree, candidate_pairs[2:end])
end

# note that the graphs can all be mutated. if your arg set is constant, it will still be manipulated if it was created
# as a variable. declared arg variables mutate inside a generative function.

# note that if you constrain generate_dotmotion on an unallowable edge (e.g. [1,3]), it wont prevent the inverse edge from being true.
# have to specify all edges at once. 

# make sure to arrange dots before entering assign_positions_and_velocities function
# have to specify position and velocity of all parents first b/c child nodes depend on it.
# arranging by number of inneighbors first and outneighbors second (inverted) guarantees parents
# are specified before children. 

@gen function generate_dotmotion(ts::Array{Float64}, 
                                 n_dots::Int)
    motion_tree = MetaDiGraph(n_dots)
    order_distribution = return_dot_distribution(n_dots)
    perceptual_order = { :order_choice } ~ order_distribution()
    candidate_edges = [p for p in Iterators.product(perceptual_order, perceptual_order) if p[1] != p[2]]
    motion_tree_updated = {*} ~ populate_edges(motion_tree, candidate_edges)
    dot_list = sort(collect(1:nv(motion_tree_updated)),
                    by=ϕ->(size(inneighbors(motion_tree_updated, ϕ))[1],
                           -1*size(outneighbors(motion_tree_updated, ϕ))[1]))
    motion_tree_assigned = {*} ~ assign_positions_and_velocities(motion_tree_updated,
                                                                 dot_list,
                                                                 ts)
    # motion_tree_assigned = {*} ~ assign_positions(motion_tree_updated,
    #                                               dot_list,
    #                                               ts)
    return motion_tree_assigned, dot_list
end


@gen function assign_positions(motion_tree::MetaDiGraph{Int64, Float64},
                               dots::Array{Int64}, ts::Array{Float64})
    if isempty(dots)
        return motion_tree
    else
        dot = first(dots)
        parents = inneighbors(motion_tree, dot)
        #   start_x = 10
        offset_x = {(:offset_x, dot)} ~ uniform_discrete(-5, 5)
        offset_y = {(:offset_y, dot)} ~ uniform_discrete(-5, 5)
        if isempty(parents)
            x_pos_mean = offset_x * ones(length(ts))
            y_pos_mean = offset_y * ones(length(ts))
        else
            parent_positions_x = [props(motion_tree, p)[:Position_X] for p in parents]
            parent_positions_y = [props(motion_tree, p)[:Position_Y] for p in parents]
            if size(parents)[1] > 1
                x_pos_mean = [offset_x + mx for mx in mean(parent_positions_x)]
                y_pos_mean = [offset_y + my for my in mean(parent_positions_y)]
            else
                x_pos_mean = [offset_x + px for px in parent_positions_x[1]]
                y_pos_mean = [offset_y + py for py in parent_positions_y[1]]
            end
        end
        cov_func = {*} ~ covariance_simple(dot)
        noise = 0.001
        covmat_x = compute_cov_matrix_vectorized(cov_func, noise, ts)
        covmat_y = compute_cov_matrix_vectorized(cov_func, noise, ts)
#        covmat_y = covmat_x
        #        x_vel = {(:x_vel, dot)} ~ mvnormal(zeros(length(ts)), covmat_x)
        x_pos = {(:x_pos, dot)} ~ mvnormal(x_pos_mean, covmat_x)
        y_pos = {(:y_pos, dot)} ~ mvnormal(y_pos_mean, covmat_y)
#        y_vel = [0 for xv in x_vel]
        # Sample from the GP using a multivariate normal distribution with
        # the kernel-derived covariance matrix.
        set_props!(motion_tree, dot,
                   Dict(:Position_X=>x_pos, :Position_Y=>y_pos))
        {*} ~ assign_positions(motion_tree, dots[2:end], ts)
    end
end    


@gen function assign_positions_and_velocities(motion_tree::MetaDiGraph{Int64, Float64},
                                              dots::Array{Int64}, ts::Array{Float64})
    position_var = 1
    if isempty(dots)
        return motion_tree
    else
        dot = first(dots)
        parents = inneighbors(motion_tree, dot)
     #   start_x = 10
        if isempty(parents)
            start_x = {(:start_x, dot)} ~ uniform_discrete(-5, 5)
            start_y = {(:start_y, dot)} ~ uniform_discrete(-5, 5)
            x_vel_mean = zeros(length(ts))
            y_vel_mean = zeros(length(ts))
        else
            if size(parents)[1] > 1
                avg_parent_position = mean([props(motion_tree, p)[:Position] for p in parents])
                parent_position = [round(Int, pp) for pp in avg_parent_position]
            else
                parent_position = props(motion_tree, parents[1])[:Position]
            end
          #  start_x = {(:start_x, dot)} ~ normal(parent_position[1], position_var)
          #  start_y = {(:start_y, dot)} ~ normal(parent_position[2], position_var)
            start_x = {(:start_x, dot)} ~ uniform_discrete(parent_position[1]-1, parent_position[1]+1)
            start_y = {(:start_y, dot)} ~ uniform_discrete(parent_position[2]-1, parent_position[2]+1)
            parent_velocities_x = [props(motion_tree, p)[:Velocity_X] for p in parents]
            parent_velocities_y = [props(motion_tree, p)[:Velocity_Y] for p in parents]
        end

        if !isempty(parents)
            if size(parents)[1] == 1
                x_vel_mean = parent_velocities_x[1]
                y_vel_mean = parent_velocities_y[1]
            else
                x_vel_mean = sum(parent_velocities_x)
                y_vel_mean = sum(parent_velocities_y)
            end
        end
        cov_func = {*} ~ covariance_simple(dot)
        noise = 0.001
        covmat = compute_cov_matrix_vectorized(cov_func, noise, ts)
        x_vel = {(:x_vel, dot)} ~ mvnormal(x_vel_mean, covmat)
        y_vel = {(:y_vel, dot)} ~ mvnormal(y_vel_mean, covmat)
#        y_vel = [0 for xv in x_vel]
        # Sample from the GP using a multivariate normal distribution with
        # the kernel-derived covariance matrix.
        set_props!(motion_tree, dot,
                   Dict(:Position=>[start_x, start_y], :Velocity_X=>x_vel, :Velocity_Y=>y_vel))
        {*} ~ assign_positions_and_velocities(motion_tree, dots[2:end], ts)
    end
end    

#start with this just being the simulated data itself. eventually have it be a biophysical implementation of a
# tectal map

# function neural_detector()
#     neural_constraints = Gen.choicemap()
#     neural_constraints[:start_x] = 0.1
#     neural_constraints[:start_y] = 0.1

    
# end


# possibly generate an R and theta
# key frame stimulus, then what you should see, then posterior with labels. 
# get alex involved in his input about metaPPL reformulation

# label everything with legends, ground truth, enumerated posterior,
# have stim come first.

# slide explaining generative model, and inference strategy that is plausible.
# one slide with ~16 samples from the prior. ground truth graph, underneath the dot movie.
# schematic of the generative process. use ben's probprog talk as a guide.
# "see inside the mind of the computer" helps people realize what's going on.
# SMC algorithm -- copy slide 57 which basically shows perfect SMC.

# talk to george about biophysical realism. 

# research design document for object permanence and dot binding experiments.

# nicely labeled TIE animation first
# gslides
# amanda + rachel. update them on the structure of the planning.
# implement tracking of paramecia under strobing. is there latent structure in the brain of the fish?

#compare ideal bayesian observer plus human data. mechanical turk.
# train a neural net and hsow it doesn't work well. 


# make this able to take various lenghts of ts and update with SMC

function loopfilter(edges, truthtab)
    filtered_truthtab = []
    for t_entry in truthtab
        edges_in_entry = [e for (e,t) in zip(edges, t_entry) if t==1]
        if !any(map(x -> (x[2], x[1]) in edges_in_entry, edges_in_entry))
            push!(filtered_truthtab, t_entry)
        end
    end
    return filtered_truthtab
end


#current thought is the difference bewteen update here and in test_assignment is that the
# tree is already established. inferring the kernel function works. this does not, because
# the total score (update) depends on the prior on trees. if you use generate, while constraining on the trees and kernels,
# you get back the prior b/c they aren't dependent.

# biggest problem -- you do not have any way of reporting back inheritance. this is critical! currently feeding in the
# velocities, but not the outcomes. 


function animate_inference(trace::Gen.DynamicDSLTrace{DynamicDSLFunction{Any}})
    num_dots = nv(get_retval(trace)[1])
    kernel_combos = [kernel_types for i in 1:num_dots]
    kernel_choices = collect(Iterators.product(kernel_combos...))
    possible_edges = [(i, j) for i in 1:num_dots for j in 1:num_dots if i != j]
    truth_entry = [[0,1] for i in 1:size(possible_edges)[1]]
    unfiltered_truthtable = [j for j in Iterators.product(truth_entry...) if sum(j) < num_dots]
    # filters trees with n_dot or more edges
    edge_truthtable = loopfilter(possible_edges, unfiltered_truthtable)
    # here you will have a list of traces
    counts = []
    truth_trace, edge_samples, vel_samples = imp_inference(trace)
    joint_edge_vel = [(Tuple(e), Tuple(v)) for (e,v) in zip(edge_samples, vel_samples)]
    for eg in edge_truthtable
        for kc in kernel_choices
            ev_count = count(λ -> (λ[1] == eg && λ[2] == kc), joint_edge_vel)
            push!(counts, ev_count)
        end
    end
    count_matrix = reshape(counts, prod(collect(size(kernel_choices))), size(edge_truthtable)[1])
    plotvals = [count_matrix, kernel_choices, possible_edges, edge_truthtable]
    return plotvals
end                



function enumerate_possibilities(trace::Gen.DynamicDSLTrace{DynamicDSLFunction{Any}})
    num_dots = nv(get_retval(trace)[1])
    kernel_combos = [kernel_types for i in 1:num_dots]
    kernel_choices = collect(Iterators.product(kernel_combos...))
    possible_edges = [(i, j) for i in 1:num_dots for j in 1:num_dots if i != j]
    truth_entry = [[0,1] for i in 1:size(possible_edges)[1]]
    # filters trees with n_dot or more edges
    unfiltered_truthtable = [j for j in Iterators.product(truth_entry...) if sum(j) < num_dots]
    edge_truthtable = loopfilter(possible_edges, unfiltered_truthtable)
  #  enum_constraints = Gen.choicemap(get_choices(trace))
    trace_args = get_args(trace)
    trace_choices = get_choices(trace)
    trace_retval = get_retval(trace)
    # have to also filter trees with loops
    scores = []
    for eg in edge_truthtable
        enum_constraints = Gen.choicemap()
      #  enum_constraints = Gen.choicemap(trace_choices)
        for (eg_id, e) in enumerate(eg)
            if e == 1
                enum_constraints[(:edge, possible_edges[eg_id][1], possible_edges[eg_id][2])] = true
            else
                enum_constraints[(:edge, possible_edges[eg_id][1], possible_edges[eg_id][2])] = false
            end
        end
        for kc in kernel_choices
            for (dot, k) in enumerate(kc)
                enum_constraints[(:kernel_type, dot)] = k
            end

            # first test is to constrain on the X value but force tree and motion type structure (without scoring).
            # 
            
            # here pass the tree through another round of noise generation. will mimic difference between generated and perceived velocities.
            # bug here is that the same velocity just keeps replenishing. have to clear the velocity before updating it, bc you're constrainig
            # on it here after one sample, which is why first column is YELLOW. 
            # (ass_trace, w) = Gen.generate(assign_positions_and_velocities, (trace_retval[1], trace_retval[2], trace_args[1]), enum_constraints)
            for i in 1:num_dots
                enum_constraints[(:x_vel, i)] = trace[(:x_vel, i)]
                enum_constraints[(:y_vel, i)] = trace[(:y_vel, i)]
                enum_constraints[(:start_x, i)] = trace[(:start_x, i)]
                enum_constraints[(:start_y, i)] = trace[(:start_y, i)]
            end
            (new_trace, w, a, ad) = Gen.update(trace, get_args(trace), (NoChange(),), enum_constraints)
            w = get_score(new_trace)

#            (tr, w) = Gen.generate(generate_dotmotion, trace_args, enum_constraints)
#            temp_constraints = [map_entry for map_entry in get_values_shallow(enum_constraints) if map_entry[1][1] != :x_vel]
            # this just removes the constraining velocities from the choicemap. 
 #           enum_constraints = Gen.choicemap(temp_constraints...)
            append!(scores, w)
        end
    end
    score_matrix = reshape(scores, prod(collect(size(kernel_choices))), size(edge_truthtable)[1])
    plotvals = [score_matrix, kernel_choices, possible_edges, edge_truthtable]
#    plot_heatmap(plotvals...)
    return plotvals
end

function evaluate_accuracy(num_dots::Int64, num_iters::Int64)
    correct_counter = zeros(4)
    for ni in 1:num_iters
        t, e, v = imp_inference(num_dots)
        motion_tree = get_retval(t)[1]
        mp_edge = findmax(countmap(e))[2]
        mp_velocity = findmax(countmap(v))[2]
        scoremat, kernels, p_edges, edge_tt = enumerate_possibilities(t)
        max_score = findmax(scoremat)[2]
        max_enum_vel = kernels[max_score[1]]
        max_enum_edge = edge_tt[max_score[2]]
        edge_truth = [convert(Int64, has_edge(motion_tree, d1, d2)) for d1 in 1:num_dots for d2 in 1:num_dots if d1 != d2]
        velocity_truth = [t[(:kernel_type, d)] for d in 1:num_dots]
        if Tuple(edge_truth) == max_enum_edge
            correct_counter[1] += 1
        end
        if Tuple(velocity_truth) == max_enum_vel
            correct_counter[2] += 1
        end
        if edge_truth == mp_edge
            correct_counter[3] += 1
        end
        if velocity_truth == mp_velocity
            correct_counter[4] += 1
        end
    end
    barplot(correct_counter / num_iters)
end        
            
                      
    
function plot_heatmap(score_matrix::Array{Any, 2}, kernels, possible_edges, edge_truth)
    scene, layout = layoutscene(resolution=(1200,900), backgroundcolor=RGBf0(0, 0, 0))
    white = RGBf0(255,255,255)
    axes = [LAxis(scene, backgroundcolor=RGBf0(0, 0, 0), xticklabelcolor=white, yticklabelcolor=white, 
                  xtickcolor=white, ytickcolor=white, xgridcolor=white, ygridcolor=white, 
                  xticklabelrotation = pi/2,  xticklabelalign = (:top, :top), yticklabelalign = (:top, :top))]
    heatmap!(axes[1], score_matrix, colormap=:viridis)
    layout[1,1] = axes[1]
    axes[1].xticks = (0:prod(collect(size(kernels)))-1, [string(k) for k in kernels])
    yticklabs = [string([e_entry for (i, e_entry) in enumerate(possible_edges) if et[i] == 1]) for et in edge_truth]
    println(yticklabs)
    axes[1].yticks = (1:size(edge_truth)[1], [yt[1] != 'T' ? yt : "[]" for yt in yticklabs]) 
    display(scene)
    return scene, axes
end

function dotsample(num_dots::Int)
    ts = range(1, stop=time_duration, length=num_velocity_points)
    gdm_args = (convert(Array{Float64}, ts), num_dots)
    trace = Gen.simulate(generate_dotmotion, gdm_args)
    println(collect(edges(get_retval(trace)[1])))
    trace_choices = get_choices(trace)
    println([trace_choices[(:kernel_type, i)] for i in 1:num_dots])
    return trace, gdm_args
end    

# function force_assign_dotpositions(trace::Gen.DynamicDSLTrace{DynamicDSLFunction{Any}})
    
#     observation = Gen.choicemap()
#     (new_trace, w, a, ad) = Gen.update(gd_trace, t_args, (NoChange(),), observations)
    
# end    


# one test you want to do is assign invertedly. see if the tree comes back inverted.
# another thing you want to do is force assign so it doesn't play with choices of start x and y and
# score values that make no sense. this is probably a thing.


function imp_inference(num_dots::Int)
    trace, args = dotsample(num_dots)
    trace_choices = get_choices(trace)
    observation = Gen.choicemap()
    for i in 1:num_dots
        observation[(:x_vel, i)] = trace[(:x_vel, i)]
        observation[(:start_y, i)] = trace[(:start_y, i)]
        observation[(:y_vel, i)] = trace[(:y_vel, i)]
        observation[(:start_x, i)] = trace[(:start_x, i)]        
    end
    edge_list = []
    kernel_types = []
    for i in 1:100
        (tr, w) = Gen.importance_resampling(generate_dotmotion, args, observation, 75)
        push!(edge_list, [tr[(:edge, j, k)] for j in 1:num_dots for k in 1:num_dots if j!=k])
        push!(kernel_types, [tr[(:kernel_type, j)] for j in 1:num_dots])
    end
    return trace, edge_list, kernel_types
end    

function imp_inference(trace::Gen.DynamicDSLTrace{DynamicDSLFunction{Any}})
    trace_choices = get_choices(trace)
    args = get_args(trace)
    observation = Gen.choicemap()
    num_dots = nv(get_retval(trace)[1])
    for i in 1:num_dots
        observation[(:x_vel, i)] = trace[(:x_vel, i)]
        observation[(:start_y, i)] = trace[(:start_y, i)]
        observation[(:y_vel, i)] = trace[(:y_vel, i)]
        observation[(:start_x, i)] = trace[(:start_x, i)]        
    end
    edge_list = []
    kernel_types = []
    for i in 1:100
        (tr, w) = Gen.importance_resampling(generate_dotmotion, args, observation, 75)
        push!(edge_list, [tr[(:edge, j, k)] for j in 1:num_dots for k in 1:num_dots if j!=k])
        push!(kernel_types, [tr[(:kernel_type, j)] for j in 1:num_dots])
    end
    return trace, edge_list, kernel_types
end

# function imp_inference(num_dots::Int)
#     trace, args = dotsample(num_dots)
#     trace_choices = get_choices(trace)
#     observation = Gen.choicemap()
#     for i in 1:num_dots
#         observation[(:x_pos, i)] = trace[(:x_pos, i)]
#         observation[(:y_pos, i)] = trace[(:y_pos, i)]
#     end
#     edge_list = []
#     kernel_types = []
#     for i in 1:100
#         (tr, w) = Gen.importance_resampling(generate_dotmotion, args, observation, 200)
#         push!(edge_list, [tr[(:edge, j, k)] for j in 1:num_dots for k in 1:num_dots if j!=k])
#         push!(kernel_types, [tr[(:kernel_type, j)] for j in 1:num_dots])
#     end
#     return trace, edge_list, kernel_types
# end    

# function imp_inference(trace::Gen.DynamicDSLTrace{DynamicDSLFunction{Any}})
#     trace_choices = get_choices(trace)
#     args = get_args(trace)
#     observation = Gen.choicemap()
#     num_dots = nv(get_retval(trace)[1])
#     for i in 1:num_dots
#         observation[(:x_pos, i)] = trace[(:x_pos, i)]
#         observation[(:y_pos, i)] = trace[(:y_pos, i)]
#     end
#     edge_list = []
#     kernel_types = []
#     for i in 1:100
#         (tr, w) = Gen.importance_resampling(generate_dotmotion, args, observation, 200)
#         push!(edge_list, [tr[(:edge, j, k)] for j in 1:num_dots for k in 1:num_dots if j!=k])
#         push!(kernel_types, [tr[(:kernel_type, j)] for j in 1:num_dots])
#     end
#     return trace, edge_list, kernel_types
# end    


"""Create Makie Rendering Environment"""

function tree_to_coords(tree::MetaDiGraph{Int64, Float64},
                        framerate::Int64)
    num_dots = nv(tree)
    dotmotion = fill(zeros(2), num_dots, size(interpolate_coords(props(tree, 1)[:Velocity_X], interp_iters))[1])
    println(size(dotmotion))
    # Assign first dot positions based on its initial XY position and velocities
    for dot in 1:num_dots
        dot_data = props(tree, dot)
        dotmotion[dot, :] = [[x, y] for (x, y) in zip(
            dot_data[:Position][1] .+ cumsum(interpolate_coords(dot_data[:Velocity_X], interp_iters)) ./ framerate,
            dot_data[:Position][2] .+ cumsum(interpolate_coords(dot_data[:Velocity_Y], interp_iters)) ./ framerate)]
    end

    dotmotion_tuples = [[Tuple(dotmotion[i, j]) for i in 1:num_dots] for j in 1:size(dotmotion)[2]]
    println(size(dotmotion_tuples))
    return dotmotion_tuples
end

function tree_to_coords(tree::MetaDiGraph{Int64, Float64})
    num_dots = nv(tree)
    dotmotion = fill(zeros(2), num_dots, size(interpolate_coords(props(tree, 1)[:Position_X], interp_iters))[1])
    dotmotion = fill(zeros(2), num_dots, size(props(tree, 1)[:Position_X])[1])
    println(size(dotmotion))
    # Assign first dot positions based on its initial XY position and velocities
    for dot in 1:num_dots
        dot_data = props(tree, dot)
        dotmotion[dot, :] = [[x, y] for (x, y) in zip(dot_data[:Position_X], dot_data[:Position_Y])]
            # interpolate_coords(dot_data[:Position_X], interp_iters),
            # interpolate_coords(dot_data[:Position_Y], interp_iters))]
    end
    dotmotion_tuples = [[Tuple(dotmotion[i, j]) for i in 1:num_dots] for j in 1:size(dotmotion)[2]]
    println(size(dotmotion_tuples))
    return dotmotion_tuples
end


function visualize_graph(motion_tree::MetaDiGraph{Int64, Float64},
                         resolution::Int64,
                         node_dict::Dict{Any})
    g = TikzGraphs.plot(motion_tree.graph,
                        edge_style="yellow, line width=2",
                        node_style="draw, rounded corners, fill=blue!20", node_styles=node_dict,
                        options="scale=8, font=\\huge\\sf");
    #make dots a certain color in the graph for a specific motion type. then turn the heatmap axis black.
    # see if you can switch the xticks to be different colors. 
    TikzPictures.save(PDF("test"), g);
    graphimage = load("test.pdf");
    rot_image = imrotate(graphimage, π/2);
    scale_ratio = (resolution*.7) / maximum(size(rot_image))
    resized_image = imresize(rot_image, ratio=scale_ratio)
    return resized_image
end    

function dotwrap(num_dots::Int)
    trace, args = dotsample(num_dots)
    render_dotmotion(trace)
    return trace, args
end

function nodecolors(trace::Gen.DynamicDSLTrace{DynamicDSLFunction{Any}})
    nc_dict = Dict()
    for n in 1:nv(get_retval(trace)[1])
        vtype = trace[(:kernel_type, n)]
        if vtype == RandomWalk
            nc_dict[n] = "fill=red!70"
        elseif vtype == Constant
            nc_dict[n] = "fill=green!50!blue!50"
        elseif vtype == Linear
            nc_dict[n] = "fill=blue!80!red!50"
          #  nc_dict[n] = "fill=blue!20"
        elseif vtype == Periodic
            nc_dict[n] = "fill=red!40!blue!30!"
        end
    end
        return nc_dict
end        

# score for the correct kernel type is always the highest, up to 3 dots. 

function test_assignment(num_dots::Int64)
    observations = Gen.choicemap()
    ts = range(1, stop=time_duration, length=num_velocity_points)
    ts_array = convert(Array{Float64}, ts)
    observed_graph = MetaGraph(num_dots)
    t_args = (ts_array, num_dots)
    gd_trace = Gen.simulate(generate_dotmotion, t_args)
    r = get_retval(gd_trace)
    println(collect(edges(r[1])))
    # if !isempty(observation)
    #     observations[observation] = gd_trace[(:x_vel, 1)]
    # end
    ws = []
    println([gd_trace[(:kernel_type, i)] for i in 1:num_dots])
    for kt in kernel_types
        observations[(:kernel_type, 1)] = kt
        (new_trace, w, a, ad) = Gen.update(gd_trace, t_args, (NoChange(),), observations)
        w = get_score(new_trace)
        push!(ws, w)
    end        
    # this is meaningless - a whole new trace gets generated that may not share edges, etc.
    # all i want is the probability of generating the velocity generated by the trace
    # given 
    #    (ass_trace, w) = Gen.generate(assign_positions_and_velocities, (r[1], r[2], ts_array), observations)
    return [wkt for wkt in zip(ws, kernel_types)]
end    
    


function render_dotmotion(trace::Gen.DynamicDSLTrace{DynamicDSLFunction{Any}})
    motion_tree = get_retval(trace)[1]
    bounds = 10
    res = 500
    outer_padding = 0
    node_styles = nodecolors(trace)
    println(node_styles)
    graph_image = visualize_graph(motion_tree, res, node_styles)
    dotmotion = tree_to_coords(motion_tree, framerate)
    f(t, coords) = coords[t]
    n_rows = 3
    n_cols = 2
    white = RGBf0(255,255,255)
    #    score_matrix = animate_inference(trace)
    score_matrix = enumerate_possibilities(trace)
    scene, layout = layoutscene(outer_padding,
                                resolution = (2*res, 3*res), 
                                backgroundcolor=RGBf0(0, 0, 0))
    axes = [LAxis(scene, backgroundcolor=RGBf0(0, 0, 0)) for i in 1:3]
    axes[3] = [LAxis(scene, backgroundcolor=white, xticklabelcolor=white, yticklabelcolor=white, 
                     xtickcolor=white, ytickcolor=white, xgridcolor=white, ygridcolor=white, 
                     xticklabelrotation = pi/2,  xticklabelalign = (:top, :top), yticklabelalign = (:top, :top))][1]
    axes[3].xticks = (0:prod(collect(size(score_matrix[2])))-1, [string([string(ks)[1] for ks in k]...) for k in score_matrix[2]])
    yticklabs = [string([e_entry for (i, e_entry) in enumerate(score_matrix[3]) if et[i] == 1]) for et in score_matrix[4]]
    axes[3].yticks = (1:size(score_matrix[4])[1], [yt[1] != 'T' ? yt : "[]" for yt in yticklabs])
#    layout[1:n_rows, 1:n_cols] = axes
    layout[3, 1:n_cols] = axes[[1,3]]
    layout[1:2, 1:n_cols] = axes[2]
    time_node = Node(1);
    f(t, coords) = coords[t]
    scatter!(axes[2], lift(t -> f(t, dotmotion), time_node), markersize=10px, color=RGBf0(255, 255, 255))
    limits!(axes[2], BBox(-bounds, bounds, -bounds, bounds))
    image!(axes[1], graph_image)
    limits!(axes[1], BBox(0, res, 0, res))
    hm = heatmap!(axes[3], score_matrix[1], colormap=:viridis)
#    limits!(axes[3], BBox(0, res, 0, res))
    hm.colorrange = (1, sum(score_matrix[1]))

    for j in 1:nv(motion_tree)
        println(trace[(:kernel_type, j)])
    end
    display(scene)

    #     time_node[] = i
    #     sleep(1/framerate)
    # end
#    record(scene, "dotmotion.mp4", 1:size(dotmotion)[1]; framerate=60) do i
    for i in 1:size(dotmotion)[1]
        time_node[] = i
        sleep(1/framerate)
    end
    return dotmotion
end    


# Currently in makie_test. Takes a tree and renders the tree and the stimulus.


#- BELOW IS CODE FOR GENERATING TIME SERIES VIA GPs FROM 6.885 PSETS. IT'S ACTUALLY A GREAT STARTING POINT FOR GENERATING SYMBOLIC MOTION PATTERNS. BUT SIMPLIFY FOR NOW. GET RID OF COMPOSITE NODES AND SQUARED EXPONENTIAL MOTION. FOR NOW, JUST KEEP CONSTANT, LINEAR, AND PERIODIC.-#


"""Node in a tree where the entire tree represents a covariance function"""
abstract type Kernel end
abstract type PrimitiveKernel <: Kernel end
abstract type CompositeKernel <: Kernel end

"""Number of nodes in the tree describing this kernel."""
Base.size(::PrimitiveKernel) = 1
Base.size(node::CompositeKernel) = node.size


#- HERE EACH KERNEL TYPE FOR GENERATING TIME SERIES IS DEFINED USING MULTIPLE DISPATCH ON eval_cov AND eval_cov_mat. 

"""Random Walk Kernel"""
struct RandomWalk <: PrimitiveKernel
    param::Float64
end

function eval_cov(node::RandomWalk, t1, t2)
    if t1 == t2
        node.param
    else
        0
    end
end        

function eval_cov_mat(node::RandomWalk, ts::Array{Float64})
    n = length(ts)
    Diagonal(node.param * ones(n))
end

    
"""Constant kernel"""
struct Constant <: PrimitiveKernel
    param::Float64
end

eval_cov(node::Constant, t1, t2) = node.param


function eval_cov_mat(node::Constant, ts::Array{Float64})
    n = length(ts)
    fill(node.param, (n, n))
end


"""Linear kernel"""
struct Linear <: PrimitiveKernel
    param::Float64
end

eval_cov(node::Linear, t1, t2) = (t1 - node.param) * (t2 - node.param)

function eval_cov_mat(node::Linear, ts::Array{Float64})
    ts_minus_param = ts .- node.param
    ts_minus_param * ts_minus_param'
end

"""Squared exponential kernel"""
struct SquaredExponential <: PrimitiveKernel
    length_scale::Float64
end

eval_cov(node::SquaredExponential, t1, t2) =
    exp(-0.5 * (t1 - t2) * (t1 - t2) / node.length_scale)

function eval_cov_mat(node::SquaredExponential, ts::Array{Float64})
    diff = ts .- ts'
    exp.(-0.5 .* diff .* diff ./ node.length_scale)
end

"""Periodic kernel"""
struct Periodic <: PrimitiveKernel
    amplitude::Float64
    scale::Float64
    period::Float64
end

# function eval_cov(node::Periodic, t1, t2)
#     freq = 2 * pi / node.period
#     exp((-1/node.scale) * (sin(freq * abs(t1 - t2)))^2)
# end

# function eval_cov_mat(node::Periodic, ts::Array{Float64})
#     freq = 2 * pi / node.period
#     abs_diff = abs.(ts .- ts')
#     exp.((-1/node.scale) .* (sin.(freq .* abs_diff)).^2)
# end

function eval_cov(node::Periodic, t1, t2)
    (node.amplitude ^ 2) * exp(
        (-2/node.scale^2) * sin(pi*abs(t1-t2)/node.period)^2) 
end

function eval_cov_mat(node::Periodic, ts::Array{Float64})
    abs_diff = abs.(ts .-ts')
    (node.amplitude ^ 2) .* exp.((-2/node.scale^2) .* sin.(pi*abs_diff./node.period).^2) 
end




#-THESE NODES CREATE BIFURCATIONS IN THE TREE THAT GENERATE TWO NEW NODE TYPES, WHICH CAN MAKE THE FUNCTION A COMPOSITE OF MULTIPLE NODE INSTANCES AND TYPES-#

"""Plus node"""
struct Plus <: CompositeKernel
    left::Kernel
    right::Kernel
    size::Int
end

Plus(left, right) = Plus(left, right, size(left) + size(right) + 1)

function eval_cov(node::Plus, t1, t2)
    eval_cov(node.left, t1, t2) + eval_cov(node.right, t1, t2)
end

function eval_cov_mat(node::Plus, ts::Vector{Float64})
    eval_cov_mat(node.left, ts) .+ eval_cov_mat(node.right, ts)
end


"""Times node"""
struct Times <: CompositeKernel
    left::Kernel
    right::Kernel
    size::Int
end

Times(left, right) = Times(left, right, size(left) + size(right) + 1)

function eval_cov(node::Times, t1, t2)
    eval_cov(node.left, t1, t2) * eval_cov(node.right, t1, t2)
end

function eval_cov_mat(node::Times, ts::Vector{Float64})
    eval_cov_mat(node.left, ts) .* eval_cov_mat(node.right, ts)
end


#-THE COVARIANCE MATRIX WILL HAVE THE DIMENSIONS OF YOUR TIME SERIES IN X, AND DEFINES THE RELATIONSHIPS BETWEEN EACH TIMEPOINT. 

"""Compute covariance matrix by evaluating function on each pair of inputs."""
function compute_cov_matrix(covariance_fn::Kernel, noise, ts)
    n = length(ts)
    cov_matrix = Matrix{Float64}(undef, n, n)
    for i=1:n
        for j=1:n
            cov_matrix[i, j] = eval_cov(covariance_fn, ts[i], ts[j])
        end
        cov_matrix[i, i] += noise
    end
    return cov_matrix
end


"""Compute covariance function by recursively computing covariance matrices."""
function compute_cov_matrix_vectorized(covariance_fn, noise, ts)
    n = length(ts)
    eval_cov_mat(covariance_fn, ts) + Matrix(noise * LinearAlgebra.I, n, n)
end

"""
Computes the conditional mean and covariance of a Gaussian process with prior mean zero
and prior covariance function `covariance_fn`, conditioned on noisy observations
`Normal(f(xs), noise * I) = ys`, evaluated at the points `new_xs`.
"""
# note this will come in handy when estimating the parameters of the function
# currently using deterministic params. 

function compute_predictive(covariance_fn::Kernel, noise::Float64,
                            ts::Vector{Float64}, pos::Vector{Float64},
                            new_xs::Vector{Float64})
    n_prev = length(ts)
    n_new = length(new_ts)
    means = zeros(n_prev + n_new)
#    cov_matrix = compute_cov_matrix(covariance_fn, noise, vcat(xs, new_xs))
    cov_matrix = compute_cov_matrix_vectorized(covariance_fn, noise, vcat(ts, new_ts))
    cov_matrix_11 = cov_matrix[1:n_prev, 1:n_prev]
    cov_matrix_22 = cov_matrix[n_prev+1:n_prev+n_new, n_prev+1:n_prev+n_new]
    cov_matrix_12 = cov_matrix[1:n_prev, n_prev+1:n_prev+n_new]
    cov_matrix_21 = cov_matrix[n_prev+1:n_prev+n_new, 1:n_prev]
    @assert cov_matrix_12 == cov_matrix_21'
    mu1 = means[1:n_prev]
    mu2 = means[n_prev+1:n_prev+n_new]
    conditional_mu = mu2 + cov_matrix_21 * (cov_matrix_11 \ (pos - mu1))
    conditional_cov_matrix = cov_matrix_22 - cov_matrix_21 * (cov_matrix_11 \ cov_matrix_12)
    conditional_cov_matrix = 0.5 * conditional_cov_matrix + 0.5 * conditional_cov_matrix'
    (conditional_mu, conditional_cov_matrix)
end

"""
Predict output values for some new input values
"""
function predict_pos(covariance_fn::Kernel, noise::Float64,
                     ts::Vector{Float64}, pos::Vector{Float64},
                     new_ts::Vector{Float64})
    (conditional_mu, conditional_cov_matrix) = compute_predictive(
        covariance_fn, noise, ts, pos, new_ts)
    mvnormal(conditional_mu, conditional_cov_matrix)
end

# This is an array of data types. Each data type takes a parameter, and each data type has a multiple dispatch
# call associated with it to create a covariance matrix. 
    
#kernel_types = [RandomWalk, Constant, Linear, Periodic]
#@dist choose_kernel_type() = kernel_types[categorical([.25, .25, .25, .25])]

kernel_types = [RandomWalk, Constant, Periodic]
#kernel_types = [RandomWalk, Linear, Constant, Periodic]

@dist choose_kernel_type() = kernel_types[categorical([1/3, 1/3, 1/3])]

function all_dot_permutations(n_dots)
    all_ranges = [1:n_dots for i in 1:n_dots]
    all_permutations = [i for i in Iterators.product(all_ranges...) if length(unique(i)) == n_dots]
    return collect(all_permutations)
end    

function return_dot_distribution(n_dots)
    d_permut = all_dot_permutations(n_dots)
    @dist dot_permutations() = d_permut[categorical([1/length(d_permut) for i in 1:length(d_permut)])]
end    
# can't pass a number param here. have to make a generator to generate distributions I think. n is not a parameter.
# 





# I tested this function under Gen.generate and constrained choices of kernel types
# unconstrained, weight is correctly 0. constrained, weights are identical to categorial probabilities
# returns a natural log of the prob. 

@gen function covariance_simple(kt)
    kernel_type = {(:kernel_type, kt)} ~ choose_kernel_type()
    if kernel_type == Periodic
        #        kernel_args = [.5, .5]
        # note the velocity profile is updating at 4Hz (40 samples over 10 sec),
        # so have to have period be factor of 4 to look periodic. 
        kernel_args = [3, .5, 1]

#        kernel_args = [20, 20]
    elseif kernel_type == Constant
        kernel_args = [1]
#        kernel_args = [3]
    elseif kernel_type == Linear
        kernel_args = [.1]
    elseif kernel_type == RandomWalk
#        kernel_args = [.2]
        kernel_args = [3]
    else
        kernel_args = [1]
    end
    return kernel_type(kernel_args...)
end 

# @gen function covariance_simple(kt)
#     kernel_type = {(:kernel_type, kt)} ~ choose_kernel_type()
#     if kernel_type == Periodic
#         kernel_args = [.5, 2]
# #        kernel_args = [.5, 5]
#     elseif kernel_type == Constant
#         kernel_args = [1]
# #        kernel_args = [3]
#     elseif kernel_type == Linear
#         kernel_args = [.2]
#     elseif kernel_type == RandomWalk
#         kernel_args = [2]
# #        kernel_args = [2]
#     else
#         kernel_args = [1]
#     end
#     return kernel_type(kernel_args...)
# end 



@gen function covariance_prior()
    # Choose a type of kernel
    kernel_type = { :kernel_type } ~ choose_kernel_type()
    # If this is a composite node, recursively generate subtrees. For now, too complex. 
    if in(kernel_type, [Plus, Times])
        return kernel_type({ :left } ~ covariance_prior(), { :right } ~ covariance_prior())
    end
    # Otherwise, generate parameters for the primitive kernel.
    if kernel_type == Periodic
        kernel_args = [{ :scale } ~ uniform(0, 1), { :period } ~ uniform(0, 10)]
    elseif kernel_type == Constant
        kernel_args = [{ :param } ~ uniform(0, 3)]
    elseif kernel_type == Linear
        kernel_args = [{ :param } ~ uniform(0, 1)]
    elseif kernel_type == RandomWalk
        kernel_args = [{ :param } ~ uniform(0, 10)]
    else
        kernel_args = [{ :param } ~ uniform(0, 1)]
    end
    return kernel_type(kernel_args...)
end

@dist gamma_bounded_below(shape, scale, bound) = gamma(shape, scale) + bound
                                          








                                          

