package unreal

class_default_object :: proc(p:^Package,class:Object_Ref) -> (object:Object_Ref,error:Error) {
    if p==nil || class<=0 || !reference_valid(p,class) {return 0,{.Invalid_Reference,0,"class default lookup requires the resolved class export"}}
    for &candidate,index in p.exports {
        if candidate.class!=class || candidate.object_flags&0x10==0 {continue}
        if object!=0 {return 0,{.Malformed,candidate.source.offset,"class has more than one RF_ClassDefaultObject export"}}
        object=Object_Ref(index+1)
    }
    if object==0 {return 0,{.Invalid_Reference,p.exports[int(class)-1].source.offset,"class default object is absent from the source package"}}
    return
}
