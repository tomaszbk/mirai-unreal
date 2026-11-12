package mesh

import "core:mem"
import unreal "project:plugins/unreal/editor/package"

// The curves a Skeleton marks as driving morph targets (CurveMetaData's
// Type.bMorphtarget): in its SmartNameContainer, after the retarget sources
// and the guid of its native tail, until UE 5.3; in the CurveMetaData of its
// AnimCurveMetaData since.

@(private) ANIM_PHYS_GUID :: [4]u32{0x29E575DD,0xE0A34627,0x9D10D276,0x232CDCEA}
@(private) UE4_SMART_NAMES :: 388                  // VER_UE4_SKELETON_ADD_SMARTNAMES
@(private) UE5_SOFT_PATH_NAMES :: 1007             // FSOFTOBJECTPATH_REMOVE_ASSET_PATH_FNAMES
@(private) UE5_SOFT_PATH_LIST :: 1008              // ADD_SOFTOBJECTPATH_LIST
@(private) FRAMEWORK_SMART_NAME_REFACTOR :: 7      // FrameworkObjectVersion::SmartNameRefactor
@(private) FRAMEWORK_CURVE_TYPES_ON_SKELETON :: 15 // FrameworkObjectVersion::MoveCurveTypesToSkeleton
@(private) ANIM_PHYS_DETERMINISTIC_NAMES :: 10     // AnimPhysObjectVersion::SmartNameRefactorForDeterministicCooking
@(private) ANIM_PHYS_CURVE_LOD :: 12               // AnimPhysObjectVersion::AddLODToCurveMetaData
@(private) ANIM_PHYS_SOFT_RETARGET_MESH :: 15      // AnimPhysObjectVersion::ChangeRetargetSourceReferenceToSoftObjectPtr
@(private) RELEASE_SMART_NAMES_REMOVED :: 64       // UE5ReleaseStreamObjectVersion::RemovedSmartNameContainerPayload

// The morph target curves of a skeleton, from the rest of its native tail
// after the reference skeleton, or from its AnimCurveMetaData. ok is false
// when the save keeps them in a way that is not read: a retarget source
// whose mesh is in the soft object path table.
@(private)
morph_curves_read :: proc(r:^Reader,p:^unreal.Package,v:Versions,skeleton:int,allocator:mem.Allocator) -> (names:[]string,ok:bool) {
    out:=make([dynamic]string,allocator)
    defer if !ok {
        for name in out {delete(name,allocator)}
        delete(out)
    }
    if v.main_release<RELEASE_SMART_NAMES_REMOVED && v.ue4>=UE4_SMART_NAMES {
        framework,_:=unreal.custom_version(p,unreal.FRAMEWORK_OBJECT_VERSION)
        physics,_:=unreal.custom_version(p,ANIM_PHYS_GUID)
        // AnimRetargetSources: a map of Name to ReferencePose.
        sources:=count_read(r,8,"retarget source count")
        for _ in 0..<sources {
            _=take(r,16,"retarget source and pose names")
            real:=v.ue5>=UE5_LARGE_WORLD_COORDINATES?8:4
            _=take(r,count_read(r,10*real,"retarget pose count")*10*real,"retarget pose")
            switch {
            case physics<ANIM_PHYS_SOFT_RETARGET_MESH:_=take(r,4,"retarget mesh")
            case v.ue5>=UE5_SOFT_PATH_LIST:return nil,false
            case v.ue5>=UE5_SOFT_PATH_NAMES:_=take(r,16,"retarget mesh path");text_skip(r,"retarget mesh sub path")
            case:_=take(r,8,"retarget mesh path");text_skip(r,"retarget mesh sub path")
            }
        }
        if v.ue4>=UE4_SKELETON_GUID {_=take(r,16,"skeleton guid")}
        // SmartNameContainer: a map of Name to SmartNameMapping.
        containers:=count_read(r,8,"smart name container count")
        for _ in 0..<containers {
            _=name_read(r,p,"smart name container")
            if framework>=FRAMEWORK_SMART_NAME_REFACTOR {
                if physics<ANIM_PHYS_DETERMINISTIC_NAMES {_=take(r,count_read(r,24,"smart name guid count")*24,"smart name guids")}
            } else {
                _=u16_read(r,"smart name next uid")
                _=take(r,count_read(r,10,"smart name uid count")*10,"smart name uids")
            }
            if framework<FRAMEWORK_CURVE_TYPES_ON_SKELETON {continue}
            entries:=count_read(r,16,"curve metadata count")
            for _ in 0..<entries {
                name:=name_read(r,p,"curve metadata name")
                morph:=curve_metadata_read(r,physics)
                if failed(r) {return nil,false}
                if morph {append(&out,unreal.name_text(p,name,allocator))}
            }
        }
        if failed(r) {return nil,false}
        return out[:],true
    }
    // AnimCurveMetaData: CurveMetaData, a map of Name to CurveMetaData serialized natively.
    for item,index in p.exports {
        if item.outer!=unreal.Object_Ref(skeleton+1) || !unreal.reference_in_package(p,item.class,"/Script/Engine","AnimCurveMetaData") {continue}
        properties,error:=unreal.export_properties(p,index,true,context.temp_allocator)
        if error.code!=.None {return nil,false}
        defer unreal.properties_destroy(&properties)
        property:=unreal.property_find(p,&properties,"CurveMetaData")
        if property==nil {continue}
        bytes,_:=unreal.span_bytes(p,property.data)
        m:=reader_make(bytes,property.data.offset)
        physics,_:=unreal.custom_version(p,ANIM_PHYS_GUID)
        _=take(&m,count_read(&m,8,"curve metadata removed count")*8,"curve metadata removed keys")
        entries:=count_read(&m,16,"curve metadata count")
        for _ in 0..<entries {
            name:=name_read(&m,p,"curve metadata name")
            morph:=curve_metadata_read(&m,physics)
            if failed(&m) {return nil,false}
            if morph {append(&out,unreal.name_text(p,name,allocator))}
        }
    }
    return out[:],true
}

// Natively serialized CurveMetaData: whether it drives a morph target.
@(private)
curve_metadata_read :: proc(r:^Reader,physics:i32) -> (morph:bool) {
    _=bool_read(r,"curve metadata material")
    morph=bool_read(r,"curve metadata morph target")
    _=take(r,count_read(r,8,"curve metadata linked bones")*8,"curve metadata linked bones")
    if physics>=ANIM_PHYS_CURVE_LOD {_=u8_read(r,"curve metadata LOD")}
    return
}
