using GLMakie
using Gen
using GenGridEnumeration
#using LinearAlgebra
using Random
using Statistics
using StatsBase
using GeometryBasics

# note there are residual types in Makie from GeometryTypes, which is
# deprecated in favor of GeometryBasics


# can also get positions w/out going to mesh first if you want to. i.e. vertices = decompose(Point3, cube_prim)
# can construct a primitive as well w/ a set of vertices (i.e. 

vertices = decompose(Point{3, Float64}, cube_prim)
# list of vertices
faces = decompose(TriangleFace{Int}, cube_prim)
# this is a list that connects indices of vertices to each other w/ a triangle

cube_mesh = GeometryBasics.Mesh(vertices, faces)

z_rotator = qrotation(Vec3f0(0, 0, 1), -.5)
x_rotator = qrotation(Vec3f0(1, 0, 0), -.5)
rotator = z_rotator * x_rotator
rotated_verts = [rotator * v for v in vertices]
rotated_mesh = GeometryBasics.Mesh(rotated_verts, faces)

struct Rotator
    euler_axis::Vec
    rot_radians::Float64
end
    
cube_prim = GeometryBasics.Rect(Vec(-.5, -.5, -.5), Vec(1.0, 1.0, 1.0)) # origin and side size
sphere_prim = GeometryBasics.Sphere(Point3(0.0, 0.0, 0.0), 1) # origin, radius
cylinder_prim = Cylinder(Point3(0.0, 0.0, 0.0), Point3(0.0,0.0,1.0), 1.0) #(origin, normal vector, width)
shape_types = [cube_prim, sphere_prim, cylinder_prim]
@dist choose_shape() = shape_types[categorical([1/3, 1/3, 1/3])]


@gen function primitive_shapes()
    shape = { :shape_choice } ~ choose_shape()
    rotation_x = { :rot_x } ~ uniform(0, π)
    rotation_y = { :rot_y } ~ uniform(0, π)
    rotation_z = { :rot_z } ~ uniform(0, π / 2)
    
    
    mesh_to_grid = scene2image(mesh_ax.scene)[1]
    noisy_image = ({ :image_2D } ~ noisy_matrix(blurred_depth_image, 0.1))
end

function render_static_wireframe(mesh, rotation::Rotator, mesh_or_wire::String)
    white = RGBAf0(255, 255, 255, 0.0)
    if mesh_or_wire == "wire"
        mesh_fig, mesh_axis = GLMakie.wireframe(cube_prim, color=:skyblue2)
    elseif mesh_or_wire == "mesh"
        mesh_fig, mesh_axis = GLMakie.mesh(cube_prim, color=:skyblue2)
    end
    meshscene = mesh_axis.scene[end]
    screen = display(mesh_fig)
    remove_axis_from_scene(mesh_axis)
    rotate!(meshscene, qrotation(rotation.euler_axis, rotation.rot_radians))
    return mesh_axis
end    
    

function animate_mesh_rotation(mesh, rotations)
    time_node = Node(1);
  
    f(t, rotations) = qrotation(rotations[t]...)
    mesh_fig, mesh_axis = GLMakie.wireframe(cube_prim, color=:skyblue2)
    meshscene = mesh_axis.scene[end]
    # another option is rotating outside the "rotations" call and instead lifting the mesh itself.
    # then all of your rotations are on the mesh instead of the 
    screen = display(mesh_fig)
    remove_axis_from_scene(mesh_axis)
    # threeDaxis = mesh_axis.scene[OldAxis]
    # threeDaxis[:showgrid] = (false, false, false)
    # threeDaxis[:showaxis] = (false, false, false)
    # threeDaxis[:ticks][:textcolor] = (white, white, white)
    # threeDaxis[:names, :axisnames] = ("", "", "")
    for r in rotations
        rotate!(meshscene, qrotation(r...))
        # need a 2D gridsave in the loop
        sleep(.1)
    end
    return mesh_axis
end


function remove_axis_from_scene(mesh_axis)
    white = RGBAf0(255, 255, 255, 0.0)
    threeDaxis = mesh_axis.scene[OldAxis]
    threeDaxis[:showgrid] = (false, false, false)
    threeDaxis[:showaxis] = (false, false, false)
    threeDaxis[:ticks][:textcolor] = (white, white, white)
    threeDaxis[:names, :axisnames] = ("", "", "")
    return threeDaxis
end



    
struct NoisyMatrix <: Gen.Distribution{Matrix{Float64}} end

const noisy_matrix = NoisyMatrix()

function Gen.logpdf(::NoisyMatrix, x::Matrix{Float64}, mu::Matrix{U}, noise::T) where {U<:Real,T<:Real}
    var = noise * noise
    diff = x - mu
    vec = diff[:]
    return -(vec' * vec)/ (2.0 * var) - 0.5 * log(2.0 * pi * var)
end

function Gen.random(::NoisyMatrix, mu::Matrix{U}, noise::T) where {U<:Real,T<:Real}
    mat = copy(mu)
    (w, h) = size(mu)
    for i=1:w
        for j=1:h
            mat[i, j] = mu[i, j] + randn() * noise
            if mat[i, j] > 1
                mat[i, j] = 1
            elseif mat[i, j] < 0
                mat[i, j] = 0
            end
        end
    end
    return mat
end


""" NOTES """
# cube_mesh.position yields the unrotated vertices
# cube.transformation.rotation gives you the rotation applied.
# cube.transformation.scale gives you scaling
# qrotation takes an axis (e.g. Vec3(1,0,0)) and a radian angle and returns a Quaternion. 
# w Rotations.jl, can make a Quat(q.data...) call to get a quaternion, which can be multiplied by 3D vecs
# coordinates(shape, nvertices=2) returns 
# ax.scene.camera contains the projection matricies w/ .projeciton and .projectionview
# lift syntax for animating a meshscatter

    # mesh_fig, mesh_ax = meshscatter(
    #     Point3f0.(rand.() .* 4, rand(N) .* 4, rand.() .* 0.01),
    #     markersize = Vec3f0.([0, .3], [0, .3], [0, 1.0]), 
    #     marker = cube_prim, 
    #     color = :skyblue2,
    #     rotations =  lift(t -> f(t, rotations), time_node),
    #     ssao = true)

# ax.scene.center = false
# im = GLMakie.scene2image(ax.scene)
#     # EQUIVALENT
# save("test.png", ax.scene)
# save("test2.png", im[1])

