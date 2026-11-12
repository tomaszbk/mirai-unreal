package unreal_foliage

import "core:math"
import "core:math/linalg"
import "core:mem"
import "core:slice"
import "core:strings"
import level "project:plugins/unreal/editor/level"
import unreal "project:plugins/unreal/editor/package"
import mm "mirai:std/math"

// The foliage of a level: each foliage type of an InstancedFoliageActor and
// its instances in Mirai's space. The instances come from the editor's
// record of each type (FoliageInfos, or FoliageMeshes before foliage
// version 12): where each was placed, its rotation and scale, its offset
// over the ground and what it was placed on. The instanced component that
// draws them in Unreal holds the same transforms as matrices; they are
// compared, instance by instance, to check the reading.
//
// A type of actors (FoliageType_Actor) places an actor of its class at each
// instance, which the level keeps among its actors; one that places only
// the static meshes of that class (bStaticMeshOnly, an ISM actor) draws them
// with instanced components of the InstancedFoliageActor, one for each mesh
// and its settings (DescriptorComponents), shared by every such type.

Scaling :: enum u8 {Uniform,Free,Lock_XY,Lock_XZ,Lock_YZ}

// What a type places: EFoliageImplType less one.
Foliage_Kind :: enum u8 {Static_Mesh,Actor,ISM_Actor}

Foliage_Type :: struct {
    name:string,          // object name of the foliage type
    path:string,          // its object path
    kind:Foliage_Kind,
    mesh:string,          // object path of its static mesh, "" without one
    actor_class:string,   // object path of the class an Actor or ISM_Actor type places
    density:f32,          // instances per square metre
    scale:[3][2]f32,      // along Unreal's X, Y and Z (Mirai's across, across and up): lowest and highest
    scaling:Scaling,
    z_offset:[2]f32,      // metres over the ground, lowest and highest
    align_to_normal:bool,
    align_max_angle:f32,  // radians
    random_yaw:bool,
    random_pitch:f32,     // radians
    cull:[2]f32,          // metres from the eye where it starts to fade and is gone; 0: never
    casts_shadow:bool,
    ray_visible:bool,
    collides:bool,
    collision_profile:string,
    bounds:[2][3]f32,     // origin and half extent of its mesh, metres in Mirai's axes
    has_bounds:bool,
    first_instance,instance_count:int,
}

Instance :: struct {
    type:int,
    transform:mm.Transform, // in Mirai's world
    ground:f32,             // metres the instance stands over the point it was placed on
    base:int,               // the component of the level it was placed on, -1 for none or unknown
    based:bool,             // it was placed on something
    aligned:bool,           // its rotation follows the ground
    actor:int,              // of an Actor type, the actor of the level placed there; -1 for none
}

Foliage :: struct {
    actor:int,              // the InstancedFoliageActor in the level document
    types:[]Foliage_Type,
    instances:[]Instance,
    components:[]int,       // the instanced components of the actor that draw its ISM_Actor types
    compared:int,           // instances whose matrix in the drawing component was compared
    mismatched:int,         // of those, the ones that differ
    max_difference:f32,     // centimetres (and unit scale) between the two transforms
    uncompared:int,         // types whose component could not be compared
    allocator:mem.Allocator,
}

foliage_destroy :: proc(f:^Foliage) {
    for t in f.types {
        delete(t.name,f.allocator);delete(t.path,f.allocator);delete(t.mesh,f.allocator);delete(t.actor_class,f.allocator)
        delete(t.collision_profile,f.allocator)
    }
    delete(f.types,f.allocator)
    delete(f.instances,f.allocator)
    delete(f.components,f.allocator)
    f^={}
}

foliages_destroy :: proc(list:^[dynamic]Foliage) {
    for &f in list {foliage_destroy(&f)}
    delete(list^)
    list^=nil
}

@(private) FOLIAGE_VERSION :: [4]u32{0x430c4d19,0x71544970,0x87699b69,0xdf90b0e5}
@(private) CROSS_LEVEL_BASE :: 5
@(private) FOLIAGE_ACTOR_SUPPORT :: 12
@(private) LAZY_TO_SOFT_POINTER :: 17
@(private) UE4_SOFT_OBJECT_PATH :: 514
@(private) UE5_LARGE_WORLD_COORDINATES :: 1004
@(private) UE5_TOP_LEVEL_ASSET_PATH :: 1007
@(private) UE5_SOFT_OBJECT_PATH_LIST :: 1008
@(private) INSTANCE_ALIGN_TO_NORMAL :: 0x1
@(private) INSTANCE_DELETED :: 0x8

// Every InstancedFoliageActor of the level, or of actors (indices of
// d.actors) when given.
foliage_read :: proc(d:^level.Document,allocator:=context.allocator,actors:[]int=nil) -> (list:[dynamic]Foliage,error:unreal.Error) {
    list.allocator=allocator
    bases:map[unreal.Guid]int
    bases.allocator=context.temp_allocator
    bases_ready:=false
    for actor,i in d.actors {
        if !level.class_is(actor.class,"/Script/Foliage","InstancedFoliageActor") {continue}
        if actors!=nil && !slice.contains(actors,i) {continue}
        if !bases_ready {bases_collect(d,&bases);bases_ready=true}
        f:Foliage
        f,error=actor_read(d,i,&bases,allocator)
        if error.code!=.None {foliages_destroy(&list);return}
        append(&list,f)
    }
    return
}

// The components of the level by the lazy GUID Object saves for them,
// which foliage bases name.
@(private)
bases_collect :: proc(d:^level.Document,bases:^map[unreal.Guid]int) {
    for component,i in d.components {
        held,error:=level.object_properties(d,component.ref)
        if error.code!=.None {continue}
        p:=level.library_package(d.library,int(component.ref.pkg))
        bytes,span_error:=unreal.span_bytes(p,held.list.trailing)
        if span_error.code!=.None || len(bytes)<20 || bytes[0]!=1 {continue}
        guid:unreal.Guid
        copy(guid[:],bytes[4:20])
        bases[guid]=i
    }
}

@(private)
Cursor :: struct {bytes:[]u8,at:int,failed:bool}

@(private)
take :: proc(c:^Cursor,n:int) -> []u8 {
    if c.failed || n<0 || c.at+n>len(c.bytes) {c.failed=true;return nil}
    out:=c.bytes[c.at:c.at+n]
    c.at+=n
    return out
}
@(private)
u32_take :: proc(c:^Cursor) -> u32 {
    b:=take(c,4)
    if b==nil {return 0}
    return u32(b[0])|u32(b[1])<<8|u32(b[2])<<16|u32(b[3])<<24
}
@(private) i32_take :: proc(c:^Cursor) -> i32 {return transmute(i32)u32_take(c)}
@(private) f32_take :: proc(c:^Cursor) -> f32 {return transmute(f32)u32_take(c)}
@(private)
f64_take :: proc(c:^Cursor) -> f64 {
    low:=u64(u32_take(c))
    return transmute(f64)(low|u64(u32_take(c))<<32)
}
@(private)
vector_take :: proc(c:^Cursor,wide:bool) -> (v:[3]f64) {
    for &x in v {x=wide?f64_take(c):f64(f32_take(c))}
    return
}
@(private)
guid_take :: proc(c:^Cursor) -> (g:unreal.Guid) {
    b:=take(c,16)
    if b!=nil {copy(g[:],b)}
    return
}
@(private)
count_take :: proc(c:^Cursor,element:int) -> int {
    n:=i32_take(c)
    if n<0 || i64(n)*i64(max(element,1))>i64(len(c.bytes)-c.at) {c.failed=true;return 0}
    return int(n)
}
@(private)
string_skip :: proc(c:^Cursor) {
    n:=i32_take(c)
    take(c,int(n<0?-i64(n)*2:i64(n)))
}

// A soft object path as the package saved it.
@(private)
soft_path_skip :: proc(c:^Cursor,p:^unreal.Package) {
    switch {
    case p.summary.version_ue5>=UE5_SOFT_OBJECT_PATH_LIST:take(c,4)
    case p.summary.version_ue5>=UE5_TOP_LEVEL_ASSET_PATH:take(c,16);string_skip(c)
    case p.summary.version_ue4>=UE4_SOFT_OBJECT_PATH:take(c,8);string_skip(c)
    case:string_skip(c)
    }
}

@(private)
Raw_Instance :: struct {
    location,rotation,pre_align:[3]f64,
    scale:[3]f32,
    flags:u32,
    z_offset:f32,
    base:i32,
}

@(private)
Raw_Type :: struct {
    type,component,actor_class:unreal.Object_Ref,
    kind:Foliage_Kind,
    first,count:int,
    actors:[]unreal.Object_Ref, // of an Actor type, by instance
    descriptors:[]i32,          // of an ISM_Actor type, the DescriptorComponents it draws with
}

@(private)
actor_read :: proc(d:^level.Document,actor_index:int,bases:^map[unreal.Guid]int,allocator:mem.Allocator) -> (f:Foliage,error:unreal.Error) {
    f.actor=actor_index
    f.allocator=allocator
    defer if error.code!=.None {foliage_destroy(&f)}
    ref:=d.actors[actor_index].ref
    p:=level.library_package(d.library,int(ref.pkg))
    payload:unreal.Span
    payload,error=level.actor_native_payload(d,ref)
    if error.code!=.None {return}
    bytes,_:=unreal.span_bytes(p,payload)
    c:=Cursor{bytes=bytes}
    version,known:=unreal.custom_version(p,FOLIAGE_VERSION)
    if !known || version<CROSS_LEVEL_BASE {return f,{.Unsupported_Version,payload.offset,"foliage saved before CrossLevelBase (foliage version 5)"}}
    fortnite,_:=unreal.custom_version(p,unreal.FORTNITE_MAIN_VERSION)
    wide:=p.summary.version_ue5>=UE5_LARGE_WORLD_COORDINATES
    // FoliageInstanceBaseCache: the bases instances were placed on.
    base_guids:=make(map[i32]unreal.Guid,64,context.temp_allocator)
    _=i32_take(&c) // next base id
    lazy:=fortnite<LAZY_TO_SOFT_POINTER
    // Counts go through locals: a range evaluates its bound on every iteration.
    count1:=count_take(&c,8)
    for _ in 0..<count1 {
        id:=i32_take(&c)
        if lazy {base_guids[id]=guid_take(&c)} else {soft_path_skip(&c,p)}
        _=vector_take(&c,wide);_=vector_take(&c,wide);_=vector_take(&c,wide)
    }
    count2:=count_take(&c,4)
    for _ in 0..<count2 {
        soft_path_skip(&c,p)
        count3:=count_take(&c,4)
        for _ in 0..<count3 {if lazy {take(&c,16)} else {soft_path_skip(&c,p)}}
    }
    raw_types:=make([dynamic]Raw_Type,context.temp_allocator)
    raw:=make([dynamic]Raw_Instance,context.temp_allocator)
    count4:=count_take(&c,8)
    for _ in 0..<count4 {
        t:=Raw_Type{type=unreal.Object_Ref(i32_take(&c)),kind=.Static_Mesh,first=len(raw)}
        if version>=FOLIAGE_ACTOR_SUPPORT {
            kind:=take(&c,1)
            if kind==nil || kind[0]<1 || kind[0]>u8(Foliage_Kind.ISM_Actor)+1 {
                return f,{.Unsupported_Value,payload.offset+i64(c.at),"foliage type of an unknown implementation"}
            }
            t.kind=Foliage_Kind(kind[0]-1)
        }
        switch t.kind {
        case .Static_Mesh:
            t.component=unreal.Object_Ref(i32_take(&c))
        case .Actor:
            // FoliageActor: the actor of each instance, then the class.
            n:=count_take(&c,4)
            t.actors=make([]unreal.Object_Ref,n,context.temp_allocator)
            for &a in t.actors {a=unreal.Object_Ref(i32_take(&c))}
            t.actor_class=unreal.Object_Ref(i32_take(&c))
        case .ISM_Actor:
            // FoliageISMActor: its guid, its client handle (index and guid), the
            // transforms of its meshes by descriptor, then the class.
            take(&c,16);take(&c,4);take(&c,16)
            n:=count_take(&c,8)
            t.descriptors=make([]i32,n,context.temp_allocator)
            for &descriptor in t.descriptors {
                descriptor=i32_take(&c)
                transforms:=count_take(&c,wide?80:40)
                take(&c,transforms*(wide?80:40))
            }
            t.actor_class=unreal.Object_Ref(i32_take(&c))
        }
        count5:=count_take(&c,76)
        for _ in 0..<count5 {
            i:Raw_Instance
            i.location=vector_take(&c,wide)
            i.rotation=vector_take(&c,wide)
            i.scale={f32_take(&c),f32_take(&c),f32_take(&c)}
            i.pre_align=vector_take(&c,wide)
            take(&c,16) // procedural guid
            i.flags=u32_take(&c)
            i.z_offset=f32_take(&c)
            i.base=i32_take(&c)
            if c.failed {break}
            append(&raw,i)
        }
        take(&c,16) // update guid
        t.count=len(raw)-t.first
        if t.kind==.Actor && len(t.actors)!=t.count && !c.failed {
            return f,{.Malformed,payload.offset+i64(c.at),"foliage of actors names a different number of actors than of instances"}
        }
        append(&raw_types,t)
        if c.failed {break}
    }
    if c.failed {return f,{.Truncated,payload.offset+i64(c.at),"foliage instances of the InstancedFoliageActor"}}
    allocation_error:mem.Allocator_Error
    f.types,allocation_error=make([]Foliage_Type,len(raw_types),allocator)
    if allocation_error!=nil {return f,{.Out_Of_Memory,0,"foliage types"}}
    kept:=0
    for i in raw {if i.flags&INSTANCE_DELETED==0 {kept+=1}}
    f.instances,allocation_error=make([]Instance,kept,allocator)
    if allocation_error!=nil {return f,{.Out_Of_Memory,0,"foliage instances"}}
    actors:=make(map[level.Ref]int,len(d.actors),context.temp_allocator)
    for a,i in d.actors {actors[a.ref]=i}
    at:=0
    for rt,type_index in raw_types {
        t:=&f.types[type_index]
        t.kind=rt.kind
        error=type_read(d,ref,rt.type,t,allocator)
        if error.code!=.None {return}
        if rt.kind!=.Static_Mesh {
            class:string
            class,error=unreal.reference_path(p,rt.actor_class,allocator)
            if error.code!=.None {return}
            t.actor_class=class
            // A type inside the level is shown by the class it places.
            if strings.contains(t.path,":") {
                delete(t.name,allocator)
                t.name=strings.clone(strings.trim_suffix(class[strings.last_index_byte(class,'.')+1:],"_C"),allocator)
            }
        }
        t.first_instance=at
        for i,n in raw[rt.first:][:rt.count] {
            if i.flags&INSTANCE_DELETED!=0 {continue}
            instance:=&f.instances[at]
            at+=1
            instance.type=type_index
            instance.actor=-1
            if rt.kind==.Actor && rt.actors[n]>0 {
                if a,found:=actors[{ref.pkg,rt.actors[n]}];found {instance.actor=a}
            }
            instance.transform,error=level.transform_to_mirai(i.location,i.rotation,{f64(i.scale.x),f64(i.scale.y),f64(i.scale.z)})
            if error.code!=.None {return}
            instance.aligned=i.flags&INSTANCE_ALIGN_TO_NORMAL!=0
            instance.base=-1
            if i.base>=0 {
                instance.based=true
                if guid,ok:=base_guids[i.base];ok {
                    if component,found:=bases[guid];found {instance.base=component}
                }
                // The offset along the instance's up, scaled with it: its height over the ground.
                up:=mm.quat_rotate(instance.transform.rotation,{0,1,0})
                instance.ground=i.z_offset*0.01*instance.transform.scale.y*up.y
            }
        }
        t.instance_count=at-t.first_instance
        if rt.kind==.Static_Mesh {compare(d,ref,rt,raw[rt.first:][:rt.count],&f)}
    }
    f.components,error=descriptor_components(d,ref,raw_types[:],allocator)
    return
}

// The instanced components of the actor ref (AISMPartitionActor's
// DescriptorComponents) that draw the ISM_Actor types among raw_types, each once.
@(private)
descriptor_components :: proc(d:^level.Document,ref:level.Ref,raw_types:[]Raw_Type,allocator:mem.Allocator) -> (components:[]int,error:unreal.Error) {
    wanted:=make(map[i32]bool,context.temp_allocator)
    for rt in raw_types {for descriptor in rt.descriptors {wanted[descriptor]=true}}
    if len(wanted)==0 {return}
    f:level.Found
    f,error=level.property(d,ref,"DescriptorComponents")
    if error.code!=.None {return}
    if f.property==nil {return nil,{.Invalid_Reference,0,"foliage of ISM actors without the DescriptorComponents that draw it"}}
    view:unreal.Array_View
    view,error=unreal.property_array(f.pkg,f.property)
    if error.code!=.None {return}
    items:unreal.Struct_Array
    items,error=unreal.array_tagged_structs(f.pkg,view,true,context.temp_allocator)
    if error.code!=.None {return}
    out:=make([dynamic]int,allocator)
    for &item,descriptor in items.items {
        if !wanted[i32(descriptor)] {continue}
        delete_key(&wanted,i32(descriptor))
        field:=unreal.property_find(f.pkg,&item,"Component")
        if field==nil {continue}
        v,v_error:=unreal.property_value(f.pkg,field)
        if v_error.code!=.None || v.kind!=.Object || v.object<=0 {continue}
        if k,found:=d.by_ref[{ref.pkg,v.object}];found {append(&out,k)}
    }
    if len(wanted)>0 {
        delete(out)
        return nil,{.Invalid_Reference,f.property.data.offset,"foliage of ISM actors names a descriptor its InstancedFoliageActor does not have"}
    }
    return out[:],{}
}

@(private)
interval_of :: proc(d:^level.Document,ref:level.Ref,name:string,default:[2]f32) -> [2]f32 {
    found,error:=level.property(d,ref,name)
    if error.code!=.None || found.property==nil {return default}
    list,list_error:=unreal.property_tagged_struct(found.pkg,found.property,true,context.temp_allocator)
    if list_error.code!=.None {return default}
    out:=default
    for field,i in ([2]string{"Min","Max"}) {
        if item:=unreal.property_find(found.pkg,&list,field);item!=nil {
            v,v_error:=unreal.property_value(found.pkg,item)
            if v_error.code!=.None {continue}
            if v.kind==.Real {out[i]=f32(v.real)} else if v.kind==.Signed {out[i]=f32(v.signed)}
        }
    }
    return out
}

// A foliage type, with FoliageType's defaults for what neither it nor an archetype has.
@(private)
type_read :: proc(d:^level.Document,owner:level.Ref,type_ref:unreal.Object_Ref,t:^Foliage_Type,allocator:mem.Allocator) -> unreal.Error {
    p:=level.library_package(d.library,int(owner.pkg))
    path,path_error:=unreal.reference_path(p,type_ref,context.temp_allocator)
    if path_error.code!=.None {return path_error}
    t.name=strings.clone(path[strings.last_index_any(path,".:")+1:],allocator)
    t.path=strings.clone(path,allocator)
    ref,native,error:=level.resolve(d,owner,type_ref)
    if error.code!=.None {return error}
    if native {return {.Invalid_Reference,0,"foliage type"}}
    if f,f_error:=level.property(d,ref,"Mesh");f_error.code==.None && f.property!=nil {
        v,v_error:=unreal.property_value(f.pkg,f.property)
        if v_error.code==.None && v.kind==.Object && v.object!=0 {
            mesh,_:=unreal.reference_path(f.pkg,v.object,context.temp_allocator)
            t.mesh=strings.clone(mesh,allocator)
            // A type inside the level is a subobject named after its class: Unreal shows it by its mesh.
            if strings.contains(path,":") {
                delete(t.name,allocator)
                t.name=strings.clone(mesh[strings.last_index_byte(mesh,'.')+1:],allocator)
            }
        }
    }
    // Density counts instances per 1000 by 1000 units.
    density,_:=level.real_of(d,ref,"Density",100)
    t.density=f32(density/100)
    for axis,i in ([3]string{"ScaleX","ScaleY","ScaleZ"}) {t.scale[i]=interval_of(d,ref,axis,{1,1})}
    if f,f_error:=level.property(d,ref,"Scaling");f_error.code==.None && f.property!=nil {
        v,v_error:=unreal.property_value(f.pkg,f.property)
        if v_error.code==.None && v.kind==.Name {
            switch strings.trim_prefix(unreal.name_plain(f.pkg,v.name),"EFoliageScaling::") {
            case "Free":t.scaling=.Free
            case "LockXY":t.scaling=.Lock_XY
            case "LockXZ":t.scaling=.Lock_XZ
            case "LockYZ":t.scaling=.Lock_YZ
            }
        }
    }
    offset:=interval_of(d,ref,"ZOffset",{0,0})
    t.z_offset={offset[0]*0.01,offset[1]*0.01}
    t.align_to_normal,_=level.bool_of(d,ref,"AlignToNormal",true)
    align_max,_:=level.real_of(d,ref,"AlignMaxAngle",0)
    t.align_max_angle=f32(align_max*math.RAD_PER_DEG)
    t.random_yaw,_=level.bool_of(d,ref,"RandomYaw",true)
    pitch,_:=level.real_of(d,ref,"RandomPitchAngle",0)
    t.random_pitch=f32(pitch*math.RAD_PER_DEG)
    cull:=interval_of(d,ref,"CullDistance",{0,0})
    t.cull={cull[0]*0.01,cull[1]*0.01}
    t.casts_shadow,_=level.bool_of(d,ref,"CastShadow",true)
    t.ray_visible,_=level.bool_of(d,ref,"bVisibleInRayTracing",true)
    // FoliageType's BodyInstance is NoCollision unless a type says otherwise.
    profile:="NoCollision"
    enabled:=""
    if f,f_error:=level.property(d,ref,"BodyInstance");f_error.code==.None && f.property!=nil && f.origin==.Authored {
        list,list_error:=unreal.property_tagged_struct(f.pkg,f.property,true,context.temp_allocator)
        if list_error.code==.None {
            if item:=unreal.property_find(f.pkg,&list,"CollisionProfileName");item!=nil {
                if v,v_error:=unreal.property_value(f.pkg,item);v_error.code==.None && v.kind==.Name {profile=unreal.name_plain(f.pkg,v.name)}
            }
            if item:=unreal.property_find(f.pkg,&list,"CollisionEnabled");item!=nil {
                if v,v_error:=unreal.property_value(f.pkg,item);v_error.code==.None && v.kind==.Name {enabled=unreal.name_plain(f.pkg,v.name)}
            }
        }
    }
    t.collision_profile=strings.clone(profile,allocator)
    t.collides=profile!="NoCollision" && enabled!="ECollisionEnabled::NoCollision"
    if f,f_error:=level.property(d,ref,"MeshBounds");f_error.code==.None && f.property!=nil {
        list,list_error:=unreal.property_tagged_struct(f.pkg,f.property,true,context.temp_allocator)
        if list_error.code==.None {
            origin,extent:[3]f64
            found:=0
            for field in ([2]string{"Origin","BoxExtent"}) {
                if item:=unreal.property_find(f.pkg,&list,field);item!=nil {
                    if v,v_error:=unreal.property_value(f.pkg,item);v_error.code==.None && v.kind==.Real_Vector {
                        if field=="Origin" {origin={v.vector[0],v.vector[1],v.vector[2]}} else {extent={v.vector[0],v.vector[1],v.vector[2]}}
                        found+=1
                    }
                }
            }
            if found==2 {
                t.bounds[0]=level.point_to_mirai(origin)
                // An extent is a size, not a point: its axes change, not its sign.
                e:=level.point_to_mirai(extent)
                t.bounds[1]={abs(e.x),abs(e.y),abs(e.z)}
                t.has_bounds=true
            }
        }
    }
    return {}
}

// Compares the instances of a type with the matrices of the component that
// draws them, PerInstanceSMData in the same order: a check of the reading.
@(private)
compare :: proc(d:^level.Document,owner:level.Ref,rt:Raw_Type,raw:[]Raw_Instance,f:^Foliage) {
    component,found:=d.by_ref[{owner.pkg,rt.component}]
    if !found || rt.component<=0 {f.uncompared+=1;return}
    world,world_error:=level.component_world(d,component)
    identity:=world_error.code==.None && mm.quat_rotate(world.rotation,{1,0,0})=={1,0,0} && world.position=={0,0,0} && world.scale=={1,1,1}
    instances,error:=level.component_instances(d,component,context.temp_allocator)
    matrices:=instances.matrices
    if !identity || error.code!=.None || len(matrices)!=len(raw) {f.uncompared+=1;return}
    for i,n in raw {
        m:=matrices[n]
        expected:=unreal_matrix(i)
        difference:f64
        for row in 0..<4 {for column in 0..<3 {difference=max(difference,abs(m[row][column]-expected[row][column]))}}
        f.compared+=1
        f.max_difference=max(f.max_difference,f32(difference))
        if difference>0.5 {f.mismatched+=1}
    }
}

// The matrix of Unreal's transform of Rotation, Location and DrawScale3D, scale included: row vectors.
@(private)
unreal_matrix :: proc(i:Raw_Instance) -> (m:[4][4]f64) {
    rotation:=linalg.matrix3_from_quaternion(unreal.rotator_quaternion(i.rotation.x,i.rotation.y,i.rotation.z))
    for row in 0..<3 {for column in 0..<3 {m[row][column]=rotation[column,row]*f64(i.scale[row])}}
    m[3]={i.location.x,i.location.y,i.location.z,1}
    return
}
