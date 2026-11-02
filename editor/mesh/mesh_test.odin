package mesh

import "core:math/linalg"
import "core:slice"
import "core:testing"
import fixture "project:plugins/unreal/editor/fixture/files"
import "project:plugins/unreal/editor/kraken"
import unreal "project:plugins/unreal/editor/package"

// A quad of 100 cm facing up (+Z), in two polygon groups, and a triangle whose
// corners are one point. Corners run as Unreal's do: cross(c2-c0, c1-c0) is the front.
@(private="file")
quad :: proc(layout:fixture.Mesh_Layout) -> fixture.Mesh_Fixture {
    up:=[3]f32{0,0,1}
    f:fixture.Mesh_Fixture
    f.layout=layout
    f.layout=layout
    f.positions=own([][3]f32{{0,0,0},{100,0,0},{100,100,0},{0,100,0}})
    f.corners=own([]u32{0,2,1, 0,3,2, 1,1,2})
    f.normals=own([][3]f32{up,up,up,up,up,up,up,up,up})
    f.tangents=own([][4]f32{{1,0,0,1},{1,0,0,1},{1,0,0,1},{1,0,0,1},{1,0,0,1},{1,0,0,1},{1,0,0,1},{1,0,0,1},{1,0,0,1}})
    f.uvs=own([][2]f32{{0,1},{1,0},{1,1},{0,1},{0,0},{1,0},{1,1},{1,1},{1,0}})
    f.uvs1=own([][2]f32{{0.5,0.5},{0.5,0.5},{0.5,0.5},{0.5,0.5},{0.5,0.5},{0.5,0.5},{0.5,0.5},{0.5,0.5},{0.5,0.5}})
    f.colors=own([][4]u8{{255,0,0,255},{255,0,0,255},{255,0,0,255},{0,128,255,255},{0,128,255,255},{0,128,255,255},{9,9,9,9},{9,9,9,9},{9,9,9,9}})
    f.groups=own([]u32{0,1,1})
    f.group_names=own([]string{"Wood","Metal"})
    f.smoothing=own([]u32{1,1,1})
    f.slots=own([]fixture.Mesh_Slot{{name="Wood",imported_name="Wood",material="/Game/Materials/M_Wood"},{name="Metal",imported_name="Metal",material="/Game/Materials/M_Metal"}})
    f.section_materials=own([]i32{1,0})
    f.has_bounds=true
    f.bounds_min,f.bounds_max={0,0,0},{100,100,0}
    return f
}

@(private="file")
own :: proc(items:[]$T) -> []T {return slice.clone(items,context.temp_allocator)}

@(private="file")
decoded :: proc(t:^testing.T,bytes:[]u8,model:=Source_Model.Lod0,loc:=#caller_location) -> (source:Static_Mesh,mesh:Mesh,ok:bool) {
    p,error:=unreal.package_open(bytes,limits=LIMITS)
    if !testing.expectf(t,error.code==.None,"package: %v",error,loc=loc) {return}
    defer unreal.package_destroy(&p)
    index:=-1
    for _,i in p.exports {if static_mesh_is(&p,i) {index=i}}
    if !testing.expect(t,index>=0,"the package has a static mesh",loc=loc) {return}
    source,error=mesh_read(&p,index,model)
    if !testing.expectf(t,error.code==.None,"read: %v",error,loc=loc) {return}
    decoder,_:=kraken.decoder_make(context.temp_allocator)
    mesh,error=mesh_decode(&p,&source,&decoder)
    if !testing.expectf(t,error.code==.None,"decode: %v",error,loc=loc) {static_mesh_destroy(&source);return}
    return source,mesh,true
}

@(test)
source_models_of_every_layout_read_as_unreal_builds_them :: proc(t:^testing.T) {
    for layout in fixture.Mesh_Layout {
        source,mesh,ok:=decoded(t,fixture.static_mesh_package(quad(layout)))
        if !ok {continue}
        defer static_mesh_destroy(&source)
        defer mesh_destroy(&mesh)
        testing.expect_value(t,source.layout,layout==.Raw_Mesh?Layout.Raw_Mesh:Layout.Mesh_Description)
        testing.expect_value(t,len(source.materials),2)
        testing.expect_value(t,source.materials[0].path,"/Game/Materials/M_Wood.M_Wood")
        testing.expect_value(t,source.materials[1].name,"Metal")
        // The triangle without area leaves; the sections take the materials of the section info.
        testing.expect_value(t,len(mesh.triangle_section),2)
        testing.expect_value(t,mesh.degenerate,1)
        testing.expect_value(t,len(mesh.sections),2)
        testing.expect_value(t,mesh.sections[0].name,"Wood")
        testing.expect_value(t,mesh.sections[0].material,1)
        testing.expect_value(t,mesh.sections[1].material,0)
        testing.expect_value(t,mesh.triangle_section[1],u32(1))
        testing.expect_value(t,mesh.uv_count,2)
        testing.expect_value(t,mesh.corner_uvs[0][1],[2]f32{1,0})
        testing.expect_value(t,mesh.corner_uvs[1][4],[2]f32{0.5,0.5})
        testing.expect_value(t,mesh.positions[mesh.corner_vertex[1]],[3]f32{100,100,0})
        testing.expect_value(t,mesh.corner_normal[0],[3]f32{0,0,1})
        testing.expect_value(t,mesh.corner_tangent[0],[4]f32{1,0,0,1})
        // Colors come back as the bytes Unreal draws with, through the linear colors of a description.
        if testing.expect_value(t,len(mesh.corner_color),6) {
            testing.expect_value(t,mesh.corner_color[0],[4]u8{255,0,0,255})
            testing.expect_value(t,mesh.corner_color[3],[4]u8{0,128,255,255})
        }
        testing.expect(t,source.has_bounds && mesh.bounds_min==source.bounds_min && mesh.bounds_max==source.bounds_max)
        // Every face is in front where Unreal looks at it.
        for triangle in 0..<2 {
            p:=[3][3]f32{mesh.positions[mesh.corner_vertex[triangle*3]],mesh.positions[mesh.corner_vertex[triangle*3+1]],mesh.positions[mesh.corner_vertex[triangle*3+2]]}
            testing.expect(t,linalg.cross(p[2]-p[0],p[1]-p[0]).z>0)
        }
    }
}

@(test)
a_ue4_save_that_keeps_its_materials_untagged_reads_them_there :: proc(t:^testing.T) {
    f:=quad(.Raw_Mesh)
    f.native_slots=true
    source,mesh,ok:=decoded(t,fixture.static_mesh_package(f))
    if !ok {return}
    defer static_mesh_destroy(&source)
    defer mesh_destroy(&mesh)
    if testing.expect_value(t,len(source.materials),2) {
        testing.expect_value(t,source.materials[0].path,"/Game/Materials/M_Wood.M_Wood")
        testing.expect_value(t,source.materials[1].path,"/Game/Materials/M_Metal.M_Metal")
        testing.expect_value(t,source.materials[1].name,"Metal")
    }
}

@(test)
missing_normals_are_smooth_across_soft_edges_and_split_at_hard_ones :: proc(t:^testing.T) {
    // A roof: two faces meeting at a ridge along +Y.
    roof :: proc(layout:fixture.Mesh_Layout,smoothing:[]u32,hard:[][2]u32) -> fixture.Mesh_Fixture {
        f:=quad(layout)
        f.positions=own([][3]f32{{0,0,0},{50,0,50},{50,100,50},{0,100,0},{100,0,0},{100,100,0}})
        f.corners=own([]u32{0,2,1, 0,3,2, 1,2,5, 1,5,4})
        f.normals=nil
        f.tangents=nil
        f.colors=nil
        f.uvs=own([][2]f32{{0,0},{1,1},{1,0},{0,0},{0,1},{1,1},{0,0},{1,1},{1,0},{0,0},{1,1},{0,1}})
        f.uvs1=nil
        f.groups=own([]u32{0,0,0,0})
        f.group_names=own([]string{"Wood"})
        f.slots=f.slots[:1]
        f.section_materials=nil
        f.smoothing=smoothing
        f.hard=hard
        f.has_bounds=false
        return f
    }
    for layout in fixture.Mesh_Layout {
        smooth_source,smooth,ok:=decoded(t,fixture.static_mesh_package(roof(layout,{1,1,1,1},nil)))
        if !ok {continue}
        // At the ridge, the normals of the three triangles there add up, each with the same weight.
        testing.expectf(t,linalg.length(smooth.corner_normal[1]-linalg.normalize([3]f32{-1,0,3}))<1e-5,"%v: %v",layout,smooth.corner_normal[1])
        testing.expect(t,smooth.corner_tangent[1]=={},"a made normal takes a made tangent")
        static_mesh_destroy(&smooth_source);mesh_destroy(&smooth)
        hard_source,hard,hard_ok:=decoded(t,fixture.static_mesh_package(roof(layout,{1,1,2,2},{{1,2}})))
        if !hard_ok {continue}
        left:=linalg.normalize([3]f32{-1,0,1})
        testing.expectf(t,linalg.length(hard.corner_normal[2]-left)<1e-5,"%v: %v",layout,hard.corner_normal[2])
        testing.expectf(t,linalg.length(hard.corner_normal[6]-[3]f32{left.z,0,left.z})<1e-5,"%v: %v",layout,hard.corner_normal[6])
        static_mesh_destroy(&hard_source);mesh_destroy(&hard)
    }
}

@(test)
the_build_scale_scales_positions_and_bends_normals_the_other_way :: proc(t:^testing.T) {
    f:=quad(.Description)
    f.scale={2,1,0.5}
    f.normals=nil
    f.positions={{0,0,0},{100,0,100},{100,100,100},{0,100,0}}
    f.has_bounds=false
    source,mesh,ok:=decoded(t,fixture.static_mesh_package(f))
    if !ok {return}
    defer static_mesh_destroy(&source)
    defer mesh_destroy(&mesh)
    testing.expect_value(t,mesh.bounds_max,[3]f32{200,100,50})
    // The face leaning 45 degrees leans less once it is twice as long and half as high.
    n:=mesh.corner_normal[0]
    testing.expectf(t,abs(n.x/n.z+0.25)<1e-4,"%v",n)
}

// Polygons of a UE4 description saved before triangles were: a convex quad, a
// convex pentagon, a dart whose first corner is the notch, and a triangle.
@(private="file")
polygons :: proc() -> fixture.Mesh_Fixture {
    f:=quad(.Legacy_Description)
    f.positions=own([][3]f32{
        {0,0,0},{100,0,0},{100,100,0},{0,100,0},
        {200,0,0},{300,0,0},{330,80,0},{250,130,0},{170,80,0},
        {450,40,0},{400,0,0},{450,100,0},{500,0,0},
        {600,0,0},{700,0,0},{650,100,0},
    })
    f.corners=own([]u32{0,1,2,3, 4,5,6,7,8, 9,10,11,12, 13,14,15})
    f.polygon_sizes=own([]int{4,5,4,3})
    f.normals=make([][3]f32,len(f.corners),context.temp_allocator)
    for &n in f.normals {n={0,0,1}}
    f.tangents=nil
    f.colors=nil
    f.uvs=make([][2]f32,len(f.corners),context.temp_allocator)
    f.uvs1=nil
    f.groups=own([]u32{0,0,1,1})
    f.section_materials=nil
    f.has_bounds=false
    return f
}

@(test)
a_description_saved_before_triangles_takes_the_triangles_unreal_5_makes_of_its_polygons :: proc(t:^testing.T) {
    source,mesh,ok:=decoded(t,fixture.static_mesh_package(polygons()))
    if !ok {return}
    defer static_mesh_destroy(&source)
    defer mesh_destroy(&mesh)
    // Each polygon of more than three corners is the fan about its second
    // corner, from the triangle of the first; the dart's covers its notch twice.
    expected:=[]u32{3,0,1, 2,3,1, 8,4,5, 7,8,5, 6,7,5, 12,9,10, 11,12,10, 13,14,15}
    if testing.expect_value(t,len(mesh.corner_vertex),len(expected)) {
        for vertex,corner in expected {testing.expectf(t,mesh.corner_vertex[corner]==vertex,"corner %d: %d, not %d",corner,mesh.corner_vertex[corner],vertex)}
    }
    testing.expect_value(t,mesh.degenerate,0)
    if testing.expect_value(t,len(mesh.triangle_section),8) {
        testing.expect_value(t,mesh.triangle_section[4],u32(0))
        testing.expect_value(t,mesh.triangle_section[5],u32(1))
    }
}

@(test)
names_of_polygon_groups_read_from_their_table :: proc(t:^testing.T) {
    f:=quad(.Description)
    f.fortnite=300
    source,mesh,ok:=decoded(t,fixture.static_mesh_package(f))
    if !ok {return}
    testing.expect_value(t,mesh.sections[1].name,"Metal")
    static_mesh_destroy(&source)
    mesh_destroy(&mesh)
}

@(test)
a_mesh_without_hi_res_source_says_so_and_reads_lod_0 :: proc(t:^testing.T) {
    bytes:=fixture.static_mesh_package(quad(.Description))
    p,_:=unreal.package_open(bytes,limits=LIMITS)
    defer unreal.package_destroy(&p)
    _,error:=mesh_read(&p,0,.Hi_Res)
    testing.expect_value(t,error.code,unreal.Error_Code.Unsupported_Value)
    source,read_error:=mesh_read(&p,0)
    testing.expect_value(t,read_error.code,unreal.Error_Code.None)
    testing.expect(t,!source.hi_res)
    static_mesh_destroy(&source)
}

// Cut at every length and with bytes changed, a package is read or refused, never read past its end.
@(test)
damaged_source_models_are_read_or_refused :: proc(t:^testing.T) {
    decoder,_:=kraken.decoder_make(context.temp_allocator)
    // Each layout, then the polygons saved before triangles.
    for source in 0..=len(fixture.Mesh_Layout) {
        bytes:=source<len(fixture.Mesh_Layout)?fixture.static_mesh_package(quad(fixture.Mesh_Layout(source))):fixture.static_mesh_package(polygons())
        attempt :: proc(bytes:[]u8,decoder:^kraken.Decoder) -> bool {
            p,error:=unreal.package_open(bytes,limits=LIMITS)
            if error.code!=.None {return false}
            defer unreal.package_destroy(&p)
            for _,index in p.exports {
                if !static_mesh_is(&p,index) {continue}
                source,read_error:=mesh_read(&p,index)
                if read_error.code!=.None {return false}
                defer static_mesh_destroy(&source)
                mesh,decode_error:=mesh_decode(&p,&source,decoder)
                defer mesh_destroy(&mesh)
                return decode_error.code==.None
            }
            return false
        }
        testing.expect(t,attempt(bytes,&decoder))
        refused:=0
        for length in 0..<len(bytes) {if !attempt(bytes[:length],&decoder) {refused+=1}}
        testing.expectf(t,refused==len(bytes),"package %d: every cut package is refused (%d of %d)",source,refused,len(bytes))
        changed:=make([]u8,len(bytes),context.temp_allocator)
        for position in 0..<len(bytes) {
            copy(changed,bytes)
            changed[position]~=0xff
            _=attempt(changed,&decoder)
            copy(changed,bytes)
            changed[position]=0x7f
            _=attempt(changed,&decoder)
        }
        free_all(context.temp_allocator)
        decoder,_=kraken.decoder_make(context.temp_allocator)
    }
}

@(test)
the_body_setup_of_every_layout_reads_its_simple_shapes :: proc(t:^testing.T) {
    for layout in fixture.Mesh_Layout {
        f:=quad(layout)
        f.body={
            boxes=own([]fixture.Body_Box{{center={100,0,0},rotation={0,90,0},size={200,100,50}}}),
            spheres=own([]fixture.Body_Sphere{{center={0,0,50},radius=30}}),
            capsules=own([]fixture.Body_Capsule{{center={0,0,0},radius=10,length=40}}),
            convexes=own([][][3]f32{own([][3]f32{{0,0,0},{0,100,0},{100,0,0},{0,0,100}})}),
            trace="CTF_UseSimpleAndComplex",profile="BlockAll",
        }
        p,error:=unreal.package_open(fixture.static_mesh_package(f),limits=LIMITS)
        if !testing.expectf(t,error.code==.None,"%v: package: %v",layout,error) {continue}
        defer unreal.package_destroy(&p)
        index:=-1
        for _,i in p.exports {if static_mesh_is(&p,i) {index=i}}
        source,read_error:=mesh_read(&p,index,.Lod0,context.temp_allocator)
        if !testing.expectf(t,read_error.code==.None,"%v: read: %v",layout,read_error) {continue}
        body,body_error:=body_read(&p,source.body_setup,context.temp_allocator)
        if !testing.expectf(t,body_error.code==.None,"%v: body: %v",layout,body_error) {continue}
        testing.expect_value(t,body.trace,Body_Trace.Simple_And_Complex)
        testing.expect_value(t,body.profile,"BlockAll")
        if !testing.expect_value(t,len(body.shapes),4) {continue}
        box:=body.shapes[0]
        testing.expect_value(t,box.kind,Body_Shape_Kind.Box)
        testing.expect_value(t,box.center,[3]f32{100,0,0})
        testing.expect_value(t,box.size,[3]f32{100,50,25})
        testing.expect(t,linalg.length(rotated(box.rotation,{1,0,0})-{0,1,0})<1e-5,"a yaw of 90 turns the box from +X to +Y")
        testing.expect_value(t,body.shapes[1].kind,Body_Shape_Kind.Sphere)
        testing.expect_value(t,body.shapes[1].size.x,30)
        testing.expect_value(t,body.shapes[2].kind,Body_Shape_Kind.Capsule)
        testing.expect_value(t,body.shapes[2].size,[3]f32{10,20,0})
        testing.expect_value(t,body.shapes[3].kind,Body_Shape_Kind.Convex)
        testing.expect_value(t,len(body.shapes[3].points),4)
        testing.expect_value(t,body.shapes[3].points[1],[3]f32{0,100,0})
    }
    // A mesh without a BodySetup has no shapes.
    p,_:=unreal.package_open(fixture.static_mesh_package(quad(.Description)),limits=LIMITS)
    defer unreal.package_destroy(&p)
    for _,i in p.exports {
        if !static_mesh_is(&p,i) {continue}
        source,_:=mesh_read(&p,i,.Lod0,context.temp_allocator)
        body,error:=body_read(&p,source.body_setup,context.temp_allocator)
        testing.expect(t,error.code==.None && len(body.shapes)==0 && body.trace==.Default,"no body setup, no shapes")
    }
}

@(private="file")
rotated :: proc(q:quaternion128,v:[3]f32) -> [3]f32 {
    u:=[3]f32{q.x,q.y,q.z}
    t:=2*linalg.cross(u,v)
    return v+q.w*t+linalg.cross(u,t)
}
