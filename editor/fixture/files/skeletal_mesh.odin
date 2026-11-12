package fixture_files

// A SkeletalMesh package with LOD 0 in each of the ways Unreal saves it, and
// a Skeleton package.
Skeletal_Layout :: enum u8 {
    UE4,         // UE4: SkeletalMeshLODModel with the import bulk data in it, bone indices and weights of 8 bits
    UE5,         // UE5 before 5.4: the LOD model with doubles, weights of 16 bits and user section data
    Description, // UE 5.4: MeshDescription with SkinWeights in a SkeletalMeshDescriptionBulkData, and the LOD model
}

Skeletal_Bone :: struct {
    name:string,
    parent:i32,
    translation:[3]f32, // centimeters
    rotation:[4]f32,    // x, y, z, w
    scale:[3]f32,
}

Skeletal_Influence :: struct {bone:u16,weight:f32} // bone: row of the reference skeleton

// A morph target: what it adds to rows of the vertices, in Unreal's space.
Skeletal_Morph :: struct {name:string,deltas:[]Skeletal_Morph_Delta}
Skeletal_Morph_Delta :: struct {vertex:u32,position,normal:[3]f32}

// A SkeletalMeshSocket; rotation is pitch, yaw and roll.
Skeletal_Socket :: struct {name,bone:string,location,rotation,scale:[3]f32}

Skeletal_Section :: struct {
    material:int,
    first_vertex,vertex_count:int,
    corners:[]u32,    // vertices of its triangles, three per triangle, rows of all the vertices
    bone_map:[]u16,
    disabled:bool,
}

Skeletal_Fixture :: struct {
    layout:Skeletal_Layout,
    name:string,               // SK_Fixture when ""
    skeleton:string,           // package of its Skeleton, "" for none
    bones:[]Skeletal_Bone,
    positions:[][3]f32,        // per vertex, Unreal's space
    normals:[][3]f32,
    tangents:[][4]f32,         // w the binormal sign
    uvs:[][2]f32,
    colors:[][4]u8,            // RGBA; empty: white
    influences:[][]Skeletal_Influence, // per vertex
    sections:[]Skeletal_Section,
    slots:[]Mesh_Slot,
    lod_material_map:[]i32,
    bounds_min,bounds_max:[3]f32,
    morphs:[]Skeletal_Morph,   // MorphTarget exports, or the Morph- attributes of a description
    sockets:[]Skeletal_Socket, // of the mesh
    thresholds:Maybe([3]f32),  // ThresholdPosition, ThresholdTangentNormal and ThresholdUV of the build settings
    influence_limit:i32,       // BoneInfluenceLimit of the build settings; 0: none
}

@(private) ANIM :: [4]u32{0xAF43A65D,0x7FD34947,0x98733E8E,0xD9C1BB05}
@(private) CORE :: [4]u32{0x375EC13C,0x06E448FB,0xB50084F0,0x262A717E}
@(private) MAIN_RELEASE :: [4]u32{0xD89B5E42,0x24BD4D46,0x8412ACA8,0xDF641779}
@(private) SKELETAL :: [4]u32{0xD78A4A00,0xE8584697,0xBAA819B5,0x487D46B4}
@(private) RECOMPUTE_TANGENT :: [4]u32{0x5579F886,0x933A4C1F,0x83BA087B,0x6361B92F}
@(private) OVERLAPPING :: [4]u32{0x612FBE52,0xDA53400B,0x910D4F91,0x9FB1857C}
@(private) FRAMEWORK :: [4]u32{0xCFFC743F,0x43B04480,0x939114DF,0x171D2073}
@(private) ANIM_PHYS :: [4]u32{0x29E575DD,0xE0A34627,0x9D10D276,0x232CDCEA}

// The versions of each layout and what they decide.
@(private)
Skeletal_Versions :: struct {
    ue5:i32,
    skeletal,editor,fortnite,anim,main,main_release,recompute_tangent:i32,
}

@(private)
skeletal_versions :: proc(layout:Skeletal_Layout) -> (s:Skeletal_Versions,versions:[]Version) {
    switch layout {
    case .UE4:
        s={ue5=0,skeletal=17,editor=26,fortnite=17,anim=2,main=-1,main_release=-1,recompute_tangent=1}
        versions=clone([]Version{{SKELETAL,17},{RENDERING,43},{EDITOR,26},{FORTNITE,17},{ANIM,2},{RELEASE,30},{CORE,2},{RECOMPUTE_TANGENT,1},{OVERLAPPING,1},{FRAMEWORK,35},{ANIM_PHYS,17}})
    case .UE5:
        s={ue5=1008,skeletal=18,editor=40,fortnite=120,anim=30,main=100,main_release=10,recompute_tangent=2}
        versions=clone([]Version{{SKELETAL,18},{RENDERING,47},{EDITOR,40},{FORTNITE,120},{ANIM,30},{RELEASE,44},{MAIN,100},{MAIN_RELEASE,10},{CORE,4},{RECOMPUTE_TANGENT,2},{OVERLAPPING,1},{ENTERPRISE,10},{FRAMEWORK,37},{ANIM_PHYS,17}})
    case .Description:
        s={ue5=1008,skeletal=18,editor=40,fortnite=170,anim=30,main=100,main_release=30,recompute_tangent=2}
        versions=clone([]Version{{SKELETAL,18},{RENDERING,47},{EDITOR,40},{FORTNITE,170},{ANIM,30},{RELEASE,44},{MAIN,100},{MAIN_RELEASE,30},{CORE,4},{RECOMPUTE_TANGENT,2},{OVERLAPPING,1},{ENTERPRISE,10},{FRAMEWORK,37},{ANIM_PHYS,17}})
    }
    return
}

skeletal_mesh_package :: proc(f:Skeletal_Fixture,allocator:=context.temp_allocator) -> []u8 {
    s,versions:=skeletal_versions(f.layout)
    mesh_name:=f.name if f.name!="" else "SK_Fixture"
    w:=writer_make({ue5=s.ue5,versions=versions,package_name="/Game/Characters/SK_Fixture"},allocator)
    class:=engine_class(&w,"SkeletalMesh")
    materials:=make([]i32,len(f.slots),allocator)
    for slot,i in f.slots {if slot.material!="" {materials[i]=material_import(&w,slot.material)}}
    skeleton:=i32(0)
    if f.skeleton!="" {
        skeleton=package_object(&w,f.skeleton,"/Script/Engine","Skeleton",last_part(f.skeleton))
    }
    description_object:=i32(0)
    if f.layout==.Description {description_object=2}
    // After the mesh and its description: its sockets, then its morph targets.
    first_socket:=description_object!=0?3:2
    first_morph:=first_socket+len(f.sockets)

    b:=bytes_make(allocator)
    if skeleton!=0 {object_property(&b,&w,"Skeleton",skeleton)}
    lod:=bytes_make(allocator)
    settings:=bytes_make(allocator)
    bool_property(&settings,&w,"bRecomputeNormals",false)
    bool_property(&settings,&w,"bRecomputeTangents",false)
    if thresholds,ok:=f.thresholds.?;ok {
        float_property(&settings,&w,"ThresholdPosition",thresholds[0])
        float_property(&settings,&w,"ThresholdTangentNormal",thresholds[1])
        float_property(&settings,&w,"ThresholdUV",thresholds[2])
    }
    if f.influence_limit!=0 {int_property(&settings,&w,"BoneInfluenceLimit",f.influence_limit)}
    struct_property(&lod,&w,"BuildSettings","SkeletalMeshBuildSettings",&settings)
    if len(f.lod_material_map)>0 {
        tag(&lod,&w,"LODMaterialMap","ArrayProperty",4+4*len(f.lod_material_map),{inner="IntProperty"})
        put_u32(&lod,u32(len(f.lod_material_map)))
        for value in f.lod_material_map {put_i32(&lod,value)}
    }
    struct_array_property(&b,&w,"LODInfo","SkeletalMeshLODInfo",{lod})
    if len(f.sockets)>0 {
        refs:=make([]i32,len(f.sockets),allocator)
        for &ref,i in refs {ref=i32(first_socket+i)}
        objects_property(&b,&w,"Sockets",refs)
    }
    if len(f.morphs)>0 && f.layout!=.Description {
        refs:=make([]i32,len(f.morphs),allocator)
        for &ref,i in refs {ref=i32(first_morph+i)}
        objects_property(&b,&w,"MorphTargets",refs)
    }
    if description_object!=0 {
        model:=bytes_make(allocator)
        object_property(&model,&w,"MeshDescriptionBulkData",description_object)
        struct_array_property(&b,&w,"SourceModels","SkeletalMeshSourceModel",{model})
    }
    none(&b,&w)
    // The native tail of a SkeletalMesh: no object guid, strip flags, ImportedBounds, materials, reference skeleton.
    put_u32(&b,0)
    put_u8(&b,0);put_u8(&b,0)
    real :: proc(b:^Bytes,s:Skeletal_Versions,value:f32) {if s.ue5>=1004 {put_f64(b,f64(value))} else {put_f32(b,value)}}
    center,extent:=(f.bounds_min+f.bounds_max)/2,(f.bounds_max-f.bounds_min)/2
    for x in center {real(&b,s,x)}
    for x in extent {real(&b,s,x)}
    real(&b,s,1)
    put_u32(&b,u32(len(f.slots)))
    for slot,i in f.slots {
        put_i32(&b,materials[i])
        put_name(&b,&w,slot.name)
        if f.layout!=.UE4 {put_u32(&b,1)}
        put_name(&b,&w,slot.imported_name)
        put_zeros(&b,24)
        if s.fortnite>=196 {put_i32(&b,0)}
    }
    reference_skeleton(&b,&w,s,f.bones)
    lod_model(&b,&w,s,f)
    put_u32(&b,0)
    export_add(&w,{class=class,outer=0,name=mesh_name,data=b.data[:]})
    if description_object!=0 {
        data:=bytes_make(allocator)
        none(&data,&w)
        put_u32(&data,0)
        editor_bulk_data(&data,&w,skeletal_description(&w,f,s,allocator))
        put_zeros(&data,20)
        export_add(&w,{class=engine_class(&w,"SkeletalMeshDescriptionBulkData"),outer=1,name="SkeletalMeshDescriptionBulkData",data=data.data[:]})
    }
    sockets_add(&w,f.sockets,1,allocator)
    if f.layout!=.Description {
        for morph in f.morphs {
            // The native tail of a MorphTarget: strip flags, MorphLODModels of LOD 0.
            m:=bytes_make(allocator)
            none(&m,&w)
            put_u32(&m,0)
            put_u8(&m,0);put_u8(&m,0)
            put_u32(&m,1)
            put_u32(&m,u32(len(morph.deltas)))
            for d in morph.deltas {
                for x in d.position {put_f32(&m,x)}
                for x in d.normal {put_f32(&m,x)}
                put_u32(&m,d.vertex)
            }
            put_u32(&m,u32(len(f.positions)))
            put_u32(&m,0)
            put_u32(&m,0)
            if s.fortnite>=158 {put_text(&m,"")}
            export_add(&w,{class=engine_class(&w,"MorphTarget"),outer=1,name=morph.name,data=m.data[:]})
        }
    }
    return package_bytes(&w)
}

// SkeletalMeshSocket exports of an outer.
@(private)
sockets_add :: proc(w:^Writer,sockets:[]Skeletal_Socket,outer:i32,allocator:=context.temp_allocator) {
    for socket in sockets {
        b:=bytes_make(allocator)
        name_property(&b,w,"SocketName",socket.name)
        name_property(&b,w,"BoneName",socket.bone)
        vector_property(&b,w,"RelativeLocation",{f64(socket.location.x),f64(socket.location.y),f64(socket.location.z)})
        rotator_property(&b,w,"RelativeRotation",socket.rotation)
        vector_property(&b,w,"RelativeScale",{f64(socket.scale.x),f64(socket.scale.y),f64(socket.scale.z)})
        none(&b,w)
        put_u32(&b,0)
        export_add(w,{class=engine_class(w,"SkeletalMeshSocket"),outer=outer,name=socket.name,data=b.data[:]})
    }
}

// A Skeleton package: its reference skeleton, an empty list of retarget
// sources, its guid and the smart names of its curves, those of
// morph_curves marked as driving morph targets.
skeleton_package :: proc(layout:Skeletal_Layout,name:string,bones:[]Skeletal_Bone,allocator:=context.temp_allocator,sockets:[]Skeletal_Socket=nil,morph_curves:[]string=nil) -> []u8 {
    s,versions:=skeletal_versions(layout)
    w:=writer_make({ue5=s.ue5,versions=versions,package_name=name},allocator)
    class:=engine_class(&w,"Skeleton")
    b:=bytes_make(allocator)
    if len(sockets)>0 {
        refs:=make([]i32,len(sockets),allocator)
        for &ref,i in refs {ref=i32(2+i)}
        objects_property(&b,&w,"Sockets",refs)
    }
    none(&b,&w)
    put_u32(&b,0)
    reference_skeleton(&b,&w,s,bones)
    put_u32(&b,0)
    put_zeros(&b,16)
    // SmartNameContainer: one mapping, AnimationCurves, with the CurveMetaData of each curve.
    put_u32(&b,1)
    put_name(&b,&w,"AnimationCurves")
    put_u32(&b,u32(len(morph_curves)))
    for curve in morph_curves {
        put_name(&b,&w,curve)
        put_u32(&b,0);put_u32(&b,1)
        put_u32(&b,0)
        put_u8(&b,0xff)
    }
    export_add(&w,{class=class,outer=0,name=last_part(name),data=b.data[:]})
    sockets_add(&w,sockets,1,allocator)
    return package_bytes(&w)
}

@(private)
last_part :: proc(path:string) -> string {
    for i:=len(path)-1;i>=0;i-=1 {if path[i]=='/' {return path[i+1:]}}
    return path
}

// ReferenceSkeleton: bones with their export names, poses and the map of names.
@(private)
reference_skeleton :: proc(b:^Bytes,w:^Writer,s:Skeletal_Versions,bones:[]Skeletal_Bone) {
    put_u32(b,u32(len(bones)))
    for bone in bones {
        put_name(b,w,bone.name)
        put_i32(b,bone.parent)
        put_text(b,bone.name)
    }
    put_u32(b,u32(len(bones)))
    real :: proc(b:^Bytes,s:Skeletal_Versions,value:f32) {if s.ue5>=1004 {put_f64(b,f64(value))} else {put_f32(b,value)}}
    for bone in bones {
        for x in bone.rotation {real(b,s,x)}
        for x in bone.translation {real(b,s,x)}
        for x in bone.scale {real(b,s,x)}
    }
    put_u32(b,u32(len(bones)))
    for bone,i in bones {put_name(b,w,bone.name);put_u32(b,u32(i))}
}

// SkeletalMeshModel with LOD 0, its sections and their soft vertices.
@(private)
lod_model :: proc(b:^Bytes,w:^Writer,s:Skeletal_Versions,f:Skeletal_Fixture) {
    if s.fortnite>=22 {put_u8(b,0);put_u8(b,0)}
    put_u32(b,1)
    put_u8(b,0);put_u8(b,0)
    wide_bones:=s.anim>=4
    bone_count:=s.anim>=5?12:8
    wide_weights:=s.main>=90
    weight_count:=wide_weights?12:bone_count
    put_u32(b,u32(len(f.sections)))
    first_index:=0
    for section in f.sections {
        put_u8(b,0);put_u8(b,0)
        put_u16(b,u16(section.material))
        put_u32(b,u32(first_index))
        put_u32(b,u32(len(section.corners)/3))
        first_index+=len(section.corners)
        if s.skeletal<18 {put_u8(b,0)}             // EnableClothLOD, before RemoveEnableClothLOD
        if s.recompute_tangent>=1 {put_u32(b,0)}
        if s.recompute_tangent>=2 {put_u8(b,0)}
        put_u32(b,1)                                // bCastShadow
        if s.main>=54 {put_u32(b,1)}
        put_u32(b,u32(section.first_vertex))
        put_u32(b,u32(section.vertex_count))
        for row in section.first_vertex..<section.first_vertex+section.vertex_count {
            p,n:=f.positions[row],f.normals[row]
            t:=f.tangents[row]
            binormal:=[3]f32{n.y*t.z-n.z*t.y,n.z*t.x-n.x*t.z,n.x*t.y-n.y*t.x}*t.w
            for x in p {put_f32(b,x)}
            for x in t.xyz {put_f32(b,x)}
            for x in binormal {put_f32(b,x)}
            for x in n {put_f32(b,x)};put_f32(b,t.w)
            for channel in 0..<4 {
                uv:=channel==0?f.uvs[row]:{}
                put_f32(b,uv.x);put_f32(b,uv.y)
            }
            c:=[4]u8{255,255,255,255}
            if len(f.colors)>0 {c=f.colors[row]}
            put_u8(b,c[2]);put_u8(b,c[1]);put_u8(b,c[0]);put_u8(b,c[3])
            locals:[12]u16
            weights:[12]f32
            for influence,k in f.influences[row] {
                if k>=bone_count {break}
                for bone,at in section.bone_map {if bone==influence.bone {locals[k]=u16(at)}}
                weights[k]=influence.weight
            }
            for k in 0..<bone_count {if wide_bones {put_u16(b,locals[k])} else {put_u8(b,u8(locals[k]))}}
            for k in 0..<weight_count {
                if wide_weights {put_u16(b,u16(weights[k]*65535+0.5))} else {put_u8(b,u8(weights[k]*255+0.5))}
            }
        }
        if wide_bones {put_u32(b,0)}
        put_u32(b,u32(len(section.bone_map)))
        for bone in section.bone_map {put_u16(b,bone)}
        put_u32(b,u32(section.vertex_count))
        put_u32(b,u32(bone_count))
        if s.main_release<15 {put_u32(b,0)} else {put_u32(b,1);put_u32(b,0)}
        put_u16(b,0xffff)
        put_zeros(b,16);put_i32(b,-1)
        put_u32(b,0)                                // overlapping vertices
        put_u32(b,section.disabled?1:0)
        put_i32(b,-1)
        if s.editor>=37 {put_i32(b,-1);put_i32(b,-1)}
    }
    if s.editor>=37 {
        // UserSectionsData by OriginalDataSectionIndex: the section of the import. The build of a
        // description makes one per material, in their order: there the key is the rank of the material.
        keys:=make([dynamic]i32,context.temp_allocator)
        rows:=make([dynamic]int,context.temp_allocator)
        for section,i in f.sections {
            key:=i32(i)
            if f.layout==.Description {
                key=0
                materials:=make([dynamic]int,context.temp_allocator)
                for other in f.sections {
                    known:=false
                    for m in materials {known||=m==other.material}
                    if !known {append(&materials,other.material)}
                }
                for m in materials {if m<section.material {key+=1}}
            }
            known:=false
            for k in keys {known||=k==key}
            if known {continue}
            append(&keys,key);append(&rows,i)
        }
        put_u32(b,u32(len(keys)))
        for key,at in keys {
            section:=f.sections[rows[at]]
            put_i32(b,key)
            put_u8(b,0);put_u8(b,0)
            put_u32(b,0);put_u8(b,0);put_u32(b,1)
            if s.main>=54 {put_u32(b,1)}
            put_u32(b,section.disabled?1:0)
            put_i32(b,-1)
            put_u16(b,0xffff)
            put_zeros(b,16);put_i32(b,-1)
        }
    }
    put_u32(b,u32(first_index))
    for section in f.sections {for corner in section.corners {put_u32(b,corner)}}
    put_u32(b,0)                                    // active bones
    if s.main>=58 {put_u32(b,0)}
    put_u32(b,0)
    put_u32(b,u32(len(f.positions)))
    put_u32(b,0)                                    // required bones
    if s.main_release<22 {byte_bulk_data(b,w,0,nil,false)} else {put_u32(b,0)}
    if s.fortnite>=14 && s.editor<38 {
        if s.editor>=37 {put_u8(b,0);put_u8(b,0)}
        byte_bulk_data(b,w,0,nil,false)
        put_zeros(b,16)
        put_u32(b,0)
    }
    if s.editor>=38 {put_text(b,"");put_u32(b,1);put_u32(b,0)}
    put_u32(b,0)
    put_i32(b,0)
    put_u32(b,1)
}

// The mesh description of the fixture: a polygon group per section, named
// after the imported slot name of its material, and the skin of each vertex.
@(private)
skeletal_description :: proc(w:^Writer,f:Skeletal_Fixture,s:Skeletal_Versions,allocator:=context.temp_allocator) -> []u8 {
    m:Mesh_Fixture
    m.positions=f.positions
    corners:=make([dynamic]u32,allocator)
    groups:=make([dynamic]u32,allocator)
    names:=make([dynamic]string,allocator)
    for section,i in f.sections {
        append(&corners,..section.corners)
        for _ in 0..<len(section.corners)/3 {append(&groups,u32(i))}
        append(&names,f.slots[section.material].imported_name)
    }
    m.corners,m.groups,m.group_names=corners[:],groups[:],names[:]
    m.normals=make([][3]f32,len(corners),allocator)
    m.tangents=make([][4]f32,len(corners),allocator)
    m.uvs=make([][2]f32,len(corners),allocator)
    for vertex,i in corners {m.normals[i],m.tangents[i],m.uvs[i]=f.normals[vertex],f.tangents[vertex],f.uvs[vertex]}
    return description_bytes(w,m,true,s.fortnite,allocator,f.influences,f.morphs)
}

// A TMeshUnboundedAttributeArraySet of int32 arrays, after its extent: one
// channel, chunks of 256 vertices, each weight the bone in the high 16 bits
// and the raw weight in the low.
@(private)
skin_weights :: proc(skin:[][]Skeletal_Influence,allocator:=context.temp_allocator) -> []u8 {
    b:=bytes_make(allocator)
    put_u32(&b,u32(len(skin)))
    put_u32(&b,1)
    chunks:=(len(skin)+255)/256
    put_u32(&b,u32(chunks))
    for chunk in 0..<chunks {
        first,last:=chunk*256,min(len(skin),chunk*256+256)
        values:=0
        for row in first..<last {values+=len(skin[row])}
        put_u32(&b,u32(values))
        for row in first..<last {
            for influence in skin[row] {put_u32(&b,u32(influence.bone)<<16|u32(influence.weight*65535+0.5))}
        }
        put_u32(&b,u32(last-first))
        start:=0
        for row in first..<last {put_u32(&b,u32(start));start+=len(skin[row])}
        for row in first..<last {put_u32(&b,u32(len(skin[row])))}
        for row in first..<last {put_u32(&b,u32(len(skin[row])))}
    }
    put_u32(&b,u32(len(skin)))
    put_u32(&b,0)
    put_u32(&b,0)
    put_u32(&b,0)
    return b.data[:]
}

// A figure of twelve bones (root, spine turned a quarter about Z 100 cm up,
// hand 50 cm along the spine and nine fingers on the hand) and ten vertices:
//
//   section 0   a quad facing up at the height of the spine, of material 1;
//               vertex 3 has ten influences (eight in UE4, which keeps no more)
//   section 1   a triangle facing +X, of material 1 that LODMaterialMap makes 0,
//               whose bone map starts at the hand
//   section 2   a triangle Unreal does not draw (bDisabled)
//
// The morph target Smile raises vertices 1 and 2 and turns the normal of 1,
// and the hand has a socket. The description of UE 5.4 has no
// LODMaterialMap: its groups take the slot of their name.
skeletal_figure :: proc(layout:Skeletal_Layout,allocator:=context.temp_allocator) -> (f:Skeletal_Fixture) {
    f.layout=layout
    f.skeleton="/Game/Characters/SK_Fixture_Skeleton"
    bones:=make([dynamic]Skeletal_Bone,allocator)
    quarter:=f32(0.70710677)
    append(&bones,
        Skeletal_Bone{"root",-1,{0,0,0},{0,0,0,1},{1,1,1}},
        Skeletal_Bone{"spine",0,{0,0,100},{0,0,quarter,quarter},{1,1,1}},
        Skeletal_Bone{"hand",1,{50,0,0},{0,0,0,1},{1,1,1}},
    )
    fingers:=[9]string{"finger_1","finger_2","finger_3","finger_4","finger_5","finger_6","finger_7","finger_8","finger_9"}
    for finger in fingers {append(&bones,Skeletal_Bone{finger,2,{10,0,0},{0,0,0,1},{1,1,1}})}
    f.bones=bones[:]
    up,forward:=[3]f32{0,0,1},[3]f32{1,0,0}
    f.positions=clone([][3]f32{{0,0,100},{100,0,100},{100,100,100},{0,100,100}, {100,0,0},{100,100,0},{100,0,100}, {0,0,0},{10,0,0},{0,10,0}},allocator)
    f.normals=clone([][3]f32{up,up,up,up, forward,forward,forward, up,up,up},allocator)
    f.tangents=make([][4]f32,10,allocator)
    for &t in f.tangents {t={0,1,0,1}}
    for &t in f.tangents[:4] {t={1,0,0,1}}
    f.uvs=clone([][2]f32{{0,1},{1,1},{1,0},{0,0}, {0,1},{1,1},{0,0}, {0,0},{1,0},{0,1}},allocator)
    many:=make([]Skeletal_Influence,layout==.UE4?8:10,allocator)
    weights:=[10]f32{0.19,0.17,0.15,0.13,0.11,0.09,0.07,0.05,0.03,0.01}
    total:f32
    for &influence,i in many {influence={u16(i+2),weights[i]};total+=weights[i]}
    for &influence in many {influence.weight/=total}
    f.influences=clone([][]Skeletal_Influence{
        clone([]Skeletal_Influence{{0,1}},allocator),
        clone([]Skeletal_Influence{{1,0.5},{2,0.5}},allocator),
        clone([]Skeletal_Influence{{2,1}},allocator),
        many,
        clone([]Skeletal_Influence{{2,1}},allocator),
        clone([]Skeletal_Influence{{1,1}},allocator),
        clone([]Skeletal_Influence{{1,0.75},{2,0.25}},allocator),
        clone([]Skeletal_Influence{{0,1}},allocator),
        clone([]Skeletal_Influence{{0,1}},allocator),
        clone([]Skeletal_Influence{{0,1}},allocator),
    },allocator)
    all:=make([]u16,len(bones),allocator)
    for &bone,i in all {bone=u16(i)}
    f.sections=clone([]Skeletal_Section{
        {material=1,first_vertex=0,vertex_count=4,corners=clone([]u32{0,2,1, 0,3,2},allocator),bone_map=all},
        {material=1,first_vertex=4,vertex_count=3,corners=clone([]u32{4,5,6},allocator),bone_map=clone([]u16{2,1},allocator)},
        {material=0,first_vertex=7,vertex_count=3,corners=clone([]u32{7,9,8},allocator),bone_map=clone([]u16{0},allocator),disabled=true},
    },allocator)
    f.slots=clone([]Mesh_Slot{{name="Head",imported_name="Head",material="/Game/Materials/M_Head"},{name="Body",imported_name="Body",material="/Game/Materials/M_Body"}},allocator)
    if layout!=.Description {f.lod_material_map=clone([]i32{-1,0},allocator)}
    f.bounds_min,f.bounds_max={0,0,0},{100,100,100}
    f.morphs=clone([]Skeletal_Morph{{name="Smile",deltas=clone([]Skeletal_Morph_Delta{{vertex=1,position={0,0,10},normal={0,0.5,0}},{vertex=2,position={0,0,20}}},allocator)}},allocator)
    f.sockets=clone([]Skeletal_Socket{{name="hand_socket",bone="hand",location={5,0,0},rotation={0,90,0},scale={1,1,1}}},allocator)
    return
}

// The sockets of the skeleton of the figure: one the mesh names again, which its own replaces, and one of its own.
skeletal_figure_sockets :: proc(allocator:=context.temp_allocator) -> []Skeletal_Socket {
    return clone([]Skeletal_Socket{{name="hand_socket",bone="hand",location={1,1,1},rotation={0,0,0},scale={1,1,1}},{name="head_socket",bone="spine",location={0,0,30},rotation={0,0,0},scale={2,2,2}}},allocator)
}

@(private)
clone :: proc(items:[]$T,allocator:=context.temp_allocator) -> []T {
    out:=make([]T,len(items),allocator)
    copy(out,items)
    return out
}
