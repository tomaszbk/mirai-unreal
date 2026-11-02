package fixture_files

// A map: a World, its PersistentLevel and the actors of the level with their
// components, as UE4 saves them. Actors and components are exports added in
// order; the level and each actor are written when the map ends, once every
// reference is known.

Level_Writer :: struct {
    w:Writer,
    level:i32,
    actors:[dynamic]Level_Actor,
    properties:Bytes, // of the level
}

Level_Actor :: struct {
    export:i32,
    label:string,
    root:i32,
    properties:Bytes, // besides RootComponent and ActorLabel
}

level_begin :: proc(package_name:string,allocator:=context.temp_allocator) -> (l:Level_Writer) {
    versions:=make([]Version,1,allocator)
    versions[0]={RELEASE,44}
    l.w=writer_make({versions=versions,package_name=package_name},allocator)

    l.actors.allocator=allocator
    world:=export_add(&l.w,{class=engine_class(&l.w,"World"),outer=0,name="Map"})
    l.level=export_add(&l.w,{class=engine_class(&l.w,"Level"),outer=world,name="PersistentLevel"})
    return
}

// A class of a script package: /Script/<module>.<class>.
script_class :: proc(w:^Writer,module,class:string) -> i32 {
    outer:=i32(0)
    for item,i in w.imports {
        if item.name==module && item.outer==0 {outer= -i32(i+1)}
        if item.name==class && item.class_name=="Class" && outer!=0 && item.outer==outer {return -i32(i+1)}
    }
    if outer==0 {outer=import_add(w,{"/Script/CoreUObject","Package",module,0})}
    return import_add(w,{"/Script/CoreUObject","Class",class,outer})
}

// An object of another package: /Game/Meshes/SM_Rock.SM_Rock of class /Script/Engine.StaticMesh.
package_object :: proc(w:^Writer,package_name,class_package,class,object:string) -> i32 {
    outer:=import_add(w,{"/Script/CoreUObject","Package",package_name,0})
    return import_add(w,{class_package,class,object,outer})
}

// An actor of the level; its root and properties are set with actor_set.
actor_add :: proc(l:^Level_Writer,class:i32,name,label:string) -> i32 {
    export:=export_add(&l.w,{class=class,outer=l.level,name=name})
    append(&l.actors,Level_Actor{export=export,label=label,properties=bytes_make(l.w.allocator)})
    return export
}

actor_set :: proc(l:^Level_Writer,actor,root:i32,properties:Bytes={}) {
    for &a in l.actors {
        if a.export!=actor {continue}
        a.root=root
        if properties.data!=nil {a.properties=properties}
    }
}

// A component of an actor with its tagged properties, ended here.
component_add :: proc(l:^Level_Writer,actor,class:i32,name:string,properties:Bytes) -> i32 {
    b:=properties
    if b.data==nil {b=bytes_make(l.w.allocator)}
    none(&b,&l.w)
    put_u32(&b,0)
    return export_add(&l.w,{class=class,outer=actor,name=name,data=b.data[:]})
}

level_bytes :: proc(l:^Level_Writer) -> []u8 {
    for &a in l.actors {
        b:=bytes_make(l.w.allocator)
        if a.root!=0 {object_property(&b,&l.w,"RootComponent",a.root)}
        if a.label!="" {str_property(&b,&l.w,"ActorLabel",a.label)}
        put_bytes(&b,a.properties.data[:])
        none(&b,&l.w)
        put_u32(&b,0)
        l.w.exports[a.export-1].data=b.data[:]
    }
    b:=bytes_make(l.w.allocator)
    put_bytes(&b,l.properties.data[:])
    none(&b,&l.w)
    put_u32(&b,0)
    put_u32(&b,u32(len(l.actors)))
    for a in l.actors {put_i32(&b,a.export)}
    l.w.exports[l.level-1].data=b.data[:]
    world:=bytes_make(l.w.allocator)
    none(&world,&l.w)
    put_u32(&world,0)
    l.w.exports[0].data=world.data[:]
    return package_bytes(&l.w)
}

str_property :: proc(b:^Bytes,w:^Writer,property,value:string) {tag(b,w,property,"StrProperty",len(value)+5);put_text(b,value)}
float_property :: proc(b:^Bytes,w:^Writer,property:string,value:f32) {tag(b,w,property,"FloatProperty",4);put_f32(b,value)}

// A ByteProperty of an enum, saved by name: "ELightUnits::Lumens".
enum_property :: proc(b:^Bytes,w:^Writer,property,enum_type,value:string) {tag(b,w,property,"ByteProperty",8,{inner=enum_type});put_name(b,w,value)}

rotator_property :: proc(b:^Bytes,w:^Writer,property:string,pitch_yaw_roll:[3]f32) {
    wide:=w.desc.ue5>=1004
    tag(b,w,property,"StructProperty",wide?24:12,{struct_name="Rotator"})
    for x in pitch_yaw_roll {if wide {put_f64(b,f64(x))} else {put_f32(b,x)}}
}

// An FColor, its bytes B, G, R and A.
color_property :: proc(b:^Bytes,w:^Writer,property:string,rgba:[4]u8) {
    tag(b,w,property,"StructProperty",4,{struct_name="Color"})
    put_u8(b,rgba[2]);put_u8(b,rgba[1]);put_u8(b,rgba[0]);put_u8(b,rgba[3])
}

objects_property :: proc(b:^Bytes,w:^Writer,property:string,values:[]i32) {
    tag(b,w,property,"ArrayProperty",4+4*len(values),{inner="ObjectProperty"})
    put_u32(b,u32(len(values)))
    for v in values {put_i32(b,v)}
}
