package mesh

import "core:mem"
import "core:strings"
import mm "mirai:std/math"
import unreal "project:plugins/unreal/editor/package"

// The simple collision of a mesh: the AggGeom of its BodySetup, in Unreal's
// space and in the space of the mesh, how its complex collision is used and
// the collision profile of its DefaultInstance.

Body_Trace :: enum u8 {
    Default,           // simple shapes collide; with none, only the complex mesh answers traces
    Simple_And_Complex,
    Simple_As_Complex,
    Complex_As_Simple, // the triangles of the mesh are its collision
}

Body_Shape_Kind :: enum u8 {Box,Sphere,Capsule,Convex}

// A box: its half sizes. A sphere: its radius in x. A capsule: its radius in
// x and half the length of its segment in y, along its Z. A convex: its
// points, already placed in the mesh.
Body_Shape :: struct {
    kind:Body_Shape_Kind,
    center:[3]f32,
    rotation:quaternion128,
    size:[3]f32,
    points:[][3]f32,
}

Body :: struct {
    shapes:[]Body_Shape,
    trace:Body_Trace,
    profile:string,  // CollisionProfileName of its DefaultInstance; "" when it does not say
    left_out:int,    // tapered capsules and level sets, which have no Mirai shape
}

// The BodySetup an export references; an empty body without one. Everything
// returned is in allocator.
body_read :: proc(p:^unreal.Package,setup:unreal.Object_Ref,allocator:=context.allocator) -> (body:Body,error:unreal.Error) {
    if setup<=0 || int(setup)>len(p.exports) {return}
    properties:unreal.Property_List
    properties,error=unreal.export_properties(p,int(setup)-1,true,context.temp_allocator)
    if error.code!=.None {return}
    defer unreal.properties_destroy(&properties)
    if item:=unreal.property_find(p,&properties,"CollisionTraceFlag");item!=nil {
        switch enum_name(p,item) {
        case "CTF_UseSimpleAndComplex": body.trace=.Simple_And_Complex
        case "CTF_UseSimpleAsComplex": body.trace=.Simple_As_Complex
        case "CTF_UseComplexAsSimple": body.trace=.Complex_As_Simple
        }
    }
    if item:=unreal.property_find(p,&properties,"DefaultInstance");item!=nil {
        if instance,instance_error:=unreal.property_tagged_struct(p,item,true,context.temp_allocator);instance_error.code==.None {
            body.profile=name_of(p,&instance,"CollisionProfileName",allocator,&error)
            if error.code!=.None {return}
        }
    }
    item:=unreal.property_find(p,&properties,"AggGeom")
    if item==nil {return}
    geometry:unreal.Property_List
    geometry,error=unreal.property_tagged_struct(p,item,true,context.temp_allocator)
    if error.code!=.None {return}
    shapes:=make([dynamic]Body_Shape,allocator)
    elements :: proc(p:^unreal.Package,list:^unreal.Property_List,name:string,error:^unreal.Error) -> []unreal.Property_List {
        item:=unreal.property_find(p,list,name)
        if item==nil || error.code!=.None {return nil}
        view,view_error:=unreal.property_array(p,item)
        if view_error.code!=.None {error^=view_error;return nil}
        items,items_error:=unreal.array_tagged_structs(p,view,true,context.temp_allocator)
        if items_error.code!=.None {error^=items_error;return nil}
        return items.items
    }
    collides :: proc(p:^unreal.Package,element:^unreal.Property_List) -> bool {
        item:=unreal.property_find(p,element,"CollisionEnabled")
        return item==nil || enum_name(p,item)!="NoCollision"
    }
    // The rotation of an element: its Rotator, or the quaternion saves before it kept.
    turn :: proc(p:^unreal.Package,element:^unreal.Property_List,error:^unreal.Error) -> quaternion128 {
        if rotator,found:=vector_of(p,element,"Rotation",error);found {
            q:=unreal.rotator_quaternion(rotator.x,rotator.y,rotator.z)
            return quaternion(w=f32(q.w),x=f32(q.x),y=f32(q.y),z=f32(q.z))
        }
        return quaternion_of(p,element,"Orientation",error)
    }
    center :: proc(p:^unreal.Package,element:^unreal.Property_List,error:^unreal.Error) -> [3]f32 {
        c,_:=vector_of(p,element,"Center",error)
        return {f32(c.x),f32(c.y),f32(c.z)}
    }
    for &box in elements(p,&geometry,"BoxElems",&error) {
        if !collides(p,&box) {continue}
        size:=[3]f64{real_of(p,&box,"X",1,&error),real_of(p,&box,"Y",1,&error),real_of(p,&box,"Z",1,&error)}
        append(&shapes,Body_Shape{kind=.Box,center=center(p,&box,&error),rotation=turn(p,&box,&error),size={f32(size.x),f32(size.y),f32(size.z)}*0.5})
    }
    for &sphere in elements(p,&geometry,"SphereElems",&error) {
        if !collides(p,&sphere) {continue}
        append(&shapes,Body_Shape{kind=.Sphere,center=center(p,&sphere,&error),rotation=1,size={f32(real_of(p,&sphere,"Radius",1,&error)),0,0}})
    }
    for &capsule in elements(p,&geometry,"SphylElems",&error) {
        if !collides(p,&capsule) {continue}
        radius,length:=real_of(p,&capsule,"Radius",1,&error),real_of(p,&capsule,"Length",1,&error)
        append(&shapes,Body_Shape{kind=.Capsule,center=center(p,&capsule,&error),rotation=turn(p,&capsule,&error),size={f32(radius),f32(length)*0.5,0}})
    }
    for &convex in elements(p,&geometry,"ConvexElems",&error) {
        if !collides(p,&convex) {continue}
        points:=vectors_of(p,&convex,"VertexData",allocator,&error)
        if error.code!=.None {return}
        if len(points)==0 {continue}
        if item:=unreal.property_find(p,&convex,"Transform");item!=nil {
            placed,placed_error:=unreal.property_tagged_struct(p,item,true,context.temp_allocator)
            if placed_error.code!=.None {error=placed_error;return}
            rotation:=quaternion_of(p,&placed,"Rotation",&error)
            translation,_:=vector_of(p,&placed,"Translation",&error)
            scale,scaled:=vector_of(p,&placed,"Scale3D",&error)
            if !scaled {scale={1,1,1}}
            for &point in points {
                point=mm.quat_rotate(rotation,point*{f32(scale.x),f32(scale.y),f32(scale.z)})+{f32(translation.x),f32(translation.y),f32(translation.z)}
            }
        }
        append(&shapes,Body_Shape{kind=.Convex,rotation=1,points=points})
    }
    for name in ([]string{"TaperedCapsuleElems","LevelSetElems","SkinnedLevelSetElems"}) {body.left_out+=len(elements(p,&geometry,name,&error))}
    if error.code!=.None {return}
    for shape in shapes {
        for value in shape.size {if value-value!=0 || value<0 {return {},{.Malformed,item.data.offset,"a shape of the body setup has a size that is not a positive number"}}}
        for value in shape.center {if value-value!=0 {return {},{.Malformed,item.data.offset,"a shape of the body setup is not at a finite place"}}}
    }
    body.shapes=shapes[:]
    return
}

body_destroy :: proc(body:^Body,allocator:=context.allocator) {
    for shape in body.shapes {delete(shape.points,allocator)}
    delete(body.shapes,allocator)
    delete(body.profile,allocator)
    body^={}
}

@(private="file")
enum_name :: proc(p:^unreal.Package,property:^unreal.Property) -> string {
    v,error:=unreal.property_value(p,property)
    if error.code!=.None || v.kind!=.Name {return ""}
    text:=unreal.name_plain(p,v.name)
    if at:=strings.last_index(text,"::");at>=0 {text=text[at+2:]}
    return text
}

@(private="file")
quaternion_of :: proc(p:^unreal.Package,list:^unreal.Property_List,name:string,error:^unreal.Error) -> quaternion128 {
    property:=unreal.property_find(p,list,name)
    if property==nil || error.code!=.None {return 1}
    read,read_error:=unreal.property_value(p,property)
    defer unreal.value_destroy(&read)
    if read_error.code!=.None {error^=read_error;return 1}
    if read.kind!=.Real_Vector || read.vector_count!=4 {error^={.Malformed,property.data.offset,"body setup quaternion"};return 1}
    q:=quaternion(w=f32(read.vector[3]),x=f32(read.vector[0]),y=f32(read.vector[1]),z=f32(read.vector[2]))
    length:=abs(q)
    if !(length>0) || length-length!=0 {error^={.Malformed,property.data.offset,"body setup quaternion is not a rotation"};return 1}
    return q/quaternion128(length)
}

// The points of an array of Vector, as Unreal serializes them: floats before
// large world coordinates, doubles after.
@(private="file")
vectors_of :: proc(p:^unreal.Package,list:^unreal.Property_List,name:string,allocator:mem.Allocator,error:^unreal.Error) -> (points:[][3]f32) {
    property:=unreal.property_find(p,list,name)
    if property==nil || error.code!=.None {return}
    view,view_error:=unreal.property_array(p,property)
    if view_error.code!=.None {error^=view_error;return}
    wide:=p.summary.version_ue5>=UE5_LARGE_WORLD_COORDINATES
    size:=i64(24 if wide else 12)
    if i64(view.count)*size!=view.data.size {error^={.Malformed,property.data.offset,"convex points have another size than their vectors"};return}
    bytes,_:=unreal.span_bytes(p,view.data)
    points=make([][3]f32,int(view.count),allocator)
    for &point,i in points {
        for k in 0..<3 {
            at:=i*int(size)+k*int(size/3)
            point[k]=f32(transmute(f64)(u64(u32_at(bytes,at))|u64(u32_at(bytes,at+4))<<32)) if wide else f32_at(bytes,at)
            if point[k]-point[k]!=0 {error^={.Malformed,property.data.offset,"a convex point is not finite"};delete(points,allocator);return nil}
        }
    }
    return
}
