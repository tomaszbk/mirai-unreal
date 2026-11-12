package level

import "core:encoding/endian"
import unreal "project:plugins/unreal/editor/package"

// The instances of an InstancedStaticMeshComponent: PerInstanceSMData, the
// matrix of each instance relative to the component (Unreal's space, row
// vectors), and PerInstanceSMCustomData, the floats each instance gives its
// materials, from the native payload of the component.
component_instances :: proc(d:^Document,component:int,allocator:=context.allocator) -> (instances:Instances,error:unreal.Error) {
    ref:=d.components[component].ref
    held:^Object_Properties
    if held,error=object_properties(d,ref);error.code!=.None {return}
    p:=library_package(d.library,int(ref.pkg))
    payload:unreal.Span
    if payload,error=unreal.object_native_payload(p,held.list.trailing);error.code!=.None {return}
    bytes:[]u8
    if bytes,error=unreal.span_bytes(p,payload);error.code!=.None {return}
    return instances_read(bytes,allocator),{}
}

Instances :: struct {
    matrices:[][4][4]f64,
    custom:[]f32,      // per_instance floats of each instance, one after the other
    per_instance:int,  // NumCustomDataFloats; 0: none
}

// The custom floats of instance i; none without them.
instance_custom :: proc(instances:Instances,i:int) -> []f32 {
    if instances.per_instance==0 {return nil}
    return instances.custom[i*instances.per_instance:][:instances.per_instance]
}

// The instances of the bulk arrays of PerInstanceSMData and
// PerInstanceSMCustomData in a native payload.
// An InstancedStaticMeshComponent writes it after what
// StaticMeshComponent keeps (LODs, painted vertices: their length changes
// with the save) and the flags bCooked and bHasSkipSerializationPropertiesData
// of the saves that have them: the element size, the count and the elements,
// then the bulk array of the custom data (floats). The array is where a size
// and a count fit the payload and its first element is a matrix of row
// vectors: InstancedStaticMeshInstanceData is a matrix of floats (64 bytes),
// with the UV biases of UE4 after it (80), or a matrix of doubles (128). None
// there is no instance: a component without them, or one that takes those
// of its archetype.
instances_read :: proc(bytes:[]u8,allocator:=context.allocator) -> (instances:Instances) {
    word :: proc(bytes:[]u8,at:int) -> u32 {
        value,_:=endian.get_u32(bytes[at:],.Little)
        return value
    }
    element :: proc(bytes:[]u8,size:u32,row,column:int) -> f64 {
        n:=row*4+column
        if size==128 {
            value,_:=endian.get_f64(bytes[n*8:],.Little)
            return value
        }
        value,_:=endian.get_f32(bytes[n*4:],.Little)
        return f64(value)
    }
    for at in 0..=len(bytes)-8 {
        size,count:=word(bytes,at),word(bytes,at+4)
        if size!=64 && size!=80 && size!=128 || count==0 || i64(count)*i64(size)>i64(len(bytes)-at-8) {continue}
        first:=bytes[at+8:]
        if element(first,size,0,3)!=0 || element(first,size,1,3)!=0 || element(first,size,2,3)!=0 || element(first,size,3,3)!=1 {continue}
        end:=at+8+int(count)*int(size)
        floats,custom:u32
        if end+8<=len(bytes) {
            floats,custom=word(bytes,end),word(bytes,end+4)
            if floats!=4 && floats!=0 || i64(custom)*4>i64(len(bytes)-end-8) {continue}
        }
        instances.matrices=make([][4][4]f64,int(count),allocator)
        for &m,i in instances.matrices {
            data:=bytes[at+8+i*int(size):]
            for row in 0..<4 {for column in 0..<4 {m[row][column]=element(data,size,row,column)}}
        }
        // The custom floats, as many for each instance.
        if floats==4 && custom>0 && custom%count==0 {
            instances.per_instance=int(custom/count)
            instances.custom=make([]f32,int(custom),allocator)
            for &value,i in instances.custom {value,_=endian.get_f32(bytes[end+8+i*4:],.Little)}
        }
        return
    }
    return
}
